#!/usr/bin/env python3
# cto-guard-agent — non-Bash tool-call enforcement for cto-orchestration. ONE script, three branches,
# routed by (hook_event_name, tool_name). Wire in .claude/settings.json:
#   PreToolUse   matcher "Agent|Task"  -> browser-dispatch MCP guard  (P0a, DENY)
#   PreToolUse   matcher "Agent|Task"  -> explicit model-tier required (P0c, DENY)
#   PreToolUse   matcher "TaskStop"    -> kill-a-live-agent guard      (P0b, DENY)
#   PostToolUse  matcher "Agent|Task"  -> black-hole deadline reminder (existing, ALLOW+context)
# Rationale (2026-07-04 audit): the failing rules already existed in prose (frontend-verify.md / memory)
# but didn't fire at dispatch/kill time. Prose that doesn't reach the decision point is net-negative →
# promote to tool-call hooks. Same conclusion applied again 2026-07-10 for P0c (see below).
# Deny = exit 2 + stderr (shown to agent). Reminder = exit 0 + JSON
# hookSpecificOutput.additionalContext. Fail-open: any parse/FS error exits 0, never blocks work.
# The Agent/Task/TaskStop tools are Claude-Code concepts — harmless no-ops under Codex/omp.
import sys, json, re, os, glob, time

BROWSER_RE = re.compile(
    r"playwright|chrome-?devtools|browser|E2E|screenshot|navigate|dev server|"
    r"localhost:[0-9]|vite|npm run dev|pnpm .*dev",
    re.I,
)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    event = data.get("hook_event_name", "") or ""
    tool = data.get("tool_name", "") or ""
    ti = data.get("tool_input", {}) or {}

    # ── (P0b) PreToolUse·TaskStop: don't kill an agent that is still alive ──────────
    # 2026-07-04: killed a working browser agent twice because I used "no screenshots in the dir I
    # watched" as a stuck-proxy — but its .output was actively GROWING (a11y-driven agents write
    # snapshots, not image files). Liveness = output-file freshness, NOT a specific deliverable
    # artifact. If the target's transcript was written in the last FRESH_S seconds, it's alive → DENY;
    # poke it (SendMessage) first, and override only after confirming it's truly stuck.
    if event == "PreToolUse" and tool in ("TaskStop", "KillShell"):
        FRESH_S = 120
        tid = ti.get("task_id") or ti.get("shell_id") or ""
        if tid:
            if os.path.exists(f"/tmp/cto-allow-kill-{tid}"):
                return 0  # explicit override
            # /tmp works on BOTH platforms (macOS /tmp is a symlink into /private/tmp and
            # glob follows it); the /private prefix alone made this guard silently fail-open
            # on Linux — no transcript ever found => every kill allowed (caught by CI run #1).
            hits = (glob.glob(f"/tmp/claude-*/*/*/tasks/{tid}.output")
                    or glob.glob(f"/tmp/claude-*/**/tasks/{tid}.output", recursive=True)
                    or glob.glob(f"/private/tmp/claude-*/*/*/tasks/{tid}.output")
                    or glob.glob(f"/private/tmp/claude-*/**/tasks/{tid}.output", recursive=True))
            try:
                age = min(time.time() - os.path.getmtime(h) for h in hits) if hits else 1e9
            except Exception:
                age = 1e9
            if age < FRESH_S:
                sys.stderr.write(
                    f"DENY: TaskStop on '{tid}' — its transcript grew {int(age)}s ago, so it is ALIVE, "
                    "not black-holed. Liveness = output-file freshness, NOT presence of a specific "
                    "artifact (a11y-driven browser agents write snapshots, not image screenshots — 'zero "
                    "screenshots' != stuck; killed real progress twice on 2026-07-04). POKE it first via "
                    "SendMessage and read its reply. Only if it CONFIRMS stuck / reports BROWSER-UNAVAILABLE: "
                    f"`touch /tmp/cto-allow-kill-{tid}` then re-run TaskStop.\n"
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
        prompt = ti.get("prompt", "") or ""
        if BROWSER_RE.search(prompt) and re.search(r"mcp__chrome-?devtools", prompt, re.I):
            sys.stderr.write(
                "DENY: browser/E2E subagent dispatched to load chrome-devtools MCP (`mcp__chrome-devtools...`). "
                "Use Playwright MCP (`mcp__playwright__browser_*`) — it launches its OWN isolated Chromium. "
                "chrome-devtools attaches the user's real Chrome via CDP → multi-agent + user-browser "
                "contention → hangs (bit us twice; frontend-verify.md Playwright-first). Rewrite the ToolSearch "
                "to `select:mcp__playwright__browser_navigate,...` and re-dispatch. (Prose mention like 'never "
                "use chrome-devtools' is fine — this fires only on the mcp__chrome-devtools tool token.)\n"
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
                "(subagent_type \"fork\" is exempt — it always inherits the parent model.)\n"
            )
            return 2
        return 0

    # ── (existing) PostToolUse·Agent|Task: black-hole deadline reminder ────────────────────────────
    if event == "PostToolUse" and tool in ("Agent", "Task"):
        prompt = ti.get("prompt", "") or ""
        if not BROWSER_RE.search(prompt):
            return 0
        msg = (
            "[browser/long subagent launched] Its completion notification can BLACK-HOLE (a live Playwright "
            "session / dev server / bg fork keeps it from firing — you'll blind-wait forever). DO NOW, don't "
            "rely on the auto-notify: set a deadline-bounded background watch on POSITIVE evidence (output-file "
            "growth / milestone SendMessage — NOT screenshot-count, a11y agents write no images); if it goes "
            "quiet past the deadline, SendMessage to poke it, then kill+relaunch rather than wait. (cto S1.4/S7.)"
        )
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
