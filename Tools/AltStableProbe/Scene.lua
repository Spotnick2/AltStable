------------------------------------------------------------
-- Scene.lua — the ModelScene line of attack for #15
--
-- Models.lua established the wall: SetUnit("player") renders a fully
-- textured character, SetDisplayInfo(savedID) renders correct GEOMETRY with no
-- texture at all. Skin, face, hair and armour are one COMPOSITE texture built
-- from customization data that a display id does not carry. Weapons, being
-- separate models with their own textures, come out perfectly - which is what
-- localised the failure.
--
-- DressUpModel has no way to ask for that composite. A ModelScene ACTOR does
-- have two that DressUpModel lacks:
--
--   SetModelByCreatureDisplayID(id, useActivePlayerCustomizations)
--       - the flag composites the ACTIVE player's customizations onto a
--         non-unit model. Only ever "you", but it proves the composite can be
--         driven without a unit token.
--
--   SetPlayerModelFromGlues(characterIndex, ...)
--       - the CHARACTER SELECT screen's own renderer. That screen draws every
--         alt on the account with full customization, from cached data, with
--         nobody logged in. If it answers in-game, same-account alts can be
--         rendered as themselves - which is most of what an alt tracker wants.
--
-- Both are documented on this client. Documented is not working, so: measure.
------------------------------------------------------------

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[scene]|r " .. tostring(s))
end

local function Try(obj, method, ...)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return nil, "missing" end
    local ok, a = pcall(fn, obj, ...)
    if ok then return (a == nil) and true or a, "ok" end
    return nil, tostring(a)
end

local frame, actor, status, idx = nil, nil, nil, 1

local function Report(what, value, err)
    local line = what .. " -> " .. tostring(value) .. (err and err ~= "ok" and ("  [" .. err .. "]") or "")
    Out(line)
    if status then status:SetText(line) end
end

local function EnsureActor()
    if actor then return actor end
    if not frame then return nil end
    -- A ModelScene needs an actor to put anything in it. The template argument
    -- is required; the default one is what Blizzard's own scenes use.
    local a = Try(frame, "CreateActor", "AltStableProbeActor", "ModelSceneActorTemplate")
    if type(a) ~= "table" and type(a) ~= "userdata" then
        a = Try(frame, "GetActorAtIndex", 1)
    end
    actor = (type(a) == "table" or type(a) == "userdata") and a or nil
    if not actor then Out("|cffff5555could not create a ModelScene actor|r") end
    return actor
end

local function FromGlues(i)
    local a = EnsureActor()
    if not a then return end
    local ok, err = Try(a, "SetPlayerModelFromGlues", i, false, true, false, true)
    Report("SetPlayerModelFromGlues(" .. i .. ")", ok, err)
end

local function FromCreature(id, useMine)
    local a = EnsureActor()
    if not a then return end
    local ok, err = Try(a, "SetModelByCreatureDisplayID", id, useMine and true or false)
    Report("SetModelByCreatureDisplayID(" .. id .. ", customizations=" ..
           tostring(useMine and true or false) .. ")", ok, err)
end

local function FromUnit()
    local a = EnsureActor()
    if not a then return end
    local ok, err = Try(a, "SetModelByUnit", "player")
    Report("SetModelByUnit(player)", ok, err)
end

local function Build()
    if frame then return frame end

    local win = CreateFrame("Frame", "AltStableSceneProbe", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(380, 470); win:SetPoint("CENTER", 320, 0)
    win:SetMovable(true); win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.TitleText then win.TitleText:SetText("ModelScene probe (#15)") end
    table.insert(UISpecialFrames, "AltStableSceneProbe")

    local ok, scene = pcall(CreateFrame, "ModelScene", nil, win)
    if not ok or not scene then
        local msg = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetPoint("CENTER")
        msg:SetText("|cffff5555CreateFrame('ModelScene') failed|r\n" .. tostring(scene))
        Out("CreateFrame('ModelScene') failed: " .. tostring(scene))
        frame = win
        return win
    end
    scene:SetPoint("TOPLEFT", 14, -36)
    scene:SetPoint("BOTTOMRIGHT", -14, 96)
    frame = scene

    status = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", 14, 74)
    status:SetPoint("BOTTOMRIGHT", -14, 74)
    status:SetJustifyH("LEFT"); status:SetWordWrap(true)
    status:SetTextColor(0.6, 0.6, 0.6)
    status:SetText("Glues 1..N walks the CHARACTER SELECT list.")

    local buttons = {
        { "Glues <", function() idx = math.max(1, idx - 1); FromGlues(idx) end },
        { "Glues >", function() idx = idx + 1; FromGlues(idx) end },
        { "Unit",    function() FromUnit() end },
        { "Creature+me", function() FromCreature(tonumber(AltStableProbeDB and AltStableProbeDB.manualID) or 49, true) end },
    }
    for i, spec in ipairs(buttons) do
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(84, 22)
        b:SetPoint("BOTTOMLEFT", 12 + ((i - 1) % 4) * 88, 14)
        b:SetText(spec[1])
        b:SetScript("OnClick", spec[2])
    end

    return win
end

SLASH_ASSCENE1 = "/asscene"
SlashCmdList["ASSCENE"] = function()
    local win = _G["AltStableSceneProbe"] or Build()
    win = _G["AltStableSceneProbe"]
    if win:IsShown() then win:Hide() else win:Show(); FromUnit() end
end
