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
eq("a bank tab's contents are not in the bags map", db.bags[2318] ~= 13, true)
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

-- A character who owns no tabs legitimately has an empty bank.
WoW.containers[6] = { size = 1, slot(2318, 13) }
WoW.bankTabs = {}
T.ScanBank()
eq("owning no tabs records an empty bank", next(AltStableWarbandDB[GUID].bank), nil)

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

local stale = blob:gsub("|s=%d+", "|s=1")
T.DeserializePlayer("Player-Peer-1", stale)
eq("an older relayed blob does not roll back fresher data", AltStableWarbandDB["Player-Peer-1"].bags[2318], 8)

T.DeserializePlayer("Player-Peer-2", "v1|s=999|kt=0|b=2318,notanumber|k=")
eq("a malformed blob is ignored", AltStableWarbandDB["Player-Peer-2"], nil)

print(("test_warband: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
