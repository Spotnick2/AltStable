----------------------------------------------------------------------------
-- /fp as played - time played on Forever, and our own request silenced (#378)
--
-- The Played column reads RequestTimePlayed() -> TIME_PLAYED_MSG (both in the
-- 71091 dump; /played calls the same function in Blizzard's SlashCommands).
-- Blizzard's chat frames print "Total time played" on every TIME_PLAYED_MSG,
-- so the addon's own request must not reach them while a typed /played must.
-- Measured here:
--   * whether TIME_PLAYED_MSG fires on its own at login (events since load);
--   * the reply to RequestTimePlayed(): how long it takes, the two values;
--   * silenced: UnregisterEvent on the chat frames that have it, our request,
--     re-register on the reply - does any chat frame still print it, and are
--     the frames registered again afterwards;
--   * a typed /played after that still prints.
-- Printing is counted by a post-hook on each chat frame's AddMessage, for
-- lines that start like TIME_PLAYED_TOTAL.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe

local function Out(s) Probe:Say("[played] " .. s) end

local function DB()
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.played = AltStableProbeDB.played or { events = {}, runs = {} }
    return AltStableProbeDB.played
end

local Played = { printed = 0, hooked = {}, loadedAt = GetTime() }

-- The chat frames: ChatFrame1..NUM_CHAT_WINDOWS.
function Played.Frames()
    local out = {}
    for i = 1, (rawget(_G, "NUM_CHAT_WINDOWS") or 10) do
        local f = rawget(_G, "ChatFrame" .. i)
        if f then out[#out + 1] = f end
    end
    return out
end

function Played.Registered()
    local out = {}
    for i, f in ipairs(Played.Frames()) do
        if f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then out[#out + 1] = i end
    end
    return out
end

-- "Total time played: %s" -> "Total time played:"
local function Prefix()
    local fmt = rawget(_G, "TIME_PLAYED_TOTAL")
    if type(fmt) ~= "string" then return nil end
    return (fmt:match("^(.-)%%s") or fmt)
end

function Played.Hook()
    local prefix = Prefix()
    for _, f in ipairs(Played.Frames()) do
        if not Played.hooked[f] and f.AddMessage then
            Played.hooked[f] = true
            hooksecurefunc(f, "AddMessage", function(_, text)
                if prefix and type(text) == "string" and text:sub(1, #prefix) == prefix then
                    Played.printed = Played.printed + 1
                end
            end)
        end
    end
end

-- The chat frames a run unregistered, back on the event: on the reply, or
-- after 10 s without one. Once.
Played.silenced = {}
function Played.Restore(run, why)
    local frames = Played.silenced[run]
    if not frames then return end
    Played.silenced[run] = nil
    for _, f in ipairs(frames) do f:RegisterEvent("TIME_PLAYED_MSG") end
    run.restoredBy = why
end

-- Every TIME_PLAYED_MSG since load, and the run waiting for it.
Played.pending = nil
function Played.OnEvent(_, _, total, level)
    local d = DB()
    local e = { at = GetTime() - Played.loadedAt, total = total, level = level,
                ours = Played.pending and Played.pending.label or nil }
    if #d.events < 50 then d.events[#d.events + 1] = e end
    local run = Played.pending
    if run then
        Played.pending = nil
        run.reply = { after = GetTime() - run.t0, total = total, level = level }
        -- Next frame, not inside this dispatch: a chat frame registered again
        -- now might still be handed this very event.
        C_Timer.After(0, function() Played.Restore(run, "reply") end)
        -- The chat frames got this event after us (or not at all): count once
        -- the frame has finished.
        C_Timer.After(0.5, function()
            run.printed = Played.printed - run.printedBefore
            run.registeredAfter = Played.Registered()
            run.done = true
            Out(("%s: reply after %.2f s, total %s, level %s, chat lines %d, registered %s"):format(
                run.label, run.reply.after, tostring(total), tostring(level), run.printed,
                table.concat(run.registeredAfter, ",")))
        end)
    end
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("TIME_PLAYED_MSG")
    f:SetScript("OnEvent", Played.OnEvent)
end

function Played.Ask(label, silence)
    Played.Hook()
    local d = DB()
    local run = { label = label, t0 = GetTime(), printedBefore = Played.printed,
                  registeredBefore = Played.Registered(),
                  eventsBefore = #d.events }
    d.runs[#d.runs + 1] = run
    if silence then
        -- The frames themselves stay out of the saved run: SavedVariables
        -- would try to write a frame table.
        local frames = {}
        for _, f in ipairs(Played.Frames()) do
            if f:IsEventRegistered("TIME_PLAYED_MSG") then
                f:UnregisterEvent("TIME_PLAYED_MSG")
                frames[#frames + 1] = f
            end
        end
        Played.silenced[run] = frames
        run.silencedCount = #frames
        C_Timer.After(10, function() Played.Restore(run, "timeout") end)
    end
    Played.pending = run
    local ok, err = pcall(RequestTimePlayed)
    run.called = ok
    run.err = not ok and tostring(err) or nil
    C_Timer.After(10, function()
        if run.done then return end
        if Played.pending == run then Played.pending = nil end
        run.done, run.timedOut = true, true
        run.printed = Played.printed - run.printedBefore
        run.registeredAfter = Played.Registered()
        Out(label .. ": no reply in 10 s")
    end)
    return run
end

-- What a typed /played did since `since` (a run).
function Played.Typed(label)
    Played.Hook()
    local d = DB()
    local run = { label = label, typed = true, t0 = GetTime(), printedBefore = Played.printed,
                  eventsBefore = #d.events, registeredBefore = Played.Registered() }
    d.runs[#d.runs + 1] = run
    return run
end

local function Latest(label)
    local runs = DB().runs
    for i = #runs, 1, -1 do
        if runs[i].label == label then return runs[i] end
    end
end

local function Summary(r)
    if not r then return "not run" end
    if r.timedOut then return "no reply in 10 s" end
    if not r.done then return "waiting" end
    return ("reply %.2f s, chat lines %d, registered after: %s"):format(
        r.reply and r.reply.after or -1, r.printed or -1, table.concat(r.registeredAfter or {}, ","))
end

local function SaveStart()
    local d = DB()
    d.atStart = { eventsSinceLoad = #d.events, registered = Played.Registered(),
                  prefix = Prefix(), frames = #Played.Frames(),
                  hasRequest = type(rawget(_G, "RequestTimePlayed")) == "function" }
    Out(("events since load %d, chat frames %d, registered %s"):format(
        d.atStart.eventsSinceLoad, d.atStart.frames, table.concat(d.atStart.registered, ",")))
end

local function Waited(label)
    return function()
        local r = Latest(label)
        if r and r.done then return true, Summary(r) end
        return false, "waiting for the reply"
    end
end

local function Checked(label, want)
    return function()
        local r = Latest(label)
        return r ~= nil and r.done == true and not r.timedOut and want(r), Summary(r)
    end
end

Probe:Command("played", function(arg)
    Played.Ask(arg ~= "" and arg or "manual", arg == "silent")
end, "ask the time played (/fp as played silent: with the chat frames silenced) (#378)")

Probe:Steps("played", {
    title = "Time played, and our own request kept out of chat (#378)",
    { text = "Reading what happened since login, then asking the time played once the normal way: "
          .. "the chat shows \"Total time played\" this time, that's expected.",
      auto = true,
      run = function() SaveStart(); Played.Ask("plain", false); return true end },
    { text = "Waiting for the reply...",
      wait = Waited("plain"), timeout = 12, check = Checked("plain", function(r) return r.printed > 0 end) },
    { text = "Asking again with the chat frames silenced: nothing should appear in chat.",
      auto = true,
      run = function() Played.Ask("silent", true); return true end },
    { text = "Waiting for the reply...",
      wait = Waited("silent"), timeout = 12,
      check = Checked("silent", function(r)
          return r.printed == 0 and #r.registeredAfter == #r.registeredBefore end) },
    { text = "Press Run, then type /played in chat yourself: it should print as usual.",
      button = "Run",
      run = function() Played.Typed("typed"); return true end },
    { text = "Waiting for your /played (up to a minute)...",
      wait = function()
          local r = Latest("typed")
          if r and Played.printed > r.printedBefore then
              r.printed = Played.printed - r.printedBefore
              r.events = #DB().events - r.eventsBefore
              r.done = true
              return true, ("chat lines %d, events %d"):format(r.printed, r.events)
          end
          return false, "type /played"
      end,
      timeout = 60,
      check = function()
          local r = Latest("typed")
          return r ~= nil and (r.printed or 0) > 0, r and ("chat lines " .. tostring(r.printed or 0)) or "not run"
      end },
    { text = "Done. Type /reload now to save the results.",
      reload = true },
})

-- The test seam, on the namespace, never on _G.
NS.played = { Played = Played, Summary = Summary, Latest = Latest }
