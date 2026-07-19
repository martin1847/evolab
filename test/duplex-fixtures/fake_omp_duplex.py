#!/usr/bin/env python3
"""Scriptable omp --mode=rpc stand-in for hermetic duplex-lane tests.

Env controls:
  FAKE_PROVIDER_LOG        append every received frame (JSON line)
  FAKE_OMP_STATE_FILE      file whose content sets get_state.isStreaming
                           ("streaming" => true, anything else/absent => false)
  FAKE_OMP_DELIVERABLE     path written (with fresh mtime) after each prompt/steer
  FAKE_OMP_ASK=1           emit a real extension_ui_request (confirm) after prompt
Protocol shape mirrors the live probe of omp 17.0.5: ready frame first, a setWidget
extension_ui_request as connect-time UI chrome, correlated response frames.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def emit(value: dict) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def streaming() -> bool:
    state_file = os.environ.get("FAKE_OMP_STATE_FILE")
    if not state_file:
        return False
    try:
        return Path(state_file).read_text(encoding="utf-8").strip() == "streaming"
    except OSError:
        return False


log_path = os.environ.get("FAKE_PROVIDER_LOG")
emit({"type": "ready"})
emit({"type": "extension_ui_request", "id": "ui-widget", "method": "setWidget",
      "widget": {"kind": "statusline"}})
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if log_path:
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(message, separators=(",", ":")) + "\n")
    command = message.get("type")
    request_id = message.get("id")
    if command == "get_state":
        emit({"id": request_id, "type": "response", "command": "get_state",
              "success": True,
              "data": {"isStreaming": streaming(), "isCompacting": False,
                       "sessionId": "fake-omp-1", "messageCount": 2,
                       "queuedMessageCount": 0}})
    elif command in {"prompt", "steer", "follow_up", "abort_and_prompt"}:
        emit({"id": request_id, "type": "response", "command": command, "success": True})
        emit({"type": "agent_start"})
        deliverable = os.environ.get("FAKE_OMP_DELIVERABLE")
        if deliverable:
            with open(deliverable, "a", encoding="utf-8") as fh:
                fh.write("made by fake omp\n")
        if command == "prompt" and os.environ.get("FAKE_OMP_ASK") == "1":
            emit({"type": "extension_ui_request", "id": "ui-q1", "method": "confirm",
                  "title": "Proceed?", "message": "Proceed?"})
        else:
            emit({"type": "agent_end"})
    elif command == "abort":
        emit({"id": request_id, "type": "response", "command": command, "success": True})
        break
