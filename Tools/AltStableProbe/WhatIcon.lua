------------------------------------------------------------
-- WhatIcon.lua — name the texture under the cursor
--
-- "That icon would be better than ours" is a normal thing to notice and an
-- annoying thing to act on: a screenshot shows the art, not the path, and
-- guessing at Interface\Icons\ names from a picture is how you end up shipping
-- the green question mark.
--
-- /asicon  — hover something, run it, and it prints every texture and atlas in
-- the frame under the cursor, deepest first, with the file id beside each.
--
-- GetMouseFoci, plural: GetMouseFocus was removed in 11.0 and this client is
-- Mainline-derived, so the old single-return call is simply absent (see
-- docs/forever-api-notes.md on false friends). It returns a LIST, because more
-- than one frame can be under the pointer.
--
-- Textures name themselves three ways and a frame may use any of them:
--   GetAtlas()           a named slice of a sheet, e.g. "worldquest-icon"
--   GetTextureFilePath() the path, when the texture was set from one
--   GetTextureFileID()   a numeric id, which is all you get for an atlas or
--                        for art the client resolved to a file id internally
-- All three are reported, because the one you can reuse is whichever is not nil.
------------------------------------------------------------

local function Out(msg)
    print("|cff66ccff[icon]|r " .. msg)
end

-- Every texture region of a frame, described as usefully as the client allows.
local function DescribeRegions(frame, label)
    if not frame or type(frame.GetRegions) ~= "function" then return 0 end

    local found = 0
    for _, region in ipairs({ frame:GetRegions() }) do
        if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            local atlas = region.GetAtlas and region:GetAtlas() or nil
            local path  = region.GetTextureFilePath and region:GetTextureFilePath() or nil
            local id    = region.GetTextureFileID and region:GetTextureFileID() or nil

            -- Skip the empty ones. A frame carries background and highlight
            -- layers that are set to nothing, and listing them buries the one
            -- texture that was asked about.
            if atlas or path or (id and id ~= 0) then
                found = found + 1
                local what = {}
                if path  then what[#what + 1] = "|cffffff00" .. path .. "|r" end
                if atlas then what[#what + 1] = "atlas |cff88ff88" .. atlas .. "|r" end
                if id and id ~= 0 and not path then
                    -- An id with no path is still reusable: SetTexture takes it.
                    what[#what + 1] = "fileID |cff88ff88" .. tostring(id) .. "|r"
                end
                local shown = region:IsShown() and "" or " |cff888888(hidden)|r"
                Out("  " .. label .. ": " .. table.concat(what, "  ") .. shown)
            end
        end
    end
    return found
end

local function WhatIsUnderTheCursor()
    if type(GetMouseFoci) ~= "function" then
        Out("|cffff8800GetMouseFoci is missing on this client.|r "
            .. "GetMouseFocus was removed in 11.0 and nothing replaced it here.")
        return
    end

    local foci = GetMouseFoci()
    if type(foci) ~= "table" or #foci == 0 then
        Out("nothing under the cursor. Hover the thing first, then run this - "
            .. "the command reads where the mouse is NOW.")
        return
    end

    local total = 0
    for i, frame in ipairs(foci) do
        local name = (frame.GetDebugName and frame:GetDebugName())
            or (frame.GetName and frame:GetName())
            or ("frame " .. i)
        Out("|cffffffff" .. name .. "|r")
        total = total + DescribeRegions(frame, "texture")

        -- Buttons keep their art in named fields rather than plain regions, so
        -- the loop above misses exactly the icons people ask about.
        for _, key in ipairs({ "icon", "Icon", "texture", "Texture", "NormalTexture" }) do
            local sub = frame[key]
            if type(sub) == "table" and sub.GetObjectType
               and sub:GetObjectType() == "Texture" then
                local path = sub.GetTextureFilePath and sub:GetTextureFilePath() or nil
                local atlas = sub.GetAtlas and sub:GetAtlas() or nil
                local id = sub.GetTextureFileID and sub:GetTextureFileID() or nil
                if path or atlas or (id and id ~= 0) then
                    total = total + 1
                    Out("  ." .. key .. ": " .. (path and ("|cffffff00" .. path .. "|r"))
                        or (atlas and ("atlas |cff88ff88" .. atlas .. "|r"))
                        or ("fileID |cff88ff88" .. tostring(id) .. "|r"))
                end
            end
        end
    end

    if total == 0 then
        Out("that frame draws no texture of its own - try a parent, or the art "
            .. "may be a child frame the pointer is not over.")
    end
end

SLASH_ASICON1 = "/asicon"
SlashCmdList["ASICON"] = function()
    WhatIsUnderTheCursor()
end

AltStableProbe = AltStableProbe or {}
AltStableProbe.WhatIcon = WhatIsUnderTheCursor
AltStableProbe._testIcon = {
    DescribeRegions = DescribeRegions,
    WhatIsUnderTheCursor = WhatIsUnderTheCursor,
}
