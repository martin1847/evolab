#!/usr/bin/env python3
"""queue-freshness — SessionStart/UserPromptSubmit hook for DECISION_QUEUE hygiene.

It surfaces two deterministic conditions:
1. entries remain under the cleared-history section and must never be rehydrated as active work;
2. docs/DECISION_QUEUE.md is staler than the newest docs/orchestration/ activity.

Reminder-only, never blocks: there is no deterministic per-turn "unlogged T2 decision" signal
to gate on, and a pseudo-precise block is worse than a reminder (false denies + the 8-strike
Stop-hook fuse). If T2 interception ever leaves a marker file, this can be upgraded to a gate.

Wiring: entries in ../queue-hooks.json (optional — only for projects that keep a DECISION_QUEUE).
Env: QUEUE_STALE_GRACE_SECS (default 3600), QUEUE_NAG_INTERVAL_SECS (default 3600).
Exit 0 always; speaks via hookSpecificOutput.additionalContext (system-reminder channel —
plain stdout is NOT reliably shown to the model for non-blocking hooks).
"""
import glob
import hashlib
import json
import os
import sys
import tempfile
import time


def has_cleared_history(queue):
    """True when the legacy/empty CLEARED section still contains meaningful content."""
    try:
        lines = open(queue, encoding="utf-8").read().splitlines()
    except OSError:
        return False
    inside = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("## "):
            if inside:
                return False
            upper = stripped.upper()
            inside = "✅" in stripped and ("CLEARED" in upper or "已清" in stripped)
            continue
        if inside and stripped and not stripped.startswith("<!--"):
            return True
    return False


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    root = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    queue = os.path.join(root, "docs", "DECISION_QUEUE.md")
    if not os.path.isfile(queue):
        return
    event = data.get("hook_event_name") or "UserPromptSubmit"
    issues = []
    if has_cleared_history(queue):
        issues.append(
            "DECISION_QUEUE.md still contains entries under its cleared-history section. "
            "Treat every one as CLOSED and never rehydrate it into active work. Remove those "
            "entries before handoff/compact; git history is the audit trail."
        )
    orch_files = [f for f in glob.glob(os.path.join(root, "docs", "orchestration", "**", "*"),
                                       recursive=True) if os.path.isfile(f)]
    if orch_files:
        newest = max(os.path.getmtime(f) for f in orch_files)
        grace = int(os.environ.get("QUEUE_STALE_GRACE_SECS", "3600"))
        qm = os.path.getmtime(queue)
        if qm + grace < newest:
            hrs = (newest - qm) / 3600
            issues.append(
                f"DECISION_QUEUE.md is {hrs:.1f}h staler than the newest docs/orchestration/ "
                "activity. Refresh active decisions and re-float due revisit triggers."
            )
    if not issues:
        return
    # A new/resumed/compacted context must always see hygiene state. Mid-session prompts are
    # rate-limited to avoid repeated noise.
    tag = hashlib.sha256(root.encode()).hexdigest()[:8]
    stamp = os.path.join(tempfile.gettempdir(), f"queue-freshness-nag-{tag}")
    interval = int(os.environ.get("QUEUE_NAG_INTERVAL_SECS", "3600"))
    if event == "UserPromptSubmit":
        try:
            if os.path.exists(stamp) and time.time() - os.path.getmtime(stamp) < interval:
                return
            open(stamp, "w").close()
        except OSError:
            pass
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": event,
        "additionalContext": "⚖️ " + " ".join(issues)
    }}))


main()
