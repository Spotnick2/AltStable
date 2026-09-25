------------------------------------------------------------
-- test_roster.lua — the Roster plugin's scaffolding (#15)
--
-- The lineup draws locally captured portraits, and a class card for anyone who
-- has none. The fallback is NOT an edge case: cutouts are produced by a tool
-- outside the game, so a user who has not run it has none at all, and a
-- character played for the first time has none yet. Most of these checks are
-- about that path behaving.
--
-- The other thing pinned here is the SLUG. The converter names each file after
-- the character, and the plugin looks it up by the same rule. If those two ever
-- disagree, every portrait silently becomes a card and nothing errors - which
-- is exactly the kind of failure a test has to catch instead of a person.
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
dofile("Theme.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
dofile("Plugins/Roster/AltStableRoster.lua")

-- The plugin registers on a timer after PLAYER_LOGIN; drive it directly.
AltStable.RosterPlugin._Bootstrap()

local registered
for _, p in ipairs(AltStable.plugins or {}) do
    if p.id == "roster" then registered = p end
end
check("the plugin registers itself", registered ~= nil)
if not registered then
    print(("test_roster: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end
local T = registered._test

eq("  under a readable label", registered.label, "Roster")
check("  with both lifecycle hooks",
      type(registered.OnActivate) == "function" and type(registered.OnDeactivate) == "function")

------------------------------------------------------------
-- The slug has to match the converter, exactly
------------------------------------------------------------
-- make-cutout.py:  re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

eq("a surname becomes one dash", T.Slug("Kaleid Sumner"), "kaleid-sumner")
eq("case is folded", T.Slug("MORPHISTO Ruskador"), "morphisto-ruskador")
eq("punctuation collapses", T.Slug("Zoruka   O'Brien"), "zoruka-o-brien")
eq("a bare first name survives", T.Slug("Solo"), "solo")
eq("leading and trailing runs are trimmed", T.Slug("  Edge  "), "edge")
eq("a nameless record has no slug", T.Slug(nil), nil)
eq("  and neither does an empty one", T.Slug(""), nil)

------------------------------------------------------------
-- Finding a portrait
------------------------------------------------------------

AltStableCutoutManifest = {
    ["kaleid-sumner"] = { file = "Interface\\AddOns\\AltStable\\Media\\Cutouts\\kaleid-sumner.tga",
                          w = 144, h = 512, texw = 256, texh = 512 },
}

local withArt = { guid = "a", name = "Kaleid Sumner", class = "HUNTER", level = 16 }
local without = { guid = "b", name = "Nobody Here",   class = "MAGE",   level = 60 }

check("a captured character finds its portrait", T.CutoutFor(withArt) ~= nil)
eq("  an uncaptured one does not", T.CutoutFor(without), nil)
eq("  and neither does a nameless record", T.CutoutFor({ guid = "c" }), nil)

AltStableCutoutManifest = nil
eq("no manifest at all is not an error", T.CutoutFor(withArt), nil)
AltStableCutoutManifest = {
    ["kaleid-sumner"] = { file = "x", w = 144, h = 512, texw = 256, texh = 512 },
}

------------------------------------------------------------
-- Cropping the power-of-two canvas
------------------------------------------------------------
-- The image sits in the TOP-LEFT and the rest is empty padding. Drawing the
-- whole texture would render a figure squashed into a corner of blank space.

local l, r, t, b = T.TexCoordsFor({ w = 144, h = 512, texw = 256, texh = 512 })
eq("the left edge is the texture's", l, 0)
eq("the right edge stops at the content", r, 144 / 256)
eq("the top edge is the texture's", t, 0)
eq("the bottom edge stops at the content", b, 512 / 512)

l, r, t, b = T.TexCoordsFor(nil)
check("a missing entry falls back to the whole texture",
      l == 0 and r == 1 and t == 0 and b == 1)
l, r, t, b = T.TexCoordsFor({ w = 0, h = 0, texw = 0, texh = 0 })
check("  and so does a zero-sized one", l == 0 and r == 1 and t == 0 and b == 1)

-- Content can never be larger than its own canvas, but a hand-edited manifest
-- could claim it is, and a tex coord above 1 samples garbage.
local _, r2 = T.TexCoordsFor({ w = 999, h = 512, texw = 256, texh = 512 })
check("an over-large width is clamped", r2 <= 1, tostring(r2))

------------------------------------------------------------
-- Everyone stands on the same ground line
------------------------------------------------------------
-- A gnome and a tauren are captured at different sizes. Scaling both to one
-- height is the whole visual point of a lineup.

local w, h = T.FigureSize({ w = 144, h = 512 }, 260)
eq("the figure takes the target height", h, 260)
eq("  and keeps its aspect", math.floor(w + 0.5), math.floor(260 * 144 / 512 + 0.5))

local w2, h2 = T.FigureSize({ w = 334, h = 512 }, 260)
eq("a wider capture is still the same height", h2, 260)
check("  and is drawn wider", w2 > w, ("%.1f vs %.1f"):format(w2, w))

w, h = T.FigureSize(nil, 260)
check("a missing entry yields a square rather than a divide by zero",
      w == 260 and h == 260)

------------------------------------------------------------
-- Who appears
------------------------------------------------------------

AltStableDB = {
    a = { guid = "a", name = "Sixty",  class = "MAGE",   level = 60 },
    b = { guid = "b", name = "Ten",    class = "ROGUE",  level = 10 },
    c = { guid = "c", name = "Forty",  class = "PRIEST", level = 40 },
    junk = "not a character",
    d = { guid = "d", level = 55 },        -- no name: not a character record
}

local picked = T.PickCharacters(10)
eq("only real character records are shown", #picked, 3)
eq("highest level first", picked[1].name, "Sixty")
eq("  then the rest in order", picked[2].name, "Forty")

-- #21: one setting, every view.
AltStableConfig.hiddenCharacters = {}
AltStable.SetCharacterHidden("a", true)
picked = T.PickCharacters(10)
eq("a hidden character stays hidden here too", #picked, 2)
check("  and it is the right one that went", picked[1].name == "Forty")
AltStable.SetCharacterHidden("a", false)

picked = T.PickCharacters(2)
eq("the lineup is capped", #picked, 2)

------------------------------------------------------------
-- It builds
------------------------------------------------------------
-- Frames are stubs, so this asserts that the panel can be constructed and
-- refreshed without erroring - the failure a plugin usually has on first load.

AltStableDB = {
    a = { guid = "a", name = "Kaleid Sumner", class = "HUNTER", level = 16 },
    b = { guid = "b", name = "Nobody Here",   class = "MAGE",   level = 60 },
}
local main = WoW.makeFrame()
local ok, err = pcall(registered.OnActivate, main)
check("the panel activates", ok, tostring(err))
ok, err = pcall(AltStable.RosterPlugin.Refresh)
check("  and refreshes with one portrait and one card", ok, tostring(err))
ok, err = pcall(AltStable.RosterPlugin.Select, "b")
check("  and a card can be selected", ok, tostring(err))
ok, err = pcall(registered.OnDeactivate, main)
check("  and deactivates", ok, tostring(err))

print(("test_roster: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
