#!/usr/bin/env python3
# cto-guard — single consolidated enforcement hook for cto-orchestration. Wire the SAME script to
# both events in .claude/settings.json (run it as `python3 .../cto-guard.py`, or directly — it is
# executable):
#   PreToolUse  matcher "Bash"        -> deny shell-backgrounding (&) and naive "idle==done" pollers
#   PostToolUse matcher "Agent|Task"  -> remind to set a deadline watch for browser/E2E subagents
# Dispatches on hook_event_name + tool_name — one script, three enforcements (shell-& deny + naive
# idle-poller deny + browser-subagent watch reminder). Rationale: cto SKILL §1.4 — don't rely on
# fragile completion signals (shell-& orphan / idle / black-holing auto-notify); these decay as
# prose, so enforce at tool-call time. PreToolUse deny = exit 2 + stderr (shown to the agent);
# PostToolUse reminder = JSON hookSpecificOutput.additionalContext (plain stdout only hits the debug log).
# All-Python (not shell+jq): the job is JSON in / JSON out — the stdlib json module parses arbitrary
# command/prompt content correctly, where shell-regex extraction would be fragile in a guard.
# Fail-open: any parse error exits 0 so a malformed payload never blocks real work.
import sys, json, re


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    event = data.get("hook_event_name", "")
    tool = data.get("tool_name", "")
    ti = data.get("tool_input", {}) or {}

    if event == "PreToolUse" and tool == "Bash":
        cmd = (ti.get("command", "") or "").replace("\n", " ")
        if not cmd:
            return 0
        # (1) trailing shell-& backgrounding -> orphan (no completion callback). Allow && / 2>&1 / quoted &.
        if re.search(r"(^|[^&])&[ \t]*(disown[ \t]*)?$", cmd) or re.search(r"&[ \t]*disown[ \t]*$", cmd):
            sys.stderr.write(
                "DENY: trailing shell & -> ORPHAN (no completion callback; wrapper falsely reports done). "
                "Drop the & and use the Bash tool run_in_background:true instead.\n"
            )
            return 2
        # (2) naive "idle==done" poller: loop + capture-pane + busy/idle grep, concluding from
        #     idle-absence with NO positive-evidence check (git deliverable OR pane Verdict/prompt marker).
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

    if event == "PostToolUse" and tool in ("Agent", "Task"):
        prompt = ti.get("prompt", "") or ""
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

    return 0


if __name__ == "__main__":
    sys.exit(main())
