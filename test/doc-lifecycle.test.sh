#!/usr/bin/env bash
# Test suite for cto-orchestration references/doc-lifecycle.py (文档年龄清单, 只读).
# Hermetic: each case builds a temp git repo with dated commits, runs the scanner,
# asserts stdout lines + exit code. NOTHING under test is modified — and case Z
# asserts that about the SCANNED tree too, byte for byte: a scanner that is allowed
# to move documents needs a reviewer for every run, which is the cost this file buys out.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/cto-orchestration/references/doc-lifecycle.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
# `--` so a needle that starts with a dash (`--docs`) is a pattern, not a grep flag
assert_has(){ printf '%s' "$1" | grep -qF -- "$2" && ok || no "$3: output missing '$2'"; }
assert_no(){ printf '%s' "$1" | grep -qF -- "$2" && no "$3: output should NOT have '$2'" || ok; }
assert_eq(){ [ "$1" = "$2" ] && ok || no "$3: expected '$2' got '$1'"; }

# commit dates are relative so the TTL arms mean the same thing on any day
ago(){ date -v-"$1"d -u +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S; }
OLD="$(ago 60)"; NEW="$(ago 3)"
gcommit(){ # $1 repo  $2 date  $3 msg
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$3"
}

# fixture: one 60-day-old commit carrying the whole surface + one 3-day-old commit that
# touches ONLY the fresh receipt (an append that also touched ACTIVE_CONTEXT would reset
# its sections' `git log -L` clock and the cool arms would test nothing).
mkfix(){
  local d; d="$(mktemp -d)"
  git init -q -b main "$d" >/dev/null
  mkdir -p "$d/docs/archive"
  printf '# 活跃上下文\n\n## 老段落无断言\n\n谁都不碰我。\n\n## 老段落续命中\n\n<!-- keep-until: 2099-01-01 -->\n\n## 老段落有断言\n\nPREMISE: 门在 verify=`true` => rc=0\n' \
    > "$d/docs/ACTIVE_CONTEXT.md"
  printf '# 老回执\n\n收工。\n' > "$d/docs/OLD_RECEIPT.md"
  printf '# 续命回执\n\n<!-- keep-until: 2099-01-01 -->\n' > "$d/docs/KEPT_RECEIPT.md"
  printf '# 归档区不扫\n' > "$d/docs/archive/ARCHIVED.md"
  gcommit "$d" "$OLD" init >/dev/null
  printf '# 新回执\n\n刚写的。\n' > "$d/docs/NEW_RECEIPT.md"
  gcommit "$d" "$NEW" fresh >/dev/null
  echo "$d"
}
run(){ python3 "$SCRIPT" --docs "$1/docs" "${@:2}" 2>&1; }
# the zero-mutation witness: every path under docs/ plus the bytes of every file there
snap(){ ( cd "$1" && find docs -print | sort \
          && find docs -type f -print0 | xargs -0 shasum -a 256 | sort ) \
        | shasum -a 256 | cut -d' ' -f1; }

echo "== doc-lifecycle.test =="

# Case A — the clean read-out: one expired receipt, one cold section, and nothing else
r="$(mkfix)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "A/dry-run rc"
assert_has "$out" "expire: docs/OLD_RECEIPT.md age=60d" "A/60 天无触碰的回执进清单"
assert_has "$out" "cool: docs/ACTIVE_CONTEXT.md#老段落无断言 lines=3-6 age=60d" \
  "A/无断言陈段带行区间进清单"
assert_has "$out" "doc-lifecycle: 1 件到期，1 段可降温" "A/尾行计数"
# 好样本绿: 三天前刚碰过的回执不到期
assert_no  "$out" "NEW_RECEIPT" "A/3 天的回执不进清单"
# 段落级判据的两个负控
assert_no  "$out" "老段落有断言" "A/带 PREMISE 的段落永不降温"
assert_no  "$out" "老段落续命中" "A/段内 keep-until 未过期 ⇒ 不降温"
assert_no  "$out" "KEPT_RECEIPT" "A/文件头 keep-until 未过期 ⇒ 整份不到期"
assert_no  "$out" "ARCHIVED" "A/只扫一层, archive/ 不在扫描面"
# living 名单缺的两件列 skip, 不静默丢
assert_has "$out" "skip: DECISION_QUEUE.md (missing)" "A/缺的 living 列 skip"
assert_has "$out" "skip: LESSONS.md (missing)" "A/缺的 living 列 skip"

# Case B — TTL is the knob, not a constant: at 90d the same tree is empty
out="$(run "$r" --ttl 90)"; rc=$?
assert_rc "$rc" 0 "B/--ttl rc"
assert_eq "$(printf '%s' "$out" | grep -c '^\(expire\|cool\):')" "0" "B/60d < 90d ⇒ 清单为空"
assert_has "$out" "doc-lifecycle: 0 件到期，0 段可降温" "B/尾行仍打印"

# Case C — a dirty file is skipped whole: worktree line numbers would feed `git log -L`
# a different span than the one on screen, and a stale file-level age would then be
# inherited by sections written today.
r="$(mkfix)"; printf '\n## 今天刚写的草稿\n\n改着呢。\n' >> "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "C/dirty rc"
assert_has "$out" "skip: ACTIVE_CONTEXT.md (dirty)" "C/dirty 文件整份 skip"
assert_no  "$out" "cool:" "C/dirty 文件一段都不降温"
assert_has "$out" "doc-lifecycle: 1 件到期，0 段可降温" "C/expire 面不受影响"

# Case D — outside any git repo there is no age to read; mtime is a checkout timestamp,
# so the scanner says so instead of reporting a fresh (empty) list.
d="$(mktemp -d)"; mkdir -p "$d/docs"; printf '# 无仓回执\n' > "$d/docs/LOOSE.md"
out="$(run "$d")"; rc=$?
assert_rc "$rc" 0 "D/no-git rc (判不了 ≠ 错)"
assert_has "$out" "(no-git)" "D/不在仓的文件列 no-git"
assert_has "$out" "doc-lifecycle: 0 件到期，0 段可降温" "D/不猜年龄 ⇒ 不进清单"

# Case E — a missing scan face is exit 2, never an empty list (量具坏 ≠ 干净)
out="$(python3 "$SCRIPT" --docs "$d/docs-gone" 2>&1)"; rc=$?
assert_rc "$rc" 2 "E/--docs 不存在 ⇒ exit 2"
assert_has "$out" "--docs" "E/说明是哪个入参"
out="$(python3 "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 2 "E/--docs 缺失 ⇒ exit 2"

# Case Z — ZERO MUTATION: the scanned tree is byte-identical across a run. This is the
# whole premise of the tool (清单给人看, 搬与不搬人拍), so it is asserted, not assumed.
r="$(mkfix)"; before="$(snap "$r")"
run "$r" >/dev/null; run "$r" --ttl 1 >/dev/null
after="$(snap "$r")"
assert_eq "$after" "$before" "Z/docs 树前后字节一致"
assert_eq "$(git -C "$r" status --porcelain | wc -l | tr -d ' ')" "0" "Z/工作树无改动"

echo "== doc-lifecycle: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
