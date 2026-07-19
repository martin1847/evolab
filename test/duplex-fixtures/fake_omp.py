#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

if "--version" in sys.argv:
    version_log = os.environ.get("FAKE_VERSION_LOG")
    if version_log is not None:
        with Path(version_log).open("a", encoding="utf-8") as handle:
            handle.write("version-probe\n")
    print("omp/16.5.2-fake")
    raise SystemExit(0)


def emit(value: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


log_path = Path(os.environ["FAKE_PROVIDER_LOG"])
emit({"type": "ready"})
for line in sys.stdin:
    message = json.loads(line)
    with log_path.open("a", encoding="utf-8") as log:
        log.write(json.dumps(message, separators=(",", ":")) + "\n")
    command = message.get("type")
    request_id = message.get("id")
    if command == "get_state":
        emit(
            {
                "id": request_id,
                "type": "response",
                "command": "get_state",
                "success": True,
                "data": {
                    "isStreaming": False,
                    "isCompacting": False,
                    "steeringMode": "all",
                    "followUpMode": "all",
                    "interruptMode": "immediate",
                    "sessionId": "omp-session-1",
                    "autoCompactionEnabled": True,
                    "messageCount": 0,
                    "queuedMessageCount": 0,
                    "todoPhases": [],
                },
            }
        )
    elif command in {"prompt", "steer", "follow_up", "abort_and_prompt"}:
        emit(
            {"id": request_id, "type": "response", "command": command, "success": True}
        )
        if command == "prompt":
            emit({"type": "agent_start"})
            emit(
                {
                    "type": "extension_ui_request",
                    "id": "ui-1",
                    "method": "confirm",
                    "title": "Continue?",
                    "message": "Continue?",
                }
            )
    elif command == "abort":
        emit(
            {"id": request_id, "type": "response", "command": command, "success": True}
        )
        break
