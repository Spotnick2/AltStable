------------------------------------------------------------
-- test_warband_mail.lua - mailbox items in the Warband (#312)
--
-- Pinned:
--   * the inbox is read only while a mailbox is open and its contents have
--     arrived, summed by item id, replaced whole on each read, and recorded only
--     when something changed (or mail on its way to this character is pending);
--   * the inbox is read through LibMailbox-1.0 (#326): a scan it can't read
--     whole (a link not there, a secret, a missing row) or a count of nothing
--     aborts the read, and a library that isn't ready reads nothing; currency
--     attachments are not items; mail the game holds back is counted as unread;
--   * mail sent or returned to one of our characters is kept on the SENDER's
--     record and counts for the recipient until the recipient's next inbox read
--     or 30 days; only once the server confirms a send; a stranger is nobody;
--   * the item counts and the grid include mail, the tooltip says where it is,
--     and Professions' reagents do not (test_professions);
--   * sync: the mail fields come after the old ones, an older reader still reads
--     the old ones, and a blob without them (or never read, or older) keeps
--     what is held;
--   * the setting: off reads, records, shows and sends no mail.
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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
-- The inbox is read through the LibMailbox-1.0 AltStable embeds (#326).
dofile("tests/libmailbox.lua")
local LM = LoadMailbox()
dofile("Plugins/Warband/WarbandTabs.lua")
dofile("Plugins/Warband/AltStableWarband.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "warband" then plugin = p end end
assert(plugin, "the Warband plugin registers")
local T = plugin._test

local ME = UnitGUID("player")
local B, C = "Player-1-0000000B", "Player-1-0000000C"
local function resetDB()
    AltStableDB = {
        [ME] = { guid = ME, name = "Kaleid Sumner", class = "MAGE",    realm = "PvE" },
        [B]  = { guid = B,  name = "Elegia Moon",   class = "PRIEST",  realm = "PvE" },
        [C]  = { guid = C,  name = "Kalizo Sun",    class = "WARRIOR", realm = "PvP" },
    }
    AltStableWarbandDB = {}
    AltStableConfig.warbandMail = nil
end
resetDB()

-- A mailbox, as the client reads it: mails of { sender, items = { {id, count, currency} } }.
-- A mail with `missing` has no header row yet; an item with `nolink` no link.
local inbox, inboxTotal = {}, nil
GetInboxNumItems = function() return #inbox, inboxTotal or #inbox end
GetInboxHeaderInfo = function(i)
    local m = inbox[i]
    if not m or m.missing then return nil end
    return nil, nil, m.sender, "subject", 0, 0, 30, #m.items
end
GetInboxItem = function(i, a)
    local it = inbox[i] and inbox[i].items[a]
    if not it then return nil end
    return "item " .. it[1], it[1], 134400, it[2], 1, true, it[3] or false
end
GetInboxItemLink = function(i, a)
    local it = inbox[i] and inbox[i].items[a]
    if not it or it.nolink then return nil end
    return "|Hitem:" .. it[1] .. "::::::::16:1485|h[item]|h"
end

local function openMailbox()
    WoW.fire("MAIL_SHOW")
    WoW.fire("MAIL_INBOX_UPDATE")
    WoW.flushTimers()
end
local function mine() return AltStableWarbandDB[ME] or {} end

------------------------------------------------------------
-- Reading the inbox
------------------------------------------------------------

inbox = {
    { sender = "Auction House", items = { { 2318, 5 } } },
    { sender = "Elegia Moon",   items = { { 2318, 3 }, { 4306, 2 }, { 99999, 40, true } } },
    { sender = "Someone Else",  items = {} },
}
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("an inbox update with no mailbox open reads nothing", mine().mail, nil)
WoW.fire("MAIL_SHOW"); T.ScanMail()
eq("a mailbox whose contents have not arrived is not read", mine().mail, nil)
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("once they arrive, the attachments are summed by item", mine().mail and mine().mail[2318], 8)
eq("  every item", mine().mail[4306], 2)
eq("  but not currency", mine().mail[99999], nil)
eq("  stamped with the read", mine().mailStamp, WoW.now)
eq("  which moves the record's watermark", mine().stamp, WoW.now)
eq("  nothing held back", mine().mailMore, 0)

-- Unchanged: no new stamp, so a mailbox visit doesn't churn the sync.
local first = WoW.now
WoW.now = WoW.now + 60
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("an unchanged read is not recorded again", mine().mailStamp, first)

-- An attachment taken: the bags change while the mailbox is open.
inbox[1].items = {}
WoW.fire("BAG_UPDATE", 0); WoW.flushTimers()
eq("taking an attachment rereads the inbox", mine().mail[2318], 3)
eq("  and stamps it", mine().mailStamp, WoW.now)

-- An inbox the library can't read whole: keep the last good read.
WoW.now = WoW.now + 60
inbox[2].items[1] = { 2318, 3, nolink = true }
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("an attachment without its link leaves the last read alone", mine().mail[2318], 3)
inbox[2].items[1] = { 2318, WoW.secret(3) }
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("  so does a secret count", mine().mail[2318], 3)
inbox[2].items[1] = { 2318, 3 }
inbox[2].missing = true
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("  and a header row that didn't come back", mine().mail[2318], 3)
inbox[2].missing = nil
eq("  none of them stamped", mine().mailStamp, WoW.now - 60)
inbox[2].items[2] = { 4306, 0 }
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("  and a count of nothing", mine().mail[4306], 2)
inbox[2].items[2] = { 4306, 2 }
-- A count the library takes as one (it can't tell missing from 1).
inbox[2].items[1] = { 2318, nil }
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("an attachment without a count counts one (the library's rule)", mine().mail[2318], 1)
inbox[2].items[1] = { 2318, 3 }

-- More mail than the game shows.
inboxTotal = 62
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("mail past what the game shows is counted as unread", mine().mailMore, 62 - 3)
inboxTotal = nil

-- Closing reads once more, then nothing is read until the next visit.
inbox[2].items = { { 2318, 1 } }
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
eq("closing the mailbox reads it one last time", mine().mail[2318], 1)
inbox[2].items = {}
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("  and after that nothing is read", mine().mail[2318], 1)
WoW.fire("BAG_UPDATE", 0); WoW.flushTimers()
eq("  nor on a bag change away from the mailbox", mine().mail[2318], 1)

-- The close is the interaction's HIDE (17), and nothing else's.
inbox[2].items = { { 2318, 2 } }
WoW.fire("MAIL_SHOW"); WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("a new visit reads again", mine().mail[2318], 2)
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)   -- a merchant, say
inbox[2].items = { { 2318, 4 } }
WoW.fire("BAG_UPDATE", 0); WoW.flushTimers()
eq("another window's close leaves the mailbox open", mine().mail[2318], 4)
-- A scan queued in the visit, then the close: the queued scan reads nothing.
inbox[2].items = { { 2318, 6 } }
WoW.fire("MAIL_INBOX_UPDATE")
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
eq("the close reads the last time", mine().mail[2318], 6)
inbox[2].items = {}
WoW.flushTimers()
eq("  and a scan queued before it reads nothing after", mine().mail[2318], 6)
-- MAIL_CLOSED never fires on Forever; if a later build sends it, it closes too.
WoW.fire("MAIL_SHOW"); WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
WoW.fire("MAIL_CLOSED")
inbox[2].items = { { 2318, 9 } }
WoW.fire("BAG_UPDATE", 0); WoW.flushTimers()
eq("MAIL_CLOSED closes it as well", mine().mail[2318] or 0, 0)

------------------------------------------------------------
-- Who a mail is for
------------------------------------------------------------

eq("a full name is one of ours", T.OwnCharacterGuid("Elegia Moon"), B)
eq("  in any case, with a realm", T.OwnCharacterGuid("elegia moon-PvE"), B)
eq("  or with spaces around it", T.OwnCharacterGuid("  Elegia Moon "), B)
eq("a first name alone is nobody (the server refuses it too)", T.OwnCharacterGuid("Elegia"), nil)
eq("a stranger is nobody", T.OwnCharacterGuid("Stranger Person"), nil)
eq("nothing is nobody", T.OwnCharacterGuid(nil), nil)
-- Two records under one name (a database can still hold an old one): the realm
-- decides, and without one it is nobody rather than a guess.
AltStableDB.dup = { guid = "dup", name = "Elegia Moon", class = "PRIEST", realm = "PvP" }
eq("two of ours with one name: nobody without a realm", T.OwnCharacterGuid("Elegia Moon"), nil)
eq("  the realm picks one", T.OwnCharacterGuid("Elegia Moon-PvP"), "dup")
AltStableDB.dup = nil

------------------------------------------------------------
-- Mail sent to our own characters
------------------------------------------------------------

resetDB()
local draft = {}
GetSendMailItem = function(i)
    local it = draft[i]
    if not it then return nil end
    return "item " .. it[1], it[1], 134400, it[2], 1
end

draft = { { 2318, 20 }, nil, { 2318, 5 }, { 4306, 1 } }
SendMail("Elegia Moon", "mats", "")
eq("a send is not counted before the server confirms it", mine().outbox, nil)
WoW.fire("MAIL_SEND_SUCCESS")
local box = mine().outbox
eq("a confirmed send to one of ours is kept on the sender's record", box and #box, 1)
eq("  addressed to the recipient", box and box[1].to, B)
eq("  with its items summed", box and box[1].items[2318], 25)
eq("  when it left", box and box[1].at, WoW.now)
eq("  which moves the sender's watermark", mine().stamp, WoW.now)
eq("the recipient's record is not written", AltStableWarbandDB[B], nil)

local total, holders = T.CountItem(2318)
eq("the items count for the recipient, in its mail", total, 25)
eq("  under the recipient", holders[1] and holders[1].guid, B)
eq("  as mail", holders[1] and holders[1].mail, 25)
WoW.fire("MAIL_SEND_SUCCESS")
eq("a second success with no send in between adds nothing", #mine().outbox, 1)

SendMail("Kalizo Sun", "x", "")
WoW.fire("MAIL_FAILED")
WoW.fire("MAIL_SEND_SUCCESS")
eq("a failed send counts nothing", #mine().outbox, 1)

SendMail("Stranger Person", "x", "")
WoW.fire("MAIL_SEND_SUCCESS")
eq("a send to a stranger counts nothing", #mine().outbox, 1)

draft = {}
SendMail("Kalizo Sun", "gold only", "")
WoW.fire("MAIL_SEND_SUCCESS")
eq("a send without items counts nothing", #mine().outbox, 1)

-- The recipient reads its inbox: what arrived is in its own mail now.
WoW.now = WoW.now + 30
AltStableWarbandDB[B] = { mail = { [2318] = 25 }, mailStamp = WoW.now, mailMore = 0 }
total = T.CountItem(2318)
eq("once the recipient has read its inbox, the send stops counting (no double count)", total, 25)

-- The recipient's read must supersede a pending send even when its inbox did
-- not change: the items may already be in its bags.
AltStableWarbandDB[B] = { mail = {}, mailStamp = WoW.now - 1000 }
local realGuid = WoW.player.guid
WoW.player.guid = B
inbox = {}
openMailbox()
WoW.player.guid = realGuid
eq("a read with a send pending is recorded even if the inbox looks the same",
   AltStableWarbandDB[B].mailStamp, WoW.now)
eq("  and the send no longer counts", (T.CountItem(2318)), 0)

-- THE SEND ARRIVES AFTER THE READ (Codex review of #313). B's inbox was empty
-- at its last read; A sends from another account; B takes the item before its
-- scan, so B's inbox reads empty again - unchanged - and B knows of no pending
-- send yet. That read must still be recorded, or the send, synced later,
-- counts as unread mail on top of the item in B's bags.
resetDB()
local sentAt = WoW.now
AltStableWarbandDB[B] = { mail = {}, mailStamp = sentAt - 100, mailMore = 0 }
WoW.now = sentAt + 100
WoW.player.guid = B
inbox = {}
WoW.fire("MAIL_SHOW"); WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("a visit's first read is recorded even when nothing changed", AltStableWarbandDB[B].mailStamp, WoW.now)
-- And its close, for a send that arrived and was taken during the visit.
WoW.now = WoW.now + 50
local midVisitSend = WoW.now - 10
WoW.fire("MAIL_INBOX_UPDATE"); WoW.flushTimers()
eq("  an unchanged read mid-visit is not", AltStableWarbandDB[B].mailStamp, WoW.now - 50)
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
eq("  its close is", AltStableWarbandDB[B].mailStamp, WoW.now)
WoW.player.guid = realGuid
T.DeserializePlayer(ME, ("v1|s=%d|kt=0|b=|k=|mt=0|mm=0|m=|ot=%d|o=%s@%d:2318,4/%s@%d:2318,1")
    :format(midVisitSend, midVisitSend, B, sentAt, B, midVisitSend))
eq("the sends, synced after those reads, count nothing", (T.CountItem(2318)), 0)

resetDB()
WoW.now = sentAt
draft = { { 2318, 20 }, { 2318, 5 } }
SendMail("Elegia Moon", "mats", "")
WoW.fire("MAIL_SEND_SUCCESS")

-- Thirty days on, unopened mail has been returned or deleted.
AltStableWarbandDB[B] = nil
WoW.now = mine().outbox[1].at + 30 * 86400 + 1
eq("a send older than 30 days no longer counts", (T.CountItem(2318)), 0)

-- The next send prunes what no longer counts.
draft = { { 4306, 2 } }
SendMail("Kalizo Sun", "ore", "")
WoW.fire("MAIL_SEND_SUCCESS")
eq("a new send drops entries that no longer count", #mine().outbox, 1)
eq("  keeping the new one", mine().outbox[1].to, C)

-- Returning a mail sends it back to its sender.
resetDB()
inbox = { { sender = "Kalizo Sun", items = { { 2589, 12 } } } }
ReturnInboxItem(1)
box = mine().outbox
eq("a mail returned to one of ours counts for its sender", box and box[1] and box[1].to, C)
eq("  with its items", box and box[1] and box[1].items[2589], 12)
inbox = { { sender = "Stranger Person", items = { { 2589, 1 } } } }
ReturnInboxItem(1)
eq("a mail returned to a stranger counts nothing", #mine().outbox, 1)
inbox = { { sender = "Stranger Person", items = { { 765, 1 } } },
          { sender = "Elegia Moon", items = { { 2589, 4 } } } }
ReturnInboxItem(2)
eq("the returned mail is the one at its index", mine().outbox[2] and mine().outbox[2].items[2589], 4)
eq("  to its sender", mine().outbox[2] and mine().outbox[2].to, B)
eq("  and nothing of the mail before it", mine().outbox[2] and mine().outbox[2].items[765], nil)
inbox = { { sender = "Elegia Moon", items = { { 2589, 4, nolink = true } } } }
ReturnInboxItem(1)
eq("a returned mail that can't be read whole counts nothing", #mine().outbox, 2)
inbox = { { sender = "Elegia Moon", items = { { 2589, 4 }, { 765, 0 } } } }
ReturnInboxItem(1)
eq("  nor one with a count of nothing (not even its other items)", #mine().outbox, 2)

------------------------------------------------------------
-- What is shown
------------------------------------------------------------

resetDB()
AltStableWarbandDB[ME] = { bags = { [2318] = 4 }, bank = { [2318] = 6 }, bankStamp = WoW.now,
                           mail = { [2318] = 7 }, mailStamp = WoW.now, mailMore = 0 }
total, holders = T.CountItem(2318)
eq("the cross-alt count adds the mail", total, 17)
eq("  and the holder says how much is mail", holders[1].mail, 7)
local agg = T.gather()
eq("the Warband grid adds it too", agg[2318] and agg[2318].total, 17)
eq("  and keeps it apart", agg[2318].holders[1].mail, 7)

GameTooltip:ClearLines()
T.AppendBreakdown(GameTooltip, total, holders)
local all = table.concat(WoW.tooltipLines, "\n")
check("the tooltip shows the mail with its icon", all:find("7|TInterface\\Icons\\INV_Letter_15", 1, true) ~= nil, all)
check("  and the character's total over all three", all:find("17=", 1, true) ~= nil, all)
check("  no note while the mail is fresh and whole",
      not all:find("Mail data", 1, true) and not all:find("not read yet", 1, true), all)
AltStableWarbandDB[ME].mailStamp = WoW.now - 8 * 86400
AltStableWarbandDB[ME].mailMore = 3
total, holders = T.CountItem(2318)
GameTooltip:ClearLines()
T.AppendBreakdown(GameTooltip, total, holders)
all = table.concat(WoW.tooltipLines, "\n")
check("old mail is flagged", all:find("Mail data may be out of date", 1, true) ~= nil, all)
check("unread mail is flagged", all:find("Some mail not read yet", 1, true) ~= nil, all)

check("the status line says mail is included", plugin._wb.StatusText():find("mail", 1, true) ~= nil,
      plugin._wb.StatusText())

------------------------------------------------------------
-- Sync
------------------------------------------------------------

resetDB()
AltStableWarbandDB[ME] = {
    bags = { [2318] = 4 }, bank = {}, bagsStamp = 100, bankStamp = 90,
    mail = { [2318] = 7, [4306] = 1 }, mailStamp = 110, mailMore = 2,
    outbox = { { to = B, at = 120, items = { [2589] = 12 } }, { to = C, at = 115, items = { [765] = 3 } } },
    outboxStamp = 120, stamp = 120,
}
local blob = T.SerializePlayer(ME)
check("the blob carries the mail after the old fields",
      blob:find("|k=", 1, true) < blob:find("|mt=", 1, true), blob)
eq("the outbox encodes oldest first", T.EncodeOutbox(AltStableWarbandDB[ME].outbox),
   C .. "@115:765,3/" .. B .. "@120:2589,12")

-- An older client reads s=, kt=, b= and k= by their first match: v1.2.0's own patterns.
local rest = blob:match("^v1|(.+)$")
eq("an older reader still finds the stamp", tonumber(rest:match("s=(%d+)")), 120)
eq("  the bank stamp", tonumber(rest:match("kt=(%d+)")), 90)
eq("  the bags", rest:match("b=([^|]*)"), "2318,4")
eq("  and the bank", rest:match("k=([^|]*)"), "")

local held = AltStableWarbandDB[ME]
AltStableWarbandDB = {}
T.DeserializePlayer(ME, "v1|s=50|kt=0|b=2318,1|k=|mt=0|mm=0|m=|ot=0|o=")
eq("a mailbox never read records no mail", AltStableWarbandDB[ME] and AltStableWarbandDB[ME].mailStamp, nil)
eq("  nor an outbox never written", AltStableWarbandDB[ME] and AltStableWarbandDB[ME].outboxStamp, nil)
AltStableWarbandDB = {}
T.DeserializePlayer(ME, blob)
local got = AltStableWarbandDB[ME]
eq("a round trip keeps the mail", got and got.mail and got.mail[2318], 7)
eq("  its stamp", got and got.mailStamp, 110)
eq("  what was held back", got and got.mailMore, 2)
eq("  and the outbox", got and T.EncodeOutbox(got.outbox), T.EncodeOutbox(held.outbox))
eq("  with its stamp", got and got.outboxStamp, 120)

-- From an older client (or relayed through one): no mail fields.
local old = "v1|s=130|kt=90|b=2318,5|k="
T.DeserializePlayer(ME, old)
eq("a blob without mail takes the bags", got.bags[2318], 5)
eq("  and keeps the mail held", got.mail and got.mail[2318], 7)
eq("  and the outbox", #got.outbox, 2)

T.DeserializePlayer(ME, "v1|s=140|kt=90|b=2318,5|k=|mt=0|mm=0|m=|ot=0|o=")
eq("a never-read mailbox (mt=0) keeps the mail held", got.mail and got.mail[2318], 7)
eq("  and a never-written outbox (ot=0) the outbox", #got.outbox, 2)

T.DeserializePlayer(ME, "v1|s=150|kt=90|b=2318,5|k=|mt=100|mm=0|m=2318,1|ot=110|o=")
eq("an older mail read than the one held is refused", got.mail[2318], 7)
eq("  so is an older outbox", #got.outbox, 2)

T.DeserializePlayer(ME, "v1|s=160|kt=90|b=2318,5|k=|mt=160|mm=0|m=2318,9|ot=160|o=bad")
eq("a newer read replaces the mail", got.mail[2318], 9)
eq("  while a malformed outbox keeps the one held", #got.outbox, 2)

T.DeserializePlayer(ME, "v1|s=170|kt=90|b=2318,5|k=|mt=160|mm=0|m=2318,9|ot=170|o=")
eq("an emptied outbox empties it", got.outbox, nil)

------------------------------------------------------------
-- The setting
------------------------------------------------------------

resetDB()
eq("mail is on by default", T.MailOn(), true)
AltStableConfig.warbandMail = false
inbox = { { sender = "Auction House", items = { { 2318, 5 } } } }
openMailbox()
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
eq("off, the inbox is not read", mine().mail, nil)
draft = { { 2318, 1 } }
SendMail("Elegia Moon", "x", "")
WoW.fire("MAIL_SEND_SUCCESS")
eq("  sends are not recorded", mine().outbox, nil)
inbox = { { sender = "Elegia Moon", items = { { 2318, 5 } } } }
ReturnInboxItem(1)
eq("  nor returns", mine().outbox, nil)
AltStableWarbandDB[ME] = { bags = { [2318] = 1 }, mail = { [2318] = 7 }, mailStamp = WoW.now, stamp = WoW.now,
                           outbox = { { to = B, at = WoW.now, items = { [2318] = 2 } } }, outboxStamp = WoW.now }
eq("  held mail is not counted", (T.CountItem(2318)), 1)
eq("  nor shown in the grid", T.gather()[2318].total, 1)
check("  nor sent", not T.SerializePlayer(ME):find("|m=", 1, true), T.SerializePlayer(ME))
check("  and the status line leaves it out", not plugin._wb.StatusText():find("mail", 1, true),
      plugin._wb.StatusText())
eq("  but it is kept", AltStableWarbandDB[ME].mail[2318], 7)
AltStableConfig.warbandMail = true
eq("back on, it counts again", (T.CountItem(2318)), 1 + 7 + 2)

-- The Options checkbox (SheetUI's) saves the setting; checked by default.
AltStableConfig.warbandMail = nil

------------------------------------------------------------
-- A newer LibMailbox copy (another addon's) that failed half-way. Last: the
-- library stays not ready for the rest of the session.
------------------------------------------------------------

resetDB()
local src = assert(io.open(LibMailboxRoot() .. "/LibMailbox.lua", "rb"))
local text = src:read("*a")
src:close()
text = text:gsub('local MAJOR, MINOR = "LibMailbox%-1%.0", (%d+)', function(n)
    return 'local MAJOR, MINOR = "LibMailbox-1.0", ' .. (tonumber(n) + 1)
end):gsub("\nlib%.ready = MINOR", '\nerror("half-loaded")\nlib.ready = MINOR')
check("a newer LibMailbox copy fails half-way", not pcall(assert(loadstring(text, "=half"))))
check("  and isn't ready", not LM.Ready())
inbox = { { sender = "Elegia Moon", items = { { 2318, 5 } } } }
openMailbox()
WoW.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
eq("then the inbox is not read", mine().mail, nil)
ReturnInboxItem(1)
eq("  nor a return recorded", mine().outbox, nil)

WoW.finish("test_warband_mail", passed, failed)
