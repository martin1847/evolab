#!/usr/bin/env bash
# Runner for the agent-watch test suite. Runs every *.test.sh (bash) + the bun TS
# test (SKIP if bun absent), prints per-test PASS/FAIL, exits non-zero if any fail.
# Hermetic: each test creates its own temp AGENT_WATCH_DIR + temp PATH bin and cleans up.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

total_pass=0
total_fail=0
total_skip=0

run_one() { # $1 label  $2... command
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    printf '[PASS] %s\n' "$label"
    total_pass=$((total_pass+1))
  else
    printf '[FAIL] %s (rc=%s)\n' "$label" "$rc"
    total_fail=$((total_fail+1))
  fi
}

echo "######## agent-watch test suite ########"

for t in emit.test.sh watch.test.sh scrape-fallback.test.sh ext-err-detection.test.sh dispatch-teardown.test.sh hook.test.sh cto-guard-bash.test.sh cto-guard-agent.test.sh retro-check.test.sh agent-mail-bus.test.sh mirror-sync.test.sh statusline.test.sh; do
  echo
  echo "==== $t ===="
  run_one "$t" bash "$HERE/$t"
done

for bt in omp-watch.bun.ts memory-hook-omp.bun.ts; do
  echo
  echo "==== $bt ===="
  if command -v bun >/dev/null 2>&1; then
    run_one "$bt" bun "$HERE/$bt"
  else
    echo "    bun not on PATH — TypeScript test skipped"
    printf '[SKIP] %s (no bun runtime)\n' "$bt"
    total_skip=$((total_skip+1))
  fi
done

echo
echo "######## SUMMARY ########"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$total_pass" "$total_fail" "$total_skip"
[ "$total_fail" -eq 0 ] && { echo "ALL GREEN"; exit 0; } || { echo "SUITE FAILED"; exit 1; }
