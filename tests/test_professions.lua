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
    [2329] = { skill = { 171 }, learn = 1,   colors = { 1, 55, 75, 95 }, makes = 2454, src = { 6 },
               reagents = { 2449, 1, 765, 1, 3371, 1 } },
    [2330] = { skill = { 171 }, learn = 15,  colors = { 15, 60, 80, 100 }, makes = 118, src = { 6 } },
    [2331] = { skill = { 171 }, learn = 50,  colors = { 50, 80, 100, 120 }, makes = 2455, src = { 2 },
               reagents = { 785, 2, 3371, 1 } },
    [2332] = { skill = { 171 }, learn = 125, colors = { 125, 150, 170, 190 }, makes = 2456, src = { 5, 6 },
               favor = 90 },                                     -- a quartermaster's, for Favor (#270)
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
-- Captured now: WoW.reset() between sections clears the registry, and the hook
-- is installed once, at bootstrap - before the tab is ever opened.
local ttCalls = WoW.tooltipPostCalls[Enum.TooltipDataType.Item]
check("the item-tooltip hook is installed at bootstrap", ttCalls ~= nil and #ttCalls == 1)
-- The plugin's event frame, captured now for the same reason (#269 calls it
-- with GET_ITEM_INFO_RECEIVED).
local eventFrame
for _, w in ipairs(WoW.frames) do
    if w._events and w._events.GET_ITEM_INFO_RECEIVED and w._events.TRADE_SKILL_SHOW then eventFrame = w end
end
check("the plugin listens for items it asked the client to load (#269)", eventFrame ~= nil)

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
    AltStableProfessionsReagents = {}
    T.ResetState()
    T.scan.open, T.scan.gen, T.scan.retries = false, T.scan.gen + 1, 0
    T.scan.reagentsLine = nil
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

-- A cooldown read that FAILS is not "ready": the field stays as it was, and
-- nothing is synced for it. The recipes still commit.
fresh()
setAlchemy({ [11479] = { name = "Transmute: Iron to Gold", learned = true, cooldown = 7200 } })
T.OnShow(); WoW.flushTimers()
local expiryBefore = AltStableDB[ME]["cd_Alchemy@Transmute"]
local realCooldown = C_TradeSkillUI.GetRecipeCooldown
C_TradeSkillUI.GetRecipeCooldown = function() error("boom") end
WoW.now = WoW.now + 60
AltStableDB[ME].lastUpdate = 1
WoW.tradeSkill.recipes[11480] = { name = "Transmute: Mithril to Truesilver", learned = true }
T.OnShow(); WoW.flushTimers()
eq("a failing cooldown read leaves the running cooldown alone", AltStableDB[ME]["cd_Alchemy@Transmute"], expiryBefore)
check("  while the recipes still commit", AltStableProfessionsDB[ME].profs[171].known[11480])
C_TradeSkillUI.GetRecipeCooldown = nil
WoW.tradeSkill.recipes[11481] = { name = "Transmute: Earth to Water", learned = true }
T.OnShow(); WoW.flushTimers()
eq("with no cooldown API at all, cooldowns are left alone", AltStableDB[ME]["cd_Alchemy@Transmute"], expiryBefore)
check("  and scanning still works", AltStableProfessionsDB[ME].profs[171].known[11481])
C_TradeSkillUI.GetRecipeCooldown = realCooldown

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

-- The same, through the core: a PC whose own alt's core record is as new as
-- the peer's (so the core keeps its copy) still takes the newer snapshot -
-- the plugin was just switched on there, or reinstalled. Both receive paths.
local function ownAltPayload(pstamp, coreTS)
    AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST", level = 40, lastUpdate = coreTS } }
    AltStableProfessionsDB = { [ALT] = { stamp = pstamp, profs = { [171] = { rank = 90, max = 150, full = pstamp, known = { [2331] = true } } } } }
    return Core.SerializeFullDB(false, 0), Core.SerializeChar(AltStableDB[ALT])
end
for _, coreTS in ipairs({ 1000, 900 }) do
    local bulk, single = ownAltPayload(1001, coreTS)
    local mine = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST", level = 40, lastUpdate = 1000,
                             scannedHere = true, prof_Alchemy = 95 } }
    AltStableDB, AltStableProfessionsDB = mine, {}
    Core.DeserializeFullDB(bulk, "Peer")
    check("bulk path, peer's core record " .. (coreTS == 1000 and "equal" or "older") .. ": the snapshot arrives",
          AltStableProfessionsDB[ALT] and AltStableProfessionsDB[ALT].profs[171] and AltStableProfessionsDB[ALT].profs[171].known[2331])
    eq("  and our own core record is untouched", mine[ALT].prof_Alchemy, 95)
    eq("  its lastUpdate too", mine[ALT].lastUpdate, 1000)
    mine[ALT].prof_Alchemy = 95
    AltStableDB, AltStableProfessionsDB = mine, {}
    Core.ReceiveCharacter(Core.DeserializeChar(single), "Peer")
    check("single path, peer's core record " .. (coreTS == 1000 and "equal" or "older") .. ": the snapshot arrives",
          AltStableProfessionsDB[ALT] and AltStableProfessionsDB[ALT].profs[171] ~= nil)
    eq("  and our own core record is untouched", mine[ALT].prof_Alchemy, 95)
end
-- Its own stamp still decides: an older snapshot does not replace a newer one.
local bulkOld = ownAltPayload(500, 1000)
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST", level = 40, lastUpdate = 1000, scannedHere = true } }
AltStableProfessionsDB = { [ALT] = { stamp = 700, profs = { [171] = { rank = 90, max = 150, full = 700, known = { [2329] = true } } } } }
Core.DeserializeFullDB(bulkOld, "Peer")
eq("through the core, an older snapshot still loses", AltStableProfessionsDB[ALT].stamp, 700)
-- Identity checks still come first: a record under another name hands over nothing.
local impostor = Core.SerializeChar({ guid = ALT, name = "Impostor", class = "PRIEST", level = 40, lastUpdate = 1000 })
    .. "\nplugin_professions:v1|s=5000|p=171:1:1:-:2332\n" .. Core.CHAR_SEP
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer", class = "PRIEST", level = 40, lastUpdate = 1000 } }
AltStableProfessionsDB = {}
Core.DeserializeFullDB(impostor, "Peer")
eq("a record that fails validation hands its snapshot to nobody", AltStableProfessionsDB[ALT], nil)

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

-- Merchant's Favor (#270): the price where "Vendor" would be, and a filter.
eq("Favor: only what a quartermaster sells for it", ids(T.BuildRows({ line = 171, onlyFavor = true })), "2332")
eq("  with Missing and an alt in focus: what that alt could buy",
   ids(T.BuildRows({ line = 171, onlyFavor = true, filter = "missing", focus = B })), "2332")
eq("  and with Known, what it already has", ids(T.BuildRows({ line = 171, onlyFavor = true, filter = "known", focus = B })), "")
eq("a Favor recipe's source says its price", T.SourceText(AltStableRecipeData.recipes[2332]), "90 Favor, Trainer")
eq("  another vendor's says Vendor", T.SourceText({ src = { 5 } }), "Vendor")
eq("  a price with no other source is still said", T.SourceText({ favor = 30 }), "30 Favor")
eq("  so is one whose sources lack a vendor", T.SourceText({ src = { 2 }, favor = 30 }), "30 Favor, Drop")
eq("  and unknown is still unknown", T.SourceText({}), "?")

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

------------------------------------------------------------
-- Reagents across the stable (#268)
------------------------------------------------------------

-- Warband's AltStable.ItemHolders, shaped as its CountItem returns: total, then
-- { guid, name, class, bags, bank, bankStale } per holder (test_warband checks
-- the real one has that shape).
local held = {}
local function holdersStub(item)
    local total, out = 0, {}
    for guid, items in pairs(held) do
        local h = items[item]
        if h then
            total = total + (h.bags or 0) + (h.bank or 0) + (h.mail or 0)
            out[#out + 1] = { guid = guid, name = AltStableDB[guid] and AltStableDB[guid].name,
                              class = AltStableDB[guid] and AltStableDB[guid].class,
                              bags = h.bags or 0, bank = h.bank or 0, bankStale = h.bankStale,
                              mail = h.mail or 0 }
        end
    end
    return total, out
end
local function owner(guid) for _, x in ipairs(T.Owners(171)) do if x.guid == guid then return x end end end

readModelState()
AltStable.ItemHolders = nil
check("without Warband nothing is counted", not T.ReagentsCounted())
eq("  so no plan", T.ReagentPlan(2329, { owner(A) }), nil)
eq("  and Craftable keeps nothing, known or not", ids(T.BuildRows({ line = 171, filter = "craftable" })), "")
local lines = T.ReagentLines(2329, { owner(A) })
eq("the tooltip still lists what one craft needs", lines[2] and lines[2][1], "1 x item 2449")
check("  and says how to get the counts", lines[#lines][1]:find("Warband", 1, true) ~= nil, lines[#lines][1])
eq("a recipe without reagents has no block", #T.ReagentLines(2330, {}), 0)

AltStable.ItemHolders = holdersStub
held = {
    [A] = { [2449] = { bags = 3 }, [3371] = { bags = 1 } },          -- Alder: no Silverleaf (765)
    [B] = { [765] = { bags = 2, bank = 3 }, [785] = { bags = 1 } },  -- Birch holds it
}
local plan = T.ReagentPlan(2329, { owner(A), owner(B) })
check("with Warband, a plan", plan ~= nil)
eq("  totals per reagent, bags and bank", plan and plan.reagents[2].total, 5)
check("  the stable has enough for one craft", plan and plan.enough)
local alder, birch = plan.crafters[1], plan.crafters[2]
eq("  Alder lacks one reagent", alder and #alder.short, 1)
eq("    Silverleaf", alder and alder.short[1] and alder.short[1].item, 765)
eq("    and Birch, who has 5, is who to ask", alder and alder.short[1].from and alder.short[1].from.name, "Birch")
eq("  Birch lacks two (Earthroot and the vial)", birch and #birch.short, 2)
eq("Craftable: known, and the stable holds every reagent", ids(T.BuildRows({ line = 171, filter = "craftable" })), "2329")
-- 2331 is known by Alder, but the stable has 1 Mageroyal of the 2 it needs.
check("  short of one reagent: not craftable", not T.ReagentPlan(2331, {}).enough)
eq("Craftable, focused on Birch: she knows 2329", ids(T.BuildRows({ line = 171, filter = "craftable", focus = B })), "2329")
AltStableProfessionsDB[B].profs[171].known[2329] = nil
eq("  and once she doesn't, nothing for her", ids(T.BuildRows({ line = 171, filter = "craftable", focus = B })), "")
AltStableProfessionsDB[B].profs[171].known[2329] = true

-- A search spans every profession, and the selected alt stays the one asked
-- about on those it does not have (#363): Birch has no Blacksmithing, Smith
-- knows the recipe and holds what it takes.
do
    local SMITH = "Player-Smith"
    AltStableDB[SMITH] = { guid = SMITH, name = "Smith", class = "WARRIOR" }
    AltStableProfessionsDB[SMITH] = { stamp = 1,
        profs = { [164] = { rank = 40, max = 75, full = 1, known = { [3100] = true } } } }
    local heldNames, heldRecipe = WoW.spellNames, AltStableRecipeData.recipes[3100].reagents
    AltStableRecipeData.recipes[3100].reagents = { 2449, 1 }
    WoW.spellNames = { [2329] = "Copper Tonic", [2331] = "Copper Elixir", [3100] = "Copper Bracers",
                       [3101] = "Rough Copper Vest" }
    for k in pairs(T.names) do T.names[k] = nil end
    local function search(filter, focus)
        return ids(T.BuildRows({ line = 171, search = "copper", filter = filter, focus = focus }))
    end
    eq("searching with Birch selected, Known is Birch's only", search("known", B), "2329")
    eq("  with nobody selected, everyone's", search("known"), "3100,2329,2331")
    eq("  Missing: only in her own professions", search("missing", B), "2331")
    eq("    with nobody selected, any full owner's", search("missing"), "3101,2331")
    eq("  Craftable: what she knows and has the reagents for", search("craftable", B), "2329")
    eq("    with nobody selected, anyone's", search("craftable"), "3100,2329")
    -- A recipe on two lines (Leatherworking and Tailoring): Birch knows it as a
    -- Tailor, so it shows once, on her Tailoring row.
    WoW.spellNames[7000] = "Copper Belt"
    for k in pairs(T.names) do T.names[k] = nil end
    AltStableProfessionsDB[B].profs[197] = { rank = 60, max = 75, full = 1, known = { [7000] = true } }
    local rows2 = T.BuildRows({ line = 171, search = "copper", filter = "known", focus = B })
    local where = {}
    for _, r in ipairs(rows2) do if r.id == 7000 then where[#where + 1] = r.line end end
    eq("  a two-line recipe she knows shows once, on her own line", table.concat(where, ","), "197")
    AltStableProfessionsDB[B].profs[197] = nil
    WoW.spellNames, AltStableRecipeData.recipes[3100].reagents = heldNames, heldRecipe
    for k in pairs(T.names) do T.names[k] = nil end
    AltStableDB[SMITH], AltStableProfessionsDB[SMITH] = nil, nil
end

-- Hidden alts: their bags are out of the counts, as they are out of the list.
AltStable.IsCharacterHidden = function(guid) return guid == B end
plan = T.ReagentPlan(2329, { owner(A) })
eq("a hidden alt's bags do not count", plan.reagents[2].total, 0)
check("  so the stable is short", not plan.enough)
eq("  and Alder has nobody to ask", plan.crafters[1].short[1].from, nil)
AltStable.IsCharacterHidden = realHidden

-- Most first: the alt to ask for a reagent is the one holding the most.
held[U] = { [765] = { bags = 9 } }
AltStableDB[U] = { guid = U, name = "Umber", class = "ROGUE" }
plan = T.ReagentPlan(2329, { owner(A) })
eq("holders are sorted most first", plan.reagents[2].holders[1].name, "Umber")
eq("  and the one to ask is the one with the most", plan.crafters[1].short[1].from.name, "Umber")
held[U] = nil

-- Mail (#312): Warband counts it, but a reagent in the mail can't be crafted
-- with, so a holder with nothing else is no holder here.
held[U] = { [765] = { mail = 9 } }
plan = T.ReagentPlan(2329, { owner(A) })
eq("a reagent only in the mail does not count", plan.reagents[2].total, 5)
check("  and its holder is not listed", plan.reagents[2].holders[1].name ~= "Umber"
      and #plan.reagents[2].holders == 1, tostring(#plan.reagents[2].holders))
held[U] = nil

-- The tooltip lines.
WoW.items[765] = { name = "Silverleaf" }
lines = T.ReagentLines(2329, { owner(A), owner(B) })
local text = {}
for _, l in ipairs(lines) do text[#text + 1] = l[1] .. "|" .. tostring(l[2]) end
text = table.concat(text, "\n")
check("a reagent's line names it and the count needed", text:find("1 x Silverleaf|", 1, true) ~= nil, text)
check("  with the stable's total in green when enough", text:find("|cff40ff405|r", 1, true) ~= nil, text)
check("  and who holds it", text:find("Birch|r 5", 1, true) ~= nil, text)
check("a knower who is short says what and from whom",
      text:find("needs 1 Silverleaf (", 1, true) ~= nil and text:find(" has 5)", 1, true) ~= nil, text)
check("  and how many more reagents are short", text:find("needs 1 item 2449 (", 1, true) ~= nil
      and text:find(" +1", 1, true) ~= nil, text)
check("no stale-bank note while the banks are fresh", not text:find("over a week old", 1, true), text)
held[B][765].bankStale = true
lines = T.ReagentLines(2329, { owner(A) })
check("an old bank count is flagged", lines[#lines - 1][1]:find("over a week old", 1, true) ~= nil,
      tostring(lines[#lines - 1][1]))
held[A] = { [2449] = { bags = 1 }, [765] = { bags = 1 }, [3371] = { bags = 1 } }
held[B] = nil
check("exactly what one craft needs is enough", T.ReagentPlan(2329, {}).enough)
lines = T.ReagentLines(2329, { owner(A) })
check("a knower with everything on them has the reagents",
      lines[#lines][2] and lines[#lines][2]:find("has the reagents", 1, true) ~= nil, tostring(lines[#lines][2]))
held[A][3371] = nil
lines = T.ReagentLines(2329, { owner(A) })
check("a reagent nobody holds says so", lines[#lines][2]:find("nobody has it", 1, true) ~= nil, lines[#lines][2])
check("  and its total is red", table.concat({ lines[4][2] or "" }):find("|cffff40400|r", 1, true) ~= nil,
      tostring(lines[4][2]))

-- Names: cached ones are used, a miss is asked for once.
WoW.itemLoadRequests = {}
for k in pairs(T.itemRequested) do T.itemRequested[k] = nil end
eq("a cached name", T.ItemName(765), "Silverleaf")
eq("an uncached one is a placeholder", T.ItemName(3371), "item 3371")
T.ItemName(3371)
eq("  asked for once, not on every hover", #WoW.itemLoadRequests, 1)

-- A Warband that throws, or answers with no list, is an UNKNOWN count - never
-- zero, never an error in the tab (Codex review of #277).
for label, fn in pairs({ throws = function() error("boom") end, ["gives no list"] = function() return 0 end }) do
    AltStable.ItemHolders = fn
    local p, why = T.ReagentPlan(2329, { owner(A) })
    check("a count that " .. label .. " gives no plan", p == nil and why == "failed", tostring(why))
    eq("  so Craftable does not claim it", ids(T.BuildRows({ line = 171, filter = "craftable" })), "")
    lines = T.ReagentLines(2329, { owner(A) })
    local all = {}
    for _, l in ipairs(lines) do all[#all + 1] = l[1] .. "|" .. tostring(l[2]) end
    all = table.concat(all, "\n")
    check("  and the tooltip says the counts could not be read", all:find("could not be read", 1, true) ~= nil, all)
    check("  never that nobody has a reagent, or a red zero",
          not all:find("nobody has it", 1, true) and not all:find("|cffff40400|r", 1, true), all)
    check("  nor to turn on a Warband that is on", not all:find("Turn on", 1, true), all)
end
AltStable.ItemHolders = holdersStub

-- The stale-bank note looks at every holder, not only the three named: a
-- fourth one's bank is in the total too (Codex review of #277).
for i, g in ipairs({ "Player-C", "Player-D", "Player-E", "Player-F" }) do
    AltStableDB[g] = { guid = g, name = "Holder" .. i, class = "MAGE" }
    held[g] = { [765] = { bags = 10 - i, bank = i == 4 and 1 or 0, bankStale = i == 4 } }
end
lines = T.ReagentLines(2329, { owner(A) })
local seen = false
for _, l in ipairs(lines) do if l[1]:find("over a week old", 1, true) then seen = true end end
check("an old bank on the fourth holder is still flagged", seen)
for _, g in ipairs({ "Player-C", "Player-D", "Player-E", "Player-F" }) do AltStableDB[g], held[g] = nil, nil end
AltStable.ItemHolders = nil
held = {}
WoW.items[765] = nil
readModelState()   -- the sections below expect the shared fixture as it was

------------------------------------------------------------
-- The window's reagents win where they differ (#348)
------------------------------------------------------------

local function flat(t) return t and table.concat(t, ",") or "nil" end

-- Reading one schematic, in the shape measured on 70959.
fresh()
setAlchemy({ [2329] = { name = "Elixir of Lion's Strength", learned = true, reagents = { 2449, 1, 765, 1, 3371, 1 } } })
eq("the window's reagents read as a flat list", flat(T.SchematicReagents(2329)), "2449,1,765,1,3371,1")
local function slot(items, n, kind, required)
    local r = {}
    for i, it in ipairs(items) do r[i] = it end
    return { reagents = r, quantityRequired = n, reagentType = kind or 1, required = required ~= false }
end
WoW.tradeSkill.recipes[2329].slots = { slot({ { itemID = 2449 } }, 2), slot({ { itemID = 9999 } }, 1, 1, false),
                                       slot({ { itemID = 8888 } }, 1, 2) }
eq("  only required Basic slots count (optional and finishing are left out)", flat(T.SchematicReagents(2329)), "2449,2")
WoW.tradeSkill.recipes[2329].slots = { slot({ { itemID = 2449 }, { itemID = 2450 } }, 1) }
eq("  a slot of alternatives can't be read as one list", T.SchematicReagents(2329), nil)
WoW.tradeSkill.recipes[2329].slots = { slot({ { currencyID = 3402 } }, 5) }
eq("  nor a currency", T.SchematicReagents(2329), nil)
WoW.tradeSkill.recipes[2329].slots = {}
eq("  and an empty answer is not taken as 'takes nothing'", T.SchematicReagents(2329), nil)
WoW.tradeSkill.recipes[2329].slots = nil
WoW.tradeSkill.recipes[2329].schematicError = true
eq("  a call that throws reads as nothing", T.SchematicReagents(2329), nil)

check("same items and amounts in another order are the same", T.SameReagents({ 1, 2, 3, 4 }, { 3, 4, 1, 2 }))
check("  one more reagent in the window is a difference", not T.SameReagents({ 1, 2, 3, 4 }, { 1, 2 }))
check("  and one more in the data is too", not T.SameReagents({ 1, 2 }, { 1, 2, 3, 4 }))
check("  another amount is", not T.SameReagents({ 1, 2 }, { 1, 3 }))
check("  and so is a list against none", not T.SameReagents({ 1, 2 }, nil))

-- A scan: the window agrees on 2329, takes one more of 785 for 2331, and has
-- reagents for 2333, which RecipeData has none for.
fresh()
setAlchemy({ [2329] = { name = "Elixir of Lion's Strength", learned = true, reagents = { 765, 1, 2449, 1, 3371, 1 } },
             [2331] = { name = "Elixir of Lesser Agility", learned = true, reagents = { 785, 3, 3371, 1 } },
             [2333] = { name = "Unknown", learned = true, reagents = { 3356, 1 } },
             [2332] = { name = "Not learned", learned = false, reagents = { 1, 1 } } })
T.OnShow()
WoW.flushTimers()
local store = AltStableProfessionsReagents
eq("a recipe the window agrees on keeps no entry (order aside)", store[2329], nil)
eq("one it disagrees on is kept, with the window's amounts", store[2331] and flat(store[2331].reagents), "785,3,3371,1")
eq("  stamped with the build", store[2331] and store[2331].build, "70959")
eq("  and the time", store[2331] and store[2331].at, WoW.now)
eq("one RecipeData has no reagents for takes the window's", store[2333] and flat(store[2333].reagents), "3356,1")
eq("an unlearned recipe is not read", store[2332], nil)
local list, fromWindow = T.Reagents(2331)
eq("the window's list is the one used", flat(list), "785,3,3371,1")
check("  and says so", fromWindow == true)
list, fromWindow = T.Reagents(2329)
eq("elsewhere RecipeData's", flat(list), "2449,1,765,1,3371,1")
check("  and says so", fromWindow == false)
AltStable.ItemHolders = holdersStub
held = { [ME] = { [785] = { bags = 2 }, [3371] = { bags = 1 } } }
plan = T.ReagentPlan(2331, {})
eq("the plan needs the window's amount", plan and plan.reagents[1].need, 3)
check("  so two in the bags is no longer enough", plan and not plan.enough)
lines = T.ReagentLines(2331, {})
check("the tooltip flags the window's amounts", lines[1] and lines[1][2] ~= nil
      and lines[1][2]:find("profession window", 1, true) ~= nil, lines[1] and tostring(lines[1][2]))
eq("  under the usual heading", lines[1] and lines[1][1], "Reagents")
eq("  in the window's amount", lines[2] and lines[2][1], "3 x item 785")
lines = T.ReagentLines(2329, {})
eq("a recipe the window agreed on has no flag", lines[1] and lines[1][2], nil)
AltStable.ItemHolders, held = nil, {}

-- Once per opening: a re-scan after a craft does not read them again.
WoW.tradeSkill.recipes[2331].reagents = { 785, 4, 3371, 1 }
T.ScheduleScan()
WoW.flushTimers()
eq("a re-scan in the same opening keeps what it read", flat(store[2331].reagents), "785,3,3371,1")
T.OnClose()
T.OnShow()
WoW.flushTimers()
eq("the next opening reads them again", flat(store[2331].reagents), "785,4,3371,1")

-- A read that fails keeps what is held; agreement drops it.
WoW.tradeSkill.recipes[2331].schematicError = true
T.OnClose(); T.OnShow(); WoW.flushTimers()
eq("a read that throws keeps the entry", store[2331] and flat(store[2331].reagents), "785,4,3371,1")
WoW.tradeSkill.recipes[2331].schematicError = nil
WoW.tradeSkill.recipes[2331].reagents = { 3371, 1, 785, 2 }
T.OnClose(); T.OnShow(); WoW.flushTimers()
eq("once the window agrees with RecipeData again, the entry goes", store[2331], nil)
eq("  and the data's amounts are back", flat((T.Reagents(2331))), "785,2,3371,1")

-- Account-wide and never synced: the character's snapshot and its stamp don't move.
fresh()
setAlchemy({ [2331] = { name = "Elixir of Lesser Agility", learned = true } })
T.OnShow(); WoW.flushTimers()
local blob, stampBefore, touchedBefore = T.SerializePlayer(ME), AltStableProfessionsDB[ME].stamp, AltStableDB[ME].lastUpdate
WoW.now = WoW.now + 10
WoW.tradeSkill.recipes[2331].reagents = { 785, 3, 3371, 1 }
T.OnClose(); T.OnShow(); WoW.flushTimers()
check("a reagent difference is kept", AltStableProfessionsReagents[2331] ~= nil)
eq("  without a new snapshot stamp", AltStableProfessionsDB[ME].stamp, stampBefore)
eq("  or a touch of the character (which would sync it)", AltStableDB[ME].lastUpdate, touchedBefore)
-- The blob's `full` is the scan's time and moves on every scan; nothing else may.
local function noFull(b) return (b:gsub(":%d+:([%d,]*)$", ":-:%1")) end
eq("  or anything new in the synced blob", noFull(T.SerializePlayer(ME)), noFull(blob))

local tocText = io.open("Plugins/Professions/AltStableProfessions.toc"):read("*a")
check("the TOC saves the reagents store", tocText:match("## SavedVariables:[^\n]*AltStableProfessionsReagents") ~= nil)
readModelState()   -- the shared fixture again, for the sections below

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

-- One verdict per owner and recipe, for the tab and the tooltips alike.
local vOwners = T.Owners(171)
local vBy = {}
for _, x in ipairs(vOwners) do vBy[x.name] = x end
eq("Alder knows Minor Healing", T.Verdict(vBy.Alder, 2330), "known")
eq("Birch meets Lesser Agility", T.Verdict(vBy.Birch, 2331), "meets")
eq("Birch is too low for 2332", T.Verdict(vBy.Birch, 2332), "low")
eq("an unscanned owner gets no verdict", T.Verdict(vBy.Umber, 2331), "unscanned")
eq("nobody-text with a hidden owner", T.NobodyText({ vBy.Alder }, 1), "Nobody recorded")
eq("nobody-text with every owner complete", T.NobodyText({ vBy.Alder, vBy.Birch }, 0), "Nobody knows")

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
-- Item tooltips
------------------------------------------------------------

local savedData = AltStableRecipeData
AltStableRecipeData = { source = "tooltip test", recipes = {
    [2331] = { skill = { 171 }, learn = 50, makes = 2455, items = { 3396 } },
    [2333] = { skill = { 171 }, makes = 2456, items = { 9001 } },           -- requirement unknown
    [2334] = { skill = { 171 }, learn = 1, makes = 118 },                    -- two recipes make 118
    [2335] = { skill = { 171 }, learn = 5, makes = 118 },
    [3100] = { skill = { 164 }, learn = 1, makes = 2862, items = { 5555 } }, -- nobody has Blacksmithing
} }
T.ResetState()
local C1, H = "Player-C", "Player-H"
AltStableDB = {
    [A]  = { guid = A,  name = "Alder", class = "MAGE" },
    [B]  = { guid = B,  name = "Birch", class = "PRIEST" },
    [C1] = { guid = C1, name = "Cedar", class = "ROGUE" },
    [U]  = { guid = U,  name = "Umber", class = "ROGUE", prof_Alchemy = 30 },   -- never scanned
    [H]  = { guid = H,  name = "Hazel", class = "DRUID" },                      -- hidden
}
AltStableProfessionsDB = {
    [A]  = { stamp = 1, profs = { [171] = { rank = 120, max = 150, full = 1, known = { [2331] = true, [2334] = true, [2335] = true } } } },
    [B]  = { stamp = 1, profs = { [171] = { rank = 60, max = 75, full = 1, known = { [2335] = true } } } },
    [C1] = { stamp = 1, profs = { [171] = { rank = 20, max = 75, full = 1, known = {} } } },
    [H]  = { stamp = 1, profs = { [171] = { rank = 150, max = 150, full = 1, known = { [2331] = true } } } },
}
local realHidden2 = AltStable.IsCharacterHidden
AltStable.IsCharacterHidden = function(guid) return guid == H end

local function tipFor(itemID)
    local out = {}
    local function plain(x) return (x:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    for _, l in ipairs(T.TooltipLines(itemID)) do out[plain(l[1])] = plain(l[2]) end
    return out
end
local tip = tipFor(3396)
eq("a recipe item says who knows it", tip["Known by"], "Alder")
eq("  who meets the skill (skill only)", tip["Meets skill"], "Birch (60)")
eq("  whose skill is too low, and by how much", tip["Skill too low"], "Cedar (20, needs 50)")
eq("  and whom it cannot speak for", tip["Not scanned"], "Umber")
check("  never naming a hidden character", not (tip["Known by"] or ""):find("Hazel", 1, true))

tip = tipFor(9001)
eq("with the requirement unknown, no skill verdict is given", tip["Requirement unknown"], "Alder, Birch, Cedar")
check("  neither 'meets' nor 'too low'", tip["Meets skill"] == nil and tip["Skill too low"] == nil)

tip = tipFor(5555)
check("a recipe for a profession nobody has says so", (tip["AltStable"] or ""):find("No alt has Blacksmithing", 1, true))
eq("an item that teaches nothing gets no lines", #T.TooltipLines(424242), 0)

-- The only Blacksmith is hidden: "No alt has Blacksmithing" would be false.
AltStableProfessionsDB[H].profs[164] = { rank = 50, max = 75, full = 1, known = { [3100] = true } }
tip = tipFor(5555)
check("a profession only a hidden alt has is not 'nobody has'", tip["AltStable"] == nil, tostring(tip["AltStable"]))
AltStableProfessionsDB[H].profs[164] = nil

tip = tipFor(118)
eq("a crafted item lists its crafters across every recipe, once each", tip["Crafted by"], "Alder, Birch")
eq("a crafted item nobody can make gets no line", tipFor(2456)["Crafted by"], nil)

-- A recipe on two lines: an alt who knows it through the second is "Known",
-- whatever the first line's skill (it was judged by the first line only).
AltStableRecipeData.recipes[7000] = { skill = { 165, 197 }, learn = 40, makes = 5000, items = { 7777 } }
T.ResetState()
local ASH = "Player-Ash"
AltStableDB[ASH] = { guid = ASH, name = "Ash", class = "WARRIOR" }
AltStableProfessionsDB[ASH] = { stamp = 1, profs = {
    [165] = { rank = 10, max = 75, full = 1, known = {} },
    [197] = { rank = 60, max = 75, full = 1, known = { [7000] = true } } } }
tip = tipFor(7777)
eq("known through a second line is known", tip["Known by"], "Ash")
eq("  and not 'too low' on the first", tip["Skill too low"], nil)
AltStableDB[ASH], AltStableProfessionsDB[ASH] = nil, nil

-- Name lists stop at four: a tooltip line does not wrap.
local many = {}
for i = 1, 6 do many[i] = { name = "Alt" .. i, class = "MAGE" } end
local listed = T.NameList(many):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
eq("six names show as four and '+2'", listed, "Alt1, Alt2, Alt3, Alt4, +2")

-- Through the hook, the way the client calls it - including a tooltip whose
-- payload carries no id (the item comes from the tooltip's link).
local lines = {}
local tt = WoW.makeFrame()
tt.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
tt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. "|" .. tostring(r) end
for _, fn in ipairs(ttCalls) do fn(tt, { id = 3396 }) end
local firstCount = #lines
check("the hook appends the lines", firstCount >= 5, table.concat(lines, " / "))
lines = {}
tt.GetItem = function() return "Recipe", "|cff1eff00|Hitem:3396::::::::60:::::|h[Recipe]|h|r" end
for _, fn in ipairs(ttCalls) do fn(tt, {}) end
eq("with no id in the payload, the item comes from the tooltip's link", #lines, firstCount)
tt.GetItem = nil
lines = {}
AltStable.SetConfigValue("professionsTooltips", false)
for _, fn in ipairs(ttCalls) do fn(tt, { id = 3396 }) end
eq("with the option off, nothing is appended", #lines, 0)
AltStable.SetConfigValue("professionsTooltips", nil)
lines = {}
for _, fn in ipairs(ttCalls) do fn(tt, { id = 424242 }) end
eq("an unrelated item gets nothing, not even a blank line", #lines, 0)

AltStable.IsCharacterHidden = realHidden2
AltStableRecipeData = savedData
T.ResetState()

------------------------------------------------------------
-- The panel builds and fills, and the wheel goes where the pointer is
------------------------------------------------------------

-- Anchored beside the sidebar's edge through the sheet's helper (#150), so
-- it follows a collapse. Declining here keeps the fixed-offset fallback.
local besideSidebar
AltStable.AnchorBesideSidebar = function(region) besideSidebar = region; return false end
readModelState()
-- The filter last picked comes back when the tab is built (#385).
eq("no saved filter is All", T.SavedFilter(), "all")
AltStableConfig.professionsFilter = "nonsense"
eq("  nor is one the tab doesn't have", T.SavedFilter(), "all")
AltStableConfig.professionsFilter = "known"
local main = CreateFrame("Frame", nil, UIParent)
local ok, err = pcall(function() plugin.OnActivate(main) end)
eq("a saved Known opens the tab on Known (#385)", AT.filter, "known")
eq("  and lists only what the alts know", ids(AT.rows or {}), "2329,2330,2331")
AT.filterButtons.all:GetScript("OnClick")(AT.filterButtons.all)
eq("picking All saves it", AltStableConfig.professionsFilter, "all")
eq("  and shows it", AT.filter, "all")
AT.filterButtons.missing:GetScript("OnClick")(AT.filterButtons.missing)
eq("picking another filter saves that one", AltStableConfig.professionsFilter, "missing")
AT.filterButtons.all:GetScript("OnClick")(AT.filterButtons.all)
AltStableConfig.professionsFilter = nil
check("the panel anchors beside the sidebar's edge (#150)", besideSidebar ~= nil)
check("  and re-lays out when the window changes size", type(plugin.OnResize) == "function")
AltStable.AnchorBesideSidebar = nil
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

-- Its size (#150): a preferred width asked for on opening, then a floor it
-- never had - so it opens the same whichever tab came before - and the floor
-- again when the window changes under it (the sidebar expanding).
do
    local calls = {}
    local heldReq, heldMin = AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize
    AltStable.RequestPluginSize = function(w) calls[#calls + 1] = "pref " .. w end
    AltStable.EnsureWindowMinSize = function(w, h) calls[#calls + 1] = "floor " .. w .. "x" .. h end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    plugin.OnActivate(main)
    eq("opening asks for the preferred width, then the floor",
       calls[1] .. "," .. tostring(calls[2]),
       "pref " .. AT.PREFERRED_PANEL_W .. ",floor " .. (sidebarW + 1 + AT.MIN_PANEL_W) .. "x" .. (titleH + 1 + AT.MIN_PANEL_H))
    check("  the preferred width holds a recipe row with its four names", AT.PREFERRED_PANEL_W >= 700)
    calls = {}
    plugin.OnResize()
    eq("a resize asks for the floor again", calls[1] and calls[1]:sub(1, 5), "floor")
    -- The Favor checkbox (#270) drives the same filter BuildRows takes.
    check("the Favor checkbox is built", AT.favorCheck ~= nil)
    if AT.favorCheck then
        AT.favorCheck:SetChecked(true)
        AT.favorCheck:GetScript("OnClick")(AT.favorCheck)
        check("  ticking it filters on Favor", AT.onlyFavor == true)
        local heldLine = AT.line
        AT.line = 171
        AT.Refresh()
        eq("  and the tab shows only what Favor buys", ids(AT.rows or {}), "2332")
        AT.line = heldLine
        AT.favorCheck:SetChecked(false)
        AT.favorCheck:GetScript("OnClick")(AT.favorCheck)
        check("  and unticking it lets everything back", AT.onlyFavor == false)
    end
    plugin.OnDeactivate(main)
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = heldReq, heldMin
end

------------------------------------------------------------
-- The wishlist (#271): a star per alt, on its own snapshot
------------------------------------------------------------

-- Alder is ours (scanned here), Birch is played on another account, Umber
-- was never scanned by the plugin.
local function wishState()
    readModelState()
    AltStableDB[A].scannedHere, AltStableDB[A].lastUpdate = true, 50
    AltStableDB[U].scannedHere = true
    AltStableProfessionsDB[A].stamp = 10
    AltStableProfessionsDB[A].profs[171].known = { [2329] = true }
end
local function wishes(guid)
    local e = AltStableProfessionsDB[guid]
    local t = {}
    for id in pairs(e and e.wish or {}) do t[#t + 1] = id end
    table.sort(t)
    return table.concat(t, ",")
end

wishState()
WoW.now = 1700000000
check("our own alt can be starred for", T.CanWish(A))
check("  not one played on another account", not T.CanWish(B))
check("  nor one the plugin has no snapshot of (an entry would say 'has no professions')", not T.CanWish(U))
check("starring a recipe it lacks", T.SetWish(A, 2332, true))
eq("  stores it on its snapshot", wishes(A), "2332")
eq("  under a new stamp, so peers take it", AltStableProfessionsDB[A].stamp, 1700000000)
check("  and it wants it", T.Wants(A, 2332))
eq("  without touching its Last Online: Alder is not the one being played", AltStableDB[A].lastUpdate, 50)
check("starring it again changes nothing", not T.SetWish(A, 2332, true))
eq("  not even the stamp", AltStableProfessionsDB[A].stamp, 1700000000)
check("a recipe it knows cannot be starred", not T.SetWish(A, 2329, true))
eq("  and is not stored", wishes(A), "2332")
check("a recipe on another account's alt cannot be starred here", not T.SetWish(B, 2332, true))
eq("  so its snapshot is untouched", AltStableProfessionsDB[B].wish, nil)
eq("  stamp included", AltStableProfessionsDB[B].stamp, 1)
check("nor one for an alt with no snapshot", not T.SetWish(U, 2332, true))
eq("  which gets none", AltStableProfessionsDB[U], nil)
AltStableProfessionsDB[U] = { profs = {} }   -- an entry not yet stamped is not a snapshot
check("  nor an entry without a stamp (stamping it would say 'has no professions')",
      not T.CanWish(U) and not T.SetWish(U, 2332, true))
eq("  which stays unstamped", AltStableProfessionsDB[U].stamp, nil)
AltStableProfessionsDB[U] = nil
check("a bad id is refused", not T.SetWish(A, "x", true))
WoW.now = 1700000005
check("unstarring", T.SetWish(A, 2332, false))
eq("  leaves no empty list behind", AltStableProfessionsDB[A].wish, nil)
eq("  and moves the stamp too", AltStableProfessionsDB[A].stamp, 1700000005)
check("unstarring what is not starred changes nothing", not T.SetWish(A, 2332, false))
eq("  not even the stamp", AltStableProfessionsDB[A].stamp, 1700000005)
T.SetWish(A, 2331, false)
eq("  with others starred neither", wishes(A), "")

-- The character being played: its record has to move, or the star never
-- rides a delta.
AltStableDB[ME] = { guid = ME, name = "Me", class = "MAGE", lastUpdate = 7, scannedHere = true }
AltStableProfessionsDB[ME] = { stamp = 3, profs = { [171] = { rank = 60, max = 75, full = 3, known = {} } } }
WoW.now = 1700000100
T.SetWish(ME, 2330, true)
eq("starring for the character being played marks it for the next sync", AltStableDB[ME].lastUpdate, 1700000100)

-- A snapshot that still holds a star on a known recipe (one from before it
-- was learned) shows no star.
AltStableProfessionsDB[B].wish = { [2329] = true, [2330] = true }
check("a starred recipe the alt knows is not wanted", not T.Wants(B, 2329))
check("  one it does not know is", T.Wants(B, 2330))
check("  one not starred is not", not T.Wants(B, 2331))
check("  nor anything for an alt with no snapshot", not T.Wants(U, 2330))
AltStableProfessionsDB[B].wish = { [7000] = true }
AltStableProfessionsDB[B].profs[197] = { rank = 50, max = 75, full = 1, known = { [7000] = true } }
check("  known through another of its professions counts too", not T.Wants(B, 7000))
AltStableProfessionsDB[B].profs[197] = nil

-- Cleared once learned: by a scan and by NEW_RECIPE_LEARNED.
fresh()
setAlchemy({ [2329] = { name = "A", learned = true }, [2330] = { name = "B", learned = false },
             [2331] = { name = "C", learned = false } })
T.RefreshOwnership()
T.OnShow(); WoW.flushTimers()
local mine = AltStableProfessionsDB[ME]
WoW.now = WoW.now + 10
check("a recipe it does not know yet is starred", T.SetWish(ME, 2330, true) and T.SetWish(ME, 2331, true))
WoW.tradeSkill.recipes[2330].learned = true
WoW.now = WoW.now + 10
local before = mine.stamp
T.ScheduleScan(); WoW.flushTimers()
eq("a scan that finds it learned clears its star", wishes(ME), "2331")
check("  under a new stamp", mine.stamp > before)
-- A star on a known recipe the store holds (an older client's snapshot of our
-- own alt): the next scan clears it, and that alone is a change.
mine.wish[2329] = true
WoW.now = WoW.now + 10
before = mine.stamp
T.ScheduleScan(); WoW.flushTimers()
eq("a scan with nothing new still clears a star on a known recipe", wishes(ME), "2331")
check("  and stamps it, so peers drop it too", mine.stamp > before)
T.OnClose()
T.OnRecipeLearned(2331)
eq("learning it with the window shut clears it too", mine.wish, nil)
check("  and it is known", mine.profs[171].known[2331])
mine.wish = { [2330] = true }
T.OnRecipeLearned(2331)
eq("a learned event for a recipe already known changes nothing", wishes(ME), "2330")

-- Sync: w= sits before p=, which every parser reads from the end.
fresh()
AltStableDB = { [ALT] = { guid = ALT, name = "Brewer" } }
AltStableProfessionsDB = { [ALT] = { stamp = 40, wish = { [2331] = true, [2330] = true },
    profs = { [171] = { rank = 60, max = 75, full = 40, known = { [2329] = true } } } } }
local wblob = T.SerializePlayer(ALT)
eq("the wishlist goes out, sorted, before p=", wblob, "v1|s=40|w=2330,2331|p=171:60:75:40:2329")
AltStableProfessionsDB[ALT].wish = {}
eq("an empty one is not sent at all", T.SerializePlayer(ALT), "v1|s=40|p=171:60:75:40:2329")
-- What a build before #271 makes of it: the same patterns its DeserializePlayer
-- and ParseProfs used. It reads the stamp and the recipes, and skips w=.
do
    local rest = wblob:match("^v1|(.*)$")
    eq("an older parser still reads the stamp", tonumber(rest:match("^s=(%d+)")), 40)
    local profStr = rest:match("|p=([^|]*)$")
    eq("  and the recipes", profStr, "171:60:75:40:2329")
    check("  which parse as before", T.ParseProfs(profStr) and T.ParseProfs(profStr)[171].known[2329])
end
AltStableProfessionsDB = {}
T.DeserializePlayer(ALT, wblob)
eq("received, the wishlist is stored", wishes(ALT), "2330,2331")
check("  with the recipes", AltStableProfessionsDB[ALT].profs[171].known[2329])
T.DeserializePlayer(ALT, "v1|s=41|p=171:60:75:41:2329")
eq("a newer snapshot without w= has no wishes: the owner unstarred them", AltStableProfessionsDB[ALT].wish, nil)
T.DeserializePlayer(ALT, "v1|s=42|w=|p=171:60:75:42:2329")
eq("an empty w= is no wishes", AltStableProfessionsDB[ALT].wish, nil)
eq("  and the snapshot is taken", AltStableProfessionsDB[ALT].stamp, 42)
T.DeserializePlayer(ALT, "v1|s=43|w=2330,x|p=171:60:75:43:2329")
eq("a malformed w= keeps what we have", AltStableProfessionsDB[ALT].stamp, 42)
T.DeserializePlayer(ALT, "v1|s=44|w=0x10|p=171:60:75:44:2329")
eq("  hex included", AltStableProfessionsDB[ALT].stamp, 42)
T.DeserializePlayer(ALT, "v1|s=45|w=2332|p=171:60:75:45:2329")
eq("a valid one after it is taken", wishes(ALT), "2332")
eq("ParseWish: none", T.ParseWish("s=1|p="), nil)

-- Through the core, both ways, and a relay hop.
ownerState(100, 1000, { [2329] = true })
AltStableProfessionsDB[ALT].wish = { [2331] = true }
local wA = send(0)
local wbDB, wbPDB = {}, {}
receive(wA, wbDB, wbPDB)
eq("through the core, the alt's wishlist arrives", wbPDB[ALT] and wbPDB[ALT].wish and wbPDB[ALT].wish[2331], true)
AltStableDB, AltStableProfessionsDB = wbDB, wbPDB
local wB = send(500)
local wcDB, wcPDB = {}, {}
receive(wB, wcDB, wcPDB)
eq("  and one relay hop later", wcPDB[ALT] and wcPDB[ALT].wish and wcPDB[ALT].wish[2331], true)

-- The rows: who wants each, the Wishlist filter, the star.
wishState()
AltStableProfessionsDB[A].wish = { [2332] = true }
AltStableProfessionsDB[B].wish = { [2331] = true, [2332] = true }
eq("Wishlist: what anyone wants", ids(T.BuildRows({ line = 171, filter = "wishlist" })), "2331,2332")
eq("  focused on Alder, only Alder's", ids(T.BuildRows({ line = 171, filter = "wishlist", focus = A })), "2332")
eq("  focused on Umber, nothing", ids(T.BuildRows({ line = 171, filter = "wishlist", focus = U })), "")
-- A search spans every profession, also ones the selected alt does not have:
-- there the selected alt is still the one whose stars are listed.
do
    local SMITH = "Player-Smith"
    AltStableDB[SMITH] = { guid = SMITH, name = "Smith", class = "WARRIOR" }
    AltStableProfessionsDB[SMITH] = { stamp = 1, wish = { [3101] = true },
        profs = { [164] = { rank = 40, max = 75, full = 1, known = { [3100] = true } } } }
    local heldNames = WoW.spellNames
    WoW.spellNames = { [2332] = "Copper Elixir", [3101] = "Rough Copper Vest" }
    for k in pairs(T.names) do T.names[k] = nil end
    eq("a search with Alder selected lists Alder's stars only, across professions",
       ids(T.BuildRows({ line = 171, search = "copper", filter = "wishlist", focus = A })), "2332")
    eq("  with nobody selected, everyone's", ids(T.BuildRows({ line = 171, search = "copper", filter = "wishlist" })),
       "3101,2332")
    WoW.spellNames = heldNames
    for k in pairs(T.names) do T.names[k] = nil end
    AltStableDB[SMITH], AltStableProfessionsDB[SMITH] = nil, nil
end
local wrows = {}
for _, r in ipairs(T.BuildRows({ line = 171 })) do wrows[r.id] = r end
local function names(list) local t = {} for _, o in ipairs(list or {}) do t[#t + 1] = o.name end return table.concat(t, ",") end
eq("each row says who wants it", names(wrows[2332].wantedBy), "Alder,Birch")
eq("  one nobody wants, nobody", names(wrows[2330].wantedBy), "")
local fr = {}
for _, r in ipairs(T.BuildRows({ line = 171, focus = A })) do fr[r.id] = r end
local function star(r) local s, c = T.StarState(r); return tostring(s) .. "/" .. tostring(c) end
eq("Alder in focus, a recipe it wants: a lit star it can clear", star(fr[2332]), "on/true")
eq("  one it lacks: an unlit star to click", star(fr[2330]), "off/true")
eq("  one it knows: no star", star(fr[2329]), "nil/false")
local br = {}
for _, r in ipairs(T.BuildRows({ line = 171, focus = B })) do br[r.id] = r end
eq("Birch (another account) in focus, a recipe it wants: lit, not clickable", star(br[2331]), "on/false")
eq("  one it lacks: nothing to click here", star(br[2330]), "nil/false")
eq("no focus, a recipe someone wants: lit, not clickable", star(wrows[2331]), "on/false")
eq("  one nobody wants: no star", star(wrows[2330]), "nil/false")

-- Clicking: through the button's script, as the client calls it.
local function starButton(r) return { GetParent = function() return { row = r } end } end
T.StarOnClick(starButton(fr[2330]))
eq("a click on an unlit star stars it for the alt in focus", wishes(A), "2330,2332")
T.StarOnClick(starButton(fr[2332]))
eq("a click on a lit one clears it", wishes(A), "2330")
T.StarOnClick(starButton(br[2331]))
eq("a click on another account's alt's star does nothing", wishes(B), "2331,2332")
T.StarOnClick(starButton(wrows[2331]))
eq("  nor one with nobody in focus", wishes(A) .. ";" .. wishes(B), "2330;2331,2332")
T.StarOnClick(starButton(fr[2329]))
eq("  nor one on a known recipe", wishes(A), "2330")
local okNil = pcall(T.StarOnClick, starButton(nil))
check("  nor a button with no row", okNil)

local function hover(r)
    WoW.tooltipLines = {}
    T.StarOnEnter(starButton(r))
    return (table.concat(WoW.tooltipLines, " / "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
check("the star's tooltip says who wants it", hover(wrows[2332]):find("Wanted by|Alder, Birch", 1, true), hover(wrows[2332]))
check("  and, with nobody in focus, how to star", hover(wrows[2330]):find("Pick an alt's card", 1, true))
check("  with an alt of ours in focus, what a click does", hover(fr[2332]):find("Click: wanted by Alder", 1, true),
      hover(fr[2332]))
check("  and on one it starred, that a click clears it",
      hover(fr[2330]):find("Click: no longer wanted by Alder", 1, true), hover(fr[2330]))
check("  on another account's alt, where to star it", hover(br[2330]):find("another account", 1, true))
check("  on a known recipe, that it is known", hover(fr[2329]):find("Alder knows it", 1, true))

-- With no card selected, the star is the played character's where it has the
-- profession (#365); elsewhere it only shows that someone wants the recipe.
do
    local heldDB, heldPDB = {}, {}
    for k, v in pairs(AltStableDB) do heldDB[k] = v end
    for k, v in pairs(AltStableProfessionsDB) do heldPDB[k] = v end
    AltStableDB[ME] = { guid = ME, name = "Mira", class = "MAGE", scannedHere = true, lastUpdate = 1 }
    AltStableProfessionsDB[ME] = { stamp = 5, profs = { [171] = { rank = 30, max = 75, full = 5,
        known = { [2329] = true, [2331] = true } } } }
    AltStableProfessionsDB[A].wish = { [2331] = true }
    local mr = {}
    for _, r in ipairs(T.BuildRows({ line = 171 })) do mr[r.id] = r end
    eq("no card selected: a recipe the played character lacks has a star to click", star(mr[2330]), "off/true")
    T.StarOnClick(starButton(mr[2330]))
    eq("  and the click stars it for that character", wishes(ME), "2330")
    eq("  which lights it", star(mr[2330]), "on/true")
    check("  its tooltip says for whom", hover(mr[2330]):find("Click: no longer wanted by Mira", 1, true), hover(mr[2330]))
    eq("  one it knows that someone else wants still shows lit, not clickable", star(mr[2331]), "on/false")
    eq("  one it knows that nobody wants, no star", star(mr[2329]), "nil/false")
    local sr = {}
    for _, r in ipairs(T.BuildRows({ line = 171, search = "", focus = B })) do sr[r.id] = r end
    eq("a card selected: its alt's star, not the played character's", star(sr[2330]), "nil/false")
    -- A search with a card selected reaches lines its alt lacks: no star there,
    -- not the played character's, not anyone's.
    local other = { id = 3101, owners = { { guid = ME, known = {} } }, wantedBy = { { name = "X" } }, selected = B }
    eq("  on a line its alt lacks, nothing", star(other), "nil/false")
    T.StarOnClick(starButton(other))
    eq("  and a click there stars nothing", wishes(ME), "2330")
    AltStableDB, AltStableProfessionsDB = heldDB, heldPDB
end

-- The item tooltip: Wanted by, above Known by.
do
    local savedData2 = AltStableRecipeData
    AltStableRecipeData = { source = "wish tooltip test", recipes = {
        [2331] = { skill = { 171 }, learn = 50, makes = 2455, items = { 3396 } },
    } }
    T.ResetState()
    wishState()
    AltStableProfessionsDB[A].profs[171].known[2331] = nil
    AltStableProfessionsDB[A].wish = { [2331] = true }
    AltStableProfessionsDB[B].wish = { [2331] = true }
    local plain = function(x) return (x:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local function labels()
        local t = {}
        for _, l in ipairs(T.TooltipLines(3396)) do t[#t + 1] = plain(l[1]) .. "=" .. plain(l[2]) end
        return table.concat(t, "; ")
    end
    check("a recipe item says who wants it", labels():find("Wanted by=Alder, Birch", 1, true), labels())
    check("  above Known by and the skill lines", labels():find("^Wanted by="), labels())
    AltStableProfessionsDB[B].profs[171].known[2331] = true
    check("  never naming an alt that knows it", labels():find("Wanted by=Alder;", 1, true), labels())
    local realHidden3 = AltStable.IsCharacterHidden
    AltStable.IsCharacterHidden = function(guid) return guid == A end
    check("  nor a hidden one", not labels():find("Wanted by", 1, true), labels())
    AltStable.IsCharacterHidden = realHidden3
    check("the option is on by default", T.WishTooltipOn())
    AltStable.SetConfigValue("professionsWishTooltip", false)
    check("turned off, the line goes", not labels():find("Wanted by", 1, true), labels())
    check("  and the rest stays", labels():find("Known by=Birch", 1, true), labels())
    AltStable.SetConfigValue("professionsWishTooltip", nil)
    AltStableRecipeData = savedData2
    T.ResetState()
end

-- In the tab: the Wishlist button, the stars drawn, and the row's tooltip.
do
    wishState()
    AltStableProfessionsDB[A].wish = { [2332] = true }
    local hasWish = false
    for _, f in ipairs(T.FILTERS) do if f[1] == "wishlist" then hasWish = f[2] == "Wishlist" end end
    check("there is a Wishlist filter", hasWish)
    local heldReq, heldMin = AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = nil, nil
    plugin.OnActivate(main)
    AT.line, AT.focus, AT.search, AT.filter, AT.onlyDrops, AT.onlyFavor = 171, A, "", "all", false, false
    AT.Refresh()
    local b = AT.filterButtons.wishlist
    check("  as a button in the tab", b ~= nil)
    if b then
        b:GetScript("OnClick")(b)
        eq("  which filters on it", ids(AT.rows or {}), "2332")
    end
    local w = AT.rowsPool[1]
    check("the row draws a lit star", w and w.star and w.star.tex:IsShown()
          and w.star.tex._atlas == "auctionhouse-icon-favorite", w and w.star and tostring(w.star.tex._atlas))
    eq("  at full strength, since a click clears it", w and w.star.tex:GetAlpha(), 1)
    AT.filter = "all"; AT.Refresh()
    local drawn = {}
    for _, row in ipairs(AT.rowsPool) do
        if row:IsShown() and row.row then drawn[row.row.id] = row end
    end
    check("an unlit star where one could be clicked", drawn[2330] and drawn[2330].star.tex:IsShown()
          and drawn[2330].star.tex._atlas == "auctionhouse-icon-favorite-off")
    check("  none on a known recipe", drawn[2329] and not drawn[2329].star.tex:IsShown())
    if drawn[2330] then
        drawn[2330].star:GetScript("OnClick")(drawn[2330].star)
        eq("clicking the drawn star stars it", wishes(A), "2330,2332")
        local again = {}
        for _, row in ipairs(AT.rowsPool) do if row:IsShown() and row.row then again[row.row.id] = row end end
        check("  and the tab redraws it lit", again[2330] and again[2330].star.tex._atlas == "auctionhouse-icon-favorite")
    end
    if drawn[2332] then
        WoW.tooltipLines = {}
        drawn[2332]:GetScript("OnEnter")(drawn[2332])
        local text = (table.concat(WoW.tooltipLines, " / "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        check("the row's tooltip says who wants it", text:find("Wanted by|Alder", 1, true), text)
    end
    -- The selected card says where another account's alt is starred (#365).
    local function cardText(guid)
        for _, c in ipairs(AT.cards) do
            if c:IsShown() and c.data and c.data.owner.guid == guid then return c.l3:GetText() or "" end
        end
    end
    AT.focus = B; AT.Refresh()
    check("another account's alt, selected: its card says stars are set there",
          (cardText(B) or ""):find("Stars: on its own account", 1, true), tostring(cardText(B)))
    eq("  ours, selected, says nothing of the sort", cardText(A), "")
    AT.focus = A; AT.Refresh()
    eq("  nor theirs once it is not selected", cardText(B), "")
    eq("  nor ours selected", cardText(A), "")
    AT.focus = nil
    plugin.OnDeactivate(main)
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = heldReq, heldMin
end

------------------------------------------------------------
-- The detail pane (#269)
------------------------------------------------------------

do
    readModelState()
    AltStableDB[A].level, AltStableDB[B].level = 40, 10
    local savedRecipe = AltStableRecipeData.recipes[2331]
    AltStableRecipeData.recipes[2331] = { skill = { 171 }, learn = 50, colors = { 50, 80, 100, 120 }, makes = 2455,
                                          src = { 2 }, items = { 3396 }, reagents = { 785, 2, 3371, 1 } }
    WoW.items[2455] = { name = "Elixir of Lesser Agility", quality = 2, minLevel = 15, icon = 134830 }
    WoW.items[3396] = { name = "Recipe: Elixir of Lesser Agility", quality = 2 }
    WoW.spellNames = { [2331] = "Elixir of Lesser Agility" }
    for k in pairs(T.names) do T.names[k] = nil end
    local plain = function(x) return (tostring(x):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local function detail(focus, id)
        for _, r in ipairs(T.BuildRows({ line = 171, focus = focus })) do
            if r.id == (id or 2331) then return T.DetailLines(r), r end
        end
    end
    local function field(d, label)
        for _, l in ipairs(d.lines) do if plain(l[1]) == label then return l[2] and plain(l[2]) or "" end end
    end
    local function has(d, text)
        for _, l in ipairs(d.lines) do
            if plain(l[1]):find(text, 1, true) or (l[2] and plain(l[2]):find(text, 1, true)) then return true end
        end
        return false
    end

    local d = detail(B)
    eq("the pane names what it makes, in its quality's colour", d.title, "|cff1eff00Elixir of Lesser Agility|r")
    check("  with its link, to shift-click into chat", d.link and d.link:find("item:2455", 1, true))
    eq("  and its icon", d.icon, 134830)
    eq("the level to use it, against the alt in focus: Birch is below it", field(d, "Use"), "level 15  (Birch is 10)")
    check("  in red", (d.lines[1][2] or ""):find("|cffff4040", 1, true))
    eq("  Alder is not: just the level", field(detail(A), "Use"), "level 15")
    eq("  with nobody in focus: just the level", field(detail(nil), "Use"), "level 15")
    eq("the skill to learn it", field(d, "Requires"), "50")
    eq("the colour thresholds", field(d, "Difficulty"), "50  80  100  120")
    eq("where the focused alt stands", field(d, "Birch"), "60, orange")
    eq("  Alder", field(detail(A), "Alder"), "120, grey")
    eq("  nothing without a focus", field(detail(nil), "Alder"), nil)
    eq("where it comes from", field(d, "Source"), "Drop")
    eq("the recipe item that teaches it", field(d, "Recipe"), "Recipe: Elixir of Lesser Agility")
    eq("who knows it, in full", field(d, "Known by"), "Alder")
    eq("who meets the skill", field(d, "Meets skill"), "Birch (60)")
    eq("whom it cannot speak for", field(d, "Not scanned"), "Umber")
    check("  and that only the skill is checked", has(d, "Specialisation, reputation and quest"))
    check("its reagents", has(d, "Reagents"))
    eq("nobody wants it: no line", field(d, "Wanted by"), nil)
    AltStableProfessionsDB[B].wish = { [2331] = true }
    eq("who wants it (#271)", field(detail(B), "Wanted by"), "Birch")
    AltStableProfessionsDB[B].wish = nil
    local low = detail(U)
    check("an unscanned focus gets no verdict of its own", low ~= nil)
    WoW.items[2455].minLevel = 1
    eq("an item anyone can use has no level line", field(detail(B), "Use"), nil)
    WoW.items[2455].minLevel = 15
    local d2 = detail(nil, 2332)
    eq("a recipe nobody knows says so", has(d2, "Nobody recorded"), true)

    -- Not in the client's cache yet: asked for once, and said to be loading.
    WoW.items[2455] = nil
    WoW.itemLoadRequests = {}
    for k in pairs(T.itemInfoAsked) do T.itemInfoAsked[k] = nil end
    d = detail(B)
    eq("an item the client has not loaded: loading", field(d, "Use"), "loading...")
    eq("  the name falls back to the recipe's", plain(d.title), "Elixir of Lesser Agility")
    eq("  no link to offer", d.link, nil)
    detail(B)
    local asked = 0
    for _, id in ipairs(WoW.itemLoadRequests) do if id == 2455 then asked = asked + 1 end end
    eq("  its load asked for once, not on every redraw", asked, 1)
    WoW.items[2455] = { name = "Elixir of Lesser Agility", quality = 2, minLevel = 15, icon = 134830 }

    -- In the tab: a click opens it, the list gives up its last two columns.
    local heldReq, heldMin = AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = nil, nil
    plugin.OnActivate(main)
    AT.line, AT.focus, AT.search, AT.filter, AT.onlyDrops, AT.onlyFavor = 171, B, "", "all", false, false
    AT.selected = nil
    AT.Refresh()
    local pane = T.Pane()
    check("the pane is built, closed", pane ~= nil and not pane:IsShown())
    local function shownRow(id)
        for _, w in ipairs(AT.rowsPool) do if w:IsShown() and w.row and w.row.id == id then return w end end
    end
    local w = shownRow(2331)
    check("  the list has its Source and Known-by columns", w and w.source:IsShown() and w.known:IsShown())
    w:GetScript("OnClick")(w)
    check("a click on a row opens the pane", pane:IsShown())
    eq("  on that recipe", plain(pane.title:GetText()), "Elixir of Lesser Agility")
    w = shownRow(2331)
    check("  the row is marked", w and w.sel:IsShown())
    check("  another is not", shownRow(2329) and not shownRow(2329).sel:IsShown())
    check("  the list drops Source and Known by", w and not w.source:IsShown() and not w.known:IsShown())
    local _, rel = w:GetPoint(2)
    eq("  and ends where the pane starts", rel, pane)
    local lineTexts = {}
    for _, p in ipairs(pane.lines) do if p.l:IsShown() then lineTexts[#lineTexts + 1] = plain(p.l:GetText()) end end
    check("  its lines are drawn", table.concat(lineTexts, ","):find("Requires", 1, true) ~= nil, table.concat(lineTexts, ","))

    -- Longer than the pane: at the tab's 400 px floor its body is 206 px
    -- (400 - 134 above the rows - 10 below - 46 header - 4), and every line
    -- must still be reachable, by the wheel over the pane (Codex review of #367).
    do
        local VIEW = AT.MIN_PANEL_H - 134 - 10 - 46 - 4
        eq("  (the floor this case stands for)", VIEW, 206)
        local body = pane.body
        body.GetHeight = function() return VIEW end
        local lineH = 13   -- the stubs' 10 px strings, and the 3 px gap
        AT.paneOffset = 0
        AT.Refresh()
        local function topOf(i) local _, _, _, _, y = pane.lines[i].l:GetPoint(1); return -y end
        local last = 0
        for i, p in ipairs(pane.lines) do if p.l:IsShown() then last = i end end
        check("a long recipe at the floor runs past the pane", AT.paneMax and AT.paneMax > 0, tostring(AT.paneMax))
        check("  its last line starts out of view", topOf(last) > VIEW - lineH, tostring(topOf(last)))
        check("  and a bar says there is more", pane.thumb:IsShown())
        local wheel = pane:GetParent():GetScript("OnMouseWheel")
        local heldOver = pane.IsMouseOver
        pane.IsMouseOver = function() return true end
        AT.scrollRow = 0
        wheel(pane:GetParent(), -1)
        check("the wheel over the pane scrolls it", AT.paneOffset > 0 and topOf(1) < 0, tostring(AT.paneOffset))
        eq("  not the list", AT.scrollRow, 0)
        for _ = 1, 50 do wheel(pane:GetParent(), -1) end
        eq("  as far as there is, no further", AT.paneOffset, AT.paneMax)
        check("  where its last line is in view", topOf(last) >= 0 and topOf(last) <= VIEW - lineH,
              tostring(topOf(last)))
        local _, _, _, _, ty = pane.thumb:GetPoint(1)
        check("  the bar at the bottom", ty < 0)
        AT.Refresh()
        eq("a redraw keeps the place", AT.paneOffset, AT.paneMax)
        for _ = 1, 50 do wheel(pane:GetParent(), 1) end
        eq("back up, to the top and no further", AT.paneOffset, 0)
        eq("  the first line at the top", topOf(1), 0)
        pane.IsMouseOver = function() return false end
        wheel(pane:GetParent(), -1)
        eq("the wheel elsewhere scrolls the list, not the pane", AT.paneOffset, 0)
        pane.IsMouseOver = heldOver
        body.GetHeight = function() return 40 end   -- so short that any recipe overflows
        AT.paneOffset = 30
        AT.Refresh()
        eq("  (scrolled down)", AT.paneOffset, 30)
        local other = shownRow(2329)
        other:GetScript("OnClick")(other)
        check("  (the other one overflows too)", AT.paneMax > 30, tostring(AT.paneMax))
        eq("another recipe opens at its top", AT.paneOffset, 0)
        shownRow(2331):GetScript("OnClick")(shownRow(2331))
        body.GetHeight = function() return 5000 end
        AT.Refresh()
        check("one that fits: no bar", not pane.thumb:IsShown() and AT.paneMax == 0)
        body.GetHeight = nil
    end

    -- Shift-click on the name: the game's own handler, with the item's link.
    local linked
    local heldHandle = rawget(_G, "HandleModifiedItemClick")
    rawset(_G, "HandleModifiedItemClick", function(link) linked = link end)
    pane.head:GetScript("OnClick")(pane.head)
    check("a click on the name hands its link to the game (shift-click links it)",
          linked and linked:find("item:2455", 1, true), tostring(linked))
    rawset(_G, "HandleModifiedItemClick", heldHandle)
    WoW.tooltipLines = {}
    pane.head:GetScript("OnEnter")(pane.head)
    check("hovering it shows the item", WoW.tooltipShown)

    -- The pane's star stars it for the alt in focus, as the row's does.
    AltStableDB[A].scannedHere = true
    AT.focus = A; AT.Refresh()
    AltStableProfessionsDB[A].profs[171].known[2331] = nil
    AT.Refresh()
    check("the pane's star can be clicked for Alder", pane.star.tex:IsShown()
          and pane.star.tex._atlas == "auctionhouse-icon-favorite-off", tostring(pane.star.tex._atlas))
    pane.star:GetScript("OnClick")(pane.star)
    check("  and stars it", AltStableProfessionsDB[A].wish and AltStableProfessionsDB[A].wish[2331])
    eq("  lit", pane.star.tex._atlas, "auctionhouse-icon-favorite")
    check("  and the pane stays open on it", pane:IsShown() and AT.selected and AT.selected.id == 2331)

    -- An item the pane asked for arrives: it redraws. One it never asked for does not.
    local refreshes = 0
    local heldRR = AT.RequestRefresh
    AT.RequestRefresh = function() refreshes = refreshes + 1 end
    T.itemInfoAsked[777001] = true
    eventFrame._scripts.OnEvent(eventFrame, "GET_ITEM_INFO_RECEIVED", 777001, true)
    eq("an item the pane asked for redraws it", refreshes, 1)
    eventFrame._scripts.OnEvent(eventFrame, "GET_ITEM_INFO_RECEIVED", 777002, true)
    eq("  one it did not, nothing", refreshes, 1)
    AT.selected = nil
    eventFrame._scripts.OnEvent(eventFrame, "GET_ITEM_INFO_RECEIVED", 777001, true)
    eq("  nor with the pane closed", refreshes, 1)
    AT.selected = { id = 2331, line = 171 }
    AT.RequestRefresh = heldRR
    T.itemInfoAsked[777001] = nil
    AT.Refresh()

    -- Closing: the same row again, the close button, or a filter that drops it.
    w = shownRow(2331)
    w:GetScript("OnClick")(w)
    check("a second click on the row closes it", not pane:IsShown() and AT.selected == nil)
    w = shownRow(2331)
    check("  and the columns come back", w and w.source:IsShown() and w.known:IsShown() and not w.sel:IsShown())
    w:GetScript("OnClick")(w)
    pane.close:GetScript("OnClick")(pane.close)
    check("the close button closes it", not pane:IsShown() and AT.selected == nil)
    w = shownRow(2331)
    w:GetScript("OnClick")(w)
    shownRow(2329):GetScript("OnClick")(shownRow(2329))
    eq("a click on another row moves it there", AT.selected and AT.selected.id, 2329)
    AT.filter = "nobody"; AT.Refresh()
    check("a filter that drops the open recipe closes it", not pane:IsShown() and AT.selected == nil)
    AT.filter = "all"
    AT.focus = nil
    plugin.OnDeactivate(main)
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = heldReq, heldMin
    AltStableRecipeData.recipes[2331] = savedRecipe
    WoW.items[2455], WoW.items[3396] = nil, nil
    for k in pairs(T.names) do T.names[k] = nil end
end

------------------------------------------------------------
-- Forget / cleanup
------------------------------------------------------------

AltStableProfessionsDB = { [A] = { stamp = 1, profs = {} }, [B] = { stamp = 1, profs = {} } }
plugin.OnForget(A)
eq("forgetting a character drops its recipes", AltStableProfessionsDB[A], nil)
plugin.OnCleanup(B)
check("cleanup keeps only the named character", AltStableProfessionsDB[B] ~= nil and next(AltStableProfessionsDB, nil) == B)

WoW.finish("test_professions", passed, failed)
