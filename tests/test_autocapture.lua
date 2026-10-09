------------------------------------------------------------
-- test_autocapture.lua - the opt-in portrait toast (AutoCapture.lua, #124)
--
-- The capture itself is test_capture's. What is pinned here is WHEN: the toast
-- appears only when asked for and only for a due look, a changed look restarts
-- it, skipping remembers the look, the countdown waits for a clear moment and
-- takes one shot, and nothing at all happens while dead.
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
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")

-- Capture.lua's seams, as spies: the capture is test_capture's business.
local blocked, capturing, shots = nil, false, {}
AltStable.PortraitBlockedReason = function() return blocked end
AltStable.PortraitCapturing = function() return capturing end
AltStable.CapturePortrait = function(opts) shots[#shots + 1] = opts or {}; return true end
local status = { due = false, reason = "none", changedSlots = {} }
AltStable.CurrentPortraitStatus = function() return status end
-- What the chain looks like before this file wraps it: PublicAPI's wrapper.
local upstream = 0
AltStable.PortraitStatusUpdated = function() upstream = upstream + 1 end

dofile("AutoCapture.lua")
local A = AltStable._test.autoCapture
check("the auto-capture exposes a test seam", A ~= nil)

local clock = 1000
GetTime = function() return clock end
local function tick(n) for _ = 1, n or 1 do clock = clock + 1; A.Tick() end end
local function update(st) status = st; AltStable.PortraitStatusUpdated(st) end
local function changed(look) return { due = true, reason = "changed", changedSlots = { "Chest" }, look = look } end
-- The offer is up while its icon is: the box beside it can be put away.
local function shown() return A.toast() ~= nil and A.toast().toggle:IsShown() end
local function reset()
    A.Stop()
    blocked, capturing, shots = nil, false, {}
    AltStableConfig.portraitAuto = true
    AltStableConfig.portraitAutoSkip = nil
    WoW.dead = false
    UIParent:Show()
    status = { due = false, reason = "none", changedSlots = {} }
end

------------------------------------------------------------
-- Off by default, and off means nothing
------------------------------------------------------------
AltStable.EnsureConfigDefaults()
eq("off by default", AltStableConfig.portraitAuto, false)
update(changed("5:1"))
check("  so a changed look shows nothing", not shown())
eq("  and the chain still runs upstream", upstream, 1)

------------------------------------------------------------
-- The offer
------------------------------------------------------------
reset()
update(changed("5:1"))
check("a changed look shows the toast", shown())
eq("  counting down five minutes", A.dueAt(), clock + 300)
check("  saying so", (A.toast().title:GetText() or ""):find("5:00", 1, true) ~= nil, A.toast().title:GetText())
check("  and why", (A.toast().sub:GetText() or ""):find("look changed", 1, true) ~= nil, A.toast().sub:GetText())
check("  ticking", A.ticker() ~= nil)
tick(61)
check("the countdown moves", (A.toast().title:GetText() or ""):find("3:59", 1, true) ~= nil, A.toast().title:GetText())

-- Like Blizzard's: in full at first, then one line.
do
    reset()
    update(changed("5:1"))
    local f = A.toast()
    eq("it starts in full", f.compact, false)
    check("  with the reason showing", f.sub:IsShown())
    local fullW = f:GetWidth()
    tick(A.COMPACT_AFTER - 1)
    eq("  for a while", f.compact, false)
    tick(1)
    eq("then it shrinks to one line", f.compact, true)
    check("  narrower", f:GetWidth() < fullW, f:GetWidth() .. " vs " .. fullW)
    check("  without the reason", not f.sub:IsShown())
    check("  still counting", (f.title:GetText() or ""):find("Portrait in 4:5", 1, true) ~= nil, f.title:GetText())
    f:GetScript("OnEnter")(f)
    eq("hovering brings the full text back", f.compact, false)
    tick(1)
    eq("  and keeps it while the cursor is there", f.compact, false)
    -- Onto the X: OnLeave fires, but the cursor is still on the toast.
    f.IsMouseOver = function() return true end
    f:GetScript("OnLeave")(f)
    eq("  reaching for the X does not shrink it", f.compact, false)
    f.IsMouseOver = function() return false end
    f:GetScript("OnLeave")(f)
    eq("  leaving does", f.compact, true)
    -- A fresh offer starts in full again.
    update(changed("5:9"))
    eq("a new look starts in full again", f.compact, false)

    -- The icon toggles the box; the offer and its countdown carry on.
    local icon = f.toggle
    icon:GetScript("OnClick")(icon)
    check("clicking the icon puts the box away", not f:IsShown())
    check("  leaving the icon up", icon:IsShown())
    local dueBefore = A.dueAt()
    tick(5)
    check("  through the ticks", not f:IsShown())
    eq("  while the countdown carries on", A.dueAt(), dueBefore)
    icon:GetScript("OnClick")(icon)
    check("clicking it again brings the box back", f:IsShown())
    icon:GetScript("OnClick")(icon)
    update(changed("5:10"))
    check("a new look brings the box back too", f:IsShown())
    A.Stop()
    check("the offer ending takes both down", not f:IsShown() and not icon:IsShown())
    -- Up again for the blocks below, which read an offer in progress.
    update(changed("5:1"))
end

-- Where Blizzard's toasts are: above the chat window, bottom left.
do
    local icon = A.toast().toggle
    local p, rel = icon:GetPoint(1)
    eq("it sits bottom left", p, "BOTTOMLEFT")
    check("  above the chat", rel == DEFAULT_CHAT_FRAME or rel == ChatAlertFrame, tostring(rel))
    eq("  under the interface, so a capture, Alt+Z and the showcase hide it",
       A.toast():GetParent(), UIParent)
    eq("  the icon too", icon:GetParent(), UIParent)
    local bp, brel, brelp = A.toast():GetPoint(1)
    check("  the box to the right of its icon", bp == "LEFT" and brel == icon and brelp == "RIGHT",
          tostring(bp) .. ">" .. tostring(brelp))
    -- Above the friends button when it shows, as Blizzard's toast is: at the
    -- container's base it covered the button (measured).
    QuickJoinToastButton = CreateFrame("Button")
    QuickJoinToastButton:Show()
    tick(1)
    local qp, qrel, qrelp = icon:GetPoint(1)
    check("  above the friends button while it shows",
          qp == "BOTTOMLEFT" and qrel == QuickJoinToastButton and qrelp == "TOPLEFT",
          tostring(qp) .. ">" .. tostring(qrelp))
    QuickJoinToastButton:Hide()
    tick(1)
    check("  and back down when it does not", select(2, icon:GetPoint(1)) ~= QuickJoinToastButton)
    QuickJoinToastButton = nil
end

-- The same look again (a status refresh with nothing new) does not restart it.
local due = A.dueAt()
update(changed("5:1"))
eq("the same look does not restart the countdown", A.dueAt(), due)
-- A different one does: the player is still changing.
update(changed("5:2"))
eq("a different look restarts it", A.dueAt(), clock + A.DELAY)
-- Nothing due any more (changed back, or captured by hand): it goes.
update({ due = false, reason = "pending", changedSlots = {} })
check("nothing due takes the toast down", not shown())
eq("  and the countdown", A.dueAt(), nil)
eq("  and the ticker", A.ticker(), nil)

-- A missing portrait is offered too, saying so.
reset()
update({ due = true, reason = "missing", changedSlots = {} })
check("no portrait at all is offered", shown())
check("  saying so", (A.toast().sub:GetText() or ""):find("No portrait yet", 1, true) ~= nil, A.toast().sub:GetText())

-- Switched off mid-countdown: gone.
AltStableConfig.portraitAuto = false
AltStable.EvaluateAutoCapture()
check("switching it off takes the toast down", not shown())

------------------------------------------------------------
-- Skip
------------------------------------------------------------
reset()
update(changed("5:1"))
A.Skip()
check("skipping takes it down", not shown())
eq("  remembering the look", AltStableConfig.portraitAutoSkip[UnitGUID("player")], "5:1")
update(changed("5:1"))
check("  so the same look is not offered again", not shown())
AltStable.EvaluateAutoCapture()
check("  not even when asked afresh", not shown())
update(changed("5:3"))
check("  while the next change is", shown())

------------------------------------------------------------
-- Now, by click
------------------------------------------------------------
reset()
update(changed("5:1"))
A.Now()
eq("clicking takes it now", #shots, 1)
check("  as a manual capture, which offers the reload", not shots[1].auto)
check("  and the offer ends", not shown())

reset()
update(changed("5:1"))
blocked = "not while you are in combat"
WoW.chatOut = {}
A.Now()
eq("a click in combat takes nothing", #shots, 0)
check("  and says why", (WoW.chatOut[#WoW.chatOut] or ""):find("combat", 1, true) ~= nil,
      tostring(WoW.chatOut[#WoW.chatOut]))
check("  keeping the offer", shown())

------------------------------------------------------------
-- The countdown ends: a clear moment, one shot
------------------------------------------------------------
reset()
update(changed("5:1"))
tick(A.DELAY - 1)
eq("nothing before the countdown is up", #shots, 0)
blocked = "not while you are moving"
tick(5)
eq("past it, not while blocked", #shots, 0)
check("  saying what it waits for", (A.toast().sub:GetText() or ""):find("moving", 1, true) ~= nil,
      A.toast().sub:GetText())
-- In full again, as Blizzard's is once its countdown ends: it was one line by
-- now, and the shot can come at any moment.
eq("  in full again once the countdown ends", A.toast().compact, false)
check("    with the reason showing", A.toast().sub:IsShown())
blocked = nil
tick(1)
eq("  not on the first clear second either", #shots, 0)
blocked = "not while you are moving"
tick(1)
blocked = nil
tick(1)
eq("  a blocked second starts the count again", #shots, 0)
tick(1)
eq("two clear seconds in a row take it", #shots, 1)
eq("  automatically", shots[1].auto, true)
check("  and end the offer", not shown() and A.ticker() == nil)
tick(10)
eq("  once", #shots, 1)

-- The other reasons to wait.
for _, case in ipairs({
    { what = "a capture already running", set = function() capturing = true end },
    { what = "the interface hidden", set = function() UIParent:Hide() end },
    { what = "someone typing", set = function() GetCurrentKeyBoardFocus = function() return {} end end },
}) do
    reset()
    update(changed("5:1"))
    case.set()
    tick(A.DELAY + 10)
    eq("it waits for " .. case.what, #shots, 0)
    GetCurrentKeyBoardFocus = nil
end

-- The in-game shortcut ends the countdown and nothing else: the clear-moment
-- rule still holds.
reset()
update(changed("5:1"))
A.Expire()
eq("Expire ends the countdown", A.dueAt(), clock)
tick(1)
eq("  but still waits for a clear moment", #shots, 0)
tick(1)
eq("  then takes it", #shots, 1)
A.Expire()
eq("  and with no offer up it does nothing", A.dueAt(), nil)

------------------------------------------------------------
-- Dead
------------------------------------------------------------
-- The corpse run that set off three dialogs in the probe.
reset()
WoW.dead = true
update(changed("5:1"))
check("nothing is offered while dead", not shown())
WoW.dead = false
WoW.timers = {}
A.events:GetScript("OnEvent")(A.events, "PLAYER_UNGHOST")
eq("coming back to life waits for the world to settle", WoW.timers[1] and WoW.timers[1].delay, A.SETTLE)
WoW.flushTimers()
check("  then offers it", shown())

print(("test_autocapture: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
