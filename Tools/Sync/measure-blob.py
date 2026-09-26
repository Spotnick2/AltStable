#!/usr/bin/env python
"""How big is the Warband sync blob on the wire, really?

#44 proposes splitting the bags and bank halves of the blob so that changing one
does not re-send the other, and sizes the waste from a hypothetical 20-alt
database with ~150 items each. This measures the actual one, which is what the
issue asks for: "worth measuring first - with a real multi-alt database, on the
wire - rather than sizing it from estimates."

    python Tools/Sync/measure-blob.py

Reads the SavedVariables directly. No client needed, nothing written.

FOUR THINGS THIS HAS TO GET RIGHT, each of which the first version got wrong:

1. PER ACCOUNT. Every account store is a separate client that sends its own
   blob. Summing them measures a message nobody ever sends, and double-counts
   the characters both accounts know about.

2. ON THE WIRE. Core DEFLATEs the whole payload and escapes it before slicing
   at MAX_CHUNK (Core.lua, ChunkAndSendPayload), so chunk counts taken from raw
   bytes are meaningless - and repetitive per-character framing, which looks
   enormous uncompressed, is exactly what DEFLATE erases. And the limit of even
   that: these fragments are compressed on their own, which is neither the size
   of a message nor a bound on what they add to one. Interleaving changes match
   distances; a fixture that compresses to 71 bytes alone can add 103 when
   separated by other text.

3. PER DELTA. A bag change touches ONE character's stamp, and SerializeFullDB
   filters on lastUpdate, so the delta carries that character - not the roster.
   The waste from re-sending its bank is one character's bank, once.

4. THE REAL FRAMING. The blob travels as "plugin_warband:" plus its own header,
   and leaving the prefix out understates it by ~45%.
"""

import glob
import os
import re
import sys
import zlib

WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"
MAX_CHUNK = 220                      # Core.lua
PLUGIN_PREFIX = "plugin_warband:"    # Core.lua, SerializeFullDB


def characters(text):
    """Every character entry in AltStableWarbandDB, as {guid: body}."""
    # Scoped to the table, so a second GUID-keyed table added later does not
    # silently join the totals.
    anchor = re.search(r'AltStableWarbandDB\s*=\s*\{', text)
    if not anchor:
        return {}
    depth, i = 1, anchor.end()
    while i < len(text) and depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    body = text[anchor.end():i - 1]

    out = {}
    for m in re.finditer(r'\["(Player-[^"]+)"\]\s*=\s*\{', body):
        d, j = 1, m.end()
        while j < len(body) and d:
            if body[j] == "{":
                d += 1
            elif body[j] == "}":
                d -= 1
            j += 1
        out[m.group(1)] = body[m.end():j - 1]
    return out


def wire_map(body, name):
    """(entry count, the "id,count;id,count" string the wire carries)."""
    m = re.search(r'\["%s"\]\s*=\s*\{' % name, body)
    if not m:
        return 0, ""
    depth, j = 1, m.end()
    while j < len(body) and depth:
        if body[j] == "{":
            depth += 1
        elif body[j] == "}":
            depth -= 1
        j += 1
    found = re.findall(r"\[(\d+)\]\s*=\s*(\d+)", body[m.end():j - 1])
    # EncodeMap sorts the ids before joining. SavedVariables order is arbitrary,
    # and the order changes how well the result compresses.
    found.sort(key=lambda pair: int(pair[0]))
    return len(found), ";".join("%s,%s" % pair for pair in found)


def on_wire(payload):
    """Bytes after DEFLATE and the addon-channel escape, and the chunk count.

    LibDeflate's EncodeForWoWAddonChannel is CreateCodec("\\000", "\\001", "") -
    it escapes NUL and 0x01 and nothing else, so it costs one byte per occurrence
    rather than base64's third. zlib stands in for LibDeflate's DEFLATE; the
    sizes are close, not identical.

    This compresses the warband fragments ALONE, which is NOT a bound of any
    kind on what they contribute to the real message. The real payload
    interleaves them with the core character records in one DEFLATE stream, and
    interleaving changes match distances and the available history - a fixture
    that compresses to 71 bytes on its own can add 103 when separated by other
    text. So these are standalone fragment sizes and nothing more: useful for
    comparing one roster against another, useless as the size of a sync or as
    the cost of adding or removing a section.
    """
    raw = payload.encode("utf-8", "replace")
    co = zlib.compressobj(8, zlib.DEFLATED, -15)
    deflated = co.compress(raw) + co.flush()
    escaped = len(deflated) + deflated.count(b"\x00") + deflated.count(b"\x01")
    return len(deflated), escaped, max(1, -(-escaped // MAX_CHUNK))


def stamp_of(body, key):
    m = re.search(r'\["' + key + r'"\]\s*=\s*(\d+)', body)
    return m.group(1) if m else "0"


def blob_for(body):
    bn, bwire = wire_map(body, "bags")
    kn, kwire = wire_map(body, "bank")
    # The REAL stamps. Substituting one constant for every character made every
    # header identical, which is exactly the repetition DEFLATE is best at, so
    # the compressed sizes came out better than the real thing would.
    header = ("v1|s=" + stamp_of(body, "stamp")
              + "|kt=" + stamp_of(body, "bankStamp")
              + "|b=" + bwire + "|k=" + kwire)
    return bn, bwire, kn, kwire, PLUGIN_PREFIX + header


def main():
    stores = sorted(glob.glob(os.path.join(WTF, "*", "SavedVariables", "AltStableWarband.lua")))
    if not stores:
        print("no AltStableWarband.lua under", WTF)
        return 1

    worst_bank = (0, None)
    for path in stores:
        account = path.split(os.sep)[-3]
        text = open(path, encoding="utf-8", errors="replace").read()
        chars = characters(text)

        blobs, n_with, bank_bytes, bag_entries, bank_entries = [], 0, 0, 0, 0
        for guid, body in chars.items():
            bn, bwire, kn, kwire, blob = blob_for(body)
            if bn == 0 and kn == 0:
                continue
            n_with += 1
            bag_entries += bn
            bank_entries += kn
            bank_bytes += len(kwire)
            blobs.append(blob)
            if len(kwire) > worst_bank[0]:
                worst_bank = (len(kwire), (account, guid, kn))

        if not blobs:
            print("%-14s no inventory recorded" % account)
            continue

        payload = "\n".join(blobs)
        deflated, escaped, chunks = on_wire(payload)

        print("account %s" % account)
        print("  characters with inventory : %d" % n_with)
        print("  bag / bank entries        : %d / %d" % (bag_entries, bank_entries))
        print("  blob payload, raw         : %d bytes" % len(payload))
        print("  ... deflated ALONE        : %d bytes" % deflated)
        print("  ... escaped               : %d bytes  (~%d chunk(s) of %d)"
              % (escaped, chunks, MAX_CHUNK))
        print("     ^ these fragments compressed BY THEMSELVES - not a bound on")
        print("       what they add to the real message, which interleaves them")
        print("       with the core character records in one DEFLATE stream.")
        print("  bank bytes, whole account : %d" % bank_bytes)
        print()

    size, who = worst_bank
    print("The waste #44 is about, stated correctly:")
    print("  A bag change bumps ONE character's stamp, so the delta carries that")
    print("  character alone. The bank re-sent with it is that character's bank.")
    if who:
        print("  Worst on this machine: %s (%s), %d entries, %d raw bytes."
              % (who[1][-12:], who[0], who[2], size))
    else:
        print("  No character here has a bank at all.")
    # Distinct ids, because repeating one 120 times compresses far better than
    # a real bank does and would flatter the answer.
    #
    # RAW bytes only. What a section costs the real stream cannot be had by
    # compressing it on its own - that has to be measured as complete payloads
    # with and without it, which needs the core serializer and so a client.
    synthetic = ";".join("%d,%d" % (4000 + i * 37, 1 + (i % 20)) for i in range(120))
    print("  A FULL bank (120 distinct items) is %d raw bytes." % len(synthetic))
    return 0


if __name__ == "__main__":
    sys.exit(main())
