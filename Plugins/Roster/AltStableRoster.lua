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
local MAX_CARD_W    = 170
local FIGURE_RATIO  = 0.94    -- of the space left ABOVE the name block

local Roster = { cards = {}, selected = nil }
AltStable = AltStable or {}
AltStable.RosterPlugin = Roster

local panel, backdropTex, hintText

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

-- Scaled to a common height so a gnome and a tauren stand on the same ground
-- line, which is the whole visual point of a lineup.
local function FigureSize(entry, targetH)
    local w = tonumber(entry and entry.w) or 0
    local h = tonumber(entry and entry.h) or 0
    if w <= 0 or h <= 0 then return targetH, targetH end
    return targetH * (w / h), targetH
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

    for i = 1, MAX_CARDS do
        Roster.cards[i] = BuildCard(panel, i)
    end
    return panel
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
            HookRefresh = HookRefresh,
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
