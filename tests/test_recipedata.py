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

check("the Apprentice rank spell (learnedat 9999) is dropped", gen.recipe_from_record(recs[0]) is None)

# A specialisation spell, as served on the Leatherworking page: 9999, no `rank`.
dragonscale = {"cat": 11, "id": 10656, "learnedat": 9999, "name": "Dragonscale Leatherworking",
               "skill": [165], "specialization": 10656, "quality": -1}
check("a specialisation spell (9999, no rank) is dropped", gen.recipe_from_record(dragonscale) is None)
find_herbs = {"id": 2383, "learnedat": 9999, "name": "Find Herbs", "skill": [182]}
check("a profession ability (Find Herbs) is dropped", gen.recipe_from_record(find_herbs) is None)

# ...but 9999 is Wowhead's "unknown", not "rank" (Codex review of #130): 28 new
# Forever recipes carry it WITH reagents. As served on the Leatherworking page:
adaptive = {"cat": 11, "id": 1252982, "learnedat": 9999, "name": "Beastculler's Adaptive Vest",
            "reagents": [[251651, 6], [8170, 32], [7082, 2]], "skill": [165]}
a = gen.recipe_from_record(adaptive)
check("a 9999 recipe with reagents is kept", a is not None, repr(a))
check("...with its requirement left unknown, not 9999 and not 0", a is not None and "learn" not in a, repr(a))

# The higher ranks, as served on the Alchemy page (review of #130: only 9999 was
# filtered, and 30 of these shipped as trainer recipes).
for rank, learn, sid in (("Journeyman", 50, 3101), ("Expert", 125, 3464), ("Artisan", 200, 11611)):
    rec = {"id": sid, "name": "Alchemy", "learnedat": learn, "rank": rank, "skill": [171], "source": [6]}
    check("the %s rank spell (learnedat %d) is dropped" % (rank, learn), gen.recipe_from_record(rec) is None)
# ...while Forever's Camping recipes carry a `rank` too, and are recipes.
mana_well = {"id": 1230564, "name": "Mana Well", "learnedat": 20, "rank": "Tier 1", "skill": [171],
             "colors": [0, 20, 22, 25], "creates": [279990, 1, 1], "source": [6]}
check("a Camping recipe with rank \"Tier 1\" is kept", gen.recipe_from_record(mana_well) is not None)
tier_enchant = {"id": 7, "learnedat": 40, "rank": "Tier 2", "skill": [333], "colors": [40, 50, 60, 70]}
check("a ranked recipe that makes nothing but has colours is kept", gen.recipe_from_record(tier_enchant) is not None)
r = gen.recipe_from_record(recs[2])
check("a recipe keeps skill, learn, colors, makes, src",
      r == {"skill": [171], "learn": 140, "colors": [140, 165, 185, 205], "makes": 3390, "src": [2, 16]}, repr(r))

enchant = {"id": 13648, "skill": [333], "learnedat": 170, "colors": [170, 190, 210, 230], "source": [5]}
e = gen.recipe_from_record(enchant)
check("an itemless enchant has no `makes` and is still a recipe", e is not None and "makes" not in e, repr(e))
smelt = {"id": 3308, "skill": [186], "learnedat": 155, "creates": [3577, 1, 1], "source": [6]}
check("smelting is a recipe that makes a bar", gen.recipe_from_record(smelt)["makes"] == 3577)
nosrc = {"id": 1, "skill": [165], "learnedat": 10, "reagents": [[2318, 1]]}
check("an unknown source is left out, not invented", "src" not in gen.recipe_from_record(nosrc))
check("a record with no skill line is an error",
      raises(lambda: gen.recipe_from_record({"id": 5, "learnedat": 1, "reagents": [[2318, 1]]})))

# ---------------------------------------------------------------------------
# Recipe items -> recipes, by name within a profession
# ---------------------------------------------------------------------------

check("the item prefix goes", gen.match_name("Recipe: Elixir of Lesser Agility") == "elixir of lesser agility")
check("every profession's prefix goes",
      all(gen.match_name(p + ": Thing") == "thing"
          for p in ("Pattern", "Plans", "Schematic", "Formula", "Manual", "Design", "Blueprint")))
check("punctuation does not count: a transmute's colon",
      gen.match_name("Recipe: Transmute Iron to Gold") == gen.match_name("Transmute: Iron to Gold"))
check("nor a hyphen or doubled spaces",
      gen.match_name("Formula: Enchant Bracer - Deflection") == gen.match_name("Enchant Bracer -  Deflection"))
check("nor an apostrophe",
      gen.match_name("Recipe: Elixir of Ogre's Strength") == gen.match_name("Elixir of Ogres Strength")
      and "'" not in gen.match_name("Pattern: Enchanter's Cowl"))

rec = {
    2335: {"skill": [171], "learn": 60},
    3230: {"skill": [171], "learn": 1},
    11479: {"skill": [171], "learn": 225},
    500: {"skill": [171], "learn": 100},      # two Alchemy recipes of one name ...
    501: {"skill": [171], "learn": 200},
    9000: {"skill": [197], "learn": 1},       # ... and a Tailoring one that shares a name with an Alchemy item
}
names = {2335: "Swiftness Potion", 3230: "Elixir of Minor Agility", 11479: "Transmute: Iron to Gold",
         500: "Twin", 501: "Twin", 9000: "Elixir of Giants"}
items = [
    {"id": 2555, "classs": 9, "subclass": 6, "name": "Recipe: Swiftness Potion", "skill": 55},
    {"id": 2553, "classs": 9, "subclass": 6, "name": "Recipe: Elixir of Minor Agility", "skill": 1},
    {"id": 9303, "classs": 9, "subclass": 6, "name": "Recipe: Transmute Iron to Gold", "skill": 225},
    {"id": 7000, "classs": 9, "subclass": 6, "name": "Recipe: Twin", "skill": 100},
    {"id": 9224, "classs": 9, "subclass": 6, "name": "Recipe: Elixir of Giants", "skill": 245},
    {"id": 4444, "classs": 0, "subclass": 6, "name": "Swiftness Potion"},
]
linked, unmatched, ambiguous = gen.link_items(rec, names, items, 171)
check("an item links to the one recipe it names", rec[2335].get("items") == [2555], repr(rec[2335]))
check("a transmute links across the colon", rec[11479].get("items") == [9303], repr(rec[11479]))
check("an item naming two recipes links to neither", "items" not in rec[500] and "items" not in rec[501])
check("a recipe of another profession is never linked", "items" not in rec[9000])
check("a non-recipe item is ignored", all(4444 not in r.get("items", []) for r in rec.values()))
check("the counts add up", (linked, unmatched, ambiguous) == (3, 1, 1), repr((linked, unmatched, ambiguous)))

# Another profession's item on this listing does not link to a same-named recipe here.
rec2 = {3230: {"skill": [171], "learn": 1}}
stray = [{"id": 8888, "classs": 9, "subclass": 2, "name": "Recipe: Elixir of Minor Agility"}]
gen.link_items(rec2, {3230: "Elixir of Minor Agility"}, stray, 171, subclass=6)
check("an item of another profession's subclass is never linked", "items" not in rec2[3230], repr(rec2))

# Overrides: applied first, and an override that points at nothing is an error.
rec3 = {3188: {"skill": [171], "learn": 175}}
ogre = [{"id": 6211, "classs": 9, "subclass": 6, "name": "Recipe: Elixir of Ogre's Strength"}]
gen.link_items(rec3, {3188: "Elixir of Ogre Strength"}, ogre, 171, subclass=6, overrides={6211: 3188})
check("an override links a recipe whose name differs", rec3[3188].get("items") == [6211], repr(rec3))
check("an override to a recipe that is not there is an error",
      raises(lambda: gen.link_items({}, {}, ogre, 171, subclass=6, overrides={6211: 3188})))
check("every shipped override names a different item",
      len(set(gen.ITEM_OVERRIDES)) == len(gen.ITEM_OVERRIDES))

good = [{"id": i, "classs": 9, "subclass": 6} for i in range(40)]
check("a listing of the profession's recipe items passes",
      not raises(lambda: gen.check_item_page(good, 6, "p")))
check("an empty listing is refused", raises(lambda: gen.check_item_page([], 6, "p")))
check("another profession's listing is refused",
      raises(lambda: gen.check_item_page([{"id": i, "classs": 9, "subclass": 2} for i in range(40)], 6, "p")))
check("a tiny listing that is half another profession's is refused (2 of 3)",
      raises(lambda: gen.check_item_page([{"id": 1, "classs": 9, "subclass": 9},
                                          {"id": 2, "classs": 9, "subclass": 2},
                                          {"id": 3, "classs": 9, "subclass": 2}], 9, "p")))
check("a listing that is not recipe items is refused",
      raises(lambda: gen.check_item_page([{"id": i, "classs": 4, "subclass": 6} for i in range(40)], 6, "p")))

linked_text = gen.render_lua({2335: {"skill": [171], "learn": 60, "items": [2555]}}, "x")
check("linked items are written", "[2335]={skill={171},learn=60,items={2555}}," in linked_text, linked_text)

# ---------------------------------------------------------------------------
# Page checks and merging
# ---------------------------------------------------------------------------

check("an empty page is refused", raises(lambda: gen.check_page([], 171, "p")))
check("a 1000-row page is refused (Wowhead's cap: a wrong slug returns one)",
      raises(lambda: gen.check_page([{"id": i, "skill": [171]} for i in range(1000)], 171, "p")))
check("a mostly-foreign page is refused",
      raises(lambda: gen.check_page([{"id": i, "skill": [185]} for i in range(50)], 171, "p")))
check("a tiny page that is all someone else's is refused (2 foreign of 2)",
      raises(lambda: gen.check_page([{"id": i, "skill": [185]} for i in range(2)], 171, "p")))
check("a small page that is half someone else's is refused (2 foreign of 4)",
      raises(lambda: gen.check_page([{"id": i, "skill": [393]} for i in range(2)] + [{"id": 9 + i, "skill": [185]} for i in range(2)], 393, "p")))
check("a page with 3 foreign rows is refused however large",
      raises(lambda: gen.check_page([{"id": i, "skill": [197]} for i in range(40)] + [{"id": 90 + i, "skill": [165]} for i in range(3)], 197, "p")))
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
    1252982: {"skill": [165]},
}
text = gen.render_lua(recipes, "wowhead forever 2026-09-30")
check("rows are sorted by spell ID", text.index("[2333]") < text.index("[3308]") < text.index("[13648]"))
check("the same data renders the same bytes", text == gen.render_lua(dict(reversed(list(recipes.items()))), "wowhead forever 2026-09-30"))
check("an itemless enchant has no makes=", "[13648]={skill={333},learn=170,src={5}}," in text, text)
check("the source line reads back", gen.source_line(text) == "wowhead forever 2026-09-30")
rows = gen.recipes_in_lua(text)
check("the rows read back", sorted(rows) == [2333, 3308, 13648, 1252982], repr(sorted(rows)))
check("an unknown requirement renders without learn=", "[1252982]={skill={165}}," in text, text)

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
gen.build = lambda refresh, log, meta=None: {k: dict(v) for k, v in recipes.items()}
try:
    quiet = open(os.devnull, "w")
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        rc_check = gen.main(["--check", "--out", out, "--reference", tmp])
        gen.main(["--out", out, "--reference", tmp])
    finally:
        sys.stdout = old_stdout
    check("--check passes on unchanged content", rc_check == 0, str(rc_check))
    check("an unchanged rerun keeps the old source date",
          gen.source_line(open(out, encoding="utf-8").read()) == "wowhead forever 2026-01-01")

    grown = {k: dict(v) for k, v in recipes.items()}
    grown[99999] = {"skill": [185], "learn": 1}
    gen.build = lambda refresh, log, meta=None: grown
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        rc_changed = gen.main(["--check", "--out", out, "--reference", tmp])
    finally:
        sys.stdout = old_stdout
    check("--check fails when a recipe was added", rc_changed == 1, str(rc_changed))
    check("--check writes nothing", "[99999]" not in open(out, encoding="utf-8").read())

    # --check covers the whole file, not only the rows: a header edited by hand
    # (or a changed row format) is a difference.
    gen.build = lambda refresh, log, meta=None: {k: dict(v) for k, v in recipes.items()}
    body = open(out, encoding="utf-8").read()
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(body.replace("-- GENERATED", "-- generated", 1))
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        rc_header = gen.main(["--check", "--out", out, "--reference", tmp])
    finally:
        sys.stdout = old_stdout
    check("--check notices a changed header", rc_header == 1, str(rc_header))

    # A source line that no longer reads back is replaced by today's date, never
    # written as `source = null` (which Lua reads as nil, for ever after).
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(body.replace('source = "wowhead forever 2026-01-01",', "source = 'hand edited',", 1))
    old_stdout, sys.stdout = sys.stdout, quiet
    try:
        gen.main(["--out", out, "--reference", tmp])
    finally:
        sys.stdout = old_stdout
    rewritten = open(out, encoding="utf-8").read()
    check("an unreadable source line becomes a dated one, not null",
          "null" not in rewritten and (gen.source_line(rewritten) or "").startswith("wowhead forever "),
          rewritten.splitlines()[10] if len(rewritten.splitlines()) > 10 else rewritten)
finally:
    gen.build = real_build

# ---------------------------------------------------------------------------
# The human-readable reference (C:\Projects\References, like the consumables list)
# ---------------------------------------------------------------------------

meta = {2333: {"name": "Elixir of Lesser Agility", "profession": "Alchemy", "status": "unchanged"},
        13648: {"name": "Enchant Bracer - Stamina", "profession": "Enchanting", "status": "new"},
        3308: {"name": "Smelt Gold", "profession": "Mining", "status": "unchanged"},
        1252982: {"name": "Beastculler's Adaptive Vest | x", "profession": "Leatherworking", "status": "new"}}
rows = gen.reference_rows(recipes, meta)
check("reference rows are sorted by profession", [r["profession"] for r in rows] ==
      ["Alchemy", "Enchanting", "Leatherworking", "Mining"], repr([r["profession"] for r in rows]))
by = {r["id"]: r for r in rows}
check("an unknown requirement shows as ?, not 0", by[1252982]["learn"] == "?")
check("sources are labelled", by[2333]["source"] == "drop, fished", by[2333]["source"])
check("an unknown source code is shown as a code, not guessed",
      gen._sources({"src": [2, 99]}) == "drop, code 99")
tsv = gen.render_reference_tsv(rows)
check("the TSV has a header and one line per recipe", len(tsv.strip().split("\n")) == 5)
md = gen.render_reference_md(rows, "wowhead forever 2026-09-30")
check("the Markdown is titled by the snapshot date", md.startswith("# WoW: Forever recipes - Wowhead snapshot 2026-09-30"))
check("a | in a name cannot break the table", "Beastculler's Adaptive Vest / x" in md)

refdir = tempfile.mkdtemp()
gen.write_reference(refdir, recipes, meta, "wowhead forever 2026-09-30", lambda m: None)
check("write_reference names both files by the snapshot date",
      sorted(os.listdir(refdir)) == ["forever-recipes-2026-09-30.md", "forever-recipes-2026-09-30.tsv"],
      repr(os.listdir(refdir)))
gen.write_reference(os.path.join(refdir, "missing"), recipes, meta, "wowhead forever 2026-09-30", lambda m: None)
check("a missing reference folder is skipped, not created", not os.path.exists(os.path.join(refdir, "missing")))

print("test_recipedata: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
