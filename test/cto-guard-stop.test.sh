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

# The fake `agentctl`: `status <s>` prints the fixture for that session, records the call so the
# census cap can be counted, and delays when told to — `<s>.sleep` is the "never answers" shape
# (8s against the 5s per-call timeout, deliberately far from the boundary), `delay` is a shared
# sub-timeout pause used by the scaled budget arm.
cat > "$PKG/agentctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FAKE_DIR/calls"
[ -f "$FAKE_DIR/$2.sleep" ] && sleep 8
[ -f "$FAKE_DIR/delay" ] && sleep "$(cat "$FAKE_DIR/delay")"
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

# a status that hangs must be abandoned BEFORE the fake would have answered, so the gate cannot
# become the thing that stalls a turn end. The fake sleeps 8s against a 5s per-call timeout and
# the assertion is `< 7`: the first version slept 6 and asserted `< 6`, which is a BOUNDARY
# EQUALITY — under load the 5s timeout plus interpreter startup measured exactly 6.0s and the
# orchestrator's re-run went red on a correct implementation.
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
chk_eq "S1 the census is abandoned before the call would have returned (${EL}s < 7s)" 1 \
  "$([ "$EL" -lt 7 ] && echo 1 || echo 0)"

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

# ── S1 BOUNDED CENSUS: the cap counts OWNED seats, and it is applied AFTER ownership ───────
reset_seats
for i in $(seq -f '%02g' 1 25); do seat "s$i" "$ORCH" stale; done
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 25 owned metas are censused at the 20-seat cap" 20 "$(grep -c . "$FAKE/calls")"
R="$(field reason "$OUT")"
chk_contains "S1 the unchecked remainder is declared, not swallowed" \
  "+5 owned seat(s) past the census cap" "$R"
chk_contains "S1 the first alphabetical seat is judged" "s01" "$R"
chk_not_contains "S1 the 21st meta was never consulted" "s21" "$R"

# R1 B3: the run dir is shared and sorted alphabetically, so capping the RAW meta list first let
# 20 alphabetically-earlier FOREIGN seats evict this repo's own unwatched seat to position 21 —
# the gate then reported an answered EMPTY census and let the turn end. Foreign seats must cost a
# file read and NOTHING else: no status call, no cap slot.
reset_seats
for i in $(seq -f '%02g' 1 20); do seat "a$i" "$OTHER" stale; done
seat z-own "$ORCH" stale
run_stop "$(stop_payload "$ORCH" false)"
chk_eq "S1 B3 20 foreign metas do not evict this repo's seat" "block" "$(field decision "$OUT")"
chk_contains "S1 B3 and the block names the owned seat" "z-own" "$(field reason "$OUT")"
chk_eq "S1 B3 the 20 foreign seats cost zero status calls" "z-own" "$(cat "$FAKE/calls")"
chk_not_contains "S1 B3 no phantom overflow is claimed for foreign metas" \
  "past the census cap" "$(field reason "$OUT")"

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

# ── R1 B1 THE SHEBANG'S PYTHON: stock interpreter on a clean PATH ──────────────────────────
# The shipped entry is `#!/usr/bin/env python3`, and on a stock macOS host that is
# /usr/bin/python3 3.9.6. A PEP 604 annotation (`str | None`) evaluated at module/class level
# raises TypeError at LOAD time, so the reminder dies before `main()` and the Stop gate degrades
# to "sibling could not be loaded" — a gate that reads as installed and never judges anything.
# Asserting rc=0 alone would not have caught it either: the Stop script exits 0 on a load
# failure BY DESIGN, so this arm demands the real verdict on both scripts.
if [ -x /usr/bin/python3 ]; then
  PYV="$(/usr/bin/python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
  reset_seats
  seat s1 "$ORCH" stale
  tmpe="$(mktemp)"
  out="$(printf '%s' "$(nag_payload UserPromptSubmit "$ORCH")" | PATH=/usr/bin:/bin \
        AGENT_WATCH_DIR="$RUN" FAKE_DIR="$FAKE" /usr/bin/python3 "$NAG" 2>"$tmpe")"; rc=$?
  err="$(cat "$tmpe")"; rm -f "$tmpe"
  chk_eq "B1 seat-liveness runs under the stock python $PYV (rc)" 0 "$rc"
  chk_eq "B1 and raises nothing (a load error would be here)" "" "$err"
  chk_contains "B1 and still reports the seat there" \
    "RUNNING seats without a live watcher: s1" "$out"
  rm -f "$RUN/seat-liveness.nag"
  tmpe="$(mktemp)"
  out="$(printf '%s' "$(stop_payload "$ORCH" false)" | PATH=/usr/bin:/bin \
        AGENT_WATCH_DIR="$RUN" FAKE_DIR="$FAKE" /usr/bin/python3 "$STOP" 2>"$tmpe")"; rc=$?
  err="$(cat "$tmpe")"; rm -f "$tmpe"
  chk_eq "B1 the Stop gate runs under the stock python $PYV (rc)" 0 "$rc"
  chk_eq "B1 and raises nothing there either" "" "$err"
  chk_eq "B1 and reaches a VERDICT, not a load failure" "block" "$(field decision "$out")"
  chk_eq "B1 so no fail-open WARN is emitted" "" "$(field systemMessage "$out")"
else
  echo "    /usr/bin/python3 absent — the stock-python pin is skipped on this host"
fi

# ── R1 M2 ONE BUDGET: the ownership probe is INSIDE the census budget, not beside it ───────
# Scaled time model, patched into a SECOND package copy — the shipped constants are never
# touched: per-call 1.0s, whole census 1.0s. Fixture: a `git` that never answers (sleeps past the
# per-call timeout) plus four owned seats whose status would answer after 0.5s each.
#
# The discriminator is STRUCTURAL, not a stopwatch: an earlier version asserted wall time and
# the machine's load moved it 1.5s→2.6s across two runs of the same correct code — a gate that
# reds under load is worse than no gate. With ONE shared deadline, the ownership probe consumes
# the whole budget and the status loop must therefore make ZERO calls and say the budget ran out.
# With the deadline taken after the git call (the R1 shape, reproduced by mutation while fixing
# this: 3.235s vs 1.042s wall), the loop got a FRESH full budget and really did call `status`.
# So: zero recorded calls + the budget message = the git call was inside the budget.
SCALED="$FIX/scaled"; SLOWBIN="$FIX/slowbin"
mkdir -p "$SCALED" "$SLOWBIN"
cp "$PKG/cto-guard-stop.py" "$PKG/seat-liveness.py" "$PKG/agentctl" "$SCALED/"
sed -i '' -e 's/^_CALL_TIMEOUT = 5\.0/_CALL_TIMEOUT = 1.0/' \
          -e 's/^_CENSUS_BUDGET = 20\.0/_CENSUS_BUDGET = 1.0/' "$SCALED/seat-liveness.py"
chk_eq "M2 the scaled copy really carries the scaled constants" 2 \
  "$(grep -c '^_CALL_TIMEOUT = 1\.0 \|^_CENSUS_BUDGET = 1\.0 ' "$SCALED/seat-liveness.py")"
printf '#!/usr/bin/env bash\nsleep 4\nexec /usr/bin/git "$@"\n' > "$SLOWBIN/git"
chmod +x "$SLOWBIN/git"
reset_seats
for i in 1 2 3 4; do seat "s$i" "$ORCH" stale; done
printf '0.5' > "$FAKE/delay"
tmpe="$(mktemp)"
out="$(printf '%s' "$(stop_payload "$ORCH" false)" | PATH="$SLOWBIN:$PATH" \
      AGENT_WATCH_DIR="$RUN" python3 "$SCALED/cto-guard-stop.py" 2>"$tmpe")"; rc=$?
err="$(cat "$tmpe")"; rm -f "$tmpe" "$FAKE/delay"
chk_eq "M2 a hung ownership probe allows the turn end (exit 0)" 0 "$rc"
chk_eq "M2 and never blocks" "" "$(field decision "$out")"
chk_eq "M2 and never writes stderr" "" "$err"
chk_contains "M2 the exhausted budget is what is reported" "ran past its 1s budget" \
  "$(field systemMessage "$out")"
chk_eq "M2 git spent the census budget, so ZERO status calls were made" "" "$(cat "$FAKE/calls")"

# ── R2 MAJOR: the OWNERSHIP SCAN is metered too, not just the subprocesses ─────────────────
# One `open` + one `realpath` per meta is trivial per entry and unbounded in the aggregate: on a
# large or slow run dir the scan could walk past the whole budget before the first deadline check
# (which used to sit in the STATUS loop) ever ran. Scaled model, second copy again: budget 0.6s
# with a 0.2s delay injected into every `*.duplex.meta` read and six metas, so the scan needs
# 1.2s of reads to finish and MUST stop early. Elapsed is measured INSIDE the harness (a
# subprocess stopwatch would be mostly interpreter startup at this scale) and the ceiling is
# budget + one read: an unmetered scan pays all six.
# 0.6s rather than the reviewer's 0.10s on purpose: at 0.10s the real `git rev-parse` fork/exec
# and normal machine noise are the same order as the budget itself, which is how the first M2
# arm became a load-dependent flake (§R2.3 of the findings).
sed -i '' -e 's/^_CALL_TIMEOUT = 1\.0/_CALL_TIMEOUT = 0.6/' \
          -e 's/^_CENSUS_BUDGET = 1\.0/_CENSUS_BUDGET = 0.6/' "$SCALED/seat-liveness.py"
chk_eq "R2 the scan model carries the 0.6s budget" 1 \
  "$(grep -c '^_CENSUS_BUDGET = 0\.6 ' "$SCALED/seat-liveness.py")"
reset_seats
for i in 1 2 3 4 5 6; do seat "m$i" "$ORCH" stale; done
SCAN_EL="$FIX/scan-elapsed"
tmpe="$(mktemp)"
out="$(printf '%s' "$(stop_payload "$ORCH" false)" | AGENT_WATCH_DIR="$RUN" python3 -c '
import builtins, runpy, sys, time
_open = builtins.open
def slow(path, *a, **k):                      # 0.2s per meta read, nothing else touched
    if str(path).endswith(".duplex.meta"):
        time.sleep(0.2)
    return _open(path, *a, **k)
builtins.open = slow
t = time.monotonic()
try:
    runpy.run_path(sys.argv[1], run_name="__main__")
except SystemExit:
    pass
el = time.monotonic() - t
builtins.open = _open
with _open(sys.argv[2], "w") as fh:
    fh.write("%.3f" % el)' "$SCALED/cto-guard-stop.py" "$SCAN_EL" 2>"$tmpe")"; rc=$?
err="$(cat "$tmpe")"; rm -f "$tmpe"
EL="$(cat "$SCAN_EL")"
chk_eq "R2 a slow ownership scan allows the turn end (exit 0)" 0 "$rc"
chk_eq "R2 and never blocks" "" "$(field decision "$out")"
chk_eq "R2 and never writes stderr" "" "$err"
chk_contains "R2 the WARN says the budget went in the ownership scan" \
  "budget during the ownership scan" "$(field systemMessage "$out")"
chk_eq "R2 the scan stops inside budget + one read (${EL}s <= 0.8s; 6 unmetered reads = 1.2s)" 1 \
  "$(python3 -c 'import sys; print(1 if float(sys.argv[1]) <= 0.8 else 0)' "$EL")"
chk_eq "R2 an abandoned scan makes ZERO status calls" "" "$(cat "$FAKE/calls")"

summary
