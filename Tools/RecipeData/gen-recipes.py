#!/usr/bin/env python
r"""Generate the Professions plugin's recipe data from Wowhead's Forever database (#14).

The client can list a profession's recipes only while that profession's window is
open (measured on 1.60.1.70124, docs/forever-api-notes.md, Professions). It cannot
say which ITEM teaches a recipe, where a recipe comes from, or what the skill
thresholds are for an alt who is not logged in. Wowhead can, and its Forever pages
embed the whole list as JSON. This turns those pages into a Lua table.

Facts only: spell and item IDs and numbers. No names - the client resolves those
at runtime, in the player's own language, and a rename cannot leave them stale.

    python Tools/RecipeData/gen-recipes.py              # fetch (cached), write RecipeData.lua
    python Tools/RecipeData/gen-recipes.py --refresh    # ignore the cache
    python Tools/RecipeData/gen-recipes.py --check      # compare with the committed file, write nothing

A run also writes a human-readable copy - names included, one table per profession -
to C:\Projects\References\forever-recipes-<snapshot date>.md/.tsv, beside the API
dumps and the consumables list (--reference DIR to put it elsewhere, '' to skip).

Run by the owner, never by CI (tests/test_recipedata.py covers the parsing with
fixtures). Twelve page requests, 1.5 s apart; the cache under .cache/ makes a
rerun free.

What the pages contain, measured 2026-09-29:
  * /forever/spells/professions/<slug> and /forever/spells/secondary-skills/<slug>
    carry `var listviewspells = [...]`: one record per spell with `id`, `skill`
    (a list of skill lines), `learnedat` (9999 when Wowhead does not know it),
    `colors` (the four difficulty thresholds), `creates` ([item, min, max], absent
    for an enchant), `reagents`, `source` (codes, below), `trainingcost`.
  * The wrong slug does not 404 - it returns a mixed listing capped at 1000 rows
    (cooking under professions/ did exactly that). Every page is therefore checked:
    fewer than 1000 rows, and every row's skill list contains the expected line.

Which ITEM teaches a recipe is deliberately not here. It is only on each spell's
own page (/forever/spell=<id>, the `used-by-item` listview, filtered to Recipe
items), and fetching those one by one - about 2000 pages - got the generator a
403 from Wowhead after roughly 110 of them on 2026-09-29. A block is an answer:
this tool does not retry, rotate or disguise itself around it. The item tooltips
(#14, PR 3) will need another source - the per-profession recipe-item listings
(/forever/items=9.<subclass>, a dozen pages) are the candidate.

Wowhead source codes seen on these pages (kept as numbers; the plugin labels the
ones it knows and shows anything else as "other"):
  1 crafted  2 drop  3 pvp  4 quest  5 vendor  6 trainer  7 discovery
  16 fished  21 pickpocketed
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
OUT = os.path.join(HERE, "RecipeData.lua")
REFERENCES = r"C:\Projects\References"
BASE = "https://www.wowhead.com/forever"
USER_AGENT = "AltStable recipe data generator (github.com/Spotnick2/AltStable)"
DELAY = 1.5
LISTVIEW_CAP = 1000

# (page path, skill line). Jewelcrafting does not exist on Forever. The gathering
# professions are here because Forever gave them recipes (Skinning: Camp Chair).
PROFESSIONS = [
    ("professions/alchemy", 171),
    ("professions/blacksmithing", 164),
    ("professions/enchanting", 333),
    ("professions/engineering", 202),
    ("professions/herbalism", 182),
    ("professions/leatherworking", 165),
    ("professions/mining", 186),
    ("professions/skinning", 393),
    ("professions/tailoring", 197),
    ("secondary-skills/cooking", 185),
    ("secondary-skills/first-aid", 129),
    ("secondary-skills/fishing", 356),
]


PROFESSION_NAMES = {line: path.split("/")[1].replace("-", " ").title() for path, line in PROFESSIONS}
SOURCE_LABELS = {1: "crafted", 2: "drop", 3: "pvp", 4: "quest", 5: "vendor", 6: "trainer",
                 7: "discovery", 16: "fished", 21: "pickpocketed"}


class DataError(Exception):
    pass


# ---------------------------------------------------------------------------
# Parsing Wowhead's embedded JavaScript
# ---------------------------------------------------------------------------

def _string_end(text, i):
    """Index just past the string literal that starts at text[i] (a quote)."""
    quote = text[i]
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i + 1
        i += 1
    raise DataError("unterminated string literal")


def extract_array(text, start):
    """The balanced [...] beginning at or after `start`, skipping brackets in strings."""
    i = text.index("[", start)
    begin, depth = i, 0
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = _string_end(text, i)
            continue
        if c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
            if depth == 0:
                return text[begin:i + 1]
        i += 1
    raise DataError("unbalanced array")


_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_COLON = re.compile(r"\s*:")


def js_to_json(js):
    """Quote bare object keys, outside strings only. Anything else non-JSON fails in json.loads.

    Wowhead writes most keys quoted and a few bare (`quality:-1`, `firstseenpatch: 0`).
    A regex over the whole text would also rewrite `"a,b:c"` inside a name, which is
    why this walks the text instead.
    """
    out, i, n = [], 0, len(js)
    last = ""  # last non-space character emitted
    while i < n:
        c = js[i]
        if c == '"':
            j = _string_end(js, i)
            out.append(js[i:j])
            last = '"'
            i = j
            continue
        if c == "'":
            raise DataError("single-quoted string in data")
        if c.isspace():
            out.append(c)
            i += 1
            continue
        m = _KEY.match(js, i)
        if m:
            word = m.group(0)
            if last in "{," and _COLON.match(js, m.end()):
                out.append('"%s"' % word)
            else:
                out.append(word)
            last = word[-1]
            i = m.end()
            continue
        out.append(c)
        last = c
        i += 1
    return "".join(out)


def _loads(js, what):
    try:
        return json.loads(js_to_json(js))
    except ValueError as e:
        raise DataError("%s is not plain data: %s" % (what, e))


def parse_listview_var(html, var):
    """`var <var> = [...];` -> list of dicts."""
    m = re.search(r"var %s\s*=\s*\[" % re.escape(var), html)
    if not m:
        raise DataError("no `var %s` on the page" % var)
    return _loads(extract_array(html, m.end() - 1), var)


# ---------------------------------------------------------------------------
# Turning records into the plugin's data
# ---------------------------------------------------------------------------

def is_profession_spell(rec):
    """The profession's own spells, which are not recipes: its ranks (Apprentice ..
    Artisan), specialisations (Dragonscale Leatherworking) and abilities (Find
    Herbs, Smelting, Tanning, Bait and Tackle).

    What they share is making nothing from nothing: no reagents, no product, no
    difficulty thresholds. Every one of the 112 such records on the 12 pages
    (2026-09-29) is one of those, and no recipe is.

    Two tests that look right and are not (reviews of #130):
      * `learnedat == 9999` - it catches Apprentice and the specialisations, but
        also 28 new Forever recipes WITH reagents (the "Adaptive" armour sets,
        Sludge Suppressor, Cleansing Stew) whose requirement is simply unknown;
      * `rank` - Forever's Camping recipes carry "Tier 1".."Tier 3".
    """
    return not rec.get("reagents") and not rec.get("creates") and not rec.get("colors")


def recipe_from_record(rec):
    """One listviewspells record -> the fields the plugin keeps, or None for a profession spell.

    `learn` is left out when Wowhead's value is its 9999 placeholder: the
    requirement is unknown, which is not the same as none.
    """
    if is_profession_spell(rec):
        return None
    skills = rec.get("skill") or []
    if not skills:
        raise DataError("spell %s has no skill line" % rec.get("id"))
    out = {"skill": sorted(skills)}
    learn = int(rec.get("learnedat") or 0)
    if learn != 9999:
        out["learn"] = learn
    colors = rec.get("colors")
    if colors:
        out["colors"] = [int(c) for c in colors]
    creates = rec.get("creates")
    if creates:
        out["makes"] = int(creates[0])
    src = rec.get("source")
    if src:
        out["src"] = sorted(int(s) for s in src)
    return out


def check_page(records, skill_line, path):
    if not records:
        raise DataError("%s: no rows" % path)
    if len(records) >= LISTVIEW_CAP:
        raise DataError("%s: %d rows - Wowhead's cap, so this is a truncated or wrong listing"
                        % (path, len(records)))
    foreign = [r["id"] for r in records if skill_line not in (r.get("skill") or [])]
    # A page may carry the odd spell of a neighbouring line (tailoring lists one
    # leatherworking spell). More than that - or a page that is half someone
    # else's, however small - means the slug is wrong.
    if len(foreign) > max(2, len(records) // 20) or len(foreign) * 2 >= len(records):
        raise DataError("%s: %d of %d rows are not skill %d - wrong page?"
                        % (path, len(foreign), len(records), skill_line))


def merge(recipes, spell_id, recipe, path):
    held = recipes.get(spell_id)
    if held is None:
        recipes[spell_id] = recipe
    elif held != recipe:
        raise DataError("spell %d differs between pages (%s): %r vs %r" % (spell_id, path, held, recipe))


# ---------------------------------------------------------------------------
# Lua output
# ---------------------------------------------------------------------------

def _lua_list(values):
    return "{" + ",".join(str(v) for v in values) + "}"


def render_lua(recipes, source):
    lines = [
        "-- GENERATED by Tools/RecipeData/gen-recipes.py from Wowhead's Forever database.",
        "-- Do not edit by hand: rerun the generator (it says how) and commit the result.",
        "--",
        "-- recipes[spellID] = { skill = {skill lines}, learn = required skill or nil (unknown),",
        "--                      colors = {orange, yellow, green, grey} or nil,",
        "--                      makes = crafted item or nil (enchants make none),",
        "--                      src = Wowhead source codes or nil (unknown) }",
        "-- Source codes: 1 crafted 2 drop 3 pvp 4 quest 5 vendor 6 trainer 7 discovery",
        "--               16 fished 21 pickpocketed; anything else is shown as \"other\".",
        "AltStableRecipeData = {",
        "source = %s," % json.dumps(source),
        "recipes = {",
    ]
    for spell_id in sorted(recipes):
        r = recipes[spell_id]
        fields = ["skill=%s" % _lua_list(r["skill"])]
        if "learn" in r:
            fields.append("learn=%d" % r["learn"])
        if "colors" in r:
            fields.append("colors=%s" % _lua_list(r["colors"]))
        if "makes" in r:
            fields.append("makes=%d" % r["makes"])
        if "src" in r:
            fields.append("src=%s" % _lua_list(r["src"]))
        lines.append("[%d]={%s}," % (spell_id, ",".join(fields)))
    lines += ["},", "}", ""]
    return "\n".join(lines)


_ROW = re.compile(r"^\[(\d+)\]=(\{.*\}),$")


def recipes_in_lua(text):
    """The committed file's recipe rows, as {spellID: row text} - for --check."""
    return {int(m.group(1)): m.group(2) for m in map(_ROW.match, text.splitlines()) if m}


def source_line(text):
    m = re.search(r'^source = (".*"),$', text, re.M)
    return json.loads(m.group(1)) if m else None


# ---------------------------------------------------------------------------
# The human-readable reference, in C:\Projects\References beside the API dumps
# and the consumables list: for people and other projects, not for the addon
# ---------------------------------------------------------------------------

def _sources(recipe):
    return ", ".join(SOURCE_LABELS.get(c, "code %d" % c) for c in recipe.get("src", []))


def reference_rows(recipes, meta):
    """One row per recipe, sorted by profession, required skill (unknown last), name."""
    rows = []
    for sid, r in recipes.items():
        m = meta.get(sid, {})
        rows.append({
            "id": sid, "name": m.get("name", ""), "profession": m.get("profession", ""),
            "learn": str(r["learn"]) if "learn" in r else "?",
            "colors": "/".join(str(c) for c in r.get("colors", [])),
            "makes": str(r.get("makes", "")), "source": _sources(r), "status": m.get("status", ""),
        })
    rows.sort(key=lambda x: (x["profession"], int(x["learn"]) if x["learn"] != "?" else 99999,
                             x["name"], x["id"]))
    return rows


REFERENCE_COLUMNS = ["id", "profession", "learn", "colors", "makes", "source", "status", "name"]


def render_reference_tsv(rows):
    out = ["\t".join(REFERENCE_COLUMNS)]
    for r in rows:
        out.append("\t".join(str(r[c]).replace("\t", " ") for c in REFERENCE_COLUMNS))
    return "\n".join(out) + "\n"


def render_reference_md(rows, source):
    date = source.rsplit(" ", 1)[-1]
    lines = [
        "# WoW: Forever recipes - Wowhead snapshot %s" % date,
        "",
        "Every recipe on Wowhead's Forever profession pages, as turned into the Professions",
        "plugin's data by `AltStable/Tools/RecipeData/gen-recipes.py`. %d recipes; the raw TSV" % len(rows),
        "is next to this file.",
        "",
        "**Wowhead's, not the client's.** The client lists a profession's recipes only while its",
        "window is open, and that list is the authority for what a character can see. Where the",
        "two disagree the client wins: Leatherworking here carries 12 new \"Adaptive\" recipes",
        "that the client's 592 (1.60.1.70124) do not appear to include.",
        "",
        "Columns: spell ID (= the client's recipe ID), required skill (`?` = Wowhead does not",
        "know - not 0), difficulty thresholds (orange/yellow/green/grey), crafted item ID (empty",
        "for enchants), sources, and Wowhead's change flag against Vanilla (`new` = Forever-only).",
        "Profession spells (ranks, specialisations, Find Herbs, Smelting...) are not recipes and",
        "are left out.",
        "",
        "**Diffing:** rerun the generator after a patch. The file is named by the snapshot date,",
        "which only moves when a recipe changed.",
    ]
    current = None
    for r in rows:
        if r["profession"] != current:
            current = r["profession"]
            n = sum(1 for x in rows if x["profession"] == current)
            lines += ["", "## %s (%d)" % (current, n), "",
                      "| ID | Name | Skill | Colours | Makes | Source | Status |",
                      "|---:|---|---:|---|---:|---|---|"]
        lines.append("| %d | %s | %s | %s | %s | %s | %s |" % (
            r["id"], r["name"].replace("|", "/"), r["learn"], r["colors"], r["makes"],
            r["source"], r["status"]))
    return "\n".join(lines) + "\n"


def write_reference(directory, recipes, meta, source, log):
    if not directory or not os.path.isdir(directory):
        log("reference: %r not found - skipped" % directory)
        return
    rows = reference_rows(recipes, meta)
    stem = os.path.join(directory, "forever-recipes-%s" % source.rsplit(" ", 1)[-1])
    with open(stem + ".md", "w", encoding="utf-8", newline="\n") as f:
        f.write(render_reference_md(rows, source))
    with open(stem + ".tsv", "w", encoding="utf-8", newline="\n") as f:
        f.write(render_reference_tsv(rows))
    log("wrote %s.md / .tsv" % stem)


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

_last_fetch = [0.0]


def fetch(url, refresh, parse):
    """GET with a disk cache -> parse(html). The parse must succeed before anything is cached."""
    key = hashlib.sha1(url.encode()).hexdigest()
    path = os.path.join(CACHE, key + ".html")
    if not refresh and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return parse(f.read())
    wait = DELAY - (time.time() - _last_fetch[0])
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        html = resp.read().decode("utf-8")
    _last_fetch[0] = time.time()
    parsed = parse(html)
    os.makedirs(CACHE, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
    return parsed


def build(refresh, log, meta=None):
    """All recipes, merged across pages. `meta`, when given, collects each kept
    recipe's name, profession and Wowhead change status for the reference."""
    recipes = {}
    for path, skill_line in PROFESSIONS:
        url = "%s/spells/%s" % (BASE, path)
        records = fetch(url, refresh, lambda h: parse_listview_var(h, "listviewspells"))
        check_page(records, skill_line, path)
        kept = 0
        for rec in records:
            recipe = recipe_from_record(rec)
            if recipe is not None:
                merge(recipes, int(rec["id"]), recipe, path)
                kept += 1
                if meta is not None:
                    meta.setdefault(int(rec["id"]), {
                        "name": rec.get("name") or "",
                        # The spell's own line: a page can carry a neighbour's spell.
                        "profession": PROFESSION_NAMES.get(
                            skill_line if skill_line in recipe["skill"] else recipe["skill"][0],
                            str(recipe["skill"][0])),
                        "status": (rec.get("envChange") or {}).get("status") or "",
                    })
        log("%-30s %4d rows, %4d recipes" % (path, len(records), kept))

    return recipes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--refresh", action="store_true", help="ignore the cache and fetch everything again")
    ap.add_argument("--check", action="store_true", help="compare with the committed file; write nothing")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--reference", default=REFERENCES,
                    help="folder for the human-readable .md/.tsv reference ('' to skip)")
    args = ap.parse_args(argv)

    def log(msg):
        print(msg, flush=True)

    meta = {}
    recipes = build(args.refresh, log, meta)
    old_text = ""
    if os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as f:
            old_text = f.read()
    old_rows = recipes_in_lua(old_text)

    # `source` names the snapshot the content came from. It changes only when the
    # content does, so a rerun that finds nothing new writes the same bytes.
    probe = recipes_in_lua(render_lua(recipes, ""))
    # A committed file whose source line no longer reads back gets today's date,
    # not `source = null` for ever after (review of #130).
    source = (probe == old_rows and source_line(old_text)) or \
        "wowhead forever %s" % time.strftime("%Y-%m-%d")
    text = render_lua(recipes, source)
    # --check compares the WHOLE file: a change to the header or the row format
    # is a change too, not only a changed recipe.
    unchanged = text == old_text

    added = sorted(set(probe) - set(old_rows))
    removed = sorted(set(old_rows) - set(probe))
    changed = sorted(k for k in set(probe) & set(old_rows) if probe[k] != old_rows[k])
    log("%d recipes: %d added, %d removed, %d changed" % (len(probe), len(added), len(removed), len(changed)))
    for label, ids in (("added", added), ("removed", removed), ("changed", changed)):
        if ids:
            log("  %s: %s%s" % (label, ", ".join(map(str, ids[:40])), " ..." if len(ids) > 40 else ""))

    if args.check:
        return 0 if unchanged else 1
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    log("wrote %s" % args.out)
    write_reference(args.reference, recipes, meta, source, log)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DataError as e:
        print("ERROR: %s - nothing written" % e, file=sys.stderr)
        sys.exit(2)
