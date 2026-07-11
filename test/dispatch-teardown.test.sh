#!/usr/bin/env bash
# Best-effort coverage of dispatch + teardown FILE-manipulation logic (the parts that
# don't require a real agent/tmux). Fake tmux makes new-session/has-session no-op.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== dispatch =="

# cwd not found -> exit 1.
sandbox_new
out="$(bash "$DISPATCH" omp s "$SANDBOX/nope" 2>&1)"; rc=$?
chk_eq "dispatch bad-cwd rc1" 1 "$rc"
chk_contains "dispatch bad-cwd msg" "cwd not found" "$out"
sandbox_clean

# unknown agent -> exit 1.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" frobnicate s "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch unknown-agent rc1" 1 "$rc"
chk_contains "dispatch unknown-agent msg" "unknown agent" "$out"
sandbox_clean

# existing tmux session -> exit 1.
sandbox_new
mkdir -p "$SANDBOX/wt"
export FAKE_TMUX_HASSESSION=0   # has-session returns success => exists
out="$(bash "$DISPATCH" omp s "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch existing-session rc1" 1 "$rc"
chk_contains "dispatch existing-session msg" "already exists" "$out"
sandbox_clean

# omp dispatch: truncates a fresh sentinel + prints monitor/events lines + rc0.
sandbox_new
mkdir -p "$SANDBOX/wt"
# pre-seed a stale sentinel; dispatch should truncate it (`: > file`).
printf 'STALE WORKING old\n' > "$WATCH_RUN_DIR/ompS.events"
out="$(bash "$DISPATCH" omp ompS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch omp rc0" 0 "$rc"
sz="$(wc -c < "$WATCH_RUN_DIR/ompS.events" | tr -d ' ')"
chk_eq "dispatch omp truncates sentinel" 0 "$sz"
chk_contains "dispatch omp announces" "dispatched omp" "$out"
chk_contains "dispatch omp monitor line" "monitor:" "$out"
sandbox_clean

# Option parsing preserves argv boundaries: spaces stay inside one arg, and a quoted
# deliverable glob stays literal even when it already matches multiple files.
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'a\n' > "$SANDBOX/wt/a.md"; printf 'b\n' > "$SANDBOX/wt/b.md"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-command" FAKE_TMUX_DELIV_FILE="$SANDBOX/tmux-deliverable"
glob="$SANDBOX/wt/*.md"
out="$(bash "$DISPATCH" omp argS "$SANDBOX/wt" --deliverable "$glob" '--label=alpha beta' 'literal*value' 2>&1)"; rc=$?
chk_eq "dispatch boundary args rc0" 0 "$rc"
cmd="$(cat "$FAKE_TMUX_CMD_FILE")"
chk_contains "agent arg with spaces shell-quoted" '--label=alpha\ beta' "$cmd"
chk_contains "literal star agent arg shell-quoted" 'literal\*value' "$cmd"
chk_not_contains "deliverable match a not leaked into agent args" "$SANDBOX/wt/a.md" "$cmd"
chk_not_contains "deliverable match b not leaked into agent args" "$SANDBOX/wt/b.md" "$cmd"
chk_eq "deliverable glob preserved literally" "$glob" "$(cat "$FAKE_TMUX_DELIV_FILE")"
sandbox_clean

# Regression: AGENT_ARGS empty (no extra agent args) must not blow up under `set -u`.
# On bash 3.2 (macOS default) "${AGENT_ARGS[@]}" on a DECLARED-BUT-EMPTY array raises
# "unbound variable" even though the array exists — hit in real usage 2026-07-10. The
# script has no `set -e`, so the failure was SILENT: the $(...) building CMD aborted
# before quote_args ever ran, CMD collapsed to just the env-var prefix (no agent binary
# at all), dispatch still printed "dispatched ..." and returned rc0, and the tmux pane
# died immediately because it had nothing to exec. Assert both no error text AND that
# the tmux command actually contains the agent invocation (catches silent truncation).
sandbox_new
mkdir -p "$SANDBOX/wt"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-command-bare-omp"
out="$(bash "$DISPATCH" omp bareOmp "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch omp no-args rc0" 0 "$rc"
chk_not_contains "dispatch omp no-args no unbound-variable" "unbound variable" "$out"
chk_contains "dispatch omp no-args cmd not truncated" "omp --hook" "$(cat "$SANDBOX/tmux-command-bare-omp" 2>/dev/null)"
sandbox_clean

sandbox_new
mkdir -p "$SANDBOX/wt"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-command-bare-codex"
out="$(bash "$DISPATCH" codex bareCdx "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch codex no-args rc0" 0 "$rc"
chk_not_contains "dispatch codex no-args no unbound-variable" "unbound variable" "$out"
chk_contains "dispatch codex no-args cmd not truncated" "AGENT_WATCH_DIR=" "$(cat "$SANDBOX/tmux-command-bare-codex" 2>/dev/null)"
cmd_codex="$(cat "$SANDBOX/tmux-command-bare-codex" 2>/dev/null)"
case "$cmd_codex" in *"codex") _record "dispatch codex no-args cmd ends in bare codex" 1 ;; *) _record "dispatch codex no-args cmd ends in bare codex" 0 "got[$cmd_codex]" ;; esac
sandbox_clean

sandbox_new
mkdir -p "$SANDBOX/wt"
export FAKE_TMUX_CMD_FILE="$SANDBOX/tmux-command-bare-claude"
out="$(bash "$DISPATCH" claude bareClaude "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch claude no-args rc0" 0 "$rc"
chk_not_contains "dispatch claude no-args no unbound-variable" "unbound variable" "$out"
cmd_claude="$(cat "$SANDBOX/tmux-command-bare-claude" 2>/dev/null)"
case "$cmd_claude" in *"claude") _record "dispatch claude no-args cmd ends in bare claude" 1 ;; *) _record "dispatch claude no-args cmd ends in bare claude" 0 "got[$cmd_claude]" ;; esac
sandbox_clean

# codex dispatch: writes .codex/hooks.json with ABS replaced by the hooks dir.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" codex cdxS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "dispatch codex rc0" 0 "$rc"
cfg="$SANDBOX/wt/.codex/hooks.json"
if [ -f "$cfg" ]; then _record "dispatch codex writes hooks.json" 1; else _record "dispatch codex writes hooks.json" 0 "missing"; fi
body="$(cat "$cfg" 2>/dev/null)"
chk_not_contains "dispatch codex ABS substituted" "ABS/emit" "$body"
chk_contains "dispatch codex points at emit-from-stdin" "$AW_DIR/hooks/emit-from-stdin.sh" "$body"
sandbox_clean

# --goal with missing file -> exit 1 BEFORE any session is launched (no orphan session).
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" omp gS "$SANDBOX/wt" --goal "$SANDBOX/nope.md" 2>&1)"; rc=$?
chk_eq "goal missing rc1" 1 "$rc"
chk_contains "goal missing msg" "goal file not found" "$out"
chk_not_contains "goal missing launches nothing" "dispatched" "$out"
sandbox_clean

# --goal accepts a real path containing spaces without re-splitting it.
# (Idle pane + silent sentinel ⇒ the fused watch ends exit 8 NO-HOOK — the delivery
# assertion is the point here; rc asserts the verdict is the honest 8, not a fake DONE.)
sandbox_new
mkdir -p "$SANDBOX/wt"
goal="$SANDBOX/goal with spaces.md"; printf 'goal\n' > "$goal"
pane_fixture "done\n"
out="$(bash "$DISPATCH" omp gsS "$SANDBOX/wt" --goal "$goal" 2>&1)"; rc=$?
chk_eq "goal path with spaces rc = NO-HOOK verdict" 8 "$rc"
chk_contains "goal path with spaces delivered intact" "delivering goal via send: $goal" "$out"
sandbox_clean

# codex --goal fused round-1: no sentinel (codex hook fires on first tool call) but pane busy
# -> tier-2 message, NOT the false "STOP and re-dispatch" alarm; goal delivery lands via pane.
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'brief\n' > "$SANDBOX/brief.md"
pane_fixture "▌ Working (3s · esc to interrupt)"
out="$(bash "$DISPATCH" codex cgS "$SANDBOX/wt" --goal "$SANDBOX/brief.md" 2>&1)"; rc=$?
chk_contains "codex goal send lands via pane" "[send] OK" "$out"
chk_contains "codex goal pane tier" "pane is BUSY" "$out"
chk_not_contains "codex goal no false alarm" "STOP and re-dispatch" "$out"
chk_contains "codex goal hands to watch" "handing off to watch" "$out"
# fused exit code = watch VERDICT; the output must spell it out so a nonzero background
# notification can't be misread as dispatch failure (3+ field misreads, LH 2026-07-11).
chk_contains "fused verdict line present" "watch verdict: exit $rc" "$out"
chk_contains "fused verdict disclaims dispatch failure" "NOT a dispatch failure" "$out"
chk_contains "engine visibility line" "engine : codex" "$out"
sandbox_clean

# codex --goal on first-ever launch: trust prompt auto-answered (branch coverage via output).
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'brief\n' > "$SANDBOX/brief.md"
pane_fixture "Do you trust this directory?  1) yes  2) no"
out="$(bash "$DISPATCH" codex ctrS "$SANDBOX/wt" --goal "$SANDBOX/brief.md" 2>&1)"; rc=$?
chk_contains "codex trust prompt auto-answered" "codex trust/acceptance prompt detected" "$out"
sandbox_clean

# claude --goal first-ever launch: SAME trust auto-answer (claude's "I trust this folder" wording).
# Regression guard for the e2e-caught gap where the claude branch had no trust handling.
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'goal\n' > "$SANDBOX/goal.md"
pane_fixture "Is this a project you created or one you trust?  1. Yes, I trust this folder  2. No"
out="$(bash "$DISPATCH" claude cltrS "$SANDBOX/wt" --goal "$SANDBOX/goal.md" 2>&1)"; rc=$?
chk_contains "claude trust prompt auto-answered" "claude trust/acceptance prompt detected" "$out"
sandbox_clean

# --goal with neither sentinel nor busy pane -> alarm tier preserved.
sandbox_new
mkdir -p "$SANDBOX/wt"
printf 'brief\n' > "$SANDBOX/brief.md"
pane_fixture '$'
out="$(bash "$DISPATCH" omp gS2 "$SANDBOX/wt" --goal "$SANDBOX/brief.md" 2>&1)"; rc=$?
chk_contains "goal dead-signal alarm" "NO sentinel after 12s and pane not busy" "$out"
sandbox_clean

# codex dispatch with existing config -> WARN, NOT clobbered.
sandbox_new
mkdir -p "$SANDBOX/wt/.codex"
printf '{"existing":true}\n' > "$SANDBOX/wt/.codex/hooks.json"
out="$(bash "$DISPATCH" codex cdx2 "$SANDBOX/wt" 2>&1)"; rc=$?
chk_contains "dispatch codex existing WARNs" "NOT modifying" "$out"
chk_eq "dispatch codex existing not clobbered" '{"existing":true}' "$(cat "$SANDBOX/wt/.codex/hooks.json")"
out="$(bash "$TEARDOWN" cdx2 "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "teardown after existing codex config rc0" 0 "$rc"
chk_eq "teardown preserves existing codex config" '{"existing":true}' "$(cat "$SANDBOX/wt/.codex/hooks.json")"
sandbox_clean

# send rotates the freshness epoch at delivery time (codex review: late watch-arm stamp
# missed fast deliverables; SIGKILL+next-round rearm measured against the OLD epoch).
sandbox_new
mkdir -p "$SANDBOX/wt"
touch -t 202601010000 "$WATCH_RUN_DIR/rot.watch-armed" "$SANDBOX/ref"
seed_events rot 'x WORKING t0\n'
pane_fixture "▌ Working (3s · esc to interrupt)"
out="$(bash "$DISPATCH" send rot -m 'next round' 2>&1)"; rc=$?
chk_eq "send rc0" 0 "$rc"
chk_eq "send rotates arm stamp" 1 "$([ "$WATCH_RUN_DIR/rot.watch-armed" -nt "$SANDBOX/ref" ] && echo 1 || echo 0)"
sandbox_clean

# --deliverable persists per session; launch without it clears a stale one; retained
# exec-lane meta blocks a same-name TUI launch (codex review: lane hijack).
sandbox_new
mkdir -p "$SANDBOX/wt"
bash "$DISPATCH" omp pers "$SANDBOX/wt" --deliverable "$SANDBOX/wt/*.md" >/dev/null 2>&1
chk_eq "deliverable persisted" "$SANDBOX/wt/*.md" "$(cat "$WATCH_RUN_DIR/pers.deliverable" 2>/dev/null)"
bash "$TEARDOWN" pers >/dev/null 2>&1
chk_eq "teardown removes persisted gate" 0 "$([ -f "$WATCH_RUN_DIR/pers.deliverable" ] && echo 1 || echo 0)"
printf 'engine=claude\n' > "$WATCH_RUN_DIR/hijack.exec.meta"
out="$(bash "$DISPATCH" omp hijack "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "TUI launch onto exec-lane name rc1" 1 "$rc"
chk_contains "TUI launch names the exec state" "exec-lane state" "$out"
sandbox_clean

echo "== teardown =="

# teardown removes a Codex config created by this dispatch session.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" codex tdS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "owned codex dispatch rc0" 0 "$rc"
chk_eq "owned codex marker exists" 1 "$([ -f "$WATCH_RUN_DIR/tdS.hook-owner" ] && echo 1 || echo 0)"
out="$(bash "$TEARDOWN" tdS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "teardown rc0" 0 "$rc"
if [ -f "$WATCH_RUN_DIR/tdS.events" ]; then _record "teardown removes sentinel" 0 "still present"; else _record "teardown removes sentinel" 1; fi
if [ -f "$SANDBOX/wt/.codex/hooks.json" ]; then _record "teardown removes codex cfg" 0 "still present"; else _record "teardown removes codex cfg" 1; fi
chk_eq "teardown removes codex ownership marker" 0 "$([ -f "$WATCH_RUN_DIR/tdS.hook-owner" ] && echo 1 || echo 0)"
chk_contains "teardown reports session" "tmux session tdS" "$out"
sandbox_clean

# A session ownership marker cannot authorize deletion in a different cwd.
sandbox_new
mkdir -p "$SANDBOX/owned" "$SANDBOX/other/.codex"
out="$(bash "$DISPATCH" codex ownS "$SANDBOX/owned" 2>&1)"; rc=$?
printf '{"other":true}\n' > "$SANDBOX/other/.codex/hooks.json"
out="$(bash "$TEARDOWN" ownS "$SANDBOX/other" 2>&1)"; rc=$?
chk_eq "teardown wrong cwd rejected" 1 "$rc"
chk_eq "wrong cwd config preserved" '{"other":true}' "$(cat "$SANDBOX/other/.codex/hooks.json")"
chk_eq "owned config preserved after wrong cwd" 1 "$([ -f "$SANDBOX/owned/.codex/hooks.json" ] && echo 1 || echo 0)"
chk_eq "ownership marker retained after wrong cwd" 1 "$([ -f "$WATCH_RUN_DIR/ownS.hook-owner" ] && echo 1 || echo 0)"
sandbox_clean

# Replacing a session-created config transfers it out of teardown ownership.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" codex replS "$SANDBOX/wt" 2>&1)"; rc=$?
printf '{"user_replacement":true}\n' > "$SANDBOX/wt/.codex/hooks.json"
out="$(bash "$TEARDOWN" replS "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "teardown replaced config rejected" 1 "$rc"
chk_eq "replaced config preserved" '{"user_replacement":true}' "$(cat "$SANDBOX/wt/.codex/hooks.json")"
chk_eq "ownership marker retained after replacement" 1 "$([ -f "$WATCH_RUN_DIR/replS.hook-owner" ] && echo 1 || echo 0)"
sandbox_clean

# teardown also removes a Claude config created by this dispatch session.
sandbox_new
mkdir -p "$SANDBOX/wt"
out="$(bash "$DISPATCH" claude tdC "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "owned claude dispatch rc0" 0 "$rc"
chk_eq "owned claude marker exists" 1 "$([ -f "$WATCH_RUN_DIR/tdC.hook-owner" ] && echo 1 || echo 0)"
out="$(bash "$TEARDOWN" tdC "$SANDBOX/wt" 2>&1)"; rc=$?
chk_eq "teardown claude rc0" 0 "$rc"
chk_eq "teardown removes claude cfg" 0 "$([ -f "$SANDBOX/wt/.claude/settings.json" ] && echo 1 || echo 0)"
chk_eq "teardown removes claude ownership marker" 0 "$([ -f "$WATCH_RUN_DIR/tdC.hook-owner" ] && echo 1 || echo 0)"
sandbox_clean

# teardown with no cwd: just removes sentinel, no error.
sandbox_new
printf 'DONE x\n' > "$WATCH_RUN_DIR/tdS2.events"
out="$(bash "$TEARDOWN" tdS2 2>&1)"; rc=$?
chk_eq "teardown no-cwd rc0" 0 "$rc"
if [ -f "$WATCH_RUN_DIR/tdS2.events" ]; then _record "teardown no-cwd removes sentinel" 0; else _record "teardown no-cwd removes sentinel" 1; fi
sandbox_clean

summary
