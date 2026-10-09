----------------------------------------------------------------------------
-- /asprobe enchant - where does the client say WHICH enchant a slot has? (#94)
--
-- gearmod_<slot> stores the enchant id from the item link; nothing maps that
-- id to words on this client (AltTracker's table was TBC data). The tooltip
-- already renders the words, and C_TooltipInfo.GetInventoryItem returns it
-- as STRUCTURED lines rather than text to scrape. To measure, per slot:
--   * the enchant id in the link (the field gearmod_ stores);
--   * every tooltip line: its type, its text and its colour - which line, if
--     any, Forever marks as the permanent enchant, and whether that type is
--     distinct from an ordinary green "Equip:" line;
--   * Enum.TooltipDataLineType's enchant-like members, if the enum exists.
-- Wear at least one enchanted item and one unenchanted one. A temporary
-- enchant (a poison, an oil) on a weapon is worth seeing too.
----------------------------------------------------------------------------

AltStableProbe = AltStableProbe or {}

local SLOTS = {
    { 1, "head" }, { 3, "shoulder" }, { 5, "chest" }, { 6, "waist" }, { 7, "legs" },
    { 8, "feet" }, { 9, "wrist" }, { 10, "hands" }, { 15, "back" },
    { 16, "mainhand" }, { 17, "offhand" }, { 18, "ranged" },
}

local function Color(c)
    if type(c) ~= "table" then return "-" end
    local r, g, b = c.r, c.g, c.b
    if type(c.GetRGB) == "function" then r, g, b = c:GetRGB() end
    if type(r) ~= "number" then return "?" end
    return ("%.2f,%.2f,%.2f"):format(r, g or 0, b or 0)
end

function AltStableProbe.Enchants()
    local out = {}
    local function add(s)
        out[#out + 1] = s
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[enchant]|r " .. s)
    end
    local version, build = GetBuildInfo()
    add(("client %s (%s)"):format(tostring(version), tostring(build)))

    -- The enum, if there is one: every member, and the enchant-like ones called out.
    local E = Enum and Enum.TooltipDataLineType
    if type(E) ~= "table" then
        add("Enum.TooltipDataLineType: ABSENT")
    else
        local names = {}
        for k, v in pairs(E) do names[#names + 1] = ("%s=%s"):format(tostring(k), tostring(v)) end
        table.sort(names)
        add("Enum.TooltipDataLineType: " .. table.concat(names, " "))
        for k, v in pairs(E) do
            if tostring(k):lower():find("enchant") then add(("  enchant-like: %s = %s"):format(k, tostring(v))) end
        end
    end

    local get = C_TooltipInfo and C_TooltipInfo.GetInventoryItem
    if type(get) ~= "function" then
        add("C_TooltipInfo.GetInventoryItem: ABSENT")
    end
    local typeName = {}
    for k, v in pairs(type(E) == "table" and E or {}) do typeName[v] = k end

    for _, s in ipairs(SLOTS) do
        local slot, key = s[1], s[2]
        local link = GetInventoryItemLink("player", slot)
        if link then
            local ench = link:match("item:%d+:(%-?%d*)")
            add(("|cffffd100%s|r (slot %d): link enchant field = %q  %s"):format(key, slot, ench or "?", link))
            if type(get) == "function" then
                local ok, data = pcall(get, "player", slot)
                if not ok then
                    add("  GetInventoryItem ERROR: " .. tostring(data))
                elseif type(data) ~= "table" then
                    add("  GetInventoryItem -> " .. type(data))
                else
                    local top = {}
                    for k in pairs(data) do top[#top + 1] = tostring(k) end
                    table.sort(top)
                    add("  data keys: " .. table.concat(top, ","))
                    for i, line in ipairs(data.lines or {}) do
                        local extra = {}
                        for k, v in pairs(line) do
                            if k ~= "leftText" and k ~= "leftColor" and k ~= "type"
                                and k ~= "rightText" and k ~= "rightColor" then
                                extra[#extra + 1] = tostring(k) .. "=" .. tostring(v)
                            end
                        end
                        table.sort(extra)
                        add(("  %2d type=%s(%s) %q [%s]%s%s"):format(i, tostring(line.type),
                            tostring(typeName[line.type] or "?"), tostring(line.leftText or ""),
                            Color(line.leftColor),
                            line.rightText and (" right=%q"):format(line.rightText) or "",
                            #extra > 0 and ("  {" .. table.concat(extra, " ") .. "}") or ""))
                    end
                end
            end
        else
            add(("%s (slot %d): empty"):format(key, slot))
        end
    end

    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.enchants = out
    if AltStableProbe.ShowCopy then AltStableProbe.ShowCopy(out) end
end
