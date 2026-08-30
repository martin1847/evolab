#!/usr/bin/env python3
# cto-guard-edit — PreToolUse·Edit|Write|MultiEdit enforcement for cto-orchestration. ONE rule:
#   (E1) the ORCHESTRATOR writing product code by hand -> DENY (iron law ①, 车道分工, field n=2:
#        two batches where the seat hand-coded the very thing it had just briefed a worker for,
#        and paid for it with the review lane it thereby lost).
# The rule existed only in prose (SKILL.md §0) and prose does not reach the moment a `Write`
# tool call is issued — same conclusion as cto-guard-bash/agent, promoted to a tool-call hook.
#
# WHAT IS JUDGED: the WRITE TARGET, not the caller's location. `file_path` decides the repo face
# (the git work tree enclosing it) and the run-dir census decides who owns that face. Judging the
# caller's `cwd` instead was the R1 shape and it was wrong in both directions (cold review §1.1,
# both counter-probed): a live seat could write an absolute `.py` into ANOTHER checkout and pass,
# while an orchestrator sitting in a git cwd was denied for `/tmp/outside.py`, a path no repo
# governs at all. The predicate now stands on the target's work tree; `cwd` only answers "is the
# caller itself a seat", which decides whether a FOREIGN repo is this gate's business.
#
# HOW A WORKER IS TOLD APART FROM THE ORCHESTRATOR — the whole difficulty of this gate.
# A worker seat's worktree is the `cwd=` line of its `<session>.duplex.meta` in the run dir, and a
# LIVE seat licenses every write inside its own WORK TREE — compared by ROOT, so a seat launched
# in a subdirectory still covers its repo root (R1 denied that legal worker: review §1.4). Reading
# the meta ALONE is wrong: `watchctl.py:_STOP_KEPT` keeps `duplex.meta` after `agentctl stop`, so
# a worktree that finished days ago would hold write rights forever. Liveness must be proved
# separately — the engine's rc file ABSENT (the pane writes it on engine exit; stop keeps it for
# post-mortem) AND the tmux session present. Either half undecidable => treated as LIVE:
# over-allowing costs one un-denied edit, while a wrong DENY brings every edit in the repo down.
# DEGRADE DIRECTION, deliberately ALLOW+WARN (never checker-error): an unlistable run dir, a meta
# that cannot be OPENED (a listable directory is not a readable census — review §1.3), or a target
# no governed work tree owns all mean the question is UNANSWERABLE, and a guard that cannot answer
# must not brick the Edit tool. The WARN says so out loud instead of passing in silence.
# Deny = exit 2 + stderr (shown to the agent). Warn = exit 0 + JSON
# hookSpecificOutput.additionalContext (the only channel that reaches the agent at exit 0).
import sys, json, os, re, subprocess

# The source face, by extension. Docs and data (md/json/yaml/toml/txt/csv/…) are NOT product code
# and never reach the rule: the orchestrator writes goals, records and briefs all day, and a gate
# that argued with that would be off within the hour. `/test/|/tests/` catches only the shape the
# extension list cannot see — an EXTENSION-LESS fixture or runner under a test dir. It is NOT
# OR-ed over the extension test any more: that OR denied `test/fixtures/data.json` and
# `tests/config.yaml`, i.e. exactly the non-source faces the contract puts through (review §1.2,
# counter-probed at rc=2).
_SRC_EXT = {"py", "sh", "bash", "ts", "js", "tsx", "jsx", "go", "rs", "java", "kt", "rb"}
_TEST_DIR = re.compile(r"/tests?/")
_OVERRIDE = "/tmp/cto-allow-direct-write"
_RUN_DEFAULT = "/tmp/agent-watch-run"       # duplexctl's own default for --run-dir

# The three ALLOW+WARN texts, as module-level literals emitted through an INLINE json.dumps at
# each branch. Not a style choice: the injected-text ratchet (test/context-budget.test.sh)
# weighs literals AT the sink and resolves one local per sink, so a message routed through a
# `warn(text)` helper's parameter would be spent entirely unweighed — the exact blind spot that
# gate's header warns about. Keeping the literal at the sink keeps every byte on the meter.
_W_NO_CWD = (
    "WARN (cto-guard E1): this payload carries no `cwd`, so which seat is writing %s could not "
    "be attributed and the 车道分工 rule stayed silent. If you are the orchestrator, dispatch "
    "the edit instead of making it (SKILL.md §0 铁律①)."
)
_W_RUN_DIR = (
    "WARN (cto-guard E1): run dir %s could not be listed, so the LIVE seat set is unknown and "
    "the write to %s was allowed unjudged. 车道分工 (SKILL.md §0 铁律①) still holds: the "
    "orchestrator dispatches product code, it does not type it."
)
_W_TARGET = (
    "WARN (cto-guard E1): write target %s is not inside a git work tree governed by this call's "
    "cwd %s or by any LIVE seat, so 车道分工 (SKILL.md §0 铁律①) had no repo face to judge and "
    "the write was allowed unjudged."
)


def checker_error(message):
    sys.stderr.write(f"CHECKER-ERROR: {message}\n")
    return 2


def _is_source(path):
    norm = path.replace(os.sep, "/")
    ext = norm.rsplit("/", 1)[-1].rsplit(".", 1)
    if len(ext) == 2 and ext[1]:
        return ext[1].lower() in _SRC_EXT
    return bool(_TEST_DIR.search(norm))


def _meta_cwd(path):
    """(cwd, readable) for one duplex.meta. `readable` False = the file could not be OPENED or
    decoded, which is NOT the same as "this seat has no cwd": swallowing it as None dropped a
    live seat from the census and could DENY its own worker (review §1.3). Same `key=value` line
    format identity.py:_meta_read consumes; first occurrence wins, exactly as it does there."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key.strip() == "cwd":
                    return value.strip() or None, True
    except OSError:
        return None, False
    except UnicodeDecodeError:
        return None, False
    return None, True


def _tmux_alive(session):
    """True / False / None(undecidable). None is NOT a softer False: an absent or broken tmux
    means the liveness question was never answered, and the caller reads that as live."""
    try:
        probe = subprocess.run(["tmux", "has-session", "-t", f"={session}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        return None
    return probe.returncode == 0


def live_seat_cwds(run_dir):
    """(cwds, complete). Every LIVE agentctl seat's cwd. `complete` False = the run dir could not
    be listed OR one of its metas could not be read, so the seat set is unknown and the caller
    degrades to ALLOW+WARN rather than judging against a census it knows is short."""
    try:
        entries = os.listdir(run_dir)
    except OSError:
        return set(), False
    out, complete = set(), True
    for name in entries:
        if not name.endswith(".duplex.meta"):
            continue
        session = name[: -len(".duplex.meta")]
        cwd, readable = _meta_cwd(os.path.join(run_dir, name))
        if not readable:
            complete = False
            continue
        if not cwd:
            continue
        # rc file present = the engine already exited (stop keeps BOTH the meta and the rc for
        # post-mortem, which is exactly why the meta alone proves nothing). `os.stat`, not
        # `os.path.exists`: exists() reports a stat ERROR as False, so a permission-denied rc
        # file read as "engine still running" — the opposite of "rc 不可判按 live" (review §1.3).
        try:
            os.stat(os.path.join(run_dir, f"{session}.duplex.rc"))
            continue
        except FileNotFoundError:
            pass                             # absent -> the live half of the predicate holds
        except OSError:
            out.add(cwd)                     # undecidable -> live
            continue
        if _tmux_alive(session) is not False:
            out.add(cwd)                     # alive, or undecidable -> live
    return out, complete


def _under(child, parent):
    """True when `child` IS `parent` or sits inside it. A seat that cd's deeper into its own
    worktree is still that seat — the generous direction, same reason as the liveness default."""
    try:
        child = os.path.realpath(child)
        parent = os.path.realpath(parent)
    except OSError:
        return False
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


def _worktree_root(path):
    """(realpath of the enclosing work tree, decided). `decided` False also covers "git
    unavailable" and "no such directory": all three mean nobody can attribute this path to a
    repo, so the rule has nothing to stand on."""
    try:
        proc = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        return None, False
    if proc.returncode != 0:
        return None, False
    root = proc.stdout.decode("utf-8", "replace").strip()
    if not root:
        return None, False
    try:
        return os.path.realpath(root), True
    except OSError:
        return None, False


def _seat_holds(node, seat, node_root, node_decided):
    """True when `node` belongs to `seat`'s work tree: inside the seat's directory, or — the
    decisive half — the SAME git work tree root. Root equality is what closes review §1.4 (a
    seat launched from a repo subdirectory owns its repo root too); a reversed containment test
    would have done it by handing the seat's PARENT checkout write rights, which is the
    orchestrator's own tree and the direction this gate exists to judge."""
    if _under(node, seat):
        return True
    seat_root, decided = _worktree_root(seat)
    return bool(node_decided and decided and seat_root == node_root)


def _target_dir(path, cwd):
    """The nearest EXISTING directory at or above the write target — the only place a repo
    question can be asked, because the target file (and its parents) may not exist yet."""
    node = path if os.path.isabs(path) else os.path.join(cwd, path)
    node = os.path.dirname(node) or os.sep
    while True:
        if os.path.isdir(node):
            return node
        parent = os.path.dirname(node)
        if parent == node:
            return node
        node = parent


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return checker_error("invalid hook JSON.")
    if not isinstance(data, dict):
        return checker_error("hook payload must be an object.")
    event = data.get("hook_event_name")
    tool = data.get("tool_name")
    if event is not None and not isinstance(event, str):
        return checker_error("hook_event_name must be a string.")
    if tool is not None and not isinstance(tool, str):
        return checker_error("tool_name must be a string.")
    if event != "PreToolUse" or tool not in ("Edit", "Write", "MultiEdit"):
        return 0
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        return checker_error("PreToolUse Edit|Write|MultiEdit requires object tool_input.")
    path = ti.get("file_path")
    if not isinstance(path, str) or not path:
        return checker_error(
            "PreToolUse Edit|Write|MultiEdit requires string tool_input.file_path.")
    if not _is_source(path):
        return 0

    cwd = data.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": _W_NO_CWD % path}}))
        return 0

    run_dir = os.environ.get("AGENT_WATCH_DIR") or _RUN_DEFAULT
    seats, complete = live_seat_cwds(run_dir)
    if not complete:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": _W_RUN_DIR % (run_dir, path)}}))
        return 0
    # THE TARGET decides: which work tree is being written, and does a LIVE seat hold it. One
    # `git rev-parse` for the target, one for the cwd, and one per seat only until a holder is
    # found — paid solely on the source face, where the alternative is a wrong verdict.
    tdir = _target_dir(path, cwd)
    troot, tdecided = _worktree_root(tdir)
    if any(_seat_holds(tdir, seat, troot, tdecided) for seat in seats):
        return 0                             # a live seat writing inside its own worktree
    # Out of the governed face entirely: a target no work tree owns (`/tmp/x.py`) is not the
    # orchestrator typing product code, and R1 denied it (review §1.1). A FOREIGN repo stays in
    # scope only when the caller is itself a live seat — a seat writing source into another
    # checkout is the same disease, and R1 let it through.
    croot, cdecided = _worktree_root(cwd)
    caller_seat = any(_seat_holds(cwd, seat, croot, cdecided) for seat in seats)
    if not (tdecided and (caller_seat or (cdecided and croot == troot))):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": _W_TARGET % (path, cwd)}}))
        return 0

    # The override is the LEGITIMATE direct-write path, not a bypass: SKILL.md §2 licenses the
    # orchestrator to write the shipped face (教义 / 门 / guard) itself, with a minimal contract.
    # Consumption IS the approval (same one-shot shape as cto-guard-bash's markers), so it can
    # never linger as a standing grant; an unremovable object at the marker path denies.
    try:
        os.remove(_OVERRIDE)
        return 0
    except OSError:
        pass
    sys.stderr.write(
        "DENY: 编排位直写源码面 — %s, a work tree no LIVE agentctl seat holds (call cwd %s), so "
        "this is the orchestrator typing product code (铁律① 车道分工, n=2: the seat hand-coded "
        "what it had just briefed and lost the review lane it was paying for). Fix: dispatch it — "
        "`agentctl start <engine> <session> <cwd> --goal <abs>` — and let the worker edit inside "
        "its own worktree; writes into a live seat's work tree pass untouched. Directly writing "
        "the SHIPPED face (教义 / 门 / guard) is a licensed path for ANY verified motive, and "
        "needs only the minimal contract (Done-when + 坏样本来源 + scope): write it, then `touch "
        "%s` (one-shot, consumed on use) and re-run. "
        "Read: cto-orchestration/SKILL.md §0.\n"
        % (path, cwd, _OVERRIDE)
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(checker_error("internal guard failure."))
