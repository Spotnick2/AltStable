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
dofile("SheetUI.lua")

local GOLD = 10000   -- copper per gold

-- Footer text carries colour codes between the numbers and their labels, so
-- "5 avg iLvl" is really "|cffaaaaaa5|r avg iLvl". Strip the markup before
-- asserting, or every check has to know the colours.
local function plain(s)
    if not s then return nil end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

local function build(db)
    AltStableDB = db
    local ok, err = pcall(AltStable.ShowSheet)
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

-- A right-click ASKS. It must not hide anything by itself: the row disappears
-- on one click and the way back is a list in Options the user has no reason to
-- have seen yet.
WoW.popups = {}
AltStable.RequestHideCharacter(AltStableDB.gone)
eq("a right-click raises one confirmation", #WoW.popups, 1)
local popup = WoW.popups[1]
if popup then
    check("  naming the character", popup.arg1 == "Goner", tostring(popup.arg1))

    -- The sheet is DIALOG strata and toplevel, and a StaticPopup is DIALOG too,
    -- so this confirmation opened BEHIND the window and appeared only once the
    -- sheet was closed. A question nobody can see reads as a click that did
    -- nothing.
    -- The confirmation was invisible until the sheet closed, so the right-click
    -- read as doing nothing. TWO things hid it and strata answers only one: the
    -- sheet is DIALOG and toplevel, AND the camera showcase hides UIParent
    -- outright - a StaticPopup is a child of UIParent, and no strata makes the
    -- child of a hidden parent draw.
    local dlg = StaticPopupDialogs[popup.which]
    check("the dialog has show/hide handlers",
          dlg ~= nil and type(dlg.OnShow) == "function" and type(dlg.OnHide) == "function")

    if dlg and type(dlg.OnShow) == "function" and type(dlg.OnHide) == "function" then
        -- A frame with real strata and parent state; the stub's default chains
        -- unknown methods back to itself, which would store the frame as its own
        -- "saved strata" and make every restore a silent no-op.
        local function FakeDialog()
            local f = WoW.makeFrame()
            f._strata, f._parent, f._scale = "DIALOG", UIParent, 1
            f.GetFrameStrata = function(self) return self._strata end
            f.SetFrameStrata = function(self, v) self._strata = v end
            f.GetParent = function(self) return self._parent end
            f.SetParent = function(self, p) self._parent = p end
            f.GetScale = function(self) return self._scale end
            f.SetScale = function(self, v) self._scale = v end
            f.GetEffectiveScale = function(self) return self._scale end
            return f
        end

        -- Sheet open, game UI visible: strata is enough.
        local fake = FakeDialog()
        dlg.OnShow(fake)
        eq("it is raised above the sheet", fake:GetFrameStrata(), "FULLSCREEN_DIALOG")
        eq("  and stays under UIParent while the UI is up", fake:GetParent(), UIParent)
        dlg.OnHide(fake)
        eq("  strata is put back, since the frame is shared with every addon",
           fake:GetFrameStrata(), "DIALOG")

        -- Showcase running, so UIParent is hidden: strata cannot help.
        local realHidden = AltStable.IsGameUIHidden
        AltStable.IsGameUIHidden = function() return true end

        fake = FakeDialog()
        dlg.OnShow(fake)
        check("with the game UI hidden it is lifted OUT from under UIParent",
              fake:GetParent() ~= UIParent, tostring(fake:GetParent()))
        dlg.OnHide(fake)
        eq("  and parented back on close", fake:GetParent(), UIParent)
        eq("  with its strata restored too", fake:GetFrameStrata(), "DIALOG")

        AltStable.IsGameUIHidden = realHidden
    end
    check("  and carrying its guid, not its name",
          type(popup.data) == "table" and popup.data.guid == "gone", tostring(popup.data))
end
eq("nothing is hidden until it is accepted", AltStable.IsCharacterHidden("gone"), false)
eq("  and the row is still drawn", joined(AltStable._test.DisplayNames()), "Keeper,Goner")

-- Accepting it is what hides.
local dialog = StaticPopupDialogs[popup and popup.which]
check("the dialog is registered", dialog ~= nil)
if dialog then
    dialog.OnAccept(nil, popup.data)
end
eq("accepting hides the character", AltStable.IsCharacterHidden("gone"), true)
eq("  the grid drops the row", joined(AltStable._test.DisplayNames()), "Keeper")

footer = refresh()
if footer then
    check("the footer counts only the visible characters",
          footer:find("1%s+chars") ~= nil, footer)
    check("  levels exclude the hidden one", footer:find("60%s+total levels") ~= nil, footer)
    check("  gold excludes the hidden one", footer:find("100", 1, true) ~= nil, footer)
    check("  and does not total all of it", footer:find("150", 1, true) == nil, footer)
    check("  the average iLvl excludes it too", footer:find("60 avg iLvl", 1, true) ~= nil, footer)
    check("  with a marker saying how many were left out",
          footer:find("(1 hidden)", 1, true) ~= nil, footer)
end

-- The record itself is untouched: hiding is not deleting.
check("the character is still in the database",
      type(AltStableDB.gone) == "table" and AltStableDB.gone.name == "Goner")

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
    check("every character can be hidden", footer:find("(8 hidden)", 1, true) ~= nil, footer)
    check("  leaving an empty grid, not an error", #AltStable._test.DisplayNames() == 0)
end

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
if onClick then
    onClick(row.nameTipBtn, "LeftButton")
    eq("a left-click does nothing", #WoW.popups, 0)
    onClick(row.nameTipBtn, "RightButton")
    eq("a right-click asks", #WoW.popups, 1)
    check("  about the character under the cursor",
          WoW.popups[1] and WoW.popups[1].arg1 == "Here", tostring(WoW.popups[1] and WoW.popups[1].arg1))

    -- A recycled row carries no character. Group rows and fillers go through
    -- the same pool, and a right-click there must not hide whatever was drawn
    -- in that row last.
    AltStable.HideFrozenRow(row)
    onClick(row.nameTipBtn, "RightButton")
    eq("a right-click on an empty row does nothing", #WoW.popups, 1)

    -- The realm header is the one that actually happens: collapse a realm and
    -- the row that drew a character now draws its header, at the same index.
    AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
    AltStable.RenderFrozenGroupRow(row, { kind = "group", realm = "R", count = 1 })
    onClick(row.nameTipBtn, "RightButton")
    eq("a right-click on a realm header hides nothing", #WoW.popups, 1)

    WoW.tooltipLines = {}
    row.nameTipBtn:GetScript("OnEnter")()
    eq("  and it shows no leftover tooltip", #WoW.tooltipLines, 0)

    -- Same for a filler row.
    AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
    AltStable.RenderFrozenFillerRow(row, 1)
    onClick(row.nameTipBtn, "RightButton")
    eq("a right-click on a filler row hides nothing", #WoW.popups, 1)
end

-- The same guard, asked directly: the row is not the only caller (a plugin or
-- a slash command could route here), so the entry point has to hold it too.
local okNil = pcall(AltStable.RequestHideCharacter, nil)
check("asking to hide nothing is not an error", okNil)
AltStable.RequestHideCharacter({ name = "No guid" })
eq("  and raises no confirmation", #WoW.popups, 1)

AltStable.RenderFrozenCharRow(row, AltStableDB.here, 1)
local onEnter = row.nameTipBtn:GetScript("OnEnter")
if onEnter then
    WoW.tooltipLines = {}
    onEnter()
    check("the tooltip says how to hide it",
          joined(WoW.tooltipLines):find("Right%-click to hide") ~= nil,
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

print(("test_sheetui: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
