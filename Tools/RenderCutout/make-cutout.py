"""make-cutout.py — turn two staged screenshots into one transparent cutout.

The addon (`/asrender`) photographs the live character twice in an identical
frozen pose: once on a BLACK backdrop, once on WHITE. That pair is enough to
recover exact alpha, which a chroma key cannot do:

    alpha  = 1 - (white - black)          per channel, averaged
    colour = black / alpha                un-premultiplied

Hair, capes and blended edges come out right, and there is no key colour left
fringing the silhouette.

Usage
-----
    python Tools/RenderCutout/make-cutout.py                 # newest pair
    python Tools/RenderCutout/make-cutout.py --name Kaleid   # name the output
    python Tools/RenderCutout/make-cutout.py --keep-png      # also leave a PNG

Writes a 32-bit uncompressed TGA, padded to a power of two (WoW reloads those
reliably), plus the content dimensions the UI needs to crop it back.
"""

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  python -m pip install pillow")

SHOTS = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Screenshots"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# Below this coverage a pixel is background, not a faint edge. Screenshots are
# lossless TGA, so this only has to reject sensor-free noise, not compression.
ALPHA_FLOOR = 0.02


def newest_pair(folder):
    """The two most recent screenshots, oldest first (black shot, then white)."""
    files = [
        os.path.join(folder, f)
        for f in os.listdir(folder)
        if f.lower().endswith((".tga", ".png", ".jpg", ".jpeg"))
    ]
    if len(files) < 2:
        sys.exit("need at least two screenshots in %s" % folder)
    files.sort(key=os.path.getmtime)
    black, white = files[-2], files[-1]
    if black.lower().endswith((".jpg", ".jpeg")):
        print("!! these are JPEGs - run /console screenshotFormat tga and retry")
    return black, white


def matte(black_path, white_path):
    """Recover colour+alpha from the same pose shot on two backdrops."""
    b = Image.open(black_path).convert("RGB")
    w = Image.open(white_path).convert("RGB")
    if b.size != w.size:
        sys.exit("the two shots differ in size (%s vs %s)" % (b.size, w.size))

    bp, wp = b.load(), w.load()
    width, height = b.size
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    op = out.load()

    minx, miny, maxx, maxy = width, height, -1, -1

    for y in range(height):
        for x in range(width):
            br, bg, bb = bp[x, y]
            wr, wg, wb = wp[x, y]
            # Coverage: an opaque pixel reads the same on both backdrops, a fully
            # transparent one differs by the full 255.
            a = 1.0 - ((wr - br) + (wg - bg) + (wb - bb)) / (3.0 * 255.0)
            if a <= ALPHA_FLOOR:
                continue
            a = min(1.0, a)
            # The black shot is already premultiplied by coverage; undo that.
            r = min(255, int(br / a + 0.5))
            g = min(255, int(bg / a + 0.5))
            bl = min(255, int(bb / a + 0.5))
            op[x, y] = (r, g, bl, int(a * 255 + 0.5))

            if x < minx: minx = x
            if y < miny: miny = y
            if x > maxx: maxx = x
            if y > maxy: maxy = y

    if maxx < 0:
        sys.exit("nothing but backdrop in those two shots - was the stage showing?")
    return out.crop((minx, miny, maxx + 1, maxy + 1))


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=SHOTS, help="the client's Screenshots folder")
    ap.add_argument("--name", default=None, help="base name for the output")
    ap.add_argument("--keep-png", action="store_true", help="also write a PNG to eyeball")
    args = ap.parse_args()

    black, white = newest_pair(args.shots)
    print("black backdrop :", os.path.basename(black))
    print("white backdrop :", os.path.basename(white))

    cut = matte(black, white)
    cw, ch = cut.size
    print("content        : %dx%d" % (cw, ch))

    os.makedirs(OUT, exist_ok=True)
    base = args.name or "cutout"

    if args.keep_png:
        png = os.path.join(OUT, base + ".png")
        cut.save(png)
        print("wrote          :", png)

    # WoW wants power-of-two textures to reload reliably; the real image sits in
    # the top-left and the UI crops back to the content size below.
    canvas = Image.new("RGBA", (pot(cw), pot(ch)), (0, 0, 0, 0))
    canvas.paste(cut, (0, 0))
    tga = os.path.join(OUT, base + ".tga")
    canvas.save(tga, compression=None)
    print("wrote          :", tga, "(%dx%d)" % canvas.size)
    print()
    print("manifest entry:")
    print('  { file = "Interface\\\\AddOns\\\\AltStable\\\\Media\\\\Cutouts\\\\%s.tga",' % base)
    print("    w = %d, h = %d, texw = %d, texh = %d }," % (cw, ch, canvas.size[0], canvas.size[1]))


if __name__ == "__main__":
    main()
