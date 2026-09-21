------------------------------------------------------------
-- AltStable/Theme.lua
--
-- ElvUI-inspired neutral dark palette and theming system.
-- Loaded before every other UI file (via .toc; only Compat.lua precedes it)
-- so they can all use it.
--
-- Dark theme: pure charcoal/black — NO blue or purple tints.
--   ElvUI defaults: border=0,0,0 | bg=0.10,0.10,0.10
--                   fade-bg=0.06,0.06,0.06 (a=0.80)
-- Class theme: current player class color replaces gold accent.
------------------------------------------------------------

AltStable = AltStable or {}

------------------------------------------------------------
-- Media path (central constant for all addon textures)
------------------------------------------------------------

AltStable.MEDIA_PATH = "Interface\\AddOns\\AltStable\\Media\\"

------------------------------------------------------------
-- Neutral charcoal palette  (R == G == B for all BG values)
-- Keeping equal channels eliminates the blue/purple cast from
-- the previous pass which had higher B values than R/G.
------------------------------------------------------------

AltStable.C = {
    -- Panel backgrounds — pure neutral gray scale
    BG_MAIN      = { 0.06, 0.06, 0.06, 0.96 },  -- main window (charcoal)
    BG_SIDEBAR   = { 0.08, 0.08, 0.08, 1.00 },  -- sidebar panel
    BG_HEADER    = { 0.11, 0.11, 0.11, 1.00 },  -- column header row
    BG_ROW_ODD   = { 0.06, 0.06, 0.06, 1.00 },  -- odd body rows
    BG_ROW_EVEN  = { 0.09, 0.09, 0.09, 1.00 },  -- even body rows
    BG_GROUP     = { 0.13, 0.13, 0.13, 1.00 },  -- realm group header
    BG_FOOTER    = { 0.08, 0.08, 0.08, 1.00 },  -- totals bar

    -- Sidebar button states — idle transparent, hover/active neutral gray
    BG_BTN_IDLE  = { 0,    0,    0,    0    },   -- fully transparent
    BG_BTN_HOVER = { 0.16, 0.16, 0.16, 0.60 },  -- neutral subtle tint
    BG_BTN_ACTIVE= { 0.20, 0.20, 0.20, 0.80 },  -- visible active state

    -- Borders and separators
    BORDER       = { 0, 0, 0, 1 },              -- pure black (ElvUI default)
    SEP          = { 0.22, 0.22, 0.22, 1 },     -- neutral mid-tone separator (structural borders)
    GRIDLINE     = { 0.5, 0.5, 0.5, 0.12 },     -- faint neutral vertical column gridline (spreadsheet feel)

    -- Text hierarchy
    TEXT_DIM     = { 0.50, 0.50, 0.50 },        -- secondary, inactive
    TEXT_NORM    = { 0.82, 0.82, 0.82 },        -- body text
    TEXT_BRIGHT  = { 1.00, 1.00, 1.00 },        -- headers, selected

    -- Dark-theme accent defaults
    ACCENT       = { 1.00, 0.82, 0.00 },        -- WoW gold/yellow
    ACCENT2      = { 0.00, 0.80, 1.00 },        -- cyan (intentional, for iLvl/links only)

    -- Structural / semantic tokens. Centralized so a palette re-skin in this
    -- file reaches every tab (incl. the Roster plugin) instead of leaving
    -- hardcoded colors behind. Values match what was previously inlined, so
    -- adding these is a zero-visual-change dedup (issue #18).
    BG_BADGE     = { 0.10, 0.10, 0.10, 0.95 },  -- stat badge / readout backdrops
    TEXT_VALUE   = { 0.95, 0.95, 0.95 },        -- numeric readout values (iLvl, GS)
    TEXT_MUTED   = { 0.667, 0.667, 0.667 },     -- muted grey label runs (== |cffaaaaaa)
    POSITIVE     = { 0.45, 1.00, 0.45 },        -- "good" state (cooldown Ready, etc.)

    -- Class row tint alpha
    CLASS_TINT_ALPHA = 0.08,
}

------------------------------------------------------------
-- Class color helpers
------------------------------------------------------------

function AltStable.GetClassRGB(class)
    if not class then return 0.5, 0.5, 0.5 end
    local info = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class:upper()]
    if info then return info.r, info.g, info.b end
    return 0.5, 0.5, 0.5
end

function AltStable.ClassColor(class)
    if not class then return "" end
    local info = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class:upper()]
    if info then
        return string.format("|cff%02x%02x%02x", info.r*255, info.g*255, info.b*255)
    end
    return ""
end

------------------------------------------------------------
-- Accent color (theme-aware)
------------------------------------------------------------

-- Build a "|cffRRGGBB" escape from a {r,g,b} palette entry, so inline colored
-- text runs can reference the palette instead of hardcoding hex (issue #18).
function AltStable.HexColor(c)
    return string.format("|cff%02x%02x%02x", (c[1] or 0) * 255, (c[2] or 0) * 255, (c[3] or 0) * 255)
end

function AltStable.GetAccentRGB()
    local theme = AltStableConfig and AltStableConfig.theme or "dark"
    if theme == "class" then
        local _, class = UnitClass("player")
        if class then return AltStable.GetClassRGB(class) end
    end
    local a = AltStable.C.ACCENT
    return a[1], a[2], a[3]
end

function AltStable.GetAccent2RGB()
    local theme = AltStableConfig and AltStableConfig.theme or "dark"
    if theme == "class" then
        local r, g, b = AltStable.GetAccentRGB()
        return math.min(r + 0.15, 1), math.min(g + 0.15, 1), math.min(b + 0.15, 1)
    end
    local a = AltStable.C.ACCENT2
    return a[1], a[2], a[3]
end

------------------------------------------------------------
-- Backdrop helper — 1px solid black border (ElvUI/MRT pattern)
------------------------------------------------------------

function AltStable.ApplyBackdrop(f, r, g, b, a)
    if not f or not f.SetBackdrop then return end
    f:SetBackdrop({
        bgFile   = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(r or 0, g or 0, b or 0, a or 1)
    f:SetBackdropBorderColor(0, 0, 0, 1)
end

function AltStable.ApplyBGOnly(f, r, g, b, a)
    if not f or not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8", tile = true, tileSize = 8 })
    f:SetBackdropColor(r or 0, g or 0, b or 0, a or 1)
end

------------------------------------------------------------
-- Faction-specific gear slot icons
-- Reads the player's faction at call-time so it works
-- correctly even if called before PLAYER_LOGIN fires.
------------------------------------------------------------

function AltStable.GetGearIconPath(slug)
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "Alliance"
    local folder  = (faction == "Horde") and "Horde" or "Alliance"
    return AltStable.MEDIA_PATH .. "Icons\\Gear\\" .. folder .. "\\" .. slug .. ".tga"
end

------------------------------------------------------------
-- Scale API
------------------------------------------------------------

function AltStable.SetScale(scale)
    scale = math.max(0.75, math.min(1.25, tonumber(scale) or 1.0))
    AltStableConfig      = AltStableConfig or {}
    AltStable.SetConfigValue("scale", scale)
    local f = _G["AltStableSheet"]
    if f then f:SetScale(scale) end
end

------------------------------------------------------------
-- Theme change callbacks
------------------------------------------------------------

AltStable._themeCallbacks = AltStable._themeCallbacks or {}

function AltStable.RegisterThemeCallback(fn)
    table.insert(AltStable._themeCallbacks, fn)
end

function AltStable.ApplyTheme()
    for _, fn in ipairs(AltStable._themeCallbacks) do
        pcall(fn)
    end
end

