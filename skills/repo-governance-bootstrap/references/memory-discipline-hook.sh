#!/usr/bin/env bash
# memory-discipline-hook.sh — shared PostToolUse hook core for Claude Code + codex.
#
# Both runtimes feed a PostToolUse hook JSON on stdin and read a stdout JSON object
# with .hookSpecificOutput.additionalContext to inject a system reminder. But they
# carry the written path DIFFERENTLY (verified by live run, 2026-06):
#   - Claude Code: tool_name Write/Edit/MultiEdit, path at .tool_input.file_path
#   - codex:       tool_name apply_patch, path inside .tool_input.command patch text
#                  ("*** Add File: <p>" / "*** Update File: <p>"), relative to cwd
# So this script tries both extractors; one script still serves both, only the wiring
# differs (Claude .claude/settings.json vs codex .codex/hooks.json — both project-level).
#
# Behavior: a write landing on a memory/*.md file (NOT the MEMORY.md index) -> emit a
# reminder to offload factual detail and keep memory bodies pointer-only. Else silent.
#
# omp uses a different mechanism (JS tool_result hook) and its context-injection path
# is UNVERIFIED — see the repo-governance-bootstrap SKILL.md step-11 omp note. Not here.
#
# Test: test/hook.test.sh drives this with synthetic Claude + codex stdin.
set -eu

REMINDER='memory 写入提醒：事实细节(schema/config/creds/endpoint/长清单)→ ACCESS.local.md/docs；memory 正文只留指针+教训。'

command -v jq >/dev/null 2>&1 || exit 0   # never block work if jq is absent

input="$(cat)"   # read stdin ONCE (two jq reads would drain the stream)

# 1) Claude Code shape
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
# 2) codex apply_patch shape: path is in the patch text of .tool_input.command
if [ -z "$fp" ]; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -n "$cmd" ] && fp="$(printf '%s\n' "$cmd" | sed -n -E 's/^\*\*\* (Add|Update) File: (.+)$/\2/p' | head -1)"
fi
[ -n "$fp" ] || exit 0

# match both relative (codex: memory/x.md) and absolute/nested (CC: /p/memory/x.md)
case "$fp" in
  memory/*.md | */memory/*.md)
    [ "$(basename "$fp")" = "MEMORY.md" ] && exit 0   # index file is the pointer list itself
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$REMINDER"
    ;;
  *) : ;;
esac
exit 0
