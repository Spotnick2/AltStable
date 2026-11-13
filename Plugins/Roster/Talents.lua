------------------------------------------------------------
-- Talents.lua - every alt's talents, in the Roster (#273)
--
-- Measured on 1.60.1.70938 (docs/forever-api-notes.md, Talents): Forever has
-- one C_Traits tree per class, and the three classic trees are node GROUPS in
-- it. C_Traits.GetGroupDisplayInfoByTreeID names them, GetGroupCurrencyInfo
-- counts the points in each (a tree with none has no entry), and
-- C_Traits.GenerateImportString packs a whole build into ~40 characters.
-- PlayerSpellsUtil.InspectLoadout, what a talent-build chat link calls, opens
-- the game's own talent frame read-only on such a string, of any class, from
-- addon code. So this stores the points and the string, and leaves the drawing
-- to the game.
--
--   AltStableRosterDB.talents[guid] = {
--     stamp  = owner's time, strictly increasing per character,
--     spec   = the class's spec ID, lv = the level it was read at,
--     active = the active spec group,
--     trees  = { { name, icon } x3 }, in the game's order,
--     specs  = { [group] = { pts = { a, b, c }, build = import string } },
--   }
-- Written by the client playing the character, adopted by everyone else as
-- sent; the stamp orders them, as the Professions plugin's snapshots are.
--
-- Its own file: AltStableRoster.lua is at Lua 5.1's local and upvalue limits.
------------------------------------------------------------

local Roster = AltStable and AltStable.RosterPlugin
if not Roster then return end

AltStableRosterDB = AltStableRosterDB or {}

local T = {}
Roster.Talents = T

local BLOB_VERSION = "v1"

local function Store()
    if type(AltStableRosterDB) ~= "table" then AltStableRosterDB = {} end
    if type(AltStableRosterDB.talents) ~= "table" then AltStableRosterDB.talents = {} end
    return AltStableRosterDB.talents
end
T.Store = Store

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and type(t[name]) == "function" and t[name] or nil
end

-- A call that may be absent or throw: its first return, or nil.
local function Call(fn, ...)
    if not fn then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

------------------------------------------------------------
-- Reading the character being played
------------------------------------------------------------

local function SpecID()
    local util = rawget(_G, "PlayerUtil")
    local id = type(util) == "table" and Call(util.GetCurrentSpecID) or nil
    if id then return id end
    local index = Call(Api("C_SpecializationInfo", "GetSpecialization"))
    return index and Call(Api("C_SpecializationInfo", "GetSpecializationInfo"), index) or nil
end

-- Names travel inside the sync blob, so its separators can't be in them.
local function Clean(s)
    return (tostring(s or ""):gsub("[|;,:\n\r]", " "))
end

-- The whole reading, or nil when the client can't give one (no tree yet, the
-- API absent): nil claims nothing, so the stored reading is kept.
function T.Read()
    local spec = SpecID()
    local tree = spec and Call(Api("C_ClassTalents", "GetTraitTreeForSpec"), spec)
    if not tree then return nil end
    local displays = Call(Api("C_Traits", "GetGroupDisplayInfoByTreeID"), tree)
    if type(displays) ~= "table" or #displays ~= 3 then return nil end
    local order = {}
    for i, d in ipairs(displays) do order[i] = d end
    table.sort(order, function(a, b) return (a.orderIndex or 0) < (b.orderIndex or 0) end)

    local r = { spec = spec, lv = UnitLevel("player") or 0, trees = {}, specs = {} }
    local ids = {}
    for i, d in ipairs(order) do
        if type(d.groupID) ~= "number" then return nil end
        r.trees[i] = { name = Clean(d.displayName), icon = tonumber(d.icon) or 0 }
        ids[i] = d.groupID
    end

    local groups = tonumber(Call(rawget(_G, "GetNumSpecGroups"))) or 1
    r.active = tonumber(Call(Api("C_SpecializationInfo", "GetActiveSpecGroup"))) or 1
    for g = 1, math.max(groups, 1) do
        local config = Call(Api("C_SpecializationInfo", "GetCombatConfigIDForSpecGroup"), g)
        if config then
            local pts = { 0, 0, 0 }
            local infos = Call(Api("C_Traits", "GetGroupCurrencyInfo"), config, ids)
            if type(infos) ~= "table" then return nil end
            for _, info in ipairs(infos) do
                for i, id in ipairs(ids) do
                    if info.traitNodeGroupID == id then
                        local c = type(info.currencyInfos) == "table" and info.currencyInfos[1]
                        pts[i] = tonumber(c and c.spent) or 0
                    end
                end
            end
            local build = Call(Api("C_Traits", "GenerateImportString"), config)
            if type(build) ~= "string" or not build:find("^[%w%+/=]+$") then build = nil end
            r.specs[g] = { pts = pts, build = build }
        end
    end
    if not r.specs[r.active] then return nil end
    return r
end

-- Same reading, stamp aside: a rescan that changes nothing moves nothing.
local function Same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a.spec ~= b.spec or a.lv ~= b.lv or a.active ~= b.active then return false end
    for i = 1, 3 do
        local x, y = a.trees and a.trees[i], b.trees and b.trees[i]
        if not (x and y) or x.name ~= y.name or x.icon ~= y.icon then return false end
    end
    for g = 1, 2 do
        local x, y = a.specs and a.specs[g], b.specs and b.specs[g]
        if (x == nil) ~= (y == nil) then return false end
        if x then
            if x.build ~= y.build then return false end
            for i = 1, 3 do if x.pts[i] ~= y.pts[i] then return false end end
        end
    end
    return true
end

function T.Scan()
    local guid = UnitGUID("player")
    local r = guid and T.Read()
    if not r then return false end
    local held = Store()[guid]
    if Same(held, r) then return false end
    -- Strictly increasing: two readings in one second must not share a stamp.
    r.stamp = math.max(time(), (type(held) == "table" and held.stamp or 0) + 1)
    Store()[guid] = r
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if Roster.isActive and Roster.Refresh then Roster.Refresh() end
    return true
end

-- One scan a second after a burst of events: a respec fires several.
local pending
function T.ScheduleScan()
    if pending then return end
    pending = true
    C_Timer.After(1, function() pending = nil; T.Scan() end)
end

------------------------------------------------------------
-- Sync: one line per character, "v1|s=..|sp=..|lv=..|a=..|t=..|g=.."
------------------------------------------------------------

function T.Serialize(guid)
    local e = Store()[guid]
    if type(e) ~= "table" or not e.stamp then return "" end
    local trees, specs = {}, {}
    for i = 1, 3 do
        local t = e.trees[i]
        trees[i] = Clean(t.name) .. "," .. tostring(tonumber(t.icon) or 0)
    end
    for g = 1, 2 do
        local s = e.specs[g]
        specs[g] = s and (s.pts[1] .. "," .. s.pts[2] .. "," .. s.pts[3] .. "," .. (s.build or "")) or ""
    end
    return ("%s|s=%d|sp=%d|lv=%d|a=%d|t=%s|g=%s"):format(BLOB_VERSION, e.stamp, e.spec, e.lv,
        e.active, table.concat(trees, ";"), table.concat(specs, ";"))
end

-- nil for anything malformed: a bad line keeps what we hold.
function T.Parse(blob)
    if type(blob) ~= "string" then return nil end
    local ver, s, sp, lv, a, t, g = blob:match(
        "^(v%d+)|s=(%d+)|sp=(%d+)|lv=(%d+)|a=(%d+)|t=([^|]*)|g=([^|]*)$")
    if ver ~= BLOB_VERSION then return nil end
    local r = { stamp = tonumber(s), spec = tonumber(sp), lv = tonumber(lv), active = tonumber(a),
                trees = {}, specs = {} }
    for name, icon in (t .. ";"):gmatch("([^;,]*),(%d+);") do
        r.trees[#r.trees + 1] = { name = name, icon = tonumber(icon) }
    end
    if #r.trees ~= 3 then return nil end
    local i = 0
    for seg in (g .. ";"):gmatch("([^;]*);") do
        i = i + 1
        if i > 2 then return nil end
        if seg ~= "" then
            local p1, p2, p3, build = seg:match("^(%d+),(%d+),(%d+),([%w%+/=]*)$")
            if not p1 then return nil end
            r.specs[i] = { pts = { tonumber(p1), tonumber(p2), tonumber(p3) },
                           build = build ~= "" and build or nil }
        end
    end
    if r.active ~= 1 and r.active ~= 2 then return nil end
    if not r.specs[r.active] then return nil end
    return r
end

function T.Deserialize(guid, blob)
    if not guid then return end
    local r = T.Parse(blob)
    if not r then return end
    -- Strictly newer only: our own echoes come back equal, and one of our alts
    -- played on another PC comes back newer and is taken.
    local held = Store()[guid]
    if type(held) == "table" and (held.stamp or 0) >= r.stamp then return end
    Store()[guid] = r
    -- No TouchCharacter: receiving is not a change of ours.
    if Roster.isActive and Roster.Refresh then Roster.Refresh() end
end

function T.Forget(guid) if guid then Store()[guid] = nil end end

function T.Cleanup(keepGuid)
    for guid in pairs(Store()) do
        if guid ~= keepGuid then Store()[guid] = nil end
    end
end

-- Readings whose character the core no longer knows.
function T.PruneOrphans()
    for guid in pairs(Store()) do
        local c = AltStableDB and AltStableDB[guid]
        if type(c) ~= "table" or not c.name then Store()[guid] = nil end
    end
end

------------------------------------------------------------
-- What the detail pane shows
------------------------------------------------------------

function T.Get(guid)
    local e = guid and Store()[guid]
    return type(e) == "table" and e or nil
end

-- The other spec group, when there is one.
local function Other(e)
    local other = e.active == 1 and 2 or 1
    return e.specs[other]
end

function T.HasRow(char, def)
    local e = T.Get(char and char.guid)
    if not e then return false end
    if def.talentOther then return Other(e) ~= nil end
    return e.trees[def.talent] ~= nil and e.specs[e.active] ~= nil
end

function T.Label(char, def)
    local e = T.Get(char and char.guid)
    if not e then return "" end
    if def.talentOther then return def.label or "" end
    local t = e.trees[def.talent]
    if not t then return "" end
    local icon = (tonumber(t.icon) or 0) > 0 and ("|T" .. t.icon .. ":0|t ") or ""
    return icon .. t.name
end

function T.Value(char, def)
    local e = T.Get(char and char.guid)
    if not e then return "-" end
    if def.talentOther then
        local s = Other(e)
        return s and table.concat(s.pts, "/") or "-"
    end
    local s = e.specs[e.active]
    return s and tostring(s.pts[def.talent] or 0) or "-"
end

-- The game's frame, read-only on the stored build: what a talent-build chat
-- link opens. Out of combat only: it shows a UI panel.
function T.CanView(guid)
    local e = T.Get(guid)
    local s = e and e.specs[e.active]
    if not (s and s.build) then return false end
    local util = rawget(_G, "PlayerSpellsUtil")
    return type(util) == "table" and type(util.InspectLoadout) == "function"
end

-- The game's panel manager closes AltStable as the talent frame opens: showing
-- a centre panel runs CloseWindows, which hides every frame in UISpecialFrames,
-- and the sheet is there so Escape closes it. The sheet can't simply stay up
-- either: it is DIALOG strata and would cover the talent frame. So it is a round
-- trip instead: closing the talent frame we opened brings the sheet back, on the
-- page it was showing (hiding the sheet doesn't leave the Roster's tab).
local returning, hooked
local function ReturnToSheet()
    if not returning then return end
    returning = nil
    if AltStable.EnsureSheetVisible then AltStable.EnsureSheetVisible() end
end

function T.View(guid)
    if InCombatLockdown() or not T.CanView(guid) then return false end
    local e = T.Get(guid)
    local s = e.specs[e.active]
    local sheet = rawget(_G, "AltStableSheet")
    local fromSheet = sheet and sheet:IsShown()
    local ok = pcall(PlayerSpellsUtil.InspectLoadout, ("%d:%d:%s"):format(e.spec, e.lv, s.build))
    local talents = rawget(_G, "PlayerSpellsFrame")
    if ok and fromSheet and talents and talents:IsShown() then
        returning = true
        if not hooked then
            talents:HookScript("OnHide", ReturnToSheet)
            hooked = true
        end
    end
    return ok
end

-- The button beside the "Talents" header.
function T.MakeButton(parent)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(44, 16)
    b:SetText("View")
    b:SetScript("OnClick", function(self) T.View(self.guid) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Talents")
        GameTooltip:AddLine("Opens this character's talents in the game's talent frame, as they "
            .. "were when it was last played. Read-only.", 1, 1, 1, true)
        if InCombatLockdown() then GameTooltip:AddLine("Not in combat.", 1, 0.3, 0.3) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    return b
end

-- Right-aligned with the column's values, on the header's line (y, from the
-- panel's top).
function T.PlaceButton(b, guid, right, y)
    b.guid = guid
    if not T.CanView(guid) then b:Hide(); return end
    b:ClearAllPoints()
    b:SetPoint("TOPRIGHT", b:GetParent(), "TOPLEFT", right, y + 2)
    b:SetEnabled(not InCombatLockdown())
    b:Show()
end

-- At the plugin's bootstrap: drop readings of forgotten characters, pull
-- everything once when there is nothing to build on (the first login with this
-- version), then read the character being played.
function T.Start()
    T.PruneOrphans()
    if AltStable.ResetPeerWatermarks and not next(Store()) then AltStable.ResetPeerWatermarks() end
    T.ScheduleScan()
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

local EVENTS = { "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED",
                 "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_LEVEL_UP" }
local frame = CreateFrame("Frame")
for _, ev in ipairs(EVENTS) do pcall(frame.RegisterEvent, frame, ev) end
frame:SetScript("OnEvent", function() T.ScheduleScan() end)

T._test = { Same = Same, Clean = Clean, EVENTS = EVENTS,
            ResetPending = function() pending = nil end }
