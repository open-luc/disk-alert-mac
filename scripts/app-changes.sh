#!/bin/bash
# Lists the changes since <base> that people using Disk Alert would notice, one "- subject" line each.
# Prints nothing when the app itself is unchanged, so CI publishes no new version for it.
#
# A commit counts when it touches what goes into the app (below), its message doesn't contain
# "[no app change]", and it isn't listed in scripts/no-app-change.txt. So tests, CI, the README,
# and refactors marked that way don't count.
#
# Usage: scripts/app-changes.sh [<base>]   (no base: every commit up to HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATHS=(Sources Resources scripts/build.sh scripts/make-icon.swift VERSION)
RANGE="${1:+$1..}HEAD"
IGNORED=$(grep -oE '^[0-9a-f]{7,40}' scripts/no-app-change.txt 2>/dev/null || true)

git log --no-merges --format='%H' "$RANGE" -- "${APP_PATHS[@]}" | while read -r commit; do
  [[ "$(git log -1 --format='%B' "$commit")" == *"[no app change]"* ]] && continue
  for prefix in $IGNORED; do [[ "$commit" == "$prefix"* ]] && continue 2; done
  git log -1 --format='- %s' "$commit"
done
