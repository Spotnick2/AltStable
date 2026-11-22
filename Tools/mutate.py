"""mutate.py - mutation runner for AltStable's Lua tests (#477).

A test that passes both with and without the change it guards proves nothing
(AGENTS.md, "Mutation-test claims"). This applies one textual break at a time
to a source file, runs the test file meant to catch it, says whether the test
went red, and puts the file back byte for byte, whatever happens.

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
- RED: a FAIL line, a traceback or a non-zero exit. GREEN: the test still
  passed - a real gap, or an equivalent mutation (say why in the PR).

The exit status is 0 when every mutation went red, 1 when one survived or was
skipped, 2 on a usage error.
"""
import argparse
import json
import os
import subprocess
import sys

DEFAULT_LUA = r"C:\Program Files (x86)\Lua\5.1\lua.exe"


def main():
    ap = argparse.ArgumentParser(description="Apply each break, run its test, restore.")
    ap.add_argument("spec", help="the mutations, a JSON array")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--lua", default=DEFAULT_LUA)
    args = ap.parse_args()

    try:
        with open(args.spec, encoding="utf-8") as f:
            muts = json.load(f)
    except (OSError, ValueError) as e:
        print("cannot read %s: %s" % (args.spec, e))
        return 2
    if not os.path.exists(args.lua):
        print("Lua 5.1 not found at %s (pass --lua)" % args.lua)
        return 2

    red = green = skipped = 0
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
        try:
            with open(path, "wb") as f:
                f.write(text.replace(old, new).encode("utf-8"))
            r = subprocess.run([args.lua, "tests/" + m["test"]], cwd=args.repo,
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            out = (r.stdout or "") + (r.stderr or "")
            fails = [l for l in out.splitlines() if "FAIL" in l]
            if fails or "traceback" in out or r.returncode != 0:
                why = fails[0].strip() if fails else "crash or non-zero exit"
                print("RED   %s -- %s" % (m["name"], why[:200]))
                red += 1
            else:
                print("GREEN %s" % m["name"])
                green += 1
        finally:
            with open(path, "wb") as f:
                f.write(orig)

    print("%d red, %d green, %d skipped, of %d" % (red, green, skipped, len(muts)))
    return 0 if green == 0 and skipped == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
