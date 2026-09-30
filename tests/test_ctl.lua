------------------------------------------------------------
-- test_ctl.lua — the REAL bundled ChatThrottleLib, against the stubs
--
-- Every other file replaces ChatThrottleLib with a stub, so the library that
-- actually paces our sync traffic never ran in a test. This file loads it.
--
-- Why it matters: on this client C_ChatInfo.SendAddonMessage returns an
-- Enum.SendAddonMessageResult, and AddonMessageThrottle (3) means the server's
-- per-prefix throttle REFUSED the message. ChatThrottleLib v24 ignored the
-- return and counted the message as sent - a sync chunk silently lost, which
-- the receiver then reported as "chunks missing" and asked to resync. v32
-- moves a throttled queue aside and retries it.
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

-- A clock the library can see move; the stub's GetTime is fixed at 0.
local clock = 100
GetTime = function() return clock end

ChatThrottleLib = nil                    -- the stub's, so the real one installs
dofile("Libs/ChatThrottleLib/ChatThrottleLib.lua")
local CTL = ChatThrottleLib
check("the bundled library is v32 or newer", (CTL.version or 0) >= 32, tostring(CTL.version))

local onUpdate = CTL.Frame:GetScript("OnUpdate")
local function pump(seconds)
    local step = 0.1
    for _ = 1, math.floor(seconds / step) do
        clock = clock + step
        onUpdate(CTL.Frame, step)
    end
end
pump(6)                                  -- past the start-up hard throttle

-- Five chunks queued at once, as a sync push does; the server throttles two
-- of the sends along the way.
WoW.sent = {}
WoW.sendResults = { 0, 3, 0, 3 }         -- 2nd and 4th attempts refused
local called = {}
for i = 1, 5 do
    CTL:SendAddonMessage("BULK", "ALTSTABLE", "CHUNK|" .. i, "WHISPER", "Peer Surname", nil,
        function(arg, didSend) called[#called + 1] = { arg = arg, sent = didSend } end, i)
end
pump(10)

local texts = {}
for _, m in ipairs(WoW.sent) do texts[#texts + 1] = m.text end
eq("every chunk is delivered despite the throttle", #texts, 5)
eq("  in order, each once", table.concat(texts, ","),
   "CHUNK|1,CHUNK|2,CHUNK|3,CHUNK|4,CHUNK|5")
eq("  and the sent-callback runs once per chunk", #called, 5)
local allSent = true
for _, c in ipairs(called) do if not c.sent then allSent = false end end
check("  each reporting it was sent", allSent)

-- A second batch reuses the recycled pipe - which needs table.wipe, as the
-- client has it; a stub without it crashed here.
WoW.sent = {}
WoW.sendResults = { 3 }
for i = 6, 8 do
    CTL:SendAddonMessage("BULK", "ALTSTABLE", "CHUNK|" .. i, "WHISPER", "Peer Surname")
end
pump(10)
texts = {}
for _, m in ipairs(WoW.sent) do texts[#texts + 1] = m.text end
eq("a second batch, through a reused pipe, is delivered too", table.concat(texts, ","),
   "CHUNK|6,CHUNK|7,CHUNK|8")

-- A refusal that is NOT the throttle is not retried: the callback says so,
-- with the result, which is what QueueWire acts on.
WoW.sent = {}
WoW.sendResults = { 12 }
local report
CTL:SendAddonMessage("ALERT", "ALTSTABLE", "REQ8|0", "WHISPER", "Gone Surname", nil,
    function(_, didSend, result) report = { sent = didSend, result = result } end)
pump(2)
eq("a TargetOffline refusal is not delivered", #WoW.sent, 0)
check("  and the callback reports it: not sent, TargetOffline",
      report and report.sent == false and report.result == 12)

print(("test_ctl: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
