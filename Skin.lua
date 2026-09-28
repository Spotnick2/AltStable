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
        -- The reading surface. See SkinPaneColor.
        pane = { 0.04, 0.05, 0.07, 0.62 },
        -- A floating popup's body. See SkinPopupTint.
        popup = { 0.05, 0.06, 0.09, 0.55 },
    },

    -- Darker, for reading. The body is a denser, cooler grey and the top-down
    -- wash is kept rather than cut: on a dark body the wash is most of what
    -- says the surface catches light instead of absorbing it.
    smoked = {
        material = true, label = "Smoked glass",
        tint = { 0.05, 0.06, 0.08, 0.62 }, grain = 0.35, wash = 0.14,
        pane = { 0.03, 0.03, 0.04, 0.80 },
        popup = { 0.03, 0.04, 0.05, 0.72 },
    },
}

local DEFAULT_SKIN = "clear"

-- The choice ON DISK, which may not be the one the window is currently wearing.
local function StoredSkin()
    local name = AltStableConfig and AltStableConfig.skin
    if type(name) == "string" and AltStable.SKINS[name] then return name end
    return DEFAULT_SKIN
end
AltStable.PendingSkinName = StoredSkin

-- The ACTIVE skin: resolved once, then held for the session.
--
-- This used to read the config on every call, which is wrong in both directions
-- at once. It cannot be captured at LOAD, because this file runs before
-- SavedVariables are read and would freeze the default. But reading it live
-- means `/alts skin flat` changes the answer immediately - while the window is
-- still made of glass - so every later hover, tab switch and lazily built panel
-- takes the flat path. A selected button keeps its glass pill, because the flat
-- path paints a backdrop and never hides that texture, and you end up wearing
-- both skins at once until you reload.
--
-- So: resolved on FIRST USE, which is when the window is built and therefore
-- after SavedVariables have loaded, and stable from then on. The command writes
-- the config and says reload; the config is the pending choice, not the live one.
local active
function AltStable.SkinName()
    if not active then active = StoredSkin() end
    return active
end

-- For tests, which drive several skins through one Lua state. Nothing in the
-- addon calls this: in game the whole point is that the active skin does not
-- change under the window's feet.
function AltStable._ResetSkinCache()
    active = nil
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

-- The colour of a READING SURFACE laid on the glass.
--
-- Not the flat palette's value. BG_MAIN and BG_FOOTER are opaque by design -
-- they were painted on an opaque window - and reusing them here puts a solid
-- black slab with hard square edges on top of the material, which is what the
-- first attempt did and what it looked like: a box pasted onto the glass rather
-- than a pane set into it.
--
-- So the panes are translucent and belong to the PRESET, which is also what
-- lets smoked be smoked: the body and the reading surface darken together.
-- Dense enough that small text over a moving world stays readable, light enough
-- that the material is still visible through it.
function AltStable.SkinPaneColor()
    return AltStable.Skin().pane
end

-- The window itself. Returns the material's region table, or nil under flat -
-- so a caller reads `if not g then <keep the old backdrop> end` rather than
-- asking about the skin twice.
-- `size` is "large" (the default) or "small", the material's two texture sets.
--
-- Everything that wants the material goes through HERE rather than calling
-- Glass.Apply directly, because this is also what pushes the preset into the
-- material's shared STYLE table - and Glass reads that at Apply time. A toast
-- that appeared before the sheet was ever built would otherwise get the file's
-- default look rather than the chosen one: clear glass in a smoked window.
function AltStable.SkinWindow(frame, size)
    if not AltStable.SkinIsGlass() then return nil end
    local preset = AltStable.Skin()

    -- Only the three body parameters: see the note above about the rim.
    local st = Glass.STYLE
    st.grain, st.wash = preset.grain, preset.wash
    -- A popup gets the denser body: see SkinPopupTint.
    st.tint = (size == "small") and preset.popup or preset.tint

    return Glass.Apply(frame, size or "large")
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
    -- The caller's colour is the FLAT palette entry, kept for the flat path and
    -- deliberately ignored here: see SkinPaneColor.
    local pane = AltStable.SkinPaneColor()
    fill:SetColorTexture(pane[1], pane[2], pane[3], pane[4])

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

-- The title band.
--
-- Two problems in one, and the first is mine: the bar paints an OPAQUE fill
-- flush to (0, 0), so under glass it owned both top corners and drew them
-- square - listed as a corner owner in the plan and then not wired, which is
-- the bug the plan existed to prevent.
--
-- The second is what it should look like instead. A darker band across the top
-- of a translucent window reads as a lid sitting on the glass; the material's
-- own body already has a top-down wash saying "light falls from above", and the
-- title band wants to agree with it rather than fight it. So it becomes a
-- LIGHTER band, brightest at the top edge, and the world shows through it more
-- than through the body below - which is what makes it read as the same slab of
-- glass, caught by the light, rather than as a separate strip.
--
-- White at low alpha rather than a grey: a grey light enough to brighten the
-- body also greys out whatever is behind it, and the point is that the scene
-- still shows through.
function AltStable.SkinTitleBand(bar, window, bg, sep)
    if not AltStable.SkinIsGlass() then return false end
    if not bar or not window or not bg then return false end

    -- SetColorTexture then SetGradient: the colour is the canvas the gradient
    -- multiplies, so a gradient on an unpainted texture shows nothing.
    bg:SetColorTexture(1, 1, 1, 1)
    bg:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0.05),   -- VERTICAL: min is the BOTTOM
        CreateColor(1, 1, 1, 0.16))   -- and max the top, where the light lands
    AltStable.SkinClipTexture(bar, bg, window)

    -- The divider was pure black, which is a hard line across a light band.
    -- White at low alpha reads as the edge of the slab instead of a gap in it.
    if sep then sep:SetColorTexture(1, 1, 1, 0.14) end
    return true
end

-- A navigation button's state fill.
--
-- ONE function for what used to be four pairs of SetBackdropColor spread over
-- SwitchSection, the button's own hover handlers and the plugin button's copy
-- of both. They have to go through one place, because under glass the fill is
-- not a backdrop any more and any site still calling SetBackdropColor would
-- quietly paint a square that is no longer there - or worse, still there.
--
-- Under flat this IS the old call, so nothing changes.
--
-- Note the mask is anchored to the PILL, the opposite of SkinPanelFill. There
-- the fill had to be trimmed by a shape it overlapped; here the fill IS the
-- shape, and a rounded selection is the point rather than a side effect.
local PILL = { left = 4, right = -6, top = -3, bottom = 3 }

function AltStable.SkinButtonFill(btn, r, g, b, a)
    if not btn then return end
    if not AltStable.SkinIsGlass() then
        if btn.SetBackdropColor then btn:SetBackdropColor(r, g, b, a or 1) end
        return
    end

    local t = btn._skinState
    if not t then
        t = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
        t:SetPoint("TOPLEFT", btn, "TOPLEFT", PILL.left, PILL.top)
        t:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", PILL.right, PILL.bottom)
        -- The SMALL set: these buttons are 52px tall, over the ~40px the
        -- material documents for it, so this is a deliberate tighter radius -
        -- a rounded rectangle rather than a capsule, which is what a nav item
        -- wants anyway.
        local S = Glass.SIZES.small
        btn._skinStateMask = Glass.Mask(btn, S.mask, S.maskMargin, 0, t)
        t:AddMaskTexture(btn._skinStateMask)
        btn._skinState = t
    end
    t:SetColorTexture(r, g, b, a or 1)
    -- Hidden rather than painted transparent, so an idle button costs nothing
    -- and so "is anything selected" is answerable.
    t:SetShown((a or 1) > 0.01)
end

-- The accent-tinted selection, and the hover.
--
-- The accent rather than a fixed colour, so this follows the existing
-- dark/class choice: gold by default, your class colour under the class theme.
-- Low alpha, because a saturated pill on translucent glass reads as a sticker.
function AltStable.SkinButtonActive(btn)
    local r, g, b = AltStable.GetAccentRGB()
    if AltStable.SkinIsGlass() then
        -- 0.15, down a third from the 0.22 first tried in game, where it read
        -- as a flat mustard block rather than a tint: at this strength enough
        -- charcoal shows through that it stays part of the glass.
        --
        -- The label stays GOLD. It was briefly turned white, on the same
        -- argument that made the title white - the pill already carries the
        -- accent - but that was treating the symptom. The label was hard to
        -- read because the pill was too strong, and with the pill corrected the
        -- gold reads fine and the accent keeps meaning one thing throughout.
        -- The title is a different case: nothing sits behind it to say what it
        -- is, so there the accent was competing rather than reinforcing.
        AltStable.SkinButtonFill(btn, r, g, b, 0.15)
    else
        AltStable.SkinButtonFill(btn, unpack(AltStable.C.BG_BTN_ACTIVE))
    end
end

function AltStable.SkinButtonHover(btn)
    if AltStable.SkinIsGlass() then
        AltStable.SkinButtonFill(btn, 1, 1, 1, 0.10)
    else
        AltStable.SkinButtonFill(btn, unpack(AltStable.C.BG_BTN_HOVER))
    end
end

function AltStable.SkinButtonIdle(btn)
    AltStable.SkinButtonFill(btn, unpack(AltStable.C.BG_BTN_IDLE))
end

-- An INACTIVE navigation label.
--
-- TEXT_DIM is 0.50, chosen against a near-black panel. On glass, with the world
-- behind it, 0.50 stops reading as "not selected" and starts reading as
-- "disabled" - which is what an outside eye said about the first screenshots.
-- Brighter under glass, unchanged under flat.
function AltStable.SkinNavDim()
    if AltStable.SkinIsGlass() then return 0.78, 0.78, 0.80 end
    return unpack(AltStable.C.TEXT_DIM)
end

-- The left accent stripe. It runs the full height of the button hard against
-- its left edge, so over a rounded selection it cuts straight across both
-- corners. The pill carries the accent now, so under glass the stripe steps
-- aside rather than being redrawn.
function AltStable.SkinStripe(stripe, show, r, g, b)
    if not stripe then return end
    if AltStable.SkinIsGlass() then stripe:Hide(); return end
    if show then
        stripe:SetColorTexture(r, g, b, 1)
        stripe:Show()
    else
        stripe:Hide()
    end
end

-- The window title.
--
-- White on glass, the accent on flat. The accent title was gold on near-black,
-- where gold is the brightest thing in the window and reads as the heading. On
-- a light translucent band it competes with the sidebar's selected item, which
-- is also the accent - two golds at the top of the window saying different
-- things. White is the quieter of the two and leaves the accent meaning
-- "selected".
function AltStable.SkinTitleColor()
    if AltStable.SkinIsGlass() then return unpack(AltStable.C.TEXT_BRIGHT) end
    return AltStable.GetAccentRGB()
end

-- A floating popup's body, which is DENSER than the window's.
--
-- The window is a big surface you look at; a toast is a small one you have to
-- read, once, while something moves behind it - and it is replacing a backdrop
-- that was 0.95 opaque. Dropping straight to the window's tint would take most
-- of the backing out from under class-coloured names and a grey dismiss hint,
-- and a text shadow does not put that back.
--
-- Still translucent, so it is still glass, and it darkens with the preset.
function AltStable.SkinPopupTint()
    return AltStable.Skin().popup
end

-- Round a texture that IS the shape - a menu entry's hover fill, say - rather
-- than one that has to be trimmed by something else.
--
-- The mask is anchored to the texture, which is the SkinButtonFill case and the
-- opposite of SkinPanelFill's. Deliberately not the nav painter itself: that
-- insets by a fixed 6px vertically, which on a 17px menu entry leaves an 11px
-- fill floating inside a 17px row, and its flat path paints a BACKDROP while a
-- menu entry paints a texture on a plain Button - so it is not a drop-in either
-- way. One small helper beats bending a control framework into shape.
--
-- The small set's slice margins are 8px against a 17px entry, so the corners
-- are squeezed rather than fully rounded. GLASS-MATERIAL.md §6 records that as
-- rendering fine, and a tighter radius is what a dense menu wants anyway.
function AltStable.SkinRoundTexture(frame, tex)
    if not AltStable.SkinIsGlass() then return false end
    if not frame or not tex or not frame.CreateMaskTexture then return false end
    if tex._skinRounded then return true end
    local S = Glass.SIZES.small
    local mask = Glass.Mask(frame, S.mask, S.maskMargin, 0, tex)
    if tex.AddMaskTexture then tex:AddMaskTexture(mask) end
    tex._skinRounded = true
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
