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

WoW.finish("test_cooldowns", passed, failed)
