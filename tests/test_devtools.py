#!/usr/bin/env python
"""Tests for the dev tooling of #477: Tools/mutate.py and Tools/Checkouts.ps1.

Plain stdlib, same shape as test_recipedata.py. Each case builds a throwaway
repository in a temp folder, so nothing here touches this one. The mutation
runner's cases need Lua 5.1 and the checkout cases need pwsh and git; a machine
without them skips those cases (the Linux CI runner has no Windows Lua).
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

import importlib.util

spec = importlib.util.spec_from_file_location("mutate", os.path.join(ROOT, "Tools", "mutate.py"))
mutate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mutate)

passed = failed = 0


def check(label, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("  FAIL: %s  -- %s" % (label, detail))


def write(path, text, crlf=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = text.replace("\n", "\r\n") if crlf else text
    with open(path, "wb") as f:
        f.write(data.encode("utf-8"))


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


def run_mutate(repo, muts):
    spec_path = os.path.join(repo, "muts.json")
    with open(spec_path, "w", encoding="utf-8") as f:
        json.dump(muts, f)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = mutate.main([spec_path, "--repo", repo, "--lua", LUA])
    return code, out.getvalue()


# ------------------------------------------------------------------
# Tools/mutate.py
# ------------------------------------------------------------------

LUA = mutate.DEFAULT_LUA if os.path.exists(mutate.DEFAULT_LUA) else shutil.which("lua5.1")
if not LUA:
    print("  (mutate.py cases skipped: no Lua 5.1)")
else:
    # A source the test reads, and a test that checks it: it says FAIL when
    # the source no longer holds "answer = 42".
    TEST = (
        'local f = assert(io.open("src.lua", "rb")); local s = f:read("*a"); f:close()\n'
        'if not s:find("answer = 42", 1, true) then print("  FAIL: the answer") end\n'
        'print("done")\n'
    )

    with tempfile.TemporaryDirectory() as repo:
        write(os.path.join(repo, "src.lua"), "local answer = 42\nlocal other = 1\n", crlf=True)
        write(os.path.join(repo, "tests", "test_src.lua"), TEST)
        orig = open(os.path.join(repo, "src.lua"), "rb").read()

        code, out = run_mutate(repo, [
            {"name": "break it", "file": "src.lua", "old": "local answer = 42\n", "new": "local answer = 7\n", "test": "test_src.lua"},
            {"name": "harmless", "file": "src.lua", "old": "local other = 1\n", "new": "local other = 2\n", "test": "test_src.lua"},
            {"name": "absent", "file": "src.lua", "old": "nowhere", "new": "", "test": "test_src.lua"},
        ])
        check("a break the test sees is RED (matched across CRLF)", "RED   break it" in out, out)
        check("one it doesn't see is GREEN", "GREEN harmless" in out, out)
        check("text not found is SKIPPED", "SKIP  absent" in out, out)
        check("  so the run exits 1", code == 1, code)
        check("the source is back byte for byte", open(os.path.join(repo, "src.lua"), "rb").read() == orig)

        code, out = run_mutate(repo, [
            {"name": "break it", "file": "src.lua", "old": "local answer = 42\n", "new": "local answer = 7\n", "test": "test_src.lua"},
        ])
        check("every mutation red: exit 0", code == 0, out)

        # A test that fails on the untouched sources (a typo, a missing
        # checkout) would make every mutation "red": stop before mutating.
        code, out = run_mutate(repo, [
            {"name": "break it", "file": "src.lua", "old": "local answer = 42\n", "new": "local answer = 7\n", "test": "test_typo.lua"},
        ])
        check("a test that can't run on the clean sources stops the run", code == 2, (code, out))
        check("  saying which, before any mutation", "SETUP ERROR: tests/test_typo.lua" in out and "RED" not in out, out)
        write(os.path.join(repo, "tests", "test_broken.lua"), 'print("  FAIL: always")\n')
        code, out = run_mutate(repo, [
            {"name": "break it", "file": "src.lua", "old": "local answer = 42\n", "new": "local answer = 7\n", "test": "test_broken.lua"},
        ])
        check("  as does one that already fails, with its output", code == 2 and "FAIL: always" in out, out)
        check("  the source untouched", open(os.path.join(repo, "src.lua"), "rb").read() == orig)

        # An edit saved while the test runs: kept, and the original set beside it.
        write(os.path.join(repo, "tests", "test_edits.lua"),
              'local f = assert(io.open("src.lua", "rb")); local s = f:read("*a"); f:close()\n'
              'if s:find("answer = 7", 1, true) then\n'
              '    local w = assert(io.open("src.lua", "wb")); w:write("-- edited meanwhile\\n"); w:close()\n'
              'end\n')
        code, out = run_mutate(repo, [
            {"name": "break it", "file": "src.lua", "old": "local answer = 42\n", "new": "local answer = 7\n", "test": "test_edits.lua"},
        ])
        check("a file changed during its test stops the run", code == 2 and "STOP: src.lua changed" in out, out)
        check("  the edit is kept", read(os.path.join(repo, "src.lua")) == "-- edited meanwhile\n")
        check("  and the original is beside it", open(os.path.join(repo, "src.lua.mutate-orig"), "rb").read() == orig)

# ------------------------------------------------------------------
# Tools/Checkouts.ps1
# ------------------------------------------------------------------

PWSH = shutil.which("pwsh")
GIT = shutil.which("git")
if not (PWSH and GIT):
    print("  (Checkouts.ps1 cases skipped: no pwsh or git)")
else:
    def root_for(repo, env=""):
        script = (". '%s'; Get-CheckoutRoot -RepoRoot '%s' -Name LibX -EnvValue '%s' -Marker 'LibX-1.0.xml'"
                  % (os.path.join(ROOT, "Tools", "Checkouts.ps1"), repo, env))
        r = subprocess.run([PWSH, "-NoProfile", "-Command", script], capture_output=True, text=True)
        return os.path.normcase(os.path.normpath(r.stdout.strip()))

    def norm(p):
        return os.path.normcase(os.path.normpath(p))

    def git(*a, cwd):
        subprocess.run([GIT, *a], cwd=cwd, capture_output=True, check=True)

    with tempfile.TemporaryDirectory() as tmp:
        main = os.path.join(tmp, "projects", "Repo")
        os.makedirs(main)
        git("init", "-q", cwd=main)
        write(os.path.join(main, "a.txt"), "a\n")
        git("add", "a.txt", cwd=main)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a", cwd=main)
        wt = os.path.join(tmp, "scratch", "wt")
        git("worktree", "add", "-q", wt, cwd=main)
        lib = os.path.join(tmp, "projects", "LibX")
        write(os.path.join(lib, "LibX-1.0.xml"), "<Ui/>\n")

        check("the environment variable wins", root_for(wt, env="E:/elsewhere") == norm("E:/elsewhere"))
        check("a worktree finds the checkout beside the main one", root_for(wt) == norm(lib), root_for(wt))
        os.makedirs(os.path.join(tmp, "scratch", "LibX"))
        check("  an empty folder of that name beside the worktree doesn't win",
              root_for(wt) == norm(lib), root_for(wt))
        check("the main checkout finds its own neighbour", root_for(main) == norm(lib), root_for(main))
        shutil.rmtree(lib)
        check("none found: the neighbour path, for the caller's message",
              root_for(wt) == norm(os.path.join(tmp, "scratch", "LibX")), root_for(wt))
        git("worktree", "remove", "--force", wt, cwd=main)

print("test_devtools: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
