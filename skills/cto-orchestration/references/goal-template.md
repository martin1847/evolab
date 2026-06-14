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

## Guardrails

- Scope = <精确边界>。No refactors of neighboring code, no format changes.
- 旗标门控：<flag 名，默认 ON/OFF + 理由>。
- 遇到需要超出 scope 的改动：STOP and report，不要自行扩权。
- 遵守仓库自身规则（AGENTS.md / GitNexus impact analysis 等）。
- Redact secrets/customer data in docs. No AI signature lines in commits.
