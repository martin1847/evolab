#!/usr/bin/env python3
"""Replay-corpus gate: real event streams vs the claude projection's terminal verdict.

Why: hermetic fixtures share the implementer's protocol model — a frame class the
model doesn't contain is invisible to both (the false-DONE incident shipped through
a fully green suite exactly this way). Real streams are the independent sample.

Ground truth is STRUCTURAL, independent of the projection code: in a claude stream,
a `task_notification` between a `result` frame and the next `system/init` marks a
HARNESS-AUTOMATIC continuation (no steer involved). At such a result prefix the
projection must read RUNNING — an IDLE there is a false-DONE window on record.
At a result prefix followed by nothing (EOF tail) the projection must read IDLE:
DONE has to stay reachable. Steer-driven rounds (init with no task_notification
before it) are not judged — steer inputs are not echoed into the events file, so
the stream cannot distinguish them from any other legitimate new round.

Corpus files are REAL streams and may carry sensitive content: the corpus dir is
gitignored/local-only, and this driver prints verdicts + line numbers, never frame
bodies.

Usage: replay-corpus.py <events.jsonl> [...]. Exit 0 all invariants hold, 1 on any
violation, 2 usage/unreadable. Non-claude-shaped files are skipped with a note.
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DUPLEXCTL = os.path.join(
    HERE, "..", "skills", "cto-orchestration", "references", "agentctl", "duplexctl.py")


def load_duplexctl():
    spec = importlib.util.spec_from_file_location("duplexctl", DUPLEXCTL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ReplaySession:
    """Minimal Session stand-in: exactly the attributes project_claude reads."""

    def __init__(self, events_path: str, sent_path: str):
        self.events = events_path
        self.sent_offset = sent_path
        self.meta = {"engine": "claude"}


def check_file(d, path: str) -> int:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    frames = []
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            frames.append((i, None))
            continue
        try:
            frames.append((i, json.loads(line)))
        except json.JSONDecodeError:
            frames.append((i, None))
    parsed = [(i, f) for i, f in frames if isinstance(f, dict)]
    if not any(f.get("type") in ("result", "assistant") for _i, f in parsed):
        print(f"  [skip] {os.path.basename(path)}: not a claude-shaped stream")
        return 0

    result_ids = [k for k, (_i, f) in enumerate(parsed) if f.get("type") == "result"]
    violations = 0
    with tempfile.TemporaryDirectory() as tmp:
        sent_path = os.path.join(tmp, "sent")
        open(sent_path, "w", encoding="utf-8").write("0")
        for k in result_ids:
            lineno = parsed[k][0]
            # continuation window: frames after this result, up to the next system/init
            auto = False
            tail_exists = k + 1 < len(parsed)
            for _j, f in parsed[k + 1:]:
                if f.get("type") == "system" and f.get("subtype") == "init":
                    break
                if f.get("type") == "system" and f.get("subtype") == "task_notification":
                    auto = True
                    break
            events_path = os.path.join(tmp, "events.jsonl")
            with open(events_path, "w", encoding="utf-8") as out:
                out.writelines(lines[: lineno + 1])
            state, _detail = d.project_claude(ReplaySession(events_path, sent_path))
            if auto and state != "RUNNING":
                print(f"  VIOLATION {os.path.basename(path)}:{lineno + 1}: result "
                      f"followed by an automatic continuation projects {state}, "
                      "not RUNNING — false-DONE window on record")
                violations += 1
            elif not tail_exists and state != "IDLE":
                print(f"  VIOLATION {os.path.basename(path)}:{lineno + 1}: final "
                      f"result projects {state}, not IDLE — DONE unreachable")
                violations += 1
    checked = len(result_ids)
    print(f"  [ok] {os.path.basename(path)}: {checked} result prefix(es) replayed, "
          f"{violations} violation(s)" if not violations else
          f"  [FAIL] {os.path.basename(path)}: {violations} violation(s) in "
          f"{checked} result prefix(es)")
    return violations


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: replay-corpus.py <events.jsonl> [...]", file=sys.stderr)
        return 2
    d = load_duplexctl()
    total = 0
    for path in sys.argv[1:]:
        if not os.path.isfile(path):
            print(f"unreadable: {path}", file=sys.stderr)
            return 2
        total += check_file(d, path)
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
