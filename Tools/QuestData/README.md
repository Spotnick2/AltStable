# QuestData: the Loremaster plugin's quest table (#374)

`gen-quests.lua` builds `Plugins/Loremaster/QuestData.lua` from QuestieDB. GPL-3, like the
plugin (`Plugins/Loremaster/NOTICE.md`). Never ships (`Tools/` is ignored by `.pkgmeta`).

```
lua Tools/QuestData/gen-quests.lua            # write the file and print the report
lua Tools/QuestData/gen-quests.lua --check    # fail if the file would change
```

Run with Lua 5.1 (`C:\Program Files (x86)\Lua\5.1\lua.exe`) from the repository root. It takes
about 20 s. The owner runs it by hand; CI has no References folder, so it can't.

## Inputs

All read in place from `C:\Projects\WoW\References`, nothing copied here:

- **QuestieDB, Forever edition** (`Addons\QuestsLeveling\QuestieDB`). Its data is baked into
  its TOC as metadata. `questiedb-loader.lua` runs QuestieDB's own reader under plain Lua 5.1
  with the client functions it calls replaced (metadata, base64, zlib through our
  `Libs/LibDeflate`, CBOR). It is read once per faction and class, because QuestieDB's
  Dynamic Corrections depend on them.
- **Questie** (`Addons\QuestsLeveling\Questie`): the quest blacklist and the holiday lists.
- **wago.tools tables** (`Forever\db`): AreaTable (English zone names, continent) and UiMap.
- **`overrides.lua`**: the hand-kept fixes, each with its reason.

## When to run it

- When the QuestieDB or Questie reference copies are updated (the `wow-references` skill).
- After changing `overrides.lua`. The in-game per-zone check feeds it: a zone that a character
  can't bring to 100%, or a quest that isn't there, gets a line in it.

Then check the report: every row with its quest count, `UNMAPPED` areas, and fields that
differ between faction or class reads (`profile difference`). Commit the regenerated file with
the change that caused it. Its `D.VERSION` changes with the content, and synced counts carry
it.

## The rules

They are the approved plan's (#374), summarised in the generated file's header:

- **Left out:** repeatables (`specialFlags` bit 1), holiday and one-time world events (holiday
  sorts and Questie's holiday lists), and quests Questie blacklists (`true` entries only).
- **Rows:**
  - Instance aliases are resolved before outdoor parents, so Zul'Farrak's quests count in
    Zul'Farrak, not Tanaris.
  - Single-class quests go to the Class row, wherever they are filed.
  - Raids and battlegrounds come from `overrides.lua`.
  - Sorts become Professions or Other rows.
- **Unsure** (counted only once done): quests with no known starter, quests QuestieDB files in
  no zone, and the areas listed in `overrides.lua`.
- **Reference-only rows:** quests the runtime rules look at (exclusive partners, breadcrumb
  targets, follow-ups, parents, pre-quests) that aren't counted themselves.
