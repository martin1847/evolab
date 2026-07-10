#!/usr/bin/env bash
# Hermetic order/failure tests for the composite pre-commit template.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../skills/repo-governance-bootstrap/references/pre-commit.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); printf '  FAIL: %s\n' "$*"; }
has(){ case "$1" in *"$2"*) ok ;; *) no "$3: missing [$2]" ;; esac; }
eq(){ [ "$1" = "$2" ] && ok || no "$3: expected [$2] got [$1]"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/repo"
LOG="$TMP/order.log"
mkdir -p "$ROOT/scripts" "$ROOT/.githooks" "$ROOT/subdir"
git -C "$ROOT" init -q
cp "$SOURCE" "$ROOT/.githooks/pre-commit"
chmod +x "$ROOT/.githooks/pre-commit"
touch "$ROOT/scripts/engineering-gate.conf"

cat > "$ROOT/scripts/docs-check.sh" <<'STUB'
#!/usr/bin/env bash
printf 'docs\n' >> "$PRECOMMIT_TEST_LOG"
[ "${FAIL_STAGE:-}" != docs ]
STUB
cat > "$ROOT/scripts/engineering-gate.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$PRECOMMIT_TEST_LOG"
[ "${FAIL_STAGE:-}" != "$1" ] || {
  printf 'engineering-gate: BLOCKED — fake/%s\n' "$1" >&2
  exit 1
}
STUB
chmod +x "$ROOT/scripts/docs-check.sh" "$ROOT/scripts/engineering-gate.sh"
export PRECOMMIT_TEST_LOG="$LOG"

echo '== pre-commit-gate.test =='

out="$(cd "$ROOT/subdir" && bash ../.githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 0 'green rc'
order="$(paste -sd, "$LOG")"
eq "$order" 'docs,check,test' 'gate order'

: > "$LOG"
export FAIL_STAGE=check
out="$(cd "$ROOT" && bash .githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 1 'check failure rc'
order="$(paste -sd, "$LOG")"
eq "$order" 'docs,check' 'check failure stops test'
has "$out" 'engineering-gate: BLOCKED' 'engineering failure preserved'
unset FAIL_STAGE

: > "$LOG"
export FAIL_STAGE=docs
out="$(cd "$ROOT" && bash .githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 1 'docs failure rc'
order="$(paste -sd, "$LOG")"
eq "$order" 'docs' 'docs failure stops engineering'
has "$out" 'AGENTS.md § Document governance' 'docs failure local standard'
has "$out" 'repo-governance-bootstrap/SKILL.md § 治理系统观' 'docs failure canonical standard'
unset FAIL_STAGE

mv "$ROOT/scripts/engineering-gate.conf" "$ROOT/scripts/engineering-gate.conf.off"
out="$(cd "$ROOT" && bash .githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 1 'missing config blocks'
has "$out" 'Failed: missing scripts/engineering-gate.conf' 'missing config exact failure'
has "$out" 'AGENTS.md § Engineering Gate' 'missing config local standard'
has "$out" 'agent-backend-standard/references/engineering-interface.md' 'missing config canonical standard'
mv "$ROOT/scripts/engineering-gate.conf.off" "$ROOT/scripts/engineering-gate.conf"

mv "$ROOT/scripts/engineering-gate.sh" "$ROOT/scripts/engineering-gate.sh.off"
out="$(cd "$ROOT" && bash .githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 1 'missing script blocks'
has "$out" 'Failed: missing scripts/engineering-gate.sh' 'missing script exact failure'
mv "$ROOT/scripts/engineering-gate.sh.off" "$ROOT/scripts/engineering-gate.sh"

mv "$ROOT/scripts/engineering-gate.conf" "$ROOT/scripts/engineering-gate.conf.off"
mv "$ROOT/scripts/engineering-gate.sh" "$ROOT/scripts/engineering-gate.sh.off"
out="$(cd "$ROOT" && bash .githooks/pre-commit 2>&1)"; rc=$?
eq "$rc" 0 'docs-only skips engineering only when both files absent'
mv "$ROOT/scripts/engineering-gate.conf.off" "$ROOT/scripts/engineering-gate.conf"
mv "$ROOT/scripts/engineering-gate.sh.off" "$ROOT/scripts/engineering-gate.sh"

echo "== pre-commit-gate: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
