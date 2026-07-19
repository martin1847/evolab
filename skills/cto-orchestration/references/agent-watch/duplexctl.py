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

Engines:
  omp    : --mode=rpc JSON-lines. prompt/steer/follow_up/abort_and_prompt verbs,
           get_state for live status (isStreaming / queuedMessageCount).
  claude : -p --input-format stream-json. A user message injected mid-turn is
           natively QUEUED to the next turn (official semantics); there is no
           public interrupt frame, so steer --now degrades to queued (told to
           the caller). State is projected from the event stream (result frame
           = turn boundary / idle).
"""
from __future__ import annotations

import argparse
import fcntl
import glob as globmod
import json
import os
import subprocess
import sys
import time

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


def write_frame(sess: Session, frame: str) -> None:
    """flock-serialized fifo write. O_NONBLOCK open doubles as a liveness probe:
    ENXIO = nothing holds the read end = supervisor pane is gone."""
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
            # clear O_NONBLOCK: a frame larger than the pipe buffer must block
            # until the engine drains it, not fail with EAGAIN.
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
            os.write(fd, frame.encode("utf-8") + b"\n")
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


# ── tail window parsing (classify never reads the whole file) ─────────────────
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
    req_id = f"ctl-{int(time.time() * 1000)}"
    write_frame(sess, build_frame("omp", "get-state", "", req_id))
    reply = wait_for(
        sess, offset,
        lambda f: f.get("id") == req_id and f.get("type") == "response",
        timeout=6.0)
    if reply is None:
        return "RUNNING", "get_state unanswered in 6s (engine busy or wedged; MAX_POLLS bounds this)"
    data = reply.get("data") or {}
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
    # A queued steer consumed at the next turn boundary leaves the PREVIOUS
    # turn's result frame as the tail — without this guard that reads as a
    # false DONE the instant after a steer is delivered.
    try:
        sent = int(open(sess.sent_offset, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        sent = 0
    if events_size(sess) <= sent:
        return "RUNNING", "no output since last steer (engine silent so far)"
    frames = tail_frames(sess)
    if not frames:
        return "RUNNING", "no frames yet (starting)"
    last = frames[-1]
    if last.get("type") == "result":
        summary = clip(str(last.get("result", "")))
        state = "IDLE"
        if last.get("is_error"):
            state = "WAITING" if "permission" in summary.lower() else "IDLE"
        return state, summary or last.get("subtype", "result")
    return "RUNNING", f"last frame type={last.get('type')}"


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

    # 3. agent-declared blocker (cross-engine ask-user protocol)
    blocked = os.path.join(cwd, "BLOCKED.md")
    try:
        if os.path.getmtime(blocked) >= os.path.getmtime(sess.epoch):
            print(f"WAITING-INPUT: agent wrote BLOCKED.md — read it, answer via agentctl steer")
            return 4
    except OSError:
        pass

    # 4. live projection
    state, detail = (project_omp if engine == "omp" else project_claude)(sess)
    if state == "WAITING":
        print(f"WAITING-INPUT: {detail}")
        return 4
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
    if engine == "claude" and args.verb in ("steer-now", "replace"):
        print("note: claude has no public interrupt frame — delivering as queued steer (lands at the next turn boundary)")
        args.verb = "steer"
    # a steer IS a new round: rotate the deliverable freshness epoch BEFORE delivery
    if args.verb in ("prompt", "steer", "steer-now", "replace"):
        with open(sess.epoch, "a", encoding="utf-8"):
            os.utime(sess.epoch, None)
    offset = events_size(sess)
    if args.verb in ("prompt", "steer", "steer-now", "replace"):
        with open(sess.sent_offset, "w", encoding="utf-8") as fh:
            fh.write(str(offset))
    req_id = f"ctl-{int(time.time() * 1000)}"
    write_frame(sess, build_frame(engine, args.verb, text, req_id))
    if engine == "omp":
        reply = wait_for(
            sess, offset,
            lambda f: f.get("id") == req_id and f.get("type") == "response",
            timeout=args.wait)
        if reply is None:
            print(f"WARN: no response frame in {args.wait:.0f}s — frame delivered to fifo, engine may be mid-turn; verify with agentctl status")
            return 3
        if not reply.get("success", False):
            print(f"ERR: engine rejected the frame: {clip(json.dumps(reply, ensure_ascii=False), 300)}")
            return 2
        print(f"OK: {args.verb} accepted by engine (correlated response)")
        return 0
    print(f"OK: {args.verb} delivered to engine stdin (claude queues it natively; no per-frame ack exists)")
    return 0


def cmd_wait_ready(args: argparse.Namespace) -> int:
    sess = Session(args.run_dir, args.session)
    sess.require_meta()
    if sess.meta["engine"] != "omp":
        return 0  # claude has no handshake frame; first prompt just goes in
    frame = wait_for(sess, 0, lambda f: f.get("type") == "ready", timeout=args.wait)
    if frame is None:
        print(f"ERR: no ready frame in {args.wait:.0f}s — engine failed to start rpc mode; tail {sess.stderr}", file=sys.stderr)
        return 1
    print("ready: omp rpc handshake frame observed")
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
