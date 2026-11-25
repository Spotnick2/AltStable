------------------------------------------------------------
-- Played.lua - each character's time played (#378, a CurseForge request)
--
-- The game tells it on request: RequestTimePlayed() -> TIME_PLAYED_MSG
-- (total, this level), in seconds; the same function /played calls. Measured
-- on 71139 (/fp steps as played, #378): the reply comes in about 0.05 s, and
-- other addons (GlassPanelXP, RXPGuides) already ask within seconds of every
-- login. So:
--   * any TIME_PLAYED_MSG is read, whoever asked for it;
--   * AltStable asks only when none has come REQUEST_AFTER seconds after a
--     login or a reload, so it rarely asks at all and never on top of
--     another addon's request;
--   * when it asks, the chat frames that print the reply have the event
--     muted around the request, one request at a time, and get it back the
--     frame after the reply or after UNMUTE_AFTER seconds - never by
--     replacing Blizzard's DisplayTimePlayed, which would taint it. The
--     GlassPanelXP way, already shipped in the suite.
--
-- Stored on the character's record, so it syncs like any other field:
-- `played` and `playedLevel`, as of the last reading or logout. While the
-- character is played, a session clock started by a reply counts on from it
-- (PlayedNow); a saved stamp's "now minus then" would count the time spent
-- offline. At logout the clock's value is written back.
------------------------------------------------------------

AltStable = AltStable or {}

local REQUEST_AFTER = 15
local UNMUTE_AFTER  = 10

local Played = {}
AltStable.Played = Played

-- The session clock, for the character being played: set by a reply.
-- { guid, total, level, at, levelAt } with GetTime() stamps.
local clock
-- A reply heard since this load, from anyone.
local heard = false
-- Our request's muted chat frames, and its token.
local muted, pending = {}, nil

local function Plain(v)
    local f = AltStable.API and AltStable.API.PlainNumber
    if f then return f(v) end
    return type(v) == "number" and v or nil
end

-- A character's time played now, total and at its level, in seconds; nil
-- when not known. The character being played counts on from its last reply.
function AltStable.PlayedNow(char)
    if type(char) ~= "table" then return nil end
    if clock and char.guid == clock.guid then
        local t = GetTime()
        return clock.total + (t - clock.at), clock.level + (t - clock.levelAt)
    end
    return Plain(char.played), Plain(char.playedLevel)
end

-- Whether a character's time is counting live (the one being played, after
-- a reply).
function AltStable.PlayedIsLive(char)
    return clock ~= nil and type(char) == "table" and char.guid == clock.guid
end

local floor = math.floor

-- Compact, for the cell: "212d 4h", "5h 20m", "45m", "<1m".
function AltStable.FormatPlayedShort(sec)
    sec = tonumber(sec)
    if not sec or sec < 0 then return nil end
    sec = floor(sec)
    local d, h, m = floor(sec / 86400), floor(sec % 86400 / 3600), floor(sec % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m" end
    return "<1m"
end

-- In words, for the tooltip: "1 year, 2 months, 3 days, 4 hours, 5 minutes",
-- the parts that aren't zero. A year is 365 days and a month 30: said so in
-- the tooltip whenever it uses them.
local PARTS = {
    { 365 * 86400, "year" }, { 30 * 86400, "month" }, { 86400, "day" },
    { 3600, "hour" }, { 60, "minute" },
}
function AltStable.FormatPlayedLong(sec)
    sec = tonumber(sec)
    if not sec or sec < 0 then return nil end
    sec = floor(sec)
    local out, months = {}, false
    for _, p in ipairs(PARTS) do
        local n = floor(sec / p[1])
        if n > 0 then
            out[#out + 1] = n .. " " .. p[2] .. (n == 1 and "" or "s")
            sec = sec - n * p[1]
            if p[1] >= 30 * 86400 then months = true end
        end
    end
    if #out == 0 then return "less than a minute", false end
    return table.concat(out, ", "), months
end

------------------------------------------------------------
-- Asking, quietly
------------------------------------------------------------

local function Unmute(token)
    if pending ~= token then return end
    for _, f in ipairs(muted) do f:RegisterEvent("TIME_PLAYED_MSG") end
    muted, pending = {}, nil
end

-- Asks for the time played with the chat frames muted. Not while a request
-- of ours is out, nor once a reply has come since this load.
function Played.Request()
    if pending or heard then return false end
    local ask = rawget(_G, "RequestTimePlayed")
    if type(ask) ~= "function" then return false end
    for i = 1, rawget(_G, "NUM_CHAT_WINDOWS") or 10 do
        local f = rawget(_G, "ChatFrame" .. i)
        if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
            f:UnregisterEvent("TIME_PLAYED_MSG")
            muted[#muted + 1] = f
        end
    end
    local token = {}
    pending = token
    C_Timer.After(UNMUTE_AFTER, function() Unmute(token) end)
    if not pcall(ask) then Unmute(token) end
    return true
end

------------------------------------------------------------
-- What the game says
------------------------------------------------------------

-- A reply, from our request or anyone's (a typed /played too).
function Played.OnReply(total, level)
    heard = true
    -- The chat frames get the event after us or not at all: given back on
    -- the next frame, outside this dispatch.
    if pending then
        local token = pending
        C_Timer.After(0, function() Unmute(token) end)
    end
    total, level = Plain(total), Plain(level)
    if not total then return end
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return end
    local t = GetTime()
    clock = { guid = guid, total = total, level = level or 0, at = t, levelAt = t }
    local char = type(AltStableDB) == "table" and AltStableDB[guid]
    if type(char) == "table" then
        char.played, char.playedLevel = total, level
        -- Carried by the next delta sync, like the Hearthstone.
        if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
end

-- A new level: its time starts at nothing, on the clock and on the record,
-- so a peer pulling it before logout doesn't see the last level's hours at
-- this one (Codex review of #496). Without a clock the record's level time
-- is unknown from here.
function Played.OnLevelUp()
    if clock then clock.level, clock.levelAt = 0, GetTime() end
    local guid = UnitGUID and UnitGUID("player")
    local char = guid and type(AltStableDB) == "table" and AltStableDB[guid]
    if type(char) == "table" then char.playedLevel = clock and 0 or nil end
end

-- A scan of the character being played: the clock's value goes on the
-- record. That is also what saves a reply that came before the record
-- existed - a new character, another addon asking at login, before the
-- first scan (Codex review of #496).
function Played.OnScanned(char)
    if not (clock and type(char) == "table" and char.guid == clock.guid) then return end
    local total, level = AltStable.PlayedNow(char)
    char.played, char.playedLevel = floor(total), floor(level)
end

-- Leaving: the clock's value goes on the record, written with the
-- SavedVariables and carried by the next sync.
function Played.OnLogout()
    if not clock then return end
    Played.OnScanned(type(AltStableDB) == "table" and AltStableDB[clock.guid])
end

-- A login or a reload: ask if nobody has within REQUEST_AFTER seconds.
-- Zoning (an instance, a portal) asks nothing.
function Played.OnEnteringWorld(isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    C_Timer.After(REQUEST_AFTER, Played.Request)
end

local events = CreateFrame("Frame")
events:RegisterEvent("TIME_PLAYED_MSG")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "TIME_PLAYED_MSG" then Played.OnReply(...)
    elseif event == "PLAYER_ENTERING_WORLD" then Played.OnEnteringWorld(...)
    elseif event == "PLAYER_LEVEL_UP" then Played.OnLevelUp()
    elseif event == "PLAYER_LOGOUT" then Played.OnLogout()
    end
end)

-- Test seam: back to a fresh load.
AltStable._test = AltStable._test or {}
AltStable._test.PlayedFrame = events
AltStable._test.ResetPlayed = function()
    clock, heard, muted, pending = nil, false, {}, nil
end
