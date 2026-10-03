------------------------------------------------------------
-- test_warband.lua — the Warband plugin (#9, #10)
--
-- Every Classic container constant this plugin shipped with is wrong on
-- Forever: -1 is the KEYRING (it was scanned as the main bank), 5 is the
-- carried reagent bag (it was scanned as a bank bag), and the bank is not a
-- fixed id range at all - tabs are purchased one at a time. The account bank
-- exists in the API but is not viewable; scanning it would count shared items
-- once per alt.
--
-- The tooltip hook is the other half: GameTooltip:HookScript("OnTooltipSetItem")
-- THROWS on this client, which aborted the whole plugin registration. The stub
-- rejects that script type, so a revert fails here rather than in game.
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

AltStable = {}
AltStableDB = {}
AltStableConfig = {}
dofile("Compat.lua")
-- The material and the skin seam, in .toc order: the revamped panel (#153) is
-- built in these tests, and it is painted through them.
assert(loadfile("Glass.lua"))("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")

-- The plugin bootstraps itself a second after load (IsLoggedIn is true under
-- the stubs), which is what registers it with the core.
dofile("Plugins/Warband/WarbandTabs.lua")
dofile("Plugins/Warband/AltStableWarband.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "warband" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_warband: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end
local T = plugin._test

-- Captured now: WoW.reset() between sections clears the registry, and the hook
-- is installed once at bootstrap.
local ttCalls = WoW.tooltipPostCalls[Enum.TooltipDataType.Item]
-- Once, however often it is asked: a second post-call would print every
-- item's counts twice (the hook is the core's now, AltStable.HookItemTooltip).
T.EnsureTooltipHook()
check("the tooltip hook is installed once, however often it is asked", ttCalls ~= nil and #ttCalls == 1,
      tostring(ttCalls and #ttCalls))

------------------------------------------------------------
-- Which containers get read
------------------------------------------------------------

local function ids(list)
    local out = {}
    for _, v in ipairs(list or {}) do out[#out + 1] = v end
    table.sort(out)
    return table.concat(out, ",")
end

eq("carried bags: keyring, backpack, four bags, reagent bag",
   ids(T.CarriedBagIDs()), "-1,0,1,2,3,4,5")
check("no bank tab is carried", not tostring(ids(T.CarriedBagIDs())):find("6"))

WoW.bankTabs = { 6, 7 }
eq("bank tabs come from the purchased list", ids(T.BankTabIDs()), "6,7")
WoW.accountTabs = { 15 }
check("an account tab is not a bank container we scan", not T.IsBankContainer(15))
check("a purchased character tab is", T.IsBankContainer(6))
check("the keyring is not a bank container", not T.IsBankContainer(-1))

------------------------------------------------------------
-- Scanning bags
------------------------------------------------------------

local GUID = UnitGUID("player")
local function slot(id, n) return { itemID = id, stackCount = n, hyperlink = "|Hitem:" .. id .. "|h" } end

WoW.reset()
WoW.containers = {
    [0]  = { size = 2, slot(6948, 1), slot(2318, 5) },   -- backpack
    [1]  = { size = 1, slot(2318, 3) },                  -- bag 1
    [5]  = { size = 1, slot(2589, 10) },                 -- reagent bag (CARRIED here)
    [-1] = { size = 1, slot(5140, 1) },                  -- keyring
    [6]  = { size = 1, slot(2318, 13) },                 -- bank tab: not a bag
}
AltStableWarbandDB = {}
T.ScanBags()
local db = AltStableWarbandDB[GUID]
check("a bag scan stores a map for this character", db ~= nil and db.bags ~= nil)
eq("stacks of one item across bags are summed", db.bags[2318], 8)
eq("the reagent bag is carried, not bank", db.bags[2589], 10)
eq("the keyring is included", db.bags[5140], 1)
eq("a bank tab's contents are not in the bags map", db.bags[2318], 8)   -- 21 if it leaked
eq("the bank map is untouched by a bag scan", db.bank, nil)

------------------------------------------------------------
-- Scanning the bank
------------------------------------------------------------

WoW.bankTabs = { 6 }
WoW.accountTabs = { 15 }
WoW.containers[15] = { size = 1, slot(9999, 42) }   -- account bank: shared, never ours

T.ScanBank()
eq("the bank is not read while it is closed", AltStableWarbandDB[GUID].bank, nil)

T.OnBankOpened()
eq("an open bank records the purchased tab", AltStableWarbandDB[GUID].bank[2318], 13)
eq("  and never the account bank", AltStableWarbandDB[GUID].bank[9999], nil)
eq("  while the bags map survives the bank scan", AltStableWarbandDB[GUID].bags[2318], 8)

-- Slot counts arrive late: a tab that reports none is not "an empty bank".
AltStableWarbandDB[GUID].bank = { [2318] = 13 }
WoW.containers[6] = { size = 0 }
T.ScanBank()
eq("a tab whose slots are not ready yet leaves the snapshot alone",
   AltStableWarbandDB[GUID].bank[2318], 13)

-- A character who owns no tabs legitimately has an empty bank. The purchased
-- set is cached between bank sessions (BAG_UPDATE asks about it constantly), so
-- a change to it is picked up when the bank opens.
WoW.containers[6] = { size = 1, slot(2318, 13) }
WoW.bankTabs = {}
T.ScanBank()
eq("the cached tab list survives a change made with the bank open",
   AltStableWarbandDB[GUID].bank[2318], 13)
T.OnBankClosed(); T.OnBankOpened()
T.ScanBank()
eq("owning no tabs records an empty bank", next(AltStableWarbandDB[GUID].bank), nil)

-- A tab bought mid-session shows up when the bank is next opened.
WoW.bankTabs = { 6, 7 }
WoW.containers[7] = { size = 1, slot(4306, 4) }
T.OnBankClosed(); T.OnBankOpened()
eq("a newly bought tab is read on the next bank session",
   AltStableWarbandDB[GUID].bank[4306], 4)
WoW.bankTabs = { 6 }
WoW.containers[7] = nil
T.OnBankClosed(); T.OnBankOpened()

-- A tab bought WITHOUT closing the bank: BANK_TABS_CHANGED is the only signal,
-- since the new tab's BAG_UPDATE looks like a carried bag against the old list.
WoW.bankTabs = { 6 }
T.OnBankClosed(); T.OnBankOpened()
WoW.bankTabs = { 6, 7 }
WoW.containers[7] = { size = 1, slot(4306, 4) }
T.OnBagUpdate(7)
WoW.flushTimers()
eq("a tab bought mid-session is invisible until the client says so",
   AltStableWarbandDB[GUID].bank[4306], nil)
T.OnBankTabsChanged(Enum.BankType.Character)
eq("BANK_TABS_CHANGED picks the new tab up while the bank is open",
   AltStableWarbandDB[GUID].bank[4306], 4)

-- The account bank's own event is not ours.
WoW.bankTabs = { 6 }
WoW.containers[7] = nil
T.OnBankTabsChanged(Enum.BankType.Account)
eq("an account-bank tab change is ignored", AltStableWarbandDB[GUID].bank[4306], 4)
T.OnBankTabsChanged(Enum.BankType.Character)
eq("  a character one is not", AltStableWarbandDB[GUID].bank[4306], nil)

-- Enumeration failure is not an empty bank.
AltStableWarbandDB[GUID].bank = { [2318] = 13 }
local realFetch = C_Bank.FetchPurchasedBankTabIDs
C_Bank.FetchPurchasedBankTabIDs = function() error("boom") end
T.ScanBank()
eq("a failed tab enumeration leaves the snapshot alone", AltStableWarbandDB[GUID].bank[2318], 13)
C_Bank.FetchPurchasedBankTabIDs = realFetch
WoW.bankTabs = { 6 }

------------------------------------------------------------
-- Event routing
------------------------------------------------------------

-- Route through the timers the plugin schedules, then see what ran.
T.OnBagUpdate(0)
WoW.flushTimers()
check("a bag update refreshes the bags", AltStableWarbandDB[GUID].bags ~= nil)

AltStableWarbandDB[GUID].bank = nil
T.OnBagUpdate(6)          -- a bank tab, with the bank open
WoW.flushTimers()
eq("a bank-tab update while the bank is open refreshes the bank",
   AltStableWarbandDB[GUID].bank and AltStableWarbandDB[GUID].bank[2318], 13)

-- The reagent bag (5) is CARRIED here; the old rule treated 5..11 as bank bags,
-- so an update to it would have gone to the bank path and never refreshed bags.
AltStableWarbandDB[GUID].bags = nil
T.OnBagUpdate(5)
WoW.flushTimers()
eq("a reagent-bag update refreshes the bags", AltStableWarbandDB[GUID].bags[2589], 10)

T.OnBankClosed()
AltStableWarbandDB[GUID].bank = nil
T.OnBagUpdate(6)
WoW.flushTimers()
eq("  but not once the bank is closed", AltStableWarbandDB[GUID].bank, nil)

------------------------------------------------------------
-- Reading a slot: the struct, not the old tuple
------------------------------------------------------------

WoW.reset()
WoW.containers = { [0] = { size = 1, slot(2318, 7) } }
local map = T.ScanContainerSet({ 0 })
eq("a stack count is read from the struct", map and map[2318], 7)

------------------------------------------------------------
-- Tooltips (#10)
------------------------------------------------------------

check("the plugin registered an item tooltip post-call, not the script hook that throws",
      ttCalls ~= nil and #ttCalls > 0)

AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid", class = "MAGE" } }
AltStableWarbandDB = { [GUID] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, bankStamp = WoW.now } }
local total = T.CountItem(2318)
eq("the cross-alt count sums bags and bank", total, 21)

AltStable.SetConfigValue("warbandItemTooltips", true)
local lines = {}
local tt = WoW.makeFrame()
tt.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
tt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. "|" .. tostring(r) end
for _, fn in ipairs(ttCalls) do fn(tt, { id = 2318 }) end
local sawTotal = false
for _, l in ipairs(lines) do if l:find("Total:", 1, true) and l:find("21", 1, true) then sawTotal = true end end
check("an item tooltip gets the cross-alt breakdown", sawTotal, table.concat(lines, " / "))

lines = {}
AltStable.SetConfigValue("warbandItemTooltips", false)
for _, fn in ipairs(ttCalls) do fn(tt, { id = 2318 }) end
eq("with the setting off, nothing is appended", #lines, 0)

------------------------------------------------------------
-- Sync blob
------------------------------------------------------------

local blob = T.SerializePlayer(GUID, 0)
check("the blob carries both maps", blob:find("b=2318,8", 1, true) ~= nil
                                     and blob:find("k=2318,13", 1, true) ~= nil, blob)
check("the blob is one line", not blob:find("\n"))

AltStableWarbandDB = {}
T.DeserializePlayer("Player-Peer-1", blob)
local got = AltStableWarbandDB["Player-Peer-1"]
eq("a peer's bags arrive", got and got.bags[2318], 8)
eq("  and their bank", got and got.bank[2318], 13)

-- Stale reject: an OLDER blob carrying DIFFERENT data must not be applied.
AltStableWarbandDB["Player-Peer-1"].stamp = 500
local older = "v1|s=400|kt=400|b=2318,999|k=2318,999"
T.DeserializePlayer("Player-Peer-1", older)
eq("an older relayed blob does not roll back fresher data",
   AltStableWarbandDB["Player-Peer-1"].bags[2318], 8)
local newer = "v1|s=600|kt=600|b=2318,999|k=2318,13"
T.DeserializePlayer("Player-Peer-1", newer)
eq("  a newer one is applied", AltStableWarbandDB["Player-Peer-1"].bags[2318], 999)

T.DeserializePlayer("Player-Peer-2", "v1|s=999|kt=0|b=2318,notanumber|k=")
eq("a malformed blob is ignored", AltStableWarbandDB["Player-Peer-2"], nil)

-- Stamps come from time(), one-second resolution: two moves in one second give
-- different maps under the SAME stamp, and the core re-sends records at the
-- watermark. A same-stamp blob whose contents differ has to be applied.
AltStableWarbandDB["Player-Same-1"] = { bags = { [2318] = 1 }, bank = {}, stamp = 100 }
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=100|b=2318,2|k=")
eq("a same-second blob with different contents is applied",
   AltStableWarbandDB["Player-Same-1"].bags[2318], 2)
-- An unchanged record costs no redraw: a full response re-sends every
-- character, and each redraw rebuilds the whole grid.
local wb = plugin._wb
local redraws = 0
local realRefresh, realActive = wb.Refresh, wb.isActive
wb.Refresh, wb.isActive = function() redraws = redraws + 1 end, true
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=100|b=2318,2|k=")
eq("  re-sending the same one changes nothing", AltStableWarbandDB["Player-Same-1"].bags[2318], 2)
eq("  and does not redraw the grid", redraws, 0)
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=100|b=2318,3|k=")
eq("  a changed one does", redraws, 1)
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=101|b=2318,3|k=")
eq("  as does a bank stamp moving on its own", redraws, 2)
wb.Refresh, wb.isActive = realRefresh, realActive
T.DeserializePlayer("Player-Same-1", "v1|s=99|kt=99|b=2318,777|k=")
eq("  and an older one is still refused", AltStableWarbandDB["Player-Same-1"].bags[2318], 3)

-- A blob missing a section is malformed, not "this character has nothing":
-- ParseMap(nil) is an empty map, so this would silently blank the inventory.
AltStableWarbandDB["Player-Peer-3"] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, stamp = 100 }
T.DeserializePlayer("Player-Peer-3", "v1|s=200")
eq("a blob with no bags field leaves the stored bags alone",
   AltStableWarbandDB["Player-Peer-3"].bags[2318], 8)
T.DeserializePlayer("Player-Peer-3", "v1|s=200|b=2318,1")
eq("  and one with no bank field leaves the bank alone",
   AltStableWarbandDB["Player-Peer-3"].bank[2318], 13)

------------------------------------------------------------
-- Cleanup and orphans
------------------------------------------------------------

-- The core's cleanup wipes its own DB and re-pulls in full. Our stale-reject
-- guard would refuse that re-pull, so our records have to go with it.
AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid", class = "MAGE", lastUpdate = 1 } }
AltStableWarbandDB = {
    [GUID] = { bags = { [2318] = 8 }, stamp = 100 },
    ["Player-Other-1"] = { bags = { [2318] = 5 }, stamp = 100 },
}
AltStable._test.CleanupDB()
eq("the core's cleanup clears other characters' inventory too",
   AltStableWarbandDB["Player-Other-1"], nil)
check("  and keeps this character's", AltStableWarbandDB[GUID] ~= nil)

-- A guid no character record mentions any more is invisible in the UI but
-- would sit in SavedVariables forever.
AltStableWarbandDB["Player-Gone-1"] = { bags = { [2318] = 5 }, stamp = 100 }
T.PruneOrphans()
eq("an orphaned record is pruned", AltStableWarbandDB["Player-Gone-1"], nil)
check("  while a known character stays", AltStableWarbandDB[GUID] ~= nil)

------------------------------------------------------------
-- The login pull
------------------------------------------------------------

-- The core loads enabled plugins from its own PLAYER_LOGIN handler, so
-- IsLoggedIn() is already true when we load: forcing a baseline on that signal
-- reset every peer watermark at every login, turning each session into a full
-- database pull.
local resets = 0
local realReset = AltStable.ResetPeerWatermarks
AltStable.ResetPeerWatermarks = function() resets = resets + 1 end

AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid" } }
AltStableWarbandDB = { [GUID] = { bags = { [2318] = 8 }, stamp = 100 },
                       ["Player-Ghost-1"] = { bags = { [2318] = 3 }, stamp = 100 } }
T.BootstrapPlugin()
eq("holding inventory, a login does not force a full re-pull", resets, 0)
eq("  and login prunes a record no character record mentions",
   AltStableWarbandDB["Player-Ghost-1"], nil)

AltStableWarbandDB = {}
T.BootstrapPlugin()
eq("holding none, it does force one", resets, 1)

-- Orphans don't count as "we hold inventory": they are pruned at login, so
-- counting them first would skip the baseline pull and leave the real
-- inventory unfetched behind watermarks that are already ahead.
resets = 0
AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid" } }
AltStableWarbandDB = { ["Player-Ghost-2"] = { bags = { [2318] = 3 }, stamp = 100 } }
T.BootstrapPlugin()
eq("inventory for a character nobody has does not count as data", resets, 1)
eq("  and it is pruned", AltStableWarbandDB["Player-Ghost-2"], nil)
AltStable.ResetPeerWatermarks = realReset

------------------------------------------------------------
-- A bank reopened inside the debounce window
------------------------------------------------------------

WoW.reset()
WoW.bankTabs = { 6 }
WoW.containers = { [6] = { size = 1, slot(2318, 13) } }
AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid" } }
AltStableWarbandDB = {}
T.OnBankOpened()          -- schedules a follow-up scan
AltStableWarbandDB[GUID].bank = nil
T.OnBankClosed()          -- ...closed and reopened before it fires
T.OnBankOpened()
AltStableWarbandDB[GUID].bank = nil
WoW.flushTimers()
eq("a bank reopened inside the debounce window still gets its scan",
   AltStableWarbandDB[GUID].bank and AltStableWarbandDB[GUID].bank[2318], 13)

-- ...while a scan whose session ended is still dropped.
AltStableWarbandDB[GUID].bank = nil
T.OnBagUpdate(6)
T.OnBankClosed()
WoW.flushTimers()
eq("a scan whose bank session ended is dropped", AltStableWarbandDB[GUID].bank, nil)

------------------------------------------------------------
-- Tooltips: the hovered cell's breakdown belongs to that item
------------------------------------------------------------

AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid", class = "MAGE" } }
AltStableWarbandDB = { [GUID] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, bankStamp = WoW.now } }
AltStable.SetConfigValue("warbandItemTooltips", false)
local hoverLines = {}
local htt = WoW.makeFrame()
htt.AddLine = function(_, text) hoverLines[#hoverLines + 1] = tostring(text) end
htt.AddDoubleLine = function(_, l, r) hoverLines[#hoverLines + 1] = tostring(l) .. "|" .. tostring(r) end

local AT_WB = plugin._wb
if AT_WB then
    AT_WB.hoverEntry = { id = 2318, total = 21, holders = { { name = "Kaleid", bags = 8, bank = 13 } } }
    for _, fn in ipairs(ttCalls) do fn(htt, { id = 2318 }) end
    check("the hovered cell's own tooltip gets its breakdown", #hoverLines > 0)

    hoverLines = {}
    for _, fn in ipairs(ttCalls) do fn(htt, { id = 9999 }) end
    eq("a comparison tooltip for a different item gets nothing", #hoverLines, 0)
    AT_WB.hoverEntry = nil
else
    check("the panel state is exposed for testing", false)
end

------------------------------------------------------------
-- Scrolling the grid
------------------------------------------------------------

-- Whole rows only, clamped, and the bar only appears when there is something
-- below the fold. STRIDE is 42 and the first row sits at ROW_TOP.
do
    local bounds = plugin._wb.ScrollBounds
    local visible, maxStart, start = bounds(3, 400, 0)
    check("a short grid fits", maxStart == 0 and start == 0, tostring(maxStart))
    local v2, max2 = bounds(40, 400, 0)
    check("a long one does not", max2 > 0 and v2 == visible, tostring(max2))
    local _, _, clampedHigh = bounds(40, 400, 999)
    eq("scrolling past the end stops at the last window", clampedHigh, max2)
    local _, _, clampedLow = bounds(40, 400, -5)
    eq("  and cannot go above the first row", clampedLow, 0)
    local _, _, kept = bounds(40, 400, 3)
    eq("  a request in range is kept", kept, 3)
    local vSmall = bounds(40, 0, 0)
    check("an unmeasured panel still lays out rows", vSmall >= 1)

    -- The bar follows the window, and only exists when something is off-screen.
    local shown, value, range = nil, nil, nil
    plugin._wb.scrollBar = {
        Hide = function() shown = false end,
        Show = function() shown = true end,
        SetMinMaxValues = function(_, lo, hi) range = hi end,
        SetValue = function(_, v) value = v end,
    }
    plugin._wb.UpdateScrollBar(0, 0)
    eq("a grid that fits has no scrollbar", shown, false)
    plugin._wb.UpdateScrollBar(6, 2)
    eq("one that does not, does", shown, true)
    eq("  its range is the last window", range, 6)
    eq("  and it sits where the grid does", value, 2)
    plugin._wb.scrollBar = nil

    local sheet = io.open("Plugins/Warband/AltStableWarband.lua"):read("*a")
    local layout = sheet:match("function AT_WB.Layout%(%)(.-)\nend")
    check("the layout drives the scrollbar",
          layout ~= nil and layout:find("UpdateScrollBar", 1, true) ~= nil)
    -- An empty grid has nothing to scroll, and both empty paths return early.
    check("the layout hides the bar when there are no rows",
          layout ~= nil and layout:find("UpdateScrollBar(0, 0)", 1, true) ~= nil)
    local refresh = sheet:match("function AT_WB.Refresh%(%)(.-)\nend")
    check("a refresh with no inventory hides it too",
          refresh ~= nil and refresh:find("UpdateScrollBar(0, 0)", 1, true) ~= nil)
end

------------------------------------------------------------
-- The revamp's model (#153): categories, rulesets, tabs, what is on screen
------------------------------------------------------------
do
    local M = AltStableWarbandModel
    check("the model loads before the plugin", type(M) == "table")

    -- Categories, as the dialog lists them.
    eq("weapons are equipment", M.CategoryOf(2), "equipment")
    eq("armour is equipment", M.CategoryOf(4), "equipment")
    eq("consumables", M.CategoryOf(0), "consumables")
    eq("ammunition sits with consumables", M.CategoryOf(6), "consumables")
    eq("trade goods", M.CategoryOf(7), "tradegoods")
    eq("gems sit with trade goods", M.CategoryOf(3), "tradegoods")
    eq("reagents", M.CategoryOf(5), "reagents")
    eq("recipes", M.CategoryOf(9), "recipes")
    eq("quest items are misc", M.CategoryOf(12), "misc")
    eq("an unknown class is misc", M.CategoryOf(nil), "misc")

    -- Rulesets from realm names: words, not substrings; unreadable is Unknown.
    eq("PvE is Normal", M.RulesetOf("Classic Beta PvE"), "Normal")
    eq("PvP", M.RulesetOf("Classic Beta PvP"), "PvP")
    eq("PvP 2 is the same ruleset", M.RulesetOf("Classic Beta PvP 2"), "PvP")
    eq("case does not matter", M.RulesetOf("CLASSIC BETA PVP"), "PvP")
    eq("an RP realm", M.RulesetOf("Forever RP"), "RP")
    eq("a Hardcore realm", M.RulesetOf("Forever Hardcore"), "Hardcore")
    eq("'rp' inside a word is not RP", M.RulesetOf("Carp Lake"), "Normal")
    eq("no realm is Unknown, never Normal", M.RulesetOf(nil), "Unknown")
    eq("  nor a blank one", M.RulesetOf("  "), "Unknown")
    eq("'current' resolves against where you are", M.ResolveRuleset("current", "Classic Beta PvP 2"), "PvP")
    eq("  and so does an unset setting", M.ResolveRuleset(nil, "Classic Beta PvE"), "Normal")
    eq("'all' is no filter", M.ResolveRuleset("all", "Classic Beta PvP"), nil)
    eq("a named ruleset is itself", M.ResolveRuleset("RP", "Classic Beta PvP"), "RP")

    -- Tabs claim by category; two claims show twice; the rest is Other.
    local tabs = { { cats = { tradegoods = true } }, { cats = { tradegoods = true, recipes = true } } }
    local per, other = M.Distribute({ { id = 1, cat = "tradegoods" }, { id = 2, cat = "recipes" },
                                      { id = 3, cat = "misc" } }, tabs)
    eq("a tab gets what it claims", #per[1], 1)
    eq("  an item claimed twice shows in both", #per[2], 2)
    eq("  and what nobody claims is Other", #other, 1)
    eq("  - just that", other[1].id, 3)

    -- Pages and selection.
    eq("Other is a page only while it has something", #M.Pages(3, false), 3)
    eq("  and the last page when it does", M.Pages(3, true)[4], "other")
    eq("a selection that exists is kept", M.RepairSelection(2, { 1, 2, 3 }), 2)
    eq("Other vanishing falls back to the last tab", M.RepairSelection("other", { 1, 2, 3 }), 3)
    eq("an index past the end falls back to the last tab", M.RepairSelection(7, { 1, 2, 3, "other" }), 3)
    eq("no pages, no selection", M.RepairSelection(1, {}), nil)

    -- Combined: three on screen, always holding the selection, clamped back.
    local f, w = M.CombinedWindow({ 1, 2, 3, 4 }, 4)
    check("choosing the last tab shows the three before it, no blanks", f == 2 and w == 3, f .. "," .. w)
    f, w = M.CombinedWindow({ 1, 2, 3, 4 }, 1)
    check("choosing the first starts there", f == 1 and w == 3)
    f, w = M.CombinedWindow({ 1, 2 }, 2)
    check("with two tabs, two columns", f == 1 and w == 2)
    f, w = M.CombinedWindow({ 1, 2, 3, 4, "other" }, "other")
    check("Other is reachable at the end", f == 3 and w == 3)

    -- Deleting.
    eq("deleting leaves Other selected", M.AfterDelete("other", 2, 3), "other")
    eq("a later tab shifts down", M.AfterDelete(3, 2, 3), 2)
    eq("the deleted tab hands over to its neighbour", M.AfterDelete(2, 2, 3), 2)
    eq("  or the new last tab", M.AfterDelete(3, 3, 2), 2)
    eq("an earlier tab is untouched", M.AfterDelete(1, 2, 3), 1)
    eq("nothing left, nothing selected", M.AfterDelete(1, 1, 0), nil)

    -- The dialog's draft is a real copy: Cancel must not have edited the tab.
    local saved = { name = "A", icon = "x", cats = { tradegoods = true } }
    local draft = M.CopyTab(saved)
    draft.cats.recipes = true
    draft.name = "B"
    check("editing a copy leaves the saved tab alone", saved.cats.recipes == nil and saved.name == "A")
end

------------------------------------------------------------
-- The revamped view (#153), driven through the real panel
------------------------------------------------------------
do
    local wb = plugin._wb
    WoW.reset()
    local ME, PVE, HID = "Player-1-AAAA", "Player-1-BBBB", "Player-1-CCCC"
    WoW.player.guid = ME
    WoW.player.realm = "Classic Beta PvP"
    AltStableDB = {
        [ME]  = { name = "Kaleid", class = "HUNTER", realm = "Classic Beta PvP" },
        [PVE] = { name = "Morph",  class = "WARLOCK", realm = "Classic Beta PvE" },
        [HID] = { name = "Hidden", class = "MAGE", realm = "Classic Beta PvP 2" },
    }
    AltStableWarbandDB = {
        [ME]  = { bags = { [101] = 2, [201] = 1 } },
        [PVE] = { bags = { [102] = 5, [301] = 1 } },
        [HID] = { bags = { [103] = 1 } },
    }
    WoW.items = {
        [101] = { name = "Linen", classID = 7, quality = 1, icon = 1 },
        [102] = { name = "Wool", classID = 7, quality = 1, icon = 2 },
        [103] = { name = "Silk", classID = 7, quality = 1, icon = 3 },
        [201] = { name = "Potion", classID = 0, quality = 1, icon = 4 },
        [301] = { name = "Quest Thing", classID = 12, quality = 1, icon = 5 },
    }
    AltStableConfig = { hiddenCharacters = { [HID] = true } }

    -- Every setting write goes through the seam.
    local writes = {}
    local realSet = AltStable.SetConfigValue
    AltStable.SetConfigValue = function(k, v) writes[#writes + 1] = k; return realSet(k, v) end

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1200 end
    main.GetHeight = function() return 800 end
    wb.Activate(main)
    -- Activating rescans our own (stubbed, empty) bags; put Kaleid's back.
    AltStableWarbandDB[ME] = { bags = { [101] = 2, [201] = 1 } }
    wb.Refresh()

    local function shownIDs()
        local out = {}
        for _, cell in ipairs(wb.cells) do
            if cell:IsShown() and cell.entry then out[#out + 1] = cell.entry.id end
        end
        table.sort(out)
        return table.concat(out, ",")
    end
    local function colKeys()
        local out = {}
        for _, c in ipairs(wb._cols or {}) do out[#out + 1] = tostring(c.key) end
        return table.concat(out, ",")
    end

    -- First draw: the four default tabs are seeded, through the seam.
    eq("the default tabs are seeded", #(AltStableConfig.warbandTabs or {}), 4)
    local seeded = false
    for _, k in ipairs(writes) do if k == "warbandTabs" then seeded = true end end
    check("  through SetConfigValue", seeded)

    -- Warband, current ruleset (PvP): Kaleid only - Morph is PvE, Hidden is hidden.
    eq("single view shows the selected tab", colKeys(), "1")
    eq("  holding this ruleset's trade goods, hidden characters left out", shownIDs(), "101")

    -- Empty slots fill the view and carry nothing.
    local empty
    for _, cell in ipairs(wb.cells) do if cell:IsShown() and not cell.entry then empty = cell end end
    check("the grid is padded with empty slots", empty ~= nil)
    -- Padded to the whole view, not just the row the items end on.
    local shownCount, firstY, perRow = 0, nil, 0
    for _, cell in ipairs(wb.cells) do
        if cell:IsShown() then
            shownCount = shownCount + 1
            local y = select(5, cell:GetPoint())
            firstY = firstY or y
            if y == firstY then perRow = perRow + 1 end
        end
    end
    check("  more than one row of them", shownCount >= 2 * perRow and perRow > 0,
          shownCount .. " cells, " .. perRow .. " per row")
    if empty then
        check("  an empty slot holds no count and no search name",
              empty.count:GetText() == "" and empty.itemName == nil)
    end

    -- A slot that held an item and is now empty forgets it.
    local first = wb.cells[1]
    eq("the first cell holds the linen", first.itemName, "Linen")
    AltStable.SetConfigValue("warbandTab", 4); wb.Refresh()      -- Recipes: nothing
    check("  and once empty, holds no name for search to find", first.entry == nil and first.itemName == nil)
    AltStable.SetConfigValue("warbandTab", 1); wb.Refresh()

    -- All rulesets: Morph's wool and his quest item come in; the quest item is Other's.
    AltStable.SetConfigValue("warbandRuleset", "all"); wb.Refresh()
    eq("all rulesets: every visible character", shownIDs(), "101,102")
    AltStable.SetConfigValue("warbandTab", "other"); wb.Refresh()
    eq("an item no tab claims is in Other", shownIDs(), "301")

    -- Back to this ruleset: Other empties, so the selection falls to the last tab.
    AltStable.SetConfigValue("warbandRuleset", "current"); wb.Refresh()
    eq("Other disappearing moves the selection to the last tab", AltStableConfig.warbandTab, 4)

    -- Combined: three at once, the window holding the selection, clamped back.
    AltStable.SetConfigValue("warbandView", "combined"); wb.Refresh()
    eq("combined shows three tabs ending at the selection", colKeys(), "2,3,4")
    AltStable.SetConfigValue("warbandTab", 1); wb.Refresh()
    eq("  or starting at it", colKeys(), "1,2,3")
    eq("  with the potion in Consumables, its own column", (function()
        for _, c in ipairs(wb._cols) do if c.key == 2 then return #c.entries end end
    end)(), 1)
    AltStable.SetConfigValue("warbandView", "single"); wb.Refresh()

    -- Personal: this character alone, whatever the ruleset says.
    AltStable.SetConfigValue("warbandScope", "personal")
    AltStable.SetConfigValue("warbandRuleset", "Normal"); wb.Refresh()
    eq("personal is this character, ruleset ignored", shownIDs(), "101")
    AltStable.SetConfigValue("warbandScope", "warband"); wb.Refresh()
    eq("warband on Normal is the PvE character", shownIDs(), "102")
    AltStable.SetConfigValue("warbandRuleset", "current")

    -- Personal for a character never scanned: says so, never shows everyone.
    WoW.player.guid = "Player-1-NEW"
    AltStable.SetConfigValue("warbandScope", "personal"); wb.Refresh()
    eq("an unscanned character shows nothing", shownIDs(), "")
    WoW.player.guid = ME
    AltStable.SetConfigValue("warbandScope", "warband"); wb.Refresh()

    -- Search dims items, never the empty slots.
    wb.search = "nothing matches this"
    wb.ApplySearchDim()
    local dimmed, slotAlpha
    for _, cell in ipairs(wb.cells) do
        if cell:IsShown() and cell.entry then dimmed = cell:GetAlpha() end
        if cell:IsShown() and not cell.entry then slotAlpha = cell:GetAlpha() end
    end
    eq("search dims a non-match", dimmed, 0.25)
    eq("  and leaves empty slots as they were", slotAlpha, 0.55)
    wb.search = ""

    -- A refresh drops a stale hover.
    wb.hoverEntry = { id = 999 }
    wb.Layout()
    eq("laying out clears the hover", wb.hoverEntry, nil)

    -- Configure: Cancel discards, even a nested category change.
    wb.OpenDialog(1)
    local dlg = wb.Dialog()
    check("the dialog opens on a tab", dlg and dlg.draft ~= nil)
    dlg.draft.cats.recipes = true
    dlg.nameBox:SetText("Renamed")
    wb.CloseDialog()
    check("Cancel leaves the tab exactly as it was",
          AltStableConfig.warbandTabs[1].name == "Trade Goods" and not AltStableConfig.warbandTabs[1].cats.recipes)

    -- "+" inserts nothing until Save; Save adds and selects it.
    wb.OpenDialog(nil)
    eq("opening a new tab adds nothing yet", #AltStableConfig.warbandTabs, 4)
    dlg.nameBox:SetText("Quest")
    dlg.draft.cats.misc = true
    wb.SaveDialog()
    eq("Save adds the tab", #AltStableConfig.warbandTabs, 5)
    eq("  named", AltStableConfig.warbandTabs[5].name, "Quest")
    eq("  and selects it", AltStableConfig.warbandTab, 5)
    -- A blank name gets one.
    wb.OpenDialog(nil); dlg.nameBox:SetText("   "); wb.SaveDialog()
    eq("a blank name becomes 'Tab N'", AltStableConfig.warbandTabs[6].name, "Tab 6")

    -- The cap: eight user tabs, then "+" does nothing.
    wb.OpenDialog(nil); wb.SaveDialog()
    wb.OpenDialog(nil); wb.SaveDialog()
    eq("up to eight tabs", #AltStableConfig.warbandTabs, 8)
    wb.OpenDialog(nil)
    check("a ninth cannot be started", not (dlg:IsShown() and dlg.draft and not dlg.index))
    wb.CloseDialog()

    -- Delete: the selection follows the tab it was on.
    AltStable.SetConfigValue("warbandTab", 5); wb.Refresh()
    wb.OpenDialog(3); wb.DeleteFromDialog()
    eq("delete removes the tab", #AltStableConfig.warbandTabs, 7)
    eq("  and a later selection shifts down with its tab", AltStableConfig.warbandTab, 4)
    -- Never the last one.
    AltStableConfig.warbandTabs = { AltStableConfig.warbandTabs[1] }
    wb.OpenDialog(1); wb.DeleteFromDialog()
    eq("the last tab cannot be deleted", #AltStableConfig.warbandTabs, 1)
    wb.CloseDialog()

    -- Existing custom tabs are never re-seeded.
    AltStableConfig.warbandTabs = { { name = "Mine", icon = "x", cats = { misc = true } } }
    wb.Refresh()
    eq("a customized profile keeps its tabs", AltStableConfig.warbandTabs[1].name, "Mine")

    -- Leaving the tab closes anything open.
    wb.OpenDialog(1)
    wb.Deactivate(main)
    check("switching away closes the dialog", dlg.draft == nil)

    AltStable.SetConfigValue = realSet
    WoW.reset()
end

print(("test_warband: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
