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
        -- Panels. See SkinPaneColor.
        pane = { 0.04, 0.05, 0.07, 0.62 },
        -- The TABLE, which is a different job. See SkinDataColor.
        data = { 0.05, 0.06, 0.08, 1.00 },
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
        data = { 0.04, 0.04, 0.05, 1.00 },
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
    --
    -- COPIED, never aliased. `st.tint = preset.tint` would make the material's
    -- process-global STYLE table hold the preset table ITSELF, so an in-place
    -- write anywhere - a debug command, a future upstream Glass change doing
    -- `STYLE.tint[4] = x` - would edit AltStable.SKINS permanently, for the
    -- rest of the session, for every window. Glass.lua is a copy that is meant
    -- to stay in step with upstream, which makes shared mutable state exactly
    -- the wrong thing to hand it.
    local body = (size == "small") and AltStable.SkinPopupTint() or preset.tint
    local st = Glass.STYLE
    st.grain, st.wash = preset.grain, preset.wash
    st.tint = { body[1], body[2], body[3], body[4] }

    -- Kept on the frame. The rim lives on a CHILD at host level + 10, pinned at
    -- Apply time, so anything that moves the host's level afterwards leaves the
    -- rim behind - and without a handle neither production nor a test can see
    -- that, let alone fix it. See SkinRelevel.
    local g = Glass.Apply(frame, size or "large")
    frame._glass = g
    return g
end

-- Re-pin the material's rim above its host.
--
-- Raise() and SetFrameLevel() move the HOST, and the rim is a separate child
-- whose level was set once when the material was applied. A frame that raises
-- itself on hover therefore climbs above its own outline and draws its body
-- over it: the reference tooltip does exactly that, so from the second hover it
-- would have rendered as a bare panel with no rim at all.
function AltStable.SkinRelevel(frame)
    local g = frame and frame._glass
    if not (g and g.top and frame.GetFrameLevel) then return false end
    g.top:SetFrameLevel((frame:GetFrameLevel() or 0) + 10)
    return true
end

-- Mask `tex` to the shape of `anchor`, with a mask owned by `frame`.
--
-- The owner and the anchor are separate arguments because that IS the decision:
-- a mask only affects textures of the frame that created it, while what it is
-- anchored to decides what shape gets cut. Anchor it to a window and a fill is
-- trimmed where the two overlap; anchor it to the fill and the fill becomes the
-- shape. Every masking helper here is one of those two.
--
-- The sentinel is set INSIDE the attach, not after it. Setting it regardless
-- meant a region without AddMaskTexture was recorded as done, the caller was
-- told it succeeded, and a later retry short-circuited for ever on a texture
-- that had never been masked at all.
local function MaskTexture(frame, tex, anchor, size)
    if not AltStable.SkinIsGlass() then return false end
    if not frame or not tex or not anchor or not frame.CreateMaskTexture then
        return false
    end
    if tex._skinMasked then return true end
    if not tex.AddMaskTexture then return false end

    local S = Glass.SIZES[size or "large"]
    -- One mask per frame per anchor. The window case reuses `_skinMask`, which
    -- several textures on one panel can share; a texture masked to ITSELF needs
    -- its own, because the shape is different for each.
    local mask
    if anchor == tex then
        mask = Glass.Mask(frame, S.mask, S.maskMargin, 0, tex)
    else
        frame._skinMask = frame._skinMask
            or Glass.Mask(frame, S.mask, S.maskMargin, 0, anchor)
        mask = frame._skinMask
    end
    tex:AddMaskTexture(mask)
    tex._skinMasked = true
    return true
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
    -- Attached ONCE, through the shared helper: AddMaskTexture appends, and the
    -- Raids tab re-paints its fills from ApplyTheme on every theme change, so a
    -- second call is a real path rather than a defensive one.
    MaskTexture(frame, fill, window, "large")
    return true
end

-- The same clipping for a panel that ALREADY paints with a texture rather than
-- a backdrop, so there is nothing to replace - only to clip. Options is the one
-- that does this today.
function AltStable.SkinClipTexture(frame, tex, window)
    return MaskTexture(frame, tex, window, "large")
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

-- The colour of a TAB's background.
--
-- Raids and Warband have had this since the corner work, because their panels
-- reach the window edge and had to be repainted as textures to be clipped -
-- and repainting them meant using the pane colour. The Roster and Options
-- never did, so two tabs showed the material and two were opaque rectangles
-- sitting inside it. Same window, same skin, different answer depending on
-- which tab you were looking at.
--
-- The flat value is returned unchanged under flat, so a caller can use this
-- unconditionally instead of branching at every site.
function AltStable.SkinTabBG()
    if AltStable.SkinIsGlass() then return unpack(AltStable.SkinPaneColor()) end
    return unpack(AltStable.C.BG_MAIN)
end

-- THE READING SURFACE, and the two overlays that mark rows out on it.
--
-- Opaque, on purpose, and that is the decision this whole section exists to
-- make rather than inherit. The window has no blur available to it, so what
-- shows through a translucent table is the world moving SHARP behind twenty-one
-- rows of small text read at a glance. Glass is for the chrome; the table is
-- somewhere to read. If a visibly translucent body is ever wanted, this is the
-- one alpha to lower - 0.92 to 0.96 first, and judged while the camera is
-- MOVING rather than in a still shot, which is the condition it fails in.
--
-- The table was already opaque before any of this, but by accident: the row
-- colours were the flat theme's and nobody had chosen them for a glass window.
-- The difference is that the surface is now ONE texture that belongs to the
-- skin, and the rows are overlays on it rather than twenty-one opaque bands
-- each repainting the whole width in a colour from another palette.
--
-- AND NO TEXT SHADOWS ON THE TABLE, which is the other half of the same
-- decision. Shadows exist here because text over a translucent surface is read
-- against whatever is moving behind it; over an opaque one they are invisible
-- and cost a second draw on every cell of a twenty-one row grid. Lower the
-- alpha above and the shadows have to come with it - see AltStable.SkinText,
-- which the popups and toasts use for exactly that reason.
--
-- The lifts are white at low alpha, which is not the same arithmetic as the
-- absolute greys they replace: a white overlay at `s` over a surface at `C`
-- lands at `C + s(1 - C)`, so the step shrinks as the surface brightens. Over
-- these near-black surfaces the values below reproduce the old spacing to
-- within a thousandth, and the test asserts that rather than the alphas.
local STRIPE_LIFT, GROUP_LIFT, HEADER_LIFT = 0.035, 0.075, 0.053

function AltStable.SkinDataColor()
    -- The same question its siblings ask, not "does this preset name a colour".
    -- SkinIsGlass is `material and Glass ~= nil`, so if the material failed to
    -- load every other path falls back to the flat palette while this one would
    -- have gone on handing out a glass surface nothing else agreed with.
    if not AltStable.SkinIsGlass() then return AltStable.C.BG_ROW_ODD end
    return AltStable.Skin().data or AltStable.C.BG_ROW_ODD
end

-- The alternating band. Flat keeps its two absolute greys; under glass the odd
-- row is the surface itself, untouched, and only the even one is painted.
function AltStable.SkinRowStripe(index)
    if not AltStable.SkinIsGlass() then
        local c = (index % 2 == 0) and AltStable.C.BG_ROW_EVEN or AltStable.C.BG_ROW_ODD
        return c[1], c[2], c[3], c[4]
    end
    if index % 2 == 0 then return 1, 1, 1, STRIPE_LIFT end
    return 0, 0, 0, 0
end

-- The realm band, which is the same idea one step stronger.
function AltStable.SkinGroupBand()
    if not AltStable.SkinIsGlass() then return unpack(AltStable.C.BG_GROUP) end
    return 1, 1, 1, GROUP_LIFT
end

-- The COLUMN HEADER, which labels the table and therefore belongs to it.
--
-- The last flat-palette colour left inside the reading area: a neutral 0.11
-- chosen against the old charcoal body, sitting between a glass title bar and a
-- table whose surface now comes from the skin, and reading warm against the
-- rows it labels. The same drift as the Roster's hand-rolled 0.05/0.05/0.06,
-- and the last of it.
--
-- Opaque, and lifted from the reading surface rather than from the pane, even
-- though the window material is what is actually behind it: these are column
-- labels in small text, and the argument for not putting small text on
-- something translucent does not change because the text is bold.
function AltStable.SkinHeaderBand()
    if not AltStable.SkinIsGlass() then return unpack(AltStable.C.BG_HEADER) end
    local d = AltStable.SkinDataColor()
    local function lift(c) return c + HEADER_LIFT * (1 - c) end
    return lift(d[1]), lift(d[2]), lift(d[3]), 1
end

------------------------------------------------------------
-- The SHARED tooltip, and only while it is ours
------------------------------------------------------------
-- GameTooltip belongs to everybody. Restyling it outright would repaint the
-- game's own tooltips and every other addon's, which is why this was left
-- alone twice while the rest of the window was done - a glass box over a
-- quest reward is not our call to make.
--
-- So the material goes on only while WE own the tooltip, and comes off the
-- moment we do not. Ownership is read from the tooltip itself and walked up
-- the parent chain to a marked root, so no call site changes: the sheet's
-- twenty-two SetOwner sites, the plugins' and the menu's all keep working as
-- they are.
--
-- THE FAILURE THAT MATTERS is not getting the material on - it is failing to
-- take it off. The stock border is hidden by alpha while ours is up, so an
-- error midway, or an owner change without a hide, would leave every tooltip
-- in the game borderless until a reload. Hence:
--
--   * ONE idempotent reconcile, called from OnShow, from a post-hook on
--     SetOwner (a tooltip can change hands while visible, with no hide in
--     between) and from OnHide. Every path asks the same question.
--   * The restore is recorded BEFORE the change that needs restoring, so a
--     failure between them still has a way back.
--   * What we put back is the alpha we found, not an assumed 1, and only if
--     it is still the 0 we set - if another addon has moved it since, it has
--     an opinion and we do not fight over it.
--
-- Comparison tooltips (ShoppingTooltip1/2) are separate frames and stay stock,
-- deliberately: they appear beside an item tooltip that is usually not ours.
--
-- NineSlice is where an 11.x client keeps the tooltip's border. Every access
-- here is guarded, so on a client that does not have it the material simply
-- does not go on rather than erroring on a frame everyone shares.
local tip = { applied = false, saved = nil }

function AltStable.MarkTooltipHost(frame)
    if frame then frame.__altstableHost = true end
end

local function OwnedByUs(tt)
    local owner = tt.GetOwner and tt:GetOwner()
    local hops = 0
    while owner and hops < 8 do
        if owner.__altstableHost then return true end
        owner = owner.GetParent and owner:GetParent() or nil
        hops = hops + 1
    end
    return false
end

-- A FIXED-LENGTH list walked numerically. `ipairs` stops at the first nil, so
-- a missing region would have hidden the walk itself - leaving g.top, which
-- carries the rim, drawn over somebody else's tooltip. The per-part guards
-- below say nils are expected; ipairs made them unreachable.
local TIP_PART_KEYS = { "shadow", "tint", "grain", "wash", "top" }

local function ForEachTipPart(g, fn)
    if not g then return end
    for i = 1, #TIP_PART_KEYS do
        local part = g[TIP_PART_KEYS[i]]
        if part then fn(part) end
    end
end

local function RestoreTooltip(tt)
    if not tip.applied then return end

    -- THE BORDER GOES BACK FIRST, before the flag that guards this and before
    -- our own regions come off. Hiding first and restoring after put the one
    -- irreversible step last: anything throwing in between left the border
    -- hidden AND `applied` false, so every later restore early-returned and
    -- every tooltip in the game - the client's own and every other addon's -
    -- stayed borderless until a reload. That is the exact outcome this section
    -- exists to prevent, and the order defeated it.
    local ns = tt and tt.NineSlice
    if ns and ns.SetAlpha and tip.saved ~= nil then
        -- Only if it is still ours to give back.
        if not ns.GetAlpha or ns:GetAlpha() == 0 then ns:SetAlpha(tip.saved) end
    end

    ForEachTipPart(tip.g, function(part) if part.Hide then part:Hide() end end)
    tip.applied = false
    tip.saved = nil
end

local function ApplyTooltip(tt)
    if tip.applied then return end
    if not tip.g then tip.g = AltStable.SkinWindow(tt, "small") end
    if not tip.g then return end
    local ns = tt.NineSlice
    -- Recorded FIRST, and the flag with it: everything after this point is
    -- undoable even if it does not finish.
    tip.saved = (ns and ns.GetAlpha and ns:GetAlpha()) or nil
    tip.applied = true
    if ns and ns.SetAlpha then ns:SetAlpha(0) end
    -- RE-PINNED on every apply. Glass.Apply sets the rim's frame level from the
    -- host's at creation, and this host is shared: the client and other addons
    -- raise tooltips to keep them above their owner, and each one leaves our
    -- rim behind. The sheet's own reference tooltip already hit this on a
    -- PRIVATE frame - "from the second hover onwards it would have been a bare
    -- panel with no edge" - and a shared one moves far more often.
    if AltStable.SkinRelevel then AltStable.SkinRelevel(tt) end
    ForEachTipPart(tip.g, function(part) if part.Show then part:Show() end end)
end

function AltStable.ReconcileTooltip()
    local tt = _G.GameTooltip
    if not tt then return end
    local ours = AltStable.SkinIsGlass()
        and (not tt.IsShown or tt:IsShown())
        and OwnedByUs(tt)
    if ours then ApplyTooltip(tt) else RestoreTooltip(tt) end
end

function AltStable.InstallTooltipSkin()
    local tt = _G.GameTooltip
    if not tt or tip.hooked then return false end
    if not AltStable.SkinIsGlass() then return false end
    local installed = 0
    if tt.HookScript then
        tt:HookScript("OnShow", AltStable.ReconcileTooltip)
        tt:HookScript("OnHide", function() RestoreTooltip(tt) end)
        installed = installed + 2
    end
    -- A tooltip can change hands WITHOUT hiding - the client reuses one frame,
    -- and the next owner may be a quest giver. That is the state an OnShow hook
    -- alone never sees.
    if hooksecurefunc and tt.SetOwner then
        hooksecurefunc(tt, "SetOwner", AltStable.ReconcileTooltip)
        installed = installed + 1
    end
    -- Only "hooked" if something actually hooked. Setting the flag first and
    -- returning true regardless made the answer meaningless and, worse,
    -- permanent: a client missing one of these would never be retried, with a
    -- green return saying it had been handled.
    tip.hooked = installed > 0
    return tip.hooked
end

AltStable._test = AltStable._test or {}
AltStable._test.TooltipState = function() return tip end

-- A WELL cut into the panel, and the hairline round it.
--
-- The figure box on the character sheet is the one that exists, and it was two
-- absolute numbers: a 0.03/0.03/0.04 fill inside a 0.16/0.16/0.18 border. Under
-- clear that is a well in a 0.04/0.05/0.07 pane. Under smoked it IS the pane -
-- the same three channels - so the inset stopped being an inset and the box was
-- carried entirely by a one-pixel border.
--
-- Two guarantees rather than two numbers:
--
-- The well is OPAQUE, so unlike the pane around it nothing of the world comes
-- through. That matters more than the fill value: the pane is translucent, so
-- over bright scenery it lifts well clear of the well and over dark scenery it
-- drops to meet it. An absolute fill is legible or not depending on where you
-- happen to be standing, which is the failure mode glass invites.
--
-- And the hairline is lifted clear of BOTH, so the box keeps an outline
-- whatever is behind the window. It is one pixel; it has to be bright.
--
-- Both are derived from the pane, so a fourth preset cannot land a well on its
-- own panel colour the way smoked did.
--
-- Derived through the pane's ALPHA, not just its colour. The pane is what you
-- see it over: its floor, over black scenery, is `alpha x colour`, and that is
-- what the well has to beat - comparing against the nominal colour compares
-- against a surface that is never on screen. Scaling the nominal value alone
-- held for the two presets that exist and inverted below alpha 0.5: an opaque
-- well came out BRIGHTER than the translucent panel it was cut into, which is
-- this whole failure class with the sign flipped.
local WELL_DARKEN, HAIRLINE_LIFT = 0.5, 0.22

function AltStable.SkinWellColor()
    if not AltStable.SkinIsGlass() then return 0.03, 0.03, 0.04, 1 end
    local p = AltStable.SkinPaneColor()
    local k = p[4] * WELL_DARKEN
    return p[1] * k, p[2] * k, p[3] * k, 1
end

-- CLAMPED, so the guarantee lives in the code and not only in the suite.
--
-- What the clamp cannot do is invent a dark hairline for a light pane: lifting
-- a 0.85 panel by 0.22 saturates to white and the outline disappears into it.
-- No preset here is light, so this is deliberately not handled - and the test
-- asserts the lift survives, which is what fails the day somebody writes one,
-- rather than a helper quietly shipping a border you cannot see.
function AltStable.SkinWellEdgeColor()
    if not AltStable.SkinIsGlass() then return 0.16, 0.16, 0.18, 1 end
    local p = AltStable.SkinPaneColor()
    local function lift(c) return math.min(1, c + HAIRLINE_LIFT) end
    return lift(p[1]), lift(p[2]), lift(p[3]), 1
end

-- Round a texture that IS the shape - a menu entry's hover fill, say - rather
-- than one trimmed by something else.
--
-- The mask is anchored to the TEXTURE, the opposite of SkinClipTexture's, which
-- anchors to the window so the fill is cut where the two overlap. That one
-- difference is the whole difference, so this shares its implementation rather
-- than being a third near-copy of it: the two used to differ only in the size
-- set, the anchor and the name of the sentinel field - and getting that third
-- difference wrong is what let this one mark a texture as done when the attach
-- had not happened.
--
-- Deliberately not the nav painter: that insets 6px vertically, which on a 17px
-- menu entry leaves an 11px fill floating in the row, and its flat path paints
-- a BACKDROP where a menu entry paints a texture on a plain Button.
--
-- The small set's slice margins are 8px against a 17px entry, so the corners
-- squeeze rather than round fully. GLASS-MATERIAL.md §6 records that as
-- rendering fine, and a tighter radius is what a dense menu wants anyway.
function AltStable.SkinRoundTexture(frame, tex)
    return MaskTexture(frame, tex, tex, "small")
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
