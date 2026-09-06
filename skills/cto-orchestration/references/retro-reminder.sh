#!/usr/bin/env bash
# retro-reminder — cto §5 复盘仪式的压缩点强制层触点（两事件一脚本，自判 event/source）。
# PreCompact 的 harness schema 只收 top-level systemMessage——additionalContext 版会被整体
# 拒收、静默失败（2026-07-28 实证），所以压缩前只能给用户可见 nudge；模型上下文注入放在
# 压缩后的 SessionStart(source=compact)。装法见 retro-hooks.json（command 换安装根绝对路径）。
#
# 只在「本仓正在被编排」时说话（audit §3, 2026-09-06）：接线是全局的（~/.claude/settings.json），
# 所以在此之前每一次压缩——包括与编排无关的单 agent 调试会话——都被推去跑七步复盘。谓词是三个门
# 共用的那一个（identity.orchestrated：同仓 = git common dir，证据 = LIVE 席位或今/昨账本 start
# 行）。not / undecidable / 载荷无 cwd ⇒ 一个字都不输出（不是缩短文案），且不调用任何 agentctl
# verb：探针只花一次 git rev-parse、一次 run dir 列目录、两个账本分片的读。
set -euo pipefail
payload="$(cat 2>/dev/null || true)"
# Real JSON parsing, not sed — a prefix-greedy sed match picks the LAST occurrence of a
# key on the line, so a duplicated key nested later in the payload could silently
# suppress the reminder (review F8). Garbage/non-JSON → empty fields → silent exit 0.
fields="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("hook_event_name", ""))
print(d.get("source", ""))
' 2>/dev/null || true)"
event="$(printf '%s\n' "$fields" | sed -n 1p)"
src="$(printf '%s\n' "$fields" | sed -n 2p)"
# The shared predicate, consulted ONLY on the two events that would otherwise speak — an
# unrelated SessionStart must pay nothing at all. rc 0 = this repo is being orchestrated.
orchestrated() {
  printf '%s' "$payload" | AGENTCTL_DIR="$(dirname "$0")/agentctl" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["AGENTCTL_DIR"])
try:
    import identity
except Exception:
    sys.exit(1)
try:
    cwd = json.load(sys.stdin).get("cwd")
except Exception:
    sys.exit(1)
if not isinstance(cwd, str) or not cwd:
    sys.exit(1)
state, _why = identity.orchestrated(cwd)
sys.exit(0 if state == identity.ORCHESTRATED else 1)
' 2>/dev/null
}
# The event/source filter runs FIRST and the identity probe only after it: a SessionStart that
# is not a compaction, or any other event, must cost nothing at all.
case "$event" in
  PreCompact) ;;
  SessionStart) [ "$src" = "compact" ] || exit 0;;
  *) exit 0;;
esac
orchestrated || exit 0
case "$event" in
  PreCompact)
    printf '%s\n' '{"systemMessage":"🔁 压缩前 = 复盘仪式触发点（cto-orchestration §5）：编排位且尚未复盘的话，先按 references/retrospective.md 七步 + retro-check.sh 收口再压缩。"}'
    ;;
  SessionStart)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"🔁 刚发生上下文压缩 = 复盘仪式触发点（cto-orchestration §5，别即兴、别等主理人说「复盘」）：若压缩前未跑，现在读 references/retrospective.md 七步逐条补——治理同步（AGENTS.md 回写）/ memory 治理 / 已完成会话与孤儿清理不依赖被压缩的细节；再跑 references/retro-check.sh 硬门。最易漏 = AGENTS.md 回写。"}}'
    ;;
esac
exit 0
