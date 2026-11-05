#!/usr/bin/env bash
# Checks a board's handbook rules against this checkout (#1775):
#
#   - every rule item parses (the server's `rules.problems` is empty);
#   - every check that names a test (not `judgement`) names files that
#     exist at REF (default HEAD);
#   - with --paths, prints the rules those paths fall under.
#
# Usage: tools/handbook-rules.sh [board] [--ref REF] [--paths a,b]
# Needs the `slipdock` CLI signed in, `jq`, and to run inside the repo.
# Exits 1 when a rule doesn't parse or names a missing test.
set -euo pipefail

board=slipdock
ref=HEAD
paths=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --paths) paths="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) board="$1"; shift ;;
  esac
done

failed=0

summary=$(slipdock handbook "$board" --json)
count=$(jq -r '.handbook.rules.count // "none"' <<<"$summary")

if [ "$count" = "none" ]; then
  echo "$board: no handbook, or a server without rules" >&2
  exit 1
fi

echo "$board: $count rules ($(jq -r '.handbook.rules.must' <<<"$summary") must)"

problems=$(jq -r '.handbook.rules.problems[] | "  \(.page) line \(.line): \(.problem)\n      \(.item)"' <<<"$summary")
if [ -n "$problems" ]; then
  echo "Items that don't parse:"
  echo "$problems"
  failed=1
fi

# Every rule: `**` overlaps every scope.
all=$(slipdock handbook "$board" --paths '**' --json)

missing=$(
  jq -r '.handbook.rules[] | select(.check != "judgement") | "\(.id)\t\(.check)"' <<<"$all" |
    while IFS=$'\t' read -r id check; do
      IFS=',' read -ra files <<<"$check"
      for f in "${files[@]}"; do
        f="${f# }"
        f="${f%%:*}"
        git cat-file -e "$ref:$f" 2>/dev/null || echo "  $id: $f is not at $ref"
      done
    done
)

if [ -n "$missing" ]; then
  echo "Checks naming a test that isn't there:"
  echo "$missing"
  failed=1
fi

judged=$(jq '[.handbook.rules[] | select(.check == "judgement")] | length' <<<"$all")
echo "checks: $((count - judged)) tests, $judged judgement"

if [ -n "$paths" ]; then
  echo
  slipdock handbook "$board" --paths "$paths"
fi

exit $failed
