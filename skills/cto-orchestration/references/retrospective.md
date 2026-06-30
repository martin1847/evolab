# 复盘仪式操作手册

> SKILL.md §5「复盘仪式」的展开 = **本文件是 checklist 本体，逐条勾**。事件触发：收口 / 压缩前 / 任何 ReOpen 后主动提议。
> SKILL §5 是入口（纪律 + 硬门 `retro-check.sh`）；这里是七步全文 + 后两步操作细节。
> **即兴版必静默漏承重治理步**——逐条过，别凭记忆。

## 七步 checklist

1. **交付清单**：shipped / parked / 残留。
2. **过程×结果四象限**（每个收口单元落唯一一格，禁「上线=好」塌缩）：好程好果=**实力赢**(固化做法) ·
   坏程好果=**走运**(别奖励、补过程洞) · 好程坏果=**倒霉**(别改流程) · 坏程坏果=**实力输**(改)。
   判「走运」即使 shipped 也标 outcome 星号 + 点出过程缺口（实证：PR 已交但 GUI 仅手动测试计划未跑 → 不给满分）。
3. **教训进 memory**：每条带 **Why + How-to-apply**；事实细节（路径/凭据/执行路径）进 ACCESS/docs，memory 只留指针。
   **升默认过样本门**（measure-before-more 的复盘版）：n=1 只标 `OBSERVATION`、不改 spec/默认；**≥2 例同向**才升为改默认的教训。
   retro 只**提议**，改 spec 由主理人**裁定**（提议/批准分离，防按一次性事件堆规则）。
4. **上下文治理**：关交付完的会话 + **扫孤儿**（见 SKILL §5「孤儿扫」纪律：`docker ps`/`ps`/后台 job + compose
   trap/finally + repro 禁裸 `while True`）+ **worktree 核对**（已合分支的 worktree 必清 `git worktree remove`）+
   **敞口清单**（=下会话入口）。
5. **治理同步（与 memory 更新同级、不可省）**：文档归档（→ `orchestration/archive/` + 索引行）+
   **ACTIVE_CONTEXT 整篇重写**（非追加，~60 行）+ **roadmap 翻状态** + **决策队列刷新**（若用
   `DECISION_QUEUE.md`：清 ✅、revisit 到期项重浮、给周期全局图——队列腐烂是 §9 机制的最弱点，靠这步兜住）。
6. **memory 治理**：见下「memory 治理」。
7. **session 切换决策**：见下「session 切换决策」。

收尾跑 SKILL §5 的硬门 **`retro-check.sh`** —— 机械校验步骤 4/5/6 的产物（已合分支无孤儿 worktree、ACTIVE_CONTEXT
今日重写、roadmap 近期动过、DECISION_QUEUE.md 在则新鲜、MEMORY.md 未超行），**未全过不算复盘完成**（只验机械代理，语义对不对仍靠你）。

## memory 治理（步骤 6 展开）

- COMPLETED workstream 精简到 ≤10 行（结论 + 关键教训 + 指针），删掉过程细节。
- 事实性细节（路径 / 凭据 / 执行路径 / 导航步骤）沉淀到项目环境文档（如 `ACCESS.local.md`,
  由 `repo-governance-bootstrap` 生成），memory 只留指针——memory 跨 session 存活但容量有限，
  环境文档是 gitignored 的本地 SoT。
- 重复 / 矛盾的 memory 合并或删除；已过时的 workstream 状态更新。
- MEMORY.md 索引 ≤40 行，按类型分组（iron rules / active / completed / reference）。
- 实证：某项目 30 条 memory 含多个 100+ 行巨型文件，新 session 读入全是噪声。

## session 切换决策（步骤 7 展开）

治理完评估当前上下文状态，二选一：

- **压缩上下文续跑**：同一任务还在连续迭代、没有天然断点。
- **新 session + handoff**：天然交接点（等外部部署 / 验收、workstream 批次结束、角色 / 优先级切换）。
  写一次性 handoff 到 `/tmp/`（**不进 `docs/orchestration/`**——handoff 是 transient 交接产物，放治理
  SoT 会变又一个只生不死的死文件；持久状态归 ACTIVE_CONTEXT + memory，handoff 只快照运行时状态）。三件事：
  ① 待办队列（带状态 + session/worktree/branch 指针）；② 活跃 tmux sessions 及其当前任务；
  ③ 需用户决策的 blocking 项。新 session 读 handoff + memory 冷启动，**读完即删**。
