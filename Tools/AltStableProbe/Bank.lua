----------------------------------------------------------------------------
-- /fp steps as bankclose - closing the bank right after a move (#419)
--
-- Warband reads the bank 1 s after a bank change, and only while it is open,
-- so a move followed by a quick close records the bags side and not the bank
-- side. Choosing the fix needs two things nobody has measured on Forever:
--   1. the ORDER of a move's events against the close: does the batch's
--      BAG_UPDATE_DELAYED come before BANKFRAME_CLOSED when the bank is closed
--      at once (Escape, the close button, walking away)?
--   2. whether the bank still READS RIGHT inside BANKFRAME_CLOSED, the next
--      frame, a second later, and in any bank update arriving after the close.
-- Each bank visit (open to 3 s after the close) records, in order (a sequence
-- number, the frame and GetTime()): BAG_UPDATE (bank tab or carried, by the
-- tab list taken at the open), BAG_UPDATE_DELAYED, PLAYERBANKSLOTS_CHANGED,
-- ITEM_LOCK_CHANGED, BANK_TABS_CHANGED, the interaction frame's SHOW/HIDE and
-- the close. The character bank (never the account bank) is read at the open,
-- at every bank-tab BAG_UPDATE, BAG_UPDATE_DELAYED and PLAYERBANKSLOTS_CHANGED,
-- inside the close, after C_Timer.After(0) (its real frame delta recorded) and
-- after 1 s. A read is compared with the open's, slot by slot:
--   kept      occupied slots at the open that still read the same item and
--             count: a healthy read keeps all but the moved slot(s); a read
--             that lost the bank's contents keeps none (the control);
--   changed   each slot that differs, exactly (bag:slot id x count);
--   items     the per-item totals that differ.
-- Slots are read as Warband reads them (the item id, else the link's), every
-- call guarded; a failed or unreadable slot is counted, never taken as empty.
-- Only item ids and counts are kept. Results: the log, and
-- AltStableProbeDB.bankclose (the last 20 visits, summarised after each).
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe

local WINDOW = 3          -- seconds recorded after a close
local KEEP = 20           -- visits kept in AltStableProbeDB.bankclose

local frameNo = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function() frameNo = frameNo + 1 end)

local visitNo, current = 0, nil      -- current: the visit being recorded
local recentVisit                   -- the newest visit, still in its window or done
local trial                         -- the armed trial whose report is pending
local lastFinished                  -- the newest finished visit: checked against the next baseline

local function API() return AltStable and AltStable.API end

local function Tabs()
    local a = API()
    if not a or type(a.GetCharacterBankTabIDs) ~= "function" then return nil end
    local ok, ids = pcall(a.GetCharacterBankTabIDs)
    if ok and type(ids) == "table" then return ids end
    return nil
end

local function IsIn(bag, list)
    for _, id in ipairs(list or {}) do if id == bag then return true end end
    return false
end

-- One slot, as Warband reads it. Returns id, count, locked; or nil (empty);
-- or nil, "bad" (occupied, count unreadable); or nil, "error".
local function ReadSlot(a, bag, slot)
    local ok, id, count, locked = pcall(function()
        local i = a.GetContainerItemID and a.GetContainerItemID(bag, slot)
        i = tonumber(i)
        if not i or i == 0 then
            local link = a.GetContainerItemLink and a.GetContainerItemLink(bag, slot)
            i = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        end
        if not i or i == 0 then return nil end
        local info = a.GetContainerItemInfo and a.GetContainerItemInfo(bag, slot)
        local n = type(info) == "table" and tonumber(info.stackCount) or nil
        if not n or n < 1 then return nil, "bad" end
        return i, n, type(info) == "table" and info.isLocked == true or false
    end)
    if not ok then return nil, "error" end
    return id, count, locked
end

-- The visit's tabs as they read now: { slots = "6:98,...", at = { ["6:3"] =
-- { id, count } }, bad = n, errors = n, locked = n }. Never throws.
local function Read(tabs)
    local a = API()
    -- unknown[key]: a slot that could not be read (bad or error); unknownTabs:
    -- tabs whose slot count could not be read. Neither is ever taken as empty.
    local r = { slots = {}, at = {}, unknown = {}, unknownBags = {}, unknownTabs = 0, bad = 0, errors = 0, locked = 0 }
    if not a or not tabs then r.err = "no tab list"; r.slots = ""; return r end
    for _, bag in ipairs(tabs) do
        -- AltStable's own rule (Compat BankContainerSlots, #439): a purchased
        -- bag slot with no bag is 0 (nothing, read whole); the main bank at 0,
        -- or a bag at 0, is not loaded (unknown).
        local ok, n = pcall(function()
            if a.BankContainerSlots then return a.BankContainerSlots(bag) end
            local c = tonumber(a.GetContainerNumSlots(bag))
            return (c and c > 0) and c or nil
        end)
        n = ok and n or nil
        if not n then r.unknownTabs = r.unknownTabs + 1; r.unknownBags[bag] = true end
        r.slots[#r.slots + 1] = bag .. ":" .. tostring(n)
        for slot = 1, n or 0 do
            local id, count, locked = ReadSlot(a, bag, slot)
            local key = bag .. ":" .. slot
            if id then
                r.at[key] = { id, count }
                if locked then r.locked = r.locked + 1 end
            elseif count == "bad" then r.bad = r.bad + 1; r.unknown[key] = true
            elseif count == "error" then r.errors = r.errors + 1; r.unknown[key] = true end
        end
    end
    r.slots = table.concat(r.slots, ",")
    return r
end

-- A read against the open's: kept/occupied, the slots that differ, the item
-- totals that differ. Formatted after the visit, never inside an event.
local function Summarise(open, r)
    local function unknownIn(t, key)
        return t.unknown[key] or t.unknownBags[tonumber(key:match("^(-?%d+):"))] or false
    end
    local kept, occupied, changed = 0, 0, {}
    for key, v in pairs(open.at) do
        occupied = occupied + 1
        local w = r.at[key]
        if w and w[1] == v[1] and w[2] == v[2] then kept = kept + 1
        elseif not w and unknownIn(r, key) then changed[#changed + 1] = key .. " " .. v[1] .. "x" .. v[2] .. "->?"
        else changed[#changed + 1] = key .. " " .. v[1] .. "x" .. v[2] .. "->" .. (w and (w[1] .. "x" .. w[2]) or "empty") end
    end
    for key, w in pairs(r.at) do
        if not open.at[key] then
            changed[#changed + 1] = key .. (unknownIn(open, key) and " ?->" or " empty->") .. w[1] .. "x" .. w[2]
        end
    end
    table.sort(changed)
    local function totals(t)
        local m = {}
        for _, v in pairs(t.at) do m[v[1]] = (m[v[1]] or 0) + v[2] end
        return m
    end
    local a, b, items = totals(open), totals(r), {}
    for id, n in pairs(a) do if b[id] ~= n then items[#items + 1] = id .. ":" .. n .. "->" .. (b[id] or 0) end end
    for id, n in pairs(b) do if not a[id] then items[#items + 1] = id .. ":0->" .. n end end
    table.sort(items)
    -- Totals are only exact when both reads are whole.
    local incomplete = next(open.unknown) or next(r.unknown) or open.unknownTabs > 0 or r.unknownTabs > 0
                       or open.err or r.err
    return ("kept=%d/%d slots=%s bad=%d errors=%d locked=%d changed=[%s] items%s=[%s]%s"):format(
        kept, occupied, tostring(r.slots), r.bad, r.errors, r.locked, table.concat(changed, "; "),
        incomplete and "(INCOMPLETE)" or "", table.concat(items, " "), r.err and (" ERR " .. r.err) or "")
end

-- Whether a read is whole: every tab's slot count and every slot read.
local function Whole(r)
    return not r.err and r.unknownTabs == 0 and next(r.unknown) == nil
end

-- A read's absolute item totals, for comparing one visit with the next (the
-- final reopen is the truth the trials are checked against).
local function Totals(r)
    local m, ids = {}, {}
    for _, v in pairs(r.at) do
        if not m[v[1]] then ids[#ids + 1] = v[1] end
        m[v[1]] = (m[v[1]] or 0) + v[2]
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = id .. ":" .. m[id] end
    local unknown = 0
    for _ in pairs(r.unknown) do unknown = unknown + 1 end
    if unknown > 0 or r.unknownTabs > 0 then
        out[#out + 1] = ("+%d unknown slots, %d unknown tabs"):format(unknown, r.unknownTabs)
    end
    if r.err then out[#out + 1] = "ERR " .. r.err end      -- never read as an empty bank
    return table.concat(out, " ")
end

local gseq = 0                       -- every recorded event's number, across visits
local armed                         -- { seq = n }: set as the owner leaves a trial's Open step

local function Event(v, kind, text, read)
    gseq = gseq + 1
    v.seq = gseq
    local e = { seq = gseq, f = frameNo, t = GetTime(), kind = kind, text = text, read = read }
    v.events[#v.events + 1] = e
    return e
end

local function Save(s)
    if type(AltStableProbeDB) ~= "table" then return end
    AltStableProbeDB.bankclose = AltStableProbeDB.bankclose or {}
    local list = AltStableProbeDB.bankclose
    list[#list + 1] = s
    while #list > KEEP do table.remove(list, 1) end
end

-- After the window: the order, whether the move's batch ended before the
-- close, and every read against the open's, as saved lines.
local function Finish(v)
    local open = v.baseline or (v.events[1] and v.events[1].read)
    local order, reads = {}, {}
    local lastTabUpdate, closedSeq, delayedBefore, closeRead, lastRead, delayedRead
    local preCloseDelayedRead, oneSecondRead
    local t0 = v.events[1] and v.events[1].t or 0
    -- Only what happened after the trial was armed (the owner left the Open
    -- step, so the opening's own updates have settled) counts as the move.
    local from = v.armedSeq or 0
    for _, e in ipairs(v.events) do
        order[#order + 1] = ("%d:f%d:+%.3fs %s%s"):format(e.seq, e.f - v.openFrame, e.t - t0, e.kind,
                                                       e.text ~= "" and ("(" .. e.text .. ")") or "")
        if e.kind == "CLOSED" then closeRead = e.read end
        if e.kind == "CLOSED+1s" then oneSecondRead = e.read end
        if e.read then lastRead = e.read end
        -- The last BAG_UPDATE_DELAYED between Ready and the close: what a scan
        -- on that event would have saved, whatever the order around it.
        if e.kind == "DELAYED" and not closedSeq and e.seq > from then preCloseDelayedRead = e.read end
        if e.kind == "BAG_UPDATE" and e.text:find("tab") and not closedSeq and e.seq > from then
            lastTabUpdate, delayedBefore, delayedRead = e.seq, nil, nil   -- a new update: its batch has to end again
        end
        if e.kind == "CLOSED" then closedSeq = e.seq end
        if e.kind == "DELAYED" and not closedSeq and lastTabUpdate and e.seq > lastTabUpdate then
            delayedBefore, delayedRead = e.seq, e.read
        end
        if e.read and open then reads[#reads + 1] = ("%d %s: %s"):format(e.seq, e.kind, Summarise(open, e.read)) end
    end
    local s = {
        visit = v.id, when = v.when, closeFrames = v.closeFrame and (v.closeFrame - v.openFrame) or nil,
        nextFrameDelta = v.nextFrameDelta,
        delayedBeforeClose = (not lastTabUpdate)
            and (v.armedSeq and "no bank-tab update after the trial was armed" or "no bank-tab update while open")
            or (delayedBefore ~= nil),
        armed = v.armedSeq ~= nil,
        order = table.concat(order, ", "), reads = reads,
        interrupted = v.interrupted or nil,       -- reopened inside the window: cut short
        openTotals = open and Totals(open) or nil,
        closeTotals = closeRead and Totals(closeRead) or nil,
        lastTotals = lastRead and Totals(lastRead) or nil,
        baselineTotals = open and Totals(open) or nil,
        -- The reads graded against the next visit's settled baseline
        -- (CheckPrevious): the last pre-close DELAYED, the one inside the
        -- close, the CLOSED+1s sample. Each with whether it read whole.
        delayedTotals = preCloseDelayedRead and Totals(preCloseDelayedRead) or nil,
        delayedWhole = preCloseDelayedRead and Whole(preCloseDelayedRead) or nil,
        closeWhole = closeRead and Whole(closeRead) or nil,
        oneSecondTotals = oneSecondRead and Totals(oneSecondRead) or nil,
        oneSecondWhole = oneSecondRead and Whole(oneSecondRead) or nil,
        baselineWhole = open and Whole(open) or nil,
    }
    v.summary, v.done = s, true
    lastFinished = v
    Save(s)
    Probe:Say(("[bank] visit %d done: DELAYED after the last bank-tab update, before the close: %s"):format(
        v.id, tostring(s.delayedBeforeClose)))
    Probe:Say("[bank]   order: " .. s.order)
    for _, line in ipairs(reads) do Probe:Say("[bank]   " .. line) end
end

local function Live(v) return v and not v.done and (not v.closedAt or GetTime() - v.closedAt <= WINDOW) end

local f = CreateFrame("Frame")
Probe:RegisterEvents(f, { "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE", "BAG_UPDATE_DELAYED",
                          "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED", "ITEM_LOCK_CHANGED",
                          "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" })
f:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "BANKFRAME_OPENED" then
        -- Reopened inside the window: the old visit ends here, cut short, and
        -- its pending reads are skipped (they would read this new visit).
        if current and not current.done then
            current.interrupted = not current.closedAt or GetTime() - current.closedAt <= WINDOW
            Finish(current)
        end
        visitNo = visitNo + 1
        local v = { id = visitNo, events = {}, openFrame = frameNo, when = date("%H:%M:%S"), tabs = Tabs() }
        current, recentVisit = v, v
        Event(v, "OPENED", "", Read(v.tabs))
        Probe:Say(("[bank] visit %d opened, tabs %s"):format(v.id, v.tabs and table.concat(v.tabs, ",") or "none"))
        return
    end
    local v = current
    if not Live(v) then return end
    local open = not v.closedAt

    if event == "BAG_UPDATE" then
        local bag = tonumber(arg1)
        local isTab = IsIn(bag, v.tabs)
        Event(v, "BAG_UPDATE", tostring(arg1) .. (isTab and " tab" or " carried") .. (open and "" or " after close"),
              isTab and Read(v.tabs) or nil)
    elseif event == "BAG_UPDATE_DELAYED" then
        Event(v, "DELAYED", open and "" or "after close", Read(v.tabs))
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        Event(v, "SLOTS", tostring(arg1) .. (open and "" or " after close"), Read(v.tabs))
    elseif event == "ITEM_LOCK_CHANGED" then
        Event(v, "LOCK", tostring(arg1) .. ":" .. tostring(arg2))
    elseif event == "BANK_TABS_CHANGED" then
        Event(v, "TABS", tostring(arg1))
    elseif event == "BANKFRAME_CLOSED" then
        Event(v, "CLOSED", "", Read(v.tabs))
        v.closedAt, v.closeFrame = GetTime(), frameNo
        if armed and not armed.visit and v.id >= (armed.minVisit or 0) then
            armed.visit, v.armedSeq = v, armed.seq
        end
        local closeFrame = frameNo
        C_Timer.After(0, function()
            if v.done then return end
            v.nextFrameDelta = frameNo - closeFrame
            Event(v, "CLOSED+0", "frames+" .. v.nextFrameDelta, Read(v.tabs))
        end)
        C_Timer.After(1, function() if not v.done then Event(v, "CLOSED+1s", "", Read(v.tabs)) end end)
        C_Timer.After(WINDOW + 0.1, function() if not v.done then Finish(v) end end)
    else
        Event(v, event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and "PIM_SHOW" or "PIM_HIDE", tostring(arg1))
    end
end)

-- The newest finished visit, as one line for a step's result.
local function Line(s)
    if not s then return "no visit recorded yet" end
    return ("visit %d%s: DELAYED before close=%s; close after %s frames; After(0)=+%s frames; order: %s; "
            .. "reads: %s; totals baseline=[%s] delayed=[%s] close=[%s] last=[%s]"):format(
        s.visit, s.interrupted and " (INTERRUPTED by a reopen)" or "", tostring(s.delayedBeforeClose),
        tostring(s.closeFrames), tostring(s.nextFrameDelta), s.order, table.concat(s.reads, " | "),
        tostring(s.baselineTotals), tostring(s.delayedTotals), tostring(s.closeTotals), tostring(s.lastTotals))
end

local reported = 0
-- A trial is armed as the owner leaves its Open step: the visit open then
-- (or, if the bank's own event comes later, the next one) is the trial's, and
-- only events after this point count as its move. Ordinary banking before the
-- procedure, or another visit in between, never answers for it.
-- The truth for the visit before `v` is v's settled baseline (the bank after
-- that trial's move, read once things settled): did each of the earlier
-- visit's candidate reads see it? This, not the event order alone, says which
-- read #419 can trust (Codex round 6). Saved on the earlier visit's summary.
local function CheckPrevious(v)
    local prev = lastFinished and lastFinished ~= v and lastFinished.summary
    if not prev or not v.baseline then return end
    local truth = Totals(v.baseline)
    -- The untouched control stack is the proof the reference read the bank's
    -- contents at all: a read with slot counts but no items is "whole" and
    -- "changed", and would grade an equally blank close read as right (Codex
    -- round 8). At least one slot of the earlier baseline must read the same.
    local kept = 0
    local before = lastFinished.baseline
    for key, w in pairs(before and before.at or {}) do
        local x = v.baseline.at[key]
        if x and x[1] == w[1] and x[2] == w[2] then kept = kept + 1 end
    end
    local why
    if not Whole(v.baseline) then why = "inconclusive: this visit's baseline did not read whole"
    elseif not prev.baselineWhole then why = "inconclusive: that visit's baseline did not read whole"
    elseif kept == 0 then why = "inconclusive: the reference lost the control stack"
    elseif prev.baselineTotals == truth then why = "inconclusive: the move did not change the bank" end
    -- A graded read is right only when it read whole and matches the truth.
    local function grade(totals, whole, missing)
        if why then return why end
        if not totals then return missing end
        if not whole then return false end
        return totals == truth
    end
    prev.delayedRight = grade(prev.delayedTotals, prev.delayedWhole, "no pre-close DELAYED read")
    prev.closeRight = grade(prev.closeTotals, prev.closeWhole, "no read inside the close")
    prev.lastRight = grade(prev.oneSecondTotals, prev.oneSecondWhole, "no 1 s sample (cut short?)")
    -- What the reference itself says moved, slot by slot, against the earlier
    -- baseline: a grade holds only when this is exactly the trial's
    -- prescribed move (A: one stack down by the 5 taken; no other slot
    -- changed). A reference that misread the moved slot alone passes the
    -- guards above, so the session reading the results checks this line
    -- before trusting a grade (Codex round 9).
    prev.referenceMove = before and Summarise(before, v.baseline) or nil
    prev.checkedAgainst = { visit = v.id, totals = truth }
    Probe:Say(("[bank] visit %d checked against visit %d's baseline: DELAYED read right=%s, close read "
               .. "right=%s, 1 s read right=%s"):format(prev.visit, v.id, tostring(prev.delayedRight),
               tostring(prev.closeRight), tostring(prev.lastRight)))
end

local function Arm()
    armed = { seq = gseq, minVisit = (current and not current.closedAt) and current.id or visitNo + 1 }
    if current and not current.closedAt and current.id >= armed.minVisit then
        -- The settled baseline: the tab list and the bank read again now, when
        -- the opening's slot counts have had time to arrive.
        current.tabs = Tabs() or current.tabs
        current.baseline = Read(current.tabs)
        Event(current, "READY", "", current.baseline)
        current.armedSeq = gseq
        armed.seq = gseq
        CheckPrevious(current)
    end
    trial = armed
end

-- A wait step: done once the armed trial's visit has finished. Reported once.
local function VisitDone()
    local v = trial and trial.visit
    if v and v.done then
        trial, armed = nil, nil
        reported = v.id
        return true, Line(v.summary)
    end
    return false, v and ("visit " .. v.id .. " still recording") or "the trial's close not seen yet"
end

NS.BankClose = { Read = Read, Summarise = Summarise, Totals = Totals, VisitDone = VisitDone, Arm = Arm,
                 Recent = function() return recentVisit end }

Probe:Command("bankclose", function()
    Probe:Say("[bank] " .. Line(recentVisit and recentVisit.summary))
end, "the newest bank visit: event order, and every read against the open's")

local function Trial(text)
    return { text = text, event = "BANKFRAME_CLOSED" }
end
local function Report()
    return { text = "Recording the 3 s after the close...", wait = VisitDone, timeout = 20 }
end
local function Open(text)
    return { text = text or "Open the bank again.", event = "BANKFRAME_OPENED" }
end
-- Pressing Next here arms the trial that follows: the bank's own opening
-- updates have settled by the time a person presses a button, so only what
-- happens after this counts as the trial's move.
local function Ready()
    return { text = "The bank is open. Read the next step, then press Next and do it at once.",
             leave = function(outcome) if outcome == "done" then Arm() end end }
end

Probe:Steps("bankclose", {
    title = "Bank: a move, then a quick close (#419)",
    rev = 11,
    { text = "Stand at your banker. In the bank you need: one stack of 10 or more, three more stacks of "
          .. "anything, one more stack you will NOT touch at all (the control), and ONE EMPTY bank slot. In "
          .. "your bags: room for five stacks, and one stack to deposit of an item the control is not. "
          .. "Don't open the bank yet. Press Next." },
    Open("Open the bank."),
    Ready(),
    Trial("A. PART OF A STACK, then ESCAPE: shift-click a stack of 10+ in the bank, take exactly 5, click "
       .. "an empty bag slot to drop them, and press Escape straight after."),
    Report(),
    Open(),
    Ready(),
    Trial("B. DEPOSIT, then the CLOSE BUTTON: first type the item and its count in the Note box below "
       .. "(e.g. \"Linen Cloth 12\") and press Enter. Then drag that stack from your bags onto the EMPTY bank "
       .. "slot, and click the bank window's close button (X) straight after."),
    Report(),
    Open(),
    Ready(),
    Trial("C. WITHDRAW, then WALK AWAY: right-click another bank stack (not the control) so it goes to "
       .. "your bags, then walk away at once until the bank closes."),
    Report(),
    Open(),
    Ready(),
    Trial("D. DRAG, then ESCAPE: drag another bank stack (not the control) onto an empty bag slot, then "
       .. "press Escape straight after."),
    Report(),
    Open(),
    Ready(),
    Trial("E. SLOW CLOSE: right-click the last movable bank stack (not the control) so it goes to your bags, "
       .. "WAIT 3 SECONDS, then press Escape."),
    Report(),
    Open("Open the bank once more: its counts now are read as the final state."),
    Ready(),
    { text = "Now close the bank (any way).", event = "BANKFRAME_CLOSED" },
    Report(),
    { text = "Done. /reload so the results are saved.", reload = true },
})
