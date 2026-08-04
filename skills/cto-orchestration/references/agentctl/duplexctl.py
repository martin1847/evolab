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
import shlex
import signal
import subprocess
import sys
from typing import NoReturn
import time
import uuid

# self-locating: this file is run as a script AND loaded by absolute path (tests use
# spec_from_file_location), where sys.path never contains the agentctl dir.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import identity  # noqa: E402  (needs the path above)

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


def die(msg: str, code: int = 1) -> NoReturn:
    print(f"ERR: {msg}", file=sys.stderr)
    sys.exit(code)


def tmux_alive(name: str) -> bool:
    # "=" pins exact-name resolution: a bare name falls through to PREFIX match on
    # miss, so a dead "rev" with a live "rev2" neighbor would probe alive (tmux 3.6b).
    probe = subprocess.run(
        ["tmux", "has-session", "-t", f"={name}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return probe.returncode == 0


def clip(text: str, limit: int = SUMMARY_CHARS) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


# ── provider capability contract: vocabulary ─────────────────────────────────
# The TABLE itself lives at the bottom of this file (§provider contract), next to the
# routing branches it names — everything a provider does is generated FROM it:
#   * `ROUTES` (route id → executable branch), `PROJECTORS` (engine → state projector) and
#     the shell-consumable provider spec `duplexctl providers --shell` (which is the ONLY
#     provider list `agentctl` has: allowlist, binary, pinned argv, argv forwarding and the
#     resume start flag all come from it) are derived, never hand-maintained;
#   * `route` IS the wire name the branch emits (omp/claude frame type, codex JSON-RPC
#     method), and the branches read it back out — the handshake's resume method, the omp
#     ask frame type and every steer frame come from the cell, not from a literal;
#   * `refusal` IS the text a refused verb prints, so a rejection and the published
#     contract cannot disagree about the recommended supported path.
# Adding a provider or a capability is ONE edit in that table. `probe.py drift` proves
# table↔registry consistency and `agentctl-capabilities.test.sh` §C8 proves the declared
# capability is actually PERFORMED against the hermetic fake engines — registry agreement
# alone was not enough (cold review R1: three behaviour mutations stayed green).
SUPPORTED, DEGRADED, UNSUPPORTED, EXPERIMENTAL = (
    "supported", "degraded", "unsupported", "experimental")
CAPABILITY_STATES = (SUPPORTED, DEGRADED, UNSUPPORTED, EXPERIMENTAL)
CAPABILITY_SCHEMA_VERSION = 1

# the closed capability vocabulary, in output order
CAPABILITY_ORDER = ("queuedSteer", "midTurnSteer", "replaceTurn", "structuredAsk",
                    "structuredReply", "resume", "permissionEnforcement")

# WHAT EACH CAPABILITY MEANS. Written down because a criterion applied unevenly is the same
# defect as a wrong cell: cold review R1 caught `resume` being judged "has a dedicated duplex
# verb" for omp/claude but "the documented public invocation works" for codex. Every cell is
# judged against the sentence here — the OPERATION the operator can invoke through
# `agentctl`, not the protocol niceness of how the lane serves it.
CAPABILITY_DEFINITIONS = {
    "queuedSteer": "deliver a message that the engine consumes at/after the current turn "
                   "boundary, without discarding the running turn",
    "midTurnSteer": "deliver a message that reaches the engine INSIDE the running turn",
    "replaceTurn": "abandon the running turn and start a replacement in the same session",
    "structuredAsk": "the engine's own question reaches the operator as a typed "
                     "WAITING-INPUT projection, not as prose to be read out of a log",
    "structuredReply": "answer such a question through a dedicated agentctl verb",
    "resume": "continue a prior conversation's context in a new round through a documented "
              "`agentctl` invocation (in-session route, or stop + start with resume args)",
    "permissionEnforcement": "the runtime constrains what the engine may do and enforces it",
}

# the send verbs that ARE capability claims. `prompt` (goal delivery) and `get-state`
# (omp's liveness probe) are lane plumbing: without them the lane cannot exist at all,
# so they are not provider capabilities and carry no state.
VERB_CAPABILITY = {"steer": "queuedSteer", "steer-now": "midTurnSteer",
                   "replace": "replaceTurn"}

# Non-protocol realizations. A capability served by one of these has no wire route, so the
# drift gate cannot check it against ROUTES — the behaviour battery must. Closed set:
# `start-argv` = `agentctl start` forwards unrecognized args verbatim to the engine, which
# is how omp/claude native resume is invoked.
SURFACE_START_ARGV = "start-argv"
CAPABILITY_SURFACES = (SURFACE_START_ARGV,)


def _cap(state: str, route: str = "", note: str = "", refusal: str = "",
         fallback: str = "", surface: str = "", detect: dict | None = None,
         start_flag: str = "", impl=None) -> dict:
    """One capability cell.

    state    — closed enum; never a boolean, because behaviour here is provider-specific.
    route    — the wire name (frame type / JSON-RPC method) the branch emits, "" if none.
    impl     — the branch that performs `route`; ROUTES is built from these pairs.
    surface  — a non-protocol realization (see CAPABILITY_SURFACES) when there is no route.
    note     — published EXACTLY for degraded (names the degradation) and unsupported
               (names the recommended supported path). A supported cell publishes no note:
               the state is the whole claim. A refusal doubles as the note, so the rejected
               operator and the contract reader see one sentence.
    refusal  — what a refused verb prints.
    fallback — the verb a degraded capability is honestly served by instead.
    detect   — projector-side recognition data (ask frame noise / ask method names), read
               BACK by the projector so the contract owns it too.
    start_flag — the `agentctl start` flag that drives this capability, if any.
    """
    published = note or refusal
    if state == SUPPORTED or state == EXPERIMENTAL:
        published = ""      # notes exist exactly where the state is not self-explanatory
    return {"state": state, "note": published, "refusal": refusal, "route": route,
            "fallback": fallback, "surface": surface, "detect": detect or {},
            "start_flag": start_flag, "impl": impl}


def provider(engine: str) -> dict:
    """The provider adapter record, or a typed death. An engine with no contract has no
    routing either — failing closed here is what keeps the two from drifting apart."""
    record = PROVIDERS.get(engine)
    if record is None:
        die(f"unknown duplex engine: {engine} — no capability contract "
            "(see `agentctl capabilities`)")
    return record


def capability(engine: str, name: str) -> dict:
    cell = provider(engine)["capabilities"].get(name)
    if cell is None:
        die(f"provider '{engine}' declares no capability '{name}' "
            "(see `agentctl capabilities`)")
    return cell


def route_of(engine: str, verb: str) -> str:
    """The wire route a capability verb resolves to — "" when the provider does not have it."""
    name = VERB_CAPABILITY.get(verb)
    return capability(engine, name)["route"] if name else ""


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
    """Latest turn/started without a later matching turn/completed, ON OUR THREAD
    only — the engine multiplexes sub-threads (its own sub-agents) onto the same
    app-server stream, and an unfiltered read let a sub-thread's turn/completed
    masquerade as our turn boundary (caught live by the first dogfood review
    session, 2026-07-19)."""
    ours = sess.meta.get("thread")
    active = None
    for frame in complete_frames_from(sess, 0):
        method = frame.get("method")
        params = frame.get("params") or {}
        if ours and params.get("threadId") not in (None, ours):
            continue
        turn = params.get("turn") or {}
        result_turn = ((frame.get("result") or {}).get("turn") or {}) if "result" in frame else {}
        if result_turn.get("id"):
            # our correlated turn/start response can precede the async started
            # notification — treat it as the active marker too (review S2 2026-07-19)
            active = result_turn["id"]
        elif method == "turn/started":
            active = turn.get("id")
        elif method == "turn/completed" and turn.get("id") == active:
            active = None
    return active



def build_frame(engine: str, verb: str, text: str, req_id: str) -> str:
    """The wire frame for one verb. A CAPABILITY verb takes its frame type from the one
    capability table (`route` IS the wire name), so a frame type cannot exist without a
    declared capability; `prompt` / `get-state` are lane plumbing and stay literal."""
    if engine == "omp":
        omp_type = {"prompt": "prompt", "get-state": "get_state"}.get(verb) \
            or route_of("omp", verb)
        if not omp_type:
            die(f"unsupported omp verb: {verb}")
        frame = {"id": req_id, "type": omp_type}
        if omp_type != "get_state":
            frame["message"] = text
        return json.dumps(frame, ensure_ascii=False)
    if engine == "claude":
        claude_type = "user" if verb == "prompt" else route_of("claude", verb)
        if not claude_type:
            die(f"unsupported claude verb: {verb} (no public interrupt/replace frame)")
        return json.dumps(
            {"type": claude_type,
             "message": {"role": "user",
                         "content": [{"type": "text", "text": text}]}},
            ensure_ascii=False)
    die(f"unknown duplex engine: {engine}")
    raise AssertionError  # unreachable


def acquire_writer_lock(lock) -> None:
    """Plain blocking LOCK_EX. The kernel's flock queue is fair; a LOCK_NB + fixed
    0.1s retry loop was tried and REVERTED (review 2026-07-28): against a healthy
    churning writer the poll starves (0.5s holds → 11.3s max wait vs 0.51s
    blocking) and can reach its own 40s bound, printing "another sender is wedged
    … stop + restart" at a lane that is perfectly fine — and inside classify the
    30s alarm preempted it anyway, so the diagnostic was unreachable.
    The wedged-holder case is bounded ONE LEVEL UP instead: all three verbs that can
    reach this call — classify, send and wait-ready — arm the per-command SIGALRM
    watchdog at entry (see arm_watchdog), so a stuck holder yields a typed exit 8
    with an honest both-candidates message instead of an infinite wait. A permanent
    flock errno (EBADF …) also surfaces immediately again rather than being retried
    into a 40s stall."""
    fcntl.flock(lock, fcntl.LOCK_EX)


# In-flight frame state, read by the watchdog handler (S2-2, review 2026-07-28):
# a signal that _exit()s during a blocked fifo write must not strand the durable
# write-intent marker when NOTHING was sent — a 0-byte "torn frame" poisons every
# later classify/send until stop+restart. sent > 0 keeps the taint: a genuinely
# torn frame must still fail closed.
_INFLIGHT: dict[str, object] = {"intent": None, "sent": 0}


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
        acquire_writer_lock(lock)
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
            # PUBLISHED BEFORE THE FILE EXISTS: a signal landing between the two would
            # otherwise strand exactly the 0-byte marker S2-2 removes (N2). The
            # handler's unlink swallows the ENOENT of the not-yet-created file.
            _INFLIGHT["intent"], _INFLIGHT["sent"] = sess.intent, 0
            with open(sess.intent, "w", encoding="utf-8") as fh:
                fh.write(f"{len(payload)}\n")
            sent = 0
            write_deadline = time.monotonic() + 30.0
            while sent < len(payload):
                try:
                    # published as soon as the write returns. Residual, unclosable in
                    # pure Python (N3, ~1e-7/call): a signal in the ~2-bytecode window
                    # between the syscall returning and this store lets the handler
                    # read sent == 0 with bytes already on the wire and drop the taint.
                    _INFLIGHT["sent"] = sent = sent + os.write(fd, payload[sent:sent + 65536])
                except BlockingIOError:
                    remaining = write_deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    select.select([], [fd], [], min(remaining, 1.0))
                    continue
                except (BrokenPipeError, OSError) as exc:
                    if sent == 0:
                        os.unlink(sess.intent)
                        _INFLIGHT["intent"] = None
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
            _INFLIGHT["intent"] = None
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
    # idle: is there an unanswered real question? The frame type, the connect-time UI chrome
    # to ignore and the frames that clear a pending ask all come from the structuredAsk cell —
    # this projector IS omp's structuredAsk route, so it must not carry its own literals.
    ask = capability("omp", "structuredAsk")
    noise = ask["detect"].get("noise", ())
    clears = ask["detect"].get("clears", ())
    pending = None
    for frame in tail_frames(sess):
        ftype = frame.get("type")
        if ftype == ask["route"] and frame.get("method") not in noise:
            pending = frame
        elif ftype in clears:
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
    # this projector IS codex's structuredAsk route: the ask method names come from the cell
    ask_methods = capability("codex", "structuredAsk")["detect"].get("methods", ())
    pending_ask = None
    answer_text = ""
    ours = sess.meta.get("thread")
    for frame in frames:
        method = frame.get("method", "")
        params = frame.get("params") or {}
        # sub-thread traffic (engine-internal sub-agents share the stream) must
        # never read as OUR turn lifecycle (live dogfood catch, 2026-07-19)
        if ours and params.get("threadId") not in (None, ours):
            continue
        if method == "turn/started":
            started_after_completed = True
        elif method == "turn/completed":
            last_completed = params.get("turn") or {}
            started_after_completed = False
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("phase") == "final_answer" and item.get("text"):
                answer_text = item["text"]
        if frame.get("id") is not None and any(m in method for m in ask_methods):
            pending_ask = frame
        elif pending_ask is not None and (
                (not method and frame.get("id") == pending_ask.get("id"))
                or method == "turn/completed"):
            pending_ask = None  # answered elsewhere / turn ended — not pending anymore
    if pending_ask is not None:
        return "WAITING", clip(
            "native engine ask (agentctl has no reply verb — approvalPolicy=never should "
            "prevent these; answer manually via the raw protocol or stop+resume): "
            + json.dumps(pending_ask, ensure_ascii=False), 300)
    if started_after_completed or last_completed is None:
        return "RUNNING", "turn in progress"
    status = last_completed.get("status")
    err = last_completed.get("error")
    if err or status not in ("completed",):
        return "ERROR", clip(f"turn status={status} error={err}")
    return "IDLE", clip(answer_text) or "turn completed"


def marker_verdict(store) -> tuple[str, str, dict] | None:
    """(class, detail, marker) for the terminal marker on disk, or None when there is no
    marker to judge. A marker that exists but cannot be parsed OR fails the schema gate is
    UNKNOWN, never ignored and never classified: ambiguous terminal evidence must not read as
    'nothing happened', and it must not reach the record at all."""
    status, marker = store.read_terminal_marker()
    if status == identity.STATUS_ABSENT:
        return None
    if status == identity.STATUS_CORRUPT:
        return identity.UNKNOWN, f"marker {store.marker_path} is unparseable", {}
    valid, detail = identity.IdentityStore.validate_marker_schema(marker)
    if not valid:
        return identity.UNKNOWN, detail, {}
    klass, detail = store.classify_stamp(identity.IdentityStore.marker_stamp(marker))
    return klass, detail, marker


def receipt_note(marker: dict) -> str:
    """Delivered-evidence summary appended to a DONE line. Hash evidence, not mtime: it names
    the exact bytes this attempt observed. The `delivered ≠ verified` label is part of the
    line, not a footnote — nothing here claims review, E2E or deployment."""
    if marker.get("phase") != identity.PHASE_DELIVERED:
        return ""
    bits = []
    for item in marker.get("deliverables") or []:
        sha = item.get("sha256") or "-"
        short = sha if sha == identity.HASH_SKIPPED else sha[:12]
        bits.append(f"{os.path.basename(item.get('path') or '-')} sha256={short} "
                    f"size={item.get('size')}")
    head = marker.get("gitHead")
    return (f", delivered evidence: {'; '.join(bits)} @git "
            f"{head[:12] if isinstance(head, str) else 'null'} "
            f"(reason={marker.get('reason')}; delivered ≠ verified)")


def delivered_receipt(store) -> dict | None:
    """The terminal record IF it is identity-valid for the current attempt AND is a VALID
    delivered receipt. Two gates, both required:

    - the WS1 identity fence (staleness is judged on the RECORD — the bytes at the declared path
      carry no provenance of their own), and
    - the WS2 receipt-body schema (`IdentityStore.receipt_status`). Without the second one, a
      record whose nested stamp matched the active attempt superseded the mtime gate on the
      strength of arbitrary fields, so a forged body opened a gate the real deliverable
      predicate had just refused (cold review R1)."""
    judged = marker_verdict(store)
    if judged is None:
        return None
    klass, _detail, marker = judged
    if klass != identity.OK:
        return None
    return store.delivered_receipt(marker)


def classify(sess: Session) -> int:
    sess.require_meta()
    engine = sess.meta.get("engine", "")
    cwd = sess.meta.get("cwd", ".")
    # Identity is the fence every later decision leans on, so an identity that cannot be
    # established at all stops the verdict here: MISSING and CORRUPT get the same typed
    # exit-2 treatment. Letting ABSENT continue was a fail-open — the rc/deliverable lane
    # below then returned DONE for a session with no established identity, and status
    # published an unstamped marker off an empty arm token (cold review R1).
    store = identity.IdentityStore(sess.run, sess.name)
    _active, id_status = store.load()
    if id_status != identity.STATUS_OK:
        why = f" — {store.corrupt_reason}" if store.corrupt_reason else ""
        print(f"IDENTITY-UNKNOWN: active identity record is {id_status} ({store.path}){why}"
              " — no state may be adopted or concluded; agentctl stop, then restart to "
              "establish a new attempt")
        return 2

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
            receipt = None if ok else delivered_receipt(store)
            if receipt is not None:
                # Hash evidence SUPERSEDES the mtime heuristic: an identity-valid receipt of
                # this round names the exact bytes that were observed, while mtime only ever
                # guessed freshness (and produced field false-negatives). Legacy markers keep
                # the mtime path — they carry no hashes to supersede it with.
                print(f"DONE: engine exited rc=0{receipt_note(receipt)} — receipt evidence "
                      "supersedes the mtime freshness heuristic")
                return 0
            if ok:
                note = f", deliverable fresh: {hit}" if hit else ""
                print(f"DONE: engine exited rc=0{note} (duplex engines normally stay alive — treat as complete)")
                return 0
            print(f"IDLE-NO-DELIVERABLE: engine exited rc=0 but '{sess.meta.get('deliverable')}' not produced this round")
            return 6
        print(f"FAILED: engine exited rc={rc} — tail {sess.events} / {sess.stderr} (raw kept on disk)")
        return 2

    # 2. supervisor pane gone without an rc = killed mid-flight — UNLESS a terminal marker
    #    stamped with the CURRENT identity is on disk. A dead process cannot emit new events,
    #    so a matching stamp is honest evidence that this round finished before the pane was
    #    reaped (exactly what the marker was invented for), while a same-pid impostor is
    #    caught by the start-time half of the incarnation. Anything else is labelled and NOT
    #    adopted — the stale file stays on disk untouched for post-mortem.
    if not tmux_alive(sess.name):
        judged = marker_verdict(store)
        if judged is not None:
            klass, detail, marker = judged
            if klass == identity.OK and marker.get("rc") == 0:
                # ONE acceptance rule for every reader that can conclude terminal truth. This
                # branch used to call marker_verdict() alone, so a current-stamped rc=0 record
                # whose RECEIPT BODY was invalid was adopted as DONE 0 here while the canonical
                # reader (`identity receipt`) refused the very same record with exit 3 (cold
                # review R3). A record that CLAIMS delivery and fails the body validator is
                # undecidable evidence, not adoptable evidence; a receipt-LESS WS1 marker stays
                # adoptable exactly as before, because it claims nothing.
                state, why = store.receipt_status(marker)
                if state == identity.RECEIPT_INVALID:
                    print("IDENTITY-UNKNOWN: terminal record claims delivery but its receipt "
                          f"body is invalid — {why}; refusing to adopt it (kept on disk for "
                          "post-mortem, not rewritten)")
                    return 2
                stamp = identity.IdentityStore.marker_stamp(marker)
                try:
                    first = store.apply_event(stamp["attemptId"], stamp.get("seq"))
                except identity.IdentityPersistError as exc:
                    print(f"IDENTITY-UNKNOWN: cannot record the marker adoption ({exc}) — "
                          "refusing to adopt terminal evidence")
                    return 2
                again = "" if first else " (event already applied — idempotent re-read)"
                # the delivered-evidence summary is printed ONLY for a receipt that passed the
                # WS2 schema gate, so an invalid body can never speak in a DONE line either
                print(f"DONE: adopted the terminal marker of the current attempt{again} — "
                      f"engine pane already reaped; {detail}"
                      f"{receipt_note(store.delivered_receipt(marker) or {})}")
                return 0
            if klass == identity.UNKNOWN:
                print(f"IDENTITY-UNKNOWN: terminal marker not adoptable — {detail}")
                return 2
            if klass != identity.OK:
                print(f"{klass}: terminal marker NOT adopted (kept on disk for post-mortem, "
                      f"not rewritten) — {detail}")
        print("AGENT-DEAD: no rc and no tmux session — killed mid-flight; agentctl stop to clean, then restart")
        return 2

    # 2.5 torn input stream: a sender died mid-frame — nothing downstream is trustworthy
    if os.path.exists(sess.intent):
        print("FAILED: torn frame on the input stream (write-intent marker) — agentctl stop, then restart with resume args")
        return 2

    # 3. agent-declared blocker (cross-engine ask-user protocol), fenced by identity: a
    #    record stamped by a PRIOR attempt must never park the current one in WAITING-INPUT.
    #    An unstamped record keeps the pre-existing round-epoch mtime fence.
    blocked = os.path.join(cwd, "BLOCKED.md")
    try:
        blocked_fresh = os.path.getmtime(blocked) >= os.path.getmtime(sess.epoch)
    except OSError:
        blocked_fresh = False
    if blocked_fresh:
        bstatus, bstamp = identity.blocked_stamp(blocked)
        klass, detail = (store.classify_stamp(bstamp) if bstatus == "stamped"
                         else (identity.OK, "unstamped record — round-epoch fence only"))
        if klass == identity.UNKNOWN:
            print(f"IDENTITY-UNKNOWN: BLOCKED.md stamp is not decidable — {detail}; refusing "
                  "to adopt it and refusing to conclude anything else about this round")
            return 2
        if klass == identity.OK:
            print("WAITING-INPUT: agent wrote BLOCKED.md — read it, answer via agentctl steer")
            return 4
        print(f"{klass}: BLOCKED.md NOT adopted (kept on disk for post-mortem, not rewritten)"
              f" — {detail}")

    # 4. live projection
    state, detail = PROJECTORS[engine](sess)
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
    receipt = None if ok else delivered_receipt(store)
    if receipt is not None:
        print(f"DONE: engine idle{receipt_note(receipt)} — receipt evidence supersedes the "
              "mtime freshness heuristic")
        print(f"last: {detail}")
        return 0
    if not ok:
        print(f"IDLE-NO-DELIVERABLE: engine idle but '{sess.meta.get('deliverable')}' not produced this round — steer the agent; do not stop")
        return 6
    note = f", deliverable fresh: {os.path.basename(hit)}" if hit else ""
    print(f"DONE: engine idle{note}")
    print(f"last: {detail}")
    return 0


# ── commands ──────────────────────────────────────────────────────────────────
def cmd_send(args: argparse.Namespace) -> int:
    """send reaches the blocking writer flock and the fifo write with NO classify
    watchdog above it, so it arms the same one-alarm-per-process bound around the
    whole verb (armed before Session(), cleared on every exit path)."""
    arm_watchdog(args.run_dir, args.session, send_timeout(), "send")
    try:
        return send_frame(args)
    finally:
        signal.alarm(0)


# ── codex routes: the executable branch behind each declared codex capability ────────
# Registered in ROUTES under the SAME route id the capability table declares, and each
# handler sends exactly that id as its JSON-RPC method — the declared route IS the wire
# truth, not a label sitting beside it.
def codex_route_start(sess: Session, ctx: dict):
    """`turn/start` — goal delivery (`prompt`) and the queuedSteer capability. codex has no
    queue, so as a STEER this route refuses while a turn is active, with the capability
    table's own refusal text."""
    if ctx["verb"] == "steer" and ctx["active"] is not None:
        die(capability("codex", "queuedSteer")["refusal"])
    return codex_request(sess, ctx["route"],
                         {"threadId": ctx["thread"], "input": codex_text_input(ctx["text"])},
                         on_ready=ctx["on_ready"])


def codex_route_steer(sess: Session, ctx: dict):
    """`turn/steer` — native mid-turn steering, guarded by the expected turn id."""
    if ctx["active"] is None:
        die("no active turn to steer — default steer starts the next turn instead")
    return codex_request(sess, ctx["route"],
                         {"threadId": ctx["thread"], "expectedTurnId": ctx["active"],
                          "input": codex_text_input(ctx["text"])},
                         on_ready=ctx["on_ready"])


def codex_route_replace(sess: Session, ctx: dict):
    """`turn/interrupt+turn/start` — the two methods in the route id are the two frames this
    branch really sends, in that order."""
    interrupt, start = ctx["route"].split("+")
    thread, active = ctx["thread"], ctx["active"]
    if active is not None:
        pre_offset = events_size(sess)
        intr = codex_request(sess, interrupt, {"threadId": thread, "turnId": active})
        if intr is None or "error" in intr:
            die(f"{interrupt} not accepted: {clip(json.dumps(intr, ensure_ascii=False), 200)}", 2)
        # only OUR turn's terminal frame opens the replacement; a stray
        # completion or a timeout must refuse (review S2 2026-07-19)
        done = wait_for(
            sess, pre_offset,
            lambda f: f.get("method") == "turn/completed"
            and (f.get("params") or {}).get("threadId") in (None, thread)
            and ((f.get("params") or {}).get("turn") or {}).get("id") == active,
            timeout=15.0)
        if done is None:
            die("interrupted turn did not reach a terminal state in 15s — NOT starting "
                "the replacement; check status, then retry or stop+resume", 2)
    # THE codex replace commit point: the engine has accepted the interrupt and the
    # interrupted turn is terminal (or there was nothing to interrupt), so the replacement
    # really is about to be written — and the new attempt is durable before that frame goes
    # out. A refusal above returns without rotating anything.
    ctx["commit"]("replace")
    return codex_request(sess, start,
                         {"threadId": thread, "input": codex_text_input(ctx["text"])},
                         on_ready=ctx["on_ready"])


def send_frame(args: argparse.Namespace) -> int:
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
    # ── capability gate ───────────────────────────────────────────────────────────────
    # The ONE table decides what this verb may do on this engine. No per-engine special case
    # lives here, and the sentence a rejected operator reads is the sentence
    # `agentctl capabilities` publishes — they cannot drift apart.
    cap_name = VERB_CAPABILITY.get(args.verb)
    if cap_name:
        cap_entry = capability(engine, cap_name)
        if cap_entry["state"] == UNSUPPORTED:
            # degrading an unsupported verb into a lesser one would silently keep the doomed
            # turn running — refuse and route the operator to the honest path instead
            die(cap_entry["refusal"])
        if cap_entry["fallback"]:
            # a DEGRADED capability honestly served by another verb: name the degradation out
            # loud, then route to the verb that actually exists
            print(f"note: {cap_entry['note']}")
            args.verb = cap_entry["fallback"]
            cap_name = VERB_CAPABILITY[args.verb]
    # Identity commit points. The record must be durable BEFORE the frame it authorises
    # leaves — but no earlier than the point where that frame is actually going to be sent:
    # a codex --replace whose interrupt handshake times out is REFUSED, and rotating the
    # attempt for a replacement that never starts made the still-current attempt stale,
    # over-rejecting its own later evidence and invalidating an armed watcher (cold review
    # R1). So `prompt` commits here, and `replace` commits at its engine's real
    # replacement-frame commit point (immediately below for a single-frame replace, after the
    # interrupt handshake for codex). A queued/--now steer keeps the whole triple.
    def commit_identity(kind: str) -> None:
        store = identity.IdentityStore(args.run_dir, args.session)
        try:
            rec = store.transition(kind)
        except identity.IdentityPersistError as exc:
            die(f"IDENTITY-PERSIST-FAILED: {exc} — frame NOT sent; the prior active identity "
                "record (if any) stays authoritative", 2)
        print(f"identity: attempt {rec['attemptId']} incarnation "
              f"{rec.get('processIncarnation') or 'UNESTABLISHED'}")

    if args.verb == "prompt":
        commit_identity("start")
    elif args.verb == "replace" and engine != "codex":
        # omp's abort_and_prompt IS the replacement frame: there is no separate handshake to
        # wait for, so the commit point is right here, before write_frame.
        commit_identity("replace")

    offset_box = {}

    def commit_round_state():
        # runs under the writer flock, after the reader is confirmed, before the
        # first byte: a steer whose delivery cannot start must NOT rotate the
        # deliverable epoch or move the sent-offset (stale-gate + phantom
        # ENGINE-SILENT otherwise, review S2 2026-07-19)
        if args.verb in ("prompt", "steer", "steer-now", "replace"):
            # AUTHORITATIVE budget/lease check on FRESH meta, under the writer flock —
            # the pre-flight check outside the lock is only a fast-fail; two concurrent
            # senders could both pass it and overrun the hard cap (review S1 2026-07-19)
            fresh = Session(args.run_dir, args.session)
            check_review_budget(fresh, text)
            with open(sess.epoch, "a", encoding="utf-8"):
                os.utime(sess.epoch, None)
            meta_update(fresh, "round", str(int(fresh.meta.get("round", "0")) + 1))
            offset_box["v"] = events_size(sess)
            # atomic replace: an in-place truncate gave lock-free classify a window
            # where the offset read as empty → 0 → an old result revived as DONE
            tmp = sess.sent_offset + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(str(offset_box["v"]))
            os.replace(tmp, sess.sent_offset)

    if engine == "codex":
        thread = sess.meta.get("thread") or die("no threadId in meta — handshake incomplete")
        if not cap_name and args.verb != "prompt":
            die(f"unsupported codex verb: {args.verb}")
        # `prompt` is lane plumbing and rides the same turn/start route; every CAPABILITY
        # verb resolves its route through the one table.
        route = route_of(engine, args.verb) if cap_name else "turn/start"
        handler = ROUTES[engine].get(route)
        if handler is None:
            die(f"codex declares route '{route}' with no executable branch — the capability "
                "contract and the routing are out of sync")
        reply = handler(sess, {"thread": thread, "text": text, "verb": args.verb,
                               "active": codex_active_turn(sess), "route": route,
                               "on_ready": commit_round_state, "commit": commit_identity})
        if reply is None:
            print("WARN: no JSON-RPC response in 20s — frame delivered, engine may be busy; verify with agentctl status")
            return 3
        if "error" in reply:
            print(f"ERR: engine rejected the frame: {clip(json.dumps(reply['error'], ensure_ascii=False), 300)}")
            return 2
        print(f"OK: {args.verb} accepted by engine (correlated JSON-RPC response)")
        if args.deliverable:
            meta_update(Session(args.run_dir, args.session), "deliverable", args.deliverable)
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
        if args.deliverable:
            meta_update(Session(args.run_dir, args.session), "deliverable", args.deliverable)
        return 0
    print(f"OK: {args.verb} delivered to engine stdin (claude queues it natively; no per-frame ack exists)")
    if args.deliverable:
        meta_update(Session(args.run_dir, args.session), "deliverable", args.deliverable)
    return 0


def cmd_wait_ready(args: argparse.Namespace) -> int:
    """Whole-verb watchdog, armed before Session() like the other two verbs. The
    codex handshake reaches the blocking writer flock FOUR times — three
    codex_request() round trips (initialize / thread/{start,resume}) plus the bare
    initialized frame — so bounding only one of them left `agentctl start` able to
    hang forever on a wedged lock holder (review N1 2026-07-28). Sized for the whole
    verb, not per call: three legitimate --wait round trips can exceed the send
    bound (see ready_timeout)."""
    arm_watchdog(args.run_dir, args.session, ready_timeout(args.wait), "wait-ready")
    try:
        return handshake(args)
    finally:
        signal.alarm(0)


def handshake(args: argparse.Namespace) -> int:
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
        # the resume METHOD is the capability's declared route, not a literal here: a
        # handshake that stopped resuming must contradict the contract, and it does — the
        # behaviour battery starts a real (fake) codex with --resume-thread and asserts the
        # frame on the wire (cold review R1: this literal drifted silently).
        started = codex_request(sess, capability(engine, "resume")["route"],
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


# ── provider contract: THE table ─────────────────────────────────────────────
# One record per provider adapter: how the lane LAUNCHES it, how the lane PROJECTS it, and
# what it can do. Everything else about a provider is derived below — there is no second
# list anywhere, in this file or in the shell.
#
# Each capability cell is judged against CAPABILITY_DEFINITIONS (see the vocabulary block at
# the top): the OPERATION an operator can invoke through `agentctl`, never "how elegantly the
# duplex protocol happens to serve it". `route` names a wire method/frame type with an
# executable branch; `surface` names a non-protocol realization when there is no wire route.
PROVIDERS: dict[str, dict] = {
    "omp": {
        "bin_env": "AGENTCTL_BIN_OMP",
        "bin": "omp",
        "argv": ("--mode=rpc",),
        # unrecognized `agentctl start` args are forwarded verbatim to the engine — that IS
        # omp's resume surface, so the two facts live in one record
        "extra_argv": True,
        "projector": project_omp,
        "capabilities": {
            "queuedSteer": _cap(SUPPORTED, route="follow_up", impl=build_frame),
            "midTurnSteer": _cap(SUPPORTED, route="steer", impl=build_frame),
            "replaceTurn": _cap(SUPPORTED, route="abort_and_prompt", impl=build_frame),
            # engine questions arrive as extension_ui_request frames and project as
            # WAITING-INPUT; the connect-time setWidget push is UI chrome, not a question
            "structuredAsk": _cap(
                SUPPORTED, route="extension_ui_request", impl=project_omp,
                detect={"noise": ("setWidget", "set_widget"),
                        "clears": ("extension_ui_response", "agent_start")}),
            "structuredReply": _cap(
                UNSUPPORTED,
                refusal="the lane has no structured reply verb — answer a pending omp "
                        "question with `agentctl steer` (the engine consumes it as the "
                        "next user message)"),
            # DEGRADED, not unsupported: `agentctl start` forwards the engine's own resume
            # args verbatim, so the documented operation IS invocable through the CLI. What
            # is missing is an IN-SESSION route — recovery costs a stop and a new attempt
            # identity, and the lane cannot confirm the engine honoured the flag.
            "resume": _cap(
                DEGRADED, surface=SURFACE_START_ARGV,
                note="no in-session resume route: `agentctl stop`, then `agentctl start omp "
                     "<s> <cwd> --goal <f> -r <session-file>` — start forwards the engine "
                     "args verbatim, but this is a NEW session and attempt identity, and "
                     "the lane cannot confirm the engine accepted the flag"),
            "permissionEnforcement": _cap(
                UNSUPPORTED,
                refusal="the lane sets no permission flag for omp: the engine's own "
                        "defaults govern and the runtime enforces nothing"),
        },
    },
    "claude": {
        "bin_env": "AGENTCTL_BIN_CLAUDE",
        "bin": "claude",
        "argv": ("-p", "--input-format", "stream-json", "--output-format", "stream-json",
                 "--verbose", "--permission-mode", "bypassPermissions"),
        "extra_argv": True,
        "projector": project_claude,
        "capabilities": {
            # native queue: lands at the next turn boundary. The protocol has no per-frame
            # ack, so `send` reports delivery, never acceptance.
            "queuedSteer": _cap(SUPPORTED, route="user", impl=build_frame),
            # THE degradation this contract exists to stop advertising as native steering.
            "midTurnSteer": _cap(
                DEGRADED, route="user", impl=build_frame,
                note="claude has no public interrupt frame — `--now` is delivered as a "
                     "QUEUED steer that lands at the next turn boundary, NOT native "
                     "mid-turn steering",
                fallback="steer"),
            "replaceTurn": _cap(
                UNSUPPORTED,
                refusal="claude has no interrupt/replace frame — `agentctl stop` the "
                        "session, then restart with `--resume <session_id>` (engine args) "
                        "and the new goal"),
            "structuredAsk": _cap(
                UNSUPPORTED,
                refusal="claude emits no structured ask frame on stream-json (a prose "
                        "'permission denied' is an error, not a question) — the worker asks "
                        "by writing BLOCKED.md, which projects as WAITING-INPUT (exit 4)"),
            "structuredReply": _cap(
                UNSUPPORTED,
                refusal="the lane has no structured reply verb — answer a BLOCKED.md "
                        "question with `agentctl steer`"),
            "resume": _cap(
                DEGRADED, surface=SURFACE_START_ARGV,
                note="no in-session resume route: `agentctl stop`, then `agentctl start "
                     "claude <s> <cwd> --goal <f> --resume <session_id>` — start forwards "
                     "the engine args verbatim (cwd-bound), but this is a NEW session and "
                     "attempt identity, and the lane cannot confirm the engine accepted it"),
            "permissionEnforcement": _cap(
                UNSUPPORTED,
                refusal="the lane launches claude with `--permission-mode "
                        "bypassPermissions`: prompts are disabled by design, the runtime "
                        "enforces nothing"),
        },
    },
    "codex": {
        "bin_env": "AGENTCTL_BIN_CODEX",
        "bin": "codex",
        "argv": ("app-server",),
        # engine config rides the protocol (thread/start params), so stray argv is REFUSED
        # rather than silently dropped — and codex therefore has no start-argv surface
        "extra_argv": False,
        "projector": project_codex,
        "capabilities": {
            # a route that EXISTS but refuses under a named condition is degraded, not
            # supported: the refusal below is the string the busy-turn branch prints.
            "queuedSteer": _cap(
                DEGRADED, route="turn/start", impl=None,
                note="codex has no queue: a default steer starts the NEXT turn when idle "
                     "and is REFUSED while a turn is active",
                refusal="codex has no queue — a turn is ACTIVE: use --now (native mid-turn "
                        "turn/steer) or wait for DONE, then steer the next turn"),
            "midTurnSteer": _cap(SUPPORTED, route="turn/steer", impl=codex_route_steer),
            # the interrupted turn must reach a terminal frame before the replacement
            # starts; an interrupt that is not accepted refuses instead of replacing
            "replaceTurn": _cap(SUPPORTED, route="turn/interrupt+turn/start",
                                impl=codex_route_replace),
            # requestApproval / requestUserInput / elicitation project as WAITING-INPUT;
            # approvalPolicy=never should keep them from appearing at all
            "structuredAsk": _cap(
                SUPPORTED, route="codex-ask", impl=project_codex,
                detect={"methods": ("requestApproval", "requestUserInput", "elicitation")}),
            "structuredReply": _cap(
                UNSUPPORTED,
                refusal="the lane has no structured reply verb — answer manually over the "
                        "raw protocol, or `agentctl stop` and restart with "
                        "`--resume-thread <id>`"),
            # the only IN-SESSION resume in the lane: the handshake resumes the thread, so
            # the next round continues the same conversation without a stop/start dance
            "resume": _cap(SUPPORTED, route="thread/resume", impl=handshake,
                           start_flag="--resume-thread"),
            "permissionEnforcement": _cap(
                UNSUPPORTED,
                refusal="the handshake pins approvalPolicy=never and "
                        "sandbox=danger-full-access: approvals are disabled by design, the "
                        "runtime enforces nothing"),
        },
    },
}
# `turn/start` is shared by codex's queuedSteer route and by goal delivery (`prompt`), so its
# branch is attached here rather than inside the cell that names it.
PROVIDERS["codex"]["capabilities"]["queuedSteer"]["impl"] = codex_route_start

# ── everything below is DERIVED from the table above ─────────────────────────
CAPABILITIES = {name: rec["capabilities"] for name, rec in PROVIDERS.items()}
# route id → the branch that really performs it. Send routes (frame builder / JSON-RPC
# handler) and projection routes (structuredAsk is realized by the projector, not by a send
# frame) alike. A route cannot exist without a cell declaring it, because this IS the cells.
ROUTES = {name: {cell["route"]: cell["impl"] for cell in caps.values() if cell["route"]}
          for name, caps in CAPABILITIES.items()}
# engine → state projector, consumed by classify.
PROJECTORS = {name: rec["projector"] for name, rec in PROVIDERS.items()}


def capability_document() -> dict:
    """The published machine contract. Exactly `{state}` for supported/experimental and
    exactly `{state, note}` for degraded (names the degradation) and unsupported (names the
    recommended supported path) — a supported cell publishes no note, because the state IS
    the whole claim (cold review R1). Route ids, refusals, surfaces and fallbacks are
    IMPLEMENTATION: publishing them would invite callers to depend on wire details that are
    free to change under a stable state."""
    return {
        "schemaVersion": CAPABILITY_SCHEMA_VERSION,
        "providers": {
            engine: {
                name: ({"state": cell["state"], "note": cell["note"]} if cell["note"]
                       else {"state": cell["state"]})
                for name, cell in ((n, capability(engine, n)) for n in CAPABILITY_ORDER)
            }
            for engine in PROVIDERS
        },
    }


def cmd_capabilities(args: argparse.Namespace) -> int:
    """Runtime-generated provider capability contract. There is no prose copy of this table:
    the main skill points here, and every provider behaviour is generated from it."""
    doc = capability_document()
    if args.json:
        print(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    engines = list(PROVIDERS)
    head = max(len(n) for n in CAPABILITY_ORDER) + 2
    col = max(max(len(e) for e in engines), max(len(s) for s in CAPABILITY_STATES)) + 2
    print(f"provider capability contract (schemaVersion {doc['schemaVersion']}) — generated "
          f"from the provider table in {os.path.basename(__file__)}; no prose copy exists")
    print("".join(["capability".ljust(head)] + [e.ljust(col) for e in engines]))
    for name in CAPABILITY_ORDER:
        print("".join([name.ljust(head)]
                      + [doc["providers"][e][name]["state"].ljust(col) for e in engines]))
    print("\ncapability definitions (the criterion every cell is judged against — the "
          "OPERATION agentctl exposes, not the protocol's elegance):")
    for name in CAPABILITY_ORDER:
        print(f"  {name.ljust(head - 2)} {CAPABILITY_DEFINITIONS[name]}")
    print("\nnotes (published exactly for degraded — naming the degradation — and "
          "unsupported — naming the recommended supported path):")
    for engine in engines:
        for name in CAPABILITY_ORDER:
            cell = doc["providers"][engine][name]
            if cell.get("note"):
                print(f"  {engine}.{name} [{cell['state']}] {cell['note']}")
    print(f"\nstates: {' / '.join(CAPABILITY_STATES)}")
    return 0


def provider_spec_rows() -> list[str]:
    """The shell-consumable provider spec — `agentctl`'s ONLY provider list.

    `name|bin_env|default_bin|pinned_argv|extra_argv|resume_start_flag`, argv already
    shell-quoted. The allowlist, the launch command, whether unrecognized start args are
    forwarded (which IS the start-argv resume surface) and which start flag drives the
    provider's resume capability all come from here, so the shell cannot hold an opinion the
    table does not (cold review R1: a renamed launch branch went undetected)."""
    rows = []
    for name, rec in PROVIDERS.items():
        argv = " ".join(shlex.quote(a) for a in rec["argv"])
        rows.append("|".join([
            name, rec["bin_env"], rec["bin"], argv,
            "1" if rec["extra_argv"] else "0",
            rec["capabilities"]["resume"]["start_flag"],
        ]))
    return rows


def cmd_providers(args: argparse.Namespace) -> int:
    if args.shell:
        print("\n".join(provider_spec_rows()))
    else:
        print("\n".join(PROVIDERS))
    return 0


STATUS_TIMEOUT_DEFAULT = 30
SEND_TIMEOUT_DEFAULT = 40   # > the longest legitimate hold: 5s fifo-open + 30s write deadline + slack
TIMEOUT_MAX = 3600          # signal.alarm() takes a C int — a knob must never crash it, nor disable it


def env_timeout(var: str, default: int) -> int:
    """Positive integer seconds from `var`. Empty / 0 / negative / non-numeric falls
    back to `default` instead of disabling the bound — an unparsable knob must never
    be the reason the control plane hangs again. Anything above TIMEOUT_MAX clamps
    DOWN to it: un-clamped, a value >= 2**31 made signal.alarm() raise OverflowError
    (traceback, rc=1, no verdict at all) and 2147483647 (~68 years) silently
    disabled the watchdog the docstring promises (review 2026-07-28)."""
    try:
        secs = int(os.environ.get(var, "").strip())
    except ValueError:
        return default
    if secs <= 0:
        return default
    return min(secs, TIMEOUT_MAX)


def status_timeout() -> int:
    """Hard deadline for ONE classify — AGENT_WATCH_STATUS_TIMEOUT."""
    return env_timeout("AGENT_WATCH_STATUS_TIMEOUT", STATUS_TIMEOUT_DEFAULT)


def send_timeout() -> int:
    """Hard deadline for ONE send — AGENT_WATCH_SEND_TIMEOUT. send reaches the
    blocking writer flock and the fifo write with no classify watchdog above it,
    so it arms the same alarm around the whole verb."""
    return env_timeout("AGENT_WATCH_SEND_TIMEOUT", SEND_TIMEOUT_DEFAULT)


READY_TIMEOUT_FLOOR = 60    # three default --wait round trips (15s each) + slack


def ready_timeout(wait: float) -> int:
    """Hard deadline for ONE wait-ready. Sized for the WHOLE verb: the codex
    handshake makes three --wait-bounded round trips, so a flat SEND_TIMEOUT_DEFAULT
    would cut a legitimate slow handshake short. AGENT_WATCH_READY_TIMEOUT overrides
    outright (how a test/operator shortens it). AGENT_WATCH_SEND_TIMEOUT deliberately
    does NOT leak in — it bounds send only; when it doubled as this bound, an operator
    shortening send silently shrank the handshake window below 3*wait+15 and the
    watchdog killed legitimate slow handshakes (R3 nit 2026-07-28, fixed 2026-07-30)."""
    derived = min(max(READY_TIMEOUT_FLOOR, int(3 * wait) + 15), TIMEOUT_MAX)
    if os.environ.get("AGENT_WATCH_READY_TIMEOUT", "").strip():
        # invalid knob values must degrade to the DERIVED bound, not the bare floor —
        # a floor fallback re-shrinks the window the knob split was meant to protect
        return env_timeout("AGENT_WATCH_READY_TIMEOUT", derived)
    return derived


def arm_watchdog(run_dir: str, name: str, secs: int, verb: str) -> None:
    """SIGALRM hard stop for ONE command: a status query is a CONTROL-PLANE read and
    must always answer, and neither a send nor a handshake may wait forever on the
    writer lock — ALL THREE verbs (classify / send / wait-ready) arm this. Every
    blocking call underneath is nominally bounded (wait_for / the 5s+30s fifo
    deadlines) except the kernel-fair LOCK_EX, and bounds can be defeated by a wedged
    host — field hit: one `agentctl status` hung and pinned an orchestrator's whole
    polling loop. Timing out is reported with the EXISTING exit-8 vocabulary
    (ENGINE-SILENT), disposition identical: read stderr, stop + resume if needed.
    Armed BEFORE any Session() is built — the constructor stats and reads the meta
    file, so a wedged run-dir used to hang outside the watchdog — hence the stderr
    path is derived from run_dir/name here instead of from a Session.
    ONE alarm per process: each verb arms at entry and clears in a finally, no nesting.
    The handler writes and _exit()s IN-SIGNAL on purpose — raising would be swallowed
    by classify's `except OSError` arms (TimeoutError IS an OSError), and unwinding
    normally would have to traverse the very code that is stuck."""
    stderr_log = os.path.join(run_dir, f"{name}.duplex.stderr.log")
    if verb == "classify":
        msg = (
            f"ENGINE-SILENT: classify timeout after {secs}s — the control-plane query never "
            f"came back (engine or writer lock unresponsive); inspect {stderr_log}, then "
            "agentctl stop + restart with the engine's resume args if it stays stuck\n"
        ).encode("utf-8")
    elif verb == "wait-ready":
        msg = (
            f"ENGINE-SILENT: wait-ready timeout after {secs}s — the engine handshake never "
            f"completed: the writer lock is held by another sender, or the engine never answered; "
            f"inspect {stderr_log} and agentctl status, then agentctl stop + restart with the "
            "engine's resume args if it stays stuck\n"
        ).encode("utf-8")
    else:
        msg = (
            f"ENGINE-SILENT: send timeout after {secs}s — the frame never went out: the writer "
            f"lock is held by another sender, or the fifo is unresponsive; inspect {stderr_log} "
            "and agentctl status, then agentctl stop + restart with the engine's resume args if "
            "it stays stuck\n"
        ).encode("utf-8")

    def fire(_signum, _frame):
        # undo the ONE piece of durable state an _exit() would strand: a write-intent
        # marker with ZERO bytes sent is not a torn frame, and leaving it behind makes
        # every later classify/send fail closed until stop+restart. sent > 0 keeps the
        # marker — a genuinely torn frame must still poison the stream.
        intent = _INFLIGHT["intent"]
        if isinstance(intent, str) and _INFLIGHT["sent"] == 0:
            try:
                os.unlink(intent)
            except OSError:
                pass
        try:
            sys.stdout.flush()
        except Exception:
            pass
        try:
            os.write(1, msg)
        except Exception:
            # fd 1 closed / EPIPE: the verdict is the only output that matters, so
            # try stderr, then give up — the typed exit 8 still carries the meaning.
            try:
                os.write(2, msg)
            except Exception:
                pass
        os._exit(8)
    signal.signal(signal.SIGALRM, fire)
    signal.alarm(secs)


def cmd_classify(args: argparse.Namespace) -> int:
    arm_watchdog(args.run_dir, args.session, status_timeout(), "classify")
    try:
        return classify(Session(args.run_dir, args.session))
    finally:
        signal.alarm(0)


def cmd_identity(args: argparse.Namespace) -> int:
    """The ONLY identity surface for callers outside this process (agentctl uses it for the
    arm-time token and for fenced marker publication)."""
    store = identity.IdentityStore(args.run_dir, args.session)
    if args.op == "token":
        print(store.token())
        return 0
    if args.op == "show":
        rec, status = store.load()
        if status != identity.STATUS_OK:
            print(f"IDENTITY-UNKNOWN: active identity record is {status} ({store.path})")
            return 3 if status == identity.STATUS_ABSENT else 2
        print(json.dumps(rec, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    if args.op == "receipt":
        # the read API for the ONE terminal record: fenced verdict + structural reason, for
        # operators and for downstream callers that must not re-derive the fence themselves
        view = store.receipt_view()
        print(json.dumps(view, ensure_ascii=False, indent=2, sort_keys=True))
        return 0 if view.get("delivered") else 3
    if args.op in ("start", "replace", "resume"):
        try:
            rec = store.transition(args.op)
        except (identity.IdentityPersistError, ValueError) as exc:
            die(f"IDENTITY-PERSIST-FAILED: {exc}", 2)
        print(f"identity {args.op}: attempt {rec['attemptId']} incarnation "
              f"{rec.get('processIncarnation') or 'UNESTABLISHED'}")
        return 0
    if args.op == "publish":
        try:
            klass, detail = store.publish_terminal(args.armed, rc=args.rc)
        except identity.IdentityPersistError as exc:
            print(f"IDENTITY-UNKNOWN: reason={identity.PUBLISH_INTERRUPTED} {exc} — no "
                  "terminal conclusion published")
            return 2
        if klass != identity.OK:
            print(f"{klass}: {detail}")
            return 2
        # the machine line the DONE verdict carries: reason= first, evidence after
        print(detail)
        return 0
    try:
        store.clear()
    except identity.IdentityPersistError as exc:
        die(f"IDENTITY-PERSIST-FAILED: {exc} — identity state left UNCHANGED; a lock that "
            "cannot be acquired proves nothing about holders", 2)
    return 0


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
    p_send.add_argument("--deliverable")
    p_send.set_defaults(func=cmd_send)

    p_ready = sub.add_parser("wait-ready", help="block until the engine handshake frame")
    p_ready.add_argument("session")
    p_ready.add_argument("--wait", type=float, default=15.0)
    p_ready.set_defaults(func=cmd_wait_ready)

    p_cls = sub.add_parser("classify", help="one-shot typed state projection")
    p_cls.add_argument("session")
    p_cls.set_defaults(func=cmd_classify)

    p_id = sub.add_parser("identity", help="attempt-identity record (the one state abstraction)")
    p_id.add_argument("op", choices=["token", "show", "start", "replace", "resume",
                                     "publish", "receipt", "clear"])
    p_id.add_argument("session")
    p_id.add_argument("--armed", default="", help="arm-time identity token (publish)")
    p_id.add_argument("--rc", type=int, default=0)
    p_id.set_defaults(func=cmd_identity)

    p_cap = sub.add_parser("capabilities", help="runtime-generated provider capability contract")
    p_cap.add_argument("--json", action="store_true", help="stable machine shape")
    p_cap.set_defaults(func=cmd_capabilities)

    p_prov = sub.add_parser("providers", help="the provider adapter spec agentctl launches from")
    p_prov.add_argument("--shell", action="store_true",
                        help="name|bin_env|default_bin|argv|extra_argv|resume_flag rows")
    p_prov.set_defaults(func=cmd_providers)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
