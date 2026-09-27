------------------------------------------------------------
-- AltStableRoster — the alts, standing together (#15).
--
-- A character-select style lineup: every alt side by side on one backdrop,
-- click to select, hover for detail. The TBC original drew PNG "cutouts"
-- scraped from the Battle.net armory by a .NET tool. Forever has no armory, so
-- the images now come from the client itself: /asrender photographs the LIVE
-- character on a flat stage, an offline matte turns the pair into a transparent
-- TGA, and CutoutManifest.lua lists what exists.
--
-- WHY NOT LIVE MODELS. Measured on 1.60.1.70009 (docs/forever-api-notes.md):
-- a character who is not logged in renders as correct GEOMETRY with NO TEXTURE.
-- Skin, face, hair and armour are one composite built from customization data
-- that a display id does not carry; only weapons, being separate models, come
-- out right. SetPlayerModelFromGlues - the character-select renderer - returns
-- false in-game. So an offline likeness has to be a picture taken earlier.
--
-- THEREFORE THE FALLBACK IS NOT AN EDGE CASE. Cutouts are generated locally by
-- a tool outside the game, so anyone who has not run it has none at all, and a
-- character played for the first time has none yet. A card - class colour,
-- name, level - is what most characters look like for most users, and it is
-- built first here for exactly that reason.
------------------------------------------------------------

local ADDON_ID = "roster"

local CARD_GAP      = 10
local NAME_H        = 28      -- two lines: name, then level
local PAD_X, PAD_Y  = 16, 14

-- The row of furniture across the top of the panel: the backdrop picker on the
-- left, the Grid/Scene toggle on the right. Named because the hint line has to
-- know where they are, and a second copy of "20" would drift from the first.
local BAR_TOP       = 4       -- from the panel's top edge
local BAR_H         = 20
local SCENE_BAR_W   = 240
local VIEW_BTN_W    = 64
local MAX_CARDS     = 24      -- laid out in rows, so this is a sanity cap

-- The card grid is measured from the panel at refresh time rather than fixed:
-- the sheet is resizable and the number of characters is whatever the player
-- has, so a hardcoded row of twelve either overflows the panel or wastes it.
local MIN_CARD_W    = 110
local MIN_CARD_H    = 96      -- below this a portrait is not worth drawing

-- Scene view.
--
-- Every backdrop carries its own MEASURED fire position (fireX, fireBaseY in
-- SCENE_BACKDROPS), found by looking for the brightest warm mass in the lower
-- half of each TGA - see Tools/Scene/find-fire.py, which regenerates them.
--
-- Not the art spec. Media/Scene/README.md commissions the twelve generated
-- scenes at horizontal centre 50% and a base around 84%, but says in the same
-- breath that these are "approximate art targets, not measured anchors" - and
-- that Karazhan, an AltTracker original that predates the spec, "retains its
-- original smaller, slightly right-of-center fire". It measures at 0.551/0.900.
-- Hardcoding 0.50/0.84 for all fourteen puts the keep-out gap on empty ground
-- and the cast below the drawn floor on exactly that backdrop.
--
-- The first version used a ground line picked by eye and spaced everyone evenly
-- across the panel, which put somebody in the flames and hid the one element
-- that makes the picture a campsite.
-- Per-backdrop fallbacks. Each entry in SCENE_BACKDROPS carries its own
-- measured fireX/fireBaseY; these only cover an entry that somehow has none.
local FIRE_X         = 0.50   -- of the content width
local FIRE_BASE_Y    = 0.84   -- of the content height, from the TOP
local SCENE_FIGURE_H = 0.62   -- of panel height, for the TALLEST character

-- The gap kept clear around the fire, as a fraction of panel width.
local FIRE_CLEARANCE = 0.22

-- And the gap kept clear of the panel's own edges, so the outermost figure is
-- not pressed against the frame.
local SCENE_EDGE = 0.02

-- The camp is a RING seen from the front, not a line. Someone standing near the
-- fire's screen x is at the back of that ring: further away, so higher up the
-- picture and smaller. Someone out at the edge is at the ring's side, nearest
-- the camera. An ellipse gives both from one number.
local SCENE_ARC      = 0.08   -- how far back the ring reaches, of panel height
local SCENE_DEPTH    = 0.14   -- how much smaller the far side of it is

-- How many stand around the fire. Retail's warband campsite shows four or five
-- and it reads as a scene; thirteen in a row reads as a police line-up, which
-- is what the first version looked like. The grid remains the place to see
-- everyone.
local SCENE_CAST = 5
local MAX_CARD_W    = 170
local FIGURE_RATIO  = 0.94    -- of the space left ABOVE the name block

-- The backdrops, as Media/Scene/README.md specifies them: a 1024x1024 texture
-- whose real image is the top 1024x682 and whose remaining rows are opaque black
-- padding. Anything drawing one MUST remap v by h/texh or the padding shows as a
-- black band along the bottom - which is what the crop maths below is for.
local SCENE_BACKDROPS = {
    { id = "felwood", label = "Felwood",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-felwood.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.510, fireBaseY = 0.833 },
    { id = "dustwallow", label = "Dustwallow Marsh",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-dustwallow.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.492, fireBaseY = 0.802 },
    { id = "ashenvale-dusk", label = "Ashenvale at dusk",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-ashenvale-dusk.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.493, fireBaseY = 0.804 },
    { id = "ashenvale-moonlight", label = "Ashenvale by moonlight",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-ashenvale-moonlight.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.498, fireBaseY = 0.824 },
    { id = "elwynn", label = "Elwynn Forest",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-elwynn.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.487, fireBaseY = 0.830 },
    { id = "mulgore", label = "Mulgore",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-mulgore.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.487, fireBaseY = 0.850 },
    { id = "thunder-bluff", label = "Thunder Bluff",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-thunder-bluff.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.496, fireBaseY = 0.833 },
    { id = "zephyras-isle", label = "Zephyras Isle",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-zephyras-isle.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.495, fireBaseY = 0.814 },
    { id = "shendralas", label = "Shen'Dralas",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-shendralas.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.500, fireBaseY = 0.824 },
    { id = "riverglades", label = "Riverglades",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-riverglades.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.496, fireBaseY = 0.849 },
    { id = "mount-hyjal", label = "Mount Hyjal",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-mount-hyjal.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.494, fireBaseY = 0.820 },
    { id = "dalaran", label = "Dalaran",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-dalaran.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.499, fireBaseY = 0.824 },
    { id = "karazhan", label = "Karazhan",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-karazhan.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.551, fireBaseY = 0.900 },
    { id = "forest", label = "Forest Camp",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-forest.tga", w = 1024, h = 682, texh = 1024,
      fireX = 0.496, fireBaseY = 0.828 },
}

local Roster = { cards = {}, selected = nil }
AltStable = AltStable or {}
AltStable.RosterPlugin = Roster

local panel, backdropTex, hintText, sceneBar, sceneLabel, viewBtn

-- Which view, and which backdrop, remembered per account. The grid is the
-- default: it works for every character, whereas the scene needs a portrait and
-- shows a gap where one is missing.
local function View()
    return (AltStableConfig and AltStableConfig.rosterView == "scene") and "scene" or "grid"
end

local function SceneIndex()
    local want = AltStableConfig and AltStableConfig.rosterScene
    for i, b in ipairs(SCENE_BACKDROPS) do
        if b.id == want then return i end
    end
    return 1
end

local function CurrentScene()
    return SCENE_BACKDROPS[SceneIndex()]
end

------------------------------------------------------------
-- Which cutout belongs to which character
------------------------------------------------------------

-- The converter names each file after the character it photographed, lowercased
-- with every run of non-alphanumerics collapsed to a dash. This has to agree
-- with Tools/RenderCutout/make-cutout.py EXACTLY or every portrait silently
-- falls back to a card, so it is one function with one test.
local function Slug(name)
    if type(name) ~= "string" then return nil end
    local s = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return (s ~= "") and s or nil
end

-- An entry only counts when it can actually be DRAWN. The renderer requires
-- entry.file, so a counter asking a weaker question would hide the "capture one
-- with /asrender" hint at exactly the moment every card is a fallback.
local function CutoutFor(char)
    local manifest = AltStableCutoutManifest
    if type(manifest) ~= "table" or type(char) ~= "table" then return nil end
    local slug = Slug(char.name)
    local entry = slug and manifest[slug] or nil
    if type(entry) ~= "table" or type(entry.file) ~= "string" or entry.file == "" then
        return nil
    end
    return entry
end

-- The image sits in the TOP-LEFT of a power-of-two canvas, so the rest of the
-- texture is empty padding that must be cropped off rather than drawn.
local function TexCoordsFor(entry)
    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    local tw = tonumber(entry and entry.texw) or 0
    local th = tonumber(entry and entry.texh) or 0
    if w <= 0 or h <= 0 or tw <= 0 or th <= 0 then return 0, 1, 0, 1 end
    return 0, math.min(1, w / tw), 0, math.min(1, h / th)
end

-- Scaled to a common height. Right for the GRID, where each card is its own
-- box and a figure filling it reads best.
local function FigureSize(entry, targetH)
    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    if w <= 0 or h <= 0 then return targetH, targetH end
    return targetH * (w / h), targetH
end

-- How tall each race is, relative to a human male.
--
-- NOT measured from the cutouts, and this is the thing that took two attempts
-- to understand. The render stage uses DressUpModel:SetUnit(), which FRAMES the
-- model to fill the frame - so a gnome and a night elf are both drawn at the
-- same size before any screenshot exists. Across nine captured characters the
-- recorded pixel heights spanned 0.609 to 0.649, a 6.6% spread, for races that
-- genuinely differ by about 40%. The earlier nativeH work assumed supersampling
-- had destroyed the difference and recovered the pre-supersample size; the
-- difference was never in the image to begin with.
--
-- The addon already knows the race and gender of every character it has
-- scanned, so use that. It is exact for anyone in the roster, needs no capture,
-- and cannot drift with resolution or UI scale.
--
-- Values are approximations of the in-game model heights, good enough that a
-- gnome reads as a gnome beside a tauren. Keys are the fileName from UnitRace
-- (Scanner writes it to char.race), which is what makes Skyborne one key.
local RACE_HEIGHT = {
    Gnome     = { male = 0.60, female = 0.58 },
    Dwarf     = { male = 0.72, female = 0.69 },
    Scourge   = { male = 0.96, female = 0.90 },   -- Undead
    Human     = { male = 1.00, female = 0.94 },
    Orc       = { male = 1.06, female = 0.97 },
    Troll     = { male = 1.17, female = 1.06 },
    NightElf  = { male = 1.18, female = 1.10 },
    Tauren    = { male = 1.35, female = 1.24 },
    -- Forever's own race, and the only entry here that is a guess: it reads as
    -- elven in game, so it is sat beside the night elves until someone measures
    -- it properly. Being slightly wrong for one race is a different order of
    -- problem from every race being identical.
    Skyborne  = { male = 1.15, female = 1.08 },
}
local DEFAULT_HEIGHT = 1.00   -- an unknown race stands human-sized, not invisible

local function RaceHeight(char)
    local entry = RACE_HEIGHT[char and char.race or ""]
    if not entry then return DEFAULT_HEIGHT end
    local female = (char.gender == "Female") or (char.sexID == 1)
    return female and entry.female or entry.male
end

-- Scaled to a common SCALE, which is what a scene needs: everyone standing on
-- one floor at their real relative heights.
--
-- The cutout still supplies the ASPECT - a tauren is broad as well as tall, and
-- that much the image does know - but the height comes from the race.
local function RelativeFigureSize(entry, height, tallest, maxH)
    height = tonumber(height) or DEFAULT_HEIGHT
    tallest = tonumber(tallest) or 0

    -- The height first, and unconditionally. A cutout with no usable content
    -- box used to return maxH here and skip the race entirely, so one bad
    -- sidecar stood a gnome at the tallest race's height - this fix, undone for
    -- that one figure.
    local drawnH = (tallest > 0) and (maxH * (height / tallest)) or maxH

    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    if w <= 0 or h <= 0 then
        return drawnH, drawnH    -- no aspect to keep, so square
    end
    return drawnH * (w / h), drawnH
end

-- The tallest race in the cast, so everyone is measured against someone who is
-- actually present: five gnomes should fill the frame, not huddle at ankle
-- height under an absent tauren.
local function TallestRace(chars)
    local tallest = 0
    for _, c in ipairs(chars) do
        local hgt = RaceHeight(c)
        if hgt > tallest then tallest = hgt end
    end
    return tallest > 0 and tallest or DEFAULT_HEIGHT
end

-- Cover-crop a backdrop to the panel: fill it completely, keep the aspect, drop
-- the overflow, and never show the padding. The sides go evenly; the vertical
-- overflow comes off the TOP only, for the reason given below.
--
-- Pure arithmetic and returned rather than applied, so the thing most likely to
-- be subtly wrong - the v remap by h/texh - is testable without a frame. Get it
-- wrong and a black band appears along the bottom, which reads as "the art is
-- broken" rather than "the texture coordinates are".
local function BackdropTexCoords(panelW, panelH, entry)
    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    local texh = tonumber(entry and entry.texh) or 0
    if w <= 0 or h <= 0 or texh <= 0 or (panelW or 0) <= 0 or (panelH or 0) <= 0 then
        return 0, 1, 0, 1
    end

    -- The content occupies v in [0, h/texh]; u is the whole width.
    local vMax = h / texh

    -- Which fraction of the CONTENT is visible, cropping the longer axis.
    local panelAspect = panelW / panelH
    local imageAspect = w / h
    local uFrac, vFrac = 1, 1
    if panelAspect > imageAspect then
        vFrac = imageAspect / panelAspect      -- panel is wider: crop top/bottom
    else
        uFrac = panelAspect / imageAspect      -- panel is taller: crop the sides
    end

    -- Horizontally, crop evenly: the fire is dead centre, so an even crop keeps
    -- it and a biased one would slide it off the side of a narrow panel.
    local uPad = (1 - uFrac) / 2

    -- VERTICALLY, crop the sky. These backdrops are bottom-weighted by design -
    -- the floor the cast stands on and the fire they stand around are both in
    -- the bottom sixth - and an even crop takes half of that away. On a wide
    -- panel it takes ALL of it: the fire ends up outside the visible texture
    -- entirely, which is the "you don't see the fire" half of the report. Sky
    -- is the part nobody misses.
    return uPad, 1 - uPad, vMax * (1 - vFrac), vMax
end

-- Where the fire ended up on screen once the backdrop was cover-cropped.
--
-- Returns its centre x and the y of its BASE, both in panel pixels measured the
-- way the cards are anchored: x from the left, y from the bottom. The crop
-- moves the fire - a tall panel cuts the sides, a wide one cuts sky off the top
-- and so raises everything left - which is why this reads the same texture
-- coordinates the backdrop is drawn with rather than the art spec directly.
local function FireAnchor(panelW, panelH, entry)
    local l, r, t, b = BackdropTexCoords(panelW, panelH, entry)
    local vMax = (tonumber(entry and entry.h) or 0) / (tonumber(entry and entry.texh) or 0)
    if not (vMax > 0) then vMax = 1 end

    local fx = tonumber(entry and entry.fireX) or FIRE_X
    local fy = tonumber(entry and entry.fireBaseY) or FIRE_BASE_Y

    -- Where the fire sits inside the VISIBLE part of the texture, 0..1.
    local u = (r > l) and ((fx - l) / (r - l)) or 0.5
    local v = (b > t) and ((fy * vMax - t) / (b - t)) or fy

    -- Cropped out of frame. Fall back to the middle of the floor rather than
    -- sending the whole cast off-screen after a fire nobody can see.
    if u < 0 or u > 1 then u = 0.5 end
    if v < 0 or v > 1 then v = fy end

    return panelW * u, panelH * (1 - v)
end

-- Where each figure stands. Returns one spot per character - x, the ground y it
-- stands on, and the scale it is drawn at - plus the height of the tallest
-- figure and the width one figure may occupy.
--
-- Two things the even-spacing version got wrong. It divided the panel into
-- equal slots, and the middle slot is where the fire is; and it put everyone on
-- one flat line, which reads as a police line-up rather than a camp. Here the
-- cast is split either side of the fire, and each figure is placed on an
-- ellipse around it: screen offset d from the fire gives depth sqrt(1 - d^2),
-- which lifts and shrinks whoever is standing at the back of the ring.
local function SceneLayout(panelW, panelH, count, entry)
    local spots = {}
    if count <= 0 or (panelW or 0) <= 0 or (panelH or 0) <= 0 then return spots, 0, 0 end

    local fireX, groundY = FireAnchor(panelW, panelH, entry)

    -- Tall enough to read, never taller than the room above the ground line. A
    -- flat fraction of the panel overflows the top on any panel whose crop
    -- pushes the fire high, and a figure running off the top of the scene looks
    -- worse than a slightly short one.
    local figureH = math.min(panelH * SCENE_FIGURE_H,
                             (panelH - groundY) * 0.92)
    local clear = panelW * FIRE_CLEARANCE

    local leftEdge  = math.max(0, math.min(panelW, fireX - clear / 2))
    local rightEdge = math.max(leftEdge, math.min(panelW, fireX + clear / 2))
    local leftRoom, rightRoom = leftEdge, panelW - rightEdge

    -- Share them out by how much room each side has, so an off-centre crop does
    -- not crowd one half while the other stands empty.
    local total = leftRoom + rightRoom
    local nLeft = (total > 0) and math.floor(count * (leftRoom / total) + 0.5)
                              or math.floor(count / 2)
    nLeft = math.max(0, math.min(count, nLeft))
    if leftRoom <= 0 then nLeft = 0 end
    if rightRoom <= 0 then nLeft = count end
    local nRight = count - nLeft

    -- ONE spacing for everybody, measured outward from the fire.
    --
    -- Each side used to divide its own half independently, which looks even
    -- only when the counts match. With five around a centred fire it is two and
    -- three, so the pair spread out across their half while the trio crowded
    -- into theirs - visibly lopsided even though the arithmetic on each side
    -- was right. A common step makes the gaps equal everywhere and keeps the
    -- two innermost symmetric about the flames.
    --
    -- The step is whatever the tighter side can afford: the side with more
    -- figures runs out of room first, and matching it is what keeps the
    -- outermost inside the frame.
    -- Dividing by the COUNT, not count - 0.5, is what keeps the outermost
    -- figure on the panel. Every figure is scaled to fit within one step (see
    -- FitScale), so the outermost reaches half a step past its own centre;
    -- leaving room only up to that centre clips it against the frame.
    local edge = panelW * SCENE_EDGE
    local step
    if nLeft > 0 then
        step = math.max(0, (leftEdge - edge) / nLeft)
    end
    if nRight > 0 then
        local rs = math.max(0, (panelW - edge - rightEdge) / nRight)
        step = (step and math.min(step, rs)) or rs
    end
    step = step or 0

    local xs = {}
    for i = 1, nLeft do
        xs[#xs + 1] = leftEdge - (i - 0.5) * step
    end
    for i = 1, nRight do
        xs[#xs + 1] = rightEdge + (i - 0.5) * step
    end
    table.sort(xs)

    local half = panelW / 2
    for i = 1, #xs do
        local d = math.min(1, math.abs(xs[i] - fireX) / half)
        local depth = math.sqrt(math.max(0, 1 - d * d))
        spots[i] = {
            x     = xs[i],
            y     = groundY + panelH * SCENE_ARC * depth,
            scale = 1 - SCENE_DEPTH * depth,
            -- Who overlaps whom. Nearest the camera wins, which is the one
            -- standing furthest from the fire's screen x. Left to roster order
            -- the ring overlaps arbitrarily, and a figure at the back of the
            -- camp is drawn over the top of one at the front.
            level = math.floor((1 - depth) * 10 + 0.5),
        }
    end

    -- The width one figure may occupy is now simply the spacing between them.
    return spots, figureH, (step > 0) and step or (panelW / count)
end

-- The figure is anchored ABOVE the name block, so the space available to it is
-- the card MINUS that block - not a fraction of the whole card. Taking a
-- fraction of the whole made the figure taller than its own card at any height
-- below ~146px, and the overflow ran up into the row above.
--
-- A named function rather than a line inside the renderer, so a test can assert
-- the real arithmetic instead of restating it: a test that recomputes the
-- formula agrees with itself no matter what the source does.
local function FigureHeightFor(cardH)
    return math.max(24, ((cardH or 0) - NAME_H - 8) * FIGURE_RATIO)
end

-- How many columns fit, how big each card is, and how many rows that needs.
-- Pure arithmetic, so it is testable without a frame: the layout bug that put
-- cards over the sidebar was invisible to every assertion until this existed.
local function GridFor(panelW, panelH, count)
    if count <= 0 then return 0, 0, 0, 0 end
    panelW = math.max(panelW or 0, MIN_CARD_W + PAD_X * 2)
    panelH = math.max(panelH or 0, 120)

    local usableW = panelW - PAD_X * 2
    local cols = math.max(1, math.floor((usableW + CARD_GAP) / (MIN_CARD_W + CARD_GAP)))
    cols = math.min(cols, count)
    local rows = math.ceil(count / cols)

    local cardW = math.min(MAX_CARD_W, (usableW - CARD_GAP * (cols - 1)) / cols)
    local usableH = panelH - PAD_Y * 2 - 18          -- 18: the hint line

    -- Drop rows rather than squash cards. Clamping the height up to a minimum
    -- breaks the very division that made the rows fit, and the surplus draws
    -- OUTSIDE the panel: WoW frames do not clip their children, so the last row
    -- lands on whatever is below it.
    local cardH = (usableH - CARD_GAP * (rows - 1)) / rows
    while rows > 1 and cardH < MIN_CARD_H do
        rows = rows - 1
        cardH = (usableH - CARD_GAP * (rows - 1)) / rows
    end
    return cols, rows, cardW, math.max(MIN_CARD_H, cardH)
end

------------------------------------------------------------
-- Who to show
------------------------------------------------------------

local function CharacterStore()
    if type(AltStableDB) ~= "table" then return {} end
    return AltStableDB
end

-- Everyone the addon knows about and is willing to show: favourites first
-- (#66), then highest level.
--
-- Deliberately UNCAPPED. MAX_CARDS is a grid concern - it is how many cards the
-- grid has to draw with - and applying it here made it a selection rule for the
-- scene too: SceneCast ranks by item level, but only among whatever survived a
-- cap sorted by level then NAME. With 25 level-60 alts the best-geared one
-- could be cut before the scene ever saw it, purely for sorting late
-- alphabetically, and a roster whose portraits all sat past the cap produced an
-- empty camp.
local function AllCharacters(includeHidden)
    local out = {}
    for _, c in next, CharacterStore() do
        if type(c) == "table" and c.name then
            -- Hidden characters stay hidden here too (#21): one setting, every
            -- view, or "hidden" means nothing.
            --
            -- The sheet's "show hidden" toggle (#69) reaches the card GRID,
            -- which is a management view - you right-click a card to unhide it,
            -- exactly as you would a row. It deliberately does NOT reach the
            -- scene: the camp is a showcase, and a dimmed figure standing in a
            -- diorama says nothing to anybody. CharactersFor already had to
            -- tell those two views apart, which is why this is a parameter and
            -- not a read of the config right here.
            local hidden = AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(c.guid)
            if not hidden or includeHidden then
                out[#out + 1] = c
            end
        end
    end
    -- Favourites first (#66), then level, then name. The grid and the scene
    -- share this one list, so pinning a character moves it in both.
    local byLevel = function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la > lb end
        return (a.name or "") < (b.name or "")
    end
    table.sort(out, AltStable.FavouriteFirst and AltStable.FavouriteFirst(byLevel) or byLevel)
    return out
end

-- The grid's page: as many as it has cards for.
local function PickCharacters(limit, includeHidden)
    local out = AllCharacters(includeHidden)
    while #out > (limit or MAX_CARDS) do table.remove(out) end
    return out
end

-- Which characters a view is given. Named, and chosen here rather than inline
-- in Refresh, because this IS the bug that was found: the scene was handed the
-- grid's page, so a cap meant for "how many cards exist" quietly became a rule
-- about who is eligible for the camp. Inline, the wiring was untestable - the
-- composition could be asserted while the call site kept doing the wrong thing.
local function CharactersFor(view)
    -- The scene is never given a hidden character, whatever the toggle says.
    if view == "scene" then return AllCharacters(false) end
    return PickCharacters(MAX_CARDS,
                          AltStable.IsShowingHidden and AltStable.IsShowingHidden() or false)
end


------------------------------------------------------------
-- The character detail view (#91)
--
-- A DRILL-DOWN, not a third pane. AltTracker gave the character list, the
-- paper doll and the stats card a column each, permanently. This panel spends
-- its width on portraits instead, which is the point of the view - so
-- selecting a character replaces the grid or the camp rather than squeezing in
-- beside it, and a Back button returns you to whichever you came from.
--
-- The figure is the CUTOUT. AltTracker rendered the character live in its
-- middle pane; we cannot - offline characters cannot be textured on this
-- client, which is the measured constraint the whole capture pipeline exists
-- to work around. A cutout is already a full-body figure at capture
-- resolution, so it is the paper doll, and the class plate stands in when
-- there is not one.
------------------------------------------------------------

-- Through the adapter, like every other client call in this addon.
local GetItemIconByID = AltStable.API and AltStable.API.GetItemIconByID

local STAT_ROW_H, STAT_SECTION_GAP = 15, 10

-- Ported from AltTracker's CHAR_STAT_GROUPS, minus two.
--
-- Haste and Resilience are gone rather than scanned as zero: there is no haste
-- rating before TBC and resilience is a TBC PvP stat, so a row reading "0%"
-- would be reporting a real value for something the game does not have. The
-- scanner does not collect them either, for the same reason.
local CHAR_STAT_GROUPS = {
    { header = "Status", defs = {
        { label = "Gold",        key = "money",       kind = "money",    allowZero = true },
        { label = "Rested XP",   key = "restPercent", kind = "percent0", allowZero = true },
        { label = "XP Progress", key = "xpPercent",   kind = "percent0", allowZero = true },
        { label = "Last Online", key = "lastUpdate",  kind = "lastseen", allowZero = true },
    } },
    { header = "Resources", defs = {
        { label = "Health", key = "stat_hp",    kind = "int" },
        { label = "Mana",   key = "stat_mana",  kind = "int" },
        { label = "Armor",  key = "stat_armor", kind = "int" },
    } },
    { header = "Attributes", defs = {
        { label = "Strength",  key = "stat_str", kind = "int" },
        { label = "Agility",   key = "stat_agi", kind = "int" },
        { label = "Stamina",   key = "stat_sta", kind = "int" },
        { label = "Intellect", key = "stat_int", kind = "int" },
        { label = "Spirit",    key = "stat_spi", kind = "int" },
    } },
    { header = "Combat", defs = {
        { label = "Attack Power", key = "stat_ap",      kind = "int" },
        { label = "Spell Power",  key = "stat_sp",      kind = "int" },
        { label = "Melee Crit",   key = "stat_crit",    kind = "percent2" },
        { label = "Hit Chance",   key = "stat_hitpct",  kind = "percent2" },
        { label = "Defense",      key = "stat_defense", kind = "int" },
    } },
}

-- The equipped slots, in the order a paper doll reads them: down the left,
-- down the right, weapons along the bottom. slotID is the client's, kept
-- because it is what an item tooltip needs.
local GEAR_SLOTS = {
    { key = "head",     label = "Head",      id = 1,  side = "left" },
    { key = "neck",     label = "Neck",      id = 2,  side = "left" },
    { key = "shoulder", label = "Shoulder",  id = 3,  side = "left" },
    { key = "back",     label = "Back",      id = 15, side = "left" },
    { key = "chest",    label = "Chest",     id = 5,  side = "left" },
    { key = "wrist",    label = "Wrist",     id = 9,  side = "left" },
    { key = "hands",    label = "Hands",     id = 10, side = "right" },
    { key = "waist",    label = "Waist",     id = 6,  side = "right" },
    { key = "legs",     label = "Legs",      id = 7,  side = "right" },
    { key = "feet",     label = "Feet",      id = 8,  side = "right" },
    { key = "ring1",    label = "Ring 1",    id = 11, side = "right" },
    { key = "ring2",    label = "Ring 2",    id = 12, side = "right" },
    { key = "trinket1", label = "Trinket 1", id = 13, side = "bottom" },
    { key = "trinket2", label = "Trinket 2", id = 14, side = "bottom" },
    { key = "mainhand", label = "Main Hand", id = 16, side = "bottom" },
    { key = "offhand",  label = "Off Hand",  id = 17, side = "bottom" },
    { key = "ranged",   label = "Ranged",    id = 18, side = "bottom" },
}

-- Ported verbatim. `allowZero` exists because 0 gold and 0% rested are facts,
-- while 0 spell power on a warrior is an absence - the difference decides
-- whether a row is drawn at all.
local function FormatStatValue(char, def)
    if not char then return "-" end
    local value = char[def.key]
    if value == nil then return "-" end
    if def.kind == "money" then
        return AltStable.FormatMoney and AltStable.FormatMoney(value) or tostring(value)
    elseif def.kind == "int" then
        return tostring(value)
    elseif def.kind == "percent0" then
        return string.format("%d%%", math.floor(tonumber(value) or 0))
    elseif def.kind == "percent2" then
        return string.format("%.2f%%", tonumber(value) or 0)
    elseif def.kind == "lastseen" then
        return AltStable.FormatLastSeen and AltStable.FormatLastSeen(value, false)
            or tostring(value)
    end
    return tostring(value)
end

-- Whether a row is worth drawing. A character with no spell power has no
-- stat_sp at all, and a row of "-" for every stat the class does not use is
-- noise; but zero gold is a real answer and has to survive.
local function HasStatValue(char, def)
    if not char then return false end
    local value = char[def.key]
    if value == nil then return false end
    if def.allowZero then return true end
    return (tonumber(value) or 0) ~= 0
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

-- Matches HIDDEN_ROW_ALPHA in RowRenderer.lua. Not shared through a constant:
-- the plugin is a separate addon and may load without the main one's internals
-- available, and a hardcoded 0.45 in two files is honest about that.
local HIDDEN_CARD_ALPHA = 0.45

-- Who a card is currently about. Called by BOTH renderers, which is the point.
--
-- There are two of them - the grid and the scene - drawing from ONE pool of
-- cards, and the scene originally set only `charGuid`. So a card that held
-- somebody in the grid kept their whole record when the scene redrew it, and a
-- right-click on a figure opened a menu titled with the wrong character and
-- offered to forget them. Three properties that must move together, in one
-- function, so a third renderer cannot take two of them.
local function SetCardSubject(card, char)
    card.char     = char
    card.charGuid = char and char.guid or nil
    local dim = char and AltStable.IsCharacterHidden
        and AltStable.IsCharacterHidden(char.guid) or false
    card:SetAlpha(dim and HIDDEN_CARD_ALPHA or 1)
end

local function BuildCard(parent, index)
    local card = CreateFrame("Button", nil, parent)

    card.highlight = card:CreateTexture(nil, "BACKGROUND")
    card.highlight:SetAllPoints()
    card.highlight:SetColorTexture(1, 1, 1, 0.06)
    card.highlight:Hide()

    -- The figure: a cutout when one exists.
    card.figure = card:CreateTexture(nil, "ARTWORK")
    card.figure:SetPoint("BOTTOM", 0, NAME_H + 4)

    -- The fallback: a class-coloured plate with the class icon on it. Built
    -- once, shown whenever there is no picture, which for most users is most
    -- characters.
    card.plate = card:CreateTexture(nil, "ARTWORK")
    card.plate:SetPoint("BOTTOM", 0, NAME_H + 4)

    card.icon = card:CreateTexture(nil, "OVERLAY")
    card.icon:SetSize(48, 48)
    card.icon:SetPoint("CENTER", card.plate, "CENTER", 0, 0)

    -- Name and level on SEPARATE lines. Sharing one line truncates a Forever
    -- name to "Morphisto Ruskador ..." at any sensible card width, and the
    -- surname is the half that distinguishes two characters called Karuzo.
    card.label = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.label:SetPoint("BOTTOM", 0, 14)
    card.label:SetJustifyH("CENTER")
    card.label:SetWordWrap(false)

    card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.sub:SetPoint("BOTTOM", 0, 2)
    card.sub:SetJustifyH("CENTER")
    card.sub:SetTextColor(0.6, 0.6, 0.6)

    card:SetScript("OnEnter", function(self) self.highlight:Show() end)
    card:SetScript("OnLeave", function(self)
        if Roster.selected ~= self.charGuid then self.highlight:Hide() end
    end)
    -- Right-click needs asking for. A Button fires OnClick for the LEFT button
    -- only until RegisterForClicks says otherwise, so adding the branch below
    -- without this line gives a menu that never opens - and a test that calls
    -- the handler directly passes, because the handler is right. The missing
    -- registration is the bug.
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    card:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            -- The same menu the sheet row raises (#69), so the two views cannot
            -- offer different things.
            if self.char and AltStable.ShowCharacterMenu then
                AltStable.ShowCharacterMenu(self.char)
            end
            return
        end
        Roster.DrillDown(self.charGuid)
    end)
    card:Hide()
    return card
end

local function RenderCard(card, char, cardW, cardH)
    SetCardSubject(card, char)
    card:SetSize(cardW, cardH)
    -- The gap is fair game for text: a name that reaches a little into it reads
    -- better than one cut off mid-surname.
    card.label:SetWidth(cardW + CARD_GAP)
    card.sub:SetWidth(cardW + CARD_GAP)

    local figureH = FigureHeightFor(cardH)
    card.plate:SetSize(math.max(24, cardW - 30), figureH * 0.82)
    card.icon:SetSize(math.min(48, cardW * 0.32), math.min(48, cardW * 0.32))
    card.label:SetText(AltStable.ClassColor
        and (AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r")
        or (char.name or "?"))
    card.sub:SetText(("level %d"):format(char.level or 0))

    local entry = CutoutFor(char)
    if entry then
        local w, h = FigureSize(entry, figureH)
        -- A wide capture (a gnome, or a drawn bow) must not spill into its
        -- neighbours, so the height gives way rather than the column.
        if w > cardW then h = h * (cardW / w); w = cardW end
        card.figure:SetTexture(entry.file)
        card.figure:SetTexCoord(TexCoordsFor(entry))
        card.figure:SetSize(w, h)
        card.figure:Show()
        card.plate:Hide()
        card.icon:Hide()
    else
        card.figure:Hide()
        local r, g, b = 0.5, 0.5, 0.5
        if AltStable.GetClassRGB then r, g, b = AltStable.GetClassRGB(char.class) end
        card.plate:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, 0.85)
        card.plate:Show()
        -- The same icons the name column uses (RowRenderer's ClassIconText),
        -- by path rather than through a helper that does not exist.
        local cls = type(char.class) == "string" and char.class or ""
        cls = cls:sub(1, 1):upper() .. cls:sub(2):lower()
        if cls ~= "" then
            card.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. cls)
            card.icon:Show()
        else
            card.icon:Hide()
        end
    end

    card.highlight:SetShown(Roster.selected == char.guid)
    card:Show()
end

local function BuildPanel(mainFrame)
    if panel then return panel end

    -- Anchored past the SIDEBAR, like every other plugin panel. Anchored to the
    -- frame's own left edge instead, the cards are drawn over the navigation -
    -- which is exactly what the first build did.
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30

    panel = CreateFrame("Frame", nil, mainFrame)
    -- Stopping SHORT of the footer, which the panel used to cover.
    --
    -- The sheet's totals bar carries the "(N hidden)" toggle (#69), and that is
    -- the only control that lists hidden characters so one can be right-clicked
    -- and unhidden. Covering it here - and then hiding it in Activate, which is
    -- what covering it forced - meant the Roster was the one tab where you
    -- could hide a character from a card and then find no way back on that tab.
    -- Hiding is unconfirmed now, so "the way back is visible" is load-bearing
    -- rather than a nicety.
    local footerH = (AltStable.LAYOUT and AltStable.LAYOUT.FOOTER_HEIGHT) or 22
    panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, footerH + 2)
    panel:Hide()

    backdropTex = panel:CreateTexture(nil, "BACKGROUND")
    backdropTex:SetAllPoints()
    backdropTex:SetColorTexture(0.05, 0.05, 0.06, 1)

    hintText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintText:SetPoint("TOP", 0, -8)
    hintText:SetTextColor(0.6, 0.6, 0.6)
    hintText:SetJustifyH("CENTER")

    -- Grid <-> Scene, and the backdrop picker. The picker only appears in scene
    -- view, because fourteen arrows over an empty grid are just clutter.
    viewBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    viewBtn:SetSize(VIEW_BTN_W, BAR_H)
    viewBtn:SetPoint("TOPRIGHT", -8, -BAR_TOP)
    viewBtn:SetText("Scene")
    viewBtn:SetScript("OnClick", function()
        AltStableConfig = AltStableConfig or {}
        AltStable.SetConfigValue("rosterView", View() == "scene" and "grid" or "scene")
        Roster.Refresh()
    end)

    sceneBar = CreateFrame("Frame", nil, panel)
    sceneBar:SetPoint("TOPLEFT", 8, -BAR_TOP)
    sceneBar:SetSize(SCENE_BAR_W, BAR_H)
    sceneBar:Hide()

    local prev = CreateFrame("Button", nil, sceneBar, "UIPanelButtonTemplate")
    prev:SetSize(22, 20); prev:SetText("<"); prev:SetPoint("LEFT", 0, 0)
    local next_ = CreateFrame("Button", nil, sceneBar, "UIPanelButtonTemplate")
    next_:SetSize(22, 20); next_:SetText(">"); next_:SetPoint("LEFT", 200, 0)

    sceneLabel = sceneBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sceneLabel:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    sceneLabel:SetPoint("RIGHT", next_, "LEFT", -6, 0)
    sceneLabel:SetJustifyH("CENTER")

    local function Step(delta)
        local i = SceneIndex() + delta
        if i < 1 then i = #SCENE_BACKDROPS end
        if i > #SCENE_BACKDROPS then i = 1 end
        AltStable.SetConfigValue("rosterScene", SCENE_BACKDROPS[i].id)
        Roster.Refresh()
    end
    prev:SetScript("OnClick", function() Step(-1) end)
    next_:SetScript("OnClick", function() Step(1) end)

    for i = 1, MAX_CARDS do
        Roster.cards[i] = BuildCard(panel, i)
    end
    return panel
end

-- Every figure's drawn size, before the cast-wide fit below.
--
-- A named function rather than a loop inside the renderer, because the thing
-- that goes wrong here is WHICH height each character is given - pass the same
-- one to everybody and the races silently level out again, which is the bug
-- this replaced. Inline, a test could check RelativeFigureSize and RaceHeight
-- agree with each other while the renderer quietly used neither.
local function MeasureCast(cast, cutoutFor, spots, tallest, figureH)
    local sizes = {}
    for i, char in ipairs(cast) do
        local cut = cutoutFor(char)
        local spot = spots[i]
        if cut and spot then
            local w, h = RelativeFigureSize(cut, RaceHeight(char), tallest, figureH)
            sizes[i] = { w * spot.scale, h * spot.scale }
        else
            sizes[i] = { 0, 0 }
        end
    end
    return sizes
end

-- One scale factor for the WHOLE cast, so nobody overflows their slot.
--
-- The per-figure clamp this replaces did precisely what its own comment said it
-- avoided. "Narrow the slot, not the figure" described the intent; `w, h = w /
-- overflow, h / overflow` is a uniform downscale of that one figure, identical
-- in effect to the grid's clamp. It fired routinely - a wide capture is exactly
-- the short-and-stocky races - so the gnome RelativeFigureSize had just
-- carefully drawn at 63% of the elf's height got shortened again for being
-- wide, and the height discrepancy came straight back.
--
-- Scaling EVERYONE by the worst overflow keeps the relative heights intact,
-- which is the entire point of having measured them.
local function FitScale(sizes, slot)
    if not slot or slot <= 0 then return 1 end
    local worst = 1
    for _, wh in ipairs(sizes) do
        local w = tonumber(wh[1]) or 0
        if w > slot then
            local over = w / slot
            if over > worst then worst = over end
        end
    end
    return 1 / worst
end

-- Who stands around the fire: favourites first (#66), then level, then item
-- level, capped.
-- Only characters with a portrait, because a class card pasted into a campsite
-- looks like a mistake rather than a placeholder.
local function SceneCast(chars, cutoutFor, limit)
    local out = {}
    for _, c in ipairs(chars) do
        if cutoutFor(c) then out[#out + 1] = c end
    end

    -- Favourites are the cast (#66). The five you want around the fire are the
    -- five you play, which is what a favourite already means - so this needs no
    -- second flag, and the hint stops apologising for guessing.
    --
    -- Top-by-level stays as the default, for a roster with no favourites yet,
    -- and as the filler when there are fewer favourites than seats. Nobody
    -- should have to mark five characters before the scene works at all.
    local byRank = function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la > lb end
        local ia, ib = a.ilvl or 0, b.ilvl or 0
        if ia ~= ib then return ia > ib end
        return (a.name or "") < (b.name or "")
    end
    table.sort(out, AltStable.FavouriteFirst and AltStable.FavouriteFirst(byRank) or byRank)

    while #out > (limit or SCENE_CAST) do table.remove(out) end
    return out
end

-- How many favourites are in a list.
--
-- Called on the CAST, never on the roster. Only characters with a portrait can
-- be seated, so a favourite without one is pinned and absent - and counting the
-- roster made the hint claim "your favourites first" while the scene was in
-- fact five pure level picks.
local function FavouritesAmong(chars)
    local n = 0
    for _, c in ipairs(chars) do
        if AltStable.IsCharacterFavourite and AltStable.IsCharacterFavourite(c.guid) then
            n = n + 1
        end
    end
    return n
end

-- One backdrop, everyone standing on it.
local function RenderScene(chars)
    local entry = CurrentScene()
    local pw, ph = panel:GetWidth(), panel:GetHeight()

    backdropTex:SetTexture(entry.file)
    backdropTex:SetTexCoord(BackdropTexCoords(pw, ph, entry))
    backdropTex:SetVertexColor(1, 1, 1, 1)

    if sceneLabel then sceneLabel:SetText(entry.label) end

    local cast = SceneCast(chars, CutoutFor, SCENE_CAST)
    local spots, figureH, slot = SceneLayout(pw, ph, #cast, entry)
    local tallest = TallestRace(cast)

    local sizes = MeasureCast(cast, CutoutFor, spots, tallest, figureH)
    local fit = FitScale(sizes, slot)
    local withArt = 0

    for i, card in ipairs(Roster.cards) do
        local char = cast[i]
        local cut = char and CutoutFor(char)
        local spot = spots[i]
        if char and cut and spot then
            withArt = withArt + 1
            local w, h = sizes[i][1] * fit, sizes[i][2] * fit

            card:SetFrameLevel(panel:GetFrameLevel() + 1 + spot.level)

            card:ClearAllPoints()
            card:SetPoint("BOTTOM", panel, "BOTTOMLEFT", spot.x, spot.y - NAME_H - 4)
            card:SetSize(math.max(slot, w), h + NAME_H + 4)

            card.plate:Hide()
            card.icon:Hide()
            card.figure:SetTexture(cut.file)
            card.figure:SetTexCoord(TexCoordsFor(cut))
            card.figure:SetSize(w, h)
            card.figure:Show()

            -- The name sizes to ITSELF, not to the slot.
            --
            -- Constraining it to the slot and disabling word wrap means the
            -- client truncates: tightening the spacing turned "Morphisto
            -- Ruskador" into "Morphisto Ruska...". A name is the one thing on
            -- this card that has to be readable, and Forever's surnames make
            -- them long. Width 0 lets the string be as wide as its text, so it
            -- may reach a little over a neighbour's empty floor - which costs
            -- nothing, because the figures are what occupy the slots.
            card.label:SetWidth(0)
            card.label:SetText(AltStable.ClassColor
                and (AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r")
                or (char.name or "?"))
            card.sub:SetWidth(0)
            card.sub:SetText(("level %d"):format(char.level or 0))
            card.highlight:SetShown(Roster.selected == char.guid)
            SetCardSubject(card, char)
            card:Show()
        else
            card:Hide()
        end
    end

    -- The third value is how many of the SEATED characters were chosen rather
    -- than guessed, which is the only honest basis for the hint below.
    return withArt, #chars, FavouritesAmong(cast)
end

-- Where the hint goes, and how wide it may be.
--
-- The grid has a clear strip along the top and the hint can sit in it, centred.
-- Scene mode does not: the backdrop picker takes the left 240px of that strip
-- and the view toggle the right 64, and a centred string long enough to say
-- "showing 3 of 12 - highest level first; the grid shows them all" runs
-- straight through both. Dropping below the bar is better than squeezing the
-- text into the 200px gap between them.
--
-- Returned rather than applied, because a collision that only appears at
-- certain panel widths is not something anyone re-checks by eye.
local function HintLayout(panelW, sceneView)
    local w = math.max(0, (tonumber(panelW) or 0) - 2 * PAD_X)
    if sceneView then
        return -(BAR_TOP + BAR_H + 4), w    -- clear of the picker row
    end
    return -8, w
end

local function ApplyHintLayout(panelW, sceneView)
    if not hintText then return end
    local y, w = HintLayout(panelW, sceneView)
    hintText:ClearAllPoints()
    hintText:SetPoint("TOP", 0, y)
    hintText:SetWidth(w)
end


------------------------------------------------------------
-- The enchant audit (#91)
--
-- AltTracker audited gems, sockets, meta-gems AND enchants across three files
-- and 842 lines. Sockets were introduced in TBC and do not exist here, so all
-- but the enchants is dead on this client - and with the gems went the two
-- settings that configured them, `minGemQuality` and `auditMinLevel`, which
-- Config.lua now clears from profiles that still carry them.
--
-- What is left needs no threshold: a slot either has an enchant or it does
-- not. So there is no config, and 842 lines becomes this.
--
-- The enchant comes out of the item LINK we already store. A link is
-- `item:<id>:<enchant>:...` and the field is EMPTY on an unenchanted item -
-- measured against real stored links on 1.60.1.70009:
--
--     |cnIQ1:|Hitem:36::::::::1:1489::75:::::::|h[Worn Mace]|h|r
--                    ^ empty: no enchant
--
-- so nothing new has to be scanned.
------------------------------------------------------------

-- Which slots take an enchant.
--
-- REASONED, NOT MEASURED, and the reason matters because an earlier version of
-- this comment was wrong. Vanilla DOES have head and leg enchantments - the
-- Dire Maul librams and arcanums are permanent and occupy the link's enchant
-- field - and Engineering scopes are permanent enchants on the ranged slot.
-- They are omitted anyway, deliberately: almost nobody has them, so including
-- them would report a finding on nearly every character for something most
-- players never intend to do. A false finding is the failure mode here.
--
-- Shoulders, rings, neck and trinkets genuinely take none.
--
-- If a finding appears on a slot you did not expect, THIS TABLE is the single
-- thing to correct.
local ENCHANTABLE_SLOTS = {
    chest    = true,
    back     = true,
    wrist    = true,
    hands    = true,
    feet     = true,
    mainhand = true,
    offhand  = true,   -- weapons and shields, but not frills; see EnchantableHere
}

-- Below this, a bare slot is not a finding.
--
-- AltTracker had `auditMinLevel` for exactly this and it was removed with the
-- gem settings - which was a mistake, because it was a LEVEL gate and the
-- argument for dropping the others was that enchants need no QUALITY
-- threshold. Two different settings. A level 14 alt in quest greens would
-- otherwise get six amber rows telling it to enchant gear it will replace this
-- afternoon.
--
-- Not a setting any more: the level cap is the only threshold worth having,
-- and it is a question the client can answer.
local function AuditFloor()
    return (AltStable.API and AltStable.API.LevelCap and AltStable.API.LevelCap()) or 60
end

-- The enchant on a slot, from the PACKED field rather than the item link.
--
-- gearmod_<slot> is "ench:sockets:g1:g2:g3" and IS SYNCED - the scanner marks
-- it so, and test_comm asserts it must ride the wire. gearlink_ is stripped at
-- the sync boundary as too large, which an earlier version of this read: every
-- peer-synced character came out as a wall of "cannot read the item", and the
-- PR calling that a rare case had it exactly backwards. It was every remote
-- character, always, by design.
--
-- Returns nil for "no enchant", false for "cannot tell", a number otherwise.
local function EnchantFromMod(packed)
    -- No separate empty-string case: the pattern below fails on "" anyway, and
    -- a branch that can never be the one that catches something is a branch no
    -- test can distinguish.
    if type(packed) ~= "string" then return false end
    local ench = packed:match("^(%-?%d+):")
    if not ench then return false end
    -- tonumber, not a string compare. "00" and "-0" are both zero and both
    -- read as enchanted under `ench == "0"`, and Classic-era links were
    -- historically written with padded zero fields.
    local n = tonumber(ench)
    if not n then return false end
    if n == 0 then return nil end
    return n
end

-- Whether THIS character's slot can take one.
--
-- Offhand is the awkward case, and the discriminator is EXCLUSION rather than
-- a whitelist: a shield takes an enchant and so does an off-hand WEAPON, while
-- a held-in-off-hand frill takes none. Whitelisting shields dropped every
-- dual-wielder's off-hand silently - one of the most commonly forgotten
-- enchants there is, so it dropped the highest-value case this exists for.
--
-- Compared against the equip-location TOKEN, which is locale-independent. The
-- item subtype is the localised display string - "Shields" on enUS, "Schilde"
-- on deDE - so a comparison against it would never fire outside English.
--
-- The token is local-only, so for a peer-synced character it is absent and the
-- answer is "cannot tell" rather than a guess in either direction.
local function EnchantableHere(char, slotKey)
    if not ENCHANTABLE_SLOTS[slotKey] then return false end
    if slotKey ~= "offhand" then return true end
    local loc = char["gearloc_offhand"]
    if type(loc) ~= "string" or loc == "" then return nil end   -- cannot tell
    return loc ~= "INVTYPE_HOLDABLE"
end

-- The findings, worst first. Returns a list of { slot, label, issue, rank }
-- and a reason string when the character was not audited at all.
--
-- An EMPTY slot is not a finding: it is already obvious on the paper doll
-- beside this, and "no enchant" for a slot with nothing in it would bury the
-- real ones.
-- Counted, so a refresh that computes the audit and discards it is visible to
-- a test. Refresh runs on every sync and Char is the tab you always land on,
-- so the wasted pass was work on a timer - and "it was computed pointlessly"
-- is otherwise indistinguishable from "it was not".
local auditCalls = 0

local function AuditCharacter(char)
    auditCalls = auditCalls + 1
    local out = {}
    if type(char) ~= "table" then return out, "no character" end

    local floor = AuditFloor()
    if (tonumber(char.level) or 0) < floor then
        return out, ("Not audited below level %d - enchants on levelling gear are not a finding.")
            :format(floor)
    end

    local occupied = 0
    for _, slot in ipairs(GEAR_SLOTS) do
        local id = tonumber(char["gearid_" .. slot.key]) or 0
        if id > 0 then
            occupied = occupied + 1
            local can = EnchantableHere(char, slot.key)
            if can == nil then
                -- Cannot tell whether it takes one. Reported, not dropped: an
                -- occupied slot silently vanishing from the audit is the same
                -- thing as calling it clean.
                out[#out + 1] = { slot = slot.key, label = slot.label,
                                  issue = "cannot tell - no item data", rank = 3 }
            elseif can then
                local ench = EnchantFromMod(char["gearmod_" .. slot.key])
                if ench == nil then
                    out[#out + 1] = { slot = slot.key, label = slot.label,
                                      issue = "no enchant", rank = 1 }
                elseif ench == false then
                    out[#out + 1] = { slot = slot.key, label = slot.label,
                                      issue = "cannot read the item", rank = 2 }
                end
            end
        end
    end

    -- "Nothing to check" is not "all clear". A character wearing nothing has
    -- no findings and no clean bill either, and collapsing the two is the same
    -- mistake as letting "cannot tell" read as "fine".
    if occupied == 0 then
        return out, "Nothing equipped to check."
    end

    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.label < b.label
    end)
    return out
end

------------------------------------------------------------
-- Building it
------------------------------------------------------------

local detail, detailRows, detailSlots, detailAudit

-- Only the tabs that have something behind them.
local DETAIL_TABS = {
    { id = "char",  label = "Char" },
    { id = "audit", label = "Audit" },
}

local DETAIL_FIGURE_W = 260
-- STEP leaves room for the item level drawn UNDER each icon; at 40 the
-- number sat against the next slot's border.
local SLOT_SIZE, SLOT_STEP = 34, 48

local function BuildSlot(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(SLOT_SIZE, SLOT_SIZE)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    -- Icons carry a border baked into the art; the standard trim is what every
    -- other icon in this addon uses.
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- The quality border, BEHIND the icon and one pixel larger on every side,
    -- so only that margin shows.
    --
    -- It was a solid colour texture on OVERLAY - which is not a border, it is
    -- a lid. Every equipped slot came out as a flat green or blue square with
    -- the item level under it and the icon completely hidden behind it, which
    -- is exactly what it looked like on screen.
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.border:SetColorTexture(0, 0, 0, 0)

    b.ilvl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.ilvl:SetPoint("TOP", b, "BOTTOM", 0, 1)
    b.ilvl:SetJustifyH("CENTER")

    b:SetScript("OnEnter", function(self)
        if not self.link or self.link == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- SetHyperlink rather than SetInventoryItem: the item belongs to a
        -- character who is not logged in, so there is no inventory slot to
        -- point at - only the link we stored when they were.
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, self.link)
        if not ok then
            GameTooltip:AddLine(self.itemName or self.slotLabel or "", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function BuildDetail()
    if detail then return detail end

    detail = CreateFrame("Frame", nil, panel)
    detail:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    detail:Hide()

    detail.bg = detail:CreateTexture(nil, "BACKGROUND")
    detail.bg:SetAllPoints()
    detail.bg:SetColorTexture(0.05, 0.05, 0.06, 1)

    local back = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
    back:SetSize(70, BAR_H)
    back:SetPoint("TOPLEFT", 8, -BAR_TOP)
    back:SetText("< Back")
    back:SetScript("OnClick", function() Roster.Back() end)
    detail.back = back

    detail.name = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    detail.name:SetPoint("TOPLEFT", back, "TOPRIGHT", 14, -2)
    detail.name:SetJustifyH("LEFT")

    detail.sub = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -2)
    detail.sub:SetJustifyH("LEFT")
    detail.sub:SetTextColor(0.6, 0.6, 0.6)

    detail.ilvl = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    detail.ilvl:SetPoint("TOPRIGHT", -12, -BAR_TOP)
    detail.ilvl:SetJustifyH("RIGHT")

    -- A box behind the figure, like the game's own character pane.
    --
    -- A cutout is a transparent PNG with nothing behind it, so on a flat panel
    -- it floats and anything near it reads as colliding with it. AltTracker
    -- put a scene back there and that is why its icons looked placed rather
    -- than dropped on top. This is the cheap version of the same idea: a
    -- darker inset with a border, so the figure is visibly INSIDE something.
    detail.stage = detail:CreateTexture(nil, "BACKGROUND")
    detail.stage:SetColorTexture(0.03, 0.03, 0.04, 1)
    detail.stageEdge = detail:CreateTexture(nil, "BACKGROUND")
    detail.stageEdge:SetColorTexture(0.16, 0.16, 0.18, 1)

    -- The figure, and its stand-in.
    detail.figure = detail:CreateTexture(nil, "ARTWORK")
    detail.plate = detail:CreateTexture(nil, "ARTWORK")
    detail.classIcon = detail:CreateTexture(nil, "OVERLAY")
    detail.classIcon:SetSize(64, 64)
    detail.classIcon:SetPoint("CENTER", detail.plate, "CENTER", 0, 0)

    detailSlots = {}
    for i, slot in ipairs(GEAR_SLOTS) do
        detailSlots[i] = BuildSlot(detail)
        detailSlots[i].slotLabel = slot.label
    end

    -- The tabs.
    --
    -- Two, because two have content. Reps and Profs are in AltTracker's bar
    -- and are not here: a tab that opens onto nothing is worse than a tab that
    -- is not there yet, and the bar is built from a table so adding them is a
    -- line each.
    detail.tabs = {}
    for _, def in ipairs(DETAIL_TABS) do
        local b = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
        b:SetSize(72, BAR_H)
        b:SetText(def.label)
        b.id = def.id
        b:SetScript("OnClick", function() Roster.SetDetailTab(def.id) end)
        detail.tabs[#detail.tabs + 1] = b
    end

    -- Audit rows, pooled to the REAL bound. A character can produce at most one
    -- finding per slot that could take an enchant - not one per gear slot,
    -- which was 17 where 7 suffice, and the comment said one thing while the
    -- loop did another.
    local maxFindings = 0
    for _ in pairs(ENCHANTABLE_SLOTS) do maxFindings = maxFindings + 1 end
    detailAudit = { rows = {} }
    detailAudit.none = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detailAudit.none:SetJustifyH("LEFT")
    detailAudit.none:SetJustifyV("TOP")
    detailAudit.none:SetTextColor(0.45, 0.8, 0.45)
    -- Bounded and wrapping. With only a TOPLEFT anchor a FontString is as wide
    -- as its text, so the longest of these sentences - "Not audited below
    -- level 60 - enchants on levelling gear are not a finding." - ran straight
    -- off the right of the panel and out over the game world.
    if detailAudit.none.SetWordWrap then detailAudit.none:SetWordWrap(true) end
    for _ = 1, maxFindings do
        local row = {}
        row.label = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetJustifyH("LEFT")
        row.label:SetTextColor(0.62, 0.62, 0.62)
        row.value = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.value:SetJustifyH("RIGHT")
        detailAudit.rows[#detailAudit.rows + 1] = row
    end

    -- The stats column.
    detailRows = {}
    for _, group in ipairs(CHAR_STAT_GROUPS) do
        local g = { header = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
                    rows = {} }
        g.header:SetText(group.header)
        g.header:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        g.header:SetJustifyH("LEFT")
        for _, def in ipairs(group.defs) do
            local row = { def = def }
            row.label = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.label:SetText(def.label)
            row.label:SetJustifyH("LEFT")
            row.label:SetTextColor(0.62, 0.62, 0.62)
            row.value = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.value:SetJustifyH("RIGHT")
            row.value:SetTextColor(unpack(AltStable.C.TEXT_VALUE))
            g.rows[#g.rows + 1] = row
        end
        detailRows[#detailRows + 1] = g
    end

    return detail
end

------------------------------------------------------------
-- Drawing it
------------------------------------------------------------

local QUALITY_RGB = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 },        [2] = { 0.12, 1, 0 },
    [3] = { 0, 0.44, 0.87 },    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.50, 0 },
    [6] = { 0.90, 0.80, 0.50 },
}

-- Laid out AROUND the figure rather than from the left edge.
--
-- The first version put the left column at a fixed x, the right column at
-- figure-width plus a margin, and the bottom row starting at the same left x -
-- so the weapons ran underneath the figure instead of beneath it, and nothing
-- was centred on anything. This takes the figure's centre and works outwards,
-- which is what a paper doll is.
local function RenderDetailSlots(char, figureCx, topY, figureHalf, bottomY)
    -- No clamp on leftX, because it cannot go negative: the caller passes
    -- figureCx as (margin + W/2) and figureHalf as (W/2), so the width cancels
    -- and this is always margin - SLOT_SIZE - 8. A guard here would be a
    -- branch nothing can reach, which is worse than none.
    local leftX  = figureCx - figureHalf - SLOT_SIZE - 8
    local rightX = figureCx + figureHalf + 8

    -- Count the bottom row first so it can be centred under the figure.
    local bottomN = 0
    for _, slot in ipairs(GEAR_SLOTS) do
        if slot.side == "bottom" then bottomN = bottomN + 1 end
    end
    local bottomX = figureCx - (bottomN * SLOT_STEP - (SLOT_STEP - SLOT_SIZE)) / 2

    local li, ri, bi = 0, 0, 0
    for i, slot in ipairs(GEAR_SLOTS) do
        local b = detailSlots[i]
        local ilvl = tonumber(char["gear_" .. slot.key]) or 0
        local id   = tonumber(char["gearid_" .. slot.key]) or 0

        b.link = char["gearlink_" .. slot.key]
        b.itemName = char["gearname_" .. slot.key]

        b:ClearAllPoints()
        if slot.side == "left" then
            b:SetPoint("TOPLEFT", detail, "TOPLEFT", leftX, topY - li * SLOT_STEP)
            li = li + 1
        elseif slot.side == "right" then
            b:SetPoint("TOPLEFT", detail, "TOPLEFT", rightX, topY - ri * SLOT_STEP)
            ri = ri + 1
        else
            -- BELOW the figure, not at a fixed offset from the top. The
            -- weapons used to be placed six rows down regardless of how tall
            -- the figure was, which put them across its legs.
            b:SetPoint("TOPLEFT", detail, "TOPLEFT",
                       bottomX + bi * SLOT_STEP, bottomY - 8)
            bi = bi + 1
        end

        -- An EMPTY slot still draws, greyed. A paper doll with holes in it is
        -- information: it is how you see the character is missing a cloak.
        if id > 0 then
            -- GetItemIconByID, through the adapter.
            --
            -- NOT GetItemIcon: Compat.lua names this as a known trap and
            -- test_compat asserts API.GetItemIcon is nil, because C_Item's
            -- version takes an ItemLocation and errors on an id. A bare global
            -- here found nothing, so every slot drew the question-mark
            -- fallback - which is exactly what it looked like on screen.
            local icon = GetItemIconByID and GetItemIconByID(id)
            b.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(false)
            b.icon:SetAlpha(1)
            local q = QUALITY_RGB[tonumber(char["gearq_" .. slot.key]) or 1] or QUALITY_RGB[1]
            b.border:SetColorTexture(q[1], q[2], q[3], 0.9)
            b.ilvl:SetText(ilvl > 0 and tostring(ilvl) or "")
            b.ilvl:SetTextColor(q[1], q[2], q[3])
        else
            b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            b.icon:SetDesaturated(true)
            b.icon:SetAlpha(0.28)
            b.border:SetColorTexture(0.25, 0.25, 0.25, 0.6)
            b.ilvl:SetText("")
        end
        b:Show()
    end
end

local function RenderDetail(char)
    if not char then return end
    BuildDetail()

    detail.name:SetText(AltStable.ClassColor
        and (AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r")
        or (char.name or "?"))

    local raceName = char.raceName or char.race or ""
    local className = (char.class or ""):sub(1, 1):upper() .. (char.class or ""):sub(2):lower()
    local where = char.guild and char.guild ~= ""
        and ("<" .. char.guild .. "> - " .. (char.realm or ""))
        or (char.realm or "")
    detail.sub:SetText(("Level %d %s %s      %s"):format(
        char.level or 0, raceName, className, where))

    detail.ilvl:SetText(("|cffaaaaaaiLvl|r  %.1f"):format(tonumber(char.ilvl) or 0))

    -- The figure: the cutout, or the class plate when there is not one. Same
    -- fallback the grid uses, so a character without a portrait looks the same
    -- here as it does there rather than looking broken.
    local entry = CutoutFor(char)
    -- The figure is sized to leave ROOM for the weapons row beneath it.
    --
    -- It used to take the whole panel height and the weapons were placed at a
    -- fixed offset from the top, so they landed across the character's legs.
    -- The game's own pane puts them below the model and so did AltTracker;
    -- ours only looked acceptable there because that figure had a background
    -- behind it, which made the overlap read as deliberate.
    local figureTop = -(BAR_TOP + BAR_H + 34)
    local WEAPON_ROW_H = SLOT_STEP + 22
    -- figureTop is a negative offset from the top, so this is what is left
    -- between it and the bottom of the panel.
    local figureH = detail:GetHeight() + figureTop - WEAPON_ROW_H - 16
    -- The side columns need six rows whatever the figure does; a panel too
    -- short for both is the panel's problem, not the figure's.
    local minH = 6 * SLOT_STEP
    if figureH < minH then figureH = minH end
    local figureBottom = figureTop - figureH

    -- The box, sized to the figure's column and the room left for it.
    local stageL = 60 - 6
    local stageW = DETAIL_FIGURE_W + 12
    detail.stageEdge:ClearAllPoints()
    detail.stageEdge:SetPoint("TOPLEFT", detail, "TOPLEFT", stageL - 1, figureTop + 1)
    detail.stageEdge:SetSize(stageW + 2, figureH + 2)
    detail.stage:ClearAllPoints()
    detail.stage:SetPoint("TOPLEFT", detail, "TOPLEFT", stageL, figureTop)
    detail.stage:SetSize(stageW, figureH)


    if entry then
        local w, h = FigureSize(entry, figureH)
        if w > DETAIL_FIGURE_W then h = h * (DETAIL_FIGURE_W / w); w = DETAIL_FIGURE_W end
        detail.figure:SetTexture(entry.file)
        detail.figure:SetTexCoord(TexCoordsFor(entry))
        detail.figure:SetSize(w, h)
        detail.figure:ClearAllPoints()
        detail.figure:SetPoint("TOP", detail, "TOPLEFT", 60 + DETAIL_FIGURE_W / 2, figureTop)
        detail.figure:Show()
        detail.plate:Hide(); detail.classIcon:Hide()
    else
        detail.figure:Hide()
        local r, g, b = AltStable.GetClassRGB(char.class)
        detail.plate:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, 1)
        detail.plate:SetSize(DETAIL_FIGURE_W * 0.7, figureH * 0.8)
        detail.plate:ClearAllPoints()
        detail.plate:SetPoint("TOP", detail, "TOPLEFT", 60 + DETAIL_FIGURE_W / 2, figureTop)
        detail.plate:Show()
        -- Built the same way the grid's plate builds it, by path. There is no
        -- ClassIconPath helper on AltStable - I reached for one that does not
        -- exist, and the guard around it would have left this icon silently
        -- blank on every character without a portrait.
        local cls = type(char.class) == "string" and char.class or ""
        cls = cls:sub(1, 1):upper() .. cls:sub(2):lower()
        if cls ~= "" then
            detail.classIcon:SetTexture("Interface\\Icons\\ClassIcon_" .. cls)
            detail.classIcon:Show()
        else
            detail.classIcon:Hide()
        end
    end

    RenderDetailSlots(char, 60 + DETAIL_FIGURE_W / 2, figureTop, DETAIL_FIGURE_W / 2,
                      figureBottom)

    -- The right-hand column, and which tab owns it.
    -- Clamped to the panel, not just pushed right. The Roster inherits
    -- whatever width the previous section left behind - SheetUI's
    -- ResizeFrameToContent early-outs for plugins - so on a narrow frame
    -- `width - 260` went NEGATIVE relative to the column and the max() pushed
    -- the tabs past the right edge instead. `detail` sets no SetClipsChildren,
    -- so they drew over the game world outside the window, and the tabs are
    -- the first thing out there a player can click.
    local COLUMN_W = 250
    local x = math.min(math.max(360 + DETAIL_FIGURE_W, detail:GetWidth() - COLUMN_W - 10),
                       math.max(0, detail:GetWidth() - COLUMN_W - 10))
    local y = figureTop

    for i, b in ipairs(detail.tabs) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", detail, "TOPLEFT", x + (i - 1) * 74, figureTop + 24)
        -- The active tab is the one you are NOT being invited to press - but
        -- disabled READS as unavailable, not as "you are here", so the tab you
        -- are on looked greyed out while the other one looked like the
        -- selected one. The label carries the state as well.
        local active = b.id == Roster.detailTab
        b:SetEnabled(not active)
        local fs = b.GetFontString and b:GetFontString()
        if fs then
            if active then fs:SetTextColor(unpack(AltStable.C.ACCENT))
            else fs:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
        end
        b:Show()
    end

    local onChar = Roster.detailTab ~= "audit"

    ----------------------------------------------------------
    -- Audit
    ----------------------------------------------------------
    -- Only computed when it is being shown. Refresh runs on every sync, and
    -- Char is the tab you always land on - walking every slot, allocating a
    -- table and sorting it to throw the result away was work done on a timer.
    local findings, reason = {}, nil
    if not onChar then findings, reason = AuditCharacter(char) end
    for i, row in ipairs(detailAudit.rows) do
        local f = findings[i]
        if f and not onChar then
            row.label:ClearAllPoints()
            row.label:SetPoint("TOPLEFT", detail, "TOPLEFT", x + 6, y)
            row.label:SetText(f.label)
            row.value:ClearAllPoints()
            row.value:SetPoint("TOPRIGHT", detail, "TOPLEFT", x + COLUMN_W, y)
            row.value:SetText(f.issue)
            -- Amber for a finding, grey for "cannot tell". Not red: a missing
            -- enchant is a thing to do, not a fault.
            if f.rank == 1 then row.value:SetTextColor(1, 0.82, 0)
            else row.value:SetTextColor(0.55, 0.55, 0.55) end
            row.label:Show(); row.value:Show()
            y = y - STAT_ROW_H
        else
            row.label:Hide(); row.value:Hide()
        end
    end
    if not onChar and #findings == 0 then
        detailAudit.none:ClearAllPoints()
        detailAudit.none:SetPoint("TOPLEFT", detail, "TOPLEFT", x + 6, y)
        -- The right edge, so it wraps inside the column instead of running out
        -- of the panel. Set here rather than at build time because the column
        -- moves with the frame width.
        detailAudit.none:SetPoint("RIGHT", detail, "TOPLEFT", x + COLUMN_W, y)
        detailAudit.none:SetHeight(STAT_ROW_H * 3)
        -- A reason means the audit did not RUN - nothing equipped, or the
        -- character is still levelling. That is not a clean bill, and saying
        -- "every enchantable slot is enchanted" to somebody wearing nothing is
        -- the same conflation this file refuses everywhere else.
        detailAudit.none:SetText(reason or "Every enchantable slot is enchanted.")
        if reason then detailAudit.none:SetTextColor(0.55, 0.55, 0.55)
        else detailAudit.none:SetTextColor(0.45, 0.8, 0.45) end
        detailAudit.none:Show()
    else
        detailAudit.none:Hide()
    end

    ----------------------------------------------------------
    -- Char
    ----------------------------------------------------------
    -- Rows whose stat this character does not have are skipped, and a section
    -- with nothing left in it takes its header with it - a "Combat" heading
    -- over five dashes says nothing.
    for _, group in ipairs(detailRows) do
        local any = false
        for _, row in ipairs(group.rows) do
            if HasStatValue(char, row.def) then any = true; break end
        end
        if not any or not onChar then
            group.header:Hide()
            for _, row in ipairs(group.rows) do row.label:Hide(); row.value:Hide() end
        else
            group.header:ClearAllPoints()
            group.header:SetPoint("TOPLEFT", detail, "TOPLEFT", x, y)
            group.header:Show()
            y = y - STAT_ROW_H - 2
            for _, row in ipairs(group.rows) do
                if HasStatValue(char, row.def) then
                    row.label:ClearAllPoints()
                    row.label:SetPoint("TOPLEFT", detail, "TOPLEFT", x + 6, y)
                    row.value:ClearAllPoints()
                    row.value:SetPoint("TOPRIGHT", detail, "TOPLEFT", x + COLUMN_W, y)
                    row.value:SetText(FormatStatValue(char, row.def))
                    row.label:Show(); row.value:Show()
                    y = y - STAT_ROW_H
                else
                    row.label:Hide(); row.value:Hide()
                end
            end
            y = y - STAT_SECTION_GAP
        end
    end
end

function Roster.Select(guid)
    Roster.selected = guid
    for _, card in ipairs(Roster.cards) do
        if card:IsShown() then card.highlight:SetShown(card.charGuid == guid) end
    end
end

-- Drill in, and back out.
--
-- Back lands in whichever view you left WITHOUT remembering it. Drilling does
-- not change rosterView and the view toggle is hidden while you are in here,
-- so there is nothing to restore - the view you return to is still the one you
-- were in. An earlier version stored a `detailFrom` and put it back on the way
-- out; it could not be made to fail a test, because the value it restored was
-- always the value already there.
function Roster.DrillDown(guid)
    if not guid then return false end
    Roster.Select(guid)
    Roster.detail = guid
    -- Always open on Char. The tab is a per-visit choice, not a setting: a
    -- roster opened on the Audit tab because that is where you left it three
    -- days ago is a surprise, and it is the less interesting of the two.
    Roster.detailTab = "char"
    Roster.Refresh()
    return true
end

function Roster.SetDetailTab(id)
    Roster.detailTab = id
    Roster.Refresh()
    return true
end

function Roster.Back()
    if not Roster.detail then return false end
    Roster.detail = nil
    -- The selection goes too. It only ever existed to mark which card you were
    -- about to drill into, and a highlight left behind on the way out reads as
    -- a mode you cannot leave.
    Roster.selected = nil
    Roster.Refresh()
    return true
end

function Roster.Refresh()
    if not panel then return end

    -- Drilled into a character: that replaces the view entirely.
    --
    -- Checked FIRST and returning, rather than hiding things afterwards. The
    -- Roster repaints on every sync, and a refresh that rebuilt the grid
    -- underneath would flicker it through the detail on each one.
    if Roster.detail then
        local char = CharacterStore()[Roster.detail]
        if char then
            BuildDetail()
            for _, card in ipairs(Roster.cards) do card:Hide() end
            if sceneBar then sceneBar:Hide() end
            if viewBtn then viewBtn:Hide() end
            if hintText then hintText:Hide() end
            RenderDetail(char)
            detail:Show()
            return
        end
        -- The character went away while we were looking at it - forgotten, or
        -- hidden from another view. Fall out rather than drawing a blank.
        Roster.detail, Roster.selected = nil, nil
    end

    if detail then detail:Hide() end
    if viewBtn then viewBtn:Show() end

    if sceneBar then sceneBar:SetShown(View() == "scene") end
    if viewBtn then viewBtn:SetText(View() == "scene" and "Grid" or "Scene") end

    if View() == "scene" then
        ApplyHintLayout(panel:GetWidth(), true)
        local shown, total, chosen = RenderScene(CharactersFor("scene"))
        if shown < total then
            hintText:SetText(chosen > 0
                and ("showing %d of %d - your favourites first; the grid shows them all")
                    :format(shown, total)
                or ("showing %d of %d - highest level first; favourite the ones you want here")
                    :format(shown, total))
            hintText:Show()
        else
            hintText:Hide()
        end
        return
    end

    local chars = CharactersFor("grid")
    ApplyHintLayout(panel:GetWidth(), false)
    backdropTex:SetTexture(nil)
    backdropTex:SetColorTexture(0.05, 0.05, 0.06, 1)

    local cols, rows, cardW, cardH = GridFor(panel:GetWidth(), panel:GetHeight(), #chars)
    local fits = cols * rows

    local withArt = 0
    for i, card in ipairs(Roster.cards) do
        local char = chars[i]
        if char and cols > 0 and i <= fits then
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            -- Put the frame level back. Scene mode raises cards by up to +11
            -- to order the ring, and nothing here lowered them again: a card
            -- left raised sits over the Grid/Scene button and eats its clicks
            -- the moment the padding or the hint line changes height.
            card:SetFrameLevel(panel:GetFrameLevel() + 1)

            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", panel, "TOPLEFT",
                PAD_X + col * (cardW + CARD_GAP),
                -(PAD_Y + 18 + row * (cardH + CARD_GAP)))
            RenderCard(card, char, cardW, cardH)
            if CutoutFor(char) then withArt = withArt + 1 end
        else
            card:Hide()
        end
    end

    -- Say where the pictures come from, but only while some are missing: a
    -- permanent instruction on a finished lineup is clutter.
    if withArt < #chars then
        hintText:SetText(("%d of %d characters have a portrait - capture one with "
            .. "|cffffff00/asrender|r while playing that character"):format(withArt, #chars))
        hintText:Show()
    else
        hintText:Hide()
    end
end

-- Repaint while the tab is OPEN. Without this the lineup is built once on
-- activation and then goes stale: an alt arriving by sync, a gear change, or
-- hiding someone (#21) shows nothing until the user leaves the tab and comes
-- back. Wrapping RefreshSheet is how the sibling plugins do it - one refresh
-- path, so nothing has to remember to call two.
local function HookRefresh()
    if Roster._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if Roster.isActive then
            C_Timer.After(0, function()
                if Roster.isActive then Roster.Refresh() end
            end)
        end
    end
    Roster._refreshHooked = true
end

function Roster.Activate(mainFrame)
    BuildPanel(mainFrame)
    HookRefresh()
    Roster.isActive = true
    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Hide()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Hide() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Hide() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Hide() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Hide()   end
    -- The totals bar deliberately STAYS: see BuildPanel. It is where the
    -- "(N hidden)" toggle lives, and a card hidden on this tab has to be
    -- recoverable on this tab.
    panel:Show()
    Roster.Refresh()
end

function Roster.Deactivate(mainFrame)
    Roster.isActive = false
    if panel then panel:Hide() end
    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Show()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Show() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Show() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Show() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Show()   end
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------

-- The icon is passed by PATH, exactly as every other tab does it (the sheet's
-- own sidebar, Warband, Raids). An earlier version guarded it with
-- API.TextureExists, which was wrong twice over: GetFileIDFromPath resolves
-- the CLIENT's file table, so an addon's own TGA on disk has no FileDataID and
-- reads as ABSENT - the guard rejected the real icon and showed a stock
-- placeholder in its place. A texture that genuinely is missing draws as
-- nothing, which is what the fallback amounted to anyway.

-- The detail view's test seams, built at FILE SCOPE and reached through
-- __index below.
--
-- Not entries in the registration table directly: each one is an upvalue of
-- the function that builds it, and that function was already near Lua 5.1's
-- sixty-upvalue ceiling. Adding the audit's four tipped it over and the file
-- stopped loading outright - a limit with no warning until the parser refuses
-- the whole plugin. One table is one upvalue.
local DETAIL_TEST = {
    DrillDown = function(g) return Roster.DrillDown(g) end,
    Back = function() return Roster.Back() end,
    Selected = function() return Roster.selected end,
    -- Direct references, not wrappers. Each `function() return f() end`
    -- is its own closure capturing its own upvalue, and this table is
    -- already near Lua 5.1's sixty-upvalue ceiling for the enclosing
    -- function - four more tipped it over and the file stopped
    -- loading. A plain reference costs none.,
    AuditCharacter = AuditCharacter,
    EnchantFromMod = EnchantFromMod,
    EnchantableHere = EnchantableHere,
    AuditFloor = AuditFloor,
    AuditCalls = function() return auditCalls end,
    ENCHANTABLE_SLOTS = ENCHANTABLE_SLOTS,
    DETAIL_TABS = DETAIL_TABS,
    DetailTabs = function() return (detail and detail.tabs) or {} end,
    DetailFrame = function() return detail end,
    DetailStageLayer = function() return detail and detail.stage:GetDrawLayer() end,
    DetailFigureBox = function()
        if not detail then return {} end
        local _, _, _, _, top = detail.stage:GetPoint(1)
        return { top = top, height = detail.stage:GetHeight(),
                 width = detail.stage:GetWidth(),
                 bottom = (top or 0) - (detail.stage:GetHeight() or 0) }
    end,
    DetailAuditLine = function() return detailAudit and detailAudit.none end,
    DetailSlotFrame = function(key)
        for i, slot in ipairs(GEAR_SLOTS) do
            if slot.key == key then return detailSlots and detailSlots[i] end
        end
    end,
    DetailClassIcon = function()
        if not detail or not detail.classIcon:IsShown() then return nil end
        return detail.classIcon:GetTexture()
    end,
    SetDetailTab = function(id) return Roster.SetDetailTab(id) end,
    DetailTab = function() return Roster.detailTab end,
    TabClick = function(label)
        for _, b in ipairs((detail and detail.tabs) or {}) do
            -- ENABLED as well as shown. A disabled button cannot be pressed
            -- in game, so a seam that fires its handler anyway proves
            -- something the player cannot do - and the active tab is
            -- deliberately the disabled one.
            if b:IsShown() and b:IsEnabled() and b:GetText() == label then
                local fn = b:GetScript("OnClick")
                if fn then fn(b) end
                return true
            end
        end
        return false
    end,
    DetailAudit = function()
        local out = {}
        if detailAudit and detailAudit.none:IsShown() then
            out[#out + 1] = detailAudit.none:GetText()
        end
        for _, r in ipairs((detailAudit and detailAudit.rows) or {}) do
            if r.value:IsShown() then
        out[#out + 1] = (r.label:GetText() or "") .. "=" .. (r.value:GetText() or "")
            end
        end
        return out
    end,
    CardClick = function(i)
        local card = Roster.cards[i]
        if not card or not card:IsShown() then return false end
        local fn = card:GetScript("OnClick")
        if not fn then return false end
        fn(card, "LeftButton")
        return true
    end,
    DetailShown = function() return detail ~= nil and detail:IsShown() and true or false end,
    DetailText = function()
        if not detail or not detail:IsShown() then return nil end
        return (detail.name:GetText() or "") .. " | " .. (detail.sub:GetText() or "")
            .. " | " .. (detail.ilvl:GetText() or "")
    end,
    DetailStats = function()
        local out = {}
        for _, g in ipairs(detailRows or {}) do
            if g.header:IsShown() then out[#out + 1] = g.header:GetText() end
            for _, r in ipairs(g.rows) do
        if r.value:IsShown() then
            out[#out + 1] = r.def.label .. "=" .. (r.value:GetText() or "")
        end
            end
        end
        return out
    end,
    DetailSlots = function()
        local out = {}
        for i, slot in ipairs(GEAR_SLOTS) do
            local b = detailSlots and detailSlots[i]
            if b and b:IsShown() then
        out[#out + 1] = slot.key .. "=" .. (b.ilvl:GetText() or "")
            end
        end
        return out
    end,
    CHAR_STAT_GROUPS = CHAR_STAT_GROUPS, GEAR_SLOTS = GEAR_SLOTS,
    FormatStatValue = FormatStatValue, HasStatValue = HasStatValue,
}

function Roster._Bootstrap()
    

if not AltStable or not AltStable.RegisterPlugin then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Roster]|r AltStable not found.")
        return
    end
    AltStable.RegisterPlugin({
        id           = ADDON_ID,
        label        = "Roster",
        icon         = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
                       .. "Icons\\roster.tga",
        _isPlugin    = true,
        OnActivate   = function(mainFrame) Roster.Activate(mainFrame) end,
        OnDeactivate = function(mainFrame) Roster.Deactivate(mainFrame) end,
        _test        = setmetatable({
            Slug = Slug, CutoutFor = CutoutFor, TexCoordsFor = TexCoordsFor,
            FigureSize = FigureSize, PickCharacters = PickCharacters,
            GridFor = GridFor, FigureHeightFor = FigureHeightFor, MAX_CARDS = MAX_CARDS,
            AllCharacters = AllCharacters, CharactersFor = CharactersFor,
            FavouritesAmong = FavouritesAmong,
            -- The card itself, so its right-click and its dimming can be
            -- driven rather than inferred from the functions behind them.
            BuildCard = BuildCard, RenderCard = RenderCard,
            HIDDEN_CARD_ALPHA = HIDDEN_CARD_ALPHA,
            RenderScene = RenderScene, Cards = function() return Roster.cards end,
            Panel = function() return panel end,
            -- What the player is actually told. Asserting the hint STRING is
            -- the only way to catch the renderer handing the count the wrong
            -- list: the composition is right either way.
            HintText = function() return hintText and hintText:GetText() end,
            Refresh = function() return Roster.Refresh() end,
            Activate = function(main) return Roster.Activate(main) end,
            HookRefresh = HookRefresh, BackdropTexCoords = BackdropTexCoords,
            SceneLayout = SceneLayout, SCENE_BACKDROPS = SCENE_BACKDROPS,
            SceneCast = SceneCast, RelativeFigureSize = RelativeFigureSize,
            RaceHeight = RaceHeight, TallestRace = TallestRace,
            MeasureCast = MeasureCast,
            RACE_HEIGHT = RACE_HEIGHT, DEFAULT_HEIGHT = DEFAULT_HEIGHT,
            FireAnchor = FireAnchor, FIRE_CLEARANCE = FIRE_CLEARANCE,
            FIRE_X = FIRE_X, FIRE_BASE_Y = FIRE_BASE_Y, SCENE_EDGE = SCENE_EDGE,
            FitScale = FitScale, HintLayout = HintLayout,
            SCENE_BAR_W = SCENE_BAR_W, VIEW_BTN_W = VIEW_BTN_W,
            BAR_TOP = BAR_TOP, BAR_H = BAR_H, PAD_X = PAD_X,
            SCENE_CAST = SCENE_CAST,
            View = View, CurrentScene = CurrentScene,
            MIN_CARD_W = MIN_CARD_W, MAX_CARD_W = MAX_CARD_W,
        }, { __index = DETAIL_TEST }),
    })
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end
    C_Timer.After(1, Roster._Bootstrap)
end)

-- THE USUAL PATH, and the one that matters: the core loads enabled plugins from
-- its OWN PLAYER_LOGIN handler, so by the time this file runs that event has
-- already fired and will not fire for us again. Without this the addon loads,
-- reports no error, and simply never appears in the nav - which is exactly what
-- it did. Warband and Raids both carry the same line.
if IsLoggedIn() then
    C_Timer.After(1, Roster._Bootstrap)
end
