#!/usr/bin/env python3
"""narrative-check — process-narrative markers must stay out of canonical skill text.

Canonical text (SKILL.md / references) carries judging criteria and actions for the
reader at execution time. Adjudication history, sample tallies and incident provenance
belong to git log / the governance ledger — inlined they bloat the corpus and rot
(SHAs change, counts grow). This gate flags the marker shapes that identify such
narrative; fenced code blocks are exempt (worked examples of DENY text legitimately
embed dates).

Flagged (outside ``` fences):  （实证 / 实证： / 实证 20xx / 外部席位 / 评审实证 /
主理人定调 / owner 20xx / owner 裁 20xx / n=<k> 实证

Usage: narrative-check.py <file>...   exits 1 listing every hit.
"""

import re
import sys

PATTERNS = [
    re.compile(r"[（(]实证"),
    re.compile(r"实证[：:]"),
    re.compile(r"实证 20\d\d"),
    re.compile(r"外部席位"),
    re.compile(r"评审实证"),
    re.compile(r"主理人定调"),
    re.compile(r"owner (?:裁 )?20\d\d"),
    re.compile(r"n=\d+ 实证"),
]


def check_file(path: str) -> list[str]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        return [f"{path}: unreadable ({e})"]
    problems = []
    in_fence = False
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for rx in PATTERNS:
            m = rx.search(line)
            if m:
                problems.append(f"{path}:{i}: process narrative marker '{m.group(0)}'")
                break
    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print((__doc__ or "usage: narrative-check.py <file>...").strip(), file=sys.stderr)
        return 2
    problems = [p for f in argv[1:] for p in check_file(f)]
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
