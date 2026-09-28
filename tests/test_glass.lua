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

-- The active skin is resolved ONCE and held for the session, so a test that
-- drives several through one Lua state has to clear it - in game the whole
-- point is that it does not change under the window's feet.
local function useSkin(name)
    AltStableConfig.skin = name
    AltStable._ResetSkinCache()
end

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

useSkin(nil)
eq("an unset skin falls back to a default", AltStable.SkinName(), "clear")
check("  which is a glass one", AltStable.SkinIsGlass())

useSkin("smoked")
eq("a chosen skin is honoured", AltStable.SkinName(), "smoked")

-- A value on DISK, so it can be anything. A junk name must not produce a nil
-- preset that then indexes into an error on the next render.
useSkin("chartreuse")
eq("an unknown skin falls back rather than erroring", AltStable.SkinName(), "clear")
useSkin(42)
eq("  and so does a non-string", AltStable.SkinName(), "clear")

useSkin("flat")
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

-- The active skin is resolved on FIRST USE, not at load.
--
-- The real order is: Skin.lua loads, SavedVariables arrive, the window is built
-- and asks. Capturing at load would freeze the default before the player's
-- choice exists, which is why this is lazy rather than a module-level constant -
-- and a test that sets the config and then clears the cache cannot tell the two
-- apart, because it has already put the value in place. So this reloads the
-- file with nothing on disk, the way the client does.
do
    AltStableConfig.skin = nil
    assert(loadfile("Skin.lua"))("AltStable")     -- loads before the config exists
    AltStableConfig.skin = "smoked"               -- SavedVariables arrive
    eq("a skin saved on disk is honoured, not the default frozen at load",
       AltStable.SkinName(), "smoked")
    useSkin("clear")
end

-- Changing the skin does NOT change the one the window is wearing.
--
-- The command writes the config and asks for a reload. If the active skin
-- followed the config live, the window would still be made of glass while every
-- later hover, tab switch and lazily built panel took the flat path - and a
-- selected button would keep its glass pill, because the flat path paints a
-- backdrop and never hides that texture. Both skins at once until reload.
do
    useSkin("clear")
    eq("the active skin is the stored one to begin with", AltStable.SkinName(), "clear")

    local btn = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    AltStable.SkinButtonActive(btn)
    check("a selected button has a glass pill", btn._skinState:IsShown())

    -- The command, WITHOUT the cache reset a test would normally do - because
    -- in game there is no reset, and that is the whole point.
    AltStableConfig.skin = "flat"
    eq("the pending choice is recorded", AltStable.PendingSkinName(), "flat")
    eq("  but the window keeps the skin it was built with",
       AltStable.SkinName(), "clear")

    -- Navigating after the command: the pill must still be handled by the glass
    -- path, or it stays lit for ever.
    AltStable.SkinButtonIdle(btn)
    check("  so deselecting still hides the pill rather than leaving it lit",
          btn._skinState:IsShown() == false)

    useSkin("clear")
end

local function freshHost()
    return CreateFrame("Frame", nil, UIParent)
end

useSkin("flat")
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

useSkin("clear")
-- The material's STYLE table is SHARED and persists between calls, so a value
-- left by an earlier Apply makes "the preset reached the material" pass for
-- free - a mutation deleting the line that writes it survived exactly that way.
-- Poisoned first, so the assertions below can only pass if THIS call wrote them.
-- TINT as well as grain and wash. The material's file default is
-- {0.13, 0.16, 0.22, 0.24}, byte-identical to SKINS.clear.tint - so under clear
-- the assertion below passed whether or not SkinWindow wrote it, which is the
-- exact failure this poisoning was added to close, stopping one line short.
Glass.STYLE.tint  = { -1, -1, -1, -1 }
Glass.STYLE.grain = -1
Glass.STYLE.wash  = -1
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

    -- ALL THREE body parameters reach the material, not just the tint. The
    -- preset pushes tint, grain and wash into the material's shared STYLE
    -- table, and only the tint was ever checked - so grain and wash could be
    -- dropped from that line with everything still passing.
    local preset = AltStable.Skin()
    check("  the preset's grain reaches the material",
          math.abs((g.grain:GetAlpha() or 0) - preset.grain) < 0.001,
          ("grain alpha %s vs preset %s"):format(
              tostring(g.grain:GetAlpha()), tostring(preset.grain)))
    check("  and its wash",
          math.abs((g.wash._gradient.max.a or 0) - preset.wash) < 0.001,
          ("%s vs %s"):format(tostring(g.wash._gradient.max.a), tostring(preset.wash)))
end

-- The preset reaches the material. Changing skin and re-applying has to change
-- what gets painted, or the presets are decoration.
do
    useSkin("smoked")
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

useSkin("clear")
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

useSkin("clear")
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

useSkin("flat")
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

useSkin("flat")
do
    local btn = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    AltStable.ApplyBGOnly(btn, 0, 0, 0, 0)
    AltStable.SkinButtonActive(btn)
    eq("under flat the state is still a backdrop", btn._skinState, nil)
    local r, g, b, a = btn:GetBackdropColor()
    check("  painted with the flat palette's active colour",
          a == AltStable.C.BG_BTN_ACTIVE[4], tostring(a))
end

useSkin("clear")
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
    useSkin("clear")
    local gr = AltStable.SkinNavDim()
    useSkin("flat")
    local fr = AltStable.SkinNavDim()
    check("nav labels are brighter on glass than on the flat panel", gr > fr,
          ("%s vs %s"):format(tostring(gr), tostring(fr)))
    eq("  and unchanged under flat", fr, AltStable.C.TEXT_DIM[1])
end

-- The stripe runs the full height hard against the left edge, so over a
-- rounded selection it cuts across both corners.
do
    useSkin("clear")
    local stripe = CreateFrame("Frame", nil, UIParent):CreateTexture()
    AltStable.SkinStripe(stripe, true, 1, 0.82, 0)
    check("the stripe steps aside under glass", stripe:IsShown() == false)

    useSkin("flat")
    AltStable.SkinStripe(stripe, true, 1, 0.82, 0)
    check("  and is still drawn under flat", stripe:IsShown())
    AltStable.SkinStripe(stripe, false)
    check("  and hidden when not selected", stripe:IsShown() == false)
end

-- The title is white on glass and the accent on flat. Gold was the brightest
-- thing in a near-black window and read as the heading; on a light band it
-- competes with the sidebar's selected item, which is also the accent.
do
    useSkin("clear")
    local r, g, b = AltStable.SkinTitleColor()
    check("the title is white on glass", r == g and g == b and r > 0.9,
          ("%s,%s,%s"):format(tostring(r), tostring(g), tostring(b)))
    -- All THREE components. Gold is (1, 0.82, 0) and white is (1, 1, 1), so
    -- they share a red channel - comparing the first return alone passes
    -- whichever one is handed back, which is exactly what it did.
    local ar, ag, ab = AltStable.GetAccentRGB()
    useSkin("flat")
    local fr, fg, fb = AltStable.SkinTitleColor()
    check("  and the accent on flat",
          fr == ar and fg == ag and fb == ab,
          ("%s,%s,%s vs accent %s,%s,%s"):format(tostring(fr), tostring(fg),
              tostring(fb), tostring(ar), tostring(ag), tostring(ab)))
end

------------------------------------------------------------
-- The floating surfaces (#97 phase 2)
------------------------------------------------------------

-- A popup body is DENSER than the window's. It replaces a backdrop that was
-- 0.95 opaque, and it is a thing you read once while something moves behind it
-- - dropping straight to the window's tint takes the backing out from under
-- class-coloured names and a grey hint, which a text shadow does not put back.
do
    useSkin("clear")
    local win = AltStable.Skin().tint
    local pop = AltStable.SkinPopupTint()
    check("a popup body is denser than the window's", pop[4] > win[4],
          ("%s vs %s"):format(tostring(pop[4]), tostring(win[4])))
    check("  but still translucent, so it is still glass", pop[4] < 1,
          tostring(pop[4]))
    check("  and it darkens with the preset",
          AltStable.SKINS.smoked.popup[4] > AltStable.SKINS.clear.popup[4])
end

-- SkinWindow, not Glass.Apply, is what everything goes through - because it is
-- also what pushes the preset into the material's shared STYLE table. A toast
-- that appeared before the sheet was ever built would otherwise wear the file's
-- default look: clear glass in a smoked window.
do
    useSkin("smoked")
    local popup = AltStable.SkinWindow(CreateFrame("Frame", nil, UIParent), "small")
    check("a popup built first still gets the chosen preset", popup ~= nil)
    if popup then
        local c = popup.tint._colorTexture
        check("  the smoked popup body, not the default clear one",
              c and math.abs(c[4] - AltStable.SKINS.smoked.popup[4]) < 0.001,
              tostring(c and c[4]))
    end

    -- And the SIZE reaches the material, not just the tint. The two are
    -- independent: the preset decides the colour, the size decides which
    -- texture set is loaded, and a popup wearing the large set has corners
    -- built for a window.
    if popup then
        local art = popup.mask:GetTexture() or ""
        check("  and the small texture set, not the window's",
              art:find("_small", 1, true) ~= nil, art)
    end

    -- And the window still gets the WINDOW body, not the popup one.
    local win = AltStable.SkinWindow(CreateFrame("Frame", nil, UIParent))
    local wc = win.tint._colorTexture
    check("  while a window keeps its own, lighter body",
          wc and math.abs(wc[4] - AltStable.SKINS.smoked.tint[4]) < 0.001,
          tostring(wc and wc[4]))
    local wart = win.mask:GetTexture() or ""
    check("  and the large texture set", wart:find("_small", 1, true) == nil, wart)
    useSkin("clear")
end

-- Rounding a texture that IS the shape, for a menu entry's hover fill.
do
    useSkin("clear")
    local entry = CreateFrame("Button", nil, UIParent)
    local bg = entry:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()

    check("an entry fill is rounded", AltStable.SkinRoundTexture(entry, bg))
    check("  by a mask the entry owns", bg:GetNumMaskTextures() > 0)
    -- Anchored to the TEXTURE, the opposite of the corner case: here the fill
    -- IS the shape rather than something to be trimmed by one.
    local mask = bg:GetMaskTexture(1)
    local _, rel = mask:GetPoint(1)
    eq("  anchored to the fill itself, so it rounds rather than trims", rel, bg)

    -- Called again on a reused entry - the menu pools them - must not stack.
    AltStable.SkinRoundTexture(entry, bg)
    eq("  and rounding it twice does not stack masks", bg:GetNumMaskTextures(), 1)

    useSkin("flat")
    local plain = CreateFrame("Button", nil, UIParent)
    local pbg = plain:CreateTexture(nil, "BACKGROUND")
    eq("under flat nothing is rounded", AltStable.SkinRoundTexture(plain, pbg), false)
    eq("  and no mask is attached", pbg:GetNumMaskTextures(), 0)
    useSkin("clear")
end

------------------------------------------------------------
-- Text on glass
------------------------------------------------------------

do
    useSkin("clear")
    local fs = freshHost():CreateFontString()
    AltStable.SkinText(fs)
    local x, y = fs:GetShadowOffset()
    check("chrome text gains a shadow under glass", x ~= 0 or y ~= 0,
          ("%s,%s"):format(tostring(x), tostring(y)))

    useSkin("flat")
    local plain = freshHost():CreateFontString()
    AltStable.SkinText(plain)
    local px, py = plain:GetShadowOffset()
    check("  and does not under flat", (px or 0) == 0 and (py or 0) == 0)
end

-- The preset tables are never handed to the material by reference.
--
-- `st.tint = preset.tint` would make the material's process-global STYLE table
-- hold the preset ITSELF, so any in-place write - a debug command, an upstream
-- Glass change doing STYLE.tint[4] = x - would edit AltStable.SKINS
-- permanently, for every window, for the rest of the session. Glass.lua is a
-- copy meant to stay in step with upstream, which makes shared mutable state
-- exactly the wrong thing to hand it.
do
    useSkin("clear")
    AltStable.SkinWindow(CreateFrame("Frame", nil, UIParent))
    local before = AltStable.SKINS.clear.tint[4]
    Glass.STYLE.tint[4] = 0.99
    eq("writing through the material's style cannot corrupt a preset",
       AltStable.SKINS.clear.tint[4], before)

    AltStable.SkinWindow(CreateFrame("Frame", nil, UIParent), "small")
    local popBefore = AltStable.SKINS.clear.popup[4]
    Glass.STYLE.tint[4] = 0.98
    eq("  and the same for the popup body",
       AltStable.SKINS.clear.popup[4], popBefore)
end

-- A mask that could not be attached is not recorded as attached.
--
-- Setting the sentinel regardless meant a region without AddMaskTexture was
-- marked done, the caller was told it succeeded, and every later retry
-- short-circuited for ever on a texture that had never been masked at all.
do
    useSkin("clear")
    local f = CreateFrame("Frame", nil, UIParent)
    -- A bare table, not a stub texture with the method removed: the stubs chain
    -- unknown lookups through a metatable, so clearing the field just hands
    -- back the chaining default and the region still looks capable.
    local tex = {}
    eq("a texture that cannot take a mask reports failure",
       AltStable.SkinRoundTexture(f, tex), false)
    check("  and is not marked as done", not tex._skinMasked)
end

-- Every tab's background is the same material (#97 phase 3).
--
-- Raids and Warband have had the pane since the corner work - their panels
-- reach the window edge, so they had to be repainted as textures to be
-- clipped, and repainting them meant using the pane colour. The Roster and
-- Options never did, so two tabs showed the material and two were opaque
-- rectangles sitting inside it: same window, same skin, different answer
-- depending on which tab you were looking at.
do
    useSkin("clear")
    local pane = AltStable.SkinPaneColor()
    local r, g, b, a = AltStable.SkinTabBG()
    check("a tab's background is the pane under glass",
          r == pane[1] and a == pane[4], ("%s a=%s"):format(tostring(r), tostring(a)))
    check("  which is translucent, so the material shows through", a < 1, tostring(a))

    useSkin("flat")
    local fr, fg, fb, fa = AltStable.SkinTabBG()
    check("and the flat palette under flat",
          fr == AltStable.C.BG_MAIN[1] and fa == AltStable.C.BG_MAIN[4],
          ("%s a=%s"):format(tostring(fr), tostring(fa)))
    -- Exactly BG_MAIN, which the Options tab already used. The Roster's was a
    -- hand-rolled 0.05/0.05/0.06/1 that had drifted off the palette, so under
    -- flat this tab now agrees with the others too.
    check("  exactly, channel for channel",
          fr == AltStable.C.BG_MAIN[1] and fg == AltStable.C.BG_MAIN[2]
          and fb == AltStable.C.BG_MAIN[3] and fa == AltStable.C.BG_MAIN[4])
    useSkin("clear")
end

-- The table: one reading surface, and rows as overlays on it (#97).
--
-- The decision recorded here is that the surface is OPAQUE. There is no blur
-- available, so what shows through a translucent table is the world moving
-- sharp behind twenty-one rows of small text. The table was already opaque
-- before any of this, but by accident - the row colours were the flat theme's
-- and nobody had chosen them for a glass window.
do
    -- A white overlay at `s` over a surface at `C` lands at C + s(1 - C), so
    -- the step SHRINKS as the surface brightens. That is why the alphas are not
    -- the thing to assert: what has to survive is the spacing the flat table
    -- had, and these are the two numbers it has to survive at.
    local function over(c, s) return c + s * (1 - c) end
    local FLAT_STRIPE = AltStable.C.BG_ROW_EVEN[1] - AltStable.C.BG_ROW_ODD[1]
    local FLAT_GROUP  = AltStable.C.BG_GROUP[1]    - AltStable.C.BG_ROW_ODD[1]

    for _, name in ipairs({ "clear", "smoked" }) do
        useSkin(name)
        local d = AltStable.SkinDataColor()
        eq(name .. ": the reading surface is opaque", d[4], 1)

        -- The odd row IS the surface. Painting it at all would be a second
        -- layer of the same colour, and under a translucent surface that would
        -- have doubled its density.
        local _, _, _, oddA = AltStable.SkinRowStripe(1)
        eq(name .. ": the odd row paints nothing", oddA, 0)

        local er, eg, eb, ea = AltStable.SkinRowStripe(2)
        -- WHITE, every channel. Asserting red alone lets `return 1, 0, 1, a`
        -- through, which is a magenta stripe across every other row.
        check(name .. ": the even row lifts rather than replaces",
              er == 1 and eg == 1 and eb == 1,
              ("%s,%s,%s"):format(er, eg, eb))
        local step = over(d[1], ea) - d[1]
        check(name .. ": and lands where the flat stripe did",
              math.abs(step - FLAT_STRIPE) < 0.005,
              ("step %.4f vs flat %.4f"):format(step, FLAT_STRIPE))

        local gr, gg, gb, ga = AltStable.SkinGroupBand()
        check(name .. ": the realm band lifts too",
              gr == 1 and gg == 1 and gb == 1, ("%s,%s,%s"):format(gr, gg, gb))
        local gstep = over(d[1], ga) - d[1]
        check(name .. ": and lands where the flat band did",
              math.abs(gstep - FLAT_GROUP) < 0.005,
              ("step %.4f vs flat %.4f"):format(gstep, FLAT_GROUP))

        -- And the band still reads as stronger than the stripe, or the realm
        -- headers stop separating anything.
        check(name .. ": the band is the stronger of the two", gstep > step * 1.5,
              ("%.4f vs %.4f"):format(gstep, step))
    end

    -- Flat keeps its two absolute greys, to the digit, and its band.
    useSkin("flat")
    local o = { AltStable.SkinRowStripe(1) }
    local e = { AltStable.SkinRowStripe(2) }
    local g = { AltStable.SkinGroupBand() }
    local function same(got, want)
        for i = 1, 4 do if got[i] ~= want[i] then return false end end
        return true
    end
    check("flat odd rows are the palette's, unchanged",
          same(o, AltStable.C.BG_ROW_ODD), table.concat(o, ","))
    check("flat even rows too", same(e, AltStable.C.BG_ROW_EVEN), table.concat(e, ","))
    check("and the realm band", same(g, AltStable.C.BG_GROUP), table.concat(g, ","))
    -- AND WHEN THE MATERIAL ITSELF IS MISSING. SkinIsGlass is "this preset
    -- wants material AND Glass loaded", so a dropped Glass.lua sends every other
    -- path to the flat palette. This one keyed off the preset naming a colour
    -- instead, so it would have gone on handing out a glass surface that nothing
    -- else in the window agreed with.
    do
        useSkin("clear")
        -- Skin.lua captures Glass as a file-local at LOAD time, so clearing
        -- AltStable.Glass here proves nothing - the upvalue is already bound.
        -- Loading the file again with it absent is what a dropped Glass.lua
        -- actually looks like, and it is the only way to reach this branch.
        local held = AltStable.Glass
        AltStable.Glass = nil
        dofile("Skin.lua")
        AltStable._ResetSkinCache()
        check("a glass preset with no material falls back like everything else",
              same({ unpack(AltStable.SkinDataColor()) }, AltStable.C.BG_ROW_ODD),
              table.concat(AltStable.SkinDataColor(), ","))
        check("  as its siblings already did", AltStable.SkinIsGlass() == false)
        AltStable.Glass = held
        dofile("Skin.lua")
        AltStable._ResetSkinCache()
        useSkin("flat")
    end

    -- Flat has no reading surface of its own; the rows ARE the surface there.
    check("flat falls back to the row colour rather than inventing one",
          same({ unpack(AltStable.SkinDataColor()) }, AltStable.C.BG_ROW_ODD))
    useSkin("clear")
end

-- The well a figure stands in (#97).
--
-- Asserted as a GAP, not as numbers. The old values were absolute - a
-- 0.03/0.03/0.04 fill in a 0.16/0.16/0.18 border - and under smoked the fill
-- was the pane's own three channels, so the inset stopped being an inset and a
-- one-pixel border was holding the box together on its own. Numbers cannot say
-- that; the distance between them can, and it says it for a preset nobody has
-- written yet.
do
    -- Perceptual weights, because the channels here are not equal: a pane that
    -- is cool-blue and a well that is neutral can share a mean and still read
    -- as different surfaces, and the eye follows green.
    local function lum(r, g, b) return 0.299 * r + 0.587 * g + 0.114 * b end

    for _, name in ipairs({ "clear", "smoked" }) do
        useSkin(name)
        local p = AltStable.SkinPaneColor()
        local wr, wg, wb, wa = AltStable.SkinWellColor()
        local er, eg, eb, ea = AltStable.SkinWellEdgeColor()
        local pl, wl, el = lum(p[1], p[2], p[3]), lum(wr, wg, wb), lum(er, eg, eb)

        -- OPAQUE is the load-bearing half. The pane is translucent, so over
        -- bright scenery it lifts clear of the well and over dark scenery it
        -- drops to meet it; a well that also let the world through would move
        -- with it and the box would be legible depending on where you stand.
        eq(name .. ": the well is opaque", wa, 1)
        eq(name .. ": so is its hairline", ea, 1)
        -- Against the pane's FLOOR - what it composites to over black
        -- scenery - not against its nominal colour, which is a surface that is
        -- never on screen. The nominal comparison held for both presets and
        -- inverted below alpha 0.5, which is this failure class with the sign
        -- flipped: an opaque well brighter than the panel it is cut into.
        local floor = pl * p[4]
        check(name .. ": the well is darker than the panel at its darkest",
              wl < floor - 0.002, ("well %.4f vs pane floor %.4f"):format(wl, floor))
        check(name .. ": the hairline is clear of the pane",
              el > pl + 0.15, ("hairline %.4f vs pane %.4f"):format(el, pl))
        check(name .. ": and clear of the well it outlines",
              el > wl + 0.15, ("hairline %.4f vs well %.4f"):format(el, wl))
        check(name .. ": and still a colour the client can draw",
              er <= 1 and eg <= 1 and eb <= 1 and wr >= 0,
              ("%.3f,%.3f,%.3f"):format(er, eg, eb))
    end

    -- AND THEY CAN FAIL. Two of these gaps are algebraically implied by the
    -- formula for the presets that exist - the weights sum to 1, so a uniform
    -- lift IS the luminance gap - and a check that cannot fail is decoration.
    -- Each one gets a preset built to break it.
    local function probe(pane)
        AltStable.SKINS.probe = { material = true, label = "Probe",
                                  tint = { 0.1, 0.1, 0.1, 0.3 }, grain = 0.4,
                                  wash = 0.1, pane = pane, popup = pane }
        useSkin("probe")
        local p = AltStable.SkinPaneColor()
        local wr, wg, wb = AltStable.SkinWellColor()
        local er, eg, eb = AltStable.SkinWellEdgeColor()
        return lum(p[1], p[2], p[3]) * p[4], lum(wr, wg, wb), lum(er, eg, eb),
               lum(p[1], p[2], p[3])
    end

    -- A THIN pane. This is the one the alpha fix exists for: scaling the
    -- nominal colour by 0.5 put the well above a pane that only contributes
    -- 45% of itself, so the inset came out brighter than its surround over
    -- dark scenery. It has to stay an inset here.
    local floor, well = probe({ 0.82, 0.84, 0.88, 0.45 })
    check("a thin pane still has a well cut INTO it, not raised out of it",
          well < floor, ("well %.4f vs pane floor %.4f"):format(well, floor))

    -- A LIGHT pane, which this helper does not cover: 0.85 lifted by 0.22
    -- saturates to white and the outline vanishes into the panel. The clamp
    -- keeps the colour legal, and the gap check is what refuses to pass it -
    -- which is the point. If somebody teaches the hairline to go dark on a
    -- light pane, this is the assertion that should be deleted with it.
    local _, _, hair, nominal = probe({ 0.90, 0.92, 0.95, 0.95 })
    check("a light pane cannot keep its hairline, and the gap check says so",
          not (hair > nominal + 0.15),
          ("hairline %.4f vs pane %.4f"):format(hair, nominal))
    check("  while the colour it returns is still one the client can draw",
          hair <= 1, ("%.4f"):format(hair))
    AltStable.SKINS.probe = nil

    -- Flat is the untouched status quo, to the digit.
    useSkin("flat")
    local fr, fg, fb, fa = AltStable.SkinWellColor()
    check("flat keeps the well it always had",
          fr == 0.03 and fg == 0.03 and fb == 0.04 and fa == 1,
          ("%s,%s,%s,%s"):format(fr, fg, fb, fa))
    local hr, hg, hb, ha = AltStable.SkinWellEdgeColor()
    check("  and the border it always had",
          hr == 0.16 and hg == 0.16 and hb == 0.18 and ha == 1,
          ("%s,%s,%s,%s"):format(hr, hg, hb, ha))
    useSkin("clear")
end

------------------------------------------------------------
-- The CALL SITES, not the helpers (#97 phase 2)
------------------------------------------------------------
-- Every helper above has its own tests. What those cannot say is whether the
-- three surfaces ASK for the material - and replacing all three calls with
-- `if true then`, shipping the old flat backdrops and no glass at all, left
-- every suite green. The central deliverable was unasserted.

do
    useSkin("clear")
    dofile("Toasts.lua")

    -- The toast, built through its own path.
    if AltStable.ShowAggregateToast then
        pcall(AltStable.ShowAggregateToast, { { name = "A", class = "MAGE", cd = "x" } })
    end
    local toast = AltStable._test.ToastFrame and AltStable._test.ToastFrame()
    check("the toast is built", toast ~= nil)
    if toast then
        check("  and wears the material", toast._glass ~= nil)
        -- Its close button hangs 2px OUTSIDE the frame, which is where the rim
        -- art is opaque - so it has to sit above the rim, not ten below it.
        if toast.closeBtn and toast._glass and toast._glass.top then
            check("  with the close button above the rim",
                  toast.closeBtn:GetFrameLevel() >= toast._glass.top:GetFrameLevel(),
                  ("close %s vs rim %s"):format(
                      tostring(toast.closeBtn:GetFrameLevel()),
                      tostring(toast._glass.top:GetFrameLevel())))
        end
        -- The BODY lines are what the denser popup tint exists to protect, and
        -- were the only text on the toast without a shadow.
        local line = AltStable._test.ToastLine and AltStable._test.ToastLine(1)
        if line then
            local sx, sy = line:GetShadowOffset()
            check("  and its body lines carry a shadow", sx ~= 0 or sy ~= 0,
                  ("%s,%s"):format(tostring(sx), tostring(sy)))
        end
    end
end

print(("test_glass: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
