------------------------------------------------------------
-- test_professions.lua - the Professions plugin (#14)
--
-- The stubs model what 1.60.1.70124 measured: C_TradeSkillUI answers for the
-- LAST profession shown, also after its window closed, so a scan that reads
-- after TRADE_SKILL_CLOSE files the wrong list - and nothing here would notice
-- unless the stub kept answering. GetAllProfessionTradeSkillLines lists every
-- line; ownership is GetProfessions, which returns seven values. A ready
-- cooldown comes back nil, and a spell the client lacks has no name.
--
-- The sync cases go through Core's real SerializeFullDB / DeserializeFullDB /
-- ReceiveCharacter, not the plugin's helpers alone: the AltTracker plugin's two
-- sync bugs (a watermark reset on every login, and recipes lost after one relay
-- hop) lived in how the plugin met the core, which helper-level tests bypass -
-- and so did the colon in a cooldown key that cut Core's key:value lines.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

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
-- The grid's columns: the plugin takes its labels and skill fields from them.
dofile("Reputations.lua")
dofile("Columns.lua")
local Core = AltStable._test

-- A small, fixed catalogue instead of the generated file, so the numbers here
-- do not move when Wowhead does. Shapes as RecipeData.lua writes them.
AltStableRecipeData = { source = "test", recipes = {
    [2329] = { skill = { 171 }, learn = 1,   colors = { 1, 55, 75, 95 }, makes = 2454, src = { 6 } },
    [2330] = { skill = { 171 }, learn = 15,  colors = { 15, 60, 80, 100 }, makes = 118, src = { 6 } },
    [2331] = { skill = { 171 }, learn = 50,  colors = { 50, 80, 100, 120 }, makes = 2455, src = { 2 } },
    [2332] = { skill = { 171 }, learn = 125, colors = { 125, 150, 170, 190 }, makes = 2456, src = { 5, 6 } },
    [2333] = { skill = { 171 } },                                -- requirement unknown (9999 on Wowhead)
    [3100] = { skill = { 164 }, learn = 1,   makes = 2862, src = { 6 } },
    [3101] = { skill = { 164 }, learn = 30,  makes = 2863 },     -- source unknown
    [7000] = { skill = { 165, 197 }, learn = 40, makes = 5000, src = { 4 } },
} }

AltStable.plugins = {}
dofile("Plugins/Professions/AltStableProfessions.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "professions" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_professions: %d passed, %d failed"):format(passed, failed + 1)); os.exit(1)
end
local T = plugin._test
local AT = plugin._at

local listed = false
for _, p in ipairs(AltStable.LOD_PLUGINS) do if p.key == "professions" and p.addon == "AltStableProfessions" then listed = true end end
check("the core lists it among the load-on-demand plugins", listed)

-- Every profession is tied to a grid column: its label is the cd_ prefix the
-- grid tooltip reads, and its field is the skill the unscanned alts show with.
for _, p in ipairs(T.PROFESSIONS) do
    check(p.label .. " has a grid column to take its skill field from", p.field ~= nil)
end

local ME = WoW.player.guid
local function fresh()
    WoW.reset()
    WoW.now = 1700000000
    AltStableDB = { [ME] = { guid = ME, name = "Me", class = "MAGE", level = 60, lastUpdate = 1, scannedHere = true } }
    AltStableProfessionsDB = {}
    T.ResetState()
    T.scan.open, T.scan.gen, T.scan.retries = false, T.scan.gen + 1, 0
    for k in pairs(T.names) do T.names[k] = nil end
    for k in pairs(T.requested) do T.requested[k] = nil end
end
local function setAlchemy(recipes, rank)
    WoW.professions = { { name = "Alchemy", rank = rank or 60, max = 75, line = 171 } }
    WoW.tradeSkill.line, WoW.tradeSkill.rank, WoW.tradeSkill.max = 171, rank or 60, 75
    WoW.tradeSkill.recipes = recipes
end
local function count(set) local n = 0 for _ in pairs(set or {}) do n = n + 1 end return n end

------------------------------------------------------------
-- Ownership: GetProfessions, not the everything-list
------------------------------------------------------------

fresh()
WoW.professions = { { name = "Alchemy", rank = 60, max = 75, line = 171 } }
T.RefreshOwnership()
local e = AltStableProfessionsDB[ME]
check("an owned profession gets an entry", e and e.profs[171] ~= nil)
eq("  with its skill", e and e.profs[171] and e.profs[171].rank, 60)
eq("  and nothing claimed about its recipes yet", e and e.profs[171] and e.profs[171].full, nil)
check("the every-line list is NOT ownership (no Blacksmithing entry)", e and e.profs[164] == nil)
eq("an owner whose window was never opened reads as unscanned", T.Owners(171)[1] and T.Owners(171)[1].state, "unscanned")
check("the first read stamps a snapshot", e and e.stamp ~= nil)

-- All seven returns are read: a profession in the seventh slot is still seen.
fresh()
WoW.professions = { false, false, false, false, false, false, { name = "Cooking", rank = 10, max = 75, line = 185 } }
T.RefreshOwnership()
check("a profession in GetProfessions' seventh return is seen",
      AltStableProfessionsDB[ME] and AltStableProfessionsDB[ME].profs[185] ~= nil)

-- Losing one: two reads in the same second do not confirm it (login can land
-- the timer and the SKILL_LINES_CHANGED debounce together); a read LOSS_CONFIRM
-- seconds later that agrees does.
fresh()
WoW.professions = { { name = "Alchemy", rank = 60, max = 75, line = 171 }, { name = "Cooking", rank = 20, max = 75, line = 185 } }
T.RefreshOwnership()
AltStableProfessionsDB[ME].profs[171].known = { [2329] = true }
AltStableProfessionsDB[ME].profs[171].full = 1
AltStableDB[ME]["cd_Alchemy@Transmute"] = WoW.now + 3600
WoW.professions = {}
T.RefreshOwnership()
T.RefreshOwnership()
check("two empty answers in the same second prune nothing", AltStableProfessionsDB[ME].profs[171] ~= nil)
WoW.now = WoW.now + 6
T.RefreshOwnership()
check("an empty answer confirmed seconds later prunes", AltStableProfessionsDB[ME].profs[171] == nil)
eq("  and takes the cooldowns with it", AltStableDB[ME]["cd_Alchemy@Transmute"], nil)
check("  leaving an explicit 'has none' snapshot", next(AltStableProfessionsDB[ME].profs) == nil)

-- A PARTIAL answer (one line missing) is held back the same way.
fresh()
WoW.professions = { { name = "Alchemy", rank = 60, max = 75, line = 171 }, { name = "Cooking", rank = 20, max = 75, line = 185 } }
T.RefreshOwnership()
WoW.professions = { { name = "Cooking", rank = 20, max = 75, line = 185 } }
T.RefreshOwnership()
check("a line missing from one answer is not pruned at once", AltStableProfessionsDB[ME].profs[171] ~= nil)
WoW.professions = { { name = "Alchemy", rank = 60, max = 75, line = 171 }, { name = "Cooking", rank = 20, max = 75, line = 185 } }
WoW.now = WoW.now + 6
T.RefreshOwnership()
check("  and survives when the next answer has it again", AltStableProfessionsDB[ME].profs[171] ~= nil)

------------------------------------------------------------
-- The scan: bounded by SHOW ... CLOSE
------------------------------------------------------------

fresh()
setAlchemy({ [2329] = { name = "Elixir of Minor Strength", learned = true },
             [2330] = { name = "Minor Healing Potion", learned = true, cooldown = 7200 },
             [2331] = { name = "Elixir of Lesser Agility", learned = false } })
T.OnShow()
WoW.flushTimers()
e = AltStableProfessionsDB[ME]
check("an open window is scanned", e and e.profs[171] ~= nil)
eq("  learned recipes are recorded", e and count(e.profs[171].known), 2)
check("  unlearned ones are not", e and not e.profs[171].known[2331])
check("  and the list is marked complete", e and e.profs[171].full ~= nil)
eq("  skill comes from the open window", e and e.profs[171].rank, 60)
eq("the character is touched so it syncs", AltStableDB[ME].lastUpdate, WoW.now)
eq("a cooldown lands on the core record as cd_<Profession>@<label>",
   AltStableDB[ME]["cd_Alchemy@Minor Healing Potion"], WoW.now + 7200)

-- A window showing a profession this character does not have.
fresh()
setAlchemy({ [2329] = { name = "A", learned = false } })
WoW.professions = {}
T.OnShow()
WoW.flushTimers()
check("a profession the character does not own is never filed as a scan",
      AltStableProfessionsDB[ME] == nil or AltStableProfessionsDB[ME].profs[171] == nil)

-- Closing before the delayed scan runs: the client still answers for Alchemy,
-- but whatever it says now is not a window we are looking at.
fresh()
setAlchemy({ [2329] = { name = "A", learned = true } })
T.OnShow()
T.OnClose()
WoW.flushTimers()
check("a scan scheduled before CLOSE does not run after it", AltStableProfessionsDB[ME] == nil
      or AltStableProfessionsDB[ME].profs[171] == nil)
local _, why = T.Candidate()
eq("  and a candidate read with the window shut is refused", why, "closed")

fresh()
setAlchemy({ [2329] = { name = "A", learned = true } })
T.OnShow()
T.OnChanging()
WoW.flushTimers()
check("a source change cancels the pending scan", AltStableProfessionsDB[ME] == nil
      or AltStableProfessionsDB[ME].profs[171] == nil)

-- A recipe whose info does not come back abandons the whole candidate.
fresh()
AltStableProfessionsDB[ME] = { stamp = 5, profs = { [171] = { rank = 60, max = 75, full = 4, known = { [2329] = true, [2330] = true } } } }
setAlchemy({ [2329] = { name = "A", learned = true }, [2330] = { name = "B", learned = true },
             [2331] = { name = "C", learned = false } })
WoW.tradeSkill.nilInfo[2330] = true
T.OnShow()
for _ = 1, 6 do WoW.flushTimers() end
check("an incomplete read leaves the stored list untouched",
      AltStableProfessionsDB[ME].profs[171].known[2330] == true)
eq("  and the stamp does not move", AltStableProfessionsDB[ME].stamp, 5)
eq("  it retries a bounded number of times", T.scan.retries, 3)

fresh()
setAlchemy({ [2329] = { name = "A", learned = true } })
WoW.tradeSkill.linked = true
T.OnShow()
WoW.flushTimers()
check("a linked profession is not scanned", AltStableProfessionsDB[ME] == nil
      or AltStableProfessionsDB[ME].profs[171] == nil)

fresh()
setAlchemy({ [2329] = { name = "A", learned = true } })
T.OnShow(); WoW.flushTimers()
local s1 = AltStableProfessionsDB[ME].stamp
WoW.now = WoW.now + 100
T.OnShow(); WoW.flushTimers()
eq("an unchanged rescan keeps the stamp", AltStableProfessionsDB[ME].stamp, s1)
eq("  but records that it verified again", AltStableProfessionsDB[ME].profs[171].full, WoW.now)

------------------------------------------------------------
-- NEW_RECIPE_LEARNED: a positive fact, not a complete list
------------------------------------------------------------

fresh()
-- 8800001 is in no data file: only the client can place it, and the client
-- names the CHILD line (2938), with Blacksmithing (164) as its parent.
WoW.recipeLines = { [8800001] = 164 }
T.OnRecipeLearned(8800001)
e = AltStableProfessionsDB[ME]
check("a recipe learned with the window shut is recorded", e and e.profs[164] and e.profs[164].known[8800001])
check("  resolved through the PARENT line (the client names the child)", e and e.profs[2938] == nil)
eq("  and the profession is partial, not complete", e and e.profs[164] and e.profs[164].full, nil)
eq("  which the read model calls partial", T.Owners(164)[1] and T.Owners(164)[1].state, "partial")
T.OnRecipeLearned(3101)
check("the data places a recipe the client does not", e.profs[164].known[3101])
T.OnRecipeLearned(999999)
check("an unresolvable recipe is not filed anywhere", e.profs[999999] == nil)

------------------------------------------------------------
-- Stamps: strictly increasing per character
------------------------------------------------------------

fresh()
setAlchemy({ [2329] = { name = "A", learned = true } })
T.OnShow(); WoW.flushTimers()
local first = AltStableProfessionsDB[ME].stamp
T.OnRecipeLearned(2330)   -- same second
check("two changes in one second get two stamps", AltStableProfessionsDB[ME].stamp > first,
      tostring(AltStableProfessionsDB[ME].stamp) .. " vs " .. tostring(first))

------------------------------------------------------------
-- Cooldowns: labels, grouping, readiness
------------------------------------------------------------

eq("a transmute files under 'Transmute'", T.CooldownLabel("Transmute: Arcanite"), "Transmute")
eq("a plain name files under itself", T.CooldownLabel("Mooncloth"), "Mooncloth")
check("no label carries a colon", not (T.CooldownLabel("A: B: C") or ""):find(":", 1, true))

-- Transmutes share one cooldown in game: one field here, not one per recipe.
fresh()
setAlchemy({ [11479] = { name = "Transmute: Iron to Gold", learned = true, cooldown = 7200 },
             [17187] = { name = "Transmute: Arcanite", learned = true, cooldown = 7200 } })
T.OnShow(); WoW.flushTimers()
local cdKeys = {}
for k in pairs(AltStableDB[ME]) do if k:find("^cd_") then cdKeys[#cdKeys + 1] = k end end
eq("two transmutes on one cooldown make one field", #cdKeys, 1)
eq("  named for the shared cooldown", cdKeys[1], "cd_Alchemy@Transmute")

-- And it survives the wire: Core sends key:value lines.
local line = Core.SerializeChar(AltStableDB[ME])
local parsed = Core.DeserializeChar(line)
eq("the cooldown reads back as a number on a peer", parsed and tonumber(parsed["cd_Alchemy@Transmute"]), WoW.now + 7200)

-- Ready again: the client says nil (not 0) - the field keeps a past expiry.
WoW.now = WoW.now + 100
WoW.tradeSkill.recipes[11479].cooldown = nil
WoW.tradeSkill.recipes[17187].cooldown = nil
T.OnShow(); WoW.flushTimers()
eq("a cooldown the client reports as nil is ready: expiry set to now", AltStableDB[ME]["cd_Alchemy@Transmute"], WoW.now)

WoW.now = 5000
local char = {}
check("a new cooldown is a change", T.ApplyCooldowns(char, "Alchemy", { Transmute = 3600 }, { Transmute = true }))
eq("  written as an absolute expiry", char["cd_Alchemy@Transmute"], 8600)
check("a shift under a minute is jitter, not a change",
      not T.ApplyCooldowns(char, "Alchemy", { Transmute = 3570 }, { Transmute = true }))
check("known and not running is a change back to ready", T.ApplyCooldowns(char, "Alchemy", {}, { Transmute = true }))
eq("  keeping a past expiry so the grid says Ready", char["cd_Alchemy@Transmute"], 5000)
check("ready staying ready is no change", not T.ApplyCooldowns(char, "Alchemy", {}, { Transmute = true }))
check("a label no learned recipe files under any more is removed", T.ApplyCooldowns(char, "Alchemy", {}, {}))
eq("  gone", char["cd_Alchemy@Transmute"], nil)

-- A cooldown alone reaches peers: the character is touched.
fresh()
setAlchemy({ [2330] = { name = "Minor Healing Potion", learned = true } })
T.OnShow(); WoW.flushTimers()
AltStableDB[ME].lastUpdate = 1
WoW.tradeSkill.recipes[2330].cooldown = 600
T.OnShow(); WoW.flushTimers()
eq("a cooldown-only change touches the character", AltStableDB[ME].lastUpdate, WoW.now)

-- The login toast: once for a cooldown that came up, not again weeks later.
dofile("Toasts.lua")
local toasted
AltStable.ShowAggregateToast = function(list) toasted = list end
AltStableConfig.toastsShown = {}
WoW.now = 1800000000
AltStableDB = { [ME] = { guid = ME, name = "Me", class = "MAGE",
                         ["cd_Alchemy@Transmute"] = WoW.now - 3600,
                         ["cd_Tailoring@Mooncloth"] = WoW.now - 8 * 86400 } }
toasted = nil
AltStable.ScanCooldowns()
eq("a cooldown ready an hour ago is toasted", toasted and #toasted, 1)
eq("  and only that one", toasted and toasted[1] and toasted[1].cdName, "Transmute")
toasted = nil
AltStable.ScanCooldowns()
eq("  once", toasted, nil)
WoW.now = WoW.now + 10 * 86400
AltStableConfig.toastsShown = {}   -- what the week-long shown-set has forgotten by then
toasted = nil
AltStable.ScanCooldowns()
eq("a cooldown that came up weeks ago is not toasted again at every login", toasted, nil)

------------------------------------------------------------
-- Sync, through the core
------------------------------------------------------------

local ALT = "Player-4618-ALT0001"
local function ownerState(stamp, lastUpdate, known)
    AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST", level = 40,
                              realm = "Classic Beta PvE", lastUpdate = lastUpdate, scannedHere = true } }
    AltStableProfessionsDB = { [ALT] = { stamp = stamp, profs = {
        [171] = { rank = 120, max = 150, full = stamp, known = known } } } }
end
local function send(sinceTS) return Core.SerializeFullDB(false, sinceTS or 0) end
local function receive(payload, db, pdb)
    AltStableDB, AltStableProfessionsDB = db, pdb
    Core.DeserializeFullDB(payload, "Peer")
end

fresh()
ownerState(100, 1000, { [2329] = true, [2330] = true })
local fromA = send(0)
local bDB, bPDB = {}, {}
receive(fromA, bDB, bPDB)
check("B holds the alt's recipes", bPDB[ALT] and bPDB[ALT].profs[171] and bPDB[ALT].profs[171].known[2330])
eq("  under the owner's stamp", bPDB[ALT] and bPDB[ALT].stamp, 100)
eq("  complete, as the owner scanned it", bPDB[ALT] and bPDB[ALT].profs[171].full, 100)
AltStableDB, AltStableProfessionsDB = bDB, bPDB
local fromB = send(500)   -- C's watermark for B: after the recipe stamp, before the core change
local cDB, cPDB = {}, {}
receive(fromB, cDB, cPDB)
check("C gets the recipes one relay hop later, with a non-zero watermark",
      cPDB[ALT] and cPDB[ALT].profs[171] and cPDB[ALT].profs[171].known[2329])

AltStableDB, AltStableProfessionsDB = bDB, bPDB
local charLine = Core.SerializeChar(bDB[ALT])
local dDB, dPDB = {}, {}
AltStableDB, AltStableProfessionsDB = dDB, dPDB
Core.ReceiveCharacter(Core.DeserializeChar(charLine), "Peer")
check("the single-character path applies the snapshot too", dPDB[ALT] and dPDB[ALT].profs[171] ~= nil)

-- Receiving never moves lastUpdate: a relay that did would re-send it forever.
-- (Through the core the incoming record's own lastUpdate is merged right after,
-- which would hide it; so the plugin is asked directly.)
eq("a relay keeps the owner's lastUpdate", bDB[ALT].lastUpdate, 1000)
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", lastUpdate = 1000 } }
AltStableProfessionsDB = {}
WoW.now = 1700009999
T.DeserializePlayer(ALT, "v1|s=300|p=171:60:75:300:2329")
check("applying a snapshot does not touch the character",
      AltStableProfessionsDB[ALT] and AltStableDB[ALT].lastUpdate == 1000)

local function blob(stamp, ids)
    return "v1|s=" .. stamp .. "|p=171:60:75:" .. stamp .. ":" .. table.concat(ids, ",")
end
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST" } }
AltStableProfessionsDB = {}
T.DeserializePlayer(ALT, blob(201, { 2329, 2330 }))
T.DeserializePlayer(ALT, blob(200, { 2329 }))
check("newer then older: the newer stays", AltStableProfessionsDB[ALT].profs[171].known[2330])
AltStableProfessionsDB = {}
T.DeserializePlayer(ALT, blob(200, { 2329 }))
T.DeserializePlayer(ALT, blob(201, { 2329, 2330 }))
check("older then newer: the newer wins", AltStableProfessionsDB[ALT].profs[171].known[2330])
local held = AltStableProfessionsDB[ALT]
T.DeserializePlayer(ALT, blob(201, { 2329 }))
check("an equal stamp is not applied (one owner never reuses a stamp)",
      AltStableProfessionsDB[ALT].profs[171].known[2330] and AltStableProfessionsDB[ALT] == held)

-- One of our own alts, played on another PC: the core takes the newer record,
-- and the snapshot has to come with it. Our own echo (equal or older) does not.
AltStableDB = { [ME] = { guid = ME, name = "Me", scannedHere = true } }
AltStableProfessionsDB = { [ME] = { stamp = 5, profs = { [171] = { known = { [2329] = true }, full = 5 } } } }
T.DeserializePlayer(ME, blob(5, { 2331 }))
check("our own snapshot echoed back is ignored", AltStableProfessionsDB[ME].profs[171].known[2329])
T.DeserializePlayer(ME, blob(999, { 2331 }))
check("a strictly newer snapshot of our own alt, from another PC, is taken",
      AltStableProfessionsDB[ME].stamp == 999 and AltStableProfessionsDB[ME].profs[171].known[2331])

-- Empty, malformed, unknown.
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer" } }
AltStableProfessionsDB = { [ALT] = { stamp = 10, profs = { [171] = { known = { [2329] = true } } } } }
T.DeserializePlayer(ALT, "v1|s=11|p=")
check("an explicit empty snapshot means 'no professions now'",
      AltStableProfessionsDB[ALT].stamp == 11 and next(AltStableProfessionsDB[ALT].profs) == nil)
AltStableProfessionsDB = { [ALT] = { stamp = 10, profs = { [171] = { known = { [2329] = true } } } } }
T.DeserializePlayer(ALT, "v1|s=12")
check("a missing p= is malformed, not empty", AltStableProfessionsDB[ALT].stamp == 10)
T.DeserializePlayer(ALT, "v1|s=12|p=171:60:75:-:2329,abc")
check("a malformed id keeps the good data", AltStableProfessionsDB[ALT].stamp == 10)
T.DeserializePlayer(ALT, "v1|s=12|p=171:x:75:-:2329")
check("a malformed field keeps the good data", AltStableProfessionsDB[ALT].stamp == 10)
T.DeserializePlayer(ALT, "v2|s=99|p=")
check("an unknown version is ignored, not applied", AltStableProfessionsDB[ALT].stamp == 10)
T.DeserializePlayer(ALT, "v1|s=12|p=171:60:75:-:2329")
eq("a partial snapshot arrives as partial", AltStableProfessionsDB[ALT].profs[171].full, nil)

-- A line this build does not know (a newer peer's) is skipped, not stored -
-- and the character can then be played here without an error.
AltStableDB = { [ME] = { guid = ME, name = "Me" } }
AltStableProfessionsDB = {}
T.DeserializePlayer(ME, "v1|s=20|p=2937:1:1:-:1;171:60:75:20:2329")
check("an unknown line is skipped", AltStableProfessionsDB[ME].profs[2937] == nil)
check("  the known one kept", AltStableProfessionsDB[ME].profs[171] ~= nil)
T.ResetState()
WoW.professions = {}
local okOwn = pcall(T.RefreshOwnership)
WoW.now = WoW.now + 6
okOwn = okOwn and pcall(T.RefreshOwnership)
check("  and reconciling ownership afterwards raises nothing", okOwn)

AltStableProfessionsDB = {}
eq("no snapshot, nothing sent", T.SerializePlayer(ALT), "")
AltStableProfessionsDB = { [ALT] = { stamp = 3, profs = {} } }
eq("a 'has none' snapshot is sent as an empty p=", T.SerializePlayer(ALT), "v1|s=3|p=")

------------------------------------------------------------
-- Full pulls: an empty store, or a plugin switched on from Options
------------------------------------------------------------

local resets = 0
local realReset = AltStable.ResetPeerWatermarks
AltStable.ResetPeerWatermarks = function() resets = resets + 1 end
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer" } }
AltStableProfessionsDB = { [ALT] = { stamp = 3, profs = {} } }
T.BootstrapPlugin()
eq("an ordinary login with snapshots held does not reset the watermarks", resets, 0)
AltStableProfessionsDB = {}
T.BootstrapPlugin()
eq("an empty store asks for a full pull", resets, 1)
AltStableProfessionsDB = { ["Player-gone"] = { stamp = 3, profs = {} } }
T.BootstrapPlugin()
eq("orphans are pruned first, so they do not count as data", resets, 2)

-- The core does it for any plugin it loads from Options: switched on after
-- sessions without it, the peers' watermarks are ahead of what it never got.
WoW.loaded = {}
AltStable.SetPluginEnabled("warband", true)
eq("enabling a plugin that was off asks for a full pull", resets, 3)
AltStable.SetPluginEnabled("warband", true)
eq("  but not when it is already loaded", resets, 3)
AltStable.SetPluginEnabled("warband", false)
eq("  nor when switching one off", resets, 3)
AltStable.ResetPeerWatermarks = realReset
WoW.flushTimers()

------------------------------------------------------------
-- Read model
------------------------------------------------------------

local A, B, U = "Player-A", "Player-B", "Player-U"
local function readModelState()
    AltStableDB = {
        [A] = { guid = A, name = "Alder", class = "MAGE", prof_Alchemy = 120 },
        [B] = { guid = B, name = "Birch", class = "PRIEST", prof_Alchemy = 60 },
        [U] = { guid = U, name = "Umber", class = "ROGUE", prof_Alchemy = 30 },   -- never scanned
    }
    AltStableProfessionsDB = {
        [A] = { stamp = 1, profs = { [171] = { rank = 120, max = 150, full = 1, known = { [2329] = true, [2330] = true, [2331] = true } } } },
        [B] = { stamp = 1, profs = { [171] = { rank = 60, max = 75, full = 1, known = { [2329] = true } } } },
    }
end
readModelState()
local o = T.Owners(171)
eq("owners are listed by skill", o[1] and o[1].name, "Alder")
eq("a character the plugin never saw, with the skill field, is unscanned", o[3] and o[3].state, "unscanned")

local cat = T.Catalogue(171, o)
check("the catalogue leaves out an unknown requirement", not cat[2333])
eq("  and holds the rest of the line", count(cat), 4)
AltStableProfessionsDB[A].profs[171].known[2333] = true
check("  unless an alt actually knows it", T.Catalogue(171, T.Owners(171))[2333])
AltStableProfessionsDB[A].profs[171].known[2333] = nil

local function ids(rows) local t = {} for _, r in ipairs(rows) do t[#t + 1] = r.id end return table.concat(t, ",") end
eq("All, sorted by required skill", ids(T.BuildRows({ line = 171 })), "2329,2330,2331,2332")
eq("Known", ids(T.BuildRows({ line = 171, filter = "known" })), "2329,2330,2331")
eq("Nobody", ids(T.BuildRows({ line = 171, filter = "nobody" })), "2332")
eq("Missing: some complete owner lacks it", ids(T.BuildRows({ line = 171, filter = "missing" })), "2330,2331,2332")
eq("Missing, focused on Birch", ids(T.BuildRows({ line = 171, filter = "missing", focus = B })), "2330,2331,2332")
eq("Known, focused on Birch", ids(T.BuildRows({ line = 171, filter = "known", focus = B })), "2329")
eq("Missing, focused on an unscanned alt: nothing is claimed",
   ids(T.BuildRows({ line = 171, filter = "missing", focus = U })), "")
eq("Not from a trainer: anything with another source", ids(T.BuildRows({ line = 171, onlyDrops = true })), "2331,2332")

local rows = T.BuildRows({ line = 171, filter = "nobody" })
eq("with an unscanned owner, nobody-knows is only 'recorded'", rows[1] and rows[1].nobody, "Nobody recorded")
AltStableDB[U] = nil
rows = T.BuildRows({ line = 171, filter = "nobody" })
eq("with every owner complete, it can say 'Nobody knows'", rows[1] and rows[1].nobody, "Nobody knows")

-- A hidden alt is out of the list but still counts: it may know the recipe.
local realHidden = AltStable.IsCharacterHidden
AltStable.IsCharacterHidden = function(guid) return guid == B end
local visibleOwners, hiddenOwners = T.Owners(171)
eq("a hidden owner is left out of the list", #visibleOwners, 1)
eq("  and counted", hiddenOwners, 1)
rows = T.BuildRows({ line = 171, filter = "nobody" })
eq("with a hidden owner, nobody-knows is only 'recorded'", rows[1] and rows[1].nobody, "Nobody recorded")
AltStable.IsCharacterHidden = realHidden

readModelState()
WoW.spellNames = { [2331] = "Elixir of Lesser Agility", [3101] = "Rough Copper Vest" }
rows = T.BuildRows({ line = 171, search = "copper" })
eq("search spans every profession", rows[1] and rows[1].id, 3101)
eq("  and only matches", #rows, 1)

-- A spell the client does not have: asked for once, and a failed answer does
-- not come back as a redraw.
WoW.unknownSpells = { [2332] = true }
T.names[2332] = nil
WoW.spellRequests = {}
T.BuildRows({ line = 171 })
T.BuildRows({ line = 171 })
local asked = 0
for _, id in ipairs(WoW.spellRequests) do if id == 2332 then asked = asked + 1 end end
eq("a name the client lacks is requested once, not per redraw", asked, 1)
AT.isActive = true
eq("a failed load does not redraw", T.OnSpellData(2332, false), false)
WoW.spellRequests = {}
T.BuildRows({ line = 171 })
eq("  and is not asked for again", #WoW.spellRequests, 0)
eq("an answer for an ID never asked about does not redraw", T.OnSpellData(424242, true), false)
T.names[2330] = nil
WoW.unknownSpells = { [2330] = true }
T.BuildRows({ line = 171 })
eq("a successful load for a requested ID redraws", T.OnSpellData(2330, true), true)
AT.isActive = false
WoW.unknownSpells = {}
WoW.flushTimers()

-- Meets the skill: only for a complete scan, only when not known.
local birch
for _, x in ipairs(T.Owners(171)) do if x.guid == B then birch = x end end
check("Birch (60) meets Lesser Agility (50), which she lacks", T.MeetsSkill(birch, 2331))
check("  not Elixir 2332 (125)", not T.MeetsSkill(birch, 2332))
check("  and nothing she already knows", not T.MeetsSkill(birch, 2329))
AltStableProfessionsDB[B].profs[171].full = nil
for _, x in ipairs(T.Owners(171)) do if x.guid == B then birch = x end end
check("a partial alt is never offered 'meets skill'", not T.MeetsSkill(birch, 2331))

local r = AltStableRecipeData.recipes[2331]
local cr, cg, cb = T.DifficultyColor(r, 40)
check("below the requirement: red", cr > 0.8 and cg < 0.3, cr .. "," .. cg)
cr, cg = T.DifficultyColor(r, 60)
check("under yellow: orange", cr == 1 and cg == 0.5)
cr, cg, cb = T.DifficultyColor(r, 130)
check("at grey: grey", cr == 0.5 and cg == 0.5 and cb == 0.5)

readModelState()
AltStableDB[A]["cd_Alchemy@Transmute"] = 1000000
WoW.now = 999000
local cards = T.Cards(171)
eq("one card per owner", #cards, 3)
eq("  known against the catalogue", cards[1].known .. "/" .. cards[1].total, "3/4")
eq("  with the soonest cooldown", cards[1].cooldown and cards[1].cooldown.label, "Transmute")

------------------------------------------------------------
-- The panel builds and fills, and the wheel goes where the pointer is
------------------------------------------------------------

readModelState()
local main = CreateFrame("Frame", nil, UIParent)
local ok, err = pcall(function() plugin.OnActivate(main) end)
check("the tab activates without an error", ok, tostring(err))
check("  and shows rows", AT.rows and #AT.rows > 0)
AT.cardData = {}
for i = 1, 8 do AT.cardData[i] = cards[1] end
AT.cardStart, AT.scrollRow = 0, 0
AT.OnWheel(-1, true)
eq("the wheel over the cards moves them sideways", AT.cardStart, 1)
eq("  and not the list", AT.scrollRow, 0)
AT.OnWheel(-1, false)
eq("the wheel elsewhere scrolls the list", AT.cardStart, 1)
ok, err = pcall(function() plugin.OnDeactivate(main) end)
check("  and deactivates", ok, tostring(err))

------------------------------------------------------------
-- Forget / cleanup
------------------------------------------------------------

AltStableProfessionsDB = { [A] = { stamp = 1, profs = {} }, [B] = { stamp = 1, profs = {} } }
plugin.OnForget(A)
eq("forgetting a character drops its recipes", AltStableProfessionsDB[A], nil)
plugin.OnCleanup(B)
check("cleanup keeps only the named character", AltStableProfessionsDB[B] ~= nil and next(AltStableProfessionsDB, nil) == B)

print(("test_professions: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
