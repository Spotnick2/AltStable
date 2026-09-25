# Sync discovery — how two accounts find each other

Design research for [#58](https://github.com/Spotnick2/AltStable/issues/58). **Parked** until the
port is finished; picked up again with in-game testing, because the decisive questions are
measurements, not opinions.

This file exists so that work does not start from zero: what the code does today, what a shipped
retail addon does, which routes are already closed and why, and the exact list of things to measure
first.

---

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

| Fact | Where |
|---|---|
| A request is answered **to whoever asked** — the replying side needs no whitelist entry, no config, nothing | `Core.lua:1390`, `replyTarget = senderName` |
| The whitelist gates **outbound only**: whom we whisper | `Core.lua:289`, `GetSyncTargets` |
| **Inbound is ungated.** Data from an unknown sender is processed, subject only to payload validation | the `CHAT_MSG_ADDON` branch, `Core.lua:1358` onward |
| Guild broadcast exists in the routing but is switched off deliberately — *"alt tracker, not guild tracker"* | `Core.lua:287` |
| We already react to "X has come online" and fire a request at whitelisted peers | `Core.lua:1719` |

So exactly one thing is missing, and it is not a longer list of names: **the asking side needs a
name that is online.**

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
  permission setting, not discovery.
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
(`50284074#1` and `50284074#12`), and an account cannot friend itself. Closed.

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
   field, with the realm attached when cross-realm. Store it as "account N was last seen as X".
2. **Try that one first** next session.
3. **When it fails, probe the adopted names in most-recently-played order.** We already store
   `lastUpdate` per character; the one played most recently is the likeliest to be logged in. One
   burst per login, never per sync tick.

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
- **#20** — the inherited sync-engine bugs. More peers means more concurrent streams, and a channel
  broadcast reaches every keyholder at once, which the per-peer watermarks and the `"<peer>#<sid>"`
  chunk buffers have never had to handle.
