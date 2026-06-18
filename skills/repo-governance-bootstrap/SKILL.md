---
name: repo-governance-bootstrap
version: 1.0.0
description: 一次性初始化适合 AI 协作开发的轻量工程治理骨架（docs/INDEX、ADR、module、roadmap、ACTIVE_CONTEXT、AGENTS.md / CLAUDE.md）。新仓库 / 文档结构混乱 / 项目内文档治理初始化时调用。【定位】独立可用、不需要多 agent 编排；也是 cto-orchestration 新项目接入的第一步，但小项目只做文档治理时单独用即可。一次性建结构，区别于循环跑的 cto-orchestration。
---

# Repo Governance Bootstrap

## 何时调用

用户说出以下任一：
- "初始化文档治理 / 项目治理 / repo governance"
- "建立 ADR / roadmap / 文档骨架"
- "新仓库接入 AI 协作"
- "整理混乱的 docs 目录"

**跳过条件**：仓库已有 `docs/INDEX.md` 和 `docs/ACTIVE_CONTEXT.md` → 提演化方案、不重新初始化；绝不覆盖既有治理文件。

## FOR

- 新仓库初始化
- 引入 AI coding workflow
- 重构混乱 docs 结构
- 建立长期演化管理

## NOT FOR

- 重型流程管理 / Jira / RFC 工作流
- 复杂审批体系
- 外部 wiki 替代 Git
- 创建 `future_plan.md` / `ideas.md` / generic TODO dump

---

## 目标结构（最小）

```text
docs/
├── INDEX.md
├── ACTIVE_CONTEXT.md                 # 当前焦点 / hot context
├── decisions/
│   └── ADR-0001-<slug>.md            # 仓库边界（ADR 编号固定 4 位）
├── modules/
│   └── <module>.md                   # 每个核心模块一个 flat 文件
└── roadmap/
    ├── README.md                     # status-bucket 索引（Active / Deferred / Obsolete）
    ├── active-roadmap.md             # 单文件，inline Status
    ├── deferred/
    │   └── README.md                 # deferred 索引（Items 表 + Entry Criteria + Promotion Rule）
    └── obsolete/
        └── README.md                 # obsolete 索引（仅索引，少用）

AGENTS.md                             # repo 治理规则（Codex 读）
CLAUDE.md                             # 一行：@AGENTS.md（Claude 读）

ACCESS.local.md                       # gitignored — 本机接入凭证 + 环境拓扑 + 验证配方
```

### 约定原则

- **Roadmap 初始化即建三桶**：`active-roadmap.md`（单文件，inline `Status:`）+ `deferred/` + `obsolete/`（各带 `README.md` 索引）。active 保持单文件——item 内联，逐项拆文件无收益；deferred 项内容厚，一项一文件 `<PREFIX>-DEFER-NNN-<slug>.md`。`<PREFIX>` = 项目自定义 ID 前缀，按项目名取（不要硬编码他人前缀）。
- **Module docs 默认单文件** `modules/<m>.md`。模块复杂到 README + architecture + evolution 各需独立维护时再拆成 `modules/<m>/{overview,architecture,evolution}.md`。
- **ADR 编号固定 4 位零填充**（`ADR-0001`、`ADR-0014`），全仓一致。
- **不创建 generic backlog**（`future_plan.md` / `ideas.md` / TODO dump）；未来工作进 `roadmap/deferred/`。
- **ACTIVE_CONTEXT 是快照不是日志**：完整契约见 `references/PROJECT_AGENT.md §6`（canonical，随成品写进项目 AGENTS.md）+ 下方「ACTIVE_CONTEXT.md 模板」的契约头。核心 = 每次收口**整篇重写**而非追加。实证（why）：某项目 ACTIVE_CONTEXT 被当 checkpoint 日志逐条 append，4 天涨到 190 行后整体冻结腐烂。
- **外部任务系统优先**：若程序任务已在外部系统跟踪（Jira / Linear / 飞书 bitable 等），roadmap 是**映射层**不是第二任务系统——沿用外部 ID（如 T-NNN），在 roadmap README 和 AGENTS.md Traceability 里写明外部 SoT；只给外部系统没有记录的仓库内部项造 RD 号。两套任务账本必烂一套。
- **接入凭证与操作配方进 `ACCESS.local.md`（gitignored）**：committed 治理骨架（INDEX/ADR/module/roadmap/ACTIVE_CONTEXT）回答 what/why，全部不含 secret；它们缺的那一块——"怎么真正连上、登录、验证运行中的系统，以及连上用的凭证"——落在一份 **gitignored 的 `ACCESS.local.md`**，三段式：① 接入凭证（URL/账号/token/cred）② 环境拓扑速查（部署布局/tenant id/env flags/调用路径）③ 验证配方与 gotcha（E2E 验收步骤、调试踩坑）。它是 `ACTIVE_CONTEXT.md` 的本地含密镜像兄弟（committed=what，local=how-to-reach），是新会话/新 agent 摸到系统的入口。**凭证口径必须一致**：canonical home 是外部 vault（如团队密钥库），此文件是本机缓存，靠 gitignore + 提交前 redaction sweep 兜底；secret 永不进 committed tree / traces / 对外消息。建文件即把 `ACCESS.local.md` 写进 `.gitignore`。
- **治理目录值得 local-only git 化**（尤其多子 repo 的 umbrella——目录本身套着各有 remote 的子 repo、自己不是 git repo）：把 `docs/` + 治理文件纳入一个**无 remote 的本地 git**、gitignore 掉子 repo，换来文档变更历史、误删恢复、agent 派工后的 `git diff` 漂移审计。orchestration docs 一旦成为多 agent 并发写的 SoT 尤其值得（实证：曾发生 agent 误删关键 docs、无版本可恢复）。加 remote 前先做一次 secrets sweep（内网 IP/库名/拓扑也算敏感面），并在 AGENTS.md 写明这条。多 agent 编排场景配合 `cto-orchestration` skill。

---

## 执行步骤

1. **询问用户**（如果未提供）：
   - 项目名 / 一句话定位
   - 核心 capability（≤3 个）
   - 核心 module 名（≤3 个）
   - 是否需要 AGENTS.md（推荐：是，串联 Codex + Claude）

2. **创建目录骨架**：`docs/decisions/`、`docs/modules/`、`docs/roadmap/deferred/`、`docs/roadmap/obsolete/`（roadmap 三桶一次建好）。

3. **生成 `docs/INDEX.md`**：含 Decisions / Modules / Roadmap / AI Context 四节 + Traceability 表（`| Capability | Component | ADR | Roadmap |`）。

4. **生成 `docs/decisions/ADR-0001-<slug>.md`**：用下方 ADR 模板，主题是"仓库定位与边界"——记录这个仓库 FOR 什么 / NOT FOR 什么。Status: `proposed` 起步，由用户后续确认为 `accepted`。

5. **生成 `docs/modules/<m>.md`**：每个核心模块一个文件，含 FOR / NOT FOR / Components / Evolution 节。

6. **生成 roadmap**：`roadmap/README.md`（三桶索引）+ `roadmap/active-roadmap.md`（≥1 item，每项含 `Status` / `Capability` / `Components` / `ADR` / `Acceptance Criteria`）+ `roadmap/deferred/README.md`（空 Items 索引 + Entry Criteria + Promotion Rule）+ `roadmap/obsolete/README.md`（空索引）。

7. **生成 `docs/ACTIVE_CONTEXT.md`**：当前焦点 + 在跑/在等的 workstream 表 + standing constraints + recent decisions（最近 3–5 条）。按"约定原则"的快照契约生成，头部带契约声明（见下方 ACTIVE_CONTEXT 模板）。

8. **生成 `AGENTS.md`**：以 `references/PROJECT_AGENT.md`（中文成品宪法）为准落地，按其章节：Source of Truth 优先级 / 三档工作模式 / 模块边界（FOR / NOT FOR）/ Capability vs Component / 状态词汇 / 文档治理（已含**文档生命周期 anti-rot**：ACTIVE_CONTEXT 快照契约 + 收口归档仪式）/ Code Traceability / 完成标准。工具偏好若全局 agent 配置未覆盖项目特定项（如子仓库 toolchain）再补。**Redaction 边界**写明一条：secret/凭证只进 `ACCESS.local.md`（gitignored）与外部 vault，永不进 committed tree / traces / 日志 / 对外消息——避免 AGENTS.md 里 "creds never in repo tree" 与本机存明文凭证的口径自相矛盾。

9. **生成 `CLAUDE.md`**：单行 `@AGENTS.md`。

10. **生成 `ACCESS.local.md` stub 并写进 `.gitignore`**：用下方「ACCESS.local.md 模板」建三段式骨架（接入凭证 / 环境拓扑 / 验证配方），字段留空待用户填实；同步在 `.gitignore` 加 `ACCESS.local.md` 一行（带注释说明含 creds、永不提交）。**绝不**把真实凭证写进 stub。

11. **完成时报告**：列出已建文件 + 用户下一步建议（填实 ADR-0001 内容 / 完成首个 module 的 FOR-NOT FOR / 把第一个 roadmap item 标 `active` / 在 `ACCESS.local.md` 填本机接入凭证与验证配方）。

---

## 状态词汇

两套词汇**独立、不可互换**：ADR 4 态（Nygard）/ Roadmap 6 态。完整定义见
`references/PROJECT_AGENT.md §5`（canonical——它随成品写进项目 AGENTS.md，必须自包含）。
生成 ADR / roadmap 时按那里取值，本 skill 不复述全文，只守一条易错点：**别把 ADR 的
`accepted` 安到 roadmap 上、别把 roadmap 的 `active/completed` 安到 ADR 上。**

---

## ADR 模板

> 编号 4 位零填充（`ADR-0001`、`ADR-0014`），全仓一致；起步 ADR 主题为仓库边界。

```markdown
# ADR-NNN: <Title>

Status: proposed

Date: YYYY-MM-DD

## Context
<the problem / forces>

## Decision
<what we decided>

## Consequences
<positive / negative / future evolution>
```

## 模块文档模板

```markdown
# Module: <name>

## FOR
- <capability A>

## NOT FOR
- <explicitly out of scope>

## Components
- `<path/to/component>`

## Evolution

### Active
- <item> — Status: active

### Deferred / Obsolete
- <item> — Status: deferred — reason
```

## Roadmap 条目模板

```markdown
## <ID>: <Title>

Status: proposed

Capability: <capability>

Components:
- `<path>`

ADR: <ADR-NNN or TBD>

Acceptance Criteria:
- <criterion>
```

## Deferred 延期条目模板

ID = `<PREFIX>-DEFER-NNN`（`<PREFIX>` 为项目自定义前缀，如 `AAM` / `PAY`）。一项一文件存 `roadmap/deferred/<PREFIX>-DEFER-NNN-<slug>.md`，并在 `roadmap/deferred/README.md` 索引。

```markdown
# <PREFIX>-DEFER-NNN: <Title>

Status: deferred

Priority: P2

Capability: <capability>

Components:
- `<path>`

Related ADRs:
- <ADR-NNN>

## Problem
<why it matters; kept across sessions>

## Proposed Direction
<approach>

## Non-goals
- <out of scope>

## Acceptance Criteria
- <criterion>

## Validation Plan
- <how it is verified>
```

## Deferred 索引模板（`roadmap/deferred/README.md`）

```markdown
# Deferred Roadmap

Future work accepted for tracking but not in active scope. Index instead of a generic backlog.

## Items

| ID | Priority | Status | Title | Components |
| --- | --- | --- | --- | --- |
| <PREFIX>-DEFER-001 | P2 | deferred | [<Title>](./<PREFIX>-DEFER-001-<slug>.md) | <components> |

## Entry Criteria

- 问题真实、需跨会话保留
- 不应扩张当前 active plan
- 有明确 owner component + acceptance criteria
- 不是某文件内的局部 TODO

## Promotion Rule

延期项转 active 时，在架构 plans 目录建具体 plan，保留链接，状态改 `active`，完成后改 `completed`。
```

## ACTIVE_CONTEXT.md 模板

```markdown
# Active Context — <project>

Last rewritten: YYYY-MM-DD

> **This file is a SNAPSHOT, not a journal.** Rewritten (never appended) at every
> workstream close, capped at ~60 lines. History lives in git; closed-workstream
> detail is archived. This is the entry point for any agent/session without the
> orchestrator's private memory.

## Current Focus
<one workstream, its single blocker, its next step>

## Live / Waiting Workstreams
| Workstream | State | Waiting on |
| --- | --- | --- |

## Standing Constraints
- <rules that outlive any single workstream>

## Recent Decisions (last 3–5 — older: git history / ADRs)
- YYYY-MM-DD — <decision>
```

## ACCESS.local.md 模板

> **gitignored，永不提交/推送。** 含明文凭证，只在本机做快速反查。生成时字段留空待用户填，
> stub 里绝不写真实 secret。凭证 canonical home 是外部 vault，此文件是本机缓存。

```markdown
# <项目> 接入与访问（仅本机 — 已 gitignore，永不提交/推送）

> 此文件含凭证/环境/访问信息，供本机快速反查。**任何内容都不得**粘进 committed 文件、
> 子仓库目录、traces、日志或对外消息。凭证 canonical home = 外部 vault；这里是本机缓存。

## ① 接入凭证
- **<环境名>**：`<登录 URL>` → 登录 → 选 `<租户/项目>`。
  - 账号：`<account>`；密码：`<password 或"见 vault">`。
  - token / cred 获取方式：`<如何拿到，例如 localStorage.token / vault 路径>`。

## ② 环境拓扑速查
- 部署布局：`<monorepo / 多服务 / 前后端目录>`。
- 关键 id：`<tenant id / project id / 资源 id>`。
- env flags：`<影响行为的开关>`。
- 调用路径：`<请求怎么走到目标代码——关键分叉点 file:line>`。

## ③ 验证配方与 gotcha
- **E2E 验收 recipe**：`<最小可复现的"摸到运行系统并确认生效"步骤>`。
- **调试踩坑**：`<本机/工具/环境特有的坑 + 绕过办法>`。

## 构建 / 工具
- `<本机构建、测试、跑服务的实际命令>`。
```

## INDEX.md 模板

```markdown
# Documentation Index

This index maps the repository source of truth.

## Decisions

- [ADR-0001: <Title>](decisions/ADR-0001-<slug>.md)

## Modules

- [<module>](modules/<module>.md)

## Roadmap

- [Active Roadmap](roadmap/active-roadmap.md)
- [Deferred Roadmap](roadmap/deferred/README.md)

## AI Context

- [Active Context](ACTIVE_CONTEXT.md)

##
| Capability | Component | ADR | Roadmap |
| --- | --- | --- | --- |
| <capability> | `<path>` | ADR-0001 | <ID> |
```

---

## Success criteria

完成后：
- `docs/INDEX.md` 单文件即可定位所有 source of truth
- 至少 1 个 ADR，记录仓库边界（Status 为 proposed 或 accepted）
- 至少 1 个 module 有 FOR / NOT FOR
- Active roadmap 至少 1 个 item
- `AGENTS.md` + `CLAUDE.md` 生效，agent 进入新对话能识别上述结构

## After bootstrap

完成后告诉用户：

- 日常开发由 `AGENTS.md` 管理（Source of Truth 优先级 / 状态词汇 / 三档工作模式 / 等）
- 新决策走 ADR，新计划进 roadmap，过时计划标 `obsolete` / `rejected` 不删
