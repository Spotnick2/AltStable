#!/usr/bin/env python
"""Tests for the cutout converter's decisions.

Plain stdlib, no framework, same shape as the Lua suites: check/eq helpers and a
count at the end. run.ps1 used to say "Lua only" because AltTracker's Python
tests pulled in deferred tooling - this file adds no tooling, and there is now
Python logic whose failure mode is silently wrong artwork rather than an error.

It does need Pillow, because the converter it loads does. Pillow is the
converter's dependency and not the addon's, so this file SKIPS rather than fails
when it is absent - and it checks for it before loading the converter, because
the converter answers a missing Pillow with sys.exit(), which is a SystemExit no
ImportError handler will catch.

The heavy image work (matte, supersample) still has no test: it needs real
screenshot pairs, which are 2 MB each and are deleted after conversion. What is
covered here is the arithmetic and the refusals - the parts that decide whether
a number is trustworthy, which is where the bugs have actually been.
"""

import contextlib
import io
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


import importlib.util

# Check the converter's dependency BEFORE loading it, and do not wrap the load
# in a handler.
#
# make-cutout.py catches its own missing Pillow and calls sys.exit("Pillow is
# required: ..."), which raises SystemExit - not ImportError. An `except
# ImportError` around the load therefore does not catch it, and since run.ps1
# runs this file unconditionally, a Python without Pillow failed the whole addon
# suite instead of skipping the optional converter checks. find_spec answers the
# question without importing anything, so there is no exit to catch.
#
# numpy is genuinely optional - the converter falls back to a pure-Python matte -
# so it is not checked here.
if importlib.util.find_spec("PIL") is None:
    print("test_cutouts: SKIPPED - Pillow is not installed "
          "(it is the converter's dependency, not the addon's)")
    sys.exit(0)

# No .pyc for the converter.
#
# Python decides a cached bytecode file is still valid from the source's mtime
# and SIZE. An edit that changes neither - and a same-length identifier swap
# changes neither - leaves the cache looking current, so the test runs the OLD
# code while reporting on the new file. That happened here: a mutation check
# swapped `first` for `stamp`, both five letters, and the suite went on passing
# against bytecode from the mutated run long after the source was restored.
sys.dont_write_bytecode = True
importlib.invalidate_caches()

# Loaded bare on purpose: past this point any failure is a real one and should
# show as an error, not be mistaken for an absent dependency.
spec = importlib.util.spec_from_file_location(
    "make_cutout", os.path.join(HERE, "..", "Tools", "RenderCutout", "make-cutout.py"))
mc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mc)


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


# ------------------------------------------------------------------
# Two shots recorded at the same second
# ------------------------------------------------------------------
# The client names screenshots to the second, so a pair taken inside one second
# is one filename and the second overwrites the first. The pair is unrecoverable
# and the converter must say WHY - "no screenshots for X" points at the wrong
# thing when the file is sitting right there, just one file where two are needed.

STORE_COLLIDED = '''
AltStableProbeDB = {
    ["renders"] = {
        { ["name"] = "Split Second", ["guid"] = "g9", ["shot"] = 1,
          ["stamp"] = "2026-09-26 02:14:44", ["screenH"] = 2160 },
        { ["name"] = "Split Second", ["guid"] = "g9", ["shot"] = 2,
          ["stamp"] = "2026-09-26 02:14:44", ["screenH"] = 2160 },
        { ["name"] = "Clean Pair", ["guid"] = "g8", ["shot"] = 1,
          ["stamp"] = "2026-09-26 02:13:56", ["screenH"] = 2160 },
        { ["name"] = "Clean Pair", ["guid"] = "g8", ["shot"] = 2,
          ["stamp"] = "2026-09-26 02:13:57", ["screenH"] = 2160 },
    },
}
'''

with tempfile.TemporaryDirectory() as tmp:
    wtf = os.path.join(tmp, "WTF", "Account", "1#1", "SavedVariables")
    os.makedirs(wtf)
    with open(os.path.join(wtf, "AltStableProbe.lua"), "w", encoding="utf-8") as fh:
        fh.write(STORE_COLLIDED)

    caps = {c[0]: c for c in mc.captures(wtf=os.path.join(tmp, "WTF"))}
    eq("both captures are recorded as pairs", len(caps), 2)

    collided = caps["Split Second"]
    eq("  and the collided one has identical stamps", collided[1], collided[2])

    clean = caps["Clean Pair"]
    check("  while a good pair does not", clean[1] != clean[2],
          "%r == %r" % (clean[1], clean[2]))

    # This equality is the whole detection rule, so pin the comparison itself:
    # it is what run_all branches on before trying to match files.
    check("identical stamps are detectable without touching the disk",
          collided[1] == collided[2] and clean[1] != clean[2])


# ------------------------------------------------------------------
# The client has not written its records yet
# ------------------------------------------------------------------
# AltStableProbeDB is saved on /reload or logout, but a screenshot hits the disk
# the instant it is taken. So the normal state right after a capture is both
# images present and nothing describing them - and the converter, working from
# the PREVIOUS records, reports something true but misleading: "no screenshots
# for X", or a complaint about a capture the player has already redone. The real
# answer is "/reload", and it should say so.

import datetime as _dt

def _t(s):
    return _dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S")

FRESH = [("Alt", "2026-09-26 02:30:04", "2026-09-26 02:30:05", "2160")]
OLD = [("Alt", "2026-09-26 02:14:43", "2026-09-26 02:14:44", "2160")]

shots_new = {"a.tga": _t("2026-09-26 02:30:04"), "b.tga": _t("2026-09-26 02:30:05")}

check("records that match the screenshots are not called stale",
      mc.store_is_stale(FRESH, shots_new) is None)

stale = mc.store_is_stale(OLD, shots_new)
check("screenshots newer than every record are", stale is not None)
if stale:
    eq("  and it reports the newest screenshot", stale[0], _t("2026-09-26 02:30:05"))
    eq("  and the newest record it does have", stale[1], _t("2026-09-26 02:14:44"))

# A record written a moment after the shutter is the normal case, not staleness.
justafter = [("Alt", "2026-09-26 02:30:04", "2026-09-26 02:30:05", "2160")]
shots_slack = {"a.tga": _t("2026-09-26 02:30:35")}
check("a shot a few seconds ahead of its record is within slack",
      mc.store_is_stale(justafter, shots_slack) is None)

check("an empty store with screenshots present is stale",
      mc.store_is_stale([], shots_new) is not None)
local_empty = mc.store_is_stale([], shots_new)
eq("  and says there is no record at all", local_empty and local_empty[1], None)
check("no screenshots at all is not staleness", mc.store_is_stale(OLD, {}) is None)


# ------------------------------------------------------------------
# Being told to delete the same file twice
# ------------------------------------------------------------------
# A superseded capture's stamp can resolve through match() onto a path already
# staged for deletion - its tolerance is wider than the gap between two shots.
# The second delete then failed and printed a WinError in the middle of a
# successful conversion, which reads like something went wrong.

with tempfile.TemporaryDirectory() as tmp:
    victim = os.path.join(tmp, "shot.tga")
    with open(victim, "wb") as fh:
        fh.write(b"x" * 1024)
    other = os.path.join(tmp, "other.tga")
    with open(other, "wb") as fh:
        fh.write(b"y" * 512)

    # The byte count alone cannot see this: without the dedupe the second
    # delete fails, is caught, and the totals come out identical. The only
    # difference is a WinError printed mid-conversion, so that is what to
    # assert.
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        freed = mc.discard([victim, victim, other], "test")
    said = buf.getvalue()

    eq("both files are counted once each", freed, 1536)
    check("  and both are gone",
          not os.path.exists(victim) and not os.path.exists(other))
    check("  with no failure reported for the repeat",
          "could not delete" not in said, said.strip())
    check("  and the tally counts two files, not three",
          "2 screenshot(s)" in said, said.strip())

    # A file that genuinely is not there still reports, because that IS worth
    # knowing - it was only the duplicate that was noise.
    missing = os.path.join(tmp, "never-existed.tga")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        eq("a truly missing file frees nothing", mc.discard([missing], "test"), 0)
    check("  and is still reported", "could not delete" in buf.getvalue(),
          buf.getvalue().strip())


print("test_cutouts: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
