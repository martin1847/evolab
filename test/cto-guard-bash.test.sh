#!/usr/bin/env bash
# cto-guard-bash.py — PreToolUse·Bash guard. Drives it with synthetic tool_input.command payloads.
# Asserts: (1) deny trailing `&`/`& disown` ; (2) deny naive idle==done poller (no positive grep) ;
# everything else passes silently. Deny = exit 2 + stderr ; pass = exit 0, no output.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agentctl/cto-guard-bash.py"

echo "== cto-guard-bash.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

# Hermetic cwd: guard (8) scope-gates on the REAL filesystem around payload cwd (umbrella =
# >=2 sibling .git children within 5 ancestor levels). A dev machine's ~ is often itself an
# umbrella, so every payload pins an explicit cwd — a deep single-repo dir by default (rules
# 1-7 unaffected), a constructed umbrella root only in the rule-8 battery.
G8ROOT="$(mktemp -d)"
trap 'rm -rf "$G8ROOT"' EXIT
mkdir -p "$G8ROOT/iso/l1/l2/l3/l4/repo/.git" "$G8ROOT/umb/a/.git" "$G8ROOT/umb/b/.git"
ISO_REPO="$G8ROOT/iso/l1/l2/l3/l4/repo"
UMB_ROOT="$G8ROOT/umb"
GUARD_CWD="$ISO_REPO"; export GUARD_CWD

mkcmd() { # $1 command, $2 run_in_background (optional "1")
  python3 -c 'import json,os,sys
ti={"command":sys.argv[1]}
if len(sys.argv)>2 and sys.argv[2]=="1": ti["run_in_background"]=True
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":ti,"cwd":os.environ["GUARD_CWD"]}))' "$@"; }
run() { # $1 command [$2 run_in_background] -> OUT(stdout) ERR(stderr) RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$@" | python3 "$GUARD" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}

# wired as executable via frontmatter `./...` — exec bit + shebang must hold
chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# (1) trailing shell & -> ORPHAN, DENY
run 'npm run dev &'
chk_eq "trailing & denied (exit 2)" 2 "$RC"; chk_contains "trailing & stderr" "ORPHAN" "$ERR"
run 'bash watch s1 & disown'
chk_eq "& disown denied" 2 "$RC"
run 'nohup poll.sh &'
chk_eq "nohup ... & denied" 2 "$RC"
# ALLOW (silent): not a trailing-& backgrounding
run 'a && echo done'
chk_eq "&& chain allowed" 0 "$RC"; chk_eq "&& chain no stderr" "" "$ERR"
run 'curl -s url 2>&1 | tee log'
chk_eq "2>&1 redirect allowed" 0 "$RC"
run 'echo "a & b"'
chk_eq "& inside quotes allowed" 0 "$RC"
# embedded quotes/braces — the case shell-regex would choke on, python json parses
run 'echo "a & b }" && ls'
chk_eq "embedded quotes/braces allowed" 0 "$RC"
# `&& disown` is a (nonsensical) && chain, not a trailing-& backgrounding -> allowed (one-regex simplification)
run 'a && disown'
chk_eq "&& disown allowed (not a bg &)" 0 "$RC"
# mid-chain backgrounding `foo & bar` (background-then-chain) — the 2026-07-04 blind spot, now DENY
run 'nohup poll.sh & echo started'
chk_eq "background-then-chain denied" 2 "$RC"

# (4) raw tmux send-keys with CJK / long payload -> DENY (popup eats Enter); safe path passes
run 'tmux send-keys -t s1 "请把理解门复述发我，确认后开工①②③" Enter'
chk_eq "send-keys CJK denied (exit 2)" 2 "$RC"; chk_contains "send-keys deny points to agentctl steer" "agentctl steer" "$ERR"
run 'tmux send-keys -t s1 Escape'
chk_eq "send-keys control key allowed" 0 "$RC"
run 'tmux send-keys -t s1 "read /tmp/goal.md" Enter'
chk_eq "send-keys short ASCII allowed" 0 "$RC"
run 'bash references/agentctl/agentctl steer s1 -m "长中文放行指令：按评审意见回修①②"'
chk_eq "agentctl steer safe path allowed" 0 "$RC"

# Heredoc bodies are safe to ignore only when Bash disables expansion by quoting the delimiter.
quoted_heredoc="$(printf '%s\n' "cat <<'EOF'" 'tmux send-keys -t s1 "这只是文档里的提及①②③" Enter' 'EOF')"
run "$quoted_heredoc"
chk_eq "quoted heredoc body mentioning guarded command allowed" 0 "$RC"

unquoted_heredoc="$(printf '%s\n' 'cat <<EOF' '$(tmux send-keys -t s1 "这会在 heredoc 中执行①②③" Enter)' 'EOF')"
run "$unquoted_heredoc"
chk_eq "unquoted heredoc command substitution remains guarded" 2 "$RC"

guarded_after_heredoc="$(printf '%s\n' "cat <<'EOF'" 'tmux send-keys -t s1 "quoted body mention①②③" Enter' 'EOF' 'tmux send-keys -t s1 "实际执行①②③" Enter')"
run "$guarded_after_heredoc"
chk_eq "guarded command after quoted heredoc remains guarded" 2 "$RC"

# (2) naive idle==done poller, DENY
run 'while true; do tmux capture-pane -p | grep Working; sleep 5; done'
chk_eq "naive idle poller denied (exit 2)" 2 "$RC"; chk_contains "idle poller stderr" "idle" "$ERR"
# ALLOW: poller WITH positive-evidence check
run 'while true; do tmux capture-pane -p|grep Working; git diff --stat; sleep 5; done'
chk_eq "poller + git positive allowed" 0 "$RC"
run 'for i in 1 2; do tmux capture-pane -p | grep -E "busy|Verdict"; done'
chk_eq "poller + Verdict positive allowed" 0 "$RC"
# ALLOW: capture-pane but no loop
run 'tmux capture-pane -p | grep Working'
chk_eq "single capture (no loop) allowed" 0 "$RC"

# (3) launch without a watcher -> ALLOW + JSON reminder (`agentctl start` never auto-watches).
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }
run 'bash references/agentctl/agentctl start omp mysess /wt --goal /tmp/g.md'
chk_eq "start w/o watch exit 0" 0 "$RC"
chk_contains "start w/o watch reminds arm watcher" "watcher" "$(ctx "$OUT")"
chk_contains "reminder names the session" "mysess" "$(ctx "$OUT")"
# start WITH watch on the same session, BACKGROUNDED -> silent (no double-nag)
run 'agentctl start omp mysess /wt --goal /tmp/g.md && bash references/agentctl/agentctl watch mysess' 1
chk_eq "start + watch same cmd (bg) exit 0" 0 "$RC"; chk_eq "start + watch silent" "" "$OUT"

# (5) blocking `agentctl watch` in the FOREGROUND -> DENY (killed at Bash timeout, exit 143)
run 'agentctl steer mysess -f /tmp/fix.md && bash references/agentctl/agentctl watch mysess'
chk_eq "chained foreground watch denied (field case)" 2 "$RC"; chk_contains "foreground deny names 143" "143" "$ERR"
run 'AGENT_WATCH_POLL_SECS=5 bash references/agentctl/agentctl watch mysess'
chk_eq "env-prefixed foreground watch denied" 2 "$RC"
# explicit sync opt-out for shell orchestrators that run watch synchronously by design
run 'AGENT_WATCH_SYNC=1 bash references/agentctl/agentctl watch mysess; rc=$?'
chk_eq "AGENT_WATCH_SYNC=1 foreground allowed" 0 "$RC"
# start returns after the goal frame is accepted -> foreground is fine
run 'bash references/agentctl/agentctl start omp mysess /wt --goal /tmp/g.md'
chk_eq "start --goal foreground allowed (returns immediately)" 0 "$RC"
# path as an ARGUMENT is not an invocation (self-inflicted false positives, 2026-07-11)
run 'grep -n foo references/agentctl/agentctl references/agentctl/duplexctl.py'
chk_eq "agentctl path as grep arg allowed" 0 "$RC"
run 'grep -n x agentctl/duplexctl.py agentctl/agentctl'
chk_eq "arg after .py arg allowed (suffix trap)" 0 "$RC"
run 'agentctl status mysess'
chk_eq "one-shot status foreground allowed" 0 "$RC"
# wrapper chains are still command position (review S2 2026-07-19 bypass census)
run 'command agentctl watch mysess'
chk_eq "command-wrapper watch denied" 2 "$RC"
run 'env FOO=1 agentctl watch mysess'
chk_eq "env-wrapper watch denied" 2 "$RC"
run 'timeout 30 agentctl watch mysess'
chk_eq "timeout-wrapper watch denied" 2 "$RC"
run "bash -lc 'agentctl watch mysess'"
chk_eq "bash -lc payload watch denied" 2 "$RC"
# R2 bypass census: path-qualified wrappers and quoted payloads are still command position
run '/usr/bin/env FOO=1 agentctl watch mysess'
chk_eq "path-qualified env wrapper denied" 2 "$RC"
run "/bin/bash -lc 'agentctl watch mysess'"
chk_eq "path-qualified bash -lc payload denied" 2 "$RC"
run "bash -lc 'command agentctl watch mysess'"
chk_eq "wrapper inside quoted payload denied" 2 "$RC"
# the sync marker must be attached AND unquoted
run 'echo AGENT_WATCH_SYNC=1; agentctl watch mysess'
chk_eq "detached sync marker does not bypass" 2 "$RC"
run "echo 'AGENT_WATCH_SYNC=1 agentctl watch'; agentctl watch mysess"
chk_eq "quoted-data forged marker does not bypass" 2 "$RC"
run "AGENT_WATCH_SYNC=1 bash -lc 'agentctl watch mysess'"
chk_eq "unquoted prefix marker on wrapped call allowed" 0 "$RC"
# rule 3 pairing must be a command-position invocation, not prose/echo
run 'bash references/agentctl/agentctl start omp mysess /wt --goal /tmp/g.md; echo watch mysess'
chk_contains "prose watch does not silence the reminder" "watcher" "$(ctx "$OUT")"
run 'bash references/agentctl/agentctl start omp mysess /wt --goal /tmp/g.md; echo agentctl watch mysess'
chk_contains "echoed invocation text does not silence the reminder" "watcher" "$(ctx "$OUT")"
# ── (6) live e2e gates: premium orchestrator must dispatch, runner declares E2E_ECONOMY=1 ──
run 'bash test/e2e/guard-wire.e2e.sh'
chk_eq "bare e2e gate run denied" 2 "$RC"; chk_contains "e2e deny teaches dispatch+marker" "E2E_ECONOMY=1" "$ERR"
chk_contains "e2e deny carries doc pointer" "SKILL.md" "$ERR"
run "zsh -lc 'cd /repo/test/e2e && bash onboard.e2e.sh; echo RC=\$?'"
chk_eq "wrapped e2e gate run denied" 2 "$RC"
run './test/e2e/run.sh'
chk_eq "e2e run.sh denied" 2 "$RC"
run "zsh -lc 'cd /repo/test/e2e && E2E_ECONOMY=1 bash onboard.e2e.sh; echo RC=\$?'"
chk_eq "declared economy runner allowed" 0 "$RC"
# path as ARGUMENT (reading/grepping the script) is not an invocation
run 'grep -n model test/e2e/round-lane.e2e.sh'
chk_eq "e2e path as grep arg allowed" 0 "$RC"
run 'head -25 test/e2e/guard-wire.e2e.sh'
chk_eq "e2e path as head arg allowed" 0 "$RC"

# ── (7) worktree lifecycle: non-force standing grant; force/prune deny + one-shot override ──
rm -f /tmp/cto-allow-worktree-destroy
run 'git worktree remove /tmp/wt-x'
chk_eq "non-force remove auto-allowed" 0 "$RC"; chk_contains "standing grant reason" "standing grant" "$OUT"
run 'git worktree remove --force /tmp/wt-x'
chk_eq "force remove denied" 2 "$RC"; chk_contains "force deny names override marker" "cto-allow-worktree-destroy" "$ERR"
run 'git worktree remove -f /tmp/wt-x'
chk_eq "-f remove denied" 2 "$RC"
run 'git worktree prune'
chk_eq "prune denied" 2 "$RC"
run 'cd /x && git worktree remove --force wt'
chk_eq "chained force denied (hidden at tail)" 2 "$RC"
run 'git -C /repo worktree prune'
chk_eq "-C form prune denied" 2 "$RC"
run 'echo "git worktree prune"'
chk_eq "quoted prune as data allowed" 0 "$RC"; chk_eq "quoted prune no auto-allow" "" "$OUT"
run 'git worktree remove /tmp/a && rm -rf /tmp/b'
chk_eq "mixed non-benign chain falls to classifier" 0 "$RC"; chk_eq "mixed chain gets no auto-allow" "" "$OUT"
touch /tmp/cto-allow-worktree-destroy
run 'git worktree prune'
chk_eq "override marker lifts deny" 0 "$RC"; chk_eq "override gives no auto-allow (permission flow applies)" "" "$OUT"
chk_eq "override marker consumed (one-shot)" 0 "$([ -e /tmp/cto-allow-worktree-destroy ] && echo 1 || echo 0)"
run 'git worktree prune'
chk_eq "second run denies again (no standing bypass)" 2 "$RC"
# review 2026-07-24 regressions: consumption IS the approval — an unremovable object at the
# marker path must deny (a mkdir'd marker was a permanent standing bypass), and git
# global-option forms (quoted -C path vanishes from the unquoted view / -c key=val) must
# still hit the destroy DENY
mkdir /tmp/cto-allow-worktree-destroy
run 'git worktree prune'
chk_eq "dir at marker path still denied (consumption failed)" 2 "$RC"
run 'git worktree prune'
chk_eq "dir marker denies repeatably (no standing bypass)" 2 "$RC"
rmdir /tmp/cto-allow-worktree-destroy
run "git -C '/repo with space' worktree prune"
chk_eq "quoted -C path prune denied" 2 "$RC"
run 'git -C "/repo with space" worktree remove --force wt'
chk_eq "quoted -C path force remove denied" 2 "$RC"
run 'git -c core.quotePath=false worktree prune'
chk_eq "-c global-option prune denied" 2 "$RC"
# benign prune: metadata-only prune auto-allows, everything unproven keeps the DENY.
# Fixture: one prunable entry whose dir is GONE (nothing to lose) + one prunable entry
# whose dir SURVIVES (`.git` removed, files still there = a real target).
WT="$G8ROOT/wt"; mkdir -p "$WT"
# identity inline: CI runners have no global user.email — a bare `git commit` dies silently
# in the ()>/dev/null wrapper and the whole fixture degrades to an EMPTY repo, turning the
# bad-sample DENY into a mystery benign ALLOW (CI red 2026-08-10, ubuntu green-locally trap)
( git init -q "$WT/repo" && cd "$WT/repo" \
  && git -c user.email=ci@test -c user.name=ci commit -q --allow-empty -m init \
  && git worktree add -q "$WT/gone" && git worktree add -q "$WT/here" ) >/dev/null 2>&1
rm -rf "$WT/gone"; rm -f "$WT/here/.git"
# known-positive precondition: the scenario must EXIST before its verdict means anything
chk_eq "fixture probe: both worktrees are prunable to this git" 2 \
  "$(git -C "$WT/repo" worktree list --porcelain 2>/dev/null | grep -c '^prunable ')"
run "git -C $WT/repo worktree prune"
chk_eq "prune with a surviving prunable worktree stays denied" 2 "$RC"
rm -rf "$WT/here"
run "git -C $WT/repo worktree prune"
chk_contains "metadata-only prune auto-allowed" "benign" "$OUT"
run "git -C $WT/repo worktree prune && git -C $WT/other worktree prune"
chk_eq "multi-repo prune chain is outside the closed syntax (denied)" 2 "$RC"
# porcelain we cannot parse ⇒ judgement unavailable ⇒ deny (orphan `prunable`, no segment)
FAKEGIT="$G8ROOT/fakegit"; mkdir -p "$FAKEGIT"
{ echo '#!/bin/sh'; echo 'echo "prunable orphan"'; } > "$FAKEGIT/git"; chmod +x "$FAKEGIT/git"
OLDPATH="$PATH"; PATH="$FAKEGIT:$PATH"
run "git -C $WT/repo worktree prune"
PATH="$OLDPATH"
chk_eq "malformed porcelain denies (fail-closed)" 2 "$RC"

# ── (8) cwd anchoring: umbrella workspaces deny unanchored git/gh; single-repo never fires ──
GUARD_CWD="$UMB_ROOT"
run 'git status'
chk_eq "umbrella bare git denied" 2 "$RC"; chk_contains "umbrella deny pointer" "cwd" "$ERR"
run 'gh pr list'
chk_eq "umbrella bare gh denied" 2 "$RC"
run 'FOO=1 git status'
chk_eq "umbrella env-prefixed git denied" 2 "$RC"
run '/opt/homebrew/bin/git status'
chk_eq "umbrella path-qualified git denied" 2 "$RC"
run 'git -C /x status && git push'
chk_eq "one unanchored segment in a chain denied" 2 "$RC"
run 'echo hi; (git push)'
chk_eq "subshell-paren bare git denied" 2 "$RC"
run 'cd /abs/repo && git status && git push'
chk_eq "leading cd anchors the whole chain" 0 "$RC"
run 'git -C /abs/repo status'
chk_eq "git -C self-anchor allowed" 0 "$RC"
run 'gh -R owner/repo pr list'
chk_eq "gh -R self-anchor allowed" 0 "$RC"
run 'gh --repo owner/repo pr view 1'
chk_eq "gh --repo self-anchor allowed" 0 "$RC"
run 'gh api repos/o/r/pulls'
chk_eq "gh api self-anchored allowed" 0 "$RC"
run 'echo git status'
chk_eq "git as quoted-free argument allowed" 0 "$RC"
# review round 2026-07-26: every probe below was a live bypass (rc=0) or false deny (rc=2)
run 'cd /definitely-missing || git status'
chk_eq "cd-or-else chain denied (cd may fail)" 2 "$RC"
run 'cd /definitely-missing; git status'
chk_eq "cd semicolon chain denied (cd may fail)" 2 "$RC"
run 'cd /definitely-missing | git status'
chk_eq "cd in pipeline denied (no cwd effect)" 2 "$RC"
run 'cd relative/dir && git status'
chk_eq "relative cd is not an anchor" 2 "$RC"
run 'command git status'
chk_eq "command-wrapper bare git denied" 2 "$RC"
run 'env FOO=1 git status'
chk_eq "env-wrapper bare git denied" 2 "$RC"
run "bash -lc 'git status'"
chk_eq "interpreter payload bare git denied" 2 "$RC"
run '"git" status'
chk_eq "quoted command token denied" 2 "$RC"
run 'g\it status'
chk_eq "backslash-escaped git denied" 2 "$RC"
run "bash -lc 'git -C /x status'"
chk_eq "interpreter payload anchored git allowed" 0 "$RC"
run 'git --version'
chk_eq "repo-insensitive git --version allowed" 0 "$RC"
run 'gh auth status'
chk_eq "repo-insensitive gh auth allowed" 0 "$RC"
run 'git -c color.ui=false -C /repo status'
chk_eq "global options before -C still anchored" 0 "$RC"
# review round 2 2026-07-26: multiline / wrapper-args / ANSI-C / shell-consumer / relative anchors
run "$(printf 'echo ready\ngit status')"
chk_eq "multiline second-line git denied" 2 "$RC"
run "$(printf 'cd /abs && git status\ngit push')"
chk_eq "git beyond cd anchor via newline denied" 2 "$RC"
run 'cd /abs && git status; git push'
chk_eq "git beyond cd anchor via semicolon denied" 2 "$RC"
run 'cd /abs && git status || git push'
chk_eq "git beyond cd anchor via or-else denied" 2 "$RC"
run 'cd /abs && git status | grep clean'
chk_eq "pipe inside cd-anchored chain allowed" 0 "$RC"
run 'timeout -s KILL 30 git status'
chk_eq "wrapper with option argument denied" 2 "$RC"
run 'nice git status'
chk_eq "nice-wrapped bare git denied" 2 "$RC"
run "\$'git' status"
chk_eq "ANSI-C quoted command token denied" 2 "$RC"
run "$(printf "bash <<'EOF'\ngit status\nEOF")"
chk_eq "quoted-heredoc shell consumer denied" 2 "$RC"
run "$(printf 'bash <<EOF\ngit status\nEOF')"
chk_eq "unquoted-heredoc shell consumer denied" 2 "$RC"
run "printf 'git status\n' | bash"
chk_eq "pipe-to-shell script body denied" 2 "$RC"
run 'git -C . status'
chk_eq "relative -C is not an anchor" 2 "$RC"
run 'git -C ../a status'
chk_eq "parent-relative -C is not an anchor" 2 "$RC"
run 'git --git-dir=.git status'
chk_eq "relative --git-dir is not an anchor" 2 "$RC"
run 'git --work-tree=/tmp status'
chk_eq "--work-tree alone is not a repo anchor" 2 "$RC"
run 'git --git-dir=/abs/repo/.git status'
chk_eq "absolute --git-dir anchors" 0 "$RC"
run "git -C '/repo with space' status"
chk_eq "quoted absolute -C anchors" 0 "$RC"
run 'git config --global --get user.name'
chk_eq "git config --global is repo-insensitive" 0 "$RC"
run 'git config user.name'
chk_eq "repo-local git config still needs anchor" 2 "$RC"
run 'gh extension list'
chk_eq "gh extension is repo-insensitive" 0 "$RC"
mkdir -p "$UMB_ROOT/a/d1/d2/d3/d4"
GUARD_CWD="$UMB_ROOT/a/d1/d2/d3/d4"
run 'git status'
chk_eq "umbrella as 5th ancestor still fires" 2 "$RC"
ln -s "$UMB_ROOT/a" "$G8ROOT/link-a"
GUARD_CWD="$G8ROOT/link-a"
run 'git status'
chk_eq "symlinked cwd resolves into umbrella" 2 "$RC"
GUARD_CWD="/nonexistent-cto-guard-g8"
run 'git status'
chk_eq "unreadable cwd fails open" 0 "$RC"
GUARD_CWD="$ISO_REPO"
run 'git status'
chk_eq "single-repo scope gate never fires" 0 "$RC"

# non-dispatch command -> silent
run 'git status'
chk_eq "non-dispatch silent" "" "$OUT"

# checker controls: malformed/missing/broken must not collapse into a clean allow.
# ── (9) browser ownership: Playwright's own isolated browser only, never the daily Chrome ──
# Bad samples = the two gated takeover flags; good samples = the isolated paths the rule steers to.
# The last two bad samples are the SHELL-EXECUTED token surface: the shell eats backslash/quote
# spans before exec, so a raw-byte match would let the identical takeover through (review 2026-08-12).
run 'playwright-cli attach --extension=chrome'
chk_eq "attach --extension denied" 2 "$RC"; chk_contains "extension deny names the isolated path" "playwright-cli open" "$ERR"
run 'playwright-cli attach --cdp=http://localhost:9222'
chk_eq "attach --cdp denied" 2 "$RC"
run 'playwright\-cli attach --cdp=http://localhost:9222'
chk_eq "backslash-escaped binary name still denied" 2 "$RC"
run 'playwright-cli at\tach --extension=chrome'
chk_eq "backslash-escaped subcommand still denied" 2 "$RC"
run 'playwright-cli open https://example.com'
chk_eq "isolated open allowed" 0 "$RC"; chk_eq "isolated open silent" "" "$ERR"
run 'npx playwright test --project=chromium'
chk_eq "playwright test run allowed" 0 "$RC"

run ''
chk_eq "empty command allowed" 0 "$RC"; chk_eq "empty command no stderr" "" "$ERR"
# (10) gate output piped — rc masked + evidence truncated (LESSON pipe-masks-exit-code n=3)
run 'bash test/run.sh 2>&1 | tail -3'
chk_eq "gate|tail denied" 2 "$RC"; chk_contains "gate|tail names the disease" "exit code is the LAST" "$ERR"
run './agentmail.test.sh | grep -c FAIL'
chk_eq "test.sh|grep denied" 2 "$RC"
run 'bash skills/cto-orchestration/references/retro-check.sh --base main --docs docs | head -5'
chk_eq "retro-check|head denied" 2 "$RC"
run 'bash test/run.sh > /tmp/gate.log 2>&1; echo rc=$?'
chk_eq "file-first shape allowed" 0 "$RC"; chk_eq "file-first silent" "" "$ERR"
run 'grep -n FAIL test/retro-check.test.sh | head -5'
chk_eq "gate path as grep ARGUMENT allowed" 0 "$RC"
run 'bash test/run.sh && echo ok'
chk_eq "gate && chain (no pipe) allowed" 0 "$RC"
run 'bash test/run.sh || echo failed'
chk_eq "gate || chain is not a pipe" 0 "$RC"
run 'tail -3 /tmp/gate.log | grep FAIL'
chk_eq "piping a LOG FILE (not the gate) allowed" 0 "$RC"
run 'echo done; bash test/run.sh > /tmp/g.log 2>&1'
chk_eq "gate in later segment, pipe-free, allowed" 0 "$RC"
# review reproductions 2026-08-13 (1 blocker + 2 major) as standing assertions
run "$(printf 'echo ready\nbash test/run.sh | tail -3')"
chk_eq "NEWLINE-separated gate pipe denied (blocker repro)" 2 "$RC"
run 'env bash test/run.sh | tail -3'
chk_eq "env wrapper denied" 2 "$RC"
run 'command bash test/run.sh | tail -3'
chk_eq "command wrapper denied" 2 "$RC"
run '/bin/bash test/run.sh | tail -3'
chk_eq "abs-path interpreter denied" 2 "$RC"
run 'bash test/run\.sh | tail -3'
chk_eq "backslash-escaped path denied" 2 "$RC"
run "bash test/'run.sh' | tail -3"
chk_eq "quoted path segment denied" 2 "$RC"
run "bash test/run.sh --filter 'a;b' | tail -3"
chk_eq "quoted arg with ; does not split the segment" 2 "$RC"
run "echo '(bash test/run.sh | tail -3)'"
chk_eq "quoted prose is DATA, not a gate (false-positive repro)" 0 "$RC"
run "echo 'note; bash test/run.sh | tail -3'"
chk_eq "quoted prose with ; is DATA" 0 "$RC"
# (10b) `;`-broken gate+commit weld — the 4th-recurrence shape, verbatim from the field
run 'bash test/run.sh > /tmp/g.log 2>&1; rc=$?; echo "rc=$rc"; git -C /x add -A && git -C /x commit -m m'
chk_eq "gate;...;commit weld denied" 2 "$RC"; chk_contains "10b names the break" "no longer depends" "$ERR"
run 'bash test/run.sh && git -C /x commit -m m'
chk_eq "direct gate && commit chain allowed (rc-coupled)" 0 "$RC"
run 'git -C /x add test/foo.test.sh; git -C /x commit -m m'
chk_eq "runner as argument + commit allowed" 0 "$RC"
run 'bash test/run.sh > /tmp/g.log 2>&1; echo rc=$?'
chk_eq "gate with ; but no commit allowed" 0 "$RC"

tmpe="$(mktemp)"; out="$(printf 'not json' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "malformed JSON is checker error" 2 "$rc"; chk_contains "malformed JSON marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Bash missing command is checker error" 2 "$rc"; chk_contains "missing command marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":42}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Bash wrong command type is checker error" 2 "$rc"; chk_contains "wrong command type marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "non-applicable Bash event stays allowed" 0 "$rc"; chk_eq "non-applicable Bash event silent" "" "$err"
tmpe="$(mktemp)"; out="$(python3 -c 'import io,re,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}"); re.search=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "internal Bash checker failure exits 2" 2 "$rc"; chk_contains "internal Bash checker failure marker" "CHECKER-ERROR" "$err"

summary
