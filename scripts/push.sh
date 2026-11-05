#!/bin/zsh
# Pushes main, then releases it as the next patch version if anything user-facing (feat/fix/perf) changed
# since the last release. Docs and chores alone are pushed without a release.
# Usage: scripts/push.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(git branch --show-current)" == main ]] || { echo "Push from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }

git push origin main

PREVIOUS=$(git describe --tags --abbrev=0 --match 'v*')
# grep without -q reads everything: stopping at the first match kills git log, which pipefail counts as a failure.
if ! git log --format=%s "$PREVIOUS..HEAD" | grep -E '^(feat|fix|perf)(\(.*\))?: ' >/dev/null; then
  echo "Nothing user-facing since $PREVIOUS; not releasing."
  exit 0
fi

PARTS=(${(s:.:)${PREVIOUS#v}})
scripts/release.sh "$PARTS[1].$PARTS[2].$((PARTS[3] + 1))"
