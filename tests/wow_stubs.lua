------------------------------------------------------------
-- wow_stubs.lua
--
-- A WoW: Forever (1.60.1) API surface, minimal but SHAPED CORRECTLY, so
-- AltStable's files load and run under stock Lua 5.1 with no game client.
--
-- Two rules this file exists to enforce:
--
--   1. The removed Classic globals are NOT defined here. GetItemInfo,
--      GetSkillLineInfo, GetFactionInfo, GetContainerItemInfo and friends are
--      absent on the real client, so code that reaches for one must fail in
--      tests too. Defining them "for convenience" would hide exactly the bug
--      this port is about.
--
--   2. Return SHAPES match what was measured in-game, not what Classic did.
--      Skills, reputation and containers return a STRUCT. Items return the
--      Classic tuple. A cache miss returns NOTHING - not nil.
--
-- Load this FIRST in every test file:  dofile("tests/wow_stubs.lua")
-- Drive it through the exported `WoW` table; reset with WoW.reset().
------------------------------------------------------------

local WoW = {
    items       = {},   -- [itemID] = { name=, quality=, ilvl=, ... }; absent = cache miss
    skillLines  = {},   -- array of skill structs
    factions    = {},   -- array of faction structs
    factionByID = {},   -- [factionID] = struct (may hold ids not in `factions`)
    containers  = {},   -- [bagID] = { name=, size=, [slot] = itemStruct }
    bankTabs    = {},   -- purchased CHARACTER bank tab ids
    accountTabs = {},   -- purchased ACCOUNT bank tab ids (should never be scanned)
    tooltipPostCalls = {},  -- [Enum.TooltipDataType.X] = { fn, ... }
    loaded      = {},
    loadCalls   = {},
    timers      = {},
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
}

function WoW.reset()
    WoW.items, WoW.skillLines, WoW.factions, WoW.factionByID = {}, {}, {}, {}
    WoW.containers, WoW.bankTabs, WoW.accountTabs = {}, {}, {}
    WoW.tooltipPostCalls = {}
    WoW.loaded, WoW.loadCalls, WoW.timers, WoW.sent = {}, {}, {}, {}
    -- Tickers are NOT cleared: they are registered once at load, like the
    -- client's, and a reset is a new test section rather than a new session.
    -- Clearing them here is what left Core's stale-buffer sweep unreachable
    -- after the first WoW.reset().
    WoW.inCombat, WoW.uiVisible, WoW.screenshots = false, true, 0
    WoW.equipped = {}
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
    -- defined at file scope like every other stub. An earlier version put the
    -- whole stat block in here at column 0, which meant UnitStat and its
    -- neighbours did not exist until something called WoW.reset() - and every
    -- reset after that silently redefined them, quietly undoing anything a
    -- test had substituted.
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
    WoW.player.name = "Example Surname"
    WoW.player.realm, WoW.player.normalizedRealm = "Classic Beta PvE", "ClassicBetaPvE"
    WoW.player.class, WoW.player.classLocalized, WoW.player.race = "PRIEST", "Priest", "Scourge"
end

------------------------------------------------------------
-- Frames / timers
------------------------------------------------------------

-- Events the live client REJECTS. Measured: RegisterEvent throws on these.
-- A stub that accepted every event would contradict our own notes and let a
-- dead handler ship.
local INVALID_EVENTS = {
    PLAYERBANKBAGSLOTS_CHANGED = true,
    TRADE_SKILL_UPDATE         = true,
}
WoW.INVALID_EVENTS = INVALID_EVENTS

local function makeFrame()
    local f = {}
    local function chain() return f end
    f.RegisterEvent = function(self, ev)
        if INVALID_EVENTS[ev] then
            error('Frame:RegisterEvent(): Attempt to register unknown event "' .. tostring(ev) .. '"', 2)
        end
        self["_ev_" .. tostring(ev)] = true
        return self
    end
    f.IsEventRegistered = function(self, ev) return self["_ev_" .. tostring(ev)] == true end
    f.SetScript = function(self, ev, fn) self["_script_" .. tostring(ev)] = fn; return self end
    f.GetScript = function(self, ev) return self["_script_" .. tostring(ev)] end
    -- Unlike the AltStable stubs, HookScript REJECTS unknown script types the
    -- way the live client does. OnTooltipSetItem throws there, and a stub that
    -- accepted everything is precisely why the old Warband tests could not
    -- catch that (issue #10).
    f.HookScript = function(self, ev, fn)
        if ev == "OnTooltipSetItem" or ev == "OnTooltipSetUnit" then
            error("bad argument #2 to 'HookScript' (Usage: self:HookScript(scriptTypeName, script))", 2)
        end
        -- CHAINED INTO THE SAME DISPATCH as SetScript, because a hook that is
        -- only recorded is a hook nothing can test. Storing it under its own
        -- key meant Show()/Hide() - which fire _script_ - never ran it, so an
        -- addon could stop hooking OnHide entirely with every suite green.
        local prev = self["_script_" .. tostring(ev)]
        self["_script_" .. tostring(ev)] = function(...)
            if prev then prev(...) end
            fn(...)
        end
        self["_hook_" .. tostring(ev)] = fn
        return self
    end
    -- The draw layer is REAL state. Which of two textures is on top is a
    -- correctness question - an underlay drawn above its overlay hides the
    -- thing it is backing up - and the chaining default swallowed it.
    -- The SUBLEVEL is real state too, and the CREATION ORDER is recorded,
    -- because between two textures the client resolves it in exactly that
    -- priority: layer, then sublevel, then which was created first. A stub that
    -- kept only the layer could not tell a border from a lid - the two are the
    -- same layer - so the bug where an edge drawn after its inset covers it
    -- completely was invisible to the suite. See T.TextureOrder.
    -- The full client signature: CreateTexture(name, drawLayer, templateName,
    -- subLevel). The TEMPLATE slot is third and easy to drop, and dropping it
    -- silently shifts the sublevel into it - every explicit sublevel in the
    -- addon read back as nil, so a draw-order assertion compared 0 against 0
    -- and passed whatever the code said.
    f.GetRegions       = function(self) return unpack(self._regions or {}) end
    f.GetNumRegions    = function(self) return #(self._regions or {}) end
    f.CreateTexture    = function(self, _, layer, _template, sublevel)
        local t = makeFrame()
        t._layer, t._sublevel = layer, sublevel
        -- A frame knows what it drew, the way the client's GetRegions does.
        -- Without this "how many backgrounds does this frame paint" is not a
        -- question a test can ask, and the answer - one, not two stacked - is
        -- the whole point of a translucent material.
        if type(self) == "table" then
            self._regions = self._regions or {}
            self._regions[#self._regions + 1] = t
            t._regionOwner = self
        end
        WoW.textureSeq = (WoW.textureSeq or 0) + 1
        t._created = WoW.textureSeq
        t.SetDrawLayer = function(self, v, sub)
            self._layer = v
            -- The client's SetDrawLayer takes the sublevel as an optional
            -- second argument and resets it to 0 when omitted, rather than
            -- leaving the previous one in place.
            self._sublevel = sub or 0
            return self
        end
        t.GetDrawLayer = function(self) return self._layer, self._sublevel end
        return t
    end
    -- A FontString is SHORTER than a layout stride, and the generic 20px default
    -- was not: it is taller than STAT_ROW_H (15), which inverts the relationship
    -- the Roster column is built on - a stride that must never be shorter than
    -- the text it steps over. With the default, compressing the rows silently
    -- GREW them and the compression tests passed without exercising compression.
    --
    -- And it is TEXT-DEPENDENT: an auto-sized FontString with no text has no
    -- height. A fixed 12 hid a real bug - code that measures a font string to
    -- reserve room for it reads 0 before the text is set, and the fixed stub
    -- made that lifecycle unreachable, so the reservation looked correct in the
    -- suite and overflowed in game on the first render.
    --
    -- An explicit SetHeight still wins, as it does on the client: that is a
    -- FontString told how tall to be rather than asked.
    --
    -- MODELLED, NOT MEASURED. The exact number does not matter; being smaller
    -- than a stride does, being zero when empty does, and no client renders a
    -- small font at 20px.
    -- Owned by the frame that creates it, and that ownership is the assertion:
    -- Glass.Mask deliberately puts the mask on the region being clipped while
    -- ANCHORING it to the shape to clip against, and getting those two the wrong
    -- way round rounds the panel into a floating capsule instead of trimming a
    -- corner.
    f.CreateMaskTexture = function(self, name, layer, template, sublevel)
        local m = self:CreateTexture(name, layer, template, sublevel)
        m._isMask = true
        m._maskOwner = self
        return m
    end
    f.CreateFontString = function(self)
        local fs = makeFrame()
        -- A font string IS a region, as on the client: GetRegions returns it
        -- with the textures. Left out, anything that walks a frame's regions
        -- - the Options page moving what sits below its lists (#151) - was
        -- tested on textures only, and every label it moves went unseen.
        if type(self) == "table" then
            self._regions = self._regions or {}
            self._regions[#self._regions + 1] = fs
            fs._regionOwner = self
            fs._isFontString = true
        end
        fs.GetHeight = function(self)
            if self._GetHeight then return self._GetHeight end
            local t = self._text
            return (t and t ~= "") and 12 or 0
        end
        return fs
    end
    -- Text is REMEMBERED, not swallowed: a footer or a label is a real
    -- assertion ("does it say 1 unknown"), and a no-op SetText makes every
    -- display bug invisible to the suite.
    -- A text shadow is REAL state and defaults to none, which is the whole
    -- assertion: over glass a shadow is what keeps a label legible when
    -- something bright passes behind it, and the chaining default returned the
    -- frame for GetShadowOffset - truthy, non-zero, indistinguishable from a
    -- shadow that was actually set.
    -- The backdrop, which was nowhere in here at all - so every ApplyBGOnly and
    -- every SetBackdropColor in the addon went to the chaining default and the
    -- FLAT path's painting could not be asserted. That matters more now that
    -- flat is the documented revert: "the revert restores what was there" is a
    -- claim, and until this existed nothing could check it.
    f.SetBackdrop = function(self, bd) self._backdrop = bd; return self end
    f.GetBackdrop = function(self) return self._backdrop end
    f.SetBackdropColor = function(self, r, g, b, a)
        self._backdropColor = { r, g, b, a }; return self
    end
    f.GetBackdropColor = function(self)
        local c = self._backdropColor
        if not c then return end
        return c[1], c[2], c[3], c[4]
    end
    f.SetBackdropBorderColor = function(self, r, g, b, a)
        self._backdropBorder = { r, g, b, a }; return self
    end

    -- Text colour, likewise real state. "Is this label readable" and "is this
    -- the selected one" are both colour questions, and both were unanswerable.
    f.SetTextColor = function(self, r, g, b, a)
        self._textColor = { r, g, b, a }; return self
    end
    f.GetTextColor = function(self)
        local c = self._textColor
        if not c then return 1, 1, 1, 1 end
        return c[1], c[2], c[3], c[4] or 1
    end

    -- A tooltip's OWNER and anchor point are real state. "Where does this
    -- tooltip open" is a question the addon answers differently per call site,
    -- and the chaining default answered it with the tooltip itself.
    f.SetOwner = function(self, owner, anchor)
        self._owner, self._ownerAnchor = owner, anchor
        return self
    end
    f.GetOwner = function(self) return self._owner end
    f.GetAnchorType = function(self) return self._ownerAnchor end

    f.SetShadowOffset = function(self, x, y) self._shadowX, self._shadowY = x, y; return self end
    f.GetShadowOffset = function(self) return self._shadowX or 0, self._shadowY or 0 end
    f.SetShadowColor  = function(self, r, g, b, a)
        self._shadowColor = { r, g, b, a }; return self
    end
    f.GetShadowColor  = function(self)
        local c = self._shadowColor
        if not c then return 0, 0, 0, 0 end
        return c[1], c[2], c[3], c[4]
    end
    f.SetText = function(self, text) self._text = text; return self end
    f.GetText = function(self) return self._text end
    -- Geometry getters return NUMBERS. The chaining default would hand back the
    -- frame itself, and layout code does arithmetic on these - so a stub that
    -- chains them turns every layout pass into "arithmetic on a table value".
    local NUMERIC = {
        GetWidth = 100, GetHeight = 20, GetStringWidth = 40, GetStringHeight = 10,
        GetNumLines = 0, GetValue = 0, GetVerticalScroll = 0, GetHorizontalScroll = 0,
        GetVerticalScrollRange = 0, GetHorizontalScrollRange = 0,
        GetLeft = 0, GetRight = 100, GetTop = 100, GetBottom = 0,
        GetScale = 1, GetEffectiveScale = 1, GetNumPoints = 0, GetAlpha = 1,
        GetFrameLevel = 1, GetID = 0,
    }
    for name, value in pairs(NUMERIC) do
        f[name] = function(self) return self["_" .. name] or value end
    end
    -- EFFECTIVE scale walks the parent chain, which is the whole difference
    -- between it and GetScale. Returning only the frame's own scale made the
    -- two identical, so UIParent's scale was always 1 here and code converting
    -- between the two coordinate spaces could be deleted without any test
    -- noticing - which is exactly what happened to the window's screen clamp.
    f.GetEffectiveScale = function(self)
        local s, p, guard = self._scale or 1, self._parent, 0
        while p and guard < 32 do
            s = s * (p._scale or 1)
            p, guard = p._parent, guard + 1
        end
        return s
    end
    -- Real state: "is the window kept on the display" is the question #99 is
    -- about, and the chaining default answered it with the frame itself.
    f.SetClampedToScreen = function(self, v) self._clamped = not not v; return self end
    f.IsClampedToScreen  = function(self) return self._clamped == true end
    -- Strata, parent, scale and shown-ness are REAL state, not chained no-ops.
    -- Code that lifts a frame out from under a hidden UIParent and puts it back
    -- is exactly what needs testing, and with the chaining default every such
    -- save/restore stored the FRAME ITSELF as "the saved strata" and restored
    -- nothing - a silent no-op that reads as correct.
    -- Textures: what was set, and whether the client knew it.
    --
    -- SetTexture takes a path OR a file id, and the two behave DIFFERENTLY.
    --
    -- MEASURED on 1.60.1.70009:
    --     /run local t=UIParent:CreateTexture() t:SetTexture(999999999)
    --          print(t:GetTexture(), t:GetTextureFileID())
    --     999999999   999999999
    --
    -- A file id is stored, not resolved. A nonsense one is echoed straight
    -- back, so NOTHING a texture can be asked will tell you whether the art
    -- exists - the only symptom is that it draws nothing. An earlier version of
    -- this stub returned nil for an unknown id, which made a validity check
    -- look testable when on the client it could never fire.
    --
    -- A PATH is believed to be different - the client resolving it to a file id
    -- and being able to fail - but that half is NOT MEASURED. See the caveat in
    -- docs/forever-api-notes.md. Modelled the optimistic way so the behaviour
    -- is expressible, and driven by WoW.textures, which is the one table that
    -- already decides whether a path exists (GetFileIDFromPath reads it too).
    f.SetTexture = function(self, v)
        if type(v) == "number" then
            self._texture, self._fileID = v, v     -- echoed, whatever it is
        elseif type(v) == "string" then
            -- The SAME table GetFileIDFromPath consults. Two notions of "a path
            -- this client has" disagree the moment a test configures one of
            -- them: with WoW.textures set, a missing path reported absent to
            -- GetFileIDFromPath and present to SetTexture, at once.
            local id = GetFileIDFromPath(v)
            self._texture = id and v or nil
            self._fileID  = id
        else
            self._texture, self._fileID = nil, nil
        end
        return self
    end
    -- A SOLID COLOUR is what most of this addon's textures are, and the colour
    -- is the assertion: a quality border's whole job is which colour it is.
    -- Swallowed by the chaining default, a palette could lose an entry and every
    -- test still pass.
    --
    -- Recorded in `_colorTexture` rather than answered by a getter, because the
    -- client has no GetColorTexture and GetVertexColor is a DIFFERENT thing - it
    -- returns the vertex tint, which SetColorTexture does not touch. Inventing
    -- a getter here would be a stub that models an API the client does not
    -- have, which is the failure mode wow_stubs exists to avoid.
    f.SetColorTexture = function(self, r, g, b, a)
        self._colorTexture = { r, g, b, a }
        self._texture = nil                     -- a colour replaces any art
        return self
    end
    -- The material's API (#97). All of it records REAL state, because the whole
    -- point of the glass layer stack is which region is masked by what and in
    -- what order, and a chaining no-op would make every one of those questions
    -- unanswerable - which is how this repo shipped three layout bugs already.
    f.SetTextureSliceMargins = function(self, l, t, r, b)
        self._slice = { l, t, r, b }; return self
    end
    f.GetTextureSliceMargins = function(self) return self._slice end
    f.SetTextureSliceMode = function(self, m) self._sliceMode = m; return self end
    f.GetTextureSliceMode = function(self) return self._sliceMode end
    f.SetHorizTile = function(self, v) self._hTile = not not v; return self end
    f.SetVertTile  = function(self, v) self._vTile = not not v; return self end
    f.SetBlendMode = function(self, m) self._blend = m; return self end
    f.GetBlendMode = function(self) return self._blend end
    f.SetGradient  = function(self, orient, minC, maxC)
        self._gradient = { orient = orient, min = minC, max = maxC }
        return self
    end
    -- A mask affects textures of the frame that OWNS it. `_maskOwner` is
    -- recorded because attaching a mask to the wrong frame is silent in game and
    -- was the single likeliest way to get the corner clipping wrong.
    f.AddMaskTexture = function(self, mask)
        self._masks = self._masks or {}
        self._masks[#self._masks + 1] = mask
        return self
    end
    f.GetNumMaskTextures = function(self) return self._masks and #self._masks or 0 end
    f.GetMaskTexture = function(self, i) return self._masks and self._masks[i] end
    f.GetTexture         = function(self) return self._texture end
    f.GetTextureFileID   = function(self) return self._fileID end
    f.GetTextureFilePath = function(self)
        return type(self._texture) == "string" and self._texture or nil
    end
    f.SetTexCoord = function(self, ...) self._texCoord = { ... }; return self end

    f.SetFrameStrata = function(self, v) self._strata = v; return self end
    f.GetFrameStrata = function(self) return self._strata or "MEDIUM" end
    -- Frame level is REAL state. "Which of two siblings takes the click" is a
    -- correctness question - a catcher drawn over the menu it is meant to sit
    -- behind eats every entry - and the chaining default made every level 1.
    f.SetFrameLevel = function(self, v) self._GetFrameLevel = v; return self end
    -- Raise MOVES THE LEVEL. The client puts the frame above the others in its
    -- strata; what matters to anything watching is that the level changed, and
    -- the chaining default changed nothing - so a test that raised a frame and
    -- checked what followed was asserting against a no-op.
    f.Raise = function(self)
        self._GetFrameLevel = (self._GetFrameLevel or 0) + 5
        return self
    end

    f.GetChildren = function(self) return unpack(self._children or {}) end

    -- SetParent MAINTAINS the child list. Appending only at creation left
    -- GetChildren disagreeing with GetParent exactly where this codebase
    -- reparents frames - the showcase lifts the sheet out from under UIParent,
    -- and the lifted frame would still have answered UIParent:GetChildren().
    -- A test walking children instead of parents would have asserted the
    -- opposite of the truth.
    f.SetParent = function(self, p)
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
    f.GetParent      = function(self) return self._parent end
    f.SetScale       = function(self, v) self._scale = v; return self end
    f.GetScale       = function(self) return self._scale or 1 end
    -- Show and Hide FIRE their scripts, because that is where cleanup lives.
    -- A frame's OnHide is how it lets go of things it raised, and with Hide as
    -- a bare flag flip none of that ran: the sheet could close while leaving a
    -- full-screen click-catcher over the game and the suite saw a tidy world.
    -- Only on an actual change, as the client does - re-hiding a hidden frame
    -- fires nothing.
    --
    -- AND ON THE DESCENDANTS, as the client does: hiding a parent fires OnHide
    -- on every child that was on screen - their own shown flag untouched - and
    -- showing it again fires their OnShow. That is how hiding UIParent reaches
    -- the sheet, and a stub that stopped at the frame itself hid every bug
    -- that lives on that path (#89: a capture that hid UIParent and a sheet
    -- that could not tell "my parent went" from "I was closed").
    local function cascade(frame, script)
        for _, c in ipairs(frame._children or {}) do
            if c._shown ~= false then
                local fn = c["_script_" .. script]
                if fn then fn(c) end
                cascade(c, script)
            end
        end
    end
    f.Show = function(self)
        local was = self._shown
        local wasVisible = self.IsVisible and self:IsVisible()
        self._shown = true
        if was ~= true and self._script_OnShow then self:_script_OnShow() end
        if not wasVisible and self:IsVisible() then cascade(self, "OnShow") end
        return self
    end
    f.Hide = function(self)
        local was = self._shown
        local wasVisible = self.IsVisible and self:IsVisible()
        self._shown = false
        if was ~= false and self._script_OnHide then self:_script_OnHide() end
        if wasVisible then cascade(self, "OnHide") end
        return self
    end
    f.IsShown        = function(self) return self._shown ~= false end
    -- SetShown is Show/Hide with the condition inline, and the client has it.
    -- Chaining meant SetShown(false) left the frame shown, so a renderer that
    -- hid a widget conditionally looked identical to one that never hid it -
    -- a mutation removing exactly that survived the suite.
    f.SetShown = function(self, v)
        if v then self:Show() else self:Hide() end
        return self
    end

    -- Enabled state is REAL. The active tab is meant to be the one you cannot
    -- press, and with SetEnabled swallowed by the chaining default that claim
    -- was asserted nowhere - worse, a client missing the method entirely would
    -- have thrown while the suite stayed green.
    --
    -- `nil` DISABLES, matching the client: these take a boolean, and a missing
    -- argument is a falsy one, not "leave it alone". An earlier version wrote
    -- `v ~= false`, which made SetEnabled(nil) and SetEnabled() enable the
    -- widget - so a caller passing a nil flag by mistake looked correct here
    -- and did the opposite in game. The DEFAULT, never having been called, is
    -- still enabled, which is what a fresh frame is.
    f.SetEnabled  = function(self, v) self._enabled = not not v; return self end
    f.Enable      = function(self) self._enabled = true; return self end
    f.Disable     = function(self) self._enabled = false; return self end
    f.IsEnabled   = function(self) return self._enabled ~= false end

    -- Word wrap is REAL state. A FontString with only a left anchor is as wide
    -- as its text, so whether it wraps decides whether a long line stays
    -- inside the frame or runs out over the game world - which it did. With
    -- SetWordWrap swallowed by the chaining default, and GetWordWrap returning
    -- the frame itself (truthy), an assertion about it could not fail. Same
    -- nil rule as SetEnabled above.
    f.SetWordWrap = function(self, v) self._wrap = not not v; return self end
    f.GetWordWrap = function(self) return self._wrap ~= false end
    -- Visible means shown AND every ancestor shown - the distinction the whole
    -- hidden-UIParent problem turns on.
    f.IsVisible      = function(self)
        if self._shown == false then return false end
        local p = self._parent
        while p do
            if p._shown == false then return false end
            p = p._parent
        end
        return true
    end
    -- Anchors are RECORDED. Placing a menu at the cursor is arithmetic - divide
    -- the cursor's physical pixels by the frame's effective scale, then clamp
    -- to the screen - and with SetPoint as a no-op none of that arithmetic was
    -- observable. A menu that opens at a multiple of the right distance from
    -- the corner looks like it opened somewhere random, and no test could see
    -- it.
    --
    -- SetPoint is variadic in the client; all three arities are normalised here
    -- so a caller does not have to know which one this stub prefers.
    f.SetPoint = function(self, point, a, b, c, d)
        local rel, relPoint, x, y
        if type(a) == "number" then
            x, y = a, b                       -- SetPoint(point, x, y)
        elseif type(b) == "number" then
            rel, x, y = a, b, c               -- SetPoint(point, rel, x, y)
        else
            rel, relPoint, x, y = a, b, c, d  -- SetPoint(point, rel, relPoint, x, y)
        end
        -- REPLACES the anchor for a point already set, which is what the
        -- client does. Appending instead meant a frame re-anchored on every
        -- open - which every pooled menu entry is - accumulated stale anchors,
        -- and GetPoint(1) handed back a position from several openings ago. A
        -- placement assertion could then pass, or fail, for the wrong reason,
        -- which defeats the point of recording anchors at all.
        self._points = self._points or {}
        for _, existing in ipairs(self._points) do
            if existing.point == point then
                existing.rel, existing.relPoint, existing.x, existing.y = rel, relPoint, x, y
                return self
            end
        end
        self._points[#self._points + 1] =
            { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
        return self
    end
    f.ClearAllPoints = function(self) self._points = nil; return self end
    -- REPLACES the anchors, as the client's does - it is not a fifth point.
    -- Recorded because "does this region cover its whole frame" is what tells
    -- a background apart from a box drawn inside one.
    f.SetAllPoints   = function(self, rel)
        self._points = nil
        self._allPoints = rel or true
        return self
    end
    f.GetNumPoints   = function(self) return self._points and #self._points or 0 end
    f.GetPoint = function(self, i)
        local pt = self._points and self._points[i or 1]
        if not pt then return nil end
        return pt.point, pt.rel, pt.relPoint, pt.x, pt.y
    end

    -- Alpha is REAL state. Dimming a hidden character's row IS the feature
    -- (#69), and rows come from a pool - so "was it set back to 1 for the next
    -- character" is the assertion, and the chaining default answered every
    -- alpha question with the constant 1.
    f.SetAlpha = function(self, a) self._GetAlpha = a; return self end
    f.GetAlpha = function(self) return self._GetAlpha or 1 end

    -- Which buttons a Button actually listens for.
    --
    -- Not bookkeeping: a Button fires OnClick for the LEFT button only until
    -- RegisterForClicks says otherwise. A right-click handler on a button that
    -- never registered right-clicks is dead code in game and perfect code to a
    -- test that calls the handler directly. Recording it is what lets a test
    -- ask the question the client asks.
    -- Attributes are STORED. The chaining default made GetAttribute hand back
    -- the frame itself - truthy, and nothing like the value - so a secure
    -- button with no action at all looked configured.
    f.SetAttribute = function(self, k, v)
        self._attributes = self._attributes or {}
        self._attributes[k] = v
        return self
    end
    f.GetAttribute = function(self, k) return self._attributes and self._attributes[k] end
    f.RegisterForClicks = function(self, ...)
        self._clicks = { ... }
        return self
    end
    f.RegisteredClicks = function(self) return self._clicks or {} end
    f.HandlesClick = function(self, button)
        for _, c in ipairs(self._clicks or {}) do
            if c == button .. "Up" or c == button .. "Down" or c == "AnyUp" or c == "AnyDown" then
                return true
            end
        end
        -- The client's default for a Button with no registration at all.
        return self._clicks == nil and button == "LeftButton" or false
    end

    -- DISABLED BY DEFAULT for a Frame, as on the client - a BUTTON is enabled
    -- when it is created, which is why the kind is passed in below. Defaulting
    -- everything to enabled meant "does this window eat the mouse" answered yes
    -- for a window that had never been asked to, and the world showing through
    -- it (#74) was not a question a test could put. Defaulting everything to
    -- disabled would have been the same mistake pointed the other way: a test
    -- asking whether a button takes the mouse would fail against correct code.
    --
    -- `v == true`, not `v ~= false`: the client reads EnableMouse(nil) as
    -- DISABLE, so `f:EnableMouse(cfg.something)` with a nil config value is off
    -- in game and would have been on here.
    f.EnableMouse    = function(self, v) self._mouse = v == true; return self end
    f.IsMouseEnabled = function(self) return self._mouse == true end
    f.EnableKeyboard = function(self, v) self._keyboard = v ~= false; return self end
    f.IsKeyboardEnabled = function(self) return self._keyboard == true end
    f.SetPropagateKeyboardInput = function(self, v) self._propagate = v; return self end

    f.SetWidth  = function(self, w) self._GetWidth = w; return self end
    f.SetHeight = function(self, h) self._GetHeight = h; return self end
    f.SetSize   = function(self, w, h) self._GetWidth, self._GetHeight = w, h; return self end
    -- Clipping is state, as on the client: the chaining default answered
    -- DoesClipChildren with the frame itself, which reads as "yes" to everything.
    f.SetClipsChildren = function(self, v) self._clipsChildren = v and true or false; return self end
    f.DoesClipChildren = function(self) return self._clipsChildren == true end

    -- Regions a TEMPLATE would have created (OptionsSliderTemplate gives a
    -- slider .Low/.High/.Text, a scroll frame gets .ScrollBar, and so on). The
    -- chaining default would hand back a function, and `slider.Low:SetText(...)`
    -- then fails on a function value - so these come back as frames.
    local TEMPLATE_CHILDREN = {
        Low = true, High = true, Text = true, ScrollBar = true, ScrollFrame = true,
        EditBox = true, Icon = true, Border = true, Left = true, Middle = true,
        Right = true, Center = true, Background = true, Label = true, Thumb = true,
    }

    -- Any unknown METHOD chains (widget methods are all capitalised). A plain
    -- field reads nil, as on a real frame - `row.dividers or {}` must see nil.
    setmetatable(f, { __index = function(self, k)
        if type(k) ~= "string" then return nil end
        if TEMPLATE_CHILDREN[k] then
            local child = makeFrame()
            self[k] = child        -- cached, so identity is stable across reads
            return child
        end
        if k:find("^%u") then return chain end
    end })
    return f
end
WoW.makeFrame = makeFrame

-- The PARENT argument is honoured, and a named frame becomes a global, because
-- the client does both.
--
-- This used to be `function CreateFrame() return makeFrame() end`, which threw
-- the parent away. Everything about lifting a frame out from under a hidden
-- UIParent then only worked because the code under test called SetParent by
-- hand: a frame that was merely CREATED as a child of UIParent looked like an
-- orphan, so "it is not parented to UIParent" was trivially true and the
-- assertion proved nothing.
function CreateFrame(kind, name, parent)
    local f = makeFrame()
    -- The KIND, which this threw away. A Button takes the mouse from the
    -- moment it exists; a Frame does not until something says so.
    f._mouse = (kind == "Button" or kind == "CheckButton")
    f._frameKind = kind
    f._parent = parent
    -- The parent keeps a CHILD LIST, because GetChildren() is how a test walks
    -- a panel it did not build - the buttons on a prompt, say - and asks what
    -- the player can actually press.
    if type(parent) == "table" then
        parent._children = parent._children or {}
        parent._children[#parent._children + 1] = f
    end
    if type(name) == "string" and name ~= "" then _G[name] = f end
    return f
end

-- The roots of the client's frame hierarchy. Absent until now, so every
-- CreateFrame(..., UIParent) passed nil and any code that lifts a frame OUT
-- from under UIParent - to survive the showcase hiding it - had nothing to be
-- compared against: "not parented to UIParent" was trivially true because
-- UIParent was nil.
-- A DISPLAY-SIZED UIParent.
--
-- It was a bare frame, so it inherited the generic 20px default - a screen
-- twenty pixels tall. Nothing noticed because nothing measured it, and that is
-- precisely why a window running off the bottom of the display could not be
-- caught here: every sane clamp against a 20px screen is indistinguishable from
-- a broken one.
--
-- MODELLED, NOT MEASURED. 1920x1080 is a plausible display rather than any
-- particular one; what matters is that it is bigger than the window and that
-- the ratio between the two is real.
UIParent = makeFrame()
-- 1365x768 at scale 1.4, which is ~1911x1075 physical: a 1080p display at the
-- client's default UI scale. The NUMBERS matter less than the fact that the
-- scale is not 1 - at 1, effective scale and own scale are the same thing and
-- any conversion between the two is untestable. It was 1920x1080 at scale 1,
-- and a mutation deleting the UIParent factor from the window clamp survived.
UIParent:SetSize(1365, 768)
UIParent:SetScale(1.4)
WorldFrame = makeFrame()

-- The cursor, in PHYSICAL pixels - which is the trap this models. Frame offsets
-- are in the frame's own scaled units, so code that places something at the
-- cursor has to divide by the effective scale. A stub that returned values
-- already in frame units would make the division look optional.
WoW.cursorX, WoW.cursorY = 800, 600
function GetCursorPosition() return WoW.cursorX, WoW.cursorY end


-- WoW's table helpers, which are globals there and absent in plain Lua 5.1.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
-- WoW hoists a few math/string functions to globals; code written against the
-- client uses them bare.
floor, ceil, abs, min, max = math.floor, math.ceil, math.abs, math.min, math.max
format, strsub, strlower, strupper = string.format, string.sub, string.lower, string.upper
function tinsert(...) return table.insert(...) end
function tremove(...) return table.remove(...) end
function tContains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
UISpecialFrames = UISpecialFrames or {}

------------------------------------------------------------
-- Secret values
--
-- Retail's "secret values", present on this client: a value an addon may hold
-- and pass along but must not inspect. Arithmetic, comparison, tostring and
-- concatenation all throw - which is what aborted a live character scan. The
-- stub models the THROWING, not just the flag, so code that reaches for the
-- number fails here the way it fails in game.
------------------------------------------------------------

-- A secret is NOT a table: code that filters on type(v) == "table" (the
-- serializer does, for nested data) would skip it and the guard that matters
-- would never run. Lua 5.1 cannot make userdata from script, so a coroutine
-- stands in: a distinct type whose arithmetic and comparisons throw by
-- themselves, exactly like the client's secret numbers.
--
-- Difference from the client, stated rather than papered over: tostring() on a
-- coroutine returns "thread: 0x..." instead of throwing. So a test can only
-- show that a secret is kept OFF the wire, not that carrying one would error.
local secrets = setmetatable({}, { __mode = "k" })

function WoW.secret(n)
    local v = coroutine.create(function() return n end)
    secrets[v] = n
    return v
end

function issecretvalue(v)
    return secrets[v] ~= nil
end

-- Pending timers land in WoW.timers as { delay = <seconds>, fn = <callback> }, so
-- a test can assert WHEN something was scheduled, not just that it ran. A
-- NewTimer handle that is cancelled drops out of the queue, the way the client
-- stops it firing - the old stub returned an inert handle and recorded nothing,
-- so a scheduled-for-later callback was invisible to every test.
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
    -- A REAL ticker: it queues like the others, fires on each flush, and stays
    -- queued until cancelled. The inert version returned a handle that never
    -- fired and a Cancel that did nothing, which made every countdown built on
    -- NewTicker untestable - the callback simply never ran, so a test could
    -- only assert that something had been scheduled.
    -- Tickers live in their own list, NOT in WoW.timers.
    --
    -- Core registers a 60-second sweep at load, so a repeating entry in
    -- WoW.timers would mean the count never reaches zero - and test_comm's
    -- flushAll short-circuits on exactly that, while test_instances asserts
    -- `#WoW.timers == 0`. A real ticker should not quietly change what a
    -- one-shot timer count means.
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

    -- Snapshot first: a ticker's callback may cancel itself or add another.
    local ticking = {}
    for _, e in ipairs(WoW.tickers) do ticking[#ticking + 1] = e end
    for _, e in ipairs(ticking) do
        if not e.cancelled then e.fn() end
    end
end

-- Combat, the interface toggle, and screenshots.
--
-- All three are real client calls the render probe makes, and none of them was
-- modelled - which is why that file went through three review rounds with no
-- test able to load it at all. Combat lockdown and Alt+Z are exactly the states
-- its bugs lived in.
WoW.inCombat = false
-- A colour OBJECT, which is what SetGradient takes on this client - not four
-- numbers. Absent entirely until the glass material needed it, so Glass.Apply
-- threw on load in the test harness while working fine in game.
function CreateColor(r, g, b, a)
    return { r = r, g = g, b = b, a = a,
             GetRGBA = function(self) return self.r, self.g, self.b, self.a end,
             GetRGB  = function(self) return self.r, self.g, self.b end }
end

function InCombatLockdown() return WoW.inCombat and true or false end

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
GameTooltip = makeFrame()
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
    dialog:Show()

    table.insert(WoW.popups, {
        which = which, arg1 = arg1, arg2 = arg2, data = data, dialog = dialog,
    })

    if type(def.OnShow) == "function" and dialog:IsVisible() then
        def.OnShow(dialog)
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
}

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
-- ("client built Sep 23 2026"), not the day it was measured here.
function GetBuildInfo() return "1.60.1", "70170", "Oct 1 2026", 16001 end

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
local createFrameBeforePets = CreateFrame
function CreateFrame(kind, name, parent, ...)
    local f = createFrameBeforePets(kind, name, parent, ...)
    if kind == "PlayerModel" or kind == "DressUpModel" then
        f.SetCreature = function(self, npc) self._display = WoW.creatureDisplays[npc] or 0; return self end
        f.SetDisplayInfo = function(self, id) self._display = id; return self end
        f.ClearModel = function(self) self._display = nil; return self end
        f.GetDisplayInfo = function(self) return self._display or 0 end
    elseif kind == "ModelScene" then
        f.SetPaused = function(self, paused, global) self._paused, self._globalPause = paused, global end
        f.CreateActor = function(self)
            local a = WoW.makeFrame()
            a._scale = 1
            a.SetModelByCreatureDisplayID = function(s, id) s._display = id; return true end
            a.ClearModel = function(s) s._display = nil end
            a.GetActiveBoundingBox = function(s)
                local b = s._display and WoW.modelBoxes[s._display]
                if not b then return 0, 0, 0, 0, 0, 0 end
                return b[1], b[2], b[3], b[4], b[5], b[6]
            end
            a.SetScale = function(s, v) s._scale = v; return s end
            a.GetScale = function(s) return s._scale end
            a.SetYaw = function(s, v) s._yaw = v; return s end
            a.SetParticleOverrideScale = function(s, v) s._particles = v end
            a.SetAnimation = function(s, anim, variation, speed)
                s._anim, s._animSpeed = anim, (speed == nil) and 1 or speed
            end
            a.GetYaw = function(s) return s._yaw end
            self._actors = self._actors or {}
            self._actors[#self._actors + 1] = a
            WoW.actors[#WoW.actors + 1] = a
            return a
        end
    end
    return f
end

_G.WoW = WoW
return WoW
