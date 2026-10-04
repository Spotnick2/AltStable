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
-- The library and Glass.lua are loaded with the addon NAME, the way the client
-- passes it: LibGlass derives its media path from the host addon's name.
dofile("tests/libglass.lua"); LoadGlass("AltStable")
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
-- Capture.lua follows SheetUI in the .toc; the title-bar button hands off to it.
dofile("Capture.lua")
dofile("PublicAPI.lua")

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

-- The footer counts what the GRID lists (review of #126). Forget a character
-- while playing another, then log into it: the scan rewrites its record, and
-- nothing clears the tombstone. The grid shows it - so the footer must count
-- it, or the totals quietly disagree with the rows right above them.
AltStableConfig.hiddenCharacters = {}
AltStableConfig.forgottenCharacters = { gone = { stamp = 1, name = "Goner" } }
footer = refresh()
eq("a forgotten character with a record again is listed", joined(AltStable._test.DisplayNames()), "Keeper,Goner")
if footer then
    check("  and the footer counts it as the grid does", footer:find("2%s+chars") ~= nil, footer)
    check("  gold included", footer:find("150", 1, true) ~= nil, footer)
end
-- And through AltStable's OWN arithmetic, not the public GetTotals: another
-- addon wrapping that (it is a writable field on a global) must not be able to
-- change what AltStable's footer says.
local realGetTotals = AltStable.GetTotals
AltStable.GetTotals = function() return { money = 0, unknown = 0, characters = 0, hidden = 0, levels = 0 } end
footer = refresh()
AltStable.GetTotals = realGetTotals
if footer then
    check("another addon wrapping GetTotals does not change the footer",
          footer:find("2%s+chars") ~= nil, footer)
end
AltStableConfig.forgottenCharacters = nil
AltStableConfig.hiddenCharacters = { gone = true }

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

    -- The title-bar button is the capture (#89): one path, Capture.lua's, which
    -- settles this fade before borrowing the alpha (pinned in test_capture).
    -- It used to run a second, single-shot path of its own that raced the
    -- fade; that path is gone, and the button must not grow another.
    do
        local asked = 0
        local realPortrait = AltStable.CapturePortrait
        AltStable.CapturePortrait = function() asked = asked + 1; return true end
        local shotsBefore = WoW.screenshots
        AltStable._test.ClickCaptureButton()
        eq("the capture button hands the capture to Capture.lua", asked, 1)
        eq("  and takes no picture of its own", WoW.screenshots, shotsBefore)
        AltStable.CapturePortrait = realPortrait
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

            -- What it promises is what the button does now (#89): the two-shot
            -- capture, and the reload that saves it. Not the retired "AI
            -- portrait", and not the "not in this download" of the release
            -- before capture shipped.
            local onEnter = T.refBtn and T.refBtn:GetScript("OnEnter")
            if txt and onEnter then
                onEnter(T.refBtn)
                local tip = txt:GetText() or ""
                check("the capture tooltip describes the two-shot capture",
                      tip:find("two screenshots", 1, true) ~= nil, tip)
                check("  and the reload that follows it",
                      tip:find("reload", 1, true) ~= nil, tip)
                check("  and no longer promises an AI portrait",
                      tip:find("AI", 1, true) == nil, tip)
                check("  nor says capture is not in the download",
                      tip:find("Not in this download", 1, true) == nil, tip)
            end
        end

        -- The SHEET's own capture path closes the menu. The fix first went into
        -- the probe's SuppressStrays, which is the wrong altitude twice over:
        -- the probe is a dev-only addon that may not be installed, and an
        -- alpha-0 sheet still takes the mouse - so a right-click during the
        -- settle opened a menu that landed in the portrait and left a
        -- full-screen catcher eating every click.
        do
            local closed = 0
            local realClose = AltStable.CloseCharacterMenu
            AltStable.CloseCharacterMenu = function() closed = closed + 1 end
            check("the sheet's capture handler is reachable",
                  T.CapturePortraitFromSheet ~= nil)
            if T.CapturePortraitFromSheet then
                pcall(T.CapturePortraitFromSheet)
            end
            AltStable.CloseCharacterMenu = realClose
            check("the sheet's own capture closes the character menu first",
                  closed > 0, tostring(closed))
            -- Leave nothing running for the blocks below.
            AltStable._test.portrait.AbandonCapture(nil, true)
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

        -- A plugin tab's floor (#154): grows a window it finds too small - the
        -- Reputations section computed 497 wide for one tracked character -
        -- and never shrinks one that is larger.
        T.ResizeFrame(497, 364)
        AltStable.EnsureWindowMinSize(951, 501)
        check("a plugin's floor grows a narrow, short window",
              f:GetWidth() == 951 and f:GetHeight() == 501, f:GetWidth() .. "x" .. f:GetHeight())
        T.ResizeFrame(1200, 700)
        AltStable.EnsureWindowMinSize(951, 501)
        check("  and leaves a larger one alone",
              f:GetWidth() == 1200 and f:GetHeight() == 700, f:GetWidth() .. "x" .. f:GetHeight())
        -- A plugin that sizes the frame DIRECTLY (Raids does) leaves the
        -- remembered request behind: Warband -> Raids -> Warband must still
        -- grow it, from the size the window actually has.
        AltStable.EnsureWindowMinSize(951, 501)
        f:SetSize(595, 430)                 -- Raids, around ResizeFrame
        AltStable.EnsureWindowMinSize(951, 501)
        check("  and grows one a plugin shrank directly",
              f:GetWidth() == 951 and f:GetHeight() == 501,
              f:GetWidth() .. "x" .. f:GetHeight())
        T.ResizeFrame(820, 600)

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

        -- A plugin tab's PREFERRED size (#150): the same whichever tab came
        -- before it, on the owner's screen (3840x2160, UI scale off: 1365 x 768
        -- units), clamped on a smaller one - and the preference survives the
        -- clamp AND the tab's floor, so scaling back down brings it back.
        do
            local savedW, savedH = UIParent:GetWidth(), UIParent:GetHeight()
            local savedScale = f:GetScale()
            UIParent:SetWidth(1365); UIParent:SetHeight(768)
            AltStable.SetScale(1.0)
            local sidebar = AltStable.LAYOUT.SIDEBAR_WIDTH
            local wantW, wantH = sidebar + 1 + 1040, AltStable.PLUGIN_WINDOW_H

            T.ResizeFrame(600, 400)                 -- a narrow sheet tab before it
            AltStable.RequestPluginSize(1040)
            local afterNarrow = f:GetWidth() .. "x" .. f:GetHeight()
            T.ResizeFrame(1280, 700)                -- a wide one
            AltStable.RequestPluginSize(1040)
            eq("a plugin tab opens at the same size after a narrow tab and a wide one",
               f:GetWidth() .. "x" .. f:GetHeight(), afterNarrow)
            eq("  its preferred size, on the owner's screen",
               afterNarrow, wantW .. "x" .. wantH)
            check("  which fits that screen with the margin",
                  wantW <= 1365 - T.SCREEN_MARGIN and wantH <= 768 - T.SCREEN_MARGIN)

            -- A smaller screen in its own units: the addon scaled to 1.25.
            AltStable.SetScale(1.25)
            local limH = (768 * UIParent:GetEffectiveScale()) / (f:GetEffectiveScale() or 1)
                         - T.SCREEN_MARGIN
            check("scaled up, the preferred size is clamped to the screen",
                  f:GetHeight() <= limH + 0.5, f:GetHeight() .. " vs " .. limH)
            AltStable.SetScale(1.0)
            eq("scaling back down restores it",
               f:GetWidth() .. "x" .. f:GetHeight(), wantW .. "x" .. wantH)

            -- A screen too small for even the tab's floor (the Roster's 796
            -- panel): the floor runs while clamped, and must floor the REQUEST,
            -- not replace it with the clamped size (Codex, #150).
            UIParent:SetWidth(1000)
            AltStable.RefitWindow()
            check("a narrow screen clamps the window below the floor",
                  f:GetWidth() < sidebar + 1 + 796, tostring(f:GetWidth()))
            AltStable.EnsureWindowMinSize(sidebar + 1 + 796, 30 + 400 + 22 + 2)
            UIParent:SetWidth(1365)
            AltStable.RefitWindow()
            eq("back on the full screen, the preferred size returns, floor and all",
               f:GetWidth() .. "x" .. f:GetHeight(), wantW .. "x" .. wantH)

            AltStable.SetScale(savedScale)
            UIParent:SetWidth(savedW); UIParent:SetHeight(savedH)
            T.ResizeFrame(820, 600)
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

            -- A POOLED RE-RENDER. Rows are reused by index, so a sync record
            -- landing while the menu is open re-renders the row under it as
            -- somebody else. Setting markGuid was not enough: the texture kept
            -- whatever state the previous occupant left it in, so the addon
            -- pointed at the wrong character as "the row this right-click acts
            -- on" while the menu still belonged to the old one.
            T.SetMenuSubject("Player-1-CCCC")
            check("the subject's row is lit before the refresh", frozen.mark:IsShown())
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-EEEE", name = "E", class = "MAGE" }, 1)
            check("  and a re-render as somebody else puts it out",
                  not frozen.mark:IsShown())
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-CCCC", name = "C", class = "MAGE" }, 1)
            check("  while re-rendering the subject lights it again",
                  frozen.mark:IsShown())
            T.SetMenuSubject(nil)

            -- Every render path clears it, including the frozen filler - which
            -- was the one that did not, so a hovered name left a lit band in an
            -- empty name column when the list shortened under it.
            frozen.nameTipBtn:GetScript("OnEnter")(frozen.nameTipBtn)
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-CCCC", name = "C", class = "MAGE" }, 1)
            frozen.nameTipBtn.charData = { guid = "Player-1-CCCC" }
            frozen.nameTipBtn:GetScript("OnEnter")(frozen.nameTipBtn)
            check("a hovered row is lit", frozen.mark:IsShown())
            AltStable.RenderFrozenFillerRow(frozen, 1)
            check("  and becoming a filler row puts it out",
                  not frozen.mark:IsShown())

            -- The scrollable half's filler too. Found by a mutation aimed at
            -- the frozen one that matched this instead, which is the more
            -- useful kind of accident.
            scroll.nameTipBtn = scroll.nameTipBtn or frozen.nameTipBtn
            AltStable.RenderRow(scroll,
                { guid = "Player-1-CCCC", name = "C", class = "MAGE" }, 1, {})
            T.SetMenuSubject("Player-1-CCCC")
            check("the scrollable half lights for the menu", scroll.mark:IsShown())
            AltStable.RenderFillerRow(scroll, 1)
            check("  and its filler row puts it out", not scroll.mark:IsShown())
            T.SetMenuSubject(nil)

            -- A STALE HOVER. The cursor does not move when the list refreshes
            -- under it, so OnLeave never fires - and without dropping the
            -- hovered guid when its row becomes somebody else, it survives and
            -- later lights whichever row happens to be given that character.
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-FFFF", name = "F", class = "MAGE" }, 1)
            frozen.nameTipBtn.charData = { guid = "Player-1-FFFF", name = "F",
                                           class = "MAGE", money = 1 }
            frozen.nameTipBtn:GetScript("OnEnter")(frozen.nameTipBtn)
            check("a hovered row is lit before the refresh", frozen.mark:IsShown())
            -- The list refreshes and this row now holds somebody else.
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-GGGG", name = "G", class = "MAGE" }, 1)
            check("  and it goes dark", not frozen.mark:IsShown())
            -- The character that WAS hovered turns up on another row. Nothing
            -- is under the cursor there, so it must not light.
            AltStable.RenderRow(scroll,
                { guid = "Player-1-FFFF", name = "F", class = "MAGE" }, 1, {})
            check("  and the character it belonged to does not light elsewhere",
                  not scroll.mark:IsShown())
            frozen.nameTipBtn:GetScript("OnLeave")(frozen.nameTipBtn)
            frozen.nameTipBtn:GetScript("OnLeave")(frozen.nameTipBtn)
            -- Put the row back to a character, or the hover assertions further
            -- down have a filler row to light and nothing to light it with.
            AltStable.RenderFrozenCharRow(frozen,
                { guid = "Player-1-CCCC", name = "C", class = "MAGE" }, 1)
            frozen.nameTipBtn.charData = { guid = "Player-1-CCCC", name = "C",
                                           class = "MAGE", money = 1 }

            -- The two halves light EQUALLY. Within one draw layer order is
            -- creation order, and the frozen half created its mark before the
            -- class tint while the scrollable half created it after - so one
            -- painted under the tint and the other over it, and the halves of
            -- one row lit at different strengths.
            -- `_created` is the stub's record of texture creation order,
            -- which is what the client uses to break a tie within one draw
            -- layer at the same sublevel.
            local fm, ft = frozen.mark._created, frozen.classTint._created
            local sm, st = scroll.mark._created, scroll.classTint._created
            check("the frozen half paints its mark above the class tint",
                  (fm or 0) > (ft or 0), ("%s vs %s"):format(tostring(fm), tostring(ft)))
            check("  as the scrollable half does",
                  (sm or 0) > (st or 0), ("%s vs %s"):format(tostring(sm), tostring(st)))

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

    -- NUMERIC order, not text. 1 and 2 sort the same either way, which is why
    -- the check above could not see that a plain table.sort put account 10
    -- before account 2.
    local many = acc(10, 2, 1)
    eq("ten accounts sort after two, not before",
       table.concat(many, ","), "1,2,10")

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

        -- ...unless there is no ROOM there, which is what moving it off the
        -- table bought at first: the sheet usually sits near the right edge of
        -- the display, so "just outside its right edge" was just outside the
        -- display, and the tooltip was clipped instead of covering anything.
        --
        -- The side is chosen from the room beside the window, before the
        -- tooltip is populated. Measuring it afterwards and flipping looked
        -- more precise and did not work: a tooltip's size is not final in the
        -- frame it is shown, so the check read the layout it had before its
        -- lines went in, agreed with itself, and still opened half off screen.
        local sheet = _G["AltStableSheet"]
        local savedL, savedR = sheet._GetLeft, sheet._GetRight
        local savedUL, savedUR = UIParent._GetLeft, UIParent._GetRight
        local savedSS, savedUS = sheet._scale, UIParent._scale
        UIParent._GetLeft, UIParent._GetRight = 0, 1000

        -- DIFFERING SCALES, or the conversion is untestable: with both at 1,
        -- every `* ss` and `* us` in SideRoomPx can be deleted and the suite
        -- stays green. That is the exact mutation this work re-earned from the
        -- Options tab, and it was unguarded here.
        --
        -- The sheet is a CHILD of UIParent, so its effective scale already
        -- includes UIParent's: setting the two to different numbers does not
        -- make their effective scales differ. Its OWN scale has to be the
        -- inverse. At 0.5 under a UIParent of 2 the sheet's effective scale is
        -- 1 against the screen's 2, so its raw coordinates are half the size
        -- they look - a window that appears hard against the right edge is
        -- really mid-display with room to spare.
        sheet._scale, UIParent._scale = 0.5, 2
        sheet._GetLeft, sheet._GetRight = 400, 995
        btn:GetScript("OnEnter")(btn)
        local _, _, scaledPoint = GameTooltip:GetPoint(1)
        check("the room beside the window is measured in one coordinate space",
              scaledPoint == "TOPRIGHT", tostring(scaledPoint))
        sheet._scale, UIParent._scale = savedSS, savedUS

        -- The WIDTH is in the tooltip's own units while the room is in physical
        -- pixels, so the comparison needs the tooltip's scale too - the same
        -- unit mixing, one layer up and in the one place it is not obvious.
        -- With every scale at 1 that conversion is a no-op and can be deleted
        -- with the suite green, which is exactly what it was.
        local savedTS = GameTooltip._scale
        GameTooltip._scale = 4          -- a 320-unit tooltip is 1280px wide
        -- 400px on the right, 500 on the left. Enough for an UNCONVERTED 320,
        -- not enough for the 1280 it really needs - and the left is roomier, so
        -- the tiebreak cannot supply the right answer by accident.
        sheet._GetLeft, sheet._GetRight = 500, 600
        btn:GetScript("OnEnter")(btn)
        local _, _, bigPoint = GameTooltip:GetPoint(1)
        check("a tooltip wider than the room beside the window opens on the left",
              bigPoint == "TOPLEFT", tostring(bigPoint))
        GameTooltip._scale = savedTS

        -- Window hard against the right edge: no room there, plenty on the left.
        sheet._GetLeft, sheet._GetRight = 400, 995
        btn:GetScript("OnEnter")(btn)
        local _, rel2, relPoint2 = GameTooltip:GetPoint(1)
        check("with no room on the right the tooltip opens on the left",
              relPoint2 == "TOPLEFT", tostring(relPoint2))
        eq("  still anchored to the sheet", rel2, sheet)

        -- Window on the left with room to spare: it stays on the right, or
        -- "flips" quietly becomes "always on the left".
        sheet._GetLeft, sheet._GetRight = 10, 400
        btn:GetScript("OnEnter")(btn)
        local _, _, relPoint3 = GameTooltip:GetPoint(1)
        check("  while a window with room keeps it on the right",
              relPoint3 == "TOPRIGHT", tostring(relPoint3))

        -- Boxed in on both sides: it picks the roomier one rather than
        -- guaranteeing a side, which is the only sensible answer.
        sheet._GetLeft, sheet._GetRight = 50, 990
        btn:GetScript("OnEnter")(btn)
        local _, _, relPoint4 = GameTooltip:GetPoint(1)
        check("  and with room on neither side it takes the roomier one",
              relPoint4 == "TOPLEFT", tostring(relPoint4))

        sheet._GetLeft, sheet._GetRight = savedL, savedR
        UIParent._GetLeft, UIParent._GetRight = savedUL, savedUR
        sheet._scale, UIParent._scale = savedSS, savedUS

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

-- The Options tab's background is the material too (#97 phase 3).
--
-- This one was already a clipped texture rather than a backdrop - it owns the
-- window's bottom-right corner - so it was rounded correctly and still opaque,
-- a slab with a neatly trimmed corner.
do
    local optBG = AltStable._test.optBG
    check("the Options tab has a background", optBG ~= nil)
    if optBG then
        local pane = AltStable.SkinPaneColor()
        local c = optBG._colorTexture
        check("  and it is the material, not a slab",
              c and c[1] == pane[1] and c[4] == pane[4],
              c and ("%s a=%s"):format(c[1], c[4]) or "nil")
    end
end

-- And the data underlay gets out from under it.
--
-- That underlay spans the body viewports - below the column headers, above the
-- footer - while a plugin panel runs from the title bar to the footer. Left
-- shown underneath a translucent one, the overlapping part was two layers of
-- pane and the rest was one: a hard horizontal seam about 30px below the title
-- and another near the bottom. It has been there since the underlay was added
-- and could not be seen while those panels were opaque.
do
    local dataBG = AltStable._dataBG
    check("the data underlay exists under glass", dataBG ~= nil)
    local btns = AltStable._test.sidebarBtns or {}
    local optBtn, tableBtn
    for _, b in ipairs(btns) do
        if b.sectionId == "options" then optBtn = b
        elseif not optBtn and not tableBtn then tableBtn = b end
    end
    if dataBG and optBtn and tableBtn then
        optBtn:GetScript("OnClick")(optBtn)
        check("a panel tab puts it away", not dataBG:IsShown())
        tableBtn:GetScript("OnClick")(tableBtn)
        check("  and a table tab brings it back", dataBG:IsShown())
    else
        check("there is a panel tab and a table tab to switch between",
              false, "no nav buttons to drive")
    end
end

-- The rows ask the skin for their band (#97), and the underlay is the surface
-- they sit on.
--
-- The arithmetic is asserted in test_glass; what cannot be asserted there is
-- whether a rendered row actually uses it. Twenty-one opaque bands in the flat
-- theme's charcoal is what the table WAS inside a glass window, and every one
-- of them came through this one call.
do
    local row = AltStable.CreateRow(UIParent, 18, {})
    local char = { guid = "Player-1-ROWBG", name = "R", class = "MAGE" }
    local function same(got, want)
        if not got then return false end
        for i = 1, 4 do if got[i] ~= want[i] then return false end end
        return true
    end

    AltStable.RenderRow(row, char, 2, {})
    check("an even row is painted with the skin's band",
          same(row.bg._colorTexture, { AltStable.SkinRowStripe(2) }),
          table.concat(row.bg._colorTexture or {}, ","))
    AltStable.RenderRow(row, char, 3, {})
    check("  and an odd row with the odd one",
          same(row.bg._colorTexture, { AltStable.SkinRowStripe(3) }),
          table.concat(row.bg._colorTexture or {}, ","))

    -- PARITY FOLLOWS THE DISPLAY INDEX, not the pooled row. Rows are reused as
    -- the list scrolls, so parity read off the slot would make a row change
    -- shade as it travelled rather than staying with the character in it.
    local a = { unpack(row.bg._colorTexture) }
    AltStable.RenderRow(row, char, 4, {})
    check("  and the same row at the next index changes band",
          not same(row.bg._colorTexture, a),
          table.concat(row.bg._colorTexture or {}, ","))

    -- The empty space below the last character is the same table, not a
    -- different material: the fillers carry the striping to the bottom.
    -- At the OPPOSITE parity to the row above, or the check passes on the
    -- colour the previous render happened to leave behind - which is exactly
    -- what it did, and a mutation deleting the paint survived it.
    AltStable.RenderFillerRow(row, 3)
    check("a filler row keeps the striping going",
          same(row.bg._colorTexture, { AltStable.SkinRowStripe(3) }),
          table.concat(row.bg._colorTexture or {}, ","))

    AltStable.RenderGroupRow(row, { kind = "group", realm = "R", count = 1 })
    check("and a realm band is the skin's band",
          same(row.bg._colorTexture, { AltStable.SkinGroupBand() }),
          table.concat(row.bg._colorTexture or {}, ","))

    -- BOTH HALVES. The name lives in the frozen column and the data in the
    -- scrollable one, side by side and separate - so a band asserted on one of
    -- them is half a row. Found by a mutation that blanked the frozen filler
    -- and passed everything above it.
    local frozen = AltStable.CreateFrozenRow(UIParent, 18, 120)
    AltStable.RenderFrozenCharRow(frozen, char, 3)
    check("the frozen half is painted from the skin too",
          same(frozen.bg._colorTexture, { AltStable.SkinRowStripe(3) }),
          table.concat(frozen.bg._colorTexture or {}, ","))
    -- The filler at the EVEN index, and the row above it odd. An odd row under
    -- glass paints nothing at all, so checking a filler there cannot tell a
    -- painted row from an unpainted one - which is how the first version of
    -- this passed a mutation that blanked it.
    AltStable.RenderFrozenFillerRow(frozen, 2)
    check("  and keeps striping past the last character",
          same(frozen.bg._colorTexture, { AltStable.SkinRowStripe(2) }),
          table.concat(frozen.bg._colorTexture or {}, ","))
    AltStable.RenderFrozenGroupRow(frozen, { kind = "group", realm = "R", count = 1 })
    check("  and carries the realm band with the other half",
          same(frozen.bg._colorTexture, { AltStable.SkinGroupBand() }),
          table.concat(frozen.bg._colorTexture or {}, ","))

    -- BOTH column headers, which are two frames for the same reason the rows
    -- are: the name column is frozen and the rest scrolls under it. One of them
    -- left behind is a header that changes colour halfway across the table.
    for _, key in ipairs({ "headerBG", "frozenHeaderBG" }) do
        local bg = AltStable._test[key]
        check(key .. " exists", bg ~= nil)
        if bg then
            check("  and is painted with the skin's header band",
                  same(bg._colorTexture, { AltStable.SkinHeaderBand() }),
                  table.concat(bg._colorTexture or {}, ","))
        end
    end

    -- AND IT ENDS WHERE THE TABLE ENDS.
    --
    -- The surface was pinned once at frame creation, 36 from the bottom, while
    -- the viewport's bottom MOVES: 23 with no horizontal scrollbar and 43 with
    -- one. Thirteen pixels of difference, invisible while every row painted an
    -- opaque band over it - and the moment the rows became lifts, a strip of
    -- moving world under the last row. The top was frozen the same way, at the
    -- header height of whichever section happened to build the frame.
    do
        local sheet = _G["AltStableSheet"]
        local dataBG = AltStable._dataBG
        local body = sheet and sheet.bodyScroll
        local function edge(region, want)
            for i = 1, (region:GetNumPoints() or 0) do
                local point, _, _, x, y = region:GetPoint(i)
                if point == want then return x, y end
            end
        end
        check("there is a surface and a viewport to compare", dataBG and body)
        if dataBG and body then
            local _, surfaceBot = edge(dataBG, "BOTTOMRIGHT")
            local _, viewBot    = edge(body,   "BOTTOMRIGHT")
            eq("the surface ends where the table ends", surfaceBot, viewBot)
            local _, surfaceTop = edge(dataBG, "TOPLEFT")
            local _, viewTop    = edge(body,   "TOPLEFT")
            eq("  and starts where it starts", surfaceTop, viewTop)

            -- ON EVERY SECTION, not just the one that built the frame. The
            -- header is 28 tall here and 64 on others, so a top frozen at
            -- creation is right exactly once - and a test that only ever looks
            -- at the default section cannot tell a tracked edge from a frozen
            -- one that happens to match.
            local moved = false
            for _, b in ipairs(AltStable._test.sidebarBtns or {}) do
                -- The TABLE sections. Options is a panel: it hides the body and
                -- the surface with it, so there is nothing to line up there.
                if b.sectionId and b.sectionId ~= "options" then
                    b:GetScript("OnClick")(b)
                    local _, t2 = edge(dataBG, "TOPLEFT")
                    local _, v2 = edge(body,   "TOPLEFT")
                    eq("  on every section's header height", t2, v2)
                    if t2 ~= surfaceTop then moved = true end
                end
            end
            check("  and at least one section moved that edge", moved,
                  "otherwise this proves nothing")
        end
    end

    -- The surface itself, which had been painted with the PANE - a translucent
    -- panel colour - while twenty-one opaque rows sat on top hiding it.
    local dataBG = AltStable._dataBG
    if dataBG then
        local d = AltStable.SkinDataColor()
        check("the underlay is the reading surface",
              same(dataBG._colorTexture, { d[1], d[2], d[3], d[4] }),
              table.concat(dataBG._colorTexture or {}, ","))
        eq("  and it is opaque", dataBG._colorTexture[4], 1)
    end
end

------------------------------------------------------------
-- The skin picker in Options (#108)
------------------------------------------------------------
-- The material shipped reachable only from `/alts skin`, so a player who never
-- read the release notes never knew there was one.
do
    local btns = AltStable._test.skinBtns or {}
    eq("there is a button per skin", #btns, 3)
    -- BUILT FROM THE TABLE, so a fourth preset arrives on its own rather than
    -- being a fourth place to remember.
    local labels = {}
    for i, b in ipairs(btns) do labels[i] = b.lbl:GetText() end
    eq("flat comes first, because it is the unstyled one", btns[1].skinName, "flat")
    for _, b in ipairs(btns) do
        eq("  " .. b.skinName .. " wears its own label",
           b.lbl:GetText(), AltStable.SKINS[b.skinName].label or b.skinName)
    end

    local held = AltStableConfig.skin
    -- CHOOSING ONE WRITES IT AND SAYS SO. The material is built when the window
    -- is, so this changes the next load - and a picker that looked like it had
    -- done nothing is why the command version says "reload" in chat.
    local loaded = AltStable.SkinName()
    local other
    for _, b in ipairs(btns) do if b.skinName ~= loaded then other = b end end
    other:GetScript("OnClick")(other)
    eq("clicking a skin stores it", AltStableConfig.skin, other.skinName)
    local prompt = AltStable._test.SkinReloadPrompt()
    check("  and the panel says it needs a reload", prompt ~= nil, tostring(prompt))
    check("  naming the one you picked",
          prompt and prompt:find(AltStable.SKINS[other.skinName].label, 1, true) ~= nil,
          tostring(prompt))

    -- And NOT while the choice matches what the window is already wearing:
    -- a permanent "reload" on a panel with nothing pending is noise.
    local current
    for _, b in ipairs(btns) do if b.skinName == loaded then current = b end end
    current:GetScript("OnClick")(current)
    eq("choosing the loaded skin is not a pending change",
       AltStable._test.SkinReloadPrompt(), nil)

    -- The selected button is the one ON DISK, not the one loaded - that is the
    -- whole point of showing a pending state at all.
    other:GetScript("OnClick")(other)
    -- ALL THREE CHANNELS. The accent is gold, {1.00, 0.82, 0.00}, so checking
    -- red alone is satisfied by plain white - and the painter is SHARED with
    -- the accent row now, so one slip there would drop the selection colour
    -- from both rows at once with the suite green.
    local function isAccent(fs)
        local ar, ag, ab = AltStable.GetAccentRGB()
        local r, g, b = fs:GetTextColor()
        return r == ar and g == ag and b == ab
    end
    local lit, litName = 0, nil
    for _, b in ipairs(btns) do
        if isAccent(b.lbl) then lit = lit + 1; litName = b.skinName end
    end
    eq("exactly one skin button reads as chosen", lit, 1)
    -- And it is the one ON DISK. Lighting the LOADED one instead passes a
    -- count and shows the player their choice did not take.
    eq("  and it is the one just chosen, not the one loaded",
       litName, other.skinName)
    check("  which is not the loaded one", other.skinName ~= loaded)

    -- CHANGING THE ACCENT REPAINTS THIS ROW. Its selected button is painted in
    -- the accent, so it goes stale on exactly the same event the accent row
    -- does - and that row has always refreshed itself.
    do
        local heldTheme = AltStableConfig.theme
        -- OPEN, because the callback is guarded on the panel being shown - a
        -- repaint of a hidden panel is work nobody sees, and OnShow covers the
        -- other direction. Driving this with the panel hidden tests neither.
        local panel = AltStable._test.optionsPanel
        local wasShown = panel:IsShown()
        panel:Show()
        local before = { AltStable.GetAccentRGB() }
        AltStable.SetConfigValue("theme", AltStableConfig.theme == "class" and "dark" or "class")
        AltStable.ApplyTheme()
        local after = { AltStable.GetAccentRGB() }
        if after[1] ~= before[1] or after[2] ~= before[2] or after[3] ~= before[3] then
            local stale = 0
            for _, b in ipairs(btns) do
                if b.skinName == AltStable.PendingSkinName() and not isAccent(b.lbl) then
                    stale = stale + 1
                end
            end
            eq("the chosen skin is repainted when the accent changes", stale, 0)
        else
            check("the accent actually changed, or this proves nothing", false,
                  "class colour matched gold")
        end
        AltStable.SetConfigValue("theme", heldTheme)
        AltStable.ApplyTheme()
        if not wasShown then panel:Hide() end
    end

    -- AND THE PANEL RE-SYNCS IT ON OPEN. `/alts skin` writes the config from
    -- outside this panel and says "reload" in chat; opening Options after that
    -- and seeing the OLD skin lit, with no pending line, contradicts the
    -- message the player just read - and invites them to click the lit button
    -- and discard the choice they made.
    do
        local other2
        for _, b in ipairs(btns) do
            if b.skinName ~= AltStable.SkinName() then other2 = b end
        end
        AltStable.SetConfigValue("skin", AltStable.SkinName())   -- nothing pending
        AltStable._test.RefreshSkinRow()
        eq("nothing pending to start with", AltStable._test.SkinReloadPrompt(), nil)
        AltStable.SetConfigValue("skin", other2.skinName)        -- as /alts skin does
        -- THROUGH THE PANEL'S OWN OnShow, not by calling the refresher: the
        -- bug was that OnShow re-synced every other control and not this one,
        -- and a test that refreshes it itself cannot see that.
        local optPanel = AltStable._test.optionsPanel
        optPanel:GetScript("OnShow")(optPanel)
        check("a skin chosen from the command line shows as pending on open",
              AltStable._test.SkinReloadPrompt() ~= nil)
        local chosen
        for _, b in ipairs(btns) do if isAccent(b.lbl) then chosen = b.skinName end end
        eq("  and the row lights the one that was chosen", chosen, other2.skinName)
    end

    -- THE RELOAD BUTTON IS REACHABLE. It sat beside the skin buttons first,
    -- and the Options viewport is not the 820 the tab asks for - the sidebar
    -- and the scrollbar take it to about 563, the three choices already end
    -- near 382, and the button was pushed off the right edge. The panel
    -- scrolls vertically only, so the one action this row exists to offer
    -- could not be reached at all.
    do
        local btn = AltStable._test.SkinReloadButton()
        local VIEWPORT = 820 - (AltStable.LAYOUT.SIDEBAR_WIDTH or 230) - 26
        local right
        for i = 1, btn:GetNumPoints() do
            local point, _, relPoint, x = btn:GetPoint(i)
            if point == "TOPRIGHT" and relPoint == "TOPRIGHT" then right = x end
        end
        check("the Reload button hangs off the panel's own right edge",
              right ~= nil and right < 0, tostring(right))
        -- Pinned to the right means its LEFT is viewport - padding - width, and
        -- it cannot be pushed anywhere by a longer message.
        local leftEdge = VIEWPORT + (right or 0) - btn:GetWidth()
        check("  so it sits inside the viewport whatever the message says",
              leftEdge > 0 and leftEdge < VIEWPORT,
              ("left %s of %s"):format(tostring(leftEdge), VIEWPORT))
        -- And the message is bounded by it rather than running under it.
        local bounded = false
        local fs = AltStable._test.SkinReloadText and AltStable._test.SkinReloadText()
        if fs then
            for i = 1, fs:GetNumPoints() do
                local point, rel = fs:GetPoint(i)
                if point == "RIGHT" and rel == btn then bounded = true end
            end
            check("  with the message stopping where the button starts", bounded)
        end
    end

    AltStableConfig.skin = held
end

------------------------------------------------------------
-- The window eats the mouse (#74)
------------------------------------------------------------
-- A frame with the mouse disabled is transparent to it, so the 3D world
-- underneath kept getting mouseover through every part of this window that is
-- not a row or a button - the sidebar, the gaps between rows, the footer, a
-- whole plugin panel. In a city that is a unit tooltip following the cursor
-- across the sheet the whole time it is open.
do
    local sheet = AltStable._test.frame
    -- Any capture left pending by an earlier test gets to finish first: its
    -- restore is a timer, and asserting before it runs is asserting mid-shot.
    WoW.flushTimers()
    check("the window takes the mouse itself", sheet:IsMouseEnabled())
    -- As built, not as left by whatever ran before: a capture's restore turns
    -- it back on, so the state now answers yes even if the window was created
    -- click-through.
    check("  and was built that way", AltStable._test.frameMouseAtBuild == true)

    -- THE HARNESS AGREES WITH THE CLIENT about a nil. EnableMouse(nil) is a
    -- disable there; reading it as an enable here would put the wrong default
    -- back by another door, for any call site that ever passes a config value.
    do
        local probe = CreateFrame("Frame", nil, UIParent)
        check("a fresh frame does not take the mouse", not probe:IsMouseEnabled())
        probe:EnableMouse(nil)
        check("  and EnableMouse(nil) does not give it one",
              not probe:IsMouseEnabled())
        local btn = CreateFrame("Button", nil, UIParent)
        check("  while a button has it from the start", btn:IsMouseEnabled())
    end

    -- AND IT LETS GO WHEN IT IS INVISIBLE, then takes the mouse back. An
    -- alpha-0 frame still takes the mouse, and the capture hides this window by
    -- alpha (Capture.lua), so without this a capture would leave an invisible
    -- full-size dead zone for its three seconds.
    -- ANY alpha-0 counts: the hook is on SetAlpha itself, so whoever zeroes it.
    sheet:SetAlpha(1)
    check("visible means clickable", sheet:IsMouseEnabled())
    sheet:SetAlpha(0)
    check("  and hiding it by alpha releases the mouse",
          not sheet:IsMouseEnabled())
    sheet:SetAlpha(1)
    check("  and showing it takes the mouse back", sheet:IsMouseEnabled())

    -- It is still DRAGGABLE, which is what the old comment was protecting:
    -- the title bar owns the drag, and enabling the mouse here does not touch
    -- that.
    check("  and is still movable", sheet:IsMovable())
    -- NOT behind `if bar then`: a guard around the only assertion protecting
    -- "dragging still works" means renaming the seam deletes the guarantee
    -- without anything going red.
    local bar = AltStable._test.titleBar
    check("the title bar seam is exported", bar ~= nil)
    check("  and the title bar still holds the drag",
          bar and bar:IsMouseEnabled() and bar:GetScript("OnDragStart") ~= nil)
end

------------------------------------------------------------
-- A popup lifted out of a hidden interface, and put back cleanly (#89 review)
------------------------------------------------------------
-- A StaticPopup is a child of UIParent. With the interface hidden - by the
-- showcase, or by a player who pressed Alt+Z - a popup under it is shown and
-- invisible. LiftPopup takes it out; DropPopup puts it back when it closes.
-- Driven with the Forget confirmation, the popup that uses them.
do
    local which = "ALTSTABLE_CONFIRM_FORGET_CHARACTER"
    local def = StaticPopupDialogs[which]
    check("the forget confirmation is defined", def ~= nil)
    local Lift, Drop = AltStable._test.LiftPopup, AltStable._test.DropPopup

    -- Alt+Z, no showcase: the showcase does not own the hiding, and the lift
    -- used to ask only the showcase.
    WoW.popups = {}
    SetUIVisibility(false)
    local dialog = Lift(StaticPopup_Show(which, "Someone", nil, { guid = "x" }))
    check("with the interface hidden by Alt+Z a popup is lifted out of it",
          dialog and dialog:GetParent() ~= UIParent)
    check("  and can actually be seen", dialog and dialog:IsVisible())
    Drop(dialog)
    eq("dropping puts it back under UIParent", dialog:GetParent(), UIParent)
    eq("  at the strata it had", dialog:GetFrameStrata(), "DIALOG")
    eq("  with nothing left marked as lifted", dialog._altstableLifted, nil)

    -- RE-ENTRANT: putting the dialog back under a hidden UIParent can fire its
    -- OnHide - another DropPopup - half way through the first. Modelled by
    -- having the reparent itself call DropPopup, as the client's hide would.
    dialog = Lift(StaticPopup_Show(which, "Someone", nil, { guid = "x" }))
    local realSetParent = dialog.SetParent
    dialog.SetParent = function(self, parent)
        local r = realSetParent(self, parent)
        if parent == UIParent then Drop(self) end
        return r
    end
    Drop(dialog)
    dialog.SetParent = realSetParent
    eq("a drop interrupted by its own OnHide still ends at the right strata",
       dialog:GetFrameStrata(), "DIALOG")
    eq("  and under UIParent", dialog:GetParent(), UIParent)

    SetUIVisibility(true)
    dialog = Lift(StaticPopup_Show(which, "Someone", nil, { guid = "x" }))
    eq("with the interface up nothing is lifted", dialog:GetParent(), UIParent)
    Drop(dialog)
    WoW.popups = {}
end

------------------------------------------------------------
-- "Reload now?" - with a button that is ALLOWED to reload (#89)
------------------------------------------------------------
-- ReloadUI() from our code is blocked on this client (measured). The prompt's
-- Reload button is a secure /reload macro, so the click is Blizzard's code.
do
    WoW.reloaded = 0
    check("a reload can be offered", AltStable.ShowReloadPrompt("Reload now?") == true)
    local f = AltStable._test.ReloadPrompt()
    check("  and the prompt is up", f and f:IsShown())
    check("  saying what it was asked to", f and f.text:GetText() == "Reload now?")
    local r = f.reload
    eq("its Reload button runs a macro", r:GetAttribute("type"), "macro")
    eq("  the /reload macro", r:GetAttribute("macrotext"), "/reload")
    eq("  and has no click handler of ours, which would make the click ours",
       r:GetScript("OnClick"), nil)
    check("  and answers the press as well as the release",
          (function()
              local up, down = false, false
              for _, c in ipairs(r:RegisteredClicks()) do
                  if c == "AnyUp" then up = true end
                  if c == "AnyDown" then down = true end
              end
              return up and down
          end)())
    eq("nothing of ours called ReloadUI to get here", WoW.reloaded, 0)

    -- Not a child of the sheet: a protected frame's parent cannot be hidden in
    -- combat, and the sheet has to close on Escape mid-fight.
    local p, inSheet = f:GetParent(), false
    while p do
        if p == AltStable._test.frame then inSheet = true end
        p = p.GetParent and p:GetParent()
    end
    check("the prompt is not inside the sheet", not inSheet)
    eq("  it hangs from nothing, so a hidden interface does not hide it", f:GetParent(), nil)
    SetUIVisibility(false)
    check("  and stays visible with the interface hidden", f:IsVisible())
    SetUIVisibility(true)

    f.later:GetScript("OnClick")(f.later)
    check("Later puts it away", not f:IsShown())

    AltStable.ShowReloadPrompt("again")
    f:GetScript("OnEvent")(f, "PLAYER_REGEN_DISABLED")
    check("combat puts it away before the lockdown", not f:IsShown())

    WoW.inCombat = true
    check("in combat it is not offered at all", AltStable.ShowReloadPrompt("x") == false)
    check("  and does not appear", not f:IsShown())
    WoW.inCombat = false

    -- The Options skin row's Reload offers the same prompt.
    local btn = AltStable._test.SkinReloadButton()
    btn:GetScript("OnClick")(btn)
    check("the skin row's Reload offers the prompt", f:IsShown())
    check("  saying why", tostring(f.text:GetText()):find("skin", 1, true) ~= nil,
          tostring(f.text:GetText()))
    eq("  without reloading by itself", WoW.reloaded, 0)
    f:Hide()
end

------------------------------------------------------------
-- A capture through the REAL camera showcase (#89 review)
------------------------------------------------------------
-- The showcase hides the game UI and lifts the sheet out of it. A capture
-- then hides UIParent itself - and hiding a parent fires OnHide on the
-- children still shown, the sheet included when it is under UIParent. The
-- sheet has to tell that apart from being CLOSED: the first must leave the
-- showcase alone, the second must end it. A flag set for the whole capture
-- could not: Alt+Z mid-capture closed the sheet and the showcase stayed on,
-- camera and all, with no window to close it from.
do
    local P = AltStable._test.portrait
    local Cam = AltStable._test.CameraPresentation
    local sheet = AltStable._test.frame
    AltStableConfig.enableWorldCameraPresentation = true
    WoW.cvars["test_cameraOverShoulder"] = "0"

    local function openSheet()
        sheet:Hide()
        pcall(Cam.ForceRestore, Cam, "test")
        Cam.active, Cam.mode = false, nil
        SetUIVisibility(true)
        AltStable.EnsureSheetVisible()
    end

    -- Alt+Z mid-capture, showcase on.
    openSheet()
    check("the sheet is open with the showcase running", sheet:IsShown() and Cam.active)
    P.Capture()
    check("a capture starts from the open sheet", P.capturing())
    SetUIVisibility(true)                       -- the player presses Alt+Z
    check("  Alt+Z abandons it", not P.capturing())
    check("  and closes the sheet, as Alt+Z does with the showcase up", not sheet:IsShown())
    eq("  and the showcase gives the interface back", Cam.uiHidden, false)
    eq("  and is on its way out, not left running", Cam.mode, "exit")
    eq("  with the sheet back under UIParent", sheet:GetParent(), UIParent)

    -- Showcase NOT hiding the UI: the sheet stays under UIParent, so the
    -- capture's own hide reaches it as a parent hide. That must not end the
    -- showcase, and the interface coming back must not replay the open.
    AltStableConfig.hideGameUIOnPresentation = false
    openSheet()
    check("with the UI left up, the sheet is under UIParent", sheet:GetParent() == UIParent)
    local enters = 0
    local realEnter = Cam.Enter
    Cam.Enter = function(self, ...) enters = enters + 1; return realEnter(self, ...) end
    P.Capture()
    check("  a capture hides the interface", not UIParent:IsShown())
    check("  and the showcase survives the sheet losing its parent", Cam.active and Cam.mode ~= "exit")
    P.AbandonCapture(nil, true)                 -- cancel, the watchdog, death
    check("  the interface is back", UIParent:IsShown())
    eq("  and coming back did not re-enter the showcase", enters, 0)
    check("  the sheet is still open", sheet:IsShown())

    -- CLOSED while the capture has UIParent down: the sheet was not visible,
    -- so the client fires no OnHide at all. The close still has to end the
    -- showcase, and must not leave the next open swallowed.
    P.Capture()
    check("  a second capture has the interface down", not UIParent:IsShown())
    local realOnHide = sheet:GetScript("OnHide")
    sheet:SetScript("OnHide", nil)              -- what the client does here
    sheet:Hide()
    sheet:SetScript("OnHide", realOnHide)
    eq("closing it mid-capture still ends the showcase", Cam.mode, "exit")
    P.AbandonCapture(nil, true)
    pcall(Cam.ForceRestore, Cam, "test")
    Cam.active, Cam.mode = false, nil
    enters = 0
    AltStable.EnsureSheetVisible()
    eq("  and the next open is a real one", enters, 1)
    Cam.Enter = realEnter

    AltStableConfig.hideGameUIOnPresentation = nil
    sheet:Hide()
    pcall(Cam.ForceRestore, Cam, "test")
    AltStableConfig.enableWorldCameraPresentation = nil
end

------------------------------------------------------------
-- The capture button glows when a new portrait is due (#128)
------------------------------------------------------------

do
    local btn, glow, txt = AltStable._test.refBtn, AltStable._test.refGlow, AltStable._test.refTipText
    check("the capture button and its glow exist", btn ~= nil and glow ~= nil and AltStable.UpdateCaptureGlow ~= nil)
    if btn and glow and AltStable.UpdateCaptureGlow then
        local function tipText() return txt and txt:GetText() or "" end
        WoW.inCombat = false
        AltStableConfig.portraitGlow = nil
        AltStable.UpdateCaptureGlow({ due = true, reason = "missing", changedSlots = {} })
        check("a due capture makes the button glow", btn._glowing == true and glow:IsShown())
        check("  and the tooltip says why", tipText():find("No portrait", 1, true), tipText())

        AltStable.UpdateCaptureGlow({ due = true, reason = "changed", changedSlots = { "Chest", "Legs" } })
        check("changed gear names the slots in the tooltip", tipText():find("Chest, Legs", 1, true), tipText())

        AltStable.UpdateCaptureGlow({ due = false, reason = "pending", changedSlots = {} })
        check("a capture waiting for the converter does not glow", btn._glowing == false and not glow:IsShown())
        check("  but the tooltip says it is waiting", tipText():find("waiting for AltStable Companion", 1, true), tipText())

        AltStable.UpdateCaptureGlow({ due = false, reason = "none", changedSlots = {} })
        check("with nothing to say, the tooltip is the plain one", not tipText():find("\n\n", 1, true))

        WoW.inCombat = true
        AltStable.UpdateCaptureGlow({ due = true, reason = "missing", changedSlots = {} })
        check("no glow in combat", btn._glowing == false and not glow:IsShown())
        WoW.inCombat = false
        AltStable.UpdateCaptureGlow({ due = true, reason = "missing", changedSlots = {} }, true)
        check("no glow when the caller says combat, before the lockdown has begun",
              btn._glowing == false and not glow:IsShown())
        AltStable.UpdateCaptureGlow({ due = true, reason = "missing", changedSlots = {} }, false)
        check("  and glowing again when it says combat is over", btn._glowing == true)

        -- The tooltip grows with its text: a long slot list is not cut off.
        local tip = AltStable._test.refTip
        local realH = txt.GetStringHeight
        txt.GetStringHeight = function() return 140 end
        AltStable.UpdateCaptureGlow({ due = true, reason = "changed",
            changedSlots = { "Head", "Shoulder", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands" } })
        check("the tooltip is as tall as its text", tip:GetHeight() >= 140, tostring(tip:GetHeight()))
        txt.GetStringHeight = realH

        AltStableConfig.portraitGlow = false
        AltStable.UpdateCaptureGlow({ due = true, reason = "missing", changedSlots = {} })
        check("no glow when switched off", btn._glowing == false and not glow:IsShown())
        check("  the tooltip still says a capture is due", tipText():find("No portrait", 1, true))
        AltStableConfig.portraitGlow = nil
        AltStable.UpdateCaptureGlow({ due = false, reason = "none", changedSlots = {} })
    end
end

------------------------------------------------------------
-- "<name> asks to sync with you" (#61)
------------------------------------------------------------
do
    local POP = AltStable._test.SyncAskPopup
    local core = AltStable._test.CoreFrame
    local onCoreEvent = core:GetScript("OnEvent")
    local function ask(who)
        onCoreEvent(core, "CHAT_MSG_ADDON", AltStable._test.PREFIX,
                    AltStable._test.MSG_REQUEST_V .. "|0", "WHISPER", who)
    end
    local function flush()
        for _ = 1, 10 do if #WoW.timers == 0 then break end WoW.flushTimers() end
    end
    local function asks()
        local out = {}
        for _, p in ipairs(WoW.popups) do
            if p.which == POP and p.dialog:IsShown() then out[#out + 1] = p end
        end
        return out
    end
    -- The client's order: the button's handler, then the dialog hides. Escape
    -- is OnCancel (hideOnEscape), exactly like the middle button.
    local function press(p, handler)
        local def = StaticPopupDialogs[POP]
        if def[handler] then def[handler](p.dialog, p.data, "clicked") end
        StaticPopup_Hide(POP)
        flush()
    end
    local function fresh()
        WoW.reset(); AltStable._test.ResetSyncState(); AltStable._test.ResetSyncPrompts()
        AltStableConfig = { peerWatermarks = {} }
        AltStable.EnsureSheetVisible()
    end

    fresh()
    ask("Asker Surname")
    local shown = asks()
    eq("a stranger asking raises the prompt", #shown, 1)
    local p = shown[1]
    if p then
        eq("  naming them", p.arg1, "Asker Surname")
        eq("  with three answers", StaticPopupDialogs[POP].button3, "Never")
        ask("Asker Surname")
        eq("  and asking again does not raise a second one", #asks(), 1)

        -- Escape is "Not now": nothing refused, still waiting.
        press(p, "OnCancel")
        eq("Escape (or Not now) refuses nobody",
           AltStable.SyncAuthFor("Asker Surname"), AltStable.AUTH_ASK)
        eq("  the request is still waiting", #AltStable.PendingSyncRequests(), 1)
        ask("Asker Surname")
        eq("  and they are not prompted again this session", #asks(), 0)
    end

    -- Never, from the third button.
    fresh()
    ask("Rude Surname")
    p = asks()[1]
    if p then
        press(p, "OnAlt")
        eq("Never refuses them for good", AltStable.SyncAuthFor("Rude Surname"), AltStable.AUTH_NEVER)
    end

    -- Allow serves them.
    fresh()
    ask("Kind Surname")
    p = asks()[1]
    if p then
        WoW.sent = {}
        press(p, "OnAccept")
        eq("Allow approves them", AltStable.SyncAuthFor("Kind Surname"), AltStable.AUTH_AUTO)
        -- DATA, not just traffic: the request Allow sends back is traffic too.
        local chunks = 0
        for _, m in ipairs(WoW.sent) do
            if m.target == "Kind Surname"
                and m.text:sub(1, #AltStable._test.MSG_CHUNK_V) == AltStable._test.MSG_CHUNK_V then
                chunks = chunks + 1
            end
        end
        check("  and serves what they asked", chunks > 0)
    end

    -- One at a time, the next after the first is answered.
    fresh()
    ask("First Surname")
    WoW.now = WoW.now + 1
    ask("Second Surname")
    eq("two askers: one prompt at a time", #asks(), 1)
    p = asks()[1]
    eq("  the first to ask first", p and p.arg1, "First Surname")
    if p then
        press(p, "OnCancel")
        local nxt = asks()[1]
        eq("  then the next", nxt and nxt.arg1, "Second Surname")
    end

    -- Answered elsewhere while the prompt is up: the stale question goes.
    fresh()
    ask("Slash Surname")
    check("a prompt is up", #asks() == 1)
    AltStable.AllowSyncPeer("Slash Surname")
    flush()
    eq("  answering by /alts allow takes it down", #asks(), 0)

    -- With the game UI hidden, putting the dialog back under UIParent runs its
    -- OnHide in the middle of the button's handler (the client's re-entrant
    -- hide, modelled as in the DropPopup test). The answer's announcement must
    -- not open the next asker's prompt inside the click, where the click's
    -- own closing hide dismisses it and that asker is never asked.
    for _, handler in ipairs({ "OnAccept", "OnAlt" }) do
        fresh()
        local realHidden = AltStable.IsGameUIHidden
        AltStable.IsGameUIHidden = function() return true end
        UIParent:Hide()
        ask("Front Surname")
        WoW.now = WoW.now + 1
        ask("Queued Surname")
        p = asks()[1]
        if p then
            local d = p.dialog
            local realSetParent = d.SetParent
            d.SetParent = function(self, parent)
                local r = realSetParent(self, parent)
                if parent == UIParent then StaticPopupDialogs[POP].OnHide(self) end
                return r
            end
            press(p, handler)
            d.SetParent = realSetParent
            local nxt = asks()[1]
            eq(handler .. " with the UI hidden: the next asker is still asked",
               nxt and nxt.arg1, "Queued Surname")
        end
        UIParent:Show()
        AltStable.IsGameUIHidden = realHidden
    end

    -- Pressed away while hidden: the client hides a dialog that is not
    -- visible without running OnHide. The slot must still come free.
    fresh()
    ask("Hidden Surname")
    p = asks()[1]
    if p then
        StaticPopupDialogs[POP].OnCancel(p.dialog, p.data, "clicked")
        p.dialog:Hide()                      -- no OnHide, as on the client
        flush()
        ask("After Surname")
        local nxt = asks()[1]
        eq("a prompt dismissed without OnHide still frees the slot", nxt and nxt.arg1, "After Surname")
    end

    -- A waiting request expiring as the next one arrives shows ONE prompt.
    fresh()
    ask("Expiring Surname")
    p = asks()[1]
    if p then press(p, "OnCancel") end
    WoW.now = WoW.now + 301
    ask("Fresh Surname")
    eq("an expiry while choosing the next asker shows one prompt, not two", #asks(), 1)

    -- Served through /alts sync consent while the prompt is up: the question
    -- is answered, so it goes.
    fresh()
    ask("Consent Surname")
    check("a prompt is up for them", #asks() == 1)
    SlashCmdList["ALTSTABLE"]("sync Consent Surname")
    ask("Consent Surname")                    -- served now: we named them
    flush()
    eq("  serving them through /alts sync takes the stale prompt down", #asks(), 0)

    -- Not in combat; after it.
    fresh()
    WoW.inCombat = true
    ask("Combat Surname")
    eq("no prompt in combat", #asks(), 0)
    WoW.inCombat = false
    local regen = AltStable._test.SyncAskRegenFrame
    regen:GetScript("OnEvent")(regen, "PLAYER_REGEN_ENABLED")
    eq("  it comes when combat ends", #asks(), 1)

    -- A refused show is not counted as asked.
    fresh()
    WoW.popupRefused = true
    ask("Unlucky Surname")
    eq("the client refusing the dialog shows nothing", #asks(), 0)
    eq("  and refuses nobody", AltStable.SyncAuthFor("Unlucky Surname"), AltStable.AUTH_ASK)
    WoW.popupRefused = nil
    AltStable.OnSyncAuthChanged()
    eq("  so the next chance still asks", #asks(), 1)

    ------------------------------------------------------------
    -- Options: requests and answers
    ------------------------------------------------------------
    fresh()
    -- Open, so the list redraws itself on each change as it would on screen:
    -- the point is that a request arriving with Options open shows up.
    local panel = AltStable._test.optionsPanel
    panel:Show()
    AltStable.DenySyncPeer("Foe Surname")
    AltStable.AllowSyncPeer("Pal Surname")
    ask("Waiter Surname")
    local rows = AltStable._test.SyncAuthRows
    check("Options has the requests-and-answers rows", type(rows) == "table")
    if rows then
        local function rowFor(name)
            for _, r in ipairs(rows) do
                if (r.label:GetText() or ""):find(name, 1, true) then return r end
            end
        end
        local foe, pal, waiter = rowFor("foe surname"), rowFor("pal surname"), rowFor("Waiter Surname")
        check("  a refused peer is listed", foe and foe.label:GetText():find("never", 1, true))
        check("  an allowed peer is listed", pal and pal.label:GetText():find("allowed", 1, true))
        check("  a waiting request is listed, without a restart",
              waiter and waiter.label:GetText():find("waiting", 1, true))
        if waiter then
            eq("  waiting: Allow / Never", waiter.first.label:GetText() .. "/"
               .. waiter.second.label:GetText(), "Allow/Never")
            waiter.second:GetScript("OnClick")()
            eq("  Never from the list refuses them",
               AltStable.SyncAuthFor("Waiter Surname"), AltStable.AUTH_NEVER)
        end
        if pal then
            eq("  allowed: Never / Forget", pal.first.label:GetText() .. "/"
               .. pal.second.label:GetText(), "Never/Forget")
            pal.second:GetScript("OnClick")()
            eq("  Forget from the list clears the answer",
               AltStable.SyncAuthFor("Pal Surname"), AltStable.AUTH_ASK)
            check("  and the list redraws without it", rowFor("pal surname") == nil)
        end
    end
    panel:Hide()
end

-- The Portrait angle slider (#149): 5-degree steps, through the shared setter,
-- Reset to the default, and Options shows what is saved.
do
    local slider, reset = AltStable._test.FacingSlider, AltStable._test.FacingReset
    check("Options has the Portrait angle slider", slider ~= nil and reset ~= nil)
    if slider and reset then
        local savedP = AltStablePortraits
        AltStablePortraits = nil
        slider:GetScript("OnValueChanged")(slider, 12.4)
        eq("the slider stores the angle, to 5 degrees", AltStable.GetPortraitFacing(), 10)
        slider:GetScript("OnValueChanged")(slider, -80)
        eq("  within -45..45", AltStable.GetPortraitFacing(), -45)
        reset:GetScript("OnClick")(reset)
        eq("Reset goes back to straight on", AltStable.GetPortraitFacing(), 0)
        AltStable.SetPortraitFacing(25)              -- as /alts portrait facing 25 does
        -- A slider that behaves like the client's: SetValue fires OnValueChanged.
        local shownValue
        local realSet = slider.SetValue
        slider.SetValue = function(self, v)
            shownValue = v
            self:GetScript("OnValueChanged")(self, v)
            return self
        end
        local optPanel = AltStable._test.optionsPanel
        optPanel:GetScript("OnShow")(optPanel)
        eq("opening Options shows the saved angle", shownValue, 25)

        -- Opening Options writes nothing: no store appears for an account that
        -- never captured.
        AltStablePortraits = nil
        optPanel:GetScript("OnShow")(optPanel)
        eq("opening Options creates no portrait store", AltStablePortraits, nil)
        -- Nor rounds an angle the command set between steps.
        AltStablePortraits = { version = 1, renders = {}, facing = 12 }
        optPanel:GetScript("OnShow")(optPanel)
        eq("  nor rewrites an off-step angle", AltStablePortraits.facing, 12)

        -- A drag writes only when the rounded angle changes.
        local writes = 0
        local realSetF = AltStable.SetPortraitFacing
        AltStable.SetPortraitFacing = function(...) writes = writes + 1; return realSetF(...) end
        slider:GetScript("OnValueChanged")(slider, 10.2)
        slider:GetScript("OnValueChanged")(slider, 11.4)
        slider:GetScript("OnValueChanged")(slider, 9.1)
        eq("a drag inside one step writes once", writes, 1)
        AltStable.SetPortraitFacing = realSetF

        -- Refused (a newer AltStable's store): the slider shows what is stored.
        AltStablePortraits = { version = 99, renders = {}, facing = 5 }
        shownValue = nil
        slider:GetScript("OnValueChanged")(slider, 30)
        eq("a refused write snaps the slider back", shownValue, 5)
        eq("  and the store is untouched", AltStablePortraits.facing, 5)

        -- The command, with Options open, moves the slider.
        AltStablePortraits = nil
        optPanel:Show()
        shownValue = nil
        AltStable.SetPortraitFacing(15)
        eq("the slider follows the command while Options is open", shownValue, 15)
        slider.SetValue = realSet
        AltStablePortraits = savedP
    end
end

------------------------------------------------------------
-- Compact sidebar and maximize (#150)
------------------------------------------------------------

do
    local T = AltStable._test
    local f = T.frame
    if not AltStableSheet:IsShown() then AltStable.ShowSheet() end
    -- The opening fade owns the scale for its length; measure at the real one.
    AltStable.FinishOpenAnimation()
    local sidebar = f.sidebar
    check("the sidebar is reachable from the window", sidebar ~= nil)

    -- A plugin tab that counts its re-layouts.
    local resized, activated = 0, 0
    AltStable.RegisterPlugin({
        id = "test150", label = "Test 150", _isPlugin = true,
        OnActivate = function() activated = activated + 1 end,
        OnResize = function() resized = resized + 1 end,
    })
    local pbtn, sheetBtn
    for _, b in ipairs(T.sidebarBtns) do
        if b.sectionId == "test150" then pbtn = b end
        if not sheetBtn and b.sectionId ~= "options" and b.sectionId ~= "test150" then sheetBtn = b end
    end
    check("the test plugin got a sidebar button", pbtn ~= nil)

    -- Instant first: the animation has its own block at the end.
    local savedAnim = AltStableConfig.enableOpenAnimation
    AltStableConfig.enableOpenAnimation = false

    -- Starts full, from the default.
    AltStableConfig.sidebarCompact = false
    eq("the sidebar starts full width", AltStable.LAYOUT.SIDEBAR_WIDTH, 230)
    -- Set at build from the saved setting, not only on a click.
    eq("  with the chevron showing collapse, >>", T.chevronText:GetText(), "\194\187")

    -- What sits beside the sidebar is anchored to its edge, not the window.
    local probe = CreateFrame("Frame", nil, f)
    check("a panel can anchor beside the sidebar", AltStable.AnchorBesideSidebar(probe, f))
    local pt, rel, relPt, x, y = probe:GetPoint(1)
    check("  to the sidebar's top-right, 1px past it",
          pt == "TOPLEFT" and rel == sidebar and relPt == "TOPRIGHT" and x == 1 and y == 0,
          table.concat({ tostring(pt), tostring(relPt), tostring(x), tostring(y) }, " "))
    local optPt, optRel = T.optionsPanel:GetPoint(1)
    check("the Options panel follows the sidebar", optRel == sidebar, tostring(optPt))
    local _, totRel = f.totalsBar:GetPoint(1)
    check("so does the totals bar", totRel == sidebar)
    local _, fhRel, _, _, fhY = f.frozenHeader:GetPoint(1)
    check("and the Name column header, at the same height as before",
          fhRel == sidebar and fhY == -4, tostring(fhY))

    -- Collapse, from a sheet tab: the labels go, the window narrows by the
    -- width given back, and the setting is saved.
    sheetBtn:GetScript("OnClick")(sheetBtn)
    local fullW = f:GetWidth()
    T.chevron:GetScript("OnClick")(T.chevron)
    eq("the chevron collapses the sidebar", AltStableConfig.sidebarCompact, true)
    eq("  to icons only", AltStable.LAYOUT.SIDEBAR_WIDTH, 56)
    eq("  the frame itself", sidebar:GetWidth(), 55)
    check("  with every label hidden", (function()
        for _, b in ipairs(T.sidebarBtns) do if b.lbl:IsShown() then return false end end
        return true end)())
    eq("a sheet tab's window narrows by what the sidebar gave back", f:GetWidth(), fullW - 174)
    -- The grid hangs off the sidebar's edge, so it slides while the sidebar animates.
    local _, bodyRel = f.bodyScroll:GetPoint(1)
    check("the grid is anchored to the sidebar's edge", bodyRel == sidebar)
    local _, hdrRel = f.headerScroll:GetPoint(1)
    check("  and so are its column headers", hdrRel == sidebar)
    eq("a compact sidebar's chevron shows expand, <<", T.chevronText:GetText(), "\194\171")

    -- Compact, each label is its button's tooltip.
    sheetBtn:GetScript("OnEnter")(sheetBtn)
    check("a compact button's label shows as its tooltip", GameTooltip:IsOwned(sheetBtn))
    sheetBtn:GetScript("OnLeave")(sheetBtn)
    check("  and goes with the mouse", not GameTooltip:IsOwned(sheetBtn))

    -- A plugin arriving late joins a compact sidebar compact.
    AltStable.RegisterPlugin({ id = "test150late", label = "Late", _isPlugin = true,
                               OnActivate = function() end })
    local late = T.sidebarBtns[#T.sidebarBtns]
    check("a late plugin's label is hidden in a compact sidebar", not late.lbl:IsShown())

    -- On a plugin tab the window keeps its size and the plugin re-lays out.
    pbtn:GetScript("OnClick")(pbtn)
    local plugW = f:GetWidth()
    resized = 0
    AltStable.SetSidebarCompact(false)
    eq("expanding re-lays out the plugin tab", resized, 1)
    eq("  in a window that kept its size", f:GetWidth(), plugW)
    check("  with the labels back", pbtn.lbl:IsShown())
    AltStable.SetSidebarCompact(false)
    eq("setting what is already set does nothing", resized, 1)
    sheetBtn:GetScript("OnEnter")(sheetBtn)
    check("a full sidebar shows no tooltip - the label is right there",
          not GameTooltip:IsOwned(sheetBtn))
    sheetBtn:GetScript("OnLeave")(sheetBtn)

    -- MAXIMIZE. The whole display less the margin, centred.
    local limW = (UIParent:GetWidth() * UIParent:GetEffectiveScale()) / f:GetEffectiveScale() - T.SCREEN_MARGIN
    local limH = (UIParent:GetHeight() * UIParent:GetEffectiveScale()) / f:GetEffectiveScale() - T.SCREEN_MARGIN
    sheetBtn:GetScript("OnClick")(sheetBtn)
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)
    local beforeW, beforeH = f:GetWidth(), f:GetHeight()
    local glyphMax, glyphRestore = T.MaxGlyphs()
    check("the button shows maximize", glyphMax[1]:IsShown() and not glyphRestore[1]:IsShown())
    T.maxBtn:GetScript("OnClick")(T.maxBtn)
    check("the button maximizes", AltStable.IsWindowMaximized())
    eq("  to the display's width", f:GetWidth(), limW)
    eq("  and height", f:GetHeight(), limH)
    local mp, mrel, mrp, mx, my = f:GetPoint(1)
    check("  centred", mp == "CENTER" and mrp == "CENTER" and mx == 0 and my == 0)
    check("  and the button now shows restore", glyphRestore[1]:IsShown() and not glyphMax[1]:IsShown())

    -- Sticky: switching tabs keeps it maximized, sheet or plugin.
    pbtn:GetScript("OnClick")(pbtn)
    eq("a plugin tab stays maximized", f:GetWidth(), limW)
    T.ResizeFrame(820, 760)                      -- what Options asks for
    eq("  a fixed request does not un-maximize it", f:GetHeight(), limH)
    AltStable.RequestWindowSize(600, 400)        -- what Raids asks for
    eq("  nor does a plugin sizing to its content", f:GetWidth(), limW)
    sheetBtn:GetScript("OnClick")(sheetBtn)
    eq("a sheet tab stays maximized", f:GetHeight(), limH)
    -- Collapsing the sidebar while maximized keeps it maximized.
    AltStable.SetSidebarCompact(true)
    eq("  through a collapse", f:GetWidth(), limW)
    AltStable.SetSidebarCompact(false)

    -- Not draggable while maximized: the position Restore goes back to is the
    -- one it had, and a drag would save the centred one over it.
    local moved = false
    local realMove = f.StartMoving
    f.StartMoving = function() moved = true end
    local savedPos = AltStableConfig.windowPosition
    T.titleBar:GetScript("OnDragStart")(T.titleBar)
    T.titleBar:GetScript("OnDragStop")(T.titleBar)
    check("a maximized window does not drag", not moved)
    eq("  nor saves its centred position", AltStableConfig.windowPosition, savedPos)
    f.StartMoving = realMove

    -- RESTORE: the size the current tab wants, where it was.
    pbtn:GetScript("OnClick")(pbtn)
    AltStable.RequestWindowSize(600, 400)
    -- A floor asked for while maximized goes on the REQUEST, or Restore would
    -- restore to full screen.
    AltStable.EnsureWindowMinSize(700, 450)
    eq("a floor while maximized leaves it maximized", f:GetWidth(), limW)
    resized = 0
    T.maxBtn:GetScript("OnClick")(T.maxBtn)
    check("the button restores", not AltStable.IsWindowMaximized())
    eq("  re-laying out the plugin tab", resized, 1)
    local rp, rrel, rrp, rx, ry = f:GetPoint(1)
    check("  back where it was", rp == "TOPLEFT" and rx == 50 and ry == -60,
          tostring(rp) .. " " .. tostring(rx) .. " " .. tostring(ry))
    check("  at the size last asked for, raised to the floor, not the screen's",
          f:GetWidth() == 700 and f:GetHeight() == 450, f:GetWidth() .. "x" .. f:GetHeight())
    sheetBtn:GetScript("OnClick")(sheetBtn)
    eq("a sheet tab is back to its own width", f:GetWidth(), beforeW)
    eq("  and height", f:GetHeight(), beforeH)
    AltStable.SetWindowMaximized(false)
    check("restoring a restored window changes nothing", f:GetPoint(1) == "TOPLEFT")

    -- Scale while maximized re-maximizes in the new units.
    AltStable.SetWindowMaximized(true)
    AltStable.SetScale(1.25)
    local limW2 = (UIParent:GetWidth() * UIParent:GetEffectiveScale()) / f:GetEffectiveScale() - T.SCREEN_MARGIN
    eq("scaling a maximized window keeps it filling the display", f:GetWidth(), limW2)
    AltStable.SetScale(1.0)
    AltStable.SetWindowMaximized(false)

    -- ...and re-lays the tab out in its new size (#157 review): a plugin tab.
    pbtn:GetScript("OnClick")(pbtn)
    AltStable.SetWindowMaximized(true)
    resized = 0
    AltStable.SetScale(1.25)
    eq("a scale change while maximized re-lays out the tab", resized, 1)
    AltStable.SetScale(1.0)
    AltStable.SetWindowMaximized(false)
    resized = 0
    AltStable.SetScale(1.25)
    eq("  but not when the window is not maximized", resized, 0)
    AltStable.SetScale(1.0)

    -- The maximized position is never saved, and a reset while maximized is
    -- where Restore goes (#157 review).
    AltStableConfig.rememberWindowPosition = true
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)
    AltStable.SetConfigValue("windowPosition", { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 50, y = -60 })
    AltStable.SetWindowMaximized(true)
    T.titleBar:GetScript("OnDragStop")(T.titleBar)
    eq("a maximized window does not save its centred position", AltStableConfig.windowPosition.x, 50)
    AltStable.ResetWindowPosition()
    eq("  a reset while maximized clears the saved one", AltStableConfig.windowPosition, nil)
    eq("  and leaves the window maximized and centred", (f:GetPoint(1)), "CENTER")
    AltStable.SetWindowMaximized(false)
    eq("  so Restore goes to the reset position, centred", (f:GetPoint(1)), "CENTER")
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)

    -- Measured at the scale the window settles at, not the open fade's 96%:
    -- reopening a maximized window used to come out 4% larger than the screen.
    AltStable.SetWindowMaximized(true)
    local settledW = f:GetWidth()
    AltStableConfig.enableOpenAnimation = true
    AltStable._PlayOpenAnimation(f)
    AltStable.RefitWindow()
    eq("a maximized window refitted during the open fade keeps the settled size", f:GetWidth(), settledW)
    AltStable.FinishOpenAnimation()
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetWindowMaximized(false)

    -- A plugin that sizes the window in its re-layout: that size is the one
    -- the window ends at, animated or not, and laid out before the trip.
    local sizer = { asked = nil }
    local sizerPlugin = {
        id = "test150sizer", label = "Sizer", _isPlugin = true, sizesWindow = true,
        OnActivate = function() end,
        OnResize = function()
            sizer.calls = (sizer.calls or 0) + 1
            AltStable.RequestWindowSize(sizer.w, 500)
        end,
    }
    AltStable.RegisterPlugin(sizerPlugin)
    local sizerBtn = T.sidebarBtns[#T.sidebarBtns]
    sizerBtn:GetScript("OnClick")(sizerBtn)
    sizer.w = 640
    AltStable.SetSidebarCompact(true)
    sizer.calls = 0
    AltStableConfig.enableOpenAnimation = true
    AltStable.SetSidebarCompact(false)          -- its space shrinks: the plugin asks for more
    local r = T.WindowAnimRunner()
    eq("a self-sizing plugin is laid out before the trip", sizer.calls, 1)
    sizer.w = 820
    AltStable.SetSidebarCompact(true)           -- grows: laid out first all the same
    eq("  whichever way it goes", sizer.calls, 2)
    local fn = r:GetScript("OnUpdate"); if fn then fn(r, 0.3) end
    eq("  and the window ends at the size it asked for", f:GetWidth(), 820)
    -- A plugin that only HOLDS a floor (Warband) is laid out before a trip
    -- that shrinks its space, and the window ends at what that asked for.
    sizerPlugin.sizesWindow = nil
    sizer.w = 900
    AltStable.SetSidebarCompact(false)          -- shrinks its space: laid out first
    fn = r:GetScript("OnUpdate"); if fn then fn(r, 0.3) end
    eq("a floor asked for before a shrinking trip is where it ends", f:GetWidth(), 900)
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetSidebarCompact(false)

    -- THE GRID FILLS A WIDER WINDOW: spare width is shared out across the
    -- columns, in proportion to their own widths. The stub's viewport does not
    -- follow anchors, so it is set to the width the window would give it.
    sheetBtn:GetScript("OnClick")(sheetBtn)
    local cols, hdrs, hdrDivs, rows = T.ColumnLayout()
    local own, ownSum = {}, 0
    for i, c in ipairs(cols) do own[i] = c.width; ownSum = ownSum + c.width end
    local natural = 10 + ownSum + 6 * #cols
    local body = f.bodyScroll
    local realBodyW = body.GetWidth
    body.GetWidth = function() return natural + 300 end
    AltStable.RefreshSheet()
    local widths = T.ColumnWidths()
    local spread = 0
    for i = 1, #cols do spread = spread + widths[i] - own[i] end
    eq("a wider window's spare width all goes to the columns", spread, 300)
    check("  shared in proportion: the widest column gains the most", (function()
        local wi, ni = 1, 1
        for i = 1, #cols do
            if own[i] > own[wi] then wi = i end
            if own[i] < own[ni] then ni = i end
        end
        return widths[wi] - own[wi] > widths[ni] - own[ni]
    end)())
    check("  never narrower than its own", (function()
        for i = 1, #cols do if widths[i] < own[i] then return false end end
        return true end)())
    -- The headers and the cells are where those widths put them.
    local x2 = 10 + widths[1] + 6
    local _, _, _, hx = hdrs[2]:GetPoint(1)
    eq("the second header starts after the first's spread width", hx, x2)
    eq("  and is as wide as its column now is", hdrs[2]:GetWidth(), widths[2])
    local _, _, _, dx = hdrDivs[1]:GetPoint(1)
    eq("  with the divider in the gap", dx, 10 + widths[1] + 3)
    check("there are rows to measure", rows[1] ~= nil)
    local _, _, _, cx = rows[1].cells[2]:GetPoint(1)
    eq("a row's second cell lines up with its header", cx, x2)
    eq("  as wide", rows[1].cells[2]:GetWidth(), widths[2])
    local _, _, _, rdx = rows[1].dividers[1]:GetPoint(1)
    eq("  and its divider with the header's", rdx, 10 + widths[1] + 3)
    local _, _, _, _, bodyC, hdrC = T.ColumnLayout()
    eq("the rows' surface spans the spread columns", bodyC:GetWidth(), natural + 300)
    eq("  as does the header's", hdrC:GetWidth(), natural + 300)
    -- A row already at these widths is left alone: a refresh with nothing
    -- changed re-places nothing.
    local placed = 0
    local cell = rows[1].cells[2]
    local realClear = cell.ClearAllPoints
    cell.ClearAllPoints = function(self) placed = placed + 1; return realClear(self) end
    AltStable.RefreshSheet()
    eq("an unchanged layout re-places no cell", placed, 0)
    cell.ClearAllPoints = realClear
    -- Whole pixels, the rounding shared a pixel at a time (#157 review).
    body.GetWidth = function() return natural + 300.5 end
    AltStable.RefreshSheet()
    widths = T.ColumnWidths()
    local total, whole, fair = 0, true, true
    for i = 1, #cols do
        local add = widths[i] - own[i]
        total = total + add
        if add ~= math.floor(add) then whole = false end
        local share = math.floor(300 * own[i] / ownSum)
        if add < share or add > share + 1 then fair = false end
    end
    eq("a fractional viewport spreads whole pixels only", total, 300)
    local _, _, _, _, bodyF = T.ColumnLayout()
    eq("  and the grid's width is whole too", bodyF:GetWidth(), natural + 300)
    -- A new row places its own cells, at the columns' own widths.
    local fresh = AltStable.CreateRow(CreateFrame("Frame"), 22, cols)
    local _, _, _, fx = fresh.cells[2]:GetPoint(1)
    eq("a new row places its own cells", fx, 10 + own[1] + 6)
    check("  each column a whole number", whole)
    check("  and no column more than a pixel over its share", fair)
    -- When the window fits the columns again, they go back to their own.
    body.GetWidth = function() return natural + 2 end
    AltStable.RefreshSheet()
    widths = T.ColumnWidths()
    check("a window that fits its columns lays them at their own widths", (function()
        for i = 1, #cols do if widths[i] ~= own[i] then return false end end
        return true end)())
    local _, _, _, cx2 = rows[1].cells[2]:GetPoint(1)
    eq("  cells too", cx2, 10 + own[1] + 6)
    -- And a grid that scrolls is never stretched.
    body.GetWidth = function() return natural - 100 end
    AltStable.RefreshSheet()
    eq("a scrolling grid keeps its own widths", T.ColumnWidths()[1], own[1])
    body.GetWidth = realBodyW
    AltStable.RefreshSheet()

    -- ANIMATED: the change lands at once (state, setting, layout), the
    -- window travels there, and settles exactly on the end state.
    AltStableConfig.enableOpenAnimation = true
    sheetBtn:GetScript("OnClick")(sheetBtn)
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)
    local startW = f:GetWidth()
    AltStable.SetSidebarCompact(true)
    local runner = T.WindowAnimRunner()
    local tick = function(dt) local fn = runner:GetScript("OnUpdate"); if fn then fn(runner, dt) end end
    check("collapsing animates", runner and runner:GetScript("OnUpdate") ~= nil)
    eq("  the setting is saved at once", AltStableConfig.sidebarCompact, true)
    eq("  and the sidebar starts from where it was", sidebar:GetWidth(), 229)
    eq("  as does the window", f:GetWidth(), startW)
    check("  without clipping its children", not f:DoesClipChildren())
    tick(0.1)
    check("half way, the sidebar is between", sidebar:GetWidth() < 229 and sidebar:GetWidth() > 55,
          tostring(sidebar:GetWidth()))
    check("  and so is the window", f:GetWidth() < startW and f:GetWidth() > startW - 174,
          tostring(f:GetWidth()))
    check("  the labels fading", sheetBtn.lbl:IsShown() and sheetBtn.lbl:GetAlpha() < 1,
          tostring(sheetBtn.lbl:GetAlpha()))
    tick(0.2)
    check("then it stops", runner:GetScript("OnUpdate") == nil)
    eq("  on the compact sidebar", sidebar:GetWidth(), 55)
    eq("  in the narrowed window", f:GetWidth(), startW - 174)
    check("  with the labels gone, at full alpha for next time",
          not sheetBtn.lbl:IsShown() and sheetBtn.lbl:GetAlpha() == 1)
    local ep, _, _, ex, ey = f:GetPoint(1)
    check("  anchored where it really is, not at the travelling anchor",
          ep == "TOPLEFT" and ex == 50 and ey == -60, tostring(ep))
    check("  and never clips its children: the client clips against a stale rect mid-resize", not f:DoesClipChildren())

    -- Clicked again half way: it goes back from where it is.
    AltStable.SetSidebarCompact(false)
    tick(0.05)
    AltStable.SetSidebarCompact(true)
    check("a reversal travels from mid-way", sidebar:GetWidth() > 55 and sidebar:GetWidth() < 229,
          tostring(sidebar:GetWidth()))
    tick(0.3)
    eq("  and lands on the latest choice", sidebar:GetWidth(), 55)
    eq("  in the window that choice wants", f:GetWidth(), startW - 174)

    -- Maximize travels too, and lands maximized, centred.
    AltStable.SetWindowMaximized(true)
    check("maximizing animates", runner:GetScript("OnUpdate") ~= nil)
    check("  from the window's size", f:GetWidth() == startW - 174)
    tick(0.3)
    eq("  to the display's", f:GetWidth(), limW)
    local cp = f:GetPoint(1)
    eq("  centred", cp, "CENTER")
    AltStable.SetWindowMaximized(false)
    tick(0.3)
    local bp, _, _, bx = f:GetPoint(1)
    check("and restoring lands back where it was", bp == "TOPLEFT" and bx == 50)

    -- A PLUGIN tab is laid out once, at the moment its layout fits inside
    -- the travelling window: at the end when its space grows, at the start
    -- when it shrinks. Nothing clips it in between.
    pbtn:GetScript("OnClick")(pbtn)
    resized = 0
    AltStable.SetWindowMaximized(true)
    eq("growing: the plugin keeps its old layout on the way", resized, 0)
    tick(0.1)
    eq("  still", resized, 0)
    tick(0.2)
    eq("  and lays out once it has arrived", resized, 1)
    resized = 0
    AltStable.SetWindowMaximized(false)
    eq("shrinking: the plugin lays out before the trip", resized, 1)
    tick(0.3)
    eq("  and not again at the end", resized, 1)
    -- Interrupted while growing: the deferred layout still happens, once.
    resized = 0
    AltStable.SetWindowMaximized(true)
    tick(0.05)
    AltStable.SetWindowMaximized(false)
    tick(0.3)
    eq("an interrupted grow still lays out, and the shrink once more", resized, 2)
    check("the window never clipped through any of it", not f:DoesClipChildren())
    sheetBtn:GetScript("OnClick")(sheetBtn)

    -- THE REPORTED CASE: restore, then switch tab inside the trip. The tab's
    -- own size must win - the trip used to settle on the size and anchors it
    -- measured before the switch, over the top of it.
    local sheetW = f:GetWidth()
    pbtn:GetScript("OnClick")(pbtn)
    AltStable.RequestWindowSize(640, 480)        -- a plugin's own size
    AltStable.SetWindowMaximized(true)
    tick(0.3)
    AltStable.SetWindowMaximized(false)
    tick(0.05)                                   -- mid-way back
    local midW = f:GetWidth()
    sheetBtn:GetScript("OnClick")(sheetBtn)      -- switch, mid-trip
    -- Since #159 a tab switch glides too: the old trip is settled and a new
    -- one starts from where the window IS, heading for the new tab's size.
    check("switching tab mid-trip travels on", runner:GetScript("OnUpdate") ~= nil)
    eq("  from where the window is", f:GetWidth(), midW)
    tick(0.3)
    eq("  and the new tab's size stands", f:GetWidth(), sheetW)
    local sp, _, _, sx = f:GetPoint(1)
    check("  where the window really is", sp == "TOPLEFT" and sx == 50, tostring(sp))
    -- And a tab sizing itself mid-trip ends it the same way.
    pbtn:GetScript("OnClick")(pbtn)
    AltStable.SetSidebarCompact(false)
    tick(0.05)
    AltStable.RequestWindowSize(700, 500)
    check("a tab sizing itself ends the trip", runner:GetScript("OnUpdate") == nil)
    tick(0.3)
    eq("  and its size stands", f:GetWidth(), 700)
    -- Switching TO a plugin tab mid-trip ends it too.
    AltStable.SetSidebarCompact(true)
    tick(0.05)
    local compactW = f:GetWidth()
    pbtn:GetScript("OnClick")(pbtn)
    check("switching to a plugin tab mid-trip travels on from where it is",
          runner:GetScript("OnUpdate") ~= nil and f:GetWidth() == compactW)
    tick(0.3)
    -- And data arriving mid-trip on a sheet tab: its re-sizing ends it.
    sheetBtn:GetScript("OnClick")(sheetBtn)
    AltStable.SetSidebarCompact(false)
    tick(0.05)
    AltStable.RefreshSheet()
    check("a refresh mid-trip ends it", runner:GetScript("OnUpdate") == nil)
    AltStable.SetSidebarCompact(true)
    tick(0.3)
    -- Starts where it was, not already at the end.
    local beforeTrip = f:GetWidth()
    AltStable.SetWindowMaximized(true)
    eq("a trip starts from the window as it was", f:GetWidth(), beforeTrip)
    tick(0.3)
    AltStable.SetWindowMaximized(false)
    tick(0.3)

    -- Turned off mid-way: the next change settles the running one and is instant.
    AltStable.SetSidebarCompact(false)
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetSidebarCompact(true)
    eq("with animation off, a change is instant", sidebar:GetWidth(), 55)
    check("  and nothing is left running", runner:GetScript("OnUpdate") == nil)

    AltStableConfig.enableOpenAnimation = savedAnim
    AltStable.SetSidebarCompact(false)
    AltStableConfig.sidebarCompact = false
end

------------------------------------------------------------
-- Options: the lists take only the room they use (#151)
------------------------------------------------------------

do
    local T = AltStable._test
    local flow = T.OptFlow
    local optPanel = T.optionsPanel
    check("the Options page records what sits below its lists", flow.items and #flow.items > 0)
    eq("three lists flow: peers, requests, hidden", #flow.lists, 3)

    local saved = { AltStableConfig.whitelist, AltStable.SyncAuthList,
                    AltStable.PendingSyncRequests, AltStable.HiddenCharacterList }
    local auth, hidden = {}, {}
    AltStable.SyncAuthList = function() return auth end
    AltStable.PendingSyncRequests = function() return {} end
    AltStable.HiddenCharacterList = function() return hidden end

    -- Where an item is now, against where the layout put it.
    local function ShiftOf(it)
        local _, _, _, _, y = it.o:GetPoint(1)
        return (y or 0) - (it.points[1][5] or 0)
    end
    local function Expected(it)
        local s = 0
        for _, list in ipairs(it.below) do s = s + (list.reserved - list.used) * 18 end
        return s
    end
    -- Every recorded anchor: a TOP edge on the page itself moves by the gaps
    -- above it; any other edge, or an anchor to a sibling, stays exactly as
    -- laid out (the sibling moves, and it follows).
    local function AllWhereExpected()
        for _, it in ipairs(flow.items) do
            for i, p in ipairs(it.points) do
                local point, rel, _, _, y0 = p[1], p[2], p[3], p[4], p[5]
                local _, nowRel, _, _, y = it.o:GetPoint(i)
                local onPage = (rel == nil or rel == it.o:GetParent())
                local want = (y0 or 0) + ((onPage and point:find("^TOP")) and Expected(it) or 0)
                if (y or 0) ~= want then
                    return false, ("%s %s: %s vs %s"):format(point, tostring(onPage), tostring(y), tostring(want))
                end
                if not onPage and nowRel ~= rel then return false, "sibling anchor changed" end
            end
        end
        return true
    end

    -- Everything empty: each list keeps one row, for its "none" line.
    AltStableConfig.whitelist = {}
    optPanel:GetScript("OnShow")(optPanel)
    local wl, au, hd = flow.lists[1], flow.lists[2], flow.lists[3]
    eq("an empty peer list uses one row", wl.used, 1)
    eq("  and so do the answers", au.used, 1)
    eq("  and the hidden list", hd.used, 1)
    check("  each saying so", T.OptWlNone:IsShown() and T.OptAuthNone:IsShown())
    check("everything below moved up by the rows not used", AllWhereExpected())
    -- Below BOTH sync lists (Toasts, Mail, Hidden): up by both gaps.
    local deepest
    for _, it in ipairs(flow.items) do
        if #it.below == 2 and it.points[1] and it.points[1][2] == it.o:GetParent() then deepest = it; break end
    end
    check("there is something below both sync lists", deepest ~= nil)
    if deepest then
        eq("  and it moved up by both gaps", ShiftOf(deepest), (4 + 5) * 18)
    end
    local fullH = flow.height
    local shown = (fullH - (4 + 5 + 5) * 18)
    -- The page's own height follows: read it from the scroll child.
    local child = flow.items[1].o:GetParent()
    eq("  the page height drops by the rows not used", child:GetHeight(), shown)

    -- Three peers: three rows, the note goes, and the rest moves back down.
    AltStableConfig.whitelist = { "A", "B", "C" }
    optPanel:GetScript("OnShow")(optPanel)
    eq("three peers use three rows", wl.used, 3)
    check("  the none line goes", not T.OptWlNone:IsShown())
    check("  and what is below sits where that leaves it", AllWhereExpected())
    eq("  the page grows back by two rows", child:GetHeight(), shown + 2 * 18)

    -- A TOP anchor to a SIBLING is left alone: the sibling moves, and it follows.
    -- (Nothing below the lists is built that way today; the rule is pinned so
    -- the first thing that is does not move twice.)
    local sib = CreateFrame("Frame", nil, child)
    local follower = CreateFrame("Frame", nil, child)
    follower:SetPoint("TOPLEFT", sib, "BOTTOMLEFT", 0, -4)
    flow.items[#flow.items + 1] = { o = follower, below = { wl }, points = { { follower:GetPoint(1) } } }
    flow.Apply()
    local _, fRel, _, _, fy = follower:GetPoint(1)
    check("a top anchor to a sibling is not moved by the flow", fRel == sib and fy == -4, tostring(fy))
    flow.items[#flow.items] = nil

    -- More than the list holds: no more than its reserve, and it says so.
    AltStableConfig.whitelist = { "A", "B", "C", "D", "E", "F", "G" }
    optPanel:GetScript("OnShow")(optPanel)
    eq("a full list uses its whole reserve, never more", wl.used, 5)
    check("  and says what it is not showing", (T.OptWlMore:GetText() or ""):find("+2 more") ~= nil,
          tostring(T.OptWlMore:GetText()))
    AltStableConfig.whitelist = { "A" }
    optPanel:GetScript("OnShow")(optPanel)
    eq("  and stops saying it when everything fits", T.OptWlMore:GetText(), "")

    -- `/alts whitelist` with Options open moves the page too (#158 review).
    AltStableConfig.whitelist = {}
    optPanel:GetScript("OnShow")(optPanel)
    optPanel:Show()
    AltStable.AddToWhitelist("Zed")
    eq("a peer added by command shows at once", wl.used, 1)
    check("  the none line goes", not T.OptWlNone:IsShown())
    AltStable.AddToWhitelist("Ann"); AltStable.AddToWhitelist("Bo")
    eq("  and the list grows with it", wl.used, 3)
    AltStable.RemoveFromWhitelist("Ann")
    eq("removing by command shrinks it", wl.used, 2)
    check("  with everything below where it should be", AllWhereExpected())

    -- Only what moves is re-anchored: a hidden-list change leaves what sits
    -- above that list alone.
    local above
    for _, it in ipairs(flow.items) do
        local underHidden = false
        for _, l in ipairs(it.below) do if l == hd then underHidden = true end end
        if not underHidden then above = it; break end
    end
    check("there is something between the sync lists and the hidden one", above ~= nil)
    if above then
        local moved = 0
        local realClear = above.o.ClearAllPoints
        above.o.ClearAllPoints = function(self) moved = moved + 1; return realClear(self) end
        hidden[1] = { guid = "h1", name = "Hid", class = "MAGE" }
        hidden[2] = { guid = "h2", name = "Den", class = "MAGE" }
        AltStable.RefreshOptionsHiddenList()
        eq("  the hidden list changing does not re-anchor it", moved, 0)
        eq("  while the hidden list did change", hd.used, 2)
        above.o.ClearAllPoints = realClear
        hidden[1], hidden[2] = nil, nil
        AltStable.RefreshOptionsHiddenList()
    end

    -- THE RULE the flow rests on: every anchor to the page is measured from
    -- its TOP edge. Its height moves; an anchor to its middle or bottom would
    -- move on its own (#158 review).
    local page = child
    local all = { page:GetChildren() }
    for _, r in ipairs({ page:GetRegions() }) do all[#all + 1] = r end
    local offenders = {}
    for _, o in ipairs(all) do
        for i = 1, (o:GetNumPoints() or 0) do
            local point, rel, relPoint = o:GetPoint(i)
            if rel == page and not tostring(relPoint):find("^TOP") then
                offenders[#offenders + 1] = point .. "->" .. tostring(relPoint)
            end
        end
    end
    eq("every anchor to the Options page is measured from its top", #offenders, 0)
    if #offenders > 0 then print("    " .. table.concat(offenders, ", ")) end

    -- Answers arriving while Options is open move the page too.
    auth[1] = { name = "Friend", mode = AltStable.AUTH_AUTO }
    auth[2] = { name = "Other", mode = AltStable.AUTH_NEVER }
    AltStable.RefreshSyncAnswers()
    eq("answers arriving reflow the page", au.used, 2)
    check("  the none line goes", not T.OptAuthNone:IsShown())
    check("  and everything below follows", AllWhereExpected())

    -- The hidden list's note rides on its own rows, which move with the lists,
    -- and the flow leaves it to that rather than putting it back.
    hidden[1] = nil
    AltStable.RefreshOptionsHiddenList()
    local skipped = 0
    for o in pairs(flow.skip) do
        skipped = skipped + 1
        local _, rel = o:GetPoint(1)
        check("the hidden list's note is anchored to the list's own rows", rel ~= nil and rel ~= child)
        for _, it in ipairs(flow.items) do
            if it.o == o then check("  and the flow does not re-anchor it", false) end
        end
    end
    eq("one note is left to its own anchoring", skipped, 1)

    -- The accent footnote sits under the Accent row, above every list.
    local note = T.OptAccentFootnote
    local _, _, _, nx, ny = note:GetPoint(1)
    local highest = -math.huge
    for _, it in ipairs(flow.items) do
        local y = it.points[1] and it.points[1][5]
        if y and it.points[1][2] == it.o:GetParent() and y > highest then highest = y end
    end
    check("the accent footnote is above every list, not at the bottom of the page", ny > highest,
          tostring(ny) .. " vs " .. tostring(highest))
    for _, it in ipairs(flow.items) do
        if it.o == note then check("  and does not move with them", false) end
    end
    check("  and explains the class colours, not the accent's own job",
          note:GetText():find("class colour") ~= nil)

    AltStableConfig.whitelist, AltStable.SyncAuthList, AltStable.PendingSyncRequests,
        AltStable.HiddenCharacterList = saved[1], saved[2], saved[3], saved[4]
end

------------------------------------------------------------
-- Column headers: one builder, reused buttons (#160)
------------------------------------------------------------

do
    local T = AltStable._test
    AltStable.EnsureSheetVisible()
    local btnFor = {}
    for _, b in ipairs(T.sidebarBtns) do
        if b.sectionId then btnFor[b.sectionId] = b end
    end
    local function Open(id) btnFor[id]:GetScript("OnClick")(btnFor[id]) end
    local function Headers()
        local cols, hdrs = T.ColumnLayout()
        local copy = {}                     -- the seam returns LIVE tables
        for i = 1, #hdrs do copy[i] = hdrs[i] end
        return cols, copy
    end
    local function SameColour(r1, g1, b1, r2, g2, b2)
        return math.abs(r1 - r2) < 1e-6 and math.abs(g1 - g2) < 1e-6 and math.abs(b1 - b2) < 1e-6
    end
    local ar, ag, ab = AltStable.GetAccentRGB()

    -- Reuse. Summary has 8 columns and Gear 21; a round trip and a second one
    -- must use the very same buttons, not make new ones each switch.
    Open("summary"); Open("gear")
    local _, gearFirst = Headers()
    Open("summary"); Open("gear")
    local gearCols, gearAgain = Headers()
    local same = #gearFirst == #gearAgain and #gearAgain == #gearCols
    for i = 1, #gearAgain do if gearAgain[i] ~= gearFirst[i] then same = false end end
    check("a section switch reuses the header buttons, not makes new ones", same)
    local pool, divs = T.HeaderPools()
    -- At least: the pool never shrinks, and an earlier test may have opened a
    -- wider tab. Unused slots are checked hidden below.
    check("  the pool holds at least this section's worth", #pool >= #gearCols)
    check("  and its dividers too", #divs >= #gearCols - 1)

    -- A reused button takes its new column's look. Slot 5 is an icon in Gear
    -- (Head) and a text header in Summary (Guild).
    check("Gear's fifth header is an icon", gearAgain[5].iconTex:IsShown())
    Open("summary")
    local sumCols, sum = Headers()
    eq("Summary's fifth column is Guild", sumCols[5].field, "guild")
    check("  a reused icon button shows no icon as a text header", not sum[5].iconTex:IsShown())
    check("  its label is back", sum[5].label:IsShown())
    eq("  and reads its new column", sum[5].label:GetText(), "Guild")
    for i = #sumCols + 1, #pool do
        if pool[i]:IsShown() then check("a header past the section's columns is hidden", false) end
    end

    -- A stacked faction header (no icon: its short name, a letter per line)
    -- reused for a text column. High Order has no icon; on Reputations it is
    -- the fourth column, and Summary's fourth is iLvl.
    local savedDB = AltStableDB
    local stackedField = AltStable.RepField(2779)
    AltStableDB = { s = { guid = "s", name = "Stack Test", realm = "R", level = 10, [stackedField] = 5 } }
    Open("rep")
    local repCols, rep = Headers()
    eq("Reputations' fourth column is the faction with no icon", repCols[4].field, stackedField)
    check("  its header is stacked letters", rep[4].label:CanNonSpaceWrap())
    eq("  a taller header strip for them", select(6, T.ColumnLayout()):GetHeight(), 64)
    eq("the Name header fills the taller strip", T.NameHeader():GetHeight(), 64)
    Open("summary")
    local _, sum2 = Headers()
    eq("  the same slot is reused for iLvl", sum2[4], rep[4])
    check("  which no longer breaks its word letter by letter", not sum2[4].label:CanNonSpaceWrap())
    eq("  nor keeps the stacked label's fixed width", sum2[4].label:GetWidth(), 0)
    eq("  and reads its own label", sum2[4].label:GetText(), "iLvl")
    eq("the Name header shrinks back with the strip", T.NameHeader():GetHeight(),
       select(6, T.ColumnLayout()):GetHeight())
    AltStableDB = savedDB
    AltStable.RefreshSheet()

    -- The Name header shows that the rows are sorted by it. It used to fall out
    -- of the sort painter on the first build and never show anything.
    local name = T.NameHeader()
    check("the frozen Name header exists", name ~= nil)
    name:GetScript("OnClick")(name)
    check("sorting by Name shows its arrow", name.arrow:IsShown())
    -- The path, exactly: with single backslashes Lua 5.1 reads it as
    -- "InterfaceButtonsUI-SortArrow" without a word, and the arrow is shown
    -- and draws nothing. That shipped to a test build of #160.
    eq("  drawn from the sort-arrow file", name.arrow:GetTexture(), "Interface\\Buttons\\UI-SortArrow")
    check("  and tints its label", SameColour(ar, ag, ab, name.label:GetTextColor()))
    local lvl
    for i, c in ipairs(sumCols) do if c.field == "level" then lvl = sum[i] end end
    lvl:GetScript("OnClick")(lvl)
    check("sorting by another column takes the arrow off Name", not name.arrow:IsShown())
    check("  and its tint", not SameColour(ar, ag, ab, name.label:GetTextColor()))
    check("  and puts it on that column", lvl.arrow:IsShown())

    local function ButtonFor(cols, hdrs, field)
        for i, c in ipairs(cols) do if c.field == field then return hdrs[i] end end
    end
    local function Tip() return table.concat(WoW.tooltipLines, " / ") end

    -- First clicks: text A to Z, numbers highest first. A second click flips.
    name:GetScript("OnClick")(name)
    local f, asc = T.SortState()
    check("a first click on Name sorts A to Z", f == "name" and asc == true)
    local gold = ButtonFor(sumCols, sum, "money")
    gold:GetScript("OnClick")(gold)
    f, asc = T.SortState()
    check("a first click on Gold sorts highest first", f == "money" and asc == false)
    gold:GetScript("OnClick")(gold)
    f, asc = T.SortState()
    check("  a second click flips it", f == "money" and asc == true)

    -- Sorted: a faint fill, an underline and the arrow. Nowhere else.
    check("the sorted header shows its fill", gold.sortFill:IsShown())
    check("  its underline", gold.underline:IsShown())
    check("  and the arrow", gold.arrow:IsShown())
    check("an unsorted header shows none of them",
          not lvl.sortFill:IsShown() and not lvl.underline:IsShown() and not lvl.arrow:IsShown())
    local p, rel = gold.arrow:GetPoint(1)
    check("a right-aligned label's arrow sits at the header's right edge", p == "RIGHT" and rel == gold)
    name:GetScript("OnClick")(name)
    p = name.arrow:GetPoint(1)
    eq("a left-aligned label's arrow follows the text", p, "LEFT")

    -- The tooltip says the order, and what the next click does.
    name:GetScript("OnEnter")(name)
    check("a sorted header's tooltip says the order", Tip():find("A to Z", 1, true) ~= nil, Tip())
    check("  and what a click does", Tip():find("Click to sort Z to A", 1, true) ~= nil, Tip())
    name:GetScript("OnClick")(name)
    check("  and is redrawn by a click under the mouse", Tip():find("Click to sort A to Z", 1, true) ~= nil, Tip())
    name:GetScript("OnLeave")(name)
    lvl:GetScript("OnEnter")(lvl)
    check("an unsorted number column offers highest first",
          Tip():find("Click to sort highest first", 1, true) ~= nil, Tip())
    local last = ButtonFor(sumCols, sum, "lastUpdate")
    last:GetScript("OnEnter")(last)
    check("Last Online speaks in time, not size",
          Tip():find("Click to sort most recent first", 1, true) ~= nil, Tip())
    last:GetScript("OnLeave")(last)
    lvl:GetScript("OnEnter")(lvl)

    -- Hover is a neutral fill, apart from the sorted look.
    check("hovering a sortable header shows the hover fill", lvl.hoverFill:IsShown())
    check("  not the sorted look", not lvl.sortFill:IsShown())
    lvl:GetScript("OnLeave")(lvl)
    check("  leaving takes it away", not lvl.hoverFill:IsShown())
    check("  and the tooltip", not GameTooltip:IsOwned(lvl))

    -- Class and Race headers are the addon's own glyphs, drawn whole - not the
    -- logged-in character's icons, which read as one more row.
    local class, race = sum[1], sum[2]
    check("the Class header is an icon", class.iconTex:IsShown() and not class.label:IsShown())
    eq("  the class glyph", class.iconTex:GetTexture(), "Interface\\AddOns\\AltStable\\Media\\Icons\\header-class.tga")
    eq("the Race header is the race glyph", race.iconTex:GetTexture(), "Interface\\AddOns\\AltStable\\Media\\Icons\\header-race.tga")
    -- GetTexCoord gives the corners: upper-left x,y, lower-left, upper-right...
    local ulx, uly, _, lly, urx = class.iconTex:GetTexCoord()
    check("  drawn whole, not cropped like a game icon", ulx == 0 and uly == 0 and lly == 1 and urx == 1,
          table.concat({ tostring(ulx), tostring(uly), tostring(lly), tostring(urx) }, ","))
    check("the glyphs ship with the addon",
          io.open("Media/Icons/header-class.tga", "rb") ~= nil and io.open("Media/Icons/header-race.tga", "rb") ~= nil)
    class:GetScript("OnClick")(class)
    f, asc = T.SortState()
    check("Class sorts, A to Z first", f == "class" and asc == true)
    eq("  an icon header's arrow sits in its corner", (class.arrow:GetPoint(1)), "BOTTOMRIGHT")

    -- The Skills tab's profession icons match the Class and Race icons beside
    -- them, though their columns are wider.
    Open("skills")
    local skillCols, skills = Headers()
    local classW = skills[1].iconTex:GetWidth()
    local profBtn
    for i, c in ipairs(skillCols) do if c.profIcon then profBtn = skills[i]; break end end
    check("the Skills tab has a profession header", profBtn ~= nil)
    eq("  its icon is the Class icon's size", profBtn.iconTex:GetWidth(), classW)
    eq("  and square", profBtn.iconTex:GetHeight(), classW)
    Open("gear")
    local gearSizeCols, gearSize = Headers()
    local slotBtn
    for i, c in ipairs(gearSizeCols) do if c.slotSlug then slotBtn = gearSize[i]; break end end
    check("the Gear tab has a slot header", slotBtn ~= nil)
    eq("  its icon is the Class icon's size too", slotBtn.iconTex:GetWidth(), gearSize[1].iconTex:GetWidth())

    -- Gear slots do not sort: no click, no hover, no order in the tooltip.
    Open("gear")
    local gearCols2, gear = Headers()
    local head = gear[5]
    eq("Gear's fifth column is Head", gearCols2[5].field, "gear_head")
    local before, beforeAsc = T.SortState()
    head:GetScript("OnClick")(head)
    local after, afterAsc = T.SortState()
    check("clicking a gear slot changes nothing", before == after and beforeAsc == afterAsc)
    check("  and shows no sorted look", not head.sortFill:IsShown() and not head.arrow:IsShown())
    head:GetScript("OnEnter")(head)
    check("  hovering one shows no fill", not head.hoverFill:IsShown())
    check("  its tooltip names it", Tip():find("Head", 1, true) ~= nil, Tip())
    check("  and offers no sort", Tip():lower():find("sort", 1, true) == nil, Tip())
    check("an icon header is never tinted", SameColour(1, 1, 1, head.iconTex:GetVertexColor()))

    -- A header rebuilt under the mouse never gets its OnLeave: the rebuild
    -- itself must take down a tooltip it owned.
    Open("summary")
    check("a header's tooltip goes when the headers are rebuilt", not GameTooltip:IsOwned(head))
end

------------------------------------------------------------
-- Sorting: the comparator (#160)
------------------------------------------------------------

do
    local T = AltStable._test
    local function Sorted(chars, field, asc)
        local list = {}
        for i, c in ipairs(chars) do list[i] = c end
        table.sort(list, T.SortComparator(list, field, asc))
        local out = {}
        for i, c in ipairs(list) do out[i] = c.id end
        return table.concat(out, ",")
    end
    local chars = {
        { id = "a", name = "Alpha One",   money = 500, level = 10, ilvl = 5 },
        { id = "b", name = "beta Two",    money = nil, level = 10, ilvl = 9 },
        { id = "c", name = "Gamma Three", money = 900, level = 10, ilvl = 7 },
    }
    eq("gold, highest first, unknown last", Sorted(chars, "money", false), "c,a,b")
    eq("gold, lowest first, unknown STILL last", Sorted(chars, "money", true), "a,c,b")
    -- Byte order would put "Gamma" before "beta".
    eq("names, A to Z, ignoring case", Sorted(chars, "name", true), "a,b,c")
    -- The three-way compare is turned into a boolean: returned as is, 0 and -1
    -- are both true and the order comes out scrambled.
    eq("names, Z to A", Sorted(chars, "name", false), "c,b,a")
    eq("equal values fall to item level, highest first", Sorted(chars, "level", false), "b,c,a")
    -- A number stored as text is still a number: as text, "10" < "9".
    eq("numbers compare as numbers whatever they are stored as",
       Sorted({ { id = "x", money = "10" }, { id = "y", money = 9 } }, "money", false), "x,y")
    -- By the name the tooltip shows: Undead is stored as "Scourge", which as
    -- a token sorts between Orc and Tauren.
    eq("race sorts by its shown name, A to Z",
       Sorted({ { id = "u", race = "Scourge" }, { id = "o", race = "Orc" }, { id = "t", race = "Tauren" } },
              "race", true), "o,t,u")
    eq("level counts the progress into it",
       Sorted({ { id = "x", level = 5, xpPercent = 10 }, { id = "y", level = 5, xpPercent = 60 } }, "level", false),
       "y,x")
    eq("rested XP at the level cap is a dash, so last",
       Sorted({ { id = "cap", level = AltStable.API.LevelCap(), restPercent = 150 },
                { id = "low", level = 5, restPercent = 10, lastUpdate = time() } }, "restPercent", false),
       "low,cap")
    eq("  in both directions",
       Sorted({ { id = "cap", level = AltStable.API.LevelCap(), restPercent = 150 },
                { id = "low", level = 5, restPercent = 10, lastUpdate = time() } }, "restPercent", true),
       "low,cap")
    -- What the cell shows: 10% stored 64 hours ago in the open world is 20%
    -- now, above a fresh 12%. By the stored number it would be the other way.
    eq("rested XP sorts by the live estimate the cell shows, not the stored snapshot",
       Sorted({ { id = "fresh", level = 5, restPercent = 12, restTimestamp = time() },
                { id = "old",   level = 5, restPercent = 10, restTimestamp = time() - 64 * 3600 } },
              "restPercent", false),
       "old,fresh")

    -- Many rows with gaps, both ways: table.sort raises "invalid order
    -- function" on a comparator that is not a strict weak order.
    local many = {}
    for i = 1, 60 do
        many[i] = { id = tostring(i), name = (i % 3 == 0) and nil or ("N" .. (i % 7)),
                    money = (i % 4 == 0) and nil or (i % 5) * 100, ilvl = i % 3 }
    end
    for _, field in ipairs({ "money", "name" }) do
        for _, asc in ipairs({ true, false }) do
            local ok, err = pcall(Sorted, many, field, asc)
            check(("%s %s sorts without error"):format(field, asc and "asc" or "desc"), ok, tostring(err))
        end
    end
end

------------------------------------------------------------
-- Sorting: per tab, remembered, and the rows follow (#160)
------------------------------------------------------------

do
    local T = AltStable._test
    AltStable.EnsureSheetVisible()
    local btnFor = {}
    for _, b in ipairs(T.sidebarBtns) do
        if b.sectionId then btnFor[b.sectionId] = b end
    end
    local function Open(id) btnFor[id]:GetScript("OnClick")(btnFor[id]) end
    local function Click(field)
        if field == "name" then local n = T.NameHeader(); n:GetScript("OnClick")(n); return end
        local cols, hdrs = T.ColumnLayout()
        for i, c in ipairs(cols) do
            if c.field == field then hdrs[i]:GetScript("OnClick")(hdrs[i]); return end
        end
        check("a header for " .. field .. " to click", false)
    end
    local function Order()
        local out = {}
        for _, it in ipairs(T.DisplayList()) do
            if it.kind == "char" then out[#out + 1] = it.data.guid end
        end
        return table.concat(out, ",")
    end

    local repField = AltStable.RepField(AltStable.REPUTATIONS[1].id)
    local savedDB = AltStableDB
    AltStableDB = {
        a = { guid = "a", name = "Alpha One",   realm = "R", level = 10, money = 500, [repField] = 5 },
        b = { guid = "b", name = "beta Two",    realm = "R", level = 20 },
        c = { guid = "c", name = "Gamma Three", realm = "R", level = 5,  money = 900 },
    }
    AltStableConfig.rememberSortOrder, AltStableConfig.sheetSort = true, nil
    T.ForgetSessionSorts()

    Open("summary")
    eq("a tab with no sort of its own starts on level, highest first", Order(), "b,a,c")
    Click("money")
    eq("the rows follow a click: gold, highest first, unknown last", Order(), "c,a,b")
    Click("name")
    eq("names A to Z, case ignored", Order(), "a,b,c")
    Click("money")

    -- Each tab its own.
    Open("gear")
    local f, asc = T.SortState()
    check("another tab keeps its own sort (level, highest first)", f == "level" and asc == false)
    Open("summary")
    f, asc = T.SortState()
    check("coming back restores this tab's", f == "money" and asc == false)

    -- Remembered across a login.
    local saved = AltStableConfig.sheetSort and AltStableConfig.sheetSort.summary
    check("the tab's sort is saved", saved and saved.field == "money" and saved.asc == false)
    T.ForgetSessionSorts()
    Open("gear"); Open("summary")
    f, asc = T.SortState()
    check("after a login the saved sort comes back", f == "money" and asc == false)
    -- Restored, then Remember switched off before any click: the tab keeps it
    -- for the session (Codex review of #162). Back on, so the tests below
    -- start from the default.
    local cbr = T.OptRememberSort
    cbr:SetChecked(false); cbr:GetScript("OnClick")(cbr)
    Open("gear"); Open("summary")
    f, asc = T.SortState()
    check("a restored sort survives Remember being switched off", f == "money" and asc == false)
    cbr:SetChecked(true); cbr:GetScript("OnClick")(cbr)
    AltStableConfig.sheetSort = { summary = { field = "money", asc = false } }
    -- A saved sort naming a column the tab does not have falls back.
    AltStableConfig.sheetSort = { summary = { field = "gear_head", asc = true } }
    T.ForgetSessionSorts()
    Open("gear"); Open("summary")
    f = T.SortState()
    eq("a saved sort on a column the tab lacks falls back to level", f, "level")

    -- Off: the saved sorts are forgotten, nothing new is saved, and a saved
    -- one is ignored at login.
    local cb = T.OptRememberSort
    cb:SetChecked(false); cb:GetScript("OnClick")(cb)
    eq("turning Remember off forgets the saved sorts", AltStableConfig.sheetSort, nil)
    Click("name")
    eq("  and a sort made while off is not saved", AltStableConfig.sheetSort, nil)
    Open("gear"); Open("summary")
    f = T.SortState()
    eq("  but the tab still keeps it for the session", f, "name")
    AltStableConfig.sheetSort = { summary = { field = "money", asc = true } }
    T.ForgetSessionSorts()
    Open("gear"); Open("summary")
    f = T.SortState()
    eq("  and a saved one is ignored at login", f, "level")
    Click("name")                       -- a sort made this session, while off
    cb:SetChecked(true); cb:GetScript("OnClick")(cb)
    check("turning it back on is saved as on", AltStableConfig.rememberSortOrder == true)
    local back = AltStableConfig.sheetSort and AltStableConfig.sheetSort.summary
    check("  and saves the tabs' current sorts at once, not from the next click",
          back and back.field == "name" and back.asc == true)

    -- A faction column that goes away while it is the sort: back to level.
    Open("rep")
    Click(repField)
    f = T.SortState()
    eq("a faction column sorts", f, repField)
    AltStableDB.a[repField] = nil
    AltStable.RefreshSheet()
    f = T.SortState()
    eq("its column gone, the sort falls back to level", f, "level")

    AltStableDB = savedDB
    AltStableConfig.sheetSort = nil
    T.ForgetSessionSorts()
    Open("summary")
    AltStable.RefreshSheet()
end

------------------------------------------------------------
-- A tab switch glides to the new tab's size (#159)
------------------------------------------------------------

do
    local T = AltStable._test
    AltStable.EnsureSheetVisible()
    local f = T.frame
    local btnFor = {}
    for _, b in ipairs(T.sidebarBtns) do
        if b.sectionId then btnFor[b.sectionId] = b end
    end
    local function Open(id) btnFor[id]:GetScript("OnClick")(btnFor[id]) end
    local runner
    local function Running() runner = T.WindowAnimRunner(); return runner ~= nil and runner:GetScript("OnUpdate") ~= nil end
    local function Tick(dt) local fn = runner and runner:GetScript("OnUpdate"); if fn then fn(runner, dt) end end

    AltStableConfig.enableOpenAnimation = false
    local offRefreshes, offReal = 0, AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...) offRefreshes = offRefreshes + 1; return offReal(...) end
    Open("gear"); local gearW = f:GetWidth()
    AltStable.RefreshSheet = offReal
    eq("with the animation off a switch is laid out once too", offRefreshes, 0)
    Open("summary"); local sumW = f:GetWidth()
    check("Summary and Gear are different widths (the case this is about)", gearW ~= sumW,
          tostring(sumW) .. " vs " .. tostring(gearW))
    check("with the animation off a switch makes no trip", not Running())

    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)
    AltStableConfig.enableOpenAnimation = true
    -- The tab is built once, by the switch: not laid out again for the trip.
    local refreshes, realRefresh = 0, AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...) refreshes = refreshes + 1; return realRefresh(...) end
    Open("gear")
    AltStable.RefreshSheet = realRefresh
    check("switching to a wider tab glides", Running())
    eq("  starting from the old width", f:GetWidth(), sumW)
    eq("  the tab laid out once, by the switch", refreshes, 0)
    Tick(0.1)
    check("  half way, between the two", f:GetWidth() > math.min(sumW, gearW) and f:GetWidth() < math.max(sumW, gearW),
          tostring(f:GetWidth()))
    Tick(0.2)
    check("  then it stops", not Running())
    eq("  at the new tab's width", f:GetWidth(), gearW)
    local p, _, _, x, y = f:GetPoint(1)
    check("  anchored where the window really is", p == "TOPLEFT" and x == 50 and y == -60, tostring(p))

    -- A plugin that keeps the window's size: nothing to travel, and laid out
    -- once - by its own OnActivate - not again through OnResize (#164 review:
    -- the Roster rebuilt its scene twice per click).
    local kept = { activated = 0, resized = 0 }
    local keeps = { id = "test159keeps", label = "Keeps", _isPlugin = true,
                    OnActivate = function() kept.activated = kept.activated + 1 end,
                    OnResize = function() kept.resized = kept.resized + 1 end,
                    OnDeactivate = function() end }
    AltStable.RegisterPlugin(keeps)
    local keepBtn = T.sidebarBtns[#T.sidebarBtns]
    keepBtn:GetScript("OnClick")(keepBtn)
    check("a plugin that keeps the size makes no trip", not Running())
    eq("  it is laid out once, by its OnActivate", kept.activated, 1)
    eq("  and not again through OnResize", kept.resized, 0)
    keepBtn:GetScript("OnClick")(keepBtn)
    check("  nor does clicking it again", not Running())
    eq("  which lays it out no second time either", kept.resized, 0)

    -- A plugin that GROWS the window as it opens (Warband's floor): it glides,
    -- and is laid out once, by OnActivate, at the size it ends at.
    Open("summary"); Tick(1)
    local grew = { resized = 0 }
    local grows = { id = "test159grows", label = "Grows", _isPlugin = true,
                    OnActivate = function() AltStable.EnsureWindowMinSize(f:GetWidth() + 200, f:GetHeight()) end,
                    OnResize = function() grew.resized = grew.resized + 1 end,
                    OnDeactivate = function() end }
    AltStable.RegisterPlugin(grows)
    local growBtn = T.sidebarBtns[#T.sidebarBtns]
    local beforeW = f:GetWidth()
    growBtn:GetScript("OnClick")(growBtn)
    check("a plugin that grows the window glides", Running())
    Tick(1)
    eq("  to the size it asked for", f:GetWidth(), beforeW + 200)
    eq("  laid out once, not again at the end", grew.resized, 0)

    -- Switching away mid-glide: the trip's deferred layout was for the tab
    -- that is leaving, so it is dropped, not run.
    AltStable.SetSidebarCompact(true)           -- its space grows: layout deferred to the end
    check("a growing trip on the plugin", Running())
    Tick(0.05)
    grew.resized = 0
    Open("summary")
    eq("switching away mid-glide does not lay out the leaving plugin", grew.resized, 0)
    Tick(1)
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetSidebarCompact(false)
    AltStableConfig.enableOpenAnimation = true

    -- A tab click during the open fade finishes the fade first: the trip is
    -- measured at the window's settled scale, not one still moving.
    AltStable._PlayOpenAnimation(f)
    Open("gear")
    check("a tab click during the open fade finishes the fade", not AltStable.FinishOpenAnimation())
    Tick(1)

    -- /alts config and the minimap right-click open Options through its button.
    local ok, err = pcall(AltStable.OpenConfig)
    check("opening Options from outside the sidebar raises nothing", ok, tostring(err))
    Tick(1)
    check("  the Options page is shown", T.optionsPanel:IsShown())
    check("  and the grid is not", not f.bodyScroll:IsShown())
    Open("gear"); Tick(1)

    -- A plugin that sizes the window when it opens glides there, laid out once.
    local sizer = { resized = 0 }
    local sizes = { id = "test159sizes", label = "Sizes", _isPlugin = true, sizesWindow = true,
                    OnActivate = function() AltStable.RequestWindowSize(700, 520) end,
                    OnResize = function() sizer.resized = sizer.resized + 1 end,
                    OnDeactivate = function() end }
    AltStable.RegisterPlugin(sizes)
    local sizeBtn = T.sidebarBtns[#T.sidebarBtns]
    sizeBtn:GetScript("OnClick")(sizeBtn)
    check("a plugin that sizes the window glides there", Running())
    eq("  from the old width", f:GetWidth(), gearW)
    eq("  not laid out a second time for the trip", sizer.resized, 0)
    Tick(0.3)
    eq("  and ends at the size it asked for", f:GetWidth(), 700)

    -- Maximized, every tab is the whole display: no trip.
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetWindowMaximized(true)
    AltStableConfig.enableOpenAnimation = true
    Open("summary")
    check("a switch while maximized makes no trip", not Running())
    AltStableConfig.enableOpenAnimation = false
    AltStable.SetWindowMaximized(false)
    Open("summary")
end

print(("test_sheetui: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
