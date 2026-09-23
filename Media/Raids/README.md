# Raid thumbnails

One landmark image per raid, shown in the name cell of each row in the Raids tab
(`Plugins/Instances/AltStableInstances.lua`).

## What ships here

Seven files, one per Vanilla raid. The name is `scene-raid-<art>.tga`, where
`<art>` is the `art` field of the matching entry in that file's `RAIDS` table:

| art | Raid |
|---|---|
| `mc` | Molten Core |
| `ony` | Onyxia's Lair |
| `bwl` | Blackwing Lair |
| `zg` | Zul'Gurub |
| `aq20` | Ruins of Ahn'Qiraj |
| `aq40` | Temple of Ahn'Qiraj |
| `naxx` | Naxxramas |

The nine Outland raids the TBC version carried are gone: Forever is Vanilla
content, so those rows no longer exist (#11).

## The format the plugin expects

The shipped files are **512×256, 32-bit uncompressed TGA**, with the image in the
**top two thirds** (roughly 170 rows) and black padding below.

That shape is not arbitrary. WoW textures must have power-of-two dimensions, but
the artwork is a ~3:1 landscape strip, so it sits in the top of a 2:1 texture and
the rest is padding the plugin never samples. `BAND_IMG_W` / `BAND_IMG_H` /
`BAND_TEX_H` in the plugin describe exactly that, and only their **ratios**
matter — art at 1024×512 with content in the top 341 rows crops identically.

Checks, before committing a replacement:

```bash
# dimensions must be powers of two, and the ratio must match the constants
python -c "d=open('scene-raid-mc.tga','rb').read(18); print(d[12]|d[13]<<8, 'x', d[14]|d[15]<<8)"
# -> 512 x 256
```

A file that fails to load renders nothing at all: `LoadTexture` in the plugin
checks `GetTexture()` after setting it and clears the texture on failure, so a
bad path or an unsupported format leaves a plain band rather than a green box.

## Making one

Any 3:1 landscape capture works. Scale it to 512 wide, then pad the bottom to
256 with black:

```bash
magick input.png -resize 512x -background black -gravity north -extent 512x256 \
       -type TrueColorAlpha -compress none scene-raid-<art>.tga
```

Uncompressed matters: WoW does not read RLE-compressed TGA reliably.
