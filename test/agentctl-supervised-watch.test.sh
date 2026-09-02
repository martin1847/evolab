#!/usr/bin/env bash
# supervised watch — the sensing loop lives in tmux, `agentctl watch` is a dumb waiter.
#
# Threat this exists for (downstream seat, production): the host reaps orchestrator-side
# background tasks (2026-08-08: ≥6 kills in 40min across two parallel sessions) while the tmux
# worker rides it out untouched. Pre-supervision that killed the SENSING loop, and every
# non-DONE conclusion it had computed died unpublished — the re-arm round became routine cost.
#
# Every stimulus below enters through the PUBLIC CLI (`agentctl watch/steer/stop`, `duplexctl
# identity …`), a REAL classify exit, or an OS signal. Nothing here hand-writes a terminal record
# and then reads it back: a reader fed by a writer that is really the same fixture cannot catch a
# common-mode error, so the records under test are always produced by the shipped publisher.
#
# Harness: a PROCESS-RUNNING fake tmux (new-session really runs the pane command, refuses a
# duplicate name like the real one, kill-session kills the tree) plus hand-seeded session state
# for the classify-driven classes — same stance as duplex-verdict-gaps. Real `sleep`: the timing
# of "supervisor still sensing" vs "waiter polled again" is part of what is under test.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL="$AW_DIR/agentctl"
DUPLEXCTL="$AW_DIR/duplexctl.py"

# ── harness ───────────────────────────────────────────────────────────────────────────
sw_sandbox() {
  sandbox_new
  rm -f "$BIN/sleep"                     # real sleep: the poll cadence IS part of the contract
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
alive() { # $1 name
  local p; p="$(cat "$FAKE_TMUX_STATE/$1.pid" 2>/dev/null)" || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
killtree() { # what real tmux + agentctl's reap do to a pane: the WHOLE tree, not just the child
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done
  kill -9 "$p" 2>/dev/null
}
case "$sub" in
  new-session)
    # real tmux refuses a duplicate session name server-side, ATOMICALLY. mkdir is this
    # harness's equivalent claim: a check-then-write would let two racing waiters both
    # "win" and would make the singleton property untestable.
    if ! mkdir "$FAKE_TMUX_STATE/$name.lock" 2>/dev/null; then
      if [ -f "$FAKE_TMUX_STATE/$name.pid" ] && ! alive "$name"; then :   # dead: reclaim
      else echo "duplicate session: $name" >&2; exit 1; fi
    fi
    ( cd "${cwd:-/}" && exec bash -c "$cmd" ) >/dev/null 2>&1 &
    echo $! > "$FAKE_TMUX_STATE/$name.pid"
    printf '%s\n' "$name" >> "$FAKE_TMUX_STATE/new-session.log"
    printf '%s\t%s\n' "$name" "$cmd" >> "$FAKE_TMUX_STATE/new-session.cmd.log"
    exit 0 ;;
  has-session) alive "$name" ;;
  kill-session)
    p="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)"
    [ -n "$p" ] && killtree "$p"
    rm -f "$FAKE_TMUX_STATE/$name.pid"; rmdir "$FAKE_TMUX_STATE/$name.lock" 2>/dev/null
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/tmux"
  WT="$SANDBOX/wt"; mkdir -p "$WT"
  SLEEPERS=""
  export AGENT_WATCH_POLL_SECS=1
}

sw_clean() {
  local p n
  for p in $SLEEPERS; do kill -9 "$p" 2>/dev/null; done
  for n in "$FAKE_TMUX_STATE"/*.pid; do
    [ -f "$n" ] || continue
    p="$(cat "$n")"; pkill -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null
  done
  sandbox_clean
}

# A session tmux believes is alive: classify's liveness probe must pass, and `stop`/`kill-session`
# must have something real to kill. Its pid is a sleeper we own, never the test shell's.
seed() { # $1 name  [$2 pane_pid]
  /bin/sleep 600 & local sl=$!
  disown "$sl" 2>/dev/null || true
  SLEEPERS="$SLEEPERS $sl"
  echo "$sl" > "$FAKE_TMUX_STATE/$1.pid"
  { printf 'engine=claude\ncwd=%s\nround=1\n' "$WT"
    [ -n "${2:-}" ] && printf 'pane_pid=%s\n' "$2"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  : > "$WATCH_RUN_DIR/$1.duplex.stderr.log"
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
}

ev() { printf '%s\n' "$2" >> "$WATCH_RUN_DIR/$1.duplex.events.jsonl"; }
running() { ev "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'; }

await() { # $1 label-less predicate as a command string, $2 tries (0.1s each)
  local i=0
  while [ "$i" -lt "${2:-100}" ]; do
    eval "$1" && return 0
    /bin/sleep 0.1; i=$((i+1))
  done
  return 1
}

watch_bg() { # $1 session  $2 outfile  [$3.. env assignments already exported by caller]
  bash "$AGENTCTL" watch "$1" > "$2" 2>&1 &
  WPID_BG=$!
}

lease_pid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' \
                "$WATCH_RUN_DIR/$1.watch.super.json" 2>/dev/null; }
spawn_count() { grep -c "^$1-watchd\$" "$FAKE_TMUX_STATE/new-session.log" 2>/dev/null || echo 0; }
record_class() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("class",""))' \
                   "$WATCH_RUN_DIR/$1.terminal.json" 2>/dev/null; }
record_round() { # the live record, else the one a waiter already DELIVERED (rotated to consumed)
  local f="$WATCH_RUN_DIR/$1.terminal.json"
  [ -s "$f" ] || f="$WATCH_RUN_DIR/$1.terminal.consumed.json"
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("round",""))' "$f" 2>/dev/null; }
# FOLLOW MIGRATION (2026-09-01): `agentctl watch` follows its session by default — a reported
# WATCH-TIMEOUT 7, or a 12 whose supervisor provably died, re-arms instead of ending the waiter.
# Every arm below that asserts the SINGLE-ROUND exit for one of those two outcomes pins
# AGENT_WATCH_FOLLOW_MAX=0 (the ceiling of automatic re-arms), which reproduces the pre-follow
# waiter verdict for verdict — no expected code and no assertion changed. Following itself is
# asserted in its own FL section at the end of this file. Arms that end on an ACTION verdict, on
# a 12 whose liveness fact is `unknown` (retired, rogue, wedged, unreadable), or on `--inline`
# are untouched: none of them can follow, and leaving them bare is the evidence of that.

# Drive one class to a published record with NO waiter attached at publish time: arm a waiter on a
# RUNNING fixture, TERM it (the production failure mode), and only then make classify terminal.
# That is the window the whole workstream exists for.
kill_waiter_then() { # $1 session  $2 shell snippet that makes classify terminal
  watch_bg "$1" "$SANDBOX/$1.w1.log"
  await "[ -s '$WATCH_RUN_DIR/$1.watch.super.json' ]" 100 || return 1
  kill -TERM "$WPID_BG" 2>/dev/null
  wait "$WPID_BG" 2>/dev/null; W1RC=$?
  eval "$2"
  await "[ -s '$WATCH_RUN_DIR/$1.terminal.json' ]" 200 || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M15/M09/M06: the canonical command really supervises; all eight classes survive =="
sw_sandbox

# fixtures: (class, exit, snippet that turns a RUNNING seeded session into that class)
run_class() { # $1 session  $2 expected-exit  $3 make-terminal snippet  $4 needle
  seed "$1" 70000
  running "$1"
  export AGENT_WATCH_MAX_POLLS=1000
  kill_waiter_then "$1" "$3" || { _record "M09 $1 fixture reached a published record" 0 "timeout"; return; }
  chk_eq "M09 $1: the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M09 $1: the supervisor published the class, not the waiter" \
    "$(python3 -c 'import json,sys;print({0:"DONE",2:"FAILED",4:"WAITING-INPUT",5:"STALLED-EXTERNAL",6:"IDLE-NO-DELIVERABLE",7:"WATCH-TIMEOUT",8:"ENGINE-SILENT",11:"STALLED-STREAM"}[int(sys.argv[1])])' "$2")" \
    "$(record_class "$1")"
  before="$(spawn_count "$1")"
  out="$(bash "$AGENTCTL" watch "$1" 2>&1)"; rc=$?
  chk_eq "M09 $1: a brand-new waiter recovers exit $2 from the record" "$2" "$rc"
  chk_contains "M09 $1: and reproduces the class line" "$4" "$out"
  chk_eq "M09 $1: recovery re-derived nothing (no second supervisor)" "$before" "$(spawn_count "$1")"
}

WTB="$WT/blocked"; mkdir -p "$WTB"
run_class swDONE 0 'printf "0\n" > "$WATCH_RUN_DIR/swDONE.duplex.rc"' "DONE"
run_class swFAIL 2 'printf "3\n" > "$WATCH_RUN_DIR/swFAIL.duplex.rc"' "FAILED"
run_class swWAIT 4 'printf "need a decision\n" > "$WT/BLOCKED.md"' "WAITING-INPUT"
rm -f "$WT/BLOCKED.md"
run_class swQUOTA 5 'printf "insufficient_quota\n" >> "$WATCH_RUN_DIR/swQUOTA.duplex.stderr.log"; printf "1\n" > "$WATCH_RUN_DIR/swQUOTA.duplex.rc"' "STALLED-EXTERNAL"
run_class swIDLE 6 'printf "deliverable=nope-*.md\n" >> "$WATCH_RUN_DIR/swIDLE.duplex.meta"; printf "0\n" > "$WATCH_RUN_DIR/swIDLE.duplex.rc"' "IDLE-NO-DELIVERABLE"
run_class swSILENT 8 'printf "0" > "$WATCH_RUN_DIR/swSILENT.duplex.sent-offset"; : > "$WATCH_RUN_DIR/swSILENT.duplex.events.jsonl"; export AGENT_WATCH_SILENT_POLLS=2' "ENGINE-SILENT"
unset AGENT_WATCH_SILENT_POLLS

# 11 STALLED-STREAM needs the real stall probe: a wedged provider tree under a fake ps, reached
# through the supervisor's own classify (PATH is forwarded into the pane, so the probe applies).
PSBIN="$SANDBOX/psbin"; mkdir -p "$PSBIN"
# The fixture is selected by a FILE, not by an env var: the supervisor runs in its own pane and
# inherits only what the pane command spells out, so an env-driven fake would silently never
# reach the process actually doing the classifying (probed: it did not).
cat > "$PSBIN/ps" <<'FAKEPS'
#!/bin/sh
fix="$(dirname "$0")/../ps-fixture.txt"
if [ -f "$fix" ] && [ "${3:-}" != "-p" ]; then cat "$fix"; exit 0; fi
exec /bin/ps "$@"
FAKEPS
chmod +x "$PSBIN/ps"
cat > "$SANDBOX/ps-wedged.txt" <<'PS'
70000     1 03:25:01
70001 70000 03:25:00
70002 70001 03:25:00
70003 70002 1-02:00:00
PS
seed swSTALL 70000
running swSTALL
export AGENT_WATCH_MAX_POLLS=1000
OLDPATH="$PATH"; export PATH="$PSBIN:$PATH"
if kill_waiter_then swSTALL 'cp "$SANDBOX/ps-wedged.txt" "$SANDBOX/ps-fixture.txt"; python3 -c "import os,sys,time; os.utime(sys.argv[1],(time.time()-1200,)*2)" "$WATCH_RUN_DIR/swSTALL.duplex.events.jsonl"'; then
  chk_eq "M09 swSTALL: the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M09 swSTALL: STALLED-STREAM persisted by the supervisor" "STALLED-STREAM" "$(record_class swSTALL)"
  before="$(spawn_count swSTALL)"
  out="$(bash "$AGENTCTL" watch swSTALL 2>&1)"; rc=$?
  chk_eq "M09 swSTALL: a brand-new waiter recovers exit 11" 11 "$rc"
  chk_contains "M09 swSTALL: and reproduces the class line" "STALLED-STREAM" "$out"
  chk_eq "M09 swSTALL: recovery re-derived nothing" "$before" "$(spawn_count swSTALL)"
else
  _record "M09 swSTALL: the supervisor published a STALLED-STREAM record" 0 "no record appeared"
fi
rm -f "$SANDBOX/ps-fixture.txt"; export PATH="$OLDPATH"

# 7 WATCH-TIMEOUT is the supervisor's OWN budget running out — no fixture can inject it
seed swTMO 70000
running swTMO
export AGENT_WATCH_MAX_POLLS=3
watch_bg swTMO "$SANDBOX/swTMO.w1.log"
await "[ -s '$WATCH_RUN_DIR/swTMO.watch.super.json' ]" 100
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
chk_eq "M09 swTMO: budget exhaustion is persisted, not lost with the waiter" 1 \
  "$(await "[ -s '$WATCH_RUN_DIR/swTMO.terminal.json' ]" 200 && echo 1 || echo 0)"
chk_eq "M09 swTMO: class recorded" "WATCH-TIMEOUT" "$(record_class swTMO)"
before="$(spawn_count swTMO)"
out="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch swTMO 2>&1)"; rc=$?
chk_eq "M09 swTMO: a brand-new waiter recovers exit 7" 7 "$rc"
chk_contains "M09 swTMO: and reproduces the class line" "WATCH TIMEOUT" "$out"
chk_eq "M09 swTMO: recovery re-derived nothing" "$before" "$(spawn_count swTMO)"

# M15 — the ACTIVATION surface: the canonical command (no flags) is what supervises. If the
# supervisor were an opt-in nobody calls, the log below would be empty and every recovery above
# would have been the old in-process loop.
chk_eq 'M15 DAMAGE ORACLE: the canonical "agentctl watch" established a tmux supervisor per session' 1 \
  "$([ "$(spawn_count swDONE)" -ge 1 ] && echo 1 || echo 0)"
chk_contains "M15 the supervisor pane really runs the sensing verb" "watch-daemon" \
  "$(grep "^swDONE-watchd" "$FAKE_TMUX_STATE/new-session.cmd.log")"
seed swACT 70000; running swACT
export AGENT_WATCH_MAX_POLLS=1000
watch_bg swACT "$SANDBOX/swACT.log"
await "[ -s '$WATCH_RUN_DIR/swACT.watch.super.json' ]" 100
/bin/sleep 1
chk_contains "M15 the canonical waiter names the tmux session sensing for it" "swACT-watchd" \
  "$(cat "$SANDBOX/swACT.log")"
chk_contains "M15 and says it is only reading the fenced record" "only reads the fenced" \
  "$(cat "$SANDBOX/swACT.log")"
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
chk_contains "M15 the published capability contract says supervised" "supervised" \
  "$(bash "$AGENTCTL" capabilities 2>&1)"

# M06 — a same-name NEW attempt must not ADOPT attempt A's conclusion, for ANY of the classes.
# `identity replace` is the public rotation; A's records stay exactly where they are. The oracle
# is the canonical reader's adoption decision, not the exit code: B legitimately RE-DERIVES the
# same class from the same live facts (the rc file still says 3), and calling that a replay would
# make this test pass for the wrong reason.
for s in swDONE swFAIL swWAIT swQUOTA swIDLE swSILENT swSTALL swTMO; do
  [ -s "$WATCH_RUN_DIR/$s.terminal.json" ] || cp "$WATCH_RUN_DIR/$s.terminal.consumed.json" \
     "$WATCH_RUN_DIR/$s.terminal.json" 2>/dev/null || true
done
m6_adopted=0; m6_unfenced=0; m6_seen=0
for s in swDONE swFAIL swWAIT swQUOTA swIDLE swSILENT swSTALL swTMO; do
  [ -s "$WATCH_RUN_DIR/$s.terminal.json" ] || { echo "    (M06 $s: no record of either kind)"; continue; }
  m6_seen=$((m6_seen+1))
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace "$s" >/dev/null 2>&1
  out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state "$s" --arm 2>&1)"; rc=$?
  [ "$rc" = 13 ] || { m6_adopted=$((m6_adopted+1)); echo "    (M06 $s: attempt B adopted A's record, rc=$rc)"; }
  case "$out" in *STALE-ATTEMPT*) ;; *) m6_unfenced=$((m6_unfenced+1)); echo "    (M06 $s: refusal did not name the attempt fence: $out)";; esac
done
chk_eq "M06 arrange: every class left a record for attempt B to trip over" 8 "$m6_seen"
chk_eq "M06 DAMAGE ORACLE: attempt B adopts NONE of attempt A's conclusions" 0 "$m6_adopted"
chk_eq "M06 and every refusal names the attempt fence" 0 "$m6_unfenced"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M01/M02: a killed waiter loses nothing; the conclusion is produced once =="
sw_sandbox
seed m1 70000; running m1
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m1 "$SANDBOX/m1.w1.log"
await "[ -s '$WATCH_RUN_DIR/m1.watch.super.json' ]" 100
SUPPID="$(lease_pid m1)"
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null; w1rc=$?
chk_eq "M01 the original waiter exited on TERM (143)" 143 "$w1rc"
chk_eq "M01 the supervisor is untouched by the waiter's death" 1 \
  "$(kill -0 "$SUPPID" 2>/dev/null && echo 1 || echo 0)"
chk_eq "M01 the killed waiter left an attributable tombstone" 1 \
  "$([ -s "$WATCH_RUN_DIR/m1.watch.tombstone.jsonl" ] && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m1.duplex.rc"          # real classify turns terminal
await "[ -s '$WATCH_RUN_DIR/m1.terminal.json' ]" 200
spawns="$(spawn_count m1)"
evsize="$(wc -c < "$WATCH_RUN_DIR/m1.duplex.events.jsonl" | tr -d ' ')"
out="$(bash "$AGENTCTL" watch m1 2>&1)"; rc=$?
chk_eq "M01 the replacement waiter returns the same class + exit" 0 "$rc"
chk_contains "M01 and prints the supervisor's own verdict line" "DONE" "$out"
chk_eq "M01 DAMAGE ORACLE: it did NOT restart classification (no new supervisor)" "$spawns" "$(spawn_count m1)"
chk_eq "M01 and produced no new engine traffic" "$evsize" \
  "$(wc -c < "$WATCH_RUN_DIR/m1.duplex.events.jsonl" | tr -d ' ')"

# M01b — the reaped waiter must leave NO LIVE READER behind, and the oracle is a process
# census rather than a race: the M01 kill above lands while the waiter is still ARMING, so it
# never covered the state the production reaper actually hits — a waiter parked in its polling
# read. `on_sig` kills `$CHILD`, and until this fix `$CHILD` named a wrapper subshell (bash
# forks one when a shell FUNCTION is backgrounded), so the canonical READER survived the TERM,
# re-parented to init, and went on to DELIVER this round's conclusion — rotating
# `<s>.terminal.json` to `.consumed.json` — for a waiter that was already dead. The next
# `agentctl watch` then correctly refuses to replay a spent record, re-establishes a SECOND
# supervisor and re-derives the class it already had: seen on Linux CI as M09 swSILENT
# "recovery re-derived nothing" expected[1] got[2], and reproduced locally by delaying the
# recovery by one reader poll.
# The census is fenced to THIS run: the reader's argv carries `--run-dir <run> watch-wait <s>`
# adjacently, and a global `ps` sees every worktree, every parallel suite and any unrelated
# process that happens to share the verb — matching the bare verb made a decoy elsewhere on the
# box a false red (review NB1, reproduced). The match is a literal substring test (`case`, not
# `grep`) so the probe cannot find ITSELF in the snapshot it is reading, and the trailing space
# keeps a session name from matching a longer one.
reader_alive() { # $1 session — a canonical reader (watch-wait) of THIS run still polling for it
  local snap; snap="$(ps -A -o args= 2>/dev/null)"
  case "$snap" in *"--run-dir $WATCH_RUN_DIR watch-wait $1 "*) return 0;; esac
  return 1
}
seed m1b 70000; running m1b
watch_bg m1b "$SANDBOX/m1b.w1.log"
# the waiter announces the supervisor it will read FROM immediately before it enters that
# polling read, so this line — not the lease — is the proof it reached the reaped state
chk_eq "M01b arrange: the waiter really reached its polling read" 1 \
  "$(seen "$SANDBOX/m1b.w1.log" "m1b-watchd" 150)"
await "reader_alive m1b" 100
chk_eq "M01b arrange: and the canonical reader was observably running" 1 \
  "$(reader_alive m1b && echo 1 || echo 0)"
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null; m1brc=$?
chk_eq "M01b the reaped waiter exited on TERM (143)" 143 "$m1brc"
chk_eq "M01b DAMAGE ORACLE: it left no live reader that could consume the conclusion" 0 \
  "$(await '! reader_alive m1b' 100 && echo 0 || echo 1)"
# m1b's supervisor is the only one in this block left SENSING (nothing made it terminal), and a
# spare classify-per-second for the rest of the block is load this suite never had: retire it
# here rather than at sw_clean, the same way M03 kills a supervisor it is done with.
tmux kill-session -t "=m1b-watchd" 2>/dev/null

# M02 — the conclusion exists but no waiter has reported it yet: kill and re-invoke repeatedly.
# One record, one publish sequence, same answer every time.
seq_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
             "$WATCH_RUN_DIR/m1.terminal.json"; }
seed m2 70000; running m2
watch_bg m2 "$SANDBOX/m2.w1.log"
await "[ -s '$WATCH_RUN_DIR/m2.watch.super.json' ]" 100
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null
printf '0\n' > "$WATCH_RUN_DIR/m2.duplex.rc"
await "[ -s '$WATCH_RUN_DIR/m2.terminal.json' ]" 200
m2seq="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' "$WATCH_RUN_DIR/m2.terminal.json")"
r1="$(bash "$AGENTCTL" watch m2 >/dev/null 2>&1; echo $?)"
r2="$(bash "$AGENTCTL" watch m2 >/dev/null 2>&1; echo $?)"
chk_eq "M02 first re-invocation reports the conclusion" 0 "$r1"
chk_eq "M02 second re-invocation reports the SAME conclusion" 0 "$r2"
chk_eq "M02 DAMAGE ORACLE: no second classification side effect (publish seq unmoved)" "$m2seq" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' "$WATCH_RUN_DIR/m2.terminal.json")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M03/M04/M05: dead vs alive vs concluded-then-dead =="
sw_sandbox

# M03 — the worker is fine, the SUPERVISOR is killed, and there is no conclusion.
seed m3 70000; running m3
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_FOLLOW_MAX=0   # follow migration: single-round 12
watch_bg m3 "$SANDBOX/m3.w.log"
await "[ -s '$WATCH_RUN_DIR/m3.watch.super.json' ]" 100
kill -9 "$(lease_pid m3)" 2>/dev/null
t0=$(date +%s)
wait "$WPID_BG" 2>/dev/null; rc=$?
el=$(( $(date +%s) - t0 ))
out="$(cat "$SANDBOX/m3.w.log")"
chk_eq "M03 DAMAGE ORACLE: a dead supervisor with no conclusion is typed 12, never 0" 12 "$rc"
chk_contains "M03 the class is named" "SUPERVISOR-LOST" "$out"
chk_contains "M03 the reason distinguishes death from undecidability" "reason=dead" "$out"
chk_not_contains "M03 a lost supervisor is never DONE" "=== [m3] DONE" "$out"
chk_eq "M03 and it returned bounded (< 60s), never silently waited" 1 "$([ "$el" -lt 60 ] && echo 1 || echo 0)"
chk_eq "M03 the worker session was never touched" 1 \
  "$(tmux has-session -t "=m3" 2>/dev/null && echo 1 || echo 0)"
unset AGENT_WATCH_FOLLOW_MAX

# M04 PAIRED GREEN — supervisor alive, classify honestly RUNNING, waiter across several cycles.
seed m4 70000; running m4
watch_bg m4 "$SANDBOX/m4.w.log"
await "[ -s '$WATCH_RUN_DIR/m4.watch.super.json' ]" 100
/bin/sleep 4                                   # ≥3 waiter poll cycles at POLL=1
chk_eq "M04 DAMAGE ORACLE: a live supervisor is never reported dead" 1 \
  "$(kill -0 "$WPID_BG" 2>/dev/null && echo 1 || echo 0)"
out="$(cat "$SANDBOX/m4.w.log")"
chk_not_contains "M04 no SUPERVISOR-LOST while it is sensing" "SUPERVISOR-LOST" "$out"
chk_not_contains "M04 no terminal verdict invented while RUNNING" "EXIT=" "$out"
chk_eq "M04 and RUNNING produced no terminal record" 0 \
  "$([ -e "$WATCH_RUN_DIR/m4.terminal.json" ] && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m4.duplex.rc"   # the real terminal still arrives
wait "$WPID_BG" 2>/dev/null; rc=$?
chk_eq "M04 PAIRED GREEN: the waiter that did not panic still gets the real class" 0 "$rc"

# M05 — publish and death are visible at the same instant: the fenced record wins.
seed m5 70000
printf '0\n' > "$WATCH_RUN_DIR/m5.duplex.rc"   # terminal on the FIRST poll: publish, then exit
export AGENT_WATCH_MAX_POLLS=1000
out="$(bash "$AGENTCTL" watch m5 2>&1)"; rc=$?
chk_eq "M05 DAMAGE ORACLE: 'supervisor exited' never overrides its own conclusion" 0 "$rc"
chk_contains "M05 the conclusion is the one the supervisor published" "DONE" "$out"
chk_not_contains "M05 and it is not reported as a lost supervisor" "SUPERVISOR-LOST" "$out"
chk_eq "M05 arrange: the supervisor really is gone by now" 0 \
  "$(await "! kill -0 $(lease_pid m5) 2>/dev/null" 100 && echo 0 || echo 1)"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M07/M08: incarnation and round do not leak across a resume or a steer =="
sw_sandbox

# M07 — same attempt, new process incarnation (the supported resume transition). The record the
# previous incarnation published must not be adopted, and must not read as a death either.
seed m7 70000
printf '0\n' > "$WATCH_RUN_DIR/m7.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
rc0="$(bash "$AGENTCTL" watch m7 >/dev/null 2>&1; echo $?)"
chk_eq "M07 arrange: incarnation A published a real DONE record" 0 "$rc0"
inc_a="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
          "$WATCH_RUN_DIR/m7.identity.d/active.json")"
printf 'pane_pid=%s\npane_lstart=%s\n' "$$" "resumed-at-a-different-time" >> "$WATCH_RUN_DIR/m7.duplex.meta"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity resume m7 >/dev/null 2>&1
inc_b="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
          "$WATCH_RUN_DIR/m7.identity.d/active.json")"
chk_eq "M07 arrange: the attempt is unchanged but the incarnation rotated" 1 \
  "$([ "$inc_a" != "$inc_b" ] && echo 1 || echo 0)"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5
out="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch m7 2>&1)"; rc=$?
chk_eq "M07 DAMAGE ORACLE: the old incarnation's DONE is not adopted after resume" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_not_contains "M07 no false DONE across the incarnation boundary" "=== [m7] DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES

# M08 — a plain steer opens the NEXT round. The previous round's conclusion must not be replayed,
# and a conclusion computed for the previous round must be refused at publish (the round fence).
seed m8 70000
printf '0\n' > "$WATCH_RUN_DIR/m8.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
bash "$AGENTCTL" watch m8 >/dev/null 2>&1
chk_eq "M08 arrange: round 1 concluded DONE and the record is on disk" 1 \
  "$([ -s "$WATCH_RUN_DIR/m8.terminal.json" ] && echo 1 || echo 0)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m8)"
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/m8.duplex.meta"; rm -f "$WATCH_RUN_DIR/m8.duplex.meta.bak"
rm -f "$WATCH_RUN_DIR/m8.terminal.json"       # what `agentctl steer` does when it opens a round
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m8 --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion about round 1" 2>&1)"; prc=$?
chk_eq "M08 DAMAGE ORACLE: a conclusion computed for the previous round is refused" 2 "$prc"
chk_contains "M08 the refusal names the round fence" "STALE-ROUND" "$pout"
chk_eq "M08 and nothing was written" 0 \
  "$([ -e "$WATCH_RUN_DIR/m8.terminal.json" ] && echo 1 || echo 0)"
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m8 --armed "$armed" \
        --rc 0 --round 2 --detail "conclusion about round 2" 2>&1)"; prc=$?
chk_eq "M08 PAIRED GREEN: the CURRENT round's conclusion publishes" 0 "$prc"
chk_eq "M08 PAIRED GREEN: and a waiter reports it" 0 \
  "$(bash "$AGENTCTL" watch m8 >/dev/null 2>&1; echo $?)"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M10: RUNNING is not a terminal state and never becomes a record =="
sw_sandbox
seed m10 70000; running m10
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m10 "$SANDBOX/m10.a.log"
await "[ -s '$WATCH_RUN_DIR/m10.watch.super.json' ]" 100
/bin/sleep 2
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null
chk_eq "M10 DAMAGE ORACLE: repeated real RUNNING never produces a terminal record" 0 \
  "$([ -e "$WATCH_RUN_DIR/m10.terminal.json" ] && echo 1 || echo 0)"
watch_bg m10 "$SANDBOX/m10.b.log"
/bin/sleep 2
chk_eq "M10 the restarted waiter keeps waiting instead of reporting" 1 \
  "$(kill -0 "$WPID_BG" 2>/dev/null && echo 1 || echo 0)"
chk_not_contains "M10 it reported no stale class" "EXIT=" "$(cat "$SANDBOX/m10.b.log")"
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M11/M12: a publish that did not land, and a record that cannot be trusted =="
sw_sandbox

# M11 — the publisher is SIGKILLed between "temp file complete" and rename (the shipped test
# seam), inside the real supervisor. Debris must never be adopted and must not read as DONE.
seed m11 70000
printf '0\n' > "$WATCH_RUN_DIR/m11.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000 AGENTCTL_PUBLISH_BARRIER="$SANDBOX/barrier"
out="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch m11 2>&1)"; rc=$?
unset AGENTCTL_PUBLISH_BARRIER
chk_eq "M11 arrange: the interruption window was really reached" 1 \
  "$([ -s "$SANDBOX/barrier" ] && echo 1 || echo 0)"
chk_eq "M11 DAMAGE ORACLE: an interrupted publish never becomes a conclusion" 12 "$rc"
chk_not_contains "M11 no DONE from publish debris" "=== [m11] DONE" "$out"
chk_eq "M11 no terminal record exists" 0 \
  "$([ -e "$WATCH_RUN_DIR/m11.terminal.json" ] && echo 1 || echo 0)"

# M11b — the publish target cannot be written at all: the supervisor must say so, publish nothing.
seed m11b 70000
printf '0\n' > "$WATCH_RUN_DIR/m11b.duplex.rc"
chmod 500 "$WATCH_RUN_DIR"
out="$(bash "$AGENTCTL" watch m11b 2>&1)"; rc=$?
chmod 700 "$WATCH_RUN_DIR"
chk_eq "M11b DAMAGE ORACLE: an unwritable record surface is never a DONE" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "M11b the refusal carries the structural reason, not just an error" \
  "PUBLISH_INTERRUPTED" "$out"
chk_contains "M11b and states that nothing was published" "no terminal conclusion published" "$out"
chk_eq "M11b no record was left behind" 0 \
  "$([ -e "$WATCH_RUN_DIR/m11b.terminal.json" ] && echo 1 || echo 0)"
# the degradation is the documented one, and it is LOUD: an unwritable run dir also means no
# lease, so the supervisor cannot be established and the waiter says so before falling back
chk_contains "M11b the fallback to the in-process loop is announced, never silent" \
  "NOT kill-resilient" "$out"

# M12 — every way a record can be untrustworthy, judged with the supervisor already gone so the
# reader has to answer on the record alone. Each variant: fail closed, never DONE, never guessed.
seed m12 70000
printf '0\n' > "$WATCH_RUN_DIR/m12.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
bash "$AGENTCTL" watch m12 >/dev/null 2>&1
cp "$WATCH_RUN_DIR/m12.terminal.json" "$SANDBOX/m12.good.json"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5 AGENT_WATCH_FOLLOW_MAX=0
damage() { # $1 label  $2 shell that installs the damaged record
  rm -f "$WATCH_RUN_DIR/m12.terminal.json"
  eval "$2"
  out="$(bash "$AGENTCTL" watch m12 2>&1)"; rc=$?
  chk_eq "M12 $1: never reported as DONE 0" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
  chk_not_contains "M12 $1: no DONE line" "=== [m12] DONE" "$out"
}
damage "truncated JSON" 'head -c 40 "$SANDBOX/m12.good.json" > "$WATCH_RUN_DIR/m12.terminal.json"'
damage "illegal class for the exit" \
  'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));m[\"class\"]=\"DONE\";m[\"rc\"]=7;json.dump(m,open(sys.argv[2],\"w\"))" "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "exit outside the terminal vocabulary" \
  'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));m[\"rc\"]=99;m[\"class\"]=\"DONE\";json.dump(m,open(sys.argv[2],\"w\"))" "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "record is a symlink out of the run dir" \
  'ln -s "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "record is a fifo" 'mkfifo "$WATCH_RUN_DIR/m12.terminal.json"'
rm -f "$WATCH_RUN_DIR/m12.terminal.json"
damage "unreadable record" 'cp "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"; chmod 000 "$WATCH_RUN_DIR/m12.terminal.json"'
chmod 600 "$WATCH_RUN_DIR/m12.terminal.json"
# PAIRED GREEN: the undamaged record of the same session still reads as DONE
cp "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"
out="$(bash "$AGENTCTL" watch m12 2>&1)"; rc=$?
chk_eq "M12 PAIRED GREEN: the intact record still reports DONE 0" 0 "$rc"
chk_contains "M12 PAIRED GREEN: with its own verdict line" "DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES AGENT_WATCH_FOLLOW_MAX
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M13: two waiters, ONE supervisor, one answer =="
sw_sandbox
seed m13 70000; running m13
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m13 "$SANDBOX/m13.a.log"; A=$WPID_BG
watch_bg m13 "$SANDBOX/m13.b.log"; B=$WPID_BG
await "[ -s '$WATCH_RUN_DIR/m13.watch.super.json' ]" 100
/bin/sleep 2
chk_eq "M13 DAMAGE ORACLE: concurrent waiters established exactly ONE supervisor" 1 "$(spawn_count m13)"
chk_eq "M13 and exactly one sensing process is alive" 1 \
  "$(kill -0 "$(lease_pid m13)" 2>/dev/null && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m13.duplex.rc"
wait "$A" 2>/dev/null; arc=$?
wait "$B" 2>/dev/null; brc=$?
chk_eq "M13 waiter A reports the fenced conclusion" 0 "$arc"
chk_eq "M13 waiter B reports the SAME fenced conclusion" 0 "$brc"
chk_eq "M13 one publish, not two (single authority)" 1 \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
      "$WATCH_RUN_DIR/m13.terminal.json")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M14: stop / --interrupt retire the supervisor; late conclusions are refused =="
sw_sandbox

# stop mid-sensing: the loop is retired, and a conclusion it computes afterwards cannot land.
seed m14 70000; running m14
# follow migration: this section asserts the two lifecycle actions that RETIRE a waiter's
# supervisor. A re-arm racing a teardown would be a second claim in the same arm (and would
# publish a fresh lease for a session `stop` just cleaned), so both arms stay single-round.
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_FOLLOW_MAX=0
watch_bg m14 "$SANDBOX/m14.w.log"
await "[ -s '$WATCH_RUN_DIR/m14.watch.super.json' ]" 100
sup="$(lease_pid m14)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m14)"
bash "$AGENTCTL" stop m14 >/dev/null 2>&1
wait "$WPID_BG" 2>/dev/null
chk_eq "M14 DAMAGE ORACLE: stop reaped the sensing loop" 0 \
  "$(await "! kill -0 $sup 2>/dev/null" 100 && echo 0 || echo 1)"
chk_eq "M14 stop removed the supervisor lease" 0 \
  "$([ -e "$WATCH_RUN_DIR/m14.watch.super.json" ] && echo 1 || echo 0)"
# `--round` is REQUIRED by the publisher since R3, so the probe supplies the round this
# session is really on — otherwise the publish is refused for the missing fence and never
# reaches the identity fence under test.
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m14 --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion from a stopped session" 2>&1)"; prc=$?
chk_eq "M14 a retired supervisor's late conclusion is refused" 2 "$prc"
chk_eq "M14 and it resurrected nothing" 0 \
  "$([ -e "$WATCH_RUN_DIR/m14.terminal.json" ] && echo 1 || echo 0)"

# --interrupt mid-sensing: new attempt, old supervisor retired, late conclusion fenced out.
seed m14r 70000; running m14r
mkfifo "$WATCH_RUN_DIR/m14r.duplex.in" 2>/dev/null || true
watch_bg m14r "$SANDBOX/m14r.w.log"
await "[ -s '$WATCH_RUN_DIR/m14r.watch.super.json' ]" 100
sup="$(lease_pid m14r)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m14r)"
bash "$AGENTCTL" steer m14r -m "start over" --interrupt >/dev/null 2>&1
chk_eq "M14 DAMAGE ORACLE: --interrupt reaped the supervisor armed under the old attempt" 0 \
  "$(await "! kill -0 $sup 2>/dev/null" 100 && echo 0 || echo 1)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace m14r >/dev/null 2>&1
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m14r --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion from the previous attempt" 2>&1)"; prc=$?
chk_eq "M14 the old attempt's late conclusion is refused" 2 "$prc"
chk_contains "M14 the refusal names the attempt fence" "STALE-ATTEMPT" "$pout"
wait "$WPID_BG" 2>/dev/null; wrc=$?
chk_eq "M14 the attached waiter is told, typed, that its supervisor is gone" 12 "$wrc"
# `--interrupt` retires the loop BEFORE the attempt actually rotates, so the honest word on the
# host surface is the retirement, not a fence class that has not fired yet — the fence class is
# asserted above, on the publish that really is refused. What must never happen is a silent or
# mysterious death: the waiter says it lost its supervisor AND why.
chk_contains "M14 the host surface names the lifecycle action that retired the loop" \
  "SUPERVISOR-RETIRED" "$(cat "$SANDBOX/m14r.w.log")"
chk_contains "M14 and points at the verb responsible" "--interrupt" "$(cat "$SANDBOX/m14r.w.log")"
chk_contains "M14 and states no conclusion was published" "no terminal conclusion published" \
  "$(cat "$SANDBOX/m14r.w.log")"
chk_not_contains "M14 a retired supervisor never yields a DONE" "=== [m14r] DONE" \
  "$(cat "$SANDBOX/m14r.w.log")"
unset AGENT_WATCH_FOLLOW_MAX
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M14b: the retirement note is published BEFORE the lease it explains disappears =="
sw_sandbox
# A waiter's typed 12 is produced by ONE observation: no lease. Retirement used to unlink the
# lease first and write its last words afterwards, so a waiter reading inside that window got a
# correct 12 with NO cause — safe, but a mystery death is exactly what the note exists to
# prevent, and the M14 relay assertions above went flaky (which teaches re-running to green).
# The window is too short to hit by polling, so this pins the WORST observation instant: an
# `rm` shim looks at the run dir the moment the lease is unlinked, and runs the canonical
# reader out of process — the read `agentctl watch` would have made had it polled right then.
#
# What is asserted is the ORDER (note on disk before the evidence that triggers the verdict),
# never which verdict the reader reaches: a conclusion published before the retirement landed
# outranks supervisor loss by design (`watch_state` priority 1), so pinning 12 here would be
# pinning a race. The reader is kept for the oracle below — whatever verdict it gives, a
# SUPERVISOR-LOST in this window must never be a bare one.
cat > "$BIN/rm" <<'EOF'
#!/usr/bin/env bash
tgt=""
for a in "$@"; do case "$a" in *.watch.super.json) tgt="$a";; esac; done
/bin/rm "$@"; rc=$?
if [ -n "$tgt" ] && [ -n "${RETIRE_PROBE_LOG:-}" ]; then
  d="${tgt%/*}"; s="${tgt##*/}"; s="${s%.watch.super.json}"
  { if [ -s "$d/$s.watch.super.exit" ]; then
      printf 'note-present: %s\n' "$(cat "$d/$s.watch.super.exit")"
    else printf 'note-absent\n'; fi
    python3 "$RETIRE_PROBE_CTL" --run-dir "$d" watch-state "$s" 2>&1; echo "rc=$?"
  } >> "$RETIRE_PROBE_LOG"
fi
exit "$rc"
EOF
chmod +x "$BIN/rm"
seed m14o 70000; running m14o
mkfifo "$WATCH_RUN_DIR/m14o.duplex.in" 2>/dev/null || true
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_FOLLOW_MAX=0   # follow migration: see M14
watch_bg m14o "$SANDBOX/m14o.w.log"
await "[ -s '$WATCH_RUN_DIR/m14o.watch.super.json' ]" 100
PROBE="$SANDBOX/m14o.probe.log"
RETIRE_PROBE_LOG="$PROBE" RETIRE_PROBE_CTL="$DUPLEXCTL" \
  bash "$AGENTCTL" steer m14o -m "start over" --interrupt >/dev/null 2>&1
wait "$WPID_BG" 2>/dev/null
probe="$(cat "$PROBE" 2>/dev/null)"
chk_contains "M14b the last words are already on disk when the lease is unlinked" \
  "note-present" "$probe"
chk_not_contains "M14b DAMAGE ORACLE: the lease never vanishes ahead of the note" \
  "note-absent" "$probe"
chk_contains "M14b and they name the lifecycle action that retired the loop" \
  "SUPERVISOR-RETIRED" "$probe"
chk_contains "M14b and the verb responsible" "--interrupt" "$probe"
chk_contains "M14b and state that nothing was concluded" "no terminal conclusion published" \
  "$probe"
chk_eq "M14b DAMAGE ORACLE: no SUPERVISOR-LOST read in that window is left without last words" \
  "$(printf '%s\n' "$probe" | grep -c 'SUPERVISOR-LOST')" \
  "$(printf '%s\n' "$probe" | grep -c "supervisor's last words")"
unset AGENT_WATCH_FOLLOW_MAX
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== legacy --inline: the pre-supervised loop is still exactly available =="
sw_sandbox
seed lg 70000
printf '0\n' > "$WATCH_RUN_DIR/lg.duplex.rc"
export AGENT_WATCH_MAX_POLLS=6
out="$(bash "$AGENTCTL" watch lg --inline 2>&1)"; rc=$?
chk_eq "--inline reaches the same DONE 0" 0 "$rc"
chk_eq "--inline keeps the machine-readable tail" "EXIT=0" "$(printf '%s\n' "$out" | tail -1)"
chk_eq "DAMAGE ORACLE: --inline establishes NO supervisor (that is the point of the flag)" 0 \
  "$(spawn_count lg)"
seed lg2 70000; running lg2
export AGENT_WATCH_MAX_POLLS=2
out="$(bash "$AGENTCTL" watch lg2 --inline 2>&1)"; rc=$?
chk_eq "--inline still exits 7 on its own budget" 7 "$rc"
chk_eq "DAMAGE ORACLE: and --inline persists NOTHING for a non-DONE class (the old loss mode)" 0 \
  "$([ -e "$WATCH_RUN_DIR/lg2.terminal.json" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" watch lg2 --bogus 2>&1)"; rc=$?
chk_eq "an unknown watch option is refused, never silently treated as a session" 1 "$rc"
chk_contains "and the refusal names the option" "unknown watch option" "$out"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R2 — the review's eight execution probes, frozen as assertions. Every one of these was RED
# against the reviewed head (316ecb6) and is the reason the corresponding fix exists. Same
# rules as above: public CLI / canonical shipped reader / real signals only.
# ═════════════════════════════════════════════════════════════════════════════════════════

echo "== F-01: the shipped status / --inline publishers carry the round fence =="
sw_sandbox

# Deterministic version of "a plain steer lands between classify and publish": the identity
# lock is the publisher's own critical section, so holding it parks the shipped publisher at
# exactly that window while the test rotates the round underneath it.
hold_identity_lock() { # $1 session — sets HOLDER (pid); the lock is held until release_lock
  python3 - "$WATCH_RUN_DIR/$1.identity.lock" "$SANDBOX/$1.held" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(120)
PY
  HOLDER=$!
  await "[ -e '$SANDBOX/$1.held' ]" 100
}
release_lock() { kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }

# --- status, the real shipped shape (no --round on the command line) ---------------------
seed f1s 70000
printf 'deliverable=%s\n' "$WT/f1s.md" >> "$WATCH_RUN_DIR/f1s.duplex.meta"
printf 'x\n' > "$WT/f1s.md"
printf '0\n' > "$WATCH_RUN_DIR/f1s.duplex.rc"
hold_identity_lock f1s
bash "$AGENTCTL" status f1s > "$SANDBOX/f1s.out" 2>&1 &
STPID=$!
/bin/sleep 3                     # classify is done; the publish is parked on the lock
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/f1s.duplex.meta"
rm -f "$WATCH_RUN_DIR/f1s.duplex.meta.bak"
release_lock
wait "$STPID" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f1s.out")"
chk_eq "F-01 DAMAGE ORACLE: status cannot publish a round-1 conclusion into round 2" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "F-01 status names the round fence" "STALE-ROUND" "$out"
chk_eq "F-01 and nothing was written" 0 \
  "$([ -e "$WATCH_RUN_DIR/f1s.terminal.json" ] && echo 1 || echo 0)"

# PAIRED GREEN: same shipped shape, no round rotation — status still publishes, stamped with
# the round it actually concluded.
seed f1p 70000
printf 'deliverable=%s\n' "$WT/f1p.md" >> "$WATCH_RUN_DIR/f1p.duplex.meta"
printf 'x\n' > "$WT/f1p.md"
printf '0\n' > "$WATCH_RUN_DIR/f1p.duplex.rc"
rc="$(bash "$AGENTCTL" status f1p >/dev/null 2>&1; echo $?)"
chk_eq "F-01 PAIRED GREEN: an unraced status publishes normally" 0 "$rc"
chk_eq "F-01 PAIRED GREEN: and the record is stamped with the round it concluded" "1" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["round"])' \
       "$WATCH_RUN_DIR/f1p.terminal.json" 2>/dev/null)"

# --- --inline, the other shipped publisher of a DONE marker ------------------------------
seed f1i 70000
printf '0\n' > "$WATCH_RUN_DIR/f1i.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
hold_identity_lock f1i
bash "$AGENTCTL" watch f1i --inline > "$SANDBOX/f1i.out" 2>&1 &
WPID=$!
/bin/sleep 5                     # two stable DONE reads happen at POLL=1; publish then parks
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/f1i.duplex.meta"
rm -f "$WATCH_RUN_DIR/f1i.duplex.meta.bak"
release_lock
wait "$WPID" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f1i.out")"
chk_eq "F-01 DAMAGE ORACLE: --inline cannot publish a round-1 conclusion into round 2" 2 "$rc"
chk_contains "F-01 the inline refusal names the round fence" "STALE-ROUND" "$out"
chk_eq "F-01 and the inline publisher wrote nothing" 0 \
  "$([ -e "$WATCH_RUN_DIR/f1i.terminal.json" ] && echo 1 || echo 0)"
sw_clean

echo "== F-02: two attached waiters converge on the same non-DONE conclusion =="
sw_sandbox
seed f2 70000; running f2
export AGENT_WATCH_MAX_POLLS=1000
# different poll cadences: A reads the conclusion first and delivers it, B arrives seconds
# later. The record A rotated away must still be B's answer — B was attached the whole time.
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch f2 > "$SANDBOX/f2.a.log" 2>&1 &
FA=$!
AGENT_WATCH_POLL_SECS=5 bash "$AGENTCTL" watch f2 > "$SANDBOX/f2.b.log" 2>&1 &
FB=$!
await "[ -s '$WATCH_RUN_DIR/f2.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/f2.duplex.rc"     # real classify → FAILED 2
wait "$FA" 2>/dev/null; arc=$?
wait "$FB" 2>/dev/null; brc=$?
chk_eq "F-02 waiter A reports the class the supervisor published" 2 "$arc"
chk_eq "F-02 DAMAGE ORACLE: waiter B reports the SAME class, never SUPERVISOR-LOST" 2 "$brc"
chk_not_contains "F-02 B was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/f2.b.log")"
chk_eq "F-02 the delivered conclusion is retained, not destroyed" 1 \
  "$([ -s "$WATCH_RUN_DIR/f2.terminal.consumed.json" ] || [ -s "$WATCH_RUN_DIR/f2.terminal.json" ] \
     && echo 1 || echo 0)"
chk_eq "F-02 one supervisor served both" 1 "$(spawn_count f2)"
# and the delivery rule still holds its other end: a waiter that arms AFTER the conclusion was
# delivered senses again instead of replaying it (the duplex-lane re-arm contract). The oracle
# is the sensing, not the exit code — this waiter legitimately RE-DERIVES the same class from
# the same live facts (the rc file still says 3), and calling that a replay would pass for the
# wrong reason.
f2spawns="$(spawn_count f2)"
AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5 bash "$AGENTCTL" watch f2 >/dev/null 2>&1
chk_eq "F-02 PAIRED: a waiter arming after delivery re-senses, it does not replay" 1 \
  "$([ "$(spawn_count f2)" -gt "$f2spawns" ] && echo 1 || echo 0)"
sw_clean

echo "== F-03: a null incarnation on both sides is undecidable, never a match =="
sw_sandbox
# no pane_pid at all: the incarnation signal is unobtainable, which is exactly the pair the
# fence used to collapse to '-' == '-'.
seed f3
chk_eq "F-03 arrange: the incarnation really is unestablished" "None" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
       "$WATCH_RUN_DIR/f3.identity.d/active.json")"
printf '0\n' > "$WATCH_RUN_DIR/f3.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
rc0="$(bash "$AGENTCTL" watch f3 >/dev/null 2>&1; echo $?)"
chk_eq "F-03 arrange: incarnation A published a real DONE record" 0 "$rc0"
tok_a="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f3)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity resume f3 >/dev/null 2>&1
tok_b="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f3)"
chk_eq "F-03 DAMAGE ORACLE: two unestablishable incarnations do NOT compare equal" 1 \
  "$([ "$tok_a" != "$tok_b" ] && echo 1 || echo 0)"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state f3 --arm 2>&1)"; rc=$?
chk_eq "F-03 the canonical reader refuses the pre-resume DONE (13 = nothing adoptable)" 13 "$rc"
chk_contains "F-03 and says why it is not adoptable" "STALE-INCARNATION" "$out"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5 AGENT_WATCH_FOLLOW_MAX=0
out="$(bash "$AGENTCTL" watch f3 2>&1)"; rc=$?
chk_eq "F-03 the public waiter never reports the old life's DONE" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_not_contains "F-03 no false DONE across the null/null boundary" "=== [f3] DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES AGENT_WATCH_FOLLOW_MAX
sw_clean

echo "== F-04: the canonical reader's OWN timeout is typed 12, never business 8 =="
sw_sandbox
seed f4 70000; running f4
# a meta the reader can open but never finish reading: the canonical read blocks inside its
# own watchdog window, with no terminal record anywhere.
mv "$WATCH_RUN_DIR/f4.duplex.meta" "$SANDBOX/f4.meta.bak"
mkfifo "$WATCH_RUN_DIR/f4.duplex.meta"
out="$(AGENT_WATCH_STATUS_TIMEOUT=1 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f4 2>&1)"; rc=$?
chk_eq "F-04 DAMAGE ORACLE: a reader that timed out returns 12, not the business class 8" 12 "$rc"
chk_contains "F-04 the class is the undecidable one" "SUPERVISOR-LOST" "$out"
chk_not_contains "F-04 and it is never dressed as an engine verdict" "ENGINE-SILENT" "$out"
rm -f "$WATCH_RUN_DIR/f4.duplex.meta"
cp "$SANDBOX/f4.meta.bak" "$WATCH_RUN_DIR/f4.duplex.meta"

# the same failure reached through the public waiter: attached, supervised, then the meta it
# reads through becomes unreadable while nothing has concluded.
seed f4w 70000; running f4w
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_STATUS_TIMEOUT=1
watch_bg f4w "$SANDBOX/f4w.log"
await "[ -s '$WATCH_RUN_DIR/f4w.watch.super.json' ]" 200
sup="$(lease_pid f4w)"
mkfifo "$SANDBOX/f4w.fifo"
mv "$SANDBOX/f4w.fifo" "$WATCH_RUN_DIR/f4w.duplex.meta"   # atomic swap: every later read blocks
kill -9 "$sup" 2>/dev/null                                 # only the waiter is left
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f4w.log")"
chk_eq "F-04 the public waiter types its own unreadable state as 12" 12 "$rc"
chk_not_contains "F-04 the waiter never reports ENGINE-SILENT for a read it could not finish" \
  "ENGINE-SILENT" "$out"
chk_eq "F-04 and no terminal record was invented" 0 \
  "$([ -e "$WATCH_RUN_DIR/f4w.terminal.json" ] && echo 1 || echo 0)"
rm -f "$WATCH_RUN_DIR/f4w.duplex.meta"
unset AGENT_WATCH_STATUS_TIMEOUT
sw_clean

echo "== F-05: a rogue same-name watchd is undecidable, not a licence to sense inline =="
sw_sandbox
seed f5 70000
printf '3\n' > "$WATCH_RUN_DIR/f5.duplex.rc"        # inline sensing would re-derive FAILED 2
export AGENT_WATCH_MAX_POLLS=1000 AGENTCTL_SUPERVISOR_ARM_TRIES=5
tmux new-session -d -s f5-watchd -c "$WT" '/bin/sleep 600'   # squats the name, never leases
out="$(bash "$AGENTCTL" watch f5 2>&1)"; rc=$?
chk_eq "F-05 DAMAGE ORACLE: the waiter returns typed 12, it does not fall back to inline" 12 "$rc"
chk_contains "F-05 the class is named" "SUPERVISOR-LOST" "$out"
chk_contains "F-05 the detail names the rogue watchd" "rogue" "$out"
chk_contains "F-05 and gives the cleanup instruction" "kill-session" "$out"
chk_not_contains "F-05 no business conclusion was re-derived inline" "=== [f5] FAILED" "$out"
chk_eq "F-05 nothing was published" 0 \
  "$([ -e "$WATCH_RUN_DIR/f5.terminal.json" ] && echo 1 || echo 0)"
chk_eq "F-05 the unidentifiable session was NOT murdered by the waiter" 1 \
  "$(tmux has-session -t "=f5-watchd" 2>/dev/null && echo 1 || echo 0)"
# PAIRED GREEN: clear the squatter and the canonical path supervises again
tmux kill-session -t "=f5-watchd" 2>/dev/null
unset AGENTCTL_SUPERVISOR_ARM_TRIES
out="$(bash "$AGENTCTL" watch f5 2>&1)"; rc=$?
chk_eq "F-05 PAIRED GREEN: with the name free, the supervised path reports the real class" 2 "$rc"
chk_contains "F-05 PAIRED GREEN: and it came from a published record" "FAILED" "$out"
sw_clean

echo "== F-06/F-07: the lease window covers a supported classify, and needs a start-time =="
sw_sandbox
seed f6 70000; running f6
f6tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f6)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease f6 \
  --armed "$f6tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "F-06 arrange: the shipped writer recorded a start-time for a live pid" 1 \
  "$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["pidStart"] else 0)' \
       "$WATCH_RUN_DIR/f6.watch.super.json")"
age_lease() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' \
                "$WATCH_RUN_DIR/f6.watch.super.json" "$1"; }
age_lease 121
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f6 2>&1)"; rc=$?
chk_eq "F-06 DAMAGE ORACLE: a 121s-old lease under a supported 300s classify is still alive" 10 "$rc"
chk_not_contains "F-06 no false wedge verdict during a legitimate slow classify" \
  "SUPERVISOR-LOST" "$out"
# Past the budget + slack the supervisor really IS wedged — but since R4 that verdict belongs
# to the POLLING waiter's own poll count and to nothing else. A one-shot read subtracts two
# mtimes, and a whole-host clock step lands them on opposite sides of the jump (review R3
# F-03), so it now makes no staleness claim at all. Same aged lease, both readers:
age_lease 400
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state f6 >/dev/null 2>&1; echo $?)"
chk_eq "F-06 a one-shot read derives no wedge from an age, however old the lease looks" 10 "$rc"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f6 --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "F-06 PAIRED RED-SIDE: the self-clocking waiter past the budget + slack IS wedged" 12 "$rc"
chk_contains "F-06 and the detail names the wedge" "wedged" "$out"

# F-07 — the writer refuses a lease it cannot fence, using the shipped CLI and a broken `ps`
seed f7 70000
f7tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f7)"
PSBIN7="$SANDBOX/psbin7"; mkdir -p "$PSBIN7"
cat > "$PSBIN7/ps" <<'FAKEPS'
#!/bin/sh
exit 1
FAKEPS
chmod +x "$PSBIN7/ps"
out="$(PATH="$PSBIN7:$PATH" python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease f7 \
       --armed "$f7tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 2>&1)"; rc=$?
chk_eq "F-07 DAMAGE ORACLE: a lease with no start-time is refused at the writer" 3 "$rc"
chk_contains "F-07 the refusal is typed" "SUPERVISOR-UNFENCEABLE" "$out"
chk_eq "F-07 and no unfenceable lease reached disk" 0 \
  "$([ -e "$WATCH_RUN_DIR/f7.watch.super.json" ] && echo 1 || echo 0)"
# reader side, defence in depth: a lease shaped like the one older writers produced (empty
# pidStart) must not read as alive just because some process holds that pid.
python3 - "$WATCH_RUN_DIR/f7.watch.super.json" "$f7tok" $$ <<'PY'
import json, sys
json.dump({"schemaVersion": 3, "pid": sys.argv[3], "pidStart": "", "identityToken": sys.argv[2],
           "tmux": "f7-watchd", "round": "1", "pollSecs": 1, "maxPolls": 1000, "iter": 1},
          open(sys.argv[1], "w"))
PY
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state f7 2>&1)"; rc=$?
chk_eq "F-07 DAMAGE ORACLE: same-pid without a start-time is undecidable, not alive" 12 "$rc"
chk_contains "F-07 and the detail says the pid alone proves nothing" "recycled" "$out"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R3 — the R2 review's four findings, frozen as assertions. Every DAMAGE ORACLE below was RED
# against the reviewed head (2deda2e) and is the reason the corresponding fix exists. Same
# rules as above: public CLI / canonical shipped reader / real signals only; nothing here
# hand-writes a terminal record and reads it back.
# ═════════════════════════════════════════════════════════════════════════════════════════

strip_fields() { # $1 json file  $2.. keys to remove
  python3 - "$@" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    rec.pop(key, None)
json.dump(rec, open(sys.argv[1], "w"))
PY
}

echo "== G-01: the public publisher REQUIRES --round; the canonical reader REQUIRES class+round =="
sw_sandbox

# (a) `duplexctl identity publish` is the ONE identity surface for callers outside this
# process. Round 1 arms, the meta advances to round 2 (what a steer does), and the shipped
# publisher omits the fence: pre-fix it stamped the round the meta had reached BY THEN and a
# waiter reported the previous round's conclusion as this round's DONE.
seed g1 70000
printf '0\n' > "$WATCH_RUN_DIR/g1.duplex.rc"
g1tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g1)"
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/g1.duplex.meta"
rm -f "$WATCH_RUN_DIR/g1.duplex.meta.bak"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1 \
       --armed "$g1tok" --rc 0 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a publish with no round fence is REFUSED, never defaulted" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "G-01 and the refusal names the missing fence" "--round" "$out"
chk_eq "G-01 and nothing was published" 0 \
  "$([ -e "$WATCH_RUN_DIR/g1.terminal.json" ] && echo 1 || echo 0)"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1 --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 so the canonical reader has nothing to adopt (13 = proceed to arm)" 13 "$rc"
# PAIRED GREEN: the same shipped publisher WITH the fence, for the round the meta is on
prc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1 \
       --armed "$g1tok" --rc 0 --round 2 >/dev/null 2>&1; echo $?)"
chk_eq "G-01 PAIRED GREEN: the fenced publish still succeeds" 0 "$prc"
chk_eq "G-01 PAIRED GREEN: and the record carries the round it concluded" "2" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["round"])' \
       "$WATCH_RUN_DIR/g1.terminal.json" 2>/dev/null)"

# (b) the read side of the same contract: `class` and `round` are REQUIRED schema fields of the
# canonical read, not compatibility options. Pre-fix a record with neither was adopted as DONE
# (`class is None && rc == 0` was completed to DONE, `round is None` skipped the round fence).
seed g1r 70000
printf '0\n' > "$WATCH_RUN_DIR/g1r.duplex.rc"
g1rtok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g1r)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1r \
  --armed "$g1rtok" --rc 0 --round 1 >/dev/null 2>&1
G1REC="$WATCH_RUN_DIR/g1r.terminal.json"
chk_eq "G-01 arrange: the shipped publisher produced a record" 1 \
  "$([ -s "$G1REC" ] && echo 1 || echo 0)"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 arrange: and it is adoptable while intact" 0 "$rc"
cp "$G1REC" "$SANDBOX/g1r.intact.json"
strip_fields "$G1REC" class
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a record with no class is not adoptable" 13 "$rc"
chk_contains "G-01 and the reader names the missing class" "class" "$out"
cp "$SANDBOX/g1r.intact.json" "$G1REC"
strip_fields "$G1REC" round
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a record with no round is not adoptable" 13 "$rc"
chk_contains "G-01 and the reader names the missing round" "round" "$out"
cp "$SANDBOX/g1r.intact.json" "$G1REC"
strip_fields "$G1REC" class round
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 DAMAGE ORACLE: neither field present is still not a legacy DONE" 13 "$rc"
# PAIRED GREEN: restore the shipped record and the same reader adopts it again
cp "$SANDBOX/g1r.intact.json" "$G1REC"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 PAIRED GREEN: the intact record is still this round's DONE" 0 "$rc"
sw_clean

echo "== G-02: a FAILED steer must not destroy an attached peer's undelivered conclusion =="
sw_sandbox
seed g2 70000; running g2
export AGENT_WATCH_MAX_POLLS=1000
# A (poll 1) reports and rotates the conclusion; B (poll 8) is attached the whole time and has
# not read yet. Pre-fix `agentctl steer` unlinked terminal.json AND terminal.consumed.json
# before duplexctl even ran, so a steer that FAILED — no new round, no delivery — still
# destroyed the only copy of this round's conclusion and B came back SUPERVISOR-LOST 12.
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch g2 > "$SANDBOX/g2.a.log" 2>&1 &
GA=$!
AGENT_WATCH_POLL_SECS=8 bash "$AGENTCTL" watch g2 > "$SANDBOX/g2.b.log" 2>&1 &
GB=$!
await "[ -s '$WATCH_RUN_DIR/g2.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/g2.duplex.rc"     # real classify → FAILED 2
wait "$GA" 2>/dev/null; arc=$?
chk_eq "G-02 arrange: waiter A reported the published class" 2 "$arc"
chk_eq "G-02 arrange: and rotated it to consumed" 1 \
  "$([ -s "$WATCH_RUN_DIR/g2.terminal.consumed.json" ] && echo 1 || echo 0)"
sout="$(bash "$AGENTCTL" steer g2 -m 'next round please' 2>&1)"; src=$?
chk_eq "G-02 arrange: the steer really failed (the engine already has an rc)" 1 \
  "$([ "$src" != 0 ] && echo 1 || echo 0)"
chk_eq "G-02 arrange: and it opened no new round" "round=1" \
  "$(sed -n 's/^\(round=.*\)$/\1/p' "$WATCH_RUN_DIR/g2.duplex.meta")"
chk_eq "G-02 DAMAGE ORACLE: the failed steer destroyed no record" 1 \
  "$([ -s "$WATCH_RUN_DIR/g2.terminal.consumed.json" ] && echo 1 || echo 0)"
wait "$GB" 2>/dev/null; brc=$?
chk_eq "G-02 so the attached peer still converges on the SAME class" 2 "$brc"
chk_not_contains "G-02 and was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/g2.b.log")"
# PAIRED GREEN for the other half of the rule — that a SUCCESSFUL steer really does clear the
# records at the round-commit point — is `test/agentctl-duplex.test.sh`'s "steer opens a new
# round and clears the marker (F1)", which drives a live fake engine this sandbox has no room
# for. Both halves must hold: this suite pins the refusal, that one pins the commit.
sw_clean

echo "== G-03: event order comes from the persisted publish sequence, never from a wall clock =="
sw_sandbox
seed g3 70000
printf '3\n' > "$WATCH_RUN_DIR/g3.duplex.rc"      # real classify → FAILED 2
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_POLL_SECS=1
arc="$(bash "$AGENTCTL" watch g3 >/dev/null 2>&1; echo $?)"
chk_eq "G-03 arrange: the first waiter reported and delivered a real conclusion" 2 "$arc"
G3C="$WATCH_RUN_DIR/g3.terminal.consumed.json"
chk_eq "G-03 arrange: the delivered record is on disk" 1 "$([ -s "$G3C" ] && echo 1 || echo 0)"
chk_eq "G-03 arrange: and the arm-time watermark is that record's publish seq" "1" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark g3)"
age_record() { python3 -c 'import os,sys,time;t=time.time()+float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
# (a) PAIRED GREEN — the host clock stepped FORWARD after publication, so a record that was
# published while this peer was attached now looks an hour old. Attachment is a seq
# comparison, so the peer (watermark 0 = it saw no record when it armed) still adopts it.
age_record "$G3C" -3600
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g3 --arm --armed-seq 0 2>&1)"; rc=$?
chk_eq "G-03 an attached peer still gets the delivered class when the record looks old" 2 "$rc"
chk_contains "G-03 and it is the real business class, not a degrade" "FAILED" "$out"
# (b) DAMAGE ORACLE — the mirror image: the host clock stepped BACK after publication, so the
# spent record's mtime is in the FUTURE. Pre-fix (`consumed.st_mtime >= arm instant`) a waiter
# that armed AFTER delivery was mistaken for an attached peer and REPLAYED a consumed business
# class. The live facts now say DONE, so a replay and a re-sense are distinguishable.
age_record "$G3C" 3600
printf '0\n' > "$WATCH_RUN_DIR/g3.duplex.rc"
brc="$(bash "$AGENTCTL" watch g3 >/dev/null 2>&1; echo $?)"
chk_eq "G-03 DAMAGE ORACLE: a waiter arming after delivery re-senses (0), it never replays (2)" \
  0 "$brc"
chk_eq "G-03 and the re-sensed conclusion is a NEW record, not the spent one" "2" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
       "$WATCH_RUN_DIR/g3.terminal.json" 2>/dev/null)"
sw_clean

echo "== G-03b: lease freshness survives a reader whose wall clock jumped, in both directions =="
sw_sandbox
# The injection: a sitecustomize shim that steps THIS reader's time.time() and nothing else —
# the filesystem's clock, the lease and the supervisor are untouched. That is the shape of a
# host clock adjustment landing between the supervisor's last renewal and the waiter's read.
CLOCKSHIM="$SANDBOX/clockshim"; mkdir -p "$CLOCKSHIM"
cat > "$CLOCKSHIM/sitecustomize.py" <<'PY'
import os, time
_skew = float(os.environ.get("SW_FAKE_CLOCK_SKEW") or 0)
if _skew:
    _real = time.time
    time.time = lambda: _real() + _skew
PY
skewed="$(SW_FAKE_CLOCK_SKEW=1000 PYTHONPATH="$CLOCKSHIM" python3 -c 'import time;print(int(time.time()))')"
nowsec="$(python3 -c 'import time;print(int(time.time()))')"
chk_eq "G-03b PROOF THE INJECTION IS LIVE: the shim really moves the reader's clock" 1 \
  "$([ $((skewed - nowsec)) -ge 990 ] && echo 1 || echo 0)"
seed g4 70000; running g4
g4tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g4)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease g4 \
  --armed "$g4tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "G-03b arrange: a valid, FRESH lease from the shipped writer" 1 \
  "$([ -s "$WATCH_RUN_DIR/g4.watch.super.json" ] && echo 1 || echo 0)"
out="$(SW_FAKE_CLOCK_SKEW=1000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
       python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 2>&1)"; rc=$?
chk_eq "G-03b DAMAGE ORACLE: a reader 1000s ahead does not call a fresh lease wedged" 10 "$rc"
chk_not_contains "G-03b and never invents a wedge from its own clock" "wedged" "$out"
# the polling waiter's own clock: N consecutive of ITS polls with an unmoved lease. The window
# comes from the budget the supervisor recorded (300s + 60s slack = 360s) over the reader's
# poll interval — 6 intervals of 60s here — and no clock is consulted at all, in either
# direction. R4 corrects the counting: n SAMPLES bound n-1 elapsed INTERVALS, because the first
# sample only establishes a baseline; reading 6 samples as 6 intervals fired the wedge after
# 300 observed seconds, inside the window a legitimately slow classify owns (review R3 F-02).
out="$(SW_FAKE_CLOCK_SKEW=-100000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
       python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 \
       --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "G-03b a reader that watched 6 of its own 60s intervals pass unmoved says wedged" 12 "$rc"
chk_contains "G-03b and names the reader's own polls, not seconds" "polls" "$out"
rc="$(SW_FAKE_CLOCK_SKEW=-100000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
      python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 \
      --lease-unchanged 6 --poll 60 >/dev/null 2>&1; echo $?)"
chk_eq "G-03b PAIRED GREEN: one interval short of the window is still alive" 10 "$rc"
sw_clean

echo "== G-04: a lease whose freshness budget is not a finite positive number is damaged =="
sw_sandbox
seed g5 70000; running g5
g5tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g5)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease g5 \
  --armed "$g5tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
G5L="$WATCH_RUN_DIR/g5.watch.super.json"
cp "$G5L" "$SANDBOX/g5.lease.intact.json"
damage_lease() { # $1 key  $2 python literal
  python3 - "$G5L" "$1" "$2" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1]))
lease[sys.argv[2]] = eval(sys.argv[3])          # noqa: S307 — fixture, literal from the test
json.dump(lease, open(sys.argv[1], "w"))
PY
}
# The lease stays FRESH and its pid/start-time stay correct: the ONLY thing wrong is the
# budget. Pre-fix `float("Infinity")` made stale_after infinite, so a damaged lease could
# impersonate a live supervisor until the waiter's outer cap (~2h) bypassed it.
damage_lease statusTimeout '"Infinity"'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state g5 2>&1)"; rc=$?
chk_eq "G-04 DAMAGE ORACLE: a non-finite freshness budget is typed 12, never alive" 12 "$rc"
chk_contains "G-04 the class is the undecidable one" "SUPERVISOR-LOST" "$out"
chk_contains "G-04 and the detail names the damaged field" "statusTimeout" "$out"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease statusTimeout 'float("nan")'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a NaN budget is damaged too" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease pollSecs '-1'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a negative poll interval is damaged too" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease pollSecs '"300"'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a stringly-typed budget is damaged too — the schema is numbers" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 PAIRED GREEN: the undamaged lease from the shipped writer is alive" 10 "$rc"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R4 — the R3 review's three findings, frozen as assertions. Each DAMAGE ORACLE below was RED
# against the reviewed head (3d21e40). Same rules as above: public CLI / canonical shipped
# reader / real classify exits only.
# ═════════════════════════════════════════════════════════════════════════════════════════

rec_seq() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
              "$1" 2>/dev/null; }

echo "== H-01: the delivery watermark is per-ATTEMPT — a retired attempt cannot arm a waiter =="
sw_sandbox
seed h1 70000; running h1
export AGENT_WATCH_MAX_POLLS=1000
H1LIVE="$WATCH_RUN_DIR/h1.terminal.json"; H1CONS="$WATCH_RUN_DIR/h1.terminal.consumed.json"
# attempt A, round 1: a real classify, a real waiter, a real delivery — seq 1, rotated to
# consumed. Then a second publish through the ONE public identity surface — seq 2, live.
printf '3\n' > "$WATCH_RUN_DIR/h1.duplex.rc"
arc="$(AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch h1 >/dev/null 2>&1; echo $?)"
chk_eq "H-01 arrange: attempt A published and delivered a real FAILED" 2 "$arc"
chk_eq "H-01 arrange: and the delivered record is attempt A's seq 1" "1" "$(rec_seq "$H1CONS")"
h1a="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h1)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish h1 \
  --armed "$h1a" --rc 7 --round 1 >/dev/null 2>&1
chk_eq "H-01 arrange: attempt A also leaves an UNdelivered live record at seq 2" "2" \
  "$(rec_seq "$H1LIVE")"
# KNOWN POSITIVE — without it a fenced watermark of 0 could not be told from a watermark that
# cannot see records at all: inside attempt A the very same call reports 2.
chk_eq "H-01 KNOWN POSITIVE: inside its own attempt the watermark really does see both" "2" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark h1)"
# the attempt rotates through the public identity CLI. The round does NOT advance and neither
# record is cleaned — exactly the residue a FAILED `steer --replace` leaves behind, since the
# replacement identity is committed before the frame that then fails to send.
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace h1 >/dev/null 2>&1
h1b="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h1)"
chk_eq "H-01 arrange: the attempt really rotated" 1 \
  "$([ -n "$h1b" ] && [ "$h1a" != "$h1b" ] && echo 1 || echo 0)"
chk_eq "H-01 arrange: the round did not advance" "round=1" \
  "$(sed -n 's/^\(round=.*\)$/\1/p' "$WATCH_RUN_DIR/h1.duplex.meta")"
chk_eq "H-01 arrange: and both of attempt A's records survive the rotation" 1 \
  "$([ -s "$H1LIVE" ] && [ -s "$H1CONS" ] && echo 1 || echo 0)"
chk_eq "H-01 DAMAGE ORACLE: a retired attempt's records contribute NOTHING to the watermark" \
  "0" "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark h1)"
# and the end-to-end shape that made it a blocker: attempt B's publish sequence restarts at 1,
# so a waiter armed at the retired attempt's watermark read attempt B's FIRST conclusion as
# "published before I attached" and fell through to SUPERVISOR-LOST 12 while its peer — the
# same supervisor, the same terminal event — reported the business class. 2/12 on one event.
rm -f "$WATCH_RUN_DIR/h1.duplex.rc"          # back to RUNNING, so BOTH waiters attach first
rm -f "$WATCH_RUN_DIR/h1.watch.super.json"
tmux kill-session -t h1-watchd 2>/dev/null   # phase 1's supervisor exited on its own; free the
                                             # harness's session slot so exactly ONE new sensing
                                             # loop serves both waiters (a second one would
                                             # publish a second time and blur the sequence)
running h1
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch h1 > "$SANDBOX/h1.a.log" 2>&1 &
HA=$!
# B polls slowly enough that A is guaranteed to have reported AND rotated the record first:
# the delivered-record path is the one the watermark bug lived on.
AGENT_WATCH_POLL_SECS=12 bash "$AGENTCTL" watch h1 > "$SANDBOX/h1.b.log" 2>&1 &
HB=$!
await "[ -s '$WATCH_RUN_DIR/h1.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/h1.duplex.rc"     # real classify → FAILED 2, under attempt B
wait "$HA" 2>/dev/null; harc=$?
wait "$HB" 2>/dev/null; hbrc=$?
chk_eq "H-01 the fast waiter reports attempt B's real class" 2 "$harc"
chk_eq "H-01 arrange: and it IS attempt B's first publish (the sequence restarted at 1)" "1" \
  "$(rec_seq "$H1CONS")"
chk_eq "H-01 the attached peer converges on the SAME typed class, not 12" 2 "$hbrc"
chk_not_contains "H-01 and was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/h1.b.log")"
sw_clean

echo "== H-02: the wedge threshold counts elapsed INTERVALS, not lease samples =="
sw_sandbox
seed h2 70000; running h2
h2tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h2)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease h2 \
  --armed "$h2tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "H-02 arrange: a valid lease recording a 300s classify budget" "300" \
  "$(python3 -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["statusTimeout"]))' \
       "$WATCH_RUN_DIR/h2.watch.super.json")"
# window = max(4×1, 120, 300+60) = 360s; a 60s waiter poll must therefore observe 6 elapsed
# intervals, which takes 7 consecutive samples. N-1 must NOT judge, N must.
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h2 --lease-unchanged 6 --poll 60 2>&1)"; rc=$?
chk_eq "H-02 DAMAGE ORACLE: 6 samples bound only 300s — inside the 360s window, still alive" \
  10 "$rc"
chk_not_contains "H-02 and the legitimately slow classify is never called wedged" "wedged" "$out"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h2 --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "H-02 PAIRED RED-SIDE: the 7th sample completes 6 intervals = 360s and IS wedged" 12 "$rc"
chk_contains "H-02 and the detail counts intervals, not samples" "intervals" "$out"
# the same boundary at a different granularity, so the assertion pins the ARITHMETIC and not
# one lucky pair of numbers: a 30s poll needs 12 intervals = 13 samples for the same window.
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 12 --poll 30 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 a 30s poll is still alive at 12 samples (11 intervals = 330s)" 10 "$rc"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 13 --poll 30 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 and wedged at 13 (12 intervals = 360s)" 12 "$rc"
# the floor still holds: a poll interval wider than the whole window must still observe two
# intervals — one missed renewal is not a wedge.
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 2 --poll 3600 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 FLOOR: one huge interval is not yet a wedge" 10 "$rc"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 3 --poll 3600 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 FLOOR: two of them are" 12 "$rc"
sw_clean

echo "== H-03: a one-shot reader has no stall authority — lease age is never its evidence =="
sw_sandbox
seed h3 70000; running h3
h3tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h3)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease h3 \
  --armed "$h3tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
H3L="$WATCH_RUN_DIR/h3.watch.super.json"
cp "$H3L" "$SANDBOX/h3.lease.intact.json"
# A WHOLE-HOST clock step forward after the last renewal, which is what the previous `fs_now`
# probe could not survive: probe mtime and lease mtime share one clock domain but sit on
# opposite sides of the jump. Moving the lease mtime 1000s back produces the identical
# subtraction from the identical filesystem clock — and the supervisor is demonstrably fine.
python3 -c 'import os,sys,time; t=time.time()-1000.0; os.utime(sys.argv[1],(t,t))' "$H3L"
chk_eq "H-03 arrange: the lease names a live pid with a matching start-time (this shell)" "$$" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$H3L")"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 DAMAGE ORACLE: a 1000s filesystem-clock step never makes a one-shot read say 12" \
  10 "$rc"
chk_not_contains "H-03 and the one-shot line claims no staleness at all" "wedged" "$out"
chk_contains "H-03 it says so out loud, so nobody re-derives an age from it" "one-shot" "$out"
# the authority MOVED, it was not deleted: the polling waiter still wedges on the same lease...
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 --lease-unchanged 7 --poll 60 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 PAIRED RED-SIDE: the self-clocking waiter still calls this lease wedged" 12 "$rc"
# ...and the one-shot read keeps every STRUCTURAL refusal it ever had. Dropping the age check
# must not quietly drop the schema, fence and pid-reuse gates with it.
damage_h3() { # $1 key  $2 python literal
  python3 - "$H3L" "$1" "$2" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1]))
lease[sys.argv[2]] = eval(sys.argv[3])          # noqa: S307 — fixture, literal from the test
json.dump(lease, open(sys.argv[1], "w"))
PY
}
damage_h3 statusTimeout '"Infinity"'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 a damaged budget is still typed 12 for the one-shot reader" 12 "$rc"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
damage_h3 pidStart '""'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 a lease with no start-time is still typed 12 for the one-shot reader" 12 "$rc"
chk_contains "H-03 and still names pid reuse as the reason" "recycled" "$out"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
damage_h3 identityToken '"someone/elses/attempt"'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 a lease fenced to another identity is still typed 12" 12 "$rc"
chk_contains "H-03 and still names the fence" "STALE-" "$out"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 PAIRED GREEN: the intact lease reads alive again" 10 "$rc"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M16 STALLED-PROGRESS: streaming is not progress =="
# Field motive (2026-08-28, downstream seat): watch only called a human on a terminal state or
# a question, so 2.5h of healthy STREAMING with zero commits, zero deliverable bytes and no
# BLOCKED.md went unnoticed. STALLED-STREAM cannot see it — the stream is alive. The probe is
# the WORK TRACE: HEAD, the dirty-tree hash, the deliverable mtime, BLOCKED.md's mtime.
sw_sandbox
export AGENT_WATCH_STALL_MINS=0          # isolate: the STREAM probe must not answer for this
# a real repo with a real commit — `git rev-parse HEAD` on a commit-less repo is UNJUDGEABLE,
# which is a different case (proven as the third fixture below)
REPO="$SANDBOX/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
progress_seed() { # $1 session  $2 cwd
  seed "$1" && running "$1"
  printf 'engine=claude\ncwd=%s\nround=1\n' "$2" > "$WATCH_RUN_DIR/$1.duplex.meta"
}
# window in MINUTES; 0.01 = 0.6s, so two real polls straddle it without a slow test
PW=0.01

# ── 坏红: the trace is frozen for the whole window → typed STALLED-PROGRESS 14 ────────────
progress_seed pgFROZEN "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgFROZEN >/dev/null 2>&1; echo $?)"
chk_eq "M16 the first read only OPENS the window (still RUNNING 10)" 10 "$rc"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgFROZEN 2>&1)"; rc=$?
chk_eq "M16 DAMAGE ORACLE: a frozen work trace past the window is typed 14" 14 "$rc"
chk_contains "M16 the verdict names the frozen probes" "dirty-tree hash" "$out"
chk_contains "M16 and never reads as done" "never read this as DONE" "$out"
chk_contains "M16 and names the knob that tunes it" "AGENT_WATCH_PROGRESS_MINS" "$out"
# the state must also be PUBLISHABLE — the terminal-class map gates that, and the supervisor
# leg below proves the whole path end to end
chk_contains "M16 the class is in the publishable terminal map" "STALLED-PROGRESS" \
  "$(grep -A2 'TERMINAL_CLASSES = ' "$AW_DIR/identity.py")"

# ── 好绿: the trace MOVES between reads → the window restarts, no verdict ─────────────────
progress_seed pgMOVES "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES >/dev/null 2>&1; echo $?)"
chk_eq "M16 PAIRED GREEN: window opened (RUNNING 10)" 10 "$rc"
/bin/sleep 1
printf 'real work\n' > "$REPO/work.txt"          # the dirty-tree hash moves: that IS progress
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: a moving work trace stays RUNNING 10 past the same window" 10 "$rc"
chk_contains "M16 PAIRED GREEN: and publishes when it last moved" "last_progress_at=" "$out"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: the window really restarted from the movement, not from arm time" \
  14 "$rc"

# ── 坏样本 (SHIP-BLOCKING, cold review R1 §3): NESTED untracked content, edited every window ─
# The DEFAULT `git status --porcelain` folds nested untracked content into ONE `?? nested/`
# line. Appending to `nested/deep/notes.md` changes neither that porcelain set nor the listed
# directory's mtime, so real uncommitted work read as a frozen trace and fired a false 14.
# `--untracked-files=all` is what makes the nested FILE the dirty entry the mtime tracks.
progress_seed pgNEST "$REPO"
mkdir -p "$REPO/nested/deep"
printf 'v1\n' > "$REPO/nested/deep/notes.md"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested: the first read only OPENS the window (RUNNING 10)" 10 "$rc"
/bin/sleep 1
printf 'v2\n' >> "$REPO/nested/deep/notes.md"    # ONLY the nested untracked file moves
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN (坏样本): editing a NESTED untracked file IS progress, past the window" \
  10 "$rc"
chk_contains "M16 nested: and the window restarted from that movement" "last_progress_at=" "$out"
/bin/sleep 1
printf 'v3\n' >> "$REPO/nested/deep/notes.md"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested: still no false verdict across a SECOND window of nested-only work" 10 "$rc"
# DAMAGE ORACLE: the very same tree, with that file left ALONE, really does freeze — so the
# green above is the fingerprint tracking the work, not the probe having been switched off
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested DAMAGE ORACLE: stop editing it and the same window fires 14" 14 "$rc"
rm -rf "$REPO/nested"

# ── 坏样本 (SHIP-BLOCKING, verify R2 SB3): a dirty set PAST the bounded scan ──────────────
# The scan stats at most PROGRESS_DIRTY_MAX paths. Silently keeping the first 500 published a
# mtime measured over a PREFIX as if it covered the tree: with 501 dirty files, work that only
# ever touched the 501st left the fingerprint bit-identical and fired a false 14 on a session
# that was moving. The bound stays — the READING is refused instead of truncated.
BIG="$SANDBOX/bigrepo"; mkdir -p "$BIG"
git -C "$BIG" init -q 2>/dev/null
git -C "$BIG" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
python3 -c '
import os, sys
root = sys.argv[1]
for n in range(1, 502):
    with open(os.path.join(root, "f%03d.txt" % n), "w") as fh:
        fh.write("v1\n")' "$BIG"
chk_eq "M16 501 files: the fixture really is ONE past the bound" 501 \
  "$(git -C "$BIG" status --porcelain --untracked-files=all | grep -c .)"
progress_seed pgBIG "$BIG"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG >/dev/null 2>&1; echo $?)"
chk_eq "M16 501 files: first read RUNNING" 10 "$rc"
/bin/sleep 1
printf 'v2\n' >> "$BIG/f501.txt"       # ONLY the file OUTSIDE the scanned prefix moves
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG 2>&1)"; rc=$?
# THE CONTRACT (cold review R1 Q1): one judged source concludes, so this cell is a typed 14 —
# but the WORD is `unknown-source` and the disposition is the gauge, never the seat. What SB3
# forbids is intact and is what the two assertions after the rc pin: the verdict may not claim
# the repo trace was measured, and it may not send the operator to steer on a gauge fault.
chk_eq "M16 (SB3, Q1): work outside the scanned prefix is 14 — as a GAUGE fault" 14 "$rc"
chk_contains "M16 501 files: the word says a source could not be judged" \
  "reason=unknown-source" "$out"
chk_contains "M16 501 files: and NAMES the bound it went past" \
  "exceeds the bounded scan (>500 paths)" "$out"
chk_contains "M16 501 files DAMAGE ORACLE (SB3): the repo source is named as UNJUDGED" \
  "and unjudged: repo" "$out"
chk_not_contains "M16 501 files DAMAGE ORACLE (SB3): never claiming the truncated trace was still" \
  "dirty-tree hash" "$out"
chk_contains "M16 501 files: and the disposition is the gauge, not the seat" \
  "REPAIR THE GAUGE FIRST" "$out"
chk_not_contains "M16 501 files: no timestamp fabricated from a truncated measurement" \
  "last_progress_at=" "$out"
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG >/dev/null 2>&1; echo $?)"
chk_eq "M16 501 files: and the same gauge fault reads the same across a SECOND window" 14 "$rc"
# PAIRED GREEN: the bound is not an off-switch. At exactly 500 dirty paths the same tree is
# JUDGED again, and a frozen one still fires the state it must.
rm -f "$BIG/f501.txt"
progress_seed pgBIG2 "$BIG"
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG2 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: 500 dirty paths opens a JUDGED window (RUNNING 10)" 10 "$rc"
chk_not_contains "M16 PAIRED GREEN: nothing unjudgeable about the bound itself" \
  "progress=unknown" "$out"
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG2 >/dev/null 2>&1; echo $?)"
chk_eq "M16 PAIRED GREEN: and a frozen 500-path tree still fires 14" 14 "$rc"
rm -rf "$BIG"

# ── 量具坏: a probe that cannot be JUDGED may never be read as stillness ──────────────────
# cwd is not a repo, so `git rev-parse HEAD` fails. 宁钝勿敏 still holds where it can: the source
# never votes silent, the frozen-probe list never names it, and the disposition is the gauge.
# What CHANGED (cold review R1 Q1): a blind repo beside ONE judged source is no longer permanent
# RUNNING — that cell is the named real-stall shape and now concludes as `unknown-source`. The
# floor is zero judged sources (M17 quorum floor), not two.
progress_seed pgBLIND "$SANDBOX/not-a-repo"
mkdir -p "$SANDBOX/not-a-repo"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND >/dev/null 2>&1; echo $?)"
chk_eq "M16 量具坏: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND 2>&1)"; rc=$?
chk_eq "M16 量具坏 (Q1): an unjudgeable git probe beside a judged source concludes" 14 "$rc"
# NB3.3: unjudgeable may not refresh the progress timestamp either — a gauge failing at 14:03
# is not the work moving at 14:03 (cold review R1 §3).
chk_contains "M16 量具坏: and SAYS which probe could not be judged" \
  "and unjudged: repo — no git, cwd not a repo" "$out"
chk_contains "M16 量具坏: with the word that refuses to call it stillness" \
  "reason=unknown-source" "$out"
chk_not_contains "M16 量具坏: the frozen list never names the repo trace it never read" \
  "dirty-tree hash" "$out"
chk_contains "M16 量具坏: and the operator is sent to the gauge, not to the seat" \
  "REPAIR THE GAUGE FIRST" "$out"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND 2>&1)"; rc=$?
chk_eq "M16 量具坏: a third window reads the same, never converting into silence" 14 "$rc"
chk_contains "M16 量具坏: still unknown-source, never tools-silent" "reason=unknown-source" "$out"
# and the knob's off switch is real: 0 disables the probe entirely, even on a frozen repo
progress_seed pgOFF "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=0 bash "$AGENTCTL" status pgOFF >/dev/null 2>&1; echo $?)"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=0 bash "$AGENTCTL" status pgOFF 2>&1)"; rc=$?
chk_eq "M16 the 0 off-switch keeps the session RUNNING" 10 "$rc"
chk_not_contains "M16 and publishes no progress timestamp at all" "last_progress_at=" "$out"

# ── the SUPERVISOR must publish it like any other class, and a fresh waiter recover exit 14 ─
progress_seed pgSUP "$REPO"
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_PROGRESS_MINS=$PW
if kill_waiter_then pgSUP ':'; then
  chk_eq "M16 the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M16 STALLED-PROGRESS persisted by the supervisor" "STALLED-PROGRESS" \
    "$(record_class pgSUP)"
  before="$(spawn_count pgSUP)"
  out="$(bash "$AGENTCTL" watch pgSUP 2>&1)"; rc=$?
  chk_eq "M16 a brand-new waiter recovers exit 14 from the record" 14 "$rc"
  chk_contains "M16 and reproduces the class line" "STALLED-PROGRESS" "$out"
  chk_eq "M16 recovery re-derived nothing (no second supervisor)" "$before" "$(spawn_count pgSUP)"
else
  _record "M16 the supervisor published a STALLED-PROGRESS record" 0 "no record appeared"
fi
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS AGENT_WATCH_STALL_MINS

# ── WATCH-TIMEOUT must say WHICH kind of budget exhaustion it was ─────────────────────────
progress_seed pgTMO "$REPO"
# follow migration: every WATCH-TIMEOUT arm from here to the end of this block asserts the
# single-round 7 and the tail word it carries, so the ceiling is pinned for the whole block.
export AGENT_WATCH_MAX_POLLS=3 AGENT_WATCH_FOLLOW_MAX=0
out="$(AGENT_WATCH_PROGRESS_MINS=30 bash "$AGENTCTL" watch pgTMO 2>&1)"; rc=$?
chk_eq "M16 budget exhaustion is still WATCH-TIMEOUT 7" 7 "$rc"
chk_contains "M16 and the line ends with the progress verdict" "progress=unchanged" "$out"
unset AGENT_WATCH_MAX_POLLS
progress_seed pgTMO2 "$REPO"
export AGENT_WATCH_MAX_POLLS=8 AGENT_WATCH_PROGRESS_MINS=30
# ORDERING, not sleeping: the work must move AFTER the loop's first read established the
# baseline window, otherwise the very first fingerprint already contains it and "unchanged"
# would be the honest answer
watch_bg pgTMO2 "$SANDBOX/pgTMO2.w.log"
await "[ -s '$WATCH_RUN_DIR/pgTMO2.duplex.progress' ]" 300
printf 'more work\n' >> "$REPO/work.txt"
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/pgTMO2.w.log")"
chk_eq "M16 PAIRED GREEN: a working session times out the same way" 7 "$rc"
chk_contains "M16 PAIRED GREEN: but the tail says the work DID move" "progress=changed" "$out"
unset AGENT_WATCH_PROGRESS_MINS
# NB3.3: the THIRD tail word is the honest one. A cwd that is not a repo makes every read
# unjudgeable, and `unchanged` there would be a measurement nobody took (cold review R1 §3).
progress_seed pgTMO3 "$SANDBOX/not-a-repo"
# ALL blind, which is what makes the tail word a real question (Q1: one judged source is enough
# to conclude, so a blind REPO alone no longer leaves the union unmeasured — the events stream
# has to be unreadable too for nobody to have measured anything at all).
printf '{not json either\n' >> "$WATCH_RUN_DIR/pgTMO3.duplex.events.jsonl"
export AGENT_WATCH_MAX_POLLS=3 AGENT_WATCH_PROGRESS_MINS=30
out="$(bash "$AGENTCTL" watch pgTMO3 2>&1)"; rc=$?
chk_eq "M16 an unjudgeable probe still times out as WATCH-TIMEOUT 7" 7 "$rc"
chk_contains "M16 NB3.3: and the tail word is unknown, not a fabricated unchanged" \
  "progress=unknown" "$out"
chk_not_contains "M16 NB3.3: never claiming the trace stood still" "progress=unchanged" "$out"
# NB3.3 恢复面 (verify R2): the gauge comes BACK mid-watch, on a tree that never changed.
# The first judgeable read only rebuilds a baseline — the window it replaces was opened by a
# read nobody could judge, so the difference between the two fingerprints is unattributed.
# Crediting it as movement moved the progress clock to the RECOVERY instant, and the
# `None → SAME → SAME` sequence below then reported `progress=changed` on a session that
# never demonstrably moved a byte.
pg_field() { # $1 session  $2 field of the persisted progress window
  python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else json.dumps(v))' "$WATCH_RUN_DIR/$1.duplex.progress" "$2"
}
RECO="$SANDBOX/recover"; mkdir -p "$RECO"
progress_seed pgREC "$RECO"
# same reason as pgTMO3: the window must be opened by a read where NOTHING could be judged
printf '{not json either\n' >> "$WATCH_RUN_DIR/pgREC.duplex.events.jsonl"
export AGENT_WATCH_MAX_POLLS=8 AGENT_WATCH_PROGRESS_MINS=30
watch_bg pgREC "$SANDBOX/pgREC.w.log"
await "[ -s '$WATCH_RUN_DIR/pgREC.duplex.progress' ]" 300
chk_eq "M16 NB3.3 恢复: the window really was opened by an UNJUDGEABLE read" "false" \
  "$(pg_field pgREC judgeable)"
# ORDERING, not sleeping: the gauge must recover AFTER that first blind read, on an
# UNCHANGED tree — the whole point is that nobody measured whether work moved before it
git -C "$RECO" init -q 2>/dev/null
git -C "$RECO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/pgREC.w.log")"
chk_eq "M16 NB3.3 恢复: budget exhaustion is still WATCH-TIMEOUT 7" 7 "$rc"
chk_eq "M16 NB3.3 恢复: and the gauge REALLY recovered — this is not the blind case again" \
  "true" "$(pg_field pgREC judgeable)"
chk_eq "M16 NB3.3 恢复: the recovery rebuilt a baseline and credited NO movement" "0.0" \
  "$(pg_field pgREC moved)"
chk_contains "M16 NB3.3 恢复: so the tail word is unknown" "progress=unknown" "$out"
chk_not_contains "M16 NB3.3 恢复 DAMAGE ORACLE: never the fabricated changed" \
  "progress=changed" "$out"
chk_not_contains "M16 NB3.3 恢复: and never a fabricated unchanged either" \
  "progress=unchanged" "$out"
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_FOLLOW_MAX
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M17 progress SOURCE UNION: three sources, and the reason= word that names which =="
# Field motive (2026-08-29, downstream seat): the repo trace is the only progress source that
# leaves an artifact, so a seat that really works and does not write — a long test suite, a
# docker build, reading code for evidence, sending probes — read as frozen. That seat's own
# audit script retired at hits=0 / false=2. The verdict now reads the UNION of three sources
# (repo trace, the engine's own tool/command frames, the process set in the pane's group) and
# fires only when none of them moved. Each source gets the same three fixtures the repo trace
# already has: 坏红 (it stands still → the state must fire), 好绿 (it moves → the state must be
# withheld) and 量具坏 (it cannot be judged → it may not vote either way), and each of the three
# published sub-reason words gets a live case.
sw_sandbox
export AGENT_WATCH_STALL_MINS=0          # isolate: the STREAM probe must not answer for this
UREPO="$SANDBOX/urepo"; mkdir -p "$UREPO"
git -C "$UREPO" init -q 2>/dev/null
git -C "$UREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
mkdir -p "$SANDBOX/blind"                # a cwd that is NOT a repo: the repo source is unjudged
PW=0.01                                  # window in MINUTES; 0.01 = 0.6s

u_seed() { # $1 session  $2 cwd  [$3 pane_pid]
  seed "$1" && running "$1"
  { printf 'engine=claude\ncwd=%s\nround=1\n' "$2"
    [ -n "${3:-}" ] && printf 'pane_pid=%s\n' "$3"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
}
u_status() { AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status "$1" 2>&1; }
# ONE tool_use item — engine tool activity, in claude's own frame vocabulary
tool_ev() { ev "$1" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t$2\",\"name\":\"Bash\",\"input\":{}}]}}"; }
# pure token output: the stream GROWS and no tool ran — this must NOT count as progress
token_ev() { ev "$1" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"thinking $2\"}]}}"; }

# A REAL process group we own, standing in for a tmux pane: `pane_pid` IS the pgid, and the
# leader forks a child when its trigger file appears — a subprocess BORN mid-window, which is
# the only thing this source claims to see.
cat > "$SANDBOX/pane_leader.py" <<'PY'
import os, subprocess, sys, time
try:
    os.setsid()          # already a group leader when bash backgrounds us: both are fine
except OSError:
    pass
assert os.getpgrp() == os.getpid(), "pane_pid must BE the pgid, like a real pane leader"
with open(sys.argv[1], "w") as fh:
    fh.write(str(os.getpid()))
spawned = False
deadline = time.time() + 180
while time.time() < deadline:
    if not spawned and os.path.exists(sys.argv[2]):
        subprocess.Popen(["/bin/sleep", "120"])      # inherits our pgid
        spawned = True
    time.sleep(0.1)
PY
# NEVER call this inside a command substitution: the leader is a background child of the
# substitution's own subshell and dies with it (probed — every pane source then read [unknown]
# and three assertions passed for the wrong reason). It publishes into PGID instead.
pane_group() { # $1 tag -> sets PGID to a live pgid, or reds via a non-zero return
  local ready="$SANDBOX/$1.pgid"
  PGID=""
  rm -f "$ready" "$SANDBOX/$1.spawn"
  python3 "$SANDBOX/pane_leader.py" "$ready" "$SANDBOX/$1.spawn" >/dev/null 2>&1 &
  SLEEPERS="$SLEEPERS $!"
  disown "$!" 2>/dev/null || true
  await "[ -s '$ready' ]" 100 || return 1
  PGID="$(cat "$ready")"
  # the fixture's own oracle: a pane source that reads [unknown] would make every case below
  # pass or fail for a reason that has nothing to do with the union
  [ "$(pgrep -g "$PGID" | grep -c .)" -ge 1 ]
}
pane_kill() { [ -n "${1:-}" ] && kill -- -"$1" 2>/dev/null; return 0; }

# ── tools 坏红 + tools 好绿 + the two sub-reasons they produce ────────────────────────────
u_seed uTOOLS "$UREPO"
rc="$(u_status uTOOLS >/dev/null 2>&1; echo $?)"
chk_eq "M17 tools: the first read only OPENS the window (RUNNING 10)" 10 "$rc"
/bin/sleep 1
tool_ev uTOOLS 1                                  # the seat ran a tool and wrote NOTHING
out="$(u_status uTOOLS)"; rc=$?
chk_eq "M17 tools 好绿: a tool ran, the repo trace is frozen — the verdict is WITHHELD" 10 "$rc"
chk_contains "M17 tools 好绿: and the WITHHELD observation is published by name" \
  "progress_reason=repo-silent+tools-active" "$out"
chk_contains "M17 tools 好绿: the clock was refreshed from that source" "last_progress_at=" "$out"
/bin/sleep 1
out="$(u_status uTOOLS)"; rc=$?
chk_eq "M17 tools 坏红 (DAMAGE ORACLE): stop running tools and the same window fires 14" \
  14 "$rc"
chk_contains "M17 tools 坏红: with the sub-reason that says both sources are still" \
  "reason=repo-silent+tools-silent" "$out"
chk_contains "M17 tools 坏红: and the verdict names the tool-frame source it read" \
  "the engine's own tool/command frames" "$out"

# ── tools 坏样本: a pure TOKEN stream is not activity ─────────────────────────────────────
# The whole point of a second source is that STREAMING was never the question: STALLED-STREAM
# already answers "the stream stopped". A thinking model that emits text forever and runs
# nothing must still reach 14, or the union has re-introduced the blind spot it was built for.
u_seed uTOKEN "$UREPO"
rc="$(u_status uTOKEN >/dev/null 2>&1; echo $?)"
chk_eq "M17 token stream: first read RUNNING" 10 "$rc"
/bin/sleep 1
token_ev uTOKEN 1; token_ev uTOKEN 2
out="$(u_status uTOKEN)"; rc=$?
chk_eq "M17 tools DAMAGE ORACLE: a growing token stream with no tool call still fires 14" \
  14 "$rc"
chk_contains "M17 token stream: and it is the tools-silent sub-reason, not unknown-source" \
  "reason=repo-silent+tools-silent" "$out"

# ── tools 量具坏 + THE QUORUM CONTRACT: one judged source is enough to conclude ────────────
# `repo = judged and still, tools = unknown, pane = n/a` is the real-stall shape the goal names
# explicitly. A fixed quorum of 2 turned it into permanent RUNNING — every read restarted the
# window at `below the judged quorum (1/2)` and the stall was never reported at all (cold review
# R1 Q1). One judged source concludes, and the WORD carries what called the operator: a gauge
# nobody could read, never a proof of stillness.
u_seed uTJUNK "$UREPO"
printf '{not json at all\n' >> "$WATCH_RUN_DIR/uTJUNK.duplex.events.jsonl"
rc="$(u_status uTJUNK >/dev/null 2>&1; echo $?)"
chk_eq "M17 tools 量具坏: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(u_status uTJUNK)"; rc=$?
chk_eq "M17 tools 量具坏: one judged source + one broken gauge — typed 14, not silence" \
  14 "$rc"
chk_contains "M17 tools 量具坏: as unknown-source, never claiming the counter was read" \
  "reason=unknown-source" "$out"
chk_contains "M17 tools 量具坏: and naming the undecodable stream" "undecodable" "$out"
chk_contains "M17 tools 量具坏: the disposition is the gauge, not the seat" \
  "REPAIR THE GAUGE FIRST" "$out"
chk_not_contains "M17 tools 量具坏: so it never tells the operator to steer on this line" \
  "then steer a concrete next step" "$out"

# ── tools 半行帧: a `tool_use` line caught MID-WRITE may not publish a terminal verdict ────
# `complete_frames_integrity` dropped a non-empty trailing fragment and still returned clean, so
# the bytes BEFORE a landing frame read as a settled counter and 14/tools-silent shipped while
# the tool was arriving (cold review R1 T1). The fragment makes the tools source unknown, and
# because those bytes arrived inside the window it credits movement — so no verdict at all.
u_seed uHALF "$UREPO"
tool_ev uHALF 1                                   # one COMPLETE frame: the counter's baseline
rc="$(u_status uHALF >/dev/null 2>&1; echo $?)"
chk_eq "M17 半行帧: first read RUNNING" 10 "$rc"
/bin/sleep 1
# NO trailing newline: this is exactly what a concurrent writer leaves at a window boundary
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2"' \
  >> "$WATCH_RUN_DIR/uHALF.duplex.events.jsonl"
out="$(u_status uHALF)"; rc=$?
chk_eq "M17 半行帧 (DAMAGE ORACLE): a tool frame still landing NEVER fires 14" 10 "$rc"
chk_contains "M17 半行帧: the arriving bytes are published as engine activity" \
  "progress_reason=repo-silent+tools-active" "$out"
printf '}]}}\n' >> "$WATCH_RUN_DIR/uHALF.duplex.events.jsonl"   # the frame lands for real
/bin/sleep 1
out="$(u_status uHALF)"; rc=$?
chk_eq "M17 半行帧: and the COMPLETED frame keeps the verdict withheld" 10 "$rc"
chk_contains "M17 半行帧: now on a countable frame" \
  "progress_reason=repo-silent+tools-active" "$out"
# 坏红 pair: a fragment that never changes is a TRUNCATED stream, not a landing frame — the
# window must still conclude, or half a line would disable this state forever.
u_seed uHALF2 "$UREPO"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9"' \
  >> "$WATCH_RUN_DIR/uHALF2.duplex.events.jsonl"
rc="$(u_status uHALF2 >/dev/null 2>&1; echo $?)"
chk_eq "M17 半行帧 坏红: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(u_status uHALF2)"; rc=$?
chk_eq "M17 半行帧 坏红: a fragment static for the whole window still concludes" 14 "$rc"
chk_contains "M17 半行帧 坏红: as unknown-source — no frame was ever countable" \
  "reason=unknown-source" "$out"
chk_contains "M17 半行帧 坏红: naming the incomplete line" "incomplete line" "$out"

# ── pane 坏红: all three sources judged and still ─────────────────────────────────────────
pane_group pg1 && PG1="$PGID" || PG1=""
if [ -n "$PG1" ]; then
  u_seed uPANE "$UREPO" "$PG1"
  rc="$(u_status uPANE >/dev/null 2>&1; echo $?)"
  chk_eq "M17 pane 坏红: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  out="$(u_status uPANE)"; rc=$?
  chk_eq "M17 pane 坏红: three judged sources, none moved — typed 14" 14 "$rc"
  chk_contains "M17 pane 坏红: with nothing left unjudged" \
    "reason=repo-silent+tools-silent" "$out"
  chk_contains "M17 pane 坏红: and the pane source named in the evidence" \
    "the process set in the pane's group" "$out"
  pane_kill "$PG1"
else
  _record "M17 pane 坏红 fixture came up" 0 "the pane-group leader never published a pgid"
fi

# ── pane 好绿: a subprocess born mid-window IS progress ───────────────────────────────────
pane_group pg2 && PG2="$PGID" || PG2=""
if [ -n "$PG2" ]; then
  u_seed uPANE2 "$UREPO" "$PG2"
  rc="$(u_status uPANE2 >/dev/null 2>&1; echo $?)"
  chk_eq "M17 pane 好绿: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  : > "$SANDBOX/pg2.spawn"                        # the pane forks a child: work with no trace
  await "[ \"\$(pgrep -g $PG2 | grep -c .)\" -ge 2 ]" 100
  out="$(u_status uPANE2)"; rc=$?
  chk_eq "M17 pane 好绿: the birth is progress — the verdict is WITHHELD past the window" \
    10 "$rc"
  chk_contains "M17 pane 好绿: published as the same WITHHELD observation" \
    "progress_reason=repo-silent+tools-active" "$out"
  /bin/sleep 1
  rc="$(u_status uPANE2 >/dev/null 2>&1; echo $?)"
  chk_eq "M17 pane 好绿 DAMAGE ORACLE: no further births and the same window fires 14" \
    14 "$rc"
  pane_kill "$PG2"
else
  _record "M17 pane 好绿 fixture came up" 0 "the pane-group leader never published a pgid"
fi

# ── pane 量具坏 + the third sub-reason: unknown-source ────────────────────────────────────
# A pgid with no process left cannot answer, while the repo trace and the tool frames both can
# and both stand still. The union has its quorum, so the operator IS called — and the word says
# what called them: a source nobody could read, not a proof of stillness.
u_seed uPGONE "$UREPO" 999999
rc="$(u_status uPGONE >/dev/null 2>&1; echo $?)"
chk_eq "M17 pane 量具坏: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(u_status uPGONE)"; rc=$?
chk_eq "M17 pane 量具坏: quorum met and still — typed 14" 14 "$rc"
chk_contains "M17 pane 量具坏: reported as unknown-source, never as tools-silent" \
  "reason=unknown-source" "$out"
chk_contains "M17 pane 量具坏: and the blind source is named in the evidence" \
  "no process left in the pane's group 999999" "$out"

# ── repo 量具坏, union still judgeable: the honest three-valued case ──────────────────────
pane_group pg3 && PG3="$PGID" || PG3=""
if [ -n "$PG3" ]; then
  u_seed uRBLIND "$SANDBOX/blind" "$PG3"
  rc="$(u_status uRBLIND >/dev/null 2>&1; echo $?)"
  chk_eq "M17 repo 量具坏: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  out="$(u_status uRBLIND)"; rc=$?
  chk_eq "M17 repo 量具坏: the other two sources carry the quorum — typed 14" 14 "$rc"
  chk_contains "M17 repo 量具坏: as unknown-source, never claiming the repo was measured" \
    "reason=unknown-source" "$out"
  chk_contains "M17 repo 量具坏: and the git probe named as the blind one" \
    "cwd not a repo" "$out"
  chk_not_contains "M17 repo 量具坏: the frozen-probe list never claims HEAD stood still" \
    "dirty-tree hash" "$out"
  # PAIRED GREEN: same blind repo, and now the pane moves — the union must withhold again
  u_seed uRBLIND2 "$SANDBOX/blind" "$PG3"
  rc="$(u_status uRBLIND2 >/dev/null 2>&1; echo $?)"
  chk_eq "M17 repo 量具坏 PAIRED GREEN: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  : > "$SANDBOX/pg3.spawn"
  await "[ \"\$(pgrep -g $PG3 | grep -c .)\" -ge 2 ]" 100
  out="$(u_status uRBLIND2)"; rc=$?
  chk_eq "M17 repo 量具坏 PAIRED GREEN: a moving pane withholds the verdict" 10 "$rc"
  chk_not_contains "M17 repo 量具坏 PAIRED GREEN: and never fires unknown-source" \
    "STALLED-PROGRESS" "$out"
  pane_kill "$PG3"
else
  _record "M17 repo 量具坏 fixture came up" 0 "the pane-group leader never published a pgid"
fi

# ── pane 身份不符: a REAL group whose recorded leader start-time does not match ────────────
# start persists `pane_pid + pane_lstart` precisely because a pgid is REUSABLE, but this source
# validated only that the pgid was numeric: an unrelated group's stability could vote silent and
# its churn could refresh the progress clock forever, on a source that claims to be watching
# THIS session (cold review R1 P2). The recorded identity is now the fence.
pane_group pg5 && PG5="$PGID" || PG5=""
if [ -n "$PG5" ]; then
  u_seed uPSTALE "$UREPO" "$PG5"
  printf 'pane_lstart=Mon Jan  1 00:00:00 2001\n' >> "$WATCH_RUN_DIR/uPSTALE.duplex.meta"
  rc="$(u_status uPSTALE >/dev/null 2>&1; echo $?)"
  chk_eq "M17 pane 身份不符: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  out="$(u_status uPSTALE)"; rc=$?
  chk_eq "M17 pane 身份不符: the sources that CAN be judged conclude — typed 14" 14 "$rc"
  chk_contains "M17 pane 身份不符: the pane source is unknown, never judged silent" \
    "reason=unknown-source" "$out"
  chk_contains "M17 pane 身份不符: and the drift is named as pid reuse" \
    "pid reuse, so this group is not this session's" "$out"
  # PAIRED GREEN: the same LIVE group with its real recorded start-time is judged, and a birth
  # inside it is progress — the fence rejects impostors, not the session's own pane.
  u_seed uPFENCE "$UREPO" "$PG5"
  printf 'pane_lstart=%s\n' "$(ps -p "$PG5" -o lstart= | sed 's/ *$//')" \
    >> "$WATCH_RUN_DIR/uPFENCE.duplex.meta"
  rc="$(u_status uPFENCE >/dev/null 2>&1; echo $?)"
  chk_eq "M17 pane 身份相符 PAIRED GREEN: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  : > "$SANDBOX/pg5.spawn"
  await "[ \"\$(pgrep -g $PG5 | grep -c .)\" -ge 2 ]" 100
  out="$(u_status uPFENCE)"; rc=$?
  chk_eq "M17 pane 身份相符 PAIRED GREEN: a birth in the fenced group is progress" 10 "$rc"
  chk_contains "M17 pane 身份相符 PAIRED GREEN: judged, and the birth refreshed the clock" \
    "progress_reason=repo-silent+tools-active" "$out"
  pane_kill "$PG5"
else
  _record "M17 pane 身份 fixture came up" 0 "the pane-group leader never published a pgid"
fi

# ── repo 好绿 under the union: the repo trace moving needs no sub-reason word ─────────────
pane_group pg4 && PG4="$PGID" || PG4=""
if [ -n "$PG4" ]; then
  u_seed uREPOMOVE "$UREPO" "$PG4"
  rc="$(u_status uREPOMOVE >/dev/null 2>&1; echo $?)"
  chk_eq "M17 repo 好绿: first read RUNNING" 10 "$rc"
  /bin/sleep 1
  printf 'real work\n' >> "$UREPO/work.txt"
  out="$(u_status uREPOMOVE)"; rc=$?
  chk_eq "M17 repo 好绿: a moving repo trace still withholds the verdict" 10 "$rc"
  chk_contains "M17 repo 好绿: and publishes when it last moved" "last_progress_at=" "$out"
  chk_not_contains "M17 repo 好绿: no WITHHELD word — the repo trace itself is what moved" \
    "progress_reason=" "$out"
  pane_kill "$PG4"
else
  _record "M17 repo 好绿 fixture came up" 0 "the pane-group leader never published a pgid"
fi

# ── the quorum FLOOR: every source blind is not a verdict, it is an admission ─────────────
u_seed uBLIND3 "$SANDBOX/blind"                   # no pane_pid, not a repo, junk stream
printf '{still not json\n' >> "$WATCH_RUN_DIR/uBLIND3.duplex.events.jsonl"
rc="$(u_status uBLIND3 >/dev/null 2>&1; echo $?)"
chk_eq "M17 quorum floor: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(u_status uBLIND3)"; rc=$?
chk_eq "M17 quorum floor: zero judged sources NEVER fires 14" 10 "$rc"
chk_contains "M17 quorum floor: and says so" "below the judged quorum (0/1)" "$out"
chk_contains "M17 quorum floor: naming every blind source — repo" "cwd not a repo" "$out"
chk_contains "M17 quorum floor: naming every blind source — tools" "undecodable" "$out"
chk_contains "M17 quorum floor: naming every blind source — pane" \
  "no pane_pid in session meta" "$out"
/bin/sleep 1
rc="$(u_status uBLIND3 >/dev/null 2>&1; echo $?)"
chk_eq "M17 quorum floor: still no verdict across a SECOND window" 10 "$rc"

# ── the SHARED measurement budget: a slow gauge is not a control-plane failure ─────────────
# Three git reads at 20s each plus `pgrep` summed to 70s of local timeout under a 30s classify
# watchdog, so a slow repo probe published ENGINE-SILENT — the control plane accusing itself for
# a gauge problem (cold review R1 P3). One budget for the whole union, and a probe with none
# left answers unknown, which this state already knows how to carry.
SLOWBIN="$SANDBOX/slowbin"; mkdir -p "$SLOWBIN"
printf '#!/bin/sh\nsleep 3\nexec %s "$@"\n' "$(command -v git)" > "$SLOWBIN/git"
chmod +x "$SLOWBIN/git"
slow_status() { PATH="$SLOWBIN:$PATH" AGENT_WATCH_STATUS_TIMEOUT=10 \
  AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status "$1" 2>&1; }
u_seed uSLOW "$UREPO"
rc="$(slow_status uSLOW >/dev/null 2>&1; echo $?)"
chk_eq "M17 预算: a slow git leaves the first read RUNNING, never ENGINE-SILENT" 10 "$rc"
T0=$(date +%s)
out="$(slow_status uSLOW)"; rc=$?
T1=$(date +%s)
chk_eq "M17 预算: the second read concludes on the source that COULD be measured" 14 "$rc"
chk_contains "M17 预算: as unknown-source" "reason=unknown-source" "$out"
chk_contains "M17 预算: naming the spent shared budget" "budget ran out mid-probe" "$out"
chk_not_contains "M17 预算: and never as a control-plane verdict" "ENGINE-SILENT" "$out"
chk_eq "M17 预算: the whole classify stayed inside its own 10s deadline" 1 \
  "$([ $((T1 - T0)) -lt 10 ] && echo 1 || echo 0)"

# ── the budget must be under the deadline for EVERY value the knob can take ────────────────
# The share alone was not that guarantee: `max(1.0, timeout*0.4)` gave AGENT_WATCH_STATUS_TIMEOUT=1
# a 1.0s budget — the whole classify watchdog — and =2 a 1.0s/50% one, so the two smallest
# supported knob values kept the ENGINE-SILENT-for-a-slow-gauge race this budget exists to
# remove (cold review R2 P3). A 1s deadline cannot be probed through a fixture honestly (the
# fixture's own tmux round trips are the same order), so the grid is checked STATICALLY, in
# this suite's S4 stance: the shipped `progress_budget` body and its constants are read out of
# the file TEXT and run verbatim over the knob grid — never a dynamic import of the module
# (white-box coupling ban), never a re-implementation of the arithmetic here.
GRID="$SANDBOX/budgetgrid.py"
cat > "$GRID" <<'GRIDPY'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
wanted = [n for n in tree.body
          if (isinstance(n, ast.Assign)
              and any(getattr(t, "id", "").startswith("PROGRESS_BUDGET_") for t in n.targets))
          or (isinstance(n, ast.FunctionDef) and n.name == "progress_budget")]
if len(wanted) != 4:                    # 3 constants + the function: a rename must be seen
    sys.exit("budget-source-not-found:%d" % len(wanted))
bad = []
for knob in (1, 2, 10, 30):
    # ProbeBudget is stubbed to hand back the total it was sized with, and status_timeout() to
    # the knob value the CLI would have parsed: the expression under test stays the shipped one
    ns = {"ProbeBudget": lambda total: total, "status_timeout": lambda: knob}
    exec(compile(ast.Module(body=wanted, type_ignores=[]), "<budget>", "exec"), ns)
    budget = ns["progress_budget"]()
    if not 0 < budget < knob:
        bad.append("timeout=%s budget=%.3f" % (knob, budget))
print(" ".join(bad) if bad else "ALL-UNDER-DEADLINE 4")
GRIDPY
chk_eq "M17 预算 knob grid: the shared budget is a positive slice strictly under the classify deadline" \
  "ALL-UNDER-DEADLINE 4" "$(python3 "$GRID" "$DUPLEXCTL")"
# PAIRED RED: the RETIRED R1 arithmetic, fed to the SAME script — it must name the knob value it
# broke on, or this grid is a green surface rather than a gate. The green side above reads the
# shipped source; only this red side is a reconstruction, and it is the code that was replaced.
cat > "$SANDBOX/r1-budget.py" <<'R1PY'
PROGRESS_BUDGET_SHARE = 0.4
PROGRESS_BUDGET_HEADROOM = 1.0
PROGRESS_BUDGET_FLOOR = 0.2


def progress_budget():
    return ProbeBudget(max(1.0, status_timeout() * PROGRESS_BUDGET_SHARE))
R1PY
chk_eq "M17 预算 knob grid PAIRED RED: the R1 arithmetic reds on the smallest knob" \
  "timeout=1 budget=1.000" "$(python3 "$GRID" "$SANDBOX/r1-budget.py")"
unset AGENT_WATCH_STALL_MINS
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# FL — FOLLOW MODE (2026-09-01). `agentctl watch` is the seat's attachment to a SESSION, not to
# one round of it: re-arming after a rotation, after a WATCH-TIMEOUT or after the host reaped the
# supervisor was a purely mechanical orchestrator round (two seats, ~27/day). Following is the
# default, so the arms below assert the LIFETIME rule from both sides — what must keep the
# waiter, and what must still end it — while the pinned arms above assert that the ceiling of 0
# still reproduces the single-round waiter. Same rules as the rest of this file: public CLI, a
# real classify, real signals; nothing here hand-writes a terminal record.
# ═════════════════════════════════════════════════════════════════════════════════════════

echo "== FL1: a steer that opens the next round is followed, not reported =="
sw_sandbox
seed fl1 70000; running fl1
# NOT a race: the round rotates under a LIVE supervisor and with no terminal record anywhere, so
# there is no window in which this waiter could have adopted anything else. The rotation is the
# only fact its next read can find, and the oracle is that it re-fenced its episode on the new
# round (a second arm) instead of staying attached to the closed one. The rotate-after-a-DEAD-
# supervisor flavour is FL3's: there the liveness fact, not the round, is what licenses the
# re-arm, and mixing the two into one arm would let either half pass for the other.
export AGENT_WATCH_MAX_POLLS=1000
AGENT_WATCH_POLL_SECS=2 bash "$AGENTCTL" watch fl1 > "$SANDBOX/fl1.log" 2>&1 &
FL1W=$!
await "[ -s '$WATCH_RUN_DIR/fl1.watch.super.json' ]" 200
/bin/sleep 1                                           # both loops are polling a RUNNING session
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/fl1.duplex.meta"   # what a steer commits
rm -f "$WATCH_RUN_DIR/fl1.duplex.meta.bak"
chk_eq "FL1 the waiter saw the rotation and aimed at the new round" 1 \
  "$(await "grep -q 'round rotated 1 → 2' '$SANDBOX/fl1.log'" 400 && echo 1 || echo 0)"
chk_eq "FL1 DAMAGE ORACLE: it re-armed for the new round instead of riding the closed one" 1 \
  "$(await "[ \"\$(grep -c 'DUPLEX-WATCH ARMED' '$SANDBOX/fl1.log')\" -ge 2 ]" 400 && echo 1 || echo 0)"
printf '3\n' > "$WATCH_RUN_DIR/fl1.duplex.rc"          # round 2 classifies FAILED 2
wait "$FL1W" 2>/dev/null; rc=$?
fl1log="$(cat "$SANDBOX/fl1.log")"
chk_eq "FL1 and it reports the class the NEW round concluded with" 2 "$rc"
chk_eq "FL1 the record it read is the new round's" "2" "$(record_round fl1)"
chk_eq "FL1 the live supervisor was re-attached, never duplicated" 1 "$(spawn_count fl1)"
chk_eq "FL1 DAMAGE ORACLE: a rotation is never reported as a lost supervisor" 0 \
  "$(printf '%s\n' "$fl1log" | grep -c 'SUPERVISOR-LOST')"
chk_eq "FL1 DAMAGE ORACLE: and it spends none of the bounded re-arm budget" 0 \
  "$(printf '%s\n' "$fl1log" | grep -c 'following: re-arm')"
chk_eq "FL1 exactly ONE verdict left the waiter, the one it exited on" 1 \
  "$(printf '%s\n' "$fl1log" | grep -c '^EXIT=')"
sw_clean

echo "== FL2: a reported WATCH-TIMEOUT re-arms, and the ceiling really ends it =="
sw_sandbox
seed fl2 70000; running fl2
export AGENT_WATCH_MAX_POLLS=1            # the supervisor's own budget: one poll, then 7
out="$(AGENT_WATCH_FOLLOW_MAX=2 bash "$AGENTCTL" watch fl2 2>&1)"; rc=$?
chk_eq "FL2 the exhausted follower exits with the LAST verdict, really 7" 7 "$rc"
chk_eq "FL2 three rounds were reported, not one" 3 \
  "$(printf '%s\n' "$out" | grep -c 'WATCH TIMEOUT')"
chk_eq "FL2 every reported round carries its own machine marker" 3 \
  "$(printf '%s\n' "$out" | grep -c '^EXIT=7$')"
chk_contains "FL2 the first re-arm names its bound" "re-arm 1/2" "$out"
chk_contains "FL2 and the last one exhausts it" "re-arm 2/2" "$out"
chk_not_contains "FL2 DAMAGE ORACLE: never one re-arm past the ceiling" "re-arm 3/2" "$out"
chk_eq "FL2 DAMAGE ORACLE: each re-arm re-established a REAL sensing loop" 3 "$(spawn_count fl2)"
chk_eq "FL2 the machine tail is still the verdict this process exited on" "EXIT=7" \
  "$(printf '%s\n' "$out" | tail -1)"
sw_clean

echo "== FL3: a supervisor the host reaped is re-established; the session's answer still lands =="
sw_sandbox
seed fl3 70000; running fl3
export AGENT_WATCH_MAX_POLLS=1000
AGENT_WATCH_FOLLOW_MAX=1 bash "$AGENTCTL" watch fl3 > "$SANDBOX/fl3.log" 2>&1 &
FL3=$!
await "[ -s '$WATCH_RUN_DIR/fl3.watch.super.json' ]" 200
kill -9 "$(lease_pid fl3)" 2>/dev/null    # the reaper's shape: no note, no conclusion, no lease change
chk_eq "FL3 the reaped supervisor is reported AND re-armed" 1 \
  "$(await "grep -q 'following: re-arm 1/1' '$SANDBOX/fl3.log'" 400 && echo 1 || echo 0)"
chk_eq "FL3 a second sensing loop really came up" 1 \
  "$(await '[ "$(spawn_count fl3)" -ge 2 ]' 400 && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/fl3.duplex.rc"
wait "$FL3" 2>/dev/null; rc=$?
fl3log="$(cat "$SANDBOX/fl3.log")"
chk_eq "FL3 and the session's real conclusion still reaches the seat" 0 "$rc"
chk_contains "FL3 the followed loss was reported as the published 12" "EXIT=12" "$fl3log"
chk_contains "FL3 with the liveness fact that licensed the re-arm" "reason=dead" "$fl3log"
chk_not_contains "FL3 DAMAGE ORACLE: no waiter-internal code ever reached the surface" \
  "EXIT=18" "$fl3log"
sw_clean

echo "== FL4: an ACTION verdict ends the waiter even with budget left =="
sw_sandbox
seed fl4 70000
printf '0\n' > "$WATCH_RUN_DIR/fl4.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
out="$(AGENT_WATCH_FOLLOW_MAX=5 bash "$AGENTCTL" watch fl4 2>&1)"; rc=$?
chk_eq "FL4 DONE 0 ends it: the seat is woken by the exit, so 0 may never be swallowed" 0 "$rc"
chk_eq "FL4 exactly one verdict marker" 1 "$(printf '%s\n' "$out" | grep -c '^EXIT=')"
chk_not_contains "FL4 and no re-arm" "following: re-arm" "$out"
chk_eq "FL4 one episode, one supervisor" 1 "$(spawn_count fl4)"
# 14 STALLED-PROGRESS is the deliberate NON-follow: a false 14 is a three-source blind spot to
# fix, and following one would hide exactly the case the progress work exists to surface.
FLREPO="$SANDBOX/flrepo"; mkdir -p "$FLREPO"
git -C "$FLREPO" init -q 2>/dev/null
git -C "$FLREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
seed fl5; running fl5
printf 'engine=claude\ncwd=%s\nround=1\n' "$FLREPO" > "$WATCH_RUN_DIR/fl5.duplex.meta"
out="$(AGENT_WATCH_PROGRESS_MINS=0.01 AGENT_WATCH_FOLLOW_MAX=5 bash "$AGENTCTL" watch fl5 2>&1)"
rc=$?
chk_eq "FL4 STALLED-PROGRESS 14 ends it too" 14 "$rc"
chk_eq "FL4 (14) exactly one verdict marker" 1 "$(printf '%s\n' "$out" | grep -c '^EXIT=')"
chk_not_contains "FL4 (14) and no re-arm" "following: re-arm" "$out"
sw_clean

echo "== FL5: the 0 ceiling IS the single-round waiter (the compatibility arm) =="
sw_sandbox
seed fl6 70000; running fl6
export AGENT_WATCH_MAX_POLLS=1
out="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch fl6 2>&1)"; rc=$?
chk_eq "FL5 with the ceiling at 0 a WATCH-TIMEOUT exits, exactly as before follow" 7 "$rc"
chk_eq "FL5 one verdict, one marker" 1 "$(printf '%s\n' "$out" | grep -c '^EXIT=7$')"
chk_not_contains "FL5 and it never re-armed" "following: re-arm" "$out"
chk_eq "FL5 one supervisor only" 1 "$(spawn_count fl6)"
chk_eq "FL5 the machine tail is the verdict" "EXIT=7" "$(printf '%s\n' "$out" | tail -1)"
sw_clean

echo "== FL6: the waiter-internal continuation codes are ONE vocabulary across two languages =="
# The codes are declared TWICE — python decides whether a round ends the waiter, bash loops on the
# numbers — and the numbers are the whole contract. A one-sided edit that lands on an ACTION code
# makes the shell consume that action exit as a re-arm, and the seat then waits forever on a
# verdict that already happened (review NB1). Static, because that is a property of the SOURCE:
# no fixture can be trusted to drive whichever code a future collision picks, and the failure is
# invisible by inspection — both files read correct on their own.
fl_codes="$(python3 - "$AW_DIR" <<'FLPY'
import ast, os, re, sys

d = sys.argv[1]


def ints(path, pred):                       # module-level `NAME = <int literal>`, nothing else
    out = {}
    for node in ast.parse(open(path, encoding="utf-8").read()).body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Constant):
            continue
        val = node.value.value
        if isinstance(val, bool) or not isinstance(val, int):
            continue
        for tgt in node.targets:
            if isinstance(tgt, ast.Name) and pred(tgt.id):
                out[tgt.id] = val
    return out


watchctl = os.path.join(d, "watchctl.py")
py = ints(watchctl, lambda n: n.startswith("FOLLOW_"))
arm = ints(watchctl, lambda n: n == "PROCEED_TO_ARM")   # the sibling internal code on these verbs
published = ints(os.path.join(d, "duplexctl.py"), lambda n: n.startswith("EXIT_"))
sh_src = open(os.path.join(d, "agentctl"), encoding="utf-8").read()
sh = {m.group(1): int(m.group(2))
      for m in re.finditer(r"(?m)^(FOLLOW_[A-Z_]+)=([0-9]+)\b", sh_src)}
taken = {**published, **arm}
bad = []
if not py or not sh or not published or not arm:
    bad.append("source-not-found:py=%d bash=%d published=%d arm=%d"
               % (len(py), len(sh), len(published), len(arm)))
# named, so a rename on either side cannot silently empty this gate instead of reddening it
for name in ("FOLLOW_ROTATED", "FOLLOW_REARM"):
    if name not in py or name not in sh:
        bad.append("cross-language-code-missing:%s" % name)
for name, val in sorted(sh.items()):
    if name not in py:
        bad.append("bash-only-code:%s=%d" % (name, val))
    elif py[name] != val:
        bad.append("disagree:%s py=%d bash=%d" % (name, py[name], val))
    # declared and then branched on as a bare number = an equality gate that proves nothing
    if not re.search(r'"\$%s"\)' % name, sh_src):
        bad.append("bash-code-not-consumed-by-name:%s" % name)
for lang, name, val in ([("py",) + kv for kv in sorted(py.items())]
                        + [("bash",) + kv for kv in sorted(sh.items())]):
    clash = sorted(n for n, v in taken.items() if v == val)
    if clash:
        bad.append("collides:%s %s=%d with %s" % (lang, name, val, ",".join(clash)))
print(" ".join(bad) if bad else "DISJOINT py=%d bash=%d" % (len(py), len(sh)))
FLPY
)"
chk_eq "FL6 internal codes agree across languages and collide with no published exit" \
  "DISJOINT py=3 bash=2" "$fl_codes"


# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== OB: the wait budget — --expect turns it on, and it fires ONCE per attempt+round =="
# Field motive (2026-09-02): waiting had NO budget, so a pathological turn reads RUNNING
# forever and only an operator ASKING ever notices — one review seat sat in `agentctl watch`
# on its own deliverable for 2h03m, typed RUNNING / tools-active the whole way. `--expect
# <minutes>` is the dispatcher's own estimate, 1.5x it is the report threshold, and the report
# is ONE per attempt+round: a state that repeats every poll would wake the orchestrator
# forever, and a state that never repeats after a steer would be a one-shot gauge.
# The clock under test is the ROUND EPOCH file, which is what every other round fence in this
# lane reads — so the fixtures backdate that file rather than sleeping through a real budget.
sw_sandbox
export AGENT_WATCH_MAX_POLLS=1000

ob_age() { # $1 session  $2 minutes to backdate the round clock by
  python3 -c 'import os, sys, time
t = time.time() - float(sys.argv[2]) * 60
os.utime(sys.argv[1], (t, t))' "$WATCH_RUN_DIR/$1.duplex.round-started" "$2"
}
ob_seed() { # $1 session  [$2 expect minutes ("" = none declared)]  [$3 round]
  seed "$1" 70000; running "$1"
  { printf 'engine=claude\ncwd=%s\nround=%s\npane_pid=70000\n' "$WT" "${3:-1}"
    [ -n "${2:-}" ] && printf 'expect_min=%s\n' "$2"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
}
# the published class, live record or the one this waiter already DELIVERED (rotated)
ob_class() {
  local f="$WATCH_RUN_DIR/$1.terminal.json"
  [ -s "$f" ] || f="$WATCH_RUN_DIR/$1.terminal.consumed.json"
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("class",""))' "$f" \
    2>/dev/null
}
# one Bash tool frame carrying a real command string — claude's own vocabulary
ob_tool() { # $1 session  $2 command text
  ev "$1" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"ob$RANDOM\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}"
}

# ── ob-neg-no-expect-unchanged: a session that declared no budget does not change ─────────
ob_seed obNONE ""
ob_age obNONE 600                        # ten hours into the round: any budget would have fired
out="$(AGENT_WATCH_MAX_POLLS=1 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obNONE 2>&1)"
rc=$?
chk_eq "ob-neg-no-expect-unchanged: ten hours in with no --expect is still WATCH-TIMEOUT" 7 "$rc"
chk_not_contains "ob-neg-no-expect-unchanged: the word never appears" "OVER-BUDGET" "$out"
st="$(bash "$AGENTCTL" status obNONE 2>&1)"; strc=$?
chk_eq "ob-neg-no-expect-unchanged: status still RUNNING" 10 "$strc"
chk_not_contains "ob-neg-no-expect-unchanged: and status prints no budget note" \
  "over budget" "$st"

# ── ob-pos-first-over-budget: the real supervised path, publish + waiter exit ─────────────
ob_seed obFIRE 0.02                      # 1.2s expected ⇒ 1.8s budget, at a 1s poll
out="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obFIRE 2>&1)"; rc=$?
chk_eq "ob-pos-first-over-budget: the waiter exits on the typed code" 19 "$rc"
chk_contains "ob-pos-first-over-budget: with the typed name" "OVER-BUDGET" "$out"
chk_contains "ob-pos-first-over-budget: naming the budget it blew" "expected 0.02min" "$out"
chk_contains "ob-pos-first-over-budget: and saying the WAIT is what ran out" \
  "the work is not judged" "$out"
chk_eq "ob-pos-first-over-budget: the SUPERVISOR published it as its own class" \
  "OVER-BUDGET" "$(ob_class obFIRE)"
st="$(bash "$AGENTCTL" status obFIRE 2>&1)"; strc=$?
chk_eq "ob-pos-first-over-budget: status stays RUNNING — advisory only" 10 "$strc"
chk_contains "ob-pos-first-over-budget: and carries the one-shot note" \
  "note: over budget by" "$st"

# ── ob-exit-not-private-code: 19 is free, and the SHELL really exits on it ────────────────
# 16/17/18 are watcher-private continuation codes the driving shell CONSUMES: a typed state
# minted on one of them would be swallowed by the follow loop instead of reaching the seat.
chk_eq "ob-exit-not-private-code: the shell exited ON that code, never consumed it" \
  "EXIT=19" "$(printf '%s\n' "$out" | tail -1)"
chk_not_contains "ob-exit-not-private-code: no re-arm swallowed the verdict" \
  "following: re-arm" "$out"
ob_codes="$(python3 - "$AW_DIR" "$AGENTCTL" <<'OBPY'
import ast, json, os, re, subprocess, sys

d, cli = sys.argv[1], sys.argv[2]
# the CLI is asked, never a copy of the table: what a consumer can enumerate is the contract
published = {s["code"] for s in json.loads(
    subprocess.run(["bash", cli, "states", "--json"], capture_output=True,
                   text=True).stdout)["states"]}


def ints(path, pred):                       # module-level `NAME = <int literal>`, nothing else
    out = {}
    for node in ast.parse(open(path, encoding="utf-8").read()).body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Constant):
            continue
        val = node.value.value
        if isinstance(val, bool) or not isinstance(val, int):
            continue
        for tgt in node.targets:
            if isinstance(tgt, ast.Name) and pred(tgt.id):
                out[tgt.id] = val
    return out


watchctl = os.path.join(d, "watchctl.py")
private = ints(watchctl, lambda n: n.startswith("FOLLOW_") or n == "PROCEED_TO_ARM"
               or n.startswith("ARM_"))
private.update({"sh:" + m.group(1): int(m.group(2))
                for m in re.finditer(r"(?m)^(FOLLOW_[A-Z_]+)=([0-9]+)\b",
                                     open(os.path.join(d, "agentctl"),
                                          encoding="utf-8").read())})
code = ints(os.path.join(d, "duplexctl.py"), lambda n: n == "EXIT_OVER_BUDGET").get(
    "EXIT_OVER_BUDGET")
bad = []
if code is None:
    bad.append("EXIT_OVER_BUDGET-not-found")
elif code not in published:
    bad.append("code-not-published:%d" % code)
else:
    clash = sorted(n for n, v in private.items() if v == code)
    if clash:
        bad.append("collides-with-private:%s" % ",".join(clash))
if not private:
    bad.append("private-codes-not-found")
print(" ".join(bad) if bad else "FREE %d" % code)
OBPY
)"
chk_eq "ob-exit-not-private-code: published, and disjoint from every waiter-internal code" \
  "FREE 19" "$ob_codes"

# ── ob-neg-same-round-no-repeat: the same round is not reported twice ─────────────────────
out2="$(AGENT_WATCH_MAX_POLLS=2 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obFIRE 2>&1)"
rc2=$?
chk_eq "ob-neg-same-round-no-repeat: a re-attached waiter falls back to the ordinary exit" \
  7 "$rc2"
chk_not_contains "ob-neg-same-round-no-repeat: no second OVER-BUDGET for that round" \
  "OVER-BUDGET" "$out2"

# ── the budget is ENGINE-INDEPENDENT, and one live codex cell proves it ───────────────────
# The clock is the round epoch and the report key is identity+round; neither reads `engine`.
# Only the evidence TAIL is engine-shaped, which is why one non-claude cell is enough here.
ob_seed obCX 0.02
printf 'engine=codex\ncwd=%s\nround=1\npane_pid=70000\nthread=t-fixture\nexpect_min=0.02\n' \
  "$WT" > "$WATCH_RUN_DIR/obCX.duplex.meta"
outcx="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obCX 2>&1)"; rccx=$?
chk_eq "ob-pos-first-over-budget: a codex-engine session reports the same typed code" 19 \
  "$rccx"
chk_contains "ob-pos-first-over-budget: (codex) same measurement line" \
  "OVER-BUDGET: this round has been running" "$outcx"

# ── ob-pos-new-round-after-steer: a steer opens a new round and a new budget ──────────────
# The round rotation itself is `commit_round_state`'s (covered by the duplex suite); what is
# under test here is that the REPORT KEY moves with it.
printf 'engine=claude\ncwd=%s\nround=2\npane_pid=70000\nexpect_min=0.02\n' "$WT" \
  > "$WATCH_RUN_DIR/obFIRE.duplex.meta"
: > "$WATCH_RUN_DIR/obFIRE.duplex.round-started"
out3="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obFIRE 2>&1)"; rc3=$?
chk_eq "ob-pos-new-round-after-steer: the new round may report again" 19 "$rc3"
chk_contains "ob-pos-new-round-after-steer: as the same typed class" "OVER-BUDGET" "$out3"

# ── ob-pos-new-attempt-after-interrupt: a new attempt may report the SAME round again ─────
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace obFIRE >/dev/null 2>&1
out4="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obFIRE 2>&1)"; rc4=$?
chk_eq "ob-pos-new-attempt-after-interrupt: the new attempt reports round 2 again" 19 "$rc4"
chk_eq "ob-pos-new-attempt-after-interrupt: three reports, three distinct keys" 3 \
  "$(grep -c . "$WATCH_RUN_DIR/obFIRE.duplex.expect-report")"

# ── ob-tail-bounded-600: the evidence tail is bounded by ROWS and by BYTES, line-wise ─────
ob_seed obTAIL 0.02
i=1
while [ "$i" -le 20 ]; do ob_tool obTAIL "short-$i"; i=$((i + 1)); done
out5="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obTAIL --inline 2>&1)"; rc5=$?
chk_eq "ob-tail-bounded-600: the inline waiter reports the same typed code" 19 "$rc5"
rows="$(printf '%s\n' "$out5" | grep '^  --:' | sed 's/ ===$//')"
chk_eq "ob-tail-bounded-600: 20 item frames yield exactly the 8-row cap" 8 \
  "$(printf '%s\n' "$rows" | grep -c .)"
chk_eq "ob-tail-bounded-600: and the newest frame is the last row" 1 \
  "$(printf '%s\n' "$rows" | tail -1 | grep -c 'short-20')"
chk_eq "ob-tail-bounded-600: rows stay inside the byte bound" 1 \
  "$([ "$(printf '%s\n' "$rows" | wc -c | tr -d ' ')" -le 600 ] && echo 1 || echo 0)"
# the BYTE bound now bites: 8 rows of 60-char commands do not fit in 600, so WHOLE rows are
# dropped from the oldest end and every surviving row still parses
ob_seed obTAIL2 0.02
i=1
while [ "$i" -le 12 ]; do
  ob_tool obTAIL2 "pytest -q tests/very/long/path/case-$i --maxfail=1 -k selector-$i"
  i=$((i + 1))
done
out6="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obTAIL2 --inline 2>&1)"; rc6=$?
chk_eq "ob-tail-bounded-600: (long rows) still the typed code" 19 "$rc6"
rows6="$(printf '%s\n' "$out6" | grep '^  --:' | sed 's/ ===$//')"
n6="$(printf '%s\n' "$rows6" | grep -c .)"
chk_eq "ob-tail-bounded-600: the byte bound dropped whole rows (fewer than the 8-row cap)" 1 \
  "$([ "$n6" -ge 1 ] && [ "$n6" -lt 8 ] && echo 1 || echo 0)"
chk_eq "ob-tail-bounded-600: total still inside 600 bytes" 1 \
  "$([ "$(printf '%s\n' "$rows6" | wc -c | tr -d ' ')" -le 600 ] && echo 1 || echo 0)"
chk_eq "ob-tail-bounded-600: every surviving row is WHOLE (never cut mid-row)" 0 \
  "$(printf '%s\n' "$rows6" | grep -cv '^  --:--:-- tool_use Bash pytest -q ')"
chk_eq "ob-tail-bounded-600: and the newest row survived" 1 \
  "$(printf '%s\n' "$rows6" | tail -1 | grep -c 'case-12')"

# ── ob-tail-tolerates-list-params: a legal-JSON frame of the WRONG SHAPE may not kill 19 ───
# Review R1 M1: `params` arriving as a LIST is decodable JSON, the integrity layer passes it,
# and the evidence tail then took the sensing loop out with an AttributeError — the budget had
# already fired, so the crash cost the verdict the caller was owed.
ob_seed obSHAPE 0.02
ev obSHAPE '{"method":"item/started","params":[1,2]}'
ev obSHAPE '{"type":"assistant","message":[1,2]}'
ev obSHAPE '{"method":"item/started","params":{"item":{"type":"commandExecution","command":["not","a","string"]}}}'
out7="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obSHAPE --inline 2>&1)"; rc7=$?
chk_eq "ob-tail-tolerates-list-params: the typed verdict still forms" 19 "$rc7"
chk_contains "ob-tail-tolerates-list-params: and the odd shapes are MARKED, not dropped" \
  "[unparsed item]" "$out7"
chk_not_contains "ob-tail-tolerates-list-params: no traceback reached the surface" \
  "AttributeError" "$out7"
chk_eq "ob-tail-tolerates-list-params: three odd frames, three marked rows" 3 \
  "$(printf '%s\n' "$out7" | grep -c '\[unparsed item\]')"

# ── ob-neg-set-but-under-budget-still-running: an INDEPENDENT under-budget time point ──────
# The "set but not over" cell may not be filled by a session that is over the threshold and
# merely suppressed by the ledger (review R1 B3): a threshold wrongly moved to 0 would still
# pass that. This session declares a 60min budget on a round that just opened.
ob_seed obUNDER 60
st="$(bash "$AGENTCTL" status obUNDER 2>&1)"; strc=$?
chk_eq "ob-neg-set-but-under-budget-still-running: status is plain RUNNING" 10 "$strc"
chk_not_contains "ob-neg-set-but-under-budget-still-running: and prints no budget note" \
  "over budget" "$st"
outu="$(AGENT_WATCH_MAX_POLLS=2 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obUNDER 2>&1)"
rcu=$?
chk_eq "ob-neg-set-but-under-budget-still-running: the waiter takes the ordinary exit" 7 "$rcu"
chk_not_contains "ob-neg-set-but-under-budget-still-running: never the typed 19" \
  "OVER-BUDGET" "$outu"
chk_eq "ob-neg-set-but-under-budget-still-running: and nothing was recorded as reported" 0 \
  "$([ -s "$WATCH_RUN_DIR/obUNDER.duplex.expect-report" ] && echo 1 || echo 0)"

# ── the ledger's three states, each pinned in BOTH directions ──────────────────────────────
# MISSING ⇒ eligible: the ledger is the only thing that suppresses a report, so removing it
# must make the SAME round reportable again (and prove the suppression above was the ledger's
# doing, not a spent budget).
ob_seed obMARK 0.02
outm="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obMARK 2>&1)"; rcm=$?
chk_eq "ob-doc-marker-missing-eligible: the first report is delivered" 19 "$rcm"
chk_eq "ob-doc-marker-missing-eligible: and it was recorded exactly once" 1 \
  "$(grep -c . "$WATCH_RUN_DIR/obMARK.duplex.expect-report")"
rm -f "$WATCH_RUN_DIR/obMARK.duplex.expect-report"
outm2="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obMARK 2>&1)"; rcm2=$?
chk_eq "ob-doc-marker-missing-eligible: with the ledger gone the same round reports again" \
  19 "$rcm2"
# CORRUPT ⇒ eligible: garbage lines are not this key, so they suppress nothing, and reading
# them may not break sensing either
printf 'not-a-key\n\x00\xff garbage\n' > "$WATCH_RUN_DIR/obMARK.duplex.expect-report"
outm3="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obMARK 2>&1)"; rcm3=$?
chk_eq "ob-doc-marker-corrupt-eligible: a garbage ledger suppresses nothing" 19 "$rcm3"
chk_eq "ob-doc-marker-corrupt-eligible: and the real key was appended beside the garbage" 1 \
  "$(grep -c "/1$" "$WATCH_RUN_DIR/obMARK.duplex.expect-report")"
# UNWRITABLE ⇒ suppressed, and ordinary sensing CONTINUES (a directory in the ledger's place
# is the portable spelling of "this append can never succeed" — no uid can write it)
ob_seed obNOMARK 0.02
mkdir -p "$WATCH_RUN_DIR/obNOMARK.duplex.expect-report"
outn="$(AGENT_WATCH_MAX_POLLS=3 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obNOMARK 2>&1)"
rcn=$?
chk_eq "ob-doc-marker-unwritable-suppressed: no report, and sensing runs to its own budget" \
  7 "$rcn"
chk_not_contains "ob-doc-marker-unwritable-suppressed: the verdict never formed" \
  "OVER-BUDGET" "$outn"
rmdir "$WATCH_RUN_DIR/obNOMARK.duplex.expect-report"
outn2="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obNOMARK 2>&1)"; rcn2=$?
chk_eq "ob-doc-marker-unwritable-suppressed: once recordable again, the round reports" 19 \
  "$rcn2"

# ── ob-neg-concurrent-single-publisher: two observers of one round, ONE publisher ──────────
# Review R1 B1: `_expect_reported` + `_expect_record` used to be a lock-free check-then-append,
# so two sensing loops could both see "not reported" and both publish. The claim now runs
# under the lane's single-writer flock, which makes the OUTCOME deterministic even though the
# winner is not: exactly one 19, exactly one ledger line, and the loser keeps sensing.
ob_seed obRACE 0.02
ob_age obRACE 5                          # already over budget at the first poll of both
AGENT_WATCH_MAX_POLLS=4 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obRACE --inline \
  > "$SANDBOX/obRACE.a.log" 2>&1 &
RA=$!
AGENT_WATCH_MAX_POLLS=4 AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obRACE --inline \
  > "$SANDBOX/obRACE.b.log" 2>&1 &
RB=$!
wait "$RA"; rca=$?
wait "$RB"; rcb=$?
chk_eq "ob-neg-concurrent-single-publisher: exactly one of the two observers reported 19" 1 \
  "$(( (rca == 19 ? 1 : 0) + (rcb == 19 ? 1 : 0) ))"
chk_eq "ob-neg-concurrent-single-publisher: the loser kept sensing to its own exit (7)" 1 \
  "$(( (rca == 7 ? 1 : 0) + (rcb == 7 ? 1 : 0) ))"
chk_eq "ob-neg-concurrent-single-publisher: one delivered report, one ledger line" 1 \
  "$(grep -c . "$WATCH_RUN_DIR/obRACE.duplex.expect-report")"
chk_eq "ob-neg-concurrent-single-publisher: the verdict was printed exactly once" 1 \
  "$(cat "$SANDBOX/obRACE.a.log" "$SANDBOX/obRACE.b.log" | grep -c 'OVER-BUDGET: this round')"

# ── ob-pos-publish-failure-retries-after-reattach: nothing delivered ⇒ nothing recorded ────
# The publish barrier is identity.py's own test seam: it SIGKILLs the publisher inside the
# os.replace window of the terminal record — the exact "marker written, conclusion lost" case
# the old order could not survive.
ob_seed obPUB 0.02
ob_age obPUB 5
BARRIER="$SANDBOX/obPUB.barrier"
outp="$(AGENTCTL_PUBLISH_BARRIER="$BARRIER" AGENT_WATCH_MAX_POLLS=6 AGENT_WATCH_FOLLOW_MAX=0 \
        bash "$AGENTCTL" watch obPUB 2>&1)"; rcp=$?
chk_eq "ob-pos-publish-failure-retries-after-reattach: the publish window really was hit" 1 \
  "$([ -s "$BARRIER" ] && echo 1 || echo 0)"
chk_eq "ob-pos-publish-failure-retries-after-reattach: no 19 reached the waiter" 0 \
  "$(printf '%s\n' "$outp" | grep -c '^EXIT=19$')"
chk_eq "ob-pos-publish-failure-retries-after-reattach: and NOTHING was recorded as delivered" \
  0 "$([ -s "$WATCH_RUN_DIR/obPUB.duplex.expect-report" ] && echo 1 || echo 0)"
outp2="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obPUB 2>&1)"; rcp2=$?
chk_eq "ob-pos-publish-failure-retries-after-reattach: the re-armed waiter still gets 19" 19 \
  "$rcp2"
chk_eq "ob-pos-publish-failure-retries-after-reattach: recorded once, now that it landed" 1 \
  "$(grep -c . "$WATCH_RUN_DIR/obPUB.duplex.expect-report")"

# ── ob-doc-postpublish-crash-may-duplicate: the state is AT-LEAST-ONCE, by ruling ──────────
# Review R2, accept-documented: a supervisor that dies AFTER `identity publish` returns 0 and
# BEFORE the ledger append leaves a DELIVERED 19 with no ledger line, so the next arm reports
# that same (session, attempt, round) a second time. Waking an orchestrator twice costs one
# read; losing the report cost 2h03m. THIS ASSERTION IS MEANT TO BE FLIPPED, consciously, by
# the reconciliation batch (terminal record carries the report key, consumers reconcile).
# The interleaving is deterministic because the crash's on-disk RESIDUE is: record published,
# key absent from the ledger — constructed here rather than raced for, and the oracle is the
# publish SEQUENCE (two accepted publishes for one key), not merely a second exit code.
ob_seed obDUP 0.02
ob_age obDUP 5
wm() { python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark "$1" 2>/dev/null; }
chk_eq "ob-doc-postpublish-crash-may-duplicate: a fresh attempt has published nothing" 0 \
  "$(wm obDUP)"
outd="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obDUP 2>&1)"; rcd=$?
chk_eq "ob-doc-postpublish-crash-may-duplicate: the first report is delivered" 19 "$rcd"
chk_eq "ob-doc-postpublish-crash-may-duplicate: publish #1 is on the record" 1 "$(wm obDUP)"
chk_eq "ob-doc-postpublish-crash-may-duplicate: and recorded once" 1 \
  "$(grep -c . "$WATCH_RUN_DIR/obDUP.duplex.expect-report")"
# the residue of a crash inside the window: the conclusion is out, the ledger never got it
: > "$WATCH_RUN_DIR/obDUP.duplex.expect-report"
outd2="$(AGENT_WATCH_FOLLOW_MAX=0 bash "$AGENTCTL" watch obDUP 2>&1)"; rcd2=$?
chk_eq "ob-doc-postpublish-crash-may-duplicate: the re-armed waiter reports the SAME round again" \
  19 "$rcd2"
chk_eq "ob-doc-postpublish-crash-may-duplicate: published=2 for one key (at-least-once)" 2 \
  "$(wm obDUP)"
chk_eq "ob-doc-postpublish-crash-may-duplicate: ledger=1 — it never doubles, it only misses" 1 \
  "$(grep -c . "$WATCH_RUN_DIR/obDUP.duplex.expect-report")"
chk_eq "ob-doc-postpublish-crash-may-duplicate: both reports were the same round, not a rotation" \
  1 "$(sed -n 's#.*/\([0-9]*\)$#\1#p' "$WATCH_RUN_DIR/obDUP.duplex.expect-report")"
unset AGENT_WATCH_MAX_POLLS
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== PROG: the tools source does not count this lane's own observation verbs =="
# Field motive (2026-09-02): the review seat's entire 2h03m of "tool activity" was ten
# `agentctl status` / `agentctl watch` invocations on ITSELF — watching work is not doing it,
# so the progress clock stayed alive on self-observation alone. The frames below are the REAL
# ones from that seat's stream (sanitized to the fields under test), because the shape that
# matters is codex's own nesting: `/bin/zsh -lc "bash -lc 'agentctl status <s>'"` — a
# single-level parse sees `/bin/zsh` and counts every self-poll as work.
sw_sandbox
export AGENT_WATCH_STALL_MINS=0          # isolate: the STREAM probe must not answer for this
PGREPO="$SANDBOX/pgrepo"; mkdir -p "$PGREPO"
git -C "$PGREPO" init -q 2>/dev/null
git -C "$PGREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
PGW=0.01                                 # window in MINUTES; 0.01 = 0.6s
FIXTURE="duplex-fixtures/codex-commandexec-observe.jsonl"

pg_seed2() { # $1 session  [$2 engine (default codex)]
  seed "$1"
  printf 'engine=%s\ncwd=%s\nround=1\nthread=t-fixture\n' "${2:-codex}" "$PGREPO" \
    > "$WATCH_RUN_DIR/$1.duplex.meta"
}
pg_status2() { AGENT_WATCH_PROGRESS_MINS=$PGW bash "$AGENTCTL" status "$1" 2>&1; }
# REAL frames, selected by what their command string contains
pg_real() { # $1 session  $2 substring of params.item.command
  python3 - "$WATCH_RUN_DIR/$1.duplex.events.jsonl" "$2" "$FIXTURE" <<'PGPY'
import json, sys
dst, sel, src = sys.argv[1], sys.argv[2], sys.argv[3]
with open(dst, "a", encoding="utf-8") as out:
    for line in open(src, encoding="utf-8"):
        if sel in json.loads(line)["params"]["item"]["command"]:
            out.write(line)
PGPY
}
# a synthetic codex commandExecution pair (single-quoted commands only — this is shell)
pg_cx() { # $1 session  $2 command
  ev "$1" "{\"method\":\"item/started\",\"params\":{\"threadId\":\"t-fixture\",\"item\":{\"type\":\"commandExecution\",\"id\":\"c$RANDOM\",\"command\":\"$2\",\"status\":\"inProgress\"}}}"
}
# claude's own vocabulary: a Bash call with a real command, and its answer frame
pg_bash() { # $1 session  $2 id  $3 command
  ev "$1" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$2\",\"name\":\"Bash\",\"input\":{\"command\":\"$3\"}}]}}"
  ev "$1" "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$2\",\"content\":\"ok\"}]}}"
}

# ── prog-neg-codex-self-observe-frames-silent: the real self-polls, real shape ────────────
pg_seed2 pgSELF
rc="$(pg_status2 pgSELF >/dev/null 2>&1; echo $?)"
chk_eq "prog-neg-codex-self-observe-frames-silent: the first read opens the window (RUNNING)" \
  10 "$rc"
/bin/sleep 1
pg_real pgSELF "agentctl status guard21-codex-gr"
pg_real pgSELF "agentctl watch guard21-codex-gr"
chk_eq "prog-neg-codex-self-observe-frames-silent: the fixture really delivered frames" 1 \
  "$([ "$(grep -c . "$WATCH_RUN_DIR/pgSELF.duplex.events.jsonl")" -ge 8 ] && echo 1 || echo 0)"
out="$(pg_status2 pgSELF)"; rc=$?
chk_eq "prog-neg-codex-self-observe-frames-silent: ten self-polls later the window still fires" \
  14 "$rc"
chk_contains "prog-neg-codex-self-observe-frames-silent: both judged sources read silent" \
  "reason=repo-silent+tools-silent" "$out"

# ── prog-pos-codex-pytest-frames-count: real work still refreshes the clock ───────────────
pg_seed2 pgWORK
rc="$(pg_status2 pgWORK >/dev/null 2>&1; echo $?)"
chk_eq "prog-pos-codex-pytest-frames-count: first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_cx pgWORK 'pytest -q tests/unit -k progress'
out="$(pg_status2 pgWORK)"; rc=$?
chk_eq "prog-pos-codex-pytest-frames-count: a real command frame WITHHOLDS the verdict" 10 "$rc"
chk_contains "prog-pos-codex-pytest-frames-count: and the engine is published as active" \
  "progress_reason=repo-silent+tools-active" "$out"

# ── prog-neg-codex-inventory-silent: the read-only verb set is the whole set ───────────────
pg_seed2 pgINV
rc="$(pg_status2 pgINV >/dev/null 2>&1; echo $?)"
chk_eq "prog-neg-codex-inventory-silent: first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_cx pgINV 'agentctl inventory --dry-run'
pg_cx pgINV 'agentctl states --json'
out="$(pg_status2 pgINV)"; rc=$?
chk_eq "prog-neg-codex-inventory-silent: inventory/states polls are not work either" 14 "$rc"
chk_contains "prog-neg-codex-inventory-silent: as tools-silent, not a broken gauge" \
  "reason=repo-silent+tools-silent" "$out"

# ── prog-pos-codex-wrapper-abs-path-still-filtered: carriers and absolute paths ────────────
pg_seed2 pgWRAP
rc="$(pg_status2 pgWRAP >/dev/null 2>&1; echo $?)"
chk_eq "prog-pos-codex-wrapper-abs-path-still-filtered: first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_cx pgWRAP 'timeout 30 /opt/agentctl/agentctl status pgWRAP'
pg_cx pgWRAP 'AGENT_WATCH_SYNC=1 agentctl watch pgWRAP'
out="$(pg_status2 pgWRAP)"; rc=$?
chk_eq "prog-pos-codex-wrapper-abs-path-still-filtered: same verb through a carrier + abs path" \
  14 "$rc"
chk_contains "prog-pos-codex-wrapper-abs-path-still-filtered: still silent, not active" \
  "reason=repo-silent+tools-silent" "$out"

# ── prog-doc-raw-run-read-counts: reading the run dir by hand IS work (declared boundary) ──
pg_seed2 pgRAW
rc="$(pg_status2 pgRAW >/dev/null 2>&1; echo $?)"
chk_eq "prog-doc-raw-run-read-counts: first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_cx pgRAW 'cat /tmp/agent-watch-run/pgRAW.duplex.events.jsonl'
out="$(pg_status2 pgRAW)"; rc=$?
chk_eq "prog-doc-raw-run-read-counts: a forensic seat reading the raw stream still counts" \
  10 "$rc"
chk_contains "prog-doc-raw-run-read-counts: published as engine activity" \
  "progress_reason=repo-silent+tools-active" "$out"
# the same rule from the other side: an agentctl verb that CHANGES the session counts too
pg_seed2 pgSTEER
rc="$(pg_status2 pgSTEER >/dev/null 2>&1; echo $?)"
chk_eq "prog-doc-raw-run-read-counts: (steer control) first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_cx pgSTEER 'agentctl steer other-seat -f /tmp/ruling.md'
out="$(pg_status2 pgSTEER)"; rc=$?
chk_eq "prog-doc-raw-run-read-counts: dispatching a steer is work, not observation" 10 "$rc"
chk_contains "prog-doc-raw-run-read-counts: (steer) published as engine activity" \
  "progress_reason=repo-silent+tools-active" "$out"

# ── prog-claude-bash-tool-filtered / prog-claude-other-tool-counts ─────────────────────────
# claude's filter reaches EXACTLY what it can prove: a Bash call with readable command text,
# and the tool_result that closes it (a filtered call must not keep the clock alive through
# its own answer frame). Anything else keeps counting.
pg_seed2 pgCLB claude
rc="$(pg_status2 pgCLB >/dev/null 2>&1; echo $?)"
chk_eq "prog-claude-bash-tool-filtered: first read RUNNING" 10 "$rc"
/bin/sleep 1
pg_bash pgCLB t1 'agentctl status pgCLB'
pg_bash pgCLB t2 'agentctl watch pgCLB'
out="$(pg_status2 pgCLB)"; rc=$?
chk_eq "prog-claude-bash-tool-filtered: the Bash self-poll AND its result frame are silent" \
  14 "$rc"
chk_contains "prog-claude-bash-tool-filtered: as tools-silent" \
  "reason=repo-silent+tools-silent" "$out"
pg_seed2 pgCLO claude
rc="$(pg_status2 pgCLO >/dev/null 2>&1; echo $?)"
chk_eq "prog-claude-other-tool-counts: first read RUNNING" 10 "$rc"
/bin/sleep 1
# a NON-Bash tool (no shell body to prove anything about) and a Bash call with no command text
ev pgCLO '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/repo/x.py"}}]}}'
out="$(pg_status2 pgCLO)"; rc=$?
chk_eq "prog-claude-other-tool-counts: a tool this filter cannot judge still counts" 10 "$rc"
chk_contains "prog-claude-other-tool-counts: published as engine activity" \
  "progress_reason=repo-silent+tools-active" "$out"
/bin/sleep 1
ev pgCLO '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r2","name":"Bash","input":{}}]}}'
out="$(pg_status2 pgCLO)"; rc=$?
chk_eq "prog-claude-other-tool-counts: a Bash frame with no readable command counts too" \
  10 "$rc"

# prog-doc-omp-unchanged lives in agentctl-duplex.test.sh: an omp session cannot be
# hand-seeded (classify's omp projector asks the LIVE engine for its turn state), and that
# suite is where the fake omp duplex engine already runs.

# ── PARITY, not single-source: two definitions, ONE mechanical gate ────────────────────────
# Review R1 B2 (accept-documented): `agentctl`'s public surface is still dispatched by its own
# bash `case`, so this asserts the two definitions AGREE in both directions — a verb added to
# either side reds here. Generating the dispatch FROM AGENTCTL_VERBS is the real single source
# and is a separate batch: it rewrites the entry script's whole front door.
pg_verbs="$(python3 - "$AW_DIR" <<'VBPY'
import ast, os, re, sys

d = sys.argv[1]
table = None
for node in ast.parse(open(os.path.join(d, "duplexctl.py"), encoding="utf-8").read()).body:
    names = ([t.id for t in node.targets if isinstance(t, ast.Name)]
             if isinstance(node, ast.Assign)
             else [node.target.id] if isinstance(node, ast.AnnAssign)
             and isinstance(node.target, ast.Name) else [])
    if "AGENTCTL_VERBS" in names and isinstance(node.value, ast.Tuple):
        table = {elt.elts[0].value: elt.elts[1].value for elt in node.value.elts}
sh = open(os.path.join(d, "agentctl"), encoding="utf-8").read()
# the dispatch `case` of the entry script: `  <verb>)  shift; …`
block = sh.split('case "${1:-}" in', 1)[-1]
dispatch = {m.group(1) for m in re.finditer(r"(?m)^  ([a-z][a-z-]*)\)", block)}
dispatch -= {"watch-daemon"}                       # INTERNAL, documented as such
bad = []
if not table:
    bad.append("AGENTCTL_VERBS-not-found")
elif not dispatch:
    bad.append("dispatch-not-found")
else:
    if set(table) - dispatch:
        bad.append("table-only:" + ",".join(sorted(set(table) - dispatch)))
    if dispatch - set(table):
        bad.append("dispatch-only:" + ",".join(sorted(dispatch - set(table))))
print(" ".join(bad) if bad else "AGREES %d observe=%d"
      % (len(table), sum(1 for v in table.values() if v)))
VBPY
)"
chk_eq "prog-neg-codex-inventory-silent: parity: bash dispatch == AGENTCTL_VERBS (two definitions, one gate)" \
  "AGREES 8 observe=5" "$pg_verbs"
unset AGENT_WATCH_STALL_MINS
sw_clean
summary
