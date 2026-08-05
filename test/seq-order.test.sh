#!/usr/bin/env bash
# scripts/seq-check.py — ordinal-sequence integrity gate for shell tests/scripts.
# Negative fixtures replay the two real incidents that motivated the gate
# (2026-07-28 owner-promoted): a '6)' check inserted physically before '5)', and a
# duplicated 'Case' letter. Gaps stay legal (removals happen); order+uniqueness gate.
# Fixtures are printf-built: literal ladder lines in THIS file would be flagged by
# the repo-tree scan below (probed — the heredoc form flagged itself).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/seq-check.py"   # lives in test/ — scripts/ is a maintainer-local symlink, absent in CI
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
w(){ local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

echo "== seq-order.test =="
T="$(mktemp -d)"

# 1. clean ladders (with gaps and 6b/6c suffixes) pass
w "$T/good.sh" '# Case A — first' '# Case D — gap is fine' \
  'echo "1) first check:"' 'echo "3) gap is fine:"' \
  '# --- 6. base' '# --- 6b. suffix' '# --- 6c. suffix' '# --- 8. onward'
out="$(python3 "$CHECK" "$T/good.sh" 2>&1)"; assert_rc $? 0 "good ladder rc"

# 2. numbered check inserted before its predecessor → caught (real incident: 6 before 5)
w "$T/badnum.sh" 'echo "4) fine:"' 'echo "6) inserted early:"' 'echo "5) now late:"'
out="$(python3 "$CHECK" "$T/badnum.sh" 2>&1)"; rc=$?
assert_rc "$rc" 1 "echo out-of-order rc"
assert_has "$out" "out of order after" "echo out-of-order message"
assert_has "$out" "badnum.sh:3" "points at the offending line"

# 3. duplicated case letter → caught (real incident: E/F duplicates)
w "$T/dupcase.sh" '# Case E — first' '# Case F — fine' '# Case E — pasted again'
out="$(python3 "$CHECK" "$T/dupcase.sh" 2>&1)"; rc=$?
assert_rc "$rc" 1 "duplicate case rc"
assert_has "$out" "out of order after" "duplicate-or-regress flagged"

# 4. suffix ladder regression (6c then 6b) → caught
w "$T/badsuf.sh" '# --- 6c. later suffix' '# --- 6b. earlier suffix'
out="$(python3 "$CHECK" "$T/badsuf.sh" 2>&1)"; assert_rc $? 1 "suffix regression rc"

# 5. markdown layer-ladder: clean L0→L1→L2 (gaps fine) passes; reversed order — the
# real 2026-08-05 incident (L1,L2,L0 read fine in a diff; gate was shell-only) — caught
w "$T/good.md" '| 层 | 位置 |' '| --- | --- |' '| L0 prose | a |' '| L1 hook | b |' '| L3 gap | c |'
out="$(python3 "$CHECK" "$T/good.md" 2>&1)"; assert_rc $? 0 "md layer ladder clean rc"
w "$T/bad.md" '| L1 hook | a |' '| L2 ci | b |' '| L0 prose | c |'
out="$(python3 "$CHECK" "$T/bad.md" 2>&1)"; rc=$?
assert_rc "$rc" 1 "md reversed layer ladder rc"
assert_has "$out" "bad.md:3" "points at the reversed layer row"

# 6. the real tree is clean (tracked + untracked-not-ignored shell files + markdown)
files="$(git -C "$REPO" ls-files --cached --others --exclude-standard \
          "test/*.sh" "scripts/*.sh" "skills/**/*.sh" "*.md" | sed "s|^|$REPO/|")"
out="$(printf '%s\n' "$files" | xargs python3 "$CHECK" 2>&1)"; rc=$?
assert_rc "$rc" 0 "repo tree sequence-clean"
[ -n "$out" ] && echo "$out"

rm -rf "$T"
echo "== seq-order: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
