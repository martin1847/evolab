#!/usr/bin/env python3
"""queue-freshness — UserPromptSubmit hook: nudge when docs/DECISION_QUEUE.md is staler than
the newest docs/orchestration/ activity (orchestration moved on, queue didn't follow).

Reminder-only, never blocks: there is no deterministic per-turn "unlogged T2 decision" signal
to gate on, and a pseudo-precise block is worse than a reminder (false denies + the 8-strike
Stop-hook fuse). If T2 interception ever leaves a marker file, this can be upgraded to a gate.

Wiring: entry in ../queue-hooks.json (optional — only for projects that keep a DECISION_QUEUE).
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


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    root = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    queue = os.path.join(root, "docs", "DECISION_QUEUE.md")
    if not os.path.isfile(queue):
        return
    orch_files = [f for f in glob.glob(os.path.join(root, "docs", "orchestration", "**", "*"),
                                       recursive=True) if os.path.isfile(f)]
    if not orch_files:
        return
    newest = max(os.path.getmtime(f) for f in orch_files)
    grace = int(os.environ.get("QUEUE_STALE_GRACE_SECS", "3600"))
    qm = os.path.getmtime(queue)
    if qm + grace >= newest:
        return
    # rate-limit: at most one nag per interval per project
    tag = hashlib.sha256(root.encode()).hexdigest()[:8]
    stamp = os.path.join(tempfile.gettempdir(), f"queue-freshness-nag-{tag}")
    interval = int(os.environ.get("QUEUE_NAG_INTERVAL_SECS", "3600"))
    try:
        if os.path.exists(stamp) and time.time() - os.path.getmtime(stamp) < interval:
            return
        open(stamp, "w").close()
    except OSError:
        pass
    hrs = (newest - qm) / 3600
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": (
            f"⚖️ docs/DECISION_QUEUE.md is {hrs:.1f}h staler than the newest docs/orchestration/ "
            "activity. Refresh it (clear ✅, surface new 🔴 with recommendation + silent default, "
            "re-float due revisit triggers) — or touch it to confirm it is current."
        )}}))


main()
