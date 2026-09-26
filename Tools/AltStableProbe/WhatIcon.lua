------------------------------------------------------------
-- WhatIcon.lua — name the texture under the cursor
--
-- "That icon would be better than ours" is a normal thing to notice and an
-- annoying thing to act on: a screenshot shows the art, not the path, and
-- guessing at Interface\Icons\ names from a picture is how you end up shipping
-- the green question mark.
--
-- /asicon        — counts down, then reads whatever the cursor is over
-- /asicon now    — reads immediately (for a keybind or a macro)
-- /asicon cancel — call off a pending read
--
-- THE COUNTDOWN IS THE POINT. The first version read the cursor the instant the
-- command ran, which sounds right and is useless: typing "/asicon" means being
-- at the chat box, so by the time it executes the pointer has left whatever you
-- wanted to identify. The first real use of it came back
-- "UI-HUD-ExperienceBar-Fill-Prediction" - the status bar behind the chat
-- frame, correctly identified and entirely beside the point.
--
-- So it waits, and you move the pointer onto the thing while it does. Same
-- reason the capture in Render.lua counts down before hiding the interface.
-- `now` is there for a keybind, which is the precise version of this: press it
-- while already hovering and there is nothing to wait for.
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

-- Everything a texture will tell us about itself, as one printable line - or
-- nil when it is an empty layer.
--
-- Built as a TABLE and concatenated, never as a chain of `or`. The first
-- version wrote the named-field case as
--     "..." .. (path and ("|cff.." .. path)) or (atlas and ...) or ...
-- and `..` binds tighter than `or`, so that concatenates nil the moment there
-- is no path - which is precisely the atlas-backed art this command exists to
-- identify. It threw before `or` could reach a fallback, aborting the whole
-- command. The same shape also printed only the FIRST answer, when the point is
-- to print all of them.
local function Describe(tex)
    if type(tex) ~= "table" or not tex.GetObjectType then return nil end
    if tex:GetObjectType() ~= "Texture" then return nil end

    local atlas = tex.GetAtlas and tex:GetAtlas() or nil
    local path  = tex.GetTextureFilePath and tex:GetTextureFilePath() or nil
    local id    = tex.GetTextureFileID and tex:GetTextureFileID() or nil

    -- Skip the empty ones. A frame carries background and highlight layers set
    -- to nothing, and listing them buries the one texture that was asked about.
    if not (atlas or path or (id and id ~= 0)) then return nil end

    local what = {}
    if path  then what[#what + 1] = "|cffffff00" .. path .. "|r" end
    if atlas then what[#what + 1] = "atlas |cff88ff88" .. atlas .. "|r" end
    if id and id ~= 0 and not path then
        -- An id with no path is still reusable: SetTexture takes it.
        what[#what + 1] = "fileID |cff88ff88" .. tostring(id) .. "|r"
    end
    if tex.IsShown and not tex:IsShown() then
        what[#what + 1] = "|cff888888(hidden)|r"
    end
    return table.concat(what, "  ")
end

-- Every texture region of a frame. `seen` records which texture objects have
-- already been reported, because a Button's icon is BOTH a region and a named
-- field, and printing it twice buries the answer exactly as an empty layer
-- would.
local function DescribeRegions(frame, label, seen, sink)
    if not frame or type(frame.GetRegions) ~= "function" then return 0 end
    seen, sink = seen or {}, sink or Out

    local found = 0
    for _, region in ipairs({ frame:GetRegions() }) do
        local line = not seen[region] and Describe(region) or nil
        if line then
            seen[region] = true
            found = found + 1
            sink("  " .. label .. ": " .. line)
        end
    end
    return found
end

-- Whatever GetMouseFoci returned, as a list of frames.
--
-- Told apart by SHAPE, not by type(). A widget IS a table with no array part,
-- so `type(foci) ~= "table"` cannot distinguish "a list of frames" from "one
-- frame, returned as the first of a tuple" - the struct-vs-tuple false friend
-- this whole probe suite exists to catch. Getting it wrong here would report
-- "nothing under the cursor" while the button is plainly hovered, and send the
-- player off to re-hover instead of showing the mismatch.
local function FociList(...)
    local n = select("#", ...)
    if n == 0 then return {}, "nothing" end

    local first = select(1, ...)
    if type(first) ~= "table" then return {}, "nothing" end

    -- A frame answers GetObjectType; a list does not.
    if first.GetObjectType then
        local out = {}
        for i = 1, n do out[#out + 1] = (select(i, ...)) end
        return out, "tuple"
    end
    return first, "list"
end

local function WhatIsUnderTheCursor(sink)
    sink = sink or Out
    if type(GetMouseFoci) ~= "function" then
        sink("|cffff8800GetMouseFoci is missing on this client.|r "
            .. "GetMouseFocus was removed in 11.0 and nothing replaced it here.")
        return {}
    end

    local foci, shape = FociList(GetMouseFoci())
    if shape == "tuple" then
        -- Worth saying out loud rather than quietly coping: the notes record
        -- this call as returning a list, and if it does not, they are wrong.
        sink("|cffff8800GetMouseFoci returned a tuple, not a list|r - "
            .. "docs/forever-api-notes.md says otherwise. Reading it as one anyway.")
    end
    if #foci == 0 then
        sink("nothing under the cursor. Hover the thing first, then run this - "
            .. "the command reads where the mouse is NOW.")
        return {}
    end

    local lines, total, seen = {}, 0, {}
    local function say(text)
        lines[#lines + 1] = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        sink(text)
    end

    for i, frame in ipairs(foci) do
        local name = (frame.GetDebugName and frame:GetDebugName())
            or (frame.GetName and frame:GetName())
            or ("frame " .. i)
        say("|cffffffff" .. name .. "|r")
        total = total + DescribeRegions(frame, "texture", seen, say)

        -- Buttons keep their art in named fields as well as regions. `seen`
        -- stops the same texture being printed twice.
        for _, key in ipairs({ "icon", "Icon", "texture", "Texture", "NormalTexture" }) do
            local sub = frame[key]
            if not seen[sub] then
                local line = Describe(sub)
                if line then
                    seen[sub] = true
                    total = total + 1
                    say("  ." .. key .. ": " .. line)
                end
            end
        end
    end

    if total == 0 then
        say("that frame draws no texture of its own - try a parent, or the art "
            .. "may be a child frame the pointer is not over.")
    elseif AltStableProbe and AltStableProbe.ShowCopy then
        -- Chat text is not selectable, and the answer is a path to be retyped
        -- exactly. Transcribing it by eye is the error this command exists to
        -- avoid, so it opens the copy window too.
        AltStableProbe.ShowCopy(lines)
    end

    return lines
end

local READ_DELAY = 5
local pendingRead

local function CancelRead()
    if not pendingRead then return false end
    pendingRead:Cancel()
    pendingRead = nil
    return true
end

local function ReadAfterDelay()
    -- Idempotent, like the capture countdown: five of these queued at once is
    -- how a countdown turns into a burst.
    if pendingRead then
        Out("already counting down - |cffffff00/asicon cancel|r to stop it")
        return
    end

    Out(("hover the thing now - reading in %ds. "):format(READ_DELAY)
        .. "|cffffff00/asicon cancel|r to stop, |cffffff00/asicon now|r to skip the wait.")

    local remaining = READ_DELAY
    pendingRead = C_Timer.NewTicker(1, function(ticker)
        remaining = remaining - 1
        if remaining > 0 then
            if remaining <= 3 then Out(tostring(remaining) .. "...") end
            return
        end
        ticker:Cancel()
        pendingRead = nil
        WhatIsUnderTheCursor()
    end)
end

SLASH_ASICON1 = "/asicon"
SlashCmdList["ASICON"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "cancel" then
        if not CancelRead() then Out("nothing counting down") end
        return
    end
    if msg == "now" then
        WhatIsUnderTheCursor()
        return
    end
    if msg ~= "" then
        Out("usage: |cffffff00/asicon|r, |cffffff00/asicon now|r, |cffffff00/asicon cancel|r")
        return
    end
    ReadAfterDelay()
end

AltStableProbe = AltStableProbe or {}
AltStableProbe.WhatIcon = WhatIsUnderTheCursor
AltStableProbe._testIcon = {
    READ_DELAY = READ_DELAY,
    CancelRead = function() return CancelRead() end,
    ReadAfterDelay = function() return ReadAfterDelay() end,
    reading = function() return pendingRead ~= nil end,
    Describe = Describe,
    DescribeRegions = DescribeRegions,
    FociList = function(...) return FociList(...) end,
    WhatIsUnderTheCursor = WhatIsUnderTheCursor,
}
