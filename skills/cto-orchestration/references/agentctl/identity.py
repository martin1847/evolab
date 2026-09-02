#!/usr/bin/env python3
"""identity.py — attempt identity + stale-attempt fencing for the agentctl duplex lane.

WHY: every runtime artifact of this lane used to be keyed by the session NAME alone, so a
restarted session inherited every stale artifact of its predecessor by name collision — a
DONE marker or a BLOCKED record from a dead attempt could open the current deliverable gate
or park the current attempt in WAITING-INPUT. Names are not identities.

THE ONE STATE ABSTRACTION. All identity reads and writes go through IdentityStore; no other
module opens these files. Layout (one record, per session, inside the session state dir):

    <run>/<name>.identity.d/active.json   the ACTIVE identity record (single writer of truth)
    <run>/<name>.identity.d/lock          flock for read-modify-write of that record
    <run>/<name>.identity.d/blocked-stamp.txt  stamp line the worker copies into BLOCKED.md

The PHASE LEDGER (bottom of this file) is the one artifact here that is not identity state,
and it lives here because its aggregation key IS the identity triple:

    <run>/phase-ledger-YYYYMMDD.jsonl     append-only commit-point log, never cleaned by stop

Identity triple:
    sessionId            stable across follow-up rounds
    attemptId            new UUID on start and on every state-resetting steer (--interrupt)
    processIncarnation   "<pid>@<start-time>" of the engine's supervisor pane — NOT the pid
                         alone (recyclable) and NOT the tmux name (reused verbatim)

Transitions and their commit points (the record is written BEFORE the frame goes out; a
failed write FAILS the verb, so no frame ever carries an identity that is not durable):
    start    prompt verb   new sessionId + new attemptId + captured incarnation
    replace  interrupt verb  same sessionId, new attemptId, re-captured incarnation
    resume   resume verb     same sessionId + attemptId, NEW incarnation (new process)
    plain steer (any route)  no write: a non-resetting steer keeps the whole triple

Staleness is DERIVED at read time — stamp vs the active record — and never written back:
the stale evidence stays on disk for post-mortem (single writer of truth). Discrimination is
fail-closed: an exact-string mismatch is typed STALE-ATTEMPT / STALE-INCARNATION, and
anything undecidable (record missing a field, corrupt, incarnation signal unobtainable,
evidence unstamped) is typed IDENTITY-UNKNOWN — never silently adopted, never mapped to OK.

THE DELIVERY RECEIPT (workstream 2) IS THIS SAME RECORD, not a second one. When the runtime
concludes the engine is terminal, publish_terminal writes ONE record at marker_path carrying
both the WS1 fence stamp and the receipt fields (schemaVersion / sessionId / attemptId /
processIncarnation / phase / engineOutcome / deliverables[path,sha256,size] / gitHead /
completedAt / reason). `phase="delivered"` means ONLY that the runtime was terminal and the
declared artifact evidence was observed and hashed — never reviewed, verified, merged or
deployed. Every non-delivered or refused outcome carries a STRUCTURAL `reason` from the closed
enum below (never a prose string), in the record and in the status/watch machine line.
"""
from __future__ import annotations

import contextlib
import datetime
import errno
import fcntl
import glob as globmod
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA_VERSION = 1
# "no event applied yet" for the per-attempt watermark. Distinguishable from every
# acceptable seq because a valid seq is a NON-NEGATIVE int (cold review R2).
WATERMARK_UNSET = -1

# record availability
STATUS_ABSENT = "absent"
STATUS_OK = "ok"
STATUS_CORRUPT = "corrupt"

# typed discrimination classes (new MESSAGE lines; they ride the existing exit vocabulary)
OK = "OK"
STALE_ATTEMPT = "STALE-ATTEMPT"
STALE_INCARNATION = "STALE-INCARNATION"
STALE_ROUND = "STALE-ROUND"
UNKNOWN = "IDENTITY-UNKNOWN"

# ── terminal classes (supervised watch) ──────────────────────────────────────────────
# The class of a terminal conclusion is a pure FUNCTION OF THE EXIT CODE, never parsed out of
# the human line: prose is diagnostics, the exit code is the contract. A record whose `class`
# and `rc` disagree with this map is undecidable evidence and is refused at the read boundary.
# `10 RUNNING` is deliberately absent — it is not a terminal state and can never be published.
TERMINAL_CLASSES = {0: "DONE", 2: "FAILED", 4: "WAITING-INPUT", 5: "STALLED-EXTERNAL",
                    6: "IDLE-NO-DELIVERABLE", 7: "WATCH-TIMEOUT", 8: "ENGINE-SILENT",
                    11: "STALLED-STREAM", 14: "STALLED-PROGRESS", 19: "OVER-BUDGET"}
# how much of classify's human line the record carries — bounded, diagnostics only
DETAIL_MAX = 600
# The bound is enforced LINE-WISE on the WHOLE field, never mid-line. classify's stdout is one
# typed verdict line plus optional machine-readable advisory lines (the misplaced-deliverable
# hint publishes a json.dumps'd path), and a char-level cut handed watch readers half a JSON
# string — parseable prose became unparseable evidence at exactly the moment a reader needed
# the path (impl review R1 B1). Clipping the classify part alone then appending the receipt
# display line was just as false: the field, and therefore `watch`'s replay of it, still ran
# past 600 and the marker was no longer last (impl review R2). So the clip is applied ONCE, to
# the concatenation, and lines are dropped from the TAIL: the receipt display line goes before
# any hint line does, because it is a redundant rendering of structural fields (`reason`,
# `phase`, `deliverables` — the receipt readers use those, never this text) while the hint is
# the payload an operator actually needs.
DETAIL_TRUNC_MARK = "…[detail truncated; run agentctl status <session> for full lines]"


def clip_detail(detail: str | None) -> str:
    """`detail` bounded to DETAIL_MAX characters without ever cutting inside a line.

    Under the limit the text is published verbatim (no marker, no rewriting). Over it, whole
    lines are kept from the top while they fit beside the marker, the tail is dropped, and the
    marker is the LAST line. Only ONE line can still be char-cut: a first line that alone
    overruns the budget — that is the typed verdict prose (advisory lines always follow it), so
    no json.dumps payload can ever be split."""
    text = detail or ""
    if len(text) <= DETAIL_MAX:
        return text
    if len(DETAIL_TRUNC_MARK) + 1 >= DETAIL_MAX:
        return DETAIL_TRUNC_MARK[:DETAIL_MAX]
    budget = DETAIL_MAX - len(DETAIL_TRUNC_MARK) - 1        # -1 = the marker's own newline
    kept: list[str] = []
    used = 0
    for line in text.split("\n"):
        need = len(line) + (1 if kept else 0)
        if used + need > budget:
            break
        kept.append(line)
        used += need
    if not kept:
        kept = [text.split("\n", 1)[0][:budget]]
    return "\n".join(kept + [DETAIL_TRUNC_MARK])


# STRUCTURAL signal, written by publish: the stored detail was clipped past its own receipt
# display line. Readers must never sniff the text for that (a truncated record is exactly the
# case where text sniffing is least trustworthy), and a replay must not be the ONE surface with
# no receipt information at all — so `terminal_verdict` rebuilds the summary from the record's
# own fields when this flag is true (impl review R3: the R3 ruling assumed watch generated that
# summary separately; it does not — the replay path only ever printed `detail`).
# Absent or false — which is every record written before this field existed — means NO rebuild,
# so a legacy record replays byte for byte as it always did.
RECEIPT_LINE_DROPPED = "receiptLineDropped"
# Prefix of the rebuilt line. Deliberately NOT a typed class word: no reader that scans for
# DONE:/FAILED:/IDLE-NO-DELIVERABLE: can mistake it for a verdict, and everything after it is
# formatted from structural fields — no detail text is re-emitted, so there is no injection
# surface either.
RECEIPT_REBUILT_PREFIX = "receipt (rebuilt from record fields): "

# Printed beside a delivered conclusion, NEVER stored in the record: a terminal record must make
# no claim about verification, and a substring reader cannot tell a negated claim from a claim.
DELIVERED_CAVEAT = (" (delivered ≠ verified: runtime terminal + hashed artifact evidence only)")

# ── receipt vocabulary (workstream 2) ────────────────────────────────────────────────
# The STRUCTURAL reason channel. Every non-delivered / refused outcome carries exactly one of
# these, in the record AND in the status/watch machine line; callers and tests assert on the
# enum, never on the accompanying human text. Adding an outcome means adding a value HERE —
# a new prose string is not a reason.
NO_DELIVERABLE_DECLARED = "NO_DELIVERABLE_DECLARED"
MISSING = "MISSING"
UNREADABLE = "UNREADABLE"
SYMLINK = "SYMLINK"
DIRECTORY = "DIRECTORY"
GLOB = "GLOB"
OVERSIZED_HASH_SKIPPED = "OVERSIZED_HASH_SKIPPED"
IDENTITY_UNKNOWN = "IDENTITY_UNKNOWN"
PUBLISH_INTERRUPTED = "PUBLISH_INTERRUPTED"
# the WS1 stale classes ride the same channel: a record fenced out by identity is a
# non-delivered outcome too, and its reason is the class that refused it
REASONS = frozenset({OK, NO_DELIVERABLE_DECLARED, MISSING, UNREADABLE, SYMLINK, DIRECTORY,
                     GLOB, OVERSIZED_HASH_SKIPPED, IDENTITY_UNKNOWN, PUBLISH_INTERRUPTED,
                     STALE_ATTEMPT, STALE_INCARNATION, STALE_ROUND})
# the ONLY two reasons that still deliver: full evidence, or a bounded-cost honest label
DELIVERING_REASONS = frozenset({OK, OVERSIZED_HASH_SKIPPED})

PHASE_DELIVERED = "delivered"
ENGINE_COMPLETED = "completed"
# > 64 MiB is hashed as `sha256:"oversized"` with the REAL size: bounded cost, honest label.
# The one bounded case that still delivers — a silent skip would claim a hash it never took.
HASH_MAX_BYTES = 64 * 1024 * 1024
HASH_SKIPPED = "oversized"
GLOB_META = "*?["

# receipt-schema verdicts at the READ boundary (cold review R1: a record whose nested WS1 stamp
# matched the active attempt used to be adopted as delivered no matter what its receipt body
# said — a forged `sha256:"oversized"` on a 5-byte file, an invented gitHead and an arbitrary
# completedAt opened the DONE gate the real deliverable predicate had just refused).
RECEIPT_LEGACY = "legacy"     # no delivery claim at all: a WS1 marker, adoptable AS a marker
RECEIPT_INVALID = "invalid"   # claims delivery but does not validate ⇒ never delivered
RECEIPT_OK = "ok"

# `\Z` + fullmatch, never `$`: Python's `$` matches immediately BEFORE a trailing newline, so
# `[0-9a-f]{64}$` accepted a 65-character digest ending in "\n" and the reader delivered it
# (cold review R3). Evidence values are matched in FULL or not at all.
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
# BOTH git object-id widths: 40 hex (sha1) and 64 hex (sha256, `git init --object-format=sha256`).
# The contract asks for the worktree HEAD, not for a sha1 — accepting only 40 made the REAL
# publisher write a receipt its own reader then refused in a sha256 repository (cold review R2).
GITHEAD_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
# RFC3339 spelling: `t`/`z` may be lower case, seconds may be `60` (leap second), and an
# offset is mandatory. Shape only — the semantics are checked by parsing (see _rfc3339).
RFC3339_RE = re.compile(r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})\Z")

# The ONLY prefixes the symlink walk may exempt for an absolute declaration: OS-level aliases
# that are symlinks by the platform's own design (darwin's `/var`, `/tmp`, `/etc` → `/private/*`).
# Top-level and fixed on purpose — a USER path component is never exempt, at any depth, and a
# platform without these aliases exempts nothing (cold review R2: the first symlink found in the
# cwd used to be exempted, which let a user's `alias -> real` hide foreign content).
PLATFORM_ALIASES = ("/var", "/tmp", "/etc")

# Directory-traversal open flag, in order of preference: POSIX `O_SEARCH` (darwin), Linux's
# `O_PATH`, then plain `O_RDONLY`. Only the last one demands READ permission on the ancestors,
# which pathname resolution never required (cold review R2).
_SEARCH_FLAG = getattr(os, "O_SEARCH", None) or getattr(os, "O_PATH", None) or os.O_RDONLY

# TEST-ONLY deterministic publish seam. When AGENTCTL_PUBLISH_BARRIER names a path, the
# terminal-record writer touches that file after the temp file is written+fsynced and
# IMMEDIATELY SIGKILLs itself, before os.replace. That makes the interruption window a
# fact (the barrier file proves it was reached) instead of a timing race. Production never
# sets it; the seam is one env read on a path that already holds the lock.
BARRIER_ENV = "AGENTCTL_PUBLISH_BARRIER"

# The worker copies this line verbatim as the last line of BLOCKED.md; a record without it
# falls back to the pre-existing round-epoch mtime fence (documented in the README).
BLOCKED_STAMP_RE = re.compile(
    r"<!--\s*agentctl-identity\s+attempt=(?P<attempt>\S+)\s+"
    r"incarnation=(?P<inc>.*?)\s+seq=(?P<seq>\d+)\s*-->")


class IdentityPersistError(RuntimeError):
    """The atomic write of the active-identity record did not complete. The triggering verb
    must FAIL and must not send its frame: an identity that is not durable cannot fence."""


def _meta_read(path: str) -> dict:
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    key, _, value = line.partition("=")
                    out[key.strip()] = value.rstrip("\n")
    except OSError:
        pass
    return out


def _proc_start_time(pid: str) -> str:
    """Wall-clock start time of `pid`, the half of the incarnation a recycled pid cannot
    forge. Empty string = signal unobtainable (process gone, ps unavailable)."""
    try:
        probe = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return ""
    return probe.stdout.strip() if probe.returncode == 0 else ""


def _incarnation_slot(incarnation, epoch) -> str:
    """The third field of an identity token — and the ONE place that answers "is this the same
    process life?" when the pid signal itself was never obtainable.

    A session whose pane pid could not be read has `processIncarnation = None`. That used to
    collapse to a literal `-` on both sides of every comparison, so two DIFFERENT lives of the
    same attempt (a `resume` between them) produced the SAME token and the older life's DONE was
    adopted after the resume — undecidable evidence read as a match (review F-03). The record
    therefore also carries `incarnationEpoch`: a nonce minted by EVERY transition, which is
    durable, comparable across processes, and changes exactly when the process life does. A
    record from before this field existed has neither signal, so it gets a per-call nonce and
    matches nothing, including itself — undecidable identity fails closed, never equal."""
    if isinstance(incarnation, str) and incarnation:
        return incarnation
    if isinstance(epoch, str) and epoch:
        return f"?{epoch}"                      # no "/" — token arity is load-bearing
    return f"?undecidable-{uuid.uuid4().hex}"


def _read_regular(path: str) -> str:
    """Read a REGULAR file, refusing to follow a symlink at the final component.

    These files are session-private evidence. With a plain open(), a planted
    `<session>.terminal.json -> /elsewhere/external.json` made an EXTERNAL file's stamp
    readable as this session's terminal evidence (cold review R1); O_NOFOLLOW turns that into
    an error instead of an escape. O_NONBLOCK plus the S_ISREG check close the neighbouring
    case: a fifo planted at the same path would otherwise block the reader forever."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, f"{path} is not a regular file")
        chunks = []
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            chunks.append(block)
    finally:
        os.close(fd)
    return b"".join(chunks).decode("utf-8", errors="replace")


def git_head(cwd: str) -> str | None:
    """Worktree HEAD of the repository containing the SESSION's cwd — not the orchestrator's
    (a background `agentctl watch` inherits the dispatcher's cwd, which is a different repo
    entirely). None when there is no repository: provenance is never invented."""
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        probe = subprocess.run(["git", "-C", cwd, "rev-parse", "HEAD"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    head = probe.stdout.strip()
    return head if probe.returncode == 0 and head else None


def _rfc3339(value) -> bool:
    """A real RFC3339 timestamp? Shape by regex, then the WHOLE value is parsed.

    Two earlier versions were wrong in opposite directions and for the same reason — the parts
    after the seconds were treated as decoration rather than data:

    - shape + `strptime` of the first 19 characters never checked the offset at all, so `+99:99`,
      `+24:00` and `+23:60` validated, while lowercase `t`/`z` (lawful RFC3339) was refused
      (cold review R2);
    - rewriting EVERY `:60` to `:59` accepted a leap second at an impossible position, e.g.
      `2026-08-04T14:00:60Z` (cold review R3).

    So: an offset is REQUIRED (RFC3339 has no floating local time), the whole value is parsed,
    and `:60` is accepted ONLY where a leap second can exist — as the 61st second of the LAST
    minute of a UTC day. `datetime` cannot represent that instant, so it is parsed as `:59` at
    the same offset and the position is checked in UTC; that is a spelling concession, not a
    claim about the instant, and it accepts every lawful spelling of it (`23:59:60Z`,
    `18:59:60-05:00`, `00:59:60+01:00`)."""
    if not isinstance(value, str):
        return False
    if not RFC3339_RE.fullmatch(value):
        return False
    leap = value[17:19] == "60"
    text = value[:17] + ("59" if leap else value[17:19]) + value[19:]
    # normalise the two case-insensitive letters for parsers older than 3.11
    text = text[:10] + "T" + text[11:]
    if text[-1] in "Zz":
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return False
    if parsed.tzinfo is None:
        return False
    if leap:
        utc = parsed.astimezone(datetime.timezone.utc)
        return (utc.hour, utc.minute) == (23, 59)
    return True


def _platform_prefix(path: str) -> tuple[str, str] | None:
    """(alias, resolved) for the OS-level path alias `path` starts with, or None.

    This is the ONE exemption the symlink walk grants an absolute declaration: on macOS every
    temp/CI tree hangs under `/var -> private/var`, so refusing that prefix would refuse delivery
    on a whole class of machines.

    It must be the PLATFORM's alias and nothing else. An earlier version returned the first
    symlink found in the literal session cwd, whatever it was: with a user's `alias -> real` the
    walk started BELOW the user link and foreign bytes were hashed with `reason=OK` (cold review
    R2). So candidates come from a fixed, top-level allowlist, each still verified to BE a link at
    runtime — a user component is never exempt at any depth, and a platform without these aliases
    exempts nothing. Creating a new top-level entry needs root, which is the trust argument."""
    literal = os.path.normpath(path)
    for alias in PLATFORM_ALIASES:
        if literal == alias or literal.startswith(alias + os.sep):
            if os.path.islink(alias):
                return alias, os.path.realpath(alias)
    return None


def _anchor_and_parts(cwd: str, declared: str) -> tuple[str, list[str]]:
    """(anchor, components) for the symlink-checked descent. The anchor is a REAL directory
    nobody is allowed to reach through a link; every component below it is walked.

    - RELATIVE declaration → anchor = realpath(session cwd). The cwd is the trust root the
      operator named, and `agentctl start` records it already resolved (`cd "$CWD" && pwd -P`),
      so its literal form carries no links in production anyway.
    - ABSOLUTE declaration → anchor = the platform alias when the declaration starts with one,
      else the filesystem root, and EVERY remaining component is walked. There is deliberately no
      "inside the session cwd" shortcut: matching a prefix by realpath and anchoring at the
      resolved cwd skipped a user's own `alias` for `alias/cwd/report.md`, so bytes behind the
      link were digested and recorded under the resolved name (cold review R3). An absolute path
      is judged as written — the receipt claims that path, so that path is what gets checked.
    """
    if not os.path.isabs(declared):
        return (os.path.realpath(cwd or "."),
                [p for p in os.path.normpath(declared).split(os.sep)
                 if p not in ("", os.curdir)])
    target = os.path.normpath(declared)
    parts = [p for p in target.split(os.sep) if p not in ("", os.curdir)]
    plat = _platform_prefix(target)
    if plat is not None:
        alias_parts = [p for p in plat[0].strip(os.sep).split(os.sep) if p]
        return plat[1], parts[len(alias_parts):]
    return os.sep, parts


def declared_target(cwd: str, declared: str) -> str:
    """The absolute path a declaration denotes — ONE resolver for both sides of the contract:
    the publisher records exactly this path, and the read boundary requires a receipt to claim
    exactly this path. Two independent resolutions would let a receipt name a plausible-looking
    neighbour of the declared artifact and still validate."""
    anchor, parts = _anchor_and_parts(cwd, declared)
    return os.path.join(anchor, *parts) if parts else anchor


def _open_dir(name: str, dir_fd: int | None = None) -> int:
    """Open a DIRECTORY for traversal only. Ordinary pathname resolution needs SEARCH (`x`) on
    the ancestors, not READ (`r`) — opening them `O_RDONLY|O_DIRECTORY` added a permission
    requirement the old predicate never had, so a perfectly readable deliverable under a mode
    0111 directory came back `UNREADABLE (EACCES)` (cold review R2). `O_SEARCH` is exactly this
    (POSIX; present on darwin), `O_PATH` is Linux's equivalent, and where neither exists the
    `O_RDONLY` form remains as the only portable fallback."""
    flags = _SEARCH_FLAG | os.O_DIRECTORY
    if dir_fd is None:
        return os.open(name, flags)
    return os.open(name, flags | os.O_NOFOLLOW, dir_fd=dir_fd)


def _open_evidence(cwd: str, declared: str) -> tuple[int | None, str, str]:
    """Open the declared deliverable by descending ONE component at a time from the anchor,
    each hop `O_NOFOLLOW` and relative to the previous component's fd (openat semantics).
    Returns (fd, reason, detail); fd is None whenever reason refuses.

    Why component-wise instead of "islink() the ancestors, then open":
    - `O_NOFOLLOW` alone guards only the FINAL component, so a symlinked ANCESTOR was followed
      and a foreign tree's bytes were hashed under the declared path (cold review R2);
    - a separate islink() pre-check is a check-then-open TOCTOU — the ancestor can be swapped
      for a link between the check and the open (also flagged in R2). Here the kernel makes the
      decision at the moment of use, per component, so there is no window to swap into.

    Ancestors are opened for SEARCH, never for READ: see `_open_dir`.
    """
    anchor, parts = _anchor_and_parts(cwd, declared)
    path = declared_target(cwd, declared)
    try:
        dfd = _open_dir(anchor)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None, MISSING, f"anchor directory '{anchor}' of '{path}' does not exist"
        return None, UNREADABLE, f"anchor directory '{anchor}' cannot be opened ({exc})"
    if not parts:
        os.close(dfd)
        return None, DIRECTORY, f"declared deliverable '{path}' is a directory"
    try:
        for part in parts[:-1]:
            try:
                nxt = _open_dir(part, dfd)
            except OSError as exc:
                klass = SYMLINK if exc.errno in (errno.ELOOP, errno.EMLINK) else ""
                if exc.errno == errno.ENOTDIR:
                    # macOS reports O_DIRECTORY|O_NOFOLLOW on a symlink as ENOTDIR, which is
                    # also what a regular file in the middle of the path gives. Re-open the SAME
                    # component through the SAME dirfd without O_DIRECTORY to tell them apart:
                    # ELOOP ⇒ it is a link, otherwise it is a non-directory. Both outcomes
                    # REFUSE, so a component swapped between the two calls can only change the
                    # label, never open the gate.
                    try:
                        probe = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                        dir_fd=dfd)
                    except OSError as again:
                        klass = SYMLINK if again.errno in (errno.ELOOP, errno.EMLINK) else ""
                    else:
                        os.close(probe)
                if klass == SYMLINK:
                    return None, SYMLINK, (f"'{path}' is reachable only through the symlinked "
                                           f"component '{part}' — evidence is never hashed "
                                           "through a link, at any depth")
                if exc.errno in (errno.ENOENT, errno.ENOTDIR):
                    return None, MISSING, (f"declared deliverable '{path}' does not exist "
                                           f"(component '{part}': {exc.strerror})")
                return None, UNREADABLE, (f"component '{part}' of '{path}' cannot be traversed "
                                          f"({exc})")
            os.close(dfd)
            dfd = nxt
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        except OSError as exc:
            if exc.errno in (errno.ELOOP, errno.EMLINK):
                return None, SYMLINK, f"declared deliverable '{path}' is a symlink"
            if exc.errno == errno.ENOENT:
                return None, MISSING, f"declared deliverable '{path}' does not exist"
            if exc.errno == errno.EISDIR:
                return None, DIRECTORY, f"declared deliverable '{path}' is a directory"
            return None, UNREADABLE, f"declared deliverable '{path}' cannot be opened ({exc})"
    finally:
        os.close(dfd)
    return fd, OK, path


def deliverable_evidence(cwd: str, declared: str) -> tuple[list[dict], str, str]:
    """Hash the DECLARED deliverable. Returns (deliverables, reason, detail) — the whole
    bounded-evidence table in one function, so no caller has to re-derive it:

        not declared            ([], NO_DELIVERABLE_DECLARED)  never vacuously delivered
        glob metacharacter      ([], GLOB)          a declared deliverable is an explicit path
        symlinked component     ([], SYMLINK)       never hash through a link, at any depth
        absent                  ([], MISSING)
        directory               ([], DIRECTORY)
        unreadable / irregular  ([], UNREADABLE)    EACCES, fifo, device — nothing to hash
        > HASH_MAX_BYTES        ([entry], OVERSIZED_HASH_SKIPPED)  sha256="oversized", real size
        otherwise               ([entry], OK)

    A relative path anchors to the SESSION's cwd (the same rule the deliverable gate learned
    the hard way: a relative pattern resolved in the watcher's cwd was a field false-negative).
    """
    if not declared:
        return [], NO_DELIVERABLE_DECLARED, "no deliverable declared for this session"
    if any(ch in declared for ch in GLOB_META):
        return [], GLOB, (f"declared deliverable '{declared}' contains glob metacharacters — a "
                          "receipt names explicit regular-file paths, so the mtime gate still "
                          "judges this session and no hash evidence is claimed")
    fd, reason, detail = _open_evidence(cwd, declared)
    if fd is None:
        return [], reason, detail
    path = detail
    try:
        info = os.fstat(fd)
        if stat.S_ISDIR(info.st_mode):
            return [], DIRECTORY, f"declared deliverable '{path}' is a directory"
        if not stat.S_ISREG(info.st_mode):
            return [], UNREADABLE, (f"declared deliverable '{path}' is not a regular file "
                                    "(fifo/socket/device) — there are no bytes to hash")
        size = info.st_size
        if size > HASH_MAX_BYTES:
            return ([{"path": path, "sha256": HASH_SKIPPED, "size": size}],
                    OVERSIZED_HASH_SKIPPED,
                    f"'{path}' is {size} bytes (> {HASH_MAX_BYTES}) — size recorded, hash "
                    "explicitly skipped and labelled, never claimed")
        digest = hashlib.sha256()
        read = 0
        while True:
            try:
                block = os.read(fd, 1 << 20)
            except OSError as exc:
                return [], UNREADABLE, f"read of '{path}' failed after {read} bytes ({exc})"
            if not block:
                break
            read += len(block)
            digest.update(block)
        return ([{"path": path, "sha256": digest.hexdigest(), "size": read}], OK,
                f"hashed '{path}' ({read} bytes)")
    finally:
        os.close(fd)


def blocked_stamp(path: str) -> tuple[str, dict]:
    """Identity stamp of a BLOCKED record. Returns (status, stamp) with status in
    absent | unstamped | stamped. Only the tail is read — a blocker is prose, not a log."""
    try:
        with open(path, "rb") as fh:
            fh.seek(max(0, os.path.getsize(path) - 8192))
            blob = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return "absent", {}
    hit = None
    for hit in BLOCKED_STAMP_RE.finditer(blob):
        pass  # last stamp wins: an appended answer round must not resurrect the first
    if hit is None:
        return "unstamped", {}
    return "stamped", {"attemptId": hit.group("attempt"),
                       "processIncarnation": hit.group("inc"),
                       "seq": int(hit.group("seq"))}


class IdentityStore:
    """Every identity file operation of the lane. Construct with the run dir + session name;
    nothing else in the codebase opens these paths."""

    def __init__(self, run_dir: str, name: str):
        self.run_dir = run_dir
        self.name = name
        self.dir = os.path.join(run_dir, f"{name}.identity.d")
        self.path = os.path.join(self.dir, "active.json")
        # ONE stable lock for EVERY mutation of this session's identity — transitions,
        # event application and marker publication alike. It lives in the run dir, NOT in
        # the identity dir, so it survives clear()/re-create cycles and stays the same
        # inode across them (a lock inside the removable dir is not a lock).
        self.lock_path = os.path.join(run_dir, f"{name}.identity.lock")
        self._held = 0
        self.corrupt_reason = ""
        self.stamp_path = os.path.join(self.dir, "blocked-stamp.txt")
        self.meta_path = os.path.join(run_dir, f"{name}.duplex.meta")
        self.marker_path = os.path.join(run_dir, f"{name}.terminal.json")
        # where the terminal record goes once a waiter has REPORTED a non-DONE class: still
        # this round's conclusion (and its forensics), just no longer the thing a fresh
        # `agentctl watch` replays instead of sensing — see terminal_verdict/_delivered_for
        self.consumed_path = os.path.join(run_dir, f"{name}.terminal.consumed.json")

    # ── capture ──────────────────────────────────────────────────────────────────────
    def capture_incarnation(self) -> tuple[str | None, str]:
        """(value, signal) for the engine process, captured AFTER spawn: agentctl records
        pane_pid + pane_lstart in meta the moment the supervisor pane exists, and the pane
        IS the engine's process-group leader. None = signal unobtainable ⇒ every later
        comparison against it is undecidable (IDENTITY-UNKNOWN), never assumed equal."""
        meta = _meta_read(self.meta_path)
        pid = (meta.get("pane_pid") or "").strip()
        if not pid.isdigit():
            return None, "unobtainable: no pane_pid recorded in session meta"
        started = (meta.get("pane_lstart") or "").strip() or _proc_start_time(pid)
        if not started:
            return None, f"unobtainable: no start-time for pid {pid}"
        return f"{pid}@{started}", "pane_pid+start-time"

    # ── read ─────────────────────────────────────────────────────────────────────────
    def _dir_is_link(self) -> bool:
        """A symlinked identity dir is untrusted state, never a location: reading through it
        would import another tree's record, and writing/cleaning through it would reach
        outside the run dir entirely (cold review R1)."""
        return os.path.islink(self.dir)

    def load(self) -> tuple[dict | None, str]:
        """(record, status). The read API workstream 2 consumes. A record that cannot be
        parsed or lacks the identifying fields is CORRUPT, never a usable default; so is one
        reachable only through a symlinked identity dir or a symlinked/irregular file — and so
        is one whose COUNTER STATE is malformed.

        That last rule is load-bearing: a persisted `seqWatermark` of `"broken"` used to pass
        here and then get mapped to -1 inside apply_event, which re-applied an event the
        attempt had already consumed (cold review R2). Sameness state that cannot be read is
        undecidable sameness, so the whole record is undecidable. `stateVersion` and
        `publishSeq` get the same treatment — a malformed value there would otherwise raise
        out of an int() cast with no verdict at all."""
        if self._dir_is_link():
            return self._corrupt(f"identity dir {self.dir} is a symlink")
        try:
            raw = _read_regular(self.path)
        except FileNotFoundError:
            self.corrupt_reason = ""
            return None, STATUS_ABSENT
        except OSError as exc:
            return self._corrupt(f"unreadable or not a regular file ({exc})")
        try:
            rec = json.loads(raw)
        except ValueError as exc:
            return self._corrupt(f"unparseable JSON ({exc})")
        if not isinstance(rec, dict):
            return self._corrupt("record is not a JSON object")
        for field in ("sessionId", "attemptId"):
            if not isinstance(rec.get(field), str) or not rec[field]:
                return self._corrupt(f"{field} is missing or not a non-empty string")
        for field, floor in (("seqWatermark", WATERMARK_UNSET),
                             ("stateVersion", 0), ("publishSeq", 0)):
            value = rec.get(field)
            if isinstance(value, bool) or not isinstance(value, int) or value < floor:
                return self._corrupt(f"malformed {field} {value!r} (need an int >= {floor})")
        self.corrupt_reason = ""
        return rec, STATUS_OK

    def _why(self) -> str:
        """The remembered corruption reason, ready to append to a typed message."""
        return f" — {self.corrupt_reason}" if self.corrupt_reason else ""

    def _corrupt(self, reason: str) -> tuple[None, str]:
        """Remember WHY the record is unusable: "corrupt" alone tells an operator nothing, and
        the reason is what separates a hand-edit from a malformed sameness counter."""
        self.corrupt_reason = reason
        return None, STATUS_CORRUPT

    @staticmethod
    def _token_of(rec: dict) -> str:
        return "{}/{}/{}".format(rec["sessionId"], rec["attemptId"],
                                 _incarnation_slot(rec.get("processIncarnation"),
                                                   rec.get("incarnationEpoch")))

    def token(self) -> str:
        """Opaque snapshot of the ACTIVE record, taken when an observer ARMS. Deliberately
        lock-free: it is a snapshot of an atomically-replaced file, and blocking here would
        put `agentctl status`'s pre-classify read behind a wedged publisher. The authority
        decision does not rest on this value — publish_terminal re-reads the record under the
        shared lock and compares again. An absent or corrupt record yields a nonce that
        matches NOTHING, including itself: there is no such thing as an unfenced publish."""
        rec, status = self.load()
        if status != STATUS_OK or rec is None:
            return f"{status.upper()}/{uuid.uuid4().hex}"
        return self._token_of(rec)

    def read_terminal_marker(self) -> tuple[str, dict]:
        """(status, marker) for the published terminal marker. absent | corrupt | ok. A marker
        that is a symlink (or any non-regular file) is CORRUPT, not evidence: the run dir is
        the session-state boundary, and a link out of it is someone else's file."""
        try:
            raw = _read_regular(self.marker_path)
        except FileNotFoundError:
            return STATUS_ABSENT, {}
        except OSError:
            return STATUS_CORRUPT, {}
        try:
            marker = json.loads(raw)
        except ValueError:
            return STATUS_CORRUPT, {}
        if not isinstance(marker, dict):
            return STATUS_CORRUPT, {}
        return STATUS_OK, marker

    @staticmethod
    def marker_stamp(marker: dict) -> dict:
        stamp = marker.get("identity")
        return stamp if isinstance(stamp, dict) else {}

    @staticmethod
    def marker_token(marker: dict) -> str:
        """The marker's identity triple in the SAME shape `token()` produces for the active
        record — including the epoch an unestablished incarnation falls back to. Comparing
        these two strings is exactly the comparison `publish_terminal` makes before it writes,
        so a reader that uses it accepts precisely what the publisher was allowed to publish:
        same session, same attempt, same process life. A record published before
        `incarnationEpoch` existed, with no pid signal either, is undecidable and gets a nonce
        that matches nothing (`_incarnation_slot`) — the null/null pair is NOT a match.
        (`classify_stamp` answers a DIFFERENT question — may FOREIGN evidence be adopted — and
        rightly refuses an unestablished incarnation there.)"""
        stamp = IdentityStore.marker_stamp(marker)
        return "{}/{}/{}".format(stamp.get("sessionId") or marker.get("sessionId") or "",
                                 stamp.get("attemptId") or "",
                                 _incarnation_slot(stamp.get("processIncarnation"),
                                                   stamp.get("incarnationEpoch")))

    @staticmethod
    def validate_marker_schema(marker: dict, require_incarnation: bool = True) -> tuple[bool, str]:
        """Schema gate run BEFORE any classification and before ANY record mutation. Evidence
        that fails it is undecidable, not a decision: a marker whose stamp omitted `seq` used
        to classify OK and mutate the ledger with the key 'attempt#None' (cold review R1).
        `rc` gets a strict int test on purpose — in Python `False == 0`.

        `require_incarnation=False` is for the ONE caller that fences on `marker_token` instead
        (the supervised waiter): a session whose pane pid was never obtainable has a null
        incarnation in BOTH the active record and everything published under it, and refusing
        the field there would make the publisher write records its own reader always rejects.
        It still demands ONE decidable process-life signal — `processIncarnation` or the
        `incarnationEpoch` every transition mints — because a stamp carrying neither cannot be
        told apart from a stamp of a DIFFERENT life of the same attempt (review F-03)."""
        rc = marker.get("rc")
        if isinstance(rc, bool) or not isinstance(rc, int):
            return False, f"marker rc {rc!r} is not an int (a bool is not an exit code)"
        stamp = IdentityStore.marker_stamp(marker)
        if not stamp:
            return False, "marker carries no identity stamp (legacy artifact)"
        fields = ("attemptId", "processIncarnation") if require_incarnation else ("attemptId",)
        for field in fields:
            value = stamp.get(field)
            if not isinstance(value, str) or not value:
                return False, f"marker stamp {field} is missing or not a non-empty string"
        if not require_incarnation:
            if not isinstance(stamp.get("processIncarnation"), (str, type(None))):
                return False, "marker stamp processIncarnation is neither a string nor null"
            if not (stamp.get("processIncarnation") or stamp.get("incarnationEpoch")):
                return (False, "marker stamp carries neither a process incarnation nor an "
                        "incarnation epoch — which process life published it is undecidable")
        seq = stamp.get("seq")
        if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
            return (False, f"marker stamp seq {seq!r} is missing or not a non-negative int — "
                    "event sameness is undecidable without a structured sequence, and a "
                    "negative one would be indistinguishable from the unset watermark")
        return True, "marker schema ok"

    # ── discrimination ───────────────────────────────────────────────────────────────
    def classify_stamp(self, stamp: dict) -> tuple[str, str]:
        """Fail-closed verdict for ONE piece of stamped evidence against the active record.
        Exact string comparison of structured fields only — never text equality of the whole
        artifact, never timestamps (a fresh mtime proves nothing about authorship)."""
        rec, status = self.load()
        if status != STATUS_OK or rec is None:
            return UNKNOWN, (f"active identity record is {status} ({self.path})"
                             f"{self._why()}")
        if not isinstance(stamp, dict) or not stamp:
            return UNKNOWN, "evidence carries no identity stamp (legacy artifact)"
        got_attempt = stamp.get("attemptId")
        if not isinstance(got_attempt, str) or not got_attempt:
            return UNKNOWN, "evidence stamp has no attemptId field"
        if got_attempt != rec["attemptId"]:
            return (STALE_ATTEMPT,
                    f"evidence attempt {got_attempt} ≠ active attempt {rec['attemptId']}")
        got_inc = stamp.get("processIncarnation")
        active_inc = rec.get("processIncarnation")
        if not isinstance(got_inc, str) or not got_inc:
            return UNKNOWN, "evidence stamp has no processIncarnation field"
        if not isinstance(active_inc, str) or not active_inc:
            return (UNKNOWN,
                    f"active process incarnation unestablished ({rec.get('incarnationSignal')})")
        if got_inc != active_inc:
            return (STALE_INCARNATION,
                    f"evidence incarnation '{got_inc}' ≠ active '{active_inc}'")
        return OK, f"attempt {got_attempt} + incarnation matched the active record"

    def terminal_verdict(self, armed_seq: int = -1) -> tuple[str, int, str]:
        """THE canonical read of the terminal record for a waiter: (state, exit, detail) with
        state in `absent` | `unusable` | `ok`. `ok` is the ONLY state whose exit may be reported
        as this session's business result.

        `armed_seq` is the delivery watermark the reading waiter captured when it ARMED (see
        `delivery_watermark`; -1 = it captured none). It only ever matters for a record that
        has already been DELIVERED — rotated to `<s>.terminal.consumed.json` by the waiter that
        reported it, so the operator's next `agentctl watch` senses again instead of replaying
        a spent WATCH-TIMEOUT. A delivered record is still THIS round's conclusion for every
        waiter that was ALREADY ATTACHED when it was published, and refusing it there is what
        made two waiters on one supervisor disagree — fast waiter FAILED 2, slow waiter
        SUPERVISOR-LOST 12 (review F-02). "Already attached" is decided by the record's
        persisted publish sequence against that watermark, never by comparing timestamps.

        Every non-`ok` outcome is deliberately collapsed into `unusable` with a reason in the
        detail: absent-vs-torn-vs-forged-vs-stale differ in forensics, never in authority. The
        gates, in order — each one has cost a real false conclusion somewhere in this lane:
        non-regular file or unparseable bytes (a symlink out of the run dir is someone else's
        file, a torn read is not a verdict), the WS1 schema gate, class↔exit agreement (prose
        never names the class, so a record whose two authoritative fields disagree is forged or
        corrupt), the attempt+incarnation fence, and the round fence.

        The `ok` detail is the STORED text plus, when the record says its receipt display line
        was clipped away (`RECEIPT_LINE_DROPPED`), one line rebuilt from structural fields. This
        is the only surface that carries the receipt to a replaying waiter: `receipt_note` lives
        on the classify/adopt DONE path and is never reached from here (impl review R3)."""
        status, marker = self.read_terminal_marker()
        if status == STATUS_ABSENT:
            delivered = self._delivered_for(armed_seq)
            if delivered is None:
                return "absent", 0, f"no terminal record at {self.marker_path}"
            status, marker, path = STATUS_OK, delivered, self.consumed_path
        else:
            path = self.marker_path
        if status == STATUS_CORRUPT:
            return ("unusable", 0,
                    f"terminal record {path} is unreadable or unparseable")
        valid, why = self.validate_marker_schema(marker, require_incarnation=False)
        if not valid:
            return "unusable", 0, f"terminal record fails the schema gate — {why}"
        rc = marker["rc"]                       # int-checked by the schema gate above
        klass = marker.get("class")
        if not isinstance(klass, str) or not klass:
            # `class` is a REQUIRED field of this read, not a compatibility option. It used to
            # be reconstructed for a class-less record with rc=0 ("only a legacy DONE may omit
            # it"), which made the one structured field the minimum reader contract asks for
            # optional: any record that lost it — truncated, hand-edited, or written by a
            # publisher that predates the supervised lane — was completed to DONE by the
            # READER (review R2 F-01). A record that cannot state its own class is damaged
            # evidence, and damaged evidence is the four-state machine's ④, never a verdict.
            return ("unusable", 0, "terminal record carries no `class` field — the class is a "
                    "required part of the record schema, never reconstructed by the reader")
        if TERMINAL_CLASSES.get(rc) != klass:
            return ("unusable", 0, f"terminal record class {klass!r} does not match exit {rc} "
                    f"(expected {TERMINAL_CLASSES.get(rc)!r}) — undecidable evidence")
        active = self.token()
        got = self.marker_token(marker)
        if got != active:
            # same comparison publish_terminal makes, so the reader accepts exactly what the
            # writer was permitted to write. A record from another attempt, another process
            # incarnation, or an unestablishable identity (whose token is a nonce) lands here.
            klass_of = (STALE_INCARNATION if got.split("/")[:2] == active.split("/")[:2]
                        else STALE_ATTEMPT)
            return ("unusable", 0, f"{klass_of}: record identity '{got}' ≠ active '{active}'")
        got_round = marker.get("round")
        if got_round is None or not str(got_round).strip():
            # Same rule as `class`, for the same reason. The round stamp is what scopes a
            # conclusion to the episode it describes, so a record without one is not "unfenced
            # but usable", it is unreadable evidence. Normalising a missing round to 0 HERE
            # would hand the next round a conclusion no writer ever fenced; the 0
            # normalisation of a round-less legacy meta belongs at the WRITE, where the value
            # is a fact about this session rather than a guess about someone else's record.
            return ("unusable", 0, "terminal record carries no `round` stamp — the round fence "
                    "is a required part of the record schema, never supplied by the reader")
        now_round = (_meta_read(self.meta_path).get("round") or "0").strip()
        if str(got_round).strip() != now_round:
            return ("unusable", 0, f"{STALE_ROUND}: record concluded round {got_round}, the "
                    f"session is on round {now_round}")
        text = marker.get("detail") or klass
        if marker.get(RECEIPT_LINE_DROPPED) is True:
            # the stored copy lost its receipt display line to the DETAIL_MAX clip. Rebuild it
            # from the record's own structural fields so the replay — the DEFAULT consumer
            # surface — still carries reason/phase/evidence. `is True` on purpose: a legacy
            # record (no such field) and an unpressured one both fall through, so nothing is
            # printed twice and nothing that used to replay changes.
            text += (f"\n{RECEIPT_REBUILT_PREFIX}"
                     f"{self.receipt_line(marker, marker.get('reason') or '-')}")
        if marker.get("phase") == PHASE_DELIVERED:
            # AFTER the rebuild on purpose: the caveat qualifies the evidence claims
            # (deliverable / sha256 / gitHead) that the rebuilt line carries, exactly as it
            # trails the receipt line in `publish_terminal`'s own stdout. Appended to the last
            # line rather than put on one of its own — a reader that greps the record for
            # "verified" must still come up empty, and this text is never stored.
            text += DELIVERED_CAVEAT
        return "ok", rc, text

    def _delivered_for(self, armed_seq: int) -> dict | None:
        """The already-delivered record, IF this reader was attached when it was published.

        Order comes from the PERSISTED publish sequence, never from a clock. Every record
        carries the monotone `identity.seq` that its publish bumped in the active identity
        record, and a waiter captures the watermark it can already see at arm time
        (`delivery_watermark`). "Published after I armed" is therefore `seq > armed_seq`: two
        durable counters on one identity record, immune to a host clock stepping in either
        direction. The rule this replaces compared the rotated file's mtime with the reader's
        arm instant — both wall clock — so a clock that stepped BACK after a conclusion was
        delivered made a freshly armed waiter look like an attached peer and replayed a spent
        business class at it, which is a stronger error than any 12 (review R2 F-03).

        The comparison is only meaningful INSIDE one sequence domain, so the record must be
        from the current attempt before its seq is compared at all (`_seq_domain`) — a record
        minted under a retired attempt is not "an earlier conclusion of this episode", it is
        someone else's counter (review R3 F-01).

        A reader with no watermark (`armed_seq < 0` — a one-shot `duplexctl watch-state`) never
        adopts one: it cannot have been attached to anything."""
        if armed_seq < 0:
            return None
        domain = self._seq_domain()
        if not domain:
            return None
        try:
            marker = json.loads(_read_regular(self.consumed_path))
        except (OSError, ValueError):
            return None
        if not isinstance(marker, dict):
            return None
        if self._marker_seq_domain(marker) != domain:
            return None
        seq = self.marker_stamp(marker).get("seq")
        if isinstance(seq, bool) or not isinstance(seq, int) or seq <= armed_seq:
            return None
        return marker

    def _seq_domain(self) -> str:
        """`session/attempt` — the identity the persisted publish sequence belongs to, or ""
        when there is no usable active record.

        This is deliberately NARROWER than `token()` and deliberately WIDER than the session:
        `publishSeq` is reset to 0 by `start` and `replace` (both mint a new attempt) and
        carried across `resume` (same attempt, new process life), so the attempt is exactly the
        span over which two seq values are comparable."""
        rec, status = self.load()
        if status != STATUS_OK or rec is None:
            return ""
        return "{}/{}".format(rec["sessionId"], rec["attemptId"])

    @staticmethod
    def _marker_seq_domain(marker: dict) -> str:
        stamp = IdentityStore.marker_stamp(marker)
        return "{}/{}".format(stamp.get("sessionId") or marker.get("sessionId") or "",
                              stamp.get("attemptId") or "")

    def delivery_watermark(self) -> int:
        """The highest publish sequence THIS ATTEMPT can ALREADY show, for a waiter to capture
        as it arms. Everything at or below it belongs to an episode that was over before the
        waiter existed; everything above it was published while the waiter was attached.

        Only records stamped with the CURRENT attempt count. The sequence is per-attempt and
        restarts at 0 on every `start`/`replace`, while the records of the previous attempt
        survive the rotation (a failed `steer --replace` commits the new identity and leaves
        the old live/consumed records in place). Taking the max over all of them let a retired
        attempt's `seq=1` arm a waiter at watermark 1, so the NEW attempt's first conclusion —
        also `seq=1` — read as "published before you attached": a peer waiter reported FAILED 2
        and this one fell through to SUPERVISOR-LOST 12 on the same terminal event (review R3
        F-01). The identity fence must cut every cross-attempt inference, and an ordering
        watermark is not an exception to it.

        An unreadable, unstamped or foreign record contributes 0, and that is safe rather than
        lenient: a record whose stamp seq cannot be read also fails the schema gate in
        `terminal_verdict`, so adopting it can only ever yield `unusable`, never a class."""
        domain = self._seq_domain()
        if not domain:
            return 0
        top = 0
        for path in (self.marker_path, self.consumed_path):
            try:
                marker = json.loads(_read_regular(path))
            except (OSError, ValueError):
                continue
            if not isinstance(marker, dict):
                continue
            if self._marker_seq_domain(marker) != domain:
                continue
            seq = self.marker_stamp(marker).get("seq")
            if not isinstance(seq, bool) and isinstance(seq, int) and seq > top:
                top = seq
        return top

    # ── the one lock ─────────────────────────────────────────────────────────────────
    @contextlib.contextmanager
    def _locked(self):
        """Serializes every identity mutation of this session against every other one:
        transitions, event application, marker publication AND cleanup.

        The lock path is STABLE for the life of the run dir — `clear()` deletes the identity
        tree but never this file. Two blockers taught that: publish once compared the armed
        token and then rewrote the record outside any lock (R1), and cleanup once unlinked the
        coordination inode so a paused critical section and a fresh transition ended up on two
        different inodes of "the same" lock (R2). Mutual exclusion is a property of the inode,
        not of the path.

        Re-entrant within one instance (flock is per-fd; a second acquire on a new fd of the
        same file would deadlock against ourselves)."""
        if self._held:
            yield
            return
        try:
            lock = open(self.lock_path, "a", encoding="utf-8")
        except OSError as exc:
            raise IdentityPersistError(
                f"cannot take the identity lock {self.lock_path}: {exc}") from exc
        with lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._held += 1
            try:
                yield
            finally:
                self._held -= 1

    # ── write ────────────────────────────────────────────────────────────────────────
    def _guard_locked(self, what: str) -> None:
        """Every mutation of this session's identity state runs inside the shared critical
        section — no exceptions, no fallbacks. This class of bug has now cost two blockers
        (unlocked publish rewrite, unlocked cleanup fallback), so the invariant is enforced
        structurally rather than trusted: a future path that forgets the lock fails typed here
        instead of silently racing."""
        if not self._held:
            raise IdentityPersistError(
                f"refusing to {what} without the identity lock ({self.lock_path})")

    def _atomic_text(self, path: str, text: str) -> None:
        """mkstemp in the SAME dir + fsync + os.replace. Any failure raises — the caller
        must treat a non-durable identity as a failed verb, not as a best effort. A symlinked
        identity dir is refused outright: makedirs(exist_ok) is happy to accept a link, and
        writing through it would put this session's private state in another tree. Replacing
        a symlinked TARGET is safe by construction — rename swaps the entry, it never writes
        through the link."""
        self._guard_locked(f"write {path}")
        if self._dir_is_link():
            raise IdentityPersistError(
                f"identity dir {self.dir} is a symlink — refusing to write session state "
                "through an untrusted path")
        try:
            os.makedirs(self.dir, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path),
                                       prefix=f".{os.path.basename(path)}-", suffix=".tmp")
        except OSError as exc:
            raise IdentityPersistError(f"cannot create identity temp file in {self.dir}: {exc}") from exc
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
                fh.flush()
                os.fsync(fh.fileno())
            self._barrier(path)
            os.replace(tmp, path)
        except OSError as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise IdentityPersistError(f"cannot persist {path}: {exc}") from exc

    def _atomic_json(self, path: str, payload: dict) -> None:
        self._atomic_text(path, json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")

    def _barrier(self, path: str) -> None:
        """TEST-ONLY seam, between "temp file complete on disk" and os.replace — the exact
        window an interrupted publish has to survive. Fires only for the terminal record and
        only when the env names a barrier file: record that the window was REACHED, then
        SIGKILL ourselves. SIGKILL is uncatchable, so the crash is deterministic rather than a
        timing race, and the surviving state is whatever os.replace had not yet swapped: the
        prior complete record, or none — never partial JSON at `path`."""
        target = os.environ.get(BARRIER_ENV, "")
        if not target or path != self.marker_path:
            return
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(f"reached pid={os.getpid()} path={path}\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.kill(os.getpid(), signal.SIGKILL)

    def _write(self, rec: dict) -> dict:
        rec["writtenAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self._atomic_json(self.path, rec)
        return rec

    def _write_blocked_stamp(self, rec: dict) -> None:
        """The line the worker appends to BLOCKED.md so its blocker is attributable. Best
        effort BY DESIGN: an unstamped blocker degrades to the pre-existing epoch fence,
        while the active record — the thing authority depends on — is already durable. Routed
        through the same atomic writer so it inherits the symlinked-dir refusal."""
        line = "<!-- agentctl-identity attempt={} incarnation={} seq=1 -->\n".format(
            rec["attemptId"], rec.get("processIncarnation") or "UNESTABLISHED")
        try:
            self._atomic_text(self.stamp_path, line)
        except IdentityPersistError:
            pass

    def transition(self, kind: str) -> dict:
        """Commit one identity transition, under the shared lock so it can neither interleave
        with a publication nor be overwritten by one. Raises IdentityPersistError when the
        record could not be made durable — the caller must then NOT send its frame."""
        if kind not in ("start", "replace", "resume"):
            raise ValueError(f"unknown identity transition: {kind}")
        with self._locked():
            prior, status = self.load()
            usable = prior if status == STATUS_OK else None
            incarnation, signal = self.capture_incarnation()
            rec = {"schemaVersion": SCHEMA_VERSION,
                   "transition": kind,
                   "stateVersion": 0,
                   "seqWatermark": WATERMARK_UNSET,
                   "publishSeq": 0}
            if kind == "resume":
                if usable is None:
                    raise IdentityPersistError(
                        f"resume needs an established active identity, record is {status} "
                        f"({self.path}){self._why()}")
                # same attempt, new process: the event watermark stays, or a re-read of an
                # already-applied event would transition twice across the restart
                rec["sessionId"] = usable["sessionId"]
                rec["attemptId"] = usable["attemptId"]
                rec["stateVersion"] = int(usable.get("stateVersion", 0))
                rec["seqWatermark"] = int(usable["seqWatermark"])
                rec["publishSeq"] = int(usable.get("publishSeq", 0))
            else:
                # replace keeps the session across the round; start — and any replace on a
                # session with no usable record — mints a fresh session identity. Overwriting a
                # corrupt record with a NEW attempt is the safe direction: it fences every
                # artifact that came before instead of inheriting ambiguous authority.
                rec["sessionId"] = (usable["sessionId"] if kind == "replace" and usable is not None
                                    else uuid.uuid4().hex)
                rec["attemptId"] = uuid.uuid4().hex
            rec["processIncarnation"] = incarnation
            rec["incarnationSignal"] = signal
            # Minted by EVERY transition, including the ones whose pid signal is unobtainable:
            # this is the only durable evidence that start/replace/resume opened a NEW process
            # life, and without it two null incarnations of the same attempt compare equal
            # (review F-03). It is never inherited — not even by `resume`, which is precisely
            # the transition that must invalidate the previous life's published records.
            rec["incarnationEpoch"] = uuid.uuid4().hex
            self._write(rec)
            self._write_blocked_stamp(rec)
            return rec

    def apply_event(self, attempt_id: str, seq) -> bool:
        """Apply one structured event exactly once, per attempt, FOREVER.

        Sameness is a MONOTONIC HIGH-WATERMARK on the structured int `seq`: only
        `seq > watermark` transitions, so every `seq <= watermark` stays a no-op for the whole
        lifetime of the attempt. The predecessor was a 128-entry ring that truncated on every
        application — an old key was forgotten and became "new" again, so replaying sequence 0
        after 129 events transitioned a second time (cold review R1). A bounded ring cannot
        express "already applied"; a watermark can, in one int.

        True = this call performed the transition; False = the event was already covered.
        The attempt is part of the fence, not part of the key: a watermark belongs to exactly
        one attempt, and every transition mints a new attempt with a fresh one."""
        with self._locked():
            rec, status = self.load()
            if status != STATUS_OK or rec is None:
                raise IdentityPersistError(
                    f"active identity record is {status} ({self.path}){self._why()}")
            if attempt_id != rec["attemptId"]:
                raise IdentityPersistError(
                    f"event attempt {attempt_id} is not the active attempt {rec['attemptId']}")
            if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
                # NON-NEGATIVE is the contract: the fresh-attempt watermark is WATERMARK_UNSET
                # (-1), so a negative seq compared <= it and an unseen event was silently
                # called a duplicate — an outcome the contract does not allow (cold review R2).
                raise IdentityPersistError(
                    f"event seq {seq!r} is not a non-negative int — sameness is undecidable")
            water = rec["seqWatermark"]   # load() guarantees an int >= WATERMARK_UNSET
            if seq <= water:
                return False
            rec["seqWatermark"] = seq
            rec["stateVersion"] = int(rec.get("stateVersion", 0)) + 1
            self._write(rec)
            return True

    def temp_glob(self) -> str:
        """Temp pattern of the terminal record's atomic write. Every atomic write names its temp
        after its TARGET (`.<basename>-*.tmp`), so debris is attributable to one file of one
        session — that is what lets the same lifecycle which clears the record clear its debris,
        instead of a shared `.identity-*` pool nobody can attribute."""
        return os.path.join(self.run_dir, f".{self.name}.terminal.json-*.tmp")

    def publish_debris(self) -> list[str]:
        """Temp files of a terminal-record publish that never reached os.replace. Their
        presence is the only on-disk trace of an interrupted publication (the record itself is
        either the prior complete one or absent — that is the whole point of the rename)."""
        return sorted(globmod.glob(self.temp_glob()))

    def receipt_line(self, marker: dict, reason: str) -> str:
        """The MACHINE line: `reason=<enum>` first, evidence after. Callers and tests parse
        the enum; the human text that follows is never a contract."""
        bits = [f"reason={reason}", f"phase={marker.get('phase') or '-'}"]
        for item in marker.get("deliverables") or []:
            sha = item.get("sha256") or "-"
            short = sha if sha == HASH_SKIPPED else sha[:12]
            bits.append(f"deliverable={os.path.basename(item.get('path') or '-')}"
                        f" sha256={short} size={item.get('size')}")
        if "gitHead" in marker:
            head = marker.get("gitHead")
            bits.append(f"gitHead={head[:12] if isinstance(head, str) else 'null'}")
        return " ".join(bits)

    def receipt_status(self, marker: dict) -> tuple[str, str]:
        """Validate the WS2 RECEIPT BODY of a record. Returns (RECEIPT_LEGACY | RECEIPT_INVALID
        | RECEIPT_OK, detail). Run at the READ boundary, BEFORE any delivered conclusion —
        `validate_marker_schema` (WS1) only ever judged `rc` and the fence stamp, so a record
        whose nested stamp matched the active attempt was adopted as delivered no matter what
        its receipt body said: a forged `sha256:"oversized"` on a 5-byte file with an invented
        gitHead and an arbitrary completedAt opened the DONE gate the real deliverable predicate
        had just refused (cold review R1, reproduced with production `classify`).

        A record that makes NO delivery claim is RECEIPT_LEGACY — a WS1 marker, adoptable as a
        marker on the pre-existing mtime path, never as a receipt. Anything that claims delivery
        and fails any rule below is RECEIPT_INVALID: fail closed, never delivered.

        What this CAN prove: internal consistency, and that the claim is about the deliverable
        THIS session declared, under the identity the fence just matched. What it cannot prove
        is the truthfulness of a self-consistent forgery written by something that already knows
        the active attempt + incarnation — that is the WS1 fence's job and its trust boundary."""
        if marker.get("phase") is None:
            return RECEIPT_LEGACY, "record makes no delivery claim (pre-receipt WS1 marker)"
        if marker.get("phase") != PHASE_DELIVERED:
            return RECEIPT_INVALID, f"unknown phase {marker.get('phase')!r}"
        if marker.get("schemaVersion") != SCHEMA_VERSION:
            return RECEIPT_INVALID, (f"schemaVersion {marker.get('schemaVersion')!r} is not "
                                     f"{SCHEMA_VERSION}")
        rc = marker.get("rc")
        if isinstance(rc, bool) or not isinstance(rc, int) or rc != 0:
            return RECEIPT_INVALID, f"rc {rc!r} is not the int 0 (a bool is not an exit code)"
        if marker.get("engineOutcome") != ENGINE_COMPLETED:
            return RECEIPT_INVALID, (f"engineOutcome {marker.get('engineOutcome')!r} is not "
                                     f"{ENGINE_COMPLETED!r}")
        reason = marker.get("reason")
        if reason not in DELIVERING_REASONS:
            return RECEIPT_INVALID, f"reason {reason!r} does not deliver"
        # the receipt view of the triple must BE the fenced stamp, not merely look like one
        stamp = self.marker_stamp(marker)
        for field in ("sessionId", "attemptId", "processIncarnation"):
            top, inner = marker.get(field), stamp.get(field)
            if not isinstance(top, str) or not top:
                return RECEIPT_INVALID, f"top-level {field} is missing or not a non-empty string"
            if top != inner:
                return RECEIPT_INVALID, (f"top-level {field} {top!r} ≠ the fenced stamp's "
                                         f"{inner!r}")
        # …and the triple must be THIS session's. The WS1 fence pins attemptId + incarnation
        # only, so a self-consistent record naming a foreign sessionId rode this attempt's
        # stamp into `delivered` (Linux CI 2026-08-05; masked on darwin by a path-canonical
        # mismatch that refused every forged record earlier).
        active, state = self.load()
        if state != STATUS_OK or not active:
            return RECEIPT_INVALID, "no active identity record to bind this receipt to"
        if marker.get("sessionId") != active.get("sessionId"):
            return RECEIPT_INVALID, (f"sessionId {marker.get('sessionId')!r} is not the active "
                                     f"session {active.get('sessionId')!r}")
        if not _rfc3339(marker.get("completedAt")):
            return RECEIPT_INVALID, f"completedAt {marker.get('completedAt')!r} is not RFC3339"
        head = marker.get("gitHead")
        if head is not None and not (isinstance(head, str) and GITHEAD_RE.fullmatch(head)):
            return RECEIPT_INVALID, (f"gitHead {head!r} is neither null nor a git object id "
                                     "(40 hex for sha1, 64 for sha256)")
        entries = marker.get("deliverables")
        if not isinstance(entries, list) or not entries:
            return RECEIPT_INVALID, "deliverables is not a non-empty list"
        meta = _meta_read(self.meta_path)
        declared = meta.get("deliverable", "")
        if not declared:
            return RECEIPT_INVALID, ("this session declares no deliverable, so no record of it "
                                     "may claim delivered evidence")
        # The declared-deliverable cross-check is on the entry PATH below. The singular
        # top-level `deliverable` field is a WS1 marker extension, NOT part of the binding
        # receipt schema, so requiring it refused contract-shaped records that carried every
        # declared field and the right path (cold review R2, the erased-benefit direction).
        expected = declared_target(meta.get("cwd", ""), declared)
        for item in entries:
            if not isinstance(item, dict):
                return RECEIPT_INVALID, f"deliverable entry {item!r} is not an object"
            path, sha, size = item.get("path"), item.get("sha256"), item.get("size")
            if not isinstance(path, str) or not path:
                return RECEIPT_INVALID, "a deliverable entry has no path"
            if path != expected:
                return RECEIPT_INVALID, (f"recorded path {path!r} is not the declared "
                                         f"deliverable {expected!r}")
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                return RECEIPT_INVALID, f"size {size!r} is not a non-negative int"
            if sha == HASH_SKIPPED:
                # the ONE case with no digest: the label is only legitimate when the recorded
                # size actually exceeds the bound AND the reason says so
                if reason != OVERSIZED_HASH_SKIPPED or size <= HASH_MAX_BYTES:
                    return RECEIPT_INVALID, (f"sha256 {HASH_SKIPPED!r} claimed with reason "
                                             f"{reason!r} and size {size} — the skip label is "
                                             f"only honest above {HASH_MAX_BYTES} bytes")
            elif not (isinstance(sha, str) and SHA256_RE.fullmatch(sha)):
                return RECEIPT_INVALID, f"sha256 {sha!r} is neither 64-hex nor {HASH_SKIPPED!r}"
            elif reason != OK or size > HASH_MAX_BYTES:
                return RECEIPT_INVALID, (f"a real digest with reason {reason!r} and size {size} "
                                         "is self-contradictory")
        return RECEIPT_OK, f"receipt schema valid ({len(entries)} deliverable(s))"

    def delivered_receipt(self, marker: dict) -> dict | None:
        """The record IF it is a VALID delivered receipt. Identity is judged by the caller (the
        WS1 fence); this adds the receipt-body gate that used to be missing entirely."""
        state, _detail = self.receipt_status(marker)
        return marker if state == RECEIPT_OK else None

    def receipt_view(self) -> dict:
        """The read API for the ONE terminal record, fenced. `delivered` is true only when the
        record is identity-valid for the CURRENT attempt AND claims phase=delivered — staleness
        is judged on the RECORD, never on the bytes at the declared path (a raw artifact on disk
        carries no provenance of its own). `reason` is always from the closed enum: the WS1
        class when identity refuses the record, PUBLISH_INTERRUPTED when there is no record but
        a publish left debris, otherwise the record's own reason."""
        status, marker = self.read_terminal_marker()
        if status == STATUS_ABSENT:
            debris = self.publish_debris()
            return {"status": status, "verdict": "", "delivered": False,
                    "reason": PUBLISH_INTERRUPTED if debris else "",
                    "debris": len(debris),
                    "detail": ("a terminal-record publish did not reach its rename — no record "
                               "was published, and no partial record exists" if debris
                               else f"no terminal record at {self.marker_path}")}
        if status == STATUS_CORRUPT:
            return {"status": status, "verdict": UNKNOWN, "delivered": False,
                    "reason": IDENTITY_UNKNOWN, "debris": len(self.publish_debris()),
                    "detail": f"terminal record at {self.marker_path} is unusable"}
        klass, detail = self.classify_stamp(self.marker_stamp(marker))
        state, why = self.receipt_status(marker)
        reason = marker.get("reason")
        if klass != OK:
            reason = IDENTITY_UNKNOWN if klass == UNKNOWN else klass
        elif state == RECEIPT_LEGACY:
            # a WS1 marker carries no receipt: adoptable as a marker, never delivered, and it
            # must not be labelled broken either
            reason = "" if reason not in REASONS else reason
        elif state == RECEIPT_INVALID:
            reason = IDENTITY_UNKNOWN
            detail = f"receipt schema refused — {why}"
        view = {"status": status, "verdict": klass, "debris": len(self.publish_debris()),
                "delivered": klass == OK and state == RECEIPT_OK,
                "receipt": state, "reason": reason or "", "detail": detail}
        for field in ("phase", "engineOutcome", "deliverables", "gitHead", "completedAt",
                      "schemaVersion", "deliverable"):
            if field in marker:
                view[field] = marker[field]
        return view

    def publish_terminal(self, armed_token: str, round_, rc: int = 0,
                         detail: str = "") -> tuple[str, str]:
        """Publish the ONE terminal record — WS1 fence stamp and WS2 delivery receipt in the
        same file. Returns (verdict, detail); the record is written only on OK, and `detail`
        carries the structural `reason=` machine line.

        The whole decision runs under the shared lock: re-read the record, compare it with
        the caller's arm-time snapshot, gather the deliverable evidence, bump the publish
        sequence and write the record — with no window for a concurrent transition to
        interleave. A watcher armed under attempt A therefore cannot publish a conclusion for
        attempt B, and cannot resurrect A by writing back a record it read before the
        comparison.

        `rc` is the FULL typed exit of the concluding observer, not just DONE: the supervised
        watch lane publishes every terminal class through this one writer, so `class` is
        derived from `rc` via TERMINAL_CLASSES and an rc outside that map is refused rather
        than written. `round_` is the round the caller CONCLUDED (captured before it classified)
        — the round fence: a steer that opened the next round between classify and publish makes
        the conclusion stale, and staleness must be refused at the write, not discovered later.
        It has NO default and the comparison is UNCONDITIONAL. It used to be optional, and an
        optional fence is no fence: `duplexctl identity publish` — the one identity surface for
        callers outside this process — could omit it, and the writer then stamped the record
        with whatever round the meta had reached by publish time, i.e. published a round-1
        conclusion as round 2's DONE (review R2 F-01).

        `phase=delivered` is set ONLY when the engine outcome is rc=0 AND the deliverable gate
        was DECLARED and satisfied by hashed evidence. Every other case publishes the terminal
        record WITHOUT phase — with a typed reason — so no session is ever vacuously
        delivered, and the existing outcome classes are untouched."""
        if rc not in TERMINAL_CLASSES:
            return UNKNOWN, (f"reason={IDENTITY_UNKNOWN} exit {rc!r} is not a terminal class "
                             f"({sorted(TERMINAL_CLASSES)}) — nothing published")
        with self._locked():
            if not os.path.exists(self.meta_path):
                # The lane is gone (a racing stop, or state someone removed), so the current
                # session's identity is no longer establishable and NOTHING may be concluded
                # under it. This used to return class OK with reason=IDENTITY_UNKNOWN: the
                # publisher then exited 0, and `agentctl status/watch` — which convert only a
                # NONZERO publisher exit into refusal — kept the prior DONE verdict alive. That
                # is exactly "a refusal silently becomes OK" (cold review R3). The class is the
                # WS1 unknown class, so duplexctl exits 2 and both callers refuse; the stop race
                # explains the missing meta, it does not make the pre-stop conclusion reportable.
                return UNKNOWN, (f"reason={IDENTITY_UNKNOWN} session meta {self.meta_path} is "
                                 "gone (stopped or cleaned mid-flight) — no terminal record "
                                 "published, no delivery receipt, and no prior conclusion may "
                                 "be reported as this session's result")
            rec, status = self.load()
            if status != STATUS_OK or rec is None:
                return UNKNOWN, (f"reason={IDENTITY_UNKNOWN} active identity record is {status} "
                                 f"({self.path}){self._why()} — nothing may be published under "
                                 "an unestablished identity")
            current = self._token_of(rec)
            if armed_token != current:
                armed_parts, now_parts = armed_token.split("/"), current.split("/")
                if len(armed_parts) != 3:
                    klass = UNKNOWN     # the arming observer had no establishable identity
                elif armed_parts[1] == now_parts[1]:
                    klass = STALE_INCARNATION
                else:
                    klass = STALE_ATTEMPT
                return klass, (f"reason={klass} active identity changed between arming and "
                               f"publish (armed '{armed_token or '-'}' ≠ now '{current}') — "
                               "no terminal conclusion published, no delivery receipt")
            meta = _meta_read(self.meta_path)
            now_round = (meta.get("round") or "0").strip()
            if str(round_).strip() != now_round:
                # the conclusion describes a round that is already over: a steer rotated the
                # deliverable epoch and the sent-offset between classify and publish, so the
                # verdict is about frames the NEXT round no longer owns. Refuse at the write —
                # a stale conclusion on disk is a false conclusion for whoever reads it next.
                return STALE_ROUND, (f"reason={STALE_ROUND} conclusion was computed for round "
                                     f"{round_} but the session is on round {now_round} — no "
                                     "terminal conclusion published, no delivery receipt")
            declared, cwd = meta.get("deliverable", ""), meta.get("cwd", "")
            entries, reason, why = deliverable_evidence(cwd, declared)
            delivered = rc == 0 and reason in DELIVERING_REASONS
            seq = int(rec.get("publishSeq", 0)) + 1
            rec["publishSeq"] = seq
            self._write(rec)
            marker = {"schemaVersion": SCHEMA_VERSION,
                      "completedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "rc": rc,
                      # class is derived from rc, never from the human line; round scopes the
                      # conclusion so the next round's reader refuses it without re-deriving
                      "class": TERMINAL_CLASSES[rc],
                      "round": now_round,
                      "detail": detail or "",          # clipped ONCE, below, after the join
                      "deliverable": declared,
                      "reason": reason,
                      # the receipt view of the triple (spec field names) and the WS1 fence
                      # view (`identity`, incl. the publish seq) are the SAME values from the
                      # SAME record read — one authority, two shapes, no divergence possible
                      "sessionId": rec["sessionId"],
                      "attemptId": rec["attemptId"],
                      "processIncarnation": rec.get("processIncarnation"),
                      "identity": {"sessionId": rec["sessionId"],
                                   "attemptId": rec["attemptId"],
                                   "processIncarnation": rec.get("processIncarnation"),
                                   # the process-life fence for records whose pid signal was
                                   # never obtainable — see _incarnation_slot
                                   "incarnationEpoch": rec.get("incarnationEpoch"),
                                   "seq": seq}}
            if delivered:
                marker["phase"] = PHASE_DELIVERED
                marker["engineOutcome"] = ENGINE_COMPLETED
                marker["deliverables"] = entries
                marker["gitHead"] = git_head(cwd)
            published = (f"terminal record published ({self.marker_path}) "
                         f"{self.receipt_line(marker, reason)} — {why}")
            # the record carries the SAME lines the concluding observer would have printed
            # (classify's verdict, then the receipt machine line) — a waiter that recovers this
            # record after the observer is gone reproduces its output, not a summary of it.
            # The delivered caveat is deliberately NOT stored: the record must make no claim
            # about verification, not even a negated one (a reader grepping the record for
            # "verified" must come up empty), so it is re-derived from `phase` when printed.
            # The DETAIL_MAX bound applies to this JOINED text, not to the classify half: the
            # field is what `watch-state` replays, so clipping before the append published a
            # record that broke the documented ≤600 bound and pushed the truncation marker off
            # the tail (impl review R2). `published` is still returned in full below — the
            # caller's own line is never truncated, only the copy stored for replay.
            joined = f"{marker['detail']}\n{published}" if marker["detail"] else published
            marker["detail"] = clip_detail(joined)
            # whether the tail that fell off took the receipt display line with it, decided
            # here where BOTH strings are in hand — the reader then needs no heuristic
            marker[RECEIPT_LINE_DROPPED] = not marker["detail"].endswith(published)
            self._atomic_json(self.marker_path, marker)
            # THE terminal commit point of the phase ledger: the record is durable, so this
            # round really HAS a published conclusion. Every refusal above returned without
            # writing and never reaches this line, which is what makes the ledger's terminal
            # count equal the lane's published-conclusion count instead of its attempt count.
            # The triple comes from `rec` — the record this critical section already read — so
            # nothing here re-enters the lock.
            phase_event(self.run_dir, self.name, "terminal",
                        rec["sessionId"], rec["attemptId"],
                        extra={"round": now_round, "class": marker["class"], "rc": rc})
            return OK, published + (DELIVERED_CAVEAT if delivered else "")

    def clear(self) -> None:
        """Drop this session's identity state so a stopped or freshly claimed name inherits
        nothing — INSIDE the shared critical section, and WITHOUT ever unlinking the lock.

        Two rules, both learned the hard way:
        - A SYMLINKED identity dir is removed as an entry and never traversed: walking it
          deleted files in the pointed-to tree, and agentctl calls this from start and both
          stop branches, so untrusted local state could expand cleanup outside the run dir
          (cold review R1).
        - The lock file is the ONE coordination inode for this session name and cleanup is not
          allowed to delete it. It used to, without even taking it: a process paused inside its
          critical section kept the old inode while the next transition created and locked a
          new one, so a stop + same-name start ran concurrently with a publish and the paused
          publisher wrote its stale record back over the newer attempt (cold review R2). The
          file therefore outlives the session — an empty 0-byte marker in the run dir, in the
          same spirit as the events/stderr/rc artifacts stop already keeps.
        - A lock that cannot be ACQUIRED refuses the whole operation. There used to be a
          fallback here that cleared unlocked "because nobody can be holding a lock whose path
          will not open" — false: a holder keeps its fd while the pathname becomes unopenable
          (mode 000), and the fallback then deleted state under a live critical section, which
          the releasing holder promptly recreated (cold review R3). An unobtainable lock proves
          nothing about holders, so the caller gets a typed failure and the state is untouched.
        """
        with self._locked():
            self._clear_tree()

    def _clear_tree(self) -> None:
        self._guard_locked(f"remove {self.dir}")
        if os.path.islink(self.dir):
            try:
                os.unlink(self.dir)          # the LINK, not what it points at
            except OSError:
                pass
            return
        try:
            for leftover in os.listdir(self.dir):
                try:
                    os.unlink(os.path.join(self.dir, leftover))
                except OSError:
                    pass
            os.rmdir(self.dir)
        except OSError:
            pass


# ── the phase ledger ─────────────────────────────────────────────────────────────────
# WHY: seat wall-clock, the span of a batch, and the gap between one seat reaching a terminal
# state and the next dispatch going out were recoverable only by hand-reading transcripts
# (2026-09-02: the orchestrator computed both numbers for two batches on a calculator, and the
# retro check could only verify that SOMEBODY had typed two numbers). This gives those numbers
# a machine source.
#
# It is a READING, and the whole design follows from that:
#   * it records COMMIT POINTS, never conclusions — nothing here decides whether a span was
#     avoidable, whether a seat was slow, or whether a batch should have been split;
#   * every write is FAIL-OPEN. Each caller sits on a hot control path (identity commit, round
#     commit, terminal publish, teardown) and an instrument that can fail a dispatch is worse
#     than no instrument: an unwritable run dir costs one stderr WARN and nothing else;
#   * `stop` never deletes it. Every other artifact of this lane is session-scoped and dies
#     with the seat, while the ledger's entire point is the batch AFTER the seat is gone. The
#     file name carries NO session prefix, so none of teardown's `<name>.*` sets can reach it
#     (watchctl `_control_state_paths` / `cmd_stop_residue`, and agentctl's start-time `rm -f`).
#
# Shape: one file per UTC day, append-only, one JSON object per line:
#   <run>/phase-ledger-YYYYMMDD.jsonl
# UTC, not local: a shard whose NAME moves with the host timezone cannot be mapped back to an
# instant, and the reader has to enumerate shard names to decide whether a window is covered.
#
# The event set is CLOSED. A sixth event is a schema change for every reader, so it is a
# ValueError here rather than a row nobody aggregates.
PHASE_EVENTS = ("start", "steer", "terminal", "stop", "watch_arm")
PHASE_LEDGER_PREFIX = "phase-ledger-"
PHASE_LEDGER_SUFFIX = ".jsonl"
# one WARN per process: a reading that spams the control plane it observes is not free anymore
_PHASE_WARNED = [False]


def phase_shard_day(when: float) -> str:
    """The UTC day a timestamp is filed under."""
    return time.strftime("%Y%m%d", time.gmtime(when))


def phase_shard_path(run_dir: str, when: float | None = None) -> str:
    day = phase_shard_day(time.time() if when is None else when)
    return os.path.join(run_dir, f"{PHASE_LEDGER_PREFIX}{day}{PHASE_LEDGER_SUFFIX}")


def phase_shards(run_dir: str) -> list[tuple[str, str]]:
    """[(day, path)] for every shard present in the run dir, oldest first. Absence is DATA —
    it is exactly what tells the reader a window is not covered — so nothing here creates a
    shard or infers one."""
    found: list[tuple[str, str]] = []
    pattern = os.path.join(globmod.escape(run_dir),
                           f"{PHASE_LEDGER_PREFIX}????????{PHASE_LEDGER_SUFFIX}")
    for path in globmod.glob(pattern):
        day = os.path.basename(path)[len(PHASE_LEDGER_PREFIX):-len(PHASE_LEDGER_SUFFIX)]
        if day.isdigit():
            found.append((day, path))
    return sorted(found)


def phase_stamp(when: float) -> str:
    """RFC3339 UTC with milliseconds — the ledger's ONE time format, so a reader parses one
    shape or refuses the line."""
    whole = int(when)
    millis = int(round((when - whole) * 1000))
    if millis >= 1000:                      # the rounding carried into the next second
        whole, millis = whole + 1, 0
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole)) + f".{millis:03d}Z"


def _phase_warn(detail: str) -> None:
    if _PHASE_WARNED[0]:
        return
    _PHASE_WARNED[0] = True
    print(f"WARN: phase ledger not recorded — {detail}; this window's readings will be "
          "incomplete (`agentctl phases` reports its own coverage)", file=sys.stderr)


def phase_event(run_dir: str, name: str, event: str, session_id: str, attempt: str,
                extra: dict | None = None, when: float | None = None) -> bool:
    """Append ONE ledger line. True = durable; False = nothing was written (and, for an I/O
    failure, one WARN went to stderr). No caller branches on the rc — it exists for the tests.

    A row with an EMPTY `session_id` is not written at all. `session_id` is the reader's
    aggregation key, so such a row would be counted inside a batch span while belonging to no
    seat; the honest report of a seat nobody can identify is silence plus the coverage field.
    """
    if event not in PHASE_EVENTS:
        raise ValueError(f"phase event {event!r} is outside the closed set {PHASE_EVENTS}")
    if not session_id:
        return False
    stamp = time.time() if when is None else when
    row: dict = {"ts": phase_stamp(stamp), "event": event, "name": name,
                 "session_id": session_id, "attempt": attempt}
    for key, value in (extra or {}).items():
        if value is not None:
            row[key] = value
    # ONE os.write of ONE complete line onto an O_APPEND fd: the offset move and the write are
    # one operation for a regular file, so concurrent seats interleave LINES, never bytes.
    # json.dumps escapes a newline inside any string value, so the record separator holds even
    # for a hostile field.
    line = (json.dumps(row, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        fd = os.open(phase_shard_path(run_dir, stamp),
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    except OSError as exc:
        _phase_warn(f"cannot open the ledger shard in {run_dir} ({exc})")
        return False
    try:
        os.write(fd, line)
    except OSError as exc:
        _phase_warn(f"cannot append to the ledger shard in {run_dir} ({exc})")
        return False
    finally:
        os.close(fd)
    return True


def phase_resolve(run_dir: str, name: str) -> tuple[str, str]:
    """(session_id, attempt) for a session NAME — from the active identity record while one
    exists, and from the ledger's own newest row for that name when it does not.

    The fallback is what makes a `stop` row attributable. Teardown clears the identity record
    BEFORE the process group is reaped, and the reap is the stop commit point, so by then the
    only surviving statement of who this seat was is the ledger. Newest shard first, last
    matching line wins; no shard anywhere means ("", "") and `phase_event` writes nothing."""
    rec, status = IdentityStore(run_dir, name).load()
    if status == STATUS_OK and rec is not None:
        return rec["sessionId"], rec["attemptId"]
    for _day, path in reversed(phase_shards(run_dir)):
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for raw in reversed(lines):
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("name") == name and row.get("session_id"):
                return str(row["session_id"]), str(row.get("attempt") or "")
    return "", ""


def phase_record(run_dir: str, name: str, event: str, extra: dict | None = None) -> bool:
    """`phase_event` for the commit points that do not already hold the identity triple."""
    session_id, attempt = phase_resolve(run_dir, name)
    return phase_event(run_dir, name, event, session_id, attempt, extra=extra)
