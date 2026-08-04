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

Identity triple:
    sessionId            stable across follow-up rounds
    attemptId            new UUID on start and on every state-resetting steer (--replace)
    processIncarnation   "<pid>@<start-time>" of the engine's supervisor pane — NOT the pid
                         alone (recyclable) and NOT the tmux name (reused verbatim)

Transitions and their commit points (the record is written BEFORE the frame goes out; a
failed write FAILS the verb, so no frame ever carries an identity that is not durable):
    start    prompt verb   new sessionId + new attemptId + captured incarnation
    replace  replace verb  same sessionId, new attemptId, re-captured incarnation
    resume   resume verb   same sessionId + attemptId, NEW incarnation (new process)
    queued / --now steer   no write: a non-resetting steer keeps the whole triple

Staleness is DERIVED at read time — stamp vs the active record — and never written back:
the stale evidence stays on disk for post-mortem (single writer of truth). Discrimination is
fail-closed: an exact-string mismatch is typed STALE-ATTEMPT / STALE-INCARNATION, and
anything undecidable (record missing a field, corrupt, incarnation signal unobtainable,
evidence unstamped) is typed IDENTITY-UNKNOWN — never silently adopted, never mapped to OK.

Deliberately NOT here: delivery receipts (workstream 2). WS1 creates no receipt code; WS2
consumes this module's read API (`IdentityStore.load()` / `duplexctl identity show`).
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import json
import os
import re
import stat
import subprocess
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
UNKNOWN = "IDENTITY-UNKNOWN"

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
                                 rec.get("processIncarnation") or "-")

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
    def validate_marker_schema(marker: dict) -> tuple[bool, str]:
        """Schema gate run BEFORE any classification and before ANY record mutation. Evidence
        that fails it is undecidable, not a decision: a marker whose stamp omitted `seq` used
        to classify OK and mutate the ledger with the key 'attempt#None' (cold review R1).
        `rc` gets a strict int test on purpose — in Python `False == 0`."""
        rc = marker.get("rc")
        if isinstance(rc, bool) or not isinstance(rc, int):
            return False, f"marker rc {rc!r} is not an int (a bool is not an exit code)"
        stamp = IdentityStore.marker_stamp(marker)
        if not stamp:
            return False, "marker carries no identity stamp (legacy artifact)"
        for field in ("attemptId", "processIncarnation"):
            value = stamp.get(field)
            if not isinstance(value, str) or not value:
                return False, f"marker stamp {field} is missing or not a non-empty string"
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
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".identity-",
                                       suffix=".tmp")
        except OSError as exc:
            raise IdentityPersistError(f"cannot create identity temp file in {self.dir}: {exc}") from exc
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        except OSError as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise IdentityPersistError(f"cannot persist {path}: {exc}") from exc

    def _atomic_json(self, path: str, payload: dict) -> None:
        self._atomic_text(path, json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")

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

    def publish_terminal(self, armed_token: str, rc: int = 0) -> tuple[str, str]:
        """Publish the terminal marker, stamped with the ACTIVE identity. Returns
        (verdict, detail); the marker is written only on OK.

        The whole decision runs under the shared lock: re-read the record, compare it with
        the caller's arm-time snapshot, bump the publish sequence and write the marker — with
        no window for a concurrent transition to interleave. A watcher armed under attempt A
        therefore cannot publish a conclusion for attempt B, and cannot resurrect A by
        writing back a record it read before the comparison."""
        with self._locked():
            if not os.path.exists(self.meta_path):
                # racing stop already removed the lane: nothing to resurrect
                return OK, "session stopped — no marker published"
            rec, status = self.load()
            if status != STATUS_OK or rec is None:
                return UNKNOWN, (f"active identity record is {status} ({self.path})"
                                 f"{self._why()} — nothing may be published under an "
                                 "unestablished identity")
            current = self._token_of(rec)
            if armed_token != current:
                armed_parts, now_parts = armed_token.split("/"), current.split("/")
                if len(armed_parts) != 3:
                    klass = UNKNOWN     # the arming observer had no establishable identity
                elif armed_parts[1] == now_parts[1]:
                    klass = STALE_INCARNATION
                else:
                    klass = STALE_ATTEMPT
                return klass, ("active identity changed between arming and publish "
                               f"(armed '{armed_token or '-'}' ≠ now '{current}') — "
                               "no terminal conclusion published")
            seq = int(rec.get("publishSeq", 0)) + 1
            rec["publishSeq"] = seq
            self._write(rec)
            marker = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "rc": rc,
                      "deliverable": _meta_read(self.meta_path).get("deliverable", ""),
                      "identity": {"sessionId": rec["sessionId"],
                                   "attemptId": rec["attemptId"],
                                   "processIncarnation": rec.get("processIncarnation"),
                                   "seq": seq}}
            self._atomic_json(self.marker_path, marker)
            return OK, f"terminal marker published ({self.marker_path})"

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
