-- Glass.lua: the "liquid glass" material.
--
-- A COPY of GlassUnitFrames/Glass.lua, which is written to be copied - it needs
-- only its textures and a media path and knows nothing about units, events or
-- secure frames. The canonical write-up, the parameters and the reasoning
-- behind each layer live there, in docs/GLASS-MATERIAL.md, along with the table
-- of client features it relies on and the measurements behind them.
--
-- THE TWO ARE MEANT TO STAY IN STEP. WoW gives no clean way to share Lua across
-- two independent addons, so this is a copy rather than a dependency, and a
-- copy is a thing that drifts. Changes to the material belong upstream first.
--
-- Diverging from upstream, deliberately:
--   * namespace AltStable.Glass, not GlassUF.Glass
--   * MEDIA is Media\Glass\, so the material's art sits apart from the
--     addon's own icons and cutouts
--
-- NOT part of this addon's supported subset: Glass.Bar, Glass.Sheen and the
-- font registry. Their definitions come along because this is a copy, but the
-- textures they name (bar_mask, bar_fill, gloss, bar_edge, sheen2) are not
-- shipped here, so calling them would draw nothing. Copy the art too if a use
-- appears.
--
-- Layer stack on a host frame, bottom to top:
--   shadow -> tint -> grain -> wash      (on the host, masked to a rounded rect)
--   ...caller's content frames...        (host level + 2)
--   dark rim -> sheen -> rim -> text     (on g.top, host level + 10)

-- The addon name the client passes to this file, NOT AltStable.MEDIA_PATH:
-- Theme.lua owns that and loads after this one, and reaching forward to it
-- would make the load order load-bearing for no gain.
local ADDON = ...
AltStable = AltStable or {}
local Glass = {}
AltStable.Glass = Glass

Glass.MEDIA = "Interface\\AddOns\\" .. (ADDON or "AltStable") .. "\\Media\\Glass\\"
local MASK_WRAP = "CLAMPTOBLACKADDITIVE"

-- Texture sets. Slice margins are in texture pixels and must match the
-- generator; "small" is for anything under ~40px tall. `inset` is where
-- content (bars) starts inside the bevel.
Glass.SIZES = {
    large = { mask = "body_mask", maskMargin = 16, rim = "rim5", dark = "rim_dark5", rimMargin = 16,
              shadow = "shadow", shadowMargin = 48, shadowPad = { -22, 20, 22, -26 }, inset = 6 },
    small = { mask = "body_mask_small", maskMargin = 8, rim = "rim5_small", dark = "rim_dark5_small", rimMargin = 8,
              shadow = "shadow_small", shadowMargin = 24, shadowPad = { -12, 10, 12, -14 }, inset = 3 },
}

-- The settled look: probe style 4 (docs/FOREVER-PROBE.md, third run) with the
-- thinner, dimmer rim5 from the outside review.
Glass.STYLE = {
    tint = { 0.13, 0.16, 0.22, 0.24 },   -- cool, light: glass, not smoked plastic
    grain = 0.45,                        -- faint frost; cannot track the scene behind
    wash = 0.18,                         -- top-down white gradient inside the body
    gloss = 0.45,                        -- ADD highlight on bars
    innerShadow = 0.35,                  -- bottom shade on bars
    sheenAlpha = 0.8,
}

-- Client-shipped fonts only. Arial Narrow runs small, so it gets a point more.
Glass.FONTS = {
    arial = { file = "Fonts\\ARIALN.TTF",   bump = 1 },
    friz  = { file = "Fonts\\FRIZQT__.TTF", bump = 0 },
}
Glass.fontKey = "arial"
local fontStrings = {}

local function slice(tex, m)
    tex:SetTextureSliceMargins(m, m, m, m)
    local modes = Enum and Enum.UITextureSliceMode
    tex:SetTextureSliceMode((modes and modes.Stretched) or 0)
end

-- A 9-sliced rounded mask owned by `host`, covering `anchor` (default: host)
-- inset by `inset` px. A mask masks textures of its own frame: give a child
-- its own mask anchored to the shape it must follow.
function Glass.Mask(host, file, margin, inset, anchor)
    local m = host:CreateMaskTexture()
    m:SetTexture(Glass.MEDIA .. file, MASK_WRAP, MASK_WRAP)
    inset = inset or 0
    anchor = anchor or host
    m:SetPoint("TOPLEFT", anchor, "TOPLEFT", inset, -inset)
    m:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -inset, inset)
    slice(m, margin)
    return m
end

-- Apply the material to `host`. Returns a table of the regions it made:
-- g.top is the frame to parent text and anything that must sit above the rim.
function Glass.Apply(host, size)
    local S = Glass.SIZES[size or "large"]
    local st = Glass.STYLE
    local g = { size = size or "large" }

    local sh = host:CreateTexture(nil, "BACKGROUND", nil, -8)
    sh:SetTexture(Glass.MEDIA .. S.shadow)
    sh:SetPoint("TOPLEFT", host, "TOPLEFT", S.shadowPad[1], S.shadowPad[2])
    sh:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", S.shadowPad[3], S.shadowPad[4])
    slice(sh, S.shadowMargin)
    g.shadow = sh

    g.mask = Glass.Mask(host, S.mask, S.maskMargin)

    local tint = host:CreateTexture(nil, "BACKGROUND", nil, -6)
    tint:SetAllPoints(host)
    tint:SetColorTexture(st.tint[1], st.tint[2], st.tint[3], st.tint[4])
    tint:AddMaskTexture(g.mask)
    g.tint = tint

    local grain = host:CreateTexture(nil, "BACKGROUND", nil, -5)
    grain:SetAllPoints(host)
    grain:SetTexture(Glass.MEDIA .. "grain", "REPEAT", "REPEAT")
    grain:SetHorizTile(true)
    grain:SetVertTile(true)
    grain:SetAlpha(st.grain)
    grain:AddMaskTexture(g.mask)
    g.grain = grain

    local wash = host:CreateTexture(nil, "BACKGROUND", nil, -4)
    wash:SetAllPoints(host)
    wash:SetColorTexture(1, 1, 1, 1)
    wash:SetGradient("VERTICAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, st.wash))
    wash:AddMaskTexture(g.mask)
    g.wash = wash

    local top = CreateFrame("Frame", nil, host)
    top:SetAllPoints(host)
    top:SetFrameLevel(host:GetFrameLevel() + 10)
    g.top = top

    local dark = top:CreateTexture(nil, "OVERLAY", nil, 4)
    dark:SetTexture(Glass.MEDIA .. S.dark)
    dark:SetAllPoints(top)
    slice(dark, S.rimMargin)
    g.dark = dark

    local rim = top:CreateTexture(nil, "OVERLAY", nil, 6)
    rim:SetTexture(Glass.MEDIA .. S.rim)
    rim:SetAllPoints(top)
    slice(rim, S.rimMargin)
    g.rim = rim

    return g
end

-- A content frame level for things drawn between the body and the rim.
function Glass.ContentLevel(host)
    return host:GetFrameLevel() + 2
end

-- Content inset (px) inside the bevel for this material size.
function Glass.Inset(size)
    return Glass.SIZES[size or "large"].inset
end

-- A glass StatusBar: masked rounded fill, ADD gloss, inner shadow, thin edge.
-- Colour it with bar:SetStatusBarColor(r, g, b). Values may be secret:
-- SetMinMaxValues/SetValue take them without Lua touching them.
-- The gloss, shade and edge live on bar.overlay (frame level bar + 2), so
-- anything added over the fill at level bar + 1 (e.g. heal prediction) sits
-- UNDER the glass layers, like the fill itself.
function Glass.Bar(parent, height)
    local st = Glass.STYLE
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local mask = Glass.Mask(bar, "bar_mask", 8)
    bar.glassMask = mask

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetColorTexture(0, 0, 0, 0.35)
    bg:AddMaskTexture(mask)

    bar:SetStatusBarTexture(Glass.MEDIA .. "bar_fill")
    bar:GetStatusBarTexture():AddMaskTexture(mask)

    local over = CreateFrame("Frame", nil, bar)
    over:SetAllPoints(bar)
    over:SetFrameLevel(bar:GetFrameLevel() + 2)
    bar.overlay = over
    local omask = Glass.Mask(over, "bar_mask", 8)

    local gloss = over:CreateTexture(nil, "OVERLAY", nil, 1)
    gloss:SetAllPoints(bar)
    gloss:SetTexture(Glass.MEDIA .. "gloss")
    gloss:SetBlendMode("ADD")
    gloss:SetAlpha(st.gloss)
    gloss:AddMaskTexture(omask)

    local inner = over:CreateTexture(nil, "OVERLAY", nil, 2)
    inner:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
    inner:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
    inner:SetHeight(math.max(3, math.floor(height * 0.45)))
    -- Keep the shade at 45% when the bar is resized later (the player's
    -- bars shrink while its inside cast row shows).
    hooksecurefunc(bar, "SetHeight", function(_, h)
        if type(h) == "number" then inner:SetHeight(math.max(3, math.floor(h * 0.45))) end
    end)
    inner:SetColorTexture(1, 1, 1, 1)
    inner:SetGradient("VERTICAL", CreateColor(0, 0, 0, st.innerShadow), CreateColor(0, 0, 0, 0))
    inner:AddMaskTexture(omask)

    local edge = over:CreateTexture(nil, "OVERLAY", nil, 3)
    edge:SetAllPoints(bar)
    edge:SetTexture(Glass.MEDIA .. "bar_edge")
    slice(edge, 8)

    -- Keep the overlay two levels above the bar when the caller moves the bar.
    hooksecurefunc(bar, "SetFrameLevel", function(self, level) over:SetFrameLevel(level + 2) end)
    return bar
end

-- The client eases a StatusBar to its new value itself (secret values
-- included: Lua never sees the in-between). Enum names are not in the API
-- dump, so fall back to an instant change when they are missing.
function Glass.Smooth()
    local e = Enum and Enum.StatusBarInterpolation
    return e and e.ExponentialEaseOut or nil
end

-- Set a bar's range and value, eased unless `snap`. Both calls take the same
-- interpolation, so a max change doesn't jump the fill and then slide. If the
-- client rejects the eased call, fall back to an instant one rather than
-- leaving the bar frozen.
function Glass.SetBar(bar, maxValue, value, snap)
    local interp = (not snap) and Glass.Smooth() or nil
    if interp and pcall(function()
        bar:SetMinMaxValues(0, maxValue, interp)
        bar:SetValue(value, interp)
    end) then return end
    bar:SetMinMaxValues(0, maxValue)
    bar:SetValue(value)
end

-- A diagonal highlight that sweeps across the body once per Play(). Clipped
-- by its own mask on g.top, which stays put while the texture translates.
-- Returns the AnimationGroup; call :Stop() then :Play() to sweep.
function Glass.Sheen(g, host, width, height)
    local S = Glass.SIZES[g.size]
    local mask = Glass.Mask(g.top, S.mask, S.maskMargin)
    local s = g.top:CreateTexture(nil, "OVERLAY", nil, 5)
    s:SetTexture(Glass.MEDIA .. "sheen2")
    s:SetSize(math.floor(width * 0.5), height + 20)
    s:SetPoint("RIGHT", g.top, "LEFT", 0, 0)
    s:SetBlendMode("ADD")
    s:SetAlpha(0)
    s:AddMaskTexture(mask)

    local ag = s:CreateAnimationGroup()
    local move = ag:CreateAnimation("Translation")
    move:SetOffset(width + math.floor(width * 0.5), 0)
    move:SetDuration(0.9)
    move:SetSmoothing("IN_OUT")
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(Glass.STYLE.sheenAlpha)
    fadeIn:SetDuration(0.25)
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(Glass.STYLE.sheenAlpha)
    fadeOut:SetToAlpha(0)
    fadeOut:SetStartDelay(0.65)
    fadeOut:SetDuration(0.25)
    return ag
end

-- A FontString in the current glass font, tracked so Glass.SetFont can
-- restyle every one of them later.
function Glass.Font(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", nil, 7)
    local f = Glass.FONTS[Glass.fontKey] or Glass.FONTS.arial
    fs:SetFont(f.file, size + f.bump, "")
    fs:SetShadowColor(0, 0, 0, 0.9)
    fs:SetShadowOffset(1, -1)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    table.insert(fontStrings, { fs = fs, size = size })
    return fs
end

function Glass.SetFont(key)
    local f = Glass.FONTS[key]
    if not f then return false end
    Glass.fontKey = key
    for _, e in ipairs(fontStrings) do e.fs:SetFont(f.file, e.size + f.bump, "") end
    return true
end
