#!/usr/bin/env bash
# cto-guard-agent.py — non-Bash tool-call guard, FOUR branches routed on (hook_event_name, tool_name):
#   P0a PreToolUse·Agent|Task   browser dispatch loading chrome-devtools MCP -> DENY (Playwright-first)
#   P0c PreToolUse·Agent|Task   dispatch missing explicit `model` -> DENY unless subagent_type "fork"
#   P0b PreToolUse·TaskStop     killing an ALIVE agent (fresh .output) -> DENY unless override marker
#   PostToolUse·Agent|Task      browser dispatch -> black-hole deadline reminder (JSON additionalContext)
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agentctl/cto-guard-agent.py"
unset AGENTCTL_SESSION                # a worker seat exempts P0c/P0d — this suite judges as the orchestrator
export AGENT_WATCH_DIR="$(mktemp -d)" # dedupe markers land here, never in the live run dir

echo "== cto-guard-agent.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

mkp() { # $1 event  $2 tool  $3 json-fragment-for-tool_input
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name":sys.argv[1],"tool_name":sys.argv[2],"tool_input":json.loads(sys.argv[3])}))' "$1" "$2" "$3"
}
run() { local tmpe; tmpe="$(mktemp)"; OUT="$(mkp "$1" "$2" "$3" | python3 "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"; }
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }

chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# ── PostToolUse reminder (JSON additionalContext; plain stdout would hit only the debug log) ──
run PostToolUse Agent '{"prompt":"run playwright E2E against localhost:3000"}'
chk_eq "browser prompt exit 0" 0 "$RC"
chk_eq "reminder hookEventName" "PostToolUse" "$(printf '%s' "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
chk_contains "reminder in additionalContext" "BLACK-HOLE" "$(ctx "$OUT")"
run PostToolUse Task '{"prompt":"take a screenshot of the dev server"}'
chk_contains "browser Task reminded" "BLACK-HOLE" "$(ctx "$OUT")"
run PostToolUse Agent '{"prompt":"refactor the auth module and run unit tests"}'
chk_eq "non-browser no reminder" "" "$OUT"; chk_eq "non-browser exit 0" 0 "$RC"
run PostToolUse Agent 'null'
chk_eq "PostToolUse malformed tool_input soft-abstains" 0 "$RC"; chk_eq "PostToolUse malformed tool_input silent" "" "$OUT$ERR"
run PostToolUse Task '{}'
chk_eq "PostToolUse missing prompt soft-abstains" 0 "$RC"; chk_eq "PostToolUse missing prompt silent" "" "$OUT$ERR"
run PostToolUse Agent '{"prompt":42}'
chk_eq "PostToolUse wrong prompt type soft-abstains" 0 "$RC"; chk_eq "PostToolUse wrong prompt type silent" "" "$OUT$ERR"
tmpe="$(mktemp)"; out="$(python3 -c 'import io,json,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"run browser E2E\"}}"); original=json.dumps; json.dumps=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "PostToolUse internal failure soft-abstains" 0 "$rc"; chk_eq "PostToolUse internal failure silent" "" "$out$err"

# ── P0a: browser dispatch that LOADS chrome-devtools MCP -> DENY; prose mention passes ──
run PreToolUse Agent '{"prompt":"browser E2E on localhost:3000; ToolSearch select:mcp__chrome-devtools__take_snapshot"}'
chk_eq "chrome-devtools tool token denied (exit 2)" 2 "$RC"
chk_contains "deny points to Playwright" "Playwright" "$ERR"
run PreToolUse Agent '{"prompt":"browser E2E via Playwright MCP; 绝不用 chrome-devtools 的工具","model":"sonnet"}'
chk_eq "prose mention (no mcp__ token) allowed" 0 "$RC"
# note: the token itself matches BROWSER_RE (substring chrome-devtools) → token anywhere = deny.
run PreToolUse Agent '{"prompt":"analyze mcp__chrome-devtools docs, no browser work"}'
chk_eq "token alone still denies (token implies browser-ish)" 2 "$RC"

# ── P0c: Agent/Task dispatch missing explicit `model` -> DENY unless subagent_type "fork" ──
run PreToolUse Agent '{"prompt":"run the test suite"}'
chk_eq "Agent no model denied (exit 2)" 2 "$RC"
chk_contains "deny mentions model tiers" "economy tier" "$ERR"
run PreToolUse Agent '{"prompt":"run the test suite","model":"sonnet"}'
chk_eq "Agent with model allowed" 0 "$RC"
run PreToolUse Agent '{"prompt":"adversarial review of the PR","model":"gpt-5.6"}'
chk_eq "non-Claude model name allowed (no allowlist)" 0 "$RC"
run PreToolUse Agent '{"prompt":"continue prior context","subagent_type":"fork"}'
chk_eq "fork subagent exempt from model requirement" 0 "$RC"
run PreToolUse Task '{"prompt":"run the test suite"}'
chk_eq "Task no model denied (exit 2)" 2 "$RC"
run PreToolUse Read '{"file_path":"/tmp/x"}'
chk_eq "non-Agent/Task tool unaffected by model requirement" 0 "$RC"

# ── P0d: e2e-runner dispatch (brief carries E2E_ECONOMY=1) must ride an economy tier ──
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"opus"}'
chk_eq "e2e runner on opus denied (exit 2)" 2 "$RC"
chk_contains "e2e-runner deny names economy tier" "economy tier" "$ERR"
chk_contains "e2e-runner deny carries doc pointer" "SKILL.md" "$ERR"
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"fable"}'
chk_eq "e2e runner on fable denied" 2 "$RC"
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"haiku"}'
chk_eq "e2e runner on haiku allowed" 0 "$RC"
run PreToolUse Agent '{"prompt":"adversarial review of test/e2e/onboard.e2e.sh changes","model":"opus"}'
chk_eq "premium review of e2e code (no marker) allowed" 0 "$RC"

# ── P0b: TaskStop on an ALIVE agent (fresh transcript) -> DENY; stale or overridden -> allow ──
TID="zzguardtest$$"
FAKE="/tmp/claude-zztest/a/b/tasks"; mkdir -p "$FAKE"
touch "$FAKE/$TID.output"                                   # fresh = alive
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "kill fresh agent denied (exit 2)" 2 "$RC"; chk_contains "deny says ALIVE" "ALIVE" "$ERR"
touch "/tmp/cto-allow-kill-$TID"                            # explicit override
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "override marker allows kill" 0 "$RC"
rm -f "/tmp/cto-allow-kill-$TID"
touch -t 202601010000 "$FAKE/$TID.output"                   # stale = not alive
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "stale transcript allows kill" 0 "$RC"
run PreToolUse TaskStop '{"task_id":"zz-ghost-task-000"}'
chk_eq "unknown task allows (no transcript found)" 0 "$RC"
rm -rf /tmp/claude-zztest

# jsonl source (Agent-type tasks): tasks/<id>.output is a completion-time stub, liveness lives in
# the subagent transcript — a fresh agent-<tid>.jsonl ALONE (no tasks/*.output anywhere) must DENY.
# HOME is overridden so the guard's ~/.claude glob resolves into the fixture, keeping this hermetic.
JID="zzjsonltest$$"
JH="/tmp/claude-zztest-home"; mkdir -p "$JH/.claude/projects/p/s/subagents"
touch "$JH/.claude/projects/p/s/subagents/agent-$JID.jsonl"
tmpe="$(mktemp)"
OUT="$(printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TaskStop\",\"tool_input\":{\"task_id\":\"$JID\"}}" | HOME="$JH" python3 "$GUARD" 2>"$tmpe")"; RC=$?
ERR="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "fresh subagent jsonl alone denies kill" 2 "$RC"; chk_contains "jsonl deny says ALIVE" "ALIVE" "$ERR"
touch -t 202601010000 "$JH/.claude/projects/p/s/subagents/agent-$JID.jsonl"
OUT="$(printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TaskStop\",\"tool_input\":{\"task_id\":\"$JID\"}}" | HOME="$JH" python3 "$GUARD" 2>/dev/null)"; RC=$?
chk_eq "stale jsonl allows kill" 0 "$RC"
rm -rf "$JH"

# ── P0e: a dispatch whose prompt names a work tree BEHIND its upstream -> WARN, never DENY ──
# The WARN rides additionalContext, NOT stderr: on exit 0 the host treats stderr as debug output
# the dispatching agent never sees, so asserting on stderr would green a message nobody reads
# (codex review 2026-09-16). Every arm below therefore reads `ctx "$OUT"` and pins stderr empty.
# Fixture = the shape that proved the pre-rule guard silent: one bare origin, `a` pushes, every
# other clone stands in for a seat's cwd at a different depth. Local paths only, no network.
SS="$(mktemp -d)"; SSR="$(cd "$SS" && pwd -P)"; PY3="$(command -v python3)"
git init -q --bare "$SS/origin.git"
git clone -q "$SS/origin.git" "$SS/a" 2>/dev/null
( cd "$SS/a" && git config user.email t@example.com && git config user.name t \
  && echo one > f && git add f && git commit -qm one && git push -q origin HEAD:main ) >/dev/null 2>&1
# the bare repo's own HEAD must name the pushed branch, or every clone below lands with no
# branch at all (dangling remote HEAD) and @{upstream} has nothing to answer
git -C "$SS/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$SS/origin.git" "$SS/b" 2>/dev/null                  # b stays at commit one
( cd "$SS/a" && echo two >> f && git commit -qam two && echo three >> f && git commit -qam three \
  && git push -q origin HEAD:main ) >/dev/null 2>&1
( cd "$SS/b" && git fetch -q ) >/dev/null 2>&1                     # b: behind 2, fetch fresh
mkdir -p "$SS/plain"
git clone -q "$SS/origin.git" "$SS/c" 2>/dev/null
git -C "$SS/c" checkout -qb solo                                   # a branch with no upstream
for w in w1 w2 w3 w4 w5; do git clone -q "$SS/origin.git" "$SS/$w" 2>/dev/null; done
( cd "$SS/a" && echo four >> f && git commit -qam four && git push -q origin HEAD:main ) >/dev/null 2>&1
for w in w1 w2 w3 w4 w5; do ( cd "$SS/$w" && git fetch -q ) >/dev/null 2>&1; done  # each behind 1
chk_eq "fixture: b is two commits behind its upstream" 2 "$(git -C "$SS/b" rev-list --count HEAD..@{upstream} 2>/dev/null)"

# ① the field shape: a seat sent into a tree that is behind -> one WARN line, rc untouched
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/b 里的 file:line\",\"model\":\"haiku\"}"
CTX="$(ctx "$OUT")"
chk_eq "stale tree leaves rc alone" 0 "$RC"
chk_contains "stale tree warns" "WARN (cto-guard-agent stale-scout-cwd)" "$CTX"
chk_contains "stale warn carries the behind count" "2" "$CTX"
chk_contains "stale warn names the work tree" "$SSR/b" "$CTX"
chk_eq "stale warn writes no stderr (exit-0 stderr is debug, not context)" "" "$ERR"

# ② behind 0 with a fresh fetch -> silent (the only silent case this rule has)
( cd "$SS/b" && git pull -q ) >/dev/null 2>&1
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/b 里的 file:line\",\"model\":\"haiku\"}"
chk_eq "fresh tree silent" "" "$ERR$OUT"; chk_eq "fresh tree exit 0" 0 "$RC"

# ③ a branch with no upstream cannot be measured, and says so
run PreToolUse Agent "{\"prompt\":\"audit $SS/c\",\"model\":\"haiku\"}"
chk_contains "no upstream is spoken" "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "no upstream exit 0" 0 "$RC"
chk_eq "no upstream writes no stderr" "" "$ERR"

# ④ behind 0 but FETCH_HEAD is 25h old: that 0 only reflects the last fetch -> UNMEASURED
"$PY3" -c 'import os,sys,time; os.utime(sys.argv[1],(time.time()-25*3600,)*2)' "$SS/b/.git/FETCH_HEAD"
run PreToolUse Agent "{\"prompt\":\"audit $SS/b\",\"model\":\"haiku\"}"
chk_contains "behind=0 on a 25h-old fetch is UNMEASURED" "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "stale FETCH_HEAD exit 0" 0 "$RC"

# ⑤ a path that is not a git work tree is none of this rule's business
run PreToolUse Agent "{\"prompt\":\"write notes to $SS/plain\",\"model\":\"haiku\"}"
chk_eq "non-git path silent" "" "$ERR$OUT"; chk_eq "non-git path exit 0" 0 "$RC"

# ⑥ no git on PATH -> UNMEASURED, never a silent pass (sandbox PATH holds nothing)
SBIN="$(mktemp -d)"; tmpe="$(mktemp)"
OUT="$(mkp PreToolUse Agent "{\"prompt\":\"audit $SS/w1\",\"model\":\"haiku\"}" | PATH="$SBIN" "$PY3" "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"
chk_contains "missing git is spoken" "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "missing git exit 0" 0 "$RC"
chk_eq "missing git writes no stderr" "" "$ERR"

# ⑦ a git that hangs -> the per-call timeout fires and is spoken, not waited on
# `/bin/sleep`, absolutely: the sandbox PATH holds only this script, so a bare `sleep` exits 127
# and the fake git would answer INSTANTLY — the probe would then measure nothing at all
printf '#!/bin/sh\n/bin/sleep 5\n' > "$SBIN/git"; chmod +x "$SBIN/git"; tmpe="$(mktemp)"
OUT="$(mkp PreToolUse Agent "{\"prompt\":\"audit $SS/w2\",\"model\":\"haiku\"}" | PATH="$SBIN" "$PY3" "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"
chk_contains "hanging git is spoken" "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "hanging git exit 0" 0 "$RC"
rm -rf "$SBIN"

# ⑧ the DENY rules keep precedence: stale tree + no model is still the model DENY
run PreToolUse Agent "{\"prompt\":\"audit $SS/w1\"}"
chk_eq "missing model still denies over a stale tree" 2 "$RC"
chk_contains "the deny is the model one" "DENY" "$ERR"
chk_not_contains "no freshness note on a denied dispatch" "stale-scout-cwd" "$OUT$ERR"

# ⑨ more work trees than the cap: four judged, one line saying the rest were not
run PreToolUse Agent "{\"prompt\":\"audit $SS/w1 $SS/w2 $SS/w3 $SS/w4 $SS/w5\",\"model\":\"haiku\"}"
CTX="$(ctx "$OUT")"
chk_eq "over-cap exit 0" 0 "$RC"
chk_eq "exactly four work trees judged" 4 "$(printf '%s\n' "$CTX" | grep -c 'WARN (cto-guard-agent stale-scout-cwd)')"
chk_contains "over-cap is spoken" "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$CTX"
chk_eq "over-cap writes no stderr" "" "$ERR"

# ⑩ a LINKED worktree keeps its OWN FETCH_HEAD, in its own git dir — the common dir's copy
# belongs to a SIBLING tree, so reading that one misreads the fetch age in BOTH directions
# (codex review 2026-09-16: a stale sibling faked UNMEASURED, a fresh sibling hid a never-fetched
# tree). Worktree seats are this rule's whole audience, so the wrong file here is a silent pass.
git clone -q "$SS/origin.git" "$SS/lw" 2>/dev/null
( cd "$SS/lw" && git fetch -q ) >/dev/null 2>&1
git -C "$SS/lw" worktree add -B lb "$SS/linked" origin/main >/dev/null 2>&1
git -C "$SS/linked" branch --set-upstream-to=origin/main lb >/dev/null 2>&1
LCOMMON="$SS/lw/.git/FETCH_HEAD"; LOWN="$SS/lw/.git/worktrees/linked/FETCH_HEAD"
age25() { touch -t "$("$PY3" -c 'import time;print(time.strftime("%Y%m%d%H%M.%S",time.localtime(time.time()-25*3600)))')" "$1"; }
chk_eq "fixture: the linked worktree is level with its upstream" 0 \
  "$(git -C "$SS/linked" rev-list --count HEAD..@{upstream} 2>/dev/null)"
chk_eq "fixture: the linked worktree's FETCH_HEAD is NOT the common dir's" 1 \
  "$([ "$(git -C "$SS/linked" rev-parse --git-path FETCH_HEAD)" \
     != "$(git -C "$SS/linked" rev-parse --git-common-dir)/FETCH_HEAD" ] && echo 1 || echo 0)"
# common fresh / linked absent: this tree never fetched, so its behind=0 compares against nothing
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/linked\",\"model\":\"haiku\"}"
chk_contains "linked tree that never fetched is UNMEASURED despite a fresh sibling" \
  "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "linked never-fetched exit 0" 0 "$RC"
# common 25h / linked fresh: the tree at issue IS fresh -> the one silent case, sibling ignored
( cd "$SS/linked" && git fetch -q ) >/dev/null 2>&1
age25 "$LCOMMON"
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/linked\",\"model\":\"haiku\"}"
chk_eq "a freshly-fetched linked tree stays silent under a 25h-old sibling" "" "$(ctx "$OUT")$ERR"
chk_eq "linked fresh exit 0" 0 "$RC"
# common fresh / linked 25h: the tree at issue is stale -> UNMEASURED, sibling freshness is noise
touch "$LCOMMON"; age25 "$LOWN"
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/linked\",\"model\":\"haiku\"}"
chk_contains "a 25h-old linked fetch is UNMEASURED despite a fresh sibling" \
  "UNMEASURED (cto-guard-agent stale-scout-cwd)" "$(ctx "$OUT")"
chk_eq "linked stale exit 0" 0 "$RC"

# ⑪ prose boundaries: markdown bold and a sentence-final period are not part of the path. Both
# used to yield complete silence (codex review 2026-09-16) — the one answer this rule may never
# give for an existing tree it could have measured.
run PreToolUse Agent "{\"prompt\":\"只读取证：**$SS/w3**\",\"model\":\"haiku\"}"
chk_contains "a bold-wrapped path is still measured" "$SSR/w3" "$(ctx "$OUT")"
chk_eq "bold path exit 0" 0 "$RC"
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/w3.\",\"model\":\"haiku\"}"
chk_contains "a sentence-final period is not part of the path" "$SSR/w3" "$(ctx "$OUT")"
run PreToolUse Agent "{\"prompt\":\"只读取证：核对 $SS/w3/f.\",\"model\":\"haiku\"}"
chk_contains "a file token plus a period still stands for its tree" "$SSR/w3" "$(ctx "$OUT")"
rm -rf "$SS"

# ── degenerate ──
tmpe="$(mktemp)"; out="$(printf 'not json' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "malformed JSON is checker error" 2 "$rc"; chk_contains "malformed JSON marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"model":"sonnet"}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Agent missing prompt is checker error" 2 "$rc"; chk_contains "missing prompt marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"TaskStop","tool_input":{"task_id":42}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching TaskStop wrong id type is checker error" 2 "$rc"; chk_contains "wrong id type marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":null}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "non-applicable tool stays allowed" 0 "$rc"; chk_eq "non-applicable tool silent" "" "$err"
tmpe="$(mktemp)"; out="$(python3 -c 'import glob,io,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TaskStop\",\"tool_input\":{\"task_id\":\"broken-checker\"}}"); glob.glob=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "internal Agent checker failure exits 2" 2 "$rc"; chk_contains "internal Agent checker failure marker" "CHECKER-ERROR" "$err"

# ── scope (owner 2026-09-25): P0c/P0d are ORCHESTRATOR rules — an agentctl seat (AGENTCTL_SESSION) is exempt ──
AGENTCTL_SESSION=zz-seat run PreToolUse Agent '{"prompt":"run the test suite"}'
chk_eq "worker seat: missing model allowed" 0 "$RC"; chk_eq "worker seat: silent" "" "$OUT$ERR"
AGENTCTL_SESSION=zz-seat run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh","model":"opus"}'
chk_eq "worker seat: e2e on opus allowed" 0 "$RC"
AGENTCTL_SESSION=zz-seat run PreToolUse Agent '{"prompt":"browser E2E; ToolSearch select:mcp__chrome-devtools__take_snapshot","model":"sonnet"}'
chk_eq "worker seat: P0a still denies (not an economy rule)" 2 "$RC"
AGENTCTL_SESSION="" run PreToolUse Agent '{"prompt":"run the test suite"}'
chk_eq "empty AGENTCTL_SESSION is not a worker seat" 2 "$RC"

# ── two-level dedupe: one (event, tool_use_id) is judged once; the second copy exits 0 silently ──
runid() { local tmpe; tmpe="$(mktemp)"; OUT="$(mkp "$1" "$2" "$3" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["tool_use_id"]=sys.argv[1]; print(json.dumps(d))' "$4" | python3 "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"; }
runid PreToolUse Agent '{"prompt":"run the test suite"}' toolu_zz01
chk_eq "first copy denies" 2 "$RC"
runid PreToolUse Agent '{"prompt":"run the test suite"}' toolu_zz01
chk_eq "second copy (same id) exits 0" 0 "$RC"; chk_eq "second copy silent" "" "$OUT$ERR"
runid PreToolUse Agent '{"prompt":"run the test suite"}' toolu_zz02
chk_eq "new id judged again" 2 "$RC"
runid PostToolUse Agent '{"prompt":"run playwright E2E against localhost:3000"}' toolu_zz01
chk_contains "Pre and Post of one id are distinct keys" "BLACK-HOLE" "$(ctx "$OUT")"
runid PostToolUse Agent '{"prompt":"run playwright E2E against localhost:3000"}' toolu_zz01
chk_eq "Post second copy silent" "" "$OUT"
run PreToolUse Agent '{"prompt":"run the test suite"}'; a=$RC; run PreToolUse Agent '{"prompt":"run the test suite"}'
chk_eq "no tool_use_id: never deduped" "2/2" "$a/$RC"
chk_eq "marker dir is 0700" "700" "$(stat -f %Lp "$AGENT_WATCH_DIR/guard-agent.seen" 2>/dev/null || stat -c %a "$AGENT_WATCH_DIR/guard-agent.seen")"
AGENT_WATCH_DIR=/nonexistent/zz runid PreToolUse Agent '{"prompt":"run the test suite"}' toolu_zz03
chk_eq "unwritable run dir still judges" 2 "$RC"
rm -rf "$AGENT_WATCH_DIR"

summary
