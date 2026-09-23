#!/usr/bin/env bash
# retro-reminder — cto §5 复盘仪式的压缩点强制层触点 + 新会话开场指针（三支一脚本，自判 event/source）。
# PreCompact 的 harness schema 只收 top-level systemMessage——additionalContext 版会被整体
# 拒收、静默失败（2026-07-28 实证），所以压缩前只能给用户可见 nudge；模型上下文注入放在
# 压缩后的 SessionStart(source=compact)。装法见 retro-hooks.json（command 换安装根绝对路径）。
#
# 只在「本仓正在被编排」时说话（audit §3, 2026-09-06）：接线是全局的（~/.claude/settings.json），
# 所以在此之前每一次压缩——包括与编排无关的单 agent 调试会话——都被推去跑七步复盘。谓词是三个门
# 共用的那一个（identity.orchestrated：同仓 = git common dir，证据 = LIVE 席位或今/昨账本 start
# 行）。not / undecidable / 载荷无 cwd ⇒ 一个字都不输出（不是缩短文案），且不调用任何 agentctl
# verb：探针只花一次 git rev-parse、一次 run dir 列目录、两个账本分片的读。
#
# 第三支（SessionStart source=startup|clear）是**开场指针**：新会话不知道交接快照在哪——
# docs/ACTIVE_CONTEXT.md 不在自动加载范围，读不读靠运气（0923 两个席位同病）。见 pointer()：谓词与上面
# 那个身份谓词无关、也不消费它，这一支一次 identity 都不调。
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
print(str(d.get("cwd", "")).replace("\n", " "))   # 带换行的 cwd ⇒ 路径对不上 ⇒ 下面静默，够了
' 2>/dev/null || true)"
event="$(printf '%s\n' "$fields" | sed -n 1p)"
src="$(printf '%s\n' "$fields" | sed -n 2p)"
cwd="$(printf '%s\n' "$fields" | sed -n 3p)"
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
# 开场指针。谓词**只有一个**：payload cwd 所在 git 仓根下 docs/ACTIVE_CONTEXT.md 存在（symlink 可）。
# 不叠加「被编排」谓词——换会话后往往还没有 LIVE 席位，叠加会恰好在最需要接上的那一刻静默（主理人
# 0923 指定）。不内联正文，只一行指针 + 日期，让模型自判快照新旧。判不出（无 cwd / 不在仓里 / 无文件 /
# 日期取不到）⇒ 零字节 exit 0。GATE-AUDIT slug `session-handoff-pointer`，到期 2026-10-24。
pointer() {
  [ -n "$cwd" ] || return 0
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] && [ -f "$top/docs/ACTIVE_CONTEXT.md" ] || return 0
  # 日期取值与 JSON 转义一并交给 python3（脚本已依赖它解析载荷）：头 64KiB 里第一条
  # `Last rewritten: <YYYY-MM-DD>`，没有就退到文件 mtime 的当地日期。任何异常 ⇒ 一个字都不打印。
  python3 -c '
import datetime as dt, json, os, re, sys
p = sys.argv[1]
try:
    with open(p, encoding="utf-8", errors="replace") as fh:
        head = fh.read(65536)
    m = re.search(r"Last rewritten:[ \t]*(\d{4}-\d{2}-\d{2})", head)
    day = m.group(1) if m else dt.datetime.fromtimestamp(os.stat(p).st_mtime).strftime("%Y-%m-%d")
except Exception:
    raise SystemExit(0)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext":
                  "📌 交接快照 docs/ACTIVE_CONTEXT.md（Last rewritten %s）——开工前先读；与驾驶舱 / "
                  "git 冲突以后者为准。切换 / 压缩后的第一条回复先复述：在飞批次 / 待裁 / 下一步"
                  % day}}, ensure_ascii=False, separators=(",", ":")))
' "$top/docs/ACTIVE_CONTEXT.md" 2>/dev/null || true
}
# The event/source filter runs FIRST and the identity probe only after it: a SessionStart that is
# neither a compaction nor an opening, or any other event, must cost nothing at all. The opening
# pointer exits before the probe — it deliberately does not consult identity at all.
case "$event" in
  PreCompact) ;;
  SessionStart)
    case "$src" in
      startup|clear) pointer; exit 0;;
      compact) ;;
      *) exit 0;;                        # resume 等：既不是新开场，也不是压缩点
    esac;;
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
