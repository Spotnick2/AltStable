#!/usr/bin/env bash
# tests/fetch_kit.sh - Fetch WowTestKit at the commit tests/kit.pin names, and
# prove the checkout IS that commit. CI runs it before the tests:
#
#   bash tests/fetch_kit.sh "$RUNNER_TEMP/WowTestKit"
#   echo "WOWTESTKIT=$RUNNER_TEMP/WowTestKit" >> "$GITHUB_ENV"
#
# Copied from WowTestKit's bootstrap/fetch_kit.sh: never edit a consumer's
# copy; change the kit's and copy it again. <dest> must not exist.
set -euo pipefail

dest="${1:-}"
if [ -z "$dest" ]; then echo "usage: bash tests/fetch_kit.sh <dest>   (a path that does not exist yet)" >&2; exit 2; fi
if [ -e "$dest" ]; then echo "$dest already exists: this script never deletes anything" >&2; exit 2; fi

sha=$(sed -n 's/^[[:space:]]*sha[[:space:]]*=[[:space:]]*\([0-9a-f]\{40\}\).*/\1/p' tests/kit.pin)
if [ -z "$sha" ]; then echo "tests/kit.pin has no 40-hex sha=" >&2; exit 1; fi

git init --quiet "$dest"
git -C "$dest" fetch --quiet --depth 1 https://github.com/Spotnick2/WowTestKit.git "$sha"
git -C "$dest" checkout --quiet FETCH_HEAD
head=$(git -C "$dest" rev-parse HEAD)
if [ "$head" != "$sha" ]; then echo "fetched $head, not the pin $sha" >&2; exit 1; fi
echo "WowTestKit $sha at $dest"
