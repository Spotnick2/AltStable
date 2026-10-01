----------------------------------------------------------------------------
-- /asprobe pet ... - can the Roster draw a hunter pet or a warlock demon with
-- nobody logged in? (#75)
--
-- Offline PLAYER display ids render untextured (Models.lua): a player's look
-- is a composite built from customization choices, which only a live unit
-- carries. A creature's texture is baked into its model, so a creature id or
-- a creature display id MAY render textured from the saved number alone. If
-- it does, pets need no screenshot capture at all.
--
--   /asprobe pet            capture the summoned pet (if any), open the viewer
--   /asprobe pet capture    record the pet: GUID, npc id, display id, family
--   /asprobe pet stable     the hunter's 5 active slots, read anywhere?
--   /asprobe pet list       what has been recorded
--   /asprobe pet wipe       forget the records
--
-- The viewer draws the selected record three ways, side by side:
--   Live      SetUnit("pet")          baseline, only while a pet is out
--   Creature  SetCreature(npcID)      the npc id parsed from the pet's GUID
--   Display   SetDisplayInfo(display) the display id read off the live model
-- THE DECISIVE TEST: record a pet, dismiss it (or log another character),
-- then judge Creature and Display. Textured = no capture pipeline needed.
-- A tamed pet may share its npc id with the wild beast but not its skin, so
-- Creature and Display can legitimately differ; Display is the exact one.
--
-- MEASURED on 70124, first run: a hunter pet's GUID is
-- "Pet-0-6783-1-164450-165189-..." - npc 165189 is the generic "Hunter Pet",
-- the same for every beast, so SetCreature(npc) is useless for hunters. And
-- GetDisplayInfo() on a SetUnit("pet") model reads 0. The stable UI draws
-- stabled pets (not units) from C_StableInfo.GetStablePetInfo(slot).displayID,
-- so the hunter's display id and real creature id are read from there.
----------------------------------------------------------------------------

AltStableProbe = AltStableProbe or {}

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[pet]|r " .. tostring(s))
end

local function Call(obj, method, ...)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return false, "missing" end
    local ok, a = pcall(fn, obj, ...)
    if ok then return true, a end
    return false, tostring(a)
end

local function Store()
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.pets = AltStableProbeDB.pets or {}
    return AltStableProbeDB.pets
end

local function NewModel(parent)
    local ok, m = pcall(CreateFrame, "PlayerModel", nil, parent)
    if not ok or not m then m = CreateFrame("DressUpModel", nil, parent) end
    return m
end

-- "Pet-0-3110-0-4-165189-01009C9D2A" or "Creature-0-...-416-...": the sixth
-- field is the npc id on both, if this client follows the Retail layout.
local function ParseGUID(guid)
    if type(guid) ~= "string" then return nil, nil end
    local parts = { strsplit("-", guid) }
    return parts[1], tonumber(parts[6])
end

local function Describe(rec)
    return string.format("%s (%s's %s, %s)  kind=%s npc=%s creature=%s display=%s (model said %s, slot %s)",
        tostring(rec.name), tostring(rec.owner), tostring(rec.family or rec.ctype),
        tostring(rec.ownerClass), tostring(rec.kind), tostring(rec.npcID),
        tostring(rec.creatureID), tostring(rec.displayID), tostring(rec.modelDisplayID),
        tostring(rec.stableSlot))
end

-- The hunter's active slots: is C_StableInfo readable away from a stable
-- master, and which slot is the summoned pet? Logged whole, once per capture.
local function StableSlots()
    local out = {}
    if not (C_StableInfo and C_StableInfo.GetStablePetInfo) then
        Out("C_StableInfo.GetStablePetInfo missing")
        return out
    end
    for slot = 1, 5 do
        local ok, info = pcall(C_StableInfo.GetStablePetInfo, slot)
        if not ok then
            Out("stable slot " .. slot .. ": error " .. tostring(info))
        elseif info then
            out[#out + 1] = info
            Out(string.format("stable slot %d: %s (%s) displayID=%s creatureID=%s petNumber=%s",
                slot, tostring(info.name), tostring(info.familyName), tostring(info.displayID),
                tostring(info.creatureID), tostring(info.petNumber)))
        else
            Out("stable slot " .. slot .. ": empty")
        end
    end
    return out
end

-- The display id only exists on a model frame, so render the pet once on an
-- off-screen model and read it back after the model has had a moment to load.
local reader
local function Capture(quiet)
    if not UnitExists("pet") then
        if not quiet then Out("no pet out - summon one first") end
        return
    end
    local guid = UnitGUID("pet")
    local kind, npcID = ParseGUID(guid)
    local first, surname = UnitName("player")
    local rec = {
        guid = guid, kind = kind, npcID = npcID,
        name = UnitName("pet"),
        family = UnitCreatureFamily and UnitCreatureFamily("pet") or nil,
        ctype = UnitCreatureType and UnitCreatureType("pet") or nil,
        owner = (surname and surname ~= "") and (first .. " " .. surname) or first,
        ownerClass = select(2, UnitClass("player")),
        captured = date("%Y-%m-%d %H:%M:%S"),
        build = select(2, GetBuildInfo()),
    }
    reader = reader or NewModel(UIParent)
    reader:SetSize(64, 64)
    reader:ClearAllPoints()
    reader:SetPoint("BOTTOMLEFT", UIParent, "TOPLEFT", 0, 0)  -- off screen, still shown
    reader:Show()
    local okU, errU = Call(reader, "SetUnit", "pet")
    rec.setUnit = okU and "ok" or errU
    -- A demon has no stable; a hunter's summoned pet is the slot with its name.
    for _, info in ipairs(StableSlots()) do
        if info.name == rec.name then
            rec.stableSlot, rec.stableDisplayID, rec.stableCreatureID =
                info.slotID, info.displayID, info.creatureID
        end
    end
    C_Timer.After(1, function()
        rec.modelDisplayID = select(2, Call(reader, "GetDisplayInfo"))
        -- The model's own reading is 0 on 70124; the stable's is the real one.
        rec.displayID = rec.stableDisplayID
            or ((rec.modelDisplayID or 0) > 0 and rec.modelDisplayID or nil)
        rec.creatureID = rec.stableCreatureID or rec.npcID
        rec.modelFileID = select(2, Call(reader, "GetModelFileID"))
        local key = tostring(rec.owner) .. "/" .. tostring(rec.npcID) .. "/" .. tostring(rec.displayID)
        Store()[key] = rec
        Out("recorded " .. Describe(rec) .. "  fileID=" .. tostring(rec.modelFileID)
            .. "  guid=" .. tostring(guid))
    end)
end

local function List()
    local out = {}
    for _, rec in pairs(Store()) do out[#out + 1] = rec end
    table.sort(out, function(a, b) return (a.captured or "") < (b.captured or "") end)
    return out
end

----------------------------------------------------------------------------
-- The viewer
----------------------------------------------------------------------------

local viewer, panes, index = nil, nil, 1

local MODES = {
    { "Live (pet out)", function(m, rec)
        return "SetUnit(pet)", Call(m, "SetUnit", "pet") end },
    { "Creature (saved id)", function(m, rec)
        local id = rec and (rec.creatureID or rec.npcID)
        if not id then return "SetCreature", false, "no creature id" end
        return "SetCreature(" .. id .. ")", Call(m, "SetCreature", id) end },
    { "Display (saved id)", function(m, rec)
        if not rec or not rec.displayID then return "SetDisplayInfo", false, "no display id" end
        return "SetDisplayInfo(" .. rec.displayID .. ")", Call(m, "SetDisplayInfo", rec.displayID) end },
}

local function Render()
    local list = List()
    if index > #list then index = 1 elseif index < 1 then index = #list end
    local rec = list[index]
    viewer.title:SetText(rec and (index .. "/" .. #list .. "  " .. Describe(rec)) or "nothing recorded yet")
    for i, pane in ipairs(panes) do
        local m = pane.model
        Call(m, "ClearModel")
        local what, ok, err = MODES[i][2](m, rec)
        Call(m, "SetPortraitZoom", 0)
        Call(m, "SetFacing", 0.5)
        Call(m, "RefreshCamera")
        local shown = select(2, Call(m, "GetDisplayInfo"))
        local file = select(2, Call(m, "GetModelFileID"))
        local line = string.format("%s=%s\n-> display=%s fileID=%s", what,
            ok and "ok" or tostring(err), tostring(shown), tostring(file))
        pane.status:SetText(line)
        Out(MODES[i][1] .. ": " .. line:gsub("\n", "  "))
    end
end

local function Build()
    if viewer then return viewer end
    viewer = CreateFrame("Frame", "AltStablePetProbe", UIParent, "BasicFrameTemplateWithInset")
    viewer:SetSize(740, 420)
    viewer:SetPoint("CENTER")
    viewer:SetMovable(true); viewer:EnableMouse(true)
    viewer:RegisterForDrag("LeftButton")
    viewer:SetScript("OnDragStart", viewer.StartMoving)
    viewer:SetScript("OnDragStop", viewer.StopMovingOrSizing)
    if viewer.TitleText then viewer.TitleText:SetText("Pet probe (#75)") end
    table.insert(UISpecialFrames, "AltStablePetProbe")

    viewer.title = viewer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    viewer.title:SetPoint("TOPLEFT", 14, -30)
    viewer.title:SetPoint("TOPRIGHT", -14, -30)
    viewer.title:SetJustifyH("LEFT")

    panes = {}
    for i, spec in ipairs(MODES) do
        local pane = CreateFrame("Frame", nil, viewer)
        pane:SetSize(230, 280)
        pane:SetPoint("TOPLEFT", 14 + (i - 1) * 240, -64)
        local bg = pane:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.12, 0.12, 0.14, 1)
        pane.model = NewModel(pane)
        pane.model:SetAllPoints()
        local label = pane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("BOTTOM", pane, "TOP", 0, 2)
        label:SetText(spec[1])
        pane.status = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pane.status:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, -4)
        pane.status:SetPoint("TOPRIGHT", pane, "BOTTOMRIGHT", 0, -4)
        pane.status:SetJustifyH("LEFT")
        pane.status:SetTextColor(0.7, 0.7, 0.7)
        panes[i] = pane
    end

    local function Button(text, x, fn)
        local b = CreateFrame("Button", nil, viewer, "UIPanelButtonTemplate")
        b:SetSize(90, 22); b:SetText(text)
        b:SetPoint("BOTTOMLEFT", x, 12)
        b:SetScript("OnClick", fn)
    end
    Button("< Prev", 14, function() index = index - 1; Render() end)
    Button("Next >", 110, function() index = index + 1; Render() end)
    Button("Re-render", 206, Render)
    Button("Capture pet", 302, function()
        Capture()
        C_Timer.After(1.2, function() index = #List(); Render() end)
    end)
    return viewer
end

function AltStableProbe.Pet(arg)
    arg = (arg or ""):lower()
    if arg == "capture" then Capture(); return end
    if arg == "stable" then StableSlots(); return end
    if arg == "list" then
        local list = List()
        if #list == 0 then Out("nothing recorded - summon a pet, /asprobe pet capture") end
        for i, rec in ipairs(list) do Out(i .. ". " .. Describe(rec)) end
        return
    end
    if arg == "wipe" then Store(); AltStableProbeDB.pets = {}; Out("records cleared"); return end
    if arg ~= "" then Out("usage: /asprobe pet [capture | stable | list | wipe]"); return end
    local f = Build()
    if f:IsShown() then f:Hide(); return end
    f:Show()
    if UnitExists("pet") then
        Capture(true)
        C_Timer.After(1.2, function() index = #List(); Render() end)
    else
        Render()
    end
end

-- Record a pet whenever one comes out, so simply playing fills the set.
local ev = CreateFrame("Frame")
ev:RegisterEvent("UNIT_PET")
ev:SetScript("OnEvent", function(_, _, unit)
    if unit ~= "player" then return end
    C_Timer.After(2, function()
        if UnitExists("pet") then Capture(true) end
    end)
end)
