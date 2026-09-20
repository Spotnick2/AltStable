AltStable = AltStable or {}

-- Retail-API adapters. Taken as file-locals so call sites below read the same
-- as they always did; see Compat.lua for why these are not globals.
local API = AltStable.API
local GetNumSkillLines = API.GetNumSkillLines
local GetSkillLineInfo = API.GetSkillLineInfo
local UnitDefenseSkill = API.UnitDefenseSkill
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
    ["Jewelcrafting"] = true,
}

-- All trackable professions for flat field reset
local ALL_PROFESSIONS = {
    "Alchemy","Blacksmithing","Enchanting","Engineering",
    "Herbalism","Leatherworking","Mining","Skinning","Tailoring","Jewelcrafting",
}

------------------------------------------------------------
-- Gear slots
------------------------------------------------------------

local GEAR_SLOTS = {
    { id=1,  key="head"     },
    { id=2,  key="neck"     },
    { id=3,  key="shoulder" },
    { id=15, key="back"     },
    { id=5,  key="chest"    },
    { id=9,  key="wrist"    },
    { id=10, key="hands"    },
    { id=6,  key="waist"    },
    { id=7,  key="legs"     },
    { id=8,  key="feet"     },
    { id=11, key="ring1"    },
    { id=12, key="ring2"    },
    { id=13, key="trinket1" },
    { id=14, key="trinket2" },
    { id=16, key="mainhand" },
    { id=17, key="offhand"  },
    { id=18, key="ranged"   },
}

local function Round2(value)
    return math.floor((tonumber(value) or 0) * 100 + 0.5) / 100
end

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

-- Test seam (harmless in-game), mirroring AltStable._test in Core.lua.
AltStable._testScanner = {
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
        char["gearname_"..slot.key] = ""   -- item name (for BiS matching)
        char["gearsubtype_"..slot.key] = ""  -- item subtype ("Dagger", "Mail", ...) — authoritative gear type
        char["gearlink_"..slot.key] = ""   -- full item link (for tooltips)
        char["gearmod_"..slot.key]  = ""   -- packed "ench:sockets:g1:g2:g3" (synced)
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

function AltStable.ScanCharacter()

    AltStableDB = AltStableDB or {}

    local guid = UnitGUID("player")
    local name = UnitName("player")
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

    char.race = select(2, UnitRace("player"))
    char.raceKey = char.race or ""

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

    --------------------------------------------------------
    -- Active spec (talent tree with most points)
    --------------------------------------------------------

    local maxPoints = 0
    local specName  = ""
    local specIcon  = ""
    if GetNumTalentTabs then
        for tab = 1, GetNumTalentTabs() do
            -- TBC Classic returns: id, name, description, icon, pointsSpent, ...
            local _, tabName, _, iconTexture, pointsSpent = GetTalentTabInfo(tab)
            pointsSpent = tonumber(pointsSpent) or 0
            if pointsSpent > maxPoints then
                maxPoints  = pointsSpent
                specName   = tabName or ""
                specIcon   = iconTexture or ""
            end
        end
    end
    char.spec     = specName
    char.specIcon = specIcon

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

    char.money = GetMoney()

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

    local rested = GetXPExhaustion() or 0
    local nextXP = UnitXPMax("player") or 1

    char.restXP = rested
    char.restPercent = math.floor((rested / nextXP) * 100)
    char.xpMax = nextXP
    char.restedArea = IsResting and IsResting() or false
    char.restTimestamp = time()

    -- XP progress toward next level (0-100%), only meaningful below cap
    local currentXP = UnitXP("player") or 0
    char.xpPercent = math.floor((currentXP / nextXP) * 100)

    --------------------------------------------------------
    -- Reset profession data
    --------------------------------------------------------

    ResetCharacter(char)

    --------------------------------------------------------
    -- Core stat snapshot (for offline detail view)
    --------------------------------------------------------

    local _, statStr = UnitStat("player", 1)
    local _, statAgi = UnitStat("player", 2)
    local _, statSta = UnitStat("player", 3)
    local _, statInt = UnitStat("player", 4)
    local _, statSpi = UnitStat("player", 5)

    char.stat_str = statStr or 0
    char.stat_agi = statAgi or 0
    char.stat_sta = statSta or 0
    char.stat_int = statInt or 0
    char.stat_spi = statSpi or 0

    char.stat_hp = UnitHealthMax("player") or 0

    local manaMax = 0
    if UnitPowerMax then
        manaMax = UnitPowerMax("player", 0) or 0
    elseif UnitManaMax then
        manaMax = UnitManaMax("player") or 0
    elseif UnitMana then
        manaMax = UnitMana("player") or 0
    end
    char.stat_mana = manaMax

    local _, effectiveArmor = UnitArmor("player")
    char.stat_armor = effectiveArmor or 0

    local baseAP, posAP, negAP = UnitAttackPower("player")
    char.stat_ap = (baseAP or 0) + (posAP or 0) + (negAP or 0)

    local spellPower = 0
    if GetSpellBonusDamage then
        for school = 2, 7 do
            local sp = GetSpellBonusDamage(school) or 0
            if sp > spellPower then
                spellPower = sp
            end
        end
    end
    char.stat_sp = spellPower

    char.stat_crit = 0
    if GetCombatRatingBonus and CR_CRIT_MELEE then
        char.stat_crit = Round2(GetCombatRatingBonus(CR_CRIT_MELEE))
    end

    char.stat_hitpct = 0
    if GetCombatRatingBonus and CR_HIT_MELEE then
        char.stat_hitpct = Round2(GetCombatRatingBonus(CR_HIT_MELEE))
    end

    char.stat_haste = 0
    if GetCombatRatingBonus and CR_HASTE_MELEE then
        char.stat_haste = Round2(GetCombatRatingBonus(CR_HASTE_MELEE))
    end

    local baseDef, modDef = UnitDefenseSkill("player")
    char.stat_defense = (baseDef or 0) + (modDef or 0)

    char.stat_resilience = 0
    local resilIndex = CR_RESILIENCE_CRIT_TAKEN
        or COMBAT_RATING_RESILIENCE_PLAYER_DAMAGE_TAKEN
        or CR_RESILIENCE_PLAYER_DAMAGE_TAKEN
    if GetCombatRating and resilIndex then
        char.stat_resilience = GetCombatRating(resilIndex) or 0
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

    -- Craft cooldowns are captured generically by the Professions plugin's
    -- tradeskill scan (any recipe with GetTradeSkillCooldown(i) > 0), stored as
    -- dynamic cd_<prof>@<label> fields on the character record, and displayed by
    -- RowRenderer/Roster. No hand-maintained allowlist here anymore.

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
        end
    end

    -- Helm/cloak display toggles. The render pipeline needs these because the Battle.net
    -- armory render respects them but the equipment list does not: a character with the helm
    -- hidden would otherwise be drawn wearing a helmet they never see in game. Synced on
    -- purpose (same reasoning as refshot_ts) — the pipeline reads ONE aggregator account, so
    -- an alt's toggle has to ride sync to reach it.
    -- Guarded: these are TBC-era APIs, and a missing global must not abort the whole scan.
    char.hidehelm  = (ShowingHelm  and not ShowingHelm())  and 1 or 0
    char.hidecloak = (ShowingCloak and not ShowingCloak()) and 1 or 0

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