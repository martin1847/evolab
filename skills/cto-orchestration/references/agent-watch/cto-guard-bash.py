#!/usr/bin/env python3
# cto-guard-bash — PreToolUse·Bash enforcement for cto-orchestration. Wire to the Bash matcher
# (CC skill frontmatter `hooks:` / `.claude/settings.json`; Codex `hooks.json`). Denies two Bash
# footguns the orchestrator keeps slipping (prose decays → enforce at tool-call time):
#   (1) trailing shell `&` -> ORPHAN (no completion callback; wrapper falsely reports done)
#   (2) naive "idle==done" poller (loop + capture-pane + idle grep, no positive-evidence check)
# Deny = exit 2 + stderr (shown to the agent). Fail-open: any parse error exits 0, never blocks work.
# All-Python: the job is parsing arbitrary command content out of hook JSON — stdlib json is correct
# where shell-regex extraction would be fragile in a guard. (PostToolUse·Agent reminder = sibling
# cto-guard-agent.py; one focused script per hook since the wiring layer already separates them.)
import sys, json, re


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    ti = data.get("tool_input", {}) or {}
    cmd = (ti.get("command", "") or "").replace("\n", " ")
    if not cmd:
        return 0

    # (1) trailing shell-& backgrounding -> orphan. Allow && / 2>&1 / quoted &.
    if re.search(r"(^|[^&])&[ \t]*(disown[ \t]*)?$", cmd) or re.search(r"&[ \t]*disown[ \t]*$", cmd):
        sys.stderr.write(
            "DENY: trailing shell & -> ORPHAN (no completion callback; wrapper falsely reports done). "
            "Drop the & and use the Bash tool run_in_background:true instead.\n"
        )
        return 2

    # (2) naive "idle==done" poller: loop + capture-pane + busy/idle grep, concluding from idle-absence
    #     with NO positive-evidence check (git deliverable OR pane Verdict/prompt marker).
    has_loop = re.search(r"\b(for|while)\b", cmd)
    has_capture = re.search(r"capture-pane|tmux .*capture", cmd)
    has_idle = re.search(r"Working|Esc to interrupt|busy|idle|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏", cmd, re.I)
    has_positive = re.search(
        r"git diff --stat|git log[^|]*\.\.HEAD|--oneline|ALL PARTS DONE|Verdict|approve|"
        r"request-changes|Would you like to run|APPEARED|COMMIT_|PROMPT|SIGNAL_FOUND",
        cmd, re.I,
    )
    if has_loop and has_capture and has_idle and not has_positive:
        sys.stderr.write(
            "DENY: hand-rolled 'idle==done' poller (loop+capture-pane+idle grep, no positive-evidence "
            "check). idle≠done — staged tasks idle at every commit boundary. Add a POSITIVE check: git "
            "deliverable (git diff --stat / git log ..HEAD) for agent completion, or a pane grep for "
            "Verdict/prompt for reviews.\n"
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
