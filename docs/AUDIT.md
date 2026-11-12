# Audit: what a sync receives and what a login rewrites

Issue #279, branch `audit/receive-migrations`, on `main` after v0.17.0's notes (7f9765f). Opus's
cross-repo audit table, row #3: AltStable has never been audited, and it sits on the receiving side
of the own-account protocol audited in AltStableSync #95. Scope, per the row: **not the whole repo**,
only the Warband plugin's sync receive path and the Config and Scanner "migrations", everything that
rewrites persisted data at login, where a bug means data loss. The property audited, as one sentence:
**after a login or a sync, every stored value is either what the owning client last read, or
unchanged; nothing is replaced by a placeholder (0, "", {}, nil) because a source was unavailable,
and nothing is deleted, except where declared.** The plan was reviewed with Codex gpt-6-astra
(medium), two rounds to consensus (2026-10-31); `docs/WORKFLOW.md` has the loop.

Facts met on the way, not fixed here:
- **The owner's live profiles were written by build 70532** (`svLoadCheck.build` on 2026-10-21) while
  `MEASURED_ON_BUILD` is 70450. The bump is the `client-update` skill's job, after launch (#275).
- **`accountSync.selfRegion` is 1 on both profiles**; the beta measured 90 (`docs/SYNC-DISCOVERY.md`).
  #275 already asks whether a region saved from the beta fails closed on live.
- **Nothing can be measured in game before 2026-11-04.** Section 5 is the procedure, run after launch.

## 1. Trace matrix

Per part: what the owning client reads, what rides the wire or the scan, what the receiver (or the
login) writes, what it keeps or clears, and the **declared exceptions**: what is knowingly lost or
overwritten and where that is said. A cell that said more or less than its row was a finding
(section 2) or is a declared exception here. Lines are as of `main` 7f9765f.

### 1a. The Warband plugin's receive path

| Part | Source (owner) | Wire | Receiver writes | Kept / cleared | Declared exceptions (where said) |
|---|---|---|---|---|---|
| Bags | `ScanBags` on BAG_UPDATE (debounced 1 s): `ApplyScan("bags")` only when the map changed; `bagsStamp = time()`, `stamp = max`, `TouchCharacter(guid)` so the core record's `lastUpdate` moves (AltStableWarband.lua:171-187) | one line on the character record, `plugin_warband:v1\|s=\|kt=\|b=\|k=` (301-314, Core.lua:894-903); omitted from a delta when `stamp < sinceTS` (308) | `DeserializePlayer` (316-358): `bags` replaced wholesale, `stamp`/`bagsStamp := s` | an older blob is refused (330); an equal stamp applies when the maps differ (345-349); a blob without `b=` or `k=`, or with a malformed entry, is refused whole (334-337) | **B2** same-second maps relayed out of order: the later-arriving older map wins until the next change (1 s stamps carry no order); said in the plugin header |
| Bank | `ScanBank` only while the frame is open and every tab's slot count is known; an emptied bank replaces a snapshot (189-211) | `kt=` is `bankStamp or 0`: **0 means the owner has never read this bank since its data began** (301-314) | `bank` replaced wholesale, `bankStamp := kt` | the bank is only readable at the bank, so the receiver's copy is the last visit's; `BANK_STALE` flags one older than 7 days (29, 522) | **B1 (fixed)**: a `kt=0` blob no longer blanks a held snapshot. **A4 (fixed)**: the login no longer deletes inventory whose core record is missing |
| Mail (#312, added after this audit; cited by function) | `ScanMail` only while a mailbox is open and its contents have arrived (`MAIL_SHOW`, then `MAIL_INBOX_UPDATE`), again on a change while open and at the close (`PLAYER_INTERACTION_MANAGER_FRAME_HIDE` with MailInfo 17: `MAIL_CLOSED` never fires on Forever); the whole inbox replaces `mail`; recorded when it changed and always at a visit's first read and its close, even unchanged (the read's time is what stops a send synced later from counting), `mailStamp = time()`; `mailMore` = mails past the 50 shown | `\|mt=\|mm=\|m=` after `k=`, only while `warbandMail` is on (`SerializePlayer`); `mt=0`: never read | `mail`, `mailMore := mm`, `mailStamp := mt` | kept when the fields are absent (an older client, a relay through one, the setting off), `mt=0`, `mt` older than the held read, or a malformed map; the record's other sections apply anyway | as stale as the last mailbox visit, like the bank (`BANK_STALE` flags it); unread mail past 50 is flagged, not counted |
| Outbox (#312) | the SENDER records a send to one of its own characters at `MAIL_SEND_SUCCESS` (the draft read in the `SendMail` post-hook) and a `ReturnInboxItem` to one; `outboxStamp = time()`; dead entries pruned on the next write (`PruneOutbox`) | `\|ot=\|o=<guid>@<at>:<map>/...` | `outbox := o`, `outboxStamp := ot` (same rules as mail) | an entry counts for its recipient while newer than the recipient's `mailStamp` and under 30 days (`EntryLive`); the recipient's record is never written | across PCs, `at` and the recipient's `mailStamp` come from two clocks; a skew of minutes can count a send once too few or too many until the next read |
| The gate the blob rides | — | the blob is a line of the core record | `DeserializeFullDB` (Core.lua:1370) dispatches a plugin's blob **only when the core record is accepted**: not forgotten (1353), `ValidateIncoming` (407), `ShouldMerge` (1327); Warband has no `independentStamp`, so a lost merge skips it (843-853, 1439) | `OnDeserialize` is pcall'd (850); a plugin error loses that blob silently | the coupling holds because every Warband change also moves `lastUpdate` (`TouchCharacter`); witness W3 in section 4 proves a delta without it never arrives |
| Delta and watermark | the requester asks `REQ8\|<watermark>` (2229-2236), capped at `time()-300` (1017) | a record goes when `lastUpdate >= sinceTS` (1232-1235) | the watermark advances to the newest `lastUpdate` **seen**, rejected and refused records included (1411-1414, 2495) | a record rejected by name/class, or refused as forgotten, is not asked for again until it changes or a full pull runs (`/alts cleanup`, a plugin switched on, a lift) | said here; by design (1411-1414) |
| Routes | — | whisper CHUNK5/DONE8 with checksum + deflate (2510-2578); LibAccountSync DB8, deflate only (2586-2599) | both end in `LibSync.Apply` (2476) | admission: `MayAdmit` (694-700), own account = AUTO | the library route has no checksum: `DecompressDeflate` refuses garbage, and the library owns its transport (declared) |
| Deletes | `/alts forget` and the settings-sync forget line → `ForgetCharacter` → `OnForget` (Core.lua:1076, AltStableWarband.lua:1880); `/alts cleanup` → `OnCleanup` (371) | `==FORGOT1==` own account only (Config.lua:1457-1460) | the Warband entry goes with the record | a forgotten character played since comes back whole: `UnforgetCharacter` resets the watermarks (Config.lua:635), the next reply is full | **C2** the tombstone list keeps the newest 200 (Config.lua:640-661): an evicted one lets a peer put the character back; said in RUNBOOK "tombstones" |

### 1b. The login: what rewrites `AltStableDB`

PLAYER_LOGIN frames fire in TOC order (there is no ADDON_LOADED handler anywhere): Core
(`PurgeRetiredFields`, `MigrateSyncAuthKeys`, `LoadEnabledPlugins`, then at +2 s `ScanCharacter` and
the sync request) → Config (`EnsureDefaults`, `PruneForgotten`) → Toasts (+15 s `PruneShownSet`) →
SheetUI (`EnsureDefaults` again) → the plugins' bootstrap at +1 s (Warband: the has-data check, +3 s
`ScanBags`).

| Part | Scan reads | Written as | When the read fails | Declared exceptions (where said) |
|---|---|---|---|---|
| Identity | `UnitGUID`, `PlayerFullName`, `GetRealmName`, `UnitClass`, `UnitRace`, `UnitFactionGroup`, `UnitSex`, `ReadPlayerDisplayID`, `UnitLevel` (Scanner.lua:608-695) | the record is reused (623); fields overwritten | `faction` keeps the old value (662); **A3 (fixed)**: `name` and `displayid` now do too; `realm`, `class`, `race`, `raceName`, `level`, `gender` are overwritten with what the read returned | class/race/realm/level: no failed read observed in-world at +2 s on this client (declared here, measured after launch, section 5) |
| Guild | `GetGuildInfo("player")` (701-702) | `guild or ""` | **""** overwrites, and nothing rescans on a guild event | nil at +2 s could be "not loaded yet" or "left the guild": **measured after launch** (section 5) before deciding |
| Gear | `GetInventoryItemLink` per slot, then `GetItemInfo` (884-915) | `gearid_`, `gearlink_`, `gearmod_`, `gearench_` from the link; `gear_`, `gearq_`, `gearname_`, `gearsubtype_` from the cache | **A1 (fixed)**: an uncached slot keeps the previous scan's four values when it still holds the same item; a *different* uncached item reads 0/"" until the cache event (declared, transient); `lastUpdate` is withheld while a slot is pending (939-941) but `TouchCharacter` moves it anyway | the cache event with `success=false` leaves the slot pending; the next scan or event fills it (Core.lua:3581, declared) |
| Skills | `GetNumSkillLines` / `GetSkillLineInfo` by skill id (446-521) | professions, secondaries | **A2 (fixed)**: an empty list leaves the stored values, as reputations already did (Reputations.lua:191) | a profession that vanished for real is cleared only by a non-empty scan (declared) |
| Reputations | `C_Reputation` list (Reputations.lua:189-202) | every `rep_` cleared then rewritten | an empty list leaves them (191) | — |
| Stats, money | `UnitStat`, `UnitHealthMax`, `GetMoney`, … through `PlainNumber`/`PlainSum` (721, 778-851) | numbers | **nil** overwrites: a secret value is unknown, and unknown is not 0 (AGENTS.md "Unit numbers can be unreadable") | by rule; the peer clears the field on merge (`ClearSyncedStateFields`) |
| Rested, pet, model path | (755-766, 929-934, 684-693) | only when read | old values kept | — |
| Lockouts | `GetNumSavedInstances` after `RequestRaidInfo` (Core.lua:2694-2768) | every `si_` not in the reply cleared | an empty reply means no lockouts | declared: the reply follows the server's UPDATE_INSTANCE_INFO |
| Retired fields | `RETIRED_FIELDS` (Core.lua:788-825) | `PurgeRetiredFields` at login deletes them from every record (827-833, 3319); dropped on receive (935) | — | by design (#8) |

### 1c. The login: what rewrites `AltStableConfig`

| Part | Where | Writes | Declared exceptions |
|---|---|---|---|
| Defaults | `EnsureDefaults` (Config.lua:85-352), twice at login (Config.lua:1769, SheetUI.lua:665) and on the Options panel | `or` / `== nil` defaults for absent keys; **unconditional deletes** every call: `toastProfessions.Jewelcrafting`, `bisTier`, `bnetKey`, `bnetTrusted`, `bnetSelfProject`, `bnetSelfRegion`, `minGemQuality` (134, 153, 157-160, 199) | idempotent; no type check on a stored value (a wrong-typed key is used as is) |
| v10 camera block | 256-276, once per profile (`worldCameraPresentationDefaultsVersion < 10`) | nine camera keys set to the v10 defaults, `worldCameraEnterDuration` only when absent, under 1.0 or the old 0.60 | a custom value of those nine keys from before v10 was replaced, once (shipped in v0.10; done on every profile that has logged in since) |
| Sync answers | `MigrateSyncAuthKeys` (Core.lua:624-636) at login | realm-suffixed / differently-cased keys folded to the bare lower-case name; on a clash "never" wins, else the first `pairs()` visits | declared; tested (`test_comm.lua:3069-3078`) |
| Plugins | `LoadEnabledPlugins` (Core.lua:3709-3721) runs **before** `EnsureDefaults` and writes `plugins = plugins or {}` | the `{professions=…=true}` default at Config.lua:137-139 never fires at login on a fresh profile | harmless: `IsPluginEnabled` treats absent as on (3703-3706) |
| Own-account store | `LibSync.Store` (Core.lua:3171-3188) | `accountSync.enabled := bnetSync ~= false` every call; a non-table `accountSync` is replaced by an empty store | by design: the addon's toggle owns the library's |
| Tombstones | `PruneForgotten` (Config.lua:640-661) at login | keeps the newest 200 by `at` | **C2** above |
| Session marks | `svLoadCheck` at PLAYER_ENTERING_WORLD (Config.lua:1692-1695); `toastsShown` pruned after 7 days (Toasts.lua:86-89) | — | — |

**Dry run over the owner's two live profiles** (2026-10-31, local only, never committed: the repo is
public). Copies of `WTF\Account\<id>\SavedVariables\AltStable.lua` and `AltStableWarband.lua` from
both accounts (5 records and 5 Warband entries each, 53 config keys, written by 70532 on 2026-10-21)
were loaded under `tests/wow_stubs.lua` as the TOC loads the addon, the real PLAYER_LOGIN was fired
on every frame that registered it, then PLAYER_ENTERING_WORLD, then every timer. Differences
afterwards: `svLoadCheck` and `accountSync.selfAt`/`selfRegion` (the session's own marks, from stub
data), nothing else: no record, no Warband entry, no other config key. `syncAuth` is empty on both,
so `MigrateSyncAuthKeys` had nothing to fold; `peerWatermarks` is keyed by the peer's full name, as
`PeerShort` keys it.

## 2. Findings and fixes

Found by reading, confirmed by a test written first (red), then fixed (green); each witness was run
once more with the fix reverted and went red again. Lines are as of this branch.

| # | Finding | Fix | Witness (reverted → red) |
|---|---|---|---|
| A1 | `ResetCharacter` zeroed every gear field before the gear loop (Scanner.lua:419-428), so an uncached slot "kept" zeros (the comment at the uncached branch said otherwise). The scanner withholds `lastUpdate` while a slot is pending, but Warband's `ApplyScan` → `TouchCharacter` stamps the record a second later, so the zeros rode the next delta and `ShouldMerge` took them as newer. A cache event answering `success=false` left them until the next good scan | the previous scan's level, quality, name and subtype are snapshotted per slot before the reset and restored for an uncached slot that still holds the same **link** (not the same item id: a suffixed variant shares the id and has another name; Codex on PR #280); a different link reads 0/"" until the cache event (declared, transient) | `test_scanner` "A1: an uncached slot keeps the previous scan's level" (+ quality, name, subtype, pending, `lastUpdate` withheld; 4 red), "the same id under another link is unknown" (W7: red with the guard loosened to any previous value); `test_warband_sync` R6 "the delta carries the helm's level from the previous scan, not 0" (W4, 3 red) |
| A2 | `ScanSkills` had no empty-list guard where `ScanReputations` has one (Reputations.lua:191), and the profession reset had already run in `ResetCharacter` | the profession and secondary reset moved into `ScanSkills`, after a `GetNumSkillLines() == 0 → return`; the tuple-shape witness now asserts the reset values | `test_scanner` "A2: …" through `ScanSkills` and through a full rescan with an empty list (6 red with the fix reverted) |
| A3 | `name` was written nil when `PlayerFullName()` returned nil (a nameless record is invisible and, before A4, an orphan to the Warband store); `displayid` was written 0, the read's failure value, and synced as "no model" | both keep the stored value when the read fails, as `faction` already did (`name or char.name`; `displayid` only when `> 0` or none stored). `guild` nil → "" stays until the live reading (section 5) says whether nil at +2 s means "not loaded" | `test_scanner` "A3: a scan that cannot read the name keeps the stored one", "…display id…" (2 red) |
| A4 | `PruneOrphans` ran at every login and deleted every Warband entry without a *named* core record, so a lost or unreadable `AltStable.lua` took every bank snapshot in `AltStableWarband.lua` with it (Codex, round 1: promote from declared to fixed) | no prune at login; an orphan stays, invisible (`gather` and `CountItem` iterate the named records), and does not count as held data for the baseline pull; `OnForget` and `OnCleanup` remain the explicit deletes | `test_warband` "A4: an orphaned record survives the login", "…is kept (A4)" ×2 (3 red); `test_login_migrations` "the Warband store keeps the orphan (A4)" |
| B1 | A blob with `kt=0` (the owner has never read that bank since its data began; a bank read as empty carries its scan time) replaced the receiver's last good bank snapshot with `{}`. The owner could not get it back either: its rescan is `scannedHere` and newer, so the peer's copy loses the merge. A data reset on the owning account erased the bank everywhere until its next bank visit | `DeserializePlayer` keeps `existing.bank`/`bankStamp` when `kt=0` and a stamped snapshot is held; the unchanged-compare uses the effective values, so a resend does not redraw; a `kt>0` empty bank still empties | `test_warband` "B1: a blob whose owner never read the bank keeps the held snapshot", "…and its stamp" (2 red); `test_warband_sync` R3 (W5, 2 red) |
| B3 | nothing drove the real plugin through the core's receive path: `test_warband` called `DeserializePlayer` directly, `test_comm` dispatched to a demo plugin, `test_accountsync` carried no `plugin_` line | `tests/test_warband_sync.lua` (section 4) | the five mutation witnesses |
| C1 | the login migrations: no defect by reading. Evidence: the dry run over the owner's two live profiles (section 1c) and `tests/test_login_migrations.lua`: a v0.12-era profile through every frame's PLAYER_LOGIN, asserting a login changes or removes only what is declared | — | "a login changes or removes nothing it does not declare" goes red with a stray `AltStableConfig.scale = nil` added to `EnsureDefaults` (W6) |

Dropped after reading (not defects):
- **`LoadEnabledPlugins` writing `plugins = {}` before `EnsureDefaults`**: the `{professions=…}` default never fires at
  login on a fresh profile, and it does not matter: `IsPluginEnabled` treats absent as on.
- **`CleanupDB` with a nil GUID** would delete every record: a slash command, always in-world.
- **`pcall` around `OnDeserialize`**: a plugin error loses that one blob; the writes are last, so nothing is half-written.
- **`bagsStamp := s` on receive**: cosmetic; `stamp` is what the delta and the stale-reject read.
- **The library route has no checksum**: `DecompressDeflate` refuses garbage and the library owns its transport.
- **A different uncached item reading 0/"" until the cache event** (Codex suggested nil): readers mostly `or 0`
  but `Export.lua:105` reads the field raw, nil would be a third state for a number, and the case lasts seconds.
- **`success=false` on the cache event**: the slot stays pending and the next scan or event fills it; a retry
  scheduler is more than this needs.

## 3. Declared exceptions, in one list

What a login or a sync knowingly overwrites or loses, and where it is said:
1. **B2** Two moves in one second relayed by two peers out of order: the later-arriving map wins until the
   next change; one-second stamps carry no order (plugin header, section 1a).
2. **C2** The tombstone list keeps the newest 200: an evicted tombstone lets a peer put that character
   back (`Config.lua:640-661`, RUNBOOK "tombstones").
3. A record rejected by name or class, or refused as forgotten, still advances the peer watermark: it is not
   asked for again until it changes or a full pull runs (`Core.lua:1411-1414`, by design).
4. The plugin blob rides the core record's merge: a lost merge drops it. The coupling holds because every
   Warband change moves `lastUpdate` (`TouchCharacter`); W3 proves a delta without it never arrives.
5. A different uncached item reads 0/"" until the cache event; a `success=false` cache event leaves the slot
   pending until the next scan (section 2).
6. Stats and money go nil on a secret value: unknown is not zero, and the peer clears the field on merge
   (AGENTS.md "Unit numbers can be unreadable").
7. `realm`, `class`, `race`, `raceName`, `level`, `gender` are overwritten with whatever the read returned; no
   failed read has been observed in-world at +2 s on this client (section 5 measures `guild`).
8. An empty lockout reply after `RequestRaidInfo` clears every lockout (`Core.lua:2756-2760`).
9. `EnsureDefaults` replaces nothing but deletes seven retired keys unconditionally; the one-shot v10 camera
   block replaced nine camera keys once, in v0.10 (section 1c).
10. `MigrateSyncAuthKeys` folds a clash to "never", else to whichever `pairs()` visits first; `LibSync.Store`
    makes the library's `enabled` follow `bnetSync` every call (section 1c).
11. An orphaned Warband entry (A4) stays on disk, invisible, until that character is forgotten or the
    database cleaned up (plugin header).

## 4. Round-trip rows and mutation witnesses

`tests/test_warband_sync.lua` (27 checks): the real plugin registered with the core, two "sides" that are
the three SavedVariables globals swapped in one Lua state, and payloads delivered to `LibSync.Apply`, where
both transports land. It tests the merge and the dispatch, not admission, transport or login
(`test_comm.lua` and `test_accountsync.lua` own those; Codex, round 1). `snap()` reads every entry of every
Warband map (an empty map and an absent one marked apart), the three stamps, and four core fields a Warband
change rides with (`name`, `class`, `lastUpdate`, `gear_head`); each row states its expected differences by
hand and passes only when the differences are exactly those.

| Row | What it does | Expected, by hand |
|---|---|---|
| R1 | A full pull A → B: two characters, one with a bank snapshot, one whose bank was never read (`kt=0`) | both records and both inventories arrive, nothing else; B's watermark for A is the newest stamp seen |
| R2 | A bag change on A (the plugin's own scan), then B pulls a delta | the scan moved the core record; the delta leaves out the unchanged character; B takes the bags and the stamps and nothing else: the bank snapshot stays |
| R3 | A's Warband store is reset; its login scans the bags only (`kt=0`); then A visits an empty bank (`kt>0`) | B keeps the bank snapshot the owner can no longer send (B1) and takes the bags; the empty bank, once read, empties B's |
| R4 | An older blob under a newer core record; an equal stamp with other contents; a truncated blob (no `b=`/`k=`) | no inventory change (stale-reject); applied; ignored whole: only the core stamp moves |
| R5 | A record whose first name changed; B forgets a character; a stale copy from A; the same character played since; the settings sync's forget line over DB8 from the own account | rejected with its inventory, the watermark still moves; the Warband entry goes with the record (the real `OnForget`); refused; let back with its inventory and every watermark reset; record and inventory dropped on B |
| R6 | A's helm cached, then a rescan with the cache cold (A1), then a bag change moves the record; then the cache event | the delta carries the previous scan's level, not 0; the cache event fills the slot and stamps the record; its next delta changes only the stamp on B |
| R7 | B's store through a Lua round trip (SavedVariables lose table identity), then a resend of everything | reads back as it was; nothing changes |

**Mutation witnesses.** Each break applied, `tests/test_warband_sync.lua` run, the file restored (all 27
green after every run, 2026-10-31):

| Witness | Break (one line) | Result |
|---|---|---|
| W1 | the stale-reject (`DeserializePlayer`, `existing.stamp > incomingStamp`) removed | 2 red: R4's older blob applies, and the equal-stamp row shifts |
| W2 | the `b=`/`k=` presence check removed | 2 red: the truncated blob blanks the bags (R4), and R6 inherits the blank |
| W3 | the `TouchCharacter` call in `ApplyScan` removed | 6 red: the core record never moves, so no delta carries R2, R3, R4 or R6 |
| W4 | A1's restore for an uncached slot removed | 3 red: the rescan and the delta read 0 (R6) |
| W5 | B1's `kt=0` guard removed | 2 red: B's snapshot is blanked (R3) |
| W6 | a stray `AltStableConfig.scale = nil` in `EnsureDefaults` | 1 red: `test_login_migrations` "a login changes or removes nothing it does not declare" |

## 5. In game (after 2026-11-04)

`/fp steps as audit` (`Tools/AltStableProbe`, deployed with `pwsh Tools/deploy-probe.ps1` on demand; tested
in `tests/test_probe.lua`, local only). At every login while the probe is deployed it records, 2 s after
PLAYER_LOGIN (the scan's moment), what the scan reads: `UnitName` both halves, `GetGuildInfo("player")`,
`C_SkillInfo.GetNumSkillLines()`, `C_PlayerInfo.GetDisplayID()`, into `AltStableProbeDB.audit.login`. The
procedure then shows that reading and checks it, asks whether the character is in a guild and compares, and
runs the Warband round trip with the owner's other account: a bag change seen on the other side after
`/alts sync`, the bank snapshot surviving a bag-only sync, one full exit on both accounts, the inventory
still held afterwards on both sides. The host cannot tell a `/reload` from a relaunch (GUIDE.md, section
3), so the exit is the owner's to prove, by `WowB`'s StartTime, never a `/reload`. Listed in #275.

| Step | What it proves |
|---|---|
| the login reading | skill lines are there at +2 s (A2 is insurance, not a live fault), the name is, and the display id |
| guild against the owner's answer | whether `GetGuildInfo` is nil at +2 s while in a guild (then `guild` gets the A3 guard too) |
| the bag change on the other account | R2 live: a Warband change rides the delta |
| the bank snapshot after a bag-only sync | R2's second half live |
| the full exit, both sides | the Warband store persists (both files), and so does the peer's copy |

_Results: pending the owner's session on live; they go here and to `docs/forever-api-notes.md`._
