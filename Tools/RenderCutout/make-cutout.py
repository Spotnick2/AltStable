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

The client gives back no partial alpha at all, so the raw cutout has hard,
aliased edges. The capture is far larger than any scene draws it, so it is
resampled down here to manufacture the coverage the client refused to produce -
premultiplied first, or every edge pixel averages with transparent black and
leaves a dark halo.

Writes a 32-bit uncompressed TGA, padded to a power of two (WoW reloads those
reliably), plus the content dimensions the UI needs to crop it back.
"""

import argparse
import os
import re
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("Pillow is required:  python -m pip install pillow")

SHOTS = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Screenshots"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"


def latest_capture(wtf=WTF):
    """Who the addon photographed last, from AltStableProbe's SavedVariables.

    Beats a hand-typed name: the file is named after the character it actually
    shows, so a capture cannot be filed under the wrong alt. Returns None when
    the store has not been written yet - the client only flushes it on logout
    or /reload, so a fresh capture may not be on disk at all.
    """
    newest, newest_time = None, -1
    for root, _dirs, files in os.walk(wtf):
        for f in files:
            if f == "AltStableProbe.lua":
                full = os.path.join(root, f)
                t = os.path.getmtime(full)
                if t > newest_time:
                    newest, newest_time = full, t
    if not newest:
        return None
    try:
        text = open(newest, encoding="utf-8", errors="replace").read()
    except OSError:
        return None

    block = re.search(r'\["renders"\]\s*=\s*\{(.+)', text, re.S)
    if not block:
        return None
    # Every entry carries a name; the last one is the most recent capture.
    names = re.findall(r'\["name"\]\s*=\s*"([^"]+)"', block.group(1))
    return names[-1] if names else None


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

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


# The client renders with NO partial alpha - every pixel comes back fully
# opaque or fully clear (measured on 1.60.1.70009). So the cutout has hard,
# aliased edges, and scaling it in the UI makes them crawl.
#
# The fix is supersampling: the capture is already much larger than the size a
# scene draws it at, so resampling it down HERE manufactures the intermediate
# coverage the client refused to give us. Done properly it is exact, offline,
# free, and needs no model.
#
# Premultiplying first is what makes it correct. Resampling straight alpha
# averages each edge pixel with the transparent black around it and leaves a
# dark halo - the classic mistake. Multiply colour by coverage, resample, then
# divide it back out.
TARGET_HEIGHT = 512


def supersample(img, target_h):
    w, h = img.size
    if target_h <= 0 or h <= target_h:
        return img, False

    nw = max(1, int(round(w * target_h / float(h))))
    nh = target_h

    r, g, b, a = img.split()
    premul = Image.merge("RGBA", (
        ImageChops.multiply(r, a),
        ImageChops.multiply(g, a),
        ImageChops.multiply(b, a),
        a,
    ))
    premul = premul.resize((nw, nh), Image.LANCZOS)

    out = Image.new("RGBA", (nw, nh), (0, 0, 0, 0))
    src, dst = premul.load(), out.load()
    for y in range(nh):
        for x in range(nw):
            pr, pg, pb, pa = src[x, y]
            if pa == 0:
                continue
            # Undo the premultiply. Values can round a shade over 255 on a
            # bright edge; clamp rather than wrap.
            f = 255.0 / pa
            dst[x, y] = (
                min(255, int(pr * f + 0.5)),
                min(255, int(pg * f + 0.5)),
                min(255, int(pb * f + 0.5)),
                pa,
            )
    return out, True


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=SHOTS, help="the client's Screenshots folder")
    ap.add_argument("--name", default=None,
                    help="base name for the output (default: the character the addon last photographed)")
    ap.add_argument("--keep-png", action="store_true", help="also write a PNG to eyeball")
    ap.add_argument("--target-height", type=int, default=TARGET_HEIGHT,
                    help="supersample down to this content height for antialiased edges "
                         "(0 keeps the capture at native size)")
    args = ap.parse_args()

    black, white = newest_pair(args.shots)
    print("black backdrop :", os.path.basename(black))
    print("white backdrop :", os.path.basename(white))

    cut = matte(black, white)
    print("content        : %dx%d" % cut.size)

    cut, resampled = supersample(cut, args.target_height)
    if resampled:
        print("supersampled   : %dx%d  (edges antialiased)" % cut.size)
    cw, ch = cut.size

    os.makedirs(OUT, exist_ok=True)
    base = args.name
    if not base:
        who = latest_capture()
        if who:
            base = slug(who)
            print("character      :", who)
        else:
            base = "cutout"
            print("character      : unknown (SavedVariables not written yet - "
                  "/reload in game, or pass --name)")

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
