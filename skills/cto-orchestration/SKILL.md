---
name: cto-orchestration
version: 1.0.0
description: "CTO/orchestrator 模式管理多 agent 开发：本人不写产品代码，通过 tmux send-keys 派发 omp（执行）+ codex（评审）混合开发，goal 文档驱动、watcher 监控、对抗式评审循环、旗标门控、运维 agent 间接取证。适用于用户要求'你做 CTO/编排者'、'派 omp/codex 去做'、'goal 模式派发'、管理多会话并行开发、或在新项目复制此 CTO 工作流时。【定位】循环式日常编排运营；新项目先跑一次性的 repo-governance-bootstrap 建治理骨架，再用本 skill 派工——两者分工：bootstrap 建结构、本 skill 跑循环。不要用于：单 agent 一次性小任务、不需要多 agent 评审循环的改动、纯文档/治理初始化（用 repo-governance-bootstrap）。"
metadata:
  requires:
    bins: ["tmux", "omp", "codex"]
---

# CTO Orchestration — 多 agent 混合开发编排

> 来源：多 agent CTO 项目实战沉淀（2026-06 起）。核心铁律：**编排者本人绝不写产品代码**——
> 哪怕改动小到"顺手就改了"，也派给执行 agent。编排者的产出是：goal 文档、监控、
> 评审调度、决策汇总、状态落盘。

## 0. 角色分工

| 角色 | 谁 | 干什么 | 不干什么 |
|---|---|---|---|
| 编排者（你） | Claude Code 主会话 | 写 goal/取证提示词、派工、watcher 监控、转述评审、向用户汇报、memory/docs 落盘、任务系统操作 | 写产品代码、自己跑长 E2E/批量验证（收工的独立复跑 test+lint 不算，见 §1.6） |
| 执行者 | omp（tmux 会话） | 按 goal 实现 + 自测 + E2E + findings 文档 | 超出 goal scope 的改动 |
| 评审者 | codex（tmux 会话） | 只读对抗式评审，severity 分级 + verdict | 改代码、commit |
| 运维 agent | 用户转交提示词 | 我们够不着的环境（prod/独立 dev DB）的只读取证与部署后验证 | 修复、配置变更 |

实证经验：omp（oh-my-pi + Opus）强在自主执行与判断，codex（gpt）强在严苛评审——
交叉评审屡次抓到双方都漏的真问题。默认 omp 执行、codex 评审，不要倒置。

## 1. 派工协议（每次都走全流程）

1. **Rebase ritual**：派工前 `git fetch` + 基于最新远端目标分支开 worktree/分支
   （`git worktree add ../wt-<name> -b feat/<name> origin/<base>`）；远端中途动了，
   评审/PR 前再 rebase。绝不让 agent 在过期基线上开工。
2. **写 goal 文档**（模板见 `references/goal-template.md`）：放项目的
   `docs/orchestration/<NAME>_GOAL.md`。必含：上下文+前置研究文档、带 file:line 的
   预判（标注"verify, don't trust"）、交付物清单、验证要求、guardrails
   （scope/stop-and-report/redaction/commit-local-no-push）。
3. **tmux 派发**：
   ```bash
   tmux new-session -d -s <proj>-<task>-omp -c <worktree> 'omp'
   sleep 12   # 等启动
   tmux send-keys -t <session> 'goal：<absolute-path-to-goal.md>'
   sleep 1 && tmux send-keys -t <session> Enter
   ```
   坑：send-keys 文本和 Enter 必须分开发；文本含 `@` 会触发补全弹窗——先发
   `Escape` 再发 `Enter`；codex 启动会弹更新提示，先发 `2` + Enter 跳过。
4. **挂 watcher**（模板见 `references/watcher.sh`）：后台轮询 pane、完成自动通知。
   **根因铁律：tmux 链路没有失败信号**——`send-keys`/`capture-pane` 只要 session 在就成功；
   agent 死了/没起来退回 shell = "成功+空屏+无忙碌标记"，裸 idle 检测会把**死亡误判成完成**
   派去评审。故判完成必须有**正向存活证据**（`pane_current_command` 仍是 agent 进程、不是
   shell），不能只凭忙碌标记（omp=`⟦esc⟧`/codex=`esc to interrupt`）缺失。watcher 返 typed
   状态：0 DONE / 1 SESSION-GONE / 2 AGENT-DEAD / 3 HANG / 4 WAITING-INPUT（DEAD≠DONE、
   WAITING 要回输入）。首接新 agent 校准存活信号（活着+空闲跑一次 `tmux display-message -p
   '#{pane_current_command}'` 记进程名，同校准忙碌标记）。长跑批必超上限——超时"still busy"重挂、非故障。
5. **中途插话（steering）**：新事实/用户新指令出现时，把它写成补充文档或直接
   send-keys 进会话——明确告诉 agent"与你的假设矛盾时，事实赢"。
6. **收工核证四件套 + Implemented→Verified**：watcher 测的是 idle、agent 自报的是
   "done"——**两者都只算 Implemented，不是交付**（统一主题：别让交付状态由执行者自报决定，
   §1.4 存活检测是它在"完成信号"层的实例）。升 **Verified** 仅当①编排者核证四件套过 +
   ②异构 codex 独立确认（同 lineage 自审不可信 = self-preference bias）；**roadmap /
   ACTIVE_CONTEXT / 关单只认 Verified**。核证四件套：① `git status -s` 树干净（实证：omp 屡次
   "声称完成没 commit"）；② `git log origin/<base>..HEAD` 与声明一致；③ 独立复跑 test+lint；
   ④ 测试计数用 `grep -E 'passed|failed'` 取、别信被工具截断的点行。核证过了才派评审。

## 2. 对抗式评审循环

1. omp commit + 核证后，起 codex 于同一 worktree（指令模板 `references/review-dispatch.md`）。
   **brief 冷上下文：只给"查哪些轴 + verify don't trust + 收敛达标线"，不夹带编排者自己的
   结论/倾向**——喂 codex 我的判断 = anchoring，换了模型却共享推理链 = 异构复核的去相关价值
   白费（其价值正在于失败模式独立）。点名最容易翻车的轴（崩溃恢复、并发竞态、旗标关路径零泄漏、
   降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏——异常链/URL userinfo/日志；评测报告
   类加**指标诚实性**——指标虚高 / 证据越界泛化到没测过的场景）。实证：点名轴让 codex 主动写
   探针复现，命中率远高于泛泛 review；每轮复审追问"上轮修复引入了什么新洞"屡次抓到真问题。
2. codex 产出 severity 分级 findings + verdict（approve / request-changes）写入
   `docs/orchestration/<NAME>_REVIEW_codex.md`，逐轮追加。
3. request-changes → 派回 omp 修 → codex 复审，循环到 approve。
4. **收敛准则（防乒乓，必须由编排者设定）**：质量类无限可挑的项（如过滤规则、
   命名）明确"达标线"——线内必修，线外列 follow-ups 不阻塞。例：
   "确定性过滤是兜底，LLM prompt 是主闸；常见形态全覆盖即达标，冷僻形态算 minor"。
5. **评审期间不要让 omp 同时改同一 worktree**（codex 在里面跑测试会被污染）。
   串行十几分钟换干净结论，值得。

## 3. 变更纪律

- **旗标门控**：行为变更默认藏在 env flag 后，默认 OFF = 字节级零变化；例外：
  ReOpen 批准的行为修复可默认 ON（在 goal 里写明理由）。性能/实验类一律默认 OFF。
- **measure-before-more（绑定约束教训）**：优化第一刀砍下去之后，绑定约束会换人
  ——先实测再决定第二刀，不要按模型推算连续实现多个 lever。修 bug 同理：先确认
  观测值真被某机制约束（观测 5 < 上限 10 ⇒ 上限不是约束），再动那个机制。
- **commit 留本地，push/PR 必须用户明示批准**；批准一次只覆盖那一次。
- **验证诚实**：每次交付必须三段式——验证了什么（真跑过）/没验证什么/剩余风险。
  本地打桩绕过的环节（真 LLM、真队列）要显式标注，部署后由运维验证补全。
  教训实例：本地 LLM 打桩导致 un-awaited coroutine 逃逸到生产。

## 4. 间接环境访问（运维 agent 模式）

够不着的环境（prod、独立 dev 运行时库）不要猜——写**自包含取证提示词**
（模板见 `references/ops-prompt-template.md`）放 `docs/orchestration/<NAME>_PROMPT.md`
让用户转交运维 agent。要点：只读约束写死、SQL/命令给全、预期读数和判定规则给全、
回报格式给死（PASS/FAIL + 一行 verdict）、敏感数据只取元数据。
运维回报的数据**优先级高于自己的推断**——现场观察和 HEAD 代码矛盾时，先怀疑
构建漂移（部署的是旧版本），再怀疑自己的控制流分析。

## 5. 状态落盘与节奏

- `docs/orchestration/` 是 SoT：`*_GOAL.md`（派工）、`*_FINDINGS/IMPL_omp.md`
  （执行产出）、`*_REVIEW_codex.md`（评审记录）、`*_PROMPT.md`（运维提示词）、
  `*_RESULT.md`（E2E 结果）。命名带任务号，全部 file:line 证据。
  **生命周期**：workstream 收口即把其文档挪进 `docs/orchestration/archive/`（README 加一行
  索引），live 区只留在跑/在等的。文档只生不死 → live 与历史混不可分（实证：某项目积 38 个才首清）。
- memory：每 workstream 一文件 + 索引一行（状态/PR 号/敞口/下一步入口），"压缩/等外部输入"前必更新。
  **memory 是编排者私有的，omp/codex/运维/新 session 只能读项目 docs**——只更 memory 不同步 docs =
  共享治理层腐烂（实证：某项目 ACTIVE_CONTEXT 冻结 4 天变废纸）。两边都写：memory 存编排者视角的
  教训与入口，docs 存所有 agent 共享的状态快照。
- **复盘仪式（事件触发，非日历）**：workstream 交付收口 / 压缩前 / 任何 ReOpen 后，
  主动提议复盘：交付清单 → 什么有效 → 教训固化进 memory → 上下文治理
  （关闭已交付会话 + 扫进程/容器孤儿、worktree 核对、敞口清单 = 下会话入口）→
  **治理同步**（orchestration 文档归档 + ACTIVE_CONTEXT 快照整篇重写 +
  roadmap 状态翻转——这步和 memory 更新同级，不可省）。
- 会话治理 + 孤儿扫：交付完的 agent 会话关掉（**持有关键上下文且任务挂起的保留**，如等用户
  决策后要续做的）；**还要扫 agent 起的孤儿**——`docker ps`（项目容器）/ `ps`（detached
  repro·dev server）/ 后台 job。临时 compose、repro 脚本属"启动了不保证终结"，与 §1.4 存活、
  §1.6 自报一脉——**启动/声称的东西别靠运气终结/兑现**。**防**：临时 compose 用 trap/finally
  `down --remove-orphans`，repro 禁裸 `while True`（用有界循环/deadline）。实证：某 repro 死
  循环空转 2.5 天 65% CPU、compose 容器遗留 2 天。

## 6. 任务系统（外部任务追踪：Jira / Linear / 飞书 bitable 等）

- 用任务系统的 CLI / API 读写任务；状态机随项目定义
  （待处理/处理中/可测试/已完成/阻塞/ReOpen）。
- **关单标准**：修复 → E2E 验证 → 截图证据上传任务附件（让验收人一眼对照）→
  处理结果写一行结论 → 翻状态。
- ReOpen 处理：先取证再修——上一轮"修好了"的机制可能根本不是绑定约束。
- **别在治理 docs 里养第二套任务账本**：外部系统是任务 SoT，roadmap 只是它的映射层。
  规则细节（沿用外部 ID / 写明 SoT / 何时才造内部 RD 号）由 `repo-governance-bootstrap`
  的"外部任务系统优先"落地，这里只记运营触点。

## 7. 前端 fix 验证（浏览器联调）

派完前端任务，**验收纪律：代码 review + 单测都不够，必须回浏览器看真实渲染**。
怎么验的完整方法论（MCP 主 CLI 补、a11y 优先、网络面板诊断联网 bug、CLI 抓 SSE）见
`references/frontend-verify.md`。本地起服务的具体坑高度项目特定，写进**该前端项目自己的
`AGENTS.md`**，不进通用 skill。

## 8. 新项目接入清单

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   `references/agents-md-orchestration-section.md` 的 **委派 Agent 边界** 一节
   增补进去——多 agent 防漂移，是 bootstrap 宪法没有的编排增量（不重复 Work Modes）。
3. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 §5）。
4. 第一个任务走一遍 §1 全流程，校准该项目的忙碌标记/工具链差异。
5. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
