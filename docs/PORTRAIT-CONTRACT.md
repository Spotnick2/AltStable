# The portrait contract

What the addon writes when it captures a portrait, and what a converter writes
back for the Roster to draw. The Tools/RenderCutout converter reads it today; the
companion app (#89) will be built against it. **Change a field here and you change what
every converter must parse — bump `version`.**

The pipeline, end to end:

```
in game     /alts portrait (or the sheet's title-bar button)
              -> two screenshots, black then white backdrop, same frozen pose
              -> two records in AltStablePortraits
              -> the player accepts "Reload" (or logs out): the records reach disk
outside     a converter pairs the records with the screenshots, mattes each pair
              -> AltStableCutouts\Cutouts\<file>.tga + CutoutManifest.lua
in game     the Roster reads AltStableCutoutManifest and draws the cutouts
```

An addon can neither write an image nor read the Screenshots folder, which is
why the middle step is outside the game.

---

## 1. The capture records (addon → converter)

**Where.** `<WoW>\_classic_beta_\WTF\Account\<ACCOUNT>\SavedVariables\AltStable.lua`,
one per account. A machine with several accounts has several files, and all of
them write screenshots into the **same** Screenshots folder, so read every
account's file.

**When.** SavedVariables are written on `/reload` and on logout, never between.
The screenshots hit the disk at once; the records only later. The addon offers a
reload after every capture for this reason. A converter that finds screenshots
newer than any record should say "reload in game", not "no capture".

**The table.** A top-level global in that file, alongside `AltStableDB` and
`AltStableConfig` (which are large and unrelated — locate the `AltStablePortraits
= {` assignment at the start of a line before looking for `["renders"]`):

```lua
AltStablePortraits = {
    ["version"] = 1,
    ["facing"] = 20,            -- optional; degrees, only present once changed
    ["renders"] = {
        {
            ["name"] = "Karuzo Elegia",       -- full name, surname included
            ["guid"] = "Player-4395-0A1B2C3D", -- the identity
            ["race"] = "Scourge",              -- race token
            ["raceLoc"] = "Undead",            -- localised race
            ["class"] = "PRIEST",              -- class token
            ["sex"] = 3,                       -- UnitSex: 2 male, 3 female
            ["level"] = 60,
            ["shot"] = 1,                      -- 1 = black backdrop, 2 = white
            ["stamp"] = "2026-09-29 14:02:11", -- LOCAL time, date("%Y-%m-%d %H:%M:%S")
            ["epoch"] = 1790690531,            -- time(): seconds since 1970, UTC
            ["screenW"] = 3840,                -- GetPhysicalScreenSize: PHYSICAL pixels
            ["screenH"] = 2160,
            ["uiScale"] = 0.7111111283302307,
        }, -- [1]
        -- ... one record per screenshot, appended in order
    },
}
```

**Absent means "no captures", never "malformed".** All of these are normal and
must be read as an empty store:

- no `AltStable.lua` for that account;
- `AltStablePortraits = nil` — what the client writes for an account that has
  never captured (the table is created on the first capture). **Measured** on
  1.60.1.70009: after a logout on such an account the file ends with exactly
  that line; a declared SavedVariable that is nil is written out, not omitted;
- no `AltStablePortraits` line at all — a file last written by a build that did
  not declare it;
- a table with an empty or missing `renders`.

A reader that finds the `AltStablePortraits =` line but no table after it must
stop there, not keep searching the file for a `["renders"]` key.

A file that stops mid-table (unbalanced braces) is being written right now: retry
shortly, do not treat it as data.

**Version.** `1` is described here. A reader that meets a version it does not know
**refuses the store** with a message ("update the converter"); it does not guess.

**Pairing rules.**

- Pair **within one file**: a shot `1` with the next shot `2` for the same `guid`.
  Never pair across accounts.
- A shot `1` with no following shot `2` is an abandoned capture; ignore it. (The
  addon removes the records of any capture it abandons, but a crash can still
  leave a lone one.)
- Two records with the **same `stamp`** are a collision: both shots landed in one
  second and one screenshot overwrote the other. Unrecoverable; report it and ask
  for a re-capture. The addon spaces its shots 1.1 s apart so this should not
  happen.
- Newest capture per character wins, ordered by **`epoch`**. `stamp` is local time
  and repeats an hour when the clocks go back; do not order by it.
- `renders` is append-only. Older captures stay in it.

**Matching records to screenshots.** The client names each screenshot
`Screenshots\WoWScrnShot_MMDDYY_HHMMSS.tga` in the same local time as `stamp`.

- Match each record's `stamp` to a file within **±4 seconds**, nearest first.
- The two files of a capture must be spaced as its two stamps are, **give or take
  one second**. The stamp is read when the shot is asked for and the file is named
  when it is written, so a second can tick in between for one shot and not the
  other; more than that is somebody else's file.
- **Each file is claimed at most once per pass.** A file wanted by two records is
  ambiguous for both: leave those captures pending and delete nothing. So is a
  stamp whose nearest files **tie** - two files equally near - and then the
  capture wants every file in the tie, not the one that happened to be listed
  first. (A capture's own two shots are about a second apart, so both always sit
  within tolerance of both stamps; that alone is not a tie. Nearest decides.)
  A record counts as wanting its files whatever else is wrong with its capture.
- A screenshot the client failed to write must not be replaced by whatever file
  sits nearby, a hand-taken screenshot included.
- **A converter that keeps screenshots keeps track of them.** The pair a cutout
  was made from stays that cutout's for as long as both exist - also after its
  character has captured again. It must not be matched to another capture whose
  own shots are missing. (The companion app records the two file names in the
  cutout's sidecar, as `shots`.)
- The addon switches `screenshotFormat` to TGA for the capture and refuses to
  capture if it cannot. Measured on this client, WoW writes **RLE-compressed**
  TGA (image type 10), 32-bit, top-left origin, with 0 alpha bits.
- Only files matched to a record may ever be deleted. Anything else in the
  folder belongs to the player.

**The matte.** Per pixel, from the black shot `b` and the white shot `w`:

```
alpha  = clamp(1 - ((w.r-b.r) + (w.g-b.g) + (w.b-b.b)) / 765, 0, 1)
colour = b / alpha            (un-premultiplied; alpha <= 0.02 is fully transparent)
```

Then crop to the non-transparent bounding box. Reject a pair that is more than
90 % opaque (the backdrop did not change: identical shots) or whose figure is 95 %
of the screen height or more (something else was matted in). Reference
implementation: `Tools/RenderCutout/make-cutout.py`.

---

## 2. The cutouts (converter → Roster)

**Where.** A separate, generated addon folder: `Interface\AddOns\AltStableCutouts\`.
It has to be separate: a Lua file dropped into `AltStable\` is never loaded
unless the committed `.toc` lists it, and a deploy would overwrite it.

The client only discovers a **new addon folder** at startup. The first time the
folder is created the player has to quit the game completely and start it again;
after that `/reload` picks up new cutouts.

**`AltStableCutouts.toc`:**

```
## Interface: 16001
## Title: AltStable Cutouts
## Notes: Character portraits captured locally by AltStable. GENERATED by AltStable Companion - delete this folder to start over.
## IconTexture: 8197123
## Dependencies: AltStable
## Author: generated
## Version: 1

CutoutManifest.lua
```

`Interface`, `Dependencies` and the file list are what the client acts on and must be
as above. `Notes` names whichever converter wrote the file (`Update-Cutouts.ps1`
writes its own); `IconTexture` is there because an addon without one shows a red
question mark in the addon list.

**`CutoutManifest.lua`** defines one global:

```lua
AltStableCutoutManifest = {
    ["Player-4395-0A1B2C3D"] = {
        guid = "Player-4395-0A1B2C3D",
        file = [[Interface\AddOns\AltStableCutouts\Cutouts\karuzo-elegia.tga]],
        w = 146, h = 512,          -- content size in pixels
        texw = 256, texh = 512,    -- the power-of-two canvas it sits in, top-left
        nativeW = 0.08333, nativeH = 0.58333,  -- optional: fraction of screen height
    },
    -- legacy entries, keyed by name slug (written before entries carried a guid):
    ['karuzo-elegia'] = { file = [[...]], w = 146, h = 512, texw = 256, texh = 512 },
}
```

**Identity is the GUID.** The Roster looks up `manifest[char.guid]` first, then
falls back to `manifest[slug(char.name)]` for entries written before this
contract. A slug-keyed entry that carries a `guid` field is only used for that
GUID. Two characters that share a name never show each other's portrait.

**The slug** (file names, legacy keys): lowercase the name, turn every run of
characters outside `a-z0-9` into `-`, trim `-` from both ends. `"Karuzo Elegia"`
becomes `karuzo-elegia`. It must match `Slug()` in
`Plugins/Roster/AltStableRoster.lua` exactly.

**The file name** is the slug, with three exceptions. They only decide what a file
is called: the Roster finds a portrait by its GUID and reads the name from `file`.

| When | The file is named | Example |
|---|---|---|
| Another character's file already has that name | `<slug>-<last 6 characters of its guid>`, lowercased | `twin-name-bbbbbb.tga` |
| That name is another character's too (a third namesake whose GUID ends in the same six) | `<slug>-<slug of its whole guid>` | `twin-player-3-00bbbbbb.tga` |
| The slug is empty (a name with nothing in `a-z0-9`: Cyrillic, Korean, Chinese) | `<slug of its guid>` | `player-4395-0a1b2c3d.tga` |

A file that holds a character's portrait keeps its name when the character is
captured again.

**What may go into the manifest.** Keys, GUIDs and file names are written between
quotes and long brackets as they are, so a converter writes only ones made of
letters, digits, `-` and `_` (and `.` in a file name). Anything else is left out of
the manifest, not escaped: a TGA named `o'brien.tga` is otherwise a syntax error
that loses every portrait, and a GUID comes from a file anyone can edit. A record
whose `guid` has other characters is not a record.

**The image.** 32-bit uncompressed TGA, content pasted top-left on a canvas whose
sides are powers of two, bottom-left origin (descriptor `0x08`) like the files
already known to load. The Roster reads only `file`, `w`, `h`, `texw`, `texh`;
it computes figure heights from race, not from the image.

An entry counts only when `file` is a non-empty string.
