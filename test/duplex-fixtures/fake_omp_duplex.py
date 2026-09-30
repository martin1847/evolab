#!/usr/bin/env python3
"""Scriptable omp --mode=rpc stand-in for hermetic duplex-lane tests.

Env controls:
  FAKE_PROVIDER_LOG        append every received frame (JSON line)
  FAKE_OMP_STATE_FILE      file whose content sets get_state.isStreaming
                           ("streaming" => true, anything else/absent => false)
  FAKE_OMP_STREAM_RAW      publish this RAW JSON value as get_state.isStreaming instead of a
                           boolean (the broken gauge: `"false"` is a TRUTHY Python string and
                           `0` a falsy one, so a truthiness reader invents a turn or invents
                           an idle out of a reading that never happened)
  FAKE_OMP_QUEUED          integer reported as get_state.queuedMessageCount (default 0)
  FAKE_OMP_DELIVERABLE     path written (with fresh mtime) after each prompt/steer
  FAKE_OMP_ASK=1           emit a real extension_ui_request (confirm) after prompt
  FAKE_OMP_TOOL_FRAMES     path of a SWITCH file: while it exists and is non-empty, every
                           get_state first emits one tool_execution_start +
                           tool_execution_end pair whose args.command is that file's text
                           (shape mirrors the live 2026-09-28 omp stream: type / toolCallId /
                           toolName / args on start, result on end). Delete the file and the
                           seat stops running tools — that is the 坏红 half of every progress
                           fixture pair. Content is SYNTHETIC; no downstream text is copied.
  FAKE_OMP_TOOL_NAME       toolName for those frames (default "bash"; a non-bash name is what
                           the observation-verb filter must not be able to judge)
  FAKE_OMP_TOOL_UPDATE=1   also emit a tool_execution_update between the pair — output
                           arriving INSIDE one call, which this lane must never count
  FAKE_OMP_DELTA_FRAMES=N  after each prompt/steer emit a real-shape streaming run: one
                           text_start, N text_delta (each re-embedding the whole message so
                           far as `partial` — the O(L²) growth the pane filter exists for),
                           one text_end carrying the full `content`. Key order and first
                           bytes mirror the live 2026-09-30 omp stream.
  FAKE_OMP_LINGER_CHILD=1  before exiting, leave a sleeping grandchild holding the inherited
                           stdout: the engine is gone but the pipe's write end is not, which
                           is what the rc file must not wait for. Its argv carries
                           `agentctl-linger:<AGENTCTL_SESSION>` so a test can find and kill
                           ITS OWN child — a bare `sleep 3` is unselectable on a shared box
                           and blanket pattern kills have shot live engines here before
Protocol shape mirrors the live probe of omp 17.0.5: ready frame first, a setWidget
extension_ui_request as connect-time UI chrome, correlated response frames.
"""
from __future__ import annotations

import json
import os
import subprocess
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


def stream_value():
    raw = os.environ.get("FAKE_OMP_STREAM_RAW")
    if raw is None:
        return streaming()
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def queued() -> int:
    """Fixed at engine launch (an env var is copied into the child): export it before start."""
    try:
        return int(os.environ.get("FAKE_OMP_QUEUED", "0"))
    except ValueError:
        return 0


tool_seq = 0
delta_seq = 0


def emit_delta_frames() -> None:
    """One streaming run per prompt/steer: start, N deltas, end.

    `partial` carries the message accumulated SO FAR in every delta (that is the live omp
    behaviour, and why one long message costs O(L²) journal bytes); the terminal text_end
    carries the same text once as `content` — which is why dropping the deltas loses nothing.
    """
    global delta_seq
    try:
        count = int(os.environ.get("FAKE_OMP_DELTA_FRAMES", "0"))
    except ValueError:
        return
    if count <= 0:
        return
    delta_seq += 1
    index = delta_seq
    text = ""
    emit({"type": "message_update",
          "assistantMessageEvent": {"type": "text_start", "contentIndex": index}})
    for n in range(count):
        chunk = f"synthetic chunk {n} "
        text += chunk
        emit({"type": "message_update",
              "assistantMessageEvent": {
                  "type": "text_delta", "contentIndex": index, "delta": chunk,
                  "partial": {"role": "assistant",
                              "content": [{"type": "text", "text": text}]}}})
    emit({"type": "message_update",
          "assistantMessageEvent": {
              "type": "text_end", "contentIndex": index,
              "content": {"type": "text", "text": text},
              "partial": {"role": "assistant",
                          "content": [{"type": "text", "text": text}]}}})


def emit_tool_frames() -> None:
    """One start/end pair per call while the switch file says the seat is running tools.
    Emitted BEFORE the correlated get_state response so the reader has appended them by the
    time the caller's classify reads the stream — a pair that lands after the response would
    be counted one poll late and make every window assertion a race."""
    global tool_seq
    switch = os.environ.get("FAKE_OMP_TOOL_FRAMES")
    if not switch:
        return
    try:
        command = Path(switch).read_text(encoding="utf-8").strip()
    except OSError:
        return
    if not command:
        return
    tool_seq += 1
    call_id = f"toolu_fake{tool_seq:04d}"
    name = os.environ.get("FAKE_OMP_TOOL_NAME", "bash")
    emit({"type": "tool_execution_start", "toolCallId": call_id, "toolName": name,
          "args": {"command": command}})
    if os.environ.get("FAKE_OMP_TOOL_UPDATE") == "1":
        emit({"type": "tool_execution_update", "toolCallId": call_id, "toolName": name,
              "delta": {"content": [{"type": "text", "text": "partial output"}]}})
    emit({"type": "tool_execution_end", "toolCallId": call_id, "toolName": name,
          "result": {"content": [{"type": "text", "text": "synthetic tool output"}]}})


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
        emit_tool_frames()
        if os.environ.get("FAKE_OMP_BAD_STATE") == "1":
            emit({"id": request_id, "type": "response", "command": "get_state",
                  "success": False, "error": "internal state error"})
            continue
        emit({"id": request_id, "type": "response", "command": "get_state",
              "success": True,
              "data": {"isStreaming": stream_value(), "isCompacting": False,
                       "sessionId": "fake-omp-1", "messageCount": 2,
                       "queuedMessageCount": queued()}})
    elif command in {"prompt", "steer", "follow_up", "abort_and_prompt"}:
        emit({"id": request_id, "type": "response", "command": command, "success": True})
        emit({"type": "agent_start"})
        emit_delta_frames()
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

if os.environ.get("FAKE_OMP_LINGER_CHILD") == "1":
    # the engine is about to die while a grandchild still holds the inherited stdout: the rc
    # file must land on the ENGINE's exit, never on the pipe reader's EOF
    seat = os.environ.get("AGENTCTL_SESSION", "noseat")
    # the trailing `: marker` is load-bearing: with `sleep` as the LAST command the shell
    # exec()s it away and the argv marker (the only safe selector) disappears with it.
    # `/bin/sleep`, not `sleep`: the testkit's PATH carries a no-op `sleep` (so the waiter's
    # backoff loops are instant) and it reaches this child through the inherited env — the
    # grandchild then dies at once and T6's "pipe still held" is decided by a startup race
    # (won on macOS, lost on Linux CI, run 36713365254)
    subprocess.Popen(["/bin/sh", "-c", f"/bin/sleep 3; : agentctl-linger:{seat}"])
