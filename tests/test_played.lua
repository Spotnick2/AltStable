------------------------------------------------------------
-- test_played.lua - each character's time played (#378)
--
-- Pinned: the cell and tooltip formats; a reply (anyone's) is read onto the
-- record, touched for the delta and starts a session clock that counts on
-- from it; AltStable asks only when nobody has 15 s after a login or a
-- reload, muting the chat frames that print the reply and giving them back
-- the frame after it or after 10 s, one request at a time; a level-up
-- restarts the level's time; logout writes the clock back; a secret reply is
-- not read; the footer's totals count unknown characters, never as 0.
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
assert(loadfile("Core.lua"))()

-- A clock of its own: GetTime and the timers, in order of when they fall due.
local now, due = 1000, {}
GetTime = function() return now end
C_Timer.After = function(d, fn) due[#due + 1] = { at = now + d, fn = fn } end
local function advance(sec)
    local stop = now + sec
    while true do
        local best, bi
        for i, e in ipairs(due) do
            if e.at <= stop and (not best or e.at < best.at) then best, bi = e, i end
        end
        if not best then break end
        table.remove(due, bi)
        now = best.at
        best.fn()
    end
    now = stop
end

local refreshes = 0
AltStable.RefreshSheet = function() refreshes = refreshes + 1 end

-- The chat frames, and the client's answer: our listener first, then every
-- chat frame still registered prints it.
local function chatFrame(on)
    local f = { reg = { TIME_PLAYED_MSG = on or nil }, lines = 0 }
    function f:IsEventRegistered(e) return self.reg[e] == true end
    function f:RegisterEvent(e) self.reg[e] = true end
    function f:UnregisterEvent(e) self.reg[e] = nil end
    return f
end
ChatFrame1, ChatFrame2, NUM_CHAT_WINDOWS = chatFrame(true), chatFrame(false), 2
local asked = 0
RequestTimePlayed = function() asked = asked + 1 end

dofile("Played.lua")
local P = AltStable.Played

local me = UnitGUID("player")
local function reply(total, level)
    P.OnReply(total, level)
    for _, f in ipairs({ ChatFrame1, ChatFrame2 }) do
        if f:IsEventRegistered("TIME_PLAYED_MSG") then f.lines = f.lines + 1 end
    end
end
local function fresh()
    AltStable._test.ResetPlayed()
    due, asked, refreshes = {}, 0, 0
    ChatFrame1.reg.TIME_PLAYED_MSG, ChatFrame2.reg.TIME_PLAYED_MSG = true, nil
    ChatFrame1.lines = 0
    AltStableDB = { [me] = { guid = me, name = "Me", level = 20, lastUpdate = 1 },
                    ["Player-Alt"] = { guid = "Player-Alt", name = "Alt", level = 60,
                                       played = 3600 * 30, playedLevel = 600 },
                    ["Player-New"] = { guid = "Player-New", name = "New", level = 1 } }
end

------------------------------------------------------------
-- Formats
------------------------------------------------------------

eq("under a minute", AltStable.FormatPlayedShort(30), "<1m")
eq("minutes", AltStable.FormatPlayedShort(45 * 60 + 59), "45m")
eq("hours and minutes", AltStable.FormatPlayedShort(5 * 3600 + 20 * 60), "5h 20m")
eq("days and hours", AltStable.FormatPlayedShort(212 * 86400 + 4 * 3600 + 59 * 60), "212d 4h")
eq("unknown is nothing", AltStable.FormatPlayedShort(nil), nil)
eq("  and so is a negative", AltStable.FormatPlayedShort(-5), nil)
local words, months = AltStable.FormatPlayedLong(365 * 86400 + 2 * 30 * 86400 + 3 * 86400 + 4 * 3600 + 5 * 60 + 9)
eq("in words: every part that isn't zero", words, "1 year, 2 months, 3 days, 4 hours, 5 minutes")
eq("  and it says months were used", months, true)
words, months = AltStable.FormatPlayedLong(3600 + 60)
eq("singular parts", words, "1 hour, 1 minute")
eq("  no months, nothing to explain", months, false)
eq("under a minute in words", (AltStable.FormatPlayedLong(20)), "less than a minute")
eq("29 days are days", (AltStable.FormatPlayedLong(29 * 86400)), "29 days")

------------------------------------------------------------
-- Reading a reply
------------------------------------------------------------

fresh()
local alt = AltStableDB["Player-Alt"]
eq("another character: its record", (AltStable.PlayedNow(alt)), 3600 * 30)
eq("  a character never read: unknown", (AltStable.PlayedNow(AltStableDB["Player-New"])), nil)
eq("the one played, before a reply: its record (none yet)", (AltStable.PlayedNow(AltStableDB[me])), nil)
check("  not live", not AltStable.PlayedIsLive(AltStableDB[me]))

WoW.now = 5000
reply(7200, 900)
eq("a reply goes on the record", AltStableDB[me].played, 7200)
eq("  with the time at this level", AltStableDB[me].playedLevel, 900)
eq("  touched, so a delta carries it", AltStableDB[me].lastUpdate, 5000)
eq("  and the sheet is redrawn", refreshes, 1)
advance(120)
local total, level = AltStable.PlayedNow(AltStableDB[me])
eq("the clock counts on while playing", total, 7320)
eq("  at this level too", level, 1020)
check("  live", AltStable.PlayedIsLive(AltStableDB[me]))
eq("  the record keeps the reading", AltStableDB[me].played, 7200)
eq("  another character is not counted on", (AltStable.PlayedNow(alt)), 3600 * 30)

P.OnLevelUp()
advance(60)
total, level = AltStable.PlayedNow(AltStableDB[me])
eq("a new level: its time starts at nothing", level, 60)
eq("  the total goes on", total, 7380)

P.OnLogout()
eq("logout writes the clock back", AltStableDB[me].played, 7380)
eq("  and the level's", AltStableDB[me].playedLevel, 60)
advance(0.5)
P.OnLogout()
eq("  whole seconds", AltStableDB[me].played, 7380)

fresh()
P.OnLogout()
eq("logout without a reply changes nothing", AltStableDB[me].played, nil)
reply(WoW.secret(50), 10)
eq("a secret reply is not read", AltStableDB[me].played, nil)
check("  nor starts a clock", not AltStable.PlayedIsLive(AltStableDB[me]))

------------------------------------------------------------
-- Asking, only when nobody has
------------------------------------------------------------

fresh()
P.OnEnteringWorld(true, false)
advance(14)
eq("nothing asked before 15 s", asked, 0)
advance(1)
eq("nobody answered: asked at 15 s", asked, 1)
check("  with the printing chat frame muted", not ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
check("  and the other left as it was", not ChatFrame2:IsEventRegistered("TIME_PLAYED_MSG"))
check("  one request at a time", not P.Request() and asked == 1)
reply(100, 100)
eq("our reply doesn't print", ChatFrame1.lines, 0)
check("  the frame is still muted inside the reply's dispatch", not ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
advance(0)
check("  and gets the event back on the next frame", ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
check("  never the one that didn't have it", not ChatFrame2:IsEventRegistered("TIME_PLAYED_MSG"))
advance(20)
check("  the timeout later changes nothing", ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG")
      and not ChatFrame2:IsEventRegistered("TIME_PLAYED_MSG"))
reply(160, 160)
eq("a typed /played afterwards prints", ChatFrame1.lines, 1)
check("  and once a reply came, nothing more is asked", not P.Request())

fresh()
P.OnEnteringWorld(true, false)
advance(5)
reply(500, 500)   -- another addon asked
advance(20)
eq("another addon's reply within 15 s: AltStable asks nothing", asked, 0)
eq("  and reads it", AltStableDB[me].played, 500)

fresh()
P.OnEnteringWorld(false, true)
advance(15)
eq("a reload asks too", asked, 1)
fresh()
P.OnEnteringWorld(false, false)
advance(30)
eq("zoning asks nothing", asked, 0)

fresh()
P.Request()
advance(9)
check("no reply: still muted at 9 s", not ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
advance(1)
check("  given back at 10 s", ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
check("  and it may ask again", P.Request() and asked == 2)

fresh()
RequestTimePlayed = function() asked = asked + 1; error("refused") end
P.Request()
check("a request that throws gives the frames back at once", ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
RequestTimePlayed = function() asked = asked + 1 end
advance(2)
P.Request()
advance(8)
check("  its own timeout, later, doesn't unmute the next request", not ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
advance(2)
check("  which gets its own", ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
RequestTimePlayed = nil
fresh()
check("no RequestTimePlayed: nothing muted, nothing asked",
      not P.Request() and ChatFrame1:IsEventRegistered("TIME_PLAYED_MSG"))
RequestTimePlayed = function() asked = asked + 1 end

------------------------------------------------------------
-- The footer's totals
------------------------------------------------------------

fresh()
local t = AltStable.CharacterTotals()
eq("the totals add the known", t.played, 3600 * 30)
eq("  and count the unknown", t.playedUnknown, 2)
reply(1000, 10)
advance(100)
t = AltStable.CharacterTotals()
eq("  the one played counts live", t.played, 3600 * 30 + 1100)
eq("  and is known now", t.playedUnknown, 1)

-- The events, through the frame's own handler.
local f = AltStable._test.PlayedFrame
for _, e in ipairs({ "TIME_PLAYED_MSG", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_LOGOUT" }) do
    check("listens to " .. e, f:IsEventRegistered(e))
end
fresh()
local onEvent = f:GetScript("OnEvent")
onEvent(f, "TIME_PLAYED_MSG", 4000, 40)
eq("TIME_PLAYED_MSG is read", AltStableDB[me].played, 4000)
onEvent(f, "PLAYER_LEVEL_UP", 21)
advance(5)
eq("PLAYER_LEVEL_UP restarts the level's time", select(2, AltStable.PlayedNow(AltStableDB[me])), 5)
onEvent(f, "PLAYER_LOGOUT")
eq("PLAYER_LOGOUT writes it back", AltStableDB[me].played, 4005)
fresh()
onEvent(f, "PLAYER_ENTERING_WORLD", true, false)
advance(15)
eq("PLAYER_ENTERING_WORLD at login leads to a request", asked, 1)

WoW.finish("test_played", passed, failed)
