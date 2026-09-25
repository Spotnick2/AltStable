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
------------------------------------------------------------
-- It has to register when loaded ON DEMAND
------------------------------------------------------------
-- The core loads enabled plugins from its own PLAYER_LOGIN handler, so by the
-- time a plugin file runs, PLAYER_LOGIN has already fired and never fires for
-- it again. A plugin that only waits for the event loads cleanly, reports no
-- error, and silently never appears in the nav. That is precisely what this one
-- did, so the load path is asserted rather than assumed.

WoW.timers = {}
dofile("Plugins/Roster/AltStableRoster.lua")
check("loading after login schedules its own bootstrap", #WoW.timers > 0,
      "no timer scheduled - the plugin is waiting for a PLAYER_LOGIN that already fired")
WoW.flushTimers()

local registered
for _, p in ipairs(AltStable.plugins or {}) do
    if p.id == "roster" then registered = p end
end
check("  and that bootstrap registers the tab", registered ~= nil)
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

-- An entry the renderer could not draw must not count as a portrait either, or
-- the "capture one with /asrender" hint disappears exactly when every card is a
-- fallback.
AltStableCutoutManifest = { ["kaleid-sumner"] = { w = 144, h = 512, texw = 256, texh = 512 } }
eq("an entry with no file is not a portrait", T.CutoutFor(withArt), nil)
AltStableCutoutManifest = { ["kaleid-sumner"] = { file = "", w = 1, h = 1, texw = 1, texh = 1 } }
eq("  nor is an empty file path", T.CutoutFor(withArt), nil)

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
-- The grid has to FIT
------------------------------------------------------------
-- GridFor exists to be testable without a frame, and then nothing tested it,
-- which is how two layout bugs shipped: figures taller than their own card, and
-- a height floor that broke the division that made the rows fit. WoW frames do
-- not clip their children, so "does not fit" means "drawn over the thing below".

local function fits(panelW, panelH, count)
    local cols, rows, cardW, cardH = T.GridFor(panelW, panelH, count)
    local usedW = PADX2 + cols * cardW + (cols - 1) * GAP
    local usedH = PADY2 + HINT + rows * cardH + (rows - 1) * GAP
    return cols, rows, cardW, cardH, usedW, usedH
end

PADX2, PADY2, GAP, HINT = 32, 28, 10, 18   -- PAD_X*2, PAD_Y*2, CARD_GAP, hint line

do
    local cols, rows, cardW, cardH, usedW, usedH = fits(1200, 600, 12)
    check("a wide panel lays out in columns", cols > 1, tostring(cols))
    check("  every card fits across", usedW <= 1200 + 1, ("%.1f > 1200"):format(usedW))
    check("  and down", usedH <= 600 + 1, ("%.1f > 600"):format(usedH))
    check("  enough cells for everyone", cols * rows >= 12, ("%dx%d"):format(cols, rows))
end

do
    -- The case that broke: a short panel with enough characters to want more
    -- rows than there is height for.
    local cols, rows, cardW, cardH, _, usedH = fits(400, 300, 8)
    check("a short panel drops rows instead of squashing cards",
          usedH <= 300 + 1, ("%.1f > 300 (rows=%d cardH=%.1f)"):format(usedH, rows, cardH))
    check("  and keeps cards big enough to show a portrait", cardH >= 96, tostring(cardH))
end

do
    local cols, rows = T.GridFor(1200, 600, 0)
    check("no characters means no grid", cols == 0 and rows == 0)
end

do
    -- A panel measured before layout reports zero; it must not divide by it.
    local ok = pcall(T.GridFor, 0, 0, 5)
    check("an unmeasured panel does not error", ok)
end

do
    local _, _, cardW = fits(4000, 600, 2)
    check("cards stop growing past a sane width", cardW <= T.MAX_CARD_W + 0.5, tostring(cardW))
end

------------------------------------------------------------
-- The figure fits inside its own card
------------------------------------------------------------
-- It is anchored above the name block, so the space it may use is the card
-- minus that block. Taking a fraction of the WHOLE card overflowed upward into
-- the row above at every card height below ~146px.

do
    -- Asking the PLUGIN, not restating its formula: a test that recomputes the
    -- arithmetic passes whatever the source does, which is how the overflow
    -- survived a green suite once already.
    local NAME_BLOCK = 28 + 8            -- NAME_H plus the gap under the figure
    for _, cardH in ipairs({ 96, 120, 150, 200, 320 }) do
        local figureH = T.FigureHeightFor(cardH)
        check(("a figure fits in a %dpx card"):format(cardH),
              figureH + NAME_BLOCK <= cardH + 0.5,
              ("figure %.1f + name %d > card %d"):format(figureH, NAME_BLOCK, cardH))
    end
    check("a figure is never negative on an absurd card", T.FigureHeightFor(0) > 0)
    check("  nor on a nil one", T.FigureHeightFor(nil) > 0)
end

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

------------------------------------------------------------
-- It repaints while it is open
------------------------------------------------------------
-- Built once on activation and then left alone, the lineup goes stale: an alt
-- arriving by sync, a gear change, or hiding someone shows nothing until the
-- user leaves the tab and comes back.

do
    -- SheetUI is not loaded here, so stand in for the function the hook wraps.
    -- What is under test is the WRAPPING: that activating installs it, that it
    -- calls through, and that it repaints only while the tab is open.
    local base = 0
    AltStable.RefreshSheet = function() base = base + 1 end

    local painted = 0
    local realRefresh = AltStable.RosterPlugin.Refresh
    AltStable.RosterPlugin.Refresh = function() painted = painted + 1 end

    pcall(registered.OnActivate, main)      -- installs the hook
    check("the hook is installed once", AltStable.RosterPlugin._refreshHooked == true)
    painted = 0
    base = 0
    AltStable.RefreshSheet()
    WoW.flushTimers()
    check("a sheet refresh repaints an open Roster", painted > 0, tostring(painted))
    eq("  and still refreshes the sheet itself", base, 1)

    pcall(registered.OnDeactivate, main)
    painted = 0
    AltStable.RefreshSheet()
    WoW.flushTimers()
    eq("  and does not touch a closed one", painted, 0)

    AltStable.RosterPlugin.Refresh = realRefresh
end

print(("test_roster: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
