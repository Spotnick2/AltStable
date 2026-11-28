------------------------------------------------------------
-- test_search.lua: finding an item on every character (#503)
--
-- The real sheet, the real Warband plugin and the real search window, driven
-- the way a player drives them: typing, Enter, Shift, the title button,
-- /alts search. The counts are what the plan was argued over (five Codex
-- rounds, on the issue): the characters the sheet lists, mail in flight
-- under its recipient once, worn gear by slot.
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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Played.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("SheetUI.lua")
dofile("Capture.lua")
dofile("PublicAPI.lua")
dofile("Export.lua")
dofile("Search.lua")
dofile("Plugins/Warband/WarbandTabs.lua")
dofile("Plugins/Warband/AltStableWarband.lua")
-- Who can craft (PR 2): the Professions plugin, on a small fixed catalogue,
-- shaped as RecipeData.lua writes it.
AltStableRecipeData = { source = "test", recipes = {
    [11000] = { skill = { 197 }, learn = 1,   makes = 2996 },    -- Bolt of Linen Cloth
    [11001] = { skill = { 171 }, learn = 275, makes = 12360 },   -- two recipes, one Arcanite Bar
    [11002] = { skill = { 171 }, learn = 275, makes = 12360 },
    [11003] = { skill = { 197 }, learn = 45,  makes = 4238 },    -- known only by the hidden one
    [11004] = { skill = { 333 }, learn = 1 },                    -- an enchant: no item
    [11005] = { skill = { 197 }, learn = 25,  makes = 4240 },    -- learned while the search is open
    [11006] = { skill = { 171 }, learn = 230, makes = 12359 },   -- its name loads late
    [11007] = { skill = { 164 }, learn = 1,   makes = 2862 },    -- arrives by sync
} }
AltStableProfessionsDB = {}
dofile("Plugins/Professions/AltStableProfessions.lua")
WoW.flushTimers()

local S = AltStable._search
local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "warband" then plugin = p end end
check("the Warband plugin registered", plugin ~= nil)
check("the search is loaded", S ~= nil and AltStable.ShowSearch ~= nil)
if not (plugin and S) then
    print(("test_search: %d passed, %d failed"):format(passed, failed))
    os.exit(1)
end
local wb, WT = plugin._wb, plugin._test

local ME, ALT, HID, GONE = "Player-1-AAAA", "Player-1-BBBB", "Player-1-CCCC", "Player-1-DDDD"
local NOW = 1000000
local realTime = time
time = function() return NOW end

local function World()
    WoW.player.guid = ME
    AltStableDB = {
        [ME]  = { name = "Kaleid", class = "HUNTER", gearid_ring1 = 200, gearid_ring2 = 200, gearid_head = 0 },
        [ALT] = { name = "Brom", class = "WARRIOR" },
        [HID] = { name = "Hidden", class = "MAGE" },
    }
    -- Every ruleset: the saved view this file returns to lists everyone.
    AltStableConfig = { hiddenCharacters = { [HID] = true }, warbandRuleset = "all" }
    AltStableWarbandDB = {
        [ME]  = { bags = { [101] = 2 }, mailStamp = NOW - 100 },
        [ALT] = { bags = { [101] = 5, [102] = 1 }, bank = { [101] = 3 } },
        [HID] = { bags = { [101] = 7 },
                  -- A hidden sender's mail to a listed character counts, under them.
                  outbox = { { to = ME, at = NOW - 10, items = { [103] = 4 } } } },
        -- What a forgotten character sent stays invisible, and so does mail
        -- to one: GONE has no core record.
        [GONE] = { outbox = { { to = ME, at = NOW - 10, items = { [106] = 1 } } } },
    }
    -- ME's mail to the hidden one, and to the forgotten one.
    AltStableWarbandDB[ME].outbox = {
        { to = HID, at = NOW - 10, items = { [104] = 1 } },
        { to = GONE, at = NOW - 10, items = { [105] = 1 } },
    }
    -- Nobody's recipes until the crafting section says so.
    AltStableProfessionsDB = {}
    -- The bags Warband rescans when its tab opens: what Kaleid's record says.
    WoW.containers = { [0] = { size = 1, { itemID = 101, stackCount = 2, hyperlink = "|Hitem:101|h" } } }
    WoW.items = {
        [101] = { name = "Linen Cloth", classID = 7, quality = 1, icon = 1 },
        [102] = { name = "Wool Cloth", classID = 7, quality = 1, icon = 2 },
        [103] = { name = "Silk Cloth", classID = 7, quality = 1, icon = 3 },
        [200] = { name = "Band of Thorns", classID = 4, quality = 2, icon = 4 },
    }
end

------------------------------------------------------------
-- The counts
------------------------------------------------------------
do
    World()
    local snap = S.BuildSnapshot()
    eq("a hidden character's copies are left out of the total", snap[101] and snap[101].total, 10)
    eq("  the most held first", snap[101] and snap[101].holders[1].name, "Brom")
    eq("  with each place", snap[101] and (snap[101].holders[1].bags .. "/" .. snap[101].holders[1].bank), "5/3")
    eq("a hidden sender's mail counts under the listed recipient",
       snap[103] and snap[103].holders[1].guid .. ":" .. snap[103].holders[1].mail, ME .. ":4")
    check("mail to a hidden character doesn't", snap[104] == nil)
    check("mail to a forgotten character doesn't", snap[105] == nil)
    check("nor what a forgotten character sent", snap[106] == nil)
    eq("two of one ring worn count two", snap[200] and snap[200].holders[1].worn, 2)
    check("an empty slot is nothing", snap[0] == nil)

    AltStableConfig.warbandMail = false
    snap = S.BuildSnapshot()
    check("the mail option off: no mail, incoming or stored", snap[103] == nil)
    eq("  bags and bank still count", snap[101] and snap[101].total, 10)
    eq("  and worn gear", snap[200] and snap[200].total, 2)
    AltStableConfig.warbandMail = nil

    local held = AltStable.ItemMapsFor
    AltStable.ItemMapsFor = nil
    snap = S.BuildSnapshot()
    check("Warband off: no bags, bank or mail", snap[101] == nil)
    eq("  worn gear still", snap[200] and snap[200].total, 2)
    AltStable.ItemMapsFor = held
end

------------------------------------------------------------
-- Matching and names
------------------------------------------------------------
local function Window() return S._test.Window() end
local function Type(text)
    local box = Window().box
    box:SetText(text)
    local fn = box:GetScript("OnTextChanged"); if fn then fn(box, true) end
    WoW.flushTimers()
end
local function RowIDs()
    local out = {}
    for _, e in ipairs(S.rows) do out[#out + 1] = e.id end
    return table.concat(out, ",")
end
local function Loaded(id)
    local ev = Window().events
    ev:GetScript("OnEvent")(ev, "ITEM_DATA_LOAD_RESULT", id, true)
end
local function Requested(id)
    for _, x in ipairs(WoW.itemLoadRequests or {}) do if x == id then return true end end
    return false
end

do
    World()
    WoW.items[102] = nil                     -- not in the client's cache yet
    WoW.itemLoadRequests = {}
    AltStable.ShowSearch()
    check("the window opens", Window():IsShown())
    -- Readable over the sheet (seen in game, 2026-11-28): the list on the
    -- opaque reading surface, inside the window's corners, and a row's two
    -- lines never wrapping into the next row.
    local surface = Window().surface
    check("(the glass skin is on)", AltStable.SkinIsGlass())
    check("the list sits on a reading surface", surface ~= nil)
    eq("  opaque", surface and surface._colorTexture and surface._colorTexture[4], 1)
    eq("  the sheet's own", surface and surface._colorTexture and surface._colorTexture[1],
       AltStable.SkinDataColor()[1])
    eq("  inside the window's corners", surface and surface:GetMaskTexture(1), Window()._glass.mask)
    check("a row's item name stays on one line", not Window().rows[1].name:GetWordWrap())
    check("  and its holders line", not Window().rows[1].who:GetWordWrap())
    check("an uncached name is asked for", Requested(102))
    check("a cached one isn't", not Requested(101))
    Type("l")
    eq("one letter: nothing yet", #S.rows, 0)
    eq("  and says why", Window().status:GetText(), "Looking up 1 item name")
    Type("LINEN")
    eq("matched by part of the name, either case", RowIDs(), "101")
    Type("cloth")
    eq("most held first", RowIDs(), "101,103")
    Type("wool")
    eq("a name not loaded yet can't match", #S.rows, 0)
    WoW.items[102] = { name = "Wool Cloth", classID = 7, quality = 1, icon = 2 }
    local timersBefore = #WoW.timers
    Loaded(999)                              -- someone else's load
    eq("  another addon's load changes nothing", S.outstanding, 1)
    eq("  and schedules no repaint", #WoW.timers, timersBefore)
    Loaded(102)
    WoW.flushTimers()
    eq("  and matches once it arrives", RowIDs(), "102")
    eq("the holders line", (S.HoldersLine(S.rows[1]):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")), "Brom 1")
    eq("the hover's places", S.PlacesText(S.BuildSnapshot()[101].holders[1]), "5 in bags, 3 in the bank")

    -- A load that answers without a name retires the item: never asked again.
    AltStableWarbandDB[ALT].bags[107] = 1
    WoW.itemLoadRequests = {}
    AltStable.NotifyItemDataChanged()
    WoW.flushTimers()
    check("an item first seen in a later rebuild is asked for", Requested(107))
    Loaded(107)
    eq("  no name in the answer: retired", S.names[107], false)
    eq("  and nothing left pending", S.outstanding, 0)
    WoW.itemLoadRequests = {}
    AltStable.NotifyItemDataChanged()
    WoW.flushTimers()
    check("  never asked again this session", not Requested(107))

    -- At most twenty at a time; one answer lets the next go.
    for id = 3001, 3025 do AltStableWarbandDB[ALT].bags[id] = 1 end
    WoW.itemLoadRequests = {}
    AltStable.NotifyItemDataChanged()
    WoW.flushTimers()
    eq("twenty loads asked for at once", #WoW.itemLoadRequests, 20)
    Loaded(WoW.itemLoadRequests[1])
    eq("  one answer, one more", #WoW.itemLoadRequests, 21)
    -- No answer in ten seconds: given up, so the status can't stick.
    local realGetTime = GetTime
    GetTime = function() return 11 end
    WoW.flushTimers(); WoW.flushTimers()
    GetTime = realGetTime
    check("  a load with no answer is given up", S.outstanding < 20, tostring(S.outstanding))

    -- Closing lets it all go.
    Window():Hide()
    eq("closed: the names are dropped", next(S.names), nil)
    eq("  and the queue", S.outstanding + #S.queue, 0)
    WoW.itemLoadRequests = {}
    WoW.timers = {}
    AltStable.NotifyItemDataChanged()
    eq("  a change while closed schedules nothing", #WoW.timers, 0)
    WoW.flushTimers()
    eq("  and rebuilds nothing", #WoW.itemLoadRequests, 0)
    for id = 3001, 3025 do AltStableWarbandDB[ALT].bags[id] = nil end
    AltStableWarbandDB[ALT].bags[107] = nil
end

------------------------------------------------------------
-- Keeping current while open
------------------------------------------------------------
do
    World()
    AltStable.ShowSearch("linen")
    WoW.flushTimers()
    eq("opened with a query", RowIDs(), "101")
    eq("  the box says it", Window().box:GetText(), "linen")
    -- Our own bags rescanned, a stack grown, the Warband tab not open: the
    -- scan restamps, and the search hears it.
    WoW.containers = { [0] = { size = 1, { itemID = 101, stackCount = 9, hyperlink = "|Hitem:101|h" } } }
    WT.ScanBags()
    WoW.flushTimers()
    eq("a bag scan with the Warband tab closed updates the total", S.rows[1] and S.rows[1].total, 17)
    -- What a sync brings: Brom's record, newer.
    -- Its bags section newer than ours (bt=, the section's own stamp).
    local blob = WT.SerializePlayer(ALT)
    AltStableWarbandDB[ALT].bags[101] = 50
    blob = blob:gsub("101,5", "101,6"):gsub("|s=%d+", "|s=" .. (NOW + 5)):gsub("|bt=%d+", "|bt=" .. (NOW + 5))
    WT.DeserializePlayer(ALT, blob)
    WoW.flushTimers()
    eq("received inventory updates it too", S.rows[1] and S.rows[1].holders[1].bags, 6)
    -- A correction under the SAME stamp (two moves in one second): Warband
    -- applies it and returns false, so no sheet refresh follows - the search
    -- hears it from the restamp alone (Codex review of the plan).
    eq("  (the held bags are stamped as the blob)", AltStableWarbandDB[ALT].bagsStamp, NOW + 5)
    local refreshes, realRefresh = 0, AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...) refreshes = refreshes + 1; return realRefresh(...) end
    WT.DeserializePlayer(ALT, blob:gsub("101,6", "101,7"))
    WoW.flushTimers()
    AltStable.RefreshSheet = realRefresh
    eq("a same-stamp correction updates it, with no sheet refresh", S.rows[1] and S.rows[1].holders[1].bags, 7)
    eq("  (none happened)", refreshes, 0)
    -- The selection follows its item through a re-sort.
    Type("cloth")
    S.selected = 1
    local keep = S.rows[1].id
    AltStableWarbandDB[ME].bags[103] = 500    -- moves past the selected one
    AltStable.NotifyItemDataChanged()
    WoW.flushTimers()
    check("  (it moved)", S.rows[1].id ~= keep)
    eq("a re-sort keeps the selected item selected", S.rows[S.selected].id, keep)
    Window():Hide()
end

------------------------------------------------------------
-- Enter: the Warband tab, on the first holder, the item lit
------------------------------------------------------------
local rawShift = rawget(_G, "IsShiftKeyDown")
local shift = false
rawset(_G, "IsShiftKeyDown", function() return shift end)

local function Enter()
    local box = Window().box
    box:GetScript("OnEnterPressed")(box)
end
local function LitIDs()
    local out = {}
    for _, cell in ipairs(wb.cells) do
        if cell:IsShown() and cell.entry and cell.lit and cell.lit:IsShown() then out[#out + 1] = cell.entry.id end
    end
    return table.concat(out, ",")
end
local function ShownIDs()
    local out = {}
    for _, cell in ipairs(wb.cells) do
        if cell:IsShown() and cell.entry then out[#out + 1] = cell.entry.id end
    end
    table.sort(out)
    return table.concat(out, ",")
end

do
    World()
    AltStableConfig.warbandTab = 1
    AltStableConfig.enableOpenAnimation = false
    check("the sheet starts closed", not (AltStableSheet and AltStableSheet:IsShown()))
    -- Saved as Personal: the view the search opens must not change it.
    AltStableConfig.warbandScope = "personal"
    local scopeBefore = AltStableConfig.warbandScope
    AltStable.ShowSearch("linen")
    WoW.flushTimers()
    Enter()
    check("Enter from a closed sheet opens it", AltStableSheet and AltStableSheet:IsShown())
    check("  on the Warband tab", wb.isActive == true)
    eq("  focused on the first holder", wb.focus and wb.focus.guid, ALT)
    eq("  showing only what they hold", ShownIDs(), "101,102")
    eq("  with the item lit", LitIDs(), "101")
    check("  the search closes", not Window():IsShown())
    check("  the status says whose", (wb.StatusText() or ""):find("Showing Brom", 1, true) ~= nil, wb.StatusText())
    check("  with a way back", wb.backBtn:IsShown())
    -- Warband's own search box dims what doesn't match; never the lit item.
    wb.search = "nothing matches this"
    wb.ApplySearchDim()
    local litAlpha, otherAlpha
    for _, cell in ipairs(wb.cells) do
        if cell:IsShown() and cell.entry then
            if cell.entry.id == 101 then litAlpha = cell:GetAlpha() else otherAlpha = cell:GetAlpha() end
        end
    end
    eq("  Warband's own search never dims the lit item", litAlpha, 1)
    eq("  (it dims the others)", otherAlpha, 0.25)
    wb.search = ""
    wb.ApplySearchDim()
    eq("  the saved tab untouched", AltStableConfig.warbandTab, 1)
    eq("  and the saved scope", AltStableConfig.warbandScope, scopeBefore)

    wb.backBtn:GetScript("OnClick")(wb.backBtn)
    eq("Back: the focus goes", wb.focus, nil)
    check("  and the button with it", not wb.backBtn:IsShown())
    eq("  the saved view: Personal, Kaleid's own (bags, and the mail coming)", ShownIDs(), "101,103")
    AltStableConfig.warbandScope = nil

    -- Warband already up: no re-click (it would rescan and rebuild).
    local activations = 0
    local realActivate = plugin.OnActivate
    plugin.OnActivate = function(...) activations = activations + 1; return realActivate(...) end
    AltStable.ShowSearch("wool")
    WoW.flushTimers()
    Enter()
    eq("Warband already open: not activated again", activations, 0)
    eq("  focused all the same", wb.focus and wb.focus.itemID, 102)
    -- The sheet closed with Warband still its tab: shown again first.
    AltStableSheet:Hide()
    AltStable.ShowSearch("linen")
    WoW.flushTimers()
    Enter()
    check("a closed sheet whose tab is Warband is shown again", AltStableSheet:IsShown())
    eq("  focused", wb.focus and wb.focus.itemID, 101)
    eq("  still not activated again", activations, 0)
    plugin.OnActivate = realActivate

    -- The focus leaves when it no longer holds.
    eq("  on Brom", wb.focus and wb.focus.guid, ALT)
    AltStableConfig.hiddenCharacters[ALT] = true
    wb.Refresh()
    eq("the holder hidden: back to the saved view", wb.focus, nil)
    AltStableConfig.hiddenCharacters[ALT] = nil
    AltStable.ShowSearch("linen"); WoW.flushTimers(); Enter()
    AltStableWarbandDB[ALT].bags[101] = nil
    AltStableWarbandDB[ALT].bank[101] = nil
    wb.Refresh()
    eq("the holder's last copy gone: back too", wb.focus, nil)
    check("  with their other items still there (the case the empty view missed)",
          AltStableWarbandDB[ALT].bags[102] == 1)
end

-- The page the item is on: not the saved one, and never saved.
do
    World()
    AltStableConfig.warbandTab = 1
    WoW.items[201] = { name = "Healing Potion", classID = 0, quality = 1, icon = 5 }
    WoW.items[301] = { name = "Quest Letter", classID = 12, quality = 1, icon = 6 }
    AltStableWarbandDB[ALT].bags[201] = 3
    AltStableWarbandDB[ALT].bags[301] = 1
    AltStable.ShowSearch("potion"); WoW.flushTimers(); Enter()
    eq("an item on the second tab shows that tab", wb._sel, 2)
    eq("  lit there", LitIDs(), "201")
    eq("  the saved tab still the first", AltStableConfig.warbandTab, 1)
    AltStable.ShowSearch("letter"); WoW.flushTimers(); Enter()
    eq("an item in no tab shows Other", wb._sel, "other")
    eq("  still not saved", AltStableConfig.warbandTab, 1)
    -- Editing a tab in this view saves the edit, not a tab choice.
    WT.OpenDialog(2)
    WT.SaveDialog()
    eq("a tab edited in the search's view keeps the saved tab", AltStableConfig.warbandTab, 1)
    wb.ClearFocus(); wb.Refresh()
    WT.OpenDialog(2)
    WT.SaveDialog()
    eq("  outside it, saving selects the tab as before", AltStableConfig.warbandTab, 2)
    -- A tab clicked: the player's own view again.
    AltStableConfig.warbandTab = 1
    AltStable.ShowSearch("potion"); WoW.flushTimers(); Enter()
    local railBtn
    for _, b in ipairs(wb.tabBtns) do if b:IsShown() and b.key == 1 then railBtn = b end end
    if railBtn then railBtn:GetScript("OnClick")(railBtn) end
    eq("a tab chosen on the rail ends the focus", wb.focus, nil)
end

-- Enter pressed within the typing delay acts on what the box says, not on
-- the last query's rows (Codex review of #548).
do
    World()
    AltStableConfig.warbandTab = 1
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    eq("(the rows are the last query's)", RowIDs(), "101")
    local box = Window().box
    box:SetText("wool")
    box:GetScript("OnTextChanged")(box, true)   -- typed; its timer not fired yet
    Enter()
    eq("Enter right after typing opens the item now typed", wb.focus and wb.focus.itemID, 102)
    wb.ClearFocus()
    local uiHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return false end
    WoW.chatBox, WoW.chatActive, WoW.chatRefuses = nil, nil, nil
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    box:SetText("wool")
    box:GetScript("OnTextChanged")(box, true)
    shift = true
    Enter()
    shift = false
    eq("  Shift+Enter links it", WoW.chatBox and WoW.chatBox.inserted[1], "|Hitem:102|h[Wool Cloth]|h")
    AltStable.IsGameUIHidden = uiHidden
    WoW.flushTimers()
    Window():Hide()
end

-- Alt+Z hides UIParent, and with it the window: that isn't closing it. It
-- comes back with its data (Codex review of #548).
do
    World()
    -- Opened with the UI shown, so it isn't lifted out from under UIParent.
    -- The sheet's showcase may have hidden UIParent already: shown first, so
    -- the Hide below is a real change and fires the window's OnHide.
    local uiWasShown = UIParent:IsShown()
    UIParent:Show()
    local uiHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return false end
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    AltStable.IsGameUIHidden = uiHidden
    eq("(opened under UIParent)", Window():GetParent(), UIParent)
    UIParent:Hide()
    check("(the game UI hidden hides the window from view)", not Window():IsVisible())
    check("  but it is still open", Window():IsShown())
    check("  and keeps its data", S.snap ~= nil and S.snap[101] ~= nil)
    UIParent:Show()
    Type("cloth")
    eq("back with the UI, it still searches", RowIDs(), "101,103,102")
    AltStableWarbandDB[ALT].bags[102] = 40
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("  and still hears changes", S.rows[1] and S.rows[1].id, 102)
    Window():Hide()
    eq("closing it for real still lets go", S.snap, nil)
    if not uiWasShown then UIParent:Hide() end
end

-- Worn only, or nothing Warband shows: the search stays, and says why.
do
    World()
    AltStable.ShowSearch("thorns"); WoW.flushTimers()
    Enter()
    check("a worn-only item keeps the search open", Window():IsShown())
    eq("  and says who wears it", Window().status:GetText(), "Worn by Kaleid.")
    local held = AltStable.ItemMapsFor
    AltStable.ItemMapsFor = nil
    Type("linen")
    check("Warband off: the warning shows", Window().warn:IsShown())
    AltStable.ItemMapsFor = held
    Window():Hide()
end

-- The animation on: the item is still in view at the end of the trip.
do
    World()
    for id = 4001, 4300 do
        AltStableWarbandDB[ALT].bags[id] = 1
        WoW.items[id] = { name = "Rock " .. id, classID = 7, quality = 0, icon = 7 }
    end
    WoW.items[101].quality = 0
    WoW.items[101].name = "Zzz Linen"          -- sorts last on its tab
    -- Back on a sheet tab first, so Enter switches with a trip.
    local T = AltStable._test
    for _, b in ipairs(T.sidebarBtns) do
        if b.sectionId == "summary" then b:GetScript("OnClick")(b) end
    end
    AltStableConfig.enableOpenAnimation = true
    AltStable.ShowSearch("zzz linen"); WoW.flushTimers(); Enter()
    local r = T.WindowAnimRunner and T.WindowAnimRunner()
    local fn = r and r:GetScript("OnUpdate")
    if fn then fn(r, 0.3) end
    eq("after the trip, the item is on screen and lit", LitIDs(), "101")
    check("  scrolled to it", (wb.scrollRow or 0) > 0, tostring(wb.scrollRow))
    AltStableConfig.enableOpenAnimation = false
    wb.ClearFocus()
end

------------------------------------------------------------
-- Shift: the link into chat
------------------------------------------------------------
do
    World()
    local realInsertLink = ChatFrameUtil.InsertLink
    -- Never through InsertLink: it may hand the link to the auction search.
    ChatFrameUtil.InsertLink = function() error("InsertLink called") end
    -- The sheet's showcase may hide the game UI; these are about chat with it shown.
    local uiHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return false end
    WoW.chatBox, WoW.chatActive, WoW.chatRefuses = nil, nil, nil
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    shift = true
    Enter()
    local box = WoW.chatBox
    eq("Shift+Enter with no draft opens chat with the link", box and box.inserted[1], "|Hitem:101|h[Linen Cloth]|h")
    eq("  the keyboard goes to chat", WoW.focus, box)
    check("  the search stays open", Window():IsShown())

    local draft = WoW.makeFrame("EditBox")
    draft.inserted = {}
    draft.Insert = function(self, t) self.inserted[#self.inserted + 1] = t end
    WoW.chatActive = draft
    Enter()
    eq("an open draft gets the link", draft.inserted[1], "|Hitem:101|h[Linen Cloth]|h")
    eq("  and the keyboard", WoW.focus, draft)

    WoW.chatActive, WoW.chatRefuses, WoW.chatBox = nil, true, nil
    Enter()
    eq("chat refusing to open: said", Window().status:GetText(), "Chat isn't available.")
    check("  nothing inserted", #WoW.chatBox.inserted == 0)
    WoW.chatRefuses = nil

    local realHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return true end
    WoW.chatBox = nil
    Enter()
    -- Presentation mode: chat is hidden, so the link to copy (owner, 2026-11-28).
    local aside = Window().aside
    check("the game UI hidden: the copy line instead", aside:IsShown() and aside.mode == "copy")
    eq("  as a chat line that prints the link", aside:GetText(),
       '/script DEFAULT_CHAT_FRAME:AddMessage("\\124Hitem:101\\124h[Linen Cloth]\\124h");')
    check("  selected, for Ctrl+C", aside._highlighted == true and aside:HasFocus())
    check("  in the search box's place", not Window().box:IsShown())
    check("  chat untouched", WoW.chatBox == nil)
    aside:GetScript("OnEscapePressed")(aside)
    check("Escape: the search box is back", Window().box:IsShown() and not aside:IsShown())
    check("  with the keyboard", Window().box:HasFocus())
    AltStable.IsGameUIHidden = function() return false end

    -- A link the client hasn't cached: asked for, and said.
    AltStableWarbandDB[ALT].bags[108] = 1
    S.names[108] = "Mageweave"; S.folded[108] = "mageweave"
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    Type("mageweave")
    WoW.itemLoadRequests = {}
    Enter()
    eq("an uncached link: said", Window().status:GetText(), "Item link loading, try again.")
    check("  and asked for", Requested(108))

    local row = Window().rows[1]
    WoW.chatBox, WoW.chatActive = nil, nil
    Type("linen")
    row:GetScript("OnClick")(row)
    eq("Shift-click links too", WoW.chatBox and WoW.chatBox.inserted[1], "|Hitem:101|h[Linen Cloth]|h")
    shift = false
    ChatFrameUtil.InsertLink = realInsertLink
    AltStable.IsGameUIHidden = uiHidden
    Window():Hide()
end

------------------------------------------------------------
-- The row menu: send the link straight out, or copy it (owner, 2026-11-28).
-- Sending needs no chat box, so it works in presentation mode too.
------------------------------------------------------------
do
    World()
    local uiHidden = AltStable.IsGameUIHidden
    AltStable.IsGameUIHidden = function() return false end
    local realShowMenu, menu = AltStable.ShowMenu, nil
    AltStable.ShowMenu = function(list, onPick, ...)
        menu = { list = list, pick = onPick }
        return realShowMenu(list, onPick, ...)
    end
    local function Entry(id)
        for _, x in ipairs(menu and menu.list or {}) do if x.id == id then return x end end
    end
    local function RightClick(i)
        local row = Window().rows[i or 1]
        menu = nil
        row:GetScript("OnClick")(row, "RightButton")
    end
    local function LastSent() return WoW.chatSent and WoW.chatSent[#WoW.chatSent] end
    WoW.chatSent, WoW.chatBox, WoW.target, WoW.chatLockdown = {}, nil, nil, nil
    WoW.inGuild, WoW.inGroup, WoW.inRaid = nil, nil, nil

    AltStable.ShowSearch("linen"); WoW.flushTimers()
    local row = Window().rows[1]
    WoW.tooltipLines = {}
    row:GetScript("OnEnter")(row)
    local hint = false
    for _, l in ipairs(WoW.tooltipLines) do
        if l == "Right-click: send or copy the link" then hint = true end
    end
    check("the hover says what a right-click does", hint)
    row:GetScript("OnLeave")(row)

    local clicks = table.concat(Window().rows[1]._clicks or {}, ",")
    check("a row hears the right button", clicks:find("RightButtonUp", 1, true) ~= nil)
    check("  and the left", clicks:find("LeftButtonUp", 1, true) ~= nil)
    RightClick()
    check("a right-click opens the row's menu", menu ~= nil)
    eq("  titled with the item", menu and menu.list[1].title and menu.list[1].text, "Linen Cloth")
    check("  Shift+Enter's link, there too", Entry("link") and not Entry("link").disabled)
    check("  no guild: greyed", Entry("GUILD") and Entry("GUILD").disabled)
    eq("    and why", Entry("GUILD") and Entry("GUILD").why, "You aren't in a guild.")
    check("  no group: party and raid greyed", Entry("PARTY").disabled and Entry("RAID").disabled)
    check("  no target: no whisper to it", Entry("target") == nil)
    check("  whisper to a name, and copy, always", Entry("whisper") and Entry("copy")
          and not Entry("whisper").disabled and not Entry("copy").disabled)

    WoW.inGuild, WoW.inGroup = true, true
    RightClick()
    check("in a guild and a group: guild and party open", not Entry("GUILD").disabled and not Entry("PARTY").disabled)
    check("  raid still greyed", Entry("RAID").disabled)
    menu.pick("GUILD")
    eq("Send to guild: the link goes out", LastSent() and LastSent().text, "|Hitem:101|h[Linen Cloth]|h")
    eq("  to the guild", LastSent() and LastSent().chatType, "GUILD")
    -- Not "sent" until chat echoes it: SendChatMessage returns nothing
    -- (Codex review of #561).
    eq("  said as sending", Window().status:GetText(), "Sending Linen Cloth to guild...")
    check("  no chat box needed", WoW.chatBox == nil)
    -- A chat event as the client sends it (CHAT_MSG_*): the text, the other
    -- player's name, ..., the sender's GUID 12th.
    local function Echo(event, text, who, guid)
        local ev = Window().events
        ev:GetScript("OnEvent")(ev, event, text, who, "", "", who, "", 0, 0, "", 0, 1, guid)
    end
    Echo("CHAT_MSG_GUILD", "|cffffffff|Hitem:102::::|h[Wool Cloth]|h|r", "Kaleid", ME)
    eq("another item's echo: still sending", Window().status:GetText(), "Sending Linen Cloth to guild...")
    -- Someone else linking the same item isn't our send (Codex review of #561).
    Echo("CHAT_MSG_GUILD", "mine too |Hitem:101::::|h[Linen Cloth]|h", "Brom", ALT)
    eq("a guildmate linking the same item: still sending", Window().status:GetText(),
       "Sending Linen Cloth to guild...")
    Echo("CHAT_MSG_GUILD", "|Hitem:101::::|h[Linen Cloth]|h", "Kaleid", nil)
    eq("  no sender to tell by: still sending", Window().status:GetText(), "Sending Linen Cloth to guild...")
    Echo("CHAT_MSG_GUILD", "look |cffffffff|Hitem:101::::|h[Linen Cloth]|h|r", "Kaleid", ME)
    eq("its echo, said by this character: sent", Window().status:GetText(), "Sent to guild: Linen Cloth.")
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("  still said after a refresh of the data", Window().status:GetText(), "Sent to guild: Linen Cloth.")
    Echo("CHAT_MSG_GUILD", "|Hitem:101|h[Linen Cloth]|h", "Kaleid", ME)
    eq("  heard once", Window().status:GetText(), "Sent to guild: Linen Cloth.")
    RightClick(); menu.pick("GUILD")
    WoW.flushTimers()
    eq("no echo in time: said", Window().status:GetText(), "Chat didn't confirm sending Linen Cloth to guild.")
    RightClick(); menu.pick("GUILD")
    local realSecret = rawget(_G, "issecretvalue")
    rawset(_G, "issecretvalue", function() return true end)
    Echo("CHAT_MSG_GUILD", "|Hitem:101|h[Linen Cloth]|h", "Kaleid", ME)
    rawset(_G, "issecretvalue", realSecret)
    eq("a secret echo isn't compared", Window().status:GetText(), "Sending Linen Cloth to guild...")
    WoW.flushTimers()
    RightClick(); menu.pick("PARTY")
    eq("Send to party", LastSent() and LastSent().chatType, "PARTY")
    WoW.inRaid = true
    RightClick()
    check("in a raid: raid opens", not Entry("RAID").disabled)
    menu.pick("RAID")
    eq("Send to raid", LastSent() and LastSent().chatType, "RAID")

    -- The target: whispered by "Name Surname", the one at the menu's opening.
    WoW.target = { name = "Brom Ironfoot" }
    RightClick()
    eq("a player targeted: whisper them", Entry("target") and Entry("target").text, "Whisper Brom Ironfoot")
    WoW.target = { name = "Someone Else" }
    menu.pick("target")
    eq("  whispered", LastSent() and LastSent().chatType, "WHISPER")
    eq("  the one targeted when the menu opened", LastSent() and LastSent().target, "Brom Ironfoot")
    WoW.target = { name = "Grukk Bonecrusher", enemy = true }
    RightClick()
    check("the other faction: greyed", Entry("target") and Entry("target").disabled)
    WoW.target = { name = "Hogger", player = false }
    RightClick()
    check("a creature targeted: no whisper to it", Entry("target") == nil)
    WoW.target = nil

    -- Whisper to a typed name.
    local sent = #WoW.chatSent
    RightClick(); menu.pick("whisper")
    local aside = Window().aside
    check("Whisper to...: a name box", aside:IsShown() and aside.mode == "name" and aside:GetText() == "")
    check("  in the search box's place, with the keyboard", not Window().box:IsShown() and aside:HasFocus())
    eq("  and says what for", Window().status:GetText(), "Whisper Linen Cloth to: type a name, then Enter.")
    -- A refresh while it is open keeps the instructions (Codex review of #561).
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("  still, after a refresh of the data", Window().status:GetText(),
       "Whisper Linen Cloth to: type a name, then Enter.")
    Type("linen"); S._test.Rerun()
    eq("  and after a rerun", Window().status:GetText(), "Whisper Linen Cloth to: type a name, then Enter.")
    aside:SetText("  Kaleid Sumner ")
    aside:GetScript("OnTextChanged")(aside, true)
    eq("  a name typed stays (not read-only)", aside:GetText(), "  Kaleid Sumner ")
    aside:GetScript("OnEnterPressed")(aside)
    eq("Enter whispers the name, trimmed", LastSent() and LastSent().target, "Kaleid Sumner")
    eq("  the link", LastSent() and LastSent().text, "|Hitem:101|h[Linen Cloth]|h")
    check("  the search box is back", Window().box:IsShown() and not aside:IsShown())
    eq("  said as sending", Window().status:GetText(), "Sending Linen Cloth to Kaleid Sumner...")
    Echo("CHAT_MSG_WHISPER_INFORM", "|Hitem:101::::|h[Linen Cloth]|h", "Brom Ironfoot", ME)
    eq("  a whisper of it to someone else: still sending", Window().status:GetText(),
       "Sending Linen Cloth to Kaleid Sumner...")
    Echo("CHAT_MSG_WHISPER_INFORM", "|Hitem:101::::|h[Linen Cloth]|h", nil, ME)
    eq("  no recipient to tell by: still sending", Window().status:GetText(),
       "Sending Linen Cloth to Kaleid Sumner...")
    Echo("CHAT_MSG_WHISPER_INFORM", "|cffffffff|Hitem:101::::|h[Linen Cloth]|h|r", "kaleid sumner-Realm", ME)
    eq("  whispered to them (either case, a realm added): sent", Window().status:GetText(),
       "Sent to Kaleid Sumner: Linen Cloth.")
    -- Someone not online: the system message chat would show (hidden in
    -- presentation mode) says so here.
    rawset(_G, "ERR_CHAT_PLAYER_NOT_FOUND_S", "No player named '%s' is currently playing.")
    local function Listening(ev)
        local t = Window().events._events
        return t ~= nil and t[ev] ~= nil and t[ev] ~= false
    end
    RightClick(); menu.pick("whisper")
    aside:SetText("Nobody Here")
    aside:GetScript("OnEnterPressed")(aside)
    check("a whisper listens for its echo and for not-found",
          Listening("CHAT_MSG_WHISPER_INFORM") and Listening("CHAT_MSG_SYSTEM"))
    Echo("CHAT_MSG_SYSTEM", "No player named 'Someone Else' is currently playing.")
    eq("another name's error: still sending", Window().status:GetText(), "Sending Linen Cloth to Nobody Here...")
    Echo("CHAT_MSG_SYSTEM", "No player named 'nobody here' is currently playing.")
    eq("not online: said", Window().status:GetText(), "No player named Nobody Here is playing.")
    check("  and no longer listening", not Listening("CHAT_MSG_WHISPER_INFORM") and not Listening("CHAT_MSG_SYSTEM"))
    RightClick(); menu.pick("GUILD")
    check("a guild send listens for its echo only", Listening("CHAT_MSG_GUILD") and not Listening("CHAT_MSG_SYSTEM"))
    Echo("CHAT_MSG_SYSTEM", "No player named 'Nobody Here' is currently playing.")
    eq("a guild send hears no whisper error", Window().status:GetText(), "Sending Linen Cloth to guild...")
    WoW.flushTimers()
    sent = #WoW.chatSent
    RightClick(); menu.pick("whisper")
    aside:GetScript("OnEnterPressed")(aside)
    eq("no name: nothing sent", #WoW.chatSent, sent)
    RightClick(); menu.pick("whisper")
    S.message = "Sent to guild: Linen Cloth."      -- an earlier answer, left behind
    aside:SetText("Kaleid Sumner")
    aside:GetScript("OnEscapePressed")(aside)
    check("  an earlier answer doesn't come back", Window().status:GetText() ~= "Sent to guild: Linen Cloth.")
    eq("Escape: nothing sent", #WoW.chatSent, sent)
    check("  the search box is back", Window().box:IsShown() and not aside:IsShown())
    check("  the instructions gone", Window().status:GetText() ~= "Whisper Linen Cloth to: type a name, then Enter.")
    RightClick(); menu.pick("whisper")
    aside:GetScript("OnEditFocusLost")(aside)
    check("a click elsewhere puts the search box back", Window().box:IsShown() and not aside:IsShown())

    -- Copy: the chat line, selected and read-only.
    RightClick(); menu.pick("copy")
    check("Copy the link: the copy line", aside:IsShown() and aside.mode == "copy")
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("  its instructions, through a refresh", Window().status:GetText(),
       "Selected: press Ctrl+C. Pasted into chat, it shows the link.")
    eq("  the chat line", aside:GetText(),
       '/script DEFAULT_CHAT_FRAME:AddMessage("\\124Hitem:101\\124h[Linen Cloth]\\124h");')
    aside._highlighted = nil
    aside:SetText("oops")
    aside:GetScript("OnTextChanged")(aside, true)
    check("  typed over: put back, selected", aside:GetText():find("^/script") and aside._highlighted)
    aside._highlighted = nil
    aside:GetScript("OnKeyUp")(aside, "LCTRL")
    check("  still selected after a key", aside._highlighted == true)
    aside:GetScript("OnEnterPressed")(aside)
    check("  Enter puts the search box back", Window().box:IsShown() and not aside:IsShown())
    eq("  nothing sent", #WoW.chatSent, sent)
    eq("the chat line escapes quotes and backslashes",
       S.ScriptLine('|cff|Hitem:1|h[A "B" \\C]|h|r'),
       '/script DEFAULT_CHAT_FRAME:AddMessage("\\124cff\\124Hitem:1\\124h[A \\"B\\" \\\\C]\\124h\\124r");')

    -- A copy line left open when the window closes: the keyboard let go, and
    -- the search box next time.
    RightClick(); menu.pick("copy")
    Window():Hide()
    check("closed while copying: the keyboard let go", WoW.focus ~= aside and WoW.focus ~= Window().box)
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    Window():Hide()
    check("closed while searching: the keyboard let go", WoW.focus ~= Window().box)
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    check("closed and reopened: the search box", Window().box:IsShown() and not aside:IsShown())
    RightClick(); menu.pick("copy")
    AltStable.ShowSearch("wool"); WoW.flushTimers()
    check("/alts search while copying: the search box takes it", Window().box:IsShown()
          and Window().box:GetText() == "wool")
    Type("linen"); WoW.flushTimers()

    -- Chat locked down: said, nothing sent.
    WoW.chatLockdown = true
    RightClick(); menu.pick("GUILD")
    eq("chat locked down: nothing sent", #WoW.chatSent, sent)
    eq("  and said", Window().status:GetText(), "Chat can't be sent right now.")
    WoW.chatLockdown = nil

    -- An uncached link: asked for, nothing sent.
    AltStableWarbandDB[ALT].bags[108] = 1
    S.names[108] = "Mageweave"; S.folded[108] = "mageweave"
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    Type("mageweave"); WoW.flushTimers()
    WoW.itemLoadRequests = {}
    RightClick(); menu.pick("GUILD")
    eq("an uncached link: nothing sent", #WoW.chatSent, sent)
    check("  and asked for", Requested(108))

    -- The menu goes with the window (Codex review of #561): in combat it
    -- doesn't take the keyboard, so Escape can close the search under it.
    local function MenuUp()
        local m = rawget(_G, "AltStableCharacterMenu")
        return m ~= nil and m:IsShown()
    end
    Type("linen"); WoW.flushTimers()
    RightClick()
    check("(the menu is up, and the search's)", MenuUp() and S.menu ~= nil)
    local latePick, before = menu.pick, #WoW.chatSent
    Window():Hide()
    check("the window closed: its menu closed", not MenuUp() and S.menu == nil)
    latePick("GUILD")
    eq("  a pick after it does nothing", #WoW.chatSent, before)
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    RightClick()
    realShowMenu({ { id = "x", text = "Someone else's" } }, function() end)
    check("another menu in its place: not the search's", S.menu == nil)
    Window():Hide()
    check("  and left open when the search closes", MenuUp())
    AltStable.CloseCharacterMenu()
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    RightClick(); menu.pick("GUILD")
    Window():Hide()
    check("the window closed while sending: no longer listening", S.sending == nil)
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    sent = #WoW.chatSent

    -- Presentation mode: sending still works; the chat box link is greyed.
    Type("linen"); WoW.flushTimers()
    AltStable.IsGameUIHidden = function() return true end
    RightClick()
    check("presentation mode: Link in chat greyed", Entry("link").disabled)
    eq("  and why", Entry("link").why, "Chat is hidden in presentation mode: copy it instead.")
    menu.pick("GUILD")
    eq("  Send to guild still goes", LastSent() and LastSent().chatType, "GUILD")
    eq("  (one more sent)", #WoW.chatSent, sent + 1)

    AltStable.ShowMenu = realShowMenu
    AltStable.IsGameUIHidden = uiHidden
    if AltStable.CloseCharacterMenu then AltStable.CloseCharacterMenu() end
    WoW.inGuild, WoW.inGroup, WoW.inRaid = nil, nil, nil
    Window():Hide()
end

------------------------------------------------------------
-- Who can craft it (PR 2)
------------------------------------------------------------
local prof
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "professions" then prof = p end end
check("the Professions plugin registered", prof ~= nil)
local PT = prof and prof._test

local function Crafting()
    World()
    AltStableProfessionsDB = {
        -- A complete scan, Tailoring; an enchant (no item) known too.
        [ME]  = { stamp = 10, profs = {
            [197] = { rank = 60, max = 75, full = NOW, known = { [11000] = true } },
            [333] = { rank = 5, max = 75, full = NOW, known = { [11004] = true } } } },
        -- Partial: only learned-recipe events, still known. Both recipes of one bar.
        [ALT] = { stamp = 10, profs = {
            [171] = { rank = 280, max = 300, known = { [11001] = true, [11002] = true, [11006] = true } } } },
        [HID] = { stamp = 10, profs = { [197] = { rank = 50, max = 75, full = NOW, known = { [11003] = true } } } },
    }
    WoW.spellNames = { [11000] = "Bolt of Linen Cloth", [11001] = "Transmute: Arcanite",
                       [11002] = "Transmute: Arcanite Bar", [11003] = "Linen Bag",
                       [11005] = "Linen Belt", [11007] = "Rough Copper Ring" }
    WoW.unknownSpells = { [11006] = true }    -- not loaded yet
    WoW.items[2996] = { name = "Bolt of Linen Cloth", classID = 7, quality = 1, icon = 8 }
    WoW.items[4240] = { name = "Linen Belt", classID = 4, quality = 1, icon = 9 }
    WoW.items[12359] = { name = "Thorium Bar", classID = 7, quality = 1, icon = 10 }
    WoW.items[2862] = { name = "Rough Copper Ring", classID = 4, quality = 1, icon = 11 }
    -- 12360, Arcanite Bar: not in the client's cache.
end

if PT then
    Crafting()
    local c = AltStable.ItemCrafters()
    eq("a known recipe's item has its crafter", c[2996] and c[2996].crafters[1].name, "Kaleid")
    eq("  with the profession's name", c[2996] and c[2996].crafters[1].line, "Tailoring")
    eq("two recipes of one item: one crafter", c[12360] and #c[12360].crafters, 1)
    eq("  known from a partial scan", c[12360] and c[12360].crafters[1].name, "Brom")
    eq("  both recipe names as aliases", c[12360] and #c[12360].aliases, 2)
    check("a hidden character crafts nothing here", c[4238] == nil)
    local any = 0
    for _ in pairs(c) do any = any + 1 end
    eq("an enchant (no item) is no entry", any, 3)

    AltStable.ShowSearch("transmute"); WoW.flushTimers()
    eq("a recipe's name finds its item", RowIDs(), "12360")
    eq("  shown by id until its own name loads", Window().rows[1].name:GetText(), "item 12360")
    local strip = function(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    eq("  nobody holds it: said, then who can craft it", strip(S.WhoLine(S.rows[1])),
       "None recorded  ·  can craft: Brom (Alchemy)")
    Enter()
    check("Enter on a craft-only item keeps the search open", Window():IsShown())
    eq("  and says who can craft it", strip(Window().status:GetText()), "None recorded. Can craft: Brom (Alchemy).")
    local row = Window().rows[1]
    row:GetScript("OnEnter")(row)
    check("its hover lists the crafters", GameTooltip:IsOwned(row))
    row:GetScript("OnLeave")(row)

    Type("linen")
    eq("held and craft-only together, held first", RowIDs(), "101,2996")
    eq("  a held item's line adds no crafters it hasn't got", strip(S.WhoLine(S.rows[1])), "Brom 8, Kaleid 2")

    -- A recipe learned with the profession window closed: the search hears it.
    Type("belt")
    eq("(nobody can make a belt yet)", #S.rows, 0)
    PT.OnRecipeLearned(11005)
    WoW.flushTimers()
    eq("a recipe learned with the window closed shows", RowIDs(), "4240")
    eq("  with who learned it", strip(S.CraftersText(S.rows[1])), "Kaleid (Tailoring)")

    -- A snapshot received by sync, the Professions tab not open.
    Type("copper ring")
    eq("(no copper ring yet)", #S.rows, 0)
    local heldAlt = AltStableProfessionsDB[ALT]
    -- The whole snapshot travels: Brom's Alchemy as before, Blacksmithing new.
    AltStableProfessionsDB[ALT] = { stamp = 50, profs = {
        [171] = { rank = 280, max = 300, known = { [11001] = true, [11002] = true, [11006] = true } },
        [164] = { rank = 20, max = 75, full = NOW, known = { [11007] = true } } } }
    local blob = PT.SerializePlayer(ALT)
    AltStableProfessionsDB[ALT] = heldAlt
    check("  (the Professions tab isn't open)", not prof._at.isActive)
    PT.DeserializePlayer(ALT, blob)
    WoW.flushTimers()
    eq("a received snapshot updates who can craft it", RowIDs(), "2862")

    -- A recipe name that loads late, the Professions tab not open.
    Type("mithril")
    eq("(its recipe's name hasn't loaded)", #S.rows, 0)
    WoW.unknownSpells[11006] = nil
    WoW.spellNames[11006] = "Transmute: Mithril to Truesilver"
    PT.OnSpellData(11006, true)
    WoW.flushTimers()
    eq("a recipe name loading late becomes searchable", RowIDs(), "12359")

    -- Professions off: no crafters, nothing found by a recipe's name.
    local held = AltStable.ItemCrafters
    AltStable.ItemCrafters = nil
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()   -- as a fresh snapshot would be
    Type("transmute")
    eq("Professions off: nothing found by recipe", #S.rows, 0)

    -- The Recipe Book switched on in Options, the search open (review of #554):
    -- loading it publishes the crafters, and the search rebuilds with them.
    local realLoad = C_AddOns.LoadAddOn
    C_AddOns.LoadAddOn = function(a)
        if a == "AltStableProfessions" then AltStable.ItemCrafters = held end
        return realLoad(a)
    end
    WoW.loaded.AltStableProfessions = nil
    AltStable.SetPluginEnabled("professions", true)
    C_AddOns.LoadAddOn = realLoad
    WoW.flushTimers()
    -- An item with no name yet sorts after the named ones (PR 3).
    eq("the Recipe Book switched on with the search open: found by recipe", RowIDs(), "12359,12360")

    -- Warband off: Enter on a craft-only item still says who can craft it.
    local heldMaps = AltStable.ItemMapsFor
    AltStable.ItemMapsFor = nil
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("(Warband off, still found by recipe)", RowIDs(), "12359,12360")
    Enter()
    eq("Warband off: Enter on a craft-only item names its crafters", strip(Window().status:GetText()),
       "Can craft: Brom (Alchemy). Bags, bank and mail need the Warband module.")

    -- Warband switched on: it publishes its holdings at its bootstrap, a second
    -- after loading, and an open search rebuilds then, with the saved bags,
    -- even when the bag scan reads nothing new.
    Type("linen")
    eq("(Warband off: only what can be crafted)", RowIDs(), "2996,4240")
    local heldContainers = WoW.containers
    WoW.containers = {}
    plugin._test.BootstrapPlugin()
    WoW.flushTimers()
    eq("Warband's bootstrap rebuilds an open search with its saved holdings", RowIDs(), "101,2996,4240")
    WoW.containers = heldContainers
    AltStable.ItemMapsFor = heldMaps
    AltStable.ItemCrafters = held
    Window():Hide()
end

------------------------------------------------------------
-- A row's line fits its row: fewer holders first, so "can craft" isn't cut
-- off the end (seen in game, 2026-11-28).
------------------------------------------------------------
do
    local fs = UIParent:CreateFontString(nil, "OVERLAY")
    local e = { holders = {
        { name = "Kaleidria Kashmere", class = "HUNTER", total = 71 },
        { name = "Elegia Mortalis", class = "PALADIN", total = 56 },
        { name = "Karuzo Macphisto", class = "PRIEST", total = 49 },
        { name = "Cowruzo Banks", class = "WARRIOR", total = 3 } },
      crafters = {
        { name = "Drakuza Memphisto", class = "MAGE", line = "First Aid" },
        { name = "Drucida Komakino", class = "DRUID", line = "First Aid" },
        { name = "Kalizo Mistwalker", class = "SHAMAN", line = "First Aid" } } }
    local function W(h, c) fs:SetText(S.WhoLine(e, h, c)); return fs:GetUnboundedStringWidth() end
    local full, two, oneCrafter, shortest = W(3, 2), W(2, 2), W(2, 1), W(1, 1)
    check("(each step is shorter)", full > two and two > oneCrafter and oneCrafter > shortest)
    fs._GetWidth = full; S.FitWhoLine(fs, e)
    eq("a line that fits is whole", fs:GetText(), S.WhoLine(e))
    fs._GetWidth = two; S.FitWhoLine(fs, e)
    eq("too long: a holder fewer first", fs:GetText(), S.WhoLine(e, 2, 2))
    fs._GetWidth = oneCrafter; S.FitWhoLine(fs, e)
    eq("  then a crafter fewer", fs:GetText(), S.WhoLine(e, 2, 1))
    fs._GetWidth = shortest; S.FitWhoLine(fs, e)
    eq("  then one of each", fs:GetText(), S.WhoLine(e, 1, 1))
    fs._GetWidth = 10; S.FitWhoLine(fs, e)
    eq("narrower still: the shortest, cut with '...'", fs:GetText(), S.WhoLine(e, 1, 1))
    check("  which still says who can craft it", fs:GetText():find("can craft", 1, true) ~= nil)

    -- In the window: a row's line is fitted, not the whole list.
    World()
    AltStable.ShowSearch("linen"); WoW.flushTimers()
    local row = Window().rows[1]
    row.who._GetWidth = 10
    Type("linen cloth"); WoW.flushTimers()
    eq("a row's line in the window is fitted", row.who:GetText(), S.WhoLine(S.rows[1], 1, 1))
    row.who._GetWidth = nil
    Window():Hide()
end

------------------------------------------------------------
-- Filters and sorting (PR 3): usable with no text, kept for the session.
------------------------------------------------------------
do
    local function Gear()
        World()
        WoW.items[200].ilvl, WoW.items[200].minLevel, WoW.items[200].equipLoc = 18, 10, "INVTYPE_FINGER"
        WoW.items[300] = { name = "Linen Robe", classID = 4, subClassID = 1, equipLoc = "INVTYPE_ROBE",
                           quality = 2, ilvl = 20, minLevel = 15, icon = 5 }
        WoW.items[301] = { name = "Leather Vest", classID = 4, subClassID = 2, equipLoc = "INVTYPE_CHEST",
                           quality = 3, ilvl = 30, minLevel = 24, icon = 6 }
        WoW.items[302] = { name = "Iron Sword", classID = 2, subClassID = 7, equipLoc = "INVTYPE_WEAPON",
                           quality = 2, ilvl = 25, minLevel = 20, icon = 7 }
        WoW.items[303] = { name = "Plate Helm", classID = 4, subClassID = 4, equipLoc = "INVTYPE_HEAD",
                           quality = 4, ilvl = 40, minLevel = 25, icon = 8 }
        -- 304 and 305: the client knows nothing of them (not cached).
        local alt = AltStableWarbandDB[ALT]
        alt.bags[300], alt.bags[302], alt.bags[304], alt.bags[305] = 1, 1, 1, 1
        alt.mail = { [303] = 3 }
        AltStableWarbandDB[ME].bank = { [301] = 1 }
        S.filters, S.sort, S.meta = {}, "total", {}
    end
    local realShowMenu, menu = AltStable.ShowMenu, nil
    AltStable.ShowMenu = function(list, onPick, again, opts)
        menu = { list = list, pick = onPick, anchor = opts and opts.anchor }
        return realShowMenu(list, onPick, again, opts)
    end
    local function Texts()
        local t = {}
        for _, x in ipairs(menu and menu.list or {}) do
            if not x.title then t[#t + 1] = (x.text:gsub("^|T.-|t ", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
        end
        return table.concat(t, ",")
    end
    local function Pick(kind, id)
        S.OpenFilterMenu(kind)
        menu.pick(id)
    end

    Gear()
    AltStable.ShowSearch(); WoW.flushTimers()
    Type(""); WoW.flushTimers()
    -- 304 and 305 load with no name: retired, the status free.
    S.OnItemDataLoaded(304); S.OnItemDataLoaded(305); WoW.flushTimers()
    eq("no text, no filter: nothing", #S.rows, 0)
    eq("  and says how to start", Window().status:GetText(),
       "Type at least two letters of an item's name, or choose a filter.")
    local fb = Window().filterBtns
    eq("the buttons say Any", fb.quality.label:GetText() .. "|" .. fb.slot.label:GetText() .. "|"
       .. fb.type.label:GetText() .. "|" .. fb.char.label:GetText() .. "|" .. fb.sort.label:GetText(),
       "Quality: Any|Slot: Any|Type: Any|All characters|Sort: Total")
    check("  Clear greyed", not fb.clear:IsEnabled())

    -- Quality, with no text.
    S.OpenFilterMenu("quality")
    eq("the quality menu hangs under its button", menu and menu.anchor, fb.quality)
    eq("  every quality, Any first", Texts(), "Any,Poor,Common,Uncommon,Rare,Epic,Legendary")
    menu.pick(2)
    eq("a quality alone is a search", RowIDs(), "200,302,300")
    eq("  the button says it", fb.quality.label:GetText(), "Quality: Uncommon")
    check("  Clear open", fb.clear:IsEnabled())
    Pick("quality", 0)
    eq("Poor: none recorded (an unknown quality never matches)", #S.rows, 0)
    eq("  and says so, not how to start", Window().status:GetText(), "None recorded.")
    Pick("quality", "any")
    S.OpenFilterMenu("slot")
    check("(a filter menu is up, the search's)", S.menu ~= nil)
    Window():Hide()
    check("a filter menu closes with the window", S.menu == nil)
    AltStable.ShowSearch(); WoW.flushTimers()

    -- Slot: a robe is a chest.
    Pick("slot", "CHEST")
    eq("the Chest slot holds robes too", RowIDs(), "301,300")
    Pick("slot", "any")

    -- Type: the armour and weapon types recorded, not every type there is.
    S.OpenFilterMenu("type")
    eq("the type menu lists what is recorded", Texts(),
       "Any,All armor,Cloth,Leather,Plate,All weapon,One-Handed Swords")
    menu.pick("4:1")
    eq("Cloth", RowIDs(), "300")
    eq("  the button says it", fb.type.label:GetText(), "Type: Cloth")
    Pick("type", "4")
    eq("all armour (the ring has no subclass of its own here)", RowIDs(), "303,200,301,300")
    Pick("type", "any")

    -- The required-level range: inclusive; an unknown level never matches.
    local lo, hi = Window().levelMin, Window().levelMax
    check("the level boxes take digits only", lo:IsNumeric() and hi:IsNumeric())
    lo:SetText("20"); lo:GetScript("OnTextChanged")(lo, true)
    hi:SetText("24"); hi:GetScript("OnTextChanged")(hi, true)
    eq("(not before the typing delay)", S.queryPending, true)
    WoW.flushTimers()
    eq("levels 20 to 24, both ends in", RowIDs(), "302,301")
    hi:SetText(""); hi:GetScript("OnTextChanged")(hi, true); WoW.flushTimers()
    eq("from 20 up", RowIDs(), "303,302,301")
    lo:SetText(""); lo:GetScript("OnTextChanged")(lo, true)
    hi:SetText("10"); hi:GetScript("OnTextChanged")(hi, true); WoW.flushTimers()
    eq("up to 10: the ring, and cloth needing no level", RowIDs(), "101,103,200,102")
    lo:SetText("0"); lo:GetScript("OnTextChanged")(lo, true); WoW.flushTimers()
    eq("a 0 bound is no bound", S.filters.minLevel, nil)
    hi:SetText(""); hi:GetScript("OnTextChanged")(hi, true); WoW.flushTimers()
    lo:SetText(""); lo:GetScript("OnTextChanged")(lo, true); WoW.flushTimers()

    -- Text and a filter together.
    Type("linen"); WoW.flushTimers()
    Pick("type", "4")
    eq("text and a filter: both", RowIDs(), "300")
    Type(""); WoW.flushTimers()

    -- Sorting the armour.
    Pick("sort", "name")
    eq("by name", RowIDs(), "200,301,300,303")
    eq("  the button says it", fb.sort.label:GetText(), "Sort: Name")
    Pick("sort", "quality")
    eq("by quality, best first; equal ones by name", RowIDs(), "303,301,200,300")
    Pick("sort", "ilvl")
    eq("by item level, highest first", RowIDs(), "303,301,300,200")
    Pick("sort", "location")
    eq("by location: bags, bank, mail, worn", RowIDs(), "300,301,303,200")
    Pick("sort", "total")
    eq("by total (the default)", RowIDs(), "303,200,301,300")
    Pick("type", "any")

    -- The character filter: one character's part, with their own total.
    S.OpenFilterMenu("char")
    eq("the characters listed, hidden left out", Texts(), "All characters,Brom,Kaleid")
    menu.pick(ME)
    eq("a character alone is a search: what they have", RowIDs(), "103,200,101,301")
    eq("  the button says who", fb.char.label:GetText(), "Kaleid")
    Type("linen"); WoW.flushTimers()
    eq("  their own total", S.rows[1] and S.rows[1].total, 2)
    eq("  their line", S.WhoLine(S.rows[1]):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), "Kaleid 2")
    eq("  Enter opens theirs, not the top holder's", S.RevealTarget(S.rows[1]).guid, ME)
    Type(""); WoW.flushTimers()

    -- Unknown last, and equal unknowns by id.
    Pick("char", ALT)
    Pick("sort", "quality")
    eq("unknown quality and name last, by id", RowIDs(), "303,302,300,101,102,304,305")
    Pick("sort", "ilvl")
    eq("unknown item level last", RowIDs(), "303,302,300,101,102,304,305")

    -- A character hidden since it was chosen: the filter goes.
    AltStableConfig.hiddenCharacters[ALT] = true
    AltStable.NotifyItemDataChanged(); WoW.flushTimers()
    eq("the chosen character hidden: the filter goes", S.filters.char, nil)
    eq("  and with it the results", #S.rows, 0)
    AltStableConfig.hiddenCharacters[ALT] = nil

    -- Kept for the session: closed and reopened, still there.
    Pick("quality", 3)
    Window():Hide()
    AltStable.ShowSearch(); WoW.flushTimers()
    eq("filters kept when the window reopens", RowIDs(), "301")
    lo:SetText("5"); lo:GetScript("OnTextChanged")(lo, true); WoW.flushTimers()
    fb.clear:GetScript("OnClick")(fb.clear)
    check("Clear filters: all gone", not S.AnyFilter())
    eq("  the level boxes emptied", lo:GetText() .. "|" .. hi:GetText(), "|")
    eq("  the sort kept", S.sort, "ilvl")
    eq("  nothing to show", #S.rows, 0)
    S.sort = "total"

    -- Where an item is first found, craft-only last.
    eq("location: craft-only is last", S.LocationRank({ holders = {} }), 5)
    eq("  bags before bank", S.LocationRank({ holders = { { bags = 0, bank = 1, mail = 0, worn = 0 },
                                                         { bags = 1, bank = 0, mail = 0, worn = 0 } } }), 1)
    local e = { id = 1, total = 3, by = { [ME] = { guid = ME, total = 3 } },
                holders = { { guid = ME, total = 3 } },
                crafters = { { guid = ALT, name = "Brom", line = "Alchemy" } } }
    local v = S.ForCharacter(e, ALT)
    eq("a crafter's part: nothing held", v and v.total, 0)
    eq("  but their crafting", v and v.crafters[1].guid, ALT)
    eq("  and no one else's holdings", v and #v.holders, 0)
    eq("someone with no part: none", S.ForCharacter(e, HID), nil)

    AltStable.ShowMenu = realShowMenu
    if AltStable.CloseCharacterMenu then AltStable.CloseCharacterMenu() end
    S.filters, S.sort = {}, "total"
    Window():Hide()
end

------------------------------------------------------------
-- Keys, Escape, the slash command, the TOC
------------------------------------------------------------
do
    World()
    AltStable.ShowSearch("cloth"); WoW.flushTimers()
    local box = Window().box
    eq("the first row is selected", S.selected, 1)
    box:GetScript("OnArrowPressed")(box, "DOWN")
    eq("Down moves the selection", S.selected, 2)
    for _ = 1, 5 do box:GetScript("OnArrowPressed")(box, "DOWN") end
    eq("  not past the last", S.selected, #S.rows)
    for _ = 1, 5 do box:GetScript("OnArrowPressed")(box, "UP") end
    eq("Up moves it back, not past the first", S.selected, 1)
    local row = Window().rows[1]
    row:GetScript("OnEnter")(row)
    check("hovering a row shows who holds it", GameTooltip:IsOwned(row))
    row:GetScript("OnLeave")(row)
    box:GetScript("OnEscapePressed")(box)
    check("Escape in the box closes the search", not Window():IsShown())
    local registered = false
    for _, n in ipairs(UISpecialFrames) do if n == "AltStableSearch" then registered = true end end
    check("  registered with the game's Escape", registered)

    SlashCmdList["ALTSTABLE"]("search linen cloth")
    WoW.flushTimers()
    check("/alts search opens it", Window():IsShown())
    eq("  with the rest of the line as the query", Window().box:GetText(), "linen cloth")
    eq("  and finds it", RowIDs(), "101")
    Window():Hide()

    local toc = io.open("AltStable.toc"):read("*a")
    check("Search.lua is in the TOC, after Export.lua", toc:find("Export.lua%s+Search.lua") ~= nil)
end

rawset(_G, "IsShiftKeyDown", rawShift)
time = realTime

print(("test_search: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
