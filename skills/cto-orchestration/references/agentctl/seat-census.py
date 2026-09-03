"""seat-census — which agentctl seats OF THIS REPO are RUNNING with no live watcher.

A LIBRARY, not a hook entrypoint: `cto-guard-stop.py` imports `census()` from here and is its
only consumer. It stays its own module instead of being inlined into the Stop gate so the FACT
and the VERDICT over it remain separately readable, and so a second consumer never has to
re-implement the fact.

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

BLINDNESS IS REPORTED, NEVER SWALLOWED. When the census cannot answer (unlistable run dir,
missing agentctl, a status that never returned, the budget spent) it returns `Census.blind` with
the reason in one clause and an EMPTY seat list. Deciding what to do with that is the caller's:
the Stop gate turns it into a fail-open WARN, because there silence would read as approval.
Env: AGENT_WATCH_DIR (run dir).

PYTHON FLOOR 3.9, and it is load-bearing: the importer's shebang is `#!/usr/bin/env python3`,
which on a stock macOS host resolves to /usr/bin/python3 3.9.6. PEP 604 (`str | None`) is
evaluated at class/module level and raises TypeError THERE, i.e. this module fails to IMPORT and
the Stop gate degrades to "census module could not be loaded" — a silently disabled gate.
Annotations here use `typing.Optional`; PEP 585 (`list[str]`) is fine, it landed in 3.9.
"""
import os
import subprocess
import time
from typing import List, NamedTuple, Optional

_RUN_DEFAULT = "/tmp/agent-watch-run"      # duplexctl's own default for --run-dir
_META = ".duplex.meta"
_SEAT_CAP = 20                             # OWNED seats consulted per census, alphabetical
_CALL_TIMEOUT = 5.0                        # per `agentctl status` / `git rev-parse`
_CENSUS_BUDGET = 20.0                      # ownership probe + every status, so a Stop hook can
                                           # never hang a turn end. The deadline is taken BEFORE
                                           # the git call, which is inside it, not beside it.


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
