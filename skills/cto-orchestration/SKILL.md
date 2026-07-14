---
name: cto-orchestration
version: 1.5.1
description: "CTO/orchestrator 模式管理多 agent 软件交付：默认 headless EXEC、goal 合同驱动、typed watcher、异构评审、真路径验收与主理人减负。适用于用户要求'你做 CTO/编排者'、'派 omp/codex 去做'、'goal 模式派发'、管理多会话开发或把这套工作流接入新项目。新项目先用 repo-governance-bootstrap 建治理骨架。不要用于单 agent 小任务、无需评审循环的局部改动或纯文档初始化。"
metadata:
  requires:
    bins: ["tmux", "omp", "codex"]
---

# CTO Orchestration — 多 agent 软件交付

> 这是领域无关内核 `orchestrator-core` 的写码皮：主干只保留写码域每次都要用的判据与路由，命令细节、
> 故障矩阵和模板按需读 `references/`。

三条铁律：

1. **编排者不写产品代码**：只产出契约、调度、裁决和状态；实现与长 E2E 交给 worker。
2. **不可逆先核事实与授权**：push / merge / 部署 / 删除 / 对外消息只认主理人真实新 turn；一次批准不外延。
3. **主理人持判断，不持状态**：可逆事项自驱，非紧急决策攒批；风险带证据、影响边界和下一步及时冒泡。

## 0. 角色与 lane

| 角色 | 责任 | 默认实现（可换） |
|---|---|---|
| 编排者 | 写 goal、派工、监控、裁决、落盘；不写产品代码 | 任意 shell + 文件 agent |
| 执行 agent | 按 goal 实现、自测、E2E、交付；不扩 scope；须可观测且可轮间 resume | omp / Claude Code |
| 评审 agent | 冷上下文只读挑刺，给 evidence + severity + verdict；不改码 | codex / 不同 lineage 模型 |
| 运维 agent | 对不可达环境只读取证与部署后验证；不顺手修复 | 用户转交提示词 |
| watcher | 返回 typed 状态；不把 idle 或沉默解释成完成 | `references/agent-watch/` |

默认用 omp 执行、codex 评审，但**工具名不证明异构**；派工前看实际 model/backend，避免执行席与评审席落到同一 lineage 或 quota 池。

三条派工 lane：

| lane | 何时选 | 交互边界 |
|---|---|---|
| **headless EXEC（默认）** | 单轮目标可自包含；优先稳定终态 | 单轮不交互；当前轮结束后才可 `dispatch send` resume 下一轮 |
| **tmux TUI** | 必须轮内实时 steering、菜单或 pane 现场 | 启动时设 `DISPATCH_TUI=1`；维护 best-effort |
| **Agent subagent** | 浏览器 / MCP / 隔离主上下文的读密集工作 | 在独立上下文完成，只回蒸馏结论；显式按任务分档 model |

文件任务必须声明 `--deliverable <glob>`，让 runtime 做 freshness gate；非文件结果不带。lane 的完整限制、状态与命令见 `references/agent-watch/README.md`。

## 1. 每次派工闭环

1. **校准基线**：fetch 远端，确认目标 base 与 worktree；base 未动不仪式性 rebase。只读 scout 也显式指定 cwd/base，防静默继承过期 checkout。命令与核证见 `references/dispatch-baseline.md`。
2. **写自包含 goal**：一个 goal = 一个可独立交付的单元 + 一个清晰交付物；每条 Done-when 绑定证明命令，写清 scope、out-of-scope、stop-and-report。高不确定方向进入昂贵设计/实现前，先跑最便宜证伪并用 `--require-preflight`；单行合同、Premises 与 Value gate 直接用 `references/goal-template.md`。
3. **派发并挂 watcher**：

   ```bash
   references/agent-watch/dispatch <omp|codex|claude> <session> <cwd> --goal <abs-goal-or-brief> [--deliverable <glob>]
   ```

   默认 EXEC 在 round 启动后立即返回，**不会自动 watch**；紧接着用宿主的受控后台能力运行 `references/agent-watch/watch <session>`。同步 shell 编排者可显式设 `AGENT_WATCH_SYNC=1`。TUI 的融合 `--goal` 才在进程内 watch。先接线 `references/agent-watch/guard-hooks.json`；guard 负责高频机械失误，主干不复制其规则表。

   理解门按 lane：TUI 先复述再等放行；EXEC 的 runtime footer 要求简短复述后立即开工，真阻塞写 `<cwd>/BLOCKED.md` 并停止。
4. **只消费 typed status**：EXEC 可用 `dispatch status` 或 `watch`；TUI 只用 `watch`。不直接读私有 rc，也不把 watcher/agent 自报当完成。任何沉默、超时、外部停滞或缺交付物都按对应 typed 分支处理；完整状态表与 `rearm` 见 agent-watch README。
5. **按 lane steering**：
   - EXEC：RUNNING 轮不读 stdin，`dispatch send` 会拒绝；等本轮停止后再 `send`，它会 resume 同一 engine session 并开下一轮。需要轮内影响，只能预先在 goal 约定 `STEERING.md` 轮询，或 teardown 后重派。
   - TUI：`dispatch send` 的 WORKING/busy 确认环只证明“指令开始被处理”，不证明完成或正确。
   - 真需要即时纠偏的任务，从一开始选 TUI；现有 EXEC session 不能原地切 lane。每个后续 round 都重新挂 `watch`。
6. **Implemented → Verified**：必须同时有 fresh 正向交付证据、不同 lineage 的独立评审、真实用户路径 E2E。先本机真路径，再部署，再部署环境 E2E，最后才关单；git 集成与 push 门禁归 Git workflow 标准。

## 2. 对抗式评审循环

- 按风险定深度：低风险走轻量 review；鉴权、迁移、基建、大重构走 `references/review-dispatch.md` 的完整循环。
- brief 冷上下文，不喂实现者结论；激进找问题，出口用 file:line、confidence 与失败探针过滤。
- 先枚举执行分叉，并点名 `缺失消费者`、under-fire、并发 / 恢复等高风险轴；完整轴表留在 reference。
- 只有 blocking 驱动续轮；advisory 转 follow-up，同一 finding 重复出现则收敛或升级人工，不无限对轰。
- 多轮 headless review 显式传 `--workflow review-loop --max-rounds N`；轮数与 stop-loss 只认 runtime meta，主干不复制状态机。
- 评审期间执行 agent 不写同一 worktree。

## 3. 实现与验证判据

- **先量再改**：先证 bug 当前可复现、怀疑机制真是绑定约束、执行真到该路径；未证先补观测，不发投机修复。
- **病类确认后枚举同模式点**：逐一分类，一轮收敛，别等评审逐个显形。
- **否定性结论先校准检测链**：用 known-positive 证明看得见 X；否则保持 `UNKNOWN`。
- **代验不冒充真验**：不 mock 正在验证的边界；交付明确写已验证、未验证与剩余风险。

具体旗标、stale-edit、验证顺序与失败模式按需读 `references/implementation-discipline.md`。

## 4. 不可达环境

够不着 prod / 独立 dev DB 时不猜、不直接改：用 `references/ops-prompt-template.md` 写自包含只读取证提示词。现场证据优先于 HEAD 推断；矛盾时先核部署 SHA / 构建漂移。

## 5. 状态、收口与主理人注意力

- `docs/orchestration/` 是共享 SoT：live 只留在跑/在等事项，完结物归档；memory 只存编排者私有教训和入口，不替代共享 docs。
- runtime evidence 推翻 audit/scout 时，同轮回写源文档 `REFUTED CLAIMS`（claim / evidence / pointer），不只记在摘要。
- 外部任务系统存在时，它是状态 SoT；roadmap 只做映射，不养第二套账。
- 收口 / 压缩前 / ReOpen 后读 `references/retrospective.md`，再跑 `references/retro-check.sh`。脚本只覆盖机械代理与 warning，不能替代语义复盘；同时清理已完成会话和孤儿进程。
- 主理人只决战略、不可逆、钱与价值。决策队列、T0/T1/T2 语义和静默默认见 `references/decision-queue.md`；队列只存活跃项，已清残留由 hook 提醒 + retro 硬失败，新鲜度仍是软告警。

## 6. 专项路由（用到才读）

| 场景 | Reference |
|---|---|
| 新项目接入 | `references/onboarding-checklist.md` |
| 前端真实验证、状态形状矩阵、浏览器委派 | `references/frontend-verify.md` |
| 评审 brief、ledger、收敛 | `references/review-dispatch.md` |
| 基线与收工四件套 | `references/dispatch-baseline.md` |
| watcher、EXEC/TUI、steering、guard wiring | `references/agent-watch/README.md` |
| 主理人决策队列 | `references/decision-queue.md` |
| 项目 AGENTS.md 编排增量 | `references/agents-md-orchestration-section.md` |

多个编排者并行时，用可选伴随 skill `agent-mail` 做跨席位异步通信。
