# Changelog

## Unreleased

- **The Roster can show an enhanced portrait.** When the companion app has
  made one (optional, its own feature), the scene, grid and detail views draw
  it in place of the plain capture; anything malformed falls back to the plain
  portrait. The contract for it is in `docs/PORTRAIT-CONTRACT.md`
  ([AltStableCompanion#17](https://github.com/Spotnick2/AltStableCompanion/issues/17)).
- **A Professions tab: which alt knows which recipe.** Open a profession's
  window on each alt once, and the tab shows every recipe of that profession
  with who knows it, the skill it needs, and where it comes from (trainer, drop,
  vendor, quest). Filters for known, missing and nobody, a "not from a trainer"
  shopping list, and a search that spans every profession. Click an alt's card
  to see the list through their eyes: their difficulty colours, what they are
  missing. Alts from your other account arrive with sync. It only claims what it
  has seen: an alt whose window was never opened says "not scanned", and
  "nobody knows" becomes "nobody recorded" until every owner has been scanned.
  "Meets the skill requirement" is exactly that - specialisations and
  reputation are not checked. Craft cooldowns now show in the grid's profession
  tooltips. The recipe list comes from Wowhead's Forever database
  ([#14](https://github.com/Spotnick2/AltStable/issues/14)).
- **Recipes on item tooltips.** Hover a recipe item (at a vendor, in the
  auction house, in your bags) to see which alts already know it, which meet the
  skill for it, whose skill is still too low and by how much, and whom it cannot
  speak for yet. Crafted items say who can make them. Switch it off in the
  Professions tab. An item is only linked to a recipe when its name matches
  exactly one recipe of that profession; the few that do not get no line rather
  than a guess ([#14](https://github.com/Spotnick2/AltStable/issues/14)).
- **New saved data: `AltStableProfessionsDB`,** created by the new plugin.
  Nothing existing changed shape.
- **Other addons can read your characters.** A small read-only API -
  `AltStable.GetCharacters()`, `AltStable.GetTotals()`, `AltStable.ToggleSheet()`
  and a `CharactersChanged` callback - so an info bar can show your total gold
  and alts without keeping its own copy of them. First user: GlassPanel. The
  sheet's footer now computes its totals through the same function, so the two
  always agree. Documented in `docs/PUBLIC-API.md`
  ([#123](https://github.com/Spotnick2/AltStable/issues/123)).
- **Portrait capture ships with the addon.** `/alts portrait`, or the camera
  button in the sheet's title bar, takes the two-shot capture the Roster's
  lineup is made from; it used to live in a development tool the download never
  had. It refuses in combat, in a dungeon, while dead or moving, and gives up
  cleanly if you enter combat, die or bring your interface back mid-capture.
  Each of the two shots makes the camera's shutter sound. Afterwards it offers a reload,
  because the record of whose screenshots these are is only saved on a reload
  or logout. `/alts portrait preview` shows the framing first, and
  `/alts portrait facing <degrees>` turns the character. Turning captures into
  portraits still happens outside the game, with the converter on the project
  page; a companion app is next
  ([#89](https://github.com/Spotnick2/AltStable/issues/89)).
- **New saved data: `AltStablePortraits`.** It holds the capture records and is
  only created the first time you capture. Nothing existing changed shape.
- **A portrait belongs to the character, not the name.** Two characters sharing
  a name no longer show each other's portrait
  ([#89](https://github.com/Spotnick2/AltStable/issues/89)).
- **`/alts update-reference` is gone.** It took one plain screenshot for a
  pipeline that no longer exists, and nothing read it; it now points you at
  `/alts portrait`.
- **The Roster's scene says so when nobody has a portrait.** It used to show an
  empty campfire captioned "showing 0 of 12 - highest level first; favourite the
  ones you want here", which no amount of favouriting could fix. It now says
  there are none yet and how to capture one; the grid still shows characters
  without one as cards ([#89](https://github.com/Spotnick2/AltStable/issues/89)).

## v0.3.1-beta

One tab's colours, and nothing else. Same client build, same data on disk, same
sync — a peer on any v0.2.x or v0.3.x stays compatible.

- **The Raids tab matches the rest under glass.** Its rows, group headers and
  column header were charcoal values chosen before the material existed, so the
  one tab with its own grid was the one that still looked like the old theme.
  They come from the skin now and move with it
  ([#97](https://github.com/Spotnick2/AltStable/issues/97)).

## v0.3.0-beta

Still measured against client build **1.60.1.70009**. Nothing changed on disk
and nothing changed in sync, so a peer on v0.2.x stays compatible with this one.

Mostly about what the window feels like to use: the glass look is now a setting
you can find, it stops at the edge of what is ours, and the world behind the
window stops answering your cursor.

- **The skin is in Options now.** Flat, Clear glass and Smoked glass as a row of
  buttons, with the panel saying when a choice needs a reload and offering one —
  the material is built when the window is, so a choice takes effect on the next
  load. `/alts skin` still works
  ([#108](https://github.com/Spotnick2/AltStable/issues/108)).
- **"Theme" is called "Accent"**, because that is what it is: one highlight
  colour, Gold or your class colour. It never changed a background, a row or a
  border. Your setting is unchanged — only the name is
  ([#108](https://github.com/Spotnick2/AltStable/issues/108)).
- **Our own tooltips wear the glass**, and only ours: the game's tooltips and
  every other addon's are left exactly as they were
  ([#97](https://github.com/Spotnick2/AltStable/issues/97)).
- **The world stops reacting to your cursor through the window.** Moving the
  mouse across the sheet used to keep firing unit tooltips for whatever happened
  to be standing behind it, which in a city is constant. The window takes the
  mouse now, so the world responds where the window is not — and nowhere it is
  ([#74](https://github.com/Spotnick2/AltStable/issues/74)).

## v0.2.1-beta

A text fix, and only a text fix — no behaviour changed. Everything in
v0.2.0-beta below applies.

- **The Roster stopped telling you to type a command you do not have.** Its grid
  hint named `/asrender`, which is registered in a development tool that is not
  part of this download, so on a packaged install the client answered it with
  "Type /help for a list of available commands". The hint now names that command
  only when the tool is installed, and otherwise says where portraits actually
  come from ([#15](https://github.com/Spotnick2/AltStable/issues/15)).
- The v0.2.0-beta notes below described portrait capture as something the addon
  does. It is a separate workflow in the project's repository, and they now say
  so.

## v0.2.0-beta

Measured against client build **1.60.1.70009**, which is also the build that
fixed SavedVariables — see below. A peer on v0.1.0-beta can still sync with this
one, with one exception noted under Sync.

### The Roster — a new tab

- **Your characters as characters, not rows.** The Roster shows each alt as a
  card — class colour, name, level — and as a **portrait** for anyone who has
  one. **Portraits are not something this download can make.** They come from a
  capture tool in the project's repository that takes two shots in game and
  mattes them outside it, and that tool is not packaged here. Installed from
  CurseForge, the card is what you get, and the Roster says so rather than
  naming a command you do not have
  ([#15](https://github.com/Spotnick2/AltStable/issues/15)).
- **Scene mode** stands them together around a campfire, on fourteen backdrops.
  The grid stays the default and both views share one selection, so switching
  never loses your place ([#15](https://github.com/Spotnick2/AltStable/issues/15)).
- **Click a character** for a paper doll: every equipped item, the stats the
  client actually reports for it, and an **enchant audit** that names the slots
  missing an enchant. Back returns you to whichever view you came from
  ([#91](https://github.com/Spotnick2/AltStable/issues/91)).
- **Favourites** pin characters to the top of the sheet, and choose who stands in
  the scene ([#66](https://github.com/Spotnick2/AltStable/issues/66)).

### A new look, and two of them

- **Liquid glass.** The window, the sidebar, the menus and the toasts are a
  translucent material with rounded corners and a lit rim, in **Clear** or
  **Smoked**. Choose one with `/alts skin clear`, `/alts skin smoked` or
  `/alts skin flat`, then `/reload` — the material is built when the window is,
  so it changes on the next load rather than under your feet. **Flat** is still
  there and is unchanged, so this is a preference and not a migration. There is
  no Options control for it yet
  ([#97](https://github.com/Spotnick2/AltStable/issues/97)).
- There is no blur available to an addon, so the world behind the window shows
  through sharp. The **table itself stays opaque** for that reason — glass is for
  the frame, the table is somewhere to read.
- **The window fits your screen now.** It clamps to the display and re-fits when
  you change the UI scale, instead of growing past the bottom edge
  ([#99](https://github.com/Spotnick2/AltStable/issues/99)).

### Living with a lot of alts

- **One right-click menu** on a character, in the sheet and in the Roster:
  favourite, hide, unhide, forget. Hovering a name marks the row, and the mark
  stays put while the menu is open, so there is no doubt which character you are
  about to act on ([#69](https://github.com/Spotnick2/AltStable/issues/69)).
- **Hide a character from the sheet.** It leaves the grid and the footer totals,
  which then say how many were left out. The record keeps syncing — nothing is
  deleted. Restore it under Options → Hidden characters
  ([#21](https://github.com/Spotnick2/AltStable/issues/21)).
- **Forget a character that no longer exists.** Deleting the record was never the
  hard part: a peer still holding it re-sends it within seconds. Forgetting now
  leaves a tombstone, so a deleted character stays gone across sync
  ([#65](https://github.com/Spotnick2/AltStable/issues/65)).
- **Faction is captured at scan time** rather than derived from the race, because
  Forever's two Skyborne races report one race key — so every Skyborne was
  exported as Alliance, silently
  ([#22](https://github.com/Spotnick2/AltStable/issues/22)).

### Sync

- **The request handler answered anyone.** The addon channel prefix ships on
  CurseForge, so a crafted message could ask this addon for every record it held
  — names, realms, guilds, levels, item levels, gold, mail, lockouts,
  reputations — and on a default install it was not limited to one account. The
  handler now requires authorization before it answers. **This is the reason to
  take this build** ([#61](https://github.com/Spotnick2/AltStable/issues/61)).
- **Surnames are back.** Client 1.60.1.70009 moved the surname into `UnitName`'s
  second return, so characters scanned on it were stored under their first name
  alone, and a persisted record then rejected its own updates ("name changed:
  Kaleid Sumner -> Kaleid"). Names are read whole again, and a record missing its
  surname gains one back on the next sync. **Both sides need this build** — a
  peer still on v0.1.0-beta applies the old strict rule and will reject the
  repaired name ([#56](https://github.com/Spotnick2/AltStable/issues/56)).

### Fixes

- **Data survives a restart.** The beta client used to write SavedVariables and
  never read them back; build 1.60.1.70009 fixed that, so characters, settings,
  the sync whitelist and the hidden-character list are all still there next
  launch. Nothing in the addon changed — it had been writing them correctly all
  along ([#23](https://github.com/Spotnick2/AltStable/issues/23)).
- **The account number saves when you click away** from the box, not only when
  you press Enter. It was never persisted, which read as "it doesn't persist"
  ([#64](https://github.com/Spotnick2/AltStable/issues/64)).
- **A corpse run is not a gear change.** Auto-capture stopped announcing three
  portraits in as many minutes on a character that had picked nothing up, and
  Skip is a button rather than a command you have five seconds to find
  ([#86](https://github.com/Spotnick2/AltStable/issues/86)).
- **One line of chat per pull, gone.** The quiet-after-combat wait announced its
  own cancellation on every single mob
  ([#81](https://github.com/Spotnick2/AltStable/issues/81)).
- **The hide confirmation opened behind the sheet**
  ([#68](https://github.com/Spotnick2/AltStable/issues/68)), and the capture
  blackout could not see the window it was standing in front of
  ([#87](https://github.com/Spotnick2/AltStable/issues/87)).
- **Realm group headers** said "(Account: Default)" for everyone. That value never
  existed — it was the fallback for a field nothing ever set. They name the
  accounts their characters actually came from now, and say nothing at all when
  there is only one.
- **Bank storage measured, not estimated**: 52 bytes, against a 30 KB guess
  ([#44](https://github.com/Spotnick2/AltStable/issues/44)).

### Notes

- **Licence.** MIT covers this addon's own code. The bundled libraries keep their
  own licences, which the previous wording implied otherwise
  ([#90](https://github.com/Spotnick2/AltStable/issues/90)).
- The repository also carries development tools — portrait capture, an icon
  identifier, an API probe — that are **not** part of this download. Commands
  like `/asrender` and `/asicon` belong to those, and the addon no longer points
  at them unless they are installed.

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
