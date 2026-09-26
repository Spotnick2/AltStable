#!/usr/bin/env python
"""Tests for the cutout converter's decisions.

Plain stdlib, no framework, same shape as the Lua suites: check/eq helpers and a
count at the end. run.ps1 used to say "Lua only" because AltTracker's Python
tests pulled in deferred tooling - this file pulls in nothing, and there is now
Python logic whose failure mode is silently wrong artwork rather than an error.

The heavy image work (matte, supersample) still has no test: it needs real
screenshot pairs, which are 2 MB each and are deleted after conversion. What is
covered here is the arithmetic and the refusals - the parts that decide whether
a number is trustworthy, which is where the bugs have actually been.
"""

import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "Tools", "RenderCutout"))

passed, failed = 0, 0


def check(label, cond, detail=None):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("  FAIL: %s%s" % (label, ("  -- " + str(detail)) if detail else ""))


def eq(label, got, want):
    check(label, got == want, "got %r, want %r" % (got, want))


try:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "make_cutout", os.path.join(HERE, "..", "Tools", "RenderCutout", "make-cutout.py"))
    mc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mc)
except ImportError as err:
    # numpy/Pillow are the converter's own dependencies, not the addon's.
    print("test_cutouts: SKIPPED - %s" % err)
    sys.exit(0)


# ------------------------------------------------------------------
# Slugs must match the addon's Slug(), or a cutout is filed under a
# name the scene will never look up.
# ------------------------------------------------------------------
eq("a surname becomes one slug", mc.slug("Karuzo Sumner"), "karuzo-sumner")
eq("case is flattened", mc.slug("KARUZO Sumner"), "karuzo-sumner")
eq("punctuation collapses", mc.slug("Kel'Thuzad  Bob"), "kel-thuzad-bob")
eq("edges are trimmed", mc.slug("  Bob  "), "bob")


# ------------------------------------------------------------------
# Recovering a legacy height, and refusing to guess one
# ------------------------------------------------------------------
# A sidecar written before nativeUnit existed holds raw screenshot pixels. Those
# are recoverable from the probe store's screenH - but ONLY when the store gives
# one unambiguous answer. A legacy sidecar records no capture identity, so with
# two capture resolutions on file there is nothing tying it to either, and a
# guess written here is stamped nativeUnit and never revisited.

def sidecar(folder, base, **extra):
    meta = {"w": 100, "h": 512, "texw": 128, "texh": 512,
            "nativeW": 300, "nativeH": 600}
    meta.update(extra)
    with open(os.path.join(folder, base + ".json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh)


def read(folder, base):
    with open(os.path.join(folder, base + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


STORE_ONE = '''
AltStableProbeDB = {
    ["renders"] = {
        { ["name"] = "Solo Alt", ["guid"] = "g1", ["shot"] = 1,
          ["stamp"] = "2026-09-25 11:00:00", ["screenH"] = 1200 },
        { ["name"] = "Solo Alt", ["guid"] = "g1", ["shot"] = 2,
          ["stamp"] = "2026-09-25 11:00:02", ["screenH"] = 1200 },
        { ["name"] = "Moved Alt", ["guid"] = "g2", ["shot"] = 1,
          ["stamp"] = "2026-09-25 11:10:00", ["screenH"] = 1200 },
        { ["name"] = "Moved Alt", ["guid"] = "g2", ["shot"] = 2,
          ["stamp"] = "2026-09-25 11:10:02", ["screenH"] = 2160 },
    },
}
'''

with tempfile.TemporaryDirectory() as tmp:
    wtf = os.path.join(tmp, "WTF", "Account", "1#1", "SavedVariables")
    os.makedirs(wtf)
    with open(os.path.join(wtf, "AltStableProbe.lua"), "w", encoding="utf-8") as fh:
        fh.write(STORE_ONE)
    root = os.path.join(tmp, "WTF")

    cuts = os.path.join(tmp, "cuts")
    os.makedirs(cuts)
    sidecar(cuts, "solo-alt")
    sidecar(cuts, "moved-alt")
    sidecar(cuts, "unknown-alt")
    sidecar(cuts, "already-done", nativeUnit="screen", nativeH=0.5, nativeW=0.25)

    done = mc.renormalise(cuts, wtf=root)
    eq("only the unambiguous one is recovered", done, 1)

    solo = read(cuts, "solo-alt")
    eq("  and it is measured as a screen fraction", solo["nativeUnit"], "screen")
    eq("  600 of 1200 rows is half the screen", solo["nativeH"], 0.5)
    eq("  the width goes with it", solo["nativeW"], 0.25)
    eq("  and the pixels are kept, so this can be redone", solo["nativePx"], [300, 600])

    moved = read(cuts, "moved-alt")
    check("a character captured at two resolutions is NOT guessed at",
          "nativeUnit" not in moved, moved)
    eq("  and keeps its raw pixels untouched", moved["nativeH"], 600)

    unknown = read(cuts, "unknown-alt")
    check("a character with no capture record is left alone",
          "nativeUnit" not in unknown, unknown)

    again = read(cuts, "already-done")
    eq("an already-measured sidecar is not touched", again["nativeH"], 0.5)

    # Idempotent: a second pass has nothing left to do and changes nothing.
    eq("a second pass recovers nothing", mc.renormalise(cuts, wtf=root), 0)
    eq("  and leaves the recovered value alone", read(cuts, "solo-alt")["nativeH"], 0.5)


print("test_cutouts: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
