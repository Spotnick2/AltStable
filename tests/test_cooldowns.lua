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
    local char = { ["cd_Alchemy@Transmute"] = NOW + 3600, ["cd_Tailoring@Mooncloth"] = NOW - 1 }
    local text, l1, l2 = CD.Cell(char, "cd_Tailoring@Mooncloth", NOW)
    check("ready: Available", text:find("Available", 1, true) ~= nil, text)
    check("  with the check mark", text:find("ReadyCheck-Ready", 1, true) ~= nil, text)
    eq("  tooltip title", l1, "Mooncloth (Tailoring)")
    eq("  and Ready", l2, "Ready")
    text, l1, l2 = CD.Cell(char, "cd_Alchemy@Transmute", NOW)
    eq("running: the countdown", text, "1h 0m")
    eq("  when it comes up", l2, "Ready " .. date("%a %H:%M", NOW + 3600))
    text, l1, l2 = CD.Cell(char, "cd_Leatherworking@Salt Shaker", NOW)
    check("none: a dash", text:find("\226\128\148", 1, true) ~= nil, text)
    eq("  said so", l2, "No recorded cooldown")
    eq("  titled all the same", l1, "Salt Shaker (Leatherworking)")
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

WoW.finish("test_cooldowns", passed, failed)
