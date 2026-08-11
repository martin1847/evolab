#!/usr/bin/env python3
# cto-guard-bash — PreToolUse·Bash enforcement for cto-orchestration. Wire to the Bash matcher
# (CC skill frontmatter `hooks:` / `.claude/settings.json`; Codex `hooks.json`). Catches the Bash
# slips the orchestrator keeps making (prose decays → enforce at tool-call time):
#   (1) trailing shell `&` -> ORPHAN (no completion callback; wrapper falsely reports done)  [DENY]
#   (2) naive "idle==done" poller (loop + capture-pane + idle grep, no positive-evidence check) [DENY]
#   (3) `agentctl start <agent> <session>` WITHOUT later arming `watch <session>` -> reminder to arm the
#       watcher (the PRIMARY signal). This is an OMISSION, not a bad action -> can't DENY (there is no
#       tool call to intercept); inject salience at dispatch time instead, same doctrine as the
#       PostToolUse·Agent browser reminder (sibling cto-guard-agent.py). [ALLOW + additionalContext]
#   (4) raw `tmux send-keys` with long/CJK payload -> route through `agentctl steer` [DENY]
#   (5) blocking `agentctl watch` in the foreground -> run_in_background [DENY]
#   (6) live e2e gate run without the E2E_ECONOMY=1 runner marker -> dispatch a cheap-model
#       worker instead of burning the orchestrator's premium session on supervision [DENY]
# Deny/checker error = exit 2 + stderr (shown to the agent). Remind = exit 0 + JSON
# hookSpecificOutput.additionalContext (only that reaches the agent). All-Python: the
# job is parsing arbitrary command content out of hook JSON — stdlib json is correct where shell-regex
# extraction would be fragile in a guard.
import sys, json, re, os, subprocess


def checker_error(message):
    sys.stderr.write(f"CHECKER-ERROR: {message}\n")
    return 2


# ── rule (7) benign-prune support ────────────────────────────────────────────────────────
# CLOSED SYNTAX. The benign fast path opens only when the WHOLE command text is ONE simple
# prune call: `git [-C <path>] worktree prune [--dry-run|-v|--verbose]`. Matched on the RAW
# command (never the quote-stripped view), separators are [ \t] only. Everything else fails
# to match and falls through to the normal DENY+marker path — chains (`;` `&&` `||` `|`),
# newlines, command substitution, env prefixes, `cd`, a second `-C`, `--git-dir` /
# `--work-tree` / `-c`, path globs / variables / escapes. Rejection is BY CONSTRUCTION: no
# dangerous form is ever enumerated, so an unlisted one cannot slip through as "not matched
# as dangerous" — it is simply not the shape we can vouch for.
# `--expire <t>` is deliberately OUT of the shape: `worktree list --porcelain` computes its
# `prunable` annotations with the DEFAULT expiry, so a custom expire can reap entries the
# annotation never showed us (e.g. a half-finished `worktree add` whose directory still
# exists). The evidence would not cover the action.
_PRUNE_BARE = r"[A-Za-z0-9_@%+=:,./^-]+"  # no quote/glob/$/~/space/shell metachar
_PRUNE_PATH = r"(?:'[^'\n]*'|\"[^\"\n$`\\!]*\"|" + _PRUNE_BARE + r")"
_PRUNE_CMD = re.compile(
    r"git[ \t]+(?:-C[ \t]+(?P<path>" + _PRUNE_PATH + r")[ \t]+)?worktree[ \t]+prune"
    r"(?:[ \t]+(?:--dry-run|-v|--verbose))*")


def _porcelain_prunable(repo):
    """Paths of every prunable worktree entry, or None when the judgement is UNAVAILABLE.
    Strict invariant: a `worktree <path>` line opens a segment, every other key belongs to
    the segment above it, no key repeats. Any deviation (orphan `prunable`, duplicate or
    valueless `worktree`, unknown key, undecodable byte) returns None -> caller denies."""
    try:
        proc = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    try:
        text = proc.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return None
    keys = ("worktree", "HEAD", "branch", "bare", "detached", "locked", "prunable")
    cur, seen, prunable = None, set(), []
    for line in text.split("\n"):
        if not line:
            cur, seen = None, set()
            continue
        key, _, value = line.partition(" ")
        if key not in keys or key in seen:
            return None
        if key == "worktree":
            if not value:
                return None
            cur, seen = value, {key}
            continue
        if cur is None:
            return None  # attribute without an owning segment
        seen.add(key)
        if key == "prunable":
            prunable.append(cur)
    return prunable


def _benign_prune(command, payload):
    """True only when this prune provably has nothing to lose: closed syntax AND every
    prunable entry's worktree path is already gone. Fail-closed everywhere else."""
    m = _PRUNE_CMD.fullmatch(command.strip(" \t\r\n"))
    if not m:
        return False
    # hook payload cwd only — the guard process's own cwd is NOT the shell's, so
    # os.getcwd() must never stand in for it (it would judge the wrong repo).
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        cwd = None
    arg = m.group("path")
    if arg is None:
        repo = cwd
    else:
        arg = arg[1:-1] if arg[0] in "'\"" else arg
        if not arg:
            return False
        repo = arg if os.path.isabs(arg) else (os.path.join(cwd, arg) if cwd else None)
    if not repo:
        return False
    prunable = _porcelain_prunable(repo)
    if prunable is None:
        return False
    # lexists, not exists: a DANGLING SYMLINK is still something standing at that path.
    return not any(os.path.lexists(p) for p in prunable)


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
    if event != "PreToolUse" or tool != "Bash":
        return 0
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        return checker_error("PreToolUse Bash requires object tool_input.")
    if "command" not in ti or not isinstance(ti["command"], str):
        return checker_error("PreToolUse Bash requires string tool_input.command.")
    if "run_in_background" in ti and not isinstance(ti["run_in_background"], bool):
        return checker_error("tool_input.run_in_background must be boolean.")
    raw = ti["command"]
    # Only a QUOTED heredoc delimiter disables expansion, so only those bodies are data-safe to
    # ignore. Unquoted `<<EOF` bodies may execute command substitutions and must remain visible to
    # every guard rule. Preserve opener/closer lines so commands after the heredoc are still scanned.
    def _strip_quoted_heredocs(s: str) -> str:
        lines = s.splitlines(keepends=True)
        opener = re.compile(r"<<(?P<tabs>-?)(?!<)[ \t]*(?P<quote>['\"])(?P<tag>[^'\"\r\n]+)(?P=quote)")
        any_op = re.compile(r"<<-?(?!<)[ \t]*(?:['\"][^'\"\r\n]+['\"]|[^\s;|&<>]+)")
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]
            out.append(line)
            quoted = list(opener.finditer(line))
            # Mixed quoted/unquoted heredocs share one body stream; leave the whole command intact
            # rather than guessing which body belongs to which delimiter.
            if not quoted or len(quoted) != len(any_op.findall(line)):
                i += 1
                continue
            cursor = i + 1
            rendered = []
            for match in quoted:
                tag = match.group("tag")
                strip_tabs = match.group("tabs") == "-"
                end = None
                for j in range(cursor, len(lines)):
                    candidate = lines[j].rstrip("\r\n")
                    if (candidate == tag or
                            (strip_tabs and candidate.startswith("\t") and candidate.lstrip("\t") == tag)):
                        end = j
                        break
                if end is None:
                    return s  # unterminated/ambiguous: scan conservatively, strip nothing
                rendered.extend(("<<<HEREDOC-BODY-STRIPPED>>>\n", lines[end]))
                cursor = end + 1
            out.extend(rendered)
            i = cursor
        return "".join(out)
    raw = _strip_quoted_heredocs(raw)
    cmd = raw.replace("\n", " ")
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
            "DENY: shell `&` backgrounding -> ORPHAN (no completion callback; wrapper falsely reports "
            "done). Fix: drop the `&`, use Bash run_in_background:true; a data `&` (URLs) must be "
            "quoted. `&&` and `2>&1`-style redirects pass. "
            "Read: cto-orchestration/references/agentctl/README.md §typed 状态.\n"
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
            "DENY: 'idle==done' poller — idle≠done (staged tasks idle at every commit boundary). "
            "Fix: add a POSITIVE check: git deliverable (`git diff --stat` / `git log ..HEAD`) for "
            "completion, or a pane grep for Verdict/prompt for reviews. "
            "Read: cto-orchestration/references/agentctl/README.md §判完成要正向证据.\n"
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
                "DENY: raw `tmux send-keys` text payload — pane keystrokes stall unseen (popup eats "
                "Enter; ~70-80% delivery). Fix: steer by protocol: `agentctl steer <session> -m \"…\"` "
                "(or -f <file>) delivers a native frame mid-turn. Control-key / short-ASCII sends on a "
                "manually attached session pass. "
                "Read: cto-orchestration/references/agentctl/README.md (裸 send-keys 坑枚举).\n"
            )
            return 2

    # (8) cwd anchoring in multi-repo umbrella workspaces (principal ruling 2026-07-26). Shell cwd
    #     drifts across tool calls (a denied command's cd never ran; parallel calls leave the last
    #     call's cwd) — in an umbrella of sibling git repos a bare `git`/`gh` then acts on the WRONG
    #     repo (field hits: 3 bites in one wave 2026-07-24; PR opened in the wrong repo 2026-07-26).
    #     This is an orchestration slip (cwd discipline), not git policy — see NOTE below.
    #     Deny message leads with REWRITE-don't-resend: field hit 2026-07-29, 4 identical resends
    #     in a row (the agent acknowledges the deny then re-emits the same text verbatim).
    #     Scope gate: only fires when the REAL cwd (symlinks resolved — a symlinked cwd hid the
    #     umbrella, review probe 2026-07-26) or an ancestor within 5 levels is an umbrella root
    #     (>=2 immediate children with .git); single-repo projects never see it.
    def _umbrella_near(path):
        try:
            p = os.path.realpath(path)
        except Exception:
            return False
        for _ in range(6):  # cwd + 5 ancestors (range(5) undershot the documented contract)
            try:
                kids = os.listdir(p)
            except OSError:
                return False
            n = 0
            for k in kids:
                if os.path.exists(os.path.join(p, k, ".git")):
                    n += 1
                    if n >= 2:
                        return True
            parent = os.path.dirname(p)
            if parent == p:
                return False
            p = parent
        return False

    # Anchor semantics (two cold-review rounds hardened all of these with live probes 2026-07-26):
    # - leading `cd <ABS> && …` anchors the whole line; `cd X; git`, `cd X || git` and
    #   `cd X | git` do NOT (git runs even when cd failed / in its own pipeline process).
    # - otherwise EVERY git/gh segment self-anchors, and the anchor must be cwd-INDEPENDENT:
    #   `-C <abs>` / `--git-dir(=| )<abs>` only — relative `-C .` still rides the drifted cwd,
    #   and `--work-tree` selects a work tree, NOT the repository (rev-parse proves the repo
    #   still comes from cwd). gh anchors via -R/--repo. Repo-insensitive forms pass:
    #   git --version/help, git config --global/--system, gh auth/config/api/extension/version.
    # - real execution forms that hid the command token, each a working bypass in review:
    #   wrapper chains incl. option args (timeout -s KILL 30 git), nice, quoted ("git") /
    #   ANSI-C ($'git') / backslash-escaped (g\it) tokens, `bash -c '<payload>'` payloads,
    #   MULTILINE commands (newline is a `;` boundary, not a space), and shell-consumer
    #   stdin (`bash <<EOF`, `… | bash`) whose body executes as script.
    def _git_anchored(rest):
        toks = rest.split()
        i = 0
        sub = None
        while i < len(toks):
            t = toks[i]
            if t == "-C":
                if i + 1 < len(toks) and toks[i + 1].startswith("/"):
                    return True
                i += 2
                continue
            if t.startswith("--git-dir"):
                val = t.split("=", 1)[1] if "=" in t else (toks[i + 1] if i + 1 < len(toks) else "")
                if val.startswith("/"):
                    return True
                i += 1 if "=" in t else 2
                continue
            if t == "-c":
                i += 2
                continue
            if t.startswith("-"):
                i += 1
                continue
            sub = t
            break
        if sub is None:
            return True  # global flags only (--version / --help): no repo action
        if sub in ("version", "help"):
            return True
        if sub == "config" and ("--global" in toks or "--system" in toks):
            return True
        return False

    def _gh_anchored(rest):
        if re.search(r"(?:^|\s)(?:-R|--repo)\s+\S+", rest):
            return True
        for t in rest.split():
            if t.startswith("-"):
                continue
            return t in ("auth", "config", "api", "extension", "version", "help")
        return True  # e.g. bare `gh --version`

    _WRAP8 = (r"(?:(?:\S*/)?(?:command|env|exec|nohup|time|timeout|nice)\s+"
              r"(?:-{1,2}[\w-]+(?:=\S*)?(?:\s+[^\s;|&-][^\s;|&]*)?\s+|\w+=\S*\s+|\d+\s+)*)*")

    def _cd_anchor(full):
        # full keeps quoted spans (a quoted absolute cd path must stay visible)
        m8cd = re.match(r"\s*(?:\w+=\S*\s+)*cd\s+(\"[^\"]*\"|'[^']*'|[^\s;|&]+)\s*&&", full)
        return m8cd if (m8cd and m8cd.group(1).strip("\"'").startswith("/")) else None

    def _unanchored_segs(stripped):
        for seg in re.split(r"[;|&(]", stripped):
            m8 = re.match(r"\s*(?:\w+=\S*\s+)*" + _WRAP8 + r"(?:\S*/)?(git|gh)\b(.*)$", seg)
            if not m8:
                continue
            tool8, rest = m8.group(1), m8.group(2)
            if tool8 == "git" and _git_anchored(rest):
                continue
            if tool8 == "gh" and _gh_anchored(rest):
                continue
            return True
        return False

    def _strip_spans(s):
        # multi-word quoted spans are data — but keep a leading slash so a quoted
        # ABSOLUTE path ('-C "/repo with space"') still reads as absolute
        return re.sub(r"\"([^\"]*)\"|'([^']*)'|`([^`]*)`",
                      lambda m: "/QSPAN" if (m.group(1) or m.group(2) or m.group(3) or "")
                      .startswith("/") else "QSPAN", s)

    def _text_unanchored(full):
        # a leading `cd /abs &&` guarantees cwd ONLY along the &&-chain: after the first
        # `;` or `||` the shell runs the rest even when cd failed — those segments must
        # self-anchor again (self-caught variant of the R1 `cd ||` hole)
        mcd = _cd_anchor(full)
        if mcd:
            parts = re.split(r";|\|\|", full[mcd.end():], 1)
            return len(parts) > 1 and _unanchored_segs(_strip_spans(parts[1]))
        return _unanchored_segs(_strip_spans(full))

    # rule-8 views: newline = `;` (a second line is a NEW command — flattening to a space
    # made `echo ready\ngit status` invisible, review R2); unwrap single-token quotes
    # ("git", $'git'), drop backslash escapes (g\it)
    cmd8 = raw.replace("\n", ";")
    v8 = re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2", cmd8).replace("\\", "")
    orig8 = ti["command"]  # pre-heredoc-strip: quoted heredoc bodies are data EXCEPT to a shell consumer
    if ((re.search(r"\b(?:git|gh)\b", v8) or re.search(r"\b(?:git|gh)\b", orig8))
            and _umbrella_near(data.get("cwd") or os.getcwd())):
        bad8 = _text_unanchored(v8)
        if not bad8:
            # interpreter payloads execute too: bash -lc 'git status' hid git in a quoted span
            for mi in re.finditer(
                    r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _WRAP8 +
                    r"(?:\S*/)?(?:bash|sh|zsh)\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+)*([\"'])(.*?)\1", cmd8):
                pv = re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2", mi.group(2)).replace("\\", "")
                if _text_unanchored(pv):
                    bad8 = True
                    break
        if not bad8 and not _cd_anchor(v8) and re.search(
                r"(?:\S*/)?(?:bash|sh|zsh)\b[^|;&]*<<|\|\s*(?:\S*/)?(?:bash|sh|zsh)\b", orig8):
            # heredoc / pipe INTO a shell runs its body as script; the body may be
            # quote-stripped above, so judge on the original text (conservative)
            bad8 = bool(re.search(r"\bgit\b|\bgh\b", orig8))
        if bad8:
            sys.stderr.write(
                "DENY: unanchored git/gh in a multi-repo umbrella — shell cwd drifts across tool "
                "calls, so a bare git/gh can act on the WRONG repo. Fix: REWRITE the command (do "
                "NOT resend the same text): prefix each call `git -C /abs/<repo>` / `gh -R "
                "<owner>/<repo>`, or lead the line with `cd /abs/<repo> && …`. Repo-insensitive "
                "forms (git --version, gh auth/api …) pass. "
                "Read: cto-orchestration/references/agentctl/README.md §cwd 锚定.\n"
            )
            return 2

    # NOTE: git-push governance (local-E2E-before-push, base-branch protection) intentionally lives in
    # the Git-workflow standard skill + a server-side branch-protection ruleset,
    # NOT here — cto-guard owns orchestration slips (backgrounding, idle-polling, dispatch, send-keys),
    # not git policy. Don't re-add push checks here.

    # (7) worktree lifecycle (principal ruling 2026-07-19): non-force `git worktree remove` is a
    #     STANDING GRANT for close/retro cleanup — git itself refuses a tree with modified or
    #     untracked files, the branch ref survives, so the non-force form is reversible by
    #     construction → auto-allow (no per-cleanup ask). The dangerous forms stay hard-gated:
    #     `--force`/`-f` bulldozes untracked files (field loss 2026-07-19: probe scripts died in
    #     a chained force-remove whose salvage cp had silently aborted on a bad glob) and `prune`
    #     mass-deletes on staleness guesses. Those need the principal's explicit fresh turn AND a
    #     salvage of untracked files VERIFIED IN A SEPARATE command first — never chain
    #     verify+destroy in one command line.
    # Global-option prefix: repeated `-C <arg>` / `-c <arg>` / `--long[=val]` before the
    # subcommand. A quoted `-C '/path with space'` argument VANISHES from the unquoted view,
    # leaving `-C` directly before `worktree` — the lookahead keeps \S+ from eating the
    # subcommand itself (review probe 2026-07-24: quoted/-c forms slipped past the old regex).
    wts = list(re.finditer(
        r"git\s+(?:-[cC]\s+(?:(?!worktree\s)[^\s;|&]+\s+)?|--?[A-Za-z][^\s;|&]*\s+)*"
        r"worktree\s+(remove|prune)\b([^;|&]*)", unq))
    if wts:
        destroy = [w for w in wts
                   if w.group(1) == "prune" or re.search(r"(?:^|\s)(?:--force|-f)\b", w.group(2))]
        if destroy:
            # BENIGN PRUNE FAST PATH (field 2026-08-10, seat A: a pure-metadata prune —
            # every prunable entry's directory already gone — cost two DENY walls and a
            # marker ritual for zero possible loss). Opens ONLY on the closed syntax above
            # AND positive evidence from `worktree list --porcelain`; the marker is NOT
            # touched, `remove --force` is unaffected.
            # TOCTOU, accepted and unresolved: between our `list` and the shell's `prune`,
            # a path we saw as gone could reappear (a `worktree add` landing in that exact
            # window). Damage ceiling then = that entry's METADATA is reaped: worktree files
            # and branch ref both survive, but the tree loses its git link (`git status`
            # rc=128) and `git worktree repair` CANNOT rebuild it (measured, git 2.50.1) —
            # recovery is manual re-add plus migrating uncommitted work. Accepted because
            # the window is milliseconds AND it takes a vanished path reappearing inside it,
            # while file bytes are never lost. No lock, no second look.
            if _benign_prune(ti["command"], data):
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "permissionDecisionReason": (
                            "cto-guard: benign `git worktree prune` — `git worktree list "
                            "--porcelain` shows every prunable entry's worktree path is already "
                            "gone, so this reaps dead metadata only (no files, no branch refs). "
                            "Override marker untouched."
                        ),
                    }
                }))
                return 0
            # Auditable ONE-SHOT override (shock-in-the-loop §4 "override 有形"; gap hit
            # 2026-07-21: an already-approved prune had no path through this DENY). The marker
            # is consumed on use so it can never linger as a standing bypass; it lifts the DENY
            # only — no auto-allow, the normal permission flow still applies.
            # CONSUMPTION IS THE APPROVAL: allow only if the marker was actually removed —
            # a directory / unremovable object at this path must DENY, not become a standing
            # bypass (review probe 2026-07-24: mkdir'd marker allowed forever); and of two
            # concurrent guards only the one whose remove succeeds is lifted.
            marker = "/tmp/cto-allow-worktree-destroy"
            try:
                os.remove(marker)
                consumed = True
            except OSError:
                consumed = False
            if not consumed:
                sys.stderr.write(
                    "DENY: `git worktree remove --force` / `prune` needs the principal's explicit "
                    "fresh-turn approval (force bulldozes untracked files; prune mass-deletes on "
                    "staleness guesses). Fix: inspect `git -C <wt> status --porcelain`, salvage "
                    "untracked files and VERIFY the salvage in its own command, then ask. Already "
                    "approved? `touch /tmp/cto-allow-worktree-destroy` (one-shot, consumed on use) "
                    "and re-run. Non-force remove of a clean tree passes (standing grant). "
                    "Read: cto-orchestration/references/agentctl/README.md §强制层 ⑦.\n"
                )
                return 2
        else:
            segs = [s.strip() for s in re.split(r"&&|;", unq) if s.strip()]
            benign = re.compile(r"^(git\s+(-C\s+\S+\s+)?worktree\s+(remove|list)\b|echo\b|cd\s)")
            if all(benign.match(s) for s in segs):
                print(json.dumps({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "permissionDecisionReason": (
                            "cto-guard: non-force `git worktree remove` = standing grant (principal "
                            "2026-07-19). git refuses dirty trees; branch ref survives — reversible."
                        ),
                    }
                }))
                return 0

    # (5) BLOCKING `agentctl watch` in the FOREGROUND: it blocks until the agent's terminal
    #     state — under a foreground Bash timeout (Claude Code default 2min) the call is killed
    #     mid-watch (exit 143) and the watcher dies with it (field hit: 2026-07-11, chained
    #     foreground). run_in_background:true is the documented path. Shell orchestrators that
    #     run watch synchronously BY DESIGN opt out explicitly by prefixing AGENT_WATCH_SYNC=1.
    #     `agentctl start` returns after the goal frame is accepted — foreground is fine there.
    if not ti.get("run_in_background"):
        # command-position only: `grep x …/agentctl` (path as an ARGUMENT) must not trip this,
        # and the interpreter itself must sit at command position too — an earlier `\bsh\s`
        # matched a ".sh" argument tail (two self-inflicted false positives within minutes of
        # wiring, 2026-07-11). Wrapper CHAINS (command/env/timeout/bash -lc …) are legal command
        # position too — a bare-prefix regex waved them through (review S2 2026-07-19). Shape:
        # [;|&(or start] [ENV=v …] [wrapper [opts/assignments/numeric-arg]…]* <token ending in
        # agentctl|dispatch-exec> watch.
        # wrapper elements may be path-qualified (/usr/bin/env) and may open a quoted
        # payload (bash -lc 'command agentctl watch …') — review R2 bypass census
        _wrap = r"(?:[\"']?(?:\S*/)?(?:bash|sh|zsh|exec|nohup|time|command|env|timeout)\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+|\w+=\S*\s+|\d+\s+)*)*"
        watchcall = re.search(
            r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _wrap +
            r"[\"']?\S*agentctl[\"']?\s+watch(?:[\"'\s]|$)",
            cmd,
        )
        # the sync marker must be ATTACHED to the watch segment AND unquoted — quoted
        # data (`echo 'AGENT_WATCH_SYNC=1 agentctl watch'`) forged attachment on the raw
        # view (review R2). Legit form: prefix the whole command, outside quotes:
        # `AGENT_WATCH_SYNC=1 bash …/agentctl watch s`.
        # conjunction: the marker must exist UNQUOTED somewhere (quoted data can't forge
        # it) AND sit in the same raw segment as the watch call (detached echo can't
        # lend it) — the watch call itself may legitimately live inside a -c payload
        sync_attached = ("AGENT_WATCH_SYNC=1" in unq) and re.search(
            r"AGENT_WATCH_SYNC=1[^;|&]*agentctl[\"'\s]+watch", cmd)
        if watchcall and not sync_attached:
            sys.stderr.write(
                "DENY: foreground `agentctl watch` — it blocks until the agent's terminal state; "
                "the Bash timeout (default 2min) kills it mid-watch (exit 143). Fix: re-run with "
                "run_in_background:true; deliberately-synchronous shell orchestrators prefix "
                "AGENT_WATCH_SYNC=1. "
                "Read: cto-orchestration/references/agentctl/README.md §Launch.\n"
            )
            return 2

    m = re.search(r"\bagentctl[\"'\s]+start[\"'\s]+(omp|codex|claude)[\"'\s]+([^\s\"';|&]+)", cmd)
    if m:
        session = m.group(2)
        # pairing must be a COMMAND-POSITION watch invocation on the same session —
        # `echo agentctl watch s1` and prose both silenced the reminder (review R2)
        _wrap3 = r"(?:[\"']?(?:\S*/)?(?:bash|sh|zsh|exec|nohup|time|command|env|timeout)\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+|\w+=\S*\s+|\d+\s+)*)*"
        paired = re.search(
            r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _wrap3 +
            r"[\"']?\S*agentctl[\"']?\s+watch[\"'\s]+" + re.escape(session) + r"\b",
            cmd,
        )
        if not paired:
            ctx = (
                f"REMINDER (cto-guard): session '{session}' has no watcher — arm the PRIMARY signal "
                f"now: `agentctl watch {session}` via Bash run_in_background:true (NOT shell &, "
                f"which orphans). A ScheduleWakeup timer is only the backstop."
            )
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": ctx,
                }
            }))
        return 0

    # (6) live e2e gates are economy-tier supervision (owner ruling 2026-07-12): the orchestrator
    #     (typically on a premium model) must DISPATCH them to a cheap-model worker, not run them
    #     itself. The dispatched runner declares itself with an E2E_ECONOMY=1 command prefix — same
    #     explicit-declaration shape as AGENT_WATCH_SYNC=1 in (5). Command-position discipline as in
    #     (5): reading/grepping an e2e script (path as argument) must not trip this; only executing
    #     one does. Deliberately NO os.environ passthrough — a global E2E_ECONOMY export would kill
    #     the guard silently; the marker belongs in the command string the worker was briefed to use.
    if "E2E_ECONOMY=1" not in cmd:
        # discriminator = the `.e2e.sh` NAMING suffix (a `cd test/e2e && bash onboard.e2e.sh`
        # invocation carries no e2e/ path segment — a dir-based match missed it, self-caught in
        # the hermetic suite before shipping), plus the e2e/run.sh umbrella runner.
        e2ecall = re.search(
            r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*(?:(?:bash|sh|zsh|exec|nohup|time)\s+)?[\"']?(?:\S*\.e2e\.sh|\S*e2e/run\.sh)[\"']?(?:[\s;|&)\"']|$)",
            cmd,
        )
        if e2ecall:
            sys.stderr.write(
                "DENY: live e2e gate in this (premium) session — it is mechanical supervision. "
                "Fix: dispatch to a CHEAP-model worker (Agent tool, e.g. haiku) that prefixes each "
                "gate command with E2E_ECONOMY=1 (the economy-runner declaration). "
                "Read: cto-orchestration/SKILL.md §0 (不自己跑长 E2E / model 按活分档).\n"
            )
            return 2

    # (9) browser ownership: the agent drives Playwright's OWN isolated browser, never the
    #      principal's daily Chrome/Edge. Same rule as P0a in cto-guard-agent.py — that one
    #      guards the `mcp__chrome-devtools` channel; `playwright-cli attach --cdp/--extension`
    #      is the same takeover through a shell command, which carries no tool token, so P0a is
    #      dark on it. Only these two flags are gated (principal's scoping 2026-08-12): they are
    #      the takeover pair, and `attach` is most tempting exactly when a login wall blocks the
    #      isolated browser — the moment prose is weakest (P0a exists because Playwright-first
    #      prose was already in place and the dispatch loaded chrome-devtools anyway).
    #      Deliberately NOT covered, accept-documented rather than silently implied:
    #      `--endpoint`/`--config` (may point at an isolated browser-server; UNKNOWN, left legal),
    #      indirection through a variable/wrapper, quoted-heredoc bodies (stripped from `raw`
    #      upstream), and any execution inside an omp/codex worker's own harness (different hook
    #      set). Echoing the literal is denied too — accepted false positive, the recovery is
    #      "don't put it in a shell command".
    #      Judge the SHELL-EXECUTED token surface, not the JSON spelling: the shell removes quote
    #      and backslash spans before exec, so `playwright\-cli at\tach --cdp=…` and
    #      `"playwright-cli" attach …` reach the same binary while a raw-byte match sees neither
    #      (review probe 2026-08-12: both returned rc=0 against the first cut of this rule).
    #      Same normalization rule (8) already uses for the git/gh anchor check.
    # Line continuations FIRST: `--c\<newline>dp` is one token to the shell but a newline-split
    # pair to a naive scan (review probe 2026-08-12 reached the takeover with rc=0).
    v9 = re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2",
                re.sub(r"\\\r?\n", "", raw)).replace("\\", "")
    if re.search(r"playwright-cli\b[^|;&]*\battach\b", v9) and re.search(
            r"(?:^|\s)--(?:cdp|extension)\b", v9):
        # Attaching is not always wrong (principal's ruling 2026-08-12): an enterprise SSO login
        # that cannot be replayed into storageState legitimately needs a real Chrome — and CDP
        # attach to an ALREADY-RUNNING one is the correct shape, strictly better than seizing the
        # profile directory (which locks it and breaks the principal's own browser). What must
        # stay gated is doing it silently by default. Same one-shot override as rule (7):
        # consumption IS the approval, so it can never linger as a standing bypass.
        marker = "/tmp/cto-allow-browser-attach"
        # One approval authorizes ONE attach, and the approved command may not re-arm the marker
        # (review probes 2026-08-12: `attach A; attach B` rode one marker; `attach A; touch
        # <marker>` rebuilt a standing bypass right after consumption). Both shapes are refused
        # BEFORE the marker is touched, so a refused command never burns the principal's approval.
        if len(re.findall(r"\battach\b", v9)) > 1 or marker in v9:
            sys.stderr.write(
                "DENY: an attach override authorizes exactly ONE attach and the approved command "
                "must not re-arm the marker. Fix: run a single `playwright-cli attach …` per "
                "approval, and never `touch /tmp/cto-allow-browser-attach` inside it.\n"
            )
            return 2
        try:
            os.remove(marker)
            consumed = True
        except OSError:
            consumed = False
        if not consumed:
            sys.stderr.write(
                "DENY: attaching to a real browser is not the default — multi-agent contention "
                "with the principal's own session hangs (bit us twice). Fix: drive Playwright's "
                "own browser (`playwright-cli open <url>`), login state carried by a "
                "PROJECT-SCOPED storageState file (per role: admin/buyer), one named session per "
                "project (`-s=<project>`), expiry refreshed by a setup project — not a temp "
                "profile, not the daily browser. Genuinely need real "
                "Chrome (enterprise SSO that cannot be replayed)? Attach to an ALREADY-RUNNING "
                "dedicated instance (never seize the profile dir), ask the principal, then "
                "`touch /tmp/cto-allow-browser-attach` (one-shot, consumed on use) and re-run. "
                "Read: cto-orchestration/references/frontend-verify.md §工具选型 (浏览器归属).\n"
            )
            return 2

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(checker_error("internal guard failure."))
