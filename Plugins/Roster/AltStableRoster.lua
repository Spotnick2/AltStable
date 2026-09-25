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

local CARD_W        = 150     -- one column of the lineup
local CARD_GAP      = 10
local FIGURE_H      = 260     -- the height every cutout is scaled to
local NAME_H        = 16
local PAD_X, PAD_Y  = 16, 14
local MAX_CARDS     = 12      -- one row; a second row is for the scene work

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

local function CutoutFor(char)
    local manifest = AltStableCutoutManifest
    if type(manifest) ~= "table" or type(char) ~= "table" then return nil end
    local slug = Slug(char.name)
    return slug and manifest[slug] or nil
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
    card:SetSize(CARD_W, FIGURE_H + NAME_H + 8)
    card:SetPoint("BOTTOMLEFT", PAD_X + (index - 1) * (CARD_W + CARD_GAP), PAD_Y + 24)

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
    card.plate:SetSize(CARD_W - 24, FIGURE_H * 0.62)

    card.icon = card:CreateTexture(nil, "OVERLAY")
    card.icon:SetSize(48, 48)
    card.icon:SetPoint("CENTER", card.plate, "CENTER", 0, 0)

    card.label = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.label:SetPoint("BOTTOM", 0, 2)
    card.label:SetWidth(CARD_W)
    card.label:SetJustifyH("CENTER")

    card:SetScript("OnEnter", function(self) self.highlight:Show() end)
    card:SetScript("OnLeave", function(self)
        if Roster.selected ~= self.charGuid then self.highlight:Hide() end
    end)
    card:SetScript("OnClick", function(self) Roster.Select(self.charGuid) end)
    card:Hide()
    return card
end

local function RenderCard(card, char)
    card.charGuid = char.guid
    card.label:SetText(("%s|cff808080  %d|r"):format(
        AltStable.ClassColor and (AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r")
            or (char.name or "?"),
        char.level or 0))

    local entry = CutoutFor(char)
    if entry and entry.file then
        local w, h = FigureSize(entry, FIGURE_H)
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
        if AltStable.ClassIcon then
            card.icon:SetTexture(AltStable.ClassIcon(char.class))
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

    panel = CreateFrame("Frame", nil, mainFrame)
    panel:SetPoint("TOPLEFT", 8, -52)
    panel:SetPoint("BOTTOMRIGHT", -8, 8)
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

    local withArt = 0
    for i, card in ipairs(Roster.cards) do
        local char = chars[i]
        if char then
            RenderCard(card, char)
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

function Roster.Activate(mainFrame)
    BuildPanel(mainFrame)
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
    if mainFrame.totalsBar    then mainFrame.totalsBar:Show()    end
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------

function Roster._Bootstrap()
    if not AltStable or not AltStable.RegisterPlugin then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Roster]|r AltStable not found.")
        return
    end
    AltStable.RegisterPlugin({
        id           = ADDON_ID,
        label        = "Roster",
        icon         = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\roster.tga",
        _isPlugin    = true,
        OnActivate   = function(mainFrame) Roster.Activate(mainFrame) end,
        OnDeactivate = function(mainFrame) Roster.Deactivate(mainFrame) end,
        _test        = {
            Slug = Slug, CutoutFor = CutoutFor, TexCoordsFor = TexCoordsFor,
            FigureSize = FigureSize, PickCharacters = PickCharacters,
            MAX_CARDS = MAX_CARDS, FIGURE_H = FIGURE_H,
        },
    })
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end
    C_Timer.After(1, Roster._Bootstrap)
end)
