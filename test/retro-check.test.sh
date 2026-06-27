#!/usr/bin/env bash
# Test suite for cto-orchestration references/retro-check.sh (复盘仪式 hard gate).
# Hermetic: each case builds a temp git repo + bare origin + docs fixtures, runs
# the gate, asserts exit code + key output lines. NOTHING under test is modified.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/cto-orchestration/references/retro-check.sh"
TODAY="$(date +%F)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
assert_no(){ printf '%s' "$1" | grep -qF "$2" && no "$3: output should NOT have '$2'" || ok; }

# build a temp repo (work + bare origin) with green docs fixtures; echo work path
mkrepo(){
  local d work; d="$(mktemp -d)"; work="$d/work"
  git init -q -b main "$work" >/dev/null
  ( cd "$work"
    git config user.email t@t; git config user.name t
    mkdir -p docs/roadmap
    printf 'Last rewritten: %s\n' "$TODAY" > docs/ACTIVE_CONTEXT.md
    printf '# active roadmap\n' > docs/roadmap/active-roadmap.md
    printf 'a\nb\nc\n' > MEMORY.md
    git add -A; git commit -qm init
    git clone -q --bare "$work" "$d/origin.git"
    git remote add origin "$d/origin.git"; git push -q origin main
  )
  echo "$work"
}
run(){ ( cd "$1" && bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 ); }

echo "== retro-check.test =="

# Case A — all green → exit 0, no FAIL
r="$(mkrepo)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "A/all-green rc"
assert_has "$out" "0 FAIL" "A/all-green result"
assert_no  "$out" "[FAIL]" "A/all-green no fail lines"

# Case B — stale ACTIVE_CONTEXT → FAIL, exit non-zero
r="$(mkrepo)"; printf 'Last rewritten: 2020-01-01\n' > "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "B/stale-AC rc"
assert_has "$out" "ACTIVE_CONTEXT" "B/stale-AC names AC"
assert_has "$out" "stale" "B/stale-AC flags stale"

# Case C — stray worktree on MERGED branch → FAIL, exit non-zero
r="$(mkrepo)"
( cd "$r"
  git checkout -q -b feat; printf 'x\n' > f.txt; git add -A; git commit -qm feat
  git checkout -q main; git merge -q --no-edit feat; git push -q origin main
  git worktree add -q "$r-wt-feat" feat ) >/dev/null 2>&1
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "C/stray-worktree rc"
assert_has "$out" "stray worktree on MERGED" "C/stray-worktree flagged"

# Case D — MEMORY over cap → warn only (not FAIL), exit 0
r="$(mkrepo)"; seq 100 > "$r/MEMORY.md"
out="$( cd "$r" && bash "$SCRIPT" --base main --docs docs --memory MEMORY.md --memory-cap 45 2>&1 )"; rc=$?
assert_rc "$rc" 0 "D/mem-overcap rc (warn≠fail)"
assert_has "$out" "[warn]" "D/mem-overcap warns"
assert_has "$out" "> 45" "D/mem-overcap shows cap"

# Case E — missing ACTIVE_CONTEXT → FAIL
r="$(mkrepo)"; rm "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "E/missing-AC rc"
assert_has "$out" "not found" "E/missing-AC flagged"

echo "== retro-check: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
