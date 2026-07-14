# 复盘仪式操作手册

> SKILL.md §5「复盘仪式」的展开 = **本文件是 checklist 本体，逐条勾**。事件触发：收口 / 压缩前 / 任何 ReOpen 后主动提议。
> SKILL §5 是入口（纪律 + 机械检查 `retro-check.sh`）；这里是七步全文 + 后两步操作细节。
> **即兴版必静默漏承重治理步**——逐条过，别凭记忆。

## 七步 checklist

1. **交付清单**：shipped / parked / 残留。
2. **过程×结果四象限**（每个收口单元落唯一一格，禁「上线=好」塌缩）：好程好果=**实力赢**(固化做法) ·
   坏程好果=**走运**(别奖励、补过程洞) · 好程坏果=**倒霉**(别改流程) · 坏程坏果=**实力输**(改)。
   判「走运」即使 shipped 也标 outcome 星号 + 点出过程缺口（实证：PR 已交但 GUI 仅手动测试计划未跑 → 不给满分）。
3. **教训分层沉淀**（系统方法论见内核 `orchestrator-core/references/self-evolution.md`，此步为其操作化、自包含可跑）：
   - **分诊落层**：五问追根，**追问停在哪层、教训就落哪层**——事实（路径/凭据/执行路径）→ ACCESS/docs；
     本项目情景教训 → memory（带 **Why + How-to-apply + provenance**〔哪次事故立的〕，memory 只留指针
     不存事实细节）；跨项目操作规则 → skill reference；判断标准 → skill 主干；范式 → meta。
     同类补丁在低层反复出现 = 上一层治理变量有缺陷的信号，升层提问、别再加一条。
   - **晋升三门**：**样本门**（measure-before-more 的复盘版）——n=1 只标 `OBSERVATION`、不改 spec/默认，
     **≥2 例同向**才提议升层；**行为门**——顺手核一条：上轮复盘沉淀的教训这轮 fire 了吗（记录 ≠ 学会，
     没 fire 的进下条淘汰）；**压缩门**——同层出现 **≥3 条同族条目 → 提蒸馏合并案**（1 条上层判据 +
     retire 原件，corpus 总量不增；总量没减 = 复制不是晋升）。retro 只**提议**，改 spec 由主理人**裁定**
     （提议/批准分离，防按一次性事件堆规则）。
   - **淘汰同轮做**：会在动手那一刻 fire 的才留正文；hook 已强制的收成一行指针；从不 fire 的删或降
     README 背景（不 fire 的散文是净负债，实证：三条早已写清的规则同日全部没在决策点应用）。
4. **上下文治理**：关交付完的会话 + **扫孤儿**（见 SKILL §5「孤儿扫」纪律：`docker ps`/`ps`/后台 job + compose
   trap/finally + repro 禁裸 `while True`）+ **worktree 核对**（已合分支的 worktree 必清 `git worktree remove`）+
   **敞口清单**（=下会话入口）。
5. **治理同步（与 memory 更新同级、不可省）**：文档归档（→ `orchestration/archive/` + 索引行）+
   **ACTIVE_CONTEXT 整篇重写**（非追加，~60 行）+ **roadmap 翻状态** + **决策队列先清再刷**（若用
   `DECISION_QUEUE.md`：先移除已处理项，再把 revisit 到期项重浮、给周期全局图。队列只存活跃项，旧决定靠 git history 留痕）。
6. **memory 治理**：见下「memory 治理」。
7. **session 切换决策**：见下「session 切换决策」。

收尾跑 SKILL §5 的 **`retro-check.sh`**：已合分支孤儿 worktree 与 ACTIVE_CONTEXT 新鲜度是 blocking FAIL；
roadmap、DECISION_QUEUE 和 MEMORY 只给 warning，exit 仍可为 0，需按任务语义人工裁决。脚本只验机械代理，不能证明复盘语义完成。

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
