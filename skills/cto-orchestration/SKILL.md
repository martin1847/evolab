---
name: cto-orchestration
version: 1.1.4
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
> 就**先问清再做**；**一次批准不自动延伸到另一个动作**。可逆只读动作直接做、不请示。实证：把用户的 "push"
> 当成含 "merge" 去合共享分支被拦；一度误读 git 合并状态（单次工具输出有歧义，靠 `cat-file -p` 实读才定论）。

## 0. 角色分工（按能力定义，工具可换）

方法论只依赖这几个能力、不绑具体工具（**含编排者本身**）；下文点名的 omp/codex/tmux（含"你=Claude Code"口吻）都是参考实现，换栈照此替换。

| 角色 | 干什么 / 不干什么 | 参考实现（可换） |
|---|---|---|
| **编排者**（你/CTO） | 写 goal/取证提示词、派工、**起 watcher 取终态裁决**、转述评审、汇报、memory/docs 落盘、任务系统操作 + 定时/轮询兜底；**绝不写产品代码、不自己跑长 E2E·批量验证**（收工独立复跑 test+lint 不算，见 §1.6） | **后台型**(起 watcher 读交付终态)：Claude Code(`run_in_background`+通知+`ScheduleWakeup`) / omp(原生 bg-job)；**阻塞型**：codex(同步 `watch` 读 exit code + cron/轮询，需 `--dangerously-bypass`)；通用:任何 shell+文件 agent。三者均实跑验证 |
| 执行 agent | 吃 goal 实现 + 自测 + E2E + findings；不做超 goal scope 改动。须交互可 steering + 忙碌信号 + 存活信号 | omp / Claude Code / aider… |
| 评审 agent | 只读对抗式评审（review）、severity + verdict；不改码/commit。须**异构**（与执行不同 lineage） | codex / 另一家强模型 |
| 运维 agent | 够不着的环境(prod/独立 dev DB)只读取证 + 部署后验证；不修复/改配置 | 用户转交提示词 |
| 派发载体 | 发指令进、抓屏出的交互会话 | tmux / 其他复用器 |
| watcher | 轮询"存活+忙碌+等输入"返 typed 状态 | `references/agent-watch/`（dispatch/watch/teardown + hook；hook 主信号、抓屏降级）|

**默认 omp 执行、codex 评审，不倒置**——omp(oh-my-pi+Opus)强在自主执行、codex(gpt)强在严苛评审，交叉评审屡抓双方都漏的真问题。
**编排者本身也可换**（codex/任何 shell+文件 agent 都能坐 CTO 位）；§1.4 的 watcher 起法/忙碌·存活信号按你的工具校准，`requires.bins` 的 tmux/omp/codex 是参考栈、非硬依赖。

## 1. 派工协议（每次走全流程）

1. **基线纪律（fetch+检查，按需 rebase，集成用 squash）**：派工前 `git fetch` + 基于最新远端目标分支开
   worktree（`git worktree add ../wt-<name> -b feat/<name> origin/<base>`）。**不让 agent 在过期基线开工。**
   权威细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard` 规划中）；这里只留编排基线。
   - **rebase 不是仪式、是条件动作**：push/PR 前 `git fetch` 后查 base 有没有动
     （`git log <branchpoint>..origin/<base>` 空=没动）。**没动 → 什么都不做**（别空转 rebase，否则看着像"忘了"其实是 no-op）。
     **动了且碰了你改的文件 → rebase**解冲突再 PR；动了但文件不重叠 → 可不动（合并自然干净）。
   - **集成（并回主干）默认 squash（linear history）；merge-commit 已弃用**：全 agent
     开发没人读 git 历史，agent 要逻辑原子 + message 清楚的 commit（squash 产物），中间 wip churn 是 context 污染。
     出 artifact 的仓由 IaC ruleset 强制 linear，merge-commit 会被挡。对抗评审知识落 **ADR + PR 记录 + commit
     trailer**（`Constraint:` / `Rejected-alternative:`），不靠 commit graph。
   - 多会话并发时 base 常被别的 PR 推进，所以 **`git fetch`+检查这一步省不得**（省了才会在过期基线上 PR）。
   - 按 SHA 部署的项目：squash / rebase-merge 的 ancestry 都干净线性（`contains <sha>` 成立）。
   - **只读 scout/audit/Explore 也算"开工"**：经 Agent 工具派出时**静默继承编排者 cwd**（常是落后的主 checkout、
     非新 worktree）→ 对着过期基线出"幻影发现"（删了的看着还在、已合的看着没合）。派 scout **显式指到新 worktree**，
     可疑结论再**对 base ref 复核**（`git show origin/<base>:<path>` / `git grep`）。实证：审计跑在落后 70 commit 的
     主 checkout、把已被某 PR 删净的子系统报成"待删"，靠对 origin 重核才在派删除前抓出。
2. **写 goal**（模板 `references/goal-template.md`，放 `docs/orchestration/<NAME>_GOAL.md`）：含
   上下文+前置研究、带 file:line 的预判（标"verify, don't trust"）、交付物、验证要求、guardrails
   （scope / stop-and-report / redaction / commit-local-no-push）。
3. **派发（用 `dispatch` 起）+ 验 hook + 理解门**：
   ```bash
   # dispatch 把 hook env 注进 tmux 命令串——watcher 走 hook 主信号的前提，缺则退化抓屏（机制见 README）。
   references/agent-watch/dispatch <omp|codex|claude> <proj>-<task>-omp <worktree>
   sleep 12
   tmux send-keys -t <session> 'goal：<abs-path>'; sleep 1; tmux send-keys -t <session> Enter
   ```
   坑：文本与 Enter 分开发；文本含 `@` 触发补全 → 先发 `Escape` 再 `Enter`；codex 启动更新提示——一次性在
   `~/.codex/config.toml` 设 `check_for_update_on_startup = false` 免掉（否则每次得先发 `2`+Enter）。
   **起后立刻验 hook（硬 gate，别跳）**：`watch` 一挂就 Read 输出——必须见 sentinel `WORKING` 行；见
   `no sentinel (hook not wired) → fallback` = 没走 dispatch（或 codex 未 trust hook）→ **停下重起、别带病跑**
   （实证：裸起整 session 退抓屏，误报 DONE + 漏 WAITING——澄清菜单挂 busy 标记 ⟦esc⟧、抓屏永判"忙"、卡 21min 零 ping）。
   **派发后、动手前先过理解门**：第一轮要 agent 复述"这改动碰哪些文件/契约、有哪些风险"，核对无误
   再放行；弱答/跑偏当场纠正，别把沉默当默许。一句复述挡掉大半"误解 goal 就埋头改"。
4. **挂 watcher**（`references/agent-watch/`，**hook 主信号、抓屏降级**）：agent 已在 step 3 用 `dispatch` 起好
   （hook 已注），本步只 `watch <session>` 监控 + 收工 `teardown`。机制细节（events sentinel、
   env-必须写进命令串、两层兜底、scrape fallback、codex hook-trust）见该目录 README；本节只留编排者纪律：
   - **typed 状态**：0 DONE / 1 SESSION-GONE / 2 AGENT-DEAD / 3 HANG / 4 WAITING-INPUT / 5 STALLED-EXTERNAL
     （DEAD≠DONE、WAITING 要回输入）。长跑批触 HANG 上限 = "still busy" 重挂、非故障。
   - **5 STALLED-EXTERNAL = 外部 provider 错误热重试盲区**（overload/rate-limit/5xx；agent 活着 WORKING 却永不
     DONE，机制见 README，实证盲等 ~13min）。收到 5：**先核证再动手**——扫 exit 5 附带的屏尾，确是 provider
     chrome（非 agent 写错误处理代码刷屏误报）再 kill 热重试 agent、换新会话（不带退避状态）。
   - **纯事件驱动会盲等：挂 watcher 时同时设上限**。除 watcher 外，按"任务预期时长 ×2"设个 fallback 自检
     （定时兜底——CC:`ScheduleWakeup`；codex/shell 编排者:cron 或有界轮询），到点没终态就主动 capture-pane
     ——"WORKING 但卡死/热重试"不发终态事件。
   - **判完成要正向证据、不凭 idle / watcher 裁决**（tmux 链路无失败信号：session 在则 send/capture 都"成功"；
     watcher 裁决同样只是线索，后台型/阻塞型哪条消费路径[见 §0 + README]都要自己 capture-pane 正向核证、不盲信）。两个坑：
     ① agent 死了退回 shell = 空屏+无忙碌 → 必须核 `pane_current_command` 仍是 agent 进程；
     ② **agent 自起后台 job 会 yield=发 DONE 但没完成**（bg 跑完自动续）——凡这类相把完成信号绑**正向
     交付物**（本地 commit／产物计数达标／显式 review 标记），别把"等自己 bg"误判成"等编排者"（实证：重批量
     抽取走 agent 自起 bg，按 idle 轮询屡误报，改判"出现本地 commit + idle 稳定"才准）。是 `沉默≠交付` 的同族。
   - **后台启动一律不加 shell `&`**（后台机制已 detached，再加 = 双重后台 → 孤儿 + 误判失联）；手滑挡不住
     → **PreToolUse(Bash) 兜底**（同 §5 强制层思路）：`references/agent-watch/no-bg-amp-guard.sh` 拦**任何**带尾随
     `&`/`& disown` 的命令 deny（`&&`/`2>&1` 重定向/引号内 `&`/前台 全放行），接项目 `.claude/settings.json`。
5. **steering**：新事实/新指令出现，写成补充文档或直接 send-keys 进会话，明确"与你假设矛盾时，事实赢"。
6. **收工核证 + Implemented→Verified**：watcher 测的是 idle、agent 自报的是 "done"——**都只算
   Implemented，不是交付**（别让交付状态由执行者自报，§1.4 存活检测是同一主题）。升 **Verified** 仅当
   ①核证四件套过 + ②异构 codex 独立确认（执行者再严的完成自审——哪怕跑了结构化完成审计——仍是
   同 lineage 自审 = self-preference bias，不可信）；
   **roadmap / ACTIVE_CONTEXT / 关单只认 Verified**。四件套：① `git status -s` 干净（实证：omp 屡次
   "声称完成没 commit"）；② `git log origin/<base>..HEAD` 与声明一致；③ 独立复跑 test+lint；
   ④ 测试计数用 `grep -E 'passed|failed'`，别信被截断的点行。

## 2. 对抗式评审循环

**先按风险定评审深度**：日常/低风险改动 → 轻量标准 review（`codex review --base <base>` 原生子命令：自动算 diff +
结构级只读，省 prompt，挡基本质量/回归）；高风险（鉴权/迁移/基建脚本/大重构）→ 走下面完整对抗循环。codex **无内置
"对抗"强度档**——"对抗"是 prompt 层（即本节：自起会话点名轴 + severity/verdict + 多轮收敛），其 `review` 子命令只给
"自动 diff + 只读 summary"、不给 verdict schema，故对抗循环**必须自起会话自控 prompt**，别用子命令。

1. **起 codex + brief 冷上下文**：omp commit+核证后起 codex 于同一 worktree（模板
   `references/review-dispatch.md`）。**只给"查哪些轴 + verify don't trust + 收敛达标线"，不夹带自己的
   结论/倾向**——喂 codex 我的判断 = anchoring，换模型却共享推理链 = 异构去相关价值白费。点名最易翻车的
   轴（崩溃恢复、并发竞态、旗标关路径零泄漏、降级语义、安全契约；多租户加租户隔离 + 凭据**间接**泄漏:
   异常链/URL userinfo/日志；评测报告类加**指标诚实性**:指标虚高/证据越界泛化）。点名轴让 codex 主动写
   探针复现，命中率远高于泛泛 review；每轮追问"上轮修复引入了什么新洞"屡次抓到真问题。
   **评审前先枚举执行路径分叉**（provider / mode、live vs rehydrate、suggestion-flow vs direct-save…），
   点 codex 核"还有哪些分支没走到"——只覆盖一条分支 ≠ 全覆盖（实证：评审只盯主 controller 路径，真实用户
   走另一个 provider 的独立分支，整条提取被绕过仍全绿）。
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
- **measure-before-more / 先量再断**：第一刀砍下后绑定约束会换人——先实测再决定第二刀，别按推算连下多个
  lever。修 bug 同理，动手前验证 ① bug **当前态真能复现**、② 观测值真被某机制约束（观测 5 < 上限 10 ⇒ 上限
  不是约束）、③ 执行**真到了**你怀疑的代码（读代码只找候选，"执行到这"要日志/trace 证）。**绑定约束未证时，
  先派埋点 + 复测、不发投机修复**（实证：读代码三轮推断一个根本不存在的"挂死"、每轮被真数据打回）。常见
  伪 bug：查错了数据源（空表当真表 / 错日志串 / 错 session）、**"没收到"(客户端) ≠ "没发出"(服务端)**。
- **commit 留本地，push/PR 必须用户明示批准**；批准一次只覆盖那次。
- **验证诚实**：交付三段式——验证了什么（真跑过）/ 没验证什么 / 剩余风险。本地打桩绕过的环节（真
  LLM、真队列）显式标注，部署后运维补验。实证：本地 LLM 打桩致 un-awaited coroutine 逃逸生产。
- **代验路径 ≠ 真路径**（后端/agent/前端通用）：mock / 打桩 / stream smoke 全绿 **≠ 真实路径成立**——
  按**真实部署路径**验收，别拿代验当真验，真路径常和你 mock 的那条不是同一条（前端实例见 §7：卡片走
  `execute/async` 非 `execute/stream`，三段绿仍 ReOpen）。最尖一条：**别 mock 你正在验证的那个边界**
  ——stub 掉被测函数 = 测试零信息、恰好盖住 bug；真应用 E2E 才是「可测试」门（实证：一天内 4 个 bug
  全过 review+单测，只它抓到）。
- **编辑前重读会变的文件**：rebase / 另一 agent 动过同一 worktree / 你刚跑了改文件的 git 操作 之后，
  in-context 文件视图已 stale——先重读再改。带 read-before-edit 护栏的工具会**拦** stale edit（报 `must be read
  first` 不是 bug、是它在挡你拿过期视图覆盖别人的改动）；没护栏的会**静默覆盖**、更糟。别在读↔编辑间插改文件的命令。

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
  （实证：某项目 ACTIVE_CONTEXT 冻 4 天变废纸）。**三分工**：docs 存全 agent 共享的状态快照（what/why）、
  `ACCESS.local.md` 存怎么连上 + 凭证（how-to-reach，含密 gitignored，见 repo-governance-bootstrap）、memory 存
  编排者私有的教训 + 入口指针。**短期 working 记忆（当前任务草稿/进度/待办）不进这三类**——活在 context window
  或临时 `/tmp` NOTES、随手可弃，别塞进 memory（污染跨 session 私有层）或 ACTIVE_CONTEXT（那是收口快照非草稿）。
  - **写时纪律（不等复盘）**：上面的卸载边写边做——写 memory 当下就把事实细节进 ACCESS/docs，别囤到复盘再清。
    靠 skill 文本记不住的高频纪律配 **PostToolUse hook** 兜底（强制层补 salience 衰减；模板见 repo-governance-bootstrap）。
- **复盘仪式（事件触发）**：收口 / 压缩前 / 任何 ReOpen 后主动提议——交付清单 → 什么有效 → 教训进
  memory → 上下文治理（关会话 + 扫孤儿 + worktree 核对 + 敞口清单=下会话入口）→ **治理同步**（文档归档
  + ACTIVE_CONTEXT 整篇重写 + roadmap 翻状态，与 memory 更新同级、不可省）→ **memory 治理**（COMPLETED
  workstream 精简、索引按类型分组——卸载规则同上）→ **session 切换决策**（压缩续跑 vs 新 session + handoff）。
  后两步操作清单见 `references/retrospective.md`。
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

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   `references/agents-md-orchestration-section.md` 的 **委派 Agent 边界** 一节增补进去——多 agent 防
   漂移，是 bootstrap 宪法没有的编排增量（不重复 Work Modes）。
3. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 §5）。
4. 第一个任务走一遍 §1 全流程，校准该项目的忙碌标记/工具链差异。
5. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
