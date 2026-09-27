------------------------------------------------------------
-- CharacterMenu.lua — one right-click menu on a character (#69)
--
-- Four things want the right-click gesture and there is only one of it:
-- favourite (#66), hide (#21), unhide, and forget (#65). Stacking them on
-- modifiers - shift-right-click, alt-right-click - is how a UI becomes
-- unusable, so they share one menu, built once and used by BOTH the sheet row
-- and the Roster card. Two menus would drift.
--
-- Why this is a hand-rolled frame and not the client's menu API
-- -------------------------------------------------------------
-- MenuUtil is present on this client (32 functions) and is the modern route.
-- It is still not used here, on purpose:
--
--   * Present is not behaves. That assumption has been wrong repeatedly on this
--     port, and a menu is not something you can check from Lua the way you can
--     check a return value.
--   * The showcase hides the game UI outright while the sheet is open, and a
--     frame the menu API owns is parented under UIParent - no strata makes the
--     child of a hidden parent draw. The fix for that here is
--     AltStable.LiftAboveHiddenUI, which needs a handle to the frame. A menu
--     built by somebody else does not reliably hand one over.
--   * The addon already has its own dark theme. A Blizzard-styled menu popping
--     up over it would be the inconsistent choice, not the consistent one.
--
-- What that buys in exchange is the whole input lifecycle: dismissal, layering,
-- Escape, cursor scaling, and not leaking an invisible click-catcher over the
-- screen. Each of those is handled below and each is marked, because the cost
-- of this decision is exactly that list.
------------------------------------------------------------

local ENTRY_H, TITLE_H, PAD = 17, 19, 6
local MIN_W, MAX_W = 150, 280

------------------------------------------------------------
-- What is on the menu
------------------------------------------------------------

-- Frame-free, but NOT pure: it reads the config and who you are playing. That
-- is the point - it is the one place the four states turn into labels, so a
-- test can assert the menu a given character gets without building any UI.
function AltStable.CharacterMenuEntries(char)
    if type(char) ~= "table" or not char.guid then return {} end
    local guid = char.guid
    local out = {}

    out[#out + 1] = { id = "title", title = true,
                      text = AltStable.ClassColor(char.class) .. (char.name or "?") .. "|r" }

    if AltStable.IsCharacterFavourite and AltStable.IsCharacterFavourite(guid) then
        out[#out + 1] = { id = "unfavourite", text = "Remove favourite" }
    else
        out[#out + 1] = { id = "favourite", text = "Favourite" }
    end

    if AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) then
        out[#out + 1] = { id = "unhide", text = "Unhide" }
    else
        out[#out + 1] = { id = "hide", text = "Hide" }
    end

    -- Offered but disabled on the character you are playing, rather than
    -- quietly absent. ForgetCharacter refuses that case anyway - the record
    -- would be rewritten by the next scan seconds later - and a menu that is a
    -- different length depending on who you right-click reads as a glitch.
    if guid == (UnitGUID and UnitGUID("player")) then
        out[#out + 1] = { id = "forget", text = "Forget", disabled = true,
                          why = "You are playing this character." }
    else
        out[#out + 1] = { id = "forget", text = "Forget\226\128\166", danger = true }
    end

    return out
end

------------------------------------------------------------
-- Doing it
------------------------------------------------------------

-- Explicit setters, never a toggle.
--
-- The menu is built from state and then sits on screen; anything - a sync
-- landing, the other view, a slash command - can change that state underneath
-- it. A toggle would then do the opposite of what the entry the user is looking
-- at says. "Favourite" must always favourite.
function AltStable.CharacterMenuInvoke(id, char)
    if type(char) ~= "table" or not char.guid then return false end
    local guid = char.guid

    if id == "favourite" or id == "unfavourite" then
        if not AltStable.SetCharacterFavourite then return false end
        AltStable.SetCharacterFavourite(guid, id == "favourite")
        -- Favourites sort first, so the row moves: repaint.
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        return true
    end

    if id == "hide" then
        if not AltStable.HideCharacter then return false end
        AltStable.HideCharacter(guid)
        return true
    end

    if id == "unhide" then
        if not AltStable.ShowCharacter then return false end
        AltStable.ShowCharacter(guid)
        return true
    end

    if id == "forget" then
        if not AltStable.RequestForgetCharacter then return false end
        AltStable.RequestForgetCharacter(char)
        return true
    end

    return false
end

------------------------------------------------------------
-- The frame
------------------------------------------------------------

local root, panel, catcher, entries, subject

-- Cursor position is in PHYSICAL pixels; frame offsets are in the frame's own
-- scaled units. Dividing by the effective scale is not optional - skip it and
-- the menu appears at a multiple of the distance from the corner, which on a
-- scaled UI looks like it opened somewhere random.
local function PlaceAtCursor()
    local x, y = GetCursorPosition()
    local scale = panel:GetEffectiveScale()
    panel:ClearAllPoints()
    if not x or not y or not scale or scale == 0 then
        panel:SetPoint("CENTER", root, "CENTER", 0, 0)   -- no cursor: still reachable
        return
    end
    x, y = x / scale, y / scale

    -- Clamp so a right-click near an edge does not open the menu off-screen.
    -- root spans UIParent and shares the panel's scale, so its size is the
    -- screen in the same units the offsets are in.
    local sw, sh = root:GetWidth() or 0, root:GetHeight() or 0
    local pw, ph = panel:GetWidth() or 0, panel:GetHeight() or 0
    if sw > 0 then x = math.max(0, math.min(x, sw - pw)) end
    if sh > 0 then y = math.max(ph, math.min(y, sh)) end

    -- The panel hangs DOWN and RIGHT from the cursor, like every other menu.
    panel:SetPoint("TOPLEFT", root, "BOTTOMLEFT", x, y)
end

local function EntryButton(index)
    entries = entries or {}
    if entries[index] then return entries[index] end

    local b = CreateFrame("Button", nil, panel)
    -- Both buttons, because the menu was OPENED with a right-click and
    -- right-clicking the entry is the natural continuation of that gesture.
    -- The entry takes the mouse, so an unregistered right-click is not passed
    -- down to the catcher either: it does nothing at all, which reads as a
    -- dead menu rather than as a button that only likes left-clicks.
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetHeight(ENTRY_H)
    b:SetPoint("LEFT", panel, "LEFT", PAD, 0)
    b:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 0.10)
    b.bg:Hide()

    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.label:SetPoint("LEFT", b, "LEFT", 4, 0)
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)

    b:SetScript("OnEnter", function(self)
        if not self._disabled then self.bg:Show() end
        if self._why then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self._why, 1, 0.82, 0, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.bg:Hide()
        if self._why then GameTooltip:Hide() end
    end)
    b:SetScript("OnClick", function(self)
        if self._disabled then return end
        local id, char = self._id, subject
        -- Closed BEFORE the action runs. Forget raises a confirmation, and a
        -- menu still sitting on screen underneath it - with a full-screen
        -- catcher swallowing the first click at the dialog - is the same bug
        -- as an invisible confirmation, wearing the other hat.
        AltStable.CloseCharacterMenu()
        AltStable.CharacterMenuInvoke(id, char)
    end)

    entries[index] = b
    return b
end

local function Build()
    if root then return end

    -- One full-screen root holding TWO SIBLINGS: the catcher below, the panel
    -- above. Lifting the root out from under UIParent carries both, so the
    -- pair cannot come apart when the showcase is on.
    root = CreateFrame("Frame", "AltStableCharacterMenu", UIParent)
    root:SetAllPoints(UIParent)
    root:SetFrameStrata("FULLSCREEN_DIALOG")
    root:Hide()

    -- Outside clicks DISMISS ONLY. They are deliberately not passed through to
    -- whatever is underneath: closing a menu is an action in itself, and a
    -- stray click that both closed the menu and re-sorted the grid behind it
    -- would be indistinguishable from a bug.
    catcher = CreateFrame("Button", nil, root)
    catcher:SetAllPoints(root)
    catcher:EnableMouse(true)
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() AltStable.CloseCharacterMenu() end)

    panel = CreateFrame("Frame", nil, root)
    if AltStable.ApplyBackdrop then
        local c = AltStable.C.BG_HEADER
        AltStable.ApplyBackdrop(panel, c[1], c[2], c[3], 0.98)
    end
    panel:EnableMouse(true)      -- a click on the panel's padding must not fall
                                 -- through to the catcher and close the menu
    if panel.SetFrameLevel and catcher.GetFrameLevel then
        panel:SetFrameLevel((catcher:GetFrameLevel() or 0) + 10)
    end

    -- Escape.
    --
    -- UISpecialFrames is NOT enough here: the sheet is registered in it too and
    -- is earlier in the list, so one Escape would close the whole window and
    -- leave the menu behind. Handling the key on the menu and propagating
    -- everything else keeps movement keys working while it is open.
    -- SetPropagateKeyboardInput is a PROTECTED method: Mainline's API docs mark
    -- it restricted, and Forever's own DialogueUI guards it with
    -- InCombatLockdown. Whether this client actually throws is NOT measured
    -- here - the dump proves the method exists, not how it behaves in combat -
    -- so this is written to be correct either way rather than on a guess:
    --
    --   * pcall, so a restriction cannot take out the handler and with it the
    --     Escape that closes the menu. An error here would fire on EVERY
    --     keypress while the menu is open, in combat, which is the worst
    --     possible moment for a wall of Lua errors.
    --   * close on Escape regardless of whether the propagation call took. The
    --     degradation if it did not is that Escape also reaches the sheet and
    --     closes both, which is tolerable; a menu that will not close is not.
    root:SetScript("OnKeyDown", function(self, key)
        local stop = (key == "ESCAPE")
        if type(self.SetPropagateKeyboardInput) == "function" then
            pcall(self.SetPropagateKeyboardInput, self, not stop)
        end
        if stop then AltStable.CloseCharacterMenu() end
    end)
end

function AltStable.CloseCharacterMenu()
    if not root then return end
    subject = nil
    if type(root.EnableKeyboard) == "function" then root:EnableKeyboard(false) end
    -- Put the root back under UIParent. Leaving it reparented would strand a
    -- full-screen mouse-enabled frame outside the hierarchy that the showcase's
    -- restore path walks.
    if AltStable.LiftAboveHiddenUI then AltStable.LiftAboveHiddenUI(root, false) end
    root:Hide()
end

function AltStable.ShowCharacterMenu(char)
    if type(char) ~= "table" or not char.guid then return false end
    Build()

    local list = AltStable.CharacterMenuEntries(char)
    if #list == 0 then return false end
    subject = char

    local width, y = MIN_W, -PAD
    for i, e in ipairs(list) do
        local b = EntryButton(i)
        b._id, b._disabled, b._why = e.id, e.disabled and true or false, e.why
        b:SetHeight(e.title and TITLE_H or ENTRY_H)
        b:SetPoint("TOP", panel, "TOP", 0, y)
        b.label:SetText(e.text or "")

        if e.title then
            b:EnableMouse(false)
        elseif e.disabled then
            b:EnableMouse(true)                    -- still hoverable: the tooltip says why
            b.label:SetTextColor(0.42, 0.42, 0.42)
        elseif e.danger then
            b:EnableMouse(true)
            b.label:SetTextColor(1, 0.35, 0.35)
        else
            b:EnableMouse(true)
            local t = AltStable.C.TEXT_NORM
            b.label:SetTextColor(t[1], t[2], t[3])
        end

        b:Show()
        y = y - b:GetHeight()
        local lw = (b.label.GetStringWidth and b.label:GetStringWidth()) or 0
        if lw + PAD * 4 > width then width = lw + PAD * 4 end
    end
    -- Recycled buttons from a longer menu must not linger under the backdrop.
    for i = #list + 1, #(entries or {}) do entries[i]:Hide() end

    panel:SetSize(math.min(width, MAX_W), -y + PAD)

    -- Lift BEFORE placing: the lift changes the panel's effective scale, and
    -- the cursor maths divides by it.
    if AltStable.LiftAboveHiddenUI and AltStable.IsGameUIHidden then
        AltStable.LiftAboveHiddenUI(root, AltStable.IsGameUIHidden())
    end
    root:Show()
    PlaceAtCursor()
    -- The keyboard is taken OUT OF COMBAT ONLY.
    --
    -- Grabbing it means every key arrives here and has to be handed back one at
    -- a time through SetPropagateKeyboardInput. If that method is restricted in
    -- combat on this client - see the note on the handler; unmeasured - then
    -- grabbing the keyboard in combat would swallow the movement keys with no
    -- way to release them. Not grabbing it costs Escape, which the sheet's own
    -- registration still answers; grabbing it and failing costs walking.
    if type(root.EnableKeyboard) == "function"
        and not (InCombatLockdown and InCombatLockdown()) then
        root:EnableKeyboard(true)
    end
    return true
end

------------------------------------------------------------
-- Test seams
------------------------------------------------------------

AltStable._test = AltStable._test or {}

AltStable._test.MenuIsShown = function() return root ~= nil and root:IsShown() and true or false end

-- The labels actually WRITTEN on the buttons, not the generator's output: the
-- two can disagree, and the renderer is where they would.
AltStable._test.MenuLabels = function()
    local out = {}
    if not root or not root:IsShown() then return out end
    for _, b in ipairs(entries or {}) do
        if b:IsShown() then out[#out + 1] = b.label:GetText() end
    end
    return out
end

AltStable._test.MenuClick = function(id)
    for _, b in ipairs(entries or {}) do
        if b:IsShown() and b._id == id then
            local fn = b:GetScript("OnClick")
            if fn then fn(b) end
            return true
        end
    end
    return false
end

AltStable._test.MenuEscape = function()
    if not root then return false end
    local fn = root:GetScript("OnKeyDown")
    if not fn then return false end
    fn(root, "ESCAPE")
    return true
end

AltStable._test.MenuClickOutside = function()
    if not catcher then return false end
    local fn = catcher:GetScript("OnClick")
    if not fn then return false end
    fn(catcher)
    return true
end

-- One entry button by id, so a test can ask what the CLIENT would ask it:
-- which buttons does it listen for, where is it anchored.
AltStable._test.MenuEntry = function(id)
    for _, b in ipairs(entries or {}) do
        if b:IsShown() and b._id == id then return b end
    end
    return nil
end

AltStable._test.MenuRoot    = function() return root end
AltStable._test.MenuPanel   = function() return panel end
AltStable._test.MenuCatcher = function() return catcher end

-- The key handler's verdict on one key, without a frame to press it on: true
-- when the menu swallowed it, false when it let it through to the game. A menu
-- that eats W is a menu you cannot walk away from.
AltStable._test.MenuKey = function(key)
    if not root then return nil end
    local fn = root:GetScript("OnKeyDown")
    if not fn then return nil end
    fn(root, key)
    return root._propagate == false
end
