AltStable = AltStable or {}

------------------------------------------------------------
-- Cooldowns: the Skills tab's Cooldowns view (#543)
--
-- Profession cooldowns are stored on each character's core record as
-- cd_<Profession>@<label> = the absolute time() they come up (the Professions
-- plugin writes them, the sync carries them like any field; a past expiry
-- means ready). There is no fixed list: the view's columns are the cooldowns
-- some listed character has.
--
-- This file is the data side, pure where it can be: which cooldowns and
-- characters there are, a column per cooldown, the countdown text, the ready
-- count and the login-toast note. SheetUI.lua holds the view itself.
------------------------------------------------------------

local CD = {}
AltStable.Cooldowns = CD

local PREFIX = "cd_"

-- The profession and the label of a cooldown field, split on the FIRST "@":
-- a label may hold another one.
function CD.Parse(key)
    if type(key) ~= "string" or key:sub(1, #PREFIX) ~= PREFIX then return nil end
    local prof, label = key:sub(#PREFIX + 1):match("^([^@]+)@(.+)$")
    return prof, label
end

-- The multiply-by-31 checksum Core.lua uses for the sync (no bit operations
-- in Lua 5.1; every step stays exact in a double).
local function Hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 0xFFFFFFFF end
    return string.format("%08X", h)
end

-- A column's field: "cd_" .. a readable part .. "_" .. a hash of the raw key.
-- The hidden-columns setting syncs "<tab>.<field>" only as letters, digits and
-- "_", at most 64 long (Config.lua GoodColumnKey), so the raw key - "@",
-- spaces - can't be the field. Made from the key alone, never from what else
-- was found, so every client names the same cooldown the same way.
local ID_MAX = 54                     -- 64 less "cooldowns."
local READABLE_MAX = ID_MAX - #PREFIX - 1 - 8
function CD.ColumnId(key)
    local prof, label = CD.Parse(key)
    local readable = ((prof or "") .. "_" .. (label or "")):gsub("[^%w_]", "_"):sub(1, READABLE_MAX)
    return PREFIX .. readable .. "_" .. Hash(key)
end

-- Icons: the item a cooldown makes or is used from, when it is one of these;
-- otherwise the profession's own icon (its sheet column's).
-- Without the Recipe Book's catalogue (recorded cooldowns only), these.
local ICON_ITEMS = {
    ["Tailoring@Mooncloth"]            = 14342,
    ["Alchemy@Transmutes"]             = 12360,   -- Arcanite Bar
    ["Alchemy@Transmute"]              = 12360,   -- an older version's label (#545)
    ["Alchemy@Iron to Gold"]           = 3577,    -- Gold Bar
    ["Alchemy@Mithril to Truesilver"]  = 6037,    -- Truesilver Bar
    ["Leatherworking@Salt Shaker"]     = 15846,
}
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function ProfessionIcon(prof)
    for _, col in ipairs(AltStable.Columns or {}) do
        if col.type == "profSkill" and col.label == prof then return col.profIcon end
    end
end

local function IconFor(prof, label)
    -- The Recipe Book's catalogue knows what each cooldown makes (#545).
    local entry = CD.Entry and CD.Entry("cd_" .. prof .. "@" .. label)
    -- A talent's: its spell's icon (#557).
    local spells = rawget(_G, "C_Spell")
    if entry and entry.spell and type(spells) == "table" and type(spells.GetSpellTexture) == "function" then
        local ok, icon = pcall(spells.GetSpellTexture, entry.spell)
        if ok and icon then return icon end
    end
    local item = (entry and entry.iconItem) or ICON_ITEMS[prof .. "@" .. label]
    if item and AltStable.API and AltStable.API.GetItemIconByID then
        local ok, icon = pcall(AltStable.API.GetItemIconByID, item)
        if ok and icon then return icon end
    end
    return ProfessionIcon(prof) or FALLBACK_ICON
end

-- Seconds until it comes up: 0 when ready, nil when the character has no
-- such cooldown recorded.
-- An item's cooldown recorded for a character the Recipe Book says can't use
-- the item yet (a Salt Shaker carried under Leatherworking 250, or a record
-- synced from an older client) is not believed: the cell says Needs 250, and
-- the badge doesn't count it (Codex review of #546).
-- Likewise a talent's recorded for a character whose reading no longer has the
-- talent (a reset, or a record synced from before it): not believed (#557).
local function Unusable(char, key)
    local entry = CD.Entry and CD.Entry(key)
    if entry and entry.legacy then return CD.Standing(char, entry) == "untaken" end
    local standing = AltStable.CooldownStanding
    return entry ~= nil and entry.item ~= nil and standing ~= nil and standing(char, entry) == "low"
end

-- Whether a recorded cooldown counts at all: the one rule for the cell, the
-- count, who is listed, which columns there are and the login toast (Codex
-- review of #559: a record kept after a talent reset added a row, a column and
-- a toast).
function CD.Believed(char, key) return not Unusable(char, key) end

function CD.Remaining(char, key, now)
    local expiry = type(char) == "table" and tonumber(char[key])
    if not expiry or Unusable(char, key) then return nil end
    return math.max(0, expiry - (now or time()))
end

-- One column per cooldown, made once and kept: the sheet looks columns up by
-- field (sorting, the Columns menu).
local byKey, byField = {}, {}
function CD.Column(key)
    local col = byKey[key]
    if col then return col end
    local prof, label = CD.Parse(key)
    if not prof then return nil end
    col = {
        label = label, field = CD.ColumnId(key), cdKey = key, prof = prof,
        -- As wide as the icon and the name need ("Mithril to Truesilver" was
        -- cut at 140), from 140 to 220. Measured in game: ~7 per character.
        type = "cooldown", width = math.min(220, math.max(140, 40 + 7 * #label)),
        align = "CENTER", group = "cooldown",
        cdIcon = IconFor(prof, label), headerIconSize = 20,
        headerTip = label .. " (" .. prof .. ")",
        -- The soonest first on the first click; nobody without it, last.
        sortFirstAsc = true, orderWords = { "soonest first", "latest first" },
        -- At the sort's own reading of the clock (SheetUI's SortComparator).
        sortValue = function(c, now) return CD.Remaining(c, key, now) end,
    }
    byKey[key], byField[col.field] = col, col
    return col
end

function CD.ColumnForField(field) return byField[field] end

-- The Recipe Book's catalogue (Professions plugin, #545) while it is loaded:
-- every cooldown, whoever has recorded one. nil without it, and the view is the
-- recorded cooldowns alone.
local function Catalogue()
    local f = AltStable.CooldownCatalogue
    return f and f() or nil
end

-- The core's own cooldowns (#557): a Legacy talent's, no profession's, so
-- listed with or without the Recipe Book. Dedicated Study, measured in the
-- client's tables on 1.60.1.71139: spell 1225469, a 23 h category cooldown
-- (SpellCooldowns 82,800,000 ms); the talent is node 110284 of the Professions
-- tree (1187), one rank (AltStableConfig.legacyLayout).
local STUDY = { key = "cd_Legacy@Dedicated Study", prof = "Legacy", label = "Dedicated Study",
                spell = 1225469, node = 110284, legacy = true }
CD.CORE = { STUDY }

function CD.Entry(key)
    for _, e in ipairs(CD.CORE) do
        if e.key == key then return e end
    end
    for _, e in ipairs(Catalogue() or {}) do
        if e.key == key then return e end
    end
end

-- A Legacy talent's cooldown, from the character's synced Legacy talents:
--   "taken"     the node has a rank
--   "untaken"   read, and it hasn't
--   nil         no reading for this character yet
local function TalentStanding(char, entry)
    local LT = AltStable.LegacyTalents
    local rank = LT and LT.Rank and LT.Rank(char, entry.node)
    if rank == nil then return nil end
    return rank > 0 and "taken" or "untaken"
end

-- Where a character stands on a catalogued cooldown (the plugin's rule, or a
-- talent's), and its skill. nil: no such profession, or no plugin.
local function Standing(char, entry)
    if entry and entry.legacy then return TalentStanding(char, entry) end
    local f = AltStable.CooldownStanding
    if f and entry then return f(char, entry) end
end
CD.Standing = Standing

-- A record with at least one cooldown recorded, and believed.
function CD.HasAny(char)
    if type(char) ~= "table" then return false end
    for k, v in pairs(char) do
        if type(k) == "string" and tonumber(v) and CD.Parse(k) and not Unusable(char, k) then return true end
    end
    return false
end

local function Shown(char, shown)
    return type(char) == "table" and char.name ~= nil and (not shown or shown(char))
end

-- Who the view lists: a named record the sheet shows (not hidden), with a
-- cooldown recorded or, the Recipe Book loaded, a profession that has one.
-- One rule for the rows and the count.
function CD.Listed(char, shown)
    if not Shown(char, shown) then return false end
    if CD.HasAny(char) then return true end
    -- A talent lists only who has taken it: every character with a Legacy
    -- reading hasn't, and isn't the view's business for that (#557).
    for _, e in ipairs(CD.CORE) do
        if Standing(char, e) == "taken" then return true end
    end
    for _, e in ipairs(Catalogue() or {}) do
        if Standing(char, e) then return true end
    end
    return false
end

-- Every column: the catalogue's cooldowns, a talent's once a shown character
-- has taken it (#557), and any other a shown character has recorded (an older
-- version's label, a recipe newer than the data), by profession, then label.
function CD.KeysInUse(store, shown)
    local seen, keys = {}, {}
    for _, e in ipairs(Catalogue() or {}) do
        seen[e.key] = true
        keys[#keys + 1] = e.key
    end
    for _, char in pairs(store or {}) do
        if Shown(char, shown) then
            for _, e in ipairs(CD.CORE) do
                if not seen[e.key] and Standing(char, e) == "taken" then
                    seen[e.key] = true
                    keys[#keys + 1] = e.key
                end
            end
            for k, v in pairs(char) do
                if not seen[k] and type(k) == "string" and tonumber(v) and CD.Parse(k)
                   and not Unusable(char, k) then
                    seen[k] = true
                    keys[#keys + 1] = k
                end
            end
        end
    end
    table.sort(keys, function(a, b)
        local pa, la = CD.Parse(a)
        local pb, lb = CD.Parse(b)
        if pa ~= pb then return pa < pb end
        return la < lb
    end)
    return keys
end

-- How many cooldowns are up, over the listed characters: character and
-- cooldown pairs, the count the tab shows.
function CD.ReadyCount(store, shown, now)
    now = now or time()
    local n = 0
    for _, char in pairs(store or {}) do
        if Shown(char, shown) then
            for k, v in pairs(char) do
                if tonumber(v) and type(k) == "string" and CD.Parse(k) then
                    local left = CD.Remaining(char, k, now)   -- an unusable item's isn't believed
                    if left and left <= 0 then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- "1d 4h", "6h 12m", "38m 12s", "45s": to the second under an hour, so the
-- countdown visibly runs.
function CD.Format(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    local d, h = math.floor(secs / 86400), math.floor((secs % 86400) / 3600)
    local m, s = math.floor((secs % 3600) / 60), secs % 60
    if d > 0 then return h > 0 and (d .. "d " .. h .. "h") or (d .. "d") end
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m " .. s .. "s" end
    return s .. "s"
end

local READY_MARK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t "
local DASH = "|cff888888\226\128\148|r"

local STATE_TEXT = {
    known     = "|cffb0b0b0Known|r",
    learnable = "|cffffd200Learnable|r",
    usable    = "|cffffd200Usable|r",
    unscanned = "|cff888888Not scanned|r",
    taken     = "|cffb0b0b0Taken|r",
    untaken   = "|cff888888Not taken|r",
}

-- The cell. A recorded cooldown first: running, or up (a 0 is one seen ready
-- and never cast). Otherwise, the Recipe Book loaded, where the character
-- stands (#545): Known (its cooldown not read yet), Learnable, Usable (an
-- item's), Needs <skill>, Not scanned. A dash for anyone else.
function CD.Cell(char, key, now)
    local left = CD.Remaining(char, key, now)
    if left then
        if left <= 0 then return READY_MARK .. "|cff1eff00Available|r" end
        return CD.Format(left)
    end
    local entry = CD.Entry(key)
    local state = Standing(char, entry)
    if state == "low" then return "|cff888888Needs " .. tostring(entry.learn or "?") .. "|r" end
    return STATE_TEXT[state] or DASH
end

-- The cell's tooltip, built on hover: a title, what the cell means, a note,
-- and the recipes (known, or what the skill meets and where each is learned).
function CD.Tip(char, key, now)
    now = now or time()
    local prof, label = CD.Parse(key)
    prof, label = prof or "?", label or key
    local name = type(char) == "table" and char.name or "?"
    local title = label .. " (" .. prof .. ")"
    local entry = CD.Entry(key)
    local state, rank = Standing(char, entry)
    local learn = tostring(entry and entry.learn or "?")
    local left = CD.Remaining(char, key, now)
    local l2, l3
    if left then
        l2 = (left <= 0) and "Ready" or ("Ready " .. date("%a %H:%M", now + left))
        if Catalogue() and not entry then
            l3 = "Not one of this version's cooldowns: recorded by an older version of AltStable, "
                .. "or for a recipe newer than its data."
        end
    elseif state == "taken" then
        l2 = "Taken; its cooldown is not recorded yet"
        l3 = "Log in on " .. name .. " to read it."
    elseif state == "untaken" then
        l2 = "Not taken: a talent of the Professions Legacy tree"
    elseif entry and entry.legacy then
        l2 = "No recorded cooldown"
        l3 = "No Legacy talents read for " .. name .. " yet: log in on it once."
    elseif state == "known" then
        l2 = "Known; its cooldown is not recorded yet"
        l3 = "Open the " .. prof .. " window on " .. name .. " to read it."
    elseif state == "learnable" then
        l2 = "Learnable: needs " .. prof .. " " .. learn .. ", " .. name .. " has " .. tostring(rank)
    elseif state == "usable" then
        l2 = "Meets " .. prof .. " " .. learn .. "; needs a " .. label .. " in the bags"
    elseif state == "low" then
        l2 = "Needs " .. prof .. " " .. learn .. "; " .. name .. " has " .. tostring(rank)
    elseif state == "unscanned" then
        l2 = "Not scanned"
        l3 = "Open the " .. prof .. " window on " .. name .. " once."
    else
        l2 = "No recorded cooldown"
    end
    local lines
    if entry and not entry.legacy and AltStable.CooldownRecipeLines then
        for _, l in ipairs(AltStable.CooldownRecipeLines(char, entry)) do
            lines = lines or {}
            lines[#lines + 1] = l[1] .. ":  " .. l[2]
        end
    end
    return title, l2, l3, lines
end

-- What the view says with nobody to list.
function CD.EmptyText()
    if Catalogue() then
        return "No shown character has a profession with a tracked cooldown, or a recorded cooldown."
    end
    return "No cooldowns recorded.\n\nEnable the Recipe Book module and open each character's "
        .. "profession window, or sync from your other account."
end

-- The login toast, as the note in the view's bar says it: the toast's own
-- rule (Toasts.lua), for the professions the view shows.
function CD.ToastNote(profs)
    local enabled = AltStable.IsToastEnabled or function() return true end
    local lines = {}
    local allOff = AltStableConfig and AltStableConfig.toastsEnabled == false
    local on, off = 0, 0
    for _, prof in ipairs(profs or {}) do
        local yes = enabled(prof)
        if yes then on = on + 1 else off = off + 1 end
        lines[#lines + 1] = { prof, yes and "|cff1eff00on|r" or "|cff888888off|r" }
    end
    local state
    if allOff or (on == 0 and off > 0) then state = "|cff888888off|r"
    elseif off > 0 then state = "|cffffd200some professions|r"
    else state = "|cff1eff00on|r" end
    return "Login toasts: " .. state, lines
end

------------------------------------------------------------
-- Recording Dedicated Study (#557), for the character being played
--
-- Unlike a recipe's, readable with no window open: C_Spell.GetSpellCooldown.
-- Measured idle, on a character without the talent (1.60.1.71139): start 0,
-- duration 0, enabled, not secret. The reading after a cast is NOT measured
-- (nobody had the talent yet); it is read as the item cooldowns are (#460).
--
-- The Salt Shaker's rules (the Recipe Book's ReadItemCooldowns): a running one
-- is an absolute expiry, and a shift under 60 s is no change; first seen and
-- not running, it is written as now (Available, and the login toast says it
-- once); a past expiry is kept. Not taken: a record held goes. Nothing changes
-- on the global cooldown alone (2 s or less), a paused cooldown (isEnabled
-- false), or a reading that fails or is secret; nor without a Legacy reading.
------------------------------------------------------------

local GCD_MAX = 2

-- Start (on the GetTime() clock) and duration, or nil.
local function SpellCooldown(spell)
    local ok, s, d = pcall(function()
        local spells = rawget(_G, "C_Spell")
        local f = type(spells) == "table" and spells.GetSpellCooldown
        local info = type(f) == "function" and f(spell)
        if type(info) ~= "table" or info.isEnabled == false then return nil end
        local plain = AltStable.API and AltStable.API.PlainNumber
        if not plain then return nil end
        return plain(info.startTime), plain(info.duration)
    end)
    if not ok or not s or not d or s < 0 or d < 0 then return nil end
    return s, d
end

function CD.ReadStudy()
    local guid = UnitGUID and UnitGUID("player")
    local char = guid and type(AltStableDB) == "table" and AltStableDB[guid]
    if type(char) ~= "table" then return false end
    local key, now, changed = STUDY.key, time(), false
    local state = Standing(char, STUDY)
    if state == "untaken" then
        if char[key] ~= nil then char[key] = nil; changed = true end
    elseif state == "taken" then
        local s, d = SpellCooldown(STUDY.spell)
        if s and not (d > 0 and d <= GCD_MAX) then
            local held = tonumber(char[key])
            local left = (s > 0 and d > 0) and (s + d - (GetTime() or 0)) or 0
            if left > 0 then
                local expiry = math.floor(now + left + 0.5)
                if not held or held <= now or math.abs(held - expiry) > 60 then
                    char[key] = expiry; changed = true
                end
            elseif not held or held > now then
                char[key] = now; changed = true
            end
        end
    end
    if changed then
        -- A cooldown alone must reach peers too: the core sends a character
        -- whose lastUpdate moved. And the view redraws.
        if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
    return changed
end

-- At a login or a reload, after the Legacy reading (LegacyTalents reads at
-- 3 s; a reading that changes calls ReadStudy itself), and on every cooldown
-- update, a burst read once.
local STUDY_AFTER, STUDY_SETTLE = 5, 0.2
local studyQueued = false
local studyEvents = CreateFrame("Frame")
studyEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
pcall(studyEvents.RegisterEvent, studyEvents, "SPELL_UPDATE_COOLDOWN")
studyEvents:SetScript("OnEvent", function(_, event, a, b)
    if event == "PLAYER_ENTERING_WORLD" then
        if a or b then C_Timer.After(STUDY_AFTER, CD.ReadStudy) end
    elseif not studyQueued then
        studyQueued = true
        C_Timer.After(STUDY_SETTLE, function() studyQueued = false; CD.ReadStudy() end)
    end
end)

AltStable._test = AltStable._test or {}
AltStable._test.StudyFrame = studyEvents
AltStable._test.ResetStudy = function() studyQueued = false end
