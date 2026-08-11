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
  # classify refuses a session whose active-identity record is MISSING exactly as it refuses
  # a corrupt one (WS1 fencing), so a hand-built session must arm one too — the incarnation
  # stays unestablished here (no pane), which is fine: nothing in this suite adopts evidence.
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
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

# an illegal value must still produce a WORKING bounded classify, not a crash
out="$(AGENT_WATCH_STATUS_TIMEOUT=bogus python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC 2>&1)"; rc=$?
chk_eq "illegal knob still classifies normally" 0 "$rc"
chk_contains "illegal knob prints the real verdict" "DONE: engine idle" "$out"

echo "== send is bounded by the SAME whole-verb alarm (S2-1: blocking LOCK_EX) =="
# the writer flock is a plain kernel-fair LOCK_EX again; the bound moved one level
# up, so a verb that reaches write_frame without a classify watchdog arms its own.
seed_session sndA omp "$WT"
python3 - "$WATCH_RUN_DIR/sndA.duplex.wlock" "$SANDBOX/held2" <<'EOF' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(60)
EOF
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/held2" ] && break; /bin/sleep 0.2; done
start=$(date +%s)
out="$(AGENT_WATCH_SEND_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       send sndA --verb steer --text hi 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
chk_eq "wedged lock → send returns, exit 8" 8 "$rc"
chk_eq "send returns inside its own deadline (<=5s)" 1 "$([ "$elapsed" -le 5 ] && echo 1 || echo 0)"
chk_contains "send verdict names the timeout" "send timeout" "$out"
chk_contains "send verdict names candidate 1: the writer lock" "writer lock" "$out"
chk_contains "send verdict names candidate 2: the fifo" "fifo" "$out"
chk_contains "send verdict routes through status first" "agentctl status" "$out"
chk_not_contains "no destructive 'another sender is wedged' claim" "wedged holding it" "$out"
chk_eq "a timed-out send strands no write-intent" 0 \
  "$([ -e "$WATCH_RUN_DIR/sndA.duplex.write-intent" ] && echo 1 || echo 0)"
kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== a fired watchdog never strands a 0-byte write-intent (S2-2) =="
seed_session e9 omp "$WT"
python3 - "$WATCH_RUN_DIR/e9.duplex.in" "$SANDBOX/rdr" <<'EOF' &
import os, sys, time
os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)   # holds the read end, never drains
open(sys.argv[2], "w").close()
time.sleep(60)
EOF
RDR=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/rdr" ] && break; /bin/sleep 0.2; done
python3 - "$WATCH_RUN_DIR/e9.duplex.in" "$SANDBOX/fill" <<'EOF' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY)
open(sys.argv[2], "w").close()
try:
    os.write(fd, b"x" * (1 << 20))   # fill the pipe buffer: the next writer blocks
except Exception:
    pass
time.sleep(60)
EOF
FILL=$!
/bin/sleep 1.5
out="$(AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify e9 2>&1)"; rc=$?
chk_eq "alarm during a blocked fifo write → exit 8" 8 "$rc"
chk_eq "zero bytes out → write-intent marker NOT stranded" 0 \
  "$([ -e "$WATCH_RUN_DIR/e9.duplex.write-intent" ] && echo 1 || echo 0)"
out2="$(AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify e9 2>&1)"; rc2=$?
chk_eq "next classify is not torn-poisoned (still 8, not 2)" 8 "$rc2"
chk_not_contains "no phantom torn-frame verdict" "torn frame" "$out2"
kill -9 "$FILL" "$RDR" 2>/dev/null; wait "$FILL" "$RDR" 2>/dev/null

echo "== timeout knob: upper clamp, never OverflowError, never disabled (S2-3) =="
out="$(AGENT_WATCH_STATUS_TIMEOUT=99999999999 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify okC 2>&1)"; rc=$?
chk_eq "huge knob still classifies normally" 0 "$rc"
chk_contains "huge knob prints the real verdict" "DONE: engine idle" "$out"
chk_not_contains "huge knob raises no traceback" "Traceback" "$out"

echo "== watchdog armed BEFORE Session() reads meta (minor-4) =="
# a fifo standing in for a wedged run-dir: Session.__init__ blocks reading meta
mkfifo "$WATCH_RUN_DIR/pre.duplex.meta"
: > "$WATCH_RUN_DIR/pre.duplex.round-started"; : > "$WATCH_RUN_DIR/pre.duplex.events.jsonl"
mkfifo "$WATCH_RUN_DIR/pre.duplex.in"
start=$(date +%s)
out="$(AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify pre 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
chk_eq "blocking meta read → still exit 8, not a hang" 8 "$rc"
chk_eq "…and inside deadline+2s" 1 "$([ "$elapsed" -le 5 ] && echo 1 || echo 0)"
chk_contains "classify verdict text unchanged" "classify timeout" "$out"

echo "== handler survives a hostile stdout (minor-7) =="
seed_session hgB omp "$WT"
python3 - "$WATCH_RUN_DIR/hgB.duplex.wlock" "$SANDBOX/held3" <<'EOF' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(60)
EOF
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/held3" ] && break; /bin/sleep 0.2; done
AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify hgB \
  2>"$SANDBOX/e1.log" >&-; rc=$?
chk_eq "stdout closed → still typed exit 8" 8 "$rc"
chk_not_contains "closed stdout raises no traceback" "Traceback" "$(cat "$SANDBOX/e1.log")"
AGENT_WATCH_STATUS_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify hgB \
  2>"$SANDBOX/e2.log" | true
rc=${PIPESTATUS[0]}
chk_eq "stdout is a dead pipe (EPIPE) → still typed exit 8" 8 "$rc"
chk_contains "EPIPE falls the verdict back to stderr" "ENGINE-SILENT" "$(cat "$SANDBOX/e2.log")"
chk_not_contains "EPIPE raises no traceback" "Traceback" "$(cat "$SANDBOX/e2.log")"
kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== wait-ready is bounded too: the codex handshake hits the flock 4x (N1) =="
seed_session wrA codex "$WT"
python3 - "$WATCH_RUN_DIR/wrA.duplex.wlock" "$SANDBOX/held4" <<'EOF' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(60)
EOF
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/held4" ] && break; /bin/sleep 0.2; done
start=$(date +%s)
out="$(AGENT_WATCH_READY_TIMEOUT=3 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       wait-ready wrA --wait 2 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
chk_eq "wedged lock → wait-ready returns, exit 8 (was an infinite hang)" 8 "$rc"
chk_eq "wait-ready returns inside its bound (<=5s)" 1 "$([ "$elapsed" -le 5 ] && echo 1 || echo 0)"
chk_contains "wait-ready verdict names its own verb" "wait-ready timeout" "$out"
chk_contains "wait-ready verdict names the handshake" "handshake never completed" "$out"
chk_contains "wait-ready verdict names the lock candidate" "writer lock is held" "$out"
kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# and the whole-verb bound must NOT preempt the honest inner diagnostics at its
# default size (the finding-6 mistake): no holder, nobody on the fifo read end →
# the 5s fifo-open bound still gets to speak, rc=1, not a timeout verdict
seed_session wrB codex "$WT"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" wait-ready wrB --wait 2 2>&1)"; rc=$?
chk_eq "default bound leaves the inner fifo diagnostic reachable" 1 "$rc"
chk_contains "…and it is the honest one" "fifo has no reader" "$out"
chk_not_contains "…not a watchdog verdict" "wait-ready timeout" "$out"

unset FAKE_TMUX_HASSESSION
sandbox_clean

echo "== the stop-path ps probe is bounded: no answer is UNKNOWN, never an empty snapshot =="
sandbox_new
# stop re-runs `ps_start_times` AFTER the reap, so a `ps` that never answers used to hang the
# stop itself. Driven directly (a pure function of one ps snapshot): first a ps on PATH that
# never returns, then the real one. The in-python alarm is the TEST's own bound.
PSBIN="$SANDBOX/psbin"; mkdir -p "$PSBIN"
printf '#!/usr/bin/env bash\nexec /bin/sleep 300\n' > "$PSBIN/ps"; chmod +x "$PSBIN/ps"
out="$(python3 - "$AW_DIR" "$PSBIN" <<'EOF'
import os, signal, sys
sys.path.insert(0, sys.argv[1]); import duplexctl
signal.alarm(40)
os.environ["PATH"] = sys.argv[2] + os.pathsep + os.environ["PATH"]
print("UNKNOWN" if duplexctl.ps_start_times(["1"]) is None else "MAP")
os.environ["PATH"] = os.environ["PATH"].split(os.pathsep, 1)[1]
mine = str(os.getpid()); got = duplexctl.ps_start_times([mine])
print("MAPPED" if isinstance(got, dict) and (got.get(mine) or "").strip() else f"BAD:{got!r}")
EOF
)"
chk_eq "a ps that never answers is UNKNOWN — an empty map would read as 'nobody is alive'" \
  "UNKNOWN" "$(printf '%s\n' "$out" | sed -n 1p)"
chk_eq "a ps that answers still maps pid → start time" "MAPPED" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
sandbox_clean

summary
