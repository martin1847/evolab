#!/usr/bin/env python3
"""Scriptable `claude -p --input-format stream-json` stand-in for hermetic tests.

For each user message on stdin: emit an assistant frame + a result frame (the turn
boundary marker classify keys on). Env controls:
  FAKE_PROVIDER_LOG          append every received frame
  FAKE_CLAUDE_DELIVERABLE    path written after each user message
  FAKE_CLAUDE_MUTE=1         swallow input, emit nothing (silent-engine scenarios)
  FAKE_CLAUDE_DIE_RC=<n>     exit with rc n after the first user message
  FAKE_CLAUDE_ERROR_RESULT=1 emit an is_error result (failed-turn scenarios)
  FAKE_CLAUDE_GATE=<path>    wait for this file before answering each user message
"""
from __future__ import annotations

import json
import os
import sys
import time


def emit(value: dict) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


log_path = os.environ.get("FAKE_PROVIDER_LOG")
turn = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if log_path:
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(message, separators=(",", ":")) + "\n")
    if message.get("type") != "user":
        continue
    if os.environ.get("FAKE_CLAUDE_MUTE") == "1":
        continue
    gate = os.environ.get("FAKE_CLAUDE_GATE")
    if gate:
        while not os.path.exists(gate):
            time.sleep(0.1)
    turn += 1
    if turn == 1:
        emit({"type": "system", "subtype": "init", "session_id": "fake-claude-1",
              "model": "fake", "tools": []})
    emit({"type": "assistant",
          "message": {"role": "assistant",
                      "content": [{"type": "text", "text": f"working on turn {turn}"}]}})
    deliverable = os.environ.get("FAKE_CLAUDE_DELIVERABLE")
    if deliverable:
        with open(deliverable, "a", encoding="utf-8") as fh:
            fh.write("made by fake claude\n")
    if os.environ.get("FAKE_CLAUDE_ERROR_RESULT") == "1":
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
              "result": "API request failed mid-turn", "session_id": "fake-claude-1"})
    else:
        emit({"type": "result", "subtype": "success", "is_error": False,
              "result": f"turn {turn} complete", "session_id": "fake-claude-1"})
    die_rc = os.environ.get("FAKE_CLAUDE_DIE_RC")
    if die_rc:
        sys.exit(int(die_rc))
