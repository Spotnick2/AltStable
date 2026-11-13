------------------------------------------------------------
-- wow_stubs.lua
--
-- A WoW: Forever (1.60.1) API surface, minimal but SHAPED CORRECTLY, so
-- AltStable's files load and run under stock Lua 5.1 with no game client.
--
-- Built on WowTestKit (#284; C:\Projects\WoW\WowTestKit, its README is the
-- reference), at the commit and client build tests/kit.pin names. The kit
-- holds the mechanics: strict globals, secrets, events checked against the
-- build, widgets that record every method called (Kit.checkMethods), print
-- with the stray-"|" check. This file holds what is AltStable's own: the
-- client APIs it calls, and the frame behaviours below that the suite was
-- written against.
--
-- Two rules this file exists to enforce:
--
--   1. The removed Classic globals are NOT defined here. GetItemInfo,
--      GetSkillLineInfo, GetFactionInfo, GetContainerItemInfo and friends are
--      absent on the real client, so code that reaches for one must fail in
--      tests too. Defining them "for convenience" would hide exactly the bug
--      this port is about. (Kit.strict, the last line, now makes reading any
--      undefined global an error rather than a nil.)
--
--   2. Return SHAPES match what was measured in-game, not what Classic did.
--      Skills, reputation and containers return a STRUCT. Items return the
--      Classic tuple. A cache miss returns NOTHING - not nil.
--
-- Load this FIRST in every test file:  dofile("tests/wow_stubs.lua")
-- Drive it through the exported `WoW` table; reset with WoW.reset().
------------------------------------------------------------

-- Lua's own print, before the kit replaces it: the suite's result and FAIL
-- lines go through print, and must still reach the runner (see print below).
local luaPrint = print

dofile("tests/kit.lua")
local Methods = WoW.Methods

-- Methods a Blizzard mixin adds in Lua, which the dump's widget walk can't see
-- (wow-ui-source). Allowed before anything loads: on the kit's API 2 a method
-- the build lacks reads as nil, so a call fails where it is made - silently
-- inside a pcall (#311). Kit.checkMethods accepts them too (test_methods).
do
    local BACKDROP = "BackdropTemplateMixin (Blizzard_SharedXML/Backdrop.lua), from BackdropTemplate"
    local TOOLTIP = "TooltipDataHandler's accessors, added in Lua (Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua)"
    Kit.allowMethods({
        ["Button:SetBackdrop"] = BACKDROP, ["Button:SetBackdropColor"] = BACKDROP,
        ["Button:SetBackdropBorderColor"] = BACKDROP,
        ["Frame:SetBackdrop"] = BACKDROP, ["Frame:SetBackdropColor"] = BACKDROP,
        ["Frame:SetBackdropBorderColor"] = BACKDROP,
        ["GameTooltip:SetHyperlink"] = TOOLTIP, ["GameTooltip:SetInventoryItem"] = TOOLTIP,
    })
end

-- AltStable's state, on the kit's WoW table.
for k, v in pairs({
    items       = {},   -- [itemID] = { name=, quality=, ilvl=, ... }; absent = cache miss
    skillLines  = {},   -- array of skill structs
    factions    = {},   -- array of faction structs
    factionByID = {},   -- [factionID] = struct (may hold ids not in `factions`)
    containers  = {},   -- [bagID] = { name=, size=, [slot] = itemStruct }
    bankTabs    = {},   -- purchased CHARACTER bank tab ids
    currencies  = {},   -- [currencyID] = quantity (C_CurrencyInfo)
    accountTabs = {},   -- purchased ACCOUNT bank tab ids (should never be scanned)
    tooltipPostCalls = {},  -- [Enum.TooltipDataType.X] = { fn, ... }
    loaded      = {},
    loadCalls   = {},
    tickers     = {},
    sent        = {},
    maxLevel    = 60,
    level = 1, xp = 0, xpMax = 400, resting = false,   -- restXP nil: measured "not rested"
    faction = "Horde",  -- UnitFactionGroup's tag
    defense     = { 1, 0 },
    chatOut     = {},   -- captured DEFAULT_CHAT_FRAME output
    now         = 1700000000,  -- the clock time() reads; tests pin their own values
    eventFrames = {},   -- [event] = { frame, ... } for GetFramesRegisteredForEvent
    tooltipLines = {},  -- lines the last GameTooltip render added
    tooltipShown = false,
    popups      = {},   -- StaticPopup_Show calls, newest last
    -- CVars, as a plain store. Code that changes one and RESTORES it is exactly
    -- what needs testing: a missed restore leaves the player's own settings
    -- altered after the addon closes, and nothing in game says so.
    cvars       = {},
    camera      = { zoom = 4, view = 1, savedViews = {} },
}) do WoW[k] = v end

-- WoW.reset() clears the kit's state (frames, timers, combat, ...), then runs
-- this for AltStable's own.
WoW.onReset[#WoW.onReset + 1] = function()
    WoW.items, WoW.skillLines, WoW.factions, WoW.factionByID = {}, {}, {}, {}
    WoW.containers, WoW.bankTabs, WoW.accountTabs = {}, {}, {}
    WoW.currencies = {}
    WoW.tooltipPostCalls = {}
    WoW.loaded, WoW.loadCalls, WoW.sent = {}, {}, {}
    -- Tickers are NOT cleared: they are registered once at load, like the
    -- client's, and a reset is a new test section rather than a new session.
    -- Clearing them here is what left Core's stale-buffer sweep unreachable
    -- after the first WoW.reset().
    WoW.uiVisible, WoW.screenshots = true, 0
    WoW.equipped = {}
    WoW.slotTooltip = {}
    if UIParent then UIParent:Show() end
    WoW.maxLevel = 60
    WoW.level, WoW.xp, WoW.xpMax, WoW.restXP, WoW.resting = 1, 0, 400, nil, false
    WoW.faction = "Horde"
    WoW.defense = { 1, 0 }
    WoW.chatOut = {}
    WoW.eventFrames = {}
    WoW.tooltipLines, WoW.tooltipShown = {}, false
    WoW.dead = false
    WoW.displayID = 56658
    WoW.instanceType, WoW.speed, WoW.falling = "none", 0, false
    -- Crit and hit are STATE, so they reset; the functions that read them are
    -- defined at file scope like every other stub.
    WoW.critChance, WoW.hitModifier = 12.5, 3
    -- UIParent is built ONCE for the whole run, so without this its child list
    -- accumulates every frame every block ever created and a test walking it
    -- sees strangers from three blocks ago.
    if UIParent then UIParent._children = {} end
    WoW.popups = {}
    WoW.popupRefused = nil
    WoW.sendResults, WoW.reportedErrors = {}, {}
    WoW.bn = { me = 1, myId = 2, project = 18, tag = "Owner#1", connected = true, accounts = {}, friends = {} }
    WoW.ctlDefer, WoW.ctlQueue, WoW.ctlHeld = false, {}, {}
    WoW.reloaded = 0
    WoW.sounds = {}
    WoW.cvars = {}
    WoW.camera = { zoom = 4, view = 1, savedViews = {} }
    WoW.now = 1700000000
    WoW.pendingPrio = nil
    -- The player too. A test that renames the character to exercise a login
    -- path would otherwise leave that name in place for every test after it,
    -- and the addon's own captured copy would agree with it - so the mistake
    -- hides itself.
    if WoW.player then
        WoW.player.name = "Example Surname"
        WoW.player.realm, WoW.player.normalizedRealm = "Classic Beta PvE", "ClassicBetaPvE"
        WoW.player.class, WoW.player.classLocalized, WoW.player.race = "PRIEST", "Priest", "Scourge"
    end
end

-- The kit's print records every line in WoW.chat and checks it for a stray
-- "|". Before the kit, print here was Lua's own, so the addon's prints and the
-- suite's own FAIL and result lines all reached stdout; they still do.
do
    local kitPrint = print
    function print(...)
        kitPrint(...)
        luaPrint(...)
    end
end

-- A test file's last line: the kit's stray-"|" check over every printed line
-- (what the kit's done() adds), then "<name>: N passed, M failed", the exit
-- code. The files keep their own check/eq: their argument orders differ from
-- the kit's and from each other.
function WoW.finish(name, passed, failed)
    local strays = WoW.strays or {}
    if #strays == 0 then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: no stray | in any printed line: " .. strays[1] .. "\n")
    end
    -- As the kit's done(): a secret touch a pcall caught is still a taint.log
    -- line on the client (WowTestKit #13; WoW.reset clears the count).
    if (WoW.secretBlocked or 0) == 0 then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: no operation on a secret was blocked and caught by a pcall: "
                 .. tostring(WoW.secretBlockedFirst) .. "\n")
    end
    io.write(string.format("%s: %d passed, %d failed\n", name, passed, failed))
    io.flush()
    os.exit(failed == 0 and 0 or 1)
end

------------------------------------------------------------
-- Frames
--
-- The kit's widgets (WoW.newWidget: method calls recorded for
-- Kit.checkMethods), with the behaviours below in place of the kit's where the
-- suite was written against them. Every one is kept for that reason: each
-- comment says what a test asks of it. Field names are the ones the tests
-- read (_colorTexture, _GetLeft, _texCoord, ...); scripts and events live in
-- the kit's _scripts and _events, which WoW.fire and WoW.tick read.
------------------------------------------------------------

local newWidget = WoW.newWidget

-- What a frame made by hand (not CreateFrame) is: tests and the stubs below
-- build loose frames this way. Not in WoW.frames, as before.
function WoW.makeFrame(kind, parent) return newWidget(kind or "Frame", parent) end
local makeFrame = WoW.makeFrame

-- Unlike the kit's, HookScript REJECTS the script types the live client does
-- not have. OnTooltipSetItem throws there, and a stub that accepted everything
-- is precisely why the old Warband tests could not catch that (issue #10).
-- CHAINED INTO THE SAME DISPATCH as SetScript, so Show()/Hide() run it.
function Methods.HookScript(self, ev, fn)
    if ev == "OnTooltipSetItem" or ev == "OnTooltipSetUnit" then
        error("bad argument #2 to 'HookScript' (Usage: self:HookScript(scriptTypeName, script))", 2)
    end
    local prev = self._scripts[ev]
    self._scripts[ev] = function(...)
        if prev then prev(...) end
        fn(...)
    end
    self["_hook_" .. tostring(ev)] = fn
    return self
end

-- Regions: the draw layer, the SUBLEVEL and the CREATION ORDER are real state,
-- because between two textures the client resolves which is on top in exactly
-- that priority: layer, then sublevel, then which was created first (see
-- T.TextureOrder). The full client signature is CreateTexture(name, drawLayer,
-- templateName, subLevel): the TEMPLATE slot is third and easy to drop.
-- A frame knows what it drew, the way the client's GetRegions does, and a
-- region's GetParent is its frame.
local function newRegion(self, kind, name)
    local r = newWidget(kind, self, name)
    if type(self) == "table" then
        self._regions = self._regions or {}
        self._regions[#self._regions + 1] = r
        r._regionOwner = self
    end
    if type(name) == "string" and name ~= "" then rawset(_G, name, r) end
    return r
end
function Methods.GetRegions(self) return unpack(self._regions or {}) end
function Methods.GetNumRegions(self) return #(self._regions or {}) end
function Methods.CreateTexture(self, name, layer, _template, sublevel)
    local t = newRegion(self, "Texture", name)
    t._layer, t._sublevel = layer, sublevel
    WoW.textureSeq = (WoW.textureSeq or 0) + 1
    t._created = WoW.textureSeq
    return t
end
-- The client's SetDrawLayer takes the sublevel as an optional second argument
-- and resets it to 0 when omitted, rather than leaving the previous one.
function Methods.SetDrawLayer(self, v, sub) self._layer = v; self._sublevel = sub or 0; return self end
function Methods.GetDrawLayer(self) return self._layer, self._sublevel end
-- Owned by the frame that creates it, and that ownership is the assertion:
-- Glass.Mask puts the mask on the region being clipped while ANCHORING it to
-- the shape to clip against.
function Methods.CreateMaskTexture(self, name, layer, _template, sublevel)
    local m = newRegion(self, "MaskTexture", name)
    m._layer, m._sublevel = layer, sublevel
    WoW.textureSeq = (WoW.textureSeq or 0) + 1
    m._created = WoW.textureSeq
    m._isMask = true
    m._maskOwner = self
    return m
end
-- A font string IS a region, as on the client: GetRegions returns it with the
-- textures (the Options page moving what sits below its lists, #151).
function Methods.CreateFontString(self, name)
    local fs = newRegion(self, "FontString", name)
    fs._isFontString = true
    return fs
end

-- The backdrop (BackdropTemplateMixin): the FLAT path's painting is asserted.
function Methods.SetBackdrop(self, bd) self._backdrop = bd; return self end
function Methods.GetBackdrop(self) return self._backdrop end
function Methods.SetBackdropColor(self, r, g, b, a) self._backdropColor = { r, g, b, a }; return self end
function Methods.GetBackdropColor(self)
    local c = self._backdropColor
    if not c then return end
    return c[1], c[2], c[3], c[4]
end
function Methods.SetBackdropBorderColor(self, r, g, b, a) self._backdropBorder = { r, g, b, a }; return self end

-- Text colour: "is this label readable" and "is this the selected one" are
-- colour questions. White, alpha 1, until set.
function Methods.SetTextColor(self, r, g, b, a) self._textColor = { r, g, b, a }; return self end
function Methods.GetTextColor(self)
    local c = self._textColor
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end
-- Texture coordinates, set with four numbers (left, right, top, bottom), read
-- back as EIGHT, the corners: upper-left, lower-left, upper-right, lower-right.
function Methods.SetTexCoord(self, ...) self._texCoord = { ... }; return self end
function Methods.GetTexCoord(self)
    local c = self._texCoord or { 0, 1, 0, 1 }
    local l, r, t, b = c[1], c[2], c[3], c[4]
    return l, t, l, b, r, t, r, b
end
-- Whether the cursor is over a frame: false unless a test puts the mouse there
-- (`frame._mouseOver = true`).
function Methods.IsMouseOver(self) return self._mouseOver == true end
function Methods.SetChecked(self, v) self._checked = v and true or false end
function Methods.GetChecked(self) return self._checked == true end
-- A texture's vertex TINT: white until set. Separate from SetColorTexture,
-- which the client does not report through GetVertexColor.
function Methods.SetVertexColor(self, r, g, b, a) self._vertexColor = { r, g, b, a }; return self end
function Methods.GetVertexColor(self)
    local c = self._vertexColor
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end
-- A tooltip's OWNER and anchor point: "where does this tooltip open".
function Methods.SetOwner(self, owner, anchor) self._owner, self._ownerAnchor = owner, anchor; return self end
function Methods.GetOwner(self) return self._owner end
function Methods.GetAnchorType(self) return self._ownerAnchor end
-- A text shadow defaults to none, which is the whole assertion: over glass a
-- shadow is what keeps a label legible.
function Methods.SetShadowOffset(self, x, y) self._shadowX, self._shadowY = x, y; return self end
function Methods.GetShadowOffset(self) return self._shadowX or 0, self._shadowY or 0 end
function Methods.SetShadowColor(self, r, g, b, a) self._shadowColor = { r, g, b, a }; return self end
function Methods.GetShadowColor(self)
    local c = self._shadowColor
    if not c then return 0, 0, 0, 0 end
    return c[1], c[2], c[3], c[4]
end
-- Text is REMEMBERED. Unlike the kit's, an EditBox's SetText does not run its
-- OnTextChanged: the suite's prompt and search tests were written that way.
function Methods.SetText(self, text) self._text = text; return self end
function Methods.GetText(self) return self._text end
function Methods.SetJustifyH(self, j) self._justifyH = j; return self end
function Methods.GetJustifyH(self) return self._justifyH end
-- Keyboard focus is ONE global slot, as on the client: an edit box that keeps
-- it after its prompt closes goes on eating every key the player presses.
function Methods.SetFocus(self) WoW.focus = self; return self end
function Methods.ClearFocus(self) if WoW.focus == self then WoW.focus = nil end; return self end
function Methods.HasFocus(self) return WoW.focus == self end
function Methods.HighlightText(self) self._highlighted = true; return self end
function Methods.SetMaxLetters(self, n) self._maxLetters = n; return self end
function Methods.GetMaxLetters(self) return self._maxLetters end

-- Geometry getters return NUMBERS, set or not: layout code does arithmetic on
-- them. A test pins one by writing the field (`frame._GetLeft = 40`).
local NUMERIC = {
    GetWidth = 100, GetHeight = 20, GetStringWidth = 40, GetStringHeight = 10,
    GetNumLines = 0, GetVerticalScroll = 0, GetHorizontalScroll = 0,
    GetVerticalScrollRange = 0, GetHorizontalScrollRange = 0,
    GetLeft = 0, GetRight = 100, GetTop = 100, GetBottom = 0,
    GetID = 0,
}
for name, value in pairs(NUMERIC) do
    Methods[name] = function(self) return self["_" .. name] or value end
end
-- A FontString is SHORTER than a layout stride, and TEXT-DEPENDENT: an
-- auto-sized one with no text has no height. An explicit SetHeight still wins,
-- as on the client. MODELLED, NOT MEASURED.
function Methods.GetHeight(self)
    if self._GetHeight then return self._GetHeight end
    if self._isFontString then
        local t = self._text
        return (t and t ~= "") and 12 or 0
    end
    return 20
end
-- A slider's or bar's value: the kit's SetValue (OnValueChanged on a change),
-- read back here as a number before anything set it.
function Methods.GetValue(self) return self._value or self._GetValue or 0 end
function Methods.GetScale(self) return self._scale or 1 end
function Methods.SetScale(self, v) self._scale = v; return self end
-- EFFECTIVE scale walks the parent chain, which is the whole difference
-- between it and GetScale (the window's screen clamp).
function Methods.GetEffectiveScale(self)
    local s, p, guard = self._scale or 1, self._parent, 0
    while p and guard < 32 do
        s = s * (p._scale or 1)
        p, guard = p._parent, guard + 1
    end
    return s
end
-- Movable is state (the kit has no SetMovable). Before the kit, the old stub's
-- unknown methods returned the frame itself, so IsMovable() was truthy for any
-- frame and "the sheet is still movable" (test_sheetui) passed whatever the
-- addon did.
function Methods.SetMovable(self, v) self._movable = v and true or false; return self end
function Methods.IsMovable(self) return self._movable == true end
function Methods.SetClampedToScreen(self, v) self._clamped = not not v; return self end
function Methods.IsClampedToScreen(self) return self._clamped == true end

-- SetTexture takes a path OR a file id, and the two behave DIFFERENTLY.
-- MEASURED on 1.60.1.70009: a file id is stored, not resolved; a nonsense one
-- is echoed straight back. A PATH resolving to a file id (and being able to
-- fail) is NOT MEASURED: modelled through WoW.textures, the one table that
-- already decides whether a path exists (GetFileIDFromPath reads it too).
function Methods.SetTexture(self, v)
    if type(v) == "number" then
        self._texture, self._fileID = v, v
    elseif type(v) == "string" then
        local id = GetFileIDFromPath(v)
        self._texture = id and v or nil
        self._fileID  = id
    else
        self._texture, self._fileID = nil, nil
    end
    return self
end
-- A SOLID COLOUR: recorded in `_colorTexture` rather than answered by a
-- getter, because the client has no GetColorTexture.
function Methods.SetColorTexture(self, r, g, b, a)
    self._colorTexture = { r, g, b, a }
    self._texture = nil                     -- a colour replaces any art
    return self
end
-- The material's API (#97): which region is masked by what and in what order.
function Methods.SetTextureSliceMargins(self, l, t, r, b) self._slice = { l, t, r, b }; return self end
function Methods.GetTextureSliceMargins(self) return self._slice end
function Methods.SetTextureSliceMode(self, m) self._sliceMode = m; return self end
function Methods.GetTextureSliceMode(self) return self._sliceMode end
function Methods.SetHorizTile(self, v) self._hTile = not not v; return self end
function Methods.SetVertTile(self, v) self._vTile = not not v; return self end
function Methods.SetBlendMode(self, m) self._blend = m; return self end
function Methods.GetBlendMode(self) return self._blend end
function Methods.SetGradient(self, orient, minC, maxC)
    self._gradient = { orient = orient, min = minC, max = maxC }
    return self
end
function Methods.AddMaskTexture(self, mask)
    self._masks = self._masks or {}
    self._masks[#self._masks + 1] = mask
    return self
end
function Methods.GetNumMaskTextures(self) return self._masks and #self._masks or 0 end
function Methods.GetMaskTexture(self, i) return self._masks and self._masks[i] end
function Methods.GetTexture(self) return self._texture end
function Methods.GetTextureFileID(self) return self._fileID end
function Methods.GetTextureFilePath(self) return type(self._texture) == "string" and self._texture or nil end

function Methods.SetFrameStrata(self, v) self._strata = v; return self end
function Methods.GetFrameStrata(self) return self._strata or "MEDIUM" end
-- Frame level: "which of two siblings takes the click". 1 until set.
function Methods.SetFrameLevel(self, v) self._GetFrameLevel = v; return self end
function Methods.GetFrameLevel(self) return self._GetFrameLevel or 1 end
-- Raise MOVES THE LEVEL, which is what anything watching sees.
function Methods.Raise(self) self._GetFrameLevel = (self._GetFrameLevel or 0) + 5; return self end
function Methods.GetChildren(self) return unpack(self._children or {}) end
-- SetParent MAINTAINS the child list, so GetChildren and GetParent agree where
-- the showcase lifts the sheet out from under UIParent.
function Methods.SetParent(self, p)
    local old = self._parent
    if type(old) == "table" and old._children then
        for i = #old._children, 1, -1 do
            if old._children[i] == self then table.remove(old._children, i) end
        end
    end
    self._parent = p
    if type(p) == "table" then
        p._children = p._children or {}
        p._children[#p._children + 1] = self
    end
    return self
end

-- Show and Hide FIRE their scripts, only on an actual change, and ON THE
-- DESCENDANTS, as the client does: hiding a parent fires OnHide on every child
-- that was on screen (their own shown flag untouched), showing it again fires
-- their OnShow. That is how hiding UIParent reaches the sheet (#89). A
-- protected frame in combat refuses, as in the kit.
local function cascade(frame, script)
    for _, c in ipairs(frame._children or {}) do
        if c._shown ~= false then
            local fn = c._scripts and c._scripts[script]
            if fn then fn(c) end
            cascade(c, script)
        end
    end
end
function Methods.Show(self)
    if WoW.refused(self, "Show") then return end
    local was = self._shown
    local wasVisible = Methods.IsVisible(self)
    self._shown = true
    if was ~= true and self._scripts.OnShow then self._scripts.OnShow(self) end
    if not wasVisible and Methods.IsVisible(self) then cascade(self, "OnShow") end
    return self
end
function Methods.Hide(self)
    if WoW.refused(self, "Hide") then return end
    local was = self._shown
    local wasVisible = Methods.IsVisible(self)
    self._shown = false
    if was ~= false and self._scripts.OnHide then self._scripts.OnHide(self) end
    if wasVisible then cascade(self, "OnHide") end
    return self
end
function Methods.IsShown(self) return self._shown ~= false end
function Methods.SetShown(self, v)
    if v then self:Show() else self:Hide() end
    return self
end
-- Visible means shown AND every ancestor shown.
function Methods.IsVisible(self)
    if self._shown == false then return false end
    local p = self._parent
    while p do
        if p._shown == false then return false end
        p = p._parent
    end
    return true
end

-- Enabled state: `nil` DISABLES, matching the client; never having been
-- called, a widget is enabled.
function Methods.SetEnabled(self, v) self._enabled = not not v; return self end
function Methods.Enable(self) self._enabled = true; return self end
function Methods.Disable(self) self._enabled = false; return self end
function Methods.IsEnabled(self) return self._enabled ~= false end
-- Word wrap: on unless turned off; the same nil rule.
function Methods.SetWordWrap(self, v) self._wrap = not not v; return self end
function Methods.GetWordWrap(self) return self._wrap ~= false end
-- SetNonSpaceWrap / CanNonSpaceWrap (SimpleFontStringAPI): off by default.
function Methods.SetNonSpaceWrap(self, v) self._nonSpaceWrap = not not v; return self end
function Methods.CanNonSpaceWrap(self) return self._nonSpaceWrap == true end

-- Anchors: SetPoint is variadic in the client; all three arities are
-- normalised. An anchor given without a frame is to the PARENT, without a
-- relative point to the same point. It REPLACES the anchor for a point
-- already set, as the client does: a pooled menu entry re-anchored on every
-- open must not accumulate stale anchors.
function Methods.SetPoint(self, point, a, b, c, d)
    if WoW.refused(self, "SetPoint") then return end
    local rel, relPoint, x, y
    if type(a) == "number" then
        x, y = a, b
    elseif type(b) == "number" then
        rel, x, y = a, b, c
    else
        rel, relPoint, x, y = a, b, c, d
    end
    if rel == nil then rel = self._parent end
    if relPoint == nil then relPoint = point end
    self._points = self._points or {}
    for _, existing in ipairs(self._points) do
        if existing.point == point then
            existing.rel, existing.relPoint, existing.x, existing.y = rel, relPoint, x, y
            return self
        end
    end
    self._points[#self._points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
    return self
end
function Methods.ClearAllPoints(self) self._points = nil; return self end
-- REPLACES the anchors: "does this region cover its whole frame".
function Methods.SetAllPoints(self, rel) self._points = nil; self._allPoints = rel or true; return self end
function Methods.GetNumPoints(self) return self._points and #self._points or 0 end
function Methods.GetPoint(self, i)
    local pt = self._points and self._points[i or 1]
    if not pt then return nil end
    return pt.point, pt.rel, pt.relPoint, pt.x, pt.y
end

-- Alpha: dimming a hidden character's row IS the feature (#69), on pooled rows.
function Methods.SetAlpha(self, a) self._GetAlpha = a; return self end
function Methods.GetAlpha(self) return self._GetAlpha or 1 end

-- Attributes are the kit's (stored, refused on a protected frame in combat),
-- which the kit's secure click reads.
-- Which buttons a Button actually listens for: LEFT only until
-- RegisterForClicks says otherwise.
function Methods.RegisterForClicks(self, ...) self._clicks = { ... }; return self end
function WoW.registeredClicks(self) return self._clicks or {} end
function WoW.handlesClick(self, button)
    for _, c in ipairs(self._clicks or {}) do
        if c == button .. "Up" or c == button .. "Down" or c == "AnyUp" or c == "AnyDown" then
            return true
        end
    end
    return self._clicks == nil and button == "LeftButton" or false
end
-- DISABLED BY DEFAULT for a Frame, ENABLED for a Button (CreateFrame below).
-- `v == true`: the client reads EnableMouse(nil) as DISABLE.
function Methods.EnableMouse(self, v) self._mouse = v == true; return self end
function Methods.IsMouseEnabled(self) return self._mouse == true end
function Methods.EnableKeyboard(self, v) self._keyboard = v ~= false; return self end
function Methods.IsKeyboardEnabled(self) return self._keyboard == true end
function Methods.SetPropagateKeyboardInput(self, v) self._propagate = v; return self end
function Methods.SetWidth(self, w) self._GetWidth = w; return self end
function Methods.SetHeight(self, h) self._GetHeight = h; return self end
function Methods.SetSize(self, w, h) self._GetWidth, self._GetHeight = w, h; return self end
function Methods.SetClipsChildren(self, v) self._clipsChildren = v and true or false; return self end
function Methods.DoesClipChildren(self) return self._clipsChildren == true end
-- The highlight is a texture that exists once it is set, as on the client.
function Methods.SetHighlightTexture(self, path, blend)
    local t = self._highlight or self:CreateTexture(nil, "HIGHLIGHT")
    t._path, t._blend = path, blend
    self._highlight = t
    return self
end
function Methods.GetHighlightTexture(self) return self._highlight end

-- Templates: the children Blizzard's XML gives them, by parentKey
-- (wow-ui-source, 70862). Only the keys anything here reads.
local function fontChild(w, key) w[key] = Methods.CreateFontString(w); return w[key] end
local function textureChild(w, key) w[key] = Methods.CreateTexture(w); return w[key] end
-- UISliderTemplateWithLabels (SharedUIPanelTemplates.xml): Text, Low, High.
WoW.templates.OptionsSliderTemplate = function(w)
    fontChild(w, "Text"); fontChild(w, "Low"); fontChild(w, "High")
end
-- UICheckButtonTemplate (CheckButtonTemplates.xml): Text.
WoW.templates.UICheckButtonTemplate = function(w) fontChild(w, "Text") end
-- UIPanelButtonNoTooltipTemplate (SecureUIPanelTemplates.xml): Left, Right,
-- Middle, and its ButtonText as Text.
WoW.templates.UIPanelButtonTemplate = function(w)
    textureChild(w, "Left"); textureChild(w, "Right"); textureChild(w, "Middle"); fontChild(w, "Text")
end
-- UIPanelScrollFrameTemplate (SecureScrollTemplates.xml): ScrollBar.
WoW.templates.UIPanelScrollFrameTemplate = function(w) w.ScrollBar = newWidget("Slider", w) end

-- The PARENT argument is honoured and a named frame becomes a global (the
-- kit's CreateFrame); a Button takes the mouse from the moment it exists, a
-- Frame does not until something says so.
do
    local kitCreateFrame = CreateFrame
    function CreateFrame(kind, name, parent, template, ...)
        local f = kitCreateFrame(kind, name, parent, template, ...)
        f._mouse = (kind == "Button" or kind == "CheckButton")
        return f
    end
end

-- A DISPLAY-SIZED UIParent: 1365x768 at scale 1.4, ~1911x1075 physical, a
-- 1080p display at the client's default UI scale. The scale is not 1, or any
-- conversion between effective and own scale is untestable. MODELLED.
UIParent:SetSize(1365, 768)
UIParent:SetScale(1.4)
WorldFrame = newWidget("Frame", nil, "WorldFrame")

-- The cursor, in PHYSICAL pixels: code that places something at the cursor
-- has to divide by the effective scale.
WoW.cursorX, WoW.cursorY = 800, 600
function GetCursorPosition() return WoW.cursorX, WoW.cursorY end

-- WoW's table helpers, which are globals there and absent in plain Lua 5.1.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
-- WoW hoists a few math/string functions to globals.
floor, ceil, abs, min, max = math.floor, math.ceil, math.abs, math.min, math.max
format, strsub, strlower, strupper = string.format, string.sub, string.lower, string.upper
function tinsert(...) return table.insert(...) end
function tremove(...) return table.remove(...) end
function tContains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
UISpecialFrames = UISpecialFrames or {}

------------------------------------------------------------
-- Secret values: the kit's (WoW.Secret, issecretvalue). Arithmetic, ordering,
-- tostring and concatenation on one throw, which is what aborted a live
-- character scan. WoW.secret(n) is the suite's name for one.
------------------------------------------------------------

function WoW.secret(n) return WoW.Secret("secret " .. tostring(n)) end

-- Timers: AltStable's own, in place of the kit's, because the suite reads
-- them this way. Pending one-shots land in WoW.timers as { delay =, fn = },
-- so a test can assert WHEN something was scheduled; a cancelled NewTimer
-- drops out of the queue; a ticker repeats, lives in WoW.tickers (not
-- WoW.timers, so a one-shot count still means one-shots) and survives
-- WoW.reset(), as Core's 60-second sweep registered at load must.
C_Timer = {
    After = function(delay, fn)
        table.insert(WoW.timers, { delay = delay, fn = fn })
    end,
    NewTimer = function(delay, fn)
        local entry = { delay = delay, fn = fn }
        table.insert(WoW.timers, entry)
        entry.Cancel = function()
            for i, e in ipairs(WoW.timers) do
                if e == entry then table.remove(WoW.timers, i); return end
            end
        end
        return entry
    end,
    NewTicker = function(delay, fn)
        local entry = { delay = delay, ticker = true }
        entry.Cancel = function()
            entry.cancelled = true
            for i, e in ipairs(WoW.tickers) do
                if e == entry then table.remove(WoW.tickers, i); return end
            end
        end
        entry.fn = function() fn(entry) end
        table.insert(WoW.tickers, entry)
        return entry
    end,
}

-- One flush is one tick: every pending one-shot fires and is gone, and every
-- live ticker fires once and stays. A test advances N ticks by flushing N times.
function WoW.flushTimers()
    local t = WoW.timers
    WoW.timers = {}
    for _, e in ipairs(t) do e.fn() end
    local ticking = {}
    for _, e in ipairs(WoW.tickers) do ticking[#ticking + 1] = e end
    for _, e in ipairs(ticking) do
        if not e.cancelled then e.fn() end
    end
end

-- Combat is the kit's: WoW.combat, read by InCombatLockdown.

-- A colour OBJECT, which is what SetGradient takes on this client - not four
-- numbers. Absent entirely until the glass material needed it, so Glass.Apply
-- threw on load in the test harness while working fine in game.
function CreateColor(r, g, b, a)
    return { r = r, g = g, b = b, a = a,
             GetRGBA = function(self) return self.r, self.g, self.b, self.a end,
             GetRGB  = function(self) return self.r, self.g, self.b end }
end


-- The stat block, so a full ScanCharacter runs. Values are arbitrary but
-- DISTINCT: identical numbers would let a scan that wrote the wrong field into
-- the wrong key pass unnoticed.
function UnitStat(_, i) return 0, 10 + i end          -- base, total
function UnitHealthMax() return 3210 end
function UnitPowerMax() return 4870 end
function UnitArmor() return 0, 812 end
function UnitAttackPower() return 100, 20, 12 end     -- base, positive, negative
function GetSpellBonusDamage(school) return 700 + school end
-- (UnitDefenseSkill is stubbed further down, pinned to the MEASURED
-- (base, modifier) pair. Do not redefine it here.)

-- Melee crit and hit, for the detail pane's Combat section. Both exist in
-- Vanilla. Their two neighbours in AltTracker's table are deliberately NOT
-- stubbed - there is no haste rating pre-TBC and resilience is a TBC PvP stat,
-- so a stub for either would let a port of the TBC table pass here and then
-- report a real 0% in game for something that does not exist.
--
-- Both are MEASURED on 1.60.1.70009 and both are scanned: GetCritChance gave
-- 1.66% on a level 18 gnome warlock, GetHitModifier printed 0 rather than
-- ABSENT or nil - a working function answering for a character with no +hit
-- gear. Neither is on Core's RETIRED_FIELDS any more.
--
-- The values here are DISTINCT and neither is zero, deliberately: a stub
-- returning 0 for bonus hit would make "the field is stored" and "the field was
-- defaulted" the same observation, and the display rule under test is precisely
-- what happens at zero.
function GetCritChance() return WoW.critChance end
function GetHitModifier() return WoW.hitModifier end

-- Dead or a ghost. Both states, one call, which is why the code uses it: a
-- corpse run is the second, and a portrait taken during one is a picture of a
-- wisp - while C_PlayerInfo.GetDisplayID() reports the ghost display and makes
-- the look fingerprint flip on every death and every resurrection.
WoW.dead = false
function UnitIsDeadOrGhost(unit)
    if unit ~= "player" then return false end
    return WoW.dead and true or false
end

-- The display id. Part of the look fingerprint, deliberately, because a barber
-- visit or a race change should refresh a portrait - and without this stub the
-- fingerprint silently appended "?" every time, so a constant in its place
-- left the suite green.
--
-- It does NOT change when the player dies. MEASURED on 1.60.1.70009: 56658
-- both alive and as a ghost. An earlier version of this stub returned a
-- separate ghost display, which would have made a broken theory pass - exactly
-- the failure mode the stub-fidelity rule exists for, since the theory was
-- that this value flips on death.
WoW.displayID = 56658
C_PlayerInfo = C_PlayerInfo or {}
function C_PlayerInfo.GetDisplayID()
    return WoW.displayID
end

-- Where the player is, and whether they are standing still.
--
-- instanceType is "none" in the open world and names the kind otherwise.
WoW.instanceType = "none"
function IsInInstance()
    return WoW.instanceType ~= "none", WoW.instanceType
end

WoW.speed, WoW.falling = 0, false
function GetUnitSpeed(unit)
    if unit ~= "player" then return 0 end
    return WoW.speed or 0
end
function IsFalling() return WoW.falling and true or false end

-- SetUIVisibility is what Alt+Z and Escape call. It is NOT protected, which is
-- the whole reason the probe uses it instead of UIParent:Hide().
WoW.uiVisible = true
function SetUIVisibility(visible)
    WoW.uiVisible = visible and true or false
    -- It really does hide UIParent - callers check IsShown() to find out
    -- whether the call took, and a stub that only flipped a flag of its own
    -- made every one of them conclude it had failed.
    if UIParent then
        if WoW.uiVisible then UIParent:Show() else UIParent:Hide() end
    end
end

WoW.screenshots = 0
function Screenshot() WoW.screenshots = WoW.screenshots + 1 end

-- ReloadUI counts rather than reloads: a test asserts that the capture's reload
-- prompt reloads when accepted, and nothing else in a stub run can.
WoW.reloaded = 0
function ReloadUI() WoW.reloaded = WoW.reloaded + 1 end

-- Sounds played, by kit ID. SOUNDKIT is Blizzard's constant table; only the
-- entries the addon uses are here, with the values from the client's own
-- Mainline SoundKitConstants.lua (1.60.1.70009).
WoW.sounds = {}
SOUNDKIT = { REPORT_SCREENSHOT_CAMERA = 230810 }
function PlaySound(id) table.insert(WoW.sounds, id); return true end

-- What the player is wearing, by slot. The probe fingerprints this to decide
-- whether a portrait is stale, so a capture that runs to completion reaches it.
WoW.equipped = {}
-- The id behind the link, as the client derives it: nothing equipped, nil.
function GetInventoryItemID(unit, slot)
    local link = WoW.equipped[slot]
    return link and tonumber(tostring(link):match("item:(%d+)")) or nil
end
function GetInventoryItemLink(unit, slot)
    return WoW.equipped[slot]
end

-- Physical pixels, which is what a screenshot is measured in. GetScreenWidth /
-- GetScreenHeight are UI units and are a different number; the probe records
-- both from ONE source for that reason, so the stub keeps them distinct.
WoW.screenW, WoW.screenH = 3840, 2160
function GetPhysicalScreenSize() return WoW.screenW, WoW.screenH end
function GetScreenWidth() return WoW.screenW / 2 end
function GetScreenHeight() return WoW.screenH / 2 end

-- The mail actions the Warband plugin post-hooks (#312). They do nothing here:
-- the server's answer is the test's to fire (MAIL_SEND_SUCCESS, MAIL_FAILED).
function SendMail(recipient, subject, body) end
function ReturnInboxItem(index) end

-- A REAL post-hook: it wraps the global so the hook actually runs afterwards.
-- An inert stub would have made the Alt+Z-during-capture path untestable, which
-- is the path that had the bug.
-- BOTH FORMS, as the client has them: hooksecurefunc(name, fn) for a global,
-- and hooksecurefunc(table, name, fn) for a method. Only the first existed
-- here, so a hook on GameTooltip:SetOwner - the one that catches a tooltip
-- changing hands WITHOUT hiding - silently did nothing and could not be
-- tested at all.
function hooksecurefunc(a, b, c)
    local host, name, fn
    if type(a) == "table" then host, name, fn = a, b, c
    else host, name, fn = _G, a, b end
    local prev = host[name]
    -- The client raises "Attempt to hook a nonexistent function". Returning
    -- quietly here installs nothing and no test can tell - which is the gap
    -- this stub was just extended to close, reopened one line lower.
    if type(prev) ~= "function" then
        error("Attempt to hook a nonexistent function: " .. tostring(name), 2)
    end
    WoW.hooked[host] = WoW.hooked[host] or {}
    WoW.hooked[host][name] = (WoW.hooked[host][name] or 0) + 1
    host[name] = function(...)
        local r = { prev(...) }
        fn(...)
        return unpack(r)
    end
end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(WoW.chatOut, m) end }

-- GameTooltip, recording what an OnEnter would draw: WoW.tooltipLines. Without
-- it every hover path in the addon is unreachable from a test - the code calls
-- a global that simply is not there, so a tooltip that shows the wrong thing
-- (or nothing) can only be caught in game.
GameTooltip = newWidget("GameTooltip", nil, "GameTooltip")
GameTooltip.ClearLines = function() WoW.tooltipLines = {} end
GameTooltip.AddLine = function(_, text) table.insert(WoW.tooltipLines, tostring(text)) end
GameTooltip.AddDoubleLine = function(_, l, r)
    table.insert(WoW.tooltipLines, tostring(l) .. "|" .. tostring(r))
end
GameTooltip.NumLines = function() return #WoW.tooltipLines end
-- Show/Hide RECORD the flag and still fire the frame's scripts. Replacing
-- makeFrame's versions with bare flag flips meant OnShow and OnHide never ran
-- on this frame, and anything hooked to them was untestable.
do
    local baseShow, baseHide = GameTooltip.Show, GameTooltip.Hide
    GameTooltip.Show = function(self, ...)
        WoW.tooltipShown = true
        return baseShow(self or GameTooltip, ...)
    end
    GameTooltip.Hide = function(self, ...)
        WoW.tooltipShown = false
        return baseHide(self or GameTooltip, ...)
    end
end
GameTooltip.IsShown = function() return WoW.tooltipShown == true end
-- The OWNER is real state too, as on the client: SetOwner records it, hiding
-- clears it, and IsOwned compares. The chaining default answered "yes, yours"
-- to every frame, so a hover that never raised the tooltip, or a leave that
-- never hid it, passed.
do
    local baseSetOwner, hide = GameTooltip.SetOwner, GameTooltip.Hide
    GameTooltip.SetOwner = function(self, owner, ...)
        WoW.tooltipOwner = owner
        if baseSetOwner then return baseSetOwner(self, owner, ...) end
    end
    GameTooltip.Hide = function(self, ...)
        WoW.tooltipOwner = nil
        return hide(self, ...)
    end
    GameTooltip.GetOwner = function() return WoW.tooltipOwner end
    GameTooltip.IsOwned = function(_, f) return f ~= nil and WoW.tooltipOwner == f end
end
-- The border an 11.x client keeps in a NineSlice child. Modelled because the
-- addon hides it while a tooltip is ours and has to put it back afterwards -
-- and "did it put it back" is the whole risk of touching a frame every other
-- addon shares.
GameTooltip.NineSlice = makeFrame()

------------------------------------------------------------
-- CVars and the camera
--
-- A CVar that does not exist reads as nil, exactly as on the client - which is
-- the case that matters for restore code: writing a default over a setting the
-- player never had is not a restore, it is an invention.
------------------------------------------------------------

function GetCVar(name) return WoW.cvars[name] end
function SetCVar(name, value)
    WoW.cvars[name] = tostring(value)
    return true
end
function GetCVarBool(name) return WoW.cvars[name] == "1" end

function GetCameraZoom() return WoW.camera.zoom end
function CameraZoomIn(d) WoW.camera.zoom = math.max(0, WoW.camera.zoom - (d or 1)) end
function CameraZoomOut(d) WoW.camera.zoom = WoW.camera.zoom + (d or 1) end
function SaveView(slot) WoW.camera.savedViews[slot or 1] = WoW.camera.zoom end
function SetView(slot) WoW.camera.view = slot end

-- StaticPopup, recording rather than drawing: WoW.popups. The confirmation
-- before a destructive-looking action is part of the behaviour (#21), so a test
-- has to be able to see that the popup was RAISED and that accepting it is what
-- performs the action - not the click itself.
StaticPopupDialogs = {}
-- Returns the dialog FRAME, as the client does - not the definition table. A
-- stub handing back the definition lets caller-side code mutate a shared table
-- by accident and hides the parent/visibility problem completely.
--
-- The dialog is parented to UIParent and OnShow only runs when it can actually
-- become visible. That is the rule the whole "invisible confirmation" bug turns
-- on: with the game UI hidden, a fix living in OnShow never runs at all.
function StaticPopup_Show(which, arg1, arg2, data)
    local def = StaticPopupDialogs[which]
    if not def then return nil end
    -- The client returns nil when it cannot show one (every dialog slot busy,
    -- or a show condition failed) - and calls OnCancel(nil, data) first. A
    -- caller that counts the popup as shown without looking is wrong there.
    if WoW.popupRefused then
        if type(def.OnCancel) == "function" then def.OnCancel(nil, data) end
        return nil
    end

    local dialog = WoW.makeFrame()
    dialog._parent = UIParent
    dialog._strata = "DIALOG"
    dialog.which = which
    dialog.data = data
    -- GameDialogMixin:GetEditBox (Blizzard_StaticPopup_Game, 70170): every
    -- dialog has one; hasEditBox decides whether it is shown.
    dialog.EditBox = WoW.makeFrame()
    dialog.GetEditBox = function(self) return self.EditBox end
    dialog:Show()

    table.insert(WoW.popups, {
        which = which, arg1 = arg1, arg2 = arg2, data = data, dialog = dialog,
    })

    if type(def.OnShow) == "function" and dialog:IsVisible() then
        def.OnShow(dialog, data)       -- StaticPopup_OnShow passes dialog.data
    end
    return dialog
end

function StaticPopup_Hide(which)
    for i = #WoW.popups, 1, -1 do
        local p = WoW.popups[i]
        if p.which == which and p.dialog then
            local def = StaticPopupDialogs[which]
            p.dialog:Hide()
            if type(def) == "table" and type(def.OnHide) == "function" then
                def.OnHide(p.dialog)
            end
        end
    end
end

function StaticPopup_Visible(which)
    for _, p in ipairs(WoW.popups) do
        if p.which == which and p.dialog and p.dialog:IsShown() then return true end
    end
    return false
end
-- The client's localized button captions. Defined because the dialog table
-- reads them at file scope. ACCEPT/CANCEL matter as much as YES/NO now that
-- the forget confirmation uses them: absent, "ACCEPT or 'Forget'" silently
-- takes the fallback and a test on the button text passes for the wrong
-- reason.
YES, NO = "Yes", "No"
ACCEPT, CANCEL = "Accept", "Cancel"

------------------------------------------------------------
-- Enums, measured from the live client
------------------------------------------------------------

Enum = {
    SendAddonMessageResult = {
        Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
        InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7,
        ChannelThrottle = 8, GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11,
        TargetOffline = 12,
    },
    BagIndex = {
        Keyring = -1, Characterbanktab = -2, Accountbanktab = -3,
        Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4,
        ReagentBag = 5,
        CharacterBankTab_1 = 6,  CharacterBankTab_2 = 7,  CharacterBankTab_3 = 8,
        CharacterBankTab_4 = 9,  CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
        CharacterBankTab_7 = 12, CharacterBankTab_8 = 13, CharacterBankTab_9 = 14,
        AccountBankTab_1 = 15, AccountBankTab_2 = 16, AccountBankTab_3 = 17,
        AccountBankTab_4 = 18, AccountBankTab_5 = 19, AccountBankTab_6 = 20,
        AccountBankTab_7 = 21, AccountBankTab_8 = 22, AccountBankTab_9 = 23,
    },
    BankType = { Character = 0, Guild = 1, Account = 2 },
    TooltipDataType = { Item = 0 },
    -- Measured on 1.60.1.70291 (/asprobe enchant, #94): the ones the addon reads.
    TooltipDataLineType = { None = 0, SellPrice = 11, ItemEnchantmentPermanent = 15,
                            ItemBinding = 20, EquipSlot = 21, ItemName = 22 },
}

-- C_TooltipInfo.GetInventoryItem, in the shape measured on 1.60.1.70291: a table
-- whose `lines` are typed, and the permanent enchant is its own line type with
-- the words in leftText - "Enchanted: Stamina +2", enchantID = 41. Like the
-- client, any EQUIPPED slot answers with a table (its name line, unless a test
-- puts lines in WoW.slotTooltip[slot]); an empty slot answers nil.
WoW.slotTooltip = {}
C_TooltipInfo = {
    GetInventoryItem = function(unit, slot)
        local link = WoW.equipped[slot]
        if not link then return nil end
        local lines = WoW.slotTooltip and WoW.slotTooltip[slot]
        if not lines then
            lines = { { type = 22, leftText = tostring(link):match("%[(.-)%]") or "" } }
        end
        return { dataInstanceID = 1, guid = "Item-0", type = 0,
                 id = tonumber(tostring(link):match("item:(%d+)")) or 0, lines = lines }
    end,
}
ENCHANTED_TOOLTIP_LINE = "Enchanted: %s"
-- GlobalStrings: the faction names, as the enUS client has them.
FACTION_ALLIANCE = "Alliance"
FACTION_HORDE = "Horde"

------------------------------------------------------------
-- C_Item  (tuple returns, Classic order)
------------------------------------------------------------

local function itemID(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    return tonumber(v:match("item:(%d+)")) or tonumber(v)
end

C_Item = {
    -- A cache miss returns NOTHING. `return` with no values, not `return nil`:
    -- select("#", ...) must be 0, which is what the live client does and what
    -- the adapter has to preserve.
    GetItemInfo = function(v)
        local it = WoW.items[itemID(v) or -1]
        if not it then return end
        local id = itemID(v)
        return it.name, "|Hitem:" .. id .. "|h[" .. (it.name or "") .. "]|h",
               it.quality, it.ilvl, it.minLevel or 0,
               it.itemType, it.subType, it.stackCount or 1,
               it.equipLoc, it.icon, it.sellPrice or 0,
               it.classID, it.subClassID, it.bindType or 0,
               it.expacID or 0, it.setID, it.isReagent or false, ""
    end,
    GetItemInfoInstant = function(v)
        local id = itemID(v)
        local it = WoW.items[id or -1]
        if not it then return end
        return id, it.itemType, it.subType, it.equipLoc, it.icon, it.classID, it.subClassID
    end,
    GetItemIconByID = function(v)
        local it = WoW.items[itemID(v) or -1]
        return it and it.icon or nil
    end,
    -- Present, and takes an ItemLocation - calling it with an item id errors,
    -- exactly as measured. Kept so a test can prove we never call it.
    GetItemIcon = function(loc)
        if type(loc) ~= "table" then
            error("bad argument #1 to 'GetItemIcon' (Usage: local icon = C_Item.GetItemIcon(itemLocation))", 2)
        end
        return nil
    end,
    GetItemCount = function(v) local it = WoW.items[itemID(v) or -1]; return it and (it.count or 0) or 0 end,
    GetItemStats = function(v) local it = WoW.items[itemID(v) or -1]; if not it then return end; return it.stats or {} end,
    GetItemQualityByID = function(v) local it = WoW.items[itemID(v) or -1]; return it and it.quality or nil end,
    -- optional itemName (70532 dump): nil on a cache miss, until the load is asked for.
    GetItemNameByID = function(v) local it = WoW.items[itemID(v) or -1]; return it and it.name or nil end,
    RequestLoadItemDataByID = function(v)
        WoW.itemLoadRequests = WoW.itemLoadRequests or {}
        WoW.itemLoadRequests[#WoW.itemLoadRequests + 1] = itemID(v)
    end,
}

------------------------------------------------------------
-- C_SkillInfo  (STRUCT)
------------------------------------------------------------

C_SkillInfo = {
    GetNumSkillLines = function() return #WoW.skillLines end,
    GetSkillLineInfo = function(i) return WoW.skillLines[i] end,
}

------------------------------------------------------------
-- C_Reputation  (STRUCT)
------------------------------------------------------------

-- WoW.factions is the full list in order. As on the client, a collapsed
-- header hides the rows under it (up to the next header) from the indexed
-- calls; Expand/Collapse change what those calls see. One level of nesting.
local function VisibleFactions()
    local out, hiding = {}, false
    for _, f in ipairs(WoW.factions) do
        if f.isHeader then out[#out + 1] = f; hiding = f.isCollapsed
        elseif not hiding then out[#out + 1] = f end
    end
    return out
end

C_Reputation = {
    GetNumFactions        = function() return #VisibleFactions() end,
    GetFactionDataByIndex = function(i) return VisibleFactions()[i] end,
    ExpandAllFactionHeaders = function()
        for _, f in ipairs(WoW.factions) do if f.isHeader then f.isCollapsed = false end end
    end,
    CollapseFactionHeader = function(i)
        local f = VisibleFactions()[i]
        if f and f.isHeader then f.isCollapsed = true end
    end,
    -- Deliberately backed by a SEPARATE table: the live client returns
    -- factions that are not in the indexed list, which is the whole reason we
    -- key reputations off ids instead of walking the UI list.
    GetFactionDataByID    = function(id) return WoW.factionByID[id] end,
}

------------------------------------------------------------
-- C_Container  (STRUCT)
------------------------------------------------------------

C_Container = {
    GetContainerNumSlots = function(bag) local b = WoW.containers[bag]; return b and b.size or 0 end,
    GetBagName           = function(bag) local b = WoW.containers[bag]; return b and b.name or nil end,
    GetContainerItemInfo = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] or nil
    end,
    GetContainerItemLink = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] and b[slot].hyperlink or nil
    end,
    GetContainerItemID = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] and b[slot].itemID or nil
    end,
}

------------------------------------------------------------
-- C_Bank
------------------------------------------------------------

-- TooltipDataProcessor: the Retail replacement for the OnTooltipSetItem script
-- hook, which THROWS on this client (see HookScript above). Registered
-- post-calls land in WoW.tooltipPostCalls[dataType] so a test can fire one.
TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
        WoW.tooltipPostCalls[dataType] = WoW.tooltipPostCalls[dataType] or {}
        table.insert(WoW.tooltipPostCalls[dataType], fn)
    end,
}

-- The struct measured on 70938 (Compat.lua, "Currencies"). WoW.currencies[id]
-- is the quantity; an id not in it reads as a currency the character has none of.
C_CurrencyInfo = {
    GetCurrencyInfo = function(id)
        if type(id) ~= "number" then error("Usage: C_CurrencyInfo.GetCurrencyInfo(type)") end
        local q = WoW.currencies[id]
        return { currencyID = id, quantity = q or 0, discovered = q ~= nil, isAccountWide = false }
    end,
}

C_Bank = {
    FetchPurchasedBankTabIDs = function(bankType)
        if bankType == Enum.BankType.Character then return WoW.bankTabs end
        if bankType == Enum.BankType.Account   then return WoW.accountTabs end
        return {}
    end,
    FetchNumPurchasedBankTabs = function(bankType)
        return #(C_Bank.FetchPurchasedBankTabIDs(bankType))
    end,
    CanViewBank = function(bankType) return bankType == Enum.BankType.Character end,
    FetchViewableBankTypes = function() return { Enum.BankType.Character } end,
}

------------------------------------------------------------
-- C_AddOns / C_ChatInfo
------------------------------------------------------------

C_AddOns = {
    IsAddOnLoaded    = function(a) return WoW.loaded[a] == true end,
    LoadAddOn        = function(a) table.insert(WoW.loadCalls, a); WoW.loaded[a] = true; return true end,
    GetAddOnMetadata = function(_, field) return field == "Version" and "dev" or nil end,
}

WoW.ctlDefer, WoW.ctlQueue, WoW.ctlHeld = false, {}, {}
function WoW.ctlDrain(n)
    WoW.ctlHeld = {}                     -- the blocked queues come back
    for _ = 1, n or #WoW.ctlQueue do
        local send = table.remove(WoW.ctlQueue, 1)
        if not send then return end
        send()
    end
end

-- SendAddonMessage returns an Enum.SendAddonMessageResult on this client, not
-- a boolean (API docs, 70009): 0 Success, 3 AddonMessageThrottle - the server's
-- per-prefix throttle - and so on. WoW.sendResults queues the results the next
-- sends get (default Success); a throttled message is NOT delivered.
-- ChatThrottleLib v24 ignored the result and lost throttled messages; v32
-- retries them, which is what test_ctl checks against the real library.
WoW.sendResults = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        local result = table.remove(WoW.sendResults, 1) or 0
        if result ~= 0 then return result end
        -- prio is set only when the send came through ChatThrottleLib, so a
        -- raw send is distinguishable from a paced one.
        table.insert(WoW.sent, { prefix = prefix, text = text, channel = channel,
                                 target = target, prio = WoW.pendingPrio,
                                 queue = WoW.pendingQueue })
        return 0
    end,
    -- Present on the client; ChatThrottleLib hooks both.
    SendAddonMessageLogged = function() return 0 end,
    SendChatMessage = function() end,
}
-- Battle.net, as measured on 70124 (#58, docs/SYNC-DISCOVERY.md):
--   * game account ids are small handles LOCAL to this client (WoW.bn.myId is
--     ours); an id this client does not know is TargetRequired;
--   * GetAccountInfoByGUID(guid).bnetAccountID says whose Battle.net account a
--     character is on - WoW.bn.me is ours; a friend's account has another;
--   * BN_CHAT_MSG_ADDON delivers (prefix, text, "WHISPER", senderID).
-- A test declares the other side with WoW.bn.accounts[id] = { characterName,
-- playerGuid, isOnline, clientProgram, wowProjectID, isInCurrentRegion,
-- factionName, realmName, bnetAccountID }.
-- regionID: 90 on the Forever beta (measured).
-- WoW.bn.blank = true models our own presence right after a login/reload
-- (measured): no account record, our own game account with no character.
-- WoW.bn.friends = { { 9, 10 }, ... }: each friend's online game account ids.
WoW.bn = { me = 1, myId = 2, project = 18, tag = "Owner#1", connected = true, accounts = {}, friends = {} }
local function bnSelf()
    if WoW.bn.blank then
        return { gameAccountID = WoW.bn.myId, isOnline = true, clientProgram = "WoW",
                 isInCurrentRegion = true }
    end
    return { gameAccountID = WoW.bn.myId, characterName = WoW.player.name,
             playerGuid = WoW.player.guid, isOnline = true, clientProgram = "WoW",
             wowProjectID = WoW.bn.project, isInCurrentRegion = true, regionID = 90,
             factionName = WoW.faction or "Horde", realmName = WoW.player.normalizedRealm }
end
local function bnCopy(t, id)
    if not t then return nil end
    local c = {}
    for k, v in pairs(t) do if k ~= "bnetAccountID" then c[k] = v end end
    c.gameAccountID = id
    return c
end
C_BattleNet = C_BattleNet or {}
function C_BattleNet.GetGameAccountInfoByID(id)
    if id == WoW.bn.myId then return bnSelf() end
    return bnCopy(WoW.bn.accounts[id], id)
end
function C_BattleNet.GetGameAccountInfoByGUID(guid)
    -- Blank, our own GUID finds nothing either (measured: "game account nil").
    if guid == WoW.player.guid then
        if WoW.bn.blank then return nil end
        return bnSelf()
    end
    for id, a in pairs(WoW.bn.accounts) do
        if a.playerGuid == guid then return bnCopy(a, id) end
    end
end
function C_BattleNet.GetAccountInfoByGUID(guid)
    if guid == WoW.player.guid then
        if WoW.bn.me == nil or WoW.bn.blank then return nil end
        return { bnetAccountID = WoW.bn.me, battleTag = WoW.bn.tag, gameAccountInfo = bnSelf() }
    end
    for id, a in pairs(WoW.bn.accounts) do
        if a.playerGuid == guid then
            -- Our own accounts carry our BattleTag; a friend's, theirs.
            local tag = a.battleTag
            if tag == nil and a.bnetAccountID ~= nil then
                tag = (a.bnetAccountID == WoW.bn.me) and WoW.bn.tag or ("Other#" .. a.bnetAccountID)
            end
            return { bnetAccountID = a.bnetAccountID, battleTag = tag, gameAccountInfo = bnCopy(a, id) }
        end
    end
end
-- Recorded in WoW.sent with channel "BNET" and the id as target. A result
-- queued in WoW.sendResults decides first (shared with addon sends); then an
-- id this client does not know, or one gone offline, is refused as measured.
function C_BattleNet.SendGameData(id, prefix, text)
    local result = table.remove(WoW.sendResults, 1)
    if result == nil then
        local a = (id == WoW.bn.myId) and bnSelf() or WoW.bn.accounts[id]
        result = (a == nil) and 6 or (a.isOnline and 0 or 12)
    end
    if result ~= 0 then return result end
    table.insert(WoW.sent, { prefix = prefix, text = text, channel = "BNET", target = id,
                             prio = WoW.pendingPrio, queue = WoW.pendingQueue })
    return 0
end
function BNFeaturesEnabledAndConnected() return WoW.bn.connected ~= false end
function BNGetNumFriends() return #WoW.bn.friends, #WoW.bn.friends end
function C_BattleNet.GetFriendNumGameAccounts(i) return #(WoW.bn.friends[i] or {}) end
-- WoW.bn.friendInfoNil: the API answers nil for a friend's game account, as
-- its declaration allows (Nilable) - a gap the elimination must not trust.
function C_BattleNet.GetFriendGameAccountInfo(i, j)
    local id = (WoW.bn.friends[i] or {})[j]
    if not id or WoW.bn.friendInfoNil then return nil end
    return C_BattleNet.GetGameAccountInfoByID(id) or { gameAccountID = id }
end
-- presenceID, battleTag, ... - available even while our presence is blank.
function BNGetInfo() return WoW.bn.me, WoW.bn.tag end

-- What ChatThrottleLib v32 calls besides the chat API, as the client has them.
-- The client's securecallfunction hands an error in fn to the error handler
-- and carries on; it does not unwind through the caller (a CTL callback
-- erroring must not abort - or, through QueueWire's pcall, duplicate - a send).
function securecallfunction(fn, ...)
    local r = { pcall(fn, ...) }
    if not r[1] then geterrorhandler()(r[2]); return end
    return unpack(r, 2, table.maxn(r))
end
-- WoW's xpcall passes its extra arguments to the function - Blizzard's own
-- code relies on it (FunctionUtil: xpcall(script, CallErrorHandler, frame, ...))
-- and so does ChatThrottleLib v32. Stock Lua 5.1 drops them, and the send it
-- wraps then ran with no arguments at all.
do
    local rawXpcall = xpcall
    function xpcall(fn, handler, ...)
        local n, args = select("#", ...), { ... }
        return rawXpcall(function() return fn(unpack(args, 1, n)) end, handler)
    end
end
-- The global form survives only as a deprecated alias (Blizzard_DeprecatedChatInfo).
SendChatMessage = function(...) return C_ChatInfo.SendChatMessage(...) end
-- The client's handler REPORTS and returns; it does not raise. Raising from a
-- handler turns a real error into "error in error handling" under xpcall and
-- loses it. Reports land in WoW.reportedErrors.
WoW.reportedErrors = {}
function geterrorhandler()
    return function(e) table.insert(WoW.reportedErrors, e) end
end
-- The client's table.wipe (and the wipe alias). CTL v32 binds it at load and
-- calls it when it reuses a pipe.
function table.wipe(t) for k in pairs(t) do t[k] = nil end return t end
wipe = table.wipe
function GetFramerate() return 60 end

------------------------------------------------------------
-- Plain globals that survived
------------------------------------------------------------

-- Identity, in the measured Forever shape: the surname is part of the name
-- string and SPACE-separated, and UnitName's second return is the realm only
-- for a cross-realm unit. GetPlayerInfoByGUID deliberately returns the FIRST
-- NAME ONLY at position 6, because the live client does and the two sources
-- disagreeing is a real trap.
WoW.player = { name = "Example Surname", realm = "Classic Beta PvE",
               normalizedRealm = "ClassicBetaPvE", guid = "Player-1234-0000AAAA",
               class = "PRIEST", classLocalized = "Priest", race = "Scourge" }

-- SURNAMES ARE SPLIT ACROSS TWO RETURNS on 1.60.1.70009: "Example Surname"
-- arrives as ("Example", "Surname"), where through 69977 it was one string.
-- WoW.player.name stays the whole name - that is what a test means by "the
-- character's name" - and the split happens here, so code that reads only the
-- first return loses the surname in tests exactly as it does in game.
-- Measured: UnitName, UnitNameUnmodified and UnitFullName all behave this way,
-- while GetUnitName and UnitPVPName return the joined string.
local function SplitPlayerName()
    local first, surname = WoW.player.name:match("^(%S+)%s+(.+)$")
    if not first then return WoW.player.name end
    return first, surname
end
function UnitName(unit) if unit == "player" then return SplitPlayerName() end end
function UnitFullName(unit) if unit == "player" then return SplitPlayerName() end end
function UnitNameUnmodified(unit) return UnitName(unit) end
function GetUnitName(unit) if unit == "player" then return WoW.player.name end end
function UnitPVPName(unit) if unit == "player" then return WoW.player.name end end
function UnitGUID(unit) if unit == "player" then return WoW.player.guid end end
function UnitNameFromGUID() return WoW.player.name end
function GetPlayerInfoByGUID()
    local first = WoW.player.name:match("^(%S+)")
    return WoW.player.classLocalized, WoW.player.class, "Undead", WoW.player.race, 1, first, ""
end
function GetRealmName() return WoW.player.realm end
function GetNormalizedRealmName() return WoW.player.normalizedRealm end
function UnitClass(unit) if unit == "player" then return WoW.player.classLocalized, WoW.player.class end end
function UnitRace(unit) if unit == "player" then return "Undead", WoW.player.race end end
function UnitSex() return 3 end

-- Mainline FrameXML's text compare (Blizzard_SharedXML/SortUtil.lua, build
-- 70170; SortUtil is in the 70205 API dump). THREE-WAY, as the client's is:
-- Sign(strcmputf8i(a, b)), so -1, 0 or 1 - never a boolean. A stub that
-- returned `a < b` would let a comparator that returns its result directly
-- (0 and -1 are both true in Lua) pass here and misorder in game.
function strcmputf8i(a, b)
    a, b = a:lower(), b:lower()
    if a < b then return -1 elseif a > b then return 1 end
    return 0
end
SortUtil = {
    CompareUtf8i = function(a, b)
        local d = strcmputf8i(a, b)
        return (d > 0 and 1) or (d < 0 and -1) or 0
    end,
}
-- Tag first, localized name second. Driven by WoW.faction so a test can put a
-- Skyborne on either side - the case a race-to-faction table gets wrong.
function UnitFactionGroup() return WoW.faction or "Horde", WoW.faction or "Horde" end
function IsLoggedIn() return WoW.loggedIn ~= false end
function GetMoney() return 0 end
function IsInGuild() return false end

SlashCmdList = {}
UISpecialFrames = {}
-- Message filters, recorded so a test can ask whether a line would be shown:
-- WoW.chatFiltered(event, text) runs them like the chat frame does (a true
-- return hides the line). Forever has ChatFrameUtil.AddMessageEventFilter,
-- with the old global kept as a deprecated alias (UI source, 70009).
WoW.chatFilters = {}
ChatFrameUtil = {
    AddMessageEventFilter = function(event, fn)
        WoW.chatFilters[event] = WoW.chatFilters[event] or {}
        table.insert(WoW.chatFilters[event], fn)
    end,
}
ChatFrame_AddMessageEventFilter = ChatFrameUtil.AddMessageEventFilter
function WoW.chatFiltered(event, text)
    for _, fn in ipairs(WoW.chatFilters[event] or {}) do
        if fn(nil, event, text) then return true end
    end
    return false
end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
-- Like the bundled ChatThrottleLib (v32) in the two ways that matter here: an
-- unknown priority or an over-255-byte message RAISES, which is what
-- QueueWire's raw fallback exists for - a stub that accepted anything left that
-- fallback untested. The priority is recorded on the captured send, so a paced
-- send is distinguishable from a raw one, and it is cleared even if the inner
-- send fails so it can never leak onto the next raw send.
local CTL_PRIORITIES = { BULK = true, NORMAL = true, ALERT = true }
ChatThrottleLib = {
    -- v32's version field: a bundled copy that loads later (LibAccountSync
    -- carries one) compares it and steps aside for an equal or newer one, as
    -- in game - without it, that copy's load errors on a nil compare.
    version = 32,
    -- callbackFn runs after the send, as CTL v32's does (when the message
    -- leaves), with (arg, didSend, sendResult).
    --
    -- WoW.ctlDefer = true holds every send in WoW.ctlQueue until
    -- WoW.ctlDrain() - as the real library does under its bandwidth budget or
    -- its start-up throttle, when even an ALERT waits. Otherwise it sends at
    -- once and calls back at once.
    SendAddonMessage = function(self, prio, prefix, text, channel, target, q, callbackFn, callbackArg)
        return self._send(self, "SendAddonMessage", function()
            return C_ChatInfo.SendAddonMessage(prefix, text, channel, target)
        end, prio, prefix, text, channel, target, q, callbackFn, callbackArg)
    end,
    -- v32's BNSendGameData: same pacing, same 255-byte cap, same callback; the
    -- "target" is the game account id and the chat type must be WHISPER.
    BNSendGameData = function(self, prio, prefix, text, chattype, gameAccountID, q, callbackFn, callbackArg)
        -- v32's own preconditions: a game account id, and chat type WHISPER.
        if not gameAccountID or chattype ~= "WHISPER" then
            error('Usage: ChatThrottleLib:BNSendGameData("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype", gameAccountID)', 2)
        end
        return self._send(self, "BNSendGameData", function()
            return C_BattleNet.SendGameData(gameAccountID, prefix, text)
        end, prio, prefix, text, chattype, gameAccountID, q, callbackFn, callbackArg)
    end,
    _send = function(self, method, sendFn, prio, prefix, text, channel, target, q, callbackFn, callbackArg)
        if WoW.ctlDefer or (q and WoW.ctlHeld[q]) then
            table.insert(WoW.ctlQueue, function()
                WoW.ctlDefer = false
                local ok, err = pcall(self[method], self, prio, prefix, text, channel,
                                      target, q, callbackFn, callbackArg)
                WoW.ctlDefer = true
                if not ok then error(err, 0) end
            end)
            return
        end
        if not CTL_PRIORITIES[prio] then
            error("ChatThrottleLib:SendAddonMessage(): unknown priority " .. tostring(prio), 2)
        end
        if #tostring(text) > 255 then
            error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
        end
        -- As v32: the send's result decides. AddonMessageThrottle is retried
        -- (held in WoW.ctlQueue until WoW.ctlDrain(), as v32 holds a blocked
        -- queue); an error inside the send is reported and becomes
        -- GeneralError, never raised; the callback gets (arg, didSend, result).
        local function attempt()
            WoW.pendingPrio, WoW.pendingQueue = prio, q
            local ok, r = pcall(sendFn)
            WoW.pendingPrio, WoW.pendingQueue = nil, nil
            if not ok then geterrorhandler()(r); r = 9 end
            if r == true or r == nil then r = 0 end
            if r == 3 then
                if q then WoW.ctlHeld[q] = true end
                table.insert(WoW.ctlQueue, attempt)
                return
            end
            if callbackFn then securecallfunction(callbackFn, callbackArg, r == 0, r) end
        end
        attempt()
    end,
}
function GetGuildInfo() return nil end

-- Frames registered for an event come back as VARARGS (frame1, frame2, ...),
-- never as a table. A stub that returned a table would let the exact bug this
-- models ship again: one return value binds the first FRAME, which is itself a
-- table, so a type() check passes and the list reads as empty.
function GetFramesRegisteredForEvent(event)
    return unpack(WoW.eventFrames[event] or {})
end

function UnitDefenseSkill() return WoW.defense[1], WoW.defense[2] end
-- Four returns, in this order. Config.lua reads the build from the second.
-- The third return is the CLIENT's build date, as the dump records it
-- ("client built Sep 23 2026"), not the day it was measured here. Verbatim,
-- including C's __DATE__ padding: a single-digit day is space-padded
-- ("Oct  5 2026", two spaces), as the dump header shows it.
function GetBuildInfo() return "1.60.1", "70938", "Nov 12 2026", 16001 end
-- GetLocale() -> localeName (forever-api-1.60.1.70205.md). WoW.locale to test another.
function GetLocale() return WoW.locale or "enUS" end
-- Client string alias (in the dump's _G walk); LibStub's version check uses it.
strmatch = string.match

-- Measured: nil when the character is not rested (docs/forever-api-notes.md).
function GetXPExhaustion() return WoW.restXP end
-- UnitXPMax at the level cap is unmeasured on Forever; Retail returns 0 there,
-- which is why callers must not divide by it unguarded. Tests set WoW.xpMax = 0.
function UnitXPMax() return WoW.xpMax end
function UnitXP() return WoW.xp end
function IsResting() return WoW.resting end

-- nil for a path the client doesn't have. WoW.textures: set of known paths;
-- nil (the default) means every path resolves.
function GetFileIDFromPath(path)
    if WoW.textures == nil then return 1 end
    return WoW.textures[path] and 1 or nil
end

function GetMaxPlayerLevel() return WoW.maxLevel end
function UnitLevel() return WoW.level end
function GetTime() return 0 end
-- A fixed clock, never the wall clock. Sync watermarks, the merge's 60-second
-- window and the stall deadlines are all time comparisons: a clock stuck at 0
-- made them untestable, and the wall clock made the suite depend on the date it
-- ran - sections on real time and sections pinned to 1000 stamped and read the
-- same state with different clocks, and one assertion quietly stopped testing
-- anything because every seeded expiry had become "the past". Tests pin their
-- own WoW.now where a value matters.
function time() return WoW.now end
-- GetServerTime() -> time:number (forever-api-1.60.1.70245.md). The same
-- clock: LibAccountSync stamps keys and stream ids with it.
function GetServerTime() return WoW.now end
-- debugprofilestop() -> elapsedMilliseconds:number (the 70245 dump): a
-- high-resolution clock LibAccountSync mixes into its entropy.
function debugprofilestop() return os.clock() * 1000 end
-- fastrandom(low, high) (in the 70245 dump's _G walk): the client's own RNG,
-- the other half of that entropy.
function fastrandom(a, b) return math.random(a, b) end
-- GetCurrentRegion() -> region:number (70245 dump). 90 on the Forever beta, as
-- the Battle.net stub's regionID (measured, see SelfBNet).
function GetCurrentRegion() return 90 end

-- WoW exposes `date` as a global (Lua 5.1 only has os.date), and anything
-- formatting a reset time calls it. Pinned to UTC so a test asserting a weekday
-- does not depend on the machine's timezone.
function date(fmt, t) return os.date("!" .. (fmt or "%c"), t or WoW.now) end

-- The payload of every captured SendAddonMessage, in send order.
function WoW.sentMessages()
    local msgs = {}
    for _, m in ipairs(WoW.sent) do msgs[#msgs + 1] = m.text end
    return msgs
end

-- WoW's strsplit takes a SET of delimiter characters and returns the fields
-- between them, preserving genuinely empty fields (adjacent or trailing
-- delimiters) but inventing none.
--
-- The obvious `gmatch("[^sep]*")` implementation is wrong: the `*` matches an
-- empty string at each delimiter AND again at end-of-string, so every field
-- after the first is shifted. Measured with that version:
--
--   strsplit("-", "Name Surname-Realm")   -> "Name Surname", "", "Realm", ""
--   strsplit("|", "CHUNK5|sid|1/3|body")  -> 8 fields instead of 4
--
-- That would have quietly corrupted both the realm-stripping in PeerShort and
-- every wire-format assertion in the eventual test_comm port.
-- `sep` is a LITERAL set of characters, not a Lua pattern, so every
-- non-alphanumeric is escaped before it goes into a character class.
-- Interpolating it raw breaks on the class metacharacters: `sep = "^"` builds
-- "[^]", which throws "malformed pattern (missing ']')" rather than splitting.
-- `]`, `%` and `-` are the same hazard. Escaping keeps the search in C, which
-- matters once test_comm starts splitting multi-KB serialized records.
-- `limit` caps the number of pieces, and the last one keeps the rest of the
-- string untouched, delimiters included - the client's strsplit(delim, str,
-- pieces). This stub used to ignore it. Core.lua reads every wire message as
-- strsplit("|", message, 2) and then parses the rest, and the rest has more "|"
-- in its HEADER: "CHUNK5|<sid>|<seq>/<total>|<body>", "DONE8|<sid>|<checksum>".
-- Without the limit the payload was only the next field, so every CHUNK and
-- DONE failed to parse and the receive path was untestable. (A chunk body can
-- contain "|" too, but that is not what broke: an all-printable body fails the
-- same way - so a "|"-free body encoding would NOT make the limit unnecessary.)
--
-- A nil string is an error, as it is for the client's C string functions,
-- rather than quietly becoming the text "nil" and letting a nil message fall
-- through as an unknown command.
function strsplit(sep, str, limit)
    if str == nil then
        error("bad argument #2 to 'strsplit' (string expected, got nil)", 2)
    end
    str = tostring(str)
    local escaped = tostring(sep):gsub("(%W)", "%%%1")
    local pattern = "[" .. escaped .. "]"
    local out, start = {}, 1
    while true do
        if limit and #out == limit - 1 then break end
        local s, e = str:find(pattern, start)
        if not s then break end
        out[#out + 1] = str:sub(start, s - 1)
        start = e + 1
    end
    out[#out + 1] = str:sub(start)
    return unpack(out)
end

------------------------------------------------------------
-- Professions (#14), shaped by what 1.60.1.70124 measured (forever-api-notes.md,
-- Professions):
--   * GetProfessions() returns spellbook indices; GetProfessionInfo(i) carries
--     the base skill line in position 7.
--   * C_TradeSkillUI answers for the LAST profession shown - also after its
--     window closed. Only WoW.tradeSkill.line decides what comes back, never
--     whether a window is open: a plugin that reads after CLOSE must be caught.
--   * GetAllRecipeIDs() lists learned and unlearned recipes.
--   * GetProfessionInfoByRecipeID() names the CHILD line (2937 for Alchemy),
--     with the base line in parentProfessionID.
--   * GetAllProfessionTradeSkillLines() is every line, owned or not.
------------------------------------------------------------

local function ProfessionsReset()
    WoW.professions = {}   -- { { name, rank, max, line }, ... } in spellbook order
    WoW.tradeSkill = {
        line = nil,        -- the source the client currently answers for (sticky)
        rank = 0, max = 0,
        recipes = {},      -- [id] = { name = , learned = , cooldown = seconds or nil }
        ready = true, changing = false, linked = false, guild = false, npc = false,
        nilInfo = {},      -- [id] = true: GetRecipeInfo returns nil for it
    }
    WoW.spellNames = {}
    WoW.unknownSpells = {}   -- [id] = true: GetSpellName returns nil, as for an ID the client lacks
    WoW.spellRequests = {}   -- RequestLoadSpellData calls, in order
    WoW.recipeLines = nil
end
ProfessionsReset()
local resetBeforeProfessions = WoW.reset
function WoW.reset()
    resetBeforeProfessions()
    ProfessionsReset()
end

-- Seven returns, as measured ("nil x 7"): a reader that stops at five would
-- miss whatever sits in the last two.
function GetProfessions()
    local idx = {}
    for i = 1, 7 do idx[i] = WoW.professions[i] and (i + 4) or nil end
    return idx[1], idx[2], idx[3], idx[4], idx[5], idx[6], idx[7]
end

function GetProfessionInfo(index)
    local p = WoW.professions[(index or 0) - 4]
    if not p then return nil end
    return p.name, 0, p.rank, p.max, 0, 0, p.line, 0, 0, 0, p.name
end

local CHILD_LINE = { [171] = 2937, [164] = 2938, [333] = 2940, [202] = 2941, [182] = 2944,
                     [165] = 2945, [186] = 2946, [393] = 2947, [197] = 2948 }

C_TradeSkillUI = {
    GetAllProfessionTradeSkillLines = function()
        return { 164, 165, 171, 182, 186, 197, 202, 333, 393, 2933, 2934, 2937, 2938, 2940, 2941,
                 2944, 2945, 2946, 2947, 2948 }
    end,
    GetBaseProfessionInfo = function()
        local ts = WoW.tradeSkill
        if not ts.line then
            return { professionID = 0, professionName = "", skillLevel = 0, maxSkillLevel = 0,
                     isPrimaryProfession = false, skillModifier = 0, sourceCounter = 0 }
        end
        return { professionID = ts.line, professionName = "Line " .. ts.line, skillLevel = ts.rank,
                 maxSkillLevel = ts.max, isPrimaryProfession = true, skillModifier = 0, sourceCounter = 1 }
    end,
    GetAllRecipeIDs = function()
        local ids = {}
        if WoW.tradeSkill.line then
            for id in pairs(WoW.tradeSkill.recipes) do ids[#ids + 1] = id end
            table.sort(ids)
        end
        return ids
    end,
    GetRecipeInfo = function(id)
        local r = WoW.tradeSkill.recipes[id]
        if not r or WoW.tradeSkill.nilInfo[id] then return nil end
        return { recipeID = id, name = r.name, learned = r.learned and true or false,
                 icon = 134400, categoryID = 1, relativeDifficulty = 0 }
    end,
    -- A ready cooldown is nil, not 0 (Retail's contract; not yet measured on
    -- Forever): code that only handles 0 must fail here.
    GetRecipeCooldown = function(id)
        local r = WoW.tradeSkill.recipes[id]
        if r and r.cooldown and r.cooldown > 0 then return r.cooldown, false, 0, 0 end
        return nil
    end,
    GetProfessionInfoByRecipeID = function(id)
        local line = WoW.recipeLines and WoW.recipeLines[id]
        if not line then return { professionID = 0, parentProfessionID = 0, professionName = "" } end
        return { professionID = CHILD_LINE[line] or line, parentProfessionID = line,
                 professionName = "Line " .. line }
    end,
    IsTradeSkillReady    = function() return WoW.tradeSkill.ready end,
    IsDataSourceChanging = function() return WoW.tradeSkill.changing end,
    IsTradeSkillLinked   = function() return WoW.tradeSkill.linked end,
    IsTradeSkillGuild    = function() return WoW.tradeSkill.guild end,
    IsNPCCrafting        = function() return WoW.tradeSkill.npc end,
}

C_Spell = {
    GetSpellName = function(id)
        if WoW.unknownSpells[id] then return nil end
        return WoW.spellNames[id] or ("Spell " .. tostring(id))
    end,
    GetSpellTexture = function() return 136235, 136235 end,
    RequestLoadSpellData = function(id) table.insert(WoW.spellRequests, id) end,
}

------------------------------------------------------------
-- Pets (#75), in the shape MEASURED on 1.60.1.70124 (Tools/AltStableProbe/Pets.lua)
------------------------------------------------------------
-- WoW.pet = { guid = "Pet-0-4615-1-86241-165189-02001E2A26", name = "Tarthosuk" }
--   A hunter pet's GUID carries the generic npc 165189 for every beast, and
--   its last six hex digits are the stable's petNumber. A demon's GUID is
--   "Pet-..." too, but carries its real npc (voidwalker 1860).
-- WoW.stable[slot] = the C_StableInfo PetInfo struct for an active slot.
-- WoW.currentSpells[spellID] = true: C_Spell.IsCurrentSpell (Call Pet N).
-- WoW.creatureDisplays[npc] = the display id SetCreature resolves to.
-- WoW.modelBoxes[display] = { minX, minY, minZ, maxX, maxY, maxZ }: the SIX
--   NUMBERS GetActiveBoundingBox returns here, not Retail's two vectors.
local function PetReset()
    WoW.pet = nil
    WoW.stable = {}
    WoW.currentSpells = {}
    WoW.creatureDisplays = {}
    WoW.modelBoxes = {}
    WoW.actors = {}
end
PetReset()
local resetBeforePets = WoW.reset
function WoW.reset()
    resetBeforePets()
    PetReset()
end

function UnitExists(unit)
    if unit == "pet" then return WoW.pet ~= nil end
    return unit == "player"
end
local unitGUIDBeforePets = UnitGUID
function UnitGUID(unit)
    if unit == "pet" then return WoW.pet and WoW.pet.guid end
    return unitGUIDBeforePets(unit)
end
local unitNameBeforePets = UnitName
function UnitName(unit)
    if unit == "pet" then return WoW.pet and WoW.pet.name end
    return unitNameBeforePets(unit)
end

C_StableInfo = {
    GetStablePetInfo = function(slot) return WoW.stable[slot] end,
}
C_Spell.IsCurrentSpell = function(id) return WoW.currentSpells[id] == true end

-- Model frames: a PlayerModel resolves a creature to its display id at once
-- (measured: GetDisplayInfo right after SetCreature read 1132 for 1860), and a
-- ModelScene hands out actors whose box is the six-number form.
-- As Methods, so the methods check sees them: PlayerModel and DressUpModel
-- (SetCreature, SetDisplayInfo, ClearModel, GetDisplayInfo), ModelScene
-- (SetPaused, CreateActor) and its ModelSceneActor.
function Methods.SetCreature(self, npc) self._display = WoW.creatureDisplays[npc] or 0; return self end
function Methods.SetDisplayInfo(self, id) self._display = id; return self end
function Methods.ClearModel(self) self._display = nil; return self end
function Methods.GetDisplayInfo(self) return self._display or 0 end
function Methods.SetPaused(self, paused, global) self._paused, self._globalPause = paused, global end
function Methods.CreateActor(self)
    local a = newWidget("ModelSceneActor", self)
    a._scale = 1
    self._actors = self._actors or {}
    self._actors[#self._actors + 1] = a
    WoW.actors[#WoW.actors + 1] = a
    return a
end
function Methods.SetModelByCreatureDisplayID(self, id) self._display = id; return true end
function Methods.GetActiveBoundingBox(self)
    local b = self._display and WoW.modelBoxes[self._display]
    if not b then return 0, 0, 0, 0, 0, 0 end
    return b[1], b[2], b[3], b[4], b[5], b[6]
end
function Methods.SetYaw(self, v) self._yaw = v; return self end
function Methods.GetYaw(self) return self._yaw end
function Methods.SetParticleOverrideScale(self, v) self._particles = v end
function Methods.SetAnimation(self, anim, variation, speed)
    self._anim, self._animSpeed = anim, (speed == nil) and 1 or speed
end

-- C_BarberShop: the choices exist only while the chair is open. Measured on
-- 1.60.1.70450 (owner's /dump away from a barber): GetAvailableCustomizations
-- returns NOTHING - "empty result", not an empty table. Set WoW.barber to a
-- categories table (CharCustomizationCategory, options with a Lua-index
-- currentChoiceIndex) to sit in the chair; nil gets up.
WoW.barber = nil
C_BarberShop = {
    GetAvailableCustomizations = function()
        if WoW.barber then return WoW.barber end
    end,
    -- A preview: moves the option's current choice, as the barber's own UI
    -- sees it on the next read.
    SetCustomizationChoice = function(optionID, choiceID)
        for _, cat in ipairs(WoW.barber or {}) do
            for _, opt in ipairs(cat.options or {}) do
                if opt.id == optionID then
                    for i, c in ipairs(opt.choices or {}) do
                        if c.id == choiceID then opt.currentChoiceIndex = i end
                    end
                end
            end
        end
    end,
    ApplyCustomizationChoices = function() return WoW.barber ~= nil end,
}

-- Strict globals, last: reading any global nobody defined is an error.
-- These may read as nil:
local allowNil = {}
-- AltStable's own globals and SavedVariables, before they are assigned: the
-- addon, its plugins and probe, the frames it looks up by name before making
-- them, and the Companion's manifest (a separate addon folder).
for _, n in ipairs({ "AltStable", "AltStableDB", "AltStableConfig", "AltStablePortraits", "AltStableAltsDB", "AltStableRosterDB" }) do allowNil[n] = true end
for _, n in ipairs({ "AltStableWarbandDB", "AltStableWarbandModel", "AltStableProfessionsDB", "AltStableCutoutManifest", "AltStableSheet", "AltStableBodyScrollScrollBar" }) do allowNil[n] = true end
for _, n in ipairs({ "AltStableCopyPrompt", "AltStableForgetPrompt", "AltStableSyncAskPrompt", "AltStableProbe", "AltStableProbeCharDB", "AltStableProbeMachineDB" }) do allowNil[n] = true end
-- Libraries, before their file creates them.
for _, n in ipairs({ "LibStub", "ChatThrottleLib" }) do allowNil[n] = true end
-- Absent on Forever (none is in the build's function list): the Classic APIs
-- Compat.lua and the tests look for, which must read nil, as on the client.
for _, n in ipairs({ "GetItemInfo", "GetItemInfoInstant", "GetItemIcon", "GetItemCount", "GetItemStats", "GetSkillLineInfo" }) do allowNil[n] = true end
for _, n in ipairs({ "GetNumSkillLines", "GetFactionInfo", "GetNumFactions", "GetContainerNumSlots", "GetContainerItemInfo", "GetContainerItemLink" }) do allowNil[n] = true end
for _, n in ipairs({ "SendAddonMessage", "RegisterAddonMessagePrefix", "IsAddOnLoaded", "LoadAddOn", "GetAddOnMetadata", "UnitDefense" }) do allowNil[n] = true end
for _, n in ipairs({ "UnitDisplayID", "UnitModel", "GetPlayerModelDisplayInfo" }) do allowNil[n] = true end
-- Stubbed above, and removed by a test to model a client without it.
for _, n in ipairs({ "C_TooltipInfo", "SetUIVisibility", "issecretvalue", "GetHitModifier", "GetCritChance", "GetFramesRegisteredForEvent" }) do allowNil[n] = true end
for _, n in ipairs({ "ENCHANTED_TOOLTIP_LINE" }) do allowNil[n] = true end
-- On the client, but never stubbed here: the suite has always run with these
-- reading nil, and the addon copes. Kept nil so the tests say what they said
-- before the kit (#284). Stubbing one changes what the tests exercise: each is
-- its own change.
for _, n in ipairs({ "GetAverageItemLevel", "GetChannelList", "GetCurrentKeyBoardFocus", "GetGuildRosterInfo", "GetNumGuildMembers", "GetInboxHeaderInfo" }) do allowNil[n] = true end
for _, n in ipairs({ "GetInboxNumItems", "GetMacroIcons", "GetMacroItemIcons", "GetMouseFoci", "GetNumSavedInstances", "GetSavedInstanceEncounterInfo" }) do allowNil[n] = true end
for _, n in ipairs({ "GetSavedInstanceInfo", "IsAltKeyDown", "IsMounted", "MoveViewLeftStart", "MoveViewLeftStop", "MoveViewRightStart" }) do allowNil[n] = true end
for _, n in ipairs({ "MoveViewRightStop", "RequestRaidInfo", "ShowingCloak", "ShowingHelm", "UnitAffectingCombat", "C_AutoComplete" }) do allowNil[n] = true end
for _, n in ipairs({ "C_FriendList", "C_Texture", "RAID_CLASS_COLORS", "CLASS_ICON_TCOORDS", "ITEM_QUALITY_COLORS", "GameFontNormal" }) do allowNil[n] = true end
for _, n in ipairs({ "GameFontHighlight", "GameFontHighlightSmall", "GameFontDisableSmall", "ChatAlertFrame", "QuickJoinToastButton", "BankFrame" }) do allowNil[n] = true end
for _, n in ipairs({ "Minimap", "CLOSE", "ERR_FRIEND_OFFLINE_S", "MAX_PLAYER_LEVEL", "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS" }) do allowNil[n] = true end
for _, n in ipairs({ "NUM_BANKGENERIC_SLOTS", "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE" }) do allowNil[n] = true end
-- Blizzard's bag frames (#305): test_goldtooltip builds them itself, and drops
-- one to pin that a client without it is handled.
for _, n in ipairs({ "ContainerFrame1", "ContainerFrameCombinedBags" }) do allowNil[n] = true end
-- The mail getters (#312): nil unless a test fills an inbox or a send draft,
-- like GetInboxNumItems and GetInboxHeaderInfo above.
for _, n in ipairs({ "GetInboxItem", "GetSendMailItem" }) do allowNil[n] = true end
Kit.strict(allowNil)

return WoW
