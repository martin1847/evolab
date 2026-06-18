# 复盘仪式操作手册

> SKILL.md §5「复盘仪式」的展开。事件触发：收口 / 压缩前 / 任何 ReOpen 后主动提议。
> 仪式链条：交付清单 → 什么有效 → 教训进 memory → 上下文治理 → 治理同步 → **memory 治理** →
> **session 切换决策**。前五步 SKILL §5 已述纪律，本文件展开操作性最强的后两步。

## memory 治理（治理同步之后）

- COMPLETED workstream 精简到 ≤10 行（结论 + 关键教训 + 指针），删掉过程细节。
- 事实性细节（路径 / 凭据 / 执行路径 / 导航步骤）沉淀到项目环境文档（如 `ACCESS.local.md`，
  由 `repo-governance-bootstrap` 生成），memory 只留指针——memory 跨 session 存活但容量有限，
  环境文档是 gitignored 的本地 SoT。
- 重复 / 矛盾的 memory 合并或删除；已过时的 workstream 状态更新。
- MEMORY.md 索引 ≤40 行，按类型分组（iron rules / active / completed / reference）。
- 实证：某项目 30 条 memory 含多个 100+ 行巨型文件，新 session 读入全是噪声。

## session 切换决策（仪式最后一步）

治理完评估当前上下文状态，二选一：

- **压缩上下文续跑**：同一任务还在连续迭代、没有天然断点。
- **新 session + handoff**：天然交接点（等外部部署 / 验收、workstream 批次结束、角色 / 优先级切换）。
  写一次性 handoff 到 `/tmp/`（**不进 `docs/orchestration/`**——handoff 是 transient 交接产物，放治理
  SoT 会变又一个只生不死的死文件；持久状态归 ACTIVE_CONTEXT + memory，handoff 只快照运行时状态）。三件事：
  ① 待办队列（带状态 + session/worktree/branch 指针）；② 活跃 tmux sessions 及其当前任务；
  ③ 需用户决策的 blocking 项。新 session 读 handoff + memory 冷启动，**读完即删**。
