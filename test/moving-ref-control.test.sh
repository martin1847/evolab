#!/usr/bin/env bash
# moving-ref-control lint — a test control read from a moving ref (`git show origin/main:<path>`)
# is only "pre-batch" until that batch is pushed; from then on the control is permanently red.
# Bitten twice on 2026-09-18: (20-sa7) was hot-fixed to a pinned SHA the same day, while the
# R13 ③ byte-identity control kept reading origin/main and CI stayed red for five pushes until
# 2026-09-23 (LESSON test-control-anchored-to-moving-ref n=2). Pin a SHA instead
# (`git show <sha>:<path>`); CI checks out with fetch-depth 0, so pinned objects are present.
# Comment lines are exempt (a comment may cite the pattern). Kill criterion (owner 2026-09-23):
# one legitimate use falsely blocked → delete this file.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
self="$(basename "$0")"
pat='^[^#]*show origin/main:'

# Instrument self-check: the pattern must hit a real use and skip a comment, or this lint is blind.
tmp="$(mktemp)"
printf 'x=$(git show origin/main:a/b)\n#   git show origin/main:c/d   (cited in a comment)\n' > "$tmp"
if [ "$(grep -c "$pat" "$tmp")" != 1 ]; then
  rm -f "$tmp"; echo "ERROR moving-ref-control: self-check failed (instrument broken)"; exit 2
fi
rm -f "$tmp"

hits=""
for f in "$HERE"/*.test.sh; do
  [ "$(basename "$f")" = "$self" ] && continue
  h="$(grep -n "$pat" "$f" || true)"
  [ -n "$h" ] && hits="${hits}$(basename "$f"):${h}"$'\n'
done
if [ -n "$hits" ]; then
  printf '%s' "$hits"
  echo "FAIL moving-ref-control: a test control reads origin/main — pin a SHA (git show <sha>:<path>)"
  exit 1
fi
echo "ok   moving-ref-control: no test control reads origin/main"
exit 0
