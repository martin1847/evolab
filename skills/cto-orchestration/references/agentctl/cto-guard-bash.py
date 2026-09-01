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
    True = the number is a FLOOR (a corrupt ledger was reset, or the bump could not be
    persisted), which the warn says out loud instead of publishing a floor as a count."""
    run_dir = os.environ.get("AGENT_WATCH_DIR") or "/tmp/agent-watch-run"
    path = os.path.join(run_dir, "babysit-%d-%s.json" % (os.getuid(), time.strftime("%Y%m%d")))
    soft = False
    try:
        with open(path, "r", encoding="utf-8") as fh:
            tally = json.load(fh)
        if not isinstance(tally, dict):
            tally, soft = {}, True
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
            json.dump(tally, fh)
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
# SHAPE: command-position `agentctl start codex … --review` with no `--max-rounds` token.
# The lane itself refuses `--review` with `--resume-thread`, so that pair is not judged twice
# here. Judged on the segment VIEW as an exact TOKEN, so `--goal /tmp/--review.md` (a path that
# merely contains the flag text) is not a review dispatch and `--max-rounds=2` is not the
# lane's spelling of a budget — agentctl parses only `--max-rounds N`.
_SEG_REVIEW = re.compile(r"^\s*(?:" + _ENV_ASSIGN + r"\s+)*" + _WRAPPER
                         + _AGENTCTL + r"\s+start\s+codex(?![\w-])")


def _review_without_budget(raw):
    """True when any command-position codex dispatch asks for a review seat with no budget."""
    for seg in _cmd_segments(raw):
        view = _pipe_view(seg)
        if not _SEG_REVIEW.match(view):
            continue
        toks = view.split()
        if "--review" not in toks or "--resume-thread" in toks:
            continue
        if "--max-rounds" not in toks:
            return True
    return False


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
    cmd8 = re.sub(r"(^|[^\\])((?:\\\\)*)\\\r?\n", r"\g<1>\g<2>", raw).replace("\n", ";")
    v8 = re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2", cmd8).replace("\\", "")
    # the shell EXECUTION face: rule 8's normalization, plus multi-word quoted spans collapsed
    # to QSPAN so a mention inside `echo "…"` / `grep "…"` stays DATA rather than a command.
    def _exec_face(s):
        return _strip_spans(re.sub(r"\$?([\"'])([^\s\"']*)\1", r"\2", s).replace("\\", ""))
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
            % (_R16_WARN_AT, sess, n16, "计数未落盘，读数是下限、不可判。" if degraded else "")
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
    # (13), (14)/(15)'s instrument warnings and (16)'s counter ride (3)'s channel: on exit 0
    # only additionalContext reaches the agent, and two JSON documents on stdout would be one
    # malformed hook response. All five strings stay LOCAL to this frame so the injected-text
    # ratchet can weigh what a worker is actually handed.
    if reminder or note13 or note14 or note15 or note16:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": "\n".join(
                    t for t in (reminder, note13, note14, note15, note16) if t),
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
