AltStable = AltStable or {}

-- Retail-API adapter; see Compat.lua.
local GetItemInfo = AltStable.API.GetItemInfo
AltStableDB = AltStableDB or {}

------------------------------------------------------------
-- DB cleanup — wipes all entries except the current character,
-- then rescans and requests fresh data from all peers.
-- This is the nuclear option for clearing corruption.
------------------------------------------------------------

local function CleanupDB()
    local guid = UnitGUID("player")

    -- Keep only the current character's entry
    local kept = 0
    for k in pairs(AltStableDB) do
        if k ~= guid then
            AltStableDB[k] = nil
        else
            kept = 1
        end
    end

    -- Rescan current character to make sure we have fresh data
    if AltStable.ScanCharacter then
        AltStable.ScanCharacter()
    end

    -- Plugins keep their own per-character stores keyed by the same guids, and
    -- their own stale-reject guards would refuse the re-pull below, so they get
    -- cleared with us.
    for _, plugin in ipairs(AltStable.plugins or {}) do
        if plugin.OnCleanup then pcall(plugin.OnCleanup, guid) end
    end

    -- We just wiped the DB, so forget every peer's delta watermark — the next
    -- request must pull a FULL database again, not just deltas.
    if AltStable.ResetPeerWatermarks then AltStable.ResetPeerWatermarks() end

    return kept
end

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local PREFIX = "ALTSTABLE"
local MSG_CHAR = "CHAR"
local MSG_REQUEST = "REQ"
local MSG_CHUNK = "CHUNK"
local MSG_DONE = "DONE"

-- Protocol version — bump this whenever the serialization format or
-- field set changes in a way that would corrupt an older client's DB.
-- Both sides must match to exchange data. Old clients see an unknown
-- command string and silently drop the packet.
--
-- v3 → v4: chunked transmission now embeds a sequence number and total
--          chunk count in each CHUNK message, so the receiver can
--          reassemble in order and detect dropped packets.
-- v4 → v5: chunk bodies are now base64-encoded.  This eliminates
--          deterministic byte-mangling we were seeing on the addon
--          channel (most likely whitespace-/control-char normalization
--          somewhere in the chat pipeline) — encoding to base64 means
--          the wire bytes are pure printable ASCII from the
--          [A-Za-z0-9+/=] alphabet, none of which any sane chat
--          pipeline rewrites.  Receiver decodes back to bytes before
--          checksum validation.
-- v5 → v6: each CHUNK/DONE carries a per-stream id (sid) so the receiver keeps
--          concurrent / retried streams from the same sender in separate
--          reassembly buffers instead of clobbering one shared buffer.
-- v6 → v7: the whole payload is now deflate-compressed (LibDeflate) and
--          WoW-addon-channel encoded, replacing the hand-rolled base64. Chunks
--          carry opaque encoded bytes (byte-split, not line-aligned). The
--          checksum is computed over the encoded stream. Huge size win on the
--          repetitive recipe payload.
local PROTOCOL_VERSION = "8"
local MSG_REQUEST_V = MSG_REQUEST .. PROTOCOL_VERSION   -- "REQ8"
local MSG_DONE_V    = MSG_DONE    .. PROTOCOL_VERSION   -- "DONE8"
-- The chunk format's own version, which moves independently of
-- PROTOCOL_VERSION: v7 and v8 both use CHUNK5, because the payload changed
-- while the framing did not.
local CHUNK_VERSION = "5"
local MSG_CHUNK_V   = MSG_CHUNK   .. CHUNK_VERSION     -- "CHUNK5"

-- Compression codec (loaded before Core.lua in the .toc).
local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)

-- WoW addon messages are capped at 255 bytes.
-- Wire packet format: "CHUNK5|<sid>|<seq>/<total>|<encoded-bytes>"
--   The body is opaque compressed+encoded bytes (no base64 expansion). The
--   header "CHUNK5|<sid>|<seq>/<total>|" is NOT fixed — sid grows with the
--   session's stream count and seq/total grow with the payload's chunk count,
--   so a naive 23-byte assumption underestimates it. Reserve a generous 35
--   bytes (covers e.g. "CHUNK5|99999999|99999/99999|" = 28) so header+body can
--   never exceed 255. That matters because ChatThrottleLib *errors* on an
--   oversize message (C_ChatInfo.SendAddonMessage returns a result code
--   instead), which would abort the whole send. 255 - 35 = 220.
local MAX_CHUNK = 220

-- Stream id, one per ChunkAndSendPayload call. Seeded from the clock, not 0,
-- so ids stay distinct across a /reload: a counter that restarted at 1 handed
-- a peer "stream 1" again within seconds (#58). Up to 8 digits; MAX_CHUNK's
-- header budget allows "CHUNK5|99999999|99999/99999|". Receivers parse any
-- %d+, so nothing on the wire changes.
local streamCounter = (time() % 1000000) * 100
-- When a DONE arrives but the buffer isn't complete, wait this long for
-- late/reordered chunks before declaring the stream incomplete. Prevents a
-- DONE that overtook an in-flight chunk from triggering a needless resync.
local CHUNK_DONE_GRACE      = 2     -- seconds

-- incomingBuffers[senderShort] = {
--   chunks = { [seq] = chunkBody, ... },   -- sparse; receiver fills as packets arrive
--   total  = N,                            -- total chunks announced (latest seen)
-- }
-- A sequenced reassembly buffer.  Replaces the previous single-string
-- buffer because chunks can arrive out of order on the addon channel
-- and silent reordering was producing checksum mismatches.
local incomingBuffers = {}
-- Streams refused at their first packet, by buffer key (#61): the rest of the
-- stream stays refused even if consent arrives half way - an Allow clicked
-- while a push is still arriving must not start a buffer from its middle.
local refusedStreams = {}

-- Which protocol a command string belongs to, and whether we can speak it.
--
-- The version rides in the command's numeric suffix (REQ8, DONE8, CHUNK5), and
-- an unversioned command is v1 - the first release. Parsing it beats listing
-- every old string: the lists stopped at REQ6 and DONE6, so a v7 peer's DONE
-- matched nothing and was dropped in SILENCE. Its chunks had already been
-- buffered (CHUNK5 is shared by v7 and v8), so the user saw a stalled sync or
-- nothing at all, never "outdated addon version" - and v8 would have needed the
-- same fix again when v9 ships.
--
-- Returns the version, or nil when the command is not one of ours.
local function CommandVersion(cmd, base)
    if type(cmd) ~= "string" then return nil end
    local suffix = cmd:match("^" .. base .. "(%d*)$")
    if not suffix then return nil end
    return tonumber(suffix) or 1
end

-- Set of senders we've already nagged about being on an outdated
-- protocol version, to avoid spamming the chat frame on every chunk.
local outdatedSenders = {}

-- Per-sender count of how many times we've auto-requested a resync
-- after detecting missing chunks.  Capped at 2 to prevent loops if
-- a peer is fundamentally broken.  Reset to nil after a successful
-- DONE.
local autoRetryCounts = {}

-- Per-peer time of the last sync request we sent.  Used to throttle
-- duplicate requests — if /alts is run again before the first sync
-- completes, or two events fire close together (PLAYER_LOGIN +
-- CHAT_MSG_SYSTEM peer-online), we don't want to spam REQ messages.
-- Keyed by peer name (no realm suffix).
local lastRequestedAt = {}
local REQUEST_THROTTLE = 300  -- 5 minutes between automatic re-requests

-- Sync-scope epoch. Watermarks belong to the REQUESTER: a peer asks us for
-- changes since its own watermark for us. So when a setting widens WHICH
-- characters we send (sendAllAccounts, accountNumber), the newly eligible ones
-- - stamped long before that watermark - would be filtered out of every delta
-- the peer asks for. The fix has to be here, on the reply side: the first reply
-- to each peer after a scope change ignores its watermark and sends everything.
-- (Resetting our OWN watermarks, the first attempt, fixed nothing for anyone and
-- forced a pointless full pull from every peer.)
--
-- Persisted, not session state: a scope change made while a peer is offline,
-- followed by a quit before that peer asks, must still be honoured next
-- session - otherwise the newly eligible characters stay filtered indefinitely.
-- So the generation and each peer's "answered in full at generation N" live in
-- AltStableConfig. (Which persisted nothing through 1.60.1.69977 (#23) - but the
-- logic is correct, and becomes durable the moment SavedVariables load.)
--
-- Limit, stated rather than solved: a peer is marked served when its full reply
-- is scheduled. If that stream is then lost, its next request gets a delta again;
-- `/alts sync <name>` always sends in full and recovers it.
local function ScopeGeneration()
    AltStableConfig = AltStableConfig or {}
    return tonumber(AltStableConfig.syncScopeGeneration) or 0
end
function AltStable.OnSyncScopeChanged()
    AltStable.SetConfigValue("syncScopeGeneration", ScopeGeneration() + 1)
end

-- Answer a request. Everything that MUTATES on behalf of a peer lives here
-- rather than in the handler, because the handler now has paths that do not
-- serve: marking a peer "answered in full at generation N" for a request we
-- then refused would consume the scope change and silently drop the newly
-- eligible characters from every later delta.
local ServeSyncRequest       -- forward: defined once SendFullDatabase exists
local RememberPendingRequest

-- Stale-buffer cleanup.  If a sender's stream gets cut off mid-flight
-- (DC, /reload on their end, sender ran out of credits to keep sending,
-- etc.) we'd otherwise hold onto a partial buffer forever.  Every 60s
-- we sweep buffers whose lastTouched is older than 120s and drop them.
-- The threshold is generous because the rate-limited sender now paces
-- at ~1 chunk/sec, so a 100-character DB takes ~2 minutes legitimately.
C_Timer.NewTicker(60, function()
    local now = time()
    for key, buf in pairs(incomingBuffers) do
        if buf.lastTouched and (now - buf.lastTouched) > 120 then
            incomingBuffers[key] = nil
        end
    end
    for key, at in pairs(refusedStreams) do
        if (now - at) > 120 then refusedStreams[key] = nil end
    end
end)

------------------------------------------------------------
-- Checksum — simple additive hash over payload bytes.
-- Returns a hex string. Computed over the full reassembled
-- buffer so the receiver can detect corruption or truncation.
------------------------------------------------------------

local function ComputeChecksum(str)
    local h = 0
    for i = 1, #str do
        h = (h * 31 + string.byte(str, i)) % 0xFFFFFFFF
    end
    return string.format("%08X", h)
end

------------------------------------------------------------
-- Chat output  (declared before ValidateIncoming, which calls it)
------------------------------------------------------------

-- Exposed as AltStable.Print below: the UI and the plugins need the same
-- prefix, and a guarded "if AltStable.Print then" that is never true prints
-- nothing while looking like it works.
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r " .. msg)
end
AltStable.Print = Print

------------------------------------------------------------
-- Character totals: what the sheet's footer shows (#123)
------------------------------------------------------------
-- One piece of arithmetic behind both the footer and the public GetTotals()
-- (PublicAPI.lua), so a bar showing "total gold" and the sheet cannot disagree.
-- It lives HERE, internal, rather than in PublicAPI: the footer must not depend
-- on a function other addons can see and overwrite, nor on a later file loading.
--
-- Which characters count is the GRID's rule - any record with a name - with
-- hidden ones left out and counted separately. A forgotten character normally
-- has no record at all; one that has a record again (the player logged into it
-- after forgetting it, and the scan rewrote it) is listed by the grid, so it is
-- counted here too, or the footer and the rows above it would disagree.
--
-- Low-level bank alts count: they hold gold, and the total is expected to match
-- other addons (ElvUI, etc.) that count them. A character whose money is
-- UNREADABLE (a secret value, see Compat.lua) is counted as unknown, not as 0:
-- counting it as zero would present the sum as the whole account's gold while
-- silently leaving one character out.
function AltStable.CharacterTotals()
    local Plain = AltStable.API.PlainNumber
    local t = { money = 0, unknown = 0, characters = 0, hidden = 0, levels = 0 }
    for _, char in pairs(type(AltStableDB) == "table" and AltStableDB or {}) do
        if type(char) == "table" and char.name then
            if AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(char.guid) then
                t.hidden = t.hidden + 1
            else
                t.characters = t.characters + 1
                t.levels = t.levels + (Plain(char.level) or 0)
                local m = Plain(char.money)
                if m == nil then t.unknown = t.unknown + 1 else t.money = t.money + m end
            end
        end
    end
    return t
end

------------------------------------------------------------
-- The account number
--
-- ONE place that coerces, validates, stores and reports. The Options box and
-- /alts account both go through it: two implementations of one setting drift,
-- and only one of them ever has a test.
--
-- Validated as a positive whole number because the value is compared as a
-- STRING on the wire (SerializeFullDB filters on tostring(charAcct) ~=
-- tostring(myAccount)), so "2.5", "0x10" and "-3" are all storable and none of
-- them mean anything to a peer.
------------------------------------------------------------

-- Re-tag the characters THIS client scanned. char.account is written at scan
-- time, so a change that did not do this would leave every alt on the old value
-- until it was next played: filtered out of account-scoped syncs, while the
-- setting claims to have changed. Peers' records are never touched - they carry
-- their owner's account, not ours.
local function RetagScannedHere(value)
    if type(AltStableDB) ~= "table" then return 0 end
    local n = 0
    for _, c in pairs(AltStableDB) do
        if type(c) == "table" and c.scannedHere
            and tostring(c.account or "") ~= tostring(value) then
            c.account = value
            n = n + 1
        end
    end
    return n
end

-- nil when unset, so callers do not have to know whether "unset" is nil or "".
function AltStable.GetAccountNumber()
    local v = AltStableConfig and AltStableConfig.accountNumber
    if v == nil or v == "" then return nil end
    return v
end

-- Returns ok, message. `text` may be a number, a numeric string, or the word
-- "clear" - clearing is EXPLICIT, never a side effect of an empty box.
function AltStable.SetAccountNumber(text)
    AltStableConfig = AltStableConfig or {}
    local before = AltStable.GetAccountNumber()

    if type(text) == "string" and text:lower():match("^%s*clear%s*$") then
        if before == nil then return false, "No account number was set." end
        AltStable.SetConfigValue("accountNumber", "")
        -- Untag our own records too. Setting a number re-tags them, so clearing
        -- without doing the same leaves this client presenting MIXED
        -- identities: the alts scanned earlier still claim the old account and
        -- are still sent to peers under it, while the next one scanned carries
        -- no account at all - all while the setting reports itself as cleared.
        local cleared = RetagScannedHere("")
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        if AltStable.RefreshAccountBox then AltStable.RefreshAccountBox() end
        local msg = "Account number cleared."
        if cleared > 0 then
            msg = msg .. " (" .. cleared .. " character(s) on this client untagged.)"
        end
        return true, msg
    end

    -- Validated by SHAPE, not by value: tonumber("0x10") is 16, a perfectly
    -- good positive whole number that nobody typed. Digits only.
    local digits = tostring(text or ""):match("^%s*(%d+)%s*$")
    local num = digits and tonumber(digits)
    if not num or num < 1 then
        return false, "Account number must be a whole number, 1 or more. "
            .. "Usage: |cffffff00/alts account 1|r (or |cffffff00clear|r)."
    end

    if before ~= nil and tostring(before) == tostring(num) then
        return false, "Account number is already " .. num .. "."
    end

    AltStable.SetConfigValue("accountNumber", num)

    local retagged = RetagScannedHere(num)
    if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    -- The Options box only reads the stored value when the panel is SHOWN, so a
    -- change made from chat while it is already open leaves a stale number in
    -- it - which blurring the box would then commit straight back over this.
    if AltStable.RefreshAccountBox then AltStable.RefreshAccountBox() end

    local msg = "Account number set to " .. num .. ". It will be included on next scan/sync."
    if retagged > 0 then
        msg = msg .. " (" .. retagged .. " character(s) on this client re-tagged.)"
    end
    return true, msg
end

------------------------------------------------------------
-- Validation — reject incoming records whose immutable
-- fields (class, name) have changed for an existing GUID.
-- Returns true if the record is safe to accept.
------------------------------------------------------------

-- The part of a name no client version disagrees about.
local function FirstName(n)
    return (type(n) == "string" and n:match("^(%S+)")) or n
end
-- Keep our surname when the incoming name is BARE - a peer still reading only
-- UnitName's first return sends "Kaleid" for a character we hold as "Kaleid
-- Sumner". That is the half their client dropped, not a change they made.
--
-- Deliberately not "keep the longer one": a genuine rename to a shorter
-- surname ("Kaleid Sumner" -> "Kaleid Fox") would then be reverted forever,
-- and we would re-broadcast the stale name. Only the exactly-bare case is
-- treated as a client artefact; every other difference is the peer's to tell
-- us about.
local function KeepFullerName(existing, priorName)
    if not priorName or not existing.name then return end
    local first = FirstName(existing.name)
    if FirstName(priorName) ~= first then return end
    if existing.name ~= first then return end      -- incoming carries a surname: theirs wins
    if priorName == first then return end          -- we had no surname either
    existing.name = priorName
end

local function ValidateIncoming(c, sender)
    if not c or not c.guid then return false end

    local existing = AltStableDB[c.guid]
    if not existing then return true end  -- new character, nothing to conflict

    -- Class should never change for a given GUID
    if existing.class and c.class and existing.class ~= c.class then
        Print("|cffff0000Rejected|r data for " .. (c.name or c.guid) ..
              " from " .. (sender or "unknown") ..
              ": class changed (" .. tostring(existing.class) ..
              " -> " .. tostring(c.class) .. ").")
        return false
    end

    -- The FIRST name should never change for a given GUID. Not the whole
    -- string: 1.60.1.70009 moved the surname into UnitName's second return, so
    -- a client reading only the first sends "Kaleid" for the character this
    -- one has on disk as "Kaleid Sumner" - and rejecting that means a
    -- character stops updating until every client has the same addon build.
    -- A genuine mismatch (Kaleid -> Zoruka) still fails.
    if existing.name and c.name and FirstName(existing.name) ~= FirstName(c.name) then
        Print("|cffff0000Rejected|r data for GUID " .. c.guid ..
              " from " .. (sender or "unknown") ..
              ": name changed (" .. tostring(existing.name) ..
              " -> " .. tostring(c.name) .. ").")
        return false
    end

    return true
end

-- Our own character name, used to suppress our own broadcast echoes. May be
-- nil this early (file load runs before PLAYER_LOGIN); refreshed in the login
-- handler below so self-suppression is reliable for the session.
-- The full name, surname included: the sender on an addon message carries it,
-- so a half name here stops us recognising our own packets (see below).
local PLAYER_NAME = AltStable.API.PlayerFullName()

------------------------------------------------------------
-- Sync routing — whisper-only to whitelisted characters
-- A peer's name without its realm suffix. Keyed on throughout - watermarks,
-- authorization, buffers - so it sits above all of them rather than beside
-- whichever one happened to need it first.
local function PeerShort(name)
    return (name and name:match("^([^%-]+)")) or name
end

------------------------------------------------------------
-- Sync authorization (#61)
--
-- The request handler used to answer ANY player who sent a REQ. The prefix is
-- public - the addon ships on CurseForge - so it took no discovery: whisper
-- "REQ8|0" and receive every character record we hold. Names, realms, guilds,
-- levels, item levels, gold, mail, lockouts, reputations.
--
-- The whitelist is not a defence and never was. It gates GetSyncTargets, which
-- is whom WE choose to whisper first, and nothing on the request path.
--
-- Nor is the account filter: `accountOnly` only bites when accountNumber is
-- set, and it defaults to "". Until someone runs /alts account <n>, a default
-- install answers a stranger with everything it holds, including characters
-- synced in from the other account. A scope limit, never an authorization.
--
-- So: three answers per peer, following Altoholic's model.
--
--   auto   serve them, no questions
--   never  ignore them
--   ask    the default for someone we have never heard of - tell the player
--          who is asking and serve nobody until they say so
--
-- "ask" is what keeps the ONE-SIDED setup working. Today A whitelists B, A
-- asks, and B answers without ever having heard of A; requiring B to whitelist
-- A first would mean nothing syncs until both sides are configured, which is
-- the friction #58 exists to remove. Asking once preserves the flow and closes
-- the hole.
------------------------------------------------------------

local AUTH_AUTO, AUTH_ASK, AUTH_NEVER = "auto", "ask", "never"
AltStable.AUTH_AUTO, AltStable.AUTH_ASK, AltStable.AUTH_NEVER = AUTH_AUTO, AUTH_ASK, AUTH_NEVER

-- What we will do for this peer, without doing it.
--
-- An explicit answer always wins, including over the whitelist: saying "never"
-- to someone you also whitelisted has to mean never.
--
-- Otherwise our own whitelist counts as consent. Those are the peers the player
-- named as their own, and prompting for characters you configured yourself
-- would be a prompt with one sensible answer. It also means an existing install
-- sees no new prompts for the peers it already syncs with.
-- One key for a peer: the character NAME, case-folded, with any realm suffix
-- dropped.
--
-- Case: WoW whisper targets are case-insensitive, and the rest of the addon
-- (IsWhitelisted, RemoveFromWhitelist, IsPeerOnline) compares with :lower().
-- A gate that did not once stored `/alts deny karuzo` under a key the handler
-- never read: it printed "refusing" and went on serving them.
--
-- Realm: on Forever the realms are four rulesets (PvP, PvE, RP, Hardcore) over
-- one region, and character names - guild names too - are unique across the
-- whole region. A realm suffix says where a character is, never who; "Bob" and
-- "Bob-OtherRealm" cannot be two people. An earlier version kept the realm as
-- part of the identity, which made one person several keys, and folding "our"
-- realm back in made the account-wide AltStableConfig depend on which realm
-- was being played (review of #136). The raw sender is still what we whisper.
local function AuthKey(peer)
    if type(peer) ~= "string" then return nil end
    local name = peer:match("^%s*([^%-]*)")
    name = name and name:match("^(.-)%s*$"):lower()
    if not name or name == "" then return nil end
    return name
end

------------------------------------------------------------
-- Your own other accounts, through Battle.net (#58, #198)
------------------------------------------------------------
-- Whispers stop at the ruleset and the faction (measured, 70124). Battle.net
-- game data between the owner's OWN accounts crosses both (measured: PvP2<->PvE,
-- Horde<->Alliance, both directions). So the owner's other accounts are found
-- through Battle.net and synced over it, with no whitelist and nothing typed.
--
-- LibAccountSync-1.0 does the finding and the proving (docs/SYNC-DISCOVERY.md
-- has the measurements it rests on); "Own accounts through LibAccountSync"
-- below is what AltStable does with it. The legacy channel that did this here
-- (HI8 hellos, CHUNK5/DONE8 over BNSendGameData) is gone (#206).
--
-- Session state only: nothing here is written to SavedVariables.

local function BNetEnabled()
    AltStableConfig = AltStableConfig or {}
    if AltStableConfig.bnetSync == false then return false end
    if not (C_BattleNet and C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetAccountInfoByGUID) then
        return false
    end
    if BNFeaturesEnabledAndConnected and not BNFeaturesEnabledAndConnected() then return false end
    return true
end

-- The same accounts through LibAccountSync-1.0 (#198); the rest is in "Own
-- accounts through LibAccountSync" below. One local table: this file's main
-- chunk is close to Lua 5.1's 200-local limit.
--   inst       the library instance, or nil (no library, or a broken one)
--   peers      AuthKey -> { name, guid, realm, faction }: an AltStable message
--              came from them over the library this session - the only thing
--              that says they run it (the library also lists accounts that run
--              only GlassChat, say)
--   seen       AuthKey -> true: known as our own account this session, even
--              after the library stopped listing them
--   announced  AuthKey -> true: "found your other account" said once
local LibSync = { peers = {}, seen = {}, announced = {} }

-- A peer heard over the library, while the library still lists that GUID
-- under that name. Stale either way (the account logged off, another
-- character): forgotten, and never trusted as ours again on the old word.
function LibSync.Peer(name)
    local key = AuthKey(name)
    local p = key and LibSync.peers[key]
    if not p or not LibSync.inst or not BNetEnabled() then return nil end
    local ok, listed = pcall(LibSync.inst.Peers)
    if ok and type(listed) == "table" then
        for _, q in ipairs(listed) do
            if q.guid == p.guid and AuthKey(q.name) == key then return p end
        end
    end
    LibSync.peers[key] = nil
    return nil
end

-- Ours: an AltStable message the library proved came from our own account.
local function OwnBNetPeer(name)
    if not BNetEnabled() then return nil end
    return LibSync.Peer(name)
end

local function SyncAuthFor(peer)
    AltStableConfig = AltStableConfig or {}
    local key = AuthKey(peer)
    if not key then return AUTH_NEVER end

    local stored = (AltStableConfig.syncAuth or {})[key]
    if stored == AUTH_AUTO or stored == AUTH_NEVER then return stored end

    for _, name in ipairs(AltStableConfig.whitelist or {}) do
        if AuthKey(name) == key then return AUTH_AUTO end
    end
    -- Your own other account, proven by the library this session: trusted like
    -- a whitelist entry. A stored answer - never in particular - came first.
    if OwnBNetPeer(peer) then return AUTH_AUTO end
    return AUTH_ASK
end

-- Told whenever an answer or a pending request changes: the Options list and
-- the prompt queue live in SheetUI and redraw from it. A no-op until then.
local function SyncAuthChanged()
    if AltStable.OnSyncAuthChanged then AltStable.OnSyncAuthChanged() end
end

local function SetSyncAuth(peer, mode)
    local key = AuthKey(peer)
    if not key then return false end
    if mode ~= AUTH_AUTO and mode ~= AUTH_NEVER and mode ~= nil then return false end

    AltStableConfig = AltStableConfig or {}
    local current = AltStableConfig.syncAuth or {}
    local copy = {}
    for k, v in pairs(current) do copy[k] = v end
    copy[key] = mode          -- nil clears it, back to whitelist-or-ask
    AltStable.SetConfigValue("syncAuth", copy)
    -- Not announced here: the callers (allow, deny, forget) announce once,
    -- when everything that goes with the answer is done.
    return true
end

-- Answers stored under a realm-qualified key ("name-realm") are folded into the
-- name. Where two forms land on one key and disagree, NEVER wins: a refusal
-- must not be undone by a tidy-up.
local function MigrateSyncAuthKeys()
    AltStableConfig = AltStableConfig or {}
    local current = AltStableConfig.syncAuth
    if type(current) ~= "table" then return false end
    local merged, changed = {}, false
    for k, v in pairs(current) do
        local nk = AuthKey(k) or k
        if nk ~= k then changed = true end
        if merged[nk] == nil or v == AUTH_NEVER then merged[nk] = v end
    end
    if changed then AltStable.SetConfigValue("syncAuth", merged) end
    return changed
end
AltStable.MigrateSyncAuthKeys = MigrateSyncAuthKeys
AltStable.PeerKey = AuthKey

-- Requests we have not answered yet, keyed by peer: what they asked for, and
-- when. Session state on purpose - an approval given tomorrow should serve
-- tomorrow's request, not replay one from before a relaunch.
local pendingAuth = {}
local PENDING_TTL = 300     -- after this, approving just waits for their next REQ
local NOTICE_EVERY = 60     -- do not narrate every retry of the same request

AltStable.SyncAuthFor = SyncAuthFor

-- Temporary consent (#61): an exchange WE started, with someone we have not
-- answered for good. Session state, keyed by AuthKey.
--
--   receiveUntil  take a stream from them if it STARTS before this - set when we
--                 send them a request (RequestCharacters) or name them in
--                 /alts sync. A stream admitted in time finishes however long
--                 it takes; this bounds the start, not the length.
--   sendUntil     answer their request before this - set ONLY by /alts sync
--                 <name>: typing the name is the consent. A request we merely
--                 sent does not make us serve them.
--
-- NEVER beats all of it (MayServe / MayAdmit check it first).
local consent = {}
local CONSENT_TTL = 600
-- Defined further down (with the streams, and the request sender), used by
-- allow/deny above them.
local DropPeerStreams, NoteRefusedStream, RequestCharacters
local refusedNotified = {}

local function GrantConsent(peer, send, receive)
    local key = AuthKey(peer)
    if not key then return end
    local c = consent[key] or {}
    local untilTime = time() + CONSENT_TTL
    if send then c.sendUntil = math.max(c.sendUntil or 0, untilTime) end
    if receive then c.receiveUntil = math.max(c.receiveUntil or 0, untilTime) end
    consent[key] = c
end

local function ClearConsent(peer)
    local key = AuthKey(peer)
    if key then consent[key] = nil end
end

-- May we answer this peer's request right now?
local function MayServe(peer)
    local mode = SyncAuthFor(peer)
    if mode == AUTH_NEVER then return false end
    if mode == AUTH_AUTO then return true end
    local c = consent[AuthKey(peer) or ""]
    return c ~= nil and (c.sendUntil or 0) >= time()
end

-- May a NEW stream from this peer start now? (A stream already admitted is
-- only ended by NEVER.)
local function MayAdmit(peer)
    local mode = SyncAuthFor(peer)
    if mode == AUTH_NEVER then return false end
    if mode == AUTH_AUTO then return true end
    local c = consent[AuthKey(peer) or ""]
    return c ~= nil and (c.receiveUntil or 0) >= time()
end

AltStable.MayServeSyncPeer = MayServe
AltStable.MayAdmitSyncPeer = MayAdmit
AltStable.GrantSyncConsent = GrantConsent

-- Every peer we hold an explicit answer for, sorted, for Options and /alts auth.
function AltStable.SyncAuthList()
    AltStableConfig = AltStableConfig or {}
    local out = {}
    for key, mode in pairs(AltStableConfig.syncAuth or {}) do
        out[#out + 1] = { name = key, key = key, mode = mode }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Peers who have asked and are still waiting on an answer.
--
-- Expired entries are DROPPED here rather than merely skipped: nothing else
-- removes one that is never allowed or denied, so every stranger who ever asks
-- would otherwise leave a permanent entry behind for the session. Same reason
-- the stale-buffer sweeper exists.
function AltStable.PendingSyncRequests()
    local out = {}
    local now = time()
    local dropped = false
    for key, req in pairs(pendingAuth) do
        if now - (req.at or 0) > PENDING_TTL then
            pendingAuth[key] = nil
            dropped = true
        else
            out[#out + 1] = { name = req.name or key, key = key, at = req.at }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    if dropped then SyncAuthChanged() end
    return out
end

------------------------------------------------------------

-- Returns a list of {channel, target} pairs to send to.
-- Only contacts whitelisted characters via whisper.
-- Guild broadcast is disabled for now (alt tracker, not guild tracker).
local function GetSyncTargets()
    AltStableConfig = AltStableConfig or {}

    local whitelist = AltStableConfig.whitelist or {}
    local targets, seen = {}, {}
    -- Your own other accounts on the library (#58, #198) count too, so the
    -- login sync, a bare /alts sync and /alts cleanup reach them with no
    -- whitelist: "BNET", the library route to them. One entry per peer:
    -- whitelisted AND found is one target.
    if BNetEnabled() then
        for key, p in pairs(LibSync.peers) do
            if not seen[key] and LibSync.Peer(p.name) and SyncAuthFor(p.name) ~= AUTH_NEVER then
                seen[key] = true
                table.insert(targets, { channel = "BNET", target = p.name })
            end
        end
    end
    -- "Refuse them for good" has to mean both directions. Gating only the
    -- inbound request left a denied peer on the whitelist, so every login
    -- still whispered them a REQ and /alts cleanup still pushed them the
    -- whole database - which is the thing the player just refused.
    for _, name in ipairs(whitelist) do
        if not seen[AuthKey(name) or ""] and SyncAuthFor(name) ~= AUTH_NEVER then
            table.insert(targets, { channel = "WHISPER", target = name })
        end
    end

    return targets
end

------------------------------------------------------------
-- Retired fields
--
-- Character fields a previous build wrote that nothing reads any more. Removing
-- the producer is not enough: stored records keep them, and sync would carry
-- them between accounts indefinitely. So they are purged from the database at
-- login, never sent, and dropped on receipt from a peer that still has them.
------------------------------------------------------------

local RETIRED_FIELDS = {
    prof_Jewelcrafting = true, profmax_Jewelcrafting = true,   -- not a Vanilla profession
    stat_haste = true, stat_resilience = true,                 -- no Vanilla equivalent
    -- stat_crit is OFF this list now, which is what the note here asked for:
    -- "when the Roster port adds a build-verified producer, take these two off
    -- the list". GetCritChance has a verified producer - observed live on
    -- 1.60.1.70009 reporting 1.66% for a level 18 gnome warlock, which is a
    -- real value and not a rating-derived zero.
    --
    -- stat_hitpct is OFF this list too, now, and the measurement is what did it.
    --
    --     /run print(GetHitModifier and GetHitModifier() or "ABSENT")
    --     0
    --
    -- MEASURED on 1.60.1.70009. Not "ABSENT" and not nil: the function exists,
    -- is callable, and returns a number. That resolves the ambiguity this note
    -- used to hedge on - "the row did not render" was equally consistent with a
    -- missing function and a genuine zero, and it was the zero.
    --
    -- So there is a build-verified producer, which is exactly the condition this
    -- note set. What is STILL unobserved is a NONZERO reading: it reports the
    -- bonus hit from gear, and the character measured had none. That is handled
    -- in the display rather than here - the Roster row has no allowZero, so it
    -- appears only for a character that actually has some - and it is not a
    -- reason to keep purging a field the client will answer for.
    spec = true, specIcon = true,   -- the talent-tab API is gone on Forever; always ""
    -- The reference-screenshot marker. It told the retired armory pipeline which
    -- screenshot was fresh; the two-shot capture (#89) records to its own
    -- store, so nothing has read this since, and it only rode the wire.
    refshot_ts = true,
}
-- The TBC reputation slugs. Standings are rep_<factionID> now (Reputations.lua).
for _, slug in ipairs({ "aldor", "scryer", "shatar", "lowercity", "cenarion", "consortium",
                        "keepers", "sporeggar", "honorhold", "thrallmar", "kurenai", "maghar",
                        "ogrila", "skyguard", "netherwing", "ashtongue", "scaleofsands",
                        "shatteredsun", "violeteye" }) do
    RETIRED_FIELDS[slug] = true
end

local function PurgeRetiredFields()
    for _, c in pairs(AltStableDB or {}) do
        if type(c) == "table" then
            for k in pairs(RETIRED_FIELDS) do c[k] = nil end
        end
    end
end

-- Hand each plugin its own blob for an ACCEPTED character, then drop the
-- carrier field so it never reaches the database or the wire.
-- independentOnly: the record itself lost the merge (ShouldMerge), so only a
-- plugin that versions its own data (plugin.independentStamp) gets its blob -
-- its own stamp decides, and the core record is still not touched. That is how
-- a store switched on after the fact, on a PC whose own alts' core records are
-- already current, can still receive their plugin data (Codex review of #132).
-- Validation and the forgotten check have run before either call.
local function DispatchPluginPayloads(c, independentOnly)
    local payloads = c and c._pluginPayloads
    c._pluginPayloads = nil
    if not payloads or not AltStable.plugins then return end
    for _, plugin in ipairs(AltStable.plugins) do
        local blob = payloads[plugin.id]
        if blob and plugin.OnDeserialize and (not independentOnly or plugin.independentStamp) then
            pcall(plugin.OnDeserialize, c.guid, blob)
        end
    end
end

------------------------------------------------------------
-- Serialize character
------------------------------------------------------------

local function SerializeChar(c, sinceTS)

    local parts = {}

    for k,v in pairs(c) do
        -- A secret value (see Compat.lua) would throw on the tostring below and
        -- take the whole sync with it. The scanner already keeps them out of the
        -- database; this is the wire boundary refusing to carry one that got in
        -- some other way - a record from an older build, or a plugin's field.
        if type(v) ~= "table"
        and not AltStable.API.IsSecretValue(v)
        and not RETIRED_FIELDS[k]
        and not k:find("^gearlink_")   -- item links are local-only (too large for sync)
                                      -- gearid_* stays included (compact + sync-safe)
        and not k:find("^gearsubtype_") -- local-only: only used by the local render pipeline;
                                      -- synced alts fall back to keyword inference on gearname_
        and k ~= "scannedHere"         -- local-only: "this client scans it". On the wire it
                                      -- would tell every peer the character was ITS own
        -- NOTE: hidehelm / hidecloak ride sync on purpose — a portrait pipeline has to know
        -- the player hid a slot, since the equipped item list alone can't tell it. They are
        -- plain 1/0 numbers, so the tonumber() coercion below round-trips them unchanged.
        -- They must NOT become booleans: tostring(false) sends "false", which tonumber() leaves
        -- as the STRING "false" — and a non-empty string is truthy in Lua, so a hidden-cloak
        -- flag would read as shown and vice versa.
        then
            parts[#parts+1] = k .. ":" .. tostring(v)
        end
    end

    -- Plugin extensions: each registered plugin may contribute one line of
    -- opaque per-character data that will round-trip through sync.  The
    -- plugin is responsible for encoding its own data into a string with
    -- no newline characters.  Lines are stored as "plugin_<id>:<blob>".
    -- sinceTS (the requester's delta watermark) is passed through so a plugin
    -- can skip re-sending data the peer already has (returning "").
    if AltStable.plugins then
        for _, plugin in ipairs(AltStable.plugins) do
            if plugin.OnSerialize and c.guid then
                local ok, blob = pcall(plugin.OnSerialize, c.guid, sinceTS)
                if ok and type(blob) == "string" and blob ~= "" and not blob:find("\n") then
                    parts[#parts+1] = "plugin_" .. plugin.id .. ":" .. blob
                end
            end
        end
    end

    return table.concat(parts, "\n")

end

------------------------------------------------------------
-- Deserialize character
------------------------------------------------------------

local function DeserializeChar(msg)

    local c = {}
    local pluginPayloads = nil  -- lazy-init

    for line in string.gmatch(msg, "([^\n]+)") do

        local k, v = line:match("^([^:]+):(.*)$")  -- (.*) so empty values round-trip

        if k then
            local pid = k:match("^plugin_(.+)$")
            if pid then
                pluginPayloads = pluginPayloads or {}
                pluginPayloads[pid] = v
            else
                -- Coerce numeric-looking values back to numbers so the UI can
                -- sort/compare them (level, ilvl, money, skills, timestamps).
                -- Intentional and safe for this schema: identity/string fields
                -- (guid, name, realm, class, guild) are never bare numbers, so
                -- none of them get mis-coerced. Don't "fix" this without a
                -- per-field type marker — a blanket string keep would break
                -- numeric sorting.
                if not RETIRED_FIELDS[k] then
                    local num = tonumber(v)
                    c[k] = num or v
                end
            end
        end

    end

    if not c.guid then
        return
    end

    -- Plugin payloads ride along on the record and are dispatched by the
    -- caller, once the record has passed ValidateIncoming and ShouldMerge.
    -- Dispatching here applied a peer's inventory for a character whose own
    -- record was then REJECTED - a conflicting name, or an older record losing
    -- to ours - so the sheet showed one character and the plugin another's
    -- items. The field is local-only; DispatchPluginPayloads strips it.
    c._pluginPayloads = pluginPayloads

    return c

end

------------------------------------------------------------
-- Serialize full DB
------------------------------------------------------------

-- "==END==" on its own line is the character record separator.
-- It cannot appear in any field value, and because we chunk at
-- line boundaries (not arbitrary byte offsets) it always arrives
-- intact — never split across two packets.
local CHAR_SEP = "==END=="

-- The replier's time(), as the payload's last line. It sits AFTER the final
-- CHAR_SEP, and every parser - including every older version's - only acts on
-- a line when it hits CHAR_SEP, so an older client accumulates it and discards
-- it with no effect. Additive, which is why there is no PROTOCOL_VERSION bump.
local SEND_TIME = "==NOW=="

-- Per-peer delta-sync watermark: the lastUpdate value we ask a peer to send
-- changes since. Persisted in AltStableConfig.peerWatermarks, keyed by the
-- realm-less short name so a REQ target and its reply sender map to one entry.
--
-- This comment used to claim the watermark is the peer's OWN timestamp, so no
-- two machine clocks are ever compared. It never was: a peer relays every
-- record it holds, including characters it received from third parties, whose
-- lastUpdate came from THEIR clocks. One relayed record from a machine running
-- an hour fast pushed the watermark an hour past the peer's own clock, and every
-- change the peer then made to its own characters fell below the delta filter
-- until real time caught up - silent, and self-healing, so it looked like flaky
-- sync. See ClampWatermark.
-- The delta filter runs on the PEER, comparing stamps against the peer's own
-- clock - so the ceiling has to be the peer's clock, not ours. A reply now ends
-- with the replier's time() (see SEND_TIME), and the watermark is capped a few
-- minutes below it. Clamping against OUR clock, the first attempt, just swapped
-- the roles: with our clock ahead of the peer's, our own characters relayed back
-- still pushed the watermark past the peer's clock.
--
-- The slack is re-sent overlap - a few minutes of records on each delta, which
-- the last-write-wins merge absorbs.
--
-- A peer that sends no clock gets NO delta at all: its watermark is reset to 0,
-- so we ask it for everything. That is the only safe reading, because the
-- protocol version did not change for this - an older v8 peer is accepted, it
-- just predates the trailer - and guessing its clock from ours is exactly bug 1
-- again: with ours an hour ahead, one of our own characters relayed back pushed
-- the watermark 55 minutes past the peer's. Full replies are how sync worked
-- before deltas existed; slower, never wrong.
local WATERMARK_SLACK = 300
local function WatermarkCeiling(peerNow)
    return (tonumber(peerNow) or time()) - WATERMARK_SLACK
end

local function GetPeerWatermark(name)
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.peerWatermarks = AltStableConfig.peerWatermarks or {}
    local wm = AltStableConfig.peerWatermarks[PeerShort(name)] or 0
    -- Never ask from beyond our own clock, whatever is stored: covers a value
    -- written before this rule existed, and one persisted by an older build -
    -- which, since SavedVariables load again (#23), is no longer hypothetical.
    return math.min(wm, time() - WATERMARK_SLACK)
end

-- Raise to the newest stamp received, then cap at the ceiling - applied to the
-- stored value too, so a watermark already in the future is pulled back rather
-- than only ever ratcheting upward.
local function AdvancePeerWatermark(name, ts, peerNow)
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.peerWatermarks = AltStableConfig.peerWatermarks or {}
    local short = PeerShort(name)
    local current = AltStableConfig.peerWatermarks[short] or 0
    if not tonumber(peerNow) then
        -- No clock from this peer: never delta against it (see above).
        if current ~= 0 then
            AltStableConfig.peerWatermarks[short] = nil
            AltStable.OnConfigChanged("peerWatermarks")
        end
        return
    end
    local new = math.min(math.max(current, tonumber(ts) or 0), WatermarkCeiling(peerNow))
    if new > 0 and new ~= current then
        AltStableConfig.peerWatermarks[short] = new
        AltStable.OnConfigChanged("peerWatermarks")
    end
end
AltStable.ResetPeerWatermarks = function() AltStable.SetConfigValue("peerWatermarks", {}) end

-- Forget a character: the record goes, and a tombstone stops peers putting it
-- back. Returns false with a reason the caller can print.
--
-- Not the character being played. Its record would be rewritten by the next
-- scan seconds later, so "forgetting" it would look broken rather than
-- destructive - and the honest answer is that you cannot forget somebody you
-- are standing on.
function AltStable.ForgetCharacter(guid)
    if not guid or not AltStableDB or not AltStableDB[guid] then
        return false, "no such character"
    end
    if guid == (UnitGUID and UnitGUID("player")) then
        return false, "that is the character you are playing - log in as someone else first"
    end

    local name = AltStableDB[guid].name or guid
    AltStableDB[guid] = nil
    AltStable.MarkCharacterForgotten(guid, time(), name)

    -- Drop the display preferences with the record. The hidden list keeps
    -- orphans on purpose, because "the record usually comes back on the next
    -- sync" - here it never will, so the entry would sit in SavedVariables for
    -- good, and an unforget would silently bring the character back invisible.
    if AltStable.SetCharacterHidden then AltStable.SetCharacterHidden(guid, false) end
    if AltStable.SetCharacterFavourite then AltStable.SetCharacterFavourite(guid, false) end
    -- And its seat in a Roster camp (#152): a forgotten character leaves it.
    if AltStable.RemoveFromCamp then AltStable.RemoveFromCamp(guid) end

    -- The plugins hold their own per-character tables and would otherwise keep
    -- the inventory, recipes and lockouts of a character nothing shows.
    for _, plugin in ipairs(AltStable.plugins or {}) do
        if plugin.OnForget then pcall(plugin.OnForget, guid) end
    end

    if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    return true, name
end
-- A character by name, for the slash commands. Returns the GUID, or nil and a
-- message to print.
--
-- Ambiguity is refused rather than guessed. The fallback match is on the first
-- name, and this client has four pairs of alts sharing one - so iterating with
-- pairs() deleted a different character run to run, silently, on a command
-- whose whole job is to delete something. Naming the candidates costs one line
-- and is the only answer that is not a coin toss.
function AltStable.ResolveCharacter(name)
    if not name or name == "" then return nil, "usage: a character name" end
    local want = name:lower()

    -- Three ways to name someone, narrowing as they go: "Name-Realm" is
    -- unambiguous, a full name usually is, a first name often is not.
    local exact, full, partial = {}, {}, {}
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name then
            local n = c.name:lower()
            local qualified = c.realm and (n .. "-" .. tostring(c.realm):lower()) or nil
            if qualified == want then
                exact[#exact + 1] = { guid = guid, name = c.name, realm = c.realm }
            elseif n == want then
                full[#full + 1] = { guid = guid, name = c.name, realm = c.realm }
            elseif n:match("^(%S+)") == want then
                partial[#partial + 1] = { guid = guid, name = c.name, realm = c.realm }
            end
        end
    end

    -- A realm-qualified name is the selector, so it wins outright.
    if #exact == 1 then return exact[1].guid end

    local function ambiguous(list)
        table.sort(list, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return tostring(a.realm) < tostring(b.realm)
        end)
        local shown = {}
        for _, e in ipairs(list) do
            shown[#shown + 1] = e.realm and (e.name .. "-" .. e.realm) or e.name
        end
        return nil, "|cffff8800" .. name .. " is ambiguous|r - did you mean "
            .. table.concat(shown, ", ") .. "? Name the realm too."
    end

    if #exact > 1 then return ambiguous(exact) end

    -- A full name matching more than once is the case that was missed: the same
    -- character name exists on a PvE and a PvP realm, and `exact = guid` in a
    -- pairs() loop simply kept the last one seen.
    if #full == 1 then return full[1].guid end
    if #full > 1 then return ambiguous(full) end

    if #partial == 1 then return partial[1].guid end
    if #partial > 1 then return ambiguous(partial) end

    return nil, "|cffff8800No character called|r " .. name
end

-- Mark a character dirty so the next delta sync includes it. Plugins call this
-- when their own per-character data changes (e.g. a recipe learned) so the
-- change actually rides a delta — otherwise the character would be filtered out
-- because its core lastUpdate didn't move.
function AltStable.TouchCharacter(guid)
    if guid and AltStableDB[guid] then
        AltStableDB[guid].lastUpdate = time()
    end
end

-- sinceTS > 0 => delta: send only characters changed since the requester last
-- heard from us. sinceTS <= 0 => full DB (first sync / forced resync).
-- `also` (a set of guids) is sent whatever the account and the delta say:
-- the members of the camps going to our own other account (#171), so it knows
-- every one of them rather than pruning the ones it has no record of.
local function SerializeFullDB(accountOnly, sinceTS, also)

    local entries = {}
    sinceTS = sinceTS or 0

    -- When accountOnly is true, only send characters whose account field
    -- matches this client's configured account number.  Characters with
    -- no account set are always included (they haven't been tagged yet).
    AltStableConfig = AltStableConfig or {}
    local myAccount = AltStableConfig.accountNumber

    for _, c in pairs(AltStableDB) do
        -- `>=` (not `>`): time() is 1-second resolution, so a character changed
        -- in the same second the watermark was set to must still be sent. The
        -- cost is re-sending characters that share the newest timestamp (usually
        -- just the currently-played one) — negligible under compression, and the
        -- merge is idempotent (last-write-wins accepts an equal timestamp).
        if type(c) == "table" and c.guid and also and also[c.guid] then
            entries[#entries + 1] = SerializeChar(c, sinceTS)
        elseif type(c) == "table" and c.guid
        and (sinceTS <= 0 or (c.lastUpdate or 0) >= sinceTS) then
            if accountOnly and myAccount and myAccount ~= "" then
                local charAcct = c.account
                if charAcct and charAcct ~= "" and tostring(charAcct) ~= tostring(myAccount) then
                    -- Skip — belongs to a different account
                else
                    entries[#entries + 1] = SerializeChar(c, sinceTS)
                end
            else
                entries[#entries + 1] = SerializeChar(c, sinceTS)
            end
        end
    end

    -- Each entry is followed by a separator line.
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = entry
        lines[#lines + 1] = CHAR_SEP
    end

    return table.concat(lines, "\n")

end

------------------------------------------------------------
-- Deserialize full DB
------------------------------------------------------------

-- Wipe the per-slot gear and per-profession "current state" fields from a
-- record before merging incoming data. Without this, a slot the source
-- unequipped or a profession it dropped would retain its stale field, because
-- the merge only writes keys that ARE present in the new data.
--
-- gearlink_ and gearsubtype_ are cleared too: they are local-only, never on the
-- wire, so on any record the merge touches they describe a scan that is no
-- longer the newest - and a REMOTE record must never carry a link at all (one
-- left by an old addon version that synced links would show gear no longer
-- worn). Our OWN characters are protected before this runs, by ShouldMerge,
-- which keeps a peer's echo from being merged over them in the first place.
--
-- Preserves metadata (account, guild, money, name, class, …): the incoming
-- record overwrites those when present, and a peer that hasn't tagged a
-- character shouldn't wipe our local account assignment.
local function ClearSyncedStateFields(t)
    t.prof1 = nil; t.prof2 = nil
    -- Money and the stat snapshot: a value that became UNREADABLE (secret, see
    -- Compat.lua) is written as nil locally and simply omitted from the wire -
    -- so without clearing first, the receiving account keeps showing and
    -- summing the last number it saw, as though it were current. Same rule as
    -- the prefixes below: an accepted record is the whole truth about these.
    t.money = nil
    t.prof1Skill = nil; t.prof2Skill = nil
    t.prof1Max   = nil; t.prof2Max   = nil
    -- Helm/cloak display toggles. A current peer always sends both (the scanner writes 1 or 0
    -- every scan), so the merge below restores them immediately. Clearing them first only
    -- matters for a MIXED-VERSION peer whose build predates the fields: without this, a
    -- previously-synced hidehelm=1 would linger and keep rendering that character bare-headed
    -- on the word of a scan that peer can no longer confirm. Absent means "shown", which is
    -- the safe direction to fail.
    t.hidehelm = nil; t.hidecloak = nil
    for k in pairs(t) do
        if k:find("^prof_") or k:find("^profmax_")
        or k:find("^gear_") or k:find("^gearq_")
        or k:find("^gearname_") or k:find("^gearid_")
        or k:find("^gearmod_")   -- NOTE: "^gear_" does NOT match "gearmod_"
        or k:find("^gearlink_") or k:find("^gearsubtype_")  -- both local-only (see note above)
        or k:find("^cd_") or k:find("^known_")   -- craft cooldowns (dynamic cd_<prof>@<label>) + legacy known_ flags
        or k:find("^si_")                        -- saved raid lockouts (si_<name>@<diff>)
        or k:find("^mail_")                      -- mail summary (mail_count / mail_expiry / mail_money)
        or k:find("^stat_")                      -- the stat snapshot: a stat that went unreadable must not linger
        or k:find("^rep_")                       -- reputations: a standing dropped at the source goes here too
        or k:find("^pet_") then                  -- the pet (#75): the owner's scan keeps the last one seen, so absent means none
            t[k] = nil
        end
    end
end

-- Whether an incoming record may overwrite what we hold.
--
-- A character this client scans (scannedHere) is OURS, and our scan is the
-- authority. With the default config a peer relays every record it holds,
-- including ours, so most of what arrives for our own characters is our own
-- record echoed back. It is accepted only if strictly newer - meaning the
-- character was genuinely played somewhere else since.
--
-- Everything else keeps the old rule: the local copy wins only if it is more
-- than 60 seconds newer, because a remote record sent with incomplete gear
-- (GetItemInfo cache miss) is often corrected moments later with the same
-- stamp. Applied to our own characters, that grace let a peer's slightly older
-- copy roll back gear we had just scanned - and take its links with it.
local function ShouldMerge(existing, incoming)
    local existingTime = existing.lastUpdate or 0
    local incomingTime = incoming.lastUpdate or 0
    if existing.scannedHere then
        return incomingTime > existingTime
    end
    return existingTime - incomingTime <= 60
end

-- Forgotten here (#65): the peer still holds this character and always will
-- until they forget it too, so dropping it once locally is not enough - it
-- arrives again every sync.
--
-- Shared, and called from BOTH receive paths. ReceiveCharacter's own header
-- warns that the two "cannot drift - they had", and putting this check in only
-- the bulk path drifted them again: the single-character path, still used by
-- the chunked stream and by older peers, put the character straight back.
--
-- Refreshing the stamp keeps a contested tombstone at the front of the eviction
-- queue.
local function RefuseIfForgotten(c)
    if not c or not c.guid then return false end
    if not (AltStable.IsCharacterForgotten and AltStable.IsCharacterForgotten(c.guid)) then
        return false
    end
    AltStable.MarkCharacterForgotten(c.guid, time())
    return true
end

local function DeserializeFullDB(payload, sender)

    local current = {}
    local rejected = 0
    local maxTS = 0   -- newest lastUpdate seen; the caller advances the peer watermark to it
    local peerNow     -- the sender's clock, when it sent one (SEND_TIME)

    for line in (payload .. "\n"):gmatch("([^\n]*)\n") do

        local stamped = line:match("^" .. SEND_TIME .. ":(%d+)$")
        if stamped then
            peerNow = tonumber(stamped)
        elseif AltStable.CAMPS_LINE and (line:find(AltStable.CAMPS_LINE, 1, true) == 1
                or line:find(AltStable.ORDER_LINE, 1, true) == 1) then
            -- Camps and the list order (#171), only from the player's own other
            -- account: a friend's sync never rearranges your Roster.
            if OwnBNetPeer(sender) then AltStable.ApplyCampSyncLine(line) end
        elseif line == CHAR_SEP then
            -- End of a character block — deserialize what we have.
            local msg = table.concat(current, "\n")
            current = {}

            local c = DeserializeChar(msg)

            if c and c.guid then

                -- Track the newest timestamp across everything the peer sent
                -- (even rejected/skipped records) so the watermark advances past
                -- them and they aren't re-requested next delta.
                if (c.lastUpdate or 0) > maxTS then maxTS = c.lastUpdate end

                if RefuseIfForgotten(c) then c = nil end
            end

            if c and c.guid then

                -- Validate immutable fields before merging
                if not ValidateIncoming(c, sender) then
                    rejected = rejected + 1
                else
                    local existing = AltStableDB[c.guid] or {}

                    if ShouldMerge(existing, c) then
                        local priorName = existing.name
                        DispatchPluginPayloads(c)
                        ClearSyncedStateFields(existing)
                        for k,v in pairs(c) do
                            existing[k] = v
                        end
                        KeepFullerName(existing, priorName)
                        AltStableDB[c.guid] = existing
                    else
                        DispatchPluginPayloads(c, true)
                    end
                end

            end

        else
            current[#current + 1] = line
        end

    end

    if rejected > 0 then
        Print("|cffff8800Warning:|r " .. rejected .. " character(s) rejected due to validation failures.")
    end

    if AltStable.RefreshSheet then
        AltStable.RefreshSheet()
    end

    return maxTS, peerNow

end

------------------------------------------------------------
-- Send character  (line-aligned chunks — single messages cap at 255 bytes)
------------------------------------------------------------

-- Send one wire message, paced by ChatThrottleLib when present (it queues +
-- rate-limits), falling back to a direct send if CTL somehow isn't loaded.
-- CTL (v32) raises only on its argument checks - an unknown priority, or an
-- oversize (>255) message - so the call is wrapped: a pathological over-budget
-- packet degrades to a direct send (which returns a refusal code) instead of
-- aborting the whole ChunkAndSendPayload loop. With MAX_CHUNK=220 this is
-- belt-and-suspenders - it should never fire. An error INSIDE the send, v32
-- catches and reports as GeneralError; it never reaches this pcall.
--
-- One CTL queue per destination (queueName). v32's default is one per PREFIX,
-- so a full push to one peer made every other peer's reply wait behind it, and
-- a throttle on one blocked both; v24 queued per destination and round-robined
-- between them, which is what this keeps (review of #138). Order within a
-- destination is still FIFO, so a DONE still follows its chunks.
-- `prio` defaults to BULK, which is right for chunks. A REQ goes at ALERT:
-- it is one small message that must not queue behind - or be sent raw on top
-- of - a large outgoing burst.
--
-- Each whisper stamps WHEN it actually left (ChatThrottleLib's per-message
-- callback: a whole database is queued at once and drains for many seconds),
-- so a "No player named X" arriving from the server can be told apart as the
-- answer to OUR traffic - see the unreachable-target handling below.
local lastWhisperAt = {}          -- AuthKey -> when addon traffic last went to them
local function StampWhisper(key) lastWhisperAt[key] = time() end

-- The server's answer to a send, when it has one: C_ChatInfo.SendAddonMessage
-- returns an Enum.SendAddonMessageResult on this client. CTL v32 retries only
-- AddonMessageThrottle and reports the rest through the callback as
-- (arg, didSend, result). TargetOffline says, at send time, what the chat line
-- "No player named X" says later: they cannot be reached. Whether this client
-- actually returns it for an offline or other-faction whisper is unmeasured
-- (forever-api-notes); acting on it costs nothing if it never comes.
local SEND_OK = 0
local SEND_TARGET_OFFLINE = (Enum and Enum.SendAddonMessageResult
    and Enum.SendAddonMessageResult.TargetOffline) or 12
local NoteUnreachable            -- defined with the unreachable-target handling below

local function SendSucceeded(result)
    return result == nil or result == true or result == SEND_OK
end

-- onSent(didSend), optional, runs when the message actually leaves - which
-- under ChatThrottleLib can be well after this call returns.
--
-- Addon whispers only. Our own other accounts go over the library, which
-- callers try first (LibSync.SendRequest, ChunkAndSendPayload); what reaches
-- here as "BNET" is a library send that was refused, and there is no other
-- way across: nothing is sent, never a whisper that cannot cross.
local function QueueWire(msg, channel, target, prio, onSent)
    if channel == "BNET" then
        if onSent then onSent(false) end
        return
    end
    -- "WHISPER_DIRECT": a plain whisper - the answer to a request that came BY
    -- whisper goes back the same way (Codex, #142), never over the library.
    if channel == "WHISPER_DIRECT" then
        channel = "WHISPER"
    end
    local key = channel == "WHISPER" and AuthKey(target) or nil
    local function sent(_, didSend, result)
        -- Only a message that went out is stamped: a refused one draws no
        -- "No player named" echo to recognize.
        if didSend ~= false and key then StampWhisper(key) end
        if key and result == SEND_TARGET_OFFLINE and NoteUnreachable then
            NoteUnreachable(target, key)
        end
        if onSent then onSent(didSend ~= false) end
    end
    local function raw()
        local result = C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
        sent(key, SendSucceeded(result), result)
    end
    if ChatThrottleLib then
        -- Stamped by CTL's callback, when the message actually leaves.
        local ok = pcall(ChatThrottleLib.SendAddonMessage, ChatThrottleLib, prio or "BULK", PREFIX, msg,
                         channel, target, PREFIX .. channel .. (target or ""),
                         (key or onSent) and sent or nil, key)
        if not ok then raw() end
    else
        raw()
    end
end

------------------------------------------------------------
-- Unreachable whisper targets
------------------------------------------------------------
-- Every addon whisper to someone who is offline - or on the OTHER FACTION,
-- since the server delivers no whisper across factions, addon messages
-- included - comes back as one "No player named 'X' is currently playing."
-- A manual /alts sync pushes the database as dozens of whispers, so the chat
-- filled with dozens of those lines (measured on 70124: a character online on
-- the other faction). The server says nothing about WHY; mail is told "wrong
-- faction", whispers are not.
--
-- So: the server's line is hidden while it is the echo of our own traffic (a
-- few seconds after our last whisper to them - the player's own whisper to
-- the same person inside that window loses its line too, which is the usual
-- trade for addons that do this), a push is only sent once a single request
-- has gone through without that answer, and a sync the player typed gets one
-- line of ours - naming the faction when we know theirs from the database.
local UNREACHABLE_ECHO = 10       -- seconds after our last whisper to them
--
-- Each /alts sync is an ATTEMPT with its own result: a retry must not erase
-- an earlier attempt's failure (whose delayed push would then go out), and
-- two attempts must not both push (Codex, review of #137). Only the current
-- attempt for a peer may push. unreachableToldAt is cleared per attempt: one
-- line per /alts sync, not per minute.
local syncAttempt = {}            -- AuthKey -> the current manual attempt
local manualSyncAt = {}           -- AuthKey -> when the player typed /alts sync <them>
local unreachableToldAt = {}      -- AuthKey -> when we said so for this attempt

-- Built once from the client's format string: this runs for every system
-- message, in every chat frame's filter.
local notFoundPattern, notFoundFormat
local function NotFoundName(text)
    local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(fmt) ~= "string" or type(text) ~= "string" then return nil end
    if fmt ~= notFoundFormat then
        local pattern = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
        notFoundPattern = "^" .. pattern:gsub("%%s", "(.+)", 1) .. "$"
        notFoundFormat = fmt
    end
    return text:match(notFoundPattern)
end

-- The echo of our own addon traffic, or someone else's business?
local function OurEcho(text)
    local name = NotFoundName(text)
    local key = name and AuthKey(name)
    if key and lastWhisperAt[key] and (time() - lastWhisperAt[key]) <= UNREACHABLE_ECHO then
        return name, key
    end
end

local function KnownFaction(key)
    for _, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name and AuthKey(c.name) == key then return c.faction end
    end
end

-- "This sync cannot go through" rather than "nothing more was sent": the echo
-- can come from a push already under way (they logged off during it), whose
-- queued remainder still drains - hidden, but sent.
local function SayUnreachable(name, key, transport)
    if unreachableToldAt[key] then return end
    unreachableToldAt[key] = time()
    -- Over Battle.net, faction is no obstacle: say what IS known. That holds for
    -- a character known as our own this session even when this attempt fell
    -- back to a whisper (the library stopped listing it): it logged off or
    -- switched.
    if transport == "BNET" or LibSync.seen[key] then
        Print("|cffff8800" .. name .. " cannot be reached through Battle.net|r - they logged "
            .. "off or switched character, so this sync cannot go through.")
        return
    end
    local mine = UnitFactionGroup and UnitFactionGroup("player")
    local theirs = KnownFaction(key)
    if mine and theirs and theirs ~= mine then
        Print("|cffff8800" .. name .. " is " .. theirs .. " and you are " .. mine .. "|r - addon "
            .. "messages do not cross factions, so this sync cannot go through.")
    elseif mine and theirs then
        Print("|cffff8800" .. name .. " cannot be reached|r - they are offline, so this sync "
            .. "cannot go through.")
    else
        Print("|cffff8800" .. name .. " cannot be reached|r - offline, or on the other faction "
            .. "(addon messages do not cross factions), so this sync cannot go through.")
    end
end

-- Unreachable, from either signal - the chat line or TargetOffline at send
-- time: the current manual attempt must not push, and a sync the player typed
-- is told once.
function NoteUnreachable(name, key, transport)
    if syncAttempt[key] then syncAttempt[key].unreachable = true end
    if manualSyncAt[key] and (time() - manualSyncAt[key]) <= 30 then
        SayUnreachable(name, key, transport)
    end
end

do
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
        or ChatFrame_AddMessageEventFilter
    if addFilter then
        addFilter("CHAT_MSG_SYSTEM", function(_, _, text)
            return OurEcho(text) ~= nil
        end)
    end
end

------------------------------------------------------------
-- Own accounts through LibAccountSync (#198)
------------------------------------------------------------
-- The library carries one whole message to ONE own account (SendTo), proven
-- ours, and delivers what our accounts send us (OnMessage). AltStable keeps
-- everything else: what to send, when, the gates, the merge.
--
-- Three messages, each a library payload (opaque bytes, binary-safe):
--   REQ8|<watermark>    a request, exactly the whisper command
--   DB8|<deflated>      a reply or a push: the payload ChunkAndSendPayload
--                       would chunk, deflated (no addon-channel encoding)
--   CAP8, CAP8|1       "do you run AltStable on the library?" and "yes": the handshake
-- An unknown command is dropped: a newer AltStable's, or nonsense.
--
-- A peer is on the library once an AltStable message came from it that way
-- (LibSync.peers), and that starts with CAP8. The library lists every own
-- account that runs ANY addon on it - GlassChat alone, say - so CAP8 is how we
-- learn which of them run AltStable. Nothing else reaches our own accounts
-- across factions and rulesets since the legacy channel went (#206): a v0.10
-- AltStable, which only spoke that, no longer syncs with us over Battle.net.
--
-- Only with a copy that delivers INDEPENDENT messages (inst.messages, r5+).
-- r4's delivery is a snapshot floor: a database overtaken by a later request
-- or ping was dropped silently (LibAccountSync#18). Checked when used, like
-- SendTo: an instance made by an older copy gains functions when a newer copy
-- loads, which can be after this file.
--
-- CAP8 is a question, CAP8|1 its answer. A question is always answered (a
-- peer that reloaded has forgotten us and asks again), at most every few
-- seconds; an answer is never answered, so two accounts cannot ping-pong.
LibSync.MSG_DB  = "DB"  .. PROTOCOL_VERSION
LibSync.MSG_CAP = "CAP" .. PROTOCOL_VERSION
LibSync.PING_EVERY, LibSync.PING_TRIES = 30, 5
LibSync.pinged = {}      -- guid -> { at, n }: our CAP8 questions to them
LibSync.answered = {}    -- guid -> when our CAP8|1 last went, taken by the library

function LibSync.Usable()
    local inst = LibSync.inst
    return inst ~= nil and inst.messages == true and type(inst.SendTo) == "function"
        and BNetEnabled()
end

-- Forget who runs it: Battle.net went away, or the switch went off.
function LibSync.Forget()
    LibSync.peers, LibSync.pinged, LibSync.answered = {}, {}, {}
end

-- One message to one GUID. True when the library took it: onDone(ok) then
-- runs exactly once, when it is on the wire or has failed. False when it was
-- refused: nothing was sent, and onDone never runs.
--
-- The library can report BEFORE SendTo returns (a peer without our nonce yet
-- is "failed"/"not-ready" at once, and ChatThrottleLib can send at once), so
-- its report is held until the return value says which case this is.
function LibSync.SendGuid(guid, msg, onDone, target)
    if not LibSync.Usable() or type(guid) ~= "string" then return false end
    local accepted, early
    local function report(ok)
        if not ok and target and NoteUnreachable then NoteUnreachable(target, AuthKey(target), "BNET") end
        if onDone then onDone(ok) end
    end
    local function result(_, status)
        if accepted == nil then
            early = status
        elseif accepted then
            report(status == "sent")
        end
    end
    local okCall, r = pcall(LibSync.inst.SendTo, guid, msg, result)
    accepted = okCall and r == 1
    if accepted and early ~= nil then report(early == "sent") end
    return accepted
end

-- The library route: "BNET", or a whisper to our own account on it. Never a
-- WHISPER_DIRECT (an answer to a whisper goes back the way it came) and never
-- a group channel.
function LibSync.RouteFor(channel, target)
    if channel ~= "BNET" and channel ~= "WHISPER" then return nil end
    if not LibSync.Usable() then return nil end
    return LibSync.Peer(target)
end

-- A request: over the library to a peer that runs it, else the whisper wire.
-- A refusal falls back for this one message - still to this one peer, never a
-- broadcast: a whisper if it was one, and for "BNET" nothing at all
-- (onSent(false), as for any unreachable peer).
-- `prio` is the whisper wire's: the library has no priorities, so a request can
-- wait behind a database still draining to the same account (a few seconds).
function LibSync.SendRequest(msg, channel, target, prio, onSent)
    local p = LibSync.RouteFor(channel, target)
    if p and LibSync.SendGuid(p.guid, msg, onSent, target) then return end
    QueueWire(msg, channel, target, prio, onSent)
end

-- The handshake. Each of our own accounts the library lists and we have not
-- heard on it yet gets a CAP8 question, every 30 s at most, five times. SendTo
-- to a peer whose nonce we lack is refused - and makes the library say hello
-- (at most every 5 s, its own limit) - so a refused question is not counted:
-- it is asked again at the next tick, which is what makes first contact quick
-- now that no legacy hello comes first. Five unanswered questions mean it runs
-- no AltStable on the library (GlassChat alone, or a v0.10 AltStable): asked
-- again only after Battle.net reconnects or the switch is turned back on
-- (LibSync.Forget), and it can always ask us.
function LibSync.Ping()
    if not LibSync.Usable() then return end
    local ok, listed = pcall(LibSync.inst.Peers)
    if not ok or type(listed) ~= "table" then return end
    local now = time()
    for _, q in ipairs(listed) do
        local key = AuthKey(q.name)
        local known = key and LibSync.peers[key]
        local asked = type(q.guid) == "string" and (LibSync.pinged[q.guid] or { at = 0, n = 0 })
        if asked and not (known and known.guid == q.guid) and asked.n < LibSync.PING_TRIES
            and (now - asked.at) >= LibSync.PING_EVERY
            and LibSync.SendGuid(q.guid, LibSync.MSG_CAP) then
            LibSync.pinged[q.guid] = { at = now, n = asked.n + 1 }
        end
    end
end

local function ChunkAndSendPayload(payload, channel, target)

    -- Our own account on the library: the whole payload as one message. A
    -- refusal (no nonce yet, too large, switched off) falls through to the
    -- chunks below, still to this one peer, when it was a whisper. Over
    -- "BNET" there is no other way: nothing goes, as to any unreachable peer,
    -- and the requester's stall watch says so.
    local libPeer = LibSync.RouteFor(channel, target)
    if libPeer and LibDeflate then
        local deflated = LibDeflate:CompressDeflate(payload or "", { level = 8 })
        if LibSync.SendGuid(libPeer.guid, LibSync.MSG_DB .. "|" .. deflated, nil, target) then return end
    end
    if channel == "BNET" then return end

    -- Compress the whole payload once (DEFLATE crushes the repetitive recipe
    -- data), then make it addon-channel safe. The body is opaque bytes chunked
    -- at byte boundaries; the receiver reassembles, checksums, decodes, and
    -- decompresses.
    local encoded
    if LibDeflate then
        encoded = LibDeflate:EncodeForWoWAddonChannel(
            LibDeflate:CompressDeflate(payload or "", { level = 8 }))
    else
        encoded = payload or ""   -- defensive; LibDeflate ships in the .toc
    end

    local chunks = {}
    for pos = 1, #encoded, MAX_CHUNK do
        chunks[#chunks + 1] = encoded:sub(pos, pos + MAX_CHUNK - 1)
    end
    if #chunks == 0 then chunks[1] = "" end   -- empty payload => one empty chunk

    local total    = #chunks
    local checksum = ComputeChecksum(encoded)

    -- One stream id per send, echoed in every CHUNK and the DONE, so the
    -- receiver never mixes this stream with a concurrent/retried one.
    streamCounter = streamCounter + 1
    local sid = streamCounter

    -- Hand every chunk (then the DONE) to ChatThrottleLib at BULK priority. CTL
    -- paces them at the game's real outbound rate — far faster than the old
    -- 1s/chunk sleep and without over-sending — and preserves FIFO order per
    -- destination, so the DONE reliably lands after the last chunk. No manual
    -- C_Timer pacing needed.
    for idx, chunk in ipairs(chunks) do
        local header = MSG_CHUNK_V .. "|" .. sid .. "|" .. idx .. "/" .. total .. "|"
        QueueWire(header .. chunk, channel, target)
    end
    QueueWire(MSG_DONE_V .. "|" .. sid .. "|" .. checksum, channel, target)

end

------------------------------------------------------------
-- Send full DB  (line-aligned chunks, throttled to avoid packet loss)
-- channel: "GUILD", "WHISPER", "PARTY", etc.
-- target:  required for WHISPER, nil otherwise
------------------------------------------------------------

-- sinceTS: when replying to a delta REQ, only the characters changed since the
-- requester's watermark are sent. Omitted (nil) => full DB (a manual push, where
-- we don't know what the target already has).
-- Stagger replies with entropy from OUR OWN name plus the clock, so two
-- clients answering the same broadcast do not pick the same moment
-- (math.random alone is seeded identically right after launch). Deterministic,
-- and distinct per character: between 1.0 and 4.0 seconds.
--
-- The whole name, surname included. Two characters sharing a first name is
-- exactly what Forever surnames produce, so seeding from "Kaleid" alone hands
-- both clients the same delay - the collision this exists to prevent.
local function ReplyDelay(name, now)
    local seed = 0
    name = tostring(name or "")
    for i = 1, #name do seed = seed + string.byte(name, i) end
    return 1 + ((seed + ((now or 0) % 1000)) % 30) / 10
end

local function SendFullDatabase(channel, target, sinceTS)

    channel = channel or "GUILD"

    -- By default only send characters from the current account.
    -- If sendAllAccounts is enabled in config, send everything.
    AltStableConfig = AltStableConfig or {}
    local accountOnly = not AltStableConfig.sendAllAccounts

    -- The camps and the list order (#171), to the player's own other account
    -- only - after the last record, where every parser reads past them - with
    -- the records of everyone in a camp.
    local toOwn = target and OwnBNetPeer(target) and AltStable.CampSyncLines
    local payload = SerializeFullDB(accountOnly, sinceTS, toOwn and AltStable.CampMemberGuids() or nil)
    if toOwn then
        for _, line in ipairs(AltStable.CampSyncLines()) do
            payload = payload .. "\n" .. line
        end
    end
    -- Our clock, so the requester can keep its watermark in OUR frame.
    payload = payload .. "\n" .. SEND_TIME .. ":" .. time()
    ChunkAndSendPayload(payload, channel, target)

end


-- Defined here because it needs SendFullDatabase, and declared far above
-- because the message handler needs it. See the note by the forward
-- declaration for why the scope bookkeeping lives in here.
local function DefineSyncServing()
    function ServeSyncRequest(peer, sinceTS, channel)
        AltStableConfig = AltStableConfig or {}
        -- Scope and watermark keys stay as PeerShort, matching what is already
        -- persisted under them; only the authorization side is case-folded.
        local owedShort = PeerShort(peer)

        -- Served a peer who was waiting (through /alts sync consent, say):
        -- the prompt and the Options list must stop showing the question.
        local pk = AuthKey(peer) or owedShort
        if pendingAuth[pk] then
            pendingAuth[pk] = nil
            SyncAuthChanged()
        end

        -- ALWAYS a whisper, to the character that asked.
        --
        -- A request arriving on GUILD used to be answered on GUILD, so every
        -- guild member received the database - including the ones who had not
        -- been authorized and the ones explicitly denied. Authorizing one peer
        -- must not authorize a broadcast, and there is no reason for an answer
        -- to a question to reach anyone but the asker. BroadcastDB is a
        -- separate, deliberate act.
        -- And on the transport the question came in on (Codex, #142): a
        -- Battle.net request gets a Battle.net answer, a whisper a whisper.
        local replyChannel = (channel == "BNET") and "BNET" or "WHISPER_DIRECT"
        local replyTarget = peer
        if not peer or peer == "" then return end
        Print(peer .. " requested sync — sending data.")
        local delay = ReplyDelay(AltStable.API.PlayerFullName(), time())
        C_Timer.After(delay, function()
            -- Consent has to be CURRENT, not merely not-revoked. The reply is
            -- staggered by a few seconds, and in that window the player can
            -- read the name and change their mind - by denying, or by typing
            -- /alts forget-peer, which drops the answer back to "ask". Testing
            -- only for NEVER let the second one through: the stored decision
            -- said ask and the database went out anyway.
            -- MayServe: approved for good, or named by us in /alts sync
            -- moments ago - and never a NEVER.
            if not MayServe(peer) then
                Print("|cffff8800" .. peer
                    .. " is no longer approved - nothing was sent.|r")
                return
            end

            -- The scope generation is spent HERE, not when the reply was
            -- scheduled. Marking a peer "answered in full at generation N"
            -- before knowing whether the answer goes out meant a cancelled
            -- reply consumed the scope change: re-approving them afterwards
            -- got a delta again, and the newly eligible records - stamped
            -- below every watermark - were never sent at all.
            local generation = ScopeGeneration()
            AltStableConfig.peerScopeGeneration = AltStableConfig.peerScopeGeneration or {}
            if (AltStableConfig.peerScopeGeneration[owedShort] or 0) < generation then
                sinceTS = 0   -- our scope changed since this peer last heard from us
                AltStableConfig.peerScopeGeneration[owedShort] = generation
                AltStable.OnConfigChanged("peerScopeGeneration")
            end

            SendFullDatabase(replyChannel, replyTarget, sinceTS)
        end)
    end

    function RememberPendingRequest(peer, sinceTS, channel)
        local key = AuthKey(peer)
        if not key then return end
        local now = time()
        local prev = pendingAuth[key]
        pendingAuth[key] = { name = peer, since = sinceTS, channel = channel, at = now,
                             told = prev and prev.told or nil }
        SyncAuthChanged()   -- the prompt and the Options list

        -- Say it once per minute per peer. A client that retries - and ours
        -- does, on every login and every resync - must not turn a single
        -- unanswered question into a wall of chat.
        if prev and prev.told and (now - prev.told) < NOTICE_EVERY then return end
        pendingAuth[key].told = now

        -- The FULL identity, realm and all, in the text and in both commands.
        --
        -- Showing PeerShort meant the prompt said "Faraway Name is asking" and
        -- told the player to type /alts allow Faraway Name - which grants the
        -- LOCAL character of that name while the cross-realm requester stays
        -- pending. A prompt whose own instruction authorizes the wrong person
        -- is worse than no prompt.
        local shown = peer
        Print("|cffff8800" .. shown .. " is asking for your character database.|r "
            .. "Nothing has been sent. "
            .. "|cffffff00/alts allow " .. shown .. "|r to share with them from now on, "
            .. "|cffffff00/alts deny " .. shown .. "|r to refuse them for good.")
    end
end

-- Answer on the player's behalf, and remember the answer. Returns whether the
-- name was usable, so the slash command can tell the difference between "done"
-- and "I do not know what you mean".
function AltStable.AllowSyncPeer(peer)
    if not SetSyncAuth(peer, AUTH_AUTO) then return false end
    local key = AuthKey(peer)
    local req = pendingAuth[key]
    Print("Sharing with |cff88ff88" .. key .. "|r from now on.")
    -- Serve what they already asked for, if it is still their question. Beyond
    -- the TTL, wait for them to ask again rather than replying to something
    -- from another session.
    -- Cleared before serving, so the serve does not announce a half-done
    -- answer; announced once below.
    pendingAuth[key] = nil
    if req and (time() - (req.at or 0)) <= PENDING_TTL then
        ServeSyncRequest(req.name or key, req.since or 0, req.channel)
        -- And ask them back, so the exchange goes both ways: they asked
        -- because they want ours; we were never sent theirs (or refused it,
        -- unasked). Only when they are there to ask - a pending request says so.
        RequestCharacters(req.channel == "BNET" and "BNET" or "WHISPER_DIRECT", req.name or key, true)
    end
    refusedNotified[key] = nil
    SyncAuthChanged()
    return true
end

function AltStable.DenySyncPeer(peer)
    if not SetSyncAuth(peer, AUTH_NEVER) then return false end
    local key = AuthKey(peer)
    pendingAuth[key] = nil
    -- Any consent from /alts sync is left: a never overrides it everywhere,
    -- and forgetting them clears it.
    DropPeerStreams(peer)
    SyncAuthChanged()
    Print("Refusing |cffff8888" .. (PeerShort(peer) or key)
        .. "|r. They will not be told, will not be asked about again, "
        .. "and we will not push to them either.")
    return true
end

-- Drop the stored answer. Says what will ACTUALLY happen next rather than
-- assuming: clearing an answer for a whitelisted peer falls back to the
-- whitelist, which means auto, not ask. Printing "they will be asked about
-- again" there would tell the player the opposite of the truth - and the
-- player most likely to type this is one who denied someone they had
-- whitelisted and now wants to reconsider.
function AltStable.ForgetSyncPeer(peer)
    if not SetSyncAuth(peer, nil) then return false end
    ClearConsent(peer)
    SyncAuthChanged()
    local shown = PeerShort(peer) or AuthKey(peer)
    local whitelisted = false
    for _, w in ipairs((AltStableConfig or {}).whitelist or {}) do
        if AuthKey(w) == AuthKey(peer) then whitelisted = true end
    end
    if SyncAuthFor(peer) == AUTH_AUTO and not whitelisted then
        Print("Forgotten |cffffff00" .. shown .. "|r - but they are your own account on "
            .. "Battle.net, so they are served again. Switch off \"Sync with your other "
            .. "accounts through Battle.net\" in Options to stop that too.")
    elseif SyncAuthFor(peer) == AUTH_AUTO then
        Print("Forgotten |cffffff00" .. shown .. "|r - but they are on your whitelist, "
            .. "so they are served again. |cffffff00/alts whitelist remove " .. shown
            .. "|r to stop that too.")
    else
        Print("Forgotten |cffffff00" .. shown .. "|r - they will be asked about again.")
    end
    return true
end

DefineSyncServing()

------------------------------------------------------------
-- Request sync
--
-- RequestCharacters fires a REQ to a single target.  It throttles
-- duplicate requests to the same peer within REQUEST_THROTTLE seconds
-- so /alts followed quickly by another /alts (or PLAYER_LOGIN +
-- CHAT_MSG_SYSTEM peer-online firing close together) doesn't double
-- up.  `force=true` bypasses the throttle for explicit user actions
-- like /alts sync.  Returns true if a REQ was actually sent.
------------------------------------------------------------

-- Sync-watch: after we ask a peer for data, watch for it to arrive so the user
-- always gets closure — a "complete" line, a "stalled" line, or a "no response"
-- line — instead of silence when a peer is offline or still loading addons.
-- Keyed by realm-less short name (same as the delta watermark). The deadline is
-- pushed out on every chunk received, so an actively-transferring large sync is
-- never falsely reported; the check only fires after SYNC_WATCH_TIMEOUT of quiet.
local SYNC_WATCH_TIMEOUT = 45      -- seconds of silence before we report a stall
local syncWatch = {}              -- [peerShort] = { name, deadline, sawData }

-- Best-effort online check for a sync peer: true/false when we can find them in
-- the guild roster or friends list, nil when we can't tell. Used to avoid the
-- pointless "no sync response" warning for a peer that's simply offline — we
-- auto-re-request when they come online (CHAT_MSG_SYSTEM), so silence is correct.
local function IsPeerOnline(name)
    if not name then return nil end
    -- Your own other account found through Battle.net is online by definition.
    if OwnBNetPeer(name) then return true end
    local short = PeerShort(name):lower()

    if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
        for i = 1, (GetNumGuildMembers() or 0) do
            local gname, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if gname and PeerShort(gname):lower() == short then
                return online and true or false
            end
        end
    end

    if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
        for i = 1, (C_FriendList.GetNumFriends() or 0) do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.name and PeerShort(info.name):lower() == short then
                return info.connected and true or false
            end
        end
    end

    return nil
end

local function CheckSyncWatch(short)
    local w = syncWatch[short]
    if not w then return end       -- cleared by CompleteStream => sync finished OK
    local now = time()
    if now >= w.deadline then
        if w.sawData then
            Print("|cffff8800Sync from " .. w.name .. " stalled|r — partial data, no completion. Try |cffffff00/alts sync " .. w.name .. "|r.")
        else
            -- Only warn when the peer is CONFIRMED online (worth flagging: still
            -- loading, or an older AltStable that isn't answering). If they're
            -- confirmed offline, OR we can't tell — which is the norm for your own
            -- alts on another account, since they aren't in your guild/friends list
            -- — stay silent. We re-request automatically when they come online
            -- (CHAT_MSG_SYSTEM peer-online handler), so a timeout for an unreachable
            -- peer is just noise.
            if IsPeerOnline(w.name) == true then
                Print("|cff888888No sync response from " .. w.name .. "|r — they're online but didn't reply (they may not have allowed you yet, or are still loading addons, or are on an older AltStable).")
            end
        end
        syncWatch[short] = nil
    else
        -- Activity pushed the deadline out; re-check when it next expires.
        C_Timer.After((w.deadline - now) + 1, function() CheckSyncWatch(short) end)
    end
end

-- Begin (or restart) watching for a response from `target`.
local function WatchSyncPeer(target)
    if not target then return end
    local short = PeerShort(target)
    local fresh = not syncWatch[short]
    syncWatch[short] = { name = target, deadline = time() + SYNC_WATCH_TIMEOUT, sawData = false }
    if fresh then
        C_Timer.After(SYNC_WATCH_TIMEOUT + 1, function() CheckSyncWatch(short) end)
    end
end

-- Called on each chunk received from a peer: push the stall deadline out and
-- record that data is flowing, and when a stream completes: stop watching.
local function NoteSyncActivity(peer)
    local w = syncWatch[PeerShort(peer)]
    if w then w.deadline = time() + SYNC_WATCH_TIMEOUT; w.sawData = true end
end
local function ClearSyncWatch(peer)
    syncWatch[PeerShort(peer)] = nil
end

function RequestCharacters(channel, target, force, onSent)

    channel = channel or "GUILD"

    if target then
        -- Never a request to a peer refused for good: whoever calls - a login
        -- broadcast, the came-online notice, /alts sync - the answer is read
        -- when the request goes out.
        if SyncAuthFor(target) == AUTH_NEVER then return false end
        local now = time()
        if not force then
            local last = lastRequestedAt[AuthKey(target) or target]
            if last and (now - last) < REQUEST_THROTTLE then
                return false
            end
        end
        -- By peer key: "Name" and "Name-Realm" are one peer (#58).
        lastRequestedAt[AuthKey(target) or target] = now
    end

    -- Carry our delta watermark for this peer so they can send only what
    -- changed since we last heard from them. A peer on older code ignores the
    -- extra payload and replies with a full DB (correct, just unoptimized).
    local wm = target and GetPeerWatermark(target) or 0
    -- Through ChatThrottleLib at ALERT, not raw: a request can go out while
    -- CTL is still draining BULK chunks (a reply, a broadcast), and a raw send
    -- then lands with the outbound budget already spent and risks a silent
    -- server-side drop. ALERT also puts it ahead of that queue - which
    -- /alts sync relies on, since its request is the reachability check that
    -- decides whether the push goes out at all.
    LibSync.SendRequest(MSG_REQUEST_V .. "|" .. wm, channel, target, "ALERT", onSent)
    WatchSyncPeer(target)
    -- We asked, so their answer may come in (#61) - if it starts in time.
    if target then GrantConsent(target, false, true) end
    return true

end

------------------------------------------------------------
-- Fan-out helpers — send to all configured targets
------------------------------------------------------------

local function BroadcastDB()
    local targets = GetSyncTargets()
    for _, t in ipairs(targets) do
        SendFullDatabase(t.channel, t.target)
    end
end

------------------------------------------------------------
-- BroadcastRequest fires a REQ at every whitelisted peer.  Each
-- per-peer call goes through the throttle, so a peer we just talked
-- to gets skipped.  Returns the list of peers we actually pinged so
-- the caller can give meaningful user feedback.
------------------------------------------------------------

local function BroadcastRequest(force)
    local targets = GetSyncTargets()
    local pinged, skipped = {}, {}
    for _, t in ipairs(targets) do
        local ok = RequestCharacters(t.channel, t.target, force)
        if ok then
            pinged[#pinged + 1] = t.target
        else
            skipped[#skipped + 1] = t.target
        end
    end
    return pinged, skipped
end

------------------------------------------------------------
-- Battle.net discovery (#58, #198)
------------------------------------------------------------
-- The library finds our own accounts and proves them ours. A scan here keeps
-- it in step with the Battle.net sync switch and asks each account it lists
-- whether it runs AltStable (LibSync.Ping); an answer is handled in
-- LibSync.OnMessage, which announces the account and asks for its data.

function AltStable.IsOwnBNetPeer(name) return OwnBNetPeer(name) ~= nil end

-- The route a sync the player types takes: over the library to an own account
-- on it (BNET - the only way across factions and rulesets), unless it is
-- whitelisted, whose whisper is the route the player configured (a whisper to
-- an own account on the library still goes over it, and falls back to the
-- whisper when refused); otherwise the whisper.
function AltStable.SyncChannelFor(name)
    local key = AuthKey(name)
    if not key or not OwnBNetPeer(name) then return "WHISPER" end
    for _, w in ipairs((AltStableConfig or {}).whitelist or {}) do
        if AuthKey(w) == key then return "WHISPER" end
    end
    return "BNET"
end

local function ScanOwnAccounts()
    AltStable._bnetLastScan = time()
    -- The library follows the same switch (the Options toggle rescans) - told
    -- only when it differs: each SetEnabled writes the store and starts a
    -- library scan, and this runs on every Battle.net event.
    local inst, on = LibSync.inst, (AltStableConfig or {}).bnetSync ~= false
    if inst and type(inst.SetEnabled) == "function" and type(inst.IsEnabled) == "function" then
        local okE, now = pcall(inst.IsEnabled)
        if not okE or now ~= on then pcall(inst.SetEnabled, on) end
    end
    if not BNetEnabled() then
        LibSync.Forget()
        return
    end
    LibSync.Ping()
end
AltStable.RescanOwnAccounts = ScanOwnAccounts

-- Coalesced: Battle.net events can come many times a second.
local bnetScanPending = false
local function RequestBNetScan()
    if bnetScanPending then return end
    bnetScanPending = true
    C_Timer.After(2, function()
        bnetScanPending = false
        ScanOwnAccounts()
    end)
end

-- For /alts auth and Options: who was found this session.
function AltStable.OwnBNetPeers()
    local out = {}
    if not BNetEnabled() then return out end
    for key in pairs(LibSync.peers) do
        local p = LibSync.Peer(key)
        if p then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function ReceiveCharacter(c, sender)

    if not c or not c.guid then
        return
    end

    if RefuseIfForgotten(c) then return end

    -- Validate immutable fields before merging
    if not ValidateIncoming(c, sender) then
        return
    end

    local existing = AltStableDB[c.guid] or {}

    -- The same merge rule as DeserializeFullDB, shared so the two paths cannot
    -- drift - they had: this one never got the first ownership fix.
    if not ShouldMerge(existing, c) then
        DispatchPluginPayloads(c, true)   -- see DispatchPluginPayloads
        return
    end

    local priorName = existing.name
    DispatchPluginPayloads(c)
    ClearSyncedStateFields(existing)
    for k,v in pairs(c) do
        existing[k] = v
    end
    KeepFullerName(existing, priorName)

    AltStableDB[c.guid] = existing

    if AltStable.RefreshSheet then
        AltStable.RefreshSheet()
    end

end

------------------------------------------------------------
-- Bounded auto-resync
--
-- Shared by both failure paths on the receiver — missing chunks AND a
-- checksum mismatch. Asks the peer for a fresh stream up to twice, then
-- gives up and resets the counter. `peer` is the full Name-Realm sender,
-- which is also a valid whisper target.
------------------------------------------------------------

-- Everything in flight from one peer: its buffers, its watch, its retries.
-- Called when a peer is refused mid-stream.
--
-- Matched by KEY, not by the text: the Options list passes the stored,
-- lower-cased key, and a player may type any case or form, while the buffers,
-- the watch and the retries are filed under the sender exactly as it arrived.
-- A text match left all three behind for "mid surname" vs "Mid Surname"
-- (review of #136).
function DropPeerStreams(peer)
    local key = AuthKey(peer)
    if not key then return end
    local function same(name) return name and AuthKey(name) == key end
    -- A dropped stream is REFUSED, not forgotten: if the peer is allowed again
    -- while it is still arriving, its remaining packets must not start a
    -- buffer from the middle - "1/2 chunks missing" and a resync. And the
    -- streams already refused stay refused, for the same reason (Codex, review
    -- of #136). The sweep clears both markers once the stream has gone quiet.
    local now = time()
    for bkey in pairs(incomingBuffers) do
        if same(bkey:match("^(.*)#%d+$")) then
            incomingBuffers[bkey] = nil
            refusedStreams[bkey] = now
        end
    end
    for short, w in pairs(syncWatch) do
        if same(w.name or short) then syncWatch[short] = nil end
    end
    for name in pairs(autoRetryCounts or {}) do
        if same(name) then autoRetryCounts[name] = nil end
    end
end

-- A stream we did not ask for, from someone we have not approved: said once
-- per peer per session, and not at all for a NEVER - they were answered.
function NoteRefusedStream(peer)
    if SyncAuthFor(peer) == AUTH_NEVER then return end
    local key = AuthKey(peer)
    if not key or refusedNotified[key] then return end
    refusedNotified[key] = true
    -- Allowing does not fetch what was refused - say how to get it.
    Print("|cffff8800" .. peer .. " sent character data you did not ask for|r - nothing was "
        .. "taken. |cffffff00/alts allow " .. peer .. "|r to accept theirs from now on, then "
        .. "|cffffff00/alts sync " .. peer .. "|r to exchange.")
end

local function RequestResync(peer, reason, transport)
    -- Recovery continues a stream already admitted; it never starts one with a
    -- peer refused for good.
    if SyncAuthFor(peer) == AUTH_NEVER then
        DropPeerStreams(peer)
        return
    end
    autoRetryCounts = autoRetryCounts or {}
    -- By peer key, like the buffers: one peer, one budget (#58).
    local rkey = AuthKey(peer) or peer
    autoRetryCounts[rkey] = (autoRetryCounts[rkey] or 0) + 1
    if autoRetryCounts[rkey] <= 2 then
        Print("|cffff8800Sync incomplete|r from " .. peer .. " — " .. reason ..
              " Auto-requesting resync (attempt " .. autoRetryCounts[rkey] .. "/2).")
        C_Timer.After(2, function()
            if SyncAuthFor(peer) == AUTH_NEVER then return end
            -- The way the failed stream came (Codex, #142).
            LibSync.SendRequest(MSG_REQUEST_V .. "|" .. GetPeerWatermark(peer),
                              transport == "BNET" and "BNET" or "WHISPER_DIRECT", peer, "ALERT")
        end)
        -- The retry's answer is a NEW stream: let it start, as the original
        -- was let in. This continues an admitted exchange; RequestResync is
        -- only ever reached from one (CompleteStream).
        GrantConsent(peer, false, true)
        WatchSyncPeer(peer)   -- give the retry its own fresh stall window
    else
        Print("|cffff0000Sync failed|r from " .. peer .. " — " .. reason ..
              " after 2 auto-retries. Try /alts sync " .. peer .. " manually.")
        autoRetryCounts[rkey] = nil
        ClearSyncWatch(peer)  -- already reported failure; don't also fire the watch
    end
end

------------------------------------------------------------
-- Finalize a received stream: verify completeness + checksum, then merge.
-- Called either immediately (buffer already complete on DONE) or after the
-- grace window (DONE arrived before a late/reordered chunk). Reads the
-- DONE's checksum stashed on the buffer as `buf.checksum`.
------------------------------------------------------------

-- A complete, decoded payload from a peer, by either transport: a character
-- record or a whole (delta) database. The chunked stream's end (CompleteStream)
-- and a library message (LibSync.Receive) both land here.
function LibSync.Apply(peer, buffer)
    -- A complete, decodable payload arrived — stop the stall-watch for this peer.
    ClearSyncWatch(peer)

    -- Dispatch
    if buffer:sub(1, 5) == MSG_CHAR .. "\n" then
        local charPayload = buffer:sub(6)
        local c = DeserializeChar(charPayload)
        if c then
            Print(peer .. " sent character data for " .. (c.name or "unknown") .. ".")
            ReceiveCharacter(c, peer)
        end
    else
        Print("Receiving data from " .. peer .. "...")
        local before = 0
        for _ in pairs(AltStableDB) do before = before + 1 end
        local maxTS, peerNow = DeserializeFullDB(buffer, peer)
        -- Advance our delta watermark for this peer so the next request only
        -- pulls what changes after this point.
        AdvancePeerWatermark(peer, maxTS, peerNow)
        local after = 0
        for _ in pairs(AltStableDB) do after = after + 1 end
        local newChars = after - before
        if newChars > 0 then
            Print("Sync with " .. peer .. " complete. " .. after .. " characters known (" .. newChars .. " new).")
        else
            Print("Sync with " .. peer .. " complete. " .. after .. " characters known.")
        end
    end

    -- Success — clear the retry budget.
    if autoRetryCounts then autoRetryCounts[AuthKey(peer) or peer] = nil end
end

local function CompleteStream(peer, bkey)
    local buf = incomingBuffers[bkey]
    if not buf then return end
    -- Over, whichever way this ends. Its id is not remembered: a whisper
    -- stream is ordered, so there are no stragglers to drop - and a client
    -- that restarts its stream ids on /reload would have a new stream taken
    -- for a late one (review of #142).
    local function finish()
        incomingBuffers[bkey] = nil
    end

    -- No never check here (#58): every way in has just made one - the last
    -- chunk and a complete DONE in the handler; a settle can only end in
    -- RequestResync, which refuses a never itself and merges nothing.

    -- Completeness
    local missing = {}
    for i = 1, buf.total do
        if buf.chunks[i] == nil then missing[#missing + 1] = i end
    end
    if #missing > 0 then
        local detail
        if #missing <= 8 then
            detail = table.concat(missing, ",")
        else
            local head = {}
            for i = 1, 8 do head[i] = missing[i] end
            detail = table.concat(head, ",") .. ",… (+" .. (#missing - 8) .. " more)"
        end
        finish()
        RequestResync(peer, #missing .. "/" .. buf.total .. " chunks missing (" .. detail .. ").", buf.transport)
        return
    end

    -- Reassemble in order, verify the checksum over the encoded stream, then
    -- decode + decompress back into the original payload.
    local ordered = {}
    for i = 1, buf.total do ordered[i] = buf.chunks[i] end
    local encoded = table.concat(ordered)

    local remoteChecksum = buf.checksum
    if remoteChecksum and remoteChecksum ~= "" then
        local localChecksum = ComputeChecksum(encoded)
        if localChecksum ~= remoteChecksum then
            Print("|cffff0000Checksum mismatch|r from " .. peer ..
                  " (expected " .. remoteChecksum .. ", got " .. localChecksum .. ").")
            finish()
            RequestResync(peer, "checksum mismatch.", buf.transport)
            return
        end
    end

    local buffer
    if LibDeflate then
        local decoded = LibDeflate:DecodeForWoWAddonChannel(encoded)
        buffer = decoded and LibDeflate:DecompressDeflate(decoded)
    else
        buffer = encoded
    end
    if not buffer then
        Print("|cffff0000Sync data from " .. peer .. " could not be decompressed|r; discarded.")
        finish()
        RequestResync(peer, "undecodable data.", buf.transport)
        return
    end

    LibSync.Apply(peer, buffer)
    finish()
end

-- A DB8 from our own account over the library: one whole payload, admitted
-- the way a whisper stream's first packet is - refused for good, or not
-- approved and not asked for, and it is dropped unread (MayAdmit refuses a
-- never; NoteRefusedStream says nothing to one). One difference: a stream
-- admitted at its first packet may finish after the consent window closes;
-- this payload is judged once, as it arrives, whole.
function LibSync.Receive(peer, deflated)
    if not MayAdmit(peer) then
        NoteRefusedStream(peer)
        return
    end
    NoteSyncActivity(peer)
    local buffer = LibDeflate and LibDeflate:DecompressDeflate(deflated or "")
    if not buffer then
        Print("|cffff0000Sync data from " .. peer .. " could not be decompressed|r; discarded.")
        RequestResync(peer, "undecodable data.", "BNET")
        return
    end
    LibSync.Apply(peer, buffer)
end

-- Every chunk present, with the DONE seen?
local function StreamReady(buf)
    if not buf.doneSeen or not buf.total or buf.total <= 0 then return false end
    for i = 1, buf.total do
        if buf.chunks[i] == nil then return false end
    end
    return true
end

-- A DONE arrived with chunks still missing: finalize once the stream goes
-- QUIET, not at a fixed moment. Each check compares the buffer's packet count
-- with the one it was scheduled at - any arrival since means "still coming",
-- so it waits again - and only acts on the very buffer it was made for, so a
-- replaced stream is never finalized by an old timer (#58, Codex).
local function ScheduleSettle(peer, bkey, buf)
    if buf.settling then return end
    buf.settling = true
    local wait = CHUNK_DONE_GRACE
    -- The count is taken when the check is SCHEDULED: read when it fires, it
    -- always matched, and a stream still arriving was finalized as missing.
    local check
    local function later()
        local seen = buf.touches
        C_Timer.After(wait, function() check(seen) end)
    end
    function check(seen)
        if incomingBuffers[bkey] ~= buf then return end
        if buf.touches ~= seen then later(); return end
        CompleteStream(peer, bkey)
    end
    later()
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------

------------------------------------------------------------
-- Saved raid lockouts (P2)
--
-- Snapshot weekly raid saved-instances into flat, syncable
-- si_<name>@<difficulty> fields on the character record, so the Instances
-- plugin can render a cross-alt matrix. Value is a packed
-- "expiresAt|progress|total|maxPlayers|difficultyName" string. Absolute
-- expiry (rounded to the minute) means every client computes "resets in …"
-- locally and re-scans don't churn the delta sync. Raids only — the 5/hour
-- dungeon cap is deferred (see issue #20).
------------------------------------------------------------
local function ScanSavedInstances()
    local guid = UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    if not char or not GetNumSavedInstances or not GetSavedInstanceInfo then return end

    local now = time()
    local newSet = {}
    for i = 1, GetNumSavedInstances() do
        local name, _, reset, difficulty, locked, extended, _, isRaid,
              maxPlayers, difficultyName, numEncounters, encounterProgress = GetSavedInstanceInfo(i)
        -- Raids only. isRaid isn't always reliable on 2.5.5, so also accept any
        -- lockout with more than 5 max players (excludes 5-man heroics either way).
        local raidish = isRaid or (maxPlayers and maxPlayers > 5)
        if name and raidish and (locked or extended) and reset and reset > 0 then
            -- Round to the minute: a later re-scan reports the same reset moment
            -- via a smaller `reset`, so now+reset is stable and won't re-bump.
            local expiresAt = math.floor((now + reset) / 60) * 60
            local diff = tostring(difficulty or 0)
            local key = "si_" .. name .. "@" .. diff
            newSet[key] = expiresAt .. "|" .. (encounterProgress or 0) .. "|"
                       .. (numEncounters or 0) .. "|" .. (maxPlayers or 0) .. "|" .. (difficultyName or "")

            -- Per-boss kill state as a positional bitmask (bit e-1 set = encounter e
            -- dead). NOTHING READS IT YET: a named Killed / Not-killed list needs the
            -- encounter ORDER to match a static boss list, and no raid lockout is
            -- obtainable on the beta to check that (#17), so the Raids plugin shows
            -- aggregate progress only. Captured now so the data exists the day it can
            -- be verified.
            -- Stored as a SEPARATE si_boss_<name>@<diff> field, NOT appended to the
            -- si_ value: the "si_boss_" prefix still matches the existing "^si_"
            -- serialize / clear / orphan-drop rules, so it syncs, gets cleaned up on
            -- expiry, and old clients can't resurrect a stale mask — while
            -- parseLockout rejects it (the value has no pipes), so no protocol bump is
            -- needed. Boss NAMES are not synced either way. Routed through newSet like
            -- every other field so the diff below flags `changed` and the delta sync
            -- picks it up.
            if type(GetSavedInstanceEncounterInfo) == "function"
               and numEncounters and numEncounters > 0 then
                local mask = 0
                for e = 1, numEncounters do
                    local _, _, isKilled = GetSavedInstanceEncounterInfo(i, e)
                    if isKilled then mask = mask + 2 ^ (e - 1) end
                end
                if mask > 0 then
                    newSet["si_boss_" .. name .. "@" .. diff] = tostring(mask)
                end
            end
        end
    end

    local changed = false
    for k in pairs(char) do
        if type(k) == "string" and k:find("^si_") and newSet[k] == nil then
            char[k] = nil; changed = true            -- lockout expired / no longer saved
        end
    end
    for k, v in pairs(newSet) do
        if char[k] ~= v then char[k] = v; changed = true end
    end
    if changed then
        char.lastUpdate = time()
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
end
AltStable.ScanSavedInstances = ScanSavedInstances
-- Ask the server to (re)populate saved-instance info; the reply fires
-- UPDATE_INSTANCE_INFO, which runs ScanSavedInstances. Cheap to call on login
-- and when the sheet opens.
AltStable.RequestLockouts = function() if RequestRaidInfo then RequestRaidInfo() end end

------------------------------------------------------------
-- Mail with expiry (P2)
--
-- Mail is only readable while a mailbox is open, so we scan on
-- MAIL_INBOX_UPDATE and snapshot a tiny synced summary onto the character
-- record: how many mails carry something to lose (items or money), the
-- soonest expiry, and the total money. `daysLeft` from GetInboxHeaderInfo
-- gives the client's own remaining lifetime, so we don't have to model the
-- 30-day / 3-day (returned/COD) rules ourselves. Expiry is stored absolute
-- and rounded to the minute — same trick as lockouts: a later re-scan reports
-- the same moment via a smaller daysLeft, so now+daysLeft is stable and won't
-- churn the delta sync every time a mailbox is opened.
--
-- Caveat: data is only as fresh as each alt's last mailbox visit — inherent
-- to the API (there's no background mail poll). CheckMailAlerts is login-only.
------------------------------------------------------------
local MAIL_ALERT_DAYS = 7   -- warn on login about mail expiring within this window

local function ScanMail()
    local guid = UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    if not char or not GetInboxNumItems or not GetInboxHeaderInfo then return end

    local now = time()
    local count, money, soonest = 0, 0, nil
    for i = 1, GetInboxNumItems() do
        local _, _, _, _, mMoney, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        -- Only mail with something to lose (attachments or gold) is worth tracking.
        local hasStuff = (itemCount and itemCount > 0) or (mMoney and mMoney > 0)
        if hasStuff and daysLeft and daysLeft > 0 then
            count = count + 1
            money = money + (mMoney or 0)
            local expiresAt = math.floor((now + daysLeft * 86400) / 60) * 60
            if not soonest or expiresAt < soonest then soonest = expiresAt end
        end
    end

    local changed = false
    local function set(k, v)
        if char[k] ~= v then char[k] = v; changed = true end
    end
    if count > 0 then
        set("mail_count",  count)
        set("mail_expiry", soonest)
        set("mail_money",  money)
    else
        for _, k in ipairs({ "mail_count", "mail_expiry", "mail_money" }) do
            if char[k] ~= nil then char[k] = nil; changed = true end
        end
    end
    if changed then
        char.lastUpdate = time()
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
    end
end
AltStable.ScanMail = ScanMail

-- Login notification: one line per alt whose mail expires within
-- MAIL_ALERT_DAYS, soonest first. Reads persisted/synced data (no mailbox
-- needed) and is gated by AltStableConfig.mailAlertsEnabled.
local function CheckMailAlerts()
    if not AltStableConfig or AltStableConfig.mailAlertsEnabled == false then return end
    if not AltStableDB then return end

    local now = time()
    local threshold = now + MAIL_ALERT_DAYS * 86400
    local alerts = {}
    for _, c in pairs(AltStableDB) do
        local exp = tonumber(c.mail_expiry)
        if exp and exp > now and exp <= threshold then
            alerts[#alerts + 1] = { name = c.name or "?", class = c.class,
                                    exp = exp, count = tonumber(c.mail_count) or 0 }
        end
    end
    if #alerts == 0 then return end
    table.sort(alerts, function(a, b) return a.exp < b.exp end)

    Print("|cffffcc00Mail expiring soon:|r")
    for _, a in ipairs(alerts) do
        local left = a.exp - now
        local when
        if left >= 86400 then
            when = math.floor(left / 86400) .. "d"
        elseif left >= 3600 then
            when = math.floor(left / 3600) .. "h"
        else
            when = math.max(1, math.floor(left / 60)) .. "m"
        end
        local color = (AltStable.ClassColor and AltStable.ClassColor(a.class)) or "|cffffffff"
        Print(string.format("  %s%s|r — %d mail, expires in %s",
            color, a.name, a.count, when))
    end
end
AltStable.CheckMailAlerts = CheckMailAlerts

local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("UNIT_PET")               -- a pet came out: record it for the Roster scene (#75)
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_UPDATE_RESTING")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("UPDATE_INSTANCE_INFO")   -- saved raid lockouts
frame:RegisterEvent("MAIL_INBOX_UPDATE")      -- mail with expiry
frame:RegisterEvent("CHAT_MSG_SYSTEM")    -- detect peer "X has come online" notifications
-- Battle.net presence changes that may mean our own other account came or
-- went (#58): the library carries the data, these only trigger a rescan.
-- Registered through pcall: an event this client does not know must not stop
-- the addon loading.
-- (Not BN_FRIEND_INFO_CHANGED: every friend's status change fires it, and none
-- of them changes which of OUR accounts are online.)
for _, ev in ipairs({ "BN_CONNECTED", "BN_DISCONNECTED", "BN_INFO_CHANGED" }) do
    pcall(frame.RegisterEvent, frame, ev)
end

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
------------------------------------------------------------
-- One addon message, from whichever transport carried it (#58). The whisper
-- path calls this from CHAT_MSG_ADDON; a request from our own other account
-- over the library calls it from LibSync.OnMessage, with the sender's
-- character name, so authorization and replies treat both alike.
--   transport  "WHISPER" (a real addon whisper) or "BNET" (the library)
------------------------------------------------------------
local function HandleAddonMessage(prefix, message, channel, sender, transport)
    transport = transport or "WHISPER"

    if prefix ~= PREFIX then
        return
    end

    ----------------------------------------------------
    -- Ignore our own packets
    ----------------------------------------------------

    -- The sender arrives as "First Surname", and cross-realm as
    -- "First Surname-Realm"; strip the realm suffix before comparing.
    -- PLAYER_NAME has to carry the surname for this to match - while it
    -- did not, we accepted and processed our own broadcasts.
    --
    -- Names are unique across the region on Forever, so our name with any
    -- realm suffix is us.
    local senderName = sender and sender:match("^([^%-]+)") or ""
    if senderName == PLAYER_NAME then
        return
    end
    -- The name as it arrived, realm and all. senderName is the realm-less
    -- form the routing and buffer keys have always used; authorization
    -- needs the full identity, because two realms can hold the same name
    -- and only one of them may have been approved (#61).
    local senderFull = sender or senderName

    local cmd, payload = strsplit("|", message, 2)

    -- Versioned request — only reply to clients running the same protocol
    if cmd == MSG_REQUEST_V then
        -- payload is the requester's delta watermark (0 / absent => full DB).
        local sinceTS = tonumber(payload) or 0
        local mode = SyncAuthFor(senderFull)

        if mode == AUTH_NEVER then
            -- Silently. They were told once, when the answer was given.
            return
        end

        -- Approved for good, or named by us in /alts sync moments ago.
        if MayServe(senderFull) then
            ServeSyncRequest(senderFull, sinceTS, transport)
            return
        end

        RememberPendingRequest(senderFull, sinceTS, transport)
        return
    end

    -- A request we cannot serve: any version but ours. Older and newer are
    -- reported differently, because only one of them is the user's to fix
    -- on the other machine.
    local reqVersion = CommandVersion(cmd, MSG_REQUEST)
    if reqVersion then
        if reqVersion < tonumber(PROTOCOL_VERSION) then
            Print("|cffff8800[AltStable]|r Ignoring sync request from "..senderName..
                  " (outdated addon version — update AltStable there).")
        else
            Print("|cffff8800[AltStable]|r Ignoring sync request from "..senderName..
                  " (newer addon version — update AltStable here).")
        end
        return
    end

    if cmd == MSG_CHAR and payload then

        -- MSG_CHAR is now sent as a chunked stream; this path is kept
        -- only for backward compatibility with older addon versions.
        -- The same admission as a stream: approved, or asked by us.
        if not MayAdmit(senderFull) then
            NoteRefusedStream(senderFull)
            return
        end

        local c = DeserializeChar(payload)

        if c then
            local senderShort = sender and sender:match("^([^%-]+)") or sender
            Print(senderShort .. " sent character data for " .. (c.name or "unknown") .. ".")
            ReceiveCharacter(c, senderShort)
        end

        return
    end

    -- Old chunk from a peer running an earlier protocol — discard.
    -- We can't safely reassemble a v3 (no seq) or v4 (raw bytes)
    -- chunk under the v5 codec, so we tell the user to update both
    -- ends and move on.  Logged once per sender per session to
    -- avoid spamming the chat frame on multi-chunk streams.
    local chunkVersion = CommandVersion(cmd, MSG_CHUNK)
    if chunkVersion and cmd ~= MSG_CHUNK_V then
        local key = sender and sender:match("^([^%-]+)") or sender
        outdatedSenders = outdatedSenders or {}
        if not outdatedSenders[key] then
            outdatedSenders[key] = true
            local which = (chunkVersion < tonumber(CHUNK_VERSION))
                and "outdated addon version" or "newer addon version"
            Print("|cffff8800[AltStable]|r Ignoring chunked sync from " .. key ..
                  " (" .. which .. " — please update AltStable on both ends).")
        end
        return
    end

    -- v7 sequenced chunk: "CHUNK5|<sid>|<seq>/<total>|<encoded-bytes>"
    -- The body is opaque compressed + addon-channel-encoded bytes; store it
    -- as-is and concatenate on completion (then checksum + decode +
    -- decompress). Out-of-order and repeated arrivals within a stream are
    -- handled (a repeat overwrites its slot; an out-of-order arrival lands
    -- at its real index); buffers are keyed per (sender, sid) so two
    -- concurrent or retried streams never clobber.
    if cmd == MSG_CHUNK_V then

        local peer = sender or "?"

        if not payload then return end
        local sidStr, seqStr, totalStr, body = payload:match("^(%d+)|(%d+)/(%d+)|(.*)$")
        if not sidStr then
            -- Malformed header — treat as drop, log and discard.
            Print("|cffff8800[AltStable]|r Malformed chunk from "..peer..", discarded.")
            return
        end
        local seq   = tonumber(seqStr)
        local total = tonumber(totalStr)
        if not seq or not total or seq < 1 or seq > total then
            Print("|cffff8800[AltStable]|r Out-of-range chunk seq from "..peer..", discarded.")
            return
        end

        -- Authorization (#61), BEFORE anything is stored or counted as
        -- activity. A peer refused for good loses whatever it had in
        -- flight. A new stream - the first packet seen for this sid, in
        -- whatever order the packets come - starts only if we approved
        -- the peer or asked it ourselves; once admitted, only a NEVER ends
        -- it.
        -- By peer KEY: "Name#3" and "Name-Realm#3" are one stream (#58).
        local bkey = (AuthKey(peer) or peer) .. "#" .. sidStr
        if SyncAuthFor(peer) == AUTH_NEVER then
            DropPeerStreams(peer)
            -- THIS stream too, which may have no buffer for the drop to
            -- mark: refused at its first packet by a never, it must stay
            -- refused if the peer is allowed while it is still arriving
            -- (Codex, review of #136).
            refusedStreams[bkey] = time()
            return
        end
        local buf = incomingBuffers[bkey]
        if not buf and (refusedStreams[bkey] or not MayAdmit(peer)) then
            refusedStreams[bkey] = time()
            NoteRefusedStream(peer)
            return
        end
        if not buf then
            -- total is fixed for the life of a stream (same sid), so it
            -- is only set at creation — never blindly overwritten by a
            -- later/stale packet.
            buf = { chunks = {}, total = total, lastTouched = time(),
                    transport = transport, touches = 0 }
            incomingBuffers[bkey] = buf
        else
            buf.lastTouched = time()
        end
        buf.chunks[seq] = body or ""
        buf.touches = (buf.touches or 0) + 1
        NoteSyncActivity(peer)   -- keep the sync-watch stall timer alive

        -- The DONE already came and this was the last missing piece.
        if StreamReady(buf) then CompleteStream(peer, bkey) end
        return
    end

    -- Versioned DONE — reassemble the buffer in seq order, verify
    -- completeness, then run the checksum.  Missing chunks are
    -- reported by index so the user / sender knows what got dropped.
    if cmd == MSG_DONE_V then

        local peer = sender or "?"
        local sidStr, remoteChecksum = (payload or ""):match("^(%d+)|(.*)$")
        if not sidStr then
            -- Malformed DONE (no stream id) — nothing to complete.
            return
        end
        local bkey = (AuthKey(peer) or peer) .. "#" .. sidStr
        if SyncAuthFor(peer) == AUTH_NEVER then
            DropPeerStreams(peer)
            refusedStreams[bkey] = time()
            return
        end
        local buf = incomingBuffers[bkey]

        -- No buffer: a stream that was refused, or is already over. A whisper
        -- stream is ordered, so its DONE never comes before its first chunk.
        if not buf then return end

        -- Stash the checksum so a deferred completion can still verify it.
        buf.checksum = remoteChecksum
        buf.doneSeen = true
        buf.touches = (buf.touches or 0) + 1

        if StreamReady(buf) then
            CompleteStream(peer, bkey)
        else
            -- A DONE can overtake in-flight chunks: finalize once the
            -- stream has gone quiet, not on a fixed clock.
            ScheduleSettle(peer, bkey, buf)
        end
        return
    end

    -- A DONE from any other version: drop whatever it was assembling and
    -- SAY so. Buffers are keyed "<peer>#<sid>", so the old code's
    -- incomingBuffers[shortName] never matched anything - the buffer was
    -- left to the 120-second sweep and the user got a "stalled" line, or
    -- silence, instead of a reason.
    local doneVersion = CommandVersion(cmd, MSG_DONE)
    if doneVersion then
        -- Buffers are keyed by the FULL sender plus the stream id
        -- ("Name-Realm#sid"); the chat line names the character. The old
        -- code looked up incomingBuffers[shortName], which never matched -
        -- so the data was left to the 120-second sweep in silence.
        local key = sender and sender:match("^([^%-]+)") or sender
        local dropped = false
        local skey = AuthKey(sender)
        for bkey in pairs(incomingBuffers) do
            if skey and bkey:match("^(.*)#%d+$") == skey then
                incomingBuffers[bkey] = nil
                dropped = true
            end
        end

        -- This stream is over, so end the watch on it. Without this the
        -- user got the right reason now and, 45 seconds later, "sync
        -- stalled - try /alts sync <name>" for something that cannot
        -- succeed: the contradictory advice this whole change exists to
        -- remove, one function call away from the fix.
        if sender then
            ClearSyncWatch(sender)
            autoRetryCounts = autoRetryCounts or {}
            autoRetryCounts[AuthKey(sender) or sender] = nil
        end

        local which = (doneVersion < tonumber(PROTOCOL_VERSION))
            and "outdated addon version" or "newer addon version"
        if dropped then
            Print("|cffff8800Warning:|r Discarded data from "..key.." ("..which..
                  " — please update AltStable).")
        else
            -- Nothing buffered: this peer's chunks were refused too, so it
            -- broadcasts one of these per update. Say it once per session,
            -- like the chunk path - the old code was silent here.
            outdatedSenders = outdatedSenders or {}
            if not outdatedSenders[key] then
                outdatedSenders[key] = true
                Print("|cffff8800[AltStable]|r Ignoring sync from "..key.." ("..which..").")
            end
        end
        return
    end

end

------------------------------------------------------------
-- The LibAccountSync instance (#198)
------------------------------------------------------------
-- The store is account-wide (AltStableConfig; Export.lua never touches it) and
-- holds the household key. Built on first use WITH the keys the legacy channel
-- shared, so two accounts that paired over it are paired here on day one,
-- without both presences having to be full once more:
--   * our bnetKey becomes the key, at keyAt 1 - older than any key the library
--     makes - so it wins the library's oldest-key choice, even where another
--     addon's store (GlassChat's) already holds one; that store keeps its own;
--   * each bnetTrusted key becomes trusted, seen now. Only `true` entries:
--     every one came from an account Battle.net verified as ours (the legacy
--     hello handler was the only writer).
-- Only keys of exactly 32 lowercase hex, the library's own rule; the legacy
-- channel accepted shorter ones. The library picks its key after PLAYER_LOGIN,
-- from every registered store - and this one registers at load, so the import
-- is always there first. Nothing writes bnetKey or bnetTrusted since the
-- legacy channel went (#206); they stay on disk for one release, so a
-- downgrade still reads them, and an install that skipped v0.11 still pairs.
function LibSync.Store()
    if type(AltStableConfig) ~= "table" then return nil end
    -- The library's own switch is store.enabled, read whenever nothing set it
    -- this session - and absent means ON. So it follows Battle.net sync from
    -- the moment the store exists, not from the first rescan after login:
    -- with sync off, the library never says a hello or scans at all.
    local on = AltStableConfig.bnetSync ~= false
    local t = AltStableConfig.accountSync
    if type(t) == "table" then
        if t.enabled ~= on then t.enabled = on end
        return t
    end
    -- Through the config seam; not loaded yet (Config.lua) means not yet.
    if not AltStable.SetConfigValue then return nil end
    local function valid(k) return type(k) == "string" and #k == 32 and k:match("^[0-9a-f]+$") ~= nil end
    t = { trusted = {}, enabled = on }
    local own = AltStableConfig.bnetKey
    if valid(own) then t.key, t.keyAt = own, 1 end
    local now = time()
    for k, v in pairs(type(AltStableConfig.bnetTrusted) == "table" and AltStableConfig.bnetTrusted or {}) do
        if v == true and valid(k) and k ~= own then t.trusted[k] = now end
    end
    AltStable.SetConfigValue("accountSync", t)
    return t
end

-- What came from our own account over the library. The sender is the
-- library's word (Blizzard's sender id, proven ours), never the message's.
function LibSync.OnMessage(payload, sender)
    if type(payload) ~= "string" or type(sender) ~= "table" then return end
    local name, guid = sender.name, sender.guid
    local key = AuthKey(name)
    if not key or type(guid) ~= "string" or not BNetEnabled() then return end
    -- An AltStable message, so they run it: from now on, the library to them.
    -- The realm name, when the library has none, is the database's for a
    -- character synced before.
    local before = LibSync.peers[key]
    local known = (AltStableDB or {})[guid]
    local realm = sender.realm or (type(known) == "table" and known.realm) or nil
    LibSync.peers[key] = { name = name, guid = guid, realm = realm, faction = sender.faction }
    -- Newly on the library: said once, and asked for their data - only while
    -- the library lists them as ours (a request opens our consent window for
    -- the reply). Refused for good: noticed, but neither announced nor asked.
    -- RequestCharacters keeps its own throttle and never-check.
    if not (before and before.guid == guid) and LibSync.Peer(name) then
        LibSync.seen[key] = true
        if SyncAuthFor(name) ~= AUTH_NEVER then
            if not LibSync.announced[key] then
                LibSync.announced[key] = true
                Print("Found your other account: |cff88ff88" .. name .. "|r ("
                    .. tostring(sender.faction or "?") .. ", " .. tostring(realm or "?") .. ") - syncing.")
            end
            if RequestCharacters then RequestCharacters("BNET", name) end
        end
    end
    local cmd, body = payload:match("^([^|]*)|?(.*)$")
    if cmd == LibSync.MSG_CAP then
        -- A question is answered, every time it comes (they may have reloaded
        -- and forgotten us), but not more than every 5 s; only an answer the
        -- library took counts. An answer (CAP8|1) is not answered.
        local last = LibSync.answered[guid]
        if body == "" and (not last or (time() - last) >= 5)
            and LibSync.SendGuid(guid, LibSync.MSG_CAP .. "|1") then
            LibSync.answered[guid] = time()
        end
    elseif cmd == MSG_REQUEST_V then
        -- Every gate of the whisper path (never, consent, a pending request);
        -- the reply goes back as "BNET", which is the library to them now.
        HandleAddonMessage(PREFIX, payload, "WHISPER", name, "BNET")
    elseif cmd == LibSync.MSG_DB then
        LibSync.Receive(name, body)
    end
end

do
    local lib, minor
    if LibStub then lib, minor = LibStub:GetLibrary("LibAccountSync-1.0", true) end
    if lib and type(lib.New) == "function" then
        local ok, inst = pcall(lib.New, lib, {
            addon = "AltStable",
            store = LibSync.Store,
            -- Independent messages, not snapshots (LibAccountSync#18).
            messages = true,
            -- A whole database, deflated, is about 9 KB for 28 characters
            -- (measured, #198); the cap leaves room to grow.
            maxPayload = 32768,
            report = function(text, kind)
                if kind == "error" or kind == "warning" then Print(tostring(text)) end
            end,
        })
        if ok and type(inst) == "table" then
            LibSync.inst = inst
            -- Right after New: a message that completes with no handler is
            -- used up.
            if type(inst.OnMessage) == "function" then inst.OnMessage(LibSync.OnMessage) end
        end
    end
    LibSync.minor = minor
    -- The handshake again while someone is still unanswered: the library can
    -- prove an account at any moment, with no event of ours to notice it.
    -- Every 10 s, so a question it refused (no nonce yet) is asked again soon;
    -- one it took waits PING_EVERY.
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(10, function() LibSync.Ping() end) end
end

------------------------------------------------------------
-- Event handler
------------------------------------------------------------

frame:SetScript("OnEvent", function(self, event, ...)

    if event == "UPDATE_INSTANCE_INFO" then
        ScanSavedInstances()
        return
    end

    if event == "MAIL_INBOX_UPDATE" then
        ScanMail()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        -- Not (...): the event's 5th argument is the recipient's name, which
        -- would land in `transport` (review of #142).
        local prefix, message, channel, sender = ...
        HandleAddonMessage(prefix, message, channel, sender, "WHISPER")
        return
    end

    if event == "BN_DISCONNECTED" then
        LibSync.Forget()
        return
    end
    if event == "BN_CONNECTED" or event == "BN_INFO_CHANGED" then
        RequestBNetScan()
        return
    end

    --------------------------------------------------------
    -- Login sync
    --------------------------------------------------------

    if event == "PLAYER_LOGIN" then

        -- Report any adapter contract this client does not satisfy. Compat.lua
        -- collects them instead of throwing, so without this call a missing
        -- API surfaces as "attempt to call a nil value" from inside the scan -
        -- after the character is half-written, with nothing naming the
        -- contract that went missing. Nobody was calling it but the tests.
        if AltStable.API and AltStable.API.AssertCapabilities then
            AltStable.API.AssertCapabilities()
        end

        PurgeRetiredFields()

        -- Re-register the prefix on login.  Calling it at file load
        -- time isn't always sufficient — same-machine dual-boxing has
        -- racy behaviour where the prefix isn't actually registered
        -- with the server until the client is in-world, so until we
        -- get this call to succeed at login time some early CHAT_MSG_ADDON
        -- traffic was being silently dropped on the receiver side.
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

        -- Refresh our own name now that we're in-world; UnitName("player") can
        -- return nil at file-load, and a nil PLAYER_NAME would silently defeat
        -- the self-echo suppression check for the whole session.
        PLAYER_NAME = AltStable.API.PlayerFullName() or PLAYER_NAME

        -- Stored sync answers keyed with our realm fold into the bare key, now
        -- that the realm is known (#61; never wins a clash).
        MigrateSyncAuthKeys()

        -- Look for our other accounts on Battle.net once the client has
        -- settled, then every minute (#58).
        C_Timer.After(5, ScanOwnAccounts)
        if not AltStable._bnetTicker and C_Timer.NewTicker then
            AltStable._bnetTicker = C_Timer.NewTicker(60, ScanOwnAccounts)
        end

        -- Load the on-demand plugins the user has enabled. Done early (not
        -- inside the 2s sync timer) so the Recipes/Roster tabs appear as
        -- soon as the sheet is built. Each plugin's BootstrapPlugin sees
        -- IsLoggedIn()==true and registers itself immediately.
        if AltStable.LoadEnabledPlugins then
            AltStable.LoadEnabledPlugins()
        end

        C_Timer.After(2, function()

            if AltStable.ScanCharacter then
                AltStable.ScanCharacter()
            end

            -- Populate weekly raid lockouts (reply fires UPDATE_INSTANCE_INFO).
            if RequestRaidInfo then RequestRaidInfo() end

            local targets = GetSyncTargets()
            if #targets > 0 then
                -- Pull-only model: ASK peers for their data rather than
                -- blindly pushing.  Pushing on login created a same-machine
                -- race where two clients started transmitting before
                -- either receiver was primed; the requester-initiated
                -- model guarantees the requester is listening when the
                -- response arrives.
                --
                -- Caveat: this only works when the peer is online at the
                -- moment we request.  If they aren't, our REQ goes
                -- nowhere — that's why CHAT_MSG_SYSTEM also fires a
                -- re-request when a peer comes online later.
                local pinged = BroadcastRequest()
                if #pinged > 0 then
                    Print("Requesting data from: " .. table.concat(pinged, ", "))
                    Print("|cff888888Data may lag while other addons finish loading — you'll get a line per peer as each completes.|r")
                end
            end

        end)

        -- Mail-expiry warnings, a beat after the sync banner so they land
        -- below the login noise. Reads persisted/synced data — no mailbox needed.
        C_Timer.After(4, function()
            if AltStable.CheckMailAlerts then AltStable.CheckMailAlerts() end
        end)

    end

    --------------------------------------------------------
    -- Peer-online re-request
    --
    -- Fixes the worst failure mode of pull-only login sync:
    -- if Memphisto logs in before Drakuzo, Memphisto's REQ at
    -- PLAYER_LOGIN goes nowhere (Drakuzo isn't listening yet),
    -- and Memphisto would never re-attempt — leaving Memphisto
    -- with stale data forever.
    --
    -- When the server tells us a friend/guildie has come online,
    -- we check if they're in our whitelist and, if so, fire a
    -- fresh REQ at them.  The throttle in RequestCharacters
    -- prevents this from double-firing if PLAYER_LOGIN's REQ
    -- happens to also be in flight.
    --
    -- Player-name extraction works off the |Hplayer:NAME|h
    -- hyperlink embedded in the system message, which is
    -- locale-independent.  We don't try to match the English
    -- "has come online" text — that breaks on non-English
    -- clients.
    --------------------------------------------------------

    if event == "CHAT_MSG_SYSTEM" then
        local text = ...
        if not text or type(text) ~= "string" then return end

        -- "No player named X" answering our own whisper: remember it, and say
        -- so once if the player asked for this sync by hand. The chat filter
        -- has hidden the server's own copies.
        local lostName, lostKey = OurEcho(text)
        if lostName then
            NoteUnreachable(lostName, lostKey)
            return
        end

        -- "X has come online" notifications carry a player link.
        -- "X has gone offline" also carries one — guard against the
        -- gone-offline case so we don't fire a REQ at someone who
        -- just left.  Both messages are sourced from
        -- ERR_FRIEND_ONLINE_SS / ERR_FRIEND_OFFLINE_S in the WoW
        -- globals; the offline string contains "offline" in every
        -- locale (Blizzard reuses the English root in localized
        -- forms in most locales — but as a safety net we also check
        -- ERR_FRIEND_OFFLINE_S literal substring presence).
        local offlineFmt = ERR_FRIEND_OFFLINE_S or ""
        local offlineMarker = offlineFmt:gsub("%%s", ""):gsub("[%[%]%(%)%.%%%+%-%*%?%^%$]", ""):match("(%S[%S%s]*%S)") or "offline"
        if offlineMarker ~= "" and text:find(offlineMarker, 1, true) then
            return
        end

        local peerName = text:match("|Hplayer:([^:|]+)")
        if not peerName then return end

        AltStableConfig = AltStableConfig or {}
        local whitelist = AltStableConfig.whitelist or {}
        -- The system message only carries the realm-less name, but whitelist
        -- entries may be "Name-Realm". Match on the realm-less part, and
        -- whisper the FULL whitelist entry so cross-realm routing works.
        local matched = nil
        for _, w in ipairs(whitelist) do
            local wShort = w:match("^([^%-]+)") or w
            if w == peerName or wShort == peerName then matched = w; break end
        end
        if not matched then return end

        -- Slight delay so the peer's CHAT_MSG_ADDON handler is fully
        -- primed before we fire — same reasoning as the 2s delay at
        -- PLAYER_LOGIN.
        C_Timer.After(3, function()
            local sent = RequestCharacters("WHISPER", matched)
            if sent then
                Print(matched .. " came online — requesting data.")
            end
        end)
        return
    end
    -- (e.g. looting, selling, buying, mailing).  A full ScanCharacter
    -- is not needed — just overwrite the money field directly.
    --------------------------------------------------------

    if event == "PLAYER_MONEY" then
        local guid = UnitGUID("player")
        if guid and AltStableDB[guid] then
            -- Through the adapter: GetMoney is one of the APIs measured
            -- returning a secret value, and the refresh below adds money up
            -- across characters - arithmetic that would throw and take the
            -- whole sheet build with it (see "Secret values" in Compat.lua).
            local money = AltStable.API.PlainNumber(GetMoney())
            if money ~= nil then
                AltStableDB[guid].money = money
                if AltStable.RefreshSheet then AltStable.RefreshSheet() end
            end
        end
        return
    end

    --------------------------------------------------------
    -- Rested-XP snapshot refresh
    --
    -- We re-snapshot whenever the player enters or leaves a rested
    -- (inn/city) area, and whenever XP changes (which catches rested
    -- being consumed during play).  We deliberately DO NOT refresh on
    -- PLAYER_LOGOUT — by the time it fires the player frame is being
    -- torn down and GetXPExhaustion() / IsResting() frequently return
    -- bogus zero values, which was previously overwriting good data
    -- with garbage just before SavedVariables were written.
    --
    -- Guarded reads: if GetXPExhaustion returns 0 while the player is
    -- below cap AND the stored snapshot was non-zero AND very recent
    -- (<5s ago), we treat the 0 as transient (likely fired during a
    -- loading transition) and skip the write.
    --------------------------------------------------------

    if event == "PLAYER_UPDATE_RESTING" or event == "PLAYER_XP_UPDATE" then
        local guid = UnitGUID("player")
        local char = guid and AltStableDB[guid]
        if char then
            -- Same adapter as the scan: these fire on every XP tick, so a
            -- secret here would error constantly rather than once.
            local liveRest = AltStable.API.PlainNumber(GetXPExhaustion())
            local liveMax  = AltStable.API.PlainNumber(UnitXPMax("player")) or 0
            local lvl      = AltStable.API.PlainNumber(UnitLevel("player")) or 0
            if liveRest == nil then return end   -- unreadable: keep the snapshot
            local atCap    = lvl >= AltStable.API.LevelCap()

            -- Suspicious-zero guard.  Only accept a zero read if we have
            -- a prior non-zero snapshot that is very recent; a fresh zero
            -- between resting-state flips is legit, but a zero right on
            -- PLAYER_XP_UPDATE when rested was previously e.g. 40% is
            -- almost certainly a transient loading-screen read.
            local prevPct  = char.restPercent or 0
            local prevTime = char.restTimestamp or 0
            local elapsed  = time() - prevTime
            local suspicious = (liveRest == 0) and (prevPct > 5) and (elapsed < 5) and not atCap

            -- A zero maximum (0 is truthy, so `or 1` never caught it): at the cap
            -- there is no next level and the snapshot is zero; below it the read
            -- is bad and the last good snapshot stands. Same rule as the scan.
            if liveMax <= 0 then
                if atCap then
                    char.restXP, char.xpMax, char.restPercent = 0, 0, 0
                    char.restedArea    = IsResting and IsResting() or false
                    char.restTimestamp = time()
                end
            elseif not suspicious then
                char.restXP        = liveRest
                char.xpMax         = liveMax
                char.restPercent   = math.floor((liveRest / liveMax) * 100)
                char.restedArea    = IsResting and IsResting() or false
                char.restTimestamp = time()
            end
        end
        return
    end

    --------------------------------------------------------
    -- Rescan + resend when gear changes in-session
    --------------------------------------------------------

    -- UNIT_PET fires for every pet owner nearby; only our own matters.
    if event == "UNIT_PET" and (...) ~= "player" then return end

    -- A summoned pet (#75) rides the same debounced rescan as gear: the scan
    -- records it and stamps lastUpdate, so the next sync carries it. Dismissal
    -- fires this too and simply changes nothing - the last pet seen stays.
    if event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_PET" then
        -- Debounce: PLAYER_EQUIPMENT_CHANGED fires once per slot changed.
        -- Swapping weapons can fire it multiple times in quick succession.
        -- Cancel any pending scan/broadcast and restart the timer.
        if frame._equipTimer then
            frame._equipTimer:Cancel()
        end
        frame._equipTimer = C_Timer.NewTimer(3, function()
            frame._equipTimer = nil
            if AltStable.ScanCharacter then
                AltStable.ScanCharacter()
            end
            -- Refresh sheet locally but don't broadcast — gear data will
            -- sync on the next natural login or /alts command.
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        end)
    end

    --------------------------------------------------------
    -- Retry pending gear slots when item cache is populated
    --------------------------------------------------------

    if event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        if not success then return end

        -- Item lookups the Roster audit could not resolve - an id the client has
        -- never seen, which is what a peer syncs from a character whose gear we
        -- have never met. Checked BEFORE the gear-slot queue below, which is
        -- local-equipment-only and is nil entirely when nothing local is pending
        -- -- the early return on it used to drop these events on the floor, so a
        -- slot the audit could not read stayed unread until something else
        -- repainted the tab.
        -- RefreshSheet is enough: the Roster plugin hooks it and already
        -- coalesces bursts into one deferred repaint.
        local pendingAudit = AltStable.PendingAuditItems
        if pendingAudit and itemID and pendingAudit[itemID] then
            pendingAudit[itemID] = nil
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        end

        if not AltStable.PendingGearSlots then return end

        local anyResolved = false
        for slotKey, info in pairs(AltStable.PendingGearSlots) do
            local itemName, _, quality, ilvl, _, _, itemSubType = GetItemInfo(info.link)
            if ilvl then
                local char = AltStableDB[info.guid]
                -- The slot may have changed since the retry was queued; only write
                -- if it still holds the item we were waiting on.
                if char and char["gearlink_"..slotKey] == info.link then
                    char["gear_"..slotKey]  = ilvl
                    char["gearq_"..slotKey] = quality or 0
                    if itemName and itemName ~= "" then char["gearname_"..slotKey] = itemName end
                    char["gearsubtype_"..slotKey] = itemSubType or ""
                    -- Re-pack now that the item is cached: this is what turns an
                    -- unresolved "?" socket count into a real one.
                    if AltStable.RepackGearMod then
                        char["gearmod_"..slotKey] =
                            AltStable.RepackGearMod(info.link, char["gearid_"..slotKey])
                    end
                    anyResolved = true
                end
                AltStable.PendingGearSlots[slotKey] = nil
            end
        end

        -- Stamp lastUpdate once all pending slots resolve, but don't broadcast.
        -- The updated gear will go out on the next login sync.
        if anyResolved and not next(AltStable.PendingGearSlots) then
            local guid = UnitGUID("player")
            local char = guid and AltStableDB[guid]
            if char then char.lastUpdate = time() end
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        end
    end

end)

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------

------------------------------------------------------------
-- Plugin registration API
-- Other addons can register themselves as AltStable plugins.
-- Each plugin is a table with the following fields:
--   id         (string)   unique identifier, used as the sidebar button key
--   label      (string)   sidebar button label
--   icon       (string)   path to a texture shown on the sidebar button
--   OnActivate (function) called when the user clicks this plugin's sidebar button;
--                         receives the AltStable main frame as the first argument
--   OnDeactivate (function, optional) called when another section/plugin is selected
------------------------------------------------------------

AltStable.plugins = AltStable.plugins or {}

------------------------------------------------------------
-- On-demand plugin loading
--
-- Recipes and Roster ship as LoadOnDemand addons (they don't auto-load
-- at startup). AltStable loads the ones the user enabled, and the
-- Options panel toggles them. Enabling loads immediately; disabling
-- only persists (WoW can't unload an addon until the next /reload).
------------------------------------------------------------

-- Each ported plugin adds its entry. Listing an addon that does not exist
-- means a failed LoadAddOn at every login, which would bury the real errors
-- this build exists to surface.
AltStable.LOD_PLUGINS = {
    { key = "warband", addon = "AltStableWarband", label = "Warband" },
    { key = "instances", addon = "AltStableInstances", label = "Raids" },
    { key = "roster", addon = "AltStableRoster", label = "Roster" },
    { key = "professions", addon = "AltStableProfessions", label = "Professions" },
}

-- Client-compat wrappers: the classic globals exist in 2.5.5, but fall
-- back to the C_AddOns namespace if a future client drops them.
local function IsPluginLoaded(addon)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(addon) end
    return IsAddOnLoaded and IsAddOnLoaded(addon)
end

local function LoadPluginAddon(addon)
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if not loader then return false, "no loader" end
    -- Skip an addon the client has never heard of, and pcall the rest. This
    -- runs from the PLAYER_LOGIN handler, and on Retail LoadAddOn can raise
    -- rather than return nil for an unknown name - which would abort login
    -- before the scan and sync are ever scheduled.
    if C_AddOns and C_AddOns.GetAddOnInfo and not C_AddOns.GetAddOnInfo(addon) then
        return false, "not installed"
    end
    local ok, a, b = pcall(loader, addon)
    if not ok then return false, tostring(a) end
    return a, b
end

function AltStable.IsPluginEnabled(key)
    return not (AltStableConfig and AltStableConfig.plugins
                and AltStableConfig.plugins[key] == false)
end

-- Load every enabled plugin that isn't already loaded. Called at login.
function AltStable.LoadEnabledPlugins()
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.plugins = AltStableConfig.plugins or {}
    for _, p in ipairs(AltStable.LOD_PLUGINS) do
        if AltStable.IsPluginEnabled(p.key) and not IsPluginLoaded(p.addon) then
            local ok, err = LoadPluginAddon(p.addon)
            if not ok then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff00ccff[AltStable]|r could not load "..p.label.." ("..p.addon.."): "..tostring(err))
            end
        end
    end
end

-- Toggle a plugin from the Options panel. Persists the choice; enabling
-- loads the addon on the spot (its BootstrapPlugin registers the tab live).
function AltStable.SetPluginEnabled(key, enabled)
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.plugins = AltStableConfig.plugins or {}
    AltStableConfig.plugins[key] = enabled and true or false
    AltStable.OnConfigChanged("plugins")
    if enabled then
        for _, p in ipairs(AltStable.LOD_PLUGINS) do
            if p.key == key and not IsPluginLoaded(p.addon) then
                local ok, err = LoadPluginAddon(p.addon)
                if not ok then
                    DEFAULT_CHAT_FRAME:AddMessage(
                        "|cff00ccff[AltStable]|r could not load "..p.label.." ("..p.addon.."): "..tostring(err))
                elseif AltStable.ResetPeerWatermarks then
                    -- Switched on after sessions without it: its store may hold
                    -- old data, and the peers' watermarks are ahead of what it
                    -- never received, so a delta would never backfill it. One
                    -- full pull, for any plugin that syncs (review of #132).
                    AltStable.ResetPeerWatermarks()
                end
            end
        end
    end
end

function AltStable.RegisterPlugin(plugin)
    if not plugin or not plugin.id or not plugin.label or not plugin.OnActivate then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r RegisterPlugin: missing required fields (id, label, OnActivate).")
        return
    end
    -- Prevent duplicate registration across reloads
    for _, p in ipairs(AltStable.plugins) do
        if p.id == plugin.id then return end
    end
    table.insert(AltStable.plugins, plugin)
    -- If the sheet is already built, notify it so it can add the button live
    if AltStable.AddPluginButton then
        AltStable.AddPluginButton(plugin)
    end
end

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------

-- Where Roster portraits come from, in the one phrase every hint uses: both
-- Roster hints and the sheet's capture button used to word it themselves, and
-- drifted (#89). The capture itself is Capture.lua; the matte that turns a
-- capture into a portrait happens outside the game, because an addon can
-- neither write an image nor read the Screenshots folder.
--
-- It names the app (#176): "the converter on the project page" sent players
-- looking for something with no name. Every hint that uses it is clickable and
-- opens ShowCompanionLink, hence the closing words.
function AltStable.PortraitSourceText()
    return "capture one with |cffffff00/alts portrait|r while playing the character; "
        .. "the free |cffffff00AltStable Companion|r app for Windows turns captures into portraits "
        .. "(click for the link)"
end

-- /releases, not /releases/latest: the Companion has only pre-releases, and
-- GitHub's "latest" skips those.
AltStable.COMPANION_URL = "https://github.com/Spotnick2/AltStableCompanion/releases"

-- The one thing the addon can tell about the Companion's folder (#176): its
-- manifest is a global the AltStableCutouts addon defines when the client
-- LOADED it. Captures on record with no manifest means either the Companion
-- has not run yet or it has and WoW has not been restarted since - a new addon
-- folder is only found at startup. The addon cannot tell which, so the line
-- is a condition, never a statement that the Companion ran.
function AltStable.PortraitRestartText()
    if AltStableCutoutManifest ~= nil then return nil end
    local renders = type(AltStablePortraits) == "table" and AltStablePortraits.renders
    if type(renders) ~= "table" or #renders == 0 then return nil end
    return "If AltStable Companion has made a portrait since your capture, quit and restart the game once: "
        .. "WoW only finds the Companion's new folder at startup."
end

-- A copyable download link. Addons cannot open a browser; a box with the text
-- selected is the usual way to hand one over. One line of text to copy: the
-- Companion's link (#176) and the /alts status line (#175). Our own prompt
-- (Prompt.lua), never the client's StaticPopup: showing one from addon code
-- taints the shared dialog pool (#199).
function AltStable.ShowCopyText(prompt, text)
    return AltStable.ShowPrompt("Copy", { text = prompt, copy = text or "" })
end

-- /alts status (#175): what a bug report needs, without asking. Read lines for
-- the chat and one line to copy. No account names, no character names: the
-- counts say enough, and the line ends up pasted in public.
--
-- "Portraits" are manifest entries for a tracked character, not verified
-- pictures: whether a file loads is not something the addon checks (Roster).
function AltStable.StatusLines()
    local get = AltStable.API and AltStable.API.GetAddOnMetadata
    local okV, version = pcall(function() return get and get("AltStable", "Version") end)
    version = (okV and type(version) == "string" and version ~= "") and version or "?"
    local clientVersion, build = "?", "?"
    if GetBuildInfo then clientVersion, build = GetBuildInfo() end
    local locale = GetLocale and GetLocale() or "?"

    local chars, withPortrait, enhanced = 0, 0, 0
    for _, c in pairs(type(AltStableDB) == "table" and AltStableDB or {}) do
        if type(c) == "table" and c.name then
            chars = chars + 1
            local entry = AltStable.CutoutFor and AltStable.CutoutFor(c)
            if entry then
                withPortrait = withPortrait + 1
                if type(entry.enhanced) == "table" then enhanced = enhanced + 1 end
            end
        end
    end
    local captures = 0
    local renders = type(AltStablePortraits) == "table" and AltStablePortraits.renders
    for _, r in ipairs(type(renders) == "table" and renders or {}) do
        if type(r) == "table" and r.shot == 1 then captures = captures + 1 end
    end
    local cutouts = AltStableCutoutManifest ~= nil

    local lines = {
        ("AltStable %s, client %s (%s), %s"):format(version, tostring(clientVersion), tostring(build), locale),
        ("%d characters tracked; %d with a portrait (%d enhanced)"):format(chars, withPortrait, enhanced),
        ("%d portrait captures on record; AltStable Companion's folder %s"):format(
            captures, cutouts and "is loaded" or "is not loaded"),
        ("sync protocol %s"):format(PROTOCOL_VERSION),
    }
    -- Semicolons, not "|": that is the escape character of WoW text.
    local copy = ("AltStable %s; client %s.%s %s; chars %d; portraits %d (enh %d); captures %d; cutouts %s; proto %s")
        :format(version, tostring(clientVersion), tostring(build), locale, chars, withPortrait, enhanced,
                captures, cutouts and "loaded" or "absent", PROTOCOL_VERSION)
    return lines, copy
end

-- The player's commands, for /alts help and for anything /alts does not know.
-- The developer-only ones (/asprobe, /apidump) are left out: they do not ship.
AltStable.HELP_LINES = {
    "|cffffff00/alts|r - open the sheet (and ask your other accounts for news)",
    "|cffffff00/alts portrait|r - capture this character for the Roster's portraits",
    "|cffffff00/alts status|r - versions and counts, to paste into a bug report",
    "|cffffff00/alts sync|r [name] - sync now, with everyone or one character",
    "|cffffff00/alts whitelist|r [remove] [name] - who you sync with",
    "|cffffff00/alts auth|r, |cffffff00allow|r / |cffffff00deny|r <name> - who may ask for your data",
    "|cffffff00/alts favourite|r / |cffffff00unfavourite|r <name> - pin to the top of the Roster grid",
    "|cffffff00/alts forget|r / |cffffff00unforget|r <name>, |cffffff00/alts forgotten|r - characters that no longer exist",
    "|cffffff00/alts account|r <n> - this account's number in the sheet",
    "|cffffff00/alts export|r - every character as a spreadsheet",
    "|cffffff00/alts config|r - options",
}

function AltStable.ShowCompanionLink()
    return AltStable.ShowCopyText(
        "AltStable Companion turns your portrait captures into the Roster's portraits. "
            .. "Copy the link (Ctrl+C) and open it in your browser:",
        AltStable.COMPANION_URL)
end

-- Split "<cmd> <target>" where the target may contain spaces.
--
-- Forever characters have a surname, so a name is two words: "Karuzo Elegia".
-- The old pattern captured the target as a single %S+ token and was anchored
-- at both ends, so a three-token line matched NEITHER that nor the one-token
-- fallback - cmd came back empty and the command silently did nothing.
function AltStable.ParseSlashArgs(args)
    args = tostring(args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, target = args:match("^(%S+)%s+(.+)$")
    if not cmd then
        cmd = args:match("^(%S+)$")
    end
    if target then
        target = target:gsub("^%s+", ""):gsub("%s+$", "")
        if target == "" then target = nil end
    end
    return (cmd and cmd:lower() or ""), target
end

SLASH_ALTSTABLE1 = "/alts"
SLASH_ALTSTABLE2 = "/altstable"

SlashCmdList["ALTSTABLE"] = function(args)

    local cmd, target = AltStable.ParseSlashArgs(args)

    ----------------------------------------------------
    -- /alts sync [PlayerName]
    --
    -- With a target: send our data to them AND request theirs back.
    -- Both directions, useful for forcing a fresh exchange.
    --
    -- Without a target: fire a REQ to every whitelisted peer.  This
    -- is the manual equivalent of what PLAYER_LOGIN does at startup
    -- and what CHAT_MSG_SYSTEM does on peer-online; we use `force`
    -- so the throttle doesn't suppress an explicit user-initiated
    -- request.
    ----------------------------------------------------

    ----------------------------------------------------
    -- /alts skin [flat|clear|smoked]
    --
    -- Applied on the NEXT LOAD, not now. Glass.Apply creates its regions every
    -- time it is called and has no teardown or update path, so switching in
    -- place would mean caching material instances, hiding every region,
    -- restoring the old fills and repainting the body - a lot of machinery for
    -- a setting changed once. Saying "reload" is the honest version.
    ----------------------------------------------------

    if cmd == "skin" then
        local names = {}
        for k in pairs(AltStable.SKINS or {}) do names[#names + 1] = k end
        table.sort(names)
        if not target or target == "" or not (AltStable.SKINS or {})[target] then
            Print("Skin is |cffffff00" .. AltStable.SkinName() .. "|r. Choose one of: "
                  .. table.concat(names, ", "))
            return
        end
        AltStable.SetConfigValue("skin", target)
        Print("Skin set to |cffffff00" .. target .. "|r - |cffffff00/reload|r to see it.")
        return
    end

    if cmd == "sync" then
        if not target or target == "" then
            local pinged, skipped = BroadcastRequest(true)
            if #pinged == 0 and #skipped == 0 then
                Print("Nobody to sync with: no other account of yours is online on Battle.net, "
                    .. "and nobody is whitelisted (|cffffff00/alts whitelist <name>|r for someone else).")
            elseif #pinged == 0 then
                Print("No requests sent (all whitelisted peers throttled).")
            else
                Print("Requesting data from: " .. table.concat(pinged, ", "))
            end
            return
        end
        if not AltStable.PeerKey(target) then
            Print("|cffff8800Not a name I can use:|r " .. tostring(target))
            return
        end
        -- Never to a peer refused for good (#61) - the push used to go out
        -- regardless of the answer.
        if AltStable.SyncAuthFor(target) == AltStable.AUTH_NEVER then
            Print("|cffff8800" .. target .. " is set to never|r - nothing was sent. "
                .. "|cffffff00/alts allow " .. target .. "|r first.")
            return
        end
        -- Typing the name is the consent, for this exchange: their answer may
        -- come in, and their own request back may be served, for ten minutes.
        -- Nothing is stored.
        AltStable.GrantSyncConsent(target, true, true)
        local key = AltStable.PeerKey(target)
        local attempt = {}
        syncAttempt[key] = attempt
        manualSyncAt[key] = time()
        unreachableToldAt[key] = nil
        Print("Requesting " .. target .. "'s data and sending yours...")
        -- The request FIRST: one small whisper, which tells us whether they can
        -- be reached at all. The push - dozens of whispers - follows only if the
        -- server did not answer "no player named" to it. Pushing first put one
        -- of those lines in chat per chunk for an offline or other-faction
        -- target.
        --
        -- The three seconds start when the request LEAVES, not when it is
        -- queued: ChatThrottleLib can hold even an ALERT (bandwidth, start-up
        -- or zoning throttle), and a window counted from the queueing could
        -- close before the server had anything to refuse - queueing the whole
        -- database behind a request that then fails (Codex, review of #137).
        -- A character found as our own account goes over Battle.net - the
        -- only way across factions and rulesets.
        local via = AltStable.SyncChannelFor and AltStable.SyncChannelFor(target) or "WHISPER"
        RequestCharacters(via, target, true, function(didSend)
            if not didSend then
                -- Refused at send (TargetOffline has said why already):
                -- the push is not queued behind a request that never went.
                if not attempt.unreachable then
                    Print("|cffff8800The request to " .. target .. " could not be sent|r - "
                        .. "nothing was pushed. Try again in a moment.")
                end
                return
            end
            C_Timer.After(3, function()
                -- A newer /alts sync to them owns the push now.
                if syncAttempt[key] ~= attempt or attempt.unreachable then return end
                syncAttempt[key] = nil
                -- Only while the exchange the player started is still on: a
                -- deny, or a deny and then a forget, in these seconds ends it.
                if not AltStable.MayServeSyncPeer(target) then return end
                SendFullDatabase(via, target)
            end)
        end)
        return
    end

    ----------------------------------------------------
    -- /alts whitelist                 — list the configured peers
    -- /alts whitelist <name>          — add one
    -- /alts whitelist remove <name>   — drop one
    --
    -- The Options panel has an editor too, but it draws a fixed five rows
    -- (OPT_WL_ROWS), so a sixth peer is only visible - and only removable -
    -- from here. This also exists because the "no whitelisted peers
    -- configured" message above tells people to use it.
    --
    -- "remove" is matched before the add branch, so a peer literally named
    -- Remove has to be added from the Options panel. Documenting that costs
    -- one line; a second keyword to disambiguate it would cost more.
    --
    -- Names go in exactly as typed: a Forever character is two words
    -- ("Karuzo Elegia") and a cross-realm peer keeps its "-Realm" suffix.
    -- ParseSlashArgs preserves both, and GetSyncTargets whispers the entry
    -- verbatim, so anything else would break routing.
    ----------------------------------------------------

    if cmd == "whitelist" then
        AltStableConfig = AltStableConfig or {}
        AltStableConfig.whitelist = AltStableConfig.whitelist or {}

        local rest = target and target:match("^[Rr][Ee][Mm][Oo][Vv][Ee]%s+(.+)$")
        if rest then
            if AltStable.RemoveFromWhitelist and AltStable.RemoveFromWhitelist(rest) then
                Print("Removed " .. rest .. " from the whitelist.")
            else
                Print(rest .. " is not on the whitelist.")
            end
        elseif target and target:lower() == "remove" then
            Print("Usage: /alts whitelist remove <name>")
        elseif target then
            if AltStable.AddToWhitelist and AltStable.AddToWhitelist(target) then
                Print("Added " .. target .. " to the whitelist.")
            else
                Print(target .. " is already on the whitelist.")
            end
        elseif #AltStableConfig.whitelist == 0 then
            Print("Whitelist is empty. Add a peer with /alts whitelist <name>.")
        else
            Print("Whitelisted peers: " .. table.concat(AltStableConfig.whitelist, ", "))
        end
        -- The Options panel rebuilds its rows on show, so an open panel is
        -- refreshed the next time it is opened; nothing to invalidate here.
        return
    end

    ----------------------------------------------------
    -- /alts account N  — set this client's account number
    ----------------------------------------------------

    -- Who may ask us for the database (#61).
    if cmd == "allow" or cmd == "deny" or cmd == "forget-peer" then
        if target == nil or target == "" then
            Print("usage: |cffffff00/alts " .. cmd .. " <character>|r")
            return
        end
        local fn = (cmd == "allow" and AltStable.AllowSyncPeer)
                or (cmd == "deny" and AltStable.DenySyncPeer)
                or AltStable.ForgetSyncPeer
        if not fn(target) then
            Print("|cffff8800Not a name I can use:|r " .. tostring(target))
        end
        return
    end

    -- What own-account sync sees, step by step (#58, #198): the switch, then
    -- the library's own account of itself and who answered on it. Script
    -- errors are off by default on this client, so this is how "nothing was
    -- found" gets explained in game.
    if cmd == "bnet" then
        Print(("Battle.net sync: setting %s, connected %s; last scan: %s"):format(
            AltStableConfig.bnetSync == false and "OFF" or "on",
            tostring(BNFeaturesEnabledAndConnected and BNFeaturesEnabledAndConnected()),
            AltStable._bnetLastScan and (time() - AltStable._bnetLastScan) .. " s ago" or "never"))
        local inst = LibSync.inst
        if not inst then
            Print("  LibAccountSync: not loaded - own-account sync is off; whitelisted characters still sync by whisper")
            return
        end
        Print(("  LibAccountSync MINOR %s, independent messages %s, SendTo %s"):format(
            tostring(LibSync.minor), inst.messages == true and "yes" or "NO (cannot sync)",
            type(inst.SendTo) == "function" and "yes" or "NO (cannot sync)"))
        local okD, iter = pcall(inst.Diagnostics)
        if okD and type(iter) == "function" then
            for line in iter do Print("    " .. tostring(line)) end
        end
        local on = {}
        for _, p in ipairs(AltStable.OwnBNetPeers()) do on[#on + 1] = p.name end
        Print("  on the library: " .. (#on > 0 and table.concat(on, ", ") or "nobody yet"))
        return
    end

    if cmd == "auth" then
        local list = AltStable.SyncAuthList()
        local waiting = AltStable.PendingSyncRequests()
        local own = {}
        for _, p in ipairs(AltStable.OwnBNetPeers()) do
            if AltStable.SyncAuthFor(p.name) ~= AltStable.AUTH_NEVER then own[#own + 1] = p end
        end
        for _, p in ipairs(own) do
            Print(("  %s  |cff88ff88your account (Battle.net)|r - %s, %s"):format(p.name,
                tostring(p.faction or "?"), tostring(p.realm or "?")))
        end
        if #list == 0 and #waiting == 0 and #own == 0 then
            Print("Nobody has asked yet, and no answers are stored. "
                .. "An unknown character asking for your database will be refused until you "
                .. "|cffffff00/alts allow|r them.")
            return
        end
        for _, e in ipairs(list) do
            Print(("  %s  |cff%s%s|r"):format(e.name,
                  e.mode == AltStable.AUTH_AUTO and "88ff88" or "ff8888", e.mode))
        end
        for _, e in ipairs(waiting) do
            Print(("  %s  |cffffff00waiting on you|r - /alts allow %s"):format(e.name, e.name))
        end
        return
    end

    -- Forget a character that no longer exists (#65).
    if cmd == "forget" or cmd == "unforget" then
        if target == nil or target == "" then
            Print("usage: |cffffff00/alts " .. cmd .. " <character>|r")
            return
        end

        if cmd == "unforget" then
            local guid, held = AltStable.ForgottenGuidFor(target)
            if not guid then
                Print(held or ("|cffff8800Not on the forgotten list:|r " .. target))
                return
            end
            AltStable.UnforgetCharacter(guid)
            Print("|cff88ff88" .. (held or target) .. "|r will be accepted from peers again, "
                .. "and every peer will be asked in full so it can actually come back. "
                .. "That takes one sync, not immediately.")
            return
        end

        local match, why = AltStable.ResolveCharacter(target)
        if not match then
            Print(why)
            return
        end

        local ok, info = AltStable.ForgetCharacter(match)
        if ok then
            Print("Forgotten |cffff8888" .. info .. "|r. The record is gone and peers offering "
                .. "it back will be ignored. |cffffff00/alts unforget " .. info .. "|r to undo.")
        else
            Print("|cffff8800Cannot forget that:|r " .. tostring(info))
        end
        return
    end

    if cmd == "forgotten" then
        local list = AltStable.ForgottenList()
        if #list == 0 then
            Print("Nothing forgotten. |cffffff00/alts forget <character>|r removes one for good.")
            return
        end
        for _, e in ipairs(list) do
            Print(("  %s  |cff888888(%s)|r"):format(e.name or "?", e.guid))
        end
        return
    end

    -- Pin a character to the top of the Roster grid (#66). Since #152 the scene
    -- shows camps, and favourites no longer seat it.
    if cmd == "favourite" or cmd == "favorite" or cmd == "unfavourite" or cmd == "unfavorite" then
        local on = (cmd == "favourite" or cmd == "favorite")

        if target == nil or target == "" then
            if not on then
                -- The verb that was typed, not the other one. The shared branch
                -- used to answer "unfavourite" with the help for adding.
                Print("usage: |cffffff00/alts " .. cmd .. " <character>|r")
                return
            end
            -- Listed from the CONFIG, not the database. A favourite whose
            -- record is gone - after /alts cleanup, or a peer not yet synced -
            -- is still pinned and comes back pinned, so reporting "no
            -- favourites" would hide the one entry the player cannot otherwise
            -- reach.
            local named = {}
            for guid in pairs((AltStableConfig or {}).favouriteCharacters or {}) do
                local c = (AltStableDB or {})[guid]
                named[#named + 1] = (type(c) == "table" and c.name)
                    or (guid .. " |cff888888(no record here)|r")
            end
            table.sort(named)
            if #named == 0 then
                Print("No favourites. |cffffff00/alts favourite <character>|r pins one to the "
                    .. "top of the Roster grid.")
            else
                Print("Favourites: |cff88ff88" .. table.concat(named, "|r, |cff88ff88") .. "|r")
            end
            return
        end

        local match, why = AltStable.ResolveCharacter(target)
        if not match then
            Print(why)
            return
        end

        AltStable.SetCharacterFavourite(match, on)
        local name = (AltStableDB[match] or {}).name or target
        if on then
            -- Hidden beats favourite, so saying "pinned to the top" of a list
            -- it does not appear in would be plainly untrue.
            if AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(match) then
                Print("|cff88ff88Pinned|r " .. name .. ", but it is hidden, so it still shows "
                    .. "nowhere. Unhide it in Options to see it.")
            else
                Print("|cff88ff88Pinned|r " .. name .. " to the top of the Roster.")
            end
        else
            Print("Unpinned " .. name .. ".")
        end
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        return
    end
    if cmd == "account" then
        if target == nil or target == "" then
            -- Bare "/alts account" answers the question people actually have,
            -- which is what it is set to now - not how to type it.
            local current = AltStable.GetAccountNumber()
            if current == nil then
                Print("No account number set. Set one with |cffffff00/alts account 1|r.")
            else
                Print("Account number is " .. tostring(current)
                      .. ". Change it with |cffffff00/alts account <n>|r, "
                      .. "or |cffffff00/alts account clear|r.")
            end
            return
        end

        local ok, msg = AltStable.SetAccountNumber(target)
        Print(msg)
        return
    end

    ----------------------------------------------------
    -- /alts export
    ----------------------------------------------------

    if cmd == "export" then
        if AltStable.ShowExport then
            AltStable.ShowExport()
        end
        return
    end

    ----------------------------------------------------
    -- /alts cleanup  — manually remove duplicate/corrupt DB entries
    ----------------------------------------------------

    if cmd == "cleanup" then
        CleanupDB()
        Print("DB wiped — kept only your current character. Requesting fresh data from peers...")
        if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        -- Give the rescan a moment to complete before broadcasting
        C_Timer.After(1, function()
            BroadcastDB()
            C_Timer.After(3, function()
                BroadcastRequest(true)   -- force: user just wiped DB, bypass throttle
            end)
        end)
        return
    end

    ----------------------------------------------------
    -- /alts config  — open the settings panel
    ----------------------------------------------------

    if cmd == "config" then
        if AltStable.OpenConfig then
            AltStable.OpenConfig()
        end
        return
    end

    ----------------------------------------------------
    -- /alts portrait [preview | facing <deg> | cancel]
    --
    -- The two-shot capture the Roster's portraits are matted from
    -- (Capture.lua). Replaces /alts update-reference, whose single plain
    -- screenshot fed the retired armory pipeline and nothing reads.
    ----------------------------------------------------

    if cmd == "portrait" then
        if AltStable.PortraitCommand then AltStable.PortraitCommand(target) end
        return
    end
    -- The retired name says where it went, rather than falling through to the
    -- bare /alts below, which opens the sheet and pings every peer for a sync.
    if cmd == "update-reference" or cmd == "updateref" then
        Print("|cffffff00/alts update-reference|r is now |cffffff00/alts portrait|r.")
        return
    end

    ----------------------------------------------------
    -- /alts help, /alts status (#175)
    --
    -- An unknown word used to fall through to the bare /alts below: it
    -- opened the sheet and pinged every peer, and never said the word meant
    -- nothing. Now it says so and lists what does.
    ----------------------------------------------------

    if cmd == "status" then
        local lines, copy = AltStable.StatusLines()
        for _, l in ipairs(lines) do Print(l) end
        AltStable.ShowCopyText("AltStable status - copy it (Ctrl+C) into your bug report:", copy)
        return
    end

    if cmd ~= "" then
        if cmd ~= "help" and cmd ~= "?" then
            Print(("|cffffff00%s|r is not an AltStable command. These are:"):format(cmd))
        end
        for _, l in ipairs(AltStable.HELP_LINES) do Print(l) end
        return
    end

    ----------------------------------------------------
    -- /alts  (open sheet + sync via configured mode)
    --
    -- Bare /alts opens the AltStable window and pings whitelisted
    -- peers for a fresh sync — but goes through the same throttle
    -- machinery, so spamming /alts won't carpet-bomb the network.
    -- Throttled peers get silently skipped here (no message), since
    -- the user just opened the UI and doesn't necessarily care that
    -- a recent sync is still being respected.
    ----------------------------------------------------

    if AltStable.EnsureSheetVisible then
        AltStable.EnsureSheetVisible()
    end

    local pinged = BroadcastRequest()
    if #pinged > 0 then
        Print("Requesting data from: " .. table.concat(pinged, ", "))
    end

end

------------------------------------------------------------
-- Test seam
--
-- Exposes the otherwise file-local sync/serialization internals so the
-- Lua unit tests in tests/ can exercise the wire protocol without a game
-- client. Harmless in-game — just a table of references to existing
-- functions/values. Not part of the public plugin API.
------------------------------------------------------------

-- Test-only. Core keeps sync state at file scope - stream counter, reassembly
-- buffers, retry budgets, throttle stamps, the stall watch - and none of it can
-- be reached from outside, so test sections used to inherit each other's. A
-- section that reused a sender found its retry budget already spent by an
-- earlier one and failed far from the cause. Harmless in game: nothing calls it.
local function ResetSyncState()
    pendingAuth = {}
    LibSync.seen, LibSync.announced = {}, {}
    bnetScanPending = false
    lastWhisperAt, syncAttempt, manualSyncAt, unreachableToldAt = {}, {}, {}, {}
    refusedStreams = {}
    consent = {}
    refusedNotified = {}
    streamCounter   = 0
    incomingBuffers = {}
    outdatedSenders = {}
    autoRetryCounts = {}
    lastRequestedAt = {}
    syncWatch       = {}
end

------------------------------------------------------------
-- Which cutout belongs to which character (#89), for everything that asks:
-- the Roster draws them, the capture button's "due" check looks them up
-- (#128). One copy, here, rather than one per file that can drift.
------------------------------------------------------------

-- The converter names each file after the character it photographed, lowercased
-- with every run of non-alphanumerics collapsed to a dash. This has to agree
-- with Tools/RenderCutout/make-cutout.py EXACTLY or every portrait silently
-- falls back to a card, so it is one function with one test.
function AltStable.CutoutSlug(name)
    if type(name) ~= "string" then return nil end
    local s = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return (s ~= "") and s or nil
end

-- An entry only counts when it can actually be DRAWN. The renderer requires
-- entry.file, so a counter asking a weaker question would hide the "N of M have
-- a portrait" hint at exactly the moment every card is a fallback.
function AltStable.CutoutDrawable(entry)
    return type(entry) == "table" and type(entry.file) == "string" and entry.file ~= ""
end

-- By GUID first, then by name.
--
-- A name is not an identity: two characters on different realms or accounts
-- can share one, and punctuation or accents can fold two different names into
-- one slug. A manifest keyed by name alone would hang one character's portrait
-- on both. So an entry is looked up by the character's GUID, and the name key
-- is the legacy fallback for manifests written before entries carried one - and
-- even then an entry that NAMES a different GUID is refused rather than shown
-- on the wrong character.
function AltStable.CutoutFor(char)
    local manifest = AltStableCutoutManifest
    if type(manifest) ~= "table" or type(char) ~= "table" then return nil end
    local drawable = AltStable.CutoutDrawable
    if type(char.guid) == "string" and drawable(manifest[char.guid]) then
        return manifest[char.guid]
    end
    local slug = AltStable.CutoutSlug(char.name)
    local entry = slug and manifest[slug] or nil
    if not drawable(entry) then return nil end
    if entry.guid ~= nil and entry.guid ~= char.guid then return nil end
    return entry
end

------------------------------------------------------------
-- Item tooltips, for every plugin that adds lines to them (Warband's counts,
-- Professions' recipes). GameTooltip:HookScript("OnTooltipSetItem") THROWS on
-- Forever (#10); TooltipDataProcessor is the replacement, and the item arrives
-- in the data payload rather than through tt:GetItem().
------------------------------------------------------------

-- The item a tooltip is showing: the payload's id, or the link's as a fallback.
function AltStable.TooltipItemID(tt, data)
    local id = data and data.id
    if not id and tt and tt.GetItem then
        local _, link = tt:GetItem()
        id = link and tonumber(link:match("item:(%d+)"))
    end
    return tonumber(id)
end

-- Registers fn(tooltip, itemID) as an item post-call. False when this client
-- has no TooltipDataProcessor - the caller's panel still works without it.
function AltStable.HookItemTooltip(fn)
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
            and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then
        return false
    end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        fn(tt, AltStable.TooltipItemID(tt, data))
    end)
    return true
end

local _seam = {
    ReplyDelay          = ReplyDelay,
    ComputeChecksum     = ComputeChecksum,
    SerializeChar       = SerializeChar,
    CleanupDB           = CleanupDB,
    DispatchPluginPayloads = DispatchPluginPayloads,
    PurgeRetiredFields  = PurgeRetiredFields,
    RETIRED_FIELDS      = RETIRED_FIELDS,
    DeserializeChar     = DeserializeChar,
    SerializeFullDB     = SerializeFullDB,
    DeserializeFullDB   = DeserializeFullDB,
    ChunkAndSendPayload = ChunkAndSendPayload,
    RequestCharacters   = RequestCharacters,
    RequestResync       = RequestResync,
    WatermarkCeiling    = WatermarkCeiling,
    ReceiveCharacter    = ReceiveCharacter,
    SendFullDatabase    = SendFullDatabase,
    QueueWire           = QueueWire,
    SyncScopeEpoch      = ScopeGeneration,
    GetPeerWatermark    = GetPeerWatermark,
    ScanSavedInstances  = ScanSavedInstances,
    ScanMail            = ScanMail,
    CheckMailAlerts     = CheckMailAlerts,
    WatchSyncPeer       = WatchSyncPeer,
    CheckSyncWatch      = CheckSyncWatch,
    NoteSyncActivity    = NoteSyncActivity,
    ClearSyncWatch      = ClearSyncWatch,
    PeerShort           = PeerShort,
    GetSyncTargets      = GetSyncTargets,
    CHAR_SEP            = CHAR_SEP,
    MAX_CHUNK           = MAX_CHUNK,
    PROTOCOL_VERSION    = PROTOCOL_VERSION,
    PREFIX             = PREFIX,
    MSG_CHUNK_V        = MSG_CHUNK_V,
    MSG_DONE_V         = MSG_DONE_V,
    MSG_REQUEST_V      = MSG_REQUEST_V,
    LibSync            = LibSync,
    CommandVersion     = CommandVersion,
    CHUNK_VERSION      = CHUNK_VERSION,
    frame              = frame,   -- drive CHAT_MSG_ADDON in receive-side tests
    CoreFrame          = frame,   -- the same, under a name SheetUI does not reuse for the sheet
    ResetSyncState     = ResetSyncState,
    BufferedStreams    = function() local n = 0; for _ in pairs(incomingBuffers) do n = n + 1 end; return n end,
}

AltStable._test = AltStable._test or {}
for k, v in pairs(_seam) do AltStable._test[k] = v end
