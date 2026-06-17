---
name: cto-orchestration
version: 1.0.3
description: "CTO/orchestrator 模式管理多 agent 开发：本人不写产品代码，通过 tmux send-keys 派发 omp（执行）+ codex（评审）混合开发，goal 文档驱动、watcher 监控、对抗式评审循环、旗标门控、运维 agent 间接取证。适用于用户要求'你做 CTO/编排者'、'派 omp/codex 去做'、'goal 模式派发'、管理多会话并行开发、或在新项目复制此 CTO 工作流时。【定位】循环式日常编排运营；新项目先跑一次性的 repo-governance-bootstrap 建治理骨架，再用本 skill 派工——两者分工：bootstrap 建结构、本 skill 跑循环。不要用于：单 agent 一次性小任务、不需要多 agent 评审循环的改动、纯文档/治理初始化（用 repo-governance-bootstrap）。"
metadata:
  requires:
    bins: ["tmux", "omp", "codex"]
---

# CTO Orchestration — 多 agent 混合开发编排

> 核心铁律：**编排者本人绝不写产品代码**——再小的改动也派给执行 agent。编排者的产出是
> goal 文档、监控、评审调度、决策、状态落盘。来源：多 agent CTO 实战沉淀（2026-06 起）。

## 0. 角色分工

| 角色 | 谁 | 干什么 | 不干什么 |
|---|---|---|---|
| 编排者（你） | Claude Code 主会话 | 写 goal/取证提示词、派工、watcher 监控、转述评审、向用户汇报、memory/docs 落盘、任务系统操作 | 写产品代码、自己跑长 E2E/批量验证（收工的独立复跑 test+lint 不算，见 §1.6） |
| 执行者 | omp（tmux 会话） | 按 goal 实现 + 自测 + E2E + findings 文档 | 超出 goal scope 的改动 |
| 评审者 | codex（tmux 会话） | 只读对抗式评审，severity 分级 + verdict | 改代码、commit |
| 运维 agent | 用户转交提示词 | 够不着的环境（prod/独立 dev DB）只读取证与部署后验证 | 修复、配置变更 |

实证：omp（oh-my-pi+Opus）强在自主执行，codex（gpt）强在严苛评审，交叉评审屡次抓到双方都漏的
真问题。默认 omp 执行、codex 评审，不倒置。

**契约（角色按能力定义，工具可换）**——方法论只依赖这四个能力，不绑具体工具：

| 角色 | 必备能力 | 参考实现（可换） |
|---|---|---|
| 执行 agent | 吃 goal 文档、交互式可 steering、有忙碌信号 + 存活信号 | omp / Claude Code / aider… |
| 评审 agent | 异构（与执行不同 lineage）、只读 | codex / 另一家强模型 |
| 派发载体 | 能发指令进、能抓屏出的交互会话 | tmux / 其他复用器 |
| watcher | 轮询"存活+忙碌+等输入"、返 typed 状态 | `references/agent-watch/`（`dispatch`/`watch`/`teardown` + 生命周期 hook;hook 主信号、抓屏降级） |

下文点名的 omp/codex/tmux 是**参考实现**；换栈时照此契约替换，§1.4 的忙碌标记/存活信号按你的工具校准。

## 1. 派工协议（每次走全流程）

1. **Rebase**：派工前 `git fetch` + 基于最新远端目标分支开 worktree
   （`git worktree add ../wt-<name> -b feat/<name> origin/<base>`）；远端中途动了，评审/PR 前再
   rebase。不让 agent 在过期基线开工。
2. **写 goal**（模板 `references/goal-template.md`，放 `docs/orchestration/<NAME>_GOAL.md`）：含
   上下文+前置研究、带 file:line 的预判（标"verify, don't trust"）、交付物、验证要求、guardrails
   （scope / stop-and-report / redaction / commit-local-no-push）。
3. **tmux 派发 + 理解门**：
   ```bash
   tmux new-session -d -s <proj>-<task>-omp -c <worktree> 'omp'
   sleep 12
   tmux send-keys -t <session> 'goal：<abs-path>'; sleep 1; tmux send-keys -t <session> Enter
   ```
   坑：文本与 Enter 分开发；文本含 `@` 触发补全 → 先发 `Escape` 再 `Enter`；codex 启动弹更新提示先发 `2`+Enter。
   **派发后、动手前先过理解门**：第一轮要 agent 复述"这改动碰哪些文件/契约、有哪些风险"，核对无误
   再放行；弱答/跑偏当场纠正，别把沉默当默许。一句复述挡掉大半"误解 goal 就埋头改"。
4. **挂 watcher**（`references/agent-watch/`，**hook 主信号、抓屏降级**）：`dispatch <omp|codex|claude>
   <session> <cwd>` 起 + `watch <session>` 监控 + `teardown` 收。机制细节（events sentinel、
   env-必须写进命令串、两层兜底、scrape fallback、codex hook-trust）见该目录 README；本节只留编排者纪律：
   - **typed 状态**：0 DONE / 1 SESSION-GONE / 2 AGENT-DEAD / 3 HANG / 4 WAITING-INPUT / 5 STALLED-EXTERNAL
     （DEAD≠DONE、WAITING 要回输入）。长跑批触 HANG 上限 = "still busy" 重挂、非故障。
   - **5 STALLED-EXTERNAL = 外部 provider 错误热重试**（overload / rate-limit / 5xx）。agent 活着且
     WORKING、hook events 在 cycling、屏幕在刷新 → DONE 与 HANG（要屏冻）都不触发，纯事件驱动会**静默盲等**
     一个永不来的终态（实证：overloaded_error 上盲等 ~13min）。watcher 现检测错误 chrome 连续命中→exit 5。
     收到 5：**先核证再动手**——扫一眼 exit 5 附带的屏尾 dump，确是 provider chrome（非 agent 正在写错误处理
     代码/看日志、把这些字符串刷上屏导致误报）；坐实后**别等了**——kill 掉热重试的 agent、换新会话（不带退避
     状态，provider 缓过来即成功），或改用更省的方式做该步。模式 `AGENT_WATCH_EXT_ERR_RE` 可配。
   - **纯事件驱动会盲等：挂 watcher 时同时设上限**。除 watcher 外，按"任务预期时长 ×2"设个 fallback 自检
     （ScheduleWakeup），到点没终态就主动 capture-pane——"WORKING 但卡死/热重试"不发终态事件。
   - **判完成要正向证据、不凭 idle**（tmux 链路无失败信号：session 在则 send/capture 都"成功"）。两个坑：
     ① agent 死了退回 shell = 空屏+无忙碌 → 必须核 `pane_current_command` 仍是 agent 进程；
     ② **agent 自起后台 job 会 yield=发 DONE 但没完成**（bg 跑完自动续）——凡这类相把完成信号绑**正向
     交付物**（本地 commit／产物计数达标／显式 review 标记），别把"等自己 bg"误判成"等编排者"（实证：重批量
     抽取走 agent 自起 bg，按 idle 轮询屡误报，改判"出现本地 commit + idle 稳定"才准）。是 `沉默≠交付` 的同族。
   - **启动纪律**：`watch` 作**单独一条** `run_in_background` 启动（绝不加 `&`、绝不拼行，否则随壳退出变孤儿
     不回调），起后立刻 Read output 确认 `WATCH ARMED`。**完成通知触发仍自己 capture-pane 核证，不盲信。**
5. **steering**：新事实/新指令出现，写成补充文档或直接 send-keys 进会话，明确"与你假设矛盾时，事实赢"。
6. **收工核证 + Implemented→Verified**：watcher 测的是 idle、agent 自报的是 "done"——**都只算
   Implemented，不是交付**（别让交付状态由执行者自报，§1.4 存活检测是同一主题）。升 **Verified** 仅当
   ①核证四件套过 + ②异构 codex 独立确认（执行者再严的完成自审——哪怕跑了结构化完成审计——仍是
   同 lineage 自审 = self-preference bias，不可信）；
   **roadmap / ACTIVE_CONTEXT / 关单只认 Verified**。四件套：① `git status -s` 干净（实证：omp 屡次
   "声称完成没 commit"）；② `git log origin/<base>..HEAD` 与声明一致；③ 独立复跑 test+lint；
   ④ 测试计数用 `grep -E 'passed|failed'`，别信被截断的点行。

## 2. 对抗式评审循环

1. **起 codex + brief 冷上下文**：omp commit+核证后起 codex 于同一 worktree（模板
   `references/review-dispatch.md`）。**只给"查哪些轴 + verify don't trust + 收敛达标线"，不夹带自己的
   结论/倾向**——喂 codex 我的判断 = anchoring，换模型却共享推理链 = 异构去相关价值白费。点名最易翻车的
   轴（崩溃恢复、并发竞态、旗标关路径零泄漏、降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏:
   异常链/URL userinfo/日志；评测报告类加**指标诚实性**:指标虚高/证据越界泛化）。点名轴让 codex 主动写
   探针复现，命中率远高于泛泛 review；每轮追问"上轮修复引入了什么新洞"屡次抓到真问题。
2. **评审记录用 ledger 结构，不纯追加**：写 `docs/orchestration/<NAME>_REVIEW_codex.md`——severity
   分级 findings + verdict（approve / request-changes），并维护 `blocking / queued / advisory / 已修 /
   stagnation` 几栏，逐轮更新。结构化记录让收敛状态一眼可判，胜过流水账追加。
3. **循环回修，每轮重贴不可变目标**：request-changes → 派回 omp 修 → codex 复审，循环到 approve。
   **每轮派回时把原 goal 的不可变验收点重贴进 prompt 对照**——防多轮改着改着跑题、偏离初衷。
4. **收敛准则（防乒乓，编排者设定）**：
   - findings 三分类：`blocking`（必修才放行）/ `queued`（记下不阻塞、留 follow-up）/ `advisory`
     （建议）。只有 `blocking` 残留才继续循环。
   - **advisory/非逻辑项 → follow-up，别挡已就绪的 push**：先 ship 已 Verified 的东西，nit 攒成后续；真要
     并也先 push 再异步补（实证：为一行注释 fold-before-push，正撞 provider 过载、空耗一轮）。
   - **不重复 raise** 已 queued / 越界 / 上轮判过的 finding——除非本轮动了那块或让风险变差。
   - **stagnation 检测**：同一 finding 反复出现 = 卡住，该收敛或升级人介入，别无限对轰。
   - 质量类无限可挑的项（过滤规则、命名）明确"达标线":线内必修、线外进 `queued`。例:"确定性过滤是
     兜底、LLM prompt 是主闸；常见形态全覆盖即达标，冷僻算 minor"。
5. **评审期 omp 别动同一 worktree**（codex 在内跑测试会被污染）。串行十几分钟换干净结论，值得。

## 3. 变更纪律

- **旗标门控**：行为变更默认藏 env flag 后，默认 OFF = 字节级零变化；例外：ReOpen 批准的修复可默认
  ON（goal 写明理由）。性能/实验类一律 OFF。
- **measure-before-more**：第一刀砍下后绑定约束会换人——先实测再决定第二刀，别按推算连下多个 lever。
  修 bug 同理：动手前先验证 ① bug 在**当前态真能复现**（可能是历史数据／部署前／查错数据源，并非当前缺陷），
  ② 观测值真被某机制约束（观测 5 < 上限 10 ⇒ 上限不是约束）。便宜的当前态求证（现在还复现吗／功能何时上线）
  挡在昂贵的代码调查前——实证屡见"报错"实为查错表、"功能失效"实为上线前历史数据。
- **commit 留本地，push/PR 必须用户明示批准**；批准一次只覆盖那次。
- **验证诚实**：交付三段式——验证了什么（真跑过）/ 没验证什么 / 剩余风险。本地打桩绕过的环节（真
  LLM、真队列）显式标注，部署后运维补验。实证：本地 LLM 打桩致 un-awaited coroutine 逃逸生产。

## 4. 间接环境访问（运维 agent 模式）

够不着的环境（prod、独立 dev 运行时库）不要猜——写**自包含取证提示词**（模板
`references/ops-prompt-template.md`，放 `docs/orchestration/<NAME>_PROMPT.md`）让用户转交运维 agent。
要点：只读约束写死、SQL/命令给全、预期读数+判定规则给全、回报格式给死（PASS/FAIL + 一行 verdict）、
敏感数据只取元数据。运维回报**优先级高于自己的推断**——现场与 HEAD 代码矛盾时，先怀疑构建漂移
（部署的是旧版本），再怀疑自己的控制流分析。

## 5. 状态落盘与节奏

- `docs/orchestration/` 是 SoT：`*_GOAL` / `*_FINDINGS|IMPL_omp` / `*_REVIEW_codex` / `*_PROMPT` /
  `*_RESULT`，命名带任务号、全 file:line 证据。**生命周期**：收口即把文档挪进 `archive/`（README 加
  索引行），live 只留在跑/在等的；文档只生不死 → live 与历史混杂（实证：某项目积 38 个才首清）。
- memory：每 workstream 一文件 + 索引一行（状态/PR/敞口/下一步入口），"压缩/等外部输入"前必更新。
  **memory 编排者私有，agent/新 session 只能读 docs**——只更 memory 不同步 docs = 共享治理层腐烂
  （实证：某项目 ACTIVE_CONTEXT 冻 4 天变废纸）。分工：memory 存编排者视角的教训+入口，docs 存全
  agent 共享的状态快照。
- **复盘仪式（事件触发）**：收口 / 压缩前 / 任何 ReOpen 后主动提议——交付清单 → 什么有效 → 教训进
  memory → 上下文治理（关会话 + 扫孤儿 + worktree 核对 + 敞口清单=下会话入口）→ **治理同步**（文档归档
  + ACTIVE_CONTEXT 整篇重写 + roadmap 翻状态，与 memory 更新同级、不可省）。
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

派完前端任务，**验收纪律：代码 review + 单测都不够，必须回浏览器看真实渲染**。完整方法论（MCP 主
CLI 补、a11y 优先、网络面板诊断联网 bug、CLI 抓 SSE）见 `references/frontend-verify.md`。本地起服务的
具体坑高度项目特定，写进**该前端项目自己的 `AGENTS.md`**，不进通用 skill。

## 8. 新项目接入清单

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   `references/agents-md-orchestration-section.md` 的 **委派 Agent 边界** 一节增补进去——多 agent 防
   漂移，是 bootstrap 宪法没有的编排增量（不重复 Work Modes）。
3. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 §5）。
4. 第一个任务走一遍 §1 全流程，校准该项目的忙碌标记/工具链差异。
5. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
