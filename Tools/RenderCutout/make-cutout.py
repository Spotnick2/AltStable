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
import json
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
    caps = captures(wtf)
    return caps[-1][0] if caps else None


def read_stores(wtf=WTF):
    """EVERY account-wide AltStableProbe.lua, as text.

    All of them, not the newest: a player with two accounts captures from both,
    and every client writes screenshots into the SAME folder. Read one store and
    the other account's captures have no metadata to match against, so its
    screenshots look like orphans and its characters silently never get a
    portrait. That is exactly how it presented - the two that failed were both
    from account 2.

    Per-character SavedVariables share the filename AltStableProbe.lua and are
    often newer than the account file, so the filter is on CONTENT: only the
    account store holds the renders array.
    """
    out = []
    for root, _dirs, files in os.walk(wtf):
        for f in files:
            if f != "AltStableProbe.lua":
                continue
            full = os.path.join(root, f)
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if '["renders"]' in text:
                out.append(text)
    return out


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


def store_is_stale(caps, times, slack=60):
    """Is the client sitting on capture records it has not written out yet?

    Returns (newest screenshot, newest record) when the screenshots on disk run
    ahead of the store, otherwise None.

    AltStableProbeDB is only written on logout or /reload, but the client writes
    a screenshot the instant it is taken. So the normal state right after a
    capture is: both images on disk, no record of them anywhere. The converter
    then works from the PREVIOUS records and reports something true but
    misleading - "no screenshots for X", or a complaint about a capture the
    player has already redone - and the real answer is simply "/reload".

    `slack` covers the ordinary gap between the shutter and the record being
    flushed a moment later; this is only worth saying when the gap is real.
    """
    if not times:
        return None
    newest_shot = max(times.values())
    newest_rec = None
    for cap in caps:
        for stamp in (cap[1], cap[2]):
            try:
                when = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
            except (ValueError, TypeError):
                continue
            if newest_rec is None or when > newest_rec:
                newest_rec = when
    if newest_rec is None:
        return (newest_shot, None)
    if (newest_shot - newest_rec).total_seconds() > slack:
        return (newest_shot, newest_rec)
    return None


def captures(wtf=WTF):
    """Every capture the addon recorded, newest last.

    Each is a (character name, shot-1 stamp, shot-2 stamp, screen height) tuple.
    The addon writes one entry per screenshot with the second it was taken,
    which is the key that matches them to files on disk - far more reliable
    than assuming the folder is in the order we left it.

    The screen height comes along because the cutout's pixel size means nothing
    on its own: see the normalisation in convert().
    """
    out = []
    for text in read_stores(wtf):
        # Pairing is per store: shot 1 and shot 2 of one capture are always
        # recorded by the same client, and two accounts shooting at the same
        # moment must not have their halves paired with each other.
        pending = {}
        for e in _entries(text):
            guid, shot, stamp = e.get("guid"), e.get("shot"), e.get("stamp")
            if not (guid and stamp):
                continue
            if shot == "1":
                pending[guid] = (e.get("name") or guid, stamp, e.get("screenH"))
            elif shot == "2" and guid in pending:
                name, first, screen_h = pending.pop(guid)
                out.append((name, first, stamp, screen_h))

    # Oldest first, so "the newest capture of each character" still means that
    # once both accounts are in one list.
    out.sort(key=lambda c: c[1])
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


def match(stamp, times, tolerance=4, exclude=()):
    """The screenshot taken at that second, allowing for a little drift.

    `exclude` is what makes this safe: the two shots of a pair are about a
    second apart and the tolerance is wider than that, so without it BOTH
    stamps can resolve to the same file when one shot is missing. The matte
    then compares an image with itself, finds no difference anywhere, and
    concludes the whole screen is opaque - producing a "cutout" that is the
    entire screenshot. That is not a hypothetical; it shipped two of them.
    """
    try:
        want = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    best, best_gap = None, None
    for path, when in times.items():
        if path in exclude:
            continue
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

    # If the two shots were identical, every pixel reads as fully covered. A
    # real capture is a figure on an empty stage, so near-total coverage means
    # the pair was wrong, not that the character filled the screen.
    covered = float((alpha > 0.5).sum()) / alpha.size
    if covered > 0.9:
        raise NotAPair("the two shots look identical (%.0f%% of the frame reads as opaque)"
                       % (covered * 100))

    img = Image.fromarray(out, "RGBA")
    box = img.getbbox()
    if not box:
        raise NotAPair("nothing but backdrop in those two shots - was the stage showing?")
    return img.crop(box)


class NotAPair(Exception):
    """The two shots are not a black/white pair of the same pose."""


def matte(black_path, white_path):
    """Recover colour+alpha from the same pose shot on two backdrops."""
    if os.path.abspath(black_path) == os.path.abspath(white_path):
        raise NotAPair("both shots resolved to the same file")

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
    kept = 0

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
            kept += 1

            if x < minx: minx = x
            if y < miny: miny = y
            if x > maxx: maxx = x
            if y > maxy: maxy = y

    if maxx < 0:
        raise NotAPair("nothing but backdrop in those two shots - was the stage showing?")
    covered = float(kept) / float(width * height)
    if covered > 0.9:
        raise NotAPair("the two shots look identical (%.0f%% of the frame reads as opaque)"
                       % (covered * 100))
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


def renormalise(folder, wtf=WTF):
    """Convert pre-convention sidecars in place, without re-capturing.

    A sidecar written before nativeUnit existed holds raw screenshot pixels, and
    the manifest generator refuses those - correctly, since they are not
    comparable across resolutions. But they are recoverable: the probe store
    still holds every capture's screenH, which is the physical screen size
    (GetPhysicalScreenSize) and therefore the screenshot's own height. Dividing
    by it gives exactly what convert() now writes.

    Recovery matters because the screenshots are deleted after conversion, so
    the alternative is re-capturing every character in game.

    ONLY when the answer is unambiguous. A legacy sidecar records no capture
    identity - just a pixel height - so there is nothing tying it to one record
    rather than another. If a character has been captured at more than one
    screen height, "their" height is a guess, and a guess written here is worse
    than no measurement: it is stamped nativeUnit and never revisited. This
    roster has two such characters already (Karuzo Sumner and Morphisto
    Ruskador, captured at both 1200 and 2160), so it is not a hypothetical.
    """
    # Every DISTINCT screen height per character. One means recovery is certain;
    # more than one means it cannot be.
    heights = {}
    for text in read_stores(wtf):
        for e in _entries(text):
            name, sh = e.get("name"), e.get("screenH")
            if name and sh:
                try:
                    heights.setdefault(slug(name), set()).add(float(sh))
                except ValueError:
                    pass

    done, stuck, ambiguous = 0, [], []
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        base = os.path.splitext(os.path.basename(path))[0]
        try:
            with open(path, encoding="utf-8") as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        if meta.get("nativeUnit"):
            continue
        px = meta.get("nativePx") or [meta.get("nativeW"), meta.get("nativeH")]
        seen = heights.get(base) or set()
        if len(seen) > 1:
            ambiguous.append((base, sorted(seen)))
            continue
        shot_h = next(iter(seen), None)
        if not shot_h or not px or not px[1]:
            stuck.append(base)
            continue
        meta["nativeUnit"] = "screen"
        meta["nativePx"] = [px[0], px[1]]
        meta["nativeW"] = round(px[0] / shot_h, 5)
        meta["nativeH"] = round(px[1] / shot_h, 5)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=2)
        print("  renormalised %-22s  %d px / %d = %.5f"
              % (base, px[1], shot_h, meta["nativeH"]))
        done += 1

    if done:
        print("  recovered %d sidecar(s) without re-capturing" % done)
    for base in stuck:
        print("  %-22s no capture record - re-capture for a true height" % base)
    for base, seen in ambiguous:
        print("  %-22s captured at %s - cannot tell which made this cutout; "
              "re-capture" % (base, " and ".join("%d" % h for h in seen)))
    return done


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def convert(black, white, base, target_height, keep_png, out_dir=OUT):
    """One pair -> one cutout on disk. Returns the manifest numbers."""
    cut = matte(black, white)
    native = cut.size
    # The screenshot is the whole screen, so its height is the yardstick the
    # character's height is measured against. Taken from the image rather than
    # from the store record, because the image cannot be wrong about itself.
    shot_h = Image.open(black).size[1]

    # A figure cannot be as tall as the screen. The render stage is 760 UI units
    # on a screen of a couple of thousand pixels, so a real cutout lands around
    # 0.6 of the frame; anything near 1.0 means the matte caught the whole
    # window, not the character. Two of those got filed before this check
    # existed, and because nativeH is RELATIVE, one of them is enough to make
    # every other character in the scene draw at half height.
    if shot_h > 0 and native[1] >= shot_h * 0.95:
        raise NotAPair(
            "the cutout is %d of %d screen rows tall - the matte caught the "
            "whole window, not the character" % (native[1], shot_h))

    cut, resampled = supersample(cut, target_height)
    cw, ch = cut.size

    os.makedirs(out_dir, exist_ok=True)
    if keep_png:
        cut.save(os.path.join(out_dir, base + ".png"))

    canvas = Image.new("RGBA", (pot(cw), pot(ch)), (0, 0, 0, 0))
    canvas.paste(cut, (0, 0))
    canvas.save(os.path.join(out_dir, base + ".tga"), compression=None)

    # The NATIVE size, beside the texture.
    #
    # NOT a race height, and it cannot be made into one. This was recorded to
    # let the scene draw a gnome shorter than a night elf, on the theory that
    # supersampling had flattened a difference the capture knew about. It had
    # not: the render stage uses DressUpModel:SetUnit(), which FRAMES the model
    # to fill the frame, so every race is drawn at the same size before a
    # screenshot exists. Across nine captured characters these values spanned
    # 0.609 to 0.649 - 6.6% - for races that differ by roughly 40%.
    #
    # The scene takes heights from char.race now. This stays because it is a
    # true measurement of how much of the screen the cutout occupies, it costs
    # nothing, and it is the evidence for the paragraph above - but nothing
    # reads it, and nothing should read it as a height until the stage renders
    # at a fixed camera scale instead of auto-framing.
    #
    # But raw screenshot pixels are NOT comparable between captures, and this
    # roster already proves it: the probe store here holds captures at screenH
    # 1200 and at screenH 2160. The render stage is 420x760 *UI units*
    # (Tools/AltStableProbe/Render.lua), so the same character comes out nearly
    # twice as tall in the 2160 shots. Left raw, the scene would draw those
    # characters twice the height of the others and call it a race difference.
    #
    # So record the fraction of SCREEN HEIGHT the character occupies:
    #
    #     nativeH = character pixels / screenshot pixels
    #
    # The screenshot is the whole screen and the stage is a fixed size in UI
    # units, so this is the same number at any resolution. Only ratios between
    # characters are ever used, which is why a dimensionless fraction is enough
    # and no scale identity has to be assumed.
    #
    # nativeUnit records WHICH convention a sidecar holds. Sidecars written
    # before this change hold raw pixels and say nothing; the manifest generator
    # drops those rather than mixing the two, because half a roster measured in
    # pixels and half in screen fractions is worse than none of it measured at
    # all. --renormalise below converts them in place instead.
    meta = {
        "w": cw, "h": ch,
        "texw": canvas.size[0], "texh": canvas.size[1],
        "nativeW": native[0], "nativeH": native[1],
    }
    if shot_h > 0:
        meta["nativeUnit"] = "screen"
        meta["nativeW"] = round(native[0] / shot_h, 5)
        meta["nativeH"] = round(native[1] / shot_h, 5)
        meta["nativePx"] = [native[0], native[1]]
    with open(os.path.join(out_dir, base + ".json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)

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
    # The same file can reach here twice: a superseded capture's stamp resolves
    # through match(), whose tolerance is wider than the gap between two shots,
    # so it can land on a path already in the list. Deleting it twice printed a
    # WinError in the middle of a successful conversion, which reads like a
    # failure. Deduplicated here rather than at the call site, because this is
    # the function that deletes and it should tolerate being told twice.
    seen, unique = set(), []
    for path in paths:
        if path not in seen:
            seen.add(path)
            unique.append(path)
    paths = unique

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

    stale = store_is_stale(caps, times)
    if stale:
        shot, rec = stale
        print("  |  Your client has not written its capture records yet.")
        print("  |  Newest screenshot: %s" % shot.strftime("%Y-%m-%d %H:%M:%S"))
        print("  |  Newest record:     %s" % (rec.strftime("%Y-%m-%d %H:%M:%S") if rec else "none at all"))
        print("  |  AltStableProbeDB is only saved on /reload or logout, so a capture")
        print("  |  taken just now is two images with nothing describing them.")
        print("  |  Run /reload in game, then run this again.")
        print("")

    done, missing, collided, freed = 0, [], [], 0
    for name, first, second, screen_h in caps:
        # Both shots recorded at the same second means one filename, and the
        # client overwrote the first with the second. There is no pair to find
        # and "no screenshots for X" is a misleading way to say so - the file is
        # right there, it is just one file where two are needed.
        if first == second:
            collided.append((name, first))
            continue
        black = match(first, times)
        white = match(second, times, exclude=(black,) if black else ())
        if not (black and white):
            missing.append((name, first))
            continue
        try:
            convert(black, white, slug(name), args.target_height, args.keep_png)
        except NotAPair as err:
            # Leave the screenshots alone: the capture can be salvaged, and a
            # bad cutout filed under a character's name is worse than none.
            print("  %-22s SKIPPED - %s" % (slug(name), err))
            missing.append((name, first))
            continue
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
    for name, stamp in collided:
        print("  %-22s both shots landed in the same second (%s), so the client "
              "wrote one file - re-capture" % (slug(name), stamp))
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
    ap.add_argument("--renormalise", metavar="DIR",
                    help="convert pre-convention sidecars in DIR to screen "
                         "fractions, using the probe store's screenH, and exit")
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

    if args.renormalise:
        renormalise(args.renormalise)
        return

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
    print("Update-Cutouts.ps1 files these and writes the manifest; this single-pair")
    print("mode is for eyeballing one capture. It deliberately prints no manifest")
    print("entry: the path it used to suggest (AltStable\\Media\\Cutouts) is not where",)
    print("the pipeline puts cutouts, and pasting it produces a texture that never loads.")


if __name__ == "__main__":
    main()
