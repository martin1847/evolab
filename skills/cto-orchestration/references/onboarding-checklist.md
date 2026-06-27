# 新项目接入清单

> SKILL.md §8（新项目接入）的展开 = 整段操作清单。主干只留一行指针。

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   `references/agents-md-orchestration-section.md` 的 **委派 Agent 边界** 一节增补进去——多 agent 防
   漂移，是 bootstrap 宪法没有的编排增量（不重复 Work Modes）。
3. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 SKILL §5）。
4. 第一个任务走一遍 SKILL §1 全流程，校准该项目的忙碌标记/工具链差异。
5. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
6. 建主理人的 `docs/DECISION_QUEUE.md`（模板见 SKILL §9 / `references/decision-queue.md`）——第一个 T2 决定就进队列。
