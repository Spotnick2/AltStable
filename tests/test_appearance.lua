------------------------------------------------------------
-- test_appearance.lua — each character's look, recorded at the barber
--
-- The look is readable only while the barber's chair is open (Appearance.lua
-- has the measurement), so what is tested is WHEN it is recorded - opening the
-- chair, paying for a change, not previews abandoned - that it survives the
-- sync wire as the string it was written as, and what the menu and the panel
-- make of it.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("Appearance.lua")
dofile("SheetUI.lua")
dofile("PublicAPI.lua")

AltStable.EnsureConfigDefaults()

local T = AltStable._test

-- Shaped like CharCustomizationCategory (the 70450 dump): options carry a
-- Lua-index currentChoiceIndex into their choices, and a choice's swatch is a
-- ColorMixin with 0..1 channels.
local function Chair()
    return {
        { id = 1, name = "Body", options = {
            { id = 10, name = "Skin Color", currentChoiceIndex = 2, choices = {
                { id = 100, name = "" , swatchColor1 = { r = 0, g = 0, b = 1 } },
                { id = 101, name = "" , swatchColor1 = { r = 1, g = 0, b = 0 } },
            } },
            { id = 11, name = "Face", currentChoiceIndex = 4, choices = {
                { id = 110, name = "" }, { id = 111, name = "" },
                { id = 112, name = "" }, { id = 113, name = "" },
            } },
        } },
        { id = 2, name = "Hair", options = {
            { id = 12, name = "Hair Style", currentChoiceIndex = 1, choices = {
                { id = 120, name = "Mohawk" }, { id = 121, name = "Braids" },
            } },
            -- Two categories carrying one option: listed once.
            { id = 11, name = "Face", currentChoiceIndex = 1, choices = { { id = 110, name = "" } } },
        } },
    }
end

local function OptionOf(list, optionID)
    for _, o in ipairs(list or {}) do if o.optionID == optionID then return o end end
end

------------------------------------------------------------
-- The stored string
------------------------------------------------------------

eq("nothing to read is no look", AltStable.EncodeLook(nil), nil)
eq("  and neither is an empty chair", AltStable.EncodeLook({}), nil)

do
    local look = AltStable.EncodeLook(Chair())
    check("a look is a string in format 1", type(look) == "string" and look:sub(1, 2) == "1;", look)
    local list = AltStable.DecodeLook(look)
    eq("each option once, in the barber's order", list and #list, 3)
    eq("  first the skin colour", list and list[1].optionID, 10)
    local face = OptionOf(list, 11)
    eq("the number is the barber's", face and face.number, 4)
    eq("  the choice id is kept for putting it back", face and face.choiceID, 113)
    eq("  a choice with no name decodes as empty", face and face.choice, "")
    eq("  and no swatch as none", face and face.swatch, nil)
    eq("a named choice keeps its name", OptionOf(list, 12).choice, "Mohawk")
    eq("a swatch keeps its colour", OptionOf(list, 10).swatch, "ff0000")
end

do
    -- An option with no current choice says nothing about the look.
    local chair = Chair()
    chair[1].options[2].currentChoiceIndex = nil
    chair[2].options[2].currentChoiceIndex = nil    -- its copy in the other category
    eq("an option with no current choice is skipped",
       OptionOf(AltStable.DecodeLook(AltStable.EncodeLook(chair)), 11), nil)
end

do
    -- The separators and the client's escape character, inside a name.
    local chair = Chair()
    chair[2].options[1].name = "Hair;Sty~le|"
    chair[2].options[1].choices[1].name = "Mo;hawk~|cff"
    local list = AltStable.DecodeLook(AltStable.EncodeLook(chair))
    eq("a name cannot break the fields", list and #list, 3)
    eq("  the option name comes back clean", OptionOf(list, 12).option, "HairStyle")
    eq("  and the choice name", OptionOf(list, 12).choice, "Mohawkcff")
end

eq("a format this build cannot read is not decoded", AltStable.DecodeLook("2;10~Skin~1~100~~"), nil)
eq("  and says so", AltStable.CharacterLookState({ look = "2;10~Skin~1~100~~" }), "newer")
eq("no look says none", AltStable.CharacterLookState({}), "none")

------------------------------------------------------------
-- Recording, at the chair
------------------------------------------------------------

local GUID = WoW.player.guid
AltStableDB[GUID] = { guid = GUID, name = "Player", class = "MAGE", realm = "R", level = 60,
                      lastUpdate = 1, scannedHere = true }
local ME = AltStableDB[GUID]
local frame = T.LookFrame()
local function Fire(event) frame:GetScript("OnEvent")(frame, event) end

WoW.now = 5000
WoW.barber = nil
Fire("BARBER_SHOP_OPEN")
eq("nothing readable records nothing", ME.look, nil)
eq("  and does not stamp the record", ME.lastUpdate, 1)

WoW.chatOut = {}
WoW.barber = Chair()
Fire("BARBER_SHOP_OPEN")
check("opening the chair records the look", AltStable.CharacterLookState(ME) == "ok", tostring(ME.look))
eq("  stamped when it was recorded", ME.lookAt, 5000)
eq("  and the record, so the next delta sync carries it", ME.lastUpdate, 5000)
check("  and the player is told where to see it",
      (WoW.chatOut[1] or ""):find("Appearance", 1, true) ~= nil, tostring(WoW.chatOut[1]))
local recorded = ME.look

WoW.now = 6000
Fire("BARBER_SHOP_OPEN")
eq("the same look again is not a change", ME.lastUpdate, 5000)

-- Previewing then getting up: previews are not a look.
C_BarberShop.SetCustomizationChoice(11, 111)
Fire("BARBER_SHOP_CLOSE")
WoW.barber = nil
eq("previews abandoned leave the look alone", ME.look, recorded)

-- Paying for a change. Blizzard's barber answers the applied event by
-- cancelling, which tears the chair down - so the read at the event finds
-- nothing, and the look has to come from when the change was sent.
WoW.barber = Chair()
Fire("BARBER_SHOP_OPEN")
C_BarberShop.SetCustomizationChoice(11, 111)
C_BarberShop.ApplyCustomizationChoices()
WoW.barber = nil
WoW.now = 7000
Fire("BARBER_SHOP_APPEARANCE_APPLIED")
eq("a change paid for is recorded", OptionOf(AltStable.DecodeLook(ME.look), 11).number, 2)
eq("  and stamped", ME.lookAt, 7000)

------------------------------------------------------------
-- The wire
------------------------------------------------------------

do
    local blob = T.SerializeChar(ME, 0)
    check("the look rides sync", blob:find("\nlook:1;", 1, true) ~= nil or blob:find("^look:1;") ~= nil)
    local back = T.DeserializeChar(blob)
    eq("  and arrives as the string it was", back and back.look, ME.look)
    eq("  with its stamp", back and back.lookAt, ME.lookAt)
end

------------------------------------------------------------
-- The menu and the panel
------------------------------------------------------------

local function LookEntry(char)
    for _, e in ipairs(AltStable.CharacterMenuEntries(char)) do
        if e.id == "look" then return e end
    end
end

do
    local OTHER = { guid = "other", name = "Someone", class = "ROGUE" }
    local e = LookEntry(OTHER)
    check("a character with no look still lists Appearance", e ~= nil)
    check("  disabled", e and e.disabled == true)
    check("  and says how to record one", e and (e.why or ""):find("barber", 1, true) ~= nil,
          e and e.why)
    eq("  choosing it anyway shows nothing", AltStable.CharacterMenuInvoke("look", OTHER), false)

    OTHER.look = "2;10~Skin~1~100~~"
    e = LookEntry(OTHER)
    check("a look from a newer build is disabled", e and e.disabled == true)
    check("  and says to update", e and (e.why or ""):find("newer", 1, true) ~= nil, e and e.why)
end

do
    local e = LookEntry(ME)
    check("a recorded look can be chosen", e and not e.disabled)
    check("choosing it shows the panel", AltStable.CharacterMenuInvoke("look", ME))
    local f = T.Prompt("Look")
    check("  it is up", f and f:IsShown())
    local text = f and f.text:GetText() or ""
    check("  listing each option with its number", text:find("Face:|r 2", 1, true) ~= nil, text)
    check("  the choice's name when it has one", text:find("1  Mohawk", 1, true) ~= nil, text)
    check("  the swatch in its colour", text:find(":255:0:0|t", 1, true) ~= nil, text)
    check("  and when it was recorded", text:find("Recorded at a barber on", 1, true) ~= nil, text)
    eq("  as a list, not centred", f and f.text:GetJustifyH(), "LEFT")
    f:Hide()

    -- The same frame kind elsewhere is centred again: justify is per showing.
    AltStable.ShowPrompt("Look", { text = "x" })
    eq("a later showing without a list is centred", f.text:GetJustifyH(), "CENTER")
    f:Hide()
end

do
    -- No option name: the panel still says which option it is.
    local char = { guid = "g", name = "N", look = "1;42~~3~420~~" }
    local text = AltStable.CharacterLookText(char) or ""
    check("an unnamed option is named by its id", text:find("Option 42:|r 3", 1, true) ~= nil, text)
end

print(string.format("test_appearance: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
