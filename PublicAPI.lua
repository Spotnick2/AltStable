------------------------------------------------------------
-- PublicAPI.lua - a small, stable, read-only API for other addons (#123)
--
-- First asked for by GlassPanel's [AltStable] block: total gold on the bar, a
-- per-character tooltip, a click that opens the sheet. AltStable stays the one
-- source of truth - with cross-account sync and forgetting - rather than every
-- consumer keeping its own copy of the characters.
--
-- The contract is docs/PUBLIC-API.md. What makes it stable:
--
--   * nothing here hands out a live table. AltStableDB's layout is internal and
--     free to change; these functions return COPIES of a fixed set of fields.
--   * PUBLIC_API_VERSION changes on ANY incompatible change - a field's meaning,
--     a removal, a function's arguments, the callback's behaviour. Adding a
--     field or a function does not bump it.
--   * a consumer's error stays in the consumer: callbacks run under pcall.
--
-- Named PUBLIC_API_VERSION, not API_VERSION: AltStable.API is the Retail-API
-- adapter (Compat.lua), and a consumer reading "AltStable.API" as this would be
-- reading the wrong table entirely.
------------------------------------------------------------

AltStable = AltStable or {}

AltStable.PUBLIC_API_VERSION = 1

-- The fields a character copy carries. Everything else on the record is
-- internal and may change without notice.
local FIELDS = { "guid", "name", "realm", "faction", "class", "level", "money",
                 "account", "lastUpdate" }

local function Plain(v)
    local P = AltStable.API and AltStable.API.PlainNumber
    if P then return P(v) end
    return tonumber(v)
end

local function Records()
    return type(AltStableDB) == "table" and AltStableDB or {}
end

local function Counts(char)
    return type(char) == "table" and char.name ~= nil
        and not (AltStable.IsCharacterForgotten and AltStable.IsCharacterForgotten(char.guid))
end

local function IsHidden(guid)
    return AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) or false
end

-- Every character AltStable knows, as copies, sorted by realm then name.
--
-- Forgotten characters are left out. HIDDEN ones are included and flagged:
-- hiding is a view choice the sheet makes, and a consumer may want to show them
-- dimmed - GetTotals() leaves them out, as the sheet's footer does.
--
-- money is copper, or nil when the client would not say (a secret value, see
-- Compat.lua): unknown, never 0.
function AltStable.GetCharacters()
    local me = UnitGUID and UnitGUID("player")
    local out = {}
    for _, char in pairs(Records()) do
        if Counts(char) then
            local copy = {}
            for _, k in ipairs(FIELDS) do copy[k] = char[k] end
            copy.level = Plain(copy.level)
            copy.money = Plain(copy.money)
            copy.lastUpdate = Plain(copy.lastUpdate)
            -- One representation, always a string: records tagged from the
            -- Options box hold a number, from /alts account a string, and old
            -- ones nothing - which a consumer grouping by account would split
            -- into "2", 2 and nil.
            copy.account = tostring(char.account or "")
            copy.hidden = IsHidden(char.guid)
            copy.current = (me ~= nil and char.guid == me)
            out[#out + 1] = copy
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = tostring(a.realm or ""), tostring(b.realm or "")
        if ra ~= rb then return ra < rb end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return out
end

-- The sheet's own footer numbers - the sheet computes its footer by calling
-- this, so a consumer showing "total gold" shows the same figure.
--
--   money      copper across the characters that count, known amounts only
--   unknown    how many of them have no readable money (not counted as 0)
--   characters how many count: every one not hidden and not forgotten
--   hidden     how many were left out for being hidden
--   levels     their levels summed (the footer's average divides this)
--
-- Low-level bank alts count: they hold gold, and totals are expected to match
-- other addons that count them.
function AltStable.GetTotals()
    local t = { money = 0, unknown = 0, characters = 0, hidden = 0, levels = 0 }
    for _, char in pairs(Records()) do
        if Counts(char) then
            if IsHidden(char.guid) then
                t.hidden = t.hidden + 1
            else
                t.characters = t.characters + 1
                t.levels = t.levels + (Plain(char.level) or 0)
                local m = Plain(char.money)
                if m == nil then t.unknown = t.unknown + 1 else t.money = t.money + m end
            end
        end
    end
    return t
end

function AltStable.OpenSheet()
    if AltStable.EnsureSheetVisible then AltStable.EnsureSheetVisible() end
end

-- What a click on an info-bar block does: open the sheet, or close it if open.
function AltStable.ToggleSheet()
    local sheet = _G.AltStableSheet
    if sheet and sheet:IsShown() then
        sheet:Hide()
    else
        AltStable.OpenSheet()
    end
end

------------------------------------------------------------
-- "CharactersChanged"
------------------------------------------------------------
-- Almost every change to the characters - a sync that lands, forgetting,
-- hiding, /alts cleanup - already ends in AltStable.RefreshSheet(), from some
-- twenty places, so the notification hangs there. Two changes do NOT reach it
-- (Codex review on #123): the login scan (Core, two seconds after login) and a
-- plugin touching a record (Warband's bag and bank updates, via TouchCharacter,
-- which moves lastUpdate). Those two are hooked as well. Every burst collapses
-- into one callback on the next frame. A refresh that changed nothing visible to a
-- consumer still notifies; repainting a block is cheap, missing a change is not.
local callbacks = {}          -- event -> { fn = true }
local pending = false

local function Fire(event)
    -- A snapshot, not the live set: a listener that registers another from inside
    -- its callback would ADD a key mid-traversal, which is undefined in Lua 5.1's
    -- pairs(). The new one is heard from the next change on.
    local listeners = {}
    for fn in pairs(callbacks[event] or {}) do listeners[#listeners + 1] = fn end
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, event)
        if not ok and geterrorhandler then
            -- Reported, not raised: the consumer's bug must not stop AltStable
            -- from refreshing, or the next consumer from hearing about it.
            geterrorhandler()(err)
        end
    end
end

local function Changed()
    if pending then return end
    pending = true
    local run = function()
        pending = false
        Fire("CharactersChanged")
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, run) else run() end
end

local EVENTS = { CharactersChanged = true }

function AltStable.RegisterCallback(event, fn)
    if not EVENTS[event] then error("AltStable.RegisterCallback: unknown event " .. tostring(event), 2) end
    if type(fn) ~= "function" then error("AltStable.RegisterCallback: fn must be a function", 2) end
    callbacks[event] = callbacks[event] or {}
    callbacks[event][fn] = true
end

function AltStable.UnregisterCallback(event, fn)
    if callbacks[event] then callbacks[event][fn] = nil end
end

-- Wrapped by replacement, the way the plugins wrap RefreshSheet; they load
-- later and wrap this in turn, so every layer runs. All three are always
-- called through AltStable.*, never a local alias, so the wrapper sees them.
local function NotifyAfter(name)
    local original = AltStable[name]
    if type(original) ~= "function" then return end
    AltStable[name] = function(...)
        local a, b, c = original(...)
        Changed()
        return a, b, c
    end
end
NotifyAfter("RefreshSheet")
NotifyAfter("ScanCharacter")
NotifyAfter("TouchCharacter")

AltStable._test = AltStable._test or {}
AltStable._test.publicApiPending = function() return pending end
