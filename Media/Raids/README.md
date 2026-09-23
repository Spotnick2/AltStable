# Raid row-band art (`Media/Raids/`)

Dim landmark artwork drawn behind each row of the **Raids** plugin
(`Plugins/Instances/AltTrackerInstances.lua`). One TGA per raid, cover-cropped to
a wide, short band with the raid name overlaid on the left.

## Source

These are **derived from existing masters**, not generated per-addon:

    C:\Projects\WowClassicRaids\assets\raid-image-masters\<slug>-master.png

The masters are ~2172×724 (≈3:1) `srgb` PNGs. Do not edit them in place — always
re-derive the TGA from the master.

## Format (same hard rules as `Media/Scene/`)

- **TGA, 32-bit RGBA** (`TrueColorMatte`), **uncompressed**, **power-of-two 1024×512**.
  24-bit or non-POT textures render **black** in WoW.
- The aspect-preserved image sits in the **top 341 rows**; the bottom is
  **black-padded** to 512. The plugin samples only the top `341/512` of the
  texture (`BAND_VSCALE`) and cover-crops the content into the row band, so the
  pad never shows and the landmark isn't distorted.
- **Fresh filename whenever pixels change** — WoW caches textures by path; a
  `/reload` won't re-read an overwritten file (bump the name or restart the client).

## Convert (ImageMagick 7)

    magick <slug>-master.png \
      -resize 1024x -background black -gravity north -extent 1024x512 \
      -alpha set -type TrueColorMatte -compress none \
      scene-raid-<id>.tga

Sanity-check → must print `1024x512 srgba 4.0`:

    magick identify -format "%wx%h %[channels]\n" scene-raid-<id>.tga

## id ↔ master map (the 16 raids the plugin ships)

| id (`RAIDS[].art`) | master slug            | raid                     |
|--------------------|------------------------|--------------------------|
| kara               | karazhan               | Karazhan                 |
| gruul              | gruuls-lair            | Gruul's Lair             |
| mag                | magtheridons-lair      | Magtheridon's Lair       |
| ssc                | serpentshrine-cavern   | Serpentshrine Cavern     |
| tk                 | tempest-keep           | Tempest Keep             |
| hyjal              | mount-hyjal            | Battle for Mount Hyjal   |
| bt                 | black-temple           | Black Temple             |
| za                 | zul-aman               | Zul'Aman                 |
| sunwell            | sunwell-plateau        | Sunwell Plateau          |
| mc                 | molten-core            | Molten Core              |
| ony                | onyxias-lair           | Onyxia's Lair            |
| bwl                | blackwing-lair         | Blackwing Lair           |
| zg                 | zul-gurub              | Zul'Gurub                |
| aq20               | ruins-of-ahn-qiraj     | Ruins of Ahn'Qiraj       |
| aq40               | temple-of-ahn-qiraj    | Temple of Ahn'Qiraj      |
| naxx               | naxxramas-classic      | Naxxramas                |

Batch-convert all 16 from a Bash shell (Git Bash):

    M="C:\Projects\WowClassicRaids\assets\raid-image-masters"
    declare -A MAP=( [kara]=karazhan [gruul]=gruuls-lair [mag]=magtheridons-lair \
      [ssc]=serpentshrine-cavern [tk]=tempest-keep [hyjal]=mount-hyjal [bt]=black-temple \
      [za]=zul-aman [sunwell]=sunwell-plateau [mc]=molten-core [ony]=onyxias-lair \
      [bwl]=blackwing-lair [zg]=zul-gurub [aq20]=ruins-of-ahn-qiraj \
      [aq40]=temple-of-ahn-qiraj [naxx]=naxxramas-classic )
    for id in "${!MAP[@]}"; do
      magick "$M/${MAP[$id]}-master.png" -resize 1024x -background black -gravity north \
        -extent 1024x512 -alpha set -type TrueColorMatte -compress none "scene-raid-$id.tga"
    done

## Registration & deploy

- Each raid's `art` id is set in the `RAIDS` table in
  `Plugins/Instances/AltTrackerInstances.lua`. A raid with no matching TGA (or an
  "Other" row) falls back to a plain dark band automatically.
- `Tools/deploy.ps1` ships `*.tga` and excludes `*.png`/`*.md` — run
  `pwsh Tools/deploy.ps1`, then `/reload`. If a replaced-in-place band still shows
  black, restart the client to flush the texture cache.
