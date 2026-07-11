#!/usr/bin/env bash
# Exercises every exit path + both fallback branches of `watch`.
# Each case: hermetic sandbox, seed sentinel + fake tmux fixtures, assert exit code
# and (where load-bearing) a stdout marker line.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

run_watch() { # captures stdout+rc of `watch <session>`; uses current fixtures/sandbox
  WATCH_OUT="$(bash "$WATCH" "$1" 2>&1)"; WATCH_RC=$?
}

echo "== watch: exit-code map =="

# exit 0 DONE: last line DONE, agent alive (omp), needs idle>=2.
sandbox_new
seed_events done-sess '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"
pane_fixture "some agent output\n$ \n"
run_watch done-sess
chk_eq "exit0 DONE rc" 0 "$WATCH_RC"
chk_contains "exit0 DONE marker" "DONE at" "$WATCH_OUT"
sandbox_clean

# exit 1 SESSION-GONE: display-message returns non-zero.
sandbox_new
seed_events gone-sess '2026-01-01T00:00:00Z WORKING t0\n'
export FAKE_TMUX_DISPLAY_FAIL=1
pane_fixture "x\n"
run_watch gone-sess
chk_eq "exit1 SESSION-GONE rc" 1 "$WATCH_RC"
chk_contains "exit1 SESSION-GONE marker" "SESSION GONE" "$WATCH_OUT"
sandbox_clean

# exit 2 AGENT-DEAD: pane_current_command matches shell regex.
sandbox_new
seed_events dead-sess '2026-01-01T00:00:00Z WORKING t0\n'
export FAKE_PANE_CMD="zsh"
pane_fixture "user@host % \n"
run_watch dead-sess
chk_eq "exit2 AGENT-DEAD rc" 2 "$WATCH_RC"
chk_contains "exit2 AGENT-DEAD marker" "AGENT DEAD" "$WATCH_OUT"
sandbox_clean

# exit 3 HANG: WORKING, line unchanged, pane benign (NO provider chrome) -> stalls>=18.
sandbox_new
seed_events hang-sess '2026-01-01T00:00:00Z WORKING stuck-tool\n'
export FAKE_PANE_CMD="omp"
pane_fixture "compiling...\nstill compiling...\n"   # benign, no EXT_ERR_RE
run_watch hang-sess
chk_eq "exit3 HANG rc" 3 "$WATCH_RC"
chk_contains "exit3 HANG marker" "SUSPECTED HANG" "$WATCH_OUT"
sandbox_clean

# exit 4 WAITING-INPUT: last line WAITING.
sandbox_new
seed_events wait-sess '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z WAITING permission\n'
export FAKE_PANE_CMD="omp"
pane_fixture "Allow this? (y/n)\n"
run_watch wait-sess
chk_eq "exit4 WAITING rc" 4 "$WATCH_RC"
chk_contains "exit4 WAITING marker" "WAITING FOR INPUT" "$WATCH_OUT"
sandbox_clean

# exit 5 STALLED-EXTERNAL: WORKING + provider-error chrome -> exterr>=3.
sandbox_new
seed_events stall-sess '2026-01-01T00:00:00Z WORKING retrying\n'
export FAKE_PANE_CMD="omp"
pane_fixture "> retrying (3/10)\n529 overloaded_error: Overloaded\n"
run_watch stall-sess
chk_eq "exit5 STALLED-EXTERNAL rc" 5 "$WATCH_RC"
chk_contains "exit5 STALLED-EXTERNAL marker" "STALLED-EXTERNAL" "$WATCH_OUT"
sandbox_clean

echo "== watch: silent hook (NO scrape fallback — honest exit 8) =="

# exit 8 NO-HOOK (absent): events file never exists, pane idle -> report, don't guess.
sandbox_new
# do NOT seed events; ensure it stays absent
export FAKE_PANE_CMD="omp"
pane_fixture "all done.\n$ \n"
run_watch absent-sess
chk_eq "no-hook absent rc8" 8 "$WATCH_RC"
chk_contains "no-hook absent marker" "NO-HOOK" "$WATCH_OUT"
chk_not_contains "no-hook never scrapes" "scrape" "$WATCH_OUT"
chk_eq "no-hook natural exit removes watchspec" 0 "$(find "$WATCH_RUN_DIR" -name '*.watchspec' | wc -l | tr -d ' ')"
sandbox_clean

# exit 8 NO-HOOK (empty): events file exists but EMPTY, pane idle -> ~6 polls -> exit 8.
sandbox_new
: > "$WATCH_RUN_DIR/empty-sess.events"   # exists, empty
export FAKE_PANE_CMD="omp"
pane_fixture "idle screen\n$ \n"
run_watch empty-sess
chk_eq "no-hook empty rc8" 8 "$WATCH_RC"
chk_contains "no-hook empty marker" "NO-HOOK" "$WATCH_OUT"
sandbox_clean

# BUSY pane keeps a silent sentinel alive (codex emits its first event on the first tool
# call): must NOT fire exit 8 while working; bounded polling ends in exit 7 instead.
sandbox_new
: > "$WATCH_RUN_DIR/busy-sess.events"
export FAKE_PANE_CMD="codex" AGENT_WATCH_MAX_POLLS=8
pane_fixture "▌ Working (12s · esc to interrupt)\n"
run_watch busy-sess
chk_eq "busy pane defers NO-HOOK to timeout rc7" 7 "$WATCH_RC"
chk_not_contains "busy pane no premature NO-HOOK" "NO-HOOK" "$WATCH_OUT"
unset AGENT_WATCH_MAX_POLLS
sandbox_clean


# exit 6 IDLE-NO-DELIVERABLE: stable DONE but declared deliverable glob never matches.
sandbox_new
seed_events nodeliv-sess '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "phase done\n"
export AGENT_WATCH_DELIVERABLE="$SANDBOX/out/*.md" AGENT_WATCH_NODELIV_POLLS=1
run_watch nodeliv-sess
chk_eq "exit6 NO-DELIVERABLE rc" 6 "$WATCH_RC"
chk_contains "exit6 marker" "IDLE-NO-DELIVERABLE" "$WATCH_OUT"
chk_contains "exit6 poke hint" "poke" "$WATCH_OUT"
unset AGENT_WATCH_DELIVERABLE AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# deliverable gate OPEN: glob matches AND is newer than the arm stamp -> plain DONE exit 0.
# Pre-create the stamp with an OLD mtime (create-if-absent keeps it, emulating a rearm'd
# watcher preserving the original arm time), then produce the deliverable "this round".
sandbox_new
seed_events deliv-ok '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "done\n"
touch -t 202601010000 "$WATCH_RUN_DIR/deliv-ok.watch-armed"
mkdir -p "$SANDBOX/out"; touch "$SANDBOX/out/report.md"
export AGENT_WATCH_DELIVERABLE="$SANDBOX/out/*.md" AGENT_WATCH_NODELIV_POLLS=1
run_watch deliv-ok
chk_eq "gate-open DONE rc" 0 "$WATCH_RC"
chk_contains "gate-open DONE marker" "DONE at" "$WATCH_OUT"
chk_eq "natural exit removes arm stamp" 0 "$([ -e "$WATCH_RUN_DIR/deliv-ok.watch-armed" ] && echo 1 || echo 0)"
unset AGENT_WATCH_DELIVERABLE AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# deliverable gate FRESHNESS (multi-round early-exit regression, LH 2026-07-11): a file
# left over from a PREVIOUS round matches the glob but predates this round's arm stamp
# -> gate must stay CLOSED (exit 6 poke), not report a phantom DONE while round 2 runs.
sandbox_new
seed_events deliv-stale '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "round-2 in flight\n"
mkdir -p "$SANDBOX/out"; touch -t 202601010000 "$SANDBOX/out/round1-impl.md"
export AGENT_WATCH_DELIVERABLE="$SANDBOX/out/*.md" AGENT_WATCH_NODELIV_POLLS=1
run_watch deliv-stale
chk_eq "stale deliverable does NOT open the gate rc6" 6 "$WATCH_RC"
chk_contains "stale deliverable marker" "IDLE-NO-DELIVERABLE" "$WATCH_OUT"
unset AGENT_WATCH_DELIVERABLE AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# persisted gate (codex review): env absent but dispatch wrote <s>.deliverable — a bare
# re-arm (gap-detect prints no env) must NOT degrade to ungated; stale file -> exit 6.
sandbox_new
seed_events deliv-persist '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "boundary done\n"
mkdir -p "$SANDBOX/out"; touch -t 202601010000 "$SANDBOX/out/old.md"
printf '%s\n' "$SANDBOX/out/*.md" > "$WATCH_RUN_DIR/deliv-persist.deliverable"
export AGENT_WATCH_NODELIV_POLLS=1
run_watch deliv-persist
chk_eq "persisted gate holds without env rc6" 6 "$WATCH_RC"
unset AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# same-mtime deliverable opens the gate (codex review: -nt strictness rejected an
# equal-timestamp valid deliverable; now >= stamp).
sandbox_new
seed_events deliv-same '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "done\n"
touch -t 202601011200 "$WATCH_RUN_DIR/deliv-same.watch-armed"
mkdir -p "$SANDBOX/out"; touch -t 202601011200 "$SANDBOX/out/report.md"
export AGENT_WATCH_DELIVERABLE="$SANDBOX/out/*.md" AGENT_WATCH_NODELIV_POLLS=1
run_watch deliv-same
chk_eq "same-mtime deliverable rc0" 0 "$WATCH_RC"
unset AGENT_WATCH_DELIVERABLE AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# busy-chrome residue must not defer NO-HOOK forever (codex review: an idle prompt with a
# leftover "Running …" line re-armed the busy tier every poll → ~87min to exit 7). Busy
# with a silent sentinel is bounded ~30 polls -> exit 8.
sandbox_new
: > "$WATCH_RUN_DIR/residue-sess.events"
export FAKE_PANE_CMD="codex"
pane_fixture "Running tests completed successfully\n\$ \n"
run_watch residue-sess
chk_eq "busy-residue bounded rc8" 8 "$WATCH_RC"
chk_contains "busy-residue marker" "pane looks busy but sentinel silent" "$WATCH_OUT"
sandbox_clean

# exit 7 WATCH-TIMEOUT: bounded polling exhausted while the agent remains alive/non-terminal.
sandbox_new
seed_events timeout-sess '2026-01-01T00:00:00Z UNKNOWN still-active\n'
export FAKE_PANE_CMD="omp" AGENT_WATCH_MAX_POLLS=1
pane_fixture "still active\n"
run_watch timeout-sess
chk_eq "exit7 WATCH-TIMEOUT rc" 7 "$WATCH_RC"
chk_contains "exit7 WATCH-TIMEOUT marker" "WATCH TIMEOUT" "$WATCH_OUT"
unset AGENT_WATCH_MAX_POLLS
sandbox_clean

summary
