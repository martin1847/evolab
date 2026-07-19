#!/usr/bin/env bash
# agentctl duplex lane — frame shapes, typed projection, lane routing, and the
# 2026-07-19 field-report regressions (relative deliverable glob / bounded watch
# tail / dispatch verb whitelist / guard motive wording).
#
# Harness: a PROCESS-RUNNING fake tmux (unlike lib-testkit's captured-command fake):
# new-session actually runs the pane command in the background, has-session reflects
# wrapper liveness, kill-session kills wrapper+engine. That exercises the REAL
# fifo/flock/events pipeline end to end with scriptable fake engines — no real tmux,
# no real engines, no tokens.
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
printf 'investigate the thing\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
export FAKE_PROVIDER_LOG="$SANDBOX/omp.log"
out="$(bash "$AGENTCTL" start omp dxA "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "omp start rc0" 0 "$rc"
chk_contains "omp start announces duplex" "duplex session 'dxA'" "$out"
chk_contains "omp ready handshake observed" "ready: omp rpc handshake" "$out"
chk_contains "prompt frame carries goal text" "investigate the thing" "$(cat "$SANDBOX/omp.log")"
chk_contains "prompt frame carries BLOCKED footer" "BLOCKED.md" "$(cat "$SANDBOX/omp.log")"
chk_eq "prompt frame is omp type=prompt" 1 "$(grep -c '"type":"prompt"' "$SANDBOX/omp.log")"

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
printf 'do the thing\n' > "$SANDBOX/goal.md"
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
printf 'do the codex thing\n' > "$SANDBOX/goal.md"
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

echo "== guard: TaskStop deny covers wrong-premise motive =="
TID="agdx$$"
TDIR="/tmp/claude-agdxtest/$$/x/tasks"; mkdir -p "$TDIR"; printf 'alive\n' > "$TDIR/$TID.output"
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"TaskStop","tool_input":{"task_id":"%s"}}' "$TID" \
      | python3 "$GUARD" 2>&1)"; rc=$?
chk_eq "fresh transcript → deny rc2" 2 "$rc"
chk_contains "deny names the wrong-premise motive" "premise is wrong" "$out"
chk_contains "deny keeps the doc pointer" "Read: cto-orchestration" "$out"
rm -rf "/tmp/claude-agdxtest/$$" "/tmp/cto-allow-kill-$TID"

summary
