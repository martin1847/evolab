#!/usr/bin/env bash
# dispatch-exec (headless exec lane) — command construction + stateless classify contract.
# Live two-round smoke (claude/omp legs, real engines) ran 2026-07-11; this suite keeps the
# hermetic surface: launch/meta/stamp, engine command shape, every typed status branch.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DEXEC="$AW_DIR/dispatch-exec"

echo "== dispatch-exec: launch =="

# launch writes meta + round stamp, no rc, and a supervisor command with rc redirect.
sandbox_new
WT="$SANDBOX/wt with spaces"
mkdir -p "$WT"; printf 'do the thing\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd"
out="$(bash "$DEXEC" claude exS "$WT" --goal "$SANDBOX/goal.md" --deliverable "$WT/*.md" --model haiku 2>&1)"; rc=$?
chk_eq "launch rc0" 0 "$rc"
chk_contains "launch announces round 1" "round 1 started" "$out"
chk_eq "meta engine" claude "$(sed -n 's/^engine=//p' "$WATCH_RUN_DIR/exS.exec.meta")"
chk_eq "meta round" 1 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/exS.exec.meta")"
chk_eq "legacy launch has no workflow meta" 0 "$(grep -c '^workflow=' "$WATCH_RUN_DIR/exS.exec.meta" || true)"
chk_eq "legacy launch has no max-rounds meta" 0 "$(grep -c '^max_rounds=' "$WATCH_RUN_DIR/exS.exec.meta" || true)"
chk_eq "round stamp exists" 1 "$([ -f "$WATCH_RUN_DIR/exS.exec.round-started" ] && echo 1 || echo 0)"
chk_eq "no rc yet" 0 "$([ -f "$WATCH_RUN_DIR/exS.exec.rc" ] && echo 1 || echo 0)"
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
round1_prompt="$(ls "$WATCH_RUN_DIR"/exS.exec.prompt-r1-* | head -1)"
chk_contains "engine cmd is headless claude -p" "claude -p" "$cmd"
chk_contains "engine cmd json output" "--output-format json" "$cmd"
chk_contains "engine cmd reads generated round prompt" "cat $(printf %q "$round1_prompt")" "$cmd"
chk_contains "engine cmd passes extra args" "--model haiku" "$cmd"
chk_contains "supervisor writes rc on exit" "exec.rc" "$cmd"
chk_eq "engine runs directly, no start-gate spin" 1 "$(printf '%s' "$cmd" | grep -qE '^claude -p .* >> ' && echo 1 || echo 0)"
goal_bytes="$(wc -c < "$SANDBOX/goal.md" | tr -d ' ')"
chk_eq "round 1 preserves original prompt bytes as prefix" 0 "$(cmp -s "$SANDBOX/goal.md" <(head -c "$goal_bytes" "$round1_prompt"); echo $?)"
chk_contains "round 1 appends headless footer" "HEADLESS ROUND PROTOCOL" "$(cat "$round1_prompt")"
canonical_wt="$(sed -n 's/^cwd=//p' "$WATCH_RUN_DIR/exS.exec.meta")"
chk_contains "footer carries absolute spaced cwd blocker path" "$canonical_wt/BLOCKED.md" "$(cat "$round1_prompt")"
chk_contains "launch advertises stable typed status" "status: dispatch status exS" "$out"
chk_not_contains "launch does not expose raw rc path" "rc-on-exit" "$out"

# Every resume round gets a fresh combined prompt too; the caller's fix brief remains its prefix.
printf '{"result":"ok","session_id":"sid-footer"}\n' >> "$WATCH_RUN_DIR/exS.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/exS.exec.rc"
printf 'fix only this\n' > "$SANDBOX/fix round.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd-r2"
out2="$(bash "$DEXEC" send exS -f "$SANDBOX/fix round.md" 2>&1)"; rc=$?
chk_eq "resume with footer rc0" 0 "$rc"
round2_prompt="$(ls "$WATCH_RUN_DIR"/exS.exec.prompt-r2-* | head -1)"
fix_bytes="$(wc -c < "$SANDBOX/fix round.md" | tr -d ' ')"
chk_eq "round 2 preserves fix prompt bytes as prefix" 0 "$(cmp -s "$SANDBOX/fix round.md" <(head -c "$fix_bytes" "$round2_prompt"); echo $?)"
chk_contains "round 2 appends headless footer" "HEADLESS ROUND PROTOCOL" "$(cat "$round2_prompt")"
chk_contains "resume command reads round 2 prompt" "cat $(printf %q "$round2_prompt")" "$(cat "$FAKE_TMUX_CMD_FILE")"
# duplicate session refused
out="$(bash "$DEXEC" claude exS "$WT" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "duplicate session rc1" 1 "$rc"
sandbox_clean

# Prompt construction failure precedes any state mutation: previous round remains DONE.
sandbox_new; mkdir -p "$SANDBOX/wt" "$SANDBOX/not-a-prompt"
mkmeta="$WATCH_RUN_DIR/bf.exec.meta"
printf 'engine=claude\ncwd=%s\nround=1\nargs=\nsid=sid-bf\n' "$SANDBOX/wt" > "$mkmeta"
: > "$WATCH_RUN_DIR/bf.exec.round-started"; printf '{"session_id":"sid-bf"}\n' > "$WATCH_RUN_DIR/bf.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/bf.exec.rc"
out="$(bash "$DEXEC" send bf -f "$SANDBOX/not-a-prompt" 2>&1)"; rc=$?
chk_eq "prompt build failure rc1" 1 "$rc"
chk_eq "build failure preserves round" 1 "$(sed -n 's/^round=//p' "$mkmeta")"
chk_eq "build failure preserves rc" 1 "$([ -f "$WATCH_RUN_DIR/bf.exec.rc" ] && echo 1 || echo 0)"
chk_eq "build failure releases round lock" 0 "$([ -e "$WATCH_RUN_DIR/bf.exec.lock" ] && echo 1 || echo 0)"
out="$(bash "$DEXEC" status bf 2>&1)"; rc=$?
chk_eq "build failure leaves prior status DONE" 0 "$rc"
sandbox_clean

# --goal required
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DEXEC" omp exG "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "missing goal rc1" 1 "$rc"
sandbox_clean

echo "== dispatch-exec: explicit review-loop budget =="

# workflow and a positive max-rounds are an inseparable opt-in; invalid launches leave no meta.
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'review\n' > "$SANDBOX/goal.md"
for case_args in \
  '--workflow review-loop' \
  '--max-rounds 2' \
  '--workflow other --max-rounds 2' \
  '--workflow review-loop --max-rounds 0' \
  '--workflow review-loop --max-rounds nope'
do
  set -- $case_args
  out="$(bash "$DEXEC" codex badBudget "$SANDBOX/wt" --goal "$SANDBOX/goal.md" "$@" 2>&1)"; rc=$?
  chk_eq "invalid budget rejected: $case_args" 1 "$rc"
  chk_eq "invalid budget leaves no meta: $case_args" 0 "$([ -e "$WATCH_RUN_DIR/badBudget.exec.meta" ] && echo 1 || echo 0)"
done
sandbox_clean

# max-rounds counts total rounds: round 1 launches, round 2 resumes, the next send exits 9
# before launch or any authoritative session-state mutation.
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'review\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_LAUNCH_LOG="$SANDBOX/launch.log"; : > "$FAKE_TMUX_LAUNCH_LOG"
out="$(bash "$DEXEC" codex reviewBudget "$SANDBOX/wt" --goal "$SANDBOX/goal.md" --workflow review-loop --max-rounds 2 2>&1)"; rc=$?
chk_eq "review-loop launch rc0" 0 "$rc"
chk_eq "review-loop workflow persisted" review-loop "$(sed -n 's/^workflow=//p' "$WATCH_RUN_DIR/reviewBudget.exec.meta")"
chk_eq "review-loop max persisted" 2 "$(sed -n 's/^max_rounds=//p' "$WATCH_RUN_DIR/reviewBudget.exec.meta")"
printf '{"type":"thread.started","thread_id":"tid-budget"}\n' >> "$WATCH_RUN_DIR/reviewBudget.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/reviewBudget.exec.rc"
out="$(bash "$DEXEC" send reviewBudget -m 'round two' 2>&1)"; rc=$?
chk_eq "round below max allowed" 0 "$rc"
chk_eq "allowed send reaches round 2" 2 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/reviewBudget.exec.meta")"
printf 'round two done\n' >> "$WATCH_RUN_DIR/reviewBudget.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/reviewBudget.exec.rc"
before_meta="$(cat "$WATCH_RUN_DIR/reviewBudget.exec.meta")"
before_rc="$(cat "$WATCH_RUN_DIR/reviewBudget.exec.rc")"
before_out="$(cat "$WATCH_RUN_DIR/reviewBudget.exec.out")"
before_launches="$(wc -l < "$FAKE_TMUX_LAUNCH_LOG" | tr -d ' ')"
before_msgs="$(find "$WATCH_RUN_DIR" -name 'reviewBudget.exec.msg-*' | wc -l | tr -d ' ')"
out="$(bash "$DEXEC" send reviewBudget -m 'round three' 2>&1)"; rc=$?
chk_eq "round at max exits 9" 9 "$rc"
chk_contains "round at max names budget exhaustion" "BUDGET-EXHAUSTED" "$out"
chk_eq "budget refusal preserves meta" "$before_meta" "$(cat "$WATCH_RUN_DIR/reviewBudget.exec.meta")"
chk_eq "budget refusal preserves rc" "$before_rc" "$(cat "$WATCH_RUN_DIR/reviewBudget.exec.rc")"
chk_eq "budget refusal preserves out" "$before_out" "$(cat "$WATCH_RUN_DIR/reviewBudget.exec.out")"
chk_eq "budget refusal does not launch" "$before_launches" "$(wc -l < "$FAKE_TMUX_LAUNCH_LOG" | tr -d ' ')"
chk_eq "budget refusal leaves no prompt" 0 "$(find "$WATCH_RUN_DIR" -name 'reviewBudget.exec.prompt-r3-*' | wc -l | tr -d ' ')"
chk_eq "budget refusal creates no message temp" "$before_msgs" "$(find "$WATCH_RUN_DIR" -name 'reviewBudget.exec.msg-*' | wc -l | tr -d ' ')"
chk_eq "budget refusal releases lock" 0 "$([ -e "$WATCH_RUN_DIR/reviewBudget.exec.lock" ] && echo 1 || echo 0)"
sandbox_clean

# codex/omp engine command shapes (claude covered above)
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'go\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tc-codex"
bash "$DEXEC" codex exC "$SANDBOX/wt" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
chk_contains "codex engine cmd carries hook trust before json" "codex exec --dangerously-bypass-hook-trust --json" "$cmd"
chk_contains "codex engine cwd flag" "-C " "$cmd"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tc-omp"
bash "$DEXEC" omp exO "$SANDBOX/wt" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
chk_contains "omp engine cmd" "omp -p" "$cmd"
chk_contains "omp pinned session dir" "--session-dir" "$cmd"
sandbox_clean

# tmux new-session FAILURE must not report success nor leave round-1 meta (codex review:
# unchecked launch printed "round 1 started", orphaned meta, destroyed the previous rc).
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'go\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_NEWSESSION_FAIL=1
out="$(bash "$DEXEC" claude exNsf "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "new-session failure rc1" 1 "$rc"
chk_contains "new-session failure named" "new-session failed" "$out"
chk_not_contains "no false round-started" "round 1 started" "$out"
chk_eq "no orphan meta on launch failure" 0 "$([ -f "$WATCH_RUN_DIR/exNsf.exec.meta" ] && echo 1 || echo 0)"
unset FAKE_TMUX_NEWSESSION_FAIL
sandbox_clean

# send discovers + persists sid under the round lock (including replacement metacharacters).
sandbox_new; mkdir -p "$SANDBOX/wt"
printf 'engine=claude\ncwd=%s\nround=1\nargs=\n' "$SANDBOX/wt" > "$WATCH_RUN_DIR/r8.exec.meta"
: > "$WATCH_RUN_DIR/r8.exec.round-started"
printf '{"result":"ok","session_id":"new&weird|sid"}\n' > "$WATCH_RUN_DIR/r8.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/r8.exec.rc"
bash "$DEXEC" send r8 -m continue >/dev/null 2>&1
chk_eq "send harvests sid under lock" 'new&weird|sid' "$(sed -n 's/^sid=//p' "$WATCH_RUN_DIR/r8.exec.meta")"
chk_eq "exactly one sid line" 1 "$(grep -c '^sid=' "$WATCH_RUN_DIR/r8.exec.meta")"
sandbox_clean

# P1 regression (independent review 2026-07-11): launching onto a name held by a LIVE
# (TUI) tmux session must fail WITHOUT leaving exec.meta — an orphan meta permanently
# self-routes that session's send/watch/teardown into the exec lane.
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'go\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_HASSESSION=0   # session name already taken
out="$(bash "$DEXEC" claude exColl "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "collision launch rc1" 1 "$rc"
chk_eq "collision leaves NO orphan meta" 0 "$([ -f "$WATCH_RUN_DIR/exColl.exec.meta" ] && echo 1 || echo 0)"
unset FAKE_TMUX_HASSESSION
sandbox_clean

echo "== dispatch-exec: status classify =="

mkstate() { # $1 session  $2 cwd — minimal meta + stamp
  printf 'engine=claude\ncwd=%s\nround=1\nargs=\n' "$2" > "$WATCH_RUN_DIR/$1.exec.meta"
  : > "$WATCH_RUN_DIR/$1.exec.round-started"
}

# RUNNING: no rc + tmux session alive -> exit 10
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r1 "$SANDBOX/wt"
export FAKE_TMUX_HASSESSION=0
out="$(bash "$DEXEC" status r1 2>&1)"; rc=$?
chk_eq "running exit10" 10 "$rc"; chk_contains "running marker" "RUNNING" "$out"
unset FAKE_TMUX_HASSESSION; sandbox_clean

# killed mid-flight: no rc + no session -> exit 2
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r2 "$SANDBOX/wt"
out="$(bash "$DEXEC" status r2 2>&1)"; rc=$?
chk_eq "dead exit2" 2 "$rc"; chk_contains "dead marker" "AGENT-DEAD" "$out"
sandbox_clean

# DONE rc=0: status may display discovered sid but must not persist it.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r3 "$SANDBOX/wt"
printf '{"result":"ok","session_id":"sid-abc-123"}\n' > "$WATCH_RUN_DIR/r3.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/r3.exec.rc"
before_meta="$(cat "$WATCH_RUN_DIR/r3.exec.meta")"
out="$(bash "$DEXEC" status r3 2>&1)"; rc=$?
chk_eq "done exit0" 0 "$rc"; chk_contains "done marker" "DONE" "$out"
chk_contains "status displays pure-read discovered sid" "sid=sid-abc-123" "$out"
chk_eq "status does not mutate meta" "$before_meta" "$(cat "$WATCH_RUN_DIR/r3.exec.meta")"

# watch/classify is also pure-read when output contains a new sid.
before_meta="$(cat "$WATCH_RUN_DIR/r3.exec.meta")"
out="$(bash "$DEXEC" watch r3 2>&1)"; rc=$?
chk_eq "watch done exit0" 0 "$rc"
chk_eq "watch does not mutate meta" "$before_meta" "$(cat "$WATCH_RUN_DIR/r3.exec.meta")"
sandbox_clean

# BLOCKED.md newer than stamp -> exit 4 (headless WAITING-INPUT)
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r4 "$SANDBOX/wt"
touch -t 202601010000 "$WATCH_RUN_DIR/r4.exec.round-started"
printf 'need a decision\n' > "$SANDBOX/wt/BLOCKED.md"
printf '0\n' > "$WATCH_RUN_DIR/r4.exec.rc"; : > "$WATCH_RUN_DIR/r4.exec.out"
out="$(bash "$DEXEC" status r4 2>&1)"; rc=$?
chk_eq "blocked exit4" 4 "$rc"; chk_contains "blocked marker" "BLOCKED.md" "$out"
sandbox_clean

# same-second cliff (review nit): BLOCKED.md written within the SAME second as the arm
# stamp must still classify WAITING (>= stamp, not strictly-newer) — a fast round's
# doubt-protocol must never read as DONE.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r4s "$SANDBOX/wt"
printf 'doubt\n' > "$SANDBOX/wt/BLOCKED.md"   # stamp and file land in the same second
printf '0\n' > "$WATCH_RUN_DIR/r4s.exec.rc"; : > "$WATCH_RUN_DIR/r4s.exec.out"
out="$(bash "$DEXEC" status r4s 2>&1)"; rc=$?
chk_eq "same-second BLOCKED exit4" 4 "$rc"
sandbox_clean

# engine failed rc!=0 -> exit 2 ; quota chrome -> exit 5
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r5 "$SANDBOX/wt"
printf 'boom\n' > "$WATCH_RUN_DIR/r5.exec.out"; printf '1\n' > "$WATCH_RUN_DIR/r5.exec.rc"
out="$(bash "$DEXEC" status r5 2>&1)"; rc=$?
chk_eq "failed exit2" 2 "$rc"
printf 'error: insufficient_quota\n' > "$WATCH_RUN_DIR/r5.exec.out"
out="$(bash "$DEXEC" status r5 2>&1)"; rc=$?
chk_eq "quota exit5" 5 "$rc"; chk_contains "quota marker" "STALLED-EXTERNAL" "$out"
sandbox_clean

# codex lying rc: turn.failed event with rc=0 -> exit 2, not DONE
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r6 "$SANDBOX/wt"
printf '{"type":"turn.failed","error":{"message":"x"}}\n' > "$WATCH_RUN_DIR/r6.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/r6.exec.rc"
out="$(bash "$DEXEC" status r6 2>&1)"; rc=$?
chk_eq "turn.failed beats rc0" 2 "$rc"
sandbox_clean

# deliverable gate: stale -> 6 ; fresh -> 0
# (backdate the stamp: same-second mtimes make -nt false under bash 3.2 second precision)
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate r7 "$SANDBOX/wt"
touch -t 202601010000 "$WATCH_RUN_DIR/r7.exec.round-started"
printf 'deliverable=%s\n' "$SANDBOX/wt/*.out.md" >> "$WATCH_RUN_DIR/r7.exec.meta"
printf '0\n' > "$WATCH_RUN_DIR/r7.exec.rc"; : > "$WATCH_RUN_DIR/r7.exec.out"
touch -t 202501010000 "$SANDBOX/wt/old.out.md"
out="$(bash "$DEXEC" status r7 2>&1)"; rc=$?
chk_eq "stale deliverable exit6" 6 "$rc"; chk_contains "nodeliv marker" "IDLE-NO-DELIVERABLE" "$out"
chk_contains "exit6 directs a fix round via send" "dispatch send r7" "$out"
chk_contains "exit6 forbids premature teardown" "do not teardown" "$out"
touch "$SANDBOX/wt/new.out.md"
out="$(bash "$DEXEC" status r7 2>&1)"; rc=$?
chk_eq "fresh deliverable exit0" 0 "$rc"
sandbox_clean

echo "== dispatch-exec: send (resume round) =="

# Two simultaneous sends serialize before any state mutation: exactly one starts round 2.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate conc "$SANDBOX/wt"
printf 'sid=sid-conc\n' >> "$WATCH_RUN_DIR/conc.exec.meta"; : > "$WATCH_RUN_DIR/conc.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/conc.exec.rc"
export FAKE_TMUX_HOLD_FILE="$SANDBOX/hold" FAKE_TMUX_LAUNCH_LOG="$SANDBOX/launch.log"
: > "$FAKE_TMUX_HOLD_FILE"
bash "$DEXEC" send conc -m first > "$SANDBOX/first.out" 2>&1 & first_pid=$!
for _ in $(seq 150); do [ -e "$WATCH_RUN_DIR/conc.exec.lock" ] && break; /bin/sleep 0.02; done
out="$(bash "$DEXEC" send conc -m second 2>&1)"; rc=$?
chk_eq "concurrent second send rejected" 1 "$rc"
chk_contains "concurrent rejection names transition" "round transition already in progress" "$out"
rm -f "$FAKE_TMUX_HOLD_FILE"; wait "$first_pid"; first_rc=$?
chk_eq "concurrent first send launches" 0 "$first_rc"
chk_eq "concurrent sends launch exactly once" 1 "$(wc -l < "$FAKE_TMUX_LAUNCH_LOG" | tr -d ' ')"
chk_eq "concurrent sends increment round once" 2 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/conc.exec.meta")"
chk_eq "concurrent metadata leaves no temp" 0 "$(find "$WATCH_RUN_DIR" -name 'conc.exec.meta-*' | wc -l | tr -d ' ')"
chk_not_contains "concurrent loser has no mktemp collision" "mktemp" "$out"
chk_not_contains "concurrent winner has no mktemp collision" "mktemp" "$(cat "$SANDBOX/first.out")"
sandbox_clean

# Pure-read status racing a send cannot roll metadata back after locked sid harvest/round commit.
sandbox_new; mkdir -p "$SANDBOX/wt"
printf 'engine=claude\ncwd=%s\nround=1\nargs=--model test-model\ndeliverable=%s\n' "$SANDBOX/wt" "$SANDBOX/wt/*.artifact" > "$WATCH_RUN_DIR/srace.exec.meta"
: > "$WATCH_RUN_DIR/srace.exec.round-started"
printf '{"session_id":"sid-srace"}\n' > "$WATCH_RUN_DIR/srace.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/srace.exec.rc"
( for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do bash "$DEXEC" status srace >/dev/null 2>&1 || true; done ) & status_pid=$!
out="$(bash "$DEXEC" send srace -m next 2>&1)"; rc=$?; wait "$status_pid"
chk_eq "status race send succeeds" 0 "$rc"
chk_eq "status race keeps committed round" 2 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/srace.exec.meta")"
chk_eq "status race keeps cwd" "$SANDBOX/wt" "$(sed -n 's/^cwd=//p' "$WATCH_RUN_DIR/srace.exec.meta")"
chk_eq "status race keeps args" "--model test-model" "$(sed -n 's/^args=//p' "$WATCH_RUN_DIR/srace.exec.meta" | tail -1)"
chk_eq "status race keeps deliverable" "$SANDBOX/wt/*.artifact" "$(sed -n 's/^deliverable=//p' "$WATCH_RUN_DIR/srace.exec.meta")"
chk_eq "status race persists discovered sid once" 1 "$(grep -c '^sid=sid-srace$' "$WATCH_RUN_DIR/srace.exec.meta")"
sandbox_clean

# Dead holder PID makes the lock stale: the next send takes over and proceeds.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate stale "$SANDBOX/wt"
printf 'sid=sid-stale\n' >> "$WATCH_RUN_DIR/stale.exec.meta"; : > "$WATCH_RUN_DIR/stale.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/stale.exec.rc"
printf '99999999\n' > "$WATCH_RUN_DIR/stale.exec.lock"
out="$(bash "$DEXEC" send stale -m retry 2>&1)"; rc=$?
chk_eq "stale round lock recovers" 0 "$rc"
chk_eq "stale recovery starts round 2" 2 "$(sed -n 's/^round=//p' "$WATCH_RUN_DIR/stale.exec.meta")"
chk_eq "stale lock removed after launch" 0 "$([ -e "$WATCH_RUN_DIR/stale.exec.lock" ] && echo 1 || echo 0)"
sandbox_clean

# Resume launch failure mutates nothing: prior DONE round/meta/rc/output remain authoritative.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate lf "$SANDBOX/wt"
printf 'sid=sid-lf\n' >> "$WATCH_RUN_DIR/lf.exec.meta"; printf 'prior output\n' > "$WATCH_RUN_DIR/lf.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/lf.exec.rc"
before_meta="$(cat "$WATCH_RUN_DIR/lf.exec.meta")"; before_out="$(cat "$WATCH_RUN_DIR/lf.exec.out")"
export FAKE_TMUX_NEWSESSION_FAIL=1
out="$(bash "$DEXEC" send lf -m retry 2>&1)"; rc=$?
unset FAKE_TMUX_NEWSESSION_FAIL
chk_eq "resume launch failure rc1" 1 "$rc"
chk_eq "resume launch failure preserves meta" "$before_meta" "$(cat "$WATCH_RUN_DIR/lf.exec.meta")"
chk_eq "resume launch failure preserves rc" 0 "$(cat "$WATCH_RUN_DIR/lf.exec.rc")"
chk_eq "resume launch failure preserves output" "$before_out" "$(cat "$WATCH_RUN_DIR/lf.exec.out")"
out="$(bash "$DEXEC" status lf 2>&1)"; rc=$?
chk_eq "resume launch failure leaves prior DONE" 0 "$rc"
chk_eq "resume launch failure cleans prepared files" 0 "$(find "$WATCH_RUN_DIR" -name 'lf.exec.prompt-*' | wc -l | tr -d ' ')"
sandbox_clean

# SIGTERM during a held launch must run the lock cleanup trap.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate term "$SANDBOX/wt"
printf 'sid=sid-term\n' >> "$WATCH_RUN_DIR/term.exec.meta"; : > "$WATCH_RUN_DIR/term.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/term.exec.rc"
export FAKE_TMUX_HOLD_FILE="$SANDBOX/term-hold"; : > "$FAKE_TMUX_HOLD_FILE"
bash "$DEXEC" send term -m stop-me > "$SANDBOX/term.out" 2>&1 & term_pid=$!
for _ in $(seq 150); do [ -e "$FAKE_TMUX_HOLD_FILE.started" ] && break; /bin/sleep 0.02; done
kill -TERM "$term_pid" 2>/dev/null || true; rm -f "$FAKE_TMUX_HOLD_FILE"; wait "$term_pid" 2>/dev/null || true
for _ in $(seq 150); do [ ! -e "$WATCH_RUN_DIR/term.exec.lock" ] && break; /bin/sleep 0.02; done
chk_eq "SIGTERM leaves no round lock" 0 "$([ -e "$WATCH_RUN_DIR/term.exec.lock" ] && echo 1 || echo 0)"
sandbox_clean

# send without harvested sid refused; with sid builds a resume command.
sandbox_new; mkdir -p "$SANDBOX/wt"; mkstate s1 "$SANDBOX/wt"
: > "$WATCH_RUN_DIR/s1.exec.out"
out="$(bash "$DEXEC" send s1 -m 'fix it' 2>&1)"; rc=$?
chk_eq "send w/o sid rc1" 1 "$rc"; chk_contains "send w/o sid msg" "no engine session id" "$out"
printf 'sid=sid-abc-123\n' >> "$WATCH_RUN_DIR/s1.exec.meta"
printf '0\n' > "$WATCH_RUN_DIR/s1.exec.rc"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd-resume"
out="$(bash "$DEXEC" send s1 -m 'fix it' 2>&1)"; rc=$?
chk_eq "send rc0" 0 "$rc"
chk_contains "send announces round 2" "round 2 started" "$out"
chk_contains "resume cmd carries sid" "--resume sid-abc-123" "$(cat "$FAKE_TMUX_CMD_FILE")"
chk_eq "send truncates rc for new round" 0 "$([ -f "$WATCH_RUN_DIR/s1.exec.rc" ] && echo 1 || echo 0)"
sandbox_clean

# codex resume drops launch-only flags (-s/-C rejected by `exec resume`; self-caught when
# codex's own re-review round died on argv) but keeps the rest.
sandbox_new; mkdir -p "$SANDBOX/wt"
printf 'engine=codex\ncwd=%s\nround=1\nargs=-s workspace-write --skip-git-repo-check\nsid=tid-1\n' "$SANDBOX/wt" > "$WATCH_RUN_DIR/cs.exec.meta"
: > "$WATCH_RUN_DIR/cs.exec.round-started"; : > "$WATCH_RUN_DIR/cs.exec.out"; printf '0\n' > "$WATCH_RUN_DIR/cs.exec.rc"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tc-resume"
bash "$DEXEC" send cs -m 'closure' >/dev/null 2>&1
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
chk_contains "codex resume uses thread id" "codex exec resume tid-1" "$cmd"
chk_not_contains "codex resume drops -s" " -s " "$cmd"
chk_not_contains "codex resume drops sandbox value" "workspace-write" "$cmd"
chk_contains "codex resume keeps compatible flags" "--skip-git-repo-check" "$cmd"
sandbox_clean

# classify reads the CURRENT round only: error tokens quoted in an EARLIER round's output
# (a review discussing quota detection!) must not flip a plain failure into exit 5.
sandbox_new; mkdir -p "$SANDBOX/wt"
printf 'engine=claude\ncwd=%s\nround=2\nargs=\n' "$SANDBOX/wt" > "$WATCH_RUN_DIR/xr.exec.meta"
: > "$WATCH_RUN_DIR/xr.exec.round-started"
{ printf '── round 1 @ x ──\nreview prose quoting insufficient_quota and No API key\n'
  printf '── round 2 @ x ──\nerror: unexpected argument\n'; } > "$WATCH_RUN_DIR/xr.exec.out"
printf '2\n' > "$WATCH_RUN_DIR/xr.exec.rc"
out="$(bash "$DEXEC" status xr 2>&1)"; rc=$?
chk_eq "old-round quota prose does not misclassify rc2" 2 "$rc"
chk_contains "plain FAILED marker" "FAILED" "$out"
sandbox_clean

echo "== interface routing (dispatch/watch/teardown are the stable surface) =="

# DEFAULT lane = exec (2026-07-12 flip): a bare launch through `dispatch` routes headless.
sandbox_new
mkdir -p "$SANDBOX/wt"; printf 'go\n' > "$SANDBOX/goal.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-cmd"
out="$(bash "$DISPATCH" claude ifS "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_eq "default launch rc0" 0 "$rc"
chk_contains "default launch routed to exec lane" "round 1 started" "$out"
chk_not_contains "default launch is not TUI" "dispatched claude" "$out"
# legacy DISPATCH_EXEC=1 is a harmless no-op (still exec)
out="$(DISPATCH_EXEC=1 bash "$DISPATCH" claude ifL "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_contains "legacy DISPATCH_EXEC=1 still exec" "round 1 started" "$out"
# escape hatch: DISPATCH_TUI=1 (canonical) and DISPATCH_EXEC=0 (muscle-memory) stay TUI
out="$(DISPATCH_TUI=1 bash "$DISPATCH" claude ifT "$SANDBOX/wt" 2>&1)"; rc=$?
chk_contains "DISPATCH_TUI=1 launch stays TUI" "dispatched claude" "$out"
out="$(DISPATCH_EXEC=0 bash "$DISPATCH" claude ifT2 "$SANDBOX/wt" 2>&1)"; rc=$?
chk_contains "legacy DISPATCH_EXEC=0 escape stays TUI" "dispatched claude" "$out"
# TUI has no durable round counter: explicit review-loop flags must fail, not leak to the engine.
out="$(DISPATCH_TUI=1 bash "$DISPATCH" codex ifTR "$SANDBOX/wt" --goal "$SANDBOX/goal.md" --workflow review-loop --max-rounds 2 2>&1)"; rc=$?
chk_eq "TUI review-loop rejected" 1 "$rc"
chk_contains "TUI review-loop rejection is clear" "TUI review-loop is unsupported" "$out"
chk_eq "TUI review-loop did not launch" 0 "$([ -e "$WATCH_RUN_DIR/ifTR.events" ] && echo 1 || echo 0)"
# send self-routes by session state (exec.meta present), no switch needed
printf 'sid=sid-xyz\n' >> "$WATCH_RUN_DIR/ifS.exec.meta"
printf '0\n' > "$WATCH_RUN_DIR/ifS.exec.rc"; : > "$WATCH_RUN_DIR/ifS.exec.out"
out="$(bash "$DISPATCH" send ifS -m 'round two' 2>&1)"; rc=$?
chk_eq "send self-routes rc0" 0 "$rc"
chk_contains "send self-routes to exec lane" "round 2 started" "$out"
# watch delegates to the exec classify for exec-lane sessions
# (send truncated rc; fake tmux has no session -> exec classify says AGENT-DEAD 2 —
#  the point here is DELEGATION: the TUI watch would have said NO-HOOK 8 instead)
out="$(bash "$WATCH" ifS 2>&1)"; rc=$?
chk_eq "watch delegates typed exit" 2 "$rc"
chk_contains "watch delegate speaks exec vocabulary" "AGENT-DEAD" "$out"
sandbox_clean

# watch delegation on a finished exec session -> DONE 0
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'engine=claude\ncwd=%s\nround=1\nargs=\n' "$SANDBOX/wt" > "$WATCH_RUN_DIR/wd.exec.meta"
: > "$WATCH_RUN_DIR/wd.exec.round-started"
printf '{"result":"ok","session_id":"s"}\n' > "$WATCH_RUN_DIR/wd.exec.out"
printf '0\n' > "$WATCH_RUN_DIR/wd.exec.rc"
printf '99999999\n' > "$WATCH_RUN_DIR/wd.exec.lock"   # stale lock: watch/teardown must not care
out="$(bash "$WATCH" wd 2>&1)"; rc=$?
chk_eq "watch delegate DONE rc0" 0 "$rc"
chk_contains "watch delegate DONE marker" "DONE" "$out"
# teardown cleans exec-lane state
out="$(bash "$TEARDOWN" wd 2>&1)"; rc=$?
chk_eq "teardown exec rc0" 0 "$rc"
chk_eq "teardown removed exec state" 0 "$(ls "$WATCH_RUN_DIR"/wd.exec.* 2>/dev/null | wc -l | tr -d ' ')"
chk_eq "teardown removed exec lock" 0 "$([ -e "$WATCH_RUN_DIR/wd.exec.lock" ] && echo 1 || echo 0)"
sandbox_clean

summary
