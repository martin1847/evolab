#!/usr/bin/env bash
# cto-guard-stop.py (Stop) + seat-liveness.py (SessionStart|UserPromptSubmit) — ONE fact, two
# channels: a RUNNING agentctl seat of THIS repo with no live watcher. The Stop gate blocks the
# turn end over it; the prompt-time script reminds about it.
#
# Every case drives the REAL hook contract — a JSON payload on stdin, verdict read off stdout /
# stderr / exit code — never a python-level call into a helper.
#
# HOW `agentctl` IS SUBSTITUTED, and why it is not PATH surgery: both scripts resolve the binary
# as their OWN SIBLING (`os.path.dirname(os.path.abspath(__file__))/agentctl`), which is what
# makes an installed copy self-contained. So the fixture copies the two shipped scripts into a
# temp package dir and drops a fake `agentctl` next to them. The production resolution path is
# exercised verbatim; a PATH-prepended fake would never be consulted at all.
#
# The load-bearing cases, each pinned as a named assertion:
#   * FAIL-OPEN. A Stop gate's false positive costs every turn end in the session, so an
#     unlistable run dir / missing agentctl / unanswered `status` / unreadable payload / internal
#     failure must exit 0 with a WARN and NEVER exit 2 (on Stop, exit 2 blocks with stderr).
#   * `stop_hook_active` stands down — otherwise the gate re-blocks its own continuation.
#   * OWNERSHIP. The run dir is shared by every seat on the box; a seat whose meta cwd sits in
#     another checkout is not this gate's business.
#   * BOUNDED. 25 metas cost 20 status calls, and a status that hangs is abandoned before the
#     fake would have answered.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SRC="../skills/cto-orchestration/references/agentctl"

echo "== cto-guard-stop.py / seat-liveness.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — stop guard test skipped"; exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "    git not on PATH — stop guard test skipped"; exit 0
fi

chk_eq "the shipped Stop gate is executable" 1 \
  "$([ -x "$SRC/cto-guard-stop.py" ] && echo 1 || echo 0)"
chk_eq "the shipped liveness reminder is executable" 1 \
  "$([ -x "$SRC/seat-liveness.py" ] && echo 1 || echo 0)"

FIX="$(mktemp -d /tmp/ctostop.XXXXXX)"
PKG="$FIX/pkg"; RUN="$FIX/run"; FAKE="$FIX/fake"
mkdir -p "$PKG" "$RUN" "$FAKE"
trap 'rm -rf "$FIX"' EXIT
cp "$SRC/cto-guard-stop.py" "$SRC/seat-liveness.py" "$PKG/"
STOP="$PKG/cto-guard-stop.py"
NAG="$PKG/seat-liveness.py"

# The fake `agentctl`: `status <s>` prints the fixture for that session, sleeps first when told
# to, and records the call so the census cap can be counted.
cat > "$PKG/agentctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FAKE_DIR/calls"
[ -f "$FAKE_DIR/$2.sleep" ] && sleep 6
[ -f "$FAKE_DIR/$2.out" ] && cat "$FAKE_DIR/$2.out"
exit 0
EOF
chmod +x "$PKG/agentctl"
FAKE_DIR="$FAKE"; export FAKE_DIR

# This session's repo, and a second checkout that stands for another seat's work tree.
ORCH="$FIX/orch"; OTHER="$FIX/other"; NOGIT="$FIX/nogit"
mkdir -p "$ORCH" "$OTHER" "$NOGIT"
git -C "$ORCH" init -q
git -C "$OTHER" init -q

# `stale` = the real shape of an unwatched seat: the typed RUNNING line from classify plus the
# advisory note watchctl.py:cmd_status appends when the watcher pid is absent or dead.
seat() { # $1 session  $2 cwd  $3 stale|watched
  printf 'engine=omp\ncwd=%s\n' "$2" > "$RUN/$1.duplex.meta"
  if [ "$3" = stale ]; then
    printf 'RUNNING: idle but queued=0\nnote: no watcher armed — arm: agentctl watch %s (run_in_background)\n' \
      "$1" > "$FAKE/$1.out"
  else
    printf 'RUNNING: idle but queued=0\n' > "$FAKE/$1.out"
  fi
}
reset_seats() {
  rm -f "$RUN"/*.duplex.meta "$RUN/seat-liveness.nag" "$FAKE"/*.out "$FAKE"/*.sleep "$FAKE/calls"
  : > "$FAKE/calls"
}

stop_payload() { # $1 cwd ("-" omits the key)  $2 stop_hook_active(true/false)  [$3 event]
  python3 -c 'import json,sys
d = {"hook_event_name": sys.argv[3], "session_id": "abc", "transcript_path": "/tmp/t.jsonl",
     "stop_hook_active": sys.argv[2] == "true", "last_assistant_message": "done"}
if sys.argv[1] != "-":
    d["cwd"] = sys.argv[1]
print(json.dumps(d))' "$1" "$2" "${3:-Stop}"
}
nag_payload() { # $1 event  $2 cwd ("-" omits the key)
  python3 -c 'import json,sys
d = {"hook_event_name": sys.argv[1], "session_id": "abc", "prompt": "carry on"}
if sys.argv[2] != "-":
    d["cwd"] = sys.argv[2]
print(json.dumps(d))' "$1" "$2"
}
run_stop() { # $1 payload  [$2 run-dir override]
  local tmpe; tmpe="$(mktemp)"
  OUT="$(printf '%s' "$1" | AGENT_WATCH_DIR="${2:-$RUN}" python3 "$STOP" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
run_nag() { # $1 payload  [$2 run-dir override]  [$3 nag interval]
  local tmpe; tmpe="$(mktemp)"
  OUT="$(printf '%s' "$1" | AGENT_WATCH_DIR="${2:-$RUN}" \
        SEAT_LIVENESS_NAG_INTERVAL_SECS="${3:-600}" python3 "$NAG" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
field() { # $1 key  $2 stdout
  printf '%s' "$2" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get(sys.argv[1], "") if isinstance(d, dict) else "")' "$1"
}

# ── S1 THE BLOCK: an unwatched RUNNING seat of this repo stops the stop ────────────────────
reset_seats
seat s1 "$ORCH" stale
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 an unwatched RUNNING seat blocks the turn end (exit 0, never 2)" 0 "$RC"
chk_eq "S1 and never writes to stderr (exit-2 channel stays unused)" "" "$ERR"
chk_eq "S1 the verdict is decision=block" "block" "$(field decision "$OUT")"
S1_REASON="$(field reason "$OUT")"
chk_contains "S1 the reason names the seat it judged" "s1" "$S1_REASON"
chk_contains "S1 the reason is a DENY (电在回路 exit contract)" "DENY:" "$S1_REASON"
chk_contains "S1 the reason states the why (idle until a human asks)" "空转到有人来问" "$S1_REASON"
chk_contains "S1 the reason carries the 正路" 'agentctl watch <S>' "$S1_REASON"
chk_contains "S1 the 正路 includes the stand-down alternative" 'agentctl stop <S>' "$S1_REASON"
chk_contains "S1 the reason carries a doc pointer" \
  "Read: cto-orchestration/references/agentctl/README.md" "$S1_REASON"
chk_eq "S1 a real block carries no fail-open WARN" "" "$(field systemMessage "$OUT")"
chk_eq "S1 one status call per owned seat" "s1" "$(cat "$FAKE/calls")"

# ── S1 NEGATIVE CONTROLS: every one of these must be silent, not a softer block ────────────
reset_seats
seat s1 "$ORCH" watched
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 a seat WITH a live watcher lets the turn end" 0 "$RC"
chk_eq "S1 and says nothing at all" "" "$OUT$ERR"

# the loop fuse: the same fixture that blocked above must stand down mid-continuation
reset_seats
seat s1 "$ORCH" stale
run_stop "$(stop_payload "$ORCH" true)"
chk_eq "S1 stop_hook_active=true stands down (exit 0)" 0 "$RC"
chk_eq "S1 and emits nothing — a stop hook must not re-block its own continuation" "" "$OUT$ERR"
chk_eq "S1 and does not even census (no status call)" "" "$(cat "$FAKE/calls")"

# ownership: the run dir is shared, so another checkout's seat is none of this gate's business
reset_seats
seat s1 "$OTHER" stale
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 a seat in ANOTHER checkout does not block this repo's turn end" 0 "$RC"
chk_eq "S1 and is not even consulted (账内 ≠ 你的)" "" "$(cat "$FAKE/calls")$OUT$ERR"
# PAIRED GREEN, same session name and status fixture: only the meta cwd moved
seat s1 "$ORCH" stale
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 control: the same seat inside this repo DOES block" "block" "$(field decision "$OUT")"

reset_seats
seat s1 "$ORCH" stale
run_stop "$(stop_payload "$ORCH" false SubagentStop)"
chk_eq "S1 SubagentStop is not this gate's event" 0 "$RC"
chk_eq "S1 and it is silent" "" "$OUT$ERR"

reset_seats
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 an empty run dir lets the turn end silently" 0 "$RC"
chk_eq "S1 with no output" "" "$OUT$ERR"

# ── S1 FAIL-OPEN: judged blind means ALLOW + one WARN, never a block and never exit 2 ──────
reset_seats
seat s1 "$ORCH" stale
run_stop "$(stop_payload "$ORCH" false)" "$FIX/no-such-run-dir"
chk_eq "S1 an unlistable run dir allows the turn end (exit 0)" 0 "$RC"
chk_eq "S1 and never lands on stderr" "" "$ERR"
chk_eq "S1 and never blocks" "" "$(field decision "$OUT")"
W="$(field systemMessage "$OUT")"
chk_contains "S1 the blindness is announced, not silent" "WARN (cto-guard S1)" "$W"
chk_contains "S1 the warn names what it could not read" "no-such-run-dir" "$W"
chk_contains "S1 the warn hands back the next action" 'agentctl watch <S>' "$W"

chmod -x "$PKG/agentctl"
run_stop "$(stop_payload "$ORCH" false)"
chmod +x "$PKG/agentctl"
chk_eq "S1 an unusable agentctl allows the turn end (exit 0)" 0 "$RC"
chk_eq "S1 and never blocks on it" "" "$(field decision "$OUT")"
chk_contains "S1 the missing instrument is announced" "is not executable" "$(field systemMessage "$OUT")"

# a status that hangs must be abandoned BEFORE the fake would have answered (6s), so the gate
# cannot become the thing that stalls a turn end
reset_seats
seat s1 "$ORCH" stale
: > "$FAKE/s1.sleep"
SECONDS=0
run_stop "$(stop_payload "$ORCH" false)"
EL=$SECONDS
rm -f "$FAKE/s1.sleep"
chk_eq "S1 a hung status allows the turn end (exit 0)" 0 "$RC"
chk_eq "S1 and never blocks on an unanswered census" "" "$(field decision "$OUT")"
chk_contains "S1 the unanswered status is announced" "never answered" "$(field systemMessage "$OUT")"
chk_eq "S1 the census is abandoned before the call would have returned (${EL}s < 6s)" 1 \
  "$([ "$EL" -lt 6 ] && echo 1 || echo 0)"

for bad in 'not json' '[1,2,3]' ''; do
  tmpe="$(mktemp)"
  out="$(printf '%s' "$bad" | AGENT_WATCH_DIR="$RUN" python3 "$STOP" 2>"$tmpe")"; rc=$?
  err="$(cat "$tmpe")"; rm -f "$tmpe"
  chk_eq "S1 an unreadable payload [$bad] allows the turn end (exit 0)" 0 "$rc"
  chk_eq "S1 [$bad] never reaches stderr (which on Stop IS the block reason)" "" "$err"
  chk_eq "S1 [$bad] never blocks" "" "$(field decision "$out")"
  chk_contains "S1 [$bad] is announced as unjudged" "WARN (cto-guard S1)" "$(field systemMessage "$out")"
done

# an internal failure must not collapse into a block either — targeted mutation, os.listdir only
reset_seats
seat s1 "$ORCH" stale
tmpe="$(mktemp)"
out="$(printf '%s' "$(stop_payload "$ORCH" false)" | AGENT_WATCH_DIR="$RUN" python3 -c 'import os,runpy,sys
os.listdir = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
runpy.run_path(sys.argv[1], run_name="__main__")' "$STOP" 2>"$tmpe")"; rc=$?
err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "S1 an internal failure allows the turn end (exit 0)" 0 "$rc"
chk_eq "S1 and never blocks" "" "$(field decision "$out")"
chk_contains "S1 the internal failure is announced" "failed internally" "$(field systemMessage "$out")"

# ── S1 UNDECIDABLE OWNERSHIP: report unfiltered and SAY the filter never ran ────────────────
reset_seats
seat s1 "$OTHER" stale
run_stop "$(stop_payload "$NOGIT" false)"
chk_eq "S1 a cwd outside any work tree still judges liveness" "block" "$(field decision "$OUT")"
chk_contains "S1 and marks the unanswered ownership question" "UNKNOWN-ownership" "$(field reason "$OUT")"
run_stop "$(stop_payload - false)"
chk_eq "S1 a payload with no cwd judges unfiltered too" "block" "$(field decision "$OUT")"
chk_contains "S1 and marks it the same way" "UNKNOWN-ownership" "$(field reason "$OUT")"

# ── S1 BOUNDED CENSUS: 25 metas cost 20 status calls and the remainder is declared ──────────
reset_seats
for i in $(seq -f '%02g' 1 25); do seat "s$i" "$ORCH" stale; done
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 25 metas are censused at the 20-seat cap" 20 "$(grep -c . "$FAKE/calls")"
R="$(field reason "$OUT")"
chk_contains "S1 the unchecked remainder is declared, not swallowed" "+5 seat(s) past the census cap" "$R"
chk_contains "S1 the first alphabetical seat is judged" "s01" "$R"
chk_not_contains "S1 the 21st meta was never consulted" "s21" "$R"

# ── L1 THE REMINDER: same census, plain-text channel, silent when there is nothing to say ──
reset_seats
seat s1 "$ORCH" stale
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_eq "L1 an unwatched seat is reported at prompt time (exit 0)" 0 "$RC"
chk_eq "L1 and nothing goes to stderr" "" "$ERR"
chk_contains "L1 the line names the seat and the fix" \
  "RUNNING seats without a live watcher: s1" "$OUT"
chk_contains "L1 the line hands back the two actions" 'agentctl watch <S>' "$OUT"
chk_eq "L1 it is ONE line" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
# the channel contract: UserPromptSubmit/SessionStart add PLAIN stdout as context, and a payload
# that starts with `{` would be parsed as a hook decision object instead
chk_eq "L1 the reminder is plain text, not JSON" 0 \
  "$(printf '%s' "$OUT" | grep -c '^[{]')"

reset_seats
seat s1 "$ORCH" watched
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_eq "L1 a watched seat says nothing (0 bytes)" "" "$OUT$ERR"
reset_seats
seat s1 "$OTHER" stale
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_eq "L1 another checkout's seat says nothing" "" "$OUT$ERR"
reset_seats
seat s1 "$ORCH" stale
run_nag "$(nag_payload UserPromptSubmit "$ORCH")" "$FIX/no-such-run-dir"
chk_eq "L1 a blind census stays SILENT (a reminder is not a gate)" "" "$OUT$ERR"

# ── L1 THROTTLE: same seat set once per window; a changed set speaks at once ────────────────
reset_seats
seat s1 "$ORCH" stale
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_contains "L1 throttle: the first prompt speaks" "s1" "$OUT"
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_eq "L1 throttle: the second prompt with the same set is silent" "" "$OUT"
run_nag "$(nag_payload SessionStart "$ORCH")"
chk_contains "L1 throttle: SessionStart is never throttled (fresh context must see it)" "s1" "$OUT"
seat s2 "$ORCH" stale
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_contains "L1 throttle: a CHANGED seat set speaks immediately" "s2" "$OUT"
run_nag "$(nag_payload UserPromptSubmit "$ORCH")"
chk_eq "L1 throttle: and then holds again" "" "$OUT"
run_nag "$(nag_payload UserPromptSubmit "$ORCH")" "$RUN" 0
chk_contains "L1 throttle: the window is a real interval, not a one-shot latch" "s1" "$OUT"

summary
