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

    -- ONE spacing for everybody. Each side used to divide its own half, which
    -- is even only when the counts match: with five around a centred fire it is
    -- two and three, so the pair spread out while the trio crowded together.
    do
        table.sort(spots, function(a, b) return a.x < b.x end)
        local gaps = {}
        for i = 2, #spots do
            -- Skip the one that straddles the fire; that gap is the keep-out.
            if not (spots[i - 1].x < fireX and spots[i].x > fireX) then
                gaps[#gaps + 1] = spots[i].x - spots[i - 1].x
            end
        end
        check("there are gaps on both sides to compare", #gaps >= 3, tostring(#gaps))
        local first = gaps[1] or 0
        local even = true
        for _, g in ipairs(gaps) do
            if math.abs(g - first) > 0.001 then even = false end
        end
        check("  and every one of them is the same", even,
              table.concat(gaps, ", "))
        check("  which is the slot the figures are fitted to",
              math.abs(first - slot) < 0.001,
              ("%.2f vs %.2f"):format(first, slot))

        -- The two nearest the fire sit the same distance from it, so the
        -- keep-out reads as a gap rather than an accident.
        local innerL, innerR
        for _, sp in ipairs(spots) do
            if sp.x < fireX then innerL = sp.x else innerR = innerR or sp.x end
        end
        check("  and the innermost pair are symmetric about the flames",
              math.abs((fireX - innerL) - (innerR - fireX)) < 0.001,
              ("%.1f vs %.1f"):format(fireX - innerL, innerR - fireX))
    end

    -- Nobody is clipped by the frame. Every figure is fitted to one slot, so it
    -- reaches half a slot past its own centre - leaving room only up to the
    -- centre puts the outermost through the edge, which is what it did.
    do
        table.sort(spots, function(a, b) return a.x < b.x end)
        check("the leftmost figure is inside the panel",
              spots[1].x - slot / 2 >= 0, ("%.1f"):format(spots[1].x - slot / 2))
        check("  and so is the rightmost",
              spots[#spots].x + slot / 2 <= 1400,
              ("%.1f"):format(spots[#spots].x + slot / 2))
    end

    -- A fire well off to one side, so the RIGHT is the side that runs out of
    -- room. On a centred fire the left binds first and a mistake in the right
    -- side's arithmetic changes nothing, which is exactly how two of them
    -- survived a mutation run.
    do
        local offset = { w = 1024, h = 682, texw = 1024, texh = 1024,
                         fireX = 0.75, fireBaseY = 0.84 }
        local off, _, offSlot = T.SceneLayout(1400, 700, 5, offset)
        local offFire = T.FireAnchor(1400, 700, offset)
        check("the fire really is off to the right", offFire > 1400 * 0.7,
              ("%.0f"):format(offFire))

        table.sort(off, function(a, b) return a.x < b.x end)
        local margin = 1400 * T.SCENE_EDGE
        check("the outermost figure keeps clear of the right frame",
              off[#off].x + offSlot / 2 <= 1400 - margin * 0.99,
              ("%.1f vs %.1f"):format(off[#off].x + offSlot / 2, 1400 - margin))
        check("  and of the left",
              off[1].x - offSlot / 2 >= margin * 0.99,
              ("%.1f vs %.1f"):format(off[1].x - offSlot / 2, margin))
        for i, sp in ipairs(off) do
            check(("  character %d still clears the fire"):format(i),
                  math.abs(sp.x - offFire) >= 1400 * T.FIRE_CLEARANCE / 2)
        end
    end

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
-- The height comes from the RACE, not from the picture. The render stage frames
-- the model to fill the frame, so every race is drawn the same size before a
-- screenshot exists: across nine real captures the recorded pixel heights
-- spanned 0.609 to 0.649 - 6.6% - for races that differ by about 40%. Measuring
-- the image could never have worked, which is why an earlier version of this
-- file measured it and a gnome still stood shoulder to shoulder with elves.

do
    local gnomeM = { race = "Gnome",    gender = "Male" }
    local elfF   = { race = "NightElf", gender = "Female" }
    local taurenM = { race = "Tauren",  gender = "Male" }

    check("a gnome is much shorter than a night elf",
          T.RaceHeight(gnomeM) < T.RaceHeight(elfF) * 0.6,
          ("%.2f vs %.2f"):format(T.RaceHeight(gnomeM), T.RaceHeight(elfF)))
    check("  and a tauren is taller than both",
          T.RaceHeight(taurenM) > T.RaceHeight(elfF))

    -- Sex matters, and both spellings of it: the scanner writes gender as a
    -- word and sexID as a number, and a sync from an older client may carry
    -- only one of them.
    check("women are shorter than men of the same race",
          T.RaceHeight({ race = "Human", gender = "Female" })
              < T.RaceHeight({ race = "Human", gender = "Male" }))
    eq("  sexID says the same thing as gender",
       T.RaceHeight({ race = "Human", sexID = 1 }),
       T.RaceHeight({ race = "Human", gender = "Female" }))
    eq("  and absent both, male is the default",
       T.RaceHeight({ race = "Human" }),
       T.RaceHeight({ race = "Human", gender = "Male" }))

    -- Forever adds races, and a client newer than this table must not make
    -- somebody vanish or tower.
    --
    -- Pinned to a REAL race, not to DEFAULT_HEIGHT. Comparing the constant with
    -- itself passes whatever it is set to: at 0 an unknown race is drawn at
    -- zero height - invisible, the exact thing the code comment claims to
    -- prevent - and at 5.0 it becomes the tallest in the cast and shrinks
    -- everyone real to a fifth. Both passed every check here.
    eq("an unknown race stands human-sized",
       T.RaceHeight({ race = "SomeFutureRace" }), T.RACE_HEIGHT.Human.male)
    eq("  as does a record with no race at all",
       T.RaceHeight({}), T.RACE_HEIGHT.Human.male)
    eq("  and no record at all", T.RaceHeight(nil), T.RACE_HEIGHT.Human.male)
    check("  which is between the shortest race and the tallest",
          T.DEFAULT_HEIGHT > T.RACE_HEIGHT.Gnome.male
              and T.DEFAULT_HEIGHT < T.RACE_HEIGHT.Tauren.male,
          tostring(T.DEFAULT_HEIGHT))

    check("Forever's own race is in the table",
          T.RACE_HEIGHT.Skyborne ~= nil,
          "Skyborne is 11 of the characters on this account")
end

------------------------------------------------------------
-- Drawing at those heights
------------------------------------------------------------

do
    -- Two cutouts of the SAME pixel size, which is what the stage really
    -- produces. If the drawn heights came from the image these would be equal.
    local cut = { w = 300, h = 512, texw = 512, texh = 512 }
    local gnome = T.RaceHeight({ race = "Gnome", gender = "Male" })
    local elf   = T.RaceHeight({ race = "NightElf", gender = "Female" })

    local _, elfH = T.RelativeFigureSize(cut, elf, elf, 400)
    local _, gnomeH = T.RelativeFigureSize(cut, gnome, elf, 400)

    eq("the tallest race fills the target height", elfH, 400)
    check("  and the gnome is visibly shorter", gnomeH < elfH * 0.75,
          ("gnome %.1f vs elf %.1f"):format(gnomeH, elfH))
    check("  in proportion to their real heights",
          math.abs(gnomeH - 400 * (gnome / elf)) < 0.01, tostring(gnomeH))

    -- Identical images, different heights: the picture is not the source.
    check("two identical cutouts still differ in height", gnomeH ~= elfH)

    local w, h = T.RelativeFigureSize(cut, elf, elf, 400)
    check("the cutout still supplies the aspect",
          math.abs(w / h - 300 / 512) < 0.0001,
          "a tauren is broad as well as tall, and that the image does know")

    local _, noRefH = T.RelativeFigureSize(cut, gnome, 0, 400)
    eq("nobody to measure against means the common height", noRefH, 400)
    -- An unmeasured cutout has no aspect, so it is drawn square - but at the
    -- height its RACE says. Returning the full target height here let one bad
    -- sidecar stand a gnome at the tallest race's height, which is this whole
    -- fix undone for that figure. The old test asserted 400x400 and blessed it.
    local bad = { w = 0, h = 0 }
    local bw, bh = T.RelativeFigureSize(bad, gnome, elf, 400)
    eq("an unmeasured cutout is square rather than a divide by zero", bw, bh)
    check("  and still stands at its own race's height",
          math.abs(bh - 400 * (gnome / elf)) < 0.001,
          ("%.1f, want %.1f"):format(bh, 400 * (gnome / elf)))
    check("  which is shorter than the tallest", bh < 400)
end

do
    local chars = {
        { name = "Stubby", race = "Gnome", gender = "Male" },
        { name = "Lofty",  race = "NightElf", gender = "Male" },
        { name = "Plain",  race = "Human", gender = "Male" },
    }
    eq("the tallest race in the cast sets the scale",
       T.TallestRace(chars), T.RaceHeight({ race = "NightElf", gender = "Male" }))

    -- A cast of gnomes should FILL the frame, not huddle at ankle height under
    -- an absent tauren.
    local gnomes = {
        { name = "A", race = "Gnome", gender = "Male" },
        { name = "B", race = "Gnome", gender = "Female" },
    }
    local tallestGnome = T.TallestRace(gnomes)
    local _, h = T.RelativeFigureSize({ w = 300, h = 512 },
                                      T.RaceHeight(gnomes[1]), tallestGnome, 400)
    eq("an all-gnome cast still fills the frame", h, 400)

    eq("an empty cast has a usable scale", T.TallestRace({}), T.DEFAULT_HEIGHT)
end

------------------------------------------------------------
-- And the renderer really measures them that way
------------------------------------------------------------
-- Checking that RaceHeight and RelativeFigureSize agree with each other proves
-- nothing about what the renderer hands them. Handing every figure the same
-- height levels the races out again while both functions stay correct.

do
    local cut = { w = 300, h = 512, texw = 512, texh = 512 }
    local cast = {
        { name = "Stubby", race = "Gnome",    gender = "Male" },
        { name = "Lofty",  race = "NightElf", gender = "Male" },
        { name = "Bare",   race = "Tauren",   gender = "Male" },   -- no portrait
    }
    local function cutoutFor(c) return c.name ~= "Bare" and cut or nil end
    local spots = { { scale = 1 }, { scale = 1 }, { scale = 1 } }

    local tallest = T.TallestRace(cast)
    local sizes = T.MeasureCast(cast, cutoutFor, spots, tallest, 400)

    eq("every slot is measured", #sizes, 3)
    check("the gnome is drawn shorter than the elf",
          sizes[1][2] < sizes[2][2] * 0.75,
          ("%.1f vs %.1f"):format(sizes[1][2], sizes[2][2]))
    -- The point of the check above is that the two came from the SAME image, so
    -- say so with an assertion rather than a comment. `check(..., true)` was
    -- here and could not fail.
    eq("  from cutouts of identical width", cutoutFor(cast[1]).w, cutoutFor(cast[2]).w)
    eq("  and identical height", cutoutFor(cast[1]).h, cutoutFor(cast[2]).h)
    check("a character with no portrait measures zero",
          sizes[3][1] == 0 and sizes[3][2] == 0)

    -- The depth scale from the ring multiplies through, and each figure gets
    -- ITS OWN. Varying only the first spot and reading only the first result
    -- cannot tell spots[i] from spots[1] - and spots[1] gives every figure the
    -- front-of-ring scale, which flattens the perspective completely. That
    -- mutation survived, on the very function this PR added to pin the wiring.
    local deep = { { scale = 1 }, { scale = 0.5 }, { scale = 1 } }
    local scaled = T.MeasureCast(cast, cutoutFor, deep, tallest, 400)
    check("the figure standing further back is smaller",
          math.abs(scaled[2][2] - sizes[2][2] * 0.5) < 0.001,
          ("%.2f vs %.2f"):format(scaled[2][2], sizes[2][2] * 0.5))
    check("  and the one at the front is untouched",
          math.abs(scaled[1][2] - sizes[1][2]) < 0.001,
          ("%.2f vs %.2f"):format(scaled[1][2], sizes[1][2]))

    -- Every index, in one pass: a distinct scale each, so nothing can quietly
    -- read the wrong spot.
    local each = T.MeasureCast(cast, cutoutFor,
                               { { scale = 0.25 }, { scale = 0.5 }, { scale = 1 } },
                               tallest, 400)
    for i = 1, 2 do
        local want = sizes[i][2] * (i == 1 and 0.25 or 0.5)
        check(("figure %d is scaled by its own spot"):format(i),
              math.abs(each[i][2] - want) < 0.001,
              ("%.2f vs %.2f"):format(each[i][2], want))
    end

    local none = T.MeasureCast({}, cutoutFor, {}, tallest, 400)
    eq("an empty cast measures nothing", #none, 0)
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
-- Every backdrop knows where its own fire is
------------------------------------------------------------
-- The art spec is 50%/84%, but the README says in the same breath that those
-- are "approximate art targets, not measured anchors", and that Karazhan - an
-- AltTracker original that predates the spec - keeps its own smaller fire,
-- right of centre. One hardcoded pair for all fourteen puts the keep-out gap on
-- empty ground there.

do
    local missing, karazhan = {}, nil
    for _, e in ipairs(T.SCENE_BACKDROPS) do
        if type(e.fireX) ~= "number" or type(e.fireBaseY) ~= "number" then
            missing[#missing + 1] = e.id
        end
        if e.id == "karazhan" then karazhan = e end
    end
    eq("every backdrop carries a measured fire anchor", #missing, 0)

    check("Karazhan's fire is right of centre, as the README says",
          karazhan and karazhan.fireX > 0.53,
          karazhan and tostring(karazhan.fireX) or "no karazhan entry")
    check("  and lower than the generated scenes",
          karazhan and karazhan.fireBaseY > 0.87, tostring(karazhan.fireBaseY))

    -- The anchor has to REACH the layout, not just sit in the table.
    local spec  = { w = 1024, h = 682, texw = 1024, texh = 1024 }
    local kara  = { w = 1024, h = 682, texw = 1024, texh = 1024,
                    fireX = karazhan.fireX, fireBaseY = karazhan.fireBaseY }
    local specX, specY = T.FireAnchor(1400, 700, spec)
    local karaX, karaY = T.FireAnchor(1400, 700, kara)
    check("a backdrop's own anchor moves the fire", karaX > specX + 40,
          ("%.1f vs %.1f"):format(karaX, specX))
    check("  and its ground line with it", karaY < specY - 10,
          ("%.1f vs %.1f"):format(karaY, specY))

    -- And the cast follows it, rather than clearing the middle of the panel.
    local spots = T.SceneLayout(1400, 700, 5, kara)
    for i, sp in ipairs(spots) do
        check(("character %d clears Karazhan's own fire"):format(i),
              math.abs(sp.x - karaX) >= 1400 * T.FIRE_CLEARANCE / 2,
              ("x %.1f vs fire %.1f"):format(sp.x, karaX))
    end
end

------------------------------------------------------------
-- One scale for the whole cast
------------------------------------------------------------
-- The clamp this replaced shrank each too-wide figure on its own, which is a
-- uniform downscale of that one character - exactly the "scaling artefact
-- masquerading as a short character" its own comment claimed to have fixed.
-- Wide captures are the short, stocky races, so it hit precisely the ones
-- RelativeFigureSize had just measured.

do
    eq("nothing overflowing means nothing scaled",
       T.FitScale({ { 50, 200 }, { 60, 210 } }, 100), 1)

    -- One figure over the slot pulls EVERYONE down by the same factor.
    local fit = T.FitScale({ { 200, 300 }, { 50, 400 } }, 100)
    eq("the worst overflow sets the scale", fit, 0.5)

    local wideH  = 300 * fit
    local narrowH = 400 * fit
    check("the tall narrow figure is still the taller one", narrowH > wideH)
    check("  and the ratio between them is untouched",
          math.abs((narrowH / wideH) - (400 / 300)) < 1e-9,
          ("%.6f"):format(narrowH / wideH))

    -- The old per-figure clamp, for contrast: it would have left the wide one
    -- at 300 * (100/200) = 150 and the narrow one at 400, a ratio of 2.67.
    check("  which the per-figure clamp did not preserve",
          math.abs((400 / 150) - (400 / 300)) > 1,
          "the fixture must actually distinguish the two")

    eq("the worst of several overflows wins",
       T.FitScale({ { 400, 100 }, { 200, 100 } }, 100), 0.25)
    eq("an unmeasured slot scales nothing", T.FitScale({ { 400, 100 } }, 0), 1)
    eq("an empty cast scales nothing", T.FitScale({}, 100), 1)
end

------------------------------------------------------------
-- The hint does not sit on top of the backdrop picker
------------------------------------------------------------
-- Scene mode puts a 240px picker at the left of the top strip and the view
-- toggle at the right. The grid has neither, which is why the hint could be
-- centred there and nobody noticed.

do
    local gridY, gridW = T.HintLayout(700, false)
    local sceneY, sceneW = T.HintLayout(700, true)

    eq("the grid hint sits in the top strip", gridY, -8)
    check("the scene hint drops below the picker row",
          sceneY <= -(T.BAR_TOP + T.BAR_H),
          ("%d vs bar bottom %d"):format(sceneY, -(T.BAR_TOP + T.BAR_H)))

    eq("both get the panel's usable width", gridW, 700 - 2 * T.PAD_X)
    eq("  including the scene", sceneW, gridW)

    -- A centred string of this width WOULD have overlapped the furniture, which
    -- is why it moved rather than narrowed: check the geometry that forced it.
    local halfFree = (700 - T.SCENE_BAR_W - T.VIEW_BTN_W) / 2
    check("there is not room to centre a hint between the two",
          sceneW / 2 > halfFree,
          ("half-hint %.1f vs free %.1f"):format(sceneW / 2, halfFree))

    local _, narrow = T.HintLayout(40, true)
    check("an absurdly narrow panel still gives a non-negative width",
          narrow >= 0, tostring(narrow))
end

------------------------------------------------------------
-- The scene ranks the whole roster, not the grid's first page
------------------------------------------------------------
-- MAX_CARDS is how many cards the GRID has. Applying it before the scene chose
-- its cast turned it into a selection rule: AllCharacters sorts by level then
-- NAME, SceneCast ranks by level then ITEM level, so on a roster of level-60
-- alts the best-geared one could be dropped for sorting late alphabetically -
-- and a roster whose portraits all sat past the cap produced an empty camp.

do
    local saved = AltStableDB
    AltStableDB = {}
    for i = 1, 25 do
        local guid = ("alt-%02d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Alt %02d"):format(i),
                              level = 60, ilvl = i, class = "WARRIOR" }
    end

    local all = T.AllCharacters()
    eq("every character is offered to the scene", #all, 25)
    check("  which is more than the grid draws", #all > T.MAX_CARDS,
          ("%d vs %d"):format(#all, T.MAX_CARDS))
    eq("the grid still takes only its page", #T.PickCharacters(T.MAX_CARDS), T.MAX_CARDS)

    local art = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    local cast = T.SceneCast(all, function() return art end, T.SCENE_CAST)
    eq("the cast is still capped", #cast, T.SCENE_CAST)
    eq("the best-geared character is cast", cast[1].name, "Alt 25")
    eq("  then the next", cast[2].name, "Alt 24")

    -- The worse failure: nobody past the cap has a portrait, so the camp empties.
    local onlyLate = function(c)
        return tonumber((c.name or ""):match("(%d+)")) > T.MAX_CARDS and art or nil
    end
    local lateCast = T.SceneCast(all, onlyLate, T.SCENE_CAST)
    check("a roster whose only portraits sort last still fills the camp",
          #lateCast > 0, "the scene came back empty")
    eq("  with the character that has one", lateCast[1] and lateCast[1].name, "Alt 25")

    -- Feeding the scene the grid's page is the bug, stated as an assertion.
    local paged = T.SceneCast(T.PickCharacters(T.MAX_CARDS), onlyLate, T.SCENE_CAST)
    eq("  which the grid's page could not", #paged, 0)

    -- And the WIRING, not just the composition. Asserting that the right two
    -- functions compose correctly says nothing about which one the view calls,
    -- which is precisely where this went wrong.
    eq("the scene view is handed everyone", #T.CharactersFor("scene"), 25)
    eq("the grid view is handed its page", #T.CharactersFor("grid"), T.MAX_CARDS)
    check("  so the two views are not handed the same list",
          #T.CharactersFor("scene") ~= #T.CharactersFor("grid"))

    local cast2 = T.SceneCast(T.CharactersFor("scene"), onlyLate, T.SCENE_CAST)
    -- Nil-safe on purpose: when this regresses the cast comes back EMPTY, and a
    -- bare cast2[1].name aborts the whole file, hiding every test below it.
    eq("what the scene view actually gets still fills the camp",
       cast2[1] and cast2[1].name, "Alt 25")

    AltStableDB = saved
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
