#!/usr/bin/env bash
# PreToolUse(Bash) guard: block agent-watch `watch` invocations backgrounded with a shell `&`/`disown`.
# Rationale: the watcher must be a harness-tracked background task (Bash tool run_in_background:true) so the
# agent gets a completion callback. A shell `&` detaches it from the wrapper → ORPHAN: no callback, and the
# wrapper reports "done" while the watcher runs unseen. The skill (§1.4) says this in prose but it kept
# being slipped (~6× in one session — salience decay), so this is the deterministic backstop.
# Deny ONLY: a command that runs `.../agent-watch/watch ...` AND ends with a single trailing `&` (or `& disown`).
# Everything else (foreground watch, `&&` chains, dispatch, etc.) passes untouched.
set -eu
command -v jq >/dev/null 2>&1 || exit 0   # never block work if jq is absent
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# is it an agent-watch watcher invocation?
printf '%s' "$cmd" | grep -Eq 'agent-watch/watch( |$)' || exit 0

# trailing background `&` (not `&&`) optionally followed by `disown`/redirects — i.e. shell-backgrounded
if printf '%s' "$cmd" | grep -Eq '(^|[^&])&[[:space:]]*(disown[[:space:]]*)?$' \
   || printf '%s' "$cmd" | grep -Eq '&[[:space:]]*disown'; then
  reason='agent-watch watcher backgrounded with shell & → ORPHAN (no completion callback; wrapper falsely reports done). Re-run WITHOUT & and set the Bash tool run_in_background:true instead.'
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
fi
exit 0
