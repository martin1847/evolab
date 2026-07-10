#!/usr/bin/env bash
# Composite project gate installed by repo-governance-bootstrap.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'project-gate: BLOCKED — not inside a Git repository\n' >&2
  exit 1
}
cd "$ROOT" || exit 1

if [ -f scripts/docs-check.sh ]; then
  if ! bash scripts/docs-check.sh .; then
    printf '\nproject-gate: BLOCKED — docs/check\n' >&2
    printf 'Retry: bash scripts/docs-check.sh .\n' >&2
    printf 'Read:\n  AGENTS.md § Document governance\n  repo-governance-bootstrap/SKILL.md § 治理系统观\n' >&2
    exit 1
  fi
fi

if [ -f scripts/engineering-gate.conf ]; then
  bash scripts/engineering-gate.sh check || exit $?
  bash scripts/engineering-gate.sh test || exit $?
fi
