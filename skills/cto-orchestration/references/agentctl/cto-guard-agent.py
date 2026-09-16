#!/usr/bin/env python3
# cto-guard-agent — non-Bash tool-call enforcement for cto-orchestration. ONE script, three branches,
# routed by (hook_event_name, tool_name). Wire in .claude/settings.json:
#   PreToolUse   matcher "Agent|Task"  -> browser-dispatch MCP guard  (P0a, DENY)
#   PreToolUse   matcher "Agent|Task"  -> explicit model-tier required (P0c, DENY)
#   PreToolUse   matcher "Agent|Task"  -> e2e-runner must be economy tier (P0d, DENY)
#   PreToolUse   matcher "Agent|Task"  -> cwd named by the brief is BEHIND upstream (P0e, WARN)
#   PreToolUse   matcher "TaskStop"    -> kill-a-live-agent guard      (P0b, DENY)
#   PostToolUse  matcher "Agent|Task"  -> black-hole deadline reminder (existing, ALLOW+context)
# Rationale (2026-07-04 audit): the failing rules already existed in prose (frontend-verify.md / memory)
# but didn't fire at dispatch/kill time. Prose that doesn't reach the decision point is net-negative →
# promote to tool-call hooks. Same conclusion applied again 2026-07-10 for P0c (see below).
# Deny/checker error = exit 2 + stderr (shown to agent). Reminder = exit 0 + JSON
# hookSpecificOutput.additionalContext.
# The Agent/Task/TaskStop tools are Claude-Code concepts — harmless no-ops under Codex/omp.
import sys, json, re, os, glob, subprocess, time

BROWSER_RE = re.compile(
    r"playwright|chrome-?devtools|browser|E2E|screenshot|navigate|dev server|"
    r"localhost:[0-9]|vite|npm run dev|pnpm .*dev",
    re.I,
)

# ── (P0e) PreToolUse·Agent|Task: a seat dispatched into a STALE work tree (WARN, never DENY) ──
# GATE-AUDIT slug `stale-scout-cwd`. KILL CRITERION (owner ruling 2026-09-16, the ruling that
# admitted this rule): 30 days with zero hits ⇒ delete. If false WARNs — a DELIBERATE look at an
# old tree — run above 10% of hits, demote it to speaking only on the UNMEASURED line.
# FIELD (downstream seats 2026-09-16, n=1 and it cost the whole batch): a read-only 取证 seat
# inherited the orchestrator's cwd — the main checkout, 74 commits behind upstream — and returned a
# report whose every file:line resolved and which was entirely STALE. Self-consistent ≠ fresh, so
# neither the orchestrator reading it nor a human re-read could catch it; it wrote the wrong
# contract and mis-reported the owner, and the stop came from an implementation seat redding on the
# right base. dispatch-baseline.md:33-35 already says 只读 scout/audit 也算开工 and names the silent
# inheritance of the orchestrator's (usually behind) cwd — prose that never reaches the dispatch
# call, the same failure mode P0a and P0c were promoted out of.
# WARN ONLY, owner ruling: 取证 on an old tree is sometimes DELIBERATE (a pinned base looks exactly
# like this), so what must die is not KNOWING which tree you are on. This rule therefore never
# denies and never moves rc, and it is judged only after the DENY rules above have let the dispatch
# through — a denied dispatch already has the message that matters.
# MEASUREMENT, bounded by construction: ≤4 work trees, 2s per git call, 6s total (monotonic).
#   * candidates = the prompt's ABSOLUTE path tokens that EXIST as a directory (a file token stands
#     for its directory); a token naming nothing is skipped without spending a subprocess, and a
#     RELATIVE token is not a candidate at all — it has no meaning without the very cwd at issue.
#   * each candidate resolves to its work tree in ONE call (`rev-parse --show-toplevel
#     --git-path FETCH_HEAD`): `--git-path` is the ONLY way to reach a LINKED WORKTREE's own
#     FETCH_HEAD, which lives in that worktree's git dir (`<common>/worktrees/<name>/`) and NOT
#     in the common dir — worktree seats are exactly who this rule serves. Reading the common
#     dir instead measured a SIBLING tree's fetch age (codex review 2026-09-16: a 25h-old common
#     file made a freshly-fetched linked tree read UNMEASURED, and a fresh common file hid a
#     linked tree that had never fetched — the silent pass this rule exists to prevent). Both
#     answers come back relative to the `-C` directory, so both are joined back onto it. Not a
#     work tree ⇒ silently skipped.
#   * behind = `rev-list --count HEAD..@{upstream}`, i.e. LOCAL knowledge only. No fetch, no
#     ls-remote: a guard that reached the network at dispatch time would be a new hazard.
# UNMEASURED IS SPOKEN, never a silent pass (the tri-state discipline cto-guard-bash's 14/15/19
# carry): no upstream, git missing, a timeout, the budget, more trees than the cap. behind=0 is
# UNMEASURED too when FETCH_HEAD is absent or older than 24h — a tree that never fetched reports 0
# because it has nothing to compare against, which is the one way this rule could lie "fresh".
# ACCEPT-DOCUMENTED: a path token carrying a space or a non-ASCII byte is not a candidate (this
# reads a prose brief, not argv — no quoting to parse), and `behind` counts commits, not their
# relevance: a tree 200 commits behind on files nobody touched warns just the same.
_P0E_TREE_CAP = 4
_P0E_CALL_S = 2.0
_P0E_BUDGET_S = 6.0
_P0E_FETCH_STALE_S = 24 * 3600
# This rule's own path arm (goal-preflight.py's `_PATH_ARM` also accepts relative forms, which are
# meaningless here). Opens on a separator — `*` included, or a bold `**/abs/path**` loses its whole
# token — and ends on a path byte so trailing prose punctuation is never read as part of the
# directory. `.` is a legal path byte, so a sentence-final one still lands inside the token and is
# stripped below; the rest of _P0E_TRAIL cannot reach the token through today's closing class and
# is listed so widening that class cannot silently reintroduce the swallow.
_P0E_PATH = re.compile(r"(?:^|[\s\"'`（(\[{=,，:：;；*])(/[A-Za-z0-9_.~@%+/-]*[A-Za-z0-9_.~@%+-])")
_P0E_TRAIL = ".,;:!?)"
_P0E_WARN = (
    "WARN (cto-guard-agent stale-scout-cwd): 派工树 %s 落后 %s %d 个 commit（%s）——旧树取证"
    "自洽但过期，人工复核抓不到；故意看旧树可无视，否则换 fresh worktree 再派。"
)
# Both lines are 判据 + 动作 and nothing else. The 09-16 field narrative that justified the rule
# lives in the comment above, NOT in the injected text: a dispatcher meets this line mid-decision,
# and the story costs bytes at exactly the moment the verdict has to be read. UNMEASURED drops the
# `rev-list` recipe for the same reason — it names the tree, which is what a manual check needs.
_P0E_UNMEASURED = "UNMEASURED (cto-guard-agent stale-scout-cwd): %s — 新鲜度没判，派发照常。"


def _p0e_git(args, deadline):
    """(returncode, stdout) for one bounded `git` call, or (None, why) when it could not run."""
    left = deadline - time.monotonic()
    if left <= 0:
        return None, "guard 的 6s 新鲜度预算用尽"
    try:
        proc = subprocess.run(["git"] + args, capture_output=True, text=True,
                              timeout=min(_P0E_CALL_S, left))
    except subprocess.TimeoutExpired:
        return None, "git 单次调用超过 2s 或剩余预算"
    except OSError:
        return None, "PATH 上没有可执行的 git"
    return proc.returncode, proc.stdout.strip()


def _p0e_tree(path, deadline):
    """(work tree root, path of THIS tree's FETCH_HEAD) for one candidate directory; (None, why)
    when git could not answer at all, and (None, None) when git answered that this is not a work
    tree. `--git-path` is asked for FETCH_HEAD by name because a linked worktree keeps its own."""
    rc, out = _p0e_git(["-C", path, "rev-parse", "--show-toplevel", "--git-path", "FETCH_HEAD"],
                       deadline)
    if rc is None:
        return None, out
    lines = out.splitlines()
    if rc != 0 or len(lines) != 2 or not lines[0]:
        return None, None
    return lines[0], os.path.normpath(os.path.join(path, lines[1]))


def _p0e_fetch(fetch_head):
    """(age of the last fetch in seconds — None when there never was one, a phrase naming it)."""
    try:
        age = time.time() - os.path.getmtime(fetch_head)
    except OSError:
        return None, "从未 fetch 过（无 FETCH_HEAD）"
    # minutes under the hour, days past two: "%.0fh" alone renders a 20-minute-old fetch as
    # "0h 前", which reads like a broken gauge in the one line a dispatcher gets
    return age, "上次 fetch 约 %s 前" % (
        "%.0fm" % (age / 60.0) if age < 3600 else
        "%.0fh" % (age / 3600.0) if age < 48 * 3600 else "%.0fd" % (age / 86400.0))


def _p0e_candidates(prompt):
    """The existing directories this prompt's absolute path tokens name, in order, deduped."""
    out = []
    for m in _P0E_PATH.finditer(prompt):
        cand = m.group(1).rstrip("/") or "/"
        if not os.path.isdir(cand):
            # prose boundaries, in order: ONE trailing sentence mark (a period is a legal path
            # byte, so `…/b.` arrived as part of the token and fell through to b's PARENT — a
            # measurable tree read as silence), then a file token standing for its directory.
            stripped = cand[:-1] if cand[-1:] in _P0E_TRAIL else ""
            if stripped and os.path.isdir(stripped):
                cand = stripped
            else:
                cand = os.path.dirname(stripped or cand)
                if not os.path.isdir(cand):
                    continue
        if cand not in out:
            out.append(cand)
    return out


def _p0e_freshness(prompt):
    """([(tree, upstream, behind, fetch phrase)] for every tree that is behind, [reasons freshness
    could not be measured]). NEVER raises and never decides anything about rc: an exception here
    would reach the __main__ wrapper and turn a legal dispatch into a CHECKER-ERROR deny."""
    warns, notes = [], []
    try:
        deadline = time.monotonic() + _P0E_BUDGET_S
        trees, over_cap = [], False
        for cand in _p0e_candidates(prompt):
            top, fetch_head = _p0e_tree(cand, deadline)
            if top is None:
                if fetch_head:                    # git itself could not answer -> stop probing
                    notes.append(fetch_head)
                    break
                continue                          # not a work tree: not this rule's face
            if any(top == seen for seen, _ in trees):
                continue
            if len(trees) >= _P0E_TREE_CAP:
                over_cap = True
                break
            trees.append((top, fetch_head))
        for top, fetch_head in trees:
            rc, out = _p0e_git(["-C", top, "rev-parse", "--abbrev-ref", "@{upstream}"], deadline)
            if rc is None:
                notes.append("%s：%s" % (top, out))
                break
            if rc != 0 or not out:
                notes.append("%s 的当前分支没有 upstream，behind 无从比" % top)
                continue
            upstream = out.splitlines()[0]
            rc, count = _p0e_git(["-C", top, "rev-list", "--count", "HEAD..@{upstream}"], deadline)
            if rc is None:
                notes.append("%s：%s" % (top, count))
                break
            if rc != 0 or not count.isdigit():
                notes.append("%s：rev-list 没给出 behind 数" % top)
                continue
            age, phrase = _p0e_fetch(fetch_head)
            if int(count) > 0:
                warns.append((top, upstream, int(count), phrase))
            elif age is None or age > _P0E_FETCH_STALE_S:
                notes.append("%s behind=0 但%s，behind 只反映上次 fetch" % (top, phrase))
        if over_cap:
            notes.append("prompt 名下的 git 工作树多于 %d 棵，只判了前 %d 棵"
                         % (_P0E_TREE_CAP, _P0E_TREE_CAP))
    except Exception:
        notes.append("guard 判新鲜度时自身出错")
    return warns, list(dict.fromkeys(notes))


def checker_error(message):
    sys.stderr.write(f"CHECKER-ERROR: {message}\n")
    return 2


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return checker_error("invalid hook JSON.")
    if not isinstance(data, dict):
        return checker_error("hook payload must be an object.")
    event = data.get("hook_event_name", "")
    tool = data.get("tool_name", "")
    if not isinstance(event, str) or not isinstance(tool, str):
        return checker_error("hook event and tool names must be strings.")
    applicable = (
        event == "PreToolUse" and tool in ("Agent", "Task", "TaskStop", "KillShell")
    ) or (event == "PostToolUse" and tool in ("Agent", "Task"))
    if not applicable:
        return 0
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        if event == "PostToolUse":
            return 0
        return checker_error("guarded tool requires object tool_input.")

    # ── (P0b) PreToolUse·TaskStop: don't kill an agent that is still alive ──────────
    # 2026-07-04: killed a working browser agent twice because I used "no screenshots in the dir I
    # watched" as a stuck-proxy — but its .output was actively GROWING (a11y-driven agents write
    # snapshots, not image files). Liveness = output-file freshness, NOT a specific deliverable
    # artifact. If the target's transcript was written in the last FRESH_S seconds, it's alive → DENY;
    # poke it (SendMessage) first, and override only after confirming it's truly stuck.
    if event == "PreToolUse" and tool in ("TaskStop", "KillShell"):
        FRESH_S = 120
        id_field = "task_id" if tool == "TaskStop" else "shell_id"
        tid = ti.get(id_field)
        if not isinstance(tid, str) or not tid:
            return checker_error(f"PreToolUse {tool} requires string tool_input.{id_field}.")
        if os.path.exists(f"/tmp/cto-allow-kill-{tid}"):
            return 0  # explicit override
        # /tmp works on BOTH platforms (macOS /tmp is a symlink into /private/tmp and
        # glob follows it); the /private prefix alone made this guard silently fail-open
        # on Linux — no transcript ever found => every kill allowed (caught by CI run #1).
        hits = (glob.glob(f"/tmp/claude-*/*/*/tasks/{tid}.output")
                or glob.glob(f"/tmp/claude-*/**/tasks/{tid}.output", recursive=True)
                or glob.glob(f"/private/tmp/claude-*/*/*/tasks/{tid}.output")
                or glob.glob(f"/private/tmp/claude-*/**/tasks/{tid}.output", recursive=True))
        # Agent-type tasks: tasks/<id>.output stays a ~130B stub until completion (live-stat'd
        # mid-run 2026-07-30; external seat n=3 same day), so its mtime == creation and the
        # freshness check FAIL-OPENS after FRESH_S. The live instrument is the subagent
        # transcript (mtime advances every tool turn); TaskStop's task_id IS the agent id.
        # Bash-type tasks (KillShell) do stream into .output — keep both sources, take freshest.
        hits += glob.glob(os.path.expanduser(f"~/.claude/projects/*/*/subagents/agent-{tid}.jsonl"))
        age = min(time.time() - os.path.getmtime(h) for h in hits) if hits else 1e9
        if age < FRESH_S:
            sys.stderr.write(
                f"DENY: TaskStop on '{tid}' — its transcript grew {int(age)}s ago, so it is ALIVE, "
                "not black-holed. Liveness = output-file freshness, NOT presence of a specific "
                "artifact (a11y-driven browser agents write snapshots, not image screenshots — 'zero "
                "screenshots' != stuck; killed real progress twice on 2026-07-04). POKE it first via "
                "SendMessage and read its reply. The override covers ANY verified kill motive — the "
                "agent confirms stuck / BROWSER-UNAVAILABLE, or you hold positive evidence the dispatch "
                "premise is wrong (bad cwd/goal) so its liveness is beside the point: "
                f"`touch /tmp/cto-allow-kill-{tid}` then re-run TaskStop. "
                "Read: cto-orchestration/references/agentctl/README.md (完成通知黑洞).\n"
            )
            return 2
        return 0

    # ── (P0a) PreToolUse·Agent|Task: browser E2E must use Playwright, never chrome-devtools ────────
    # chrome-devtools MCP attaches the user's real Chrome via CDP → multi-agent + user-browser CDP
    # contention → hangs (frontend-verify.md:19-21 / memory frontend-browser-verify:19-23, "bit us
    # twice"). The rule existed in prose; my dispatch prompt loaded `select:mcp__chrome-devtools__…`
    # anyway. Enforce: a browser/E2E dispatch that instructs loading chrome-devtools tools = DENY.
    # Discriminator = the tool token `mcp__chrome-devtools` (loading/using it), NOT the bare word
    # "chrome-devtools" (a correct prompt says "绝不用 chrome-devtools" in prose — must pass).
    if event == "PreToolUse" and tool in ("Agent", "Task"):
        prompt = ti.get("prompt")
        if not isinstance(prompt, str):
            return checker_error(f"PreToolUse {tool} requires string tool_input.prompt.")
        for field in ("model", "subagent_type"):
            if field in ti and not isinstance(ti[field], str):
                return checker_error(f"tool_input.{field} must be a string.")
        if BROWSER_RE.search(prompt) and re.search(r"mcp__chrome-?devtools", prompt, re.I):
            sys.stderr.write(
                "DENY: browser/E2E subagent dispatched to load chrome-devtools MCP (`mcp__chrome-devtools...`) "
                "— it attaches the user's real Chrome via CDP; multi-agent contention hangs (bit us twice). "
                "Fix: drive Playwright's OWN isolated browser instead — default is the browser CLI "
                "(`playwright-cli open <url>`, temp profile); Playwright MCP is the headed/agentic-loop "
                "exception. Rewrite the dispatch accordingly and re-dispatch. (Prose mention like 'never "
                "use chrome-devtools' is fine — this fires only on the mcp__chrome-devtools tool token.) "
                "Read: cto-orchestration/references/frontend-verify.md (Playwright-first).\n"
            )
            return 2

        # ── (P0c) PreToolUse·Agent|Task: dispatch must pin an explicit economic model tier ──────────
        # 2026-07-10: the human caught the orchestrator dispatching subagents without `model` — two
        # workers silently inherited the parent session's premium model (Fable) to run mechanical work.
        # The tiering rule already existed in SKILL.md prose but doesn't fire at dispatch time (same
        # failure mode as the 2026-07-04 audit above: prose that doesn't reach the decision point is
        # net-negative) → promote to hook. Exempt: subagent_type "fork" always inherits the parent
        # model — `model` is ignored for it, so requiring one would be a false demand.
        # The guard intentionally does NOT validate the model value against an allowlist — any explicit
        # non-empty model passes; the harness enforces its own enum, and non-Claude stacks (codex/omp)
        # use different names. The rule is "make the tier choice explicit", not "use these models".
        # ── (P0d) PreToolUse·Agent|Task: an e2e-runner dispatch must ride an economy tier ───────────
        # Owner ruling 2026-07-12: live e2e gates are mechanical supervision — cheap model only.
        # Discriminator = the E2E_ECONOMY=1 marker in the brief (a brief carrying the runner marker
        # IS an e2e-run dispatch by definition — same zero-false-positive trick as P0a's tool token;
        # a premium REVIEW of e2e code doesn't carry the marker and must pass). Premium-name check is
        # deliberately narrow (fable/opus) — cto-guard-bash (6) forces the marker onto every runner.
        if "E2E_ECONOMY=1" in prompt and re.search(r"\b(fable|opus)\b", str(ti.get("model") or ""), re.I):
            sys.stderr.write(
                "DENY: e2e-runner dispatch (brief carries E2E_ECONOMY=1) on a premium model. Running "
                "live e2e gates is mechanical supervision — re-dispatch with an economy tier (e.g. "
                "haiku). Read: cto-orchestration/SKILL.md §0 (不自己跑长 E2E / model 按活分档).\n"
            )
            return 2

        subagent_type = ti.get("subagent_type", "") or ""
        model = str(ti.get("model") or "").strip()
        if subagent_type != "fork" and not model:
            sys.stderr.write(
                "DENY: Agent/Task dispatch missing explicit `model`. Silent inheritance of the parent "
                "session's model burns premium tier on mechanical work (caught 2026-07-10: two workers "
                "defaulted to Fable for scripted probes). Pick a tier and re-dispatch with `model` set:\n"
                "  economy tier (mechanical/light: file moves, running tests, small patches, scripted "
                "probes) -> e.g. haiku/sonnet, gpt-5-mini\n"
                "  reasoning tier (adversarial review, architecture, long-context research) -> "
                "e.g. opus, gpt-5.6\n"
                "  premium/frontier stays allowed, but it must be deliberate, not silent inheritance. "
                "(subagent_type \"fork\" is exempt — it always inherits the parent model.) "
                "Read: cto-orchestration/SKILL.md §0 (model 按活分档).\n"
            )
            return 2

        # ── (P0e) the work tree this brief names is BEHIND its upstream (WARN, never DENY) ──────
        # Judged LAST, i.e. only on a dispatch the DENY rules above already allowed, and it cannot
        # change the verdict: rc stays 0 and the only channel used is additionalContext. CHANNEL,
        # not a style choice (codex review 2026-09-16): on exit 0 stderr is the host's DEBUG log
        # and the dispatching agent never sees it, so a WARN written there is a gauge that reads
        # green while saying nothing — exactly the false-green this rule exists to kill. Same
        # channel as cto-guard-bash's (3)/(13)/(14)/(15)/(19)/(20) notes, one JSON document only.
        # Design, bounds and the kill criterion sit with the constants at the top of this file.
        warns, notes = _p0e_freshness(prompt)
        if warns or notes:
            # both comprehensions stay INSIDE this call: the injected-text ratchet resolves
            # literals that appear at the sink expression, and a list assembled one statement
            # earlier would weigh as zero bytes — a page of injected text nobody meters.
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": "\n".join(
                    [_P0E_WARN % w for w in warns] + [_P0E_UNMEASURED % why for why in notes]),
            }}))
        return 0

    # ── (existing) PostToolUse·Agent|Task: black-hole deadline reminder ────────────────────────────
    if event == "PostToolUse" and tool in ("Agent", "Task"):
        try:
            prompt = ti.get("prompt", "")
            if not isinstance(prompt, str):
                return 0
            if not BROWSER_RE.search(prompt):
                return 0
            # instrument correction (external-seat report 2026-07-29, 3 false-STALLED in one day):
            # the task .output file is agent-type-dependent — for many agents it stays a stub until
            # completion, so "output-file growth" as positive evidence manufactures false STALLED.
            msg = (
                "[browser/long subagent launched] Its completion notification can BLACK-HOLE (a live Playwright "
                "session / dev server / bg fork keeps it from firing — you'll blind-wait forever). DO NOW, don't "
                "rely on the auto-notify: set a deadline-bounded background watch on POSITIVE evidence — milestone "
                "SendMessage from the agent (NOT .output growth: for many agent types it stays a stub until "
                "completion, 3 false-STALLED field hits; NOT screenshot-count, a11y agents write no images); if it "
                "goes quiet past the deadline, SendMessage to poke it, then kill+relaunch rather than wait. "
                "(cto S1.4/S7.)"
            )
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
        except Exception:
            return 0
        return 0

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(checker_error("internal guard failure."))
