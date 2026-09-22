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
assert(loadfile("Core.lua"))()
dofile("Config.lua")

-- The plugin bootstraps itself a second after load (IsLoggedIn is true under
-- the stubs), which is what registers it with the core.
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

print(("test_warband: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
