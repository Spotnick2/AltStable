#!/usr/bin/env python
"""Measure where the campfire is in each scene backdrop.

The scene view stands its characters AROUND the fire and puts their feet on the
fire's base, so it needs to know where that is on each of the fourteen
backdrops. Media/Scene/README.md gives an art target - horizontal centre 50%,
base around 84% - but says in the same breath that these are "approximate art
targets, not measured anchors", and that Karazhan (an AltTracker original that
predates the spec) "retains its original smaller, slightly right-of-center
fire". Measuring it beats trusting it: Karazhan comes out at 0.551/0.900, which
is 70px right and 80px low on a 1400x700 panel - enough to put the keep-out gap
on empty ground and the cast below the drawn floor.

Run this after adding or regenerating a backdrop, and paste the numbers into
SCENE_BACKDROPS in Plugins/Roster/AltStableRoster.lua as fireX/fireBaseY. It
prints them in Lua table form, ready to paste.

    python Tools/Scene/find-fire.py

Requires numpy and Pillow, the same two the cutout converter uses.
"""

import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image

SCENE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "..", "Media", "Scene")

# The real image occupies the top of a 1024x1024 canvas; the rest is opaque
# black padding, and averaging it in would drag every anchor downwards.
CONTENT_H = 682

# Warm mass below this fraction of the peak is glow, not flame.
FLOOR = 0.35

# Sunset skies are warm and enormous and would win outright, so only look low.
HORIZON = 0.45


def fire(path):
    """(x, base y) as fractions of the content, or None if nothing warm."""
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.float32)[:CONTENT_H, :, :]
    h, w, _ = a.shape
    R, G, B = a[..., 0], a[..., 1], a[..., 2]

    # Fire is the brightest WARM thing in the picture: strong red, red well
    # clear of blue. Moonlight and snow are bright but cold; the product of the
    # two margins suppresses anything that is merely bright.
    warm = np.clip(R - B, 0, None) * np.clip(R - G * 0.5, 0, None)
    warm[: int(h * HORIZON), :] = 0

    peak = warm.max()
    if peak <= 0:
        return None

    ys, xs = np.nonzero(warm >= peak * FLOOR)
    weights = warm[ys, xs]
    cx = float((xs * weights).sum() / weights.sum())
    # The BASE of the flame, not its centre: the 90th-percentile row of the warm
    # mass is roughly where it meets the ground. The mean sits halfway up the
    # flame, which would bury the cast's feet in the fire.
    base = float(np.percentile(ys, 90))
    return cx / w, base / h, len(xs)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=SCENE_DIR, help="where the scene-*.tga live")
    args = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(args.dir, "scene-*.tga")))
    if not paths:
        print("no scene-*.tga in %s" % os.path.abspath(args.dir))
        return 1

    for path in paths:
        name = os.path.basename(path)
        found = fire(path)
        if not found:
            print("-- %-30s no warm source found; check the art" % name)
            continue
        x, base, px = found
        flag = "   -- OFF-CENTRE" if abs(x - 0.5) > 0.03 else ""
        print("      fireX = %.3f, fireBaseY = %.3f },   -- %s, %d px%s"
              % (x, base, name, px, flag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
