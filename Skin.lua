------------------------------------------------------------
-- AltStable/Skin.lua — which material the window is made of (#97)
--
-- Loads after Glass.lua and Theme.lua: it needs the material and the palette,
-- and nothing needs it until SheetUI builds the window.
--
-- THE FLAT PATH IS THE UNTOUCHED STATUS QUO. `skin = "flat"` does not select a
-- second palette to keep in step with the first - it means "do not apply a
-- material", and every existing ApplyBackdrop/ApplyBGOnly call runs exactly as
-- it did before this file existed. That is what makes the revert cheap, and it
-- is why this is not a theme system: there is one palette, `AltStable.C`, and
-- one question on top of it.
--
-- The presets are PARAMETERS, not palettes. Clear and smoked differ by about
-- six numbers against one code path, which is why having both costs almost
-- nothing. The rim is deliberately NOT among them: GLASS-MATERIAL.md ranks it
-- the single biggest lever for reading as glass rather than as plastic, and
-- darkening it with the body is exactly how a smoked preset turns into a
-- smoked plastic case.
--
-- Applied at LOGIN, not live. Glass.Apply creates regions every time it is
-- called and has no teardown, dedup or update path, so switching in place would
-- mean caching material instances, hiding every region, restoring the old fills
-- and repainting tint/grain/wash - a lot of machinery for a setting changed
-- once. `/alts skin <name>` saves and asks for a /reload.
------------------------------------------------------------

AltStable = AltStable or {}

local Glass = AltStable.Glass

AltStable.SKINS = {
    -- No material. Everything renders the way it did before #97.
    flat = { material = false, label = "Flat" },

    -- The GlassUnitFrames look, unchanged: cool, light, translucent.
    clear = {
        material = true, label = "Clear glass",
        tint = { 0.13, 0.16, 0.22, 0.24 }, grain = 0.45, wash = 0.18,
    },

    -- Darker, for reading. The body is a denser, cooler grey and the top-down
    -- wash is kept rather than cut: on a dark body the wash is most of what
    -- says the surface catches light instead of absorbing it.
    smoked = {
        material = true, label = "Smoked glass",
        tint = { 0.05, 0.06, 0.08, 0.62 }, grain = 0.35, wash = 0.14,
    },
}

local DEFAULT_SKIN = "clear"

-- Resolved at CALL time, never captured at load: this file loads before
-- SavedVariables are read, so a value cached here would be the default for the
-- whole session no matter what is on disk.
function AltStable.SkinName()
    local name = AltStableConfig and AltStableConfig.skin
    if type(name) == "string" and AltStable.SKINS[name] then return name end
    return DEFAULT_SKIN
end

function AltStable.Skin()
    return AltStable.SKINS[AltStable.SkinName()]
end

-- The one question the rest of the addon asks.
function AltStable.SkinIsGlass()
    return AltStable.Skin().material == true and Glass ~= nil
end

------------------------------------------------------------
-- Applying it
------------------------------------------------------------

-- The window itself. Returns the material's region table, or nil under flat -
-- so a caller reads `if not g then <keep the old backdrop> end` rather than
-- asking about the skin twice.
function AltStable.SkinWindow(frame)
    if not AltStable.SkinIsGlass() then return nil end
    local preset = AltStable.Skin()

    -- Applied to the shared STYLE table, which Glass reads at Apply time. Only
    -- the three body parameters: see the note above about the rim.
    local st = Glass.STYLE
    st.tint, st.grain, st.wash = preset.tint, preset.grain, preset.wash

    return Glass.Apply(frame, "large")
end

-- A background fill for a panel that reaches into the window's rounded corners.
--
-- This is the whole reason phase 1 could not be "the window and nothing else".
-- The title bar, the sidebar, the totals bar and every plugin panel that anchors
-- to BOTTOMRIGHT (0, 1) sits flush to the frame edge, so a rounded body behind
-- them is a rounded body with its corners drawn straight back on.
--
-- Returns true when it painted the fill, false when the caller should use its
-- own ApplyBGOnly as before.
--
-- A BACKDROP CANNOT BE MASKED. ApplyBGOnly paints through SetBackdrop, which is
-- not a texture, so a corner-owning panel cannot simply keep its backdrop and
-- gain a mask - under glass the fill has to BE a texture. That is the whole
-- reason this function exists rather than a mask-only helper.
function AltStable.SkinPanelFill(frame, window, c)
    if not AltStable.SkinIsGlass() then return false end
    if not frame or not window or not frame.CreateTexture then return false end

    local fill = frame._skinFill
    if not fill then
        fill = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        fill:SetAllPoints(frame)
        frame._skinFill = fill
    end
    c = c or AltStable.C.BG_MAIN
    fill:SetColorTexture(c[1], c[2], c[3], c[4] or 1)

    local S = Glass.SIZES.large
    -- Masked to the WINDOW's shape, not its own. A mask anchored to the fill
    -- would round that fill into a separate capsule floating inside the glass;
    -- anchored to the window, it clips the fill exactly where the two overlap -
    -- which is what a corner needs and what a border would get wrong.
    --
    -- The mask is owned by `frame`, because a mask only affects textures of the
    -- frame that created it. That is why this cannot be done once on the window
    -- and why every corner-owning panel needs its own call.
    if not frame._skinMask then
        frame._skinMask = Glass.Mask(frame, S.mask, S.maskMargin, 0, window)
    end
    -- Attached ONCE. AddMaskTexture appends, so guarding only the mask's
    -- creation still stacks a second reference to the same mask on every call -
    -- and the Raids tab re-paints its fills from ApplyTheme on every theme
    -- change, so this is a real path rather than a defensive one.
    if fill.AddMaskTexture and not fill._skinMasked then
        fill:AddMaskTexture(frame._skinMask)
        fill._skinMasked = true
    end
    return true
end

-- The same clipping for a panel that ALREADY paints with a texture rather than
-- a backdrop, so there is nothing to replace - only to clip. Options is the one
-- that does this today.
function AltStable.SkinClipTexture(frame, tex, window)
    if not AltStable.SkinIsGlass() then return false end
    if not frame or not tex or not window or not frame.CreateMaskTexture then
        return false
    end
    local S = Glass.SIZES.large
    if not frame._skinMask then
        frame._skinMask = Glass.Mask(frame, S.mask, S.maskMargin, 0, window)
    end
    if tex.AddMaskTexture and not tex._skinMasked then
        tex:AddMaskTexture(frame._skinMask)
        tex._skinMasked = true
    end
    return true
end

-- Text that is now sitting on glass with the world behind it.
-- GLASS-MATERIAL.md §6: a shadow is not decoration here, it is what keeps a
-- label legible when something bright passes behind it.
function AltStable.SkinText(fs)
    if not AltStable.SkinIsGlass() then return end
    if not fs or not fs.SetShadowOffset then return end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.9)
end
