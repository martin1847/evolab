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
"""
import re
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
SCOPE_RE = re.compile(
    r"scope\s*=|全仓|全树|整仓|repo[ -]?根|repo-root"
    r"|(?:^|[\s（(=`,，])(?:\.{1,2}/|/)?"
    r"[A-Za-z0-9_.~*-]*[A-Za-z_][A-Za-z0-9_.~*-]*/[^\s`）),，]+")

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
PREMISE_LINE = re.compile(r"(?mi)^[\s>*+#-]*(?:\[[ x]\]\s*)?PREMISE\s*[:：]\s*(?P<rest>.*)$")
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
        if not (claim and probe and observed):
            faults.append((number, "三段都要有内容——claim / verify= / => observed 缺一即未声明"))
        elif PLACEHOLDER.search(m.group("rest")):
            faults.append((number, "占位符未解——把 `<…>` 换成真跑过的探针与观察到的结果"))
        elif UNRESOLVED.match(probe) or UNRESOLVED.match(observed):
            faults.append((number, "继承来的机理断言要核过活体才落笔；unresolved/N/A/TBD 不是证据"))
    return faults


def fail(message):
    print(
        "ERR: preflight gate: " + message
        + " Read cto-orchestration/references/goal-template.md.",
        file=sys.stderr,
    )
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
    warn(smelly_rows(body))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
