# Loremaster's SavedVariables: what an export can read (#374, AltStableCompanion#82)

The Loremaster plugin (`AltStableLoremaster`) keeps one snapshot per character in its own
SavedVariables file, `WTF\Account\<account>\SavedVariables\AltStableLoremaster.lua`. A tool can
read it without the game and without the plugin's GPL quest table. Everything below is a
plain Lua table of numbers and strings, safe for a table scanner that executes nothing.

## `AltStableLoremasterDB.chars[guid]`

Keyed by the character's GUID, as in `AltStableDB`. One entry per character Loremaster has
counted: the character playing, at its own login and turn-ins, or a character from the other
WoW account, received by sync.

| Field | Type | Meaning |
|---|---|---|
| `stamp` | number | When this snapshot was taken (Unix time, strictly increasing per character). |
| `ver` | string | What the counts were made with: the quest table's version and the counting rules' (for example `9b0a9380r2`). Counts from different versions are not directly comparable. |
| `level` | number | The character's level at the snapshot. |
| `faction` | string | `"Alliance"` or `"Horde"`. |
| `race`, `class` | number | Race ID and class ID (`UnitRace`/`UnitClass` third returns). |
| `log` | number or nil | Quests in the quest log ("!" in the player's spreadsheet). `nil` = not read. |
| `completed` | number | Every quest the client lists as completed, including repeatable and holiday quests the zone counts leave out ("?" in the spreadsheet). |
| `cls` | table | Class quests: `done`, `total` (everything the character can ever do), `now` (done, plus those open at its current level). The spreadsheet's "Class Quests 4/4" is `done` / `now`. |
| `c` | table | `c[zoneKey] = { done, total }`: per row, quests done out of those the character can ever do, missed ones left out. A row the character has no quests in is absent. |

**Unknown vs 0:** a character with **no entry** has never been counted (Loremaster wasn't on
when it last logged in). It is never stored as zeros. Within an entry, an absent `c[zoneKey]`
means that zone has no quests for this character, not 0/0 progress.

## `AltStableLoremasterDB.zones[zoneKey]`

Row names, written at every login: `{ name = <English name>, uiMapID = <number or nil>,
group = "zone" | "dungeon" | "raid" | "battleground" | "class" | "profession" | "other" }`.

`zoneKey` is:
- an area ID (a zone, dungeon or raid, e.g. `1` Dun Morogh, `12` Elwynn Forest);
- a negative QuestSort ID for professions and other sorts (e.g. `-304` Cooking);
- `-25` for Battlegrounds;
- `-9999` for the Class quests row (the same numbers as `cls.done` / `cls.total`);
- `0` for quests QuestieDB files in no zone.

## Not for export

- `AltStableLoremasterDB.done[guid]` is this install's list of done quest IDs, used for
  tooltips. It is local, never synced, and may be missing.
- `collapsed` and `thisChar` are the tab's display settings.
