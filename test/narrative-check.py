#!/usr/bin/env python3
"""narrative-check — process-narrative markers must stay out of canonical skill text.

Canonical text (SKILL.md / references) carries judging criteria and actions for the
reader at execution time. Adjudication history, sample tallies and incident provenance
belong to git log / the governance ledger — inlined they bloat the corpus and rot
(SHAs change, counts grow). This gate flags the marker shapes that identify such
narrative; fenced code blocks are exempt (worked examples of DENY text legitimately
embed dates).

Flagged (outside ``` fences):  （实证 / 实证： / 实证 20xx / 外部席位 / 评审实证 /
主理人定调 / owner 20xx / owner 裁 20xx / n=<k> 实证 / 评审 R<k> F-0x (review-finding
provenance: WHY a rule was adopted belongs to git log, the rule itself is what canon carries)

Face: every markdown file under skills/ — SKILL.md, references/**, AND README.md. `--tree
<repo>` enumerates it (tracked + untracked-not-ignored) so the face lives here, not in a
caller's pathspec.

Usage: narrative-check.py <file>...  |  narrative-check.py --tree <repo>
       exits 1 listing every hit.
"""

import os
import re
import subprocess
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
    re.compile(r"评审 (?:R\d+ )?F-\d"),
    re.compile(r"\bR\d+ F-\d"),
]

# Exemptions — TEMPORARY narrowing scaffolding for widening this gate onto pre-existing
# files, NOT a long-term mechanism. Every line names its removal condition; an entry with
# no owner and no exit is a bug. Matched as a repo-relative path suffix.
EXEMPT = [
    # 待编排位清理后移除本行 — the review-finding provenance in agentctl's README predates
    # this gate's widening; the cleanup is the orchestrator's, not this gate's.
    "skills/cto-orchestration/references/agentctl/README.md",
]


def exempt(path: str) -> bool:
    norm = path.replace("\\", "/")
    return any(norm == e or norm.endswith("/" + e) for e in EXEMPT)


def face(repo: str) -> list[str]:
    """The canonical scan face, enumerated by this gate itself."""
    out = subprocess.run(["git", "-C", repo, "ls-files", "--cached", "--others",
                          "--exclude-standard", "skills/*.md"],
                         capture_output=True, text=True, check=True)
    return [os.path.join(repo, p) for p in out.stdout.split("\n") if p]


def check_file(path: str) -> list[str]:
    if exempt(path):
        return []
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
    targets = (face(argv[2]) if argv[1] == "--tree" and len(argv) == 3 else argv[1:])
    problems = [p for f in targets for p in check_file(f)]
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
