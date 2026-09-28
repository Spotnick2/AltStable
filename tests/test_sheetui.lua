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
dofile("Theme.lua")
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

        local w, h = T.FitToScreen(820, 760)
        eq("a window that fits is left alone", w, 820)
        eq("  in both directions", h, 760)

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
        local prev = f:GetEffectiveScale()
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
        T.ResizeFrame(820, 760)
        eq("a window that fits is sized exactly as asked", f:GetHeight(), 760)

        -- The OTHER path. ResizeFrameToContent sets the size directly rather
        -- than going through ResizeFrame, so it needed the clamp of its own -
        -- and a roster long enough to want more height than the display has is
        -- just as reachable as the Options tab asking for a fixed 760.
        if T.ResizeFrameToContent then
            local saved = UIParent:GetHeight()
            -- 250, not something roomier: the sidebar alone floors the computed height
            -- near 480, so a limit above that never binds and the assertion
            -- passes whether the clamp is there or not. It has to be shorter
            -- than the content genuinely wants.
            UIParent:SetHeight(250)
            T.ResizeFrameToContent()
            local lim = (250 * UIParent:GetEffectiveScale())
                        / (f:GetEffectiveScale() or 1) - T.SCREEN_MARGIN
            check("sizing to content is clamped to the display too",
                  f:GetHeight() <= lim,
                  ("%s vs max %s"):format(tostring(f:GetHeight()), tostring(lim)))
            UIParent:SetHeight(saved)
        else
            check("the content-sizing path is reachable from a test", false)
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

print(("test_sheetui: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
