# Changelog

## Unreleased

### New

- **Camps in the Roster** ([#152](https://github.com/Spotnick2/AltStable/issues/152)), like
  retail's warband camps: the scene now shows a **camp**, a named group of up to four characters
  in the order they stand, each with its own backdrop.
  - Your first camp is made for you the first time you open the scene, from your highest-level
    characters (those with a portrait first).
  - Switch camps with the new **< camp name >** arrows at the top of the scene; the backdrop
    arrows now change the shown camp's backdrop.
  - **Click the backdrop's name** for the backdrop picker, like retail's Campsites: every
    backdrop as a thumbnail, six to a page. Pick one and **Apply** it to the camp you're looking
    at, or tick **Apply for all camps**.
  - **The camp list**, beside the scene like retail's: a search box, **+** for a new camp, each
    camp with its four seats, then everyone in no camp. **Drag** a character onto a seat or a
    camp's name to put it there, onto someone in another camp to swap them, or anywhere else in
    the list to take it out; drag the characters in no camp up and down to order them, and a
    camp's name onto another to reorder the camps. Click a camp's
    name to show it, **right-click** it to rename or delete it. The **CAMPS** toggle along the
    bottom tucks the list away.
  - Right-click a character: **Add to** a camp, **Move to** another, **Add to a new camp**, or
    **Remove from** its camp.
  - **Favourites no longer pick who stands at the fire**; they still sort the grid first.
  - **Camps sync between your own accounts** ([#171](https://github.com/Spotnick2/AltStable/issues/171)):
    the camps and the order of the characters in no camp go with every sync to your other
    account found through Battle.net, and the newer one wins. A friend's sync never changes
    your camps. Which camp you're looking at, and whether the list is tucked away, stay per
    account.

## v0.7.1-beta

A one-fix release on top of v0.7.0-beta. Measured on client 1.60.1.70205. Nothing changes on the
sync wire or in saved data.

### AltStable Companion

The Roster's character portraits come from **AltStable Companion**, a free Windows app that turns
your `/alts portrait` captures into the transparent cutouts the scene draws (and can enhance them).
Without it, the scene has no one to show. Get it from
[AltStable Companion releases](https://github.com/Spotnick2/AltStableCompanion/releases).

### Fixed

- **The developer message at login could come back after the next client update.** v0.7.0-beta
  meant to show it only on development copies, but the release counted itself as one. It now
  recognises a release correctly.

## v0.7.0-beta

Sorting that makes sense, a window that moves smoothly, and a bigger, tidier sheet. Measured on
client 1.60.1.70205. Nothing changes on the sync wire. The new settings below are this account's
own and are not synced.

### AltStable Companion

The Roster's character portraits come from **AltStable Companion**, a free Windows app that turns
your `/alts portrait` captures into the transparent cutouts the scene draws (and can enhance them).
Without it, the scene has no one to show. Get it from
[AltStable Companion releases](https://github.com/Spotnick2/AltStableCompanion/releases).

### New

- **Sorting, reworked** ([#160](https://github.com/Spotnick2/AltStable/issues/160)):
  - **Each tab keeps its own sort.** Sort Summary by Gold, switch to Gear, and Gear has its own;
    come back and Summary is still by Gold.
  - **Remembered across logouts**, with a new option, **Options > "Remember each tab's sort
    order"** (on by default). Turned off, each tab keeps its sort until you log out.
  - **The first click goes the natural way:** names, guilds, classes and races A to Z; numbers
    highest first; Last Online most recent first. Click again to reverse.
  - **Characters with no value sort last**, whichever way you sort: unreadable gold, a faction
    they haven't met, no guild.
  - **Gear slot columns no longer sort.**
- **Clearer column headers:**
  - The column you sort by has a soft accent fill, an accent underline and an **arrow** for the
    direction, on every kind of header, icons included.
  - Hovering a header shows a plain grey highlight, so it never looks sorted.
  - Each header's tooltip says the current order and what the next click does.
  - The Class and Race headers have their own icons instead of the letters C and R, and every
    header icon is the same size.
- **Switching tabs animates** ([#159](https://github.com/Spotnick2/AltStable/issues/159)): the
  window glides to the new tab's size instead of jumping. Tabs that keep the size don't move.
  Turning off the open animation in Options turns this off too.
- **The Roster's menu icon is the AltStable logo.**
- **Portrait angle is a setting** ([#149](https://github.com/Spotnick2/AltStable/issues/149)):
  Options > Presentation > **Portrait angle**, -45 to 45 degrees (the same value
  `/alts portrait facing` sets). The default is now **straight on** (it was 20 degrees). An
  account that already has captures keeps 20, so new captures match the old ones; set 0 there
  to switch.
- **Collapse the menu to icons** ([#150](https://github.com/Spotnick2/AltStable/issues/150)):
  the **»** at the bottom of the left menu shrinks it to its icons (hover one for its name) and
  gives the room to the tab; **«** brings the labels back. Remembered per account.
- **Maximize** ([#150](https://github.com/Spotnick2/AltStable/issues/150)): the new button
  beside close fills the screen, and stays maximized as you switch tabs; click it again to go
  back to the size and place the window had.
- Collapsing and maximizing **animate**: the menu slides and the window grows or shrinks into
  place, in a fifth of a second. Turning off the open animation in Options turns these off too.
- **The grid fills a wider window**: when the window has more room than the columns need
  (maximized, or a collapsed menu), the spare width is shared out across the columns instead of
  leaving empty space beside the table.
- **Options reads better** ([#151](https://github.com/Spotnick2/AltStable/issues/151)): the
  sync peer, request and hidden-character lists take only the room they use (an empty one says
  so in a line), so there are no more large blank gaps; and the note about class colours now
  sits under the **Accent** row it explains instead of at the bottom of the page.

### Fixed

- **No more developer message at login.** After a client update, AltStable told every player to
  "re-run /apidump" and edit its source. That note is for whoever tests the addon, and now only
  shows on a development copy.
- **`/alts config` and right-clicking the minimap button** opened Options half way and raised an
  error. They open it properly now.
- **Sorting by Name** never showed which column was sorted.
- **Rested XP** sorted by the stored value rather than the one shown in the cell.
- **Race** sorted by the game's internal names, so Undead ("Scourge") landed between Orc and
  Tauren. Class and Race now sort by the names their tooltips show.


## v0.6.0-beta

The Warband tab becomes a warband bank, laid out like retail's. Measured on client 1.60.1.70170.
Nothing changes on the sync wire, and no saved data changes shape: the new settings are this
account's own.

### AltStable Companion

The Roster's character portraits come from **AltStable Companion**, a free Windows app that turns
your `/alts portrait` captures into the transparent cutouts the scene draws (and can enhance them).
Without it, the scene has no one to show. Get it from
[AltStable Companion releases](https://github.com/Spotnick2/AltStableCompanion/releases).

### New

- **The Warband tab is a warband bank** ([#153](https://github.com/Spotnick2/AltStable/issues/153)),
  laid out like retail's, read-only:
  - **Your own tabs** sort items by category (Equipment, Consumables, Trade Goods, Reagents,
    Recipes, Miscellaneous). Add one with **+**; right-click a tab, or the gear by its title, to
    rename it, pick its icon and choose what it shows. An item in no tab appears under **Other**.
  - **Single** shows one tab, **Combined** three side by side.
  - **Personal Bank** shows the character you're on; **Warband** shows every character, filtered
    by **ruleset** (your current one by default, or All, Normal, PvP, RP, Hardcore). Hidden
    characters are left out, as from the sheet's totals.
  - Tabs are settings on this account; nothing about them is synced, and no item moves.
  - The window grows to fit the tab when you open it, whichever tab you came from.

## v0.5.0-beta

Hunter pets and warlock demons in the Roster's campfire scene. Measured on client 1.60.1.70170.
The sync wire is unchanged; the pet travels as three new fields that a v0.4.x peer stores and passes
on without reading.

### AltStable Companion

The Roster's character portraits come from **AltStable Companion**, a free Windows app that turns
your `/alts portrait` captures into the transparent cutouts the scene draws (and can enhance them).
Without it, the scene has no one to show. Get it from
[AltStable Companion releases](https://github.com/Spotnick2/AltStableCompanion/releases).

### New

- **Pets in the Roster scene** ([#75](https://github.com/Spotnick2/AltStable/issues/75)): a hunter's
  beast or a warlock's demon stands with its owner, as on the retail warband screen. Off by
  default: **Options > Presentation > "Show hunter pets and warlock demons in the Roster scene"**.
  - Drawn live from the pet's saved look, so it needs no portrait capture, and it keeps its idle
    animation (its particle effects, like an imp's fel fire, are left out).
  - A character's pet is the **last one they had out**; summon a different one and the scene
    follows. An alt's pet arrives with sync like the rest of its record.
  - Pets keep their true size against their owners: a cat comes to a night elf's hip, a voidwalker
    towers over a gnome.
  - With pets shown, **four** stand at the fire instead of five, to leave them room. Pets beside the
    fire turn toward it; the outermost stand at the scene's edges, a little further back.
  - New saved fields, flat and synced: `pet_display`, `pet_npc`, `pet_name`.

### Under the hood

- Measured on client **1.60.1.70170**: the login warning about a different build is gone on it.
  The API changes in this build touch nothing AltStable uses.

## v0.4.0-beta

Your accounts sync through Battle.net, sync asks before it shares, a Professions
tab, and portrait capture in the addon. Measured on client 1.60.1.70124. The
sync wire is unchanged, so a peer on v0.3.x still syncs by whisper; syncing
through Battle.net needs both accounts on v0.4.0. New saved data is listed below;
nothing existing changed shape.

- **Your other accounts sync by themselves - any ruleset, any faction.** Two of
  your WoW accounts on the same Battle.net account now find each other through
  Battle.net and sync with no whitelist and nothing to type, including a Horde
  account with an Alliance one and across rulesets, which whispers cannot do.
  "Found your other account: ..." says when it happens; Options has an off
  switch. Once two accounts have met, they keep finding each other even when
  Battle.net is slow to show who is playing on either. Battle.net friends are never included
  ([#58](https://github.com/Spotnick2/AltStable/issues/58)).
- **Sync is sturdier when pieces arrive out of order.** A finishing message that
  overtakes the data no longer loses the sync, a stream completes the moment its
  last piece arrives, and a character seen with and without its realm is one
  peer.
- **Sync no longer loses pieces to the server's message throttle.** The bundled
  ChatThrottleLib is updated from v24 to v32: on this client the server can
  refuse an addon message it considers too fast, and v24 treated the refused
  piece as sent - the other side then reported chunks missing and asked again.
  v32 waits and retries.

- **`/alts sync` to someone unreachable no longer floods the chat.** A
  character offline, or online on the other faction (addon messages do not
  cross factions), used to produce one "No player named..." line per piece of
  the database. Now AltStable asks first, sends nothing more if they cannot be
  reached, and says so once - "X is Alliance and you are Horde" when it knows.
  The server's echo of AltStable's own messages is hidden, including the one a
  login request to an offline peer used to leave.
- **Sync asks before it shares, and before it takes.** Someone you have not
  allowed who asks for your characters gets a prompt on your side - Allow, Not
  now, Never; Escape is Not now - and Options has a *Requests and answers* list
  to change any answer later. Characters sent to you are taken only from people
  you allowed, or asked yourself in the last ten minutes; anything else is
  dropped with one line. `/alts sync <name>` counts as your consent for that
  exchange and refuses anyone set to never. An answer is by name: it covers
  the character whatever realm suffix they arrive with, on every ruleset you
  play ([#61](https://github.com/Spotnick2/AltStable/issues/61)).
- **The Roster can show an enhanced portrait.** When the companion app has
  made one (optional, its own feature), the scene, grid and detail views draw
  it in place of the plain capture; anything malformed falls back to the plain
  portrait. The contract for it is in `docs/PORTRAIT-CONTRACT.md`
  ([AltStableCompanion#17](https://github.com/Spotnick2/AltStableCompanion/issues/17)).
- **The capture button tells you when a portrait is due.** It glows when the
  character you are playing has no portrait yet, or when the gear a portrait
  shows changed since the last capture - not rings, trinkets, the neck or the
  ranged slot, but showing or hiding the helm or cloak does count; its
  tooltip says which. A capture waiting for the converter does not glow. Never
  in combat; `/alts portrait glow off` turns it off. Other addons can ask too:
  `AltStable.GetPortraitStatus()` and a `PortraitStatusChanged` callback
  ([#128](https://github.com/Spotnick2/AltStable/issues/128)).
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
  portraits happens outside the game, with the free
  [AltStable Companion](https://github.com/Spotnick2/AltStableCompanion/releases)
  app for Windows
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
