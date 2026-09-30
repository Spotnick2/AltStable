#!/usr/bin/env python
"""Tests for the recipe data generator (Tools/RecipeData/gen-recipes.py, #14).

Plain stdlib, same shape as test_cutouts.py. The generator's network half is
never run here; these feed it trimmed copies of what Wowhead's pages actually
contain (measured 2026-09-29) and check the decisions: what is a recipe, what
makes a page untrustworthy, and that the output is stable.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "Tools", "RecipeData"))

import importlib.util

spec = importlib.util.spec_from_file_location(
    "gen_recipes", os.path.join(HERE, "..", "Tools", "RecipeData", "gen-recipes.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

passed = failed = 0


def check(label, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("  FAIL: %s  -- %s" % (label, detail))


def raises(fn):
    try:
        fn()
    except gen.DataError:
        return True
    return False


# ---------------------------------------------------------------------------
# Parsing the embedded JavaScript
# ---------------------------------------------------------------------------

# Trimmed from /forever/spells/professions/alchemy: quoted keys, then a few bare
# ones at the end of the record (quality:-1, popularity:80), exactly as served.
ALCHEMY_PAGE = r'''<script>
var listviewspells = [{"cat":11,"displayName":"Alchemy","id":2259,"learnedat":9999,"level":0,"name":"Alchemy","nskillup":1,"rank":"Apprentice","schools":1,"skill":[171],"source":[6],"trainingcost":10,"envChange":{"status":"unchanged","labels":[],"lines":[]},quality:-1,popularity:80},{"cat":11,"colors":[1,55,75,95],"creates":[2454,1,1],"displayName":"Elixir of Minor Strength","id":2329,"learnedat":1,"level":0,"name":"Elixir of Minor Strength","nskillup":1,"quality":1,"reagents":[[2449,1],[765,1],[3371,1]],"schools":1,"skill":[171],"source":[6],"trainingcost":50,"envChange":{"status":"updated","labels":["renamed","reworded"],"lines":["Renamed from Elixir of Lion's Strength","Same numbers, rew: {x} ]"]},popularity:12},{"cat":11,"colors":[140,165,185,205],"creates":[3390,1,1],"displayName":"Elixir of Lesser Agility","id":2333,"learnedat":140,"level":0,"name":"Elixir of Lesser Agility","nskillup":1,"quality":1,"reagents":[[3355,1]],"schools":1,"skill":[171],"source":[2,16],"envChange":{"status":"unchanged","labels":[],"lines":[]},popularity:76}];
new Listview({template: 'spell', id: 'spells', data: listviewspells});
</script>'''

recs = gen.parse_listview_var(ALCHEMY_PAGE, "listviewspells")
check("three records parsed", len(recs) == 3, str(len(recs)))
check("bare keys quoted (quality)", recs[0].get("quality") == -1, repr(recs[0].get("quality")))
check("a colon, braces and ] inside a string survive untouched",
      recs[1]["envChange"]["lines"][1] == "Same numbers, rew: {x} ]", repr(recs[1]["envChange"]["lines"]))
check("nested arrays (reagents)", recs[1]["reagents"] == [[2449, 1], [765, 1], [3371, 1]])

check("a key-looking word inside a string is not quoted",
      gen.js_to_json('{"name":"a,b:c",k:1}') == '{"name":"a,b:c","k":1}',
      gen.js_to_json('{"name":"a,b:c",k:1}'))
check("whitespace before a bare key", gen.js_to_json('{ a: 1, b :2}') == '{ "a": 1, "b" :2}',
      gen.js_to_json('{ a: 1, b :2}'))
check("a JS expression as a value is rejected, not guessed",
      raises(lambda: gen.parse_listview_var("var listviewspells = [{a: WH.TERMS.x}];", "listviewspells")))
check("single-quoted strings are refused", raises(lambda: gen.js_to_json("{a:'x'}")))
check("a page without the listview is an error", raises(lambda: gen.parse_listview_var("<html></html>", "listviewspells")))
check("an unbalanced array is an error", raises(lambda: gen.extract_array("x = [1, [2, 3]", 0)))

# ---------------------------------------------------------------------------
# Records -> recipes
# ---------------------------------------------------------------------------

check("the rank spell (learnedat 9999) is dropped", gen.recipe_from_record(recs[0]) is None)
r = gen.recipe_from_record(recs[2])
check("a recipe keeps skill, learn, colors, makes, src",
      r == {"skill": [171], "learn": 140, "colors": [140, 165, 185, 205], "makes": 3390, "src": [2, 16]}, repr(r))

enchant = {"id": 13648, "skill": [333], "learnedat": 170, "colors": [170, 190, 210, 230], "source": [5]}
e = gen.recipe_from_record(enchant)
check("an itemless enchant has no `makes` and is still a recipe", e is not None and "makes" not in e, repr(e))
smelt = {"id": 3308, "skill": [186], "learnedat": 155, "creates": [3577, 1, 1], "source": [6]}
check("smelting is a recipe that makes a bar", gen.recipe_from_record(smelt)["makes"] == 3577)
nosrc = {"id": 1, "skill": [165], "learnedat": 10}
check("an unknown source is left out, not invented", "src" not in gen.recipe_from_record(nosrc))
check("a record with no skill line is an error", raises(lambda: gen.recipe_from_record({"id": 5, "learnedat": 1})))

# ---------------------------------------------------------------------------
# Page checks and merging
# ---------------------------------------------------------------------------

check("an empty page is refused", raises(lambda: gen.check_page([], 171, "p")))
check("a 1000-row page is refused (Wowhead's cap: a wrong slug returns one)",
      raises(lambda: gen.check_page([{"id": i, "skill": [171]} for i in range(1000)], 171, "p")))
check("a mostly-foreign page is refused",
      raises(lambda: gen.check_page([{"id": i, "skill": [185]} for i in range(50)], 171, "p")))
check("one neighbouring spell is tolerated (tailoring lists one leatherworking spell)",
      not raises(lambda: gen.check_page([{"id": i, "skill": [197]} for i in range(50)] + [{"id": 99, "skill": [165]}], 197, "p")))

held = {}
gen.merge(held, 1, {"skill": [171], "learn": 1}, "a")
check("the same recipe on two pages merges", not raises(lambda: gen.merge(held, 1, {"skill": [171], "learn": 1}, "b")))
check("a disagreeing duplicate is an error", raises(lambda: gen.merge(held, 1, {"skill": [171], "learn": 2}, "b")))

# ---------------------------------------------------------------------------
# Lua output: stable, and readable back for --check
# ---------------------------------------------------------------------------

recipes = {
    2333: {"skill": [171], "learn": 140, "colors": [140, 165, 185, 205], "makes": 3390, "src": [2, 16]},
    13648: {"skill": [333], "learn": 170, "src": [5]},
    3308: {"skill": [186], "learn": 155, "makes": 3577, "src": [6]},
}
text = gen.render_lua(recipes, "wowhead forever 2026-09-30")
check("rows are sorted by spell ID", text.index("[2333]") < text.index("[3308]") < text.index("[13648]"))
check("the same data renders the same bytes", text == gen.render_lua(dict(reversed(list(recipes.items()))), "wowhead forever 2026-09-30"))
check("an itemless enchant has no makes=", "[13648]={skill={333},learn=170,src={5}}," in text, text)
check("the source line reads back", gen.source_line(text) == "wowhead forever 2026-09-30")
rows = gen.recipes_in_lua(text)
check("the rows read back", sorted(rows) == [2333, 3308, 13648], repr(sorted(rows)))

# The file must be valid Lua: luac -p when it is on PATH (CI has luac5.1).
import shutil
import subprocess
luac = shutil.which("luac") or shutil.which("luac5.1")
if luac:
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
        f.write(text)
    res = subprocess.run([luac, "-p", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    check("the output is valid Lua", res.returncode == 0, res.stderr)

# main(): a rerun with unchanged content keeps the old `source` date, so the file
# only changes when the data does; --check says whether it would.
tmp = tempfile.mkdtemp()
out = os.path.join(tmp, "RecipeData.lua")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    f.write(gen.render_lua(recipes, "wowhead forever 2026-01-01"))
real_build = gen.build
gen.build = lambda refresh, log: {k: dict(v) for k, v in recipes.items()}
try:
    quiet = open(os.devnull, "w")
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        rc_check = gen.main(["--check", "--out", out])
        gen.main(["--out", out])
    finally:
        sys.stdout = old_stdout
    check("--check passes on unchanged content", rc_check == 0, str(rc_check))
    check("an unchanged rerun keeps the old source date",
          gen.source_line(open(out, encoding="utf-8").read()) == "wowhead forever 2026-01-01")

    grown = {k: dict(v) for k, v in recipes.items()}
    grown[99999] = {"skill": [185], "learn": 1}
    gen.build = lambda refresh, log: grown
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        rc_changed = gen.main(["--check", "--out", out])
    finally:
        sys.stdout = old_stdout
    check("--check fails when a recipe was added", rc_changed == 1, str(rc_changed))
    check("--check writes nothing", "[99999]" not in open(out, encoding="utf-8").read())
finally:
    gen.build = real_build

print("test_recipedata: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
