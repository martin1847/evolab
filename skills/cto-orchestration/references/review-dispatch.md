# codex 评审派发模板（brief 文本）

> **固定样板单源** = `references/review-brief-preamble.md`（输出契约 / Tally 格式 / 只读纪律 /
> 直写合同要求）：每份 brief 首行写 `Read first: <该文件绝对路径>`，brief 本体只写本批
> scope、per-unit 合同与评审轴——样板不再逐份复制。

> 目录：[goal-review](#goal-review派发前白名单免评--其余必评) · [轮数预算](#轮数预算) · [首轮评审](#首轮评审) · [复审](#复审第-n-轮) ·
> [收敛准则注入](#收敛准则注入防乒乓第-3-轮左右仍未收敛时) · [修复派回模板](#修复派回-omp-模板) ·
> [评审轴](#评审轴主干-2-的展开)

> 首轮：brief 写成文件（`docs/orchestration/*_REVIEW_BRIEF.md`），
> `agentctl start codex <proj>-<task>-codex <同一worktree> --goal <brief.md> --review
> --deliverable <REVIEW_codex.md> --workflow review-loop --max-rounds <N>`——与 omp 派发同构
> （`--review` 进评审档、`--deliverable` 给产物 freshness gate，缺一即无 typed 交付）。
> 差分口径统一 **three-dot**（`origin/<base>...HEAD`，对 merge-base 差分）：stale base 的两点差分会把
> 他人 commit 的反向删除混进评审面、误判为回退；评审不因 base 移动而 rebase，rebase 归 push/merge 阶段。
> - [ ] 写 codex 评审 brief / steer → 用中性工程措辞，避 forged / impostor / attack / probe 类
>   攻击词汇（对象：投给引擎的 prompt 文本；安全型内容过滤只判 prompt，被读文件不进判定）。
> - [ ] codex 轮被 cyberPolicy 拦 → 重投前先净化 prompt：敏感细节移入被读文件、prompt 只留
>   中性指针；仍被拦 → 开新会话兜底（失败轮照常计入轮数预算）。
> - [ ] 变更集含编排位直写单元（教义 / 门 / guard）→ Context docs 附其最小合同（SKILL §2「直写也要合同」）。

## goal-review（派发前，白名单免评 + 其余必评）

> 免评白名单唯一正源在此；每条目共同硬门 = **不新增任何决策面**（判据 / 门 / 指标 /
> 停止规则 / 行为契约），任一新增即出白名单。派发前逐条判：
>
> - [ ] 纯只读取证类（只产出**数据 / 读数**，不下「该不该做 / 根因是什么」类判断）→ 免评
> - [ ] 调研 / 研究类产出**结论或裁决** → goal 本身仍免评（只读不写），但其 RESULT 是 scout
>   结论、不是判决：下游任何以它作 Value gate / 前提的 goal，须把该结论列进 goal-template
>   §Premises 逐条独立验证——改一行代码要过冷评审，「要不要改」的判断不得零检验直通派工
> - [ ] 轻档 goal（不新增判据 / 门 / 状态 / 接口 / 解析面：纯删、纯搬迁、有参考实现；判档在 SKILL §2）→ 免 goal-review，但仍过 1 轮冷评审或编排位抽查
> - [ ] 其余——含一切带写动作的 goal，哪怕看着机械（门禁 / 量具类必评：改断言即改判据）→
>   1 轮冷上下文 goal-review（异构模型，只读 goal 文本，不喂实现语境）；歧义即 fail-closed

问块按 goal 命中的面选用，任一问不过即 blocking，修 goal 再派；goal 带 Preflight 声明时
评审须**复跑探针**、不采信贴出值（预计算结果会诱导评审不复跑）；命中仪器面时该轮还须产出
**承诺面变异清单**（异源出题，实现者逐条做到红——判据见仪器第 5 问）；命中测量面
（Done-when 含对比 / 命中率 / 基准类判定）时，该轮同时按 `measurement-protocol.md` 七条款
逐条复核、任一条款缺失即 blocking——量具自身可信度仍归仪器六问，不重判：

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

## 轮数预算

初轮计入总轮数；stop-loss 只认 runtime meta（duplex 会话档），GOAL/brief 不复制轮数。到限后 send 返回
`BUDGET-EXHAUSTED`（exit 9），不得绕过，转人工裁决。定 `--max-rounds` 时：催写 nudge 也走 steer 计轮——
预算 = 内容轮 + 1（max-rounds 1 遇 idle 即死局；上限不是燃料，slack 轮用不到零成本）。
**深档 / 轻档由 SKILL §2 两档规则定**：深档保留 blocking 驱动续轮；轻档恒一轮（`--max-rounds 1`），
findings 回编排位裁 fix / accept-documented，机器可验修复即收，轮数耗尽转 owner 裁决。
裸 `codex review` 子命令由 guard ⑩ 拦，一律走 lane。

## 首轮评审

> 输出契约 / 证据档 / severity 与 PRE-EXISTING 口径 / 只读纪律**全在 preamble，模板不复制**。

```
Read first: <review-brief-preamble.md 绝对路径>（常驻合同）。
独立代码评审。评审集 = `origin/<base>...HEAD`（three-dot = merge-base 差分；commits <sha…>），
分支 <branch>，worktree <server root>。Context docs（先读）：<goal.md>、<findings.md>（同目录）。
评审焦点：(1) <该变更最危险的轴，点名：旗标关路径零行为泄漏 / 崩溃恢复 / 并发竞态 /
降级语义 / 安全契约>；(2) <次轴>；(3) 测试充分性；(4) scope 纪律 vs goal guardrails；
(5) <作者声明的可疑点，要求独立验证>。
跳过：生成代码 / lockfile / CI 已强制项 / <项目排除面>。
评审写到 <REVIEW_codex.md 绝对路径>（`--review` 档下必须在 session cwd 内）。
```

## 复审（第 N 轮）

```
第 <N> 轮复审：commit <sha> 回应了你的 findings——<逐条一句话>。
逐条核真闭合——尤其 <上轮 HIGH 修复自身的新风险>，并确认没有夹带改动。
把 "Round <N>" verdict 追加到 <REVIEW_codex.md>，Tally 口径同 preamble。只读。
```

- [ ] review-loop 续派任何一轮前 → 先过**杠杆线分诊**：①逐轮新增 blocking 计数衰减（内容轮 ≥3 且
  最近两轮不升、各 ≤1）②本轮 remedy 撤销上轮 remedy 引入的行 ③同一「评审轴 + 路径簇」连续 ≥3 轮
  出 finding——任一命中 → 本轮不续派，转编排者杠杆账（SKILL §2）；裁定续派 = 显式追加预算并在 ledger 记账。
- [ ] 评审 closure-requirement 要求新增/扩大守卫机械（断言 / 变异样本 / manifest / 自证层）→
  **默认 advisory 不得 blocking**；升 blocking 须编排位显式裁定并记账（防评审棘轮把合同逐轮加码）。
- **复审轮只审封闭性**（上轮 finding 是否真闭 + 修复引入的新洞 + 无夹带改动），别让同一会话重扫全量——
  要全新全面评审就起 fresh session。

## 收敛准则注入（防乒乓，第 3 轮左右仍未收敛时）

```
收敛准则（来自编排位，同时写进 findings 文档）：
<兜底机制> 是尽力兜底——<主闸机制> 才是主闸。本轮之后达标线 = 所有常见 <X> 有测试覆盖；
更冷僻的缺口是 minor follow-up，不是 ship blocker。
```

## 修复派回 omp 模板

```
codex 第 <N> 轮：request-changes——读 <REVIEW_codex.md>，在本分支一个后续 commit 里
处理全部 findings：[<severity>] <一句话> — <修复方向，含「镜像 <同场景既有路径> 的
既有行为」类对齐要求>；… 加测试：<修复前必须红的回归测试>。复跑测试套、commit、
把变更说明追加进 findings 文档。
```

修复涉及**资源界限 / 生命周期**（锁、超时、marker、句柄）时，模板必须加一句：先枚举**全部**够得到
该资源的路径再动手（SKILL §3「病类确认后枚举同模式点」的修复态 fire 点）。

## 评审轴（主干 §2 的展开）

SKILL §2 已定：brief 冷上下文、不喂实现者结论（喂了 = anchoring，异构去相关白费）；激进找、
出口滤（源头克制型措辞是漏报机器；置信过滤放 verdict 层，规则归 preamble）。这里只留轴的枚举与装配表。

**缺失消费者轴（absence review，diff 评审的结构性盲区）**<!-- trunk:缺失消费者 -->：被评审改动若新增/变更一种**能力或
运行时语义**（新端点、token/会话寿命、重试契约、降级开关），必须问"**谁必须消费/适配它？
它们现在消费了吗？**"——缺失的调用方不存在于任何 diff 里，按 diff 划界的评审永远看不见。
brief 里点名这条轴时给评审者消费者清单的检索起点（前端仓路径 / 调用点 grep 词）。
崩溃恢复、并发竞态、旗标关路径零泄漏、降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏（异常链/URL
userinfo/日志）；评测报告类加**指标诚实性**（指标虚高/证据越界泛化）。

**LLM 产出进入结构化管道的接缝轴**：凡"生成内容被当数据消费"的地方（提取结果落库、合成答案进解析器、
引用标记进溯源链），评审必须验证：①有无内容契约（拒收 PII/秘密/编造）；②有无溯源校验（引用/ID 必须能
对回真实来源集，幻觉条目剥除而非放行）；③测试 fixture 里要有"恶意/幻觉样本"且无防护时必红。

**执行路径分叉**（provider / mode、live vs rehydrate、suggestion-flow vs direct-save…）：先枚举，
点评审者核"还有哪些分支没走到"——只覆盖一条分支 ≠ 全覆盖。

**门控/触发型功能必查 under-fire（"该触发时触发了没"），不只 over-fire**：触发器检测的输入若在上游已被
改写（如指代被抽取替换），真实场景永不触发，只有真输入验才能看见。

**架构符合性轴（仓库声明了方向文档时必挂）**：若目标仓（或其伞仓）声明了北极星 / constitution /
ADR 类方向文档，brief 里给出其绝对路径，并要求评审者：①对照改动逐条检查是否触碰任何带 ID 的原则
（引用原则 ID，如 `NS-3`）；②改动若新增结构性约束（gate/lint/门禁），反向验证约束真咬得动——
"绿因为零覆盖"是 blocking 级 finding；③方向文档与 accepted ADR 冲突时不择边，报编排者升级主理人。
没有方向文档的仓跳过本轴，不造假锚点。

### 轴装配先查表（path→轴映射表）<!-- trunk:轴映射表 -->

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
维护「本仓路径 → 轴」增量行，装配时默认表 ∪ 项目表。每次评审漏轴的 post-mortem 落一行新映射。

### ledger 结构 + 收敛准则

写 `docs/orchestration/<NAME>_REVIEW_codex.md`——severity 分级 findings + verdict，维护
`blocking / queued / advisory / pre-existing / 已修 / stagnation` 栏目逐轮更新。
**pre-existing（存量 bug、非本 diff 引入）单列**：记录、开 follow-up，不进 blocking；准入口径归 preamble。
每轮派回时把原 goal 的不可变验收点重贴进 prompt 对照——防多轮改着改着跑题。

- 质量类无限可挑的项（过滤规则、命名）明确"达标线"：线内必修、线外进 `queued`。
- 为一行 advisory fold-before-push 不值得——先 ship 已 Verified 的，nit 攒 follow-up。
- **裁决沉淀为 skip rules**：收口时把"已判 advisory / 越界 / 不值得报"的 finding **类别**回写项目 AGENTS.md
  的 Review guidelines 节（codex 官方评审通道原生读该节）——同类噪声下次从源头不进 ledger。
