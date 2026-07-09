# 多 Agent 编排业界 SOTA（2025–2026）——内核的外部佐证

> 调研日期 2026-07。全部一手来源，每条附出处。用途有二：
> ① 给内核九条铁律做**外部 reverse-map**（SKILL.md §11 是两皮内证，这里是业界外证）；
> ② 收录内核尚未吸收的业界新判据（读并行写单线 / 复杂度分档 / 递归深度护栏）。

## 0. 铁律 ↔ SOTA 对照（外部自证）

| 内核铁律 | 业界佐证 |
|---|---|
| 一：编排者不做产物 | S5 官方 troubleshooting 点名"lead 抢活"病 + 修正指令；S10 核心工程师 Adam Wolf |
| 二：切分轴=要不要主上下文 | S4 官方"主对话 vs subagent"判据表；S3 context isolation 是委派的第一原因 |
| 三：派发即契约 | S1 实测 delegation 四要素（objective / output format / tool guidance / boundaries）逐条对上 |
| 四：模型按活分档 | S1 生产配置 Opus lead + Sonnet workers；S4 cost routing；token 用量解释 ~80% 效果方差 |
| 五：合并是工程 + 对抗验证 | S6 fresh-context reviewer（不带写码偏见）；S9 "verifier 必须近乎完美" |
| 六：萃取式慢增长 | S3 "worker 烧几万 token，回来只交 1-2k 蒸馏摘要" 原文同款 |
| 七：Implemented ≠ Done | S6 "show evidence rather than asserting success"；S9 worker 必留机器可读证据 |
| 八：降主理人认知负载 | S5 shared task list / 系统管依赖（状态不进人脑） |
| 九：状态落盘 | S9 filesystem lock + failed-approaches 跑账；S10 "file system as external memory" |
| **从业界吸收（2026-07 已入内核 §2/§3 + 常驻 digest）** | 读并行写单线（S7/S8 收敛共识）；规模按复杂度分档（S1）；分形递归护栏（S4） |

## 来源清单

| # | 来源 | URL |
|---|------|-----|
| S1 | Anthropic — How we built our multi-agent research system (2025-06) | https://www.anthropic.com/engineering/multi-agent-research-system |
| S2 | Anthropic — Building effective agents | https://www.anthropic.com/research/building-effective-agents |
| S3 | Anthropic — Effective context engineering for AI agents | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents |
| S4 | Claude Code 官方 subagents 文档 | https://code.claude.com/docs/en/sub-agents |
| S5 | Claude Code 官方 agent teams 文档 | https://code.claude.com/docs/en/agent-teams |
| S6 | Claude Code 官方 best practices | https://code.claude.com/docs/en/best-practices |
| S7 | Cognition — Don't Build Multi-Agents (Walden Yan) | https://cognition.com/blog/dont-build-multi-agents |
| S8 | LangChain — How and when to build multi-agent systems | https://www.langchain.com/blog/how-and-when-to-build-multi-agent-systems |
| S9 | Anthropic — Building a C compiler with a team of parallel Claudes (2026) | https://www.anthropic.com/engineering/building-c-compiler |
| S10 | agentkit.best subagent 误区复盘（含 Claude Code 核心工程师 Adam Wolf 引言） | https://agentkit.best/blog/vc-04-subagents-from-basic-to-deep-dive-i-misunderstood |

## 一、何时委派 vs 自己做（context economics / 并行性 / 隔离）

1. **委派的第一原因是 context isolation，不是"专业分工"。**
   - S4 原文："Use one when a side task would flood your main conversation with search results, logs, or file contents you won't reference again: the subagent does that work in its own context and returns only the summary."
   - S3："Each subagent might explore extensively, using tens of thousands of tokens or more, but returns only a condensed, distilled summary of its work (often 1,000-2,000 tokens)."
   - S6 把这条列为整份 best practices 的地基："Most best practices are based on one constraint: Claude's context window fills up fast, and performance degrades as it fills."
2. **官方"用主对话 vs 用 subagent"判据表（S4）：**
   - 用**主对话**：频繁往返 / 迭代打磨；多阶段共享大量 context；快速定点小改；latency 敏感（subagent 冷启动要重新收集 context）。
   - 用 **subagent**：产生大量主 context 不需要的 verbose output；需收紧 tool/permission 边界；工作 self-contained、一份 summary 能交差。
3. **读并行，写单线——2025 年 Anthropic vs Cognition 辩论后的收敛共识。**
   - S8："read actions are inherently more parallelizable than write actions."（Anthropic research 系统即并行收集、单次统一写作。）
   - S7："Actions carry implicit decisions, and conflicting decisions carry bad results."（并行写码的 agent 隐式决策互相冲突。）Cognition 认可的例外恰是 Claude Code 式 subagent："subagents should be read-only investigators, not independent decision-makers."
   - S1（Anthropic 自承）：multi-agent 不适合"most coding tasks (fewer parallelizable components)"。
4. **成本天花板**：S1 multi-agent 比 chat 多耗约 15× token；Opus lead + Sonnet subagents 在 breadth-first research eval 上比单 Opus 好 90.2%——但只对"heavy parallelization、信息量超单 context window"的任务成立。S2 总纲："consider adding complexity *only* when it demonstrably improves outcomes."
5. **subagents vs agent teams（S5）**：subagent = "focused tasks where only the result matters"（token 便宜）；team = 需要讨论协作（竞争假设 debug、跨层各占一摊）。"For sequential tasks, same-file edits, or work with many dependencies, a single session or subagents are more effective."

## 二、如何写 task brief

6. **委派 prompt 四要素（S1 实测）**：Objective / Output format / Tool & source guidance / Task boundaries。反例原文：模糊指令让 subagent "misinterpreted the task or performed the exact same searches as other agents"。
7. **brief 必须自包含**（S4）：非 fork subagent 起步只有自己的 system prompt + 委派消息 + CLAUDE.md + git snapshot，"It doesn't see your conversation history…"（Explore/Plan 型连 CLAUDE.md 都不加载）。S7 反面依据：做不到共享 trace 就必须把关键决策显式写进 brief，否则 telephone game。
8. **规模按复杂度分档（S1，防 overinvestment）**：简单 fact-finding = 1 agent（3-10 tool calls）；直接对比 = 2-4 subagents（各 10-15 calls）；复杂研究 = 10+ subagents 明确分责。早期失败模式：为简单查询 spawn 50 个 subagent。
9. **模型/工具分档**（S4）：便宜活路由到弱模型；tools 用 allowlist 最小权限（read-only reviewer 不给写权限）。
10. **任务粒度（S5/S9）**："Too small: coordination overhead exceeds the benefit… Just right: self-contained units that produce a clear deliverable." 团队从 3-5 人起步："Three focused teammates often outperform five scattered ones." S9 粒度反例：把"编译 Linux kernel"当单一巨型任务 → 全员撞同一 bug 互相覆盖；拆成"每 agent 认领一个 failing test"则并行 trivial。

## 三、Orchestrator 纪律

11. **plan-then-delegate**（S1）：lead 先评估工具适配与查询复杂度、拆成 well-defined subtasks 再派。
12. **别自己抢活**（S5 troubleshooting 原文修正指令）："Wait for your teammates to complete their tasks before proceeding." 已委派的搜索不要自己再跑一遍。
13. **对抗式独立验证**（S6）：fresh subagent context 的 reviewer 只看 diff 与标准、不带产生该改动的推理偏见。反噬警告同页："A reviewer prompted to find gaps will usually report some, even when the work is sound"——限定只报影响 correctness 的。S9：无人值守并行的前提"the task verifier is nearly perfect"，worker 必须留证据（README/进度文件/机器可读 log）。
14. **状态外置文件系统**（S9/S10/S5）：filesystem lock、failed-approaches 跑账、shared task list；文件所有权切分防覆盖。
15. **监控与止损**（S5/S1）：无人值守跑太久 = 浪费风险上升；拿到足够结果就停（早期失败模式之一是不停）。追加同主题工作优先 resume 已有 subagent（保留历史）而非重派冷启动。

## 四、递归委派（分形）：何时合适、深度护栏

16. **官方立场（S4，Claude Code v2.1.172+ 正式支持 subagent 再 spawn）：**
    - 合适场景原文："Use this when a delegated task itself splits into parallel subtasks, such as a reviewer subagent that dispatches a verifier per finding, so the intermediate output never reaches your main conversation."——递归的正当性依然是 context isolation，不是组织架构美学。
    - **硬性深度上限 5 层，不可配置**；深度 spawn 时固定，resume 不能绕过。
    - 护栏手段：从 subagent 的 `tools` 去掉 `Agent` 即禁再分；coordinator 用 `Agent(worker, researcher)` allowlist 限定可 spawn 类型。
    - Teams 反而**禁止**嵌套（S5）："No nested teams… Only the lead can manage the team."
    - 实践推论：递归是例外不是默认——每层多一次 summary 压缩（telephone game 损耗随深度累积，S7），合理形态 = fan-out 一层为主，第二层仅用于 per-finding 验证这类天然树状、每节点 brief 极小的任务。

## 五、失败模式清单

| 失败模式 | 出处与修正 |
|---|---|
| Over-delegation / overinvestment | S1：简单查询 spawn 50 subagent；修正 = 复杂度分档（第 8 条） |
| Telephone game / context loss | S7：只传任务不传决策 context → 冲突假设各干各的；修正 = 自包含 brief 或单线程 |
| Duplicate work | S1：brief 模糊 → 多 subagent 跑同样搜索；修正 = 显式 boundaries |
| 用 subagent 做 implementation | S10：按前后端分 specialist 各写各的 = 最大社区误区；Adam Wolf："Sub agents work best when they just looking for information and provide a small amount of summary back." 实现类并行用 teams + 文件所有权 / worktree |
| 同文件并行写入互相覆盖 | S5/S9；修正 = per-file ownership、worktree、filesystem lock |
| Coordination overhead 吞掉收益 | S5："beyond a certain point, additional teammates don't speed up work proportionally" |
| Lead 抢活 / 提前收工 | S5 troubleshooting 两条原文 |
| Subagent 结果回流撑爆主 context | S4 warning；修正 = output contract 限定返回长度/形态 |
| 无验证信任 worker 自报 | S6 + S9；修正 = fresh-context 对抗 review + 要证据不要断言 |
| Reviewer 过度找茬 → over-engineering | S6；限定只报影响 correctness 的 |

## 六、一段话总纲

综合 S1/S2/S4/S7 收敛共识：**默认单线程做；只有当 (a) 中间产物大而结论小（context economics 划算），或 (b) 子任务是相互独立的读操作可真并行，才委派。委派 brief 自包含并带四要素，effort 按复杂度显式分档；写操作保持单一 writer；orchestrator 只持蓝图与验收，状态放文件系统，结果用 fresh-context 对抗验证；递归委派仅限天然树状且每层返回极小的任务，平台硬限 5 层，实践 1-2 层。**

---

**调研局限**：全部来自公开来源 WebFetch；S4/S5/S6 读了全文原文（引文可靠度最高），S1/S2/S3/S7/S9 经抓取摘要转述（个别措辞可能与原页有细微出入）；未做本地实验复现。
