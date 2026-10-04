------------------------------------------------------------
-- AltStableRoster — the alts, standing together (#15).
--
-- A character-select style lineup: every alt side by side on one backdrop,
-- click to select, hover for detail. The TBC original drew PNG "cutouts"
-- scraped from the Battle.net armory by a .NET tool. Forever has no armory, so
-- the images now come from the client itself: /alts portrait (Capture.lua)
-- photographs the LIVE character on a flat stage, a converter outside the game
-- mattes the pair into a transparent TGA, and CutoutManifest.lua lists what
-- exists. The capture ships; the converter does not, yet (#89).
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
local CAMP_BAR_W    = 200     -- the camp switcher, left of the backdrop picker (#152)
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
--
-- Four when pets are shown (#75): a fifth figure takes the room a hunter's
-- beast or a warlock's demon stands in, and with five they stood behind the
-- next character instead of beside their own (owner, in game). Five without.
-- By the OPTION, not by who has a pet, so a pet arriving by sync does not
-- reshuffle the line.
local SCENE_CAST = 5
local SCENE_CAST_WITH_PETS = 4
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

local panel, backdropTex, hintText, sceneBar, sceneLabel, viewBtn, campBar, campLabel

-- Which view, and which backdrop, remembered per account. The grid is the
-- default: it works for every character, whereas the scene needs a portrait and
-- shows a gap where one is missing.
local function View()
    return (AltStableConfig and AltStableConfig.rosterView == "scene") and "scene" or "grid"
end

-- The shown camp's own backdrop (#152); the old single choice, `rosterScene`,
-- before any camp exists or for a camp that has none yet.
local function SceneIndex()
    local camp = AltStable.SelectedCamp and AltStable.SelectedCamp()
    local want = (camp and camp.backdrop) or (AltStableConfig and AltStableConfig.rosterScene)
    for i, b in ipairs(SCENE_BACKDROPS) do
        if b.id == want then return i end
    end
    return 1
end

local function CurrentScene()
    return SCENE_BACKDROPS[SceneIndex()]
end
-- For the backdrop picker (CampList.lua, #152).
Roster.SCENE_BACKDROPS, Roster.CurrentScene = SCENE_BACKDROPS, CurrentScene

------------------------------------------------------------
-- Which cutout belongs to which character
------------------------------------------------------------

-- The identity rules live in the core (Core.lua), shared with the capture
-- button's "is a portrait due" check (#128): a character with a portrait there
-- has one here.
local Slug      = AltStable.CutoutSlug
local CutoutFor = AltStable.CutoutFor

-- The texture a character is DRAWN with (AltStableCompanion#17, "Enhanced
-- textures" in docs/PORTRAIT-CONTRACT.md): the entry's `enhanced` descriptor
-- when it has a usable one, else the plain portrait. Every drawing path - scene,
-- grid, detail - draws, fits and crops from what this returns: aspect and UVs
-- belong to the picture actually shown, while height still comes from the race.
--
-- "Usable" is checked on its SHAPE only: a non-empty file and four positive
-- numbers. Whether the file LOADS is not checked here, on purpose. A texture
-- cannot be asked whether a file id resolved (measured), and whether a path can
-- is not measured (forever-api-notes.md, "A file id cannot be validated") - a
-- check that may never fire would only claim the case is handled. The guarantee
-- is the writer's: the contract's attachment rule lists `enhanced` only when the
-- file is on disk and its hash matches the sidecar's.
local DESCRIPTOR_SIZES = { "w", "h", "texw", "texh" }
local function UsableDescriptor(d)
    -- The file half is the same rule a primary entry is held to (Core).
    if not AltStable.CutoutDrawable(d) then return false end
    for _, k in ipairs(DESCRIPTOR_SIZES) do
        local v = d[k]
        if type(v) ~= "number" or v ~= v or v <= 0 or v == math.huge then return false end
    end
    return true
end

local function EffectiveTexture(entry)
    if type(entry) ~= "table" then return nil end
    if UsableDescriptor(entry.enhanced) then return entry.enhanced end
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

Roster.BackdropTexCoords = BackdropTexCoords   -- for the picker's thumbnails (#152)

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

Roster.AllCharacters = AllCharacters      -- for the camp list (CampList.lua, #152)

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
local GetItemInfoInstant = AltStable.API and AltStable.API.GetItemInfoInstant

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
        -- allowZero AND hideAtCap: 0% rested is a real answer while you are
        -- still levelling, and at the cap there is no bar at all. See
        -- HasStatValue.
        { label = "Rested XP",   key = "restPercent", kind = "percent0",
          allowZero = true, hideAtCap = true },
        { label = "XP Progress", key = "xpPercent",   kind = "percent0",
          allowZero = true, hideAtCap = true },
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
        -- "Bonus Hit", NOT "Hit Chance". GetHitModifier returns the hit percent
        -- your GEAR adds, not your chance to hit anything - so a row reading
        -- "Hit Chance 0%" would be stating that the character always misses,
        -- which is the label being wrong rather than the number.
        --
        -- MEASURED as 0 on 1.60.1.70009, which is a real answer for a character
        -- with no +hit gear. Deliberately WITHOUT allowZero: a nonzero reading
        -- is still unobserved on this client, and without it HasStatValue hides
        -- the row at zero - so the row appears only for a character that has
        -- some, and nobody is shown a figure that turns out to mean nothing.
        { label = "Bonus Hit",    key = "stat_hitpct",  kind = "percent2" },
        { label = "Defense",      key = "stat_defense", kind = "int" },
    } },
}

-- The equipped slots, in the order a paper doll reads them: down the left, down
-- the right, weapons along the bottom.
--
-- The scanner's table, not a copy of it. There was a second copy here, and two
-- lists of seventeen slots each is two chances to disagree about which key a
-- slot writes - while the field names they produce (`gearid_back`,
-- `gearmod_back`) are the contract between the two files.
local GEAR_SLOTS = AltStable.GEAR_SLOTS

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
        -- The second argument is "is this the character you are logged in as",
        -- and it decides whether a recent timestamp reads "Online" or "0m ago".
        -- Passing a flat false meant your OWN character - the one whose row is
        -- guaranteed fresh - was the single character that could never say
        -- Online, which is how RowRenderer's tooltip already calls it.
        return AltStable.FormatLastSeen
            and AltStable.FormatLastSeen(value, char.guid == UnitGUID("player"))
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
    -- At the level cap there is no XP bar, and the scanner writes a literal 0
    -- for both XP fields to say exactly that. Combined with allowZero - which
    -- those two rows need, because 0% rested below the cap is a real answer -
    -- a capped character read "Rested XP 0%" and "XP Progress 0%": a precise
    -- number for a bar that does not exist. `allowZero` cannot tell those two
    -- zeroes apart, so the level does.
    if def.hideAtCap then
        local cap = AltStable.API and AltStable.API.LevelCap and AltStable.API.LevelCap()
        if cap and (tonumber(char.level) or 0) >= cap then return false end
    end
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

    local entry = EffectiveTexture(CutoutFor(char))
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

-- The tab's own background, whenever it is a COLOUR rather than camp art.
--
-- Under glass that colour is the material's: painted opaque, this tab was a
-- solid rectangle sitting inside a glass window while Raids and Warband beside
-- it were not - they picked the pane up during the corner work, because their
-- panels reach the window edge and had to become clipped textures.
--
-- One function for both sites because the scene view puts art on this same
-- texture, so coming back from it has to repaint, and a repaint that names its
-- own colour is a second place for the skin to disagree with itself.
local function PaintBackdrop()
    if not backdropTex then return end
    backdropTex:SetTexture(nil)
    backdropTex:SetColorTexture(AltStable.SkinTabBG())
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
    -- Beside the sidebar's edge, so it follows when the sidebar collapses (#150).
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, footerH + 2)
    panel:Hide()
    Roster.panel = panel        -- for the camp list (CampList.lua, #152)

    backdropTex = panel:CreateTexture(nil, "BACKGROUND")
    backdropTex:SetAllPoints()
    -- Left UNPAINTED here on purpose. Activate calls Refresh immediately after
    -- this, and every path out of it paints this texture - the grid through
    -- PaintBackdrop, the scene with camp art, the drill-down through it too. A
    -- colour set here is overwritten before a frame is drawn, which is also why
    -- a mutation deleting it could not be caught: nothing ever observes it.

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

    -- The camp switcher (#152): which camp the scene shows, by name.
    campBar = CreateFrame("Frame", nil, panel)
    campBar:SetPoint("TOPLEFT", 8, -BAR_TOP)
    campBar:SetSize(CAMP_BAR_W, BAR_H)
    campBar:Hide()
    local campPrev = CreateFrame("Button", nil, campBar, "UIPanelButtonTemplate")
    campPrev:SetSize(22, 20); campPrev:SetText("<"); campPrev:SetPoint("LEFT", 0, 0)
    local campNext = CreateFrame("Button", nil, campBar, "UIPanelButtonTemplate")
    campNext:SetSize(22, 20); campNext:SetText(">"); campNext:SetPoint("RIGHT", 0, 0)
    campLabel = campBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    campLabel:SetPoint("LEFT", campPrev, "RIGHT", 6, 0)
    campLabel:SetPoint("RIGHT", campNext, "LEFT", -6, 0)
    campLabel:SetJustifyH("CENTER")
    local function StepCamp(delta)
        local camps = AltStable.GetCamps and AltStable.GetCamps() or {}
        if #camps == 0 then return end
        local shown, at = AltStable.SelectedCamp(), 1
        for i, c in ipairs(camps) do if c == shown then at = i end end
        local i = at + delta
        if i < 1 then i = #camps end
        if i > #camps then i = 1 end
        AltStable.SelectCamp(camps[i].id)
        Roster.Refresh()
    end
    campPrev:SetScript("OnClick", function() StepCamp(-1) end)
    campNext:SetScript("OnClick", function() StepCamp(1) end)
    Roster.campButtons = { prev = campPrev, next = campNext }

    sceneBar = CreateFrame("Frame", nil, panel)
    sceneBar:SetPoint("TOPLEFT", 8 + CAMP_BAR_W + 8, -BAR_TOP)
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

    -- The backdrop's name opens the picker (#152, part 3: retail's Campsites
    -- dialog, thumbnails in pages). The arrows stay, for a quick step.
    local pick = CreateFrame("Button", nil, sceneBar)
    pick:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    pick:SetPoint("RIGHT", next_, "LEFT", -4, 0)
    pick:SetHeight(BAR_H)
    local pickHL = pick:CreateTexture(nil, "HIGHLIGHT")
    pickHL:SetAllPoints()
    pickHL:SetColorTexture(1, 1, 1, 0.08)
    pick:SetScript("OnClick", function()
        if Roster.CampList and Roster.CampList.OpenBackdrops then Roster.CampList.OpenBackdrops() end
    end)
    pick:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:ClearLines()
        GameTooltip:AddLine("Choose a backdrop", 1, 1, 1)
        GameTooltip:AddLine("Every camp can have its own.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    pick:SetScript("OnLeave", function(self)
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    Roster.backdropPick = pick

    local function Step(delta)
        local i = SceneIndex() + delta
        if i < 1 then i = #SCENE_BACKDROPS end
        if i > #SCENE_BACKDROPS then i = 1 end
        -- The shown camp's backdrop (#152); the shared one only with no camp.
        local camp = AltStable.SelectedCamp and AltStable.SelectedCamp()
        if camp then
            AltStable.SetCampBackdrop(camp.id, SCENE_BACKDROPS[i].id)
        else
            AltStable.SetConfigValue("rosterScene", SCENE_BACKDROPS[i].id)
        end
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
        local cut = EffectiveTexture(cutoutFor(char))
        local spot = spots[i]
        if cut and spot then
            local w, h = RelativeFigureSize(cut, RaceHeight(char), tallest, figureH)
            -- The texture it measured goes along, so the draw loop draws that
            -- one rather than resolving (and possibly disagreeing) again.
            sizes[i] = { w * spot.scale, h * spot.scale, cut = cut }
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

-- Seeding the first camp (#152) ranks characters with a portrait: a class card
-- pasted into a campsite looks like a mistake rather than a placeholder.
-- Highest level, then item level, then name.
local function ByRank(a, b)
    local la, lb = a.level or 0, b.level or 0
    if la ~= lb then return la > lb end
    local ia, ib = a.ilvl or 0, b.ilvl or 0
    if ia ~= ib then return ia > ib end
    return (a.name or "") < (b.name or "")
end

-- The characters with a portrait, ranked: what the FIRST camp is seeded from
-- (#152). The scene itself draws a camp now, not this; favourites order the
-- grid only.
local function SceneCast(chars, cutoutFor, limit)
    local out = {}
    for _, c in ipairs(chars) do
        if cutoutFor(c) then out[#out + 1] = c end
    end
    table.sort(out, ByRank)
    while #out > (limit or SCENE_CAST) do table.remove(out) end
    return out
end

------------------------------------------------------------
-- Camps (#152)
--
-- The scene shows a CAMP: a named group of up to AltStable.CAMP_SIZE
-- characters, in order, with its own backdrop - retail's warband camps. The
-- data lives in Config.lua (the right-click menu needs it too); this file seeds
-- the first one and draws them.
------------------------------------------------------------

-- The first camp's members: the top characters with a portrait, then, if there
-- are fewer than a camp holds, the top ones without (they stand once captured).
local function SeedMembers(chars, cutoutFor)
    local size = AltStable.CAMP_SIZE or SCENE_CAST
    local out, taken = {}, {}
    for _, c in ipairs(SceneCast(chars, cutoutFor, size)) do
        out[#out + 1] = c.guid; taken[c.guid] = true
    end
    local rest = {}
    for _, c in ipairs(chars) do
        if not taken[c.guid] then rest[#rest + 1] = c end
    end
    table.sort(rest, ByRank)
    for _, c in ipairs(rest) do
        if #out >= size then break end
        out[#out + 1] = c.guid
    end
    return out
end

-- The camps, kept sound. The first time they are needed with a character
-- known, the first camp is made: the top characters. Until the player changes
-- any camp it stays "the top characters", topped up as more arrive - a fresh
-- install knows only the character logged in. Seats whose record is gone are
-- freed. After the player's first change, a camp is only what they made it -
-- even an empty list, after they delete the last one.
local function EnsureCamps()
    if not (AltStable.CampsSetUp and AltStable.SeedCamp) then return end
    local chars = AllCharacters(false)
    if not AltStable.CampsSetUp() then
        if #chars == 0 then return end
        AltStable.SeedCamp(SeedMembers(chars, CutoutFor), AltStableConfig and AltStableConfig.rosterScene)
        return
    end
    AltStable.PruneCamps(CharacterStore())
    if AltStable.CampsAutoSeeded() then
        AltStable.RefreshSeededCamp(SeedMembers(chars, CutoutFor))
    end
end
-- For the right-click menu, which can be the first to need a camp.
AltStable.EnsureRosterCamps = EnsureCamps

-- Who in a camp stands at the fire: its members in order, skipping anyone
-- forgotten, hidden (#21: hidden is hidden in every view) or without a
-- portrait, up to `limit` seats. `info` counts each kind left out, for the hint.
local function CampCast(camp, cutoutFor, limit)
    local store = CharacterStore()
    local cast = {}
    local info = { members = 0, gone = 0, hidden = 0, noArt = 0, noSeat = 0 }
    for _, guid in ipairs(camp and camp.members or {}) do
        info.members = info.members + 1
        local c = store[guid]
        if type(c) ~= "table" or not c.name then
            info.gone = info.gone + 1
        elseif AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) then
            info.hidden = info.hidden + 1
        elseif not cutoutFor(c) then
            info.noArt = info.noArt + 1
        elseif #cast >= (limit or SCENE_CAST) then
            info.noSeat = info.noSeat + 1
        else
            cast[#cast + 1] = c
        end
    end
    return cast, info
end

-- One backdrop, everyone standing on it.
------------------------------------------------------------
-- Pets in the scene (#75), as the retail warband screen does it: a hunter's
-- beast or a warlock's demon standing at its owner's shoulder. An Options
-- toggle, off by default.
--
-- A LIVE MODEL, unlike the cast. Measured on 1.60.1.70124: a creature's
-- texture is baked into its model, so the display id the scanner saved renders
-- the pet fully textured with nobody logged in - the thing a player's display
-- id cannot do (see the header). No capture, no converter.
--
-- Framed BY HAND. PlayerModel's own camera is per model - the owner's bear came
-- out head-only where the cat came out whole - and the stable's ModelScene
-- preset (718) has no actor on Forever. So each pet gets a plain ModelScene
-- with a fixed camera, and its actor is scaled from its own bounding box.
--
-- SIZED in the cast's units (RACE_HEIGHT: a human male is 1.0), not from the
-- box: boxes are not in world scale (a night elf measured 2.09 and a gnome
-- 1.53, nothing like their real ratio). Demons by creature, from in-game
-- screenshots; beasts from the box with one calibration factor, the owner's
-- cat being half a night elf.
------------------------------------------------------------

local PET_HEIGHT = {          -- demons, by npc id
    [416]  = 0.45,            -- imp: a little under its gnome's height (in game)
    [1860] = 1.00,            -- voidwalker: ~1.7 gnomes beside its gnome (measured)
    [1863] = 1.00,            -- succubus
    [417]  = 0.62,            -- felhunter
}
local BEAST_UNITS_PER_BOX = 0.32   -- cat: box 1.72 -> 0.55, half of a 1.10 night elf (measured)
local BEAST_DEFAULT = 0.55         -- until the box has loaded
local PET_MIN, PET_MAX = 0.35, 1.10

-- Camera on +X, looking back at the model, from FAR with a NARROW lens: close
-- and wide, the parts of a model nearest the camera grew past its frame and
-- were cut off (an imp's, in game). Same framing, nearly no perspective.
local PET_FOV, PET_CAMERA = 0.15, 40
-- The frame is bigger than the model, both ways: the box is measured in ONE
-- pose, and the idle animation reaches past it - an imp's horns, feet, and a
-- step to the left were cut off at 4% (in game). The frame is lowered by the
-- spare below the model, so the feet stay on the ground.
local PET_SPARE_W = 1.4               -- frame width per model width
local PET_MARGIN = 1.3                -- frame height per model height
local PET_LIFT = 0.03                 -- BEHIND the owner: a touch higher up the ground
-- One table: Lua 5.1 allows a function 60 upvalues, and the test exports are
-- one function already near it.
--   turn        a pet on the fire side turns this far toward it (owner: 20 deg);
--               one on the outside faces the viewer
--   ownerShift  an owner with a pet steps this share of the slot away from it
--   reach       the pet's centre: this share of the owner's width out, so it
--               stands mostly BEHIND them (owner). Its own width is left out:
--               a frame is wider than the animal, and it pushed a cat clear
-- NO width cap: capping a pet to its slot shrank a cat - long in 3/4 view - to
-- a kitten by the fire (owner, in game). It keeps its true size and is only
-- kept inside the panel.
--   outer       a pet on the OUTSIDE has room to spare there (owner, in game):
--               BESIDE its owner by both widths (reach of the half-widths, so
--               they overlap a little), a step further back (higher), smaller,
--               and stopped by the panel's edge - so a wide one hugs the edge.
--               It reads as FURTHER AWAY (a quarter smaller, well up the
--               ground), never reaches past its owner's inner shoulder, and is
--               drawn behind the fire-side pets: a voidwalker right behind its
--               gnome covered the next character, and the cat's tail went
--               behind it (owner, in game)
local PET_LAYOUT = { turn = math.rad(20), ownerShift = 0.15, reach = 0.2,
                     outer = { reach = 0.8, lift = 0.10, size = 0.75 }, edgePad = 4 }

local function PetsEnabled()
    return AltStableConfig and AltStableConfig.rosterPets == true
end

-- How tall a pet stands, in RACE_HEIGHT units.
local function PetUnits(char, boxH)
    local units = PET_HEIGHT[tonumber(char and char.pet_npc) or 0]
    if not units then
        boxH = tonumber(boxH) or 0
        units = (boxH > 0) and (boxH * BEAST_UNITS_PER_BOX) or BEAST_DEFAULT
    end
    return math.max(PET_MIN, math.min(PET_MAX, units))
end

-- Which side of its owner each pet stands on, and how it is turned - the
-- owner's layout. Counted out from the fire on each side: the nearest owner's
-- pet stands on the fire side, turned 20 degrees toward it; the next one out
-- stands on the outside, facing the viewer; and so on. With four that is left,
-- right, left, right, turned 0, +20, -20, 0, and each pair's pets take the
-- outside of the pair, never one gap. +1 is screen right; spots are in x order.
local function PetSides(spots, fireX)
    local out, nLeft = {}, 0
    for _, s in ipairs(spots) do
        if s.x <= fireX then nLeft = nLeft + 1 end
    end
    for i, s in ipairs(spots) do
        local left = s.x <= fireX
        local rank = left and (nLeft - i) or (i - nLeft - 1)   -- 0 = nearest the fire
        local toFire = left and 1 or -1
        if rank % 2 == 0 then
            out[i] = { side = toFire, yaw = toFire * PET_LAYOUT.turn }
        else
            out[i] = { side = -toFire, yaw = 0, outer = true }
        end
    end
    return out
end

-- Where a pet is centred. On the fire side, out by part of the owner's width
-- only, mostly behind them (a frame is wider than its animal, and counting it
-- pushed a cat clear). On the outside, beside the owner by both widths. Then
-- the MODEL is kept inside the panel - not its frame, whose spare width is
-- empty: clamping the frame pushed a wide voidwalker in behind the next
-- character instead of to the edge (owner, in game).
local function PetX(ownerX, ownerW, modelW, side, panelW, outer)
    local x
    if outer then
        x = ownerX + side * (ownerW + modelW) / 2 * PET_LAYOUT.outer.reach
    else
        x = ownerX + side * ownerW * PET_LAYOUT.reach
    end
    local half = modelW / 2 + PET_LAYOUT.edgePad
    if panelW and panelW > 2 * half then
        x = math.max(half, math.min(panelW - half, x))
    end
    return x
end

-- How wide an outside pet may be: from the panel's edge to its owner's INNER
-- shoulder, so it never covers the next character.
local function OuterRoom(ownerX, ownerW, side, panelW)
    if side < 0 then return ownerX + ownerW / 2 - PET_LAYOUT.edgePad end
    return (panelW or 0) - PET_LAYOUT.edgePad - (ownerX - ownerW / 2)
end

local function HasPet(char)
    local display = char and tonumber(char.pet_display)
    return PetsEnabled() and display ~= nil and display > 0
end

-- Where an owner stands in its slot: off-centre, away from its pet, when it
-- has one to make room for.
local function OwnerX(char, spot, slot, petSide)
    if not HasPet(char) or not petSide then return spot.x end
    return spot.x - petSide.side * slot * PET_LAYOUT.ownerShift
end

-- Width per height of the model as the camera sees it. The box's X is the
-- model's length (it faces +X), and the screen's horizontal is world Y; turned
-- by yaw, length and width each show a part.
local function PetAspect(box, yaw)
    if not box or (box.h or 0) <= 0 then return 2 end
    local seen = math.abs(box.l * math.sin(yaw)) + math.abs(box.w * math.cos(yaw))
    return math.max(0.5, seen / box.h)
end

-- The box as Forever returns it: six numbers (measured), or Retail's two
-- vectors should a later build switch. nil until the model has loaded.
local function ReadBox(actor)
    local r = { pcall(actor.GetActiveBoundingBox, actor) }
    if not r[1] then return nil end
    local x0, y0, z0, x1, y1, z1
    if type(r[2]) == "table" and type(r[3]) == "table" then
        x0, y0, z0, x1, y1, z1 = r[2].x, r[2].y, r[2].z, r[3].x, r[3].y, r[3].z
    else
        x0, y0, z0, x1, y1, z1 = r[2], r[3], r[4], r[5], r[6], r[7]
    end
    x0, y0, z0 = tonumber(x0), tonumber(y0), tonumber(z0)
    x1, y1, z1 = tonumber(x1), tonumber(y1), tonumber(z1)
    if not (x0 and y0 and z0 and x1 and y1 and z1) then return nil end
    local h = z1 - z0
    if h <= 0.001 then return nil end
    return { l = x1 - x0, w = y1 - y0, h = h }
end

local function PetFrame(i)
    Roster.pets = Roster.pets or {}
    if Roster.pets[i] ~= nil then return Roster.pets[i] or nil end
    local ok, scene = pcall(CreateFrame, "ModelScene", nil, panel)
    local okA, actor
    if ok and scene then okA, actor = pcall(scene.CreateActor, scene) end
    if not (okA and actor) then
        Roster.pets[i] = false        -- this client has no ModelScene: never retry
        return nil
    end
    pcall(scene.SetCameraFieldOfView, scene, PET_FOV)
    pcall(scene.SetCameraNearClip, scene, 0.1)
    pcall(scene.SetCameraFarClip, scene, 100)
    pcall(scene.SetCameraPosition, scene, PET_CAMERA, 0, 0)
    pcall(scene.SetCameraOrientationByYawPitchRoll, scene, math.pi, 0, 0)
    pcall(actor.SetUseCenterForOrigin, actor, true, true, true)
    pcall(actor.SetPosition, actor, 0, 0, 0)
    -- No particles. An imp's fel fire kept burning on a frozen pose, ran past
    -- the frame as a green rectangle, and swelled the box the imp is fitted
    -- by until the imp itself was a speck (measured, 70124). The portraits
    -- around it carry no effects either.
    pcall(actor.SetParticleOverrideScale, actor, 0)
    scene:EnableMouse(false)          -- clicks belong to the cards
    scene.actor = actor
    scene:Hide()
    Roster.pets[i] = scene
    return scene
end

-- Size and place one pet from what it wants and what its model measured.
local function PlacePet(f)
    local want = f._want
    if not want then return end
    local box = f._box
    local yaw = want.yaw
    local aspect = PetAspect(box, yaw)
    local h = math.min(PetUnits(want.char, box and box.h) * want.unitPx, want.maxH)
    if want.outer then
        local room = OuterRoom(want.ownerX, want.ownerW, want.side, want.panelW)
        if room > 0 and h * aspect > room then h = room / aspect end
    end
    local frameH = h * PET_MARGIN
    local frameW = h * aspect * PET_SPARE_W
    f:SetSize(frameW, frameH)
    f:SetFrameLevel(want.level)
    f:ClearAllPoints()
    f:SetPoint("BOTTOM", panel, "BOTTOMLEFT",
        PetX(want.ownerX, want.ownerW, h * aspect, want.side, want.panelW, want.outer), want.y - (frameH - h) / 2)
    pcall(f.actor.SetYaw, f.actor, yaw)
    if box then
        -- The field of view spans the frame's LARGER side (measured: taken as
        -- the height, a cat in a wide frame came out three times too big; then
        -- taken as the width, an imp in a tall frame clipped top and bottom,
        -- while the portrait probe pane had fitted as height). So the height
        -- the camera sees is the full span, or the width's share of it.
        local span = 2 * PET_CAMERA * math.tan(PET_FOV / 2)
        local viewH = (frameW >= frameH) and (span * frameH / frameW) or span
        pcall(f.actor.SetScale, f.actor, viewH / (box.h * PET_MARGIN))
        f:Show()
    end
end

-- The box exists once the model has streamed in; poll briefly for it. The
-- token drops an answer that arrives after the pet was changed or hidden.
local function MeasurePet(f, token, tries)
    if f._token ~= token then return end
    local box = ReadBox(f.actor)
    if box then
        f._box = box
        -- It keeps its idle animation: a breathing cat among still portraits
        -- reads as alive, not wrong, once its particles are gone (owner, in
        -- game, after trying it frozen - "the sweet spot").
        PlacePet(f)
    elseif tries > 0 and C_Timer and C_Timer.After then
        C_Timer.After(0.1, function() MeasurePet(f, token, tries - 1) end)
    else
        -- Gave up: forget the display, so the next Refresh loads it afresh
        -- rather than re-placing a pet that has no box and never shows (Codex).
        f._display = nil
    end
end

local function HidePets()
    for _, f in pairs(Roster.pets or {}) do
        if f then f._want = nil; f:Hide() end
    end
end

-- One pet per seated owner that has one, after the cast is drawn. Refresh
-- has hidden them all first, so a pet not placed here stays hidden.
local function RenderPets(cast, spots, sizes, fit, figureH, tallest, petSides, panelW, panelH, slot)
    if not PetsEnabled() then HidePets(); return 0 end
    local drawn = 0
    for i = 1, #(Roster.cards or {}) do
        local char, spot = cast[i], spots[i]
        local display = char and tonumber(char.pet_display)
        local f = (display and display > 0 and spot and sizes[i] and sizes[i].cut) and PetFrame(i)
        if f then
            local ps = petSides[i]
            local outer = ps.outer and PET_LAYOUT.outer
            local y = spot.y + panelH * (outer and outer.lift or PET_LIFT)
            f._want = {
                char = char, side = ps.side, yaw = ps.yaw,
                ownerX = OwnerX(char, spot, slot, ps), ownerW = sizes[i][1] * fit,
                panelW = panelW,
                outer = ps.outer,
                y = y,
                unitPx = figureH / tallest * spot.scale * fit * (outer and outer.size or 1),
                -- Capped by the panel's TOP only: a voidwalker may tower over a
                -- gnome. Capped at the tallest character's height, it shrank to
                -- its gnome in a cast of gnomes (Codex). The MODEL's top, not the
                -- frame's - the frame's headroom is empty, and counting it
                -- shrank demons the cast had room for.
                maxH = math.max(0, panelH - y),
                -- Under EVERY character, not just its owner: the pet stands
                -- behind, as on the warband screen. Just under its owner, the
                -- one nearest the camera put a voidwalker over the next figure
                -- (measured), because the owner outranks the whole ring.
                -- Outside pets furthest back, then the fire-side ones; the
                -- cast from +3.
                level = panel:GetFrameLevel() + (ps.outer and 1 or 2),
            }
            if f._display ~= display then
                f._display, f._box = display, nil
                f._token = (f._token or 0) + 1
                f:Hide()
                local ok = pcall(f.actor.SetModelByCreatureDisplayID, f.actor, display)
                if ok then MeasurePet(f, f._token, 30) else f._display = nil end
            else
                PlacePet(f)
            end
            drawn = drawn + 1
        end
    end
    return drawn
end

-- The pets' test seam, apart from the plugin's: see its __index.
local PET_TEST = {
    PetUnits = PetUnits, PetSides = PetSides, PetX = PetX, PetAspect = PetAspect, OuterRoom = OuterRoom,
    ReadBox = ReadBox, PET_HEIGHT = PET_HEIGHT, PET_LAYOUT = PET_LAYOUT,
    SCENE_CAST_WITH_PETS = SCENE_CAST_WITH_PETS,
    Pets = function() return Roster.pets or {} end,
    SceneSlot = function() return Roster.sceneSlot end,
}

-- The width the camp list (CampList.lua, #152) takes off the right of the
-- panel while it is open in the scene view. The scene - backdrop, figures,
-- hint, buttons - lives in what is left.
local function SceneInset()
    local list = Roster.CampList
    return (View() == "scene" and list and list.Inset and list.Inset()) or 0
end
Roster.SceneInset = SceneInset

local function RenderScene(camp)
    local entry = CurrentScene()
    local pw, ph = panel:GetWidth() - SceneInset(), panel:GetHeight()

    backdropTex:SetTexture(entry.file)
    backdropTex:SetTexCoord(BackdropTexCoords(pw, ph, entry))
    backdropTex:SetVertexColor(1, 1, 1, 1)

    if sceneLabel then sceneLabel:SetText(entry.label) end
    if campLabel then campLabel:SetText(camp and camp.name or "No camp") end

    -- The shown camp's members, in their order (#152).
    local petsOn = AltStableConfig and AltStableConfig.rosterPets == true
    local cast, info = CampCast(camp, CutoutFor, petsOn and SCENE_CAST_WITH_PETS or SCENE_CAST)
    local spots, figureH, slot = SceneLayout(pw, ph, #cast, entry)
    local tallest = TallestRace(cast)

    local sizes = MeasureCast(cast, CutoutFor, spots, tallest, figureH)
    local fit = FitScale(sizes, slot)
    local petSides = PetSides(spots, (FireAnchor(pw, ph, entry)))
    local withArt = 0

    for i, card in ipairs(Roster.cards) do
        local char = cast[i]
        local cut = char and sizes[i] and sizes[i].cut
        local spot = spots[i]
        if char and cut and spot then
            withArt = withArt + 1
            local w, h = sizes[i][1] * fit, sizes[i][2] * fit

            -- From +2: +1 is the pets' (#75), behind the whole cast.
            card:SetFrameLevel(panel:GetFrameLevel() + 3 + spot.level)
            card._spotLevel = spot.level

            card:ClearAllPoints()
            card:SetPoint("BOTTOM", panel, "BOTTOMLEFT", OwnerX(char, spot, slot, petSides[i]), spot.y - NAME_H - 4)
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

    Roster.sceneSlot = slot
    RenderPets(cast, spots, sizes, fit, figureH, tallest, petSides, pw, ph, slot)

    -- How many stand at the fire, and who in the camp does not and why.
    return withArt, info
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

local function ApplyHintLayout(panelW, sceneView, dx)
    if not hintText then return end
    local y, w = HintLayout(panelW, sceneView)
    hintText:ClearAllPoints()
    hintText:SetPoint("TOP", dx or 0, y)
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
-- So it is still a setting, and Config.lua defaults it to the level cap. It was
-- briefly hardcoded to the cap instead, which is the same policy with the choice
-- taken away: "nothing is audited until it is finished levelling" is a
-- reasonable default and a poor law.
local function AuditFloor()
    local cap = (AltStable.API and AltStable.API.LevelCap and AltStable.API.LevelCap()) or 60
    local set = AltStableConfig and tonumber(AltStableConfig.auditMinLevel)
    -- Clamped, not trusted: this is a number on disk, and a floor of 0 audits
    -- every level 1 alt while a floor above the cap audits nobody at all and
    -- looks like the tab is broken.
    if set then return math.max(2, math.min(cap, set)) end
    return cap
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
    -- tonumber, not a string compare: "00" and "-0" are both zero and both read
    -- as ENCHANTED under `ench == "0"`.
    --
    -- Not a hypothetical. This field is SYNCED, so the string here is whatever
    -- arrived on the wire - and the peer that wrote it is running whatever
    -- version of this addon it is running. Our own PackGearMod formats with %d
    -- and cannot emit a padded zero, which is exactly why the defence has to be
    -- justified by the wire and not by the producer: the producer is not
    -- necessarily us.
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
-- The token is RESOLVED from the item id rather than stored, so it answers for
-- a peer-synced character exactly as it does for a local one. "Cannot tell" is
-- reserved for an id the client genuinely has no data for, which is a wait
-- rather than a verdict: AuditCharacter queues it for GET_ITEM_INFO_RECEIVED.
local function EnchantableHere(char, slotKey)
    if not ENCHANTABLE_SLOTS[slotKey] then return false end
    if slotKey ~= "offhand" then return true end

    -- Resolved from the item ID, which IS synced, rather than from a stored
    -- token that is not.
    --
    -- A stored gearloc_ field meant every peer-synced character reported
    -- "cannot tell" for its off-hand for ever - the same always-on remote
    -- noise that moving off gearlink_ was supposed to end. And it was stored
    -- for all seventeen slots when one is read, which is seventeen keys per
    -- character plus two sync-boundary special cases, for a fact already on
    -- the wire.
    --
    -- GetItemInfoInstant needs no item cache and takes a bare id, so this
    -- works for local and remote characters alike.
    local id = tonumber(char["gearid_offhand"]) or 0
    if id <= 0 then return false end
    if not GetItemInfoInstant then return nil end               -- cannot tell
    local ok, _, _, _, loc = pcall(GetItemInfoInstant, id)
    if not ok or type(loc) ~= "string" or loc == "" then return nil end
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
                -- And QUEUED, so the row is temporary rather than permanent.
                -- GetItemInfoInstant needs no cache for an item the client
                -- knows, but an id it has never seen - which a peer can sync
                -- from a character whose gear we have never met - resolves only
                -- after the server answers, and that arrives as
                -- GET_ITEM_INFO_RECEIVED. Core's handler repaints the sheet when
                -- an id in this queue lands.
                --
                -- Core has read this queue since the gem audit and nothing has
                -- filled it since the gems went, which made that branch dead
                -- code - and, less obviously, made "cannot tell" a permanent
                -- verdict for exactly the remote characters this tab is for.
                AltStable.PendingAuditItems = AltStable.PendingAuditItems or {}
                AltStable.PendingAuditItems[tonumber(char["gearid_" .. slot.key])] = true
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
-- The tab buttons' size and the stride between them. Named because the column
-- width is clamped against the row they form: a column narrower than its own
-- tabs puts the last tab back outside the panel, which is the thing the clamp
-- exists to prevent.
local DETAIL_TAB_W, DETAIL_TAB_STRIDE = 72, 74
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

    -- NO background of its own.
    --
    -- The tab's is directly behind it and is repainted on the way in, and a
    -- translucent material does not stack: pane over pane came out at ~0.86
    -- where the grid two clicks away was 0.62, so the character sheet read
    -- noticeably denser than the tab it opened from - the same per-surface
    -- disagreement this whole phase exists to remove. Opaque, it could not
    -- have shown; that is why it was there.

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
    -- EXPLICIT SUBLEVELS, because within one draw layer order is creation
    -- order: created second, the edge drew over the whole inset and the box
    -- read as a flat light-grey rectangle - "not a border, a lid", the same bug
    -- as the item-quality border two hundred lines above, in the same commit
    -- that fixed that one. Sublevels say what is in front regardless of the
    -- order these lines happen to be in, which is how
    -- Plugins/Instances/AltStableInstances.lua layers its row bands.
    detail.stageEdge = detail:CreateTexture(nil, "BACKGROUND", nil, 1)
    detail.stageEdge:SetColorTexture(AltStable.SkinWellEdgeColor())
    detail.stage = detail:CreateTexture(nil, "BACKGROUND", nil, 2)
    detail.stage:SetColorTexture(AltStable.SkinWellColor())

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
        b:SetSize(DETAIL_TAB_W, BAR_H)
        b:SetText(def.label)
        b.id = def.id
        b:SetScript("OnClick", function() Roster.SetDetailTab(def.id) end)
        -- The active marker is a TEXTURE, not a text colour.
        --
        -- The active tab is disabled, and UIPanelButtonTemplate swaps in its
        -- DISABLED font object when a button is disabled - which reapplies that
        -- object's colour and throws away a SetTextColor set on the current font
        -- string. So the accent tint below is a hint that the template is
        -- entitled to overrule, and on a client where it does, the only signal
        -- left was "greyed out", which reads as unavailable rather than "you are
        -- here". A texture we own cannot be overruled.
        b.activeMark = b:CreateTexture(nil, "OVERLAY")
        b.activeMark:SetColorTexture(unpack(AltStable.C.ACCENT))
        b.activeMark:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 4, 1)
        b.activeMark:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 1)
        b.activeMark:SetHeight(2)
        b.activeMark:Hide()
        detail.tabs[#detail.tabs + 1] = b
    end

    -- Audit rows, pooled to the REAL bound. A character can produce at most one
    -- finding per slot that could take an enchant - not one per gear slot,
    -- which was 17 where 7 suffice, and the comment said one thing while the
    -- loop did another.
    local maxFindings = 0
    for _ in pairs(ENCHANTABLE_SLOTS) do maxFindings = maxFindings + 1 end
    detailAudit = { rows = {} }
    -- Said out loud when the stats column runs out of room. A row quietly not
    -- drawn is a stat the player has no way to know exists, which is the same
    -- class of dishonesty as a clean bill for a character wearing nothing.
    detail.statsMore = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detail.statsMore:SetJustifyH("LEFT")
    detail.statsMore:SetTextColor(0.55, 0.55, 0.55)
    detail.statsMore:Hide()

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

-- The shared palette, not a third copy of it. The copy that was here was
-- missing Heirloom (7), so an heirloom drew a Common white border in this pane
-- and cyan in the grid beside it. The fallback is for the case this plugin
-- somehow loads without RowRenderer, and is a grey that is obviously not a
-- quality colour rather than a second palette to drift from.
local function QualityRGB(quality)
    if AltStable.QualityRGB then return AltStable.QualityRGB(quality) end
    return 0.5, 0.5, 0.5
end

-- Laid out AROUND the figure rather than from the left edge.
--
-- The first version put the left column at a fixed x, the right column at
-- figure-width plus a margin, and the bottom row starting at the same left x -
-- so the weapons ran underneath the figure instead of beneath it, and nothing
-- was centred on anything. This takes the figure's centre and works outwards,
-- which is what a paper doll is.
-- How big the slot buttons can be, given the room the side columns have.
--
-- The side columns are the tallest part of the layout: six rows at a fixed
-- stride from a fixed top, so their extent did not depend on the panel height at
-- all - and raising the stride from 40 to 48 in this same change put the sixth
-- button at 332px below the panel top. A 310px panel is reachable (SheetUI's
-- sidebar floors the window at 364, BuildPanel takes 30 above and 24 below, and
-- ResizeFrameToContent deliberately does not resize for plugins), so wrist and
-- ring 2 and their item-level labels sat on the footer and past the bottom edge.
--
-- Fixing the figure height was not enough: that bounds the WEAPONS row, which
-- hangs off the figure's bottom, and never touched the side stride. So the whole
-- equipment layout scales instead, keeping the stride-to-size ratio so the
-- item-level label keeps the gap it lives in.
--
-- Returns size, step. Never larger than the constants: a big panel is unchanged.
local SLOT_MIN = 18
local function SlotScale(rows, room)
    rows = math.max(1, rows or 1)
    local step = math.min(SLOT_STEP, (room or 0) / rows)
    local size = math.floor(step * (SLOT_SIZE / SLOT_STEP))
    if size < SLOT_MIN then size = SLOT_MIN end
    if size > SLOT_SIZE then size = SLOT_SIZE end
    if step < size then step = size end
    return size, step
end

-- `size` and `step` are passed in, not read from the constants, because a short
-- panel has to SHRINK the whole equipment layout rather than run off the bottom
-- of it. See SlotScale.
local function RenderDetailSlots(char, figureCx, topY, figureHalf, bottomY, size, step)
    size, step = size or SLOT_SIZE, step or SLOT_STEP
    -- No clamp on leftX, because it cannot go negative: the caller passes
    -- figureCx as (margin + W/2) and figureHalf as (W/2), so the width cancels
    -- and this is always margin - size - 8. A guard here would be a branch
    -- nothing can reach, which is worse than none.
    local leftX  = figureCx - figureHalf - size - 8
    local rightX = figureCx + figureHalf + 8

    -- Count the bottom row first so it can be centred under the figure.
    local bottomN = 0
    for _, slot in ipairs(GEAR_SLOTS) do
        if slot.side == "bottom" then bottomN = bottomN + 1 end
    end
    local bottomX = figureCx - (bottomN * step - (step - size)) / 2

    local li, ri, bi = 0, 0, 0
    for i, slot in ipairs(GEAR_SLOTS) do
        local b = detailSlots[i]
        local ilvl = tonumber(char["gear_" .. slot.key]) or 0
        local id   = tonumber(char["gearid_" .. slot.key]) or 0

        b.link = char["gearlink_" .. slot.key]
        b.itemName = char["gearname_" .. slot.key]

        b:ClearAllPoints()
        b:SetSize(size, size)
        if slot.side == "left" then
            b:SetPoint("TOPLEFT", detail, "TOPLEFT", leftX, topY - li * step)
            li = li + 1
        elseif slot.side == "right" then
            b:SetPoint("TOPLEFT", detail, "TOPLEFT", rightX, topY - ri * step)
            ri = ri + 1
        else
            -- BELOW the figure, not at a fixed offset from the top. The
            -- weapons used to be placed six rows down regardless of how tall
            -- the figure was, which put them across its legs.
            b:SetPoint("TOPLEFT", detail, "TOPLEFT",
                       bottomX + bi * step, bottomY - 8)
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
            local qr, qg, qb = QualityRGB(char["gearq_" .. slot.key])
            b.border:SetColorTexture(qr, qg, qb, 0.9)
            b.ilvl:SetText(ilvl > 0 and tostring(ilvl) or "")
            b.ilvl:SetTextColor(qr, qg, qb)
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
    local entry = EffectiveTexture(CutoutFor(char))
    -- The figure is sized to leave ROOM for the weapons row beneath it.
    --
    -- It used to take the whole panel height and the weapons were placed at a
    -- fixed offset from the top, so they landed across the character's legs.
    -- The game's own pane puts them below the model and so did AltTracker;
    -- ours only looked acceptable there because that figure had a background
    -- behind it, which made the overlap read as deliberate.
    local figureTop = -(BAR_TOP + BAR_H + 34)
    -- Reserved from the full-size slot, NOT from SLOT_STEP: the stride is what
    -- SlotScale derives from the room left over here, so reserving a stride's
    -- worth would make the two chase each other. An icon plus its item-level
    -- label plus breathing room, at the largest the icon can be, so the reserve
    -- is never short.
    local WEAPON_ROW_H = SLOT_SIZE + 22
    -- figureTop is a negative offset from the top, so this is what is left
    -- between it and the bottom of the panel.
    local figureH = detail:GetHeight() + figureTop - WEAPON_ROW_H - 16
    -- No six-row floor. There was one - `if figureH < 6 * SLOT_STEP then ...` -
    -- on the argument that the side columns need six rows whatever the figure
    -- does, and it produced exactly the bug the column clamp above fixes: the
    -- floor won on a short panel, figureBottom went past the bottom edge, and
    -- the weapons row went with it. Nothing here sets SetClipsChildren, so those
    -- seven item buttons drew over the game world and took the mouse there.
    --
    -- The two goals genuinely conflict on a short panel and the weapons row
    -- wins, for the same reason as before: overlapping side icons are ugly, and
    -- clickable buttons outside the window are a bug. So the figure takes the
    -- room that is actually there, and only refuses to invert.
    if figureH < 24 then figureH = 24 end
    local figureBottom = figureTop - figureH

    -- The side columns get the figure's own vertical extent, which is what they
    -- flank - so they can never reach the weapons row hanging below it either.
    local sideRows = 0
    do
        local li, ri = 0, 0
        for _, slot in ipairs(GEAR_SLOTS) do
            if slot.side == "left" then li = li + 1
            elseif slot.side == "right" then ri = ri + 1 end
        end
        sideRows = math.max(li, ri)
    end
    local slotSize, slotStep = SlotScale(sideRows, figureH)

    -- How wide the stats column gets.
    --
    -- The Roster inherits whatever width the previous section left behind -
    -- SheetUI's ResizeFrameToContent early-outs for plugins - so a frame too
    -- narrow to hold both the paper doll and a 250px column beside it is
    -- reachable. The two goals conflict there, and FITTING INSIDE THE PANEL
    -- WINS: `detail` sets no SetClipsChildren, so a control laid out past the
    -- right edge draws over the game world, and the tabs are the first thing out
    -- there a player can click. Sitting clear of the figure is cosmetic.
    --
    -- So the column NARROWS rather than moving out. An earlier version clamped
    -- the POSITION twice instead, `min(max(620, V), max(0, V))`, which is just
    -- `max(0, V)` for any V - the floor it looked like it had could never bind,
    -- and the tabs went outside the panel anyway.
    --
    -- The floor is the TAB ROW's own width, not an arbitrary number: the tabs
    -- are laid out from the column's left at a fixed stride, so a column
    -- narrower than the row puts the last tab back outside - clamped column,
    -- unclamped tabs.
    local tabRow = (#detail.tabs - 1) * DETAIL_TAB_STRIDE + DETAIL_TAB_W
    local COLUMN_W = math.max(tabRow, math.min(250,
                              detail:GetWidth() - (360 + DETAIL_FIGURE_W) - 10))

    -- And WHERE the whole composition sits, before anything is placed.
    --
    -- The paper doll and the stats column are one thing, and pinning the column
    -- to the right edge pulled them apart: on a 1520px panel the doll ended at
    -- 1180 and the stats began at 1680, five hundred pixels of nothing between
    -- them and the numbers jammed against the window frame. Two unrelated
    -- objects that had drifted to opposite walls.
    --
    -- So the pair is CENTRED as a unit when there is room to spare, and only
    -- falls back to the left margin when there is not. The slots overhang the
    -- figure on both sides, so the block's real edges are a gutter wider than
    -- the figure itself - centring on the figure would centre the wrong
    -- rectangle and lean the whole thing left by that gutter.
    local GROUP_GAP, EDGE_MIN = 40, 18
    local slotGutter = slotSize + 8
    local groupW = slotGutter + DETAIL_FIGURE_W + slotGutter + GROUP_GAP + COLUMN_W
    local figureL = EDGE_MIN + slotGutter
    if detail:GetWidth() - groupW > figureL * 2 then
        figureL = math.floor((detail:GetWidth() - groupW) / 2) + slotGutter
    end

    -- The box, sized to the figure's column and the room left for it.
    local stageL = figureL - 6
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
        detail.figure:SetPoint("TOP", detail, "TOPLEFT", figureL + DETAIL_FIGURE_W / 2, figureTop)
        detail.figure:Show()
        detail.plate:Hide(); detail.classIcon:Hide()
    else
        detail.figure:Hide()
        local r, g, b = AltStable.GetClassRGB(char.class)
        detail.plate:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, 1)
        detail.plate:SetSize(DETAIL_FIGURE_W * 0.7, figureH * 0.8)
        detail.plate:ClearAllPoints()
        detail.plate:SetPoint("TOP", detail, "TOPLEFT", figureL + DETAIL_FIGURE_W / 2, figureTop)
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

    RenderDetailSlots(char, figureL + DETAIL_FIGURE_W / 2, figureTop, DETAIL_FIGURE_W / 2,
                      figureBottom, slotSize, slotStep)

    -- The stats column starts a fixed gap past the paper doll's right-hand
    -- slots, wherever the group ended up - so the two stay a pair. Clamped to
    -- the panel on the way out, because on a frame too narrow to hold both, the
    -- gap is the thing that gives.
    local x = figureL + DETAIL_FIGURE_W + slotGutter + GROUP_GAP
    x = math.max(10, math.min(x, detail:GetWidth() - COLUMN_W - 10))
    detail.columnRight = x + COLUMN_W
    local y = figureTop

    for i, b in ipairs(detail.tabs) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", detail, "TOPLEFT",
                   x + (i - 1) * DETAIL_TAB_STRIDE, figureTop + 24)
        -- The active tab is the one you are NOT being invited to press - but
        -- disabled READS as unavailable, not as "you are here", so the tab you
        -- are on looked greyed out while the other one looked like the
        -- selected one. The label carries the state as well.
        local active = b.id == Roster.detailTab
        b:SetEnabled(not active)
        b.activeMark:SetShown(active)
        -- Attempted as well, because when the template does NOT overrule it the
        -- label reading in the accent colour is the clearer of the two signals.
        -- Never the only one: see activeMark above.
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
        --
        -- TOPRIGHT, not RIGHT: RIGHT pins the vertical CENTRE to the same y the
        -- TOPLEFT above pins the TOP to, which is a request for a height of
        -- zero. The line went invisible and the SetHeight below could not save
        -- it, because two conflicting anchors beat an explicit size.
        detailAudit.none:SetPoint("TOPRIGHT", detail, "TOPLEFT", x + COLUMN_W, y)
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
    --
    -- And the column is CLAMPED to the panel, the vertical half of the clamp the
    -- tabs above already had. Seventeen rows and four headers is about 421px
    -- measured from figureTop, the loop only ever decremented y, and `detail`
    -- sets no SetClipsChildren - so a fully-statted character on a short
    -- inherited frame drew its last rows below the panel edge and over the game
    -- world. Sixteen rows already did; the Bonus Hit row made it one worse,
    -- which is how it came up.
    --
    -- Compressed first, hidden second. Squeezing the rows keeps everything
    -- visible for any panel that is merely snug, and only a genuinely short one
    -- loses rows - with a line saying how many, because a row silently absent is
    -- a stat the player cannot know exists.
    -- The row's OWN measured height is the floor for everything below, not a
    -- guessed number. A stride shorter than the text it steps over stacks the
    -- rows on each other - the same trap as a slot stride below the icon size -
    -- and it also makes the clamp lie, because the loop advances by the stride
    -- while the label reaches further down than that.
    --
    -- Taking the floor HERE rather than at each clamp site is what keeps the two
    -- honest about each other: with the stride provably at least as tall as the
    -- text, the distance the loop advances is the distance the row occupies, and
    -- "will the next row fit" needs no second quantity to compare against.
    local lineH = 9
    if detailRows[1] and detailRows[1].rows[1] then
        lineH = math.max(lineH, detailRows[1].rows[1].label:GetHeight() or 0)
    end
    local rowH  = math.max(STAT_ROW_H, lineH)
    local headH = rowH + 2
    local gapH  = STAT_SECTION_GAP
    local hidden, mightTruncate = 0, false
    if onChar then
        -- What the column needs at full size, counting only what will be drawn.
        local needed = 0
        for _, group in ipairs(detailRows) do
            local shown = 0
            for _, row in ipairs(group.rows) do
                if HasStatValue(char, row.def) then shown = shown + 1 end
            end
            if shown > 0 then needed = needed + headH + shown * rowH + gapH end
        end
        -- The room between the column's top and the panel's bottom edge. y is a
        -- negative offset from the top, so -y is the distance already spent.
        local room = detail:GetHeight() + y - 4
        mightTruncate = needed > room
        if mightTruncate and needed > 0 then
            local scale = room / needed
            rowH  = math.max(lineH, math.floor(rowH * scale))
            headH = math.max(lineH + 2, math.floor(headH * scale))
            gapH  = math.max(2, math.floor(gapH * scale))
        end
    end
    -- The notice needs room too, and it is the thing that ANNOUNCES the
    -- overflow - so it drawing outside the panel is the bug wearing its own
    -- warning label. Reserved whenever truncation is possible at all, which is
    -- exactly the condition that made the column compress: the loop cannot know
    -- it will truncate until it has already spent the height, so the room has to
    -- be set aside before it starts.
    -- Measured from a POPULATED font string, never from the notice itself.
    --
    -- An auto-sized FontString with no text has no height, and the notice is
    -- created empty and cleared back to "" by every render that hides nothing -
    -- so measuring it returns 0 on the first short panel, and on every
    -- tall-then-short transition. Both the reservation and the clamp below then
    -- reserve nothing, and the notice overflows by its own full height: the
    -- original bug, surviving the fix for it, in the one lifecycle the fix did
    -- not cover.
    --
    -- `lineH` comes from a stat row's label, which is given its text at build
    -- time and never loses it, and which uses the same font object as the
    -- notice - so it is the notice's height, measured somewhere the measurement
    -- is always valid.
    --
    -- Just lineH, not max(lineH, whatever the notice says). The notice is one
    -- line in the same font and has no width constraint, so it cannot wrap and
    -- cannot exceed it; a max() would be a branch nothing can reach, which is
    -- worse than none. If this ever gains a width and wraps, that changes and
    -- this line has to change with it.
    local noticeH = lineH
    local bottomY = -detail:GetHeight() + 4
    local floorY  = bottomY + (mightTruncate and (noticeH + 2) or 0)

    for _, group in ipairs(detailRows) do
        local any = false
        for _, row in ipairs(group.rows) do
            if HasStatValue(char, row.def) then any = true; break end
        end
        -- A header needs room for itself AND one row under it, or it is a
        -- heading introducing nothing - the same rule as the empty-section case
        -- just above, reached by running out of panel instead of out of stats.
        if not any or not onChar or (y - headH - rowH) < floorY then
            group.header:Hide()
            for _, row in ipairs(group.rows) do
                if any and onChar and HasStatValue(char, row.def) then
                    hidden = hidden + 1
                end
                row.label:Hide(); row.value:Hide()
            end
        else
            group.header:ClearAllPoints()
            group.header:SetPoint("TOPLEFT", detail, "TOPLEFT", x, y)
            group.header:Show()
            y = y - headH
            for _, row in ipairs(group.rows) do
                if not HasStatValue(char, row.def) then
                    row.label:Hide(); row.value:Hide()
                elseif (y - rowH) < floorY then
                    hidden = hidden + 1
                    row.label:Hide(); row.value:Hide()
                else
                    row.label:ClearAllPoints()
                    row.label:SetPoint("TOPLEFT", detail, "TOPLEFT", x + 6, y)
                    row.value:ClearAllPoints()
                    row.value:SetPoint("TOPRIGHT", detail, "TOPLEFT", x + COLUMN_W, y)
                    row.value:SetText(FormatStatValue(char, row.def))
                    row.label:Show(); row.value:Show()
                    y = y - rowH
                end
            end
            y = y - gapH
        end
    end

    -- Clamped as well as reserved for. `y` has had a section gap taken off it
    -- since the last row was placed, so it can sit a little below the floor the
    -- rows honoured - and the reserve above only holds while the arithmetic that
    -- produced it does. This is the line that makes it true regardless.
    detail.statsMore:ClearAllPoints()
    detail.statsMore:SetPoint("TOPLEFT", detail, "TOPLEFT", x + 6,
                              math.max(y, bottomY + noticeH))
    detail.statsMore:SetText(hidden > 0
        and ("|cff888888+%d more - the window is too short|r"):format(hidden) or "")
    detail.statsMore:SetShown(hidden > 0)
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
    -- The character has to EXIST. Opening the pane on a guid that is not in the
    -- database gives a header with no name, an empty paper doll and an audit
    -- that cannot run, and returning true said it worked - so a stale guid from
    -- a card rendered before a delete drilled into nothing at all.
    if not (AltStableDB and AltStableDB[guid]) then return false end
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
    -- Pets belong to the scene alone; RenderScene puts back the ones it wants.
    HidePets()

    -- Drilled into a character: that replaces the view entirely.
    --
    -- Checked FIRST and returning, rather than hiding things afterwards. The
    -- Roster repaints on every sync, and a refresh that rebuilt the grid
    -- underneath would flicker it through the detail on each one.
    if Roster.detail then
        local char = CharacterStore()[Roster.detail]
        if char then
            BuildDetail()
            -- The scene's camp art lives on the panel backdrop, and the
            -- drill-down's own background is the MATERIAL now - translucent.
            -- Left there, Mount Hyjal came up through the stats, the slots and
            -- the figure box: the same pane that reads as glass over the world
            -- reads as a mess over a landscape. The drill-down is not the
            -- scene, so it gets the tab's own background whichever view it was
            -- opened from - over the WHOLE panel: the scene may have narrowed
            -- it for the camp list (#169 review), and this returns before the
            -- anchoring below.
            backdropTex:ClearAllPoints()
            backdropTex:SetAllPoints()
            PaintBackdrop()
            for _, card in ipairs(Roster.cards) do card:Hide() end
            if sceneBar then sceneBar:Hide() end
            if campBar then campBar:Hide() end
            if Roster.CampList and Roster.CampList.Render then Roster.CampList.Render(false) end
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
    if campBar then campBar:SetShown(View() == "scene") end
    if viewBtn then viewBtn:SetText(View() == "scene" and "Grid" or "Scene") end

    -- The camp list belongs to the scene view (#152); the scene is drawn in
    -- the width it leaves. The first camp is seeded BEFORE the list is drawn,
    -- or the first open lists no camp at all.
    if View() == "scene" then EnsureCamps() end
    if Roster.CampList and Roster.CampList.Render then Roster.CampList.Render(View() == "scene") end
    local inset = SceneInset()
    backdropTex:ClearAllPoints()
    backdropTex:SetPoint("TOPLEFT")
    backdropTex:SetPoint("BOTTOMRIGHT", -inset, 0)
    if viewBtn then
        viewBtn:ClearAllPoints()
        viewBtn:SetPoint("TOPRIGHT", -8 - inset, -BAR_TOP)
    end

    if View() == "scene" then
        -- Centred over the scene, not the whole panel.
        ApplyHintLayout(panel:GetWidth() - inset, true, -inset / 2)
        EnsureCamps()
        local camp = AltStable.SelectedCamp and AltStable.SelectedCamp()
        local _, info = RenderScene(camp)
        -- Whether ANYONE has a portrait, counted over the roster rather than
        -- taken from who was seated: nobody is seated while the panel has no
        -- size yet, which would tell a player with portraits they have none.
        local sceneChars = CharactersFor("scene")
        local withArt = 0
        for _, c in ipairs(sceneChars) do
            if CutoutFor(c) then withArt = withArt + 1 end
        end
        local name = camp and camp.name or ""
        if withArt == 0 and #sceneChars > 0 then
            -- Nobody has a portrait, so nobody stands at the fire, whatever
            -- the camp holds. Say what is actually going on.
            hintText:SetText("No portraits yet - " .. AltStable.PortraitSourceText()
                .. ". The grid shows characters without one as cards.")
            hintText:Show()
        elseif not camp then
            -- With the camp list open, it is the way; without it, the grid.
            hintText:SetText(inset > 0 and "No camp - make one with + in the list."
                or "No camp - right-click a character in the grid and choose \"Add to a new camp\".")
            hintText:Show()
        elseif info.members == 0 then
            hintText:SetText(inset > 0
                and ("%s is empty - drag a character onto one of its seats in the list."):format(name)
                or ("%s is empty - right-click a character in the grid and choose \"Add to %s\".")
                    :format(name, name))
            hintText:Show()
        else
            -- Everyone in the camp who is not at the fire, and why.
            local why = {}
            if info.noArt > 0 then why[#why + 1] = ("%d without a portrait"):format(info.noArt) end
            if info.hidden > 0 then why[#why + 1] = ("%d hidden"):format(info.hidden) end
            if info.noSeat > 0 then why[#why + 1] = ("%d without a seat while pets are shown"):format(info.noSeat) end
            if #why > 0 then
                local seated = info.members - info.gone - info.noArt - info.hidden - info.noSeat
                hintText:SetText(("showing %d of %d in %s - %s"):format(
                    seated, info.members - info.gone, name, table.concat(why, ", ")))
                hintText:Show()
            else
                hintText:Hide()
            end
        end
        return
    end

    local chars = CharactersFor("grid")
    ApplyHintLayout(panel:GetWidth(), false)
    PaintBackdrop()

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
    --
    -- PortraitSourceText is the same phrase the scene uses, so the two views
    -- cannot give different instructions (#89).
    if withArt < #chars then
        hintText:SetText(("%d of %d characters have a portrait - %s")
            :format(withArt, #chars, AltStable.PortraitSourceText()))
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

-- The window this tab needs, as Warband holds its own: the top bar's camp
-- switcher, backdrop picker and view toggle side by side (#152). Plugin tabs
-- keep whatever size the last tab left, and a narrower panel ran the backdrop
-- picker under the view toggle, so clicks landed on the wrong one.
local MIN_PANEL_W = 8 + CAMP_BAR_W + 8 + SCENE_BAR_W + 8 + VIEW_BTN_W + 8
local MIN_PANEL_H = 400
Roster.MIN_PANEL_W, Roster.MIN_PANEL_H = MIN_PANEL_W, MIN_PANEL_H
-- And room for the camp list beside a usable scene (CampList.lua), or the list
-- would step aside on a window the Roster itself chose, toggle and all.
function Roster.MinPanelW()
    local list = Roster.CampList
    if list and list.NeedsWidth then return math.max(MIN_PANEL_W, list.NeedsWidth()) end
    return MIN_PANEL_W
end
function Roster.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    local footerH  = (AltStable.LAYOUT and AltStable.LAYOUT.FOOTER_HEIGHT) or 22
    AltStable.EnsureWindowMinSize(sidebarW + 1 + Roster.MinPanelW(), titleH + MIN_PANEL_H + footerH + 2)
end

function Roster.Activate(mainFrame)
    Roster.HoldMinSize()
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
    -- The drill-down is a per-visit state, like the tab it opens on. Left set,
    -- switching to another sheet tab and coming back landed you straight in the
    -- detail pane with no grid and nothing to say why - and the only way out was
    -- a Back button for a journey you did not take.
    Roster.detail = nil
    Roster.selected = nil
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
    -- These are plain references rather than wrappers because they need no
    -- late binding: they are file-scope locals already defined above, unlike
    -- the entries around them, which have to reach `detail` or `Roster.*` as
    -- they are at call time.
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
    -- What is actually in front of what, the way the client resolves it:
    -- layer, then sublevel, then creation order. Reported rather than
    -- asserted here so the test can state the invariant - the inset is in
    -- front of its edge - without caring which of the three settles it.
    -- Where the right-hand column landed, and how wide it ended up. Both,
    -- because on a narrow frame the column narrows instead of moving out, and
    -- "it starts inside the panel" is satisfied by a column whose right edge
    -- is still outside it.
    DetailColumn = function()
        if not detail then return {} end
        local _, _, _, bx = detail.tabs[1]:GetPoint(1)
        return { x = bx, right = detail.columnRight, panel = detail:GetWidth() }
    end,
    SlotScale = SlotScale,
    -- The label the column measures its line height FROM. Exposed so a test can
    -- give it a height larger than STAT_ROW_H and check the stride follows: no
    -- font this stub models is that tall, and the floor that handles it would
    -- otherwise be code no test ever reaches.
    DetailStatFirstLabel = function()
        return detailRows and detailRows[1] and detailRows[1].rows[1]
           and detailRows[1].rows[1].label
    end,
    DetailStatsMore = function()
        if not detail or not detail.statsMore:IsShown() then return nil end
        return detail.statsMore:GetText()
    end,
    -- EVERYTHING drawn in the stats column, with the y it was placed at, so a
    -- test can ask whether any of it left the panel rather than trusting a count.
    --
    -- "Everything" is load-bearing. This used to walk headers and rows only, and
    -- the one widget it left out - the overflow notice - was the one that then
    -- drew below the panel edge, because it is appended after the loop has spent
    -- the height. A widget added to this column belongs in this walk, or the
    -- bounds tests pass without covering it.
    DetailStatRowYs = function()
        local out = {}
        for _, group in ipairs(detailRows or {}) do
            if group.header:IsShown() then
                out[#out + 1] = { select(5, group.header:GetPoint(1)) }
                out[#out].h = group.header:GetHeight()
            end
            for _, row in ipairs(group.rows) do
                if row.label:IsShown() then
                    local e = { select(5, row.label:GetPoint(1)) }
                    e.h = row.label:GetHeight()
                    out[#out + 1] = e
                end
            end
        end
        if detail and detail.statsMore:IsShown() then
            local e = { select(5, detail.statsMore:GetPoint(1)) }
            e.h = detail.statsMore:GetHeight()
            out[#out + 1] = e
        end
        return out
    end,
    SLOT_SIZE = SLOT_SIZE, SLOT_STEP = SLOT_STEP, SLOT_MIN = SLOT_MIN,
    DetailStageOrder = function()
        if not detail then return {} end
        local function of(t)
            local layer, sub = t:GetDrawLayer()
            return { layer = layer, sublevel = sub or 0, created = t._created }
        end
        return { edge = of(detail.stageEdge), inset = of(detail.stage) }
    end,
    DetailFigureBox = function()
        if not detail then return {} end
        local _, _, _, left, top = detail.stage:GetPoint(1)
        return { top = top, left = left, height = detail.stage:GetHeight(),
                 width = detail.stage:GetWidth(),
                 -- The figure's centre, which MOVES: the composition is centred
                 -- as a whole on a wide panel, so anything that has to line up
                 -- under the figure must read this rather than assume a margin.
                 centre = (left or 0) + (detail.stage:GetWidth() or 0) / 2,
                 -- Where the ART is anchored, which is a SEPARATE fact from
                 -- where the box is: the cutout and the class plate are placed
                 -- by their own SetPoint calls, and a mutation that leaves
                 -- either behind while the box moves is invisible to anything
                 -- that only looks at the box.
                 art = (detail.figure:IsShown() and select(4, detail.figure:GetPoint(1)))
                    or (detail.plate:IsShown() and select(4, detail.plate:GetPoint(1)))
                    or nil,
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
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize     = function()
            if not Roster.isActive then return end
            -- Expanding the sidebar narrows the panel while the window keeps
            -- its width: hold the floor again, as Warband does.
            Roster.HoldMinSize()
            Roster.Refresh()
        end,
        OnDeactivate = function(mainFrame) Roster.Deactivate(mainFrame) end,
        _test        = setmetatable({
            Slug = Slug, CutoutFor = CutoutFor, TexCoordsFor = TexCoordsFor,
            EffectiveTexture = EffectiveTexture,
            FigureSize = FigureSize, PickCharacters = PickCharacters,
            GridFor = GridFor, FigureHeightFor = FigureHeightFor, MAX_CARDS = MAX_CARDS,
            AllCharacters = AllCharacters, CharactersFor = CharactersFor,
            CampCast = CampCast, SeedMembers = SeedMembers, EnsureCamps = EnsureCamps,
            CampLabel = function() return campLabel and campLabel:GetText() end,
            CampBar = function() return campBar end,
            -- The card itself, so its right-click and its dimming can be
            -- driven rather than inferred from the functions behind them.
            BuildCard = BuildCard, RenderCard = RenderCard,
            HIDDEN_CARD_ALPHA = HIDDEN_CARD_ALPHA,
            RenderScene = RenderScene, Cards = function() return Roster.cards end,
            -- What the panel is ACTUALLY showing, rather than what the config
            -- says it should be. The config is what a test sets; these are what
            -- the render did with it, which is the thing a "Back lands you in
            -- the scene" assertion has to look at.
            SceneBarShown = function() return sceneBar and sceneBar:IsShown() end,
            ViewButtonText = function() return viewBtn and viewBtn:GetText() end,
            Panel = function() return panel end,
            -- The tab's own background, so a test can check this tab agrees
            -- with the others rather than trusting the helper alone.
            BackdropTex = function() return backdropTex end,
            -- The figure box's two textures, so a test can ask what they were
            -- PAINTED with and not only how they are stacked.
            DetailWell = function()
                if not detail then return nil end
                return detail.stage, detail.stageEdge
            end,
            DetailRegions = function()
                if not detail then return {} end
                return { detail:GetRegions() }
            end,
            -- What the player is actually told. Asserting the hint STRING is
            -- the only way to catch the renderer handing the count the wrong
            -- list: the composition is right either way.
            HintText = function() return hintText and hintText:GetText() end,
            HintShown = function() return hintText and hintText:IsShown() end,
            Refresh = function() return Roster.Refresh() end,
            Activate = function(main) return Roster.Activate(main) end,
            Deactivate = function(main) return Roster.Deactivate(main) end,
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
        }, { __index = function(_, k)
            -- Two side tables, because this one function sits at Lua 5.1's
            -- 60-upvalue limit (#75 crossed it).
            local v = PET_TEST[k]
            if v ~= nil then return v end
            return DETAIL_TEST[k]
        end }),
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
