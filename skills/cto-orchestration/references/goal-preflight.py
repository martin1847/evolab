#!/usr/bin/env python3
"""Validate the cheapest-refutation contract before dispatch.

This is deliberately a shape/evidence-presence gate, not a truth oracle. The gate is on
by default (mechanical/forensic goals opt out with --no-preflight); the runtime refuses
missing, duplicate, placeholder, or unresolved declarations before launch.

SCAN SURFACE, stated because a reader WILL rediscover it otherwise (external seat did,
2026-08-18, with reproductions): the absence-claim scope check reads the Preflight line
ONLY. An absence claim in goal BODY prose — even using this gate's own vocabulary — is
not this gate's territory by design: body claims are premises, and premises flow through
goal-template §Premises (the consuming worker re-enumerates the scope and diffs) and
pre-dispatch goal-review. Extending the keyword scan to full text trades an unmeasured
false-positive surface for coverage the layered path already owns; if that trade is ever
re-priced, measure body-prose keyword density first.

PREMISE EXECUTION is the one half of this gate that is not shape-only. A premise probe written
as exactly ONE inline-code span is the author's per-line opt-in, so the gate runs it verbatim
and compares the author's OWN `rc=` / `count=` markers against the live reading. Only a
self-declared contradiction blocks: a marker-free observation gets its reading printed and no
verdict, a timeout or an unrunnable command WARNs, and a probe wearing any other shape — no span
at all, or prose mixed with one/several spans — is never executed but ALWAYS says so: a command
that is visually opted in and silently skipped reads to its author as verified. Each marker may
be declared at most once (a repeated `rc=` is a shape fault: only the first would ever be
consumed, so `prior rc=1; now rc=0` would otherwise be judged on the stale half). `count` counts
non-empty STDOUT lines only, and probe stderr is dropped: stderr
carries per-machine diagnostics (`grep: no such file`, deprecation banners) that would make a
declared count depend on the seat's environment instead of on the claim, and this gate's own
stderr is a contract surface an executed probe must not be able to write into. The operator
re-runs the command himself — every verdict prints it, with the cwd it ran in.

LIVE-TREE PROBE (2026-09-13) is a WARN-only shape reading of the same premise lines: a probe
whose path token lands in this goal's own write set (path tokens in `## Task / Deliverables`
plus the lane's `--deliverable` glob, GOAL_PREFLIGHT_DELIVERABLE) and that quotes no pinned
revision (`git show <rev>:` / `cat-file` / `ls-tree` / `git grep`) declares a reading the
deliverable itself will flip — the shape that failed four goals in two seats in four days.
It NEVER changes rc and never blocks: a probe asserting an invariant that must still hold
AFTER delivery wears the identical shape, and only the author knows which he wrote. It does
NOT parse the C09 closed-set format, sandbox nothing, and compares tokens as written rather
than by basename (owner ruling + accepted miss class — see the layer's own comment).
Environment: GOAL_PREFLIGHT_CWD = cwd probes run in (default: this process's cwd);
GOAL_PREFLIGHT_TIMEOUT = per-probe seconds, a POSITIVE FINITE number (default 120); anything else
(nan, inf, 0, negative, non-numeric) WARNs and falls back to the default, because `nan` is a legal
float that removes `communicate()`'s deadline altogether and makes the gate hangable again.
"""
import fnmatch
import math
import os
import re
import signal
import subprocess
import sys


# the keyword tolerates an inline （…）/(…) annotation and a full-width colon —
# `Preflight（编排者已实跑）: probe => result` is a legitimate declaration, and
# rejecting it taught goal authors to move load-bearing notes away from the line
LINE_RE = re.compile(
    r"(?mi)^.*?\bPreflight(\s*[（(][^）)\n]*[）)])?\s*[:：]\s*(.*?)\s*=>\s*(.*?)\s*$")
# Two arms, deliberately different in reach. The GENERIC words (`no`, `pending`, `todo`, …) are
# also legitimate openers of a real observation (`no such endpoint, rc=1`), so they only count as
# unresolved at end-of-declaration or before a `- : —` dash; `N/A` and `TBD` are never anything
# but unresolved, so they count with ANY tail — `N/A，待跑` and `TBD（待跑）` were the shapes
# people actually wrote and both counter-probed rc=0 against the tail-anchored version (cold
# review §3.1). The tail is unconstrained rather than a punctuation list on purpose: a full-width
# comma, a bracket and a bare Chinese clause are all the same non-evidence.
UNRESOLVED = re.compile(
    r"^(?:(?:result|observed|status)\s*:\s*)?"
    r"(?:(?:no|not[ -]?run|pending|todo|unknown|unverified)\s*(?:$|[-:—])"
    r"|(?:tbd|n/?a)(?![\w/]))",
    re.IGNORECASE,
)
# `<>` included (`*`, not `+`): an EMPTY placeholder is an unresolved declaration too, and
# `verify=<> => observed` passed the `+` version (cold review §3.2).
PLACEHOLDER = re.compile(r"<[^<>\n]*>")
# WARN-class smell only: an acceptance row asserting INTERNAL agreement (table vs registry)
# instead of observable behaviour is where same-source self-proof hides. Never blocks — this
# gate validates declaration shape and is never an oracle for oracle quality.
DONE_WHEN_RE = re.compile(r"(?msi)^##+ +Done[ -]?when.*?(?=^##+ |\Z)")
ROW_RE = re.compile(r"(?ms)^\s*- \[ \] (.+?)(?=^\s*[-*] |\Z)")
CONSISTENCY_RE = re.compile(
    r"一致|相同|等同|等价|镜像|匹配|同步|自洽|漂移|比对|对比"
    r"|in ?sync|consistent|matches?|mirrors?|identical|equals?|equivalent|drift",
    re.IGNORECASE,
)
# proof-shape, not vocabulary: a runnable command, an exit/return reading, or a named observation
EVIDENCE_RE = re.compile(
    r"`[^`\n]+`|\bexits? +\d|\brc *[=:]|\breturn(?:ed|s)? +\d|返回 *\d|退出码|exit[- ]?code|stdout|stderr"
    r"|--exit-code|变红|转红|观察到|observed|实测|真跑|探针|probe",
    re.IGNORECASE,
)


def warn(rows):
    for number, row in rows:
        first = " ".join(row.split())[:60]
        print(
            f"WARN: preflight: Done-when 第 {number} 条断言内部一致而未给可观察证据 — "
            f"坏样本打在承诺面了吗？{first} "
            "Read: cto-orchestration/references/review-dispatch.md §goal-review 仪器第 5 问.",
            file=sys.stderr,
        )


def smelly_rows(body):
    section = DONE_WHEN_RE.search(body)
    if not section:
        return []
    return [
        (number, row)
        for number, row in enumerate(ROW_RE.findall(section.group(0)), 1)
        if CONSISTENCY_RE.search(row) and not EVIDENCE_RE.search(row)
    ]


# absence-claim scope declaration (adopted 2026-08-17 from external-seat field evidence, n=6
# same-shape misses in two days, one would have deleted half an app): a negative control
# proves the DETECTOR works, not that the SCAN SURFACE was complete — two independent
# failure modes, and the second one was invisible because the scope lived only in the
# author's head. This check judges DECLARATION PRESENCE, not correctness (correctness is
# semantic, the consuming worker re-enumerates the scope and diffs — goal-template clause).
# Known boundary (accept-documented): a keyword list — rephrased absence claims slip
# through; this catches the ones written the way people actually write them.
# Corpus-bound vocabulary only (review 2026-08-17 M4): bare 不存在/没有任何 also match
# single-point runtime observations (`404，端点不存在`) which are NOT scans over a corpus —
# the discriminator requires reference/usage/call semantics. Corpus claims phrased with the
# bare words slip through: same word-list boundary as declared above, not a new one.
ABSENCE_RE = re.compile(
    r"零引用|零调用|零使用|未被引用|未被调用|[无没]有?任何(?:引用|调用|使用|命中)"
    r"|(?:引用|调用|使用)[^\n，。;]{0,4}不存在|仅在\s*\d|只在\s*\d"
    r"|zero\s+(?:references|usages|callers|hits)|no\s+(?:references|usages|callers)|unused",
    re.IGNORECASE,
)
# A scope declaration is scope=, a whole-tree word, or a PATH token. Path-ness is judged,
# not just a slash (review 2026-08-17 B1: URLs and dates/ratios satisfied a bare-slash
# test): URLs are stripped first, and the slash's left side must contain a letter.
_URL_RE = re.compile(r"https?://\S+")
# A path token may start absolute (`/Users/...`) or dot-relative (`./src`, `../lib`) —
# review R2: requiring the letter before the FIRST slash rejected both. The letter
# requirement moves to the first named segment; bare digits (8/17) still fail it.
# The path arm is named because a SECOND judgement now reads the same syntax (the write-set
# check below): one grammar, two consumers, so a path that counts as a scan root also counts
# as a probe target. SCOPE_RE's own pattern is byte-identical to before the extraction.
_PATH_ARM = (r"(?:\.{1,2}/|/)?"
             r"[A-Za-z0-9_.~*-]*[A-Za-z_][A-Za-z0-9_.~*-]*/[^\s`）),，]+")
SCOPE_RE = re.compile(
    r"scope\s*=|全仓|全树|整仓|repo[ -]?根|repo-root"
    r"|(?:^|[\s（(=`,，])" + _PATH_ARM)

# inherited-mechanism premise declaration (2026-08-28, n=3 field shape: a mechanism claim
# arrived by letter / prior transcript and was written into the next goal WITHOUT anyone
# re-probing the live system, so a stale premise propagated as a fact). The semantic half —
# "was this claim actually verified against a live system?" — needs the provenance chain from
# one prose sentence back to one verification action, which no regex / AST / file-existence
# check can produce; per shock-in-the-loop §1 判据② it is therefore NOT hard-gated here.
# What IS machine-decidable is the same thing this gate already judges for Preflight: that the
# declaration exists in full and carries no unresolved placeholder. Optional by design — a goal
# with no inherited premise writes no line and is judged on nothing.
# Anchored at line start (list markers and checkbox tolerated) so body prose "…the premise:
# X" is not read as a declaration; `Premises` (the goal-template section heading) has no colon
# after the keyword and never matches.
# The leading class is horizontal whitespace only (`[ \t]`, not `\s`): with `\n` in it the
# greedy prefix could start on the BLANK line above a `- [ ] PREMISE: …` row and swallow the
# newline, so every reported line number under a section break was one short — invisible while
# the only consumers were hand-written fixtures with no blank line above the row. Supported
# prefixes are ASCII horizontal indentation (space / Tab) plus the list-marker characters; a
# form-feed / vertical-tab / NBSP prefix is NOT supported — the old `\s` class matched those,
# this one does not, an accepted narrowing since goals indent with spaces and Tabs. CR is not in
# that family: the goal is read in TEXT mode, so a lone `\r` has already become a line break
# before this pattern ever runs (a regex-probed claim about `\r` does not describe the gate).
PREMISE_LINE = re.compile(r"(?mi)^[ \t>*+#-]*(?:\[[ x]\]\s*)?PREMISE\s*[:：]\s*(?P<rest>.*)$")
PREMISE_PARTS = re.compile(r"(?s)^(?P<claim>.*?)\bverify\s*=\s*(?P<probe>.*?)=>\s*(?P<obs>.*)$")


def premise_faults(body):
    """(line-number, message) for every malformed inherited-premise declaration."""
    faults = []
    for m in PREMISE_LINE.finditer(body):
        number = body.count("\n", 0, m.start()) + 1
        parts = PREMISE_PARTS.match(m.group("rest"))
        if not parts:
            faults.append((number, "写全三段 `PREMISE: <claim> verify=<cmd|live-probe> => "
                                   "<observed>`——缺 verify= 或 => 的继承断言只是散文"))
            continue
        claim, probe, observed = (part.strip() for part in parts.groups())
        duplicate = marker_duplicate(observed)
        if not (claim and probe and observed):
            faults.append((number, "三段都要有内容——claim / verify= / => observed 缺一即未声明"))
        elif PLACEHOLDER.search(m.group("rest")):
            faults.append((number, "占位符未解——把 `<…>` 换成真跑过的探针与观察到的结果"))
        elif UNRESOLVED.match(probe) or UNRESOLVED.match(observed):
            faults.append((number, "继承来的机理断言要核过活体才落笔；unresolved/N/A/TBD 不是证据"))
        elif duplicate:
            faults.append((number, duplicate))
    return faults


# The executable half of the premise contract: exactly ONE inline-code span and nothing else is
# the author's per-line opt-in. Any other shape is never executed but is ALWAYS reported as not
# run: a probe MIXING prose with a span (`verify=`agentctl status s1` 读 round`) or carrying two
# spans is not runnable as written, and staying silent about it (the shape's first delivered
# behaviour, review 2026-09-10 B1) let a visually opted-in command read as verified. A probe with
# no inline code at all is a live-probe recipe and is likewise told it was not run.
PROBE_CMD = re.compile(r"^`([^`\n]+)`$")
# word-boundary markers, so `src=` / `recount=` can never impersonate one
MARKERS = (("rc", re.compile(r"\brc\s*=\s*(\d+)\b")),
           ("count", re.compile(r"\bcount\s*=\s*(\d+)\b")))
CWD_ENV, TIMEOUT_ENV, DEFAULT_TIMEOUT = "GOAL_PREFLIGHT_CWD", "GOAL_PREFLIGHT_TIMEOUT", 120.0
# 126/127 are the shell's own "I could not run this" answers (not executable / not found), read
# as an unrunnable probe and never as a refutation: a tool missing on THIS machine says nothing
# about the claim, and only a self-declared contradiction may block a dispatch.
UNRUNNABLE = (126, 127)


def advise(message):
    print("WARN: preflight: " + message, file=sys.stderr)


def marker_duplicate(observed):
    """Message if the observation declares one marker twice — a shape fault, not a verdict.

    The comparison consumes exactly one value per marker, so `prior rc=1; now rc=0` would be
    judged on the stale half and `now rc=0; also rc=1` would hide the author's own conflict.
    Uniqueness is decided on shape, before anything in the batch runs.
    """
    for name, pattern in MARKERS:
        hits = pattern.findall(observed)
        if len(hits) > 1:
            return f"记号重复：{name}= 出现 {len(hits)} 次，只能声明一次"
    return None


def probe_timeout():
    """Per-probe deadline: a positive finite number of seconds, else the default plus a WARN.

    `float("nan")` parses fine and then makes every `communicate()` deadline comparison false,
    i.e. no deadline at all — the knob would turn the dispatch gate back into a hangable path.
    """
    raw = os.environ.get(TIMEOUT_ENV)
    if not raw:
        return DEFAULT_TIMEOUT
    try:
        seconds = float(raw)
    except ValueError:
        seconds = float("nan")
    if not math.isfinite(seconds) or seconds <= 0:
        advise(f"{TIMEOUT_ENV}={raw} 不是正的有限秒数，回退默认 {DEFAULT_TIMEOUT:g}s")
        return DEFAULT_TIMEOUT
    return seconds


def premise_probes(body):
    """(line-number, probe, observed) for every three-part premise declaration."""
    for m in PREMISE_LINE.finditer(body):
        parts = PREMISE_PARTS.match(m.group("rest"))
        if not parts:
            continue
        claim, probe, observed = (part.strip() for part in parts.groups())
        if claim and probe and observed:
            yield body.count("\n", 0, m.start()) + 1, probe, observed


# ---- live-tree probe morphology (2026-09-13, field n=4 across two seats) --------------------
# The disease: a premise probe reads a path THIS goal is about to change, so the reading it
# declares flips the moment the deliverable lands — the goal then fails its own gate on the
# fix round (own repo 2026-09-10, LESSON premise-anchored-to-live-tree; three more downstream
# on 2026-09-13, same shape every time). Judged on the probe TEXT alone: never on whether the
# probe ran, never on its result, and it NEVER changes rc — a probe deliberately asserting an
# invariant that must still hold AFTER delivery is a legitimate live-tree probe, and only the
# author knows which of the two he wrote. So: one WARN naming the line and the path.
# The write set is declared, not discovered: path tokens inside the `## Task / Deliverables`
# section plus the `--deliverable` glob the lane already knows (GOAL_PREFLIGHT_DELIVERABLE).
# NOT parsed (owner ruling 2026-09-13): the C09 closed-set format — a second, richer grammar
# for the same question buys recall this gate cannot price, and the two would drift.
# Tokens are compared AS WRITTEN (after absolute→seat-relative normalization), never by
# basename: a goal that says it edits `goal-preflight.py` and a probe that reads
# `skills/…/references/goal-preflight.py` are not matched, because a basename rule makes every
# same-named file in the tree a hit. Accepted boundary, stated because it IS a miss class.
DELIVERABLE_ENV = "GOAL_PREFLIGHT_DELIVERABLE"
# The TITLE TEXT (`#` and any leading number removed) must START with Task / Deliverable: a
# substring rule read `## Out of scope / Tasks not done` as a write set, i.e. reported the very
# paths the goal swore off.
WRITE_SECTION_RE = re.compile(
    r"(?msi)^##+ +(?:\d+[.)、]\s*)?(?:Task|Deliverable)[^\n]*\n(.*?)(?=^##+ |\Z)")
# A bare FILENAME is a write-set path too (`改 README.md`), which SCOPE_RE's arm cannot see:
# there a slash is what proves path-ness, here the dotted extension does. An extension is a run
# of ≥2 characters containing a letter, which is what keeps `e.g.` / `i.e.` (1 char), `v1.7.10`
# / `8.17` (no letter) and `39.5` out; `example.com` remains indistinguishable from a file by
# morphology alone — accepted false WARN, counted against the false-WARN budget, not hidden.
_FILE_ARM = (r"[A-Za-z0-9_~*-]*[A-Za-z_][A-Za-z0-9_~*-]*"
             r"(?:\.(?=[A-Za-z0-9_~*-]*[A-Za-z])[A-Za-z0-9_~*-]{2,8})+")
# A trailing slash is the other way a directory is written (`docs/`); `docs/api` already arrives
# through _PATH_ARM, whose tail needs a character after the slash. Bare `docs` with no slash at
# all stays a miss: a word that common cannot be read as a path. Separate arm on purpose —
# SCOPE_RE's grammar stays byte-identical, because a scan-面 declaration is a different question.
_DIR_ARM = r"(?:\.{1,2}/|/)?[A-Za-z0-9_.~*-]*[A-Za-z_][A-Za-z0-9_.~*-]*/"
PATH_TOKEN_RE = re.compile(
    r"(?:^|[\s（(=`,，:：])(" + _PATH_ARM + "|" + _FILE_ARM + "|" + _DIR_ARM + ")")
# pinned-shape, not rev-parsing: any of these reads a committed object, so its answer cannot
# be changed by this goal's own deliverable. Any distance between `git` and the verb, because a
# length window only ever mis-read a long `git -C <path> show <rev>:` as live and WARNed on it.
PINNED_RE = re.compile(r"\bgit\b[^`\n]*?\b(?:show\s+[^\s`]+:|cat-file|ls-tree|grep)\b")
_TRAILING = "。，、；：,.;:!！?？)）」』】>"
LIVE_PROBE_MSG = ("{where} 活树探针命中本 goal 写集路径 {path}——交付物一落地它就翻转；"
                  "描述 base 状态请改 pinned 形态（git show <base sha>:{path} | …），"
                  "交付后仍应成立的不变量可忽略本行")
WRITE_SET_NOTE = "该路径在本 goal 写集内；若探针本意是描述 base 状态，改 pinned 形态。"


def seat_cwd():
    """The cwd probes are read against — the seat's tree, or this process's own."""
    return os.environ.get(CWD_ENV) or os.getcwd()


def path_tokens(text):
    """Every path-shaped token in one text, in order, de-duplicated. URLs never count."""
    tokens = []
    for hit in PATH_TOKEN_RE.finditer(_URL_RE.sub("", text)):
        token = hit.group(1).strip("`")
        if token.startswith("**") and token.endswith("**"):
            token = token[2:-2]      # markdown bold AROUND a path — both ends, or `**` globs
        elif token.endswith("**"):
            token = token[:-2]
        token = token.rstrip(_TRAILING)
        if token and token not in tokens:
            tokens.append(token)
    return tokens


def repo_relative(token, cwd):
    """Seat-relative form of one token, or None when it cannot name a file in this tree.

    An absolute path is normalized against the SEAT cwd (that is the tree the probe runs in);
    anything resolving outside it, and `~`-relative text this gate would have to expand with
    the wrong user's home, is not this goal's write set and is dropped in silence.
    """
    if token.startswith("~"):
        return None
    try:
        token = os.path.relpath(token, cwd) if os.path.isabs(token) else os.path.normpath(token)
    except (OSError, ValueError):
        return None
    return None if token.startswith("..") or token in (".", "") else token


def write_set(body, cwd):
    """Paths this goal declares it will change: Task / Deliverables tokens ∪ the lane's glob."""
    entries = []
    for section in WRITE_SECTION_RE.finditer(body):
        for token in path_tokens(section.group(1)):
            rel = repo_relative(token, cwd)
            if rel and rel not in entries:
                entries.append(rel)
    raw = (os.environ.get(DELIVERABLE_ENV) or "").strip()
    if raw:
        rel = repo_relative(raw, cwd)
        if not rel:
            advise(f"{DELIVERABLE_ENV}={raw} 归一不到席位树内路径，写集只取 Task / Deliverables 节")
        elif rel not in entries:
            entries.append(rel)
    return entries


def write_set_hit(token, entries):
    """The write-set entry this token reads — equality, under a declared dir, or glob match."""
    for entry in entries:
        if (token == entry or token.startswith(entry.rstrip("/") + "/")
                or fnmatch.fnmatch(token, entry)):
            return entry
    return None


def live_probe_paths(body):
    """{line-number: path} for every premise probe reading a write-set path off the live tree."""
    cwd = seat_cwd()
    entries = write_set(body, cwd)
    hits = {}
    for number, probe, _ in premise_probes(body) if entries else ():
        if PINNED_RE.search(probe):
            continue
        for token in path_tokens(probe):
            rel = repo_relative(token, cwd)
            if rel and write_set_hit(rel, entries):
                hits[number] = rel
                break
    return hits


def run_probe(command, cwd, timeout):
    """(exit code, non-empty stdout lines) — the probe verbatim, never re-typed."""
    with subprocess.Popen(command, shell=True, cwd=cwd, text=True,
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, start_new_session=True) as proc:
        try:
            out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # the whole process GROUP, not just the shell: `cmd &` inside the probe keeps the
            # stdout pipe open, and the post-kill read would then wait forever — a dispatch
            # gate that can hang is worse than one that WARNs
            os.killpg(proc.pid, signal.SIGKILL)
            raise
        return proc.returncode, sum(1 for line in out.splitlines() if line.strip())


def premise_contradiction(body, live_paths=()):
    """Run every opt-in probe; message for the first declaration its own command refutes."""
    cwd = seat_cwd()
    timeout = probe_timeout()
    for number, probe, observed in premise_probes(body):
        where = f"PREMISE 行(第 {number} 行)"
        span = PROBE_CMD.match(probe)
        if not span:
            if "`" in probe:
                advise(f"{where} 未执行（混排 / 多段反引号；"
                       f"要执行请把整条命令放进一个反引号段）：{probe}")
            else:
                advise(f"{where} 未执行（非命令形态）：{probe}")
            continue
        command = span.group(1)
        try:
            code, count = run_probe(command, cwd, timeout)
        except subprocess.TimeoutExpired:
            advise(f"{where} 超时 {timeout:g}s，未判（不拒发）：`{command}`")
            continue
        except OSError as exc:
            advise(f"{where} 无法执行，未判（不拒发）：`{command}` — {exc}")
            continue
        if code in UNRUNNABLE:
            advise(f"{where} 无法执行（shell rc={code}），未判（不拒发）：`{command}`")
            continue
        got = {"rc": code, "count": count}
        declared = []
        for name, pattern in MARKERS:
            hit = pattern.search(observed)
            if hit:
                declared.append((name, int(hit.group(1))))
        if not declared:
            advise(f"{where} 未声明记号，只报实况（不判）：rc={code} count={count} — `{command}`")
            continue
        for name, want in declared:
            if want != got[name]:
                verdict = (f"{where} 实跑与声明不符：declared {name}={want}, got {name}={got[name]}"
                           f"（probe `{command}`，cwd {cwd}）。")
                # the same predicate, on the rejection path: a refuted reading whose path this
                # goal is about to rewrite is most often the live-tree shape, not a false claim
                return (verdict + WRITE_SET_NOTE) if number in live_paths else verdict
    return None

def fail(message, read="Read cto-orchestration/references/goal-template.md."):
    print("ERR: preflight gate: " + message + " " + read, file=sys.stderr)
    return 1


def main():
    if len(sys.argv) != 2:
        return fail("usage: goal-preflight.py <goal-file>")
    try:
        body = open(sys.argv[1], encoding="utf-8").read()
    except OSError as exc:
        return fail(f"cannot read goal: {exc}")
    matches = LINE_RE.findall(body)
    if len(matches) != 1:
        return fail(f"expected exactly one 'Preflight: <probe> => <observed result>' line; found {len(matches)}")
    note, probe, observed = (part.strip() for part in matches[0])
    # the annotation is part of the declaration — a placeholder hiding there is
    # just as unresolved as one in the probe/result halves
    if not probe or not observed or PLACEHOLDER.search(note + probe + observed):
        return fail("replace every placeholder with the probe actually run and its observed result")
    if UNRESOLVED.match(probe) or UNRESOLVED.match(observed):
        return fail("the cheapest refutation must be run before dispatch; unresolved/N/A is not evidence")
    line = LINE_RE.search(body).group(0)
    if ABSENCE_RE.search(line) and not SCOPE_RE.search(_URL_RE.sub("", line)):
        return fail(
            "缺席断言未声明扫描面——负对照只证明探测器有效，不证明扫描面完整"
            "（外部实证：范围只在作者脑内的『零引用』差点删掉半个应用）。"
            "同一行写出扫描根（路径 token / scope=… / 全仓），"
            "消费该前提的 worker 独立重列范围做差集。")
    faults = premise_faults(body)
    if faults:
        number, why = faults[0]
        return fail(f"PREMISE 行(第 {number} 行)未成立声明：{why}。")
    live_paths = live_probe_paths(body)
    for number, path in sorted(live_paths.items()):
        advise(LIVE_PROBE_MSG.format(where=f"PREMISE 行(第 {number} 行)", path=path))
    contradiction = premise_contradiction(body, live_paths)
    if contradiction:
        return fail(contradiction,
                    "Read: cto-orchestration/references/goal-template.md §Premises.")
    warn(smelly_rows(body))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
