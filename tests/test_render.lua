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
    -- Module state too, not just the stubs. pending / combatSettle / capturing
    -- are locals in Render.lua, and StartCountdown is idempotent - so a stale
    -- `pending` leaking in from an earlier block makes the next
    -- StartCountdown a silent no-op while pendingKind() still answers
    -- "countdown", and the block passes against a timer it never created.
    local t = AltStableProbe and AltStableProbe._test
    if t and t.CancelPending then t.CancelPending() end
    -- `capturing` too, which this helper claimed to reset and did not. A block
    -- that leaves a capture RUNNING makes the next StartCountdown a silent
    -- no-op - it refuses while one is in flight - so the block after it tests
    -- a countdown that was never started. No message: this is housekeeping
    -- between blocks, not something a player did.
    if t and t.AbandonCapture then t.AbandonCapture(nil, true) end
    -- WoW.dead too. A block that leaves it set turns every later Capture() into
    -- a refusal and every ConsiderCapture() into an early return, so the block
    -- after it asserts "nothing was queued" and passes against a feature that
    -- is simply switched off. Exactly the leak this helper's comment describes,
    -- with a new flag.
    WoW.dead = false
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

------------------------------------------------------------
-- The quiet-after-combat wait cancels quietly
------------------------------------------------------------
-- Reported from a live session: "[render] auto-capture cancelled - combat
-- started" on EVERY pull. The wait is armed when combat ends and cancelled the
-- moment the next fight begins, so while questing that is a line of chat per
-- mob - announcing the end of something whose beginning was never announced.
--
-- The countdown is the opposite case. It says "refreshing your portrait in 5s"
-- when it starts, so cancelling it silently would leave the player waiting for
-- a picture that is not coming.

do
    resetCapture()
    local events = T.events:GetScript("OnEvent")

    -- Leaving combat arms the silent wait.
    events(T.events, "PLAYER_REGEN_ENABLED")
    eq("leaving combat arms the quiet wait", T.pendingKind(), "settle")

    -- Entering it again cancels the wait, and says nothing.
    WoW.chatOut = {}
    events(T.events, "PLAYER_REGEN_DISABLED")
    eq("  and the next pull cancels it", T.pendingKind(), nil)
    eq("  without a word, because nothing announced it", #(WoW.chatOut or {}), 0)

    -- Ten pulls, still nothing.
    WoW.chatOut = {}
    for _ = 1, 10 do
        events(T.events, "PLAYER_REGEN_ENABLED")
        events(T.events, "PLAYER_REGEN_DISABLED")
    end
    eq("  ten pulls in a row produce ten lines of nothing", #(WoW.chatOut or {}), 0)
end

do
    -- The countdown is the opposite case and must still speak. It announced
    -- itself when it started, so cancelling it in silence leaves the player
    -- waiting for a picture that is not coming.
    resetCapture()
    T.StartCountdown("gear changed")
    eq("a countdown is pending", T.pendingKind(), "countdown")
    WoW.chatOut = {}
    T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_DISABLED")
    eq("  and combat cancels it", T.pendingKind(), nil)
    local said = table.concat(WoW.chatOut or {}, " ")
    check("  but says so, because it had announced itself",
          #(WoW.chatOut or {}) > 0, "the player was left waiting in silence")
    -- The REASON is the payload. A player told "refreshing your portrait in 5s"
    -- and then handed a bare "auto-capture cancelled" has no idea combat did
    -- it, which is the confusion the countdown message exists to prevent.
    check("  and says what cancelled it", said:find("combat started", 1, true) ~= nil,
          said)
end

do
    -- /asrender cancel is the player asking, so silence would read as a command
    -- that did nothing. Driven through the real command, because the argument
    -- it passes is the whole point.
    resetCapture()
    T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_ENABLED")
    WoW.chatOut = {}
    SlashCmdList["ASRENDER"]("cancel")
    -- On the CONTENT, not the line count. "nothing pending" is also one line,
    -- so a CancelPending that cancelled the timer and reported false would
    -- satisfy a count - and reporting false while cancelling is exactly the
    -- regression this function's own comment records as having shipped once.
    local answer = table.concat(WoW.chatOut or {}, " ")
    check("/asrender cancel confirms it cancelled the quiet wait",
          answer:find("cancelled", 1, true) ~= nil, answer)
    check("  and does not claim nothing was pending",
          answer:find("nothing pending", 1, true) == nil, answer)
    eq("  and there is nothing left pending", T.pendingKind(), nil)
end

do
    -- The same promise one level down, at the function rather than the command.
    --
    -- NOT a duplicate of the block above, which drives SlashCmdList and so
    -- pins the ARGUMENT the command passes. This one pins what CancelPending
    -- does when given it - the two failures are different, and testing only
    -- this one is exactly how the missing `announce` survived the first pass.
    resetCapture()
    local events = T.events:GetScript("OnEvent")
    events(T.events, "PLAYER_REGEN_ENABLED")
    WoW.chatOut = {}
    check("cancelling the quiet wait by hand is confirmed",
          T.CancelPending(nil, true) == true)
    check("  out loud", #(WoW.chatOut or {}) > 0,
          "the player asked and got no answer")

    WoW.chatOut = {}
    eq("cancelling nothing reports nothing was pending", T.CancelPending(nil, true), false)
end

------------------------------------------------------------
-- Turning auto-capture off stops what is already coming
------------------------------------------------------------
-- The countdown announces itself five seconds ahead. Type /asrender auto inside
-- that window and you are told auto-capture is off - and then, three seconds
-- later, the interface vanishes for a capture anyway.

do
    resetCapture()
    AltStableProbeDB.autoCaptureOff = nil
    T.StartCountdown("gear changed")
    eq("a countdown is pending", T.pendingKind(), "countdown")

    WoW.chatOut = {}
    SlashCmdList["ASRENDER"]("auto")
    eq("  turning auto off cancels it", T.pendingKind(), nil)
    local said = table.concat(WoW.chatOut or {}, " ")
    check("  and says so, rather than going quiet",
          said:find("cancelled", 1, true) ~= nil, said)

    WoW.screenshots = 0
    WoW.flushTimers()
    eq("  so no picture is taken", WoW.screenshots, 0)
    AltStableProbeDB.autoCaptureOff = nil
end

do
    -- And the countdown asks again when it fires, for every other way the
    -- answer could have changed in those five seconds.
    resetCapture()
    AltStableProbeDB.autoCaptureOff = nil
    T.StartCountdown("gear changed")
    AltStableProbeDB.autoCaptureOff = true    -- changed behind the command's back
    WoW.screenshots = 0
    WoW.flushTimers()
    eq("a countdown that fires with auto off takes no picture", WoW.screenshots, 0)
    check("  and is not left capturing", not T.capturing())
    AltStableProbeDB.autoCaptureOff = nil
end

------------------------------------------------------------
-- The blackout has to cover what somebody lifted out of UIParent
------------------------------------------------------------
-- AltStable's showcase reparents the sheet and GameTooltip out from under
-- UIParent so that hiding the game UI does not take them with it. Hiding
-- UIParent therefore does not hide them - and UIParent:IsShown() reports the
-- interface gone while the addon's own window is still in front of the camera.
--
-- This is not hypothetical. Every portrait taken with the sheet's capture
-- button was a picture of the sheet, tooltip included, because the button
-- lives in the sheet's title bar - so the sheet is open every time it is used.

do
    -- The sheet as the showcase leaves it: shown, opaque, and parented OUTSIDE
    -- UIParent. The global name is how the probe finds it, the probe being a
    -- separate addon with no access to AltStable's internals.
    local sheet = CreateFrame("Frame", "AltStableSheet", UIParent)
    -- The NAME is the contract. The probe is a separate addon and cannot reach
    -- into AltStable's locals, so the global a named frame creates is the only
    -- handle it has - rename the sheet's frame and the blackout stops covering
    -- it, silently.
    check("a named frame is reachable by that name", _G["AltStableSheet"] == sheet)
    sheet:SetParent(nil)
    sheet:Show()
    sheet:SetAlpha(1)

    GameTooltip:SetParent(nil)
    GameTooltip:Show()
    GameTooltip:SetAlpha(1)

    -- Earlier blocks in this file leave the blackout on, and HideUI short-
    -- circuits when it is already hidden. Start from a known interface.
    T.ShowUI()
    UIParent:Show()
    check("the interface starts up", UIParent:IsShown())

    check("the blackout reports success", T.HideUI())
    check("  UIParent is down", UIParent:IsShown() == false)
    eq("  and the lifted sheet is invisible too", sheet:GetAlpha(), 0)
    eq("  as is the lifted tooltip", GameTooltip:GetAlpha(), 0)

    T.ShowUI()
    eq("restoring brings the sheet back", sheet:GetAlpha(), 1)
    eq("  and the tooltip", GameTooltip:GetAlpha(), 1)
    check("  and the interface", UIParent:IsShown())

    -- The alpha that was THERE, not a hardcoded 1: a player running the sheet
    -- at reduced opacity must not have it reset by taking a picture.
    sheet:SetAlpha(0.6)
    T.HideUI()
    eq("a translucent sheet still goes fully invisible", sheet:GetAlpha(), 0)
    T.ShowUI()
    eq("  and comes back at the alpha it had", sheet:GetAlpha(), 0.6)
    sheet:SetAlpha(1)

    -- A capture abandoned after the blackout leaves no uiHidden to key off, so
    -- the restore has to happen outside that branch or the player is left
    -- looking at an invisible sheet with no way to know why.
    T.HideUI()
    eq("the sheet is invisible mid-capture", sheet:GetAlpha(), 0)
    T.ShowUI()                       -- the real restore, clears uiHidden
    T.ShowUI()                       -- and again, as an abandoned capture would
    eq("a second restore is harmless", sheet:GetAlpha(), 1)

    -- A sheet that is NOT lifted is already covered by the blackout, and is
    -- left alone. Touching it would add a second thing that has to be undone
    -- for no gain - and the one failure mode here is an invisible window, so
    -- the fewer frames whose alpha is on loan, the better.
    T.ShowUI()
    sheet:SetParent(UIParent)
    T.HideUI()
    check("a sheet still under UIParent is not collected", (function()
        for _, e in ipairs(T.strays() or {}) do
            if e.frame == sheet then return false end
        end
        return true
    end)(), "the lifted GameTooltip is expected here; the sheet is not")
    eq("  and its alpha is left alone", sheet:GetAlpha(), 1)
    T.ShowUI()
    sheet:SetParent(nil)

    -- Alt+Z mid-capture, driven through a REAL capture rather than HideUI on
    -- its own, because the hook that makes this dangerous only fires while a
    -- capture is running.
    --
    -- The engine call is how the player takes their interface back. The hook
    -- clears uiHidden on the spot and abandons the shot - so a restore that
    -- keyed off uiHidden would skip the strays and leave the sheet at alpha 0
    -- with nothing to explain why. The player's only clue would be that their
    -- addon window had vanished, and Alt+Z is exactly what somebody does when
    -- an addon starts taking pictures unexpectedly.
    resetCapture()
    T.Capture()
    check("a capture is running", T.capturing())
    eq("  and the sheet went invisible with the interface", sheet:GetAlpha(), 0)

    SetUIVisibility(true)              -- the player presses Alt+Z
    check("  which abandons the capture", not T.capturing())
    eq("Alt+Z mid-capture still gives the sheet back", sheet:GetAlpha(), 1)

    -- The fallback blackout, on a client with no SetUIVisibility. It hides
    -- UIParent directly and has exactly the same blind spot.
    do
        local realSetUIVisibility = SetUIVisibility
        SetUIVisibility = nil
        UIParent:Show()
        check("the fallback blackout reports success", T.HideUI())
        check("  UIParent is down", UIParent:IsShown() == false)
        eq("  and it covers the lifted sheet too", sheet:GetAlpha(), 0)
        T.ShowUI()
        eq("  restoring brings it back", sheet:GetAlpha(), 1)
        SetUIVisibility = realSetUIVisibility
    end

    -- A sheet that is CLOSED is not something to restore: bringing it back at
    -- alpha 1 would be fine, but recording it at all is noise, and the same
    -- rule keeps the probe from touching frames it has no business in.
    sheet:Hide()
    T.HideUI()
    check("a closed sheet is not collected", (function()
        for _, e in ipairs(T.strays() or {}) do
            if e.frame == sheet then return false end
        end
        return true
    end)())
    T.ShowUI()
    sheet:Show()

    -- Put the world back for anything after this block.
    GameTooltip:SetParent(UIParent)
    sheet:Hide()
end

------------------------------------------------------------
-- A corpse run is not a gear change
------------------------------------------------------------
-- Reported from a live level-one corpse run: three captures in as many
-- minutes, each announced as "gear changed since your last portrait", on a
-- character that had never picked anything up.
--
-- C_PlayerInfo.GetDisplayID() returns the GHOST display while you are one, and
-- it is part of the look fingerprint - deliberately, because a barber visit or
-- a race change should refresh the portrait. So dying flips the fingerprint and
-- resurrecting flips it back: two "your look changed" events per death, and
-- every picture taken in between is of a wisp.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"

    -- Alive and unphotographed: the capture is wanted.
    WoW.dead = false
    T.ConsiderCapture("gear changed since your last portrait")
    check("alive, a look change starts a countdown", T.pendingKind() == "countdown",
          tostring(T.pendingKind()))
    T.CancelPending()

    -- The same look change, as a ghost.
    WoW.dead = true
    T.ConsiderCapture("gear changed since your last portrait")
    eq("dead, nothing is queued at all", T.pendingKind(), nil)

    -- The direct routes land in Capture() without passing ConsiderCapture, and
    -- /asrender is what a player reaches for when they want a picture NOW.
    WoW.screenshots = 0
    T.Capture()
    check("a capture asked for directly is refused while dead", not T.capturing())
    eq("  and nothing was photographed", WoW.screenshots, 0)
    eq("  and the interface was never touched", WoW.uiVisible, true)

    -- Dying inside the five-second countdown. Most of a corpse run is exactly
    -- this, so the check at the top of ConsiderCapture is not enough on its own:
    -- the timer was armed while the player was alive.
    WoW.dead = false
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    check("the countdown is running", T.pendingKind() == "countdown")
    WoW.dead = true                       -- they die while it counts
    WoW.screenshots = 0
    WoW.flushTimers()
    eq("a countdown that fires after you die takes no picture", WoW.screenshots, 0)
    check("  and is not left capturing", not T.capturing())

    WoW.dead = false
end

------------------------------------------------------------
-- The countdown is cancellable on screen
------------------------------------------------------------
-- It used to be a line of chat saying to type /asrender cancel. That scrolls
-- away behind combat spam, and it asks somebody who is mid-corpse-run to find
-- and type a command inside five seconds.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"

    check("nothing is on screen to begin with", T.PromptText() == nil)

    T.StartCountdown("gear changed since your last portrait")
    local text = T.PromptText()
    check("the countdown puts a prompt on screen", text ~= nil, tostring(text))
    check("  saying how long is left", (text or ""):find("Portrait in 5s", 1, true) ~= nil, text)
    check("  and why it is happening", (text or ""):find("gear changed", 1, true) ~= nil, text)

    -- Skip: the whole point of the report.
    check("Skip is a button, not a command", T.PromptClick("Skip"))
    eq("  and it cancels the countdown", T.pendingKind(), nil)
    check("  and takes the prompt down", T.PromptText() == nil)
    WoW.screenshots = 0
    WoW.flushTimers()
    eq("  so no picture is taken", WoW.screenshots, 0)

    -- Now: the "do it while I am standing still" button.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    check("Now is a button too", T.PromptClick("Now"))
    check("  which starts the capture immediately", T.capturing())
    check("  and takes the prompt down", T.PromptText() == nil)
    -- The timer must be dead, or it fires five seconds into this capture.
    eq("  leaving nothing queued behind it", T.pendingKind(), nil)

    -- Never: for somebody who wants it to stop asking.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    AltStableProbeDB.autoCaptureOff = nil
    T.StartCountdown("gear changed")
    check("Never is offered as well", T.PromptClick("Never"))
    check("  and turns auto-capture off", AltStableProbeDB.autoCaptureOff == true)
    eq("  cancelling this one too", T.pendingKind(), nil)
    T.ConsiderCapture("gear changed")
    eq("  so the next look change queues nothing", T.pendingKind(), nil)
    AltStableProbeDB.autoCaptureOff = nil

    -- Letting it run to the end. The timer firing is the one exit that does
    -- not go through CancelPending, so it has to take the prompt down itself -
    -- otherwise it sits there reading "Portrait in 0s" over the capture that
    -- already started, offering a Skip button that skips nothing.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    check("a prompt is up while it counts", T.PromptText() ~= nil)
    WoW.flushTimers()
    check("  the capture went ahead", T.capturing())
    check("  and the prompt came down with it", T.PromptText() == nil,
          tostring(T.PromptText()))
    resetCapture()

    -- The prompt must never end up IN the photograph, and it is NOT under
    -- UIParent - it cannot be, or the showcase would hide the one warning the
    -- player has. So it is covered the way the sheet is: by name, in the
    -- blackout's own list. Two independent guarantees, which is why the list
    -- is a net rather than the mechanism - every path hides it first.
    check("the prompt is not left where the showcase can hide it",
          T.prompt():GetParent() ~= UIParent)
    -- Being un-hidden is not the same as being on screen. The sheet is DIALOG
    -- and the player can drag it anywhere, including over a prompt at a fixed
    -- top-centre position - and IsVisible() reports a frame hidden behind
    -- another as perfectly visible, so nothing else in this file would catch
    -- the warning being covered while the countdown ran out.
    local RANK = {
        BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
        DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
    }
    local strata = T.prompt():GetFrameStrata()
    check("the prompt draws above the sheet, which is DIALOG",
          (RANK[strata] or 0) > RANK.DIALOG,
          ("prompt is %s"):format(tostring(strata)))

    check("  and the blackout knows it by name",
          (function()
              for _, n in ipairs(T.STRAY_FRAMES or {}) do
                  if n == "AltStableRenderPrompt" then return true end
              end
              return false
          end)(),
          "nothing else would keep it out of the picture")

    -- Combat starting cancels the countdown; the prompt must not be left
    -- promising a portrait that is not coming.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    check("a prompt is up", T.PromptText() ~= nil)
    T.CancelPending("combat started")
    check("  and combat takes it down with the countdown", T.PromptText() == nil)
end

------------------------------------------------------------
-- The stubs have to model the thing being fixed
------------------------------------------------------------
-- Asserted directly, because both of these are invisible from the code under
-- test: a stub that does not flip the display id, or does not move a frame
-- between child lists, makes the tests below pass for reasons that have
-- nothing to do with the addon.

do
    -- MEASURED on 1.60.1.70009: 56658 alive and 56658 as a ghost, same
    -- character. Pinned as a fact, not as scaffolding - an earlier stub
    -- returned a separate ghost display, which is what a wrong theory about
    -- this value needed in order to pass.
    WoW.dead = false
    local alive = C_PlayerInfo.GetDisplayID()
    WoW.dead = true
    local ghost = C_PlayerInfo.GetDisplayID()
    WoW.dead = false
    eq("dying does not change the display id", ghost, alive)

    -- GetChildren against GetParent. This codebase reparents frames on purpose
    -- - the showcase lifts the sheet out from under UIParent - so a child list
    -- maintained only at creation would have the lifted frame still answering
    -- UIParent:GetChildren(), and a test walking children would assert the
    -- opposite of the truth.
    local a, b = CreateFrame("Frame"), CreateFrame("Frame")
    local kid = CreateFrame("Frame", nil, a)
    local function childOf(parent)
        for _, c in ipairs({ parent:GetChildren() }) do
            if c == kid then return true end
        end
        return false
    end
    check("a new frame is listed under its parent", childOf(a))
    kid:SetParent(b)
    check("  reparenting moves it to the new parent", childOf(b))
    check("  and takes it off the old one", not childOf(a))
end

------------------------------------------------------------
-- The ghost never reaches the fingerprint at all
------------------------------------------------------------
-- Filtering at the two entry points suppressed the symptom and left the bad
-- value reachable: Finish() stores a fingerprint, /asrender status prints one,
-- and neither asks whether the player is a ghost.

do
    resetCapture()
    local guid = UnitGUID("player")

    WoW.dead = false
    local alive = T.LookFingerprint()
    check("the display id is part of the fingerprint",
          alive:find(tostring(WoW.displayID), 1, true) ~= nil, alive)

    -- Dying changes nothing about the fingerprint, which follows from the
    -- measurement above rather than from any filtering in LookFingerprint -
    -- there is none, and the version that had some was guarding against a
    -- ghost display that does not exist.
    T.RememberFingerprint(guid, T.LookFingerprint())
    local stored = T.StoredFingerprint(guid)
    WoW.dead = true
    eq("dying does not change what the character looks like",
       T.LookFingerprint(), stored)
    WoW.dead = false
    eq("  and neither does coming back", T.LookFingerprint(), stored)

    -- The whole reported symptom, stated once: no trigger either way.
    WoW.dead = true
    T.ConsiderCapture("gear changed since your last portrait")
    eq("dying queues nothing", T.pendingKind(), nil)
    WoW.dead = false
    T.ConsiderCapture("gear changed since your last portrait")
    eq("  and resurrecting queues nothing either", T.pendingKind(), nil)

    -- A REAL change still gets through, or the fix is just "never capture".
    WoW.displayID = 2000               -- a barber visit
    AltStableProbeDB.autoConsent = "yes"
    T.ConsiderCapture("gear changed since your last portrait")
    check("a genuine look change is still noticed", T.pendingKind() == "countdown",
          tostring(T.pendingKind()))
    T.CancelPending()
    WoW.displayID = 1000
end

------------------------------------------------------------
-- Dying part-way through a capture
------------------------------------------------------------
-- A capture takes about three seconds. Both guards run before it starts, so
-- neither sees a death one second in: shot one is the character, shot two is a
-- wisp, and the converter pairs them happily into a cutout that overwrites the
-- good portrait.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.Capture()
    check("a capture is running", T.capturing())

    WoW.dead = true
    T.events:GetScript("OnEvent")(T.events, "PLAYER_DEAD")
    check("dying abandons it", not T.capturing())

    WoW.flushTimers()
    check("  so no complete pair is left on disk", #renders() < 2, tostring(#renders()))

    -- And the fingerprint is NOT recorded, or the next live look would differ
    -- from a ghost's and fire another capture.
    WoW.dead = false
    eq("  and no fingerprint was stored for it",
       T.StoredFingerprint(UnitGUID("player")), nil)
end

------------------------------------------------------------
-- Coming back re-arms the trigger that being dead consumed
------------------------------------------------------------
-- Refusing while dead THROWS AWAY the trigger: the combat-settle timer fires
-- during the corpse run, finds the player dead and returns. Without an
-- event on the way back, a genuine gear change that coincided with a death
-- waits for the next fight or the next login.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    WoW.dead = true
    WoW.displayID = 3000                 -- something really did change
    T.ConsiderCapture("quiet since combat - gear changed since your last portrait")
    eq("while dead the trigger is dropped", T.pendingKind(), nil)

    WoW.dead = false
    T.events:GetScript("OnEvent")(T.events, "PLAYER_UNGHOST")
    check("coming back picks it up again", T.pendingKind() == "countdown",
          tostring(T.pendingKind()))
    T.CancelPending()

    -- PLAYER_ALIVE covers a resurrection that never involved a ghost.
    T.events:GetScript("OnEvent")(T.events, "PLAYER_ALIVE")
    check("  and so does PLAYER_ALIVE", T.pendingKind() == "countdown")
    T.CancelPending()
    WoW.displayID = 1000
end

------------------------------------------------------------
-- Every entry point takes the queued countdown with it
------------------------------------------------------------

do
    -- The sheet's Capture button goes straight to Capture() without touching
    -- the countdown, so pressing it while one was armed ran the whole chain
    -- twice - two captures, two blackouts - and left the prompt on screen
    -- offering Now and Skip over a capture that had already finished.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    check("a countdown is armed", T.pendingKind() == "countdown")

    AltStableProbe.CapturePortrait()      -- the sheet's button
    check("the sheet's button captures", T.capturing())
    eq("  and disarms the countdown it overtook", T.pendingKind(), nil)
    check("  and takes the prompt down with it", T.PromptText() == nil)

    WoW.flushTimers()
    check("  so only one capture ran", #renders() <= 2, tostring(#renders()))
end

------------------------------------------------------------
-- Now does not announce a cancellation
------------------------------------------------------------

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    T.StartCountdown("gear changed")
    WoW.chatOut = {}
    T.PromptClick("Now")
    local said = table.concat(WoW.chatOut, " | ")
    check("pressing Now does not say the capture was cancelled",
          said:find("cancelled", 1, true) == nil, said)
end

------------------------------------------------------------
-- The prompt fits the longest reason there is
------------------------------------------------------------

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    -- The exact string the combat-settle trigger passes, which is the one a
    -- player is most likely to see mid-session - and the one no test used.
    T.StartCountdown("quiet since combat - gear changed since your last portrait")
    local p = T.prompt()
    check("the label has room to wrap above the buttons",
          p.label:GetHeight() + 20 + 16 <= p:GetHeight(),
          ("label %d + buttons in %d"):format(p.label:GetHeight(), p:GetHeight()))
    check("  and it wraps rather than running off the side",
          p.label.GetWordWrap == nil or p.label:GetWordWrap() ~= false)
    T.CancelPending()
end

------------------------------------------------------------
-- Never in a dungeon, never while moving
------------------------------------------------------------

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    WoW.displayID = 7000                    -- something to photograph

    -- A dungeon, and that includes a capture asked for by hand: the stage is a
    -- flat backdrop so the location makes no difference to the picture, but
    -- hiding the whole interface for three seconds does make a difference when
    -- four other people are relying on you.
    WoW.instanceType = "party"
    T.ConsiderCapture("gear changed since your last portrait")
    eq("a dungeon queues nothing", T.pendingKind(), nil)

    WoW.screenshots = 0
    T.Capture()
    check("  and refuses a capture asked for by hand", not T.capturing())
    eq("  taking no picture", WoW.screenshots, 0)
    eq("  and never touching the interface", WoW.uiVisible, true)

    -- Raids, battlegrounds and arenas are the same answer, and the check reads
    -- instanceType rather than a list, so a kind added by a future patch is
    -- covered without an edit.
    for _, kind in ipairs({ "raid", "pvp", "arena", "scenario", "something-new" }) do
        WoW.instanceType = kind
        T.Capture()
        check("  " .. kind .. " too", not T.capturing())
    end

    -- Leaving brings the trigger back. Refusing CONSUMES it otherwise - the
    -- same trap the corpse-run guard fell into - so a gear change made in a
    -- dungeon would wait for the next fight or the next login.
    WoW.instanceType = "none"
    -- The REGISTRATION, not just the handler. Calling the handler with an
    -- event name it never registered for proves nothing - and this test passed
    -- that way first, because the unrecognised name fell through to the
    -- combat-ended branch and armed the settle timer by accident.
    check("the addon listens for the zone change at all",
          T.events:IsEventRegistered("PLAYER_ENTERING_WORLD"),
          "leaving a dungeon would never be noticed in game")
    T.events:GetScript("OnEvent")(T.events, "PLAYER_ENTERING_WORLD")
    -- Zoning is not "a fight ended". Without its own branch the event falls
    -- through to the combat-ended one and arms a THIRTY second quiet-wait, so
    -- the countdown below would appear either way and this block would pass
    -- against a handler that does not know what a zone change is.
    eq("  and handles it as a zone change, not as a fight ending",
       T.pendingKind(), nil)
    WoW.flushTimers()
    check("leaving the dungeon picks the portrait back up",
          T.pendingKind() == "countdown", tostring(T.pendingKind()))
    T.CancelPending()
    WoW.displayID = 56658
end

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"

    -- Moving is refused, but NOT dropped. It is over in a second and has no
    -- event worth waiting on, so the countdown waits rather than throwing the
    -- picture away and hoping something asks again later.
    WoW.speed = 7
    WoW.screenshots = 0
    T.Capture()
    check("a capture asked for while running is refused", not T.capturing())
    eq("  and takes no picture", WoW.screenshots, 0)

    T.StartCountdown("gear changed")
    check("the countdown starts anyway", T.pendingKind() == "countdown")
    WoW.flushTimers()
    eq("  but fires no capture while still moving", WoW.screenshots, 0)
    check("  and does not drop it either", T.pendingKind() ~= nil,
          "the trigger would be gone and nothing would ask again")

    local waiting = T.PromptText()
    check("  the prompt says what it is waiting for",
          (waiting or ""):find("stand still", 1, true) ~= nil, tostring(waiting))

    -- Standing still lets it through.
    WoW.speed = 0
    WoW.flushTimers()
    check("standing still takes the picture", T.capturing())
    check("  and the prompt comes down", T.PromptText() == nil)

    -- Falling counts as moving: a capture that begins as somebody leaves the
    -- ground is worse than one taken mid-stride.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    WoW.speed, WoW.falling = 0, true
    T.Capture()
    check("falling is moving", not T.capturing())
    WoW.falling = false

    -- Something that is NOT moving ending the wait: it has its own event to
    -- bring the trigger back, so outlasting it here would be wrong.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    WoW.speed = 7
    T.StartCountdown("gear changed")
    WoW.flushTimers()
    check("waiting for stillness", T.PromptText() ~= nil)
    WoW.dead = true
    WoW.flushTimers()
    check("dying ends the wait rather than outlasting it", T.PromptText() == nil)
    check("  and takes no picture", not T.capturing())
    WoW.dead, WoW.speed = false, 0
end

------------------------------------------------------------
-- Say WHICH part of the look changed
------------------------------------------------------------
-- The display id was measured and cleared, so the cause of the repeated
-- "gear changed" on a corpse run is one of the nineteen slots. Naming it turns
-- the next occurrence into a measurement instead of another theory.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    local guid = UnitGUID("player")
    T.RememberFingerprint(guid, T.LookFingerprint())

    WoW.displayID = 9001
    WoW.chatOut = {}
    T.ConsiderCapture("gear changed since your last portrait")
    local said = table.concat(WoW.chatOut, " | ")
    check("the change is named, not just announced",
          said:find("look changed", 1, true) ~= nil, said)
    check("  naming the field that moved",
          said:find("display id", 1, true) ~= nil, said)
    check("  with both values", said:find("9001", 1, true) ~= nil, said)
    T.CancelPending()
    WoW.displayID = 56658
end

------------------------------------------------------------
-- The warning has to be VISIBLE, not merely shown
------------------------------------------------------------
-- AltStable's showcase hides UIParent for the whole time the sheet is open.
-- The prompt is parented to UIParent so it stays out of the photograph - which
-- also meant that a countdown firing while the sheet was up left it shown and
-- invisible: the timer ran on, the capture happened, and the visible chance to
-- cancel was not on screen.
--
-- Every assertion in this block uses PromptText, which asks IsVisible. The
-- version that asked IsShown could not see this at all.

do
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"

    -- The sheet is open, so the showcase has taken the interface down.
    UIParent:Hide()
    T.StartCountdown("gear changed")
    check("the countdown still warns when the interface is hidden",
          T.PromptText() ~= nil,
          "shown but invisible is the same as absent, and the capture goes ahead")
    check("  by getting out from under the hidden UIParent",
          T.prompt():GetParent() ~= UIParent, tostring(T.prompt():GetParent()))

    -- And it must not then be standing in the photograph.
    WoW.flushTimers()
    check("the capture went ahead", T.capturing())
    check("  with the prompt gone", T.PromptText() == nil)
    check("  and actually hidden, not merely moved", T.PromptShown() == false)
    check("  and hidden wherever it is parented", T.PromptShown() == false)
    UIParent:Show()
end

do
    -- The other order: the countdown starts in the open, and the player opens
    -- the sheet during those five seconds.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    UIParent:Show()

    T.StartCountdown("gear changed")
    check("a countdown in the open is visible", T.PromptText() ~= nil)
    check("  and kept out from under UIParent from the start",
          T.prompt():GetParent() ~= UIParent,
          "lifting it only once the interface goes down cannot work - the "
          .. "frame that would do the lifting is the one that stops updating")

    UIParent:Hide()                       -- they open the sheet mid-countdown
    -- Nothing is driven here on purpose.
    --
    -- The previous version of this check fetched the prompt's OnUpdate and
    -- called it by hand, which is an update the client would never deliver: a
    -- frame whose parent is hidden receives none. It passed against a prompt
    -- that was invisible for the rest of the countdown while the timer ran on
    -- and took the picture anyway. The prompt is not under UIParent at all
    -- now, so hiding UIParent is simply not its business.
    check("opening the showcase mid-countdown does not hide the warning",
          T.PromptText() ~= nil,
          "the player would get a capture with no visible way to stop it")

    -- Skip still works from there, which is the entire point.
    check("Skip is still reachable", T.PromptClick("Skip"))
    eq("  and cancels", T.pendingKind(), nil)
    check("  and the prompt goes away", T.PromptText() == nil)
    UIParent:Show()
end

do
    -- Waiting for stillness is the long one - up to ninety seconds - so it is
    -- the wait most likely to still be running when somebody opens the sheet.
    resetCapture()
    AltStableProbeDB.autoConsent = "yes"
    UIParent:Show()
    WoW.speed = 7
    T.StartCountdown("gear changed")
    WoW.flushTimers()
    check("the stillness wait is up", T.PromptText() ~= nil)

    UIParent:Hide()                       -- they open the sheet while it waits
    WoW.flushTimers()
    check("opening the showcase does not hide it either",
          T.PromptText() ~= nil,
          "a ninety-second wait is the one most likely to overlap the sheet")

    UIParent:Show()
    WoW.speed = 0
    T.CancelPending()
end

do
    -- The SEAM, asserted directly.
    --
    -- Every on-screen check in this file goes through PromptText. Asking
    -- IsShown instead of IsVisible makes a prompt hidden behind the showcase
    -- indistinguishable from one on screen - which is precisely how the bug
    -- above survived a suite full of prompt assertions. It only differs from
    -- IsShown when something is broken, so it is pinned here rather than
    -- relied upon to fail somewhere else.
    resetCapture()
    UIParent:Show()
    T.StartCountdown("gear changed")
    check("the prompt is on screen", T.PromptText() ~= nil)

    -- Force the exact state the design prevents: shown, under a hidden
    -- UIParent. Reachable only by putting it back there by hand, which is the
    -- point - nothing in the code does.
    T.prompt():SetParent(UIParent)
    UIParent:Hide()
    check("  it is still 'shown'", T.PromptShown())
    check("  but the seam reports nothing, because nobody can see it",
          T.PromptText() == nil,
          "a seam that cannot tell shown from visible hides this class of bug")

    -- Put it back where the code keeps it. This block reaches in and moves the
    -- prompt somewhere nothing in the addon would, so it owns undoing that -
    -- leaving it under UIParent made the next two blocks fail for a reason
    -- that had nothing to do with what they were testing.
    T.prompt():SetParent(WorldFrame)
    UIParent:Show()
    T.CancelPending()
end

do
    -- WorldFrame does not carry the player's UI scale, so without copying it
    -- the prompt is drawn at a different size from every other piece of
    -- interface - the cost of parking it outside UIParent, paid explicitly.
    resetCapture()
    UIParent:Show()

    UIParent:SetScale(0.8)
    T.StartCountdown("gear changed")
    eq("it is drawn at the player's UI scale", T.prompt():GetScale(), 0.8)
    T.CancelPending()

    -- On every show, not once at build: the scale can change while the addon
    -- is loaded, and a prompt stuck at the scale of the first countdown of the
    -- session would be wrong for every one after it.
    UIParent:SetScale(1)
    T.StartCountdown("gear changed")
    eq("  and follows it when it changes", T.prompt():GetScale(), 1)
    T.CancelPending()
end

do
    -- The safety net, independent of every path above: if the prompt is
    -- somehow still up when the blackout runs, it is covered like any other
    -- frame that escaped UIParent, rather than printed into the portrait.
    resetCapture()
    T.ShowUI()
    UIParent:Show()
    T.StartCountdown("gear changed")
    UIParent:Hide()
    check("the prompt is visible with the interface down", T.PromptText() ~= nil)

    UIParent:Show()
    T.ShowUI()
    T.prompt():Show()                     -- pretend a path forgot to hide it
    T.HideUI()
    eq("a prompt that escaped is blacked out with everything else",
       T.prompt():GetAlpha(), 0)
    T.ShowUI()
    T.CancelPending()
end

------------------------------------------------------------
-- Never borrow an alpha somebody else is still animating
------------------------------------------------------------
-- The blackout hides the lifted sheet by saving its alpha and zeroing it, then
-- writes the saved value back afterwards. The sheet's opening fade owns that
-- same alpha for 0.22 seconds, climbing from 0 to 1 under its own timer - so a
-- capture starting inside the fade saved 0, the fade finished at 1 regardless,
-- and the restore put the 0 back. A sheet shown and completely invisible.
--
-- Two owners of one property need an order. The probe settles the fade before
-- it reads, which is AltStable's job to provide and the probe's to ask for.

do
    resetCapture()
    T.ShowUI()
    UIParent:Show()

    local sheet = CreateFrame("Frame", "AltStableSheet", UIParent)
    sheet:SetParent(nil)                  -- as the showcase leaves it
    sheet:Show()

    -- A fade in progress: alpha is mid-climb and something else will carry it
    -- to 1 whatever the capture does.
    sheet:SetAlpha(0)
    local finished = false
    AltStable = AltStable or {}
    local realFinish = AltStable.FinishOpenAnimation
    AltStable.FinishOpenAnimation = function()
        finished = true
        sheet:SetAlpha(1)                 -- what finishing the fade does
        return true
    end

    T.HideUI()
    check("the capture asks for the fade to be settled first", finished,
          "otherwise it saves a number the fade is about to overwrite")
    eq("  and the sheet is blacked out for the shot", sheet:GetAlpha(), 0)

    T.ShowUI()
    eq("  and comes back at the alpha the fade settled on, not the one mid-fade",
       sheet:GetAlpha(), 1)

    -- A configured alpha is still preserved: settling the fade must not become
    -- "restore everything to 1".
    AltStable.FinishOpenAnimation = function() return false end   -- nothing running
    sheet:SetAlpha(0.6)
    T.HideUI()
    eq("a sheet with no fade running is blacked out too", sheet:GetAlpha(), 0)
    T.ShowUI()
    eq("  and keeps the alpha its owner chose", sheet:GetAlpha(), 0.6)

    -- The probe must not require AltStable to be loaded at all: it is a
    -- separate addon and can run without it.
    AltStable.FinishOpenAnimation = nil
    sheet:SetAlpha(1)
    local ok = pcall(function() T.HideUI() end)
    check("no AltStable, no problem", ok)
    T.ShowUI()
    eq("  and the alpha still round-trips", sheet:GetAlpha(), 1)

    AltStable.FinishOpenAnimation = realFinish
    sheet:Hide()
end

print(("test_render: %d passed, %d failed"):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
