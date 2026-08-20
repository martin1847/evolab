#!/usr/bin/env bash
# agentctl duplex lane — frame shapes, typed projection, lane routing, and the
# 2026-07-19 field-report regressions (relative deliverable glob / bounded watch
# tail / dispatch verb whitelist / guard motive wording).
#
# Harness: a PROCESS-RUNNING fake tmux (unlike lib-testkit's captured-command fake):
# new-session actually runs the pane command in the background, has-session reflects
# wrapper liveness, kill-session kills wrapper+engine. That exercises the REAL
# fifo/flock/events pipeline end to end with scriptable fake engines — no real tmux,
# no real engines, no tokens. NOTE: this fake's display-message prints nothing, so
# PANE_PID stays empty and the stop process-tree reap is NOT exercised here — that
# coverage (real setsid trees) lives in agentctl-reap.test.sh.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL="$AW_DIR/agentctl"
GUARD="$AW_DIR/cto-guard-agent.py"
FIX="$(pwd)/duplex-fixtures"

install_running_tmux() { # replaces the sandbox fake tmux with a process-running one
  export FAKE_TMUX_STATE="$SANDBOX/tmux-state"
  mkdir -p "$FAKE_TMUX_STATE"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
name=""; cwd=""; cmd=""
while [ "$#" -gt 0 ]; do case "$1" in
  -s|-t) name="$2"; shift 2;;
  -c) cwd="$2"; shift 2;;
  -d|-p) shift;;
  *) cmd="$1"; shift;;
esac; done
# agentctl targets sessions with tmux exact-match syntax ("=name" / "=name:"); state
# files are keyed by the bare name, so normalize like real tmux resolves it.
name="${name#=}"; name="${name%:}"
case "$sub" in
  new-session)
    ( cd "${cwd:-/}" && exec bash -c "$cmd" ) >/dev/null 2>&1 &
    echo $! > "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  has-session)
    pid="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)" || exit 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null ;;
  kill-session)
    pid="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)"
    if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
    rm -f "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/tmux"
}

sweep_fakes() { # kill any engine/wrapper the fake tmux started (orphans hold the fifo)
  local pidfile pid
  for pidfile in "$FAKE_TMUX_STATE"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
  done
  pkill -f "duplex-fixtures/fake_omp_duplex" 2>/dev/null
  pkill -f "duplex-fixtures/fake_claude_duplex" 2>/dev/null
  pkill -f "duplex-fixtures/fake_codex_duplex" 2>/dev/null
  return 0
}

echo "== duplex: omp lifecycle (frames + projection) =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wt"; mkdir -p "$WT"
# goals carry a resolved Preflight declaration: the gate is ON by default since
# 1.6.0, so every start below exercises the default path (not an exempted one).
printf 'investigate the thing\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
export FAKE_PROVIDER_LOG="$SANDBOX/omp.log"
out="$(bash "$AGENTCTL" start omp dxA "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "omp start rc0" 0 "$rc"
chk_contains "omp start announces duplex" "duplex session 'dxA'" "$out"
chk_contains "omp ready handshake observed" "ready: omp rpc handshake" "$out"
chk_contains "prompt frame carries goal text" "investigate the thing" "$(cat "$SANDBOX/omp.log")"
chk_contains "prompt frame carries BLOCKED footer" "BLOCKED.md" "$(cat "$SANDBOX/omp.log")"
# the footer must reach the ENGINE with the contract-gate half intact — source-level wording is
# checked by cto-docs-contract; this asserts it survives into the delivered frame.
chk_contains "prompt frame carries contract-gate clause" "stop and wait for the orchestrator" "$(cat "$SANDBOX/omp.log")"
chk_contains "prompt frame carries promised-review branch" "Unless the goal contract promises to review" "$(cat "$SANDBOX/omp.log")"
chk_eq "prompt frame is omp type=prompt" 1 "$(grep -c '"type":"prompt"' "$SANDBOX/omp.log")"

# no-deliverable start must NOT carry the file-delivery contract (review R2 M1: the helper
# test alone let the production call-point wiring regress unseen — this pins the REAL frame)
chk_not_contains "no-deliverable prompt frame has no file contract" "chat output is not delivery" "$(cat "$SANDBOX/omp.log")"

out="$(bash "$AGENTCTL" status dxA 2>&1)"; rc=$?
chk_eq "omp idle no-gate → DONE rc0" 0 "$rc"
chk_contains "omp DONE message" "DONE: engine idle" "$out"
chk_not_contains "setWidget chrome does not read as WAITING" "WAITING-INPUT" "$out"

out="$(bash "$AGENTCTL" steer dxA -m "adjust course" 2>&1)"; rc=$?
chk_eq "steer default rc0" 0 "$rc"
chk_contains "steer default → follow_up frame" '"type":"follow_up"' "$(cat "$SANDBOX/omp.log")"
out="$(bash "$AGENTCTL" steer dxA -m "right now" --now 2>&1)"
chk_contains "steer --now → steer frame" '"type":"steer"' "$(cat "$SANDBOX/omp.log")"
out="$(bash "$AGENTCTL" steer dxA -m "start over" --replace 2>&1)"
chk_contains "steer --replace → abort_and_prompt frame" '"type":"abort_and_prompt"' "$(cat "$SANDBOX/omp.log")"

# deliverable gate: RELATIVE glob resolves against the session cwd (2026-07-19 regression)
out="$(bash "$AGENTCTL" steer dxA -m "produce the file" -d "out-*.md" 2>&1)"; rc=$?
chk_eq "steer with -d rc0" 0 "$rc"
out="$(bash "$AGENTCTL" status dxA 2>&1)"; rc=$?
chk_eq "gate armed, file missing → 6" 6 "$rc"
chk_contains "no-deliverable message says steer, not stop" "do not stop" "$out"
printf 'result\n' > "$WT/out-final.md"
out="$(bash "$AGENTCTL" status dxA 2>&1)"; rc=$?
chk_eq "relative glob matches in session cwd → DONE" 0 "$rc"
chk_contains "DONE names the fresh deliverable" "out-final.md" "$out"

# BLOCKED.md protocol → WAITING-INPUT
sleep 0.01; printf 'need a decision\n' > "$WT/BLOCKED.md"
out="$(bash "$AGENTCTL" status dxA 2>&1)"; rc=$?
chk_eq "fresh BLOCKED.md → 4" 4 "$rc"
rm -f "$WT/BLOCKED.md"

out="$(bash "$AGENTCTL" stop dxA 2>&1)"; rc=$?
chk_eq "stop rc0" 0 "$rc"
chk_eq "stop removes meta" 0 "$([ -f "$WATCH_RUN_DIR/dxA.duplex.meta" ] && echo 1 || echo 0)"
chk_eq "stop keeps events for post-mortem" 1 "$([ -f "$WATCH_RUN_DIR/dxA.duplex.events.jsonl" ] && echo 1 || echo 0)"
unset FAKE_PROVIDER_LOG

echo "== duplex: omp pending question → WAITING =="
export FAKE_OMP_ASK=1 FAKE_PROVIDER_LOG="$SANDBOX/omp-ask.log"
out="$(bash "$AGENTCTL" start omp dxQ "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "ask-session start rc0" 0 "$rc"
out="$(bash "$AGENTCTL" status dxQ 2>&1)"; rc=$?
chk_eq "real confirm request → 4" 4 "$rc"
chk_contains "WAITING surfaces the question" "confirm" "$out"
bash "$AGENTCTL" stop dxQ >/dev/null 2>&1
unset FAKE_OMP_ASK FAKE_PROVIDER_LOG

echo "== duplex: claude lifecycle =="
export AGENTCTL_BIN_CLAUDE="$FIX/fake_claude_duplex.py"
export FAKE_PROVIDER_LOG="$SANDBOX/claude.log"
out="$(bash "$AGENTCTL" start claude dxC "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "claude start rc0" 0 "$rc"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"type":"result"' "$WATCH_RUN_DIR/dxC.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
# assert AFTER the result poll: claude prompt delivery is fire-and-forget, so the
# provider log only exists once the engine has consumed the frame.
chk_contains "claude goal delivered as stream-json user frame" '"type":"user"' "$(cat "$SANDBOX/claude.log")"
out="$(bash "$AGENTCTL" status dxC 2>&1)"; rc=$?
chk_eq "claude result frame → DONE" 0 "$rc"
chk_contains "DONE carries bounded last summary" "turn 1 complete" "$out"
out="$(AGENT_WATCH_MAX_POLLS=6 bash "$AGENTCTL" watch dxC 2>&1)"; rc=$?
chk_eq "duplex watch confirms stable DONE" 0 "$rc"
chk_eq "watch DONE ends with a machine-readable tail" "EXIT=0" "$(printf '%s\n' "$out" | tail -1)"
chk_contains "typed DONE line survives beside the tail" "=== [dxC] DONE" "$out"
out="$(bash "$AGENTCTL" steer dxC -m "one more thing" --now 2>&1)"
chk_contains "claude --now degrades to queued, said out loud" "no public interrupt frame" "$out"
bash "$AGENTCTL" stop dxC >/dev/null 2>&1
unset FAKE_PROVIDER_LOG

echo "== duplex: silent engine → ENGINE-SILENT 8 =="
export FAKE_CLAUDE_MUTE=1
out="$(bash "$AGENTCTL" start claude dxM "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "mute start rc0" 0 "$rc"
out="$(AGENT_WATCH_SILENT_POLLS=2 AGENT_WATCH_MAX_POLLS=6 bash "$AGENTCTL" watch dxM 2>&1)"; rc=$?
chk_eq "no output after steer → exit 8" 8 "$rc"
chk_contains "silent verdict names stderr log" "stderr.log" "$out"
chk_eq "watch ENGINE-SILENT ends with a machine-readable tail" "EXIT=8" "$(printf '%s\n' "$out" | tail -1)"
chk_contains "typed ENGINE-SILENT line survives beside the tail" "=== [dxM] ENGINE-SILENT" "$out"
bash "$AGENTCTL" stop dxM >/dev/null 2>&1
unset FAKE_CLAUDE_MUTE

echo "== duplex: engine death paths =="
export FAKE_CLAUDE_DIE_RC=3
bash "$AGENTCTL" start claude dxD "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$WATCH_RUN_DIR/dxD.duplex.rc" ] && break; /bin/sleep 0.2; done
out="$(bash "$AGENTCTL" status dxD 2>&1)"; rc=$?
chk_eq "engine rc=3 → FAILED 2" 2 "$rc"
printf 'error: insufficient_quota for model\n' >> "$WATCH_RUN_DIR/dxD.duplex.stderr.log"
out="$(bash "$AGENTCTL" status dxD 2>&1)"; rc=$?
chk_eq "rc!=0 + quota chrome → STALLED-EXTERNAL 5" 5 "$rc"
bash "$AGENTCTL" stop dxD >/dev/null 2>&1
unset FAKE_CLAUDE_DIE_RC

bash "$AGENTCTL" start claude dxK "$WT" --goal "$SANDBOX/goal.md" --marker-dxK >/dev/null 2>&1
wpid="$(cat "$FAKE_TMUX_STATE/dxK.pid" 2>/dev/null)"
kill -9 "$wpid" 2>/dev/null; pkill -f "marker-dxK" 2>/dev/null; /bin/sleep 0.3
out="$(bash "$AGENTCTL" status dxK 2>&1)"; rc=$?
chk_eq "no rc + wrapper dead → AGENT-DEAD 2" 2 "$rc"
bash "$AGENTCTL" stop dxK >/dev/null 2>&1

sweep_fakes; sandbox_clean

echo "== review-fix regressions (2026-07-19 cold review) =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wtr"; mkdir -p "$WT"
printf 'do the thing\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_CLAUDE="$FIX/fake_claude_duplex.py"
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"

# S1: an is_error result is a FAILED turn, never DONE (false-success killer)
export FAKE_CLAUDE_ERROR_RESULT=1
bash "$AGENTCTL" start claude rxE "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"is_error":true' "$WATCH_RUN_DIR/rxE.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status rxE 2>&1)"; rc=$?
chk_eq "claude error result → FAILED 2, not DONE" 2 "$rc"
chk_contains "error verdict names the failed turn" "error result" "$out"
bash "$AGENTCTL" stop rxE >/dev/null 2>&1
unset FAKE_CLAUDE_ERROR_RESULT

# sent-offset window: old result must NOT read as DONE while the gated engine
# has produced nothing for the new steer; delivery must be provably received
export FAKE_PROVIDER_LOG="$SANDBOX/gate.log"
bash "$AGENTCTL" start claude rxG "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"type":"result"' "$WATCH_RUN_DIR/rxG.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status rxG 2>&1)"; rc=$?
chk_eq "turn 1 DONE before gated steer" 0 "$rc"
export FAKE_CLAUDE_GATE="$SANDBOX/gate-open"   # takes effect via engine env? no — engine started earlier
# engine was started WITHOUT the gate env, so gate the next turn differently:
# use a big frame to prove >PIPE_BUF delivery instead, and assert the old result
# does not leak through the sent-offset guard while the engine is still working.
python3 -c "print('x' * 100000)" > "$SANDBOX/bigsteer.txt"
out="$(bash "$AGENTCTL" steer rxG -f "$SANDBOX/bigsteer.txt" 2>&1)"; rc=$?
chk_eq "big (>PIPE_BUF) steer rc0" 0 "$rc"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ "$(grep -c '"type":"user"' "$SANDBOX/gate.log" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
chk_eq "second user frame provably received" 2 "$(grep -c '"type":"user"' "$SANDBOX/gate.log")"
chk_eq "big frame arrived complete (no tear)" 1 "$(awk 'length($0) > 100000' "$SANDBOX/gate.log" | grep -c '"type":"user"')"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c '"type":"result"' "$WATCH_RUN_DIR/rxG.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status rxG 2>&1)"; rc=$?
chk_eq "post-steer turn 2 DONE" 0 "$rc"
# every round-state commit journals its offset (replay-corpus sidecar): goal + steer = 2
chk_eq "sent-journal has one entry per rotation" 2 "$(wc -l < "$WATCH_RUN_DIR/rxG.duplex.sent-journal" | tr -d ' ')"
chk_contains "journal entries carry offsets, no frame bodies" '"offset"' "$(cat "$WATCH_RUN_DIR/rxG.duplex.sent-journal")"

# claude --replace is refused with the honest path, never silently degraded —
# and a refused steer must NOT touch the deliverable gate (R2 regression)
out="$(bash "$AGENTCTL" steer rxG -m "start over" --replace -d "never-*.md" 2>&1)"; rc=$?
chk_eq "claude replace refused" 1 "$rc"
chk_contains "refusal routes to stop+resume" "resume" "$out"
chk_eq "refused steer leaves the gate untouched" 0 "$(grep -c '^deliverable=never' "$WATCH_RUN_DIR/rxG.duplex.meta")"
# torn-frame taint marker fails everything closed until stop (R2 regression)
: > "$WATCH_RUN_DIR/rxG.duplex.write-intent"
out="$(bash "$AGENTCTL" status rxG 2>&1)"; rc=$?
chk_eq "write-intent residue → FAILED 2" 2 "$rc"
chk_contains "taint verdict names the recovery" "stop" "$out"
out="$(bash "$AGENTCTL" steer rxG -m "more" 2>&1)"; rc=$?
chk_eq "steer refused on tainted stream" 2 "$rc"
bash "$AGENTCTL" stop rxG >/dev/null 2>&1
chk_eq "stop clears the taint marker" 0 "$([ -e "$WATCH_RUN_DIR/rxG.duplex.write-intent" ] && echo 1 || echo 0)"
unset FAKE_PROVIDER_LOG FAKE_CLAUDE_GATE

# gated engine: steer delivered but zero output → RUNNING (silent), NOT stale DONE
export FAKE_CLAUDE_GATE="$SANDBOX/gate2-open"
export FAKE_PROVIDER_LOG="$SANDBOX/gate2.log"
: > "$FAKE_CLAUDE_GATE"   # gate open for turn 1
bash "$AGENTCTL" start claude rxW "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"type":"result"' "$WATCH_RUN_DIR/rxW.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
rm -f "$FAKE_CLAUDE_GATE"   # close the gate: turn 2 will hang before ANY output
out="$(bash "$AGENTCTL" steer rxW -m "turn two" 2>&1)"; rc=$?
chk_eq "gated steer rc0" 0 "$rc"
/bin/sleep 0.5
out="$(bash "$AGENTCTL" status rxW 2>&1)"; rc=$?
chk_eq "old result does not leak past sent-offset → RUNNING 10" 10 "$rc"
chk_contains "silent detail names the guard" "no output since last steer" "$out"
: > "$FAKE_CLAUDE_GATE"     # reopen: turn 2 completes
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c '"type":"result"' "$WATCH_RUN_DIR/rxW.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status rxW 2>&1)"; rc=$?
chk_eq "gate reopened → DONE" 0 "$rc"
bash "$AGENTCTL" stop rxW >/dev/null 2>&1
unset FAKE_CLAUDE_GATE FAKE_PROVIDER_LOG

# omp anomalous get_state response stays NON-terminal
export FAKE_OMP_BAD_STATE=1
bash "$AGENTCTL" start omp rxB "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
out="$(bash "$AGENTCTL" status rxB 2>&1)"; rc=$?
chk_eq "rejected get_state → RUNNING 10, not DONE" 10 "$rc"
chk_contains "anomalous response surfaced" "anomalous" "$out"
bash "$AGENTCTL" stop rxB >/dev/null 2>&1
unset FAKE_OMP_BAD_STATE

# crash-residue fifo blocks a new same-name start (mkfifo IS the claim), and the
# ADVERTISED recovery path — agentctl stop — must actually clear it (R2 regression)
mkfifo "$WATCH_RUN_DIR/rxF.duplex.in"
out="$(bash "$AGENTCTL" start claude rxF "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "stray fifo → start refused" 1 "$rc"
chk_contains "refusal names the recovery path" "agentctl stop" "$out"
out="$(bash "$AGENTCTL" stop rxF 2>&1)"; rc=$?
chk_eq "stop cleans orphan residue rc0" 0 "$rc"
chk_eq "orphan fifo actually removed" 0 "$([ -e "$WATCH_RUN_DIR/rxF.duplex.in" ] && echo 1 || echo 0)"
sweep_fakes; sandbox_clean

echo "== agentctl verb surface (unknown verbs die clean — 2026-07-19 field report) =="
sandbox_new
out="$(bash "$AGENTCTL" teardown someSess 2>&1)"; rc=$?
chk_eq "unknown verb → clean rc1" 1 "$rc"
chk_contains "usage names the real verbs" "start <omp|codex|claude>" "$out"
chk_not_contains "no bare parameter-expansion error" "3: cwd" "$out"
out="$(bash "$AGENTCTL" stop ghost-session 2>&1)"; rc=$?
chk_eq "stop on unknown session → clean rc1" 1 "$rc"
sandbox_clean

echo "== codex duplex: handshake + steer semantics (unified lane) =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wtc"; mkdir -p "$WT"
printf 'do the codex thing\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_CODEX="$FIX/fake_codex_duplex.py"
export FAKE_PROVIDER_LOG="$SANDBOX/codex.log"
out="$(bash "$AGENTCTL" start codex cxA "$WT" --goal "$SANDBOX/goal.md" --model gpt-fake 2>&1)"; rc=$?
chk_eq "codex start rc0" 0 "$rc"
chk_contains "codex handshake announces thread" "thread thread-1" "$out"
chk_eq "threadId persisted in meta" thread-1 "$(sed -n 's/^thread=//p' "$WATCH_RUN_DIR/cxA.duplex.meta")"
chk_contains "thread/start carries pinned model" '"model":"gpt-fake"' "$(cat "$SANDBOX/codex.log")"
chk_contains "goal delivered as turn/start" '"method":"turn/start"' "$(cat "$SANDBOX/codex.log")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'turn/completed' "$WATCH_RUN_DIR/cxA.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status cxA 2>&1)"; rc=$?
chk_eq "codex turn completed → DONE" 0 "$rc"
chk_contains "DONE carries final answer summary" "turn-1 complete" "$out"
# idle: default steer = next turn; --now refused (engine truth: no active turn)
out="$(bash "$AGENTCTL" steer cxA -m "again" 2>&1)"; rc=$?
chk_eq "idle steer starts next turn rc0" 0 "$rc"
# wait for turn 2's terminal before asserting idle refusal — asserting while turn 2 is
# still active would make --now legitimately succeed (review S3 race, 2026-07-19)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c 'turn/completed' "$WATCH_RUN_DIR/cxA.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" steer cxA -m "mid" --now 2>&1)"; rc=$?
chk_eq "idle --now refused" 1 "$rc"
chk_contains "refusal names default steer" "default steer" "$out"
bash "$AGENTCTL" stop cxA >/dev/null 2>&1
# resume leg: handshake uses thread/resume with the given id
out="$(bash "$AGENTCTL" start codex cxV "$WT" --goal "$SANDBOX/goal.md" --resume-thread old-thread-9 2>&1)"; rc=$?
chk_eq "resume-thread start rc0" 0 "$rc"
chk_eq "resumed threadId persisted" old-thread-9 "$(sed -n 's/^thread=//p' "$WATCH_RUN_DIR/cxV.duplex.meta")"
chk_contains "handshake used thread/resume" '"method":"thread/resume"' "$(cat "$SANDBOX/codex.log")"
bash "$AGENTCTL" stop cxV >/dev/null 2>&1
# --resume-thread is codex-only
out="$(bash "$AGENTCTL" start omp cxW "$WT" --goal "$SANDBOX/goal.md" --resume-thread x 2>&1)"; rc=$?
chk_eq "resume-thread on omp refused" 1 "$rc"
# --model with --resume-thread: the resume handshake sends the threadId alone, so the model
# used to be written to meta and consumed by nobody. Refused before the start owns anything.
out="$(bash "$AGENTCTL" start codex cxM "$WT" --goal "$SANDBOX/goal.md" \
       --resume-thread old-thread-9 --model gpt-fake 2>&1)"; rc=$?
refused=0
case "$out" in *"ERR: --model cannot be combined"*"drop --resume-thread"*) [ "$rc" = 1 ] && refused=1;; esac
chk_eq "model + resume-thread is refused rc1, naming both ways forward" 1 "$refused"
chk_eq "the refusal owns nothing: no meta, no fifo, no lane state for that session" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^cxM\.' | tr '\n' ' ')"

# active-turn window: default steer refused (no queue), --now = native turn/steer
export FAKE_CODEX_GATE="$SANDBOX/cx-gate"
out="$(bash "$AGENTCTL" start codex cxB "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "gated codex start rc0" 0 "$rc"
/bin/sleep 0.3
out="$(bash "$AGENTCTL" status cxB 2>&1)"; rc=$?
chk_eq "gated turn → RUNNING 10" 10 "$rc"
out="$(bash "$AGENTCTL" steer cxB -m "queue me" 2>&1)"; rc=$?
chk_eq "busy default steer refused (no queue)" 1 "$rc"
chk_contains "refusal teaches --now" "use --now" "$out"
out="$(bash "$AGENTCTL" steer cxB -m "adjust" --now 2>&1)"; rc=$?
chk_eq "busy --now rc0 (native mid-turn steer)" 0 "$rc"
chk_contains "turn/steer frame with expectedTurnId" '"expectedTurnId":"turn-1"' "$(cat "$SANDBOX/codex.log")"
# --replace on the ACTIVE turn: interrupt (single terminal) + fresh turn
out="$(bash "$AGENTCTL" steer cxB -m "start over" --replace 2>&1)"; rc=$?
chk_eq "active replace rc0 (interrupt+start)" 0 "$rc"
chk_contains "interrupt frame sent" '"method":"turn/interrupt"' "$(cat "$SANDBOX/codex.log")"
chk_eq "interrupted turn has exactly one terminal" 1 "$(grep -c '"id":"turn-1","status":"interrupted"' "$WATCH_RUN_DIR/cxB.duplex.events.jsonl")"
: > "$FAKE_CODEX_GATE"
# count>=2: turn-1's interrupted terminal must not satisfy the wait for turn-2
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c 'turn/completed' "$WATCH_RUN_DIR/cxB.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status cxB 2>&1)"; rc=$?
chk_eq "gate released → DONE" 0 "$rc"
bash "$AGENTCTL" stop cxB >/dev/null 2>&1
unset FAKE_CODEX_GATE

# sub-thread noise must not read as OUR turn boundary (live dogfood catch 2026-07-19:
# the first codex review session spawned sub-threads whose turn/completed projected as
# a false idle — deliverable gate held, but watch bailed early)
export FAKE_CODEX_GATE="$SANDBOX/cx-noise-gate" FAKE_CODEX_SUBTHREAD_NOISE=1
bash "$AGENTCTL" start codex cxN "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
/bin/sleep 0.5
out="$(bash "$AGENTCTL" status cxN 2>&1)"; rc=$?
chk_eq "sub-thread completion does not fake our idle → 10" 10 "$rc"
: > "$FAKE_CODEX_GATE"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"' "$WATCH_RUN_DIR/cxN.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status cxN 2>&1)"; rc=$?
chk_eq "our own completion still reads DONE" 0 "$rc"
bash "$AGENTCTL" stop cxN >/dev/null 2>&1
unset FAKE_CODEX_GATE FAKE_CODEX_SUBTHREAD_NOISE

# failed turn is FAILED, never DONE (uniform S1 semantics)
export FAKE_CODEX_ERROR_TURN=1
bash "$AGENTCTL" start codex cxE "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'turn/completed' "$WATCH_RUN_DIR/cxE.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status cxE 2>&1)"; rc=$?
chk_eq "failed turn → FAILED 2" 2 "$rc"
bash "$AGENTCTL" stop cxE >/dev/null 2>&1
unset FAKE_CODEX_ERROR_TURN

echo "== codex review seat: the sandbox tier is a lane flag, never a hand-rolled exec =="
# The FRAME is the whole contract, so both tiers are asserted byte-exact with only the volatile
# correlation id normalized away. A "contains sandbox=X" assertion would have let approvalPolicy
# or cwd drift under it unseen — and the default tier's frame must not move AT ALL.
start_frame() { # $1 log — the thread/start frame with the correlation id normalized
  # `[0-9a-f][0-9a-f]*`, never `*`: a zero-width match would normalize a malformed empty
  # `"id":"ctl-"` into `"id":"ID"` and the byte-exact comparison would stop covering the
  # generator's non-empty-id promise (review R1 m1). BRE, so no `\+` — portable spelling.
  grep '"method":"thread/start"' "$1" | sed 's/"id":"ctl-[0-9a-f][0-9a-f]*"/"id":"ID"/'
}
# meta records the cwd as `pwd -P`, and on darwin $TMPDIR resolves through /private — so the
# expectation must be built from the SAME normalization the runtime used, never from $WT.
WTP="$(cd "$WT" && pwd -P)"
export FAKE_PROVIDER_LOG="$SANDBOX/rv-default.log"
out="$(bash "$AGENTCTL" start codex rvD "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "default-tier start rc0" 0 "$rc"
chk_eq "default tier frame is byte-for-byte unchanged" \
  "{\"jsonrpc\":\"2.0\",\"method\":\"thread/start\",\"id\":\"ID\",\"params\":{\"cwd\":\"$WTP\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}}" \
  "$(start_frame "$SANDBOX/rv-default.log")"
chk_eq "a default session carries no review marker in meta" "" \
  "$(sed -n 's/^review=//p' "$WATCH_RUN_DIR/rvD.duplex.meta")"
bash "$AGENTCTL" stop rvD >/dev/null 2>&1
export FAKE_PROVIDER_LOG="$SANDBOX/rv-review.log"
out="$(bash "$AGENTCTL" start codex rvR "$WT" --goal "$SANDBOX/goal.md" --review 2>&1)"; rc=$?
chk_eq "review-tier start rc0" 0 "$rc"
chk_eq "--review moves sandbox and NOTHING else (approvalPolicy stays never)" \
  "{\"jsonrpc\":\"2.0\",\"method\":\"thread/start\",\"id\":\"ID\",\"params\":{\"cwd\":\"$WTP\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}}" \
  "$(start_frame "$SANDBOX/rv-review.log")"
chk_eq "the tier is recorded in session meta" 1 "$(sed -n 's/^review=//p' "$WATCH_RUN_DIR/rvR.duplex.meta")"
chk_contains "the start banner names the tier it requested" "review sandbox=danger-full-access" "$out"
bash "$AGENTCTL" stop rvR >/dev/null 2>&1

# With both tiers unified the wire frame cannot show WHICH key the handshake selected —
# always-default (or a call site hardwired to review=False) would pass the exact-frame
# checks above. Proven through the REAL entry instead: a fixture COPY of the lane with
# divergent tiers must put tier-R on a --review frame and tier-D on a default frame.
DIV="$SANDBOX/divergent-aw"; mkdir -p "$DIV"
cp "$AW_DIR/agentctl" "$AW_DIR/duplexctl.py" "$AW_DIR/identity.py" "$DIV/"
sed -i '' 's/^CODEX_SANDBOX = .*/CODEX_SANDBOX = {"default": "tier-D", "review": "tier-R"}/' "$DIV/duplexctl.py"
export FAKE_PROVIDER_LOG="$SANDBOX/rv-div-r.log"
out="$(bash "$DIV/agentctl" start codex rvWr "$WT" --goal "$SANDBOX/goal.md" --review --no-preflight 2>&1)"; rc=$?
chk_eq "divergent fixture: review start rc0" 0 "$rc"
chk_contains "divergent fixture: review flag reaches the wire frame" '"sandbox":"tier-R"' \
  "$(start_frame "$SANDBOX/rv-div-r.log")"
bash "$DIV/agentctl" stop rvWr >/dev/null 2>&1
export FAKE_PROVIDER_LOG="$SANDBOX/rv-div-d.log"
out="$(bash "$DIV/agentctl" start codex rvWd "$WT" --goal "$SANDBOX/goal.md" --no-preflight 2>&1)"; rc=$?
chk_eq "divergent fixture: default start rc0" 0 "$rc"
chk_contains "divergent fixture: default frame stays on the default tier" '"sandbox":"tier-D"' \
  "$(start_frame "$SANDBOX/rv-div-d.log")"
bash "$DIV/agentctl" stop rvWd >/dev/null 2>&1

# Both refusals are PARAMETER-surface refusals, so they own nothing. The self-proving check is
# that the same session name starts clean immediately afterwards: a leftover fifo or meta file
# would refuse it (the mkfifo claim is the collision detector).
out="$(bash "$AGENTCTL" start codex rvX "$WT" --goal "$SANDBOX/goal.md" --review \
       --resume-thread old-thread-9 2>&1)"; rc=$?
chk_eq "--review with --resume-thread refused rc1" 1 "$rc"
chk_contains "the refusal says resume carries no sandbox" "thread/resume carries only the threadId" "$out"
chk_eq "that refusal owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvX\.' | tr '\n' ' ')"
out="$(bash "$AGENTCTL" start codex rvX "$WT" --goal "$SANDBOX/goal.md" --review 2>&1)"; rc=$?
chk_eq "the same name starts clean right after the refusal" 0 "$rc"
bash "$AGENTCTL" stop rvX >/dev/null 2>&1
# omp/claude forward unrecognized start args to the engine binary VERBATIM, so a non-codex
# --review has to be refused here — "the engine will reject it" is not a refusal.
out="$(bash "$AGENTCTL" start omp rvO "$WT" --goal "$SANDBOX/goal.md" --review 2>&1)"; rc=$?
chk_eq "--review on a provider with no sandbox tier refused rc1" 1 "$rc"
chk_contains "the refusal names the missing tier" "declares none" "$out"
chk_eq "and it owns no lane state either" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvO\.' | tr '\n' ' ')"

# The deliverable fence: review artifacts written into unrelated trees outlive worktree
# cleanup as orphans, and the exit-6 near-miss scan walks cwd only — refused before the
# lane owns anything.
out="$(bash "$AGENTCTL" start codex rvG1 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "$SANDBOX/outside.md" 2>&1)"; rc=$?
chk_eq "review + absolute glob OUTSIDE cwd refused" 1 "$rc"
chk_contains "the refusal names the boundary" "must live INSIDE its session cwd" "$out"
chk_eq "the deliverable refusal owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvG1\.' | tr '\n' ' ')"
out="$(bash "$AGENTCTL" start codex rvG2 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "$WTP/REVIEW.md" 2>&1)"; rc=$?
chk_eq "review + absolute glob INSIDE cwd accepted" 0 "$rc"
bash "$AGENTCTL" stop rvG2 >/dev/null 2>&1
out="$(bash "$AGENTCTL" start codex rvG3 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable 'REVIEW-*.md' 2>&1)"; rc=$?
chk_eq "review + relative glob accepted (resolved against cwd by construction)" 0 "$rc"
bash "$AGENTCTL" stop rvG3 >/dev/null 2>&1
# path COMPONENT, not string prefix: a sibling spelled like the cwd must not read as inside it
mkdir -p "${WTP}-2"
out="$(bash "$AGENTCTL" start codex rvG4 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "${WTP}-2/x.md" 2>&1)"; rc=$?
chk_eq "sibling sharing the cwd's string prefix refused" 1 "$rc"
# a `..` component is refused outright — nothing is resolved, because nothing exists yet
out="$(bash "$AGENTCTL" start codex rvG5 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "$WTP/../escape.md" 2>&1)"; rc=$?
chk_eq "'..' component refused without resolving it" 1 "$rc"
# R1 B1: the ORIGINAL contract assumed a relative glob "cannot escape because it is resolved
# against cwd". False for `..` — duplexctl joins it onto the cwd and it lands one level up. Both
# of these were rc=0 (accepted, lane state created) before the fix.
out="$(bash "$AGENTCTL" start codex rvE1 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "../outside-review.md" 2>&1)"; rc=$?
chk_eq "RELATIVE '..' glob refused (a relative glob is not automatically safe)" 1 "$rc"
chk_eq "the relative-escape refusal owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvE1\.' | tr '\n' ' ')"
# R1 B1 second half: a symlink INSIDE cwd whose target is outside it. Lexical comparison called
# this inside the cwd; the write would have landed outside the workspace. The deepest EXISTING
# ancestor is resolved physically (`cd … && pwd -P`, no realpath(1) — macOS has no `-m`).
mkdir -p "$SANDBOX/rv-escape"
ln -s ../rv-escape "$WT/rvlink"
out="$(bash "$AGENTCTL" start codex rvE2 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "$WTP/rvlink/result.md" 2>&1)"; rc=$?
chk_eq "absolute path through a cwd-internal symlink pointing OUT refused" 1 "$rc"
out="$(bash "$AGENTCTL" start codex rvE3 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "rvlink/result.md" 2>&1)"; rc=$?
chk_eq "and the same escape spelled relatively refused too" 1 "$rc"
# PAIRED GREEN: a symlink that stays inside the cwd is still a legal target — the gate resolves
# links, it does not ban them.
mkdir -p "$WT/rvinside"
ln -s rvinside "$WT/rvin"
out="$(bash "$AGENTCTL" start codex rvE4 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "$WTP/rvin/result.md" 2>&1)"; rc=$?
chk_eq "a symlink resolving INSIDE cwd is accepted" 0 "$rc"
bash "$AGENTCTL" stop rvE4 >/dev/null 2>&1
# a deep glob whose intermediate dirs do not exist yet resolves to the deepest EXISTING
# ancestor — the cwd itself — so it passes; the target need not exist
out="$(bash "$AGENTCTL" start codex rvE5 "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable "docs/orchestration/REVIEW.md" 2>&1)"; rc=$?
chk_eq "a not-yet-existing subpath inside cwd is accepted" 0 "$rc"
bash "$AGENTCTL" stop rvE5 >/dev/null 2>&1

# R1 M2: meta is one key=value per line, so a newline in a param-plane value injects meta KEYS.
# `artifact-*.md\nreview=1` minted a review seat on a session that never asked for one.
# Refused, not encoded.
out="$(bash "$AGENTCTL" start codex rvI1 "$WT" --goal "$SANDBOX/goal.md" \
       --deliverable "$(printf 'artifact-*.md\nreview=1')" 2>&1)"; rc=$?
chk_eq "newline in --deliverable refused" 1 "$rc"
chk_contains "the refusal names the injection" "would inject meta KEYS" "$out"
chk_eq "the injection attempt owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvI1\.' | tr '\n' ' ')"
# the same file format, the same hole: every param-plane value that reaches meta is checked
out="$(bash "$AGENTCTL" start codex rvI2 "$WT" --goal "$SANDBOX/goal.md" \
       --model "$(printf 'gpt-fake\nreview=1')" 2>&1)"; rc=$?
chk_eq "newline in --model refused too" 1 "$rc"
# and on the steer surface, where duplexctl's meta_update writes the same file
out="$(bash "$AGENTCTL" start codex rvI3 "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "clean session for the steer injection probe started" 0 "$rc"
out="$(bash "$AGENTCTL" steer rvI3 -m "x" -d "$(printf 'a.md\nreview=1')" 2>&1)"; rc=$?
chk_eq "newline in steer -d refused" 1 "$rc"
chk_eq "and no review marker reached the meta" "" \
  "$(sed -n 's/^review=//p' "$WATCH_RUN_DIR/rvI3.duplex.meta")"
bash "$AGENTCTL" stop rvI3 >/dev/null 2>&1
# R2 F3: `--cwd` reaches the SAME line-oriented meta (`printf 'engine=%s\ncwd=%s\n'`) and was
# missing from the checked enumeration, so a directory whose name legitimately contains a
# newline injected `review=1` and re-pinned the codex sandbox tier without `--review`.
BADCWD="$SANDBOX/$(printf 'wtx\nreview=1')"
mkdir -p "$BADCWD" "$SANDBOX/wtx"
out="$(bash "$AGENTCTL" start codex rvC1 "$BADCWD" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "newline in the session cwd refused" 1 "$rc"
chk_contains "the cwd refusal names the injection" "would inject meta KEYS" "$out"
chk_eq "the cwd injection owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvC1\.' | tr '\n' ' ')"
# and the same directory is fine once it has no newline: the gate judges the VALUE, not the dir
out="$(bash "$AGENTCTL" start codex rvC2 "$SANDBOX/wtx" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "the newline-free sibling directory still starts" 0 "$rc"
bash "$AGENTCTL" stop rvC2 >/dev/null 2>&1
# the ENGINE-controlled route into meta: thread/start's threadId never passes the parameter
# surface at all, so meta_update itself is the backstop. A newline there must fail the handshake
# closed rather than write extra keys.
export FAKE_CODEX_THREAD_ID="$(printf 'thread-9\nreview=1')"
out="$(bash "$AGENTCTL" start codex rvC3 "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "an engine-supplied threadId with a newline fails the start" 1 "$rc"
chk_eq "and no meta survives it" 0 \
  "$([ -e "$WATCH_RUN_DIR/rvC3.duplex.meta" ] && echo 1 || echo 0)"
unset FAKE_CODEX_THREAD_ID
# PAIRED GREEN: the same knob with a legal id still completes the handshake
export FAKE_CODEX_THREAD_ID=thread-legal
out="$(bash "$AGENTCTL" start codex rvC4 "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "a legal engine-supplied threadId still starts" 0 "$rc"
chk_eq "and lands in meta" thread-legal "$(sed -n 's/^thread=//p' "$WATCH_RUN_DIR/rvC4.duplex.meta")"
bash "$AGENTCTL" stop rvC4 >/dev/null 2>&1
unset FAKE_CODEX_THREAD_ID

# R2 F4: the root-directory edge of the containment comparison. `cwd + "/"` is `//` at the root,
# which no real path starts with, so cwd=/ refused its own descendants. Driven through the
# `check-params` verb because no lane session can be rooted at `/`.
cp_rc() { python3 "$AW_DIR/duplexctl.py" --run-dir "$WATCH_RUN_DIR" check-params "$@" \
            >/dev/null 2>&1; echo $?; }
chk_eq "F4 cwd=/ accepts a descendant" 0 \
  "$(cp_rc --gate start --cwd / --review --deliverable /tmp/result.md)"
chk_eq "F4 '--deliverable /' is a directory, not a deliverable: refused" 1 \
  "$(cp_rc --gate start --cwd / --review --deliverable /)"
chk_eq "F4 a trailing slash is refused for the same reason" 1 \
  "$(cp_rc --gate start --cwd "$WTP" --review --deliverable "$WTP/")"
chk_eq "F4 cwd=/ still refuses a '..' escape" 1 \
  "$(cp_rc --gate start --cwd / --review --deliverable ../x.md)"


# R1 B3: an older SIX-field provider row must not hand the resume flag over AS the review tier.
# `${var#*|}` returns the string unchanged when no delimiter is left, so `--review` used to be
# ACCEPTED against a producer that never promised a tier. The AGENTCTL_PYTHON seam (a documented
# knob) intercepts only `providers --shell` and drops the 7th field; everything else is real.
cat > "$BIN/py-6field" <<'SIXEOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = providers ] && { python3 "$@" | sed 's/|[^|]*$//'; exit $?; }; done
exec python3 "$@"
SIXEOF
chmod +x "$BIN/py-6field"
chk_eq "the seam really produces a six-field codex row" 6 \
  "$("$BIN/py-6field" "$AW_DIR/duplexctl.py" providers --shell \
     | grep '^codex|' | awk -F'|' '{print NF}')"
out="$(AGENTCTL_PYTHON="$BIN/py-6field" bash "$AGENTCTL" start codex rvB3 "$WT" \
       --goal "$SANDBOX/goal.md" --review 2>&1)"; rc=$?
chk_eq "--review against a six-field row refused rc1" 1 "$rc"
chk_contains "the refusal names the missing tier, not the resume flag" "declares none" "$out"
chk_not_contains "and never echoes the resume flag as a sandbox tier" "sandbox=--resume-thread" "$out"
chk_eq "the degraded-row refusal owns no lane state" "" \
  "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep '^rvB3\.' | tr '\n' ' ')"
# PAIRED GREEN: the same start against the REAL seven-field row still succeeds
out="$(bash "$AGENTCTL" start codex rvB3 "$WT" --goal "$SANDBOX/goal.md" --review 2>&1)"; rc=$?
chk_eq "the real seven-field row still accepts --review" 0 "$rc"
bash "$AGENTCTL" stop rvB3 >/dev/null 2>&1

# NEGATIVE CONTROL: the fence belongs to the review SEAT alone. The execution seat
# legitimately delivers outside cwd (build outputs) — this goes red if the gate leaks.
out="$(bash "$AGENTCTL" start codex rvG6 "$WT" --goal "$SANDBOX/goal.md" \
       --deliverable "$SANDBOX/outside.md" 2>&1)"; rc=$?
chk_eq "default tier + cwd-external glob still allowed" 0 "$rc"
bash "$AGENTCTL" stop rvG6 >/dev/null 2>&1

# `steer -d` moves the freshness target, so it must clear the SAME fence: otherwise a session
# that opened compliant is walked out of its fence by one steer.
out="$(bash "$AGENTCTL" start codex rvS "$WT" --goal "$SANDBOX/goal.md" --review \
       --deliverable REVIEW.md 2>&1)"; rc=$?
chk_eq "review session for the steer gate started" 0 "$rc"
out="$(bash "$AGENTCTL" steer rvS -m "move it out" -d "$SANDBOX/outside.md" 2>&1)"; rc=$?
chk_eq "review steer -d outside cwd refused" 1 "$rc"
chk_eq "and the deliverable did NOT move" "REVIEW.md" \
  "$(sed -n 's/^deliverable=//p' "$WATCH_RUN_DIR/rvS.duplex.meta")"
# the paired green: the same steer with an in-cwd target lands (idle turn required — codex has
# no queue, so wait for the goal turn's terminal first)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'turn/completed' "$WATCH_RUN_DIR/rvS.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" steer rvS -m "move it in" -d "$WTP/REVIEW2.md" 2>&1)"; rc=$?
chk_eq "review steer -d inside cwd accepted" 0 "$rc"
chk_eq "and the deliverable moved" "$WTP/REVIEW2.md" \
  "$(sed -n 's/^deliverable=//p' "$WATCH_RUN_DIR/rvS.duplex.meta")"
bash "$AGENTCTL" stop rvS >/dev/null 2>&1

echo "== review-loop budget rides the duplex lane (all engines) =="
export FAKE_PROVIDER_LOG="$SANDBOX/budget.log"
out="$(bash "$AGENTCTL" start codex cxR "$WT" --goal "$SANDBOX/goal.md" --workflow review-loop --max-rounds 2 2>&1)"; rc=$?
chk_eq "review-loop start rc0 (round 1)" 0 "$rc"
chk_eq "budget persisted in duplex meta" 2 "$(sed -n 's/^max_rounds=//p' "$WATCH_RUN_DIR/cxR.duplex.meta")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'turn/completed' "$WATCH_RUN_DIR/cxR.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" steer cxR -m "round two please" 2>&1)"; rc=$?
chk_eq "round 2 steer rc0" 0 "$rc"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c 'turn/completed' "$WATCH_RUN_DIR/cxR.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" steer cxR -m "SHIP-BLOCKING: real issue remains" 2>&1)"; rc=$?
chk_eq "round 3 beyond budget → BUDGET-EXHAUSTED 9" 9 "$rc"
chk_contains "budget verdict names max-rounds" "max-rounds=2" "$out"
bash "$AGENTCTL" stop cxR >/dev/null 2>&1
# lease: with budget 3, round 3 continuation demands SHIP-BLOCKING
out="$(bash "$AGENTCTL" start codex cxL "$WT" --goal "$SANDBOX/goal.md" --workflow review-loop --max-rounds 3 2>&1)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'turn/completed' "$WATCH_RUN_DIR/cxL.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
bash "$AGENTCTL" steer cxL -m "round two" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c 'turn/completed' "$WATCH_RUN_DIR/cxL.duplex.events.jsonl" 2>/dev/null)" -ge 2 ] && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" steer cxL -m "no lease here" 2>&1)"; rc=$?
chk_eq "round 3 without lease refused" 1 "$rc"
chk_contains "lease error names SHIP-BLOCKING" "SHIP-BLOCKING" "$out"
out="$(bash "$AGENTCTL" steer cxL -m "SHIP-BLOCKING: verified regression" 2>&1)"; rc=$?
chk_eq "round 3 with lease rc0" 0 "$rc"
bash "$AGENTCTL" stop cxL >/dev/null 2>&1
unset FAKE_PROVIDER_LOG
sweep_fakes; sandbox_clean

echo "== 1.6.0 runtime: preflight default / EXIT tail / watcher-absence note =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wtn"; mkdir -p "$WT"
export AGENTCTL_BIN_CLAUDE="$FIX/fake_claude_duplex.py"
export AGENTCTL_BIN_CODEX="$FIX/fake_codex_duplex.py"
bare="$SANDBOX/bare.md"; printf 'mechanical rename, nothing to falsify\n' > "$bare"
declared="$SANDBOX/declared.md"
printf 'risky direction\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$declared"

# preflight is ON by default (1.6.0 flip): opt-in-by-memory is what kept failing
out="$(bash "$AGENTCTL" start claude pfA "$WT" --goal "$bare" 2>&1)"; rc=$?
chk_eq "undeclared goal refused by default" 1 "$rc"
chk_contains "refusal names the preflight contract" "preflight gate" "$out"
chk_contains "refusal points at the explicit exemption" "--no-preflight" "$out"
chk_eq "refused start launched no engine" 0 "$([ -e "$FAKE_TMUX_STATE/pfA.pid" ] && echo 1 || echo 0)"
chk_eq "refused start left no lane state" 0 "$([ -e "$WATCH_RUN_DIR/pfA.duplex.meta" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" start claude pfB "$WT" --goal "$bare" --no-preflight 2>&1)"; rc=$?
chk_eq "--no-preflight exempts the same goal" 0 "$rc"
bash "$AGENTCTL" stop pfB >/dev/null 2>&1
out="$(bash "$AGENTCTL" start claude pfC "$WT" --goal "$declared" 2>&1)"; rc=$?
chk_eq "resolved declaration passes the default gate" 0 "$rc"
bash "$AGENTCTL" stop pfC >/dev/null 2>&1
# legacy spelling stays accepted as a no-op — codex REFUSES unrecognized argv, so rc0
# proves the parser consumed the flag instead of leaking it into engine args
out="$(bash "$AGENTCTL" start codex pfL "$WT" --goal "$declared" --require-preflight 2>&1)"; rc=$?
chk_eq "legacy --require-preflight accepted, never leaked to engine argv" 0 "$rc"
bash "$AGENTCTL" stop pfL >/dev/null 2>&1

# gate never opens: turn 1 hangs before ANY output → a durably RUNNING session
export FAKE_CLAUDE_GATE="$SANDBOX/nw-gate"
bash "$AGENTCTL" start claude nwR "$WT" --goal "$declared" >/dev/null 2>&1
/bin/sleep 0.3
out="$(bash "$AGENTCTL" status nwR 2>&1)"; rc=$?
chk_eq "gated engine → RUNNING 10" 10 "$rc"
chk_eq "RUNNING leaves no terminal marker" 0 "$([ -e "$WATCH_RUN_DIR/nwR.terminal.json" ] && echo 1 || echo 0)"
out="$(AGENT_WATCH_MAX_POLLS=2 AGENT_WATCH_SILENT_POLLS=99 bash "$AGENTCTL" watch nwR 2>&1)"; rc=$?
chk_eq "bounded poll exhausted → exit 7" 7 "$rc"
chk_eq "watch TIMEOUT ends with a machine-readable tail" "EXIT=7" "$(printf '%s\n' "$out" | tail -1)"
chk_contains "typed TIMEOUT line survives beside the tail" "=== [nwR] WATCH TIMEOUT" "$out"
chk_eq "watch removes its own pid file on exit" 0 "$([ -e "$WATCH_RUN_DIR/nwR.duplex.watch.pid" ] && echo 1 || echo 0)"

# RUNNING + nobody watching = the omission a guard reminder caught 4x in one day
out="$(bash "$AGENTCTL" status nwR 2>&1)"; rc=$?
chk_eq "no-watcher note leaves the verdict at RUNNING 10" 10 "$rc"
chk_contains "typed RUNNING line still printed" "RUNNING:" "$out"
chk_contains "absent watcher → note prompts to arm one" "no watcher armed" "$out"
chk_contains "note carries the ready-to-run command" "agentctl watch nwR" "$out"
printf '%s\n' "$$" > "$WATCH_RUN_DIR/nwR.duplex.watch.pid"   # live pid = this test shell
out="$(bash "$AGENTCTL" status nwR 2>&1)"; rc=$?
chk_eq "live watcher: verdict still RUNNING 10" 10 "$rc"
chk_not_contains "live watcher silences the note" "no watcher armed" "$out"
/bin/sleep 5 & dead=$!; kill -9 "$dead" 2>/dev/null; wait "$dead" 2>/dev/null
printf '%s\n' "$dead" > "$WATCH_RUN_DIR/nwR.duplex.watch.pid"   # stale: file in, process gone
out="$(bash "$AGENTCTL" status nwR 2>&1)"; rc=$?
chk_eq "stale watcher pid: verdict still RUNNING 10" 10 "$rc"
chk_contains "stale watcher pid still warns (noisy beats missed)" "no watcher armed" "$out"
: > "$FAKE_CLAUDE_GATE"   # release the turn: terminal states carry no note
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"type":"result"' "$WATCH_RUN_DIR/nwR.duplex.events.jsonl" 2>/dev/null && break
  /bin/sleep 0.2
done
out="$(bash "$AGENTCTL" status nwR 2>&1)"; rc=$?
chk_eq "released gate → DONE 0" 0 "$rc"
chk_not_contains "terminal verdict carries no watcher note" "no watcher armed" "$out"
chk_eq "undeclared deliverable: one-shot status leaves no durable marker (F6)" 0 "$([ -e "$WATCH_RUN_DIR/nwR.terminal.json" ] && echo 1 || echo 0)"
out="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=6 bash "$AGENTCTL" watch nwR 2>&1)"; rc=$?
chk_eq "watch reaches stable DONE" 0 "$rc"
chk_eq "watch 2-stable read drops the marker even undeclared" 1 "$([ -s "$WATCH_RUN_DIR/nwR.terminal.json" ] && echo 1 || echo 0)"
chk_contains "marker records rc0" '"rc": 0' "$(cat "$WATCH_RUN_DIR/nwR.terminal.json" 2>/dev/null)"
bash "$AGENTCTL" stop nwR >/dev/null 2>&1
chk_eq "stop removes the watcher pid file" 0 "$([ -e "$WATCH_RUN_DIR/nwR.duplex.watch.pid" ] && echo 1 || echo 0)"
chk_eq "stop removes the terminal marker" 0 "$([ -e "$WATCH_RUN_DIR/nwR.terminal.json" ] && echo 1 || echo 0)"

# marker lifecycle (review F1/F3): declared deliverable + quoted glob → durable, parseable, round-scoped
FAKE_PROVIDER_LOG="$SANDBOX/dmS.log" \
bash "$AGENTCTL" start claude dmS "$WT" --goal "$declared" --deliverable 'dm-"q"-*.md' >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '"type":"result"' "$WATCH_RUN_DIR/dmS.duplex.events.jsonl" 2>/dev/null && break; /bin/sleep 0.2; done
# with-deliverable start: the file-delivery sentence must survive into the ENGINE-received
# frame through the PRODUCTION call point (review R2 M1 — helper-only tests missed the wire)
chk_contains "declared-deliverable prompt frame carries file contract" "chat output is not delivery" "$(cat "$SANDBOX/dmS.log")"
: > "$WT/dm-\"q\"-1.md"
out="$(bash "$AGENTCTL" status dmS 2>&1)"; rc=$?
chk_eq "declared+fresh deliverable → DONE 0" 0 "$rc"
chk_eq "declared deliverable: status persists the marker" 1 "$([ -s "$WATCH_RUN_DIR/dmS.terminal.json" ] && echo 1 || echo 0)"
chk_eq "quoted glob still yields valid marker JSON (F3)" 0 "$(python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WATCH_RUN_DIR/dmS.terminal.json" >/dev/null 2>&1; echo $?)"
bash "$AGENTCTL" steer dmS -m "round two" >/dev/null 2>&1
chk_eq "steer opens a new round and clears the marker (F1)" 0 "$([ -e "$WATCH_RUN_DIR/dmS.terminal.json" ] && echo 1 || echo 0)"
# steer -d moves the freshness target WITHOUT re-sending the footer — the runtime must say
# so to the operator at the decision point (review R3: the boundary lived in a helper
# comment no CLI operator ever meets)
sderr="$(bash "$AGENTCTL" steer dmS -m "write into the new file" -d 'moved-*.md' 2>&1 >/dev/null)"
chk_contains "steer -d surfaces the no-refooter boundary to the operator" "does NOT re-send the footer" "$sderr"
chk_contains "steer -d note names the new target" "moved-*.md" "$sderr"
chk_eq "steer -d really moved the meta target" "moved-*.md" "$(sed -n 's/^deliverable=//p' "$WATCH_RUN_DIR/dmS.duplex.meta" | tail -1)"
bash "$AGENTCTL" stop dmS >/dev/null 2>&1

# stale same-name marker: start claims the name and clears prior-life residue (F1)
printf '{"rc":0,"stale":true}\n' > "$WATCH_RUN_DIR/stM.terminal.json"
bash "$AGENTCTL" start claude stM "$WT" --goal "$declared" >/dev/null 2>&1
chk_eq "start clears a stale same-name marker (F1)" 0 "$([ -e "$WATCH_RUN_DIR/stM.terminal.json" ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop stM >/dev/null 2>&1
printf '{"rc":0}\n' > "$WATCH_RUN_DIR/orx.terminal.json"
: > "$WATCH_RUN_DIR/orx.duplex.prompt"
out="$(bash "$AGENTCTL" stop orx 2>&1)"
chk_contains "none-branch stop sweeps residue" "orphan session residue" "$out"
chk_eq "none-branch stop clears the marker too (F1)" 0 "$([ -e "$WATCH_RUN_DIR/orx.terminal.json" ] && echo 1 || echo 0)"

# tombstone rotation must never destroy forensics on a failed append (F4)
printf 'engine=claude\ncwd=%s\n' "$WT" > "$WATCH_RUN_DIR/fbT.duplex.meta"
printf '{"event":"watcher-killed"}\n' > "$WATCH_RUN_DIR/fbT.watch.tombstone.jsonl"
mkdir -p "$WATCH_RUN_DIR/fbT.watch.tombstone.jsonl.consumed"
bash "$AGENTCTL" stop fbT >/dev/null 2>&1
chk_eq "failed rotation keeps the tombstone (F4)" 1 "$([ -f "$WATCH_RUN_DIR/fbT.watch.tombstone.jsonl" ] && echo 1 || echo 0)"
rm -rf "$WATCH_RUN_DIR/fbT.watch.tombstone.jsonl.consumed" "$WATCH_RUN_DIR/fbT.watch.tombstone.jsonl"
unset FAKE_CLAUDE_GATE
sweep_fakes; sandbox_clean

echo "== watcher tombstone: external TERM is attributable, trap is prompt =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wtt"; mkdir -p "$WT"
export AGENTCTL_BIN_CLAUDE="$FIX/fake_claude_duplex.py"
tgoal="$SANDBOX/tg.md"; printf 'g\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$tgoal"
export FAKE_CLAUDE_GATE="$SANDBOX/tw-gate"     # never released: durably RUNNING session
bash "$AGENTCTL" start claude twR "$WT" --goal "$tgoal" >/dev/null 2>&1
AGENT_WATCH_POLL_SECS=15 bash "$AGENTCTL" watch twR > "$SANDBOX/tw.log" 2>&1 &
WP=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$WATCH_RUN_DIR/twR.duplex.watch.pid" ] && break; /bin/sleep 0.2; done
kill -TERM "$WP"
# promptness IS the contract: bare foreground sleep defers the trap up to POLL seconds
# (probed 14s) and the tombstone loses the race against a TERM→KILL grace window
tries=0
while kill -0 "$WP" 2>/dev/null; do
  tries=$((tries+1)); [ "$tries" -ge 30 ] && break; /bin/sleep 0.1
done
chk_eq "TERM'd watcher exits within ~3s (interruptible wait)" 0 "$(kill -0 "$WP" 2>/dev/null && echo 1 || echo 0)"
wait "$WP" 2>/dev/null; rc=$?
chk_eq "TERM'd watcher exit code 143" 143 "$rc"
TS="$WATCH_RUN_DIR/twR.watch.tombstone.jsonl"
chk_eq "tombstone file written" 1 "$([ -s "$TS" ] && echo 1 || echo 0)"
chk_contains "tombstone records the signal" '"signal":"TERM"' "$(cat "$TS" 2>/dev/null)"
chk_contains "tombstone records the arming parent" '"ppid":' "$(cat "$TS" 2>/dev/null)"
chk_eq "pid file cleaned on TERM (no stale window)" 0 "$([ -e "$WATCH_RUN_DIR/twR.duplex.watch.pid" ] && echo 1 || echo 0)"

# the killed-notification can die with the host: status must surface the unresolved death
out="$(bash "$AGENTCTL" status twR 2>&1)"; rc=$?
chk_eq "dead-watcher status verdict stays RUNNING 10" 10 "$rc"
chk_contains "status surfaces the unresolved death" "previous watcher killed externally" "$out"
chk_contains "attribution carries the tombstone record" '"signal":"TERM"' "$out"
chk_contains "death note keeps the semantic warning" "killed ≠ worker dead" "$out"

# batch reaping: a second gated session TERM'd seconds later = same reap event
bash "$AGENTCTL" start claude twS "$WT" --goal "$tgoal" >/dev/null 2>&1
AGENT_WATCH_POLL_SECS=15 bash "$AGENTCTL" watch twS > "$SANDBOX/tws.log" 2>&1 &
WP2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$WATCH_RUN_DIR/twS.duplex.watch.pid" ] && break; /bin/sleep 0.2; done
kill -TERM "$WP2"; wait "$WP2" 2>/dev/null
out="$(bash "$AGENTCTL" status twR 2>&1)"
chk_contains "same-event peer named for batch re-arm" "watchers of: twS" "$out"
chk_contains "peer note prompts re-arming each" "re-arm each" "$out"
printf '%s\n' "$$" > "$WATCH_RUN_DIR/twS.duplex.watch.pid"   # peer re-armed: live pid
out="$(bash "$AGENTCTL" status twR 2>&1)"
chk_not_contains "re-armed peer drops off the reap list" "re-arm each" "$out"
rm -f "$WATCH_RUN_DIR/twS.duplex.watch.pid"
touch -t 202601010000 "$WATCH_RUN_DIR/twS.watch.tombstone.jsonl"   # distant death = different event
out="$(bash "$AGENTCTL" status twR 2>&1)"
chk_not_contains "old tombstone is not this reap event" "re-arm each" "$out"
chk_contains "own-death attribution survives without peers" "previous watcher killed externally" "$out"

# arming supersedes the prior death: watch rotates the tombstone into .consumed
AGENT_WATCH_POLL_SECS=15 bash "$AGENTCTL" watch twR > "$SANDBOX/tw2.log" 2>&1 &
WP3=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$WATCH_RUN_DIR/twR.duplex.watch.pid" ] && break; /bin/sleep 0.2; done
chk_eq "arming rotates the tombstone away" 0 "$([ -e "$WATCH_RUN_DIR/twR.watch.tombstone.jsonl" ] && echo 1 || echo 0)"
chk_eq "consumed forensics preserved" 1 "$([ -s "$WATCH_RUN_DIR/twR.watch.tombstone.jsonl.consumed" ] && echo 1 || echo 0)"
kill -9 "$WP3" 2>/dev/null; wait "$WP3" 2>/dev/null   # KILL: untrappable — no fresh tombstone
rm -f "$WATCH_RUN_DIR/twR.duplex.watch.pid"           # KILL also skips the EXIT trap
out="$(bash "$AGENTCTL" status twR 2>&1)"
chk_contains "no active tombstone → plain no-watcher note" "no watcher armed" "$out"
chk_not_contains "consumed death is never re-reported" "previous watcher killed externally" "$out"

bash "$AGENTCTL" stop twS >/dev/null 2>&1
chk_eq "stop consumes the tombstone (same-name restart safe)" 0 "$([ -e "$WATCH_RUN_DIR/twS.watch.tombstone.jsonl" ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop twR >/dev/null 2>&1
unset FAKE_CLAUDE_GATE
sweep_fakes; sandbox_clean

echo "== watch vs classify timeout: single 8 does not fell the watcher =="
sandbox_new; install_running_tmux
WT8="$SANDBOX/wt8"; mkdir -p "$WT8" "$SANDBOX/bin8"
ln -s /usr/bin/true "$SANDBOX/bin8/tmux"   # hand-built session: liveness probe must pass so classify reaches the lock
printf 'engine=omp\ncwd=%s\n' "$WT8" > "$WATCH_RUN_DIR/tmoS.duplex.meta"
: > "$WATCH_RUN_DIR/tmoS.duplex.events.jsonl"; : > "$WATCH_RUN_DIR/tmoS.duplex.stderr.log"
# classify refuses a session with no established identity the same way it refuses a corrupt
# one (WS1), so a hand-built session has to arm a record before the lock contention matters
python3 "$AW_DIR/duplexctl.py" --run-dir "$WATCH_RUN_DIR" identity start tmoS >/dev/null 2>&1
python3 - "$WATCH_RUN_DIR/tmoS.duplex.wlock" "$SANDBOX/held8" <<'EOF' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(30)
EOF
H8=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$SANDBOX/held8" ] && break; /bin/sleep 0.2; done
t0=$(date +%s)
out="$(PATH="$SANDBOX/bin8:$PATH" AGENT_WATCH_STATUS_TIMEOUT=1 AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=5 bash "$AGENTCTL" watch tmoS 2>&1)"; rc=$?
el=$(( $(date +%s) - t0 ))
chk_eq "two consecutive classify timeouts → watch exits 8" 8 "$rc"
chk_eq "machine tail is EXIT=8" "EXIT=8" "$(printf '%s\n' "$out" | tail -1)"
chk_eq "did not fall on the first 8 (>=2 polls elapsed)" 1 "$([ "$el" -ge 2 ] && echo 1 || echo 0)"
kill "$H8" 2>/dev/null; wait "$H8" 2>/dev/null
bash "$AGENTCTL" stop tmoS >/dev/null 2>&1
sweep_fakes; sandbox_clean

echo "== guard: TaskStop deny covers wrong-premise motive =="
TID="agdx$$"
TDIR="/tmp/claude-agdxtest/$$/x/tasks"; mkdir -p "$TDIR"; printf 'alive\n' > "$TDIR/$TID.output"
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"TaskStop","tool_input":{"task_id":"%s"}}' "$TID" \
      | python3 "$GUARD" 2>&1)"; rc=$?
chk_eq "fresh transcript → deny rc2" 2 "$rc"
chk_contains "deny names the wrong-premise motive" "premise is wrong" "$out"
chk_contains "deny keeps the doc pointer" "Read: cto-orchestration" "$out"
rm -rf "/tmp/claude-agdxtest/$$" "/tmp/cto-allow-kill-$TID"

echo "== idle-marks: episode = steer count; DONE resets; stop cleans (helper white-box) =="
# White-box by SANCTION (cto-docs-contract allowlist, 2026-08-17): the helpers are pure file
# arithmetic; their CLI-black-box path needs an engine emulator answering get_state — negative
# leverage for a hint line. Live two-idle fire is e2e-tier. Only these two helpers may be
# consumed here; anything else from duplexctl is still the manifest gate's business.
sandbox_new
imk_py(){ AW_DIR="$AW_DIR" WATCH_RUN_DIR="$WATCH_RUN_DIR" python3 - "$1" <<'EOF'
import importlib.util, os, sys, types
spec = importlib.util.spec_from_file_location(
    "duplexctl", os.environ["AW_DIR"] + "/duplexctl.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sess = types.SimpleNamespace(run=os.environ["WATCH_RUN_DIR"], name="imk")
if sys.argv[1] == "count":
    print(m._idle_mark_and_count(sess))
else:
    m._idle_marks_reset(sess); print("ok")
EOF
}
chk_eq "first idle episode counts 1" 1 "$(imk_py count)"
chk_eq "re-poll of the same episode still 1" 1 "$(imk_py count)"
printf '{"ts":1,"offset":10}\n' >> "$WATCH_RUN_DIR/imk.duplex.sent-journal"
chk_eq "after a steer the next idle is episode 2" 2 "$(imk_py count)"
chk_eq "reset clears" "ok" "$(imk_py reset)"
chk_eq "post-DONE idle starts over at 1" 1 "$(imk_py count)"
# review repros (2026-08-17 B1) as standing assertions:
printf '\xff\n' >> "$WATCH_RUN_DIR/imk.duplex.sent-journal"   # undecodable journal byte
chk_eq "undecodable journal byte never crashes the counter" 2 "$(imk_py count)"
# read-only dir: reset's R-sentinel append still works on the existing writable file, and a
# fresh idle after that DONE reads 1 — a stale pre-reset mark must never fabricate episode 2
chmod 0555 "$WATCH_RUN_DIR"
chk_eq "reset survives an unlink-denied dir (sentinel append)" "ok" "$(imk_py reset)"
chk_eq "post-reset idle in read-only dir is episode 1 again" 1 "$(imk_py count)"
chmod 0755 "$WATCH_RUN_DIR"
# unpersistable marks (missing dir) → fail-closed to 1, never a memory-fabricated 2
IMGONE="$SANDBOX/gone-run"; WATCH_RUN_DIR_SAVE="$WATCH_RUN_DIR"
WATCH_RUN_DIR="$IMGONE"
chk_eq "unpersistable episode reads fail-closed 1" 1 "$(imk_py count)"
WATCH_RUN_DIR="$WATCH_RUN_DIR_SAVE"
# stop teardown removes the sidecar so a reclaimed session name cannot inherit stale marks
chk_contains "idle-marks is in the stop removal set" "duplex.idle-marks" "$(grep -A2 '_STOP_KEPT = ' "$AW_DIR/duplexctl.py")"
# hint carries the path-first guidance (review M2: prefix pin alone let the new half vanish)
chk_contains "idle hint keeps path-first guidance" "check the path first" "$(grep -B2 -A4 '2nd+ idle episode this session' "$AW_DIR/duplexctl.py")"

echo "== footer deliverable sentence: injected ONLY when a deliverable was declared =="
FGATE="$SANDBOX/fgate"; mkdir -p "$FGATE"
sed -n '/^append_footer()/,/^}/p' "$AGENTCTL" > "$FGATE/fn.sh"
printf ': > "$1"\nappend_footer "$1" "/abs/wt" "/abs/stamp.txt" "%s"\n' 'out-*.md' >> "$FGATE/fn.sh"
bash "$FGATE/fn.sh" "$FGATE/with.txt"
# generic sentence, no glob (R2: a start-time glob lies once `steer -d` moves the target)
chk_contains "with-deliverable footer states chat is not delivery" "chat output is not delivery" "$(cat "$FGATE/with.txt")"
chk_not_contains "footer never embeds the mutable glob" "out-*.md" "$(cat "$FGATE/with.txt")"
sed -n '/^append_footer()/,/^}/p' "$AGENTCTL" > "$FGATE/fn2.sh"
printf ': > "$1"\nappend_footer "$1" "/abs/wt" "/abs/stamp.txt" ""\n' >> "$FGATE/fn2.sh"
bash "$FGATE/fn2.sh" "$FGATE/without.txt"
chk_not_contains "no-deliverable footer carries NO false file contract" "deliverable file" "$(cat "$FGATE/without.txt")"
chk_contains "no-deliverable footer keeps the base second line" "further instructions may arrive" "$(cat "$FGATE/without.txt")"
# the hint text must live in the LIVE-idle verdict block (source pin; anchored BEFORE the
# verdict print where the hint is assembled)
chk_contains "hint wired on live-idle verdict" "2nd+ idle episode this session" "$(grep -B14 "IDLE-NO-DELIVERABLE: engine idle but" "$AW_DIR/duplexctl.py")"

summary
