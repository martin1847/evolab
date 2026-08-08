#!/usr/bin/env python3
"""Replay-corpus gate: real event streams vs the claude projection's terminal verdict.

Why: hermetic fixtures share the implementer's protocol model — a frame class the
model doesn't contain is invisible to both (the false-DONE incident shipped through
a fully green suite exactly this way). Real streams are the independent sample.

Ground truth is STRUCTURAL, independent of the projection code: in a claude stream,
a `task_notification` strictly between a `result` frame and a LATER `system/init`
marks a harness-automatic continuation (no steer involved; a notification trailing
into EOF has no continuation to speak of). At such a result prefix the projection
must read RUNNING — an IDLE there is a false-DONE window on record. At a result
prefix followed by nothing (EOF tail): a success result must read IDLE (DONE has
to stay reachable) and an error result must read ERROR.

Replay window — two modes:
  - EVIDENCE mode: a `<file>.sent-journal` sidecar (offsets + timestamps only, no
    frame bodies; the runtime appends it on every round-state commit) names the
    TRUE production offset for each verdict; violations are hard failures.
  - ADVISORY mode (no sidecar — historical captures): a mid-turn steer rotates the
    window invisibly in the raw stream, so no offset can be reconstructed (cold
    review round 2: per-turn guessing can mask a production false DONE behind
    pre-steer snapshots). The file is replayed per-turn, reported `[unknown]`,
    and NEVER counts as gate-green.

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


def is_sys(frame: dict, subtype: str) -> bool:
    return frame.get("type") == "system" and frame.get("subtype") == subtype


def check_file(d, path: str) -> int:
    # byte-exact lines: offsets handed to the projection must match the file on disk
    with open(path, "rb") as fh:
        raw_lines = fh.readlines()
    parsed: list[tuple[int, dict]] = []
    for i, raw in enumerate(raw_lines):
        text = raw.decode("utf-8", errors="replace").strip()
        if not text:
            continue
        try:
            frame = json.loads(text)
        except json.JSONDecodeError:
            continue
        if isinstance(frame, dict):
            parsed.append((i, frame))
    if not any(f.get("type") in ("result", "assistant") for _i, f in parsed):
        print(f"  [skip] {os.path.basename(path)}: not a claude-shaped stream")
        return 0

    offsets = None
    journal_path = path + ".sent-journal"
    if os.path.isfile(journal_path):
        offsets = []
        try:
            with open(journal_path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    off = json.loads(line).get("offset")
                    if isinstance(off, int):
                        offsets.append(off)
        except (OSError, json.JSONDecodeError, AttributeError):
            offsets = None  # corrupt sidecar = no evidence — drop to advisory

    result_ids = [k for k, (_i, f) in enumerate(parsed) if f.get("type") == "result"]
    violations = 0
    with tempfile.TemporaryDirectory() as tmp:
        events_path = os.path.join(tmp, "events.jsonl")
        sent_path = os.path.join(tmp, "sent")
        for k in result_ids:
            lineno, rframe = parsed[k]
            # auto-continuation requires BOTH: a task_notification after this result
            # and a later init to continue INTO — in that strict order
            auto = False
            seen_note = False
            tail_exists = k + 1 < len(parsed)
            for _j, frame in parsed[k + 1:]:
                if is_sys(frame, "init"):
                    auto = seen_note
                    break
                if is_sys(frame, "task_notification"):
                    seen_note = True
            prefix_end = sum(len(raw) for raw in raw_lines[: lineno + 1])
            if offsets is not None:
                # evidence mode: the latest journalled rotation at or before this prefix
                sent_bytes = max((o for o in offsets if o <= prefix_end), default=0)
            else:
                # advisory mode: this result's own turn (after the most recent init)
                start_line = 0
                for j in range(k - 1, -1, -1):
                    jj, frame = parsed[j]
                    if is_sys(frame, "init"):
                        start_line = jj + 1
                        break
                sent_bytes = sum(len(raw) for raw in raw_lines[:start_line])
            with open(events_path, "wb") as out:
                out.writelines(raw_lines[: lineno + 1])
            with open(sent_path, "w", encoding="utf-8") as out:
                out.write(str(sent_bytes))
            state, _detail = d.project_claude(ReplaySession(events_path, sent_path))
            is_err = bool(rframe.get("is_error"))
            if auto and state != "RUNNING":
                print(f"  VIOLATION {os.path.basename(path)}:{lineno + 1}: result "
                      f"followed by an automatic continuation projects {state}, "
                      "not RUNNING — false-DONE window on record")
                violations += 1
            elif not tail_exists:
                if is_err and state != "ERROR":
                    print(f"  VIOLATION {os.path.basename(path)}:{lineno + 1}: final "
                          f"error result projects {state}, not ERROR")
                    violations += 1
                elif not is_err and state != "IDLE":
                    print(f"  VIOLATION {os.path.basename(path)}:{lineno + 1}: final "
                          f"result projects {state}, not IDLE — DONE unreachable")
                    violations += 1
    checked = len(result_ids)
    if offsets is None:
        print(f"  [unknown] {os.path.basename(path)}: no sent-journal sidecar — "
              f"{checked} prefix(es) replayed per-turn, {violations} suspect(s); "
              "advisory only, not gate evidence")
        return 0
    tag = "[ok]" if not violations else "[FAIL]"
    print(f"  {tag} {os.path.basename(path)}: {checked} result prefix(es) replayed "
          f"at journalled offsets, {violations} violation(s)")
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
