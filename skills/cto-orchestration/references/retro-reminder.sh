#!/usr/bin/env bash
# retro-reminder — cto §5 复盘仪式的压缩点强制层触点（两事件一脚本，自判 event/source）。
# PreCompact 的 harness schema 只收 top-level systemMessage——additionalContext 版会被整体
# 拒收、静默失败（2026-07-28 实证），所以压缩前只能给用户可见 nudge；模型上下文注入放在
# 压缩后的 SessionStart(source=compact)。装法见 retro-hooks.json（command 换安装根绝对路径）。
set -euo pipefail
payload="$(cat 2>/dev/null || true)"
event=$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
case "$event" in
  PreCompact)
    printf '%s\n' '{"systemMessage":"🔁 压缩前 = 复盘仪式触发点（cto-orchestration §5）：编排位且尚未复盘的话，先按 references/retrospective.md 七步 + retro-check.sh 收口再压缩。"}'
    ;;
  SessionStart)
    src=$(printf '%s' "$payload" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ "$src" = "compact" ] || exit 0
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"🔁 刚发生上下文压缩 = 复盘仪式触发点（cto-orchestration §5，别即兴、别等主理人说「复盘」）：若压缩前未跑，现在读 references/retrospective.md 七步逐条补——治理同步（AGENTS.md 回写）/ memory 治理 / 已完成会话与孤儿清理不依赖被压缩的细节；再跑 references/retro-check.sh 硬门。最易漏 = AGENTS.md 回写。"}}'
    ;;
esac
exit 0
