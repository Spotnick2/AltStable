------------------------------------------------------------
-- test_glass.lua — the liquid-glass material and the skin seam (#97)
--
-- What this asserts, and what it deliberately does not.
--
-- It does NOT try to judge the look. Nothing here can tell you whether glass
-- over sandstone reads as glass; that is an in-game question and the PR says so.
--
-- What it CAN tell you is whether the layers were built, which frame owns each
-- mask, and what the flat path does - and mask ownership is the one that
-- matters most, because Glass.Mask deliberately puts the mask on the region
-- being clipped while ANCHORING it to the shape to clip against. Get those two
-- the wrong way round and a panel rounds into a floating capsule instead of
-- having a corner trimmed. In game that is a glance; here it is an assertion.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
-- The addon NAME, the way the client passes it. Glass.lua derives its media
-- path from `...`; a bare dofile leaves that nil and every texture path comes
-- out as "Interface\\AddOns\\nil\\Media\\Glass\\...". Worth asserting below
-- rather than trusting, because a wrong path draws nothing and throws nothing.
assert(loadfile("Glass.lua"))("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")

local Glass = AltStable.Glass
check("the material loaded", Glass ~= nil)
if not Glass then
    print(("test_glass: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end

------------------------------------------------------------
-- The media path, and the files actually being on disk
------------------------------------------------------------

eq("the media path comes from the addon name",
   Glass.MEDIA, "Interface\\AddOns\\AltStable\\Media\\Glass\\")

-- Every texture the material names for BOTH sizes. A missing TGA is silent in
-- game: SetTexture stores the path, the texture draws nothing, and the window
-- comes up with no body and no rim rather than with an error.
local wanted = {}
for _, S in pairs(Glass.SIZES) do
    wanted[S.mask] = true; wanted[S.rim] = true
    wanted[S.dark] = true; wanted[S.shadow] = true
end
wanted["grain"] = true
local missing = {}
for name in pairs(wanted) do
    local f = io.open("Media/Glass/" .. name .. ".tga", "rb")
    if f then f:close() else missing[#missing + 1] = name end
end
check("every texture the material names is on disk",
      #missing == 0, table.concat(missing, ", "))

-- And the .toc loads them in an order that works: Glass before Theme (Skin
-- needs the material), Skin after Theme (it reads AltStable.C).
local toc = {}
do
    local fh = io.open("AltStable.toc", "r")
    if fh then
        local i = 0
        for line in fh:lines() do
            local name = line:match("^%s*([%w_]+%.lua)%s*$")
            if name then i = i + 1; toc[name] = i end
        end
        fh:close()
    end
end
check("Glass.lua is in the .toc", toc["Glass.lua"] ~= nil)
check("Skin.lua is in the .toc", toc["Skin.lua"] ~= nil)
check("  the material loads before the palette",
      (toc["Glass.lua"] or 99) < (toc["Theme.lua"] or 0))
check("  and the skin after it, since it reads AltStable.C",
      (toc["Skin.lua"] or 0) > (toc["Theme.lua"] or 99))

------------------------------------------------------------
-- Choosing a skin
------------------------------------------------------------

AltStableConfig.skin = nil
eq("an unset skin falls back to a default", AltStable.SkinName(), "clear")
check("  which is a glass one", AltStable.SkinIsGlass())

AltStableConfig.skin = "smoked"
eq("a chosen skin is honoured", AltStable.SkinName(), "smoked")

-- A value on DISK, so it can be anything. A junk name must not produce a nil
-- preset that then indexes into an error on the next render.
AltStableConfig.skin = "chartreuse"
eq("an unknown skin falls back rather than erroring", AltStable.SkinName(), "clear")
AltStableConfig.skin = 42
eq("  and so does a non-string", AltStable.SkinName(), "clear")

AltStableConfig.skin = "flat"
check("flat is not glass", AltStable.SkinIsGlass() == false)

-- The presets differ in the BODY only. The rim is deliberately shared:
-- GLASS-MATERIAL.md ranks it the biggest lever for reading as glass rather than
-- plastic, and darkening it along with the body is what turns a smoked preset
-- into a smoked plastic case.
do
    local clear, smoked = AltStable.SKINS.clear, AltStable.SKINS.smoked
    check("smoked is darker than clear", smoked.tint[1] < clear.tint[1])
    check("  and denser", smoked.tint[4] > clear.tint[4])
    check("  while both keep a top-down wash", clear.wash > 0 and smoked.wash > 0)
    check("  and neither carries a rim of its own",
          clear.rim == nil and smoked.rim == nil)
end

------------------------------------------------------------
-- Applying the material
------------------------------------------------------------

local function freshHost()
    return CreateFrame("Frame", nil, UIParent)
end

AltStableConfig.skin = "flat"
do
    local host = freshHost()
    eq("under flat, no material is applied", AltStable.SkinWindow(host), nil)
    eq("  and no panel fill is painted",
       AltStable.SkinPanelFill(host, UIParent, AltStable.C.BG_MAIN), false)
    local tex = host:CreateTexture()
    eq("  and nothing is clipped", AltStable.SkinClipTexture(host, tex, UIParent), false)
    -- The caller's fallback is the untouched status quo, so the flat path must
    -- leave the frame entirely alone rather than half-dressing it.
    eq("  leaving the frame with no fill of ours", host._skinFill, nil)
    eq("  and no mask", host._skinMask, nil)
end

AltStableConfig.skin = "clear"
local host = freshHost()
local g = AltStable.SkinWindow(host)
check("under glass, the material is applied", g ~= nil)
if g then
    check("  a shadow is laid down", g.shadow ~= nil)
    check("  a body mask", g.mask ~= nil)
    check("  a tint", g.tint ~= nil)
    check("  a grain", g.grain ~= nil)
    check("  a wash", g.wash ~= nil)
    check("  a dark rim and a light rim", g.dark ~= nil and g.rim ~= nil)
    check("  and a frame above the rim for content", g.top ~= nil)

    -- The stack is only a stack if the parts are ordered. The rim must draw
    -- over the body, and the body over the shadow.
    eq("  the body mask is owned by the window", g.mask._maskOwner, host)
    eq("  the tint is masked by it", g.tint:GetMaskTexture(1), g.mask)
    eq("  and so is the grain", g.grain:GetMaskTexture(1), g.mask)
    eq("  and the wash", g.wash:GetMaskTexture(1), g.mask)
    check("  the rim sits above the body", g.top:GetFrameLevel() > host:GetFrameLevel())

    -- 9-slice, or a rounded corner stretches into a smear when the window is
    -- resized - and this window is resizable.
    check("  the mask is 9-sliced", g.mask:GetTextureSliceMargins() ~= nil)
    check("  and so is the rim", g.rim:GetTextureSliceMargins() ~= nil)

    -- The gradient takes colour OBJECTS on this client, not four numbers.
    -- CreateColor was absent from the stubs until this file needed it.
    check("  the wash is a gradient of colour objects",
          g.wash._gradient ~= nil and type(g.wash._gradient.min) == "table")
end

-- The preset reaches the material. Changing skin and re-applying has to change
-- what gets painted, or the presets are decoration.
do
    AltStableConfig.skin = "smoked"
    local dark = AltStable.SkinWindow(freshHost())
    check("the smoked preset paints a denser body",
          dark and dark.tint._colorTexture and
          dark.tint._colorTexture[4] > AltStable.SKINS.clear.tint[4],
          tostring(dark and dark.tint._colorTexture and dark.tint._colorTexture[4]))
end

------------------------------------------------------------
-- The corners
------------------------------------------------------------
-- The reason phase 1 could not be "the window and nothing else". Every fill
-- that reaches the frame edge draws the rounded corner straight back on.

AltStableConfig.skin = "clear"
do
    local window = freshHost()
    AltStable.SkinWindow(window)
    local footer = CreateFrame("Frame", nil, window)

    check("a corner-owning panel gets a fill",
          AltStable.SkinPanelFill(footer, window, AltStable.C.BG_FOOTER))
    check("  painted as a TEXTURE, because a backdrop cannot be masked",
          footer._skinFill ~= nil)
    -- In the PANE colour, not the flat palette's. BG_FOOTER is opaque - it was
    -- painted on an opaque window - and reusing it here lays a solid slab with
    -- hard edges over the material, which is what the first attempt did and what
    -- it looked like in game: a black box pasted onto the glass.
    local fc = footer._skinFill._colorTexture
    local pane = AltStable.SkinPaneColor()
    check("  in the pane colour, not the flat palette's",
          fc and fc[1] == pane[1] and fc[4] == pane[4],
          fc and ("%s a=%s"):format(tostring(fc[1]), tostring(fc[4])))
    check("  which is translucent, so the material still shows through",
          pane[4] < 1, tostring(pane[4]))
    check("  and darkens with the preset",
          AltStable.SKINS.smoked.pane[4] > AltStable.SKINS.clear.pane[4])

    -- THE point of the whole exercise, and the easiest thing to get backwards.
    eq("  the mask is owned by the PANEL", footer._skinMask._maskOwner, footer)
    eq("  and the fill carries it", footer._skinFill:GetMaskTexture(1), footer._skinMask)

    -- Anchored to the WINDOW, not to the panel. Anchored to the panel it would
    -- round the footer into its own floating capsule; anchored to the window it
    -- clips the footer exactly where the two overlap and nowhere else.
    local _, rel = footer._skinMask:GetPoint(1)
    eq("  but anchored to the WINDOW, so it trims rather than rounds", rel, window)

    -- Calling twice must not stack a second fill and a second mask on top.
    -- ApplyTheme re-runs on every theme change, so this happens for real.
    AltStable.SkinPanelFill(footer, window, AltStable.C.BG_FOOTER)
    eq("  and re-applying reuses them rather than stacking",
       footer._skinFill:GetNumMaskTextures(), 1)

    -- The variant for a panel that already paints with a texture of its own.
    local opts = CreateFrame("Frame", nil, window)
    local optBG = opts:CreateTexture(nil, "BACKGROUND")
    check("an existing texture can be clipped instead of replaced",
          AltStable.SkinClipTexture(opts, optBG, window))
    eq("  by a mask the panel owns", opts._skinMask._maskOwner, opts)
    local _, rel2 = opts._skinMask:GetPoint(1)
    eq("  anchored to the window too", rel2, window)
    eq("  and no second fill is painted over its own", opts._skinFill, nil)
end

------------------------------------------------------------
-- The title band
------------------------------------------------------------
-- It owns BOTH top corners and it painted an opaque fill flush to (0, 0), so
-- before this it drew them square - listed as a corner owner in the plan and
-- then not wired. The assertion is therefore as much about the clipping as
-- about the look.

AltStableConfig.skin = "clear"
do
    local window = freshHost()
    AltStable.SkinWindow(window)
    local bar = CreateFrame("Frame", nil, window)
    local bg  = bar:CreateTexture(nil, "BACKGROUND")
    local sep = bar:CreateTexture(nil, "OVERLAY")
    bg:SetColorTexture(0.10, 0.10, 0.10, 1)   -- what it was: opaque and dark
    sep:SetColorTexture(0, 0, 0, 1)

    check("the title band is restyled", AltStable.SkinTitleBand(bar, window, bg, sep))

    -- LIGHTER than the body, not darker. A dark band across the top of a
    -- translucent window reads as a lid laid on the glass.
    local c = bg._colorTexture
    check("  painted light rather than dark", c and c[1] > 0.5, tostring(c and c[1]))

    -- And graded, brightest at the top, agreeing with the body's own wash.
    -- VERTICAL takes min at the BOTTOM, so max is the top edge.
    local grad = bg._gradient
    check("  with a vertical gradient", grad ~= nil and grad.orient == "VERTICAL")
    check("  brightest at the top edge",
          grad and grad.max.a > grad.min.a,
          grad and ("%s -> %s"):format(tostring(grad.min.a), tostring(grad.max.a)))
    -- Translucent, or the world stops showing through and it is just a bar.
    check("  and translucent enough to see through",
          grad and grad.max.a < 0.5, grad and tostring(grad.max.a))

    -- The corner fix, which is the part that was actually broken.
    eq("  clipped by a mask the bar owns", bar._skinMask._maskOwner, bar)
    local _, rel = bar._skinMask:GetPoint(1)
    eq("  anchored to the window", rel, window)
    eq("  and carried by the fill", bg:GetMaskTexture(1), bar._skinMask)

    -- The divider stops being a hard black line across a light band.
    local sc = sep._colorTexture
    check("  the divider is light, not black", sc and sc[1] > 0.5 and sc[4] < 0.5,
          sc and ("%s a=%s"):format(tostring(sc[1]), tostring(sc[4])))
end

AltStableConfig.skin = "flat"
do
    local bar = CreateFrame("Frame", nil, UIParent)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0.10, 0.10, 0.10, 1)
    eq("under flat the title band is left alone",
       AltStable.SkinTitleBand(bar, UIParent, bg, nil), false)
    local c = bg._colorTexture
    check("  keeping its opaque dark fill", c and c[1] == 0.10 and c[4] == 1)
    eq("  and gaining no mask", bar._skinMask, nil)
end

------------------------------------------------------------
-- The navigation buttons
------------------------------------------------------------
-- Three states sharing one shape: normal is nothing, hover is a faint rounded
-- highlight, selected is a stronger one in the accent colour. The shape and
-- padding are shared deliberately - only brightness and colour differ - so the
-- sidebar reads as one control rather than two unrelated effects.

AltStableConfig.skin = "flat"
do
    local btn = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    AltStable.ApplyBGOnly(btn, 0, 0, 0, 0)
    AltStable.SkinButtonActive(btn)
    eq("under flat the state is still a backdrop", btn._skinState, nil)
    local r, g, b, a = btn:GetBackdropColor()
    check("  painted with the flat palette's active colour",
          a == AltStable.C.BG_BTN_ACTIVE[4], tostring(a))
end

AltStableConfig.skin = "clear"
local pillPoints
do
    local btn = CreateFrame("Button", nil, UIParent, "BackdropTemplate")

    AltStable.SkinButtonActive(btn)
    local t = btn._skinState
    check("under glass the selection is a texture, not a backdrop", t ~= nil)
    check("  rounded by a mask", t and t:GetNumMaskTextures() > 0)
    eq("  owned by the button", btn._skinStateMask._maskOwner, btn)

    -- Anchored to the PILL, the opposite of the corner case: there the fill had
    -- to be trimmed by a shape it overlapped, here the fill IS the shape.
    local _, rel = btn._skinStateMask:GetPoint(1)
    eq("  and anchored to the pill itself, so it rounds rather than trims", rel, t)

    -- Inset from the sidebar edges, or it is a full-width rectangle again -
    -- which is the thing being replaced.
    local _, _, _, lx = t:GetPoint(1)
    check("  inset from the button's left edge", (lx or 0) > 0, tostring(lx))

    local accent = { AltStable.GetAccentRGB() }
    local c = t._colorTexture
    check("  tinted with the accent, not a fixed colour",
          c and c[1] == accent[1] and c[2] == accent[2], tostring(c and c[1]))
    -- A TINT, not a button face. At 0.22 this read as a flat mustard block in
    -- game; enough charcoal has to show through that it stays part of the glass.
    check("  and a tint rather than a fill, so charcoal shows through",
          c and c[4] <= 0.16, tostring(c and c[4]))
    local activeAlpha = c[4]

    -- Same shape and padding for hover, differing only in brightness/colour.
    pillPoints = { t:GetPoint(1) }
    AltStable.SkinButtonHover(btn)
    local hoverPoints = { btn._skinState:GetPoint(1) }
    eq("hover uses the same shape as selection", hoverPoints[4], pillPoints[4])
    local hc = btn._skinState._colorTexture
    check("  but quieter", hc[4] < activeAlpha,
          ("hover %s vs active %s"):format(tostring(hc[4]), tostring(activeAlpha)))
    check("  and neutral rather than accented", hc[1] == hc[2] and hc[2] == hc[3])

    AltStable.SkinButtonIdle(btn)
    check("idle shows nothing at all", btn._skinState:IsShown() == false)
end

-- An inactive label reading as "disabled" was the other thing an outside eye
-- caught. TEXT_DIM is 0.50, chosen against a near-black panel.
do
    AltStableConfig.skin = "clear"
    local gr = AltStable.SkinNavDim()
    AltStableConfig.skin = "flat"
    local fr = AltStable.SkinNavDim()
    check("nav labels are brighter on glass than on the flat panel", gr > fr,
          ("%s vs %s"):format(tostring(gr), tostring(fr)))
    eq("  and unchanged under flat", fr, AltStable.C.TEXT_DIM[1])
end

-- The stripe runs the full height hard against the left edge, so over a
-- rounded selection it cuts across both corners.
do
    AltStableConfig.skin = "clear"
    local stripe = CreateFrame("Frame", nil, UIParent):CreateTexture()
    AltStable.SkinStripe(stripe, true, 1, 0.82, 0)
    check("the stripe steps aside under glass", stripe:IsShown() == false)

    AltStableConfig.skin = "flat"
    AltStable.SkinStripe(stripe, true, 1, 0.82, 0)
    check("  and is still drawn under flat", stripe:IsShown())
    AltStable.SkinStripe(stripe, false)
    check("  and hidden when not selected", stripe:IsShown() == false)
end

-- The title is white on glass and the accent on flat. Gold was the brightest
-- thing in a near-black window and read as the heading; on a light band it
-- competes with the sidebar's selected item, which is also the accent.
do
    AltStableConfig.skin = "clear"
    local r, g, b = AltStable.SkinTitleColor()
    check("the title is white on glass", r == g and g == b and r > 0.9,
          ("%s,%s,%s"):format(tostring(r), tostring(g), tostring(b)))
    -- All THREE components. Gold is (1, 0.82, 0) and white is (1, 1, 1), so
    -- they share a red channel - comparing the first return alone passes
    -- whichever one is handed back, which is exactly what it did.
    local ar, ag, ab = AltStable.GetAccentRGB()
    AltStableConfig.skin = "flat"
    local fr, fg, fb = AltStable.SkinTitleColor()
    check("  and the accent on flat",
          fr == ar and fg == ag and fb == ab,
          ("%s,%s,%s vs accent %s,%s,%s"):format(tostring(fr), tostring(fg),
              tostring(fb), tostring(ar), tostring(ag), tostring(ab)))
end

------------------------------------------------------------
-- Text on glass
------------------------------------------------------------

do
    AltStableConfig.skin = "clear"
    local fs = freshHost():CreateFontString()
    AltStable.SkinText(fs)
    local x, y = fs:GetShadowOffset()
    check("chrome text gains a shadow under glass", x ~= 0 or y ~= 0,
          ("%s,%s"):format(tostring(x), tostring(y)))

    AltStableConfig.skin = "flat"
    local plain = freshHost():CreateFontString()
    AltStable.SkinText(plain)
    local px, py = plain:GetShadowOffset()
    check("  and does not under flat", (px or 0) == 0 and (py or 0) == 0)
end

print(("test_glass: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
