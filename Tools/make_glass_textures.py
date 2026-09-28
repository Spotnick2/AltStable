"""Generate the glass material textures into Media/ as uncompressed 32-bit TGA.

    python Tools/make_textures.py

The generator is the source of truth; the .tga files are committed outputs.

Conventions, all chosen to avoid edge halos and to keep colour a runtime decision:
- Overlay textures (rim, gloss, sheen, grain, shadow) are a single RGB colour
  everywhere, with the shape carried only in alpha. Colour comes from
  SetVertexColor / SetStatusBarColor at runtime.
- Mask textures are white-on-black in RGB *and* alpha, so they work whichever
  channel the client samples (loaded with CLAMPTOBLACKADDITIVE wrap).
- Rounded-rect textures are designed for 9-slicing: the corner radius sits
  inside the slice margin, noted per texture below and mirrored in the Lua.
- Power-of-two sizes, bottom-left origin (the most common TGA layout).
"""

import os
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Media/Glass, not Media: this addon keeps the material's art apart from its own
# icons and cutouts. Renaming the script without changing this regenerates into
# the wrong folder and silently leaves the real textures stale.
OUT = os.path.join(ROOT, "Media", "Glass")


def write_tga(name, rgba):
    """rgba: float array (h, w, 4) in 0..1, row 0 = top."""
    h, w, _ = rgba.shape
    assert w & (w - 1) == 0 and h & (h - 1) == 0, f"{name}: not power of two"
    px = (np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8)
    bgra = px[::-1, :, [2, 1, 0, 3]]            # flip to bottom-left origin, RGBA -> BGRA
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    w & 255, w >> 8, h & 255, h >> 8, 32, 0x08])
    with open(os.path.join(OUT, name + ".tga"), "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())
    print(f"  {name}.tga  {w}x{h}")


def rounded_rect_sdf(w, h, inset, radius):
    """Signed distance (px) to a rounded rect inset from the texture edge; negative inside."""
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    cx, cy = w / 2.0, h / 2.0
    hx, hy = w / 2.0 - inset, h / 2.0 - inset
    qx = np.abs(xs - cx) - (hx - radius)
    qy = np.abs(ys - cy) - (hy - radius)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def coverage(d, soft=0.75):
    """Antialiased fill from a signed distance: 1 inside, 0 outside."""
    return np.clip(0.5 - d / (2 * soft), 0, 1)


def band(d, lo, hi, soft=0.75):
    """Antialiased band where lo <= d <= hi (d negative inside)."""
    return coverage(d - hi, soft) * (1 - coverage(d - lo, soft))


def white(alpha):
    h, w = alpha.shape
    out = np.ones((h, w, 4))
    out[..., 3] = alpha
    return out


def black(alpha):
    out = white(alpha)
    out[..., :3] = 0
    return out


def mask(alpha):
    out = np.zeros(alpha.shape + (4,))
    out[..., 0] = out[..., 1] = out[..., 2] = out[..., 3] = alpha
    return out


def normals(d):
    gy, gx = np.gradient(d)
    n = np.hypot(gx, gy) + 1e-9
    return gx / n, gy / n


def glass_rim(size, radius, k, light=1.0):
    """The style-4 glass rim and its dark companion, at any size.

    k scales every distance (bevel width, lips, glints) from the 64px design,
    so a 32px, radius-7 texture with k=0.5 is the same material, smaller.
    light scales every highlight (not the dark companion).
    Returns (rim, dark) as RGBA float arrays.
    """
    d = rounded_rect_sdf(size, size, 0.5, radius)
    nx, ny = normals(d)
    top, bottom, left = np.maximum(-ny, 0), np.maximum(ny, 0), np.maximum(-nx, 0)
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    outer = band(d, -1.4 * k, -0.3 * k, 0.5) * (0.28 + 0.72 * top ** 0.5 + 0.35 * left ** 1.5 + 0.30 * bottom ** 2)
    inner = band(d, -7.6 * k, -6.6 * k, 0.5) * (0.14 + 0.45 * bottom ** 0.7 + 0.18 * top ** 2)
    vert = 1 - ys / size                          # 1 at the top, 0 at the bottom
    slab = band(d, -7.0 * k, -0.5 * k, 0.6) * (0.05 + 0.13 * vert ** 1.5 + 0.06 * top)
    glint = np.zeros_like(d)
    c = 6.5 * k                                   # glint centre: on the top corner arcs, near the outer lip
    for gx, gy in ((c, c), (size - c, c)):
        glint += np.exp(-(((xs - gx) ** 2 + (ys - gy) ** 2) / (2 * (2.2 * k) ** 2))) * 0.85
    glint *= band(d, -3.5 * k, -0.2 * k, 0.6)
    rim = white(np.clip(np.maximum.reduce([outer, inner, slab, glint]) * light, 0, 1))
    dark = black(np.clip(band(d, -0.6 * k, 0.3 * k, 0.5) * 0.45 + band(d, -8.8 * k, -7.6 * k, 0.6) * 0.18, 0, 1))
    return rim, dark


def main():
    os.makedirs(OUT, exist_ok=True)
    print("Writing", OUT)

    # Body mask: 64x64, radius 14, slice margins 16.
    d = rounded_rect_sdf(64, 64, 0.5, 14)
    write_tga("body_mask", mask(coverage(d)))

    # Bar mask: 32x32, radius 5, slice margins 8.
    d = rounded_rect_sdf(32, 32, 0.5, 5)
    write_tga("bar_mask", mask(coverage(d)))

    # Specular rim: 64x64, radius 14, slice margins 16.
    # A ~3px bevel band lit from the top-left, a fainter counter-highlight on
    # the bottom-right (glass catches light on both edges), and a thin inner line.
    d = rounded_rect_sdf(64, 64, 0.5, 14)
    nx, ny = normals(d)
    lx, ly = -0.70710678, -0.70710678           # light from top-left (y grows downward)
    facing = nx * lx + ny * ly
    light = 0.22 + 0.78 * np.maximum(facing, 0) ** 1.4 + 0.30 * np.maximum(-facing, 0) ** 2
    bevel = band(d, -3.2, 0.0) * light
    inner = band(d, -5.2, -4.4) * 0.28
    write_tga("rim", white(np.maximum(bevel, inner)))

    # Dark rim: a 1px outer line for contrast on bright scenery, plus a faint
    # inner shadow just inside the bevel. Same geometry as the rim.
    outer = band(d, -1.0, 0.0) * 0.55
    shade = band(d, -7.5, -3.2) * 0.18 * np.clip((-d - 3.2) / 4.3, 0, 1)[..., ] ** 0.5
    write_tga("rim_dark", black(np.maximum(outer, shade)))

    # Thin edge for the bars: 32x32, radius 5, slice margins 8.
    d = rounded_rect_sdf(32, 32, 0.5, 5)
    nx, ny = normals(d)
    facing = nx * lx + ny * ly
    edge = band(d, -1.2, 0.0) * (0.25 + 0.45 * np.maximum(facing, 0))
    write_tga("bar_edge", white(edge))

    # Drop shadow: 128x128, rect inset 32 with radius 14, blurred; slice margins 48.
    d = rounded_rect_sdf(128, 128, 32, 14)
    sigma = 9.0
    shadow = 1 / (1 + np.exp(d / (sigma * 0.55)))    # logistic falloff ~ gaussian-blurred edge
    write_tga("shadow", black(shadow * 0.55))

    # Gloss: 64x64, bright at the top, gone by ~55% height, plus a soft lip.
    ys = (np.arange(64) + 0.5) / 64.0
    g = np.clip(1 - ys / 0.55, 0, 1) ** 1.8 * 0.85
    lip = np.exp(-((ys - 0.08) / 0.05) ** 2) * 0.35
    col = np.maximum(g, lip)
    write_tga("gloss", white(np.tile(col[:, None], (1, 64))))

    # Bar fill: 64x16 grayscale ramp (alpha 1), lighter at the top. Colour comes
    # from SetStatusBarColor, which multiplies RGB.
    ys = (np.arange(16) + 0.5) / 16.0
    ramp = 1.0 - 0.22 * ys
    fill = np.ones((16, 64, 4))
    fill[..., 0] = fill[..., 1] = fill[..., 2] = np.tile(ramp[:, None], (1, 64))
    write_tga("bar_fill", fill)

    # Grain: 128x128 tileable noise, white with tiny alpha.
    rng = np.random.default_rng(1601)
    noise = rng.random((128, 128))
    write_tga("grain", white((noise ** 3) * 0.10))

    # Sheen: 256x64 diagonal soft streak for the animated highlight.
    ys, xs = np.mgrid[0:64, 0:256].astype(np.float64) + 0.5
    t = (xs - 128) + (ys - 32) * 0.6              # slanted distance from the centre line
    streak = np.exp(-(t / 26.0) ** 2) * 0.55 + np.exp(-((t - 34) / 7.0) ** 2) * 0.25
    fade = np.exp(-((ys - 32) / 40.0) ** 2)
    write_tga("sheen", white(streak * fade))

    # --- Style 2: "clear glass". Feedback on style 1: the rim read as a chrome
    # bezel (thick, opaque, evenly grey). Glass rims are thin and mostly clear:
    # a crisp highlight along the TOP edge, a faint one on the bottom, and a soft
    # glow just inside the edge where light refracts through the thickness.
    d = rounded_rect_sdf(64, 64, 0.5, 14)
    nx, ny = normals(d)
    top = np.maximum(-ny, 0)                    # 1 on the top edge, 0 on the sides/bottom
    bottom = np.maximum(ny, 0)
    left = np.maximum(-nx, 0)
    crisp = band(d, -1.4, -0.4, 0.5) * (0.12 + 0.88 * top ** 0.7 + 0.35 * left ** 2 + 0.30 * bottom ** 3)
    glow = np.exp(-np.maximum(-d - 1.0, 0) / 2.2) * (d < -0.6) * (0.10 + 0.14 * top + 0.06 * bottom)
    write_tga("rim2", white(np.clip(np.maximum(crisp, glow), 0, 1)))

    # Dark line for style 2: just a hairline outside the highlight, no inner shade.
    write_tga("rim_dark2", black(band(d, -0.6, 0.3, 0.5) * 0.40))

    # --- Style 3: "thick clear bevel", closer to the mockup: a ~7px slab that
    # is mostly transparent, with light only on its two edges (outer and inner
    # lip), strongest along the top, and a whisper of fill so it reads as solid.
    outer_lip = band(d, -1.3, -0.3, 0.5) * (0.20 + 0.80 * top ** 0.6 + 0.30 * left ** 2 + 0.25 * bottom ** 2)
    inner_lip = band(d, -7.6, -6.6, 0.5) * (0.10 + 0.25 * bottom ** 0.8 + 0.20 * top ** 2)
    slab = band(d, -7.0, -0.5, 0.6) * (0.06 + 0.10 * top)
    write_tga("rim3", white(np.clip(np.maximum.reduce([outer_lip, inner_lip, slab]), 0, 1)))
    shade3 = band(d, -0.6, 0.3, 0.5) * 0.40 + band(d, -8.8, -7.6, 0.6) * 0.22
    write_tga("rim_dark3", black(np.clip(shade3, 0, 1)))

    # --- Style 4: style 3 with more light, after owner feedback that the bevel
    # read flat next to the mockup. Brighter outer lip along the top, a real
    # catch-light on the inner lip at the bottom (light passing through the
    # slab), a slab that brightens toward the top, and small specular glints
    # where the top edge turns into the corners.
    rim4, dark4 = glass_rim(64, 14, 1.0)
    write_tga("rim4", rim4)
    write_tga("rim_dark4", dark4)

    # Small variants of the style-4 material, for frames too short for 16px
    # slice margins (cast pill, pet, target-of-target): 32x32, radius 7,
    # bevel scaled by 0.5, slice margins 8.
    rim, dark = glass_rim(32, 7, 0.5)
    write_tga("rim4_small", rim)
    write_tga("rim_dark4_small", dark)
    write_tga("body_mask_small", mask(coverage(rounded_rect_sdf(32, 32, 0.5, 7))))
    d = rounded_rect_sdf(64, 64, 16, 7)
    write_tga("shadow_small", black(0.50 / (1 + np.exp(d / (5.0 * 0.55)))))

    # Style 5 = style 4 after an outside design review (2026-09-27): "thick and
    # bright enough to look like a clear plastic case". Same material, bevel at
    # 0.72x width and highlights at 0.8x. The glass content inset follows the
    # bevel: 6px on large frames, 3px on small (Glass.SIZES in Glass.lua).
    for name, size, radius, k in (("rim5", 64, 14, 0.72), ("rim5_small", 32, 7, 0.36)):
        rim, dark = glass_rim(size, radius, k, light=0.8)
        write_tga(name, rim)
        write_tga(name.replace("rim5", "rim_dark5"), dark)

    # Softer, narrower sheen that does not wash out text.
    ys, xs = np.mgrid[0:64, 0:256].astype(np.float64) + 0.5
    t = (xs - 128) + (ys - 32) * 0.6
    streak = np.exp(-(t / 16.0) ** 2) * 0.32 + np.exp(-((t - 22) / 4.0) ** 2) * 0.22
    write_tga("sheen2", white(streak * np.exp(-((ys - 32) / 40.0) ** 2)))

    # Late-file check: only deployed on a second pass, to see whether /reload
    # picks up a texture file that did not exist when the client started.
    write_tga("late", white(np.ones((32, 32))))


if __name__ == "__main__":
    main()
