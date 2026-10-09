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
-- A real press: the mouse goes down, then the click. The down is what clears a
-- finished drag, so a click without it is not one a player can make.
local function press(frame, button)
    local down = frame:GetScript("OnMouseDown")
    if down then down(frame, button or "LeftButton") end
    frame:GetScript("OnClick")(frame, button or "LeftButton")
end
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
-- The skin's pill, as a spy: the toggle is built at the first offer, on
-- LibGlass r5's Glass.Pill (through AltStable.SkinPill), as GlassChat's
-- buttons beside the chat are. What the pill does is LibGlass's, tested there.
local pills = {}
AltStable.SkinPill = function(button, opts)
    local pill = CreateFrame("Frame", nil, button)
    pills[#pills + 1] = { button = button, opts = opts, pill = pill,
                          level = button:GetFrameLevel(),
                          highlight = button.GetHighlightTexture and button:GetHighlightTexture() }
    return pill, {}
end
reset()
update(changed("5:1"))
check("a changed look shows the toast", shown())
eq("  counting down five minutes", A.dueAt(), clock + 300)
eq("  saying so", A.toast().title:GetText(), "New portrait in 5 minutes")
check("  and why", (A.toast().sub:GetText() or ""):find("look changed", 1, true) ~= nil, A.toast().sub:GetText())
check("  ticking", A.ticker() ~= nil)
tick(61)
do
    local icon = A.toast().toggle
    WoW.tooltipLines = {}
    icon:GetScript("OnEnter")(icon)
    check("the icon's tooltip says the Companion is needed",
          table.concat(WoW.tooltipLines, "|"):find("Needs AltStable Companion", 1, true),
          table.concat(WoW.tooltipLines, "|"))
    icon:GetScript("OnLeave")(icon)
    local made = pills[1]
    eq("the icon is a glass pill, made once", #pills, 1)
    check("  on the toggle", made and made.button == icon)
    check("  kept as its pill", made and icon.pill == made.pill)
    eq("  GlassChat's size", icon:GetWidth(), 24)
    -- At level 0 the pill would be LEVEL with the button, where the rims are
    -- not sure to draw under the symbol (LibGlass docs).
    check("  on a button above level 0 when it was made", made and made.level >= 1,
          tostring(made and made.level))
    -- Set first, so Pill softens it rather than finding nothing to soften.
    check("  whose highlight was set before", made and made.highlight ~= nil)
    check("  with a symbol, not an item icon", icon.symbol ~= nil and icon.icon == nil)
    local _, _, _, x0, y0 = icon.symbol:GetPoint(1)
    icon:GetScript("OnMouseDown")(icon)
    local _, _, _, x1, y1 = icon.symbol:GetPoint(1)
    check("  which moves a pixel when pressed", x1 ~= x0 or y1 ~= y0)
    icon:GetScript("OnMouseUp")(icon)
    local _, _, _, x2, y2 = icon.symbol:GetPoint(1)
    check("  and back", x2 == x0 and y2 == y0)
end
-- In whole minutes, then seconds for the last one, as Blizzard's says it.
check("the countdown moves, in whole minutes", (A.toast().title:GetText() or ""):find("in 3 minutes", 1, true) ~= nil,
      A.toast().title:GetText())
local function leaveLeft(n) tick(A.dueAt() - clock - n) end
leaveLeft(60)
check("  one minute left is singular", (A.toast().title:GetText() or ""):find("in 1 minute", 1, true) ~= nil
      and not (A.toast().title:GetText() or ""):find("minutes", 1, true), A.toast().title:GetText())
leaveLeft(59)
check("  then seconds for the last one", (A.toast().title:GetText() or ""):find("in 59 seconds", 1, true) ~= nil,
      A.toast().title:GetText())
leaveLeft(1)
check("  down to one, singular", (A.toast().title:GetText() or ""):find("in 1 second", 1, true) ~= nil
      and not (A.toast().title:GetText() or ""):find("seconds", 1, true), A.toast().title:GetText())

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
    eq("  still counting", f.title:GetText(), "Portrait in 4 minutes")
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
    -- Onto the X, then straight off the toast: only the X's OnLeave fires
    -- then, so it lets go of the hover too (review of #215).
    f:GetScript("OnEnter")(f)
    f.IsMouseOver = function() return true end
    f:GetScript("OnLeave")(f)
    f.IsMouseOver = function() return false end
    f.close:GetScript("OnLeave")(f.close)
    eq("  leaving through the X lets it shrink again", f.compact, true)
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

-- A missing portrait is offered too, saying so. With a look, as the client
-- gives once inventory has loaded: the fixture without one was the only reason
-- "No portrait yet" passed while the game never said it (review of #215).
reset()
update({ due = true, reason = "missing", changedSlots = {}, look = "5:1" })
check("no portrait at all is offered", shown())
check("  saying so", (A.toast().sub:GetText() or ""):find("No portrait yet", 1, true) ~= nil, A.toast().sub:GetText())

-- Due but no look yet (inventory not loaded after a login): wait for it, then
-- offer under the look - one countdown, not one restarted when it loads.
reset()
update({ due = true, reason = "missing", changedSlots = {} })
check("due with no look yet offers nothing", not shown())
update({ due = true, reason = "missing", changedSlots = {}, look = "5:1" })
check("  until the look is known", shown())
eq("  under the look", A.offered(), "5:1")
local firstDue = A.dueAt()
tick(3)
update({ due = true, reason = "missing", changedSlots = {} })
eq("  and a look that goes unreadable again does not restart it", A.dueAt(), firstDue)
check("  nor take it down", shown())

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
-- A different look that the PUBLIC signal does not report (same slots
-- changed) reaches the auto-capture through its own hook.
AltStable.PortraitLookChanged(changed("5:4"))
check("the look hook alone offers a new look", shown())
A.Stop()
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
eq("  a second clear tick is only one second clear", #shots, 0)
tick(1)
eq("two clear seconds in a row take it", #shots, 1)
eq("  automatically", shots[1].auto, true)
check("  and end the offer", not shown() and A.ticker() == nil)
tick(10)
eq("  once", #shots, 1)

-- Two seconds by the clock, not two ticks: a stop seen just after it happened
-- still waits the full two seconds (Codex review of #215).
reset()
update(changed("5:1"))
tick(A.DELAY + 1)
blocked = "not while you are moving"
tick(1)
blocked = nil
clock = clock + 0.1; A.Tick()
clock = clock + 1.8; A.Tick()
eq("1.8 seconds still is not two", #shots, 0)
clock = clock + 0.2; A.Tick()
eq("  two are", #shots, 1)

-- The look as worn at the moment of the shot, not as the last status said:
-- Capture.lua refreshes two seconds after a gear change, and a swap inside
-- that wait must not be shot unannounced (Codex review of #215). `status` is
-- what CurrentPortraitStatus reads live; no update() is sent.
reset()
update(changed("5:1"))
tick(A.DELAY + 1)
status = changed("5:2")
tick(3)
eq("a look swapped before the refresh is not shot", #shots, 0)
check("  but offered, its countdown from the start", shown() and A.dueAt() > clock + A.DELAY - 5,
      tostring(A.dueAt()) .. " vs " .. clock)
tick(math.ceil(A.dueAt() - clock))
eq("  whose end waits two clear seconds of its own", #shots, 0)
reset()
update(changed("5:1"))
tick(A.DELAY + 1)
-- Same look, nothing due any more (taken by hand, say): no second shot.
status = { due = false, reason = "pending", changedSlots = {}, look = "5:1" }
tick(3)
eq("nothing due any more by the shot: nothing shot", #shots, 0)
reset()
update(changed("5:1"))
tick(A.DELAY + 1)
status = { due = false, reason = "none", changedSlots = {}, look = "5:0" }
tick(3)
eq("back to the captured look before the refresh: nothing shot", #shots, 0)
check("  and the offer ends", not shown())
reset()
update(changed("5:1"))
tick(A.DELAY + 1)
status = { due = true, reason = "changed", changedSlots = { "Chest" } }
tick(3)
eq("a look that cannot be read yet is not shot", #shots, 0)
check("  the offer waits", shown())
status = changed("5:1")
tick(2)
eq("  and once it reads the same, it is", #shots, 1)

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
tick(2)
eq("  then takes it", #shots, 1)
A.Expire()
eq("  and with no offer up it does nothing", A.dueAt(), nil)

------------------------------------------------------------
-- Moving it: Alt+drag, kept; Alt+right-click puts it back
------------------------------------------------------------
do
    reset()
    update(changed("5:1"))
    local f = A.toast()
    local icon = f.toggle
    local alt = false
    IsAltKeyDown = function() return alt end
    local moved, stopped = 0, 0
    icon.StartMoving = function() moved = moved + 1 end
    icon.StopMovingOrSizing = function() stopped = stopped + 1 end
    local placed
    icon.SetUserPlaced = function(_, v) placed = v end

    icon:GetScript("OnDragStart")(icon)
    eq("a plain drag does not move it", moved, 0)
    icon:GetScript("OnDragStop")(icon)
    eq("  and its release pins nothing: it still follows the chat", AltStableConfig.portraitToastPos, nil)

    alt = true
    icon:GetScript("OnDragStart")(icon)
    eq("an Alt+drag on the icon moves it", moved, 1)
    icon._GetLeft, icon._GetBottom = 412.4, 233.6
    icon:GetScript("OnDragStop")(icon)
    eq("  and stops", stopped, 1)
    local pos = AltStableConfig.portraitToastPos
    check("  where it was dropped is kept", pos and pos.x == 412 and pos.y == 234,
          pos and (pos.x .. "," .. pos.y) or "nil")
    eq("  as ours, not the client's layout cache", placed, false)
    local p, rel, relp, x, y = icon:GetPoint(1)
    check("  and it stays there", p == "BOTTOMLEFT" and rel == UIParent and relp == "BOTTOMLEFT"
          and x == 412 and y == 234, ("%s %s %s,%s"):format(tostring(p), tostring(relp), tostring(x), tostring(y)))
    tick(1)
    check("  through the ticks", select(4, icon:GetPoint(1)) == 412)

    -- The release that ends a drag is not a click.
    local wasHidden = not f:IsShown()
    icon:GetScript("OnClick")(icon, "LeftButton")
    eq("an Alt+click on the icon does not toggle", not f:IsShown(), wasHidden)
    f:GetScript("OnClick")(f, "LeftButton")
    eq("  nor does one on the box take it now", #shots, 0)

    -- The box drags the icon, and the box follows.
    moved = 0
    f:GetScript("OnDragStart")(f)
    eq("an Alt+drag on the box moves the icon", moved, 1)
    f:GetScript("OnDragStop")(f)

    -- A new offer, or the next session, comes up where it was put.
    A.Stop()
    update(changed("5:2"))
    check("a new offer comes up where it was put", select(4, icon:GetPoint(1)) == 412)

    -- Alt+right-click: back above the chat.
    alt = false
    icon:GetScript("OnClick")(icon, "RightButton")
    check("a plain right-click does nothing", AltStableConfig.portraitToastPos ~= nil)
    check("  not even toggle", f:IsShown())
    alt = true
    icon:GetScript("OnClick")(icon, "RightButton")
    eq("an Alt+right-click puts it back", AltStableConfig.portraitToastPos, nil)
    check("  above the chat", select(2, icon:GetPoint(1)) ~= UIParent)

    alt = false
    press(icon)
    check("a plain click still toggles", not f:IsShown())
    press(icon)

    -- Alt let go BEFORE the mouse button: the release still ends a drag, not a
    -- click - "take it now" by accident was the failure (review of #215).
    alt = true
    f:GetScript("OnMouseDown")(f, "LeftButton")
    f:GetScript("OnDragStart")(f)
    f:GetScript("OnDragStop")(f)
    alt = false
    f:GetScript("OnClick")(f, "LeftButton")
    eq("a drag released after Alt is not 'take it now'", #shots, 0)
    icon:GetScript("OnMouseDown")(icon, "LeftButton")
    icon:GetScript("OnDragStart")(icon)
    alt = true
    icon:GetScript("OnDragStart")(icon)
    icon:GetScript("OnDragStop")(icon)
    alt = false
    local before = f:IsShown()
    icon:GetScript("OnClick")(icon, "LeftButton")
    eq("  nor a toggle on the icon", f:IsShown(), before)
    press(f)
    eq("  while the next real press is", #shots, 1)

    -- A drag whose release fires no click (the client need not send one) must
    -- not swallow the next real press: the press clears what the drag left.
    alt = true
    f:GetScript("OnMouseDown")(f, "LeftButton")
    f:GetScript("OnDragStart")(f)
    f:GetScript("OnDragStop")(f)
    alt = false
    local shotsBefore = #shots
    press(f)
    eq("a drag with no click after it does not swallow the next press", #shots, shotsBefore + 1)

    -- While it is being dragged, the ticks leave it where the cursor has it -
    -- with no saved spot, so the anchor really does change under it.
    AltStableConfig.portraitToastPos = nil
    reset()
    update(changed("5:1"))
    alt = true
    icon:GetScript("OnDragStart")(icon)
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", UIParent, "CENTER", 7, 7)     -- where StartMoving has it
    QuickJoinToastButton = CreateFrame("Button"); QuickJoinToastButton:Show()
    tick(2)
    eq("the ticks do not re-anchor it mid-drag", (icon:GetPoint(1)), "CENTER")
    icon._GetLeft, icon._GetBottom = 50, 60
    icon:GetScript("OnDragStop")(icon)
    check("  and the drop puts it where it was saved", select(4, icon:GetPoint(1)) == 50)
    -- Dropped on the very spot already saved: still put back on the saved
    -- anchor, not left where StartMoving had it.
    icon:GetScript("OnDragStart")(icon)
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", UIParent, "CENTER", 7, 7)
    icon:GetScript("OnDragStop")(icon)
    eq("  even dropped on the spot already saved", (icon:GetPoint(1)), "BOTTOMLEFT")
    QuickJoinToastButton = nil
    alt = false
    AltStableConfig.portraitToastPos = nil
    IsAltKeyDown = nil
end

------------------------------------------------------------
-- A capture that started and was abandoned is offered again
------------------------------------------------------------
do
    reset()
    update(changed("5:1"))
    tick(A.DELAY + 2)
    eq("the countdown took its shot", #shots, 1)
    check("  ending the offer", not shown())
    -- Combat, death or the watchdog gave it up; the status is the same.
    AltStable.OnPortraitCaptureAbandoned()
    check("an abandoned capture is offered again", shown())
    eq("  with a fresh countdown", A.dueAt(), clock + A.DELAY)
end

------------------------------------------------------------
-- A tick asks once, and lays out only what changed
------------------------------------------------------------
do
    reset()
    update(changed("5:1"))
    local asked = 0
    AltStable.PortraitBlockedReason = function() asked = asked + 1; return "not while you are moving" end
    tick(A.DELAY + 1)
    asked = 0
    tick(1)
    eq("one blocked check per tick once the countdown is up", asked, 1)
    AltStable.PortraitBlockedReason = function() return blocked end
    local f = A.toast()
    local sized = 0
    local realSize = f.SetSize
    f.SetSize = function(self, ...) sized = sized + 1; return realSize(self, ...) end
    reset()
    update(changed("5:1"))
    sized = 0
    tick(3)
    eq("no re-layout while nothing changes", sized, 0)
    tick(A.COMPACT_AFTER)
    eq("  one when it shrinks", sized, 1)
    f.SetSize = realSize
    local icon = f.toggle
    local placed = 0
    local realPoint = icon.SetPoint
    icon.SetPoint = function(self, ...) placed = placed + 1; return realPoint(self, ...) end
    tick(3)
    eq("no re-anchoring while the anchor is the same", placed, 0)
    QuickJoinToastButton = CreateFrame("Button"); QuickJoinToastButton:Show()
    tick(1)
    eq("  one when it changes", placed, 1)
    QuickJoinToastButton = nil
    tick(1)
    icon.SetPoint = realPoint
end

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
