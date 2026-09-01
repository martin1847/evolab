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
# Rule (16) keeps a per-session tally under AGENT_WATCH_DIR. Point the whole suite at a REGULAR
# FILE: every read/write there fails, so the counter is deterministically silent and cannot
# inject a warn into another rule's expected payload (this file re-hangs `s1`/`mysess` 15 times
# each). That is not a workaround — it IS rule (16)'s contracted broken-meter face, asserted as
# such in the (16) battery, which drives its own real run dirs.
BABYSIT_OFF="$G8ROOT/babysit-meter-is-a-file"; : > "$BABYSIT_OFF"
AGENT_WATCH_DIR="$BABYSIT_OFF"; export AGENT_WATCH_DIR

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
# ── (11) bare `codex exec|e|review`: review dispatch may only go through the lane ──────────
# Field 2026-08-19/20: the lane pinned danger-full-access with no alternative, the review seat
# needed OS read-only, so the orchestrator hand-rolled `codex exec --sandbox read-only` — one
# heredoc-in-the-same-command hang ran 10h21m and one empty `$(cat brief)` burned a round.
run 'codex exec "review the diff"'
chk_eq "bare codex exec denied" 2 "$RC"
chk_contains "deny points at the lane review flag" "--review" "$ERR"
chk_contains "deny carries the doc pointer" "README.md" "$ERR"
run 'codex e "review the diff"'
chk_eq "the 'e' alias is the same call, denied" 2 "$RC"
run 'codex review --base main'
chk_eq "the native review subcommand is denied too" 2 "$RC"
# the field shape verbatim: sandbox flag + heredoc-adjacent prompt plumbing
run 'codex exec --sandbox read-only "$(cat /tmp/brief.md)"'
chk_eq "the hand-rolled read-only form denied" 2 "$RC"
# wrapper chains and path-qualified spellings are command position too (_WRAP8 family)
run 'env FOO=1 codex exec "x"'
chk_eq "env-wrapper codex exec denied" 2 "$RC"
run 'timeout 600 /usr/local/bin/codex review --base main'
chk_eq "timeout + path-qualified codex review denied" 2 "$RC"
run "bash -lc 'codex e \"x\"'"
chk_eq "bash -lc payload codex e denied" 2 "$RC"
run 'cd /wt && codex exec "x"'
chk_eq "cd-chained codex exec denied" 2 "$RC"
# R1 B2: Bash-equivalent spellings. Rule 11 judges the shell EXECUTION face (rule 8's
# normalization: single-token quotes unwrapped, backslash escapes dropped, line continuations
# folded), so an equivalent rewrite is the same command. All four were rc=0 before the fix.
run 'echo skip; "codex" exec "x"'
chk_eq "quoted command word denied" 2 "$RC"
run 'co\de\x review --base main'
chk_eq "backslash-escaped command word denied" 2 "$RC"
run "$(printf 'codex \\\nexec "x"')"
chk_eq "line-continuation split denied" 2 "$RC"
run "bash -lc \$'codex exec \"x\"'"
chk_eq "ANSI-C quoted payload denied" 2 "$RC"
# R1 M1: the subcommand is the first NON-FLAG token after codex's valued flags are consumed —
# a regex with an optional value group backtracked and read a `--profile review` VALUE as the
# review subcommand, denying a legal login. Both directions pinned.
run 'codex --profile review login'
chk_eq "a flag VALUE spelled 'review' does not make login a dispatch" 0 "$RC"
chk_eq "and that allow is silent" "" "$ERR"
run 'codex --profile prod login'
chk_eq "the same login with an unremarkable profile stays allowed" 0 "$RC"
run 'codex --model review login'
chk_eq "same for a --model value spelled review" 0 "$RC"
# a valued flag must not HIDE a real subcommand behind it, in either spelling
run 'codex --profile foo exec "x"'
chk_eq "codex exec behind a valued flag denied" 2 "$RC"
run 'codex --sandbox=read-only exec "x"'
chk_eq "codex exec behind an =-joined flag denied" 2 "$RC"
# a VALUELESS flag must not swallow the subcommand as if it took a value
run 'codex --search exec "x"'
chk_eq "codex exec after a valueless flag denied" 2 "$RC"
# R2 F1: a LEGAL codex call must not shadow an illegal one later in the same chain. The token
# walk used to return on the first invocation it resolved, so `codex login; codex exec "x"` went
# through — and rule 11 was not the enforcement layer it claims to be. Every invocation in the
# chain is judged now; a legal subcommand ends its own invocation, never the scan.
run 'codex login; codex exec "x"'
chk_eq "a legal codex call does not shadow a later exec (;)" 2 "$RC"
chk_contains "and the deny is still rule 11's" "--review" "$ERR"
run 'codex login && codex exec "x"'
chk_eq "same for && " 2 "$RC"
run 'codex --version; codex e "x"'
chk_eq "same when the shadowing call is flags-only" 2 "$RC"
run 'codex login || codex review --base main'
chk_eq "same for ||" 2 "$RC"
run "bash -lc 'codex login; codex exec \"x\"'"
chk_eq "same inside an interpreter payload" 2 "$RC"
# PAIRED GREEN: a chain of only-legal codex calls stays allowed — the fix must not deny by
# "two codex invocations" alone
run 'codex login; codex --version'
chk_eq "a chain of legal codex calls stays allowed" 0 "$RC"
chk_eq "and stays silent" "" "$ERR"
run 'codex login && codex app-server'
chk_eq "legal chain ending in app-server allowed" 0 "$RC"
# THE PLACEMENT PROOF: rule (3)'s branch ends in an unconditional `return 0`, so a bare codex
# call chained after a legal dispatch is invisible to anything ordered below it. This case is
# red if rule (11) ever moves under the dispatch reminder.
run 'bash references/agentctl/agentctl start codex s1 /wt --goal /tmp/g.md; codex exec "review"'
chk_eq "bare codex chained after a legal dispatch denied (early-return bypass)" 2 "$RC"
# ALLOW: the lane itself, and every codex spelling that is not a headless dispatch
run 'bash references/agentctl/agentctl start codex s1 /wt --goal /tmp/g.md --review --workflow review-loop --max-rounds 2'
chk_eq "the lane review dispatch is allowed" 0 "$RC"
chk_contains "and still gets the watcher reminder" "watcher" "$(ctx "$OUT")"
run 'codex --version'
chk_eq "codex --version allowed" 0 "$RC"; chk_eq "codex --version silent" "" "$ERR"
run 'codex login'
chk_eq "codex login allowed" 0 "$RC"
run 'codex --help'
chk_eq "codex --help allowed" 0 "$RC"
# `exec-server` shares a prefix with `exec`: a bare \b would have matched straight through it
run 'codex exec-server --port 1234'
chk_eq "codex exec-server allowed (prefix trap)" 0 "$RC"
run 'codex app-server'
chk_eq "codex app-server allowed (this is what the lane launches)" 0 "$RC"
# quoted spans are data, and a path as an ARGUMENT is not an invocation
run 'echo "codex exec is denied now"'
chk_eq "quoted mention of the guarded command allowed" 0 "$RC"
run 'grep -rn "codex exec" skills/'
chk_eq "grepping for the guarded command allowed" 0 "$RC"

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
# R2 F2 — BACKSLASH PARITY, a regression this normalization introduced and a four-way control.
# Only an ODD run of backslashes continues a line. Folding unconditionally spliced the two lines
# of `echo ready \\<newline>git status` — where the pair is a literal backslash ARGUMENT and the
# newline really does end the command — so rule 8 stopped seeing the unanchored `git` on line 2
# and went fail-open (rc=2 at e3a4bd7, rc=0 after the naive fold). All four must hold together:
# fixing parity by dropping the fold would flip the second case back to rc=0.
run "$(printf 'echo ready \\\\\ngit status')"
chk_eq "F2 even backslashes are NOT a continuation: line 2 is a new unanchored git" 2 "$RC"
run "$(printf 'git \\\nstatus')"
chk_eq "F2 odd backslash IS a continuation (folded, still one command)" 2 "$RC"
run "$(printf 'echo ready\ngit status')"
chk_eq "F2 a plain newline is a new command" 2 "$RC"
run "$(printf 'git -C /abs \\\nstatus')"
chk_eq "F2 a folded continuation stays ANCHORED (allowed)" 0 "$RC"
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
# review 2026-08-17 repros: bound sequence, not global existence (B2) + wrapper forms (B3)
run 'echo ready; bash test/run.sh && git -C /x commit -m m'
chk_eq "leading ; then rc-coupled chain allowed" 0 "$RC"
run 'bash test/run.sh && git -C /x commit -m m; echo done'
chk_eq "trailing ; after rc-coupled chain allowed" 0 "$RC"
run "$(printf 'echo ready\nbash test/run.sh && git -C /x commit -m m')"
chk_eq "newline before rc-coupled chain allowed" 0 "$RC"
run 'env CI=1 bash test/run.sh; git -C /x commit -m m'
chk_eq "env-assignment wrapper weld denied" 2 "$RC"
run 'bash -e test/run.sh; git -C /x commit -m m'
chk_eq "interpreter-flag wrapper weld denied" 2 "$RC"
run 'command -- bash test/run.sh; git -C /x commit -m m'
chk_eq "command -- wrapper weld denied" 2 "$RC"
# extraction side-effect, declared: rule 10's wrapper list was the only one of the three
# missing `timeout`, so the unified set closes that hole in 10 as well as arming 12
run 'timeout 600 bash test/run.sh | tail -3'
chk_eq "timeout-wrapped gate pipe denied (wrapper set unified on extraction)" 2 "$RC"
run 'timeout 600 agentctl watch s1 | tail -3' 1
chk_eq "timeout-wrapped typed pipe denied" 2 "$RC"

# ── (12) typed-command stdout piped: verdict rc masked + state frame truncated ────────────
# `agentctl watch|steer|start|stop` and `gh pr checks --watch` / `gh run watch` carry their
# verdict in the exit code; a pipeline's rc is the LAST command's. Same disease as (10), and
# deliberately the same parse face (`_pipe_view` + `_pos_head`), one separator apart.
run 'agentctl watch s1 | tail -3' 1
chk_eq "watch|tail denied" 2 "$RC"; chk_contains "12 names the masked verdict" "EXIT CODE" "$ERR"
chk_contains "12 teaches the file-first shape" "rc=\$?" "$ERR"
run 'agentctl steer s1 -m fix | tee /tmp/o.log'
chk_eq "steer|tee denied" 2 "$RC"
run 'agentctl stop s1 | cat'
chk_eq "stop|cat denied" 2 "$RC"
# rule (3)'s branch ends in an unconditional `return 0` — this is red if (12) ever moves below it
run 'agentctl start omp s1 /wt --goal /tmp/g.md | tee /tmp/o.log'
chk_eq "start|tee denied (early-return placement proof)" 2 "$RC"
run 'gh pr checks 12 --watch | tail -1'
chk_eq "gh pr checks --watch piped denied" 2 "$RC"
run 'gh run watch 99 | cat'
chk_eq "gh run watch piped denied" 2 "$RC"
# MID-pipeline: stdout is still consumed, and this is the position rule 10's anchor cannot see
run 'date | agentctl steer s1 -m fix | tee /tmp/o.log'
chk_eq "typed command mid-pipeline denied" 2 "$RC"
run 'echo x | gh run watch 99 | cat'
chk_eq "gh run watch mid-pipeline denied" 2 "$RC"
# wrapper / path-qualified / env-prefix spellings reach the same binary
run 'command agentctl watch s1 | tail -3' 1
chk_eq "command-wrapper typed pipe denied" 2 "$RC"
run '/usr/bin/env FOO=1 agentctl stop s1 | cat'
chk_eq "path-qualified env wrapper typed pipe denied" 2 "$RC"
run '/opt/bin/agentctl watch s1 | tail -3' 1
chk_eq "absolute-path binary typed pipe denied" 2 "$RC"
run 'FOO=1 agentctl watch s1 | tail -3' 1
chk_eq "env-assignment prefix typed pipe denied" 2 "$RC"
# a backslash continuation is REMOVED by the shell before it parses: one pipeline, not two lines
run "$(printf 'agentctl watch s1 \\\n| tail -3')" 1
chk_eq "backslash continuation spells one pipeline, denied" 2 "$RC"
# ALLOW: the shapes that are not a consumed stdout
run 'agentctl watch s1 || echo lost' 1
chk_eq "|| is a chain, not a pipe" 0 "$RC"; chk_eq "|| chain silent" "" "$ERR"
run 'echo brief | agentctl steer s1 -f -'
chk_eq "typed command LAST in pipeline (its STDIN is fed) allowed" 0 "$RC"
run 'agentctl watch s1 > /tmp/w.log 2>&1' 1
chk_eq "file-first typed shape allowed" 0 "$RC"; chk_eq "file-first typed shape silent" "" "$ERR"
run 'echo "agentctl watch s1 | tail -3"'
chk_eq "quoted literal is DATA" 0 "$RC"
run 'echo ok; # agentctl watch s1 | tail -3'
chk_eq "a comment is not command position" 0 "$RC"
run 'grep -n watch references/agentctl/agentctl | head -5'
chk_eq "agentctl path as grep ARGUMENT allowed" 0 "$RC"
run 'gh pr checks 12 | tail -1'
chk_eq "gh pr checks WITHOUT --watch is out of scope" 0 "$RC"
# negative control: the same text inside a stripped quoted-heredoc body is data, not a command
typed_heredoc="$(printf '%s\n' "cat <<'EOF'" 'agentctl watch s1 | tail -3' 'EOF')"
run "$typed_heredoc"
chk_eq "stripped quoted-heredoc body is DATA" 0 "$RC"
# and a plain newline ENDS the command — `| tail` on line 2 is a shell syntax error, not a pipe
run "$(printf 'agentctl watch s1\n| tail -3')" 1
chk_eq "plain newline is not a continuation (control for the backslash case)" 0 "$RC"
# parse failure must NOT silently pass: an exception inside the shared pipeline view reaches
# the top-level wrapper as CHECKER-ERROR. Targeted — only _pipe_view uses this sub() pattern.
tmpe="$(mktemp)"; out12="$(python3 -c 'import io,re,runpy,sys
sys.stdin=io.StringIO(sys.argv[2])
_sub=re.sub
re.sub=lambda p,*a,**k: (_ for _ in ()).throw(RuntimeError("boom")) if p==r"\d*>&\d*" else _sub(p,*a,**k)
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" "$(mkcmd 'agentctl watch s1 | tail -3' 1)" 2>"$tmpe")"; rc12=$?; err12="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "a broken pipeline view is a CHECKER-ERROR, not a silent pass" 2 "$rc12"
chk_contains "rule 12 parse failure marker" "CHECKER-ERROR" "$err12"

# ── (13) codex brief wording advisory: WARN-only, bounded read, never blocks ──────────────
# Word list = literal phrases from the four cyberPolicy-blocked review dispatches (n=4).
B13="$G8ROOT/briefs"; mkdir -p "$B13"
printf '%s\n' '目标：核对 rc 直读。注意评审席不要拿 forged 身份去 bypass 门禁。' > "$B13/dirty.md"
printf '%s\n' 'Goal: verify rc is read directly; report findings as file:line.' > "$B13/clean.md"
D13="agentctl start codex s1 /wt --goal"
# the `--review` tail of every fixture below carries the round budget rule (17) requires: these
# cases are about the BRIEF, and an unbudgeted review dispatch would be denied before rule (13)
# ever reads one (asserted in the (17) battery at the end of this file).
W13="--workflow review-loop --max-rounds 2 && agentctl watch s1"
run "$D13 $B13/dirty.md --review $W13" 1
chk_eq "dirty brief still exits 0 (advisory, never a DENY)" 0 "$RC"
chk_eq "advisory writes nothing to stderr" "" "$ERR"
chk_contains "dirty brief warns" "WARN (cto-guard 13)" "$(ctx "$OUT")"
chk_contains "warn names the matched wording" "forged" "$(ctx "$OUT")"
chk_contains "warn names every match, not just the first" "bypass" "$(ctx "$OUT")"
chk_contains "warn points at neutral review-dispatch wording" "DISPATCH" "$(ctx "$OUT")"
chk_contains "warn points at moving detail into the read file" "INTO the file" "$(ctx "$OUT")"
run "$D13 $B13/clean.md --review $W13" 1
chk_eq "clean brief exits 0" 0 "$RC"; chk_eq "clean brief emits nothing" "" "$OUT"
chk_eq "clean brief no stderr" "" "$ERR"
# CJK term (no word boundaries exist) is a substring match
printf '%s\n' '这一轮请顺手验证一下能不能绕过 pre-push 钩子。' > "$B13/cjk.md"
run "$D13 $B13/cjk.md --review $W13" 1
chk_contains "CJK term matches as a substring" "绕过" "$(ctx "$OUT")"
# the whole list ships tested: a typo in an unexercised term would be a silent dead entry
printf '%s\n' 'Send an impostor stamp plus the ATTACK   PAYLOAD, then 失败探针复跑 一轮。' > "$B13/rest.md"
run "$D13 $B13/rest.md --review $W13" 1
chk_contains "remaining term: impostor" "impostor" "$(ctx "$OUT")"
chk_contains "remaining term: attack payload, case- and whitespace-insensitive" "attack   payload" "$(ctx "$OUT")"
chk_contains "remaining term: the full CJK probe phrase" "失败探针复跑" "$(ctx "$OUT")"
# CALIBRATION, not defects: the list is literal + whole-word, so inflections and synonyms miss
printf '%s\n' 'The 2019 gate was bypassed once; probe the new one and report.' > "$B13/inflected.md"
run "$D13 $B13/inflected.md --review $W13" 1
chk_eq "whole-word: 'bypassed'/'probe' do not fire (declared FN, calibration)" "" "$OUT"
printf '%s\n' 'Check whether a spoofed identity can circumvent the guard; 试着规避一下。' > "$B13/synonym.md"
run "$D13 $B13/synonym.md --review $W13" 1
chk_eq "synonym rewrite is a KNOWN miss (literal list, not a semantic detector)" "" "$OUT"
# I/O boundary: every failure is a `not inspected` note at exit 0
run "$D13 $B13/nope.md --review $W13" 1
chk_eq "missing brief exits 0" 0 "$RC"
chk_contains "missing brief reported" "not inspected (missing)" "$(ctx "$OUT")"
ln -sf "$B13/dirty.md" "$B13/link.md"
run "$D13 $B13/link.md --review $W13" 1
chk_eq "symlinked brief exits 0" 0 "$RC"
chk_contains "symlink is reported, not followed" "not inspected (symlink)" "$(ctx "$OUT")"
run "$D13 $B13 --review $W13" 1
chk_contains "a directory is not a brief" "not inspected (not a regular file)" "$(ctx "$OUT")"
python3 -c 'import sys; open(sys.argv[1],"w").write("bypass "*40000)' "$B13/huge.md"
run "$D13 $B13/huge.md --review $W13" 1
chk_contains "oversize brief is bounded, not read" "not inspected (larger than 256KB)" "$(ctx "$OUT")"
printf 'bypass \377\376 not utf8\n' > "$B13/binary.md"
run "$D13 $B13/binary.md --review $W13" 1
chk_contains "undecodable brief reported" "not inspected (not UTF-8)" "$(ctx "$OUT")"
run "$D13 \"\$BRIEF\" --review $W13" 1
chk_contains "an expansion in the path is an admitted UNKNOWN" "not inspected (unparseable path)" "$(ctx "$OUT")"
# path fidelity: the raw text is the source, so a quoted path with a space survives (the
# normalized pipeline view would have blanked it to ARG — that is why rule 13 does not use it)
mkdir -p "$G8ROOT/br iefs"; cp "$B13/dirty.md" "$G8ROOT/br iefs/b.md"
run "$D13 '$G8ROOT/br iefs/b.md' --review $W13" 1
chk_contains "quoted path containing a space is read" "forged" "$(ctx "$OUT")"
run "$D13=$B13/dirty.md --review $W13" 1
chk_contains "--goal=<f> joined form is the same dispatch" "forged" "$(ctx "$OUT")"
cp "$B13/dirty.md" "$ISO_REPO/brief.md"
run "$D13 brief.md --review $W13" 1
chk_contains "relative path resolves against the payload cwd" "forged" "$(ctx "$OUT")"
# declared boundary: only the FIRST start-codex form in a command is inspected
run "$D13 $B13/clean.md --review $W13; agentctl start codex s2 /wt --goal $B13/dirty.md --review --workflow review-loop --max-rounds 2 && agentctl watch s2" 1
chk_eq "only the FIRST start codex is inspected (declared boundary)" "" "$OUT"
# scope: not a codex dispatch, and not a dispatch at all
run "agentctl start omp s1 /wt --goal $B13/dirty.md $W13" 1
chk_eq "rule 13 is codex-only (an omp brief is not read)" "" "$OUT"
run "cat $B13/dirty.md"
chk_eq "reading the brief is not a dispatch" "" "$OUT"
# the WARN rides rule (3)'s channel: ONE hook response carrying both notes
run "$D13 $B13/dirty.md --review --workflow review-loop --max-rounds 2"
chk_eq "unwatched dirty dispatch exits 0" 0 "$RC"
chk_contains "watcher reminder still delivered" "watcher" "$(ctx "$OUT")"
chk_contains "and the wording WARN rides the same channel" "WARN (cto-guard 13)" "$(ctx "$OUT")"
chk_eq "exactly one JSON hook response on stdout" 1 "$(printf '%s' "$OUT" | grep -c hookSpecificOutput)"
# rule 12 outranks the advisory when both apply
run "$D13 $B13/dirty.md --review | tee /tmp/o.log"
chk_eq "a piped dispatch is denied by (12), advisory does not soften it" 2 "$RC"
# THE ADVISORY CONTRACT: an exception inside rule 13 must NOT reach the top-level wrapper,
# which would turn exit 0 + WARN into exit 2 + DENY of a legal dispatch (review R1 finding-5).
tmpe="$(mktemp)"; out13="$(python3 -c 'import io,os,runpy,sys
sys.stdin=io.StringIO(sys.argv[2])
os.lstat=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom"))
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" "$(mkcmd "$D13 $B13/dirty.md --review $W13" 1)" 2>"$tmpe")"; rc13=$?; err13="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "an exception inside rule 13 stays exit 0" 0 "$rc13"
chk_eq "and never emits a CHECKER-ERROR" "" "$err13"
chk_contains "it degrades to not inspected" "not inspected (unreadable)" "$(ctx "$out13")"

# ── impl review R1 (codex) — every reproduction verbatim, red-then-green ──────────────────
# B1: rule 8 REQUIRES -R/--repo for gh in a multi-repo umbrella, so the repository-qualified
# spelling is the only legal one there — and it must still reach rule 12.
run 'gh -R owner/repo pr checks 12 --watch | tail -1' 1
chk_eq "R1-B1 gh -R … pr checks --watch piped denied" 2 "$RC"
chk_contains "R1-B1 and it is rule 12's verdict" "EXIT CODE" "$ERR"
run 'gh -R owner/repo run watch 99 | cat' 1
chk_eq "R1-B1 gh -R … run watch piped denied" 2 "$RC"
run '/opt/bin/gh -R owner/repo pr checks 12 --watch | tail -1' 1
chk_eq "R1-B1 path-qualified gh with -R denied" 2 "$RC"
run 'gh --repo owner/repo pr checks 12 --watch | tail -1' 1
chk_eq "R1-B1 --repo spelling denied too" 2 "$RC"
# PAIRED GREEN: the global-flag window is bounded and does not turn gh into a wildcard
run 'gh -R owner/repo pr list | tail -1'
chk_eq "R1-B1 an unrelated gh subcommand behind -R stays allowed" 0 "$RC"

# B2: an env VALUE with spaces is a blanked ARG in the shared view; the anchor must survive it.
run 'FOO="a b" agentctl stop s1 | cat'
chk_eq "R1-B2 quoted env value keeps the env prefix anchored" 2 "$RC"
run 'env FOO="a b" agentctl stop s1 | cat'
chk_eq "R1-B2 same through an env wrapper" 2 "$RC"
run 'A=one B="two words" /opt/bin/agentctl start omp s1 /wt | tee /tmp/o'
chk_eq "R1-B2 mixed plain+quoted assignments on a path-qualified binary" 2 "$RC"
chk_contains "R1-B2 and rule 12 answers, not rule 3's reminder" "EXIT CODE" "$ERR"

# M1: `timeout`'s ordinary duration syntax, not just an integer.
run 'timeout 5s agentctl stop s1 | cat'
chk_eq "R1-M1 timeout 5s wrapper denied" 2 "$RC"
run 'timeout 0.5 agentctl stop s1 | cat'
chk_eq "R1-M1 fractional duration denied" 2 "$RC"
run 'timeout 5s bash test/run.sh | tail -1'
chk_eq "R1-M1 rule 10 gets the same duration coverage" 2 "$RC"
chk_contains "R1-M1 and that one is rule 10's verdict" "exit code is the LAST" "$ERR"

# M2: a backslash-escaped `|` is argv DATA and a `#` comment's `|` is prose — neither is a pipe.
run 'agentctl stop s1 \| cat'
chk_eq "R1-M2 escaped pipe is argv data, allowed" 0 "$RC"; chk_eq "R1-M2 and silent" "" "$ERR"
m2b="agentctl stop s1 '# audit' \\| cat"
run "$m2b"
chk_eq "R1-M2 quoted hash plus escaped pipe allowed" 0 "$RC"
run 'agentctl stop s1 # note | cat'
chk_eq "R1-M2 a trailing comment's pipe is prose, allowed" 0 "$RC"
# PAIRED RED-SIDE: the real operators must still bite, and `\\|` IS a real pipe (literal
# backslash argument + pipe), which is why the escape parking is parity-aware.
run 'agentctl stop s1 | cat'
chk_eq "R1-M2 an unescaped pipe is still denied" 2 "$RC"
run 'agentctl stop s1 \\| cat'
chk_eq "R1-M2 a literal-backslash argument does not shield the pipe" 2 "$RC"
run 'echo "a#b" ; agentctl watch s1 | tail -3' 1
chk_eq "R1-M2 a hash inside a token is not a comment" 2 "$RC"

# M3: binary identity is a basename, not a suffix.
run 'fakeagentctl stop s1 | cat'
chk_eq "R1-M3 fakeagentctl is a different program, allowed" 0 "$RC"
chk_eq "R1-M3 and silent" "" "$ERR"
run '/opt/bin/agentctl stop s1 | cat'
chk_eq "R1-M3 PAIRED RED-SIDE: the real binary at a path still denied" 2 "$RC"

# M4: `--watch` is a boolean flag; only bare / =true is watch mode.
run 'gh pr checks 12 --watch=false | tail -1'
chk_eq "R1-M4 --watch=false is not watch mode, allowed" 0 "$RC"
run 'gh pr checks 12 --watch=bogus | tail -1'
chk_eq "R1-M4 a non-boolean value is not watch mode either" 0 "$RC"
run 'gh pr checks 12 --watch=true | tail -1'
chk_eq "R1-M4 PAIRED RED-SIDE: --watch=true is watch mode, denied" 2 "$RC"

# M5: `|&` is bash's pipe-with-stderr operator. Denying it as backgrounding sent the operator
# to run_in_background — straight into the next denial — instead of the file-first fix.
run 'agentctl stop s1 |& cat'
chk_eq "R1-M5 |& piped typed command denied" 2 "$RC"
chk_contains "R1-M5 with rule 12's file-first fix" "read rc directly" "$ERR"
chk_eq "R1-M5 and NOT rule 1's orphan wording" 0 "$(printf '%s' "$ERR" | grep -c ORPHAN)"
run 'printf x | agentctl steer s1 -f - |& cat'
chk_eq "R1-M5 same mid-pipeline" 2 "$RC"
chk_eq "R1-M5 mid-pipeline is also not an orphan" 0 "$(printf '%s' "$ERR" | grep -c ORPHAN)"
run 'bash test/run.sh |& tail -3'
chk_eq "R1-M5 a gate behind |& reaches rule 10, not rule 1" 2 "$RC"
chk_contains "R1-M5 and gets rule 10's wording" "exit code is the LAST" "$ERR"
run 'npm run dev &'
chk_eq "R1-M5 PAIRED GREEN-SIDE: a real trailing & is still an ORPHAN" 2 "$RC"
chk_contains "R1-M5 rule 1 keeps its own shape" "ORPHAN" "$ERR"

# M7: a glob/brace/tilde token makes the shell open a DIFFERENT file than the text names.
printf '%s\n' 'forged stamp here' > "$B13/a[1].md"
printf '%s\n' 'clean brief, nothing to see' > "$B13/a1.md"
run "$D13 $B13/a[1].md --review $W13" 1
chk_eq "R1-M7 glob path exits 0" 0 "$RC"
chk_contains "R1-M7 glob path is an admitted UNKNOWN, not a literal read" \
  "not inspected (unparseable path)" "$(ctx "$OUT")"
chk_eq "R1-M7 and the literal file's wording never leaks" 0 "$(printf '%s' "$(ctx "$OUT")" | grep -c forged)"
run "$D13 $B13/{a,b}.md --review $W13" 1
chk_contains "R1-M7 brace expansion is UNKNOWN too" "unparseable path" "$(ctx "$OUT")"
run "$D13 ~/brief.md --review $W13" 1
chk_contains "R1-M7 tilde expansion is UNKNOWN too" "unparseable path" "$(ctx "$OUT")"
# PAIRED GREEN: metacharacters are only ambiguous UNQUOTED. Inside single quotes the shell hands
# the binary exactly those bytes, so the same brace text is a plain filename and is read.
printf '%s\n' 'forged, and literally named {a,b}.md' > "$B13/{a,b}.md"
run "$D13 '$B13/{a,b}.md' --review $W13" 1
chk_contains "R1-M7 a SINGLE-QUOTED brace is a literal filename, read normally" "forged" "$(ctx "$OUT")"
# PAIRED GREEN: ordinary filename punctuation is extracted, not rejected
cp "$B13/dirty.md" "$B13/re-view_2.0+draft@x%y=z:1.md"
run "$D13 '$B13/re-view_2.0+draft@x%y=z:1.md' --review $W13" 1
chk_contains "R1-M7 ordinary punctuation still extracts and reads" "forged" "$(ctx "$OUT")"

# m1: quoted data is not a dispatch — the advisory must not narrate a command nobody runs.
# SCOPE, stated: rule (3)'s watcher reminder still fires on quoted text. That is pre-existing
# behaviour of rule 3's own `cmd` match, outside this batch, and the reviewer bracketed it the
# same way; the assertion below is on rule 13's output only.
run "echo 'note; $D13 $B13/dirty.md --review'"
chk_eq "R1-m1 quoted dispatch text exits 0" 0 "$RC"
chk_eq "R1-m1 and produces no rule-13 advisory" 0 \
  "$(printf '%s' "$(ctx "$OUT")" | grep -c 'cto-guard 13')"

# m2: the size verdict comes from the bytes READ, not from the lstat snapshot. The liar returns
# st_size=1 for the 280000-byte dirty brief, so a stat-trusting guard would emit the wording WARN.
tmpe="$(mktemp)"; outm2="$(python3 -c 'import io,os,runpy,sys
sys.stdin=io.StringIO(sys.argv[2])
_lstat = os.lstat
def _liar(p):
    t = list(_lstat(p)[:10]); t[6] = 1; return os.stat_result(tuple(t))
os.lstat = _liar
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" "$(mkcmd "$D13 $B13/huge.md --review $W13" 1)" 2>"$tmpe")"; rcm2=$?; errm2="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "R1-m2 a lying stat still exits 0" 0 "$rcm2"
chk_eq "R1-m2 and emits no CHECKER-ERROR" "" "$errm2"
chk_contains "R1-m2 the bounded read owns the verdict" \
  "not inspected (larger than 256KB)" "$(ctx "$outm2")"
chk_eq "R1-m2 and no wording from the oversize file leaks" 0 \
  "$(printf '%s' "$(ctx "$outm2")" | grep -c bypass)"

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
# ── (14)/(15) dispatch preconditions on the `<cwd>` positional of `agentctl start` ─────────
# (15) untracked BLOCKED.md left by the previous seat; (14) a dirty worktree at dispatch time.
# Both judged on the SAME parse rule (3) uses, and both DENY before any hook response is
# printed. The order between them is asserted below: a surviving BLOCKED.md is itself untracked,
# so if (14) answered first the fix line would tell the orchestrator to COMMIT the previous
# seat's held gate instead of harvesting it.
SD="$G8ROOT/seed"; mkdir -p "$SD/wt"
git -C "$SD/wt" init -q
printf 'x\n' > "$SD/wt/tracked.txt"
git -C "$SD/wt" add -A >/dev/null 2>&1
git -C "$SD/wt" -c user.email=t@t -c user.name=t commit -q -m seed >/dev/null 2>&1
DSP="bash references/agentctl/agentctl start omp seedsess"

# clean tree, no BLOCKED.md: the dispatch is legal and only the watcher reminder speaks
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "clean worktree dispatch allowed" 0 "$RC"; chk_eq "clean dispatch silent on stderr" "" "$ERR"
chk_contains "clean dispatch still gets the watcher reminder" "watcher" "$(ctx "$OUT")"

# (14) untracked seed file = dirty
printf 'brief\n' > "$SD/wt/GOAL.md"
run "$DSP $SD/wt --goal $SD/wt/GOAL.md"
chk_eq "dirty worktree dispatch denied" 2 "$RC"
chk_contains "14 names the disease" "播种未 seed commit" "$ERR"
chk_contains "14 gives the commit-first正路" "commit -m 'seed:" "$ERR"
chk_contains "14 carries the doc pointer" "dispatch-baseline.md" "$ERR"
chk_eq "14 prints no hook response alongside the deny" "" "$OUT"
# a tracked-but-modified file is the same disease
git -C "$SD/wt" add -A >/dev/null 2>&1
git -C "$SD/wt" -c user.email=t@t -c user.name=t commit -q -m seed2 >/dev/null 2>&1
run "$DSP $SD/wt --goal $SD/wt/GOAL.md"
chk_eq "committed seed makes the same dispatch legal" 0 "$RC"
printf 'edited\n' >> "$SD/wt/tracked.txt"
run "$DSP $SD/wt --goal $SD/wt/GOAL.md"
chk_eq "an uncommitted modification is dirty too" 2 "$RC"
git -C "$SD/wt" checkout -q -- tracked.txt

# (15) BLOCKED.md, first while UNTRACKED (both rules apply) — the order proof
printf 'held gate\n' > "$SD/wt/BLOCKED.md"
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "surviving BLOCKED.md denied" 2 "$RC"
chk_contains "15 answers first, not 14" "前席 BLOCKED 未收割" "$ERR"
chk_eq "and 14's wording never appears" 0 "$(printf '%s' "$ERR" | grep -c 'seed commit')"
chk_contains "15 tells the seat to harvest, not to commit" "rm $SD/wt/BLOCKED.md" "$ERR"
chk_contains "15 carries the doc pointer" "dispatch-baseline.md" "$ERR"
# and a COMMITTED BLOCKED.md (clean tree) is still an unharvested gate
git -C "$SD/wt" add -A >/dev/null 2>&1
git -C "$SD/wt" -c user.email=t@t -c user.name=t commit -q -m blocked >/dev/null 2>&1
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "committed BLOCKED.md still denied (clean tree)" 2 "$RC"
chk_contains "still 15's verdict" "前席 BLOCKED" "$ERR"
git -C "$SD/wt" rm -q BLOCKED.md >/dev/null 2>&1
git -C "$SD/wt" -c user.email=t@t -c user.name=t commit -q -m harvest >/dev/null 2>&1
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "harvested + committed is legal again" 0 "$RC"

# a directory git does not own is NOT judged (14 skips; 15 needs no repo)
mkdir -p "$G8ROOT/nogit"
run "$DSP $G8ROOT/nogit --goal /tmp/g.md"
chk_eq "non-git cwd is not judged by 14" 0 "$RC"; chk_eq "and stays silent on stderr" "" "$ERR"
printf 'held\n' > "$G8ROOT/nogit/BLOCKED.md"
run "$DSP $G8ROOT/nogit --goal /tmp/g.md"
chk_eq "15 needs no repo — BLOCKED.md in a plain dir still denied" 2 "$RC"
rm -f "$G8ROOT/nogit/BLOCKED.md"
run "$DSP $G8ROOT/missing-entirely --goal /tmp/g.md"
chk_eq "a nonexistent cwd is not judged" 0 "$RC"

# the cwd positional: relative resolves against the payload cwd, quoted spaces survive, and any
# expansion / glob is an admitted UNKNOWN (same discipline as rule 13's `--goal` extraction)
GUARD_CWD="$SD"
printf 'dirty\n' > "$SD/wt/loose.txt"
run "$DSP wt --goal /tmp/g.md"
chk_eq "a RELATIVE cwd resolves against the payload cwd" 2 "$RC"
chk_contains "and it is 14's verdict" "播种未 seed commit" "$ERR"
mkdir -p "$SD/wt space"; git -C "$SD/wt space" init -q; printf 'x\n' > "$SD/wt space/loose.txt"
run "$DSP '$SD/wt space' --goal /tmp/g.md"
chk_eq "a quoted cwd containing a space is judged" 2 "$RC"
run "$DSP \"\$WT\" --goal /tmp/g.md"
chk_eq "an expansion in the cwd is an admitted UNKNOWN (not judged)" 0 "$RC"
run "$DSP $SD/w? --goal /tmp/g.md"
chk_eq "a glob in the cwd is an admitted UNKNOWN too" 0 "$RC"
run "bash references/agentctl/agentctl start omp seedsess"
chk_eq "a dispatch with no cwd positional is not judged" 0 "$RC"
chk_contains "and still gets the reminder" "watcher" "$(ctx "$OUT")"
# a flag before the positional must not be eaten as the cwd
run "$DSP --review $SD/wt --goal /tmp/g.md"
chk_eq "leading flags are skipped, the positional is still found" 2 "$RC"
chk_contains "and judged as 14" "播种未 seed commit" "$ERR"
# DENY outranks the watcher reminder: a dirty dispatch that DOES arm a watcher is still denied
run "$DSP $SD/wt --goal /tmp/g.md && bash references/agentctl/agentctl watch seedsess" 1
chk_eq "a watched dirty dispatch is denied all the same" 2 "$RC"
chk_eq "and prints no JSON alongside" "" "$OUT"
rm -f "$SD/wt/loose.txt"

# ── R2 (cold review §2.1/§2.2) THE PARSE FACE: command position, and EVERY segment ─────────
# R1 reused rule (3)'s unanchored `re.search` and inspected only its FIRST match. Both halves
# were counter-probed: argv DATA was DENIED as if it were a dispatch, and a real LATER dispatch
# was never judged at all. Rule (3)'s permissive matcher stays where it belongs (an over-eager
# REMINDER costs a sentence; an over-eager DENY costs the seat its Bash tool).
printf 'held gate\n' > "$SD/wt/BLOCKED.md"
run "echo agentctl start omp s $SD/wt"
chk_eq "R2-2.1 an echoed dispatch is DATA, not a dispatch" 0 "$RC"
chk_eq "R2-2.1 and no DENY reaches stderr" "" "$ERR"
run "printf %s agentctl start omp s $SD/wt"
chk_eq "R2-2.1 printf argv is DATA too" 0 "$RC"
run "echo 'note; agentctl start omp s $SD/wt'"
chk_eq "R2-2.1 a quoted mention inside an echo is DATA" 0 "$RC"
# PAIRED GREEN->RED: the identical text in command position is still judged
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "R2-2.1 control: the same text in command position is denied" 2 "$RC"
# the SECOND dispatch of a chain is a dispatch
CLEANWT="$SD/clean"; mkdir -p "$CLEANWT"; git -C "$CLEANWT" init -q
git -C "$CLEANWT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
CHAIN2="bash references/agentctl/agentctl start omp s2"
run "$DSP $CLEANWT --goal /tmp/g.md; $CHAIN2 $SD/wt --goal /tmp/g.md"
chk_eq "R2-2.2 a LATER dispatch onto a held BLOCKED.md is judged" 2 "$RC"
chk_contains "R2-2.2 and it is 15's verdict" "前席 BLOCKED 未收割" "$ERR"
chk_eq "R2-2.2 and no hook response rides alongside the deny" "" "$OUT"
rm -f "$SD/wt/BLOCKED.md"
printf 'loose\n' > "$SD/wt/loose.txt"
run "$DSP $CLEANWT --goal /tmp/g.md; $CHAIN2 $SD/wt --goal /tmp/g.md"
chk_eq "R2-2.2 a LATER dispatch onto a dirty worktree is judged" 2 "$RC"
chk_contains "R2-2.2 and it is 14's verdict" "播种未 seed commit" "$ERR"
chk_contains "R2-2.2 the denial names the SECOND cwd, not the first" "$SD/wt" "$ERR"
rm -f "$SD/wt/loose.txt"
run "$DSP $CLEANWT --goal /tmp/g.md; $CHAIN2 $CLEANWT --goal /tmp/g.md"
chk_eq "R2-2.2 control: two clean dispatches stay legal" 0 "$RC"

# ── R2 (cold review §2.3) gate 15 asks EXISTS, not isfile ─────────────────────────────────
# A directory at `<cwd>/BLOCKED.md` wedges the next seat exactly the same way (it still cannot
# create its own file there), and git never reports an empty directory, so (14) does not cover it.
mkdir -p "$SD/wt/BLOCKED.md"
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "R2-2.3 a DIRECTORY at BLOCKED.md is an unharvested gate too" 2 "$RC"
chk_contains "R2-2.3 and 15 answers it" "前席 BLOCKED 未收割" "$ERR"
rmdir "$SD/wt/BLOCKED.md"

# ── R2 (cold review §5.1) the copyable recovery must survive a cwd with a space ────────────
# The parser ADMITS a quoted cwd containing spaces (asserted above), so an unquoted fix line is
# a false promise on an input this gate itself accepts: copying it would split the path.
printf 'loose\n' > "$SD/wt space/loose.txt"
run "$DSP '$SD/wt space' --goal /tmp/g.md"
chk_eq "R2-5.1 a spaced cwd is judged as 14" 2 "$RC"
chk_contains "R2-5.1 14's git commands are shell-quoted" "git -C '$SD/wt space' add -A" "$ERR"
chk_contains "R2-5.1 both of them" "git -C '$SD/wt space' commit -m 'seed:" "$ERR"
printf 'held\n' > "$SD/wt space/BLOCKED.md"
run "$DSP '$SD/wt space' --goal /tmp/g.md"
chk_eq "R2-5.1 and the same cwd is judged as 15 first" 2 "$RC"
chk_contains "R2-5.1 15's rm is shell-quoted" "rm '$SD/wt space/BLOCKED.md'" "$ERR"
rm -f "$SD/wt space/BLOCKED.md"

# ── R2 (cold review §4.2) gate 14's INSTRUMENT: a git that cannot answer must say so ───────
# `_git_porcelain` folded "no git / timeout" into the same verdict as "not a repo" and the caller
# allowed in silence — an unmeasured precondition reading exactly like a met one. Targeted
# mutation of the `git status` call only, so every other rule keeps its real git.
mut14() { # $1 command  $2 python exception expression -> OUT/ERR/RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$1" | python3 -c 'import runpy,subprocess,sys
_run=subprocess.run
def fake(a,**k):
    if list(a)[:1]==["git"] and "status" in list(a): raise eval(sys.argv[2])
    return _run(a,**k)
subprocess.run=fake
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" "$2" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
printf 'loose\n' > "$SD/wt/loose.txt"
run "$DSP $SD/wt --goal /tmp/g.md"
chk_eq "R2-4.2 control: unmutated, this dirty dispatch is denied" 2 "$RC"
mut14 "$DSP $SD/wt --goal /tmp/g.md" 'FileNotFoundError("no git on PATH")'
chk_eq "R2-4.2 a missing git never becomes a DENY (exit 0)" 0 "$RC"
chk_eq "R2-4.2 and writes nothing to stderr" "" "$ERR"
chk_contains "R2-4.2 the unmeasured precondition is ANNOUNCED" "WARN (cto-guard 14)" "$(ctx "$OUT")"
chk_contains "R2-4.2 the warn names the cwd it could not measure" "$SD/wt" "$(ctx "$OUT")"
chk_contains "R2-4.2 and says what went unchecked" "went UNCHECKED" "$(ctx "$OUT")"
mut14 "$DSP $SD/wt --goal /tmp/g.md" 'subprocess.TimeoutExpired("git",10)'
chk_eq "R2-4.2 a git TIMEOUT degrades the same way" 0 "$RC"
chk_contains "R2-4.2 timeout is announced too" "WARN (cto-guard 14)" "$(ctx "$OUT")"
mut14 "$DSP $SD/wt --goal /tmp/g.md" 'OSError("git refused")'
chk_eq "R2-4.2 an OSError from the probe degrades the same way" 0 "$RC"
chk_contains "R2-4.2 and is announced" "WARN (cto-guard 14)" "$(ctx "$OUT")"
# the reminder still rides the SAME hook response — one JSON document, never two
chk_contains "R2-4.2 the watcher reminder still arrives with it" "watcher" "$(ctx "$OUT")"
chk_eq "R2-4.2 and the response is a single JSON document" 1 \
  "$(printf '%s\n' "$OUT" | grep -c hookSpecificOutput)"
rm -f "$SD/wt/loose.txt"

# ── R2 (cold review §4.3) gate 15's INSTRUMENT: the stat probe, mutated on purpose ─────────
# The pre-existing global `re.search` mutation fails BEFORE this rule and proves nothing about
# it. Only `BLOCKED.md` lookups are intercepted; rule 8's `.git` probes keep the real function.
# R3 (verify §4.3) RETARGETED the interception from `os.path.exists` to `os.stat`, because that
# is the call the rule now makes — patching a function the rule no longer calls would leave
# these probes measuring nothing while reporting green. The harness CONTRACT is unchanged: `$2`
# is the BLOCKED.md verdict — truthy = something stands there, falsy = nothing does (raised as
# the real ENOENT the kernel would give), and an expression that RAISES exercises the
# instrument face directly.
mut15() { # $1 command  $2 python expression for the BLOCKED.md verdict -> OUT/ERR/RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$1" | python3 -c 'import os,runpy,sys
_s=os.stat
def fake(p,*a,**k):
    if str(p).endswith("BLOCKED.md"):
        if eval(sys.argv[2]): return _s(sys.argv[1])
        raise FileNotFoundError(2,"No such file or directory",str(p))
    return _s(p,*a,**k)
os.stat=fake
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" "$2" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
mut15 "$DSP $CLEANWT --goal /tmp/g.md" 'True'
chk_eq "R2-4.3 forced True denies a clean cwd — the verdict really comes from this probe" 2 "$RC"
chk_contains "R2-4.3 and it is 15's verdict" "前席 BLOCKED 未收割" "$ERR"
printf 'held\n' > "$SD/wt/BLOCKED.md"
mut15 "$DSP $SD/wt --goal /tmp/g.md" 'False'
chk_not_contains "R2-4.3 forced False loses 15's verdict (the arm is load-bearing)" \
  "前席 BLOCKED" "$ERR"
# R3 (verify §4.3): an OSError from the stat probe is now a CLASSIFIED reading (WARN, asserted
# below), so the "cannot ANSWER" face is exercised with a failure this rule does NOT classify —
# the assertion it carries is unchanged: an unanswerable probe never becomes a silent pass.
mut15 "$DSP $SD/wt --goal /tmp/g.md" '(_ for _ in ()).throw(RuntimeError("stat wedged"))'
chk_eq "R2-4.3 a probe that cannot ANSWER is a CHECKER-ERROR, not a silent pass" 2 "$RC"
chk_contains "R2-4.3 and carries the marker" "CHECKER-ERROR" "$ERR"
rm -f "$SD/wt/BLOCKED.md"

# ── R3 (verify §4.3) gate 15's BROKEN METER: unreadable is not harvested ───────────────────
# `os.path.exists` answers False for "nothing there" AND for "could not look" (it swallows the
# stat error), so a seat whose BLOCKED.md could not be stat'ed — mode 000 parent, dead mount,
# root-owned file under a non-root guard — read exactly like a harvested one and the dispatch
# went through SILENTLY GREEN. Verify probe: `os.stat(<cwd>/BLOCKED.md)` raising PermissionError
# -> rc=0, no warn, no verdict. Same failure shape §4.2 fixed for (14), and the fix is the same:
# a meter that cannot measure is not a green meter. Not a DENY either — this rule stops a
# dispatch onto a HELD gate, not onto an unreadable path.
# PAIRED CONTROL first: the same file, really present, really denies.
printf 'held\n' > "$CLEANWT/BLOCKED.md"
git -C "$CLEANWT" add BLOCKED.md >/dev/null 2>&1
git -C "$CLEANWT" -c user.email=t@t -c user.name=t commit -q -m held >/dev/null 2>&1
run "$DSP $CLEANWT --goal /tmp/g.md"
chk_eq "R3-4.3 control: a real committed BLOCKED.md is denied" 2 "$RC"
mut15 "$DSP $CLEANWT --goal /tmp/g.md" '(_ for _ in ()).throw(PermissionError(13,"Permission denied"))'
chk_eq "R3-4.3 a stat the guard is not allowed to make never becomes a DENY (exit 0)" 0 "$RC"
chk_eq "R3-4.3 and writes nothing to stderr" "" "$ERR"
chk_contains "R3-4.3 the unmeasured precondition is ANNOUNCED" "WARN (cto-guard 15)" "$(ctx "$OUT")"
chk_contains "R3-4.3 the warn names the path it could not measure" "$CLEANWT/BLOCKED.md" "$(ctx "$OUT")"
chk_contains "R3-4.3 and says what went unchecked" "went UNCHECKED" "$(ctx "$OUT")"
chk_not_contains "R3-4.3 and it is not dressed as a verdict" "前席 BLOCKED 未收割" "$(ctx "$OUT")"
chk_eq "R3-4.3 the warn rides ONE hook response, never a second document" 1 \
  "$(printf '%s\n' "$OUT" | grep -c hookSpecificOutput)"
# other OSErrors from the same probe degrade identically — the family, not one errno
mut15 "$DSP $CLEANWT --goal /tmp/g.md" '(_ for _ in ()).throw(OSError(5,"Input/output error"))'
chk_eq "R3-4.3 an EIO probe degrades the same way" 0 "$RC"
chk_contains "R3-4.3 and is announced too" "WARN (cto-guard 15)" "$(ctx "$OUT")"
# ENOENT/ENOTDIR still MEAN absent — the fix must not turn a harvested seat into a warn
mut15 "$DSP $CLEANWT --goal /tmp/g.md" '(_ for _ in ()).throw(NotADirectoryError(20,"Not a directory"))'
chk_eq "R3-4.3 ENOTDIR is ABSENT, not unmeasured (exit 0)" 0 "$RC"
chk_not_contains "R3-4.3 and says nothing about 15" "cto-guard 15" "$(ctx "$OUT")"
# an unmeasured (15) must not swallow (14): the loop degrades this seat and keeps judging
printf 'loose\n' > "$CLEANWT/loose.txt"
mut15 "$DSP $CLEANWT --goal /tmp/g.md" '(_ for _ in ()).throw(PermissionError(13,"Permission denied"))'
chk_eq "R3-4.3 an unmeasured 15 still lets 14 judge the same seat" 2 "$RC"
chk_contains "R3-4.3 and 14's verdict is the one that lands" "播种未 seed commit" "$ERR"
rm -f "$CLEANWT/loose.txt"
git -C "$CLEANWT" rm -q BLOCKED.md >/dev/null 2>&1
git -C "$CLEANWT" -c user.email=t@t -c user.name=t commit -q -m harvest >/dev/null 2>&1

# ── R3 (verify §2.2 / N1) THE PARSE FACE: a quoted env VALUE is not the command ────────────
# `_SEG_HEAD` judged the segment a dispatch on the VIEW (quoted env value = opaque ARG) but
# `_SEG_START` then located the command on the RAW segment, so a decoy inside the env value won
# the first match and the guard judged /tmp/fake instead of the seat actually being started:
# `X="agentctl start omp fake /tmp/fake" agentctl start omp real <dirty>` exited 0 where (14)
# owed a DENY. Both faces now agree on what is data (`_quote_blind`).
DECOY='X="agentctl start omp fake /tmp/fake"'
printf 'loose\n' > "$SD/wt/loose.txt"
run "$DECOY agentctl start omp real $SD/wt"
chk_eq "R3-2.2 a decoy in a quoted env value no longer shadows the real dispatch" 2 "$RC"
chk_contains "R3-2.2 and 14 judges it" "播种未 seed commit" "$ERR"
chk_contains "R3-2.2 the seat judged is the REAL one" "$SD/wt" "$ERR"
chk_not_contains "R3-2.2 not the decoy's path" "/tmp/fake" "$ERR"
rm -f "$SD/wt/loose.txt"
printf 'held\n' > "$SD/wt/BLOCKED.md"
run "$DECOY agentctl start omp real $SD/wt"
chk_eq "R3-2.2 15 reaches the real seat through the same decoy" 2 "$RC"
chk_contains "R3-2.2 and it is 15's verdict" "前席 BLOCKED 未收割" "$ERR"
rm -f "$SD/wt/BLOCKED.md"
# NEGATIVE CONTROL: the same quoted text with no dispatch behind it is still DATA
printf 'loose\n' > "$SD/wt/loose.txt"
run "X=\"agentctl start omp fake $SD/wt\" echo hi"
chk_eq "R3-2.2 a quoted dispatch in front of echo stays DATA (exit 0)" 0 "$RC"
chk_eq "R3-2.2 and no DENY reaches stderr" "" "$ERR"
# the DOCUMENTED positive control stays reachable: a spaced env value before a REAL dispatch
run "FOO=\"a b\" $DSP $SD/wt --goal /tmp/g.md"
chk_eq "R3-2.2 a spaced env value before a real dispatch is still judged" 2 "$RC"
chk_contains "R3-2.2 and 14 owns that verdict" "播种未 seed commit" "$ERR"
# blinding must not eat the QUOTED-cwd extraction: the positional is read off the RAW segment
run "FOO=\"a b\" agentctl start omp s1 \"$SD/wt\""
chk_eq "R3-2.2 a quoted cwd behind a spaced env value is still extracted" 2 "$RC"
chk_contains "R3-2.2 and names that cwd" "$SD/wt" "$ERR"
rm -f "$SD/wt/loose.txt"
GUARD_CWD="$ISO_REPO"

# ── (17) review dispatch with no round budget ──────────────────────────────────────────────
# An unbudgeted review loop is the arms-race shape: `--max-rounds` is the only ceiling the
# runtime enforces, so a review seat started without it has none anywhere. DENY.
REV="bash references/agentctl/agentctl start codex rev $CLEANWT --goal /tmp/g.md"
run "$REV --review"
chk_eq "17 a --review dispatch with no budget is denied" 2 "$RC"
chk_contains "17 the denial names the missing budget" "评审无预算" "$ERR"
chk_contains "17 and hands over the exact replacement" "--workflow review-loop --max-rounds N" "$ERR"
chk_eq "17 no hook response rides alongside the deny" "" "$OUT"
# GREEN: the budgeted spelling is the one the lane accepts (the flag PAIR is required together)
run "$REV --review --workflow review-loop --max-rounds 2"
chk_eq "17 a budgeted review dispatch passes" 0 "$RC"
chk_not_contains "17 and says nothing about the budget" "评审无预算" "$ERR"
# non-review dispatches are none of this rule's business
run "$REV"
chk_eq "17 a non-review codex dispatch passes" 0 "$RC"
run "bash references/agentctl/agentctl start omp rev $CLEANWT --goal /tmp/g.md --review"
chk_eq "17 --review on another engine is not judged here (the lane refuses it itself)" 0 "$RC"
# `--resume-thread` keeps its creation-time tier; the lane refuses the pair, this rule does not
# double-judge it
run "$REV --review --resume-thread th_123"
chk_eq "17 a resumed thread is not judged" 0 "$RC"
# argv DATA is not a dispatch — same command-position discipline as (14)/(15)
run "echo '$REV --review'"
chk_eq "17 a quoted mention is DATA (exit 0)" 0 "$RC"
chk_eq "17 and no DENY reaches stderr" "" "$ERR"
# a path that merely CONTAINS the flag text is not the flag: the scan compares whole tokens
run "bash references/agentctl/agentctl start codex rev $CLEANWT --goal /tmp/--review.md"
chk_eq "17 a --review-shaped path token is not a review dispatch" 0 "$RC"
# the SECOND dispatch of a chain is a dispatch (the rule reads every command-position segment)
run "$REV --review --workflow review-loop --max-rounds 2; bash references/agentctl/agentctl start codex rev2 $CLEANWT --goal /tmp/g.md --review"
chk_eq "17 a LATER unbudgeted review dispatch is judged" 2 "$RC"
# ORDER: a command-text defect is answered before the worktree preconditions (14)/(15)
printf 'loose\n' > "$CLEANWT/loose.txt"
run "$REV --review"
chk_eq "17 a dirty seat plus a missing budget is still denied" 2 "$RC"
chk_contains "17 and the command-text defect answers first" "评审无预算" "$ERR"
chk_not_contains "17 not 14's verdict" "播种未 seed commit" "$ERR"
rm -f "$CLEANWT/loose.txt"
# ── (17) OPTION ARITY (cold review F1, the reviewer's three probes as standing arms) ────────
# A flat membership test over the token list read a VALUED option's argument as a flag, and the
# one root cause faced both ways: a legal dispatch was DENIED and two unbudgeted review loops
# bought their way out with a filename. The scan now mirrors `agentctl start`'s own argv rules
# (agentctl:183-198). The seat is this suite's clean worktree rather than the probe's `/tmp`,
# so the green arm cannot be flipped by a stray `/tmp/BLOCKED.md` on the machine.
ARITY="bash references/agentctl/agentctl start codex rev $CLEANWT"
run "$ARITY --goal '--review'"
chk_eq "17-F1 a flag-shaped --goal VALUE is data, not a review dispatch (exit 0)" 0 "$RC"
chk_eq "17-F1 and no DENY reaches stderr" "" "$ERR"
run "$ARITY --goal '--max-rounds' --review"
chk_eq "17-F1 a --max-rounds-shaped VALUE does not buy a budget" 2 "$RC"
chk_contains "17-F1 and the review is denied for what it is" "评审无预算" "$ERR"
run "$ARITY --goal '--resume-thread' --review"
chk_eq "17-F1 a --resume-thread-shaped VALUE does not buy the resume exemption" 2 "$RC"
chk_contains "17-F1 and that review is denied too" "评审无预算" "$ERR"
# every other valued option consumes its argument the same way — one arm per remaining member
# of the set, so a shrunken `_START_VALUED` cannot pass unnoticed
for opt in --deliverable --workflow --model; do
  run "$ARITY --goal /tmp/g.md $opt '--review'"
  chk_eq "17-F1 $opt's VALUE is data too (exit 0)" 0 "$RC"
done
# PAIRED CONTROL: the same three flags in real OPTION position still decide
run "$ARITY --goal /tmp/g.md --review"
chk_eq "17-F1 control: --review in option position is still judged" 2 "$RC"
run "$ARITY --goal /tmp/g.md --review --workflow review-loop --max-rounds 2"
chk_eq "17-F1 control: --max-rounds in option position is still a budget" 0 "$RC"
run "$ARITY --goal /tmp/g.md --review --resume-thread th_1"
chk_eq "17-F1 control: --resume-thread in option position still exempts" 0 "$RC"
# a budget BEFORE the review flag is the same budget (order is not a rule)
run "$ARITY --workflow review-loop --max-rounds 2 --goal /tmp/g.md --review"
chk_eq "17-F1 a budget declared before --review counts" 0 "$RC"


# ── (16) babysit-round counter ─────────────────────────────────────────────────────────────
# Re-hanging a watcher is LEGAL, so this can never be a DENY; the fourth re-hang of the same
# session in one day is what the orchestrator must see (field: one session re-hung 6 times
# while the gauge, not the agent, was the problem). Each case drives its own run dir.
runbs() { # $1 run-dir  $2 command  [$3 "1" = run_in_background]
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$2" "${3:-}" | AGENT_WATCH_DIR="$1" python3 "$GUARD" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
BS1="$G8ROOT/bs1"; mkdir -p "$BS1"
for i in 1 2 3; do runbs "$BS1" 'agentctl watch g16s' 1; done
chk_eq "16 the third re-hang exits 0" 0 "$RC"
chk_eq "16 and is SILENT (under the threshold)" "" "$OUT"
runbs "$BS1" 'agentctl watch g16s' 1
chk_eq "16 the FOURTH re-hang still exits 0 (never a DENY)" 0 "$RC"
chk_eq "16 and writes nothing to stderr" "" "$ERR"
chk_contains "16 the fourth is announced" "WARN (cto-guard 16)" "$(ctx "$OUT")"
chk_contains "16 the warn names the session" "g16s" "$(ctx "$OUT")"
chk_contains "16 and the count it reached" "4 times today" "$(ctx "$OUT")"
chk_contains "16 and points at the instrument before the re-hang" "INSTRUMENT" "$(ctx "$OUT")"
chk_not_contains "16 the reading is not dressed as undecidable" "不可判" "$(ctx "$OUT")"
# a steer counts the same way, and it keeps counting past the threshold — never escalating
runbs "$BS1" 'agentctl steer g16s -m x' 1
chk_eq "16 a steer on the same session counts too" 0 "$RC"
chk_contains "16 and the tally advanced" "5 times today" "$(ctx "$OUT")"
# an --interrupt steer is a deliberate intervention, not a mechanical re-hang: NOT counted.
# Proved by exhaustion — three of them plus three re-hangs must still read as three.
BS2="$G8ROOT/bs2"; mkdir -p "$BS2"
for i in 1 2 3; do runbs "$BS2" 'agentctl steer g16i -m x --interrupt' 1; done
for i in 1 2; do runbs "$BS2" 'agentctl watch g16i' 1; done
chk_eq "16 interrupt steers are not re-hangs" "" "$OUT"
runbs "$BS2" 'agentctl steer g16i -m x --replace' 1
chk_eq "16 --replace is the same verb under its silent alias" "" "$OUT"
runbs "$BS2" 'agentctl watch g16i' 1
chk_eq "16 the third real re-hang stays silent — interrupts never entered the tally" "" "$OUT"
runbs "$BS2" 'agentctl watch g16i' 1
chk_contains "16 the fourth REAL re-hang is the one that warns" "4 times today" "$(ctx "$OUT")"
# one command, one round: the standard `steer …; watch …` pair is a single babysit round
BS3="$G8ROOT/bs3"; mkdir -p "$BS3"
for i in 1 2 3; do runbs "$BS3" 'agentctl steer g16p -m x > /tmp/o.log; agentctl watch g16p' 1; done
chk_eq "16 three steer+watch pairs are three rounds, not six" "" "$OUT"
runbs "$BS3" 'agentctl steer g16p -m x > /tmp/o.log; agentctl watch g16p' 1
chk_contains "16 the fourth pair warns exactly once" "4 times today" "$(ctx "$OUT")"
chk_eq "16 and the response is a single JSON document" 1 \
  "$(printf '%s\n' "$OUT" | grep -c hookSpecificOutput)"
# argv DATA is not a re-hang
BS4="$G8ROOT/bs4"; mkdir -p "$BS4"
for i in 1 2 3 4 5; do runbs "$BS4" "echo 'agentctl watch g16q'" 1; done
chk_eq "16 a quoted mention never enters the tally" "" "$OUT"
# BROKEN METER: a run dir that cannot be read or written stays SILENT — no warn, no deny.
# This is the fixture the rest of this suite runs on, asserted here so the choice is load-bearing.
for i in 1 2 3 4 5 6; do runbs "$BABYSIT_OFF" 'agentctl watch g16s' 1; done
chk_eq "16 an unreadable meter never accuses (exit 0)" 0 "$RC"
chk_eq "16 and injects nothing at all" "" "$OUT"
chk_eq "16 and writes nothing to stderr" "" "$ERR"
# DEGRADED METER: the tally can be READ but not persisted -> the count is a FLOOR and the warn
# says so, instead of publishing a floor as a measurement.
if [ "$(id -u)" != "0" ]; then
  BS5="$G8ROOT/bs5"; mkdir -p "$BS5"
  printf '{"floor": false, "n": {"g16d": 3}}' > "$BS5/babysit-$(id -u)-$(date +%Y%m%d).json"
  chmod 500 "$BS5"
  runbs "$BS5" 'agentctl watch g16d' 1
  chk_eq "16 an unpersistable bump is not a DENY" 0 "$RC"
  chk_contains "16 the seen count is still reported" "4 times today" "$(ctx "$OUT")"
  chk_contains "16 and is admitted as a floor" "不可判" "$(ctx "$OUT")"
  chmod 700 "$BS5"
else
  echo "  [skip] running as root — the unwritable-run-dir case cannot be built"
fi
# ── (16) STICKY FLOOR (cold review F2, the reviewer's repro as a standing arm) ──────────────
# A corrupt ledger loses the day's history. The process that resets it knew that; the NEXT
# process read a well-formed file and published `4 times today` as an exact reading of a day
# whose start it never saw. The day's record now carries the fact, so the admission survives
# ACROSS PROCESSES — four separate guard invocations here, exactly as the field has them.
BS6="$G8ROOT/bs6"; mkdir -p "$BS6"
printf '{bad json' > "$BS6/babysit-$(id -u)-$(date +%Y%m%d).json"
for i in 1 2 3 4; do
  runbs "$BS6" 'agentctl watch g16corrupt' 1
  chk_eq "16-F2 call $i on a corrupt ledger never crashes or denies" 0 "$RC"
done
chk_contains "16-F2 the threshold warn still arrives" "4 times today" "$(ctx "$OUT")"
chk_contains "16-F2 and STILL admits the floor, three processes after the reset" "不可判" "$(ctx "$OUT")"
chk_eq "16-F2 and nothing reaches stderr" "" "$ERR"
# PAIRED CONTROL: a ledger that was never corrupt reports the SAME count with no floor wording,
# so the admission is carried by the record and not stapled to every warn
BS7="$G8ROOT/bs7"; mkdir -p "$BS7"
for i in 1 2 3 4; do runbs "$BS7" 'agentctl watch g16clean' 1; done
chk_contains "16-F2 control: a healthy ledger reaches the same count" "4 times today" "$(ctx "$OUT")"
chk_not_contains "16-F2 control: and claims no floor" "不可判" "$(ctx "$OUT")"
# the pre-flag FLAT shape is unknown history, not a count to adopt: it resets AND raises the flag
BS8="$G8ROOT/bs8"; mkdir -p "$BS8"
printf '{"g16flat": 3}' > "$BS8/babysit-$(id -u)-$(date +%Y%m%d).json"
runbs "$BS8" 'agentctl watch g16flat' 1
chk_eq "16-F2 a legacy flat ledger is not adopted as a count" "" "$OUT"
for i in 2 3 4; do runbs "$BS8" 'agentctl watch g16flat' 1; done
chk_contains "16-F2 it counts from zero" "4 times today" "$(ctx "$OUT")"
chk_contains "16-F2 and says the history is unknown" "不可判" "$(ctx "$OUT")"


summary
