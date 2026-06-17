#!/usr/bin/env bash
# Best-effort coverage of dispatch + teardown FILE-manipulation logic (the parts that
# don't require a real agent/tmux). Fake tmux makes new-session/has-session no-op.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== dispatch =="

# cwd not found -> exit 1.
sandbox_new
out="$(bash "$DISPATCH" omp s "$SANDBOX/nope" 2>&1)"; rc=$?
chk_eq "dispatch bad-cwd rc1" 1 "$rc"
chk_contains "dispatch bad-cwd msg" "cwd not found" "$out"
sandbox_clean

# unknown agent -> exit 1.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" frobnicate s "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch unknown-agent rc1" 1 "$rc"
chk_contains "dispatch unknown-agent msg" "unknown agent" "$out"
sandbox_clean

# existing tmux session -> exit 1.
sandbox_new
mkdir -p "$SANDBOX/wt"
export FAKE_TMUX_HASSESSION=0   # has-session returns success => exists
out="$(bash "$DISPATCH" omp s "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch existing-session rc1" 1 "$rc"
chk_contains "dispatch existing-session msg" "already exists" "$out"
sandbox_clean

# omp dispatch: truncates a fresh sentinel + prints monitor/events lines + rc0.
sandbox_new
mkdir -p "$SANDBOX/wt"
# pre-seed a stale sentinel; dispatch should truncate it (`: > file`).
printf 'STALE WORKING old\n' > "$WATCH_RUN_DIR/ompS.events"
out="$(bash "$DISPATCH" omp ompS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch omp rc0" 0 "$rc"
sz="$(wc -c < "$WATCH_RUN_DIR/ompS.events" | tr -d ' ')"
chk_eq "dispatch omp truncates sentinel" 0 "$sz"
chk_contains "dispatch omp announces" "dispatched omp" "$out"
chk_contains "dispatch omp monitor line" "monitor:" "$out"
sandbox_clean

# codex dispatch: writes .codex/hooks.json with ABS replaced by the hooks dir.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" codex cdxS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch codex rc0" 0 "$rc"
cfg="$SANDBOX/wt/.codex/hooks.json"
if [ -f "$cfg" ]; then _record "dispatch codex writes hooks.json" 1; else _record "dispatch codex writes hooks.json" 0 "missing"; fi
body="$(cat "$cfg" 2>/dev/null)"
chk_not_contains "dispatch codex ABS substituted" "ABS/emit" "$body"
chk_contains "dispatch codex points at emit-from-stdin" "$AW_DIR/hooks/emit-from-stdin.sh" "$body"
sandbox_clean

# codex dispatch with existing config -> WARN, NOT clobbered.
sandbox_new
mkdir -p "$SANDBOX/wt/.codex"
printf '{"existing":true}\n' > "$SANDBOX/wt/.codex/hooks.json"
out="$(bash "$DISPATCH" codex cdx2 "$SANDBOX/wt" 2>&1)"; rc=$?
chk_contains "dispatch codex existing WARNs" "NOT modifying" "$out"
chk_eq "dispatch codex existing not clobbered" '{"existing":true}' "$(cat "$SANDBOX/wt/.codex/hooks.json")"
sandbox_clean

echo "== teardown =="

# teardown: removes sentinel + .codex/hooks.json (+dir), reports kill.
sandbox_new
mkdir -p "$SANDBOX/wt/.codex"
printf 'WORKING x\n' > "$WATCH_RUN_DIR/tdS.events"
printf '{}\n' > "$SANDBOX/wt/.codex/hooks.json"
out="$(bash "$TEARDOWN" tdS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "teardown rc0" 0 "$rc"
if [ -f "$WATCH_RUN_DIR/tdS.events" ]; then _record "teardown removes sentinel" 0 "still present"; else _record "teardown removes sentinel" 1; fi
if [ -f "$SANDBOX/wt/.codex/hooks.json" ]; then _record "teardown removes codex cfg" 0 "still present"; else _record "teardown removes codex cfg" 1; fi
chk_contains "teardown reports session" "tmux session tdS" "$out"
sandbox_clean

# teardown with no cwd: just removes sentinel, no error.
sandbox_new
printf 'DONE x\n' > "$WATCH_RUN_DIR/tdS2.events"
out="$(bash "$TEARDOWN" tdS2 2>&1)"; rc=$?
chk_eq "teardown no-cwd rc0" 0 "$rc"
if [ -f "$WATCH_RUN_DIR/tdS2.events" ]; then _record "teardown no-cwd removes sentinel" 0; else _record "teardown no-cwd removes sentinel" 1; fi
sandbox_clean

summary
