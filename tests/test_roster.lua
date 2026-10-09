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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")   -- our prompts, before Core (TOC order)
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
dofile("Plugins/Roster/CampList.lua")      -- the camp list, after it, as the .toc loads them (#152)
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
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
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

    -- Since #152 the scene draws a CAMP, and favourites order the grid only:
    -- the ranking the first camp is seeded from ignores them.
    AltStableConfig.favouriteCharacters = nil
    local byLevel = T.SceneCast(T.AllCharacters(), cut, 2)
    eq("the seed ranking goes by level", byLevel[1].name, "Alt 6")
    AltStable.SetCharacterFavourite("fav-1", true)
    local cast = T.SceneCast(T.AllCharacters(), cut, 2)
    eq("a favourite no longer takes a seat by being one", cast[1].name, "Alt 6")
    eq("  the seats go by level", cast[2].name, "Alt 5")
    eq("  while the grid still lists favourites first", T.AllCharacters()[1].name, "Alt 1")
    AltStableConfig.favouriteCharacters = nil

    -- The first camp: the top characters WITH a portrait, then the top ones
    -- without, up to a camp's size.
    local function artFor(names) return function(c) return names[c.name] and art or nil end end
    local seed = T.SeedMembers(T.AllCharacters(), artFor({ ["Alt 2"] = true, ["Alt 4"] = true }))
    eq("a camp holds five", #seed, AltStable.CAMP_SIZE)
    eq("  portraits first, by level", seed[1], "fav-4")
    eq("  then the next portrait", seed[2], "fav-2")
    eq("  then the highest without one", seed[3], "fav-6")

    AltStableDB = saved
    AltStableConfig.favouriteCharacters = nil
end

------------------------------------------------------------
-- Camps (#152): the scene draws one, and says who in it is not at the fire
------------------------------------------------------------
-- Driven through the real panel: what the player SEES is the camp's name in
-- the switcher and the hint, so those are what is asserted.

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

    -- Anchored beside the sidebar's edge through the sheet's helper (#150), so
    -- it follows a collapse. Declining here keeps the fixed-offset fallback.
    local besideSidebar
    AltStable.AnchorBesideSidebar = function(region) besideSidebar = region; return false end
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    check("the panel anchors beside the sidebar's edge (#150)", besideSidebar ~= nil)
    check("  and re-lays out when the window changes size", type(registered.OnResize) == "function")
    AltStable.AnchorBesideSidebar = nil

    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView = "scene"
    local function hint() return T.HintShown() and (T.HintText() or "") or "" end
    local function seated()
        local n = 0
        for _, card in ipairs(T.Cards()) do if card:IsShown() then n = n + 1 end end
        return n
    end

    -- The first camp is set up the first time the scene is shown.
    check("no camp before the scene is first shown", not AltStable.CampsSetUp())
    T.Refresh()
    local camps = AltStable.GetCamps()
    eq("the first time, one camp is made", #camps, 1)
    eq("  named Camp 1", camps[1].name, "Camp 1")
    eq("  holding the top four with a portrait", table.concat(camps[1].members, ","),
       "wire-6,wire-5,wire-4,wire-3")
    eq("the switcher names the camp shown", T.CampLabel(), "Camp 1")
    check("  and shows in the scene view", T.CampBar():IsShown())
    eq("all four stand at the fire", seated(), 4)
    eq("  so the hint has nothing to explain", hint(), "")
    -- Made for the player, so kept "the top characters" as they arrive (a
    -- fresh install knows only the one logged in)...
    local function firstMembers() return table.concat(AltStable.GetCamps()[1].members, ",") end
    check("the first camp is marked as made for the player", AltStable.CampsAutoSeeded())
    AltStableDB["wire-7"] = { guid = "wire-7", name = "Wire 7", level = 99, class = "MAGE" }
    AltStableCutoutManifest["wire-7"] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    T.Refresh()
    eq("  it takes in a new top character", firstMembers(), "wire-7,wire-6,wire-5,wire-4")
    AltStableDB["wire-7"], AltStableCutoutManifest["wire-7"] = nil, nil
    T.Refresh()
    eq("  and lets one whose record went go", firstMembers(), "wire-6,wire-5,wire-4,wire-3")
    -- ...until the player changes a camp. Then it is only what they made it.
    local id1 = camps[1].id
    AltStable.RemoveFromCamp("wire-3")
    check("the player's first change ends that", not AltStable.CampsAutoSeeded())
    AltStableDB["wire-7"] = { guid = "wire-7", name = "Wire 7", level = 99, class = "MAGE" }
    AltStableCutoutManifest["wire-7"] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    T.Refresh()
    eq("  no one joins by themselves after it", firstMembers(), "wire-6,wire-5,wire-4")
    AltStableDB["wire-7"], AltStableCutoutManifest["wire-7"] = nil, nil
    AltStable.AddToCamp("wire-3", id1)

    -- A seat whose record is gone (/alts cleanup deletes records without
    -- asking the camps) is freed, so the camp is not full of no one.
    local heldRecord = AltStableDB["wire-3"]
    AltStableDB["wire-3"] = nil
    T.Refresh()
    eq("a seat whose record is gone is freed", firstMembers(), "wire-6,wire-5,wire-4")
    AltStableDB["wire-3"] = heldRecord
    AltStable.AddToCamp("wire-3", id1)

    -- A camp from when camps held five keeps its first four.
    AltStableConfig.rosterCamps[1].members[5] = "wire-2"
    T.Refresh()
    eq("a camp holding five is trimmed to its first four", firstMembers(), "wire-6,wire-5,wire-4,wire-3")

    -- Who is left out, and why.
    check("a full camp refuses a fifth", not AltStable.AddToCamp("wire-1", id1))
    AltStable.RemoveFromCamp("wire-3")
    check("  with room, it takes one", AltStable.AddToCamp("wire-1", id1))
    T.Refresh()
    eq("a member with no portrait is left out", seated(), 3)
    check("  and the hint says so", hint():find("showing 3 of 4 in Camp 1 - 1 without a portrait", 1, true) ~= nil, hint())
    AltStable.SetCharacterHidden("wire-5", true)
    T.Refresh()
    check("a hidden member is left out and counted", hint():find("1 hidden", 1, true) ~= nil, hint())
    AltStable.SetCharacterHidden("wire-5", false)
    AltStable.RemoveFromCamp("wire-1"); AltStable.AddToCamp("wire-3", id1)
    -- Pets take no seat (#170): four stand with them as without.
    AltStableConfig.rosterPets = true
    T.Refresh()
    eq("with pets shown, all four are still seated", seated(), 4)
    eq("  with nothing to explain", hint(), "")
    AltStableConfig.rosterPets = nil

    -- More camps, and the switcher.
    local id2 = AltStable.CreateCamp("Raiders", { "wire-6" })
    eq("making a camp with a member moves it out of its old one",
       table.concat(AltStable.GetCamp(id1).members, ","), "wire-5,wire-4,wire-3")
    AltStable.RosterPlugin.campButtons.next:GetScript("OnClick")()
    eq("the switcher's > shows the next camp", T.CampLabel(), "Raiders")
    eq("  with only its own members", seated(), 1)
    AltStable.RosterPlugin.campButtons.next:GetScript("OnClick")()
    eq("  and wraps round", T.CampLabel(), "Camp 1")
    AltStable.RosterPlugin.campButtons.prev:GetScript("OnClick")()
    eq("< goes back", T.CampLabel(), "Raiders")

    -- Each camp has its own backdrop.
    AltStable.SelectCamp(id1)
    AltStable.SetCampBackdrop(id1, T.SCENE_BACKDROPS[3].id)
    AltStable.SetCampBackdrop(id2, T.SCENE_BACKDROPS[5].id)
    eq("a camp draws its own backdrop", T.CurrentScene().id, T.SCENE_BACKDROPS[3].id)
    AltStable.SelectCamp(id2)
    eq("  and another camp its own", T.CurrentScene().id, T.SCENE_BACKDROPS[5].id)

    -- An empty camp, and none at all.
    local id3 = AltStable.CreateCamp("Empty")
    AltStable.SelectCamp(id3)
    T.Refresh()
    check("an empty camp says how to fill it", hint():find("Empty is empty", 1, true) ~= nil, hint())
    check("  and where: the scene has no one to right-click", hint():find("in the grid", 1, true) ~= nil, hint())

    -- Drilled into a character, the camp switcher goes with the scene's bar.
    AltStable.SelectCamp(id1)
    T.Refresh()
    check("the switcher shows over the scene", T.CampBar():IsShown())
    AltStable.RosterPlugin.DrillDown("wire-6")
    check("  and not over a character's detail", not T.CampBar():IsShown())
    AltStable.RosterPlugin.Back()
    AltStable.SelectCamp(id3)
    for _, c in ipairs(AltStable.GetCamps()) do AltStable.DeleteCamp(c.id) end
    T.Refresh()
    check("with every camp deleted the scene says so", hint():find("No camp", 1, true) ~= nil, hint())
    eq("  and does not make a new one by itself", #AltStable.GetCamps(), 0)
    eq("  so nobody stands at the fire", seated(), 0)

    AltStableConfig.rosterView = nil
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

-- The Roster holds the window it needs, as Warband does: the top bar's three
-- controls side by side, on activation and when the window changes under it.
do
    local asked
    local held = AltStable.EnsureWindowMinSize
    AltStable.EnsureWindowMinSize = function(w, h) asked = { w, h } end
    local main = CreateFrame("Frame")
    T.Activate(main)
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    check("opening the Roster asks for its minimum window", asked ~= nil)
    eq("  wide enough for the camp switcher, backdrop picker and view toggle",
       asked and asked[1], sidebarW + 1 + AltStable.RosterPlugin.MinPanelW())
    check("  which is all three side by side", AltStable.RosterPlugin.MinPanelW() >= 200 + 240 + 64)
    local CL = AltStable.RosterPlugin.CampList
    check("  and the camp list beside a usable scene", AltStable.RosterPlugin.MinPanelW() >= CL.LIST_W + CL.MIN_SCENE_W)
    asked = nil
    registered.OnResize()
    check("and asks again when the window changes under it", asked ~= nil)
    AltStable.EnsureWindowMinSize = held

    -- Its PREFERRED size (#150), asked for on opening, before the floor - so
    -- it opens the same whichever tab came before.
    local calls = {}
    local heldReq, heldMin = AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize
    AltStable.RequestPluginSize = function(w) calls[#calls + 1] = "pref " .. w end
    AltStable.EnsureWindowMinSize = function() calls[#calls + 1] = "floor" end
    T.Activate(main)
    eq("opening the Roster asks for its preferred width, then the floor",
       tostring(calls[1]) .. "," .. tostring(calls[2]),
       "pref " .. AltStable.RosterPlugin.PREFERRED_PANEL_W .. ",floor")
    check("  which is more than the floor", AltStable.RosterPlugin.PREFERRED_PANEL_W > AltStable.RosterPlugin.MinPanelW())
    AltStable.RequestPluginSize, AltStable.EnsureWindowMinSize = heldReq, heldMin
end

-- The camp storage (Config.lua), and the right-click menu's camp entries.
do
    local savedDB = AltStableDB
    AltStableDB = {}
    for i = 1, 7 do
        local guid = ("cm-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Cm %d"):format(i), level = i, class = "MAGE" }
    end
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = {}, nil, nil

    local a = AltStable.CreateCamp(nil, { "cm-1", "cm-2", "cm-3", "cm-1", "cm-4", "cm-5", "cm-6" })
    eq("an unnamed camp gets a number", AltStable.GetCamp(a).name, "Camp 1")
    eq("  duplicates are dropped and it stops at four",
       table.concat(AltStable.GetCamp(a).members, ","), "cm-1,cm-2,cm-3,cm-4")
    local b = AltStable.CreateCamp("B")
    check("ids are distinct", a ~= b)
    -- A deleted camp's id is never handed out again: a menu or drag still
    -- holding it must not land in a newer camp.
    AltStable.DeleteCamp(b)
    local b2 = AltStable.CreateCamp("B")
    check("a deleted camp's id is not reused", b2 ~= b, tostring(b2) .. " vs " .. tostring(b))
    b = b2
    -- A field this build does not know survives its writes.
    AltStableConfig.rosterCamps[1].later = "kept"
    AltStable.RenameCamp(a, "Camp 1")
    eq("a camp field from a later version survives a write", AltStable.GetCamp(a).later, "kept")
    check("a camp is not renamed to nothing", not AltStable.RenameCamp(b, ""))
    check("  but to a name", AltStable.RenameCamp(b, "Bee") and AltStable.GetCamp(b).name == "Bee")

    check("adding to another camp moves", AltStable.AddToCamp("cm-2", b))
    eq("  out of the first", table.concat(AltStable.GetCamp(a).members, ","), "cm-1,cm-3,cm-4")
    local camp, at = AltStable.CampOf("cm-2")
    check("  and CampOf finds it", camp and camp.id == b and at == 1)
    check("a move within a camp reorders it", AltStable.AddToCamp("cm-5", a, 1))
    eq("  to the place asked", table.concat(AltStable.GetCamp(a).members, ","), "cm-5,cm-1,cm-3,cm-4")

    check("camps reorder", AltStable.MoveCamp(b, 1))
    eq("  b first", AltStable.GetCamps()[1].id, b)

    -- Three, so the neighbour is not simply the first: b, a, c - delete a.
    local c3 = AltStable.CreateCamp("C")
    AltStable.SelectCamp(a)
    AltStable.DeleteCamp(a)
    eq("deleting the shown camp shows the one after it", AltStable.SelectedCamp().id, c3)
    -- Restore a for the menu checks below.
    a = AltStable.CreateCamp(nil, { "cm-1", "cm-3", "cm-4", "cm-5" })
    AltStable.DeleteCamp(b); AltStable.DeleteCamp(c3)

    -- The menu (the Roster plugin is loaded in this file).
    local entries = AltStable.CharacterMenuEntries(AltStableDB["cm-1"])
    local ids = {}
    for _, e in ipairs(entries) do ids[#ids + 1] = e.id end
    local list = table.concat(ids, " ")
    check("a camp member's menu offers to remove it", list:find("camp:remove", 1, true) ~= nil, list)
    check("  and a new camp", list:find("camp:new", 1, true) ~= nil, list)
    local outsider = AltStable.CharacterMenuEntries(AltStableDB["cm-7"])
    local addOne
    for _, e in ipairs(outsider) do if e.id == "camp:add:" .. a then addOne = e end end
    check("someone in no camp is offered each camp", addOne ~= nil)
    check("  by name", addOne and addOne.text == "Add to " .. AltStable.GetCamp(a).name, addOne and addOne.text)
    AltStable.AddToCamp("cm-2", a)
    for _, e in ipairs(AltStable.CharacterMenuEntries(AltStableDB["cm-7"])) do
        if e.id == "camp:add:" .. a then addOne = e end
    end
    check("a full camp is offered, disabled", addOne and addOne.disabled == true)
    check("choosing Add to a new camp makes one and shows it",
          AltStable.CharacterMenuInvoke("camp:new", AltStableDB["cm-7"])
          and AltStable.SelectedCamp().members[1] == "cm-7")
    check("Remove takes it out", AltStable.CharacterMenuInvoke("camp:remove", AltStableDB["cm-7"])
          and not AltStable.CampOf("cm-7"))
    check("a forgotten character leaves its camp", (function()
        AltStable.ForgetCharacter("cm-3")
        return not AltStable.CampOf("cm-3")
    end)())

    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil
    AltStableDB = savedDB
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

    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
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

    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
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

    -- Findings only: rank 4 is an enchant that IS there, listed in words (#94).
    local function findings(char)
        char.level = char.level or FLOOR
        local out = {}
        for _, f in ipairs(T.AuditCharacter(char)) do
            if f.rank < 4 then out[#out + 1] = f.slot .. ":" .. f.issue end
        end
        return table.concat(out, " | ")
    end
    -- And the listed ones, separately.
    local function listed(char)
        char.level = char.level or FLOOR
        local out = {}
        for _, f in ipairs(T.AuditCharacter(char)) do
            if f.rank == 4 then out[#out + 1] = f.slot .. ":" .. f.issue end
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
    -- The enchants that ARE there, in words (#94)
    ----------------------------------------------------------
    -- No judgement of which are weak - the owner's call was the words only.
    eq("an enchant is listed in words",
       listed({ gearid_chest = 10, gearmod_chest = "41:0:0:0:0", gearench_chest = "Stamina +2" }),
       "chest:Stamina +2")
    -- A peer on an older build sends the id but no words; a tooltip read
    -- before the item was cached leaves "". Either way: still enchanted.
    eq("  an enchant without words is still listed as one",
       listed({ gearid_chest = 10, gearmod_chest = "41:0:0:0:0" }), "chest:enchanted")
    eq("  and so is one whose words are blank",
       listed({ gearid_chest = 10, gearmod_chest = "41:0:0:0:0", gearench_chest = "" }),
       "chest:enchanted")
    -- Any occupied slot with words, so an arcanum or a scope shows although
    -- those slots are never flagged as missing one.
    eq("  a head arcanum is listed though the head is never a finding",
       listed({ gearid_head = 10, gearmod_head = "2583:0:0:0:0", gearench_head = "Arcanum of Focus" }),
       "head:Arcanum of Focus")
    eq("  while a bare head is still no finding",
       findings({ gearid_head = 10, gearmod_head = "0:0:0:0:0", gearench_head = "" }), "")
    -- Words on an EMPTY slot are left over and say nothing.
    eq("  words on an empty slot are not listed",
       listed({ gearid_chest = 0, gearench_chest = "Stamina +2" }), "")
    -- DeserializeChar coerces a number-looking value; it is still the words.
    eq("  a number-looking value reads as text",
       listed({ gearid_wrist = 10, gearmod_wrist = "41:0:0:0:0", gearench_wrist = 5 }), "wrist:5")
    -- An off-hand with words is listed even when its kind cannot be resolved,
    -- and is not queued: the enchant answers whether it takes one.
    AltStable.PendingAuditItems = nil
    eq("  an off-hand of unknown kind with words is listed",
       listed({ gearid_offhand = 999999, gearmod_offhand = "41:0:0:0:0", gearench_offhand = "Spirit +3" }),
       "offhand:Spirit +3")
    check("    and not queued", AltStable.PendingAuditItems == nil)
    -- After the findings, which keep their order.
    do
        local mixed = T.AuditCharacter({
            level = FLOOR,
            gearid_wrist = 10, gearmod_wrist = "41:0:0:0:0", gearench_wrist = "Stamina +2",
            gearid_feet  = 10, gearmod_feet  = "0:0:0:0:0",
            gearid_chest = 10, gearmod_chest = "41:0:0:0:0", gearench_chest = "Stamina +2",
        })
        eq("a finding comes before the listed enchants", mixed[1].issue, "no enchant")
        eq("  which are alphabetical after it", mixed[2].label .. "," .. mixed[3].label, "Chest,Wrist")
    end
    -- Not audited below the floor: no words either.
    eq("  a levelling alt lists nothing",
       listed({ level = 14, gearid_chest = 10, gearmod_chest = "41:0:0:0:0",
                gearench_chest = "Stamina +2" }), "")

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
                  gearid_chest = 10, gearmod_chest = "2504:0:0:0:0",
                  gearench_chest = "Stamina +2" },
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
    -- And shown the enchant it has, green (#94).
    check("  and shown the enchant it has", clean:find("Chest=Stamina +2", 1, true) ~= nil, clean)
    do
        local shown
        for _, r in ipairs(T.DetailAuditRows()) do
            if r.value:IsShown() and r.value:GetText() == "Stamina +2" then shown = r end
        end
        local c = shown and shown.value._textColor or {}
        eq("  in green", ("%.2f,%.2f,%.2f"):format(c[1] or -1, c[2] or -1, c[3] or -1),
           "0.45,0.80,0.45")
        -- The clean bill goes BELOW the listed enchants, not on top of them.
        local _, _, _, _, lineY = T.DetailAuditLine():GetPoint(1)
        local rowY = shown and select(5, shown.label:GetPoint(1))
        check("  with the clean bill under the list", (lineY or 0) < (rowY or 0),
              tostring(lineY) .. " vs " .. tostring(rowY))
    end
    -- Every slot can list one, so the rows are pooled per GEAR slot: an
    -- enchantable-slots pool (7) would drop the eighth and ninth silently.
    do
        local decked = { guid = "decked", name = "Decked One", class = "MAGE", realm = "R",
                         level = FLOOR, race = "Human", raceName = "Human", ilvl = 50,
                         money = 100, stat_int = 400 }
        local n = 0
        for _, slot in ipairs(T.GEAR_SLOTS) do
            decked["gearid_" .. slot.key] = 10
            decked["gearmod_" .. slot.key] = "41:0:0:0:0"
            decked["gearench_" .. slot.key] = "Stamina +" .. slot.key
            n = n + 1
        end
        AltStableDB.decked = decked
        T.DrillDown("decked")
        local d = T.DetailFrame()
        local wasH = d:GetHeight()
        d:SetHeight(900)
        T.TabClick("Audit")
        local function count()
            local got = 0
            for _, line in ipairs(T.DetailAudit()) do
                if line:find("=Stamina +", 1, true) then got = got + 1 end
            end
            return got
        end
        eq("every occupied slot's enchant is listed", count(), n)
        eq("  with no notice when they fit", T.DetailStatsMore(), nil)

        -- A short panel: `detail` does not clip, so the list is CLAMPED, and
        -- what is cut is said out loud.
        d:SetHeight(260)
        T.Refresh()
        local shown = count()
        check("  a short panel cuts the list", shown < n, tostring(shown))
        local lowest = 0
        for _, r in ipairs(T.DetailAuditRows()) do
            if r.label:IsShown() then
                local by = select(5, r.label:GetPoint(1)) or 0
                if by < lowest then lowest = by end
            end
        end
        check("  and no row starts below the panel",
              lowest - 15 >= -260, tostring(lowest))
        -- Room is RESERVED for the notice, so it sits under the last row
        -- rather than on top of it.
        local noticeY = select(5, T.DetailFrame().statsMore:GetPoint(1)) or 0
        check("  the notice sits under the last row, not on it",
              noticeY <= lowest - 15, ("notice %s, last row %s"):format(noticeY, lowest))
        local more = T.DetailStatsMore() or ""
        -- +1 for the clean-bill line, which is cut too.
        check("  and the notice counts what was cut",
              more:find("+" .. (n - shown + 1) .. " more", 1, true) ~= nil, more)
        d:SetHeight(wasH)
        T.Refresh()

        -- Long words are bounded on the LEFT as well, so they are cut short
        -- rather than drawn over the slot label.
        local row = T.DetailAuditRows()[1]
        local pts = {}
        for i = 1, row.value:GetNumPoints() do pts[(row.value:GetPoint(i))] = true end
        check("  an audit value is bounded on both sides", pts.TOPLEFT and pts.TOPRIGHT)
        AltStableDB.decked = nil
    end
    -- One with a missing enchant gets no clean bill, listed enchants or not.
    T.DrillDown("messy")
    T.TabClick("Audit")
    local messy = table.concat(T.DetailAudit(), " | ")
    check("a character with a finding gets no clean bill",
          messy:find("Every enchantable slot", 1, true) == nil, messy)

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

        -- The enchant in words beside each slot (#94), behind an option that
        -- is off by default. Toward the figure on the sides, under the item
        -- level on the weapons row.
        AltStableDB.messy.gearid_wrist, AltStableDB.messy.gearench_wrist = 10, "Stamina +2"
        AltStableDB.messy.gearid_hands, AltStableDB.messy.gearench_hands = 10, "Agility +5"
        AltStableDB.messy.gearid_mainhand, AltStableDB.messy.gearench_mainhand = 10, "Crusader"
        AltStableDB.messy.gearench_feet = "Left over"           -- an empty slot
        AltStableConfig.rosterEnchants = nil
        T.Refresh()
        check("enchant words are off by default", not T.DetailSlotFrame("wrist").ench:IsShown())
        AltStableConfig.rosterEnchants = true
        T.Refresh()
        local function ench(key)
            local e = T.DetailSlotFrame(key).ench
            return e:IsShown() and e:GetText() or nil, e
        end
        eq("  on, a slot shows its enchant", (ench("wrist")), "Stamina +2")
        local _, wrist = ench("wrist")
        local p, rel, relp = wrist:GetPoint(1)
        eq("  a left-column slot's words sit to its right, over the figure",
           tostring(p) .. ">" .. tostring(relp), "LEFT>RIGHT")
        check("    anchored to the slot", rel == T.DetailSlotFrame("wrist"))
        local _, hands = ench("hands")
        local hp, _, hrelp = hands:GetPoint(1)
        eq("  a right-column slot's to its left", tostring(hp) .. ">" .. tostring(hrelp), "RIGHT>LEFT")
        local _, mh = ench("mainhand")
        local mp, mrel, mrelp = mh:GetPoint(1)
        eq("  a weapon's under its item level", tostring(mp) .. ">" .. tostring(mrelp), "TOP>BOTTOM")
        check("    anchored to that label", mrel == T.DetailSlotFrame("mainhand").ilvl)
        eq("  an empty slot shows none", (ench("feet")), nil)
        eq("  nor a slot without an enchant", (ench("chest")), nil)
        -- An id with no words reads "enchanted" here as in the audit: one
        -- record, one answer.
        AltStableDB.messy.gearid_back, AltStableDB.messy.gearmod_back = 10, "41:0:0:0:0"
        T.Refresh()
        eq("  an enchant id without words reads 'enchanted', as in the audit",
           (ench("back")), "enchanted")
        -- And hovering a synced slot (no link) names the enchant in full.
        do
            local b = T.DetailSlotFrame("mainhand")
            b.link = nil
            GameTooltip:Hide()
            b:GetScript("OnEnter")(b)
            local text = table.concat(WoW.tooltipLines or {}, "|")
            check("  hovering a synced slot shows its enchant in words",
                  text:find("Crusader", 1, true) ~= nil, text)
            b:GetScript("OnLeave")(b)
        end
        AltStableDB.messy.gearid_back, AltStableDB.messy.gearmod_back = nil, nil
        AltStableConfig.rosterEnchants = false
        T.Refresh()
        eq("  and switched off they go", (ench("wrist")), nil)
        AltStableDB.messy.gearid_wrist, AltStableDB.messy.gearench_wrist = nil, nil
        AltStableDB.messy.gearid_hands, AltStableDB.messy.gearench_hands = nil, nil
        AltStableDB.messy.gearid_mainhand, AltStableDB.messy.gearench_mainhand = nil, nil
        AltStableDB.messy.gearench_feet = nil
        T.Refresh()

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
    -- A real panel height: the block above leaves it at 20, where the clamp
    -- rightly cuts even this one line.
    T.DetailFrame():SetHeight(700)
    T.TabClick("Audit")
    local naked = table.concat(T.DetailAudit(), " | ")
    T.DetailFrame():SetHeight(20)
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
        AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
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
-- Both hints name the command that ships (#89)
------------------------------------------------------------
-- Capture ships with the addon now, as /alts portrait. The hints used to depend
-- on whether the development probe happened to be loaded - naming /asrender
-- when it was, and a tool "not part of the download" when it was not - and the
-- two views did not even agree on that. Now there is one command, for
-- everyone, and one phrase for it (AltStable.PortraitSourceText).
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

    local heldProbe = _G.AltStableProbe
    for _, probe in ipairs({ false, true }) do
        _G.AltStableProbe = probe and { CapturePortrait = function() end } or nil
        local label = probe and " (probe loaded)" or ""

        AltStableConfig.rosterView = "grid"
        T.Refresh()
        local grid = T.HintText() or ""
        check("the grid hint names /alts portrait" .. label,
              grid:find("/alts portrait", 1, true) ~= nil, grid)
        check("  and never the dev-only /asrender" .. label,
              grid:find("asrender", 1, true) == nil, grid)
        check("  and still counts the portraits" .. label,
              grid:find("0 of 3", 1, true) ~= nil, grid)

        AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
        AltStableConfig.rosterView = "scene"
        T.Refresh()
        local scene = T.HintText() or ""
        check("an empty scene says there are no portraits" .. label,
              scene:find("No portraits yet", 1, true) ~= nil, scene)
        check("  names the same command" .. label,
              scene:find("/alts portrait", 1, true) ~= nil, scene)
        check("  and does not offer favouriting as the fix" .. label,
              scene:find("favourite", 1, true) == nil, scene)
    end
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

------------------------------------------------------------
-- A portrait belongs to a GUID, not to a name (#89)
------------------------------------------------------------
-- Two characters can share a name - different realms, different accounts - and
-- punctuation or accents fold different names into one slug. A manifest keyed
-- by name alone hangs one character's portrait on both. The name key stays as
-- the fallback for manifests written before entries carried a GUID.
do
    local saved = AltStableCutoutManifest
    local mine  = { guid = "Player-1-AAAA", name = "Twin Name" }
    local other = { guid = "Player-2-BBBB", name = "Twin Name" }
    local art = function(extra)
        local e = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
        for k, v in pairs(extra or {}) do e[k] = v end
        return e
    end

    AltStableCutoutManifest = { ["Player-1-AAAA"] = art({ guid = "Player-1-AAAA" }) }
    check("a portrait keyed by GUID is found", T.CutoutFor(mine) ~= nil)
    eq("  and is not found for a namesake", T.CutoutFor(other), nil)

    AltStableCutoutManifest = { ["twin-name"] = art() }
    check("a legacy name-keyed portrait is still found", T.CutoutFor(mine) ~= nil)

    AltStableCutoutManifest = { ["twin-name"] = art({ guid = "Player-1-AAAA" }) }
    check("a name-keyed entry that names its GUID is found for that character",
          T.CutoutFor(mine) ~= nil)
    eq("  and refused for anyone else with that name", T.CutoutFor(other), nil)

    -- The GUID entry wins over a name entry that would also match.
    local byGuid = art({ guid = "Player-2-BBBB", file = "other.tga" })
    AltStableCutoutManifest = { ["twin-name"] = art(), ["Player-2-BBBB"] = byGuid }
    eq("the GUID entry is preferred to the name entry", T.CutoutFor(other), byGuid)

    -- And the GUID entry must be drawable too, or it falls back to the name.
    AltStableCutoutManifest = { ["twin-name"] = art(), ["Player-2-BBBB"] = { guid = "Player-2-BBBB" } }
    check("an undrawable GUID entry falls back to the name entry",
          T.CutoutFor(other) ~= nil and T.CutoutFor(other).file == "x.tga")

    AltStableCutoutManifest = saved
end

------------------------------------------------------------
-- Enhanced textures (AltStableCompanion#17; PORTRAIT-CONTRACT.md section 3)
------------------------------------------------------------

do
    local ET = T.EffectiveTexture
    local PLAIN = [[Interface\AddOns\AltStableCutouts\Cutouts\enh-anced.tga]]
    local ENH = [[Interface\AddOns\AltStableCutouts\Cutouts\Enhanced\enh-anced.tga]]
    local function plainEntry(enhanced)
        return { guid = "Player-9-ENH", file = PLAIN, w = 146, h = 512, texw = 256, texh = 512,
                 enhanced = enhanced }
    end
    local function enhanced(over)
        local d = { file = ENH, w = 188, h = 400, texw = 256, texh = 512 }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end

    local plain = plainEntry()
    check("an entry without `enhanced` draws itself", ET(plain) == plain)
    check("no entry, nothing to draw", ET(nil) == nil)
    local both = plainEntry(enhanced())
    check("a well-formed `enhanced` is what is drawn", ET(both) == both.enhanced)

    -- Malformed: the plain portrait, never a broken figure.
    local bad = {
        { "an empty file", enhanced({ file = "" }) },
        { "a file that is not a string", enhanced({ file = 123 }) },
        { "a missing texh", enhanced({ texh = false }) },
        { "a width given as a string", enhanced({ w = "188" }) },
        { "a zero height", enhanced({ h = 0 }) },
        { "a negative width", enhanced({ w = -1 }) },
        { "a NaN", enhanced({ texw = 0 / 0 }) },
        { "an infinite size", enhanced({ texh = math.huge }) },
    }
    for _, case in ipairs(bad) do
        if case[2].texh == false then case[2].texh = nil end
        local e = plainEntry(case[2])
        check("`enhanced` with " .. case[1] .. " falls back to the plain portrait", ET(e) == e)
    end
    local notTable = plainEntry("Enhanced\\x.tga")
    check("`enhanced` that is not a table falls back to the plain portrait", ET(notTable) == notTable)

    -- UVs and aspect from the descriptor DRAWN (different aspect, POT padding).
    local _, pr, _, pb = T.TexCoordsFor(ET(plain))
    local _, er, _, eb = T.TexCoordsFor(ET(both))
    check("the plain portrait crops its own padding", math.abs(pr - 146 / 256) < 1e-9 and pb == 1)
    check("the enhanced one crops ITS padding", math.abs(er - 188 / 256) < 1e-9 and math.abs(eb - 400 / 512) < 1e-9,
          ("%s,%s"):format(er, eb))
    local gw = T.FigureSize(ET(both), 200)
    check("the grid fits the enhanced picture's aspect", math.abs(gw - 200 * 188 / 400) < 1e-9, tostring(gw))
    local sw, sh = T.RelativeFigureSize(ET(both), 1.0, 1.0, 300)
    local _, ph = T.RelativeFigureSize(ET(plain), 1.0, 1.0, 300)
    check("the scene keeps the race's height for the enhanced picture", sh == ph and sh == 300)
    check("  and takes its width from the enhanced aspect", math.abs(sw - 300 * 188 / 400) < 1e-9, tostring(sw))

    -- Every drawing path draws it: grid, scene, detail.
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    local guid = "Player-9-ENH"
    AltStableDB = { [guid] = { guid = guid, name = "Enh Anced", class = "MAGE", level = 60, race = "Human" } }
    AltStableCutoutManifest = { [guid] = plainEntry(enhanced()) }

    local card = T.BuildCard(WoW.makeFrame(), 1)
    T.RenderCard(card, AltStableDB[guid], 100, 140)
    eq("the grid card draws the enhanced picture", card.figure:GetTexture(), ENH)

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView = "scene"
    T.Refresh()
    local drawn, fw, fh
    for _, c in ipairs(T.Cards()) do
        if c.char and c.char.guid == guid then
            drawn, fw, fh = c.figure:GetTexture(), c.figure:GetWidth(), c.figure:GetHeight()
        end
    end
    eq("the scene draws the enhanced picture", drawn, ENH)
    check("  at the enhanced picture's proportions", fw and fh and fh > 0 and math.abs(fw / fh - 188 / 400) < 1e-6,
          ("%s x %s"):format(tostring(fw), tostring(fh)))

    check("the character opens in detail", T.DrillDown(guid))
    eq("the detail view draws the enhanced picture", T.DetailFrame().figure:GetTexture(), ENH)
    T.Back()

    AltStableCutoutManifest = { [guid] = plainEntry(enhanced({ w = "wide" })) }
    T.RenderCard(card, AltStableDB[guid], 100, 140)
    eq("a malformed `enhanced` draws the plain portrait in the grid", card.figure:GetTexture(), PLAIN)
    T.Refresh()
    drawn = nil
    for _, c in ipairs(T.Cards()) do
        if c.char and c.char.guid == guid then drawn = c.figure:GetTexture() end
    end
    eq("  and in the scene", drawn, PLAIN)

    AltStableConfig.rosterView = nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

------------------------------------------------------------
-- Pets in the scene (#75)
------------------------------------------------------------
-- A hunter (night elf, cat) and a warlock (gnome, voidwalker): one either side
-- of the fire. Boxes are the six numbers Forever returns; the cat's is the
-- measured one.
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    local CAT, VOID = 143626, 1132
    AltStableDB = {
        ["pet-hunter"] = { guid = "pet-hunter", name = "Kaleid Sumner", class = "HUNTER",
            level = 20, race = "NightElf", gender = "Female", sexID = 1,
            pet_display = CAT, pet_npc = 251245, pet_name = "Tarthosuk" },
        ["pet-lock"] = { guid = "pet-lock", name = "Morphisto Ruskador", class = "WARLOCK",
            level = 18, race = "Gnome", gender = "Male", sexID = 0,
            pet_display = VOID, pet_npc = 1860, pet_name = "Hathnos" },
    }
    AltStableCutoutManifest = {
        ["kaleid-sumner"]      = { file = "k.tga", w = 100, h = 512, texw = 128, texh = 512 },
        ["morphisto-ruskador"] = { file = "m.tga", w = 100, h = 512, texw = 128, texh = 512 },
    }
    WoW.modelBoxes = {
        [CAT]  = { -3.686, -1.6145, -0.0317, 1.0157, 1.3213, 1.6881 },
        [VOID] = { -1, -1, 0, 1, 1, 3 },
    }

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView = "scene"

    local function pets()
        local out = {}
        for i, card in ipairs(T.Cards()) do
            local f = T.Pets()[i]
            if card:IsShown() and card.char and f and f:IsShown() then
                out[card.char.guid] = { pet = f, card = card }
            end
        end
        return out
    end
    local function x(region) return select(4, region:GetPoint()) end

    AltStableConfig.rosterPets = nil     -- never set: off, not "not false"
    T.Refresh()
    check("pets are off by default: none drawn", next(pets()) == nil)
    -- Where everyone stands with no pets, to see them make room for one.
    local offX = {}
    for _, card in ipairs(T.Cards()) do
        if card:IsShown() and card.char then offX[card.char.guid] = x(card) end
    end

    AltStableConfig.rosterPets = true
    T.Refresh()
    local drawn = pets()
    local cat, void = drawn["pet-hunter"], drawn["pet-lock"]
    check("with the option on, the hunter's pet is drawn", cat ~= nil)
    check("  and the warlock's demon", void ~= nil)

    if cat and void then
        eq("the pet shows its saved display", cat.pet.actor._display, CAT)
        eq("  the demon too", void.pet.actor._display, VOID)

        -- Behind the whole cast, not just its owner: a big demon beside the
        -- figure nearest the camera covered its neighbour (measured).
        for who, d in pairs(drawn) do
            for _, card in ipairs(T.Cards()) do
                if card:IsShown() then
                    check(who .. ": the pet is behind " .. tostring(card.char and card.char.name),
                          d.pet:GetFrameLevel() < card:GetFrameLevel())
                end
            end
            check(who .. ": and above the backdrop", d.pet:GetFrameLevel() > T.Panel():GetFrameLevel())
        end
        -- +1 is the pets' level for ANY spot: the ring's deepest figure (level 0,
        -- at the fire) must not tie with them, which two figures here never reach.
        local base = T.Panel():GetFrameLevel()
        for _, card in ipairs(T.Cards()) do
            if card:IsShown() then
                check("a character's level clears the pets' even at the fire",
                      card:GetFrameLevel() - base - (card._spotLevel or 0) >= 3)
            end
        end



        -- One owner each side of the fire: each is nearest it on its side, so
        -- each pet stands on the fire side, turned 20 degrees toward it.
        local cx, vx = x(cat.card), x(void.card)
        check("the hunter's pet stands toward the fire", (x(cat.pet) - cx) * (vx - cx) > 0)
        check("the demon stands toward the fire", (x(void.pet) - vx) * (cx - vx) > 0)
        local turn = math.rad(20)
        check("  turned 20 degrees toward it",
              math.abs((cat.pet.actor._yaw or 0) - turn * ((vx > cx) and 1 or -1)) < 1e-9)

        -- The owner steps aside in its slot, away from its pet.
        local slot = T.SceneSlot()
        for who, d in pairs(drawn) do
            local moved = x(d.card) - (offX[who] or x(d.card))
            check(who .. ": the owner stepped away from it by its share of the slot",
                  math.abs(math.abs(moved) - slot * T.PET_LAYOUT.ownerShift) < 1e-6
                  and moved * (x(d.pet) - x(d.card)) < 0, tostring(moved))
            -- Out by part of the OWNER's width only: mostly behind them.
            local want = d.card.figure:GetWidth() * T.PET_LAYOUT.reach
            check(who .. ": the pet stands mostly behind its owner",
                  math.abs(math.abs(x(d.pet) - x(d.card)) - want) < 1e-6,
                  math.abs(x(d.pet) - x(d.card)) .. " vs " .. want)
        end

        -- In the cast's units: the cat 0.55 (box 1.72 x 0.32) against a 1.10
        -- night elf; the voidwalker 1.00 against a 0.60 gnome.
        local catRatio = cat.pet:GetHeight() / cat.card.figure:GetHeight()
        local voidRatio = void.pet:GetHeight() / void.card.figure:GetHeight()
        check("the cat stands about half its owner's height",
              math.abs(catRatio - (1.6881 + 0.0317) * 0.32 * 1.3 / 1.10) < 0.01, tostring(catRatio))
        check("the voidwalker towers over its gnome",
              math.abs(voidRatio - 1.00 * 1.3 / 0.60) < 0.01, tostring(voidRatio))
        eq("an imp stands a little under its gnome", T.PetUnits({ pet_npc = 416 }, 9), 0.45)

        -- Framed from its own box: the model's height fills the frame. The
        -- field of view spans the WIDTH (measured), so a wide frame sees less
        -- height than its width.
        local span = 2 * 40 * math.tan(0.075)
        check("the cat's frame is wide", cat.pet:GetWidth() > cat.pet:GetHeight())
        local viewH = span * cat.pet:GetHeight() / cat.pet:GetWidth()
        check("the model is scaled from its box",
              math.abs(cat.pet.actor._scale - viewH / ((1.6881 + 0.0317) * 1.3)) < 1e-6,
              tostring(cat.pet.actor._scale))
        -- A TALL frame sees the full span as its height (an imp clipped top
        -- and bottom when the span was taken as its width).
        check("the voidwalker's frame is tall", void.pet:GetHeight() > void.pet:GetWidth())
        check("a tall frame's model is scaled to the full span",
              math.abs(void.pet.actor._scale - span / (3 * 1.3)) < 1e-6, tostring(void.pet.actor._scale))

        -- Room to spare across: a frame cut to the model's width clipped it.
        local box = { l = 1.0157 + 3.686, w = 1.3213 + 1.6145, h = 1.6881 + 0.0317 }
        local shape = T.PetAspect(box, cat.pet.actor._yaw or 0) * 1.4 / 1.3
        check("the frame has room to spare across",
              math.abs(cat.pet:GetWidth() / cat.pet:GetHeight() - shape) < 1e-6,
              cat.pet:GetWidth() / cat.pet:GetHeight() .. " vs " .. shape)

        -- And above and below, with the feet still on the ground: the frame
        -- drops by the spare under the model. Feet = the owner's ground (card
        -- bottom + name block) plus the step back.
        for who, d in pairs(drawn) do
            local frameH = d.pet:GetHeight()
            local feet = select(5, d.pet:GetPoint()) + (frameH - frameH / 1.3) / 2
            local ground = select(5, d.card:GetPoint()) + 28 + 4 + T.Panel():GetHeight() * 0.03
            check(who .. ": the pet's feet are on the ground", math.abs(feet - ground) < 1e-6,
                  feet .. " vs " .. ground)
        end

        -- Alive, but with no particles: an imp's fire burned past its frame and
        -- swelled its box. The idle animation stays (owner's call).
        eq("the pet has no particles", cat.pet.actor._particles, 0)
        check("  and is not frozen", cat.pet.actor._animSpeed ~= 0 and not cat.pet._paused)

        -- Clicks belong to the cards.
        check("a pet does not take the mouse", not cat.pet:IsMouseEnabled())
    end

    -- A model that never loaded is tried again by the next Refresh, not left
    -- re-placed without a box forever (Codex).
    AltStableDB["pet-lock"].pet_display = 1134
    T.Refresh()
    for _ = 1, 40 do WoW.flushTimers() end
    check("a model that never loads is not drawn", pets()["pet-lock"] == nil)
    WoW.modelBoxes[1134] = { -1, -1, 0, 1, 1, 3 }
    T.Refresh()
    check("  and the next Refresh tries it again", pets()["pet-lock"] ~= nil)
    WoW.modelBoxes[VOID] = { -1, -1, 0, 1, 1, 3 }
    AltStableDB["pet-lock"].pet_display = VOID
    T.Refresh()

    -- A pet whose model has not loaded waits, then appears.
    WoW.modelBoxes[VOID] = nil
    AltStableDB["pet-lock"].pet_display = 1133
    T.Refresh()
    check("a pet with no box yet is not drawn", pets()["pet-lock"] == nil)
    WoW.modelBoxes[1133] = { -1, -1, 0, 1, 1, 3 }
    WoW.flushTimers()
    check("  and appears once its model has loaded", pets()["pet-lock"] ~= nil)

    -- No pet recorded: nothing beside them.
    AltStableDB["pet-lock"].pet_display = nil
    T.Refresh()
    check("a character with no pet has none drawn", pets()["pet-lock"] == nil)
    check("  while the other's stays", pets()["pet-hunter"] ~= nil)

    -- The grid is cards, not a camp.
    AltStableConfig.rosterView = "grid"
    T.Refresh()
    local any = false
    for _, f in pairs(T.Pets()) do if f and f:IsShown() then any = true end end
    check("the grid draws no pets", not any)

    AltStableConfig.rosterPets = nil
    AltStableConfig.rosterView = nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
    WoW.modelBoxes = {}
end

-- Which side and which way, counted out from the fire (owner's layout).
do
    local t = math.rad(20)
    local four = T.PetSides({ { x = 100 }, { x = 300 }, { x = 700 }, { x = 900 } }, 500)
    local sides, yaws = {}, {}
    for i, p in ipairs(four) do sides[i], yaws[i] = p.side, p.yaw end
    eq("four: pets left, right, left, right", table.concat(sides, " "), "-1 1 -1 1")
    eq("  the outer two face the viewer", yaws[1] == 0 and yaws[4] == 0, true)
    eq("  and are marked outer", (four[1].outer and four[4].outer and not four[2].outer and not four[3].outer) and true, true)
    check("  the inner two turn 20 degrees to the fire",
          math.abs(yaws[2] - t) < 1e-9 and math.abs(yaws[3] + t) < 1e-9)
    local two = T.PetSides({ { x = 300 }, { x = 700 } }, 500)
    eq("two: each pet on its fire side", two[1].side .. " " .. two[2].side, "1 -1")
    local lopsided = T.PetSides({ { x = 100 }, { x = 200 }, { x = 300 } }, 500)
    eq("three on one side: alternating out from the fire",
       lopsided[1].side .. " " .. lopsided[2].side .. " " .. lopsided[3].side, "1 -1 1")

    -- Kept inside the panel: a pet at the scene's edge never spills over.
    -- Kept inside the panel by its MODEL's width (the frame's spare is empty).
    local pad = T.PET_LAYOUT.edgePad
    eq("a pet past the left edge is brought inside", T.PetX(50, 100, 200, -1, 1000), 100 + pad)
    eq("  past the right edge too", T.PetX(950, 100, 200, 1, 1000), 900 - pad)
    eq("  and left alone inside", T.PetX(500, 100, 200, 1, 1000),
       500 + 100 * T.PET_LAYOUT.reach)
    eq("  an outer pet stands beside its owner by both widths",
       T.PetX(500, 100, 200, 1, 1000, true), 500 + (100 + 200) / 2 * T.PET_LAYOUT.outer.reach)
    eq("  and a wide one hugs the edge", T.PetX(200, 100, 300, -1, 1000, true), 150 + pad)
    eq("an outer pet's room on the left: edge to the owner's inner shoulder", T.OuterRoom(200, 100, -1, 1000), 250 - pad)
    eq("  and on the right", T.OuterRoom(800, 100, 1, 1000), 1000 - pad - 750)
end

-- Four at the fire: the outermost owners' pets stand OUTSIDE, further out, a
-- step further back and a touch smaller (owner, in game: "there's room").
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB, AltStableCutoutManifest = {}, {}
    for i = 1, 4 do
        local guid = ("four-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Four %d"):format(i), level = 10 + i,
            class = "HUNTER", race = "Human", gender = "Male", pet_display = 3000 + i, pet_npc = 416 }
        AltStableCutoutManifest[guid] = { file = "f.tga", w = 100, h = 512, texw = 128, texh = 512 }
        WoW.modelBoxes[3000 + i] = { -1, -1, 0, 1, 1, 3 }
    end
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView, AltStableConfig.rosterPets = "scene", true
    T.Refresh()
    local rows = {}
    for i, card in ipairs(T.Cards()) do
        local f = T.Pets()[i]
        if card:IsShown() and f and f:IsShown() then
            rows[#rows + 1] = { card = card, pet = f, x = select(4, card:GetPoint()) }
        end
    end
    eq("four owners, four pets", #rows, 4)
    table.sort(rows, function(a, b) return a.x < b.x end)
    local function feetAbove(r)
        local frameH = r.pet:GetHeight()
        local feet = select(5, r.pet:GetPoint()) + (frameH - frameH / 1.3) / 2
        return feet - (select(5, r.card:GetPoint()) + 32)
    end
    local ph = T.Panel():GetHeight()
    if #rows == 4 then
        for _, k in ipairs({ 1, 4 }) do
            local r = rows[k]
            check(("outer pet %d stands a step further back"):format(k),
                  math.abs(feetAbove(r) - ph * T.PET_LAYOUT.outer.lift) < 1e-6, tostring(feetAbove(r)))
        end
        for _, k in ipairs({ 2, 3 }) do
            check(("inner pet %d stands at the usual step"):format(k),
                  math.abs(feetAbove(rows[k]) - ph * 0.03) < 1e-6, tostring(feetAbove(rows[k])))
        end
        -- Same demon, same race: only the outer size factor tells them apart
        -- (spot scale aside, so compare per spot through the owner's figure).
        local function ratio(r) return r.pet:GetHeight() / r.card.figure:GetHeight() end
        check("an outer pet is drawn further back: behind the fire-side pets",
              rows[1].pet:GetFrameLevel() < rows[2].pet:GetFrameLevel()
              and rows[4].pet:GetFrameLevel() < rows[3].pet:GetFrameLevel())
        check("  and the fire-side pets behind every character",
              rows[2].pet:GetFrameLevel() < rows[1].card:GetFrameLevel())
        check("an outer pet is drawn smaller, as further away",
              math.abs(ratio(rows[1]) / ratio(rows[2]) - T.PET_LAYOUT.outer.size) < 1e-6,
              tostring(ratio(rows[1]) / ratio(rows[2])))
        -- Reach is a share of the OWNER's width: compare shares, not pixels -
        -- the outer owners stand nearer the camera and are drawn bigger.
        local function share(r)
            return math.abs(select(4, r.pet:GetPoint()) - r.x) / r.card.figure:GetWidth()
        end
        check("an inner pet reaches the usual share",
              math.abs(share(rows[2]) - T.PET_LAYOUT.reach) < 1e-6, tostring(share(rows[2])))
        -- The right-hand outer pet: beside its owner by both widths (the model's
        -- width is its frame's less the 40% spare), unless the edge stops it.
        do
            local r = rows[4]
            local off = math.abs(select(4, r.pet:GetPoint()) - r.x)
            local modelW = r.pet:GetWidth() / 1.4
            local want = (r.card.figure:GetWidth() + modelW) / 2 * T.PET_LAYOUT.outer.reach
            local edge = T.Panel():GetWidth() - modelW / 2 - T.PET_LAYOUT.edgePad
            check("an outer pet stands beside its owner by both widths (or at the edge)",
                  math.abs(off - want) < 1e-6 or math.abs(select(4, r.pet:GetPoint()) - edge) < 1e-6,
                  off .. " vs " .. want)
        end
    end
    -- A demon too wide for its corner is shrunk to it, never let over the
    -- next character: no wider than the edge to its owner's inner shoulder.
    for i = 1, 4 do WoW.modelBoxes[3000 + i] = nil; WoW.modelBoxes[4000 + i] = { -1, -20, 0, 1, 20, 3 } end
    for i = 1, 4 do AltStableDB[("four-%d"):format(i)].pet_display = 4000 + i end
    T.Refresh()
    local leftmost
    for i, card in ipairs(T.Cards()) do
        local f = T.Pets()[i]
        if card:IsShown() and f and f:IsShown() then
            local cx = select(4, card:GetPoint())
            if not leftmost or cx < leftmost.x then leftmost = { card = card, pet = f, x = cx } end
        end
    end
    check("the wide outer demon is drawn", leftmost ~= nil)
    if leftmost then
        local modelW = leftmost.pet:GetWidth() / 1.4
        local room = T.OuterRoom(leftmost.x, leftmost.card.figure:GetWidth(), -1, T.Panel():GetWidth())
        check("  no wider than its corner", modelW <= room + 1e-6, modelW .. " > " .. room)
    end
    AltStableConfig.rosterView, AltStableConfig.rosterPets = nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
    WoW.modelBoxes = {}
end

-- True scale even where the pet outgrows the cast: a lone gnome's voidwalker
-- stands 1.0/0.6 of him, not his height - capped only by the panel's top.
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB = { ["g"] = { guid = "g", name = "Lone Gnome", class = "WARLOCK", level = 10,
        race = "Gnome", gender = "Male", pet_display = 1132, pet_npc = 1860 } }
    AltStableCutoutManifest = { ["lone-gnome"] = { file = "g.tga", w = 100, h = 512, texw = 128, texh = 512 } }
    WoW.modelBoxes = { [1132] = { -1, -1, 0, 1, 1, 3 } }
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView, AltStableConfig.rosterPets = "scene", true
    T.Refresh()
    local card, pet = T.Cards()[1], T.Pets()[1]
    check("the lone gnome's demon is drawn", pet and pet:IsShown())
    if pet and pet:IsShown() then
        local modelH = pet:GetHeight() / 1.3
        local ratio = modelH / card.figure:GetHeight()
        local ph = T.Panel():GetHeight()
        local feet = select(5, pet:GetPoint()) + (pet:GetHeight() - modelH) / 2
        local top = feet + modelH
        if top < ph - 1e-6 then
            check("  at 1.0/0.6 of its gnome, not his height", math.abs(ratio - 1 / 0.6) < 1e-6, tostring(ratio))
        end
        check("  and never past the panel's top", top <= ph + 1e-6, top .. " > " .. ph)
    end
    AltStableConfig.rosterView, AltStableConfig.rosterPets = nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
    WoW.modelBoxes = {}
end

-- Four round the fire, with pets or without (#170): a camp holds four, and a
-- fifth seat that came and went with the pets option only confused.
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB, AltStableCutoutManifest = {}, {}
    for i = 1, 6 do
        local guid = ("cast-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Cast %d"):format(i), level = 10 + i, class = "MAGE" }
        AltStableCutoutManifest[guid] = { file = "c.tga", w = 100, h = 512, texw = 128, texh = 512 }
    end
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil   -- seed this block's own camp (#152)
    AltStableConfig.rosterView = "scene"
    local function seated()
        local n = 0
        for _, card in ipairs(T.Cards()) do if card:IsShown() then n = n + 1 end end
        return n
    end
    AltStableConfig.rosterPets = nil
    T.Refresh()
    eq("without pets, four stand at the fire", seated(), 4)
    AltStableConfig.rosterPets = true
    T.Refresh()
    eq("with pets, the same four", seated(), 4)
    AltStableConfig.rosterPets, AltStableConfig.rosterView = nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

-- The capability marker the companion reads before it spends a generation.
do
    local f = io.open("Plugins/Roster/AltStableRoster.toc", "rb")
    local toc = f and f:read("*a") or ""
    if f then f:close() end
    check("the Roster's TOC declares enhanced-texture support",
          toc:find("\n## X%-AltStable%-Enhanced: 1\r?\n") ~= nil)
end

------------------------------------------------------------
-- The camp list (#152, part 2): retail's warband list beside the scene
------------------------------------------------------------

do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB, AltStableCutoutManifest = {}, {}
    for i = 1, 8 do
        local guid = ("pool-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Pool %d"):format(i), level = 10 * i, class = "MAGE" }
        AltStableCutoutManifest[guid] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    end
    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 1400 end
    p.GetHeight = function() return 800 end
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil
    AltStableConfig.rosterCampListHidden = nil
    AltStableConfig.rosterView = "scene"
    T.Refresh()

    local L = AltStable.RosterPlugin.CampList
    local LT = L._test
    -- Read straight after the FIRST refresh: the list was once drawn before
    -- the first camp was seeded, and only showed it on the next one.
    eq("the very first open already lists the new camp", LT.Rows()[1] and LT.Rows()[1].text:GetText(), "Camp 1")
    check("the camp list is open in the scene view", LT.List():IsShown())
    eq("  taking its width off the scene", AltStable.RosterPlugin.SceneInset(), L.LIST_W)
    check("  with the toggle along the bottom", LT.Toggle():IsShown())
    local function Rightmost()
        local x = 0
        for _, card in ipairs(T.Cards()) do
            if card:IsShown() then x = math.max(x, (select(4, card:GetPoint()))) end
        end
        return x
    end
    local withList = Rightmost()
    check("the figures stand left of the list", withList > 0 and withList < 1400 - L.LIST_W, tostring(withList))
    -- The same camp with the list tucked away spreads over the whole panel.
    LT.ToggleButton():GetScript("OnClick")(LT.ToggleButton())
    local without = Rightmost()
    LT.ToggleButton():GetScript("OnClick")(LT.ToggleButton())
    check("  and spread wider once it is tucked away", without > withList, without .. " vs " .. withList)

    local function kinds()
        local out = {}
        for _, it in ipairs(L.Items()) do
            out[#out + 1] = it.kind .. (it.guid and (":" .. it.guid:sub(6)) or "")
        end
        return table.concat(out, " ")
    end
    eq("a header, its four seats, a divider, then everyone in no camp", kinds(),
       "header slot:8 slot:7 slot:6 slot:5 sep char:4 char:3 char:2 char:1")
    local rows = LT.Rows()
    eq("the header row names the camp", rows[1].text:GetText(), "Camp 1")
    local camp1 = AltStable.GetCamps()[1].id

    local function item(kind, guid, campName)
        for _, it in ipairs(L.Items()) do
            if it.kind == kind and (guid == nil or it.guid == guid)
               and (campName == nil or (it.camp and it.camp.name == campName)) then return it end
        end
    end
    local function members(id) return table.concat(AltStable.GetCamp(id).members, ","):gsub("pool%-", "") end

    -- Dropping.
    local outsider = { kind = "char", guid = "pool-3" }
    check("a full camp's header refuses a newcomer", not L.Drop(outsider, item("header")))
    local seat2 = item("slot", "pool-7")
    check("onto a seat in a full camp, the newcomer takes it", L.Drop(outsider, seat2))
    eq("  the one sitting there leaves", members(camp1), "8,3,6,5")
    check("  and is back among the campless", item("char", "pool-7") ~= nil)
    check("a seat dragged onto another seat reorders", L.Drop({ kind = "char", guid = "pool-8", fromCamp = camp1, fromPos = 1 }, item("slot", "pool-6")))
    eq("  in that order", members(camp1), "3,6,8,5")

    -- A new camp, through the dialog.
    LT.Plus():GetScript("OnClick")(LT.Plus())
    local d = L.Dialog()
    check("+ opens the camp dialog", d and d:IsShown())
    eq("  offering a numbered name", d.box:GetText(), "Camp 2")
    check("  with no Delete for a camp that does not exist yet", not d.delete:IsShown())
    d.box:SetText("   ")
    check("a blank name is not accepted", not L.AcceptDialog())
    d.box:SetText("Raiders")
    check("Accept makes the camp", L.AcceptDialog())
    check("  and closes the dialog", not d:IsShown())
    local raiders = AltStable.SelectedCamp()
    eq("  and shows it", raiders.name, "Raiders")
    check("an empty camp's hint points at the list's seats",
          (T.HintText() or ""):find("drag a character onto one of its seats", 1, true) ~= nil, T.HintText())
    check("its four seats are empty", kinds():find("header slot slot slot slot sep", 1, true) ~= nil, kinds())
    check("a newcomer dropped on a camp's header joins it",
          L.Drop({ kind = "char", guid = "pool-7" }, item("header", nil, "Raiders")))
    eq("  at the end", members(raiders.id), "7")
    AltStable.RemoveFromCamp("pool-7")

    -- Between camps.
    check("a member dropped on another camp's empty seat moves",
          L.Drop({ kind = "char", guid = "pool-5", fromCamp = camp1, fromPos = 4 }, item("slot", nil, "Raiders")))
    eq("  out of the first", members(camp1), "3,6,8")
    eq("  into the second", members(raiders.id), "5")
    check("onto someone in another camp, the two swap",
          L.Drop({ kind = "char", guid = "pool-3", fromCamp = camp1, fromPos = 1 }, item("slot", "pool-5")))
    eq("  one way", members(raiders.id), "3")
    eq("  and the other", members(camp1), "5,6,8")
    check("dragged out into the list, a member leaves its camp",
          L.Drop({ kind = "char", guid = "pool-8", fromCamp = camp1, fromPos = 3 }, { kind = "out" }))
    check("  and is campless", not AltStable.CampOf("pool-8"))
    local function campless()
        local out = {}
        for _, c in ipairs(L.Campless()) do out[#out + 1] = c.guid:sub(6) end
        return table.concat(out, ",")
    end
    eq("  landing at the end of the campless", campless():match("8$"), "8")
    check("a header dropped on another reorders the camps",
          L.Drop({ kind = "camp", id = raiders.id }, item("header", nil, "Camp 1")))
    eq("  Raiders first", AltStable.GetCamps()[1].name, "Raiders")

    -- The characters in no camp are dragged up and down too, as on retail
    -- (#170): onto another to go before it, onto the divider for the top,
    -- into the empty space for the end.
    local before = campless()
    check("a campless character dropped on another moves before it",
          L.Drop({ kind = "char", guid = "pool-1" }, item("char", "pool-4")))
    check("  so it lists just above it", campless():find("1,4", 1, true) ~= nil, campless())
    check("  and the order is saved", type(AltStableConfig.rosterListOrder) == "table"
          and #AltStableConfig.rosterListOrder == #L.Campless())
    L.Drop({ kind = "char", guid = "pool-2" }, item("sep"))
    eq("dropped on the divider, it goes to the top", campless():match("^%d+"), "2")
    L.Drop({ kind = "char", guid = "pool-2" }, { kind = "out" })
    eq("into the empty space, to the end", campless():match("%d+$"), "2")
    check("dropped on itself, nothing moves", not L.Drop({ kind = "char", guid = "pool-2" }, item("char", "pool-2")))
    check("a camp member dropped among them leaves its camp and lands there",
          L.Drop({ kind = "char", guid = "pool-6", fromCamp = camp1, fromPos = 2 }, item("char", "pool-4"))
          and not AltStable.CampOf("pool-6") and campless():find("6,4", 1, true) ~= nil)
    check("the list shows them in that order", (function()
        local seen = {}
        for _, it in ipairs(L.Items()) do if it.kind == "char" then seen[#seen + 1] = it.guid:sub(6) end end
        return table.concat(seen, ",") == campless()
    end)())
    AltStable.AddToCamp("pool-6", camp1)

    -- The real gesture: drag a row, release over another.
    T.Refresh()
    local srcRow, dstRow
    for i = 1, L.shown do
        local r = rows[i]
        if r.item and r.item.kind == "char" and r.item.guid == "pool-1" then srcRow = r end
        if r.item and r.item.kind == "slot" and r.item.camp.name == "Camp 1" and not r.item.guid then dstRow = r end
    end
    check("there is a row to drag and an empty seat to drop on", srcRow and dstRow)
    if srcRow and dstRow then
        dstRow._mouseOver = true
        srcRow:GetScript("OnDragStart")(srcRow)
        check("dragging shows the name under the cursor", L.drag ~= nil and L.drag.guid == "pool-1")
        srcRow:GetScript("OnDragStop")(srcRow)
        dstRow._mouseOver = nil
        check("releasing over a seat puts it there", (AltStable.CampOf("pool-1")) and AltStable.CampOf("pool-1").name == "Camp 1")
        check("  and the drag is over", L.drag == nil)
    end

    -- Rename, then delete, from a right-click on the header.
    T.Refresh()
    local headerRow
    for i = 1, L.shown do
        if rows[i].item and rows[i].item.kind == "header" and rows[i].item.camp.name == "Raiders" then headerRow = rows[i] end
    end
    headerRow:GetScript("OnClick")(headerRow, "RightButton")
    check("right-click on a header opens the dialog for it", d:IsShown() and d.camp and d.camp.name == "Raiders")
    check("  with Delete", d.delete:IsShown())
    d.box:SetText("Raid Team")
    L.AcceptDialog()
    eq("Accept renames", AltStable.GetCamp(raiders.id).name, "Raid Team")
    L.OpenDialog(AltStable.GetCamp(raiders.id))
    d.delete:GetScript("OnClick")(d.delete)
    check("Delete asks first", d.confirm:IsShown() and not d.edit:IsShown())
    check("  naming the camp", (d.question:GetText() or ""):find("Raid Team", 1, true) ~= nil)
    d.no:GetScript("OnClick")(d.no)
    check("No goes back", d.edit:IsShown() and AltStable.GetCamp(raiders.id) ~= nil)
    d.delete:GetScript("OnClick")(d.delete)
    d.yes:GetScript("OnClick")(d.yes)
    check("Yes deletes it", AltStable.GetCamp(raiders.id) == nil and not d:IsShown())
    L.OpenDialog(nil)
    d:GetScript("OnKeyDown")(d, "ESCAPE")
    check("Escape closes the dialog", not d:IsShown())

    -- Folding, searching.
    T.Refresh()
    for i = 1, L.shown do
        if rows[i].item and rows[i].item.kind == "header" then
            rows[i].fold:GetScript("OnClick")(rows[i].fold); break
        end
    end
    check("folding a camp hides its seats", not kinds():find("slot", 1, true), kinds())
    for k in pairs(LT.Folded) do LT.Folded[k] = nil end
    L.search = "pool 4"
    eq("searching lists matches only, no empty seats", kinds(), "header sep char:4")
    L.search = ""

    -- The toggle along the bottom.
    LT.ToggleButton():GetScript("OnClick")(LT.ToggleButton())
    check("the toggle tucks the list away", not LT.List():IsShown())
    eq("  giving the scene its width back", AltStable.RosterPlugin.SceneInset(), 0)
    check("  remembered", AltStableConfig.rosterCampListHidden == true)
    check("  and stays to bring it back", LT.Toggle():IsShown())
    LT.ToggleButton():GetScript("OnClick")(LT.ToggleButton())
    check("and it comes back", LT.List():IsShown())

    -- At the Roster's own minimum width the list fits beside the WHOLE top
    -- bar: the Grid button (TOPRIGHT, left of the list) clears the backdrop
    -- picker, which ends at 8 + 200 + 8 + 240 (#169 review).
    local minW = AltStable.RosterPlugin.MinPanelW()
    p.GetWidth = function() return minW end
    T.Refresh()
    check("at the minimum width the list is shown", LT.List():IsShown())
    local gridLeft = minW - L.LIST_W - 8 - 64
    check("  and the Grid button clears the backdrop picker", gridLeft >= 8 + 200 + 8 + 240,
          gridLeft .. " < " .. (8 + 200 + 8 + 240))
    p.GetWidth = function() return minW - 1 end
    T.Refresh()
    check("a pixel narrower, the list steps aside", not LT.List():IsShown())
    p.GetWidth = function() return 1400 end
    T.Refresh()

    -- The dialog lets go of the keyboard: on close, in combat, and when
    -- handing a key on fails (#169 review).
    L.OpenDialog(nil)
    check("the dialog takes the keyboard out of combat", d:IsKeyboardEnabled())
    d:GetScript("OnKeyDown")(d, "ESCAPE")
    check("  and gives it back when Escape closes it", not d:IsKeyboardEnabled())
    WoW.inCombat = true
    L.OpenDialog(AltStable.GetCamps()[1])
    check("reopened in combat it does not take the keyboard", not d:IsKeyboardEnabled())
    d.delete:GetScript("OnClick")(d.delete)
    check("  even at the delete confirmation", not d:IsKeyboardEnabled())
    WoW.inCombat = false
    L.CloseDialog()
    -- Reopened while still open (no close in between), now in combat: the
    -- earlier grab is let go, not inherited.
    L.OpenDialog(nil)
    WoW.inCombat = true
    L.OpenDialog(AltStable.GetCamps()[1])
    check("reopened in combat while open, it lets go of the earlier grab", not d:IsKeyboardEnabled())
    WoW.inCombat = false
    L.CloseDialog()
    L.OpenDialog(nil)
    d:GetScript("OnEvent")(d, "PLAYER_REGEN_DISABLED")
    check("entering combat while it is open lets go of the keyboard", not d:IsKeyboardEnabled())
    L.CloseDialog()
    local realProp = d.SetPropagateKeyboardInput
    d.SetPropagateKeyboardInput = function() error("restricted") end
    L.OpenDialog(nil)
    check("if propagation cannot be set on opening, the keyboard is let go", not d:IsKeyboardEnabled())
    d:EnableKeyboard(true)
    d:GetScript("OnKeyDown")(d, "W")
    check("  and if handing a key on fails, likewise", not d:IsKeyboardEnabled())
    d.SetPropagateKeyboardInput = realProp
    L.CloseDialog()

    -- A character's detail, opened from the scene with the list open, has the
    -- tab background over the whole panel, not the scene's narrowed one.
    T.Refresh()
    local bd = T.BackdropTex()
    local narrowed = false
    for i = 1, bd:GetNumPoints() do
        local pt, _, _, x = bd:GetPoint(i)
        if pt == "BOTTOMRIGHT" and x == -L.LIST_W then narrowed = true end
    end
    check("the scene narrows its backdrop for the list", narrowed)
    AltStable.RosterPlugin.DrillDown("pool-8")
    local still = false
    for i = 1, bd:GetNumPoints() do
        local _, _, _, x = bd:GetPoint(i)
        if x and x ~= 0 then still = true end
    end
    check("  and the detail gets it back full width", not still)
    AltStable.RosterPlugin.Back()

    -- Each character row: its faction's crest and its ruleset's badge (#170).
    AltStableDB["pool-1"].faction, AltStableDB["pool-1"].realm = "Horde", "Classic Beta PvP"
    AltStableDB["pool-2"].faction, AltStableDB["pool-2"].realm = "Alliance", nil
    local heldTex = C_Texture
    C_Texture = { GetAtlasInfo = function(name)
        return (name == "communities-icon-faction-horde" or name == "communities-icon-faction-alliance") and {} or nil
    end }
    eq("the crest is the first faction atlas this client has", L.FactionArt("Horde").atlas, "communities-icon-faction-horde")
    C_Texture = nil
    eq("  with none, the vanilla banner icon", L.FactionArt("Alliance").file, "Interface\\Icons\\INV_BannerPVP_02")
    eq("  and the Horde's", L.FactionArt("Horde").file, "Interface\\Icons\\INV_BannerPVP_01")
    check("  no crest for no faction", L.FactionArt(nil) == nil)
    C_Texture = heldTex
    check("a PvP realm's badge says PvP", L.RulesetBadge("Classic Beta PvP"):find("PvP", 1, true) ~= nil)
    check("  a PvE realm's says PvE", L.RulesetBadge("Classic Beta PvE"):find("PvE", 1, true) ~= nil)
    check("  Hardcore is HC", L.RulesetBadge("Forever Hardcore"):find("HC", 1, true) ~= nil)
    check("  RP is RP", L.RulesetBadge("Forever RP"):find("RP", 1, true) ~= nil)
    eq("  an unreadable realm has none", L.RulesetBadge(nil), "")
    T.Refresh()
    local r1, r2
    for i = 1, L.shown do
        local r = LT.Rows()[i]
        if r.item and r.item.guid == "pool-1" then r1 = r end
        if r.item and r.item.guid == "pool-2" then r2 = r end
    end
    check("a character row shows its crest", r1 and r1.faction:IsShown())
    check("  and its ruleset badge", r1 and r1.ruleset:IsShown() and (r1.ruleset:GetText() or ""):find("PvP", 1, true) ~= nil)
    check("a realm the addon cannot read shows no badge", r2 and not r2.ruleset:IsShown())
    local headerRow = LT.Rows()[1]
    check("a camp header shows neither", not headerRow.faction:IsShown() and not headerRow.ruleset:IsShown())
    -- Rows are reused by position: a new camp turns rows that held characters
    -- into a header and empty seats, which must drop the crest and badge.
    local tmp = AltStable.CreateCamp("Tmp")
    T.Refresh()
    local stale = false
    for i = 1, L.shown do
        local r = LT.Rows()[i]
        if r.item and not r.item.char and (r.faction:IsShown() or r.ruleset:IsShown()) then stale = true end
    end
    check("a row reused for a header or an empty seat drops the crest and badge", not stale)
    AltStable.DeleteCamp(tmp)
    AltStable.SelectCamp(camp1)
    T.Refresh()

    -- Refreshed the instant it is shown, before the client has sized the
    -- panel: drawn again on the next frame, not left without its list until
    -- some later refresh (#170: seconds, in game).
    p.GetWidth = function() return 0 end
    WoW.timers = {}
    T.Refresh()
    check("a refresh at no width asks to be run again next frame", #WoW.timers > 0)
    p.GetWidth = function() return 1400 end
    WoW.flushTimers()
    check("  and then shows the list", LT.List():IsShown())

    -- A size change mid-glide (#159: opening the Roster grows the window to
    -- its minimum) repaints the rows and decides nothing: it once hid the list
    -- at a half-way width while the scene kept its room - an empty strip.
    T.Refresh()
    check("the list is open before the glide", LT.List():IsShown())
    p.GetWidth = function() return 500 end
    LT.Scroll():GetScript("OnSizeChanged")(LT.Scroll())
    check("a size change mid-glide leaves the list shown", LT.List():IsShown())
    eq("  and the scene's room for it", AltStable.RosterPlugin.SceneInset(), L.LIST_W)
    check("  with its rows drawn", L.shown > 0 and LT.Rows()[1]:IsShown())
    -- Nor does the search box (an edit box fires OnTextChanged when it is
    -- first shown, which on a second account was mid-glide) or a fold: they
    -- redraw rows, and the list was hidden again (owner, in game, #170).
    local sb = LT.Search()
    sb:SetText("")
    sb:GetScript("OnTextChanged")(sb)
    check("the search box changing mid-glide leaves the list shown", LT.List():IsShown())
    eq("  and the scene's room for it", AltStable.RosterPlugin.SceneInset(), L.LIST_W)
    local foldRow = LT.Rows()[1]
    foldRow.fold:GetScript("OnClick")(foldRow.fold)
    check("  as does a fold", LT.List():IsShown())
    foldRow.fold:GetScript("OnClick")(foldRow.fold)
    sb:SetText("pool 4")
    sb:GetScript("OnTextChanged")(sb)
    check("searching still filters the rows", L.shown > 0 and (function()
        for i = 1, L.shown do
            local it = LT.Rows()[i].item
            if it and it.char and it.guid ~= "pool-4" then return false end
        end
        return true
    end)())
    sb:SetText("")
    sb:GetScript("OnTextChanged")(sb)
    p.GetWidth = function() return 1400 end

    -- Too narrow, and the grid.
    p.GetWidth = function() return 500 end
    T.Refresh()
    check("too narrow a panel: the list steps aside", not LT.List():IsShown() and not LT.Toggle():IsShown())
    eq("  and the scene keeps its width", AltStable.RosterPlugin.SceneInset(), 0)
    p.GetWidth = function() return 1400 end
    T.Refresh()
    check("wide again, the list is back", LT.List():IsShown())
    AltStableConfig.rosterView = "grid"
    T.Refresh()
    check("the grid has no camp list", not LT.List():IsShown() and not LT.Toggle():IsShown())

    p.GetWidth, p.GetHeight = heldW, heldH
    AltStableConfig.rosterView = nil
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampListHidden = nil, nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

-- A camp member dropped on the divider when it then sorts FIRST among the
-- campless (a level 60 beside a campless level 10, no saved order): it leaves
-- its camp, and the list and scene are redrawn (#170 Codex review: the
-- "already first" check ran after the removal and skipped the redraw).
do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB = {
        hi = { guid = "hi", name = "High One", level = 60, class = "MAGE" },
        lo = { guid = "lo", name = "Low One", level = 10, class = "MAGE" },
    }
    AltStableCutoutManifest = {}
    local main = CreateFrame("Frame")
    T.Activate(main)
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 1400 end
    p.GetHeight = function() return 800 end
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = nil, nil, nil
    AltStableConfig.rosterListOrder, AltStableConfig.rosterCampListHidden = nil, nil
    AltStableConfig.rosterView = "scene"
    T.Refresh()
    local L = AltStable.RosterPlugin.CampList
    local camp = AltStable.SelectedCamp()
    AltStable.RemoveFromCamp("lo")
    T.Refresh()
    check("the setup: High in the camp, Low campless", AltStable.CampOf("hi") and not AltStable.CampOf("lo"))
    local sep
    for _, it in ipairs(L.Items()) do if it.kind == "sep" then sep = it end end
    local moved = L.Drop({ kind = "char", guid = "hi", fromCamp = camp.id, fromPos = 1 }, sep)
    check("a camp member dropped on the divider counts as a move", moved)
    check("  it has left its camp", not AltStable.CampOf("hi"))
    eq("  and lists first among the campless", L.Campless()[1].guid, "hi")
    local drawn = false
    for i = 1, L.shown do
        local it = L._test.Rows()[i].item
        if it and it.kind == "char" and it.guid == "hi" then drawn = true end
    end
    check("  and the list is redrawn with it there", drawn)

    p.GetWidth, p.GetHeight = heldW, heldH
    AltStableConfig.rosterView, AltStableConfig.rosterListOrder = nil, nil
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = nil, nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

-- Camp sync (#172, Codex): a camp with no backdrop of its own shows the
-- account's default - chosen, or the built-in first when none ever was - and
-- must show the same on the other account, whose default may differ.
do
    local R = AltStable.RosterPlugin
    local first = R.SCENE_BACKDROPS[1].id
    local other = R.SCENE_BACKDROPS[2].id
    local function shown(id)
        AltStable.SelectCamp(id)
        return R.CurrentScene().id
    end

    -- The sender never chose a default: the built-in first.
    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp, AltStableConfig.rosterCampNextId = nil, nil, nil
    AltStableConfig.rosterScene, AltStableConfig.rosterCampsAuto = nil, nil
    local id = AltStable.CreateCamp("Made with +", {})
    eq("a camp made with + shows the built-in default", shown(id), first)
    local sent = AltStable.CampSyncLines()
    -- The receiver chose another.
    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp = nil, nil
    AltStableConfig.rosterScene = other
    for _, line in ipairs(sent) do AltStable.ApplyCampSyncLine(line) end
    eq("  and still shows it on an account whose default differs", shown(id), first)

    -- The other way round: a chosen default, onto an account with none.
    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp = nil, nil
    AltStableConfig.rosterScene = other
    id = AltStable.CreateCamp("Made with + too", {})
    sent = AltStable.CampSyncLines()
    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp, AltStableConfig.rosterScene = nil, nil, nil
    for _, line in ipairs(sent) do AltStable.ApplyCampSyncLine(line) end
    eq("a chosen default arrives on an account with none", shown(id), other)

    -- A default naming a backdrop that is gone shows the first, so sends it.
    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp = nil, nil
    AltStableConfig.rosterScene = "a-backdrop-since-removed"
    eq("a default that is gone resolves to the first", AltStable.DefaultCampBackdrop(), first)

    AltStableConfig.rosterCamps, AltStableConfig.rosterCampsStamp, AltStableConfig.rosterScene = nil, nil, nil
    AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = nil, nil
end

------------------------------------------------------------
-- The backdrop picker (#152, part 3): retail's Campsites dialog
------------------------------------------------------------

do
    local savedDB, savedManifest = AltStableDB, AltStableCutoutManifest
    AltStableDB, AltStableCutoutManifest = {}, {}
    for i = 1, 3 do
        local guid = ("bd-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Bd %d"):format(i), level = i, class = "MAGE" }
        AltStableCutoutManifest[guid] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    end
    local main = CreateFrame("Frame")
    T.Activate(main)
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 1400 end
    p.GetHeight = function() return 800 end
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = nil, nil, nil
    AltStableConfig.rosterView = "scene"
    T.Refresh()

    local L = AltStable.RosterPlugin.CampList
    local B = T.SCENE_BACKDROPS
    local campA = AltStable.SelectedCamp().id

    -- The made-for-you first camp keeps topping up through a backdrop change,
    -- a rename and a no-change Apply: none of them is about who is in it
    -- (#170 review).
    check("the first camp starts made for the player", AltStable.CampsAutoSeeded())
    AltStable.SetCampBackdrop(campA, B[2].id)
    check("  a backdrop change keeps it so", AltStable.CampsAutoSeeded())
    AltStable.RenameCamp(campA, "Main")
    check("  as does a rename", AltStable.CampsAutoSeeded())
    L.OpenBackdrops()
    L.ApplyBackdrop()
    check("  and an Apply that changes nothing", AltStable.CampsAutoSeeded())

    local campB = AltStable.CreateCamp("Second")
    AltStable.SetCampBackdrop(campA, B[#B].id)        -- the last one: on the last page
    AltStable.SetCampBackdrop(campB, B[1].id)
    AltStable.SelectCamp(campA)
    T.Refresh()

    local pick = AltStable.RosterPlugin.backdropPick
    pick:GetScript("OnClick")(pick)
    local pk = L.Picker()
    check("the backdrop's name opens the picker", pk and pk:IsShown())
    eq("  with the shown camp's backdrop chosen", L.pick.chosen, B[#B].id)
    local pages = math.ceil(#B / 6)
    eq("  on the page it is on", L.pick.page, pages)
    check("  framed as chosen", (function()
        for _, t in ipairs(pk.thumbs) do if t:IsShown() and t.entry and t.entry.id == B[#B].id then return t.chosen end end
    end)())
    check("  'next' is off on the last page", not pk.next:IsEnabled())
    pk.prev:GetScript("OnClick")(pk.prev)
    eq("< goes back a page", L.pick.page, pages - 1)
    L.PickPage(-99)
    eq("paging stops at the first", L.pick.page, 1)
    check("  where 'prev' is off", not pk.prev:IsEnabled())
    local shown = 0
    for _, t in ipairs(pk.thumbs) do if t:IsShown() then shown = shown + 1 end end
    eq("six to a page", shown, math.min(6, #B))
    eq("each named", pk.thumbs[1].name:GetText(), B[1].label)
    eq("  and drawn from its own picture", pk.thumbs[1].tex:GetTexture(), B[1].file)
    -- Cropped for the picture as drawn: inside a 2px frame, so 4px smaller.
    local l, r, t = T.BackdropTexCoords(176 - 4, 99 - 4, B[1])
    local ulx, uly, _, _, urx = pk.thumbs[1].tex:GetTexCoord()
    check("  cropped for the picture inside its frame", ulx == l and urx == r and uly == t,
          table.concat({ ulx, urx, uly }, ",") .. " vs " .. table.concat({ l, r, t }, ","))

    -- Choose, and Apply to the shown camp only.
    pk.thumbs[2]:GetScript("OnClick")(pk.thumbs[2])
    eq("clicking a thumbnail chooses it", L.pick.chosen, B[2].id)
    pk.apply:GetScript("OnClick")(pk.apply)
    check("Apply closes the picker", not pk:IsShown())
    eq("  and gives the shown camp that backdrop", AltStable.GetCamp(campA).backdrop, B[2].id)
    eq("  and no other camp", AltStable.GetCamp(campB).backdrop, B[1].id)
    eq("  and the scene draws it", T.CurrentScene().id, B[2].id)

    -- Closing without applying changes nothing.
    L.OpenBackdrops()
    L.ChooseBackdrop(B[3].id)
    pk.close:GetScript("OnClick")(pk.close)
    eq("closing without Apply changes nothing", AltStable.GetCamp(campA).backdrop, B[2].id)
    L.OpenBackdrops()
    check("the picker takes the keyboard", pk:IsKeyboardEnabled())
    pk:GetScript("OnKeyDown")(pk, "ESCAPE")
    check("Escape closes it", not pk:IsShown())
    check("  and lets go of the keyboard", not pk:IsKeyboardEnabled())

    -- Apply for all camps.
    L.OpenBackdrops()
    L.ChooseBackdrop(B[4].id)
    pk.all:SetChecked(true)
    L.ApplyBackdrop()
    eq("Apply for all camps sets the shown camp", AltStable.GetCamp(campA).backdrop, B[4].id)
    eq("  and every other", AltStable.GetCamp(campB).backdrop, B[4].id)
    local later = AltStable.CreateCamp("Later")
    AltStable.SelectCamp(later)
    eq("  and a camp made afterwards starts with it", T.CurrentScene().id, B[4].id)
    AltStable.SelectCamp(campA)
    L.OpenBackdrops()
    check("the tick does not stay ticked for next time", not pk.all:GetChecked())
    L.ClosePicker()
    check("closing lets the thumbnails' pictures go", pk.thumbs[1].tex:GetTexture() == nil)

    -- Leaving the tab closes both dialogs; they do not come back open. Their
    -- dimming covers only the panel, so the sidebar stays clickable.
    L.OpenBackdrops()
    registered.OnDeactivate(main)
    check("leaving the Roster tab closes the picker", not pk:IsShown())
    T.Activate(main)
    check("  which does not come back open", not pk:IsShown())
    L.OpenDialog(nil)
    registered.OnDeactivate(main)
    check("  nor does the camp dialog", not L.Dialog():IsShown())
    T.Activate(main)

    -- With no camp at all, the shared backdrop the scene falls back to.
    for _, c in ipairs(AltStable.GetCamps()) do AltStable.DeleteCamp(c.id) end
    L.OpenBackdrops()
    L.ChooseBackdrop(B[5].id)
    L.ApplyBackdrop()
    eq("with no camp, the shared backdrop is set", AltStableConfig.rosterScene, B[5].id)

    -- Leaving the scene closes it.
    L.OpenBackdrops()
    AltStableConfig.rosterView = "grid"
    T.Refresh()
    check("switching to the grid closes the picker", not pk:IsShown())

    p.GetWidth, p.GetHeight = heldW, heldH
    AltStableConfig.rosterView, AltStableConfig.rosterScene = nil, nil
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp, AltStableConfig.rosterCampNextId = nil, nil, nil
    AltStableDB, AltStableCutoutManifest = savedDB, savedManifest
end

------------------------------------------------------------
-- The portrait hint names the Companion and links to it (#176)
------------------------------------------------------------
-- "The converter on the project page" sent players looking for a nameless
-- tool. The hint now names AltStable Companion, a click on it hands over the
-- download link, and with captures on record but the Companion's folder not
-- loaded it says a first portrait needs one full restart - as a condition: the
-- addon cannot know whether the Companion has run.
do
    local savedDB, savedManifest, savedStore = AltStableDB, AltStableCutoutManifest, AltStablePortraits
    AltStableDB = {}
    for i = 1, 3 do
        local guid = ("link-%d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Link %d"):format(i),
                              level = i * 10, ilvl = i, class = "MAGE" }
    end
    AltStableCutoutManifest, AltStablePortraits = nil, nil

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 1400 end
    main.GetHeight = function() return 800 end
    T.Activate(main)
    -- Room for every card: the grid counts the cards it draws (#178).
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 1200 end
    p.GetHeight = function() return 760 end
    AltStableConfig.favouriteCharacters = nil
    local RESTART = "restart the game once"

    for _, view in ipairs({ "grid", "scene" }) do
        AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil
        AltStableConfig.rosterView = view
        AltStablePortraits = nil
        T.Refresh()
        local hint = T.HintText() or ""
        check(view .. ": the hint names AltStable Companion",
              hint:find("AltStable Companion", 1, true) ~= nil, hint)
        check(view .. ":   and no longer a nameless converter",
              hint:find("converter", 1, true) == nil, hint)
        check(view .. ":   and is a link", T.HintLinkShown() == true)
        check(view .. ": no captures, no restart line", hint:find(RESTART, 1, true) == nil, hint)

        AltStablePortraits = { version = 1, renders = { { guid = "link-1", shot = 1 } } }
        T.Refresh()
        hint = T.HintText() or ""
        check(view .. ": captures and no Companion folder loaded: the restart line",
              hint:find(RESTART, 1, true) ~= nil, hint)
        check(view .. ":   worded as a condition, not as fact",
              hint:find("If AltStable Companion has made a portrait", 1, true) ~= nil, hint)
    end

    -- A hint of several lines pushes the cards down (#179 review): the cards
    -- are frames, drawn over the panel's text, so a fixed one-line gap hid the
    -- second and third lines - the link wording and the restart line.
    AltStableConfig.rosterView = "grid"
    local function firstCardTop()
        local card = T.Cards()[1]
        local _, _, _, _, y = card:GetPoint(1)
        return y
    end
    T.Refresh()
    local oneLine = firstCardTop()
    eq("a one-line hint keeps the cards where they always were", oneLine, -(14 + 18))
    local hint = T.Hint()
    hint.GetStringHeight = function() return 36 end      -- three lines
    T.Refresh()
    eq("a three-line hint starts the cards below it", firstCardTop(), -(14 + 36 + 6))
    hint.GetStringHeight = nil
    T.Refresh()

    -- The link box's letter limit: none (0). A limit would cut the link short
    -- (#179 review); our own box, so no other dialog's limit can leak in.
    local linkPrompt = AltStable.ShowCompanionLink()
    eq("the link box sets no letter limit (0)", linkPrompt and linkPrompt.edit:GetMaxLetters(), 0)
    AltStable.HidePrompt("Copy")

    -- The folder loaded (a manifest exists): no restart line, even with
    -- captures and someone still without a portrait.
    AltStableConfig.rosterView = "grid"
    AltStableCutoutManifest = { ["link-3"] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 } }
    T.Refresh()
    local partial = T.HintText() or ""
    check("with the folder loaded the hint still counts", partial:find("1 of 3", 1, true) ~= nil, partial)
    check("  without the restart line", partial:find(RESTART, 1, true) == nil, partial)
    check("  and is still a link", T.HintLinkShown() == true)

    -- Everyone has a portrait: no hint, so no link either.
    -- A new table, as a load gives: the lookup is cached per manifest table.
    AltStableCutoutManifest = {}
    for i = 1, 3 do
        AltStableCutoutManifest[("link-%d"):format(i)] = { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
    end
    T.Refresh()
    check("everyone with a portrait: no hint", not T.HintShown(), T.HintText())
    check("  and no link", not T.HintLinkShown())

    -- A camp hint is not a link: the scene with portraits and an empty camp.
    AltStableConfig.rosterView = "scene"
    AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = {}, nil
    AltStable.SelectCamp(AltStable.CreateCamp("Empty", {}))
    T.Refresh()
    check("an empty camp has its hint", T.HintShown() and (T.HintText() or ""):find("is empty", 1, true) ~= nil, T.HintText())
    check("  which is not the portrait link", not T.HintLinkShown(), T.HintText())

    -- The click hands over /releases - the Companion has only pre-releases,
    -- and GitHub's /latest skips them - selected, ready to copy.
    local before = #WoW.popups
    local prompt = AltStable.ShowCompanionLink()
    check("the link opens our copy box", prompt ~= nil and prompt:IsShown())
    eq("  never a StaticPopup (#199)", #WoW.popups, before)
    local box = prompt and prompt.edit
    eq("  holding the releases page", box and box:GetText(), "https://github.com/Spotnick2/AltStableCompanion/releases")
    check("  not /latest", AltStable.COMPANION_URL:find("latest", 1, true) == nil)
    if box then
        box._text = "typed over"
        box:GetScript("OnTextChanged")(box, true)
        eq("  typing over it puts the link back", box:GetText(), AltStable.COMPANION_URL)
    end
    AltStable.HidePrompt("Copy")

    AltStableConfig.rosterView, AltStableConfig.rosterCamps, AltStableConfig.rosterCamp = nil, nil, nil
    p.GetWidth, p.GetHeight = heldW, heldH
    AltStableDB, AltStableCutoutManifest, AltStablePortraits = savedDB, savedManifest, savedStore
    pcall(AltStable.RosterPlugin.Refresh)
end

------------------------------------------------------------
-- The grid counts the whole roster, and says who it is not showing (#178)
------------------------------------------------------------
-- The grid draws at most MAX_CARDS (24), and fewer when the window is small.
-- Its count used to be over the cards it DREW against the capped list, so a
-- big roster read "missing portraits" that were there, and the rest of it
-- vanished without a word.
do
    local savedDB, savedManifest, savedStore = AltStableDB, AltStableCutoutManifest, AltStablePortraits
    local savedHidden = AltStableConfig.hiddenCharacters
    AltStablePortraits = nil
    AltStableDB = {}
    -- Levels fall with i, so the grid's order is 1, 2, 3 ...
    for i = 1, 30 do
        local guid = ("big-%02d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Big %02d"):format(i),
                              level = 100 - i, ilvl = i, class = "MAGE" }
    end
    local function portraits(list)
        AltStableCutoutManifest = {}
        for _, i in ipairs(list) do
            AltStableCutoutManifest[("big-%02d"):format(i)] =
                { file = "x.tga", w = 100, h = 512, texw = 128, texh = 512 }
        end
    end
    local function range(a, b) local t = {} for i = a, b do t[#t + 1] = i end return t end

    local main = CreateFrame("Frame")
    main.GetWidth = function() return 2600 end
    main.GetHeight = function() return 2000 end
    T.Activate(main)
    AltStableConfig.favouriteCharacters = nil
    AltStableConfig.rosterView = "grid"
    local p = T.Panel()
    local heldW, heldH = p.GetWidth, p.GetHeight
    p.GetWidth = function() return 2400 end            -- room for every card there is
    p.GetHeight = function() return 1900 end
    -- The hint and the not-shown line under it, as the player reads them.
    local function hint()
        return (T.HintShown() and (T.HintText() or "") or "") .. " | " .. (T.MoreText() or "")
    end

    -- Everyone has a portrait: no portrait hint, but the six past the cap are
    -- named, and that line is not the Companion link.
    portraits(range(1, 30))
    T.Refresh()
    local h = hint()
    check("all 30 with portraits: no portrait count", h:find("have a portrait", 1, true) == nil, h)
    check("  but the six past the cap are named", h:find("+6 more not shown", 1, true) ~= nil, h)
    check("  as the grid's limit", h:find("shows 24 at most", 1, true) ~= nil, h)
    check("  and it is not a link", not T.HintLinkShown())

    -- Portraits past the cap still count: 1-19 and 25-30 have one (25), so
    -- the 24 drawn hold only 19. Counted over the drawn cards this read 19.
    local list = range(1, 19)
    for i = 25, 30 do list[#list + 1] = i end
    portraits(list)
    T.Refresh()
    h = hint()
    check("the count is over the whole roster", h:find("25 of 30 characters have a portrait", 1, true) ~= nil, h)
    check("  the not-shown line comes with it", h:find("+6 more not shown", 1, true) ~= nil, h)
    check("  and the portrait hint is the link", T.HintLinkShown() == true)
    -- The link covers the hint's string whole: the not-shown line must be in
    -- its own string, or it would open the Companion link (#180 review).
    check("  which does not cover the not-shown line",
          (T.HintText() or ""):find("more not shown", 1, true) == nil
          and (T.MoreText() or ""):find("+6 more not shown", 1, true) ~= nil,
          tostring(T.HintText()) .. " / " .. tostring(T.MoreText()))

    -- A small window: the cap is not the reason, the window is.
    portraits(range(1, 30))
    p.GetWidth = function() return 400 end
    p.GetHeight = function() return 300 end
    T.Refresh()
    local drawn = 0
    for _, card in ipairs(T.Cards()) do if card:IsShown() then drawn = drawn + 1 end end
    h = hint()
    check("a small window draws fewer than 24", drawn > 0 and drawn < 24, tostring(drawn))
    check("  and says how many it left out", h:find(("+%d more not shown"):format(30 - drawn), 1, true) ~= nil, h)
    check("  and that a larger window fits more", h:find("larger window", 1, true) ~= nil, h)

    -- Hidden characters are out of both counts, as they are out of the grid.
    p.GetWidth = function() return 2400 end
    p.GetHeight = function() return 1900 end
    portraits(range(1, 20))
    AltStable.SetCharacterHidden("big-30", true)
    T.Refresh()
    h = hint()
    check("a hidden character is out of the count", h:find("20 of 29 characters", 1, true) ~= nil, h)
    check("  and out of the not-shown count", h:find("+5 more not shown", 1, true) ~= nil, h)

    -- Fitting everyone, until the tall hint costs a row - and the not-shown
    -- line that THAT adds must be made room for too (#180 review): the cards
    -- start below the hint AND the line under it.
    AltStableConfig.hiddenCharacters = savedHidden
    AltStableDB = {}
    for i = 1, 24 do
        local guid = ("fit-%02d"):format(i)
        AltStableDB[guid] = { guid = guid, name = ("Fit %02d"):format(i),
                              level = 100 - i, ilvl = i, class = "MAGE" }
    end
    AltStableCutoutManifest = nil                     -- nobody has art: the portrait hint shows
    p.GetWidth = function() return 800 end
    p.GetHeight = function() return 460 end
    T.Refresh()
    check("24 fit this panel under a one-line hint", T.MoreText() == nil, tostring(T.MoreText()))
    T.Hint().GetStringHeight = function() return 36 end
    T.More().GetStringHeight = function() return 12 end
    T.Refresh()
    local _, _, _, _, top = T.Cards()[1]:GetPoint(1)
    check("a three-line hint costs a row, and says so", (T.MoreText() or ""):find("more not shown", 1, true) ~= nil,
          tostring(T.MoreText()))
    eq("  the cards start below the hint AND that line", top, -(14 + 36 + 2 + 12 + 6))
    T.Hint().GetStringHeight, T.More().GetStringHeight = nil, nil

    AltStableConfig.rosterView = nil
    p.GetWidth, p.GetHeight = heldW, heldH
    AltStableDB, AltStableCutoutManifest, AltStablePortraits = savedDB, savedManifest, savedStore
    pcall(AltStable.RosterPlugin.Refresh)
end

print(("test_roster: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
