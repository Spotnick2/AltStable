# Sync discovery — how two accounts find each other

Design research for [#58](https://github.com/Spotnick2/AltStable/issues/58) - **shipped** for the
owner's own accounts (below); the rest of this file is the research that led there, kept because
its closed routes stay closed.

This file exists so that work does not start from zero: what the code does today, what a shipped
retail addon does, which routes are already closed and why, and the exact list of things to measure
first.

---

## #58, shipped: your own accounts, through Battle.net

Measured on 70124 (the probe rounds of 2026-09-30, `Tools/AltStableProbe/BNet.lua`): Battle.net
game data between two WoW accounts on the **same Battle.net account** is delivered - across
rulesets and across factions, both directions - where whispers and channels stop at both. So:

- **Discovery** (`ScanOwnAccounts`): walk the client-local game account ids 1-128 (plus a GUID
  lookup for database characters beyond that) and keep those whose `GetAccountInfoByGUID` names
  OUR `bnetAccountID` - online, this game (`wowProjectID`), this region, not us. At login +5 s,
  every 60 s, on Battle.net presence events; the map is rebuilt each time and is session-only (ids
  are handles, never stored or sent).
- **Discovery waits for presences**: right after a login our own Battle.net presence can be blank
  (measured) - the scan then looks again every 10 s for up to 5 min, and ownership is also matched
  by BattleTag (`BNGetInfo`), which does not wait. `/alts bnet` shows each step.
- **A presence can stay blank** (measured 2026-10-01: 16+ minutes after a `/reload`, and again
  after a relog; blank on both sides - our own record and the other client's view of us), while
  `BNGetInfo` still answers. So nothing depends on it:
  - **our presence blank**: ownership by our BattleTag (`BNGetInfo`) still holds; our game and
    region come from the last time they were known (saved), and with nothing ever known we fail
    closed. **Same game AND same region, always** - a live realm, a PTR or TBC Anniversary on the
    same Battle.net account never syncs with this one (owner, 2026-10-01). Forever beta measured as
    `wowProjectID` 18, `regionID` 90; a live Forever is expected to differ in region (unmeasured);
  - **theirs blank** (no name AND no GUID): elimination - an id in no friend's list - is only a HINT
    of where to say hello. It cannot prove ownership: a friends list answering "zero" while still
    loading looks complete (Codex round 2 reproduced a friend being sent a chunk). **Proof is the
    household key**: each account has a random key, sent only to an account Battle.net verifies as
    ours and remembered when received from one; a blank presence is believed only when its hello
    carries a trusted key. Two accounts must have seen each other's full presence once, ever;
  - **both blank** (Codex round 3): neither side may send its key, so each PROVES it holds a trusted
    one. Every hello carries a nonce (fixed per id for the session) and answers the other side's
    latest nonce with `HMAC-SHA-256(own key, "AltStable#58|" nonce "|" name)`, truncated to 32 hex;
    the receiver checks it against the keys it trusts. A friend sees nonces and proofs only, each
    good for one id's nonce and one name. A new nonce is answered at once, but only to an id that is
    ours by elimination (or verified), so proofs go only where hellos go. SHA-256 is pure Lua in
    `Core.lua` (the client exposes no hash; LibDeflate's checksums are linear and forgeable),
    checked against the FIPS 180-2 and RFC 4231 vectors. Limit, accepted: a friend whose list we
    misread as ours could relay one side's proof to the other - it needs a broken friends list AND
    a purpose-built relay;
  - **who is on it**: a Battle.net-only hello, `HI8|name|guid|faction|realm|key|nonce|proof`, sent
    on first contact, to blank ids by hint (without the key), and in answer to a hello (at most once
    a minute per id, at once for a new nonce); forgotten when that id goes offline, its binding
    drops, or Battle.net contradicts it. Older clients read the first six fields and ignore the rest.
- **Transport of origin**: a request is answered the way it came (Battle.net, or a plain whisper -
  `WHISPER_DIRECT`), a resync goes the way the failed stream came, and a whitelisted own account not
  yet heard over Battle.net keeps its whisper. Capability is forgotten with its binding.
- First in-game successes: Karuzo Mortalis (PvE) <-> Karuzo Test (PvP2), and Memphisto Mortalis
  (Horde) <-> Karuzo Mortalis (Alliance), both ways, nothing whitelisted. Reviewed by Codex twice
  more (gpt-6-astra, high): the two P2s on #142, then the blank-presence design (one P1 - a gap in
  the friends list granting ownership - reproduced and fixed).
- **Capability**: ordinary traffic moves to Battle.net only once that peer has been HEARD over it;
  until then only discovery requests (channel `BNET`) use it - a peer with the switch off, or a
  pre-#58 AltStable, keeps its whisper sync.
- **Transport**: `QueueWire` sends a WHISPER to such a character as `BNSendGameData` through
  ChatThrottleLib (255 bytes, our chunks unchanged - **no protocol change**). `BN_CHAT_MSG_ADDON`
  from one feeds the same handler, under the character name Blizzard gives for the `senderID`; a
  friend's game data fails the ownership test and is dropped unread.
- **Trust**: such a character is `auto` after any stored answer - `never` still wins.
- **New peer**: asked at once (forced past the request throttle), twice more 30 s apart until a
  stream arrives; their request to us counts as finding them too, so both directions sync.
- **Unordered delivery**: a DONE may arrive first and now starts the stream; a stream completes on
  its last packet, or settles when nothing has arrived for 6 s (2 s for whispers); a late packet of
  a finished stream is ignored; stream ids are clock-seeded so a `/reload` cannot reuse them.
- **Off switch**: Options, or `AltStableConfig.bnetSync = false`.

Plan reviewed adversarially (Codex gpt-6-astra, high: "ship with changes", all taken but two
bounded - the 1-128 walk stays a heuristic with the GUID fallback, and queued-destination reuse is
re-checked before queueing, not recalled).

---


## #44, measured: the bank half is 52 bytes of 1.6 KB

Measured 2026-09-26 with `Tools/Sync/measure-blob.py`, which reads the
SavedVariables directly. Re-run it rather than trusting these numbers.

```
account 50284074#12
  characters with inventory : 20
  bag / bank entries        : 100 / 7
  blob payload, raw         : 1592 bytes
  ... deflated ALONE        :  403 bytes
  bank bytes, whole account :   52

account 50284074#1
  characters with inventory : 15
  bag / bank entries        :  80 / 0
  blob payload, raw         : 1188 bytes
  ... deflated ALONE        :  317 bytes
```

**What the compressed figures are and are not.** The warband fragments are
compressed here *on their own*, which is neither the size of a message nor a
bound on what they add to one. The real payload interleaves them with the core
character records in a single DEFLATE stream, and interleaving changes match
distances and available history: a fixture that compresses to 71 bytes alone can
add **103** when separated by other text. So these are standalone fragment sizes
— useful for comparing one roster against another, useless for "what does the
bank cost the wire". Answering *that* means measuring complete payloads with and
without the bank, which needs the core serializer and so a client.

**The decision does not rest on them anyway.** #44's concern is that a bag
change re-sends the bank too. Stated correctly: a bag change bumps **one**
character's stamp, and `SerializeFullDB` filters on `lastUpdate`, so the delta
carries that character alone. The bank re-sent with it is that one character's
bank — the worst on this machine is **7 entries, 52 raw bytes**.

Even the worst case the issue imagines is small in raw terms: a full 120-item
bank, with distinct ids so it does not compress unrealistically, is 905 raw
bytes. What that costs *compressed, in context* is exactly the thing this script
cannot tell you — but 905 bytes against a 1.6 KB blob, on the one character that
changed, is not a format change.

**So the split is not justified**, and it is not free: a `BLOB_VERSION` bump
with cross-version compatibility to get right. Re-measure if characters start
hoarding.

### Five ways the first attempt got this wrong

Recorded because each is an easy mistake to repeat, and the first version of
this section stated all of them as fact.

1. **Summing the account stores.** Each account is a separate client sending its
   own blob; summing them measures a message nobody sends and double-counts the
   13 characters both accounts know. Reported 35 characters for something that
   is really 20.
2. **Counting chunks on raw bytes.** `ChunkAndSendPayload` DEFLATEs and escapes
   before slicing, so raw size says nothing about chunk count. The correction
   was itself half wrong: compressing the fragments alone and calling it an
   upper bound on their contribution. It is not a bound in either direction —
   see the counterexample above.
3. **Treating a delta as the whole roster.** The waste is per character, because
   only the changed character rides the delta. This made the recorded threshold
   about twenty times too high.
4. **"Framing is half the blob."** True uncompressed, false on the wire:
   near-identical repeated headers are what DEFLATE erases. The claim that
   trimming framing was "the cheaper fix" is withdrawn.
5. **Inventing the values being measured.** The script substituted one constant
   stamp for every character and kept SavedVariables order instead of the
   numeric order `EncodeMap` emits. Both flatter the compressor: with the real
   stamps the same data deflates to **403 bytes rather than 343**, 17% worse.
   Measuring a fixture is not measuring the thing.

Note also that `EncodeForWoWAddonChannel` is **not** base64: it is
`CreateCodec("\000", "\001", "")`, which escapes two byte values and costs
~0.6% rather than a third. See #20 item 5, which is about that choice.

## The problem, stated precisely

Sync is whisper-only to a hand-typed whitelist. A whisper needs a character name, and the name that
matters is **whichever character the other account is logged in on right now** — which changes
every time you switch characters over there. So the list goes stale constantly, and the addon looks
broken when it is merely aimed at a character who logged out.

Two framings that sound right and are not:

- *"Auto-whitelist the character I log in on."* Does nothing locally. The whitelist holds the
  **other** account's characters; adding your own to your own list changes nothing. (The peer does
  learn about your character — but through the database exchange, not the whitelist.)
- *"Use the guild channel."* Only works if your alts are in the same guild as you. See Altoholic
  below: it takes the guild route and restricts sharing to same-guild alts on purpose.

---

## What the code does today

Authorization is done (#61: the request gate in PR #77, the rest after it). The rules, all in
`Core.lua`:

| Rule | Where |
|---|---|
| A request is served only to a peer answered **auto** (allowed, or on the whitelist), or one we named ourselves in `/alts sync <name>` in the last ten minutes. Anyone else is filed as a question: a chat line and a prompt | `MayServe`, the `REQ` branch, `RememberPendingRequest` |
| A stream is taken only from an auto peer, or one **we asked** in the last ten minutes. The window bounds the start; an admitted stream runs to the end | `MayAdmit`, the `CHUNK` and `CHAR` branches |
| **Never wins** everywhere: no *new* request, push, reply or resync goes to a never, and nothing is taken from one, even mid-stream or in the DONE grace window. A reply already in ChatThrottleLib's queue is not recalled | `CompleteStream`, `RequestCharacters`, `RequestResync`, `/alts sync` |
| A stream refused at its first packet stays refused to its end, even if the peer is allowed half way | `refusedStreams`, the `CHUNK` branch |
| One key per peer: the **name**, lower-cased, realm suffix dropped - names are unique across the region (below) | `AuthKey` (`AltStable.PeerKey`) |
| The reply is always a whisper to the character that asked | `ServeSyncRequest` |
| The whitelist is who *we* ask; allowing someone does not add them to it | `GetSyncTargets` |

Before #61 any player who whispered `REQ8|0` got the whole database back, and any stream from
anyone was merged. On a default install that was not even limited to one account: the account
filter only runs once `accountNumber` is set, and it defaults to `""`. That is still true of the
**scope** of a reply, but it is now a reply to someone the player approved.

A one-sided whitelist still works, which is why the gate is not simply "on the whitelist": A
types `/alts sync B`, B is asked once and presses Allow, and B's Allow also asks A back. A is
never prompted, because typing the name was A's consent.

**Names are unique across the region.** On Forever the realms are four rulesets (PvP, PvE, RP,
Hardcore) - servers underneath, but one namespace: character names, and guild names, are unique
across the whole region. So the realm suffix on a sender says where a character is, never who,
and keying by the name alone is correct - for the authorization answers, the echo check, and the
watermarks, `peerScopeGeneration` and stall watch that were always keyed by `PeerShort`. An
earlier cut of #61 kept the realm as identity; it made one person several keys, and folding our
own realm in made the account-wide config depend on the realm being played (review of #136).

So the thing missing for *discovery* is still a name that is online — but it is not the only
prerequisite.

---

## How Altoholic solves it (v12.1.002, read in full)

Worth knowing because it is a long-lived retail addon with the same problem — and its answer is
*not* a shared key.

- **Guild is the discovery channel.** At login it broadcasts `MSG_ANNOUNCELOGIN` carrying its alt
  list; online members whisper back `MSG_LOGINREPLY` with theirs
  (`DataStore/API/GuildComm.lua`). The guild roster supplies online status.
- **It shares same-guild alts only**, by design: `GetAlts()` carries the comment *"same guild (to
  send only guilded alts, privacy concern, do not change this)"*.
- **Account-to-account sharing is fully manual** (`Altoholic/Services/AccountSharing.lua`): name a
  target character, press Send Request, and the other side auto-accepts, asks, or refuses. A
  one-shot pull driven by a table of contents — not continuous sync. Its "automatic" is a
  permission setting, not discovery. The mode gates what it **sends**; what arrives in reply is
  not checked against it (its `authorizedRecipient` test is on the send side) - ours checks both.
  Its `Comm.lua` also runs every sender through `Ambiguate(sender, "none")`; we key on our own
  realm-folding instead, because what `Ambiguate` returns on this client is unmeasured.
- Chunking is AceComm-compatible control bytes (`\001` first, `\002` next, `\003` last) over
  ChatThrottleLib — functionally what our `CHUNK`/`DONE` protocol does.

**Conclusion: nobody has solved discovery for non-guilded alts.** Altoholic asks you to type a
name, exactly as we do.

### Worth stealing regardless of which design wins

1. **Three-mode inbound authorization** — `AUTH_AUTO` / `AUTH_ASK` / `AUTH_NEVER` per client name,
   defaulting to *ask*. This is the gate we lack entirely, and it is strictly better than a plain
   blacklist: "ask" is the right default for a stranger, and it makes the ungated-inbound hole a
   deliberate policy rather than an oversight.
2. **Never whisper someone known to be offline** — `GuildWhisper` checks `IsGuildMemberOnline`
   first. Wherever online status is knowable, this is the fix for whisper spam.
3. **`Ambiguate(sender, "none")`** to normalise a sender, instead of our hand-rolled
   `sender:match("^([^%-]+)")`. Present on 70009.

---

## Routes already closed

**Battle.net game data.** `C_BattleNet.SendGameData(gameAccountID, prefix, data)` exists on 70009
and is cross-realm *and* cross-faction — the ideal transport, except it needs a **Battle.net
friend's** game account id. Our two WoW accounts live under one Battle.net account
(`50284074#1` and `50284074#12`), and an account cannot friend itself. ~~Closed.~~ **Reopened and
shipped as #58:** our own other game accounts are addressable too, without friending (measured,
70124). Separate Battle.net accounts that are friends: #143, deferred until there is a tester.

**Across factions, nothing.** Measured on 70124: an addon whisper to a character online on the
other faction comes back as `No player named 'X' is currently playing.` - the same line as for
someone offline. The server delivers no whisper across factions, addon messages included, and
says nothing about why (mail is told "wrong faction"; whispers are not). So a Horde alt and an
Alliance alt cannot sync directly by any route we have; each syncs with the same-faction
characters of the other account. Any discovery design has to be per faction.

**Guild.** Only reaches alts guilded with you. Closed for the general case; still the cheapest path
for anyone whose alts *are* guilded together, so the login-announce handshake stays worth copying
if that ever becomes the common setup.

**Reading the other account's SavedVariables.** The client only loads the current account's files.
Closed at the client level, fixed or not (#23 changes nothing here).

---

## The design, in two halves

### Same realm — a household key on a private channel

Set the same key on both accounts once, derive a channel name from it, join silently, run sync
traffic there. No names, no guild, and switching characters changes nothing: whoever is logged in
is in the channel. Every piece exists on 1.60.1.70009:

```
JoinTemporaryChannel(name, password)        -- silent: no chat-window tab
SetChannelPassword / LeaveChannelByName / GetChannelName
C_ChatInfo.SendAddonMessage(prefix, message, "CHANNEL", channelIndex)
```

The password means **channel membership is the authentication** — a client without the key is not
in the channel at all. Carrying the key in the handshake also closes the ungated-inbound hole.

### Cross realm — remember who answered, then probe in the right order

Custom channels are almost certainly realm-bound, and our characters span `Classic Beta PvE` and
`Classic Beta PvP`, so whisper stays the only cross-realm transport. One manual seed is
unavoidable (two accounts cannot discover each other: SavedVariables are per account, a whisper
needs a name). After that seed:

1. **Remember who answered.** Any reply names that account's current character in the sender
   field — *assuming* the realm is attached when cross-realm, which is *unverified on this client*
   (`docs/forever-api-notes.md` records the cross-realm `CHAT_MSG_ADDON` sender format as
   untested). Store it as "account N was last seen as X".
2. **Try that one first** next session.
3. **When it fails, probe the adopted names in most-recently-played order.** We already store
   `lastUpdate` per character; the one played most recently is the likeliest to be logged in. One
   burst per login, never per sync tick.

**What our own code does with cross-realm senders.** Identity is the name (unique across the
region, see "What the code does today"), so the name-only echo check and keys are right.
Routing is the other job: requests are answered to the **raw** sender, realm and all, so a
cross-ruleset whisper goes where it came from. What remains is measuring whether cross-ruleset
whispers route at all.

Automatic after the first seed, and self-correcting when you switch characters.

---

## Measure before building any of it

The design above branches on facts nobody has established on this client. Do these first, in one
session, with two clients running:

1. Does `C_ChatInfo.SendAddonMessage(prefix, msg, "CHANNEL", index)` actually deliver? What does
   `SendAddonMessageResult` report when it does not?
2. **Are custom channels visible cross-realm?** This single answer decides whether the key is the
   whole design or half of it.
3. Does `JoinTemporaryChannel` stay out of the chat frame, and does it survive a relog?
4. What happens at the channel-count cap (historically 10)? Joining must fail loudly, not eat sync
   silently.
5. What trailing args does `CHAT_MSG_ADDON` carry for a channel message? `Core.lua:1389` currently
   routes every non-whisper reply to `GUILD`, so a channel branch is needed before anything works.
6. Does whispering an offline character produce a visible error line? That decides how aggressive
   the probing in step 3 above can be.
7. **A cross-realm request/reply round trip, end to end.** What exactly does `CHAT_MSG_ADDON`
   put in `sender` for a cross-realm whisper — and does a reply addressed to that value arrive?
   Everything in the cross-realm half rests on this, and both the client format and our own
   realm-stripping are unverified.

A probe for 1–5 belongs in `Tools/AltStableProbe`, not in the addon.

---

## Key handling

Cleartext is replayable by anyone listening on the same prefix. For personal alt data that is
probably good enough — but a nonce plus a hash of `key .. nonce` is cheap and worth costing out
before settling. **Do not build a key exchange.** This is a single-owner addon syncing its owner's
own characters; the threat model is an idle eavesdropper, not an attacker.

---

## Settings

**No on/off toggle.** The key — or the seed entry — *is* the consent. A toggle whose "off" position
means "keep typing names" earns nothing.

Build visibility instead: Options showing which peers came from the key, which you typed, and which
were adopted, with one click to set any of them to never. Altoholic's three-mode authorization is
the model.

---

## Dependencies

- **#56** — whisper targets need the full name including the surname. Adoption also removes the
  main source of whitelist typos, since names arrive over the wire rather than from the keyboard.
- **#61** — authorizing requests before sending records. Done: see "What the code does
  today".
- **#20** — the inherited sync-engine bugs. More peers means more concurrent streams, and a channel
  broadcast reaches every keyholder at once, which the per-peer watermarks and the `"<peer>#<sid>"`
  chunk buffers have never had to handle.
