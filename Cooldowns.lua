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
local ICON_ITEMS = {
    ["Tailoring@Mooncloth"]        = 14342,
    ["Alchemy@Transmute"]          = 12360,   -- Arcanite Bar
    ["Leatherworking@Salt Shaker"] = 15846,
}
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function ProfessionIcon(prof)
    for _, col in ipairs(AltStable.Columns or {}) do
        if col.type == "profSkill" and col.label == prof then return col.profIcon end
    end
end

local function IconFor(prof, label)
    local item = ICON_ITEMS[prof .. "@" .. label]
    if item and AltStable.API and AltStable.API.GetItemIconByID then
        local ok, icon = pcall(AltStable.API.GetItemIconByID, item)
        if ok and icon then return icon end
    end
    return ProfessionIcon(prof) or FALLBACK_ICON
end

-- Seconds until it comes up: 0 when ready, nil when the character has no
-- such cooldown recorded.
function CD.Remaining(char, key, now)
    local expiry = type(char) == "table" and tonumber(char[key])
    if not expiry then return nil end
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
        type = "cooldown", width = 140, align = "CENTER", group = "cooldown",
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

-- Who the view lists: a named record the sheet shows (not hidden), with at
-- least one cooldown recorded. One rule for the columns, the rows and the
-- count, so none of them can know of a character the others don't.
function CD.HasAny(char)
    if type(char) ~= "table" then return false end
    for k, v in pairs(char) do
        if type(k) == "string" and tonumber(v) and CD.Parse(k) then return true end
    end
    return false
end

function CD.Listed(char, shown)
    return type(char) == "table" and char.name ~= nil and (not shown or shown(char)) and CD.HasAny(char)
end

-- Every cooldown a listed character has, by profession, then label.
function CD.KeysInUse(store, shown)
    local seen, keys = {}, {}
    for _, char in pairs(store or {}) do
        if CD.Listed(char, shown) then
            for k, v in pairs(char) do
                if not seen[k] and type(k) == "string" and tonumber(v) and CD.Parse(k) then
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
        if CD.Listed(char, shown) then
            for k, v in pairs(char) do
                local expiry = tonumber(v)
                if expiry and expiry <= now and type(k) == "string" and CD.Parse(k) then n = n + 1 end
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

-- The cell, and its tooltip's two lines: up, running, or nothing recorded.
function CD.Cell(char, key, now)
    now = now or time()
    local prof, label = CD.Parse(key)
    local title = (label or key) .. " (" .. (prof or "?") .. ")"
    local left = CD.Remaining(char, key, now)
    if not left then return DASH, title, "No recorded cooldown" end
    if left <= 0 then return READY_MARK .. "|cff1eff00Available|r", title, "Ready" end
    return CD.Format(left), title, "Ready " .. date("%a %H:%M", now + left)
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
