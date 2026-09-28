------------------------------------------------------------
-- test_charactermenu.lua — the one right-click menu (#69)
--
-- Two halves, tested apart on purpose:
--
--   * CharacterMenuEntries / CharacterMenuInvoke - no frames. What the menu
--     OFFERS for a given character, and what each entry DOES.
--   * The frame - dismissal, Escape, the click-catcher, cursor placement. This
--     is the part the client's own menu API would have handled, so it is the
--     part that has to be shown to work here.
--
-- The labels are read off the BUTTONS, not out of the generator, wherever both
-- would do: the renderer is where the two can disagree.
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
-- The material and the skin seam, in .toc order. The menu asks the skin whether
-- it is glass, so a harness without them is not the addon: it is a load order
-- that cannot happen in game.
assert(loadfile("Glass.lua"))("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("SheetUI.lua")

AltStable.EnsureConfigDefaults()

local T = AltStable._test

local ME    = { guid = "me",    name = "Player",  class = "MAGE",   realm = "R", level = 60 }
local OTHER = { guid = "other", name = "Someone", class = "ROGUE",  realm = "R", level = 40 }
AltStableDB.me, AltStableDB.other = ME, OTHER

-- UnitGUID("player") decides whether Forget is offered, so it has to be a
-- character the menu can actually be opened on.
local realUnitGUID = UnitGUID
UnitGUID = function(unit) if unit == "player" then return "me" end return realUnitGUID(unit) end

local function ids(char)
    local out = {}
    for _, e in ipairs(AltStable.CharacterMenuEntries(char)) do out[#out + 1] = e.id end
    return table.concat(out, ",")
end

local function labels()
    return table.concat(T.MenuLabels(), "|")
end

------------------------------------------------------------
-- What the menu offers
------------------------------------------------------------

eq("a plain character gets all four entries", ids(OTHER), "title,favourite,hide,forget")

AltStable.SetCharacterFavourite("other", true)
eq("a favourite is offered the way back", ids(OTHER), "title,unfavourite,hide,forget")
AltStable.SetCharacterFavourite("other", false)

AltStable.SetCharacterHidden("other", true)
eq("a hidden character is offered Unhide", ids(OTHER), "title,favourite,unhide,forget")
AltStable.SetCharacterHidden("other", false)
eq("  and Hide again once it is back", ids(OTHER), "title,favourite,hide,forget")

-- Favourite and hidden are separate states and must not collapse into one.
AltStable.SetCharacterFavourite("other", true)
AltStable.SetCharacterHidden("other", true)
eq("a character can be both at once", ids(OTHER), "title,unfavourite,unhide,forget")
AltStable.SetCharacterFavourite("other", false)
AltStable.SetCharacterHidden("other", false)

do
    -- The entry is present but disabled, not missing: a menu whose length
    -- changes depending on who you right-clicked reads as a glitch, and the
    -- reason is worth telling.
    local forget
    for _, e in ipairs(AltStable.CharacterMenuEntries(ME)) do
        if e.id == "forget" then forget = e end
    end
    eq("the character you are playing still lists Forget", ids(ME),
       "title,favourite,hide,forget")
    check("  but cannot choose it", forget and forget.disabled == true)
    check("  and is told why", forget and (forget.why or ""):find("playing") ~= nil,
          tostring(forget and forget.why))

    local other
    for _, e in ipairs(AltStable.CharacterMenuEntries(OTHER)) do
        if e.id == "forget" then other = e end
    end
    check("anybody else can", other and not other.disabled)
end

eq("nothing at all gets no menu", #AltStable.CharacterMenuEntries(nil), 0)
eq("  and neither does a record with no guid",
   #AltStable.CharacterMenuEntries({ name = "Nameless" }), 0)

------------------------------------------------------------
-- What the entries do
------------------------------------------------------------

check("favourite favourites", AltStable.CharacterMenuInvoke("favourite", OTHER))
eq("  and it took", AltStable.IsCharacterFavourite("other"), true)

-- The one that matters: EXPLICIT setters, never a toggle.
--
-- The menu is built from state and then sits on screen. Anything can change
-- that state underneath it - a sync landing, the other view, a slash command -
-- and a toggle would then do the opposite of what the entry the user is
-- looking at says. Invoking "favourite" on something already favourite must
-- leave it favourite.
AltStable.CharacterMenuInvoke("favourite", OTHER)
eq("choosing Favourite twice does not un-favourite", AltStable.IsCharacterFavourite("other"), true)
AltStable.CharacterMenuInvoke("unfavourite", OTHER)
eq("  and Remove favourite is what removes it", AltStable.IsCharacterFavourite("other"), false)
AltStable.CharacterMenuInvoke("unfavourite", OTHER)
eq("  twice over, still removed", AltStable.IsCharacterFavourite("other"), false)

AltStable.CharacterMenuInvoke("hide", OTHER)
eq("hide hides", AltStable.IsCharacterHidden("other"), true)
AltStable.CharacterMenuInvoke("hide", OTHER)
eq("  and hiding again leaves it hidden", AltStable.IsCharacterHidden("other"), true)
AltStable.CharacterMenuInvoke("unhide", OTHER)
eq("unhide unhides", AltStable.IsCharacterHidden("other"), false)
AltStable.CharacterMenuInvoke("unhide", OTHER)
eq("  and again leaves it shown", AltStable.IsCharacterHidden("other"), false)

check("an unknown entry does nothing", AltStable.CharacterMenuInvoke("nonsense", OTHER) == false)
check("  and neither does a real one on nothing",
      AltStable.CharacterMenuInvoke("hide", nil) == false)

do
    WoW.popups = {}
    AltStable.CharacterMenuInvoke("forget", OTHER)
    eq("forget asks before it deletes", #WoW.popups, 1)
    check("  by name", WoW.popups[1] and WoW.popups[1].arg1 == "Someone",
          tostring(WoW.popups[1] and WoW.popups[1].arg1))
    check("  and has deleted nothing yet", AltStableDB.other ~= nil)
    StaticPopup_Hide(WoW.popups[1].which)
end

------------------------------------------------------------
-- The frame: what it draws
------------------------------------------------------------

check("no menu to begin with", T.MenuIsShown() == false)
check("opening one works", AltStable.ShowCharacterMenu(OTHER))
check("  and it is on screen", T.MenuIsShown())

check("the title carries the character's name", labels():find("Someone", 1, true) ~= nil, labels())
check("  in its class colour", labels():find("|cff", 1, true) ~= nil, labels())

do
    -- The BUTTONS, against the generator. These are two code paths and the
    -- renderer is where they part company - it is the half that decides which
    -- button gets which entry, and an off-by-one there draws a menu whose
    -- labels are right and whose actions are not.
    local want = {}
    for _, e in ipairs(AltStable.CharacterMenuEntries(OTHER)) do want[#want + 1] = e.text end
    eq("every entry is drawn, in order", labels(), table.concat(want, "|"))
end

do
    local root, pnl, cat = T.MenuRoot(), T.MenuPanel(), T.MenuCatcher()
    check("the catcher and the panel are siblings under one root",
          cat:GetParent() == root and pnl:GetParent() == root)
    check("  the panel draws above the catcher",
          pnl:GetFrameLevel() > cat:GetFrameLevel(),
          pnl:GetFrameLevel() .. " vs " .. cat:GetFrameLevel())
    -- Without this the catcher underneath swallows clicks on the menu's own
    -- padding, and the menu closes when you aim slightly wide of an entry.
    check("  and the panel takes the mouse itself", pnl:IsMouseEnabled())
    check("the catcher hears every button, not just the left one",
          cat:HandlesClick("RightButton") and cat:HandlesClick("LeftButton"),
          table.concat(cat:RegisteredClicks(), ","))
end

do
    -- The menu was OPENED with a right-click, so right-clicking an entry is the
    -- natural continuation of the gesture. The entry takes the mouse, so an
    -- unregistered right-click is not passed down to the catcher either: it
    -- does nothing whatsoever, which reads as a dead menu.
    AltStable.ShowCharacterMenu(OTHER)
    local entry = T.MenuEntry("hide")
    check("an entry hears the right button", entry and entry:HandlesClick("RightButton"),
          entry and table.concat(entry:RegisteredClicks(), ","))
    check("  and the left one", entry and entry:HandlesClick("LeftButton"),
          entry and table.concat(entry:RegisteredClicks(), ","))
    AltStable.CloseCharacterMenu()
end

do
    -- Entry buttons are POOLED, so every opening re-anchors the same button.
    -- An anchor list that grew instead of being replaced would leave the first
    -- recorded TOP behind for ever, and every placement assertion in this file
    -- would be reading a position from the first opening.
    AltStable.ShowCharacterMenu(OTHER)
    local e = T.MenuEntry("hide")
    local firstTop = select(5, e:GetPoint(1))
    local n = e:GetNumPoints()
    AltStable.CloseCharacterMenu()
    AltStable.ShowCharacterMenu(OTHER)
    eq("re-opening the menu does not stack another anchor on a pooled entry",
       T.MenuEntry("hide"):GetNumPoints(), n)
    check("  (and the anchor it keeps is a real one)", firstTop ~= nil)
    AltStable.CloseCharacterMenu()
end

------------------------------------------------------------
-- The frame: where it opens
------------------------------------------------------------

do
    local root, pnl = T.MenuRoot(), T.MenuPanel()
    root:SetSize(1920, 1080)

    -- Expectations derived from the EFFECTIVE scale, not written as constants.
    -- They used to be 800 and 400, which was only right while UIParent's scale
    -- was 1 - and a stub UIParent at scale 1 is the thing that made the whole
    -- physical-pixels-to-frame-units conversion untestable everywhere it
    -- appears. The division is still the assertion; the number it divides by is
    -- now the real one.
    WoW.cursorX, WoW.cursorY = 800, 600
    pnl._scale = 1
    AltStable.ShowCharacterMenu(OTHER)
    local _, _, _, x, y = pnl:GetPoint(1)
    local es1 = pnl:GetEffectiveScale()
    check("at scale 1 the menu opens at the cursor", math.abs(x - 800 / es1) < 0.01,
          ("%s vs %s"):format(tostring(x), tostring(800 / es1)))
    check("  vertically too", math.abs(y - 600 / es1) < 0.01)

    -- The trap. GetCursorPosition is in PHYSICAL pixels and an anchor offset is
    -- in the frame's own units, so the division is the whole job. Without it
    -- the menu opens at twice the distance from the corner on a half-scaled UI
    -- - which reads as opening somewhere random, not as a scaling bug.
    pnl._scale = 2
    AltStable.ShowCharacterMenu(OTHER)
    local _, _, _, x2, y2 = pnl:GetPoint(1)
    local es2 = pnl:GetEffectiveScale()
    check("a scaled UI divides the cursor by the scale",
          math.abs(x2 - 800 / es2) < 0.01,
          ("%s vs %s"):format(tostring(x2), tostring(800 / es2)))
    check("  vertically too", math.abs(y2 - 600 / es2) < 0.01)
    -- And it really is a different divisor, or the two cases above are one case
    -- written twice.
    check("  which is a different number from the unscaled case", es2 > es1)
    pnl._scale = 1

    -- Right-clicking near an edge must not put the menu off-screen, where it
    -- cannot be read OR dismissed by clicking an entry.
    WoW.cursorX, WoW.cursorY = 1915, 1078
    AltStable.ShowCharacterMenu(OTHER)
    local _, _, _, cx, cy = pnl:GetPoint(1)
    check("a menu opened at the right edge is pulled back on screen",
          cx + pnl:GetWidth() <= 1920, tostring(cx))
    check("  and one at the top keeps its bottom on screen too",
          cy <= 1080 and cy >= pnl:GetHeight(), tostring(cy))

    WoW.cursorX, WoW.cursorY = 5, 5
    AltStable.ShowCharacterMenu(OTHER)
    local _, _, _, lx, ly = pnl:GetPoint(1)
    check("the bottom-left corner does not push it off the bottom",
          ly >= pnl:GetHeight(), tostring(ly))
    check("  nor off the left", lx >= 0, tostring(lx))

    WoW.cursorX, WoW.cursorY = 800, 600
end

------------------------------------------------------------
-- The frame: how it closes
------------------------------------------------------------

AltStable.ShowCharacterMenu(OTHER)
check("a click outside closes it", T.MenuClickOutside() and T.MenuIsShown() == false)

AltStable.ShowCharacterMenu(OTHER)
check("Escape closes it", T.MenuEscape() and T.MenuIsShown() == false)

do
    -- UISpecialFrames is not enough on its own: the sheet is registered there
    -- too and comes first, so one Escape would shut the whole window and leave
    -- the menu behind. The menu handles the key itself - and must hand every
    -- OTHER key straight back, or it is a menu you cannot walk away from.
    AltStable.ShowCharacterMenu(OTHER)
    eq("Escape is swallowed by the menu", T.MenuKey("ESCAPE"), true)
    AltStable.ShowCharacterMenu(OTHER)
    eq("  but movement keys are not", T.MenuKey("W"), false)
    check("  and the menu is still open after one", T.MenuIsShown())
    AltStable.CloseCharacterMenu()
end

------------------------------------------------------------
-- Combat
------------------------------------------------------------
-- SetPropagateKeyboardInput is a protected method (Mainline marks it
-- restricted; Forever's own DialogueUI guards it with InCombatLockdown).
-- Whether THIS client throws is unmeasured, so the menu is written to survive
-- both answers rather than betting on one.

do
    local realCombat = InCombatLockdown
    InCombatLockdown = function() return true end

    AltStable.CloseCharacterMenu()
    AltStable.ShowCharacterMenu(OTHER)
    check("the menu still opens in combat", T.MenuIsShown())
    check("  but does not grab the keyboard",
          T.MenuRoot():IsKeyboardEnabled() == false,
          "grabbing it means handing every movement key back one at a time "
          .. "through a method that may be restricted in combat")

    -- It is still fully usable, because the gesture that opens it is a mouse
    -- gesture and so is every way out of it.
    check("  and an outside click still dismisses it",
          T.MenuClickOutside() and T.MenuIsShown() == false)

    -- Entering combat with the menu ALREADY open leaves the handler installed,
    -- which is why the propagation call is wrapped rather than merely guarded:
    -- an error there would fire on every keypress, in combat.
    InCombatLockdown = realCombat
    AltStable.ShowCharacterMenu(OTHER)
    check("the keyboard is taken out of combat", T.MenuRoot():IsKeyboardEnabled())
    InCombatLockdown = function() return true end

    local root = T.MenuRoot()
    local realSet = root.SetPropagateKeyboardInput
    root.SetPropagateKeyboardInput = function()
        error("ADDON_ACTION_BLOCKED: SetPropagateKeyboardInput")
    end
    local ok = pcall(function() return T.MenuKey("W") end)
    check("a restricted propagation call does not take out the key handler", ok)

    -- Surviving is not the same as working. A handler that catches the error
    -- and leaves the frame keyboard-enabled with propagation still false eats
    -- the key just as completely as one that threw - and the first version of
    -- this test asserted only that W did not throw, so it passed against
    -- exactly that.
    check("  and the key actually reaches the game", not T.MenuSwallowsKeys(),
          "the menu kept the keyboard and never handed the key back")

    check("  while Escape still closes the menu",
          pcall(function() return T.MenuEscape() end) and T.MenuIsShown() == false,
          "a menu that cannot be closed is worse than one that shares Escape")
    root.SetPropagateKeyboardInput = realSet

    InCombatLockdown = realCombat
    AltStable.CloseCharacterMenu()
end

do
    -- The reachable sequence, start to finish.
    --
    -- Escape sets propagation to FALSE and that state outlives the menu. Open
    -- again, enter combat while it sits there - which the open-time guard
    -- cannot see, because the menu was opened out of combat - and press a
    -- movement key. The restricted call fails silently, propagation is still
    -- false from the Escape, and the player cannot walk.
    local realCombat = InCombatLockdown

    AltStable.CloseCharacterMenu()
    AltStable.ShowCharacterMenu(OTHER)
    T.MenuEscape()                       -- leaves propagation false
    check("Escape closed it", T.MenuIsShown() == false)

    AltStable.ShowCharacterMenu(OTHER)   -- still out of combat
    check("reopening resets propagation rather than inheriting the Escape",
          not T.MenuSwallowsKeys(),
          "the first key of this opening would be swallowed")

    -- Combat begins with the menu already open.
    InCombatLockdown = function() return true end
    check("the combat event is handled", T.MenuCombat())
    check("  and the menu lets go of the keyboard",
          T.MenuRoot():IsKeyboardEnabled() == false,
          "no key should ever have to be swallowed first")

    local root = T.MenuRoot()
    local realSet = root.SetPropagateKeyboardInput
    root.SetPropagateKeyboardInput = function()
        error("ADDON_ACTION_BLOCKED: SetPropagateKeyboardInput")
    end
    T.MenuKey("W")
    check("so W reaches the game in the full sequence", not T.MenuSwallowsKeys(),
          "open, Escape, reopen, enter combat, press W - and you cannot move")
    root.SetPropagateKeyboardInput = realSet

    InCombatLockdown = realCombat
    AltStable.CloseCharacterMenu()
end

do
    -- The same trap with the combat event taken away.
    --
    -- Both other defences are keyed to combat: the release on
    -- PLAYER_REGEN_DISABLED, and the reset when the menu opens, which succeeds
    -- because opening happens out of combat. Neither helps if the restriction
    -- is not strictly combat-keyed - and whether it is on this client is the
    -- unmeasured part, so it is the case worth being right about.
    --
    -- Here the reset at open time fails silently, leaving propagation false
    -- from the previous Escape. Releasing the keyboard when the call fails is
    -- then the ONLY thing standing between the player and a key that never
    -- arrives.
    AltStable.CloseCharacterMenu()
    AltStable.ShowCharacterMenu(OTHER)
    T.MenuEscape()                        -- propagation left false

    local root = T.MenuRoot()
    local realSet = root.SetPropagateKeyboardInput
    root.SetPropagateKeyboardInput = function()
        error("ADDON_ACTION_BLOCKED: SetPropagateKeyboardInput")
    end

    AltStable.ShowCharacterMenu(OTHER)    -- out of combat; the reset throws
    check("the menu took the keyboard", root:IsKeyboardEnabled())
    T.MenuKey("W")
    check("a key that cannot be handed back releases the keyboard instead",
          not T.MenuSwallowsKeys(),
          "propagation was left false and the frame kept the keyboard")

    root.SetPropagateKeyboardInput = realSet
    AltStable.CloseCharacterMenu()
end

do
    -- Closed BEFORE the action runs, not merely closed by the time anyone
    -- looks. Forget raises a confirmation, and a menu still on screen
    -- underneath it - with a full-screen catcher over everything - swallows
    -- the first click aimed at the dialog.
    --
    -- So the state is captured FROM INSIDE the action. Asserting
    -- "MenuIsShown() == false" after the click cannot tell the two orders
    -- apart: the menu is shut either way by the time the assertion runs, and
    -- that version of this check passed against the bug.
    local wasOpenDuringAction
    local realForget = AltStable.RequestForgetCharacter
    AltStable.RequestForgetCharacter = function(char)
        wasOpenDuringAction = T.MenuIsShown()
        return realForget(char)
    end

    WoW.popups = {}
    AltStable.ShowCharacterMenu(OTHER)
    T.MenuClick("forget")
    eq("the menu is already closed when the action runs", wasOpenDuringAction, false)
    check("  and stays closed", T.MenuIsShown() == false)
    eq("  the confirmation is raised", #WoW.popups, 1)
    StaticPopup_Hide(WoW.popups[1].which)

    AltStable.RequestForgetCharacter = realForget
end

do
    -- A disabled entry is inert. It is still hoverable, because the tooltip is
    -- where the reason lives.
    WoW.popups = {}
    AltStable.ShowCharacterMenu(ME)
    check("the disabled Forget does nothing when clicked", T.MenuClick("forget"))
    eq("  no confirmation", #WoW.popups, 0)
    check("  and the menu stays open, since nothing happened", T.MenuIsShown())
    AltStable.CloseCharacterMenu()
end

do
    -- Entry buttons are pooled across openings. A menu that was four entries
    -- long and is now three must not leave the fourth button drawn under the
    -- backdrop, still clickable, still carrying the last character's action.
    AltStable.SetCharacterHidden("other", true)
    AltStable.ShowCharacterMenu(OTHER)
    local hiddenLen = #T.MenuLabels()
    AltStable.CloseCharacterMenu()
    AltStable.SetCharacterHidden("other", false)
    AltStable.ShowCharacterMenu(OTHER)
    eq("a re-opened menu draws only its own entries", #T.MenuLabels(),
       #AltStable.CharacterMenuEntries(OTHER))
    check("  including after a shorter one", hiddenLen > 0, tostring(hiddenLen))
    AltStable.CloseCharacterMenu()
end

------------------------------------------------------------
-- The showcase: lifted out from under a hidden UIParent
------------------------------------------------------------

do
    local realHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return true end
    UIParent:Hide()

    AltStable.ShowCharacterMenu(OTHER)
    local root = T.MenuRoot()
    check("the menu is lifted out from under the hidden UIParent",
          root:GetParent() ~= UIParent, tostring(root:GetParent()))
    check("  so it can actually be seen", root:IsVisible() == true)
    check("  and the catcher came with it, still under the root",
          T.MenuCatcher():GetParent() == root)

    AltStable.CloseCharacterMenu()
    eq("closing parents it back", root:GetParent(), UIParent)
    check("  leaving no full-screen catcher over the game",
          root:IsShown() == false)

    UIParent:Show()
    AltStable.IsGameUIHidden = realHidden
end

do
    -- Lifting is idempotent in both directions, and that is load-bearing: a
    -- second lift used to save the ALREADY-LIFTED scale and strata, so the
    -- restore afterwards left the frame permanently raised. The only symptom
    -- was somebody else's dialog turning up in the wrong place.
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("LOW")
    f:SetScale(0.8)

    AltStable.LiftAboveHiddenUI(f, true)
    AltStable.LiftAboveHiddenUI(f, true)
    AltStable.LiftAboveHiddenUI(f, false)
    eq("a double lift still restores the strata", f:GetFrameStrata(), "LOW")
    eq("  and the scale", f:GetScale(), 0.8)
    eq("  and the parent", f:GetParent(), UIParent)

    AltStable.LiftAboveHiddenUI(f, false)
    eq("a double drop changes nothing either", f:GetFrameStrata(), "LOW")
    eq("  scale intact", f:GetScale(), 0.8)
end

------------------------------------------------------------
-- One menu, both views
------------------------------------------------------------

-- The sheet row and the Roster card must raise the SAME menu. Asserted as one
-- entry point rather than by comparing two lists: two lists that happen to
-- match today is exactly the drift this is meant to prevent.
check("there is one entry point for both views",
      type(AltStable.ShowCharacterMenu) == "function")
check("  and one generator behind it",
      type(AltStable.CharacterMenuEntries) == "function")

UnitGUID = realUnitGUID

------------------------------------------------------------
-- The material (#97 phase 2)
------------------------------------------------------------
-- The menu is a window in its own right, floating over the world beside a glass
-- sheet. What matters is that dressing it did not disturb how it takes INPUT:
-- the catcher is a sibling below the panel, the panel eats clicks on its own
-- padding, and Escape is handled on the root.
do
    AltStableConfig.skin = "clear"
    AltStable._ResetSkinCache()

    AltStable.ShowCharacterMenu(OTHER)
    local panel   = T.MenuPanel()
    local catcher = T.MenuCatcher()

    check("there is a panel and a catcher", panel ~= nil and catcher ~= nil)
    if panel and catcher then
        -- The material puts its rim on a child frame at host level + 10, and
        -- that child takes the level the host has AT APPLY TIME. Applied before
        -- the panel was raised above the catcher, the rim would sit ten above
        -- the CATCHER instead - which is why the order of those two lines in
        -- Build() is load-bearing rather than tidy.
        check("the panel still sits above the catcher",
              panel:GetFrameLevel() > catcher:GetFrameLevel(),
              ("panel %s vs catcher %s"):format(
                  tostring(panel:GetFrameLevel()), tostring(catcher:GetFrameLevel())))
        check("  and the catcher still covers the screen and takes clicks",
              catcher:IsShown() and catcher:HandlesClick("LeftButton"))
    end

    -- The hover fill is rounded, keeping its own full-entry bounds: the nav
    -- painter insets 6px vertically, which on a 17px entry would leave an 11px
    -- fill floating inside the row.
    local bg = T.MenuEntryBG(1)
    check("an entry's hover fill is rounded", bg ~= nil and bg:GetNumMaskTextures() > 0)
    if bg then
        local _, rel = bg:GetMaskTexture(1):GetPoint(1)
        eq("  by a mask anchored to the fill itself", rel, bg)
    end

    AltStable.CloseCharacterMenu()

    -- And under flat the menu keeps the backdrop it always had.
    AltStableConfig.skin = "flat"
    AltStable._ResetSkinCache()
end

print(("test_charactermenu: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
