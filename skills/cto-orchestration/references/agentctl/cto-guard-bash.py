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
#  (11) bare `codex exec|e|review` -> hand-rolled headless codex (no typed state, stdin-EOF hangs);
#       review dispatch goes through the lane's `agentctl start codex … --review` [DENY]
#  (14) `agentctl start <engine> <session> <cwd>` onto a DIRTY worktree -> the seat's own clean
#       gate reds on the orchestrator's uncommitted seed and STOPs before working [DENY]
#  (15) same dispatch with a surviving `<cwd>/BLOCKED.md` -> the new seat inherits a gate held
#       by its predecessor and has nowhere to write its own [DENY]
#  (18) `git commit --amend` / `cherry-pick` / `rebase` sharing one command with another step ->
#       a half-way rewrite leaves a state the command text cannot explain; one step per call [DENY]
#  (19) a command that `cd`s into repo A and then names repo B by RELATIVE path -> the batch runs
#       the wrong repo's suite (or 127s) while its `echo PASS` tail claims a gate [ALLOW + WARN]
#  (20) the ORCHESTRATOR writing a source/test path through one of three parseable literal-write
#       spellings (redirection / `tee` / in-place `sed`) — cto-guard-edit's E1 on this channel,
#       because auto mode prefers Bash over Edit|Write for editing files and E1 is dark there
#       (four spellings measured at rc=0, 2026-09-02). Seat attribution is IMPORTED from that
#       guard, never copied; uncovered channels are listed in README §强制层 [DENY]
#  (21) `agentctl steer … -m <inline text>` carrying a backtick or `$(` -> the shell expands it
#       BEFORE agentctl sees it: a quoted example command inside the steer body RUNS (2026-08-30
#       a `gh api …` example hit the real repo; the `>` in the same text truncated the message,
#       so agentctl could only report a parse error). Body goes in a file: `-f <path>`.
#       KILL CRITERION (owner 2026-09-02): zero hits in a year -> remove this rule. [DENY]
# Deny/checker error = exit 2 + stderr (shown to the agent). Remind = exit 0 + JSON
# hookSpecificOutput.additionalContext (only that reaches the agent). All-Python: the
# job is parsing arbitrary command content out of hook JSON — stdlib json is correct where shell-regex
# extraction would be fragile in a guard.
import sys, json, re, os, shlex, stat, subprocess, time


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


# ── shared pipeline face for rules (10) and (12) ─────────────────────────────────────────
# ONE shell approximation for both pipeline rules, not two (rule 12 was written against this
# extraction rather than re-inventing a second near-miss parser).
# View construction (review 2026-08-13, 1 blocker + 2 major all here): build from `raw`, NOT
# the space-flattened `cmd` — a second-line gate pipeline loses its command-position anchor
# (rule 8 learned the same lesson: newline = `;`). Then normalize the shell-executed token
# surface the way rule 9 does: join line continuations, park backslash-ESCAPED separators,
# drop `N>&M` redirects so a redirect's `&` doesn't end the segment scan, unquote simple tokens
# (`test/'run.sh'`), blank quoted spans that contain spaces/delimiters to an inert ARG (they are
# DATA — `echo '(bash test/run.sh | tail)'` must stay silent; `--filter 'a;b'` must not split
# the segment), drop unquoted `#` comments, strip backslashes.
# Separator escapes are parked, NOT stripped (review R1 M2): the blanket backslash strip would
# promote `agentctl stop s1 \| cat` — argv data — into a pipeline and DENY it. `\\` is a literal
# backslash ARGUMENT, so its pair is parked first and can never lend a backslash to the
# separator behind it. The parked characters are inert to every `[^;&|]` scan below.
_ESCAPED = {"|": "\x11", ";": "\x12", "&": "\x13", "#": "\x14"}


def _pipe_view(raw):
    v = re.sub(r"\\\r?\n", "", raw)
    v = v.replace("\\\\", "\x00")
    v = re.sub(r"\\([|;&#])", lambda m: _ESCAPED[m.group(1)], v)
    v = re.sub(r"\d*>&\d*", "", v)
    v = re.sub(r"([\"'])([^\s\"';|&()]*)\1", r"\2", v)
    v = re.sub(r"([\"'])[^\"']*\1", " ARG ", v)
    # an unquoted `#` opens a comment that runs to end of LINE, so its `|` is prose, not a pipe
    # (review R1 M2). AFTER quote blanking, so a `#` inside quoted data cannot eat the line.
    v = re.sub(r"(?m)(^|[ \t])#[^\n]*", r"\1", v)
    return v.replace("\n", ";").replace("\\", "").replace("\x00", "")


# Wrappers may carry option flags, env assignments and a duration operand (`env CI=1 bash`,
# `bash -e`, `command --`, `timeout 600 bash`, `timeout 5s bash`) — review 2026-08-17 B3:
# without them the anchor breaks and the weld shape sails through.
# `timeout` joins the list on extraction (rules 5 and 8 already carry it; rule 10's copy was the
# odd one out, so `timeout 600 bash test/run.sh | tail` masked its rc) — `timeout` precedes
# `time` so the shorter alternative cannot claim the prefix. Its operand is `timeout`'s ORDINARY
# duration syntax, not just an integer: `5s` / `0.5` / `2m` all reach the same binary (review R1
# M1). A wrapper flag that takes a SEPARATE non-numeric value (`timeout -s KILL 30 …`) still
# breaks the anchor: accept-documented, same blind-spot class as the rest of this approximation.
# Nested shells (`bash -lc '…'`) are OUT of both rules' reach BY CONSTRUCTION: the quoted body
# is blanked to ARG in the view — accept-documented boundary, same class as command substitution.
# An env VALUE containing spaces is a blanked ARG token by the time the anchor runs, so the
# assignment reads as `FOO=` + ` ARG ` — matching that shape is what keeps the documented
# `FOO="a b" agentctl stop s1 | cat` positive control reachable (review R1 B2).
_ENV_ASSIGN = r"\w+=(?:\s*ARG)?\S*"
_DURATION = r"\d+(?:\.\d+)?[smhd]?"
_WRAPPER = (r"(?:(?:\S*/)?(?:bash|sh|zsh|env|command|exec|nohup|timeout|time)"
            r"(?:\s+(?:-\S+|" + _ENV_ASSIGN + r"|" + _DURATION + r"))*\s+)*")


def _pos_head(seps):
    """Command position: start of text or one of `seps`, then env assignments, then wrappers."""
    return r"(?:^|[" + seps + r"]\s*)(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER


# (10)'s runners: the `.e2e.sh`-style NAMING families. Anchored on `^ ; & (` only — a gate is
# the thing being RUN, and rule 10's field cases are all head-of-segment.
_POS_RUNNER = _pos_head(r";&(") + r"\S*(?:\.test\.sh|test/run\.sh|retro-check\.sh)"
# (12)'s typed commands. `|` joins the separator set: a typed command in the MIDDLE of a
# pipeline is exactly the position this rule exists to catch.
# Binary identity is a BASENAME match, not a suffix: `fakeagentctl` is a different program and
# outside the command surface (review R1 M3).
# `gh` global flags may sit between the binary and its subcommand — in a multi-repo umbrella
# rule 8 REQUIRES `-R/--repo`, so without this the only legal spelling of `gh … --watch` here
# could never reach rule 12 (review R1 B1). Bounded to 3 pairs: enough for every real spelling,
# and a bound keeps the scan from wandering down a long argv.
# `--watch` is a BOOLEAN flag: bare or `=true` is watch mode; `--watch=false` (and anything else)
# is not, and is none of this rule's business (review R1 M4).
_AGENTCTL = r"(?:\S*/)?agentctl(?![\w-])"
_GH_GLOBAL = r"(?:(?:-R|--repo)\s+[^\s;|&]+\s+|--[\w-]+(?:=[^\s;|&]*)?\s+){0,3}"
_POS_TYPED = (_pos_head(r";&(|") +
              r"(?:" + _AGENTCTL + r"\s+(?:watch|steer|start|stop)\b"
              r"|(?:\S*/)?gh\s+" + _GH_GLOBAL +
              r"(?:pr\s+checks\b[^;&|]*--watch(?:=true)?(?![=\w-])|run\s+watch(?![\w-])))")


# ── rule (13) brief-wording advisory ─────────────────────────────────────────────────────
# SOURCE, exhaustively: the literal phrases that appear in the four cyberPolicy-blocked review
# dispatches (n=4, 2026-08), minimally redacted — nothing was invented to round the list out.
# `guard 绕过` from those prompts is carried by the bare `绕过` entry (a separate row would only
# double-report the same sentence). `probe` alone was considered and REJECTED: far too common in
# a verification brief to carry signal, so only the full `失败探针复跑` phrase is listed.
# NOT a semantic detector and never claimed to be: FP face = a brief legitimately quoting
# security terminology; FN face = any synonym rewrite (`circumvent`, `spoofed`, `impersonator`)
# and any inflection past the word boundary (`bypassed`).
_R13_TERMS = ("forged", "impostor", "attack payload", "bypass", "绕过", "失败探针复跑")
_R13_RE = re.compile("|".join(
    (r"\b" + r"\s+".join(re.escape(w) for w in t.split()) + r"\b") if t.isascii()
    else re.escape(t) for t in _R13_TERMS), re.I)
_R13_MAX = 256 * 1024
# Direct command-position dispatch only, judged on the SHARED pipeline view so that quoted data
# (`echo 'note; agentctl start codex … --goal x'`) cannot trigger an advisory about a command
# nothing is running (review R1 m1). The `--goal` path is then read off the RAW text, never off
# that view: `_pipe_view` blanks any quoted span containing a space to ARG, so a real path like
# `--goal '/tmp/wt a/brief.md'` is already destroyed there.
_R13_POS = re.compile(_pos_head(r";&(|") + _AGENTCTL + r"\s+start\s+codex\b")
_R13_HEAD = re.compile(_pos_head(";&(|\n") + _AGENTCTL + r"\s+start\s+codex\b")


def _r13_segment(text, start):
    """Text from `start` to the end of this shell segment, quotes respected (a `;` or `|`
    inside the brief path must not end it)."""
    quote = None
    for i in range(start, len(text)):
        c = text[i]
        if quote is not None:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c in ";|&\n":
            return text[start:i]
    return text[start:]


def _r13_goal_arg(seg):
    """(path, reason): the first `--goal` argument, or a reason it cannot be read.
    Both None = no `--goal` in this dispatch. Bounded extraction, NOT a shell parser: any
    expansion / escape / glob in the token is an admitted UNKNOWN, never a guess."""
    m = re.search(r"(?:^|\s)--goal(?:=|\s+)", seg)
    if not m:
        return None, None
    rest = seg[m.end():]
    if rest[:1] in ("'", '"'):
        end = rest.find(rest[0], 1)
        if end < 0:
            return None, "unparseable path"
        val = rest[1:end]
        # single quotes are literal; double quotes still expand $ ` \
        if rest[0] == '"' and re.search(r"[$`\\]", val):
            return None, "unparseable path"
        return (val, None) if val else (None, "unparseable path")
    tok = rest.split()[0] if rest.split() else ""
    # glob / brace / tilde metacharacters mean the shell hands the binary a DIFFERENT path than
    # the text says (`a[1].md` → `a1.md`), so the token is an admitted UNKNOWN rather than a
    # guess (review R1 M7). Ordinary filename punctuation (`- _ . + @ % = :`) stays extractable.
    if not tok or re.search(r"""[$`\\'"*?\[\]{}~]""", tok):
        return None, "unparseable path"
    return tok, None


# ── rules (14) and (15): dispatch preconditions on the seat's cwd ─────────────────────────
# The THIRD positional of `agentctl start <engine> <session> <cwd>`. Same bounded-extraction
# discipline as `_r13_goal_arg` (and the same vocabulary): the cwd comes BEFORE every flag in
# the CLI shape, so the first non-flag token after the session IS it, and any expansion /
# escape / glob makes the shell open a DIFFERENT directory than the text names -> UNKNOWN,
# never a guess. UNKNOWN means both rules stay silent; they judge a real directory or nothing.
def _start_cwd(seg):
    """The `<cwd>` positional of one `agentctl start` segment, or None when unreadable."""
    rest = seg
    while True:
        m = re.match(r"\s*(-{1,2}[\w-]+)(=\S*)?(?=\s|$)", rest)
        if not m:
            break
        rest = rest[m.end():]
    rest = rest.lstrip()
    if rest[:1] in ("'", '"'):
        end = rest.find(rest[0], 1)
        if end < 0:
            return None
        val = rest[1:end]
        if rest[0] == '"' and re.search(r"[$`\\]", val):
            return None
        return val or None
    tok = rest.split()[0] if rest.split() else ""
    if not tok or re.search(r"""[$`\\'"*?\[\]{}~]""", tok):
        return None
    return tok


# COMMAND POSITION, EVERY SEGMENT — the two properties (14)/(15) cannot be built without, both
# counter-probed against the R1 shape (cold review §2.1, §2.2). That version reused rule (3)'s
# unanchored `re.search` and read only its FIRST match, so `echo agentctl start omp s <cwd>` was
# DENIED as a dispatch (argv data promoted to a command) while `agentctl start … <clean>;
# agentctl start … <blocked>` PASSED (a real second dispatch never looked at). Rule (3)'s own
# reminder keeps its permissive matcher: an over-eager REMINDER costs a sentence, an over-eager
# DENY costs the seat its Bash tool.
# The segmenter is quote- and escape-aware so a `;` or `|` inside a brief path cannot end a
# segment (same property `_r13_segment` needed); each segment then starts AT command position by
# construction, so the head test is rule (10)/(12)'s shared anchor (`_ENV_ASSIGN` + `_WRAPPER`)
# applied to `_pipe_view` OF THAT SEGMENT — no second shell approximation. The cwd is extracted
# from the RAW segment, never the view, because the view blanks a quoted span containing a space
# (`'/wt a'`) to ARG.
# DECLARED BOUNDARY, inherited from that shared face rather than newly introduced: a dispatch
# buried in a nested shell (`bash -lc 'agentctl start …'`) is a blanked ARG in the view and is
# NOT judged — the same construction limit rules (10)/(12)/(13) carry. R1's text search did reach
# inside those quotes, but it reached inside `echo`'s too, and a rule that cannot tell a command
# from a string must not hold a DENY.
_SEG_HEAD = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER
                       + _AGENTCTL + r"\s+start\s+(?:omp|codex|claude)\b")
_SEG_START = re.compile(r"\bagentctl[\"'\s]+start[\"'\s]+(?:omp|codex|claude)[\"'\s]+"
                        r"[^\s\"';|&]+")
# R3 (verify §2.2 / N1): `_SEG_HEAD` decides WHETHER the segment is a dispatch on the VIEW (where
# a quoted env value is an opaque ARG), but `_SEG_START` then located the command on the RAW
# segment — so `X="agentctl start omp fake /tmp/fake" agentctl start omp real <dirty>` located
# the DECOY inside the env value and judged `/tmp/fake` instead of the real seat: probe rc=0
# where (14) owed a DENY. The two faces must agree on what is data. `_quote_blind` is that
# agreement made length-preserving: exactly the spans `_pipe_view` blanks to ARG (a quoted body
# carrying whitespace or a separator) get their CONTENT replaced 1:1 by \x01, so a match maps
# straight back onto raw offsets and `_r13_segment` keeps reading the RAW text — which is what
# lets a quoted cwd with spaces still be extracted. The quote DELIMITERS survive, so the
# `agentctl "start" omp` spelling `_SEG_START` accepts stays reachable.
_BLIND = "\x01"
_OPAQUE = re.compile(r"[\s\"';|&()]")


def _quote_blind(text):
    out, i, n = list(text), 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c not in "'\"":
            i += 1
            continue
        quote, j = c, i + 1
        while j < n:
            if text[j] == "\\" and quote == '"' and j + 1 < n:
                j += 2
                continue
            if text[j] == quote:
                break
            j += 1
        body = text[i + 1:j]
        if _OPAQUE.search(body):
            out[i + 1:j] = _BLIND * len(body)
        i = j + 1
    return "".join(out)


def _cmd_segments(text):
    """Every command-position segment of a shell command, quotes and backslash escapes
    respected. Separators are the ones the rest of this file treats as such (`; | & ( ) \\n`);
    an unquoted `#` opens a comment that runs to end of line, exactly as in `_pipe_view`."""
    segs, start, quote, i, n = [], 0, None, 0, len(text)
    while i < n:
        c = text[i]
        if quote is not None:
            if c == "\\" and quote == '"' and i + 1 < n:
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c in "'\"":
            quote = c
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n"):
            segs.append(text[start:i])
            nl = text.find("\n", i)
            if nl < 0:
                return segs
            start = i = nl + 1
            continue
        if c in ";|&()\n":
            segs.append(text[start:i])
            start = i + 1
        i += 1
    segs.append(text[start:])
    return segs


def _start_seats(raw, base):
    """Absolute `<cwd>` of EVERY command-position `agentctl start` in this command, in order.
    Unreadable positionals (expansion / glob / absent) are dropped, not guessed."""
    out = []
    for seg in _cmd_segments(raw):
        if not _SEG_HEAD.match(_pipe_view(seg)):
            continue
        # located on the BLINDED segment (offsets are raw's), read back off the RAW one
        hit = _SEG_START.search(_quote_blind(seg))
        if not hit:
            continue
        seat = _start_cwd(_r13_segment(seg, hit.end()))
        if seat:
            out.append(seat if os.path.isabs(seat) else os.path.join(base, seat))
    return out


def _git_porcelain(repo):
    """(dirty, decided, available). `decided` False = git answered but does not own this tree ->
    the rule skips silently, as contracted. `available` False = the INSTRUMENT failed (no git,
    timeout, OSError) -> the caller says so out loud instead of allowing in silence: a meter that
    cannot measure is not a green meter (cold review §4.2). Never a DENY on an undecidable tree:
    rule (14) exists to stop a dispatch onto an uncommitted seed, not to gate directories git
    does not own."""
    try:
        proc = subprocess.run(["git", "-C", repo, "status", "--porcelain"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        return False, False, False
    if proc.returncode != 0:
        return False, False, True
    return bool(proc.stdout.strip()), True, True


def _blocked_stands(path):
    """(stands, measured) for a seat's `BLOCKED.md`. `stands` True = SOMETHING is at that path —
    file or directory, both wedge the next seat identically (cold review §2.3). `measured` False
    = the INSTRUMENT could not answer (permissions, dead mount, symlink loop, I/O), which is NOT
    the same reading as "nothing there" — and `os.path.exists` returns False for BOTH, so a
    seat this guard could not look at read exactly like a harvested one (verify R3 §4.3, the
    shape §4.2 already fixed for (14)). Absence is the errno family that MEANS absence
    (`ENOENT`, and `ENOTDIR` for a non-directory seat); every other OSError is unmeasured, and
    the caller says so out loud instead of allowing in silence. Never a DENY on an unmeasured
    seat: (15) exists to stop a dispatch onto a HELD gate, not to gate an unreadable path."""
    try:
        os.stat(path)
    except (FileNotFoundError, NotADirectoryError):
        return False, True
    except OSError:
        return False, False
    return True, True


def _brief_review(raw, vpipe, cwd):
    """(reason, hits, path) for the first direct `agentctl start codex … --goal <f>`.
    All-None = nothing to say; `reason` = a SHORT why-not, `hits` = matched phrases.

    Returns DATA, never prose: the injected-text ratchet (test/context-budget.test.sh) weighs
    string literals at the sink, so a message assembled in a helper would be spent unweighed.
    ADVISORY: every failure path yields a reason and the caller still exits 0. The blanket
    except is load-bearing, not laziness — an escaping exception is caught by the __main__
    wrapper as CHECKER-ERROR (exit 2), which would silently promote this reminder into a DENY
    of a legal dispatch. A wording hint must never be able to block one."""
    try:
        if not _R13_POS.search(vpipe):   # quoted data is not a dispatch
            return None, None, None
        m = _R13_HEAD.search(raw)
        if not m:
            return None, None, None
        # first dispatch only, declared boundary: a command chaining two `start codex` calls
        # gets its second brief unread (chaining dispatches is not the shape we optimize for)
        path, reason = _r13_goal_arg(_r13_segment(raw, m.end()))
        if reason or path is None:
            return reason, None, None
        full = path if os.path.isabs(path) else os.path.join(cwd, path)
        st = os.lstat(full)  # lstat, deliberately: a symlinked brief is reported, not followed
        if stat.S_ISLNK(st.st_mode):
            return "symlink", None, None
        if not stat.S_ISREG(st.st_mode):
            return "not a regular file", None, None
        if st.st_size > _R13_MAX:
            return "larger than 256KB", None, None
        with open(full, "rb") as fh:
            blob = fh.read(_R13_MAX + 1)
        # the size VERDICT comes from the bytes actually read, not the lstat snapshot: the file
        # can grow between stat and open, and a lying/racing stat must not buy an unbounded
        # inspection (review R1 m2). The read itself was already bounded to MAX+1.
        if len(blob) > _R13_MAX:
            return "larger than 256KB", None, None
        body = blob.decode("utf-8")
    except FileNotFoundError:
        return "missing", None, None
    except UnicodeDecodeError:
        return "not UTF-8", None, None
    except Exception:
        return "unreadable", None, None
    return None, sorted({h.lower() for h in _R13_RE.findall(body)}), path


# ── rule (16): babysit-round counter (WARN, never DENY) ───────────────────────────────────
# KILL CRITERION (slug `g16-babysit-counter`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill.
# FIELD: a session whose classify said 14 with the gauge blind was re-hung SIX times in a row
# (2026-08/09) — each re-hang cost a round and none of them looked at the instrument. Re-hanging
# a watcher is LEGAL (that is why this can never be a DENY); doing it a fourth time on the same
# session in one day is the signal that the orchestrator is babysitting instead of diagnosing.
# COUNTED: command-position `agentctl watch <s>` and `agentctl steer <s>`. An `--interrupt`
# steer (and its silent alias `--replace`) is a deliberate intervention, not a re-hang, so it is
# NOT counted. A session is counted ONCE per command: the standard `steer …; watch …` pair is
# one babysit round, not two.
# METER: `<AGENT_WATCH_DIR|/tmp/agent-watch-run>/babysit-<YYYYMMDD>.json`, a day-stamped
# `{session: count}` map — the DATE IS THE ROLL (yesterday's file is simply never read) and the
# uid keeps two users on one host out of each other's tally. Every read and write is wrapped:
# an exception escaping here is CHECKER-ERROR (exit 2) at the __main__ wrapper, i.e. a broken
# tally would take the orchestrator's whole Bash tool with it. A meter that cannot count is
# SILENT (no warn, no deny); a count that could not be persisted still warns and says the
# number is a floor — 不可判, never dressed as a measurement.
_R16_WARN_AT = 4
_SEG_BABYSIT = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER
                          + _AGENTCTL + r"\s+(?P<verb>watch|steer)(?:\s+(?P<sess>\S+))?")
_R16_INTERRUPT = re.compile(r"(?:^|\s)--(?:interrupt|replace)(?=\s|$)")


def _babysit_sessions(raw):
    """Sessions this command re-hangs, in order, deduped. Same segmenter + command-position
    head as rules (14)/(15) — a quoted mention (`echo 'agentctl watch s1'`) is DATA and is
    never counted. A session token that is a flag, or the blanked `ARG` of a quoted span with
    spaces, is UNREADABLE and dropped rather than counted under a made-up name."""
    out = []
    for seg in _cmd_segments(raw):
        view = _pipe_view(seg)
        m = _SEG_BABYSIT.match(view)
        if not m:
            continue
        sess = m.group("sess")
        if not sess or sess == "ARG" or sess.startswith("-"):
            continue
        # the flag sits AFTER the session, so the exclusion reads the whole segment, never the
        # matched head (`m.group(0)` stops at the session and every steer looked mechanical)
        if m.group("verb") == "steer" and _R16_INTERRUPT.search(view):
            continue
        if sess not in out:
            out.append(sess)
    return out


def _babysit_bump(session):
    """(count, degraded) for today's tally of one session, INCLUDING this call.
    `count` None = the meter could not answer at all -> the caller stays silent. `degraded`
    True = the number is a FLOOR, which the warn says out loud instead of publishing a floor
    as a count.

    THE FLOOR FLAG IS PERSISTED, not per-process (cold review F2): a corrupt ledger loses the
    day's history, and the process that resets it knows that — but the NEXT process reads a
    perfectly well-formed file and would publish `4 times today` as an exact reading of a day
    it never saw the start of. So the day's record carries the fact: `{"floor": <bool>,
    "n": {session: count}}`, and `floor` is STICKY for the rest of that day (it is read back
    in and written back out). One shape consequence, deliberate: any file that is not this
    shape — including the pre-flag flat map — is UNKNOWN HISTORY, so it resets AND raises the
    flag rather than being adopted as a count. The file is day-stamped, so the cost is bounded
    to one day's tally on the machine that upgrades mid-day.
    The unwritable-meter path cannot persist anything BY DEFINITION; it returns the floor
    verdict for its own call, and the next call re-reads whatever the file still says."""
    run_dir = os.environ.get("AGENT_WATCH_DIR") or "/tmp/agent-watch-run"
    path = os.path.join(run_dir, "babysit-%d-%s.json" % (os.getuid(), time.strftime("%Y%m%d")))
    soft = False
    try:
        with open(path, "r", encoding="utf-8") as fh:
            record = json.load(fh)
        counts = record.get("n") if isinstance(record, dict) else None
        if isinstance(counts, dict):
            tally, soft = counts, bool(record.get("floor"))
        else:
            tally, soft = {}, True   # unknown shape = unknown history
    except FileNotFoundError:
        tally = {}
    except (ValueError, UnicodeDecodeError):
        tally, soft = {}, True   # corrupt ledger: rebuild it, and admit the count is a floor
    except Exception:
        return None, True
    n = tally.get(session)
    n = (n if isinstance(n, int) and n >= 0 else 0) + 1
    tally[session] = n
    try:
        os.makedirs(run_dir, exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"floor": soft, "n": tally}, fh)
        os.replace(tmp, path)   # one rename: a concurrent guard never reads a half-written map
    except Exception:
        return n, True
    return n, soft


# ── rule (17): review dispatch without a round budget (DENY) ──────────────────────────────
# KILL CRITERION (slug `g17-review-budget`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill.
# FIELD: a review loop with no declared ceiling is an arms race — the reviewer keeps finding,
# the seat keeps fixing, and nobody owns the round count (downstream DEV-tier batch ran 3
# rounds on advisory findings, 2026-08/09). The budget must be stated at DISPATCH time, where
# it is cheap; `--max-rounds` is the only thing the runtime enforces (SKILL §2), so a review
# seat started without it has no ceiling anywhere.
# SHAPE: command-position `agentctl start codex … --review` with no `--max-rounds` IN OPTION
# POSITION. The lane itself refuses `--review` with `--resume-thread`, so that pair is not
# judged twice here.
# OPTION ARITY IS LOAD-BEARING (cold review F1, three counter-probes): a flat membership test
# over `view.split()` reads a valued option's ARGUMENT as if it were a flag, and that one root
# cause faces both ways — `--goal '--review'` was DENIED (a legal dispatch, argv data promoted
# to a flag) while `--goal '--max-rounds' --review` and `--goal '--resume-thread' --review`
# PASSED (a real unbudgeted review loop bought its way out with a filename). So the scan
# mirrors `agentctl start`'s own argv rules (agentctl:183-198): these six options consume the
# NEXT token, which is therefore DATA and can never be a flag; every other token — the
# valueless `--no-preflight` / `--require-preflight` / `--review`, any `--x=y` joined form, and
# each unrecognized token the lane forwards as EXTRA — advances by one, exactly as its `*)` arm
# does. `--max-rounds=2` still reads as no budget, which is correct: agentctl parses only the
# separated spelling and would refuse the joined one (accept-documented false positive whose
# fix line is the spelling the lane accepts).
# WORD BOUNDARIES ARE PART OF THE ARITY (R2 verify, the same root cause one layer down): the
# shared `_pipe_view` strips backslashes, so `--goal x\ --max-rounds\ y` — ONE argv word to the
# shell — arrived at the walk as three, and the `--max-rounds` buried inside the value was
# promoted to a budget flag (the quoted spelling of the same value was already correct: the
# view blanks it to `ARG`). An arity walk that splits differently than the shell does is not
# reading argv. So rule (17) — and ONLY rule (17), no other rule's view moves — scans a view
# where an escaped space/tab is PARKED into a sentinel instead of being unescaped into a
# separator, exactly the trick `_ESCAPED` already plays for escaped shell separators.
# PARITY, load-bearing for the same reason rule 8's line-continuation fold needed it: only an
# ODD run of backslashes escapes the whitespace. `x\\ --max-rounds 2` is the word `x\` followed
# by a REAL separator and a REAL option, so the pattern anchors on a non-backslash (or string
# start), keeps whole `\\` pairs, and consumes only the final lone backslash plus its space.
# The sentinel is inert to `str.split()` and can never equal an option name, so a value that
# contains one is data all the way through.
_ESC_WS = "\x15"


def _arity_view(seg):
    """`_pipe_view` of one segment with escaped whitespace held INSIDE its word."""
    return _pipe_view(re.sub(r"(^|[^\\])((?:\\\\)*)\\([ \t])", r"\g<1>\g<2>" + _ESC_WS, seg))


_START_VALUED = {"--goal", "--deliverable", "--workflow", "--max-rounds",
                 "--resume-thread", "--model"}
_SEG_REVIEW = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER
                         + _AGENTCTL + r"\s+start\s+codex(?![\w-])")


def _start_option_flags(rest):
    """Options in OPTION POSITION for one `agentctl start …` tail (`rest` = the text after the
    engine). The positionals are skipped by the CLI's own shape — `<session> <cwd>` come BEFORE
    every flag, the property `_start_cwd` already relies on — and a valued option's argument is
    skipped as the DATA it is, never inspected."""
    toks = rest.split()
    i = 0
    while i < len(toks) and not toks[i].startswith("-"):
        i += 1
    flags = set()
    while i < len(toks):
        tok = toks[i]
        if tok.startswith("-"):
            flags.add(tok)
            i += 2 if tok in _START_VALUED else 1
            continue
        i += 1   # a stray positional past the flags: not an option, judged by nobody
    return flags


def _review_without_budget(raw):
    """True when any command-position codex dispatch asks for a review seat with no budget."""
    for seg in _cmd_segments(raw):
        view = _arity_view(seg)
        head = _SEG_REVIEW.match(view)
        if not head:
            continue
        flags = _start_option_flags(view[head.end():])
        if "--review" not in flags or "--resume-thread" in flags:
            continue
        if "--max-rounds" not in flags:
            return True
    return False


# ── rule (18): a history rewrite is its own step (DENY) ───────────────────────────────────
# KILL CRITERION (slug `g18-rewrite-single-step`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill.
# FIELD (downstream seats, n=2, ~30 min recovery each): `git commit --amend` / `cherry-pick` /
# `rebase` welded into a compound chain. Shell chains are LEFT-ASSOCIATIVE, so in `a && b || c &&
# d` the `||` arm binds the whole left chain and NOT the step that failed: a rewrite that dies
# half-way leaves index + worktree in a state whose owner cannot be read off the command text
# (which step ran? which one is being retried?), and recovery is a reflog walk. These three verbs
# are the only git commands that rewrite ALREADY-COMMITTED history in place, i.e. the only ones
# whose half-done state cannot be re-derived by re-reading the command.
# SHAPE: a command-position rewrite invocation in a command holding >=2 command-position steps.
# `&&`, `||`, `;` and multi-segment pipelines all count — the hazard is "more than one step in one
# tool call", not any particular operator.
# EXEMPTION, load-bearing: ONE leading `cd /abs &&` is rule (8)'s PRESCRIBED anchoring idiom, and
# env assignments live INSIDE the segment they prefix. Denying `cd /abs && git rebase --continue`
# would put this rule in a fight with rule (8), whose own fix line hands out that exact spelling.
# Exactly one anchor is discounted (`cd /abs && git rebase && git push` is still two steps) and
# the `&&` is required — after a `;` the cd may have failed, rule (8)'s ruling and the same reason.
# `--continue` / `--abort` / `--skip` are judged identically: resuming IS the half-way state both
# field cases died in.
# ACCEPTED FALSE POSITIVE, stated with its recovery: `git rebase --continue; echo rc=$?` is
# denied. The doctrine's answer is the deny message's own — the tool already reports rc for a
# single command, so run the rewrite alone and read it there; rule (12)'s file-first shape exists
# for commands whose verdict a PIPELINE would swallow, which is not this one.
# COMMAND POSITION, on `_cmd_segments` + the shared `_pipe_view`: a rewrite verb inside a quoted
# string, a comment or a heredoc BODY is document text and not a step — the caller passes the
# heredoc-stripped view for exactly that reason.
_R18_VERBS = {"rebase", "cherry-pick"}
# git's valued GLOBAL options: each consumes the NEXT token, which is therefore DATA and can never
# be the subcommand (`git -c alias.x=rebase status` is not a rebase). Same arity discipline rule
# (17) had to learn, applied to git's own argv.
_GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
               "--config-env", "--super-prefix"}
# `git commit`'s options that take a SEPARATE value: each consumes the NEXT token, so a MESSAGE
# that happens to read `--amend` is argv data, not a flag.
_COMMIT_VALUED = {"-m", "--message", "-F", "--file", "--author", "--date", "-C",
                  "--reuse-message", "-c", "--reedit-message", "--fixup", "--squash",
                  "--cleanup", "-t", "--template", "--trailer", "--pathspec-from-file"}
# NOT listed above, and that is the whole point (review F2/finding 2): `-S[<keyid>]` /
# `--gpg-sign[=<keyid>]` / `-u[<mode>]` / `--untracked-files[=<mode>]` are OPTIONAL-ATTACHED —
# `git commit -h` publishes them with the value GLUED to the flag, so the next token is NEVER
# theirs. Listing them as valued swallowed the real flag behind them, and
# `git commit -S --amend && echo done` sailed straight through the gate this rule IS (probe rc=0
# where a DENY was owed). They fall through to the advance-by-one arm, which is correct for them.
_SEG_GIT = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER
                      + r"(?:\S*/)?git(?![\w-])(?P<rest>.*)$", re.S)
# The anchor is decided on the RAW text, not on `_pipe_view` (review F2/finding 7): the view blanks
# a quoted span carrying a space to ` ARG `, which destroys exactly the leading `/` that makes the
# path absolute — so rule (8) accepted `cd "/abs/repo space" && …` as an anchor while this rule
# counted it as an extra step and denied a legal single-step rewrite. Both spellings of one path
# must get one verdict. The step COUNT still comes from the view; only the absolute-ness question
# is asked of the raw text.
_R18_ANCHOR = re.compile(r"\s*(?:" + _ENV_ASSIGN + r"\s+)*cd\s+"
                         r"(?:\"/[^\"\n]*\"|'/[^'\n]*'|/[^\s;|&]*)\s*&&")
# …and the first VIEW segment must itself be that `cd` step, so the discount can only ever be
# spent on a cd (never on a rewrite that happens to follow an absolute path in the text).
_R18_CD_STEP = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*cd\s+\S+\s*$")


def _git_argv(rest):
    """(subcommand, tokens after it) for one `git …` tail; (None, []) when there is no subcommand
    (`git --version`). Valued global options are skipped WITH their value."""
    toks, i = rest.split(), 0
    while i < len(toks):
        t = toks[i]
        if not t.startswith("-"):
            return t, toks[i + 1:]
        i += 2 if (t in _GIT_VALUED and "=" not in t) else 1
    return None, []


def _rewrites_history(view):
    """True when this command-position segment view is an in-place history rewrite."""
    head = _SEG_GIT.match(view)
    if not head:
        return False
    sub, rest = _git_argv(head.group("rest"))
    if sub in _R18_VERBS:
        return True
    if sub != "commit":
        return False
    i = 0
    while i < len(rest):          # `--amend` must sit in OPTION position, not in a message
        t = rest[i]
        if t == "--":
            return False          # option terminator: everything after it is pathspec DATA
        if t == "--amend":
            return True
        if not t.startswith("-"):
            return False
        i += 2 if (t in _COMMIT_VALUED and "=" not in t) else 1
    return False


def _rewrite_in_chain(raw):
    """True when a history rewrite shares one tool call with another step."""
    steps = [s for s in _cmd_segments(_pipe_view(raw)) if s.strip()]
    # rule (8)'s prescribed `cd <ABS> &&` anchor, discounted exactly ONCE. Two faces must AGREE
    # here: the first STEP is a `cd` (asked of the view, where the step boundaries are) and its
    # target is ABSOLUTE (asked of the raw text, where a quoted path still has its leading `/`).
    if steps and _R18_CD_STEP.match(steps[0]) and _R18_ANCHOR.match(raw):
        steps = steps[1:]
    return len(steps) > 1 and any(_rewrites_history(s) for s in steps)


# ── rule (19): a verification batch that drifts across repos (WARN, never DENY) ────────────
# KILL CRITERION (slug `g19-cwd-drift`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill.
# FIELD (downstream verification batches, n=4): the command `cd`s into repo A and then names a
# path RELATIVE to repo B (`cd /umb/a && bash b/test/run.sh && echo PASS`). Two ways it lies: the
# path misses and the runner 127s, or — worse — the same relative path EXISTS in repo A, so the
# batch runs the wrong repo's suite and its `echo PASS` tail reports a gate that never ran.
# WARN ONLY, by owner ruling for this batch: one cwd per command is a discipline, and a relative
# path naming another repo is legal shell (a monorepo-style invocation from the umbrella root is
# the same text). False-positive rate decides whether this ever becomes a DENY.
# REGISTER: the mechanically available face only — the umbrella root's immediate children that
# carry a `.git` (which is also where `git worktree list`'s roots land: a worktree umbrella's
# children each carry a `.git` FILE). No subprocess, one `listdir`. A gauge that cannot list is
# SILENT — never a guess, same contract as rules (14)/(15)/(16).
# BOUNDARY: `here` is only set by a `cd` whose target IS a registered repo root or lies INSIDE
# one, decided by PATH (review F5/finding 5), and a later `cd` elsewhere CLEARS it — the premise
# of this rule is "you told me which repo you are in". An earlier cut asked whether any COMPONENT
# of the cd target matched a registered NAME, so `cd /somewhere/otherrepo/not-a-repo` (a directory
# that merely shares a name) set `here='otherrepo'` and the warn then announced a repo the command
# was never in. A name is not a location; the register therefore carries ROOTS, not just names.
def _umbrella_near(path):
    """The umbrella ROOT at or within 5 ancestors of `path` (>=2 immediate children with .git),
    or None. Rule (8)'s scope gate; rule (19)'s repo register reads the same root."""
    try:
        p = os.path.realpath(path)
    except Exception:
        return None
    for _ in range(6):  # cwd + 5 ancestors (range(5) undershot the documented contract)
        try:
            kids = os.listdir(p)
        except OSError:
            return None
        n = 0
        for k in kids:
            if os.path.exists(os.path.join(p, k, ".git")):
                n += 1
                if n >= 2:
                    return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent
    return None


# ── rule (8) scope narrowing: is the cwd's own repo THIS session's project root? ───────────
# FIELD MEASUREMENT (two machines, 2026-09-02): of 728 real guard DENYs, 598 were rule (8) —
# and by hook cwd every one of the biggest buckets was the session's OWN project root (~246 of
# them in the top five alone), i.e. commands that could not have hit the wrong repo. Only ~40
# sat in a genuinely umbrella (non-repo) directory. Each false DENY costs a tool call + a rewrite.
# THE DISCRIMINATOR, and why it is sound rather than clever: in Claude Code the shell cwd is
# PERSISTENT inside the project tree and a `cd` out of the project root is RESET on the next
# call ("Shell cwd was reset to <dir>"), so a cwd whose own git top level IS the session's
# project root cannot be a drifted cwd pointing at a sibling repo — the 2026-07-26 accident
# (session root = umbrella, cwd cd'd into one repo, bare `gh` hit another) keeps its DENY
# because THERE the session root is the umbrella, not the repo.
# The session root is read off `transcript_path` (an official PreToolUse common input field):
# `~/.claude/projects/<slug>/<session>.jsonl`, where <slug> is the project root with every
# non-[A-Za-z0-9] character replaced by `-`. That encoding is NOT a published contract — it is
# an empirical regularity (27 project dirs on this machine: 26 matched slug(the recorded cwd of
# their newest transcript), the 1 miss being a directory whose repo had MOVED). So the test is
# used in exactly ONE direction: equality ALLOWS, everything else keeps the existing DENY —
# a codex seat (whose payload carries no `transcript_path`), a repo NESTED inside the umbrella,
# a sibling repo and an umbrella session root all stay denied.
# FAIL-OPEN, the one shape that is NOT on that list (an earlier revision of this comment claimed
# an unreadable cwd stayed denied; the implementation and its oracle both say otherwise): an
# unreadable cwd never reaches this test at all, because the scope gate ahead of it —
# `_umbrella_near` — cannot list the directory and returns None, so rule (8) NEVER EVALUATES.
# Oracle: assertion `unreadable cwd fails open`.
# SAME FAIL-OPEN DIRECTION, scope-gate shape: an outer repo holding a SINGLE nested repo, with no
# umbrella within 5 ancestors, never has >=2 git children on the scan path, so the rule does not
# evaluate there either. Accept-documented and pinned as
# `r8-doc-nested-no-umbrella-never-evaluates`, with a control that adds one more direct child and
# flips the same workspace back to DENY.
# A SYMLINKED cwd is judged by realpath (`_git_top` and `_umbrella_near` share that 口径): the
# slug is compared against the RESOLVED repo root, so a cwd that reaches a repo root through a
# link whose own path slugs differently keeps the DENY — the conservative direction, pinned as
# `r8-neg-symlinked-cwd`.
# The encoding is also NOT injective (`/tmp/a.b` and `/tmp/a-b` share a slug), so two sibling
# repos differing only in punctuation would license each other. Accept-DOCUMENTED and pinned as
# `r8-doc-slug-collision`, not defended by machinery: it takes a hand-built pair of repo names
# inside one umbrella, and the direction is ALLOW on a workspace the orchestrator built itself.
_SLUG = re.compile(r"[^A-Za-z0-9]")


def _git_top(path):
    """The nearest ancestor of `path` (symlinks resolved) carrying a `.git` file OR directory,
    or None. Same realpath口径 as `_umbrella_near`, and NO subprocess: this runs on every
    umbrella-scoped git/gh command, where `git rev-parse` would add a process spawn to a path
    that already pays one `listdir` per ancestor."""
    try:
        p = os.path.realpath(path)
    except Exception:
        return None
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def _cwd_is_session_root(cwd, transcript):
    """True when the repo enclosing `cwd` IS the project root this session was started in.
    False on every unanswerable case (no/odd `transcript_path`, no enclosing repo, unreadable
    path) — the ALLOW is the narrow claim, the DENY is the default."""
    if not isinstance(transcript, str) or not transcript:
        return False
    slug = os.path.basename(os.path.dirname(transcript))
    if not slug:
        return False
    top = _git_top(cwd)
    return top is not None and _SLUG.sub("-", top) == slug


def _registered_repos(cwd):
    """{repo NAME: absolute repo ROOT} for the umbrella's immediate git children, or {} when the
    register cannot be measured (both cases read the same to the caller: silence)."""
    root = _umbrella_near(cwd)
    if root is None:
        return {}
    try:
        kids = os.listdir(root)
    except OSError:
        return {}
    out = {}
    for k in kids:
        p = os.path.join(root, k)
        if os.path.exists(os.path.join(p, ".git")):
            out[k] = os.path.realpath(p)
    return out


_R19_CD = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*cd\s+(?P<path>[^\s;|&]+)")
_R19_REL = re.compile(r"(?:\./)?(?P<head>[^/\s]+)/")


def _cd_lands_in(target, base, repos):
    """The registered repo NAME whose root contains (or IS) this `cd` target, else None.
    Unreadable/expanding targets resolve to a path that matches nothing, i.e. to None."""
    try:
        p = os.path.realpath(target if os.path.isabs(target) else os.path.join(base, target))
    except Exception:
        return None
    for name, root in repos.items():
        if p == root or p.startswith(root + os.sep):
            return name
    return None


def _cwd_drift(raw, repos, base):
    """(repo you cd'd into, offending token) for the first relative path naming a DIFFERENT
    registered repo after such a cd, or (None, None)."""
    here = None
    for seg in _cmd_segments(_pipe_view(raw)):
        cd = _R19_CD.match(seg)
        if cd:
            here = _cd_lands_in(cd.group("path"), base, repos)
            continue
        if here is None:
            continue
        for tok in seg.split():
            rel = _R19_REL.match(tok)
            if rel and rel.group("head") in repos and rel.group("head") != here:
                return here, tok
    return None, None


# ── rule (20): the orchestrator writing SOURCE through bash (DENY) ────────────────────────
# KILL CRITERION (slug `g20-bash-direct-write`, retro GATE-AUDIT): hits=0 ∧ false>=2 ⇒ kill;
# plus two of its own — a LIVE seat falsely denied inside its own worktree even once means the
# attribution is broken before the rule is worth keeping, and a non-literal WARN that fires
# >=10 times in a week without ever standing over a real source write goes silent.
# WHY THIS EXISTS: E1 (cto-guard-edit.py) is the SAME rule on the Edit|Write channel, and in
# auto mode the harness explicitly prefers Bash (heredoc / sed / a script) for editing files —
# so E1 is a paper door there. Measured 2026-09-02, by the orchestrator and again by a cold
# review: a heredoc write, an append redirect, a `tee` and a `sed -i` onto a repo `.py` all
# returned rc=0 with zero output from this guard.
# THE CLOSED SET, enumerated HERE because README §强制层 keeps only the reader's three sentences —
# it is a set of SPELLINGS this file can parse, never a claim about shell writes in general:
#  (a) REDIRECTIONS naming a path: `>` `>>` `&>` `&>>` `N>` `N>>`. `_R20_OP` locates every
#      operator and `_R20_WRITE_OP` picks the writing ones; `>&N` / `N>&M` is fd DUPLICATION and
#      not a write (`_R20_DUP` below).
#  (b) EVERY path argument of `tee`, not just the first — `-a` and `--` are handled by
#      `_positionals`, and one match anywhere in that argv denies.
#  (c) `sed` rewriting in place, all five spellings `_sed_in_place` accepts: `-i`, `-i.bak`
#      (attached suffix), `-i SUF` (BSD separated suffix), `--in-place`, `--in-place=SUF`, plus
#      short-flag clusters carrying `i` (`-ni`). With `-i SUF` the suffix token is judged like
#      every other positional of that segment, which is correct under either parse: a suffix
#      (`.bak`) and a script (`s/a/b/`) both fail the source face harmlessly.
# ACCEPT-UNCOVERED, said out loud instead of implied: `cp` / `mv` / `install` / `dd of=` /
# `rsync` / `git apply` / `patch` / an editor / a write from INSIDE an interpreter
# (`python - <<EOF` … `open().write`). A gate that implied coverage it does not have would be
# worse than the gap. ONE more uncovered shape, with an oracle of its own: a heredoc opener
# sitting in COMMENT text (`echo ok # <<EOF`) is taken for a real opener by the SHARED
# `_heredoc_scan`, so every line after it is invisible to the rules reading that scan's
# non-quoted-only view (`raw_hd`: rules (8)/(18)/(19)/(20)) — including a real source write on
# the next line. The quoted-only readers are unaffected (that pass strips `<<'TAG'` / `<<"TAG"`
# only). Fixing it means moving the shared face, i.e. another batch; today's behaviour is pinned
# as `r20-doc-comment-heredoc-opener-uncovered`, so whoever moves that face sees it go red.
# JUDGED ON AN EXECUTION FACE OF THIS RULE'S OWN, and `_pipe_view` could not be it (cold review
# R1 F1, both spellings counter-probed at rc=0): that view BLANKS a multi-word quoted span to
# `ARG` and STRIPS backslashes, so `> "/a b/x.py"` and `> /a\ b/x.py` — two ordinary spellings of
# one real file — arrived with no target at all and were silently allowed. A write target has to
# be read the way the SHELL reads it. The idiom is the one rules (14)/(17) already established
# for exactly this problem: a LENGTH-PRESERVING blind decides WHERE the operators are, and the
# ORIGINAL bytes at those offsets are then unquoted to recover the path — one face, two reads,
# no third parser. `_write_face` IS that blind: the content of a QUOTED span, a backslash-ESCAPED
# byte and an unquoted `#` comment each collapse to a sentinel, which is what lets a space-bearing
# literal path still be recovered from the original bytes — `> "…/a b/x.py"` and `> …/a\ b/y.py`
# name one real file and both DENY (`r20-recall-quoted-space` / `r20-recall-escaped-space`).
# Three properties fall out and all three are load-bearing: a `>` inside quotes, behind a `#`
# comment, or in a heredoc BODY is DATA and can never be an operator (`echo "a > b.py"`,
# `echo ok # > x.py`, and a brief that documents a redirect, all stay silent); `2>&1` / `>&2` are
# matched as duplication operators in their own right, so the word behind them is never read as a
# file; and a MISSING target (a bare trailing `>`) is not a write, so the rule stays SILENT
# instead of guessing at one.
# VERDICT DIRECTION WHEN THE PATH IS NOT LITERAL: a target carrying an expansion (`$x`, a
# backtick, `$(`), a glob (`* ? [`) or a leading `~` is OPAQUE — the shell would open a file this
# guard never read — so it is ALLOW + one WARN, and the one-shot override marker is NOT consumed.
# Spending an approval on a verdict nobody reached would retire it silently.
_R20_BLIND = "\x01"
# A COMMENT is not data inside a word — it is text the shell never hands to any program, so it
# gets its OWN sentinel and `_seg_tokens` drops it like whitespace (R2-1: sharing `_R20_BLIND`
# left the comment as a same-length WORD, which was then read back off the raw text and became a
# `tee`/`sed` argv — `tee #comment.py` was DENIED for a file no shell ever opens, and
# `echo x > #comment.py`, which the shell rejects for a missing operand, was denied too).
_R20_COMMENT = "\x02"


def _write_face(text):
    """`text` with the CONTENT of every quoted span, every backslash escape and every unquoted
    `#` comment replaced 1:1 by a sentinel. Length-preserving, so an offset in this face is an
    offset in `text`: operators are located here, bytes are read there. An unterminated quote
    blinds to end of text — the conservative direction, since nothing after it is executable."""
    out, i, n = list(text), 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out[i] = out[i + 1] = _R20_BLIND     # `\>` is not an operator, `\ ` not a separator
            i += 2
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;|&()"):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = _R20_COMMENT * (j - i)
            i = j
            continue
        if c not in "'\"":
            i += 1
            continue
        quote, j = c, i + 1
        while j < n:
            if text[j] == "\\" and quote == '"' and j + 1 < n:
                j += 2
                continue
            if text[j] == quote:
                break
            j += 1
        out[i + 1:j] = _R20_BLIND * (len(text[i + 1:j]))
        i = j + 1
    return "".join(out)


def _write_segments(face):
    """(start, end) of every command-position segment of the blinded face. An `&` that belongs
    to a redirect (`&>` / `&>>`) or to a duplication (`>&`) is NOT a separator — splitting there
    would tear the operator off its operand."""
    segs, start, i, n = [], 0, 0, len(face)
    while i < n:
        c = face[i]
        if c == "&" and (face[i + 1:i + 2] == ">" or face[i - 1:i] == ">"):
            i += 1
            continue
        if c in ";|&()\n":
            segs.append((start, i))
            start = i + 1
        i += 1
    segs.append((start, n))
    return segs


# Redirect operators, longest alternative first. A DUPLICATION carries its operand INSIDE the
# operator (`2>&1`, `>&2`, `<&0`, `>&-`), so it neither writes a file nor consumes the next word
# — R2-2: treating it like every other operator swallowed the real argv behind it and
# `tee 2>&1 <repo>/x.py` sailed through. The right side must therefore be a FD or `-`: bash
# reads `>&word` with a non-numeric word as "both streams to that FILE", and that spelling falls
# through to the plain `>` arm below, where the word IS read as the target. `&>` / `&>>` send
# both streams to a file; the `<`-family is matched only to CONSUME its operand — a heredoc tag,
# an input file and `_strip_heredocs`'s `<<<HEREDOC-BODY-STRIPPED>>>` marker are not writes.
_R20_DUP = re.compile(r"\d*[<>]&(?:\d+|-)")
_R20_OP = re.compile(r"\d*[<>]&(?:\d+|-)|&>>|&>|\d*>>|\d*>|<<-|<<<|<<|<")
_R20_WRITE_OP = re.compile(r"(?:\d*|&)>{1,2}")


def _seg_tokens(face, lo, hi):
    """[(operator or None, start, end)] for one segment of the blinded face; a word token has
    `None` and the caller reads the ORIGINAL bytes at [start, end). A COMMENT run is dropped
    exactly like whitespace: it is neither a word nor anything's operand."""
    toks, i = [], lo
    while i < hi:
        if face[i] in " \t" or face[i] == _R20_COMMENT:
            i += 1
            continue
        m = _R20_OP.match(face, i, hi)
        if m:
            toks.append((m.group(0), m.start(), m.end()))
            i = m.end()
            continue
        if face[i] in "<>&":       # a stray operator byte (the `>` left over from `>>>`)
            i += 1
            continue
        j = i
        while j < hi and face[j] not in " \t<>&" and face[j] != _R20_COMMENT:
            j += 1
        toks.append((None, i, j))
        i = j
    return toks


def _unquote_word(word):
    """(the path the SHELL would hand the program, expands). `expands` True when the shell would
    expand something this guard cannot evaluate; the text is then the word with its quoting
    removed, which is what the WARN shows. Quoting IS resolved, so `"/a b/x.py"` and
    `/a\\ b/x.py` both read as `/a b/x.py`."""
    out, i, n, expands = [], 0, len(word), False
    while i < n:
        c = word[i]
        if c == "\\" and i + 1 < n:
            out.append(word[i + 1])
            i += 2
            continue
        if c == "'":
            j = word.find("'", i + 1)
            if j < 0:
                return "".join(out) + word[i + 1:], True
            out.append(word[i + 1:j])
            i = j + 1
            continue
        if c == '"':
            # Inside double quotes a backslash escapes `$` `` ` `` `"` `\` and NOTHING else, so
            # the expansion test has to run on the ORIGINAL bytes as they are consumed — R2-3:
            # recovering the body first and then searching it for `$` read the LITERAL `$` of
            # `"…/\$literal.py"` as an expansion and downgraded a real target to a WARN.
            j = i + 1
            while j < n and word[j] != '"':
                if word[j] == "\\" and j + 1 < n and word[j + 1] in "$`\"\\":
                    out.append(word[j + 1])
                    j += 2
                    continue
                if word[j] in "$`":
                    expands = True
                out.append(word[j])
                j += 1
            if j >= n:
                return "".join(out), True
            i = j + 1
            continue
        if c in "$`*?[" or (c == "~" and i == 0):
            expands = True
        out.append(c)
        i += 1
    return "".join(out), expands


# The wrapper chain rules (8)-(19) share, as a NAME set: the command this segment really runs
# sits behind any env assignments, wrapper words and their flags / duration operands.
_R20_WRAPPERS = {"bash", "sh", "zsh", "env", "command", "exec", "nohup", "timeout", "time",
                 "nice"}
_R20_DURATION = re.compile(r"\d+(?:\.\d+)?[smhd]?$")


def _cmd_head(words):
    """(basename of the command this segment runs, index of its first argument). A wrapper flag
    that takes a SEPARATE non-numeric value (`timeout -s KILL 30 tee f`) still breaks the anchor
    — the same accept-documented limit `_WRAPPER` carries for every other rule in this file."""
    i = 0
    while i < len(words):
        w = words[i]
        if re.match(r"\w+=", w) or w.startswith("-") or _R20_DURATION.match(w):
            i += 1
            continue
        base = w.rsplit("/", 1)[-1]
        if base in _R20_WRAPPERS:
            i += 1
            continue
        return base, i + 1
    return None, len(words)


# sed's options that take a SEPARATE value: their argument is DATA and must not be judged as a
# path (same arity discipline rules (17)/(18) apply to argv). `-i SUFFIX` is deliberately NOT
# listed: BSD and GNU disagree about whether that token is a suffix or the script, and it does
# not matter here — a suffix (`.bak`) and a script (`s/a/b/`) both fail the source-face test,
# so judging EVERY positional is correct under either parse.
_SED_VALUED = {"-e", "--expression", "-f", "--file", "-l", "--line-length"}


def _sed_in_place(tok):
    """True when this argv token asks sed to rewrite its input files. Covers the bare `-i`, an
    attached suffix (`-i.bak`), a short-flag cluster carrying `i` (`-ni`), and both long
    spellings. sed has no OTHER option whose name starts with `i`, so the cluster test cannot
    catch an unrelated flag."""
    return (tok == "--in-place" or tok.startswith("--in-place=")
            or bool(re.match(r"-[A-Za-z]*i", tok)))


def _positionals(words, valued):
    """The non-flag words of one command tail, returned STILL QUOTED (the caller unquotes them
    with the path recovery). `--` ends option parsing and each `valued` option consumes its
    argument; the option tests read the UNQUOTED form, because `'-e'` is the same flag as `-e`."""
    out, i = [], 0
    while i < len(words):
        tok = _unquote_word(words[i])[0]
        if tok == "--":
            out.extend(words[i + 1:])
            break
        if tok.startswith("-") and tok != "-":
            i += 2 if (tok in valued and "=" not in tok) else 1
            continue
        out.append(words[i])
        i += 1
    return out


def _write_targets(text):
    """(literal, expanding): every path this command's three parseable channels name. `text` is
    the heredoc-STRIPPED command, so a body is the document being written and never a step.
    An absent target (a bare trailing `>`) is not a write. `/dev/null` is deliberately NOT
    special-cased: it carries no source extension, so the source face already passes it, and a
    branch the suite cannot turn red is worse than no branch."""
    # A backslash-newline is REMOVED by the shell before it lexes anything, so the fold has to
    # happen before this rule splits words — R2-3: keeping it made `> /repo\<newline>/x.py` one
    # word containing a newline, which no source face can match. Same PARITY as rule (8)'s own
    # fold and for the same reason: only an ODD run of backslashes continues a line, so `x\\`
    # ends the command and the next line is new text.
    text = re.sub(r"(^|[^\\])((?:\\\\)*)\\\r?\n", r"\g<1>\g<2>", text)
    face = _write_face(text)
    lit, expanding = [], []

    def add(raw_word):
        path, expands = _unquote_word(raw_word)
        if not path:
            return
        (expanding if expands else lit).append(path)

    for lo, hi in _write_segments(face):
        toks = _seg_tokens(face, lo, hi)
        words, after_op = [], False
        for k, (op, start, end) in enumerate(toks):
            if op is not None:
                # a DUPLICATION's operand is inside the operator, so it consumes no word
                after_op = not _R20_DUP.fullmatch(op)
                if _R20_WRITE_OP.fullmatch(op):
                    nxt = toks[k + 1] if k + 1 < len(toks) else None
                    if nxt and nxt[0] is None:
                        add(text[nxt[1]:nxt[2]])
                continue
            if after_op:            # a redirect's operand is not an argv positional
                after_op = False
                continue
            words.append(text[start:end])
        plain = [_unquote_word(w)[0] for w in words]
        base, first = _cmd_head(plain)
        if base == "tee":
            for w in _positionals(words[first:], ()):
                add(w)
        elif base == "sed" and any(_sed_in_place(t) for t in plain[first:]):
            for w in _positionals(words[first:], _SED_VALUED):
                add(w)
    return lit, expanding


_EDIT_GUARD = []


def _edit_guard():
    """cto-guard-edit's seat-attribution face, loaded from the SAME directory on demand, or None
    when it cannot be loaded at all (a missing / unreadable sibling: the rule then DEGRADES to
    ALLOW+WARN like every other unanswerable case, rather than taking the Bash tool down with a
    CHECKER-ERROR).
    IMPORTED, never copied: rule (20) IS E1 on another channel, and two copies of "which live
    seat owns this work tree" would drift until the two channels disagreed about the same write.
    Lazy + cached, so a command with no literal write target never pays for it — measured at
    1.0 ms, against 12.5 ms for ONE of the `git rev-parse` calls the judgement itself makes (the
    hyphenated filename is why this goes through importlib rather than `import`)."""
    if not _EDIT_GUARD:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cto-guard-edit.py")
        try:
            spec = importlib.util.spec_from_file_location("cto_guard_edit", path)
            if spec is None or spec.loader is None:
                return None
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)   # `main()` is under a __main__ guard: no side effects
        except Exception:
            return None
        _EDIT_GUARD.append(mod)
    return _EDIT_GUARD[0]


def _r20_judge(g, lit, cwd):
    """(target to deny, reason it could not be judged) for one command's literal write targets.
    E1's predicate, per target and in E1's order:
      * seat-attribution module unloadable          -> UNANSWERABLE, ALLOW and say so
      * not a source/test path                      -> none of this rule's business, silent
      * inside a LIVE seat's work tree              -> a worker writing its own repo, ALLOW
      * census incomplete, or no governed work tree
        owns it while the caller is not a seat      -> UNANSWERABLE, ALLOW and say so
      * whatever is left                            -> the orchestrator typing product code."""
    if g is None:
        return None, "cto-guard-edit.py could not be loaded, so no seat census exists"
    src = [(t, t if os.path.isabs(t) else os.path.join(cwd, t)) for t in lit]
    src = [(t, full) for t, full in src if g._is_source(full)]
    if not src:
        return None, None
    run_dir = os.environ.get("AGENT_WATCH_DIR") or g._RUN_DEFAULT
    seats, complete = g.live_seat_cwds(run_dir)
    if not complete:
        return None, "run dir %s could not be listed, so the LIVE seat set is unknown" % run_dir
    croot, cdecided = g._worktree_root(cwd)
    caller_seat = any(g._seat_holds(cwd, s, croot, cdecided) for s in seats)
    unjudged = None
    for tok, full in src:
        tdir = g._target_dir(full, cwd)
        troot, tdecided = g._worktree_root(tdir)
        if any(g._seat_holds(tdir, s, troot, tdecided) for s in seats):
            continue
        if not (tdecided and (caller_seat or (cdecided and croot == troot))):
            unjudged = unjudged or "%s is inside no work tree this call can attribute" % tok
            continue
        return tok, None
    return None, unjudged


# ── rule (21): inline steer text carrying command substitution (DENY) ─────────────────────
# KILL CRITERION (slug `g21-steer-inline-substitution`, retro GATE-AUDIT): hits=0 for a year ⇒
# kill (owner ruling 2026-09-02, the ruling that admitted the rule).
# FIELD, 2026-08-30: `agentctl steer <s> -m "…`gh api repos/… --jq .status`…"`. The shell ran the
# example `gh api` for real (a 404, harmless by luck) before agentctl was even exec'd, and the `>`
# in the same body truncated what was left, so agentctl reported a parse error and could not say
# why. Two seats have each been bitten once by this exact shape since (2026-09-02).
# SHAPE: a command-position `agentctl steer` (the wrapper/env chain rules (8)-(20) already share)
# whose line carries `-m`; the BODY is every byte from that `-m` to the END of the command text.
# A BYTE BAN, and that is the design decision rather than an oversight: single quotes, double
# quotes and `\$(` are NOT distinguished. The shell does not expand a backtick inside single
# quotes, so `-m 'plain `ls` text'` is an ACCEPTED false positive — bought deliberately, because
# one fix line (`-f <file>`) covers every spelling, while a rule that reasoned about quote nesting
# inside an argv word the shell has not lexed yet would be guessing at the exact moment it holds a
# DENY. Pinned as `r21-doc-single-quoted-body-denied` / `r21-doc-escaped-dollar-paren-denied`.
# BODY ENDS AT END OF TEXT, not end of line: the field case was a MULTI-LINE `-m "…"`, and finding
# where such a body really ends means parsing the quoting this ban already refuses to reason
# about. Second accepted over-reach, same recovery: a separate command chained AFTER a clean `-m`
# is read as body (`r21-doc-tail-after-m-judged`), and its fix is the same `-f` rewrite.
# NEVER MATCHES: `-f <file>` (there is no `-m`), and a `steer` with no `-m` at all.
# JUDGED ON `raw`, the quoted-heredoc-stripped face the general rules read — one view, both
# directions pinned: a `<<'EOF'` body is DATA (the shell expands nothing inside it, so the text
# reaches agentctl intact), while a BARE `<<EOF` body stays visible because its substitutions
# really do run before the fed shell sees a thing.
# A MENTION IS NOT A COMMAND, the discipline every other rule here carries: `echo "agentctl steer
# s1 -m \`x\`"` is not at command position and is not judged, even though that backtick expands.
# The rule owns the steer channel, not shell substitution in general.
_R21_HEAD = re.compile(_pos_head(r";&(|\n") + _AGENTCTL
                       + r"\s+steer(?![\w-])[^\n]*?\s-m(?=[\s\"'])")
_R21_SUBST = re.compile(r"`|\$\(")


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
    # Only a QUOTED heredoc delimiter disables expansion, so only those bodies are data-safe for
    # EVERY rule to ignore. Unquoted `<<EOF` bodies may execute command substitutions and must stay
    # visible to the general views. Opener/closer lines survive so commands after the heredoc are
    # still scanned.
    # `quoted_only=False` strips EVERY body. That view belongs to rules (8)/(18)/(19) ONLY
    # (`raw_hd` below), where a heredoc body is the DOCUMENT being written, not a list of steps —
    # field false positives n=2, both a brief/note whose prose put `git …` at line start or behind
    # a markdown table pipe, denied as an unanchored command inside a document (GATE-AUDIT false+2).
    # ONE walk, TWO consumers (review R2-1): the string view below, and the LINE STRUCTURE rule (8)'s
    # interpreter face needs. A regex over the flat text cannot tell an outer document's body from
    # real command text, so the structure has to be carried, not re-derived.
    def _heredoc_scan(s, quoted_only):
        """[(command-line, [(body, closer-line), …])] for every line that is real COMMAND text,
        or None when the split cannot be trusted (unterminated / mixed delimiters).

        BODY lines never appear as command lines: text inside a heredoc body is DATA. That is the
        whole property — a body cannot be a command, and it cannot open an interpreter feed either.
        """
        lines = s.splitlines(keepends=True)
        quo = r"(?P<quote>['\"])(?P<tag>[^'\"\r\n]+)(?P=quote)"
        opener = re.compile(r"<<(?P<tabs>-?)(?!<)[ \t]*(?:" + quo + r")" if quoted_only else
                            r"<<(?P<tabs>-?)(?!<)[ \t]*(?:" + quo + r"|(?P<bare>[^\s;|&<>]+))")
        any_op = re.compile(r"<<-?(?!<)[ \t]*(?:['\"][^'\"\r\n]+['\"]|[^\s;|&<>]+)")
        recs = []
        i = 0
        while i < len(lines):
            line = lines[i]
            hits = list(opener.finditer(line))
            # Mixed quoted/unquoted heredocs share one body stream; leave the whole command intact
            # rather than guessing which body belongs to which delimiter. With `quoted_only=False`
            # both patterns see the same openers, so this can only fire on the quoted pass.
            if not hits or len(hits) != len(any_op.findall(line)):
                recs.append((line, []))
                i += 1
                continue
            cursor = i + 1
            pairs = []
            for match in hits:
                tag = match.group("tag") or match.groupdict().get("bare")
                strip_tabs = match.group("tabs") == "-"
                end = None
                for j in range(cursor, len(lines)):
                    candidate = lines[j].rstrip("\r\n")
                    if (candidate == tag or
                            (strip_tabs and candidate.startswith("\t") and candidate.lstrip("\t") == tag)):
                        end = j
                        break
                if end is None:
                    return None  # unterminated/ambiguous: the caller falls back, conservatively
                pairs.append(("".join(lines[cursor:end]), lines[end]))
                cursor = end + 1
            recs.append((line, pairs))
            i = cursor
        return recs

    def _strip_heredocs(s, quoted_only):
        recs = _heredoc_scan(s, quoted_only)
        if recs is None:
            return s  # unterminated/ambiguous: scan conservatively, strip nothing
        out = []
        for line, pairs in recs:
            out.append(line)
            for _, closer in pairs:
                out.extend(("<<<HEREDOC-BODY-STRIPPED>>>\n", closer))
        return "".join(out)
    raw = _strip_heredocs(raw, True)
    # rules (8)/(18)/(19) read this face. Built from the ORIGINAL command and never from `raw`:
    # the marker line above itself contains `<<`, so a second pass over an already-stripped text
    # would read the marker as an unterminated opener and bail (stripping nothing).
    raw_hd = _strip_heredocs(ti["command"], False)
    cmd = raw.replace("\n", " ")
    if not cmd:
        return 0
    # quote-stripped view: drop "..."/'...'/`...` spans so a token that only appears inside a quoted
    # arg (e.g. `echo "git push later"`, `echo "a & b"`) is NOT mistaken for a real command. Used by
    # the & guard (1) and the push guard (5). NOT used by the send-keys guard (4) — that one is
    # specifically about the QUOTED CJK payload, so it must see the raw cmd.
    unq = re.sub(r"\"[^\"]*\"|'[^']*'|`[^`]*`", "", cmd)

    # (12) typed-command stdout consumed by a pipe — rule (10)'s disease, a different organ.
    #      `agentctl watch|steer|start|stop` and `gh pr checks --watch` / `gh run watch` publish
    #      TYPED state on stdout and carry their verdict in the EXIT CODE. A pipeline's rc is the
    #      LAST command's, so `agentctl steer s -m x | tee log` reports success for a steer that
    #      never landed, and the state frame the orchestrator was supposed to read is truncated
    #      into a pager. Only NON-LAST position is denied: stdout is consumed exactly when a `|`
    #      FOLLOWS the command, so `… | agentctl steer s -m x` (piped STDIN, typed state still
    #      on the terminal) stays legal. `||` is a chain, not a pipe.
    #      PARSE FACE = rule (10)'s, verbatim: `_pipe_view` + `_pos_head`, one shell
    #      approximation shared by both pipeline rules. Quoted literals, comments and stripped
    #      quoted-heredoc bodies are DATA and never reach command position.
    #      PLACEMENT — FIRST rule in the chain, each hop earned:
    #        above (1), because `|&` is a pipe operator and (1) read its `&` as backgrounding,
    #          sending the operator to run_in_background instead of the file-first fix (R1 M5);
    #        above (5), so a piped `watch` gets the pipe verdict, whose fix covers the
    #          foreground one too (the reverse is not true);
    #        above (3), whose branch ends in an unconditional `return 0` and would otherwise
    #          hide every `agentctl start … | …` from this rule.
    #      BLIND SPOTS, inherited from (10), accept-documented (a regex cannot parse shell):
    #      command substitution `$(agentctl watch s)`, process substitution, nested-shell
    #      payloads (`bash -lc '… | …'`: the quoted body is blanked to ARG in the view), and
    #      indirection through a shell variable.
    vpipe = _pipe_view(raw)
    if re.search(_POS_TYPED + r"[^;&|]*\|(?!\|)", vpipe):
        sys.stderr.write(
            "DENY: typed-command stdout piped — `agentctl watch/steer/start/stop` and `gh pr "
            "checks --watch` / `gh run watch` carry the verdict in their EXIT CODE, and a "
            "pipeline's rc is the LAST command's, so a failed call reports green while the "
            "state frame is truncated. Fix: redirect to a file and read rc directly "
            "(`agentctl steer s1 -m x > /tmp/o.log 2>&1; echo rc=$?`), then grep the file; a "
            "`watch` belongs in Bash run_in_background:true, never in a pipeline. A typed "
            "command at the END of a pipeline and `||` chains pass. "
            "Read: cto-orchestration/references/agentctl/README.md §typed 状态.\n"
        )
        return 2

    # (21) inline steer text carrying command substitution — placed HERE, directly above (1): a
    #      body whose backticked example contains an `&` would otherwise take (1)'s orphan
    #      verdict, and run_in_background does nothing about a substitution that already ran.
    #      Below (12), which owns the piped shape and whose file-first fix the steer still needs.
    #      Doctrine, the byte ban and its two accepted over-reaches: `_R21_HEAD` at module level.
    m21 = _R21_HEAD.search(raw)
    if m21 and _R21_SUBST.search(raw[m21.end():]):
        sys.stderr.write(
            "DENY: `agentctl steer -m` 正文含命令替换 — a backtick or `$(` in the inline body is "
            "expanded by the SHELL before agentctl sees it: the example command RUNS (2026-08-30: a "
            "`gh api …` ran for real), a `>` truncates the rest, and agentctl can only report a parse "
            "error. Fix: body in a file — `agentctl steer <session> -f <file>`; `-m` is one plain "
            "sentence, no backtick / `$(` / `>`, single quotes included. "
            "Read: cto-orchestration/references/agentctl/README.md §agentctl —— 当前命令面.\n"
        )
        return 2

    # (1) shell-& backgrounding -> orphan. STRIP quoted/backtick spans first (so `echo "a & b"` is not a
    #     false positive), THEN flag any single `&` that backgrounds: not part of `&&` (logical-and) and
    #     not a redirect (`>&`, `&>`, `N>&M`). This closes the earlier blind spot where `foo & bar`
    #     (background-then-chain, e.g. `nohup … & echo …`) slipped the old `&[ \t]*(disown|;|$)` tail —
    #     the tail only caught `& ;` / `& disown` / `& <end>`, self-inflicted miss 2026-07-04. An unquoted
    #     `&` in a URL (`curl x?a=1&b=2`) IS a real shell background hazard → DENY is correct (quote it).
    #     `|&` is EXCLUDED: it is bash's pipe-with-stderr operator, not backgrounding. Calling it an
    #     orphan sent the operator to run_in_background — straight into the next denial — instead of
    #     the file-first fix its actual pipeline needs (review R1 M5); rule (12) above owns that shape.
    if re.search(r"(?<![&>|])&(?![&>])", unq):
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
    #     (>=2 immediate children with .git); single-repo projects never see it. That scan is
    #     `_umbrella_near` at module level — rule (19) reads the same root for its repo register.

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
            parts = re.split(r";|\|\|", full[mcd.end():], maxsplit=1)
            return len(parts) > 1 and _unanchored_segs(_strip_spans(parts[1]))
        return _unanchored_segs(_strip_spans(full))

    # rule-8 views, also consumed by rule (11): a backslash-newline is REMOVED by the shell
    # before it parses anything, so fold continuations FIRST — otherwise one command spelled
    # across two lines reads as two, and a subcommand sitting on the second line escapes every
    # rule anchored at command position (review R1 B2). THEN newline = `;` (a second line is a
    # NEW command — flattening to a space made `echo ready\ngit status` invisible, review R2);
    # unwrap single-token quotes ("git", $'git'), drop backslash escapes (g\it)
    #
    # PARITY IS LOAD-BEARING (review R2 F2, a regression this fold introduced): only an ODD run
    # of backslashes continues a line. `echo ready \\<newline>git status` ends the command — the
    # two backslashes are a literal backslash argument — so `git status` on the next line is a
    # NEW, unanchored command that rule 8 must still see. Folding unconditionally spliced the
    # lines and rule 8 went fail-open on exactly the shape it exists to catch. The pattern
    # therefore anchors on a non-backslash (or string start), keeps whole `\\` pairs in group 2,
    # and consumes only the final lone backslash plus its newline.
    def _fold8(s):
        return re.sub(r"(^|[^\\])((?:\\\\)*)\\\r?\n", r"\g<1>\g<2>", s).replace("\n", ";")

    def _unq8(s):
        return re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2", s).replace("\\", "")

    cmd8 = _fold8(raw)          # rule (11)'s face, unchanged
    v8 = _unq8(cmd8)
    # RULE (8) ONLY (owner ruling, this batch): the unanchored-git scan reads the SAME
    # normalization over the heredoc-stripped text. A heredoc body is the document being written,
    # and rule (8) was scanning it as commands — two field false positives, both a brief/note
    # whose prose put `git …` at line start or behind a markdown-table `|` (GATE-AUDIT false+2).
    # The `<<`-into-a-shell branch below is the EXCEPTION and still judges `orig8`: there the body
    # really is script. No other rule's view moves — rule (11) keeps `cmd8`/`v8` above.
    cmd8h = _fold8(raw_hd)
    v8h = _unq8(cmd8h)
    # the shell EXECUTION face: rule 8's normalization, plus multi-word quoted spans collapsed
    # to QSPAN so a mention inside `echo "…"` / `grep "…"` stays DATA rather than a command.
    def _exec_face(s):
        return _strip_spans(_unq8(s))
    orig8 = ti["command"]  # pre-heredoc-strip: quoted heredoc bodies are data EXCEPT to a shell consumer
    cwd8 = data.get("cwd") or os.getcwd()
    # SCOPE GATE, two conjuncts and the second one only ever SUBTRACTS: `_umbrella_near`'s scan
    # (5 ancestors, >=2 direct git children) is unchanged, and after it fires the rule stands
    # down for exactly one shape — the cwd's own repo IS this session's project root, where a
    # drifted cwd cannot be pointing at a sibling (`_cwd_is_session_root`, and the field numbers
    # that made it worth doing, are documented at module level). Everything else — session root
    # IS the umbrella, cwd in a sibling repo, cwd in a repo nested inside one, no
    # `transcript_path` at all (a codex seat) — keeps the DENY it has today.
    if ((re.search(r"\b(?:git|gh)\b", v8) or re.search(r"\b(?:git|gh)\b", orig8))
            and _umbrella_near(cwd8)
            and not _cwd_is_session_root(cwd8, data.get("transcript_path"))):
        bad8 = _text_unanchored(v8h)
        if not bad8:
            # interpreter payloads execute too: bash -lc 'git status' hid git in a quoted span
            for mi in re.finditer(
                    r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _WRAP8 +
                    r"(?:\S*/)?(?:bash|sh|zsh)\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+)*([\"'])(.*?)\1", cmd8h):
                pv = _unq8(mi.group(2))
                if _text_unanchored(pv):
                    bad8 = True
                    break
        # A heredoc / pipe INTO a shell runs its body as script, so THERE the body is not document
        # text and must be judged. Three review findings live in this one branch, all the same root
        # cause — the interpreter face was not asking the question on the right SURFACE:
        #  * finding 1, an under-fire regression: the pipe RHS admitted only a BARE interpreter, so
        #    `cat <<EOF | env sh -` (same class: `command sh`, `/usr/bin/env bash`) went silent at
        #    exit 0 while the shell really ran the body — baseline denied that payload.
        #  * finding 4: with no command-position anchor, the FILENAME in `cat > /tmp/bash <<EOF`
        #    read as an interpreter and a document body was re-scanned.
        #  * R2-1: with detection on the RAW text, a documentation heredoc that SHOWS a nested
        #    shell heredoc (`cat > brief.md <<OUTER` / `bash <<INNER` / `git status` / …) had its
        #    inner example read as a real feed. The shell there runs `cat` and nothing else; the
        #    inner `bash` is bytes being written to a file. That is precisely the false-positive
        #    class this batch exists to remove, so it is not an acceptable residual.
        # THE PROPERTY, which the two earlier cuts both lacked: text inside ANY heredoc body is
        # DATA and can never open an interpreter feed. So detection runs per COMMAND LINE of the
        # stripped structure (`_heredoc_scan` drops body lines by construction), and only a line
        # that fires makes us look at the bodies THAT line opens — read from the original text,
        # because that is where a real feed's script still lives.
        # `_WRAP8` is the wrapper chain rules (8)/(11) already share; `^` is command position
        # within a line, exactly as a newline is a `;` everywhere else in this rule.
        _fed8 = (r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _WRAP8
                 + r"(?:\S*/)?(?:bash|sh|zsh)\b[^|;&\n]*<<")
        _piped8 = (r"\|\s*(?:\w+=\S*\s+)*" + _WRAP8 + r"(?:\S*/)?(?:bash|sh|zsh)\b")
        if not bad8 and not _cd_anchor(v8h):
            recs8 = _heredoc_scan(ti["command"], False)
            if recs8 is None:
                # the split is untrustworthy (unterminated heredoc), so neither is any claim about
                # which text is a body: fall back to the whole original, the conservative face
                if re.search(_fed8, orig8) or re.search(_piped8, orig8):
                    bad8 = bool(re.search(r"\bgit\b|\bgh\b", orig8))
            else:
                for line8, pairs8 in recs8:
                    if not (re.search(_fed8, line8) or re.search(_piped8, line8)):
                        continue
                    # the script this feed actually runs: the bodies this line opens, plus the line
                    # itself (`printf 'git status' | bash` carries its script in argv, no heredoc)
                    fed = line8 + "".join(b for b, _ in pairs8)
                    if re.search(r"\bgit\b|\bgh\b", fed):
                        bad8 = True
                        break
        if bad8:
            sys.stderr.write(
                "DENY: unanchored git/gh in a multi-repo umbrella — the session root IS the "
                "umbrella, or this cwd is another repo in it, so a bare git/gh hits the WRONG "
                "repo. Fix: REWRITE, do NOT resend: prefix each call `git -C /abs/<repo>` / "
                "`gh -R <owner>/<repo>`, or lead with `cd /abs/<repo> && …` — a DENIED command "
                "never ran its `cd`. git --version / gh auth pass. "
                "Read: cto-orchestration/references/agentctl/README.md §cwd 锚定.\n"
            )
            return 2

    # (18) history rewrite welded into a compound chain — placed HERE, immediately after (8),
    #      because the two rules share one subject (the SHAPE of a git command line) and (8)'s
    #      `cd /abs && …` prescription is this rule's exemption; letting (8) speak first also
    #      means a command that is both unanchored AND chained gets the anchoring fix, which the
    #      rewritten single-step command still needs. Above (3)'s unconditional `return 0`.
    #      Doctrine, shape, exemption and the one accepted false positive: `_rewrite_in_chain`.
    #      Judged on `raw_hd`: a rewrite verb in a heredoc BODY is document text, not a step.
    if _rewrite_in_chain(raw_hd):
        sys.stderr.write(
            "DENY: 历史重写混在复合链里 — `git commit --amend` / `cherry-pick` / `rebase` share this "
            "command with another step. Shell chains are left-associative, so a `||` arm binds the "
            "whole left chain instead of the step that failed, and a rewrite that dies half-way "
            "leaves a state the command text cannot explain (downstream seats n=2, ~30 min reflog "
            "recovery each). Fix: one step per tool call — run the rewrite ALONE, read its rc, then "
            "send the next command. A single leading `cd /abs && …` anchor and env prefixes pass. "
            "Read: cto-orchestration/references/dispatch-baseline.md §基线纪律.\n"
        )
        return 2

    # (20) the orchestrator writing SOURCE through bash — E1 (cto-guard-edit.py) on this
    #      channel, because in auto mode the harness prefers Bash over Edit/Write for editing
    #      files and E1 is dark there (four spellings measured at rc=0, 2026-09-02). Doctrine,
    #      the closed set of parseable spellings, the uncovered channels and the seat
    #      attribution it imports rather than copies: `_write_targets` / `_r20_judge`.
    #      PLACEMENT: below (8)/(18) — a command that is both unanchored and a hand-write gets
    #      the anchoring rewrite first, which is the cheaper fix — and ABOVE every `return 0`
    #      that follows (rule (7)'s benign-prune allow, rule (3)'s reminder branch), so a write
    #      chained after a legal dispatch is still judged.
    lit20, opaque20 = _write_targets(raw_hd)
    note20 = note20b = ""
    if lit20:
        g20 = _edit_guard()
        tgt20, why20 = _r20_judge(g20, lit20, cwd8)
        if tgt20 is not None and g20 is not None:
            # The override is the LICENSED direct-write path (SKILL.md §2: the orchestrator may
            # write the shipped 教义 / 门 / guard face itself), and consumption IS the approval —
            # the same one-shot marker E1 consumes, so one `touch` can never become a standing
            # bypass and an unremovable object at that path still denies.
            try:
                os.remove(g20._OVERRIDE)
                tgt20 = None
            except OSError:
                pass
        if tgt20 is not None and g20 is not None:
            sys.stderr.write(
                "DENY: 编排位经 bash 直写源码面 — this command writes %s (a source/test path) "
                "through a redirect / tee / in-place sed, and no LIVE agentctl seat holds that "
                "work tree (call cwd %s): that is the orchestrator typing product code (铁律① "
                "车道分工, n=2 — the seat hand-coded what it had just briefed and lost the "
                "review lane it was paying for). Fix: dispatch it — `agentctl start <engine> "
                "<session> <cwd> --goal <abs>` — and let the worker edit inside its own "
                "worktree; writes into a live seat's work tree pass untouched. Writing the "
                "SHIPPED face (教义 / 门 / guard) yourself is licensed for ANY verified motive: "
                "`touch %s` (one-shot, consumed on use) and re-run. "
                "Read: cto-orchestration/references/agentctl/README.md §强制层.\n"
                % (tgt20, cwd8, g20._OVERRIDE)
            )
            return 2
        if why20:
            note20 = (
                # TWO locals for this rule, not one with two assignment arms: the injected-text
                # ratchet resolves ONE literal per local name, so a second assignment to `note20`
                # would go entirely unweighed. Held near (14)/(15)/(16)/(19)'s length — they join
                # in ONE assembled response, and that assembly is what `BUDGET_GUARD_SINGLE` weighs.
                "WARN (cto-guard 20): 席位归属未判 — %s, so a write to a source path was allowed "
                "unjudged. 铁律① 车道分工 still holds: the orchestrator dispatches product code, "
                "it does not type it." % why20
            )
    if opaque20 and not note20:
        note20b = (
            "WARN (cto-guard 20): write target not literal (%s) — the shell expands it, so 席位"
            "归属未判 and the override marker was NOT consumed. If you are the orchestrator and "
            "that path is source, dispatch it (`agentctl start … --goal <abs>`) or `touch "
            "/tmp/cto-allow-direct-write` and re-send with a LITERAL path." % opaque20[0]
        )

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

    # (11) bare `codex exec` / `codex e` / `codex review` — a hand-rolled headless codex.
    #      Field 2026-08-19/20: the orchestrator hand-rolled `codex exec` for a review
    #      seat. A bare exec owns no fifo and publishes no typed state: a heredoc in the
    #      same command waits on stdin EOF forever (one hang ran 10h21m) and a `$(cat
    #      brief)` that expanded empty burned a whole round in silence.
    #      Owner ruling: review dispatch may go through the lane ONLY —
    #      `agentctl start codex … --review`.
    #      PLACEMENT IS LOAD-BEARING: this must stay ABOVE rule (3), whose `if m:` branch ends
    #      in an unconditional `return 0` — every rule below it is invisible to any command
    #      containing `agentctl start`, which is exactly the shape that chains a bare codex
    #      call after a legal dispatch. `agentctl start codex` is allowed by COMMAND POSITION
    #      here (codex sits as an argument, not at the head of a segment), never by ordering.
    #      `codex exec-server` is EXPLICITLY excluded — the token compare is exact, where a bare
    #      `\b` would have matched straight through the hyphen.
    #      NOT covered, accept-documented: interactive `codex "<prompt>"`. It is a TTY session
    #      rather than a headless dispatch, and no regex can tell a prompt from a subcommand.
    #      The subcommand is decided by TOKEN WALK, not by a regex with an optional value group:
    #      that group backtracks, so `codex --profile review login` re-read the profile VALUE as
    #      the review subcommand and denied a legal login (review R1 M1).
    # codex's global options that take a SEPARATE value, from `codex --help` (verified against
    # the installed CLI, 2026-08-20). Only these consume the next token; every other flag is
    # valueless, so `codex --search exec …` still resolves `exec` as the subcommand. A valued
    # flag NOT on this list whose value happens to be exec/e/review denies — a guard erring
    # toward DENY on an unknown flag is the correct direction, and the list is the narrow part.
    _CODEX_VALUED = {"-c", "--config", "--enable", "--disable", "--remote",
                     "--remote-auth-token-env", "-i", "--image", "-m", "--model",
                     "--local-provider", "-p", "--profile", "-s", "--sandbox", "-C", "--cd",
                     "--add-dir", "-a", "--ask-for-approval"}
    _CODEX_HEADLESS = {"exec", "e", "review"}
    _codex_head = re.compile(
        r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _WRAP8 + r"(?:\S*/)?codex(?=\s)")

    def _bare_codex(face):
        """True when ANY command-position `codex` invocation resolves to a headless subcommand.

        Every invocation in the chain is judged, not just the first: returning on the first one
        let a legal call SHADOW an illegal one, so `codex login; codex exec "x"` (and the `&&`
        spelling) walked straight through the rule this guard exists to be (review R2 F1). A
        legal subcommand only ends ITS OWN invocation — it never ends the scan."""
        for mh in _codex_head.finditer(face):
            # the invocation ends at the next shell separator; a `(` opens a subshell, so it
            # cannot carry codex arguments either
            seg = re.split(r"[;|&()]", face[mh.end():], maxsplit=1)[0]
            toks = seg.split()
            i = 0
            while i < len(toks):
                tok = toks[i]
                if tok.startswith("-"):
                    # `--flag=value` carries its own value; a listed flag eats the NEXT token
                    i += 2 if ("=" not in tok and tok in _CODEX_VALUED) else 1
                    continue
                if tok in _CODEX_HEADLESS:   # first non-flag token IS the subcommand
                    return True
                break                        # a legal subcommand: keep scanning the chain
            # flags only (`codex --version`, `codex --help`): no subcommand, nothing to deny
        return False
    hit11 = _bare_codex(_exec_face(cmd8))
    if not hit11:
        # interpreter payloads execute too: `bash -lc 'codex exec …'` / `$'…'` hid the call in a
        # quoted span, same blind spot rule (8) closes with the same shape
        for mi in re.finditer(
                r"(?:^|[;|&(]\s*)(?:\w+=\S*\s+)*" + _WRAP8 +
                r"(?:\S*/)?(?:bash|sh|zsh)\s+(?:-{1,2}[\w-]+(?:=\S*)?\s+)*\$?([\"'])(.*?)\1",
                cmd8):
            if _bare_codex(_exec_face(mi.group(2))):
                hit11 = True
                break
    if hit11:
        sys.stderr.write(
            "DENY: bare `codex exec` / `codex e` / `codex review` — a hand-rolled headless codex "
            "publishes no typed state: a heredoc in the same command waits on stdin EOF forever "
            "(field 2026-08-19: one hang ran 10h21m) and an empty `$(cat brief)` burns a round in "
            "silence. Fix: dispatch through the lane — `agentctl start codex <s> <cwd> --goal <f> "
            "--review` gets typed exit codes, a watcher and a receipt. "
            "`codex --version` / `login` / `exec-server` and `agentctl start codex` pass. "
            "Read: cto-orchestration/references/agentctl/README.md §强制层 ⑩.\n"
        )
        return 2

    # (17) review dispatch with no round budget — placed HERE, immediately after (11): that
    #      rule's fix line hands the seat `agentctl start codex … --review`, and this one is
    #      the other half of the same prescription (a review seat states its ceiling at
    #      dispatch time). Above (3), whose branch ends in an unconditional `return 0`, and
    #      above (13)/(14)/(15) because a defect in the COMMAND TEXT is cheaper to fix than
    #      one in the worktree the command points at. Doctrine and shape: `_review_without_budget`.
    if _review_without_budget(raw):
        sys.stderr.write(
            "DENY: 评审无预算 — `agentctl start codex … --review` with no `--max-rounds`: an "
            "unbudgeted review loop is an arms race, the reviewer keeps finding and nobody owns "
            "the round count (downstream DEV-tier batch: 3 rounds on advisory findings). Fix: "
            "state the ceiling at dispatch — `--workflow review-loop --max-rounds N` (the pair "
            "is required together; non-deep batches N=2, a deep batch declares its own N in the "
            "goal). Non-review dispatches and `--resume-thread` pass. "
            "Read: cto-orchestration/references/review-dispatch.md §轮数预算.\n"
        )
        return 2

    # (13) codex brief wording — a BOUNDED, best-effort advisory, WARN-only and never a DENY.
    #      Field n=4: review dispatches whose brief narrated the attack (`forged` stamp,
    #      `bypass` the guard) were refused by the provider's cyber filter, and the seat burned
    #      a round discovering that the wording, not the task, was the problem. The word list is
    #      the LITERAL phrases from those four prompts (`_R13_TERMS`) — declared non-complete
    #      there, with both failure faces named.
    #      Trigger: only a direct command-position `agentctl start codex … --goal <f>` (first
    #      one in the command). The path is read off the RAW text, because the normalized
    #      pipeline view blanks any quoted span with a space to ARG. Bounded read: regular
    #      files only, no symlink following, 256KB, UTF-8 — every failure degrades to a
    #      `not inspected (<reason>)` line at exit 0.
    reason13, hits13, path13 = _brief_review(raw, vpipe, data.get("cwd") or os.getcwd())
    note13 = ""
    if reason13:
        note13 = "WARN (cto-guard 13): brief not inspected (%s); wording unchecked." % reason13
    elif hits13:
        note13 = (
            "WARN (cto-guard 13): brief %s uses wording that has tripped the provider's cyber "
            "filter on review dispatches (n=4 false blocks): %s. Fix: keep the brief a DISPATCH "
            "— what to check, where, acceptance — in neutral review-dispatch wording, and move "
            "the sensitive narrative INTO the file the reviewer reads. Advisory: a literal "
            "phrase list from those four prompts, not a semantic check."
            % (path13, ", ".join(hits13))
        )

    m = re.search(r"\bagentctl[\"'\s]+start[\"'\s]+(omp|codex|claude)[\"'\s]+([^\s\"';|&]+)", cmd)
    # (14)/(15) dispatch preconditions, judged on EVERY command-position `agentctl start` in the
    #      command (`_start_seats`) rather than on rule (3)'s first unanchored match: quoted argv
    #      data is not a dispatch, and a LATER dispatch is still one (cold review §2.1/§2.2, both
    #      counter-probed). Both are DENYs and both must land BEFORE the reminder's
    #      `print(json.dumps(...))`: exit 2 plus a hook response on stdout would be one malformed
    #      reply, and (3)'s branch ends in an unconditional `return 0`.
    #      ORDER IS LOAD-BEARING — (15) BLOCKED.md first, and across ALL seats before (14) judges
    #      any: an unharvested BLOCKED.md is itself untracked, so (14) would fire on it and its
    #      fix line ("commit the seed") would tell the orchestrator to COMMIT the previous seat's
    #      held gate instead of harvesting it.
    seats14 = _start_seats(raw, data.get("cwd") or os.getcwd())
    note14 = note15 = ""
    for seat in seats14:
        # (15) BLOCKED.md is a path SHARED between successive seats: the new one correctly
        #      refuses to touch another seat's file and wedges with nowhere to write its own
        #      held gate (field: same day, n=2). Anything AT that path counts, file or
        #      DIRECTORY: a directory wedges the next seat the same way (cold review §2.3).
        #      The meter is `_blocked_stands`, not `os.path.exists` — that call answers False
        #      for "nothing there" AND for "could not look", so an unreadable seat read exactly
        #      like a harvested one (verify R3 §4.3; the same shape §4.2 fixed for (14)).
        stands, measured = _blocked_stands(os.path.join(seat, "BLOCKED.md"))
        if not measured:
            note15 = (
                "WARN (cto-guard 15): %s/BLOCKED.md could not be stat'ed, so the unharvested-"
                "gate precondition went UNCHECKED on this dispatch — look before you seat."
                % seat
            )
            continue
        if stands:
            sys.stderr.write(
                "DENY: 前席 BLOCKED 未收割 — %s/BLOCKED.md still stands, so the seat you are "
                "starting inherits a gate held by its predecessor and has nowhere to write "
                "its own (same day, n=2: the new seat correctly refuses to touch another "
                "seat's file and wedges). Fix: read it, archive the verdict into the batch "
                "record, `rm %s`, then re-send this dispatch. "
                "Read: cto-orchestration/references/dispatch-baseline.md §基线纪律.\n"
                % (seat, shlex.quote(os.path.join(seat, "BLOCKED.md")))
            )
            return 2
    for seat in seats14:
        # (14) untracked = dirty: the seat's own clean gate reds on the ORCHESTRATOR's
        #      uncommitted seed and STOPs before doing any work (downstream seats n=2, one
        #      burned round each). A directory git does not own is not judged at all — but a
        #      git that could not RUN is not that answer, and says so (cold review §4.2).
        #      Every fix command interpolates the cwd through `shlex.quote`: the parser admits
        #      quoted paths with spaces, so an unquoted copyable recovery is a false promise on
        #      an input this gate itself accepts (cold review §5.1).
        dirty, decided, available = _git_porcelain(seat)
        if not available:
            # Kept SHORT on purpose: it joins (3)'s reminder and (13)'s advisory in ONE hook
            # response, and that assembled payload is what `BUDGET_GUARD_SINGLE` ceilings. The
            # ceiling did NOT move for this batch — 149 B is what fits under it.
            note14 = (
                "WARN (cto-guard 14): `git status` could not run for %s, so the DIRTY-worktree "
                "precondition went UNCHECKED on this dispatch — commit the seed first."
                % seat
            )
            continue
        if decided and dirty:
            sys.stderr.write(
                "DENY: 播种未 seed commit — `agentctl start … %s` onto a DIRTY worktree; the "
                "seat's clean gate reads the orchestrator's own uncommitted seed as work in "
                "progress and STOPs (downstream seats n=2, one burned round each). Fix: "
                "commit the seed first (`git -C %s add -A && git -C %s commit -m 'seed: "
                "<brief>'`), then re-send this dispatch; anything that must NOT be committed "
                "belongs in the umbrella's docs/ or .gitignore, never loose in the worktree. "
                "Read: cto-orchestration/references/dispatch-baseline.md §基线纪律.\n"
                % (seat, shlex.quote(seat), shlex.quote(seat))
            )
            return 2

    # (16) babysit-round counter: the tally is bumped HERE, below every DENY above it, so a
    #      command that never runs is never counted (rule (5) kills a foreground watch, and a
    #      denied re-hang is not a re-hang). Doctrine, meter and its failure modes:
    #      `_babysit_bump`. WARN only — re-arming a watcher is legal, and this rule exists to
    #      make the FOURTH one on the same session visible, not to stop it.
    note16 = ""
    for sess in _babysit_sessions(raw):
        n16, degraded = _babysit_bump(sess)
        if n16 is None or n16 < _R16_WARN_AT or note16:
            continue   # a meter that cannot count stays silent; one warn per command is enough
        note16 = (
            # Held near (14)/(15)'s warn length on purpose: it joins them in ONE assembled
            # response, and that assembly is what `BUDGET_GUARD_SINGLE` weighs.
            "WARN (cto-guard 16): 保姆轮 ≥%d — session '%s' re-hung %d times today "
            "(watch/steer). Read the INSTRUMENT before the next one (a 14 with all three "
            "progress sources blind is a gauge fault), or go to one long-interval wakeup.%s"
            # the suffix covers BOTH floor causes — this bump could not be persisted, or the
            # day's ledger was corrupt and the reset is remembered (`_babysit_bump`'s flag)
            % (_R16_WARN_AT, sess, n16, "读数是下限、不可判（台账当日坏过或未落盘）。" if degraded else "")
        )

    # (19) verification batch drifting across repos: WARN only, by owner ruling for this batch.
    #      Doctrine, register and its boundary: `_registered_repos` / `_cwd_drift`. Judged on
    #      `raw_hd` so a path named inside a heredoc document is not read as an invocation; an
    #      unmeasurable register is an empty set, i.e. silence.
    note19 = ""
    base19 = data.get("cwd") or os.getcwd()
    here19, tok19 = _cwd_drift(raw_hd, _registered_repos(base19), base19)
    if here19:
        note19 = (
            # Held to (16)'s length: it joins (3)/(13)/(14)/(15)/(16) in ONE assembled response,
            # and that assembly is what `BUDGET_GUARD_SINGLE` weighs.
            "WARN (cto-guard 19): 验证批一条命令一个 cwd — this command cd's into '%s', then names "
            "'%s' — a DIFFERENT registered repo (n=4). A relative path against the wrong repo "
            "127s, or silently runs THAT repo's suite while the `&& echo PASS` tail claims a "
            "gate. Fix: one repo per command, or an absolute path." % (here19, tok19)
        )

    reminder = ""
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
            reminder = (
                f"REMINDER (cto-guard): session '{session}' has no watcher — arm the PRIMARY "
                f"signal now: `agentctl watch {session}` via Bash run_in_background:true (NOT "
                f"shell &, which orphans). A ScheduleWakeup timer is only the backstop."
            )
    # (13), (14)/(15)'s instrument warnings, (16)'s counter, (19)'s drift warn and (20)'s two
    # unjudged-write warns ride (3)'s channel: on exit 0 only additionalContext reaches the
    # agent, and two JSON documents on stdout would be one malformed hook response. All eight
    # strings stay LOCAL to this frame so the injected-text ratchet can weigh what a worker is
    # actually handed.
    if reminder or note13 or note14 or note15 or note16 or note19 or note20 or note20b:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": "\n".join(
                    t for t in (reminder, note13, note14, note15, note16, note19,
                                note20, note20b)
                    if t),
            }
        }))
    if m:
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

    # (10) gate output piped — a pipeline's exit code is the LAST command's, so a red gate
    #      reports green (`bash test/run.sh | tail -3` → tail exits 0), and the pipe also
    #      truncates the evidence (field: three occurrences 2026-07-10 / 08-09 / 08-12; the
    #      last one left "FAIL=1, which suite?" permanently unanswerable). LESSON
    #      pipe-masks-exit-code n=3 — this rule is its gate. Right shape: write the gate's
    #      output to a file, read rc directly, THEN grep the file.
    #      Command-position discipline as in (6): grepping/reading a *.test.sh path as an
    #      ARGUMENT must not trip this; only executing one does. `2>&1` is normalized away
    #      first so the redirect's `&` doesn't end the segment scan. `||` is a chain, not a
    #      pipe. Deliberately NOT covered (accept-documented, same boundary as (9): a regex
    #      cannot parse shell): command substitution `$(gate)`, process substitution,
    #      `set -o pipefail` preambles (pipefail fixes rc but still truncates evidence —
    #      recovery is the same file-first shape), and gate runners not matching the three
    #      naming families below.
    #      View construction and the command-position anchor are shared with rule (12):
    #      `_pipe_view` / `_POS_RUNNER` at module level, where both the normalization rationale
    #      and the wrapper set are documented.
    if re.search(_POS_RUNNER + r"[^;&|]*\|(?!\|)", vpipe):
        sys.stderr.write(
            "DENY: gate output piped — a pipeline's exit code is the LAST command's, so a "
            "red gate reports green, and the pipe truncates the evidence (bit us 3x; one "
            "red is permanently unattributable). Fix: run the gate with output to a file "
            "and read rc directly — `bash test/run.sh > /tmp/gate.log 2>&1; echo rc=$?` — "
            "then grep the log. Read: cto-orchestration/references/retrospective.md "
            "§教训分层沉淀.\n"
        )
        return 2
    # (10b) gate and `git commit` welded into one compound command with a `;` break —
    #       the commit no longer depends on the gate's rc (the `;` resets $?; whatever
    #       follows chains off an innocent middle command). 4th recurrence of the same
    #       family, this exact shape, committed THROUGH rule (10)'s pipe check the day
    #       after it shipped. A direct `gate && git commit` chain stays legal (rc-coupled,
    #       no `;`); runner as a mere argument (`git add x.test.sh; git commit`) does not
    #       match because the anchor requires command position.
    # BOUND sequence, not three global existence checks (review 2026-08-17 B2: a `;`
    # anywhere plus a legal `gate && git commit` direct chain was denied): the gate's own
    # segment must END at a `;` and the commit must come AFTER that break. A commit inside
    # the gate's segment (`gate && git commit; echo done`) is rc-coupled and stays legal.
    if re.search(_POS_RUNNER + r"[^;]*;.*\bgit\s[^|;]*\bcommit\b", vpipe):
        sys.stderr.write(
            "DENY: gate run and `git commit` in one `;`-broken compound — the commit no "
            "longer depends on the gate's rc (bit us 4x; the 4th sailed through the pipe "
            "check). Fix: run the gate alone and read rc first; commit in a SEPARATE "
            "command after the gate is green. Read: cto-orchestration/references/"
            "retrospective.md §教训分层沉淀.\n"
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
        # BOUNDARY, accept-documented (orchestrator ruling 2026-08-12 after two review rounds):
        # a regex cannot parse shell. Loop / brace expansion (`for u in a b; do … attach …; done`)
        # still executes N attaches under one approval, and can re-arm the marker through an
        # expansion this scan does not evaluate. Chasing shell semantics here is negative leverage
        # and guard regexes are the repo's most error-prone surface. What the rule buys is that
        # attaching is never the SILENT DEFAULT — a deliberately constructed loop is no longer
        # "doing it by accident", which is the failure this gate exists to prevent. It is a speed
        # bump on the default path, NOT a sandbox; do not read it as one.
        if len(re.findall(r"\battach\b", v9)) > 1 or marker in v9:
            sys.stderr.write(
                "DENY: an attach override authorizes exactly ONE attach and the approved command "
                "must not re-arm the marker. Fix: run a single `playwright-cli attach …` per "
                "approval, and never `touch /tmp/cto-allow-browser-attach` inside it. "
                "Read: cto-orchestration/references/frontend-verify.md\n"
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
