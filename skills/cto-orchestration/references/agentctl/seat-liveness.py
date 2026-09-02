#!/usr/bin/env python3
"""seat-liveness — SessionStart|UserPromptSubmit reminder: RUNNING seats nobody is watching.

It answers ONE question, and `cto-guard-stop.py` imports the same answer from here so the two
channels can never disagree: which agentctl seats OF THIS REPO are RUNNING with no live watcher.

WHERE THE FACT COMES FROM. `agentctl status <s>` appends `note: no watcher armed — arm: agentctl
watch <S>` when classify says RUNNING and the watcher pid is absent or dead (watchctl.py
`cmd_status`, the `rc == 10 and not watcher_alive(...)` branch). That note is the SINGLE SOURCE
and this script consumes only it: reading pid / lease files here would be a second liveness
implementation, and the two would drift the first time the run dir layout moved.
Side effect, stated rather than hidden: `status` is not a pure read — for a session with a
declared deliverable it publishes an idle conclusion (identity publish, fenced by the armed
token). This hook therefore does exactly what the orchestrator's own `agentctl status` does, no
more; it is the only command that carries the watcher note.

OWNERSHIP. The run dir is shared by every seat on the box, so a census is not a licence: only
seats whose meta `cwd=` sits at or under THIS payload's git top level are ours to judge (retro:
账内 ≠ 你的). An undecidable top level does NOT widen into silence and does not filter either —
it reports every seat and says the ownership question went unanswered.

REMINDER, NOT A GATE, and the asymmetry with the Stop gate is deliberate: when the census cannot
answer (unlistable run dir, missing agentctl, a status that never returned) this script stays
SILENT, because a reminder that fires on a machine without agentctl is pure noise. The Stop gate
announces its blindness instead, because there silence reads as approval.

Wiring: entries in `guard-hooks.json` (SessionStart + UserPromptSubmit). Both events add plain
stdout to the model's context, which is why this speaks in plain text and never JSON.
Exit 0 always. 0 bytes = nothing to say.
Throttle: the SAME seat set is reported at most once per `SEAT_LIVENESS_NAG_INTERVAL_SECS`
(default 600) on UserPromptSubmit; SessionStart is NEVER throttled, because a new / resumed /
compacted context has no memory of the previous reminder and the stamp it would consult was
written for a conversation it cannot see (owner ruling 2026-09-02, accept-documented).
Env: AGENT_WATCH_DIR (run dir), SEAT_LIVENESS_NAG_INTERVAL_SECS (default 600).

PYTHON FLOOR 3.9, and it is load-bearing: the shipped entry is `#!/usr/bin/env python3`, which on
a stock macOS host resolves to /usr/bin/python3 3.9.6. PEP 604 (`str | None`) is evaluated at
class/module level and raises TypeError THERE, i.e. the hook dies before `main()` and the Stop
gate degrades to "sibling could not be loaded" — a silently disabled gate. Annotations here use
`typing.Optional`; PEP 585 (`list[str]`) is fine, it landed in 3.9.

KILL CRITERION (slug `seat-liveness-nag`, retro GATE-AUDIT): four weeks with zero hits ⇒ delete
it — a reminder that never names a seat is measuring nothing.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
from typing import List, NamedTuple, Optional

_RUN_DEFAULT = "/tmp/agent-watch-run"      # duplexctl's own default for --run-dir
_META = ".duplex.meta"
_SEAT_CAP = 20                             # OWNED seats consulted per census, alphabetical
_CALL_TIMEOUT = 5.0                        # per `agentctl status` / `git rev-parse`
_CENSUS_BUDGET = 20.0                      # ownership probe + every status, so a Stop hook can
                                           # never hang a turn end. The deadline is taken BEFORE
                                           # the git call, which is inside it, not beside it.
_NAG_DEFAULT = 600

# The reminder text, as a module literal spent AT the sink below. Not a style choice: the
# injected-text ratchet (test/context-budget.test.sh) weighs literals at the sink and resolves
# one local per name, so text routed through a helper's return value would be spent unweighed.
_NAG = ("RUNNING seats without a live watcher: %s%s%s — arm `agentctl watch <S>` in the host's "
        "background (never a foreground Bash) or `agentctl stop <S>`. An unwatched RUNNING seat "
        "is idle time until a human asks (2026-09-02: 44 minutes).")


class Census(NamedTuple):
    """seats: owned sessions that are RUNNING with no live watcher.
    overflow: OWNED metas past `_SEAT_CAP` that were never consulted.
    unowned: True = the ownership question went unanswered, so `seats` is unfiltered.
    blind: None = the census answered; otherwise why it could not, in one clause."""
    seats: List[str]
    overflow: int
    unowned: bool
    blind: Optional[str]


def run_dir() -> str:
    return os.environ.get("AGENT_WATCH_DIR") or _RUN_DEFAULT


def _meta_cwd(path: str) -> Optional[str]:
    """The seat's `cwd=`, or None when the meta cannot be read or carries none. Same `key=value`
    format identity.py:_meta_read consumes; first occurrence wins, exactly as it does there."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key.strip() == "cwd":
                    return value.strip() or None
    except (OSError, UnicodeDecodeError):
        return None
    return None


def _git_top(path: str, timeout: float) -> Optional[str]:
    """realpath of the work tree enclosing `path`, or None when nobody can attribute it to a
    repo (no git, no such directory, not a work tree, or the probe outran the census budget it
    SHARES with every status call). None is the undecidable answer, never a softer 'no': the
    caller reports it instead of quietly filtering on a root it never had."""
    try:
        proc = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout)
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    top = proc.stdout.decode("utf-8", "replace").strip()
    if not top:
        return None
    try:
        return os.path.realpath(top)
    except OSError:
        return None


def _under(child: str, parent: str) -> bool:
    """True when `child` IS `parent` or sits inside it — a seat launched deeper in the repo is
    still this repo's seat."""
    try:
        child = os.path.realpath(child)
    except OSError:
        return False
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


def _status(agentctl: str, session: str, run: str, timeout: float) -> Optional[str]:
    """`agentctl status <session>` stdout, or None when the question was never answered (missing
    binary, timeout, spawn failure). None must not be read as 'watched': the caller treats it as
    a blind census and degrades."""
    env = dict(os.environ)
    env["AGENT_WATCH_DIR"] = run
    try:
        proc = subprocess.run([agentctl, "status", session], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout, env=env)
    except Exception:
        return None
    return proc.stdout.decode("utf-8", "replace")


def _unwatched(out: str) -> bool:
    """The predicate, on `status` output alone: the typed verdict line says RUNNING and the
    advisory note says no watcher is armed. Both halves are required — the note without a
    RUNNING first line would be a stale read of some other classification."""
    lines = [ln for ln in out.splitlines() if ln.strip()]
    return bool(lines) and lines[0].startswith("RUNNING") and "no watcher armed" in out


def census(cwd: Optional[str], run: str) -> Census:
    """The shared enumeration. Bounded four ways so a Stop hook can never hang a turn end: at
    most `_SEAT_CAP` OWNED seats, `_CALL_TIMEOUT` per subprocess, `_CENSUS_BUDGET` for the whole
    path — deadline first, ownership probe INSIDE it (R1 M2: taking the deadline after the git
    call made the real worst case 25s while the file advertised 20s) — and the ownership SCAN
    metered per meta (R2 major: the per-entry cost is trivial, the aggregate over a large or slow
    run dir is not). The FIRST status that does not answer ends the census as blind rather than
    reporting a set it knows is short — a partial census would let a real unwatched seat read as
    'nothing to report'.

    OWNERSHIP IS APPLIED BEFORE THE CAP (R1 B3): capping the raw meta list first meant 20
    alphabetically-earlier FOREIGN seats could evict this repo's own unwatched seat to position
    21, and the gate then reported an answered EMPTY census and let the turn end. Foreign metas
    now cost one file read each and nothing else — no status call, no cap slot."""
    agentctl = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agentctl")
    deadline = time.monotonic() + _CENSUS_BUDGET
    try:
        names = sorted(n for n in os.listdir(run) if n.endswith(_META))
    except OSError:
        return Census([], 0, False, f"run dir {run} could not be listed")
    if not names:
        return Census([], 0, False, None)
    if not os.access(agentctl, os.X_OK):
        return Census([], 0, False, f"{agentctl} is not executable")
    owner = _git_top(cwd, min(_CALL_TIMEOUT, max(0.0, deadline - time.monotonic()))) if cwd \
        else None
    mine: List[str] = []
    for name in names:
        # The scan itself is metered (R2 major): one `open` + one `realpath` per meta is cheap
        # per entry and unbounded in the AGGREGATE — a large or slow (network / contended) run
        # dir could walk the whole census past its budget before the first deadline check ever
        # ran, which is precisely the "the gate becomes the thing that stalls a turn end" failure
        # the budget exists to prevent. Stopping here reports a blind census, which is the same
        # fail-open exit every other unanswerable case takes.
        if time.monotonic() >= deadline:
            return Census([], 0, False,
                          f"the seat census ran past its {int(_CENSUS_BUDGET)}s budget during "
                          "the ownership scan")
        if owner is not None:
            # An empty / unreadable `cwd=` is NOT ours: `_under("", owner)` would realpath the
            # empty string to the HOOK PROCESS's own cwd and hand a cwd-less meta ownership
            # whenever the hook runs inside this repo.
            seat_cwd = _meta_cwd(os.path.join(run, name))
            if not seat_cwd or not _under(seat_cwd, owner):
                continue                   # another seat's session: one file read, nothing more
        mine.append(name[: -len(_META)])   # owner unanswered -> unfiltered, and said so below
    overflow = max(0, len(mine) - _SEAT_CAP)
    seats: List[str] = []
    for session in mine[:_SEAT_CAP]:
        left = deadline - time.monotonic()
        if left <= 0:
            return Census([], overflow, False,
                          f"the seat census ran past its {int(_CENSUS_BUDGET)}s budget")
        out = _status(agentctl, session, run, min(_CALL_TIMEOUT, left))
        if out is None:
            return Census([], overflow, False, f"`agentctl status {session}` never answered")
        if _unwatched(out):
            seats.append(session)
    return Census(seats, overflow, owner is None, None)


def _nag_interval() -> int:
    try:
        return int(os.environ.get("SEAT_LIVENESS_NAG_INTERVAL_SECS", str(_NAG_DEFAULT)))
    except ValueError:
        return _NAG_DEFAULT


def _throttled(run: str, cwd: Optional[str], seats: List[str]) -> bool:
    """True = this exact seat set was already reported for this cwd inside the interval. Keyed on
    the SET, so a seat appearing or being armed speaks immediately instead of waiting out the
    window. An unwritable stamp over-reminds and never silences: the stamp is a noise brake, and
    a brake that fails must fail toward saying it."""
    tag = hashlib.sha256(("\n".join(seats) + "\0" + (cwd or "")).encode("utf-8")).hexdigest()[:16]
    stamp = os.path.join(run, "seat-liveness.nag")
    now = time.time()
    try:
        with open(stamp, encoding="utf-8") as fh:
            prev, _, at = fh.read().strip().partition(" ")
        if prev == tag and now - float(at) < _nag_interval():
            return True
    except (OSError, ValueError):
        pass
    try:
        with open(stamp, "w", encoding="utf-8") as fh:
            fh.write(f"{tag} {int(now)}\n")   # FLOOR: `%.0f` rounds, so a stamp could sit up to
            # half a second in the FUTURE and a zero/short interval then read as still-throttled
    except OSError:
        pass
    return False


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    event = data.get("hook_event_name")
    cwd = data.get("cwd")
    run = run_dir()
    seen = census(cwd if isinstance(cwd, str) else None, run)
    if seen.blind or not seen.seats:
        return 0
    # A new / resumed / compacted context has no memory of the previous reminder, so SessionStart
    # is never throttled; mid-session prompts are rate-limited by the SAME-SET stamp (same split
    # queue-freshness.py makes, same reason; owner ruling 2026-09-02 kept it as accept-documented).
    if event != "SessionStart" and _throttled(run, cwd if isinstance(cwd, str) else None,
                                              seen.seats):
        return 0
    cap_nag = (f" (+{seen.overflow} owned seat(s) past the {_SEAT_CAP}-seat census cap were not"
               " checked)" if seen.overflow else "")
    own_nag = (" [UNKNOWN-ownership: this cwd has no decidable git top level, so seats from other"
               " checkouts may be listed]" if seen.unowned else "")
    print(_NAG % (", ".join(seen.seats), cap_nag, own_nag))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)                        # a reminder must never break a prompt
