#!/usr/bin/env bash
# duplexctl classify — bounded control plane (2026-07-28).
#
# Field motive: one `agentctl status` hung forever and pinned an orchestrator's
# polling loop. classify's only unbounded wait was the writer flock (project_omp
# live-queries get_state through write_frame), so a wedged lock holder = a status
# query that never answers. Contract now: EVERY classify returns inside a hard
# deadline, timeout is reported with the existing exit-8 ENGINE-SILENT vocabulary.
#
# Harness: no engines, no real tmux. classify is driven DIRECTLY on hand-built
# session state (the lane's file layout is the whole input surface), and the lock
# holder is a real background python holding LOCK_EX on the real wlock file.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DUPLEXCTL="$AW_DIR/duplexctl.py"

seed_session() { # $1 name  $2 engine  $3 cwd
  printf 'engine=%s\ncwd=%s\n' "$2" "$3" > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  mkfifo "$WATCH_RUN_DIR/$1.duplex.in" 2>/dev/null || true
}

echo "== classify hangs on a wedged writer lock → bounded exit 8 =="
sandbox_new
export FAKE_TMUX_HASSESSION=0     # pane alive: classify must reach the projector
WT="$SANDBOX/wt"; mkdir -p "$WT"
seed_session hgA omp "$WT"

# real contention: a background holder takes LOCK_EX on the same wlock and sits on it
python3 - "$WATCH_RUN_DIR/hgA.duplex.wlock" "$SANDBOX/held" <<'EOF' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(60)
EOF
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/held" ] && break; /bin/sleep 0.2; done
chk_eq "lock holder armed" 1 "$([ -e "$SANDBOX/held" ] && echo 1 || echo 0)"

start=$(date +%s)
out="$(AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify hgA 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
chk_eq "wedged lock → classify returns, exit 8" 8 "$rc"
chk_eq "returns inside the deadline (<=5s), never hangs" 1 "$([ "$elapsed" -le 5 ] && echo 1 || echo 0)"
chk_contains "verdict names the timeout" "classify timeout" "$out"
chk_contains "verdict reuses the ENGINE-SILENT vocabulary" "ENGINE-SILENT" "$out"
chk_contains "verdict points at the stderr log" "stderr.log" "$out"
chk_contains "verdict names the recovery path" "agentctl stop" "$out"

# the lock is STILL held: a second query must be just as bounded (no latched state)
start=$(date +%s)
AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify hgA >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
chk_eq "repeat query stays bounded (exit 8)" 8 "$rc"
chk_eq "repeat query also inside the deadline" 1 "$([ "$elapsed" -le 5 ] && echo 1 || echo 0)"

kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== normal verdicts unchanged (watchdog is invisible when nothing hangs) =="
# claude projector: DONE comes from a complete result frame, no engine process needed
seed_session okC claude "$WT"
printf '%s\n' '{"type":"result","subtype":"success","result":"turn 1 complete"}' \
  > "$WATCH_RUN_DIR/okC.duplex.events.jsonl"
base="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC 2>&1)"; rc=$?
chk_eq "idle claude session → DONE 0 (default deadline)" 0 "$rc"
chk_contains "DONE line intact" "DONE: engine idle" "$base"
chk_contains "DONE carries the last summary" "turn 1 complete" "$base"
chk_not_contains "no timeout chrome on the happy path" "classify timeout" "$base"
# same session under a TIGHT deadline: rc and first line must be byte-identical —
# the alarm must be disarmed by the verdict, never fire on a finished classify
tight="$(AGENT_WATCH_STATUS_TIMEOUT=1 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC 2>&1)"; trc=$?
chk_eq "tight deadline leaves rc unchanged" "$rc" "$trc"
chk_eq "tight deadline leaves the first line unchanged" \
  "$(printf '%s\n' "$base" | head -1)" "$(printf '%s\n' "$tight" | head -1)"
/bin/sleep 1.5   # a leaked alarm would land here, in the NEXT command's process — prove it cannot
chk_eq "watchdog leaks no signal past the verdict" "$rc" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC >/dev/null 2>&1; echo $?)"

# non-terminal verdicts keep their exit codes too (8 must not swallow RUNNING)
seed_session runC claude "$WT"
out="$(AGENT_WATCH_STATUS_TIMEOUT=5 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify runC 2>&1)"; rc=$?
chk_eq "silent-but-alive session still RUNNING 10, not 8" 10 "$rc"
chk_contains "RUNNING detail intact" "no output since last steer" "$out"

echo "== timeout knob: positive int honored, anything else falls back to 30 =="
# PYTHONDONTWRITEBYTECODE: importing the module under test must not litter a
# __pycache__ into the shipped skill tree.
probe() { AGENT_WATCH_STATUS_TIMEOUT="$1" PYTHONDONTWRITEBYTECODE=1 python3 -c \
  "import sys; sys.path.insert(0, '$AW_DIR'); import importlib.util as u; \
s=u.spec_from_file_location('dctl', '$DUPLEXCTL'); m=u.module_from_spec(s); s.loader.exec_module(m); \
print(m.status_timeout())"; }
chk_eq "default when unset" 30 "$(unset AGENT_WATCH_STATUS_TIMEOUT; probe "")"
chk_eq "positive int honored" 7 "$(probe 7)"
chk_eq "whitespace tolerated" 12 "$(probe '  12  ')"
chk_eq "empty → default" 30 "$(probe '')"
chk_eq "zero → default (never unbounded)" 30 "$(probe 0)"
chk_eq "negative → default" 30 "$(probe -5)"
chk_eq "non-numeric → default" 30 "$(probe abc)"
chk_eq "float string → default" 30 "$(probe 2.5)"

# an illegal value must still produce a WORKING bounded classify, not a crash
out="$(AGENT_WATCH_STATUS_TIMEOUT=bogus python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC 2>&1)"; rc=$?
chk_eq "illegal knob still classifies normally" 0 "$rc"
chk_contains "illegal knob prints the real verdict" "DONE: engine idle" "$out"

unset FAKE_TMUX_HASSESSION
sandbox_clean

summary
