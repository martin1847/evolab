# 新项目接入清单

> SKILL.md §8（新项目接入）的展开 = 整段操作清单。主干只留一行指针。

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   `references/agents-md-orchestration-section.md` 的**两节**增补进去——①委派 Agent 边界（多 agent
   防漂移）+ ②编排者行为内核（人格纪律 + 角色绑定；放 AGENTS.md 使 CC/codex/omp 任一坐编排位
   都吃到，均实测）。是 bootstrap 宪法没有的编排增量（不重复 Work Modes）。
3. **wire 强制层 hooks**：`cto-guard-bash.py` + `cto-guard-agent.py` 两条 entry 并进 bootstrap §11 已建的
   settings.json（路径用**绝对路径**——hooks 不展开 `~`；entry 全文见 `references/agent-watch/README.md`
   §Wiring）；接完各喂一条合成 payload **验真触发**（尾随 `&` 应 deny、browser 派发应出提醒），别只信"配了"。
4. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 SKILL §5）。
5. 第一个任务走一遍 SKILL §1 全流程，校准该项目的忙碌标记/工具链差异。
6. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
7. 建主理人的 `docs/DECISION_QUEUE.md`（模板见 SKILL §9 / `references/decision-queue.md`）——第一个 T2 决定就进队列。
