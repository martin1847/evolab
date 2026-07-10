---
name: agent-backend-standard
version: 1.0.6
description: 生产级 agent 时代后端工程手册(hub)——建 / 评审 agent·LLM 后端、**任何碰 DB 的持久层后端**、或为任何后端建立 / 评审 repo 工程门禁时加载。覆盖:架构与控制流、上下文与 prompt 工程、工具设计(ACI)、记忆与状态、检索/RAG、韧性与幂等、人在环、安全护栏与生成操作的有界执行、评估、可观测与成本、代码/依赖生命周期与反死代码、**数据访问纪律(连接·读·写事务)**、Python/Go/Java/Rust 统一 `fix/check/test` 工程接口与门禁、规范治理。本文件是目录,深度按需读 references/。可观测性/Git/A2A 对外契约是独立 skill,本 hub 交叉引用不重复。Use when building or reviewing agent/LLM backend code, ANY backend touching a database, or establishing/reviewing repository engineering gates for a backend: architecture, prompts, tools, memory, RAG, resilience, HITL, safety and bounded execution, eval, cost, code/dependency lifecycle, data access, and the Python/Go/Java/Rust fix/check/test gate interface.
---

# Agent Backend — 后端工程手册（hub）

agent 时代后端工程规范的集中入口。**本文件是目录(ToC):每章一句话 + reference 指针。深度全在 `references/`,按需读单章,别全量加载。**

> 双层落地:软层 = 本手册(write-time 预防);硬层(CI 门禁 / ruleset / 清扫 bot)归 你的 IaC 仓 / IaC CTO。
> 粒度:同属"写·评审 agent 后端代码"这一触发的 concern 都在本 hub 作章;**独立 skill 仅限触发动词不同者**——埋点 → `observability-standard`、git → `git-workflow-standard`、A2A 对外契约 → A2A 对外契约规范(本 hub 交叉引用,不重复)。
> *TBD* 章 = 已占位、待真实素材再写实(不空写通用建议)。

## Book I — Foundations
- **I-1 何时该建 agent** —— simplicity-first;能确定性 / 工作流解决就别上 agent。*TBD*
- **I-2 架构与控制流** —— augmented-LLM 基元、workflow 模式(chaining/routing/parallel/orchestrator-workers/evaluator)、单 vs 多 agent。*TBD*

## Book II — Engineering Concerns
- **II-3 上下文与 prompt 工程** → `references/prompt-context.md` —— 含 **prompt 内容生命周期**(写死值绑 eval、模型耦合打 `REVISIT-WHEN`)。
- **II-4 工具 / 函数设计(ACI)** —— 整合/命名空间/返回上下文/token 效率。*TBD*(交叉引 A2A 对外契约规范)
- **II-5 记忆 / 状态 / 持久** → `references/state-durability.md` —— workflow 首次 runnable / 首个副作用前原子固化 immutable effective-config snapshot(`snapshot_id` + digest);step / resume / recovery 只读该 snapshot,缺失 / 损坏 / digest mismatch fail-closed。
- **II-6 检索 / RAG / grounding** —— chunking、faithfulness、向量弱点。*TBD*
- **II-7 韧性 / 错误 / 幂等** → `references/resilience.md` —— 每个外部/LLM/工具调用:超时 + 有界重试 + 幂等 + 熔断 + 池/并发;**事件循环不阻塞**(async 运行时承重条,五层门禁:lint→测试期检测→staging 阈值→生产 lag 遥测→部署断言)。
- **II-8 人在环(HITL)+ resume 安全** → `references/hitl-resume-safety.md` —— 可恢复 flow 的 resume 安全:**六道闸**防御(持久 checkpoint 校验请求 ctx、fail-closed、runtime 层)。clarify/approve 协议交叉引 A2A 对外契约规范。
- **II-9 安全 · 护栏 · 生成操作的有界执行** → `references/safety-bounded-execution.md` —— 执行不可信生成操作(尤 SQL)的硬边界、安全分层、workflow 迭代上限。

## Book III — Operations & Governance
- **III-10 评估与测试** —— offline/online、LLM-as-judge、eval 驱动选型。*TBD*
- **III-11 可观测与成本 / 时延** → `references/observability-cost.md` —— 薄:成本/token/时延预算;埋点本体交叉引 `observability-standard`,不重复。
- **III-12 规范治理** → `references/governance.md` —— 例外/偏离、owner、手册如何演化。

## 附(本仓并入,非 agent 专属但同一触发)
- **A 代码 / 依赖生命周期 + 反死代码** → `references/code-dependency-lifecycle.md` —— 引入即退役(ADR-with-sunset)、stale-but-live(`EXPIRES`/`REVISIT-WHEN`)、**功能旗标生命周期(分类 + 毕业/退休 + 登记册)**、死代码检测 + 盲区、反 bloat、清扫。
- **B 数据访问纪律(连接·读·写)** → `references/data-write-discipline.md` —— **读也占连接**(弱事务/autocommit 用完即释放;MANAGED+closeConnection=false 无事务读 = 泄漏);记账写移出主链路 / 不跨 LLM 持锁 / 服务端增量;**关键写保留原子性但同样不持锁跨 LLM/执行**(短原子写 + 锁外执行)。
- **C Agent-friendly engineering interface** → `references/engineering-interface.md` §1–§6 —— Python / Go / Java / Rust 统一 repo-owned `fix/check/test` 接口、legacy ratchet、初始化 forcing function 与失败自解释契约;边界类型规则只交叉引 observability §2,不复制。

## 关联(独立 skill,不在本 hub 重复)
- 埋点 / telemetry → `observability-standard`;Git SOP → `git-workflow-standard`;A2A 对外契约 → A2A 对外契约规范。
- 硬层 CI 门禁 / ruleset / 清扫 bot → 你的 IaC 仓。
