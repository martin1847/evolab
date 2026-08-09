#!/usr/bin/env bash
# scale-check — leverage anchor gate for acceptance: added test lines must not exceed
# added product lines in the reviewed range; refactor / zero-behavior batches must add
# zero test lines (pass --refactor). The orchestrator runs this at acceptance; a breach
# is escalated to the principal, never accepted silently (goal-template 规模锚).
#
# Usage: scale-check.sh <repo-abs-path> <base-ref> [test-path-prefix] [--refactor]
#        (default prefix: test/; --refactor may appear in place of or after the prefix)
# Exit: 0 = within anchor · 1 = anchor breached (escalate) · 2 = tool error (UNKNOWN, not pass)
set -u
if [ "$#" -lt 2 ]; then
  echo "scale-check: ERROR usage: scale-check.sh <repo> <base-ref> [test-prefix] [--refactor]" >&2
  exit 2
fi
repo=$1; base=$2; shift 2
prefix="test/"; refactor=0
for arg in "$@"; do
  case "$arg" in
    --refactor) refactor=1 ;;
    *) prefix=$arg ;;
  esac
done

# --no-renames: a rename compresses to a `{src => test}/x` display path that defeats prefix
# classification; splitting renames into delete+add yields plain destination paths.
num=$(git -C "$repo" diff --numstat --no-renames "$base"...HEAD 2>/dev/null) \
  || { echo "scale-check: ERROR git diff failed" >&2; exit 2; }

prod=0; tst=0
while IFS=$'\t' read -r add _del path; do
  [ -z "${path:-}" ] && continue
  [ "$add" = "-" ] && continue   # binary
  case "$path" in
    "$prefix"*) tst=$((tst + add)) ;;
    *)          prod=$((prod + add)) ;;
  esac
done <<EOF
$num
EOF

mode=$([ "$refactor" -eq 1 ] && echo "refactor: test = 0" || echo "test <= product")
echo "scale-check: product +$prod · test +$tst (anchor: $mode)"
if [ "$refactor" -eq 1 ]; then
  [ "$tst" -eq 0 ] && exit 0
else
  [ "$tst" -le "$prod" ] && exit 0
fi
echo "SCALE-BREACH: added test lines ($tst) violate the anchor ($mode) — a declared deviation" >&2
echo "must exist in the goal, else shrink the guard surface. Do not accept silently." >&2
exit 1
