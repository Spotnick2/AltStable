------------------------------------------------------------
-- test_suite.lua — following Glass UI's suite theme and look (#261)
--
-- Glass UI is faked here as its contract says it is (GlassUI.Suite, API 1:
-- Theme, Report, Look, Accent, Open), so what is tested is AltStable's side:
-- when it follows, what it builds, what it reports, and that its own saved
-- appearance is never touched and every write path refuses while it follows.
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
local function near(name, got, want)
    check(name, type(got) == "number" and math.abs(got - want) < 1e-6,
          "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")
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
local ICE = { 0.65, 0.835, 0.905 }

-- Glass UI as its contract has it. `opts.preset`: the answer to Theme; nil
-- answers "not-following". `opts.throw`: Theme errors.
local reports
local function fakeSuite(opts)
    reports = {}
    local S = { API = opts.api or 1 }
    S.Theme = function(addon)
        S.asked = addon
        if opts.throw then error("boom") end
        if opts.preset then return { name = "pearl", preset = opts.preset } end
        return nil, "not-following"
    end
    S.Report = function(addon, state) reports[#reports + 1] = { addon = addon, state = state } end
    S.Look = function() return opts.look end
    S.Accent = function(name)
        local c = ({ gold = { 1, 0.82, 0 }, ice = ICE })[name]
        return c and { c[1], c[2], c[3] }
    end
    S.Open = function() S.opened = true; return true end
    -- Suite.Body only when asked for: without it, our own copy is the body.
    if opts.body then S.Body = function(tint) return opts.body[tint] end end
    GlassUI = { Suite = S }
    return S
end

-- A new session: nothing decided, the given saved appearance.
local function session(saved)
    AltStableConfig.skin = saved and saved.skin
    AltStableConfig.skinClassTint = saved and saved.classTint or false
    AltStableConfig.skinClean = not (saved and saved.clean == false)
    AltStableConfig.theme = saved and saved.theme or "dark"
    AltStable._ResetSkinCache()
end

local SAVED = { skin = "reflective", classTint = true, clean = false, theme = "class" }
local function savedUntouched(label)
    check(label, AltStableConfig.skin == "reflective" and AltStableConfig.skinClassTint == true
        and AltStableConfig.skinClean == false and AltStableConfig.theme == "class",
        ("%s %s %s %s"):format(tostring(AltStableConfig.skin), tostring(AltStableConfig.skinClassTint),
            tostring(AltStableConfig.skinClean), tostring(AltStableConfig.theme)))
end

------------------------------------------------------------
-- No Glass UI, or one that does not speak API 1: our own look, no report
------------------------------------------------------------
do
    GlassUI = nil
    session(SAVED)
    eq("without Glass UI the saved skin is worn", AltStable.SkinName(), "reflective")
    check("  not following", not AltStable.SuiteFollowing())
    eq("  our accent", select(1, AltStable.GetAccentRGB()), select(1, AltStable.GetClassRGB(select(2, UnitClass("player")))))

    local S = fakeSuite({ api = 2, preset = "pearl" })
    session(SAVED)
    eq("a Glass UI speaking another API counts as absent", AltStable.SkinName(), "reflective")
    eq("  it is not even asked", S.asked, nil)
    eq("  and gets no report", #reports, 0)

    GlassUI = { Suite = "junk" }
    session(SAVED)
    eq("a Suite that is not a table counts as absent", AltStable.SkinName(), "reflective")
end

------------------------------------------------------------
-- Glass UI says follow: Pearl, its tint, its accent
------------------------------------------------------------
do
    local S = fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "ice" } })
    session(SAVED)
    eq("following, the suite's tint is the skin", AltStable.SkinName(), "smoked")
    eq("  asked as AltStable", S.asked, "AltStable")
    check("  following", AltStable.SuiteFollowing())
    eq("  the material is Pearl", AltStable.Glass.preset, "pearl")
    check("  built clean (no grain)", AltStable.SkinClean() == true)
    eq("  no class-coloured glass on a smoked tint", AltStable.SkinClassTint(), false)
    local r, g, b = AltStable.GetAccentRGB()
    check("  the accent is the suite's", r == ICE[1] and g == ICE[2] and b == ICE[3],
          ("%s %s %s"):format(tostring(r), tostring(g), tostring(b)))
    savedUntouched("  our own appearance is kept, untouched")

    -- The wash: Pearl's own, scaled as smoked scales clear's.
    local pearlWash = AltStable.Glass.STYLE.wash
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    AltStable.SkinWindow(f, "large")
    near("  the wash is Pearl's, scaled for smoked", AltStable.Glass.STYLE.wash,
         pearlWash * AltStable.SKINS.smoked.wash / AltStable.SKINS.clear.wash)
    eq("  and the grain stays off", AltStable.Glass.STYLE.grain, 0)

    -- The report.
    eq("one report", #reports, 1)
    local st = reports[1] and reports[1].state or {}
    eq("  as AltStable", reports[1] and reports[1].addon, "AltStable")
    eq("  api 1", st.api, 1)
    eq("  built pearl", st.built, "pearl")
    eq("  no reason", st.reason, nil)
    eq("  not live: a suite change waits for a reload", st.live, false)
    check("  the look it built", st.look and st.look.tint == "smoked" and st.look.accent == "ice")
    eq("  a way to our options", type(st.options), "function")
    check("  its own backing, and no look key of its own",
          st.own and st.own.backing == true and st.own.tint == nil and st.own.accent == nil)
    eq("  the MINOR it ran on", st.minor, AltStable.GlassMinor())

    -- Once per session: asking again changes nothing and reports nothing.
    AltStable.SuiteStart()
    AltStable.SkinName()
    eq("decided once per session", #reports, 1)
end

-- Glass UI's body numbers, when it has Suite.Body: its own, not our copy.
do
    fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "gold" },
                body = { smoked = { tint = { 0.01, 0.02, 0.03, 0.5 }, wash = 0.5,
                                    backing = { 0, 0, 0, 0.9 } },
                         class = { classShade = 0.25, wash = 2, backing = { 0, 0, 0, 0.3 } } } })
    session(SAVED)
    AltStable.SkinName()
    local pearlWash = AltStable.Glass.STYLE.wash
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    AltStable.SkinWindow(f, "large")
    local t = AltStable.Glass.STYLE.tint
    check("the window's body is Glass UI's", t[1] == 0.01 and t[2] == 0.02 and t[3] == 0.03 and t[4] == 0.5,
          ("%s %s %s %s"):format(tostring(t[1]), tostring(t[2]), tostring(t[3]), tostring(t[4])))
    near("  the wash is Pearl's times its factor", AltStable.Glass.STYLE.wash, pearlWash * 0.5)

    -- A class body: clear glass, shaded by Glass UI's classShade.
    fakeSuite({ preset = "pearl", look = { tint = "class", accent = "gold" },
                body = { class = { classShade = 0.25, wash = 2, backing = { 0, 0, 0, 0.3 } } } })
    session(SAVED)
    AltStable.SkinName()
    local shaded
    local realTint, realColors = AltStable.Glass.SetSurfaceTint, RAID_CLASS_COLORS
    local cr = 0.8
    RAID_CLASS_COLORS = { [select(2, UnitClass("player"))] = { r = cr, g = 0.4, b = 0.2 } }
    AltStable.Glass.SetSurfaceTint = function(_, r) shaded = r end
    AltStable.SkinApplyClassTint({})
    AltStable.Glass.SetSurfaceTint, RAID_CLASS_COLORS = realTint, realColors
    near("a class body uses Glass UI's classShade", shaded, cr * 0.25)
    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    AltStable.SkinWindow(f, "large")
    eq("  over clear glass", AltStable.Glass.STYLE.tint[4], AltStable.SKINS.clear.tint[4])

    -- Junk from Body: our copy instead.
    fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "gold" },
                body = { smoked = { tint = "dark", wash = "lots" } } })
    session(SAVED)
    AltStable.SkinName()
    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    AltStable.SkinWindow(f, "large")
    eq("a body Glass UI cannot give is our smoked", AltStable.Glass.STYLE.tint[4], AltStable.SKINS.smoked.tint[4])

    -- A good wash with a junk tint is still junk.
    fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "gold" },
                body = { smoked = { tint = "dark", wash = 1 } } })
    session(SAVED)
    AltStable.SkinName()
    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(200, 200)
    AltStable.SkinWindow(f, "large")
    eq("  so is one with a good wash and a junk tint", AltStable.Glass.STYLE.tint[4], AltStable.SKINS.smoked.tint[4])
end

do
    fakeSuite({ preset = "pearl", look = { tint = "class", accent = "gold" } })
    session(SAVED)
    eq("the class tint is clear glass", AltStable.SkinName(), "clear")
    eq("  in the class colour", AltStable.SkinClassTint(), true)
    local r = AltStable.GetAccentRGB()
    eq("  a gold accent is gold, not our class accent", r, 1)

    fakeSuite({ preset = "pearl", look = { tint = "clear", accent = "neon" } })
    session(SAVED)
    -- The accent never starts the decision on its own; the skin does.
    eq("before the decision, the accent is our own", select(1, AltStable.GetAccentRGB()),
       select(1, AltStable.GetClassRGB(select(2, UnitClass("player")))))
    AltStable.SkinName()
    eq("an accent Glass UI cannot name falls back to gold", select(2, AltStable.GetAccentRGB()), 0.82)
    check("  and is reported as gold", reports[1].state.look.accent == "gold")

    fakeSuite({ preset = "pearl", look = { tint = "plaid", accent = "ice" } })
    session(SAVED)
    eq("a tint we do not know is clear", AltStable.SkinName(), "clear")
end

------------------------------------------------------------
-- Not following, Theme failing, Pearl failing: our own look
------------------------------------------------------------
do
    fakeSuite({})
    session(SAVED)
    eq("not following: the saved skin", AltStable.SkinName(), "reflective")
    eq("  the saved look", AltStable.SkinClean(), false)
    eq("  reported, built nothing", reports[1] and reports[1].state.built, nil)
    eq("  and no failure", reports[1] and reports[1].state.reason, nil)

    fakeSuite({ throw = true })
    session(SAVED)
    eq("Theme throwing: our own look", AltStable.SkinName(), "reflective")
    check("  not following", not AltStable.SuiteFollowing())

    -- An older LibGlass won the race: New errors on "pearl".
    local realUse = AltStable.UseGlassPreset
    AltStable.UseGlassPreset = function() return false, "library-too-old" end
    fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "ice" } })
    session(SAVED)
    eq("Pearl not built: our own look", AltStable.SkinName(), "reflective")
    check("  not following", not AltStable.SuiteFollowing())
    eq("  reported with the reason", reports[1] and reports[1].state.reason, "library-too-old")
    eq("  and built nothing", reports[1] and reports[1].state.built, nil)
    AltStable.UseGlassPreset = realUse

    -- The real one against a library without Pearl: the reason is the MINOR's.
    local realMinor = AltStable.GlassMinor
    AltStable.GlassMinor = function() return 10 end
    local realNew = LibStub("LibGlass-1.0").New
    LibStub("LibGlass-1.0").New = function() error("unknown preset") end
    local ok, why = AltStable.UseGlassPreset("nacre")
    eq("an older library's error is library-too-old", why, "library-too-old")
    check("  and not a success", ok == false)
    AltStable.GlassMinor = function() return 11 end
    ok, why = AltStable.UseGlassPreset("nacre2")
    eq("  a current one failing is build-failed", why, "build-failed")
    LibStub("LibGlass-1.0").New = realNew
    AltStable.GlassMinor = realMinor
end

------------------------------------------------------------
-- Every write path refuses while following
------------------------------------------------------------
do
    local S = fakeSuite({ preset = "pearl", look = { tint = "smoked", accent = "ice" } })
    session(SAVED)
    AltStable.SkinName()
    AltStable.EnsureSheetVisible()

    WoW.chatOut = {}
    SlashCmdList["ALTSTABLE"]("skin clear")
    savedUntouched("/alts skin does not write while following")
    check("  it says where the skin is set", table.concat(WoW.chatOut, "\n"):find("Glass UI", 1, true) ~= nil)

    for _, list in ipairs({ T.skinBtns, T.tintBtns, T.lookBtns }) do
        for _, b in ipairs(list) do b:GetScript("OnClick")(b) end
    end
    savedUntouched("the skin, glass and look buttons do not write while following")

    T.RefreshSkinRow()
    local line = T.SkinReloadText():GetText() or ""
    check("the row says Glass UI sets it", line:find("Set in Glass UI", 1, true) ~= nil, line)
    check("  naming what it is wearing", line:find("Pearl", 1, true) and line:find("smoked", 1, true)
          and line:find("ice", 1, true), line)
    eq("  the button goes to Glass UI", T.SkinReloadButton():GetText(), "Glass UI")
    local btn = T.SkinReloadButton()
    btn:GetScript("OnClick")(btn)
    check("  and opens it", S.opened == true)
    eq("  the buttons are dimmed", T.skinBtns[1]:GetAlpha(), 0.45)

    -- Back to our own look: the row is ours again.
    fakeSuite({})
    session(SAVED)
    T.RefreshSkinRow()
    eq("not following, the button reloads again", T.SkinReloadButton():GetText(), "Reload")
    eq("  and the buttons are bright", T.skinBtns[1]:GetAlpha(), 1)
    local cb = T.lookBtns[2]
    cb:GetScript("OnClick")(cb)
    eq("  and they write", AltStableConfig.skinClean, true)
end

print(("test_suite: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
