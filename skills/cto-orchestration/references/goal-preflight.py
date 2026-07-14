#!/usr/bin/env python3
"""Validate the opt-in cheapest-refutation contract before dispatch.

This is deliberately a shape/evidence-presence gate, not a truth oracle. The orchestrator
explicitly selects it with --require-preflight for uncertain, expensive directions; the
runtime refuses missing, duplicate, placeholder, or unresolved declarations before launch.
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
