#!/usr/bin/env bash
# PreToolUse(Bash) guard: block ANY shell-level backgrounding in the Bash tool.
# Rationale: background work must be a harness-tracked task (Bash tool run_in_background:true) so the agent
# gets a completion callback. A shell `&` / nohup / disown / setsid detaches it from the wrapper → ORPHAN:
# no callback, and the wrapper reports "done" while the job runs unseen. The skill (§1.4) says this in prose
# but it kept being slipped (~6× in one session, then again with a hand-rolled `nohup ... &` poll loop that
# the old watch-only guard let through — salience decay), so this is the deterministic backstop.
# Deny: a trailing background `&` (not `&&`) or `& disown` — this covers `nohup ... &`. A bare
# `setsid`/`disown` without a trailing `&` is accepted-missing (keyword-matching it false-positives on data
# like `grep nohup`; we trade that exotic miss for near-zero false positives).
# Pass untouched: `&&` chains, `2>&1` redirects, `&` inside quoted strings/URLs (not at command end), and
# normal foreground commands. The ONLY sanctioned background path is the Bash tool's run_in_background:true
# (no shell `&` in the command → never seen here).
set -eu
command -v jq >/dev/null 2>&1 || exit 0   # never block work if jq is absent
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# Detect shell backgrounding by SYNTAX, not keywords (a bare `nohup`/`setsid`/`disown` word-match
# false-positives on data like `grep nohup` / `man setsid`). The real mistake mode is a trailing
# background `&` — which also covers `nohup ... &` (ends in `&`). `setsid foo` without `&` is an exotic
# detach we accept missing, in exchange for near-zero false positives.
# Deny: a trailing `&` (not `&&`), optionally `& disown`.
if printf '%s' "$cmd" | grep -Eq '(^|[^&])&[[:space:]]*(disown[[:space:]]*)?$' \
   || printf '%s' "$cmd" | grep -Eq '&[[:space:]]*disown[[:space:]]*$'; then
  reason='command backgrounded with a trailing shell & -> ORPHAN: no completion callback, wrapper falsely reports done. Re-run WITHOUT & and set the Bash tool run_in_background:true instead.'
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
fi
exit 0
