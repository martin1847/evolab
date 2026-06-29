#!/usr/bin/env bash
# memory-discipline-hook.py — shared PostToolUse hook core (Claude Code + codex).
# Drives the script with synthetic stdin and asserts the match matrix:
# memory/*.md (non-index) -> reminder; everything else -> silent. CC file_path + codex apply_patch shapes.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

HOOK="../skills/repo-governance-bootstrap/references/memory-discipline-hook.py"

echo "== memory-discipline-hook.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — hook test skipped"; exit 0
fi

# wired as executable via `<S>/...py` — exec bit + shebang must hold
chk_eq "script is executable" 1 "$([ -x "$HOOK" ] && echo 1 || echo 0)"

# feed <tool_input-json> on stdin, capture stdout
run_hook() { printf '%s' "$1" | python3 "$HOOK"; }

# 1. memory file (non-index) -> reminder with additionalContext
out="$(run_hook '{"tool_input":{"file_path":"/proj/memory/lesson.md"}}')"
chk_contains "memory/*.md fires" "additionalContext" "$out"
chk_contains "reminder text present" "只留指针" "$out"

# 2. nested under memory/ -> still fires (glob spans slashes)
out="$(run_hook '{"tool_input":{"file_path":"/proj/memory/sub/x.md"}}')"
chk_contains "nested memory/ fires" "additionalContext" "$out"

# 3. MEMORY.md index -> silent (it IS the pointer list)
out="$(run_hook '{"tool_input":{"file_path":"/proj/memory/MEMORY.md"}}')"
chk_eq "MEMORY.md index silent" "" "$out"

# 4. non-memory path -> silent
out="$(run_hook '{"tool_input":{"file_path":"/proj/src/app.md"}}')"
chk_eq "non-memory path silent" "" "$out"

# 5. memory dir but non-.md -> silent
out="$(run_hook '{"tool_input":{"file_path":"/proj/memory/notes.txt"}}')"
chk_eq "memory non-.md silent" "" "$out"

# 6. missing file_path -> silent, exit 0
out="$(run_hook '{"tool_input":{}}')"; rc=$?
chk_eq "missing file_path silent" "" "$out"
chk_eq "missing file_path exit 0" 0 "$rc"

# 7. empty / non-JSON stdin -> silent, exit 0 (never block work)
out="$(printf '' | python3 "$HOOK")"; rc=$?
chk_eq "empty stdin silent" "" "$out"
chk_eq "empty stdin exit 0" 0 "$rc"

# 8. emitted reminder is valid JSON with the right event name
out="$(run_hook '{"tool_input":{"file_path":"/proj/memory/lesson.md"}}')"
ev="$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
chk_eq "emits valid PostToolUse JSON" "PostToolUse" "$ev"

# --- codex apply_patch shape (path in .tool_input.command patch text, relative to cwd) ---
# 9. codex Add File under memory/ -> fires
out="$(run_hook '{"tool_input":{"command":"*** Begin Patch\n*** Add File: memory/probe.md\n+hi\n*** End Patch\n"}}')"
chk_contains "codex Add File memory/ fires" "additionalContext" "$out"

# 10. codex Update File under memory/ -> fires
out="$(run_hook '{"tool_input":{"command":"*** Begin Patch\n*** Update File: memory/lesson.md\n@@\n-a\n+b\n*** End Patch\n"}}')"
chk_contains "codex Update File memory/ fires" "additionalContext" "$out"

# 11. codex apply_patch to non-memory path -> silent
out="$(run_hook '{"tool_input":{"command":"*** Begin Patch\n*** Add File: src/app.md\n+x\n*** End Patch\n"}}')"
chk_eq "codex non-memory silent" "" "$out"

# 12. codex apply_patch to MEMORY.md index -> silent
out="$(run_hook '{"tool_input":{"command":"*** Begin Patch\n*** Update File: memory/MEMORY.md\n@@\n-a\n+b\n*** End Patch\n"}}')"
chk_eq "codex MEMORY.md index silent" "" "$out"

summary
