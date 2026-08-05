#!/usr/bin/env python3
"""seq-check — ordinal-sequence integrity for shell tests/scripts.

Insertion edits pick a label and an anchor independently, so a locally-correct
label lands in the wrong place ('6)' inserted before '5)', 'Case E' duplicated) and
reads fine in a diff. ORDER and UNIQUENESS per file are the invariants; gaps are
allowed (removals are legitimate). Patterns (shell files):

  # Case <A-Z> ...        test case ladders
  # --- <n><suffix>. ...  numbered section comments (6b/6c style suffixes)
  echo "<n>) ...          user-visible numbered check headers

Markdown files (tables):

  | L<n> ...              layer-ladder table rows (L0/L1/L2 — 2026-08-05 incident:
                          a reversed L-table read fine in a diff; gate was shell-only)

Usage: seq-check.py <file>...   exits 1 listing every out-of-order/duplicate label.
"""

import re
import sys

PATTERNS = [
    ("case-letter", re.compile(r'^#\s*(?:---\s*)?Case\s+([A-Z]+)\b')),
    ("section-num", re.compile(r'^#\s*---\s*(\d+)([a-z]?)[.)]')),
    ("echo-num", re.compile(r'^echo\s+"(\d+)\)')),
    ("layer-num", re.compile(r'^\|\s*L(\d+)\b')),
]


def label_key(name: str, m: re.Match) -> tuple:
    if name == "case-letter":
        s = m.group(1)
        return (len(s), s)  # Z < AA
    if name == "section-num":
        return (int(m.group(1)), m.group(2))
    return (int(m.group(1)),)


def check_file(path: str) -> list[str]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        return [f"{path}: unreadable ({e})"]
    problems = []
    last: dict[str, tuple] = {}
    last_label: dict[str, str] = {}
    for i, line in enumerate(lines, 1):
        for name, rx in PATTERNS:
            m = rx.match(line)
            if not m:
                continue
            key = label_key(name, m)
            label = m.group(0).strip()
            if name in last and key <= last[name]:
                kind = "duplicates" if key == last[name] else "out of order after"
                problems.append(f"{path}:{i}: [{name}] '{label}' {kind} '{last_label[name]}'")
            last[name] = key
            last_label[name] = label
            break
    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print((__doc__ or "usage: seq-check.py <file>...").strip(), file=sys.stderr)
        return 2
    problems = [p for f in argv[1:] for p in check_file(f)]
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
