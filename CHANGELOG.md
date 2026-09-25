# Changelog

## Unreleased

- **Surnames are back on the sheet.** Client 1.60.1.70009 moved the surname into
  `UnitName`'s second return, so every character scanned on it was stored as just its first
  name — and a persisted record then rejected its own updates over sync ("name changed: Kaleid
  Sumner -> Kaleid"). Names are read whole again, and a record missing its surname gains one
  back on the next sync instead of being refused
  ([#56](https://github.com/Spotnick2/AltStable/issues/56)).

- **Data survives a restart.** The beta client used to write SavedVariables and never read them
  back; build 1.60.1.70009 fixed that, so characters, settings, the sync whitelist and the
  hidden-character list are all still there on the next launch. Nothing in the addon changed for
  this — it has been writing them correctly all along
  ([#23](https://github.com/Spotnick2/AltStable/issues/23)).
- Measured against client build 1.60.1.70009.

- **Hide a character from the sheet.** Right-click its name and confirm; it
  disappears from the grid and from the footer totals, which then say how many
  were left out. The record keeps syncing and updating - nothing is deleted.
  Restore it under Options, "Hidden characters". The list is per account and is
  keyed by GUID, so two characters sharing a first name are not confused
  ([#21](https://github.com/Spotnick2/AltStable/issues/21)).

## v0.1.0-beta

First packaged build for World of Warcraft: Forever (measured on client
1.60.1.69977, interface 16001). Ported from AltTracker (TBC Classic 2.5.5).

**Known limitation at the time of this release:** the client did not read
SavedVariables back after a restart
([#23](https://github.com/Spotnick2/AltStable/issues/23)), so nothing persisted
between sessions. Fixed by Blizzard in client build 1.60.1.70009, with no change
needed here.

### The sheet

- Characters, gear, professions, reputations, gold, rested XP and raid lockouts,
  in one grid, gathered from every character on the account.
- **Reputations** are the Vanilla set plus Forever's own sixteen factions, keyed
  by faction ID. A faction appears only once some character has actually met it.
- **Gear** is coloured by item quality, and item levels read as whole numbers.
- The level cap, the rested-XP rules and the profession caps all come from the
  client rather than being hard-coded, so they follow content patches.

### Plugins (optional, enable them in Options)

- **Warband** — every item across all your characters' bags and banks in one
  grid, with a per-character breakdown on hover, and optional counts on every
  item tooltip in the game.
- **Raids** — which characters are saved to which raid and when each resets.
  Progress is shown as a count ("7/10"); named boss kills wait until a real
  lockout can confirm the encounter order
  ([#17](https://github.com/Spotnick2/AltStable/issues/17)).

### Sync

- Characters sync between your own accounts over the addon channel, in deltas,
  compressed and chunked under the client's 255-byte message cap.
- Whitelisted names only, and a character removed at the source is removed on
  the other account too.
