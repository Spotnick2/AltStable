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
local MSG_REQUEST_V = MSG_REQUEST .. PROTOCOL_VERSION   -- "REQ7"
local MSG_DONE_V    = MSG_DONE    .. PROTOCOL_VERSION   -- "DONE7"
local MSG_CHUNK_V   = MSG_CHUNK   .. "5"                -- "CHUNK5"

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
--   oversize message (the old C_ChatInfo path only returned false), which would
--   abort the whole send. 255 - 35 = 220.
local MAX_CHUNK = 220

-- Monotonic per-session stream id, one per ChunkAndSendPayload call.
local streamCounter = 0
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

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r " .. msg)
end

------------------------------------------------------------
-- Validation — reject incoming records whose immutable
-- fields (class, name) have changed for an existing GUID.
-- Returns true if the record is safe to accept.
------------------------------------------------------------

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

    -- Name should never change for a given GUID
    if existing.name and c.name and existing.name ~= c.name then
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
local PLAYER_NAME = UnitName("player")

------------------------------------------------------------
-- Sync routing — whisper-only to whitelisted characters
------------------------------------------------------------

-- Returns a list of {channel, target} pairs to send to.
-- Only contacts whitelisted characters via whisper.
-- Guild broadcast is disabled for now (alt tracker, not guild tracker).
local function GetSyncTargets()
    AltStableConfig = AltStableConfig or {}

    local whitelist = AltStableConfig.whitelist or {}
    if #whitelist == 0 then
        return {}
    end

    local targets = {}
    for _, name in ipairs(whitelist) do
        table.insert(targets, { channel = "WHISPER", target = name })
    end

    return targets
end

------------------------------------------------------------
-- Serialize character
------------------------------------------------------------

local function SerializeChar(c, sinceTS)

    local parts = {}

    for k,v in pairs(c) do
        if type(v) ~= "table"
        and not k:find("^gearlink_")   -- item links are local-only (too large for sync)
                                      -- gearid_* stays included (compact + sync-safe)
        and not k:find("^gearsubtype_") -- local-only: only used by the local render pipeline;
                                      -- synced alts fall back to keyword inference on gearname_
        and k ~= "specIcon"            -- numeric fileID, client-specific
        -- NOTE: refshot_ts (reference-screenshot marker) IS synced on purpose. The render
        -- pipeline reads ONE aggregator account, so an alt's marker must ride sync to reach it.
        -- NOTE: hidehelm / hidecloak ride sync for the same reason — the pipeline has to know
        -- the player hid a slot, since the equipped item list alone can't tell it. They are
        -- plain 1/0 numbers, so the tonumber() coercion below round-trips them unchanged.
        -- They must NOT become booleans: tostring(false) sends "false", which tonumber() leaves
        -- as the STRING "false" — and a non-empty string is truthy in Lua, so a hidden-cloak
        -- flag would read as shown and vice versa.
        -- The screenshot lives in the install-wide Screenshots folder, so any account on this
        -- machine resolves it; cross-machine peers just won't match and fall back to the saved ref.
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
                local num = tonumber(v)
                c[k] = num or v
            end
        end

    end

    if not c.guid then
        return
    end

    -- Dispatch any plugin payloads to their owners.  Done AFTER c.guid
    -- is confirmed so plugins can trust the character exists.
    if pluginPayloads and AltStable.plugins then
        for _, plugin in ipairs(AltStable.plugins) do
            local blob = pluginPayloads[plugin.id]
            if blob and plugin.OnDeserialize then
                pcall(plugin.OnDeserialize, c.guid, blob)
            end
        end
    end

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

-- Per-peer delta-sync watermark: the newest lastUpdate VALUE we have received
-- from that peer. It is the peer's OWN timestamp, so we never compare across
-- machine clocks. Persisted in AltStableConfig.peerWatermarks, keyed by the
-- realm-less short name so a REQ target and its reply sender map to one entry.
local function PeerShort(name)
    return (name and name:match("^([^%-]+)")) or name
end
local function GetPeerWatermark(name)
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.peerWatermarks = AltStableConfig.peerWatermarks or {}
    return AltStableConfig.peerWatermarks[PeerShort(name)] or 0
end
local function AdvancePeerWatermark(name, ts)
    if not ts or ts <= 0 then return end
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.peerWatermarks = AltStableConfig.peerWatermarks or {}
    local short = PeerShort(name)
    if ts > (AltStableConfig.peerWatermarks[short] or 0) then
        AltStableConfig.peerWatermarks[short] = ts
    end
end
AltStable.ResetPeerWatermarks = function() AltStableConfig.peerWatermarks = {} end

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
local function SerializeFullDB(accountOnly, sinceTS)

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
        if type(c) == "table" and c.guid
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
-- This runs ONLY on the receive/merge path, i.e. for REMOTE characters synced
-- from another account. That's why gearlink_* is cleared too: a full item link
-- is only ever populated by a LOCAL scan (ScanCharacter writes those directly,
-- not through this merge), so on a synced record any gearlink_ is stale — it
-- lingers from older addon versions that used to sync links, and would make the
-- gear tooltip show ancient gear even though the synced ilvl/name/id are current.
--
-- Preserves metadata (account, guild, money, name, class, …): the incoming
-- record overwrites those when present, and a peer that hasn't tagged a
-- character shouldn't wipe our local account assignment.
local function ClearSyncedStateFields(t)
    t.prof1 = nil; t.prof2 = nil
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
        or k:find("^mail_") then                 -- mail summary (mail_count / mail_expiry / mail_money)
            t[k] = nil
        end
    end
end

local function DeserializeFullDB(payload, sender)

    local current = {}
    local rejected = 0
    local maxTS = 0   -- newest lastUpdate seen; the caller advances the peer watermark to it

    for line in (payload .. "\n"):gmatch("([^\n]*)\n") do

        if line == CHAR_SEP then
            -- End of a character block — deserialize what we have.
            local msg = table.concat(current, "\n")
            current = {}

            local c = DeserializeChar(msg)

            if c and c.guid then

                -- Track the newest timestamp across everything the peer sent
                -- (even rejected/skipped records) so the watermark advances past
                -- them and they aren't re-requested next delta.
                if (c.lastUpdate or 0) > maxTS then maxTS = c.lastUpdate end

                -- Validate immutable fields before merging
                if not ValidateIncoming(c, sender) then
                    rejected = rejected + 1
                else
                    local existing = AltStableDB[c.guid] or {}

                    local existingTime = existing.lastUpdate or 0
                    local incomingTime = c.lastUpdate or 0

                    -- Only keep local copy if it is meaningfully newer (>60s).
                    -- Equal timestamps or small differences always accept the
                    -- incoming data — this handles the case where a record was
                    -- sent with incomplete gear (GetItemInfo cache miss) and a
                    -- corrected version arrives shortly after with the same stamp.
                    if existingTime - incomingTime <= 60 then
                        ClearSyncedStateFields(existing)
                        for k,v in pairs(c) do
                            existing[k] = v
                        end
                        AltStableDB[c.guid] = existing
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

    return maxTS

end

------------------------------------------------------------
-- Send character  (line-aligned chunks — single messages cap at 255 bytes)
------------------------------------------------------------

------------------------------------------------------------
-- Base64 codec
--
-- Chunks transmitted over WoW's addon channel are now base64-
-- encoded.  Reasoning: even though SendAddonMessage's docs
-- claim it transmits all bytes 1-255 verbatim, the user has
-- been seeing deterministic checksum mismatches with the
-- exact same hashes both sides every time, even when all
-- chunks arrived.  The likeliest culprit is some kind of
-- whitespace / control-character normalization happening
-- somewhere in the channel — leading/trailing whitespace
-- stripping is a common pattern in chat-server pipelines.
--
-- Encoding the chunk body as base64 sidesteps this entire
-- class of issues at the cost of a 33% size overhead.  Each
-- chunk's bytes after the header are now pure printable
-- ASCII from the base64 alphabet — A-Z, a-z, 0-9, +, /, =
-- — none of which any sane chat pipeline touches.
--
-- The encoding is plain RFC 4648 with `=` padding.
------------------------------------------------------------

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_DECODE = {}
for i = 1, #B64_ALPHABET do
    B64_DECODE[B64_ALPHABET:sub(i,i)] = i - 1
end

local function Base64Encode(s)
    if not s or s == "" then return "" end
    local out = {}
    local n = #s
    for i = 1, n, 3 do
        local b1 = string.byte(s, i)
        local b2 = string.byte(s, i+1) or 0
        local b3 = string.byte(s, i+2) or 0
        local n1 = math.floor(b1 / 4)
        local n2 = (b1 % 4) * 16 + math.floor(b2 / 16)
        local n3 = (b2 % 16) * 4 + math.floor(b3 / 64)
        local n4 = b3 % 64
        out[#out+1] = B64_ALPHABET:sub(n1+1, n1+1)
        out[#out+1] = B64_ALPHABET:sub(n2+1, n2+1)
        if i+1 <= n then
            out[#out+1] = B64_ALPHABET:sub(n3+1, n3+1)
        else
            out[#out+1] = "="
        end
        if i+2 <= n then
            out[#out+1] = B64_ALPHABET:sub(n4+1, n4+1)
        else
            out[#out+1] = "="
        end
    end
    return table.concat(out)
end

local function Base64Decode(s)
    if not s or s == "" then return "" end
    -- Strip any whitespace that might have crept in (defensive)
    s = s:gsub("%s", "")
    local out = {}
    local n = #s
    for i = 1, n, 4 do
        local c1 = s:sub(i,   i)
        local c2 = s:sub(i+1, i+1)
        local c3 = s:sub(i+2, i+2)
        local c4 = s:sub(i+3, i+3)
        local n1 = B64_DECODE[c1]
        local n2 = B64_DECODE[c2]
        local n3 = B64_DECODE[c3] or 0
        local n4 = B64_DECODE[c4] or 0
        if not n1 or not n2 then return nil end  -- malformed
        local b1 = n1 * 4 + math.floor(n2 / 16)
        local b2 = (n2 % 16) * 16 + math.floor(n3 / 4)
        local b3 = (n3 % 4) * 64 + n4
        out[#out+1] = string.char(b1)
        if c3 ~= "=" and c3 ~= "" then out[#out+1] = string.char(b2) end
        if c4 ~= "=" and c4 ~= "" then out[#out+1] = string.char(b3) end
    end
    return table.concat(out)
end


--
-- Called by SendFullDatabase. Splits the payload into chunks no larger
-- than MAX_CHUNK, computes one checksum over the reassembled stream, and
-- sends each chunk as
--   "CHUNK2|<seq>/<total>|<chunkBody>"
-- followed by "DONE4|<checksum>".
--
-- Both sides must agree on the byte sequence in order — the sequence
-- numbers let the receiver reassemble even if packets arrive out of
-- order, and detect drops (a missing seq gets reported on DONE).
------------------------------------------------------------

-- Send one wire message, paced by ChatThrottleLib when present (it queues +
-- rate-limits), falling back to a direct send if CTL somehow isn't loaded.
-- CTL raises a Lua error on an oversize (>255) message, so the call is wrapped:
-- a pathological over-budget packet degrades to a direct send (which merely
-- returns false) instead of aborting the whole ChunkAndSendPayload loop. With
-- MAX_CHUNK=220 this is belt-and-suspenders — it should never fire.
local function QueueWire(msg, channel, target)
    if ChatThrottleLib then
        local ok = pcall(ChatThrottleLib.SendAddonMessage, ChatThrottleLib, "BULK", PREFIX, msg, channel, target)
        if not ok then
            C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
        end
    else
        C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
    end
end

local function ChunkAndSendPayload(payload, channel, target)

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
local function SendFullDatabase(channel, target, sinceTS)

    channel = channel or "GUILD"

    -- By default only send characters from the current account.
    -- If sendAllAccounts is enabled in config, send everything.
    AltStableConfig = AltStableConfig or {}
    local accountOnly = not AltStableConfig.sendAllAccounts

    local payload = SerializeFullDB(accountOnly, sinceTS)
    ChunkAndSendPayload(payload, channel, target)

end

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
                Print("|cff888888No sync response from " .. w.name .. "|r — they're online but didn't reply (still loading addons, or on an older AltStable).")
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

local function RequestCharacters(channel, target, force)

    channel = channel or "GUILD"

    if target then
        local now = time()
        if not force then
            local last = lastRequestedAt[target]
            if last and (now - last) < REQUEST_THROTTLE then
                return false
            end
        end
        lastRequestedAt[target] = now
    end

    -- Carry our delta watermark for this peer so they can send only what
    -- changed since we last heard from them. A peer on older code ignores the
    -- extra payload and replies with a full DB (correct, just unoptimized).
    local wm = target and GetPeerWatermark(target) or 0
    C_ChatInfo.SendAddonMessage(PREFIX, MSG_REQUEST_V .. "|" .. wm, channel, target)
    WatchSyncPeer(target)
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

local function ReceiveCharacter(c, sender)

    if not c or not c.guid then
        return
    end

    -- Validate immutable fields before merging
    if not ValidateIncoming(c, sender) then
        return
    end

    local existing = AltStableDB[c.guid] or {}

    -- Last-write-wins: keep the local copy only if it is meaningfully newer
    -- (>60s), matching DeserializeFullDB's merge policy, so a stray older
    -- single-character update can't clobber fresher data.
    local existingTime = existing.lastUpdate or 0
    local incomingTime = c.lastUpdate or 0
    if existingTime - incomingTime > 60 then
        return
    end

    ClearSyncedStateFields(existing)
    for k,v in pairs(c) do
        existing[k] = v
    end

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

local function RequestResync(peer, reason)
    autoRetryCounts = autoRetryCounts or {}
    autoRetryCounts[peer] = (autoRetryCounts[peer] or 0) + 1
    if autoRetryCounts[peer] <= 2 then
        Print("|cffff8800Sync incomplete|r from " .. peer .. " — " .. reason ..
              " Auto-requesting resync (attempt " .. autoRetryCounts[peer] .. "/2).")
        C_Timer.After(2, function()
            C_ChatInfo.SendAddonMessage(PREFIX, MSG_REQUEST_V .. "|" .. GetPeerWatermark(peer), "WHISPER", peer)
        end)
        WatchSyncPeer(peer)   -- give the retry its own fresh stall window
    else
        Print("|cffff0000Sync failed|r from " .. peer .. " — " .. reason ..
              " after 2 auto-retries. Try /alts sync " .. peer .. " manually.")
        autoRetryCounts[peer] = nil
        ClearSyncWatch(peer)  -- already reported failure; don't also fire the watch
    end
end

------------------------------------------------------------
-- Finalize a received stream: verify completeness + checksum, then merge.
-- Called either immediately (buffer already complete on DONE) or after the
-- grace window (DONE arrived before a late/reordered chunk). Reads the
-- DONE's checksum stashed on the buffer as `buf.checksum`.
------------------------------------------------------------

local function CompleteStream(peer, bkey)
    local buf = incomingBuffers[bkey]
    if not buf or not buf.total or buf.total <= 0 then return end

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
        incomingBuffers[bkey] = nil
        RequestResync(peer, #missing .. "/" .. buf.total .. " chunks missing (" .. detail .. ").")
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
            incomingBuffers[bkey] = nil
            RequestResync(peer, "checksum mismatch.")
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
        incomingBuffers[bkey] = nil
        RequestResync(peer, "undecodable data.")
        return
    end

    -- A complete, decodable stream arrived — stop the stall-watch for this peer.
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
        local maxTS = DeserializeFullDB(buffer, peer)
        -- Advance our delta watermark for this peer so the next request only
        -- pulls what changes after this point.
        AdvancePeerWatermark(peer, maxTS)
        local after = 0
        for _ in pairs(AltStableDB) do after = after + 1 end
        local newChars = after - before
        if newChars > 0 then
            Print("Sync with " .. peer .. " complete. " .. after .. " characters known (" .. newChars .. " new).")
        else
            Print("Sync with " .. peer .. " complete. " .. after .. " characters known.")
        end
    end

    -- Success — clear retry budget and buffer for this stream.
    if autoRetryCounts then autoRetryCounts[peer] = nil end
    incomingBuffers[bkey] = nil
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
            -- dead), so the Raids plugin can show a named Killed / Not-killed list.
            -- Stored as a SEPARATE si_boss_<name>@<diff> field, NOT appended to the
            -- si_ value: the "si_boss_" prefix still matches the existing "^si_"
            -- serialize / clear / orphan-drop rules, so it syncs, gets cleaned up on
            -- expiry, and old clients can't resurrect a stale mask — while
            -- parseLockout rejects it (the value has no pipes), so no protocol bump is
            -- needed. Boss NAMES aren't synced; the plugin maps bit positions to a
            -- static boss list, so the encounter ORDER must stay stable (verified in
            -- game). Routed through newSet like every other field so the diff below
            -- flags `changed` and the delta sync picks it up.
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
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_UPDATE_RESTING")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("UPDATE_INSTANCE_INFO")   -- saved raid lockouts
frame:RegisterEvent("MAIL_INBOX_UPDATE")      -- mail with expiry
frame:RegisterEvent("CHAT_MSG_SYSTEM")    -- detect peer "X has come online" notifications

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

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

        local prefix, message, channel, sender = ...

        if prefix ~= PREFIX then
            return
        end

        ----------------------------------------------------
        -- Ignore our own packets
        ----------------------------------------------------

        -- In TBC, sender arrives as "Name-Realm". Strip the realm suffix before comparing.
        local senderName = sender and sender:match("^([^%-]+)") or ""
        if senderName == PLAYER_NAME then
            return
        end

        local cmd, payload = strsplit("|", message, 2)

        -- Versioned request — only reply to clients running the same protocol
        if cmd == MSG_REQUEST_V then
            -- payload is the requester's delta watermark (0 / absent => full DB).
            local sinceTS = tonumber(payload) or 0
            local replyChannel = (channel == "WHISPER") and "WHISPER" or "GUILD"
            local replyTarget  = (channel == "WHISPER") and senderName or nil
            Print(senderName .. " requested sync — sending data.")
            -- Stagger replies with entropy from the receiver's name +
            -- current time, so that two clients on the same machine
            -- replying to a broadcast don't pick the same delay (math.random
            -- on its own would be seeded identically right after launch).
            -- Result: each peer gets a deterministic-but-distinct delay
            -- between 1.0 and 4.0 seconds.
            local seed = 0
            local me = UnitName("player") or ""
            for i = 1, #me do seed = seed + string.byte(me, i) end
            local delay = 1 + ((seed + (time() % 1000)) % 30) / 10
            C_Timer.After(delay, function()
                SendFullDatabase(replyChannel, replyTarget, sinceTS)
            end)
            return
        end

        -- Older request from a previous protocol version — ignore
        if cmd == MSG_REQUEST or cmd == "REQ2" or cmd == "REQ3" or cmd == "REQ4" or cmd == "REQ5" or cmd == "REQ6" then
            Print("|cffff8800[AltStable]|r Ignoring sync request from "..senderName.." (outdated addon version).")
            return
        end

        if cmd == MSG_CHAR and payload then

            -- MSG_CHAR is now sent as a chunked stream; this path is kept
            -- only for backward compatibility with older addon versions.
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
        if cmd == MSG_CHUNK or cmd == "CHUNK2" or cmd == "CHUNK3" or cmd == "CHUNK4" then
            local key = sender and sender:match("^([^%-]+)") or sender
            outdatedSenders = outdatedSenders or {}
            if not outdatedSenders[key] then
                outdatedSenders[key] = true
                Print("|cffff8800[AltStable]|r Ignoring chunked sync from " .. key ..
                      " (outdated addon version — please update AltStable on both ends).")
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

            local bkey = peer .. "#" .. sidStr
            local buf = incomingBuffers[bkey]
            if not buf then
                -- total is fixed for the life of a stream (same sid), so it
                -- is only set at creation — never blindly overwritten by a
                -- later/stale packet.
                buf = { chunks = {}, total = total, lastTouched = time() }
                incomingBuffers[bkey] = buf
            else
                buf.lastTouched = time()
            end
            buf.chunks[seq] = body or ""
            NoteSyncActivity(peer)   -- keep the sync-watch stall timer alive

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
            local bkey = peer .. "#" .. sidStr
            local buf = incomingBuffers[bkey]

            if not buf then
                -- No chunks buffered for this stream (never arrived, or it was
                -- already finalized). Clear any leftover retry budget.
                if autoRetryCounts then autoRetryCounts[peer] = nil end
                return
            end

            -- Stash the checksum so a deferred completion can still verify it.
            buf.checksum = remoteChecksum

            -- Complete right now?
            local complete = buf.total and buf.total > 0
            if complete then
                for i = 1, buf.total do
                    if buf.chunks[i] == nil then complete = false; break end
                end
            end

            if complete then
                CompleteStream(peer, bkey)
            elseif not buf.donePending then
                -- A DONE can overtake an in-flight / reordered chunk. Give the
                -- straggler a short grace window before finalizing, so we don't
                -- declare a false "missing" and trigger a needless resync.
                buf.donePending = true
                C_Timer.After(CHUNK_DONE_GRACE, function()
                    CompleteStream(peer, bkey)
                end)
            end
            return
        end

        -- Old unversioned DONE from a previous addon version — discard buffer silently
        if cmd == MSG_DONE or cmd == "DONE2" or cmd == "DONE3" or cmd == "DONE4" or cmd == "DONE5" or cmd == "DONE6" then
            local key = sender and sender:match("^([^%-]+)") or sender
            if incomingBuffers[key] then
                incomingBuffers[key] = nil
                Print("|cffff8800Warning:|r Discarded data from "..key.." (outdated addon version — please update AltStable).")
            end
            return
        end

    end

    --------------------------------------------------------
    -- Login sync
    --------------------------------------------------------

    if event == "PLAYER_LOGIN" then

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
        PLAYER_NAME = UnitName("player") or PLAYER_NAME

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
            AltStableDB[guid].money = GetMoney()
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
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
            local liveRest = GetXPExhaustion() or 0
            local liveMax  = UnitXPMax("player") or 1
            local lvl      = UnitLevel("player") or 0

            -- Suspicious-zero guard.  Only accept a zero read if we have
            -- a prior non-zero snapshot that is very recent; a fresh zero
            -- between resting-state flips is legit, but a zero right on
            -- PLAYER_XP_UPDATE when rested was previously e.g. 40% is
            -- almost certainly a transient loading-screen read.
            local prevPct  = char.restPercent or 0
            local prevTime = char.restTimestamp or 0
            local elapsed  = time() - prevTime
            local suspicious = (liveRest == 0) and (prevPct > 5) and (elapsed < 5) and (lvl < 70)

            if not suspicious then
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

    if event == "PLAYER_EQUIPMENT_CHANGED" then
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

        -- Gem lookups the Roster audit could not resolve. Checked BEFORE the
        -- gear-slot queue below, which is local-equipment-only and is nil
        -- entirely when nothing local is pending -- the early return on it used
        -- to drop these events on the floor, so an audit finding suppressed by
        -- a cache miss stayed invisible until something else repainted the tab.
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

-- Empty until the plugins are ported. Each re-adds its own entry:
--   Warband   -> #9  / #10
--   Instances -> #11
--   Recipes   -> #14 (deferred)
--   Roster    -> #15 (deferred)
-- Listing an addon that does not exist means a failed LoadAddOn at every
-- login, which would bury the real errors this build exists to surface.
AltStable.LOD_PLUGINS = {}

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
    if enabled then
        for _, p in ipairs(AltStable.LOD_PLUGINS) do
            if p.key == key and not IsPluginLoaded(p.addon) then
                local ok, err = LoadPluginAddon(p.addon)
                if not ok then
                    DEFAULT_CHAT_FRAME:AddMessage(
                        "|cff00ccff[AltStable]|r could not load "..p.label.." ("..p.addon.."): "..tostring(err))
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

------------------------------------------------------------
-- Reference screenshot capture (feeds the AI render pipeline)
--
-- Hides the whole UI, takes an in-world Screenshot(), then restores the UI,
-- and stamps an epoch marker (refshot_ts) on the player's record. The external
-- render pipeline matches that marker to the resulting Screenshots/ file and
-- uses it as a FRESH identity/gear reference — fixing the stale-reference
-- problem where a months-old saved screenshot shows outdated transmog.
--
-- Screenshot() is asynchronous, so we sequence via C_Timer: hide UI -> let a
-- frame render UI-less -> capture -> let the file write -> show UI.
--
-- v1 is manual (`/alts update-reference`): the player frames the camera (mouse-
-- orbit to face the character) first. A portrait-UI button that auto-frames via
-- the world-camera presentation is the intended follow-up.
------------------------------------------------------------
local function CaptureReferenceScreenshot()
    if type(Screenshot) ~= "function" then
        Print("|cffff8800Screenshot() is unavailable on this client.|r")
        return
    end
    local guid = UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    if not char then
        Print("|cffff8800No character record yet|r — run |cffffff00/alts|r once so it scans, then retry.")
        return
    end

    -- Draw weapons so they show in the reference (a caster's weapon in hand, a
    -- hunter's bow, etc.). GetSheathState() == 1 means stowed; ToggleSheath()
    -- draws them. Remember the original state and restore it afterward so we
    -- don't leave the player's weapons changed.
    local restoreSheath = false
    if type(GetSheathState) == "function" and type(ToggleSheath) == "function" then
        local ok, state = pcall(GetSheathState)
        if ok and state == 1 then
            pcall(ToggleSheath)   -- draw
            restoreSheath = true
        end
    end

    Print("Capturing reference screenshot — drawing weapons, hiding UI...")
    -- Let the draw-weapon animation settle before hiding the UI and capturing.
    C_Timer.After(0.6, function()
        UIParent:Hide()
        C_Timer.After(0.2, function()
            char.refshot_ts = time()   -- marker the render pipeline matches against
            Screenshot()
            C_Timer.After(0.7, function()
                UIParent:Show()
                if restoreSheath and type(ToggleSheath) == "function" then
                    pcall(ToggleSheath)   -- restore the stowed state
                end
                Print("|cff88ff88Reference captured|r (in your Screenshots folder). "
                    .. "Run |cffffff00/reload|r to flush it to SavedVariables, then re-run the render pipeline.")
            end)
        end)
    end)
end
AltStable.CaptureReferenceScreenshot = CaptureReferenceScreenshot

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

    if cmd == "sync" then
        if not target or target == "" then
            local pinged, skipped = BroadcastRequest(true)
            if #pinged == 0 and #skipped == 0 then
                Print("No whitelisted peers configured. Add some with /alts whitelist <name>.")
            elseif #pinged == 0 then
                Print("No requests sent (all whitelisted peers throttled).")
            else
                Print("Requesting data from: " .. table.concat(pinged, ", "))
            end
            return
        end
        Print("Sending your data to " .. target .. " and requesting theirs...")
        SendFullDatabase("WHISPER", target)
        -- ChatThrottleLib paces the send in the background; fire the paired
        -- request shortly after so both directions exchange.
        C_Timer.After(3, function()
            RequestCharacters("WHISPER", target, true)
        end)
        return
    end

    ----------------------------------------------------
    -- /alts account N  — set this client's account number
    ----------------------------------------------------

    if cmd == "account" then
        local num = tonumber(target)
        if not num then
            Print("Usage: /alts account 1   (or 2, 3, ...)")
            return
        end
        AltStableConfig = AltStableConfig or {}
        AltStableConfig.accountNumber = num
        Print("Account number set to " .. num .. ". It will be included on next scan/sync.")
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
    -- /alts update-reference  — capture a fresh render reference
    ----------------------------------------------------

    if cmd == "update-reference" or cmd == "updateref" then
        CaptureReferenceScreenshot()
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

AltStable._test = {
    ComputeChecksum     = ComputeChecksum,
    Base64Encode        = Base64Encode,
    Base64Decode        = Base64Decode,
    SerializeChar       = SerializeChar,
    DeserializeChar     = DeserializeChar,
    SerializeFullDB     = SerializeFullDB,
    DeserializeFullDB   = DeserializeFullDB,
    ChunkAndSendPayload = ChunkAndSendPayload,
    RequestCharacters   = RequestCharacters,
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
    frame              = frame,   -- drive CHAT_MSG_ADDON in receive-side tests
}
