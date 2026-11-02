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

-- What this AltStable offers beyond version 1's functions (#281). Additions
-- do not bump the version (docs/PUBLIC-API.md), so a consumer checks the
-- flag: an older AltStable has no table, or no flag, and reads as "not
-- available" rather than as an error.
AltStable.PUBLIC_API_FEATURES = {
    provenance = true,          -- GetCharacterProvenance, the provenance fields, ProvenanceChanged
    ownAccountChannel = true,   -- SendToOwnAccounts and the rest, OwnAccountPeersChanged
    gear = true,                -- GetCharacterGear, GearChanged (AS-003)
}

-- Whose character a record is (Core.lua, "Ownership provenance"): kind, the
-- time it was established (nil when not known), and for "own-account" the
-- own account that said so.
local function ProvenanceOf(char)
    if char.scannedHere then
        -- provAt is the scan's stamp: nothing else writes one on our own
        -- scan (Provenance.Apply skips it). nil on a record from before #281.
        return "self", PlainNumber(char.provAt), nil
    end
    if char.provKind == "own-account" then
        return "own-account", PlainNumber(char.provAt), char.provVia
    end
    return "third-party", nil, nil
end

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
            copy.provenance, copy.provenanceAt, copy.provenanceVia = ProvenanceOf(char)
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

-- One character's equipped gear (#281, AS-003), as a copy. nil for a
-- character AltStable has no record of. Per inventory slot id:
--   state       "occupied": itemString is exact;
--               "empty": nothing in the slot;
--               "unknown": the record cannot say which item (a record from an
--               AltStable before #281, or a string that disagrees with the
--               record's item id, enchant or gems - stale, never trusted).
--               itemID is still given when known, as a hint.
--   itemString  "item:..." with the random suffix (Forever: bonus IDs) and the
--               enchant and gems, without the scanner's level and spec
--               (Scanner.lua, GearItemString)
--   itemLevel   nil when the scanning client had not cached the item
local function GearSlot(char, slot)
    local out = { slot = slot.id, key = slot.key }
    local id = tonumber(char["gearid_" .. slot.key])
    if id == nil then out.state = "unknown" return out end
    if id == 0 then out.state = "empty" return out end
    out.itemID = id
    local lvl = PlainNumber(char["gear_" .. slot.key])
    if lvl and lvl > 0 then out.itemLevel = lvl end
    local str = char["gearstr_" .. slot.key]
    -- Our own scan from before #281 still has its link to read it from.
    if (type(str) ~= "string" or str == "") and char.scannedHere and AltStable.GearItemString then
        str = AltStable.GearItemString(char["gearlink_" .. slot.key])
    end
    out.state = "unknown"
    if type(str) ~= "string" then return out end
    local f = {}
    for v in (str:gsub("^item:", "") .. ":"):gmatch("([^:]*):") do f[#f + 1] = v end
    if tonumber(f[1]) ~= id then return out end
    -- An older client relays a string it cannot clear on a later merge: one
    -- whose enchant or gems disagree with the record's own is stale.
    local mod = char["gearmod_" .. slot.key]
    if type(mod) == "string" and mod ~= "" then
        local ench, _, g1, g2, g3 = mod:match("^(%d+):([^:]*):(%d+):(%d+):(%d+)$")
        if ench and (tonumber(f[2]) or 0) ~= tonumber(ench) then return out end
        if g1 and ((tonumber(f[3]) or 0) ~= tonumber(g1) or (tonumber(f[4]) or 0) ~= tonumber(g2)
                   or (tonumber(f[5]) or 0) ~= tonumber(g3)) then return out end
    end
    out.state, out.itemString = "occupied", str
    return out
end

local function GearCapturedAt(char)
    local at, gearAt = PlainNumber(char.lastUpdate), PlainNumber(char.gearAt)
    if gearAt and (not at or gearAt > at) then return gearAt end
    return at
end

function AltStable.GetCharacterGear(guid)
    local char = type(AltStableDB) == "table" and type(guid) == "string" and AltStableDB[guid]
    if type(char) ~= "table" or not char.name then return nil end
    local out = {
        guid = guid,
        -- When the gear was last read as it is: the record's stamp, or gearAt
        -- when that is later. A scan holds lastUpdate back while an item is
        -- uncached (the cache retry stamps it), but the strings come from the
        -- links and are exact already (Codex, PR #283). Not a receive time.
        capturedAt = GearCapturedAt(char),
        -- When the worn items last changed, on the character's own client; nil
        -- on a record from an AltStable before #281.
        gearAt = PlainNumber(char.gearAt),
        provenance = (ProvenanceOf(char)),
        slots = {},
    }
    for _, slot in ipairs(AltStable.GEAR_SLOTS or {}) do
        out.slots[slot.id] = GearSlot(char, slot)
    end
    return out
end

-- One character's provenance: kind, at, via (see ProvenanceOf). nil for a
-- character AltStable has no record of.
function AltStable.GetCharacterProvenance(guid)
    local char = type(AltStableDB) == "table" and type(guid) == "string" and AltStableDB[guid]
    if type(char) ~= "table" or not char.name then return nil end
    return ProvenanceOf(char)
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
local gearGuids = {}          -- guid -> true: gear changed since the last GearChanged

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
    -- "GearChanged" says WHICH characters (#281): the GUIDs gathered over the
    -- burst, a fresh list for each listener.
    local guids
    if event == "GearChanged" then guids, gearGuids = gearGuids, {} end
    firing[event] = true
    for _, fn in ipairs(listeners) do
        local arg
        if guids then
            arg = {}
            for guid in pairs(guids) do arg[#arg + 1] = guid end
            table.sort(arg)
        end
        xpcall(function() return fn(event, arg) end, Report)
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

local EVENTS = { CharactersChanged = true, PortraitStatusChanged = true,
                 ProvenanceChanged = true, OwnAccountPeersChanged = true,    -- #281
                 GearChanged = true }                                         -- #281, AS-003

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

-- "ProvenanceChanged" and "OwnAccountPeersChanged" (#281): Core and Scanner
-- call these when a character's provenance moves, or an own account comes
-- onto the library or leaves it. Coalesced like the others.
function AltStable.ProvenanceUpdated() Changed("ProvenanceChanged") end
function AltStable.OwnAccountPeersUpdated() Changed("OwnAccountPeersChanged") end

-- "GearChanged" (#281, AS-003): Scanner.lua for our own scan, Core.lua for a
-- merge that changed what a record says is worn. Nothing gathered while
-- nobody listens.
function AltStable.GearUpdated(guid)
    if not next(callbacks.GearChanged or {}) then return end
    if type(guid) == "string" then gearGuids[guid] = true end
    Changed("GearChanged")
end

------------------------------------------------------------
-- The own-account channel (#281)
------------------------------------------------------------
-- A consumer's own messages between the player's own accounts, over
-- AltStable's LibAccountSync instance. Both directions are gated in Core
-- before anything here runs: out only to accounts the library proved ours
-- and lists now, in only from them, never to or from one the player refused.
-- A whitelisted friend is not an own account and never sees any of it.

local handlers = {}   -- namespace -> fn(payload, sender)

local function CheckNamespace(namespace, who)
    if type(namespace) ~= "string" or #namespace == 0 or #namespace > 32
        or not namespace:find("^[%w_%.%-]+$") then
        error(who .. ": namespace must be 1-32 letters, digits, '_', '.' or '-'", 3)
    end
end

-- One handler per namespace; registering again replaces it. fn(payload,
-- sender) runs once per message, with the sender as the library proved it:
-- { name, guid, realm, faction }.
function AltStable.RegisterOwnAccountHandler(namespace, fn)
    CheckNamespace(namespace, "AltStable.RegisterOwnAccountHandler")
    if type(fn) ~= "function" then error("AltStable.RegisterOwnAccountHandler: fn must be a function", 2) end
    handlers[namespace] = fn
end

function AltStable.UnregisterOwnAccountHandler(namespace)
    handlers[namespace] = nil
end

-- Core's only way in. A message for a namespace nobody registered is
-- dropped: the other side may run a consumer this one does not.
function AltStable.OwnAccountDeliver(namespace, payload, sender)
    local fn = handlers[namespace]
    if not fn then return end
    -- `sender` is already a table of its own, built by Core for this message.
    xpcall(function() return fn(payload, sender) end, Report)
end

-- Sends `payload` (any string) to every own account, or only to `guid` when
-- given. Returns how many accounts the library took it for; 0 with a reason
-- when none: "no-peers", "too-large", "not-ready", "unavailable" (Battle.net
-- sync off or down) or the library's own. Taken is not delivered: the
-- library does not acknowledge, so a consumer that must know asks back.
function AltStable.SendToOwnAccounts(namespace, payload, guid)
    CheckNamespace(namespace, "AltStable.SendToOwnAccounts")
    if type(payload) ~= "string" then error("AltStable.SendToOwnAccounts: payload must be a string", 2) end
    if guid ~= nil and type(guid) ~= "string" then error("AltStable.SendToOwnAccounts: guid must be a string", 2) end
    if not AltStable.OwnAccountSend then return 0, "unavailable" end
    return AltStable.OwnAccountSend(namespace, payload, guid)
end

-- The own accounts a send would reach right now, as copies:
-- { { name, guid, realm, faction }, ... }, sorted by name.
function AltStable.GetOwnAccountPeers()
    return AltStable.OwnAccountPeerList and AltStable.OwnAccountPeerList() or {}
end
