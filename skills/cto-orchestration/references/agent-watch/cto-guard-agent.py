#!/usr/bin/env python3
# cto-guard-agent — PostToolUse·Agent|Task enforcement for cto-orchestration. Wire to the Agent|Task
# matcher (CC skill frontmatter `hooks:` / `.claude/settings.json`). When a browser/E2E subagent is
# launched, its completion notification can BLACK-HOLE (a live Playwright session / dev server / bg
# fork keeps it from firing) — omission can't be hard-denied, so inject a deadline-watch reminder at
# launch time. Reminder = JSON hookSpecificOutput.additionalContext (PostToolUse plain stdout only
# hits the debug log, never the agent). Fail-open: any parse error exits 0. (PreToolUse·Bash denies =
# sibling cto-guard-bash.py; one focused script per hook since the wiring layer separates them.)
# Note: the Agent/Task tool is a Claude Code concept — Codex/omp have no such tool, so this branch is
# CC-specific (harmless no-op elsewhere). See agent-watch/README.md 跨调度者移植.
import sys, json, re


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    prompt = (data.get("tool_input", {}) or {}).get("prompt", "") or ""
    if not re.search(
        r"playwright|chrome-?devtools|browser|E2E|screenshot|navigate|dev server|"
        r"localhost:[0-9]|vite|npm run dev|pnpm .*dev",
        prompt, re.I,
    ):
        return 0
    msg = (
        "[browser/long subagent launched] Its completion notification can BLACK-HOLE (a live Playwright "
        "session / dev server / bg fork keeps it from firing — you'll blind-wait forever). DO NOW, don't "
        "rely on the auto-notify: set a deadline-bounded background watch on POSITIVE evidence (output-file "
        "growth / new screenshots / a milestone SendMessage); if it goes quiet past the deadline, "
        "SendMessage to poke it, then kill+relaunch rather than wait. (cto SKILL §1.4 / §7.)"
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
