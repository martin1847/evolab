#!/usr/bin/env bash
# agentctl stop process-tree reap — the 2026-07-28 leak class: tmux kill-session only
# signals the pane leader, so engine children/grandchildren adopted by PID 1 survive.
# Pins: group TERM→bounded grace→KILL with zero-residue verify; adopted-grandchild
# coverage; leader-lstart fingerprint against pid recycling (mismatch = refuse, dead
# leader = POSIX pgid persistence, no check needed); live-pane read preferred over
# stale meta; idempotent re-stop; old metas without pane_pid stay a clean no-op.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== agentctl-reap =="

sandbox_new
# reap_tree's grace loop needs REAL time (the sandbox no-op sleep would burn the whole
# grace budget in microseconds and mislabel every TERM reap as KILL).
printf '#!/usr/bin/env bash\nexec /bin/sleep "$@"\n' > "$BIN/sleep"; chmod +x "$BIN/sleep"

# Disposable setsid tree: fork → setsid leader (pid == pgid) spawns members, prints pid.
#   plain      : sleep child + intermediate bash whose grandchild outlives it (adoption);
#                leader exits early → every survivor is PID-1-adopted, pgid persists.
#   ignore-term: one member ignores SIGTERM (forces the KILL escalation).
#   keep-leader: leader stays alive (fingerprint tests read its real lstart).
spawn_tree() { # $1 mode → echoes leader pid
  python3 - "$1" <<'EOF'
import os, subprocess, sys, time
mode = sys.argv[1]
pid = os.fork()
if pid == 0:
    os.setsid()
    # detach ALL stdio: members inherit the test's command-substitution pipe, and a
    # 120s member would hold it open — $(spawn_tree ...) waits for pipe close, not exit
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    if mode == "ignore-term":
        subprocess.Popen([sys.executable, "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(120)"])
    else:
        subprocess.Popen(["/bin/sleep", "120"])
        subprocess.Popen(["/bin/bash", "-c", "/bin/sleep 121 & disown"])
    if mode == "keep-leader":
        time.sleep(120)
    time.sleep(0.3)
    os._exit(0)
print(pid)
EOF
}

mkmeta() { # $1 session  $2 pane_pid("" = omit)  $3 pane_lstart("" = omit)
  { printf 'engine=omp\ncwd=/tmp\n'
    [ -n "$2" ] && printf 'pane_pid=%s\n' "$2"
    [ -n "$3" ] && printf 'pane_lstart=%s\n' "$3"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
}

# --- 1. meta-fallback reap: dead leader, adopted members (incl. grandchild) ---------
pg="$(spawn_tree plain)"; /bin/sleep 0.6   # leader dead → members adopted by PID 1
n="$(pgrep -g "$pg" 2>/dev/null | wc -l | tr -d ' ')"
chk_eq "plain: ≥2 adopted members in group pre-stop" 1 "$([ "$n" -ge 2 ] && echo 1 || echo 0)"
mkmeta s1 "$pg" "Thu Jan  1 00:00:00 1970"   # wrong lstart MUST be ignored: leader is dead
export FAKE_TMUX_DISPLAY_FAIL=1              # no live pane → stop must use the meta
out="$(bash "$AGENTCTL" stop s1 2>&1)"; rc=$?
chk_eq  "stop s1 rc=0" 0 "$rc"
chk_contains "stop s1 reaped the group" "reaped process group $pg" "$out"
chk_eq  "group empty after stop s1" "" "$(pgrep -g "$pg" 2>/dev/null)"
chk_eq  "meta removed" "0" "$([ -e "$WATCH_RUN_DIR/s1.duplex.meta" ] && echo 1 || echo 0)"

# --- 2. idempotent re-stop: only post-mortem artifacts remain -----------------------
: > "$WATCH_RUN_DIR/s1.duplex.events.jsonl"
out="$(bash "$AGENTCTL" stop s1 2>&1)"; rc=$?
chk_eq "re-stop rc=0" 0 "$rc"
chk_contains "re-stop says already stopped" "already stopped" "$out"

# --- 3. TERM ignored → bounded escalation to KILL -----------------------------------
pg="$(spawn_tree ignore-term)"; /bin/sleep 0.6
mkmeta s3 "$pg" ""
out="$(AGENTCTL_REAP_GRACE=1 bash "$AGENTCTL" stop s3 2>&1)"; rc=$?
chk_eq  "KILL-escalation rc=0" 0 "$rc"
chk_contains "escalated to KILL" "reaped process group $pg (KILL)" "$out"
chk_eq  "group empty after KILL" "" "$(pgrep -g "$pg" 2>/dev/null)"

# --- 4. live leader + WRONG fingerprint → refuse (pid-recycling guard) --------------
pg="$(spawn_tree keep-leader)"; /bin/sleep 0.3
mkmeta s4 "$pg" "Thu Jan  1 00:00:00 1970"
out="$(bash "$AGENTCTL" stop s4 2>&1)"; rc=$?
chk_eq  "mismatch stop rc=0 (not ours = nothing of ours leaked)" 0 "$rc"
chk_contains "mismatch refused the reap" "not reaping" "$out"
chk_eq  "stranger group SURVIVED" 1 "$([ -n "$(pgrep -g "$pg" 2>/dev/null)" ] && echo 1 || echo 0)"
chk_eq  "control state still cleaned" "0" "$([ -e "$WATCH_RUN_DIR/s4.duplex.meta" ] && echo 1 || echo 0)"
kill -KILL -- "-$pg" 2>/dev/null

# --- 5. live leader + matching fingerprint → reap -----------------------------------
pg="$(spawn_tree keep-leader)"; /bin/sleep 0.3
mkmeta s5 "$pg" "$(ps -p "$pg" -o lstart= | sed 's/ *$//')"
out="$(bash "$AGENTCTL" stop s5 2>&1)"; rc=$?
chk_eq  "fingerprint-match rc=0" 0 "$rc"
chk_contains "fingerprint-match reaped" "reaped process group $pg" "$out"
chk_eq  "group empty after fingerprint reap" "" "$(pgrep -g "$pg" 2>/dev/null)"

# --- 6. live pane read wins: meta has NO pane_pid, tmux hands out "0 <pgid>" --------
unset FAKE_TMUX_DISPLAY_FAIL
pg="$(spawn_tree plain)"; /bin/sleep 0.6
mkmeta s6 "" ""
out="$(FAKE_PANE_CMD="0 $pg" bash "$AGENTCTL" stop s6 2>&1)"; rc=$?
chk_eq  "live-path rc=0" 0 "$rc"
chk_contains "live-path reaped without meta pane_pid" "reaped process group $pg" "$out"
chk_eq  "group empty after live-path reap" "" "$(pgrep -g "$pg" 2>/dev/null)"
order=0; case "$out" in *"removed duplex control state"*"reaped process group"*) order=1;; esac
chk_eq  "cleanup precedes reap (marker-guard window stays µs)" 1 "$order"

# --- 6b. DEAD pane (remain-on-exit residue): live read reports "1 <pid>" → must be
# distrusted, meta fingerprint path reaps the REAL group (review S1) ------------------
pg="$(spawn_tree plain)"; /bin/sleep 0.6
mkmeta s6b "$pg" "Thu Jan  1 00:00:00 1970"   # dead leader → fingerprint skipped, meta wins
out="$(FAKE_PANE_CMD="1 9999999" bash "$AGENTCTL" stop s6b 2>&1)"; rc=$?
chk_eq  "dead-pane stop rc=0" 0 "$rc"
chk_contains "dead-pane fell back to meta group" "reaped process group $pg" "$out"
chk_not_contains "dead-pane pid was NOT trusted" "9999999" "$out"
chk_eq  "group empty after dead-pane fallback" "" "$(pgrep -g "$pg" 2>/dev/null)"

# --- 6c. survivors after KILL → WARN + stop rc 1 (duplex AND bare paths agree) ------
# pgrep stub keeps reporting a member even after KILL; the signalled group is one WE
# spawned — a hardcoded pgid is somebody else's within minutes (pid wrap, review S5:
# a fork loop landed on the "surely free" pid and this suite killed it).
pg="$(spawn_tree ignore-term)"; /bin/sleep 0.6
printf '#!/usr/bin/env bash\necho %s\n' "$pg" > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
mkmeta s6c "$pg" ""
export FAKE_TMUX_DISPLAY_FAIL=1
out="$(AGENTCTL_REAP_GRACE=1 bash "$AGENTCTL" stop s6c 2>&1)"; rc=$?
chk_eq  "survivors: duplex stop rc=1" 1 "$rc"
chk_contains "survivors: WARN names the group" "survivors in process group $pg" "$out"
unset FAKE_TMUX_DISPLAY_FAIL
out="$(FAKE_TMUX_HASSESSION=0 FAKE_PANE_CMD="0 $pg" AGENTCTL_REAP_GRACE=1 bash "$AGENTCTL" stop s6d 2>&1)"; rc=$?
chk_eq  "survivors: bare-tmux stop rc=1 (no silent drop)" 1 "$rc"
chk_contains "survivors: bare path cleaned residue too" "killed bare tmux session s6d" "$out"
rm -f "$BIN/pgrep"
kill -KILL -- "-$pg" 2>/dev/null

# --- 7. old meta (no pane_pid) + no live pane = clean no-op, not an error -----------
export FAKE_TMUX_DISPLAY_FAIL=1
mkmeta s7 "" ""
out="$(bash "$AGENTCTL" stop s7 2>&1)"; rc=$?
chk_eq  "legacy-meta stop rc=0" 0 "$rc"
chk_not_contains "legacy-meta stop reaps nothing" "reaped process group" "$out"
unset FAKE_TMUX_DISPLAY_FAIL

# --- 8. wiring pins: every session-ending path feeds reap_tree ----------------------
src="$(cat "$AGENTCTL")"
chk_contains "start records pane_pid+lstart into meta" 'pane_pid=%s\npane_lstart=%s' "$src"
chk_contains "handshake-fail path reaps" 'reap_tree "$PANE_PID"' "$src"
chk_contains "bare-tmux stop path reaps" 'reap_tree "$live_pg"' "$src"
chk_contains "stale-meta stop path carries the fingerprint" 'meta_get "$S" pane_lstart' "$src"
# exact-match targeting: a bare -t name falls through to PREFIX match on miss (tmux 3.6b
# probed: has-session -t rev-rea hit rev-reap; display-message -t "revre:" hit revreap
# too — the colon form prefix-matches the same way, review S2) — a stop of a dead "rev"
# must never kill a live "rev2" neighbor, and pane_pid must never be read from one.
chk_eq "no prefix-matching tmux -t \$S target survives (bare OR colon form)" "" \
  "$(grep -nE 'tmux (has-session|kill-session|display-message|set-option)[^|]*-t "\$S:?"' "$AGENTCTL")"
# the python side of the lane is TWO files since the watch/supervisor split (duplexctl.py keeps
# the engine + front door, watchctl.py the patrol verbs): both scan faces are the union, so a
# rule cannot be satisfied by the file that happens to be looked at.
PY_SRC="$(cat "$AW_DIR/duplexctl.py" "$AW_DIR/watchctl.py")"
chk_contains "duplexctl tmux_alive probes exact name" 'f"={name}"' "$PY_SRC"
chk_eq "the python lane has no bare -t name target" "" \
  "$(grep -n '"-t", name' "$AW_DIR/duplexctl.py" "$AW_DIR/watchctl.py")"
chk_contains "start pins remain-on-exit off (dead-pane pid trap, S1)" 'remain-on-exit off' "$src"

# ═══ process hygiene: escaped-descendant advisory · inventory · reap negative controls ═══
# [BTn] tags the goal-review blocking test each scenario discharges (reap 1/10/11, stop 3/6,
# inventory 2/4/5/7/8/9). Every live fixture is self-expiring AND torn down by RECORDED pid
# after an identity re-check — nothing here is ever killed from something a scan produced.
NONCE="hyg$$"

kill_recorded() { # $1 pid  $2 the argv it must STILL have — anything else is left alone
  [ -n "${1:-}" ] || return 0
  [ "$(ps -o args= -p "$1" 2>/dev/null)" = "$2" ] || return 0
  kill -KILL "$1" 2>/dev/null
}

# A live pane-like group: leader (pid == pgid) + one IN-group member the reap owns + one child
# that setsid()s OUT of the group — the escape a group-scoped reap cannot see by construction.
spawn_escape_tree() { # $1 escapee argv[0]  $2 file the escapee writes its own pid to → leader
  python3 - "$1" "$2" <<'EOF'
import os, subprocess, sys, time
marker, pidfile = sys.argv[1], sys.argv[2]
pid = os.fork()
if pid == 0:
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    subprocess.Popen(["/bin/sleep", "120"])          # IN the group: the reap owns this one
    if os.fork() == 0:
        os.setsid()                                  # OUT of the group: invisible to the reap
        with open(pidfile, "w") as fh:
            fh.write(str(os.getpid()))
        os.execv("/bin/sleep", [marker, "90"])       # uniquely named, self-expiring
    time.sleep(120)
print(pid)
EOF
}

spawn_orphan() { # → pid of a GENUINE PPID=1 process whose argv[0] IS a production matcher
  python3 - <<'EOF'
import os, sys
r, w = os.pipe()
if os.fork() == 0:
    os.close(r)
    if os.fork() == 0:                               # double fork: PID 1 really adopts it
        os.setsid()
        os.write(w, str(os.getpid()).encode())
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        os.execv("/bin/sleep", ["omp", "97"])        # self-expiring; torn down by RECORDED pid
    os._exit(0)
os.close(w)
os.wait()
sys.stdout.write(os.read(r, 32).decode().strip())
EOF
}

# --- 9. [BT3] stop advisory: an escaped descendant is REPORTED, and only reported ----------
esc_pidf="$SANDBOX/escapee.pid"; esc_argv="esc-$NONCE 90"
pg="$(spawn_escape_tree "esc-$NONCE" "$esc_pidf")"; /bin/sleep 0.8
esc="$(cat "$esc_pidf" 2>/dev/null)"
chk_eq "BT3 pre-probe: the escapee is alive with the expected argv" "$esc_argv" \
       "$(ps -o args= -p "${esc:-0}" 2>/dev/null)"
chk_eq "BT3 pre-probe: the escapee really left the pane's process group" 1 \
  "$([ -n "$esc" ] && [ "$(ps -o pgid= -p "$esc" 2>/dev/null | tr -d ' ')" != "$pg" ] && echo 1 || echo 0)"
mkmeta s9 "$pg" ""
bt3="$SANDBOX/bt3.out"
FAKE_TMUX_DISPLAY_FAIL=1 bash "$AGENTCTL" stop s9 > "$bt3" 2>&1; rc=$?
out="$(cat "$bt3")"
chk_eq  "BT3 stop rc is untouched by the advisory" 0 "$rc"
chk_contains "BT3 the group stop OWNS was still reaped" "reaped process group $pg" "$out"
chk_eq  "BT3 the in-group member is gone" "" "$(pgrep -g "$pg" 2>/dev/null)"
chk_contains "BT3 the advisory counts exactly one escapee" "1 descendant(s) escaped" "$out"
chk_eq  "BT3 exactly one advisory line, naming the escapee once" 1 \
        "$(grep -c "^ADVISORY: .*pid=$esc " "$bt3")"
chk_eq  "BT3 the escapee SURVIVED: the advisory adds no signal" "$esc_argv" \
        "$(ps -o args= -p "${esc:-0}" 2>/dev/null)"
kill_recorded "$esc" "$esc_argv"

# --- 10. [BT6] a broken probe says [unknown]; it never reads as clean, and stop is unmoved --
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
# fail ONLY the survivor probe's snapshot form; reap_tree's own `ps -o …` stays real
[ "$1" = "-axo" ] && exit 1
exec /bin/ps "$@"
EOF
chmod +x "$BIN/ps"
pg="$(spawn_tree keep-leader)"; /bin/sleep 0.3
mkmeta s10 "$pg" ""
out="$(FAKE_TMUX_DISPLAY_FAIL=1 bash "$AGENTCTL" stop s10 2>&1)"; rc=$?
rm -f "$BIN/ps"
chk_eq  "BT6 a broken probe leaves stop's rc alone" 0 "$rc"
chk_contains "BT6 the broken probe announces itself" "escaped-descendant probe [unknown]" "$out"
chk_contains "BT6 the reap itself still ran" "reaped process group $pg" "$out"
order=0; case "$out" in *"removed duplex control state"*"reaped process group"*) order=1;; esac
chk_eq  "BT6 cleanup→reap ordering survives a broken probe" 1 "$order"
chk_eq  "BT6 both stop branches bracket the reap with the SAME probe" "2 2" \
  "$(grep -c 'survivor_probe "\$S"' "$AGENTCTL") $(grep -c 'survivor_advise "\$S"' "$AGENTCTL")"
chk_eq  "BT6 group empty after the stop" "" "$(pgrep -g "$pg" 2>/dev/null)"
# …and the other way the probe can break: the snapshot never lands at all (the probe verb
# could not run, or could not write). Silence there would be indistinguishable from clean.
pg="$(spawn_tree keep-leader)"; /bin/sleep 0.3
mkmeta s10b "$pg" ""
mkdir -p "$WATCH_RUN_DIR/.s10b.stop-probe.json"      # the snapshot path is unwritable
out="$(FAKE_TMUX_DISPLAY_FAIL=1 bash "$AGENTCTL" stop s10b 2>&1)"; rc=$?
chk_eq  "BT6 an unrecordable snapshot still leaves stop's rc alone" 0 "$rc"
chk_contains "BT6 a snapshot that never landed reads [unknown], not clean" \
             "escaped-descendant probe [unknown]" "$out"
chk_eq  "BT6 group empty after the unrecordable-snapshot stop" "" "$(pgrep -g "$pg" 2>/dev/null)"

# --- 11. [BT1] the self-pgid guard, probed where a regression can only hurt itself ----------
# reap_tree's own group is the one thing it must never signal, and probing that means CALLING
# it with its own pgid. So everything here runs inside a THROWAWAY setsid group while a witness
# sits in the runner's group: a regression that really signals blows up the throwaway (marker
# never lands) and witness + runner survive to report it, instead of the suite killing itself.
#
# Two halves, because the end-to-end half alone is NOT a guard test: on macOS `pgrep -g <own
# pgid>` skips the caller AND its ancestors, so a group made of nothing but our own ancestry
# reads as empty and reap_tree would refuse one line LATER even with the guard deleted (probed:
# deleting it left this scenario green). The second half forces `pgrep` to report the group
# populated, so the guard is the ONLY thing left that can refuse — and routes the signal through
# a recording double, so even a regressed guard puts nothing on the wire.
reap_src="$SANDBOX/reap_tree.sh"
awk '/^reap_tree\(\) \{/,/^\}/' "$AGENTCTL" > "$reap_src"
chk_contains "BT1/BT10/BT11 the extracted function is the SHIPPED reap_tree" \
             'lower bounds are load-bearing' "$(cat "$reap_src")"
( exec -a "wit-$NONCE" /bin/sleep 45 ) & wit=$!; disown "$wit" 2>/dev/null || true
bt1="$SANDBOX/bt1.out"
python3 - "$WATCH_RUN_DIR" "$AGENTCTL" "$bt1" "$reap_src" "$SANDBOX/bt1.kill.log" <<'EOF'
import os, subprocess, sys
run, ctl, marker, reap_src, killlog = sys.argv[1:6]
pid = os.fork()
if pid == 0:
    os.setsid()                                      # the disposable group under test
    snippet = ('pg=$(ps -o pgid= -p $$ | tr -d " ");'
               'printf "engine=omp\\ncwd=/tmp\\npane_pid=%s\\n" "$pg" > "$1/s11.duplex.meta";'
               'FAKE_TMUX_DISPLAY_FAIL=1 bash "$2" stop s11 2>&1; echo "rc=$?";'
               '. "$3"; export AGENTCTL_REAP_GRACE=0; KLOG="$4";'
               # KLOG, not "$4": inside a function the positionals are the FUNCTION's args
               'kill() { printf "x\\n" >> "$KLOG"; return 0; }; pgrep() { return 0; };'
               ': > "$KLOG"; kill -0 wiring; echo "wired=$(wc -l < "$KLOG" | tr -d " ")";'
               ': > "$KLOG"; reap_tree 987654 "" >/dev/null 2>&1;'
               'echo "stranger_signals=$(wc -l < "$KLOG" | tr -d " ")";'
               ': > "$KLOG"; reap_tree "$pg" "" >/dev/null 2>&1;'
               'echo "selfpgid_signals=$(wc -l < "$KLOG" | tr -d " ")"')
    done = subprocess.run(["bash", "-c", snippet, "_", run, ctl, reap_src, killlog],
                          capture_output=True, text=True)
    with open(marker, "w") as fh:
        fh.write(done.stdout + done.stderr)
    os._exit(0)
os.waitpid(pid, 0)
EOF
out="$(cat "$bt1" 2>/dev/null)"
chk_eq  "BT1 the disposable group survived (a real regression leaves NO marker)" 1 \
        "$([ -s "$bt1" ] && echo 1 || echo 0)"
chk_contains "BT1 stop still exits 0" "rc=0" "$out"
chk_not_contains "BT1 end-to-end: stop reaped no group of its own" "reaped process group" "$out"
chk_contains "BT1 known positive: the kill double is in the lookup path" "wired=1" "$out"
chk_contains "BT1 known positive: a STRANGER pgid does reach the double here" \
             "stranger_signals=2" "$out"
chk_contains "BT1 the GUARD refuses our own pgid: zero signals, populated group" \
             "selfpgid_signals=0" "$out"
chk_eq  "BT1 the witness in the runner's group is untouched" "wit-$NONCE 45" \
        "$(ps -o args= -p "$wit" 2>/dev/null)"
kill_recorded "$wit" "wit-$NONCE 45"

# --- 12. [BT10/BT11] lower bounds 0 and 1 go through an INTERCEPTING kill double ------------
# `pgrep -g 0` is our own group on Linux, so the guard at pg<=1 is load-bearing — and probing
# it must never put a real signal on the wire. The double records instead of signalling. Zero
# is only evidence with BOTH known positives beside it: the double is really in the lookup
# path, and a pgid ABOVE the bound really does reach it (else "no signal" would just mean the
# shipped function was never loaded — this test passed vacuously exactly that way once).
kill_log="$SANDBOX/killdouble.log"
probe="$(KILL_LOG="$kill_log" REAP_SRC="$reap_src" AGENTCTL_REAP_GRACE=0 bash -c '
  . "$REAP_SRC"
  kill()  { printf "%s\n" "$*" >> "$KILL_LOG"; return 0; }
  pgrep() { return 0; }                              # pretend every probed group is populated
  : > "$KILL_LOG"; kill -0 wiring-check; wired=$(wc -l < "$KILL_LOG" | tr -d " ")
  : > "$KILL_LOG"; reap_tree 0 "" >/dev/null 2>&1; zero=$(wc -l < "$KILL_LOG" | tr -d " ")
  : > "$KILL_LOG"; reap_tree 1 "" >/dev/null 2>&1; one=$(wc -l < "$KILL_LOG" | tr -d " ")
  : > "$KILL_LOG"; reap_tree 987654 "" >/dev/null 2>&1; hi=$(wc -l < "$KILL_LOG" | tr -d " ")
  printf "%s %s %s %s %s\n" "$(type -t reap_tree)" "$wired" "$zero" "$one" "$hi"')"
read -r bt_def bt_wired bt_zero bt_one bt_hi <<EOF
$probe
EOF
chk_eq "BT10/11 the shipped reap_tree is loaded and callable" "function" "$bt_def"
chk_eq "BT10/11 known positive: the kill double really intercepts" 1 "$bt_wired"
chk_eq "BT10/11 known positive: a pgid ABOVE the bound does reach the double" 2 "$bt_hi"
chk_eq "BT10 reap_tree 0 emitted zero signals" 0 "$bt_zero"
chk_eq "BT11 reap_tree 1 emitted zero signals" 0 "$bt_one"

# ── inventory: read-only candidate overview ────────────────────────────────────────────────
INVBIN="$SANDBOX/invbin"; INVRUN="$SANDBOX/invrun"; mkdir -p "$INVBIN" "$INVRUN"
export KILL_AUDIT="$SANDBOX/kill-audit.log" PROBE_AUDIT="$SANDBOX/probe-audit.log"
: > "$KILL_AUDIT"; : > "$PROBE_AUDIT"
# Every signal surface a scan could reach, stubbed to RECORD instead of act.
for k in kill pkill killall; do
  cat > "$INVBIN/$k" <<EOF
#!/usr/bin/env bash
printf '$k %s\n' "\$*" >> "$KILL_AUDIT"
exit 0
EOF
  chmod +x "$INVBIN/$k"
done
cat > "$INVBIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${PROBE_AUDIT:-/dev/null}"
case "$1" in kill-session|kill-server) printf 'tmux %s\n' "$*" >> "$KILL_AUDIT"; exit 0;; esac
[ "$1" = list-sessions ] || exit 0
case "${FAKE_TMUX_LS_RC:-0}" in
  0) [ -n "${FAKE_TMUX_SESSIONS:-}" ] && printf '%s\n' ${FAKE_TMUX_SESSIONS}; exit 0 ;;
  1) echo "no server running on /tmp/tmux-0/default" >&2; exit 1 ;;
  *) echo "tmux: connection refused" >&2; exit "$FAKE_TMUX_LS_RC" ;;
esac
EOF
cat > "$INVBIN/ps" <<'EOF'
#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "${PROBE_AUDIT:-/dev/null}"
if [ "$1" = "-axo" ]; then
  case "${FAKE_PS_MODE:-real}" in
    fail)      exit 1 ;;
    malformed) echo "4242 1 4242 Not A Date At All idle omp --mode=rpc"; exit 0 ;;
    clean)     echo "4242 4241 4241 Mon Aug 10 00:00:00 2026 01:02:03 /bin/zsh -l"; exit 0 ;;
  esac
fi
exec /bin/ps "$@"
EOF
chmod +x "$INVBIN/tmux" "$INVBIN/ps"
inv() { PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="${1:-$INVRUN}" bash "$AGENTCTL" inventory --dry-run 2>&1; }

# --- 13. [BT2] the argument contract is refused BEFORE anything is probed -------------------
: > "$KILL_AUDIT"; : > "$PROBE_AUDIT"; bad_ok=1
for form in "" "--apply" "--apply --yes" "--dry-run --apply" "--dry-run extra" "--bogus" "-n"; do
  o="$(PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="$INVRUN" bash "$AGENTCTL" inventory $form 2>&1)"; r=$?
  [ "$r" = 0 ] && bad_ok=0
  case "$o" in *"ERR: inventory"*) ;; *) bad_ok=0 ;; esac
done
chk_eq "BT2 every illegal inventory spelling is a typed non-zero refusal" 1 "$bad_ok"
chk_eq "BT2 a refusal reached no probe (no ps, no tmux)" "" "$(cat "$PROBE_AUDIT")"
chk_eq "BT2 a refusal reached no signal surface" "" "$(cat "$KILL_AUDIT")"
# --- 13b. the python entry keeps that promise too: argparse abbreviation is off per SUBPARSER
# (`allow_abbrev=False` on the top-level parser is NOT inherited — the plausible one-line fix)
r=0; python3 "$AW_DIR/duplexctl.py" --run-dir "$INVRUN" inventory --dry >/dev/null 2>&1 || r=$?
chk_eq "BT2 duplexctl refuses the abbreviated spelling (inventory --dry)" 2 "$r"
r=0; PATH="$INVBIN:$PATH" python3 "$AW_DIR/duplexctl.py" --run-dir "$INVRUN" inventory --dry-run >/dev/null 2>&1 || r=$?
chk_eq "BT2 the declared spelling still runs the read-only scan" 0 "$r"

orphan="$(spawn_orphan)"; /bin/sleep 0.5

# --- 14. [BT4] inventory is READ-ONLY while candidates it did not create coexist ------------
: > "$KILL_AUDIT"
out="$(PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="$INVRUN" FAKE_TMUX_SESSIONS="stray-shell" \
       bash "$AGENTCTL" inventory --dry-run 2>&1)"
chk_eq "BT4 the whole scan signalled nothing (kill/pkill/killall/tmux-kill audit empty)" "" \
       "$(cat "$KILL_AUDIT")"
chk_eq "BT4 the recorded fixture is still alive after the scan" "omp 97" \
       "$(ps -o args= -p "${orphan:-0}" 2>/dev/null)"
chk_eq "BT4 the report holds candidates we did not create, alongside the fixture" 1 \
  "$([ "$(printf '%s\n' "$out" | grep -cE '^(orphan-candidate|unattributed|record-without-tmux|tmux-without-record) ')" -ge 2 ] && echo 1 || echo 0)"
chk_eq "BT4 the python lane's only os.kill is the signal-0 liveness probe" "1 1" \
  "$(cat "$AW_DIR/duplexctl.py" "$AW_DIR/watchctl.py" | grep -c 'os\.kill(') $(cat "$AW_DIR/duplexctl.py" "$AW_DIR/watchctl.py" | grep -c 'os\.kill(int(pid), 0)')"

# --- 15. [BT5] a broken ps makes ONLY the census [unknown] — never empty, never 0 -----------
for mode in fail malformed; do
  out="$(PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="$INVRUN" FAKE_PS_MODE="$mode" \
         FAKE_TMUX_SESSIONS="stray-shell" bash "$AGENTCTL" inventory --dry-run 2>&1)"
  cen="$(printf '%s\n' "$out" | sed -n '/engine-orphan census/,$p' | tail -n +2)"
  chk_eq "BT5 ps $mode → the census block is exactly one [unknown] line" 1 \
         "$(printf '%s\n' "$cen" | grep -c '^\[unknown\] ')"
  chk_not_contains "BT5 ps $mode → the census never claims an empty world" "(none)" "$cen"
  chk_contains "BT5 ps $mode → the other block still reports" "stray-shell" "$out"
done

# --- 16. [BT7] known positive: a REAL PPID=1 fixture a PRODUCTION matcher claims ------------
# Synthetic but not fake: genuinely reparented to PID 1, and its argv is genuinely what the
# shipped matcher looks for. Both are proved BEFORE the census is read, so neither a fabricated
# row nor a fabricated predicate can carry this assertion.
chk_eq "BT7 pre-probe: the fixture is genuinely reparented to PPID=1" 1 \
       "$(ps -o ppid= -p "${orphan:-0}" 2>/dev/null | tr -d ' ')"
chk_eq "BT7 pre-probe: the fixture argv is exactly what the shipped matcher looks for" "omp 97" \
       "$(ps -o args= -p "${orphan:-0}" 2>/dev/null)"
out="$(inv)"
chk_eq "BT7 the census lists the fixture exactly once, as a candidate" 1 \
       "$(printf '%s\n' "$out" | grep -c "^orphan-candidate .*pid=$orphan ")"
chk_contains "BT7 labelled with the provider-table matcher" "matcher=direct:omp" "$out"
kill_recorded "$orphan" "omp 97"

# --- 17. [BT8] tmux-without-record is claimed only on an ATTRIBUTION SIGNAL -----------------
: > "$INVRUN/known.duplex.meta"                      # a record whose tmux session is gone
: > "$INVRUN/adopted.duplex.stderr.log"              # run-dir family, but no .duplex.meta
out="$(PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="$INVRUN" FAKE_PS_MODE=clean \
       FAKE_TMUX_SESSIONS="adopted stray-shell other-watchd" bash "$AGENTCTL" inventory --dry-run 2>&1)"
chk_eq "BT8 a record with no tmux session is record-without-tmux" 1 \
       "$(printf '%s\n' "$out" | grep -c '^record-without-tmux  *known$')"
chk_eq "BT8 a tmux session owning run-dir files is agentctl's" 1 \
       "$(printf '%s\n' "$out" | grep -c '^tmux-without-record  *adopted$')"
chk_eq "BT8 a -watchd session is agentctl's by naming" 1 \
       "$(printf '%s\n' "$out" | grep -c '^tmux-without-record  *other-watchd$')"
chk_eq "BT8 no attribution signal → unattributed, NOT an agentctl leak" 1 \
       "$(printf '%s\n' "$out" | grep -c '^unattributed  *stray-shell$')"
rm -f "$INVRUN/known.duplex.meta" "$INVRUN/adopted.duplex.stderr.log"

# --- 18. [BT9] a hermetic CLEAN fixture: both blocks explicitly empty, distinct from unknown -
# The negative control is a world we stubbed, never the developer's own box: "we saw nothing"
# is only evidence when every source of the nothing is under the test's control.
out="$(PATH="$INVBIN:$PATH" AGENT_WATCH_DIR="$SANDBOX/never-created" FAKE_PS_MODE=clean \
       FAKE_TMUX_LS_RC=1 bash "$AGENTCTL" inventory --dry-run 2>&1)"; rc=$?
chk_eq "BT9 the clean fixture exits 0" 0 "$rc"
chk_eq "BT9 both blocks report an explicit empty" 2 "$(printf '%s\n' "$out" | grep -c '^(none)$')"
chk_not_contains "BT9 an empty world is never dressed up as [unknown]" "[unknown]" "$out"
unset KILL_AUDIT PROBE_AUDIT

sandbox_clean
summary
