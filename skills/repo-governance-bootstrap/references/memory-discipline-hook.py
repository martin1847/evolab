#!/usr/bin/env python3
# memory-discipline-hook.py — shared PostToolUse hook core for Claude Code + codex.
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
# All-Python (not shell+jq): parses the hook JSON with the stdlib (no jq dependency — the
# old shell version fail-opened and silently dropped the reminder when jq was absent) and
# emits valid JSON via json.dumps. Fail-open: any parse error exits 0, never blocks work.
#
# omp uses a different mechanism (JS tool_result hook) and its context-injection path
# is UNVERIFIED — see the repo-governance-bootstrap SKILL.md step-11 omp note. Not here.
#
# Test: test/hook.test.sh drives this with synthetic Claude + codex stdin.
import sys, json, os, re

REMINDER = ("memory 写入提醒：事实细节(schema/config/creds/endpoint/长清单)→ ACCESS.local.md/docs；"
            "memory 正文只留指针+教训。")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    ti = data.get("tool_input", {}) or {}

    # 1) Claude Code shape: path at .tool_input.file_path
    fp = ti.get("file_path", "") or ""
    # 2) codex apply_patch shape: path in the patch text of .tool_input.command
    if not fp:
        cmd = ti.get("command", "") or ""
        m = re.search(r"^\*\*\* (?:Add|Update) File: (.+)$", cmd, re.M)
        if m:
            fp = m.group(1)
    if not fp:
        return 0

    # match both relative (codex: memory/x.md) and absolute/nested (CC: /p/memory/x.md)
    if fp.endswith(".md") and (fp.startswith("memory/") or "/memory/" in fp):
        if os.path.basename(fp) == "MEMORY.md":
            return 0  # index file is the pointer list itself
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                                  "additionalContext": REMINDER}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
