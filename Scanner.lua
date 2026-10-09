AltStable = AltStable or {}

-- Retail-API adapters. Taken as file-locals so call sites below read the same
-- as they always did; see Compat.lua for why these are not globals.
local API = AltStable.API
local GetNumSkillLines = API.GetNumSkillLines
local GetSkillLineInfo = API.GetSkillLineInfo
local UnitDefenseSkill = API.UnitDefenseSkill
-- Unit stats can come back "secret" on this client: storable, but arithmetic or
-- tostring on one throws (see Compat.lua). Every unit number below is read
-- through these, so a secret becomes nil - unknown - instead of aborting the
-- scan or being stored as a value that cannot be summed, compared or synced.
local plain = API.PlainNumber
local plainSum = API.PlainSum
local GetItemInfo      = API.GetItemInfo
local GetItemStats     = API.GetItemStats

local PRIMARY_PROFESSIONS = {
    ["Alchemy"] = true,
    ["Blacksmithing"] = true,
    ["Enchanting"] = true,
    ["Engineering"] = true,
    ["Herbalism"] = true,
    ["Leatherworking"] = true,
    ["Mining"] = true,
    ["Skinning"] = true,
    ["Tailoring"] = true,
}

-- Skill line ID -> the canonical name above (#177). The profession IDs are the
-- Professions plugin's (AltStableProfessions.lua LINES), measured on the
-- client; on this skill list Enchanting, Tailoring, Herbalism, Leatherworking,
-- Skinning and the three secondaries were (forever-api-notes.md). Riding is
-- 762 in every version, not measured here. ScanSkills falls back to the
-- English name for an ID that is not in this table.
local SKILL_BY_ID = {
    [171] = "Alchemy",   [164] = "Blacksmithing",  [333] = "Enchanting",
    [202] = "Engineering", [182] = "Herbalism",    [165] = "Leatherworking",
    [186] = "Mining",    [393] = "Skinning",       [197] = "Tailoring",
    [356] = "Fishing",   [185] = "Cooking",        [129] = "First Aid",
    [762] = "Riding",
}
local KNOWN_SKILL = {}
for _, name in pairs(SKILL_BY_ID) do KNOWN_SKILL[name] = true end

-- All trackable professions for flat field reset
local ALL_PROFESSIONS = {
    "Alchemy","Blacksmithing","Enchanting","Engineering",
    "Herbalism","Leatherworking","Mining","Skinning","Tailoring",
}

------------------------------------------------------------
-- Gear slots
------------------------------------------------------------

-- ONE table, published on AltStable, because the Roster's detail pane needs the
-- same seventeen slots in the same order and had its own copy - seventeen rows
-- of id/key duplicated, which is seventeen chances for the two to disagree
-- about what `gearid_back` means.
--
-- `id` is the client's inventory slot, which is what the scanner reads and what
-- an item tooltip needs. `label` and `side` are the paper doll's, and the ORDER
-- is the paper doll's too: down the left, down the right, weapons along the
-- bottom. The scanner does not care about the order, so the reader that does
-- gets to set it.
AltStable.GEAR_SLOTS = {
    { id=1,  key="head",     label="Head",      side="left"   },
    { id=2,  key="neck",     label="Neck",      side="left"   },
    { id=3,  key="shoulder", label="Shoulder",  side="left"   },
    { id=15, key="back",     label="Back",      side="left"   },
    { id=5,  key="chest",    label="Chest",     side="left"   },
    { id=9,  key="wrist",    label="Wrist",     side="left"   },
    { id=10, key="hands",    label="Hands",     side="right"  },
    { id=6,  key="waist",    label="Waist",     side="right"  },
    { id=7,  key="legs",     label="Legs",      side="right"  },
    { id=8,  key="feet",     label="Feet",      side="right"  },
    { id=11, key="ring1",    label="Ring 1",    side="right"  },
    { id=12, key="ring2",    label="Ring 2",    side="right"  },
    { id=13, key="trinket1", label="Trinket 1", side="bottom" },
    { id=14, key="trinket2", label="Trinket 2", side="bottom" },
    { id=16, key="mainhand", label="Main Hand", side="bottom" },
    { id=17, key="offhand",  label="Off Hand",  side="bottom" },
    { id=18, key="ranged",   label="Ranged",    side="bottom" },
}
local GEAR_SLOTS = AltStable.GEAR_SLOTS

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return 0 end
    local id = link:match("item:(%d+)")
    return tonumber(id) or 0
end

------------------------------------------------------------
-- Permanent enchant + gems, packed for sync
--
-- The TBC itemString is
--   item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:...
-- The capture below is deliberately NOT anchored: it has to match inside
-- the full "|cff...|Hitem:...|h[Name]|h|r" hyperlink wrapper. [^:|]* (not
-- %d+) is required because any of these fields may be empty, and the tail
-- is left unanchored so extra client-version fields don't break the match.
--
-- TBC caps items at three sockets, so only gem1..gem3 are stored; gem4 is
-- captured purely so a non-zero value can be spotted rather than silently
-- ignored.
------------------------------------------------------------

local SOCKET_STAT_KEYS = {
    "EMPTY_SOCKET_RED", "EMPTY_SOCKET_YELLOW", "EMPTY_SOCKET_BLUE",
    "EMPTY_SOCKET_META", "EMPTY_SOCKET_PRISMATIC",
}

-- Socket count for an item, or nil when it can't be resolved yet.
-- Deliberately queried against a BARE "item:<id>" string rather than the
-- equipped link: with no gems attached, the EMPTY_SOCKET_* counts are the
-- item template's total sockets under either interpretation of the API,
-- so the arithmetic doesn't depend on whether GetItemStats reports total
-- or merely-remaining sockets for a gemmed link.
local function SocketCount(itemID)
    if not itemID or itemID == 0 then return nil end
    if type(GetItemStats) ~= "function" then return nil end
    local ok, stats = pcall(GetItemStats, "item:" .. itemID)
    if not ok or type(stats) ~= "table" then return nil end
    local n = 0
    for _, key in ipairs(SOCKET_STAT_KEYS) do
        n = n + (tonumber(stats[key]) or 0)
    end
    return n
end

-- Pack into "<ench>:<sockets>:<g1>:<g2>:<g3>". An unresolved socket count is
-- written as "?" and MUST NOT be written as 0 -- a false zero permanently
-- hides a missing gem, which is exactly the bug a cache miss would cause.
-- Returns enchantID, gem1, gem2, gem3, gem4 -- all numbers, 0 when absent.
-- gem4 is returned (not silently dropped) so the "no TBC item has a fourth
-- socket" assumption is testable rather than implicit.
local function ParseItemMods(link)
    if type(link) ~= "string" then return 0, 0, 0, 0, 0 end

    local ench, g1, g2, g3, g4 =
        link:match("item:[^:|]+:([^:|]*):([^:|]*):([^:|]*):([^:|]*):([^:|]*)")

    return tonumber(ench) or 0, tonumber(g1) or 0, tonumber(g2) or 0,
           tonumber(g3) or 0, tonumber(g4) or 0
end

local function PackGearMod(link, itemID)
    if type(link) ~= "string" or link == "" then return "" end

    local ench, g1, g2, g3 = ParseItemMods(link)
    local sockets = SocketCount(itemID)

    return string.format("%d:%s:%d:%d:%d",
        ench, sockets and tostring(sockets) or "?", g1, g2, g3)
end

-- Re-pack a slot once its item lands in the client cache, so an unresolved
-- "?" socket count becomes a real one. Called from the GET_ITEM_INFO_RECEIVED
-- retry in Core.lua.
function AltStable.RepackGearMod(link, itemID)
    return PackGearMod(link, itemID)
end

-- The enchant on an equipped slot, IN WORDS (#94): "Stamina +2", not 41.
--
-- gearmod_ carries the enchant id, and nothing on this client maps an id to a
-- name. The tooltip does, and C_TooltipInfo returns it as typed lines - measured
-- on 1.60.1.70291 (/asprobe enchant): the permanent enchant is its own line type,
-- Enum.TooltipDataLineType.ItemEnchantmentPermanent (15), with leftText
-- "Enchanted: Stamina +2" and enchantID matching the link's field. An ordinary
-- green "Equip:" line is type 0, so there is nothing to tell apart by colour.
--
-- Returns the words, "" for a slot whose tooltip has no enchant line, or nil
-- when the client cannot say (no API, no lines yet). The scan has already reset
-- the field to "", so words from the item worn before can never survive a swap;
-- the Roster falls back to the enchant id in gearmod_ to say "enchanted".
local ENCHANT_LINE = (Enum and Enum.TooltipDataLineType
    and Enum.TooltipDataLineType.ItemEnchantmentPermanent) or 15

local function EnchantText(slotID)
    local get = C_TooltipInfo and C_TooltipInfo.GetInventoryItem
    if type(get) ~= "function" then return nil end
    local ok, data = pcall(get, "player", slotID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    for _, line in ipairs(data.lines) do
        if line.type == ENCHANT_LINE and type(line.leftText) == "string" then
            local text = line.leftText
                :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                :gsub("[\r\n]", " ")   -- one record line per field on the wire
            -- The client's own label, localised: "Enchanted: %s" on enUS.
            local fmt = type(ENCHANTED_TOOLTIP_LINE) == "string" and ENCHANTED_TOOLTIP_LINE
                or "Enchanted: %s"
            local prefix = fmt:match("^(.-)%%s")
            if prefix and prefix ~= "" and text:sub(1, #prefix) == prefix then
                text = text:sub(#prefix + 1)
            end
            return text
        end
    end
    return ""
end

-- Re-read once the item is cached; same retry as RepackGearMod.
function AltStable.RereadEnchantText(slotKey)
    for _, slot in ipairs(GEAR_SLOTS) do
        if slot.key == slotKey then return EnchantText(slot.id) end
    end
end

-- Test seam (harmless in-game), mirroring AltStable._test in Core.lua.
AltStable._testScanner = {
    EnchantText   = EnchantText,
    ParseItemMods = ParseItemMods,
    PackGearMod   = PackGearMod,
    SocketCount   = SocketCount,
    GEAR_SLOTS    = GEAR_SLOTS,
}

local function ReadPlayerDisplayID()
    local id

    if type(C_PlayerInfo) == "table" and type(C_PlayerInfo.GetDisplayID) == "function" then
        local ok, value = pcall(C_PlayerInfo.GetDisplayID, "player")
        if ok then
            id = tonumber(value)
            if id and id > 0 then return id end
        end
        ok, value = pcall(C_PlayerInfo.GetDisplayID)
        if ok then
            id = tonumber(value)
            if id and id > 0 then return id end
        end
    end

    if type(UnitDisplayID) == "function" then
        local ok, value = pcall(UnitDisplayID, "player")
        if ok then
            id = tonumber(value)
            if id and id > 0 then return id end
        end
    end

    if type(GetPlayerModelDisplayInfo) == "function" then
        local ok, value = pcall(GetPlayerModelDisplayInfo)
        if ok then
            id = tonumber(value)
            if id and id > 0 then return id end
        end
    end

    return 0
end

local modelPathProbeFrame
local modelPathRetryScheduled = false

local function EnsureModelPathProbeFrame()
    if modelPathProbeFrame then
        return modelPathProbeFrame
    end
    if type(CreateFrame) ~= "function" then
        return nil
    end
    local parent = UIParent or WorldFrame
    if not parent then
        return nil
    end

    local frame = CreateFrame("PlayerModel", nil, parent)
    if not frame then
        local ok
        ok, frame = pcall(CreateFrame, "DressUpModel", nil, parent)
        if not ok then
            frame = nil
        end
    end
    if not frame then
        return nil
    end

    frame:SetSize(1, 1)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    frame:Hide()
    modelPathProbeFrame = frame
    return modelPathProbeFrame
end

local function PrimeProbeForPlayerModelPath()
    local probe = EnsureModelPathProbeFrame()
    if not probe or type(probe.SetUnit) ~= "function" then
        return nil
    end

    if type(probe.ClearModel) == "function" then
        pcall(probe.ClearModel, probe)
    end
    if type(probe.Show) == "function" then
        probe:Show()
    end

    local ok = pcall(probe.SetUnit, probe, "player")
    if not ok then
        if type(probe.Hide) == "function" then
            probe:Hide()
        end
        return nil
    end
    return probe
end

local function ReadModelPathFromProbe(probe)
    if not probe or type(probe.GetModel) ~= "function" then
        return ""
    end
    local okModel, modelPath = pcall(probe.GetModel, probe)
    if okModel and type(modelPath) == "string" and modelPath ~= "" then
        return modelPath
    end
    return ""
end

local function ReadPlayerModelPathFromProbe()
    local probe = PrimeProbeForPlayerModelPath()
    if not probe then
        return ""
    end

    local modelPath = ReadModelPathFromProbe(probe)
    if type(probe.Hide) == "function" then
        probe:Hide()
    end
    return modelPath
end

local function ReadPlayerModelPath()
    if type(UnitModel) == "function" then
        local ok, value = pcall(UnitModel, "player")
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return ReadPlayerModelPathFromProbe()
end

local function QueueModelPathRetry(guid)
    if modelPathRetryScheduled then return end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end

    local probe = PrimeProbeForPlayerModelPath()
    if not probe then
        return
    end

    modelPathRetryScheduled = true
    C_Timer.After(0.3, function()
        modelPathRetryScheduled = false

        local modelPath = ReadModelPathFromProbe(probe)
        if type(probe.Hide) == "function" then
            probe:Hide()
        end
        if modelPath == "" then
            return
        end

        local char = AltStableDB and AltStableDB[guid]
        if not char then
            return
        end
        if char.modelPath == modelPath then
            return
        end

        char.modelPath = modelPath
        if AltStable.RefreshSheet then
            AltStable.RefreshSheet()
        end
    end)
end

local function ResetCharacter(char)

    -- primary professions (legacy fields kept for compat)
    char.prof1 = ""
    char.prof2 = ""
    char.prof1Skill = 0
    char.prof2Skill = 0
    char.prof1Max = 0
    char.prof2Max = 0

    -- flat per-profession fields used by new columns
    for _, name in ipairs(ALL_PROFESSIONS) do
        char["prof_"..name]    = nil
        char["profmax_"..name] = nil
    end

    -- secondary professions
    char.fishing = 0
    char.fishingMax = 0
    char.cooking = 0
    char.cookingMax = 0
    char.firstAid = 0
    char.firstAidMax = 0
    char.riding = 0
    char.ridingMax = 0

    -- gear slots
    for _, slot in ipairs(GEAR_SLOTS) do
        char["gear_"..slot.key]     = 0
        char["gearq_"..slot.key]    = 0   -- item quality (5 = legendary)
        char["gearid_"..slot.key]   = 0   -- compact item id (safe to sync)
        char["gearname_"..slot.key] = ""   -- item name (gear tooltips)
        char["gearsubtype_"..slot.key] = ""  -- item subtype ("Dagger", "Mail", ...) — authoritative gear type
        char["gearlink_"..slot.key] = ""   -- full item link (for tooltips)
        char["gearmod_"..slot.key]  = ""   -- packed "ench:sockets:g1:g2:g3" (synced)
        char["gearench_"..slot.key] = ""   -- the enchant in words, "" for none (synced, #94)
    end

    -- Helm/cloak display toggles. 1 = hidden, 0 = shown.
    -- Numbers, not booleans: DeserializeChar coerces with tonumber and falls back to the raw
    -- string, so a boolean would arrive at a peer as the STRING "true" while staying a real
    -- boolean locally (the asymmetry restedArea already has). 1/0 round-trips as a number.
    -- Named for the HIDDEN state so absent (record predates the field, or a peer on an older
    -- build) reads as 0 = shown = the behaviour before this existed.
    char.hidehelm  = 0
    char.hidecloak = 0

end

-- Skill lines: secondary skills, riding, and the primary professions.
--
-- Split out of ScanCharacter so it can be driven directly in tests. All of
-- ScanCharacter needs ~30 stubbed APIs; this needs two, and it is where the
-- tuple-to-struct change actually bites.
function AltStable.ScanSkills(char)
    local primaryCount = 0
    local seen = {}

    for i = 1, GetNumSkillLines() do

        -- One struct, not the old 7-value tuple. Destructuring positionally
        -- here would yield nil for every field and silently record no
        -- professions at all, which is why this is read by name.
        local info = GetSkillLineInfo(i)
        local skillName = info and info.name
        local rank      = info and info.rank
        -- maxRank is dynamic for weapon and defense skills (5 x level), so it
        -- is read per line rather than assumed to be a cap.
        local maxRank   = info and info.maxRank

        -- Matched by skill ID (#177), turned into the canonical English name
        -- the saved fields, the sync and the export are keyed by. By name it
        -- matched nothing on a French or German client - and on every client
        -- it matched each profession TWICE: Forever lists a base line and a
        -- 29xx line under one name (Enchanting 333 and 2940, in either order;
        -- measured 70205, same rank and max on both), so prof1 and prof2 were
        -- one profession and the second one was lost (Export reads those).
        -- A base ID names the skill. A line whose ID is not in the table falls
        -- back to its name when that is one of the English names - not every
        -- ID was measured on this list (Alchemy, Blacksmithing, Engineering,
        -- Mining, Riding), and an English client must not lose what the name
        -- used to find. A 29xx twin can pass that way too, which is harmless:
        -- same rank, and a name is never counted twice.
        if info and not info.isHeader then
            skillName = SKILL_BY_ID[info.skillID]
                or (KNOWN_SKILL[skillName] and skillName) or nil
            if skillName and seen[skillName] then skillName = nil end
            if skillName then seen[skillName] = true end
        end

        if info and not info.isHeader and skillName then

            if skillName == "Fishing" then
                char.fishing = rank or 0
                char.fishingMax = maxRank or 0

            elseif skillName == "Cooking" then
                char.cooking = rank or 0
                char.cookingMax = maxRank or 0

            elseif skillName == "First Aid" then
                char.firstAid = rank or 0
                char.firstAidMax = maxRank or 0

            elseif skillName == "Riding" then
                char.riding = rank or 0
                char.ridingMax = maxRank or 0

            elseif PRIMARY_PROFESSIONS[skillName] then

                primaryCount = primaryCount + 1

                -- Flat field for new column layout
                char["prof_"..skillName]    = rank or 0
                char["profmax_"..skillName] = maxRank or 0

                if primaryCount == 1 then
                    char.prof1 = skillName
                    char.prof1Skill = rank or 0
                    char.prof1Max = maxRank or 0

                elseif primaryCount == 2 then
                    char.prof2 = skillName
                    char.prof2Skill = rank or 0
                    char.prof2Max = maxRank or 0
                end
            end
        end
    end
end

------------------------------------------------------------
-- The pet (#75): enough to draw a hunter's beast or a warlock's demon in the
-- Roster scene with nobody logged in.
--
-- MEASURED on 1.60.1.70124 (Tools/AltStableProbe/Pets.lua):
--   * A creature's texture is baked into its model, so a saved DISPLAY ID
--     renders the pet fully textured offline - unlike a player's (#15).
--   * A hunter pet's GUID carries the generic npc 165189 for EVERY beast; the
--     real look is the stable's: C_StableInfo.GetStablePetInfo(slot).displayID.
--     SetCreature(creatureID) is NOT a substitute - it picks a random skin of
--     the creature (251245 drew a red cat for a blue one).
--   * Which active slot is out: the GUID's last six hex digits are the slot's
--     petNumber; the current Call Pet spell is the second witness. NOT the
--     name - two pets may share one (the owner's cat and bear do).
--   * A demon's GUID carries its real npc (voidwalker 1860), and a PlayerModel
--     resolves that to its single display id on the spot (1860 -> 1132).
------------------------------------------------------------

local PET_CLASSES = { HUNTER = true, WARLOCK = true }
local CALL_PET = { 883, 83242, 83243, 83244, 83245 }   -- Call Pet 1..5, as Blizzard_StableUI lists them

local function StableSlot(slot)
    if not (C_StableInfo and type(C_StableInfo.GetStablePetInfo) == "function") then return nil end
    local ok, info = pcall(C_StableInfo.GetStablePetInfo, slot)
    if ok and type(info) == "table" then return info end
end

local function HunterPet(guid)
    local tail = guid:match("%-(%x+)$")
    local number = tail and #tail >= 6 and tonumber(tail:sub(-6), 16)
    if number then
        for slot = 1, #CALL_PET do
            local info = StableSlot(slot)
            if info and info.petNumber == number then return info end
        end
    end
    if C_Spell and type(C_Spell.IsCurrentSpell) == "function" then
        for slot, spell in ipairs(CALL_PET) do
            local ok, current = pcall(C_Spell.IsCurrentSpell, spell)
            if ok and current then return StableSlot(slot) end
        end
    end
end

local demonModel
local function DemonDisplayID(npc)
    if type(CreateFrame) ~= "function" then return nil end
    if not demonModel then
        local ok, f = pcall(CreateFrame, "PlayerModel", nil, UIParent)
        if not ok or not f then return nil end
        f:SetSize(1, 1)
        f:Hide()
        demonModel = f
    end
    local ok = pcall(demonModel.SetCreature, demonModel, npc)
    if not ok then return nil end
    local okD, id = pcall(demonModel.GetDisplayInfo, demonModel)
    id = okD and tonumber(id)
    pcall(demonModel.ClearModel, demonModel)
    return (id and id > 0) and id or nil
end

-- display id, npc, name of the pet that is out now - or nil.
local function ReadPet(classFile)
    if not PET_CLASSES[classFile] or not UnitExists or not UnitExists("pet") then return nil end
    local guid = UnitGUID("pet")
    if type(guid) ~= "string" then return nil end
    local name = UnitName("pet")
    if classFile == "HUNTER" then
        local info = HunterPet(guid)
        local display = info and tonumber(info.displayID)
        if not display or display <= 0 then return nil end
        return display, tonumber(info.creatureID), name
    end
    local npc = tonumber((select(6, strsplit("-", guid))))   -- one value: a second would be read as the base
    local display = npc and DemonDisplayID(npc)
    if not display then return nil end
    return display, npc, name
end
AltStable.ReadPet = ReadPet

function AltStable.ScanCharacter()

    AltStableDB = AltStableDB or {}

    local guid = UnitGUID("player")
    -- Both halves of the name: on 1.60.1.70009 the surname is UnitName's
    -- second return, and taking only the first stored "Kaleid" for a character
    -- every other client (and the whitelist) calls "Kaleid Sumner".
    local name = API.PlayerFullName()
    local realm = GetRealmName()

    if not guid then
        return
    end

    --------------------------------------------------------
    -- Use GUID as unique character key
    --------------------------------------------------------

    AltStableDB[guid] = AltStableDB[guid] or {}
    local char = AltStableDB[guid]

    char.guid = guid
    -- This client scans this character, so its local record is the authority:
    -- the merge will not let a peer's echo of it overwrite it unless strictly
    -- newer. Local-only - never serialized.
    char.scannedHere = true
    char.name = name
    char.realm = realm

    -- Account number: set once with /alts account 1 (or 2, etc.)
    -- Stored globally so all chars on this client share the same value.
    AltStableConfig = AltStableConfig or {}
    char.account = AltStableConfig.accountNumber or ""

    --------------------------------------------------------
    -- Basic character info
    --------------------------------------------------------

    local classLocalized, classFile = UnitClass("player")
    char.class = classFile

    -- UnitRace returns (localizedName, fileName). Both are worth keeping:
    -- Forever's Skyborne is ONE race key with two faction-dependent display
    -- names - "High Order Skyborne" and "Windshaper Skyborne" both report
    -- fileName "Skyborne" - so no key-to-name table can render it correctly.
    local raceLocalized, raceFile = UnitRace("player")
    char.race = raceFile
    char.raceKey = char.race or ""
    char.raceName = raceLocalized or ""

    -- Faction from the CLIENT, not inferred from the race. Forever's Skyborne is
    -- one race key on both sides ("High Order Skyborne" / "Windshaper
    -- Skyborne"), so any race-to-faction table gets one of them wrong - and gets
    -- it wrong silently, in an export the user pastes into a spreadsheet.
    -- The tag is the English "Horde"/"Alliance"; the second return is localized
    -- and deliberately not stored.
    if UnitFactionGroup then
        char.faction = UnitFactionGroup("player") or char.faction
    end

    -- Gender: 2 = male, 3 = female
    local gender = UnitSex("player")
    char.gender = (gender == 3) and "Female" or "Male"
    char.sexID = (gender == 3) and 1 or 0

    -- Compact appearance fields for offline model reconstruction (sync-safe).
    -- These are tiny values and ride through the normal character serializer.
    char.displayid = ReadPlayerDisplayID()

    -- Model path capture is two-phase because the model file load is
    -- asynchronous in TBC Classic 2.5.x. The synchronous read often
    -- returns "" because the file is still streaming in. The retry
    -- queue (QueueModelPathRetry) waits 0.3s and reads again — by
    -- which time the file has loaded.
    --
    -- Strategy: try synchronously first (cheap, sometimes wins), and
    -- ALWAYS queue a retry to overwrite with the deferred value if the
    -- sync read didn't already produce a non-empty path. The retry is
    -- idempotent (no-op if char.modelPath is already correct).
    local modelPath = ReadPlayerModelPath()
    if modelPath ~= "" then
        char.modelPath = modelPath
    elseif type(char.modelPath) ~= "string" then
        char.modelPath = ""
    end
    -- ALWAYS queue retry on first scan after login: the previous-session
    -- modelPath in saved variables may be stale (race-change, expansion
    -- model rev, etc.) and the deferred value is more authoritative.
    QueueModelPathRetry(guid)

    char.level = UnitLevel("player")

    --------------------------------------------------------
    -- Guild
    --------------------------------------------------------

    local guild = GetGuildInfo("player")
    char.guild = guild or ""

    -- No spec: GetNumTalentTabs / GetTalentTabInfo are gone on Forever, so the
    -- old talent-tab scan wrote "" for every character. Which of
    -- C_SpecializationInfo / C_ClassTalents returns Vanilla trees is unresolved.

    --------------------------------------------------------
    -- Item level
    --------------------------------------------------------

    if GetAverageItemLevel then
        local ilvl = select(2, GetAverageItemLevel())
        char.ilvl = ilvl
    end

    --------------------------------------------------------
    -- Money
    --------------------------------------------------------

    char.money = plain(GetMoney())

    --------------------------------------------------------
    -- Rested XP
    --
    -- We store the current snapshot plus enough context to
    -- extrapolate rested XP forward for this character while
    -- they're offline.  See RowRenderer for the extrapolation.
    --   restXP       : current rested XP (raw)
    --   restPercent  : rested as % of XP-to-next-level (0..150)
    --   xpMax        : UnitXPMax at scan time — needed so the
    --                  renderer can re-divide if the restXP
    --                  value is still useful offline
    --   restedArea   : true if the character was in an inn /
    --                  rested-state zone at scan time.  In TBC,
    --                  rested XP accrues at 2x the normal rate
    --                  while in a rested area.
    --   restTimestamp: when the snapshot was taken.  Normally
    --                  the same as lastUpdate but kept separate
    --                  so we can always trust it for the
    --                  offline extrapolation math.
    --------------------------------------------------------

    -- A maximum of 0 can't be divided by (and 0 is truthy, so `or 1` never
    -- caught it). At the cap it is real: there is no next level, so the
    -- snapshot is zero. Below the cap it is a bad read, and the last good
    -- snapshot is kept rather than replaced with a percentage of nothing.
    -- `rested` unreadable is NOT zero: writing 0 here would overwrite a good
    -- snapshot and sync that zero to the other account. Unlike the live event
    -- path there is no suspicious-zero guard to catch it afterwards.
    local rested = plain(GetXPExhaustion())
    local nextXP = plain(UnitXPMax("player")) or 0
    local currentXP = plain(UnitXP("player")) or 0

    if rested ~= nil and nextXP > 0 then
        char.restXP = rested
        char.restPercent = math.floor((rested / nextXP) * 100)
        char.xpMax = nextXP
        char.xpPercent = math.floor((currentXP / nextXP) * 100)
        char.restedArea = IsResting and IsResting() or false
        char.restTimestamp = time()
    elseif (UnitLevel("player") or 0) >= AltStable.API.LevelCap() then
        char.restXP, char.restPercent, char.xpMax, char.xpPercent = 0, 0, 0, 0
        char.restedArea = IsResting and IsResting() or false
        char.restTimestamp = time()
    end

    --------------------------------------------------------
    -- Reset profession data
    --------------------------------------------------------

    ResetCharacter(char)

    --------------------------------------------------------
    -- Core stat snapshot (for offline detail view)
    --------------------------------------------------------

    char.stat_str = plain((select(2, UnitStat("player", 1))))
    char.stat_agi = plain((select(2, UnitStat("player", 2))))
    char.stat_sta = plain((select(2, UnitStat("player", 3))))
    char.stat_int = plain((select(2, UnitStat("player", 4))))
    char.stat_spi = plain((select(2, UnitStat("player", 5))))

    char.stat_hp = plain(UnitHealthMax("player"))

    local manaMax
    if UnitPowerMax then
        manaMax = plain(UnitPowerMax("player", 0))
    elseif UnitManaMax then
        manaMax = plain(UnitManaMax("player"))
    elseif UnitMana then
        manaMax = plain(UnitMana("player"))
    end
    char.stat_mana = manaMax

    char.stat_armor = plain((select(2, UnitArmor("player"))))

    -- A sum, so one secret component makes the whole thing unknown.
    char.stat_ap = plainSum(UnitAttackPower("player"))

    local spellPower
    if GetSpellBonusDamage then
        for school = 2, 7 do
            local sp = plain(GetSpellBonusDamage(school))
            -- The comparison is the danger here: `sp > spellPower` on a secret
            -- throws exactly like the arithmetic did.
            if sp and (not spellPower or sp > spellPower) then spellPower = sp end
        end
    end
    char.stat_sp = spellPower

    char.stat_defense = plainSum(UnitDefenseSkill("player"))

    -- Crit and hit, for the detail pane's Combat section (#91).
    --
    -- Both exist in Vanilla and are read from the player directly. The two
    -- stats beside them in AltTracker's table do NOT come across: there is no
    -- haste rating pre-TBC, and resilience is a TBC PvP stat - so they are
    -- absent here rather than scanned as zero, which would have the pane
    -- reporting a real 0% for something the game does not have.
    --
    -- Melee crit is the honest one to show: GetSpellCritChance takes a school
    -- and the pane has one row, so picking a school would be arbitrary.
    -- Crit only. GetCritChance has a verified producer: observed live on
    -- 1.60.1.70009 reporting 1.66%, a real value rather than a
    -- rating-derived zero, which is what Core's RETIRED_FIELDS note asked for
    -- before taking a field off that list.
    --
    -- GetHitModifier is scanned now. MEASURED on 1.60.1.70009:
    --
    --     /run print(GetHitModifier and GetHitModifier() or "ABSENT")
    --     0
    --
    -- Zero, not "ABSENT" and not nil - so the function exists and returns a
    -- number, which is the build-verified producer Core's RETIRED_FIELDS note
    -- asked for before taking a field off that list.
    --
    -- It is the BONUS hit from gear, so zero is the right answer for a character
    -- with none, and a nonzero reading is still unobserved. The pane decides
    -- whether to draw it (no allowZero, so a zero hides the row); the scanner's
    -- job is only to store what the client says.
    --
    -- Guarded like GetCritChance beside it, and for the same reason: the scan
    -- runs at login before anything else works, and neither is guaranteed on
    -- every build.
    if GetCritChance then
        char.stat_crit = plain(GetCritChance())
    end
    if GetHitModifier then
        char.stat_hitpct = plain(GetHitModifier())
    end

    --------------------------------------------------------
    -- Scan professions
    --------------------------------------------------------

    AltStable.ScanSkills(char)

    --------------------------------------------------------
    -- Reputations
    --------------------------------------------------------

    if AltStable.ScanReputations then
        AltStable.ScanReputations(char)
    end

    -- Craft cooldowns are captured by the Professions plugin's trade-skill scan
    -- (C_TradeSkillUI.GetRecipeCooldown on every learned recipe, window open),
    -- stored as cd_<Profession>@<recipe name> on the character record, and shown
    -- by RowRenderer. No hand-maintained allowlist.

    --------------------------------------------------------
    -- Gear slots — item level per slot
    -- GetItemInfo can return nil at login if the item isn't in the
    -- client cache yet. We track whether any slots are still pending
    -- so we can retry once the cache is populated.
    --------------------------------------------------------

    -- Slots that returned nil from GetItemInfo. Keyed by SLOT KEY, not by link:
    -- two identical rings/trinkets/weapons share one link, and a link-keyed table
    -- silently drops one of the two slots' retries.
    local pendingSlots = {}

    for _, slot in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink("player", slot.id)
        if link then
            local itemID = ItemIDFromLink(link)
            char["gearid_"..slot.key] = itemID
            char["gearlink_"..slot.key] = link
            -- Enchant and gem IDs come straight out of the link, so they resolve
            -- even while the item itself is uncached; only the socket count inside
            -- PackGearMod can come back unresolved ("?").
            char["gearmod_"..slot.key] = PackGearMod(link, itemID)
            local words = EnchantText(slot.id)
            if words then char["gearench_"..slot.key] = words end
            local itemName, _, quality, ilvl, _, _, itemSubType = GetItemInfo(link)
            if ilvl then
                char["gear_"..slot.key]      = ilvl
                char["gearq_"..slot.key]     = quality or 0
                char["gearname_"..slot.key]  = itemName or ""
                char["gearsubtype_"..slot.key] = itemSubType or ""
            else
                -- Item link exists but item data isn't cached yet. Keep the
                -- existing ilvl/quality/name/subtype values and retry on cache event.
                pendingSlots[slot.key] = link
            end
        else
            char["gear_"..slot.key]      = 0
            char["gearq_"..slot.key]     = 0
            char["gearid_"..slot.key]    = 0
            char["gearname_"..slot.key]  = ""
            char["gearsubtype_"..slot.key] = ""
            char["gearlink_"..slot.key]  = ""
            char["gearmod_"..slot.key]   = ""
            char["gearench_"..slot.key]  = ""
        end
    end

    -- Helm/cloak display toggles. A portrait pipeline needs these because the equipment
    -- list alone cannot say a slot is hidden: a character with the helm hidden would
    -- otherwise be drawn wearing a helmet they never see in game. Synced on purpose — a
    -- pipeline reads ONE aggregator account, so an alt's toggle has to ride sync to reach it.
    -- Guarded: these are TBC-era APIs, and a missing global must not abort the whole scan.
    char.hidehelm  = (ShowingHelm  and not ShowingHelm())  and 1 or 0
    char.hidecloak = (ShowingCloak and not ShowingCloak()) and 1 or 0

    -- The pet (#75). The LAST one seen out, not only one out right now: every
    -- character the Roster shows is logged out, and one who logged out with the
    -- pet dismissed, dead or not yet resummoned would otherwise lose it. A new
    -- summon overwrites it. Flat fields, because the serializer drops tables.
    local petDisplay, petNpc, petName = ReadPet(classFile)
    if petDisplay then
        char.pet_display = petDisplay
        char.pet_npc     = petNpc
        char.pet_name    = petName
    end

    -- Only stamp lastUpdate when we have complete data.
    -- If any items are pending cache we deliberately leave the timestamp
    -- unchanged so peers don't reject a later corrected version.
    if not next(pendingSlots) then
        char.lastUpdate = time()
    end

    -- Register for cache-ready events to fill in pending slots
    if next(pendingSlots) then
        AltStable.PendingGearSlots = AltStable.PendingGearSlots or {}
        for key, link in pairs(pendingSlots) do
            AltStable.PendingGearSlots[key] = { link = link, guid = char.guid }
        end
    end

    return char

end