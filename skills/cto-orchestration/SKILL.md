---
name: cto-orchestration
version: 1.2.9
description: "CTO/orchestrator 模式管理多 agent 开发：本人不写产品代码，通过 tmux send-keys 派发 omp（执行）+ codex（评审）混合开发，goal 文档驱动、watcher 监控、对抗式评审循环、旗标门控、运维 agent 间接取证。适用于用户要求'你做 CTO/编排者'、'派 omp/codex 去做'、'goal 模式派发'、管理多会话并行开发、或在新项目复制此 CTO 工作流时。【定位】循环式日常编排运营；新项目先跑一次性的 repo-governance-bootstrap 建治理骨架，再用本 skill 派工——两者分工：bootstrap 建结构、本 skill 跑循环。不要用于：单 agent 一次性小任务、不需要多 agent 评审循环的改动、纯文档/治理初始化（用 repo-governance-bootstrap）。"
metadata:
  requires:
    bins: ["tmux", "omp", "codex"]
---

# CTO Orchestration — 多 agent 混合开发编排

> 核心铁律：**编排者本人绝不写产品代码**——再小的改动也派给执行 agent。编排者的产出是
> goal 文档、监控、评审调度、决策、状态落盘。来源：多 agent CTO 实战沉淀（2026-06 起）。
>
> 第二铁律：**执行前先验证、不明先问。** 做不可逆/对外动作（push / merge / 部署 / 删除 / 对外消息）前，
> 先**核实真实事实与当前状态**（实读 state，别凭假设/凭工具的一次输出——本地 ref 会骗你），范围或授权不清
> 就**先问清再做**；**一次批准不自动延伸到另一个动作**。可逆只读动作直接做、不请示。
> 实证：把用户的 "push" 当成含 "merge" 去合共享分支被拦。
>
> 第三铁律（第二铁律的操作化）：**把"降低主理人认知负载"当设计目标**——单一决策队列（编排者维护、
> 主理人只读、完整性保证）+ 三层委派（T0 直接做 / T1 做了记一行 / T2 动手前问）+ 静默默认（可逆前进、
> 不可逆 HOLD）+ 批处理升级包 + 心跳。不是每事问，是把"该谁决"事先设计掉，让主理人只决承重的、永不必记。**见 §9 + `references/decision-queue.md`。**

## 0. 角色分工（按能力定义，工具可换）

方法论只依赖这几个能力、不绑具体工具（**含编排者本身**）；下文点名的 omp/codex/tmux（含"你=Claude Code"口吻）都是参考实现，换栈照此替换。

| 角色 | 干什么 / 不干什么 | 参考实现（可换） |
|---|---|---|
| **编排者**（你/CTO） | 写 goal/取证提示词、派工、**起 watcher 取终态裁决**、转述评审、汇报、memory/docs 落盘、任务系统操作 + 定时/轮询兜底；**绝不写产品代码、不自己跑长 E2E·批量验证**（收工独立复跑 test+lint 不算，见 §1.6） | **后台型**(读交付终态)/**阻塞型**(同步读 exit code)；任何 shell+文件 agent 均可、三者实跑验证（消费路径细节见 `references/agent-watch/README.md`） |
| 执行 agent | 吃 goal 实现 + 自测 + E2E + findings；不做超 goal scope 改动。须交互可 steering + 忙碌信号 + 存活信号 | omp / Claude Code / aider… |
| 评审 agent | 只读对抗式评审（review）、severity + verdict；不改码/commit。须**异构**（与执行不同 lineage） | codex / 另一家强模型 |
| 运维 agent | 够不着的环境(prod/独立 dev DB)只读取证 + 部署后验证；不修复/改配置 | 用户转交提示词 |
| 派发载体 | 发指令进、抓屏出的交互会话 | tmux / 其他复用器 |
| watcher | 轮询"存活+忙碌+等输入"返 typed 状态 | `references/agent-watch/`（dispatch/watch/teardown + hook；hook 主信号、抓屏降级）|

**默认 omp 执行、codex 评审，不倒置**——omp(oh-my-pi+Opus)强在自主执行、codex(gpt)强在严苛评审，交叉评审屡抓双方都漏的真问题。
**两条派工载体，按任务选**：① **tmux omp/codex** = 实现 + 对抗评审 + 需 steering/多轮回修（可 `dispatch send` 引导、watcher 取终态、会话持久）——核心开发循环走这条；② **Agent-工具 subagent** = 浏览器 E2E / 研究 / 读密集一次性（能载我的 MCP 如 Playwright、大 a11y 快照隔离在子上下文外、直接返结论、无 tmux 开销）。别用 subagent 干需反复 steering 的实现活、也别用 tmux omp 干要 MCP 的浏览器验。**派 Agent-工具 subagent 必显式指定 model**（重推理 opus / 轻量 sonnet）——不设=继承主会话模型（不一定合适）；fork 例外（永远继承父模型）。
**编排者本身也可换**（codex/任何 shell+文件 agent 都能坐 CTO 位）；§1.4 的 watcher 起法/忙碌·存活信号按你的工具校准，`requires.bins` 的 tmux/omp/codex 是参考栈、非硬依赖。
**多个编排者并行**（各管一摊）时，跨席位异步通信用可选伴随 skill `agent-mail`（信箱总线、各自 inbox 单一去处）。

## 1. 派工协议（每次走全流程）

1. **基线纪律（fetch+检查，按需 rebase，集成用 squash）**：派工前 `git fetch` + 基于最新远端目标分支
   开 worktree，**不让 agent 在过期基线开工**。三条判据：① **rebase 是条件动作非仪式**——base 没动 →
   什么都不做、别空转；② **集成默认 squash、merge-commit 已弃用**；③ **只读 scout/audit/Explore 经 Agent
   工具派出会静默继承编排者 cwd**（落后的主 checkout）→ 幻影发现，须显式指 worktree + 对 base ref 复核。
   命令全串 / rebase 三分支判定 / squash 论证 / scout 70-commit 实证见 `references/dispatch-baseline.md`；
   权威 git 细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard`）。
2. **写 goal**（模板 `references/goal-template.md`，放 `docs/orchestration/<NAME>_GOAL.md`）：含
   上下文+前置研究、带 file:line 的预判（标"verify, don't trust"）、交付物、验证要求、guardrails
   （scope / stop-and-report / redaction / commit-local-no-push）。
3. **派发（用 `dispatch` 起）+ 验 hook（硬 gate）+ 理解门**：用 `references/agent-watch/dispatch` 起会话、
   send-keys 进 goal 路径（命令全串 + 坑：text/Enter 分发、`@` 补全、codex update 提示——见
   `references/agent-watch/README.md`）。**起后立刻验 hook**：`watch` 一挂就 Read，必须见 sentinel `WORKING`
   行；见 `no sentinel (hook not wired) → fallback` = 没走 dispatch / codex 未 trust hook → **停下重起、
   别带病跑**。**派发后、动手前先过理解门**：第一轮要 agent 复述"碰哪些文件/契约、有哪些风险"，核对无误
   再放行；弱答/跑偏当场纠正，别把沉默当默许。一句复述挡掉大半"误解 goal 就埋头改"。
4. **挂 watcher**（`references/agent-watch/`，**hook 主信号、抓屏降级**）：**首选融合 `dispatch <agent> <session> <cwd> --goal <goal文件>`
   一条命令用 Bash 工具 `run_in_background:true` 调一次**——内建 launch→送 goal(agent 转 WORKING)→验 hook→**自动 watch**，
   把"dispatch 后单独 send + 单独 `watch &`"三步收成一次调用，最高频的 `watch &` slip 从设计上无处发生（design > guard；
   无独立 `--watch` flag——goal 不 watch 无正当场景、watch 无 goal 是看一个空转 agent 立即退出，"必须与另一 flag 同用的 flag"
   本身就是 API 脚枪，源头删除）。派发后 Read 一次输出确认 `[send] OK…WORKING` + `hook: WORKING ✓`。
   codex 评审(需先送 brief 再多轮)或首启 codex 目录信任提示的场景，仍用两步(`dispatch` 起 → `dispatch send` brief → 单独 `watch`，**必 run_in_background 禁 `&`**)。收工 `teardown`。四条判据；机制全文 + typed 状态全枚举 +
   STALLED-EXTERNAL / 异步完成通知黑洞 / 正向证据两坑 / fallback 自检 / cto-guard 实证见该目录 README：
   - **typed 状态存在、DEAD≠DONE、WAITING 要回输入**（别把 idle / watcher 裁决当终态）。
   - **判完成要正向证据、不凭 idle / watcher 裁决**——tmux 链路无失败信号、watcher 裁决只是线索；把完成绑
     正向交付物（本地 commit／产物计数／review 标记），自己 capture-pane 核证（分阶段任务每个 part 边界都
     idle 一瞬——裸 idle 轮询已由 guard DENY，坑的全案见 README）。
   - **纯事件驱动会盲等 → 设超时上限兜底**：按预期时长 ×2 设 fallback 自检（`ScheduleWakeup`/cron），到点无终态
     主动 capture-pane——治 "WORKING 卡死/热重试" 的**永不 DONE**（与上条**假 DONE** 是两个失败态）。
     **浏览器/E2E subagent 完成通知会黑洞** → 派发即配 deadline 正向证据 watch（guard 在派发那刻注入全文提醒；
     活性判据=输出文件新鲜度、不是截图数，误杀防护=P0b，实证见 README）。
   - **后台启动一律不加 shell `&`**（已 detached，再加 = 双重后台 → 孤儿）；唯一后台正路 = Bash 工具 `run_in_background`。
   - **强制层（结构不靠自律——不 fire 的散文=净负债，见 memory `ineffective-prose-net-negative`）**：坑已代码化，
     wiring 见项目 `.claude/settings.json` + README §Wiring：
     - `cto-guard-bash.py`（PreToolUse·Bash）：DENY 背景 `&`（剥引号后任意单 `&`）· DENY 无正向 grep 的裸 idle 轮询 ·
       DENY 长/CJK 裸 send-keys（逼 dispatch send）· dispatch 未挂 watch 提醒。（push 时硬 gate 不在此，见 §1.6。）
     - `cto-guard-agent.py`（Pre+Post·Agent|Task|TaskStop）：DENY 浏览器派发用 chrome-devtools（逼 Playwright，P0a）·
       DENY TaskStop 杀"输出 120s 内还在长"的活 agent（P0b；override=`touch /tmp/cto-allow-kill-<id>`）· browser 派发注入黑洞提醒。
5. **steering / 放行（理解门后 + 回修 + 新指令）**：一律 `references/agent-watch/dispatch send <session> -m "…"`（或 `-f <file>`）
   交付，并以它的**确认环收尾——会话真转 `WORKING` 才算放行落地**，别假设 send-keys 成功=已送达。
   裸 send-keys 长中文/全角已由 guard DENY（弹窗吃 Enter 卡 24min 的机制与实证见 dispatch 头注 + guard 提示文本）。
6. **收工核证 + Implemented→Verified**：watcher 测的是 idle、agent 自报的是 "done"——**都只算
   Implemented，不是交付**（别让交付状态由执行者自报，§1.4 存活检测是同一主题）。升 **Verified** 仅当
   ①核证四件套过 + ②异构 codex 独立确认（执行者再严的自审仍是同 lineage = self-preference bias，不可信）
   + ③**本机真实路径 E2E 过**（下面的顺序门）；**roadmap / ACTIVE_CONTEXT / 关单只认 Verified**。核证四件套
   （git status / git log / 复跑 test+lint / grep 计数 + 实证）见 `references/dispatch-baseline.md`。
   - **验证顺序门（不可跳级）**：**本机真实路径 E2E 先** → ops 部署 → **部署环境 E2E** → **最后才改任务状态**。
     - 前端 = **浏览器本机 E2E**（localhost 前端 → 已部署后端，真点真输真渲染，§7）。
     - 后端 = **curl 模拟本机 E2E**（尤其 SSE；起本机栈跑真路径，不是 mock）。
     - **单测 + codex ≠ 本机 E2E**：结构测试是「结构防火墙」、不证真路径成立（实证：某并发锁功能 73 测试全过 +
       codex approve，但 codex 自己两轮标"未跑 live DB 锁复现"——拿结构证据顶 Verified = 超前）。
   - **顺序是编排纪律，push 硬 gate 不在 cto-guard**：本机 E2E→部署→部署环境 E2E→改任务状态 的**验证顺序**
     由编排者守（Verified 定义 + §6 关单）。**`git push`/PR 的 push 时硬 gate 归你的 Git 协作规范
     （evolab 公开镜像 `git-workflow-standard`）+ 服务端分支保护 ruleset**——git 策略不塞进 cto-guard（职责分清）。

## 2. 对抗式评审循环

**先按风险定评审深度**：低风险走轻量标准 review（`codex review --base`）、高风险（鉴权/迁移/基建/大重构）
走完整对抗循环。codex 无内置"对抗"档——对抗在 prompt 层（自起会话点名轴 + severity/verdict + 多轮收敛），
**必须自起会话自控 prompt、别用子命令**。完整模板 + 轴全枚举 + 实证 + ledger 栏目 + 达标线见
`references/review-dispatch.md`。判据：

- **brief 冷上下文、不夹带自己的结论**（喂 codex 我的判断 = anchoring，换模型却共享推理链 = 去相关价值白费）。
- **点名最易翻车的轴**（崩溃恢复/并发/旗标关路径/降级/安全契约/多租户隔离/指标诚实性），让 codex 主动写探针。
- **评审前先枚举执行路径分叉**（provider/mode、live vs rehydrate…），点 codex 核"还有哪些分支没走到"。
- **门控/触发型功能必查 under-fire（该触发时触发了没），不只 over-fire**。
- **评审记录用 ledger 结构、不纯追加**（blocking/queued/advisory/已修/stagnation 逐轮更新）；每轮回修重贴原 goal 不可变验收点。
- **三分类收敛**：只有 `blocking` 残留才继续循环；**advisory→follow-up，别挡已就绪的 push**；不重复 raise 已判过的。
- **stagnation 检测**：同一 finding 反复出现 = 卡住，该收敛或升级人介入，别无限对轰。
- **评审期 omp 别动同一 worktree**（codex 在内跑测试会污染结论）。

## 3. 变更纪律

- **旗标门控**：行为变更默认藏 env flag 后，默认 OFF = 字节级零变化；例外：ReOpen 批准的修复可默认
  ON（goal 写明理由）。性能/实验类一律 OFF。
- **measure-before-more / 先量再断**：第一刀砍下后绑定约束会换人——先实测再决定第二刀，别按推算连下多个
  lever。修 bug 同理，动手前验证 ① bug **当前态真能复现**、② 观测值真被某机制约束（观测 5 < 上限 10 ⇒ 上限
  不是约束）、③ 执行**真到了**你怀疑的代码（读代码只找候选，"执行到这"要日志/trace 证）。**绑定约束未证时，
  先派埋点 + 复测、不发投机修复**（实证：读代码三轮推断一个根本不存在的"挂死"、每轮被真数据打回）。常见
  伪 bug：查错了数据源（空表当真表 / 错日志串 / 错 session）、**"没收到"(客户端) ≠ "没发出"(服务端)**。
- **commit 留本地，push/PR 必须用户明示批准**；批准一次只覆盖那次。
- **验证诚实**：交付三段式——验证了什么（真跑过）/ 没验证什么 / 剩余风险。本地打桩绕过的环节（真
  LLM、真队列）显式标注，部署后运维补验。实证：本地 LLM 打桩致 un-awaited coroutine 逃逸生产。
- **代验路径 ≠ 真路径**（后端/agent/前端通用）：mock / 打桩 / stream smoke 全绿 **≠ 真实路径成立**——按
  **真实部署路径**验收，真路径常和你 mock 的那条不是同一条（前端实例见 §7）。最尖一条：**别 mock 你正在
  验证的那个边界**——stub 掉被测函数 = 测试零信息、恰好盖住 bug；真应用 E2E 才是「可测试」门（实证：一天
  4 个 bug 全过 review+单测，只它抓到）。
- **编辑前重读会变的文件**：rebase / 另一 agent 动过同一 worktree / 你刚跑了改文件的 git 操作 之后，
  in-context 文件视图已 stale——先重读再改。带 read-before-edit 护栏的工具会**拦** stale edit（报 `must be read
  first` 不是 bug、是它在挡你拿过期视图覆盖别人的改动）；没护栏的会**静默覆盖**、更糟。别在读↔编辑间插改文件的命令。

## 4. 间接环境访问（运维 agent 模式）

够不着的环境（prod、独立 dev 运行时库）不要猜——写**自包含取证提示词**（模板
`references/ops-prompt-template.md`，放 `docs/orchestration/<NAME>_PROMPT.md`）让用户转交运维 agent。
要点（只读写死 / SQL 给全 / 预期读数+判定规则给全 / 回报格式给死 / 敏感只取元数据）见该模板。
判据：**运维回报优先级高于自己的推断**——现场与 HEAD 代码矛盾时，先怀疑构建漂移（部署的是旧版本），
再怀疑自己的控制流分析。

## 5. 状态落盘与节奏

- `docs/orchestration/` 是 SoT：`*_GOAL` / `*_FINDINGS|IMPL_omp` / `*_REVIEW_codex` / `*_PROMPT` /
  `*_RESULT`，命名带任务号、全 file:line 证据。**生命周期**：收口即把文档挪进 `archive/`（README 加
  索引行），live 只留在跑/在等的；文档只生不死 → live 与历史混杂（实证：某项目积 38 个才首清）。
- memory：每 workstream 一文件 + 索引一行（状态/PR/敞口/下一步入口），"压缩/等外部输入"前必更新。
  **memory 编排者私有，agent/新 session 只能读 docs**——只更 memory 不同步 docs = 共享治理层腐烂
  （实证：某项目 ACTIVE_CONTEXT 冻 4 天变废纸）。**信息四分工**：docs=全 agent 共享状态快照（what/why）·
  `ACCESS.local.md`=怎么连上+凭证（含密 gitignored，见 repo-governance-bootstrap）· memory=编排者私有教训+入口指针 ·
  短期草稿/进度/待办=context window 或 `/tmp`（随手可弃，别塞 memory 或 ACTIVE_CONTEXT——那是收口快照非草稿）。
  - **写时纪律（不等复盘）**：卸载边写边做——写 memory 当下就把事实细节进 ACCESS/docs，别囤到复盘再清；
    高频纪律配 **PostToolUse hook** 兜底（强制层补 salience 衰减；模板见 repo-governance-bootstrap）。
- **复盘仪式（事件触发：收口 / 压缩前 / 任何 ReOpen 后主动提议）——是 CHECKLIST 不是即兴。**
  听到"复盘 / 收口 / handoff" → **读 `references/retrospective.md` 七步逐条勾**，别凭记忆即兴（即兴版读着完整却静默漏
  承重治理步——实证 2026-06-26：被要求"复盘仪式"却自由发挥，漏了 roadmap 翻状态 + ACTIVE_CONTEXT 整篇重写 + 上下文治理）。
  - **硬门（未过不得宣布完成）**：跑 `bash references/retro-check.sh --base <branch> --docs <docs-dir> --memory <MEMORY.md>`
    机械校验（已合分支无孤儿 worktree / ACTIVE_CONTEXT 今日重写 / roadmap 近期动 / MEMORY 未超行）；只验机械代理、语义靠你。
- **孤儿扫**：关交付完的会话（持关键上下文且挂起的保留）；扫 agent 起的孤儿——`docker ps` / `ps` /
  后台 job。临时 compose 用 trap/finally `down --remove-orphans`，repro 禁裸 `while True`（用有界
  循环/deadline）。实证：某 repro 死循环空转 2.5 天、65% CPU。

## 6. 任务系统（外部任务追踪：Jira / Linear / 飞书 bitable 等）

- 用任务系统的 CLI / API 读写任务；状态机随项目定义（待处理/处理中/可测试/已完成/阻塞/ReOpen）。
- **关单标准**：修复 → E2E 验证 → 截图证据上传任务附件（验收人一眼对照）→ 一行结论 → 翻状态。
- ReOpen：先取证再修——上一轮"修好了"的机制可能根本不是绑定约束。
- **别在治理 docs 里养第二套任务账本**：外部系统是任务 SoT，roadmap 只是它的映射层。规则细节（沿用
  外部 ID / 写明 SoT / 何时才造内部 RD 号）由 `repo-governance-bootstrap` 的"外部任务系统优先"落地。

## 7. 前端 fix 验证（浏览器联调）

派完前端任务，**验收纪律：代码 review + 单测都不够，必须回浏览器看真实渲染；且 mock / SSE 帧 / 本地都过
≠ 真用户能看到——闭环要登已发布的真应用跑真实一轮 + 截图才算数**（`代验路径≠真路径` 的前端实例，通用原则
见 §3）。**E2E 是验收、不占编排者主上下文——委派给带浏览器 MCP 的子 agent**（§0「不自己跑长 E2E」的前端实例）。
完整方法论（MCP 主 CLI 补、a11y 优先、网络面板诊断联网 bug、CLI 抓 SSE、**交付闭环**、**E2E 委派子 agent**、
本地起服务坑入项目 `AGENTS.md`）见 `references/frontend-verify.md`。

## 8. 新项目接入清单

新项目接入 7 步（bootstrap 治理骨架 → AGENTS.md 编排两节 → wire 强制层 hooks → 建 orchestration 目录 →
首任务走 §1 全流程 → memory working-style 条目 → 建 DECISION_QUEUE）见 `references/onboarding-checklist.md`。

## 9. 主理人注意力与决策队列（降认知负载）

第三铁律的落地。**目标不是主理人少决，是只决承重的（战略/不可逆/钱/价值），每个给嚼过的选项，且永不必记。**
完整方法论（七件机制 + 委派板 + 失败模式 + 出处诚实标注 + copy-paste 模板）见 **`references/decision-queue.md`**。
本节只留承重要点：

- **单一决策队列** `docs/DECISION_QUEUE.md`：编排者维护、主理人只读。🔴需他/🟡我驱动/💤parked/✅已清。
  **完整性保证**=唯一面、不另存、不静默丢（信任前提，否则 offload 失效）。每 🔴 带推荐+静默默认+revisit 触发。
- **三层委派**：T0 直接做（可逆/已授权/无价值判断）· T1 做了+记一行（可逆但值得知会、可否决）· T2 动手前问
  （不可逆/对外、战略/优先级/钱/价值、有实质下行的真模糊）。减负=多往 T1 挪、少用 T2 当同步闸。
- **静默默认**：主理人没回 → 可逆按写明默认前进、**不可逆一律 HOLD（永不自动越过不可逆）**。
- 其余机制（聚合绊线 / 批处理升级包 / 心跳 / HELD revisit / 队列腐烂兜底 / 三层治理勿混）见 `references/decision-queue.md`。
