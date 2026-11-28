------------------------------------------------------------
-- test_cooldowns.lua - the Cooldowns view's data side (#543)
--
-- Cooldowns.lua: parsing cd_<Profession>@<label> fields, a column per
-- cooldown with an id the settings sync accepts, who is listed, the ready
-- count, the countdown text, the cell and the login-toast note. The view
-- itself is in test_sheetui.lua.
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

local function plain(s)
    return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
dofile("Reputations.lua")
dofile("LegacyTalents.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("Cooldowns.lua")
local CD = AltStable.Cooldowns
local NOW = WoW.now

-- Parse: on the first "@", the rest kept.
do
    local p, l = CD.Parse("cd_Tailoring@Mooncloth")
    eq("a field's profession", p, "Tailoring")
    eq("  and its label", l, "Mooncloth")
    p, l = CD.Parse("cd_Alchemy@A@B")
    eq("split on the first @: profession", p, "Alchemy")
    eq("  the label keeps the rest", l, "A@B")
    eq("not a cooldown field", CD.Parse("prof_Alchemy"), nil)
    eq("no label", CD.Parse("cd_Alchemy@"), nil)
    eq("not a string", CD.Parse(42), nil)
end

-- Column ids: what the settings sync takes, from the key alone.
do
    local id = CD.ColumnId("cd_Leatherworking@Salt Shaker")
    check("an id is letters, digits and _", id:match("^[%w_]+$") ~= nil, id)
    check("  readable", id:find("^cd_Leatherworking_Salt_Shaker_") ~= nil, id)
    check("  a setting key the sync accepts", AltStable.GoodColumnKey("cooldowns." .. id))
    eq("  the same key, the same id", CD.ColumnId("cd_Leatherworking@Salt Shaker"), id)
    check("A-B and A B differ", CD.ColumnId("cd_X@A-B") ~= CD.ColumnId("cd_X@A B"))
    local long = CD.ColumnId("cd_Alchemy@" .. string.rep("Transmute ", 20))
    check("a long label still fits", #("cooldowns." .. long) <= 64, #long)
    check("  and syncs", AltStable.GoodColumnKey("cooldowns." .. long))
end

-- Columns: made once, looked up by field, the item's icon or the profession's.
do
    WoW.items[15846] = { icon = 133849 }
    local col = CD.Column("cd_Leatherworking@Salt Shaker")
    eq("a column's label is the cooldown", col.label, "Salt Shaker")
    eq("  its field is the id", col.field, CD.ColumnId("cd_Leatherworking@Salt Shaker"))
    eq("  it reads the raw key", col.cdKey, "cd_Leatherworking@Salt Shaker")
    eq("  type", col.type, "cooldown")
    eq("  the item's icon", col.cdIcon, 133849)
    eq("  made once", CD.Column("cd_Leatherworking@Salt Shaker"), col)
    eq("  a short name: 140 wide", col.width, 140)
    check("  a long one wide enough for its name", CD.Column("cd_Alchemy@Mithril to Truesilver").width >= 40 + 7 * 21)
    eq("  never wider than 220", CD.Column("cd_Alchemy@" .. string.rep("X", 60)).width, 220)
    eq("  found by its field", CD.ColumnForField(col.field), col)
    eq("  the soonest first on a first click", col.sortFirstAsc, true)
    eq("an unknown cooldown has its profession's icon", CD.Column("cd_Tailoring@Spellcloth").cdIcon,
       "Interface\\Icons\\Trade_Tailoring")
    eq("a profession with no column: the question mark", CD.Column("cd_Jewelcrafting@Gem").cdIcon,
       "Interface\\Icons\\INV_Misc_QuestionMark")
    eq("not a cooldown: no column", CD.Column("prof_Alchemy"), nil)
    -- Sorted by what is left: ready is 0, none is nil (last).
    eq("sort value: running", col.sortValue({ ["cd_Leatherworking@Salt Shaker"] = NOW + 90 }), 90)
    eq("sort value: ready", col.sortValue({ ["cd_Leatherworking@Salt Shaker"] = NOW - 5 }), 0)
    eq("sort value: none", col.sortValue({}), nil)
end

-- Who is listed, what is found, what is ready.
do
    local store = {
        a = { name = "Ann", ["cd_Tailoring@Mooncloth"] = NOW + 600, ["cd_Alchemy@Transmute"] = NOW - 1 },
        b = { name = "Bob", ["cd_Leatherworking@Salt Shaker"] = NOW },
        c = { name = "Cy", prof_Alchemy = 300 },                         -- no cooldown
        d = { name = "Di", ["cd_Tailoring@Spellcloth"] = NOW - 100 },    -- hidden below
        e = { ["cd_Engineering@Orphan"] = NOW - 100 },                    -- no name
        f = "not a record",
    }
    local function shown(c) return c.name ~= "Di" end
    local keys = CD.KeysInUse(store, shown)
    eq("found: by profession, then label", table.concat(keys, ","),
       "cd_Alchemy@Transmute,cd_Leatherworking@Salt Shaker,cd_Tailoring@Mooncloth")
    eq("  everyone's with no filter", #CD.KeysInUse(store), 4)
    check("a character with a cooldown is listed", CD.Listed(store.a, shown))
    check("  one without is not", not CD.Listed(store.c, shown))
    check("  a hidden one is not", not CD.Listed(store.d, shown))
    check("  a nameless record is not", not CD.Listed(store.e, shown))
    check("  nor a value that isn't a record", not CD.Listed(store.f, shown))
    eq("ready: Ann's transmute and Bob's Shaker (expiry now)", CD.ReadyCount(store, shown, NOW), 2)
    eq("  Di's counts once shown", CD.ReadyCount(store, nil, NOW), 3)
    eq("  later, Ann's Mooncloth too", CD.ReadyCount(store, shown, NOW + 600), 3)
    check("HasAny ignores a non-number", not CD.HasAny({ name = "X", ["cd_Tailoring@Mooncloth"] = "soon" }))
end

-- The countdown.
do
    eq("days and hours", CD.Format(86400 + 4 * 3600 + 59), "1d 4h")
    eq("whole days", CD.Format(2 * 86400 + 59), "2d")
    eq("hours and minutes", CD.Format(6 * 3600 + 12 * 60 + 5), "6h 12m")
    eq("an hour on the dot", CD.Format(3600), "1h 0m")
    eq("minutes and seconds", CD.Format(38 * 60 + 12), "38m 12s")
    eq("seconds", CD.Format(45), "45s")
    eq("nothing left", CD.Format(0), "0s")
    eq("never negative", CD.Format(-30), "0s")
    eq("a fraction down", CD.Format(59.9), "59s")
end

-- The cell: up, running, nothing recorded.
do
    local char = { name = "Ann", ["cd_Alchemy@Transmute"] = NOW + 3600, ["cd_Tailoring@Mooncloth"] = NOW - 1,
                   ["cd_Alchemy@Transmutes"] = 0 }
    local text = CD.Cell(char, "cd_Tailoring@Mooncloth", NOW)
    local l1, l2, l3 = CD.Tip(char, "cd_Tailoring@Mooncloth", NOW)
    check("ready: Available", text:find("Available", 1, true) ~= nil, text)
    check("  with the check mark", text:find("ReadyCheck-Ready", 1, true) ~= nil, text)
    eq("  tooltip title", l1, "Mooncloth (Tailoring)")
    eq("  and Ready", l2, "Ready")
    eq("  no note without the Recipe Book", l3, nil)
    check("0, seen ready and never cast (#545): Available", CD.Cell(char, "cd_Alchemy@Transmutes", NOW):find("Available", 1, true) ~= nil)
    eq("  at no time left", CD.Remaining(char, "cd_Alchemy@Transmutes", NOW), 0)
    text = CD.Cell(char, "cd_Alchemy@Transmute", NOW)
    l1, l2 = CD.Tip(char, "cd_Alchemy@Transmute", NOW)
    eq("running: the countdown", text, "1h 0m")
    eq("  when it comes up", l2, "Ready " .. date("%a %H:%M", NOW + 3600))
    text = CD.Cell(char, "cd_Leatherworking@Salt Shaker", NOW)
    l1, l2 = CD.Tip(char, "cd_Leatherworking@Salt Shaker", NOW)
    check("none: a dash", text:find("\226\128\148", 1, true) ~= nil, text)
    eq("  said so", l2, "No recorded cooldown")
    eq("  titled all the same", l1, "Salt Shaker (Leatherworking)")
    check("the empty text without the Recipe Book says to enable it",
          CD.EmptyText():find("Enable the Recipe Book", 1, true) ~= nil, CD.EmptyText())
end

-- The note: the toast's own rule.
do
    AltStableConfig.toastsEnabled, AltStableConfig.toastProfessions = nil, nil
    local text, lines = CD.ToastNote({ "Alchemy", "Leatherworking" })
    check("unset: on", text:find("on", 1, true) ~= nil and not text:find("off", 1, true), text)
    eq("  a line per profession", #lines, 2)
    eq("  named", lines[2][1], "Leatherworking")
    check("  on", lines[2][2]:find("on", 1, true) ~= nil)
    AltStableConfig.toastProfessions = { Leatherworking = false }
    text, lines = CD.ToastNote({ "Alchemy", "Leatherworking" })
    check("one off: some professions", text:find("some professions", 1, true) ~= nil, text)
    check("  Leatherworking off", lines[2][2]:find("off", 1, true) ~= nil)
    text = CD.ToastNote({ "Leatherworking" })
    check("every shown one off: off", text:find("off", 1, true) ~= nil, text)
    AltStableConfig.toastProfessions = nil
    AltStableConfig.toastsEnabled = false
    text = CD.ToastNote({ "Alchemy" })
    check("toasts off: off", text:find("off", 1, true) ~= nil, text)
    AltStableConfig.toastsEnabled = nil
    text = CD.ToastNote({})
    check("nothing shown: on", text:find("on", 1, true) ~= nil and not text:find("off", 1, true), text)
    eq("the rule is Toasts.lua's", AltStable.IsToastEnabled ~= nil, true)
end

-- With the Recipe Book (#545): its catalogue and standings, as the plugin
-- hands them (stubbed here; the plugin's own rules are in test_professions).
do
    local TRANS = { key = "cd_Alchemy@Transmutes", prof = "Alchemy", line = 171, label = "Transmutes",
                    learn = 275, spells = { 17187 } }
    local SHAKER = { key = "cd_Leatherworking@Salt Shaker", prof = "Leatherworking", line = 165,
                     label = "Salt Shaker", learn = 250, spells = {}, item = 15846 }
    local MOON = { key = "cd_Tailoring@Mooncloth", prof = "Tailoring", line = 197, label = "Mooncloth",
                   learn = 250, spells = { 18560 } }
    local standing = {}   -- [name] = { [key] = { state, rank } }
    AltStable.CooldownCatalogue = function() return { TRANS, SHAKER, MOON } end
    AltStable.CooldownStanding = function(char, entry)
        local s = standing[char.name] and standing[char.name][entry.key]
        if s then return s[1], s[2] end
    end
    AltStable.CooldownRecipeLines = function(char, entry)
        if entry == TRANS then return { { "Transmute: Arcanite", "|cff1eff00Known|r" } } end
        return {}
    end
    standing.Kim = { ["cd_Alchemy@Transmutes"] = { "known", 290 } }
    standing.Lee = { ["cd_Alchemy@Transmutes"] = { "learnable", 280 }, ["cd_Leatherworking@Salt Shaker"] = { "usable", 260 } }
    standing.Low = { ["cd_Alchemy@Transmutes"] = { "low", 210 } }
    standing.New = { ["cd_Tailoring@Mooncloth"] = { "unscanned", 255 } }
    local store = {
        kim = { name = "Kim" }, lee = { name = "Lee" }, low = { name = "Low" }, new = { name = "New" },
        none = { name = "None" },                                          -- no such profession
        old = { name = "Old", ["cd_Alchemy@Transmute"] = NOW + 600 },      -- an older version's field
    }
    TRANS.iconItem = 99001   -- an item the fallback table does not name
    WoW.items[99001] = { icon = 133220 }
    eq("a column's icon: the catalogue's item (what its lowest recipe makes)", CD.Column(TRANS.key).cdIcon, 133220)
    eq("columns: the catalogue's, and an older label someone recorded",
       table.concat(CD.KeysInUse(store), ","),
       "cd_Alchemy@Transmute,cd_Alchemy@Transmutes,cd_Leatherworking@Salt Shaker,cd_Tailoring@Mooncloth")
    eq("  the catalogue alone with nothing recorded", #CD.KeysInUse({}), 3)
    check("listed: an owner with nothing recorded", CD.Listed(store.kim) and CD.Listed(store.new))
    check("  not someone without the profession", not CD.Listed(store.none))
    check("  a recorded cooldown still lists", CD.Listed(store.old))
    eq("known, nothing recorded: Known (not Available)", plain(CD.Cell(store.kim, TRANS.key, NOW)), "Known")
    eq("learnable", plain(CD.Cell(store.lee, TRANS.key, NOW)), "Learnable")
    eq("an item the skill allows: Usable", plain(CD.Cell(store.lee, SHAKER.key, NOW)), "Usable")
    eq("skill too low: Needs and the lowest skill", plain(CD.Cell(store.low, TRANS.key, NOW)), "Needs 275")
    eq("not scanned", plain(CD.Cell(store.new, MOON.key, NOW)), "Not scanned")
    eq("no profession: the dash", CD.Cell(store.none, TRANS.key, NOW), "|cff888888\226\128\148|r")
    local recorded = { name = "Kim", ["cd_Alchemy@Transmutes"] = NOW + 60 }
    eq("a recorded cooldown wins over the standing", CD.Cell(recorded, TRANS.key, NOW), "1m 0s")
    eq("the count: only recorded cooldowns that are up (Known is not)", CD.ReadyCount(store, nil, NOW), 0)
    -- An item's cooldown recorded for someone who can't use it yet (Codex
    -- review of #546): not believed in the cell, the sort or the count.
    standing.Raw = { ["cd_Leatherworking@Salt Shaker"] = { "low", 200 } }
    local raw = { name = "Raw", ["cd_Leatherworking@Salt Shaker"] = NOW - 5 }
    eq("a Shaker recorded under Leatherworking 250: Needs 250, not Available",
       plain(CD.Cell(raw, SHAKER.key, NOW)), "Needs 250")
    eq("  no time left to sort by", CD.Remaining(raw, SHAKER.key, NOW), nil)
    eq("  not counted", CD.ReadyCount({ raw = raw }, nil, NOW), 0)
    do   -- nor toasted: the view's rule (Codex review of #559)
        local realShow, realNotified, realDB = AltStable.ShowAggregateToast, AltStableConfig.toastsShown, AltStableDB
        local toasted
        AltStable.ShowAggregateToast = function(list) toasted = list end
        AltStableConfig.toastsShown, AltStableDB = {}, { raw = raw }
        AltStable.ScanCooldowns()
        eq("  not toasted", toasted, nil)
        standing.Raw[SHAKER.key] = { "usable", 260 }
        AltStable.ScanCooldowns()
        eq("  at the skill, toasted", toasted and #toasted, 1)
        AltStable.ShowAggregateToast, AltStableConfig.toastsShown, AltStableDB = realShow, realNotified, realDB
    end
    standing.Raw[SHAKER.key] = { "usable", 260 }
    eq("  at the skill, the record is believed", CD.ReadyCount({ raw = raw }, nil, NOW), 1)
    -- A RECIPE's recorded cooldown is believed whatever the snapshot says: a
    -- snapshot older than the record (learned since) must not hide a real timer.
    local lowRec = { name = "Low", ["cd_Alchemy@Transmutes"] = NOW + 60 }
    eq("a recipe's recorded cooldown under a 'low' snapshot still counts down",
       CD.Cell(lowRec, TRANS.key, NOW), "1m 0s")
    local _, l2, l3, lines = CD.Tip(store.kim, TRANS.key, NOW)
    eq("tooltip, known: not recorded yet", l2, "Known; its cooldown is not recorded yet")
    eq("  how to read it", l3, "Open the Alchemy window on Kim to read it.")
    eq("  and the recipes", lines and lines[1], "Transmute: Arcanite:  |cff1eff00Known|r")
    _, l2 = CD.Tip(store.lee, TRANS.key, NOW)
    eq("tooltip, learnable: the skill needed and had", l2, "Learnable: needs Alchemy 275, Lee has 280")
    _, l2 = CD.Tip(store.low, TRANS.key, NOW)
    eq("tooltip, too low", l2, "Needs Alchemy 275; Low has 210")
    _, l2 = CD.Tip(store.lee, SHAKER.key, NOW)
    eq("tooltip, usable", l2, "Meets Leatherworking 250; needs a Salt Shaker in the bags")
    _, l2, l3 = CD.Tip(store.new, MOON.key, NOW)
    eq("tooltip, not scanned", l2, "Not scanned")
    eq("  what to do", l3, "Open the Tailoring window on New once.")
    _, l2, l3 = CD.Tip(store.old, "cd_Alchemy@Transmute", NOW)
    check("an older version's field says so", (l3 or ""):find("older version", 1, true) ~= nil, l3)
    check("the empty text with the Recipe Book", CD.EmptyText():find("tracked cooldown", 1, true) ~= nil)
    AltStable.CooldownCatalogue, AltStable.CooldownStanding, AltStable.CooldownRecipeLines = nil, nil, nil
end

------------------------------------------------------------
-- Dedicated Study (#557): a Legacy talent's cooldown, the core's own
------------------------------------------------------------

local STUDY = "cd_Legacy@Dedicated Study"
-- Legacy readings (LegacyTalents.lua's text): node 110284 of the Professions
-- tree taken; not taken (Well Rested only); nothing at all.
local TAKEN   = "v1;c10;1187:7:110284.1.1.136844.1.1225469;1188:0:;1189:0:"
local UNTAKEN = "v1;c4;1187:0:;1188:1:110301.1.5.136855.1.1225478;1189:0:"

do
    local LT = AltStable.LegacyTalents
    eq("a taken node's rank", LT.Rank({ legacyTalents = TAKEN }, 110284), 1)
    eq("  read and not listed: 0", LT.Rank({ legacyTalents = UNTAKEN }, 110284), 0)
    eq("  no reading: nil", LT.Rank({}, 110284), nil)
end

-- Listed, columns, cells and tooltips, without the Recipe Book.
do
    local store = {
        t = { name = "Tess", legacyTalents = TAKEN },
        u = { name = "Ugo", legacyTalents = UNTAKEN },
        n = { name = "Nell" },
    }
    check("taken: listed, with nothing recorded", CD.Listed(store.t))
    check("  not taken: not listed for it", not CD.Listed(store.u))
    check("  no reading: not listed", not CD.Listed(store.n))
    eq("its column once someone shown has taken it", table.concat(CD.KeysInUse(store), ","), STUDY)
    eq("  none while they're hidden", #CD.KeysInUse(store, function(c) return c.name ~= "Tess" end), 0)
    eq("  none when nobody has", #CD.KeysInUse({ u = store.u, n = store.n }), 0)
    local col = CD.Column(STUDY)
    eq("the column: its label", col.label, "Dedicated Study")
    eq("  the spell's icon", col.cdIcon, 136235)
    eq("taken, nothing recorded: Taken", plain(CD.Cell(store.t, STUDY, NOW)), "Taken")
    eq("not taken", plain(CD.Cell(store.u, STUDY, NOW)), "Not taken")
    eq("no reading: the dash", CD.Cell(store.n, STUDY, NOW), "|cff888888\226\128\148|r")
    local running = { name = "Tess", legacyTalents = TAKEN, [STUDY] = NOW + 3600 }
    eq("taken and running: the countdown", CD.Cell(running, STUDY, NOW), "1h 0m")
    local dropped = { name = "Ugo", legacyTalents = UNTAKEN, [STUDY] = NOW - 5 }
    eq("a record for someone who no longer has it: Not taken", plain(CD.Cell(dropped, STUDY, NOW)), "Not taken")
    eq("  no time to sort by", CD.Remaining(dropped, STUDY, NOW), nil)
    eq("  not counted", CD.ReadyCount({ d = dropped }, nil, NOW), 0)
    eq("  a taken one's is", CD.ReadyCount({ r = { name = "R", legacyTalents = TAKEN, [STUDY] = NOW - 5 } }, nil, NOW), 1)
    -- Nor does it list the character or add the column (Codex review of #559).
    check("  not listed for it", not CD.Listed(dropped))
    check("  not a recorded cooldown", not CD.HasAny(dropped))
    eq("  no column from it", #CD.KeysInUse({ d = dropped, u = store.u }), 0)
    check("  while another's record still lists", CD.Listed({ name = "Ann", ["cd_Tailoring@Mooncloth"] = NOW + 5 }))

    -- The login toast: a taken one's that came up, not a reset one's.
    local realShow, realNotified = AltStable.ShowAggregateToast, AltStableConfig.toastsShown
    local toasted
    AltStable.ShowAggregateToast = function(list) toasted = list end
    AltStableConfig.toastsShown = {}
    AltStableDB = { r = { guid = "r", name = "Rae", legacyTalents = TAKEN, [STUDY] = NOW - 60 },
                    d = { guid = "d", name = "Ugo", legacyTalents = UNTAKEN, [STUDY] = NOW - 60 } }
    AltStable.ScanCooldowns()
    eq("the toast: one", toasted and #toasted, 1)
    eq("  the one who has it", toasted and toasted[1] and toasted[1].charName, "Rae")
    eq("  as Dedicated Study", toasted and toasted[1] and toasted[1].cdName, "Dedicated Study")
    AltStable.ShowAggregateToast, AltStableConfig.toastsShown, AltStableDB = realShow, realNotified, {}
    local l1, l2, l3 = CD.Tip(store.t, STUDY, NOW)
    eq("tooltip title", l1, "Dedicated Study (Legacy)")
    eq("  taken: not recorded yet", l2, "Taken; its cooldown is not recorded yet")
    eq("  how to read it", l3, "Log in on Tess to read it.")
    _, l2, l3 = CD.Tip(store.u, STUDY, NOW)
    eq("tooltip, not taken: where the talent is", l2, "Not taken: a talent of the Professions Legacy tree")
    eq("  no note", l3, nil)
    _, l2, l3 = CD.Tip(store.n, STUDY, NOW)
    eq("tooltip, no reading", l2, "No recorded cooldown")
    eq("  says why", l3, "No Legacy talents read for Nell yet: log in on it once.")
end

-- With the Recipe Book loaded: the talent's column joins its catalogue, its
-- standing is the talent's, and the plugin's recipe lines never see it.
do
    local MOON = { key = "cd_Tailoring@Mooncloth", prof = "Tailoring", line = 197, label = "Mooncloth",
                   learn = 250, spells = { 18560 } }
    local asked = 0
    AltStable.CooldownCatalogue = function() return { MOON } end
    AltStable.CooldownStanding = function(_, entry)
        if entry.legacy then asked = asked + 1 end
        return "learnable", 260
    end
    AltStable.CooldownRecipeLines = function(_, entry)
        if entry.legacy then error("a recipe lookup for a talent") end
        return {}
    end
    local tess = { name = "Tess", legacyTalents = TAKEN }
    eq("both columns", table.concat(CD.KeysInUse({ t = tess }), ","), STUDY .. ",cd_Tailoring@Mooncloth")
    eq("the talent's cell is the talent's standing", plain(CD.Cell(tess, STUDY, NOW)), "Taken")
    local ok, _, l2, _, lines = pcall(CD.Tip, tess, STUDY, NOW)
    check("its tooltip asks the plugin for no recipes", ok and lines == nil, tostring(l2))
    eq("  nor for a standing", asked, 0)
    AltStable.CooldownCatalogue, AltStable.CooldownStanding, AltStable.CooldownRecipeLines = nil, nil, nil
end

-- Recording, for the character being played.
do
    local guid = WoW.player.guid
    local touched = 0
    local realTouch, realGetTime = AltStable.TouchCharacter, GetTime
    AltStable.TouchCharacter = function(g) if g == guid then touched = touched + 1 end end
    local clock = 1000
    GetTime = function() return clock end
    local char = { name = "Me", guid = guid }
    AltStableDB = { [guid] = char }

    eq("no Legacy reading: nothing read", CD.ReadStudy(), false)
    eq("  nothing written", char[STUDY], nil)

    char.legacyTalents = TAKEN
    WoW.spellCooldowns = {}
    eq("taken and idle: a change", CD.ReadStudy(), true)
    eq("  written as now (Available)", char[STUDY], NOW)
    eq("  the character touched, so it syncs", touched, 1)
    eq("  idle again: no change", CD.ReadStudy(), false)

    WoW.spellCooldowns[1225469] = { 990, 82800 }   -- cast 10 s ago
    eq("running: a change", CD.ReadStudy(), true)
    eq("  the absolute expiry", char[STUDY], NOW + 82790)
    clock = 1030; WoW.now = NOW + 30                 -- both clocks on
    eq("  read again later: no change", CD.ReadStudy(), false)
    char[STUDY] = NOW + 82790 + 45
    eq("  a shift under 60 s is no change", CD.ReadStudy(), false)
    char[STUDY] = NOW + 82790 + 120
    eq("  over 60 s is", CD.ReadStudy(), true)
    eq("  set back", char[STUDY], NOW + 82790)
    WoW.now, clock = NOW, 1000

    WoW.spellCooldowns[1225469] = { 1000, 1.5 }      -- the global cooldown alone
    char[STUDY] = nil
    eq("the global cooldown: no change", CD.ReadStudy(), false)
    eq("  nothing written", char[STUDY], nil)
    WoW.spellCooldowns[1225469] = { 990, 82800, false }
    eq("paused: no change", CD.ReadStudy(), false)
    WoW.spellCooldowns[1225469] = { 990, WoW.secret(82800) }
    eq("a secret duration: no change", CD.ReadStudy(), false)
    eq("  nothing written", char[STUDY], nil)

    char[STUDY] = NOW + 5000
    WoW.spellCooldowns[1225469] = nil                -- reset: ready again
    eq("held running, read ready: a change", CD.ReadStudy(), true)
    eq("  now", char[STUDY], NOW)
    char[STUDY] = NOW - 300
    eq("a past expiry is kept (the toast keys on it)", CD.ReadStudy(), false)
    eq("  as it was", char[STUDY], NOW - 300)

    char.legacyTalents = UNTAKEN
    eq("not taken any more: a change", CD.ReadStudy(), true)
    eq("  the record goes", char[STUDY], nil)
    eq("  and nothing more", CD.ReadStudy(), false)

    -- Its events: a login reads it after the Legacy reading, a burst of
    -- cooldown updates reads once, and a Legacy reading that changes reads it.
    char.legacyTalents = TAKEN
    local frame = AltStable._test.StudyFrame
    local onEvent = frame:GetScript("OnEvent")
    WoW.timers = {}
    onEvent(frame, "PLAYER_ENTERING_WORLD", false, false)
    eq("a zone change reads nothing", #WoW.timers, 0)
    onEvent(frame, "PLAYER_ENTERING_WORLD", true, false)
    WoW.flushTimers()
    eq("a login reads it", char[STUDY], NOW)
    char[STUDY] = nil
    AltStable._test.ResetStudy()
    for _ = 1, 3 do onEvent(frame, "SPELL_UPDATE_COOLDOWN") end
    eq("a burst of cooldown updates: one read queued", #WoW.timers, 1)
    WoW.flushTimers()
    eq("  that reads it", char[STUDY], NOW)
    check("its frame hears the cooldown updates", frame._events and frame._events.SPELL_UPDATE_COOLDOWN)
    char[STUDY] = nil
    char.legacyTalents = UNTAKEN
    AltStable.LegacyTalents.Write(char, TAKEN)
    eq("the talent just taken: read at once", char[STUDY], NOW)

    AltStable.TouchCharacter, GetTime = realTouch, realGetTime
    WoW.spellCooldowns = {}
    AltStableDB = {}
end

WoW.finish("test_cooldowns", passed, failed)
