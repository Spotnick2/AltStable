------------------------------------------------------------
-- test_sheetui.lua — the sheet, executed
--
-- SheetUI.lua now BUILDS under tests/wow_stubs.lua: ShowSheet creates its
-- frames and Refresh draws a pass. That matters because the alternative was
-- grepping the source, and a source check cannot see the failure this file
-- exists to catch - a count declared local in one function and read in another
-- compiles as a nil global and errors on every single sheet build, while the
-- text of both lines looks exactly right.
--
-- What the stubs give up, stated plainly: every frame is a table that accepts
-- any call, geometry getters return fixed numbers, and nothing is drawn. So
-- this file asserts VALUES the sheet computes and text it sets, never layout.
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
-- Glass.lua is loaded with the addon NAME, the way the client passes it: it
-- derives its media path from `...`, and a bare dofile leaves that nil so every
-- texture path comes out as "Interface\AddOns\nil\...".
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

local GOLD = 10000   -- copper per gold

-- Footer text carries colour codes between the numbers and their labels, so
-- "5 avg iLvl" is really "|cffaaaaaa5|r avg iLvl". Strip the markup before
-- asserting, or every check has to know the colours.
local function plain(s)
    if not s then return nil end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

-- EnsureSheetVisible, not ShowSheet: ShowSheet TOGGLES, so calling it on an
-- already-open sheet closes it - and a closed sheet does not refresh, leaving
-- every later assertion reading a stale footer. That went unnoticed while the
-- stub's Hide() was a no-op; now that frames model shown-ness it matters.
local function build(db)
    AltStableDB = db
    local ok, err = pcall(AltStable.EnsureSheetVisible)
    check("the sheet builds", ok, tostring(err))
    if ok then
        local ok2, err2 = pcall(AltStable.RefreshSheet)
        check("  and refreshes", ok2, tostring(err2))
    end
    return plain(AltStable._test.FooterText())
end

------------------------------------------------------------
-- The footer totals
------------------------------------------------------------

local footer = build({
    a = { guid = "a", name = "Rich", class = "MAGE", realm = "R", level = 60,
          ilvl = 66, money = 123 * GOLD, lastUpdate = 1 },
    b = { guid = "b", name = "Poor", class = "ROGUE", realm = "R", level = 40,
          ilvl = 40, money = 7 * GOLD, lastUpdate = 1 },
})
check("the footer says something", footer ~= nil and #footer > 0, tostring(footer))
if footer then
    check("it counts the characters", footer:find("2", 1, true) ~= nil, footer)
    check("it totals the levels", footer:find("100", 1, true) ~= nil, footer)
    check("it totals the gold", footer:find("130", 1, true) ~= nil, footer)
    check("  with no unknown marker when every character has money",
          footer:find("unknown", 1, true) == nil, footer)
end

------------------------------------------------------------
-- Money that cannot be read (#49)
------------------------------------------------------------
-- On the measured PvP realm GetMoney returns a secret value, so the scan stores
-- nothing and the field is absent. Counting that as zero would present the sum
-- as the whole account's gold while quietly leaving a character out.

footer = build({
    a = { guid = "a", name = "Rich", class = "MAGE", realm = "R", level = 60,
          ilvl = 66, money = 123 * GOLD, lastUpdate = 1 },
    b = { guid = "b", name = "Secretive", class = "ROGUE", realm = "R", level = 40,
          ilvl = 40, lastUpdate = 1 },   -- no money field at all
})
if footer then
    check("the total still shows the gold it does know", footer:find("123", 1, true) ~= nil, footer)
    check("  and says one character is unknown", footer:find("(1 unknown)", 1, true) ~= nil, footer)
end

footer = build({
    a = { guid = "a", name = "One", class = "MAGE", realm = "R", level = 1, lastUpdate = 1 },
    b = { guid = "b", name = "Two", class = "ROGUE", realm = "R", level = 1, lastUpdate = 1 },
})
if footer then
    check("two unknown characters are both counted", footer:find("(2 unknown)", 1, true) ~= nil, footer)
end

------------------------------------------------------------
-- The average item level is rounded, like the column (#39)
------------------------------------------------------------

footer = build({
    a = { guid = "a", name = "A", class = "MAGE", realm = "R", level = 60, ilvl = 4.5,
          money = 0, lastUpdate = 1 },
    b = { guid = "b", name = "B", class = "ROGUE", realm = "R", level = 60, ilvl = 4.5,
          money = 0, lastUpdate = 1 },
})
if footer then
    check("the footer average is a whole number", footer:find("5 avg iLvl", 1, true) ~= nil, footer)
    check("  not one decimal place", footer:find("4.5 avg", 1, true) == nil, footer)
end

------------------------------------------------------------
-- Hidden characters (#21)
--
-- Hiding is a VIEW filter: the record stays in the database, keeps syncing and
-- keeps updating. So these checks watch the grid, the totals and the restore
-- list, and never the store.
------------------------------------------------------------

-- Refresh without re-running ShowSheet (which toggles).
local function refresh()
    local ok, err = pcall(AltStable.RefreshSheet)
    check("the sheet refreshes", ok, tostring(err))
    return plain(AltStable._test.FooterText())
end

local function joined(list) return table.concat(list, ",") end

AltStableConfig.hiddenCharacters = {}
footer = build({
    keep = { guid = "keep", name = "Keeper", class = "MAGE", realm = "R", level = 60,
             ilvl = 60, money = 100 * GOLD, lastUpdate = 1 },
    gone = { guid = "gone", name = "Goner", class = "ROGUE", realm = "R", level = 40,
             ilvl = 20, money = 50 * GOLD, lastUpdate = 1 },
})
eq("both characters start visible", joined(AltStable._test.DisplayNames()), "Keeper,Goner")

-- A right-click opens the MENU (#69). It used to raise "hide this character?"
-- directly, which spent the only right-click there is on one of the four things
-- that want it.
WoW.popups = {}
AltStable.ShowCharacterMenu(AltStableDB.gone)
check("a right-click opens the menu", AltStable._test.MenuIsShown())
eq("  and asks nothing yet", #WoW.popups, 0)

do
    local labels = table.concat(AltStable._test.MenuLabels(), "|")
    check("  the menu is titled with the character", labels:find("Goner", 1, true) ~= nil, labels)
    check("  and offers to hide it", labels:find("Hide", 1, true) ~= nil, labels)
end

-- Hiding is immediate and unconfirmed now. The confirmation existed because
-- the way back was a list in Options the user had no reason to have seen; the
-- footer toggle below is that way back, and it is on screen.
AltStable._test.MenuClick("hide")
eq("choosing Hide asks nothing", #WoW.popups, 0)
eq("  and hides the character there and then", AltStable.IsCharacterHidden("gone"), true)
eq("  the grid drops the row", joined(AltStable._test.DisplayNames()), "Keeper")
check("  and the menu closes behind it", AltStable._test.MenuIsShown() == false)

-- Reversed from the menu, which is the point of dropping the confirmation.
AltStable.ShowCharacterMenu(AltStableDB.gone)
do
    local labels = table.concat(AltStable._test.MenuLabels(), "|")
    check("a hidden character is offered Unhide, not Hide",
          labels:find("Unhide", 1, true) ~= nil, labels)
end
AltStable._test.MenuClick("unhide")
eq("  which puts it back", AltStable.IsCharacterHidden("gone"), false)
eq("  and the row returns", joined(AltStable._test.DisplayNames()), "Keeper,Goner")

-- Back to hidden for the footer checks below.
AltStable.ShowCharacterMenu(AltStableDB.gone)
AltStable._test.MenuClick("hide")
eq("hidden again for the totals checks", AltStable.IsCharacterHidden("gone"), true)

footer = refresh()
if footer then
    check("the footer counts only the visible characters",
          footer:find("1%s+chars") ~= nil, footer)
    check("  levels exclude the hidden one", footer:find("60%s+total levels") ~= nil, footer)
    check("  gold excludes the hidden one", footer:find("100", 1, true) ~= nil, footer)
    check("  and does not total all of it", footer:find("150", 1, true) == nil, footer)
    check("  the average iLvl excludes it too", footer:find("60 avg iLvl", 1, true) ~= nil, footer)
end

-- The marker moved OUT of the gold string into its own button, so that a click
-- on it can toggle the view without a click on the gold total doing the same.
-- Asserted on the button, not on the footer text, or the move would look like
-- the marker disappearing.
check("the gold string no longer carries the hidden marker",
      (footer or ""):find("hidden", 1, true) == nil, footer)
eq("a marker says how many were left out", AltStable._test.HiddenToggleText(),
   "|cff808080(1 hidden)|r")

-- The record itself is untouched: hiding is not deleting.
check("the character is still in the database",
      type(AltStableDB.gone) == "table" and AltStableDB.gone.name == "Goner")

------------------------------------------------------------
-- The opening fade can be finished from outside
------------------------------------------------------------
-- It owns the sheet's alpha for 0.22 seconds, and the portrait capture
-- borrows that alpha to hide the sheet for the shot. A capture starting
-- inside the fade read 0 - or a third of the way up - while the fade carried
-- on to 1 under its own timer, and the restore afterwards wrote the stale
-- number back. A sheet shown and completely invisible, with nothing on screen
-- to explain it.

do
    AltStableConfig.enableOpenAnimation = true
    -- A scale that is NOT the fallback, or the settled-scale check below
    -- compares 1.0 against 1.0 and a hardcoded SetScale(1) passes it.
    AltStableConfig.scale = 1.4
    local sheet = CreateFrame("Frame")
    sheet:SetAlpha(1)

    AltStable._PlayOpenAnimation(sheet)
    eq("the fade starts the sheet invisible", sheet:GetAlpha(), 0)

    check("the fade reports that it finished something",
          AltStable.FinishOpenAnimation() == true)
    eq("  and leaves the sheet at its settled alpha", sheet:GetAlpha(), 1)
    eq("  and its settled scale", sheet:GetScale(), 1.4)

    -- Idempotent, and honest about it: anything about to borrow the alpha
    -- calls this whether or not a fade is running, so "nothing to finish" has
    -- to be a normal answer rather than a second write.
    sheet:SetAlpha(0.5)
    check("finishing again reports there was nothing to do",
          AltStable.FinishOpenAnimation() == false)
    eq("  and touches nothing", sheet:GetAlpha(), 0.5)

    -- Mid-fade, not only at the start: the capture can land anywhere in the
    -- 0.22 seconds.
    sheet:SetAlpha(1)
    AltStable._PlayOpenAnimation(sheet)
    local tick = AltStable._test.OpenAnimTick()
    if tick then tick(0.1) end
    check("part way through, the sheet is part way faded",
          sheet:GetAlpha() > 0 and sheet:GetAlpha() < 1, tostring(sheet:GetAlpha()))
    AltStable.FinishOpenAnimation()
    eq("  and finishing still lands on 1", sheet:GetAlpha(), 1)

    -- It still has to END BY ITSELF.
    --
    -- FinishOpenAnimation is now the only thing that stops the runner, and it
    -- bails when `target` is nil - so a terminal condition that never fires
    -- leaves a shown runner writing alpha and scale every frame for the rest
    -- of the session, holding a live reference to the sheet. Nothing here
    -- noticed: changing `p >= 1` to `p >= 99` left every check passing.
    sheet:SetAlpha(1)
    AltStable._PlayOpenAnimation(sheet)
    local run = AltStable._test.OpenAnimTick()
    run(0.3)                                    -- past the 0.22s duration
    eq("the fade ends on its own", sheet:GetAlpha(), 1)
    eq("  at the settled scale", sheet:GetScale(), 1.4)
    check("  and really has stopped, not merely arrived",
          AltStable.FinishOpenAnimation() == false,
          "a runner still holding the sheet would report there was work to do")

    -- The sheet's OWN capture is a second borrower of the same alpha, and was
    -- left racing.
    --
    -- Its legacy path - reached when the probe's two-shot capture is missing
    -- or declines - writes 0, waits 1.3s, shoots, then writes a hardcoded 1.
    -- A live fade overwrites that 0 and climbs to 1 under its own timer well
    -- before the shutter, so the sheet ends up fully visible in the portrait:
    -- the exact thing hiding it was for, and the mirror image of the bug on
    -- the probe's side.
    do
        AltStableDB[UnitGUID("player")] = AltStableDB[UnitGUID("player")]
            or { guid = UnitGUID("player"), name = "Shooter", class = "MAGE",
                 realm = "R", level = 60 }
        AltStable.EnsureSheetVisible()

        -- The probe declines, so the legacy path runs.
        local realPortrait = AltStable.CapturePortrait
        AltStable.CapturePortrait = function() return false end

        AltStable._PlayOpenAnimation(AltStableSheet)
        eq("a fade is running over the sheet", AltStableSheet:GetAlpha(), 0)

        AltStable._test.ClickCaptureButton()
        check("the capture settles the fade before borrowing the alpha",
              AltStable.FinishOpenAnimation() == false,
              "a live fade would climb back to 1 and put the sheet in the photo")
        eq("  and the sheet is hidden for the shot", AltStableSheet:GetAlpha(), 0)

        AltStable.CapturePortrait = realPortrait
        AltStableSheet:SetAlpha(1)
    end

    AltStableConfig.enableOpenAnimation = nil
    AltStableConfig.scale = nil
end

------------------------------------------------------------
-- The menu does not outlive the window that raised it (#69)
------------------------------------------------------------

do
    AltStableDB.keep = AltStableDB.keep
        or { guid = "keep", name = "Keeper", class = "MAGE", realm = "R", level = 60,
             ilvl = 60, money = 100 * GOLD, lastUpdate = 1 }
    AltStable.EnsureSheetVisible()
    AltStable.ShowCharacterMenu(AltStableDB.keep)
    check("a menu is open over the sheet", AltStable._test.MenuIsShown())

    -- Not a stray widget. The menu is FULLSCREEN_DIALOG with a full-screen
    -- click-catcher under it, so one that outlives the sheet is an invisible
    -- sheet of glass over the whole game that eats every click.
    -- Through the real gesture: ShowSheet toggles, and the stub fires OnHide
    -- the way the client does. Calling CloseCharacterMenu directly would
    -- assert the function exists, not that anything calls it.
    AltStable.ShowSheet()
    check("  the sheet did close", AltStableSheet:IsShown() == false)
    check("closing the sheet takes the menu with it",
          AltStable._test.MenuIsShown() == false,
          "a full-screen click-catcher would be left over the game")
    check("  and the catcher is not left parented outside UIParent",
          AltStable._test.MenuRoot():GetParent() == UIParent)
end

------------------------------------------------------------
-- "Show hidden" (#69)
--
-- The toggle changes WHAT THE GRID LISTS and nothing else. The totals and the
-- "(N hidden)" count deliberately still leave hidden characters out, on or off,
-- so switching a view can never change the account's reported gold.
------------------------------------------------------------

do
    AltStableConfig.hiddenCharacters = {}
    AltStable.SetShowingHidden(false)
    footer = build({
        keep = { guid = "keep", name = "Keeper", class = "MAGE", realm = "R", level = 60,
                 ilvl = 60, money = 100 * GOLD, lastUpdate = 1 },
        gone = { guid = "gone", name = "Goner", class = "ROGUE", realm = "R", level = 40,
                 ilvl = 20, money = 50 * GOLD, lastUpdate = 1 },
    })

    eq("nothing is hidden, so there is no toggle to press",
       AltStable._test.HiddenToggleText(), nil)

    AltStable.HideCharacter("gone")
    footer = refresh()
    eq("hiding one puts the toggle on the footer",
       AltStable._test.HiddenToggleText(), "|cff808080(1 hidden)|r")
    eq("  and the grid leaves it out", joined(AltStable._test.DisplayNames()), "Keeper")

    -- The totals BEFORE, so the comparison below is against a measured value
    -- rather than a guess at what they should be.
    local totalsWhileOff = footer

    check("pressing it works", AltStable._test.ClickHiddenToggle())
    eq("  the preference is set", AltStable.IsShowingHidden(), true)
    footer = refresh()
    eq("  and the grid lists the hidden character again",
       joined(AltStable._test.DisplayNames()), "Keeper,Goner")

    -- The half that could quietly lie.
    eq("the totals do NOT change when hidden rows are listed", footer, totalsWhileOff)
    check("  so the gold total still excludes it",
          footer:find("100", 1, true) ~= nil and footer:find("150", 1, true) == nil, footer)
    check("  and the iLvl average too", footer:find("60 avg iLvl", 1, true) ~= nil, footer)
    check("  the label says as much, since the rows are visible",
          (AltStable._test.HiddenToggleText() or ""):find("not counted", 1, true) ~= nil,
          tostring(AltStable._test.HiddenToggleText()))

    -- The row is listed, but marked. Otherwise it is indistinguishable from a
    -- character that was never hidden, and unhiding becomes guesswork.
    do
        local row = AltStable.CreateFrozenRow(WoW.makeFrame(), 18, 100)
        AltStable.RenderFrozenCharRow(row, AltStableDB.gone, 1)
        eq("a hidden row is dimmed", row:GetAlpha(), AltStable._test.HIDDEN_ROW_ALPHA)

        -- Rows come from a POOL. The one that drew the dimmed character draws a
        -- normal one next, and a one-way "dim it if hidden" leaves a perfectly
        -- visible character greyed out for no reason the user can see.
        AltStable.RenderFrozenCharRow(row, AltStableDB.keep, 2)
        eq("  and the next character in that pooled row is not",
           row:GetAlpha(), 1)

        AltStable.RenderFrozenCharRow(row, AltStableDB.gone, 1)
        AltStable.RenderFrozenGroupRow(row, { kind = "group", realm = "R", count = 1 })
        eq("  nor is a realm header drawn in it", row:GetAlpha(), 1)
        AltStable.RenderFrozenCharRow(row, AltStableDB.gone, 1)
        AltStable.RenderFrozenFillerRow(row, 1)
        eq("  nor a filler", row:GetAlpha(), 1)

        -- The scrollable half of the same row, which is a SECOND renderer.
        -- Dimming only the name column would leave a half-faded row.
        local cols = { { key = "level", label = "Level", width = 60 } }
        local wide = AltStable.CreateRow(WoW.makeFrame(), 18, cols)
        AltStable.RenderRow(wide, AltStableDB.gone, 1, cols)
        eq("the scrollable half of a hidden row is dimmed too",
           wide:GetAlpha(), AltStable._test.HIDDEN_ROW_ALPHA)
        AltStable.RenderRow(wide, AltStableDB.keep, 2, cols)
        eq("  and undimmed for the next one", wide:GetAlpha(), 1)
        AltStable.RenderRow(wide, AltStableDB.gone, 1, cols)
        AltStable.RenderFillerRow(wide, 1)
        eq("  and for a filler", wide:GetAlpha(), 1)
        AltStable.RenderRow(wide, AltStableDB.gone, 1, cols)
        AltStable.RenderGroupRow(wide, { kind = "group", realm = "R", count = 1 })
        eq("  and for a group row", wide:GetAlpha(), 1)
    end

    -- Unhide the last hidden character WHILE listing them. The button must not
    -- vanish with the preference still set, or the next character hidden stays
    -- on screen with no control in sight to explain why.
    AltStable.ShowCharacter("gone")
    footer = refresh()
    eq("nothing is hidden any more", AltStable.IsCharacterHidden("gone"), false)
    check("the toggle stays while it is switched on",
          AltStable._test.HiddenToggleText() ~= nil,
          "with none hidden and the toggle on, there would be no way to turn it off")
    check("  reading zero", (AltStable._test.HiddenToggleText() or ""):find("(0 hidden", 1, true) ~= nil,
          tostring(AltStable._test.HiddenToggleText()))

    check("pressing it again turns it off", AltStable._test.ClickHiddenToggle())
    eq("  the preference clears", AltStable.IsShowingHidden(), false)
    footer = refresh()
    eq("  and now it goes away", AltStable._test.HiddenToggleText(), nil)
end

------------------------------------------------------------
-- Forgetting a character, confirmed (#65 via the #69 menu)
--
-- The confirmation that used to guard HIDING now guards forgetting, and it
-- inherits the whole problem that made it worth testing: a StaticPopup raised
-- while the sheet is open is invisible, so the click reads as doing nothing.
-- These checks are on the forget path because that is where the popup went -
-- dropping them with the hide confirmation would have retired the coverage
-- along with the feature, and the bug is still live.
------------------------------------------------------------

do
    AltStableConfig.hiddenCharacters = {}
    build({
        keep = { guid = "keep", name = "Keeper", class = "MAGE", realm = "R", level = 60,
                 ilvl = 60, money = 100 * GOLD, lastUpdate = 1 },
        gone = { guid = "gone", name = "Goner", class = "ROGUE", realm = "R", level = 40,
                 ilvl = 20, money = 50 * GOLD, lastUpdate = 1 },
    })

    WoW.popups = {}
    AltStable.ShowCharacterMenu(AltStableDB.gone)
    AltStable._test.MenuClick("forget")
    eq("choosing Forget raises one confirmation", #WoW.popups, 1)
    check("  and closes the menu first, so it cannot swallow the dialog's click",
          AltStable._test.MenuIsShown() == false)

    local popup = WoW.popups[1]
    if popup then
        check("  naming the character", popup.arg1 == "Goner", tostring(popup.arg1))

        -- The sheet is DIALOG strata and toplevel, and a StaticPopup is DIALOG
        -- too, so this confirmation opened BEHIND the window.
        local dialog = popup.dialog
        check("the popup hands back a frame", dialog ~= nil)
        if dialog then
            eq("it is raised above the sheet", dialog:GetFrameStrata(), "FULLSCREEN_DIALOG")
            check("  and is actually visible", dialog:IsVisible() == true)
            StaticPopup_Hide(popup.which)
            eq("  strata is put back, since the frame is shared with every addon",
               dialog:GetFrameStrata(), "DIALOG")
        end

        -- The case that was broken: the showcase has hidden the whole UI, and a
        -- StaticPopup is a CHILD of UIParent. No strata makes the child of a
        -- hidden parent draw.
        local realHidden = AltStable.IsGameUIHidden
        AltStable.IsGameUIHidden = function() return true end
        UIParent:Hide()

        WoW.popups = {}
        AltStable.ShowCharacterMenu(AltStableDB.gone)
        AltStable._test.MenuClick("forget")
        local hiddenUIPopup = WoW.popups[#WoW.popups]
        check("a confirmation is still raised with the UI hidden", hiddenUIPopup ~= nil)
        if hiddenUIPopup and hiddenUIPopup.dialog then
            local d = hiddenUIPopup.dialog
            check("  it is lifted OUT from under the hidden UIParent",
                  d:GetParent() ~= UIParent, tostring(d:GetParent()))
            check("  so the player can actually see the question", d:IsVisible() == true)
            StaticPopup_Hide(hiddenUIPopup.which)
            eq("  and is parented back on close", d:GetParent(), UIParent)
            eq("  with its strata restored", d:GetFrameStrata(), "DIALOG")
        end

        -- The menu itself has to survive the same thing: it is a frame of ours,
        -- raised while UIParent is hidden.
        AltStable.ShowCharacterMenu(AltStableDB.gone)
        local menuRoot = AltStable._test.MenuRoot()
        check("the menu is lifted out from under the hidden UIParent too",
              menuRoot and menuRoot:GetParent() ~= UIParent, tostring(menuRoot))
        check("  so it can be seen at all", menuRoot and menuRoot:IsVisible() == true)
        AltStable.CloseCharacterMenu()
        eq("  and is parented back when it closes", menuRoot:GetParent(), UIParent)

        UIParent:Show()
        AltStable.IsGameUIHidden = realHidden
    end

    -- Nothing happens until it is accepted.
    WoW.popups = {}
    AltStable.ShowCharacterMenu(AltStableDB.gone)
    AltStable._test.MenuClick("forget")
    popup = WoW.popups[1]
    check("the record survives an unanswered confirmation", AltStableDB.gone ~= nil)

    local dialog = StaticPopupDialogs[popup and popup.which]
    check("the dialog is registered", dialog ~= nil)
    if dialog then
        eq("  its accept button is not a yes/no", dialog.button1, ACCEPT)

        -- The text has to match what the addon can actually do. It used to say
        -- "there is no undo" and that the character "will only reappear by
        -- logging into it" - and BOTH were wrong: /alts unforget lifts the
        -- tombstone, while logging in on another account does not clear THIS
        -- account's, so a player following that sentence leaves the record
        -- rejected for good. The slash command printed the right answer all
        -- along, which is what makes this a contradiction rather than a gap.
        check("  the recovery route it names really exists",
              type(AltStable.UnforgetCharacter) == "function")
        check("  and the dialog names it",
              dialog.text:find("/alts unforget", 1, true) ~= nil, dialog.text)
        check("  without claiming there is no undo",
              dialog.text:find("no undo", 1, true) == nil, dialog.text)
        check("  and without sending the player to log into it instead",
              dialog.text:find("only reappear by logging", 1, true) == nil, dialog.text)
        check("  while still saying it is not instant",
              dialog.text:find("not instantly", 1, true) ~= nil, dialog.text)

        dialog.OnAccept(nil, popup.data)
    end
    eq("accepting forgets the character", AltStableDB.gone, nil)
    check("  and the grid drops the row",
          joined(AltStable._test.DisplayNames()):find("Goner") == nil,
          joined(AltStable._test.DisplayNames()))

    -- Put the world back the way the next section expects to find it: Goner
    -- present and hidden. This block deletes a character, and leaving that
    -- deletion lying around would make the Options restore list below fail for
    -- a reason that has nothing to do with the Options restore list.
    build({
        keep = { guid = "keep", name = "Keeper", class = "MAGE", realm = "R", level = 60,
                 ilvl = 60, money = 100 * GOLD, lastUpdate = 1 },
        gone = { guid = "gone", name = "Goner", class = "ROGUE", realm = "R", level = 40,
                 ilvl = 20, money = 50 * GOLD, lastUpdate = 1 },
    })
    AltStable.SetCharacterHidden("gone", true)
    AltStable.RefreshSheet()
end

------------------------------------------------------------
-- The restore list in Options
------------------------------------------------------------

check("Options exposes a hidden list", type(AltStable._test.OptionsHiddenList) == "function")
if AltStable._test.OptionsHiddenList then
    AltStable.RefreshOptionsHiddenList()
    local rows, note = AltStable._test.OptionsHiddenList()
    eq("the hidden character is listed once", #rows, 1)
    check("  by name", (rows[1] or ""):find("Goner", 1, true) ~= nil, tostring(rows[1]))
    eq("  and no empty-list note is left behind", note, "")

    AltStable.ShowCharacter("gone")
    eq("restoring it unhides the character", AltStable.IsCharacterHidden("gone"), false)
    rows, note = AltStable._test.OptionsHiddenList()
    eq("  the list empties", #rows, 0)
    eq("  and says so", note, "Nothing is hidden.")
    footer = refresh()
    if footer then
        check("  the footer marker goes away", footer:find("hidden", 1, true) == nil, footer)
        check("  and the row is back", joined(AltStable._test.DisplayNames()) == "Keeper,Goner",
              joined(AltStable._test.DisplayNames()))
    end
end

-- More hidden characters than rows: say so rather than pretend the list is
-- complete.
local many = {}
for i = 1, 8 do
    many["g" .. i] = { guid = "g" .. i, name = "Alt" .. i, class = "MAGE", realm = "R",
                       level = 10, money = 0, lastUpdate = 1 }
end
build(many)
for i = 1, 8 do AltStable.SetCharacterHidden("g" .. i, true) end
AltStable.RefreshOptionsHiddenList()
local rows, note = AltStable._test.OptionsHiddenList()
eq("the list shows a full page", #rows, 6)
check("  and counts the rest", (note or ""):find("2 more", 1, true) ~= nil, tostring(note))
footer = refresh()
if footer then
    check("  leaving an empty grid, not an error", #AltStable._test.DisplayNames() == 0)
end
check("every character can be hidden",
      (AltStable._test.HiddenToggleText() or ""):find("(8 hidden)", 1, true) ~= nil,
      tostring(AltStable._test.HiddenToggleText()))

------------------------------------------------------------
-- Keyed by guid, because names are not unique
------------------------------------------------------------
-- Every Forever character has a surname, and two characters can share a first
-- name across realms or accounts. Hiding one must not hide the other.

AltStableConfig.hiddenCharacters = {}
build({
    t1 = { guid = "t1", name = "Twin", class = "MAGE", realm = "R", level = 20,
           money = 0, lastUpdate = 1 },
    t2 = { guid = "t2", name = "Twin", class = "ROGUE", realm = "R", level = 20,
           money = 0, lastUpdate = 1 },
})
AltStable.SetCharacterHidden("t1", true)
refresh()
eq("hiding one namesake leaves the other", joined(AltStable._test.DisplayNames()), "Twin")
eq("  by guid", AltStable.IsCharacterHidden("t2"), false)

------------------------------------------------------------
-- A hidden character with no record yet
------------------------------------------------------------
-- /alts cleanup wipes the store and re-pulls it. The entry is kept so the
-- character comes back hidden, but it is not listed as a row it cannot fill.

AltStableConfig.hiddenCharacters = {}
build({
    here = { guid = "here", name = "Here", class = "MAGE", realm = "R", level = 20,
             money = 0, lastUpdate = 1 },
})
AltStable.SetCharacterHidden("vanished", true)
local list = AltStable.HiddenCharacterList()
eq("a hidden guid with no record is not listed", #list, 0)
eq("  but stays hidden for when it syncs back", AltStable.IsCharacterHidden("vanished"), true)

-- ...and when it does syncs back with Options already open, the restore list
-- has to notice. Its OnShow does not fire again while the panel stays open, so
-- without this the character is unrestorable until the user leaves Options and
-- comes back.
AltStable.RefreshOptionsHiddenList()
eq("the restore list starts empty", #(select(1, AltStable._test.OptionsHiddenList())), 0)
AltStableDB.vanished = { guid = "vanished", name = "Returned", class = "WARRIOR",
                         realm = "R", level = 30, money = 0, lastUpdate = 1 }
AltStable.RefreshSheet()
local backRows = AltStable._test.OptionsHiddenList()
eq("a record arriving for a hidden character reaches the restore list", #backRows, 1)
check("  by name", (backRows[1] or ""):find("Returned", 1, true) ~= nil, tostring(backRows[1]))
eq("  and it is still hidden from the grid", joined(AltStable._test.DisplayNames()), "Here")

------------------------------------------------------------
-- The row wiring
------------------------------------------------------------

WoW.popups = {}
local row = AltStable.CreateFrozenRow(WoW.makeFrame(), 18, 100)
AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
local onClick = row.nameTipBtn:GetScript("OnClick")
check("the name row handles clicks", type(onClick) == "function")

-- The registration, not just the handler.
--
-- A Button fires OnClick for the LEFT button only until RegisterForClicks says
-- otherwise. Every check below calls the handler directly with "RightButton",
-- which the client would never do on an unregistered button - so without this
-- one assertion the whole section can pass against a menu that cannot be
-- opened in game.
check("the row listens for right-clicks at all",
      row.nameTipBtn:HandlesClick("RightButton"),
      table.concat(row.nameTipBtn:RegisteredClicks(), ","))

if onClick then
    AltStable.CloseCharacterMenu()
    onClick(row.nameTipBtn, "LeftButton")
    check("a left-click opens no menu", AltStable._test.MenuIsShown() == false)

    onClick(row.nameTipBtn, "RightButton")
    check("a right-click opens the menu", AltStable._test.MenuIsShown())
    check("  about the character under the cursor",
          table.concat(AltStable._test.MenuLabels(), "|"):find("Here", 1, true) ~= nil,
          table.concat(AltStable._test.MenuLabels(), "|"))
    eq("  and still asks nothing", #WoW.popups, 0)

    -- A recycled row carries no character. Group rows and fillers go through
    -- the same pool, and a right-click there must not offer to act on whatever
    -- was drawn in that row last.
    AltStable.CloseCharacterMenu()
    AltStable.HideFrozenRow(row)
    onClick(row.nameTipBtn, "RightButton")
    check("a right-click on an empty row opens nothing",
          AltStable._test.MenuIsShown() == false)

    -- The realm header is the one that actually happens: collapse a realm and
    -- the row that drew a character now draws its header, at the same index.
    AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
    AltStable.RenderFrozenGroupRow(row, { kind = "group", realm = "R", count = 1 })
    onClick(row.nameTipBtn, "RightButton")
    check("a right-click on a realm header opens nothing",
          AltStable._test.MenuIsShown() == false)

    WoW.tooltipLines = {}
    row.nameTipBtn:GetScript("OnEnter")()
    eq("  and it shows no leftover tooltip", #WoW.tooltipLines, 0)

    -- Same for a filler row.
    AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
    AltStable.RenderFrozenFillerRow(row, 1)
    onClick(row.nameTipBtn, "RightButton")
    check("a right-click on a filler row opens nothing",
          AltStable._test.MenuIsShown() == false)
end

-- The same guard, asked directly: the row is not the only caller (the Roster
-- card raises the same menu), so the entry point has to hold it too.
AltStable.CloseCharacterMenu()
local okNil = pcall(AltStable.ShowCharacterMenu, nil)
check("asking for a menu on nothing is not an error", okNil)
AltStable.ShowCharacterMenu({ name = "No guid" })
check("  and opens nothing", AltStable._test.MenuIsShown() == false)

AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
local onEnter = row.nameTipBtn:GetScript("OnEnter")
if onEnter then
    WoW.tooltipLines = {}
    onEnter()
    check("the tooltip says the right-click does more than hide",
          joined(WoW.tooltipLines):find("favourite") ~= nil,
          joined(WoW.tooltipLines))
end

------------------------------------------------------------
-- The account number box
------------------------------------------------------------
-- Reported as "it doesn't persist". It had never been SAVED: the box committed
-- only on Enter, so typing a number and clicking away discarded it silently.
--
-- The first fix over-corrected and introduced a worse bug: committing an EMPTY
-- box on blur wiped a configured number. The box selects all of its text when
-- focused, so backspace-then-click-elsewhere is ordinary - and accountNumber is
-- a sync-scope key, so clearing it forces a full re-send to every peer.

AltStableConfig = {}
AltStableDB = {}
local commit = AltStable._test.CommitAccountNumber
local box = AltStable._test.AccountBox
check("the commit seam exists", type(commit) == "function")

if commit then
    WoW.chatOut = {}
    check("typing a number and clicking away stores it", commit("2", false))
    eq("  really stores it", AltStableConfig.accountNumber, 2)
    check("  and says so", #WoW.chatOut > 0, "nothing printed")

    -- The regression, pinned.
    WoW.chatOut = {}
    eq("blurring an EMPTY box does not clear the setting", commit("", false), false)
    eq("  the value survives", AltStableConfig.accountNumber, 2)
    eq("  and the box is put back", box:GetText(), "2")

    eq("blurring an unparseable box does not clear it either", commit("abc", false), false)
    eq("  the value still survives", AltStableConfig.accountNumber, 2)

    -- Clearing is explicit.
    WoW.chatOut = {}
    commit("", true)
    eq("pressing Enter on an empty box clears it", AltStableConfig.accountNumber, "")
    check("  and says so", #WoW.chatOut > 0)

    -- Validation lives in the shared seam, so the box inherits it.
    commit("2", true)
    eq("a whole number is accepted", AltStableConfig.accountNumber, 2)
    eq("a fraction is refused", commit("2.5", true), false)
    eq("  leaving the value", AltStableConfig.accountNumber, 2)
    eq("a negative is refused", commit("-3", true), false)
    eq("hex is refused", commit("0x10", true), false)
    eq("  still leaving the value", AltStableConfig.accountNumber, 2)

    check("the box commits on Enter", type(box:GetScript("OnEnterPressed")) == "function")
    check("  and on losing focus, which is how a typed value used to vanish",
          type(box:GetScript("OnEditFocusLost")) == "function")
    check("  while Escape reverts", type(box:GetScript("OnEscapePressed")) == "function")

    -- Invoke the handlers themselves: type-checking them let a gutted body pass.
    AltStable.SetAccountNumber("clear")
    box:SetText("4")
    box:GetScript("OnEnterPressed")(box)
    eq("the Enter handler actually commits", AltStableConfig.accountNumber, 4)

    box:SetText("5")
    box:GetScript("OnEditFocusLost")(box)
    eq("the focus-lost handler actually commits", AltStableConfig.accountNumber, 5)

    box:SetText("9")
    box:GetScript("OnEscapePressed")(box)
    eq("the Escape handler reverts instead", AltStableConfig.accountNumber, 5)
    eq("  and puts the stored value back in the box", box:GetText(), "5")

    -- A change from chat must not leave a stale number in an open box, or
    -- blurring it commits the old value straight back over the new one.
    AltStable.SetAccountNumber("6")
    eq("a change elsewhere refreshes the box", box:GetText(), "6")
end

------------------------------------------------------------
-- The camera presentation must beat CameraKeepCharacterCentered (#25)
------------------------------------------------------------
-- The offset was written and then quietly cancelled: an 11.0.x client - which
-- this codebase is - added CameraKeepCharacterCentered, which re-centres the
-- character regardless. So the source looked right and the screen did not.
-- DialogueUI, which works on Forever, sets the same pair and comments them
-- "11.0.2 Fix".
--
-- The other half is putting them back. A presentation that leaves a player's
-- camera CVars changed after the window closes is worse than one that never
-- moved the camera.

local Cam = AltStable._test.CameraPresentation
check("the presentation is reachable", Cam ~= nil)

if Cam then
    local CENTRING = AltStable._test.CENTRING_CVARS
    check("the centring CVars are named", type(CENTRING) == "table" and #CENTRING >= 1)

    -- The key _GetConfig actually reads. An earlier version set
    -- `worldCameraPresentation`, which nothing reads at all: the block passed
    -- only because the feature defaults to on, and would have failed with a
    -- confusing "Enter() did not activate" the moment that default changed.
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.enableWorldCameraPresentation = true

    -- The player's own settings, as they were before we touched anything.
    WoW.cvars["CameraKeepCharacterCentered"] = "1"
    WoW.cvars["CameraReduceUnexpectedMovement"] = "1"
    WoW.cvars["test_cameraOverShoulder"] = "0"
    WoW.cvars["cameraDistanceMaxZoomFactor"] = "1.0"

    Cam.active = false
    local entered = pcall(Cam.Enter, Cam)
    check("entering does not error", entered)

    if entered and Cam.active then
        eq("the character stops being centred", WoW.cvars["CameraKeepCharacterCentered"], "0")
        eq("  and the movement damping is off", WoW.cvars["CameraReduceUnexpectedMovement"], "0")
        check("  while the shoulder offset is still written",
              tonumber(WoW.cvars["test_cameraOverShoulder"]) ~= 0,
              tostring(WoW.cvars["test_cameraOverShoulder"]))

        pcall(Cam.ForceRestore, Cam, "test")
        eq("leaving puts centring back exactly as found",
           WoW.cvars["CameraKeepCharacterCentered"], "1")
        eq("  and the damping", WoW.cvars["CameraReduceUnexpectedMovement"], "1")
        eq("  and the shoulder offset", tonumber(WoW.cvars["test_cameraOverShoulder"]), 0)
    else
        check("the presentation entered", false, "Enter() did not activate")
    end

    -- A CVar this client does not have must not be INVENTED - on the way in or
    -- the way out. Asserting Cam.active matters: without it an Enter() that
    -- threw or bailed early would leave the CVar absent and this would pass for
    -- the wrong reason, proving nothing about the guard.
    WoW.cvars["CameraKeepCharacterCentered"] = nil
    WoW.cvars["CameraReduceUnexpectedMovement"] = nil
    Cam.active = false
    local ok2 = pcall(Cam.Enter, Cam)
    check("it still enters on a client without those CVars", ok2 and Cam.active == true)
    eq("  and does not create the one it lacks",
       WoW.cvars["CameraKeepCharacterCentered"], nil)
    eq("  nor the other", WoW.cvars["CameraReduceUnexpectedMovement"], nil)
    pcall(Cam.ForceRestore, Cam, "test")
    eq("  nor invent one on the way out",
       WoW.cvars["CameraKeepCharacterCentered"], nil)

    -- Reopening the sheet DURING the exit animation must cancel the pending
    -- restore. Otherwise it fires with the sheet open and re-centres the
    -- character - the very bug this feature exists to prevent, arriving half a
    -- second late.
    WoW.cvars["CameraKeepCharacterCentered"] = "1"
    Cam.active = false
    pcall(Cam.Enter, Cam)
    eq("centring is off while shown", WoW.cvars["CameraKeepCharacterCentered"], "0")
    pcall(Cam.Exit, Cam, "test")
    pcall(Cam.Enter, Cam)                       -- reopened mid-exit
    eq("re-entering during the exit animation restarts the presentation",
       Cam.mode, "enter")
    eq("  and leaves centring off", WoW.cvars["CameraKeepCharacterCentered"], "0")
    -- Exit() had already put the saved view back and stopped the yaw, so merely
    -- flipping the mode would leave a sheet open with no showcase at all. The
    -- entry must be a REAL one: SetView(2) is the first thing Enter does.
    eq("  and really re-enters, rather than resuming a half-undone one",
       WoW.camera.view, 2)
    check("  with a fresh capture to restore from", Cam.capture ~= nil)
    pcall(Cam.ForceRestore, Cam, "test")

    AltStableConfig.enableWorldCameraPresentation = nil
    WoW.reset()
end

------------------------------------------------------------
-- The addon's icon
------------------------------------------------------------
-- The group-of-figures art from the client's Who tab, found with the probe's
-- /asicon. The client gave no path for it - the tab is the `common-sidetab`
-- atlas and the art inside is set by FILE ID with no atlas and no filename - so
-- an id is the only thing there is to write.
--
-- Measured on 1.60.1.70009 (see docs/forever-api-notes.md): SetTexture with a
-- nonsense file id echoes it straight back from both getters. A file id is
-- stored, not resolved, so no check on the texture can tell you the art is
-- missing. An earlier version had a fallback behind exactly such a check: it
-- could never fire, and it claimed the case was handled.
--
-- The fallback is DRAWN instead. The old icon sits on a lower layer with the
-- file id over it, so if the id ever stops resolving - which the same
-- measurement says draws nothing - the layer beneath shows through.

do
    local T = AltStable._test

    -- The title band, through the BUILT sheet rather than the helper. The helper
    -- has its own tests in test_glass; what those cannot say is whether SheetUI
    -- actually calls it, and the title bar was listed as a corner owner in the
    -- plan and then not wired at all.
    do
        local bg = T.titleBarBG
        check("the title bar is restyled when the sheet is built", bg ~= nil)
        if bg then
            local c = bg._colorTexture
            check("  painted light rather than the old opaque dark",
                  c and c[1] > 0.5, tostring(c and c[1]))
            check("  and graded", bg._gradient ~= nil)
            -- The corner fix: it spans (0, 0) to the top corners, so without a
            -- mask it draws them square.
            check("  and clipped, so it stops squaring the top corners",
                  bg:GetNumMaskTextures() > 0)
        end
        -- The nav buttons as SwitchSection left them: exactly one selected, in
        -- the accent colour, and the rest showing nothing.
        local btns = T.sidebarBtns or {}
        check("the sidebar has buttons", #btns > 1, tostring(#btns))
        local lit, litBtn = 0, nil
        for _, b in ipairs(btns) do
            if b._skinState and b._skinState:IsShown() then
                lit = lit + 1; litBtn = b
            end
        end
        eq("exactly one nav button is selected", lit, 1)
        if litBtn then
            local accent = { AltStable.GetAccentRGB() }
            local c = litBtn._skinState._colorTexture
            check("  and it is painted in the accent colour",
                  c and c[1] == accent[1], tostring(c and c[1]))
        end
        -- And an unselected label is the brighter glass value, not the 0.50
        -- that reads as disabled over a translucent panel.
        for _, b in ipairs(btns) do
            if b ~= litBtn and b.lbl then
                local lr = b.lbl:GetTextColor()
                check("  unselected labels are not the disabled-looking dim",
                      lr and lr > AltStable.C.TEXT_DIM[1], tostring(lr))
                break
            end
        end

        -- The reference tooltip's CALL SITE. Replacing it with `if true then` -
        -- shipping the old flat backdrop and no material - left every suite
        -- green, which is how the PR came to claim coverage it did not have.
        do
            local tip = T.refTip
            check("the reference tooltip is built", tip ~= nil)
            if tip then
                check("  and wears the material", tip._glass ~= nil)
                if tip._glass and tip._glass.top then
                    -- It raises itself on hover, and the rim is a CHILD pinned
                    -- at Apply time - so without re-levelling the tooltip climbs
                    -- above its own outline and draws its body over it.
                    -- Driven through the REAL hover handler, not by calling the
                    -- helper: the bug was that the hover raised the tooltip and
                    -- did not re-level the rim, so a test that calls
                    -- SkinRelevel itself proves only that the helper works.
                    local before = tip._glass.top:GetFrameLevel()
                    tip:SetFrameLevel((tip:GetFrameLevel() or 0) + 50)
                    local onEnter = T.refBtn and T.refBtn:GetScript("OnEnter")
                    check("the reference button has a hover handler", onEnter ~= nil)
                    if onEnter then onEnter(T.refBtn) end
                    check("  and its rim follows when the tooltip is raised",
                          tip._glass.top:GetFrameLevel() > before,
                          ("%s -> %s"):format(tostring(before),
                              tostring(tip._glass.top:GetFrameLevel())))
                    check("    staying above it",
                          tip._glass.top:GetFrameLevel() > tip:GetFrameLevel())
                end
            end
            local txt = T.refTipText
            check("the reference tooltip's text is reachable", txt ~= nil)
            if txt then
                local sx, sy = txt:GetShadowOffset()
                check("  and has a shadow", sx ~= 0 or sy ~= 0,
                      ("%s,%s"):format(tostring(sx), tostring(sy)))
            end
        end

        -- The SHEET's own capture path closes the menu. The fix first went into
        -- the probe's SuppressStrays, which is the wrong altitude twice over:
        -- the probe is a dev-only addon that may not be installed, and an
        -- alpha-0 sheet still takes the mouse - so a right-click during the
        -- settle opened a menu that landed in the portrait and left a
        -- full-screen catcher eating every click.
        do
            -- A character record, or the capture bails before the blackout it
            -- is being tested for and the assertion passes on a path that never
            -- ran.
            local savedDB = AltStableDB
            AltStableDB = { [UnitGUID("player")] = {
                guid = UnitGUID("player"), name = "Me", class = "MAGE",
                realm = "R", level = 1 } }
            local closed = 0
            local realClose = AltStable.CloseCharacterMenu
            AltStable.CloseCharacterMenu = function() closed = closed + 1 end
            if T.CaptureReferenceFromSheet then
                pcall(T.CaptureReferenceFromSheet)
            end
            AltStable.CloseCharacterMenu = realClose
            AltStableDB = savedDB
            check("the sheet's own capture closes the character menu first",
                  closed > 0, tostring(closed))
        end

        local tt = T.titleText
        if tt then
            local tr, tg, tb = tt:GetTextColor()
            check("the title is white, not competing with the accent selection",
                  tr == tg and tg == tb and tr > 0.9,
                  ("%s,%s,%s"):format(tostring(tr), tostring(tg), tostring(tb)))
        end
        check("the title text has a shadow over the glass", tt ~= nil)
        if tt then
            local x, y = tt:GetShadowOffset()
            check("  a real one", x ~= 0 or y ~= 0,
                  ("%s,%s"):format(tostring(x), tostring(y)))
        end
    end

    ------------------------------------------------------------
    -- The window fits the display (#99)
    ------------------------------------------------------------
    -- Options is the only section that asks for a FIXED size rather than
    -- sizing to its content - ResizeFrame(820, 760) - and nothing clamped it,
    -- so on a shorter display, or at scale 1.25 where 760 is an effective 950,
    -- the bottom of the window ran off the screen and took the last options
    -- with it. The scroll frame inside cannot help: what is off-screen is the
    -- window, not the content.
    do
        local f = T.frame
        check("the sheet frame is reachable", f ~= nil)
        local screenH = UIParent:GetHeight()
        check("the stubs model a display-sized UIParent", screenH > 500,
              tostring(screenH))

        -- 600, not 760. On a default 1080p UI the screen is 768 units at an
        -- effective scale of ~1.4, so the limit is ~728 - and the Options tab's
        -- fixed 760 is ABOVE it. That is not a quirk of the fixture, it is the
        -- reported bug: at default scale that tab asks for more height than the
        -- display has, before any scaling makes it worse.
        local w, h = T.FitToScreen(820, 600)
        eq("a window that fits is left alone", w, 820)
        eq("  in both directions", h, 600)

        -- The reported case, stated as itself.
        local _, opts = T.FitToScreen(820, 760)
        check("the Options tab's fixed 760 does not fit a default 1080p UI",
              opts < 760, tostring(opts))

        local _, tall = T.FitToScreen(820, 5000)
        check("a window taller than the display is clamped", tall < 5000)
        check("  to inside it, with a margin", tall <= screenH - T.SCREEN_MARGIN,
              ("%s vs %s"):format(tostring(tall), tostring(screenH)))

        local wide = T.FitToScreen(9000, 760)
        check("and the same for width", wide <= UIParent:GetWidth() - T.SCREEN_MARGIN)

        -- SCALE. The frame carries the user's scale and UIParent the client's,
        -- so the two heights are numbers in different spaces - comparing them
        -- raw is wrong by exactly the ratio nobody notices at 1.0, which is the
        -- scale everything gets tested at.
        -- GetScale, not GetEffectiveScale. Restoring an EFFECTIVE scale as if
        -- it were a scale multiplies the parent's in a second time and leaves
        -- the frame at the wrong size for everything downstream - which is only
        -- invisible while UIParent's scale is 1.
        local prev = f:GetScale()
        f:SetScale(1.25)
        local _, scaled = T.FitToScreen(820, 5000)
        f:SetScale(prev)
        local _, unscaled = T.FitToScreen(820, 5000)
        check("a scaled-up window is clamped sooner, in its own units",
              scaled < unscaled,
              ("1.25 gives %s, 1.0 gives %s"):format(tostring(scaled), tostring(unscaled)))

        -- A floor, or a bad read during load leaves a window with no room for
        -- anything and no way to get it back.
        local savedH = UIParent:GetHeight()
        UIParent:SetHeight(10)
        local _, floored = T.FitToScreen(820, 760)
        UIParent:SetHeight(savedH)
        eq("an implausible screen does not shrink the window to nothing", floored, 760)

        -- Fitting is not the same as being ON the display: the position is
        -- remembered, and growing taller moves the bottom down while the saved
        -- anchor holds the top still.
        check("the window is kept on the screen", f:IsClampedToScreen())

        -- Through the real resize, not just the helper. This is the half that
        -- was missing: FitToScreen had eight assertions and the two lines that
        -- call it had none, so removing them changed nothing the suite saw.
        local maxH = (UIParent:GetHeight() * UIParent:GetEffectiveScale())
                     / (f:GetEffectiveScale() or 1) - T.SCREEN_MARGIN
        T.ResizeFrame(820, 5000)
        check("asking the window for more height than the display has is refused",
              f:GetHeight() <= maxH,
              ("%s vs max %s"):format(tostring(f:GetHeight()), tostring(maxH)))
        T.ResizeFrame(9000, 760)
        check("  and more width", f:GetWidth() <= (UIParent:GetWidth()
              * UIParent:GetEffectiveScale()) / (f:GetEffectiveScale() or 1)
              - T.SCREEN_MARGIN)
        -- And a reasonable request still goes through untouched, or "clamped"
        -- would be satisfied by a window that is always the same size.
        T.ResizeFrame(820, 600)
        eq("a window that fits is sized exactly as asked", f:GetHeight(), 600)

        -- SCALING is a third way to stop fitting, and it goes through neither
        -- resize path: the numbers stay the same and the display they occupy
        -- changes. Driven through the real AltStable.SetScale rather than by
        -- setting the scale and calling the clamp by hand, because the bug was
        -- precisely that SetScale did not call it.
        do
            local savedH = UIParent:GetHeight()
            -- GetScale, not GetEffectiveScale: restoring an effective scale as
            -- if it were a scale multiplies the parent's in a second time.
            local savedScale = f:GetScale()
            UIParent:SetHeight(900)
            T.ResizeFrame(820, 760)
            eq("a window that fits at scale 1 is left alone", f:GetHeight(), 760)
            AltStable.SetScale(1.25)
            local lim = (900 * UIParent:GetEffectiveScale())
                        / (f:GetEffectiveScale() or 1) - T.SCREEN_MARGIN
            check("and scaling it up refits it rather than leaving it oversized",
                  f:GetHeight() <= lim,
                  ("%s vs max %s"):format(tostring(f:GetHeight()), tostring(lim)))
            -- And BACK. FitToScreen only ever reduces, so refitting against the
            -- current size is a one-way ratchet: scaling up shrinks the window,
            -- scaling back down sees something that already fits and does
            -- nothing, and it stays short for ever. On the Options tab - the one
            -- place the scale slider lives, and a plugin section, so
            -- sizing-to-content early-outs - there is no way back at all.
            AltStable.SetScale(1.0)
            eq("and scaling back down restores the size that was asked for",
               f:GetHeight(), 760)

            -- And the CONTENT path remembers its own request too. Without that,
            -- a refit after sizing-to-content restores whatever the last
            -- explicit ResizeFrame asked for - a stale number from another tab.
            T.ResizeFrameToContent()
            local contentH = f:GetHeight()
            AltStable.SetScale(1.25)
            AltStable.SetScale(1.0)
            eq("a content-sized window comes back to its own size, not another tab's",
               f:GetHeight(), contentH)

            AltStable.SetScale(savedScale)
            UIParent:SetHeight(savedH)
        end

        -- The OTHER path. ResizeFrameToContent sets the size directly rather
        -- than going through ResizeFrame, so it needed the clamp of its own.
        -- Exercised on WIDTH, because height has a floor it cannot go below -
        -- see just after.
        if T.ResizeFrameToContent then
            local savedW = UIParent:GetWidth()
            UIParent:SetWidth(400)
            T.ResizeFrameToContent()
            local lim = (400 * UIParent:GetEffectiveScale())
                        / (f:GetEffectiveScale() or 1) - T.SCREEN_MARGIN
            -- EQUAL to the limit, not merely under it. A one-sided check
            -- passes for any mutation that clamps too hard, and one that drops
            -- the scale conversion does exactly that.
            check("sizing to content is clamped to the display too",
                  math.abs(f:GetWidth() - lim) < 1,
                  ("%s vs max %s"):format(tostring(f:GetWidth()), tostring(lim)))
            UIParent:SetWidth(savedW)
        else
            check("the content-sizing path is reachable from a test", false)
        end

        -- LIFTED OUT of UIParent, which is what the capture pipeline does.
        --
        -- This is the only case where the UIParent factor in the conversion
        -- does any work: for an ordinary child, `fs` already contains `us` and
        -- the two cancel. Reparented, they do not - and dropping the factor
        -- would then size the window against a screen measured in the wrong
        -- units. A mutation removing it survives every other assertion here.
        do
            local savedParent = f:GetParent()
            f:SetParent(WorldFrame or UIParent)
            local us = UIParent:GetEffectiveScale()
            local fs = f:GetEffectiveScale()
            local lim = (UIParent:GetHeight() * us) / fs - T.SCREEN_MARGIN
            local _, got = T.FitToScreen(820, 99999)
            check("a window lifted out of UIParent is still measured against the screen",
                  math.abs(got - lim) < 1,
                  ("%s vs %s"):format(tostring(got), tostring(lim)))
            check("  which is a different limit from the parented case",
                  math.abs(fs - us) > 0.01,
                  ("frame %s vs UIParent %s"):format(tostring(fs), tostring(us)))
            f:SetParent(savedParent)
        end

        -- The HEIGHT floor, which is the sidebar's own requirement rather than
        -- an arbitrary number.
        --
        -- ComputeContentSize raises the height so the last nav button clears the
        -- totals bar, and the sidebar has no scroll of its own - so clamping
        -- below that trades "the window is off-screen" for "half the navigation
        -- is off-screen", which is not a fix. Below the floor the honest answer
        -- is that the display cannot show this window, and an overflowing window
        -- beats one with no way to reach Options and turn the scale down.
        do
            local savedH2 = UIParent:GetHeight()
            UIParent:SetHeight(250)
            T.ResizeFrameToContent()
            local tooSmall = (250 * UIParent:GetEffectiveScale())
                             / (f:GetEffectiveScale() or 1) - T.SCREEN_MARGIN
            check("a display too short for the sidebar is not clamped into it",
                  f:GetHeight() > tooSmall,
                  ("%s vs the would-be limit %s"):format(
                      tostring(f:GetHeight()), tostring(tooSmall)))
            UIParent:SetHeight(savedH2)
        end
    end
    local btn = CreateFrame("Frame")
    local over, under = T.ApplyRosterIcon(btn)

    eq("the Who tab's icon is drawn", over:GetTextureFileID(), T.ROSTER_ICON_FILE_ID)
    eq("  and the old icon underneath it", under:GetTexture(), T.ROSTER_ICON_UNDERLAY)

    -- Order matters: BACKGROUND is beneath ARTWORK. The wrong way round and the
    -- old icon covers the new one on every client that HAS the file.
    eq("the old icon is on the lower layer", under:GetDrawLayer(), "BACKGROUND")
    eq("  and the new one above it", over:GetDrawLayer(), "ARTWORK")

    -- The Who tab art is not trimmed; the icon beneath it is.
    check("the Who tab art is drawn whole",
          over._texCoord and over._texCoord[1] == 0 and over._texCoord[2] == 1,
          tostring(over._texCoord and over._texCoord[1]))
    check("  while the Icons file under it is trimmed, as such art needs",
          under._texCoord and under._texCoord[1] > 0,
          tostring(under._texCoord and under._texCoord[1]))

    -- The measurement itself, pinned: if a future client ever DOES reject a bad
    -- id, this fails and a check becomes worth writing again.
    local bogus = CreateFrame("Frame"):CreateTexture()
    bogus:SetTexture(999999999)
    eq("a file id the client does not have is echoed back, not rejected",
       bogus:GetTextureFileID(), 999999999)

    check("nothing to draw on is not a crash", T.ApplyRosterIcon(nil) == nil)
end

------------------------------------------------------------
-- Which row a right-click will act on
------------------------------------------------------------
-- The menu opens UNDER THE CURSOR, so the moment it appears the pointer is
-- over the menu and not over the row it belongs to. A hover highlight goes out
-- exactly when you need to know which character you are about to forget.

do
    local T = AltStable._test
    check("the renderer takes a menu subject", T.SetMenuSubject ~= nil)

    if T.SetMenuSubject then
        T.SetMenuSubject("Player-1-AAAA")
        eq("the subject is remembered", T.MarkedGuid(), "Player-1-AAAA")

        -- A GUID, not a row. Rows come from a POOL and are re-rendered by
        -- index, so the row that held a character when the menu opened can be
        -- showing somebody else by the time it closes - marking the row object
        -- would light the wrong name.
        T.SetMenuSubject(nil)
        eq("and closing the menu clears it", T.MarkedGuid(), nil)
    end

    -- The PAINTING, not just the state. The mark is what the player sees, and
    -- asserting the remembered guid says nothing about whether a texture
    -- lit - a mutation that never showed it passed all of the above.
    do
        -- BOTH halves of a row. The name is in the frozen column and the data
        -- in the scrollable one; they are separate frames, and a highlight on
        -- one of them lights half a row. The first attempt put the mark on one
        -- and the registration on the other, and this test skipped silently
        -- because of its own `and row.nameTipBtn` guard.
        local scroll = AltStable.CreateRow(UIParent, 18, {})
        local frozen = AltStable.CreateFrozenRow(UIParent, 18, 120)
        check("the scrollable half has a mark", scroll.mark ~= nil)
        check("the frozen half has one too", frozen.mark ~= nil)
        check("and the frozen half owns the right-click button",
              frozen.nameTipBtn ~= nil)

        local row = frozen
        if true then
            scroll.markGuid = "Player-1-CCCC"
            frozen.markGuid = "Player-1-CCCC"
            row.nameTipBtn.charData = { guid = "Player-1-CCCC", name = "C", class = "MAGE" }

            T.SetMenuSubject("Player-1-CCCC")
            check("the subject's row lights up", row.mark:IsShown())
            check("  and so does its other half", scroll.mark:IsShown())
            local c = row.mark._colorTexture
            check("  at the menu strength",
                  c and math.abs(c[4] - T.MARK_MENU) < 0.001, tostring(c and c[4]))

            -- Brighter than hover, or the two states are one state: the menu
            -- mark has to survive the pointer moving onto the menu.
            check("  which is brighter than hover", T.MARK_MENU > T.MARK_HOVER,
                  ("%s vs %s"):format(tostring(T.MARK_MENU), tostring(T.MARK_HOVER)))

            -- Somebody else's menu does not light this row.
            T.SetMenuSubject("Player-1-DDDD")
            check("another character's menu leaves it dark", not row.mark:IsShown())

            T.SetMenuSubject(nil)
            check("  and closing clears it", not row.mark:IsShown())

            -- Hover, through the real handler.
            row.nameTipBtn:GetScript("OnEnter")(row.nameTipBtn)
            check("hovering the name lights the row", row.mark:IsShown())
            local h = row.mark._colorTexture
            check("  at the fainter hover strength",
                  h and math.abs(h[4] - T.MARK_HOVER) < 0.001, tostring(h and h[4]))
            row.nameTipBtn:GetScript("OnLeave")(row.nameTipBtn)
            check("  and leaving puts it out", not row.mark:IsShown())
        end
    end

    -- Through the real menu, not just the setter: opening marks, closing
    -- unmarks, and a menu that never opens marks nothing.
    if AltStable.ShowCharacterMenu then
        local char = { guid = "Player-1-BBBB", name = "Somebody", class = "MAGE" }
        AltStable.ShowCharacterMenu(char)
        eq("opening the menu marks its character", T.MarkedGuid(), "Player-1-BBBB")
        AltStable.CloseCharacterMenu()
        eq("  and closing it unmarks", T.MarkedGuid(), nil)

        -- An entryless menu never opens, so it must not leave a row lit with
        -- nothing on screen to explain it.
        local realEntries = AltStable.CharacterMenuEntries
        AltStable.CharacterMenuEntries = function() return {} end
        AltStable.ShowCharacterMenu(char)
        eq("a menu that never opens marks nothing", T.MarkedGuid(), nil)
        AltStable.CharacterMenuEntries = realEntries
    end
end

------------------------------------------------------------
-- The account label on a group header
------------------------------------------------------------
-- It read "(Account: Default)" on every group for everybody, because the group
-- item never carried an account at all: `item.account` was nil and "Default"
-- was the fallback for nil, not a value anybody had.

do
    local T = AltStable._test
    check("the account collection is reachable", T.CollectAccounts ~= nil)

    local function acc(...)
        local chars = {}
        for _, a in ipairs({ ... }) do chars[#chars + 1] = { account = a } end
        return T.CollectAccounts(chars)
    end

    eq("no accounts at all gives an empty list", #acc(), 0)
    eq("  as does a character that never got one", #acc(nil), 0)
    eq("  or an empty string, which is what the scanner writes when unset",
       #acc(""), 0)

    -- A SET: the same account on nine characters is one account, not nine.
    eq("one account on many characters is one account", #acc(1, 1, 1), 1)

    -- Two accounts on one realm is the entire point of the sync feature, and
    -- the only case where naming them distinguishes anything.
    local two = acc(2, 1, 2)
    eq("two accounts are both listed", #two, 2)
    eq("  in a stable order", two[1] .. "," .. two[2], "1,2")

    -- Numbers and strings are the same account: the scanner writes
    -- AltStableConfig.accountNumber, and a profile edited by hand can hold
    -- either.
    eq("1 and \"1\" are one account", #acc(1, "1"), 1)

    -- The RENDERING, on a real row rather than a bare frame.
    local grow = AltStable.CreateRow(UIParent, 18, {})
    AltStable.RenderGroupRow(grow, { kind = "group", realm = "R", count = 2,
                                     accounts = { "1" }, sumLevel = 2, sumGold = 0 })
    check("a single-account group shows no account label",
          grow.groupLabel and not grow.groupLabel:IsShown())
    AltStable.RenderGroupRow(grow, { kind = "group", realm = "R", count = 2,
                                     accounts = { "1", "2" }, sumLevel = 2, sumGold = 0 })
    check("  while a mixed one names them", grow.groupLabel:IsShown())
    local txt = grow.groupLabel:GetText() or ""
    -- It read "(Account: Default)" on every group for everybody, because the
    -- item never carried an account and "Default" was the fallback for nil.
    check("  and never says Default", txt:find("Default", 1, true) == nil, txt)
    check("  listing the accounts it found",
          txt:find("1", 1, true) and txt:find("2", 1, true), txt)
end

------------------------------------------------------------
-- The row tooltip opens beside the window, not on it
------------------------------------------------------------
-- ANCHOR_RIGHT put it immediately right of the NAME cell - the leftmost column
-- - so it covered the table it describes, and for rows near the top it covered
-- the column headers and the title bar as well.

do
    local T = AltStable._test
    local frozen = AltStable.CreateFrozenRow(UIParent, 18, 120)
    local btn = frozen.nameTipBtn
    check("the frozen row has a name button", btn ~= nil)
    if btn then
        btn.charData = { guid = "g", name = "N", class = "MAGE", money = 1 }
        btn:GetScript("OnEnter")(btn)

        -- The owner is recorded too: "which widget is this tooltip about" is
        -- what the client uses to close it, and the stub answered it with the
        -- tooltip itself until this test needed it.
        eq("the tooltip knows which cell it is about", GameTooltip:GetOwner(), btn)

        local point, rel, relPoint = GameTooltip:GetPoint(1)
        check("the tooltip is anchored to the sheet, not the cell",
              rel == _G["AltStableSheet"], tostring(rel))
        check("  off its right edge", relPoint == "TOPRIGHT", tostring(relPoint))

        -- ...unless that would put it off the SCREEN, which is what moving it
        -- off the table bought at first: the sheet usually sits near the right
        -- edge of the display, so "just outside its right edge" was just
        -- outside the display, and the tooltip was clipped instead of covering
        -- anything.
        local savedRight = GameTooltip._GetRight
        GameTooltip:SetWidth(GameTooltip:GetWidth())
        GameTooltip._GetRight = (UIParent:GetRight() or 0) + 50
        btn:GetScript("OnEnter")(btn)
        local _, rel2, relPoint2 = GameTooltip:GetPoint(1)
        check("a tooltip that would leave the screen flips to the other side",
              relPoint2 == "TOPLEFT", tostring(relPoint2))
        eq("  still anchored to the sheet", rel2, _G["AltStableSheet"])
        GameTooltip._GetRight = savedRight

        -- And one that fits is left where it was, or "flips" would just mean
        -- "always on the left".
        btn:GetScript("OnEnter")(btn)
        local _, _, relPoint3 = GameTooltip:GetPoint(1)
        check("  while one that fits stays on the right",
              relPoint3 == "TOPRIGHT", tostring(relPoint3))

        -- The fallback matters: the Roster raises this same tooltip from a
        -- card, where there is no sheet frame to hang off.
        local saved = _G["AltStableSheet"]
        _G["AltStableSheet"] = nil
        btn:GetScript("OnEnter")(btn)
        -- The ANCHOR TYPE, not the owner. The owner is already this button from
        -- the anchored call above, so `GetOwner() == btn` passes whether the
        -- fallback ran or not - which is exactly what it did.
        check("  and falls back to the cell when there is no sheet",
              GameTooltip:GetAnchorType() == "ANCHOR_RIGHT",
              tostring(GameTooltip:GetAnchorType()))
        _G["AltStableSheet"] = saved
    end
end

print(("test_sheetui: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
