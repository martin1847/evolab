#!/usr/bin/env bash
# repo-gov pre-push.template — driver contract. The skeleton ships with ZERO gates, so what
# it must guarantee is the DRIVER: fail-closed on unresolvable ranges (cold-review catch
# 2026-07-26: a new-branch push with no baseline ran zero gates and exited 0), usage-fail on
# malformed --range, and clean pass on resolvable ranges.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

TPL="$(pwd)/../skills/repo-governance-bootstrap/references/pre-push.template"

echo "== repo-gov pre-push.template driver =="

if ! command -v git >/dev/null 2>&1; then
  echo "    git not on PATH — skipped"; exit 0
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$T"
R="$T/repo"
mkdir -p "$R" && cd "$R"
git init -q -b main .
echo a > f && git add f && git commit -qm c1
C1="$(git rev-parse HEAD)"
echo b >> f && git add f && git commit -qm c2
C2="$(git rev-parse HEAD)"
ZOID="$(printf '%040d' 0)"   # built, not literal: the redaction gate flags long digit runs

run_tpl() { # args... ; stdin piped by caller when needed -> OUT ERR RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(bash "$TPL" "$@" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}

# --range mode
run_tpl --range "$C1..$C2" < /dev/null
chk_eq "valid --range with zero gates passes" 0 "$RC"
run_tpl --range < /dev/null
chk_eq "--range without value usage-fails" 2 "$RC"; chk_contains "usage message" "usage" "$ERR"
run_tpl --range "no-such-ref..$C2" < /dev/null
chk_eq "unresolvable --range fails closed" 2 "$RC"; chk_contains "names the bad range" "no-such-ref" "$ERR"

# hook (stdin) mode
run_tpl_stdin() { # $1 stdin line -> OUT ERR RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(printf '%s\n' "$1" | bash "$TPL" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
run_tpl_stdin "refs/heads/x $C2 refs/heads/x $C1"
chk_eq "known remote OID update passes" 0 "$RC"
run_tpl_stdin "refs/heads/x $ZOID refs/heads/x $C1"
chk_eq "ref delete is skipped" 0 "$RC"
run_tpl_stdin "refs/heads/x $C2 refs/heads/x $ZOID"
chk_eq "new branch w/o baseline fails closed" 1 "$RC"
chk_contains "tells how to configure baseline" "hooks.baseline" "$ERR"
git config hooks.baseline main
run_tpl_stdin "refs/heads/x $C2 refs/heads/x $ZOID"
chk_eq "new branch with configured baseline passes" 0 "$RC"
run_tpl_stdin "refs/heads/x $C2 refs/heads/x aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
chk_eq "unknown remote OID falls back to baseline" 0 "$RC"
git config --unset hooks.baseline
run_tpl_stdin "refs/heads/x $C2 refs/heads/x aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
chk_eq "unknown remote OID w/o baseline fails closed" 1 "$RC"

# outside a git repo the hook must not explode (template's early exit 0)
cd "$T"
run_tpl_stdin "refs/heads/x $C2 refs/heads/x $C1"
chk_eq "outside a repo exits 0 (no-op)" 0 "$RC"

summary
