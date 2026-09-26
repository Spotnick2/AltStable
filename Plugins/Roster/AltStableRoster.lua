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
local MAX_CARDS     = 24      -- laid out in rows, so this is a sanity cap

-- The card grid is measured from the panel at refresh time rather than fixed:
-- the sheet is resizable and the number of characters is whatever the player
-- has, so a hardcoded row of twelve either overflows the panel or wastes it.
local MIN_CARD_W    = 110
local MIN_CARD_H    = 96      -- below this a portrait is not worth drawing

-- Scene view.
--
-- The fire's position is not guessed. Media/Scene/README.md commissions every
-- backdrop with the campfire at horizontal centre 50% and its base at about 84%
-- of the image height, and those two numbers are what let the figures stand on
-- the ground the art drew and stand AROUND the fire rather than in it. The
-- first version used a ground line picked by eye and spaced everyone evenly
-- across the panel, which put somebody in the flames and hid the one element
-- that makes the picture a campsite.
local FIRE_X         = 0.50   -- of the content width
local FIRE_BASE_Y    = 0.84   -- of the content height, from the TOP
local SCENE_FIGURE_H = 0.62   -- of panel height, for the TALLEST character

-- The gap kept clear around the fire, as a fraction of panel width.
local FIRE_CLEARANCE = 0.22

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
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-felwood.tga", w = 1024, h = 682, texh = 1024 },
    { id = "dustwallow", label = "Dustwallow Marsh",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-dustwallow.tga", w = 1024, h = 682, texh = 1024 },
    { id = "ashenvale-dusk", label = "Ashenvale at dusk",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-ashenvale-dusk.tga", w = 1024, h = 682, texh = 1024 },
    { id = "ashenvale-moonlight", label = "Ashenvale by moonlight",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-ashenvale-moonlight.tga", w = 1024, h = 682, texh = 1024 },
    { id = "elwynn", label = "Elwynn Forest",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-elwynn.tga", w = 1024, h = 682, texh = 1024 },
    { id = "mulgore", label = "Mulgore",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-mulgore.tga", w = 1024, h = 682, texh = 1024 },
    { id = "thunder-bluff", label = "Thunder Bluff",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-thunder-bluff.tga", w = 1024, h = 682, texh = 1024 },
    { id = "zephyras-isle", label = "Zephyras Isle",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-zephyras-isle.tga", w = 1024, h = 682, texh = 1024 },
    { id = "shendralas", label = "Shen'Dralas",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-shendralas.tga", w = 1024, h = 682, texh = 1024 },
    { id = "riverglades", label = "Riverglades",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-riverglades.tga", w = 1024, h = 682, texh = 1024 },
    { id = "mount-hyjal", label = "Mount Hyjal",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-mount-hyjal.tga", w = 1024, h = 682, texh = 1024 },
    { id = "dalaran", label = "Dalaran",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-dalaran.tga", w = 1024, h = 682, texh = 1024 },
    { id = "karazhan", label = "Karazhan",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-karazhan.tga", w = 1024, h = 682, texh = 1024 },
    { id = "forest", label = "Forest Camp",
      file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-forest.tga", w = 1024, h = 682, texh = 1024 },
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

-- Scaled to a common SCALE, which is what a scene needs: everyone standing on
-- one floor at their real relative heights, so a gnome is visibly a gnome.
--
-- Every cutout is supersampled to the same pixel height, so w/h says nothing
-- about how tall the character is - nativeH, recorded before that step, is the
-- only surviving record. A cutout made before sidecars existed has none, and
-- falls back to the common height it always had rather than guessing.
local function RelativeFigureSize(entry, tallestNative, maxH)
    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    if w <= 0 or h <= 0 then return maxH, maxH end

    local native = tonumber(entry and entry.nativeH)
    if not native or not tallestNative or tallestNative <= 0 then
        return maxH * (w / h), maxH
    end
    local drawnH = maxH * (native / tallestNative)
    return drawnH * (w / h), drawnH
end

-- The tallest character present, in native pixels, so everyone can be measured
-- against it. Absent sidecars simply do not vote.
local function TallestNative(chars, cutoutFor)
    local tallest
    for _, c in ipairs(chars) do
        local e = cutoutFor(c)
        local n = e and tonumber(e.nativeH)
        if n and (not tallest or n > tallest) then tallest = n end
    end
    return tallest
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

    -- Where the fire sits inside the VISIBLE part of the texture, 0..1.
    local u = (r > l) and ((FIRE_X - l) / (r - l)) or 0.5
    local v = (b > t) and ((FIRE_BASE_Y * vMax - t) / (b - t)) or FIRE_BASE_Y

    -- Cropped out of frame. Fall back to the middle of the floor rather than
    -- sending the whole cast off-screen after a fire nobody can see.
    if u < 0 or u > 1 then u = 0.5 end
    if v < 0 or v > 1 then v = FIRE_BASE_Y end

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

    local xs = {}
    for i = 1, nLeft do
        xs[#xs + 1] = leftRoom * ((i - 0.5) / nLeft)
    end
    for i = 1, nRight do
        xs[#xs + 1] = rightEdge + rightRoom * ((i - 0.5) / nRight)
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

    -- The tighter of the two sides, so nobody overlaps their neighbour.
    local slot
    if nLeft > 0 then slot = leftRoom / nLeft end
    if nRight > 0 then
        local rs = rightRoom / nRight
        slot = (slot and math.min(slot, rs)) or rs
    end

    return spots, figureH, slot or (panelW / count)
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

local function PickCharacters(limit)
    local out = {}
    for _, c in next, CharacterStore() do
        if type(c) == "table" and c.name then
            -- Hidden characters stay hidden here too (#21): one setting, every
            -- view, or "hidden" means nothing.
            if not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(c.guid)) then
                out[#out + 1] = c
            end
        end
    end
    table.sort(out, function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la > lb end
        return (a.name or "") < (b.name or "")
    end)
    while #out > (limit or MAX_CARDS) do table.remove(out) end
    return out
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------

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
    card:SetScript("OnClick", function(self) Roster.Select(self.charGuid) end)
    card:Hide()
    return card
end

local function RenderCard(card, char, cardW, cardH)
    card.charGuid = char.guid
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
    panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 1)
    panel:Hide()

    backdropTex = panel:CreateTexture(nil, "BACKGROUND")
    backdropTex:SetAllPoints()
    backdropTex:SetColorTexture(0.05, 0.05, 0.06, 1)

    hintText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintText:SetPoint("TOP", 0, -8)
    hintText:SetTextColor(0.6, 0.6, 0.6)

    -- Grid <-> Scene, and the backdrop picker. The picker only appears in scene
    -- view, because fourteen arrows over an empty grid are just clutter.
    viewBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    viewBtn:SetSize(64, 20)
    viewBtn:SetPoint("TOPRIGHT", -8, -4)
    viewBtn:SetText("Scene")
    viewBtn:SetScript("OnClick", function()
        AltStableConfig = AltStableConfig or {}
        AltStable.SetConfigValue("rosterView", View() == "scene" and "grid" or "scene")
        Roster.Refresh()
    end)

    sceneBar = CreateFrame("Frame", nil, panel)
    sceneBar:SetPoint("TOPLEFT", 8, -4)
    sceneBar:SetSize(240, 20)
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

-- Who stands around the fire: the highest level first, then item level, capped.
-- Only characters with a portrait, because a class card pasted into a campsite
-- looks like a mistake rather than a placeholder.
local function SceneCast(chars, cutoutFor, limit)
    local out = {}
    for _, c in ipairs(chars) do
        if cutoutFor(c) then out[#out + 1] = c end
    end
    table.sort(out, function(a, b)
        local la, lb = a.level or 0, b.level or 0
        if la ~= lb then return la > lb end
        local ia, ib = a.ilvl or 0, b.ilvl or 0
        if ia ~= ib then return ia > ib end
        return (a.name or "") < (b.name or "")
    end)
    while #out > (limit or SCENE_CAST) do table.remove(out) end
    return out
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
    local tallest = TallestNative(cast, CutoutFor)
    local withArt = 0

    for i, card in ipairs(Roster.cards) do
        local char = cast[i]
        local cut = char and CutoutFor(char)
        local spot = spots[i]
        if char and cut and spot then
            withArt = withArt + 1
            local w, h = RelativeFigureSize(cut, tallest, figureH)
            w, h = w * spot.scale, h * spot.scale
            -- Narrow the slot, not the figure: shrinking a wide capture to fit
            -- made it SHORTER than its neighbours, which is the height
            -- discrepancy the first version showed - a scaling artefact
            -- masquerading as a short character.
            if w > slot then
                local overflow = w / slot
                w, h = w / overflow, h / overflow
            end

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

            card.label:SetWidth(math.max(slot, w))
            card.label:SetText(AltStable.ClassColor
                and (AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r")
                or (char.name or "?"))
            card.sub:SetWidth(math.max(slot, w))
            card.sub:SetText(("level %d"):format(char.level or 0))
            card.highlight:SetShown(Roster.selected == char.guid)
            card.charGuid = char.guid
            card:Show()
        else
            card:Hide()
        end
    end

    return withArt, #chars
end

-- Exposed for the hint below: how many the scene chose to show.
local function SceneCastSize(chars)
    return #SceneCast(chars, CutoutFor, SCENE_CAST)
end

function Roster.Select(guid)
    Roster.selected = guid
    for _, card in ipairs(Roster.cards) do
        if card:IsShown() then card.highlight:SetShown(card.charGuid == guid) end
    end
end

function Roster.Refresh()
    if not panel then return end
    local chars = PickCharacters(MAX_CARDS)

    if sceneBar then sceneBar:SetShown(View() == "scene") end
    if viewBtn then viewBtn:SetText(View() == "scene" and "Grid" or "Scene") end

    if View() == "scene" then
        local shown, total = RenderScene(chars)
        if shown < total then
            hintText:SetText(("showing %d of %d - highest level first; the grid shows them all")
                :format(shown, total))
            hintText:Show()
        else
            hintText:Hide()
        end
        return
    end

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
    if mainFrame.totalsBar    then mainFrame.totalsBar:Hide()    end
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
    if mainFrame.totalsBar    then mainFrame.totalsBar:Show()    end
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
        _test        = {
            Slug = Slug, CutoutFor = CutoutFor, TexCoordsFor = TexCoordsFor,
            FigureSize = FigureSize, PickCharacters = PickCharacters,
            GridFor = GridFor, FigureHeightFor = FigureHeightFor, MAX_CARDS = MAX_CARDS,
            HookRefresh = HookRefresh, BackdropTexCoords = BackdropTexCoords,
            SceneLayout = SceneLayout, SCENE_BACKDROPS = SCENE_BACKDROPS,
            SceneCast = SceneCast, RelativeFigureSize = RelativeFigureSize,
            FireAnchor = FireAnchor, FIRE_CLEARANCE = FIRE_CLEARANCE,
            FIRE_X = FIRE_X, FIRE_BASE_Y = FIRE_BASE_Y,
            TallestNative = TallestNative, SCENE_CAST = SCENE_CAST,
            View = View, CurrentScene = CurrentScene,
            MIN_CARD_W = MIN_CARD_W, MAX_CARD_W = MAX_CARD_W,
        },
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
