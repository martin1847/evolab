# GOAL — <一句话任务名>（<implementation | research-only | hotfix>）

> Owner: omp. Worktree `<abs path>`, branch `<feat/...>`（cut from latest origin/<base> @ <sha>）.
> Reviewer: codex（after commits）. Commits stay LOCAL — pushing requires <用户名> approval.
> Paths relative to `<server root>`. 如属研究：RESEARCH ONLY — no code changes, no commits.

## Context (read first)

<前置研究/诊断文档列表 + 一段话现状。来自外部的观测事实（运维/QA）原样列出并标注
"ground truth：与假设矛盾时事实赢">

## Pre-triage hypotheses (verify, don't trust)

- **H1 (likely primary)**: <假设 + file:line 证据>
- **H2**: <...>
（编排者预判可以加速，但必须标注为待验证——执行者有义务推翻它们）

## Task / Deliverables

1. <可验证的具体产出，含文档名>
2. **Tests**: <要求的测试形态——回归测试必须"修复前红、修复后绿">
3. **E2E**: <环境 + 数据约束（哪个 DB 批准了写）+ 做不到时的诚实降级路径>
4. 文档：findings 写入 `docs/orchestration/<NAME>_<FINDINGS|IMPL>_omp.md`，
   含 what-changed / what-verified(真跑过) / NOT-verified / 剩余假设。

## Done when（完成判定 — 逐条须有**本次会话工具结果**级证据，非记忆中的旧结果；验证范围匹配声明范围）

- [ ] <可验证后置条件：行为变了 / bug 不再复现 / 产出存在——写成"两个评审独立判会得同一 pass/fail"的无歧义形态>
- [ ] 回归测试绿、独立复跑 test+lint 干净；单测过 ≠ 端到端成立，E2E 范围匹配声明范围。
- 不确定 = 未完成；预算/时间耗尽 ≠ 完成。未达成就保持任务 active + STOP and report，别把易达成的子集当目标。

- 鉴权/会话/用户数据相关改动：验证须覆盖**状态形状矩阵**（新鲜登录 / 过期会话 / 贫数据账号 / 未登录），
  不得只测新鲜快乐态（见 frontend-verify「状态形状矩阵」）。

## Guardrails

- Scope = <精确边界>。No refactors of neighboring code, no format changes.
- 禁止删 / 改 / 跳过测试、断言或 grader 来让验收通过——测试集对执行者只读（成功标准"红→绿"最易被 game）。
- 旗标门控：<flag 名，默认 ON/OFF + 理由>。
- 遇到需要超出 scope 的改动：STOP and report，不要自行扩权。
- 遵守仓库自身规则（AGENTS.md / GitNexus impact analysis 等）。
- 点名本仓适用的工程规范 skill 并要求执行 agent 开工前加载（观测/后端/git 等）——**名单来自该仓 AGENTS.md 的声明，本模板不硬编码任何具体规范**（编排与规范各自独立可用，不耦合）。
- Redact secrets/customer data in docs. No AI signature lines in commits.
