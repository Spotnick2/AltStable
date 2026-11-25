------------------------------------------------------------
-- test_drawn.lua - the helm and cloak as the game draws them (#485)
--
-- Pinned: one model for the session, 1x1 at alpha 0, shown, on WorldFrame,
-- no mouse; a slot drawn with a hide-visual source reads hidden, another
-- source shown, nothing or an error unknown (the field is left alone); a
-- reading stamps drawnAt, and a change also gearReadAt, the delta, the
-- portrait status and the sheet; one read at a time with one trailing read;
-- a reading before the record exists is written by the scan; the triggers;
-- flags without drawnAt (the broken ones) are dropped at login and from an
-- older peer.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
local T = AltStable._test

-- Timers in the order they fall due.
local now, due = 0, {}
C_Timer.After = function(d, fn) due[#due + 1] = { at = now + d, fn = fn } end
local function advance(sec)
    local stop = now + sec
    while true do
        local best, bi
        for i, e in ipairs(due) do
            if e.at <= stop and (not best or e.at < best.at) then best, bi = e, i end
        end
        if not best then break end
        table.remove(due, bi)
        now = best.at
        best.fn()
    end
    now = stop
end

-- The model the reader makes: what it is drawn with is up to the test.
local drawn, models, setUnits = {}, {}, 0
local realCreate = CreateFrame
CreateFrame = function(kind, name, parent, ...)
    local f = realCreate(kind, name, parent, ...)
    if kind == "DressUpModel" then
        models[#models + 1] = f
        f._parent = parent
        f:EnableMouse(true)   -- whatever the default, the reader must turn it off
        f.SetUnit = function(self, unit) self._unit = unit; setUnits = setUnits + 1 end
        f.GetItemTransmogInfo = function(_, slot)
            local d = drawn[slot]
            if d == "error" then error("not loaded") end
            return { appearanceID = d or 0 }
        end
    end
    return f
end
WorldFrame = WorldFrame or realCreate("Frame", "WorldFrame")
C_TransmogCollection = {
    GetSourceInfo = function(id)
        if id == 77344 then return { itemID = 134110, isHideVisual = true } end
        if id == 77345 then return { itemID = 134111, isHideVisual = true } end
        if id == 999 then return nil end
        return { itemID = id * 10, isHideVisual = false }
    end,
}

local statusRefreshes, sheetRefreshes = 0, 0
AltStable.RefreshPortraitStatus = function() statusRefreshes = statusRefreshes + 1 end
AltStable.RefreshSheet = function() sheetRefreshes = sheetRefreshes + 1 end

dofile("Drawn.lua")
local D = AltStable.Drawn
local me = UnitGUID("player")

local function fresh(rec)
    T.ResetDrawn()
    due, drawn, models, setUnits = {}, {}, {}, 0
    statusRefreshes, sheetRefreshes = 0, 0
    AltStableDB = { [me] = rec or { guid = me, name = "Me", lastUpdate = 1, gearReadAt = 5 } }
end

------------------------------------------------------------
-- The model
------------------------------------------------------------

fresh()
WoW.now = 1000
D.Read()
local m = models[1]
check("the reader makes a DressUpModel", m ~= nil)
eq("  on WorldFrame, which the showcase doesn't hide", m and m._parent, WorldFrame)
check("  1x1", m and m:GetWidth() == 1 and m:GetHeight() == 1)
eq("  at alpha 0", m and m:GetAlpha(), 0)
check("  shown (a model never shown reads nothing)", m and m:IsShown())
check("  taking no mouse", m and not m:IsMouseEnabled())
eq("  set on the player", m and m._unit, "player")

------------------------------------------------------------
-- Reading
------------------------------------------------------------

drawn = { [1] = 77344, [15] = 307653 }
advance(0.4)
eq("nothing read before 0.5 s", AltStableDB[me].hidehelm, nil)
advance(0.1)
local rec = AltStableDB[me]
eq("a hidden helm reads hidden", rec.hidehelm, 1)
eq("  a drawn cloak shown", rec.hidecloak, 0)
eq("  stamped", rec.drawnAt, 1000)
eq("  a change dates the gear reading (the Companion's gearReadAt)", rec.gearReadAt, 1000)
eq("  and the delta", rec.lastUpdate, 1000)
eq("  the portrait status is asked again", statusRefreshes, 1)
eq("  and the sheet redrawn", sheetRefreshes, 1)

WoW.now = 2000
D.Read()
advance(1)
eq("the same reading: stamped again", rec.drawnAt, 2000)
eq("  but no change to date", rec.gearReadAt, 1000)
eq("  nor anything to tell", statusRefreshes, 1)
eq("one model for the session", #models, 1)

drawn = { [1] = 158756, [15] = 77345 }
D.Read()
advance(1)
eq("the helm shown again", rec.hidehelm, 0)
eq("  the cloak hidden", rec.hidecloak, 1)

drawn = { [1] = 0, [15] = "error" }
WoW.now = 3000
D.Read()
advance(1)
eq("nothing drawn (an empty slot): left as it was", rec.hidehelm, 0)
eq("  a model error too", rec.hidecloak, 1)
eq("  and nothing read is no reading", rec.drawnAt, 2000)
drawn = { [1] = 158756, [15] = 999 }
D.Read()
advance(1)
eq("a source without info: left as it was (not taken as shown)", rec.hidecloak, 1)
eq("  the other slot still read", rec.drawnAt, 3000)

------------------------------------------------------------
-- One at a time, the last change wins
------------------------------------------------------------

fresh()
drawn = { [1] = 77344 }
D.Read()
check("a read during a read waits", not D.Read())
D.Read()
advance(0.5)
drawn = { [1] = 158756 }
eq("  one more read after it, however many came", setUnits, 2)
advance(0.5)
eq("  the last change wins", AltStableDB[me].hidehelm, 0)
advance(5)
eq("  and no more", setUnits, 2)

------------------------------------------------------------
-- A reading before the record exists
------------------------------------------------------------

fresh()
AltStableDB = {}
drawn = { [1] = 77344, [15] = 307653 }
D.Read()
advance(1)
check("no record yet: nothing to write", AltStableDB[me] == nil)
local scanned = { guid = me, name = "Me" }
D.OnScanned(scanned)
eq("the first scan writes it", scanned.hidehelm, 1)
eq("  stamped", scanned.drawnAt ~= nil, true)
local other = { guid = "Player-Other", name = "O" }
D.OnScanned(other)
eq("  another character's scan is untouched", other.hidehelm, nil)

------------------------------------------------------------
-- Triggers
------------------------------------------------------------

local onEvent = T.DrawnFrame:GetScript("OnEvent")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "TRANSMOGRIFY_CLOSE", "PLAYER_EQUIPMENT_CHANGED" }) do
    check("listens to " .. e, T.DrawnFrame:IsEventRegistered(e))
end
fresh()
onEvent(T.DrawnFrame, "PLAYER_ENTERING_WORLD", true, false)
advance(1.9)
eq("a login reads at 2 s, with the login scan", setUnits, 0)
advance(0.1)
eq("  then", setUnits, 1)
fresh()
onEvent(T.DrawnFrame, "PLAYER_ENTERING_WORLD", false, true)
advance(2)
eq("a reload too", setUnits, 1)
fresh()
onEvent(T.DrawnFrame, "PLAYER_ENTERING_WORLD", false, false)
advance(10)
eq("zoning reads nothing", setUnits, 0)
fresh()
onEvent(T.DrawnFrame, "TRANSMOGRIFY_CLOSE")
eq("closing the transmogrifier reads at once", setUnits, 1)
fresh()
onEvent(T.DrawnFrame, "PLAYER_EQUIPMENT_CHANGED", 5, false)
advance(10)
eq("a chest change reads nothing", setUnits, 0)
onEvent(T.DrawnFrame, "PLAYER_EQUIPMENT_CHANGED", 1, false)
onEvent(T.DrawnFrame, "PLAYER_EQUIPMENT_CHANGED", 15, true)
advance(2.9)
eq("a helm or cloak change waits for Core's rescan, 3 s", setUnits, 0)
advance(0.1)
eq("  then reads once for both", setUnits, 1)
advance(5)
eq("  and only once", setUnits, 1)

------------------------------------------------------------
-- The broken flags: dropped without the stamp
------------------------------------------------------------

local old = { guid = "Player-Old", name = "Old", hidehelm = 1, hidecloak = 1 }
AltStable.DropUndrawnFlags(old)
check("flags without drawnAt are dropped (absent = shown)", old.hidehelm == nil and old.hidecloak == nil)
local new = { guid = "Player-New", name = "New", hidehelm = 1, hidecloak = 0, drawnAt = 5 }
AltStable.DropUndrawnFlags(new)
check("  with it they stay", new.hidehelm == 1 and new.hidecloak == 0)

AltStableDB = { [me] = { guid = me, name = "Me", hidehelm = 1, hidecloak = 1 },
                ["Player-Read"] = { guid = "Player-Read", name = "R", hidehelm = 1, drawnAt = 9 } }
local coreEvent = T.frame:GetScript("OnEvent")
coreEvent(T.frame, "PLAYER_LOGIN")
eq("at login, every unstamped record loses them", AltStableDB[me].hidehelm, nil)
eq("  a stamped one keeps them", AltStableDB["Player-Read"].hidehelm, 1)

AltStableDB = {}
T.DeserializeFullDB(T.SerializeChar({ guid = "Player-Peer", name = "P", class = "MAGE", level = 30,
    lastUpdate = 1000, hidehelm = 1, hidecloak = 0 }) .. "\n" .. T.CHAR_SEP, "OldPeer")
eq("an older peer's flags (no drawnAt) are dropped", AltStableDB["Player-Peer"].hidehelm, nil)
T.DeserializeFullDB(T.SerializeChar({ guid = "Player-Peer", name = "P", class = "MAGE", level = 30,
    lastUpdate = 2000, hidehelm = 1, hidecloak = 0, drawnAt = 1900 }) .. "\n" .. T.CHAR_SEP, "NewPeer")
eq("  a current peer's arrive", AltStableDB["Player-Peer"].hidehelm, 1)
eq("  with the stamp, as a number", AltStableDB["Player-Peer"].drawnAt, 1900)
T.DeserializeFullDB(T.SerializeChar({ guid = "Player-Peer", name = "P", class = "MAGE", level = 30,
    lastUpdate = 3000, hidehelm = 1 }) .. "\n" .. T.CHAR_SEP, "OldPeer")
eq("  then an older peer's newer record: the stamp doesn't linger", AltStableDB["Player-Peer"].drawnAt, nil)
eq("  nor its flag", AltStableDB["Player-Peer"].hidehelm, nil)

WoW.finish("test_drawn", passed, failed)
