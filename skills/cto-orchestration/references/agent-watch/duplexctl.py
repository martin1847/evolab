#!/usr/bin/env python3
"""duplexctl — frame builder + state projector for the agentctl duplex lane.

stdlib only, no daemon. One long-lived engine process per session runs under a
tmux supervisor pane:  bash -c 'exec 3<>IN.FIFO; ENGINE <&3 >> EVENTS 2>> ERR; echo $? > RC'
This tool is the ONLY writer to the fifo (flock-serialized) and the only reader
that interprets EVENTS. It never touches the pane; terminal truth is the typed
exit code (same vocabulary as the round lane):
  0 DONE / 2 FAILED|AGENT-DEAD / 4 WAITING-INPUT / 5 STALLED-EXTERNAL
  / 6 IDLE-NO-DELIVERABLE / 10 RUNNING
Output is BOUNDED by design: raw engine output stays in EVENTS; classify prints
one typed line + a <=600-char summary (the 147KB single-line agent_end replay
going into the orchestrator context was a field-reported token bomb).

Engines (one uniform surface; an impl that lacks a capability REFUSES cleanly —
Java-interface style — instead of silently degrading):
  omp    : --mode=rpc JSON-lines. prompt/steer(follow_up)/steer-now(steer)/
           replace(abort_and_prompt); get_state for live status.
  claude : -p --input-format stream-json. steer = natively queued to the next
           turn; --now degrades to queued (told); --replace refused (stop+resume).
  codex  : app-server JSON-RPC (spike-verified 2026-07-19 on 0.144.5, v1 param
           shapes). steer default = NEXT turn only (no queue: busy → refuse,
           idle → turn/start); --now = native mid-turn turn/steer{expectedTurnId};
           --replace = turn/interrupt + turn/start. threadId persisted in meta.
"""
from __future__ import annotations

import argparse
import fcntl
import glob as globmod
import json
import os
import select
import subprocess
import sys
import time
import uuid

SUMMARY_CHARS = 600


# ── session file layout ───────────────────────────────────────────────────────
class Session:
    def __init__(self, run_dir: str, name: str):
        self.run = run_dir
        self.name = name
        self.meta_path = os.path.join(run_dir, f"{name}.duplex.meta")
        self.fifo = os.path.join(run_dir, f"{name}.duplex.in")
        self.events = os.path.join(run_dir, f"{name}.duplex.events.jsonl")
        self.stderr = os.path.join(run_dir, f"{name}.duplex.stderr.log")
        self.rc = os.path.join(run_dir, f"{name}.duplex.rc")
        self.epoch = os.path.join(run_dir, f"{name}.duplex.round-started")
        self.wlock = os.path.join(run_dir, f"{name}.duplex.wlock")
        self.sent_offset = os.path.join(run_dir, f"{name}.duplex.sent-offset")
        self.intent = os.path.join(run_dir, f"{name}.duplex.write-intent")
        self.meta = {}
        if os.path.exists(self.meta_path):
            with open(self.meta_path, encoding="utf-8") as fh:
                for line in fh:
                    if "=" in line:
                        key, _, value = line.partition("=")
                        self.meta[key.strip()] = value.rstrip("\n")

    def require_meta(self) -> None:
        if not self.meta:
            die(f"unknown duplex session '{self.name}' (no {self.meta_path})")


def meta_update(sess: Session, key: str, value: str) -> None:
    lines = [ln for ln in open(sess.meta_path, encoding="utf-8")
             if not ln.startswith(f"{key}=")] if os.path.exists(sess.meta_path) else []
    lines.append(f"{key}={value}\n")
    tmp = sess.meta_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.replace(tmp, sess.meta_path)
    sess.meta[key] = value


def check_review_budget(sess: Session, text: str) -> None:
    """review-loop stop-loss, ported from the round lane: each prompt/steer is a
    round; the budget and the SHIP-BLOCKING continuation lease live in meta."""
    if sess.meta.get("workflow") != "review-loop":
        return
    round_n = int(sess.meta.get("round", "0"))
    max_rounds = int(sess.meta.get("max_rounds", "0"))
    if round_n >= max_rounds:
        print(f"BUDGET-EXHAUSTED: review-loop '{sess.name}' reached max-rounds={max_rounds} (current round={round_n})",
              file=sys.stderr)
        sys.exit(9)
    if round_n >= 2 and not any(l.startswith("SHIP-BLOCKING:") and l.split(":", 1)[1].strip()
                                for l in text.splitlines()):
        die(f"review-loop continuation lease missing for round {round_n + 1}; add an independent "
            "'SHIP-BLOCKING: <non-empty rationale>' line to the message/brief")


def die(msg: str, code: int = 1) -> None:
    print(f"ERR: {msg}", file=sys.stderr)
    sys.exit(code)


def tmux_alive(name: str) -> bool:
    probe = subprocess.run(
        ["tmux", "has-session", "-t", name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return probe.returncode == 0


def clip(text: str, limit: int = SUMMARY_CHARS) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


# ── frames ────────────────────────────────────────────────────────────────────
def jsonrpc(req_id, method: str, params=None) -> str:
    frame = {"jsonrpc": "2.0", "method": method}
    if req_id is not None:
        frame["id"] = req_id
    if params is not None:
        frame["params"] = params
    return json.dumps(frame, ensure_ascii=False)


def codex_request(sess: Session, method: str, params, timeout: float = 20.0,
                  on_ready=None):
    """One correlated JSON-RPC round trip through the fifo/events pipeline."""
    req_id = f"ctl-{uuid.uuid4().hex[:12]}"
    offset = events_size(sess)
    write_frame(sess, jsonrpc(req_id, method, params), on_ready=on_ready)
    return wait_for(
        sess, offset,
        lambda f: f.get("id") == req_id and ("result" in f or "error" in f),
        timeout)


def codex_text_input(text: str) -> list:
    return [{"type": "text", "text": text}]


def codex_active_turn(sess: Session):
    """Latest turn/started without a later matching turn/completed (whole file:
    turn ids are engine truth, not steer-relative)."""
    active = None
    for frame in complete_frames_from(sess, 0):
        method = frame.get("method")
        turn = (frame.get("params") or {}).get("turn") or {}
        if method == "turn/started":
            active = turn.get("id")
        elif method == "turn/completed" and turn.get("id") == active:
            active = None
    return active



def build_frame(engine: str, verb: str, text: str, req_id: str) -> str:
    if engine == "omp":
        omp_type = {
            "prompt": "prompt", "steer": "follow_up", "steer-now": "steer",
            "replace": "abort_and_prompt", "get-state": "get_state",
        }.get(verb)
        if omp_type is None:
            die(f"unsupported omp verb: {verb}")
        frame = {"id": req_id, "type": omp_type}
        if omp_type != "get_state":
            frame["message"] = text
        return json.dumps(frame, ensure_ascii=False)
    if engine == "claude":
        if verb not in ("prompt", "steer", "steer-now"):
            die(f"unsupported claude verb: {verb} (no public interrupt/replace frame)")
        return json.dumps(
            {"type": "user",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": text}]}},
            ensure_ascii=False)
    die(f"unknown duplex engine: {engine}")
    raise AssertionError  # unreachable


def write_frame(sess: Session, frame: str, on_ready=None) -> None:
    """flock-serialized fifo write. O_NONBLOCK open doubles as a liveness probe
    (ENXIO = nothing holds the read end = supervisor pane is gone) and STAYS on
    for the write loop: a blocking write() of a large frame could hang forever on
    an engine that stopped reading, and POSIX allows short writes above PIPE_BUF —
    so we loop a memoryview with select() under one hard deadline instead.
    `on_ready` runs after the reader is confirmed and BEFORE the first byte: the
    round state (epoch/sent-offset) must not change when delivery cannot even
    start, and must be committed once bytes begin to flow."""
    payload = memoryview(frame.encode("utf-8") + b"\n")
    with open(sess.wlock, "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        fd = None
        deadline = time.monotonic() + 5.0  # pane opens the fifo asynchronously at launch
        while fd is None:
            try:
                fd = os.open(sess.fifo, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as exc:
                if time.monotonic() >= deadline:
                    die(f"fifo has no reader ({exc.strerror}) — engine/pane dead? see status")
                time.sleep(0.1)
        try:
            if on_ready is not None:
                on_ready()
            # durable write-intent: created before the first byte, removed only after
            # the full frame (incl. newline) is out. A sender killed mid-write leaves
            # it behind, and every later send/classify fails closed on it instead of
            # stacking frames onto a torn protocol stream (review R2 2026-07-19).
            with open(sess.intent, "w", encoding="utf-8") as fh:
                fh.write(f"{len(payload)}\n")
            sent = 0
            write_deadline = time.monotonic() + 30.0
            while sent < len(payload):
                try:
                    sent += os.write(fd, payload[sent:sent + 65536])
                except BlockingIOError:
                    remaining = write_deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    select.select([], [fd], [], min(remaining, 1.0))
                    continue
                except (BrokenPipeError, OSError) as exc:
                    if sent == 0:
                        os.unlink(sess.intent)
                        die(f"fifo write failed before any byte ({exc}) — engine died; see status")
                    die(f"fifo write failed mid-frame ({exc}) after {sent}/{len(payload)} bytes "
                        "— frame is TORN, input stream tainted: agentctl stop, then restart "
                        "with the engine's resume args", 2)
                if time.monotonic() >= write_deadline:
                    break
            if sent < len(payload):
                die(f"engine stopped draining the fifo mid-frame ({sent}/{len(payload)} bytes in 30s) "
                    "— frame is TORN, session input stream is tainted: agentctl stop, then restart "
                    "with the engine's resume args", 2)
            os.unlink(sess.intent)
        finally:
            os.close(fd)


def events_size(sess: Session) -> int:
    try:
        return os.path.getsize(sess.events)
    except OSError:
        return 0


def read_events_from(sess: Session, offset: int) -> list[dict]:
    frames = []
    try:
        with open(sess.events, encoding="utf-8", errors="replace") as fh:
            fh.seek(offset)
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    frames.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return frames


def wait_for(sess: Session, offset: int, predicate, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for frame in read_events_from(sess, offset):
            if predicate(frame):
                return frame
        time.sleep(0.2)
    return None


def complete_frames_from(sess: Session, offset: int) -> list[dict]:
    """Frames from COMPLETE lines only, starting at a byte offset. A trailing
    line without a newline is still being written — never consumed as state.
    If the offset lands mid-line (engine was mid-write when the offset was
    recorded), the partial head line is skipped."""
    frames = []
    try:
        with open(sess.events, "rb") as fh:
            if offset > 0:
                fh.seek(offset - 1)
                if fh.read(1) != b"\n":
                    fh.readline()  # skip the partial line the offset landed in
            blob = fh.read()
    except OSError:
        return []
    body, nl, _tail = blob.rpartition(b"\n")
    if not nl:
        return []
    for line in body.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            frames.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return frames


# ── tail window parsing (pending-question scan only — NOT state truth) ────────
def tail_frames(sess: Session, window: int = 262144) -> list[dict]:
    size = events_size(sess)
    if size == 0:
        return []
    start = max(0, size - window)
    frames = []
    with open(sess.events, "rb") as fh:
        fh.seek(start)
        blob = fh.read().decode("utf-8", errors="replace")
    lines = blob.splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # first line is likely torn
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            frames.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return frames


QUOTA_RE = ("insufficient_quota", "invalid_api_key", "No API key",
            "credit balance", "billing")
# omp pushes a setWidget extension_ui_request at connect: UI chrome, not a question.
UI_NOISE_METHODS = {"setWidget", "set_widget"}


def deliverable_fresh(sess: Session) -> tuple[bool, str]:
    """Gate matched fresh this round? Glob resolves RELATIVE TO THE SESSION CWD
    (a relative glob evaluated in the watcher's own cwd was the root cause of a
    field false-negative: file existed, gate said no). mtime compare is float
    (ns) — no same-second cliff."""
    pattern = sess.meta.get("deliverable", "")
    if not pattern:
        return True, ""
    cwd = sess.meta.get("cwd", ".")
    if not os.path.isabs(pattern):
        pattern = os.path.join(cwd, pattern)
    try:
        epoch_mtime = os.path.getmtime(sess.epoch)
    except OSError:
        epoch_mtime = 0.0
    for path in globmod.glob(pattern):
        try:
            if os.path.getmtime(path) >= epoch_mtime:
                return True, path
        except OSError:
            continue
    return False, pattern


def scan_quota(sess: Session) -> bool:
    for path in (sess.stderr, sess.events):
        try:
            with open(path, "rb") as fh:
                fh.seek(max(0, os.path.getsize(path) - 16384))
                blob = fh.read().decode("utf-8", errors="replace")
        except OSError:
            continue
        if any(marker in blob for marker in QUOTA_RE):
            return True
    return False


# ── per-engine idle/waiting projection ────────────────────────────────────────
def project_omp(sess: Session) -> tuple[str, str]:
    """Returns (state, detail): state in RUNNING|IDLE|WAITING. Live-queries
    get_state through the fifo (documented verb; request-response closes over
    the events file)."""
    offset = events_size(sess)
    req_id = f"ctl-{uuid.uuid4().hex[:12]}"
    write_frame(sess, build_frame("omp", "get-state", "", req_id))
    reply = wait_for(
        sess, offset,
        lambda f: f.get("id") == req_id and f.get("type") == "response",
        timeout=6.0)
    if reply is None:
        return "RUNNING", "get_state unanswered in 6s (engine busy or wedged; MAX_POLLS bounds this)"
    # a rejected/malformed response must stay NON-terminal — mapping it to idle
    # would manufacture a false DONE out of an engine error
    if reply.get("command") != "get_state" or reply.get("success") is not True \
            or not isinstance(reply.get("data"), dict):
        return "RUNNING", f"get_state anomalous response (kept non-terminal): {clip(json.dumps(reply, ensure_ascii=False), 200)}"
    data = reply["data"]
    if data.get("isStreaming") or data.get("isCompacting"):
        return "RUNNING", f"streaming, queued={data.get('queuedMessageCount', 0)}"
    if data.get("queuedMessageCount"):
        return "RUNNING", "idle but messages queued"
    # idle: is there an unanswered real question? (setWidget chrome ignored)
    pending = None
    for frame in tail_frames(sess):
        ftype = frame.get("type")
        if ftype == "extension_ui_request" and frame.get("method") not in UI_NOISE_METHODS:
            pending = frame
        elif ftype in ("extension_ui_response", "agent_start"):
            pending = None
    if pending is not None:
        return "WAITING", clip(json.dumps(pending, ensure_ascii=False), 200)
    return "IDLE", "isStreaming=false, queue empty"


def project_claude(sess: Session) -> tuple[str, str]:
    # State comes ONLY from complete frames that landed AFTER the last steer:
    # a queued steer consumed at the next turn boundary leaves the PREVIOUS
    # turn's result frame in the file — reading the raw tail turned that into a
    # false DONE the instant after a steer was delivered, and a torn/oversized
    # tail line could resurrect it even past a size guard.
    try:
        sent = int(open(sess.sent_offset, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        sent = 0
    frames = complete_frames_from(sess, sent)
    if not frames:
        if events_size(sess) <= sent:
            return "RUNNING", "no output since last steer (engine silent so far)"
        return "RUNNING", "output started, no complete frame yet"
    last = frames[-1]
    if last.get("type") == "result":
        summary = clip(str(last.get("result", "")))
        if last.get("is_error"):
            # ANY error result is a FAILED turn — projecting it to DONE manufactures
            # false success (review S1), and a prose keyword like "permission" is NOT
            # a structured ask frame ("Permission denied" on a file is an error, not a
            # question — review R2). Interactive asks ride BLOCKED.md instead.
            return "ERROR", summary or "result is_error=true"
        return "IDLE", summary or last.get("subtype", "result")
    return "RUNNING", f"last frame type={last.get('type')}"


CODEX_ASK_METHODS = ("requestApproval", "requestUserInput", "elicitation")


def project_codex(sess: Session) -> tuple[str, str]:
    try:
        sent = int(open(sess.sent_offset, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        sent = 0
    frames = complete_frames_from(sess, sent)
    if not frames:
        if events_size(sess) <= sent:
            return "RUNNING", "no output since last steer (engine silent so far)"
        return "RUNNING", "output started, no complete frame yet"
    last_completed = None
    started_after_completed = False
    pending_ask = None
    answer_text = ""
    for frame in frames:
        method = frame.get("method", "")
        params = frame.get("params") or {}
        if method == "turn/started":
            started_after_completed = True
        elif method == "turn/completed":
            last_completed = params.get("turn") or {}
            started_after_completed = False
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("phase") == "final_answer" and item.get("text"):
                answer_text = item["text"]
        if frame.get("id") is not None and any(m in method for m in CODEX_ASK_METHODS):
            pending_ask = frame
    if pending_ask is not None:
        return "WAITING", clip(json.dumps(pending_ask, ensure_ascii=False), 200)
    if started_after_completed or last_completed is None:
        return "RUNNING", "turn in progress"
    status = last_completed.get("status")
    err = last_completed.get("error")
    if err or status not in ("completed",):
        return "ERROR", clip(f"turn status={status} error={err}")
    return "IDLE", clip(answer_text) or "turn completed"


def classify(sess: Session) -> int:
    sess.require_meta()
    engine = sess.meta.get("engine", "")
    cwd = sess.meta.get("cwd", ".")

    # 1. engine process exited? (the pane shell writes RC on engine exit)
    if os.path.exists(sess.rc):
        try:
            rc = open(sess.rc, encoding="utf-8").read().strip()
        except OSError:
            rc = "?"
        if rc != "0" and scan_quota(sess):
            print(f"STALLED-EXTERNAL: engine exited rc={rc} on a backend quota/auth error — fix credentials, then agentctl stop + restart")
            return 5
        if rc == "0":
            ok, hit = deliverable_fresh(sess)
            if ok:
                note = f", deliverable fresh: {hit}" if hit else ""
                print(f"DONE: engine exited rc=0{note} (duplex engines normally stay alive — treat as complete)")
                return 0
            print(f"IDLE-NO-DELIVERABLE: engine exited rc=0 but '{sess.meta.get('deliverable')}' not produced this round")
            return 6
        print(f"FAILED: engine exited rc={rc} — tail {sess.events} / {sess.stderr} (raw kept on disk)")
        return 2

    # 2. supervisor pane gone without an rc = killed mid-flight
    if not tmux_alive(sess.name):
        print("AGENT-DEAD: no rc and no tmux session — killed mid-flight; agentctl stop to clean, then restart")
        return 2

    # 2.5 torn input stream: a sender died mid-frame — nothing downstream is trustworthy
    if os.path.exists(sess.intent):
        print("FAILED: torn frame on the input stream (write-intent marker) — agentctl stop, then restart with resume args")
        return 2

    # 3. agent-declared blocker (cross-engine ask-user protocol)
    blocked = os.path.join(cwd, "BLOCKED.md")
    try:
        if os.path.getmtime(blocked) >= os.path.getmtime(sess.epoch):
            print(f"WAITING-INPUT: agent wrote BLOCKED.md — read it, answer via agentctl steer")
            return 4
    except OSError:
        pass

    # 4. live projection
    projector = {"omp": project_omp, "claude": project_claude, "codex": project_codex}[engine]
    state, detail = projector(sess)
    if state == "WAITING":
        print(f"WAITING-INPUT: {detail}")
        return 4
    if state == "ERROR":
        if scan_quota(sess):
            print(f"STALLED-EXTERNAL: turn failed on backend quota/auth — fix credentials, then steer to retry. {detail}")
            return 5
        print(f"FAILED: engine reported an error result (turn failed, engine still alive) — {detail}")
        return 2
    if state == "RUNNING":
        print(f"RUNNING: {detail}")
        return 10
    ok, hit = deliverable_fresh(sess)
    if not ok:
        print(f"IDLE-NO-DELIVERABLE: engine idle but '{sess.meta.get('deliverable')}' not produced this round — steer the agent; do not stop")
        return 6
    note = f", deliverable fresh: {os.path.basename(hit)}" if hit else ""
    print(f"DONE: engine idle{note}")
    print(f"last: {detail}")
    return 0


# ── commands ──────────────────────────────────────────────────────────────────
def cmd_send(args: argparse.Namespace) -> int:
    sess = Session(args.run_dir, args.session)
    sess.require_meta()
    engine = sess.meta["engine"]
    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = args.text or ""
    if args.verb != "get-state" and not text.strip():
        die("empty message")
    if os.path.exists(sess.rc):
        die(f"engine already exited (rc file present) — agentctl status {sess.name}")
    if os.path.exists(sess.intent):
        die("a previous frame write died mid-stream (write-intent marker present) — the "
            "engine's input stream is tainted: agentctl stop, then restart with resume args", 2)
    if args.verb in ("prompt", "steer", "steer-now", "replace"):
        check_review_budget(sess, text)
    if engine == "claude" and args.verb == "replace":
        # degrading replace to a queued steer would silently keep the doomed turn
        # running — refuse and route the operator to the honest path instead
        die("claude has no interrupt/replace frame — `agentctl stop` the session, then "
            "restart with `--resume <session_id>` (engine args) and the new goal")
    if engine == "claude" and args.verb == "steer-now":
        print("note: claude has no public interrupt frame — delivering as queued steer (lands at the next turn boundary)")
        args.verb = "steer"
    offset_box = {}

    def commit_round_state():
        # runs under the writer flock, after the reader is confirmed, before the
        # first byte: a steer whose delivery cannot start must NOT rotate the
        # deliverable epoch or move the sent-offset (stale-gate + phantom
        # ENGINE-SILENT otherwise, review S2 2026-07-19)
        if args.verb in ("prompt", "steer", "steer-now", "replace"):
            with open(sess.epoch, "a", encoding="utf-8"):
                os.utime(sess.epoch, None)
            meta_update(sess, "round", str(int(sess.meta.get("round", "0")) + 1))
            offset_box["v"] = events_size(sess)
            # atomic replace: an in-place truncate gave lock-free classify a window
            # where the offset read as empty → 0 → an old result revived as DONE
            tmp = sess.sent_offset + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(str(offset_box["v"]))
            os.replace(tmp, sess.sent_offset)

    if engine == "codex":
        thread = sess.meta.get("thread") or die("no threadId in meta — handshake incomplete")
        active = codex_active_turn(sess)
        if args.verb == "steer":
            if active is not None:
                die("codex has no queue — a turn is ACTIVE: use --now (native mid-turn "
                    "turn/steer) or wait for DONE, then steer the next turn")
            reply = codex_request(sess, "turn/start",
                                  {"threadId": thread, "input": codex_text_input(text)},
                                  on_ready=commit_round_state)
        elif args.verb == "steer-now":
            if active is None:
                die("no active turn to steer — default steer starts the next turn instead")
            reply = codex_request(sess, "turn/steer",
                                  {"threadId": thread, "expectedTurnId": active,
                                   "input": codex_text_input(text)},
                                  on_ready=commit_round_state)
        elif args.verb == "replace":
            if active is not None:
                intr = codex_request(sess, "turn/interrupt",
                                     {"threadId": thread, "turnId": active})
                if intr is None or "error" in intr:
                    die(f"turn/interrupt not accepted: {clip(json.dumps(intr, ensure_ascii=False), 200)}", 2)
                wait_for(sess, events_size(sess),
                         lambda f: f.get("method") == "turn/completed", timeout=15.0)
            reply = codex_request(sess, "turn/start",
                                  {"threadId": thread, "input": codex_text_input(text)},
                                  on_ready=commit_round_state)
        elif args.verb == "prompt":
            reply = codex_request(sess, "turn/start",
                                  {"threadId": thread, "input": codex_text_input(text)},
                                  on_ready=commit_round_state)
        else:
            die(f"unsupported codex verb: {args.verb}")
        if reply is None:
            print("WARN: no JSON-RPC response in 20s — frame delivered, engine may be busy; verify with agentctl status")
            return 3
        if "error" in reply:
            print(f"ERR: engine rejected the frame: {clip(json.dumps(reply['error'], ensure_ascii=False), 300)}")
            return 2
        print(f"OK: {args.verb} accepted by engine (correlated JSON-RPC response)")
        return 0

    req_id = f"ctl-{uuid.uuid4().hex[:12]}"
    write_frame(sess, build_frame(engine, args.verb, text, req_id), on_ready=commit_round_state)
    offset = offset_box.get("v", events_size(sess))
    if engine == "omp":
        reply = wait_for(
            sess, offset,
            lambda f: f.get("id") == req_id and f.get("type") == "response",
            timeout=args.wait)
        if reply is None:
            print(f"WARN: no response frame in {args.wait:.0f}s — frame delivered to fifo, engine may be mid-turn; verify with agentctl status")
            return 3
        if reply.get("success") is not True:
            print(f"ERR: engine rejected the frame: {clip(json.dumps(reply, ensure_ascii=False), 300)}")
            return 2
        print(f"OK: {args.verb} accepted by engine (correlated response)")
        return 0
    print(f"OK: {args.verb} delivered to engine stdin (claude queues it natively; no per-frame ack exists)")
    return 0


def cmd_wait_ready(args: argparse.Namespace) -> int:
    sess = Session(args.run_dir, args.session)
    sess.require_meta()
    engine = sess.meta["engine"]
    if engine == "claude":
        return 0  # no handshake frame; first prompt just goes in
    if engine == "omp":
        frame = wait_for(sess, 0, lambda f: f.get("type") == "ready", timeout=args.wait)
        if frame is None:
            print(f"ERR: no ready frame in {args.wait:.0f}s — engine failed to start rpc mode; tail {sess.stderr}", file=sys.stderr)
            return 1
        print("ready: omp rpc handshake frame observed")
        return 0
    # codex: initialize → initialized → thread/start; persist threadId (v1 param
    # shapes, spike-verified 2026-07-19 — the live server self-describes drift)
    init = codex_request(sess, "initialize",
                         {"clientInfo": {"name": "agentctl", "title": "agentctl duplex",
                                         "version": "2.0"}}, timeout=args.wait)
    if init is None or "error" in init:
        print(f"ERR: codex initialize failed: {clip(json.dumps(init, ensure_ascii=False), 200)}", file=sys.stderr)
        return 1
    write_frame(sess, jsonrpc(None, "initialized"))
    if sess.meta.get("resume_thread"):
        started = codex_request(sess, "thread/resume",
                                {"threadId": sess.meta["resume_thread"]}, timeout=args.wait)
    else:
        params = {"cwd": sess.meta.get("cwd"), "approvalPolicy": "never",
                  "sandbox": "danger-full-access"}
        if sess.meta.get("model"):
            params["model"] = sess.meta["model"]
        started = codex_request(sess, "thread/start", params, timeout=args.wait)
    thread_id = (((started or {}).get("result") or {}).get("thread") or {}).get("id")
    if not thread_id:
        print(f"ERR: codex thread/start failed: {clip(json.dumps(started, ensure_ascii=False), 300)}", file=sys.stderr)
        return 1
    meta_update(sess, "thread", thread_id)
    print(f"ready: codex app-server handshake complete (thread {thread_id})")
    return 0


def cmd_classify(args: argparse.Namespace) -> int:
    return classify(Session(args.run_dir, args.session))


def main() -> None:
    parser = argparse.ArgumentParser(prog="duplexctl")
    parser.add_argument("--run-dir", default=os.environ.get("AGENT_WATCH_DIR", "/tmp/agent-watch-run"))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_send = sub.add_parser("send", help="build + deliver one frame (flock single-writer)")
    p_send.add_argument("session")
    p_send.add_argument("--verb", default="steer",
                        choices=["prompt", "steer", "steer-now", "replace", "get-state"])
    p_send.add_argument("--text")
    p_send.add_argument("--file")
    p_send.add_argument("--wait", type=float, default=10.0)
    p_send.set_defaults(func=cmd_send)

    p_ready = sub.add_parser("wait-ready", help="block until the engine handshake frame")
    p_ready.add_argument("session")
    p_ready.add_argument("--wait", type=float, default=15.0)
    p_ready.set_defaults(func=cmd_wait_ready)

    p_cls = sub.add_parser("classify", help="one-shot typed state projection")
    p_cls.add_argument("session")
    p_cls.set_defaults(func=cmd_classify)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
