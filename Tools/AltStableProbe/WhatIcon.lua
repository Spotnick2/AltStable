------------------------------------------------------------
-- WhatIcon.lua — name the texture under the cursor
--
-- "That icon would be better than ours" is a normal thing to notice and an
-- annoying thing to act on: a screenshot shows the art, not the path, and
-- guessing at Interface\Icons\ names from a picture is how you end up shipping
-- the green question mark.
--
-- /fp as icon        — counts down, then reads whatever the cursor is over
-- /fp as icon now    — reads immediately (for a keybind or a macro)
-- /fp as icon cancel — call off a pending read
-- (It was /asicon, before the probe became a ForeverProbe module, #240.)
--
-- THE COUNTDOWN IS THE POINT. The first version read the cursor the instant the
-- command ran, which sounds right and is useless: typing the command means being
-- at the chat box, so by the time it executes the pointer has left whatever you
-- wanted to identify. The first real use of it came back
-- "UI-HUD-ExperienceBar-Fill-Prediction" - the status bar behind the chat
-- frame, correctly identified and entirely beside the point.
--
-- So it waits, and you move the pointer onto the thing while it does. Same
-- reason the old auto-capture (Render.lua, removed in #89) counted down first.
-- `now` is there for a keybind, which is the precise version of this: press it
-- while already hovering and there is nothing to wait for.
--
-- GetMouseFoci, plural: GetMouseFocus was removed in 11.0 and this client is
-- Mainline-derived, so the old single-return call is simply absent. It returns
-- a LIST, because more than one frame can be under the pointer. Recorded in
-- docs/forever-api-notes.md under the cursor-focus note.
--
-- Textures name themselves three ways and a frame may use any of them:
--   GetAtlas()           a named slice of a sheet, e.g. "worldquest-icon"
--   GetTextureFilePath() the path, when the texture was set from one
--   GetTextureFileID()   a numeric id, which is all you get for an atlas or
--                        for art the client resolved to a file id internally
-- All three are reported, because the one you can reuse is whichever is not nil.
------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe

local function Out(msg) Probe:Say("[icon] " .. msg) end


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
            .. "the notes say otherwise. Reading it as one anyway.")
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
    end

    return lines
end

local READ_DELAY = 5
local pendingRead

-- The /fp console and the steps panel are big mouse-enabled frames: left up,
-- the reading is of them. Probe:HideWindows() puts them away and holds through
-- the command that called it; Probe:ShowWindows() brings back what was open,
-- the console filtered to this probe on its newest lines - where a path to
-- retype is copied from: Freeze, Select all, Ctrl+C (ForeverProbe#5, #8).
-- ShowWindows on every path, a throwing read included.
local function ReadBetweenWindows()
    -- Hiding while already hidden does nothing; a bare /fp in the meantime
    -- showed the console and cleared that, so this puts it away again.
    Probe:HideWindows()
    local ok, lines = pcall(WhatIsUnderTheCursor)
    Probe:ShowWindows()
    if not ok then error(lines, 0) end
    return lines
end

-- The countdown, on a banner of the probe's own. It was on the errors frame,
-- which is UIParent's: it vanished while the AltStable sheet hides the game
-- UI - which is when this command is most wanted, to name the sheet's own
-- textures (measured in game, 2026-10-15). The console stays up there since
-- ForeverProbe#7, but it is put away for the countdown. So:
--   * parentless, so a hidden UIParent doesn't take it along (the sheet's
--     showcase lifts the sheet the same way);
--   * scaled to UIParent's effective scale, so it reads the same size;
--   * never takes the mouse, so it can't be what a reading names.
-- After the read it says where the answer went, then goes.
local BANNER_HOLD = 4
local banner, bannerToken = nil, 0

local function Banner(text, hold)
    if not banner then
        banner = CreateFrame("Frame", nil, nil)
        banner:SetFrameStrata("FULLSCREEN_DIALOG")
        banner:EnableMouse(false)
        banner:SetSize(700, 40)
        banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        banner.text:SetAllPoints()
    end
    banner:SetScale(UIParent:GetEffectiveScale())
    banner:ClearAllPoints()
    banner:SetPoint("TOP", WorldFrame, "TOP", 0, -140)
    banner.text:SetText(text)
    banner:Show()
    bannerToken = bannerToken + 1
    if hold then
        local mine = bannerToken
        C_Timer.After(hold, function() if bannerToken == mine then banner:Hide() end end)
    end
end

local function HideBanner()
    bannerToken = bannerToken + 1
    if banner then banner:Hide() end
end

local function CancelRead()
    if not pendingRead then return false end
    pendingRead:Cancel()
    pendingRead = nil
    HideBanner()
    Probe:ShowWindows()        -- the countdown put them away
    return true
end

local function ReadAfterDelay()
    -- Get the windows off the screen first, or the reading is of the probe's
    -- own backdrop. Before the early return below: a repeated ask after a
    -- bare /fp has to put them away again (Codex on #241).
    Probe:HideWindows()

    -- Idempotent, like the capture countdown: five of these queued at once is
    -- how a countdown turns into a burst.
    if pendingRead then
        Out("already counting down - |cffffff00/fp as icon cancel|r to stop it")
        return
    end

    Out(("hover the thing now - reading in %ds. "):format(READ_DELAY)
        .. "|cffffff00/fp as icon cancel|r to stop, |cffffff00/fp as icon now|r to skip the wait.")
    Banner(("hover the thing now - reading in %d"):format(READ_DELAY))

    local remaining = READ_DELAY
    pendingRead = C_Timer.NewTicker(1, function(ticker)
        remaining = remaining - 1
        if remaining > 0 then
            Banner(tostring(remaining) .. "...")
            return
        end
        ticker:Cancel()
        pendingRead = nil
        -- The windows come back whatever the answer: output goes nowhere
        -- else. If the read throws, the banner goes too.
        HideBanner()
        local lines = ReadBetweenWindows()
        Banner(("read: %d line(s) - in the /fp console"):format(#lines), BANNER_HOLD)
    end)
end

Probe:Command("icon", function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "cancel" then
        if not CancelRead() then Out("nothing counting down") end
        return
    end
    if msg == "now" then
        -- Cancel any countdown first. Without this the pending one still fires
        -- five seconds later and overwrites the answer just given with
        -- whatever the cursor has wandered onto - two readings from one ask,
        -- and the wrong one last.
        CancelRead()
        ReadBetweenWindows()
        return
    end
    if msg ~= "" then
        Out("usage: |cffffff00/fp as icon|r, |cffffff00/fp as icon now|r, |cffffff00/fp as icon cancel|r")
        return
    end
    ReadAfterDelay()
end, "[now | cancel]: name the texture under the cursor, after a countdown")

NS._testIcon = {
    READ_DELAY = READ_DELAY,
    CancelRead = function() return CancelRead() end,
    ReadAfterDelay = function() return ReadAfterDelay() end,
    reading = function() return pendingRead ~= nil end,
    banner = function() return banner end,
    Describe = Describe,
    DescribeRegions = DescribeRegions,
    FociList = function(...) return FociList(...) end,
    WhatIsUnderTheCursor = WhatIsUnderTheCursor,
}
