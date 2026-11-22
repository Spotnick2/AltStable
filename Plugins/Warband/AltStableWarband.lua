------------------------------------------------------------
-- AltStableWarband — consolidated cross-alt bag + bank + mail inventory (P3, #312).
--
-- A single "Warband bank"-style grid of every item across all tracked
-- characters (bags + bank), each unique item shown once as a stack with its
-- total count, grouped by item type, with a search that dims non-matches in
-- place and a per-item tooltip listing which alt holds how many.
--
-- We capture + sync our OWN data (not another addon's SavedVariables) so the
-- other account's characters merge in over AltStable's transport.
--
-- Persistence (plugin-owned; kept out of the core AltStableDB record):
--   AltStableWarbandDB[guid] = {
--       bags = { [itemID] = count },   -- summed across the carried bags + keyring
--       bank = { [itemID] = count },   -- summed across the purchased bank tabs
--       mail = { [itemID] = count },   -- the inbox at the last mailbox visit (#312)
--       mailMore,                      -- mails the game held back (50 shown at a time)
--       outbox = { { to = guid, at = time, items = { [itemID] = count } } },
--                                      -- mail sent/returned to our own characters
--       bagsStamp, bankStamp, mailStamp, outboxStamp,  -- when each section last changed
--       stamp = max of those           -- drives the delta watermark
--   }
-- bags and bank are SEPARATE maps: bags refresh live on BAG_UPDATE, but the
-- bank is only readable while its frame is open, so a bag rescan must never
-- clobber the (intentionally stale) bank snapshot.
--
-- What a received blob may and may not do (docs/AUDIT.md):
--   * an older stamp is refused; an equal one applies only when the maps differ;
--   * a bank the owner has never read (kt=0) leaves a held snapshot alone;
--   * the blob is judged by these stamps alone (independentStamp), not by the
--     record carrying it: a newer bank inside an older record still lands;
--   * the bank has its own stamp (kt=): an older bank, or one with no kt=
--     (unknown age, stored as 0), never replaces a dated one, whatever the
--     overall stamp says (#420). Mixed versions: an older client still
--     replaces it, so two clients can hold different banks until the owner
--     publishes a newer kt= that both accept (a bank change, or a visit once
--     visits restamp, #432) - each swap needs more sync traffic, nothing loops;
--   * two moves in one second relayed out of order keep the later-arriving
--     map until the next change: one-second stamps carry no order (declared);
--   * inventory whose character record is gone is kept, invisible, until that
--     character is forgotten or the database cleaned up: the login never
--     deletes it, so a loss of AltStable.lua does not take this file with it.
--     The other plugins follow the same rule (#418, Core.lua "Plugin records
--     whose character the core has no record of").
------------------------------------------------------------

AltStableWarbandDB = AltStableWarbandDB or {}

local ADDON_ID     = "warband"
local BLOB_VERSION = "v1"

local BANK_STALE = 7 * 86400   -- flag a bank snapshot as "may be out of date" past this

------------------------------------------------------------
-- Which containers to read
--
-- Every Classic constant this plugin used is wrong on Forever: -1 is the
-- KEYRING (not the main bank), -2 and -3 are bank-TYPE pseudo-ids that hold
-- nothing, and 5 is the carried reagent bag. Measured ids live in Enum.BagIndex
-- and are read through the adapter (see "Container identity" in Compat.lua).
--
-- The bank is not a fixed range either: tabs are bought one at a time, so the
-- set is whatever C_Bank reports as purchased - Character tabs only. An account
-- bank exists in the API but is not viewable on this build; folding its tabs
-- into each character's map would count the same shared items once per alt.
------------------------------------------------------------

local function CarriedBagIDs()
    local ids = AltStable.API.GetCarriedBagIDs()
    if not ids then return nil end
    -- The keyring rides along with the bags so keys are findable too.
    local keyring = AltStable.API.GetKeyringBagID()
    if keyring then
        local out = { keyring }
        for _, id in ipairs(ids) do out[#out + 1] = id end
        return out
    end
    return ids
end

-- nil (not {}) when the bank tabs can't be enumerated, so a failed read aborts
-- the scan instead of recording an empty bank over a good snapshot.
--
-- Cached: BAG_UPDATE fires several times a second while questing and each one
-- asks whether the bag is a bank tab. The set only changes when a tab is
-- bought, which happens at the bank - so every bank session re-reads it. Only
-- a success is cached ({} included): a failed enumeration is asked again, so
-- the next read in the same visit can recover (#419).
local tabCache
local function BankTabIDs()
    if tabCache == nil then tabCache = AltStable.API.GetCharacterBankTabIDs() end
    return tabCache
end

local function InvalidateTabCache()
    tabCache = nil
end

local function IsBankContainer(bag)
    local tabs = BankTabIDs()
    if not tabs then return false end
    for _, id in ipairs(tabs) do if id == bag then return true end end
    return false
end

local AT_WB = { cells = {}, isActive = false, search = "" }

-- Bank-session state for the transactional bank scan.
local isBankOpen  = false
local bankDirty   = false   -- a bank change (or the open) not yet read (#419)
local bankGen     = 0
local bagsPending = false
local bankPending = false

-- Async item metadata we've asked the client to load (re-render on arrival).
local requestedIDs = {}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Warband]|r " .. msg)
end

------------------------------------------------------------
-- Retail-API adapters; see Compat.lua. GetContainerItemInfo returns a STRUCT
-- here, not the old positional tuple - reading `stackCount` off return 2 would
-- store nil counts for every slot.
------------------------------------------------------------

local CGetNumSlots = AltStable.API.GetContainerNumSlots
local CGetItemID   = AltStable.API.GetContainerItemID
local CGetItemLink = AltStable.API.GetContainerItemLink
local CGetItemInfo = AltStable.API.GetContainerItemInfo

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- Read one slot. Returns:
--   itemID, count   for an occupied, well-formed slot
--   nil             for an empty slot
--   nil, "bad"      occupied but the count is unreadable (caller aborts the scan)
local function ReadSlot(bag, slot)
    local itemID
    if CGetItemID then itemID = CGetItemID(bag, slot) end
    if not itemID or itemID == 0 then
        itemID = ItemIDFromLink(CGetItemLink and CGetItemLink(bag, slot))
    end
    if not itemID or itemID == 0 then return nil end

    local count
    if CGetItemInfo then
        local info = CGetItemInfo(bag, slot)
        count = type(info) == "table" and info.stackCount or nil
    end
    count = tonumber(count)
    if not count or count < 1 then return nil, "bad" end
    return itemID, count
end

-- Sum a set of containers into { [itemID] = count }. Returns nil if any
-- occupied slot is unreadable, so a mid-transition scan aborts instead of
-- recording garbage.
-- `slotsOf(bag)`, when given, says how many slots to read, 0 for a container
-- that is legitimately empty, or nil when it isn't loaded yet: then the whole
-- read is nil, and nothing is recorded (#439).
local function ScanContainerSet(ids, slotsOf)
    if not CGetNumSlots or not ids then return nil end
    local map = {}
    for _, bag in ipairs(ids) do
        local n
        if slotsOf then
            n = slotsOf(bag)
            if n == nil then return nil end
        else
            n = CGetNumSlots(bag)
        end
        if n and n > 0 then
            for slot = 1, n do
                local id, count = ReadSlot(bag, slot)
                if id then
                    map[id] = (map[id] or 0) + count
                elseif count == "bad" then
                    return nil
                end
            end
        end
    end
    return map
end

local function mapsEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function GetDB(guid)
    AltStableWarbandDB[guid] = AltStableWarbandDB[guid] or {}
    return AltStableWarbandDB[guid]
end

-- The record's watermark is the newest of its sections.
local function Restamp(db)
    db.stamp = math.max(db.bagsStamp or 0, db.bankStamp or 0, db.mailStamp or 0, db.outboxStamp or 0)
end

-- Commit a freshly-built section map for the current player, but only if it
-- actually changed — otherwise cosmetic BAG_UPDATEs would churn the sync.
-- `confirm`: this read confirms the section (the session's first bag scan, a
-- bank visit's first complete read), so even an unchanged map is restamped:
-- the stamp then says when the map was last seen right, which is what lets it
-- refuse an older reading from another PC (Codex review of #438) and what the
-- freshness label reads (#432). Any other unchanged read is nothing to record,
-- or cosmetic BAG_UPDATEs would churn the sync. A map with no stamp (a bank of
-- unknown age received for our own character, #420) is dated by any read.
local function ApplyScan(sectionKey, stampKey, newMap, confirm)
    if not newMap then return false end
    local guid = UnitGUID("player")
    if not guid then return false end
    local db = GetDB(guid)
    if mapsEqual(db[sectionKey], newMap) and (db[stampKey] or 0) > 0 and not confirm then return true end

    db[sectionKey] = newMap
    db[stampKey]   = time()
    Restamp(db)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AT_WB.isActive and AT_WB.RequestRefresh then AT_WB.RequestRefresh() end
    return true
end

local bagsConfirmed = false      -- this session's first bag read has confirmed them
local bankConfirm = false        -- the open bank visit's first complete read is still to come

-- The carried bags by Core's readiness rule (the backpack or a bag at 0 slots
-- is not loaded yet; an empty bag slot is nothing), the keyring as before: it
-- has no bag slot to ask about. Returns whether the bags were read.
local function CarriedSlots(bag)
    if bag == AltStable.API.GetKeyringBagID() then
        return (CGetNumSlots and tonumber(CGetNumSlots(bag))) or 0
    end
    return AltStable.API.CarriedContainerSlots(bag)
end

local function ScanBags()
    if ApplyScan("bags", "bagsStamp", ScanContainerSet(CarriedBagIDs(), CarriedSlots), not bagsConfirmed) then
        bagsConfirmed = true
        return true
    end
    return false
end

-- Transactional bank scan. A genuinely emptied bank MUST be allowed to replace
-- a non-empty snapshot, so we never gate on "candidate is empty". The bank is
-- only readable while open, so we require isBankOpen; a scan whose bank session
-- ended before it ran is blocked at SCHEDULE time via the generation counter
-- (see ScheduleBank), not here — an in-flight synchronous scan can't have its
-- own generation change under it.
--
-- Readiness is now per tab: the purchased list is authoritative, so a character
-- who owns tabs whose slot counts have not arrived yet is not ready, while one
-- who owns none legitimately has an empty bank. (Which is why the old
-- MAIN_BANK slot-count gate is gone along with the constant.)
--
-- A purchased bag slot with no bag reports 0 slots: that is nothing, not "not
-- ready" (#439: it aborted every read of such a bank). The main bank at 0, or a
-- slot holding a bag at 0, is still "not ready" (Compat's BankContainerSlots).
-- Returns whether the bank was read.
local function ScanBank()
    if not isBankOpen then return false end
    local tabs = BankTabIDs()
    if not tabs then return false end             -- can't enumerate: not ready
    local candidate = ScanContainerSet(tabs, AltStable.API.BankContainerSlots)
    if not candidate then return false end        -- not loaded, or malformed mid-transition: abort
    if ApplyScan("bank", "bankStamp", candidate, bankConfirm) then
        bankConfirm, bankDirty = false, false
        return true
    end
    return false
end

local function ScheduleBags()
    if bagsPending then return end
    bagsPending = true
    C_Timer.After(1, function() bagsPending = false; ScanBags() end)
end

-- Debounced, and tied to the CURRENT bank session: a scan is dropped when the
-- bank closed before it fired, but a close-then-reopen inside the window must
-- not lose the new session's scan. So a pending timer is re-pointed at the
-- newest generation rather than the request being dropped.
local pendingBankGen
local function ScheduleBank()
    pendingBankGen = bankGen
    if bankPending then return end
    bankPending = true
    C_Timer.After(1, function()
        bankPending = false
        if pendingBankGen == bankGen and isBankOpen then ScanBank() end
    end)
end

-- Read the bags and the bank together, while the bank is certainly readable
-- (#419): at the end of a batch that changed it (BAG_UPDATE_DELAYED, which the
-- probe measured in the SAME frame as the move's bank update), and inside
-- BANKFRAME_CLOSED (measured still readable; one frame later it reports 0
-- slots everywhere). The bags first, so both sides of a move are published
-- together. Bags that can't be read yet keep the bank read and get the 1 s bag
-- timer, which needs no bank (Codex review).
local function ReadBankPass()
    local bagsRead = ScanBags()
    ScanBank()
    if not bagsRead then ScheduleBags() end
end

------------------------------------------------------------
-- Mail (#312): what waits in each character's mailbox
--
-- The inbox is readable only while a mailbox is open, so a character's mail is
-- as old as its last visit, like its bank. It is read once the inbox arrives
-- (the first MAIL_INBOX_UPDATE after MAIL_SHOW), again whenever it changes
-- while open (an attachment taken: MAIL_INBOX_UPDATE, a bag update), and once
-- at close. Each read replaces the whole map, so what was taken or deleted goes.
-- The close is PLAYER_INTERACTION_MANAGER_FRAME_HIDE with MailInfo (17):
-- MAIL_CLOSED never fired on Forever in about ten closes and a logout at the
-- mailbox (GlassMail docs/FOREVER-PROBE.md, session 2; Codex review of #313).
--
-- Every visit is recorded at least twice, at its first read and at its close,
-- even when the inbox looks the same: the read's time is what tells a send that
-- the recipient has seen it (below), and the send may only reach this account
-- after the read, from another one. Between those, an unchanged read is not
-- recorded, so a visit doesn't churn the sync (Codex review of #313).
--
-- The game shows 50 mails at a time; GetInboxNumItems' second return is how
-- many there are. The rest can't be read until some are cleared, so a read
-- keeps how many it could not see (mailMore) and the tooltip says so.
--
-- The inbox is read through LibMailbox-1.0 (embedded by AltStable, shared with
-- GlassMail; #326), looked up each time, never captured: a newer copy another
-- addon embeds replaces the functions on the same table. A read is taken only
-- when the library is ready and its scan is whole: every header row back,
-- nothing withheld as a secret, every attachment with its link (GlassMail's
-- probe saw a link for every attachment, cached or not). Anything less keeps
-- the last good read. Currency attachments are not items.
--
-- Mail sent or returned to one of your own characters counts as soon as it
-- leaves: players mostly fill an alt's mailbox from another alt, and without
-- this the items would vanish from search until the alt's next visit. It is
-- kept on the SENDER's record (outbox), never written into the recipient's:
-- each character writes only its own record, which sync ownership relies on.
-- An entry counts for its recipient while it is newer than that character's
-- last inbox read (the read sees the mail itself) and less than 30 days old
-- (by then unopened mail has been returned or deleted).
--
-- Measured on Forever (References PORTING-TBC-TO-FOREVER.md, "Mail"): the send
-- draft is still filled at the SendMail post-hook and cleared by
-- MAIL_SEND_SUCCESS, so the attachments are read in the hook and committed on
-- success; a ReturnInboxItem post-hook still finds the mail at its index. A
-- recipient is "First Surname" (a first name alone is refused by the server).
--
-- warbandMail (Options): on unless set to false. Off reads, records, shows and
-- sends no mail; what is held stays, for when it is switched back on.
------------------------------------------------------------

local SEND_ATTACHMENTS  = 12          -- ATTACHMENTS_MAX_SEND
local OUTBOX_TTL        = 30 * 86400

local function MailOn()
    return not (AltStableConfig and AltStableConfig.warbandMail == false)
end

local isMailOpen, inboxReady, mailPending = false, false, false
local visitStamped = false   -- this visit's first read is recorded
local pendingSend   -- { to = guid, items = map }, from the SendMail post-hook

-- The library, or nil when it isn't there or a newer copy failed half-way.
local function Mailbox()
    local stub = rawget(_G, "LibStub")
    local LM = stub and stub("LibMailbox-1.0", true)
    if LM and LM.Ready and LM.Ready() then return LM end
end

-- A scanned mail's attachments, summed by item id into `map`. False when the
-- mail can't be counted: withheld, not read whole, or a count that isn't one.
local function AddMailItems(m, map)
    if m.secret or not m.resolved then return false end
    for _, it in ipairs(m.items) do
        local id = tonumber(it.itemID)
        if id and id > 0 and not it.isCurrency then
            local count = tonumber(it.count)
            if not count or count < 1 then return false end
            map[id] = (map[id] or 0) + count
        end
    end
    return true
end

-- The loaded mails' attachments as { [itemID] = count }, and how many mails the
-- game holds back; nil when the inbox can't be read whole (yet).
local function ReadInbox()
    local LM = Mailbox()
    if not LM then return nil end
    local scan = LM.ScanInbox()
    -- resolved: every row back, none withheld, every attachment with its link.
    if not scan.resolved then return nil end
    local map = {}
    for _, m in ipairs(scan.mails) do
        if not AddMailItems(m, map) then return nil end
    end
    return map, math.max(0, (tonumber(scan.total) or 0) - (tonumber(scan.loaded) or 0))
end

-- One of our characters, from a mail's "First Surname" or "First Surname-Realm".
-- Names are unique region-wide on Forever, so the name decides; the realm only
-- settles a tie a database could still hold. nil when it is no one of ours.
local function OwnCharacterGuid(who)
    if type(who) ~= "string" then return nil end
    local name, realm = who:match("^%s*([^%-]-)%s*%-%s*(.-)%s*$")
    if not name then name, realm = who:match("^%s*(.-)%s*$"), "" end
    if name == "" then return nil end
    name = name:lower()
    local function norm(s) return (tostring(s or ""):gsub("[%s%-']", "")):lower() end
    local found, n = nil, 0
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and type(c.name) == "string" and c.name:lower() == name then
            if realm ~= "" and norm(c.realm) == norm(realm) then return guid end
            found, n = guid, n + 1
        end
    end
    return n == 1 and found or nil
end

-- An outbox entry still counts for its recipient: newer than the recipient's
-- last inbox read, and not yet returned or deleted by the game.
local function EntryLive(e, now)
    if type(e) ~= "table" or not e.to or not e.at then return false end
    local to = AltStableWarbandDB[e.to]
    local read = (type(to) == "table" and to.mailStamp) or 0
    return e.at > read and now - e.at <= OUTBOX_TTL
end

-- Items on their way to each character: { [guid] = { [itemID] = count } }.
-- Not from a sender the core has no record of (an orphan, #418): its other
-- sections are invisible, and so is what it sent.
local function Incoming()
    local out, now = {}, time()
    for sender, wb in pairs(AltStableWarbandDB) do
        if type(wb) == "table" and type(wb.outbox) == "table"
           and (not AltStable.HasNamedRecord or AltStable.HasNamedRecord(sender)) then
            for _, e in ipairs(wb.outbox) do
                if EntryLive(e, now) then
                    local m = out[e.to] or {}
                    out[e.to] = m
                    for id, n in pairs(e.items or {}) do m[id] = (m[id] or 0) + n end
                end
            end
        end
    end
    return out
end

local function Touch(guid)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AT_WB.isActive and AT_WB.RequestRefresh then AT_WB.RequestRefresh() end
end

-- A read is recorded when it changed something, or when it is the visit's
-- first or its last (`final`, the close): each must stop the sends it has seen
-- counting, or a taken item would count twice, in the bags and still "in the
-- mail". A send taken mid-visit with nothing else changed counts until the close.
local function ScanMail(final)
    if not MailOn() or not isMailOpen or not inboxReady then return end
    local guid = UnitGUID("player")
    if not guid then return end
    local map, more = ReadInbox()
    if not map then return end
    local db = GetDB(guid)
    if visitStamped and not final and db.mailStamp
       and mapsEqual(db.mail, map) and (db.mailMore or 0) == more then
        return
    end
    visitStamped = true
    db.mail, db.mailMore, db.mailStamp = map, more, time()
    Restamp(db)
    Touch(guid)
end

local function ScheduleMail()
    if mailPending then return end
    mailPending = true
    C_Timer.After(0.5, function() mailPending = false; ScanMail() end)
end

local function OnMailShow()
    isMailOpen, inboxReady, visitStamped = true, false, false
end

local function OnMailInboxUpdate()
    if not isMailOpen then return end
    inboxReady = true
    ScheduleMail()
end

-- Idempotent: a scan queued for this visit finds the mailbox closed and reads
-- nothing.
local function OnMailClosed()
    if isMailOpen and inboxReady then ScanMail(true) end
    isMailOpen, inboxReady = false, false
end

local function OnInteractionHide(kind)
    local mailInfo = (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo) or 17
    if kind == mailInfo then OnMailClosed() end
end

-- Entries the recipient has since read, or the game has since returned or
-- deleted, go when the sender's outbox next changes.
local function PruneOutbox(db, now)
    if type(db.outbox) ~= "table" then return end
    local keep = {}
    for _, e in ipairs(db.outbox) do
        if EntryLive(e, now) and AltStableDB and AltStableDB[e.to] then keep[#keep + 1] = e end
    end
    db.outbox = (#keep > 0) and keep or nil
end

-- Callers have checked the mail setting.
local function RecordOutgoing(to, items)
    if not to or not next(items) then return end
    local guid = UnitGUID("player")
    if not guid or guid == to then return end
    local db, now = GetDB(guid), time()
    PruneOutbox(db, now)
    db.outbox = db.outbox or {}
    db.outbox[#db.outbox + 1] = { to = to, at = now, items = items }
    db.outboxStamp = now
    Restamp(db)
    Touch(guid)
end

local function OnSendMail(recipient)
    pendingSend = nil
    if not MailOn() or not GetSendMailItem then return end
    local to = OwnCharacterGuid(recipient)
    if not to then return end
    local items = {}
    for i = 1, SEND_ATTACHMENTS do
        local _, id, _, count = GetSendMailItem(i)
        id, count = tonumber(id), tonumber(count)
        if id and id > 0 and count and count > 0 then items[id] = (items[id] or 0) + count end
    end
    if next(items) then pendingSend = { to = to, items = items } end
end

local function OnMailSendSuccess()
    local p = pendingSend
    pendingSend = nil
    if p then RecordOutgoing(p.to, p.items) end
end

local function OnMailFailed()
    pendingSend = nil
end

-- Returning a mail sends it back to whoever sent it. The post-hook still finds
-- the mail at its index (measured); the library has no one-mail read, so this
-- scans the inbox, a click at a time.
local function OnReturnInboxItem(index)
    if not MailOn() then return end
    local LM = Mailbox()
    if not LM then return end
    for _, m in ipairs(LM.ScanInbox().mails) do
        if m.index == index then
            local to = OwnCharacterGuid(m.sender)
            local items = {}
            if to and AddMailItems(m, items) then RecordOutgoing(to, items) end
            return
        end
    end
end

local function InstallMailHooks()
    if AT_WB._mailHooked then return end
    AT_WB._mailHooked = true
    -- Post-hooks: an error here must never surface from Blizzard's own send.
    if type(SendMail) == "function" then
        hooksecurefunc("SendMail", function(recipient) pcall(OnSendMail, recipient) end)
    end
    if type(ReturnInboxItem) == "function" then
        hooksecurefunc("ReturnInboxItem", function(index) pcall(OnReturnInboxItem, index) end)
    end
end

------------------------------------------------------------
-- Event routing
------------------------------------------------------------

local function OnBagUpdate(bag)
    -- An attachment taken lands in the bags while the mailbox is open.
    if isMailOpen and inboxReady then ScheduleMail() end
    bag = tonumber(bag)
    if bag and IsBankContainer(bag) then
        -- A bank-tab change while open: read at the batch's end (below), with
        -- the 1 s timer as the fallback.
        if isBankOpen then bankDirty = true; ScheduleBank() end
        return
    end
    ScheduleBags()   -- carried bags / keyring (or a nil/unspecified bag)
end

-- The end of a batch of bag updates: the bank read now, if it changed.
local function OnBagUpdateDelayed()
    if isBankOpen and bankDirty then ReadBankPass() end
end

local function OnBankOpened()
    isBankOpen = true
    bankConfirm = true
    InvalidateTabCache()   -- a tab may have been bought since the last session
    bankGen = bankGen + 1
    bankDirty = true       -- until a read succeeds, so the next batch's end retries
    ScanBank()          -- immediate...
    ScheduleBank()      -- ...plus a follow-up in case slot counts aren't ready yet
end

-- A tab bought without closing the bank: its BAG_UPDATE would be classified as
-- a carried bag (the cached list predates it) and ScanBank would keep reading
-- the old tabs. BANK_TABS_CHANGED carries the bank type, so only ours counts.
local function OnBankTabsChanged(bankType)
    if Enum and Enum.BankType and bankType ~= nil and bankType ~= Enum.BankType.Character then
        return
    end
    InvalidateTabCache()
    if isBankOpen then bankDirty = true; ScanBank(); ScheduleBank() end
end

-- The last read, inside the close: the bank still reads right here, and not a
-- frame later (#419). The bags too, always: a move's carried update can come
-- in the batch after the bank's. Then the visit ends.
local function OnBankClosed()
    if isBankOpen then ReadBankPass() end
    isBankOpen, bankDirty = false, false
    InvalidateTabCache()
    bankGen = bankGen + 1   -- invalidate any in-flight scheduled scan
end

------------------------------------------------------------
-- Sync — compact, single-line, no "\n". Only itemID+count integers ride the
-- wire (item links are reconstructed client-side, like the core gear scan).
--   v1|s=<stamp>|kt=<bankStamp>|bt=<bagsStamp>|b=id,count;id,count|k=id,count;...
--     [|mt=<mailStamp>|mm=<mails unread>|m=id,count;...|ot=<outboxStamp>|o=<guid>@<at>:id,count;.../...]
--
-- The mail fields (#312) come last and only while the sender's mail setting is
-- on. A client without them reads s=, kt=, b= and k= by their first match, all
-- of which sit before them, so it takes the rest of the blob and ignores the
-- mail. The new fields are matched with their leading "|", so "|m=" never
-- matches inside "|mm=" or "|mt=".
--
-- bt= (Codex review of #438) is the bags' own stamp, after kt=. An older
-- client never sees it: its "b=" and "k=" matches find the real fields first
-- ("bt=" holds no "b=" or "k="), so it keeps dating the bags by s=. A blob
-- without it (an older sender) is dated by s= here too.
------------------------------------------------------------

local function EncodeMap(map)
    local ids = {}
    for id in pairs(map or {}) do ids[#ids + 1] = id end
    table.sort(ids)   -- deterministic output for tests/diffs/compression
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = id .. "," .. map[id] end
    return table.concat(parts, ";")
end

-- Parse "id,count;id,count" into { [id]=count }. Returns nil on any malformed
-- entry so a corrupt blob cannot half-replace good data.
local function ParseMap(s)
    local map = {}
    if not s or s == "" then return map end
    for pair in s:gmatch("([^;]+)") do
        local id, count = pair:match("^(%d+),(%d+)$")
        id, count = tonumber(id), tonumber(count)
        if not id or not count or id < 1 or count < 1 then return nil end
        map[id] = count
    end
    return map
end

-- The outbox: "<guid>@<at>:<map>" entries joined by "/", oldest first.
local function EncodeOutbox(list)
    local entries = {}
    for _, e in ipairs(type(list) == "table" and list or {}) do
        if e.to and e.at then entries[#entries + 1] = e end
    end
    table.sort(entries, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return tostring(a.to) < tostring(b.to)
    end)
    local parts = {}
    for _, e in ipairs(entries) do parts[#parts + 1] = e.to .. "@" .. e.at .. ":" .. EncodeMap(e.items) end
    return table.concat(parts, "/")
end

-- nil on any malformed entry, as ParseMap.
local function ParseOutbox(s)
    local list = {}
    if not s or s == "" then return list end
    for entry in s:gmatch("[^/]+") do
        local to, at, items = entry:match("^([%w%-]+)@(%d+):(.*)$")
        items = items and ParseMap(items)
        if not to or not items or not next(items) then return nil end
        list[#list + 1] = { to = to, at = tonumber(at), items = items }
    end
    return list
end

local function SerializePlayer(guid, sinceTS)
    local db = AltStableWarbandDB[guid]
    if not db then return "" end
    local stamp = db.stamp or 0
    -- Strict "<": the core delta includes a char at lastUpdate >= sinceTS
    -- (resend-on-equality is idempotent), so skipping at equality would drop a
    -- same-second change permanently once the watermark reaches it.
    if sinceTS and sinceTS > 0 and stamp < sinceTS then return "" end
    local blob = BLOB_VERSION
        .. "|s=" .. stamp
        .. "|kt=" .. (db.bankStamp or 0)
        .. "|bt=" .. (db.bagsStamp or 0)
        .. "|b=" .. EncodeMap(db.bags)
        .. "|k=" .. EncodeMap(db.bank)
    if MailOn() then
        blob = blob
            .. "|mt=" .. (db.mailStamp or 0)
            .. "|mm=" .. (db.mailMore or 0)
            .. "|m=" .. EncodeMap(db.mail)
            .. "|ot=" .. (db.outboxStamp or 0)
            .. "|o=" .. EncodeOutbox(db.outbox)
    end
    return blob
end

local function DeserializePlayer(guid, blob)
    if not guid or not blob or blob == "" then return end
    local ver, rest = blob:match("^(v%d+)|(.+)$")
    if ver ~= BLOB_VERSION then return end   -- unknown version: ignore, don't wipe

    local incomingStamp = tonumber(rest:match("s=(%d+)"))
    if not incomingStamp then return end
    -- Stale-reject, per section: never let an older relayed record roll back
    -- fresher local inventory, and never let one section's age decide
    -- another's (Codex review of #438: held bags at 130 must not keep out a
    -- bank read at 100 when the bank held is from 60). Equality is NOT stale:
    -- stamps come from time(), so two item moves in the same second produce
    -- different maps under one stamp, and the core deliberately re-sends
    -- records at the watermark. So a same-stamp section is applied when its
    -- contents differ (idempotent when they don't), and only an older one is
    -- kept out.
    local existing = AltStableWarbandDB[guid]

    -- The fields must be PRESENT, not merely parseable: ParseMap(nil) is an
    -- empty map, so a truncated blob would silently blank the peer's inventory.
    local bagsStr, bankStr = rest:match("b=([^|]*)"), rest:match("k=([^|]*)")
    if not bagsStr or not bankStr then return end
    local bags, bank = ParseMap(bagsStr), ParseMap(bankStr)
    if not bags or not bank then return end   -- malformed: keep existing good data

    -- The bags, by their own stamp (bt=), else by the overall one: the newest
    -- of the sender's sections, so no older than its bags (declared, for an
    -- older sender: one whose bank or mail is newer than its bags dates its
    -- bags by them). bt= matters because a bank visit's confirming read moves
    -- the overall stamp while the bags are still a cached map (Codex review of
    -- #438). Held bags newer than that stay.
    -- bt=0 is a current sender saying its bags were never read (a fresh or
    -- reset store whose bank was read first): unknown age, like kt=0, so it
    -- never replaces held bags that say anything (Codex review of #438). Only a
    -- blob with no bt= at all (an older sender) falls back to s=.
    local bt = tonumber(("|" .. rest .. "|"):match("|bt=(%d+)|"))
    local bagsStamp = bt or incomingStamp
    local heldMap = existing and existing.bags
    local heldBags = existing and (existing.bagsStamp or existing.stamp) or 0
    if heldMap and ((bagsStamp > 0 and heldBags > bagsStamp)
                    or (bagsStamp == 0 and (heldBags > 0 or next(heldMap)))) then
        bags, bagsStamp = heldMap, heldBags
    end

    -- The bank's own stamp, the whole pipe-delimited field: "xkt=123" or
    -- "kt=123junk" is no stamp. Absent, the bank's age is unknown (0), never
    -- the overall stamp: newer bags must not date a bank of unknown age (#420).
    local kt = tonumber(("|" .. rest .. "|"):match("|kt=(%d+)|"))
    local bankStamp = kt or 0

    -- The bank is kept when a dated one is held and the incoming one is older,
    -- of unknown age (no kt=), or never read (kt=0: the owner has not read this
    -- bank since its data began; a bank read as empty carries its scan time).
    -- The overall stamp moves with the bags, so it says nothing about the bank:
    -- a second PC holding an older bank snapshot scans new bags and sends its
    -- old bank under a newer stamp (#420). Without the kt=0 case, a data reset
    -- on the owning account erased the bank everywhere until its next bank
    -- visit (docs/AUDIT.md, B1). An equal kt with another map is taken: two
    -- moves in one second (B2, declared).
    -- A bank of unknown age (0) is no evidence at all, so it never replaces a
    -- held bank that says anything: a dated one, or an undated one with items
    -- in it (Codex review of #438: a delayed never-read blob emptied one).
    local held = existing and existing.bank
    local heldStamp = existing and existing.bankStamp or 0
    if held and ((heldStamp > 0 and bankStamp < heldStamp) or (bankStamp == 0 and (heldStamp > 0 or next(held)))) then
        bank, bankStamp = held, heldStamp
    end

    -- Mail (#312) and the outbox, each by its own stamp. Absent (an older
    -- client, a relay through one, or the sender's mail switched off), never
    -- read (0), older than what is held, or malformed: what is held stays.
    local mail, mailStamp, mailMore = existing and existing.mail, existing and existing.mailStamp,
                                      existing and existing.mailMore
    local mt, mailStr = tonumber(rest:match("|mt=(%d+)")), rest:match("|m=([^|]*)")
    if mt and mt > 0 and mailStr and mt >= (mailStamp or 0) then
        local m = ParseMap(mailStr)
        if m then mail, mailStamp, mailMore = m, mt, tonumber(rest:match("|mm=(%d+)")) or 0 end
    end
    local outbox, outboxStamp = existing and existing.outbox, existing and existing.outboxStamp
    local ot, outStr = tonumber(rest:match("|ot=(%d+)")), rest:match("|o=([^|]*)")
    if ot and ot > 0 and outStr and ot >= (outboxStamp or 0) then
        local o = ParseOutbox(outStr)
        if o then outbox, outboxStamp = (#o > 0) and o or nil, ot end
    end

    -- Nothing new: a full response re-sends every character, and the sheet is
    -- redrawn per character while the panel is open - each redraw rebuilds the
    -- whole aggregate, its buckets and its rows. Compare what we would store,
    -- not just the stamp, so an unchanged record costs nothing.
    if existing and (existing.bagsStamp or existing.stamp or 0) == bagsStamp
       and (existing.bankStamp or 0) == bankStamp
       and mapsEqual(existing.bags, bags) and mapsEqual(existing.bank, bank)
       and existing.mailStamp == mailStamp and existing.mailMore == mailMore
       and mapsEqual(existing.mail, mail)
       and existing.outboxStamp == outboxStamp and EncodeOutbox(existing.outbox) == EncodeOutbox(outbox) then
        return
    end

    -- A section with a newer stamp than held: what the core marks for the
    -- deltas it sends (#422). Not an equal-stamp swap of contents: two peers
    -- holding different maps under one stamp would mark each other for good.
    local function newer(stamp, heldStamp) return (stamp or 0) > (heldStamp or 0) end
    local advanced = not existing
        or newer(bagsStamp, existing.bagsStamp or existing.stamp)
        or newer(bankStamp, existing.bankStamp)
        or newer(mailStamp, existing.mailStamp)
        or newer(outboxStamp, existing.outboxStamp)

    local db = GetDB(guid)
    db.bags = bags
    db.bank = bank
    db.bagsStamp = bagsStamp
    db.bankStamp = bankStamp
    db.mail, db.mailStamp, db.mailMore = mail, mailStamp, mailMore
    db.outbox, db.outboxStamp = outbox, outboxStamp
    Restamp(db)
    if AT_WB.isActive and AT_WB.RequestRefresh then AT_WB.RequestRefresh() end
    return advanced
end

------------------------------------------------------------
-- Read model for the grid: merge every character's bags+bank by itemID.
--   agg[itemID] = { total, holders = { {name,class,realm,bags,bank,bankStamp} } }
------------------------------------------------------------

-- The core's /alts cleanup wipes AltStableDB down to this character and resets
-- the peer watermarks so everything is re-pulled in full. Our records are keyed
-- by the same guids, and the stale-reject guard below would refuse the re-pull
-- (the peers' stamps have not moved), so they have to go at the same time.
-- This and OnForget are the only deletes: an orphan (a guid no character
-- record mentions) is invisible in the UI and stays, because the login used to
-- prune them and that made a lost AltStable.lua take every bank snapshot with
-- it (docs/AUDIT.md, A4).
local function CleanupWarbandDB(keepGuid)
    for guid in pairs(AltStableWarbandDB) do
        if guid ~= keepGuid then AltStableWarbandDB[guid] = nil end
    end
end

-- Where the player is now, for "current ruleset" (#412): the core's one path
-- (AltStable.CurrentRuleset: the game's rules, the realm, then this
-- character's own record), as a record RulesetOf reads.
local function Here()
    return { ruleset = AltStable.CurrentRuleset and AltStable.CurrentRuleset() }
end

-- filter (optional, #153):
--   only       = guid    one character (Personal), hidden or not
--   ruleset    = "PvP"   characters whose realm is on that ruleset
--   faction    = "Horde" characters of that faction (#461)
--   skipHidden = true    leave hidden characters out, as the sheet's totals do
-- No filter is every character - the tooltips' and the tests' view.
local function Included(guid, c, filter)
    if not filter then return true end
    if filter.personal or filter.only then return filter.only ~= nil and guid == filter.only end
    if filter.skipHidden and AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid) then
        return false
    end
    if filter.ruleset and AltStableWarbandModel.RulesetOf(c) ~= filter.ruleset then
        return false
    end
    -- Only a recorded Alliance or Horde is left out for being the other side;
    -- a faction not recorded ("", "Unknown", nil) stays, as in the tooltip's
    -- filter: no claim from nothing.
    local f = c.faction
    if filter.faction and (f == "Alliance" or f == "Horde") and f ~= filter.faction then
        return false
    end
    return true
end

-- One character's counts by item: { [itemID] = { bags, bank, mail } }. Mail is
-- its last inbox read plus what is on its way to it (`incoming`), both only
-- while the mail setting is on.
local function PerItem(guid, wb, incoming, mailOn)
    local per = {}
    local function add(map, key)
        if type(map) ~= "table" then return end
        for id, n in pairs(map) do
            local p = per[id]
            if not p then p = { bags = 0, bank = 0, mail = 0 }; per[id] = p end
            p[key] = p[key] + n
        end
    end
    if wb then add(wb.bags, "bags"); add(wb.bank, "bank") end
    if mailOn then
        if wb then add(wb.mail, "mail") end
        add(incoming[guid], "mail")
    end
    return per
end

local function gather(filter)
    AltStableDB = AltStableDB or {}
    local mailOn = MailOn()
    local incoming = mailOn and Incoming() or {}
    local agg = {}
    for guid, c in pairs(AltStableDB) do
        if type(c) == "table" and c.name and Included(guid, c, filter) then
            local wb = AltStableWarbandDB[guid]
            if type(wb) ~= "table" then wb = nil end
            for id, v in pairs(PerItem(guid, wb, incoming, mailOn)) do
                local a = agg[id]
                if not a then a = { total = 0, holders = {} }; agg[id] = a end
                a.total = a.total + v.bags + v.bank + v.mail
                a.holders[#a.holders + 1] = {
                    name = c.name, class = c.class, realm = c.realm,
                    bags = v.bags, bank = v.bank, bankStamp = wb and wb.bankStamp,
                    mail = v.mail, mailStamp = wb and wb.mailStamp, mailMore = wb and wb.mailMore,
                }
            end
        end
    end
    return agg
end

------------------------------------------------------------
-- Display (#153) - a retail Warband Bank, read-only. User tabs on a rail at
-- the right; one tab at a time (Single) or three side by side (Combined); the
-- logged-in character (Personal) or everyone on a ruleset (Warband). The model
-- - categories, rulesets, which tabs claim what, which are on screen - is in
-- WarbandTabs.lua; this is frames.
--
-- Cells stay DIRECT children of the panel and scrolling stays virtual: a real
-- ScrollFrame swallowed the cells' hover. Combined shares one row offset over
-- its columns, ranged by the longest.
------------------------------------------------------------

local M = AltStableWarbandModel

local PAD       = 12
local ICON      = 34
local STRIDE    = 40     -- icon + gutter
local HEAD_H    = 70     -- title row + the controls row
local TABTITLE_H = 28    -- a tab's name above its grid
local FOOT_H    = 34     -- Personal / Warband and the status line
local RAIL_W    = 58     -- the tab bar at the right
local RAIL_BTN  = 40
local SCROLL_W  = 14
local COL_GAP   = 18     -- between Combined's columns
local ROW_TOP   = HEAD_H + TABTITLE_H   -- first grid row, from the panel's top
local ARROW_W   = 26    -- Combined's paging arrows get their own margin
-- The room the tab asks the window for: the toolbar's controls side by side
-- (~640) plus the rail, and the Configure dialog's height. Inherited from a
-- narrow or short section, the ruleset control ran off the window and the
-- dialog's last icon rows past its own Save (Codex review of #154).
-- With the faction menu and the reset (#461) the closed row is ~714 wide: 740.
local MIN_PANEL_W, MIN_PANEL_H = 740, 470

local panel, titleFS, emptyFS, searchBox, statusFS
AT_WB.scrollRow = 0
AT_WB.tabBtns, AT_WB.colHeads = {}, {}

local function fmtCount(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local GetItemInfo        = AltStable.API.GetItemInfo
local GetItemInfoInstant = AltStable.API.GetItemInfoInstant
local GetItemIconByID    = AltStable.API.GetItemIconByID

local function RequestMeta(id)
    if requestedIDs[id] then return end
    requestedIDs[id] = true
    if GetItemInfo then GetItemInfo(id) end   -- schedules the async cache load
end


-- Sum one itemID across every tracked character's bags, bank and mail (for the
-- global item-tooltip hook). Returns total + a holders list shaped like
-- gather()'s. Unfiltered on purpose: a tooltip on an item anywhere in the game
-- answers "who has this", whatever the Warband tab happens to be showing. The
-- guid and bankStale ride along for the Professions plugin's reagent counts
-- (#268), which leaves hidden alts out, says when a bank count is old, and
-- counts bags + bank only: an item in the mail can't be crafted with.
--
-- Third, `unseen` (#423): our own characters (scanned here, or our other
-- account's) whose bags were never read or whose bank was never visited, so
-- "nobody has it" can't be said for them. By the section stamps, not the
-- maps: a synced bt=0 or kt=0 is an empty map dated 0, and the overall stamp
-- dates the bags only beside a bags map, as the decoder reads it.
local function CountItem(itemID)
    local total, holders, now, unseen = 0, {}, time(), {}
    local mailOn = MailOn()
    local incoming = mailOn and Incoming() or {}
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name then
            local wb = AltStableWarbandDB[guid]
            if type(wb) ~= "table" then wb = nil end
            local bags = (wb and wb.bags and wb.bags[itemID]) or 0
            local bank = (wb and wb.bank and wb.bank[itemID]) or 0
            local mail = 0
            if mailOn then
                mail = ((wb and wb.mail and wb.mail[itemID]) or 0)
                     + ((incoming[guid] and incoming[guid][itemID]) or 0)
            end
            if c.scannedHere or c.provKind == "own-account" then
                local bagsSeen = wb and type(wb.bags) == "table" and (tonumber(wb.bagsStamp or wb.stamp) or 0) > 0
                local bankSeen = wb and (tonumber(wb.bankStamp) or 0) > 0
                if not (bagsSeen and bankSeen) then unseen[#unseen + 1] = guid end
            end
            if bags + bank + mail > 0 then
                total = total + bags + bank + mail
                holders[#holders + 1] = {
                    guid = guid, name = c.name, class = c.class, realm = c.realm,
                    bags = bags, bank = bank, bankStamp = wb and wb.bankStamp,
                    bankStale = bank > 0 and wb.bankStamp ~= nil and (now - wb.bankStamp) > BANK_STALE,
                    mail = mail, mailStamp = wb and wb.mailStamp, mailMore = wb and wb.mailMore,
                }
            end
        end
    end
    return total, holders, unseen
end
AT_WB.CountItem = CountItem

-- What a character holds, for the core's Bags tooltip (#346): the stored maps,
-- { [itemID] = count }, read-only. The mail only while the mail option is on,
-- and with what our own characters sent it since its last mailbox visit, as
-- CountItem counts it - also for a character with no inventory recorded yet.
local function ItemMapsFor(guid)
    if not guid then return nil end
    local wb = AltStableWarbandDB[guid]
    if type(wb) ~= "table" then wb = nil end
    local mail
    if MailOn() then
        local incoming = Incoming()[guid]
        if (wb and wb.mail) or incoming then
            mail = {}
            for id, n in pairs(wb and wb.mail or {}) do mail[id] = n end
            for id, n in pairs(incoming or {}) do mail[id] = (mail[id] or 0) + n end
        end
    end
    if not wb and not mail then return nil end
    return { bags = wb and wb.bags, bank = wb and wb.bank, mail = mail }
end

-- The counts block, the core's (AltStable.AppendItemCounts), shared with the
-- Options preview. Kept by this name for the tests' seam.
local function AppendBreakdown(tt, total, holders, split, inTab)
    return AltStable.AppendItemCounts(tt, total, holders, split, inTab)
end

-- One item's breakdown, as the item tooltips' layout asks (#403): every
-- character, grouped by whether they match. `inTab`, for a Warband cell.
local function ItemBreakdown(tt, id, inTab)
    local total, holders = CountItem(id)
    if total <= 0 then return end
    AltStable.AppendItemCountsFor(tt, total, holders, inTab)
end

-- A Warband cell's breakdown: the same as everywhere else (Show, the owner,
-- 2026-11-20), whatever the tab filters, with the tab's own count beside it
-- when they differ. The items with no counts and the global opt-in don't
-- apply here: hovering a cell is asking.
local function CellBreakdown(tt, e)
    ItemBreakdown(tt, e.id, e.total)
end

-- A tooltip re-renders itself from the item link when the async item info
-- arrives (and for uncached remote-alt items), wiping anything appended after
-- SetHyperlink — so the breakdown is appended from a post-call that re-fires on
-- every render. Installed once at bootstrap so it also enriches item tooltips
-- everywhere (bags, bank, merchant, links), gated by the warbandItemTooltips
-- setting. hoverEntry routes our own panel cells to their precomputed aggregate.
--
-- GameTooltip:HookScript("OnTooltipSetItem", ...) is gone on Forever: the script
-- type no longer exists and the call THROWS, which used to abort this plugin's
-- registration entirely (#10). TooltipDataProcessor is the replacement, and the
-- item id arrives in the data payload rather than through tt:GetItem().
-- AT_WB._ttHooked: true once installed, nil when this client has no
-- TooltipDataProcessor (CellOnEnter appends the breakdown itself then).
local function EnsureTooltipHook()
    if AT_WB._ttHooked then return end
    -- The post-call and the item lookup are the core's (Core.lua), shared with
    -- the Professions plugin. Without TooltipDataProcessor nothing is hooked;
    -- the panel still works.
    local hooked = AltStable.HookItemTooltip and AltStable.HookItemTooltip(function(tt, id)
        -- Our own panel cell, and only for the item it holds: comparison
        -- tooltips (Shift, or alwaysCompareItems) render the EQUIPPED items
        -- through this same post-call, and would otherwise be labelled with the
        -- hovered item's holders - bypassing the opt-in below as well.
        local e = AT_WB.hoverEntry
        if e and id == e.id then CellBreakdown(tt, e); return end
        if e then return end
        -- Global enrichment: on unless the player turned it off, or (never
        -- having chosen) another addon already shows counts (#304, Core.lua).
        if not (AltStable.ItemTooltipCountsOn and AltStable.ItemTooltipCountsOn()) then return end
        -- Items the player left out, and only the characters they asked for (#403).
        if id and not (AltStable.TooltipIgnored and AltStable.TooltipIgnored(id)) then
            ItemBreakdown(tt, id)
        end
    end)
    if hooked then AT_WB._ttHooked = true end
end

local function CellOnEnter(self)
    local e = self.entry
    if not e then return end      -- an empty slot
    AT_WB.hoverEntry = e
    AT_WB.hoverCell = self
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- SetHyperlink drives the item tooltip; OnTooltipSetItem then appends the
    -- breakdown. Guard it so a finicky bare-item string never aborts the hover.
    local ok = pcall(function() GameTooltip:SetHyperlink("item:" .. e.id) end)
    if ok and AT_WB._ttHooked == nil then
        -- No TooltipDataProcessor on this client, so nothing appends for us:
        -- add the breakdown here, where the grid's whole point lives.
        CellBreakdown(GameTooltip, e)
        return
    end
    if not ok or GameTooltip:NumLines() == 0 then
        -- Fallback: no item tooltip available (uncached, no data yet) — show a
        -- quality-coloured name header and the breakdown directly.
        GameTooltip:ClearLines()
        local r, g, b = 1, 1, 1
        local qc = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
        if qc then r, g, b = qc.r, qc.g, qc.b end
        GameTooltip:AddLine(e.name or ("Item " .. e.id), r, g, b)
        CellBreakdown(GameTooltip, e)
    end
end

local function CellOnLeave()
    AT_WB.hoverEntry, AT_WB.hoverCell = nil, nil
    GameTooltip:Hide()
end

local function ClearHover()
    if AT_WB.hoverEntry then
        AT_WB.hoverEntry, AT_WB.hoverCell = nil, nil
        if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
    end
end

-- After a layout: the tooltip stays while the cell under the mouse still holds
-- the same item (its entry refreshed), and goes the moment it holds another or
-- nothing. Clearing unconditionally closed it under a resting mouse on every
-- refresh - item info arriving 0.2 s after the hover, a bag update, a sync
-- (review of #154).
local function ReconcileHover()
    local e, cell = AT_WB.hoverEntry, AT_WB.hoverCell
    if not e then return end
    local now = cell and cell:IsShown() and cell.entry
    if now and now.id == e.id then
        AT_WB.hoverEntry = now
        -- The tooltip's "N shown in this tab" is the cell's count: when that
        -- changed, draw it again for the same item (#407 review).
        if now.total ~= e.total then CellOnEnter(cell) end
    else
        ClearHover()
    end
end

-- Shown only when there is something to scroll to, and kept in step with the
-- wheel. _syncing stops the value we set here from re-entering Layout.
function AT_WB.UpdateScrollBar(maxStart, start)
    local scrollBar = AT_WB.scrollBar
    if not scrollBar then return end
    if (maxStart or 0) <= 0 then scrollBar:Hide(); return end
    scrollBar._syncing = true
    scrollBar:SetMinMaxValues(0, maxStart)
    scrollBar:SetValue(start or 0)
    scrollBar._syncing = false
    scrollBar:Show()
end

local function hideFrom(pool, from)
    for k = from, #pool do if pool[k] then pool[k]:Hide() end end
end

-- How much of the grid fits, and where the window starts. Whole rows only:
-- cells are laid out on a fixed stride, so a partial row at the bottom would be
-- a clipped row rather than a scrolled one. The grid sits between the tab
-- titles and the Personal/Warband bar. Returns visible rows, the highest
-- first-row index, and the requested start clamped into range.
local function ScrollBounds(rowCount, panelHeight, requested)
    local ph = (panelHeight and panelHeight >= 50) and panelHeight or 400
    local visible = math.max(1, math.floor((ph - ROW_TOP - FOOT_H - PAD) / STRIDE))
    local maxStart = math.max(0, (rowCount or 0) - visible)
    local start = math.max(0, math.min(requested or 0, maxStart))
    return visible, maxStart, start
end
AT_WB.ScrollBounds = ScrollBounds

local function getCell(i)
    local cell = AT_WB.cells[i]
    if not cell then
        cell = CreateFrame("Button", nil, panel, "BackdropTemplate")
        cell:SetSize(ICON, ICON)
        cell:EnableMouse(true)
        cell:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        cell.icon = cell:CreateTexture(nil, "ARTWORK")
        cell.icon:SetPoint("TOPLEFT", 1, -1)
        cell.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        cell.count = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        cell.count:SetPoint("BOTTOMRIGHT", -1, 1)
        cell:SetScript("OnEnter", CellOnEnter)
        cell:SetScript("OnLeave", CellOnLeave)
        AT_WB.cells[i] = cell
    end
    return cell
end

-- One cell, holding an item or (entry nil) an empty slot. An empty slot clears
-- everything an item left on it: the hover, the count and the search name.
local function FillCell(cell, e)
    cell.entry = e
    if e then
        cell.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        cell.icon:SetDesaturated(false)
        cell.count:SetText(e.total > 1 and fmtCount(e.total) or "")
        local qc = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
        if qc then cell:SetBackdropBorderColor(qc.r, qc.g, qc.b, 1)
        else cell:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
        cell.itemName = e.name
        cell:SetAlpha(1)
    else
        -- A quiet box, not slot art: these are filters, not storage, and the
        -- textured slots outweighed the items (review, 2026-10-03).
        cell.icon:SetTexture(nil)
        cell.count:SetText("")
        cell:SetBackdropBorderColor(1, 1, 1, 0.07)
        cell.itemName = nil
        cell:SetAlpha(1)        -- faint by its border, not its alpha
    end
end

------------------------------------------------------------
-- The read model, filtered
------------------------------------------------------------

local function Cfg(key, default)
    local v = AltStableConfig and AltStableConfig[key]
    if v == nil then return default end
    return v
end

-- Tabs from config, seeded with the defaults the first time - for an existing
-- profile as well as a new one - and never overwritten once there.
local function Tabs()
    local tabs = AltStableConfig and AltStableConfig.warbandTabs
    if type(tabs) ~= "table" or #tabs == 0 then
        tabs = M.DefaultTabs()
        AltStable.SetConfigValue("warbandTabs", tabs)
    end
    return tabs
end

local function Scope() return Cfg("warbandScope", "warband") end
local function View() return Cfg("warbandView", "single") end

-- The two filters' saved choices, normalized (#461): kept in AltStableConfig,
-- so they last between sessions; "current" by default.
local function RulesetChoice() return M.RulesetChoice(Cfg("warbandRuleset", "current")) end
local function FactionChoice() return M.FactionChoice(Cfg("warbandFaction", "current")) end
local function FiltersAtDefault() return RulesetChoice() == "current" and FactionChoice() == "current" end

-- The played character's faction tag, nil when unreadable.
local function MyFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Alliance" or f == "Horde" then return f end
    return nil
end

-- Who the grid is about: Personal is the logged-in character alone, ruleset
-- ignored, hidden or not; Warband is every character not hidden (the sheet's
-- totals leave hidden ones out too) on the chosen ruleset.
local function CurrentFilter()
    if Scope() == "personal" then
        -- `personal` is the flag, not the GUID: with no GUID yet this shows
        -- nobody, never everybody (review of #154).
        return { personal = true, only = UnitGUID and UnitGUID("player") }
    end
    return {
        ruleset = M.ResolveRuleset(RulesetChoice(), Here()),
        faction = M.ResolveFaction(FactionChoice(), MyFaction()),
        skipHidden = true,
    }
end

-- Every unique item, resolved to what the view needs. An item whose metadata
-- has not arrived sits in misc until GET_ITEM_INFO_RECEIVED refreshes it.
local function BuildEntries(agg)
    local list = {}
    for id, a in pairs(agg) do
        local icon, classID
        if GetItemInfoInstant then
            local _, _, _, _, ic, cid = GetItemInfoInstant(id)
            icon, classID = ic, cid
        end
        local name, _, quality = nil, nil, nil
        if GetItemInfo then name, _, quality = GetItemInfo(id) end
        if not name then RequestMeta(id) end
        if not icon and GetItemIconByID then icon = GetItemIconByID(id) end
        list[#list + 1] = {
            id = id, total = a.total, holders = a.holders, icon = icon, name = name,
            quality = quality, classID = classID, cat = M.CategoryOf(classID),
        }
    end
    -- Grouped by kind inside a tab, then best first, then by name.
    table.sort(list, function(x, y)
        local cx, cy = x.classID or 99, y.classID or 99
        if cx ~= cy then return cx < cy end
        local qx, qy = x.quality or -1, y.quality or -1
        if qx ~= qy then return qx > qy end
        return (x.name or ("zzz" .. x.id)) < (y.name or ("zzz" .. y.id))
    end)
    return list
end

local RULESET_LABEL = {
    current = "Current ruleset", all = "All rulesets",
    Normal = "Normal", PvP = "PvP", RP = "RP", RPPvP = "RP-PvP", Hardcore = "Hardcore",
}

local function RulesetText(setting)
    setting = setting or RulesetChoice()
    if setting == "current" then
        return "Current ruleset (" .. M.RulesetOf(Here()) .. ")"
    end
    return RULESET_LABEL[setting] or tostring(setting)
end

-- The faction button shows the side in effect (#461); its menu spells out
-- which choice that comes from.
local function FactionText(setting, inMenu)
    setting = setting or FactionChoice()
    if setting == "all" then return "Both factions" end
    if setting == "current" then
        local f = MyFaction()
        if not f then return "Current faction" end
        return inMenu and ("Current faction (" .. f .. ")") or f
    end
    return setting
end

------------------------------------------------------------
-- Small glass widgets
------------------------------------------------------------

local function Accent()
    if AltStable.GetAccentRGB then return AltStable.GetAccentRGB() end
    return 1, 0.82, 0
end

local function StyleButton(btn, active)
    local r, g, b = Accent()
    local glass = AltStable.SkinIsGlass and AltStable.SkinIsGlass()
    if active then
        btn:SetBackdropColor(r, g, b, glass and 0.18 or 0.25)
        btn:SetBackdropBorderColor(r, g, b, 1)
        if btn.label then btn.label:SetTextColor(r, g, b) end
    else
        if glass then
            btn:SetBackdropColor(1, 1, 1, btn._hover and 0.10 or 0.04)
            btn:SetBackdropBorderColor(1, 1, 1, 0.18)
        else
            -- The flat skin's own button fills (Theme.lua), not glass tints.
            local c = btn._hover and AltStable.C.BG_BTN_HOVER or AltStable.C.BG_BTN_ACTIVE
            btn:SetBackdropColor(c[1], c[2], c[3], c[4])
            btn:SetBackdropBorderColor(0, 0, 0, 1)
        end
        if btn.label then btn.label:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
    end
end

local function MakeButton(parent, w, h, text, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, h)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(text or "")
    if AltStable.SkinText then AltStable.SkinText(btn.label) end
    btn:SetScript("OnEnter", function(self) self._hover = true; StyleButton(self, self._active) end)
    btn:SetScript("OnLeave", function(self) self._hover = false; StyleButton(self, self._active) end)
    if onClick then btn:SetScript("OnClick", onClick) end
    StyleButton(btn, false)
    return btn
end

local function SetActive(btn, on)
    btn._active = on and true or false
    StyleButton(btn, btn._active)
end

-- Closes on a click anywhere else in the panel, and on Escape.
local function MakeCatcher(owner, onClose, dim)
    local c = CreateFrame("Button", nil, panel)
    c:SetAllPoints(panel)
    c:SetFrameStrata("FULLSCREEN_DIALOG")
    c:RegisterForClicks("AnyUp")
    c:SetScript("OnClick", onClose)
    if dim then
        -- The bank behind a dialog is dimmed, so it stops competing with it.
        local t = c:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0, 0, 0, dim)
        c.dim = t
    end
    c:Hide()
    return c
end

-- Escape closes it and is swallowed; every other key goes on to the game, so
-- an open menu never eats movement.
--
-- SetPropagateKeyboardInput is restricted in combat (HasRestrictions in the
-- API docs), so this follows CharacterMenu.lua exactly (review of #154): the
-- call is pcall'd and a failure RELEASES the keyboard - a caught error leaves
-- propagation where the last Escape put it, false, and W would be swallowed;
-- the keyboard is not grabbed in combat at all; and combat starting with the
-- frame open releases it before the first key.
local function CloseOnEscape(f, onClose)
    f:SetScript("OnKeyDown", function(self, key)
        local stop = (key == "ESCAPE")
        local handed = true
        if type(self.SetPropagateKeyboardInput) == "function" then
            handed = pcall(self.SetPropagateKeyboardInput, self, not stop)
        end
        if not handed and type(self.EnableKeyboard) == "function" then
            pcall(self.EnableKeyboard, self, false)
        end
        if stop then onClose() end
    end)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function(self)
        if type(self.EnableKeyboard) == "function" then pcall(self.EnableKeyboard, self, false) end
    end)
end

-- On opening: take the keyboard only out of combat, and reset propagation, which
-- outlives the frame and was left false by the last Escape.
local function GrabKeyboard(f)
    if type(f.EnableKeyboard) ~= "function" then return end
    if InCombatLockdown and InCombatLockdown() then
        pcall(f.EnableKeyboard, f, false)
        return
    end
    f:EnableKeyboard(true)
    if type(f.SetPropagateKeyboardInput) == "function" then
        pcall(f.SetPropagateKeyboardInput, f, true)
    end
end

------------------------------------------------------------
-- The ruleset menu
------------------------------------------------------------

-- The ruleset and faction menus (#461: one helper for both). Each has its own
-- catcher, which covers the panel: with one menu open, a click on the other
-- button closes it, and a second click opens the other (two clicks, declared).
local rulesetBtn, factionBtn, resetBtn
local menus = {}   -- [name] = { frame = ..., catcher = ... }

local function CloseMenus()
    for _, m in pairs(menus) do
        m.frame:Hide()
        m.catcher:Hide()
    end
end

-- spec: name, setting (the config key), keys, choice() (the normalized saved
-- choice), label(key), anchor(frame) (the menu's point, set on every open).
local function OpenMenu(spec)
    if Scope() == "personal" then return end
    CloseMenus()
    local m = menus[spec.name]
    if not m then
        local catcher = MakeCatcher(panel, CloseMenus)
        local f = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(catcher:GetFrameLevel() + 5)
        local g = AltStable.SkinWindow and AltStable.SkinWindow(f, "small")
        if g then
            -- The popup glass alone is see-through, and over the item icons the
            -- rows could not be read (in game, #461): the tooltip's backing,
            -- BACKGROUND -7, over the shadow (-8), under the tint (-6), masked
            -- to the glass's corners. See AltStable.TOOLTIP_BACKING.
            local b = f:CreateTexture(nil, "BACKGROUND", nil, -7)
            b:SetAllPoints(f)
            if g.mask and b.AddMaskTexture then b:AddMaskTexture(g.mask) end
            local c = AltStable.TOOLTIP_BACKING or { 0.04, 0.05, 0.07, 0.93 }
            b:SetColorTexture(c[1], c[2], c[3], c[4])
            f.backing = b
        else
            AltStable.ApplyBackdrop(f, 0.08, 0.08, 0.1, 0.97)
        end
        CloseOnEscape(f, CloseMenus)
        f.rows = {}
        for i, key in ipairs(spec.keys) do
            local row = MakeButton(f, 180, 22, "", function()
                CloseMenus()
                AltStable.SetConfigValue(spec.setting, key)
                AT_WB.scrollRow = 0
                AT_WB.Refresh()
            end)
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8 - (i - 1) * 24)
            row.key = key
            f.rows[i] = row
        end
        f:SetSize(196, 16 + #spec.keys * 24)
        m = { frame = f, catcher = catcher }
        menus[spec.name] = m
    end
    local current = spec.choice()
    for _, row in ipairs(m.frame.rows) do
        row.label:SetText(spec.label(row.key))
        SetActive(row, row.key == current)
    end
    m.frame:ClearAllPoints()
    spec.anchor(m.frame)
    m.catcher:Show()
    m.frame:Show()
    GrabKeyboard(m.frame)
end

local RULESET_MENU = {
    name = "ruleset", setting = "warbandRuleset",
    keys = { "current", "all", "Normal", "PvP", "RP", "RPPvP", "Hardcore" },
    choice = function() return RulesetChoice() end,
    label = function(key) return key == "current" and RulesetText("current") or RULESET_LABEL[key] end,
    anchor = function(f) f:SetPoint("TOPLEFT", rulesetBtn, "BOTTOMLEFT", 0, -2) end,
}
-- Opens leftwards from the faction button's right edge, so it stays inside the
-- panel at the tab's minimum width (Codex review of the #461 plan).
local FACTION_MENU = {
    name = "faction", setting = "warbandFaction",
    keys = { "current", "all", "Alliance", "Horde" },
    choice = function() return FactionChoice() end,
    label = function(key) return FactionText(key, true) end,
    anchor = function(f) f:SetPoint("TOPRIGHT", factionBtn, "BOTTOMRIGHT", 0, -2) end,
}

local function OpenRulesetMenu() OpenMenu(RULESET_MENU) end
local function OpenFactionMenu() OpenMenu(FACTION_MENU) end

-- Both filters back to their defaults (#461).
local function ResetFilters()
    CloseMenus()
    AltStable.SetConfigValue("warbandRuleset", "current")
    AltStable.SetConfigValue("warbandFaction", "current")
    AT_WB.scrollRow = 0
    AT_WB.Refresh()
end

-- Tests.
AT_WB.OpenRulesetMenu, AT_WB.OpenFactionMenu = OpenRulesetMenu, OpenFactionMenu
AT_WB.Menu = function(name) local m = menus[name]; return m and m.frame, m and m.catcher end
AT_WB.FilterControls = function() return rulesetBtn, factionBtn, resetBtn end

------------------------------------------------------------
-- Configure Tab
------------------------------------------------------------

local dialog, dialogCatcher
local ICON_COLS, ICON_ROWS, ICON_SIZE = 10, 4, 34
local iconList                       -- deduplicated, built once on first open

-- The client's icon lists can run to thousands of entries: read once, kept,
-- and only ICON_COLS x ICON_ROWS cells ever exist.
local function IconList()
    if iconList then return iconList end
    iconList = {}
    local seen = {}
    local function add(v)
        if v and not seen[v] then seen[v] = true; iconList[#iconList + 1] = v end
    end
    for _, t in ipairs(M.DefaultTabs()) do add(t.icon) end
    -- By name: `ipairs({ GetMacroItemIcons, GetMacroIcons })` stops at the first
    -- nil, so a client without the first list would silently lose the second.
    for _, fname in ipairs({ "GetMacroItemIcons", "GetMacroIcons" }) do
        local fn = _G[fname]
        if type(fn) == "function" then
            local out = {}
            local ok, r = pcall(fn, out)
            local src = (ok and type(r) == "table") and r or out
            for _, v in ipairs(src) do add(v) end
        end
    end
    return iconList
end
AT_WB.IconList = IconList
AT_WB.ResetIconList = function() iconList = nil end   -- tests: a different client list

-- Icon rows that fit a dialog of height h: the grid starts GRID_TOP down and
-- must end above the buttons' strip.
local GRID_TOP, BUTTON_STRIP = 224, 46
local function DialogIconRows(h)
    local rows = math.floor((h - BUTTON_STRIP - GRID_TOP - ICON_SIZE) / (ICON_SIZE + 4)) + 1
    return math.max(1, math.min(ICON_ROWS, rows))
end
AT_WB.DialogIconRows = DialogIconRows

local function CloseDialog()
    if dialog then dialog:Hide(); dialog.draft = nil end
    if dialogCatcher then dialogCatcher:Hide() end
end

local function RenderIconGrid()
    local list = IconList()
    local rows = dialog.visRows or ICON_ROWS
    local total = math.ceil(#list / ICON_COLS)
    local maxStart = math.max(0, total - rows)
    dialog.iconRow = math.max(0, math.min(dialog.iconRow or 0, maxStart))
    if dialog.iconBar then
        dialog.iconBar._syncing = true
        dialog.iconBar:SetMinMaxValues(0, maxStart)
        dialog.iconBar:SetValue(dialog.iconRow)
        dialog.iconBar._syncing = false
        dialog.iconBar:SetShown(maxStart > 0)
    end
    if dialog.iconCount then dialog.iconCount:SetText(#list .. " icons - scroll for more") end
    if dialog.iconBar then
        dialog.iconBar:ClearAllPoints()
        dialog.iconBar:SetPoint("TOPLEFT", dialog.iconCells[ICON_COLS], "TOPRIGHT", 6, 0)
        dialog.iconBar:SetPoint("BOTTOMLEFT", dialog.iconCells[rows * ICON_COLS], "BOTTOMRIGHT", 6, 0)
    end
    for r = 0, ICON_ROWS - 1 do
        for c = 1, ICON_COLS do
            local cell = dialog.iconCells[r * ICON_COLS + c]
            local v = (r < rows) and list[(dialog.iconRow + r) * ICON_COLS + c] or nil
            cell.value = v
            if v then
                cell.icon:SetTexture(v)
                local picked = dialog.draft and dialog.draft.icon == v
                local ar, ag, ab = Accent()
                if picked then cell:SetBackdropBorderColor(ar, ag, ab, 1)
                else cell:SetBackdropBorderColor(0.25, 0.25, 0.28, 1) end
                cell:Show()
            else
                cell:Hide()
            end
        end
    end
end

local function SaveDialog()
    local d = dialog.draft
    if not d then return end
    local name = (dialog.nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local tabs = M.CopyTabs(Tabs())
    local index = dialog.index
    if name == "" then name = "Tab " .. (index or (#tabs + 1)) end
    d.name = name
    if index then
        tabs[index] = d
    else
        -- The cap is enforced where a new tab is started (OpenDialog).
        tabs[#tabs + 1] = d
        index = #tabs
    end
    AltStable.SetConfigValue("warbandTabs", tabs)
    AltStable.SetConfigValue("warbandTab", index)
    CloseDialog()
    AT_WB.scrollRow = 0
    AT_WB.Refresh()        -- SetConfigValue does not refresh anything itself
end

local function DeleteFromDialog()
    local index = dialog.index
    local tabs = M.CopyTabs(Tabs())
    if not index or #tabs <= 1 then return end
    table.remove(tabs, index)
    AltStable.SetConfigValue("warbandTabs", tabs)
    AltStable.SetConfigValue("warbandTab", M.AfterDelete(Cfg("warbandTab", 1), index, #tabs) or 1)
    CloseDialog()
    AT_WB.scrollRow = 0
    AT_WB.Refresh()
end

local function BuildDialog()
    dialogCatcher = MakeCatcher(panel, CloseDialog, 0.55)
    dialog = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(dialogCatcher:GetFrameLevel() + 5)
    dialog:SetSize(ICON_COLS * (ICON_SIZE + 4) + 40, 420)
    dialog:SetPoint("CENTER", panel, "CENTER", -RAIL_W / 2, 0)
    dialog:EnableMouse(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(dialog, "small")) then
        AltStable.ApplyBackdrop(dialog, 0.08, 0.08, 0.1, 0.98)
    end
    -- Glass around the edge, a dark near-opaque body: through the glass alone,
    -- item icons and titles showed straight through the labels (review).
    local body = dialog:CreateTexture(nil, "BACKGROUND", nil, 1)
    body:SetPoint("TOPLEFT", 6, -6)
    body:SetPoint("BOTTOMRIGHT", -6, 6)
    body:SetColorTexture(0.06, 0.065, 0.08, 0.94)
    CloseOnEscape(dialog, CloseDialog)

    -- An upper-right close, as well as Cancel and Escape.
    local close = MakeButton(dialog, 22, 22, "x", CloseDialog)
    close:SetPoint("TOPRIGHT", -12, -12)

    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -14)
    title:SetText("Configure Tab")

    dialog.preview = dialog:CreateTexture(nil, "ARTWORK")
    dialog.preview:SetSize(44, 44)
    dialog.preview:SetPoint("TOPLEFT", 18, -44)
    dialog.preview:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local nameLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("TOPLEFT", dialog.preview, "TOPRIGHT", 12, 0)
    nameLbl:SetText("Tab Name")
    local box = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    box:SetSize(230, 22)
    box:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 4, -4)
    box:SetAutoFocus(false)
    box:SetMaxLetters(32)
    box:SetScript("OnEscapePressed", function() CloseDialog() end)
    box:SetScript("OnEnterPressed", function() SaveDialog() end)
    dialog.nameBox = box
    local note = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -4, -2)
    note:SetText("Display filters only - nothing is moved.")

    local catLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    catLbl:SetPoint("TOPLEFT", 18, -108)
    catLbl:SetText("Item Categories")
    dialog.checks = {}
    for i, cat in ipairs(M.CATEGORIES) do
        local cb = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", 16 + col * 180, -126 - row * 24)
        local lbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        lbl:SetText(M.CATEGORY_LABEL[cat])
        cb:SetScript("OnClick", function(self)
            if dialog.draft then dialog.draft.cats[cat] = self:GetChecked() and true or nil end
        end)
        cb.cat = cat
        dialog.checks[i] = cb
    end

    local iconLbl = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconLbl:SetPoint("TOPLEFT", 18, -206)
    iconLbl:SetText("Choose an Icon")
    dialog.iconCells = {}
    for r = 0, ICON_ROWS - 1 do
        for c = 1, ICON_COLS do
            local cell = CreateFrame("Button", nil, dialog, "BackdropTemplate")
            cell:SetSize(ICON_SIZE, ICON_SIZE)
            cell:SetPoint("TOPLEFT", 18 + (c - 1) * (ICON_SIZE + 4), -GRID_TOP - r * (ICON_SIZE + 4))
            cell:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            cell.icon = cell:CreateTexture(nil, "ARTWORK")
            cell.icon:SetPoint("TOPLEFT", 1, -1)
            cell.icon:SetPoint("BOTTOMRIGHT", -1, 1)
            cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            cell:SetScript("OnClick", function(self)
                if dialog.draft and self.value then
                    dialog.draft.icon = self.value
                    dialog.preview:SetTexture(self.value)
                    RenderIconGrid()
                end
            end)
            dialog.iconCells[r * ICON_COLS + c] = cell
        end
    end
    dialog:EnableMouseWheel(true)
    dialog:SetScript("OnMouseWheel", function(_, delta)
        dialog.iconRow = (dialog.iconRow or 0) - delta * 2
        RenderIconGrid()
    end)
    -- A scrollbar and a count: the lists run to thousands, and they are bare
    -- file ids with no names, so there is nothing a search box could match.
    local bar = CreateFrame("Slider", nil, dialog)
    bar:SetWidth(8)
    bar:SetPoint("TOPLEFT", dialog.iconCells[ICON_COLS], "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", dialog.iconCells[ICON_ROWS * ICON_COLS], "BOTTOMRIGHT", 6, 0)
    bar:SetOrientation("VERTICAL")
    bar:SetValueStep(1)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(); track:SetColorTexture(1, 1, 1, 0.06)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.3); thumb:SetSize(8, 24)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnValueChanged", function(self, v)
        if self._syncing then return end
        dialog.iconRow = math.floor((v or 0) + 0.5)
        RenderIconGrid()
    end)
    dialog.iconBar = bar
    dialog.iconCount = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dialog.iconCount:SetPoint("LEFT", iconLbl, "RIGHT", 10, 0)

    dialog.save = MakeButton(dialog, 90, 24, "Save", SaveDialog)
    dialog.save:SetPoint("BOTTOMRIGHT", -16, 14)
    SetActive(dialog.save, true)             -- the primary action, in gold
    dialog.save:SetScript("OnLeave", function(self) self._hover = false; StyleButton(self, true) end)
    dialog.cancel = MakeButton(dialog, 90, 24, "Cancel", CloseDialog)
    dialog.cancel:SetPoint("RIGHT", dialog.save, "LEFT", -8, 0)
    dialog.delete = MakeButton(dialog, 100, 24, "Delete Tab", DeleteFromDialog)
    dialog.delete:SetPoint("BOTTOMLEFT", 16, 14)
    dialog:Hide()
end

-- index nil = a new tab: nothing is inserted until Save.
local function OpenDialog(index)
    if not dialog then BuildDialog() end
    CloseMenus()
    local tabs = Tabs()
    if not index and #tabs >= M.MAX_TABS then return end
    dialog.index = index
    dialog.draft = index and M.CopyTab(tabs[index])
        or { name = "", icon = M.DefaultTabs()[1].icon, cats = {} }
    dialog.nameBox:SetText(dialog.draft.name or "")
    dialog.preview:SetTexture(dialog.draft.icon)
    for _, cb in ipairs(dialog.checks) do cb:SetChecked(dialog.draft.cats[cb.cat] and true or false) end
    -- Never taller than the panel it sits on, and its content fits what it
    -- gets: as many icon rows as clear the buttons (the window is asked for
    -- room on activation; a display too small for that still must not put
    -- icons under Save - Codex review of #154). Sized
    -- BEFORE the grid is drawn, which reads visRows.
    local ph = panel:GetHeight()
    local h = 420
    if ph and ph > 100 then h = math.min(420, ph - 8) end
    dialog:SetHeight(h)
    dialog.visRows = DialogIconRows(h)
    dialog.iconRow = 0
    RenderIconGrid()
    -- Delete exists for a saved tab, and never for the last one.
    dialog.delete:SetShown(index ~= nil)
    dialog.delete:SetEnabled(index ~= nil and #tabs > 1)
    dialog.delete:SetAlpha((index ~= nil and #tabs > 1) and 1 or 0.4)
    dialogCatcher:Show()
    dialog:Show()
    GrabKeyboard(dialog)
end
AT_WB.OpenDialog = OpenDialog
AT_WB.SaveDialog = function() return SaveDialog() end
AT_WB.CloseDialog = CloseDialog
AT_WB.DeleteFromDialog = function() return DeleteFromDialog() end
AT_WB.Dialog = function() return dialog end
AT_WB.MIN_PANEL_W, AT_WB.MIN_PANEL_H = MIN_PANEL_W, MIN_PANEL_H

------------------------------------------------------------
-- Tab rail and column heads
------------------------------------------------------------

local function TabMeta(key, tabs)
    if key == "other" then return "Other", M.OTHER_ICON end
    local t = tabs[key]
    return (t and t.name) or ("Tab " .. tostring(key)), (t and t.icon) or M.OTHER_ICON
end

local function Select(key)
    AltStable.SetConfigValue("warbandTab", key)
    AT_WB.scrollRow = 0
    AT_WB.Refresh()
end

local function getTabBtn(i)
    local b = AT_WB.tabBtns[i]
    if b then return b end
    b = CreateFrame("Button", nil, panel, "BackdropTemplate")
    b:SetSize(RAIL_BTN, RAIL_BTN)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.plus = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    b.plus:SetPoint("CENTER", 0, 1)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        if self.isAdd then OpenDialog(nil); return end
        if button == "RightButton" then
            if type(self.key) == "number" then OpenDialog(self.key) end
            return
        end
        Select(self.key)
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(self.tip or "")
        if not self.isAdd then
            if self.shown then
                GameTooltip:AddLine(View() == "combined" and "Shown in the combined view" or "Shown", .6, .9, .6)
            else
                GameTooltip:AddLine("Click to show", .8, .8, .8)
            end
        end
        if type(self.key) == "number" then GameTooltip:AddLine("Right-click to configure", .7, .7, .7) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    AT_WB.tabBtns[i] = b
    return b
end

local function getColHead(i)
    local h = AT_WB.colHeads[i]
    if h then return h end
    h = CreateFrame("Frame", nil, panel)
    h:SetHeight(TABTITLE_H - 4)
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(20, 20)
    h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    h.name = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if AltStable.SkinText then AltStable.SkinText(h.name) end
    h.gear = CreateFrame("Button", nil, h)
    h.gear:SetSize(18, 18)
    h.gear.tex = h.gear:CreateTexture(nil, "ARTWORK")
    h.gear.tex:SetAllPoints()
    h.gear.tex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    h.gear:SetScript("OnClick", function(self) if type(self.key) == "number" then OpenDialog(self.key) end end)
    AT_WB.colHeads[i] = h
    return h
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------

-- The grid area: everything between the header, the bar, the rail and the
-- scrollbar.
local function GridBox()
    local pw = panel:GetWidth()
    if not pw or pw < 200 then pw = 700 end
    local left = PAD
    local right = pw - RAIL_W - SCROLL_W - PAD
    -- Combined's arrows have a margin of their own at each end; drawn over the
    -- grid, they sat on the first tab's icon and the last one's gear (review).
    if AT_WB._paging then
        left = left + ARROW_W
        right = right - ARROW_W
    end
    return left, math.max(STRIDE, right - left)
end

-- Lay out only the visible window of rows, for one column (Single) or several
-- (Combined), offset by AT_WB.scrollRow.
function AT_WB.Layout()
    if not panel or not panel:IsShown() then return end
    local cols = AT_WB._cols or {}
    if #cols == 0 then
        ClearHover()
        hideFrom(AT_WB.cells, 1)
        hideFrom(AT_WB.colHeads, 1)
        AT_WB.UpdateScrollBar(0, 0)   -- nothing to scroll: no bar
        return
    end

    local left, width = GridBox()
    local n = #cols
    local colW = (width - (n - 1) * COL_GAP) / n
    local perRow = math.max(1, math.floor((colW + (STRIDE - ICON)) / STRIDE))
    local visible = ScrollBounds(0, panel:GetHeight(), 0)

    -- Rows: enough for the longest column, and never fewer than fill the view,
    -- so a tab reads as a bank with empty slots rather than a short list.
    local longest = 0
    for _, col in ipairs(cols) do
        col.rows = math.ceil(#col.entries / perRow)
        if col.rows > longest then longest = col.rows end
    end
    local rowCount = math.max(longest, visible)
    local _, maxStart, start = ScrollBounds(rowCount, panel:GetHeight(), AT_WB.scrollRow)
    AT_WB.scrollRow = start
    AT_WB.UpdateScrollBar(maxStart, start)

    local ci = 0
    for c, col in ipairs(cols) do
        local x0 = left + (c - 1) * (colW + COL_GAP)
        local gridW = perRow * STRIDE - (STRIDE - ICON)
        local gx = x0 + math.floor((colW - gridW) / 2)

        local head = getColHead(c)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", panel, "TOPLEFT", x0, -HEAD_H)
        head:SetWidth(colW)
        head.name:SetText(col.title)
        head.icon:SetTexture(col.icon)
        head.icon:SetShown(n > 1)
        head.icon:ClearAllPoints()
        head.name:ClearAllPoints()
        if n > 1 then
            head.icon:SetPoint("LEFT", head, "LEFT", 0, 0)
            head.name:SetPoint("LEFT", head.icon, "RIGHT", 6, 0)
        else
            head.name:SetPoint("CENTER", head, "CENTER", 0, 0)
        end
        head.gear.key = col.key
        head.gear:ClearAllPoints()
        if n > 1 then head.gear:SetPoint("RIGHT", head, "RIGHT", 0, 0)
        else head.gear:SetPoint("LEFT", head.name, "RIGHT", 8, 0) end
        head.gear:SetShown(type(col.key) == "number")
        head:Show()

        for slot = 0, visible - 1 do
            local r = start + slot
            if r >= rowCount then break end
            for k = 1, perRow do
                local e = col.entries[r * perRow + k]
                ci = ci + 1
                local cell = getCell(ci)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", panel, "TOPLEFT", gx + (k - 1) * STRIDE, -(ROW_TOP + slot * STRIDE))
                FillCell(cell, e)
                cell:Show()
            end
        end
    end
    hideFrom(AT_WB.cells, ci + 1)
    hideFrom(AT_WB.colHeads, n + 1)
    ReconcileHover()
    AT_WB.ApplySearchDim()
end

-- Search dims what is on screen, in every column; it does not decide what is
-- shown, and a match in a tab that is off screen stays off screen.
local function ApplySearchDim()
    local q = AT_WB.search or ""
    for i = 1, #AT_WB.cells do
        local cell = AT_WB.cells[i]
        if cell:IsShown() and cell.entry then
            local match = (q == "")
            if not match then
                local nm = cell.itemName
                match = nm and nm:lower():find(q, 1, true) and true or false
            end
            cell.icon:SetDesaturated(not match)
            cell:SetAlpha(match and 1 or 0.25)
        end
    end
end
AT_WB.ApplySearchDim = ApplySearchDim

-- The rail's step: as tall as the buttons want, shorter when the panel cannot
-- fit them all - eight tabs, Other and "+" ran off a short window and over the
-- status line (review of #154).
local function RailStep(count, panelH)
    local ph = (panelH and panelH >= 50) and panelH or 400
    local room = ph - HEAD_H - FOOT_H - PAD
    return math.max(24, math.min(RAIL_BTN + 8, math.floor(room / math.max(1, count))))
end
AT_WB.RailStep = RailStep

local function LayoutRail(pages, shown, tabs)
    local pw = panel:GetWidth()
    if not pw or pw < 200 then pw = 700 end
    local step = RailStep(#pages + 1, panel:GetHeight())
    local size = math.min(RAIL_BTN, step - 6)
    local x = pw - RAIL_W + (RAIL_W - size) / 2 - 4
    local ar, ag, ab = Accent()
    local i = 0
    for _, key in ipairs(pages) do
        i = i + 1
        local b = getTabBtn(i)
        b.isAdd, b.key = false, key
        local name, icon = TabMeta(key, tabs)
        b.tip = name
        b.icon:SetTexture(icon)
        b.icon:Show()
        b.plus:SetText("")
        b:SetBackdropColor(0, 0, 0, 0.35)
        b.shown = shown[key] and true or false
        if shown[key] then b:SetBackdropBorderColor(ar, ag, ab, 1)
        else b:SetBackdropBorderColor(1, 1, 1, 0.15) end
        b:SetAlpha(1)
        b:ClearAllPoints()
        b:SetSize(size, size)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -(HEAD_H + (i - 1) * step))
        b:Show()
    end
    -- "+", disabled at the cap.
    i = i + 1
    local add = getTabBtn(i)
    add.isAdd, add.key = true, nil
    add.tip = (#tabs >= M.MAX_TABS) and ("At most " .. M.MAX_TABS .. " tabs") or "Add a tab"
    add.icon:Hide()
    add.plus:SetText("+")
    add.plus:SetTextColor(ar, ag, ab)
    add:SetBackdropColor(0, 0, 0, 0.35)
    add:SetBackdropBorderColor(1, 1, 1, 0.15)
    add:SetEnabled(#tabs < M.MAX_TABS)
    add:SetAlpha(#tabs < M.MAX_TABS and 1 or 0.35)
    add:ClearAllPoints()
    add:SetSize(size, size)
    add:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -(HEAD_H + (i - 1) * step))
    add:Show()
    hideFrom(AT_WB.tabBtns, i + 1)
end

------------------------------------------------------------
-- Refresh
------------------------------------------------------------

local scopeBtns, viewBtns = {}, {}
local prevBtn, nextBtn

local function UpdateControls()
    SetActive(viewBtns.single, View() ~= "combined")
    SetActive(viewBtns.combined, View() == "combined")
    SetActive(scopeBtns.personal, Scope() == "personal")
    SetActive(scopeBtns.warband, Scope() ~= "personal")
    local personal = Scope() == "personal"
    rulesetBtn.label:SetText(personal and "This character" or RulesetText())
    rulesetBtn.chevron:SetShown(not personal)
    rulesetBtn:SetEnabled(not personal)
    rulesetBtn:SetAlpha(personal and 0.5 or 1)
    factionBtn.label:SetText(personal and "This character" or FactionText())
    factionBtn.chevron:SetShown(not personal)
    factionBtn:SetEnabled(not personal)
    factionBtn:SetAlpha(personal and 0.5 or 1)
    -- Reset compares the saved CHOICE, not the side it resolves to: "Alliance"
    -- picked while playing Alliance is still not the default.
    resetBtn:SetShown(not personal and not FiltersAtDefault())
end

local function StatusText()
    local w = AT_WB._window
    local paging = (w and #w.pages > M.COMBINED)
        and ("Tabs " .. w.first .. "-" .. (w.first + w.width - 1) .. " of " .. #w.pages .. "  ·  ") or ""
    if Scope() == "personal" then
        local me = AltStableDB and UnitGUID and AltStableDB[UnitGUID("player")]
        return paging .. ((me and me.name) or "This character")
            .. (MailOn() and "  ·  Bags, bank + mail" or "  ·  Bags + bank") .. "  ·  Read-only"
    end
    local r = M.ResolveRuleset(RulesetChoice(), Here())
    local f = M.ResolveFaction(FactionChoice(), MyFaction())
    return paging .. (MailOn() and "Bags, banks + mail  ·  " or "Bags + banks  ·  ")
        .. (r or "All rulesets") .. "  ·  " .. (f or "Both factions") .. "  ·  Read-only"
end

AT_WB.StatusText = function() return StatusText() end

-- Redraws asked for by data - a scan, a received inventory, the sheet's
-- refresh (#435): at most one per frame, however many records a sync brings,
-- and none while the tab is off screen. Closing the sheet hides the window
-- without OnDeactivate, and IsShown stays true under a hidden parent: the
-- panel is marked dirty instead, and drawn once when it shows again (OnShow).
-- Any draw consumes `dirty`, so a draw made meanwhile (Activate, a click)
-- leaves the queued one nothing to do. Legacy's pattern (L.RequestRefresh).
-- What the player does still redraws at once: the click answers in its frame.
function AT_WB.RequestRefresh()
    if not AT_WB.isActive then return end
    AT_WB.dirty = true
    if AT_WB._pending or not (panel and panel:IsVisible()) then return end
    AT_WB._pending = true
    C_Timer.After(0, function()
        AT_WB._pending = nil
        if AT_WB.isActive and AT_WB.dirty and panel and panel:IsVisible() then AT_WB.Refresh() end
    end)
end

-- Recompute what is shown from current data, then lay out.
function AT_WB.Refresh()
    if not panel or not panel:IsShown() then return end
    AT_WB.dirty = nil
    UpdateControls()

    local filter = CurrentFilter()
    local agg = gather(filter)
    local tabs = Tabs()
    if not next(agg) then
        AT_WB._cols = {}
        hideFrom(AT_WB.cells, 1)
        hideFrom(AT_WB.colHeads, 1)
        AT_WB.UpdateScrollBar(0, 0)   -- nothing left to scroll
        AT_WB._window, AT_WB._paging = nil, false
        statusFS:SetText(StatusText())
        LayoutRail(M.Pages(#tabs, false), {}, tabs)
        prevBtn:Hide(); nextBtn:Hide()
        local me = UnitGUID and UnitGUID("player")
        emptyFS:SetText((Scope() == "personal" and not (AltStableDB and AltStableDB[me]))
            and "This character has not been scanned yet - open your bags, or your bank."
            or "Nothing here yet. Log in on your alts (and open a bank) to fill it.")
        emptyFS:Show()
        return
    end
    emptyFS:Hide()

    local perTab, other = M.Distribute(BuildEntries(agg), tabs)
    local pages = M.Pages(#tabs, #other > 0)
    local sel = M.RepairSelection(Cfg("warbandTab", 1), pages)
    if sel ~= Cfg("warbandTab", 1) then AltStable.SetConfigValue("warbandTab", sel) end

    local keys
    if View() == "combined" then
        local first, width = M.CombinedWindow(pages, sel, AT_WB._first)
        AT_WB._first = first
        keys = {}
        for i = first, first + width - 1 do keys[#keys + 1] = pages[i] end
        AT_WB._paging = #pages > M.COMBINED
        prevBtn:SetShown(AT_WB._paging)
        nextBtn:SetShown(AT_WB._paging)
        prevBtn:SetEnabled(first > 1)
        nextBtn:SetEnabled(first + width - 1 < #pages)
        AT_WB._window = { first = first, width = width, pages = pages }
    else
        keys = { sel }
        prevBtn:Hide(); nextBtn:Hide()
        AT_WB._paging = false
        AT_WB._window = nil
    end

    local cols, shown = {}, {}
    for _, key in ipairs(keys) do
        local title, icon = TabMeta(key, tabs)
        cols[#cols + 1] = {
            key = key, title = title, icon = icon,
            entries = (key == "other") and other or (perTab[key] or {}),
        }
        shown[key] = true
    end
    AT_WB._cols = cols
    statusFS:SetText(StatusText())
    LayoutRail(pages, shown, tabs)
    AT_WB.Layout()
end

-- Combined's arrows: move the window by one page, keeping the selection on the
-- page that enters.
local function StepWindow(delta)
    local w = AT_WB._window
    if not w then return end
    local target = delta < 0 and w.pages[w.first - 1] or w.pages[w.first + w.width]
    if target then Select(target) end
end

------------------------------------------------------------
-- Panel + activation
------------------------------------------------------------

local function BuildPanel(mainFrame)
    if panel then return end
    EnsureTooltipHook()
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30

    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    -- Beside the sidebar's edge, so it follows when the sidebar collapses (#150).
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 1)
    -- Reaches BOTTOMRIGHT (0, 1), so under glass this panel owns the window's
    -- bottom-right corner and its fill has to be clipped to the window outline.
    -- A backdrop cannot be masked; SkinPanelFill paints a texture instead.
    if not AltStable.SkinPanelFill(panel, mainFrame, AltStable.C.BG_MAIN) then
        AltStable.ApplyBGOnly(panel, AltStable.C.BG_MAIN[1], AltStable.C.BG_MAIN[2], AltStable.C.BG_MAIN[3], AltStable.C.BG_MAIN[4])
    end
    panel:Hide()
    -- Anything open goes with the panel: a menu or dialog left up over another
    -- tab would act on a view that is not there.
    panel:SetScript("OnHide", function()
        CloseMenus()
        CloseDialog()
        ClearHover()
    end)
    -- The sheet opened again on this tab: what changed while it was closed (#435).
    panel:SetScript("OnShow", function()
        if AT_WB.isActive and AT_WB.dirty then AT_WB.Refresh() end
    end)

    titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD + 2)
    titleFS:SetText("Warband Inventory")
    titleFS:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))

    searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    searchBox:SetSize(200, 20)
    searchBox:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -PAD + 2)
    searchBox:HookScript("OnTextChanged", function(self)
        AT_WB.search = (self:GetText() or ""):lower()
        ApplySearchDim()
    end)

    -- The controls row: Single | Combined, the tooltip opt-in, the ruleset.
    local rowY = -(PAD + 30)
    viewBtns.single = MakeButton(panel, 76, 22, "Single", function() AT_WB.SetView("single") end)
    viewBtns.single:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, rowY)
    viewBtns.combined = MakeButton(panel, 86, 22, "Combined", function() AT_WB.SetView("combined") end)
    viewBtns.combined:SetPoint("LEFT", viewBtns.single, "RIGHT", 2, 0)

    -- The global item-tooltip enrichment: on by default unless another addon
    -- shows counts (#304). Also in Options; it shows the setting in effect,
    -- refreshed on every Activate, and a click makes it the player's own choice.
    local tipCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    AT_WB.tipCheck = tipCheck
    tipCheck:SetSize(18, 18)
    tipCheck:SetPoint("LEFT", viewBtns.combined, "RIGHT", 16, 0)
    tipCheck:SetChecked(AltStable.ItemTooltipCountsOn and AltStable.ItemTooltipCountsOn() or false)
    tipCheck:SetScript("OnClick", function(self)
        -- Through the config seam (Config.lua), like every other setting write.
        AltStable.SetConfigValue("warbandItemTooltips", self:GetChecked() and true or false)
    end)
    local tipLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tipLbl:SetPoint("LEFT", tipCheck, "RIGHT", 2, 0)
    -- Short, to leave the row room for both filter menus (#461); the hover
    -- help spells it out.
    tipLbl:SetText("Counts in tooltips")
    tipLbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
    tipCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        AltStable.ItemTooltipCountsHelp(GameTooltip)
        GameTooltip:Show()
    end)
    tipCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rulesetBtn = MakeButton(panel, 200, 22, "", OpenRulesetMenu)
    rulesetBtn:SetPoint("LEFT", tipLbl, "RIGHT", 16, 0)
    rulesetBtn.chevron = rulesetBtn:CreateTexture(nil, "OVERLAY")
    rulesetBtn.chevron:SetSize(12, 12)
    rulesetBtn.chevron:SetPoint("RIGHT", -8, 0)
    rulesetBtn.chevron:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

    -- The faction filter (#461), then the reset for both.
    factionBtn = MakeButton(panel, 130, 22, "", OpenFactionMenu)
    factionBtn:SetPoint("LEFT", rulesetBtn, "RIGHT", 6, 0)
    factionBtn.chevron = factionBtn:CreateTexture(nil, "OVERLAY")
    factionBtn.chevron:SetSize(12, 12)
    factionBtn.chevron:SetPoint("RIGHT", -8, 0)
    factionBtn.chevron:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

    resetBtn = MakeButton(panel, 22, 22, "", ResetFilters)
    resetBtn:SetPoint("LEFT", factionBtn, "RIGHT", 6, 0)
    resetBtn.icon = resetBtn:CreateTexture(nil, "OVERLAY")
    resetBtn.icon:SetSize(14, 14)
    resetBtn.icon:SetPoint("CENTER")
    resetBtn.icon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    local onEnter, onLeave = resetBtn:GetScript("OnEnter"), resetBtn:GetScript("OnLeave")
    resetBtn:SetScript("OnEnter", function(self)
        onEnter(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset filters", 1, 1, 1)
        GameTooltip:AddLine("Back to the current ruleset and the current faction.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        onLeave(self)
        GameTooltip:Hide()
    end)
    resetBtn:Hide()

    -- Combined's paging arrows, either side of the column titles.
    prevBtn = MakeButton(panel, 22, 22, "<", function() StepWindow(-1) end)
    prevBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -HEAD_H + 1)
    nextBtn = MakeButton(panel, 22, 22, ">", function() StepWindow(1) end)
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(RAIL_W + SCROLL_W + PAD), -HEAD_H + 1)
    prevBtn:Hide(); nextBtn:Hide()

    -- The bottom bar: Personal Bank / Warband, and what is being shown.
    scopeBtns.personal = MakeButton(panel, 110, 24, "Personal Bank", function()
        CloseMenus()
        AltStable.SetConfigValue("warbandScope", "personal"); AT_WB.scrollRow = 0; AT_WB.Refresh()
    end)
    scopeBtns.personal:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, 6)
    scopeBtns.warband = MakeButton(panel, 110, 24, "Warband", function()
        AltStable.SetConfigValue("warbandScope", "warband"); AT_WB.scrollRow = 0; AT_WB.Refresh()
    end)
    scopeBtns.warband:SetPoint("LEFT", scopeBtns.personal, "RIGHT", 4, 0)
    statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 12)
    statusFS:SetTextColor(unpack(AltStable.C.TEXT_DIM))

    -- Virtual scroll: the wheel shifts which rows are laid out (cells are direct
    -- panel children, so hover works — a real ScrollFrame ate the mouse events).
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        AT_WB.scrollRow = math.max(0, (AT_WB.scrollRow or 0) - delta * 2)
        AT_WB.Layout()
    end)

    emptyFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(ROW_TOP + 6))
    emptyFS:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    emptyFS:Hide()

    -- Scrollbar. The wheel already scrolls, but nothing showed there was more
    -- below - and a grid whose last group is off-screen just looks short. Built
    -- from a bare Slider rather than a scroll-frame template: the cells are
    -- direct children of the panel (a ScrollFrame swallowed their hover), and
    -- template names differ across builds.
    --
    -- Built LAST in this function: BuildPanel early-returns once `panel` is
    -- assigned, so a widget call that failed here would leave the panel
    -- half-built for the session - emptyFS nil, and the next data-less Refresh
    -- throwing on it. The bar is the expendable part, so it goes at the end.
    -- SetObeyStepOnDrag is measured on this build (Slider:SetObeyStepOnDrag in
    -- the build-matched API dump); SheetUI omits it because TBC 2.5.x lacked it.
    local scrollBar = CreateFrame("Slider", nil, panel)
    AT_WB.scrollBar = scrollBar
    scrollBar:SetWidth(10)
    scrollBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(RAIL_W + 2), -ROW_TOP)
    scrollBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -(RAIL_W + 2), FOOT_H + PAD)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetValueStep(1)
    scrollBar:SetObeyStepOnDrag(true)
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(10, 32)
    scrollBar:SetThumbTexture(thumb)
    scrollBar:SetScript("OnValueChanged", function(self, value)
        if self._syncing then return end
        AT_WB.scrollRow = math.floor((value or 0) + 0.5)
        AT_WB.Layout()
    end)
    scrollBar:Hide()
end

local function HookRefresh()
    if AT_WB._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        -- Asked for BEFORE the sheet's own refresh (Codex review of #469): that
        -- can finish a window animation, whose settle redraws this panel
        -- through OnResize with the new data, consuming the request. Asked
        -- after, it would rebuild a second time for the same update.
        if AT_WB.isActive then AT_WB.RequestRefresh() end
        prev(...)
    end
    AT_WB._refreshHooked = true
end

-- The panel's floor, as a window size: on activation, and again whenever the
-- window changes under the tab - expanding the sidebar narrows the panel by
-- 174px while the window keeps its width (#157 review).
function AT_WB.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local sidebarW = (AltStable.LAYOUT and AltStable.LAYOUT.SIDEBAR_WIDTH) or 230
    local titleH   = (AltStable.LAYOUT and AltStable.LAYOUT.TITLE_H) or 30
    AltStable.EnsureWindowMinSize(sidebarW + 1 + MIN_PANEL_W, titleH + 1 + MIN_PANEL_H)
end

-- The size each view opens at (#150): Single is its floor, a retail-style
-- 14-wide tab; Combined holds three tabs at seven icons each (3 x 274 + the
-- gaps, the rail, the scroll bar and the paging arrows = 1006). The window
-- height is the one every plugin tab shares.
AT_WB.PREFERRED_PANEL_W = { single = MIN_PANEL_W, combined = 1010 }
function AT_WB.RequestPreferredSize()
    if not AltStable.RequestPluginSize then return end
    AltStable.RequestPluginSize(AT_WB.PREFERRED_PANEL_W[View()] or MIN_PANEL_W)
end

-- Single <-> Combined: the view and its size, gliding like a tab switch
-- rather than jumping (#150). The LAYOUT is the animator's to place, through
-- OnResize (the floor, then Refresh): at the end of a trip that grows, so
-- Combined's columns never stand past a window still on its way there, and
-- before one that shrinks. Refreshing here as well laid Combined out at its
-- final width before the trip and gathered every bag twice (#191 review).
function AT_WB.SetView(view)
    if View() == view then return end
    local function apply()
        AltStable.SetConfigValue("warbandView", view)
        AT_WB.scrollRow = 0
        AT_WB.RequestPreferredSize()
    end
    if AltStable.AnimateWindowChange then AltStable.AnimateWindowChange(apply) else apply() end
end

function AT_WB.Activate(mainFrame)
    BuildPanel(mainFrame)
    HookRefresh()
    -- Options may have changed the setting since the panel was built (#304).
    if AT_WB.tipCheck and AltStable.ItemTooltipCountsOn then
        AT_WB.tipCheck:SetChecked(AltStable.ItemTooltipCountsOn())
    end
    AT_WB.isActive = true
    AT_WB.RequestPreferredSize()
    AT_WB.HoldMinSize()

    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Hide()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Hide() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Hide() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Hide() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Hide()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Hide()    end

    panel:Show()
    ScanBags()                     -- freshen our own bags on open
    if isBankOpen then ScanBank() end
    AT_WB.Refresh()
end

function AT_WB.Deactivate(mainFrame)
    AT_WB.isActive = false
    AT_WB.dirty = nil   -- Activate draws afresh
    if panel then panel:Hide() end
    CloseMenus()
    CloseDialog()
    ClearHover()
    if mainFrame.bodyScroll   then mainFrame.bodyScroll:Show()   end
    if mainFrame.frozenScroll then mainFrame.frozenScroll:Show() end
    if mainFrame.headerScroll then mainFrame.headerScroll:Show() end
    if mainFrame.frozenHeader then mainFrame.frozenHeader:Show() end
    if mainFrame.hScrollBar   then mainFrame.hScrollBar:Show()   end
    if mainFrame.totalsBar    then mainFrame.totalsBar:Show()    end
end

------------------------------------------------------------
-- Bootstrap + events
------------------------------------------------------------

local eventFrame   -- the plugin's event frame, for the tests (set below)

local function BootstrapPlugin()
    if not AltStable or not AltStable.RegisterPlugin then
        Print("AltStable not found — make sure it is installed and enabled.")
        return
    end
    EnsureTooltipHook()   -- install now so the global item-tooltip option works pre-panel
    InstallMailHooks()    -- mail sent or returned to your own characters (#312)
    -- Who holds an item, for other plugins (Professions' reagents, #268). Set
    -- only while this plugin is loaded: absent means "not counted", never "none".
    AltStable.ItemHolders = CountItem
    AltStable.ItemMapsFor = ItemMapsFor
    AltStable.RegisterPlugin({
        id            = ADDON_ID,
        label         = "Warband",
        icon          = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
                        .. "Icons\\warband.tga",
        _isPlugin     = true,
        OnActivate    = function(mf) AT_WB.Activate(mf) end,
        -- The window changed size under us: maximize, restore, the sidebar (#150).
        OnResize      = function()
            if not AT_WB.isActive then return end
            AT_WB.HoldMinSize()
            AT_WB.Refresh()
        end,
        OnDeactivate  = function(mf) AT_WB.Deactivate(mf) end,
        OnSerialize   = function(g, s) return SerializePlayer(g, s) end,
        OnDeserialize = function(g, b) return DeserializePlayer(g, b) end,
        -- Our blob is judged by its own stamps (the overall one, then the
        -- bank's), so it is applied even when the record carrying it loses the
        -- core merge (Codex review of #438): PC 1 reads the alt's bank at 100,
        -- PC 2 (Warband off) plays it at 130, and a peer that heard PC 2 first
        -- would otherwise refuse PC 1's bank with PC 1's older record, for good.
        independentStamp = true,
        OnCleanup     = function(keepGuid) CleanupWarbandDB(keepGuid) end,
        DropForgottenOrphans = function()
            return AltStable.DropForgottenOrphans and AltStable.DropForgottenOrphans(AltStableWarbandDB) or 0
        end,
        -- #65: a forgotten character's bags and bank go with its record, or
        -- they sit in SavedVariables for good - for a character nothing shows.
        OnForget      = function(guid)
            if guid and AltStableWarbandDB then AltStableWarbandDB[guid] = nil end
        end,
        _wb           = AT_WB,
        _test = {
            SerializePlayer = SerializePlayer, DeserializePlayer = DeserializePlayer,
            gather = gather, ScanBags = ScanBags, ScanBank = ScanBank, CountItem = CountItem,
            EncodeMap = EncodeMap, ParseMap = ParseMap, mapsEqual = mapsEqual,
            OnBagUpdate = OnBagUpdate, OnBankOpened = OnBankOpened, OnBankClosed = OnBankClosed,
            OnBagUpdateDelayed = OnBagUpdateDelayed, IsBankDirty = function() return bankDirty end,
            EventFrame = function() return eventFrame end,
            NewSession = function() bagsConfirmed = false end,
            CarriedBagIDs = CarriedBagIDs, BankTabIDs = BankTabIDs, IsBankContainer = IsBankContainer,
            CleanupWarbandDB = CleanupWarbandDB,
            InvalidateTabCache = InvalidateTabCache, BootstrapPlugin = BootstrapPlugin,
            OnBankTabsChanged = OnBankTabsChanged,
            ScanContainerSet = ScanContainerSet, EnsureTooltipHook = EnsureTooltipHook,
            ScanMail = ScanMail, OnMailShow = OnMailShow, OnMailInboxUpdate = OnMailInboxUpdate,
            OnMailClosed = OnMailClosed, OnMailSendSuccess = OnMailSendSuccess, OnMailFailed = OnMailFailed,
            OwnCharacterGuid = OwnCharacterGuid, Incoming = Incoming, MailOn = MailOn,
            EncodeOutbox = EncodeOutbox, ParseOutbox = ParseOutbox, AppendBreakdown = AppendBreakdown,
        },
    })

    -- Full-baseline pull when we hold no inventory at all: the peer watermark
    -- may already be ahead of data we never received, which a delta pull would
    -- never backfill. Inventory for a guid no character record mentions is
    -- invisible in the UI, so it does not count as "we hold data" (counting it
    -- would skip the pull and leave the real inventory unfetched).
    --
    -- NOT on "loaded on demand": the core loads enabled plugins from its own
    -- PLAYER_LOGIN handler, so IsLoggedIn() is already true and EVERY login
    -- took that branch. That reset every peer watermark about a second before
    -- the login sync, turning every session into a full-database pull (minutes
    -- on a large database). Holding data is the only signal that matters.
    --
    -- First, the orphans of characters forgotten while this plugin was off
    -- (their forget never reached OnForget): the only orphans that go.
    if AltStable.DropForgottenOrphans then AltStable.DropForgottenOrphans(AltStableWarbandDB) end
    if AltStable.ResetPeerWatermarks and AltStable.HoldsAttached then
        local hasData = AltStable.HoldsAttached(AltStableWarbandDB, function(cdb)
            return type(cdb) == "table"
               and ((cdb.bags and next(cdb.bags)) or (cdb.bank and next(cdb.bank))) and true or false
        end)
        if not hasData then AltStable.ResetPeerWatermarks() end
    end

    C_Timer.After(3, ScanBags)   -- prime our own bags after the login event storm
end

local frame = CreateFrame("Frame")
eventFrame = frame
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BAG_UPDATE_DELAYED")     -- the end of a batch: the bank read (#419)
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("BANK_TABS_CHANGED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("MAIL_CLOSED")          -- never seen on Forever; the HIDE below closes
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_FAILED")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "MAIL_SHOW" then
        OnMailShow()
    elseif event == "MAIL_INBOX_UPDATE" then
        OnMailInboxUpdate()
    elseif event == "MAIL_CLOSED" then
        OnMailClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        OnInteractionHide(arg1)
    elseif event == "MAIL_SEND_SUCCESS" then
        OnMailSendSuccess()
    elseif event == "MAIL_FAILED" then
        OnMailFailed()
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(1, BootstrapPlugin)
    elseif event == "BAG_UPDATE" then
        OnBagUpdate(arg1)
    elseif event == "BANKFRAME_OPENED" then
        OnBankOpened()
    elseif event == "BANKFRAME_CLOSED" then
        OnBankClosed()
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        if isBankOpen then bankDirty = true; ScheduleBank() end
    elseif event == "BAG_UPDATE_DELAYED" then
        OnBagUpdateDelayed()
    elseif event == "BANK_TABS_CHANGED" then
        OnBankTabsChanged(arg1)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local id, success = arg1, arg2
        if id and success and requestedIDs[id] then
            requestedIDs[id] = nil
            if AT_WB.isActive then
                if self._metaTimer then self._metaTimer:Cancel() end
                self._metaTimer = C_Timer.NewTimer(0.2, function()
                    self._metaTimer = nil
                    if AT_WB.isActive and AT_WB.RequestRefresh then AT_WB.RequestRefresh() end
                end)
            end
        end
    end
end)

-- Loaded on demand after login (the usual path: the core loads enabled plugins
-- from its PLAYER_LOGIN handler), so PLAYER_LOGIN will not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, BootstrapPlugin)
end
