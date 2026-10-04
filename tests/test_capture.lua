------------------------------------------------------------
-- test_capture.lua — the shipped portrait capture (Capture.lua, #89)
--
-- Ported from test_render.lua, which pinned the same code while it lived in the
-- development probe. What is pinned is mostly ABANDONMENT, not the happy path:
-- a capture hides the player's entire interface for three seconds and writes
-- records a separate offline tool later consumes, so every way of giving up
-- half-way has to leave the interface back, the stage gone, the screenshot
-- format restored, and no usable record of a picture nobody wants.
--
-- The happy path is pinned too now, because its records are a CONTRACT
-- (docs/PORTRAIT-CONTRACT.md): the converter parses exactly these fields.
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
AltStablePortraits = nil
dofile("Compat.lua")
assert(loadfile("Core.lua"))()

WoW.timers = {}
dofile("Capture.lua")

local T = AltStable._test and AltStable._test.portrait
check("the capture exposes a test seam", T ~= nil)
if not T then
    print(("test_capture: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end

------------------------------------------------------------
-- Combat on a fresh login, before anything has been built
------------------------------------------------------------
-- FIRST, deliberately: the stage is built lazily by the first capture or
-- preview, so this is the only point in the file where it genuinely does not
-- exist yet. Every check below constructs it.

WoW.inCombat = true
local okFresh, freshErr = pcall(function()
    T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_DISABLED")
end)
check("combat before the stage exists does not error", okFresh, tostring(freshErr))
check("  and nothing was capturing to abandon", not T.capturing())
WoW.inCombat = false
eq("an install that never captured writes no store at all", AltStablePortraits, nil)

-- The reload prompt lives in SheetUI (a secure button; pinned in test_sheetui).
-- Here it is a spy: the question is only WHETHER the capture offers it.
prompts = {}
AltStable.ShowReloadPrompt = function(msg) prompts[#prompts + 1] = msg; return true end

local function renders() return (AltStablePortraits and AltStablePortraits.renders) or {} end
local function resetCapture()
    -- Module state too: a block that leaves a capture RUNNING makes the next
    -- Capture() a silent no-op, so the block after it tests nothing.
    T.AbandonCapture(nil, true)
    WoW.dead = false
    WoW.instanceType, WoW.speed, WoW.falling = "none", 0, false
    AltStablePortraits = nil
    WoW.inCombat, WoW.uiVisible, WoW.screenshots = false, true, 0
    UIParent:Show()
    WoW.timers = {}
    WoW.chatOut = {}
    WoW.popups = {}
    WoW.reloaded = 0
    prompts = {}
    WoW.sounds = {}
    -- The client always has a format set; JPEG is its default. An empty
    -- stub CVar would make "put the player's format back" untestable.
    WoW.cvars = { screenshotFormat = "jpeg" }
end

-- Walk the timer chain on a virtual clock, IN TIME ORDER, and record when each
-- shutter fires.
--
-- NOT WoW.flushTimers(): that runs whatever is queued in insertion order with
-- no regard for the delay, and does not run what those callbacks queue. The
-- first thing a capture queues is its 12-second watchdog, so a flush fires the
-- watchdog first and abandons the capture before a single shot - a test of the
-- happy path through flushTimers passes against a capture that never happens.
--
-- `stopAfter` lets a test step in between links: it is called after each
-- callback with the clock, and returning true stops the walk there.
local function runChain(stopAfter)
    local clock, shots = 0, {}
    for _ = 1, 40 do
        local nextTimer, at
        for _, t in ipairs(WoW.timers) do
            local due = (t.due or (clock + t.delay))
            t.due = due
            if not at or due < at then nextTimer, at = t, due end
        end
        if not nextTimer then break end
        for i, t in ipairs(WoW.timers) do
            if t == nextTimer then table.remove(WoW.timers, i); break end
        end
        WoW.now = WoW.now + (at - clock)
        clock = at
        local before = WoW.screenshots
        nextTimer.fn()
        if WoW.screenshots > before then shots[#shots + 1] = clock end
        if stopAfter and stopAfter(clock, shots) then break end
    end
    return shots
end

------------------------------------------------------------
-- Never in combat, from any entry point
------------------------------------------------------------

resetCapture()
WoW.inCombat = true
T.Capture()
check("a capture is refused in combat", not T.capturing())
eq("  and nothing was photographed", WoW.screenshots, 0)
eq("  and the interface was never touched", WoW.uiVisible, true)
eq("  and no record was written", #renders(), 0)

------------------------------------------------------------
-- The whole capture, start to finish
------------------------------------------------------------
-- The records are what a converter reads to know WHOSE screenshots these are,
-- so their shape is pinned field by field.

resetCapture()
T.Capture()
check("out of combat, the capture starts", T.capturing())
eq("  and the interface goes away", WoW.uiVisible, false)
eq("  and screenshots are switched to TGA", WoW.cvars.screenshotFormat, "tga")

local shots = runChain()
eq("a capture takes exactly two shots", #shots, 2)
eq("  each with a shutter sound", #WoW.sounds, 2)
eq("  the camera one", WoW.sounds[1], SOUNDKIT.REPORT_SCREENSHOT_CAMERA)
check("  and finishes", not T.capturing())
eq("  giving the interface back", WoW.uiVisible, true)
eq("  and taking the stage down", T.stage():IsShown(), false)

eq("the store says which contract it follows", AltStablePortraits and AltStablePortraits.version,
   T.STORE_VERSION)
eq("  version 1", T.STORE_VERSION, 1)
eq("one record per shot", #renders(), 2)
local r1, r2 = renders()[1] or {}, renders()[2] or {}
eq("  shot 1 is the black one", r1.shot, 1)
eq("  shot 2 the white one", r2.shot, 2)
eq("  the whole name, surname included", r1.name, "Example Surname")
eq("  the GUID, which is the identity", r1.guid, WoW.player.guid)
eq("  race token", r1.race, WoW.player.race)
eq("  localised race", r1.raceLoc, "Undead")
eq("  class token", r1.class, WoW.player.class)
eq("  sex", r1.sex, 3)
eq("  level", r1.level, WoW.level)
check("  a local-time stamp in the filename's format",
      type(r1.stamp) == "string" and r1.stamp:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil,
      tostring(r1.stamp))
eq("  and an epoch to order by", type(r1.epoch), "number")
check("  which moves on between the two shots",
      r2.epoch and r1.epoch and r2.epoch > r1.epoch,
      ("%s -> %s"):format(tostring(r1.epoch), tostring(r2.epoch)))
check("  as the stamps do, a second apart at least", r1.stamp ~= r2.stamp,
      tostring(r1.stamp) .. " / " .. tostring(r2.stamp))
-- PHYSICAL pixels, which is what a screenshot measures. The stub keeps
-- GetScreenWidth at half, so a record from the wrong source is caught.
eq("  screen width in physical pixels", r1.screenW, WoW.screenW)
eq("  screen height in physical pixels", r1.screenH, WoW.screenH)
eq("  the UI scale", type(r1.uiScale), "number")

-- The flush gap: SavedVariables reach disk on reload or logout only.
eq("the capture offers a reload", #prompts, 1)
check("  saying why, naming the app (#176)", tostring(prompts[1]):find("AltStable Companion", 1, true) ~= nil, tostring(prompts[1]))
local told = false
for _, line in ipairs(WoW.chatOut) do
    if tostring(line):find("reload", 1, true) then told = true end
end
check("  and says so in chat too", told)
eq("  and reloads nothing by itself - the click does that", WoW.reloaded, 0)
eq("the screenshot format is put back", WoW.cvars.screenshotFormat, "jpeg")

------------------------------------------------------------
-- TGA or nothing
------------------------------------------------------------
-- JPEG makes the matte read compression noise as coverage, and the converter
-- cannot tell that from a real portrait. The probe warned and carried on; a
-- capture that cannot switch the format now does not happen.

do
    resetCapture()
    local realSet = SetCVar
    SetCVar = function(name, value)
        if name == "screenshotFormat" and value == "tga" then return false end
        return realSet(name, value)
    end
    T.Capture()
    check("a client that refuses TGA gets no capture", not T.capturing())
    eq("  no picture", WoW.screenshots, 0)
    eq("  no record", #renders(), 0)
    eq("  the interface untouched", WoW.uiVisible, true)
    eq("  and the player's format left as it was", WoW.cvars.screenshotFormat, "jpeg")
    SetCVar = realSet
end

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

local shotsBefore = WoW.screenshots
runChain()
eq("  and the abandoned chain takes no pictures", WoW.screenshots, shotsBefore)
eq("  and makes no shutter sound", #WoW.sounds, 0)
eq("  and writes no records", #renders(), 0)
eq("  and offers no reload", #prompts, 0)
WoW.inCombat = false

------------------------------------------------------------
-- The player takes their interface back
------------------------------------------------------------
-- Alt+Z and Escape both call SetUIVisibility(true). Only setting a flag let the
-- chain run on and photograph the restored interface - and the converter pairs
-- from the records, so the ruined pair stayed eligible.

resetCapture()
T.Capture()
local tokenBefore = T.token()
eq("the interface is hidden while shooting", WoW.uiVisible, false)

SetUIVisibility(true)          -- the player presses Alt+Z

check("restoring the interface abandons the capture", not T.capturing())
check("  and voids every pending callback", T.token() ~= tokenBefore)
eq("  and dismisses the stage immediately", T.stage():IsShown(), false)
eq("  and leaves the interface the player asked for", WoW.uiVisible, true)

local shotsNow = WoW.screenshots
runChain()
eq("  the abandoned chain takes no further pictures", WoW.screenshots, shotsNow)
eq("  and leaves NO record for the converter to find", #renders(), 0)

------------------------------------------------------------
-- Records already written are taken back - driven through the real chain
------------------------------------------------------------
-- A lone shot-1 record is harmless, because a converter only pairs a 1 with a
-- 2; a chain that is abandoned after BOTH shots leaves a complete pair from a
-- capture nobody trusts. An earlier, good capture must survive either way.

local function seedGoodPair()
    AltStablePortraits = { version = 1, renders = {
        { name = "Old Alt", guid = "g0", shot = 1 },
        { name = "Old Alt", guid = "g0", shot = 2 },
    } }
end

for _, case in ipairs({
    { label = "after shot 1", shots = 1 },
    { label = "after shot 2, before it finishes", shots = 2 },
}) do
    resetCapture()
    seedGoodPair()
    T.Capture()
    eq("[" .. case.label .. "] the mark is taken at the start", T.renderMark(), 2)
    runChain(function(_, taken) return #taken >= case.shots end)
    eq("[" .. case.label .. "] this capture has written its records", #renders(), 2 + case.shots)

    T.events:GetScript("OnEvent")(T.events, "PLAYER_DEAD")   -- any way of giving up
    runChain()                                               -- the rest of the chain
    eq("[" .. case.label .. "] abandoning takes back what it wrote", #renders(), 2)
    eq("  and keeps the earlier capture intact", renders()[1] and renders()[1].name, "Old Alt")
    eq("  including its second shot", renders()[2] and renders()[2].shot, 2)
    eq("  and offers no reload for a capture that was thrown away", #prompts, 0)
end

------------------------------------------------------------
-- Abandoning twice is harmless
------------------------------------------------------------
-- Combat and Alt+Z can land in either order, and the watchdog fires regardless.

resetCapture()
T.Capture()
table.insert(AltStablePortraits.renders, { name = "Half", guid = "g2", shot = 1 })
T.AbandonCapture(nil, true)
local after = T.token()
table.insert(AltStablePortraits.renders, { name = "Later", guid = "g3", shot = 1 })
T.AbandonCapture(nil, true)
eq("a second abandon changes nothing", T.token(), after)
check("  and does not eat a record it never wrote",
      #renders() == 1 and renders()[1].name == "Later",
      ("%d record(s)"):format(#renders()))

------------------------------------------------------------
-- The watchdog
------------------------------------------------------------
-- A chain that stops half way - a callback that errors, a timer the client
-- drops - would leave the interface hidden for good. The watchdog is what
-- brings it back, and it has to outlast a capture that goes RIGHT.

do
    resetCapture()
    T.Capture()
    -- Drop every link of the chain except the watchdog, as a hung chain would.
    local wd
    for _, t in ipairs(WoW.timers) do
        if t.delay == T.WATCHDOG then wd = t end
    end
    check("a capture arms a watchdog", wd ~= nil)
    WoW.timers = { wd }
    runChain()
    check("  which abandons a chain that hung", not T.capturing())
    eq("  and gives the interface back", WoW.uiVisible, true)
end

------------------------------------------------------------
-- The stage always goes, even if nothing is in flight
------------------------------------------------------------

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
-- first. At the original 0.9s gap that happened whenever the clock ticked
-- unkindly: Morphisto Ruskador recorded both shots at 02:14:44.

local shutterGap = T.SHOT_DELAY + T.SWAP_DELAY
check("the gap between shutters exceeds one second", shutterGap > 1.0,
      ("%.2fs - two shots can share a filename"):format(shutterGap))
check("  and is not so long the pose can drift", shutterGap < 2.5,
      ("%.2fs"):format(shutterGap))
local worst = 0.999 + shutterGap
check("  so the second shot always lands in a later second",
      math.floor(worst) > math.floor(0.999),
      ("%.3f"):format(worst))

-- The constants agreeing proves nothing if the chain schedules something else.
resetCapture()
T.Capture()
local times = runChain()
check("the first shot waits for the model to stream in",
      times[1] and times[1] >= T.KEY_DELAY - 0.001, tostring(times[1]))
check("the SCHEDULED gap between shutters exceeds one second",
      times[2] and times[1] and (times[2] - times[1]) > 1.0,
      times[2] and ("%.2fs as scheduled"):format(times[2] - times[1]) or "no second shot")
check("  and matches the constants it is built from",
      times[2] and math.abs((times[2] - times[1]) - shutterGap) < 0.001,
      times[2] and ("%.3f vs %.3f"):format(times[2] - times[1], shutterGap) or "-")
check("the watchdog outlasts the whole sequence", T.WATCHDOG > (times[2] or 0) + T.SHOT_DELAY,
      ("%.1f vs %.2f"):format(T.WATCHDOG, times[2] or 0))

------------------------------------------------------------
-- The sheet's camera showcase is not told anything
------------------------------------------------------------
-- It used to be, through a `capturing` flag that made the showcase ignore
-- every hide of the sheet for the whole capture - including a real close, which
-- left the camera showcase running with no window (#89 review). The sheet now
-- tells its parent's hide from a close by itself; that is pinned in
-- test_sheetui against the REAL showcase, which this file does not load.

------------------------------------------------------------
-- The blackout has to cover what somebody lifted out of UIParent
------------------------------------------------------------
-- The showcase reparents the sheet and GameTooltip out from under UIParent so
-- hiding the game UI does not take them with it. Every portrait taken with the
-- sheet's capture button was once a picture of the sheet, tooltip included.

do
    local sheet = CreateFrame("Frame", "AltStableSheet", UIParent)
    check("a named frame is reachable by that name", _G["AltStableSheet"] == sheet)
    sheet:SetParent(nil)
    sheet:Show()
    sheet:SetAlpha(1)

    GameTooltip:SetParent(nil)
    GameTooltip:Show()
    GameTooltip:SetAlpha(1)

    resetCapture()
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

    -- The alpha that was THERE, not a hardcoded 1.
    sheet:SetAlpha(0.6)
    T.HideUI()
    eq("a translucent sheet still goes fully invisible", sheet:GetAlpha(), 0)
    T.ShowUI()
    eq("  and comes back at the alpha it had", sheet:GetAlpha(), 0.6)
    sheet:SetAlpha(1)

    T.HideUI()
    T.ShowUI()
    T.ShowUI()                       -- again, as an abandoned capture would
    eq("a second restore is harmless", sheet:GetAlpha(), 1)

    -- A sheet still under UIParent is already covered, and left alone.
    sheet:SetParent(UIParent)
    T.HideUI()
    check("a sheet still under UIParent is not collected", (function()
        for _, e in ipairs(T.strays() or {}) do
            if e.frame == sheet then return false end
        end
        return true
    end)())
    eq("  and its alpha is left alone", sheet:GetAlpha(), 1)
    T.ShowUI()
    sheet:SetParent(nil)

    -- Alt+Z mid-capture, through a REAL capture: the hook clears uiHidden on
    -- the spot, so a restore keyed off uiHidden would leave the sheet at 0.
    resetCapture()
    T.Capture()
    check("a capture is running", T.capturing())
    eq("  and the sheet went invisible with the interface", sheet:GetAlpha(), 0)
    SetUIVisibility(true)
    check("  which Alt+Z abandons", not T.capturing())
    eq("Alt+Z mid-capture still gives the sheet back", sheet:GetAlpha(), 1)

    -- The fallback blackout, on a client with no SetUIVisibility.
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

    -- The tooltip, HIDDEN when the capture starts - which is how the capture
    -- leaves it - and then shown by the cursor resting on the invisible sheet.
    -- It draws above the stage, so it must be neither visible nor opaque.
    resetCapture()
    GameTooltip:SetAlpha(1)
    GameTooltip:Show()
    T.Capture()
    eq("the lifted tooltip is dimmed even though the capture hid it first",
       GameTooltip:GetAlpha(), 0)
    GameTooltip:Show()                     -- a row hovered mid-capture
    check("  and a tooltip raised mid-capture is taken straight down",
          not GameTooltip:IsShown())
    runChain()
    eq("  and its alpha is given back afterwards", GameTooltip:GetAlpha(), 1)
    GameTooltip:Show()
    check("  after which it shows normally", GameTooltip:IsShown())

    -- A CLOSED sheet is not collected.
    sheet:Hide()
    T.HideUI()
    check("a closed sheet is not collected", (function()
        for _, e in ipairs(T.strays() or {}) do
            if e.frame == sheet then return false end
        end
        return true
    end)())
    T.ShowUI()

    GameTooltip:SetParent(UIParent)
end

------------------------------------------------------------
-- The interface stays off if that is how we found it
------------------------------------------------------------
-- With the sheet open, the showcase has already hidden the game UI; so has a
-- player who pressed Alt+Z first. Neither wants a capture to bring it back.

do
    resetCapture()
    SetUIVisibility(false)
    T.Capture()
    check("a capture starts with the interface already hidden", T.capturing())
    runChain()
    eq("  and leaves it hidden afterwards", WoW.uiVisible, false)
    SetUIVisibility(true)
end

------------------------------------------------------------
-- Never borrow an alpha somebody else is still animating
------------------------------------------------------------
-- The sheet's opening fade owns its alpha for 0.22 seconds. A capture starting
-- inside the fade saved the mid-fade value and wrote it back afterwards over a
-- sheet the fade had finished - shown, and completely invisible.

do
    resetCapture()
    local sheet = _G["AltStableSheet"]
    sheet:SetParent(nil)
    sheet:Show()
    sheet:SetAlpha(0)
    local finished = false
    local realFinish = AltStable.FinishOpenAnimation
    AltStable.FinishOpenAnimation = function()
        finished = true
        sheet:SetAlpha(1)
        return true
    end

    T.HideUI()
    check("the capture asks for the fade to be settled first", finished)
    eq("  and the sheet is blacked out for the shot", sheet:GetAlpha(), 0)
    T.ShowUI()
    eq("  and comes back at the alpha the fade settled on", sheet:GetAlpha(), 1)

    AltStable.FinishOpenAnimation = nil
    sheet:SetAlpha(1)
    check("without the function it still works", pcall(function() T.HideUI() end))
    T.ShowUI()
    eq("  and the alpha round-trips", sheet:GetAlpha(), 1)

    AltStable.FinishOpenAnimation = realFinish
    sheet:Hide()
end

------------------------------------------------------------
-- Dead, in a dungeon, or moving: refused from every entry point
------------------------------------------------------------

do
    resetCapture()
    WoW.dead = true
    T.Capture()
    check("a capture is refused while dead", not T.capturing())
    eq("  and nothing was photographed", WoW.screenshots, 0)
    check("  and the reason is available to ask for", AltStable.PortraitBlockedReason() ~= nil)
    WoW.dead = false
    eq("alive and standing still, nothing blocks it", AltStable.PortraitBlockedReason(), nil)

    for _, kind in ipairs({ "party", "raid", "pvp", "arena", "scenario", "something-new" }) do
        WoW.instanceType = kind
        T.Capture()
        check("refused inside a " .. kind, not T.capturing())
    end
    WoW.instanceType = "none"

    WoW.speed = 7
    T.Capture()
    check("refused while running", not T.capturing())
    WoW.speed, WoW.falling = 0, true
    T.Capture()
    check("  and while falling", not T.capturing())
    WoW.falling = false
    eq("none of them took a picture", WoW.screenshots, 0)
end

------------------------------------------------------------
-- /alts portrait, through Core's dispatcher
------------------------------------------------------------
-- The dispatcher splits "<cmd> <target>" with ParseSlashArgs, so the
-- subcommand arrives as `target` - "facing 25" is one argument, not two.

do
    resetCapture()
    SlashCmdList["ALTSTABLE"]("portrait")
    check("/alts portrait starts a capture", T.capturing())
    SlashCmdList["ALTSTABLE"]("portrait cancel")
    check("/alts portrait cancel abandons it", not T.capturing())
    eq("  giving the interface back", WoW.uiVisible, true)

    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("portrait cancel")
    check("cancel with nothing running says so",
          tostring(WoW.chatOut[#WoW.chatOut]):find("nothing to cancel", 1, true) ~= nil,
          tostring(WoW.chatOut[#WoW.chatOut]))

    SlashCmdList["ALTSTABLE"]("portrait facing 25")
    eq("/alts portrait facing 25 turns the character", AltStablePortraits.facing, 25)
    eq("  and makes a store that says its version", AltStablePortraits.version, 1)
    SlashCmdList["ALTSTABLE"]("portrait FACING -10")
    eq("  any case, either way round", AltStablePortraits.facing, -10)

    SlashCmdList["ALTSTABLE"]("portrait preview")
    check("/alts portrait preview shows the stage", T.stage():IsShown())
    check("  without capturing", not T.capturing())
    eq("  or touching the interface", WoW.uiVisible, true)
    T.AbandonCapture(nil, false)

    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("portrait nonsense")
    check("anything else prints the usage",
          tostring(WoW.chatOut[#WoW.chatOut]):find("usage", 1, true) ~= nil,
          tostring(WoW.chatOut[#WoW.chatOut]))

    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("update-reference")
    eq("the retired update-reference takes no picture", WoW.screenshots, 0)
    check("  and does not start a capture", not T.capturing())

    resetCapture()
    eq("AltStable.CapturePortrait answers for the capture", AltStable.CapturePortrait(), true)
    check("  and starts it", T.capturing())
    T.AbandonCapture(nil, true)
end

------------------------------------------------------------
-- Review round on #125
------------------------------------------------------------

-- A reload or logout inside the three seconds: screenshotFormat is a SAVED
-- CVar, and the timer chain that puts it back dies with the Lua state.
do
    resetCapture()
    T.Capture()
    eq("mid-capture, screenshots are TGA", WoW.cvars.screenshotFormat, "tga")
    T.events:GetScript("OnEvent")(T.events, "PLAYER_LOGOUT")
    eq("a reload or logout puts the player's format back", WoW.cvars.screenshotFormat, "jpeg")
    check("  the capture listens for it at all", T.events:IsEventRegistered("PLAYER_LOGOUT"))
    T.AbandonCapture(nil, true)
end

-- No preview over a capture: re-posing unfreezes the model and repaints the
-- backdrop between the two shots, and the pair would still be recorded.
do
    resetCapture()
    T.Capture()
    T.Preview()
    check("a preview asked for mid-capture is refused", not T.previewing())
    local times = runChain()
    eq("  and the capture still takes its two shots", #times, 2)

    WoW.inCombat = true
    T.Preview()
    check("no preview in combat", not T.previewing())
    WoW.inCombat = false
end

-- A preview closed by combat stays closed: `facing` used to bring it back.
do
    resetCapture()
    T.Preview()
    check("a preview is up", T.previewing() and T.stage():IsShown())
    T.events:GetScript("OnEvent")(T.events, "PLAYER_REGEN_DISABLED")
    check("  combat takes it down", not T.stage():IsShown())
    check("  and ends it", not T.previewing())
    SlashCmdList["ALTSTABLE"]("portrait facing 30")
    check("  so turning the character does not bring it back", not T.stage():IsShown())
    check("  nor leaves the stage taking the mouse", not T.stage():IsMouseEnabled())
end

-- Unit numbers can be secret on this client, and a comparison on one throws.
do
    resetCapture()
    local realSpeed, realSex, realLevel = GetUnitSpeed, UnitSex, UnitLevel
    GetUnitSpeed = function() return WoW.secret(7) end
    UnitSex = function() return WoW.secret(3) end
    UnitLevel = function() return WoW.secret(60) end
    local ok, err = pcall(T.Capture)
    check("a secret speed does not break the capture", ok, tostring(err))
    check("  and unknown speed is not treated as moving", T.capturing())
    runChain()
    local r = renders()[1] or {}
    eq("a secret sex is stored as unknown, not as a secret", r.sex, nil)
    eq("  and so is a secret level", r.level, nil)
    GetUnitSpeed, UnitSex, UnitLevel = realSpeed, realSex, realLevel
end

-- A store written by a NEWER AltStable is neither relabelled nor added to.
do
    resetCapture()
    AltStablePortraits = { version = 2, renders = { { shot = 1, future = true } } }
    T.Capture()
    check("a capture into a newer store is refused", not T.capturing())
    eq("  the store keeps its version", AltStablePortraits.version, 2)
    eq("  and its records", #AltStablePortraits.renders, 1)
    SlashCmdList["ALTSTABLE"]("portrait facing 10")
    eq("  and setting the facing does not relabel it either", AltStablePortraits.version, 2)
end

-- The retired command says where it went instead of opening the sheet.
do
    resetCapture()
    local opened = 0
    local realOpen = AltStable.EnsureSheetVisible
    AltStable.EnsureSheetVisible = function() opened = opened + 1 end
    SlashCmdList["ALTSTABLE"]("update-reference")
    AltStable.EnsureSheetVisible = realOpen
    check("/alts update-reference names its replacement",
          tostring(WoW.chatOut[#WoW.chatOut]):find("/alts portrait", 1, true) ~= nil,
          tostring(WoW.chatOut[#WoW.chatOut]))
    eq("  and does not fall through to opening the sheet", opened, 0)
end

------------------------------------------------------------
-- The stubs have to model the thing being fixed
------------------------------------------------------------

do
    -- MEASURED on 1.60.1.70009: 56658 alive and 56658 as a ghost.
    WoW.dead = false
    local alive = C_PlayerInfo.GetDisplayID()
    WoW.dead = true
    local ghost = C_PlayerInfo.GetDisplayID()
    WoW.dead = false
    eq("dying does not change the display id", ghost, alive)

    -- Screen size: physical and UI units are different numbers on purpose.
    local pw = GetPhysicalScreenSize()
    check("physical and UI screen widths differ in the stubs", pw ~= GetScreenWidth())
end

------------------------------------------------------------
-- Is a new capture due? (#128)
------------------------------------------------------------

local GUID = WoW.player.guid
local function wear(slots)
    WoW.equipped = {}
    for slot, id in pairs(slots) do WoW.equipped[slot] = "|Hitem:" .. id .. "::|h[x]|h" end
end
local function pair(look, guid)
    AltStablePortraits = { version = 1, renders = {
        { guid = guid or GUID, shot = 1, epoch = 100, look = look },
        { guid = guid or GUID, shot = 2, epoch = 101, look = look },
    } }
end

resetCapture()
AltStableCutoutManifest = nil
T.ResetStatus()
wear({ [5] = 100, [7] = 200, [2] = 300 })
local look = T.CurrentLook()
check("the look covers the shown slots", look and look:find("5:100", 1, true) and look:find("7:200", 1, true), look)
check("  and not the neck (invisible in a portrait)", look and not look:find("2:300", 1, true), look)
check("  an empty slot reads as 0", look and look:find("1:0", 1, true), look)
check("  and never a comma - the converter's reader stops at one", look and not look:find(",", 1, true))
wear({ [5] = 100, [7] = 200, [2] = 999, [11] = 5, [18] = 77 })
eq("a new ring, neck or ranged-slot relic does not change the look", T.CurrentLook(), look)
wear({})
eq("nothing readable at all (inventory not loaded yet) is 'cannot tell', not 'naked'", T.CurrentLook(), nil)
wear({ [1] = 10, [5] = 100 })
local realShowingHelm = ShowingHelm
ShowingHelm = function() return false end
check("a hidden helm is marked hidden, not its item", (T.CurrentLook() or ""):find("1:h", 1, true), T.CurrentLook())
ShowingHelm = realShowingHelm
local realInv = GetInventoryItemID
GetInventoryItemID = function() error("boom") end
eq("a failing inventory read is 'cannot tell', never an error", T.CurrentLook(), nil)
GetInventoryItemID = realInv
wear({ [5] = 100, [7] = 200, [2] = 300 })

local st = T.PortraitStatus()
eq("no portrait and no capture: missing", st.reason, "missing")
eq("  which is due", st.due, true)

pair(look)
st = T.PortraitStatus()
eq("captured, not converted: pending", st.reason, "pending")
eq("  which is NOT due - it is done, and waits for the converter", st.due, false)

AltStableCutoutManifest = { [GUID] = { file = "x.tga", w = 1, h = 1, texw = 1, texh = 1 } }
st = T.PortraitStatus()
eq("a portrait and the same gear: nothing to do", st.reason, "none")
eq("  not due", st.due, false)

wear({ [5] = 101, [7] = 200 })
st = T.PortraitStatus()
eq("the chest changed since the capture: changed", st.reason, "changed")
eq("  due", st.due, true)
eq("  naming the slot", table.concat(st.changedSlots, ","), "Chest")

-- A capture from before looks were recorded never reads as changed.
pair(nil)
st = T.PortraitStatus()
eq("a capture with no look is never 'changed'", st.reason, "none")

-- "Changed" is a SLOT that differs, not two strings: a look stored by another
-- version of this code (a different slot list) is not a change in itself.
pair("1:0;3:0;4:0;5:101;6:0;7:200;8:0;9:0;10:0;15:0;16:0;17:0;18:555;19:0")
eq("a stored look with an extra slot, same gear, is not 'changed'", T.PortraitStatus().reason, "none")

-- Showing or hiding the helm is a change the portrait would show.
wear({ [1] = 10, [5] = 101, [7] = 200 })
pair(T.CurrentLook())
ShowingHelm = function() return false end
st = T.PortraitStatus()
eq("hiding the helm since the capture: changed", st.reason, "changed")
eq("  on the Head", table.concat(st.changedSlots, ","), "Head")
wear({ [1] = 11, [5] = 101, [7] = 200 })
pair(T.CurrentLook())
wear({ [1] = 12, [5] = 101, [7] = 200 })
eq("swapping a helm that stays hidden is not a change", T.PortraitStatus().reason, "none")
ShowingHelm = realShowingHelm

-- Inventory not readable yet: no verdict about the look.
wear({})
eq("with the look unreadable, an existing capture is not 'changed'", T.PortraitStatus().reason, "none")
wear({ [5] = 101, [7] = 200 })

-- A capture taken THIS session cannot be in the manifest loaded at startup,
-- whatever older portrait the character has.
T.SetSessionStart(50)
AltStablePortraits = { version = 1, renders = {
    { guid = GUID, shot = 1, epoch = 100, look = T.CurrentLook() },
    { guid = GUID, shot = 2, epoch = 101, look = T.CurrentLook() } } }
eq("a fresh capture with an older portrait on file is pending", T.PortraitStatus().reason, "pending")

-- Across the reload the capture asks for (Codex review of #134): the capture
-- is no longer "this session", and the old portrait is still in the manifest.
-- The entry says which capture it was made from, so it stays pending...
T.SetSessionStart(200)
AltStableCutoutManifest = { [GUID] = { file = "x.tga", w = 1, h = 1, texw = 1, texh = 1, epoch = 40 } }
eq("after a reload, a replacement not yet converted is still pending", T.PortraitStatus().reason, "pending")
-- ...until the converter's entry names this capture (its first shot).
AltStableCutoutManifest[GUID].epoch = 100
eq("once converted from this capture, nothing is pending", T.PortraitStatus().reason, "none")
AltStableCutoutManifest[GUID].epoch = 101
eq("  also when a converter recorded the second shot's epoch", T.PortraitStatus().reason, "none")
-- An entry from before `epoch` can only be judged by the session, as before.
AltStableCutoutManifest[GUID].epoch = nil
eq("an entry without an epoch, after a reload: the old reading (none)", T.PortraitStatus().reason, "none")
T.SetSessionStart(50)
eq("  and within the session: pending", T.PortraitStatus().reason, "pending")
AltStableCutoutManifest = { [GUID] = { file = "x.tga", w = 1, h = 1, texw = 1, texh = 1 } }
T.SetSessionStart(1700000000)

-- An abandoned half says nothing: only a complete pair counts.
AltStableCutoutManifest = nil
AltStablePortraits = { version = 1, renders = { { guid = GUID, shot = 1, epoch = 5, look = "x" } } }
eq("a lone first shot is not a capture", T.PortraitStatus().reason, "missing")
AltStablePortraits = { version = 1, renders = {
    { guid = GUID, shot = 1, epoch = 5, look = "x" }, { guid = GUID, shot = 1, epoch = 9, look = "x" } } }
eq("  nor are two first shots in a row (two abandoned captures)", T.PortraitStatus().reason, "missing")
-- Someone else's capture is not ours.
pair(look, "Player-other")
eq("another character's capture does not count", T.PortraitStatus().reason, "missing")

-- The Roster's identity rules (Core's CutoutFor): GUID first, then the name,
-- refused when the name's entry names another GUID.
local slugged = AltStable.CutoutSlug("Example Surname")
AltStablePortraits = nil
AltStableCutoutManifest = { [slugged] = { file = "x.tga" } }
eq("a legacy name-keyed portrait counts", T.PortraitStatus().reason, "none")
AltStableCutoutManifest = { [slugged] = { file = "x.tga", guid = "Player-someone-else" } }
eq("  unless it names another character", T.PortraitStatus().reason, "missing")
AltStableCutoutManifest = { [GUID] = { file = "" } }
eq("an entry with no file is no portrait", T.PortraitStatus().reason, "missing")


-- Notified on a change, once.
AltStableCutoutManifest = nil
AltStablePortraits = nil
T.ResetStatus()
local seen = {}
local realUpdated = AltStable.PortraitStatusUpdated
AltStable.PortraitStatusUpdated = function(s) seen[#seen + 1] = s.reason end
AltStable.RefreshPortraitStatus()
AltStable.RefreshPortraitStatus()
eq("a refresh with nothing new notifies once", table.concat(seen, ","), "missing")
pair(T.CurrentLook())
AltStable.RefreshPortraitStatus()
eq("  and again when the answer changes", table.concat(seen, ","), "missing,pending")
AltStable.PortraitStatusUpdated = realUpdated

-- Gear changes are coalesced, then re-evaluated.
seen = {}
AltStable.PortraitStatusUpdated = function(s) seen[#seen + 1] = s.reason end
T.ResetStatus()
WoW.timers = {}
local onEvent = T.events:GetScript("OnEvent")
onEvent(T.events, "PLAYER_EQUIPMENT_CHANGED")
onEvent(T.events, "PLAYER_EQUIPMENT_CHANGED")
eq("a burst of gear changes schedules one look", #WoW.timers, 1)
WoW.flushTimers()
eq("  which re-evaluates", #seen, 1)
AltStable.PortraitStatusUpdated = realUpdated

-- A real capture records the look it photographed.
resetCapture()
wear({ [5] = 4242 })
AltStable.RefreshPortraitStatus = function() end   -- Finish calls it; not under test here
T.Capture()
runChain()
local newest = renders()[#renders()]
check("a capture records the look it photographed", newest and newest.look and newest.look:find("5:4242", 1, true),
      newest and tostring(newest.look))

-- Capture's helpers are locals: a missing forward declaration would either
-- throw (a nil global at the call) or leak a global. Neither may happen.
check("Capture leaks no global PortraitStatus or GlowForCombat",
      rawget(_G, "PortraitStatus") == nil and rawget(_G, "GlowForCombat") == nil)

-- The combat events, with the sheet's glow in place: they must run (an
-- undeclared helper threw at every pull), and must SAY combat rather than ask -
-- InCombatLockdown() is still false at PLAYER_REGEN_DISABLED.
local glowCalls = {}
local realGlow = AltStable.UpdateCaptureGlow
AltStable.UpdateCaptureGlow = function(status, inCombat) glowCalls[#glowCalls + 1] = { status = status, inCombat = inCombat } end
WoW.inCombat = false
local okDis, errDis = pcall(onEvent, T.events, "PLAYER_REGEN_DISABLED")
check("combat starting with the glow in place raises nothing", okDis, tostring(errDis))
eq("  and tells the glow it is combat, though the lockdown has not begun", glowCalls[1] and glowCalls[1].inCombat, true)
local okEn, errEn = pcall(onEvent, T.events, "PLAYER_REGEN_ENABLED")
check("combat ending raises nothing", okEn, tostring(errEn))
eq("  and tells the glow combat is over", glowCalls[2] and glowCalls[2].inCombat, false)
AltStable.UpdateCaptureGlow = realGlow

-- One pending look per loading screen burst, not one per zone.
WoW.timers = {}
onEvent(T.events, "PLAYER_ENTERING_WORLD")
onEvent(T.events, "PLAYER_ENTERING_WORLD")
eq("two loading screens schedule one look", #WoW.timers, 1)
WoW.timers = {}

-- /alts portrait glow off|on
AltStable.SetConfigValue = AltStable.SetConfigValue or function(k, v) AltStableConfig[k] = v end
AltStable.PortraitCommand("glow off")
eq("/alts portrait glow off turns it off", AltStableConfig.portraitGlow, false)
AltStable.PortraitCommand("glow on")
eq("  and on", AltStableConfig.portraitGlow, true)

-- The angle as a setting (#149): one setter behind the slider and the command,
-- straight on by default, and never written into a newer AltStable's store.
do
    AltStablePortraits = nil
    eq("captures face straight on by default", AltStable.GetPortraitFacing(), 0)
    check("the setting is accepted", AltStable.SetPortraitFacing(-15))
    eq("  and is what the capture uses", AltStable.GetPortraitFacing(), -15)
    eq("  stored in the contract's field", AltStablePortraits.facing, -15)
    -- What the stage actually turns the model by - in radians.
    T.Build()
    local turned
    local m = T.model()
    local realFacing = m.SetFacing
    m.SetFacing = function(_, r) turned = r end
    T.Preview()
    check("  which the stage turns the model by, in radians",
          turned ~= nil and math.abs(turned - math.rad(-15)) < 1e-9, tostring(turned))
    m.SetFacing = realFacing
    if T.previewing() then T.Preview() end          -- toggles it closed
    check("nonsense is refused", not AltStable.SetPortraitFacing("left"))
    eq("  and changes nothing", AltStablePortraits.facing, -15)
    AltStablePortraits = { version = 99, renders = {} }
    check("a newer store is not written by the setting", not AltStable.SetPortraitFacing(10))
    eq("  its facing untouched", AltStablePortraits.facing, nil)
    T.MigrateFacing()
    eq("  not even by the migration", AltStablePortraits.facing, nil)

    -- The range is the setter's, so the command and the slider agree.
    AltStablePortraits = nil
    AltStable.SetPortraitFacing(90)
    eq("the angle is held to 45", AltStable.GetPortraitFacing(), 45)
    AltStable.SetPortraitFacing(-90)
    eq("  either way", AltStable.GetPortraitFacing(), -45)

    -- A store from before #149: captures, no angle - they were shot at 20, and
    -- it says so once, so the next capture matches them.
    AltStablePortraits = { version = 1, renders = { { guid = "g", shot = 1 } } }
    eq("an older store's captures keep their 20", AltStable.GetPortraitFacing(), 20)
    eq("  written into it", AltStablePortraits.facing, 20)
    -- A store this version creates records its angle at once, so its first
    -- capture is not later mistaken for a pre-#149 one.
    AltStablePortraits = nil
    T.Store()
    eq("a new store records its angle", AltStablePortraits.facing, 0)
    table.insert(AltStablePortraits.renders, { guid = "g", shot = 1 })
    eq("  and its first capture keeps it", AltStable.GetPortraitFacing(), 0)
    AltStablePortraits = { version = 1, renders = {} }
    eq("one with no captures takes the new default", AltStable.GetPortraitFacing(), 0)
    eq("  written too, so absent never means two things", AltStablePortraits.facing, 0)
    AltStablePortraits = nil
end

print(("test_capture: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
