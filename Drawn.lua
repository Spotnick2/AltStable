------------------------------------------------------------
-- Drawn.lua - whether the helm and cloak are DRAWN (#485)
--
-- On Forever, ShowingHelm() and ShowingCloak() return false whatever the
-- character shows (measured on 71091 and 71139), so every scan used to write
-- hidehelm = 1 and hidecloak = 1, and every capture's `look` said `h` for
-- both. Hiding is done at the transmogrifier now, as a "Hidden Helm" or
-- "Hidden Cloak" appearance.
--
-- What reads it (/fp steps as drawn, 71139, results on #485):
--   * a DressUpModel on the player: GetItemTransmogInfo(slot).appearanceID is
--     the source the slot is drawn with;
--   * C_TransmogCollection.GetSourceInfo(source).isHideVisual is true for the
--     hidden helm (77344) and cloak (77345). IsAppearanceHiddenVisual on their
--     visual says false: not used;
--   * the model has to be SHOWN - a 1x1 one at alpha 0 reads, one never shown
--     reads nothing - and a new one needs about 0.1 s after SetUnit.
-- One model for the session, parented to WorldFrame (as the capture stage):
-- the showcase and the portrait capture hide UIParent, which would blind it.
--
-- Written: hidehelm / hidecloak, 1 or 0, the portrait contract's fields
-- (docs/PORTRAIT-CONTRACT.md), only for a slot read; `drawnAt` beside them
-- marks a record whose flags came from this reading. Records without it had
-- the broken ones: Core drops their flags (absent means shown).
------------------------------------------------------------

AltStable = AltStable or {}

local Drawn = {}
AltStable.Drawn = Drawn

local FIELDS = { [1] = "hidehelm", [15] = "hidecloak" }
local READ_AFTER  = 0.5   -- after SetUnit: a new model needs about 0.1 s
local LOGIN_AFTER = 2     -- with the login scan
local EQUIP_AFTER = 3     -- with Core's rescan after a gear change
-- A reading that saw nothing is asked again: 2 s after a login the player's
-- model can still be loading, and the model then gives no transmog info at
-- all (seen in game, 2026-11-25, on dev-c75a1ff). Then it stops: a character
-- with no helm and no cloak reads nothing too.
local RETRY = { 3, 10, 30 }

local model
local reading, again = false, false
local retries = 0
-- The last reading, for the character it was read on: written by the scan
-- if the record didn't exist yet when it came.
local last

local function Model()
    if model then return model end
    local parent = rawget(_G, "WorldFrame") or UIParent
    model = CreateFrame("DressUpModel", nil, parent)
    model:SetSize(1, 1)
    model:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    model:SetAlpha(0)
    if model.EnableMouse then model:EnableMouse(false) end
    model:Show()
    return model
end

-- Whether a slot's drawn source is a hidden one: true or false, nil when it
-- can't be read (nothing drawn, no source info, an error).
local function SlotHidden(m, slot)
    local ok, info = pcall(m.GetItemTransmogInfo, m, slot)
    local source = ok and type(info) == "table" and tonumber(info.appearanceID)
    if not source or source <= 0 then return nil end
    local tc = rawget(_G, "C_TransmogCollection")
    local get = type(tc) == "table" and tc.GetSourceInfo
    if type(get) ~= "function" then return nil end
    local okInfo, src = pcall(get, source)
    if not okInfo or type(src) ~= "table" then return nil end
    return src.isHideVisual == true
end

-- A reading onto a record: the flags read, the stamp, and the dates and
-- notices a change needs. Returns whether a flag changed.
function Drawn.Apply(char, result)
    if type(char) ~= "table" or type(result) ~= "table" then return false end
    local changed, any = false, false
    for slot, field in pairs(FIELDS) do
        local hidden = result[slot]
        if hidden ~= nil then
            any = true
            local v = hidden and 1 or 0
            if char[field] ~= v then char[field] = v; changed = true end
        end
    end
    if not any then return false end
    char.drawnAt = time()
    if changed then
        -- The Companion dates a hidden/shown difference by gearReadAt
        -- (PortraitJudge): this was a reading of the gear (Codex, plan of #485).
        char.gearReadAt = time()
        if AltStable.TouchCharacter then AltStable.TouchCharacter(char.guid) end
        if AltStable.RefreshPortraitStatus then pcall(AltStable.RefreshPortraitStatus) end
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
    return changed
end

-- Reads the player's helm and cloak. One at a time; a trigger during a read
-- asks for one more after it, so the last change wins.
function Drawn.Read()
    if reading then again = true; return false end
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return false end
    reading = true
    local m = Model()
    pcall(m.SetUnit, m, "player")
    C_Timer.After(READ_AFTER, function()
        local result = {}
        for slot in pairs(FIELDS) do result[slot] = SlotHidden(m, slot) end
        local any = next(result) ~= nil
        local char = type(AltStableDB) == "table" and AltStableDB[guid]
        if any then
            retries = 0
            last = { guid = guid, result = result }
            if type(char) == "table" then Drawn.Apply(char, result) end
        end
        reading = false
        if again then
            again = false; Drawn.Read()
        elseif not any and retries < #RETRY then
            retries = retries + 1
            C_Timer.After(RETRY[retries], Drawn.Read)
        end
    end)
    return true
end

-- A scan of the character being played: a reading that came before its
-- record existed goes on it.
function Drawn.OnScanned(char)
    if last and type(char) == "table" and char.guid == last.guid then Drawn.Apply(char, last.result) end
end

local pendingEquip
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TRANSMOGRIFY_CLOSE")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:SetScript("OnEvent", function(_, event, a, b)
    if event == "PLAYER_ENTERING_WORLD" then
        if a or b then C_Timer.After(LOGIN_AFTER, Drawn.Read) end   -- a login or a reload
    elseif event == "TRANSMOGRIFY_CLOSE" then
        Drawn.Read()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if FIELDS[tonumber(a) or 0] and not pendingEquip then
            pendingEquip = true
            C_Timer.After(EQUIP_AFTER, function() pendingEquip = nil; Drawn.Read() end)
        end
    end
end)

-- Records whose flags didn't come from this reading had the broken ones
-- (always 1): dropped, absent means shown. At load, and for a record taken
-- from a peer on an older build (Core.lua).
function AltStable.DropUndrawnFlags(char)
    if type(char) == "table" and char.drawnAt == nil then
        char.hidehelm, char.hidecloak = nil, nil
    end
end

AltStable._test = AltStable._test or {}
AltStable._test.DrawnFrame = events
AltStable._test.DrawnModel = function() return model end
AltStable._test.ResetDrawn = function()
    model, reading, again, last, pendingEquip, retries = nil, false, false, nil, nil, 0
end
