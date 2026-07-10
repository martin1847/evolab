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

gate_script=scripts/engineering-gate.sh
gate_config=scripts/engineering-gate.conf
if [ -f "$gate_script" ] && [ -f "$gate_config" ]; then
  bash scripts/engineering-gate.sh check || exit $?
  bash scripts/engineering-gate.sh test || exit $?
elif [ -f "$gate_script" ] || [ -f "$gate_config" ]; then
  printf '\nproject-gate: BLOCKED — engineering/config\n' >&2
  if [ ! -f "$gate_script" ]; then
    printf 'Failed: missing %s\n' "$gate_script" >&2
  else
    printf 'Failed: missing %s\n' "$gate_config" >&2
  fi
  printf 'Fix:   restore both engineering gate files via repo-governance-bootstrap\n' >&2
  printf 'Retry: bash .githooks/pre-commit\n' >&2
  printf 'Read:\n' >&2
  printf '  AGENTS.md § Engineering Gate\n' >&2
  printf '  agent-backend-standard/references/engineering-interface.md\n' >&2
  exit 1
fi
