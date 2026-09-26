# AltStable scene backdrops

Prepared artwork for a character-select / roster Scene view in WoW: Forever.
This folder contains **12 newly generated Forever scenes**, the **two unchanged
AltTracker originals** requested by the owner, and a WoW texture for every scene.

These assets are not registered in the addon yet. At preparation time AltStable has
no `SCENE_BACKDROPS` table or scene picker. Adding that UI is separate work.

## Inventory

| Scene | Source PNG | WoW texture | Reference |
|---|---|---|---|
| Felwood | [felwood-campsite.png](felwood-campsite.png) | `scene-felwood.tga` | [01](References/01-felwood.png) |
| Dustwallow Marsh | [dustwallow-campsite.png](dustwallow-campsite.png) | `scene-dustwallow.tga` | [02](References/02-dustwallow.png) |
| Ashenvale — dusk | [ashenvale-dusk-campsite.png](ashenvale-dusk-campsite.png) | `scene-ashenvale-dusk.tga` | [03](References/03-ashenvale-dusk.png) |
| Ashenvale — moonlight | [ashenvale-moonlight-campsite.png](ashenvale-moonlight-campsite.png) | `scene-ashenvale-moonlight.tga` | [04](References/04-ashenvale-moonlight.png) |
| Elwynn Forest | [elwynn-campsite.png](elwynn-campsite.png) | `scene-elwynn.tga` | [05](References/05-elwynn.png) |
| Mulgore — lake | [mulgore-campsite.png](mulgore-campsite.png) | `scene-mulgore.tga` | [06](References/06-mulgore.png) |
| Mulgore — Thunder Bluff | [thunder-bluff-campsite.png](thunder-bluff-campsite.png) | `scene-thunder-bluff.tga` | [07](References/07-thunder-bluff.png) |
| Zephyras Isle | [zephyras-isle-campsite.png](zephyras-isle-campsite.png) | `scene-zephyras-isle.tga` | [08](References/08-zephyras-isle.png) |
| Shen'Dralas | [shendralas-campsite.png](shendralas-campsite.png) | `scene-shendralas.tga` | [09](References/09-shendralas.png) |
| Riverglades | [riverglades-campsite.png](riverglades-campsite.png) | `scene-riverglades.tga` | [10](References/10-riverglades.png) |
| Mount Hyjal — cinematic | [mount-hyjal-campsite.png](mount-hyjal-campsite.png) | `scene-mount-hyjal.tga` | [11](References/11-mount-hyjal.png) |
| Forest Camp — copied original, initial image #8 | [roster-campsite.png](roster-campsite.png) | `scene-forest.tga` | AltTracker original |
| Dalaran | [dalaran-campsite.png](dalaran-campsite.png) | `scene-dalaran.tga` | [12](References/12-dalaran.png) |
| Karazhan — copied original, initial image #9 | [karazhan-campsite.png](karazhan-campsite.png) | `scene-karazhan.tga` | AltTracker original |

`References/` preserves all owner-supplied screenshots unchanged. Numbers 01–07
match the initial message; 08–11 match the four follow-up images in order.
Dalaran uses the owner's later full-resolution screenshot, `12-dalaran.png`;
the three smaller supplied views are preserved as `12-dalaran-small-1.png`
through `12-dalaran-small-3.png`. Related source: [wowreforged's Dalaran post](https://www.instagram.com/p/DdenQenjbmE/).
These screenshots are reference material, not finished backdrops: some contain
watermarks, NPCs, or cinematic framing.

The two originals were copied from `C:\Projects\AltTracker\Media\Scene`.
Their PNGs are byte-identical to the supplied files. Karazhan retains its original
smaller, slightly right-of-center fire; the new scenes use Forest Camp as their
common composition reference.

## Composition specification

- Source PNG: **1536 × 1024**, landscape **3:2**.
- Empty scene with no people, characters, or creatures.
- Broad, clear, dry center foreground for superimposed character models.
- Small orange campfire in a stone ring, low-center. Generation target:
  horizontal center **50%**, ground contact around **84%** of image height,
  flame top around **74%**. These are approximate art targets, not measured anchors.
- Recognizable zone scenery behind the camp, softened with atmospheric depth
  and depth of field. Target horizon near the lower third.
- Subtle dark edge vignette and warm fire illumination.
- Keep key content within the central area where possible so side crops remain useful.
- No text, UI, or watermark in generated scenes.
- Zone architecture, color and terrain follow the supplied Forever references.
  Mount Hyjal follows the cinematic reference.

Generated with the **built-in image generation tool** on 2026-09-25.
See [PROMPTS.md](PROMPTS.md) for the exact prompt and input mapping for every new scene.
Forest Camp supplies the fire placement and rendered style; each zone screenshot
supplies its environment. The outputs are artistic interpretations, not exact
reconstructions of in-game locations.

## WoW texture format

All `scene-*.tga` files use the format documented by AltTracker:

- **1024 × 1024**, uncompressed **32-bit RGBA**.
- Image resized to **1024 × 682** in the top rows.
- Remaining **342 rows** padded opaque black.
- Display only the content: full-image texture coordinates
  `u = 0..1`, `v = 0..682/1024` (**0.666015625**).

From the repository root, using ImageMagick 7:

```powershell
magick Media/Scene/felwood-campsite.png -resize '1024x682!' -background black -gravity north -extent 1024x1024 -alpha set -type TrueColorAlpha -depth 8 -compress none Media/Scene/scene-felwood.tga
magick identify -format "%f %wx%h %[channels]\n" Media/Scene/scene-*.tga
```

Expected texture identification: `1024x1024 srgba 4.0`.
The PNGs are retained as source artwork; the addon should load the TGAs.

AltTracker's README reports black textures with 24-bit/non-power-of-two exports
and stale pixels when overwriting a cached texture path. Preserve this known
working format. Use a new texture filename when changing pixels, or fully restart
the client. These new exports have been validated on disk, **not in the Forever client**.

## Future integration and testing

A future scene renderer can use an entry shaped like the upstream renderer's:

```lua
{ id = "felwood", label = "Felwood",
  file = "Interface\\AddOns\\AltStable\\Media\\Scene\\scene-felwood.tga",
  w = 1024, h = 682, texh = 1024 },
```

This is an integration example, not an existing AltStable registration point.
The renderer must remap vertical texture coordinates by `h / texh` after computing
its content crop, so padding is never displayed.

### Fire anchors are measured, not assumed

The composition target below (centre 50%, base ~84%) is what the scenes were
*commissioned* to; it is not what they are. `SCENE_BACKDROPS` carries a measured
`fireX`/`fireBaseY` per backdrop, produced by:

```
python Tools/Scene/find-fire.py
```

which finds the brightest warm mass in the lower half of each TGA and prints the
numbers in Lua table form. The generated scenes land between 0.487 and 0.510
horizontally and 0.802 to 0.850 vertically; **Karazhan measures 0.551 / 0.900**,
because it is an AltTracker original that predates the spec. Run it again after
adding or regenerating a backdrop, and paste the line into the table - the scene
view stands the cast around that point, so a wrong anchor puts the keep-out gap
on empty ground.

Once integrated, deploy with `pwsh Tools/deploy.ps1`, then test:

1. Every texture loads, including after a reload and full client restart.
2. Narrow and wide panels keep the fire visible and hide all bottom padding.
3. Character feet align with the ground and models remain readable against the scene.
4. Bright daytime scenes and dark swamp scenes both work with the UI overlays.

Only artwork and documentation were added for this task; addon code, deployment
rules, and packaging rules were left unchanged.
