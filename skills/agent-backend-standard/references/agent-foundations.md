# I-1 / I-2 — 何时建 agent · 架构与控制流（合章）

> 素材基线：Anthropic building-effective-agents / loop-engineering / effective-context-
> engineering、12-factor-agents（含其停更教训）。

## I-1 何时该建 agent（simplicity-first）

- 判据一句话：**已知步骤的活用工作流（真控制流），未知步骤的探索才用 agent 循环**。
  "别用 prompt 做控制流"（12-factor agents 的核心遗产；该项目 2.5 万星后停更
  ——方法论热度≠持续维护，引用时说明）。
- 升级路径：单次 LLM 调用 → 加检索/工具的 augmented LLM → 固定工作流编排 →
  agent 循环。每一级只有在上一级实测不够时才升——agent 循环的成本是
  不确定性+token+调试面。
- 建 agent 前先问：停止条件能否量化？（测试通过数/阈值/明确验收）——
  量化不了的目标交给 agent 只会拿到 "looks done"。

## I-2 架构与控制流

**五个工作流基元**（组合优先于自由 agent）：
- chaining（顺序分解）/ routing（分类分流）/ parallelization（切片或投票）/
  orchestrator-workers（动态分解+回收）/ evaluator-optimizer（生成-评审循环）。

**agent 循环分类**（按触发与停止条件）：
- turn-based（人触发人收）/ goal-based（独立 evaluator 每轮判停止条件）/
  time-based（定时/轮询）/ proactive（事件驱动）。停止条件必须机器可判。

**单 vs 多 agent**：默认单 agent+好工具；并行读（调研/评审 fan-out）收益实、
并行写需按所有权隔离（同 cto-orchestration「读并行写单线」）。多 agent 交接用
**artifact handoff**（读写文档，不对话）——上下文不共享是特性不是缺陷
（fresh context 评审无沉没偏见）。

**上下文工程四处方**（Anthropic 规范级）：just-in-time 检索（轻量标识符+按需展开）、
compaction（长任务蒸馏重启）、structured note-taking（进度外化到文件）、
sub-agent 架构（大读移出主上下文）。反面：context rot——塞得越满注意力越稀。

## 电在回路接线

工作流/agent 选型是判断项（散文层）；但停止条件量化与迭代预算上限可下沉——
goal 门/Stop hook/最大轮数熔断（门禁落地见附录 F selfcheck-gates，经 SKILL.md 目录进入）。
