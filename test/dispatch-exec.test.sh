#!/usr/bin/env bash
# dispatch-exec (headless exec lane) — command construction + stateless classify contract.
# Live two-round smoke (claude/omp legs, real engines) ran 2026-07-11; this suite keeps the
# hermetic surface: launch/meta/stamp, engine command shape, every typed status branch.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DEXEC="$AW_DIR/dispatch-exec"

echo "== dispatch-exec: launch =="

# launch writes meta + round stamp, no rc, and a supervisor command with rc redirect.
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'do the thing\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd"
out="$(bash "$DEXEC" claude exS "$SANDBOX/wt" --goal "$SANDBOX/goal.md" --deliverable "$SANDBOX/wt/*.md" --model haiku 2>&1)"; rc=$?
chk_eq "launch rc0" 0 "$rc"
chk_contains "launch announces round 1" "round 1 started" "$out"
chk_eq "meta engine" claude "$(sed -n 's/^engine=//p' "$WATCH_RUN_DIR/exS.exec.meta")"
chk_eq "meta round" 1 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/exS.exec.meta")"
chk_eq "round stamp exists" 1 "$([ -f "$WATCH_RUN_DIR/exS.exec.round-started" ] && echo 1 || echo 0)"
chk_eq "no rc yet" 0 "$([ -f "$WATCH_RUN_DIR/exS.exec.rc" ] && echo 1 || echo 0)"
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
chk_contains "engine cmd is headless claude -p" "claude -p" "$cmd"
chk_contains "engine cmd json output" "--output-format json" "$cmd"
chk_contains "engine cmd reads goal file" "cat $SANDBOX/goal.md" "$cmd"
chk_contains "engine cmd passes extra args" "--model haiku" "$cmd"
chk_contains "supervisor writes rc on exit" "exec.rc" "$cmd"
# duplicate session refused
out="$(bash "$DEXEC" claude exS "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "duplicate session rc1" 1 "$rc"
sandbox_clean

# --goal required
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DEXEC" omp exG "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "missing goal rc1" 1 "$rc"
sandbox_clean

echo "== dispatch-exec: status classify =="

mkstate() { # $1 session  $2 cwd — minimal meta + stamp
  printf 'engine=claude\ncwd=%s\nround=1\nargs=\n' "$2" > "$WATCH_RUN_DIR/$1.exec.meta"
  : > "$WATCH_RUN_DIR/$1.exec.round-started"
}

# RUNNING: no rc + tmux session alive -> exit 10
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r1 "$SANDBOX/wt"
export FAKE_TMUX_HASSESSION=0
out="$(bash "$DEXEC" status r1 2>&1)"; rc=$?
chk_eq "running exit10" 10 "$rc"; chk_contains "running marker" "RUNNING" "$out"
unset FAKE_TMUX_HASSESSION; sandbox_clean

# killed mid-flight: no rc + no session -> exit 2
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r2 "$SANDBOX/wt"
out="$(bash "$DEXEC" status r2 2>&1)"; rc=$?
chk_eq "dead exit2" 2 "$rc"; chk_contains "dead marker" "AGENT-DEAD" "$out"
sandbox_clean

# DONE rc=0, sid harvested from out
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r3 "$SANDBOX/wt"
printf '{"result":"ok","session_id":"sid-abc-123"}\n' > "$WATCH_RUN_DIR/r3.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/r3.exec.rc"
out="$(bash "$DEXEC" status r3 2>&1)"; rc=$?
chk_eq "done exit0" 0 "$rc"; chk_contains "done marker" "DONE" "$out"
chk_eq "sid harvested" sid-abc-123 "$(sed -n 's/^sid=//p' "$WATCH_RUN_DIR/r3.exec.meta")"
sandbox_clean

# BLOCKED.md newer than stamp -> exit 4 (headless WAITING-INPUT)
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r4 "$SANDBOX/wt"
touch -t 202601010000 "$WATCH_RUN_DIR/r4.exec.round-started"
printf 'need a decision\n' > "$SANDBOX/wt/BLOCKED.md"
printf '0\n' > "$WATCH_RUN_DIR/r4.exec.rc"; : > "$WATCH_RUN_DIR/r4.exec.out"
out="$(bash "$DEXEC" status r4 2>&1)"; rc=$?
chk_eq "blocked exit4" 4 "$rc"; chk_contains "blocked marker" "BLOCKED.md" "$out"
sandbox_clean

# engine failed rc!=0 -> exit 2 ; quota chrome -> exit 5
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r5 "$SANDBOX/wt"
printf 'boom\n' > "$WATCH_RUN_DIR/r5.exec.out"; printf '1\n' > "$WATCH_RUN_DIR/r5.exec.rc"
out="$(bash "$DEXEC" status r5 2>&1)"; rc=$?
chk_eq "failed exit2" 2 "$rc"
printf 'error: insufficient_quota\n' > "$WATCH_RUN_DIR/r5.exec.out"
out="$(bash "$DEXEC" status r5 2>&1)"; rc=$?
chk_eq "quota exit5" 5 "$rc"; chk_contains "quota marker" "STALLED-EXTERNAL" "$out"
sandbox_clean

# codex lying rc: turn.failed event with rc=0 -> exit 2, not DONE
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r6 "$SANDBOX/wt"
printf '{"type":"turn.failed","error":{"message":"x"}}\n' > "$WATCH_RUN_DIR/r6.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/r6.exec.rc"
out="$(bash "$DEXEC" status r6 2>&1)"; rc=$?
chk_eq "turn.failed beats rc0" 2 "$rc"
sandbox_clean

# deliverable gate: stale -> 6 ; fresh -> 0
# (backdate the stamp: same-second mtimes make -nt false under bash 3.2 second precision)
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r7 "$SANDBOX/wt"
touch -t 202601010000 "$WATCH_RUN_DIR/r7.exec.round-started"
printf 'deliverable=%s\n' "$SANDBOX/wt/*.out.md" >> "$WATCH_RUN_DIR/r7.exec.meta"
printf '0\n' > "$WATCH_RUN_DIR/r7.exec.rc"; : > "$WATCH_RUN_DIR/r7.exec.out"
touch -t 202501010000 "$SANDBOX/wt/old.out.md"
out="$(bash "$DEXEC" status r7 2>&1)"; rc=$?
chk_eq "stale deliverable exit6" 6 "$rc"; chk_contains "nodeliv marker" "IDLE-NO-DELIVERABLE" "$out"
touch "$SANDBOX/wt/new.out.md"
out="$(bash "$DEXEC" status r7 2>&1)"; rc=$?
chk_eq "fresh deliverable exit0" 0 "$rc"
sandbox_clean

echo "== dispatch-exec: send (resume round) =="

# send without harvested sid refused; with sid builds a resume command.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate s1 "$SANDBOX/wt"
: > "$WATCH_RUN_DIR/s1.exec.out"
out="$(bash "$DEXEC" send s1 -m 'fix it' 2>&1)"; rc=$?
chk_eq "send w/o sid rc1" 1 "$rc"; chk_contains "send w/o sid msg" "no engine session id" "$out"
printf 'sid=sid-abc-123\n' >> "$WATCH_RUN_DIR/s1.exec.meta"
printf '0\n' > "$WATCH_RUN_DIR/s1.exec.rc"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd-resume"
out="$(bash "$DEXEC" send s1 -m 'fix it' 2>&1)"; rc=$?
chk_eq "send rc0" 0 "$rc"
chk_contains "send announces round 2" "round 2 started" "$out"
chk_contains "resume cmd carries sid" "--resume sid-abc-123" "$(cat "$FAKE_TMUX_CMD_FILE")"
chk_eq "send truncates rc for new round" 0 "$([ -f "$WATCH_RUN_DIR/s1.exec.rc" ] && echo 1 || echo 0)"
sandbox_clean

summary
