#!/usr/bin/env python3
"""Claude lifecycle hook: surface actionable watcher gaps without leaking scan data."""

import json
import subprocess
import sys
from pathlib import Path


EVENTS = {"SessionStart", "UserPromptSubmit"}
REMINDER = "Watcher coverage gap detected. Run agent-watch/rearm and re-arm every listed watcher."


def check_error() -> int:
    sys.stderr.write("CHECKER-ERROR: watcher rearm check failed.\n")
    return 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return check_error()
    if not isinstance(payload, dict) or payload.get("hook_event_name") not in EVENTS:
        return check_error()
    event = payload["hook_event_name"]
    try:
        result = subprocess.run(
            [str(Path(__file__).with_name("rearm"))],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return check_error()
    if result.returncode != 0:
        return check_error()
    actionable = any(
        line.strip() and not line.lstrip().startswith("#")
        for line in result.stdout.splitlines()
    )
    if actionable:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": event,
                    "additionalContext": REMINDER,
                }
            },
            sys.stdout,
        )
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
