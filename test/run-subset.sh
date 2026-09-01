#!/usr/bin/env bash
# run-subset.sh — 改动面子集门（非深档迭代用）。NOT a test: filename carries no
# `.test.sh`, so run.sh's `for tp in "$HERE"/*.test.sh` glob never picks it up.
#
# Usage: bash test/run-subset.sh [<base-ref>]        # default base = origin/main
#
# 选择 = 机械推导，不建映射表（表必漂）。对 `git diff --name-only <base>...HEAD`
# 的每个改动文件，选中所有「文本里出现其 basename（word-boundary）」的 test/*.test.sh；
# 改动文件本身是 test/*.test.sh 且仍在盘上 → 选它自己。word-boundary 是 grep -wF：
# `-` / `.` 都是非 word 字符，所以 basename `agentctl` 也会命中 `agentctl-weight`
# ——误宽是刻意的，宁多选不少选。
#
# fail-closed 三条（子集门只许比全量更保守）：
#   a) 任一改动文件在全部套件文本中零命中 → 跑全量 test/run.sh（打明原因）
#   b) 改动含 test/run.sh / test/lib-testkit.sh / .github/workflows/* → 全量
#   c) diff 为空 / base 解析失败 / 量具（git、grep）失败 → GATE_ERROR rc=2，不静默绿
# rc: 0 全绿 · 1 有套件红 · 2 GATE_ERROR（含全量回退时 run.sh 自己的 rc 透传）
#
# 边界：只看 committed diff（`<base>...HEAD`），working tree 未提交的改动不参与选择
# ——提交后再跑，否则空 diff 会撞 rc=2 而不是假绿。
#
# kill criterion（slug `subset-gate`，GATE-AUDIT 结账）：
#   一个复盘周期内出现「子集绿而 CI 全量红」的漏网真回归 ≥1 ⇒ 收紧选择或废；
#   或从未被使用 / 从未省时 ⇒ kill。
#   记账行：`GATE-AUDIT: subset-gate hits=<int> false=<int> action=<kill|keep(<reason>)>`
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

gate_error() { # $1 reason
  printf 'GATE_ERROR: %s\n' "$1" >&2
  exit 2
}

base="${1:-origin/main}"

# ---- base ref 解析（量具失败显式红，不静默绿） ----------------------------
if ! git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
  gate_error "base ref '$base' does not resolve to a commit"
fi
head_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)" || gate_error "cannot resolve HEAD"

changed="$(git -C "$ROOT" diff --name-only "$base...HEAD" 2>&1)"; grc=$?
[ "$grc" -eq 0 ] || gate_error "git diff --name-only $base...HEAD failed (rc=$grc): $changed"
[ -n "$changed" ] || gate_error "empty diff for $base...HEAD — nothing to gate, refusing to report green"

# ---- 套件清单（自动发现；硬编码列表会静默漏掉新套件） ----------------------
suite_paths=()
for sp in "$HERE"/*.test.sh; do
  [ -f "$sp" ] && suite_paths[${#suite_paths[@]}]="$sp"
done
[ "${#suite_paths[@]}" -gt 0 ] || gate_error "no test/*.test.sh discovered under $HERE"
total_suites="${#suite_paths[@]}"

run_full() { # $1 reason
  printf 'SUBSET: FULL-FALLBACK — %s\n' "$1"
  printf 'SUBSET: base=%s head=%s\n' "$base" "$head_sha"
  bash "$HERE/run.sh"
  exit $?
}

# ---- fail-closed (b): 基础设施改动 → 全量 ---------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    test/run.sh|test/lib-testkit.sh|.github/workflows/*)
      run_full "infra file changed: $f" ;;
  esac
done <<EOF
$changed
EOF

# ---- 选择 ------------------------------------------------------------------
mapping=""
selected=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  bn="${f##*/}"
  hits=""
  case "$f" in
    test/*.test.sh) [ -f "$ROOT/$f" ] && hits="$bn" ;;
  esac
  gout="$(grep -lwF -- "$bn" "${suite_paths[@]}" 2>/dev/null)"; grc=$?
  if [ "$grc" -gt 1 ]; then
    gate_error "grep failed while scanning suites for basename '$bn' (rc=$grc)"
  fi
  while IFS= read -r hp; do
    [ -n "$hp" ] || continue
    hits="$hits
${hp##*/}"
  done <<EOF
$gout
EOF
  hits="$(printf '%s\n' "$hits" | grep -v '^$' | sort -u)"
  # fail-closed (a): 零命中 = 我们不知道这个文件影响谁 → 全量
  [ -n "$hits" ] || run_full "no suite mentions '$bn' (changed: $f) — selection is blind here"
  mapping="$mapping
$f → $(printf '%s\n' "$hits" | tr '\n' ' ' | sed 's/ *$//')"
  selected="$selected
$hits"
done <<EOF
$changed
EOF

selected="$(printf '%s\n' "$selected" | grep -v '^$' | sort -u)"
[ -n "$selected" ] || gate_error "selection produced no suites (internal inconsistency)"
n_selected="$(printf '%s\n' "$selected" | grep -c '^')"

# ---- 证据行 ----------------------------------------------------------------
printf 'SUBSET: %s/%s suites — base=%s head=%s\n' "$n_selected" "$total_suites" "$base" "$head_sha"
printf '%s\n' "$mapping" | grep -v '^$' | sed 's/^/SUBSET:   /'

# ---- 跑 --------------------------------------------------------------------
total_pass=0
total_fail=0
echo
echo "######## agentctl subset gate ########"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  echo
  echo "==== $t ===="
  out="$(bash "$HERE/$t" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -eq 0 ]; then
    printf '[PASS] %s\n' "$t"
    total_pass=$((total_pass+1))
  else
    printf '[FAIL] %s (rc=%s)\n' "$t" "$rc"
    total_fail=$((total_fail+1))
  fi
done <<EOF
$selected
EOF

echo
echo "######## SUBSET SUMMARY ########"
printf 'SUBSET SUMMARY PASS=%d FAIL=%d\n' "$total_pass" "$total_fail"
if [ "$total_fail" -eq 0 ]; then
  echo "SUBSET GREEN (full test/run.sh still required before merge)"
  exit 0
fi
echo "SUBSET FAILED"
exit 1
