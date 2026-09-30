------------------------------------------------------------
-- PublicAPI.lua - a small, stable, read-only API for other addons (#123)
--
-- First asked for by GlassPanel's [AltStable] block: total gold on the bar, a
-- per-character tooltip, a click that toggles the sheet. AltStable stays the
-- one source of truth - with cross-account sync and forgetting - rather than
-- every consumer keeping its own copy of the characters.
--
-- The contract is docs/PUBLIC-API.md. What makes it stable:
--
--   * nothing here hands out a live table. AltStableDB's layout is internal and
--     free to change; these functions return COPIES of a fixed set of fields.
--   * PUBLIC_API_VERSION changes on ANY incompatible change - a field's meaning,
--     a removal, a function's arguments, the callback's behaviour. Adding a
--     field or a function does not bump it.
--   * a consumer's error stays in the consumer: callbacks run under xpcall.
--
-- Named PUBLIC_API_VERSION, not API_VERSION: AltStable.API is the Retail-API
-- adapter (Compat.lua), and a consumer reading "AltStable.API" as this would be
-- reading the wrong table entirely.
--
-- AltStable's own code never calls into this file. The sheet's footer uses
-- AltStable.CharacterTotals (Core.lua), which GetTotals exposes: a function
-- other addons can see - and wrap - must not be able to change AltStable's own
-- numbers.
------------------------------------------------------------

AltStable = AltStable or {}

local PlainNumber = AltStable.API.PlainNumber

AltStable.PUBLIC_API_VERSION = 1

-- The fields a character copy carries. Everything else on the record is
-- internal and may change without notice.
local FIELDS = { "guid", "name", "realm", "faction", "class", "level", "money",
                 "account", "lastUpdate" }

-- Every character AltStable has a record for - the same ones the sheet's grid
-- lists - as copies, sorted by realm then name.
--
-- A forgotten character normally has no record, so it is not here. One that has
-- a record again (logged into after forgetting) IS, exactly as the grid shows
-- it: a list that disagreed with the sheet would be the bug (review of #126).
-- HIDDEN ones are included and flagged: hiding is a view choice the sheet
-- makes, and a consumer may want to show them dimmed - GetTotals() leaves them
-- out, as the sheet's footer does.
--
-- money is copper, or nil when the client would not say (a secret value, see
-- Compat.lua): unknown, never 0.
function AltStable.GetCharacters()
    local me = UnitGUID and UnitGUID("player")
    local out = {}
    for _, char in pairs(type(AltStableDB) == "table" and AltStableDB or {}) do
        if type(char) == "table" and char.name then
            local copy = {}
            for _, k in ipairs(FIELDS) do copy[k] = char[k] end
            copy.level = PlainNumber(copy.level)
            copy.money = PlainNumber(copy.money)
            copy.lastUpdate = PlainNumber(copy.lastUpdate)
            -- One representation, always a string: records tagged from the
            -- Options box hold a number, from /alts account a string, and old
            -- ones nothing - which a consumer grouping by account would split
            -- into "2", 2 and nil.
            copy.account = tostring(char.account or "")
            copy.hidden = (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(char.guid)) or false
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

-- The sheet's own footer numbers (AltStable.CharacterTotals, Core.lua). A copy:
-- a consumer changing it changes nothing.
--
--   money      copper across the characters that count, known amounts only
--   unknown    how many of them have no readable money (not counted as 0)
--   characters how many count: every one the grid lists, less the hidden
--   hidden     how many were left out for being hidden
--   levels     their levels summed (the footer's average divides this)
function AltStable.GetTotals()
    return AltStable.CharacterTotals()
end

function AltStable.OpenSheet()
    if AltStable.EnsureSheetVisible then AltStable.EnsureSheetVisible() end
end

-- Whether a new portrait capture is worth taking for the character being
-- played (#128), as a copy:
--   due          true when a capture is worth taking (the button's glow can
--                still be off: in combat, or switched off by the player)
--   reason       "missing" (no portrait, nothing captured), "changed" (the
--                gear shown in the portrait changed since the last capture),
--                "pending" (captured, not yet converted - not due) or "none"
--   changedSlots for "changed", the slot names that differ ("Chest", ...)
-- The action is AltStable.CapturePortrait(); "PortraitStatusChanged" says when
-- to ask again.
function AltStable.GetPortraitStatus()
    -- Built afresh on every call (Capture.lua), so it is already the caller's
    -- own copy; the test pins that rather than this file copying it again.
    local s = AltStable.CurrentPortraitStatus and AltStable.CurrentPortraitStatus()
    if type(s) ~= "table" then return { due = false, reason = "none", changedSlots = {} } end
    return s
end

-- What a click on an info-bar block does: open the sheet, or close it if open.
-- The sheet's own toggle, the one the minimap button uses - not a second copy.
function AltStable.ToggleSheet()
    if AltStable.ShowSheet then AltStable.ShowSheet() end
end

------------------------------------------------------------
-- "CharactersChanged"
------------------------------------------------------------
-- Almost every change to the characters - a sync that lands, forgetting,
-- hiding, /alts cleanup - already ends in AltStable.RefreshSheet(), from some
-- twenty places, so the notification hangs there. Two changes do NOT reach it
-- (Codex review on #123): the login scan (Core, two seconds after login) and a
-- plugin touching a record (Warband's bag and bank updates, via TouchCharacter,
-- which moves lastUpdate). Those two are hooked as well.
--
-- A deliberate trade-off (review of #126 asked for notifying at every place
-- that WRITES a character instead). Hanging it on the refresh means a pure view
-- change - "show hidden", say - also notifies. The contract says a callback may
-- come when nothing a consumer shows has changed; repainting is cheap. Threading
-- a notification through every write site in Core, Config and the plugins is
-- the larger change, and the gaps it would close are the two hooked here.
--
-- Every burst collapses into one callback on the next frame.
local callbacks = {}          -- event -> { fn = true }
local pending = {}            -- event -> true while its callback is scheduled
local firing = {}             -- event -> true while its listeners run

local function Listeners(event)
    local list = {}
    for fn in pairs(callbacks[event] or {}) do list[#list + 1] = fn end
    return list
end

-- xpcall with the client's error handler, so a consumer's error is reported
-- WITH its own stack - the failing frame is still live when the handler runs -
-- and stays the consumer's: it does not stop AltStable or the next listener.
local function Report(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then pcall(handler, err) end
end

local function Fire(event)
    -- A snapshot, not the live set: a listener that registers another from inside
    -- its callback would ADD a key mid-traversal, which is undefined in Lua 5.1's
    -- pairs(). The new one is heard from the next change on.
    local listeners = Listeners(event)
    firing[event] = true
    for _, fn in ipairs(listeners) do
        xpcall(function() return fn(event) end, Report)
    end
    firing[event] = nil
end

local function Changed(event)
    event = event or "CharactersChanged"
    -- Nothing listening: nothing to schedule. The default for everyone without
    -- a consumer addon, on every coin looted and every bag change.
    if not next(callbacks[event] or {}) then return end
    -- A refresh made FROM INSIDE a callback is the consumer syncing the sheet to
    -- what it was just told, not a new change. Notifying it again would call the
    -- consumer again, which refreshes again - every frame, for ever. Per event:
    -- a portrait status that changes inside a CharactersChanged callback is
    -- still news (review of #134).
    if firing[event] or pending[event] then return end
    pending[event] = true
    local function run() pending[event] = nil; Fire(event) end
    if C_Timer and C_Timer.After then C_Timer.After(0, run) else run() end
end

local EVENTS = { CharactersChanged = true, PortraitStatusChanged = true }

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
--
-- Notified BEFORE the original runs. The callback is on the next frame anyway,
-- and by the time any of these is called the data has usually changed already:
-- a render error in the sheet must not be able to swallow the notification.
local function NotifyAround(name)
    local original = AltStable[name]
    if type(original) ~= "function" then return end
    AltStable[name] = function(...)
        Changed()
        return original(...)
    end
end
NotifyAround("RefreshSheet")
NotifyAround("ScanCharacter")
NotifyAround("TouchCharacter")

-- "PortraitStatusChanged" (#128): Capture.lua calls PortraitStatusUpdated only
-- when the answer changes, so this is one callback per change, next frame.
do
    local original = AltStable.PortraitStatusUpdated
    if type(original) == "function" then
        AltStable.PortraitStatusUpdated = function(...)
            Changed("PortraitStatusChanged")
            return original(...)
        end
    end
end
