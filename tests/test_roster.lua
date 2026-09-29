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
-- The material and the skin seam, in .toc order: CharacterMenu below asks the
-- skin whether it is glass, so a harness without them is a load order that
-- cannot happen in game.
assert(loadfile("Glass.lua"))("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
assert(loadfile("Core.lua"))()
-- Scanner.lua owns AltStable.GEAR_SLOTS, the one list of the seventeen
-- equipment slots. The detail pane's paper doll walks it, and it used to carry
-- its own copy: two lists of seventeen rows, each naming the `gearid_<key>`
-- fields that are the contract between the scanner that writes them and this
-- pane that reads them. Loaded in the .toc order, which puts Scanner first.
dofile("Scanner.lua")
dofile("Config.lua")
-- RowRenderer owns FormatMoney and FormatLastSeen, which the detail pane calls
-- through AltStable. Without it they are NIL, FormatStatValue falls through to
-- tostring, and every assertion about formatting passes against a raw number -
-- "Gold=573920", "Last Online=1699996400".
dofile("RowRenderer.lua")
-- The card's right-click raises the shared character menu (#69).
dofile("CharacterMenu.lua")
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
-- the "N of M have a portrait" hint disappears exactly when every card is a
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
-- Favourites (#66)
------------------------------------------------------------
-- Three per-character states now, and they have to stay distinct or none of
-- them means anything: favourite is "show me first", hidden is "do not show me
-- at all", forgotten removes the record. Favourite and hidden are the same kind
-- of thing, so this reuses hidden's storage shape rather than inventing a
-- second one that can disagree with it.

do
    local saved = AltStableDB
    AltStableDB = {}
    for i = 1, 6 do
        local guid = ("fav-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Alt %d"):format(i),
                              level = i * 10, ilvl = i, class = "MAGE" }
    end
    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.hiddenCharacters = nil

    -- Plain order: level descending.
    local plain = T.AllCharacters()
    eq("without favourites, the highest level leads", plain[1].name, "Alt 6")

    -- Pin the weakest character and it goes to the front.
    AltStable.SetCharacterFavourite("fav-1", true)
    local pinned = T.AllCharacters()
    eq("a favourite sorts first whatever its level", pinned[1].name, "Alt 1")
    eq("  and the rest keep their order behind it", pinned[2].name, "Alt 6")
    eq("  all the way down", pinned[#pinned].name, "Alt 2")

    -- Two favourites keep level order between themselves.
    AltStable.SetCharacterFavourite("fav-3", true)
    local two = T.AllCharacters()
    eq("favourites are ordered among themselves by level", two[1].name, "Alt 3")
    eq("  then the other favourite", two[2].name, "Alt 1")
    eq("  then everyone else", two[3].name, "Alt 6")

    -- It is a toggle, and absent means no.
    check(AltStable.IsCharacterFavourite("fav-1"), "a pinned character reads as favourite")
    eq("toggling reports the new state", AltStable.ToggleCharacterFavourite("fav-1"), false)
    check(not AltStable.IsCharacterFavourite("fav-1"), "  and unpins it")
    eq("  storing nil rather than false, like hidden does",
       AltStableConfig.favouriteCharacters["fav-1"], nil)
    check(not AltStable.IsCharacterFavourite("never-seen"), "an unknown guid is not a favourite")
    check(not AltStable.IsCharacterFavourite(nil), "and neither is nothing")

    -- Favourite and hidden stay different things.
    AltStable.SetCharacterFavourite("fav-2", true)
    AltStable.SetCharacterHidden("fav-2", true)
    for _, c in ipairs(T.AllCharacters()) do
        check(c.guid ~= "fav-2", "a hidden character stays hidden even when favourited")
    end
    AltStable.SetCharacterHidden("fav-2", false)

    ------------------------------------------------------------
    -- The scene casts from them
    ------------------------------------------------------------
    local art = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    local function cut() return art end

    AltStableConfig.favouriteCharacters = nil
    local byLevel = T.SceneCast(T.AllCharacters(), cut, 2)
    eq("with no favourites the scene still fills itself by level", byLevel[1].name, "Alt 6")

    AltStable.SetCharacterFavourite("fav-1", true)
    local cast = T.SceneCast(T.AllCharacters(), cut, 2)
    eq("a favourite takes a seat at the fire", cast[1].name, "Alt 1")
    eq("  and the rest of the seats go by level", cast[2].name, "Alt 6")

    -- Fewer favourites than seats must not empty the camp.
    eq("the cast is still full", #cast, 2)

    -- The hint counts who is SEATED, not who is pinned. Only characters with a
    -- portrait can be seated, so favouriting a portrait-less alt used to make
    -- the hint claim "your favourites first" over a scene of pure level picks.
    -- The first version of this test asserted the roster count and blessed it.
    eq("the hint counts favourites actually seated", T.FavouritesAmong(cast), 1)

    local function noArtForAlt1(c) return c.name ~= "Alt 1" and art or nil end
    local castNoArt = T.SceneCast(T.AllCharacters(), noArtForAlt1, 2)
    eq("a favourite with no portrait cannot be seated",
       T.FavouritesAmong(castNoArt), 0)
    check("  so the scene fills from level instead", castNoArt[1].name == "Alt 6")
    check("  while the roster still counts it as pinned",
          T.FavouritesAmong(T.AllCharacters()) == 1,
          "the roster and the cast are different questions")

    AltStableConfig.favouriteCharacters = nil
    eq("  and none are seated when none are pinned",
       T.FavouritesAmong(T.SceneCast(T.AllCharacters(), cut, 2)), 0)

    AltStableDB = saved
    AltStableConfig.favouriteCharacters = nil
end

------------------------------------------------------------
-- What the scene actually tells the player
------------------------------------------------------------
-- The hint claims either "your favourites first" or "highest level first", and
-- which one is true depends on who got SEATED - not on who is pinned. Only
-- characters with a portrait can be seated, so favouriting a portrait-less alt
-- used to produce a scene of pure level picks under a hint claiming otherwise.
--
-- This drives the real panel, because the bug was the renderer handing the
-- count the wrong list. Every test that checks FavouritesAmong directly passes
-- whichever list it is given.

do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB = {}
    for i = 1, 6 do
        local guid = ("wire-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Wire %d"):format(i),
                              level = i * 10, ilvl = i, class = "MAGE" }
    end

    -- Portraits for everyone EXCEPT Wire 1, who is the one we pin.
    AltStableCutoutManifest = {}
    for i = 2, 6 do
        AltStableCutoutManifest[("wire-%d"):format(i)] =
            { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    end

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)

    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.rosterView = "scene"
    T.Refresh()
    local guessed = T.HintText() or ""
    check("with nobody pinned the hint says it is guessing",
          guessed:find("highest level first", 1, true) ~= nil, guessed)

    -- Pin the one character that CANNOT be seated.
    AltStable.SetCharacterFavourite("wire-1", true)
    T.Refresh()
    local stillGuessing = T.HintText() or ""
    check("pinning a character with no portrait does not make it a choice",
          stillGuessing:find("highest level first", 1, true) ~= nil, stillGuessing)
    check("  and the hint does not claim otherwise",
          stillGuessing:find("favourites first", 1, true) == nil, stillGuessing)

    -- Pin one that can.
    AltStable.SetCharacterFavourite("wire-2", true)
    T.Refresh()
    local chosen = T.HintText() or ""
    check("pinning a character that can be seated does",
          chosen:find("favourites first", 1, true) ~= nil, chosen)

    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.rosterView = nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
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

------------------------------------------------------------
-- The card's right-click, and hidden characters (#69)
------------------------------------------------------------

do
    AltStableDB = {
        shown  = { guid = "shown",  name = "Shown One",  class = "MAGE",  realm = "R",
                   level = 60, race = "Human" },
        tucked = { guid = "tucked", name = "Tucked Away", class = "ROGUE", realm = "R",
                   level = 59, race = "Human" },
    }
    AltStableConfig.hiddenCharacters = {}
    AltStableConfig.favouriteCharacters = {}
    AltStable.SetCharacterHidden("tucked", true)
    AltStable.SetShowingHidden(false)

    local function names(list)
        local out = {}
        for _, c in ipairs(list) do out[#out + 1] = c.name end
        table.sort(out)
        return table.concat(out, ",")
    end

    eq("a hidden character is out of the card grid",
       names(T.CharactersFor("grid")), "Shown One")
    eq("  and out of the scene", names(T.CharactersFor("scene")), "Shown One")

    AltStable.SetShowingHidden(true)
    eq("with the toggle on, the grid lists it",
       names(T.CharactersFor("grid")), "Shown One,Tucked Away")

    -- The line that separates a management view from a showcase. The camp is a
    -- diorama; a dimmed figure standing in it says nothing to anybody, and
    -- there is no card there to right-click.
    eq("  but the scene still never shows one",
       names(T.CharactersFor("scene")), "Shown One")

    AltStable.SetShowingHidden(false)
    eq("switching it back off empties the grid of it again",
       names(T.CharactersFor("grid")), "Shown One")
end

do
    local card = T.BuildCard(WoW.makeFrame(), 1)

    -- The registration, not just the handler.
    --
    -- A Button fires OnClick for the LEFT button only until RegisterForClicks
    -- says otherwise. Every check below calls the handler directly with
    -- "RightButton", which the client would never do on an unregistered
    -- button - so without this the section passes against a card whose menu
    -- cannot be opened in game. The card had exactly that shape before #69:
    -- SetScript("OnClick") and no registration at all.
    check("the card listens for right-clicks",
          card:HandlesClick("RightButton"),
          table.concat(card:RegisteredClicks(), ","))
    check("  and still for left-clicks, which select",
          card:HandlesClick("LeftButton"),
          table.concat(card:RegisteredClicks(), ","))

    T.RenderCard(card, AltStableDB.shown, 100, 140)
    local onClick = card:GetScript("OnClick")
    check("the card handles clicks", type(onClick) == "function")

    if onClick then
        AltStable.CloseCharacterMenu()
        onClick(card, "RightButton")
        check("a right-click on a card opens the same menu the row does",
              AltStable._test.MenuIsShown())
        check("  about the character on that card",
              table.concat(AltStable._test.MenuLabels(), "|"):find("Shown One", 1, true) ~= nil,
              table.concat(AltStable._test.MenuLabels(), "|"))
        AltStable.CloseCharacterMenu()

        -- Cards are POOLED and re-rendered. A card still carrying the previous
        -- character would open a menu about somebody who is no longer on it.
        T.RenderCard(card, AltStableDB.tucked, 100, 140)
        onClick(card, "RightButton")
        check("a re-rendered card opens the menu for its NEW character",
              table.concat(AltStable._test.MenuLabels(), "|"):find("Tucked Away", 1, true) ~= nil,
              table.concat(AltStable._test.MenuLabels(), "|"))
        AltStable.CloseCharacterMenu()

        onClick(card, "LeftButton")
        check("a left-click still selects instead of opening a menu",
              AltStable._test.MenuIsShown() == false)
    end

    -- Dimmed exactly as a hidden row is, and set BOTH ways: the card showed
    -- somebody else a frame ago.
    T.RenderCard(card, AltStableDB.tucked, 100, 140)
    eq("a hidden character's card is dimmed", card:GetAlpha(), T.HIDDEN_CARD_ALPHA)
    T.RenderCard(card, AltStableDB.shown, 100, 140)
    eq("  and the next card drawn in it is not", card:GetAlpha(), 1)
end

------------------------------------------------------------
-- The scene draws from the SAME pool of cards as the grid
------------------------------------------------------------
-- Which makes every per-card property the two renderers do not both set a bug
-- waiting for a view switch. The right-click menu reads card.char, so a scene
-- that set only charGuid opened a menu titled with whoever that card held in
-- the GRID - and offered to forget them.

do
    AltStableDB = {}
    AltStableCutoutManifest = {}
    AltStableConfig.hiddenCharacters = {}
    AltStableConfig.favouriteCharacters = {}
    for i = 1, 8 do
        local guid = ("pool-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Pool %d"):format(i), class = "MAGE",
                              realm = "R", level = 60 - i, race = "Human" }
        -- Only the LAST few get portraits, so the scene's cast is a different
        -- set of characters from the grid's first cards - which is what makes
        -- a stale card.char point at the wrong person rather than the right one.
        if i >= 6 then
            AltStableCutoutManifest[("pool-%d"):format(i)] =
                { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
        end
    end

    local main = CreateFrame("Frame")
    main.GetWidth  = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)

    AltStableConfig.rosterView = "grid"
    T.Refresh()
    local first = T.Cards()[1]
    check("the grid put a character on the first card", first and first.char ~= nil)
    local inGrid = first and first.char and first.char.name

    AltStableConfig.rosterView = "scene"
    T.Refresh()
    check("the scene put a character on the first card too",
          first and first.char ~= nil,
          "a right-click on a scene figure would open a menu about nobody")
    eq("  and it is the one that card's guid says it is",
       first.char and first.char.guid, first.charGuid)
    check("  not the one the GRID left there",
          first.char and first.char.name ~= inGrid,
          ("both views put %s on card 1 - pick a fixture where they differ"):format(
              tostring(inGrid)))

    -- Same pool, same dimming rule. With the toggle on, the grid can leave a
    -- card at 45%; the scene must not inherit it.
    AltStable.SetShowingHidden(true)
    AltStable.SetCharacterHidden("pool-1", true)
    AltStableConfig.rosterView = "grid"
    T.Refresh()
    local dimmed
    for _, c in ipairs(T.Cards()) do
        if c.charGuid == "pool-1" then dimmed = c end
    end
    check("the hidden character's card is dimmed in the grid",
          dimmed and dimmed:GetAlpha() == T.HIDDEN_CARD_ALPHA,
          tostring(dimmed and dimmed:GetAlpha()))

    AltStableConfig.rosterView = "scene"
    T.Refresh()
    if dimmed and dimmed:IsShown() then
        eq("  and the scene figure drawn in that same card is not",
           dimmed:GetAlpha(), 1)
    end

    AltStable.SetCharacterHidden("pool-1", false)
    AltStable.SetShowingHidden(false)
end

------------------------------------------------------------
-- The way back is on this tab too
------------------------------------------------------------

do
    -- Hiding is unconfirmed since #69, and the only control that lists hidden
    -- characters so one can be right-clicked and unhidden is the sheet's
    -- footer. The Roster used to cover it with the panel and then hide it
    -- outright, which made this the one tab where you could hide a character
    -- from a card and find no way back without discovering that another tab
    -- has one.
    local main = CreateFrame("Frame")
    main.GetWidth  = function() return 1400 end
    main.GetHeight = function() return 800 end
    main.totalsBar = CreateFrame("Frame", nil, main)
    main.bodyScroll = CreateFrame("Frame", nil, main)

    T.Activate(main)
    check("the footer stays on screen on the Roster tab",
          main.totalsBar:IsShown(),
          "the (N hidden) toggle is the only route back from an unconfirmed hide")
    check("  while the grid it replaced does not", main.bodyScroll:IsShown() == false)

    -- Shown is not the same as VISIBLE. The panel is opaque and spans the body;
    -- leaving the totals bar shown underneath it looks identical to this test
    -- and identical to a covered footer in game, so the gap is asserted too.
    local footerH = (AltStable.LAYOUT and AltStable.LAYOUT.FOOTER_HEIGHT) or 22
    local bottomY
    local pnl = T.Panel()
    for i = 1, pnl:GetNumPoints() do
        local point, _, _, _, y = pnl:GetPoint(i)
        if point == "BOTTOMRIGHT" then bottomY = y end
    end
    check("  and the panel stops above it rather than covering it",
          bottomY ~= nil and bottomY >= footerH,
          ("panel bottom is %s, footer is %d tall"):format(tostring(bottomY), footerH))
end

------------------------------------------------------------
-- The character detail view (#91)
------------------------------------------------------------
-- A drill-down: selecting a character replaces the grid or the camp, and Back
-- returns you to whichever you came from. Every field it shows is already
-- scanned and stored - this is presentation over data the addon has held all
-- along and displayed nowhere.

do
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end

    AltStableDB = {
        geared = { guid = "geared", name = "Geared One", class = "PRIEST", realm = "R",
                   level = 60, race = "Human", raceName = "Human", guild = "A Guild",
                   ilvl = 61.5, money = 573920, restPercent = 42, xpPercent = 88,
                   lastUpdate = time() - 3600,
                   stat_hp = 3210, stat_mana = 4870, stat_armor = 812,
                   stat_str = 42, stat_agi = 53, stat_sta = 290,
                   stat_int = 493, stat_spi = 446,
                   stat_ap = 32, stat_sp = 728, stat_defense = 300,
                   stat_crit = 12.5, stat_hitpct = 3,
                   gear_head = 66, gearq_head = 4, gearid_head = 1001,
                   gearname_head = "A Hat", gearlink_head = "|Hitem:1001|h[A Hat]|h",
                   gear_chest = 58, gearq_chest = 3, gearid_chest = 1002,
                   gearname_chest = "A Robe", gearlink_chest = "|Hitem:1002|h[A Robe]|h" },
        bare   = { guid = "bare", name = "Bare One", class = "WARRIOR", realm = "R",
                   level = 12, race = "Orc", raceName = "Orc",
                   money = 0, lastUpdate = time() - 90000,
                   -- Combat is PARTLY filled on purpose: a warrior has attack
                   -- power and no spell power. A fixture where every stat in a
                   -- section is absent only ever exercises the section-level
                   -- filter, and a row-level one could be deleted unnoticed.
                   stat_ap = 140, stat_defense = 60 },
    }
    AltStableConfig.hiddenCharacters = {}
    AltStableConfig.favouriteCharacters = {}
    AltStableConfig.rosterView = "grid"
    T.Activate(main)
    T.Refresh()

    check("nothing is drilled into to begin with", T.DetailShown() == false)

    ----------------------------------------------------------
    -- Drilling in and back out
    ----------------------------------------------------------

    -- Through the CARD, not the function behind it. Calling DrillDown proves
    -- the function works and nothing about whether clicking a card reaches it -
    -- and the card's handler used to call Select, which only moves a highlight.
    check("clicking a card drills in", T.CardClick(1))

    -- The detail frame gets a REALISTIC SIZE from here on, because the stub does
    -- not compute layout: `detail` fills the panel in game, so GetHeight is the
    -- panel's height there and the stub's 20px default here. The stats column is
    -- clamped against that height, so leaving it at 20 makes every row overflow
    -- and the whole section below assert against a pane with nothing in it.
    --
    -- Set on the frame the code actually MEASURES, for the same reason the
    -- narrow-panel block further down says: a size on the parent does not reach
    -- the detail, and asserting against the parent's would be asserting against a
    -- number the code never reads.
    T.DetailFrame():SetWidth(1400)
    T.DetailFrame():SetHeight(800)
    T.Refresh()
    check("  the detail view is up", T.DetailShown())
    check("  showing the character on that card",
          (T.DetailText() or ""):find(T.Cards()[1].char.name, 1, true) ~= nil,
          T.DetailText())
    T.Back()

    check("a card drills into its character", T.DrillDown("geared"))
    check("  the detail view is up again", T.DetailShown())

    local head = T.DetailText() or ""
    check("  naming the character", head:find("Geared One", 1, true) ~= nil, head)
    check("  with level, race and class", head:find("Level 60 Human Priest", 1, true) ~= nil, head)
    check("  the guild and realm", head:find("<A Guild> - R", 1, true) ~= nil, head)
    check("  and the item level", head:find("61.5", 1, true) ~= nil, head)

    -- The cards go. Left shown they sit behind the detail still taking the
    -- mouse, so a click meant for the pane can land on a card and drill into
    -- somebody else - and the frames are siblings, so strata does not save it.
    do
        local visible = 0
        for _, card in ipairs(T.Cards()) do
            if card:IsShown() then visible = visible + 1 end
        end
        eq("no card is left behind the detail", visible, 0)
    end

    -- A guid that is not in the database is REFUSED. The pane would otherwise
    -- open on a blank header, an empty paper doll and an audit with nothing to
    -- audit, and say true - which is what a card rendered before a delete hands
    -- it.
    check("drilling into a character that is not there fails",
          T.DrillDown("no-such-guid") == false)
    check("  and leaves the pane where it was", T.DetailShown())

    check("something is selected while drilled in", T.Selected() ~= nil)
    check("Back leaves it", T.Back())
    check("  and the view returns", T.DetailShown() == false)
    -- A highlight left behind on the way out reads as a mode you cannot leave.
    eq("  and nothing is left selected", T.Selected(), nil)

    -- Leaving the tab leaves the drill-down. It is a per-visit state, like the
    -- tab it opens on: left set, the next visit to the Roster started inside the
    -- detail pane with no grid behind it and a Back button for a journey the
    -- player did not take.
    do
        T.DrillDown("geared")
        check("the pane is up before leaving the tab", T.DetailShown())
        T.Deactivate(main)
        T.Activate(main)
        T.Refresh()
        check("  and coming back to the tab shows the grid, not the pane",
              T.DetailShown() == false)
        eq("  with nothing selected", T.Selected(), nil)
    end

    -- Back must land where you came FROM. Leaving a camp and arriving in a
    -- spreadsheet is disorienting.
    AltStable.SetConfigValue("rosterView", "scene")
    T.Refresh()
    T.DrillDown("geared")
    check("drilling in from the scene works too", T.DetailShown())
    T.Back()
    -- NOT `T.View()`: that reads back the config value this test set two lines
    -- above, and nothing in Back writes it, so the assertion passed no matter
    -- what Back did - including landing in the grid. The scene's own furniture
    -- is what proves where you are.
    check("  and Back leaves you in the scene, not the grid", T.SceneBarShown() == true)
    eq("  with the button offering the way out of it", T.ViewButtonText(), "Grid")
    check("  and the camp drawn again, not the detail pane", T.DetailShown() == false)
    do
        local visible = 0
        for _, card in ipairs(T.Cards()) do
            if card:IsShown() then visible = visible + 1 end
        end
        eq("  with no grid cards behind it", visible, 0)
    end

    -- And the same assertion the other way round, or "the scene bar is up"
    -- would be satisfied by a bar that is always up.
    AltStable.SetConfigValue("rosterView", "grid")
    T.Refresh()
    T.DrillDown("geared")
    T.Back()
    check("Back from the grid leaves you in the grid", T.SceneBarShown() == false)
    eq("  with the button offering the scene", T.ViewButtonText(), "Scene")
    AltStable.SetConfigValue("rosterView", "scene")
    T.Refresh()
    AltStable.SetConfigValue("rosterView", "grid")
    T.Refresh()

    ----------------------------------------------------------
    -- The stats
    ----------------------------------------------------------

    T.DrillDown("geared")
    local stats = table.concat(T.DetailStats(), " | ")

    check("the Status section is drawn", stats:find("Status", 1, true) ~= nil, stats)
    -- The VALUE, not just the label. "Gold=" is true of the raw copper count.
    check("gold is formatted as money, not a copper count",
          stats:find("Gold=57", 1, true) ~= nil and stats:find("573920", 1, true) == nil, stats)
    check("  and last online in words, not an epoch",
          stats:find("ago", 1, true) ~= nil and stats:find("17", 1, true) == nil, stats)

    -- "Online" is reserved for the character you are logged in as, and the flag
    -- that says so was hardcoded to false here - so the one character whose
    -- timestamp is guaranteed fresh was the only one that could never read it,
    -- while reading "0m ago" about itself. RowRenderer's tooltip passes the same
    -- comparison.
    do
        local mine = UnitGUID("player")
        AltStableDB[mine] = { guid = mine, name = "Me", class = "MAGE", realm = "R",
            level = 60, race = "Human", raceName = "Human", ilvl = 40, money = 100,
            stat_int = 200, lastUpdate = time() - 5 }
        T.Refresh()
        T.DrillDown(mine)
        -- Matched on the VALUE, not on "Online" anywhere in the string: the row
        -- is LABELLED "Last Online", so a bare find passes for every character
        -- ever rendered.
        local own = table.concat(T.DetailStats(), " | ")
        check("your own character reads Online, not '0m ago'",
              own:find("Last Online=|cff00ff00Online", 1, true) ~= nil, own)
        -- And a different character with the same fresh timestamp does NOT,
        -- or "Online" would just mean "recent".
        AltStableDB.fresh = { guid = "fresh", name = "Fresh One", class = "MAGE",
            realm = "R", level = 60, race = "Human", raceName = "Human", ilvl = 40,
            money = 100, stat_int = 200, lastUpdate = time() - 5 }
        T.Refresh()
        T.DrillDown("fresh")
        local other = table.concat(T.DetailStats(), " | ")
        check("  while somebody else that fresh reads minutes ago",
              other:find("Last Online=|cff00ff00Online", 1, true) == nil
              and other:find("ago", 1, true) ~= nil, other)
        AltStableDB[mine], AltStableDB.fresh = nil, nil
        T.Refresh()
        T.DrillDown("geared")
    end

    -- The XP rows, which depend on the LEVEL and not only on the value.
    --
    -- `geared` is at the cap, and at the cap the scanner writes a literal 0 to
    -- both XP fields to say "there is no next level". With allowZero set - which
    -- these two rows need, since 0% rested while levelling is a real answer -
    -- that produced "Rested XP 0%" and "XP Progress 0%" on every capped
    -- character: a precise figure for a bar that is not on screen.
    check("a capped character is not told its rested XP is 0%",
          stats:find("Rested XP", 1, true) == nil, stats)
    check("  nor its XP progress", stats:find("XP Progress", 1, true) == nil, stats)
    -- And the rows are not simply gone: a levelling character still gets them,
    -- or "hidden at the cap" would be satisfied by deleting them outright.
    do
        AltStableDB.levelling = { guid = "levelling", name = "Levelling One",
            class = "PRIEST", realm = "R", level = 59, race = "Human",
            raceName = "Human", ilvl = 40, money = 100, stat_int = 200,
            restPercent = 42, xpPercent = 88, lastUpdate = time() - 3600 }
        T.Refresh()
        T.DrillDown("levelling")
        local low = table.concat(T.DetailStats(), " | ")
        check("a levelling character still gets its rested percent",
              low:find("Rested XP=42%", 1, true) ~= nil, low)
        check("  and its XP progress", low:find("XP Progress=88%", 1, true) ~= nil, low)
        -- Zero is still a real answer BELOW the cap, which is what allowZero is
        -- for and what the level test must not have thrown away.
        AltStableDB.levelling.restPercent = 0
        T.DrillDown("levelling")
        check("  including a genuine 0% rested",
              table.concat(T.DetailStats(), " | "):find("Rested XP=0%", 1, true) ~= nil)
        AltStableDB.levelling = nil
        T.Refresh()
        T.DrillDown("geared")
    end

    check("Attributes are drawn", stats:find("Intellect=493", 1, true) ~= nil, stats)
    check("Resources too", stats:find("Health=3210", 1, true) ~= nil, stats)

    -- The two stats that exist in Vanilla and had to be added to the scanner.
    check("melee crit is shown to two places", stats:find("Melee Crit=12.50%", 1, true) ~= nil, stats)

    -- Bonus hit IS offered now, and LABELLED as bonus hit. MEASURED on
    -- 1.60.1.70009: GetHitModifier() printed 0, which is a number rather than
    -- ABSENT or nil, so the function works. What it returns is the hit percent
    -- your GEAR adds - so "Hit Chance" would have been the wrong label whatever
    -- the value: no bonus hit is not a 0% chance to hit anything.
    check("the row is labelled Bonus Hit, not Hit Chance",
          stats:find("Hit Chance", 1, true) == nil, stats)

    -- And the two that do NOT exist pre-TBC, which must not have been ported
    -- along with the rest of AltTracker's table.
    -- Asserted on the TABLE rather than the rendering. A row for a stat nobody
    -- has is invisible either way, so a rendered check passes whether or not
    -- the row was ported - the question is whether it is in the definition.
    local defined = {}
    for _, g in ipairs(T.CHAR_STAT_GROUPS) do
        for _, d in ipairs(g.defs) do defined[d.key] = true end
    end
    check("haste is not in the table at all", not defined.stat_haste)
    check("  nor resilience", not defined.stat_resilience)
    check("  while the crit row is", defined.stat_crit)
    check("  and the bonus-hit row is too, now it is measured", defined.stat_hitpct)

    -- The row HIDES at zero, which is the whole reason it is safe to offer.
    -- GetHitModifier reports what gear adds, a nonzero reading is still
    -- unobserved on this client, and allowZero is deliberately absent so nobody
    -- is shown a precise 0.00% that might turn out to mean nothing.
    do
        local hitDef
        for _, g in ipairs(T.CHAR_STAT_GROUPS) do
            for _, d in ipairs(g.defs) do
                if d.key == "stat_hitpct" then hitDef = d end
            end
        end
        check("the bonus-hit row does not claim zero is worth showing",
              hitDef and not hitDef.allowZero)
        check("  so a character with no +hit gear is not given the row",
              T.HasStatValue({ stat_hitpct = 0 }, hitDef) == false)
        check("  while one that has some is",
              T.HasStatValue({ stat_hitpct = 2 }, hitDef) == true)
        -- And rendered as a percentage to two places, like crit beside it,
        -- rather than a bare number.
        eq("  formatted as a percentage", T.FormatStatValue({ stat_hitpct = 2 }, hitDef),
           "2.00%")

        -- Through the pane, not only the table: a character carrying some.
        AltStableDB.hitty = { guid = "hitty", name = "Hit Ty", class = "WARRIOR",
            realm = "R", level = 60, race = "Human", raceName = "Human", ilvl = 40,
            money = 100, stat_int = 10, lastUpdate = time() - 60, stat_hitpct = 3 }
        T.Refresh()
        T.DrillDown("hitty")
        local hitStats = table.concat(T.DetailStats(), " | ")
        check("a character with bonus hit sees the row",
              hitStats:find("Bonus Hit=3.00%", 1, true) ~= nil, hitStats)
        AltStableDB.hitty.stat_hitpct = 0
        T.DrillDown("hitty")
        check("  and one without does not",
              table.concat(T.DetailStats(), " | "):find("Bonus Hit", 1, true) == nil)
        AltStableDB.hitty = nil
        T.Refresh()
        T.DrillDown("geared")
    end
    check("haste is not rendered either", stats:find("Haste", 1, true) == nil, stats)
    check("  and the scanner does not invent them",
          AltStableDB.geared.stat_haste == nil and AltStableDB.geared.stat_resilience == nil)

    ----------------------------------------------------------
    -- A character with almost nothing recorded
    ----------------------------------------------------------

    T.DrillDown("bare")
    local bare = table.concat(T.DetailStats(), " | ")

    -- Zero gold is a FACT and survives; a warrior's absent spell power is not
    -- a zero and its row goes, taking an empty section's header with it.
    check("zero gold is still shown", bare:find("Gold=", 1, true) ~= nil, bare)
    check("  but absent stats are not rows of dashes",
          bare:find("Intellect", 1, true) == nil, bare)
    check("  and a section with nothing in it takes its header",
          bare:find("Attributes", 1, true) == nil, bare)

    -- The row-level filter, which the section-level one would otherwise hide.
    check("a partly-filled section keeps its header", bare:find("Combat", 1, true) ~= nil, bare)
    check("  and the stats that are there", bare:find("Attack Power=140", 1, true) ~= nil, bare)
    check("  while the ones that are not are absent, not dashes",
          bare:find("Spell Power", 1, true) == nil, bare)

    ----------------------------------------------------------
    -- The equipped slots
    ----------------------------------------------------------

    T.DrillDown("geared")
    local slots = table.concat(T.DetailSlots(), " | ")
    eq("every slot is drawn", #T.DetailSlots(), #T.GEAR_SLOTS)
    check("  an equipped one carries its item level",
          slots:find("head=66", 1, true) ~= nil, slots)
    check("  and another", slots:find("chest=58", 1, true) ~= nil, slots)
    -- An EMPTY slot still draws, blank. A paper doll with holes in it is how
    -- you see the character has no cloak.
    check("  an empty one is drawn without a number",
          slots:find("back=", 1, true) ~= nil and slots:find("back=%d") == nil, slots)

    ----------------------------------------------------------
    -- Surviving what happens around it
    ----------------------------------------------------------

    -- The Roster repaints on every sync. A refresh must not bounce us out.
    T.Refresh()
    check("a refresh does not drop you out of the detail", T.DetailShown())

    -- But a character that goes away while you are looking at it must not
    -- leave a blank pane.
    AltStableDB.geared = nil
    T.Refresh()
    check("a forgotten character falls back to the view", T.DetailShown() == false)
end

------------------------------------------------------------
-- The enchant audit (#91)
------------------------------------------------------------
-- AltTracker audited gems, sockets and meta-gems across 842 lines. None of
-- that exists pre-TBC. What is left is enchants.
--
-- Read from gearmod_<slot>, which is "ench:sockets:g1:g2:g3" and IS SYNCED -
-- the scanner marks it so and test_comm asserts it must ride the wire. An
-- earlier version read gearlink_, which Core strips at the sync boundary as
-- too large: every peer-synced character came out as a wall of "cannot read
-- the item", so the whole tab was noise for any character not scanned here.

do
    local FLOOR = T.AuditFloor()
    check("there is a level floor", FLOOR and FLOOR > 1, tostring(FLOOR))

    -- And it is a SETTING, not a law. It was briefly hardcoded to the level cap
    -- in the same change that deleted the persisted `auditMinLevel` - the same
    -- policy with the choice taken away. The gem settings went because sockets
    -- do not exist on this client; the level gate is a different question.
    do
        local saved = AltStableConfig.auditMinLevel
        AltStableConfig.auditMinLevel = 20
        eq("the floor honours auditMinLevel", T.AuditFloor(), 20)
        -- Clamped both ways: it is a number on disk. Above the cap audits
        -- nobody and reads as a broken tab; at 0 it audits every level 1 alt.
        AltStableConfig.auditMinLevel = 9999
        eq("  clamped to the level cap", T.AuditFloor(), FLOOR)
        AltStableConfig.auditMinLevel = 0
        check("  and never below 2", T.AuditFloor() >= 2, tostring(T.AuditFloor()))
        AltStableConfig.auditMinLevel = nil
        eq("  with the cap as the default", T.AuditFloor(), FLOOR)
        AltStableConfig.auditMinLevel = saved
    end

    ----------------------------------------------------------
    -- Reading an enchant off the packed field
    ----------------------------------------------------------

    eq("a zero enchant means no enchant", T.EnchantFromMod("0:0:0:0:0"), nil)
    eq("an enchant id is read", T.EnchantFromMod("2504:0:0:0:0"), 2504)
    eq("  and one beside real sockets", T.EnchantFromMod("2661:2:24028:35759:0"), 2661)

    -- tonumber, not a string compare. Classic-era links were historically
    -- written with padded zero fields, and "00" is truthy as a string.
    eq("a padded zero is still no enchant", T.EnchantFromMod("00:0:0:0:0"), nil)
    eq("  and a signed one", T.EnchantFromMod("-0:0:0:0:0"), nil)

    -- "Cannot tell" is a THIRD answer and must never collapse into "fine".
    eq("an empty packed field cannot be read", T.EnchantFromMod(""), false)
    eq("  nor a missing one", T.EnchantFromMod(nil), false)
    eq("  nor a malformed one", T.EnchantFromMod("not packed at all"), false)

    ----------------------------------------------------------
    -- Which slots take one
    ----------------------------------------------------------

    check("chest does", T.ENCHANTABLE_SLOTS.chest)
    check("  and weapons", T.ENCHANTABLE_SLOTS.mainhand)
    check("rings do not", not T.ENCHANTABLE_SLOTS.ring1 and not T.ENCHANTABLE_SLOTS.ring2)
    check("  nor the neck", not T.ENCHANTABLE_SLOTS.neck)

    -- Offhand by EQUIP LOCATION, a locale-independent token. The item SUBTYPE
    -- is the localised display string - "Shields" on enUS, "Schilde" on deDE -
    -- so comparing against it would never fire outside English.
    --
    -- Resolved from gearid_offhand, which IS SYNCED, rather than read from a
    -- stored token which was not: an earlier version stored the token for all
    -- seventeen slots and then had to exclude it from sync, so every
    -- peer-synced character reported "cannot tell" for its off-hand for ever.
    -- GetItemInfoInstant needs no item cache, so there is nothing to store.
    WoW.items[6001] = { name = "A Shield",   equipLoc = "INVTYPE_SHIELD",         icon = 1 }
    WoW.items[6002] = { name = "An Off-hand", equipLoc = "INVTYPE_WEAPONOFFHAND", icon = 2 }
    WoW.items[6003] = { name = "A Tome",     equipLoc = "INVTYPE_HOLDABLE",       icon = 3 }

    eq("a shield takes an enchant",
       T.EnchantableHere({ gearid_offhand = 6001 }, "offhand"), true)
    -- The case a shields-only whitelist dropped: an off-hand WEAPON, one of
    -- the most commonly forgotten enchants there is.
    eq("so does an off-hand weapon",
       T.EnchantableHere({ gearid_offhand = 6002 }, "offhand"), true)
    eq("a held-in-hand frill does not",
       T.EnchantableHere({ gearid_offhand = 6003 }, "offhand"), false)
    -- The id is what rides the wire, so a remote character resolves the same
    -- way a local one does - the case the stored token could never answer.
    eq("  and a synced id resolves identically",
       T.EnchantableHere({ gearid_offhand = "6003" }, "offhand"), false)
    -- An id the client has no data for at all: still "cannot tell", never
    -- "fine", and never a false "no enchant" finding.
    eq("an id with no item data is 'cannot tell'",
       T.EnchantableHere({ gearid_offhand = 999999 }, "offhand"), nil)
    -- Nothing equipped is not "cannot tell": there is nothing to enchant.
    eq("an empty off-hand is simply not enchantable",
       T.EnchantableHere({}, "offhand"), false)

    ----------------------------------------------------------
    -- What gets reported
    ----------------------------------------------------------

    local function findings(char)
        char.level = char.level or FLOOR
        local out = {}
        for _, f in ipairs(T.AuditCharacter(char)) do
            out[#out + 1] = f.slot .. ":" .. f.issue
        end
        return table.concat(out, " | ")
    end

    eq("an unenchanted chest is a finding",
       findings({ gearid_chest = 10, gearmod_chest = "0:0:0:0:0" }), "chest:no enchant")
    eq("  and an enchanted one is not",
       findings({ gearid_chest = 10, gearmod_chest = "2504:0:0:0:0" }), "")

    -- A peer-synced character HAS gearmod_, which is the whole reason for
    -- reading it: this is the case the old version got wrong for 100% of
    -- remote characters.
    eq("a synced character audits normally",
       findings({ gearid_chest = 10, gearmod_chest = "0:0:0:0:0",
                  gearid_wrist = 11, gearmod_wrist = "2504:0:0:0:0" }),
       "chest:no enchant")

    -- An EMPTY slot is not a finding: already obvious on the paper doll.
    eq("an empty slot is not reported",
       findings({ gearid_chest = 0, gearid_head = 10, gearmod_head = "0:0:0:0:0" }), "")

    eq("an unreadable packed field says so",
       findings({ gearid_wrist = 10, gearmod_wrist = "" }),
       "wrist:cannot read the item")

    -- An occupied off-hand whose kind is unknown is REPORTED as unknown, not
    -- dropped. A slot silently vanishing from the audit is the same thing as
    -- calling it clean.
    eq("an off-hand of unknown kind is reported, not dropped",
       findings({ gearid_offhand = 999999, gearmod_offhand = "0:0:0:0:0" }),
       "offhand:cannot tell - no item data")
    -- And the id is QUEUED, so "cannot tell" is a wait and not a verdict. Core
    -- has watched this queue since the gem audit; with the gems gone nothing
    -- filled it, so the branch there was dead code AND a remote character's
    -- unknown off-hand stayed unreadable for the whole session. The id the
    -- client cannot resolve arrives later as GET_ITEM_INFO_RECEIVED.
    check("  and the unresolved id is queued for a retry",
          AltStable.PendingAuditItems and AltStable.PendingAuditItems[999999] == true,
          tostring(AltStable.PendingAuditItems))
    -- An id that DID resolve is not queued: the queue is a list of things to
    -- wait for, and everything-in-it is the same as nothing-in-it.
    AltStable.PendingAuditItems = nil
    findings({ gearid_offhand = 6001, gearmod_offhand = "2504:0:0:0:0" })
    check("  while a resolvable one is not",
          AltStable.PendingAuditItems == nil
          or AltStable.PendingAuditItems[6001] == nil)
    AltStable.PendingAuditItems = nil
    eq("  while a known frill is simply not audited",
       findings({ gearid_offhand = 6003, gearmod_offhand = "0:0:0:0:0" }), "")
    eq("  and an unenchanted shield IS a finding",
       findings({ gearid_offhand = 6001, gearmod_offhand = "0:0:0:0:0" }),
       "offhand:no enchant")

    -- Worst first, then alphabetical. The slots are chosen so the sorted order
    -- differs from the order GEAR_SLOTS is WALKED in - wrist, hands, feet -
    -- or deleting the sort would change nothing.
    local both = T.AuditCharacter({
        level = FLOOR,
        gearid_wrist = 10, gearmod_wrist = "",
        gearid_hands = 10, gearmod_hands = "0:0:0:0:0",
        gearid_feet  = 10, gearmod_feet  = "0:0:0:0:0",
    })
    eq("three findings", #both, 3)
    eq("findings are ordered worst first", both[1].issue, "no enchant")
    eq("  alphabetically within that", both[1].label, "Feet")
    eq("  and not in the order the slots are walked", both[2].label, "Hands")
    eq("  with the unreadable one last", both[3].issue, "cannot read the item")

    ----------------------------------------------------------
    -- When the audit does not run at all
    ----------------------------------------------------------

    -- A level gate, which AltTracker had as auditMinLevel and which was
    -- dropped along with the GEM settings by mistake: that argument was about
    -- a quality threshold and this is a different setting. A levelling alt in
    -- quest greens would otherwise get a screenful of non-actionable rows.
    local lowFindings, lowReason = T.AuditCharacter({
        level = 14, gearid_chest = 10, gearmod_chest = "0:0:0:0:0" })
    eq("a levelling alt produces no findings", #lowFindings, 0)
    check("  and is told why rather than called clean",
          (lowReason or ""):find("Not audited below level", 1, true) ~= nil, tostring(lowReason))

    -- "Nothing to check" is not "all clear" either.
    local bareFindings, bareReason = T.AuditCharacter({ level = FLOOR })
    eq("a character wearing nothing produces no findings", #bareFindings, 0)
    check("  and is not told everything is enchanted",
          (bareReason or ""):find("Nothing equipped", 1, true) ~= nil, tostring(bareReason))

    ----------------------------------------------------------
    -- The tab
    ----------------------------------------------------------

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    AltStableDB = {
        messy = { guid = "messy", name = "Messy One", class = "MAGE", realm = "R",
                  level = FLOOR, race = "Human", raceName = "Human", ilvl = 50,
                  money = 100, stat_int = 400,
                  gearid_chest = 10, gearmod_chest = "0:0:0:0:0" },
        tidy  = { guid = "tidy", name = "Tidy One", class = "MAGE", realm = "R",
                  level = FLOOR, race = "Human", raceName = "Human", ilvl = 50,
                  money = 100, stat_int = 400,
                  gearid_chest = 10, gearmod_chest = "2504:0:0:0:0" },
        naked = { guid = "naked", name = "Naked One", class = "MAGE", realm = "R",
                  level = FLOOR, race = "Human", raceName = "Human", ilvl = 0,
                  money = 100, stat_int = 400 },
    }
    AltStableConfig.hiddenCharacters = {}
    AltStableConfig.favouriteCharacters = {}
    AltStableConfig.rosterView = "grid"
    T.Activate(main)
    T.Refresh()

    T.DrillDown("messy")
    eq("drilling in opens on Char, not wherever you left it", T.DetailTab(), "char")
    check("  so the stats are showing",
          table.concat(T.DetailStats(), "|"):find("Intellect", 1, true) ~= nil)
    eq("  and no audit rows are", #T.DetailAudit(), 0)

    -- The ACTIVE tab is the one you are not invited to press, and a seam that
    -- fires a disabled button's handler proves something the player cannot do.
    check("the tab you are on cannot be pressed", T.TabClick("Char") == false)
    -- The audit is not computed on the Char tab. Refresh runs on every sync
    -- and Char is the tab you always land on, so a pass whose result is thrown
    -- away is work on a timer - and it is invisible without counting.
    do
        local before = T.AuditCalls()
        T.Refresh()
        eq("a refresh on the Char tab does not run the audit", T.AuditCalls(), before)
    end

    check("the Audit tab is a button", T.TabClick("Audit"))
    check("  and now Char is the one that can be", T.TabClick("Audit") == false)
    eq("  which switches to it", T.DetailTab(), "audit")

    -- The active tab carries a marker of its OWN, not only a text colour.
    -- UIPanelButtonTemplate swaps in its disabled font object when a button is
    -- disabled, which reapplies that object's colour and discards a SetTextColor
    -- on the current font string - so on a client where it does that, the only
    -- signal left was "greyed out", which reads as unavailable rather than "you
    -- are here".
    do
        local marked = {}
        for _, b in ipairs(T.DetailTabs()) do
            if b.activeMark and b.activeMark:IsShown() then marked[#marked + 1] = b.id end
        end
        eq("exactly one tab is marked active", #marked, 1)
        eq("  and it is the one you are on", marked[1], "audit")
    end

    local rows = table.concat(T.DetailAudit(), " | ")
    check("  showing the finding", rows:find("Chest=no enchant", 1, true) ~= nil, rows)
    do
        local before = T.AuditCalls()
        T.Refresh()
        check("  and on THIS tab a refresh does run it", T.AuditCalls() > before)
    end
    eq("  and the stats step aside", #T.DetailStats(), 0)

    check("Char is a button too", T.TabClick("Char"))
    eq("  and switches back", T.DetailTab(), "char")
    check("  bringing the stats with it", #T.DetailStats() > 0)

    T.DrillDown("tidy")
    T.TabClick("Audit")
    local clean = table.concat(T.DetailAudit(), " | ")
    check("a clean character is told so",
          clean:find("Every enchantable slot", 1, true) ~= nil, clean)

    -- The reason line has to be BOUNDED. With only a TOPLEFT anchor a
    -- FontString is as wide as its text, and the longest of these sentences
    -- ran off the right of the panel and out over the game world - reported
    -- from a live client.
    do
        local none = T.DetailAuditLine()
        check("the reason line has a right edge", none and none:GetNumPoints() >= 2,
              tostring(none and none:GetNumPoints()))
        -- TOPRIGHT specifically. A bare RIGHT pins the vertical CENTRE to the
        -- same y that the TOPLEFT beside it pins the TOP to, which asks for a
        -- height of zero: the line goes invisible, and the explicit SetHeight
        -- cannot rescue it because two conflicting anchors beat a set size. So
        -- the assertion is on the exact point and not merely "has a right
        -- edge" - "has a right edge" is what the broken version passed.
        local points = {}
        for i = 1, (none and none:GetNumPoints() or 0) do
            points[(none:GetPoint(i))] = true
        end
        check("  anchored TOPLEFT and TOPRIGHT, so it wraps at a real height",
              points.TOPLEFT and points.TOPRIGHT,
              table.concat((function() local t = {}
                  for k in pairs(points) do t[#t + 1] = k end
                  table.sort(t); return t end)(), "+"))
        check("  and not on a bare RIGHT, which would collapse it", not points.RIGHT)
        -- The stub has to MODEL wrapping for the line above to mean anything:
        -- a chaining no-op leaves GetWordWrap returning the frame itself,
        -- which is truthy, and the assertion passes either way. Pinned here
        -- rather than assumed.
        local scratch = CreateFrame("Frame"):CreateFontString()
        scratch:SetWordWrap(false)
        eq("wrapping is real state in the stubs", scratch:GetWordWrap(), false)
        scratch:SetWordWrap(true)
        eq("  both ways", scratch:GetWordWrap(), true)
        -- And nil is FALSE, not "leave it alone". These take a boolean, so a
        -- missing argument is a falsy one - the stub wrote `v ~= false`, which
        -- turned SetWordWrap(nil) into SetWordWrap(true) and made a caller
        -- passing a nil flag by mistake look correct here and do the opposite in
        -- game.
        scratch:SetWordWrap(nil)
        eq("  and nil turns it off, as the client does", scratch:GetWordWrap(), false)
        -- Untouched is still ON, which is what a fresh FontString is.
        eq("  while a fresh one wraps",
           CreateFrame("Frame"):CreateFontString():GetWordWrap(), true)

        -- A FontString's height is TEXT-DEPENDENT, and empty means zero.
        --
        -- Pinned directly because it is a stub contract that nothing else
        -- exercises any more: the Roster stopped measuring an empty font string,
        -- which is the bug this models, so without an assertion here the stub
        -- could quietly go back to a fixed height and the next piece of code
        -- that reserves room for a font string would overflow in game and pass
        -- in the suite. That is exactly what happened.
        local empty = CreateFrame("Frame"):CreateFontString()
        eq("an empty font string has no height", empty:GetHeight(), 0)
        empty:SetText("something")
        check("  and a populated one does", empty:GetHeight() > 0,
              tostring(empty:GetHeight()))
        empty:SetText("")
        eq("  and clearing it takes the height away again", empty:GetHeight(), 0)
        -- Told how tall to be rather than asked: an explicit size wins, as on
        -- the client, or the Roster's own reason line could not set its height.
        empty:SetHeight(33)
        eq("  while an explicit SetHeight wins over both", empty:GetHeight(), 33)

        -- Same rule for enabled state, which the active tab depends on.
        local btn = CreateFrame("Button")
        eq("a fresh button is enabled", btn:IsEnabled(), true)
        btn:SetEnabled(nil)
        eq("  and SetEnabled(nil) disables it", btn:IsEnabled(), false)
        btn:SetEnabled(true)
        eq("  both ways", btn:IsEnabled(), true)

        -- And the SUBLEVEL survives the client's real argument order:
        -- CreateTexture(name, drawLayer, templateName, subLevel). The template
        -- slot is third and easy to drop, and dropping it shifts the sublevel
        -- into it - so every explicit sublevel in the addon read back nil and
        -- every draw-order assertion compared 0 against 0.
        local layered = CreateFrame("Frame"):CreateTexture(nil, "BACKGROUND", nil, 4)
        local gotLayer, gotSub = layered:GetDrawLayer()
        eq("the stub keeps a texture's layer", gotLayer, "BACKGROUND")
        eq("  and its sublevel, from the fourth argument", gotSub, 4)
        -- SetDrawLayer RESETS the sublevel when it is not given, rather than
        -- leaving the previous one behind.
        layered:SetDrawLayer("ARTWORK")
        local _, resetSub = layered:GetDrawLayer()
        eq("  which SetDrawLayer resets when it is omitted", resetSub, 0)

        -- A solid colour is recorded too: a quality border's whole job is which
        -- colour it is, and a chaining no-op let the palette lose an entry with
        -- every test still passing.
        local swatch = CreateFrame("Frame"):CreateTexture()
        swatch:SetColorTexture(0.25, 0.5, 0.75, 1)
        local c = swatch._colorTexture or {}
        check("a solid colour is real state in the stubs",
              c[1] == 0.25 and c[2] == 0.5 and c[3] == 0.75, tostring(c[1]))

        check("  and wrapping is on for the reason line",
              none:GetWordWrap() == true)
    end

    -- The gear icons themselves.
    --
    -- Every slot drew the question-mark fallback, because the lookup was a
    -- bare GetItemIcon - which Compat names as a known trap and test_compat
    -- asserts is nil on the adapter, since C_Item's version takes an
    -- ItemLocation and errors on an id. The right call is GetItemIconByID.
    do
        WoW.items[4242] = { name = "A Real Chest", quality = 3, ilvl = 40,
                            icon = 133076, equipLoc = "INVTYPE_CHEST" }
        AltStableDB.messy.gearid_chest = 4242
        AltStableDB.messy.gear_chest = 40
        AltStableDB.messy.gearq_chest = 3
        T.DrillDown("messy")
        local slot = T.DetailSlotFrame("chest")
        eq("an equipped slot shows the ITEM's icon", slot and slot.icon:GetTexture(), 133076)
        check("  and not the question-mark fallback",
              tostring(slot and slot.icon:GetTexture()):find("QuestionMark") == nil)

        -- An empty slot still draws, and the fallback is right THERE.
        local empty = T.DetailSlotFrame("ranged")
        check("an empty slot keeps the placeholder",
              tostring(empty and empty.icon:GetTexture()):find("QuestionMark") ~= nil,
              tostring(empty and empty.icon:GetTexture()))
    end

    -- The slots are laid out AROUND the figure. The first version anchored the
    -- left column at a fixed x and started the bottom row at the same one, so
    -- the weapons ran underneath the figure rather than beneath it.
    do
        -- A realistic panel. The stub's default frame height is 20, which
        -- trips the "too short for both" clamp - correct behaviour, and not
        -- the geometry this block is about.
        T.DrillDown("messy")
        local d = T.DetailFrame()
        d:SetWidth(1170)
        d:SetHeight(700)
        T.Refresh()

        local function xOf(key)
            local b = T.DetailSlotFrame(key)
            local _, _, _, bx = b:GetPoint(1)
            return bx or 0
        end
        -- Read from the stage rather than reconstructed from a margin: the
        -- composition is centred on a wide panel, so the figure's centre is not
        -- a constant any more.
        local figureCx = T.DetailFigureBox().centre
        check("the left column sits left of the figure", xOf("head") < figureCx - 100,
              tostring(xOf("head")))
        check("  and the right column right of it", xOf("hands") > figureCx + 100,
              tostring(xOf("hands")))
        check("  and neither is off the left edge", xOf("head") >= 0, tostring(xOf("head")))

        -- The bottom row is centred under the figure, not started at the left.
        local first, last = xOf("trinket1"), xOf("ranged")
        local mid = (first + last) / 2
        check("the bottom row is centred under the figure",
              math.abs(mid - figureCx) < 30,
              ("row centre %d vs figure %d"):format(mid, figureCx))

        -- And BELOW it, not across its legs. The weapons used to be placed six
        -- rows down from the top regardless of how tall the figure was.
        local function yOf(key)
            local b = T.DetailSlotFrame(key)
            local _, _, _, _, by = b:GetPoint(1)
            return by or 0
        end
        local fig = T.DetailFigureBox()
        check("the weapons sit below the figure, not on it",
              yOf("mainhand") <= fig.bottom,
              ("weapons at %s, figure ends at %s"):format(
                  tostring(yOf("mainhand")), tostring(fig.bottom)))
        check("  while the side columns start beside it",
              yOf("head") > fig.bottom, tostring(yOf("head")))

        -- A cutout is a transparent image with nothing behind it, so on a flat
        -- panel it floats and anything near it reads as colliding. The box is
        -- what makes the figure look like it is INSIDE something.
        check("the figure sits in a box", fig.height > 0 and fig.width > 0,
              ("%sx%s"):format(tostring(fig.width), tostring(fig.height)))
        -- The invariant that actually matters: a weapons row's worth of space
        -- below the box, INSIDE the panel. "The box is smaller than the panel"
        -- is satisfied by a figure that still pushes the weapons off the
        -- bottom edge, which is what the previous version of this allowed.
        local roomBelow = fig.bottom - (-700)
        check("  leaving a weapons row's room below it, inside the panel",
              roomBelow >= 56,
              ("only %s left below the figure"):format(tostring(roomBelow)))

        -- And the box is BEHIND the figure, not over it.
        check("the box is behind the figure",
              T.DetailStageLayer() == "BACKGROUND", tostring(T.DetailStageLayer()))

        -- The box is an inset with a BORDER, which means the edge has to be
        -- BEHIND the inset. Both are BACKGROUND textures, so "same layer" is
        -- not enough: within a layer the client resolves sublevel first and
        -- creation order second, and with neither set the edge - created
        -- afterwards - covered the inset completely and the whole box read as
        -- one flat light-grey rectangle. Not subtle: a lid. Exactly the bug
        -- this same change fixed for the item-quality border.
        local ord = T.DetailStageOrder()
        local function inFrontOf(a, b)
            if a.layer ~= b.layer then return nil end        -- decided elsewhere
            if a.sublevel ~= b.sublevel then return a.sublevel > b.sublevel end
            return (a.created or 0) > (b.created or 0)
        end
        eq("the inset and its edge are in the same layer", ord.inset.layer, ord.edge.layer)
        check("  and the inset draws in FRONT of the edge, so it is a border",
              inFrontOf(ord.inset, ord.edge) == true,
              ("inset sub=%s seq=%s vs edge sub=%s seq=%s"):format(
                  tostring(ord.inset.sublevel), tostring(ord.inset.created),
                  tostring(ord.edge.sublevel), tostring(ord.edge.created)))
        -- And the pane they sit on belongs to the TAB, not to the drill-down.
        -- It used to paint its own, which is invisible while it is opaque and
        -- doubles the density the moment it is not: pane over pane came out at
        -- ~0.86 against the grid's 0.62, so the character sheet read darker
        -- than the tab it was opened from.
        -- And painted from the SKIN. Two absolute numbers here put a
        -- 0.03/0.03/0.04 well inside the smoked pane's own 0.03/0.03/0.04, so
        -- the inset stopped being an inset and a one-pixel border was holding
        -- the box together.
        local well, hair = T.DetailWell()
        check("the figure box has a well and a hairline", well and hair)
        if well and hair then
            local w, h = well._colorTexture, hair._colorTexture
            local ew = { AltStable.SkinWellColor() }
            local eh = { AltStable.SkinWellEdgeColor() }
            -- ALL FOUR channels. Comparing red and alpha catches a swap but
            -- not a scramble, and green and blue reaching the wrong texture is
            -- exactly the mix-up worth catching here.
            local function same(got, want)
                if not got then return false end
                for i = 1, 4 do if got[i] ~= want[i] then return false end end
                return true
            end
            check("  the well is the skin's", same(w, ew),
                  w and table.concat(w, ",") or "nil")
            check("  and so is the hairline", same(h, eh),
                  h and table.concat(h, ",") or "nil")
        end

        local own = 0
        for _, region in ipairs(T.DetailRegions()) do
            -- A FULL-FRAME fill. The figure box paints two of its own, and
            -- those are a box inside the pane rather than a second pane.
            if region._colorTexture and region._allPoints then own = own + 1 end
        end
        eq("  and the drill-down paints no background of its own", own, 0)

        d:SetWidth(100); d:SetHeight(20)
    end

    -- The quality palette is SHARED with the grid, not a third copy of it. The
    -- copy that was here was missing Heirloom (7) entirely, so an heirloom drew
    -- a Common white border in this pane and cyan in the grid beside it, for the
    -- same item. Asserted through the pane's own rendering, and against the
    -- shared table, so a private copy reappearing fails rather than drifting.
    do
        WoW.items[7001] = { name = "An Heirloom", quality = 7, ilvl = 1, icon = 7 }
        AltStableDB.heir = { guid = "heir", name = "Heir Loom", class = "MAGE",
            realm = "R", level = 60, race = "Human", raceName = "Human", ilvl = 1,
            money = 100, stat_int = 200, lastUpdate = time() - 60,
            gearid_chest = 7001, gear_chest = 1, gearq_chest = 7 }
        T.Refresh()
        T.DrillDown("heir")
        T.TabClick("Char")
        local want = { AltStable.QualityRGB(7) }
        -- `_colorTexture` is the stub's bookkeeping for SetColorTexture, not a
        -- client method: there is no GetColorTexture, and GetVertexColor returns
        -- the vertex tint, which is a different thing SetColorTexture never sets.
        local got = T.DetailSlotFrame("chest").border._colorTexture or {}
        check("an heirloom slot draws in the heirloom colour",
              got[1] == want[1] and got[2] == want[2] and got[3] == want[3],
              ("%s,%s,%s vs %s,%s,%s"):format(tostring(got[1]), tostring(got[2]),
                  tostring(got[3]), tostring(want[1]), tostring(want[2]), tostring(want[3])))
        -- And heirloom is not just "whatever Common is": a palette that fell
        -- back to Common for the missing entry would satisfy the line above if
        -- both were read through the same fallback.
        local common = { AltStable.QualityRGB(1) }
        check("  which is not the Common colour",
              want[1] ~= common[1] or want[2] ~= common[2] or want[3] ~= common[3])
        AltStableDB.heir = nil
        T.Refresh()
        T.DrillDown("geared")
    end

    do
        T.TabClick("Char")
        local slot = T.DetailSlotFrame("chest")
        check("a slot has an icon", slot and slot.icon ~= nil)
        check("  and the quality border sits BEHIND it",
              slot and slot.border:GetDrawLayer() == "BACKGROUND",
              tostring(slot and slot.border:GetDrawLayer()))
        check("  with the icon above", slot and slot.icon:GetDrawLayer() == "ARTWORK",
              tostring(slot and slot.icon:GetDrawLayer()))
    end

    -- And the one the clean bill must NOT be given to.
    -- The class-plate icon's PATH.
    --
    -- Lua 5.1 silently collapses an unknown escape, so "Interface\Icons\X"
    -- becomes "InterfaceIconsX" and the texture never resolves - no error, no
    -- warning, just a blank icon. It happened here, in the same function whose
    -- comment warns about a blank class icon. Asserted on the resulting STRING
    -- rather than on the source, because that is where the difference shows.
    T.DrillDown("naked")
    do
        local tex = T.DetailClassIcon()
        check("the class icon path survived its escapes",
              (tex or ""):find("Icons", 1, true) ~= nil
              and (tex or ""):find(string.char(92), 1, true) ~= nil,
              tostring(tex))
    end
    T.TabClick("Audit")
    local naked = table.concat(T.DetailAudit(), " | ")
    check("a character wearing nothing is not told it is fully enchanted",
          naked:find("Every enchantable slot", 1, true) == nil, naked)
    check("  it is told there is nothing to check",
          naked:find("Nothing equipped", 1, true) ~= nil, naked)

    ----------------------------------------------------------
    -- The tabs stay inside the panel
    ----------------------------------------------------------
    -- The Roster inherits whatever width the previous section left behind, so a
    -- narrow frame is reachable. Nothing sets SetClipsChildren, so a control
    -- laid out past the right edge draws over the game world - and the tabs
    -- are the first thing out there a player can click.
    do
        -- Width set on the frame the code actually MEASURES. The stub does not
        -- compute layout, so a width on the parent does not reach the detail -
        -- and asserting against the parent's would be asserting against a
        -- number the code never reads.
        T.DrillDown("messy")
        local d = T.DetailFrame()
        local WIDE, NARROW = 1400, 589
        for _, w in ipairs({ WIDE, NARROW, 320 }) do
            -- SetWidth, not an overridden getter. Assigning the getter and
            -- then clearing it removes the stub's numeric default and hands
            -- back the chaining one, which returns the FRAME - and the next
            -- render does arithmetic on a table.
            d:SetWidth(w)
            T.Refresh()
            for _, b in ipairs(T.DetailTabs()) do
                local _, _, _, bx = b:GetPoint(1)
                check(("a tab stays inside a %dpx panel"):format(w),
                      (bx or 0) >= 0 and (bx or 0) + b:GetWidth() <= w,
                      ("tab at %s wide %s vs panel %d"):format(
                          tostring(bx), tostring(b:GetWidth()), w))
            end

            -- The COLUMN's far edge, not just where it starts. A column that
            -- begins inside the panel and then runs 250px past the right edge
            -- is the same bug, and the tabs do not catch it: they sit at the
            -- column's left, 74px apart.
            local col = T.DetailColumn()
            check(("the whole column fits a %dpx panel"):format(w),
                  (col.right or 0) <= w,
                  ("column %s..%s in %d"):format(tostring(col.x), tostring(col.right), w))
        end

        -- On a frame with room for both, nothing is given up: full width, at
        -- the right edge. Without this, "clamped" is satisfied by a column
        -- that is always narrow, and the clamp above would pass if the whole
        -- calculation were replaced by a constant.
        d:SetWidth(1400)
        T.Refresh()
        local wide = T.DetailColumn()
        eq("on a wide frame the column keeps its full width",
           (wide.right or 0) - (wide.x or 0), 250)
        -- NOT at the right edge. It used to be, and on a wide panel that pulled
        -- the stats away from the paper doll they describe - five hundred pixels
        -- of nothing between them, with the numbers against the window frame.
        -- They are one composition and are centred as one.
        do
            local box = T.DetailFigureBox()
            local gap = (wide.x or 0) - ((box.left or 0) + (box.width or 0))
            check("  a fixed gap past the paper doll, not pinned to the edge",
                  gap > 0 and gap < 120, tostring(gap))
            -- Centred as a group: the space left of the doll and the space
            -- right of the column match.
            --
            -- Measured from the SLOTS, not from the stage. The slots overhang
            -- the box on both sides, so the box's left edge is not the
            -- composition's left edge - comparing it against the column's right
            -- edge compares unlike things and reports an asymmetry that is not
            -- there, or hides one that is.
            local leftRoom  = select(4, T.DetailSlotFrame("head"):GetPoint(1)) or 0
            local rightRoom = 1400 - (wide.right or 0)
            -- Tight, because the symmetry is exact up to one floor(): a loose
            -- tolerance here passed a version that centred the FIGURE rather
            -- than the group, which leans the whole composition left by the
            -- slot overhang - about forty pixels, and invisible under a sixty
            -- pixel allowance.
            check("  with the pair centred in the panel",
                  math.abs(leftRoom - rightRoom) <= 4,
                  ("left %s vs right %s"):format(tostring(leftRoom), tostring(rightRoom)))
            -- And the ART moved with the box. The cutout and the class plate are
            -- placed by their OWN SetPoint calls, so either can be left behind
            -- at the old fixed margin while the box centres - a character
            -- standing outside its own frame.
            --
            -- Both are checked, with a cutout put in place for the first: the
            -- fixtures here have no portraits, so without one the plate is the
            -- only path this ever exercises and the cutout's placement is
            -- untested. A mutation proved it - moving the figure's anchor back
            -- to the fixed margin changed nothing the suite could see.
            check("  and the class plate is centred in its box",
                  box.art and math.abs(box.art - (box.centre or 0)) <= 1,
                  ("plate at %s, box centre %s"):format(
                      tostring(box.art), tostring(box.centre)))

            -- "messy", not "geared": an earlier block replaced AltStableDB
            -- wholesale, so `geared` is not in it here and DrillDown correctly
            -- refuses an unknown guid - which left this drilling into nothing
            -- and asserting against the previous render. The manifest key is
            -- the character's slug, so it has to match whoever is actually
            -- there.
            local savedManifest = AltStableCutoutManifest
            AltStableCutoutManifest = { ["messy-one"] = {
                file = "Interface\AddOns\AltStable\Media\Cutouts\messy-one.tga",
                w = 144, h = 512, texw = 256, texh = 512 } }
            T.DrillDown("messy")
            check("  the cutout path is the one being exercised",
                  T.CutoutFor(AltStableDB.messy) ~= nil)
            local withArt = T.DetailFigureBox()
            check("  and a real cutout is centred in its box too",
                  withArt.art and math.abs(withArt.art - (withArt.centre or 0)) <= 1,
                  ("cutout at %s, box centre %s"):format(
                      tostring(withArt.art), tostring(withArt.centre)))
            AltStableCutoutManifest = savedManifest
            T.DrillDown("messy")
        end
        -- While a narrow one gives up width rather than position, which is the
        -- half of the trade the old double-clamp got backwards.
        d:SetWidth(589)
        T.Refresh()
        local tight = T.DetailColumn()
        check("a narrow frame narrows the column instead of moving it out",
              (tight.right or 0) - (tight.x or 0) < 250,
              tostring((tight.right or 0) - (tight.x or 0)))

        -- And the same question about HEIGHT, which had the same bug for the
        -- same reason: the figure used to be floored at six rows of slots, so on
        -- a short panel the floor won, the figure ran past the bottom edge and
        -- the weapons row went with it - seven item buttons drawn over the game
        -- world, taking the mouse there. Nothing sets SetClipsChildren.
        -- EVERY equipment button, not only the weapons row. The first version of
        -- this checked weapons and trinkets, which hang off the figure's bottom
        -- and so were the only ones the figure-height fix touched. The SIDE
        -- columns are six rows at a fixed stride from a fixed top, so their
        -- extent did not depend on the panel height at all - and raising the
        -- stride from 40 to 48 put the sixth button 332px down whatever the panel
        -- did.
        --
        -- 310 is in the list because it is the real floor: SheetUI's sidebar
        -- floors the window at 364, BuildPanel takes 30 above and 24 below, and
        -- ResizeFrameToContent deliberately does not resize for plugins.
        d:SetWidth(1400)
        local ALL_SLOTS = { "head", "neck", "shoulder", "back", "chest", "wrist",
                            "hands", "waist", "legs", "feet", "ring1", "ring2",
                            "trinket1", "trinket2", "mainhand", "offhand", "ranged" }
        for _, h in ipairs({ 800, 420, 310, 260 }) do
            d:SetHeight(h)
            T.Refresh()
            for _, key in ipairs(ALL_SLOTS) do
                local b = T.DetailSlotFrame(key)
                local _, _, _, _, by = b:GetPoint(1)
                -- Anchored TOPLEFT from the panel's TOPLEFT, so the offset is
                -- negative downwards and the button's own height hangs below it.
                local bottom = (by or 0) - b:GetHeight()
                check(("the %s stays inside a %dpx-tall panel"):format(key, h),
                      bottom >= -h,
                      ("%s bottom=%s panel=%d"):format(key, tostring(bottom), h))
                -- And the ITEM LEVEL label, which is anchored TOP to the
                -- button's BOTTOM and so reaches further down than the button
                -- does. It is the part that landed on the footer.
                local lh = b.ilvl:GetHeight() or 0
                check(("  and its item level label does too, at %dpx"):format(h),
                      bottom - lh >= -h,
                      ("%s label bottom=%s panel=%d"):format(
                          key, tostring(bottom - lh), h))
            end
            -- The figure still has to BE there, or "inside the panel" is
            -- satisfied by a figure of zero height.
            check(("  and the figure still has a height at %dpx"):format(h),
                  (T.DetailFigureBox().height or 0) >= 24,
                  tostring(T.DetailFigureBox().height))
            -- And the icons have to stay legible, or "it fits" is satisfied by
            -- shrinking them to nothing.
            check(("  with slot icons still legible at %dpx"):format(h),
                  (T.DetailSlotFrame("head"):GetWidth() or 0) >= T.SLOT_MIN,
                  tostring(T.DetailSlotFrame("head"):GetWidth()))
            -- Nor may they overlap: a stride smaller than the icon stacks them.
            local a = select(5, T.DetailSlotFrame("head"):GetPoint(1))
            local bY = select(5, T.DetailSlotFrame("neck"):GetPoint(1))
            local sz = T.DetailSlotFrame("head"):GetHeight()
            check(("  and not overlapping each other at %dpx"):format(h),
                  (a - bY) >= sz,
                  ("stride %s vs size %s"):format(tostring(a - bY), tostring(sz)))

            -- The WEAPONS row scales with them, horizontally. It is laid out
            -- from its own centred start at the same stride, so a row still
            -- stepping by the full 48 while the buttons are 21 wide is spread
            -- out of line with the figure it is supposed to sit under - and the
            -- centring calculation and the placement have to use the SAME
            -- stride or the row drifts right.
            local mhX = select(4, T.DetailSlotFrame("mainhand"):GetPoint(1))
            local ohX = select(4, T.DetailSlotFrame("offhand"):GetPoint(1))
            -- Compared with a tolerance, not with ==: the stride is a division
            -- and two float paths to the same number are not bit-identical.
            check(("the weapons row steps by the same stride at %dpx"):format(h),
                  math.abs((ohX - mhX) - (a - bY)) < 0.01,
                  ("bottom %s vs side %s"):format(tostring(ohX - mhX), tostring(a - bY)))
            -- And stays centred under the figure: five bottom slots, so the
            -- middle one is the centre.
            -- Read from the stage, not computed from a margin. The whole
            -- composition is centred on a wide panel now, so a hardcoded
            -- `60 + W/2` asserts against where the figure used to be.
            local midX = select(4, T.DetailSlotFrame("mainhand"):GetPoint(1))
            local figCx = T.DetailFigureBox().centre
            check(("  centred under the figure at %dpx"):format(h),
                  math.abs((midX + sz / 2) - figCx) <= 1,
                  ("mainhand centre %s vs figure centre %s"):format(
                      tostring(midX + sz / 2), tostring(figCx)))
        end
        d:SetHeight(800)

        -- The STATS column has to stay inside the panel too, which is the
        -- vertical half of the clamp the tabs got. Seventeen rows and four
        -- headers is about 421px from the column's top, the render loop only ever
        -- decremented y, and nothing here sets SetClipsChildren - so a
        -- fully-statted character on a short frame drew its last rows over the
        -- game world. Sixteen rows already did this; the Bonus Hit row made it
        -- one worse, which is how it surfaced.
        do
            AltStableDB.loaded = { guid = "loaded", name = "Fully Loaded",
                class = "WARRIOR", realm = "R", level = 59, race = "Human",
                raceName = "Human", ilvl = 61.5, money = 573920,
                lastUpdate = time() - 3600, restPercent = 42, xpPercent = 88,
                stat_hp = 3210, stat_mana = 4870, stat_armor = 812,
                stat_str = 42, stat_agi = 53, stat_sta = 290,
                stat_int = 493, stat_spi = 446,
                stat_ap = 32, stat_sp = 728, stat_defense = 300,
                stat_crit = 12.5, stat_hitpct = 3 }
            T.Refresh()

            -- 321, 333 and 345 are not decoration. They are the heights where
            -- the last row that fits is the last row of a SECTION, so the loop
            -- takes a section gap off y before the notice is placed - and the
            -- notice lands below the floor the rows honoured. A sweep of every
            -- height from 180 to 800 with the notice's own clamp removed puts it
            -- outside the panel at exactly these three and nowhere else, so
            -- without them the clamp is a line no test can justify.
            for _, h in ipairs({ 800, 500, 345, 333, 321, 310, 240 }) do
                d:SetHeight(h)
                T.DrillDown("loaded")
                local rows = T.DetailStatRowYs()
                check(("the stats column draws something at %dpx"):format(h),
                      #rows > 0, tostring(#rows))
                for i, r in ipairs(rows) do
                    check(("every drawn stat row is inside a %dpx panel"):format(h),
                          (r[1] or 0) - (r.h or 0) >= -h,
                          ("row bottom %s vs panel %d"):format(
                              tostring((r[1] or 0) - (r.h or 0)), h))
                    -- And no row sits on top of the one above it. This is the
                    -- invariant the stride floor exists for: compressing the
                    -- column is only legitimate down to the height of the text
                    -- itself, and past that the rows stop being separate rows.
                    -- It is also the reason the clamp can compare against the
                    -- stride alone - the stride is provably at least as tall as
                    -- what it steps over.
                    if i > 1 then
                        local prev = rows[i - 1]
                        check(("stat rows do not overlap at %dpx"):format(h),
                              (prev[1] or 0) - (r[1] or 0) >= (r.h or 0),
                              ("stride %s vs text %s"):format(
                                  tostring((prev[1] or 0) - (r[1] or 0)),
                                  tostring(r.h)))
                    end
                end
            end

            -- At full height nothing is dropped, so the clamp is not just
            -- "hide most of it".
            d:SetHeight(800)
            T.DrillDown("loaded")
            eq("a tall panel hides no stat rows", T.DetailStatsMore(), nil)
            local tall = #T.DetailStatRowYs()
            check("  and draws every section", tall >= 21, tostring(tall))

            -- Snug rather than short: the rows COMPRESS and everything survives.
            -- Without this, "nothing draws outside" is satisfied by hiding rows
            -- the moment the panel is anything less than generous.
            --
            -- 380 is chosen against the stub's font metrics, where a row of text
            -- is 12px inside a 15px stride: this column wants 363px at full
            -- spacing and can be squeezed to 268 before a stride would be
            -- shorter than its own text, so a 380px panel (318px of room) sits
            -- inside the band where compression is both necessary and sufficient.
            -- The invariant under test is the behaviour, not the pixel.
            d:SetHeight(380)
            T.DrillDown("loaded")
            eq("a snug panel compresses instead of dropping rows",
               T.DetailStatsMore(), nil)
            eq("  keeping every row", #T.DetailStatRowYs(), tall)

            -- The reserve for the notice is taken only when truncation is
            -- POSSIBLE, not always. 425 is the height where the column fits
            -- exactly: an unconditional reserve would take 14px it does not
            -- need, drop the last row and then announce the drop it caused. The
            -- same sweep says 425-428 is the whole band where that shows, so
            -- this is the assertion that keeps the condition on the reserve.
            d:SetHeight(425)
            T.DrillDown("loaded")
            eq("a column that fits exactly reserves nothing and drops nothing",
               T.DetailStatsMore(), nil)
            eq("  keeping every row at the boundary", #T.DetailStatRowYs(), tall)

            -- And when it genuinely cannot fit, it SAYS how many went. A row
            -- quietly not drawn is a stat the player has no way to know exists.
            d:SetHeight(200)
            T.DrillDown("loaded")
            local more = T.DetailStatsMore()
            check("a panel too short to compress says how many rows it dropped",
                  more ~= nil and more:find("more", 1, true) ~= nil, tostring(more))
            check("  and drew fewer than it does when there is room",
                  #T.DetailStatRowYs() < tall,
                  ("%s vs %s"):format(tostring(#T.DetailStatRowYs()), tostring(tall)))

            -- The EMPTY-TO-VISIBLE transition, which is the lifecycle the
            -- reservation has to survive.
            --
            -- The notice is created without text and cleared back to "" by every
            -- render that hides nothing, and an auto-sized FontString with no
            -- text has no height. So a tall panel leaves it empty, and the next
            -- short render measures zero, reserves nothing, and the notice
            -- overflows by its own full height - the original bug living through
            -- its own fix. Driven from a TALL panel each time, deliberately: a
            -- test that only ever shrinks finds the notice already populated by
            -- the previous case and never measures the empty one.
            for _, h in ipairs({ 240, 310, 321 }) do
                d:SetHeight(900)
                T.DrillDown("loaded")
                eq(("the notice starts empty before the %dpx case"):format(h),
                   T.DetailStatsMore(), nil)
                d:SetHeight(h)
                T.DrillDown("loaded")
                check(("the notice appears on the first short render at %dpx"):format(h),
                      T.DetailStatsMore() ~= nil)
                for _, r in ipairs(T.DetailStatRowYs()) do
                    check(("  and everything is inside the panel at %dpx"):format(h),
                          (r[1] or 0) - (r.h or 0) >= -h,
                          ("bottom %s vs panel %d"):format(
                              tostring((r[1] or 0) - (r.h or 0)), h))
                end
            end

            -- A font TALLER than the row stride. No font the stub models is
            -- 22px, and STAT_ROW_H is 15 - so without forcing it, the floor that
            -- keeps the stride at least as tall as the text is unreachable code,
            -- and the whole clamp rests on an assumption it never checks.
            d:SetHeight(800)
            T.DrillDown("loaded")
            local label = T.DetailStatFirstLabel()
            check("the column has a label to measure from", label ~= nil)
            if label then
                label:SetHeight(22)
                T.DrillDown("loaded")
                local big = T.DetailStatRowYs()
                check("a font taller than the stride still draws rows", #big > 2,
                      tostring(#big))
                local stride = nil
                for i = 2, #big do
                    local gap = (big[i - 1][1] or 0) - (big[i][1] or 0)
                    if not stride or gap < stride then stride = gap end
                end
                check("  and the stride grows to match it, rather than the text overlapping",
                      (stride or 0) >= 22, tostring(stride))
                label:SetHeight(12)
            end

            AltStableDB.loaded = nil
            d:SetHeight(800)
            T.Refresh()
            T.DrillDown("geared")
        end

        -- The scale itself, at the boundaries.
        do
            local size, step = T.SlotScale(6, 10000)
            eq("a panel with room keeps the full slot size", size, T.SLOT_SIZE)
            eq("  and the full stride", step, T.SLOT_STEP)
            -- A panel so short the legibility floor and the fitting rule
            -- disagree. The floor wins - an icon below SLOT_MIN is not a slot,
            -- it is a smudge - and the STRIDE has to be lifted with it, or the
            -- rows stack on top of each other, which is the one thing worse
            -- than overflowing.
            local tiny, tinyStep = T.SlotScale(6, 12)
            check("an impossible panel still gives a legible icon", tiny >= T.SLOT_MIN,
                  tostring(tiny))
            check("  and lifts the stride with it rather than stacking rows",
                  tinyStep >= tiny, ("%s vs %s"):format(tostring(tinyStep), tostring(tiny)))
            local mid, midStep = T.SlotScale(6, 180)
            check("a short panel shrinks it", mid < T.SLOT_SIZE and mid >= T.SLOT_MIN,
                  tostring(mid))
            check("  and the stride never falls below the icon", midStep >= mid,
                  ("%s vs %s"):format(tostring(midStep), tostring(mid)))
        end

        d:SetWidth(100)
        T.Back()
    end
end

------------------------------------------------------------
-- The tab's background is the material (#97 phase 3)
------------------------------------------------------------
-- The helper has its own tests in test_glass. What those cannot say is whether
-- THIS tab asks for it - and it did not: Raids and Warband picked the pane up
-- during the corner work, because their panels reach the window edge and had to
-- become clipped textures, while the Roster kept a hand-rolled opaque
-- 0.05/0.05/0.06/1. Two tabs showed the material and two were solid rectangles
-- sitting inside it, same window, same skin.
do
    local pane = AltStable.SkinPaneColor()
    local bd = T.BackdropTex and T.BackdropTex()
    check("the grid has a backdrop to paint", bd ~= nil)
    if bd then
        local c = bd._colorTexture
        check("the grid backdrop is the material under glass",
              c and c[1] == pane[1] and c[4] == pane[4],
              c and ("%s,%s,%s a=%s"):format(c[1], c[2], c[3], c[4]) or "nil")
    end

    -- The drill-down has no background of its own to check; the assertion that
    -- it must not grow one lives with the figure box above, where the sublevels
    -- it would have fought with are.

    -- THE SCENE'S ART DOES NOT COME UP THROUGH THE DRILL-DOWN.
    --
    -- The camp art lives on this same backdrop, and the drill-down's own
    -- background is the material now - translucent. Left there, Mount Hyjal
    -- came up through the stats, the slot icons and the figure box: the pane
    -- that reads as glass over the world reads as a mess over a landscape.
    if bd then
        local savedView = AltStableConfig.rosterView
        AltStableConfig.rosterView = "scene"
        pcall(AltStable.RosterPlugin.Refresh)
        check("the scene view puts art on the backdrop", bd._texture ~= nil,
              tostring(bd._texture))
        -- Whatever character the database holds by now; the fixtures earlier
        -- in this file have been replaced several times over.
        local anyGuid = next(AltStableDB)
        check("  there is a character to drill into", T.DrillDown(anyGuid) == true,
              tostring(anyGuid))
        check("  and drilling in from it clears the art", bd._texture == nil,
              tostring(bd._texture))
        local c = bd._colorTexture
        check("  back to the tab's own background",
              c and c[1] == pane[1] and c[4] == pane[4],
              c and ("a=%s"):format(c[4]) or "nil")
        T.Back()
        AltStableConfig.rosterView = savedView
        pcall(AltStable.RosterPlugin.Refresh)
    end

    -- And it is re-asked on every refresh, not painted once at build. The scene
    -- view puts camp ART on this same texture, so coming back from it has to
    -- repaint - and a repaint that hard-codes a colour is a second place for
    -- the skin to disagree with itself.
    if bd then
        -- PINNED to the grid. The scene branch returns before PaintBackdrop, so
        -- an ambient "scene" left by another test would have this read back the
        -- colour the previous refresh happened to leave - passing for a reason
        -- that has nothing to do with the skin.
        local heldView = AltStableConfig.rosterView
        AltStableConfig.rosterView = "grid"
        AltStableConfig.skin = "flat"
        AltStable._ResetSkinCache()
        pcall(AltStable.RosterPlugin.Refresh)
        local c = bd._colorTexture
        check("  and a refresh re-asks the skin rather than repeating a literal",
              c and c[1] == AltStable.C.BG_MAIN[1] and c[4] == AltStable.C.BG_MAIN[4],
              c and ("%s a=%s"):format(c[1], c[4]) or "nil")
        AltStableConfig.skin = nil
        AltStableConfig.rosterView = heldView
        AltStable._ResetSkinCache()
        pcall(AltStable.RosterPlugin.Refresh)
    end
end

------------------------------------------------------------
-- The hint names a command the player actually has
------------------------------------------------------------
-- `/asrender` is registered in AltStableProbe, a development tool that
-- `.pkgmeta` excludes from the package. So for everyone who installed this from
-- CurseForge - which is everyone who did not clone the repo - the scene view
-- was telling them to type a command the client answers with "Type /help".
do
    local held = _G.AltStableProbe
    -- The GRID's hint. The scene view has its own line about favourites.
    AltStableConfig.rosterView = "grid"

    _G.AltStableProbe = nil
    pcall(AltStable.RosterPlugin.Refresh)
    local without = T.HintText() or ""
    check("with no capture tool the hint does not name the command",
          not without:find("asrender", 1, true), without)
    check("  and says where portraits come from instead",
          without:find("capture tool", 1, true) ~= nil, without)

    _G.AltStableProbe = { CapturePortrait = function() end }
    pcall(AltStable.RosterPlugin.Refresh)
    local with = T.HintText() or ""
    check("with the tool installed it names the command",
          with:find("asrender", 1, true) ~= nil, with)

    -- A probe that is THERE but cannot capture is the same to the player as no
    -- probe at all: an older build, or the global existing for another reason.
    -- Testing the table rather than the function sends them to a command that
    -- answers nothing.
    _G.AltStableProbe = {}
    pcall(AltStable.RosterPlugin.Refresh)
    local stale = T.HintText() or ""
    check("a probe that cannot capture does not get the command either",
          not stale:find("asrender", 1, true), stale)

    -- Both still say how many are missing, which is the hint's actual job.
    check("both forms still count the portraits",
          without:find("of", 1, true) and with:find("of", 1, true))

    _G.AltStableProbe = held
    AltStableConfig.rosterView = nil
    pcall(AltStable.RosterPlugin.Refresh)
end

------------------------------------------------------------
-- The scene with nobody in it says why (#89)
------------------------------------------------------------
-- The scene seats only characters with a portrait, and portraits are not made
-- by anything in the download. So for everyone who installed from CurseForge
-- the scene was an empty campfire captioned "showing 0 of 12 - favourite the
-- ones you want here": advice that cannot work, since a favourite with no
-- picture is not seated either.
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB = {}
    for i = 1, 3 do
        local guid = ("empty-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Empty %d"):format(i),
                              level = i * 10, ilvl = i, class = "MAGE" }
    end
    AltStableCutoutManifest = nil

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)

    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.rosterView = "scene"
    T.Refresh()
    local empty = T.HintText() or ""
    check("a scene with no portraits says there are none",
          empty:find("No portraits yet", 1, true) ~= nil, empty)
    check("  and does not offer favouriting as the fix",
          empty:find("favourite", 1, true) == nil, empty)
    check("  and points at the grid, which shows them as cards",
          empty:find("grid", 1, true) ~= nil, empty)
    check("  and without the capture tool does not name its command",
          empty:find("asrender", 1, true) == nil, empty)

    -- With the probe loaded the scene gives the same instruction the grid
    -- does. They used to disagree: the grid named /asrender and the scene sent
    -- the one person who CAN capture to the project page.
    local heldProbe = _G.AltStableProbe
    _G.AltStableProbe = { CapturePortrait = function() end }
    T.Refresh()
    local withTool = T.HintText() or ""
    check("with the capture tool the empty scene names its command",
          withTool:find("asrender", 1, true) ~= nil, withTool)
    AltStableConfig.rosterView = "grid"
    T.Refresh()
    local gridWithTool = T.HintText() or ""
    check("  as the grid does",
          gridWithTool:find("asrender", 1, true) ~= nil, gridWithTool)
    AltStableConfig.rosterView = "scene"
    _G.AltStableProbe = heldProbe

    -- One portrait, and the ordinary count comes back.
    AltStableCutoutManifest = { ["empty-2"] =
        { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 } }
    T.Refresh()
    local one = T.HintText() or ""
    check("with one portrait the scene counts again",
          one:find("showing 1 of 3", 1, true) ~= nil, one)

    -- A panel with no size yet seats nobody - the layout has nowhere to put
    -- them - and that is not the same thing as having no portraits.
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 0 end
    p.GetHeight = function() return 0 end
    T.Refresh()
    local early = T.HintText() or ""
    check("an unsized scene does not claim there are no portraits",
          early:find("No portraits yet", 1, true) == nil, early)
    p.GetWidth, p.GetHeight = heldW, heldH

    AltStableConfig.rosterView = nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
    pcall(AltStable.RosterPlugin.Refresh)
end

print(("test_roster: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
