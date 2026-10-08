#!/usr/bin/env bash
# fetch_libaccountsync.sh - Clone LibAccountSync-1.0 at the ref .pkgmeta pins, and prove
# the checkout IS that ref. CI runs it before the tests (they load the library
# from $LIBACCOUNTSYNC); it also works locally from git bash.
#
# The url and the pin are read from .pkgmeta, the one place they are written,
# so CI tests exactly what the packager will embed.
#
# Usage (from the repo root):  bash tests/fetch_libaccountsync.sh <dest>
#
# <dest> must not exist: the script never deletes anything (a default of
# ../LibAccountSync would have wiped the dev checkout, uncommitted work included).
set -euo pipefail

dest="${1:-}"
if [ -z "$dest" ]; then
    echo "usage: bash tests/fetch_libaccountsync.sh <dest>   (a path that does not exist yet)" >&2
    exit 2
fi
if [ -e "$dest" ]; then
    echo "$dest already exists; refusing to touch it (pick a fresh path)" >&2
    exit 1
fi

# The Libs/LibAccountSync-1.0 entry of the externals block.
entry=$(tr -d '\r' < .pkgmeta | awk '
    /^externals:/ { inext = 1; next }
    inext && /^[^ #]/ { inext = 0 }
    inext && /^  Libs\/LibAccountSync-1\.0:/ { inlib = 1; next }
    inlib && /^  [^ ]/ { inlib = 0 }
    inext && inlib')
# Values are read the way the packager reads them: the whole rest of the line.
# Its YAML reader keeps an inline "# comment" as part of the value, so a
# comment there must fail here too, not only in the packaging step.
url=$(printf '%s\n' "$entry" | sed -n 's/^ *url: *\(.*[^ ]\) *$/\1/p')
kind=$(printf '%s\n' "$entry" | sed -n 's/^ *\(commit\|tag\): *\(.*[^ ]\) *$/\1/p')
ref=$(printf '%s\n' "$entry" | sed -n 's/^ *\(commit\|tag\): *\(.*[^ ]\) *$/\2/p')
if [ -z "$url" ] || [ -z "$ref" ]; then
    echo "no url and commit/tag pin for Libs/LibAccountSync-1.0 in .pkgmeta" >&2
    exit 1
fi

echo "LibAccountSync: $kind $ref from $url -> $dest"
# A full clone: a commit pin can't be fetched with --branch (the packager does
# the same for `commit:`).
git clone -q "$url" "$dest"
git -C "$dest" -c advice.detachedHead=false checkout -q "$ref"

# The pinned-commit check: HEAD must be the commit the pin names.
want=$(git -C "$dest" rev-parse --verify "$ref^{commit}")
head=$(git -C "$dest" rev-parse HEAD)
if [ "$head" != "$want" ]; then
    echo "LibAccountSync checkout is at $head, but .pkgmeta pins $kind $ref ($want)" >&2
    exit 1
fi
echo "LibAccountSync checkout at $head (pinned $kind $ref)"
