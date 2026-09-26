#!/usr/bin/env python
"""How big is the Warband sync blob, really?

#44 proposes splitting the bags and bank halves of the blob so that changing
one does not re-send the other, and sizes the waste from a hypothetical 20-alt
database with ~150 items each. This measures the actual one instead, which is
what the issue asks for: "worth measuring first - with a real multi-alt
database, on the wire - rather than sizing it from estimates."

Re-run it as the roster grows. The change it would justify is a BLOB_VERSION
bump with cross-version compatibility to get right, so it wants a real number
behind it, not a projection.

    python Tools/Sync/measure-blob.py

Reads the SavedVariables directly - no client needed, nothing written.
"""
import glob, re, os

STORES = glob.glob("C:/Program Files (x86)/World of Warcraft/_classic_beta_/WTF/Account/*/SavedVariables/AltStableWarband.lua")

def blocks(text, key):
    """The { ... } table under ["<key>"] inside a character entry."""
    out = {}
    i = text.find('AltStableWarbandDB')
    if i < 0:
        return out
    # Each character entry: ["Player-..."] = { ... }
    for m in re.finditer(r'\["(Player-[^"]+)"\]\s*=\s*\{', text):
        guid = m.group(1)
        depth, j = 1, m.end()
        while j < len(text) and depth:
            if text[j] == '{': depth += 1
            elif text[j] == '}': depth -= 1
            j += 1
        out[guid] = text[m.end():j-1]
    return out

def count_map(body, name):
    m = re.search(r'\["%s"\]\s*=\s*\{' % name, body)
    if not m:
        return 0, 0
    depth, j = 1, m.end()
    while j < len(body) and depth:
        if body[j] == '{': depth += 1
        elif body[j] == '}': depth -= 1
        j += 1
    inner = body[m.end():j-1]
    pairs = re.findall(r'\[(\d+)\]\s*=\s*(\d+)', inner)
    # wire form is "id,count" joined by ";"
    wire = ";".join("%s,%s" % p for p in pairs)
    return len(pairs), len(wire)

total_chars = 0
tot_bags_n = tot_bank_n = 0
tot_bags_b = tot_bank_b = 0
rows = []

for path in STORES:
    text = open(path, encoding="utf-8", errors="replace").read()
    for guid, body in blocks(text, "AltStableWarbandDB").items():
        bn, bb = count_map(body, "bags")
        kn, kb = count_map(body, "bank")
        if bn == 0 and kn == 0:
            continue
        total_chars += 1
        tot_bags_n += bn; tot_bank_n += kn
        tot_bags_b += bb; tot_bank_b += kb
        rows.append((guid[-12:], bn, bb, kn, kb))

if not total_chars:
    print("no warband data found in", len(STORES), "store(s)")
    raise SystemExit(0)

rows.sort(key=lambda r: -(r[2] + r[4]))
print("%-14s %6s %8s %6s %8s" % ("character", "bags", "bytes", "bank", "bytes"))
for r in rows[:12]:
    print("%-14s %6d %8d %6d %8d" % r)
print()

blob = tot_bags_b + tot_bank_b
overhead = total_chars * len("v1|s=1758800000|kt=1758800000|b=|k=")
print("characters with inventory : %d" % total_chars)
print("bag entries / bytes       : %d / %d" % (tot_bags_n, tot_bags_b))
print("bank entries / bytes      : %d / %d" % (tot_bank_n, tot_bank_b))
print("total blob payload        : %d bytes (+%d framing)" % (blob, overhead))
print()

# The waste: looting one item bumps bagsStamp, and the whole blob is re-sent.
# The bank half of that is pure waste.
print("A single bag change re-sends the bank too.")
print("  wasted per such delta, whole roster : %d bytes" % tot_bank_b)
print("  as a share of the blob              : %.0f%%" % (100.0 * tot_bank_b / blob if blob else 0))
CHUNK = 220
print("  extra 220-byte chunks               : %d" % ((tot_bank_b + CHUNK - 1) // CHUNK))
print()
print("Per character, the average bank half is %d bytes (%d chunks)."
      % (tot_bank_b / total_chars, max(1, round(tot_bank_b / total_chars / CHUNK))))
