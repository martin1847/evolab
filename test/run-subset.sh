#!/usr/bin/env bash
# run-subset.sh — 改动面子集门（非深档迭代用）。NOT a test: filename carries no
# `.test.sh`, so run.sh's `for tp in "$HERE"/*.test.sh` glob never picks it up.
#
# Usage: bash test/run-subset.sh [<base-ref>]        # default base = origin/main
#
# 选择 = 机械推导，不建映射表（表必漂）。对每个改动文件走一条**三级阶梯**，每级都 fail-closed：
#   a) 有套件的文本里出现该文件的**完整 repo-relative 路径** → 选这些套件（path-certain，
#      路径唯一标识文件，没有同名歧义）；
#   b) 否则，若该 basename 在仓库树里**恰好只出现在一个路径上** → 退回 basename 匹配
#      （`grep -lwF`，`-`/`.` 是非 word 字符，所以 `agentctl` 也命中 `agentctl-duplex`；
#      误宽刻意保留，宁多选不少选）；
#   c) 否则（basename 在仓内多路径重名，例如 README.md / SKILL.md）→ FULL-FALLBACK。
#      重名时「某套件提到这个 basename」不能证明它提的是**这个**文件，选择证据失效，全量兜底。
# 改动文件本身是 test/*.test.sh 且仍在盘上 → 直接自选（这是最强的 path-certain 证据）。
#
# diff 用 `git diff --name-status -z`（NUL 分隔，文件名里的空格/换行不会被拆错）。
# 只认 A/M/D 三种状态：R（rename）/C（copy）两端路径都参与影响面，T/U/X 语义不明——
# 一律 FULL-FALLBACK，不猜。D 保留旧 basename 参与选择（在 base 树里判重名）。
#
# fail-closed：
#   * 任一改动文件在全部套件文本中零命中 → 跑全量 test/run.sh（打明原因）
#   * 改动含 test/run.sh / test/lib-testkit.sh / .github/workflows/* → 全量
#   * base 解析失败 / diff 为空 / 非 A,M,D 状态 / basename 重名 → 全量或 GATE_ERROR
#   * **每一处量具（git / grep / sort / mktemp）都查 rc**：grep rc≥2、sort/git/mktemp 非零
#     → GATE_ERROR rc=2。核心扫描之外的清洗 grep 同样查——量具坏了不许降级成「没命中」。
#     脚本里没有未查 rc 的管道：外部命令一律单独调用 + `rc=$?`，中间态走 $tmpd 临时文件。
# rc: 0 全绿 · 1 有套件红 · 2 GATE_ERROR（全量回退时透传 run.sh 自己的 rc）
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

if ! git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
  gate_error "base ref '$base' does not resolve to a commit"
fi
head_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)" || gate_error "cannot resolve HEAD"

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/run-subset.XXXXXX")"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$tmpd" ] && [ -d "$tmpd" ] || gate_error "mktemp -d failed (rc=$rc)"
trap 'rm -rf "$tmpd"' EXIT

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
  bash "$HERE/run.sh" </dev/null
  exit $?
}

# ---- 量具封装：每一处都查 rc ------------------------------------------------
SCAN_OUT=""
scan_suites() { # $1 needle — 在全部套件里找 word-boundary 定长匹配；设 SCAN_OUT
  local out rc
  out="$(grep -lwF -- "$1" "${suite_paths[@]}" 2>"$tmpd/scan.err")"; rc=$?
  [ "$rc" -le 1 ] || gate_error "grep -lwF failed scanning suites for '$1' (rc=$rc): $(<"$tmpd/scan.err")"
  SCAN_OUT="$out"
}

UNIQ_OUT=""
uniq_lines() { # $1 newline-separated blob — 去空行 + 去重排序；设 UNIQ_OUT
  local rc
  printf '%s\n' "$1" > "$tmpd/u.raw"; rc=$?
  [ "$rc" -eq 0 ] || gate_error "cannot write $tmpd/u.raw (rc=$rc)"
  grep -v '^$' "$tmpd/u.raw" > "$tmpd/u.ne"; rc=$?
  [ "$rc" -le 1 ] || gate_error "grep -v failed cleaning blank lines (rc=$rc)"
  sort -u "$tmpd/u.ne" > "$tmpd/u.out"; rc=$?
  [ "$rc" -eq 0 ] || gate_error "sort -u failed deduplicating suites (rc=$rc)"
  UNIQ_OUT="$(<"$tmpd/u.out")"
}

COUNT_OUT=0
count_lines() { # $1 file — 数行；设 COUNT_OUT
  local rc
  COUNT_OUT="$(grep -c '^' "$1")"; rc=$?
  [ "$rc" -le 1 ] || gate_error "grep -c failed counting lines of $1 (rc=$rc)"
  [ -n "$COUNT_OUT" ] || COUNT_OUT=0
}

BN_COUNT=0
bn_count() { # $1 basename  $2 basenames-file — 数该 basename 在树里占几个路径；设 BN_COUNT
  local rc
  BN_COUNT="$(grep -cxF -- "$1" "$2")"; rc=$?
  [ "$rc" -le 1 ] || gate_error "grep -cxF failed counting basename '$1' (rc=$rc)"
  [ -n "$BN_COUNT" ] || BN_COUNT=0
}

mk_basenames() { # $1 tree-ish  $2 out-file — 把整棵树压成每行一个 basename
  local rc
  git -C "$ROOT" ls-tree -r -z --name-only "$1" > "$tmpd/lt.raw" 2>"$tmpd/lt.err"; rc=$?
  [ "$rc" -eq 0 ] || gate_error "git ls-tree -r -z --name-only $1 failed (rc=$rc): $(<"$tmpd/lt.err")"
  { while IFS= read -r -d '' p; do printf '%s\n' "${p##*/}"; done; } < "$tmpd/lt.raw" > "$2"; rc=$?
  [ "$rc" -eq 0 ] || gate_error "cannot write basename index for $1 (rc=$rc)"
  [ -s "$2" ] || gate_error "tree listing for $1 is empty — refusing to judge basename uniqueness blind"
}

# ---- diff 解析：NUL 分隔 + name-status；rename/copy 不猜 --------------------
git -C "$ROOT" diff --name-status -z "$base...HEAD" > "$tmpd/ns" 2>"$tmpd/ns.err"; rc=$?
[ "$rc" -eq 0 ] || gate_error "git diff --name-status -z $base...HEAD failed (rc=$rc): $(<"$tmpd/ns.err")"
[ -s "$tmpd/ns" ] || gate_error "empty diff for $base...HEAD — nothing to gate, refusing to report green"

chg_path=()
chg_status=()
want=status
pending=""
while IFS= read -r -d '' tok; do
  if [ "$want" = status ]; then
    case "$tok" in
      A|M|D) pending="$tok"; want=path ;;
      R*)    run_full "diff status '$tok' (rename) — a move has two path ends, neither is path-certain here" ;;
      C*)    run_full "diff status '$tok' (copy) — a copy has two path ends, neither is path-certain here" ;;
      *)     run_full "unsupported diff status '$tok' — refusing to guess its blast radius" ;;
    esac
  else
    chg_path[${#chg_path[@]}]="$tok"
    chg_status[${#chg_status[@]}]="$pending"
    want=status
  fi
done < "$tmpd/ns"
[ "$want" = status ] || gate_error "malformed 'git diff --name-status -z' stream — dangling status '$pending'"
[ "${#chg_path[@]}" -gt 0 ] || gate_error "diff for $base...HEAD produced no paths"

# ---- fail-closed: 基础设施改动 → 全量 --------------------------------------
i=0
while [ "$i" -lt "${#chg_path[@]}" ]; do
  case "${chg_path[$i]}" in
    test/run.sh|test/lib-testkit.sh|.github/workflows/*)
      run_full "infra file changed: ${chg_path[$i]}" ;;
  esac
  i=$((i+1))
done

# ---- basename 重名索引（HEAD 树给 A/M，base 树给 D） -----------------------
mk_basenames HEAD "$tmpd/bn.head"
mk_basenames "$base" "$tmpd/bn.base"

# ---- 选择阶梯 --------------------------------------------------------------
mapping=()
selected=""
i=0
while [ "$i" -lt "${#chg_path[@]}" ]; do
  f="${chg_path[$i]}"
  st="${chg_status[$i]}"
  i=$((i+1))
  bn="${f##*/}"
  hits=""
  how=""

  # 阶梯 a — path-certain 证据：改动文件自己是套件，或有套件写了它的完整 repo-relative 路径。
  # 这类证据不受同名歧义影响。
  case "$f" in
    test/*.test.sh) [ -f "$ROOT/$f" ] && { hits="$bn"; how="self"; } ;;
  esac
  scan_suites "$f"
  if [ -n "$SCAN_OUT" ]; then
    [ -n "$how" ] || how="path"
    while IFS= read -r hp; do
      [ -n "$hp" ] || continue
      hits="$hits
${hp##*/}"
    done <<EOF
$SCAN_OUT
EOF
  fi

  # 阶梯 b/c — basename 证据只在仓内不重名时可信。
  # 注意 `grep -lwF "$bn"` 的命中天然是 path 命中的**超集**（完整路径里也含 basename），
  # 所以 basename 唯一时必须 union 进来、而不是让阶梯 a 短路掉它：短路只会更窄，
  # 而更窄正是本轮 SHIP-BLOCKING 的病根（实测 duplexctl.py path=3 vs basename=13，
  # 被短路掉的 10 套正是跑 duplex 行为的那些）。重名时反过来：basename 命中不可信，
  # 只有 path-certain 证据算数；连 path 证据都没有 → 全量兜底。
  if [ "$st" = D ]; then
    bn_count "$bn" "$tmpd/bn.base"
  else
    bn_count "$bn" "$tmpd/bn.head"
  fi
  if [ "$BN_COUNT" -eq 1 ]; then
    how="basename"
    scan_suites "$bn"
    while IFS= read -r hp; do
      [ -n "$hp" ] || continue
      hits="$hits
${hp##*/}"
    done <<EOF
$SCAN_OUT
EOF
  else
    [ -n "$hits" ] || run_full "basename '$bn' is not unique in the repo tree ($BN_COUNT paths carry it; changed: $f) and no suite names its full path — a suite naming '$bn' does not prove it means THIS file"
    how="path-only(ambiguous basename: $BN_COUNT paths)"
  fi

  uniq_lines "$hits"
  hits="$UNIQ_OUT"
  # fail-closed: 零命中 = 我们不知道这个文件影响谁 → 全量
  [ -n "$hits" ] || run_full "no suite mentions '$bn' (changed: $f, status $st) — selection is blind here"

  joined=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ -z "$joined" ]; then joined="$s"; else joined="$joined $s"; fi
  done <<EOF
$hits
EOF
  mapping[${#mapping[@]}]="SUBSET:   [$how] $f → $joined"
  selected="$selected
$hits"
done

uniq_lines "$selected"
selected="$UNIQ_OUT"
[ -n "$selected" ] || gate_error "selection produced no suites (internal inconsistency)"
printf '%s\n' "$selected" > "$tmpd/sel"
count_lines "$tmpd/sel"
n_selected="$COUNT_OUT"

# ---- 证据行 ----------------------------------------------------------------
printf 'SUBSET: %s/%s suites — base=%s head=%s\n' "$n_selected" "$total_suites" "$base" "$head_sha"
i=0
while [ "$i" -lt "${#mapping[@]}" ]; do
  printf '%s\n' "${mapping[$i]}"
  i=$((i+1))
done

# ---- 跑 --------------------------------------------------------------------
total_pass=0
total_fail=0
echo
echo "######## agentctl subset gate ########"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  echo
  echo "==== $t ===="
  out="$(bash "$HERE/$t" </dev/null 2>&1)"; rc=$?
  while IFS= read -r line || [ -n "$line" ]; do
    printf '    %s\n' "$line"
  done <<EOF
$out
EOF
  if [ "$rc" -eq 0 ]; then
    printf '[PASS] %s\n' "$t"
    total_pass=$((total_pass+1))
  else
    printf '[FAIL] %s (rc=%s)\n' "$t" "$rc"
    total_fail=$((total_fail+1))
  fi
done < "$tmpd/sel"

echo
echo "######## SUBSET SUMMARY ########"
printf 'SUBSET SUMMARY PASS=%d FAIL=%d\n' "$total_pass" "$total_fail"
if [ "$total_fail" -eq 0 ]; then
  echo "SUBSET GREEN (full test/run.sh still required before merge)"
  exit 0
fi
echo "SUBSET FAILED"
exit 1
