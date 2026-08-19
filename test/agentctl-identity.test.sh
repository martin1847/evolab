#!/usr/bin/env bash
# WS1 — attempt identity & stale-attempt fencing (2026-08-04).
#
# Field motive: every runtime artifact of the duplex lane used to be keyed by the session
# NAME alone. A restarted session therefore inherited every stale artifact of its
# predecessor by name collision — a DONE marker or a BLOCKED record from a dead attempt
# could open the current deliverable gate or park the current attempt in WAITING-INPUT.
# Contract now: session_id / attempt_id / process_incarnation, persisted atomically BEFORE
# any frame goes out, and every adoption decision fenced against that active record.
#
# Harness: REAL tmux on an ISOLATED `-L` socket (destructive probes never touch the default
# server) with the scriptable fake omp engine — the real socket is what makes
# pane_pid + pane_lstart, and therefore the process incarnation, genuine rather than mocked.
# `sleep` is restored to the real binary: the watcher TOCTOU probe needs actual poll gaps.
# Every negative case carries a PAIRED GREEN control: over-rejecting the CURRENT attempt is
# a failure here, not acceptable collateral of failing closed.
set -u
cd "$(dirname "$0")"
REAL_TMUX="$(command -v tmux || true)"
. ./lib-testkit.sh

FIX="$(pwd)/duplex-fixtures"
WS1="$FIX/ws1"
DUPLEXCTL="$AW_DIR/duplexctl.py"

if [ -z "$REAL_TMUX" ]; then
  echo "NOT VERIFIED: no tmux binary on PATH — the identity suite needs a real isolated server" >&2
  exit 1
fi

TMUX_SOCK=""
install_socket_tmux() { # every tmux call in agentctl lands on OUR private server
  TMUX_SOCK="ws1id-$$-${RANDOM}"
  cat > "$BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TMUX_SOCK" "\$@"
EOF
  cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep "$@"
EOF
  chmod +x "$BIN/tmux" "$BIN/sleep"
}

kill_socket_tmux() {
  [ -n "$TMUX_SOCK" ] && "$REAL_TMUX" -L "$TMUX_SOCK" kill-server >/dev/null 2>&1
  return 0
}

# PRIVATE engine copies, under names no sibling suite can pattern-match. agentctl-duplex's
# sweep_fakes runs a GLOBAL `pkill -f "duplex-fixtures/fake_omp_duplex"` (and the claude/codex
# equivalents); the duplex pane's argv carries that exact path, so running the two suites
# CONCURRENTLY let the sibling reap this suite's engine and every session here read AGENT-DEAD.
# Confirmed empirically, not inferred: `pgrep -f duplex-fixtures/fake_omp_duplex` matches this
# suite's engine, and simulating the sweep turns a live session into AGENT-DEAD. That is the
# cause of the five N4 failures the R3 review saw under parallel execution. Copying the
# fixtures makes this suite immune instead of merely lucky about scheduling.
install_private_engines() {
  ENGDIR="$SANDBOX/engine"; mkdir -p "$ENGDIR"
  cp "$FIX/fake_omp_duplex.py" "$ENGDIR/ws1-omp.py"
  cp "$FIX/fake_codex_duplex.py" "$ENGDIR/ws1-codex.py"
  chmod +x "$ENGDIR/ws1-omp.py" "$ENGDIR/ws1-codex.py"
}

setup() { # fresh sandbox + private tmux server + private fake engines
  sandbox_new; install_socket_tmux; install_private_engines
  WT="$SANDBOX/wt"; mkdir -p "$WT"
  printf 'ship the identity fence\nPreflight: ls duplex-fixtures/ws1 => 2 forge tools on disk\n' \
    > "$SANDBOX/goal.md"
  export AGENTCTL_BIN_OMP="$ENGDIR/ws1-omp.py"
  export FAKE_OMP_STATE_FILE="$SANDBOX/omp-state"; : > "$FAKE_OMP_STATE_FILE"
  KEEP_SANDBOX=0
}

# Engines whose pane leader was killed directly (the pane-gone probes) get reparented instead
# of reaped — the adopted-worker class agentctl's reap_tree exists for, and which it correctly
# REFUSES to guess at once a probe has stripped pane_pid from meta. Sweep them by this sandbox's
# private engine dir: unique per section, so it can never reach a sibling suite. Until the
# engines moved inside $SANDBOX this suite's ps-residue check could not even see them.
sweep_private_engines() {
  [ -n "${ENGDIR:-}" ] && pkill -f "$ENGDIR" 2>/dev/null
  return 0
}

teardown() {
  kill_socket_tmux; sweep_private_engines; unset FAKE_OMP_STATE_FILE FAKE_PROVIDER_LOG
  # a diagnostic dump asks for the tree to survive: an assertion nobody can explain later is
  # exactly what made the R3 flake UNKNOWN instead of attributable
  if [ "${KEEP_SANDBOX:-0}" = 1 ]; then
    echo "  NOTE sandbox PRESERVED for post-mortem: $SANDBOX"
    export PATH="${OLD_PATH:-$PATH}"; unset AGENT_WATCH_DIR
  else
    sandbox_clean
  fi
}

start_session() { # $1 name  [extra agentctl args...]
  local s="$1"; shift
  bash "$AGENTCTL" start omp "$s" "$WT" --goal "$SANDBOX/goal.md" "$@" >/dev/null 2>&1
}

id_field() { # $1 session  $2 field — "" when absent/null
  python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v)' "$WATCH_RUN_DIR/$1.identity.d/active.json" "$2"
}

newid() { python3 -c 'import uuid; print(uuid.uuid4().hex)'; }

# N4 is the only case whose verdict depends on a live watcher racing a rotation, so a failure
# there must never again be unexplainable: print the OBSERVED verdict and the state it was
# computed from, and keep the sandbox. The R3 review hit five N4 failures whose cause stayed
# UNKNOWN precisely because the assertions printed no watcher output and teardown had already
# removed the tree.
n4_dump() { # $1 which assertion group failed
  echo "    ---- N4 DIAGNOSTIC ($1) ----"
  echo "    watcher exit  : ${w4rc:-<none>}"
  printf '%s\n' "${w4out:-<no watcher output>}" | sed 's/^/    watcher out  | /'
  echo "    active record : $(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity show n4 2>&1 | tr -d '\n')"
  echo "    marker        : $(cat "$WATCH_RUN_DIR/n4.terminal.json" 2>/dev/null || echo '<absent>')"
  echo "    status now    : $(bash "$AGENTCTL" status n4 2>&1 | head -2 | tr '\n' ' ')"
  echo "    rc file       : $(cat "$WATCH_RUN_DIR/n4.duplex.rc" 2>/dev/null || echo '<absent>')"
  echo "    tmux sessions : $("$REAL_TMUX" -L "$TMUX_SOCK" list-sessions 2>&1 | tr '\n' ' ')"
  echo "    sandbox procs : $(ps -Ao command= 2>/dev/null | grep -F "$SANDBOX" | grep -v grep | grep -c .) live"
  echo "    events tail   : $(tail -2 "$WATCH_RUN_DIR/n4.duplex.events.jsonl" 2>/dev/null | tr '\n' ' ')"
  echo "    stderr tail   : $(tail -2 "$WATCH_RUN_DIR/n4.duplex.stderr.log" 2>/dev/null | tr '\n' ' ')"
  KEEP_SANDBOX=1
}

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N1: a DONE marker stamped by attempt A must not open attempt B's gate =="
setup
start_session n1
B_ATTEMPT="$(id_field n1 attemptId)"; B_INC="$(id_field n1 processIncarnation)"
chk_eq "N1 arrange: start persisted an active-identity record" 1 \
  "$([ -s "$WATCH_RUN_DIR/n1.identity.d/active.json" ] && echo 1 || echo 0)"
chk_eq "N1 arrange: attempt id minted" 1 "$([ -n "$B_ATTEMPT" ] && echo 1 || echo 0)"
chk_eq "N1 arrange: incarnation captured from the live pane (pid@start-time)" 1 \
  "$([ "${B_INC%@*}" != "$B_INC" ] && [ -n "${B_INC%@*}" ] && echo 1 || echo 0)"
tmux kill-session -t "=n1" 2>/dev/null
chk_eq "N1 arrange: pane gone and no rc was written" 0 \
  "$([ -e "$WATCH_RUN_DIR/n1.duplex.rc" ] && echo 1 || echo 0)"
base="$(bash "$AGENTCTL" status n1 2>&1)"; base_rc=$?
chk_eq "N1 baseline: pane gone, no marker → AGENT-DEAD 2" 2 "$base_rc"

A_ATTEMPT="$(newid)"
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n1.terminal.json" \
  --attempt "$A_ATTEMPT" --incarnation "$B_INC" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status n1 2>&1)"; rc=$?
chk_eq "N1 DAMAGE ORACLE: B's state is unchanged by A's DONE marker" "$base_rc" "$rc"
chk_contains "N1 verdict stays AGENT-DEAD (gate never opened)" "AGENT-DEAD" "$out"
chk_not_contains "N1 an A-stamped marker never reads as DONE" "DONE" "$out"
chk_contains "N1 typed class surfaced" "STALE-ATTEMPT" "$out"
chk_contains "N1 stale evidence is left on disk, not rewritten" "$A_ATTEMPT" \
  "$(cat "$WATCH_RUN_DIR/n1.terminal.json")"

python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n1.terminal.json" \
  --attempt "$B_ATTEMPT" --incarnation "$B_INC" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status n1 2>&1)"; rc=$?
chk_eq "N1 PAIRED GREEN: a B-stamped DONE marker lands normally → 0" 0 "$rc"
chk_contains "N1 PAIRED GREEN: adoption is explicit, not silent" "adopted the terminal marker" "$out"
bash "$AGENTCTL" stop n1 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N2: a BLOCKED record from a prior attempt must not force WAITING-INPUT =="
setup
start_session n2
CUR_A="$(id_field n2 attemptId)"; CUR_I="$(id_field n2 processIncarnation)"
/bin/sleep 0.05
python3 "$WS1/forge_blocked.py" "$WT/BLOCKED.md" \
  --attempt "$(newid)" --incarnation "$CUR_I" >/dev/null
out="$(bash "$AGENTCTL" status n2 2>&1)"; rc=$?
chk_eq "N2 DAMAGE ORACLE: the current attempt does NOT enter WAITING-INPUT" 1 \
  "$([ "$rc" != 4 ] && echo 1 || echo 0)"
chk_not_contains "N2 no WAITING-INPUT line is emitted" "WAITING-INPUT" "$out"
chk_contains "N2 typed class surfaced" "STALE-ATTEMPT" "$out"
chk_contains "N2 stale record kept for post-mortem, not rewritten" "agentctl-identity" \
  "$(cat "$WT/BLOCKED.md")"

python3 "$WS1/forge_blocked.py" "$WT/BLOCKED.md" \
  --attempt "$CUR_A" --incarnation "$CUR_I" >/dev/null
out="$(bash "$AGENTCTL" status n2 2>&1)"; rc=$?
chk_eq "N2 PAIRED GREEN: a current-attempt BLOCKED record → WAITING-INPUT 4" 4 "$rc"
chk_contains "N2 PAIRED GREEN: verdict names the answer path" "agentctl steer" "$out"
# a legacy, unstamped blocker keeps the pre-identity round-epoch fence (CLI behaviour preserved)
python3 "$WS1/forge_blocked.py" "$WT/BLOCKED.md" --no-stamp >/dev/null
out="$(bash "$AGENTCTL" status n2 2>&1)"; rc=$?
chk_eq "N2 PAIRED GREEN: an unstamped legacy blocker still reaches WAITING-INPUT 4" 4 "$rc"
rm -f "$WT/BLOCKED.md"
bash "$AGENTCTL" stop n2 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N3: same pid, different start-time cannot inherit the previous authority =="
setup
start_session n3
A3="$(id_field n3 attemptId)"; I3="$(id_field n3 processIncarnation)"
PID3="${I3%%@*}"
FORGED_I="$PID3@Thu Jan  1 00:00:00 2026"
chk_eq "N3 arrange: the forged incarnation reuses the EXACT pid" "$PID3" "${FORGED_I%%@*}"
chk_eq "N3 arrange: only the start-time half differs" 1 \
  "$([ "$FORGED_I" != "$I3" ] && echo 1 || echo 0)"
tmux kill-session -t "=n3" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n3.terminal.json" \
  --attempt "$A3" --incarnation "$FORGED_I" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status n3 2>&1)"; rc=$?
chk_eq "N3 DAMAGE ORACLE: the same-pid impostor marker is NOT adopted (still 2)" 2 "$rc"
chk_not_contains "N3 pid reuse never reads as DONE" "DONE" "$out"
chk_contains "N3 typed class surfaced" "STALE-INCARNATION" "$out"

python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n3.terminal.json" \
  --attempt "$A3" --incarnation "$I3" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status n3 2>&1)"; rc=$?
chk_eq "N3 PAIRED GREEN: the exact incarnation is adopted → 0" 0 "$rc"
chk_contains "N3 PAIRED GREEN: adoption names the matched record" "adopted the terminal marker" "$out"
bash "$AGENTCTL" stop n3 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N4: a watcher armed under A cannot publish a terminal conclusion for B =="
setup
start_session n4
printf 'streaming\n' > "$FAKE_OMP_STATE_FILE"   # engine busy: the watcher must keep polling
A4="$(id_field n4 attemptId)"
( AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=40 bash "$AGENTCTL" watch n4 \
    > "$SANDBOX/n4.watch.out" 2>&1; echo $? > "$SANDBOX/n4.watch.rc" ) &
W4=$!
# SYNC POINT 1 — the watcher has armed (its identity snapshot is taken before this line prints)
armed=0
for _ in $(seq 1 100); do
  grep -q "DUPLEX-WATCH ARMED" "$SANDBOX/n4.watch.out" 2>/dev/null && { armed=1; break; }
  /bin/sleep 0.1
done
chk_eq "N4 arrange: the A-watcher armed (identity snapshot taken)" 1 "$armed"
# SYNC POINT 2 — the watcher has COMPLETED at least one classify while the engine is streaming.
# Each classify round-trips a get_state frame, so the events file growing past its armed-time
# size is proof of a finished poll. This replaces a sleep margin with an observable fact.
n4_ev1="$(wc -c < "$WATCH_RUN_DIR/n4.duplex.events.jsonl" 2>/dev/null | tr -d ' ')"
polled=0
for _ in $(seq 1 200); do
  n4_ev2="$(wc -c < "$WATCH_RUN_DIR/n4.duplex.events.jsonl" 2>/dev/null | tr -d ' ')"
  [ "${n4_ev2:-0}" -gt "${n4_ev1:-0}" ] && { polled=1; break; }
  /bin/sleep 0.1
done
chk_eq "N4 arrange: the A-watcher completed a poll under RUNNING" 1 "$polled"
# active identity rotates UNDER the running watcher, then the engine goes idle: the watcher
# will compute a terminal DONE while holding attempt A's snapshot
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace n4 >/dev/null
B4="$(id_field n4 attemptId)"
chk_eq "N4 arrange: active attempt rotated A→B" 1 "$([ "$A4" != "$B4" ] && echo 1 || echo 0)"
: > "$FAKE_OMP_STATE_FILE"
wait "$W4" 2>/dev/null
w4rc="$(cat "$SANDBOX/n4.watch.rc" 2>/dev/null)"
w4out="$(cat "$SANDBOX/n4.watch.out" 2>/dev/null)"
n4_fail0="$FAIL"
chk_eq "N4 DAMAGE ORACLE: the A-watcher published NO terminal marker" 0 \
  "$([ -e "$WATCH_RUN_DIR/n4.terminal.json" ] && echo 1 || echo 0)"
chk_eq "N4 the A-watcher never exits DONE 0" 1 "$([ "$w4rc" != 0 ] && echo 1 || echo 0)"
chk_contains "N4 typed class emitted by the refusing watcher" "STALE-ATTEMPT" "$w4out"
chk_contains "N4 refusal says nothing was published" "no terminal conclusion published" "$w4out"
[ "$FAIL" = "$n4_fail0" ] || n4_dump "stale-watcher assertions"

out="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=40 bash "$AGENTCTL" watch n4 2>&1)"; rc=$?
n4_fail0="$FAIL"
chk_eq "N4 PAIRED GREEN: B's own watcher reaches DONE 0" 0 "$rc"
chk_eq "N4 PAIRED GREEN: B's watcher publishes the marker" 1 \
  "$([ -s "$WATCH_RUN_DIR/n4.terminal.json" ] && echo 1 || echo 0)"
chk_contains "N4 PAIRED GREEN: the marker is stamped with B" "$B4" \
  "$(cat "$WATCH_RUN_DIR/n4.terminal.json")"
if [ "$FAIL" != "$n4_fail0" ]; then
  printf '%s\n' "$out" | sed 's/^/    paired-watch| /'
  n4_dump "paired-green assertions"
fi
bash "$AGENTCTL" stop n4 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N5: the same (attempt_id, seq) event applies exactly once =="
setup
start_session n5
A5="$(id_field n5 attemptId)"; I5="$(id_field n5 processIncarnation)"
chk_eq "N5 arrange: state version starts at 0" 0 "$(id_field n5 stateVersion)"
tmux kill-session -t "=n5" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n5.terminal.json" \
  --attempt "$A5" --incarnation "$I5" --seq 7 >/dev/null
out1="$(bash "$AGENTCTL" status n5 2>&1)"; rc1=$?
sv1="$(id_field n5 stateVersion)"
out2="$(bash "$AGENTCTL" status n5 2>&1)"; rc2=$?
sv2="$(id_field n5 stateVersion)"
chk_eq "N5 first read of the event applies one transition" 1 "$sv1"
chk_eq "N5 DAMAGE ORACLE: re-reading the SAME event does not transition twice" 1 "$sv2"
chk_eq "N5 the verdict itself is idempotent (0 both times)" "$rc1-0" "$rc2-0"
chk_contains "N5 the second read says so out loud" "already applied" "$out2"
chk_contains "N5 the first read did apply" "adopted the terminal marker of the current attempt —" "$out1"

# paired green stated RELATIVE to the observed version: a distinct event must always add
# exactly one transition, whatever the counter already stands at
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/n5.terminal.json" \
  --attempt "$A5" --incarnation "$I5" --seq 8 >/dev/null
out3="$(bash "$AGENTCTL" status n5 2>&1)"; rc3=$?
chk_eq "N5 PAIRED GREEN: a distinct seq is a distinct event → 0" 0 "$rc3"
chk_eq "N5 PAIRED GREEN: distinct seq applies exactly one more transition" \
  "$((sv2 + 1))" "$(id_field n5 stateVersion)"
bash "$AGENTCTL" stop n5 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== N6: identity persists BEFORE the frame, or the verb fails and sends nothing =="
setup
export FAKE_PROVIDER_LOG="$SANDBOX/n6.log"
start_session n6
before="$(grep -c . "$SANDBOX/n6.log" 2>/dev/null || echo 0)"
A6="$(id_field n6 attemptId)"
chk_eq "N6 arrange: the start frame was delivered (log has frames)" 1 \
  "$([ "$before" -gt 0 ] && echo 1 || echo 0)"
chmod 500 "$WATCH_RUN_DIR/n6.identity.d"
out="$(bash "$AGENTCTL" steer n6 -m "start over" --replace 2>&1)"; rc=$?
after="$(grep -c . "$SANDBOX/n6.log" 2>/dev/null || echo 0)"
chk_eq "N6 replace fails typed when the record cannot be made durable" 2 "$rc"
chk_contains "N6 the error names the persist failure" "IDENTITY-PERSIST-FAILED" "$out"
chk_eq "N6 DAMAGE ORACLE: NO frame reached the engine" "$before" "$after"
chk_eq "N6 the prior active record stays authoritative" "$A6" "$(id_field n6 attemptId)"
chmod 700 "$WATCH_RUN_DIR/n6.identity.d"
out="$(bash "$AGENTCTL" steer n6 -m "start over" --replace 2>&1)"; rc=$?
A6B="$(id_field n6 attemptId)"
chk_eq "N6 PAIRED GREEN: a writable state dir accepts the replace" 0 "$rc"
chk_eq "N6 PAIRED GREEN: the record durably holds a NEW attempt" 1 \
  "$([ -n "$A6B" ] && [ "$A6B" != "$A6" ] && echo 1 || echo 0)"
chk_eq "N6 PAIRED GREEN: and only then did the frame go out" 1 \
  "$([ "$(grep -c . "$SANDBOX/n6.log")" -gt "$after" ] && echo 1 || echo 0)"
chk_contains "N6 PAIRED GREEN: the frame is the omp replace frame" '"type":"abort_and_prompt"' \
  "$(cat "$SANDBOX/n6.log")"
chk_eq "N6 PAIRED GREEN: session_id survives the replace (same session, new attempt)" 1 \
  "$([ -n "$(id_field n6 sessionId)" ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop n6 >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
# Review round 1 regressions (cold review R1, 2026-08-04). Each block is derived from the
# reviewer's own reproduction probe.
# ─────────────────────────────────────────────────────────────────────────────────────────

echo "== R1-F2: a MISSING active record is IDENTITY-UNKNOWN, never a legacy DONE =="
# Reviewer's probe: meta + rc=0 + a fresh deliverable + NO identity dir. Pre-fix classify
# rejected only CORRUPT and let ABSENT walk into the rc path, returning DONE 0 with no
# established identity at all — and let status publish an unstamped marker on an empty token.
setup
start_session f2a --deliverable 'done-*.txt'
: > "$WT/done-1.txt"
out="$(bash "$AGENTCTL" status f2a 2>&1)"; rc=$?
chk_eq "F2 PAIRED GREEN: with a record present the gate still reaches DONE 0" 0 "$rc"
chk_eq "F2 PAIRED GREEN: and the marker is published, stamped" 1 \
  "$([ -s "$WATCH_RUN_DIR/f2a.terminal.json" ] && echo 1 || echo 0)"
chk_contains "F2 PAIRED GREEN: the published marker carries an attempt" "attemptId" \
  "$(cat "$WATCH_RUN_DIR/f2a.terminal.json")"
# act: remove the identity record entirely, keeping every legacy signal intact
rm -rf "$WATCH_RUN_DIR/f2a.identity.d" "$WATCH_RUN_DIR/f2a.terminal.json"
chk_eq "F2 arrange: no identity record remains" 0 \
  "$([ -e "$WATCH_RUN_DIR/f2a.identity.d/active.json" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" status f2a 2>&1)"; rc=$?
chk_eq "F2 DAMAGE ORACLE: a missing record never returns DONE 0" 2 "$rc"
chk_contains "F2 status types the missing record" "IDENTITY-UNKNOWN" "$out"
chk_not_contains "F2 no legacy DONE continuation" "DONE" "$out"
chk_eq "F2 DAMAGE ORACLE: and no unstamped marker is published" 0 \
  "$([ -e "$WATCH_RUN_DIR/f2a.terminal.json" ] && echo 1 || echo 0)"
wout="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=3 bash "$AGENTCTL" watch f2a 2>&1)"; wrc=$?
chk_contains "F2 watch types the missing record too" "IDENTITY-UNKNOWN" "$wout"
chk_not_contains "F2 watch never concludes DONE without an identity" "DONE" "$wout"
chk_eq "F2 watch never exits 0" 1 "$([ "$wrc" != 0 ] && echo 1 || echo 0)"
# the engine-exited (rc file) lane must be fenced identically — that is the exact path the
# reviewer walked to a false DONE
printf '0\n' > "$WATCH_RUN_DIR/f2a.duplex.rc"
out="$(bash "$AGENTCTL" status f2a 2>&1)"; rc=$?
chk_eq "F2 DAMAGE ORACLE: rc=0 + fresh deliverable + no record ⇒ still 2" 2 "$rc"
chk_not_contains "F2 the rc lane cannot manufacture DONE either" "DONE" "$out"
# the reviewer's exact oracle: the CLASSIFIER itself, with no publish layered above it
crc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify f2a >/dev/null 2>&1; echo $?)"
chk_eq "F2 DAMAGE ORACLE: the classifier itself refuses (exit 2, was 0)" 2 "$crc"
bash "$AGENTCTL" stop f2a >/dev/null 2>&1
teardown

echo "== R1-F3: marker fields are schema-validated before classification or mutation =="
# Reviewer's probe: an exact current attempt/incarnation marker whose identity object omits
# `seq`. Pre-fix the classifier returned 0 and MUTATED the record (appliedEvents ['aid#None']),
# although event sameness is undecidable without a structured sequence.
setup
start_session f3a
A3F="$(id_field f3a attemptId)"; I3F="$(id_field f3a processIncarnation)"
sv_before="$(id_field f3a stateVersion)"
tmux kill-session -t "=f3a" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/f3a.terminal.json" \
  --attempt "$A3F" --incarnation "$I3F" --no-seq >/dev/null
out="$(bash "$AGENTCTL" status f3a 2>&1)"; rc=$?
chk_eq "F3 DAMAGE ORACLE: a marker with no seq is never adopted (exit 2, was 0)" 2 "$rc"
chk_contains "F3 the missing sequence is typed" "IDENTITY-UNKNOWN" "$out"
chk_not_contains "F3 an undecidable event never reads as DONE" "DONE" "$out"
chk_eq "F3 DAMAGE ORACLE: the active record was not mutated" "$sv_before" "$(id_field f3a stateVersion)"
# rc must be a STRICT int: `False == 0` in Python, so a boolean rc must not pass as success
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/f3a.terminal.json" \
  --attempt "$A3F" --incarnation "$I3F" --seq 1 --rc-raw 'false' >/dev/null
out="$(bash "$AGENTCTL" status f3a 2>&1)"; rc=$?
chk_eq "F3 DAMAGE ORACLE: rc=false is not rc=0 (exit 2)" 2 "$rc"
chk_contains "F3 the mistyped rc is typed" "IDENTITY-UNKNOWN" "$out"
chk_eq "F3 DAMAGE ORACLE: a mistyped marker leaves the record untouched" "$sv_before" \
  "$(id_field f3a stateVersion)"
# and a seq that is not an int at all
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/f3a.terminal.json" \
  --attempt "$A3F" --incarnation "$I3F" --seq-raw '"7"' >/dev/null
out="$(bash "$AGENTCTL" status f3a 2>&1)"; rc=$?
chk_eq "F3 a string seq is undecidable, not adopted" 2 "$rc"
chk_contains "F3 the non-int sequence is typed" "IDENTITY-UNKNOWN" "$out"
# paired green: the same marker with a schema-valid int seq and int rc is still adopted
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/f3a.terminal.json" \
  --attempt "$A3F" --incarnation "$I3F" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status f3a 2>&1)"; rc=$?
chk_eq "F3 PAIRED GREEN: a schema-valid marker is still adopted → 0" 0 "$rc"
chk_contains "F3 PAIRED GREEN: adoption is explicit" "adopted the terminal marker" "$out"
chk_eq "F3 PAIRED GREEN: and it does move the state version" 1 \
  "$([ "$(id_field f3a stateVersion)" -gt "$sv_before" ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop f3a >/dev/null 2>&1
teardown

echo "== R1-F5: a REFUSED codex replace must not rotate the attempt =="
# Reviewer's probe: the fake codex accepts turn/interrupt and then drops the interrupted
# turn's terminal event, so agentctl explicitly refuses to start the replacement. Pre-fix the
# identity had already rotated, making the still-current attempt stale — over-rejecting its
# own later evidence and invalidating an armed watcher for an operation that never happened.
setup
export AGENTCTL_BIN_CODEX="$ENGDIR/ws1-codex.py"
export FAKE_CODEX_GATE="$SANDBOX/never-opens"   # turn 1 stays ACTIVE: replace has work to do
export FAKE_PROVIDER_LOG="$SANDBOX/f5a.log"
export FAKE_CODEX_DROP_INTERRUPT_TERMINAL=1
bash "$AGENTCTL" start codex f5a "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
A5A="$(id_field f5a attemptId)"
TOK5="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f5a)"
starts_before="$(grep -c '"method":"turn/start"' "$SANDBOX/f5a.log" 2>/dev/null || echo 0)"
chk_eq "F5 arrange: the goal turn is running (one turn/start on the wire)" 1 "$starts_before"
out="$(bash "$AGENTCTL" steer f5a -m "start over" --replace 2>&1)"; rc=$?
chk_eq "F5 arrange: the replacement is refused (interrupt never went terminal)" 2 "$rc"
chk_contains "F5 arrange: refusal names the missing terminal state" "did not reach a terminal state" "$out"
chk_eq "F5 DAMAGE ORACLE: the refused replace did NOT rotate the attempt" "$A5A" \
  "$(id_field f5a attemptId)"
chk_eq "F5 DAMAGE ORACLE: no replacement frame was sent either" 1 \
  "$(grep -c '"method":"turn/start"' "$SANDBOX/f5a.log")"
chk_eq "F5 the watcher armed before the refused replace is still valid" "$TOK5" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f5a)"
# --round is REQUIRED by the publisher since R3: pass the round this session is really
# on, so the probe still exercises the identity fence rather than the missing one.
F5RND="$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/f5a.duplex.meta")"
pubrc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish f5a --armed "$TOK5" --round "${F5RND:-0}" >/dev/null 2>&1; echo $?)"
chk_eq "F5 and that armed watcher can still publish its conclusion" 0 "$pubrc"
rm -f "$WATCH_RUN_DIR/f5a.terminal.json"
bash "$AGENTCTL" stop f5a >/dev/null 2>&1
unset FAKE_CODEX_DROP_INTERRUPT_TERMINAL

# commit-point ordering: with the interrupt completing normally but the identity write
# failing, the interrupt must be on the wire and the REPLACEMENT frame must not be
# — i.e. the record is committed after the handshake and before the replacement.
export FAKE_PROVIDER_LOG="$SANDBOX/f5b.log"
bash "$AGENTCTL" start codex f5b "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
A5B="$(id_field f5b attemptId)"; S5B="$(id_field f5b sessionId)"
chmod 500 "$WATCH_RUN_DIR/f5b.identity.d"
out="$(bash "$AGENTCTL" steer f5b -m "start over" --replace 2>&1)"; rc=$?
chmod 700 "$WATCH_RUN_DIR/f5b.identity.d"
chk_eq "F5 ordering: a failed identity write fails the replace typed" 2 "$rc"
chk_contains "F5 ordering: with the typed persist error" "IDENTITY-PERSIST-FAILED" "$out"
chk_eq "F5 ordering: the interrupt handshake DID happen" 1 \
  "$(grep -c '"method":"turn/interrupt"' "$SANDBOX/f5b.log")"
chk_eq "F5 ordering DAMAGE ORACLE: the replacement frame did NOT" 1 \
  "$(grep -c '"method":"turn/start"' "$SANDBOX/f5b.log")"
chk_eq "F5 ordering: and the attempt stayed put" "$A5B" "$(id_field f5b attemptId)"
# paired green: a replace the engine accepts rotates durably AND sends the replacement
bash "$AGENTCTL" steer f5b -m "next turn" >/dev/null 2>&1
out="$(bash "$AGENTCTL" steer f5b -m "start over for real" --replace 2>&1)"; rc=$?
A5B2="$(id_field f5b attemptId)"
chk_eq "F5 PAIRED GREEN: an accepted replace succeeds" 0 "$rc"
chk_eq "F5 PAIRED GREEN: and rotates the attempt" 1 \
  "$([ -n "$A5B2" ] && [ "$A5B2" != "$A5B" ] && echo 1 || echo 0)"
chk_eq "F5 PAIRED GREEN: the replacement frame went out after the rotation" 3 \
  "$(grep -c '"method":"turn/start"' "$SANDBOX/f5b.log")"
chk_eq "F5 PAIRED GREEN: session_id survives the codex replace" "$S5B" "$(id_field f5b sessionId)"
bash "$AGENTCTL" stop f5b >/dev/null 2>&1
unset AGENTCTL_BIN_CODEX FAKE_CODEX_GATE FAKE_PROVIDER_LOG
teardown

echo "== R1-F6: symlinked state paths cannot escape the session-state boundary =="
# Reviewer's two probes. (1) read_terminal_marker used a plain open(), so a symlinked
# <session>.terminal.json pointing at an EXTERNAL json file with the current stamp was adopted
# as DONE 0. (2) clear() enumerated entries THROUGH a symlinked identity dir, so a planted
# link made agentctl's start/stop cleanup delete files outside the run directory.
setup
start_session f6a
A6F="$(id_field f6a attemptId)"; I6F="$(id_field f6a processIncarnation)"
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/ws1-f6-out.XXXXXX")"
python3 "$WS1/forge_marker.py" "$OUTSIDE/external.json" \
  --attempt "$A6F" --incarnation "$I6F" --seq 1 >/dev/null
tmux kill-session -t "=f6a" 2>/dev/null
rm -f "$WATCH_RUN_DIR/f6a.terminal.json"
ln -s "$OUTSIDE/external.json" "$WATCH_RUN_DIR/f6a.terminal.json"
chk_eq "F6 arrange: the marker path is a symlink out of the run dir" 1 \
  "$([ -L "$WATCH_RUN_DIR/f6a.terminal.json" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" status f6a 2>&1)"; rc=$?
chk_eq "F6 DAMAGE ORACLE: a symlinked marker is NOT adopted (exit 2, was 0)" 2 "$rc"
chk_not_contains "F6 external evidence never reads as DONE" "DONE" "$out"
chk_contains "F6 the refusal is typed" "IDENTITY-UNKNOWN" "$out"
chk_eq "F6 DAMAGE ORACLE: and the record was not mutated by it" 0 "$(id_field f6a stateVersion)"
# paired green: the same content as a REGULAR file inside the run dir is still adopted
rm -f "$WATCH_RUN_DIR/f6a.terminal.json"
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/f6a.terminal.json" \
  --attempt "$A6F" --incarnation "$I6F" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status f6a 2>&1)"; rc=$?
chk_eq "F6 PAIRED GREEN: a regular in-run-dir marker is still adopted → 0" 0 "$rc"
chk_contains "F6 PAIRED GREEN: adoption is explicit" "adopted the terminal marker" "$out"
bash "$AGENTCTL" stop f6a >/dev/null 2>&1

# (2) a symlinked identity dir must never be traversed by cleanup
VICTIM="$(mktemp -d "${TMPDIR:-/tmp}/ws1-f6-victim.XXXXXX")"
printf 'do not delete me\n' > "$VICTIM/KEEP"
printf 'engine=omp\ncwd=%s\n' "$WT" > "$WATCH_RUN_DIR/f6b.duplex.meta"
ln -s "$VICTIM" "$WATCH_RUN_DIR/f6b.identity.d"
chk_eq "F6 arrange: the identity dir is a symlink to an external tree" 1 \
  "$([ -L "$WATCH_RUN_DIR/f6b.identity.d" ] && echo 1 || echo 0)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity clear f6b >/dev/null 2>&1
chk_eq "F6 DAMAGE ORACLE: clear() never deletes through the link (sentinel survives)" 1 \
  "$([ -e "$VICTIM/KEEP" ] && echo 1 || echo 0)"
chk_eq "F6 clear() removes the untrusted link entry itself" 0 \
  "$([ -L "$WATCH_RUN_DIR/f6b.identity.d" ] && echo 1 || echo 0)"
# and a transition must refuse to write THROUGH a re-planted link rather than escape
rm -rf "$WATCH_RUN_DIR/f6b.identity.d"; ln -s "$VICTIM" "$WATCH_RUN_DIR/f6b.identity.d"
trc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start f6b >/dev/null 2>&1; echo $?)"
chk_eq "F6 DAMAGE ORACLE: no identity record is written through a symlinked dir" 2 "$trc"
chk_eq "F6 and nothing was created in the external tree" 1 \
  "$([ "$(ls -1 "$VICTIM" | tr -d ' \n')" = "KEEP" ] && echo 1 || echo 0)"
rm -f "$WATCH_RUN_DIR/f6b.identity.d"
# paired green: a real directory takes the record normally
prc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start f6b >/dev/null 2>&1; echo $?)"
chk_eq "F6 PAIRED GREEN: a real identity dir still takes the record" 0 "$prc"
chk_eq "F6 PAIRED GREEN: and the record is there" 1 \
  "$([ -s "$WATCH_RUN_DIR/f6b.identity.d/active.json" ] && echo 1 || echo 0)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity clear f6b >/dev/null 2>&1
rm -rf "$OUTSIDE" "$VICTIM"
teardown


# ─────────────────────────────────────────────────────────────────────────────────────────
# Review round 2 regressions (cold review R2, 2026-08-04) — findings introduced BY the round-1
# fix delta. Same rule: each block is the reviewer's own reproduction.
# ─────────────────────────────────────────────────────────────────────────────────────────

echo "== R2-G2: a corrupt seqWatermark is IDENTITY-UNKNOWN, never reset-and-continue =="
# and both live surfaces must type it: a corrupt watermark is an unestablishable identity
setup
start_session g2s
python3 - "$WATCH_RUN_DIR/g2s.identity.d/active.json" <<'PYEOF'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
rec["seqWatermark"] = "broken"
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rec, sort_keys=True) + "\n")
PYEOF
out="$(bash "$AGENTCTL" status g2s 2>&1)"; rc=$?
chk_eq "G2 status refuses a corrupt watermark (exit 2)" 2 "$rc"
chk_contains "G2 status types it" "IDENTITY-UNKNOWN" "$out"
chk_not_contains "G2 status never concludes DONE from it" "DONE" "$out"
wout="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=3 bash "$AGENTCTL" watch g2s 2>&1)"; wrc=$?
chk_contains "G2 watch types it too" "IDENTITY-UNKNOWN" "$wout"
chk_eq "G2 watch never exits 0" 1 "$([ "$wrc" != 0 ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop g2s >/dev/null 2>&1
teardown

echo "== R2-G3: a negative seq is IDENTITY-UNKNOWN, never a silent duplicate =="
# end to end: a forged marker with a negative seq must be typed on the live surface
setup
start_session g3s
A3G="$(id_field g3s attemptId)"; I3G="$(id_field g3s processIncarnation)"
tmux kill-session -t "=g3s" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/g3s.terminal.json" \
  --attempt "$A3G" --incarnation "$I3G" --seq-raw '-3' >/dev/null
out="$(bash "$AGENTCTL" status g3s 2>&1)"; rc=$?
chk_eq "G3 status refuses a negative-seq marker (exit 2)" 2 "$rc"
chk_contains "G3 status types it" "IDENTITY-UNKNOWN" "$out"
chk_not_contains "G3 a negative seq never reads as DONE" "DONE" "$out"
chk_eq "G3 DAMAGE ORACLE: the record was not mutated" 0 "$(id_field g3s stateVersion)"
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/g3s.terminal.json" \
  --attempt "$A3G" --incarnation "$I3G" --seq 0 >/dev/null
out="$(bash "$AGENTCTL" status g3s 2>&1)"; rc=$?
chk_eq "G3 PAIRED GREEN: seq 0 on the live surface is adopted → 0" 0 "$rc"
chk_eq "G3 PAIRED GREEN: and it moves the state version" 1 "$(id_field g3s stateVersion)"
bash "$AGENTCTL" stop g3s >/dev/null 2>&1
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
# Review round 3 regression (cold review R3) — the lock-acquisition axis.
# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R3-H1: lock ACQUISITION failure refuses the mutation, never falls back lockless =="

# the same refusal must reach the CLI surfaces, not be swallowed by a `|| true`
setup
start_session h1s
chmod 000 "$WATCH_RUN_DIR/h1s.identity.lock"
cout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity clear h1s 2>&1)"; crc=$?
chk_eq "H1 duplexctl identity clear exits typed (2) on an unacquirable lock" 2 "$crc"
chk_contains "H1 and says so" "IDENTITY-PERSIST-FAILED" "$cout"
chk_eq "H1 DAMAGE ORACLE: the record survived the refused CLI clear" 1 \
  "$([ -s "$WATCH_RUN_DIR/h1s.identity.d/active.json" ] && echo 1 || echo 0)"
sout="$(bash "$AGENTCTL" stop h1s 2>&1)"; src=$?
chk_eq "H1 agentctl stop surfaces the refusal instead of claiming success" 1 \
  "$([ "$src" != 0 ] && echo 1 || echo 0)"
chk_contains "H1 stop names the identity that outlived it" "identity state was NOT cleared" "$sout"
chk_contains "H1 stop still tore the session down" "removed duplex control state" "$sout"
chmod 600 "$WATCH_RUN_DIR/h1s.identity.lock"
bash "$AGENTCTL" stop h1s >/dev/null 2>&1
teardown


# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== UNKNOWN probes: ambiguous identity is typed on BOTH surfaces, never OK =="
setup

# P1 — the active record itself is corrupt: nothing can be judged, so nothing is adopted
start_session u1
printf 'this is not json\n' > "$WATCH_RUN_DIR/u1.identity.d/active.json"
out="$(bash "$AGENTCTL" status u1 2>&1)"; rc=$?
chk_contains "P1 status reports IDENTITY-UNKNOWN (corrupt active record)" "IDENTITY-UNKNOWN" "$out"
chk_eq "P1 status never maps a corrupt record to OK" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
wout="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=3 bash "$AGENTCTL" watch u1 2>&1)"; wrc=$?
chk_contains "P1 watch reports IDENTITY-UNKNOWN" "IDENTITY-UNKNOWN" "$wout"
chk_not_contains "P1 watch never concludes DONE from an ambiguous identity" "DONE" "$wout"
chk_eq "P1 watch never exits 0" 1 "$([ "$wrc" != 0 ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop u1 >/dev/null 2>&1

# P2 — the evidence stamp is missing a required field
start_session u2
I2="$(id_field u2 processIncarnation)"
tmux kill-session -t "=u2" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/u2.terminal.json" \
  --incarnation "$I2" --seq 1 >/dev/null       # no --attempt: stamp lacks attemptId
out="$(bash "$AGENTCTL" status u2 2>&1)"; rc=$?
chk_contains "P2 status reports IDENTITY-UNKNOWN (stamp has no attemptId)" "IDENTITY-UNKNOWN" "$out"
chk_not_contains "P2 an unattributable marker never reads as DONE" "DONE" "$out"
chk_eq "P2 status never maps it to OK" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
wout="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=3 bash "$AGENTCTL" watch u2 2>&1)"; wrc=$?
chk_contains "P2 watch reports IDENTITY-UNKNOWN" "IDENTITY-UNKNOWN" "$wout"
chk_not_contains "P2 watch never concludes DONE" "DONE" "$wout"
chk_eq "P2 watch never exits 0" 1 "$([ "$wrc" != 0 ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop u2 >/dev/null 2>&1

# P3 — the start-time signal is unobtainable, so the incarnation cannot be established
start_session u3
grep -v '^pane_' "$WATCH_RUN_DIR/u3.duplex.meta" > "$SANDBOX/u3.meta" \
  && mv "$SANDBOX/u3.meta" "$WATCH_RUN_DIR/u3.duplex.meta"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start u3 >/dev/null
A_U3="$(id_field u3 attemptId)"
chk_eq "P3 arrange: the incarnation is unestablished (no pid/start-time signal)" "" \
  "$(id_field u3 processIncarnation)"
chk_contains "P3 arrange: the record records WHY" "unobtainable" "$(id_field u3 incarnationSignal)"
tmux kill-session -t "=u3" 2>/dev/null
python3 "$WS1/forge_marker.py" "$WATCH_RUN_DIR/u3.terminal.json" \
  --attempt "$A_U3" --incarnation "4242@Thu Jan  1 00:00:00 2026" --seq 1 >/dev/null
out="$(bash "$AGENTCTL" status u3 2>&1)"; rc=$?
chk_contains "P3 status reports IDENTITY-UNKNOWN (start-time unobtainable)" "IDENTITY-UNKNOWN" "$out"
chk_contains "P3 the message names the missing signal" "unobtainable" "$out"
chk_not_contains "P3 a matching attempt alone never reads as DONE" "DONE" "$out"
chk_eq "P3 status never maps it to OK" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
wout="$(AGENT_WATCH_POLL_SECS=1 AGENT_WATCH_MAX_POLLS=3 bash "$AGENTCTL" watch u3 2>&1)"; wrc=$?
chk_contains "P3 watch reports IDENTITY-UNKNOWN" "IDENTITY-UNKNOWN" "$wout"
chk_not_contains "P3 watch never concludes DONE" "DONE" "$wout"
chk_eq "P3 watch never exits 0" 1 "$([ "$wrc" != 0 ] && echo 1 || echo 0)"
bash "$AGENTCTL" stop u3 >/dev/null 2>&1

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== Q1: the record's detail bound is LINE-WISE — a reader never gets half a line =="
# The published detail is machine-read: classify emits a typed verdict line plus advisory
# lines that carry json.dumps payloads, and `detail[:DETAIL_MAX]` used to hand watch readers
# a truncated JSON string (impl review R1 B1). Clipping only the caller's half and then
# appending the writer's receipt display line was equally false — the FIELD is what watch
# replays, and it ran past the bound with the marker no longer last (impl review R2). So the
# oracle here measures the whole stored field: ≤ DETAIL_MAX, every line either a whole source
# line / the writer's receipt line / the marker, and the marker LAST. Publish only touches
# files, so this case needs no engine and no pane.
QWT="$SANDBOX/q1wt"; mkdir -p "$QWT"
q1_seed() { # $1 session
  printf 'engine=omp\ncwd=%s\nround=0\n' "$QWT" > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
}
q1_publish() { # $1 session  $2 detail file — publishes rc=6 with that detail
  local tok
  tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token "$1")"
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish "$1" --armed "$tok" \
    --rc 6 --round 0 --detail "$(cat "$2")" >/dev/null 2>&1
}
cat > "$SANDBOX/q1-check.py" <<'PY'
import json, sys
MARK = "…[detail truncated"
REBUILT = "receipt (rebuilt from record fields): "
src = open(sys.argv[1], encoding="utf-8").read().rstrip("\n").split("\n")
rec = json.load(open(sys.argv[2], encoding="utf-8"))["detail"]
lines = rec.split("\n")
bad, marks, receipt = [], 0, 0
# the STORED field carries no trailing newline and no blank tail line; stripping before the
# scan would make a stray one unobservable (impl review R3 minor 1)
if rec != rec.rstrip("\n"):
    bad.append("trailing-newline-in-stored-field")
for i, ln in enumerate(lines):
    if ln.startswith(MARK):
        marks += 1
        if i != len(lines) - 1:
            bad.append("marker-not-last:%d/%d" % (i, len(lines) - 1))
    elif ln.startswith("terminal record published ("):   # the writer's own receipt line
        receipt += 1
    elif ln.startswith(REBUILT):
        # the rebuild is a READ-side reconstruction; it must never be stored
        bad.append("rebuilt-line-stored:%d" % i)
    elif ln not in src:
        bad.append("not-a-whole-source-line:%s" % ln[-30:])
if len(rec) > int(sys.argv[3]):
    bad.append("over-bound:%d" % len(rec))
print(" ".join(bad) if bad
      else "FIELD_OK lines=%d mark=%d receipt=%d" % (len(lines), marks, receipt))
PY

# 10 whole lines (1 verdict of 33 chars + 9 of 99): the budget is 600 − 65-char marker − 1
# newline = 534, so exactly the verdict + 5 data lines (533 chars) survive; the rest of the
# tail — including the writer's own receipt display line — is dropped WHOLE. The arithmetic is
# spelled out here on purpose: this suite carries its own oracle, and a regression in the
# marker accounting has to red something.
python3 -c 'print("IDLE-NO-DELIVERABLE: verdict line"); [print("L%d:" % i + "x"*96) for i in range(9)]' \
  > "$SANDBOX/q1-long.txt"
q1_seed q1a
q1_publish q1a "$SANDBOX/q1-long.txt"
chk_eq "Q1 a 1000-char multi-line detail publishes whole lines + a trailing marker, in bound" \
  "FIELD_OK lines=7 mark=1 receipt=0" \
  "$(python3 "$SANDBOX/q1-check.py" "$SANDBOX/q1-long.txt" "$WATCH_RUN_DIR/q1a.terminal.json" 600)"
# …and because that drop took the receipt display line with it, the READ side rebuilds one
# from structural fields — otherwise a replaying waiter is the only surface with no receipt
# at all (impl review R3). Read-side only: the stored field above must not contain it.
cat > "$SANDBOX/q1-replay.py" <<'PY'
# argv: record.json  replay.txt  rebuilt|none — the verdict of ONE replay against the record
# it replays. Exactly one trailing newline is the transport's (the reader's own print); more is
# a stray blank line and must stay observable, so nothing here rstrips (impl review R3 minor 1).
import json, sys
REBUILT = "receipt (rebuilt from record fields): "
rec = json.load(open(sys.argv[1], encoding="utf-8"))
raw = open(sys.argv[2], encoding="utf-8").read()
text = raw[:-1] if raw.endswith("\n") else raw
if text.endswith("\n"):
    print("extra-trailing-blank-line")
    sys.exit()
lines = text.split("\n")
built = [ln for ln in lines if ln.startswith(REBUILT)]
if sys.argv[3] == "none":
    print("rebuilt=%d same_detail=%s"
          % (len(built), "yes" if text == rec["detail"] else "no"))
    sys.exit()
bits = built[0].split() if built else []
want_phase = "phase=%s" % (rec.get("phase") or "-")
if len(built) != 1:
    print("rebuilt-lines=%d" % len(built))
elif built[0] != lines[-1]:
    print("rebuilt-not-last")
elif "reason=%s" % rec.get("reason") not in bits:
    print("reason-not-the-record-field:want reason=%s" % rec.get("reason"))
elif want_phase not in bits:
    print("phase-not-the-record-field:want %s" % want_phase)
elif text != rec["detail"] + "\n" + built[0]:
    # the replay is the STORED field plus that one line — nothing else rewritten
    print("replay-is-not-stored-detail-plus-one-line")
else:
    print("ok")
PY
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state q1a --arm \
  > "$SANDBOX/q1a-replay.txt" 2>&1
chk_eq "Q1 the pressured record replays as the stored field plus a rebuilt receipt line" ok \
  "$(python3 "$SANDBOX/q1-replay.py" "$WATCH_RUN_DIR/q1a.terminal.json" \
     "$SANDBOX/q1a-replay.txt" rebuilt)"
# …and that line's prefix must collide with NO typed class word: a diagnostic summary that
# starts like a verdict is a verdict to every reader that scans line starts. Asserted against
# the vocabulary itself, never a hand-copied list.
chk_eq "Q1 the rebuilt line starts with no typed class word" ok \
  "$(python3 -c 'import sys
sys.path.insert(0, sys.argv[1])
import identity
words = (list(identity.TERMINAL_CLASSES.values())
         + [identity.OK, identity.UNKNOWN, identity.STALE_ATTEMPT,
            identity.STALE_INCARNATION, identity.STALE_ROUND])
hit = [w for w in words if identity.RECEIPT_REBUILT_PREFIX.startswith(w)]
print("ok" if not hit else "collides:%s" % ",".join(hit))' "$AW_DIR")"

# paired control: a detail that fits is stored verbatim — no marker invented
printf 'IDLE-NO-DELIVERABLE: verdict line\nadvisory line\n' > "$SANDBOX/q1-short.txt"
q1_seed q1b
q1_publish q1b "$SANDBOX/q1-short.txt"
chk_eq "Q1 PAIRED GREEN: a detail under the bound keeps every line, marker-free, receipt kept" \
  "FIELD_OK lines=3 mark=0 receipt=1" \
  "$(python3 "$SANDBOX/q1-check.py" "$SANDBOX/q1-short.txt" "$WATCH_RUN_DIR/q1b.terminal.json" 600)"

# the one line that may still be cut: a FIRST line that alone overruns the budget. That line
# is the typed verdict prose (advisory lines always follow it), so no payload can be split.
python3 -c 'print("IDLE-NO-DELIVERABLE: " + "y"*900)' > "$SANDBOX/q1-huge.txt"
q1_seed q1c
q1_publish q1c "$SANDBOX/q1-huge.txt"
q1c_detail="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["detail"].split("\n")[0])' \
  "$WATCH_RUN_DIR/q1c.terminal.json")"
case "$q1c_detail" in "IDLE-NO-DELIVERABLE: yyy"*) q1c_pre=yes ;; *) q1c_pre=no ;; esac
chk_eq "Q1 an over-long FIRST line is cut to the budget (only prose can be)" \
  "prefix=yes len=534" "prefix=$q1c_pre len=${#q1c_detail}"
chk_contains "Q1 and that cut is announced" "…[detail truncated" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["detail"])' \
     "$WATCH_RUN_DIR/q1c.terminal.json")"

# BACKWARD COMPATIBILITY: a record written before `receiptLineDropped` existed carries no such
# field. It must still replay, and it must replay the OLD way (no rebuild) — the flag is read
# with `is True`, so absent is not "maybe". Simulated by stripping the field off q1a's record,
# which is exactly the shape an older agentctl left on disk.
python3 -c 'import json, sys
p = sys.argv[1]
rec = json.load(open(p, encoding="utf-8"))
rec.pop("receiptLineDropped", None)
json.dump(rec, open(p, "w", encoding="utf-8"))' "$WATCH_RUN_DIR/q1a.terminal.json"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state q1a --arm \
  > "$SANDBOX/q1a-legacy.txt" 2>&1; q1a_lrc=$?
chk_eq "Q1 a legacy record (no flag) still replays, and replays without a rebuilt line" \
  "rc=6 rebuilt=0 same_detail=yes" \
  "rc=$q1a_lrc $(python3 "$SANDBOX/q1-replay.py" "$WATCH_RUN_DIR/q1a.terminal.json" \
     "$SANDBOX/q1a-legacy.txt" none)"

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== complexity budget: no new long-running process, no out-of-scope file touched =="
SB="$SANDBOX"; SOCK="$TMUX_SOCK"
kill_socket_tmux; sweep_private_engines
/bin/sleep 0.5
resid="$(ps -Ao command= 2>/dev/null | grep -F -e "$SB" -e "$SOCK" | grep -v grep | grep -c . )"
chk_eq "ps: nothing from this suite outlives it (no daemon, no leaked engine)" 0 "$resid"
teardown

# NOTE: a branch-scope guardrail used to live here (diff main...HEAD vs an allowlist). It was
# a worktree-lifetime check for the reliability-core branches, and it read repository state from
# OUTSIDE this suite's sandbox — so once the workstreams merged it began firing on legitimate,
# already-reviewed doctrine commits (Linux CI, 2026-08-05) while staying green on the author's
# machine. A hermetic suite must not assert on the surrounding checkout; scope discipline is the
# reviewer's and the pre-push gate's job, not a runtime test's. Removed rather than patched.

summary
