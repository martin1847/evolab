#!/usr/bin/env python3
# cto-guard-bash — PreToolUse·Bash enforcement for cto-orchestration. Wire to the Bash matcher
# (CC skill frontmatter `hooks:` / `.claude/settings.json`; Codex `hooks.json`). Catches three Bash
# slips the orchestrator keeps making (prose decays → enforce at tool-call time):
#   (1) trailing shell `&` -> ORPHAN (no completion callback; wrapper falsely reports done)  [DENY]
#   (2) naive "idle==done" poller (loop + capture-pane + idle grep, no positive-evidence check) [DENY]
#   (3) `dispatch <agent> <session>` WITHOUT later arming `watch <session>` -> reminder to arm the
#       watcher (the PRIMARY signal). This is an OMISSION, not a bad action -> can't DENY (there is no
#       tool call to intercept); inject salience at dispatch time instead, same doctrine as the
#       PostToolUse·Agent browser reminder (sibling cto-guard-agent.py). [ALLOW + additionalContext]
# Deny = exit 2 + stderr (shown to the agent). Remind = exit 0 + JSON hookSpecificOutput.additionalContext
# (only that reaches the agent). Fail-open: any parse error exits 0, never blocks work. All-Python: the
# job is parsing arbitrary command content out of hook JSON — stdlib json is correct where shell-regex
# extraction would be fragile in a guard.
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

    # (1) shell-& backgrounding -> orphan. Catches a background `&` at the end of ANY line (re.MULTILINE),
    #     or followed by `disown` / `;` — so it fires on the TRAILING form AND the mid-command form
    #     `foo & \n more` / `foo & disown; more` / `foo & ; more` (a mid-string `&` launches a detached
    #     job the orchestrator can't track; observed twice self-inflicted). `[^&>]` before the `&` keeps
    #     `&&` chains, `2>&1` / `N>&M` / `&>` redirects, and quoted-then-text `&` allowed.
    if re.search(r"(^|[^&>])&[ \t]*(disown\b|;|$)", cmd, re.MULTILINE):
        sys.stderr.write(
            "DENY: shell & backgrounding -> ORPHAN (no completion callback; the orchestrator can't track "
            "it and the wrapper falsely reports done). This includes a mid-command `& \\n ...` / `& disown` "
            "/ `& ;`, not just a trailing &. Drop the & and use the Bash tool run_in_background:true instead.\n"
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

    # (3) dispatch -> remind to arm watch. `dispatch <omp|codex|claude> <session> [cwd]` starts a tmux
    #     agent; arming `watch <session>` (the primary, hook-driven signal) is a SEPARATE step the
    #     orchestrator owns (Claude Code must background it via run_in_background — NOT shell &, which
    #     orphans) -> easy to skip -> silent timer-guessing displaces the proper signal. Allow, but
    #     inject the reminder so the omission can't pass silently. Don't fire if `watch <session>` is
    #     already in the same command line.
    m = re.search(r"\bdispatch[\"'\s]+(omp|codex|claude)[\"'\s]+([^\s\"';|&]+)", cmd)
    if m:
        session = m.group(2)
        if not re.search(r"\bwatch[\"'\s]+" + re.escape(session) + r"\b", cmd):
            ctx = (
                f"REMINDER (cto-guard): you are dispatching tmux session '{session}'. Arm the watcher "
                f"as the PRIMARY signal right after it starts — run `bash <agent-watch>/watch {session}` "
                f"via the Bash tool with run_in_background:true (NOT shell &, which orphans it). A "
                f"ScheduleWakeup timer is only the BACKSTOP, not a substitute for the watcher."
            )
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": ctx,
                }
            }))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
