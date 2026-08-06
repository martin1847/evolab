# codex 评审派发模板（brief 文本）

> 目录：[首轮评审](#首轮评审) · [复审](#复审第-n-轮) · [收敛准则注入](#收敛准则注入防乒乓第-3-轮左右仍未收敛时) ·
> [修复派回模板](#修复派回-omp-模板) · [对抗式评审循环展开](#skill-2-对抗式评审循环的展开)（深度分档 / 冷上下文 / 高危轴 / ledger + 收敛）

> 首轮：brief 写成文件（`docs/orchestration/*_REVIEW_BRIEF.md`），
> `agentctl start codex <proj>-<task>-codex <同一worktree> --goal <brief.md> --workflow review-loop
> --max-rounds <N>`——与 omp 派发同构。start 返回后立即另挂 `agentctl watch`；复审轮同样是
> `agentctl steer -f` + `watch`。裸 `tmux new-session` 绕过 durable state 与 lane routing，别用。
> 初轮计入总轮数；stop-loss 只认 runtime meta（duplex 会话档），GOAL/brief 不复制轮数。到限后 send 返回
> `BUDGET-EXHAUSTED`（exit 9），不得绕过，转人工裁决。
> 差分口径统一 **three-dot**（`origin/<base>...HEAD`，对 merge-base 差分）：并发合并环境下 stale base 的
> 两点差分会把他人 commit 的反向删除混进评审面、误判为回退报 blocking；
> 评审不因 base 移动而 rebase；rebase 归 push/merge 阶段、由编排者按所在仓的 Git 协作规范收口。
> 定 `--max-rounds` 时：催写 nudge 也走 steer 计轮——预算 = 内容轮 + 1（max-rounds 1 遇 idle
> 即死局，连催写都投不进只能重开；上限不是燃料，slack 轮用不到零成本）。
> - [ ] 写 codex 评审 brief / steer → 用中性工程措辞，避 forged / impostor / attack / probe 类
>   攻击词汇（对象：投给引擎的 prompt 文本；安全型内容过滤只判 prompt，被读文件不进判定）。
> - [ ] codex 轮被 cyberPolicy 拦 → 重投前先净化 prompt：敏感细节移入被读文件、prompt 只留
>   中性指针；仍被拦 → 开新会话兜底（对象：该评审任务；失败轮照常计入轮数预算）。

## goal-review（派发前，白名单免评 + 其余必评）

> 免评白名单唯一正源在此；每条目共同硬门 = **不新增任何决策面**（判据 / 门 / 指标 /
> 停止规则 / 行为契约），任一新增即出白名单。派发前逐条判：
>
> - [ ] 纯只读取证 / 调研 / 研究类（不写任何东西、只产出结论）→ 免评
> - [ ] 其余——含一切带写动作的 goal，哪怕看着机械（门禁 / 量具类必评：改断言即改判据）→
>   1 轮冷上下文 goal-review（异构模型，只读 goal 文本，不喂实现语境）；歧义即 fail-closed

问块按 goal 命中的面选用，任一问不过即 blocking，修 goal 再派；命中仪器面时该轮还须产出
**承诺面变异清单**（异源出题，实现者逐条做到红——判据见仪器第 5 问）：

**仪器六问**（goal 定义验收判据 / 门 / 指标 / 停止规则 / error 分型时）：

1. 判据能否**看见**它要防的那类损坏？已知阳性是什么？
2. 判不出时默认走向哪？必须落 `UNKNOWN`，不许滑向 pass。
3. 负对照在哪（好样本必须绿）？
4. 每类 error 双问：会否造成伤害？会否让收益消失？
5. 坏样本**从哪来**？只认打在**承诺面**的（读者会信的那句话，破它即行为真变坏）；打在实现中间结构
   （内部表 / 注册表 / 自洽性）的不算自证——量具、坏样本、损害命名同源时模型错是共模的，同源自证
   永远测不出。
6. 判据把一份枚举当**完备集**消费（治理其每个成员、或支撑「无遗漏」结论；声明为示例/抽样/
   开放式的清单不适用）→ 双问完备性：这份清单从哪个**视角**产生？换到消费者/运行时机制视角，
   还有哪些通道/入口/平面没进账？消费前先做**已知成员校准**——枚举法须召回一个已知成员，
   召不回 = 清单残缺、该枚举结果不得消费（校准正源见 implementation-discipline
   §否定性结论与 Goodhart，此处为其 goal-review 时刻的 fire 点）。

**契约三问**（goal 定义新行为契约时——状态机 / 确认流 / 自然语言判别面 / 授权·租户语义）：

1. 状态机每个转移的**显式触发信号**是什么？无信号 / 上下文丢失时缺省走向哪？
   （"未拒绝"不是"已确认"。）
2. 每个判别面 fail-open 还是 fail-closed？两个方向的代价各是什么？
3. 是否在**枚举自然语言**做判别？枚举即打回——换结构性通道（显式命令 / 结构化握手 / 状态标记）。

## 首轮评审

```
Independent code review. Review the change set `origin/<base>...HEAD` (three-dot = merge-base
diff; commits <sha…>) on <branch> in this worktree (<server root>). Context docs (read first): <goal.md> , <findings.md> (同目录).
Review focus: (1) <该变更最危险的轴，点名：旗标关路径零行为泄漏 / 崩溃恢复 / 并发竞态 /
降级语义 / 安全契约>; (2) <次轴>; (3) test adequacy; (4) scope discipline vs the goal
guardrails; (5) <作者声明的可疑点，要求独立验证，如"2 个预存失败 stale-on-base"的说法>.
Investigate every suspicious pattern aggressively — filtering happens at the verdict layer,
not by self-censoring. Skip: generated code / lockfiles / anything CI already enforces / <项目排除面>.
Evidence bar: every finding cites file:line (not inference from naming); blocker/major additionally
needs a probe or failing test that reproduces it. Rate each finding with confidence (0-1).
Write your review to <REVIEW_codex.md 绝对路径> with severity-tagged findings
(blocker/major/minor/nit; pre-existing bugs not introduced by this diff tagged PRE-EXISTING —
record, don't block) and a final verdict (approve / request-changes) + a one-line tally up front.
Cap nits at 5, mention the rest as a count.
Calibration: only findings that affect correctness or the stated requirements can block;
speculative hardening / style go to advisory.
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

- **复审轮只审封闭性**（上轮 finding 是否真闭 + 修复引入的新洞 + 无夹带改动），别让同一会话重扫全量——
  受控实验（arXiv 2603.12123）：同会话对同一改动评第二遍不是更严、是**加投机噪声**（精度反降）；
  要全新全面评审就起 fresh session。每轮点名"上一轮修复可能引入的新洞"——4 轮抓 4 个真问题是常态。

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

修复涉及**资源界限 / 生命周期**（锁、超时、marker、句柄）时，模板必须加一句：先枚举**全部**够得到
该资源的路径再动手（SKILL §3「病类确认后枚举同模式点」的修复态 fire 点）。

## SKILL §2 对抗式评审循环的展开

SKILL 主干是判据清单；这里是轴全枚举、ledger 栏目、达标线与模板。

### 评审深度分档

先按风险定评审深度：日常/低风险改动 → 轻量标准 review（`codex review --base <base>` 原生子命令：自动算
diff + 结构级只读，省 prompt，挡基本质量/回归）；高风险（鉴权/迁移/基建脚本/大重构）→ 走完整对抗循环。
**shipped 脚本小改走轻量单轮**：文案/常量/单函数收紧、
匹配逻辑面未扩 → 单轮冷评审（--max-rounds 1）+ 机器可验修复即收，轮数耗尽转 owner 裁决；碰匹配
逻辑/新增规则/生命周期 → 完整对抗循环。
codex **无内置"对抗"强度档**——"对抗"是 prompt 层（自起会话点名轴 + severity/verdict + 多轮收敛），其
`review` 子命令只给"自动 diff + 只读 summary"、不给 verdict schema，故对抗循环**必须自起会话自控 prompt**，别用子命令。

### 冷上下文 + 激进找、出口滤

omp commit+核证后起 codex 于同一 worktree。**只给"查哪些轴 + verify don't trust + 收敛达标线"，不夹带
自己的结论/倾向**——喂 codex 我的判断 = anchoring，换模型却共享推理链 = 异构去相关价值白费。冷上下文
反锚定有定量背书（arXiv 2603.12123：冷上下文评审 F1 显著高于同会话自评，收益来自 context separation 本身）。

**激进找、出口滤（两层分工别选反边）**：brief 鼓励评审者调查一切可疑模式——源头克制型措辞（"只报你
确定的"）是漏报机器；置信过滤放 verdict 层——低置信也报、标 confidence(0-1)，由证据档杀假阳：
所有 finding 须 file:line 引用（禁从命名推断行为），blocker/major 须探针/失败测试**执行复现**
（业界评审产品的验证层同构：候选先泛报、再独立复现过滤）。出口是**双面闸**：晋级须复现，**删除须
证伪**——不能复现只降档不删；要删一条 finding 必须指出 diff/代码里直接反驳它的证据，「仅仅无法验证」
不构成删除理由（防 verifier 变成第二个噪声源；大规模评审产品的 filter pass 同款 veto 措辞）。

**点名最易翻车的轴**（让 codex 主动写探针复现，命中率远高于泛泛 review）：

**缺失消费者轴（absence review，diff 评审的结构性盲区）**<!-- trunk:缺失消费者 -->：被评审改动若新增/变更一种**能力或
运行时语义**（新端点、token/会话寿命、重试契约、降级开关），必须问"**谁必须消费/适配它？
它们现在消费了吗？**"——缺失的调用方不存在于任何 diff 里，按 diff 划界的评审永远看不见。
brief 里点名这条轴时给评审者消费者清单的检索起点（前端仓路径/
调用点 grep 词）。
崩溃恢复、并发竞态、旗标关路径零泄漏、降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏（异常链/URL
userinfo/日志）；评测报告类加**指标诚实性**（指标虚高/证据越界泛化）。

**LLM 产出进入结构化管道的接缝轴**：凡"生成内容被当数据消费"的地方（提取结果落库、合成答案进解析器、
引用标记进溯源链），评审必须验证：①有无内容契约（拒收 PII/秘密/编造）；②有无溯源校验（引用/ID 必须能
对回真实来源集，幻觉条目剥除而非放行）；③测试 fixture 里要有"恶意/幻觉样本"且无防护时必红。

**评审前先枚举执行路径分叉**（provider / mode、live vs rehydrate、suggestion-flow vs direct-save…），点
codex 核"还有哪些分支没走到"——只覆盖一条分支 ≠ 全覆盖（真实用户可能走另一条独立分支，
整条功能被绕过仍全绿）。

**门控/触发型功能必查 under-fire（"该触发时触发了没"），不只 over-fire**：有触发条件的特性（正则/旗标/阈值
门控）评审天然盯"会不会误触发"，常漏"真实输入下到底触发没"——触发器检测的输入若在上游已被
改写（如指代被抽取替换），真实场景永不触发，只有真输入验才能看见。

**架构符合性轴（仓库声明了方向文档时必挂）**：若目标仓（或其伞仓）声明了北极星 / constitution /
ADR 类方向文档，brief 里给出其绝对路径，并要求评审者：①对照改动逐条检查是否触碰任何带 ID 的原则
（引用原则 ID，如 `NS-3`），tripwire 清单是现成的检查表；②改动若新增结构性约束（gate/lint/门禁），
反向验证约束真咬得动——"绿因为零覆盖"（规则空转、pattern 不匹配、检查器没跑）是 blocking 级 finding；
③方向文档与 accepted ADR 冲突时不择边，报编排者升级主理人。没有方向文档的仓跳过本轴，不造假锚点。

### 轴装配先查表（path→轴映射表）<!-- trunk:轴映射表 -->

轴选择不能全靠编排者临场判断——判断会疲劳、会漏、跨席位不一致。业界大规模评审产品同构：规则按
文件路径 glob 确定性匹配、命中即注入 prompt，问题从「记不记得点轴」收敛为「表全不全」。装配规则：
**表命中的轴必进 brief，判断只做增补、不做删减**；多条命中全注入（轴取并集，不是 first-match）。
默认表（领域通用）：

| diff 路径命中 | 必注入的轴 |
|---|---|
| hook / guard 脚本（PreToolUse 类拦截器） | hook 语义：DENY 三件套完整、误拦/漏拦双向探针、宿主契约真送达（合成测试 ≠ 真 wire） |
| 可执行入口（bin / CLI / *.sh） | 信号与并发语义、退出码契约、cwd/引号/注入面 |
| migration / schema | 回滚路径、幂等、真实数据量级下的锁行为 |
| auth / session / token | 缺失消费者轴（必挂）+ 安全契约 + 过期/续期路径 |
| CI / workflow / 门禁配置 | 门禁真咬（"绿因为零覆盖" = blocking）、secret 暴露面 |
| prompt / LLM 管道文件 | LLM 接缝轴（内容契约 / 溯源 / 恶意样本 fixture） |
| 前端入口 / E2E | 执行路径分叉枚举 + under-fire |

**项目自带增量表**：各仓在自己的治理文档（AGENTS.md Review guidelines 节或 docs/orchestration/）
维护「本仓路径 → 轴」增量行，装配时默认表 ∪ 项目表。表是活的：每次评审漏轴的 post-mortem 落一行
新映射——同类漏轴从「下次记得」升为结构（skip rules 的对偶：那边沉淀"别再报"，这边沉淀"别再漏"）。

### ledger 结构 + 收敛准则

写 `docs/orchestration/<NAME>_REVIEW_codex.md`——severity 分级 findings + verdict，维护
`blocking / queued / advisory / pre-existing / 已修 / stagnation` 栏目逐轮更新，收敛状态一眼可判。
**pre-existing（存量 bug、非本 diff 引入）单列**：记录、开 follow-up，不进 blocking——治 scope 争议；
作者声明的"预存失败"必须让 codex 在干净 base 上复现验证后才准入此档。

**循环回修每轮重贴不可变目标**：request-changes → 派回 omp 修 → codex 复审，循环到 approve。每轮派回时把原
goal 的不可变验收点重贴进 prompt 对照——防多轮改着改着跑题。

- 质量类无限可挑的项（过滤规则、命名）明确"达标线"：线内必修、线外进 `queued`。例："确定性过滤是兜底、LLM
  prompt 是主闸；常见形态全覆盖即达标，冷僻算 minor"。
- 为一行 advisory fold-before-push 不值得——先 ship 已 Verified 的，nit 攒 follow-up。
- **裁决沉淀为 skip rules**：收口时把"已判 advisory / 越界 / 不值得报"的 finding **类别**回写项目 AGENTS.md
  的 Review guidelines 节（codex 官方评审通道原生读最近的 AGENTS.md 该节）——同类噪声下次从源头不进 ledger，
  "不复提已裁决"从单次记忆升为跨评审结构。
