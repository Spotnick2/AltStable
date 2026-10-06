------------------------------------------------------------
-- AltStable/Prompt.lua — our own prompts, never a StaticPopup (#199)
--
-- Showing a StaticPopup from addon code taints Blizzard's shared dialog pool,
-- and so does reparenting, raising or hooking one. MEASURED on 1.60.1.70205
-- (LibShowcase r3): after our popup, the player's Quit failed with
-- ADDON_ACTION_FORBIDDEN ... ForceQuit(). So the copy box, the forget
-- confirmation and the sync question are frames of our own.
--
-- One frame per KIND, built on first use and reused: a sync question can sit
-- next to a copy box, and showing one never touches another's handlers.
--
-- Parented to nothing, so a hidden interface (the camera showcase, Alt+Z)
-- cannot hide them, and FULLSCREEN_DIALOG, above the sheet (DIALOG, toplevel).
--
-- Every way out ends in OnHide, which calls the caller's onClose exactly once:
-- with the button's index for a button, with nil for anything else (Escape,
-- Enter in the copy box, a caller hiding it). Answering lives there and only
-- there, so no route can skip it.
------------------------------------------------------------

AltStable = AltStable or {}

local WIDTH, PAD, BUTTON_H, GAP = 380, 16, 22, 8
local prompts = {}   -- kind -> frame
local order = {}     -- the kinds, in the order they were built

-- Escape, the CharacterMenu way (CharacterMenu.lua has the whole argument).
-- UISpecialFrames alone would close the sheet too: it is in that list, and
-- CloseSpecialWindows hides every shown one. So the prompt takes the keyboard
-- (out of combat only), answers Escape and hands every other key on, so the
-- player can still walk. The calls are pcalled: SetPropagateKeyboardInput is
-- marked restricted, and a failure must give the keyboard back, never keep it.
local function OnKeyDown(self, key)
    local stop = (key == "ESCAPE")
    local handed = true
    if type(self.SetPropagateKeyboardInput) == "function" then
        handed = pcall(self.SetPropagateKeyboardInput, self, not stop)
    end
    if not handed and type(self.EnableKeyboard) == "function" then
        pcall(self.EnableKeyboard, self, false)
    end
    if stop then self:Hide() end
end

local function ReleaseKeyboard(self)
    if type(self.EnableKeyboard) == "function" then pcall(self.EnableKeyboard, self, false) end
end

-- Out of combat only: in it, a restricted propagation call could leave the
-- movement keys swallowed with no way to hand them back.
local function TakeKeyboard(self)
    if InCombatLockdown and InCombatLockdown() then return end
    if type(self.EnableKeyboard) ~= "function" then return end
    pcall(self.EnableKeyboard, self, true)
    -- Propagation outlives the showing, and the last key was usually Escape,
    -- which turned it off: reset it, or the first key is eaten.
    if type(self.SetPropagateKeyboardInput) == "function" then
        pcall(self.SetPropagateKeyboardInput, self, true)
    end
end

-- Combat starting with a prompt up: it stays (a StaticPopup did too, and the
-- sync question closing here would have counted as asked), but the keyboard
-- goes back before the lockdown can make that impossible; Escape still works
-- through UISpecialFrames meanwhile. Combat ending with it still up: take the
-- keyboard back, or Escape goes on closing the sheet along with the prompt.
local function OnEvent(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        ReleaseKeyboard(self)
    elseif self:IsShown() then
        TakeKeyboard(self)
    end
end

local function OnHide(self)
    ReleaseKeyboard(self)
    -- A focused box keeps the keyboard after its frame is gone: every key
    -- would go on landing in it.
    if self.edit then self.edit:ClearFocus() end
    local choice, onClose = self._choice, self._onClose
    self._choice, self._onClose = nil, nil
    if onClose then onClose(choice) end
end

local function Build(kind, count, withCopy)
    local f = CreateFrame("Frame", "AltStable" .. kind .. "Prompt", nil, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetWidth(WIDTH)
    f:EnableMouse(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(f, "small")) then
        if AltStable.ApplyBackdrop then AltStable.ApplyBackdrop(f, 0.05, 0.05, 0.05, 0.96) end
    end
    f:Hide()

    -- An explicit width, not two anchors: the height is measured right after
    -- SetText, before a frame built a moment ago has ever been laid out, and a
    -- width that comes only from anchors may not have resolved yet - the text
    -- would measure as one unwrapped line and run under the buttons.
    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOP", 0, -PAD)
    text:SetWidth(WIDTH - 2 * PAD)
    text:SetJustifyH("CENTER")
    if AltStable.SkinText then AltStable.SkinText(text) end
    f.text = text

    if withCopy then
        local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        box:SetSize(WIDTH - 2 * PAD - 8, 20)
        box:SetAutoFocus(false)
        -- 0 = no limit: a link cut short is a wrong link.
        box:SetMaxLetters(0)
        box:SetScript("OnEnterPressed", function() f:Hide() end)
        box:SetScript("OnEscapePressed", function() f:Hide() end)
        -- Typing over it must not leave a wrong text to copy. Once per change:
        -- should the box ever hand back other text than it was given (its
        -- escape character is |), resetting it would otherwise loop forever.
        box:SetScript("OnTextChanged", function(self)
            if self._restoring or not self._copy then return end
            if self:GetText() ~= self._copy then
                self._restoring = true
                self:SetText(self._copy)
                self:HighlightText()
                self._restoring = nil
            end
        end)
        f.edit = box
    end

    f.buttons = {}
    local w = math.min(110, (WIDTH - 2 * PAD - (count - 1) * GAP) / count)
    local x = -(count * w + (count - 1) * GAP) / 2
    for i = 1, count do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, BUTTON_H)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOM", x + (i - 1) * (w + GAP), 14)
        b:SetScript("OnClick", function() f._choice = i; f:Hide() end)
        f.buttons[i] = b
    end

    f:SetScript("OnKeyDown", OnKeyDown)
    f:SetScript("OnHide", OnHide)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", OnEvent)
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, f:GetName()) end

    prompts[kind] = f
    order[#order + 1] = kind
    return f
end

-- Show the prompt of this kind, replacing what it showed before (that showing
-- ends first, as a dismissal: its onClose gets nil).
--   opts.text     the message
--   opts.buttons  the labels, left to right; the count is fixed per kind
--   opts.copy     text to hand over, selected, in a read-only box
--   opts.onClose  function(choice): the button's index, or nil
function AltStable.ShowPrompt(kind, opts)
    local labels = opts.buttons or { CLOSE or "Close" }
    local f = prompts[kind] or Build(kind, #labels, opts.copy ~= nil)
    if f:IsShown() then f:Hide() end

    f.text:SetText(opts.text or "")
    for i, b in ipairs(f.buttons) do b:SetText(labels[i] or "") end
    local textH = tonumber(f.text:GetStringHeight()) or 40
    local boxH = f.edit and 30 or 0
    f:SetHeight(PAD + textH + boxH + 12 + BUTTON_H + 14)
    if f.edit then
        f.edit:ClearAllPoints()
        f.edit:SetPoint("TOP", f.text, "BOTTOM", 0, -10)
        f.edit._copy = opts.copy or ""
        f.edit._restoring = true
        f.edit:SetText(f.edit._copy)
        f.edit._restoring = nil
    end

    -- Below any other prompt already up, never on top of it: a copy box
    -- opening over a sync question would hide its three buttons.
    local y = -180
    for _, k in ipairs(order) do
        local o = prompts[k]
        if o ~= f and o:IsShown() then y = y - (tonumber(o:GetHeight()) or 0) - GAP end
    end
    f:ClearAllPoints()
    f:SetPoint("TOP", 0, y)

    f._choice, f._onClose = nil, opts.onClose
    f:Show()
    f:Raise()
    TakeKeyboard(f)
    if f.edit then
        f.edit:SetFocus()
        f.edit:HighlightText()
    end
    return f
end

-- Take it down; onClose runs with nil. Nothing to do if it is not up.
function AltStable.HidePrompt(kind)
    local f = prompts[kind]
    if f and f:IsShown() then f:Hide() end
end

AltStable._test = AltStable._test or {}
AltStable._test.Prompt = function(kind) return prompts[kind] end
