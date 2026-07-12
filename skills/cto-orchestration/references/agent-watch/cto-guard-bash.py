#!/usr/bin/env python3
# cto-guard-bash — PreToolUse·Bash enforcement for cto-orchestration. Wire to the Bash matcher
# (CC skill frontmatter `hooks:` / `.claude/settings.json`; Codex `hooks.json`). Catches the Bash
# slips the orchestrator keeps making (prose decays → enforce at tool-call time):
#   (1) trailing shell `&` -> ORPHAN (no completion callback; wrapper falsely reports done)  [DENY]
#   (2) naive "idle==done" poller (loop + capture-pane + idle grep, no positive-evidence check) [DENY]
#   (3) `dispatch <agent> <session>` WITHOUT later arming `watch <session>` -> reminder to arm the
#       watcher (the PRIMARY signal). This is an OMISSION, not a bad action -> can't DENY (there is no
#       tool call to intercept); inject salience at dispatch time instead, same doctrine as the
#       PostToolUse·Agent browser reminder (sibling cto-guard-agent.py). [ALLOW + additionalContext]
#   (4) raw `tmux send-keys` with long/CJK payload -> route through `dispatch send` [DENY]
#   (5) blocking `watch`/fused `dispatch --goal` in the foreground -> run_in_background [DENY]
# Deny = exit 2 + stderr (shown to the agent). Remind = exit 0 + JSON hookSpecificOutput.additionalContext
# (only that reaches the agent). Fail-open: any parse error exits 0, never blocks work. All-Python: the
# job is parsing arbitrary command content out of hook JSON — stdlib json is correct where shell-regex
# extraction would be fragile in a guard.
import sys, json, re, os


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    ti = data.get("tool_input", {}) or {}
    cmd = (ti.get("command", "") or "").replace("\n", " ")
    if not cmd:
        return 0
    # quote-stripped view: drop "..."/'...'/`...` spans so a token that only appears inside a quoted
    # arg (e.g. `echo "git push later"`, `echo "a & b"`) is NOT mistaken for a real command. Used by
    # the & guard (1) and the push guard (5). NOT used by the send-keys guard (4) — that one is
    # specifically about the QUOTED CJK payload, so it must see the raw cmd.
    unq = re.sub(r"\"[^\"]*\"|'[^']*'|`[^`]*`", "", cmd)

    # (1) shell-& backgrounding -> orphan. STRIP quoted/backtick spans first (so `echo "a & b"` is not a
    #     false positive), THEN flag any single `&` that backgrounds: not part of `&&` (logical-and) and
    #     not a redirect (`>&`, `&>`, `N>&M`). This closes the earlier blind spot where `foo & bar`
    #     (background-then-chain, e.g. `nohup … & echo …`) slipped the old `&[ \t]*(disown|;|$)` tail —
    #     the tail only caught `& ;` / `& disown` / `& <end>`, self-inflicted miss 2026-07-04. An unquoted
    #     `&` in a URL (`curl x?a=1&b=2`) IS a real shell background hazard → DENY is correct (quote it).
    if re.search(r"(?<![&>])&(?![&>])", unq):
        sys.stderr.write(
            "DENY: shell & backgrounding -> ORPHAN (no completion callback; the orchestrator can't track it "
            "and the wrapper falsely reports done). Fires on trailing `&`, `& ;`, `& disown`, AND "
            "background-then-chain `foo & bar` (e.g. `nohup … & echo`). `&&`, `2>&1`/`&>`/`N>&M` redirects, "
            "and quoted `&` are allowed. Drop the & and use the Bash tool run_in_background:true instead. "
            "Read: cto-orchestration/references/agent-watch/README.md §typed 状态.\n"
        )
        return 2

    # (2) naive "idle==done" poller: loop + capture-pane + busy/idle grep, concluding from idle-absence
    #     with NO positive-evidence check (git deliverable OR pane Verdict/prompt marker).
    has_loop = re.search(r"\b(for|while)\b", cmd)
    has_capture = re.search(r"capture-pane|tmux .*capture", cmd)
    has_idle = re.search(r"Working|Esc to interrupt|busy|idle|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏", cmd, re.I)
    has_positive = re.search(
        r"git diff --stat|git log[^|]*\.\.HEAD|--oneline|ALL PARTS DONE|Verdict|approve|"
        r"request-changes|Would you like to run|APPEARED|COMMIT_|PROMPT|SIGNAL_FOUND",
        cmd, re.I,
    )
    if has_loop and has_capture and has_idle and not has_positive:
        sys.stderr.write(
            "DENY: hand-rolled 'idle==done' poller (loop+capture-pane+idle grep, no positive-evidence "
            "check). idle≠done — staged tasks idle at every commit boundary. Add a POSITIVE check: git "
            "deliverable (git diff --stat / git log ..HEAD) for agent completion, or a pane grep for "
            "Verdict/prompt for reviews. Read: cto-orchestration/references/agent-watch/README.md "
            "§判完成要正向证据.\n"
        )
        return 2

    # (3) dispatch -> remind to arm watch. `dispatch <omp|codex|claude> <session> [cwd]` starts a tmux
    #     agent; arming `watch <session>` (the primary, hook-driven signal) is a SEPARATE step the
    #     orchestrator owns (Claude Code must background it via run_in_background — NOT shell &, which
    #     orphans) -> easy to skip -> silent timer-guessing displaces the proper signal. Allow, but
    #     inject the reminder so the omission can't pass silently. Don't fire if `watch <session>` is
    #     already in the same command line.
    # (4) raw `tmux send-keys` with a long / non-ASCII (CJK) text payload -> the omp skill-fuzzy
    #     popup eats Enter, the message stalls in the input buffer, the session sits idle, and the
    #     watcher can't tell "waiting for my release" from "my release didn't land" (2026-07-04:
    #     self-inflicted 24-min stall). Route through `dispatch send <session> -m/-f …`, which writes
    #     the instruction to a FILE, send-keys only a short ASCII "read <file>", clears any popup, and
    #     VERIFIES the session transitioned to WORKING (retry+warn if not). Control-key / short-ASCII
    #     sends (Enter / Escape / C-u / menu picks "1" "B" / "read <file>…") have no CJK and no long
    #     quoted arg -> allowed. `dispatch send` at the tool-call layer is `bash …/dispatch send …`
    #     and does NOT contain the literal `tmux send-keys`, so the safe path is never caught here.
    if re.search(r"tmux\s+send-keys", cmd):
        has_cjk = re.search(r"[①-⓿　-鿿＀-￯]", cmd)  # CJK ideographs+punct, ①②③, 全角
        quoted = re.findall(r'"([^"]*)"', cmd) + re.findall(r"'([^']*)'", cmd)
        long_quoted = any(len(q) > 120 for q in quoted)
        if has_cjk or long_quoted:
            sys.stderr.write(
                "DENY: raw `tmux send-keys` with long/non-ASCII (中文/①②③/全角/长串) text -> the omp "
                "skill-popup eats Enter, the message stalls in the input buffer, the session sits idle, "
                "and the watcher can't tell 'waiting for release' from 'release didn't land' (self-inflicted "
                "24-min stall, 2026-07-04). Use `bash <agent-watch>/dispatch send <session> -m \"…\"` (or "
                "-f <file>) instead — it writes the instruction to a file, sends only a short ASCII "
                "reference, and VERIFIES the session transitioned to WORKING. Control-key sends "
                "(Enter/Escape/C-u/short ASCII menu picks) are fine and not blocked. "
                "Read: cto-orchestration/references/agent-watch/README.md (裸 send-keys 坑枚举).\n"
            )
            return 2

    # NOTE: git-push governance (local-E2E-before-push, base-branch protection) intentionally lives in
    # the Git-workflow standard skill + a server-side branch-protection ruleset,
    # NOT here — cto-guard owns orchestration slips (backgrounding, idle-polling, dispatch, send-keys),
    # not git policy. Don't re-add push checks here.

    # (5) BLOCKING watch / fused `dispatch --goal` run in the FOREGROUND: both block until the
    #     agent's terminal state — under a foreground Bash timeout (Claude Code default 2min) the
    #     call is killed mid-watch (exit 143) and the watcher dies with it (field hit: LH
    #     2026-07-11, `send … && watch` chained foreground). run_in_background:true is the
    #     documented path. Shell orchestrators that run watch synchronously BY DESIGN (codex/
    #     shell — README "run it synchronously and read the code") opt out explicitly by
    #     prefixing the command with AGENT_WATCH_SYNC=1.
    # DISPATCH_EXEC=1 routes the launch to the headless exec lane, which returns
    # immediately (tmux supervisor detaches) — foreground is fine there. Check BOTH the
    # command string (inline prefix) and this hook's own env: a global switch (e.g. set in
    # ~/.zshenv) never appears in the command text but is inherited by the hook process.
    if (not ti.get("run_in_background") and "AGENT_WATCH_SYNC=1" not in cmd
            and "DISPATCH_EXEC=1" not in cmd and os.environ.get("DISPATCH_EXEC") != "1"):
        fused = re.search(r"\bdispatch[\"'\s]+(omp|codex|claude)\b", cmd) and "--goal" in cmd
        # command-position only: `grep x …/agent-watch/watch` (path as an ARGUMENT) must not trip
        # this, and the interpreter itself must sit at command position too — `emit.sh <path>` let
        # `\bsh\s` match the ".sh" tail and re-flagged an argument. Both self-inflicted false
        # positives within minutes of wiring, 2026-07-11. Shape: [;|&(or start] [ENV=v …]
        # [bash|sh|exec|nohup|time] <token ending in agent-watch/watch>.
        watchcall = re.search(
            r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*(?:(?:bash|sh|exec|nohup|time)\s+)?[\"']?\S*agent-watch/watch[\"']?(?:\s|$)",
            cmd,
        )
        if fused or watchcall:
            sys.stderr.write(
                "DENY: blocking watch/`dispatch --goal` in the FOREGROUND — it blocks until the agent's "
                "terminal state, so a foreground Bash timeout (default 2min) kills it mid-watch (exit 143) "
                "and the watcher dies with it. Re-run with run_in_background:true. Synchronous shell "
                "orchestrators (codex): prefix the command with AGENT_WATCH_SYNC=1 to pass. "
                "Read: cto-orchestration/references/agent-watch/README.md §Launch.\n"
            )
            return 2

    m = re.search(r"\bdispatch[\"'\s]+(omp|codex|claude)[\"'\s]+([^\s\"';|&]+)", cmd)
    if m and "--goal" not in cmd:  # `dispatch … --goal` auto-arms the in-process watch → no reminder needed
        session = m.group(2)
        if not re.search(r"\bwatch[\"'\s]+" + re.escape(session) + r"\b", cmd):
            ctx = (
                f"REMINDER (cto-guard): you are dispatching tmux session '{session}'. Arm the watcher "
                f"as the PRIMARY signal right after it starts — run `bash <agent-watch>/watch {session}` "
                f"via the Bash tool with run_in_background:true (NOT shell &, which orphans it). A "
                f"ScheduleWakeup timer is only the BACKSTOP, not a substitute for the watcher."
            )
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": ctx,
                }
            }))
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
