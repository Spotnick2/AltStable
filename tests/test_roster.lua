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
-- Scene mode: the backdrop must never show its padding
------------------------------------------------------------
-- Media/Scene/README.md specifies a 1024x1024 texture whose real image is the
-- top 1024x682 and whose remaining 342 rows are opaque black. Forget the v
-- remap and a black band appears along the bottom, which reads as broken art
-- rather than wrong texture coordinates.

local V_MAX = 682 / 1024

do
    local entry = { w = 1024, h = 682, texh = 1024 }

    -- A panel with the same aspect as the content: no crop, full content.
    local l, r, t, b = T.BackdropTexCoords(1024, 682, entry)
    eq("an exactly-matching panel shows the whole width", l, 0)
    eq("  to the far edge", r, 1)
    eq("  starting at the top", t, 0)
    check("  and stopping at the content, not the canvas",
          math.abs(b - V_MAX) < 0.0001, tostring(b))

    -- Wider than the art: crop vertically - and crop the SKY. The floor and the
    -- fire live in the bottom sixth of every backdrop, so an even crop halves
    -- the camp and a wide enough panel removes the fire altogether.
    l, r, t, b = T.BackdropTexCoords(2000, 400, entry)
    eq("a wide panel keeps the full width", l, 0)
    eq("  still to the far edge", r, 1)
    check("  and crops vertically", t > 0, tostring(t))
    check("  from the top, keeping the floor", math.abs(b - V_MAX) < 0.0001,
          ("%.4f vs %.4f"):format(b, V_MAX))
    check("  by exactly the overflow", math.abs(t - V_MAX * (1 - (400 / 2000) / (682 / 1024))) < 0.0001,
          tostring(t))

    -- Wide enough to crop past the fire's own ground line under an even crop.
    -- This is the case that produced "most of the time you don't see the fire".
    l, r, t, b = T.BackdropTexCoords(1800, 500, entry)
    check("even a very wide panel keeps the fire's base in frame",
          0.84 * V_MAX > t and 0.84 * V_MAX < b,
          ("fire %.4f outside %.4f..%.4f"):format(0.84 * V_MAX, t, b))

    -- Taller than the art: crop the sides instead.
    l, r, t, b = T.BackdropTexCoords(400, 800, entry)
    check("a tall panel crops the sides", l > 0 and r < 1, ("%.3f..%.3f"):format(l, r))
    eq("  and keeps the full content height", t, 0)
    check("  up to the content edge", math.abs(b - V_MAX) < 0.0001)
    check("  symmetrically", math.abs(l - (1 - r)) < 0.0001)

    -- Nonsense in, whole texture out, rather than a divide by zero.
    l, r, t, b = T.BackdropTexCoords(0, 0, entry)
    check("an unmeasured panel is safe", l == 0 and r == 1 and t == 0 and b == 1)
    l, r, t, b = T.BackdropTexCoords(800, 600, nil)
    check("a missing entry is safe", l == 0 and r == 1 and t == 0 and b == 1)
end

------------------------------------------------------------
-- Nobody stands in the fire
------------------------------------------------------------
-- The backdrops are commissioned with the fire at horizontal centre and its
-- base at 84% of the image height (Media/Scene/README.md). The first version
-- guessed a ground line and spread the cast evenly across the panel, which put
-- the middle character in the flames and hid the fire behind the rest.

-- A backdrop shaped exactly like the real ones: 1024x682 of art in the top of a
-- 1024x1024 texture.
local BACKDROP = { w = 1024, h = 682, texw = 1024, texh = 1024 }

do
    -- 1400x700 is very close to the art's own 1024x682, so the crop is mild and
    -- the fire should land near where the art put it.
    local fireX, fireY = T.FireAnchor(1400, 700, BACKDROP)
    check("the fire is horizontally centred", math.abs(fireX - 700) < 1,
          tostring(fireX))
    check("its base is low in the frame, where the art drew it",
          fireY > 0 and fireY < 700 * 0.25, tostring(fireY))

    -- A TALL panel crops the sides. The fire is dead centre horizontally, so it
    -- survives that crop - and being centred is the point of the check: a naive
    -- (0.5 * panelW) would also pass here, so the wide case below is what
    -- actually proves the crop is being read.
    local tallX = T.FireAnchor(400, 900, BACKDROP)
    check("a tall panel keeps the fire centred", math.abs(tallX - 200) < 1,
          tostring(tallX))

    -- A WIDE panel crops sky off the top, so what is left is proportionally
    -- more floor and the fire sits HIGHER up the visible frame. Read the crop
    -- and the ground line follows it; ignore it and the cast stands in the
    -- bottom sixth of a panel whose bottom sixth is no longer the floor.
    local _, wideY = T.FireAnchor(1800, 500, BACKDROP)
    local _, squareY = T.FireAnchor(700, 500, BACKDROP)
    check("cropping the sky raises the fire up the frame",
          wideY > squareY + 1, ("wide %.1f vs square %.1f"):format(wideY, squareY))
    check("  and it stays on the panel", wideY > 0 and wideY < 500,
          tostring(wideY))

    -- The v remap by h/texh again: forget it and the anchor is computed against
    -- the black padding as though it were art, putting the ground line a third
    -- of the way up the panel.
    local flat = { w = 1024, h = 682, texw = 1024, texh = 682 }
    local _, flatY = T.FireAnchor(1400, 700, flat)
    check("the padding above the art is not mistaken for art",
          math.abs(flatY - fireY) < 1,
          ("%.1f vs %.1f"):format(flatY, fireY))

    local x, y = T.FireAnchor(1400, 700, nil)
    check("a missing backdrop still gives a usable anchor",
          x > 0 and x < 1400 and y > 0 and y < 700)
end

do
    local spots, figureH, slot = T.SceneLayout(1400, 700, 5, BACKDROP)
    local fireX = T.FireAnchor(1400, 700, BACKDROP)
    local clear = 1400 * T.FIRE_CLEARANCE

    eq("everyone in the cast gets a spot", #spots, 5)
    check("the figures fit on the panel", figureH > 0 and figureH < 700)

    -- The reported bug, as an assertion.
    for i, sp in ipairs(spots) do
        check(("character %d is clear of the fire"):format(i),
              math.abs(sp.x - fireX) >= clear / 2,
              ("x %.1f vs fire %.1f, clearance %.1f"):format(sp.x, fireX, clear))
        check(("  and on the panel"):format(i), sp.x > 0 and sp.x < 1400)
    end

    -- An odd cast with the fire dead centre cannot split evenly, but it must
    -- still split: 3 and 2, never 2 and a passenger in the flames.
    local left = 0
    for _, sp in ipairs(spots) do if sp.x < fireX then left = left + 1 end end
    check("the cast is split either side of the fire", left >= 2 and left <= 3,
          tostring(left))

    -- The ring, not the line-up.
    table.sort(spots, function(a, b) return a.x < b.x end)
    local inner, outer = spots[3], spots[1]
    check("whoever stands nearest the fire is further back",
          inner.y > outer.y, ("%.1f vs %.1f"):format(inner.y, outer.y))
    check("  and therefore drawn smaller",
          inner.scale < outer.scale,
          ("%.3f vs %.3f"):format(inner.scale, outer.scale))
    check("  but nobody is shrunk out of sight", inner.scale > 0.7,
          tostring(inner.scale))
    -- The ring rises from the ground line; nobody sinks below it, and nobody is
    -- lifted so far they are standing on air.
    local _, ground = T.FireAnchor(1400, 700, BACKDROP)
    for i, sp in ipairs(spots) do
        check(("character %d stands on or behind the ground line"):format(i),
              sp.y >= ground - 0.001 and sp.y <= ground + 700 * 0.09,
              ("%.1f vs ground %.1f"):format(sp.y, ground))
        check(("  and fits above it"):format(i), sp.y + figureH * sp.scale <= 700,
              ("%.1f"):format(sp.y + figureH * sp.scale))
    end

    -- Overlap order. The one nearest the camera is drawn last, over the top of
    -- whoever is standing behind them.
    check("the figure at the front is drawn over the one at the back",
          outer.level > inner.level,
          ("front %d vs back %d"):format(outer.level, inner.level))
    check("  and the ring's own back is the bottom of the stack",
          inner.level >= 0, tostring(inner.level))

    check("the slots leave room between neighbours", slot > 0 and slot < 1400)
    local _, _, slot8 = T.SceneLayout(1400, 700, 8, BACKDROP)
    check("a bigger cast gets narrower slots", slot8 < slot,
          ("%.1f vs %.1f"):format(slot8, slot))

    local one = T.SceneLayout(1400, 700, 1, BACKDROP)
    eq("a single character still gets a spot", #one, 1)
    check("  and still stands clear of the fire",
          math.abs(one[1].x - fireX) >= clear / 2)

    -- A wide panel is where the ground line climbs: cropping sky leaves more
    -- floor, so the fire - and the cast on it - sit higher up. A figure height
    -- taken as a flat fraction of the panel then runs off the top.
    do
        local wide, wideH = T.SceneLayout(1800, 500, 5, BACKDROP)
        local _, wideGround = T.FireAnchor(1800, 500, BACKDROP)
        check("a wide panel puts the ground line well up the frame",
              wideGround > 500 * 0.25, tostring(wideGround))
        check("  and the figures still fit above it",
              wideGround + wideH <= 500, ("%.1f + %.1f"):format(wideGround, wideH))
        check("  without shrinking to nothing", wideH > 500 * 0.4, tostring(wideH))
        for i, sp in ipairs(wide) do
            check(("  character %d stays on the panel"):format(i),
                  sp.y + wideH * sp.scale <= 500,
                  ("%.1f"):format(sp.y + wideH * sp.scale))
        end
    end

    local none, f, sl = T.SceneLayout(1400, 700, 0, BACKDROP)
    check("an empty roster lays out nothing", #none == 0 and f == 0 and sl == 0)
    local unmeasured = T.SceneLayout(0, 0, 5, BACKDROP)
    eq("an unmeasured panel lays out nothing", #unmeasured, 0)
end

------------------------------------------------------------
-- The backdrops themselves
------------------------------------------------------------

do
    local scenes = T.SCENE_BACKDROPS
    check("there are backdrops to choose from", #scenes >= 2, tostring(#scenes))

    local seen = {}
    for _, b in ipairs(scenes) do
        check("every backdrop has an id, a label and a file",
              type(b.id) == "string" and type(b.label) == "string"
              and type(b.file) == "string" and b.file ~= "")
        check("  ids are unique (" .. tostring(b.id) .. ")", not seen[b.id])
        seen[b.id] = true
        -- The whole point of the padding contract: h must be SMALLER than texh,
        -- or the entry is claiming the black rows are part of the picture.
        check("  " .. b.id .. " declares content shorter than its canvas",
              b.h < b.texh, ("h=%s texh=%s"):format(tostring(b.h), tostring(b.texh)))
        check("  " .. b.id .. " points at a scene texture",
              b.file:find("Scene", 1, true) ~= nil, b.file)
    end
end

------------------------------------------------------------
-- The view is remembered, and the grid is the default
------------------------------------------------------------

do
    AltStableConfig.rosterView = nil
    eq("the grid is the default view", T.View(), "grid")
    AltStableConfig.rosterView = "scene"
    eq("  and the scene is remembered when chosen", T.View(), "scene")
    AltStableConfig.rosterView = "nonsense"
    eq("  anything else falls back to the grid", T.View(), "grid")

    AltStableConfig.rosterScene = nil
    check("an unset backdrop picks the first", T.CurrentScene() == T.SCENE_BACKDROPS[1])
    AltStableConfig.rosterScene = T.SCENE_BACKDROPS[3].id
    check("  a chosen one is remembered", T.CurrentScene() == T.SCENE_BACKDROPS[3])
    AltStableConfig.rosterScene = "a-scene-that-was-deleted"
    check("  and one that no longer exists falls back rather than erroring",
          T.CurrentScene() == T.SCENE_BACKDROPS[1])
    AltStableConfig.rosterScene = nil
    AltStableConfig.rosterView = nil
end

------------------------------------------------------------
-- A gnome is shorter than a night elf
------------------------------------------------------------
-- Every cutout is supersampled to the SAME pixel height, so w/h carries no
-- information about how tall the character is. nativeH, recorded before that
-- step, is the only surviving record - and without it the scene drew a gnome
-- exactly as tall as an elf, which is what made the first version look wrong.

do
    local elf   = { w = 144, h = 512, texw = 256, texh = 512, nativeH = 1382 }
    local gnome = { w = 334, h = 512, texw = 512, texh = 512, nativeH = 874 }

    local _, elfH = T.RelativeFigureSize(elf, 1382, 400)
    local _, gnomeH = T.RelativeFigureSize(gnome, 1382, 400)
    eq("the tallest character fills the target height", elfH, 400)
    check("  and the gnome is visibly shorter", gnomeH < elfH * 0.75,
          ("gnome %.1f vs elf %.1f"):format(gnomeH, elfH))
    check("  in proportion to its real height",
          math.abs(gnomeH - 400 * (874 / 1382)) < 0.01, tostring(gnomeH))

    local w, h = T.RelativeFigureSize(elf, 1382, 400)
    check("aspect ratio is preserved", math.abs(w / h - 144 / 512) < 0.0001)

    -- A cutout captured before sidecars existed has no native height. It must
    -- fall back to the common height it always had, not vanish or tower.
    local legacy = { w = 200, h = 512, texw = 256, texh = 512 }
    local _, legacyH = T.RelativeFigureSize(legacy, 1382, 400)
    eq("a cutout with no native height falls back to the common one", legacyH, 400)

    local _, noRefH = T.RelativeFigureSize(elf, nil, 400)
    eq("  as does everyone when nothing has one", noRefH, 400)
end

do
    local function cut(c) return c.entry end
    local chars = {
        { name = "Tall",  entry = { nativeH = 1382 } },
        { name = "Short", entry = { nativeH = 874 } },
        { name = "None",  entry = {} },
    }
    eq("the tallest native height wins", T.TallestNative(chars, cut), 1382)
    eq("nobody with a height means nobody to measure against",
       T.TallestNative({ { name = "None", entry = {} } }, cut), nil)
end

------------------------------------------------------------
-- Who stands around the fire
------------------------------------------------------------
-- Thirteen in a row reads as a police line-up. Retail's warband campsite shows
-- four or five, which is the look this is copying.

do
    local withArt = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    local function cut(c) return c.hasArt and withArt or nil end

    local many = {}
    for i = 1, 13 do
        many[i] = { name = "Alt" .. i, level = i, ilvl = i, hasArt = true }
    end

    local cast = T.SceneCast(many, cut, T.SCENE_CAST)
    eq("the cast is capped", #cast, T.SCENE_CAST)
    eq("  highest level first", cast[1].name, "Alt13")
    eq("  then the next", cast[2].name, "Alt12")

    -- Item level breaks a tie, since a levelled roster is mostly one level.
    local tied = {
        { name = "Geared", level = 60, ilvl = 70, hasArt = true },
        { name = "Naked",  level = 60, ilvl = 10, hasArt = true },
    }
    eq("item level breaks a level tie", T.SceneCast(tied, cut, 2)[1].name, "Geared")

    -- Without a portrait there is nothing to draw.
    local mixed = {
        { name = "Pictured", level = 5, hasArt = true },
        { name = "Bare",     level = 60 },
    }
    local only = T.SceneCast(mixed, cut, 5)
    eq("only characters with a portrait appear", #only, 1)
    eq("  even when a bare one outranks them", only[1].name, "Pictured")

    eq("an empty roster casts nobody", #T.SceneCast({}, cut, 5), 0)
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
