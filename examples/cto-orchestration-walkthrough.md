# 示例：一次派工的完整循环（illustrative）

> 这是一个**示意性**端到端走查，用一个通用任务（给 API 加限流）演示 `cto-orchestration`
> §1–§2 的全流程。git/tmux 命令是真实形态（watcher 参数按你项目校准），内容是构造的、
> 不含任何真实项目身份。真实运行产物见仓库 README 的「效果示例」截图。

任务：给 `/api/export` 加限流（每 IP 每分钟 60 次），超限返回 429。

---

## 1. Rebase + 写 goal

```bash
git fetch origin
git worktree add ../wt-ratelimit -b feat/ratelimit origin/main
```

`docs/orchestration/RATELIMIT_GOAL.md`（节选）：

```markdown
# GOAL: /api/export 限流

## 上下文
- 现状：导出接口无限流，已出现刷量。前置研究见 docs/research/abuse-2024.md。

## 预判（verify, don't trust）
- 限流中间件挂载点疑在 src/api/middleware.ts:42（注册顺序在 auth 之后）——核实。
- 计数器选型：进程内 Map 不够（多实例）→ 倾向 Redis，但先确认部署是否多实例。

## 交付物
- 中间件 + 单测（命中/未命中/重置窗口）+ E2E（连发 61 次第 61 返回 429）。

## 验证要求
- test+lint 全绿；E2E 截图；429 响应带 Retry-After 头。

## Guardrails
- scope：只动限流，不重构 auth。
- 行为变更藏 env flag RATELIMIT_ENABLED，默认 OFF。
- commit 留本地，不 push。stop-and-report：部署形态（单/多实例）不明就停下问。
```

## 2. tmux 派发 omp + 挂 watcher

```bash
tmux new-session -d -s demo-ratelimit-omp -c ../wt-ratelimit 'omp'
sleep 12
tmux send-keys -t demo-ratelimit-omp 'goal：/abs/path/docs/orchestration/RATELIMIT_GOAL.md'
sleep 1 && tmux send-keys -t demo-ratelimit-omp Enter
bash skills/cto-orchestration/references/watcher.sh demo-ratelimit-omp &
```

watcher 轮询返回（typed 状态）：

```
[watcher] demo-ratelimit-omp  busy(⟦esc⟧)  pane_cmd=omp     # 仍在跑、存活
[watcher] demo-ratelimit-omp  idle         pane_cmd=omp     # 0 DONE（活着+空闲）
```

> 若返回 `pane_cmd=zsh` 而非 `omp` = AGENT-DEAD，不是 DONE——别派去评审。

## 3. 收工核证四件套

```bash
cd ../wt-ratelimit
git status -s                       # ① 树干净（防"声称完成没 commit"）
git log origin/main..HEAD --oneline # ② 与声明一致
npm test && npm run lint            # ③ 独立复跑
npm test 2>&1 | grep -E 'passed|failed'   # ④ 取真实计数，别信截断的点行
```

四件套过 → Implemented。**还不是交付。**

## 4. 对抗式评审（codex）

```bash
tmux new-session -d -s demo-ratelimit-codex -c ../wt-ratelimit 'codex'
sleep 12 && tmux send-keys -t demo-ratelimit-codex '2' Enter   # 跳过更新提示
```

冷上下文 brief（不夹带自己的结论，点名易翻车的轴）：

```
只读评审 feat/ratelimit。点名轴：并发竞态（计数器自增原子性）、
窗口重置边界、旗标关路径零行为变化、429 是否泄漏内部信息。
verify don't trust，写探针复现。收敛线：常见绕过全覆盖即达标。
```

codex 写入 `docs/orchestration/RATELIMIT_REVIEW_codex.md`：

```
[major] 计数器 INCR 与 EXPIRE 非原子，窗口边界并发下可超发 → 探针复现见下
[minor] 429 未带 Retry-After
verdict: request-changes
```

→ 派回 omp 修 → codex 复审 → `verdict: approve`。

## 5. 升 Verified + 关单

- 编排者核证四件套过 + 异构 codex 独立 approve → **Verified**。
- roadmap / ACTIVE_CONTEXT 翻状态（只认 Verified）。
- `push/PR 必须用户明示批准`——这一步停下等放行。

---

**这一页演示了：** rebase ritual → goal 驱动 → 存活检测（死≠完成）→ 核证四件套 →
异构对抗评审循环 → Verified 才关单。换成你的真实任务，把任务名和验证要求替进去即可。
