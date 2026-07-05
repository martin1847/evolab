# codex 评审派发模板（brief 文本）

> 首轮：brief 写成文件（`docs/orchestration/*_REVIEW_BRIEF.md`），
> `agent-watch/dispatch codex <proj>-<task>-codex <同一worktree> --goal <brief.md>` 一条命令——与 omp
> 派发同构（launch+送 brief+验证+自动 watch）。复审轮：`dispatch send -f` + 单独 watch。
> 裸 `tmux new-session` 缺 hook env → watcher 退抓屏，别用。评审期间 omp 不得改同一 worktree。

## 首轮评审

```
Independent code review. Review commit <sha> (the only commit(s) on <branch> vs origin/<base>)
in this worktree (<server root>). Context docs (read first): <goal.md> , <findings.md> (同目录).
Review focus: (1) <该变更最危险的轴，点名：旗标关路径零行为泄漏 / 崩溃恢复 / 并发竞态 /
降级语义 / 安全契约>; (2) <次轴>; (3) test adequacy; (4) scope discipline vs the goal
guardrails; (5) <作者声明的可疑点，要求独立验证，如"2 个预存失败 stale-on-base"的说法>.
Write your review to <REVIEW_codex.md 绝对路径> with severity-tagged findings
(blocker/major/minor/nit) and a final verdict (approve / request-changes).
Read-only review: do NOT modify code or commit.
```

## 复审（第 N 轮）

```
Round <N> re-review: commit <sha> addresses your findings — <逐条一句话>.
Verify each is properly closed — especially <上轮 HIGH 的修复自身的新风险，例如
"recovery path 自身是否 race-safe（恢复 vs 迟到的协调器 finally 双跑？）">,
and confirm no other changes snuck in. Append "Round <N>" verdict to <REVIEW_codex.md>.
Read-only.
```

## 收敛准则注入（防乒乓，第 3 轮左右仍未收敛时）

```
CONVERGENCE CRITERION (from the orchestrator, also state it in the findings doc):
<兜底机制> is a best-effort backstop — <主闸机制> is the primary gate. After this round,
the bar is: all COMMON <X> covered with tests. Further exotic gaps are minor follow-ups,
NOT ship blockers.
```

## 修复派回 omp 模板

```
codex round <N>: request-changes — read <REVIEW_codex.md> and address ALL findings in a
follow-up commit on this branch: [<severity>] <一句话> — <修复方向，含"mirror the EXACT
existing behavior of <同场景的既有路径>"这类对齐要求>; ... Add tests: <修复前必须红的
回归测试>. Re-run the suites, commit, append the change note to the findings doc.
```

## 经验

- **必点评审轴：LLM 产出进入结构化管道的接缝**——凡是"生成内容被当数据消费"的地方
  （提取结果落库、合成答案进解析器、引用标记进溯源链），评审必须验证：①有无内容
  契约（拒收 PII/秘密/编造）；②有无溯源校验（引用/ID 必须能对回真实来源集，幻觉
  条目剥除而非放行）；③测试 fixture 里要有"恶意/幻觉样本"且无防护时必红。
  实战两连击：记忆提取缺 PII 契约、KB 合成缺引用溯源——同一类洞。
- 每轮评审都点名"上一轮修复可能引入的新洞"——4 轮抓 4 个真问题是常态，不是评审过严。
- 要求 codex 独立复跑测试 + current-vs-base 对照（旗标关字节级一致的验证方式）。
- 作者的"与本次无关的预存失败"声明必须让 codex 在干净 base 上复现验证。

## SKILL §2 对抗式评审循环的展开

SKILL 主干只留判据清单（不夹带结论 anchoring / 点名轴 / 评审前枚举路径分叉 / 门控查 under-fire /
ledger 不纯追加 / 三分类收敛 / advisory→follow-up / stagnation 检测）。这里是轴全枚举、实证、ledger 栏目、达标线。

### 评审深度分档

先按风险定评审深度：日常/低风险改动 → 轻量标准 review（`codex review --base <base>` 原生子命令：自动算
diff + 结构级只读，省 prompt，挡基本质量/回归）；高风险（鉴权/迁移/基建脚本/大重构）→ 走完整对抗循环。
codex **无内置"对抗"强度档**——"对抗"是 prompt 层（自起会话点名轴 + severity/verdict + 多轮收敛），其
`review` 子命令只给"自动 diff + 只读 summary"、不给 verdict schema，故对抗循环**必须自起会话自控 prompt**，别用子命令。

### 起 codex + brief 冷上下文（不夹带结论）

omp commit+核证后起 codex 于同一 worktree。**只给"查哪些轴 + verify don't trust + 收敛达标线"，不夹带
自己的结论/倾向**——喂 codex 我的判断 = anchoring，换模型却共享推理链 = 异构去相关价值白费。

**点名最易翻车的轴**（让 codex 主动写探针复现，命中率远高于泛泛 review；每轮追问"上轮修复引入了什么新洞"屡抓真问题）：

**缺失消费者轴（absence review，diff 评审的结构性盲区）**：被评审改动若新增/变更一种**能力或
运行时语义**（新端点、token/会话寿命、重试契约、降级开关），必须问"**谁必须消费/适配它？
它们现在消费了吗？**"——缺失的调用方不存在于任何 diff 里，按 diff 划界的评审永远看不见
（实证 2026-07-05：后端上 refresh 端点+access 缩 2h，codex 过了后端 diff，前端零调用方，
过期态用户全灭到真机才发现）。brief 里点名这条轴时给评审者消费者清单的检索起点（前端仓路径/
调用点 grep 词）。
崩溃恢复、并发竞态、旗标关路径零泄漏、降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏（异常链/URL
userinfo/日志）；评测报告类加**指标诚实性**（指标虚高/证据越界泛化）。

**评审前先枚举执行路径分叉**（provider / mode、live vs rehydrate、suggestion-flow vs direct-save…），点
codex 核"还有哪些分支没走到"——只覆盖一条分支 ≠ 全覆盖（实证：评审只盯主 controller 路径，真实用户走另一个
provider 的独立分支，整条提取被绕过仍全绿）。

**门控/触发型功能必查 under-fire（"该触发时触发了没"），不只 over-fire**：有触发条件的特性（正则/旗标/阈值
门控）评审天然盯"会不会误触发"，常漏"真实输入下到底触发没"。实证：referent func-call 触发器检测的是**抽取后
被改写过的** content（指代已被改没）→ 真实场景永不触发；评审查了误触发、漏了漏触发，靠真模型验才抓出。

### ledger 结构 + 收敛准则

**评审记录用 ledger 结构，不纯追加**：写 `docs/orchestration/<NAME>_REVIEW_codex.md`——severity 分级
findings + verdict（approve / request-changes），并维护 `blocking / queued / advisory / 已修 / stagnation`
几栏，逐轮更新。结构化记录让收敛状态一眼可判，胜过流水账追加。

**循环回修每轮重贴不可变目标**：request-changes → 派回 omp 修 → codex 复审，循环到 approve。每轮派回时把原
goal 的不可变验收点重贴进 prompt 对照——防多轮改着改着跑题。

收敛准则（防乒乓，编排者设定）：
- findings 三分类：`blocking`（必修才放行）/ `queued`（记下不阻塞、留 follow-up）/ `advisory`（建议）。
  只有 `blocking` 残留才继续循环。
- **advisory/非逻辑项 → follow-up，别挡已就绪的 push**：先 ship 已 Verified 的东西，nit 攒成后续；真要并也
  先 push 再异步补（实证：为一行注释 fold-before-push，正撞 provider 过载、空耗一轮）。
- **不重复 raise** 已 queued / 越界 / 上轮判过的 finding——除非本轮动了那块或让风险变差。
- **stagnation 检测**：同一 finding 反复出现 = 卡住，该收敛或升级人介入，别无限对轰。
- 质量类无限可挑的项（过滤规则、命名）明确"达标线"：线内必修、线外进 `queued`。例："确定性过滤是兜底、LLM
  prompt 是主闸；常见形态全覆盖即达标，冷僻算 minor"。

**评审期 omp 别动同一 worktree**（codex 在内跑测试会被污染）。串行十几分钟换干净结论，值得。
