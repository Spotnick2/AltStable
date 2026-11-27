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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
-- The camera showcase (LibShowcase-1.0), next in the TOC.
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")   -- our prompts, before Core (TOC order)
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("Cooldowns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("Appearance.lua")   -- after CharacterMenu (TOC order): the Appearance entry
dofile("SheetUI.lua")
-- PublicAPI.lua (after SheetUI in the .toc): the footer computes its totals through it.
dofile("PublicAPI.lua")

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

eq("a plain character gets all six entries", ids(OTHER), "title,favourite,invite,look,hide,forget")

AltStable.SetCharacterFavourite("other", true)
eq("a favourite is offered the way back", ids(OTHER), "title,unfavourite,invite,look,hide,forget")
AltStable.SetCharacterFavourite("other", false)

AltStable.SetCharacterHidden("other", true)
eq("a hidden character is offered Unhide", ids(OTHER), "title,favourite,invite,look,unhide,forget")
AltStable.SetCharacterHidden("other", false)
eq("  and Hide again once it is back", ids(OTHER), "title,favourite,invite,look,hide,forget")

-- Favourite and hidden are separate states and must not collapse into one.
AltStable.SetCharacterFavourite("other", true)
AltStable.SetCharacterHidden("other", true)
eq("a character can be both at once", ids(OTHER), "title,unfavourite,invite,look,unhide,forget")
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
       "title,favourite,invite,look,hide,forget")
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
-- Invite to group (#448)
------------------------------------------------------------
do
    local function entry(char)
        for _, e in ipairs(AltStable.CharacterMenuEntries(char)) do
            if e.id == "invite" then return e end
        end
    end
    local heldFaction = WoW.faction
    WoW.faction = "Alliance"
    local ALT = { guid = "inv-1", name = "Karuzo Windmere", class = "PRIEST", faction = "Alliance" }
    AltStableDB[ALT.guid] = ALT
    WoW.invites = {}

    local e = entry(ALT)
    check("#448: an alt of the other account is offered Invite to group", e and e.text == "Invite to group")
    check("  enabled", e and not e.disabled and e.why == nil)
    check("  and choosing it invites", AltStable.CharacterMenuInvoke("invite", ALT))
    eq("  by its whole stored name, surname included", WoW.invites[1], "Karuzo Windmere")
    eq("  once", #WoW.invites, 1)

    -- The one being played.
    e = entry(ME)
    check("the character being played: disabled", e and e.disabled == true)
    check("  and told why", e and (e.why or ""):find("playing", 1, true) ~= nil, tostring(e and e.why))
    check("  and choosing it anyway invites nobody", not AltStable.CharacterMenuInvoke("invite", ME))

    -- The other faction; an unknown faction is no claim.
    ALT.faction = "Horde"
    e = entry(ALT)
    check("an alt of the other faction: disabled", e and e.disabled == true)
    check("  and told why", e and (e.why or ""):find("faction", 1, true) ~= nil, tostring(e and e.why))
    check("  and choosing it anyway invites nobody", not AltStable.CharacterMenuInvoke("invite", ALT))
    for _, f in ipairs({ "Unknown", "" }) do
        ALT.faction = f
        e = entry(ALT)
        check("  a faction not recorded (" .. f .. ") is no claim", e and not e.disabled)
    end
    ALT.faction = nil
    check("  nor is none at all", entry(ALT) and not entry(ALT).disabled)
    WoW.faction = "Horde"
    ALT.faction = "Horde"
    check("  same faction as the player, Horde side too", entry(ALT) and not entry(ALT).disabled)
    WoW.faction = "Alliance"
    ALT.faction = "Alliance"

    -- One of this WoW account: it can't be online now.
    ALT.scannedHere = true
    e = entry(ALT)
    check("an alt of this account: disabled", e and e.disabled == true)
    check("  and told why", e and (e.why or ""):find("this account", 1, true) ~= nil, tostring(e and e.why))
    check("  and choosing it anyway invites nobody", not AltStable.CharacterMenuInvoke("invite", ALT))
    ALT.scannedHere = 1   -- merged from a peer before #281: not ours
    check("  a scannedHere of 1 (an old peer's) stays invitable", entry(ALT) and not entry(ALT).disabled)
    ALT.scannedHere = nil
    ALT.provKind = "own-account"
    check("  as does an alt of the other own account", entry(ALT) and not entry(ALT).disabled)
    ALT.provKind = nil
    eq("nobody was invited by a disabled entry", #WoW.invites, 1)

    -- No name: no entry. No API: no entry, and invoking does nothing.
    local nameless = { guid = "inv-2", class = "MAGE" }
    check("a record with no name gets no invite entry", entry(nameless) == nil)
    check("  and invoking it does nothing", not AltStable.CharacterMenuInvoke("invite", nameless))
    local realParty = C_PartyInfo
    C_PartyInfo = nil
    check("without the client's invite, no entry", entry(ALT) == nil)
    check("  and invoking it does nothing", not AltStable.CharacterMenuInvoke("invite", ALT))
    C_PartyInfo = { InviteUnit = function() error("refused") end }
    check("an invite that throws is caught, and reported as not done",
          not AltStable.CharacterMenuInvoke("invite", ALT))
    C_PartyInfo = realParty

    AltStableDB[ALT.guid] = nil
    WoW.faction = heldFaction
end

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
    local P = AltStable._test.Prompt("Forget")
    check("forget asks before it deletes", P ~= nil and P:IsShown())
    local text = P and P.text:GetText() or ""
    check("  by name", text:find("Someone", 1, true) ~= nil, text)
    check("  and has deleted nothing yet", AltStableDB.other ~= nil)
    eq("  on our own prompt, never a StaticPopup (#199)", #WoW.popups, 0)
    AltStable.HidePrompt("Forget")
    check("  dismissing it deletes nothing", AltStableDB.other ~= nil)
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
          WoW.handlesClick(cat, "RightButton") and WoW.handlesClick(cat, "LeftButton"),
          table.concat(WoW.registeredClicks(cat), ","))
end

do
    -- The menu was OPENED with a right-click, so right-clicking an entry is the
    -- natural continuation of the gesture. The entry takes the mouse, so an
    -- unregistered right-click is not passed down to the catcher either: it
    -- does nothing whatsoever, which reads as a dead menu.
    AltStable.ShowCharacterMenu(OTHER)
    local entry = T.MenuEntry("hide")
    check("an entry hears the right button", entry and WoW.handlesClick(entry, "RightButton"),
          entry and table.concat(WoW.registeredClicks(entry), ","))
    check("  and the left one", entry and WoW.handlesClick(entry, "LeftButton"),
          entry and table.concat(WoW.registeredClicks(entry), ","))
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

    -- The DROP SHADOW hangs outside the panel - 12px right and 14px below for
    -- the small set - so a clamp that knows only the panel's own size puts it
    -- flush to the edge and clips the shadow off on that side alone. The menu
    -- then reads as a card lit from a different direction depending on where it
    -- opened, which is the kind of thing you notice without being able to say
    -- why.
    if AltStable.SkinIsGlass() and AltStable.Glass then
        local sp = AltStable.Glass.SIZES.small.shadowPad
        -- The screen SIZE has to be supplied: the clamp measures `root`, the
        -- stubs do not compute layout, and without a real size the clamp never
        -- binds and any assertion about it passes on an unclamped position.
        T.MenuRoot():SetSize(1920, 1080)
        WoW.cursorX, WoW.cursorY = 1919, 1
        AltStable.ShowCharacterMenu(OTHER)
        local _, _, _, ex, ey = pnl:GetPoint(1)
        cx, cy = ex, ey
        check("a menu at the right edge leaves room for its shadow",
              cx + pnl:GetWidth() + sp[3] <= 1920,
              ("%s + %s + %s"):format(tostring(cx), tostring(pnl:GetWidth()),
                                      tostring(sp[3])))
        check("  and one at the bottom does too",
              cy - pnl:GetHeight() - (-sp[4]) >= 0,
              ("%s - %s - %s"):format(tostring(cy), tostring(pnl:GetHeight()),
                                      tostring(-sp[4])))
    end

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
    check("  the confirmation is raised", AltStable._test.Prompt("Forget"):IsShown())
    AltStable.HidePrompt("Forget")

    AltStable.RequestForgetCharacter = realForget
end

do
    -- A disabled entry is inert. It is still hoverable, because the tooltip is
    -- where the reason lives.
    WoW.popups = {}
    AltStable.ShowCharacterMenu(ME)
    check("the disabled Forget does nothing when clicked", T.MenuClick("forget"))
    check("  no confirmation", not AltStable._test.Prompt("Forget"):IsShown())
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
    -- No skin setup here, deliberately. Build() ran at the top of this file and
    -- early-returns on `if root then`, so setting a skin now cannot affect
    -- anything below - the previous version did exactly that and passed only
    -- because "clear" happens to be the default. The menu under test is the one
    -- built with whatever skin was active then, which is the honest subject.
    AltStable.ShowCharacterMenu(OTHER)
    local panel   = T.MenuPanel()
    local catcher = T.MenuCatcher()

    check("there is a panel and a catcher", panel ~= nil and catcher ~= nil)

    -- THE CALL SITE, not the helper. SkinWindow has its own tests; what those
    -- cannot say is whether the menu asks for it - and replacing this call with
    -- `if true then` (shipping the old flat backdrop and no material at all)
    -- left every suite green.
    check("the menu panel actually wears the material", panel._glass ~= nil)

    if panel._glass and panel._glass.top then
        -- The ORDER of the two lines in Build() is what this is about. The rim
        -- is a child pinned to host level + 10 AT APPLY TIME, so applying the
        -- material before the panel was raised above the catcher would leave
        -- the rim ten above the CATCHER instead. Asserting
        -- panel > catcher cannot see that, because the ordering does not change
        -- it - the rim's own level is the only witness.
        check("  with its rim pinned above the panel, not above the catcher",
              panel._glass.top:GetFrameLevel() > panel:GetFrameLevel() + 9,
              ("rim %s vs panel %s"):format(
                  tostring(panel._glass.top:GetFrameLevel()),
                  tostring(panel:GetFrameLevel())))
    end

    -- The label shadow, on the REAL label. SkinText has its own test; deleting
    -- every call to it left the suite green, and a shadow is what keeps a menu
    -- entry readable when something bright passes behind the panel.
    local lbl = T.MenuEntryLabel(1)
    check("an entry label has a shadow", lbl ~= nil)
    if lbl then
        local sx, sy = lbl:GetShadowOffset()
        check("  a real one", sx ~= 0 or sy ~= 0,
              ("%s,%s"):format(tostring(sx), tostring(sy)))
    end
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
              catcher:IsShown() and WoW.handlesClick(catcher, "LeftButton"))
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
end

------------------------------------------------------------
-- Another menu on the same frame (the Legacy Bucket List's): its own entries
-- and its own action, and a character menu opened after it does the
-- character's, not the earlier menu's.
------------------------------------------------------------

do
    local picked
    check("ShowMenu opens", AltStable.ShowMenu({ { id = "title", title = true, text = "Novice Spelunker" },
                                                 { id = "remove", text = "Remove from Bucket List" } },
                                               function(id) picked = id end))
    eq("  with its own entries", labels(), "Novice Spelunker|Remove from Bucket List")
    check("  choosing one runs its action", T.MenuClick("remove") and picked == "remove")
    check("  and closes it", not T.MenuIsShown())
    check("an empty one does not open", not AltStable.ShowMenu({}, function() end) and not T.MenuIsShown())

    picked = nil
    AltStable.ShowMenu({ { id = "favourite", text = "Not a character" } }, function(id) picked = id end)
    AltStable.ShowCharacterMenu(OTHER)
    local before = AltStable.IsCharacterFavourite("other")
    T.MenuClick(before and "unfavourite" or "favourite")
    check("a character menu after it does the character's action",
          picked == nil and AltStable.IsCharacterFavourite("other") == not before)
    AltStable.CloseCharacterMenu()
end

------------------------------------------------------------
-- A menu that stays open on a pick (#378, the column chooser), and a list
-- too long for the screen wrapping into columns.
------------------------------------------------------------

do
    local on = { a = true, b = false }
    local function list()
        return { { id = "a", text = (on.a and "[x] " or "[ ] ") .. "A" },
                 { id = "b", text = (on.b and "[x] " or "[ ] ") .. "B" },
                 { id = "close", text = "Close it" },
                 { id = "other", text = "Open another" } }
    end
    local picked = {}
    local function pick(id)
        picked[#picked + 1] = id
        if id == "close" then AltStable.CloseCharacterMenu()
        elseif id == "other" then AltStable.ShowMenu({ { id = "z", text = "Another" } }, function() end)
        else on[id] = not on[id] end
    end
    WoW.cursorX, WoW.cursorY = 300, 400
    AltStable.ShowMenu(list(), pick, list)
    local pnl = T.MenuPanel()
    local _, _, _, x0, y0 = pnl:GetPoint(1)
    WoW.cursorX, WoW.cursorY = 500, 200   -- the cursor is on the entry, elsewhere
    T.MenuClick("b")
    eq("a staying menu runs the pick", picked[1], "b")
    check("  and stays open", T.MenuIsShown())
    eq("  showing its entries again", labels(), "[x] A|[x] B|Close it|Open another")
    local _, _, _, x1, y1 = pnl:GetPoint(1)
    check("  where it was", x1 == x0 and y1 == y0, ("%s,%s -> %s,%s"):format(tostring(x0), tostring(y0), tostring(x1), tostring(y1)))
    T.MenuClick("close")
    check("a pick that closes it leaves it closed", not T.MenuIsShown())

    AltStable.ShowMenu(list(), pick, list)
    T.MenuClick("other")
    eq("a pick that opens another menu leaves that one", labels(), "Another")
    T.MenuClick("z")
    check("  and the other one closes on a pick as usual", not T.MenuIsShown())

    AltStable.ShowMenu(list(), pick, function() return nil end)
    T.MenuClick("a")
    check("nothing to show again: it closes", not T.MenuIsShown())

    AltStable.ShowMenu(list(), pick, list)
    on.a = false
    check("a change made elsewhere: the staying menu shows it", AltStable.RefreshStayingMenu()
          and labels() == "[ ] A|[x] B|Close it|Open another", labels())
    AltStable.CloseCharacterMenu()
    check("  closed, there's nothing to refresh", not AltStable.RefreshStayingMenu() and not T.MenuIsShown())
    AltStable.ShowMenu({ { id = "q", text = "Q" } }, function() end)
    check("  nor for a menu that doesn't stay", not AltStable.RefreshStayingMenu() and labels() == "Q")
    AltStable.CloseCharacterMenu()
    AltStable.ShowMenu(list(), pick, function() return nil end)
    AltStable.RefreshStayingMenu()
    check("  nothing to show: it closes", not T.MenuIsShown())

    AltStable.ShowMenu(list(), pick, list)
    T.MenuEscape()
    check("Escape closes a staying menu", not T.MenuIsShown())
    AltStable.ShowCharacterMenu(OTHER)
    local fav = AltStable.IsCharacterFavourite("other")
    T.MenuClick(fav and "unfavourite" or "favourite")
    check("  and a character menu after it closes on a pick", not T.MenuIsShown())
    local n = #picked
    AltStable.ShowMenu({ { id = "q", text = "Q" } }, function(id) picked[#picked + 1] = id end)
    T.MenuClick("q")
    check("a menu opened after it closes on a pick, as before", not T.MenuIsShown() and #picked == n + 1)

    -- Wrapping: 60 entries on a 600-high screen.
    local root = T.MenuRoot()
    local realH = root.GetHeight
    root.GetHeight = function() return 600 end
    local long = {}
    for i = 1, 60 do long[i] = { id = "e" .. i, text = "Entry " .. i } end
    AltStable.ShowMenu(long, function() end)
    local w1 = pnl:GetWidth()
    check("a long list stays within the screen's height", pnl:GetHeight() <= 600 * 0.85 + 12, tostring(pnl:GetHeight()))
    local first, last = T.MenuEntry("e1"), T.MenuEntry("e60")
    local _, _, _, fx = first:GetPoint(1)
    local _, _, _, lx = last:GetPoint(1)
    check("  by wrapping into columns", lx > fx, ("%s vs %s"):format(tostring(fx), tostring(lx)))
    eq("  each entry anchored once", last:GetNumPoints(), 1)
    AltStable.CloseCharacterMenu()
    AltStable.ShowMenu({ { id = "s1", text = "Short" }, { id = "s2", text = "List" } }, function() end)
    check("a short list is one column again", pnl:GetWidth() < w1)
    local _, _, _, s2x = T.MenuEntry("s2"):GetPoint(1)
    local _, _, _, s1x = T.MenuEntry("s1"):GetPoint(1)
    eq("  one under the other", s2x, s1x)
    AltStable.CloseCharacterMenu()
    root.GetHeight = realH
    WoW.cursorX, WoW.cursorY = 800, 600
end

------------------------------------------------------------
-- A menu opened from a button (#523): under it, on screen, and readable
------------------------------------------------------------
do
    local root, pnl = T.MenuRoot(), T.MenuPanel()
    root:SetSize(1920, 1080)
    local btn = CreateFrame("Button", nil, UIParent)
    btn._GetRight, btn._GetBottom = 900, 700
    local entries = { { id = "a", text = "A" }, { id = "b", text = "B" } }
    AltStable.ShowMenu(entries, function() end, function() return entries end, { anchor = btn })
    local pt, rel, _, x, y = pnl:GetPoint(1)
    eq("under its button, right-aligned with it", ("%s %s %s"):format(pt, tostring(rel == root), tostring(x)),
       "TOPLEFT true " .. tostring(900 - pnl:GetWidth()))
    eq("  4 below it", y, 696)
    AltStable.CloseCharacterMenu()
    -- A narrow window by the left edge (Codex review of #524).
    btn._GetRight, btn._GetBottom = 60, 20
    AltStable.ShowMenu(entries, function() end, function() return entries end, { anchor = btn })
    _, _, _, x, y = pnl:GetPoint(1)
    eq("a button by the left edge: the menu pulled on screen", x, 0)
    check("  and one by the bottom keeps its bottom on screen", y >= pnl:GetHeight(), tostring(y))
    -- A scaled button: its edges are in its own units.
    AltStable.CloseCharacterMenu()
    btn._GetRight, btn._GetBottom, btn._scale = 450, 350, 2
    AltStable.ShowMenu(entries, function() end, nil, { anchor = btn })
    _, _, _, x, y = pnl:GetPoint(1)
    eq("a button at another scale: converted to the menu's", y, 696)
    btn._scale = nil
    AltStable.CloseCharacterMenu()
    -- Shown again in place: clamped again where it stands, should the screen
    -- (or the list) no longer hold it there.
    btn._GetRight, btn._GetBottom = 1900, 700
    local long = { { id = "a", text = "A" } }
    AltStable.ShowMenu(long, function() end, function() return long end, { anchor = btn })
    local _, _, _, x0, y0 = pnl:GetPoint(1)
    root:SetSize(1000, 1080)
    T.MenuClick("a")
    _, _, _, x, y = pnl:GetPoint(1)
    local padR = 0
    if AltStable.SkinIsGlass() and AltStable.Glass then padR = AltStable.Glass.SIZES.small.shadowPad[3] or 0 end
    check("shown again where it no longer fits: pulled back on screen", x + pnl:GetWidth() + padR <= 1000,
          ("%s + %s"):format(tostring(x), tostring(pnl:GetWidth())))
    eq("  at the same height", y, y0)
    root:SetSize(1920, 1080)
    AltStable.CloseCharacterMenu()
    -- The next menu without an anchor opens at the cursor again.
    WoW.cursorX, WoW.cursorY = 800, 600
    AltStable.ShowCharacterMenu(OTHER)
    _, _, _, x, y = pnl:GetPoint(1)
    check("the next menu opens at the cursor", math.abs(x - 800 / pnl:GetEffectiveScale()) < 0.01, tostring(x))
    AltStable.CloseCharacterMenu()
    -- Opaque enough to read over the grid (#523, in game): the tooltip's backing.
    if AltStable.SkinIsGlass() then
        local b = pnl.backing
        local c = b and b._colorTexture
        check("under glass the menu has the tooltip's backing", c ~= nil and c[4] == AltStable.TOOLTIP_BACKING[4],
              tostring(c and c[4]))
    end
end

WoW.finish("test_charactermenu", passed, failed)
