"""mutate.py - mutation runner for AltStable's Lua tests (#477).

A test that passes both with and without the change it guards proves nothing
(AGENTS.md, "Mutation-test claims"). This applies one textual break at a time
to a source file, runs the test file meant to catch it, says whether the test
went red, and puts the file back.

Usage, from anywhere:

    python -I Tools/mutate.py <mutations.json> [--repo <path>] [--lua <lua.exe>]

The repo defaults to this file's repository (a worktree works too). The test
files load the library checkouts the way tests/run.ps1 does (tests/checkouts.lua).

The mutation list is a JSON array of objects:

    {"name": "no lift", "file": "Export.lua",
     "old": "    AltStable.LiftAboveHiddenUI(f, true)\\n", "new": "",
     "test": "test_sheetui.lua"}

- "old" must occur exactly once in the file, else the mutation is SKIPPED (and
  says how often it was found). Write it with "\\n" line ends: they are matched
  to the file's own (CRLF or LF).
- WRITE THE LIST WITH PYTHON OR THE WRITE TOOL, NEVER A BASH HEREDOC: a heredoc
  collapses a doubled backslash to a single one, so a Lua escape in "new"
  silently becomes another mutation, which then "survives".
- First, every test file named in the list runs once on the untouched sources.
  One that fails there (a typo in "test", no WowTestKit cache, a broken checkout)
  would turn every mutation "red" without exercising anything: the run stops
  before mutating, with that test's output (Codex review of #478).
- RED: a FAIL line, a traceback or a non-zero exit. GREEN: the test still
  passed - a real gap, or an equivalent mutation (say why in the PR).
- The file is restored only if it still holds the mutation. If it changed,
  was renamed or was deleted while the test ran, that is left as it is, the
  original is written beside it as <file>.mutate-orig (.mutate-orig.1, .2, ...
  when an earlier one is there: never overwritten), and the run stops.

Exit status: 0 when every mutation went red, 1 when one survived or was
skipped, 2 on a setup error (unreadable list, no Lua, a failing baseline test)
or a file changed during the run.
"""
import argparse
import json
import os
import subprocess
import sys

DEFAULT_LUA = r"C:\Program Files (x86)\Lua\5.1\lua.exe"


def run_test(lua, repo, test):
    """(red, output) for one test file run from the repo root."""
    r = subprocess.run([lua, "tests/" + test], cwd=repo, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    fails = [l for l in out.splitlines() if "FAIL" in l]
    red = bool(fails) or "traceback" in out or r.returncode != 0
    why = fails[0].strip() if fails else ("crash or non-zero exit" if red else "")
    return red, why, out


def save_original(path, data):
    """Write data beside path, never over an earlier recovery file: <file>.mutate-orig,
    else .mutate-orig.1, .2, ... (Codex review of #478). Returns the path written."""
    n = 0
    while True:
        name = path + ".mutate-orig" + ("" if n == 0 else ".%d" % n)
        try:
            with open(name, "xb") as f:
                f.write(data)
            return name
        except FileExistsError:
            n += 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply each break, run its test, restore.")
    ap.add_argument("spec", help="the mutations, a JSON array")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--lua", default=DEFAULT_LUA)
    args = ap.parse_args(argv)

    try:
        with open(args.spec, encoding="utf-8") as f:
            muts = json.load(f)
    except (OSError, ValueError) as e:
        print("cannot read %s: %s" % (args.spec, e))
        return 2
    if not os.path.exists(args.lua):
        print("Lua 5.1 not found at %s (pass --lua)" % args.lua)
        return 2

    # The baseline: every test named, once, on the untouched sources.
    for test in sorted({m["test"] for m in muts}):
        red, why, out = run_test(args.lua, args.repo, test)
        if red:
            print("SETUP ERROR: tests/%s fails before any mutation (%s); nothing was mutated." % (test, why))
            print("\n".join(out.splitlines()[-15:]))
            return 2

    red_n = green_n = skipped = 0
    for m in muts:
        path = os.path.join(args.repo, m["file"])
        with open(path, "rb") as f:
            orig = f.read()
        text = orig.decode("utf-8")
        crlf = "\r\n" in text
        old = m["old"].replace("\n", "\r\n") if crlf else m["old"]
        new = m["new"].replace("\n", "\r\n") if crlf else m["new"]
        found = text.count(old)
        if found != 1:
            print("SKIP  %s -- old text found %d times" % (m["name"], found))
            skipped += 1
            continue
        mutated = text.replace(old, new).encode("utf-8")
        changed = False
        try:
            with open(path, "wb") as f:
                f.write(mutated)
            red, why, _ = run_test(args.lua, args.repo, m["test"])
        finally:
            # Only put back what we wrote: an edit saved meanwhile is kept, and
            # so is a rename or a deletion (the original is saved instead).
            try:
                with open(path, "rb") as f:
                    now = f.read()
            except FileNotFoundError:
                now = None
            if now == mutated:
                with open(path, "wb") as f:
                    f.write(orig)
            else:
                changed = save_original(path, orig)
        if changed:
            print("STOP: %s changed or went while its test ran; left as it is, the original is %s"
                  % (m["file"], changed))
            return 2
        if red:
            print("RED   %s -- %s" % (m["name"], why[:200]))
            red_n += 1
        else:
            print("GREEN %s" % m["name"])
            green_n += 1

    print("%d red, %d green, %d skipped, of %d" % (red_n, green_n, skipped, len(muts)))
    return 0 if green_n == 0 and skipped == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
