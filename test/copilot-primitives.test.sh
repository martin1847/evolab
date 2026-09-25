#!/usr/bin/env bash
# Copilot primitives (B1, 2026-09-25): `tuictl interject` and `tuictl settings`.
#
# WHAT THESE VERBS ARE: the two ways to address a session agentctl did NOT start —
# the operator's own codex or claude TUI. There is no lane, no fifo and no meta behind them,
# so everything under test here is (a) which argv reaches the engine's own CLI, (b) what is
# read back out of the record that engine already writes, and (c) the typed line + exit code
# each outcome publishes.
#
# HERMETIC, and hermetic in a second sense than the rest of the suite: $HOME itself is
# redirected, because the whole addressing surface is `~/.codex/sessions`,
# `~/.claude/sessions` and `~/.claude/projects`. No engine runs — `codex` and `claude` are
# scripted stubs on the temp PATH that RECORD argv and replay one of a fixed set of
# outcomes. The stubs are FIXTURE MECHANISM, not gauges: argv that matches no preset exits
# 99 with `stub: unexpected argv`, which reds the case instead of passing silently.
#
# THE CONFIRM GAUGE (C14): `--confirm` is judged from a byte offset taken BEFORE delivery,
# so each arm below moves exactly one thing — what the stub appends after that offset.
#   positive : echo + a new turn      -> LANDED           rc 0
#   negative : echo, no new turn      -> UNMEASURED       rc 7
#   broken   : file vanishes / non-JSON line appended -> UNMEASURED  rc 7 (never LANDED)
#   boundary : a complete pairing that was already on disk BEFORE the offset -> UNMEASURED
# The settings gauge has no threshold, so its four arms are valid / stale-shape / unreadable
# / legally-absent-effort.
#
# Run the SAME file against a pinned older tree with COPILOT_AGENTCTL=<path>/agentctl to see
# which cases are entrypoint-missing and which are decision-mismatch (the red-before-green
# evidence in the findings doc).
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

[ -n "${COPILOT_AGENTCTL:-}" ] && AGENTCTL="$COPILOT_AGENTCTL"

THREAD="0199aa11-2222-4333-8444-555566667777"
MISSING_THREAD="0199bb22-3333-4444-8555-666677778888"
CLAUDE_SID="0199cc33-4444-4555-8666-777788889999"
CLAUDE_NAME="zz-copilot-t1"

ac() { bash "$AGENTCTL" "$@"; }
tc() { bash "$(dirname "$AGENTCTL")/tuictl" "$@"; }

# ---- fixture: a $HOME with the two engines' records in it ------------------------------------
copilot_setup() {
  sandbox_new
  export HOME="$SANDBOX/home"
  ROLLOUT="$HOME/.codex/sessions/2026/09/25/rollout-2026-09-25T10-00-00-$THREAD.jsonl"
  SOCK="$HOME/.codex/app-server-control/app-server-control.sock"
  TRANSCRIPT="$HOME/.claude/projects/-work/$CLAUDE_SID.jsonl"
  STUB_ARGV_LOG="$SANDBOX/argv.log"
  export ROLLOUT SOCK TRANSCRIPT STUB_ARGV_LOG
  export AGENTCTL_CONFIRM_TIMEOUT=2      # the confirm budget, fixture-sized
  mkdir -p "$(dirname "$ROLLOUT")" "$(dirname "$TRANSCRIPT")" "$HOME/.claude/sessions" "$HOME/work"
  : > "$STUB_ARGV_LOG"
  seed_rollout
  seed_claude
  install_stubs
}

copilot_teardown() {
  unset FAKE_CODEX_MODE FAKE_CODEX_APPEND FAKE_CLAUDE_MODE FAKE_CLAUDE_APPEND \
        AGENTCTL_CONFIRM_TIMEOUT ROLLOUT SOCK TRANSCRIPT STUB_ARGV_LOG 2>/dev/null || true
  export HOME="$REAL_HOME"
  sandbox_clean
}

seed_rollout() { # three turn_contexts; the LAST one is what `settings` must publish
  python3 - "$ROLLOUT" <<'PY'
import json, sys
def tc(tid, model, effort, mode, approval, sandbox):
    return {"type": "turn_context", "ordinal": 0, "payload": {
        "turn_id": tid, "model": model, "effort": effort,
        "collaboration_mode": {"mode": mode, "settings": {}},
        "approval_policy": approval, "sandbox_policy": {"type": sandbox}}}
rows = [
    {"type": "session_meta", "payload": {"id": "x"}},
    tc("t1", "gpt-6-luna", "low", "default", "never", "read-only"),
    {"type": "event_msg", "payload": {"type": "user_message", "message": "first turn"}},
    tc("t2", "gpt-6-luna", "low", "default", "never", "read-only"),
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                          "content": [{"type": "output_text", "text": "ok"}]}},
    tc("t3", "gpt-6-luna", "medium", "plan", "on-request", "workspace-write"),
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

seed_claude() { # the live-session registry entry + a transcript whose last turn is haiku
  python3 - "$HOME" "$CLAUDE_SID" "$CLAUDE_NAME" "$TRANSCRIPT" <<'PY'
import json, os, sys
home, sid, name, transcript = sys.argv[1:5]
with open(os.path.join(home, ".claude", "sessions", "4242.json"), "w", encoding="utf-8") as fh:
    json.dump({"name": name, "sessionId": sid, "cwd": os.path.join(home, "work"),
               "status": "shell", "messagingSocketPath": "/tmp/zz.sock"}, fh)
rows = [
    {"type": "permission-mode", "permissionMode": "auto", "sessionId": sid},
    {"type": "user", "message": {"role": "user", "content": "hi"}},
    # haiku records no effort: a LEGAL absence, which must still publish a reading
    {"type": "assistant", "effort": None, "uuid": "u1",
     "message": {"id": "msg_h1", "model": "claude-haiku-4"}},
]
with open(transcript, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

install_stubs() {
  cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
bad() { echo "stub: unexpected argv" >&2; exit 99; }
[ "${1:-}" = queue ] || bad
shift
msg=""; thread=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --thread)  thread="${2:-}"; shift 2 ;;
    --message) msg="${2:-}"; shift 2 ;;
    --remote)  shift 2 ;;
    *) bad ;;
  esac
done
[ -n "$msg" ] && [ -n "$thread" ] || bad
case "${FAKE_CODEX_MODE:-ok}" in
  norollout) echo "no rollout found for thread $thread" >&2; exit 1 ;;
  daemon)    echo "cannot queue through an embedded app server while a local app-server daemon is running" >&2; exit 1 ;;
esac
python3 - "$ROLLOUT" "$msg" "${FAKE_CODEX_APPEND:-none}" <<'PY'
import json, os, sys
path, msg, mode = sys.argv[1:4]
if mode == "vanish":
    os.remove(path)
    raise SystemExit(0)
# `live` replays the REAL codex append order observed 2026-09-25 on a scratch TUI attached to
# the app-server daemon: task_started + turn_context land BEFORE the user row carrying the
# queued text. `full` keeps the other order. Both must read as LANDED — that is the whole
# point of judging the WINDOW rather than the sequence.
with open(path, "a", encoding="utf-8") as fh:
    if mode == "live":
        fh.write(json.dumps({"type": "event_msg", "payload": {
            "type": "task_started", "turn_id": "t-live"}}) + "\n")
        fh.write(json.dumps({"type": "turn_context", "payload": {
            "turn_id": "t-live", "model": "gpt-6-luna", "effort": "low",
            "collaboration_mode": {"mode": "default"}}}) + "\n")
    if mode in ("echo", "full", "live"):
        fh.write(json.dumps({"type": "response_item", "payload": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": msg}]}}) + "\n")
    if mode == "full":
        fh.write(json.dumps({"type": "turn_context", "payload": {
            "turn_id": "t9", "model": "gpt-6-luna", "effort": "low",
            "collaboration_mode": {"mode": "default"}}}) + "\n")
    if mode == "garbage":
        fh.write("this line is not json\n")
PY
echo "queued msg_fake_1"
EOF
  cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
bad() { echo "stub: unexpected argv" >&2; exit 99; }
[ "${1:-}" = "-p" ] || bad
prompt="${2:-}"
case "$*" in
  *"--name copilot-"*) ;;
  *) bad ;;
esac
case "$*" in
  *"--model haiku"*) ;;
  *) bad ;;
esac
case "$*" in
  *"--allowedTools SendMessage"*) ;;
  *) bad ;;
esac
if [ "${FAKE_CLAUDE_MODE:-ok}" = fail ]; then
  echo "SendMessage: no session named that is accepting messages" >&2; exit 1
fi
python3 - "$TRANSCRIPT" "$prompt" "${FAKE_CLAUDE_APPEND:-none}" <<'PY'
import json, sys
path, prompt, mode = sys.argv[1:4]
body = next((l for l in prompt.splitlines() if l.startswith("[")), None)
if body is None:
    sys.stderr.write("stub: unexpected argv (no tagged body in the relay prompt)\n")
    raise SystemExit(99)
with open(path, "a", encoding="utf-8") as fh:
    if mode in ("echo", "full"):
        fh.write(json.dumps({"type": "user", "turnOrigin": "peer",
                             "origin": {"kind": "peer", "name": "copilot-copilot"},
                             "message": {"role": "user", "content": body}}) + "\n")
    if mode == "full":
        fh.write(json.dumps({"type": "assistant", "effort": "low", "uuid": "u9",
                             "message": {"id": "msg_h9", "model": "claude-haiku-4"}}) + "\n")
PY
echo "sent"
EOF
  chmod +x "$BIN/codex" "$BIN/claude"
}

argv_count() { grep -c . "$STUB_ARGV_LOG"; }
REAL_HOME="$HOME"

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== entrypoints: lane and live TUI contracts stay separate =="
out="$(tc --help 2>&1)"; rc=$?
chk_eq "tuictl help succeeds" 0 "$rc"
chk_eq "tuictl help has exactly two forms" 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
out="$(ac steer -m hi zz-none 2>&1)"; rc=$?
chk_eq "a leading steer flag stays on the lane's usage path" 1 "$rc"
chk_contains "the lane's own steer form is visible" "agentctl steer <session>" "$out"
out="$(ac steer --help 2>&1)"; rc=$?
chk_eq "the lane's steer help succeeds" 0 "$rc"
chk_contains "the lane's interrupt option is visible" "--interrupt" "$out"
out="$(ac settings --thread x 2>&1)"; rc=$?
chk_eq "lane settings rejects a live TUI address" 2 "$rc"
chk_eq "lane settings gives the live TUI entrypoint" \
  "ERR: agentctl settings takes <session>; live TUI threads: tuictl settings --help" "$out"

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== A: the A/B route is ONE predicate — does the daemon control socket exist =="
copilot_setup
out="$(tc interject --thread "$THREAD" -m "no daemon here" 2>&1)"; rc=$?
chk_eq "A no socket: the verb delivers and types the boundary" 15 "$rc"
chk_contains "A no socket: typed line names the queue route" \
  "DELIVERED-NEXT-TURN: reason=queue" "$out"
chk_contains "A no socket: and carries the thread it addressed" "thread=$THREAD" "$out"
chk_contains "A no socket: and the id the engine handed back" "id=msg_fake_1" "$out"
chk_not_contains "A DAMAGE ORACLE: embedded delivery must not claim a remote" \
  "--remote" "$(cat "$STUB_ARGV_LOG")"
chk_contains "A the engine's own CLI was invoked with the thread" \
  "--thread $THREAD" "$(cat "$STUB_ARGV_LOG")"
chk_contains "A the tag prefix is at the HEAD of the body, not appended" \
  "--message [copilot] no daemon here" "$(cat "$STUB_ARGV_LOG")"

: > "$STUB_ARGV_LOG"
mkdir -p "$(dirname "$SOCK")"; : > "$SOCK"
out="$(tc interject --thread "$THREAD" -m "daemon is up" 2>&1)"; rc=$?
chk_eq "A socket present: still one delivery, same typed class" 15 "$rc"
chk_contains "A socket present: the remote endpoint is on the argv" \
  "--remote unix://$SOCK" "$(cat "$STUB_ARGV_LOG")"
chk_eq "A PAIRED: exactly one engine invocation either way (no retry, no second route)" \
  1 "$(argv_count)"
# a custom tag replaces the default, head of body, nothing else
: > "$STUB_ARGV_LOG"; rm -f "$SOCK"
tc interject --thread "$THREAD" -m "tagged" --tag montior >/dev/null 2>&1
chk_contains "A --tag is the prefix the operator sees arrive" \
  "--message [montior] tagged" "$(cat "$STUB_ARGV_LOG")"
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== B: an engine refusal is REPORTED verbatim — never interpreted, never retried =="
copilot_setup
export FAKE_CODEX_MODE=daemon
out="$(tc interject --thread "$THREAD" -m "who owns this thread" 2>&1)"; rc=$?
chk_eq "B DAMAGE ORACLE: a refused delivery fails (EXIT_FAILED), never DELIVERED" 2 "$rc"
chk_eq "B exactly one ERR line, no commentary around it" 1 \
  "$(printf '%s\n' "$out" | grep -c '^ERR:')"
chk_contains "B the ERR names the command and its rc" "codex queue rc=1:" "$out"
chk_contains "B and carries the engine's own first stderr line" \
  "cannot queue through an embedded app server" "$out"
chk_not_contains "B DAMAGE ORACLE: the lane does not diagnose WHY (that is B3's question)" \
  "plain TUI" "$out"
chk_eq "B DAMAGE ORACLE: one invocation — a refusal is not retried on another route" \
  1 "$(argv_count)"
unset FAKE_CODEX_MODE
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C: addressing refusals — a thread we cannot name is never guessed at =="
copilot_setup
out="$(tc interject --thread "$MISSING_THREAD" -m "nobody home" 2>&1)"; rc=$?
chk_eq "C a uuid with no rollout is refused before any engine call" 2 "$rc"
chk_contains "C and the refusal says what to do about it" \
  "thread has no rollout yet (send one turn in the TUI first)" "$out"
chk_eq "C DAMAGE ORACLE: nothing was sent" 0 "$(argv_count)"
out="$(tc interject --thread "not-a-uuid" -m "x" 2>&1)"; rc=$?
chk_eq "C a non-uuid codex thread is refused (the rollout is addressed by uuid)" 2 "$rc"
chk_contains "C and says which spelling it needs" "full thread uuid" "$out"
# claude: EXACT match only, and several matches is a refusal listing candidates
python3 - "$HOME" "$CLAUDE_NAME" <<'PY'
import json, os, sys
home, name = sys.argv[1:3]
with open(os.path.join(home, ".claude", "sessions", "4343.json"), "w", encoding="utf-8") as fh:
    json.dump({"name": name, "sessionId": "0199dd44-5555-4666-8777-888899990000",
               "cwd": os.path.join(home, "work"), "status": "shell"}, fh)
PY
out="$(tc interject --thread "$CLAUDE_NAME" --engine claude -m "which one" 2>&1)"; rc=$?
chk_eq "C two live claude sessions with one name: refused, not guessed" 2 "$rc"
chk_contains "C and both candidates are named" "$CLAUDE_SID" "$out"
chk_contains "C including the second" "0199dd44-5555-4666-8777-888899990000" "$out"
chk_eq "C DAMAGE ORACLE: an ambiguous target receives nothing" 0 "$(argv_count)"
# UNIQUE BY UUID, AMBIGUOUS AT THE HOP (review r1 M1): the sessionId selects exactly one
# record, but the relay channel addresses by NAME — so a name two live sessions share would
# deliver the ruling to whichever of them wins that name, while the typed line claimed the
# uuid the operator picked. Fail closed instead: refuse, send nothing.
for uuid in "$CLAUDE_SID" "0199dd44-5555-4666-8777-888899990000"; do
  out="$(tc interject --thread "$uuid" --engine claude -m "by uuid" 2>&1)"; rc=$?
  chk_eq "C a uuid whose name is shared is refused, not silently renamed ($uuid)" 2 "$rc"
  chk_contains "C and the refusal names the ambiguity ($uuid)" \
    "relay target ambiguous: name $CLAUDE_NAME shared by 2 sessions" "$out"
done
chk_eq "C DAMAGE ORACLE: neither uuid delivered anything" 0 "$(argv_count)"
# a record with no name at all cannot be addressed either
python3 - "$HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
with open(os.path.join(home, ".claude", "sessions", "4444.json"), "w", encoding="utf-8") as fh:
    json.dump({"sessionId": "0199ee55-6666-4777-8888-999900001111",
               "cwd": os.path.join(home, "work"), "status": "shell"}, fh)
PY
out="$(tc interject --thread "0199ee55-6666-4777-8888-999900001111" --engine claude -m "no name" 2>&1)"
rc=$?
chk_eq "C a nameless live session is refused (the relay has no way to address it)" 2 "$rc"
chk_contains "C and says why" "has no name" "$out"
rm -f "$HOME/.claude/sessions/4444.json"
rm -f "$HOME/.claude/sessions/4343.json"
out="$(tc interject --thread "zz-copilot" --engine claude -m "prefix only" 2>&1)"; rc=$?
chk_eq "C a PREFIX of a live session name is not a match" 2 "$rc"
chk_contains "C and the refusal points at the registry" "~/.claude/sessions" "$out"
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== D: claude delivery is a throwaway relay seat over the peer channel =="
copilot_setup
out="$(tc interject --thread "$CLAUDE_NAME" --engine claude -m "reply PONG" 2>&1)"; rc=$?
chk_eq "D the relay delivered and typed the boundary" 15 "$rc"
chk_contains "D the typed line names the peer route" "DELIVERED-NEXT-TURN: reason=peer" "$out"
chk_contains "D the id IS the relay name the target will attribute it to" \
  "id=copilot-copilot" "$out"
argv="$(cat "$STUB_ARGV_LOG")"
chk_contains "D the relay is a named session" "--name copilot-copilot" "$argv"
chk_contains "D on the cheap model" "--model haiku" "$argv"
chk_contains "D bounded to three turns" "--max-turns 3" "$argv"
chk_contains "D with only the messaging tools" "--allowedTools SendMessage ListAgents" "$argv"
chk_contains "D and the target named in the prompt" "$CLAUDE_NAME" "$argv"
chk_contains "D the body reaches the relay tagged" "[copilot] reply PONG" "$argv"
# sessionId addresses the same session as the name
: > "$STUB_ARGV_LOG"
out="$(tc interject --thread "$CLAUDE_SID" --engine claude -m "by id" 2>&1)"; rc=$?
chk_eq "D a sessionId addresses the same seat" 15 "$rc"
export FAKE_CLAUDE_MODE=fail
out="$(tc interject --thread "$CLAUDE_NAME" --engine claude -m "held" 2>&1)"; rc=$?
chk_eq "D a relay that fails is reported, not swallowed" 2 "$rc"
chk_contains "D with the relay's own first line" "no session named that is accepting" "$out"
unset FAKE_CLAUDE_MODE
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== E: the --confirm gauge, four arms (C14) =="
copilot_setup
export FAKE_CODEX_APPEND=full
out="$(tc interject --thread "$THREAD" -m "confirm me" --confirm 2>&1)"; rc=$?
chk_eq "E POSITIVE: echo + a new turn after the offset is LANDED (rc 0)" 0 "$rc"
chk_contains "E POSITIVE: the boundary line is still published first" \
  "DELIVERED-NEXT-TURN" "$out"
chk_contains "E POSITIVE: LANDED carries the turn it opened" "LANDED: turn=t9" "$out"
chk_contains "E POSITIVE: and the settings that turn runs under" "effort=low mode=default" "$out"
# THE REGRESSION the live probe bought (2026-09-25): the engine opens the turn BEFORE it
# records the queued text. An order-sensitive reader called this exact landing UNMEASURED
# while the TUI was visibly answering it.
export FAKE_CODEX_APPEND=live
out="$(tc interject --thread "$THREAD" -m "live order" --confirm 2>&1)"; rc=$?
chk_eq "E POSITIVE (live order): turn_context BEFORE the echo is still LANDED" 0 "$rc"
chk_contains "E POSITIVE (live order): and names that turn" "LANDED: turn=t-live" "$out"

export FAKE_CODEX_APPEND=echo
out="$(tc interject --thread "$THREAD" -m "no turn follows" --confirm 2>&1)"; rc=$?
chk_eq "E NEGATIVE: the text arrived but no turn opened — UNMEASURED (rc 7)" 7 "$rc"
chk_contains "E NEGATIVE: and it says WHICH half was not seen" \
  "the message is in the record but no new turn opened with it" "$out"
chk_not_contains "E NEGATIVE: never LANDED" "LANDED" "$out"

export FAKE_CODEX_APPEND=garbage
out="$(tc interject --thread "$THREAD" -m "damaged record" --confirm 2>&1)"; rc=$?
chk_eq "E BROKEN GAUGE: a non-JSON line appended is UNMEASURED, never LANDED" 7 "$rc"
chk_contains "E BROKEN GAUGE: and names the file it could not read" "cannot read" "$out"
export FAKE_CODEX_APPEND=vanish
out="$(tc interject --thread "$THREAD" -m "record gone" --confirm 2>&1)"; rc=$?
chk_eq "E BROKEN GAUGE: the record vanishing mid-poll is UNMEASURED too" 7 "$rc"
chk_contains "E BROKEN GAUGE: and says so" "cannot read" "$out"

# BOUNDARY: a COMPLETE pairing already on disk before the offset proves nothing
copilot_teardown
copilot_setup
python3 - "$ROLLOUT" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "event_msg", "payload": {
        "type": "user_message", "message": "[copilot] old news"}}) + "\n")
    fh.write(json.dumps({"type": "turn_context", "payload": {
        "turn_id": "t-old", "model": "gpt-6-luna", "effort": "low",
        "collaboration_mode": {"mode": "default"}}}) + "\n")
PY
export FAKE_CODEX_APPEND=none
out="$(tc interject --thread "$THREAD" -m "old news" --confirm 2>&1)"; rc=$?
chk_eq "E BOUNDARY: a pairing from BEFORE the offset is not this delivery's evidence" 7 "$rc"
chk_contains "E BOUNDARY: the verdict is the absence, not the stale pair" \
  "the message never reached the record" "$out"
chk_not_contains "E BOUNDARY: and certainly not LANDED" "LANDED" "$out"

# DEADLINE BOUNDARY (C14, review r1 B1): the window closes at the deadline in BOTH
# directions. Evidence that lands after it must not be consumed, and the clock must be read
# BEFORE the record — a reader that reads first and checks the time last publishes a LANDED
# whose truth depends on how far the last sleep overslept.
# (b1) the exhausted-budget arm: a COMPLETE, in-window pairing is on disk and the budget is
# already spent. This is the arm that discriminates — the pre-fix loop read once before it
# ever looked at the clock, and answered LANDED / 0.
export FAKE_CODEX_APPEND=full AGENTCTL_CONFIRM_TIMEOUT=0
out="$(tc interject --thread "$THREAD" -m "budget already spent" --confirm 2>&1)"; rc=$?
chk_eq "E DEADLINE: an exhausted budget consumes no evidence at all (rc 7)" 7 "$rc"
chk_not_contains "E DEADLINE: and never publishes LANDED" "LANDED" "$out"
chk_contains "E DEADLINE: the boundary line is still published" "DELIVERED-NEXT-TURN" "$out"
# (b2) the late-append arm in its realistic shape: budget 1s, the pairing is appended by a
# writer 1.5s later — i.e. after the window closed — and must never read as LANDED.
unset FAKE_CODEX_APPEND
export AGENTCTL_CONFIRM_TIMEOUT=1
( /bin/sleep 1.5; python3 - "$ROLLOUT" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "turn_context", "payload": {
        "turn_id": "t-late", "model": "gpt-6-luna", "effort": "low",
        "collaboration_mode": {"mode": "default"}}}) + "\n")
    fh.write(json.dumps({"type": "event_msg", "payload": {
        "type": "user_message", "message": "[copilot] late pair"}}) + "\n")
PY
) &
late_writer=$!
out="$(tc interject --thread "$THREAD" -m "late pair" --confirm 2>&1)"; rc=$?
chk_eq "E DEADLINE: a pairing appended after the window is not this run's answer" 7 "$rc"
chk_not_contains "E DEADLINE: no late LANDED" "LANDED: turn=t-late" "$out"
wait "$late_writer" 2>/dev/null
export AGENTCTL_CONFIRM_TIMEOUT=2
unset FAKE_CODEX_APPEND
# PAIRED GREEN on the claude side: the same gauge over a transcript
export FAKE_CLAUDE_APPEND=full
out="$(tc interject --thread "$CLAUDE_NAME" --engine claude -m "reply PONG" --confirm 2>&1)"; rc=$?
chk_eq "E claude POSITIVE: peer message + an assistant line is LANDED" 0 "$rc"
chk_contains "E claude POSITIVE: the assistant turn is named" "LANDED: turn=msg_h9" "$out"
export FAKE_CLAUDE_APPEND=echo
out="$(tc interject --thread "$CLAUDE_NAME" --engine claude -m "silent target" --confirm 2>&1)"; rc=$?
chk_eq "E claude NEGATIVE: delivered but the seat never spoke — UNMEASURED" 7 "$rc"
unset FAKE_CLAUDE_APPEND
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== F: settings is a READING of the engine's own record, four arms (C14) =="
copilot_setup
out="$(tc settings --thread "$THREAD" --engine codex 2>&1)"; rc=$?
chk_eq "F VALID: a codex thread with turn_context rows reads (rc 0)" 0 "$rc"
chk_eq "F VALID: exactly one line, and it is the reading" 1 \
  "$(printf '%s\n' "$out" | grep -c '^SETTINGS:')"
chk_contains "F VALID: the LAST turn_context is the answer, not the first" \
  "model=gpt-6-luna effort=medium mode=plan approval=on-request sandbox=workspace-write" "$out"
chk_contains "F VALID: and the source is named by ordinal" "source=turn_context@3" "$out"

out="$(tc settings --thread "$CLAUDE_NAME" --engine claude 2>&1)"; rc=$?
chk_eq "F VALID: a claude transcript reads too" 0 "$rc"
chk_contains "F BOUNDARY: a legally absent effort still publishes a reading" \
  "model=claude-haiku-4 effort=n/a mode=auto" "$out"
chk_contains "F VALID: approval/sandbox are not claude's to publish" \
  "approval=n/a sandbox=n/a" "$out"
chk_contains "F VALID: the source is the transcript line" "source=transcript@3" "$out"

# STALE SHAPE: the last assistant line carries no model, an EARLIER one does
python3 - "$TRANSCRIPT" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "assistant", "effort": "low", "uuid": "u2",
                         "message": {"id": "msg_h2"}}) + "\n")
PY
out="$(tc settings --thread "$CLAUDE_NAME" --engine claude 2>&1)"; rc=$?
chk_eq "F STALE: the last line has no model — UNMEASURED, rc 7" 7 "$rc"
chk_contains "F STALE: and says which line it judged" "carries no message.model" "$out"
chk_not_contains "F DAMAGE ORACLE: an earlier line's model is NOT borrowed" \
  "claude-haiku-4" "$out"

# BROKEN GAUGE: the record is gone. A GAUGE with nothing to read publishes UNMEASURED — the
# ERR / 2 for this condition belongs to `interject`, which cannot deliver into a thread the
# engine never wrote (review r1 M2; the two contracts are asserted separately, §C above).
rm -f "$ROLLOUT"
out="$(tc settings --thread "$THREAD" --engine codex 2>&1)"; rc=$?
chk_eq "F BROKEN GAUGE: a missing record is an UNMEASURED reading, not a refusal" 7 "$rc"
chk_contains "F BROKEN GAUGE: and names the thread it found nothing for" \
  "no rollout for thread $THREAD" "$out"
chk_not_contains "F BROKEN GAUGE: and publishes no reading" "SETTINGS:" "$out"
chk_not_contains "F DAMAGE ORACLE: interject's delivery refusal is NOT reused here" \
  "send one turn in the TUI first" "$out"
# PAIRED: the same missing rollout is still ERR / 2 for a DELIVERY
out2="$(tc interject --thread "$THREAD" -m "cannot deliver" 2>&1)"; rc2=$?
chk_eq "F PAIRED: interject on the same missing rollout stays a refusal" 2 "$rc2"
chk_contains "F PAIRED: with its own wording" "thread has no rollout yet" "$out2"
seed_rollout
printf 'not json at all\n' >> "$ROLLOUT"
out="$(tc settings --thread "$THREAD" --engine codex 2>&1)"; rc=$?
chk_eq "F BROKEN GAUGE: a damaged record reads UNMEASURED, never a stale answer" 7 "$rc"
chk_contains "F BROKEN GAUGE: and says it could not read the file" "cannot read" "$out"
chk_not_contains "F BROKEN GAUGE: no SETTINGS line is published from damage" "SETTINGS:" "$out"

# the two spellings are mutually exclusive, and each is refused on its own terms
out="$(ac settings 2>&1)"; rc=$?
chk_eq "F neither spelling given: refused" 2 "$rc"
chk_contains "F and the refusal teaches both" "EITHER <session> OR --thread" "$out"
out="$(ac settings "$THREAD" --thread "$THREAD" --engine codex 2>&1)"; rc=$?
chk_eq "F both spellings given: refused" 2 "$rc"
out="$(tc settings --thread "$THREAD" 2>&1)"; rc=$?
chk_eq "F a thread without its engine: refused" 2 "$rc"
chk_contains "F and says which flag is missing" "--thread needs --engine" "$out"
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== G: a seat THIS runtime owns reads the same record, addressed through its meta =="
copilot_setup
printf 'engine=codex\ncwd=%s\nthread=%s\n' "$HOME/work" "$THREAD" \
  > "$WATCH_RUN_DIR/own-cx.duplex.meta"
out="$(ac settings own-cx 2>&1)"; rc=$?
chk_eq "G a codex seat resolves its thread from meta" 0 "$rc"
chk_contains "G and reads the same rollout" "source=turn_context@3" "$out"
printf 'engine=claude\ncwd=%s\n' "$HOME/work" > "$WATCH_RUN_DIR/own-cl.duplex.meta"
printf '{"type":"system","subtype":"init","session_id":"%s"}\n' "$CLAUDE_SID" \
  > "$WATCH_RUN_DIR/own-cl.duplex.events.jsonl"
out="$(ac settings own-cl 2>&1)"; rc=$?
chk_eq "G a claude seat resolves its transcript from the id on its own stream" 0 "$rc"
chk_contains "G and reads that transcript" "model=claude-haiku-4" "$out"
printf 'engine=omp\ncwd=%s\n' "$HOME/work" > "$WATCH_RUN_DIR/own-omp.duplex.meta"
out="$(ac settings own-omp 2>&1)"; rc=$?
chk_eq "G omp publishes no such record, and the refusal says so" 2 "$rc"
chk_contains "G pointing at the contract that publishes it" "settingsRead" "$out"
out="$(ac settings nosuchseat 2>&1)"; rc=$?
chk_eq "G an unknown session is refused" 1 "$rc"
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== H: the capability contract publishes all three keys, with the batch's real values =="
copilot_setup
doc="$(ac capabilities --json)"
chk_eq "H the three keys exist on every provider" \
  "claude:interject,settingsRead,settingsWrite codex:interject,settingsRead,settingsWrite omp:interject,settingsRead,settingsWrite" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
d = json.load(sys.stdin)["providers"]
print(" ".join(p + ":" + ",".join(sorted(k for k in c
      if k in ("interject", "settingsRead", "settingsWrite"))) for p in sorted(d)
      for c in [d[p]]))')"
states="$(printf '%s' "$doc" | python3 -c '
import json, sys
d = json.load(sys.stdin)["providers"]
print(" ".join(f"{p}.{k}={d[p][k]['"'"'state'"'"']}" for p in sorted(d)
      for k in ("interject", "settingsRead", "settingsWrite")))')"
chk_eq "H the values are this batch's truth, not a placeholder" \
  "claude.interject=supported claude.settingsRead=supported claude.settingsWrite=unsupported codex.interject=supported codex.settingsRead=supported codex.settingsWrite=supported omp.interject=unsupported omp.settingsRead=unsupported omp.settingsWrite=unsupported" \
  "$states"
chk_eq "H the schema version is unchanged: these are ADDED keys, not a reshape" "2" \
  "$(printf '%s' "$doc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["schemaVersion"])')"
chk_contains "H every settingsWrite refusal points at the batch that adds it" "B2" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
d = json.load(sys.stdin)["providers"]
print(" ".join(d[p]["settingsWrite"].get("note", "") for p in sorted(d)))')"
chk_contains "H the human table carries the same rows" "interject" "$(ac capabilities)"
copilot_teardown

echo "== J: codex daemon settings write routes through a single script =="
TMPDIR=/tmp copilot_setup
mkdir -p "$(dirname "$SOCK")"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$SOCK"
cat > "$BIN/uv" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = run ] || exit 99
[ "${2:-}" = --quiet ] || exit 99
printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
if [ "${FAKE_DAEMON_FAIL:-0}" = 1 ]; then
  echo 'daemon stub failure' >&2; exit 1
fi
echo '{"effort":"medium","mode":"plan","model":"gpt-6-sol","approval":"never","sandbox":{"type":"danger-full-access"}}'
EOF
chmod +x "$BIN/uv"
out="$(tc settings --thread "$THREAD" --engine codex --effort medium --mode plan 2>&1)"; rc=$?
# damage: a successful update must return one SETTINGS reading.
chk_eq "J daemon write success rc" 0 "$rc"
# damage: the stale rollout says gpt-6-luna; only the notification says gpt-6-sol.
chk_contains "J daemon write reads notification" "SETTINGS: model=gpt-6-sol effort=medium mode=plan approval=never sandbox=danger-full-access source=thread/settings/updated" "$out"
export FAKE_DAEMON_FAIL=1
out="$(tc settings --thread "$THREAD" --engine codex --effort medium 2>&1)"; rc=$?
# damage: a failed daemon update must not be reported as a successful reading.
chk_eq "J daemon failure rc" 2 "$rc"
# damage: hiding the daemon's error would make the refused update unactionable.
chk_contains "J daemon error detail" "ERR: codex daemon rc=1: daemon stub failure" "$out"
unset FAKE_DAEMON_FAIL
: > "$STUB_ARGV_LOG"
out="$(tc settings --thread "$THREAD" --engine codex --mode plan 2>&1)"; rc=$?
# damage: stale rollout values must not be forwarded as overrides for a mode-only write.
chk_eq "J mode-only forwards no stale model/effort" 1 "$(python3 -c 'import sys; s=open(sys.argv[1]).read(); print(int("--mode plan" in s and "--effort" not in s and "--model" not in s))' "$STUB_ARGV_LOG")"
rm -f "$SOCK"
out="$(tc settings --thread "$THREAD" --engine codex --effort medium 2>&1)"; rc=$?
# damage: without a daemon socket, a write must refuse before invoking the script.
chk_eq "J missing socket" "7:UNSUPPORTED: no daemon socket" "$rc:${out%% —*}"
out="$(tc settings --thread "$CLAUDE_NAME" --engine claude --effort medium 2>&1)"; rc=$?
# damage: a claude thread must never be sent to the codex daemon path.
chk_eq "J claude write refusal" "7:UNSUPPORTED: settings write is only for codex daemon threads" "$rc:$out"
copilot_teardown

# ─────────────────────────────────────────────────────────────────────────────────────────

summary
