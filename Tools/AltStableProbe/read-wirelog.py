"""Print the probe's wire log from every account's SavedVariables.

The probe (/asprobe whisper, /asprobe channel ...) appends to
AltStableProbeDB.wireLog, which the client writes to
WTF\\Account\\<account>\\SavedVariables\\AltStableProbe.lua on /reload and on
logout - not before. Reading the file beats copying out of the game, which came
back empty until a /reload.

    python Tools/AltStableProbe/read-wirelog.py                # everything
    python Tools/AltStableProbe/read-wirelog.py --since 23:10  # from a time on
    python Tools/AltStableProbe/read-wirelog.py --wtf "D:\\...\\WTF"

Lines are printed per account, colour codes stripped, oldest first.
"""
import argparse
import glob
import os
import re
import sys

DEFAULT_WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF"


def wire_lines(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    start = text.find('["wireLog"] = {')
    if start < 0:
        return []
    # The table ends at its own closing brace: the first line after its opening
    # that is not one of its string entries. Searching for the file's "\n}"
    # could take in whatever table followed it (review of #141).
    out = []
    for raw in text[start:].splitlines()[1:]:
        m = re.match(r'^\s*"(.*)",\s*(?:--.*)?$', raw)
        if not m:
            break
        line = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
        out.append(re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wtf", default=DEFAULT_WTF)
    ap.add_argument("--since", help="only lines at or after this: 'HH:MM[:SS]' (today) or "
                                    "'YYYY-MM-DD HH:MM[:SS]'")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.wtf, "Account", "*", "SavedVariables", "AltStableProbe.lua")))
    if not files:
        print("no AltStableProbe.lua under " + args.wtf, file=sys.stderr)
        return 1
    for path in files:
        account = os.path.basename(os.path.dirname(os.path.dirname(path)))
        lines = wire_lines(path)
        if args.since:
            # Entries start "YYYY-MM-DD HH:MM:SS" (dated) or "HH:MM:SS" (older,
            # undated). A dated entry is compared with the full date and time -
            # a log spanning days must not mix rounds (review of #141); an
            # undated one only has its time to offer.
            import datetime
            since = args.since.strip()
            if re.match(r"^\d\d:\d\d", since):
                since_full = datetime.date.today().isoformat() + " " + since
                since_time = since
            else:
                since_full = since
                since_time = since[11:]
            def keep(l):
                m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", l)
                if m:
                    return m.group(1) >= since_full
                m = re.match(r"(\d\d:\d\d:\d\d)", l)
                return bool(m) and m.group(1) >= since_time
            lines = [l for l in lines if keep(l)]
        print("#### %s  (%d lines, file written %s)" % (
            account, len(lines), __import__("time").strftime("%Y-%m-%d %H:%M:%S",
                __import__("time").localtime(os.path.getmtime(path)))))
        for l in lines:
            print(l)
    return 0


if __name__ == "__main__":
    sys.exit(main())
