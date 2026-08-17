#!/usr/bin/env python3
"""duplexctl — frame builder + state projector for the agentctl duplex lane.

stdlib only, no daemon. One long-lived engine process per session runs under a
tmux supervisor pane:  bash -c 'exec 3<>IN.FIFO; ENGINE <&3 >> EVENTS 2>> ERR; echo $? > RC'
This tool is the ONLY writer to the fifo (flock-serialized) and the only reader
that interprets EVENTS. It never touches the pane; terminal truth is the typed
exit code, whose vocabulary is defined ONCE in TYPED_STATES below and published by
`agentctl states` — this docstring keeps no copy of it.
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
import math
import os
import re
import select
import shlex
import shutil
import signal
import stat
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


# ── typed state vocabulary ────────────────────────────────────────────────────
# The ONE definition of every typed state this lane can hand an orchestrator. Every typed
# exit in this file returns one of these constants — a bare integer literal is never a
# verdict — and `agentctl states` is GENERATED from the table below, so a state cannot
# appear in the lane without appearing in the published vocabulary.
#
# DISPOSITION IS NOT HERE. What an orchestrator should DO about a state is judgement that
# moves with the workflow; only what the runtime OBSERVED is a runtime fact.
#
# Untyped exits are deliberately absent — plumbing, not states: 1 usage/environment error,
# 3 a verb-local refusal (no correlated ack, refused lease, refused publish), 13 the
# waiter-internal arm handshake, 130/143 signals, and the ARM_* supervisor-arm decisions.
EXIT_DONE = 0
EXIT_FAILED = 2
EXIT_WAITING_INPUT = 4
EXIT_STALLED_EXTERNAL = 5
EXIT_IDLE_NO_DELIVERABLE = 6
EXIT_WATCH_TIMEOUT = 7
EXIT_ENGINE_SILENT = 8
EXIT_BUDGET_EXHAUSTED = 9
EXIT_RUNNING = 10
EXIT_STALLED_STREAM = 11
EXIT_SUPERVISOR_LOST = 12

TYPED_STATE_SCHEMA_VERSION = 1
TYPED_STATES: tuple[tuple[int, str, str], ...] = (
    (EXIT_DONE, "DONE",
     "engine idle or exited rc=0, and any declared deliverable is fresh for this round"),
    (EXIT_FAILED, "FAILED|AGENT-DEAD",
     "the engine errored or exited non-zero, or its pane is gone with no rc, or this "
     "round's identity is undecidable"),
    (EXIT_WAITING_INPUT, "WAITING-INPUT",
     "the agent is asking: a BLOCKED.md fresh for this attempt, or a question frame from "
     "the engine (UI chrome filtered)"),
    (EXIT_STALLED_EXTERNAL, "STALLED-EXTERNAL",
     "the turn or the process died on a backend quota/auth error"),
    (EXIT_IDLE_NO_DELIVERABLE, "IDLE-NO-DELIVERABLE",
     "the engine reads terminal but the deliverable it declared did not appear this round"),
    (EXIT_WATCH_TIMEOUT, "WATCH-TIMEOUT",
     "the sensing loop exhausted its poll budget while the engine was still active"),
    (EXIT_ENGINE_SILENT, "ENGINE-SILENT",
     "a control-plane operation or the steered engine produced no output within its bound"),
    (EXIT_BUDGET_EXHAUSTED, "BUDGET-EXHAUSTED",
     "the review loop reached --max-rounds; the steer was refused before delivery"),
    (EXIT_RUNNING, "RUNNING",
     "non-terminal: the engine is working — a status snapshot, or the waiter keeps waiting"),
    (EXIT_STALLED_STREAM, "STALLED-STREAM",
     "the event stream stopped past its window with no unmatched in-flight lifecycle frame "
     "and nothing young under the pane"),
    (EXIT_SUPERVISOR_LOST, "SUPERVISOR-LOST",
     "no fenced terminal record for this attempt+round, and the sensing supervisor cannot "
     "be shown to be running (reason=dead) or cannot be judged at all (reason=unknown)"),
)


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
        sys.exit(EXIT_BUDGET_EXHAUSTED)
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
                        "with the engine's resume args", EXIT_FAILED)
                if time.monotonic() >= write_deadline:
                    break
            if sent < len(payload):
                die(f"engine stopped draining the fifo mid-frame ({sent}/{len(payload)} bytes in 30s) "
                    "— frame is TORN, session input stream is tainted: agentctl stop, then restart "
                    "with the engine's resume args", EXIT_FAILED)
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


CLAUDE_TASK_TERMINAL = ("completed", "failed", "killed", "cancelled", "stopped", "error")


def claude_pending_background_tasks(frames: list[dict]) -> list[str]:
    """Background-task ids still in flight per the harness's own accounting.
    `background_tasks_changed` carries the FULL live set (authoritative snapshot —
    each one replaces the previous set); a later `task_updated`/`task_notification`
    with a terminal status retires its id. An unknown status keeps the id pending:
    the safe failure mode is RUNNING (watch keeps polling, WATCH-TIMEOUT bounds it),
    never a premature DONE."""
    pending: dict[str, bool] = {}
    for frame in frames:
        if frame.get("type") != "system":
            continue
        sub = frame.get("subtype")
        if sub == "background_tasks_changed":
            tasks = frame.get("tasks")
            if isinstance(tasks, list):
                # an entry without a task_id can never be retired — the sentinel keeps
                # it pending forever, so a malformed entry reads RUNNING, never DONE
                pending = {}
                for i, task in enumerate(tasks):
                    tid = task.get("task_id") if isinstance(task, dict) else None
                    pending[tid or f"<malformed#{i}>"] = True
        elif sub in ("task_updated", "task_notification"):
            tid = frame.get("task_id")
            status = ((frame.get("patch") or {}).get("status")
                      if sub == "task_updated" else frame.get("status"))
            if tid in pending and status in CLAUDE_TASK_TERMINAL:
                del pending[tid]
    return sorted(pending)


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
        # a result frame ends the TURN, not necessarily the round: with background
        # tasks pending the harness auto re-invokes the engine — no steer involved —
        # so this idle is a gap between turns, not terminal (field incident: DONE
        # fired in that gap and the orchestrator tore down the environment the
        # engine's backgrounded verification was still using).
        pending = claude_pending_background_tasks(frames)
        if pending:
            shown = ", ".join(pending[:3]) + ("…" if len(pending) > 3 else "")
            return ("RUNNING", f"turn ended but {len(pending)} background task(s) "
                    f"pending ({shown}) — harness auto-continues; not terminal")
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


def parse_etime(text: str) -> float:
    """ps etime ([[dd-]hh:]mm:ss) → seconds. Raises ValueError on a malformed field."""
    text = text.strip()
    days = 0
    if "-" in text:
        day_part, text = text.split("-", 1)
        days = int(day_part)
    parts = [int(p) for p in text.split(":")]
    if not 2 <= len(parts) <= 3:
        raise ValueError(text)
    while len(parts) < 3:
        parts.insert(0, 0)
    hours, minutes, seconds = parts
    return ((days * 24 + hours) * 60 + minutes) * 60 + seconds


def pane_descendants(root_pid: int) -> list[tuple[int, float]] | None:
    """(pid, age_seconds) for every descendant of the pane pid, from ONE ps snapshot.
    None on ANY probe uncertainty — ps failing, the root pid absent from a successful
    snapshot (died/reused), or a MALFORMED row reachable from the root (a dropped young
    tool must not make the remaining old rows read as 'quiet') — and the caller must
    read None as alive: a broken probe concluding 'stalled' is exactly the false
    verdict this guards."""
    try:
        proc = subprocess.run(["ps", "-axo", "pid=,ppid=,etime="],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    children: dict[int, list[tuple[int, float]]] = {}
    root_seen = False
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 2)
        if len(parts) != 3:
            return None  # short row in a fixed-format snapshot — probe poisoned
        try:
            pid, ppid = int(parts[0]), int(parts[1])
            age = parse_etime(parts[2])
        except ValueError:
            # a malformed ppid/pid/etime cannot be proven unrelated to the pane's
            # subtree, so the whole snapshot is uncertainty (review round 3)
            return None
        if pid == root_pid:
            root_seen = True
        children.setdefault(ppid, []).append((pid, age))
    if not root_seen:
        return None
    out: list[tuple[int, float]] = []
    seen: set[int] = set()
    queue = [root_pid]
    while queue:
        for pid, age in children.get(queue.pop(), ()):
            if pid not in seen:
                seen.add(pid)
                out.append((pid, age))
                queue.append(pid)
    return out


# ── escaped-descendant visibility ─────────────────────────────────────────────
# reap_tree is process-GROUP scoped on purpose — one pgid we own, never a global kill — so a
# child that setsid()s out of the pane's group is invisible to it and outlives the stop
# (field 2026-08: one stop left 32 MCP children behind, ~700MB, oldest 6 days). What follows
# makes that gap VISIBLE and nothing more: it never becomes a kill list, because the only
# processes stop signals are the members of the one group it already owned.
PS_IDENTITY_FMT = "pid=,ppid=,pgid=,lstart=,etime=,args="
_LSTART_RE = re.compile(r"\w{3} \w{3} \d{1,2} \d{2}:\d{2}:\d{2} \d{4}")


def ps_identity_rows() -> list[dict] | None:
    """Every process as {pid, ppid, pgid, lstart, etime, cmd} from ONE ps snapshot, or None
    on ANY probe uncertainty. Same discipline as pane_descendants: a row this parser cannot
    read might BE the process the caller is about to reason about, so an unreadable row makes
    the whole snapshot uncertainty instead of a shorter, confident-looking list."""
    try:
        proc = subprocess.run(["ps", "-axo", PS_IDENTITY_FMT],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    rows: list[dict] = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 9)          # pid ppid pgid + 5 lstart fields + etime + argv
        if len(parts) < 9:
            return None
        lstart = " ".join(parts[3:8])        # normalized here so both probes compare equal
        if not _LSTART_RE.fullmatch(lstart):
            return None
        try:
            pid, ppid, pgid = int(parts[0]), int(parts[1]), int(parts[2])
            parse_etime(parts[8])
        except ValueError:
            return None
        rows.append({"pid": pid, "ppid": ppid, "pgid": pgid, "lstart": lstart,
                     "etime": parts[8], "cmd": parts[9] if len(parts) > 9 else ""})
    return rows


# The one "nothing to look at" reason, kept as a constant so the probe half can tell it apart
# from a probe that tried and could not answer (m-1: [n/a] vs [unknown]).
PANE_GONE_WHY = "pane pid {pid} absent from a successful ps snapshot (already gone)"


def escaped_descendants(root_pid: int) -> tuple[list[dict] | None, str]:
    """(rows, why-not) — descendants of root_pid sitting OUTSIDE its process group, from one
    snapshot. In-group descendants are excluded deliberately: those are exactly what the reap
    owns, and reap_tree already reports its own survivors. None = the probe cannot answer."""
    rows = ps_identity_rows()
    if rows is None:
        return None, "ps snapshot failed or unparseable"
    kids: dict[int, list[dict]] = {}
    root: dict | None = None
    for row in rows:
        if row["pid"] == root_pid:
            root = row
        kids.setdefault(row["ppid"], []).append(row)
    if root is None:
        return None, PANE_GONE_WHY.format(pid=root_pid)
    out: list[dict] = []
    seen: set[int] = set()
    queue = [root_pid]
    while queue:
        for row in kids.get(queue.pop(), ()):
            if row["pid"] in seen:
                continue
            seen.add(row["pid"])
            queue.append(row["pid"])         # traverse THROUGH escapees: their kids escaped too
            if row["pgid"] != root["pgid"]:
                out.append(row)
    return out, ""


def complete_frames_integrity(sess: Session) -> tuple[list[dict], bool]:
    """All frames from COMPLETE lines from the stream START, plus a clean flag —
    False when any complete non-empty line failed to decode. Junk the stall path
    cannot read must count as ambiguity (alive), never as silence."""
    try:
        with open(sess.events, "rb") as fh:
            blob = fh.read()
    except OSError:
        return [], False
    body, nl, _tail = blob.rpartition(b"\n")
    if not nl:
        return [], True
    frames: list[dict] = []
    clean = True
    for line in body.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            frames.append(json.loads(line))
        except json.JSONDecodeError:
            clean = False
    return frames, clean


def claude_inflight(sess: Session, frames: list[dict]) -> bool:
    """True = structured evidence of in-flight work OR ambiguity: an UNMATCHED
    tool_use (no tool_result yet — covers long MCP calls served INSIDE an old
    persistent helper, where the process tree carries no request boundary at all),
    an unmatched command_lifecycle, pending background tasks, or ANY lifecycle
    frame the matcher cannot pair cleanly (missing id, duplicate start, unknown
    command state) — tri-state collapsed to alive, per the stall contract."""
    open_tools: set[str] = set()
    open_cmds: set[str] = set()
    for frame in frames:
        ftype = frame.get("type")
        if ftype in ("assistant", "user"):
            for item in (frame.get("message") or {}).get("content") or []:
                if not isinstance(item, dict):
                    continue
                if ftype == "assistant" and item.get("type") == "tool_use":
                    tid = item.get("id")
                    if not tid or tid in open_tools:
                        return True  # id-less or duplicate start: cannot pair — alive
                    open_tools.add(tid)
                elif ftype == "user" and item.get("type") == "tool_result" \
                        and item.get("tool_use_id"):
                    open_tools.discard(item["tool_use_id"])
        elif ftype == "command_lifecycle":
            cid = frame.get("command_uuid")
            state = frame.get("state")
            if not cid or state not in ("started", "completed"):
                return True  # unpairable lifecycle transition — alive
            if state == "started":
                if cid in open_cmds:
                    return True
                open_cmds.add(cid)
            else:
                open_cmds.discard(cid)
    return bool(open_tools or open_cmds or claude_pending_background_tasks(frames))


def codex_inflight(sess: Session, frames: list[dict]) -> bool:
    """True = an unmatched item/started on OUR thread (a running command/tool), or
    any pairing ambiguity. An open turn alone is NOT in-flight evidence: a wedged
    engine dies mid-turn by definition, and a healthy in-turn engine streams
    item/delta frames that keep the events file fresh anyway. When session meta
    names our thread, frames WITHOUT a threadId are ambiguous (a foreign completion
    must not close our item); without meta, no scoping is possible — pair as-is."""
    ours = sess.meta.get("thread")
    open_items: set[str] = set()
    for frame in frames:
        method = frame.get("method", "")
        if method not in ("item/started", "item/completed"):
            continue
        params = frame.get("params") or {}
        tid = params.get("threadId")
        if ours:
            if tid is None:
                return True  # unscoped lifecycle frame while scoping is required — alive
            if tid != ours:
                continue
        item_id = (params.get("item") or {}).get("id")
        if not item_id:
            return True
        if method == "item/started":
            if item_id in open_items:
                return True
            open_items.add(item_id)
        else:
            open_items.discard(item_id)
    return bool(open_items)


def omp_inflight(sess: Session, frames: list[dict]) -> bool:
    """omp's liveness is probed live: every classify sends get_state, and any answer
    lands in the events file and refreshes it. A stale file therefore already means
    the probe went unanswered — no extra frame evidence exists to consult."""
    return False


ENGINE_INFLIGHT = {"claude": claude_inflight, "codex": codex_inflight, "omp": omp_inflight}
STALL_SLACK_SECS = 60.0


def stream_stalled(sess: Session, engine: str) -> tuple[bool, str]:
    """A RUNNING projection that is likely a wedged stream, not a thinking model.
    ALL legs required, and every ambiguity reads as ALIVE (宁钝勿敏 — the honest
    fallback for a truly dead session is WATCH-TIMEOUT, never a premature verdict):

      - the events file has not grown/moved for AGENT_WATCH_STALL_MINS minutes
        (default 12; <=0 disables). Live engines keep the file fresh — streamed
        thinking/progress frames, and omp answers the get_state probe itself;
      - the engine's OWN lifecycle frames show no unmatched in-flight work
        (tool_use/tool_result, command_lifecycle, background tasks, item/started —
        per-engine matchers above). Process age cannot carry a request boundary
        (a long call served inside an old persistent helper is tree-identical to a
        wedge — review round 2, live-probed), so the stream is the primary signal;
      - the process-tree probe is a pure VETO: a descendant younger than the
        silence (plus slack) = in-flight work = alive; an uncertain probe = alive.
        Only a fully-parsed subtree with nothing young lets the verdict through.
        (A flat descendant-count threshold was refuted live in review: real panes
        carry 8-14 wrapper/MCP helper descendants.)"""
    raw = os.environ.get("AGENT_WATCH_STALL_MINS", "12")
    try:
        mins = float(raw)
    except ValueError:
        mins = 12.0
    if mins <= 0:
        return False, ""
    try:
        silence = time.time() - os.path.getmtime(sess.events)
    except OSError:
        return False, ""
    if silence < mins * 60:
        return False, ""
    inflight = ENGINE_INFLIGHT.get(engine)
    if inflight is None:
        return False, ""
    # lifecycle pairs across the WHOLE stream, never the sent-offset window: the
    # offset rotates on every steer and can cut across an operation opened before
    # it (review round 3 — the forgotten open tool_use re-enabled the false 11).
    frames, clean = complete_frames_integrity(sess)
    if not clean or inflight(sess, frames):
        return False, ""
    pane = str(sess.meta.get("pane_pid", ""))
    if not pane.isdigit():
        return False, ""
    descendants = pane_descendants(int(pane))
    if descendants is None:
        return False, ""
    if any(age <= silence + STALL_SLACK_SECS for _pid, age in descendants):
        return False, ""
    return True, (f"no new frame for {int(silence // 60)}min, no unmatched in-flight "
                  f"lifecycle in the stream, and nothing young under the pane "
                  f"({len(descendants)} descendant(s))")


def _idle_marks_path(sess: Session) -> str:
    return os.path.join(sess.run, f"{sess.name}.duplex.idle-marks")


def _idle_mark_and_count(sess: Session) -> int:
    """Distinct idle EPISODES since the last DONE. Episode identity = steer count at
    observation time: re-polling the same stuck round adds nothing; a steer that fails to
    unstick makes the next observation a new episode.

    FAIL-CLOSED to "no hint" (review 2026-08-17): the ONLY consequence of this counter is
    an advisory hint, so any state we could not durably persist must read as count=1 —
    an in-memory token or a stale pre-reset mark must never fabricate a 2nd episode.
    Append-only design: reset writes an R sentinel instead of unlinking (an unlink can be
    denied while the file stays appendable, which left stale marks alive); decode errors
    are neutralized with errors="replace" so classify can never crash here."""
    try:
        with open(os.path.join(sess.run, f"{sess.name}.duplex.sent-journal"),
                  encoding="utf-8", errors="replace") as fh:
            steers = sum(1 for _ in fh)
    except OSError:
        steers = 0
    lines: list[str] = []
    try:
        with open(_idle_marks_path(sess), encoding="utf-8", errors="replace") as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        pass
    for i in range(len(lines) - 1, -1, -1):
        if lines[i] == "R":
            lines = lines[i + 1:]
            break
    seen = set(lines)
    tok = str(steers)
    if tok not in seen:
        try:
            with open(_idle_marks_path(sess), "a", encoding="utf-8") as fh:
                fh.write(tok + "\n")
        except OSError:
            return 1  # could not persist the episode — never reason from memory
        seen.add(tok)
    return len(seen)


def _idle_marks_reset(sess: Session) -> None:
    """DONE boundary: append an R sentinel (works even when unlink would be refused).
    If even the append fails, fall back to remove; if both fail the residual is narrow —
    the next count's own append will typically fail the same way and read fail-closed."""
    try:
        with open(_idle_marks_path(sess), "a", encoding="utf-8") as fh:
            fh.write("R\n")
    except OSError:
        try:
            os.remove(_idle_marks_path(sess))
        except OSError:
            pass


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
        return EXIT_FAILED

    # 1. engine process exited? (the pane shell writes RC on engine exit)
    if os.path.exists(sess.rc):
        try:
            rc = open(sess.rc, encoding="utf-8").read().strip()
        except OSError:
            rc = "?"
        if rc != "0" and scan_quota(sess):
            print(f"STALLED-EXTERNAL: engine exited rc={rc} on a backend quota/auth error — fix credentials, then agentctl stop + restart")
            return EXIT_STALLED_EXTERNAL
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
                return EXIT_DONE
            if ok:
                note = f", deliverable fresh: {hit}" if hit else ""
                print(f"DONE: engine exited rc=0{note} (duplex engines normally stay alive — treat as complete)")
                return EXIT_DONE
            print(f"IDLE-NO-DELIVERABLE: engine exited rc=0 but '{sess.meta.get('deliverable')}' not produced this round")
            return EXIT_IDLE_NO_DELIVERABLE
        print(f"FAILED: engine exited rc={rc} — tail {sess.events} / {sess.stderr} (raw kept on disk)")
        return EXIT_FAILED

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
                    return EXIT_FAILED
                stamp = identity.IdentityStore.marker_stamp(marker)
                try:
                    first = store.apply_event(stamp["attemptId"], stamp.get("seq"))
                except identity.IdentityPersistError as exc:
                    print(f"IDENTITY-UNKNOWN: cannot record the marker adoption ({exc}) — "
                          "refusing to adopt terminal evidence")
                    return EXIT_FAILED
                again = "" if first else " (event already applied — idempotent re-read)"
                # the delivered-evidence summary is printed ONLY for a receipt that passed the
                # WS2 schema gate, so an invalid body can never speak in a DONE line either
                print(f"DONE: adopted the terminal marker of the current attempt{again} — "
                      f"engine pane already reaped; {detail}"
                      f"{receipt_note(store.delivered_receipt(marker) or {})}")
                return EXIT_DONE
            if klass == identity.UNKNOWN:
                print(f"IDENTITY-UNKNOWN: terminal marker not adoptable — {detail}")
                return EXIT_FAILED
            if klass != identity.OK:
                print(f"{klass}: terminal marker NOT adopted (kept on disk for post-mortem, "
                      f"not rewritten) — {detail}")
        print("AGENT-DEAD: no rc and no tmux session — killed mid-flight; agentctl stop to clean, then restart")
        return EXIT_FAILED

    # 2.5 torn input stream: a sender died mid-frame — nothing downstream is trustworthy
    if os.path.exists(sess.intent):
        print("FAILED: torn frame on the input stream (write-intent marker) — agentctl stop, then restart with resume args")
        return EXIT_FAILED

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
            return EXIT_FAILED
        if klass == identity.OK:
            print("WAITING-INPUT: agent wrote BLOCKED.md — read it, answer via agentctl steer")
            return EXIT_WAITING_INPUT
        print(f"{klass}: BLOCKED.md NOT adopted (kept on disk for post-mortem, not rewritten)"
              f" — {detail}")

    # 4. live projection
    state, detail = PROJECTORS[engine](sess)
    if state == "WAITING":
        print(f"WAITING-INPUT: {detail}")
        return EXIT_WAITING_INPUT
    if state == "ERROR":
        if scan_quota(sess):
            print(f"STALLED-EXTERNAL: turn failed on backend quota/auth — fix credentials, then steer to retry. {detail}")
            return EXIT_STALLED_EXTERNAL
        print(f"FAILED: engine reported an error result (turn failed, engine still alive) — {detail}")
        return EXIT_FAILED
    if state == "RUNNING":
        stalled, why = stream_stalled(sess, engine)
        if stalled:
            print(f"STALLED-STREAM: {why} — engine likely wedged mid-round; salvage "
                  "work from the checkout/commits first, then agentctl stop "
                  "(AGENT_WATCH_STALL_MINS tunes the window; 0 disables)")
            return EXIT_STALLED_STREAM
        print(f"RUNNING: {detail}")
        return EXIT_RUNNING
    ok, hit = deliverable_fresh(sess)
    receipt = None if ok else delivered_receipt(store)
    if receipt is not None:
        _idle_marks_reset(sess)
        print(f"DONE: engine idle{receipt_note(receipt)} — receipt evidence supersedes the "
              "mtime freshness heuristic")
        print(f"last: {detail}")
        return EXIT_DONE
    if not ok:
        # 2nd+ DISTINCT idle episode (episode identity = steer count, so re-polling one
        # stuck round never inflates it; DONE resets) reads as context exhaustion far more
        # often than as a wording problem — field 2026-08-17, external seat: 3 same-day
        # cases, the operator burned an extra nudge round before realizing a fresh session
        # was the fix. Observability only: the watcher gains no steer authority (auto-nudge
        # was deliberately declined by the principal, 2026-08-09 — this hint is NOT that).
        hint = ("" if _idle_mark_and_count(sess) < 2 else
                " [2nd+ idle episode this session — likely context exhaustion; a fresh "
                "session (agentctl stop + start) usually beats another nudge]")
        print(f"IDLE-NO-DELIVERABLE: engine idle but '{sess.meta.get('deliverable')}' not produced this round — steer the agent; do not stop{hint}")
        return EXIT_IDLE_NO_DELIVERABLE
    _idle_marks_reset(sess)
    note = f", deliverable fresh: {os.path.basename(hit)}" if hit else ""
    print(f"DONE: engine idle{note}")
    print(f"last: {detail}")
    return EXIT_DONE


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
            die(f"{interrupt} not accepted: {clip(json.dumps(intr, ensure_ascii=False), 200)}", EXIT_FAILED)
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
                "the replacement; check status, then retry or stop+resume", EXIT_FAILED)
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
            "engine's input stream is tainted: agentctl stop, then restart with resume args", EXIT_FAILED)
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
                "record (if any) stays authoritative", EXIT_FAILED)
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
            # THE terminal-record rotation point. A new round is now a durable fact, so the
            # previous round's conclusion — live or already delivered to a peer — is no longer
            # anybody's answer and must not be replayed by the next waiter.
            #
            # It happens HERE, and not in `agentctl steer` before this call, because a steer
            # that never reaches this point opened no round: it delivered nothing, the meta
            # still says round N, and the conclusion it would have destroyed is still the one
            # every attached waiter is entitled to. Pre-clearing unlinked both records before
            # duplexctl even ran, so a REFUSED steer (engine already exited, tainted stream,
            # budget) silently destroyed a conclusion a peer waiter had not read yet and that
            # waiter came back SUPERVISOR-LOST 12 while its peer had reported FAILED 2 —
            # exactly the divergence the delivery rule exists to prevent (review R2 F-02).
            # Same flock, same commit instant as the round bump: no waiter can observe the new
            # round with the old round's record still adoptable, or the reverse.
            for spent in (os.path.join(sess.run, f"{sess.name}.terminal.json"),
                          os.path.join(sess.run, f"{sess.name}.terminal.consumed.json")):
                try:
                    os.unlink(spent)
                except OSError:
                    pass
            for debris in globmod.glob(globmod.escape(
                    os.path.join(sess.run, f".{sess.name}.terminal.json-")) + "*.tmp"):
                try:
                    os.unlink(debris)
                except OSError:
                    pass
            # offset journal (append-only, no frame bodies — offsets and timestamps
            # only): raw events alone cannot reconstruct where a mid-turn steer
            # rotated the window, so post-mortem replay (test/corpus/) needs this
            # sidecar to project each verdict at its TRUE production offset. Best
            # effort: a failed journal write must never fail the steer itself.
            try:
                with open(os.path.join(sess.run, f"{sess.name}.duplex.sent-journal"),
                          "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"ts": time.time(),
                                         "offset": offset_box["v"]}) + "\n")
            except OSError:
                pass

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
            return EXIT_FAILED
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
            return EXIT_FAILED
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


# The watch lane's published contract, same spirit as the capability table: ONE table, read by
# `agentctl capabilities` and by nothing that also holds a second opinion.
WATCH_LANE = {
    "mode": "supervised",
    "sensing": "tmux session <session>-watchd runs `agentctl watch-daemon` — the classify "
               "polling loop lives where the worker already survives host reaping",
    "waiter": "`agentctl watch <session>` blocks reading ONLY the fenced terminal record; "
              "killing it loses nothing, re-running it recovers the same class + exit",
    "terminalClasses": sorted(identity.TERMINAL_CLASSES),
    "recordLifetime": "every published class — DONE and the seven non-DONE ones alike — stays "
                      "readable for the whole life of its round+attempt and is never consumed "
                      "by the waiter that reports it, so any number of attached waiters read "
                      "the same typed conclusion. start / steer / stop clear it.",
    "typedLost": "12 SUPERVISOR-LOST — no fenced conclusion and the supervisor cannot be shown "
                 "to be running (reason=dead) or cannot be judged at all (reason=unknown: lease "
                 "or record torn/corrupt/stale, lease without a start-time, pid recycled, probe "
                 "unusable, the waiter's own read timed out, or a rogue <session>-watchd holds "
                 "the singleton name without leasing). Never DONE, always bounded.",
    "legacyFlag": "--inline: run the sensing loop in the waiter process (pre-supervised "
                  "behaviour). No supervisor, no non-DONE persistence — a killed `--inline` "
                  "watch loses its round's conclusion, which is exactly what supervision fixes.",
    "degradation": "automatic fallback to the --inline loop happens ONLY when supervision is "
                   "structurally impossible here (no tmux, an unwritable run dir, or a pane "
                   "that exited without leasing) and is announced loudly on stderr. A live "
                   "<session>-watchd that published no lease is undecidable, not a licence to "
                   "sense inline: the waiter returns 12 SUPERVISOR-LOST with the rogue-watchd "
                   "detail and the cleanup instruction.",
}


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
    print("\nwatch lane (engine-independent — how `agentctl watch` senses and what it "
          "degrades to):")
    for key in ("mode", "sensing", "waiter", "typedLost", "legacyFlag", "degradation"):
        print(f"  {key.ljust(head - 2)} {WATCH_LANE[key]}")
    print(f"  {'persisted'.ljust(head - 2)} terminal classes "
          f"{WATCH_LANE['terminalClasses']} (10 RUNNING is not terminal and is never recorded)")
    return 0


def typed_state_document() -> dict:
    """The published machine contract for the typed state vocabulary. code / name / meaning
    only: disposition is judgement that moves with the workflow, not a runtime fact, so it is
    not published here."""
    return {
        "schemaVersion": TYPED_STATE_SCHEMA_VERSION,
        "states": [{"code": code, "name": name, "meaning": meaning}
                   for code, name, meaning in TYPED_STATES],
    }


def cmd_states(args: argparse.Namespace) -> int:
    """Runtime-generated typed state vocabulary. Same contract as `capabilities`: one table
    in this module, generated here, and no prose copy anywhere that could hold a second
    opinion about what an exit code means."""
    doc = typed_state_document()
    if args.json:
        print(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    width = max(len(s["name"]) for s in doc["states"]) + 2
    print(f"typed state vocabulary (schemaVersion {doc['schemaVersion']}) — generated from "
          f"the TYPED_STATES table in {os.path.basename(__file__)}; no prose copy exists")
    print("exit  " + "name".ljust(width) + "meaning (what the runtime observed)")
    for state in doc["states"]:
        print(f"{str(state['code']).rjust(4)}  {state['name'].ljust(width)}{state['meaning']}")
    print("\ndisposition — what an orchestrator should DO about a state — is judgement, not a "
          "runtime fact, and is deliberately not published here.")
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
    normally would have to traverse the very code that is stuck.

    The typed exit is PER VERB. `watch-state` is not an engine query at all — it is the
    waiter's canonical read of the record and of supervisor liveness — so its timeout is an
    UNDECIDABLE read (12 SUPERVISOR-LOST), never the business class 8 ENGINE-SILENT. It used
    to inherit the `send timeout` branch verbatim and hand the host a business terminal for a
    read that never completed, with no terminal record anywhere (review F-04)."""
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
    elif verb == "watch-state":
        # the four-state machine's ④: evidence unobtainable ⇒ bounded typed 12, never a
        # business conclusion. Same vocabulary the reader itself prints, so the host cannot
        # tell a timed-out read from any other undecidable one — because it must not.
        msg = (
            f"SUPERVISOR-LOST: reason=unknown the waiter's canonical read timed out after "
            f"{secs}s (AGENT_WATCH_STATUS_TIMEOUT) — neither the terminal record nor "
            f"supervisor liveness could be read, so nothing may be concluded for this round; "
            f"re-run `agentctl watch` to re-establish the sensing loop\n"
        ).encode("utf-8")
    else:
        msg = (
            f"ENGINE-SILENT: send timeout after {secs}s — the frame never went out: the writer "
            f"lock is held by another sender, or the fifo is unresponsive; inspect {stderr_log} "
            "and agentctl status, then agentctl stop + restart with the engine's resume args if "
            "it stays stuck\n"
        ).encode("utf-8")
    code = EXIT_SUPERVISOR_LOST if verb == "watch-state" else EXIT_ENGINE_SILENT

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
            # try stderr, then give up — the typed exit still carries the meaning.
            try:
                os.write(2, msg)
            except Exception:
                pass
        os._exit(code)
    signal.signal(signal.SIGALRM, fire)
    signal.alarm(secs)


def cmd_classify(args: argparse.Namespace) -> int:
    arm_watchdog(args.run_dir, args.session, status_timeout(), "classify")
    try:
        return classify(Session(args.run_dir, args.session))
    finally:
        signal.alarm(0)


# ── supervised watch: the supervisor lease and the waiter's canonical read ────────────
# Split of duties since the host started reaping background tasks every few minutes: the
# SENSING loop (classify polling) runs as a supervisor inside tmux — the one place in this lane
# that demonstrably survives the reaper — and `agentctl watch` on the host degrades to a dumb
# waiter that only ever reads what the supervisor published. A killed waiter therefore loses
# nothing: re-running it recovers the conclusion instead of restarting the classification.
#
# The waiter needs exactly two facts and this module is the ONE place that derives them: is
# there a fenced terminal conclusion for the current attempt+round (identity.terminal_verdict),
# and — only if there is not — is the supervisor demonstrably alive.
# every terminal class a watch may report — named, so this set cannot name a code the
# published vocabulary does not have
SUPERVISOR_EXITS = {EXIT_DONE, EXIT_FAILED, EXIT_WAITING_INPUT, EXIT_STALLED_EXTERNAL,
                    EXIT_IDLE_NO_DELIVERABLE, EXIT_WATCH_TIMEOUT, EXIT_ENGINE_SILENT,
                    EXIT_STALLED_STREAM}
PROCEED_TO_ARM = 13                             # arm-mode only, never leaves the waiter
# A lease older than this is a wedged supervisor, not a live one. The window is derived, never
# a bare constant: the supervisor renews the lease BEFORE it classifies, and one classify may
# legitimately block for the WHOLE control-plane timeout the operator granted it
# (AGENT_WATCH_STATUS_TIMEOUT, up to an hour). A floor of 120s therefore called a supervisor
# wedged at second 121 of a supported 300s classify — a false SUPERVISOR-LOST for a session
# that was fine (review F-06). stale_after = max(4*poll, floor, the classify budget the
# SUPERVISOR itself recorded + slack), so only a supervisor that has overrun every bound it
# was given can read as wedged.
LEASE_STALE_FLOOR = 120
LEASE_STALE_SLACK = 60          # renewal cadence + fs timestamp granularity, on top of the budget


def lease_path(run_dir: str, name: str) -> str:
    return os.path.join(run_dir, f"{name}.watch.super.json")


def supervisor_session(name: str) -> str:
    """tmux session that hosts the supervisor. Its OWN session, never a window of the worker's:
    an extra window would keep the worker session alive after the engine pane died and silently
    disable classify's `no rc + no tmux session ⇒ AGENT-DEAD` branch."""
    return f"{name}-watchd"


def write_lease(run_dir: str, name: str, payload: dict) -> None:
    """Publish the supervisor's liveness fact. Same tmp+rename discipline as every other record
    in this lane — a waiter must never read half a lease and call it a wedge."""
    path = lease_path(run_dir, name)
    tmp = os.path.join(run_dir, f".{name}.watch.super.json-{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


# The lease's numeric fields are a SCHEMA, not free-form JSON. `read_lease` used to demand
# only a JSON object, and the reader then called float() on whatever it found: the STRING
# "Infinity" converts happily, `stale_after` became inf, and a lease with a correct pid and
# start-time could impersonate a live supervisor forever — the waiter kept returning "keep
# waiting" until its own outer cap (~2h) bypassed it (review R2 F-04). Damaged evidence is the
# four-state machine's ④: the lease is refused WHOLE, and the waiter gets typed 12 at once.
# Floors, not just finiteness: a freshness budget of 0 or -1 seconds is not a budget either.
LEASE_NUMBERS = {"pollSecs": 0.0, "statusTimeout": 0.0, "maxPolls": -1.0, "iter": -1.0}


def lease_schema_damage(lease: dict) -> str:
    """"" when every numeric field PRESENT is a finite number above its floor, else why not.

    An absent field is not damage — a legacy lease carries fewer of them and the reader has a
    documented default for the two that size its window. A present one that is a string, a
    bool, a NaN or an infinity is damage: it cannot be compared, so nothing derived from it
    can be either, and a budget nobody can compare is not a softer budget."""
    for key, floor in LEASE_NUMBERS.items():
        if key not in lease:
            continue
        value = lease[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return f"`{key}` is {value!r}, not a number"
        if not math.isfinite(value):
            return f"`{key}` is {value!r}, not a finite number"
        if value <= floor:
            return f"`{key}` is {value!r}, not above {floor:g}"
    return ""


def read_lease(run_dir: str, name: str) -> tuple[dict | None, str]:
    """(lease, why). A non-regular file (symlink, fifo) is refused like every other piece of
    session state: the run dir is the boundary, a link out of it is someone else's file.

    The lease's mtime is deliberately NOT returned. It used to be, as the reference point for a
    one-shot age check, and it is exactly the datum no reader can verify: an mtime is only
    meaningful against a clock that did not step between the write and the read (review R3
    F-03). What survives is what the bytes themselves state."""
    path = lease_path(run_dir, name)
    try:
        st = os.lstat(path)
    except OSError:
        return None, f"no supervisor lease at {path}"
    if not stat.S_ISREG(st.st_mode):
        return None, f"supervisor lease {path} is not a regular file"
    try:
        with open(path, encoding="utf-8") as fh:
            lease = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, f"supervisor lease {path} is unreadable or unparseable ({exc})"
    if not isinstance(lease, dict):
        return None, f"supervisor lease {path} is not a JSON object"
    damage = lease_schema_damage(lease)
    if damage:
        return None, (f"supervisor lease {path} is damaged: {damage} — a liveness budget "
                      "that cannot be compared proves nothing about the supervisor")
    return lease, ""


def ps_start_times(pids: list[str]) -> dict[str, str] | None:
    """{pid: start-time} from ONE ps snapshot, or None when the PROBE ITSELF is broken.

    The caller always passes its own pid as a known positive: "the daemon is not in the list"
    only means death if the list can be trusted to contain a process we KNOW is running.
    Without that control a missing `ps` would read as "the supervisor died" for every session
    on the box."""
    try:
        probe = subprocess.run(["ps", "-o", "pid=,lstart=", "-p", ",".join(pids)],
                               capture_output=True, text=True, check=False, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None       # a probe that never answers is uncertainty, never an empty box:
                          # `{}` would read as "nobody is alive" for every pid asked about
    if probe.returncode not in (0, 1):
        return None
    out = {}
    for line in probe.stdout.splitlines():
        pid, _, started = line.strip().partition(" ")
        if pid.isdigit():
            out[pid] = started.strip()
    return out


def supervisor_liveness(run_dir: str, name: str, token: str, unchanged: int = 0,
                        reader_poll: float = 0.0) -> tuple[str, str]:
    """(state, detail) with state in `alive` | `dead` | `unknown`. `unknown` is not a softer
    `alive`: both it and `dead` return the same typed SUPERVISOR-LOST exit, because a waiter
    that cannot prove the sensing loop is running must not keep waiting on it.

    `unchanged` + `reader_poll` are the POLLING waiter's own clock: how many of its OWN
    consecutive polls have now seen a byte-identical lease, and how far apart those polls are.
    A waiter that supplies them is judged by counting, never by any clock — that is what makes
    the verdict that can abort a live watch immune to a host clock step in either direction
    (review R2 F-03).

    A ONE-SHOT reader (`status`, the arm read, a single `duplexctl watch-state`) has no poll
    history and therefore NO STALL VERDICT AT ALL: for it the lease is evidence of structure —
    schema, identity fence, pid + start-time — and never of age. It used to subtract the lease
    mtime from a probe file's mtime ("the filesystem's clock"), which keeps both sides in one
    clock domain but not on one side of a clock STEP: a whole-host jump forward after the last
    renewal aged a perfectly fresh lease past its window and returned 12 for a live supervisor
    (review R3 F-03). Stall is a claim about elapsed time, no one-shot read can make it from
    evidence it can verify, and 12 is a verdict that kills a live watch — so the authority to
    make it belongs to the self-clocking poller alone."""
    lease, why = read_lease(run_dir, name)
    if lease is None:
        return "unknown", why
    if lease.get("identityToken") != token:
        # Name the FENCE, not just the mismatch, and name it HERE: the supervisor may not have
        # reached its next lease renewal yet, so waiting for its exit note would be a race. The
        # host learns the same typed class publish would have refused it with.
        got = str(lease.get("identityToken") or "")
        parts, now = got.split("/"), token.split("/")
        klass = (identity.STALE_INCARNATION if len(parts) == 3 and parts[1] == now[1]
                 else identity.STALE_ATTEMPT)
        return "unknown", (f"{klass}: the supervisor sensing this session armed under a retired "
                           f"identity ('{got or '-'}' ≠ active '{token}') — no terminal "
                           "conclusion published, and nothing it computes under that identity "
                           "may ever be adopted")
    pid = str(lease.get("pid") or "")
    if not pid.isdigit():
        return "unknown", "supervisor lease carries no pid"
    snapshot = ps_start_times([pid, str(os.getpid())])
    if snapshot is None or str(os.getpid()) not in snapshot:
        return "unknown", ("the process probe cannot see our own pid — `ps` is unusable here, "
                           "so supervisor liveness is undecidable")
    if pid not in snapshot:
        return "dead", f"supervisor pid {pid} is gone and published no conclusion"
    started = lease.get("pidStart")
    if not isinstance(started, str) or not started:
        # No start-time in the lease means there is NO evidence separating our supervisor from
        # a stranger that inherited its pid: same-pid alone used to read as alive (review F-07).
        # PID-reuse suspicion is the four-state machine's ④, not a softer alive.
        return "unknown", (f"supervisor lease records no start-time for pid {pid} — the pid "
                           "alone cannot be told apart from a recycled one, so liveness is "
                           "undecidable")
    if snapshot[pid] != started:
        return "unknown", (f"supervisor pid {pid} started '{snapshot[pid]}' ≠ recorded "
                           f"'{started}' — the pid was recycled, this is not our supervisor")
    poll = float(lease.get("pollSecs") or 0)          # schema-checked in read_lease: finite
    if unchanged <= 0 or reader_poll <= 0:
        return "alive", (f"supervisor pid {pid} alive (lease structurally intact and fenced to "
                         f"this identity), iteration {lease.get('iter')} — a one-shot read "
                         "makes no staleness claim; only a polling waiter's own poll count is "
                         "admissible evidence of a stalled sensing loop")
    budget = float(lease.get("statusTimeout") or 0)
    # the supervisor's OWN recorded classify budget wins over ours: it is the process that
    # forwards AGENT_WATCH_STATUS_TIMEOUT to classify, and a waiter started with a different
    # env must not shorten a window the sensing loop was legitimately granted.
    if budget <= 0:
        budget = float(status_timeout())
    stale_after = max(4 * poll, float(LEASE_STALE_FLOOR), budget + LEASE_STALE_SLACK)
    # THE reader's own clock, and it counts INTERVALS, not samples. `stale_after` is
    # denominated in seconds because the supervisor's budget is, so covering it takes
    # ceil(stale_after / reader_poll) elapsed intervals — and n consecutive samples of an
    # unmoved lease bound only n-1 of them, because the FIRST sample establishes the baseline
    # and proves no elapsed time whatsoever. Reading the sample count as an interval count
    # fired the wedge one whole interval early: with a 300s classify budget (360s window) and a
    # 60s waiter poll, the 6th sample declared 12 after 300 observed seconds, inside the
    # tolerance a legitimately slow classify is entitled to (review R3 F-02). The floor of 2
    # intervals keeps a single missed renewal from being a wedge. Nothing here reads a clock,
    # so nothing here can be moved by one.
    intervals = max(2, math.ceil(stale_after / reader_poll))
    need = intervals + 1
    if unchanged >= need:
        return "unknown", (f"supervisor pid {pid} is alive but its lease has not moved across "
                           f"{unchanged - 1} elapsed intervals of this waiter's own polls "
                           f"(>= {intervals} intervals of {reader_poll:g}s, i.e. {need} "
                           f"consecutive polls, to cover the {int(budget)}s classify budget it "
                           "recorded) — wedged, not sensing")
    return "alive", (f"supervisor pid {pid} alive, lease unmoved across {unchanged - 1} of the "
                     f"{intervals} intervals this waiter must observe, iteration "
                     f"{lease.get('iter')}")


def watch_state(args: argparse.Namespace) -> int:
    """The waiter's ONE read. Priority is the contract, not an implementation detail:

      1. a valid fenced terminal record wins — "the supervisor died" must never overwrite a
         conclusion it published on its way out;
      2. no conclusion + a demonstrably live supervisor ⇒ keep waiting;
      3. no conclusion + anything else (dead, wedged, pid recycled, lease or record torn,
         corrupt, stale, unreadable) ⇒ typed SUPERVISOR-LOST, bounded, never DONE.

    `--arm` is the same read taken BEFORE a supervisor is established: a conclusion already on
    disk IS this invocation's answer (that is exactly the recovery path a killed waiter takes),
    and only when there is none does the caller go on to establish the sensing loop.

    `--armed-seq` is the delivery watermark the reading waiter captured when it armed
    (`identity watermark`). It widens rule 1 by exactly one case: a conclusion that was already
    DELIVERED to a peer waiter still counts for a waiter that was attached when it was
    published, so two waiters on one supervisor cannot disagree about the same terminal event
    (review F-02). Attachment is a comparison of persisted publish sequences within ONE
    attempt, never of clocks and never across the identity fence.

    `--lease-unchanged` + `--poll` are the polling waiter's own clock, and the ONLY input that
    can produce rule 3's wedge case: how many of ITS consecutive polls have seen an unmoved
    lease, and how far apart they are. Without them the read makes no staleness claim at all —
    see `supervisor_liveness`."""
    run, name = args.run_dir, args.session
    sess = Session(run, name)
    if not sess.meta:
        print(f"SESSION-GONE: no duplex state for '{name}' ({sess.meta_path}) — the session was "
              "stopped or cleaned while this waiter was attached")
        return 1
    store = identity.IdentityStore(run, name)
    _rec, id_status = store.load()
    if id_status != identity.STATUS_OK:
        # identity is the fence every later decision leans on; without it nothing may be
        # concluded AND nothing may be armed (a supervisor with no identity could publish
        # nothing anyway). Same fail-closed exit both surfaces already use.
        print(f"IDENTITY-UNKNOWN: active identity record is {id_status} ({store.path})"
              f"{' — ' + store.corrupt_reason if store.corrupt_reason else ''} — no state may be "
              "adopted or concluded; agentctl stop, then restart to establish a new attempt")
        return EXIT_FAILED
    state, rc, detail = store.terminal_verdict(armed_seq=args.armed_seq)
    if state == "ok":
        print(detail)
        return rc
    if args.arm:
        if state == "unusable":
            print(f"note: ignoring unusable terminal evidence — {detail}")
        return PROCEED_TO_ARM
    live, why = supervisor_liveness(run, name, store.token(),
                                    unchanged=args.lease_unchanged, reader_poll=args.poll)
    if live == "alive":
        print(f"RUNNING: {why}"
              + (f" (terminal evidence present but not adoptable — {detail})"
                 if state == "unusable" else ""))
        return EXIT_RUNNING
    print(f"SUPERVISOR-LOST: reason={'dead' if live == 'dead' else 'unknown'} {why}"
          + (f"; terminal evidence present but not adoptable — {detail}"
             if state == "unusable" else "")
          + " — the sensing loop cannot be shown to be running and published no conclusion for "
            "this round; re-run `agentctl watch` to re-establish it, or `agentctl status` for a "
            "one-shot verdict"
          # a refusal the supervisor could not publish (stale attempt / round / a failed write)
          # must still reach the host: silence there is how a fenced-out watcher went dark.
          + last_words(run, name))
    return EXIT_SUPERVISOR_LOST


def last_words(run_dir: str, name: str) -> str:
    """The supervisor's exit note, if it left one — bounded, and diagnostics ONLY: the typed
    exit above it is the contract. It exists because the interesting deaths are the ones with
    nothing to publish (a fenced-out attempt, a refused write), and those used to be invisible
    from the host the moment sensing moved off it."""
    try:
        with open(os.path.join(run_dir, f"{name}.watch.super.exit"), encoding="utf-8") as fh:
            note = fh.read(1200).strip()
    except OSError:
        return ""
    return f"\nsupervisor's last words: {note}" if note else ""


def cmd_watch_state(args: argparse.Namespace) -> int:
    arm_watchdog(args.run_dir, args.session, status_timeout(), "watch-state")
    try:
        return watch_state(args)
    except Exception as exc:      # noqa: BLE001 — a crashed reader is undecidable, not a verdict
        print(f"SUPERVISOR-LOST: reason=unknown the waiter's read failed ({exc!r}) — no "
              "conclusion may be inferred from a failed read")
        return EXIT_SUPERVISOR_LOST
    finally:
        signal.alarm(0)


def cmd_watch_lease(args: argparse.Namespace) -> int:
    """Renew the supervisor's liveness lease. Called by the supervisor itself once per poll, and
    doubles as its identity check: a supervisor whose arm-time token no longer matches the active
    record has been retired (stop, --replace, resume) and MUST stop sensing — its next conclusion
    would be refused at publish anyway, and a retired lease would keep waiters attached to a
    supervisor that can never speak for them."""
    store = identity.IdentityStore(args.run_dir, args.session)
    token = store.token()
    if args.armed and args.armed != token:
        # name the FENCE that retired it, in the same vocabulary publish would have used — the
        # host reads this line, and "retired" alone does not say whether an attempt rotated
        # under the supervisor or the process incarnation did.
        armed_parts, now_parts = args.armed.split("/"), token.split("/")
        if len(armed_parts) != 3:
            klass = identity.UNKNOWN
        elif armed_parts[1] == now_parts[1]:
            klass = identity.STALE_INCARNATION
        else:
            klass = identity.STALE_ATTEMPT
        print(f"{klass}: the active identity rotated under this supervisor (armed "
              f"'{args.armed}' ≠ now '{token}') — sensing stops, no terminal conclusion "
              "published, no delivery receipt")
        return 3
    pid = str(args.pid or os.getpid())
    snapshot = ps_start_times([pid]) or {}
    started = snapshot.get(pid, "")
    if not started:
        # A lease whose pid carries no start-time is not a weaker lease, it is an UNFENCEABLE
        # one: the reader could not tell our supervisor from a stranger that recycled the pid,
        # so it refuses the lease anyway (supervisor_liveness). Failing HERE turns that into a
        # loud stop with a reason instead of a sensing loop no waiter can ever adopt.
        print("SUPERVISOR-UNFENCEABLE: `ps` returned no start-time for supervisor pid "
              f"{pid} — the liveness lease would carry no incarnation evidence and every "
              "waiter would have to refuse it; sensing stops, no terminal conclusion "
              "published, no delivery receipt")
        return 3
    write_lease(args.run_dir, args.session,
                {"schemaVersion": identity.SCHEMA_VERSION,
                 "pid": pid,
                 "pidStart": started,
                 "identityToken": token,
                 "tmux": supervisor_session(args.session),
                 "round": (Session(args.run_dir, args.session).meta.get("round") or "0"),
                 "pollSecs": args.poll,
                 # the classify budget THIS supervisor runs with — the reader sizes its
                 # stale-lease window from it so a legitimately slow classify is never a wedge
                 "statusTimeout": status_timeout(),
                 "maxPolls": args.max_polls,
                 "iter": args.iter,
                 "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    return 0


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
    if args.op == "watermark":
        # the delivery watermark a waiter captures as it ARMS: the highest publish sequence
        # THIS ATTEMPT already has on disk. Everything above it was published while this waiter
        # was attached, everything at or below it belonged to an episode that ended before it
        # existed. A persisted counter, so the comparison survives a host clock step (review R2
        # F-03); attempt-scoped, because the counter restarts at 0 on every start/replace while
        # the previous attempt's records stay on disk (review R3 F-01).
        print(store.delivery_watermark())
        return 0
    if args.op in ("start", "replace", "resume"):
        try:
            rec = store.transition(args.op)
        except (identity.IdentityPersistError, ValueError) as exc:
            die(f"IDENTITY-PERSIST-FAILED: {exc}", EXIT_FAILED)
        print(f"identity {args.op}: attempt {rec['attemptId']} incarnation "
              f"{rec.get('processIncarnation') or 'UNESTABLISHED'}")
        return 0
    if args.op == "publish":
        if args.round is None:
            # REQUIRED, not defaulted. This is the one identity surface outside this process,
            # so an omitted round here is not "the caller does not care": it is an unfenced
            # write, and the writer would then stamp the record with whatever round the meta
            # had reached by publish time — publishing the round the caller CONCLUDED as the
            # round a steer has since opened (review R2 F-01). Refuse the publish instead.
            print(f"{identity.UNKNOWN}: `identity publish` requires --round (the round the "
                  "conclusion was computed for, captured BEFORE classify) — an unfenced "
                  "publish is refused: no terminal conclusion published, no delivery receipt")
            return EXIT_FAILED
        try:
            klass, detail = store.publish_terminal(args.armed, args.round, rc=args.rc,
                                                   detail=args.detail)
        except identity.IdentityPersistError as exc:
            print(f"IDENTITY-UNKNOWN: reason={identity.PUBLISH_INTERRUPTED} {exc} — no "
                  "terminal conclusion published")
            return EXIT_FAILED
        if klass != identity.OK:
            print(f"{klass}: {detail}")
            return EXIT_FAILED
        # the machine line the DONE verdict carries: reason= first, evidence after
        print(detail)
        return 0
    try:
        store.clear()
    except identity.IdentityPersistError as exc:
        die(f"IDENTITY-PERSIST-FAILED: {exc} — identity state left UNCHANGED; a lock that "
            "cannot be acquired proves nothing about holders", EXIT_FAILED)
    return 0




# ── supervised lane verbs (salvaged from archive/agentctl-lib-attempt commit ②+⑤: the
# bash-side decision logic — sense loop, stop cleanup/sentinel, arm/wait — as python verbs;
# function bodies verbatim from the reviewed archive supervise module) ─────────────────

_CTL = os.path.abspath(__file__)  # self-exec: the salvaged verbs live in this very file now

def _ctl(run_dir: str, *argv: str, merge_stderr: bool = False) -> tuple[int, str]:
    """One `duplexctl <verb>` round trip, exactly as the shell made it: stdout captured with
    trailing newlines stripped (command substitution semantics), stderr passed through unless
    the shell redirected it with `2>&1`."""
    proc = subprocess.run([sys.executable, _CTL, "--run-dir", run_dir, *argv],
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT if merge_stderr else None,
                          text=True)
    return proc.returncode, (proc.stdout or "").rstrip("\n")

def _sleep(secs) -> None:
    """`sleep <secs>` through PATH — see the note above."""
    try:
        subprocess.run(["sleep", str(secs)], check=False)
    except OSError:
        pass

def _rm_f(*paths: str) -> None:
    """`rm -f` through PATH — see the note in `cmd_supervisor_retire`."""
    try:
        subprocess.run(["rm", "-f", *paths], stderr=subprocess.DEVNULL, check=False)
    except OSError:
        pass

_ASCII_DIGITS = re.compile(r"^[0-9]+$")

def _ascii_int(value: str) -> int | None:
    """ASCII digits and NOTHING else, or None.

    `str.isdigit()` is true for `²` and the other unicode digit forms that `int()` then
    refuses — an unusable probe became a ValueError on a path contracted never to change its
    caller's rc. The old shell's `case $v in ''|*[!0-9]*) return 1` accepted exactly the
    alphabet below, padding and full-width digits included as UNUSABLE. `int()` stays guarded
    regardless: no vocabulary surprise may raise out of here.
    """
    if _ASCII_DIGITS.match(value) is None:
        return None
    try:
        return int(value)
    except ValueError:      # unreachable through the pattern above, and not worth trusting
        return None

def _stat_mtime(path: str) -> int | None:
    """Epoch seconds of `path`, or None when the probe itself fails.

    The two `stat` dialects are probed SEPARATELY and each result validated numeric, because
    a failed dialect's stdout must never leak into the arithmetic: GNU `stat -f` prints
    filesystem status to stdout and still fails. Exit status is deliberately not consulted —
    all-digits stdout is the whole acceptance test, which is what makes a broken probe
    (neither dialect answering) degrade to silence instead of to a false sentinel.

    Kept on the external binary rather than os.path.getmtime for the same reason
    `cmd_supervisor_retire` keeps `rm`: the dialect probe IS the behaviour under contract.
    """
    for flag, fmt in (("-f", "%m"), ("-c", "%Y")):
        try:
            probe = subprocess.run(["stat", flag, fmt, path], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, check=False)
        except OSError:
            continue
        # `$(…)` strips the trailing newlines and NOTHING else: the old shell case rejected
        # any other whitespace as a non-digit, and a wider vocabulary here would turn an
        # unusable probe into a timestamp
        mtime = _ascii_int((probe.stdout or "").rstrip("\n"))
        if mtime is not None:
            return mtime
    return None

def _clock() -> str:
    return time.strftime("%H:%M:%S")

def _watch_exit(rc: int) -> int:
    """Every watch exit prints the verdict twice: the typed `=== … ===` line for humans and a
    final `EXIT=<n>` for pipes — a wrapper that swallows the process exit code can still parse
    the verdict off the last line."""
    print(f"EXIT={rc}")
    sys.exit(rc)

def _session_round(run_dir: str, name: str) -> str:
    """The round a conclusion computed NOW would be about. Empty normalizes to 0, the same
    default the writer uses, so a round-less legacy meta is not a permanent refusal."""
    return (identity._meta_read(os.path.join(run_dir, f"{name}.duplex.meta")).get("round")
            or "0")

def _watch_pid_path(run_dir: str, name: str) -> str:
    return os.path.join(run_dir, f"{name}.duplex.watch.pid")

def watcher_alive(run_dir: str, name: str) -> bool:
    """A live `agentctl watch` publishes its own pid; a stale file (watcher crashed or was
    killed with the orchestrator's shell) reads as ABSENT — over-reminding is cheap, a RUNNING
    session nobody watches is not."""
    try:
        with open(_watch_pid_path(run_dir, name), encoding="utf-8") as fh:
            pid = fh.read().strip()
    except OSError:
        return False
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except (ValueError, OverflowError, OSError):
        return False
    return True

def _tombstone_path(run_dir: str, name: str) -> str:
    return os.path.join(run_dir, f"{name}.watch.tombstone.jsonl")

def consume_tombstone(run_dir: str, name: str) -> None:
    """Arming a new watcher or stopping the session resolves any prior death: rotate the
    tombstone into .consumed (forensics kept) so status never re-reports a death across
    re-arms, restarts of the same name, or long-dead history.

    A FAILED append must not destroy the forensics: the unlink only happens once the copy is
    on disk. An unconsumed tombstone re-reports at worst, a deleted one is gone for good."""
    path = _tombstone_path(run_dir, name)
    if not os.path.isfile(path):
        return
    try:
        with open(path, "rb") as src, open(path + ".consumed", "ab") as dst:
            dst.write(src.read())
    except OSError:
        return
    try:
        os.unlink(path)
    except OSError:
        pass

def super_note(run_dir: str, name: str, text: str) -> None:
    """The supervisor's last words, for the waiter to relay: a refusal nobody may publish must
    not become a refusal nobody hears about either."""
    tmp = os.path.join(run_dir, f"{name}.watch.super.exit.tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        os.replace(tmp, os.path.join(run_dir, f"{name}.watch.super.exit"))
    except OSError:
        pass

def _read_state(run_dir: str, name: str, arm: bool = False, armed_seq: int | None = None,
                lease_unchanged: int | None = None, poll: float | None = None,
                quiet: bool = False) -> tuple[int, str]:
    """The waiter's canonical read, as its own process — see the watchdog note above.

    `--armed-seq` rides along whenever the caller captured one at arm time; the
    lease-unchanged pair ONLY when the caller is a polling loop with its own clock, because
    without both the read makes no staleness claim at all."""
    argv = ["watch-state", name]
    if armed_seq is not None:
        argv += ["--armed-seq", str(armed_seq)]
    if lease_unchanged:
        argv += ["--lease-unchanged", str(lease_unchanged), "--poll", str(poll)]
    if arm:
        argv.append("--arm")
    if quiet:
        proc = subprocess.run([sys.executable, _CTL, "--run-dir", run_dir, *argv],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return proc.returncode, ""
    return _ctl(run_dir, *argv)

def deliver_conclusion(run_dir: str, name: str, rc: int, armed_seq: int | None,
                       lease_unchanged: int | None, poll: float | None) -> None:
    """Rotating a REPORTED non-DONE conclusion to `<s>.terminal.consumed.json` is DELIVERY,
    not destruction: the canonical reader still adopts the rotated record for every waiter
    that was already attached when it was published.

    Only a class this waiter actually read OFF the record is deliverable. 12 SUPERVISOR-LOST
    and 1 SESSION-GONE are verdicts about the ABSENCE of an adoptable record — rotating one
    away would delete evidence the waiter explicitly refused to trust."""
    if rc not in (2, 4, 5, 6, 7, 8, 11):
        return
    marker = os.path.join(run_dir, f"{name}.terminal.json")
    if not os.path.isfile(marker):
        return                                  # already delivered by an attached peer
    again, _ = _read_state(run_dir, name, arm=True, armed_seq=armed_seq,
                           lease_unchanged=lease_unchanged, poll=poll, quiet=True)
    if again != rc:
        return
    try:
        os.replace(marker, os.path.join(run_dir, f"{name}.terminal.consumed.json"))
    except OSError:
        pass

def cmd_status(args: argparse.Namespace) -> int:
    """`agentctl status <session>` — one classify, one fenced publish, and the advisory notes
    about a watcher that is not there.

    Snapshot the identity AND the round BEFORE classify: the publish below re-reads both and
    refuses if either rotated in between, so a conclusion computed under one attempt — or for
    a round a steer has since closed — can never be published as the current one."""
    run, name = args.run_dir, args.session
    armed = identity.IdentityStore(run, name).token()
    rnd = _session_round(run, name)
    rc, msg = _ctl(run, "classify", name)
    if msg:
        print(msg)                              # a died classify says it all on stderr
    # one-shot status persists DONE only when the deliverable gate vouched for it — a bare
    # idle read at a turn boundary must not become durable truth; sessions without a declared
    # deliverable get their marker from watch's 2-stable read.
    declared = identity._meta_read(
        os.path.join(run, f"{name}.duplex.meta")).get("deliverable", "")
    if rc == 0 and declared:
        prc, pmsg = _ctl(run, "identity", "publish", name, "--armed", armed, "--round", rnd)
        if pmsg:
            print(pmsg)
        if prc != 0:
            rc = 2                              # not ours to publish: never report OK
    # RUNNING with nobody watching is the field's most expensive omission. Advisory only: the
    # typed line and the exit code are untouched.
    if rc == 10 and not watcher_alive(run, name):
        print(f"note: no watcher armed — arm: agentctl watch {name} (run_in_background)")
        tomb = _tombstone_path(run, name)
        # Second liveness check right at the emit point: a re-arm racing this call has
        # already consumed the tombstone AND flipped liveness.
        if os.path.isfile(tomb) and not watcher_alive(run, name):
            # single read + emptiness guard: a rotation racing between the test and the read
            # must not print an empty attribution
            last = ""
            try:
                with open(tomb, encoding="utf-8", errors="replace") as fh:
                    lines = [ln for ln in fh.read().splitlines() if ln]
                last = lines[-1] if lines else ""
            except OSError:
                last = ""
            if last:
                print(f"note: previous watcher killed externally — {last} — "
                      "killed ≠ worker dead")
            # The host reaps background tasks in batches. Correlation here is tombstone-mtime
            # proximity only — honest wording, no causality claim.
            peers = ""
            for peer_tomb in sorted(globmod.glob(os.path.join(run, "*.watch.tombstone.jsonl"))):
                if not os.path.isfile(peer_tomb) or peer_tomb == tomb:
                    continue
                peer = os.path.basename(peer_tomb)[: -len(".watch.tombstone.jsonl")]
                if watcher_alive(run, peer):
                    continue
                try:
                    close = abs(os.path.getmtime(peer_tomb) - os.path.getmtime(tomb)) <= 120
                except OSError:
                    close = False
                if close:
                    peers += f" {peer}"
            if peers:
                print(f"note: watchers of:{peers} also died within ±120s (likely one reap) "
                      "— re-arm each")
    return rc

def cmd_watch_tombstone(args: argparse.Namespace) -> int:
    """External kills are non-deterministic and the sender is invisible from inside the
    sandbox. Leave an attributable tombstone so the death is diagnosable."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = (f'{{"ts":"{stamp}","event":"watcher-killed","signal":"{args.signal}",'
            f'"ppid":{args.ppid},"uptime_s":{args.uptime}}}\n')
    try:
        with open(_tombstone_path(args.run_dir, args.session), "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass
    return 0

def cmd_watch_arm(args: argparse.Namespace) -> int:
    """Publish this waiter's pid, resolve any prior death, and announce the arm."""
    run, name = args.run_dir, args.session
    try:
        with open(_watch_pid_path(run, name), "w", encoding="utf-8") as fh:
            fh.write(f"{args.pid}\n")
    except OSError:
        pass
    consume_tombstone(run, name)
    print(f"=== [{name}] DUPLEX-WATCH ARMED at {_clock()} "
          "(stateless — safe to kill and re-run) ===")
    return 0

def cmd_watch_arm_read(args: argparse.Namespace) -> int:
    """The arm-time read: a conclusion already on disk is this invocation's answer (that IS
    the recovery path a killed waiter takes), unless a previous waiter already delivered it.
    PROCEED_TO_ARM means there is none and the caller goes on to establish the sensing loop."""
    run, name = args.run_dir, args.session
    rc, msg = _read_state(run, name, arm=True, armed_seq=args.armed_seq)
    if rc == PROCEED_TO_ARM:
        if msg:
            print(msg)
        return PROCEED_TO_ARM
    print(f"=== [{name}] {msg} ===")
    deliver_conclusion(run, name, rc, args.armed_seq, None, None)
    return _watch_exit(rc)

def _lease_mark(run_dir: str, name: str) -> bytes:
    """The lease's current bytes — b"" when there is no readable lease. Every renewal bumps
    `iter`, so unchanged bytes mean the sensing loop did not renew. Content, never mtime: the
    waiter's own poll count is the only clock a wedge verdict may rest on."""
    try:
        with open(lease_path(run_dir, name), "rb") as fh:
            return fh.read()
    except OSError:
        return b""

def cmd_watch_wait(args: argparse.Namespace) -> int:
    """The dumb wait: read the fenced record, never re-derive it. Bounded by construction —
    the supervisor self-terminates at its own poll budget, so twice that budget plus slack is
    only reachable by a supervisor that is alive and no longer concluding anything.

    This loop is also the waiter's OWN CLOCK and the only holder of stall authority in the
    lane: it counts consecutive polls over a byte-identical lease and hands that count to the
    canonical reader, which sizes the threshold from the supervisor's recorded budget. n
    consecutive samples bound n-1 elapsed intervals, and the reader converts."""
    run, name = args.run_dir, args.session
    poll, maxp = args.poll, args.max_polls
    cap = maxp * 2 + 24
    mark_seen, same = b"", 0
    graced = False
    i = 1
    while i <= cap:
        mark = _lease_mark(run, name)
        if not mark:
            same = 0                            # no lease to have watched
        elif mark == mark_seen:
            same += 1
        else:
            same, mark_seen = 1, mark
        rc, msg = _read_state(run, name, armed_seq=args.armed_seq,
                              lease_unchanged=same, poll=poll)
        if rc == EXIT_SUPERVISOR_LOST and not graced and "supervisor's last words" not in msg:
            # retirement race: the killer writes the last-words note a beat AFTER the sensing
            # process dies, so a LOST read inside that gap would report a mysterious death
            # with no cause. ONE grace poll turns a mid-retirement read into the noted
            # verdict; a real crash (no note ever) just repeats LOST one poll later.
            graced = True
            cap += 1                            # the deferred re-read must happen even when the
            i += 1                              # grace lands on the final budgeted poll —
            _sleep(poll)                        # bounded: one extra iteration, once, ever
            continue
        if rc != EXIT_RUNNING:
            print(f"=== [{name}] {msg} ===")
            deliver_conclusion(run, name, rc, args.armed_seq, same, poll)
            return _watch_exit(rc)
        if i % 12 == 0:
            print(f"[{name}] heartbeat iter {i} {_clock()} — {msg}")
        i += 1
        _sleep(poll)
    print(f"=== [{name}] SUPERVISOR-LOST: reason=unknown the supervisor is alive but "
          f"concluded nothing in {cap} waiter polls (its own budget is {maxp} polls) — "
          f"inspect {run}/{name}.watch.super.log ===")
    return _watch_exit(EXIT_SUPERVISOR_LOST)

ARM_RETIRE_FIRST = 4        # decided: retire what is provably not ours, then spawn

ARM_SPAWN = 3               # decided: spawn, nothing to retire

ARM_UNDECIDABLE = 2         # decided: nothing may be concluded or retired — the shell maps
                            # this to the waiter's typed SUPERVISOR-LOST

def cmd_watch_arm_check(args: argparse.Namespace) -> int:
    run, name = args.run_dir, args.session
    rc, _ = _read_state(run, name, armed_seq=args.armed_seq, quiet=True)
    if rc == EXIT_RUNNING:
        return 0                    # already sensing under the current identity — attach
    if shutil.which("tmux") is None:
        print("no tmux on PATH — the sensing loop has nowhere to live")
        return 1
    # The run dir carries the lease AND the terminal record: unwritable, no supervisor can
    # ever report anything, and the arm window would only be ten seconds of waiting for that.
    probe = os.path.join(run, f".{name}.super.wprobe.{os.getpid()}")
    try:
        with open(probe, "w", encoding="utf-8"):
            pass
    except OSError:
        print(f"run dir {run} is not writable — no lease and no terminal record can be "
              "published")
        return 1
    try:
        os.unlink(probe)
    except OSError:
        pass
    # Retire ONLY what is provably not ours: a live -watchd session with no lease yet is a
    # supervisor still starting up (very likely another waiter's, one second ahead of us), and
    # killing it would turn the singleton into a thrash. Anything else — a lease from another
    # identity, or lease residue with no session — is dead weight and goes.
    try:
        leased = os.path.getsize(lease_path(run, name)) > 0
    except OSError:
        leased = False
    if not tmux_alive(supervisor_session(name)) or leased:
        return ARM_RETIRE_FIRST
    return ARM_SPAWN

def cmd_watch_arm_wait(args: argparse.Namespace) -> int:
    """Readiness is OBSERVED, never assumed: the supervisor publishes its lease before it
    senses anything, so the lease appearing is the proof that the pane really ran our
    command."""
    run, name = args.run_dir, args.session
    try:
        tries = int(os.environ.get("AGENTCTL_SUPERVISOR_ARM_TRIES", "50"))
    except ValueError:
        tries = 50
    i = 0
    while i < tries:
        try:
            if os.path.getsize(lease_path(run, name)) > 0:
                return 0
        except OSError:
            pass
        _sleep(0.2)
        i += 1
    sup = supervisor_session(name)
    if args.mine == 1:
        # We claimed the name and our own pane still published nothing: the sensing verb
        # cannot run in this environment. The caller retires what it created — it is ours to
        # kill, and leaving a leaseless pane behind would make the NEXT waiter read it as a
        # rogue — then degrades loudly.
        print(f"the '{sup}' pane this waiter started published no lease within the arm window "
              f"— the sensing verb cannot run in this environment (see "
              f"{run}/{name}.watch.super.log)")
        return ARM_RETIRE_FIRST
    print(f"tmux session '{sup}' already existed and published no supervisor lease for this "
          "identity within the arm window — a rogue or wedged watchd is holding the singleton "
          "name (it may belong to another run dir, or predate this attempt). It is NOT retired "
          "automatically: killing a session this waiter cannot identify is the one move that "
          f"could murder a healthy supervisor. Inspect it with 'tmux attach -t {sup}', then "
          f"'tmux kill-session -t {sup}' and re-run 'agentctl watch {name}'")
    return ARM_UNDECIDABLE

def cmd_supervisor_retire(args: argparse.Namespace) -> int:
    """The non-tmux half of retirement: the last words, then the lease.

    That order is the contract, not tidiness — the missing lease IS the evidence that produces
    the waiter's typed 12, so anything meant to ride that verdict has to be on disk before the
    evidence appears. The lease is removed LAST and re-removed: a renewal already in flight
    when the kill landed can recreate it a moment later, and a lease outliving its supervisor
    is exactly the evidence a later waiter would misread as "someone is sensing"."""
    run, name = args.run_dir, args.session
    if args.why:
        super_note(run, name, f"SUPERVISOR-RETIRED: {args.why} — sensing stopped, no terminal "
                              "conclusion published")
    else:
        # no cause to leave — and a predecessor's last words are not this retirement's
        try:
            os.unlink(os.path.join(run, f"{name}.watch.super.exit"))
        except OSError:
            pass
    path = lease_path(run, name)
    i = 0
    while i < 20:
        # `rm -f` through PATH, exactly as the shell did it. The set of processes a verb
        # executes is part of what an observer can see — the suite's retirement-order probe
        # is an `rm` shim that samples the run dir at the instant the lease disappears — so
        # swapping in os.unlink() here would silently change observable behaviour, which this
        # refactor is not allowed to do.
        _rm_f(path, *globmod.glob(globmod.escape(os.path.join(run, f".{name}.watch.super.json-")) + "*.tmp"))
        if not os.path.exists(path):
            break
        _sleep(0.1)
        i += 1
    return 0

def _sense_conclude(args: argparse.Namespace, rnd: str, rc: int, msg: str) -> None:
    """One conclusion point for both modes. Daemon: publish through the fenced writer and stop
    — a refused publish publishes NOTHING and leaves the refusal where the waiter reads it.
    Inline: the pre-supervised behaviour (DONE publishes, everything else prints)."""
    run, name = args.run_dir, args.session
    if args.mode == "daemon":
        prc, pmsg = _ctl(run, "identity", "publish", name, "--armed", args.armed,
                         "--rc", str(rc), "--round", rnd, "--detail", msg, merge_stderr=True)
        if prc != 0:
            print(f"[{name}] conclusion {rc} NOT published: {pmsg}")
            super_note(run, name, pmsg)
            sys.exit(3)
        print(f"[{name}] published {rc} — {msg}\n{pmsg}")
        sys.exit(0)
    if rc == EXIT_DONE:
        # same round fence as the daemon: rnd is the round captured BEFORE this classify
        prc, pmsg = _ctl(run, "identity", "publish", name, "--armed", args.armed,
                         "--round", rnd)
        if pmsg:
            msg = f"{msg}\n{pmsg}"
        if prc != 0:
            rc = EXIT_FAILED      # armed under another identity: publish nothing, report the class
    print(f"=== [{name}] {msg} ===")
    _watch_exit(rc)

def cmd_sense_loop(args: argparse.Namespace) -> int:
    run, name = args.run_dir, args.session
    poll, maxp, silent_max = args.poll, args.max_polls, args.silent_polls
    if args.mode == "daemon":
        try:
            os.unlink(os.path.join(run, f"{name}.watch.super.exit"))
        except OSError:
            pass
        print(f"=== [{name}] WATCH-SUPERVISOR armed at {_clock()} pid {os.getpid()} — the "
              "host waiter reads only what this publishes ===")
        # the lease goes out BEFORE any sensing: the arming waiter blocks on exactly this
        # file, so it must mean "the pane really ran our command", not "a pane exists".
        rc, out = _ctl(run, "watch-lease", name, "--armed", args.armed, "--pid",
                       str(os.getpid()), "--poll", str(poll), "--max-polls", str(maxp),
                       "--iter", "0", merge_stderr=True)
        if rc != 0:
            print(out)
            super_note(run, name, out)
            return 3
        _install_supervisor_traps(run, name)
    idle = silent = tmo = 0
    i = 1
    rnd = _session_round(run, name)   # set before any conclude path (MAX=0 corner)
    while i <= maxp:
        if args.mode == "daemon":
            # renew liveness BEFORE sensing, and let the renewal double as the identity
            # check: a supervisor whose attempt rotated must stop sensing rather than compute
            # a verdict it could never publish — and must say WHICH fence retired it.
            rc, lease = _ctl(run, "watch-lease", name, "--armed", args.armed, "--pid",
                             str(os.getpid()), "--poll", str(poll), "--max-polls", str(maxp),
                             "--iter", str(i), merge_stderr=True)
            if rc != 0:
                print(lease)
                super_note(run, name, lease)
                return 3
        # the round the verdict below is ABOUT, captured before classify: publish refuses it
        # if a steer opened the next round in between.
        rnd = _session_round(run, name)
        rc, msg = _ctl(run, "classify", name)
        if rc == EXIT_RUNNING:
            silent = silent + 1 if "no output since last steer" in msg else 0
            if silent >= silent_max:
                _sense_conclude(args, rnd, EXIT_ENGINE_SILENT,
                                f"ENGINE-SILENT at {_clock()} — steer delivered but no engine "
                                f"output ~2min; inspect {run}/{name}.duplex.stderr.log")
            idle = tmo = 0
        elif rc in (EXIT_DONE, EXIT_IDLE_NO_DELIVERABLE):
            # stability: require 2 consecutive terminal reads — a turn boundary right before
            # an auto-consumed queued message must not read as terminal.
            idle += 1
            silent = tmo = 0
            if idle >= 2:
                _sense_conclude(args, rnd, rc, msg)
        elif rc == EXIT_ENGINE_SILENT:
            # classify's own control-plane timeout — transient lock/engine contention is
            # possible, so require 2 consecutive reads before killing the watch (mirrors the
            # idle stability rule).
            tmo += 1
            idle = silent = 0
            if tmo >= 2:
                _sense_conclude(args, rnd, EXIT_ENGINE_SILENT, msg)
        else:
            _sense_conclude(args, rnd, rc, msg)
        if i % 12 == 0:
            print(f"[{name}] heartbeat iter {i} {_clock()} — {msg}")
        i += 1
        _sleep(poll)
    _sense_conclude(args, rnd, EXIT_WATCH_TIMEOUT,
                    "WATCH TIMEOUT — engine still active; re-run watch or investigate")
    return 0

def _install_supervisor_traps(run_dir: str, name: str) -> None:
    """A signalled supervisor must leave its cause where `watch-state` relays it: a refusal
    nobody may publish must not become a refusal nobody hears about either."""
    def _leave(word: str, code: int):
        def _handler(_signum, _frame):
            super_note(run_dir, name,
                       f"SUPERVISOR-KILLED: the sensing loop was {word} before it concluded "
                       "— no terminal conclusion published")
            try:
                sys.stdout.flush()
            except Exception:       # noqa: BLE001 — a closed stdout must not mask the exit
                pass
            os._exit(code)
        return _handler
    signal.signal(signal.SIGTERM, _leave("signalled", 143))
    signal.signal(signal.SIGINT, _leave("interrupted", 130))

def _stop_sample_path(run_dir: str, name: str) -> str:
    return os.path.join(run_dir, f".{name}.stop-sample.tmp")

_STOP_SAMPLE_NONE = "-"        # the handoff word for "there is nothing to sample"

def _write_stop_sample(sample: str, token: str, value: str) -> None:
    """Publish `<token> <value>` atomically: a reader never sees a half-written sample, and a
    failed publish leaves the previous stop's file — which the token then rejects."""
    tmp = f"{sample}.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(f"{token} {value}\n")
        os.replace(tmp, sample)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass          # part 2 reads no sample of ITS OWN and says so — cmd_stop_sentinel

def _read_stop_sample(sample: str, token: str) -> str | None:
    """The value THIS invocation's part 1 wrote, or None for anything else at all: absent,
    unreadable, truncated, or stamped by a stop that is not this one."""
    try:
        with open(sample, encoding="utf-8") as fh:
            line = fh.read().rstrip("\n")
    except OSError:
        return None
    stamped, sep, value = line.partition(" ")
    return value if sep and stamped == token else None

_STOP_KEPT = ("duplex.in", "duplex.meta", "duplex.round-started", "duplex.wlock",
              "duplex.prompt", "duplex.sent-offset", "duplex.write-intent",
              "duplex.watch.pid", "duplex.idle-marks")

def _control_state_paths(run_dir: str, name: str) -> list[str]:
    paths = [os.path.join(run_dir, f"{name}.{suffix}") for suffix in _STOP_KEPT]
    paths.append(os.path.join(run_dir, f"{name}.terminal.json"))
    # an unmatched shell glob passes its own WORD through: `rm -f` really was invoked with the
    # literal `.<session>.terminal.json-*.tmp` when nothing matched, and the executed argv is
    # part of teardown's observable behaviour, so the no-match case must argue it too
    pattern = os.path.join(run_dir, f".{name}.terminal.json-*.tmp")
    escaped = globmod.escape(os.path.join(run_dir, f".{name}.terminal.json-")) + "*.tmp"
    paths.extend(sorted(globmod.glob(escaped)) or [pattern])
    paths.append(os.path.join(run_dir, f"{name}.terminal.consumed.json"))
    return paths

def _identity_clear(run_dir: str, name: str) -> tuple[int, str]:
    """Cleanup is a MUTATION of identity state and is refused when the shared lock cannot be
    acquired, so its exit code is load-bearing: swallowing it would let a reclaimed session
    name inherit its predecessor's authority."""
    return _ctl(run_dir, "identity", "clear", name, merge_stderr=True)

def cmd_stop_cleanup(args: argparse.Namespace) -> int:
    """Duplex-lane teardown, between the tmux kill and the reap. Control state goes down
    BEFORE the reap: the terminal-marker guard (the meta re-check right before publish) prices
    in a µs kill→cleanup gap, and a grace-long reap in between would stretch it to seconds."""
    run, name = args.run_dir, args.session
    marker = os.path.join(run, f"{name}.terminal.json")
    marker_mtime = _stat_mtime(marker) if os.path.isfile(marker) else None
    _write_stop_sample(_stop_sample_path(run, name), args.token,
                       _STOP_SAMPLE_NONE if marker_mtime is None else str(marker_mtime))
    # ONE `rm -f` over the whole control-state set, through PATH: the executed process set is
    # part of teardown's observable behaviour (the same reason `cmd_supervisor_retire` keeps
    # `rm`), so a `rm` that refuses, audits or is missing still sees exactly this invocation.
    _rm_f(*_control_state_paths(run, name))
    # the attempt is over: its authority should die with the control state. A refused clear
    # must be SAID OUT LOUD — the session is down but its identity still holds authority, so a
    # same-name restart would be refused rather than silently inheriting it.
    id_rc, clear_out = _identity_clear(run, name)
    if id_rc != 0:
        print(f"WARN: identity state was NOT cleared for '{name}' — {clear_out}",
              file=sys.stderr)
    consume_tombstone(run, name)
    print(f"removed duplex control state; kept for post-mortem: "
          f"{run}/{name}.duplex.events.jsonl, .stderr.log, .rc, .sent-journal "
          "(replay-corpus sidecar)")
    return 1 if id_rc != 0 else 0

def cmd_stop_sentinel(args: argparse.Namespace) -> int:
    """False-DONE sentinel, part 2 — advisory, and it must never change stop's rc.

    With the tree fully reaped nothing can write the events file anymore, so THIS is the
    honest sampling point. Events growing >2s past the marker = the round was concluded while
    the engine still spoke (the silent-misfire class, made loud); +2s prices in the
    marker-write vs final-flush race."""
    run, name = args.run_dir, args.session
    sample = _stop_sample_path(run, name)
    handoff = _read_stop_sample(sample, args.token)
    try:
        os.unlink(sample)
    except OSError:
        pass
    # The pre-kill snapshot dies with the stop that took it. `survivor_advise` unlinks it on
    # the way past, so this only ever catches the one a KILLED stop left behind: nothing globs
    # it (leading dot, not `*.duplex.meta`), so it used to be permanent. Never any earlier than
    # this verb — the advisory that reads the snapshot runs between the reap and this call.
    try:
        os.unlink(os.path.join(run, f".{name}.stop-probe.json"))
    except OSError:
        pass
    events = os.path.join(run, f"{name}.duplex.events.jsonl")
    marker_mtime = None if handoff is None else _ascii_int(handoff)
    if handoff is None or not (handoff == _STOP_SAMPLE_NONE or marker_mtime is not None):
        print(f"SENTINEL: cannot sample the terminal marker of '{name}' — the stop-cleanup "
              f"handoff {sample} is missing, unreadable, or not the one THIS stop wrote, so "
              f"the false-DONE check did NOT run; inspect {events} by hand", file=sys.stderr)
        return 0
    if handoff == _STOP_SAMPLE_NONE:
        return 0
    if marker_mtime is None:  # unreachable (narrowed above); spelled out for the type checker
        return 0
    if not os.path.isfile(events):
        return 0
    events_mtime = _stat_mtime(events)
    if events_mtime is None:
        return 0
    if events_mtime > marker_mtime + 2:
        print(f"SENTINEL: events grew {events_mtime - marker_mtime}s past the terminal marker "
              "— possible false-DONE window or unknown continuation; keep "
              f"{events} and consider the replay corpus", file=sys.stderr)
    return 0

def cmd_stop_residue(args: argparse.Namespace) -> int:
    """The no-lane branch of stop: clean orphan duplex claims (crash residue like a stray
    fifo/write-intent) — this IS the recovery path the start error advertises — and return the
    exit code stop as a whole must report. `--reap-rc` is what the shell's own reap produced, so
    the combination stays exactly where it was before the split."""
    run, name = args.run_dir, args.session
    cleaned = args.killed == 1
    reap_rc = args.reap_rc
    # one PATH `rm -f` per residue file, exactly as the old loop ran it: the executed process
    # set is part of the observable teardown, not an implementation detail of the delete
    for suffix in ("duplex.in", "duplex.wlock", "duplex.prompt", "duplex.sent-offset",
                   "duplex.round-started", "duplex.write-intent", "duplex.watch.pid",
                   "terminal.json", "terminal.consumed.json"):
        path = os.path.join(run, f"{name}.{suffix}")
        if os.path.lexists(path):
            _rm_f(path)
            cleaned = True
    for debris in sorted(globmod.glob(globmod.escape(os.path.join(run, f".{name}.terminal.json-")) + "*.tmp")):
        _rm_f(debris)
        cleaned = True
    # a pre-kill snapshot whose stop never reached its advisory: same crash-residue class as
    # the stray fifo above, and the branch that recovers a session with no lane meta left
    snap = os.path.join(run, f".{name}.stop-probe.json")
    if os.path.isfile(snap):
        _rm_f(snap)
        cleaned = True
    # orphan identity must not outlive the residue it belonged to
    id_rc, clear_out = _identity_clear(run, name)
    if id_rc != 0:
        reap_rc = 1
        print(f"WARN: identity state was NOT cleared for '{name}' — {clear_out}",
              file=sys.stderr)
    if cleaned:
        print(f"removed orphan session residue for '{name}'")
        return reap_rc
    if (os.path.exists(os.path.join(run, f"{name}.duplex.events.jsonl"))
            or os.path.exists(os.path.join(run, f"{name}.duplex.rc"))):
        # idempotent re-stop: session already cleaned, only post-mortem artifacts remain
        print(f"already stopped: only post-mortem artifacts remain for '{name}'")
        return 0
    print(f"ERR: unknown session '{name}' (no lane state, no tmux session, no residue)",
          file=sys.stderr)
    return 1


ADVISORY_CMD_CLIP = 120     # advisory lines stay bounded; argv's head is the identifying part
ADVISORY_MAX_ROWS = 8


def cmd_stop_probe(args: argparse.Namespace) -> int:
    """Pre-kill half of the escaped-descendant advisory: record who is ALREADY outside the
    pane's process group. Evidence, not a target list — no signal is ever sent because of it."""
    rows, why = escaped_descendants(args.pane_pid)
    # "gone" is not "failed": nothing to look at is a different verdict from a probe that
    # looked and could not answer, and stop-survivors renders the two with distinct tokens.
    state = ("ok" if rows is not None
             else "gone" if why == PANE_GONE_WHY.format(pid=args.pane_pid) else "failed")
    payload = {"root": args.pane_pid, "probe": state, "why": why, "procs": rows or []}
    try:
        with open(args.snapshot, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    except OSError:
        pass        # a probe we cannot even record reports itself: stop-survivors finds no file
    return 0


def cmd_stop_survivors(args: argparse.Namespace) -> int:
    """Post-reap half. A survivor is a snapshot pid still alive under the SAME start time; a
    recycled pid is NOT one and triggers nothing. Advisory in the strict sense: it never
    changes stop's exit code, and a probe that cannot answer says [unknown] rather than
    nothing — a broken probe reading as 'clean' is the false verdict this exists to prevent."""
    def note(token: str, why: str) -> int:
        print(f"ADVISORY: stop {args.session}: escaped-descendant probe {token} ({why}) — "
              "survivors outside the pane's process group were NOT observable", file=sys.stderr)
        return 0

    def unknown(why: str) -> int:
        return note("[unknown]", why)
    try:
        with open(args.snapshot, encoding="utf-8") as fh:
            snap = json.load(fh)
    except (OSError, ValueError):
        return unknown("pre-kill snapshot missing or unreadable")
    if snap.get("probe") != "ok":
        # [n/a]: there was nothing to probe. [unknown] stays reserved for a probe that tried
        # and could not answer, so the token an operator must not read as clean keeps its edge.
        return note("[n/a]" if snap.get("probe") == "gone" else "[unknown]",
                    str(snap.get("why") or "pre-kill snapshot failed")[:ADVISORY_CMD_CLIP])
    before = {str(p["pid"]): p for p in snap.get("procs", ())}
    if not before:
        return 0
    # our own pid rides along as the known positive: "they are all gone" only means anything
    # from a list that provably contains a process we KNOW is running (cf. ps_start_times).
    me = str(os.getpid())
    live = ps_start_times([me, *before])
    if live is None or me not in live:
        return unknown("post-reap re-probe unusable")
    surv = [p for pid, p in sorted(before.items(), key=lambda kv: int(kv[0]))
            if " ".join(live.get(pid, "").split()) == p["lstart"]]
    if not surv:
        return 0
    shown = "; ".join(f"pid={p['pid']} age={p['etime']} cmd={p['cmd'][:ADVISORY_CMD_CLIP]}"
                      for p in surv[:ADVISORY_MAX_ROWS])
    more = f" [+{len(surv) - ADVISORY_MAX_ROWS} more]" if len(surv) > ADVISORY_MAX_ROWS else ""
    print(f"ADVISORY: stop {args.session}: {len(surv)} descendant(s) escaped the pane's process "
          f"group and survived the reap — NOT signalled (stop only ever signals the one pgid it "
          f"owns): {shown}{more} [boundary] only escapees still inside the pane's process tree "
          f"at snapshot time are enumerable; ones already reparented to PID 1 are invisible to "
          f"this probe and its silence does not cover them — `agentctl inventory --dry-run` "
          f"censuses that class", file=sys.stderr)
    return 0


# ── inventory ─────────────────────────────────────────────────────────────────
# Two censuses nothing else owns: control state that drifted from tmux reality, and engine
# processes PID 1 adopted (field 2026-08: 38 orphans, 12-19 days old, 2.2GiB, found by hand).
# Every row is a CANDIDATE — something to look at, never something this tool acts on. There is
# no --apply here or planned, and the verb refuses every spelling but `inventory --dry-run`.
ENGINE_WRAPPER_HOSTS = ("node", "bun", "python", "python3")


def engine_binaries() -> set[str]:
    """The allowlist's engine half, DERIVED from the one provider table — a second,
    hand-maintained engine list here IS the drift that rule exists to kill."""
    return {rec["bin"] for rec in PROVIDERS.values()}


def engine_match(cmd: str) -> str | None:
    """Which declared matcher claims this argv, or None. Allowlist by basename only."""
    try:
        argv = shlex.split(cmd)
    except ValueError:
        argv = cmd.split()
    if not argv:
        return None
    bins = engine_binaries()
    head = os.path.basename(argv[0])
    if head in bins:
        return f"direct:{head}"
    if head in ENGINE_WRAPPER_HOSTS:
        for tok in argv[1:]:
            if os.path.basename(tok) in bins:
                return f"wrapper:{head}->{os.path.basename(tok)}"
    return None


def inventory_control(run: str) -> tuple[list[str], str]:
    """(rows, why-unknown) for the control-state block. BOTH sources must succeed completely
    before this block is allowed to report emptiness: a half-probed census reading as "clean"
    is worse than one that says it does not know."""
    try:
        entries = os.listdir(run)
    except FileNotFoundError:
        entries = []                # a run dir that was never created IS zero records
    except OSError as exc:
        return [], f"run dir {run} unreadable ({exc.strerror})"
    records = {n[: -len(".duplex.meta")] for n in entries if n.endswith(".duplex.meta")}
    try:
        probe = subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"],
                               capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return [], f"tmux probe failed ({exc})"
    if probe.returncode == 0:
        live = {s.strip() for s in probe.stdout.splitlines() if s.strip()}
    elif "no server running" in probe.stderr:
        live = set()                # a server that was never started IS zero sessions
    else:
        return [], f"tmux list-sessions rc={probe.returncode}: {probe.stderr.strip()[:120]}"
    rows = [f"{'record-without-tmux':<19}  {n}" for n in sorted(records - live)]
    for name in sorted(live - records):
        # attribution is a SIGNAL, not a guess: the name owns files in the run dir, it is a
        # supervisor session, or its supervisor is up. Anything else is somebody else's shell
        # and gets listed as unattributed rather than counted as an agentctl leak.
        attributed = (any(e.startswith(f"{name}.") for e in entries)
                      or name.endswith("-watchd") or f"{name}-watchd" in live)
        label = "tmux-without-record" if attributed else "unattributed"
        rows.append(f"{label:<19}  {name}")
    return rows, ""


def inventory_orphans() -> tuple[list[str], str]:
    """(rows, why-unknown) for the PPID=1 engine census, from one ps snapshot."""
    rows = ps_identity_rows()
    if rows is None:
        return [], "ps snapshot failed or unparseable"
    out = []
    for row in rows:
        if row["ppid"] != 1:
            continue
        label = engine_match(row["cmd"])
        if label is None:
            continue
        out.append(f"{'orphan-candidate':<19}  pid={row['pid']} age={row['etime']} "
                   f"matcher={label} cmd={row['cmd'][:ADVISORY_CMD_CLIP]}")
    return out, ""


def cmd_inventory(args: argparse.Namespace) -> int:
    """Read-only candidate overview. Nothing here signals anything, ever."""
    bins = "|".join(sorted(engine_binaries()))
    print("== agentctl inventory --dry-run — CANDIDATES only; nothing is signalled ==")
    print(f"[matchers] direct: basename(argv[0]) in {{{bins}}} (from the provider table) · "
          f"wrapper: {{{'|'.join(ENGINE_WRAPPER_HOSTS)}}} carrying one of those basenames")
    print("[boundary] FP: any PPID=1 process merely WEARING an engine name (ChatGPT.app, a "
          "login-launched interactive CLI) lands here — rows are candidates, not processes "
          "this tool claims to own. FN: AGENTCTL_BIN_* overrides, renamed binaries and "
          "undeclared wrappers are invisible to this list. FP (control block): a `-watchd`-"
          "suffixed tmux name is attributed by naming convention alone, with no run-dir "
          "cross-check, so it may over-report as tmux-without-record.")
    for title, (rows, why) in (("control-state reconciliation", inventory_control(args.run_dir)),
                               ("engine-orphan census (PPID=1)", inventory_orphans())):
        print(f"-- {title} --")
        if why:
            print(f"[unknown] {title}: {why} — this block is NOT a clean bill")
        elif not rows:
            print("(none)")
        else:
            print("\n".join(rows))
    return 0


def _knob(var: str, fallback: str) -> str:
    """`${VAR:-fallback}`, verbatim: the shell used to expand these three watch knobs and pass
    them down, so the same empty-or-unset rule and the same failure on a non-numeric value
    (argparse applies `type` to a string default) still apply — there is just one copy of the
    defaults now instead of one here and one in the entry script."""
    return os.environ.get(var) or fallback


class _StrictParser(argparse.ArgumentParser):
    """One accepted spelling per flag, at EVERY level of this entry.

    `allow_abbrev=False` on the top-level parser is not inherited: argparse builds each
    subparser from `parser_class` with its own defaults, so `inventory --dry` was still
    accepted after the obvious one-line fix. Carrying the setting on the class — which
    `add_subparsers` reuses by default — is what makes the promise hold for the subcommands,
    where every flag this tool actually takes lives."""

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)


def main() -> None:
    # Line-buffered on purpose: the long-running verbs (`watch-wait`, `sense-loop`) run with
    # stdout redirected to a log a live operator tails, and the shell `echo`s they replaced
    # were never block-buffered. Cheap for the one-shot verbs, correctness for the loops.
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        try:
            reconfigure(line_buffering=True)
        except ValueError:                      # stdout already detached / closed fd
            pass
    parser = _StrictParser(prog="duplexctl")
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
                                     "publish", "receipt", "watermark", "clear"])
    p_id.add_argument("session")
    p_id.add_argument("--armed", default="", help="arm-time identity token (publish)")
    p_id.add_argument("--rc", type=int, default=0)
    p_id.add_argument("--round", default=None,
                      help="round the conclusion was computed for: the round fence. REQUIRED "
                           "for publish — an unfenced publish is refused, never defaulted")
    p_id.add_argument("--detail", default="",
                      help="human line the concluding observer printed (diagnostics only)")
    p_id.set_defaults(func=cmd_identity)

    p_ws = sub.add_parser("watch-state", help="the supervised waiter's ONE read: fenced terminal "
                                              "record, else supervisor liveness")
    p_ws.add_argument("session")
    p_ws.add_argument("--arm", action="store_true",
                      help="arm-time read (before a supervisor is established)")
    p_ws.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq",
                      help="the delivery watermark this waiter captured when it armed "
                           "(`identity watermark`): a conclusion already delivered to a peer "
                           "still counts for a waiter attached when it was published. Absent "
                           "(-1) = a one-shot reader, which was attached to nothing")
    p_ws.add_argument("--lease-unchanged", type=int, default=0, dest="lease_unchanged",
                      help="consecutive polls of THIS waiter that saw an unmoved supervisor "
                           "lease — the reader's own clock, and the only admissible evidence "
                           "of a wedge (n polls bound n-1 elapsed intervals)")
    p_ws.add_argument("--poll", type=float, default=0.0,
                      help="this waiter's poll interval, seconds (pairs with "
                           "--lease-unchanged; without both, the read is one-shot and derives "
                           "no staleness from the lease at all)")
    p_ws.set_defaults(func=cmd_watch_state)

    p_wl = sub.add_parser("watch-lease", help="renew the supervisor liveness lease (supervisor "
                                              "internal; also its identity-rotation check)")
    p_wl.add_argument("session")
    p_wl.add_argument("--armed", default="", help="arm-time identity token of the supervisor")
    p_wl.add_argument("--pid", default="", help="supervisor pid (defaults to this process)")
    p_wl.add_argument("--poll", type=float, default=0.0, help="supervisor poll interval, seconds")
    p_wl.add_argument("--max-polls", type=int, default=0, dest="max_polls")
    p_wl.add_argument("--iter", type=int, default=0, help="current poll iteration")
    p_wl.set_defaults(func=cmd_watch_lease)

    p_cap = sub.add_parser("capabilities", help="runtime-generated provider capability contract")
    p_cap.add_argument("--json", action="store_true", help="stable machine shape")
    p_cap.set_defaults(func=cmd_capabilities)

    p_states = sub.add_parser("states", help="runtime-generated typed state vocabulary")
    p_states.add_argument("--json", action="store_true", help="stable machine shape")
    p_states.set_defaults(func=cmd_states)

    p_prov = sub.add_parser("providers", help="the provider adapter spec agentctl launches from")
    p_prov.add_argument("--shell", action="store_true",
                        help="name|bin_env|default_bin|argv|extra_argv|resume_flag rows")
    p_prov.set_defaults(func=cmd_providers)


    # ── orchestration verbs: the judgements the bash entry used to make ──────────────
    # `agentctl` calls these; they are not an operator surface. Each one is one step of a
    # verb whose remaining steps are tmux or process-group work the shell still owns.
    p_status = sub.add_parser("status", help="one-shot typed state + fenced publish + the "
                                             "no-watcher advisories (agentctl status)")
    p_status.add_argument("session")
    p_status.set_defaults(func=cmd_status)

    p_arm = sub.add_parser("watch-arm", help="publish the waiter pid, consume any tombstone, "
                                             "announce the arm")
    p_arm.add_argument("session")
    p_arm.add_argument("--pid", type=int, required=True, help="the waiter process pid")
    p_arm.set_defaults(func=cmd_watch_arm)

    p_armread = sub.add_parser("watch-arm-read", help="arm-time read of the fenced record; "
                                                      "exit 13 = nothing to adopt, go arm")
    p_armread.add_argument("session")
    p_armread.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    p_armread.set_defaults(func=cmd_watch_arm_read)

    p_tomb = sub.add_parser("watch-tombstone", help="record an externally killed waiter")
    p_tomb.add_argument("session")
    p_tomb.add_argument("--signal", required=True)
    p_tomb.add_argument("--ppid", default="0")
    p_tomb.add_argument("--uptime", default="0")
    p_tomb.set_defaults(func=cmd_watch_tombstone)

    p_check = sub.add_parser("watch-arm-check", help="may/must a supervisor be established? "
                                                     "0 sensing / 1 structural / 3 spawn / "
                                                     "4 retire-then-spawn")
    p_check.add_argument("session")
    p_check.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    p_check.set_defaults(func=cmd_watch_arm_check)

    p_armwait = sub.add_parser("watch-arm-wait", help="block until the supervisor leases; "
                                                      "0 leased / 2 rogue / 4 ours, leaseless")
    p_armwait.add_argument("session")
    p_armwait.add_argument("--mine", type=int, default=0,
                           help="1 when this waiter won the singleton tmux name")
    p_armwait.set_defaults(func=cmd_watch_arm_wait)

    p_wait = sub.add_parser("watch-wait", help="the dumb waiter loop over the fenced record")
    p_wait.add_argument("session")
    p_wait.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    p_wait.add_argument("--poll", type=float, default=_knob("AGENT_WATCH_POLL_SECS", "15"))
    p_wait.add_argument("--max-polls", type=int, dest="max_polls",
                        default=_knob("AGENT_WATCH_MAX_POLLS", "240"))
    p_wait.set_defaults(func=cmd_watch_wait)

    p_sense = sub.add_parser("sense-loop", help="THE sensing loop (supervisor pane, or the "
                                                "--inline fallback)")
    p_sense.add_argument("session")
    p_sense.add_argument("--mode", choices=["daemon", "inline"], required=True)
    p_sense.add_argument("--armed", default="", help="arm-time identity token")
    p_sense.add_argument("--poll", type=float, default=_knob("AGENT_WATCH_POLL_SECS", "15"))
    p_sense.add_argument("--max-polls", type=int, dest="max_polls",
                         default=_knob("AGENT_WATCH_MAX_POLLS", "240"))
    p_sense.add_argument("--silent-polls", type=int, dest="silent_polls",
                         default=_knob("AGENT_WATCH_SILENT_POLLS", "8"))
    p_sense.set_defaults(func=cmd_sense_loop)

    p_ret = sub.add_parser("supervisor-retire", help="last words, then the lease (in that "
                                                     "order); the tmux kill is the shell's")
    p_ret.add_argument("session")
    p_ret.add_argument("--why", default="", help="cause to leave for an attached waiter")
    p_ret.set_defaults(func=cmd_supervisor_retire)

    p_clean = sub.add_parser("stop-cleanup", help="duplex-lane teardown between the tmux kill "
                                                  "and the reap")
    p_clean.add_argument("session")
    # opaque, never interpreted: it only has to be the SAME string the matching stop-sentinel
    # gets and a different one from any other stop invocation's
    p_clean.add_argument("--token", default="",
                         help="per-invocation nonce stamped on the sentinel handoff sample")
    p_clean.set_defaults(func=cmd_stop_cleanup)

    p_sent = sub.add_parser("stop-sentinel", help="false-DONE sentinel, sampled after the reap")
    p_sent.add_argument("session")
    p_sent.add_argument("--token", default="",
                        help="the nonce stop-cleanup was given; a sample stamped with anything "
                             "else is a failed handoff, not a reading")
    p_sent.set_defaults(func=cmd_stop_sentinel)

    p_res = sub.add_parser("stop-residue", help="the no-lane branch of stop")
    p_res.add_argument("session")
    p_res.add_argument("--killed", type=int, default=0,
                       help="1 when the shell already killed a bare tmux session")
    p_res.add_argument("--reap-rc", type=int, default=0, dest="reap_rc",
                       help="exit code the shell's own reap produced")
    p_res.set_defaults(func=cmd_stop_residue)

    p_probe = sub.add_parser("stop-probe", help="pre-kill snapshot of descendants ALREADY "
                                                "outside the pane's process group")
    p_probe.add_argument("session")
    p_probe.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
    p_probe.add_argument("--snapshot", required=True, help="where the pre-kill evidence lands")
    p_probe.set_defaults(func=cmd_stop_probe)

    p_surv = sub.add_parser("stop-survivors", help="post-reap re-probe; stderr advisory only — "
                                                   "never a signal, never stop's rc")
    p_surv.add_argument("session")
    p_surv.add_argument("--snapshot", required=True)
    p_surv.set_defaults(func=cmd_stop_survivors)

    # --dry-run is REQUIRED, not defaulted: the read-only promise has to be spelled out by the
    # caller, so no future flag can quietly turn this verb into one that acts.
    p_inv = sub.add_parser("inventory", help="read-only candidate overview: control-state drift "
                                             "+ PPID=1 engine orphans")
    p_inv.add_argument("--dry-run", action="store_true", required=True, dest="dry_run",
                       help="the ONLY accepted spelling; this verb never acts")
    p_inv.set_defaults(func=cmd_inventory)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
