---
name: cto-orchestration
version: 1.4.1
description: "CTO/orchestrator 模式管理多 agent 开发：本人不写产品代码，通过 tmux send-keys 派发 omp（执行）+ codex（评审）混合开发，goal 文档驱动、watcher 监控、对抗式评审循环、旗标门控、运维 agent 间接取证。适用于用户要求'你做 CTO/编排者'、'派 omp/codex 去做'、'goal 模式派发'、管理多会话并行开发、或在新项目复制此 CTO 工作流时。【定位】循环式日常编排运营；新项目先跑一次性的 repo-governance-bootstrap 建治理骨架，再用本 skill 派工——两者分工：bootstrap 建结构、本 skill 跑循环。不要用于：单 agent 一次性小任务、不需要多 agent 评审循环的改动、纯文档/治理初始化（用 repo-governance-bootstrap）。"
metadata:
  requires:
    bins: ["tmux", "omp", "codex"]
---

# CTO Orchestration — 多 agent 混合开发编排

> **定位**：本 skill 是编排内核（领域无关九条铁律，见同仓 `orchestrator-core`）的**写码领域皮**——
> 切分轴/契约/合并/分形等判据的论证在内核，本文只写写码域的角色表、操作协议与实证；
> 单独安装本 skill 亦自包含可用（下面三铁律即内核判据的写码浓缩）。
>
> 核心铁律：**编排者本人绝不写产品代码**——再小的改动也派给执行 agent。编排者的产出是
> goal 文档、监控、评审调度、决策、状态落盘。来源：多 agent CTO 实战沉淀（2026-06 起）。
>
> 第二铁律：**执行前先验证、不明先问。** 做不可逆/对外动作（push / merge / 部署 / 删除 / 对外消息）前，
> 先**核实真实事实与当前状态**（实读 state，别凭假设——本地 ref 会骗你），范围或授权不清就**先问清再做**；
> **一次批准不自动延伸到另一个动作**。可逆只读动作直接做、不请示。
> 实证：把用户的 "push" 当成含 "merge" 去合共享分支被拦。
>
> 第三铁律（第二铁律的操作化）：**把"降低主理人认知负载"当设计目标**——不是每事问，是把"该谁决"
> 事先设计掉，让主理人只决承重的、永不必记。机制见 §9。

## 0. 角色分工（按能力定义，工具可换）

方法论只依赖这几个能力、不绑具体工具（**含编排者本身**）；下文点名的 omp/codex/tmux（含"你=Claude Code"口吻）都是参考实现，换栈照此替换。

| 角色 | 干什么 / 不干什么 | 参考实现（可换） |
|---|---|---|
| **编排者**（你/CTO） | 写 goal/取证提示词、派工、**起 watcher 取终态裁决**、转述评审、汇报、memory/docs 落盘、任务系统操作 + 定时/轮询兜底；**绝不写产品代码、不自己跑长 E2E·批量验证**（收工独立复跑 test+lint 不算，见 §1.6） | **后台型**(读交付终态)/**阻塞型**(同步读 exit code)；任何 shell+文件 agent 均可、三者实跑验证（消费路径细节见 `references/agent-watch/README.md`） |
| 执行 agent | 吃 goal 实现 + 自测 + E2E + findings；不做超 goal scope 改动。须交互可 steering + 忙碌信号 + 存活信号 | omp / Claude Code / aider… |
| 评审 agent | 只读对抗式评审（review）、severity + verdict；不改码/commit。须**异构**（与执行不同 lineage） | codex / 另一家强模型 |
| 运维 agent | 够不着的环境(prod/独立 dev DB)只读取证 + 部署后验证；不修复/改配置 | 用户转交提示词 |
| 派发载体 | 发指令进、抓屏出的交互会话 | tmux / 其他复用器 |
| watcher | 轮询"存活+忙碌+等输入"返 typed 状态 | `references/agent-watch/`（dispatch/watch/teardown + hook；hook 主信号）|

- **默认 omp 执行、codex 评审，不倒置**——omp(oh-my-pi+Opus)强在自主执行、codex(gpt)强在严苛评审，交叉评审屡抓双方都漏的真问题。
- **三条派工 lane，按任务选**：① **tmux TUI lane** = 需要轮内实时交互 / 即时 steering / 菜单或 pane
  现场的核心开发与对抗评审（`dispatch send` 引导、watcher 取终态、会话持久）；② **headless lane**
  （`DISPATCH_EXEC=1`——命令面与 TUI 完全同面，只多这个开关；实现 = `dispatch-exec`）=
  单轮自包含、轮内不交互，后续轮仍可用 `send` resume；tmux 只作 supervisor，
  终态只认 `dispatch status` / `watch` 的 typed status；
  文件产出必须声明 `--deliverable` 加 fresh deliverable 门，非文件结果不带；
  ③ **Agent-工具 subagent** = 需要浏览器 / MCP / 隔离主上下文的读密集一次性工作（大快照留在子上下文、
  直接返结论）。需要轮内 steering 的工作走 TUI lane；要浏览器/MCP 的验收别塞给 tmux agent。
  **派 subagent 显式指定 model 按活分档**（重推理强模型 / 机械·轻量弱模型）——默认继承主会话模型
  常让机械活烧强模型；fork 例外（永远继承）。
- **编排者本身也可换**（codex/任何 shell+文件 agent 都能坐 CTO 位）；watcher 起法/忙碌·存活信号按你的工具校准，`requires.bins` 是参考栈、非硬依赖。
- **多个编排者并行**（各管一摊）时，跨席位异步通信用可选伴随 skill `agent-mail`。

## 1. 派工协议（每次走全流程）

1. **基线纪律**：派工前 `git fetch` + 基于最新远端目标分支开 worktree，**不让 agent 在过期基线开工**。
   三条判据：① rebase 是条件动作非仪式——base 没动 → 什么都不做；② 集成默认 squash、merge-commit
   弃用；③ **只读 scout/audit/Explore 经 Agent 工具派出会静默继承编排者 cwd**（落后的主 checkout）→
   幻影发现，须显式指 worktree + 对 base ref 复核。命令全串 / 三分支判定 / scout 70-commit 实证见
   `references/dispatch-baseline.md`；权威 git 细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard`）。
2. **写 goal**（模板 `references/goal-template.md`，放 `docs/orchestration/<NAME>_GOAL.md`）：含
   上下文+前置研究、带 file:line 的预判（标"verify, don't trust"）、交付物、验证要求（每条 Done-when
   绑定证明命令）、guardrails（scope + out-of-scope 枚举 / 存疑协议 / stop-and-report / redaction /
   commit-local-no-push）。若依赖 upstream audit/scout，必须填写模板的 Premises 段逐条验证承重 claim。
   **粒度判据**：一个 goal = 自包含单元 + 一个清晰交付物——太小则协调开销
   吃掉收益，太大则长跑无 check-in、漂移风险随时长涨。
3. **派发 = 融合一条命令 + 验 hook（硬 gate）+ 理解门**：首选
   `references/agent-watch/dispatch <agent> <session> <cwd> --goal <goal文件>`（Bash 工具
   `run_in_background:true` 调一次）——内建 launch→送 goal→验 hook→**自动 watch**，最高频的漏挂
   watch 从设计上无处发生（无独立 `--watch`，论证见 `dispatch` 头注）。**起后立刻 Read 输出按三档判定**：
   `hook: WORKING ✓` / `pane is BUSY`（codex 首个 tool 前正常）可继续；`NO sentinel…pane not busy` =
   goal 没送达 → **停下重起、别带病跑**（手动 send-keys 仅逃生舱，坑枚举见 agent-watch README）。
   **codex 评审首轮同构**：brief 写成文件、同样 `--goal <brief.md>` 一条命令。**理解门按 lane**：TUI
   核对 agent 复述的"碰哪些文件/契约、风险、scope"再放行；headless 由 runtime footer 要求简短复述后
   直接开工、不等待，真阻塞写 cwd 的 `BLOCKED.md` 并停止。
4. **watcher 纪律**（typed 状态全枚举 + 各失败态机制/实证全文见 `references/agent-watch/README.md`）：
   - **typed 状态 0-7 存在：DEAD≠DONE、WAITING 要回输入、WATCH-TIMEOUT≠DONE**——别把 idle / watcher 裁决当终态。
   - **判完成要正向证据**（本地 commit / 产物计数 / review 标记），自己 capture-pane 核证；产出=文件的
     任务派发时直接 `--deliverable <glob>`——glob 未命中不认 DONE、超时 exit 6 = 幻影 DONE 去 poke
     （turn_end ≠ 任务终态，实证单日 4 次假 DONE）。
   - **纯事件驱动会盲等**：按预期时长 ×2 设 fallback 自检（`ScheduleWakeup`/cron），到点无终态主动
     capture-pane——治 WORKING 卡死/热重试的**永不 DONE**（与**假 DONE** 是两个失败态）。浏览器/E2E
     subagent 完成通知会黑洞 → 派发即配 deadline 正向证据 watch；watcher 被宿主批量收割（"was stopped"
     通知）→ 跑 `rearm` 照单重挂。
   - **后台启动一律不加 shell `&`**（已 detached 再加 = 孤儿）；唯一后台正路 = Bash 工具 `run_in_background`。
   - **强制层（结构不靠自律）**：高频坑已由两 guard 脚本代码化 DENY（背景 `&` / 裸 idle 轮询 / CJK 裸
     send-keys / chrome-devtools 浏览器派发 / 误杀活 agent）——被拦读 deny 文案照做；DENY 全枚举 +
     override + wiring 见 `guard-hooks.json`（entry 真源）+ 该目录 README §Wiring。
5. **steering / 放行 / 回修**：一律 `references/agent-watch/dispatch send <session> -m "…"`（或 `-f <file>`），
   以**确认环收尾——会话真转 WORKING 才算送达**，别假设 send-keys 成功=已送达（裸 send-keys 长中文/全角
   已被 guard DENY）。复审轮 send 后单独 `watch`（必 run_in_background）。收工 `teardown`。
6. **收工核证 Implemented→Verified**：watcher 测的是 idle、agent 自报的是 "done"——**都只算
   Implemented**（别让交付状态由执行者自报）。升 **Verified** = ①核证四件套（git status / git log /
   复跑 test+lint / grep 计数，见 `references/dispatch-baseline.md`）+ ②异构 codex 独立确认（执行者
   再严的自审仍是同 lineage = self-preference bias）+ ③**本机真实路径 E2E 过**。
   **roadmap / ACTIVE_CONTEXT / 关单只认 Verified。**
   - **验证顺序门（不可跳级）**：本机真实路径 E2E（前端 = 浏览器真点真渲染，§7；后端 = curl 模拟真路径，
     尤其 SSE）→ ops 部署 → 部署环境 E2E → **最后才改任务状态**。**单测 + codex ≠ 本机 E2E**——结构
     测试是「结构防火墙」、不证真路径成立（实证：73 测试全过 + approve，codex 自标"未跑 live DB 锁复现"）。
   - push 时硬 gate 归你的 Git 协作规范（`git-workflow-standard`）+ 服务端分支保护，不塞 cto-guard。

## 2. 对抗式评审循环

**先按风险定评审深度**：低风险走轻量 `codex review --base`；高风险（鉴权/迁移/基建/大重构）走完整
对抗循环——codex 无内置"对抗"档，对抗在 prompt 层，**必须自起会话自控 prompt、别用子命令**。
完整模板 + 轴全枚举 + 实证 + ledger 栏目 + 达标线见 `references/review-dispatch.md`。判据：

- **brief 冷上下文、不夹带自己的结论**（喂评审者我的判断 = anchoring，换模型却共享推理链 = 异构去相关价值白费）。
- **激进找、出口滤**：brief 鼓励评审者查一切可疑、别写"只报确定的"（源头克制 = 漏报机器）；过滤放
  verdict 层——finding 须 file:line 证据 + confidence 标注，blocker/major 须探针/失败测试执行复现。
- **点名最易翻车的轴**（崩溃恢复/并发/旗标关路径/降级/安全契约/多租户隔离/指标诚实性/**缺失消费者**
  〔absence review：新能力谁必须消费？现在消费了吗？——缺失的调用方不在任何 diff 里〕），让 codex 主动写探针。
- **评审前枚举执行路径分叉**（provider/mode、live vs rehydrate…），点名核"还有哪些分支没走到"；
  **门控/触发型功能必查 under-fire（该触发时触发了没），不只 over-fire**。
- **ledger 结构、不纯追加**（blocking/queued/advisory/**pre-existing 存量单列、记录不阻塞**/已修/stagnation
  逐轮更新）；每轮回修重贴原 goal 不可变验收点。
- **分类收敛**：只有 `blocking` 残留才继续循环；**advisory→follow-up，别挡已就绪的 push**；不重复
  raise 已判过的（收口把已裁决类别沉淀为项目 AGENTS.md 的 Review guidelines/skip rules）；同一 finding
  反复出现 = stagnation，收敛或升级人介入，别无限对轰。
- **评审期 omp 别动同一 worktree**（codex 在内跑测试会污染结论）。

## 3. 变更纪律

- **旗标门控**：行为变更默认藏 env flag 后，默认 OFF = 字节级零变化；例外：ReOpen 批准的修复可默认
  ON（goal 写明理由）。性能/实验类一律 OFF。
- **measure-before-more / 先量再断**：第一刀砍下后绑定约束会换人——先实测再下第二刀。修 bug 动手前
  验证 ① bug **当前态真能复现**、② 观测值真被怀疑的机制约束（观测 5 < 上限 10 ⇒ 上限不是约束）、
  ③ 执行**真到了**你怀疑的代码（读代码只找候选，"执行到这"要日志/trace 证）。**绑定约束未证时，先派
  埋点 + 复测、不发投机修复**（实证：读代码三轮推断一个不存在的"挂死"、每轮被真数据打回）。常见伪
  bug：查错数据源（空表当真表 / 错日志串 / 错 session）、**"没收到"(客户端) ≠ "没发出"(服务端)**。
- **病类确认 → 立即系统性枚举全部同模式点**：root-cause 确认为"类"（如"持事务跨 async"）后，当场枚举
  代码里所有同模式点、逐一分类（安全/持有嫌疑）成表、一轮修完——别修眼前一处等下轮再显形一处
  （实证：idle-txn 5 轮逐个显形逐个修，第 1 轮就枚举可收敛成 ~2 轮）。
- **验证诚实**：交付三段式——验证了什么（真跑过）/ 没验证什么 / 剩余风险。本地打桩绕过的环节（真
  LLM、真队列）显式标注，部署后运维补验（实证：本地 LLM 打桩致 un-awaited coroutine 逃逸生产）。
- **代验路径 ≠ 真路径**：mock / 打桩 / stream smoke 全绿 **≠ 真实路径成立**——按**真实部署路径**验收
  （前端实例见 §7）。最尖一条：**别 mock 你正在验证的那个边界**——stub 掉被测函数 = 测试零信息、恰好
  盖住 bug（实证：一天 4 个 bug 全过 review+单测，只有真应用 E2E 抓到）。
- **编辑前重读会变的文件**：rebase / 另一 agent 动过同一 worktree / 刚跑了改文件的 git 操作之后，
  in-context 视图已 stale——先重读再改。护栏报 `must be read first` 是在挡 stale edit，不是 bug；
  没护栏的工具会**静默覆盖**、更糟。别在读↔编辑间插改文件的命令。

## 4. 间接环境访问（运维 agent 模式）

够不着的环境（prod、独立 dev 运行时库）不要猜——写**自包含取证提示词**（模板
`references/ops-prompt-template.md`，放 `docs/orchestration/<NAME>_PROMPT.md`）让用户转交运维 agent。
要点（只读写死 / SQL 给全 / 预期读数+判定规则给全 / 回报格式给死 / 敏感只取元数据）见该模板。
判据：**运维回报优先级高于自己的推断**——现场与 HEAD 代码矛盾时，先怀疑构建漂移（部署的是旧版本），
再怀疑自己的控制流分析。

## 5. 状态落盘与节奏

- `docs/orchestration/` 是 SoT：`*_GOAL` / `*_FINDINGS|IMPL_omp` / `*_REVIEW_codex` / `*_PROMPT` /
  `*_RESULT`，命名带任务号、全 file:line 证据。**生命周期**：收口即挪 `archive/`（README 加索引行），
  live 只留在跑/在等的——文档只生不死 → live 与历史混杂（实证：某项目积 38 个才首清）。
- **信息四分工**：docs = 全 agent 共享状态快照（what/why）· `ACCESS.local.md` = 怎么连上+凭证（含密
  gitignored，见 repo-governance-bootstrap）· memory = 编排者私有教训 + 入口指针（每 workstream 一文件
  + 索引一行，"压缩/等外部输入"前必更新）· 短期草稿/进度 = context window 或 `/tmp`（随手可弃）。
  **memory 编排者私有，agent/新 session 只能读 docs**——只更 memory 不同步 docs = 共享治理层腐烂
  （实证：ACTIVE_CONTEXT 冻 4 天变废纸）。**写时纪律**：卸载边写边做，别囤到复盘再清；高频纪律配
  PostToolUse hook 兜底（模板见 repo-governance-bootstrap）。
- runtime evidence 推翻 audit/scout claim 时，同一轮回写源文档顶部 `REFUTED CLAIMS` 表
  （claim / evidence / pointer），不只记 queue / memory。
- **复盘仪式（事件触发：收口 / 压缩前 / 任何 ReOpen 后主动提议）是 CHECKLIST 不是即兴**：听到"复盘 /
  收口 / handoff" → **读 `references/retrospective.md` 七步逐条勾**（即兴版必静默漏承重治理步，实证漏
  roadmap 翻状态 + ACTIVE_CONTEXT 重写）。**硬门**：跑 `bash references/retro-check.sh --base <branch>
  --docs <docs-dir> --memory <MEMORY.md>` 机械校验，未过不得宣布完成（只验机械代理，语义靠你）。
- **孤儿扫**：关交付完的会话（持关键上下文且挂起的保留）；扫 agent 起的孤儿——`docker ps` / `ps` /
  后台 job；临时 compose 用 trap/finally `down --remove-orphans`；repro 禁裸 `while True`（用有界
  循环/deadline，实证：死循环空转 2.5 天、65% CPU）。

## 6. 任务系统（外部任务追踪：Jira / Linear / 飞书 bitable 等）

- 用任务系统的 CLI / API 读写任务；状态机随项目定义（待处理/处理中/可测试/已完成/阻塞/ReOpen）。
- **关单标准**：修复 → E2E 验证 → 截图证据上传任务附件（验收人一眼对照）→ 一行结论 → 翻状态。
- ReOpen：先取证再修——上一轮"修好了"的机制可能根本不是绑定约束。
- **别在治理 docs 里养第二套任务账本**：外部系统是任务 SoT，roadmap 只是它的映射层。规则细节由
  `repo-governance-bootstrap` 的"外部任务系统优先"落地。

## 7. 前端 fix 验证（浏览器联调）

派完前端任务，**验收纪律：代码 review + 单测都不够，必须回浏览器看真实渲染；且 mock / SSE 帧 / 本地都过
≠ 真用户能看到——闭环要登已发布的真应用跑真实一轮 + 截图才算数**（`代验路径≠真路径` 的前端实例，通用原则
见 §3）。**E2E 是验收、不占编排者主上下文——委派 Playwright MCP 的子 agent**（§0「不自己跑长 E2E」的前端实例）。
完整方法论（MCP 主 CLI 补、a11y 优先、**状态形状矩阵**〔新鲜登录/过期会话/贫数据账号/未登录——只测
新鲜快乐态是结构性漏测〕、网络面板诊断联网 bug、CLI 抓 SSE、**交付闭环**、**E2E 委派子 agent**、
本地起服务坑入项目 `AGENTS.md`）见 `references/frontend-verify.md`。

## 8. 新项目接入清单

新项目接入 7 步（bootstrap 治理骨架 → AGENTS.md 编排两节 → wire 强制层 hooks → 建 orchestration 目录 →
首任务走 §1 全流程 → memory working-style 条目 → 建 DECISION_QUEUE）见 `references/onboarding-checklist.md`。

## 9. 主理人注意力与决策队列（降认知负载）

第三铁律的落地。**目标不是主理人少决，是只决承重的（战略/不可逆/钱/价值），每个给嚼过的选项，且永不必记。**
完整架构（三层各归其位 + 六件机制 + 强制层 + 模板）见 **`references/decision-queue.md`**；承重四条：

- **三档委派下沉权限层**（散文只定义语义，执行靠结构——permission rules enforced by harness, not by
  the model）：T0 直接做 = allow · T1 做了+记一行（可否决）= allow + hook 自动记账 · T2 动手前问 =
  ask/deny + guard（不可逆/对外、战略/钱/价值、真模糊）。减负 = 多往 T1 挪、少用 T2 当同步闸。
- **单一决策队列** `docs/DECISION_QUEUE.md` 只装人脑判断题：🔴需他/💤parked/✅已清（🟡在飞的事归
  ACTIVE_CONTEXT，别养第二份）。**完整性保证** = 唯一面、不另存、不静默丢（信任前提，否则 offload
  失效）；每 🔴 带推荐 + 静默默认 + revisit 触发。
- **静默默认**：主理人没回 → 可逆按写明默认前进、**不可逆一律 HOLD（永不自动越过不可逆）**。
- **新鲜度强制层**：`queue-freshness.py`（UserPromptSubmit hook，wiring 真源 `references/queue-hooks.json`，
  可选接入）——orchestration 活动比队列新即注入提醒；收口由 retro-check 硬门兜底。
