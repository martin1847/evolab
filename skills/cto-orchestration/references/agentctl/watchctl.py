#!/usr/bin/env python3
"""watchctl — supervised watch, supervisor lease and stop/inventory verbs for the duplex lane.

Split out of duplexctl.py verbatim (2026-08-30): the engine side of the lane (frame builder,
classify, the provider/state vocabularies, the argv front door) stayed there, the PATROL side
came here. Nothing in this module is an operator surface of its own — it has NO argv front door
and never grows one: `duplexctl.py` stays the single entry, its `main()` wires these 20 `cmd_*`
functions, and the self-exec below re-enters through THAT file. `duplexctl` imports this module
inside `main()` only, which is what keeps the import cycle a cycle on paper and not at runtime.
"""
from __future__ import annotations

import argparse
import datetime
import glob as globmod
import json
import math
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time

# self-locating, exactly as duplexctl does it and for the same reason: this file is loaded by
# absolute path (tests copy the whole directory), where sys.path never contains the agentctl dir.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import duplexctl  # noqa: E402  (needs the path above)
import identity  # noqa: E402  (needs the path above)
from duplexctl import (  # noqa: E402  (needs the path above)
    EXIT_DONE, EXIT_ENGINE_SILENT, EXIT_FAILED, EXIT_IDLE_NO_DELIVERABLE, EXIT_OVER_BUDGET,
    EXIT_RUNNING, EXIT_STALLED_EXTERNAL, EXIT_STALLED_PROGRESS, EXIT_STALLED_STREAM,
    EXIT_SUPERVISOR_LOST, EXIT_WAITING_INPUT, EXIT_WATCH_TIMEOUT, OVER_BUDGET_FACTOR,
    PANE_GONE_WHY, PROVIDERS, SUB_REASON_CHANGED, SUB_REASON_UNCHANGED, SUB_REASON_UNKNOWN,
    Session, acquire_writer_lock, arm_watchdog, classify, die, escaped_descendants,
    over_budget_line, progress_state, ps_identity_rows, status_timeout, sub_reason, tmux_alive,
    wait_budget,
)


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
                    EXIT_STALLED_STREAM, EXIT_STALLED_PROGRESS, EXIT_OVER_BUDGET}
PROCEED_TO_ARM = 13                             # arm-mode only, never leaves the waiter
# ── follow mode: the waiter's LIFETIME, never a verdict ──────────────────────────────
# `agentctl watch` FOLLOWS its session by default. The waiter used to hand one round's verdict
# back and exit, so every non-action outcome cost the orchestrator a manual re-arm — a purely
# mechanical round, ~27 of them a day across two seats (2026-09-01). The codes below are how the
# python side asks the driving shell to re-arm instead of exiting. Plumbing exactly like
# PROCEED_TO_ARM: each one is either mapped back to a published class or consumed by that loop,
# so none of them can reach a caller.
FOLLOW_ROTATED = 16    # a steer opened the next round before any verdict was delivered: aim at
                       # the new round. UNBOUNDED and unable to spin — producing one takes an
                       # external steer, and the re-armed waiter follows the round it finds.
FOLLOW_REARM = 17      # a NON-ACTION verdict was reported and this waiter re-arms; bounded by
                       # AGENT_WATCH_FOLLOW_MAX, because an auto-continue with no ceiling is a
                       # waiter that can wait forever without ever saying so.
FOLLOW_DEAD = 18       # `--follow` readers only: SUPERVISOR-LOST whose liveness fact is `dead`
                       # (lease intact and fenced to us, its pid gone). Every OTHER 12 is
                       # `unknown` — retired, wedged, pid recycled, evidence unreadable — and
                       # ends the waiter: only a supervisor that provably died may be
                       # re-established without an operator looking at the session first.
# The outcomes a re-arm is equivalent to what the seat did by hand. 14 STALLED-PROGRESS is
# deliberately NOT one of them: a false 14 is a three-source blind spot to fix, not to outwait.
FOLLOW_CONTINUES = (EXIT_WATCH_TIMEOUT, FOLLOW_DEAD)
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
    see `supervisor_liveness`.

    `--follow` is the FOLLOWING waiter's flag and refines exactly one outcome: rule 3's `dead`
    case leaves as FOLLOW_DEAD instead of 12, so the continuation decision reads an exit code
    instead of sniffing the human line for a word it printed itself. The line, and every other
    caller's 12, are byte-identical."""
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
    return FOLLOW_DEAD if (args.follow and live == "dead") else EXIT_SUPERVISOR_LOST


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

_CTL = os.path.abspath(duplexctl.__file__)  # self-exec re-enters the argv front door

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

def _watch_mark(rc: int) -> None:
    """The machine-readable half of a verdict: `EXIT=<n>`. A FOLLOWING waiter prints it for a
    round it reports without dying on, so that round's outcome reaches the stream in the shape
    wrappers already parse — the LAST such line is still this process's own exit."""
    print(f"EXIT={rc}")

def _watch_exit(rc: int) -> int:
    """Every watch exit prints the verdict twice: the typed `=== … ===` line for humans and a
    final `EXIT=<n>` for pipes — a wrapper that swallows the process exit code can still parse
    the verdict off the last line."""
    _watch_mark(rc)
    sys.exit(rc)

def _follow_or_exit(name: str, rc: int, followed: int, follow_max: int) -> int:
    """Mark the verdict this waiter just printed, then decide whether its life ends with it.

    An ACTION verdict ends it: the seat is woken by the process exit, so swallowing one strands
    an orchestrator blocked on an answer that is already on its stream. The two non-action
    outcomes are the ones an operator answered by re-running the identical command, so the
    waiter does that itself — bounded by `--follow-max` (AGENT_WATCH_FOLLOW_MAX), where 0
    reproduces the single-round waiter exactly, verdict for verdict.

    A followed 12 is still reported as 12: FOLLOW_DEAD refines the READ, not the vocabulary."""
    reported = EXIT_SUPERVISOR_LOST if rc == FOLLOW_DEAD else rc
    if rc not in FOLLOW_CONTINUES or followed >= follow_max:
        return _watch_exit(reported)
    _watch_mark(reported)
    print(f"--- [{name}] following: re-arm {followed + 1}/{follow_max} after EXIT={reported} "
          "— no action verdict for this round, so this waiter stays with the session ---")
    return FOLLOW_REARM

def _session_round(run_dir: str, name: str) -> str:
    """The round a conclusion computed NOW would be about. Empty normalizes to 0, the same
    default the writer uses, so a round-less legacy meta is not a permanent refusal."""
    return (identity._meta_read(os.path.join(run_dir, f"{name}.duplex.meta")).get("round")
            or "0")

def _round_now(run_dir: str, name: str) -> str:
    """The round a conclusion would be about, or "" when there is no meta to read at all: a
    session whose control state vanished has not ROTATED, it is GONE, and saying that is the
    canonical read's job (SESSION-GONE) — never a rotation claim made by a loop."""
    path = os.path.join(run_dir, f"{name}.duplex.meta")
    if not os.path.isfile(path):
        return ""
    return identity._meta_read(path).get("round") or "0"

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
                quiet: bool = False, follow: bool = False) -> tuple[int, str]:
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
    if follow:
        argv.append("--follow")
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
    if rc not in (2, 4, 5, 6, 7, 8, 11, EXIT_OVER_BUDGET):
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
    # The wait budget, on the ONE surface an orchestrator polls by hand. Advisory exactly like
    # the no-watcher line below it: the typed line and the exit code are untouched, because a
    # one-shot read is not the round's conclusion and `status` publishes no non-DONE class.
    if rc == EXIT_RUNNING:
        over, used, expect = wait_budget(Session(run, name))
        if over:
            # `.1f` printed a real 3-second overrun as "0.0min" (live probe 2026-09-02): a
            # number that reads as zero makes the note look broken, so a sub-minute delta
            # keeps two decimals and anything larger stays at one
            over_by = f"{used - expect:.2f}" if used - expect < 1 else f"{used - expect:.1f}"
            print(f"note: over budget by {over_by}min (expect {expect:g}min) — the "
                  f"WAIT is over budget past {expect * OVER_BUDGET_FACTOR:g}min, the work is "
                  "not judged; an armed watcher reports OVER-BUDGET once for this round")
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
    # THE watch-arm commit point of the phase ledger: one row per ARM, which in follow mode
    # means one row per episode — the waiter re-captures its fences per round, so a session
    # has as many arms as it has rounds watched. It is the only ledger event that is not a
    # state change of the seat, and it is here because "the orchestrator was attached" is a
    # different fact from "the seat was running".
    identity.phase_record(run, name, "watch_arm", extra={"mode": args.mode})
    print(f"=== [{name}] DUPLEX-WATCH ARMED at {_clock()} "
          "(stateless — safe to kill and re-run) ===")
    return 0

def cmd_watch_arm_read(args: argparse.Namespace) -> int:
    """The arm-time read: a conclusion already on disk is this invocation's answer (that IS
    the recovery path a killed waiter takes), unless a previous waiter already delivered it.
    PROCEED_TO_ARM means there is none and the caller goes on to establish the sensing loop.

    This read is also where a re-run after a WATCH-TIMEOUT lands, so it follows a non-action
    verdict exactly as the polling loop does: report it, DELIVER it (an undelivered record is
    the one the next arm read would replay), then re-arm. It never needs `--follow`: arm mode
    answers off the record alone and never reaches supervisor liveness, so 12 cannot arise."""
    run, name = args.run_dir, args.session
    rc, msg = _read_state(run, name, arm=True, armed_seq=args.armed_seq)
    if rc == PROCEED_TO_ARM:
        if msg:
            print(msg)
        return PROCEED_TO_ARM
    print(f"=== [{name}] {msg} ===")
    deliver_conclusion(run, name, rc, args.armed_seq, None, None)
    return _follow_or_exit(name, rc, args.followed, args.follow_max)

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
    consecutive samples bound n-1 elapsed intervals, and the reader converts.

    The loop belongs to ONE round. A steer that opens the next one ends this episode with
    FOLLOW_ROTATED, and that test comes BEFORE the read: every quantity this iteration would
    produce — the lease sample, the wedge count, the watermark the read is fenced by — is about
    the round that just closed, and a fresh arm is the thing that reads the new one. Nothing is
    lost by re-arming, because the round fence already refuses the closed round's conclusion to
    every reader in the lane."""
    run, name = args.run_dir, args.session
    poll, maxp = args.poll, args.max_polls
    cap = maxp * 2 + 24
    mark_seen, same = b"", 0
    graced = False
    rnd = _round_now(run, name)
    i = 1
    while i <= cap:
        now = _round_now(run, name)
        if now and rnd and now != rnd:
            print(f"--- [{name}] round rotated {rnd} → {now}: following the new round "
                  "(this episode closed with no verdict to deliver) ---")
            return FOLLOW_ROTATED
        mark = _lease_mark(run, name)
        if not mark:
            same = 0                            # no lease to have watched
        elif mark == mark_seen:
            same += 1
        else:
            same, mark_seen = 1, mark
        rc, msg = _read_state(run, name, armed_seq=args.armed_seq,
                              lease_unchanged=same, poll=poll, follow=True)
        if rc in (EXIT_SUPERVISOR_LOST, FOLLOW_DEAD) and not graced \
                and "supervisor's last words" not in msg:
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
            return _follow_or_exit(name, rc, args.followed, args.follow_max)
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

def _sense_conclude(args: argparse.Namespace, rnd: str, rc: int, msg: str,
                    on_delivered=None) -> None:
    """One conclusion point for both modes. Daemon: publish through the fenced writer and stop
    — a refused publish publishes NOTHING and leaves the refusal where the waiter reads it.
    Inline: the pre-supervised behaviour (DONE publishes, everything else prints).

    `on_delivered` runs at the instant this conclusion is really OUT — after an accepted
    publish in daemon mode, and immediately before the printed verdict in inline mode (where
    the print plus this process's exit code IS the delivery, since inline persists no non-DONE
    class). It exists so a caller can record what was DELIVERED rather than what was
    attempted; it never runs on a refused publish."""
    run, name = args.run_dir, args.session
    if args.mode == "daemon":
        prc, pmsg = _ctl(run, "identity", "publish", name, "--armed", args.armed,
                         "--rc", str(rc), "--round", rnd, "--detail", msg, merge_stderr=True)
        if prc != 0:
            # nothing delivered ⇒ nothing recorded: a caller's claim must stay retryable
            print(f"[{name}] conclusion {rc} NOT published: {pmsg}")
            super_note(run, name, pmsg)
            sys.exit(3)
        if on_delivered is not None:
            # THE at-least-once window: dying between the accepted publish above and this
            # callback leaves a delivered conclusion with no ledger line, and the next arm
            # reports that round again (ruled accept-documented, R2 — see _report_over_budget)
            on_delivered()
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
    if on_delivered is not None:
        on_delivered()
    _watch_exit(rc)

def _expect_mark_path(run_dir: str, name: str) -> str:
    return os.path.join(run_dir, f"{name}.duplex.expect-report")

def _expect_mark_key(run_dir: str, name: str, rnd: str) -> str:
    """(sessionId, attemptId, round) — the identity of ONE wait-budget report, or "" when the
    active identity cannot be established (nothing to key a report to, and classify already
    answers such a session with IDENTITY-UNKNOWN)."""
    rec, status = identity.IdentityStore(run_dir, name).load()
    if status != identity.STATUS_OK or rec is None:
        return ""
    return f"{rec.get('sessionId')}/{rec.get('attemptId')}/{rnd}"

def _expect_reported(run_dir: str, name: str, key: str) -> bool:
    """Whether THIS (session, attempt, round) already had a report DELIVERED. A file nobody can
    read answers False: an unreadable ledger is not evidence that the orchestrator was told."""
    try:
        with open(_expect_mark_path(run_dir, name), encoding="utf-8", errors="replace") as fh:
            return key in {line.strip() for line in fh}
    except OSError:
        return False

def _expect_recordable(run_dir: str, name: str) -> bool:
    """Whether a report COULD be recorded, probed WITHOUT recording anything (no bytes are
    written). An unrecordable report is not made at all — a state that repeats every poll would
    wake the orchestrator forever, and firing exactly once is this state's whole value.
    Accepted hole, and the only one left: if the path becomes unwritable between this probe and
    the append below, that report is delivered but unrecorded and the next arm may repeat it
    once. The alternative — recording first — is what made a failed publish silence the round
    forever (review R1 B1)."""
    try:
        with open(_expect_mark_path(run_dir, name), "a", encoding="utf-8"):
            pass
    except OSError:
        return False
    return True

def _expect_record(run_dir: str, name: str, key: str) -> bool:
    """Append-only, like the idle-marks sidecar. False = the report was NOT recorded."""
    try:
        with open(_expect_mark_path(run_dir, name), "a", encoding="utf-8") as fh:
            fh.write(key + "\n")
    except OSError:
        return False
    return True

# ── OVER-BUDGET delivery semantics: AT-LEAST-ONCE, and that is a RULING, not a gap ──────
# The claim below is fenced (one publisher per round) and the ledger records only what was
# DELIVERED, which closes every direction except one: a supervisor that dies AFTER `identity
# publish` returns 0 and BEFORE the ledger append leaves a published 19 with no ledger line, so
# the next arm reports that same (session, attempt, round) a SECOND time. Owner ruling (R2,
# accept-documented): the state is at-least-once, not exactly-once — an orchestrator woken
# twice pays one wasted read, a report LOST pays another 2h03m. Exactly-once needs the terminal
# record itself to carry the report key and every consumer/re-arm to reconcile against it,
# which is a separate batch (a new field in the published record shape, plus the reconciliation
# on both the waiter and arm paths). `ob-doc-postpublish-crash-may-duplicate` pins the CURRENT
# direction on purpose: that assertion is meant to be flipped, consciously, by that batch.
# KILL CRITERION for the ruling (record it here, not in a doc nobody re-reads): if a live
# double report is observed even ONCE in 4 weeks, do the reconciliation batch. Zero in 4 weeks
# means the window is theoretical and the ruling stands.
def _report_over_budget(args: argparse.Namespace, rnd: str) -> None:
    """Conclude OVER-BUDGET at THIS sampling point, or return and keep sensing.

    ONE report per (sessionId, attemptId, round) — at-least-once, see the block above — and the
    whole decision (read the ledger, deliver the conclusion, record it) runs under the LANE'S
    SINGLE-WRITER LOCK, the same flock `send` serializes steers on. Two properties come from
    that, and neither survives a lock-free check-then-append (review R1 B1):
      * two observers of the same round cannot both publish. The loser reads the winner's
        record and returns to ordinary sensing (a terminal class, or the poll budget running
        out as WATCH-TIMEOUT);
      * a steer that opens the next round cannot interleave with a claim about the old one.
    The ledger records what was DELIVERED, never what was attempted: a publish refused by the
    identity fence, an unwritable terminal surface or a crash in that window records nothing,
    so a re-armed waiter may report the same round again. A plain steer opens a new round and
    `--interrupt` a new attempt — either may report again, because the budget is per round and
    so is the estimate behind it.
    A lock we cannot even open is not a fence, and an unfenced report is not made."""
    run, name = args.run_dir, args.session
    sess = Session(run, name)
    over, used, expect = wait_budget(sess)
    if not over:
        return
    try:
        lock = open(sess.wlock, "a", encoding="utf-8")
    except OSError:
        return
    try:
        # blocking, exactly as every other writer on this lane takes it: the only holders are
        # `send` and a peer observer, both bounded by their own watchdogs
        acquire_writer_lock(lock)
        key = _expect_mark_key(run, name, rnd)
        if not key or _expect_reported(run, name, key) or not _expect_recordable(run, name):
            return
        _sense_conclude(args, rnd, EXIT_OVER_BUDGET, over_budget_line(sess, used, expect),
                        on_delivered=lambda: _expect_record(run, name, key))
    finally:
        lock.close()

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
    # The work-trace window as the FIRST sensing read left it — the only thing that lets a
    # WATCH-TIMEOUT say whether the budget ran out on a working session or a frozen one. It is
    # captured after that read, not at arm time: before the first classify there is no window
    # at all, and comparing "absent" to "present" called every session CHANGED.
    armed_progress = None
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
        if armed_progress is None:
            armed_progress = progress_state(run, name).get("moved")
        if rc == EXIT_RUNNING:
            silent = silent + 1 if "no output since last steer" in msg else 0
            if silent >= silent_max:
                _sense_conclude(args, rnd, EXIT_ENGINE_SILENT,
                                f"ENGINE-SILENT at {_clock()} — steer delivered but no engine "
                                f"output ~2min; inspect {run}/{name}.duplex.stderr.log")
            idle = tmo = 0
            # every sampling point is a budget check, and it is the LAST word of this branch:
            # ENGINE-SILENT above is a stronger observation about the same round, and a
            # session that declared no budget cannot reach past this line at all.
            _report_over_budget(args, rnd)
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
    record = progress_state(run, name)
    moved = record.get("moved")
    if not record.get("judged") or not moved:
        # the probe is disabled (window <=0), never got to persist a window, its LAST read left
        # the union below its judged quorum, or NO judged movement was ever recorded (`moved` is
        # 0/absent exactly when the window was opened or restarted below quorum, so the blind
        # stretch is unattributed): say UNKNOWN rather than claim a measurement nobody made.
        # A union nobody could judge is not evidence of movement and not evidence of stillness.
        word = sub_reason(EXIT_WATCH_TIMEOUT, SUB_REASON_UNKNOWN)
    else:
        word = sub_reason(EXIT_WATCH_TIMEOUT, SUB_REASON_CHANGED if moved != armed_progress
                          else SUB_REASON_UNCHANGED)
    _sense_conclude(args, rnd, EXIT_WATCH_TIMEOUT,
                    "WATCH TIMEOUT — engine still active; re-run watch or investigate "
                    f"progress={word}")
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
# The identity half of the same handoff. `stop-cleanup` re-reads the lane's identity right
# before it clears it and compares that with the token the shell captured INSIDE the lane fence;
# `ok` means the two describe the same seat, `drift` means they do not and no phase-ledger stop
# row may be written for this teardown (review R2: a stop that killed one lane while holding
# another lane's token wrote the ledger row for the wrong seat).
_STOP_ID_OK = "ok"
_STOP_ID_DRIFT = "drift"

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

# The control state teardown removes. `duplex.wlock` is DELIBERATELY not in it: that file is
# the lane's single-writer lock and now also the fence `agentctl start`/`agentctl stop` take
# around their whole claim/teardown, so it must be the SAME inode across a stop + same-name
# start. Unlinking a lock that a live critical section holds does not end the section — it
# just lets the next caller create a fresh inode and walk straight in, which is exactly the
# concurrent-stop race the fence exists to close. Same rule, same reason as
# `IdentityStore.clear`'s refusal to unlink the identity lock: the file outlives the session as
# an empty marker in the run dir.
_STOP_KEPT = ("duplex.in", "duplex.meta", "duplex.round-started",
              "duplex.prompt", "duplex.sent-offset", "duplex.write-intent",
              "duplex.watch.pid", "duplex.idle-marks", "duplex.progress",
              "duplex.expect-report", "steer-log.jsonl")

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

def cmd_lane_fence(args: argparse.Namespace) -> int:
    """Take the lane's single-writer lock on a file descriptor THE CALLER already holds open.

    WHY a verb and not a lock taken inside each step: `agentctl start`'s claim and `agentctl
    stop`'s teardown are each a SEQUENCE of shell steps (tmux, process-group signals) with
    python verbs in between, and the fence has to span the whole sequence. `flock(2)` belongs
    to the open file DESCRIPTION, not to the process, so a child that locks an inherited fd
    leaves the lock held by the parent's description after it exits — the shell opens fd 9 on
    `<run>/<name>.duplex.wlock`, this verb locks it, and closing fd 9 (or the shell exiting)
    releases it. That is the whole mechanism: no new lock file, no new state, no daemon.

    It is the SAME lock `send` and the over-budget reporter take, which is the point: while a
    teardown holds it no frame can open a round underneath, and while a claim holds it no
    concurrent stop can locate the lane, kill it, and hand a different lane's identity to the
    ledger (review R2). NOTHING inside either fenced sequence takes this lock, so it cannot
    self-deadlock — `wait-ready`, `send` and `classify` all do, and all three run OUTSIDE it.

    Blocking acquire under a SIGALRM bound, exactly like `acquire_writer_lock` argues: the
    kernel's flock queue is fair, and a LOCK_NB retry loop starves against a churning writer.
    A timeout is a REFUSAL — the caller must fail loudly rather than proceed unfenced, because
    proceeding is what produced the divergence this fence closes."""
    def _expired(_signum, _frame):
        raise TimeoutError

    signal.signal(signal.SIGALRM, _expired)
    signal.setitimer(signal.ITIMER_REAL, args.timeout)
    try:
        duplexctl.acquire_writer_lock(args.fd)
    except TimeoutError:
        print(f"ERR: {args.gate} '{args.session}' could not take the lane fence "
              f"({args.run_dir}/{args.session}.duplex.wlock) within {args.timeout:g}s — another "
              "start/stop/steer holds it. Nothing was changed and no phase-ledger row was "
              f"written; re-run, or inspect with agentctl status {args.session}",
              file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"ERR: {args.gate} '{args.session}' cannot lock the lane fence ({exc}) — a lane "
              "that cannot be fenced must not be claimed or torn down", file=sys.stderr)
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    return 0

def cmd_stop_cleanup(args: argparse.Namespace) -> int:
    """Duplex-lane teardown, between the tmux kill and the reap. Control state goes down
    BEFORE the reap: the terminal-marker guard (the meta re-check right before publish) prices
    in a µs kill→cleanup gap, and a grace-long reap in between would stretch it to seconds.

    It is also where the phase ledger's stop row is AUTHORISED, and the authorisation is a
    re-read: the lane's identity is compared, right before this verb clears it, with the token
    the shell captured inside the lane fence. Agreement rides the sentinel handoff as `ok`, and
    anything else as `drift` — which the sentinel turns into "no stop row, and say why".
    Belt and braces on top of the fence: under it a same-name restart cannot start until this
    teardown releases, so drift should be unreachable. It is checked anyway because the failure
    it guards against is a row that names the wrong seat, and the reader has no way to spot
    one; a missing row is recoverable, a confidently wrong one is not."""
    run, name = args.run_dir, args.session
    marker = os.path.join(run, f"{name}.terminal.json")
    marker_mtime = _stat_mtime(marker) if os.path.isfile(marker) else None
    current = identity.IdentityStore(run, name).token()
    verdict = _STOP_ID_OK if _phase_same_seat(args.identity, current) else _STOP_ID_DRIFT
    if verdict == _STOP_ID_DRIFT:
        print(f"WARN: identity drifted between the kill and the cleanup of '{name}' — the "
              f"fence captured '{args.identity or '-'}' but the lane now reads '{current}'; NO "
              "phase-ledger stop row will be written for this teardown (a row naming the wrong "
              "seat cannot be spotted by any reader)", file=sys.stderr)
    sample = _STOP_SAMPLE_NONE if marker_mtime is None else str(marker_mtime)
    _write_stop_sample(_stop_sample_path(run, name), args.token, f"{sample}|{verdict}")
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

def _phase_stop_triple(token: str) -> tuple[str, str]:
    """(session_id, attempt) out of the arm-style identity token `agentctl` captured at the TOP
    of stop, or ("", "") when that token does not describe an established identity.

    The token is `IdentityStore.token()`'s output, carried through as an opaque string exactly
    like every other fence token in this lane: `<sessionId>/<attemptId>/<incarnation>` for a
    live record, and `<STATUS>/<nonce>` — TWO segments by construction — for an absent or
    corrupt one. So the three-segment shape IS the "we really know who this was" test, and
    nothing here has to interpret the identity itself."""
    parts = token.strip().split("/", 2)
    if len(parts) != 3 or not parts[0] or not parts[1]:
        return "", ""
    return parts[0], parts[1]


def _phase_same_seat(captured: str, current: str) -> bool:
    """Do two identity tokens describe the SAME seat? Both unresolvable counts as agreement —
    there is nothing to contradict, and the row that follows carries the reserved unknown key
    anyway. One resolvable and the other not is a DISAGREEMENT: a lane that had an identity
    when the fence captured it and none by cleanup (or the reverse) is not the same lane."""
    return _phase_stop_triple(captured) == _phase_stop_triple(current)


def _phase_record_stop(run: str, name: str, token: str, reason: str, lane: int) -> None:
    """The ledger's stop row, under the two conditions that make it true.

    A stop row is a claim that a seat ENDED. Two ways that claim used to be false:
      * the reap failed and survivors are still running (review R1 B2) — the caller does not
        call this at all in that case, and the seat correctly stays `open` in the readings,
        matching the survivor advisory stop already prints on stderr. No `stop_failed` event
        was added for it: a sixth event is a schema change for every reader, and "still open
        plus a loud stderr advisory" already says the true thing.
      * the identity was resolved by NAME after cleanup released it, so a same-name restart
        could inherit the row (review R1 B3). The triple is captured before cleanup now; when
        it is genuinely unobtainable the row is written under the reserved
        PHASE_SESSION_UNKNOWN key, which the reader refuses to treat as a seat — an
        unattributable ending is reported as unattributable, never applied by elimination."""
    session_id, attempt = _phase_stop_triple(token)
    identity.phase_event(run, name, "stop",
                         session_id or identity.PHASE_SESSION_UNKNOWN, attempt,
                         extra={"reason": reason, "lane": lane})


def cmd_stop_sentinel(args: argparse.Namespace) -> int:
    """False-DONE sentinel, part 2 — advisory, and it must never change stop's rc.

    With the tree fully reaped nothing can write the events file anymore, so THIS is the
    honest sampling point. Events growing >2s past the marker = the round was concluded while
    the engine still spoke (the silent-misfire class, made loud); +2s prices in the
    marker-write vs final-flush race.

    It is also the phase ledger's STOP commit point, under THREE conditions, all of which have
    to hold for the row to be true:
      * the reap finished — `--reap-rc` non-zero means survivors outlived the KILL, and a
        ledger that calls that an ending would shorten an open seat and manufacture idle time
        out of a process that is still burning the machine;
      * the handoff sample is the one THIS stop's cleanup wrote (the nonce proves it), because
        without it there is no evidence about the seat's identity at teardown time at all;
      * that sample says `ok` — cleanup compared the fence-captured token against the lane's
        own identity right before clearing it, and `drift` means they named different seats.
    Missing evidence therefore costs the row, never its accuracy: a reader can recover from a
    seat that shows `open` too long, and cannot recover from a stop attributed to the wrong
    one."""
    run, name = args.run_dir, args.session
    sample = _stop_sample_path(run, name)
    handoff = _read_stop_sample(sample, args.token)
    mtime_part, has_verdict, id_verdict = (handoff or "").partition("|")
    if args.reap_rc == 0 and has_verdict and id_verdict == _STOP_ID_OK:
        _phase_record_stop(run, name, args.identity, "stopped", 1)
    elif args.reap_rc == 0:
        why = f"reported {id_verdict}" if has_verdict else "is missing, or is not this stop's"
        print(f"WARN: no phase-ledger stop row for '{name}' — the cleanup handoff {why}, so "
              "which seat this teardown ended cannot be established", file=sys.stderr)
    handoff = mtime_part if has_verdict else None
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
    # set is part of the observable teardown, not an implementation detail of the delete.
    # `duplex.wlock` is NOT in this set, for the reason spelled out at `_STOP_KEPT`: it is the
    # fence this very branch is running inside, and unlinking it would let the next caller
    # create a fresh inode and walk past a live critical section.
    for suffix in ("duplex.in", "duplex.prompt", "duplex.sent-offset",
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
    # THE stop commit point of the no-lane branch, after the shell's own reap. `lane=0` says
    # this stop found no duplex meta, so the identity was very likely already gone before the
    # verb ran: the captured token then has no triple and the row lands under
    # PHASE_SESSION_UNKNOWN, which the reader refuses to close a seat with. Same reap
    # condition as the duplex branch — a teardown whose reap failed did not end anything.
    # Neither branch below records anything: an idempotent re-stop is not a second seat end
    # (the real one already wrote its row, and a duplicate would move the seat's end to
    # whenever somebody re-ran the verb), and a name with no lane state, no tmux, no residue
    # and no post-mortem artifact never held a seat to close at all.
    if cleaned:
        if reap_rc == 0:
            _phase_record_stop(run, name, args.identity, "no-lane", 0)
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


# ── phases: the read side of the phase ledger ────────────────────────────────────────
# `agentctl phases` is the ONE reader of <run>/phase-ledger-*.jsonl, and it prints READINGS.
# That word is the entire contract:
#   * it emits numbers plus the coverage of the data behind them, and it emits no ruling.
#     There is deliberately NO `wall≈` / `avoidable≈` line anywhere in this file: those two
#     numbers are the orchestrator's judgement about a batch (which minutes were overhead,
#     which rework was worth paying for), and a machine suggestion would be copied into the
#     ledger as if a machine had decided it. The instrument gives the human a floor to argue
#     from; it does not do the arguing.
#   * it says what it could NOT see. A window with a missing shard reports coverage `unknown`,
#     and the retro pane then prints n/a instead of numbers — a reading nobody can vouch for
#     is worse than a blank, because it looks like a measurement.
#   * the aggregation key is `session_id`, NEVER the CLI name. Names are reusable by design
#     (identity.py's opening paragraph), so a restarted `d10phase-omp` is a SECOND seat with
#     its own span; merging the two would understate the dispatch count and overstate one
#     seat's wall in the same breath.
#
# KILL CRITERION for this reading face (slug `phase-readings`, settled by GATE-AUDIT like every
# other gate here): four weeks with no retro consuming these numbers ⇒ drop the retro pane and
# keep the ledger as forensics only. Separately: `dispatch_latency` never once cited in a retro
# ⇒ that row comes out of the table. A number that is only ever printed is decoration.
PHASE_SESSION_ROWS = 12         # human table bound — the whole block stays inside 30 lines
PHASE_IDLE_TOP = 3              # idle segments named individually; the rest is in the total
PHASE_LATENCY_TOP = 3


def _phase_parse_ts(text: object) -> float | None:
    """Epoch seconds for one ledger `ts`, or None when the field is not the ONE format the
    writer emits. A row whose instant cannot be read is not placed on the timeline at all."""
    if not isinstance(text, str) or not text:
        return None
    raw = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        stamp = datetime.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        return None
    return stamp.timestamp()


def _phase_since(spec: str, now: float) -> tuple[float, str]:
    """(epoch, refusal). `<N>m|h|d` is relative to now; anything else must be RFC3339 WITH an
    offset — a naive timestamp would be read in the host's timezone while every ledger row is
    UTC, and that skew is invisible in the output, which is the worst place for it."""
    text = spec.strip()
    if not text:
        return now - 86400.0, ""
    rel = re.fullmatch(r"([0-9]+)([mhd])", text)
    if rel:
        unit = {"m": 60.0, "h": 3600.0, "d": 86400.0}[rel.group(2)]
        return now - int(rel.group(1)) * unit, ""
    stamp = _phase_parse_ts(text)
    if stamp is None:
        return 0.0, (f"--since '{spec}' is neither <N>m/<N>h/<N>d nor an RFC3339 instant "
                     "carrying a UTC offset (2026-09-02T00:00:00+08:00, 2026-09-02T16:00:00Z)")
    return stamp, ""


def _phase_contains(repo: str, cwd: str) -> bool:
    """Is `cwd` inside `repo` by PATH COMPONENT? `startswith` answers yes for
    /Users/x/evolab-wt-d10clauses under /Users/x/evolab — a sibling worktree is a different
    repo, and folding its seats into this batch's readings is exactly the quietly wrong number
    this instrument exists to remove. `repo` arrives already realpath'd; `cwd` is resolved
    here so a symlinked spelling on disk still lands inside."""
    if not repo or not cwd:
        return False
    try:
        return os.path.commonpath([os.path.realpath(cwd), repo]) == repo
    except ValueError:      # different drives, or one path relative: no containment to judge
        return False


def _phase_load(run_dir: str) -> tuple[list[dict], int, set[str], list[str]]:
    """(rows in APPEND order, skipped, shard days READ, shard days that could not be read).

    Append order — shard day ascending, then line order — is the CAUSAL order, and it is the
    order the durations and the dispatch scan use. Sorting by `ts` would erase the one thing a
    regressed clock leaves behind: a row that arrived after another while claiming to be
    earlier. A line that is not decodable JSON, not an object, carries an event outside the
    closed set, has no readable `ts` or no `session_id` is COUNTED and dropped: the count is
    the honest signal, and guessing at a broken row would put invented time in a total.

    A day is `present` only once its shard was OPENED AND READ. It used to be marked present
    from the glob alone, with the open failure merely `continue`d, so a directory wearing a
    shard's name, a dangling symlink and a mode-000 file all read as "that day is covered,
    and it contained nothing" — the window then had no holes, coverage said `ok`, and the
    retro pane printed a full set of zeroes it had never measured (review R1 B1). Existence of
    a path is not readability of its data, and the difference is the whole value of `coverage`.
    `UnicodeDecodeError` counts as unreadable too: a shard that is not text is not a shard."""
    rows: list[dict] = []
    skipped = 0
    days: set[str] = set()
    unreadable: list[str] = []
    for day, path in identity.phase_shards(run_dir):
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.readlines()
        except (OSError, UnicodeDecodeError):
            if day not in unreadable:
                unreadable.append(day)
            continue
        days.add(day)
        for raw in lines:
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except ValueError:
                skipped += 1
                continue
            if not isinstance(row, dict):
                skipped += 1
                continue
            stamp = _phase_parse_ts(row.get("ts"))
            sid = row.get("session_id")
            if (stamp is None or row.get("event") not in identity.PHASE_EVENTS
                    or not isinstance(sid, str) or not sid):
                skipped += 1
                continue
            row["_t"] = stamp
            rows.append(row)
    return rows, skipped, days, unreadable


def _phase_needed_days(since: float, now: float) -> list[str]:
    """Every UTC day the window touches, oldest first. A day in this list with no shard on
    disk is a HOLE, and a hole cannot be told apart from "no seat ran that day" — which is why
    it reads `unknown` rather than a smaller number."""
    days: list[str] = []
    cursor = since
    while cursor <= now:
        day = identity.phase_shard_day(cursor)
        if day not in days:
            days.append(day)
        cursor += 86400.0
    tail = identity.phase_shard_day(now)
    if tail not in days:
        days.append(tail)
    return days


def _phase_round_of(row: dict) -> int:
    """The highest round number this row states, 0 when it states none. `round_after` (steer)
    and `round` (terminal) are the two spellings, and a terminal record's round arrives as a
    STRING because that is what the session meta holds."""
    best = 0
    for field in ("round_after", "round"):
        value = row.get(field)
        if isinstance(value, str) and value.isdigit():
            value = int(value)
        if isinstance(value, int) and not isinstance(value, bool) and value > best:
            best = value
    return best


def _phase_report(run_dir: str, since: float, now: float, repo: str) -> dict:
    """The whole reading, as data. Every judgement in here is about the DATA (is it covered, is
    a duration measurable) and never about the work the data describes."""
    rows, skipped, days_present, days_unreadable = _phase_load(run_dir)
    needed = _phase_needed_days(since, now)
    missing = [day for day in needed if day not in days_present]

    # Each session's start row, found across ALL shards but never from the FUTURE: a seat that
    # opened before the window still owns the engine/cwd/review facts, and `--repo` cannot
    # judge a seat whose cwd it never saw. This is the "跨分片向前找 start" half of the window
    # semantics. A `start` claiming an instant after `now` is not a beginning this reading may
    # measure from — it would put `begin` in the future and turn every duration negative.
    starts: dict[str, dict] = {}
    for row in rows:
        if row["event"] == "start" and row["_t"] <= now:
            starts.setdefault(row["session_id"], row)

    def in_repo(sid: str) -> bool:
        if not repo:
            return True
        start = starts.get(sid)
        return start is not None and _phase_contains(repo, str(start.get("cwd") or ""))

    # THE WINDOW IS CLOSED AT BOTH ENDS. It used to have a lower bound only, so a row written
    # by a clock that had jumped forward — or any future row in a shard — decided `state`,
    # `last_event`, `batch_span` and `seat_wall` for a batch it had not happened in, and did it
    # without tripping `clock_regressed` (review R1 M1). A reading may not extend past the
    # instant it was taken; future rows are counted and dropped, exactly like corrupt ones.
    future_dropped = sum(1 for row in rows if row["_t"] > now)
    window = [row for row in rows
              if since <= row["_t"] <= now and in_repo(row["session_id"])]
    clock_regressed = 0

    order: list[str] = []
    grouped: dict[str, list[dict]] = {}
    for row in window:
        seq = grouped.get(row["session_id"])
        if seq is None:
            seq = grouped[row["session_id"]] = []
            order.append(row["session_id"])
        seq.append(row)

    sessions: list[dict] = []
    unattributed = 0
    for sid in order:
        seq = grouped[sid]
        # The reserved key an unattributable teardown writes (identity.PHASE_SESSION_UNKNOWN).
        # It is NOT a seat and must never become one: a `stop` that cannot name the seat it
        # ended would otherwise close a seat by elimination, which is the exact failure the
        # captured-triple handoff exists to prevent. Its rows still count for `batch_span`
        # (they happened), and their presence makes the whole reading `partial`.
        if sid == identity.PHASE_SESSION_UNKNOWN:
            unattributed += 1
            continue
        start = starts.get(sid)
        start_t = start["_t"] if start is not None else None
        if start is None:
            unattributed += 1
        # WINDOW INTERSECTION: a seat that opened before `--since` contributes only the part of
        # itself this window can see, and flags it. An unclipped span would report time the
        # reading never measured, in a total the retro is about to argue from.
        begin = max(start_t, since) if start_t is not None else max(seq[0]["_t"], since)
        last = seq[-1]
        # THE STATE TRANSITION TABLE, and both halves of the terminal→steer case:
        #   start            → open (round 1)
        #   steer            → open (round_after); an --interrupt steer carries a new attempt
        #   terminal         → closed for THAT round; the row stays in `terminals` forever
        #   terminal → steer → open again on the next round, WITH the earlier terminal kept
        #   stop             → stopped, final
        # `state` therefore reads off the LAST event only, while `terminals` is the full
        # history: a seat that concluded round 1 and is now working round 2 is honestly both.
        state = ("stopped" if last["event"] == "stop"
                 else "closed" if last["event"] == "terminal" else "open")
        end = last["_t"] if state in ("stopped", "closed") else now
        duration: float | None = end - begin
        if end < begin:
            # a regressed clock, NOT a zero-length seat: clamping to 0 would publish a
            # measurement of "no time passed" that nobody actually made
            clock_regressed += 1
            duration = None
        terminals = [{"ts": row["ts"], "round": str(row.get("round") or ""),
                      "class": str(row.get("class") or ""), "rc": row.get("rc")}
                     for row in seq if row["event"] == "terminal"]
        rounds = max([_phase_round_of(row) for row in seq] + [1 if start is not None else 0])
        sessions.append({
            "session_id": sid,
            "name": str(seq[0].get("name") or ""),
            "engine": str((start or {}).get("engine") or ""),
            "cwd": str((start or {}).get("cwd") or ""),
            "review": 1 if (start or {}).get("review") == 1 else 0,
            "start": start["ts"] if start is not None else None,
            "truncated_start": 0 if (start_t is not None and start_t >= since) else 1,
            "rounds": rounds,
            "terminals": terminals,
            "last_event": last["event"],
            "last_ts": last["ts"],
            "state": state,
            "open_round": rounds if state == "open" else None,
            "duration_s": duration,
            "_begin": begin,
            "_end": end,
        })

    frame_start = min((row["_t"] for row in window), default=0.0)
    frame_end = max((row["_t"] for row in window), default=0.0)
    batch_span = frame_end - frame_start if window else 0.0
    seat_wall = sum(s["duration_s"] for s in sessions if s["duration_s"] is not None)
    review_wall = sum(s["duration_s"] for s in sessions
                      if s["review"] == 1 and s["duration_s"] is not None)

    # idle_span — sweep-line over the UNION of seat intervals, complement taken inside the
    # observed frame only. Outside the frame there is no evidence of idleness, just no data,
    # and the two must not print as the same number. KNOWN BOUNDARY: a seat whose duration was
    # excluded as clock-regressed leaves its interval out of the union, so its time reads as
    # idle — `clock_regressed` is printed beside the total for exactly that reason.
    merged: list[list[float]] = []
    for lo, hi in sorted((s["_begin"], min(s["_end"], frame_end)) for s in sessions
                         if s["duration_s"] is not None):
        lo, hi = max(lo, frame_start), min(hi, frame_end)
        if hi <= lo:
            continue
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    gaps: list[tuple[float, float]] = []
    cursor = frame_start
    for lo, hi in merged:
        if lo > cursor:
            gaps.append((cursor, lo))
        cursor = max(cursor, hi)
    if frame_end > cursor:
        gaps.append((cursor, frame_end))
    idle_top = [{"from": identity.phase_stamp(lo), "to": identity.phase_stamp(hi),
                 "seconds": hi - lo}
                for lo, hi in sorted(gaps, key=lambda g: g[1] - g[0], reverse=True)]

    # dispatch_latency — per terminal, and NEVER summed. Each row is "this seat reached a
    # terminal state; the next dispatch inside the same repo went out N minutes later". A sum
    # would be meaningless across overlapping seats and would read as one accumulated delay,
    # so only the list and its maximum are published.
    latency: list[dict] = []
    pending = 0
    for index, row in enumerate(window):
        if row["event"] != "terminal":
            continue
        nxt = next((later for later in window[index + 1:]
                    if later["event"] in ("start", "steer")), None)
        if nxt is None:
            pending += 1
            continue
        gap = nxt["_t"] - row["_t"]
        if gap < 0:
            clock_regressed += 1
            continue
        latency.append({"terminal_ts": row["ts"], "session_id": row["session_id"],
                        "name": str(row.get("name") or ""),
                        "class": str(row.get("class") or ""),
                        "next_ts": nxt["ts"], "next_event": nxt["event"],
                        "next_name": str(nxt.get("name") or ""), "seconds": gap})

    # An UNREADABLE shard is `unknown`, exactly like a missing one: both mean this reading
    # cannot speak for a day the window covers, and the pane that consumes it must print n/a
    # rather than a set of zeroes nobody measured.
    if missing or days_unreadable:
        coverage = "unknown"
    elif unattributed or any(s["truncated_start"] for s in sessions):
        coverage = "partial"
    else:
        coverage = "ok"

    for s in sessions:
        del s["_begin"], s["_end"]
    return {
        "since": identity.phase_stamp(since),
        "now": identity.phase_stamp(now),
        "repo": repo or None,
        "coverage": coverage,
        "shards_present": sorted(days_present),
        "shards_needed": needed,
        "shards_missing": missing,
        "shards_unreadable": sorted(days_unreadable),
        "first_event": identity.phase_stamp(frame_start) if window else None,
        "last_event": identity.phase_stamp(frame_end) if window else None,
        "events": len(window),
        "skipped": skipped,
        "clock_regressed": clock_regressed,
        "future_dropped": future_dropped,
        "readings": {
            "batch_span_s": batch_span,
            "seat_wall_s": seat_wall,
            "review_wall_s": review_wall,
            "idle_span_s": sum(item["seconds"] for item in idle_top),
            "idle_top": idle_top[:PHASE_IDLE_TOP],
            "idle_segments": len(idle_top),
            "dispatch_latency": latency,
            "dispatch_latency_max_s": max((hop["seconds"] for hop in latency), default=None),
            "dispatch_pending": pending,
        },
        "sessions": sessions,
        "note": ("readings only — no verdict is derived here; wall/avoidable stay the "
                 "orchestrator's judgement"),
    }


def _phase_mins(seconds: object) -> str:
    return "n/a" if not isinstance(seconds, (int, float)) else f"{seconds / 60:.1f}m"


def _phase_print(report: dict, run_dir: str) -> None:
    """The bounded human face: ≤30 lines, and every line is a number or the provenance of
    one."""
    read = report["readings"]
    shards = ",".join(report["shards_present"]) or "-"
    print("== agentctl phases — READINGS ONLY, no verdict is derived here ==")
    print(f"ledger  : {run_dir}/{identity.PHASE_LEDGER_PREFIX}*{identity.PHASE_LEDGER_SUFFIX}"
          f"  since={report['since']}  now={report['now']}"
          + (f"  repo={report['repo']}" if report["repo"] else ""))
    print(f"coverage: {report['coverage']}  shards_present={shards}  "
          f"shards_missing={','.join(report['shards_missing']) or '-'}  "
          f"shards_unreadable={','.join(report['shards_unreadable']) or '-'}")
    print(f"          events={report['events']}  first={report['first_event'] or '-'}  "
          f"last={report['last_event'] or '-'}  skipped={report['skipped']}  "
          f"clock_regressed={report['clock_regressed']}  "
          f"future_dropped={report['future_dropped']}")
    print(f"batch_span       {_phase_mins(read['batch_span_s'])}  (first → last event of the "
          "window)")
    print(f"seat_wall        {_phase_mins(read['seat_wall_s'])}  (SUM of per-seat spans = seat "
          "machine-time; above batch_span means seats overlapped — NOT wall clock)")
    print(f"review_wall      {_phase_mins(read['review_wall_s'])}  (the review seats' share of "
          "seat_wall)")
    idle = "; ".join(f"{_phase_mins(gap['seconds'])} @{gap['from']}"
                     for gap in read["idle_top"]) or "-"
    print(f"idle_span        {_phase_mins(read['idle_span_s'])} over "
          f"{read['idle_segments']} gap(s) with no seat open; top: {idle}")
    print(f"dispatch_latency max {_phase_mins(read['dispatch_latency_max_s'])} — "
          f"{len(read['dispatch_latency'])} measured, {read['dispatch_pending']} with no next "
          "dispatch yet; PER TERMINAL, never summed")
    for hop in read["dispatch_latency"][:PHASE_LATENCY_TOP]:
        print(f"  {hop['terminal_ts']} {hop['name']} {hop['class']} → "
              f"+{_phase_mins(hop['seconds'])} {hop['next_event']} {hop['next_name']}")
    print("-- seats (key = session_id; a restarted NAME is a new seat) --")
    for seat in report["sessions"][:PHASE_SESSION_ROWS]:
        print(f"  {seat['name'][:24]:<24} {seat['state']:<7} r{seat['rounds']:<3}"
              f"{_phase_mins(seat['duration_s']):>8}"
              f"{'~' if seat['truncated_start'] else ' '} {seat['engine'][:6]:<6} "
              f"{'review' if seat['review'] else '-':<6} "
              f"{','.join(t['class'] for t in seat['terminals']) or '-'}")
    if len(report["sessions"]) > PHASE_SESSION_ROWS:
        print(f"  … {len(report['sessions']) - PHASE_SESSION_ROWS} more seat(s) — --json for all")
    print("(~ = the seat opened before the window; its span is the intersection only)")


def cmd_phases(args: argparse.Namespace) -> int:
    """`agentctl phases` — the entire read side. rc 0 whenever the arguments are legal: an
    empty ledger is a legitimate reading (no events, coverage unknown), never a failure. The
    only nonzero exit is a parameter-surface refusal, decided before a byte is read."""
    now = time.time()
    since, refusal = _phase_since(args.since, now)
    if refusal:
        die(refusal)
    repo = ""
    if args.repo:
        if not os.path.isabs(args.repo):
            die(f"--repo needs an absolute path (got {args.repo!r}) — containment is judged "
                "against a resolved root, and a relative spelling has none")
        repo = os.path.realpath(args.repo)
    report = _phase_report(args.run_dir, since, now, repo)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    else:
        _phase_print(report, args.run_dir)
    return 0
