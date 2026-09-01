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
Java-interface style — instead of silently degrading). ONE steering verb, and it means
DELIVER AS SOON AS THE ENGINE ALLOWS: the LIVE TURN STATE picks the route, never a flag
(field 2026-08-28: with a queue-vs-now-vs-replace triple the operator queued behind a
35-60min turn and the engine then executed a ruling the batch had already overtaken).
  omp    : --mode=rpc JSON-lines. steer = `steer` frame mid-turn / `follow_up` when idle;
           interrupt = abort_and_prompt; prompt delivers the goal, get_state reads status.
  claude : -p --input-format stream-json. ONE `user` frame: it opens the next turn at once
           when idle, and lands at the turn BOUNDARY while a turn runs — degraded, and said
           out loud; interrupt refused (stop+resume).
  codex  : app-server JSON-RPC (spike-verified 2026-07-19 on 0.144.5, v1 param shapes).
           steer = turn/steer{expectedTurnId} mid-turn / turn/start when idle;
           interrupt = turn/interrupt + turn/start. threadId persisted in meta.
"""
from __future__ import annotations

import argparse
import fcntl
import fnmatch
import glob as globmod
import hashlib
import json
import os
import re
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

# ALSO reachable under its own import name while this file is the argv front door: watchctl does
# `from duplexctl import …` at its module scope, and without this alias `python3 duplexctl.py
# <verb>` would execute this whole file a SECOND time as module "duplexctl" — two copies of every
# constant and of `_INFLIGHT`. `.get`: a spec_from_file_location load (the sanctioned white-box
# tests) never registers the module at all, and no such copy calls main().
_SELF = sys.modules.get(__name__)
if _SELF is not None:
    sys.modules.setdefault("duplexctl", _SELF)

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
# 13 is the waiter-internal arm handshake (plumbing, see above), so the next typed code is 14
EXIT_STALLED_PROGRESS = 14
EXIT_DELIVERED_NEXT_TURN = 15

# BUMPED 1 -> 2 by the progress-source batch: the document gained a SECOND published
# vocabulary (`subReasons`). A consumer that read `{schemaVersion, states}` as the whole
# contract would silently miss the dimension that now qualifies three of those states, so it
# must be able to REFUSE this document instead of concluding "this state has no sub-reason".
TYPED_STATE_SCHEMA_VERSION = 2
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
    (EXIT_STALLED_PROGRESS, "STALLED-PROGRESS",
     "the engine keeps streaming, but at no sampling point of a whole window was any progress "
     "source observed to have moved: the repo trace (HEAD, the dirty-tree hash and its file "
     "mtimes, the deliverable's mtime, BLOCKED.md), the engine's own tool/command frames, and "
     "the process set in the pane's group — see the reason= word for which of them were judged"),
    (EXIT_DELIVERED_NEXT_TURN, "DELIVERED-NEXT-TURN",
     "a steer was DELIVERED, but by the next-turn route while a turn was running — so it "
     "lands at the turn boundary, not inside that turn: the engine declares no mid-turn "
     "route (reason=capability), or the live turn state could not be judged "
     "(reason=undecidable)"),
)


# ── typed sub-reason vocabulary ───────────────────────────────────────────────
# The SECOND dimension of the same contract. A typed state says WHAT the runtime observed; a
# sub-reason says WHICH observation inside that state — and that word is what an orchestrator
# branches its disposition on. Every one of them used to be a bare literal at its print site
# (`reason=capability`, `progress=unchanged`), so the set existed only in prose and no consumer
# could enumerate it. Same rule as TYPED_STATES: ONE table, generated into `agentctl states`,
# and no word may leave this module without a row here (`sub_reason()` is the only gate).
#
# Grouped by the FIRST-LEVEL exit whose line carries the word. A row is NOT a promise that the
# exit fires: `repo-silent+tools-active` is exactly the observation under which 14 is WITHHELD,
# and the RUNNING line carries the word instead.
#
# Not in here: the SUPERVISOR-LOST reason words (`dead`/`unknown`). They are the four-state
# waiter handshake's own vocabulary, published in that state's own `meaning` sentence, and
# folding them in would make this table the second definition of a machine nobody asked to
# reshape.
SUB_REASON_TOOLS_ACTIVE = "repo-silent+tools-active"
SUB_REASON_TOOLS_SILENT = "repo-silent+tools-silent"
SUB_REASON_UNKNOWN_SOURCE = "unknown-source"
SUB_REASON_CAPABILITY = "capability"
SUB_REASON_UNDECIDABLE = "undecidable"
SUB_REASON_CHANGED = "changed"
SUB_REASON_UNCHANGED = "unchanged"
SUB_REASON_UNKNOWN = "unknown"

SUB_REASONS: tuple[tuple[int, str, str], ...] = (
    (EXIT_STALLED_PROGRESS, SUB_REASON_TOOLS_ACTIVE,
     "no repo-trace sample changed while an engine-activity source did move — new tool/command "
     "frames, or a changed process set in the pane's group: the verdict is WITHHELD, the "
     "progress clock is refreshed from that source, and the RUNNING line carries this word"),
    (EXIT_STALLED_PROGRESS, SUB_REASON_TOOLS_SILENT,
     "no judged progress source was observed to move at any sampling point of the window, and "
     "there was nothing left unjudged: the repo trace, the engine's own tool/command frames "
     "and the process set in the pane's group — a source that moved and returned between two "
     "samples is not visible to these instruments"),
    (EXIT_STALLED_PROGRESS, SUB_REASON_UNKNOWN_SOURCE,
     "the judged sources were not observed to move at any sampling point while at least one "
     "source could not be judged at all — nothing proves work, and nothing proves stillness"),
    (EXIT_DELIVERED_NEXT_TURN, SUB_REASON_CAPABILITY,
     "the engine declares no mid-turn steer route, so the frame lands at the turn boundary"),
    (EXIT_DELIVERED_NEXT_TURN, SUB_REASON_UNDECIDABLE,
     "the live turn state could not be judged, so the always-landing next-turn route was taken"),
    (EXIT_WATCH_TIMEOUT, SUB_REASON_CHANGED,
     "the poll budget ran out on a session whose progress sources were observed to move"),
    (EXIT_WATCH_TIMEOUT, SUB_REASON_UNCHANGED,
     "the poll budget ran out and no judged movement was observed after the first sensing read"),
    (EXIT_WATCH_TIMEOUT, SUB_REASON_UNKNOWN,
     "the poll budget ran out and the progress gauge never measured a judgeable movement — "
     "disabled, never persisted, or the union stayed below its judged quorum"),
)


def _sub_reason_index() -> dict[tuple[int, str], str]:
    """(code, word) → meaning, built ONCE at import so a drifted table cannot serve even one
    verb. Two integrity rules: a sub-reason may only qualify a PUBLISHED typed state, and every
    SUB_REASON_* constant must appear in the table (a constant nothing publishes is a bare
    literal wearing a name). SystemExit, not die(): die() is defined further down the file and
    this runs at import — the message and the rc are identical."""
    codes = {code for code, _name, _meaning in TYPED_STATES}
    words = {word for _code, word, _meaning in SUB_REASONS}
    index: dict[tuple[int, str], str] = {}
    for code, word, meaning in SUB_REASONS:
        if code not in codes:
            raise SystemExit(f"ERR: sub-reason '{word}' qualifies exit {code}, which "
                             "TYPED_STATES does not publish — the closed set is broken")
        index[(code, word)] = meaning
    orphans = sorted(name for name, value in list(globals().items())
                     if name.startswith("SUB_REASON_") and isinstance(value, str)
                     and value not in words)
    if orphans:
        raise SystemExit("ERR: SUB_REASON constant(s) absent from the SUB_REASONS table: "
                         + ", ".join(orphans))
    return index


SUB_REASON_INDEX = _sub_reason_index()


def sub_reason(code: int, word: str) -> str:
    """The published sub-reason word, or a typed death. EVERY emission goes through here, so a
    word outside the closed set cannot reach an operator or a machine consumer at all."""
    if (code, word) not in SUB_REASON_INDEX:
        die(f"sub-reason '{word}' is not published for exit {code} — refusing to emit a "
            "verdict word no consumer can enumerate")
    return word


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
        # steer/progress sidecars: the delivery record that makes `queued=N` readable, and
        # the work-trace fingerprint STALLED-PROGRESS accumulates over. Both are lane control
        # state (stop removes them); neither is ever read as terminal truth.
        self.steer_log = os.path.join(run_dir, f"{name}.steer-log.jsonl")
        self.progress = os.path.join(run_dir, f"{name}.duplex.progress")
        # live queue depth, set by the projector that can actually ask the engine (omp).
        # 0 = no queue / not asked: engines without a queue print no listing at all.
        self.queued = 0
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
    # BACKSTOP for the line-format injection class (review R2 F3): `check-params` refuses at the
    # parameter surface, where a refusal is cheap and the operator gets a real message, but that
    # only covers values the SHELL parsed. This is the single write point every other value goes
    # through too — `thread` comes back from the engine, `deliverable` from `steer -d` — so the
    # invariant is enforced where the file is actually written and no future key can miss it.
    if "\n" in value or "\r" in value:
        die(f"refusing to write meta {key}: value contains a newline, which would inject "
            f"additional meta keys into {sess.meta_path}")
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
#     provider list `agentctl` has: allowlist, binary, pinned argv, argv forwarding, the
#     resume start flag and the review sandbox tier all come from it) are derived, never
#     hand-maintained;
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
# BUMPED 1 -> 2 by the ASAP steer batch: the capability KEYS changed shape (the three verbs
# `queuedSteer`/`midTurnSteer`/`replaceTurn` became `steer`/`interruptTurn`), which is not a
# compatible addition. A machine consumer pinned to v1 must be able to REFUSE this document
# instead of reading the new keys as missing fields (cold review R1).
CAPABILITY_SCHEMA_VERSION = 2

# the closed capability vocabulary, in output order
CAPABILITY_ORDER = ("steer", "interruptTurn", "structuredAsk",
                    "structuredReply", "resume", "permissionEnforcement")

# WHAT EACH CAPABILITY MEANS. Written down because a criterion applied unevenly is the same
# defect as a wrong cell: cold review R1 caught `resume` being judged "has a dedicated duplex
# verb" for omp/claude but "the documented public invocation works" for codex. Every cell is
# judged against the sentence here — the OPERATION the operator can invoke through
# `agentctl`, not the protocol niceness of how the lane serves it.
CAPABILITY_DEFINITIONS = {
    "steer": "deliver a message to a live session AS SOON AS the engine allows it — inside "
             "the running turn where the engine has a mid-turn route, as the next turn when "
             "the session is idle. ONE operation: the live turn state picks the route",
    "interruptTurn": "abandon the running turn and start a replacement in the same session",
    "structuredAsk": "the engine's own question reaches the operator as a typed "
                     "WAITING-INPUT projection, not as prose to be read out of a log",
    "structuredReply": "answer such a question through a dedicated agentctl verb",
    "resume": "continue a prior conversation's context in a new round through a documented "
              "`agentctl` invocation (in-session route, or stop + start with resume args)",
    "permissionEnforcement": "the runtime constrains what the engine may do and enforces it",
}

# A steer cell's route is an ALTERNATION — "<mid-turn>|<next-turn>" — and the branch emits
# EXACTLY ONE half, whichever the live turn state selects (steer_delivery below). A single
# name means the engine has only that one frame, which is also WHY such a cell is DEGRADED:
# while a turn runs, that frame cannot land inside it. (`+` is the other composite: a
# SEQUENCE whose halves are BOTH sent, used by codex's interrupt handshake.)
STEER_ROUTE_SEP = "|"

# the send verbs that ARE capability claims. `prompt` (goal delivery) and `get-state`
# (omp's liveness probe) are lane plumbing: without them the lane cannot exist at all,
# so they are not provider capabilities and carry no state.
VERB_CAPABILITY = {"steer": "steer", "interrupt": "interruptTurn"}

# Non-protocol realizations. A capability served by one of these has no wire route, so the
# drift gate cannot check it against ROUTES — the behaviour battery must. Closed set:
# `start-argv` = `agentctl start` forwards unrecognized args verbatim to the engine, which
# is how omp/claude native resume is invoked.
SURFACE_START_ARGV = "start-argv"
CAPABILITY_SURFACES = (SURFACE_START_ARGV,)


def _cap(state: str, route: str = "", note: str = "", refusal: str = "",
         surface: str = "", detect: dict | None = None, queue_routes: tuple[str, ...] = (),
         start_flag: str = "", impl=None) -> dict:
    """One capability cell.

    state    — closed enum; never a boolean, because behaviour here is provider-specific.
    route    — the wire name (frame type / JSON-RPC method) the branch emits, "" if none.
               May be composite: `a|b` = alternation (one half goes out, state-selected),
               `a+b` = sequence (both go out, in order). See STEER_ROUTE_SEP.
    impl     — the branch that performs `route`; ROUTES is built from these pairs.
    surface  — a non-protocol realization (see CAPABILITY_SURFACES) when there is no route.
    note     — published EXACTLY for degraded (names the degradation) and unsupported
               (names the recommended supported path). A supported cell publishes no note:
               the state is the whole claim. A refusal doubles as the note, so the rejected
               operator and the contract reader see one sentence. A degraded steer prints
               this note VERBATIM at the moment it degrades — one sentence, two surfaces.
    refusal  — what a refused verb prints.
    detect   — projector-side recognition data (ask frame noise / ask method names), read
               BACK by the projector so the contract owns it too.
    queue_routes — the subset of `route`'s halves whose delivery really enters an engine-held
               QUEUE. Read back by the steer-log listing, which a queue DEPTH indexes: a
               mid-turn frame and a turn-opening frame both leave the lane without queueing
               anything, so neither may be listed as a queued item.
    start_flag — the `agentctl start` flag that drives this capability, if any.
    """
    published = note or refusal
    if state == SUPPORTED or state == EXPERIMENTAL:
        published = ""      # notes exist exactly where the state is not self-explanatory
    return {"state": state, "note": published, "refusal": refusal, "route": route,
            "surface": surface, "detect": detect or {}, "queue_routes": tuple(queue_routes),
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
    """The route id a capability verb resolves to — "" when the provider does not have it.
    For a steer this is the whole ALTERNATION: WHICH half reaches the wire is a function of
    the live turn state, and only steer_delivery() may answer that."""
    name = VERB_CAPABILITY.get(verb)
    return capability(engine, name)["route"] if name else ""


def steer_halves(cell: dict) -> tuple[str, str]:
    """(mid-turn route, next-turn route) of a steer cell. One name = the engine has a single
    frame, so both halves are that frame."""
    mid, sep, nxt = cell["route"].partition(STEER_ROUTE_SEP)
    return mid, (nxt if sep else mid)


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


def codex_frames(sess: Session) -> tuple[list[dict] | None, str]:
    """(every COMPLETE frame on the lane, "") or (None, why) when the events stream ITSELF
    could not be read. A stream that is unreadable, corrupt, or holds no complete frame yet is
    a BROKEN GAUGE, not an idle engine: folding it into an empty frame list picked the same
    safe route but published a state nobody measured, so a gauge failure was indistinguishable
    from a known-idle session (cold review R1). The caller must say undecidable out loud."""
    try:
        with open(sess.events, "rb") as fh:
            blob = fh.read()
    except OSError:
        return None, f"codex events stream unreadable ({sess.events})"
    body, nl, _tail = blob.rpartition(b"\n")
    if not nl:
        return None, (f"codex events stream holds no complete frame yet "
                      f"({len(blob)}B unterminated)")
    lines = [ln.strip() for ln in body.decode("utf-8", errors="replace").splitlines()
             if ln.strip()]
    frames, corrupt = [], 0
    for line in lines:
        try:
            frames.append(json.loads(line))
        except json.JSONDecodeError:
            corrupt += 1
    if corrupt or not frames:
        return None, (f"codex events stream unparseable ({corrupt} corrupt of "
                      f"{len(lines)} complete line(s))")
    return frames, ""


def codex_turn_from(frames: list[dict], ours: str | None):
    """Latest turn/started without a later matching turn/completed, ON OUR THREAD
    only — the engine multiplexes sub-threads (its own sub-agents) onto the same
    app-server stream, and an unfiltered read let a sub-thread's turn/completed
    masquerade as our turn boundary (caught live by the first dogfood review
    session, 2026-07-19)."""
    active = None
    for frame in frames:
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


def codex_active_turn(sess: Session) -> tuple[str | None, str]:
    """(active turn id or None, "") — or (None, why) when the events stream ITSELF could not
    be read. The diagnosis rides along because "no turn" and "no measurement" license
    different frames: folding them together let a replacement rotate the attempt on a session
    whose turn was still running (verify R2)."""
    frames, why = codex_frames(sess)
    if frames is None:
        return None, why
    return codex_turn_from(frames, sess.meta.get("thread")), ""



def build_frame(engine: str, verb: str, text: str, req_id: str, route: str = "") -> str:
    """The wire frame for one verb. A CAPABILITY verb's frame type IS `route`, which the
    caller resolves through the one capability table (a steer resolves it from the live turn
    state), so a frame type cannot exist without a declared capability; `prompt` /
    `get-state` are lane plumbing and stay literal."""
    if engine == "omp":
        omp_type = {"prompt": "prompt", "get-state": "get_state"}.get(verb) or route
        if not omp_type:
            die(f"unsupported omp verb: {verb}")
        frame = {"id": req_id, "type": omp_type}
        if omp_type != "get_state":
            frame["message"] = text
        return json.dumps(frame, ensure_ascii=False)
    if engine == "claude":
        claude_type = "user" if verb == "prompt" else route
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


# ── misplaced-deliverable scan ────────────────────────────────────────────────
# Field incident 2026-08-18 (external seat): worker and reviewer wrote their file into
# the session cwd ROOT under the declared BASENAME while the declaration named a path one
# directory deeper. The gate read IDLE-NO-DELIVERABLE, the orchestrator read "no
# output", stopped the seat and re-dispatched — a review carrying a BLOCKER was never
# consumed and the branch merged hurt. The bytes were on disk the whole time.
#
# OBSERVABILITY ONLY: these lines print AFTER the verdict line and touch no exit code,
# no state, no receipt. Bounds are hard constants, not tunables — a watcher poll must
# stay cheap and predictable on a large worktree:
#   * depth: the cwd itself plus at most SCAN_MAX_DEPTH levels of subdirectory
#   * entries: SCAN_MAX_ENTRIES dirents CONSUMED overall, counted as each comes off an
#     os.scandir iterator. os.walk is unusable here: it materializes a whole directory
#     before any cap can apply, so one 200k-entry dir would be enumerated in full.
#   * symlinks are never followed and never candidates (no link-vs-target mtime
#     ambiguity to adjudicate); dotted names are skipped — a misplaced deliverable is
#     not a hidden file, and .git alone would eat the whole budget.
# TWO FAILURE LAYERS, deliberately different (impl review R1 B2 fixed the contract, not the
# code): a PER-DIRECTORY OSError is EXPECTED filesystem noise (unreadable dir, dir raced
# away) — that subtree is skipped and candidates already found elsewhere still speak, because
# the incident shape sits in the cwd ROOT and must not be lost to one unreadable directory
# three levels down. Anything else — an unexpected error anywhere in the scan — hits the
# blanket fail-safe arm in misplaced_hint() and the whole scan goes silent: state safety
# outranks scanner health, so that degradation is indistinguishable from a clean cwd. The
# paired tests (known positive + injected fault on the same fixture) are the only
# calibration that exists for the silent arm.
SCAN_MAX_DEPTH = 3
SCAN_MAX_ENTRIES = 2000
SCAN_SHOW = 3


def _misplaced_candidates(sess: Session) -> tuple[list[str], bool]:
    """(absolute paths that carry the declared deliverable's NAME in a place the
    declaration does not name, whether the entry cap stopped the scan early).

    Pattern resolution is deliverable_fresh's, deliberately: relative globs against the
    session cwd, absolute kept. A path the declared glob itself matches is never
    misplaced — that set is the gate's own business, and this scan excludes it."""
    pattern = sess.meta.get("deliverable", "")
    if not pattern:
        return [], False
    cwd = sess.meta.get("cwd", ".")
    if not os.path.isabs(pattern):
        pattern = os.path.join(cwd, pattern)
    want = os.path.basename(pattern)
    if not want:
        return [], False
    try:
        epoch_mtime = os.path.getmtime(sess.epoch)
    except OSError:
        epoch_mtime = 0.0
    declared = {os.path.abspath(p) for p in globmod.glob(pattern)}
    hits: list[str] = []
    budget = SCAN_MAX_ENTRIES
    capped = False
    stack = [(os.path.abspath(cwd), 0)]
    while stack and not capped:
        base, depth = stack.pop()
        batch = []
        try:
            with os.scandir(base) as it:
                # budget is checked BEFORE each next(): a check-after-consume let the 2001st
                # dirent be pulled to discover the cap was full (R1 B3). "Consumed" means
                # exactly the entries this loop pulled, and it never exceeds the constant.
                while True:
                    if budget <= 0:
                        capped = True
                        break
                    try:
                        entry = next(it)
                    except StopIteration:
                        break
                    budget -= 1
                    batch.append(entry)
        except OSError:
            pass            # bounded-degradation arm: skip this subtree, keep what is paid for
        # sorted WITHIN the consumed batch: traversal order is stable whenever the cap
        # did not fire. Once it fires the os-order truncation is arbitrary, which is
        # exactly what the "; scan capped" wording refuses to hide.
        for entry in sorted(batch, key=lambda e: e.name):
            if entry.name.startswith("."):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if depth + 1 <= SCAN_MAX_DEPTH:
                        stack.append((entry.path, depth + 1))
                    continue
                if not entry.is_file(follow_symlinks=False):
                    continue
                if not fnmatch.fnmatch(entry.name, want):
                    continue
                path = os.path.abspath(entry.path)
                # belt and suspenders: in the exit-6 context every member of `declared` is
                # necessarily STALE (a fresh one would have made the verdict DONE), so the
                # epoch fence below already covers this. This arm holds when the fence cannot
                # — a missing/unreadable epoch file reads as mtime 0.0 and accepts everything.
                if path in declared:
                    continue
                if entry.stat(follow_symlinks=False).st_mtime < epoch_mtime:
                    continue
            except OSError:
                continue
            hits.append(path)
    return hits, capped


def misplaced_hint(sess: Session) -> None:
    """Advisory lines under an IDLE-NO-DELIVERABLE verdict.

    The path leaves json.dumps-ENCODED: a filename holding a newline (or the text
    "DONE:") must not be able to forge a second typed line in a stdout an orchestrator
    parses. ANY failure returns silently — the verdict printed above this call must
    never depend on a scanner."""
    try:
        hits, capped = _misplaced_candidates(sess)
        for path in hits[:SCAN_SHOW]:
            print(f"possible misplaced deliverable: {json.dumps(path)}")
        extra = len(hits) - SCAN_SHOW
        if extra > 0:
            print(f"(+{extra} more among scanned entries"
                  f"{'; scan capped' if capped else ''})")
    except Exception:   # noqa: BLE001 — a broken scan must read exactly like a clean cwd
        return


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
def json_bool(data: dict, key: str) -> bool | None:
    """A protocol boolean, or None when the gauge did not answer with one. Python truthiness
    is the WRONG reader here and the failure is asymmetric in both directions: the JSON string
    `"false"` is truthy (a dead turn read as live) and the integer `0` is falsy (a live turn
    read as dead). Only `true` and `false` decide; a missing key, a null, a number or a string
    is UNDECIDABLE (cold review R1)."""
    value = data.get(key)
    return value if value is True or value is False else None


# the two protocol booleans that TOGETHER define "a turn is running on omp right now"
OMP_TURN_FLAGS = ("isStreaming", "isCompacting")


def omp_stream_flags(data: dict) -> tuple[bool | None, str]:
    """(a turn is running, why-not). BOTH flags must be real JSON booleans: this is the one
    fact the ASAP router and the projector select on, so half a reading is no reading."""
    read = {key: json_bool(data, key) for key in OMP_TURN_FLAGS}
    broken = [key for key, value in read.items() if value is None]
    if broken:
        shown = {key: data.get(key) for key in broken}
        return None, ("get_state answered with a non-boolean "
                      + "/".join(broken) + " (gauge broken, NOT idle): "
                      + clip(json.dumps(shown, ensure_ascii=False), 160))
    return any(read.values()), ""


def omp_get_state(sess: Session) -> tuple[dict | None, str]:
    """One correlated get_state round trip: (data, why-not). Live-queries through the fifo
    (documented verb; request-response closes over the events file). `data` is None when the
    engine did not answer or answered anomalously — a rejected/malformed response must stay
    NON-terminal, since mapping it to idle would manufacture a false DONE out of an engine
    error — and `why-not` is the sentence a caller can print."""
    offset = events_size(sess)
    req_id = f"ctl-{uuid.uuid4().hex[:12]}"
    write_frame(sess, build_frame("omp", "get-state", "", req_id))
    reply = wait_for(
        sess, offset,
        lambda f: f.get("id") == req_id and f.get("type") == "response",
        timeout=6.0)
    if reply is None:
        return None, "get_state unanswered in 6s (engine busy or wedged; MAX_POLLS bounds this)"
    if reply.get("command") != "get_state" or reply.get("success") is not True \
            or not isinstance(reply.get("data"), dict):
        return None, ("get_state anomalous response (kept non-terminal): "
                      f"{clip(json.dumps(reply, ensure_ascii=False), 200)}")
    return reply["data"], ""


def project_omp(sess: Session) -> tuple[str, str]:
    """Returns (state, detail): state in RUNNING|IDLE|WAITING."""
    data, why = omp_get_state(sess)
    if data is None:
        return "RUNNING", why
    # the queue DEPTH is the index the steer log is listed by: `queued=6` alone was a black
    # box (field 2026-08-28 — six rulings in flight, no way to see WHICH).
    try:
        sess.queued = int(data.get("queuedMessageCount") or 0)
    except (TypeError, ValueError):
        sess.queued = 0
    active, why = omp_stream_flags(data)
    if active is None:
        # same road as an unanswered get_state: a gauge we cannot read keeps the session
        # NON-terminal. It must never fall through to the idle branch below.
        return "RUNNING", f"{why} — kept non-terminal, queued={sess.queued}"
    if active:
        return "RUNNING", f"streaming, queued={sess.queued}"
    if sess.queued:
        # the DEPTH goes in the detail on this half too: `queued=N` is what the steer-log
        # listing below is indexed by, and an operator reading only the typed line otherwise
        # saw "messages queued" with no idea how many
        return "RUNNING", f"idle but queued={sess.queued}"
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


# ── live turn state: the ONE fact an ASAP steer routes on ────────────────────────────
# Every engine answers "is a turn running RIGHT NOW" from its own protocol truth — never from
# a clock, and never from an operator flag. UNDECIDABLE reads as "no turn": the next-turn
# route always DELIVERS (it is the engine's own queue / next-turn path), while a mid-turn
# frame aimed at an idle engine can be rejected and lose the message. 宁钝勿敏, the same rule
# the stream probe follows: a steer that lands one boundary late beats a steer that vanishes.
def omp_turn_active(sess: Session) -> tuple[bool | None, str]:
    data, why = omp_get_state(sess)
    if data is None:
        return None, why
    return omp_stream_flags(data)


def claude_turn_active(sess: Session) -> tuple[bool | None, str]:
    """claude's stream IS its turn signal: a `result` frame ends the turn — unless the harness
    still owes background tasks, in which case it auto-continues and the turn is still the
    engine's. Nothing since the last delivery = the engine owns a turn."""
    try:
        sent = int(open(sess.sent_offset, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        sent = 0
    frames = complete_frames_from(sess, sent)
    if not frames or frames[-1].get("type") != "result":
        return True, ""
    return bool(claude_pending_background_tasks(frames)), ""


def codex_turn_active(sess: Session) -> tuple[bool | None, str]:
    frames, why = codex_frames(sess)
    if frames is None:
        return None, why
    return codex_turn_from(frames, sess.meta.get("thread")) is not None, ""


TURN_ACTIVE = {"omp": omp_turn_active, "claude": claude_turn_active,
               "codex": codex_turn_active}


# the reason words of a DELIVERED-NEXT-TURN verdict, in the order the selector can produce
# them — DERIVED from the published table, never a second list beside it
STEER_NEXT_TURN_REASONS = tuple(word for code, word, _meaning in SUB_REASONS
                                if code == EXIT_DELIVERED_NEXT_TURN)


def steer_delivery(engine: str, sess: Session) -> tuple[str, str, str]:
    """(wire route, reason, detail) for ONE steer, decided by the engine's live turn state.

    THE ASAP semantic, in one place: the mid-turn half while a turn runs on an engine that has
    one, the next-turn half otherwise.

    `reason` is EMPTY whenever the chosen route IS as soon as the engine allows — mid-turn on a
    running turn, or the next-turn route on an idle engine, which opens that turn at once. It is
    non-empty exactly when a RUNNING turn could not be reached, and then it is the reason word
    of the typed DELIVERED-NEXT-TURN exit:
      capability  — the engine declares no mid-turn route at all (its steer cell is DEGRADED)
      undecidable — the live turn state could not be JUDGED, so 宁钝勿敏 takes the route that
                    always lands (a steer one boundary late beats a steer that vanishes)
    `detail` names the missing capability or the measurement that failed. A typed code plus a
    bounded fact, never a paragraph: the prose note this used to print was routinely lost by
    wrappers that keep only the exit code (owner ruling, R2)."""
    cell = capability(engine, "steer")
    mid, nxt = steer_halves(cell)
    active, why = TURN_ACTIVE[engine](sess)
    if active is None:
        # NAME the broken gauge: "undecidable" without the measurement that failed is how a
        # gauge fault gets read back as a known-idle engine (cold review R1).
        return nxt, sub_reason(EXIT_DELIVERED_NEXT_TURN, SUB_REASON_UNDECIDABLE), why
    if not active:
        return nxt, "", ""
    if cell["state"] == DEGRADED:
        return nxt, sub_reason(EXIT_DELIVERED_NEXT_TURN, SUB_REASON_CAPABILITY), \
            f"{engine} declares no mid-turn steer route"
    return mid, "", ""


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


# ONE read of the stream per classify. Both the stall probe and the tools counter need every
# frame from the stream START — the stall probe PAIRS lifecycle frames across the whole stream,
# so an offset-incremental view would change its meaning, not just its cost — and reading the
# same bytes twice in one process is pure cost. The memo key is (size, mtime_ns) on an
# append-only stream: a stream that really grew between the two callers is read again.
_EVENTS_MEMO: dict[str, tuple[tuple[int, int], tuple[list[dict], bool, bool, str]]] = {}


def _events_snapshot(sess: Session) -> tuple[list[dict], bool, bool, str]:
    """(frames, clean, partial, tail mark) — the whole stream, read once.

    `clean` is False when any complete non-empty line failed to decode: junk the stall path
    cannot read must count as ambiguity (alive), never as silence. `partial` is True when the
    file ends in a NON-EMPTY fragment with no newline yet — a frame is landing RIGHT NOW — and
    `tail mark` identifies those exact bytes so a LATER read can tell the fragment grew. They
    are separate facts because the readers differ: the stall probe reads a fragment as the
    stream MOVING (which it is, and its own mtime gate already saw those bytes), while a source
    that votes "nothing happened" may not read a half-written frame at all — a `tool_use` line
    caught mid-write published a terminal 14/tools-silent while the tool was arriving (cold
    review R1 T1)."""
    try:
        stat = os.stat(sess.events)
        stamp = (stat.st_size, stat.st_mtime_ns)
        hit = _EVENTS_MEMO.get(sess.events)
        if hit is not None and hit[0] == stamp:
            return hit[1]
        with open(sess.events, "rb") as fh:
            blob = fh.read()
    except OSError:
        return [], False, False, ""
    body, nl, tail = blob.rpartition(b"\n")
    partial = bool(tail.strip())
    mark = f"{len(blob)}:{_digest(tail.decode('utf-8', 'replace'))}" if partial else ""
    frames: list[dict] = []
    clean = True
    if nl:
        for line in body.decode("utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                clean = False
    snap = (frames, clean, partial, mark)
    _EVENTS_MEMO[sess.events] = (stamp, snap)
    return snap


def complete_frames_integrity(sess: Session) -> tuple[list[dict], bool, bool]:
    """The frame view of the stream snapshot: (frames, clean, partial)."""
    frames, clean, partial, _mark = _events_snapshot(sess)
    return frames, clean, partial


def events_tail_mark(sess: Session) -> str:
    """The fragment view of the same snapshot: `<size>:<digest>` of the INCOMPLETE trailing
    fragment, or "" when the stream ends on a frame boundary. It is not a frame count and never
    a verdict — the ONE thing it can do is prove bytes arrived between two reads."""
    return _events_snapshot(sess)[3]


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
    frames, clean, _partial = complete_frames_integrity(sess)
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


# ── progress fingerprint: "streaming, and nothing is happening" ──────────────────────
# STALLED-STREAM answers "the stream stopped". THIS answers the other field failure, which
# the stream probe is blind to by construction: the engine keeps emitting frames — thinking,
# tool calls, retries, re-reads — and the WORK stands still (field 2026-08-28, downstream
# seat: 2.5h of healthy streaming, zero commits, zero deliverable bytes, nobody called).
#
# The fingerprint is deliberately COARSE and made only of traces an operator would also
# accept as progress: HEAD, the porcelain hash of the dirty tree, the newest mtime WITHIN
# that dirty set, the newest mtime under the declared deliverable glob, and BLOCKED.md's
# mtime. The dirty-set mtime is not redundant: porcelain reports WHICH files are dirty and
# never what is in them, so half an hour of edits to one already-untracked file left the
# hash bit-identical (caught by this batch's own paired-green fixture). A probe that cannot
# be JUDGED (git missing, cwd not a repo, command error, a dirty set past the bounded scan)
# reads as PROGRESS — the window restarts and this state never fires. 宁钝勿敏, the same rule
# the stream probe follows: the honest fallback for a session nobody can judge is
# WATCH-TIMEOUT, never a fabricated verdict. An ABSENT file is not a broken probe: absence is
# a decided fact and participates in the fingerprint.
PROGRESS_DIRTY_MAX = 500      # more dirty paths than this ⇒ UNJUDGEABLE, never a silent prefix
PROGRESS_MINS_DEFAULT = 30


def progress_window_mins() -> float:
    """AGENT_WATCH_PROGRESS_MINS: minutes of frozen work-trace before STALLED-PROGRESS.
    <=0 disables the probe entirely (no state, no timestamp, no verdict)."""
    try:
        return float(os.environ.get("AGENT_WATCH_PROGRESS_MINS",
                                    str(PROGRESS_MINS_DEFAULT)))
    except ValueError:
        return float(PROGRESS_MINS_DEFAULT)


def _stamp(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts))


# ── ONE shared measurement budget for the whole union ─────────────────────────────────────
# Three git reads at 20s each plus a 5s `pgrep` and a 5s `ps` sum to 70s of local timeout under
# a 30s classify watchdog. The watchdog does stop the hang — by publishing ENGINE-SILENT, a
# CONTROL-PLANE verdict, for a slow MEASUREMENT (cold review R1 P3). So the sources share one
# deadline, sized as a fraction of the very classify deadline they run under, and a probe with
# no budget left answers UNKNOWN: the honest word for a measurement nobody took, and one that
# this state's own rules already handle (it forbids a clean verdict word, never fabricates one).
PROGRESS_BUDGET_SHARE = 0.4     # of status_timeout() → 12s of the default 30s classify deadline
PROGRESS_BUDGET_HEADROOM = 1.0  # …and it must END this far before that deadline, always
PROGRESS_BUDGET_FLOOR = 0.2     # the smallest budget worth starting a probe with
PROGRESS_GIT_TIMEOUT = 20.0     # per-call ceilings, unchanged: the SUM is what needed a bound
PROGRESS_PROC_TIMEOUT = 5.0


class ProbeBudget:
    """The union's remaining measurement time. `take(cap)` is the timeout one probe may ask
    for; 0 means the budget is spent and the caller must return UNKNOWN rather than start a
    read whose only possible outcome is the classify watchdog firing on top of it."""

    def __init__(self, total: float):
        self.deadline = time.monotonic() + max(0.0, total)

    def take(self, cap: float) -> float:
        return min(cap, max(0.0, self.deadline - time.monotonic()))


def progress_budget() -> ProbeBudget:
    """Derived from the classify deadline, never a second knob: whoever tunes
    AGENT_WATCH_STATUS_TIMEOUT is tuning exactly the bound this share is carved out of. The
    share ALONE was not the bound: with a `max(1.0, …)` floor, the supported small knob values
    (1s, 2s) gave the measurement a budget that met or exceeded the whole classify watchdog,
    which is exactly the ENGINE-SILENT-for-a-slow-gauge race this budget exists to remove (cold
    review R2 P3). So the budget also ends one full second before that deadline, and the floor
    is small enough to stay under the smallest legal timeout — strictly below it, for any knob."""
    deadline = float(status_timeout())
    return ProbeBudget(max(PROGRESS_BUDGET_FLOOR,
                           min(deadline * PROGRESS_BUDGET_SHARE,
                               deadline - PROGRESS_BUDGET_HEADROOM)))


def _git_out(cwd: str, budget: ProbeBudget, *argv: str) -> str | None:
    """A bounded git read, bounded TWICE: its own per-call ceiling and the union's shared
    budget. None = UNJUDGEABLE (no git, not a repo, error, timeout, no budget left), which
    every caller must read as progress rather than as 'nothing changed'."""
    window = budget.take(PROGRESS_GIT_TIMEOUT)
    if window <= 0:
        return None
    try:
        proc = subprocess.run(["git", "-C", cwd, *argv], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=window)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def _digest(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:16]


def _newest_mtime(paths) -> float:
    newest = 0.0
    for path in paths:
        try:
            newest = max(newest, os.path.getmtime(path))
        except OSError:
            continue          # vanished between listing and stat: bounded, not a gauge fault
    return newest


def _porcelain_paths(porcelain: str) -> tuple[list[str], bool]:
    """(paths, overflowed) out of `status --porcelain -z`, repo-root relative. Each record is
    `XY <path>\\0`; a rename/copy is followed by an EXTRA NUL-terminated ORIGIN path which
    must be CONSUMED, never read as its own dirty entry — the destination is the live file.
    `-z` is the only porcelain form that carries a path containing a space, a quote or a
    newline without escaping it, so there is nothing to unquote here.

    `overflowed` is the honest answer to a dirty set larger than the bounded scan. Silently
    keeping the first PROGRESS_DIRTY_MAX paths published a mtime measured over a PREFIX as if
    it covered the tree: with 501 dirty files, all the work happening in the 501st left the
    fingerprint bit-identical and fired STALLED-PROGRESS on a session that was moving (cold
    review R1 SB3, reproduced in verify R2). The scan stays bounded — the READING is refused."""
    records = porcelain.split("\0")
    paths, i = [], 0
    while i < len(records):
        entry = records[i]
        i += 1
        if len(entry) < 4:                      # "" (trailing NUL) or a truncated record
            continue
        status, path = entry[:2], entry[3:]
        if "R" in status or "C" in status:
            i += 1                              # the origin path rides its own record
        if path:
            paths.append(path)
            if len(paths) > PROGRESS_DIRTY_MAX:
                return paths, True
    return paths, False


def progress_fingerprint(sess: Session, budget: ProbeBudget) -> tuple[str | None, str]:
    """(work-trace fingerprint, "") — or (None, why) when ANY probe could not be judged. The
    three git reads spend the union's SHARED budget (see ProbeBudget), so a slow repo cannot
    push the whole classify into its watchdog."""
    cwd = sess.meta.get("cwd", "")
    if not cwd or not os.path.isdir(cwd):
        return None, f"session cwd is not a directory ({cwd or 'unset'})"
    head = _git_out(cwd, budget, "rev-parse", "HEAD")
    # `--untracked-files=all` is not a nicety. The DEFAULT folds a whole untracked directory
    # into one `?? dir/` line, so continuous edits to `dir/file` left both the porcelain set
    # and the listed directory's mtime bit-identical: real uncommitted work read as frozen and
    # fired a false STALLED-PROGRESS (cold review R1). Expanding to every untracked FILE is
    # what makes the dirty set track the work instead of its container.
    porcelain = _git_out(cwd, budget, "status", "--porcelain", "--untracked-files=all", "-z")
    top = _git_out(cwd, budget, "rev-parse", "--show-toplevel")
    if head is None or porcelain is None or top is None:
        return None, ("no git, cwd not a repo, the command failed, or the union's measurement "
                      "budget ran out mid-probe")
    # porcelain paths are repo-root relative, so they are resolved against the top level the
    # same command tree reported — never against the session cwd, which may be a subdir
    root = top.strip() or cwd
    names, overflowed = _porcelain_paths(porcelain)
    if overflowed:
        return None, (f"the dirty set exceeds the bounded scan (>{PROGRESS_DIRTY_MAX} paths), "
                      "so the file-mtime half of the fingerprint would cover a prefix and "
                      "call work outside it frozen")
    dirty_paths = [os.path.join(root, path) for path in names]
    parts = [f"head={_digest(head)}", f"dirty={_digest(porcelain)}",
             f"dirtymtime={_newest_mtime(dirty_paths):.3f}"]
    pattern = sess.meta.get("deliverable", "")
    if pattern:
        # same resolution rule as the freshness gate: a relative glob is the SESSION cwd's
        if not os.path.isabs(pattern):
            pattern = os.path.join(cwd, pattern)
        parts.append(f"deliv={_newest_mtime(globmod.glob(pattern)):.3f}")
    try:
        blocked = f"{os.path.getmtime(os.path.join(cwd, 'BLOCKED.md')):.3f}"
    except OSError:
        blocked = "-"
    parts.append(f"blocked={blocked}")
    return "|".join(parts), ""


# ── the other two progress sources ────────────────────────────────────────────────────
# The repo trace above is the only source that leaves a durable artifact, and it is blind to a
# seat that really works and does not write: a long test suite, a docker build, reading code for
# evidence, sending probes. A downstream seat's own audit script retired at hits=0/false=2 for
# exactly that (2026-08-29), so the verdict now reads the UNION of three independent sources and
# fires only when none of them moved. The other two:
#
#   tools — the engine's OWN tool/command frames, counted from the events stream through the
#           per-engine vocabulary this file already pairs for the stall probe. A pure token /
#           thinking stream is NOT counted: streaming was never the question.
#   pane  — the process set in the pane's own group, AS SEEN AT THE SAMPLING POINTS. `pane_pid`
#           IS the pgid (the pane is started as its own session+group leader), so one `pgrep -g`
#           is the whole probe: a subprocess that appears, or is gone by the next poll, is work
#           the repo trace cannot see. What two snapshots CANNOT see is a child both born and
#           reaped between them (probed, cold review R1 P1), so this source only ever reports
#           "no process birth was OBSERVED at a sampling point" — never "no process was born".
#
# Both answer None = UNKNOWN, never a confident zero: a probe that could not look must not vote
# "nothing happened". Which is not the same as "the verdict is dead" — see progress_verdict.
def claude_tool_events(sess: Session, frames: list[dict]) -> int | None:
    """Count of claude's own tool/command frames — the SAME vocabulary claude_inflight pairs
    (tool_use / tool_result items, command_lifecycle transitions), counted instead of paired:
    a tool that opened and closed between two polls left no unmatched pair but IS activity."""
    count = 0
    for frame in frames:
        ftype = frame.get("type")
        if ftype == "command_lifecycle":
            count += 1
        elif ftype in ("assistant", "user"):
            for item in (frame.get("message") or {}).get("content") or []:
                if isinstance(item, dict) and item.get("type") in ("tool_use", "tool_result"):
                    count += 1
    return count


def codex_tool_events(sess: Session, frames: list[dict]) -> int | None:
    """Count of codex item lifecycle frames on our thread. An UNSCOPED frame is counted, the
    one place this differs from codex_inflight's pairing: over-counting can only refresh the
    progress clock (no verdict), while dropping a frame could manufacture a STALLED-PROGRESS."""
    ours = sess.meta.get("thread")
    count = 0
    for frame in frames:
        if frame.get("method") not in ("item/started", "item/completed"):
            continue
        tid = (frame.get("params") or {}).get("threadId")
        if ours and tid is not None and tid != ours:
            continue
        count += 1
    return count


def omp_tool_events(sess: Session, frames: list[dict]) -> int | None:
    """UNKNOWN, always. The omp duplex stream carries lane protocol only — ready, correlated
    command responses, agent_start/agent_end, extension UI requests — and not one tool or
    command frame to count. A zero here would be a source voting "no tool ran" on evidence it
    never had; omp sessions are judged by the other two sources."""
    return None


ENGINE_TOOL_EVENTS = {"claude": claude_tool_events, "codex": codex_tool_events,
                      "omp": omp_tool_events}


def tools_activity(sess: Session, engine: str) -> tuple[str | None, str, bool]:
    """(fingerprint, "", False) of engine tool activity, or (None, why, structural) when this
    source has no answer. `structural` is the m-1 distinction this file already draws between
    [n/a] and [unknown]: an engine whose lane carries no tool frames at all is nothing to look
    at, while an events file nobody can read is a BROKEN GAUGE — and only a broken gauge may
    taint a verdict's reason word. Junk the counter cannot read never reads as silence, the same
    rule complete_frames_integrity serves the stall probe."""
    counter = ENGINE_TOOL_EVENTS.get(engine)
    if counter is None:
        return None, f"engine '{engine or 'unset'}' declares no tool-frame vocabulary", True
    frames, clean, partial = complete_frames_integrity(sess)
    if not clean:
        return None, "the events stream is unreadable or carries an undecodable line", False
    if partial:
        # the counter would read the bytes BEFORE a landing frame as a settled total and vote
        # silent on a tool that is arriving right now (cold review R1 T1)
        return None, ("the events stream ends in an incomplete line — a frame is being written "
                      "as this read happens"), False
    count = counter(sess, frames)
    if count is None:
        return None, f"the {engine} lane's stream carries no tool/command frame vocabulary", True
    return f"tools={count}", "", False


def pane_identity_drift(sess: Session, pane: str, budget: ProbeBudget) -> str:
    """Empty when the pane group may be judged at all, else why it may not. The fence is the one
    `stop` already uses: the leader's START TIME, persisted at start precisely because a pgid
    is reusable. A leader `ps` cannot see is NOT drift — an unused pid cannot be some other
    group's leader, so live members under that pgid are still ours (`reap_tree`'s own
    reasoning). No recorded `pane_lstart` (a session started before the fence) is nothing to
    verify, and a `ps` that could not answer is not an identity claim either."""
    want = " ".join(str(sess.meta.get("pane_lstart", "")).split())
    if not want:
        return ""
    window = budget.take(PROGRESS_PROC_TIMEOUT)
    if window <= 0:
        return "the union's measurement budget ran out before the pane identity check"
    try:
        probe = subprocess.run(["ps", "-p", pane, "-o", "lstart="], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=window)
    except (OSError, subprocess.SubprocessError):
        return "the pane leader's start-time probe failed or timed out"
    have = " ".join(probe.stdout.decode("utf-8", "replace").split())
    if not have or have == want:
        return ""
    return (f"the pane group {pane}'s leader started '{have}' ≠ the recorded '{want}' — pid "
            "reuse, so this group is not this session's")


def pane_pgroup(sess: Session, budget: ProbeBudget) -> tuple[str | None, str, bool]:
    """(fingerprint of the pane group's process set AT THIS SAMPLING POINT, "", False) or
    (None, why, structural). A member that appeared and one that is gone both count as
    movement: either way something under the pane is being started or finished. A still
    fingerprint means no change was OBSERVED at the sampling points, never that no process ran
    (R1 P1). No pane_pid recorded is [n/a] — there is nothing to look at. An EMPTY group is
    [unknown]: meta claims a pane, the leader itself must be a member, and a group with nothing
    in it means this probe cannot be trusted about that session. A pane whose recorded
    start-time fingerprint does not match the live leader is [unknown] too: without that check
    an UNRELATED reused group's stability voted silent and its churn refreshed the progress
    clock forever, on a source that claims to be watching THIS session (R1 P2)."""
    pane = str(sess.meta.get("pane_pid", "")).strip()
    if not pane.isdigit():
        return None, "no pane_pid in session meta", True
    drift = pane_identity_drift(sess, pane, budget)
    if drift:
        return None, drift, False
    window = budget.take(PROGRESS_PROC_TIMEOUT)
    if window <= 0:
        return None, "the union's measurement budget ran out before the pgrep probe", False
    try:
        probe = subprocess.run(["pgrep", "-g", pane], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=window)
    except (OSError, subprocess.SubprocessError):
        return None, "the pgrep probe failed or timed out", False
    if probe.returncode not in (0, 1):          # 1 = no match, a real answer; >1 = broken probe
        return None, f"pgrep exited {probe.returncode}", False
    pids = sorted(line for line in probe.stdout.decode("utf-8", "replace").split()
                  if line.isdigit())
    if not pids:
        return None, f"no process left in the pane's group {pane}", False
    return f"pane={_digest(' '.join(pids))}:{len(pids)}", "", False


# name → (persisted fingerprint key, persisted judged-flag key). The repo source keeps the two
# key names it shipped with (`fp` / `judgeable`): a window persisted by the previous version
# must keep its meaning across an upgrade, and its judged flag is the one the recovery rule
# reads. Order IS publication order, repo first — the repo trace is what an operator checks.
PROGRESS_KEYS = (("repo", "fp", "judgeable"), ("tools", "tools", "tools_j"),
                 ("pane", "pane", "pane_j"))
# What each source is, in the words the verdict prints.
PROGRESS_TRACE = {
    "repo": "HEAD, the dirty-tree hash and its file mtimes, the deliverable mtime and BLOCKED.md",
    "tools": "the engine's own tool/command frames",
    "pane": "the process set in the pane's group",
}
# How many sources must be JUDGED before the union may conclude anything. ONE — and that floor
# is the contract, not a taste call: "any source unknown while every source that COULD be judged
# stood still" is exactly the real-stall shape this state exists to report, and it must fire 14
# carrying `unknown-source` — the word that tells the operator a broken gauge called them, not
# proven stillness. A fixed 2 turned the named cell `repo=unknown + tools=silent + pane=n/a`
# into permanent RUNNING: every read restarted the window and the stall was never reported at
# all (cold review R1 Q1). Only ZERO judged sources withholds, because there the union has no
# observation of any kind to publish — that session's honest fallback is the poll budget running
# out as WATCH-TIMEOUT `progress=unknown`, never a fabricated verdict.
PROGRESS_QUORUM = 1


def progress_sources(sess: Session) -> list[tuple[str, str | None, str, bool]]:
    """[(name, fingerprint or None, why, structural)] for every progress source, in publication
    order, measured under ONE shared budget (see ProbeBudget — an over-budget probe reads
    [unknown], which is what this union is built to survive). None is never "nothing moved": it
    is [unknown] (a gauge that tried and failed) or [n/a] (`structural` — nothing to look at). A
    repo probe nobody can judge is ALWAYS a broken gauge: an unset cwd, a missing git, a dirty
    set past the bounded scan — every one of them is a session whose most important source is
    unreadable, and that must reach the operator."""
    budget = progress_budget()
    fp, fp_why = progress_fingerprint(sess, budget)
    return [("repo", fp, fp_why, False),
            ("tools", *tools_activity(sess, sess.meta.get("engine", ""))),
            ("pane", *pane_pgroup(sess, budget))]


def progress_state(run_dir: str, name: str) -> dict:
    """The persisted window: {round, since, moved, judged} plus one fingerprint + judged flag
    per source (PROGRESS_KEYS). Unreadable/garbage reads as EMPTY, which restarts the window —
    never as a frozen one."""
    try:
        with open(os.path.join(run_dir, f"{name}.duplex.progress"), encoding="utf-8") as fh:
            record = json.load(fh)
    except (OSError, ValueError):
        return {}
    return record if isinstance(record, dict) else {}


def _progress_write(sess: Session, record: dict) -> bool:
    tmp = f"{sess.progress}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
        os.replace(tmp, sess.progress)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def progress_verdict(sess: Session) -> tuple[bool, str, str, str, str]:
    """(frozen, why, observed_change_at, undecidable, sub_reason) — FIVE facts, deliberately not
    folded into one (cold review R1; the sub-reason added by the progress-source batch).

    `frozen` is the STALLED-PROGRESS verdict, and it is now a verdict about the UNION of the
    sources progress_sources() samples: movement in ANY of them is progress, so
    `observed_change_at` is the LAST observation at which any source was JUDGED to move.
    A source nobody could judge never becomes one, because a gauge failing at 14:03 is not the
    work moving at 14:03. `undecidable` is the sentence naming that state, empty when the union
    answered. `sub_reason` is the published word for WHICH observation this is — the word the
    orchestrator branches its disposition on, empty when there is nothing to name.

    THE UNION RULE, in one place:
      * any judged source moved            → no verdict, clock refreshed. The word names it when
                                             the repo trace was the silent one.
      * NO source judged at all            → no verdict, window RESTARTED, `undecidable` says
                                             which sources are blind. A permanently blind gauge
                                             can never be followed by one lucky read that fires.
      * quorum judged, all of them still   → the verdict, once the window is full. The word is
                                             `unknown-source` while any source stays unjudged:
                                             the operator is called, and told that what called
                                             them is a gauge nobody could read, not a proof of
                                             stillness. ONE judged source is enough for that —
                                             see PROGRESS_QUORUM.
    A new round restarts the window: new instructions deserve their own clock. A baseline built
    where there was none — a new round, a source seen judged for the first time, a gauge that
    just recovered — is NOT movement: the stretch it replaces was never measured, so crediting
    it moved the progress clock to the recovery instant and made `None → SAME → SAME` report
    `progress=changed` (verify R2 NB3.3). A rebuild we cannot persist yields no verdict at all —
    a window cannot accumulate in memory across the one-shot classifies that make it up."""
    mins = progress_window_mins()
    if mins <= 0:
        return False, "", "", "", ""
    now = time.time()
    rnd = sess.meta.get("round", "0")
    sampled = {name: (value, why, structural)
               for name, value, why, structural in progress_sources(sess)}
    prev = progress_state(sess.run, sess.name)
    try:
        moved = float(prev["moved"])
    except (KeyError, TypeError, ValueError):
        moved = 0.0
    # THREE buckets, not two: `judged` votes, `blind` is a gauge that tried and failed (it
    # forbids a clean verdict word), `absent` is a source there is nothing to look at for (it
    # votes on nothing and accuses nobody). Collapsing the last two made a session with no
    # recorded pane_pid — or any omp session, whose stream has no tool vocabulary at all —
    # report `unknown-source` forever, i.e. "fix your gauge" for a gauge that was never there.
    judged, blind, absent, active = [], [], [], []
    record: dict = {"round": rnd}
    for name, fp_key, judged_key in PROGRESS_KEYS:
        value, why, structural = sampled[name]
        if value is None:
            (absent if structural else blind).append((name, why))
            # the fingerprint is CARRIED OVER, so the next good read of an unchanged source is
            # not mistaken for movement either
            record[fp_key], record[judged_key] = prev.get(fp_key, ""), False
            continue
        judged.append(name)
        if prev.get(judged_key) and prev.get(fp_key) != value:
            active.append(name)
        record[fp_key], record[judged_key] = value, True
    fresh = prev.get("round") != rnd or not prev.get("since")
    # THE ARRIVING FRAGMENT. A half-written line makes the tools source unknown (it is not a
    # countable frame and must never vote silent) — but a fragment that CHANGED since the last
    # read is bytes the engine wrote inside this window, which is movement, and a terminal 14
    # over a landing `tool_use` is the exact false positive T1 reported. Movement only: a
    # fragment that sits unchanged for a whole window is a TRUNCATED stream, not a landing
    # frame, so it never blocks the (unknown-source) verdict either.
    record["tail"] = tail = events_tail_mark(sess)
    if not fresh and tail != prev.get("tail", ""):
        active.append("tools")
    union = len(judged) >= PROGRESS_QUORUM
    record["judged"] = union
    at = _stamp(moved) if moved else ""
    if not union:
        # BELOW QUORUM, first: the window RESTARTS on every such read, so a permanently blind
        # union can never be followed by one lucky read that fires — and `moved` stays exactly
        # where it was, because a gauge that could not look did not measure a movement either.
        record["since"], record["moved"] = now, moved
        _progress_write(sess, record)
        return False, "", at, (
            f"progress sources below the judged quorum ({len(judged)}/{PROGRESS_QUORUM}): "
            + "; ".join(f"{name} — {why}" for name, why in blind + absent)
            + " — this read proves nothing about progress and may never fire STALLED-PROGRESS"
        ), ""
    if fresh or active:
        # a fresh window (a new round, or no window at all) or a MEASURED movement in one of the
        # judged sources: either way the clock starts now.
        record["since"] = record["moved"] = moved = now
        if not _progress_write(sess, record):
            return False, "", "", "", ""
        return False, "", _stamp(moved), "", _withheld_reason(active, judged)
    try:
        since = float(prev["since"])
    except (TypeError, ValueError):
        return False, "", "", "", ""
    record["since"], record["moved"] = since, moved
    _progress_write(sess, record)
    # `moved` is 0 exactly when no JUDGED movement was ever recorded (the window was opened or
    # rebuilt below quorum). Publish NO timestamp there: `since` is the window's own opening
    # moment — the gauge's clock, not the work's.
    frozen_for = now - since
    if frozen_for < mins * 60:
        return False, "", at, "", ""
    still = "; ".join(PROGRESS_TRACE[name] for name in judged)
    why = (f"still streaming, but no progress source was OBSERVED to move for "
           f"{int(frozen_for // 60)}min — {still}: unchanged at every sampling point since "
           f"{_stamp(since)}")
    if blind:
        why += (" (and unjudged: "
                + "; ".join(f"{name} — {reason}" for name, reason in blind) + ")")
    return True, why, at, "", sub_reason(
        EXIT_STALLED_PROGRESS,
        SUB_REASON_UNKNOWN_SOURCE if blind else SUB_REASON_TOOLS_SILENT)


def _withheld_reason(active: list[str], judged: list[str]) -> str:
    """The published word for a WITHHELD verdict: the repo trace was judged and still, and an
    engine-activity source is what moved. That is the false 14 this batch exists to kill — a
    seat running a long suite / a docker build / reading code writes nothing, and the repo
    source alone called it stalled — so the observation is NAMED rather than merely silent.
    Movement in the repo trace itself needs no word: the state's own sentence covers it."""
    if "repo" in judged and "repo" not in active and active:
        return sub_reason(EXIT_STALLED_PROGRESS, SUB_REASON_TOOLS_ACTIVE)
    return ""


# ── steer delivery log: what `queued=N` is actually holding ──────────────────────────
# duplexctl is the single writer on this lane, so it is the only thing that CAN keep this
# record: one bounded line per delivered steer. The engine reports a queue DEPTH and nothing
# more (field 2026-08-28: `queued=6` with no way to see whether a superseded ruling was about
# to execute), so the depth indexes this log's tail.
STEER_LOG_HEAD_BYTES = 80


def steer_log_append(sess: Session, mode: str, text: str) -> None:
    """Best effort, exactly like the offset journal: a failed log write must never fail the
    steer. Never the body — the full frame is already in the events stream."""
    head = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    head = head.encode("utf-8")[:STEER_LOG_HEAD_BYTES].decode("utf-8", "ignore")
    try:
        with open(sess.steer_log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "mode": mode, "head": head},
                                ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


def queue_routes(engine: str) -> tuple[str, ...]:
    """The wire routes whose delivery really ENTERS the engine's queue. Declared by the steer
    cell, because only the cell knows WHICH half is a queue at all: omp's next-turn half is
    `follow_up`, an engine-held queue, while codex's is `turn/start`, which opens a turn
    immediately and holds nothing."""
    return tuple(capability(engine, "steer").get("queue_routes") or ())


def print_steer_queue(sess: Session, engine: str) -> None:
    """List what the engine still holds, newest last. ONLY a live depth opens this listing:
    an engine with no queue surface reports 0 and prints nothing at all.

    The depth indexes the QUEUED deliveries alone. steer-log records EVERY delivery on the
    lane — mid-turn steers and interrupts included — and neither of those ever entered the
    queue, so tailing the raw log listed a mid-turn steer as a queued item and pushed the
    real one out of the window (cold review R1). The filter is the declared queue route, not
    the verb: only the route the selector actually used can say where the message went."""
    depth = sess.queued
    if depth <= 0:
        return
    wanted = {f"steer:{route}" for route in queue_routes(engine)}
    try:
        with open(sess.steer_log, encoding="utf-8", errors="replace") as fh:
            raw = [ln for ln in fh.read().splitlines() if ln.strip()]
    except OSError:
        raw = []
    queued = []
    for line in raw:
        try:
            rec = json.loads(line)
            when = _stamp(float(rec.get("ts") or 0))
        except (ValueError, TypeError):
            continue
        if rec.get("mode") in wanted:
            queued.append((when, rec))
    if not queued:
        print(f"queued={depth}: no delivery record on this lane (log unreadable, no QUEUED "
              "delivery recorded, or the queue predates it) — read the events stream")
        return
    if len(queued) < depth:
        print(f"queued={depth}: only {len(queued)} queued delivery recorded on this lane — "
              "the rest predates the record; read the events stream for those")
    for when, rec in queued[-depth:]:
        print(f"queued: {when} {rec.get('mode', '?')} {rec.get('head', '')}")


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
    If even the append fails, fall back to remove. ACCEPTED RESIDUAL (review 2026-08-17
    R2, carried): if BOTH fail here and IO then RECOVERS before the next idle, the stale
    pre-reset marks survive and that idle reads as episode 2 — one advisory hint line
    shown early. Closing it needs durable state that survives the same IO failure that
    caused it, which does not exist; the hint's blast radius (one sentence, no authority)
    is priced against that. Do not read this counter as exact."""
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
            misplaced_hint(sess)
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
        frozen, why, at, undecided, reason = progress_verdict(sess)
        if frozen:
            # `reason=` is the branch an orchestrator's disposition hangs on, so it leads: the
            # published word (`agentctl states`) says whether this is a stalled seat or a gauge
            # nobody could read, and the sentence after it is the evidence. The DISPOSITION
            # branches on the SAME word: "read the events tail and steer" is the wrong move
            # when what fired was an unreadable gauge, and one sentence for both cases
            # contradicted this repo's own published disposition table (cold review R1 D1).
            act = ("REPAIR THE GAUGE FIRST — the detail above names the source that could not "
                   "be judged: fix it or verify this seat by hand, and do NOT dispose of this "
                   "as seat stagnation (nothing here proves the seat stood still)"
                   if reason == SUB_REASON_UNKNOWN_SOURCE else
                   "read the events tail FIRST, then steer a concrete next step or interrupt "
                   "the turn")
            print(f"STALLED-PROGRESS: reason={reason} {why} — {act}; never read this as DONE "
                  "(AGENT_WATCH_PROGRESS_MINS tunes the window; 0 disables)")
            print_steer_queue(sess, engine)
            return EXIT_STALLED_PROGRESS
        print(f"RUNNING: {detail}")
        # all three are independent: a blind union publishes the ADMISSION and never a
        # timestamp, and a WITHHELD verdict publishes the word that says why it was withheld —
        # "the repo trace is still, and the engine is not" is the fact an operator would
        # otherwise have to reconstruct from the events tail by hand.
        if undecided:
            print(f"progress={sub_reason(EXIT_WATCH_TIMEOUT, SUB_REASON_UNKNOWN)}: {undecided}")
        if reason:
            print(f"progress_reason={reason}")
        if at:
            print(f"last_progress_at={at}")
        print_steer_queue(sess, engine)
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
                " [2nd+ idle episode this session — likely context exhaustion, or the "
                "declared --deliverable no longer matches this round's actual output "
                "(check the path first); else a fresh session (agentctl stop + start) "
                "usually beats another nudge]")
        print(f"IDLE-NO-DELIVERABLE: engine idle but '{sess.meta.get('deliverable')}' not produced this round — steer the agent; do not stop{hint}")
        misplaced_hint(sess)
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
def codex_start_turn(sess: Session, thread: str, text: str, method: str = "turn/start",
                     on_ready=None):
    """One fresh turn on our thread. Goal delivery (`prompt`) and the next-turn half of a
    steer are the SAME wire operation, so they are the same call — `method` comes from the
    capability cell when a steer makes it, and is the literal lane default for `prompt`."""
    return codex_request(sess, method,
                         {"threadId": thread, "input": codex_text_input(text)},
                         on_ready=on_ready)


def codex_route_steer(sess: Session, ctx: dict):
    """`turn/steer|turn/start` — ASAP delivery. WHICH half goes out was decided by the live
    turn state (ctx["wire"], from steer_delivery); the mid-turn half is guarded by the
    expected turn id, so a steer can never land in a turn that rotated under it."""
    mid, nxt = steer_halves(capability("codex", "steer"))
    if ctx["wire"] != mid:
        return codex_start_turn(sess, ctx["thread"], ctx["text"], nxt, ctx["on_ready"])
    if ctx["active"] is None:
        # the turn ended between the state read and this frame: refuse rather than send a
        # mid-turn frame with no turn to name — re-running the steer opens the next turn
        die("the turn ended between the live-state read and delivery — nothing was sent; "
            "re-run agentctl steer (it will open the next turn)")
    return codex_request(sess, mid,
                         {"threadId": ctx["thread"], "expectedTurnId": ctx["active"],
                          "input": codex_text_input(ctx["text"])},
                         on_ready=ctx["on_ready"])


def codex_route_replace(sess: Session, ctx: dict):
    """`turn/interrupt+turn/start` — the two methods in the route id are the two frames this
    branch really sends, in that order."""
    interrupt, start = ctx["route"].split("+")
    thread, active, why = ctx["thread"], ctx["active"], ctx["active_why"]
    if why:
        # `why` is a BROKEN GAUGE, not an idle engine — and not a licence to improvise a
        # frame either. codex `turn/interrupt` REQUIRES `turnId` (TurnInterruptParams,
        # app-server v0.144.5/v0.147.0), so with the id unreadable there is NO interrupt
        # frame this branch may legally send. R3 sent a threadId-only one on the theory
        # that a thread holds at most one turn; the real engine rejects it as malformed,
        # and only the fixture's auto-fill made that look accepted (verify R4). Refuse
        # BEFORE the wire: an engine round trip that can only be refused is not evidence,
        # and a refusal the operator reads as an engine verdict is worse than no frame.
        die(f"cannot {interrupt}: it needs the running turn's id and the events gauge "
            f"cannot supply it ({why}) — nothing was sent, the attempt did not rotate. "
            f"Read {sess.events} to see the damage, then either repair/clear that stream "
            f"and re-run --interrupt, or agentctl stop {sess.name} and restart with "
            f"resume args.", EXIT_FAILED)
    if active is not None:
        pre_offset = events_size(sess)
        intr = codex_request(sess, interrupt,
                             {"threadId": thread, "turnId": active})
        if intr is None or "error" in intr:
            die(f"{interrupt} not accepted: {clip(json.dumps(intr, ensure_ascii=False), 200)}", EXIT_FAILED)
        # only OUR turn's terminal frame opens the replacement; a stray
        # completion or a timeout must refuse (review S2 2026-07-19). The id is always
        # readable on this path — an unreadable gauge was refused above.
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
    # interrupted turn is terminal (or the turn state was READ as idle), so the replacement
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
    if args.verb in ("prompt", "steer", "interrupt"):
        check_review_budget(sess, text)
    # ── capability gate + route selection ─────────────────────────────────────────────
    # The ONE table decides what this verb may do on this engine, and — for a steer — WHICH
    # of its routes the engine's LIVE turn state allows right now. No per-engine special case
    # lives here, and the sentence a rejected operator reads is the sentence
    # `agentctl capabilities` publishes — they cannot drift apart.
    cap_name = VERB_CAPABILITY.get(args.verb)
    wire = ""
    # a steer that could NOT reach a running turn is its own typed verdict, published only
    # after the frame really landed (see delivered_rc below) — never as a pre-delivery guess
    nxt_reason = nxt_detail = ""
    if cap_name:
        cap_entry = capability(engine, cap_name)
        if cap_entry["state"] == UNSUPPORTED:
            # degrading an unsupported verb into a lesser one would silently keep the doomed
            # turn running — refuse and route the operator to the honest path instead
            die(cap_entry["refusal"])
        if args.verb == "steer":
            wire, nxt_reason, nxt_detail = steer_delivery(engine, sess)
        else:
            wire = cap_entry["route"]

    def delivered_rc() -> int:
        """The typed verdict of a frame that DID land. A steer stopped at the turn boundary
        gets its own exit code: the operator's next move differs (wait out the boundary vs.
        assume the running turn already saw it), and a stdout note carrying that difference was
        routinely swallowed by wrappers that keep only the exit code (owner ruling, R2). Every
        other delivered frame — prompt, interrupt, a mid-turn steer — is plain DONE."""
        if not nxt_reason:
            return EXIT_DONE
        print(f"DELIVERED-NEXT-TURN: reason={nxt_reason} {nxt_detail}".rstrip())
        return EXIT_DELIVERED_NEXT_TURN
    # Identity commit points. The record must be durable BEFORE the frame it authorises
    # leaves — but no earlier than the point where that frame is actually going to be sent:
    # a codex --replace whose interrupt handshake times out is REFUSED, and rotating the
    # attempt for a replacement that never starts made the still-current attempt stale,
    # over-rejecting its own later evidence and invalidating an armed watcher (cold review
    # R1). So `prompt` commits here, and `replace` commits at its engine's real
    # replacement-frame commit point (immediately below for a single-frame replace, after the
    # interrupt handshake for codex). A steer keeps the whole triple.
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
    elif args.verb == "interrupt" and engine != "codex":
        # omp's abort_and_prompt IS the replacement frame: there is no separate handshake to
        # wait for, so the commit point is right here, before write_frame.
        commit_identity("replace")

    offset_box = {}

    def commit_round_state():
        # runs under the writer flock, after the reader is confirmed, before the
        # first byte: a steer whose delivery cannot start must NOT rotate the
        # deliverable epoch or move the sent-offset (stale-gate + phantom
        # ENGINE-SILENT otherwise, review S2 2026-07-19)
        if args.verb in ("prompt", "steer", "interrupt"):
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
            # steer delivery log: the queue's contents, since the engine only reports a
            # depth. Same commit point as the offset journal (delivery is starting) and the
            # same best-effort rule. `prompt` is goal delivery, not a steer, and is not logged.
            if args.verb in ("steer", "interrupt"):
                steer_log_append(sess, f"{args.verb}:{wire}", text)

    if engine == "codex":
        thread = sess.meta.get("thread") or die("no threadId in meta — handshake incomplete")
        if not cap_name and args.verb != "prompt":
            die(f"unsupported codex verb: {args.verb}")
        if args.verb == "prompt":
            # goal delivery is lane PLUMBING: it opens a turn directly instead of borrowing a
            # capability route, because the only cell that names turn/start owns it as one
            # half of the steer alternation.
            reply = codex_start_turn(sess, thread, text, on_ready=commit_round_state)
        else:
            # the capability's whole route id (the alternation for a steer); `wire` below is
            # the half the live turn state already selected
            route = route_of(engine, args.verb)
            handler = ROUTES[engine].get(route)
            if handler is None:
                die(f"codex declares route '{route}' with no executable branch — the capability "
                    "contract and the routing are out of sync")
            active, active_why = codex_active_turn(sess)
            reply = handler(sess, {"thread": thread, "text": text, "verb": args.verb,
                                   "active": active, "active_why": active_why,
                                   "route": route, "wire": wire,
                                   "on_ready": commit_round_state,
                                   "commit": commit_identity})
        if reply is None:
            print("WARN: no JSON-RPC response in 20s — frame delivered, engine may be busy; verify with agentctl status")
            return 3
        if "error" in reply:
            print(f"ERR: engine rejected the frame: {clip(json.dumps(reply['error'], ensure_ascii=False), 300)}")
            return EXIT_FAILED
        print(f"OK: {args.verb} accepted by engine (correlated JSON-RPC response)")
        if args.deliverable:
            _deliverable_moved(args.run_dir, args.session, args.deliverable)
        return delivered_rc()

    req_id = f"ctl-{uuid.uuid4().hex[:12]}"
    write_frame(sess, build_frame(engine, args.verb, text, req_id, wire),
                on_ready=commit_round_state)
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
            _deliverable_moved(args.run_dir, args.session, args.deliverable)
        return delivered_rc()
    print(f"OK: {args.verb} delivered to engine stdin (claude queues it natively; no per-frame ack exists)")
    if args.deliverable:
        _deliverable_moved(args.run_dir, args.session, args.deliverable)
    return delivered_rc()


def _deliverable_moved(run_dir: str, session: str, glob_: str) -> None:
    """steer -d moves the freshness target for the NEXT round. The footer is a one-shot
    frame and is never re-sent, so the OPERATOR is the only one who can tell the worker —
    say it at the decision point (review 2026-08-17 R3: this boundary lived in a helper
    comment no CLI operator ever meets)."""
    meta_update(Session(run_dir, session), "deliverable", glob_)
    print("note: deliverable updated for the NEXT freshness check — the runtime does NOT "
          "re-send the footer; your steer text itself must tell the worker to write "
          f"results into '{glob_}' (chat output is not delivery).", file=sys.stderr)


# ── parameter-surface judgement ───────────────────────────────────────────────
# What `agentctl start` / `agentctl steer -d` parsed but has not committed anywhere yet. It
# lives HERE, not in the shell, for the same reason every other judgement does (agentctl is a
# thin entry): both rules are properties of things this file owns — the session meta's line
# format, and the review seat's deliverable fence. One verb, called before the start owns a
# fifo, a meta file or a tmux session, so a refusal leaves nothing behind.

def _meta_line_problem(flag: str, value: str) -> str | None:
    r"""The meta is one `key=value` per line, so a newline inside a value is a KEY injection:
    `--deliverable $'artifact-*.md\nreview=1'` minted a review seat nobody asked for
    (review R1 M2). Refused rather than encoded — no value here has a legitimate newline.
    EVERY value that reaches meta is checked: the injection is a property of the FILE
    FORMAT, not of one flag."""
    if "\n" in value or "\r" in value:
        return (f"{flag} value contains a newline — the session meta is one key=value per "
                "line, so this would inject meta KEYS (e.g. a smuggled 'review=1'). "
                "Refused rather than encoded: pass a single-line value")
    return None


def deliverable_inside_cwd(glob_: str, cwd: str) -> bool:
    """Whether this deliverable lands inside the session cwd.

    Lane discipline, not a sandbox fact (watch itself resolves absolute globs anywhere):
    review artifacts live WITH the review workspace — written into an unrelated tree they
    survive worktree cleanup as orphans (the misplaced-deliverable incident class), and
    the exit-6 near-miss scan walks cwd only, so a missing deliverable declared outside
    cwd could not even be hunted.

    EVERY glob is judged, relative included — `..` joined onto cwd lands one level up
    (review R1 B1), so the glob is resolved to a candidate path first and one rule covers
    both spellings.

    Two refusals, in order:
      1. any `..` component, anywhere. Refused rather than normalized: the target need not
         exist yet, and lexical normalization is a lie the moment a symlink sits on the path.
      2. the deepest EXISTING ancestor directory, resolved PHYSICALLY, must be the cwd or
         under it. This is what catches `<cwd>/link/result.md` where `link -> ../outside`:
         lexical comparison called that inside the cwd while the write would have landed
         outside. Comparison is by path COMPONENT, never string prefix, so a sibling spelled
         like the cwd (/a/b-2/x against /a/b) does not pass.
    No existing ancestor at all = nothing to resolve = ambiguity = refuse. Ambiguity refusing
    is the trade: the false positive lands loudly on the operator at start/steer time, over a
    deliverable that silently lands as an orphan nothing collects. Glob metacharacters need no special case —
    a wildcard component never names a real directory, so the walk simply passes it.

    A glob with an empty basename (`/`, or anything ending in `/`) names a DIRECTORY, not a
    deliverable, and is refused: it can never satisfy the freshness check (review R2 F4)."""
    cwd = os.path.realpath(cwd)
    target = glob_ if os.path.isabs(glob_) else os.path.join(cwd, glob_)
    if os.pardir in target.split(os.sep):
        return False
    if not os.path.basename(target):
        return False
    anc = os.path.dirname(target)
    while anc and not os.path.isdir(anc):
        parent = os.path.dirname(anc)
        if parent == anc:
            return False
        anc = parent
    if not anc or not os.path.isdir(anc):
        return False
    try:
        phys = os.path.realpath(anc)
    except OSError:
        return False
    # `cwd + os.sep` is `//` at the root, which no real path starts with — so cwd=/ refused its
    # own descendants (review R2 F4). Append the separator only when it is not already there.
    prefix = cwd if cwd.endswith(os.sep) else cwd + os.sep
    return phys == cwd or phys.startswith(prefix)


def cmd_check_params(args: argparse.Namespace) -> int:
    """rc 0 = every supplied value may be committed; rc 1 = refused, reason on stderr.

    The meta-line enumeration below is EVERY param-plane value `agentctl` writes into the meta
    file, checked against its writer block: engine, cwd, deliverable, model, resume_thread,
    review, workflow, max_rounds. `cwd` was missing and a directory legitimately containing a
    newline injected keys past the gate (review R2 F3). Deliberately absent, with reasons:
    `engine` is a PROVIDERS key (a closed set this process owns), `review` is the literal `1`,
    and `max_rounds` is already digits-only by the time it gets here. `thread` and the
    `steer -d` deliverable never pass through this verb at all — meta_update backstops those."""
    for flag, value in (("--cwd", args.cwd), ("--deliverable", args.deliverable),
                        ("--model", args.model), ("--resume-thread", args.resume_thread),
                        ("--workflow", args.workflow)):
        if not value:
            continue
        problem = _meta_line_problem(flag, value)
        if problem:
            print(f"ERR: {args.gate} refused: {problem}", file=sys.stderr)
            return 1
    if args.review and args.deliverable and not deliverable_inside_cwd(
            args.deliverable, args.cwd):
        print(f"ERR: {args.gate} refused: a --review session's deliverable must live INSIDE "
              f"its session cwd ({args.cwd}), and '{args.deliverable}' does not — review "
              "artifacts written into unrelated trees outlive worktree cleanup as orphans, "
              "and the exit-6 near-miss scan walks cwd only. Fix: point the glob inside "
              f"{args.cwd}. "
              "'..' escapes and is refused; the deepest existing ancestor is resolved "
              "physically (symlinks out of cwd refused); no existing ancestor = ambiguous, "
              "refused.", file=sys.stderr)
        return 1
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
        # thread/resume above deliberately has no tier — it sends the threadId alone, so a
        # resumed thread keeps its creation-time tier and `agentctl start` refuses the pair.
        params = {"cwd": sess.meta.get("cwd"), "approvalPolicy": "never",
                  "sandbox": sandbox_tier(engine, bool(sess.meta.get("review")))}
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
# codex is the lane's only OS-sandboxed engine; this dict feeds both the thread/start
# params and the permissionEnforcement row, so a tier rename cannot desync the two.
# Tiers are unified: workspace-write's network block made review seats misread live
# probes/DB reads as DEAD (n=3 false BLOCKED in one night) while the write boundary
# caught nothing. Providers with no OS sandbox declare an EMPTY dict: "no such tier"
# is what makes `--review` a typed refusal.
CODEX_SANDBOX = {"default": "danger-full-access", "review": "danger-full-access"}


def sandbox_tier(engine: str, review: bool) -> str:
    """The tier the handshake pins — always the provider record's, never a literal.
    With both tiers unified the wire frame cannot show WHICH key was selected, so the
    full wiring (meta review=1 → this selection → the frame) is proven against a
    divergent-tier fixture copy of this file (agentctl-duplex.test.sh)."""
    return provider(engine)["sandbox"]["review" if review else "default"]

PROVIDERS: dict[str, dict] = {
    "omp": {
        "bin_env": "AGENTCTL_BIN_OMP",
        "bin": "omp",
        "argv": ("--mode=rpc",),
        # unrecognized `agentctl start` args are forwarded verbatim to the engine — that IS
        # omp's resume surface, so the two facts live in one record
        "extra_argv": True,
        # the lane sets no OS sandbox flag for omp: no tiers, so `--review` is refused
        "sandbox": {},
        "projector": project_omp,
        "capabilities": {
            # both halves are native: `steer` reaches INSIDE the running turn, `follow_up`
            # opens the next one when the session is idle — and `follow_up` is the half that
            # lands in the engine's QUEUE, which is what the depth-indexed listing counts
            "steer": _cap(SUPPORTED, route="steer|follow_up",
                          queue_routes=("follow_up",), impl=build_frame),
            "interruptTurn": _cap(SUPPORTED, route="abort_and_prompt", impl=build_frame),
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
        # bypassPermissions is an APPROVAL setting, not an OS sandbox: no tiers to pin
        "sandbox": {},
        "projector": project_claude,
        "capabilities": {
            # ONE frame, and the honest consequence of that: idle → it opens the next turn at
            # once (which IS as soon as possible, exit 0), mid-turn → there is no public
            # interrupt frame, so it lands at the turn BOUNDARY and the verb exits
            # DELIVERED-NEXT-TURN reason=capability. THE degradation this contract exists to
            # stop advertising as native steering. The protocol has no per-frame ack, so `send`
            # reports delivery, never acceptance.
            "steer": _cap(
                DEGRADED, route="user", queue_routes=("user",), impl=build_frame,
                note="claude has no public mid-turn frame: a steer sent while a turn is "
                     "RUNNING is a QUEUED message landing at the boundary, NOT inside the "
                     "running turn — typed exit DELIVERED-NEXT-TURN reason=capability "
                     "(idle: it opens the next turn immediately, exit 0)"),
            "interruptTurn": _cap(
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
        # the OS-level tiers the handshake pins; `--review` selects the review one
        "sandbox": CODEX_SANDBOX,
        "projector": project_codex,
        "capabilities": {
            # both halves are native: turn/steer reaches inside the running turn (guarded by
            # its id), turn/start opens the next one. codex has NO queue, and with the ASAP
            # contract it no longer needs one — a steer never waits for a boundary here.
            "steer": _cap(SUPPORTED, route="turn/steer|turn/start",
                          impl=codex_route_steer),
            # the interrupted turn must reach a terminal frame before the replacement
            # starts; an interrupt that is not accepted refuses instead of replacing
            "interruptTurn": _cap(SUPPORTED, route="turn/interrupt+turn/start",
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
            # STATIC on purpose: `capabilities` has no session context, so it publishes both
            # tiers rather than reading one back out of a meta it cannot see. Still UNSUPPORTED
            # either way — an OS sandbox bounds what the engine can REACH, it does not give
            # the runtime an approval decision to enforce.
            "permissionEnforcement": _cap(
                UNSUPPORTED,
                refusal="the handshake pins approvalPolicy=never and sandbox="
                        f"{CODEX_SANDBOX['default']} (default lane) or "
                        f"{CODEX_SANDBOX['review']} (`--review`, the review seat): "
                        "approvals are disabled by design, the runtime enforces nothing"),
        },
    },
}
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
    """The published machine contract for the typed state vocabulary: code / name / meaning,
    plus the sub-reason word that qualifies a state where one exists. Disposition is judgement
    that moves with the workflow, not a runtime fact, so it is not published here."""
    return {
        "schemaVersion": TYPED_STATE_SCHEMA_VERSION,
        "states": [{"code": code, "name": name, "meaning": meaning}
                   for code, name, meaning in TYPED_STATES],
        "subReasons": [{"code": code, "reason": word, "meaning": meaning}
                       for code, word, meaning in SUB_REASONS],
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
    names = {code: name for code, name, _meaning in TYPED_STATES}
    # `reason=<word>` is printed VERBATIM as the runtime prints it on the state's own line, so a
    # row and the line it explains are searchable with the same string.
    rwidth = max(len(s["reason"]) for s in doc["subReasons"]) + len("reason=") + 2
    print("\nsub-reasons — the second dimension of the same contract, generated from the "
          "SUB_REASONS table. A row is NOT a promise the exit fires: a sub-reason may name\n"
          "exactly the observation under which its own state is WITHHELD.")
    print("exit  " + "reason".ljust(rwidth) + "meaning (which observation inside the state)")
    for row in doc["subReasons"]:
        print(f"{str(row['code']).rjust(4)}  "
              f"{('reason=' + row['reason']).ljust(rwidth)}{row['meaning']}")
    print("\nstates without a row above carry no sub-reason word at all: "
          + ", ".join(names[code] for code, _n, _m in TYPED_STATES
                      if code not in {c for c, _w, _m in SUB_REASONS}))
    print("\ndisposition — what an orchestrator should DO about a state — is judgement, not a "
          "runtime fact, and is deliberately not published here.")
    return 0


def provider_spec_rows() -> list[str]:
    """The shell-consumable provider spec — `agentctl`'s ONLY provider list.

    `name|bin_env|default_bin|pinned_argv|extra_argv|resume_start_flag|review_sandbox`, argv
    already shell-quoted. The allowlist, the launch command, whether unrecognized start args
    are forwarded (which IS the start-argv resume surface), which start flag drives the
    provider's resume capability and which sandbox tier `--review` pins all come from here, so
    the shell cannot hold an opinion the table does not (cold review R1: a renamed launch
    branch went undetected). `review_sandbox` is EMPTY for a provider with no OS sandbox
    surface, and that emptiness is what makes `--review` a typed refusal in the shell."""
    rows = []
    for name, rec in PROVIDERS.items():
        argv = " ".join(shlex.quote(a) for a in rec["argv"])
        rows.append("|".join([
            name, rec["bin_env"], rec["bin"], argv,
            "1" if rec["extra_argv"] else "0",
            rec["capabilities"]["resume"]["start_flag"],
            rec["sandbox"].get("review", ""),
        ]))
    return rows


def cmd_providers(args: argparse.Namespace) -> int:
    if args.shell:
        print("\n".join(provider_spec_rows()))
    else:
        print("\n".join(PROVIDERS))
    return 0


STATUS_TIMEOUT_DEFAULT = 30
SEND_TIMEOUT_DEFAULT = 50   # > the longest legitimate hold: a 6s live turn-state probe (omp
                            # get_state) + 5s fifo-open + 30s write deadline + slack
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
    # The watch/supervisor half of the lane. Imported HERE, never at module scope: watchctl
    # does `from duplexctl import …` at ITS module scope, so a top-level import would be a real
    # circular import into a half-initialized module. By the time main() runs this module is
    # complete, which is what makes the cycle a one-way edge at runtime.
    import watchctl

    parser = _StrictParser(prog="duplexctl")
    parser.add_argument("--run-dir", default=os.environ.get("AGENT_WATCH_DIR", "/tmp/agent-watch-run"))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_send = sub.add_parser("send", help="build + deliver one frame (flock single-writer)")
    p_send.add_argument("session")
    p_send.add_argument("--verb", default="steer",
                        choices=["prompt", "steer", "interrupt", "get-state"])
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
    p_cls.set_defaults(func=watchctl.cmd_classify)

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
    p_id.set_defaults(func=watchctl.cmd_identity)

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
    p_ws.add_argument("--follow", action="store_true",
                      help="waiter-internal: report a `dead` supervisor under the following "
                           "waiter's own code so its continuation decision reads an exit "
                           "status, never the human line. Same printed verdict either way")
    p_ws.set_defaults(func=watchctl.cmd_watch_state)

    p_wl = sub.add_parser("watch-lease", help="renew the supervisor liveness lease (supervisor "
                                              "internal; also its identity-rotation check)")
    p_wl.add_argument("session")
    p_wl.add_argument("--armed", default="", help="arm-time identity token of the supervisor")
    p_wl.add_argument("--pid", default="", help="supervisor pid (defaults to this process)")
    p_wl.add_argument("--poll", type=float, default=0.0, help="supervisor poll interval, seconds")
    p_wl.add_argument("--max-polls", type=int, default=0, dest="max_polls")
    p_wl.add_argument("--iter", type=int, default=0, help="current poll iteration")
    p_wl.set_defaults(func=watchctl.cmd_watch_lease)

    p_cp = sub.add_parser("check-params", help="judge parameter-surface values before the "
                                               "caller commits any of them (meta-line safety, "
                                               "review deliverable containment)")
    p_cp.add_argument("--gate", default="start", help="label used in the refusal line")
    p_cp.add_argument("--cwd", default="", help="session cwd, already physically normalized")
    p_cp.add_argument("--review", action="store_true",
                      help="the caller requested the review sandbox tier")
    p_cp.add_argument("--deliverable", default="")
    p_cp.add_argument("--model", default="")
    p_cp.add_argument("--resume-thread", default="", dest="resume_thread")
    p_cp.add_argument("--workflow", default="")
    p_cp.set_defaults(func=cmd_check_params)

    p_cap = sub.add_parser("capabilities", help="runtime-generated provider capability contract")
    p_cap.add_argument("--json", action="store_true", help="stable machine shape")
    p_cap.set_defaults(func=cmd_capabilities)

    p_states = sub.add_parser("states", help="runtime-generated typed state vocabulary")
    p_states.add_argument("--json", action="store_true", help="stable machine shape")
    p_states.set_defaults(func=cmd_states)

    p_prov = sub.add_parser("providers", help="the provider adapter spec agentctl launches from")
    p_prov.add_argument("--shell", action="store_true",
                        help="name|bin_env|default_bin|argv|extra_argv|resume_flag|"
                             "review_sandbox rows")
    p_prov.set_defaults(func=cmd_providers)


    # ── orchestration verbs: the judgements the bash entry used to make ──────────────
    # `agentctl` calls these; they are not an operator surface. Each one is one step of a
    # verb whose remaining steps are tmux or process-group work the shell still owns.
    p_status = sub.add_parser("status", help="one-shot typed state + fenced publish + the "
                                             "no-watcher advisories (agentctl status)")
    p_status.add_argument("session")
    p_status.set_defaults(func=watchctl.cmd_status)

    p_arm = sub.add_parser("watch-arm", help="publish the waiter pid, consume any tombstone, "
                                             "announce the arm")
    p_arm.add_argument("session")
    p_arm.add_argument("--pid", type=int, required=True, help="the waiter process pid")
    p_arm.set_defaults(func=watchctl.cmd_watch_arm)

    p_armread = sub.add_parser("watch-arm-read", help="arm-time read of the fenced record; "
                                                      "exit 13 = nothing to adopt, go arm")
    p_armread.add_argument("session")
    p_armread.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    # the two knobs of follow mode. `--followed` is the shell's only piece of follow state (how
    # many re-arms it has already been told to make); the CEILING is read here, from the same
    # env family as every other watch bound, so the POLICY never lives in bash.
    p_armread.add_argument("--followed", type=int, default=0, dest="followed",
                           help="re-arms this waiter has already made (follow mode)")
    p_armread.add_argument("--follow-max", type=int, dest="follow_max",
                           default=_knob("AGENT_WATCH_FOLLOW_MAX", "8"),
                           help="ceiling on automatic re-arms after a NON-action verdict "
                                "(7 WATCH-TIMEOUT, 12 SUPERVISOR-LOST with the supervisor "
                                "provably dead); 0 = the single-round waiter")
    p_armread.set_defaults(func=watchctl.cmd_watch_arm_read)

    p_tomb = sub.add_parser("watch-tombstone", help="record an externally killed waiter")
    p_tomb.add_argument("session")
    p_tomb.add_argument("--signal", required=True)
    p_tomb.add_argument("--ppid", default="0")
    p_tomb.add_argument("--uptime", default="0")
    p_tomb.set_defaults(func=watchctl.cmd_watch_tombstone)

    p_check = sub.add_parser("watch-arm-check", help="may/must a supervisor be established? "
                                                     "0 sensing / 1 structural / 3 spawn / "
                                                     "4 retire-then-spawn")
    p_check.add_argument("session")
    p_check.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    p_check.set_defaults(func=watchctl.cmd_watch_arm_check)

    p_armwait = sub.add_parser("watch-arm-wait", help="block until the supervisor leases; "
                                                      "0 leased / 2 rogue / 4 ours, leaseless")
    p_armwait.add_argument("session")
    p_armwait.add_argument("--mine", type=int, default=0,
                           help="1 when this waiter won the singleton tmux name")
    p_armwait.set_defaults(func=watchctl.cmd_watch_arm_wait)

    p_wait = sub.add_parser("watch-wait", help="the dumb waiter loop over the fenced record")
    p_wait.add_argument("session")
    p_wait.add_argument("--armed-seq", type=int, default=-1, dest="armed_seq")
    p_wait.add_argument("--poll", type=float, default=_knob("AGENT_WATCH_POLL_SECS", "15"))
    p_wait.add_argument("--max-polls", type=int, dest="max_polls",
                        default=_knob("AGENT_WATCH_MAX_POLLS", "240"))
    p_wait.add_argument("--followed", type=int, default=0, dest="followed",
                        help="re-arms this waiter has already made (follow mode)")
    p_wait.add_argument("--follow-max", type=int, dest="follow_max",
                        default=_knob("AGENT_WATCH_FOLLOW_MAX", "8"),
                        help="ceiling on automatic re-arms after a NON-action verdict; "
                             "0 = the single-round waiter")
    p_wait.set_defaults(func=watchctl.cmd_watch_wait)

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
    p_sense.set_defaults(func=watchctl.cmd_sense_loop)

    p_ret = sub.add_parser("supervisor-retire", help="last words, then the lease (in that "
                                                     "order); the tmux kill is the shell's")
    p_ret.add_argument("session")
    p_ret.add_argument("--why", default="", help="cause to leave for an attached waiter")
    p_ret.set_defaults(func=watchctl.cmd_supervisor_retire)

    p_clean = sub.add_parser("stop-cleanup", help="duplex-lane teardown between the tmux kill "
                                                  "and the reap")
    p_clean.add_argument("session")
    # opaque, never interpreted: it only has to be the SAME string the matching stop-sentinel
    # gets and a different one from any other stop invocation's
    p_clean.add_argument("--token", default="",
                         help="per-invocation nonce stamped on the sentinel handoff sample")
    p_clean.set_defaults(func=watchctl.cmd_stop_cleanup)

    p_sent = sub.add_parser("stop-sentinel", help="false-DONE sentinel, sampled after the reap")
    p_sent.add_argument("session")
    p_sent.add_argument("--token", default="",
                        help="the nonce stop-cleanup was given; a sample stamped with anything "
                             "else is a failed handoff, not a reading")
    p_sent.set_defaults(func=watchctl.cmd_stop_sentinel)

    p_res = sub.add_parser("stop-residue", help="the no-lane branch of stop")
    p_res.add_argument("session")
    p_res.add_argument("--killed", type=int, default=0,
                       help="1 when the shell already killed a bare tmux session")
    p_res.add_argument("--reap-rc", type=int, default=0, dest="reap_rc",
                       help="exit code the shell's own reap produced")
    p_res.set_defaults(func=watchctl.cmd_stop_residue)

    p_probe = sub.add_parser("stop-probe", help="pre-kill snapshot of descendants ALREADY "
                                                "outside the pane's process group")
    p_probe.add_argument("session")
    p_probe.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
    p_probe.add_argument("--snapshot", required=True, help="where the pre-kill evidence lands")
    p_probe.set_defaults(func=watchctl.cmd_stop_probe)

    p_surv = sub.add_parser("stop-survivors", help="post-reap re-probe; stderr advisory only — "
                                                   "never a signal, never stop's rc")
    p_surv.add_argument("session")
    p_surv.add_argument("--snapshot", required=True)
    p_surv.set_defaults(func=watchctl.cmd_stop_survivors)

    # --dry-run is REQUIRED, not defaulted: the read-only promise has to be spelled out by the
    # caller, so no future flag can quietly turn this verb into one that acts.
    p_inv = sub.add_parser("inventory", help="read-only candidate overview: control-state drift "
                                             "+ PPID=1 engine orphans")
    p_inv.add_argument("--dry-run", action="store_true", required=True, dest="dry_run",
                       help="the ONLY accepted spelling; this verb never acts")
    p_inv.set_defaults(func=watchctl.cmd_inventory)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
