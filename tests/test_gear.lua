------------------------------------------------------------
-- test_gear.lua - the public gear read API (#281, AS-003)
--
-- What Glass Gear is promised in docs/PUBLIC-API.md:
--   * an item string per slot that keeps the random suffix - on Forever a
--     BONUS ID, measured on 205 stored links: the classic suffix field is
--     always empty - with the enchant and gems, and without the scanning
--     character's level and spec;
--   * per slot "occupied" / "empty" / "unknown", where a record that cannot
--     say which item is worn is unknown, never a wrong item;
--   * a gear-change stamp apart from lastUpdate, and "GearChanged" with the
--     GUIDs, for our own scan and for a sync that lands.
-- The links below are copied from those stored links.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Config.lua")
AltStable.RefreshSheet = function() end
dofile("PublicAPI.lua")

local T = AltStable._test
local G = AltStable._testScanner.GearItemString

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1 else
        failed = failed + 1
        print("  FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end
local function eq(name, got, want) check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want))) end

local function flush()
    for _ = 1, 20 do
        if #WoW.timers == 0 then break end
        WoW.flushTimers()
    end
end

local function link(body, name) return "|cff1eff00|Hitem:" .. body .. "|h[" .. (name or "X") .. "]|h|r" end

------------------------------------------------------------
-- The item string
------------------------------------------------------------
eq("a random suffix (a bonus ID) is kept; the level and spec are blanked",
   G(link("14094::::::::10:1482:::1:12745::::::", "Beaded Wraps of the Sorcerer")),
   "item:14094::::::::::::1:12745")
eq("context, a bonus and a modifier are kept",
   G(link("15304::::::::16:1485::1:1:12728:1:28:5244:::::", "Grizzly Jerkin of Agility")),
   "item:15304:::::::::::1:1:12728:1:28:5244")
eq("a modifier with no bonus",
   G(link("1156::::::::18:1490::1::1:28:5240:::::", "Lavishly Jeweled Ring")),
   "item:1156:::::::::::1::1:28:5240")
eq("a crafter's GUID is dropped",
   G(link("11287::::::::10:1487::::::::Player-4619-00DF0AC2:", "Lesser Magic Wand")), "item:11287")
eq("an enchant is kept", G(link("2302:15:::::::16:1485::::::::Player-4618-01580781:")), "item:2302:15")
eq("a plain item is just its id", G(link("288919::::::::16:1485:::::::::")), "item:288919")
eq("the context alone is kept", G(link("139::::::::1:1486::75:::::::")), "item:139:::::::::::75")
eq("gems are kept", G(link("100:5:7:8:9::::20:1482")), "item:100:5:7:8:9")
eq("the same item at another level and spec is the same string",
   G(link("14094::::::::18:1490:::1:12745::::::")), G(link("14094::::::::10:1482:::1:12745::::::")))
check("another suffix is another string",
      G(link("14094::::::::10:1482:::1:12746")) ~= G(link("14094::::::::10:1482:::1:12745")))
eq("a bare item string works too", G("item:288919::::::::16:1485"), "item:288919")
eq("a bonus count past the fields there are: what is there",
   G(link("5:::::::::::::4:1:2")), "item:5:::::::::::::4:1:2")
eq("not an item link: nil", G("|Hspell:133|h[Fireball]|h"), nil)
eq("no number for the id: nil", G("item:abc:1"), nil)
eq("not a string: nil", G(nil), nil)

------------------------------------------------------------
-- Our own scan
------------------------------------------------------------
local events = {}
local function onGear(e, guids) events[#events + 1] = guids end
AltStable.RegisterCallback("GearChanged", onGear)

WoW.reset()
AltStableDB = {}
AltStableConfig = {}
WoW.items[14094] = { name = "Beaded Wraps of the Sorcerer", quality = 2, ilvl = 14, itemType = "Armor", subType = "Cloth" }
WoW.items[2302]  = { name = "Handstitched Leather Boots", quality = 1, ilvl = 8, itemType = "Armor", subType = "Leather" }
WoW.equipped[9] = link("14094::::::::10:1482:::1:12745::::::", "Beaded Wraps of the Sorcerer")
WoW.equipped[8] = link("2302:15:::::::16:1485::::::::Player-4618-01580781:", "Handstitched Leather Boots")
local ME = UnitGUID("player")
WoW.now = 1000
AltStable.ScanCharacter()
flush()
local me = AltStableDB[ME]
eq("the scan stores the wrist's item string", me.gearstr_wrist, "item:14094::::::::::::1:12745")
eq("  and the boots'", me.gearstr_feet, "item:2302:15")
eq("  an empty slot stores none (gearid_ 0 says it is empty)", me.gearstr_head, nil)
eq("the first scan stamps gearAt", me.gearAt, 1000)
eq("  and says so", #events, 1)
eq("  for our GUID", events[1] and events[1][1], ME)

events = {}
WoW.now = 2000
AltStable.ScanCharacter()
flush()
eq("the same gear again: no GearChanged", #events, 0)
eq("  and gearAt stays", AltStableDB[ME].gearAt, 1000)

-- A level up: every link changes its level field, and nothing else.
WoW.equipped[9] = link("14094::::::::11:1482:::1:12745::::::", "Beaded Wraps of the Sorcerer")
WoW.now = 3000
AltStable.ScanCharacter()
flush()
eq("a level up alone is not a gear change", #events, 0)

-- The same base item with another suffix.
WoW.equipped[9] = link("14094::::::::11:1482:::1:12746::::::", "Beaded Wraps of the Owl")
WoW.now = 4000
AltStable.ScanCharacter()
flush()
eq("another suffix of the same item is a change", #events, 1)
eq("  stamped", AltStableDB[ME].gearAt, 4000)

-- A record scanned before #281: its links are there, no gearAt yet. The
-- first scan stamps it even with nothing changed - "changed" once is the
-- safe way to be wrong - and says so.
events = {}
AltStableDB[ME].gearAt = nil
WoW.now = 4500
AltStable.ScanCharacter()
flush()
eq("the first scan after the update stamps gearAt with nothing changed", AltStableDB[ME].gearAt, 4500)
eq("  and says so", #events, 1)
WoW.now = 4000

-- An uncached item: the string comes from the link, so it is exact anyway.
events = {}
WoW.items[14094] = nil
AltStable.ScanCharacter()
eq("an uncached item still has its exact string", AltStableDB[ME].gearstr_wrist, "item:14094::::::::::::1:12746")
WoW.items[14094] = { name = "Beaded Wraps of the Owl", quality = 2, ilvl = 14, itemType = "Armor", subType = "Cloth" }

-- Taking an item off.
events = {}
WoW.equipped[8] = nil
WoW.now = 5000
AltStable.ScanCharacter()
flush()
eq("an item taken off is a change", #events, 1)
eq("  its string cleared", AltStableDB[ME].gearstr_feet, nil)

------------------------------------------------------------
-- The wire
------------------------------------------------------------
local wire = T.SerializeChar(AltStableDB[ME])
check("the item string is sent", wire:find("gearstr_wrist:item:14094::::::::::::1:12746", 1, true) ~= nil)
check("  and gearAt", wire:find("\ngearAt:5000", 1, true) ~= nil or wire:find("^gearAt:5000") ~= nil)
check("  the link still is not", not wire:find("gearlink_", 1, true))
check("  and nothing for an empty slot", not wire:find("gearstr_head", 1, true))
local back = T.DeserializeChar(wire)
eq("it comes back a string, not a number", back.gearstr_wrist, "item:14094::::::::::::1:12746")
eq("  gearAt a number", back.gearAt, 5000)

-- A peer's record lands.
local OTHER = "Player-9-ALT"
local function peerRecord(fields)
    local lines = { "guid:" .. OTHER, "name:Alt", "class:MAGE", "level:20" }
    for _, l in ipairs(fields) do lines[#lines + 1] = l end
    lines[#lines + 1] = T.CHAR_SEP
    return table.concat(lines, "\n") .. "\n==NOW==:9000"
end
events = {}
T.DeserializeFullDB(peerRecord({ "lastUpdate:6000", "gearAt:5500", "gearid_wrist:14094",
    "gearmod_wrist:0:0:0:0:0", "gear_wrist:14", "gearstr_wrist:item:14094::::::::::::1:12745",
    "gearid_head:0" }), "Peer Person")
flush()
eq("a peer's record with new gear: GearChanged", #events, 1)
eq("  for that character", events[1] and events[1][1], OTHER)

local g = AltStable.GetCharacterGear(OTHER)
eq("a remote slot is occupied", g.slots[9].state, "occupied")
eq("  with its suffix", g.slots[9].itemString, "item:14094::::::::::::1:12745")
eq("  its item id", g.slots[9].itemID, 14094)
eq("  its item level", g.slots[9].itemLevel, 14)
eq("an empty remote slot is empty", g.slots[1].state, "empty")
eq("a slot the record does not have is unknown", g.slots[5].state, "unknown")
eq("capturedAt is the record's stamp", g.capturedAt, 6000)
eq("gearAt is the owner's", g.gearAt, 5500)
eq("provenance comes with it", g.provenance, "third-party")

events = {}
T.DeserializeFullDB(peerRecord({ "lastUpdate:6100", "gearAt:5500", "gearid_wrist:14094",
    "gearmod_wrist:0:0:0:0:0", "gear_wrist:14", "gearstr_wrist:item:14094::::::::::::1:12745",
    "gearid_head:0" }), "Peer Person")
flush()
eq("a newer record with the same gear: no GearChanged", #events, 0)

-- An older AltStable's record: no strings, no gearAt. The merge clears ours.
events = {}
T.DeserializeFullDB(peerRecord({ "lastUpdate:7000", "gearid_wrist:14094", "gearmod_wrist:0:0:0:0:0",
    "gear_wrist:14", "gearid_head:0" }), "Peer Person")
flush()
g = AltStable.GetCharacterGear(OTHER)
eq("an older peer's record: the suffix slot is unknown", g.slots[9].state, "unknown")
eq("  never the old string", g.slots[9].itemString, nil)
eq("  the item id is still given, as a hint", g.slots[9].itemID, 14094)
eq("  its gearAt cleared", g.gearAt, nil)
eq("  and the empty slot is still empty", g.slots[1].state, "empty")
eq("  that is a change (the string went away)", #events, 1)

-- The single-record path reports too.
events = {}
local c = T.DeserializeChar(table.concat({ "guid:" .. OTHER, "name:Alt", "class:MAGE", "lastUpdate:8000",
    "gearid_wrist:14094", "gearmod_wrist:0:0:0:0:0", "gearstr_wrist:item:14094::::::::::::1:12746" }, "\n"))
T.ReceiveCharacter(c, "Peer Person")
flush()
eq("ReceiveCharacter: GearChanged", #events, 1)

------------------------------------------------------------
-- A string that disagrees with its record: unknown
------------------------------------------------------------
local function slotWith(fields)
    AltStableDB["Player-9-X"] = { guid = "Player-9-X", name = "X" }
    for k, v in pairs(fields) do AltStableDB["Player-9-X"][k] = v end
    return AltStable.GetCharacterGear("Player-9-X").slots[9]
end
eq("another item id in the string: unknown",
   slotWith({ gearid_wrist = 14095, gearstr_wrist = "item:14094::::::::::::1:12745" }).state, "unknown")
eq("another enchant: unknown",
   slotWith({ gearid_wrist = 14094, gearmod_wrist = "41:0:0:0:0", gearstr_wrist = "item:14094" }).state, "unknown")
eq("another gem: unknown",
   slotWith({ gearid_wrist = 14094, gearmod_wrist = "0:1:7:0:0", gearstr_wrist = "item:14094" }).state, "unknown")
eq("the same enchant and gems: occupied",
   slotWith({ gearid_wrist = 14094, gearmod_wrist = "41:?:7:0:0", gearstr_wrist = "item:14094:41:7" }).state, "occupied")
eq("no gearmod to compare: the id decides",
   slotWith({ gearid_wrist = 14094, gearstr_wrist = "item:14094" }).state, "occupied")
eq("an item level of 0 (uncached) is nil",
   slotWith({ gearid_wrist = 14094, gear_wrist = 0, gearstr_wrist = "item:14094" }).itemLevel, nil)

-- Our own scan from before #281: no string yet, but its link is there.
AltStableDB["Player-1-OLD"] = { guid = "Player-1-OLD", name = "Old", scannedHere = true,
    gearid_wrist = 14094, gearlink_wrist = link("14094::::::::10:1482:::1:12745::::::") }
eq("our own pre-#281 record reads its string from the link",
   AltStable.GetCharacterGear("Player-1-OLD").slots[9].itemString, "item:14094::::::::::::1:12745")
-- A peer's record never has a link (local-only), and is not read from one.
AltStableDB["Player-9-LNK"] = { guid = "Player-9-LNK", name = "Lnk",
    gearid_wrist = 14094, gearlink_wrist = link("14094::::::::10:1482:::1:12745::::::") }
eq("  a peer's record is never read from a link", AltStable.GetCharacterGear("Player-9-LNK").slots[9].state, "unknown")

------------------------------------------------------------
-- The getter's contract
------------------------------------------------------------
eq("no record: nil", AltStable.GetCharacterGear("Player-404"), nil)
eq("not a string: nil", AltStable.GetCharacterGear(5), nil)
g = AltStable.GetCharacterGear(ME)
local n = 0
for slotID, s in pairs(g.slots) do
    n = n + 1
    eq("slot " .. slotID .. " carries its own id", s.slot, slotID)
end
eq("seventeen slots, by inventory slot id", n, 17)
eq("the shirt and tabard are not gear slots", g.slots[4], nil)
g.slots[9].itemString = "changed"
eq("a copy: changing it changes nothing", AltStable.GetCharacterGear(ME).slots[9].itemString,
   "item:14094::::::::::::1:12746")
eq("the feature flag says it is there", AltStable.PUBLIC_API_FEATURES.gear, true)

-- Nobody listening: nothing gathered, so the next listener hears only its own news.
AltStable.UnregisterCallback("GearChanged", onGear)
WoW.equipped[8] = link("2302:15", "Handstitched Leather Boots")
AltStable.ScanCharacter()                                   -- our gear changes, unheard
flush()
events = {}
AltStable.RegisterCallback("GearChanged", onGear)
T.DeserializeFullDB(peerRecord({ "lastUpdate:9000", "gearid_wrist:2302", "gearstr_wrist:item:2302" }), "Peer Person")
flush()
eq("a listener registered later hears one change", #events, 1)
eq("  only that character, not what changed while nobody listened",
   events[1] and table.concat(events[1], ","), OTHER)

-- Each listener gets its own list.
local seenA, seenB
AltStable.RegisterCallback("GearChanged", function(_, l) seenA = l; l[1] = "changed" end)
AltStable.RegisterCallback("GearChanged", function(_, l) seenB = l end)
T.DeserializeFullDB(peerRecord({ "lastUpdate:9100", "gearid_wrist:2302", "gearstr_wrist:item:2302:15" }), "Peer Person")
flush()
check("each listener has its own list", seenA ~= nil and seenB ~= nil and seenA ~= seenB)
eq("  one changing its list changes nobody else's", seenB and seenB[1], OTHER)

print(("test_gear: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
