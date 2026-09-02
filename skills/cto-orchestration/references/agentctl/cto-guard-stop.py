#!/usr/bin/env python3
"""cto-guard-stop — Stop-event enforcement for cto-orchestration. ONE rule:

  (S1) ending a turn while THIS repo has a RUNNING agentctl seat with no live watcher -> block
       the stop and say so.

Field, 2026-09-02: the orchestrator seat came back from a review round, ran one forensic command
and ended its turn. A seat was RUNNING, its watcher had been TERM'd with the host's task, and no
wakeup was armed — 44 minutes of pure idle until a human asked. Prose cannot reach that moment:
it is the instant the turn ends, and only the Stop event runs there. The prompt-time twin
(`seat-liveness.py`, SessionStart|UserPromptSubmit) covers "after the fact"; this covers "the
moment of".

FAIL-OPEN, ALWAYS. A Stop hook is the only gate whose false positive costs every turn end in the
session, so every unanswerable case (unparseable payload, unlistable run dir, missing agentctl, a
`status` that never returned, any internal failure) exits 0 with a one-line `systemMessage` WARN
and lets the turn end. It never exits 2 — on Stop, exit 2 BLOCKS with stderr as the reason, which
is exactly the verdict a blind gate must not reach. `stop_hook_active` short-circuits first:
Claude Code / codex set it while already continuing because of a stop hook, and blocking there is
how a Stop hook wedges a session (the harness also caps consecutive blocks at 8, which is a fuse,
not a design).

The seat census, the ownership filter and the "no watcher armed" predicate are IMPORTED from
`seat-liveness.py` in this directory, never copied: two channels judging the same fact must not
be able to disagree (same arrangement as cto-guard-bash importing cto-guard-edit's attribution).

Wiring: entry in `guard-hooks.json` (Stop). Same script serves Claude Code and codex — both send
`stop_hook_active` on stdin and both read `{"decision":"block","reason":…}` on stdout; codex needs
the hook trusted once via `/hooks` (README §Wiring).

PYTHON FLOOR 3.9: the shebang is `#!/usr/bin/env python3`, which on a stock macOS host is
/usr/bin/python3 3.9.6, so annotations use `typing.Optional` and never PEP 604 `X | None` — a
module-level `|` raises TypeError at LOAD time, i.e. the gate is silently disabled (R1 B1: the
sibling failed to import and every turn end got the "could not be loaded" WARN instead of a
verdict). `test/cto-guard-stop.test.sh` pins both scripts against /usr/bin/python3 when present.

KILL CRITERION (slug `s1-stop-unwatched-seat`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill —
"false" here is a block raised over a seat that was not this repo's business or was already being
supervised, because a gate that argues with a correct turn end burns one round every time.
"""
import json
import os
import sys
from types import ModuleType
from typing import Optional

_LIVENESS = "seat-liveness.py"

# Both texts are module literals spent AT their sink (inline `json.dumps`), which is what keeps
# them on the injected-text meter (test/context-budget.test.sh weighs literals at the sink and
# resolves one local per name — a message handed through a helper would be spent unweighed).
_BLOCK = (
    "DENY: 结束 turn 时有 RUNNING 席位没人看 — %s%s%s. Why: 没有活 watcher 的 RUNNING 席位在你收工"
    "后无人收割，空转到有人来问（2026-09-02 实证 44 分钟：席位 RUNNING、watcher 随宿主任务被 TERM、"
    "编排位跑完一条取证命令即结束 turn）。正路：`agentctl watch <S>` 交宿主后台跑（前台 Bash 超时会"
    "连 watcher 一起杀）；确实要放着不管就 `agentctl stop <S>`，或显式挂一个 wakeup 再结束。"
    "Read: cto-orchestration/references/agentctl/README.md §强制层\n"
)
_WARN = (
    "WARN (cto-guard S1): %s, so RUNNING-seat liveness went UNJUDGED and this turn was allowed to "
    "end. A gate that cannot answer must not block — but its silence would read as approval, so: "
    "if a seat is still working, arm `agentctl watch <S>` in the host's background yourself."
)


def _liveness() -> Optional[ModuleType]:
    """The seat census from the sibling script, or None when it cannot be loaded at all. A
    missing / unreadable sibling degrades to ALLOW+WARN like every other unanswerable case rather
    than taking every turn end down with it. importlib because the filename is hyphenated;
    `main()` there is under a `__main__` guard, so loading it has no side effects."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), _LIVENESS)
    try:
        spec = importlib.util.spec_from_file_location("seat_liveness", path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception:
        return None
    return mod


def main() -> int:
    """ONE warn sink, on purpose: every unanswerable branch assigns `blind` and falls through to
    the single emit below. Four `print(json.dumps(...))` copies would each be weighed separately
    by the injected-text meter (test/context-budget.test.sh resolves literals AT the sink), so
    the same sentence would be charged four times and the ratchet would stop meaning anything."""
    blind: Optional[str] = None
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = None
    if not isinstance(data, dict):
        blind = "the Stop payload could not be parsed"
    else:
        if data.get("hook_event_name") != "Stop":
            return 0                       # SubagentStop and every other event: not this rule's
        if data.get("stop_hook_active"):
            return 0                       # already continuing from a stop hook: stand down
        mod = _liveness()
        if mod is None:
            blind = f"{_LIVENESS} could not be loaded from this script's own directory"
        else:
            cwd = data.get("cwd")
            seen = mod.census(cwd if isinstance(cwd, str) else None, mod.run_dir())
            blind = seen.blind
            if blind is None:
                if not seen.seats:
                    return 0
                cap_note = (f" (+{seen.overflow} owned seat(s) past the census cap were not "
                            "checked — there may be more) " if seen.overflow else "")
                own_note = (" [UNKNOWN-ownership: this cwd has no decidable git top level, so a "
                            "seat listed here may belong to another checkout] "
                            if seen.unowned else "")
                print(json.dumps({"decision": "block",
                                  "reason": _BLOCK % (", ".join(seen.seats), cap_note, own_note)}))
                return 0
    if blind:
        print(json.dumps({"systemMessage": _WARN % blind}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(json.dumps({"systemMessage": _WARN % f"the stop gate failed internally ({exc!r})"}))
        sys.exit(0)
