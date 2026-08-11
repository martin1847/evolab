#!/usr/bin/env bash
# test/narrative-check.py — process narrative stays out of canonical skill text.
# Negative fixtures replay the marker shapes the owner ruled out of skill prose
# (sample tallies, seat attributions, adjudication dates); positives pin the
# NORMATIVE look-alikes that must stay legal ('转 owner 裁决' is an action,
# '没实证先别立法' is a criterion, dates inside fenced worked examples are genre).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/narrative-check.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
w(){ local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

echo "== narrative.test =="
T="$(mktemp -d)"

# 1. narrative markers → red, points at line
w "$T/bad1.md" '规则正文（外部席位单日 n=3 实证：某事）' '第二行没事'
out="$(python3 "$CHECK" "$T/bad1.md" 2>&1)"; rc=$?
assert_rc "$rc" 1 "seat-attribution tally rc"
assert_has "$out" "bad1.md:1" "points at the offending line"
w "$T/bad2.md" '方向裁决（owner 2026-08-02，倾质量）：叙事段' '另一段 owner 裁 2026-08-06 收窄'
out="$(python3 "$CHECK" "$T/bad2.md" 2>&1)"; rc=$?
assert_rc "$rc" 1 "adjudication-date rc"
w "$T/bad3.md" '这样做（实证：某次事故……）' '写作纪律（主理人定调 2026-07-26）' 'R2 评审实证收编'
out="$(python3 "$CHECK" "$T/bad3.md" 2>&1)"; rc=$?
assert_rc "$rc" 1 "incident-parenthetical rc"
assert_has "$out" "bad3.md:2" "each narrative line reported"

# 2. normative look-alikes stay green
w "$T/good.md" '轮数耗尽转 owner 裁决' '（有过实证最佳；没实证先别立法）' \
  '样本门——n=1 只标 OBSERVATION' '带实证日期更佳'
out="$(python3 "$CHECK" "$T/good.md" 2>&1)"; assert_rc $? 0 "normative look-alikes rc"

# 3. fenced worked examples are exempt (DENY-text genre embeds dates)
w "$T/fence.md" '正文干净' '```text' 'Why: 2026-07-10 e2e 全红（实证）。' '```' '尾部干净'
out="$(python3 "$CHECK" "$T/fence.md" 2>&1)"; assert_rc $? 0 "fenced example exempt rc"

# 4. the real tree is clean — the face is the GATE's (`--tree`), not this caller's pathspec:
#    every skills/**/*.md including README.md, minus the declared exemptions.
out="$(python3 "$CHECK" --tree "$REPO" 2>&1)"; rc=$?
assert_rc "$rc" 0 "skills tree narrative-clean"
[ -n "$out" ] && echo "$out"

# 5. the widened face: a skill-internal README carrying review-finding provenance reds …
mkdir -p "$T/skills/x/references/y"
w "$T/skills/x/references/y/README.md" '判据正文' '取这个阈值是因为（评审 R2 F-03）曾误判' '尾部'
out="$(python3 "$CHECK" "$T/skills/x/references/y/README.md" 2>&1)"
assert_rc $? 1 "skill-internal README in the face"
# … and a declared exemption is skipped instead (temporary scaffolding, listed with an owner)
out="$(python3 "$CHECK" "$REPO/skills/cto-orchestration/references/agentctl/README.md" 2>&1)"
assert_rc $? 0 "declared exemption skipped"

rm -rf "$T"
echo "== narrative: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
