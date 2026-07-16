#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/skills/repo-governance-bootstrap/references/templates.md"
COMMAND=$(sed -n 's/^> `\(missing=0;.*\)`。$/\1/p' "$TEMPLATE")

[ -n "$COMMAND" ] || { echo "FAIL: umbrella coverage command missing" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/dir-repo/.git" "$TMP/gitfile-repo"
printf 'gitdir: /tmp/example\n' > "$TMP/gitfile-repo/.git"

set +e
OUTPUT=$(cd "$TMP" && bash -c "$COMMAND" 2>&1)
RC=$?
set -e
[ "$RC" -eq 1 ] || { echo "FAIL: missing AGENTS must exit 1, got $RC" >&2; exit 1; }
grep -q 'MISSING: dir-repo/' <<<"$OUTPUT" || { echo "FAIL: directory .git repo not reported" >&2; exit 1; }
grep -q 'MISSING: gitfile-repo/' <<<"$OUTPUT" || { echo "FAIL: gitfile repo not reported" >&2; exit 1; }

touch "$TMP/dir-repo/AGENTS.md" "$TMP/gitfile-repo/AGENTS.md"
(cd "$TMP" && bash -c "$COMMAND")

echo "repo-governance templates: coverage gate clean"
