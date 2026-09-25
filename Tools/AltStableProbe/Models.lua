------------------------------------------------------------
-- Models.lua — can this client render an OFFLINE alt? (#15)
--
-- The Roster plugin's scene needs to draw characters who are not logged in.
-- On TBC Classic that never worked and the old addon fell back to PNG cutouts
-- scraped from the Battle.net armory, which Forever has no equivalent for.
--
-- The method table says DressUpModel:TryOn / :SetDisplayInfo / :Undress all
-- exist here (on 69913, 69977 and 70009 alike). Existence is not behaviour, so
-- this measures it.
--
-- THE EXPERIMENT THAT MATTERS: rendering the CURRENT character proves nothing.
-- The client already knows that character, so SetDisplayInfo can look like a
-- success while carrying none of their customization. The decisive test is to
-- capture a display ID on character A, log in as character B, and render A from
-- the saved number alone - ideally beside a second saved character of the SAME
-- race and gender. If two same-race captures render identically, the display ID
-- is a race/gender mannequin and an exact likeness is off the table.
--
-- That test only became possible when 1.60.1.70009 fixed SavedVariables (#23):
-- before it, nothing captured on character A survived to character B.
--
-- Measured signals, so this is not pure eyeballing:
--   GetDisplayInfo()          - did the display ID stick?
--   GetModelFileID()          - did a model actually load?
--   GetItemTransmogInfoList() - did TryOn register anything?
------------------------------------------------------------

local SLOTS = 19           -- Vanilla equipped slots, 1..19

-- Render knobs, flipped in the viewer. The pale untextured body the first run
-- produced is what Blizzard's TRANSMOG SKIN looks like - the featureless
-- mannequin the dressing room poses - and the frame reported a 19-slot
-- transmog list the instant SetDisplayInfo landed, which is the dressing-room
-- state. So these get tried in combination rather than guessed at.
local knobs = {
    { key = "skin",    method = "SetUseTransmogSkin",    value = false,
      label = "TransmogSkin", hint = "OFF should give the character's own skin instead of the mannequin" },
    { key = "choices", method = "SetUseTransmogChoices", value = true,
      label = "TransmogChoices", hint = "customization choices: hair, face, skin colour" },
    { key = "auto",    method = "SetAutoDress",          value = true,
      label = "AutoDress", hint = "let the model dress itself from the display" },
}

AltStableProbeDB = AltStableProbeDB or {}

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[model]|r " .. tostring(s))
end

-- Every model call goes through here: the client is allowed to not have one.
local function Try(obj, method, ...)
    if type(obj) ~= "table" and type(obj) ~= "userdata" then return false, "no frame" end
    local fn = obj[method]
    if type(fn) ~= "function" then return false, "missing" end
    local ok, err = pcall(fn, obj, ...)
    if ok then return true, "ok" end
    return false, tostring(err)
end

local function Get(obj, method, ...)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return nil, "missing" end
    local ok, value = pcall(fn, obj, ...)
    if ok then return value, "ok" end
    return nil, tostring(value)
end

------------------------------------------------------------
-- Capture
------------------------------------------------------------

local function CaptureSelf()
    local guid = UnitGUID("player")
    if not guid then return nil, "no guid" end

    local first, surname = UnitName("player")
    local name = (surname and surname ~= "") and (first .. " " .. surname) or first

    local raceLoc, raceToken = UnitRace("player")
    local classLoc, classToken = UnitClass("player")

    local displayID
    if C_PlayerInfo and type(C_PlayerInfo.GetDisplayID) == "function" then
        local ok, id = pcall(C_PlayerInfo.GetDisplayID)
        if ok then displayID = id end
    end

    local gear = {}
    for slot = 1, SLOTS do
        local link = GetInventoryItemLink("player", slot)
        if link then gear[slot] = link end
    end

    AltStableProbeDB.models = AltStableProbeDB.models or {}
    AltStableProbeDB.models[guid] = {
        guid = guid, name = name, realm = GetRealmName(),
        race = raceToken, raceLoc = raceLoc,
        class = classToken, classLoc = classLoc,
        sex = UnitSex("player"),          -- 2 = male, 3 = female
        displayID = displayID,
        gear = gear,
        captured = date("%Y-%m-%d %H:%M:%S"),
        build = select(2, GetBuildInfo()),
    }
    return AltStableProbeDB.models[guid]
end

local function StoredList()
    local out = {}
    for _, rec in pairs(AltStableProbeDB.models or {}) do out[#out + 1] = rec end
    table.sort(out, function(a, b)
        if a.race ~= b.race then return (a.race or "") < (b.race or "") end
        if a.sex ~= b.sex then return (a.sex or 0) < (b.sex or 0) end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

local function Describe(rec)
    if not rec then return "(none)" end
    local n = 0
    for _ in pairs(rec.gear or {}) do n = n + 1 end
    return string.format("%s  %s %s  display=%s  gear=%d",
        rec.name or "?", rec.raceLoc or rec.race or "?",
        (rec.sex == 3) and "female" or "male",
        tostring(rec.displayID), n)
end

------------------------------------------------------------
-- The viewer: two panes, side by side, on purpose
------------------------------------------------------------

local viewer, panes

local function BuildPane(parent, index)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetSize(230, 330)
    pane:SetPoint("TOPLEFT", 14 + (index - 1) * 240, -52)

    local model = CreateFrame("DressUpModel", nil, pane)
    model:SetAllPoints()
    pane.model = model

    local label = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 16)
    label:SetPoint("TOPRIGHT", 0, 16)
    label:SetJustifyH("CENTER")
    pane.label = label

    local status = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, -4)
    status:SetPoint("TOPRIGHT", pane, "BOTTOMRIGHT", 0, -4)
    status:SetJustifyH("LEFT"); status:SetWordWrap(true)
    status:SetTextColor(0.6, 0.6, 0.6)
    pane.status = status

    local prev = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    prev:SetSize(24, 18); prev:SetText("<")
    prev:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, -46)
    local next_ = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    next_:SetSize(24, 18); next_:SetText(">")
    next_:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, -46)
    pane.prev, pane.next = prev, next_

    pane.index = 1
    return pane
end

local function PaneRecord(pane)
    local list = StoredList()
    if #list == 0 then return nil end
    if pane.index > #list then pane.index = 1 end
    if pane.index < 1 then pane.index = #list end
    return list[pane.index], #list
end

-- Apply a saved character to a pane, reporting what the client did with it.
local function Apply(pane, mode)
    local rec = PaneRecord(pane)
    local m = pane.model
    if not rec then pane.label:SetText("no captures yet"); return end

    pane.label:SetText(rec.name .. "  |cff808080" .. (rec.raceLoc or "?") ..
        ((rec.sex == 3) and " f" or " m") .. "|r")

    local notes = {}
    Try(m, "ClearModel")

    -- Read the defaults once, then push our values. Order matters: these have
    -- to be set BEFORE the display is applied, or the model is already built.
    if not pane.reportedDefaults then
        pane.reportedDefaults = true
        local d1 = Get(m, "GetUseTransmogSkin")
        local d2 = Get(m, "GetAutoDress")
        Out("defaults: GetUseTransmogSkin=" .. tostring(d1) .. " GetAutoDress=" .. tostring(d2))
    end
    for _, knob in ipairs(knobs) do
        local ok, err = Try(m, knob.method, knob.value)
        if not ok then notes[#notes + 1] = knob.method .. "=" .. err end
    end

    if mode == "unit" then
        local ok, err = Try(m, "SetUnit", "player")
        notes[#notes + 1] = "SetUnit(player)=" .. (ok and "ok" or err)
    else
        if not rec.displayID then
            notes[#notes + 1] = "no display id captured"
        else
            local ok, err = Try(m, "SetDisplayInfo", rec.displayID)
            notes[#notes + 1] = "SetDisplayInfo(" .. rec.displayID .. ")=" .. (ok and "ok" or err)
        end
    end

    if mode == "dress" then
        local ok, err = Try(m, "Dress")
        notes[#notes + 1] = "Dress()=" .. (ok and "ok" or err)
    end

    if mode == "gear" then
        local okU, errU = Try(m, "Undress")
        notes[#notes + 1] = "Undress=" .. (okU and "ok" or errU)
        local worn, failed = 0, 0
        for slot = 1, SLOTS do
            local link = rec.gear and rec.gear[slot]
            if link then
                local ok = Try(m, "TryOn", link)
                if ok then worn = worn + 1 else failed = failed + 1 end
            end
        end
        notes[#notes + 1] = string.format("TryOn %d ok / %d failed", worn, failed)
    end

    Try(m, "SetPortraitZoom", 0.35)
    Try(m, "SetFacing", 0.4)
    Try(m, "RefreshCamera")

    -- The measured part: what does the frame say about itself now?
    local shown = Get(m, "GetDisplayInfo")
    local fileID = Get(m, "GetModelFileID")
    local tmog = Get(m, "GetItemTransmogInfoList")
    local tmogN = (type(tmog) == "table") and #tmog or nil
    notes[#notes + 1] = "-> GetDisplayInfo=" .. tostring(shown)
        .. " GetModelFileID=" .. tostring(fileID)
        .. " transmogList=" .. tostring(tmogN)
    local state = {}
    for _, knob in ipairs(knobs) do
        state[#state + 1] = knob.label .. "=" .. tostring(knob.value)
    end
    notes[#notes + 1] = "   " .. table.concat(state, " ")

    pane.status:SetText(table.concat(notes, "\n"))
    for _, n in ipairs(notes) do Out(rec.name .. ": " .. n) end
end

local lastMode = "display"

local function ApplyBoth(mode)
    lastMode = mode or lastMode
    for _, pane in ipairs(panes) do Apply(pane, lastMode) end
end

local function BuildViewer()
    if viewer then return viewer end

    viewer = CreateFrame("Frame", "AltStableModelProbe", UIParent, "BasicFrameTemplateWithInset")
    viewer:SetSize(510, 500)
    viewer:SetPoint("CENTER")
    viewer:SetMovable(true); viewer:EnableMouse(true)
    viewer:RegisterForDrag("LeftButton")
    viewer:SetScript("OnDragStart", viewer.StartMoving)
    viewer:SetScript("OnDragStop", viewer.StopMovingOrSizing)
    if viewer.TitleText then viewer.TitleText:SetText("Model probe (#15)") end
    table.insert(UISpecialFrames, "AltStableModelProbe")

    local hint = viewer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 14, -30)
    hint:SetPoint("TOPRIGHT", -14, -30)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.7, 0.7, 0.7)
    hint:SetText("Pick two SAVED characters. Identical render = the display id is a mannequin.")

    panes = { BuildPane(viewer, 1), BuildPane(viewer, 2) }
    for _, pane in ipairs(panes) do
        pane.prev:SetScript("OnClick", function() pane.index = pane.index - 1; Apply(pane, "display") end)
        pane.next:SetScript("OnClick", function() pane.index = pane.index + 1; Apply(pane, "display") end)
    end
    panes[2].index = 2

    local buttons = {
        { "Display", "display", "render both from their SAVED display id" },
        { "+ Gear",  "gear",    "then Undress and TryOn every saved item" },
        { "Unit",    "unit",    "baseline: the live character, ignoring saves" },
        { "Dress",   "dress",   "ask the model to dress itself, no saved links" },
    }
    for i, spec in ipairs(buttons) do
        local b = CreateFrame("Button", nil, viewer, "UIPanelButtonTemplate")
        b:SetSize(84, 22)
        b:SetPoint("BOTTOMLEFT", 14 + (i - 1) * 88, 14)
        b:SetText(spec[1])
        b:SetScript("OnClick", function() ApplyBoth(spec[2]) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(spec[3], 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Toggle row: flip a knob and both panes re-render, so a combination can
    -- be found by eye in seconds instead of by rebuild-and-relog.
    for i, knob in ipairs(knobs) do
        local cb = CreateFrame("CheckButton", nil, viewer, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("BOTTOMLEFT", 14 + (i - 1) * 150, 40)
        cb:SetChecked(knob.value)
        local lbl = viewer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        lbl:SetText(knob.label)
        cb:SetScript("OnClick", function(self)
            knob.value = self:GetChecked() and true or false
            ApplyBoth(lastMode or "display")
        end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(knob.hint, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local cap = CreateFrame("Button", nil, viewer, "UIPanelButtonTemplate")
    cap:SetSize(110, 22)
    cap:SetPoint("BOTTOMRIGHT", -14, 14)
    cap:SetText("Capture me")
    cap:SetScript("OnClick", function()
        local rec = CaptureSelf()
        Out(rec and ("captured " .. Describe(rec)) or "capture failed")
        ApplyBoth("display")
    end)

    return viewer
end

------------------------------------------------------------
-- Capability report — what the frame type actually offers here
------------------------------------------------------------

local function Caps()
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, UIParent)
    if not ok or not m then
        Out("|cffff5555CreateFrame('DressUpModel') failed|r - " .. tostring(m))
        return
    end
    m:Hide()
    local names = { "SetUnit", "SetDisplayInfo", "TryOn", "Undress", "SetItemTransmogInfo",
                    "SetItemAppearance", "SetSheathed", "SetCreature", "SetModel",
                    "SetAnimation", "SetPortraitZoom", "SetCamera", "SetFacing",
                    "SetKeepModelOnHide", "RefreshCamera", "GetDisplayInfo",
                    "GetModelFileID", "GetItemTransmogInfoList" }
    local have, miss = {}, {}
    for _, n in ipairs(names) do
        if type(m[n]) == "function" then have[#have + 1] = n else miss[#miss + 1] = n end
    end
    Out("present: " .. table.concat(have, " "))
    Out(#miss > 0 and ("|cffff5555missing:|r " .. table.concat(miss, " ")) or "nothing missing")
    Out("C_PlayerInfo.GetDisplayID = " ..
        tostring(C_PlayerInfo and type(C_PlayerInfo.GetDisplayID) == "function"))
end

------------------------------------------------------------
-- Commands
------------------------------------------------------------

SLASH_ASMODEL1 = "/asmodel"
SlashCmdList["ASMODEL"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "capture" then
        local rec = CaptureSelf()
        Out(rec and ("captured " .. Describe(rec)) or "capture failed")
        return
    end
    if msg == "list" then
        local list = StoredList()
        if #list == 0 then Out("nothing captured yet - /asmodel capture on each character") end
        for i, rec in ipairs(list) do Out(i .. ". " .. Describe(rec)) end
        return
    end
    if msg == "caps" then Caps(); return end
    if msg == "wipe" then
        AltStableProbeDB.models = {}
        Out("captures cleared")
        return
    end
    if msg ~= "" and msg ~= "show" then
        Out("usage: /asmodel [show] | capture | list | caps | wipe")
        return
    end

    local f = BuildViewer()
    if f:IsShown() then f:Hide() else f:Show(); ApplyBoth("display") end
end

------------------------------------------------------------
-- Capture on login, so simply playing your alts fills the set.
------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    -- A short delay: display id and inventory are not reliably readable the
    -- instant PLAYER_LOGIN fires.
    C_Timer.After(5, function()
        local rec = CaptureSelf()
        if rec then
            Out("captured " .. Describe(rec) .. "  (/asmodel to compare)")
        end
    end)
end)
