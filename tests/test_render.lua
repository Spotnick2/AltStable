------------------------------------------------------------
-- test_render.lua — the capture probe's giving-up paths (#15)
--
-- This file had three review rounds find three real bugs in it and not one
-- test, because the suite could not load it: InCombatLockdown, SetUIVisibility,
-- Screenshot and hooksecurefunc were all absent from the stubs. Those are
-- precisely the states the bugs lived in.
--
-- What is pinned here is ABANDONMENT, not the happy path. A capture hides the
-- player's entire interface for three seconds and writes records a separate
-- offline tool later consumes, so every way of giving up half-way has to leave
-- the interface back, the stage gone, the screenshot format restored, and - the
-- one that was missed - no usable record of a picture nobody wants.
--
-- The image work itself is not testable here and is not pretended to be: it
-- needs a real client to render a model and real screenshots on disk.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
AltStableProbeDB = {}
dofile("Compat.lua")

WoW.timers = {}
dofile("Tools/AltStableProbe/Render.lua")

local T = AltStableProbe and AltStableProbe._test
check("the probe exposes a test seam", T ~= nil)
if not T then
    print(("test_render: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end

------------------------------------------------------------
-- Combat on a fresh login, before anything has been built
------------------------------------------------------------
-- FIRST, deliberately: the stage is built lazily by the first capture or
-- preview, so this is the only point in the file where it genuinely does not
-- exist yet. Every check below constructs it, which is exactly how a crash here
-- stayed invisible - combat entry called frame:Hide() on a nil.

WoW.inCombat = true
local okFresh, freshErr = pcall(function()
    T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_DISABLED")
end)
check("combat before the stage exists does not error", okFresh, tostring(freshErr))
check("  and nothing was capturing to abandon", not T.capturing())
WoW.inCombat = false

local function renders() return (AltStableProbeDB.renders or {}) end
local function resetCapture()
    AltStableProbeDB = { renders = {}, looks = {} }
    WoW.inCombat, WoW.uiVisible, WoW.screenshots = false, true, 0
    WoW.timers = {}
    WoW.chatOut = {}
end

------------------------------------------------------------
-- Never in combat, from any entry point
------------------------------------------------------------
-- The automatic path checks this before it schedules, but /asrender and the
-- notice's own button reach Capture() directly. Hiding the interface for three
-- seconds during a pull is the single worst thing this feature can do.

resetCapture()
WoW.inCombat = true
T.Capture()
check("a capture is refused in combat", not T.capturing())
eq("  and nothing was photographed", WoW.screenshots, 0)
eq("  and the interface was never touched", WoW.uiVisible, true)
eq("  and no record was written", #renders(), 0)

------------------------------------------------------------
-- A capture in progress
------------------------------------------------------------

resetCapture()
T.Capture()
check("out of combat, the capture starts", T.capturing())
eq("  and the interface goes away", WoW.uiVisible, false)
local startedToken = T.token()

------------------------------------------------------------
-- Combat, mid-capture
------------------------------------------------------------

resetCapture()
T.Capture()
local before = T.token()
WoW.inCombat = true
T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_DISABLED")

check("combat abandons the capture", not T.capturing())
check("  and voids every pending callback", T.token() ~= before)
eq("  and the stage is gone at once", T.stage():IsShown(), false)
eq("  and the interface is back", WoW.uiVisible, true)

-- The pending timers must now do nothing, not fire late into a fight.
local shotsBefore = WoW.screenshots
WoW.flushTimers()
eq("  and the abandoned chain takes no pictures", WoW.screenshots, shotsBefore)
eq("  and writes no records", #renders(), 0)

------------------------------------------------------------
-- The player takes their interface back
------------------------------------------------------------
-- Alt+Z and Escape both call SetUIVisibility(true). This used only to set a
-- flag: the chain ran on, both shots were taken THROUGH the restored interface,
-- and both records were written. Finish() withheld the look fingerprint and
-- announced the portrait discarded - but the converter pairs from the RENDER
-- records, not the fingerprint, so the ruined pair stayed eligible and would
-- overwrite a good portrait with one full of action bars.

resetCapture()
T.Capture()
local tokenBefore = T.token()
eq("the interface is hidden while shooting", WoW.uiVisible, false)

SetUIVisibility(true)          -- the player presses Alt+Z

check("restoring the interface abandons the capture", not T.capturing())
check("  and voids every pending callback", T.token() ~= tokenBefore)
eq("  and dismisses the stage immediately", T.stage():IsShown(), false)
eq("  and leaves the interface the player asked for", WoW.uiVisible, true)

local shots = WoW.screenshots
WoW.flushTimers()
eq("  the abandoned chain takes no further pictures", WoW.screenshots, shots)
eq("  and leaves NO record for the converter to find", #renders(), 0)

------------------------------------------------------------
-- Records already written are taken back
------------------------------------------------------------
-- The truncation is the part that matters: a lone shot-1 record is harmless,
-- because the converter only pairs a 1 with a 2, but a chain that hangs after
-- BOTH shots leaves a complete pair from a capture nobody trusts.

resetCapture()
-- Records from an earlier, good capture that must survive.
table.insert(AltStableProbeDB.renders, { name = "Old Alt", guid = "g0", shot = 1 })
table.insert(AltStableProbeDB.renders, { name = "Old Alt", guid = "g0", shot = 2 })

T.Capture()
eq("the mark is taken at the start", T.renderMark(), 2)
table.insert(AltStableProbeDB.renders, { name = "New Alt", guid = "g1", shot = 1 })
table.insert(AltStableProbeDB.renders, { name = "New Alt", guid = "g1", shot = 2 })
eq("  with a full pair written since", #renders(), 4)

T.AbandonCapture(nil, true)
-- Nil-safe: when this regresses the list is the wrong LENGTH, and indexing a
-- missing entry aborts the file and hides every test below it.
eq("abandoning takes back what this capture wrote", #renders(), 2)
eq("  and keeps the earlier capture intact", renders()[1] and renders()[1].name, "Old Alt")
eq("  including its second shot", renders()[2] and renders()[2].shot, 2)

------------------------------------------------------------
-- Abandoning twice is harmless
------------------------------------------------------------
-- Combat and Alt+Z can land in either order, and the watchdog fires regardless.

resetCapture()
T.Capture()
table.insert(AltStableProbeDB.renders, { name = "Half", guid = "g2", shot = 1 })
T.AbandonCapture(nil, true)
local after = T.token()
table.insert(AltStableProbeDB.renders, { name = "Later", guid = "g3", shot = 1 })
T.AbandonCapture(nil, true)
eq("a second abandon changes nothing", T.token(), after)
check("  and does not eat a record it never wrote",
      #renders() == 1 and renders()[1].name == "Later",
      ("%d record(s)"):format(#renders()))

------------------------------------------------------------
-- The stage always goes, even if nothing is in flight
------------------------------------------------------------
-- It is a fullscreen frame on WorldFrame with no mouse: if a broken chain ever
-- leaves it up, neither Escape nor Alt+Z dismisses it and the player needs a
-- /reload. That is worth being unconditional about.

resetCapture()
T.Build()
T.stage():Show()
check("the stage can be up with no capture running", not T.capturing())
T.AbandonCapture(nil, false)
eq("  and abandoning still takes it down", T.stage():IsShown(), false)

------------------------------------------------------------
-- The two shots must not share a filename
------------------------------------------------------------
-- The client names screenshots to the second - WoWScrnShot_MMDDYY_HHMMSS.tga -
-- so two shots inside one second are ONE filename and the second overwrites the
-- first. What survives is a single file the converter cannot pair, and both
-- records claim the same stamp. At the original 0.9s gap that happened whenever
-- the clock ticked unkindly: Morphisto Ruskador recorded both shots at 02:14:44
-- and left one file behind.

local shutterGap = T.SHOT_DELAY + T.SWAP_DELAY
check("the gap between shutters exceeds one second", shutterGap > 1.0,
      ("%.2fs - two shots can share a filename"):format(shutterGap))
check("  and is not so long the pose can drift", shutterGap < 2.5,
      ("%.2fs"):format(shutterGap))

-- Strictly greater than one second is what guarantees a different second, at
-- ANY point in the clock's cycle. Worst case is a shot taken a hair before a
-- tick; it still has to land past the next one.
local worst = 0.999 + shutterGap
check("  so the second shot always lands in a later second",
      math.floor(worst) > math.floor(0.999),
      ("%.3f"):format(worst))

------------------------------------------------------------
-- The chain really is spaced that way
------------------------------------------------------------
-- The constants agreeing with each other proves nothing if the code schedules
-- something else, which is the mistake the roster review caught: asserting a
-- composition while the call site did its own thing.

-- Walk the timer chain on a virtual clock and record WHEN each shutter fires.
-- The chain is linear - one pending callback at a time, plus the watchdog,
-- which is far longer than any link and is skipped here.
local function shutterTimes()
    local clock, shots = 0, {}
    for _ = 1, 20 do
        local nextTimer
        for _, t in ipairs(WoW.timers) do
            if t.delay < 5 then nextTimer = t; break end   -- not the watchdog
        end
        if not nextTimer then break end
        for i, t in ipairs(WoW.timers) do
            if t == nextTimer then table.remove(WoW.timers, i); break end
        end
        clock = clock + nextTimer.delay
        local before = WoW.screenshots
        nextTimer.fn()
        if WoW.screenshots > before then shots[#shots + 1] = clock end
    end
    return shots
end

resetCapture()
T.Capture()
local watchdogDelay = 0
for _, t in ipairs(WoW.timers) do
    if t.delay > watchdogDelay then watchdogDelay = t.delay end
end
local shots = shutterTimes()

eq("a capture takes exactly two shots", #shots, 2)
check("the first waits for the model to stream in",
      shots[1] and shots[1] >= T.KEY_DELAY - 0.001, tostring(shots[1]))
-- The one the constants alone could not catch: the chain may not schedule its
-- own number. Hardcoding the old 0.25 here leaves SWAP_DELAY looking correct
-- while the shots collide exactly as before.
check("the SCHEDULED gap between shutters exceeds one second",
      shots[2] and shots[1] and (shots[2] - shots[1]) > 1.0,
      shots[2] and ("%.2fs as scheduled"):format(shots[2] - shots[1]) or "no second shot")
check("  and matches the constants it is built from",
      shots[2] and math.abs((shots[2] - shots[1]) - shutterGap) < 0.001,
      shots[2] and ("%.3f vs %.3f"):format(shots[2] - shots[1], shutterGap) or "-")
check("the watchdog outlasts the whole sequence",
      watchdogDelay > (shots[2] or 0), ("%.1f vs %.2f"):format(watchdogDelay, shots[2] or 0))

print(("test_render: %d passed, %d failed"):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
