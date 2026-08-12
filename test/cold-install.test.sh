#!/usr/bin/env bash
# cold-install — 装完能不能用，只认从 TAG 拷出来的那份。
#
# Why: 维护者机器上的"验证安装"验的是工作树，不是发出去的东西——HOME 里有 gitignored 的
# scripts/、已 wire 的 hooks、symlink 回工作树的 skill。同源陷阱。本套把这些全切断：
# 从 git archive 导出（工作树的未跟踪/被忽略文件一律不进）、拷进空目录、HOME 指向空目录、
# cwd 在拷贝内，然后只跑**不需要引擎**的那一半——引擎那一半归 T2（真实模式一轮，人跑并留回执）。
#
# 覆盖边界（如实）：本套证明「拷贝即可用、无隐形依赖」。它不证明真实模式下能干活，
# 也不证明陌生人照 README 装得成——后者结构上够不着，只有真外部人能填。
set -u
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
no()  { fail=$((fail+1)); echo "  FAIL $1"; }
chk() { [ "$2" = "$3" ] && ok "$1" || no "$1 -- expected[$3] got[$2]"; }

REF="${COLD_INSTALL_REF:-HEAD}"
T="$(mktemp -d /tmp/coldinstall.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/install" "$T/home"

echo "== cold install from $REF (archive, not worktree) =="
git -C "$REPO" archive "$REF" | tar -x -C "$T/src"
for s in cto-orchestration orchestrator-core; do
  cp -R "$T/src/skills/$s" "$T/install/" 2>/dev/null || no "copy $s"
done
AC="$T/install/cto-orchestration/references/agentctl/agentctl"
chk "the lane entry survives the copy and is executable" \
  "$([ -x "$AC" ] && echo yes || echo no)" "yes"

# Everything below runs with a CLEAN HOME and cwd inside the copy: anything that silently
# depends on the maintainer's machine dies here rather than in a user's terminal.
run_cold() { ( cd "$T/install/cto-orchestration" && HOME="$T/home" "$@" ) 2>&1; }

out="$(run_cold "$AC" states)"; rc=$?
chk "states runs from the copy with a clean HOME" "$rc" "0"
chk "states publishes the vocabulary, not an error" \
  "$(printf '%s' "$out" | grep -c 'typed state vocabulary')" "1"

out="$(run_cold "$AC" states --json)"; rc=$?
chk "states --json runs cold" "$rc" "0"
chk "states --json is parseable" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["states"] else 0)' 2>/dev/null || echo 0)" "1"

out="$(run_cold "$AC" capabilities)"; rc=$?
chk "capabilities runs cold" "$rc" "0"
chk "capabilities emits the contract, not a stub" \
  "$(printf '%s' "$out" | grep -c 'capability contract')" "1"

# The guards ship with the skill and are wired by the installer — a guard that cannot start is a
# silently disabled gate on the user's machine.
for g in cto-guard-bash cto-guard-agent; do
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  out="$(printf '%s' "$payload" | ( cd "$T/install" && HOME="$T/home" python3 \
        "cto-orchestration/references/agentctl/$g.py" ) 2>&1)"; rc=$?
  chk "$g starts cold and allows a benign command" "$rc" "0"
done

# No path may escape the installed skill: a reference that resolves only inside the repo is a
# dead link the moment the user copies the directory alone.
esc=0
while IFS= read -r f; do
  while IFS= read -r p; do
    case "$p" in
      /*|http*|"") continue ;;
    esac
    [ -e "$T/install/cto-orchestration/$p" ] || [ -e "$(dirname "$f")/$p" ] || esc=$((esc+1))
  done <<EOF
$(grep -oE '\`references/[A-Za-z0-9._/-]+\`' "$f" 2>/dev/null | tr -d '`')
EOF
done <<EOF
$(find "$T/install/cto-orchestration" -name '*.md')
EOF
chk "every references/ path named in the copy resolves inside the copy" "$esc" "0"

echo "== cold-install: $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
