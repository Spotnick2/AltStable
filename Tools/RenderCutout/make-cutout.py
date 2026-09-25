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
    python Tools/RenderCutout/make-cutout.py --all           # every capture, by character
    python Tools/RenderCutout/make-cutout.py --name Kaleid   # name the output
    python Tools/RenderCutout/make-cutout.py --keep-png      # also leave a PNG

The client gives back no partial alpha at all, so the raw cutout has hard,
aliased edges. The capture is far larger than any scene draws it, so it is
resampled down here to manufacture the coverage the client refused to produce -
premultiplied first, or every edge pixel averages with transparent black and
leaves a dark halo.

Writes a 32-bit uncompressed TGA, padded to a power of two (WoW reloads those
reliably), plus the content dimensions the UI needs to crop it back.

Staged screenshots are DELETED once their cutout is written - two per capture
at 1-2 MB each adds up fast. Only files that matched a capture the addon
recorded are ever removed, so a screenshot taken by hand is never touched.
Pass --keep-shots to leave them.
"""

import argparse
import datetime
import glob
import os
import re
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("Pillow is required:  python -m pip install pillow")

try:
    import numpy as np
except ImportError:
    np = None   # the pure-Python matte still works, it is just slower

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
    text = read_store(wtf)
    if not text:
        return None

    shots = _entries(text)
    for e in reversed(shots):
        if e.get("name"):
            return e["name"]
    return None


def read_store(wtf=WTF):
    """The ACCOUNT-wide AltStableProbe.lua, as text.

    Per-character SavedVariables have the SAME FILENAME, one per character, and
    are often newer than the account file - so picking by timestamp alone reads
    a file that has no captures in it and reports "nothing recorded". Filter on
    content: only the account store contains the renders array.
    """
    best, best_time = None, -1
    for root, _dirs, files in os.walk(wtf):
        for f in files:
            if f != "AltStableProbe.lua":
                continue
            full = os.path.join(root, f)
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if '["renders"]' not in text:
                continue
            t = os.path.getmtime(full)
            if t > best_time:
                best, best_time = text, t
    return best


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _entries(text):
    """Every { ... } block inside the renders array, as dicts."""
    start = text.find('["renders"]')
    if start < 0:
        return []
    out, i, n = [], text.find("{", start) + 1, len(text)
    while i < n:
        c = text[i]
        if c == "}":
            break                       # end of the renders array itself
        if c == "{":
            depth, j = 1, i + 1
            while j < n and depth:
                if text[j] == "{": depth += 1
                elif text[j] == "}": depth -= 1
                j += 1
            body = text[i + 1:j - 1]
            out.append(dict(re.findall(r'\["(\w+)"\]\s*=\s*"?([^",\n]+)"?', body)))
            i = j
            continue
        i += 1
    return out


def captures(wtf=WTF):
    """Every capture the addon recorded, newest last.

    Each is a (character name, shot-1 stamp, shot-2 stamp) triple. The addon
    writes one entry per screenshot with the second it was taken, which is the
    key that matches them to files on disk - far more reliable than assuming
    the folder is in the order we left it.
    """
    text = read_store(wtf)
    if not text:
        return []

    shots = _entries(text)
    out, pending = [], {}
    for e in shots:
        guid, shot, stamp = e.get("guid"), e.get("shot"), e.get("stamp")
        if not (guid and stamp):
            continue
        if shot == "1":
            pending[guid] = (e.get("name") or guid, stamp)
        elif shot == "2" and guid in pending:
            name, first = pending.pop(guid)
            out.append((name, first, stamp))
    return out


def shot_times(folder):
    """Screenshot path -> the second it was written, from its own filename."""
    found = {}
    for path in glob.glob(os.path.join(folder, "WoWScrnShot_*.tga")):
        m = re.search(r"WoWScrnShot_(\d{6})_(\d{6})", os.path.basename(path))
        if not m:
            continue
        try:
            found[path] = datetime.datetime.strptime(m.group(1) + m.group(2), "%m%d%y%H%M%S")
        except ValueError:
            pass
    return found


def match(stamp, times, tolerance=4):
    """The screenshot taken at that second, allowing for a little drift."""
    try:
        want = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    best, best_gap = None, None
    for path, when in times.items():
        gap = abs((when - want).total_seconds())
        if gap <= tolerance and (best_gap is None or gap < best_gap):
            best, best_gap = path, gap
    return best

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


def matte_numpy(b, w):
    """The same arithmetic, vectorised. A 3840x1200 pair is 4.6M pixels per
    image, which a Python loop walks in tens of seconds and numpy in well
    under one - and a batch run does this for every character."""
    bb = np.asarray(b, dtype=np.int16)
    ww = np.asarray(w, dtype=np.int16)

    # Coverage: an opaque pixel reads the same on both backdrops, a fully
    # transparent one differs by the full 255.
    diff = (ww - bb).sum(axis=2) / (3.0 * 255.0)
    alpha = np.clip(1.0 - diff, 0.0, 1.0)

    keep = alpha > ALPHA_FLOOR
    safe = np.where(keep, alpha, 1.0)[..., None]      # never divide by zero
    rgb = np.clip(bb / safe, 0, 255).astype(np.uint8)  # undo the premultiply

    out = np.zeros(bb.shape[:2] + (4,), dtype=np.uint8)
    out[..., :3] = rgb
    out[..., 3] = (alpha * 255 + 0.5).astype(np.uint8)
    out[~keep] = 0

    img = Image.fromarray(out, "RGBA")
    box = img.getbbox()
    if not box:
        sys.exit("nothing but backdrop in those two shots - was the stage showing?")
    return img.crop(box)


def matte(black_path, white_path):
    """Recover colour+alpha from the same pose shot on two backdrops."""
    b = Image.open(black_path).convert("RGB")
    w = Image.open(white_path).convert("RGB")
    if b.size != w.size:
        sys.exit("the two shots differ in size (%s vs %s)" % (b.size, w.size))

    if np is not None:
        return matte_numpy(b, w)

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


def convert(black, white, base, target_height, keep_png, out_dir=OUT):
    """One pair -> one cutout on disk. Returns the manifest numbers."""
    cut = matte(black, white)
    native = cut.size
    cut, resampled = supersample(cut, target_height)
    cw, ch = cut.size

    os.makedirs(out_dir, exist_ok=True)
    if keep_png:
        cut.save(os.path.join(out_dir, base + ".png"))

    canvas = Image.new("RGBA", (pot(cw), pot(ch)), (0, 0, 0, 0))
    canvas.paste(cut, (0, 0))
    canvas.save(os.path.join(out_dir, base + ".tga"), compression=None)

    print("  %-22s %4dx%-4d -> %3dx%-4d  canvas %sx%s%s"
          % (base, native[0], native[1], cw, ch, canvas.size[0], canvas.size[1],
             "" if resampled else "  (native)"))

    # A standing character is much taller than it is wide. Anything close to
    # square means something ELSE survived the matte - a tooltip above the
    # stage is the one that has actually happened - and the bounding box has
    # stretched to include it. Cheap to check, and it catches a cutout that
    # would otherwise look fine in a manifest and wrong on screen.
    if native[0] > native[1] * 0.8:
        print("     ^ that is nearly square: something other than the character was on "
              "screen (a tooltip?). Re-capture this one.")

    return cw, ch, canvas.size[0], canvas.size[1]


def human(nbytes):
    mb = nbytes / (1024.0 * 1024.0)
    return "%.1f MB" % mb if mb >= 1 else "%.0f KB" % (nbytes / 1024.0)


def discard(paths, why):
    """Delete staged screenshots we are finished with.

    Only ever files that MATCHED a capture the addon recorded: those are shots
    this pipeline staged and nobody else wants. A screenshot the player took
    themselves never matches a stamp, so it is never touched - which is the
    whole reason deletion keys off the addon's record rather than a filename
    pattern or a date.
    """
    freed, gone = 0, 0
    for path in paths:
        try:
            freed += os.path.getsize(path)
            os.remove(path)
            gone += 1
        except OSError as err:
            print("     could not delete %s (%s)" % (os.path.basename(path), err))
    if gone:
        print("  cleaned up %d screenshot(s), %s freed  [%s]" % (gone, human(freed), why))
    return freed


def run_all(args):
    """Every capture the addon recorded, matched to its screenshots by time."""
    caps = captures()
    if not caps:
        sys.exit("no captures recorded - /reload in game so the addon writes its store")

    times = shot_times(args.shots)

    # One portrait per character: a re-shoot supersedes the one before it, and
    # converting the whole history would re-report every old mistake and write
    # each character's file several times over, newest not necessarily last.
    superseded = {}
    if not args.history:
        latest = {}
        for cap in caps:
            prev = latest.get(cap[0])
            if prev:
                superseded.setdefault(cap[0], []).append(prev)
            latest[cap[0]] = cap          # recorded oldest first, so this keeps the newest
        chosen = [latest[k] for k in sorted(latest)]
        if len(chosen) != len(caps):
            print("%d capture(s) of %d character(s) - taking the newest of each"
                  % (len(caps), len(chosen)))
        caps = chosen

    print("%d capture(s) to convert, %d screenshots on disk\n" % (len(caps), len(times)))

    done, missing, freed = 0, [], 0
    for name, first, second in caps:
        black, white = match(first, times), match(second, times)
        if not (black and white):
            missing.append((name, first))
            continue
        convert(black, white, slug(name), args.target_height, args.keep_png)
        done += 1

        if not args.keep_shots:
            # Only after the cutout is written: a failed convert must leave its
            # source alone so it can be retried.
            spent = [black, white]
            # Older shots of the SAME character are superseded by the cutout we
            # just made, so they go with it.
            for old_cap in superseded.get(name, []):
                for stamp in (old_cap[1], old_cap[2]):
                    hit = match(stamp, times)
                    if hit:
                        spent.append(hit)
            freed += discard(spent, "converted " + slug(name))

    print()
    print("converted %d of %d" % (done, len(caps)))
    if freed:
        print("reclaimed %s of staged screenshots" % human(freed))
    for name, stamp in missing:
        print("  no screenshots for %s (%s) - already cleaned up, deleted, or taken "
              "on another machine" % (name, stamp))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=SHOTS, help="the client's Screenshots folder")
    ap.add_argument("--name", default=None,
                    help="base name for the output (default: the character the addon last photographed)")
    ap.add_argument("--keep-png", action="store_true", help="also write a PNG to eyeball")
    ap.add_argument("--target-height", type=int, default=TARGET_HEIGHT,
                    help="supersample down to this content height for antialiased edges "
                         "(0 keeps the capture at native size)")
    ap.add_argument("--all", action="store_true",
                    help="convert the newest capture of every character the addon recorded, "
                         "matching each to its screenshots by timestamp")
    ap.add_argument("--keep-shots", action="store_true",
                    help="do not delete the staged screenshots after converting them "
                         "(they are 1-2 MB each and there are two per capture)")
    ap.add_argument("--history", action="store_true",
                    help="with --all: convert every capture ever recorded, not just the "
                         "newest of each character")
    args = ap.parse_args()

    if args.all:
        run_all(args)
        return

    black, white = newest_pair(args.shots)
    print("black backdrop :", os.path.basename(black))
    print("white backdrop :", os.path.basename(white))

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

    cw, ch, tw, th = convert(black, white, base, args.target_height, args.keep_png)
    canvas = type("c", (), {"size": (tw, th)})
    print()
    print("manifest entry:")
    print('  { file = "Interface\\\\AddOns\\\\AltStable\\\\Media\\\\Cutouts\\\\%s.tga",' % base)
    print("    w = %d, h = %d, texw = %d, texh = %d }," % (cw, ch, canvas.size[0], canvas.size[1]))


if __name__ == "__main__":
    main()
