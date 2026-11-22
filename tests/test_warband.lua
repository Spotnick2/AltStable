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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
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

-- #420: a bank of unknown age (stamp 0, received for our own character)
-- read unchanged here gets dated, once; a dated one read unchanged doesn't move.
AltStableWarbandDB[GUID].bankStamp = 0
WoW.now = WoW.now + 5
T.ScanBank()
eq("#420: an undated bank read unchanged is dated by the read", AltStableWarbandDB[GUID].bankStamp, WoW.now)
local dated = AltStableWarbandDB[GUID].bankStamp
WoW.now = WoW.now + 5
T.ScanBank()
eq("  and an unchanged read of a dated bank leaves it", AltStableWarbandDB[GUID].bankStamp, dated)

-- Codex review of #438: a visit's first complete read confirms the bank, and
-- the session's first bag read the bags, even unchanged: the stamp says when
-- each was last seen right (also #432's "over a week old" after a visit).
T.OnBankClosed()
WoW.now = WoW.now + 100
T.OnBankOpened()
eq("a visit's first read restamps an unchanged bank", AltStableWarbandDB[GUID].bankStamp, WoW.now)
local visitStamp = WoW.now
WoW.now = WoW.now + 5
T.ScanBank()
eq("  the visit's later unchanged reads don't", AltStableWarbandDB[GUID].bankStamp, visitStamp)
T.NewSession()
WoW.now = WoW.now + 5
T.ScanBags()
eq("the session's first bag read restamps unchanged bags", AltStableWarbandDB[GUID].bagsStamp, WoW.now)
local sessionStamp = WoW.now
WoW.now = WoW.now + 5
T.ScanBags()
eq("  later unchanged ones don't", AltStableWarbandDB[GUID].bagsStamp, sessionStamp)
-- Confirmed, they refuse another PC's older reading of the same character.
do
    local heldBags, heldBank = AltStableWarbandDB[GUID].bags[2318], AltStableWarbandDB[GUID].bank[2318]
    T.DeserializePlayer(GUID, ("v1|s=%d|kt=%d|b=2318,1|k=2318,1"):format(sessionStamp - 1, visitStamp - 1))
    eq("  an older reading from another PC keeps the confirmed bags", AltStableWarbandDB[GUID].bags[2318], heldBags)
    eq("  and the confirmed bank", AltStableWarbandDB[GUID].bank[2318], heldBank)
end

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

-- Published for the Professions plugin's reagents (#268), with what it needs.
check("the count is published to the core as AltStable.ItemHolders", AltStable.ItemHolders == T.CountItem)
local _, holders = T.CountItem(2318)
eq("  a holder carries its guid (Professions leaves hidden alts out)", holders[1] and holders[1].guid, GUID)
eq("  a fresh bank is not stale", holders[1] and holders[1].bankStale, false)
AltStableWarbandDB[GUID].bankStamp = WoW.now - 8 * 86400
_, holders = T.CountItem(2318)
eq("  a bank over a week old is", holders[1] and holders[1].bankStale, true)
AltStableWarbandDB[GUID].bank = {}
_, holders = T.CountItem(2318)
eq("  a count with nothing in the bank never is", holders[1] and holders[1].bankStale, false)
AltStableWarbandDB[GUID] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, bankStamp = WoW.now }

-- Which of our own alts were never read (#423), by the section stamps: only
-- they keep "nobody has it" from being said.
do
    local heldDB, heldWB = AltStableDB, AltStableWarbandDB
    local function rec(g, extra)
        local r = { guid = g, name = g, class = "MAGE" }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    AltStableDB = {
        ["P-read"]    = rec("P-read", { scannedHere = true }),
        ["P-none"]    = rec("P-none", { scannedHere = true }),
        ["P-nobank"]  = rec("P-nobank", { provKind = "own-account" }),
        ["P-bankonly"]= rec("P-bankonly", { scannedHere = true }),
        ["P-friend"]  = rec("P-friend", { provKind = "third-party" }),
        ["P-bt0"]     = rec("P-bt0", { scannedHere = true }),
        ["P-kt0"]     = rec("P-kt0", { scannedHere = true }),
    }
    AltStableWarbandDB = {
        ["P-read"]     = { bags = {}, bagsStamp = 100, bank = {}, bankStamp = 100, stamp = 100 },
        ["P-nobank"]   = { bags = {}, bagsStamp = 100, stamp = 100 },
        ["P-bankonly"] = { bank = {}, bankStamp = 100, stamp = 100 },
    }
    T.DeserializePlayer("P-bt0", "v1|s=200|bt=0|kt=200|b=|k=")
    T.DeserializePlayer("P-kt0", "v1|s=200|bt=200|kt=0|b=|k=")
    local _, _, unseen = T.CountItem(2318)
    local set = {}
    for _, g in ipairs(unseen or {}) do set[g] = true end
    check("#423: an alt whose bags and bank were both read is not unseen", not set["P-read"])
    check("  one with no Warband entry is", set["P-none"])
    check("  our other account's, bank never visited, is", set["P-nobank"])
    check("  a bank read first, bags never, is", set["P-bankonly"])
    check("  a synced bt=0 (bags never read) is", set["P-bt0"])
    check("  a synced kt=0 (bank never read) is", set["P-kt0"])
    check("  a friend's is not ours to count", not set["P-friend"])
    AltStableWarbandDB["P-bankonly"].bags, AltStableWarbandDB["P-bankonly"].bagsStamp = {}, 150
    local _, _, after = T.CountItem(2318)
    local still = false
    for _, g in ipairs(after or {}) do if g == "P-bankonly" then still = true end end
    check("  and once its bags are read, empty, it no longer is", not still)
    AltStableDB, AltStableWarbandDB = heldDB, heldWB
end

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

-- #304: never chosen (nil) means on, unless another addon already shows counts.
local function tipLines()
    lines = {}
    for _, fn in ipairs(ttCalls) do fn(tt, { id = 2318 }) end
    return #lines
end
AltStableConfig.warbandItemTooltips = nil
WoW.loaded = WoW.loaded or {}
check("never chosen, no other counts addon: on by default", tipLines() > 0)
for _, other in ipairs({ "BagBrother", "Bagnon", "Syndicator", "Altoholic" }) do
    WoW.loaded[other] = true
    eq("  but off with " .. other .. " loaded (no counts twice)", tipLines(), 0)
    WoW.loaded[other] = nil
end
WoW.loaded.Bagnon, WoW.loaded.BagBrother = true, true
eq("  the help says which addon, by the name the player installed",
   AltStable.OtherItemCountsAddon(), "Bagnon")
local help = {}
local htip = { AddLine = function(_, s) help[#help + 1] = s end }
AltStable.ItemTooltipCountsHelp(htip)
check("  and the checkbox's help explains why it starts off",
      (help[3] or ""):find("Bagnon already shows its own counts", 1, true) ~= nil, help[3])
AltStable.SetConfigValue("warbandItemTooltips", true)
check("the player's own true wins over another addon", tipLines() > 0)
help = {}
AltStable.ItemTooltipCountsHelp(htip)
eq("  and the help no longer says it starts off", #help, 3)
check("  it points at the layout, matching and item options (#403)",
      (help[3] or ""):find("Options, Item tooltips", 1, true) ~= nil, help[3])
AltStable.SetConfigValue("warbandItemTooltips", false)
WoW.loaded.Bagnon, WoW.loaded.BagBrother = nil, nil
eq("the player's own false wins with nothing else loaded", tipLines(), 0)

------------------------------------------------------------
-- #403: only this character's faction and/or ruleset, and items with no counts
------------------------------------------------------------
do
    local ALLY, HORDE, PVP = "Player-1-ALLY", "Player-1-HORDE", "Player-1-PVP"
    AltStableDB = {
        [GUID]  = { guid = GUID,  name = "Kaleid", class = "MAGE",    faction = "Alliance", realm = "Forever PvE" },
        [ALLY]  = { guid = ALLY,  name = "Alder",  class = "WARRIOR", faction = "Alliance", realm = "Forever PvE" },
        [HORDE] = { guid = HORDE, name = "Birch",  class = "ROGUE",   faction = "Horde",    realm = "Forever PvE" },
        [PVP]   = { guid = PVP,   name = "Cedar",  class = "PRIEST",  faction = "Alliance", realm = "Forever PvP" },
    }
    AltStableWarbandDB = {
        [GUID]  = { bags = { [2318] = 1 } },
        [ALLY]  = { bags = { [2318] = 2 } },
        [HORDE] = { bags = { [2318] = 4 } },
        [PVP]   = { bags = { [2318] = 8 } },
    }
    check("the two test realms are different rulesets",
          AltStable.RulesetOf("Forever PvE") ~= AltStable.RulesetOf("Forever PvP"))
    local function shown()
        lines = {}
        for _, fn in ipairs(ttCalls) do fn(tt, { id = 2318 }) end
        local t = table.concat(lines, " / ")
        local function has(n) return t:find(n, 1, true) ~= nil end
        return t, has
    end
    AltStable.SetConfigValue("warbandItemTooltips", true)
    local D = " \194\183 "
    eq("the layout is Separate groups unless chosen", AltStable.TooltipScope(), "both")
    local t, has = shown()
    check("no match box ticked: one list of everyone, as before",
          has("Total:|15") and has("Birch") and has("Cedar") and not has("Other"), t)
    check("  and no summary line", not has("+"), t)

    -- Separate groups (the default): the matching ones, the others, the Total.
    AltStable.SetConfigValue("tooltipSameFaction", true)
    t, has = shown()
    check("Faction, Separate groups: the matching ones first, under their faction",
          has("Alliance|11") and t:find("Alliance|11", 1, true) < t:find("Other", 1, true), t)
    check("  then the others under the faction that explains them all",
          has("Other faction" .. D .. "Horde|4") and has("Birch|4"), t)
    check("  untagged: the heading already says why", not has("(Horde)"), t)
    check("  Birch is listed once, after that heading",
          select(2, t:gsub("Birch", "")) == 1 and t:find("Other faction", 1, true) < t:find("Birch", 1, true), t)
    check("  the PvP alt matches on faction", has("Cedar|") and t:find("Cedar", 1, true) < t:find("Other", 1, true), t)
    check("  and everyone's Total last", has("Total|15") and t:find("Total|15", 1, true) > t:find("Birch", 1, true), t)

    -- Summarize other characters.
    AltStable.SetConfigValue("tooltipScope", "side")
    t, has = shown()
    check("Faction, Summarize: everyone's Total, the matching ones by name",
          has("Total:|15") and has("Kaleid|") and has("Cedar|") and not has("Birch"), t)
    check("  and one line for the rest, naming their faction", has("+4 on Horde characters"), t)

    -- The order within a group: by name unless chosen, by count on request.
    AltStable.SetConfigValue("tooltipScope", "all")
    t, has = shown()
    check("One list by name: Alder before Cedar", t:find("Alder", 1, true) < t:find("Cedar", 1, true), t)
    AltStable.SetConfigValue("tooltipSort", "count")
    t, has = shown()
    check("  by count: Cedar's 8, Birch's 4, Alder's 2, Kaleid's 1",
          t:find("Cedar", 1, true) < t:find("Birch", 1, true) and t:find("Birch", 1, true) < t:find("Alder", 1, true)
          and t:find("Alder", 1, true) < t:find("Kaleid", 1, true), t)
    AltStable.SetConfigValue("tooltipSort", nil)
    AltStable.SetConfigValue("tooltipScope", "side")

    -- One list: the boxes don't matter.
    AltStable.SetConfigValue("tooltipScope", "all")
    t, has = shown()
    check("One list: everyone together, whatever the boxes say",
          has("Total:|15") and has("Birch|") and not has("Other") and not has("+"), t)
    AltStable.SetConfigValue("tooltipScope", "bogus")
    eq("an unknown layout is Separate groups", AltStable.TooltipScope(), "both")

    -- Ruleset alone.
    AltStable.SetConfigValue("tooltipSameFaction", false)
    AltStable.SetConfigValue("tooltipSameRuleset", true)
    local pvp = AltStable.RulesetName("Forever PvP")
    AltStable.SetConfigValue("tooltipScope", "side")
    t, has = shown()
    check("Ruleset, Summarize: the PvP alt summarized, the Horde one listed",
          has("Total:|15") and has("Birch") and not has("Cedar") and has("+8 on " .. pvp .. " characters"), t)
    AltStable.SetConfigValue("tooltipScope", "both")
    t, has = shown()
    check("  Separate groups: under this character's ruleset, then the other one",
          has(AltStable.RulesetName("Forever PvE") .. "|7") and has("Other ruleset" .. D .. pvp .. "|8"), t)

    -- Both boxes: a character must match both. Birch differs by faction, Cedar
    -- by ruleset, so no one reason explains the others: "Other characters",
    -- each tagged.
    AltStable.SetConfigValue("tooltipSameFaction", true)
    t, has = shown()
    check("both boxes, Separate groups: what they share, then Other characters",
          has("Alliance" .. D .. AltStable.RulesetName("Forever PvE") .. "|3") and has("Other characters|12"), t)
    check("  each other character with its reason", has("Birch |cff888888(Horde)|r") and has("Cedar |cff888888(" .. pvp .. ")|r"), t)
    AltStable.SetConfigValue("tooltipScope", "side")
    t, has = shown()
    check("both boxes, Summarize: one line for a mix", has("Total:|15") and has("+12 on other characters"), t)
    -- One reason for all of them, both parts: Birch on a Horde PvP realm, Cedar back on PvE.
    AltStableDB[HORDE].realm, AltStableDB[PVP].realm = "Forever PvP", "Forever PvE"
    t, has = shown()
    check("  a Horde PvP character alone: named both ways", has("+4 on Horde " .. pvp .. " characters"), t)
    AltStable.SetConfigValue("tooltipScope", "both")
    t, has = shown()
    check("    and in Separate groups", has("Horde" .. D .. pvp .. "|4") and not has("(Horde"), t)
    AltStableDB[HORDE].realm, AltStableDB[PVP].realm = "Forever PvE", "Forever PvP"
    AltStable.SetConfigValue("tooltipScope", "side")

    -- #404 review: what is summarized keeps its warnings. Only Birch (Horde)
    -- has bank stock, eight days old; Birch is not listed, the warning is.
    AltStableWarbandDB[HORDE] = { bags = {}, bank = { [2318] = 4 }, bankStamp = WoW.now - 8 * 86400 }
    AltStable.SetConfigValue("tooltipSameRuleset", false)
    t, has = shown()
    check("Summarize: a stale bank summarized still warns",
          has("+4 on Horde characters") and has("Bank data may be out of date") and not has("Birch"), t)
    AltStableWarbandDB[HORDE] = { bags = { [2318] = 4 } }
    t, has = shown()
    check("  and a fresh one does not", not has("out of date"), t)
    AltStable.SetConfigValue("tooltipSameRuleset", true)

    -- #412: with the realm hidden, the records' stored rulesets do the work.
    do
        local heldRealms = {}
        for g, c in pairs(AltStableDB) do heldRealms[g] = c.realm; c.ruleset = AltStable.RulesetOf(c.realm); c.realm = "" end
        AltStable.SetConfigValue("tooltipScope", "both")
        local t2, has2 = shown()
        check("realm hidden, rulesets stored: named headings still",
              has2("Alliance" .. D .. AltStable.RulesetName({ ruleset = "Normal" }) .. "|3")
              and has2("Other characters|12") and has2("Cedar |cff888888(" .. pvp .. ")|r"), t2)
        AltStable.SetConfigValue("tooltipScope", "side")
        for g, c in pairs(AltStableDB) do c.realm = heldRealms[g]; c.ruleset = nil end
    end

    -- A record whose faction or realm can't be read matches.
    AltStableDB[HORDE].faction, AltStableDB[PVP].realm = nil, nil
    t, has = shown()
    check("an unknown faction or realm is listed, not summarized", has("Birch") and has("Cedar") and not has("+"), t)
    -- #410 review: in Separate groups, nothing confirms they share this
    -- character's faction and ruleset, so the heading doesn't say it does.
    AltStable.SetConfigValue("tooltipScope", "both")
    AltStableDB[PVP].realm = "Forever PvP"      -- Cedar elsewhere, so there are groups
    t, has = shown()
    check("Separate groups with an unknown faction among them: a neutral heading",
          has("Matching characters|7") and not has("Alliance" .. D) and has("Birch"), t)
    check("  still counted in the Total", has("Total|15"), t)
    AltStableDB[HORDE].faction = "Horde"
    AltStableDB[ALLY].realm = ""
    t, has = shown()
    check("  a blank realm among them: the same", has("Matching characters|3"), t)
    AltStableDB[ALLY].realm = "Forever PvE"
    t, has = shown()
    check("  all known again: named", has("Alliance" .. D .. AltStable.RulesetName("Forever PvE") .. "|3"), t)
    AltStable.SetConfigValue("tooltipScope", "side")
    AltStableDB[HORDE].faction, AltStableDB[PVP].realm = "Horde", "Forever PvP"

    -- Nobody matching: Summarize keeps the Total and the line, Separate groups
    -- has no empty heading.
    AltStableWarbandDB[GUID], AltStableWarbandDB[ALLY] = nil, nil
    t, has = shown()
    check("nobody matching, Summarize: the Total and the line", has("Total:|12") and has("+12 on other"), t)
    AltStable.SetConfigValue("tooltipScope", "both")
    t, has = shown()
    check("  Separate groups: no empty heading, the others and the Total",
          not has("Alliance") and has("Other characters|12") and has("Total|12"), t)
    AltStableWarbandDB[GUID], AltStableWarbandDB[ALLY] = { bags = { [2318] = 1 } }, { bags = { [2318] = 2 } }

    -- The Warband tab's own grid counts everyone.
    local _, all = T.CountItem(2318)
    eq("CountItem itself is unfiltered (the Warband grid's view)", #all, 4)

    AltStable.SetConfigValue("tooltipSameFaction", false)
    AltStable.SetConfigValue("tooltipSameRuleset", false)
    AltStable.SetConfigValue("tooltipScope", nil)

    -- Items with no counts.
    eq("an item is not ignored unless chosen", AltStable.TooltipIgnored(2318), false)
    AltStable.SetTooltipIgnored(2318, true)
    eq("ignoring an item saves it in the config", AltStableConfig.tooltipIgnore[2318], true)
    shown()
    eq("  and its tooltip gets no counts", #lines, 0)
    AltStableWarbandDB[GUID].bags[765] = 3
    lines = {}
    for _, fn in ipairs(ttCalls) do fn(tt, { id = 765 }) end
    check("  other items still do", #lines > 0)
    eq("the list is sorted IDs", table.concat(AltStable.TooltipIgnoredList(), ","), "2318")
    AltStable.SetTooltipIgnored(2318, false)
    check("unignoring brings the counts back", (shown()):find("Total:", 1, true) ~= nil)
    eq("  and leaves an empty list", #AltStable.TooltipIgnoredList(), 0)

    -- /alts tooltip: a shift-clicked link or an ID.
    local link = "|cffffffff|Hitem:6948::::::::60:::::|h[Hearthstone]|h|r"
    eq("an item link gives its ID", AltStable.ItemIDFromArg(link), 6948)
    eq("  a bare ID too", AltStable.ItemIDFromArg(" 6948 "), 6948)
    eq("  anything else nothing", AltStable.ItemIDFromArg("Hearthstone"), nil)
    SlashCmdList.ALTSTABLE("tooltip ignore " .. link)
    eq("/alts tooltip ignore <link> leaves the Hearthstone out", AltStable.TooltipIgnored(6948), true)
    SlashCmdList.ALTSTABLE("tooltip")
    SlashCmdList.ALTSTABLE("tooltip unignore 6948")
    eq("/alts tooltip unignore <id> brings it back", AltStable.TooltipIgnored(6948), false)
    SlashCmdList.ALTSTABLE("tooltip ignore")
    eq("  with no item, nothing changes", #AltStable.TooltipIgnoredList(), 0)

    AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid", class = "MAGE" } }
    AltStableWarbandDB = { [GUID] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, bankStamp = WoW.now } }
    AltStable.SetConfigValue("warbandItemTooltips", false)
end

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
AltStableWarbandDB["Player-Peer-1"].bagsStamp, AltStableWarbandDB["Player-Peer-1"].bankStamp = 500, 500
local older = "v1|s=400|kt=400|b=2318,999|k=2318,999"
check("an older blob says nothing new (#422)", not T.DeserializePlayer("Player-Peer-1", older))
eq("an older relayed blob does not roll back fresher data",
   AltStableWarbandDB["Player-Peer-1"].bags[2318], 8)
local newer = "v1|s=600|kt=600|b=2318,999|k=2318,13"
eq("a newer one says so, for the core to mark (#422)", T.DeserializePlayer("Player-Peer-1", newer), true)
eq("  a newer one is applied", AltStableWarbandDB["Player-Peer-1"].bags[2318], 999)
check("  the same again says nothing new", not T.DeserializePlayer("Player-Peer-1", newer))
check("  nor other contents under the same stamps: taken, not marked",
      not T.DeserializePlayer("Player-Peer-1", "v1|s=600|kt=600|bt=600|b=2318,998|k=2318,13"))
eq("  (taken)", AltStableWarbandDB["Player-Peer-1"].bags[2318], 998)
eq("  a newer bank alone says so", T.DeserializePlayer("Player-Peer-1", "v1|s=600|kt=601|bt=600|b=2318,998|k=2318,14"), true)
eq("  and newer mail alone", T.DeserializePlayer("Player-Peer-1",
   "v1|s=600|kt=601|bt=600|b=2318,998|k=2318,14|mt=700|mm=0|m=2318,1"), true)
eq("  and a newer outbox alone", T.DeserializePlayer("Player-Peer-1",
   "v1|s=600|kt=601|bt=600|b=2318,998|k=2318,14|mt=700|mm=0|m=2318,1|ot=800|o=Alt-Name@790:2318,1"), true)

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
local realRefresh, realActive = wb.RequestRefresh, wb.isActive
wb.RequestRefresh, wb.isActive = function() redraws = redraws + 1 end, true
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=100|b=2318,2|k=")
eq("  re-sending the same one changes nothing", AltStableWarbandDB["Player-Same-1"].bags[2318], 2)
eq("  and does not redraw the grid", redraws, 0)
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=100|b=2318,3|k=")
eq("  a changed one does", redraws, 1)
T.DeserializePlayer("Player-Same-1", "v1|s=100|kt=101|b=2318,3|k=")
eq("  as does a bank stamp moving on its own", redraws, 2)
wb.RequestRefresh, wb.isActive = realRefresh, realActive
T.DeserializePlayer("Player-Same-1", "v1|s=99|kt=99|b=2318,777|k=")
eq("  and an older one is still refused", AltStableWarbandDB["Player-Same-1"].bags[2318], 3)

-- #420: the bank has its own stamp. Newer bags with an older bank (a second PC
-- holding an old bank snapshot) take the bags and keep the bank.
do
    local G = "Player-Bank-1"
    local function hold() AltStableWarbandDB[G] = { bags = { [1] = 1 }, bank = { [2318] = 20 }, stamp = 100,
                                                    bagsStamp = 100, bankStamp = 95 } end
    local function bank() return AltStableWarbandDB[G].bank[2318] end
    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=60|b=1,2|k=2318,3")
    eq("#420: newer bags with an older bank: the bags are taken", AltStableWarbandDB[G].bags[1], 2)
    eq("  the bank is kept", bank(), 20)
    eq("  with its own stamp", AltStableWarbandDB[G].bankStamp, 95)
    -- Replayed, it changes nothing and costs no redraw.
    local n = 0
    wb.RequestRefresh, wb.isActive = function() n = n + 1 end, true
    T.DeserializePlayer(G, "v1|s=101|kt=60|b=1,2|k=2318,3")
    eq("  a replay doesn't redraw", n, 0)
    wb.RequestRefresh, wb.isActive = realRefresh, realActive

    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=95|b=1,1|k=2318,7")
    eq("an equal bank stamp with another map is taken (B2)", bank(), 7)
    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=95|b=1,1|k=")
    eq("  so is a same-second emptying", bank(), nil)
    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=96|b=1,1|k=")
    eq("a newer confirmed-empty bank clears it", bank(), nil)
    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=0|b=1,1|k=")
    eq("a never-read bank (kt=0) keeps it (B1)", bank(), 20)

    hold()
    T.DeserializePlayer(G, "v1|s=101|b=1,1|k=2318,3")
    eq("no kt= (unknown age) keeps a dated bank", bank(), 20)
    hold()
    T.DeserializePlayer(G, "v1|s=101|xkt=123|b=1,1|k=2318,3")
    eq("  xkt= is not kt=", bank(), 20)
    hold()
    T.DeserializePlayer(G, "v1|s=101|kt=123junk|b=1,1|k=2318,3")
    eq("  nor is kt=123junk", bank(), 20)

    AltStableWarbandDB[G] = nil
    T.DeserializePlayer(G, "v1|s=200|b=1,1|k=2318,3")
    eq("no kt= on an empty store: the bank is taken", bank(), 3)
    eq("  undated (0), not under the overall stamp", AltStableWarbandDB[G].bankStamp, 0)
    check("  and relayed as never read", (T.SerializePlayer(G) or ""):find("|kt=0|", 1, true) ~= nil,
          T.SerializePlayer(G))
    T.DeserializePlayer(G, "v1|s=201|kt=150|b=1,1|k=2318,9")
    eq("  a confirmed bank with a lower kt but newer overall stamp replaces it", bank(), 9)
    eq("  dated", AltStableWarbandDB[G].bankStamp, 150)

    -- Codex review of #438: newer bags held don't keep out a newer bank.
    AltStableWarbandDB[G] = { bags = { [1] = 7 }, bank = { [2318] = 2 }, stamp = 130, bagsStamp = 130, bankStamp = 60 }
    T.DeserializePlayer(G, "v1|s=100|kt=100|b=1,3|k=2318,11")
    eq("held bags at 130, bank at 60; a blob at 100 with its bank at 100: the bank lands", bank(), 11)
    eq("  dated 100", AltStableWarbandDB[G].bankStamp, 100)
    eq("  and the newer bags stay", AltStableWarbandDB[G].bags[1], 7)
    eq("  with their stamp", AltStableWarbandDB[G].bagsStamp, 130)
    eq("  the overall stamp is the newest section", AltStableWarbandDB[G].stamp, 130)

    -- An undated bank with items (taken from a blob with no kt=) is never
    -- emptied by a never-read one: kt=0 is no evidence (Codex follow-up on #438).
    AltStableWarbandDB[G] = { bags = { [1] = 1 }, bank = { [2318] = 3 }, stamp = 200, bagsStamp = 200, bankStamp = 0 }
    T.DeserializePlayer(G, "v1|s=100|kt=0|b=1,1|k=")
    eq("a never-read blob keeps an undated bank with items", bank(), 3)
    T.DeserializePlayer(G, "v1|s=100|b=1,1|k=")
    eq("  so does one with no kt=", bank(), 3)
    T.DeserializePlayer(G, "v1|s=100|kt=150|b=1,1|k=")
    eq("  a dated empty bank clears it", bank(), nil)
    AltStableWarbandDB[G] = { bags = { [1] = 1 }, bank = {}, stamp = 200, bagsStamp = 200, bankStamp = 0 }
    T.DeserializePlayer(G, "v1|s=100|b=1,1|k=2318,4")
    eq("  an undated EMPTY bank held takes an undated one with items", bank(), 4)

    -- bt= dates the bags; without it, s= does (an older sender).
    AltStableWarbandDB[G] = { bags = { [1] = 7 }, bank = {}, stamp = 110, bagsStamp = 110, bankStamp = 0 }
    T.DeserializePlayer(G, "v1|s=130|kt=130|bt=80|b=1,2|k=")
    eq("bags dated by bt= older than the held ones are kept", AltStableWarbandDB[G].bags[1], 7)
    T.DeserializePlayer(G, "v1|s=130|kt=130|b=1,2|k=")
    eq("  an older sender's (no bt=) are dated by s=", AltStableWarbandDB[G].bags[1], 2)
    check("  and the serializer sends bt=", (T.SerializePlayer(G) or ""):find("|bt=130|", 1, true) ~= nil,
          T.SerializePlayer(G))
    AltStableWarbandDB[G] = nil
end

-- A blob missing a section is malformed, not "this character has nothing":
-- ParseMap(nil) is an empty map, so this would silently blank the inventory.
AltStableWarbandDB["Player-Peer-3"] = { bags = { [2318] = 8 }, bank = { [2318] = 13 }, stamp = 100 }
T.DeserializePlayer("Player-Peer-3", "v1|s=200")
eq("a blob with no bags field leaves the stored bags alone",
   AltStableWarbandDB["Player-Peer-3"].bags[2318], 8)
T.DeserializePlayer("Player-Peer-3", "v1|s=200|b=2318,1")
eq("  and one with no bank field leaves the bank alone",
   AltStableWarbandDB["Player-Peer-3"].bank[2318], 13)

-- B1 (docs/AUDIT.md): kt=0 says the owner has never read this bank since its
-- data began (a bank read as empty carries its scan time). That is no
-- knowledge, so a held snapshot stays; the bags are still taken.
AltStableWarbandDB["Player-Peer-4"] = { bags = { [2318] = 8 }, bank = { [2318] = 13 },
                                        stamp = 100, bagsStamp = 100, bankStamp = 90 }
T.DeserializePlayer("Player-Peer-4", "v1|s=200|kt=0|b=2318,9|k=")
local p4 = AltStableWarbandDB["Player-Peer-4"]
eq("B1: a blob whose owner never read the bank keeps the held snapshot", p4.bank[2318], 13)
eq("  and its stamp", p4.bankStamp, 90)
eq("  while the bags are taken", p4.bags[2318], 9)
eq("  and the record's stamp moves", p4.stamp, 200)
redraws = 0
wb.RequestRefresh, wb.isActive = function() redraws = redraws + 1 end, true
T.DeserializePlayer("Player-Peer-4", "v1|s=200|kt=0|b=2318,9|k=")
eq("  re-sending it changes nothing and does not redraw", redraws, 0)
wb.RequestRefresh, wb.isActive = realRefresh, realActive
T.DeserializePlayer("Player-Peer-4", "v1|s=300|kt=300|b=2318,9|k=")
eq("  a bank read as empty (kt>0) still empties it", next(p4.bank), nil)
eq("  with its stamp", p4.bankStamp, 300)
-- Nothing held: kt=0 stores the empty map, as before.
T.DeserializePlayer("Player-Peer-5", "v1|s=200|kt=0|b=2318,1|k=")
check("  with nothing held, kt=0 stores an empty bank",
      AltStableWarbandDB["Player-Peer-5"] ~= nil and next(AltStableWarbandDB["Player-Peer-5"].bank) == nil)

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

-- A4 (docs/AUDIT.md): a guid no character record mentions is invisible in the
-- UI and stays on disk. The login used to delete it, which made a loss of
-- AltStable.lua take every bank snapshot in AltStableWarband.lua with it;
-- forget and cleanup are the deletes, and they are explicit.
AltStableWarbandDB["Player-Gone-1"] = { bags = { [2318] = 5 }, stamp = 100 }
T.BootstrapPlugin()
check("A4: an orphaned record survives the login", AltStableWarbandDB["Player-Gone-1"] ~= nil)
check("  and a known character's too", AltStableWarbandDB[GUID] ~= nil)
local total = T.CountItem(2318)
eq("  an orphan is invisible to the counts", total, 8)

-- #418: forgotten while Warband was off, so OnForget never ran: the next
-- bootstrap drops it; an orphan with no tombstone still stays; and never the
-- character being played.
AltStableConfig = AltStableConfig or {}
AltStableWarbandDB["Player-Forgot-1"] = { bags = { [2318] = 2 }, stamp = 100 }
AltStableConfig.forgottenCharacters = {
    ["Player-Forgot-1"] = { at = 1000, forgottenAt = 1000, name = "Forgot" },
    [GUID] = { at = 1000, forgottenAt = 1000, name = "Kaleid" },
}
local meRec = AltStableDB[GUID]
AltStableDB[GUID] = nil
T.BootstrapPlugin()
eq("#418: a forgotten character's orphan goes at the bootstrap", AltStableWarbandDB["Player-Forgot-1"], nil)
check("  one with no tombstone stays", AltStableWarbandDB["Player-Gone-1"] ~= nil)
check("  and so does the character being played", AltStableWarbandDB[GUID] ~= nil)
AltStableDB[GUID] = meRec
AltStableConfig.forgottenCharacters = nil

-- #418: mail sent by an orphan is as invisible as the rest of it.
do
    local now = time()
    AltStableWarbandDB["Player-Gone-1"].outbox = { { to = GUID, at = now, items = { [2318] = 4 } } }
    eq("an orphan sender's mail is not on its way to anyone", T.Incoming()[GUID], nil)
    AltStableDB["Player-Gone-1"] = { guid = "Player-Gone-1", name = "Gone", class = "ROGUE" }
    eq("  until its record is back", T.Incoming()[GUID] and T.Incoming()[GUID][2318], 4)
    AltStableDB["Player-Gone-1"] = nil
    AltStableWarbandDB["Player-Gone-1"].outbox = nil
end

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
check("  and a record no character record mentions is kept (A4)",
      AltStableWarbandDB["Player-Ghost-1"] ~= nil)

AltStableWarbandDB = {}
T.BootstrapPlugin()
eq("holding none, it does force one", resets, 1)

-- Orphans don't count as "we hold inventory": they are invisible, so counting
-- them would skip the baseline pull and leave the real inventory unfetched
-- behind watermarks that are already ahead.
resets = 0
AltStableDB = { [GUID] = { guid = GUID, name = "Kaleid" } }
AltStableWarbandDB = { ["Player-Ghost-2"] = { bags = { [2318] = 3 }, stamp = 100 } }
T.BootstrapPlugin()
eq("inventory for a character nobody has does not count as data", resets, 1)
check("  and it is kept (A4)", AltStableWarbandDB["Player-Ghost-2"] ~= nil)
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

-- ...while a scan whose session ended is still dropped. The close itself
-- reads the bank (#419: still readable inside BANKFRAME_CLOSED), and the old
-- timer then reads nothing.
AltStableWarbandDB[GUID].bank = nil
T.OnBagUpdate(6)
T.OnBankClosed()
eq("#419: the close reads the bank", AltStableWarbandDB[GUID].bank and AltStableWarbandDB[GUID].bank[2318], 13)
do
    local reads, real = 0, AltStable.API.GetContainerNumSlots
    AltStable.API.GetContainerNumSlots = function(b) if b == 6 then reads = reads + 1 end return real(b) end
    WoW.flushTimers()
    AltStable.API.GetContainerNumSlots = real
    eq("  and a scan whose bank session ended reads nothing", reads, 0)
end

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

    -- A cell follows Show like every item tooltip (the owner, 2026-11-20):
    -- every character, whatever the tab filters, and the tab's own count when
    -- it differs. Kaleid's 21 is the tab's; Birch, on the other faction and
    -- outside the tab's filter, holds 4 more.
    local BIRCH = "Player-1-BIRCH"
    AltStableDB[GUID].faction, AltStableDB[GUID].realm = "Alliance", "Forever PvE"
    AltStableDB[BIRCH] = { guid = BIRCH, name = "Birch", class = "ROGUE", faction = "Horde", realm = "Forever PvE" }
    AltStableWarbandDB[BIRCH] = { bags = { [2318] = 4 } }
    local function hover()
        hoverLines = {}
        AT_WB.hoverEntry = { id = 2318, total = 21, holders = { { name = "Kaleid", bags = 8, bank = 13 } } }
        for _, fn in ipairs(ttCalls) do fn(htt, { id = 2318 }) end
        return table.concat(hoverLines, " / ")
    end
    local t = hover()
    check("a cell lists every character, not only the tab's", t:find("Birch", 1, true) ~= nil
          and t:find("Total:|25", 1, true) ~= nil, t)
    check("  and says what the tab itself shows", t:find("21 shown in this tab", 1, true) ~= nil, t)
    AltStable.SetConfigValue("tooltipSameFaction", true)
    t = hover()
    check("  Separate groups: Birch under the other faction", t:find("Other faction \194\183 Horde|4", 1, true) ~= nil, t)
    AltStable.SetConfigValue("tooltipScope", "side")
    t = hover()
    check("  Summarize: everyone's Total, Birch as the line, and the tab's count",
          t:find("Total:|25", 1, true) ~= nil and t:find("+4 on Horde characters", 1, true) ~= nil
          and t:find("21 shown in this tab", 1, true) ~= nil, t)
    AltStable.SetConfigValue("tooltipIgnore", { [2318] = true })
    t = hover()
    check("  an item with no counts still gets them in a cell (hovering it is asking)", t:find("Total:", 1, true) ~= nil, t)
    AltStable.SetConfigValue("tooltipIgnore", nil)
    AltStable.SetConfigValue("tooltipScope", nil)
    AltStable.SetConfigValue("tooltipSameFaction", nil)
    AltStableWarbandDB[BIRCH] = nil
    t = hover()
    check("the same count as the tab: no tab line", not t:find("shown in this tab", 1, true), t)
    AltStableDB[BIRCH] = nil
    AltStable.SetConfigValue("warbandItemTooltips", false)
    t = hover()
    check("  and the global opt-in off still leaves the cell its breakdown", t:find("Total:|21", 1, true) ~= nil, t)
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
    eq("RP-PvP is its own ruleset, not RP", M.RulesetOf("Forever RP-PvP"), "RPPvP")
    eq("  however it is written: RPPvP", M.RulesetOf("Forever RPPvP"), "RPPvP")
    eq("  RP PvP", M.RulesetOf("Forever RP PvP 2"), "RPPvP")
    eq("  Roleplay PvP", M.RulesetOf("Forever Roleplay PvP"), "RPPvP")
    eq("  in capitals, never PvP", M.RulesetOf("CAMWOW US2 Realm 3 RP-PVP"), "RPPvP")
    eq("an RP realm with no PvP stays RP", M.RulesetOf("CAMWOW US2 Realm 2 RP"), "RP")
    check("RP-PvP is in the list of rulesets", (function()
        for _, r in ipairs(M.RULESETS) do if r == "RPPvP" then return true end end
    end)())
    eq("a Hardcore realm", M.RulesetOf("Forever Hardcore"), "Hardcore")
    eq("'rp' inside a word is not RP", M.RulesetOf("Carp Lake"), "Normal")
    eq("no realm is Unknown, never Normal", M.RulesetOf(nil), "Unknown")
    eq("  nor a blank one", M.RulesetOf("  "), "Unknown")
    eq("'current' resolves against where you are", M.ResolveRuleset("current", "Classic Beta PvP 2"), "PvP")
    eq("  and so does an unset setting", M.ResolveRuleset(nil, "Classic Beta PvE"), "Normal")
    eq("'all' is no filter", M.ResolveRuleset("all", "Classic Beta PvP"), nil)

    -- #412: since the 2026-11-20 hotfix the realm is hidden ("" from
    -- GetRealmName), so a record carries its ruleset, read from the game's rules.
    eq("a record's own ruleset wins over its realm",
       M.RulesetOf({ ruleset = "PvP", realm = "Classic Beta PvE" }), "PvP")
    eq("  a record with a blank realm still has one", M.RulesetOf({ ruleset = "RP", realm = "" }), "RP")
    eq("  one with none reads its realm", M.RulesetOf({ realm = "Classic Beta PvP" }), "PvP")
    eq("  a stored value it doesn't know is ignored", M.RulesetOf({ ruleset = "Bogus", realm = "Forever RP" }), "RP")
    eq("  neither: Unknown", M.RulesetOf({ realm = "" }), "Unknown")
    eq("'current' resolves against the game's rules", M.ResolveRuleset("current", { ruleset = "Hardcore", realm = "" }), "Hardcore")

    -- The game's rules, as read: Hardcore first, RP and PvP together are RP-PvP.
    local R, held = Enum.GameRule, WoW.gameRules
    -- Each reading below is a new session's: the answer is kept once read (#435).
    local fresh = AltStable._test.ResetLiveRuleset
    local function live() fresh(); return AltStable.LiveRuleset() end
    local function rules(h, rp, pvp)
        WoW.gameRules = { [R.HardcoreRuleset] = h, [R.RPRuleset] = rp, [R.PvPRuleset] = pvp }
        return live()
    end
    eq("no rule on: Normal", rules(false, false, false), "Normal")
    eq("PvP", rules(false, false, true), "PvP")
    eq("RP", rules(false, true, false), "RP")
    eq("RP and PvP: RP-PvP", rules(false, true, true), "RPPvP")
    eq("Hardcore wins", rules(true, false, true), "Hardcore")
    local realRealm = GetRealmName
    GetRealmName = function() return "" end
    rules(false, false, true)
    eq("where you are, with the realm hidden: the rules", AltStable.CurrentRuleset(), "PvP")
    local realRules = Enum.GameRule
    Enum.GameRule = nil
    eq("a client without the rule names can't say", live(), nil)
    local heldRec = AltStableDB[UnitGUID("player")]
    AltStableDB[UnitGUID("player")] = nil
    fresh()
    eq("  and where you are falls back to the realm: hidden, and no record, Unknown", AltStable.CurrentRuleset(), "Unknown")
    AltStableDB[UnitGUID("player")] = heldRec
    Enum.GameRule = { RPRuleset = 1, PvPRuleset = 2 }
    eq("  a missing name is the same as none", live(), nil)
    Enum.GameRule = realRules
    -- #413 review: a query that fails is not "off".
    local realActive = C_GameRules.IsGameRuleActive
    C_GameRules.IsGameRuleActive = function(rule)
        if rule == Enum.GameRule.PvPRuleset then error("not ready") end
        return false
    end
    eq("a rule query that throws: no reading, never Normal", live(), nil)
    C_GameRules.IsGameRuleActive = function() return nil end
    eq("  nor one that answers nil", live(), nil)

    -- Read once a session (#435): the character's ruleset can't change while
    -- it is logged in. Only a reading is kept: nil at login, while the rules
    -- aren't readable yet, would freeze "unknown" for the session.
    local asked = 0
    C_GameRules.IsGameRuleActive = function(rule) asked = asked + 1; return rule == R.PvPRuleset end
    fresh()
    eq("the first call reads the rules", AltStable.LiveRuleset(), "PvP")
    local first = asked
    check("  asking each of the three", first == 3, tostring(first))
    eq("a second call", AltStable.LiveRuleset(), "PvP")
    eq("  doesn't ask again", asked, first)
    fresh()
    asked = 0
    C_GameRules.IsGameRuleActive = function() asked = asked + 1; error("not ready") end
    eq("a first call before the rules are readable says nothing", AltStable.LiveRuleset(), nil)
    C_GameRules.IsGameRuleActive = function(rule) asked = asked + 1; return rule == R.RPRuleset end
    eq("  and isn't kept: the next call reads them", AltStable.LiveRuleset(), "RP")
    local n = asked
    eq("  and keeps that", AltStable.LiveRuleset(), "RP")
    eq("  without asking again", asked, n)
    fresh()
    C_GameRules.IsGameRuleActive = function() return "yes" end
    eq("an answer that isn't a boolean isn't kept either", AltStable.LiveRuleset(), nil)
    C_GameRules.IsGameRuleActive = function(rule) return rule == R.HardcoreRuleset end
    eq("  the next call reads", AltStable.LiveRuleset(), "Hardcore")
    C_GameRules.IsGameRuleActive = realActive
    fresh()
    -- No rules, no realm: where you are is this character's own record.
    Enum.GameRule = nil
    local me = UnitGUID("player")
    local heldMe = AltStableDB[me]
    AltStableDB[me] = { guid = me, name = "Me", ruleset = "PvP", realm = "" }
    fresh()
    eq("rules and realm unreadable: the current ruleset is this character's record", AltStable.CurrentRuleset(), "PvP")
    AltStableDB[me] = nil
    eq("  no record either: Unknown", AltStable.CurrentRuleset(), "Unknown")
    AltStableDB[me] = heldMe
    Enum.GameRule = realRules
    fresh()
    GetRealmName = realRealm
    WoW.gameRules = held
    eq("a named ruleset is itself", M.ResolveRuleset("RP", "Classic Beta PvP"), "RP")
    eq("'current' on an RP-PvP realm is RP-PvP", M.ResolveRuleset("current", "Forever RP-PvP"), "RPPvP")

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

    -- Anchored beside the sidebar's edge through the sheet's helper (#150), so
    -- it follows a collapse. Declining here keeps the fixed-offset fallback.
    local besideSidebar
    AltStable.AnchorBesideSidebar = function(region) besideSidebar = region; return false end
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1200 end
    main.GetHeight = function() return 800 end
    wb.Activate(main)
    check("the panel anchors beside the sidebar's edge (#150)", besideSidebar ~= nil)
    -- #304: the tab's counts box follows a change made in Options meanwhile.
    if wb.tipCheck then
        local heldTips = AltStableConfig.warbandItemTooltips
        AltStableConfig.warbandItemTooltips = false
        wb.Activate(main)
        eq("the counts box shows a change made elsewhere on the next open", wb.tipCheck:GetChecked() and true or false, false)
        AltStableConfig.warbandItemTooltips = true
        wb.Activate(main)
        eq("  both ways", wb.tipCheck:GetChecked() and true or false, true)
        AltStableConfig.warbandItemTooltips = heldTips
    else
        check("the Warband tab exposes its counts box", false)
    end
    check("  and re-lays out when the window changes size", type(plugin.OnResize) == "function")
    AltStable.AnchorBesideSidebar = nil
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

    -- #435: redraws asked for by data are coalesced, and none while the sheet
    -- is closed (the window hidden, the tab still active).
    do
        local real, n = wb.Refresh, 0
        wb.Refresh = function(...) n = n + 1; return real(...) end
        -- The sheet's refresh, which the tab wraps on activation.
        local realSheet = AltStable.RefreshSheet
        local base = function() end
        AltStable.RefreshSheet = function() base() end
        wb.Activate(main)
        WoW.flushTimers()
        n = 0
        for i = 1, 40 do
            T.DeserializePlayer("Player-435-" .. i, "v1|s=" .. (500 + i) .. "|kt=0|b=101," .. i .. "|k=")
        end
        eq("#435: 40 changed inventories in one pull: no redraw yet", n, 0)
        WoW.flushTimers()
        eq("  one on the next frame", n, 1)
        WoW.flushTimers()
        eq("  and only one", n, 1)
        AltStable.RefreshSheet()
        AltStable.RefreshSheet()
        WoW.flushTimers()
        eq("two sheet refreshes in a frame: one redraw", n, 2)
        -- The sheet's refresh finishing a window animation redraws the panel
        -- itself (OnResize): that draw is the one (Codex review of #469).
        base = function() wb.Refresh() end
        n = 0
        T.DeserializePlayer("Player-435-1", "v1|s=650|kt=0|b=101,55|k=")
        AltStable.RefreshSheet()
        WoW.flushTimers()
        eq("a sheet refresh that redraws on resize: one draw in all", n, 1)
        base = function() end
        main:Hide()
        n = 0
        for i = 1, 40 do
            T.DeserializePlayer("Player-435-" .. i, "v1|s=" .. (600 + i) .. "|kt=0|b=101," .. (i + 1) .. "|k=")
        end
        AltStable.RefreshSheet()
        WoW.flushTimers()
        eq("the sheet closed: none", n, 0)
        main:Show()
        eq("  shown again: one", n, 1)
        WoW.flushTimers()
        eq("  and none more", n, 1)
        main:Hide()
        main:Show()
        eq("closed and opened with nothing new: none", n, 1)
        -- Asked for, then the sheet closed before the next frame: drawn on show.
        n = 0
        T.DeserializePlayer("Player-435-1", "v1|s=700|kt=0|b=101,77|k=")
        main:Hide()
        WoW.flushTimers()
        eq("closed before the queued redraw ran: none", n, 0)
        main:Show()
        eq("  one when it shows", n, 1)
        -- Dirty from a closed sheet, then another tab: the next activation
        -- draws once, not once for the dirt and once for itself.
        main:Hide()
        T.DeserializePlayer("Player-435-1", "v1|s=701|kt=0|b=101,78|k=")
        wb.Deactivate(main)
        main:Show()
        n = 0
        wb.Activate(main)
        WoW.flushTimers()
        eq("dirty, then another tab, then back: one draw", n, 1)
        -- Activation draws itself: a changed scan of our bags on open asks
        -- for a redraw, which that draw has already done.
        n = 0
        AltStableWarbandDB[ME] = { bags = { [101] = 99 } }
        WoW.containers = { [0] = { size = 1, slot(101, 3) } }
        wb.Activate(main)
        WoW.flushTimers()
        eq("activation with a changed bag scan: one draw", n, 1)
        WoW.containers = {}
        for i = 1, 40 do AltStableWarbandDB["Player-435-" .. i] = nil end
        wb.Refresh = real
        AltStable.RefreshSheet = realSheet
    end
    -- Activating rescans our own (stubbed, empty) bags; put Kaleid's back.
    AltStableWarbandDB[ME] = { bags = { [101] = 2, [201] = 1 } }
    wb.Refresh()

    -- First draw: the four default tabs are seeded, through the seam.
    eq("the default tabs are seeded", #(AltStableConfig.warbandTabs or {}), 4)
    local seeded = false
    for _, k in ipairs(writes) do if k == "warbandTabs" then seeded = true end end
    check("  through SetConfigValue", seeded)

    -- Warband, current ruleset (PvP): Kaleid only - Morph is PvE, Hidden is hidden.
    eq("single view shows the selected tab", colKeys(), "1")
    eq("  holding this ruleset's trade goods, hidden characters left out", shownIDs(), "101")
    -- #412: with the realm hidden (the 2026-11-20 hotfix), "current" is the
    -- game's rules, not Unknown.
    do
        local realRealm, heldRules = GetRealmName, WoW.gameRules
        GetRealmName = function() return "" end
        WoW.gameRules = { [Enum.GameRule.PvPRuleset] = true }
        AltStable._test.ResetLiveRuleset()
        wb.Refresh()
        eq("  the realm hidden: still this ruleset's, from the game's rules", shownIDs(), "101")
        -- #413 review: no rules either - this character's own record says.
        local realRules, heldRuleset = Enum.GameRule, AltStableDB[ME].ruleset
        Enum.GameRule = nil
        AltStableDB[ME].ruleset = "PvP"
        local heldRealm = AltStableDB[ME].realm
        AltStableDB[ME].realm = ""
        AltStable._test.ResetLiveRuleset()
        wb.Refresh()
        eq("  no rules and no realm: this character's record, its own items shown", shownIDs(), "101")
        Enum.GameRule, AltStableDB[ME].ruleset, AltStableDB[ME].realm = realRules, heldRuleset, heldRealm
        GetRealmName, WoW.gameRules = realRealm, heldRules
        AltStable._test.ResetLiveRuleset()
        wb.Refresh()
    end

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
    -- Clicking a tab already on screen keeps the window where it is.
    AltStable.SetConfigValue("warbandTab", 2); wb.Refresh()
    eq("  and a click on a shown tab does not scroll it", colKeys(), "1,2,3")
    AltStable.SetConfigValue("warbandTab", 1); wb.Refresh()
    eq("  with the potion in Consumables, its own column", (function()
        for _, c in ipairs(wb._cols) do if c.key == 2 then return #c.entries end end
    end)(), 1)
    -- More tabs than fit: the arrows get their own margin, and the status line
    -- says which tabs are on screen. All rulesets brings Other in: five pages.
    AltStable.SetConfigValue("warbandRuleset", "all"); wb.Refresh()
    local head = wb.colHeads[1]
    local headX = head and select(4, head:GetPoint())
    check("the first column starts clear of the left arrow", headX and headX >= 12 + 26, tostring(headX))
    local statusText = wb.StatusText and wb.StatusText()
    check("the status line says which tabs are shown",
          statusText and statusText:find("Tabs 1-3 of 5", 1, true) ~= nil, tostring(statusText))
    -- The rail says what a gold outline means.
    local railShown, railHidden
    for _, b in ipairs(wb.tabBtns) do
        if b:IsShown() and not b.isAdd then
            if b.shown then railShown = b else railHidden = b end
        end
    end
    check("a tab on screen is marked shown", railShown ~= nil)
    check("  and one off screen is not", railHidden ~= nil)
    AltStable.SetConfigValue("warbandRuleset", "current")
    AltStable.SetConfigValue("warbandView", "single"); wb.Refresh()
    local singleX = wb.colHeads[1] and select(4, wb.colHeads[1]:GetPoint())
    eq("single view has no arrow margin", singleX, 12)

    -- Personal: this character alone, whatever the ruleset says.
    AltStable.SetConfigValue("warbandScope", "personal")
    AltStable.SetConfigValue("warbandRuleset", "Normal"); wb.Refresh()
    eq("personal is this character, ruleset ignored", shownIDs(), "101")
    AltStable.SetConfigValue("warbandScope", "warband"); wb.Refresh()
    eq("warband on Normal is the PvE character", shownIDs(), "102")
    AltStable.SetConfigValue("warbandRuleset", "current")

    -- #461: the faction filter, kept in AltStableConfig, and the reset.
    do
        local ALLY, HORDE, NOFAC, UNK = "Player-1-F001", "Player-1-F002", "Player-1-F003", "Player-1-F004"
        local PVP = "Classic Beta PvP"
        AltStableDB[ALLY]  = { name = "Ally",  class = "PRIEST", realm = PVP, faction = "Alliance" }
        AltStableDB[HORDE] = { name = "Hordy", class = "ROGUE",  realm = PVP, faction = "Horde" }
        AltStableDB[NOFAC] = { name = "Nofac", class = "DRUID",  realm = PVP }
        AltStableDB[UNK]   = { name = "Unk",   class = "SHAMAN", realm = PVP, faction = "Unknown" }
        AltStableWarbandDB[ALLY]  = { bags = { [104] = 1 } }
        AltStableWarbandDB[HORDE] = { bags = { [105] = 1 } }
        AltStableWarbandDB[NOFAC] = { bags = { [106] = 1 } }
        AltStableWarbandDB[UNK]   = { bags = { [107] = 1 } }
        for id = 104, 107 do WoW.items[id] = { name = "Cloth " .. id, classID = 7, quality = 1, icon = id } end
        local heldFaction = WoW.faction
        local rb, fb, reset = wb.FilterControls()
        local function rows(name)
            local menu = wb.Menu(name)
            local out = {}
            for _, r in ipairs(menu and menu.rows or {}) do out[r.key] = r end
            return out
        end
        local function click(b) b:GetScript("OnClick")(b) end

        -- Current faction, Alliance: the Horde alt out; no faction or "Unknown" stays in.
        WoW.faction = "Alliance"
        wb.Refresh()
        eq("#461: current faction leaves the other side's alt out, an unrecorded faction stays",
           shownIDs(), "101,104,106,107")
        eq("  the button names the side", fb.label:GetText(), "Alliance")
        check("  at the defaults, no reset", not reset:IsShown())
        local st = wb.StatusText()
        check("  the status line names it too", st:find("PvP  ·  Alliance  ·  Read-only", 1, true) ~= nil, st)
        -- The player changes side: "current" follows, never saved resolved.
        WoW.faction = "Horde"
        wb.Refresh()
        eq("  playing Horde, current follows", shownIDs(), "101,105,106,107")
        eq("  and so does the button", fb.label:GetText(), "Horde")
        eq("  the saved choice is untouched", AltStableConfig.warbandFaction, nil)
        -- No readable faction: no faction filter.
        local realUFG = UnitFactionGroup
        UnitFactionGroup = function() return nil end
        wb.Refresh()
        eq("  an unreadable side filters nothing", shownIDs(), "101,104,105,106,107")
        eq("  and the button says Current faction", fb.label:GetText(), "Current faction")
        UnitFactionGroup = realUFG
        WoW.faction = "Alliance"

        -- The menu: rows labelled, the choice highlighted, a click writes it.
        wb.OpenFactionMenu()
        local menu, catcher = wb.Menu("faction")
        check("the faction menu opens", menu and menu:IsShown() and catcher:IsShown())
        local p, rel, relP = menu:GetPoint()
        check("  leftwards from the button's right edge", p == "TOPRIGHT" and rel == fb and relP == "BOTTOMRIGHT")
        local r = rows("faction")
        eq("  current spelled out", r.current.label:GetText(), "Current faction (Alliance)")
        eq("  both", r.all.label:GetText(), "Both factions")
        check("  current highlighted", r.current._active and not r.all._active and not r.Horde._active)
        if AltStable.SkinIsGlass() then
            check("  on glass, a dark backing under the menu", menu.backing ~= nil)
        end
        click(r.all)
        check("  a click closes it", not menu:IsShown() and not catcher:IsShown())
        eq("  and saves the choice", AltStableConfig.warbandFaction, "all")
        eq("both factions: everyone on this ruleset", shownIDs(), "101,104,105,106,107")
        eq("  the button says so", fb.label:GetText(), "Both factions")
        check("  and Reset appears", reset:IsShown())
        st = wb.StatusText()
        check("  the status line too", st:find("Both factions", 1, true) ~= nil, st)
        wb.OpenFactionMenu()
        check("  reopened, Both is the highlighted row", rows("faction").all._active and not rows("faction").current._active)
        menu:GetScript("OnKeyDown")(menu, "ESCAPE")
        check("  Escape closes it", not menu:IsShown() and not catcher:IsShown())

        -- An explicit side equal to the played one is still not the default.
        click(rows("faction").Alliance)
        eq("Alliance picked while playing Alliance", shownIDs(), "101,104,106,107")
        check("  still shows Reset", reset:IsShown())
        click(reset)
        eq("Reset puts the faction back to current", AltStableConfig.warbandFaction, "current")
        eq("  and the ruleset", AltStableConfig.warbandRuleset, "current")
        check("  and hides itself", not reset:IsShown())

        -- The ruleset through its menu: Normal while on PvP.
        wb.OpenRulesetMenu()
        local rmenu, rcatch = wb.Menu("ruleset")
        click(rows("ruleset").Normal)
        eq("Normal picked from the menu: the PvE alt", shownIDs(), "102")
        check("  Reset shows for the ruleset alone", reset:IsShown())
        wb.OpenRulesetMenu()
        check("  Normal highlighted", rows("ruleset").Normal._active and not rows("ruleset").current._active)
        -- Opening the other menu closes this one.
        wb.OpenFactionMenu()
        check("opening the faction menu closes the ruleset one",
              not rmenu:IsShown() and not rcatch:IsShown() and menu:IsShown())
        -- Leaving the tab closes it too.
        wb.Deactivate(main)
        check("leaving the tab closes the menu", not menu:IsShown() and not catcher:IsShown())
        wb.Activate(main)
        AltStableWarbandDB[ME] = { bags = { [101] = 2, [201] = 1 } }
        check("  back on the tab, Reset still shows for Normal", reset:IsShown())
        click(reset)
        eq("Reset puts the ruleset back to current from Normal", AltStableConfig.warbandRuleset, "current")
        eq("  this ruleset's items again", shownIDs(), "101,104,106,107")

        -- A saved value nobody offers reads as current, everywhere.
        AltStableConfig.warbandRuleset, AltStableConfig.warbandFaction = "bogus", "Neutral"
        wb.Refresh()
        eq("unknown saved choices filter as current", shownIDs(), "101,104,106,107")
        check("  label as current", rb.label:GetText():find("Current ruleset", 1, true) == 1
              and fb.label:GetText() == "Alliance", rb.label:GetText())
        check("  and need no reset", not reset:IsShown())
        wb.OpenRulesetMenu()
        check("  the ruleset menu highlights current", rows("ruleset").current._active)
        wb.OpenFactionMenu()
        check("  so does the faction menu", rows("faction").current._active)
        menu:GetScript("OnKeyDown")(menu, "ESCAPE")
        AltStableConfig.warbandRuleset, AltStableConfig.warbandFaction = "current", nil

        -- Personal ignores the faction, as it ignores the ruleset.
        AltStableDB[ME].faction = "Alliance"
        AltStable.SetConfigValue("warbandFaction", "Horde")
        AltStable.SetConfigValue("warbandScope", "personal"); wb.Refresh()
        eq("personal ignores the faction", shownIDs(), "101")
        eq("  its button says This character", fb.label:GetText(), "This character")
        check("  disabled, and no reset", not fb:IsEnabled() and not reset:IsShown())
        AltStable.SetConfigValue("warbandScope", "warband")
        AltStable.SetConfigValue("warbandFaction", "current")
        AltStableDB[ME].faction = nil
        wb.Refresh()

        -- Kept between sessions: a key in AltStableConfig, defaulted, never overwritten.
        local heldCfg = AltStableConfig
        AltStableConfig = {}
        AltStable.EnsureConfigDefaults()
        eq("a fresh config defaults the faction to current", AltStableConfig.warbandFaction, "current")
        AltStableConfig = { warbandFaction = "all" }
        AltStable.EnsureConfigDefaults()
        eq("  a saved choice survives the defaults", AltStableConfig.warbandFaction, "all")
        AltStableConfig = heldCfg

        for _, g in ipairs({ ALLY, HORDE, NOFAC, UNK }) do AltStableDB[g] = nil; AltStableWarbandDB[g] = nil end
        WoW.faction = heldFaction
        wb.Refresh()
    end

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
    eq("  and leaves empty slots as they were", slotAlpha, 1)
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

------------------------------------------------------------
-- Review of #154
------------------------------------------------------------
do
    local M = AltStableWarbandModel
    -- The combined window is sticky: a click on a tab already shown keeps it,
    -- and stepping past either end moves by one page.
    eq("a tab already on screen does not scroll the window", (M.CombinedWindow({ 1, 2, 3, 4 }, 2, 1)), 1)
    eq("stepping right moves one page", (M.CombinedWindow({ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 4, 1)), 2)
    eq("stepping left moves one page", (M.CombinedWindow({ 1, 2, 3, 4, 5 }, 2, 3)), 2)
    eq("  and a far jump still lands with the selection on screen", (M.CombinedWindow({ 1, 2, 3, 4, 5, 6 }, 6, 1)), 4)

    -- The rail fits the panel.
    local wb = plugin._wb
    local step = wb.RailStep(10, 430)
    check("ten rail buttons fit a short panel", step * 10 <= 430 - 70 - 34 - 12, tostring(step))
    eq("  and a tall one keeps the full size", wb.RailStep(5, 900), 48)

    -- Personal with no GUID yet shows nobody, never everybody.
    WoW.reset()
    AltStableDB = { ["Player-1-X"] = { name = "Someone", class = "MAGE", realm = "Classic Beta PvP" } }
    AltStableWarbandDB = { ["Player-1-X"] = { bags = { [101] = 1 } } }
    WoW.items = { [101] = { name = "Linen", classID = 7, quality = 1, icon = 1 } }
    AltStableConfig = { warbandScope = "personal" }
    local realGUID = UnitGUID
    UnitGUID = function() return nil end
    local main = CreateFrame("Frame")
    wb.Activate(main)
    local any = false
    for _, cell in ipairs(wb.cells) do if cell:IsShown() and cell.entry then any = true end end
    check("Personal with no GUID yet shows nobody", not any)
    UnitGUID = realGUID

    -- Hover survives a refresh that leaves the same item under the mouse...
    AltStableConfig = { warbandScope = "warband", warbandRuleset = "all" }
    AltStableWarbandDB["Player-1-X"] = { bags = { [101] = 1 } }
    wb.Refresh()
    local cell
    for _, c in ipairs(wb.cells) do if c:IsShown() and c.entry and c.entry.id == 101 then cell = c end end
    check("the linen is on screen", cell ~= nil)
    if cell then
        cell:GetScript("OnEnter")(cell)
        -- Drawn again when the cell's count changes (its "shown in this tab"
        -- line, #407 review), and only then.
        local drawn = 0
        local realSet = GameTooltip.SetHyperlink
        GameTooltip.SetHyperlink = function(self, link, ...)
            if link == "item:101" then drawn = drawn + 1 end
            return realSet(self, link, ...)
        end
        wb.Refresh()
        eq("a refresh with the same count leaves the tooltip as drawn", drawn, 0)
        AltStableWarbandDB["Player-1-X"] = { bags = { [101] = 3 } }    -- a bag update
        wb.Refresh()
        check("a refresh keeps the tooltip on the same item", wb.hoverEntry ~= nil and wb.hoverEntry.id == 101)
        eq("  with its refreshed count", wb.hoverEntry and wb.hoverEntry.total, 3)
        eq("  and draws it again, so its tab line says 3", drawn, 1)
        GameTooltip.SetHyperlink = realSet
        -- ...and drops it when the item is gone.
        AltStableWarbandDB["Player-1-X"] = { bags = { [102] = 1 } }
        WoW.items[102] = { name = "Wool", classID = 7, quality = 1, icon = 2 }
        wb.Refresh()
        eq("  and drops it once the cell holds something else", wb.hoverEntry, nil)
    end

    -- The keyboard, as CharacterMenu does it.
    local realCombat = InCombatLockdown
    InCombatLockdown = function() return true end
    wb.OpenDialog(1)
    local dlg = wb.Dialog()
    check("in combat the dialog does not take the keyboard", not dlg:IsKeyboardEnabled())
    wb.CloseDialog()
    InCombatLockdown = function() return false end
    wb.OpenDialog(1)
    check("out of combat it does", dlg:IsKeyboardEnabled())
    check("the dialog listens for combat starting", dlg:IsEventRegistered("PLAYER_REGEN_DISABLED"))
    dlg:GetScript("OnEvent")(dlg, "PLAYER_REGEN_DISABLED")
    check("combat starting with it open releases the keyboard", not dlg:IsKeyboardEnabled())
    wb.CloseDialog()
    wb.OpenDialog(1)
    local realProp = dlg.SetPropagateKeyboardInput
    dlg.SetPropagateKeyboardInput = function() error("ADDON_ACTION_BLOCKED") end
    local ok = pcall(dlg:GetScript("OnKeyDown"), dlg, "W")
    check("a blocked propagation call does not throw", ok)
    check("  and releases the keyboard, so W is not swallowed", not dlg:IsKeyboardEnabled())
    dlg.SetPropagateKeyboardInput = realProp
    wb.CloseDialog()
    InCombatLockdown = realCombat

    wb.Deactivate(main)
    WoW.reset()
end

------------------------------------------------------------
-- Codex review of #154: room on activation, and a dialog that fits its height
------------------------------------------------------------
do
    local wb = plugin._wb
    local asked
    local realMin = AltStable.EnsureWindowMinSize
    AltStable.EnsureWindowMinSize = function(w, h) asked = { w, h } end
    local main = CreateFrame("Frame")
    WoW.reset()
    AltStableDB, AltStableWarbandDB, AltStableConfig = {}, {}, {}
    wb.Activate(main)
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    check("opening the tab asks the window for its room", asked ~= nil)
    if asked then
        eq("  wide enough for the toolbar and the rail", asked[1], sidebarW + 1 + wb.MIN_PANEL_W)
        eq("  tall enough for the Configure dialog", asked[2], titleH + 1 + wb.MIN_PANEL_H)
        check("  which is at least the dialog's full height", wb.MIN_PANEL_H >= 420 + 8)
        check("  and the toolbar's width", wb.MIN_PANEL_W >= 640 + 58)
        -- And again when the window changes under the tab (#157 review):
        -- expanding the sidebar narrows the panel while the window keeps its
        -- width, so the floor is asked for from the sidebar as it is NOW.
        asked = nil
        local savedSW = AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH
        AltStable.LAYOUT = AltStable.LAYOUT or {}
        AltStable.LAYOUT.SIDEBAR_WIDTH = 56
        plugin.OnResize()
        eq("a resize asks for the floor again, from the sidebar as it is now",
           asked and asked[1], 56 + 1 + wb.MIN_PANEL_W)
        AltStable.LAYOUT.SIDEBAR_WIDTH = savedSW
    end
    AltStable.EnsureWindowMinSize = realMin

    -- Its PREFERRED size (#150), per view, asked for on opening - before the
    -- floor, so the floor can only raise it - and on switching views, once.
    do
        local calls = {}
        local realReq, realMin2, realAnim = AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize,
                                            AltStable.AnimateWindowChange
        AltStable.RequestPluginSize = function(w) calls[#calls + 1] = "pref " .. w end
        AltStable.EnsureWindowMinSize = function() calls[#calls + 1] = "floor" end
        local animated = 0
        AltStable.AnimateWindowChange = function(fn) animated = animated + 1; fn() end
        AltStableConfig.warbandView = "single"
        wb.Activate(main)
        eq("Single opens at its preferred width, then the floor",
           table.concat(calls, ","), "pref " .. wb.PREFERRED_PANEL_W.single .. ",floor")
        calls = {}
        wb.SetView("combined")
        eq("switching to Combined asks for Combined's width",
           calls[1], "pref " .. wb.PREFERRED_PANEL_W.combined)
        -- And nothing else: the layout is the animator's to place, through
        -- OnResize (#191 review) - laid out here, Combined stood past a
        -- window still growing toward it, and every bag was gathered twice.
        eq("  and leaves the layout to the animator", #calls, 1)
        eq("  through the window animation", animated, 1)
        eq("  and the view is saved", AltStableConfig.warbandView, "combined")
        calls = {}
        wb.SetView("combined")
        eq("the view it already has changes nothing", #calls, 0)
        check("Combined holds three tabs at seven icons", wb.PREFERRED_PANEL_W.combined >= 3 * 274 + 2 * 18 + 58 + 14 + 2 * 12 + 2 * 26)
        AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize, AltStable.AnimateWindowChange =
            realReq, realMin2, realAnim
        AltStableConfig.warbandView = nil
    end

    -- A display too small even for that: the dialog shows fewer icon rows,
    -- never rows past its own Save (the 333-px panel Codex measured).
    wb.OpenDialog(1)
    local dlg = wb.Dialog()
    wb.CloseDialog()
    local panel = dlg._parent
    local realH = panel.GetHeight
    panel.GetHeight = function() return 333 end
    -- A client-sized icon list, so every row has icons to (wrongly) show.
    local realIcons = GetMacroIcons
    GetMacroIcons = function() local t = {}; for i = 1, 200 do t[i] = 100000 + i end; return t end
    wb.ResetIconList()
    wb.OpenDialog(1)
    eq("the dialog uses the rows its height allows", dlg.visRows, wb.DialogIconRows(325))
    local h = dlg:GetHeight()
    eq("the dialog fits the short panel", h, 325)
    local rows = wb.DialogIconRows(h)
    check("  with fewer icon rows", rows < 4, tostring(rows))
    check("  every shown row ends above the buttons", 224 + (rows - 1) * 38 + 34 <= h - 46)
    local beyond = false
    for i = rows * 10 + 1, 40 do
        local c = dlg.iconCells[i]
        if c and c:IsShown() then beyond = true end
    end
    check("  and no icon is drawn below them", not beyond)
    eq("a full-height dialog keeps all four rows", wb.DialogIconRows(420), 4)
    wb.CloseDialog()
    GetMacroIcons = realIcons
    wb.ResetIconList()
    panel.GetHeight = realH
    wb.Deactivate(main)
    WoW.reset()
end

------------------------------------------------------------
-- #419: the bank is read at the end of the batch that changed it, and inside
-- the close; never after. Driven through the plugin's real event frame.
------------------------------------------------------------
do
    WoW.reset()
    -- The kit's reset discards every frame; the plugin's event frame goes back
    -- in, with the events it registered, so WoW.fire reaches it as in game.
    local ef = T.EventFrame()
    local present = false
    for _, w in ipairs(WoW.frames) do if w == ef then present = true end end
    if not present then table.insert(WoW.frames, ef) end
    local function fresh(bank, bags)
        WoW.flushTimers()                            -- no timer left over from the scenario before
        WoW.bankTabs, WoW.accountTabs, WoW.bankBags = { 6 }, {}, {}
        WoW.containers = { [0] = { size = 3 }, [6] = { size = 3 } }
        for i, v in ipairs(bank or {}) do WoW.containers[6][i] = slot(v[1], v[2]) end
        for i, v in ipairs(bags or {}) do WoW.containers[0][i] = slot(v[1], v[2]) end
        AltStableWarbandDB = {}
        T.NewSession()
    end
    local ME = UnitGUID("player")                       -- the reset's player, not the file's GUID
    local function mine() return AltStableWarbandDB[ME] or {} end
    local function bankOf(id) return (mine().bank or {})[id] or 0 end
    local function bagsOf(id) return (mine().bags or {})[id] or 0 end
    local function withdraw(fromBank, toBags)
        WoW.containers[6][1] = fromBank > 0 and slot(2318, fromBank) or nil
        WoW.containers[0][1] = toBags > 0 and slot(2318, toBags) or nil
    end

    -- A withdrawal, then Escape: the batch's end reads both sides at once.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    eq("#419: the open reads the bank", bankOf(2318), 20)
    withdraw(5, 15)
    WoW.fire("BAG_UPDATE", 6); WoW.fire("BAG_UPDATE", 0); WoW.fire("BAG_UPDATE_DELAYED")
    eq("  the batch's end reads the bank, before any close or timer", bankOf(2318), 5)
    eq("  and the bags with it", bagsOf(2318), 15)
    WoW.fire("BANKFRAME_CLOSED"); WoW.flushTimers()
    eq("  the total stays 20 after the close", bankOf(2318) + bagsOf(2318), 20)

    -- A deposit: the same.
    fresh({ { 2318, 5 } }, { { 2318, 15 } })
    WoW.fire("BANKFRAME_OPENED")
    withdraw(20, 0)
    WoW.fire("BAG_UPDATE", 6); WoW.fire("BAG_UPDATE", 0); WoW.fire("BAG_UPDATE_DELAYED")
    eq("a deposit: the bank at the batch's end", bankOf(2318), 20)
    eq("  the bags too", bagsOf(2318), 0)
    WoW.fire("BANKFRAME_CLOSED")

    -- PLAYERBANKSLOTS_CHANGED alone marks the bank changed.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    withdraw(7, 13)
    WoW.fire("PLAYERBANKSLOTS_CHANGED", 1); WoW.fire("BAG_UPDATE_DELAYED")
    eq("PLAYERBANKSLOTS_CHANGED alone: the batch's end reads the bank", bankOf(2318), 7)
    WoW.fire("BANKFRAME_CLOSED")

    -- The carried update in the NEXT batch: the close reads the bags.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    WoW.containers[6][1] = slot(2318, 5)
    WoW.fire("BAG_UPDATE", 6); WoW.fire("BAG_UPDATE_DELAYED")
    WoW.containers[0][1] = slot(2318, 15)            -- the bags' own update hasn't come yet
    WoW.fire("BANKFRAME_CLOSED")
    eq("the carried side arriving later is read inside the close", bagsOf(2318), 15)

    -- A close with no batch end first: the close read takes the move.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    withdraw(5, 15)
    WoW.fire("BAG_UPDATE", 6)
    WoW.fire("BANKFRAME_CLOSED")
    eq("a close before the batch's end: the close reads the bank", bankOf(2318), 5)
    eq("  and the bags", bagsOf(2318), 15)

    -- A batch's end while the bank isn't loaded keeps it marked; the next
    -- batch's end, with no new change, reads it.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    WoW.fire("BAG_UPDATE", 6)
    WoW.containers[6].size = 0                       -- the main bank not loaded
    WoW.fire("BAG_UPDATE_DELAYED")
    check("an unloaded bank at the batch's end stays marked", T.IsBankDirty())
    WoW.containers[6].size = 3; WoW.containers[6][1] = slot(2318, 9)
    WoW.fire("BAG_UPDATE_DELAYED")
    eq("  the next batch's end reads it", bankOf(2318), 9)
    check("  and clears the mark", not T.IsBankDirty())
    WoW.fire("BANKFRAME_CLOSED")

    -- The tab list failing at the open is retried by the next batch's end, with
    -- no change event between; the confirming stamp moves once.
    fresh({ { 2318, 20 } })
    WoW.bankTabs = "not a list"
    WoW.fire("BANKFRAME_OPENED")
    eq("a failed tab list at the open reads nothing", mine().bank, nil)
    WoW.bankTabs = { 6 }
    WoW.now = WoW.now + 5
    WoW.fire("BAG_UPDATE_DELAYED")
    eq("  the next batch's end reads it", bankOf(2318), 20)
    eq("  confirmed once, at that read", mine().bankStamp, WoW.now)
    local confirmed = WoW.now
    WoW.now = WoW.now + 5
    WoW.fire("BAG_UPDATE", 6); WoW.fire("BAG_UPDATE_DELAYED"); WoW.flushTimers()
    eq("  an unchanged later read doesn't move it", mine().bankStamp, confirmed)
    WoW.fire("BANKFRAME_CLOSED")

    -- A batch's end with the bank closed, or nothing changed: no bank read.
    do
        local reads, real = 0, AltStable.API.GetContainerNumSlots
        AltStable.API.GetContainerNumSlots = function(b) if b == 6 then reads = reads + 1 end return real(b) end
        WoW.fire("BAG_UPDATE_DELAYED")
        eq("a batch's end with the bank closed reads no bank", reads, 0)
        fresh({ { 2318, 20 } })
        WoW.fire("BANKFRAME_OPENED")
        reads = 0
        WoW.fire("BAG_UPDATE", 0); WoW.fire("BAG_UPDATE_DELAYED")
        eq("  nor with only the bags changed", reads, 0)
        WoW.fire("BANKFRAME_CLOSED")
        AltStable.API.GetContainerNumSlots = real
    end

    -- The backpack not loaded at the close: the bags and their stamp stay, the
    -- bank is recorded, and the 1 s bag timer repairs the bags afterwards.
    fresh({ { 2318, 20 } }, { { 2318, 1 } })
    T.ScanBags()                                     -- the bags as last read
    WoW.fire("BANKFRAME_OPENED")
    local bagsStamp = mine().bagsStamp
    eq("  (the bags read before the visit)", bagsOf(2318), 1)
    WoW.now = WoW.now + 5
    withdraw(5, 16)
    WoW.containers[0].size = 0
    WoW.fire("BANKFRAME_CLOSED")
    eq("an unloaded backpack at the close: the bags stay", bagsOf(2318), 1)
    eq("  with their stamp", mine().bagsStamp, bagsStamp)
    eq("  the bank is recorded", bankOf(2318), 5)
    WoW.containers[0].size = 3; WoW.containers[0][1] = slot(2318, 15)
    WoW.flushTimers()
    eq("  and the bag timer repairs the bags, no bank needed", bagsOf(2318), 15)

    -- A bag slot holding a bag at 0 slots is not loaded either; an empty one is nothing.
    fresh({ { 2318, 20 } }, { { 2318, 1 } })
    WoW.containers[1] = { size = 0 }
    WoW.equipped[31] = "|Hitem:4500|h"                 -- a bag in carried slot 1
    check("a bag slot holding a bag at 0 slots: the bags aren't read", (function()
        T.ScanBags(); return mine().bags == nil end)())
    WoW.equipped[31] = nil
    T.ScanBags()
    eq("  an empty bag slot at 0 is nothing: the bags read", bagsOf(2318), 1)

    -- #439: a purchased bank bag slot with no bag (container 7, slot 2) is
    -- nothing; with a bag at 0 slots it isn't loaded.
    fresh({ { 2318, 20 } })
    WoW.bankTabs = { 6, 7 }; WoW.containers[7] = { size = 0 }
    WoW.fire("BANKFRAME_OPENED")
    eq("#439: an empty purchased bag slot doesn't stop the bank read", bankOf(2318), 20)
    WoW.fire("BANKFRAME_CLOSED")
    fresh({ { 2318, 20 } })
    WoW.bankTabs = { 6, 7 }; WoW.containers[7] = { size = 0 }; WoW.bankBags = { [2] = true }
    WoW.fire("BANKFRAME_OPENED")
    eq("  a bag in it at 0 slots: not loaded, nothing recorded", mine().bank, nil)
    WoW.fire("BANKFRAME_CLOSED")

    -- A peer gets both sides, each by its own stamp.
    fresh({ { 2318, 20 } })
    WoW.fire("BANKFRAME_OPENED")
    withdraw(5, 15)
    WoW.fire("BAG_UPDATE", 6); WoW.fire("BAG_UPDATE", 0); WoW.fire("BAG_UPDATE_DELAYED")
    WoW.fire("BANKFRAME_CLOSED")
    local blob = T.SerializePlayer(ME)
    T.DeserializePlayer("Player-Peer-419", blob)
    local peer = AltStableWarbandDB["Player-Peer-419"]
    eq("a peer gets the bank after the move", peer and peer.bank[2318], 5)
    eq("  and the bags", peer and peer.bags[2318], 15)
    WoW.reset()
end

WoW.finish("test_warband", passed, failed)
