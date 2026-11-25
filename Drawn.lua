------------------------------------------------------------
-- Drawn.lua - what the character's gear is DRAWN as (#485, #497)
--
-- On Forever, ShowingHelm() and ShowingCloak() return false whatever the
-- character shows (measured on 71091 and 71139), so every scan used to write
-- hidehelm = 1 and hidecloak = 1, and every capture's `look` said `h` for
-- both. Hiding is done at the transmogrifier now, as a "Hidden Helm" or
-- "Hidden Cloak" appearance, and any slot can be drawn as another item.
--
-- What reads it (/fp steps as drawn, 71139, results on #485):
--   * a DressUpModel on the player: GetItemTransmogInfo(slot).appearanceID is
--     the source the slot is drawn with;
--   * C_TransmogCollection.GetSourceInfo(source): .itemID is the equipped
--     item when untouched, the transmog's otherwise; .isHideVisual is true for
--     a hidden appearance (helm 77344, cloak 77345). IsAppearanceHiddenVisual
--     on their visual says false: not used;
--   * the model has to be SHOWN - a 1x1 one at alpha 0 reads, one never shown
--     reads nothing - and a new one needs about 0.1 s after SetUnit.
-- One model for the session, parented to WorldFrame (as the capture stage):
-- the showcase and the portrait capture hide UIParent, which would blind it.
-- The primary appearance only: an illusion or a secondary appearance isn't
-- read, and two sources of one item read as that item.
--
-- Written for the head and back (#485): hidehelm / hidecloak, 1 or 0, the
-- portrait contract's fields, with `drawn` ("h1c0", the values this reading
-- wrote) and `drawnAt` beside them. Flags that don't match `drawn` didn't
-- come from this reading - the broken ones, or an older build's written over
-- a relayed record that kept the stamp - and Core drops them.
--
-- Written for every roster slot a portrait shows (#497): gearlook_<key> = the
-- drawn item id where it differs from gearid_<key>, 0 for a hidden appearance
-- (absent = drawn as equipped); `drawnOutfit` = the active saved outfit;
-- `drawnLookAt` = when that look last changed; `gearlookSig` = what they
-- were when written ("o2;3:271754;9:0"). Own signature, so a #485 build still
-- reads `drawn` as before; fields that don't match it are dropped the same way.
-- Only from a STABLE reading (login, the transmogrifier, a gear change):
-- Forever's saved outfits switch by themselves with location, movement,
-- weather and time of day - at random among several that fit - and the record
-- must not chase the weather through every sync. A switch is read for the
-- player's own portrait status only (Drawn.Current).
------------------------------------------------------------

AltStable = AltStable or {}

local Drawn = {}
AltStable.Drawn = Drawn

local FIELDS = { [1] = "hidehelm", [15] = "hidecloak" }
-- The slots a portrait shows (Capture.lua's LOOK_SLOTS), and of those the
-- ones the roster records (GEAR_SLOTS keys; the shirt and tabard aren't).
local LOOK_SLOTS = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 19 }
local ROSTER = {
    { 1, "head" }, { 3, "shoulder" }, { 5, "chest" }, { 6, "waist" }, { 7, "legs" }, { 8, "feet" },
    { 9, "wrist" }, { 10, "hands" }, { 15, "back" }, { 16, "mainhand" }, { 17, "offhand" },
}
local IS_LOOK = {}
for _, s in ipairs(LOOK_SLOTS) do IS_LOOK[s] = true end
Drawn.LOOK_SLOTS, Drawn.ROSTER = LOOK_SLOTS, ROSTER

local READ_AFTER  = 0.5   -- after SetUnit: a new model needs about 0.1 s
local LOGIN_AFTER = 2     -- with the login scan
local EQUIP_AFTER = 3     -- with Core's rescan, 3 s after the LAST gear change
-- A reading is asked again while it saw nothing, or left an EQUIPPED slot
-- unread: 2 s after a login the player's model can still be loading, and
-- gives no transmog info at all (seen in game, 2026-11-25, on dev-c75a1ff).
-- Three more tries per trigger, then it stops.
local RETRY = { 3, 10, 30 }

local model
local reading, again, againStable = false, false, false
local retries = 0
-- Which trigger the retries belong to: a fresh one takes over, and a retry
-- still queued for an earlier one then does nothing (Codex review of #498).
local generation, genStable = 0, true
-- The last reading, for the character it was read on: written by the scan
-- if the record didn't exist yet when it came.
local last
-- What the character being played is drawn as right now, every reading
-- included (a situational switch too): { look = { [slot] = value }, outfit }.
local current = { look = {} }

-- The flags as `drawn` records them (#485): kept byte for byte.
local function Signature(char)
    return "h" .. tostring(char.hidehelm or "-") .. "c" .. tostring(char.hidecloak or "-")
end

-- The per-slot look as `gearlookSig` records it (#497). Text: the "o" keeps
-- tonumber off it on the wire.
local function LookSignature(char)
    local parts = { "o" .. tostring(char.drawnOutfit or "-") }
    for _, s in ipairs(ROSTER) do
        local v = char["gearlook_" .. s[2]]
        if v ~= nil then parts[#parts + 1] = s[1] .. ":" .. tostring(v) end
    end
    return table.concat(parts, ";")
end

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

local function Equipped(slot)
    local f = rawget(_G, "GetInventoryItemID")
    local id = type(f) == "function" and tonumber((f("player", slot))) or nil
    return id or 0
end

local function ActiveOutfit()
    local o = rawget(_G, "C_TransmogOutfitInfo")
    local f = type(o) == "table" and o.GetActiveOutfitID
    if type(f) ~= "function" then return nil end
    local ok, id = pcall(f)
    return ok and tonumber(id) or nil
end
Drawn.ActiveOutfit = ActiveOutfit

-- What a slot is drawn as, three states kept apart (Codex, plan of #497):
--   the drawn item's id; "h" for a hidden appearance; 0 for a slot with
--   nothing equipped; nil when it can't be told (an equipped slot the model
--   gives no source for, no source info, an error) - never "hidden" or
--   "empty" for want of an answer.
function Drawn.SlotValue(m, slot)
    local ok, info = pcall(m.GetItemTransmogInfo, m, slot)
    local source = ok and type(info) == "table" and tonumber(info.appearanceID)
    if not source or source <= 0 then
        if Equipped(slot) == 0 then return 0 end
        return nil
    end
    local tc = rawget(_G, "C_TransmogCollection")
    local get = type(tc) == "table" and tc.GetSourceInfo
    if type(get) ~= "function" then return nil end
    local okInfo, src = pcall(get, source)
    if not okInfo or type(src) ~= "table" then return nil end
    if src.isHideVisual == true then return "h" end
    return tonumber(src.itemID)
end

-- Whether a slot's drawn source is a hidden one: true or false, nil when it
-- can't be told or nothing is equipped there (#485; the capture's stage).
function Drawn.SlotHidden(m, slot)
    local v = Drawn.SlotValue(m, slot)
    if v == "h" then return true end
    if type(v) == "number" and v > 0 then return false end
    return nil
end

-- The look of a roster slot as gearlook_<key> stores it: nil (drawn as
-- equipped, or nothing equipped), 0 (hidden), or the drawn item's id.
local function GearlookValue(value, equipped)
    if value == "h" then return equipped ~= 0 and 0 or nil end
    if type(value) == "number" and value > 0 and value ~= equipped then return value end
    return nil
end

-- A reading onto a record. The head and back flags as #485 writes them; the
-- per-slot look and the outfit only from a stable reading, and only for a
-- slot whose equipped item is still the one the reading saw (a reading from
-- before a gear swap must not be read against the new item; Codex, plan of
-- #497). Returns whether anything changed.
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
    if any then
        char.drawn = Signature(char)
        char.drawnAt = time()
    end
    local lookChanged = false
    if result.stable and type(result.look) == "table" then
        local wrote = false
        for _, s in ipairs(ROSTER) do
            local slot, key = s[1], s[2]
            local value, eq = result.look[slot], result.equipped and result.equipped[slot]
            if value ~= nil and eq ~= nil and (tonumber(char["gearid_" .. key]) or 0) == eq then
                wrote = true
                local gl = GearlookValue(value, eq)
                if char["gearlook_" .. key] ~= gl then char["gearlook_" .. key] = gl; lookChanged = true end
            end
        end
        if wrote then
            if result.outfit ~= nil and char.drawnOutfit ~= result.outfit then
                char.drawnOutfit = result.outfit
                lookChanged = true
            end
            if lookChanged or char.drawnLookAt == nil then char.drawnLookAt = time() end
            char.gearlookSig = LookSignature(char)
        end
    end
    if changed or lookChanged then
        -- The Companion dates a hidden/shown difference by gearReadAt
        -- (PortraitJudge): this was a reading of the gear (Codex, plan of #485).
        if changed then char.gearReadAt = time() end
        if AltStable.TouchCharacter then AltStable.TouchCharacter(char.guid) end
        if AltStable.RefreshPortraitStatus then pcall(AltStable.RefreshPortraitStatus) end
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
    return changed or lookChanged
end

-- Whether a reading needs another try: it saw nothing, or a slot with
-- something equipped stayed unread.
local function Unresolved(result)
    if next(result.look) == nil then return true end
    for _, slot in ipairs(LOOK_SLOTS) do
        if result.look[slot] == nil and (result.equipped[slot] or 0) ~= 0 then return true end
    end
    return false
end

-- What the character is drawn as now, for its own portrait status: the last
-- reading's look ({ [slot] = value }) and outfit. Empty before one.
function Drawn.Current()
    return current
end

-- Reads the player's drawn look. One at a time; a trigger during a read
-- asks for one more after it, so the last change wins. `retry` is a retry's
-- own call, with the generation it belongs to: anything else is a fresh
-- trigger, with its own tries. `situational` marks an outfit that switched
-- by itself: read for the status, not written to the record.
function Drawn.Read(retry, situational)
    -- An earlier trigger's retry: a newer one took over. Checked before the
    -- read in progress, or it would queue a trailing read of its own (Codex
    -- review of #498).
    if retry ~= nil and retry ~= generation then return false end
    if reading then
        again = true
        if not situational then againStable = true end
        return false
    end
    if retry == nil then
        retries, generation = 0, generation + 1
        genStable = not situational
    end
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return false end
    reading = true
    local m = Model()
    pcall(m.SetUnit, m, "player")
    C_Timer.After(READ_AFTER, function()
        local result = { look = {}, equipped = {}, stable = genStable, outfit = ActiveOutfit() }
        for _, slot in ipairs(LOOK_SLOTS) do
            result.equipped[slot] = Equipped(slot)
            result.look[slot] = Drawn.SlotValue(m, slot)
        end
        for slot in pairs(FIELDS) do
            local v = result.look[slot]
            if v == "h" then result[slot] = true
            elseif type(v) == "number" and v > 0 then result[slot] = false end
        end
        -- The status's view: every slot read, the outfit now. A confirmed
        -- empty slot replaces what was there (an unequipped shirt).
        for slot, v in pairs(result.look) do current.look[slot] = v end
        current.outfit = result.outfit
        local char = type(AltStableDB) == "table" and AltStableDB[guid]
        -- Retried on what this reading itself saw, before the merge below.
        local unresolved = Unresolved(result)
        if next(result.look) ~= nil then
            -- What the scan may still need: a slot this reading couldn't see
            -- keeps the last reading's value while the same item is on.
            local prev = last and last.guid == guid and last.result
            if prev then
                for _, slot in ipairs(LOOK_SLOTS) do
                    if result.look[slot] == nil and prev.look and prev.look[slot] ~= nil
                       and prev.equipped and prev.equipped[slot] == result.equipped[slot] then
                        result.look[slot] = prev.look[slot]
                        if FIELDS[slot] then result[slot] = prev[slot] end
                    end
                end
            end
            last = { guid = guid, result = result }
            if type(char) == "table" then Drawn.Apply(char, result) end
        end
        if AltStable.RefreshPortraitStatus then pcall(AltStable.RefreshPortraitStatus) end
        reading = false
        if again then
            local stable = againStable
            again, againStable = false, false
            Drawn.Read(nil, not stable)
        elseif unresolved and retries < #RETRY then
            retries = retries + 1
            local gen = generation
            C_Timer.After(RETRY[retries], function() Drawn.Read(gen) end)
        end
    end)
    return true
end

-- A scan of the character being played: a reading that came before its
-- record existed goes on it (Apply checks each slot's equipped item).
function Drawn.OnScanned(char)
    if last and type(char) == "table" and char.guid == last.guid then Drawn.Apply(char, last.result) end
end

local equipTimer
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TRANSMOGRIFY_CLOSE")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
pcall(events.RegisterEvent, events, "TRANSMOG_DISPLAYED_OUTFIT_CHANGED")
events:SetScript("OnEvent", function(_, event, a, b)
    if event == "PLAYER_ENTERING_WORLD" then
        if a or b then C_Timer.After(LOGIN_AFTER, function() Drawn.Read() end) end   -- a login or a reload
    elseif event == "TRANSMOGRIFY_CLOSE" then
        Drawn.Read()
    elseif event == "TRANSMOG_DISPLAYED_OUTFIT_CHANGED" then
        Drawn.Read(nil, true)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Restarted on each change, as Core's rescan is: both read after the
        -- last one.
        if IS_LOOK[tonumber(a) or 0] then
            if equipTimer and equipTimer.Cancel then equipTimer:Cancel() end
            equipTimer = C_Timer.NewTimer(EQUIP_AFTER, function() equipTimer = nil; Drawn.Read() end)
        end
    end
end)

-- Fields that don't match their stamp didn't come from this reading: the
-- broken helm/cloak flags (always 1), or an older build's written beside a
-- stamp it relayed. Dropped with the stamp: absent means shown, and drawn as
-- equipped. At load, and for a record taken from a peer (Core.lua).
function AltStable.DropUndrawnFlags(char)
    if type(char) ~= "table" then return end
    if char.drawn ~= Signature(char) then
        char.hidehelm, char.hidecloak, char.drawn, char.drawnAt = nil, nil, nil, nil
    end
    if char.gearlookSig ~= LookSignature(char) then
        for _, s in ipairs(ROSTER) do char["gearlook_" .. s[2]] = nil end
        char.drawnOutfit, char.drawnLookAt, char.gearlookSig = nil, nil, nil
    end
end

AltStable._test = AltStable._test or {}
AltStable._test.DrawnFrame = events
AltStable._test.DrawnModel = function() return model end
AltStable._test.ResetDrawn = function()
    model, reading, again, againStable, last, equipTimer = nil, false, false, false, nil, nil
    retries, generation, genStable = 0, 0, true
    current = { look = {} }
end
