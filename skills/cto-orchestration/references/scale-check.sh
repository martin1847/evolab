#!/usr/bin/env bash
# scale-check — leverage anchor gate for acceptance: added test lines must not exceed
# added product lines in the reviewed range. The orchestrator runs this at acceptance;
# a breach is escalated to the principal, never accepted silently (goal-template 规模锚).
#
# Usage: scale-check.sh <repo-abs-path> <base-ref> [test-path-prefix]   (default prefix: test/)
# Exit: 0 = within anchor · 1 = anchor breached (escalate) · 2 = tool error (UNKNOWN, not pass)
set -u
repo=${1:?usage: scale-check.sh <repo> <base-ref> [test-prefix]}
base=${2:?usage: scale-check.sh <repo> <base-ref> [test-prefix]}
prefix=${3:-test/}

num=$(git -C "$repo" diff --numstat "$base"...HEAD 2>/dev/null) || { echo "scale-check: ERROR git diff failed" >&2; exit 2; }

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

echo "scale-check: product +$prod · test +$tst (anchor: test <= product; refactor goals: test = 0)"
if [ "$tst" -le "$prod" ]; then
  exit 0
fi
echo "SCALE-BREACH: added test lines ($tst) exceed added product lines ($prod) — a declared" >&2
echo "deviation must exist in the goal, else shrink the guard surface. Do not accept silently." >&2
exit 1
