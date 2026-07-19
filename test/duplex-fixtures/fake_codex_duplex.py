#!/usr/bin/env python3
"""Scriptable `codex app-server` stand-in (v1 param shapes, spike-verified vocab).

JSON-RPC over stdio. Env controls:
  FAKE_PROVIDER_LOG        append every received frame
  FAKE_CODEX_DELIVERABLE   path written during each turn
  FAKE_CODEX_GATE=<path>   turn stays ACTIVE until this file exists (steer window)
  FAKE_CODEX_ERROR_TURN=1  complete turns with status=failed + error
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time

emit_lock = threading.Lock()
state = {"active": None, "turns": 0, "cancelled": set()}


def emit(value: dict) -> None:
    with emit_lock:
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def complete_turn(tid: str, interrupted: bool = False) -> None:
    gate = os.environ.get("FAKE_CODEX_GATE")
    if gate and not interrupted:
        while not os.path.exists(gate):
            if tid in state["cancelled"]:
                return  # interrupt already emitted this turn's single terminal
            time.sleep(0.1)
    if tid in state["cancelled"] and not interrupted:
        return
    deliverable = os.environ.get("FAKE_CODEX_DELIVERABLE")
    if deliverable and not interrupted:
        with open(deliverable, "a", encoding="utf-8") as fh:
            fh.write("made by fake codex\n")
    if interrupted:
        turn = {"id": tid, "status": "interrupted", "error": None, "items": []}
    elif os.environ.get("FAKE_CODEX_ERROR_TURN") == "1":
        turn = {"id": tid, "status": "failed", "error": {"message": "boom"}, "items": []}
    else:
        emit({"method": "item/completed",
              "params": {"threadId": "thread-1",
                         "item": {"id": f"item-{tid}", "phase": "final_answer",
                                  "text": f"{tid} complete"}}})
        turn = {"id": tid, "status": "completed", "error": None, "items": []}
    if state["active"] == tid:
        state["active"] = None
    emit({"method": "turn/completed", "params": {"threadId": "thread-1", "turn": turn}})


log_path = os.environ.get("FAKE_PROVIDER_LOG")
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if log_path:
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(message, separators=(",", ":")) + "\n")
    method = message.get("method")
    req_id = message.get("id")
    if method == "initialize":
        emit({"id": req_id, "result": {"userAgent": "fake-codex/0.144.5"}})
    elif method == "initialized":
        continue
    elif method == "thread/start":
        emit({"id": req_id, "result": {"thread": {"id": "thread-1"}}})
    elif method == "thread/resume":
        emit({"id": req_id,
              "result": {"thread": {"id": message["params"]["threadId"]}}})
    elif method == "turn/start":
        if state["active"] is not None:
            emit({"id": req_id, "error": {"code": -32600, "message": "turn already active"}})
            continue
        state["turns"] += 1
        tid = f"turn-{state['turns']}"
        state["active"] = tid
        emit({"id": req_id, "result": {"turn": {"id": tid}}})
        emit({"method": "turn/started",
              "params": {"threadId": "thread-1", "turn": {"id": tid, "status": "inProgress"}}})
        if os.environ.get("FAKE_CODEX_SUBTHREAD_NOISE") == "1":
            # engine-internal sub-agent traffic multiplexed onto the same stream
            emit({"method": "turn/started",
                  "params": {"threadId": "thread-sub", "turn": {"id": "sub-1", "status": "inProgress"}}})
            emit({"method": "turn/completed",
                  "params": {"threadId": "thread-sub",
                             "turn": {"id": "sub-1", "status": "completed", "error": None}}})
        threading.Thread(target=complete_turn, args=(tid,), daemon=True).start()
    elif method == "turn/steer":
        expected = message["params"].get("expectedTurnId")
        if state["active"] is None or expected != state["active"]:
            emit({"id": req_id, "error": {"code": -32600, "message": "no active turn to steer"}})
        else:
            emit({"id": req_id, "result": {"turnId": expected}})
    elif method == "turn/interrupt":
        tid = message["params"].get("turnId")
        if state["active"] is None:
            emit({"id": req_id, "error": {"code": -32600, "message": "no active turn"}})
        else:
            state["cancelled"].add(tid)
            emit({"id": req_id, "result": {}})
            complete_turn(tid, interrupted=True)
    else:
        emit({"id": req_id, "error": {"code": -32600, "message": f"unknown method {method}"}})
