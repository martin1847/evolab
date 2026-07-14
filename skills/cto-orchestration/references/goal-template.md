# GOAL — <一句话任务名>（<implementation | research-only | hotfix>）

> Owner: omp. Worktree `<abs path>`, branch `<feat/...>`（cut from latest origin/<base> @ <sha>）.
> Reviewer: codex（after commits; flag only findings that affect correctness or the stated
> requirements——no bar, review 必驱动 over-engineering）. Commits stay LOCAL — pushing requires
> <用户名> approval. 本 goal 中所有“先读路径”和“交付物路径”必须写绝对路径，尤其跨伞仓/子仓；
> 不要求证明命令内部每个参数都绝对化。如属研究：RESEARCH ONLY — no code changes, no commits.

## Context (read first)

<前置研究/诊断文档列表（每项写 `/absolute/path/to/...`）+ 一段话现状。来自外部的观测事实（运维/QA）原样列出并标注
"ground truth：与假设矛盾时事实赢">
<凭据/环境入口给**绝对路径**（如 `ACCESS.local.md`——worker cwd 在 worktree，相对搜找不到，实证）；
build/test 关键命令若该仓 AGENTS.md 未列，在此内联一行>

> iterative/speculative 任务（调研、实验、新能力、自动化、多轮评审）可按需保留下一行；若无额外价值判断必要则删除。普通 bugfix / 明确小改删除它。
Value gate: <existing gap → incremental value>; falsifier: <cheapest check + rejection signal>
Optional absence-evidence gate (delete unless the decision relies on not observing X): known-positive probe: <how the detector proves it can see X>; otherwise report UNKNOWN.

## Pre-triage hypotheses (verify, don't trust)

- **H1 (likely primary)**: <假设 + file:line 证据>
- **H2**: <...>
（编排者预判可以加速，但必须标注为待验证——执行者有义务推翻它们）

## Premises this goal rests on (VERIFY — do not trust)

> 仅当本 goal 依赖 upstream audit / scout 结论时填写。编排者必须抽出每条承重 premise；candidate evidence
> is not a verdict。任何 premise 为假 → **STOP AND REPORT**，不得在错误基础上继续实现。

- [ ] **Claim**: <承重前提> — **Verify by**: <独立证明命令 / runtime evidence + 预期结果>
- [ ] **Claim**: <...> — **Verify by**: <...>

## Task / Deliverables

1. <可验证的具体产出，含交付物绝对路径>
2. **Tests**: <要求的测试形态——回归测试必须"修复前红、修复后绿">
3. **E2E**: <环境 + 数据约束（哪个 DB 批准了写）+ 做不到时的诚实降级路径>
4. 文档：findings 写入 `/absolute/path/to/worktree/docs/orchestration/<NAME>_<FINDINGS|IMPL>_omp.md`，
   含 what-changed / what-verified(真跑过) / NOT-verified / 剩余假设 / 意外发现与关键决策（含理由）。

## Done when（完成判定 — 每条绑定证明命令，逐条须有**本次会话工具结果**级证据，非记忆中的旧结果；验证范围匹配声明范围）

- [ ] <可验证后置条件 + **证明命令与预期输出**（如 "`npm test` exits 0"）——写成只看输出即可机械判
  pass/fail 的形态（两个评审独立判得同一结论；harness 原生完成判定器如 Claude Code `/goal` 可直接消费这种条件）>
- [ ] 回归测试绿、独立复跑 test+lint 干净；单测过 ≠ 端到端成立，E2E 范围匹配声明范围。
- 普通非 review-loop 长跑可按需写时长 / 成本预算；耗尽仍未达成 = 保持任务 active + STOP and report。
  review-loop 的轮数预算只由 runtime `--max-rounds` / exec.meta 强制，本 GOAL 不复制轮数。
- 鉴权/会话/用户数据相关改动：验证须覆盖**状态形状矩阵**（新鲜登录 / 过期会话 / 贫数据账号 / 未登录），
  不得只测新鲜快乐态（见 frontend-verify「状态形状矩阵」）。

## Guardrails

- Scope = <精确边界>；**out of scope（枚举）**= <明确不做的相邻项>。No refactors of neighboring
  code, no format changes.
- 禁止删 / 改 / 跳过测试、断言或 grader，禁止压制错误顶替修 root cause——测试集对执行者只读
  （成功标准"红→绿"最易被 game）。
- 旗标门控：<flag 名，默认 ON/OFF + 理由>。
- **动手前理解门（按 lane）**：TUI lane 先复述"碰哪些文件/契约、有哪些风险、scope 是什么"，等编排者
  放行再动手（高风险任务升级为先交 mini-plan）；headless lane 简短复述后直接开工、不得等待交互，真阻塞
  才写 `/absolute/path/to/cwd/BLOCKED.md` 并停止。
- **存疑协议**：goal 没写明的事项标 `NEEDS-CLARIFICATION: <具体问题>` 停下问，**禁止合理化猜测**
  （猜而不问是 goal 执行最常见的静默失败）；需要超 scope 改动、或同一路径连败两次：STOP and
  report（blocked + 已试过什么），不自行扩权、别硬耕。
- 遵守仓库自身规则（AGENTS.md / 项目声明的影响分析工具等）。
- 点名本仓适用的工程规范 skill 并要求执行 agent 开工前加载（观测/后端/git 等）——**名单来自该仓
  AGENTS.md 的声明，本模板不硬编码任何具体规范**（编排与规范各自独立可用，不耦合）。
- Redact secrets/customer data in docs. No AI signature lines in commits.
