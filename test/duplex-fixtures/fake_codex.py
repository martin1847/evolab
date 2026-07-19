#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def emit(value: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


log_path = Path(os.environ["FAKE_PROVIDER_LOG"])
active_turn = "turn-1"
turn_count = 1
for line in sys.stdin:
    message = json.loads(line)
    with log_path.open("a", encoding="utf-8") as log:
        log.write(json.dumps(message, separators=(",", ":")) + "\n")
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        emit(
            {
                "id": request_id,
                "result": {"serverInfo": {"name": "fake-codex", "version": "0.144.4"}},
            }
        )
    elif method == "initialized":
        continue
    elif method == "thread/start":
        emit(
            {
                "id": request_id,
                "result": {"thread": {"id": "thread-1", "status": {"type": "idle"}}},
            }
        )
    elif method == "turn/start":
        turn_count += 1
        active_turn = f"turn-{turn_count}"
        emit(
            {
                "id": request_id,
                "result": {
                    "turn": {"id": active_turn, "status": "inProgress", "items": []}
                },
            }
        )
        emit(
            {
                "method": "turn/started",
                "params": {
                    "threadId": "thread-1",
                    "turn": {"id": active_turn, "status": "inProgress", "items": []},
                },
            }
        )
    elif method == "turn/steer":
        emit(
            {
                "id": request_id,
                "result": {"turnId": message["params"]["expectedTurnId"]},
            }
        )
    elif method == "turn/interrupt":
        interrupted = message["params"]["turnId"]
        emit({"id": request_id, "result": {}})
        if os.environ.get("FAKE_CODEX_INTERRUPT_SERVER_REQUEST") == "1":
            emit(
                {
                    "id": "091",
                    "method": "item/commandExecution/requestApproval",
                    "params": {"reason": "approve during interrupt"},
                }
            )
        if os.environ.get("FAKE_CODEX_DROP_INTERRUPT_EVENT") == "1":
            continue
        emit(
            {
                "method": "turn/completed",
                "params": {
                    "threadId": "thread-1",
                    "turn": {"id": interrupted, "status": "interrupted", "items": []},
                },
            }
        )
    elif method == "thread/read":
        emit(
            {
                "id": request_id,
                "result": {
                    "thread": {
                        "id": "thread-1",
                        "status": {"type": "active", "activeFlags": []},
                        "turns": [
                            {"id": active_turn, "status": "inProgress", "items": []}
                        ],
                    }
                },
            }
        )
