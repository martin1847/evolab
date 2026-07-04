#!/usr/bin/env bash
# mirror-sync — coding-discipline mirror pair consistency gate.
# Truth pair: templates/rules/coding.md (rules form, conditional `paths:` loading)
#         ⇄  skills/source-coding-discipline/SKILL.md (skill form, for agents w/o conditional rules)
# The four discipline paragraphs must stay byte-identical across both files.
# Includes a negative case: a synthetically drifted copy must be caught.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

RULES="../templates/rules/coding.md"
SKILL="../skills/source-coding-discipline/SKILL.md"

# Each discipline paragraph is a single line starting with its bolded title.
extract() {
  grep -E '^\*\*(先思考再编码|简单优先|外科手术式改动|目标驱动执行)' "$1"
}

echo "== coding-discipline mirror pair =="

chk_eq "rules file exists" 1 "$([ -f "$RULES" ] && echo 1 || echo 0)"
chk_eq "skill file exists" 1 "$([ -f "$SKILL" ] && echo 1 || echo 0)"

# Structural guard: exactly 4 paragraphs on each side — a renamed/split paragraph
# must fail loudly here instead of silently shrinking the compared set.
chk_eq "rules file has 4 discipline paragraphs" 4 "$(extract "$RULES" | grep -c . )"
chk_eq "skill file has 4 discipline paragraphs" 4 "$(extract "$SKILL" | grep -c . )"

d="$(diff <(extract "$RULES") <(extract "$SKILL") 2>&1 || true)"
if [ -z "$d" ]; then
  chk_eq "mirror pair in sync (paragraphs byte-identical)" "" ""
else
  printf '%s\n' "$d" | sed 's/^/    drift> /'
  chk_eq "mirror pair in sync (paragraphs byte-identical)" "" "$d"
fi

# Negative case: drift must be detected.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mirror-sync.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sed 's/零投机/零投机-DRIFTED/' "$RULES" > "$tmp/drifted.md"
d2="$(diff <(extract "$tmp/drifted.md") <(extract "$SKILL") 2>&1 || true)"
chk_eq "negative case: synthetic drift is caught" 1 "$([ -n "$d2" ] && echo 1 || echo 0)"

summary
