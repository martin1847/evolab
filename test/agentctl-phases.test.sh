#!/usr/bin/env bash
# The phase ledger (write side) + `agentctl phases` (read side).
#
# WHY this suite exists at all: the two numbers a retro argues from — how long a batch took and
# how much of it was avoidable — were hand-computed off transcripts, so the mechanical check
# could only verify that SOMEBODY typed two numbers. The ledger gives the first half a machine
# source. That makes it a NEW INSTRUMENT, and an instrument gets the four arms: it fires when it
# should (§A live commit points, §B fixture readings), it does NOT fire when it should not (a
# refused publish writes no terminal row; a sibling worktree is not this repo), it degrades
# honestly (unwritable shard, corrupt lines, missing shards → coverage `unknown`), and it never
# turns into a verdict (§V: no `wall≈`/`avoidable≈` may appear anywhere in its output).
#
# Harness: §A uses the PROCESS-RUNNING fake tmux (same shape as agentctl-duplex.test.sh) so the
# real fifo/flock/identity pipeline runs end to end against a scripted fake engine. §B needs no
# engine at all — it seeds ledger shards with computed timestamps and asserts EXACT numbers, so
# every base instant is a whole second and every stamp round-trips without rounding slack.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL="$AW_DIR/agentctl"
CTL="$AW_DIR/duplexctl.py"
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
  return 0
}

# ── readers over the artifact under test ─────────────────────────────────────────────
ledger_events() { # every event word of $1 (default: the live run dir), in append order
  python3 - "${1:-$AGENT_WATCH_DIR}" <<'PY'
import glob, json, os, sys
words = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "phase-ledger-*.jsonl"))):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                words.append(json.loads(line)["event"])
print(" ".join(words))
PY
}

ledger_field() { # $1 event, $2 field, $3 occurrence (1-based) -> the value, "" when absent
  python3 - "${AGENT_WATCH_DIR}" "$1" "$2" "$3" <<'PY'
import glob, json, os, sys
run, want, field, nth = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
hits = []
for path in sorted(glob.glob(os.path.join(run, "phase-ledger-*.jsonl"))):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row["event"] == want:
                hits.append(row)
print("" if len(hits) < nth else hits[nth - 1].get(field, ""))
PY
}

ledger_keys() { # $1 event -> the sorted field names of its FIRST row
  python3 - "${AGENT_WATCH_DIR}" "$1" <<'PY'
import glob, json, os, sys
run, want = sys.argv[1], sys.argv[2]
for path in sorted(glob.glob(os.path.join(run, "phase-ledger-*.jsonl"))):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip() and json.loads(line)["event"] == want:
                print(" ".join(sorted(json.loads(line))))
                raise SystemExit(0)
print("")
PY
}

jget() { # $1 dotted path (ints index lists); stdin = the report json
  # the program arrives via -c, NEVER a heredoc: a heredoc IS python's stdin, so the report
  # would be consumed as the program's own source (the first cut of this suite did exactly
  # that, and every numeric assertion silently read empty)
  python3 -c '
import json, sys
node = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    node = node[int(key)] if key.isdigit() else node[key]
print(node if isinstance(node, str) else json.dumps(node, sort_keys=True))
' "$1"
}

seats() { # stdin = the report json -> the seat names, in report order
  python3 -c '
import json, sys
print(" ".join(seat["name"] for seat in json.load(sys.stdin)["sessions"]))'
}

seat_count() { # stdin = the report json
  python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))'
}

terminal_count() { # $1 seat index; stdin = the report json
  python3 -c '
import json, sys
print(len(json.load(sys.stdin)["sessions"][int(sys.argv[1])]["terminals"]))' "$1"
}

shard_overlap() { # $1 shard path, $2 session name -> overlap | disjoint
  case "$(basename "$1")" in
    "$2".*|."$2".*) echo overlap ;;
    *) echo disjoint ;;
  esac
}

# ── §A the five commit points, on a live fake engine ─────────────────────────────────
echo "== A: write side — one row per commit point, nothing in between =="
sandbox_new; install_running_tmux
WT="$SANDBOX/wt"; mkdir -p "$WT"
printf 'do the thing\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
SHARD="$WATCH_RUN_DIR/phase-ledger-$(date -u +%Y%m%d).jsonl"
bash "$AGENTCTL" start omp phA "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
chk_eq "A1 start commits exactly ONE row, and it is the start" "start" "$(ledger_events)"
chk_eq "A1 the shard is named for the UTC day, not the local one" 1 \
  "$([ -f "$SHARD" ] && echo 1 || echo 0)"
# the row's field set is CLOSED: a reader that has to guess which keys exist cannot report
# coverage, and a stray key is a schema change nobody declared
chk_eq "A2 the start row carries exactly its declared fields" \
  "attempt cwd engine event launcher_ppid name review session_id ts" "$(ledger_keys start)"
chk_eq "A2 ts is RFC3339 UTC with milliseconds" 1 \
  "$(printf '%s' "$(ledger_field start ts 1)" \
     | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$')"
chk_eq "A2 cwd is the realpath, so --repo containment can be judged at all" \
  "$(cd "$WT" && pwd -P)" "$(ledger_field start cwd 1)"
chk_eq "A2 the seat's engine is recorded" "omp" "$(ledger_field start engine 1)"
START_SID="$(ledger_field start session_id 1)"
START_ATT="$(ledger_field start attempt 1)"

# watch-arm: one row per ARM. --inline exercises the real waiter; the supervised spelling is
# driven through the verb directly (a real supervisor needs a real tmux, which this fake is not)
AGENT_WATCH_MAX_POLLS=4 bash "$AGENTCTL" watch phA --inline >/dev/null 2>&1
chk_eq "A3 the inline waiter's arm is recorded with its mode" "inline" \
  "$(ledger_field watch_arm mode 1)"
python3 "$CTL" --run-dir "$WATCH_RUN_DIR" watch-arm phA --pid $$ --mode supervised >/dev/null 2>&1
chk_eq "A3 the supervised spelling reaches the same field" "supervised" \
  "$(ledger_field watch_arm mode 2)"
chk_eq "A3 watch-arm refuses to record a mode it was never told" 2 \
  "$(python3 "$CTL" --run-dir "$WATCH_RUN_DIR" watch-arm phA --pid $$ >/dev/null 2>&1; echo $?)"

# terminal: published by the ONE writer, so its class comes from the record, never from prose
chk_eq "A4 the concluded round published a terminal row" "DONE" "$(ledger_field terminal class 1)"
chk_eq "A4 and it names the round it concluded" "1" "$(ledger_field terminal round 1)"
chk_eq "A4 with the terminal rc beside the class" "0" "$(ledger_field terminal rc 1)"
TERM_BEFORE="$(ledger_events | tr ' ' '\n' | grep -c '^terminal$')"

# A REFUSED publish must leave no terminal row: the ledger's terminal count is the lane's
# published-conclusion count, and a row for a conclusion nobody may report would break that.
out="$(python3 "$CTL" --run-dir "$WATCH_RUN_DIR" identity publish phA \
        --armed "bogus/bogus/bogus" --round 1 --rc 0 2>&1)"; rc=$?
chk_eq "A5 a publish fenced out by identity is refused (known-positive for the row below)" 1 \
  "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
chk_eq "A5 and it writes NO terminal row" "$TERM_BEFORE" \
  "$(ledger_events | tr ' ' '\n' | grep -c '^terminal$')"

# steer: recorded at the ROUND commit point, so an --interrupt row carries the new attempt
bash "$AGENTCTL" steer phA -m "again" >/dev/null 2>&1
chk_eq "A6 a plain steer records the round it opened" "2" "$(ledger_field steer round_after 1)"
chk_eq "A6 and marks itself as not an interrupt" "0" "$(ledger_field steer interrupt 1)"
chk_eq "A6 a plain steer keeps the attempt" "$START_ATT" "$(ledger_field steer attempt 1)"
bash "$AGENTCTL" steer phA -m "restart" --interrupt >/dev/null 2>&1
chk_eq "A7 --interrupt records itself as one" "1" "$(ledger_field steer interrupt 2)"
chk_eq "A7 --interrupt's row carries a NEW attempt" 1 \
  "$([ "$(ledger_field steer attempt 2)" != "$START_ATT" ] && echo 1 || echo 0)"
chk_eq "A7 and the same session_id: a new attempt is not a new seat" "$START_SID" \
  "$(ledger_field steer session_id 2)"

# rc 3 = "delivered, unconfirmed". The round ALREADY opened before the first byte, so the
# dispatch was paid for and must be in the ledger — waiting for an ack it may never get would
# lose exactly the rounds a stuck engine costs. `--wait 0` skips the ack window deterministically.
out="$(python3 "$CTL" --run-dir "$WATCH_RUN_DIR" send phA --verb steer --text "unacked" \
        --wait 0 2>&1)"; rc=$?
chk_eq "A8 an unacked steer really does exit 3 (known-positive)" 3 "$rc"
chk_eq "A8 and it still recorded its round" "4" "$(ledger_field steer round_after 3)"

# stop: after the reap, and the shard outlives it
bash "$AGENTCTL" stop phA >/dev/null 2>&1
chk_eq "A9 stop appends its own row, in commit order" \
  "start watch_arm terminal watch_arm steer steer steer stop" "$(ledger_events)"
chk_eq "A9 the stop row is attributed to the seat whose identity teardown just cleared" \
  "$START_SID" "$(ledger_field stop session_id 1)"
chk_eq "A9 with its reason and lane" "stopped" "$(ledger_field stop reason 1)"
chk_eq "A9 the shard survived teardown" 1 "$([ -f "$SHARD" ] && echo 1 || echo 0)"
# known-positive that teardown really ran over this run dir, so "the shard is still here" is
# evidence of disjointness and not evidence that nothing was deleted
chk_eq "A9 known-positive: teardown DID remove the session-scoped records" 0 \
  "$([ -e "$WATCH_RUN_DIR/phA.terminal.json" ] && echo 1 || echo 0)"
chk_eq "A9 the shard name cannot match any '<session>.*' teardown glob" "disjoint" \
  "$(shard_overlap "$SHARD" phA)"
sweep_fakes

# A start whose goal frame never lands must not leave a seat that reads `open` for the rest of
# the day. The commit order is what makes this reachable: the identity (and therefore the
# ledger's start row) is durable BEFORE the frame goes out, so a refusal between the two has
# an opened seat to close. A codex meta with no threadId is the cheapest such refusal — the
# handshake never completed, and `send` dies right after the identity commit.
echo "== A: a failed start closes its own row =="
sandbox_new
WT="$SANDBOX/wt"; mkdir -p "$WT"
printf 'engine=codex\ncwd=%s\n' "$WT" > "$WATCH_RUN_DIR/phF.duplex.meta"
out="$(python3 "$CTL" --run-dir "$WATCH_RUN_DIR" send phF --verb prompt --text "goal" 2>&1)"; rc=$?
chk_eq "A10 a prompt refused after the identity commit fails the verb (known-positive)" 1 \
  "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
chk_contains "A10 and it is the post-commit refusal, not a pre-flight one" "no threadId" "$out"
chk_eq "A10 the ledger opened the seat and then closed it" "start stop" "$(ledger_events)"
chk_eq "A10 with the reason that says which end failed" "start-failed" \
  "$(ledger_field stop reason 1)"
chk_eq "A10 and the closing row is attributed to the seat that opened" \
  "$(ledger_field start session_id 1)" "$(ledger_field stop session_id 1)"

# FAIL-OPEN: an unwritable ledger costs one WARN and nothing else
echo "== A: fail-open — the instrument never fails a dispatch =="
if [ "$(id -u)" != "0" ]; then
  sandbox_new; install_running_tmux
  WT="$SANDBOX/wt"; mkdir -p "$WT"
  printf 'do the thing\nPreflight: ls => ok\n' > "$SANDBOX/goal.md"
  export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
  bash "$AGENTCTL" start omp phW "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
  chmod 000 "$WATCH_RUN_DIR/phase-ledger-$(date -u +%Y%m%d).jsonl"
  out="$(bash "$AGENTCTL" steer phW -m "still works" 2>&1)"; rc=$?
  chk_eq "A11 an unwritable shard does NOT change the verb's rc" 0 "$rc"
  chk_contains "A11 it says so on stderr, once" "WARN: phase ledger not recorded" "$out"
  chk_contains "A11 and points at the verb that reports coverage" "agentctl phases" "$out"
  chmod 644 "$WATCH_RUN_DIR/phase-ledger-$(date -u +%Y%m%d).jsonl"
  bash "$AGENTCTL" stop phW >/dev/null 2>&1
  sweep_fakes
else
  echo "  [skip] running as root — an unwritable shard cannot be built"
fi

# ── §B the read side, on seeded shards with exact numbers ────────────────────────────
echo "== B: read side — readings, coverage, and the numbers that are NOT summed =="
sandbox_new
SEED="$SANDBOX/seed.py"
cat > "$SEED" <<'PY'
"""Seed one ledger fixture. Every base instant is a WHOLE second, so `phase_stamp`'s
millisecond field round-trips exactly and the report's numbers are exact integers."""
import json
import os
import sys
import time

run, case = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
NOW = time.time()
BASE = float(int(NOW))
ROWS = []


def stamp(when):
    whole, millis = int(when), int(round((when - int(when)) * 1000))
    if millis >= 1000:
        whole, millis = whole + 1, 0
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole)) + ".%03dZ" % millis


def day(when):
    return time.strftime("%Y%m%d", time.gmtime(when))


def ev(when, event, name, sid, attempt="at1", ts=None, **extra):
    row = {"ts": stamp(when if ts is None else ts), "event": event, "name": name,
           "session_id": sid, "attempt": attempt}
    row.update(extra)
    ROWS.append((when, row))


def flush(pad=2, raw=()):
    """One shard per UTC day, plus EMPTY shards for the padding days before the first row: a
    real run dir accumulates a shard per day the lane ran, and a window reaching back past the
    ledger's first day is the `unknown` case, tested on its own below."""
    days = {}
    for when, row in ROWS:
        days.setdefault(day(when), []).append(json.dumps(row))
    for extra_day, line in raw:
        days.setdefault(extra_day, []).append(line)
    first = min([when for when, _ in ROWS], default=NOW)
    cursor = first - pad * 86400.0
    while cursor <= NOW + 1:
        days.setdefault(day(cursor), [])
        cursor += 86400.0
    days.setdefault(day(NOW), [])
    for name, lines in days.items():
        with open(os.path.join(run, "phase-ledger-%s.jsonl" % name), "w",
                  encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")


def out(**fields):
    for key, value in fields.items():
        print("%s=%s" % (key, value))


T = BASE - 3600.0
REPO = rest[0] if rest else "/nonexistent"

if case == "restart":
    # the SAME cli name, twice: two seats, and merging them would understate the dispatch
    # count and overstate one seat's wall in one stroke
    ev(T, "start", "seatA", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 600, "terminal", "seatA", "s1", round="1", rc=0, **{"class": "DONE"})
    ev(T + 700, "stop", "seatA", "s1", reason="stopped", lane=1)
    ev(T + 800, "start", "seatA", "s2", attempt="at2", cwd=REPO, engine="omp", review=0,
       launcher_ppid=1)
    ev(T + 1400, "stop", "seatA", "s2", attempt="at2", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(T))
elif case == "reopen":
    ev(T, "start", "seatB", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 300, "terminal", "seatB", "s1", round="1", rc=0, **{"class": "DONE"})
    ev(T + 400, "steer", "seatB", "s1", round_after=2, interrupt=0)
    flush()
    out(SINCE=stamp(T))
elif case == "reopen-interrupt":
    ev(T, "start", "seatB", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 300, "terminal", "seatB", "s1", round="1", rc=0, **{"class": "DONE"})
    ev(T + 400, "steer", "seatB", "s1", attempt="at2", round_after=2, interrupt=1)
    flush()
    out(SINCE=stamp(T))
elif case == "stop-first":
    ev(T, "start", "seatS", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 500, "stop", "seatS", "s1", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(T))
elif case == "two-terminals":
    ev(T, "start", "seatI", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T, "start", "seatR", "s2", attempt="at2", cwd=REPO, engine="codex", review=1,
       launcher_ppid=1)
    ev(T + 300, "terminal", "seatI", "s1", round="1", rc=0, **{"class": "DONE"})
    ev(T + 400, "terminal", "seatR", "s2", attempt="at2", round="1", rc=0, **{"class": "DONE"})
    ev(T + 900, "start", "seatN", "s3", attempt="at3", cwd=REPO, engine="omp", review=0,
       launcher_ppid=1)
    ev(T + 1000, "stop", "seatN", "s3", attempt="at3", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(T))
elif case == "review-while-open":
    ev(T, "start", "seatI", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 100, "start", "seatR", "s2", attempt="at2", cwd=REPO, engine="codex", review=1,
       launcher_ppid=1)
    ev(T + 400, "terminal", "seatR", "s2", attempt="at2", round="1", rc=0, **{"class": "DONE"})
    ev(T + 500, "stop", "seatR", "s2", attempt="at2", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(T))
elif case == "midnight":
    early = BASE - 26 * 3600.0
    ev(early, "start", "seatM", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(early + 3600, "terminal", "seatM", "s1", round="1", rc=0, **{"class": "DONE"})
    ev(BASE - 60, "stop", "seatM", "s1", reason="stopped", lane=1)
    flush()
    out(SINCE="30h", DAY_START=day(early), DAY_STOP=day(BASE - 60),
        SPAN=int(26 * 3600 - 60))
elif case == "boundary":
    ev(BASE - 7200, "start", "seatOld", "sOld", cwd=REPO, engine="omp", review=0,
       launcher_ppid=1)
    ev(BASE - 7100, "stop", "seatOld", "sOld", reason="stopped", lane=1)
    ev(BASE - 3600, "start", "seatAt", "sAt", attempt="at2", cwd=REPO, engine="omp", review=0,
       launcher_ppid=1)
    # this seat OUTLIVES the narrow window's start, which is what makes it the intersection
    # case below: opened before `--since`, still on the clock inside it
    ev(BASE - 2500, "stop", "seatAt", "sAt", attempt="at2", reason="stopped", lane=1)
    ev(BASE - 1800, "start", "seatNew", "sNew", attempt="at3", cwd=REPO, engine="omp",
       review=0, launcher_ppid=1)
    ev(BASE - 1700, "stop", "seatNew", "sNew", attempt="at3", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(BASE - 3600), WIDE=stamp(BASE - 7200), INSIDE=stamp(BASE - 3000))
elif case == "clock":
    ev(BASE - 3600, "start", "seatC", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    # the stop ARRIVED after the start and CLAIMS to precede it: a regressed clock, and the
    # only place that fact survives is the mismatch between append order and `ts`
    ev(BASE - 3000, "stop", "seatC", "s1", ts=BASE - 3700, reason="stopped", lane=1)
    ev(BASE - 2000, "start", "seatOk", "s2", attempt="at2", cwd=REPO, engine="omp", review=0,
       launcher_ppid=1)
    ev(BASE - 1700, "stop", "seatOk", "s2", attempt="at2", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(BASE - 4000))
elif case == "repo":
    inside, sibling, link = rest[0], rest[1], rest[2]
    ev(T, "start", "seatIn", "s1", cwd=inside, engine="omp", review=0, launcher_ppid=1)
    ev(T + 100, "stop", "seatIn", "s1", reason="stopped", lane=1)
    ev(T + 200, "start", "seatSib", "s2", attempt="at2", cwd=sibling, engine="omp", review=0,
       launcher_ppid=1)
    ev(T + 300, "stop", "seatSib", "s2", attempt="at2", reason="stopped", lane=1)
    ev(T + 400, "start", "seatLink", "s3", attempt="at3", cwd=link, engine="omp", review=0,
       launcher_ppid=1)
    ev(T + 500, "stop", "seatLink", "s3", attempt="at3", reason="stopped", lane=1)
    flush()
    out(SINCE=stamp(T))
elif case == "corrupt":
    ev(T, "start", "seatV", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(T + 100, "stop", "seatV", "s1", reason="stopped", lane=1)
    bad = [
        "this is not json at all",
        json.dumps(["a", "list", "is", "legal", "json"]),
        json.dumps({"ts": stamp(T + 50), "event": "teleport", "name": "x",
                    "session_id": "z"}),
        json.dumps({"ts": "not-a-timestamp", "event": "start", "name": "x",
                    "session_id": "z"}),
        json.dumps({"ts": stamp(T + 60), "event": "start", "name": "x"}),
    ]
    flush(raw=[(day(T), line) for line in bad])
    out(SINCE=stamp(T), BAD=len(bad))
elif case == "empty":
    out(SINCE=stamp(BASE - 3600))
elif case == "stale":
    early = BASE - 3 * 86400.0
    ev(early, "start", "seatZ", "s1", cwd=REPO, engine="omp", review=0, launcher_ppid=1)
    ev(early + 600, "stop", "seatZ", "s1", reason="stopped", lane=1)
    # ONLY the old shard: the window's own days were never written, which is exactly the
    # "old shards exist, today's is missing" shape
    with open(os.path.join(run, "phase-ledger-%s.jsonl" % day(early)), "w",
              encoding="utf-8") as fh:
        for _when, row in ROWS:
            fh.write(json.dumps(row) + "\n")
    out(SINCE="5d")
else:
    raise SystemExit("unknown fixture case %r" % case)
PY

ph_case() { # $1 case, rest = seeder args -> fresh run dir + eval'd anchors
  export AGENT_WATCH_DIR="$SANDBOX/runs/$1"
  rm -rf "$AGENT_WATCH_DIR"; mkdir -p "$AGENT_WATCH_DIR"
  eval "$(python3 "$SEED" "$AGENT_WATCH_DIR" "$@")"
}

# B1 — a restarted NAME is a second seat
ph_case restart /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"; rc=$?
chk_eq "B1 restart rc0" 0 "$rc"
chk_eq "B1 the same name twice is TWO seats" 2 "$(printf '%s' "$out" | seat_count)"
chk_eq "B1 both seats keep the shared cli name" "seatA seatA" \
  "$(printf '%s' "$out" | seats)"
chk_eq "B1 and are keyed apart by session_id" "s1 s2" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(" ".join(s["session_id"] for s in json.load(sys.stdin)["sessions"]))')"
chk_eq "B1 seat_wall is the SUM of the two spans" "1300.0" \
  "$(printf '%s' "$out" | jget readings.seat_wall_s)"
chk_eq "B1 batch_span is first→last event, not the sum" "1400.0" \
  "$(printf '%s' "$out" | jget readings.batch_span_s)"
chk_eq "B1 idle_span is the gap between the two seats" "100.0" \
  "$(printf '%s' "$out" | jget readings.idle_span_s)"
chk_eq "B1 dispatch_latency measures terminal → next dispatch" "200.0" \
  "$(printf '%s' "$out" | jget readings.dispatch_latency.0.seconds)"
chk_eq "B1 coverage is ok when every window day has a shard" "ok" \
  "$(printf '%s' "$out" | jget coverage)"

# B2 — terminal then a plain steer: the round reopens AND the terminal is kept
ph_case reopen /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B2 a steer after a terminal reopens the seat" "open" \
  "$(printf '%s' "$out" | jget sessions.0.state)"
chk_eq "B2 on the round the steer opened" "2" "$(printf '%s' "$out" | jget sessions.0.open_round)"
chk_eq "B2 and the concluded round's terminal is still on the record" "DONE" \
  "$(printf '%s' "$out" | jget sessions.0.terminals.0.class)"
chk_eq "B2 exactly one terminal, not one per round" 1 \
  "$(printf '%s' "$out" | terminal_count 0)"

# B3 — terminal then --interrupt: a new attempt is not a new seat
ph_case reopen-interrupt /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B3 an --interrupt after a terminal does not split the seat" 1 \
  "$(printf '%s' "$out" | seat_count)"
chk_eq "B3 the seat is open again on round 2" "open" \
  "$(printf '%s' "$out" | jget sessions.0.state)"
chk_eq "B3 and the earlier conclusion survives the new attempt" 1 \
  "$(printf '%s' "$out" | terminal_count 0)"

# B4 — stopped without ever concluding
ph_case stop-first /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B4 a seat stopped before any conclusion reads stopped" "stopped" \
  "$(printf '%s' "$out" | jget sessions.0.state)"
chk_eq "B4 with no terminal invented for it" 0 \
  "$(printf '%s' "$out" | terminal_count 0)"
chk_eq "B4 and its span is start→stop" "500.0" "$(printf '%s' "$out" | jget sessions.0.duration_s)"

# B5 — two terminals waiting on ONE next dispatch: listed per terminal, never summed
ph_case two-terminals /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B5 both terminals get their own latency row" 2 \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["readings"]["dispatch_latency"]))')"
chk_eq "B5 each measured to the SAME next dispatch, not to each other" "600.0 500.0" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(" ".join(str(h["seconds"]) for h in json.load(sys.stdin)["readings"]["dispatch_latency"]))')"
chk_eq "B5 only the maximum is published — no sum exists to misread" "600.0" \
  "$(printf '%s' "$out" | jget readings.dispatch_latency_max_s)"
chk_eq "B5 no summed latency field is published at all" "absent" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin)["readings"]; print("present" if any("latency" in k and "sum" in k for k in r) else "absent")')"
chk_eq "B5 idle_span is the union's complement, not per-seat idleness" "500.0" \
  "$(printf '%s' "$out" | jget readings.idle_span_s)"
chk_eq "B5 seat_wall sums the three seats" "800.0" \
  "$(printf '%s' "$out" | jget readings.seat_wall_s)"
chk_eq "B5 review_wall is the review seat's share only" "400.0" \
  "$(printf '%s' "$out" | jget readings.review_wall_s)"
# seat_wall < batch_span here because these three seats barely overlap; the OPPOSITE case (and
# the reason the label insists it is not wall clock) is asserted on the concurrent fixture B6
chk_eq "B5 seat_wall is machine-time, so it can sit either side of batch_span" "under" \
  "$(printf '%s' "$out" | python3 -c '
import json, sys
read = json.load(sys.stdin)["readings"]
print("under" if read["seat_wall_s"] < read["batch_span_s"] else "over")')"

# B6 — an open implementation seat covers the review seat's conclusion: zero idle
ph_case review-while-open /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B6 a still-open seat leaves no idle gap behind a peer's terminal" "0" \
  "$(printf '%s' "$out" | jget readings.idle_span_s)"
chk_eq "B6 and the open seat is reported open, not concluded" "open" \
  "$(printf '%s' "$out" | jget sessions.0.state)"
# the concurrency half of the seat_wall label: two seats on the clock at once make the SUM of
# their spans exceed the batch's own span, which is exactly why the number is announced as seat
# machine-time and never as wall clock
chk_eq "B6 concurrent seats push seat_wall past batch_span" "over" \
  "$(printf '%s' "$out" | python3 -c '
import json, sys
read = json.load(sys.stdin)["readings"]
print("over" if read["seat_wall_s"] > read["batch_span_s"] else "under")')"

# B7 — a seat whose start lives in the PREVIOUS UTC shard
ph_case midnight /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B7 the start really is in an older shard (known-positive)" 1 \
  "$([ "$DAY_START" != "$DAY_STOP" ] && echo 1 || echo 0)"
chk_eq "B7 the reader found it across the shard boundary" 1 \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(0 if json.load(sys.stdin)["sessions"][0]["start"] is None else 1)')"
chk_eq "B7 so the span is the whole seat, not the shard's slice" "$SPAN.0" \
  "$(printf '%s' "$out" | jget sessions.0.duration_s)"
chk_eq "B7 and nothing is marked truncated" "0" \
  "$(printf '%s' "$out" | jget sessions.0.truncated_start)"

# B8 — the --since edge: before / exactly on / after
ph_case boundary /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B8 a seat exactly ON the window start is inside it" "seatAt seatNew" \
  "$(printf '%s' "$out" | seats)"
out="$(bash "$AGENTCTL" phases --json --since "$WIDE")"
chk_eq "B8 widening the window recovers the earlier seat (known-positive)" 3 \
  "$(printf '%s' "$out" | seat_count)"
out="$(bash "$AGENTCTL" phases --json --since "$INSIDE")"
chk_eq "B8 a seat that opened before the window keeps only the intersection" "500.0" \
  "$(printf '%s' "$out" | jget sessions.0.duration_s)"
chk_eq "B8 and says so" "1" "$(printf '%s' "$out" | jget sessions.0.truncated_start)"
chk_eq "B8 which makes the whole reading partial, never silently ok" "partial" \
  "$(printf '%s' "$out" | jget coverage)"

# B9 — a regressed clock excludes ONE duration and is counted, never clamped to zero
ph_case clock /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B9 the inverted edge is counted" "1" "$(printf '%s' "$out" | jget clock_regressed)"
chk_eq "B9 its duration is excluded, not clamped to 0" "null" \
  "$(printf '%s' "$out" | jget sessions.0.duration_s)"
chk_eq "B9 so seat_wall carries only the measurable seat" "300.0" \
  "$(printf '%s' "$out" | jget readings.seat_wall_s)"

# B10 — --repo containment is by PATH COMPONENT
mkdir -p "$SANDBOX/repo/sub" "$SANDBOX/repo-sibling"
ln -sfn "$SANDBOX/repo/sub" "$SANDBOX/spelling"
ph_case repo "$SANDBOX/repo/sub" "$SANDBOX/repo-sibling" "$SANDBOX/spelling"
out="$(bash "$AGENTCTL" phases --json --since "$SINCE" --repo "$SANDBOX/repo")"
chk_eq "B10 a sibling sharing the name PREFIX is not this repo" "seatIn seatLink" \
  "$(printf '%s' "$out" | seats)"
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B10 known-positive: without --repo all three seats are visible" 3 \
  "$(printf '%s' "$out" | seat_count)"
out="$(bash "$AGENTCTL" phases --json --since "$SINCE" --repo "$SANDBOX/repo-sibling")"
chk_eq "B10 and the sibling root sees only its own seat" "seatSib" \
  "$(printf '%s' "$out" | seats)"
rc=$(bash "$AGENTCTL" phases --json --since "$SINCE" --repo "repo" >/dev/null 2>&1; echo $?)
chk_eq "B10 a relative --repo is refused at the parameter surface" 1 "$rc"

# B11 — corrupt lines are counted and dropped, never guessed at
ph_case corrupt /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"; rc=$?
chk_eq "B11 a shard with garbage still reports rc0" 0 "$rc"
chk_eq "B11 every unusable line is counted" "$BAD" "$(printf '%s' "$out" | jget skipped)"
chk_eq "B11 and none of them invented a seat" 1 \
  "$(printf '%s' "$out" | seat_count)"

# B12 — an empty ledger is a legitimate reading, not an error
ph_case empty /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"; rc=$?
chk_eq "B12 an empty ledger exits 0" 0 "$rc"
chk_eq "B12 with no seats" 0 \
  "$(printf '%s' "$out" | seat_count)"
chk_eq "B12 no events" "0" "$(printf '%s' "$out" | jget events)"
chk_eq "B12 a zero span rather than an invented one" "0.0" \
  "$(printf '%s' "$out" | jget readings.batch_span_s)"
chk_eq "B12 and coverage that refuses to vouch for the window" "unknown" \
  "$(printf '%s' "$out" | jget coverage)"

# B13 — old shards but no shard for the window's own days
ph_case stale /repo/one
out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
chk_eq "B13 a hole in the window's shards reads unknown" "unknown" \
  "$(printf '%s' "$out" | jget coverage)"
chk_eq "B13 and the missing days are named" 1 \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin)["shards_missing"] else 0)')"
chk_eq "B13 known-positive: the OLD shard is present and was read" 1 \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin)["shards_present"] else 0)')"

# ── §V the verb is a reading, and stays one ─────────────────────────────────────────
echo "== V: numbers only — the verb never renders a verdict =="
ph_case two-terminals /repo/one
json_out="$(bash "$AGENTCTL" phases --json --since "$SINCE")"
human_out="$(bash "$AGENTCTL" phases --since "$SINCE")"
# The forbidden thing is a SUGGESTED VALUE, not the words: the json's `note` says out loud that
# wall/avoidable stay the orchestrator's judgement, and that sentence is the point. What must
# never appear is either number in a form the ledger's grammar would accept.
chk_not_contains "V1 the json suggests no wall figure" "wall=" "$json_out"
chk_not_contains "V1 nor an approximate one" "wall≈" "$json_out"
chk_not_contains "V1 nor an avoidable figure" "avoidable=" "$json_out"
chk_not_contains "V1 nor an approximate avoidable one" "avoidable≈" "$json_out"
chk_contains "V1 and it says whose judgement those two numbers are" \
  "orchestrator's judgement" "$json_out"
chk_not_contains "V2 the human face suggests no wall figure" "wall=" "$human_out"
chk_not_contains "V2 nor an approximate one" "wall≈" "$human_out"
chk_not_contains "V2 nor an avoidable figure" "avoidable" "$human_out"
chk_contains "V2 it says what it is" "READINGS ONLY" "$human_out"
chk_contains "V2 and warns that seat_wall is not wall clock" "NOT wall clock" "$human_out"
chk_contains "V2 and that latency is never summed" "never summed" "$human_out"
chk_eq "V3 the human face stays inside its 30-line bound" 1 \
  "$([ "$(printf '%s\n' "$human_out" | grep -c .)" -le 30 ] && echo 1 || echo 0)"
chk_eq "V4 --json parses" "ok" \
  "$(printf '%s' "$json_out" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")')"

# the verb is registered as a PUBLIC OBSERVATION verb in both definitions the parity gate holds
chk_eq "V5 phases is declared read-only about the work" "True" \
  "$(python3 -c "import sys; sys.path.insert(0, '$AW_DIR'); import duplexctl; print('phases' in duplexctl.OBSERVE_VERBS)")"
chk_eq "V5 and the bash front door dispatches it" 1 \
  "$(grep -c '^  phases)' "$AGENTCTL")"
chk_eq "V5 usage names it" 1 "$(bash "$AGENTCTL" 2>&1 | grep -c 'agentctl phases')"

# one accepted spelling per flag, at this level too
chk_eq "V6 an abbreviated flag is refused" 2 \
  "$(bash "$AGENTCTL" phases --sinc 1h >/dev/null 2>&1; echo $?)"
chk_eq "V6 an unparseable --since is refused with a usable message" 1 \
  "$(bash "$AGENTCTL" phases --since "last tuesday" >/dev/null 2>&1; echo $?)"
chk_contains "V6 and the message names both accepted grammars" "RFC3339" \
  "$(bash "$AGENTCTL" phases --since "last tuesday" 2>&1)"
chk_eq "V7 a naive RFC3339 instant is refused: UTC skew must not hide in the numbers" 1 \
  "$(bash "$AGENTCTL" phases --since "2026-09-02T00:00:00" >/dev/null 2>&1; echo $?)"
chk_eq "V8 the relative grammar works in all three units" "0 0 0" \
  "$(for unit in 30m 2h 1d; do bash "$AGENTCTL" phases --since "$unit" >/dev/null 2>&1; printf '%s ' $?; done | sed 's/ $//')"

summary
