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

summary
