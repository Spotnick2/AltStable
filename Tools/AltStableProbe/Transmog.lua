----------------------------------------------------------------------------
-- /fp as transmog - what a slot SHOWS on Forever, not what is equipped (#485)
--
-- Measured by the Companion (71037): ShowingHelm() / ShowingCloak() return
-- false for a helm and cloak that the armory render and the game draw, on a
-- character that never visited a transmogrifier. On Forever a slot is hidden
-- by transmog, not by that toggle. Before AltStable records anything, per
-- visible slot:
--   * the equipped item (what gearid_<slot> stores) and ShowingHelm/Cloak;
--   * C_Transmog.GetSlotVisualInfo: base / applied source and visual ids, and
--     isHideVisual (the location from TransmogUtil, as Blizzard builds it);
--   * C_TransmogOutfitInfo's viewed slot: transmogID, displayType,
--     isTransmogrified (Retail 12's outfit system, in the 71037 dump);
--   * the applied source's item and name (C_TransmogCollection.GetSourceInfo),
--     and IsAppearanceHiddenVisual on its appearance;
--   * a DressUpModel on the player: GetItemTransmogInfo(slot), what is DRAWN;
--   * the tooltip's transmog lines (C_TooltipInfo.GetInventoryItem).
-- Three states: nothing transmogged, a slot transmogged to another look, a
-- slot hidden by transmog. /fp steps as transmog walks them.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe

local SLOTS = {
    { 1, "HEADSLOT" }, { 3, "SHOULDERSLOT" }, { 4, "SHIRTSLOT" }, { 5, "CHESTSLOT" },
    { 6, "WAISTSLOT" }, { 7, "LEGSSLOT" }, { 8, "FEETSLOT" }, { 9, "WRISTSLOT" },
    { 10, "HANDSSLOT" }, { 15, "BACKSLOT" }, { 16, "MAINHANDSLOT" }, { 17, "SECONDARYHANDSLOT" },
    { 19, "TABARDSLOT" },
}

local function Out(s) Probe:Say("[transmog] " .. s) end

-- A value as text, a secret said as one rather than read.
local function V(v)
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    if type(v) == "table" then
        local keys = {}
        for k, x in pairs(v) do
            if type(x) ~= "function" and type(x) ~= "table" then
                keys[#keys + 1] = tostring(k) .. "=" .. V(x)
            end
        end
        table.sort(keys)
        return "{" .. table.concat(keys, " ") .. "}"
    end
    return tostring(v)
end

-- A copy safe to save: plain fields only, secrets as a marker.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    if type(v) == "table" then
        local t = {}
        for k, x in pairs(v) do
            if type(x) ~= "function" then t[tostring(k)] = Plain(x) end
        end
        return t
    end
    if type(v) == "function" or type(v) == "userdata" then return type(v) end
    return v
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "absent" end
    return pcall(fn, ...)
end

-- A call's answer to save: the value (false included), or why there is none.
local function Got(ok, v, why)
    if ok then return Plain(v) end
    return why or ("error: " .. tostring(v))
end

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

local function DB()
    AltStableProbeDB.transmog = AltStableProbeDB.transmog or {}
    return AltStableProbeDB.transmog
end

-- TransmogUtil lives in Blizzard_TransmogShared, load-on-demand: load it once.
local function Util()
    local U = rawget(_G, "TransmogUtil")
    if type(U) ~= "table" or type(U.GetTransmogLocation) ~= "function" then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or rawget(_G, "LoadAddOn")
        if load then pcall(load, "Blizzard_TransmogShared") end
        U = rawget(_G, "TransmogUtil")
    end
    return type(U) == "table" and U or nil
end

local function Location(slot, name)
    local U = Util()
    local appearance = Enum and Enum.TransmogType and Enum.TransmogType.Appearance
    if not U then return nil, "no TransmogUtil" end
    local ok, loc = Try(U.GetTransmogLocation, name, appearance, false)
    if ok and loc then return loc, "GetTransmogLocation" end
    ok, loc = Try(U.CreateTransmogLocation, slot, appearance, false)
    if ok and loc then return loc, "CreateTransmogLocation" end
    return nil, "no location: " .. tostring(loc)
end

-- The tooltip's lines that speak of transmog (or of a hidden look).
local function TipLines(slot)
    local ok, data = Try(Api("C_TooltipInfo", "GetInventoryItem"), "player", slot)
    if not ok or type(data) ~= "table" then return { "tooltip: " .. tostring(data) } end
    local names = {}
    for k, v in pairs(Enum and Enum.TooltipDataLineType or {}) do names[v] = k end
    local found = {}
    for i, line in ipairs(data.lines or {}) do
        local text = line.leftText
        local tn = names[line.type] or "?"
        if (type(text) == "string" and (text:lower():find("transmog") or text:lower():find("hidden")))
            or tostring(tn):lower():find("transmog") then
            found[#found + 1] = ("%d %s %q"):format(i, tn, tostring(text))
        end
    end
    return found
end

local function ReadSlot(slot, name)
    local r = { slot = slot }
    r.itemID = GetInventoryItemID("player", slot)
    r.link = GetInventoryItemLink("player", slot)

    local loc, how = Location(slot, name)
    r.location = how
    if loc then
        local ok, info = Try(Api("C_Transmog", "GetSlotVisualInfo"), loc)
        r.slotVisual = Got(ok, info)
        if ok and type(info) == "table" then
            local src = info.appliedSourceID ~= 0 and info.appliedSourceID or info.baseSourceID
            r.shownSource = src
            local ok2, si = Try(Api("C_TransmogCollection", "GetSourceInfo"), src)
            r.sourceInfo = Got(ok2, si)
            if ok2 and type(si) == "table" and si.visualID then
                local ok3, hidden = Try(Api("C_TransmogCollection", "IsAppearanceHiddenVisual"), si.visualID)
                r.isHiddenVisual = Got(ok3, hidden)
            end
        end
    end

    -- Retail 12's outfit system, if Forever wires it.
    local ok, oslot = Try(Api("C_TransmogOutfitInfo", "GetTransmogOutfitSlotFromInventorySlot"), slot - 1)
    if ok and oslot ~= nil then
        r.outfitSlot = Plain(oslot)
        local okO, option = Try(Api("C_TransmogOutfitInfo", "GetEquippedSlotOptionFromTransmogSlot"), oslot)
        r.outfitOption = Got(okO, option)
        local appearance = Enum and Enum.TransmogType and Enum.TransmogType.Appearance
        local okV, viewed = Try(Api("C_TransmogOutfitInfo", "GetViewedOutfitSlotInfo"), oslot, appearance,
                                okO and option or 0)
        r.outfitViewed = Got(okV, viewed)
    else
        r.outfitSlot = "error: " .. tostring(oslot)
    end

    r.tooltip = TipLines(slot)
    return r
end

-- A DressUpModel on the player: what the game DRAWS per slot. It needs a frame
-- that is shown and a moment to load, so it is read a little after.
local model
local function ReadModel(rec, done)
    if not model then
        model = CreateFrame("DressUpModel", nil, UIParent)
        model:SetSize(120, 160)
        model:SetPoint("BOTTOMLEFT", 8, 8)
    end
    model:Show()
    local ok, err = pcall(model.SetUnit, model, "player")
    if not ok then rec.model = "SetUnit error: " .. tostring(err); model:Hide(); if done then done() end; return end
    C_Timer.After(2, function()
        rec.model = {}
        for _, s in ipairs(SLOTS) do
            local okI, info = pcall(model.GetItemTransmogInfo, model, s[1])
            rec.model[tostring(s[1])] = Got(okI, info)
        end
        model:Hide()
        local hs = rec.slots and rec.slots["1"]
        Out(("model read: head %s, back %s"):format(V(rec.model["1"]), V(rec.model["15"])))
        if done then done(hs) end
    end)
end

local function Read(label)
    local name = UnitName("player")
    local rec = {
        label = label, char = name, at = date("%Y-%m-%d %H:%M:%S"),
        build = select(2, GetBuildInfo()),
        uptime = GetTime(),
    }
    local okH, sh = Try(rawget(_G, "ShowingHelm"))
    local okC, sc = Try(rawget(_G, "ShowingCloak"))
    rec.showingHelm = Got(okH, sh, "absent")
    rec.showingCloak = Got(okC, sc, "absent")
    local okA, outfit = Try(Api("C_TransmogOutfitInfo", "GetActiveOutfitID"))
    rec.activeOutfit = Got(okA, outfit)
    local okN, atNPC = Try(Api("C_Transmog", "IsAtTransmogNPC"))
    rec.atNPC = Got(okN, atNPC)
    rec.displayTypes = Enum and Plain(Enum.TransmogOutfitDisplayType) or "absent"

    Out(("%s - %s (build %s): ShowingHelm %s, ShowingCloak %s, outfit %s"):format(
        label, tostring(name), tostring(rec.build), V(rec.showingHelm), V(rec.showingCloak), V(rec.activeOutfit)))
    rec.slots = {}
    for _, s in ipairs(SLOTS) do
        local okS, r = pcall(ReadSlot, s[1], s[2])
        if not okS then r = { error = tostring(r) } end
        rec.slots[tostring(s[1])] = r
        if okS and r.itemID then
            local sv = type(r.slotVisual) == "table" and r.slotVisual or {}
            local si = type(r.sourceInfo) == "table" and r.sourceInfo or {}
            local ov = type(r.outfitViewed) == "table" and r.outfitViewed or {}
            Out(("  %s item %s | base %s/%s applied %s/%s hide %s | shown %s %q | outfit id %s type %s tmog %s | tip %s"):format(
                s[2], tostring(r.itemID), V(sv.baseSourceID), V(sv.baseVisualID), V(sv.appliedSourceID),
                V(sv.appliedVisualID), V(sv.isHideVisual), V(si.itemID), tostring(si.name or ""),
                V(ov.transmogID), V(ov.displayType), V(ov.isTransmogrified),
                table.concat(r.tooltip or {}, " / ")))
            if type(r.slotVisual) ~= "table" then Out("    slot visual: " .. V(r.slotVisual) .. " (" .. tostring(r.location) .. ")") end
        elseif okS then
            Out("  " .. s[2] .. " empty")
        else
            Out("  " .. s[2] .. " ERROR " .. r.error)
        end
    end
    local t = DB()
    t[#t + 1] = rec
    ReadModel(rec)
    return rec
end

local function Latest(label)
    local t = DB()
    for i = #t, 1, -1 do
        if t[i].label == label and t[i].char == UnitName("player") then return t[i] end
    end
end

-- The head and back, as each reader sees them, in one line.
local function Summary(rec)
    if not rec then return "no reading" end
    local function slot(n)
        local r = rec.slots and rec.slots[n] or {}
        local sv = type(r.slotVisual) == "table" and r.slotVisual or {}
        local m = type(rec.model) == "table" and rec.model[n] or nil
        return ("item %s applied %s hide %s model %s"):format(tostring(r.itemID), V(sv.appliedSourceID),
            V(sv.isHideVisual), type(m) == "table" and V(m.appearanceID) or tostring(m))
    end
    return ("ShowingHelm %s ShowingCloak %s | head: %s | back: %s"):format(
        V(rec.showingHelm), V(rec.showingCloak), slot("1"), slot("15"))
end

Probe:Command("transmog", function(arg) Read(arg ~= "" and arg or "manual") end,
    "what each slot SHOWS: transmog, hidden, the model (#485)")

Probe:Steps("transmog", {
    title = "What a slot shows on Forever: transmog and hidden gear (#485)",
    { text = "Wear a helm and a cloak. Reading every slot as it is now: ShowingHelm / ShowingCloak, "
          .. "the transmog slot info, the outfit info, the tooltip, and a model of you (bottom left, 2 s).",
      auto = true,
      run = function() Read("as is"); return true end,
      check = function()
          local r = Latest("as is")
          return r ~= nil, Summary(r)
      end },
    { text = "Open your character window (C). Are the helm and the cloak DRAWN on your character? "
          .. "(Type in the note what you see.)",
      ask = true, screenshot = "character window, as is" },
    { text = "Go to a transmogrifier. Transmogrify ONE slot (shoulders, say) to another look, and HIDE the "
          .. "helm with the hidden appearance. Apply both. Stay at the NPC, then press Run.",
      button = "Run",
      run = function() Read("transmogged"); return true end,
      check = function()
          local r = Latest("transmogged")
          return r ~= nil, Summary(r)
      end },
    { text = "Close the transmog window and open your character window (C). Is the helm hidden and the "
          .. "shoulder showing its new look?",
      ask = true, screenshot = "character window, transmogged" },
    { text = "Type /reload (or press Reload now): the same reading after a reload, away from the NPC.",
      reload = true },
    { text = "Wait 10 s after the reload, then press Run.",
      button = "Run",
      run = function() Read("after reload"); return true end,
      check = function()
          local r = Latest("after reload")
          return r ~= nil, Summary(r)
      end },
    { text = "Done. Undo the transmog at the NPC if you like. Type /reload now to save the results.",
      reload = true },
})

----------------------------------------------------------------------------
-- /fp steps as drawn - the second pass (#485), after /fp steps as transmog
-- found (71091) that only a DressUpModel's GetItemTransmogInfo reads the drawn
-- look: the base source untransmogged, the applied one transmogged, 77344 for
-- a hidden helm. Before AltStable reads it the same way:
--   * what each drawn id IS: GetSourceInfo (item, name, isHideVisual) and
--     IsAppearanceHiddenVisual on its visual, for the helm, the cloak and a
--     transmogged slot;
--   * how the model must be set up: shown on screen, shown 1x1 at alpha 0
--     (Scanner.lua's model-path frame), or never shown; read at once and
--     0.1 / 0.5 / 1 / 2 s after SetUnit;
--   * which events fire when a transmog is applied or undone.
----------------------------------------------------------------------------

local VARIANTS = { "shown", "alpha0", "hidden" }
local DELAYS = { 0, 0.1, 0.5, 1, 2 }
local LOOK = { 1, 3, 15 } -- head, shoulder, back: the slots the summary names

local function DrawnDB()
    AltStableProbeDB.transmogDrawn = AltStableProbeDB.transmogDrawn or {}
    return AltStableProbeDB.transmogDrawn
end

local Drawn = {}

function Drawn.MakeModel(kind)
    local m = CreateFrame("DressUpModel", nil, UIParent)
    if kind == "shown" then
        m:SetSize(120, 160)
        m:SetPoint("BOTTOMLEFT", 136, 8)
    else
        m:SetSize(1, 1)
        m:SetPoint("TOPLEFT", 0, 0)
    end
    return m
end

local models = {}
local function VariantModel(kind)
    local m = models[kind]
    if not m then m = Drawn.MakeModel(kind); models[kind] = m end
    if kind == "hidden" then m:Hide() else m:Show() end
    if m.SetAlpha then m:SetAlpha(kind == "alpha0" and 0 or 1) end
    return m
end

-- Every slot's drawn id now, from one model.
local function Snap(m)
    local row = {}
    for _, s in ipairs(SLOTS) do
        local ok, info = pcall(m.GetItemTransmogInfo, m, s[1])
        if ok and type(info) == "table" then
            row[tostring(s[1])] = info.appearanceID
        else
            row[tostring(s[1])] = Got(ok, info)
        end
    end
    return row
end

-- What a drawn source id is.
local function Source(id)
    local e = {}
    local ok, si = Try(Api("C_TransmogCollection", "GetSourceInfo"), id)
    e.info = Got(ok, si)
    if ok and type(si) == "table" and si.visualID then
        local okH, hidden = Try(Api("C_TransmogCollection", "IsAppearanceHiddenVisual"), si.visualID)
        e.hiddenVisual = Got(okH, hidden)
    end
    return e
end

local function LatestDrawn(label)
    local t = DrawnDB()
    for i = #t, 1, -1 do
        if t[i].label == label and t[i].char == UnitName("player") then return t[i] end
    end
end

-- Head, shoulder and back in one line: the drawn id per setup (at once / 2 s),
-- and what the shown model's id is.
local function DrawnSummary(rec)
    if not rec then return "no reading" end
    if not rec.done then return "still reading" end
    local parts = {}
    for _, slot in ipairs(LOOK) do
        local k = tostring(slot)
        local per = {}
        for _, kind in ipairs(VARIANTS) do
            local v = rec.variants[kind] or {}
            per[#per + 1] = ("%s %s/%s"):format(kind, V((v.t0 or {})[k]), V((v.t2 or {})[k]))
        end
        local id = (rec.variants.shown and rec.variants.shown.t2 or {})[k]
        local src = type(id) == "number" and rec.sources[tostring(id)] or nil
        local si = src and type(src.info) == "table" and src.info or {}
        parts[#parts + 1] = ("%d: equipped %s | %s | drawn item %s %q hide %s/%s"):format(slot,
            tostring(rec.equipped[k]), table.concat(per, " "), V(si.itemID), tostring(si.name or ""),
            V(si.isHideVisual), V(src and src.hiddenVisual))
    end
    return table.concat(parts, " || ")
end

function Drawn.Read(label)
    local rec = {
        label = label, char = UnitName("player"), at = date("%Y-%m-%d %H:%M:%S"),
        build = select(2, GetBuildInfo()), uptime = GetTime(),
        variants = {}, sources = {}, equipped = {},
    }
    local t = DrawnDB()
    t[#t + 1] = rec
    for _, s in ipairs(SLOTS) do rec.equipped[tostring(s[1])] = GetInventoryItemID("player", s[1]) end
    for _, kind in ipairs(VARIANTS) do
        local m = VariantModel(kind)
        local ok, err = pcall(m.SetUnit, m, "player")
        local v = { setUnit = ok and true or tostring(err) }
        rec.variants[kind] = v
        if ok then
            for _, d in ipairs(DELAYS) do
                local key = "t" .. d
                if d == 0 then v[key] = Snap(m) else C_Timer.After(d, function() v[key] = Snap(m) end) end
            end
        end
    end
    C_Timer.After(2.5, function()
        for _, kind in ipairs(VARIANTS) do
            for _, row in pairs(rec.variants[kind]) do
                if type(row) == "table" then
                    for _, id in pairs(row) do
                        if type(id) == "number" and id > 0 and not rec.sources[tostring(id)] then
                            rec.sources[tostring(id)] = Source(id)
                        end
                    end
                end
            end
        end
        for _, m in pairs(models) do m:Hide() end
        rec.done = true
        Out(label .. ": " .. DrawnSummary(rec))
    end)
    return rec
end

-- The events around a transmog, kept from load: what AltStable could listen to.
Drawn.EVENTS = {
    "TRANSMOGRIFY_SUCCESS", "TRANSMOGRIFY_UPDATE", "TRANSMOGRIFY_ITEM_UPDATE", "TRANSMOGRIFY_OPEN",
    "TRANSMOGRIFY_CLOSE", "TRANSMOG_OUTFITS_CHANGED", "TRANSMOG_DISPLAYED_OUTFIT_CHANGED",
    "VIEWED_TRANSMOG_OUTFIT_CHANGED", "VIEWED_TRANSMOG_OUTFIT_SLOT_SAVE_SUCCESS",
    "VIEWED_TRANSMOG_OUTFIT_SLOT_REFRESH", "PLAYER_EQUIPMENT_CHANGED", "UNIT_MODEL_CHANGED",
    "UNIT_INVENTORY_CHANGED",
}
Drawn.watched = {}

function Drawn.OnEvent(_, event, ...)
    if (event == "UNIT_MODEL_CHANGED" or event == "UNIT_INVENTORY_CHANGED") and ... ~= "player" then return end
    AltStableProbeDB.transmogEvents = AltStableProbeDB.transmogEvents or {}
    local log = AltStableProbeDB.transmogEvents
    local args = {}
    for i = 1, select("#", ...) do args[i] = V((select(i, ...))) end
    log[#log + 1] = ("%.1f %s %s"):format(GetTime(), event, table.concat(args, " "))
    while #log > 300 do table.remove(log, 1) end
end

do
    local f = CreateFrame("Frame")
    for _, e in ipairs(Drawn.EVENTS) do
        if pcall(f.RegisterEvent, f, e) then Drawn.watched[#Drawn.watched + 1] = e end
    end
    f:SetScript("OnEvent", Drawn.OnEvent)
end

local function Waited(label)
    return function()
        local r = LatestDrawn(label)
        if r and r.done then return true, DrawnSummary(r) end
        return false, "reading the models"
    end
end

local function Checked(label)
    return function()
        local r = LatestDrawn(label)
        return r ~= nil and r.done == true, DrawnSummary(r)
    end
end

Probe:Command("drawn", function(arg) Drawn.Read(arg ~= "" and arg or "manual") end,
    "what each slot is DRAWN as, three model setups, and the source behind it (#485)")

Probe:Steps("drawn", {
    title = "What a slot is drawn as: the ids, the model setup, the events (#485)",
    { text = "Wear a helm and a cloak. Reading what is drawn now, from three models: one shown (bottom "
          .. "left), one 1x1 at alpha 0, one hidden. About 3 s.",
      auto = true,
      run = function() Drawn.Read("now"); return true end },
    { text = "Reading the models...",
      wait = Waited("now"), timeout = 10, check = Checked("now") },
    { text = "Go to a transmogrifier. HIDE the helm and HIDE the cloak, and transmogrify the shoulders to "
          .. "another look. Apply, close the transmog window, then press Run.",
      button = "Run",
      run = function() Drawn.Read("hidden"); return true end },
    { text = "Reading the models...",
      wait = Waited("hidden"), timeout = 10, check = Checked("hidden") },
    { text = "Back at the transmogrifier, SHOW the helm and the cloak again (their own look). Apply, close "
          .. "the window, then press Run.",
      button = "Run",
      run = function() Drawn.Read("shown again"); return true end },
    { text = "Reading the models...",
      wait = Waited("shown again"), timeout = 10, check = Checked("shown again") },
    { text = "Done. Type /reload now to save the results.",
      reload = true },
})

-- The test seam, on the namespace, never on _G.
NS.transmog = { Read = Read, Summary = Summary, Latest = Latest, V = V, Plain = Plain,
                Drawn = Drawn, DrawnSummary = DrawnSummary, LatestDrawn = LatestDrawn }
