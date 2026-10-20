------------------------------------------------------------
-- test_stale.lua — forgetting the characters nobody plays any more (#259)
--
-- Three layers, each tested where it can disagree with the next:
--
--   * StaleCharacters - who is old, from lastUpdate, oldest first, never the
--     character being played.
--   * The Options list - ticked by default, an untick keeps one, and only the
--     rows on screen are ever forgotten.
--   * /alts stale - read-only, whatever it lists.
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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")   -- our prompts, before Core (TOC order)
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("SheetUI.lua")
dofile("PublicAPI.lua")

AltStable.EnsureConfigDefaults()

local T = AltStable._test
local DAY = 86400
local NOW = WoW.now
local ME = WoW.player.guid

-- A character last played `days` ago (nil: a record with no stamp at all).
local function char(guid, name, days, money)
    AltStableDB[guid] = { guid = guid, name = name, realm = "R", class = "MAGE", level = 60,
                          money = money, lastUpdate = days and (NOW - days * DAY) or nil }
end

local function seed()
    for k in pairs(AltStableDB) do AltStableDB[k] = nil end
    char(ME, "Myself", 400)                   -- old, but the one being played
    char("fresh", "Fresh", 3)
    char("edge", "Edge", 89)                  -- just inside a 90-day window
    char("old", "Old", 120, 50000)
    char("older", "Older", 300, 10000)
    char("nostamp", "Nostamp", nil)
end

local function names(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.name end
    return table.concat(out, ",")
end

------------------------------------------------------------
-- StaleCharacters
------------------------------------------------------------
do
    seed()
    local list = AltStable.StaleCharacters(90, NOW)
    eq("older than 90 days, oldest first, the unstamped one first of all",
       names(list), "Nostamp,Older,Old")
    eq("  a record with no stamp has no age to show", list[1].days, nil)
    eq("  the others say how long", list[2].days, 300)
    eq("  and carry their gold for the totals line", list[3].money, 50000)

    local wide = AltStable.StaleCharacters(1, NOW)
    local hasMe = false
    for _, e in ipairs(wide) do if e.guid == ME then hasMe = true end end
    check("the character being played is never listed, however old its record", not hasMe)

    eq("a bad age lists nobody rather than everybody", #AltStable.StaleCharacters(0, NOW), 0)
    eq("  nor does no age at all", #AltStable.StaleCharacters(nil, NOW), 0)

    eq("the default age is 90 days", AltStable.GetStaleDays(), 90)
    AltStableConfig.staleDays = 30
    eq("  unless Options set another", AltStable.GetStaleDays(), 30)
    AltStableConfig.staleDays = 0
    eq("  and a nonsense one falls back to it", AltStable.GetStaleDays(), 90)
    AltStableConfig.staleDays = nil
end

------------------------------------------------------------
-- ForgetCharacters: each one the ordinary way
------------------------------------------------------------
do
    seed()
    local done, refused = AltStable.ForgetCharacters({ "old", ME, "missing" })
    eq("the forgettable one is forgotten", table.concat(done, ","), "Old")
    eq("  the record is gone", AltStableDB.old, nil)
    check("  and tombstoned, so peers cannot send it back", AltStable.IsCharacterForgotten("old"))
    eq("the refusals come back with their reasons", #refused, 2)
    check("  the character being played is kept", AltStableDB[ME] ~= nil)
    AltStableConfig.forgottenCharacters = {}
end

------------------------------------------------------------
-- The Options list
------------------------------------------------------------
AltStable.EnsureSheetVisible()
local S = T.OptStale
local panel = T.optionsPanel
check("Options has an old-characters list", S ~= nil and panel ~= nil)

local function shownNames()
    local out = {}
    for _, row in ipairs(S.rows) do
        local t = row.label:GetText()
        if t and t ~= "" then out[#out + 1] = (t:match("|c%x%x%x%x%x%x%x%x(.-)|r")) end
    end
    return table.concat(out, ",")
end
local function untick(i)
    local cb = S.rows[i].check
    cb:SetChecked(false)
    cb:GetScript("OnClick")(cb)
end
local function clickForget() S.forget:GetScript("OnClick")(S.forget) end
local function answer(i)
    local p = T.Prompt("Forget")
    p.buttons[i]:GetScript("OnClick")(p.buttons[i])
end

if S and panel then
    seed()
    S.reset()
    panel:GetScript("OnShow")(panel)
    eq("the list shows who is old", shownNames(), "Nostamp,Older,Old")
    check("  every one ticked to start", S.rows[1].check:GetChecked() and S.rows[3].check:GetChecked())
    check("  the button counts them", (S.forgetLabel:GetText() or ""):find("Forget 3", 1, true) ~= nil,
          S.forgetLabel:GetText())
    eq("  the box shows the age", S.box:GetText(), "90")

    -- Untick one: it is kept, whatever happens next.
    untick(1)
    check("unticking one takes it off the count",
          (S.forgetLabel:GetText() or ""):find("Forget 2", 1, true) ~= nil, S.forgetLabel:GetText())

    -- Cancel forgets nobody.
    clickForget()
    local p = T.Prompt("Forget")
    check("Forget asks first", p and p:IsShown())
    check("  naming who", (p.text:GetText() or ""):find("Older", 1, true) ~= nil
          and not (p.text:GetText() or ""):find("Nostamp", 1, true), p.text:GetText())
    check("  and saying what leaves the totals", (p.text:GetText() or ""):find("leaves the totals", 1, true) ~= nil)
    check("  without the sync warning while the settings sync is off",
          not (p.text:GetText() or ""):find("other accounts forget", 1, true))
    answer(2)
    check("cancelling forgets nobody", AltStableDB.old ~= nil and AltStableDB.older ~= nil)

    -- Accept: the ticked go, the unticked stay.
    clickForget()
    answer(1)
    eq("accepting forgets the ticked", AltStableDB.old, nil)
    eq("  every one of them", AltStableDB.older, nil)
    check("  and keeps the unticked", AltStableDB.nostamp ~= nil)
    eq("  the list redraws without them", shownNames(), "Nostamp")
    check("  the unticked one stays unticked", not S.rows[1].check:GetChecked())
    check("  so there is nothing left to forget", (S.forgetLabel:GetText() or ""):find("Forget|r", 1, true) ~= nil,
          S.forgetLabel:GetText())
    AltStableConfig.forgottenCharacters = {}

    -- With the settings sync on, the question says it travels.
    seed()
    S.reset()
    AltStableConfig.syncSettings = true
    panel:GetScript("OnShow")(panel)
    clickForget()
    check("with the settings sync on, the question says the other accounts forget too",
          (T.Prompt("Forget").text:GetText() or ""):find("other accounts forget", 1, true) ~= nil)
    answer(2)
    AltStableConfig.syncSettings = nil

    -- More than the list holds: only the rows on screen are forgotten.
    seed()
    S.reset()
    for i = 1, 10 do char("many" .. i, ("Many%02d"):format(i), 100 + i) end
    panel:GetScript("OnShow")(panel)
    check("past the reserve, the note says so",
          (S.more:GetText() or ""):find("more", 1, true) ~= nil, S.more:GetText())
    clickForget()
    answer(1)
    local left = 0
    for k in pairs(AltStableDB) do if k:find("^many") or k == "old" or k == "older" or k == "nostamp" then left = left + 1 end end
    eq("only the rows on screen were forgotten", left, 13 - #S.rows)
    AltStableConfig.forgottenCharacters = {}

    -- The age box: a new age redraws the list; empty reverts.
    seed()
    S.reset()
    panel:GetScript("OnShow")(panel)
    S.commit("200")
    eq("a new age is kept", AltStableConfig.staleDays, 200)
    eq("  and the list follows it", shownNames(), "Nostamp,Older")
    S.commit("")
    eq("an emptied box keeps the age it had", AltStableConfig.staleDays, 200)
    eq("  and shows it again", S.box:GetText(), "200")
    AltStableConfig.staleDays = nil

    -- Nobody old: it says so.
    for k in pairs(AltStableDB) do AltStableDB[k] = nil end
    char("fresh", "Fresh", 3)
    panel:GetScript("OnShow")(panel)
    check("with nobody old, the list says so", (S.none:GetText() or ""):find("Everyone", 1, true) ~= nil,
          S.none:GetText())
end

------------------------------------------------------------
-- /alts stale - only a list
------------------------------------------------------------
do
    seed()
    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("stale")
    local all = table.concat(WoW.chatOut, "\n")
    check("/alts stale lists the old ones", all:find("Older", 1, true) and all:find("Old", 1, true), all)
    check("  not the recent ones", not all:find("Fresh", 1, true))
    check("  and forgets nobody", AltStableDB.old ~= nil and AltStableDB.older ~= nil)

    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("stale 200")
    all = table.concat(WoW.chatOut, "\n")
    check("/alts stale <days> uses that age", all:find("Older", 1, true) and not all:find("Old -", 1, true), all)

    -- (The unstamped one is old at any age, so it goes first.)
    AltStableDB.nostamp = nil
    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("stale 1000")
    check("  and says when nobody is that old", table.concat(WoW.chatOut, "\n"):find("Every character", 1, true) ~= nil)
end

print(("test_stale: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
