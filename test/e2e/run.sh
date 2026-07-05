#!/usr/bin/env bash
# E2E runner (tier 2) — LIVE tests that spawn real headless `claude` sessions.
#
# Why a separate tier: the hermetic suite (../run.sh) proves script LOGIC with synthetic
# payloads, but harness-contract outputs (hook deny/reminder delivery, skill-driven
# onboarding) can pass synthetic tests and still silently fail in the real harness
# (proven twice: PostToolUse plain-stdout black-hole; frontmatter hooks not registering).
# This tier is the forcing function for "合成测 ≠ 真送达，发布前真 wire 跑一遍".
#
# COST: each test starts real `claude -p` sessions (minutes + API tokens). Run manually
# BEFORE a release/push, not in a loop:  bash test/e2e/run.sh
# Requires: `claude` CLI on PATH + working credentials; skills installed (symlink or copy)
# so the harness can activate them.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not on PATH — E2E tier needs a live harness"; exit 0
fi

total_pass=0; total_fail=0
for t in guard-wire.e2e.sh onboard.e2e.sh dispatch-goal.e2e.sh; do
  echo; echo "==== $t ===="
  if bash "$HERE/$t"; then
    printf '[PASS] %s\n' "$t"; total_pass=$((total_pass+1))
  else
    printf '[FAIL] %s\n' "$t"; total_fail=$((total_fail+1))
  fi
done

echo; echo "######## E2E SUMMARY ########"
printf 'PASS=%d  FAIL=%d\n' "$total_pass" "$total_fail"
[ "$total_fail" -eq 0 ] && { echo "E2E GREEN"; exit 0; } || { echo "E2E FAILED"; exit 1; }
