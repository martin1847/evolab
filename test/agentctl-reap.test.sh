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
chk_contains "duplexctl tmux_alive probes exact name" 'f"={name}"' "$(cat "$AW_DIR/duplexctl.py")"
chk_eq "duplexctl has no bare -t name target" "" "$(grep -n '"-t", name' "$AW_DIR/duplexctl.py")"
chk_contains "start pins remain-on-exit off (dead-pane pid trap, S1)" 'remain-on-exit off' "$src"

sandbox_clean
summary
