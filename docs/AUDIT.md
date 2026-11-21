# AltStable full-addon audit

Reviewed on 2026-11-20 at commit `dd6b027f1aaa8af4fa66f32d8fd43e85e4f054db`. File and line references below identify the implementation at that commit. Findings describe that checkout, including code predating the module integrations.

**Release recommendation.** Hold the release until login preserves intact plugin saves, a quick bank close preserves the last inventory movement, and out-of-order sync cannot replace newer character or bank data. A missing wishlist can be permanent. A wrong inventory count reaches both item tooltips and crafting advice. All 33 existing Lua test files passed on the reviewed checkout.

**Verified 2026-11-21.** Claude traced every finding in the code. The plan was agreed with Codex in three rounds. All twelve findings hold, and finding 12 holds only in part. Each finding below names its issue (#418–#435) and adds a **Verified** note where the code differs from the audit's account. One more issue came from the in-game table: the TSV export is invisible while the game UI is hidden (#434). The other in-game checks get an issue only if one reproduces.

The [historical issue #279 audit](#historical-audit-for-issue-279) follows this review. Its A1–A4 and B1 identifiers, mutation tests, and in-game procedure are still referenced from the scanner, Warband, tests, and probe.

## Findings in fix order

### 1. High · Login can delete intact recipe wishlists, talent snapshots, and quest history · #418

**Trigger and impact.** Restore an older core `AltStable.lua`, or lose it while the separate plugin saves survive. Log in with Professions, Roster, and Loremaster enabled. Each deletes records whose GUID has no named core row. Core requests plugin loading before its delayed character scan and peer pull. An offline alt can be missing much longer. A later sync can restore only what another peer holds. Replaying the alt can reconstruct much of the game-derived data, but cannot reconstruct the player's recipe stars. This was established by tracing startup and the three deletion paths. [Core startup](../Core.lua#L3734) · [Professions deletion](../Plugins/Professions/AltStableProfessions.lua#L716) · [Professions bootstrap](../Plugins/Professions/AltStableProfessions.lua#L2367) · [Roster deletion](../Plugins/Roster/Talents.lua#L233) · [Loremaster deletion](../Plugins/Loremaster/Loremaster.lua#L426)

**Fix and verification.** Follow Warband's recovery rule. Retain unattached records, omit them from display, and delete them on explicit forget, cleanup, or an applicable tombstone. Unattached data alone should not suppress a full peer backfill. Start with an older core fixture and intact plugin fixtures, then restore one GUID by sync. Its wishlist, talents, and completions should reappear. Also forget an alt while its plugin is disabled and check that re-enabling honors the tombstone. [Warband recovery rule](../Plugins/Warband/AltStableWarband.lua#L740)

**Verified.** Whether a full pull repairs the loss depends on what survives. Any enabled plugin whose store ends up empty resets the shared watermarks: Professions, Talents and Warband, plus Loremaster, which checks only `chars`. An older core file usually leaves the stores non-empty, so no pull runs. A lost `AltStable.lua` also loses the whisper targets and watermarks. The prune is asserted by tests that must flip: `test_professions.lua:536`, `test_roster.lua:64` and `:5183`, `test_loremaster.lua:339`.

### 2. High · Closing the bank quickly can double-count withdrawals or lose deposits · #419

**Trigger and impact.** Withdraw 15 from a bank stack of 20 and close the bank within one second. Warband schedules the bank scan on the bag update. Closing invalidates the pending bank scan while the carried-bag scan can still complete. In the Lua reproduction the bank retained 20. Once the bags record 15, the tooltip and Professions can count 35. A deposit can undercount by the same mechanism. Switching characters or syncing propagates the inconsistent snapshot. [Bank update](../Plugins/Warband/AltStableWarband.lua#L536) · [Timer](../Plugins/Warband/AltStableWarband.lua#L248) · [Close](../Plugins/Warband/AltStableWarband.lua#L564) · [Crafting consumer](../Plugins/Professions/AltStableProfessions.lua#L948)

**Fix and verification.** Capture the changed bank contents while the bank remains readable. Coalesce the aggregate redraw separately. Exercise both movement directions, immediately close, inspect the item on another alt, then sync to a peer. The combined quantity should stay 20. Repeat with a two-second pause to distinguish the timing failure from a container-ID error.

**Verified.** Nobody has measured whether the bank can still be read inside the close handler on Forever, and the fix depends on it. `test_warband.lua:669` asserts that the stale-session scan is dropped.

### 3. High · Out-of-order sync can roll back a character and its bank · #421 (core), #420 (bank)

**Verified.** The 60-second grace is documented design (`Core.lua:1436`), and two tests cover it (`test_comm.lua:440`, `test_provenance.lua:211`). Its stated reason, a correction sent with the same stamp, only needs `>=` on the remote branch. The cache retry stamps `time()`, so keep an equal-stamp test. In Warband, a missing `kt=` falls back to the overall stamp (`AltStableWarband.lua:678`). Warband has no `independentStamp`, so test both fixes together through Core.

| Store | Reproduced behavior | Fix and verification |
|---|---|---|
| Core character | A remotely held character accepts a snapshot up to 60 seconds older. Delivering stamp 1000 with 100 copper, then stamp 960 with 60 copper, left **stamp 960 and 60 copper**. Gear and other cleared-and-replaced fields follow the same merge. A locally scanned record correctly refused an older update. Identical replay preserves the values, but replay of an older snapshot after a newer one can reverse them. [Merge rule](../Core.lua#L1441) · [Bulk application](../Core.lua#L1558) · [Single-character application](../Core.lua#L2620) | Reject strictly older snapshots. Preserve the legitimate cache-completion case with equal-stamp enrichment or a new source revision on completion. Test newer → older → duplicate on both receive paths, including a slot whose item data finishes loading. |
| Warband bank | The overall inventory stamp admits a blob even when its bank is older. A bank holding 20 at bank stamp 95 reverted to 3 at bank stamp 60 when the overall stamp rose from 100 to 101. The existing guard protects a bank stamp of zero only. This can occur when a second PC scans new bags while holding an older bank snapshot. [Admission](../Plugins/Warband/AltStableWarband.lua#L669) · [Zero-stamp guard](../Plugins/Warband/AltStableWarband.lua#L685) · [Replacement](../Plugins/Warband/AltStableWarband.lua#L721) | Compare the bank section's own stamp before replacing its map. Test newer bags accompanied by older, never-scanned, and newer-confirmed-empty banks. Only the last case should clear a known bank. |

### 4. Medium · Routine sync can skip an offline alt's wishlist indefinitely · #422

**Trigger and impact.** Star or unstar a recipe for an offline alt whose core record predates the peer watermark. Professions advances its own stamp and correctly preserves the alt's Last Online time. Core selects records by Last Online before consulting the plugin serializer. The changed GUID was absent from the reproduced delta. A forced full pull or inclusion as a camp member can mask the failure. With all-account sending enabled, a newly received third-party record can also miss a downstream delta if its original scan predates that downstream account's watermark. [Wishlist edit](../Plugins/Professions/AltStableProfessions.lua#L318) · [Record selection](../Core.lua#L1337) · [Plugin serialization](../Core.lua#L990)

**Fix and verification.** Track when a record changed for transmission separately from when the character was online or scanned. Advance that revision for local plugin edits and genuinely different admitted data. Star an offline non-camp alt, pull twice, then replay identical data. The first pull should carry the change, Last Online should stay accurate, and the replay should not manufacture another change.

**Verified.** The delay is acknowledged in a comment (`AltStableProfessions.lua:315`). `independentStamp` only acts on receive. "Indefinitely" overstates it: camp membership or a full pull carries the change. A new cursor on the wire would have to be additive, with a fallback for older peers.

### 5. Medium · Professions reports “nobody has it” before inventory has been scanned · #423

**Trigger and impact.** With a known crafter and an empty Warband store, the reproduced recipe tooltip showed three red zeroes and “nobody has it.” Warband omits characters without positive holdings. The caller receives no coverage information to distinguish an unvisited bank or unscanned bags from a confirmed empty scan. The disabled-after-reload case correctly says counts are unavailable. “Nobody has it” is also misleading when the crafter holds one of the two required items. [Holder lookup](../Plugins/Warband/AltStableWarband.lua#L885) · [Professions consumer](../Plugins/Professions/AltStableProfessions.lua#L940) · [Tooltip wording](../Plugins/Professions/AltStableProfessions.lua#L1112)

**Fix and verification.** Carry coverage alongside the holder list, or say “none recorded” when a relevant source lacks a scan. Keep mailed items out of immediately craftable materials. Compare disabled Warband, an unvisited bank, a confirmed empty bank, and a partial stack.

**Verified.** Mail is already left out of craftable materials (`AltStableProfessions.lua:946`), so that part needs no change.

### 6. Medium · Mail expiry alerts stop after the first of several deadlines · #424

**Trigger and impact.** Scan two valuable mails due on days one and four. Leave that mailbox alone and log into another character on day two. Core stores one count and the earliest deadline. Once that date passes, it drops the character from the alert despite the second mail expiring in two days. The data loss follows from a complete inbox read. A partially loaded inbox further limits what the summary can say. [Summary write](../Core.lua#L3076) · [Alert filter](../Core.lua#L3112)

**Fix and verification.** Keep enough deadlines to select the next outstanding expiry, or warn that a mailbox with additional recorded mail needs another visit. Advance a fixture through both deadlines without rescanning. Also test a mailbox where the server reports more messages than the client has loaded.

### 7. Medium · Rested XP, level, skills, and standing can remain at obsolete values · #425 (rested, XP %), #426 (level, skills, standing)

**Verified, and wider than described.** Below the cap, when the player has no rested bonus, a full scan also never updates `xpPercent` or `xpMax` (`Scanner.lua:998`). The XP event never writes `xpPercent`, even while rested.

**Rested XP.** Forever returns ordinary `nil` when the player has no rested bonus. The scanner, XP event handler, and renderer treat this like a withheld secret. I reproduced a no-bonus XP event leaving a prior 60% bonus and its old timestamp intact. The renderer and Companion can extrapolate further from that obsolete reading. Check the raw value for secrecy before interpreting an ordinary no-bonus result as zero. Verify plain nil, a secret, and a positive number separately. [Client measurement](forever-api-notes.md#L1841) · [Scanner](../Scanner.lua#L994) · [XP event](../Core.lua#L3965) · [Renderer](../RowRenderer.lua#L70) · Companion checkout, `src/AltStableCompanion.Core/SheetExport.cs:570`

**Character progress.** The XP event updates rested fields but leaves `xpPercent` and `level` at their last full-scan values. A skill-up can update the Professions plugin's own rank while the core Skills grid and TSV keep the old rank. Reputation gains also wait for a full scan. A player can level, train, or earn standing, then switch characters without an equipment change or pet summon to trigger a rescan. Update the relevant fields on their own events and debounce skill and reputation reads. Verify level, skill, and standing changes without a gear rescan, then inspect the alt locally and on a peer. [Scanner level](../Scanner.lua#L921) · [Skills and reputation scans](../Scanner.lua#L1112) · [XP event](../Core.lua#L3958) · [Level cell](../RowRenderer.lua#L1024) · [Professions event](../Plugins/Professions/AltStableProfessions.lua#L2393)

### 8. Medium · Camp sync can delete camps or leave accounts with different settings · #427 (cap), #428 (ties)

**Verified.** Older receivers truncate too, so the sender must also hold back an oversized snapshot. Equal stamps also block the campless list order (`Config.lua:1251`).

**Camp loss.** Local creation accepts a 51st camp. The receiver stops parsing at 50 and adopts the truncated list. I reproduced 51 on account A, sync to B, a rename of the first camp on B, and sync back to A. Both accounts ended with 50. Reject an over-limit snapshot atomically, align local creation with the supported wire limit, and preserve existing over-limit stores. Verify that round trip before changing the limit. [Creation](../Config.lua#L955) · [Truncation](../Config.lua#L1195) · [Adoption](../Config.lua#L1238)

**Equal revisions.** Different customized pre-upgrade camps each synthesize stamp 1. Two accounts holding “North” and “South” rejected each other's snapshot in the reproduction. Legacy customized preference groups follow the same rule, and simultaneous edits can also tie. Add a deterministic tie-breaker for equal revisions with different contents. Exchange both ways twice and verify convergence and idempotence. [Camp stamp](../Config.lua#L1141) · [Camp comparison](../Config.lua#L1227) · [Preference stamp](../Config.lua#L1398) · [Preference comparison](../Config.lua#L1476)

### 9. Medium · Loremaster counts quests the character cannot reach · #429

**Trigger and impact.** The eligibility check follows prerequisite restrictions only one level back. Using the shipped data, a Human mage fails eligibility for *The Missing Scholar* (92850) because its predecessor (92849) is Skyborne-only. Yet its successor *Fillion's Mission* (99260) is counted as eligible. A player can chase an impossible completion and never close the gap in the zone total. [Eligibility check](../Plugins/Loremaster/Loremaster.lua#L134) · [Progress count](../Plugins/Loremaster/Loremaster.lua#L198) · [Predecessor data](../Plugins/Loremaster/QuestData.lua#L3874) · [Successor data](../Plugins/Loremaster/QuestData.lua#L5070)

**Fix and verification.** Evaluate attainability through the chain, with memoization, cycle protection, and the existing treatment of completions, alternatives, and unknown prerequisites. Test the shipped IDs against both Human and eligible Skyborne profiles.

### 10. Medium · Legacy misses partial exploration while its tab is closed · #430

**Trigger and impact.** Discover a new area without earning an achievement, then switch characters without opening Legacy. The client fixture reported six discovered areas while the stored count stayed at five after the criteria event and queued timers. Achievement completion and tab activation reread exploration. Neither occurs in this sequence, and logout does not capture it. [Exploration read](../Plugins/Legacy/AltStableLegacy.lua#L216) · [Visibility gate](../Plugins/Legacy/AltStableLegacy.lua#L2151) · [Event routing](../Plugins/Legacy/AltStableLegacy.lua#L2242)

**Fix and verification.** Save a debounced exploration read independently of repainting the achievement panel. Deliver a criteria change with the sheet closed, switch characters, and check the previous alt's count.

### 11. Lower severity · Three displays give incorrect answers from usable data · #431 (Raids), #432 (bank), #433 (TSV)

**Verified.** The Raids footer also leaves out characters beyond `MAX_COLS` and "Other" rows beyond `MAX_OTHER_ROWS`. For the bank label, the simplest fix is the mail precedent: the visit's first complete read refreshes `bankStamp` once.

| Problem | Cause, fix, and verification |
|---|---|
| **Collapsing a Raids group makes active saves disappear from the footer.** | With one active Barrow Deeps save, folding its group changed the footer from 1 active save and 1/8 bosses to 0 active saves and no bosses. The data was unchanged. Aggregate from the lockout lookup before filtering rows for display. Verify totals across fold and unfold. [Group filter](../Plugins/Instances/AltStableInstances.lua#L431) · [Accumulator](../Plugins/Instances/AltStableInstances.lua#L920) · [Footer](../Plugins/Instances/AltStableInstances.lua#L996) |
| **A bank can still be labeled over a week old immediately after a visit.** | Reading the same map returns before updating the stamp used for freshness. The stale flag remained after a successful unchanged scan nine days later. Record verification once per visit without churning the stamp on every cosmetic bag event. [Scan](../Plugins/Warband/AltStableWarband.lua#L194) · [Tooltip](../Core.lua#L5202) |
| **TSV assigns Alliance to an old Skyborne record with no faction.** | An unrecognized race defaults to Alliance. I reproduced the exported A for Skyborne, a race on both sides. Leave ambiguous legacy factions blank and retain the fallback for unambiguous races. Test missing faction and both explicit factions. [TSV fallback](../Export.lua#L87) · [Scanner faction contract](../Scanner.lua#L865) |

### 12. Performance · A single sync can cause many full panel rebuilds · #435

**Verified in part.** The cost is bounded. An unchanged record returns early (`AltStableWarband.lua:710`), so Warband rebuilds once per changed inventory. Roster and Raids queue once per `RefreshSheet`, which runs after the batch. Warband and Raids check `IsShown()`, not `IsVisible()`. Roster only checks that its panel exists.

**Trigger and impact.** While Warband is active, each changed character received causes a synchronous inventory rebuild across the roster. Core refreshes again after the batch. Roster and Raids queue a callback per refresh while selected. Closing the sheet leaves that selection in place. A child panel can remain individually shown under its hidden parent, so money, bag, and sync events can still schedule invisible layout work. Source inspection establishes the repeated work. Its frame-time cost needs a live roster. [Warband receiver](../Plugins/Warband/AltStableWarband.lua#L727) · [Inventory rebuild](../Plugins/Warband/AltStableWarband.lua#L1937) · [Core batch refresh](../Core.lua#L1580) · [Sheet close](../SheetUI.lua#L2491) · [Roster hook](../Plugins/Roster/AltStableRoster.lua#L3047) · [Raids hook](../Plugins/Instances/AltStableInstances.lua#L1162)

**Fix and verification.** Allow one pending redraw per visible panel per frame. Mark hidden panels dirty and repaint once on show. Count redraws during a 40-character pull with the panel open, closed, and reopened. Legacy already uses a visibility-aware scheduler. [Legacy scheduler](../Plugins/Legacy/AltStableLegacy.lua#L2144)

## Shipping inventory and validation

**Client.** World of Warcraft: Forever 1.60.1, interface 16001, Lua 5.1, with Vanilla content on the Mainline UI codebase. The checkout declares measured build **71037**. Its matching reference is `C:\Projects\WoW\References\Forever\api\forever-api-1.60.1.71037.md`. The reviewed XP, level, skill, reputation, bank, and mailbox event declarations were checked there. The pinned WowTestKit fixture describes build **70959**. Runtime measurements, including the ordinary nil result for no rested XP, are recorded separately. [Core manifest](../AltStable.toc) · [Build constant](../Config.lua#L1803) · [Kit pin](../tests/kit.pin) · [Measured notes](forever-api-notes.md)

**Packaging and module lifecycle.** Seven top-level addon folders ship. The six plugins each depend on AltStable and declare `LoadOnDemand`. Core requests enabled plugins at login so they can collect data before the player opens their windows. Enabling a plugin in Options loads it during the session. Disabling a loaded plugin takes effect on reload. A successful enable in Options resets peer watermarks for backfill. The development probe is excluded. [Package map](../.pkgmeta) · [Package assertions](../.github/workflows/package-check.yml#L165) · [Registry](../Core.lua#L4125) · [Enable and backfill](../Core.lua#L4187)

**Executed during the review.** `pwsh tests/run.ps1` passed, including the Lua 5.1 syntax check of 36 files, all 33 Lua test files, 16 cutout-manifest checks, 45 Python cutout checks, and 130 recipe-data checks. The suite also passed with temporary exports of the exact package tags, LibGlass r11, LibShowcase r10, LibAccountSync r8, and LibMailbox r1. A separate in-memory first-open exercise loaded all six plugins together and opened Summary, Gear, Skills, Reputations, Warband, Raids, Roster, Professions, Legacy, Loremaster, and Options. All 11 calls completed without a Lua error. Targeted Lua reproductions are identified in the findings. There was no live WoW session or release-zip build in this review. [Test runner](../tests/run.ps1)

### Cross-module contracts

**From a bank or mailbox visit to another alt's tooltip.** Warband keeps bags, bank, inbox, and outgoing-mail state separately. A bank stamp of zero means never scanned. A positive stamp can accompany a confirmed empty map. Warband accepts resolved inbox reads, keeps the count of withheld mail separately, and compares outgoing attachments with the recipient's last mailbox read. Core's expiry summary requires readable headers and clears its summary after recording no valuable mail. Professions counts immediately craftable materials from bags and bank. Findings 2, 3, 5, and 6 identify where the timing, merge, or consumer loses those distinctions. [Inbox read](../Plugins/Warband/AltStableWarband.lua#L336) · [Outgoing mail](../Plugins/Warband/AltStableWarband.lua#L371) · [Core mail summary](../Core.lua#L3065)

**Exports and external consumers.** GlassPanel uses public character copies and totals, including unknown balances. AltStableCompanion reads SavedVariables, selects character records by GUID and `lastUpdate`, and pairs portrait shots per store. Companion's spreadsheet exporter and the addon's in-game TSV are separate implementations. AltStableSync Link creates its own LibAccountSync instance and store. No direct use of AltStable's roster API was found in the accessible AltStableSync source. The sibling-checkout references are `GlassPanel/Plugins/AltStable/AltStable.lua:128`, `AltStableCompanion/src/AltStableCompanion.Core/SheetExport.cs:309`, `AltStableCompanion/src/AltStableCompanion.Core/CapturePairing.cs:48`, and `AltStableSync/Plugins/Link/Link.lua`. [Public character contract](../PublicAPI.lua#L77) · [Public API documentation](PUBLIC-API.md) · [Portrait contract](PORTRAIT-CONTRACT.md)

## Needs in-game verification

| Test | Observation needed |
|---|---|
| On build 71037, leave a known attachment in a mailbox, close it, switch characters, and hover its item. Repeat after taking the attachment immediately before close. | Confirm that attachment rows remain readable during the interaction-hide handler and a delayed callback cannot erase or duplicate them. The event declaration establishes neither property. [Close handler](../Plugins/Warband/AltStableWarband.lua#L439) |
| Use copies of core and plugin saves from different dates. Start and fully exit the client, relaunch, and inspect an offline alt before playing it. | Use a wishlist and a quest snapshot as witnesses. This distinguishes data restored from disk from fields rebuilt by the login scan. |
| Enable game-UI hiding, open the sheet, and invoke `/alts export` from a binding or macro. Start a portrait and interrupt it with combat. Complete a separate capture through Companion. | Check TSV visibility and focus, camera and UI restoration, screenshot format, and correct pairing of the two completed images. The export frame is parented to UIParent and raises itself; it is never lifted above the hidden UI (#434). [Export frame](../Export.lua#L171) · [Showcase adapter](../SheetUI.lua#L329) · [Capture recovery](../Capture.lua#L871) |
| Compare a low-level Hardcore alt and high-level Normal alt of the same class against Blizzard's Hardcore milestone. Cold-open a Loremaster map after login and revisit after map data loads. | Determine the actual Hardcore credit pool. Check whether an early missing tile or parent stays missing until reload. [Legacy measurement gap](forever-api-notes.md#L2418) · [Map cache](../Plugins/Loremaster/AltStableLoremaster.lua#L624) |

## Coverage checklist

| Shipped module or subsystem | Reviewed paths and outstanding limits |
|---|---|
| Packaging, TOCs, XML, bindings | Seven folders, plugin dependencies, four external XML includes, vendored LibStub, LibDeflate and ChatThrottleLib, optional GlassUI, toggle binding, and package exclusions. Packaging-input tests passed. The published zip was outside this checkout review. |
| Compat, Scanner, Reputations | API aliases, secrets, skill structs and collapsed headers, gear cache retries, bag and bank space, rulesets, reputation storage and scan triggers. Findings 7 and 11. |
| Core, Config | Login order, defaults and migrations, ownership, forget guards, consent, whisper and own-account routes, watermarks, chunk reassembly, duplicate delivery, plugin dispatch, camps, settings, raid and mail collection. Findings 1, 3, 4, 6, 7, and 8. |
| Glass, Theme, Skin, Prompt, Appearance | Library negotiation, optional suite integration, tooltip ownership, prompt lifecycle, theme/scale callbacks, barber read/apply/storage. Visual fidelity, protected interactions, and barber event order remain client checks. |
| Columns, RowRenderer, CharacterMenu, SheetUI | Summary, Gear, Skills, Reputations, six Options pages, registration, sorting, grouping, layout, first build, character actions, hidden windows and refresh hooks. All sidebar sections opened in the combined fixture. |
| Toasts, GoldTooltip | Login cooldown scan and deduplication, money-frame hooks, hidden characters, unknown balances and shared total calculation. Actual Blizzard-frame hover remains a client check. |
| Capture, AutoCapture | Paired shots, metadata, gear-change offers, countdown, combat/death cancellation, screenshot-format restoration and Companion handoff. Automated suites passed. Real screenshots require the client. |
| PublicAPI, Export | Copies, provenance, gear state, callbacks, totals, TSV ordering and fallback fields. Compared GlassPanel, Companion, and AltStableSync integration paths. Findings 3, 7, and 11 affect consumers. |
| Warband · WarbandTabs, AltStableWarband | Tab defaults and filters, bags, bank, mailbox, outbox, section timestamps, item tooltips, sync and redraws. Findings 2, 3, 5, 11, and 12. |
| Raids · AltStableInstances | Core lockout scan through expiry, boss masks, group collapse, footer totals and hidden refresh. Findings 11 and 12. |
| Roster · AltStableRoster, CampList, Talents | First activation, camp membership and order, portraits and fallback cards, gear audit, talent scans and snapshots, cleanup and refresh. Findings 1, 8, and 12. |
| Professions · RecipeData, AltStableProfessions | Catalogue, trade-window reads, ownership and loss confirmation, cooldowns, independent snapshot stamps, wishlists, Warband reagent planning and disable/re-enable behavior. Findings 1, 2, 4, 5, and 7. |
| Legacy · LegacyData, AltStableLegacy | Achievement and exploration collection, per-alt storage, criteria events, first activation, footer and hidden-panel behavior. Finding 10. Hardcore credit needs a live comparison. |
| Loremaster · QuestData, Loremaster, AltStableLoremaster | Generated quest data, eligibility and prerequisite links, completion snapshots, sync, deletion, zone totals, map cache and first activation. Findings 1 and 9. In-game map streaming remains unverified. |

**Recommended work order.** Preserve plugin saves first, then repair bank-close capture and both stale-snapshot comparisons. Require those fixes for release. Next address delta selection, incomplete reagent counts, and mail expiry alerts. Follow with progress updates, camp convergence, and quest eligibility. The Raids footer, freshness label, TSV faction fallback, and redraw scheduling can be fixed independently.

---

## Historical audit for issue 279

The following is the original audit of what a sync receives and what a login rewrites. Its build numbers, branch, line references, test results and pending live checks describe the earlier checkout.

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
| Skills | `GetNumSkillLines` / `GetSkillLineInfo` by skill id (446-521) | professions, secondaries | **A2 (fixed)**: an empty list leaves the stored values, as reputations already did (Reputations.lua:191) | a profession that vanished for real is cleared only by a non-empty scan (declared); with a header collapsed in the Skills panel, the lines it hides keep their stored values (#383) |
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
