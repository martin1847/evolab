#!/usr/bin/env python3
"""Validate the cheapest-refutation contract before dispatch.

This is deliberately a shape/evidence-presence gate, not a truth oracle. The gate is on
by default (mechanical/forensic goals opt out with --no-preflight); the runtime refuses
missing, duplicate, placeholder, or unresolved declarations before launch.
"""
import re
import sys


LINE_RE = re.compile(r"(?mi)^.*?\bPreflight:\s*(.*?)\s*=>\s*(.*?)\s*$")
UNRESOLVED = re.compile(
    r"^(?:(?:result|observed|status)\s*:\s*)?"
    r"(?:no|not[ -]?run|pending|todo|tbd|unknown|unverified|n/?a)"
    r"\s*(?:$|[-:—])",
    re.IGNORECASE,
)
PLACEHOLDER = re.compile(r"<[^<>\n]+>")
# WARN-class smell only: an acceptance row asserting INTERNAL agreement (table vs registry)
# instead of observable behaviour is where same-source self-proof hides. Never blocks — the
# gate validates shape, never oracle quality (see meta/truth_not_eq_checker_output.md).
CHECKLIST_RE = re.compile(r"(?m)^\s*- \[ \] (.+)$")
CONSISTENCY_RE = re.compile(
    r"一致|相同|匹配|同步|自洽|漂移|比对|对比|in sync|consistent|matches|drift", re.IGNORECASE
)
BEHAVIOUR_RE = re.compile(
    r"行为|实际|观察|运行|执行|调用|发出|变红|红|绿|输出|探针|exit|rc\b|stdout|stderr|emit|frame|probe",
    re.IGNORECASE,
)


def warn(rows):
    for number, row in rows:
        print(
            f"WARN: preflight: Done-when 第 {number} 条断言内部自洽而没有可观察行为 — "
            f"坏样本打在承诺面了吗？{row[:60]} "
            "Read: cto-orchestration/references/review-dispatch.md §goal-review 仪器第 5 问.",
            file=sys.stderr,
        )


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
    probe, observed = (part.strip() for part in matches[0])
    if not probe or not observed or PLACEHOLDER.search(probe + observed):
        return fail("replace every placeholder with the probe actually run and its observed result")
    if UNRESOLVED.match(probe) or UNRESOLVED.match(observed):
        return fail("the cheapest refutation must be run before dispatch; unresolved/N/A is not evidence")
    warn([
        (number, row)
        for number, row in enumerate(CHECKLIST_RE.findall(body), 1)
        if CONSISTENCY_RE.search(row) and not BEHAVIOUR_RE.search(row)
    ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
