# 治理产物模板（bootstrap 步骤 4-10 用）

> 主干只留步骤与判据；所有生成物模板在此。目录：
> [ADR](#adr-模板) · [组件引入 ADR lifecycle 变体](#组件引入-adr-变体lifecycle) · [模块文档](#模块文档模板) ·
> [Roadmap 条目](#roadmap-条目模板) · [Deferred 条目](#deferred-延期条目模板) · [Deferred 索引](#deferred-索引模板roadmapdeferredreadmemd) ·
> [ACTIVE_CONTEXT](#active_contextmd-模板) · [ACCESS.local](#accesslocalmd-模板) · [INDEX](#indexmd-模板)

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

### 组件引入 ADR 变体（lifecycle）

引入**重依赖 / 重组件**（数据存储 / MQ / 缓存 / 搜索 / 新外部服务 / 新能力类别）的 ADR，在基础模板上**增 `Owner` / `Sunset Criteria` / `Review-by` 三段**——记录"何时该退役"，防止引入后无人清理、沦为死基础设施。这是 ADR 天然该承载的槽，bootstrap 直接建。

```markdown
# ADR-NNN: 引入 <组件>
Status: accepted
Date: YYYY-MM-DD
Owner: <谁负责其存续与退役>

## Context
<问题 + 为何 stdlib / 现有依赖不够；评估过的替代方案>
## Decision
<引入什么；如何 wrap behind interface 保持可替换>
## Sunset Criteria（退役判据）
- <什么条件下应被移除：依赖它的 X 特性下线 / 长期 QPS < N / 被 Y 替代>
## Review-by
- YYYY-MM-DD（到期必须复审：仍需要？可降级/移除？）
## Consequences
<运维成本 / 锁定风险 / 退役难度>
```

> 更细的 lifecycle 规则（重组件阈值 / wrap-behind-interface / 情境绑定 hardcode 与 prompt 的 `EXPIRES`·`REVISIT-WHEN` 内联过期标记 / 配套 CI 门禁）见 `agent-backend-standard` 附录 A；本骨架不重复、只建 ADR 这个槽。

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

### 外部服务 / 模型 endpoint（每个被认证调用的依赖一条：LLM 网关 / DB / 第三方 API）
- **<服务名>**：endpoint `<base url / host>`；auth header `<如 api-key / Authorization / Ocp-Apim-Subscription-Key>`；
  模型/部署/库名 `<model / deployment / db>`。
- **凭证间接（必记）**：cred 实际存在 env 变量 `<X，如 VENDOR_APIM_KEY>`，但代码读的是 `<Y，如 LLM_API_KEY>`
  —— **桥接** = `<如启动时 Y="$X" 进程 env 覆盖 .env；或 vault→Y 注入>`。
- **参数 gotcha**：`<如 gpt-5.x 用 max_completion_tokens 非 max_tokens；某 API 必带 version>`。

## ② 环境拓扑速查
- 部署布局：`<monorepo / 多服务 / 前后端目录>`。
- 关键 id：`<tenant id / project id / 资源 id>`。
- env flags：`<影响行为的开关>`。
- 调用路径：`<请求怎么走到目标代码——关键分叉点 file:line>`。

## ③ 验证配方与 gotcha
- **E2E 验收 recipe**：`<最小可复现的"摸到运行系统并确认生效"步骤>`。
- **活体 auth smoke（依赖建在它之上前先验，别等彩排）**：`<最小 curl/调用，打印 HTTP 码>`。
  **读失败模式**：401/403 = 凭证/header 错；**400 参数错 = 凭证其实通了**（已过认证到参数校验）；
  404 = base_url/路径/model 错。区分清楚才知道改 key 还是改配置。
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

## Traceability
| Capability | Component | ADR | Roadmap |
| --- | --- | --- | --- |
| <capability> | `<path>` | ADR-0001 | <ID> |
```
