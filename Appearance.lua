------------------------------------------------------------
-- AltStable/Appearance.lua — each character's look, from the barber's chair
--
-- Which face, hair, skin colour... a character wears, shown from the
-- right-click menu ("Appearance...").
--
-- The barber is the ONLY place this client hands those choices to Lua.
-- C_BarberShop.GetAvailableCustomizations() returns them while the chair is
-- open and nothing outside it (owner's /dump away from a barber, 1.60.1.70450:
-- empty). Nothing else carries them: C_PlayerInfo.GetPlayerCharacterData is
-- name, race, sex and an icon; a display ID does not carry the choices
-- (forever-api-notes.md, the model findings); and the readout Blizzard's own
-- debug binding prints, GetDebugTargetCustomizationInfo, is in no Forever dump.
--
-- So the look is recorded when the chair opens - before anything is previewed,
-- so it is the look the character has - and again when a change is paid for.
-- Sitting down and getting up costs nothing. A character never changed at a
-- barber shows exactly what was picked at creation.
--
-- ONE STRING field on the character record, so it rides sync like any other:
-- SerializeChar skips tables, and a table here would never leave this account.
-- A peer on an older build stores and resends an unknown field unchanged, so
-- the wire format is untouched and there is no protocol bump. Deliberately NOT
-- in ClearSyncedStateFields: a record without it says nothing about the look,
-- and the last one recorded still is the look.
--
--   look   = "1;" .. option .. ";" .. option ...     (the barber's own order)
--   option = optionID~optionName~number~choiceID~choiceName~swatchHex
--
-- The number is what the barber always shows next to a choice, and the name or
-- the colour swatch is what it shows when the choice has one. The ids are what
-- C_BarberShop.SetCustomizationChoice takes, kept for a barber profile that
-- puts a look back. Names are stored because nothing outside the chair can
-- turn an id into one. `lookAt` is when the look last changed.
------------------------------------------------------------

AltStable = AltStable or {}

local LOOK_FORMAT = "1"

-- The two separators, and | - the client's escape character: a name carrying
-- one would cut a field short, or print as a colour code.
local function Clean(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[;~|\r\n]", ""))
end

-- The choice's colour swatch (a ColorMixin, 0..1 channels) as "rrggbb".
local function Hex(color)
    if type(color) ~= "table" then return "" end
    local r, g, b = tonumber(color.r), tonumber(color.g), tonumber(color.b)
    if not (r and g and b) then return "" end
    local function byte(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
    return string.format("%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- GetAvailableCustomizations' categories -> the stored string, or nil when
-- there is nothing to read (outside the chair the call returns nothing).
-- An option is listed once even if two categories carry it.
function AltStable.EncodeLook(categories)
    if type(categories) ~= "table" then return nil end
    local parts, seen = { LOOK_FORMAT }, {}
    for _, cat in ipairs(categories) do
        local options = type(cat) == "table" and type(cat.options) == "table" and cat.options or {}
        for _, opt in ipairs(options) do
            -- currentChoiceIndex is a Lua index into choices, and nilable.
            local idx = type(opt) == "table" and tonumber(opt.currentChoiceIndex)
            local choice = idx and type(opt.choices) == "table" and opt.choices[idx]
            if type(choice) == "table" and opt.id and not seen[opt.id] then
                seen[opt.id] = true
                parts[#parts + 1] = table.concat({
                    tostring(opt.id), Clean(opt.name), tostring(idx),
                    tostring(choice.id or ""), Clean(choice.name), Hex(choice.swatchColor1),
                }, "~")
            end
        end
    end
    if #parts == 1 then return nil end
    return table.concat(parts, ";")
end

-- The stored string -> { { optionID, option, number, choiceID, choice, swatch } ... },
-- or nil for nothing, or for a format this build cannot read.
function AltStable.DecodeLook(s)
    if type(s) ~= "string" then return nil end
    local out, first = {}, true
    for part in s:gmatch("[^;]+") do
        if first then
            if part ~= LOOK_FORMAT then return nil end
            first = false
        else
            -- Appending the separator is what lets an EMPTY field match:
            -- "[^~]+" would skip it and shift every field after it.
            local f = {}
            for v in (part .. "~"):gmatch("([^~]*)~") do f[#f + 1] = v end
            out[#out + 1] = {
                optionID = tonumber(f[1]), option   = f[2] or "",
                number   = tonumber(f[3]), choiceID = tonumber(f[4]),
                choice   = f[5] or "",     swatch   = (f[6] or "") ~= "" and f[6] or nil,
            }
        end
    end
    if first or #out == 0 then return nil end
    return out
end

-- "none", "newer" (recorded by a build whose format this one cannot read), or
-- "ok". What the menu entry offers depends on it.
function AltStable.CharacterLookState(char)
    local look = type(char) == "table" and char.look
    if type(look) ~= "string" or look == "" then return "none" end
    return AltStable.DecodeLook(look) and "ok" or "newer"
end

------------------------------------------------------------
-- Recording
------------------------------------------------------------

local function ReadLook()
    if not (C_BarberShop and C_BarberShop.GetAvailableCustomizations) then return nil end
    local ok, categories = pcall(C_BarberShop.GetAvailableCustomizations)
    return ok and AltStable.EncodeLook(categories) or nil
end

-- Writes the look onto the character being played. Nothing readable leaves
-- what was recorded alone; the same look is not a change, so it neither
-- re-stamps the record nor wakes the delta sync.
local function StoreLook(look)
    if not look then return false end
    local guid = UnitGUID and UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    if not char or char.look == look then return false end
    local first = char.look == nil
    char.look = look
    char.lookAt = time()
    char.lastUpdate = time()
    if AltStable.Print then
        local name = char.name or "this character"
        if first then
            AltStable.Print("Recorded " .. name .. "'s look. Right-click them in AltStable"
                .. " and choose Appearance to see it.")
        else
            AltStable.Print("Recorded " .. name .. "'s new look.")
        end
    end
    return true
end

-- Read when the change is SENT, kept, and written only once the barber says it
-- was applied. The applied event alone is not enough: Blizzard's barber answers
-- it by cancelling, which tears the chair down, and whether that runs before
-- this handler is down to frame order. Read at the send, the choices are still
-- the previewed ones, which is what was bought.
local pending

local function OnApplySent()
    pending = ReadLook()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("BARBER_SHOP_OPEN")
frame:RegisterEvent("BARBER_SHOP_APPEARANCE_APPLIED")
frame:RegisterEvent("BARBER_SHOP_CLOSE")
frame:SetScript("OnEvent", function(_, event)
    if event == "BARBER_SHOP_OPEN" then
        pending = nil
        StoreLook(ReadLook())
    elseif event == "BARBER_SHOP_APPEARANCE_APPLIED" then
        StoreLook(ReadLook() or pending)
        pending = nil
    else
        -- Got up without paying: previews are not a look.
        pending = nil
    end
end)

if C_BarberShop and type(C_BarberShop.ApplyCustomizationChoices) == "function" then
    hooksecurefunc(C_BarberShop, "ApplyCustomizationChoices", OnApplySent)
end

------------------------------------------------------------
-- Showing it
------------------------------------------------------------

-- The texture escape draws a white square in the swatch's colour.
local function Swatch(hex)
    local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    if not (r and g and b) then return "" end
    return string.format("  |TInterface\\Buttons\\WHITE8X8:12:12:0:0:8:8:0:8:0:8:%d:%d:%d|t", r, g, b)
end

-- The panel's text, frame-free so a test can read it. One line per option, as
-- the barber has them: the number always, then the name or the swatch.
function AltStable.CharacterLookText(char)
    local list = type(char) == "table" and AltStable.DecodeLook(char.look)
    if not list then return nil end
    local lines = {
        (AltStable.ClassColor and AltStable.ClassColor(char.class) or "") .. (char.name or "?") .. "|r",
        "",
    }
    -- The labels in the accent, which is Glass UI's while AltStable follows
    -- the suite (Theme.lua), so the panel matches the windows around it.
    local accent = "|cffffd100"
    if AltStable.GetAccentRGB and AltStable.HexColor then
        local r, g, b = AltStable.GetAccentRGB()
        if r then accent = AltStable.HexColor({ r, g, b }) end
    end
    for _, o in ipairs(list) do
        local label = o.option ~= "" and o.option or ("Option " .. tostring(o.optionID or "?"))
        local line = accent .. label .. ":|r " .. tostring(o.number or "?")
        if o.choice ~= "" then line = line .. "  " .. o.choice end
        if o.swatch then line = line .. Swatch(o.swatch) end
        lines[#lines + 1] = line
    end
    if char.lookAt and type(date) == "function" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff888888Recorded at a barber on " .. date("%Y-%m-%d", char.lookAt) .. "|r"
    end
    return table.concat(lines, "\n")
end

function AltStable.ShowCharacterLook(char)
    local text = AltStable.CharacterLookText(char)
    if not text or not AltStable.ShowPrompt then return false end
    AltStable.ShowPrompt("Look", { text = text, justify = "LEFT" })
    return true
end

AltStable._test = AltStable._test or {}
AltStable._test.LookFrame = function() return frame end
