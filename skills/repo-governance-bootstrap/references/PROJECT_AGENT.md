# Project Engineering Constitution

> 项目级工程治理规则。全局 agent 配置（如 Claude Code 的 `~/.claude/CLAUDE.md`、Codex 的 `~/.codex/AGENTS.md` 等）已涵盖：人格 / 通信 / 反 sycophancy / Agency 按可逆性分配 / 验证诚实性 / 工具偏好。本文件**仅补充**项目长期演化所需的架构治理约束。
>
> **启用条件**：本项目存在 ADR / roadmap / module docs / module evolution 等长期治理脚手架（或正在建立）。一次性脚本、原型、个人小工具不要套这套。
>
> **使用方式**：在项目根目录另存为 `AGENTS.md`（Codex 直接读；Claude Code 通过同目录的 `CLAUDE.md` 写一行 `@AGENTS.md` 导入；其他 agent 按其根级 instructions 文件约定）。按项目实际路径替换 ADR / docs 位置。

---

## 1. Source of Truth 优先级

发生架构冲突时按以下优先级判断（高 → 低）：

1. ADRs：`docs/decisions/`（按项目实际路径调整）
2. Module architecture docs
3. Module evolution docs
4. Active roadmap
5. Inline TODOs

实现代码是**现实证据**，但**不是架构权威**。

冲突处理：
- 不默认代码正确，不默认 ADR 过时。
- 显式指出冲突 → 说明影响 → 给路径建议（改代码 / 改文档 / 新增 ADR），不静默 override。

---

## 2. 三档工作模式

每个任务进入以下三档之一，使用**最低必要**档。与全局 agent 规则的"按可逆性分配 agency"叠加——可逆 = DO，重大但可逆 = THINK，不可逆 = REQUIRE APPROVAL。

### DO（直接做）

全部满足：模式已知 / 改动局部 / 不动 public contract / 不动 security boundary / 不创建新 subsystem / 不引入新 framework / 不涉及 schema 或 migration。

### THINK（先分析再决定）

任一触发：架构变化 / 多模块影响 / 重大 tradeoff / 新基础设施 / 服务边界变化 / migration / 可能创建平行系统 / 可能与 ADR 冲突。

输出最少包含：目标、相关 source of truth、影响范围、风险、tradeoff、计划、验证方式。THINK 不等于必须审批——分析完可以决定继续 DO。

### REQUIRE APPROVAL（先停，等放行）

任一触发：destructive migration / 删 major module / security boundary 变更 / auth model 变更 / prod config 变更 / force push 或 history rewrite / secrets 处理变更 / 大规模跨模块 refactor / 替换既有架构方向 / 创建新平台能力或跨模块抽象。

未获明确 approval 不实施。

---

## 3. 模块边界：FOR / NOT FOR

每个重要模块必须有 FOR / NOT FOR 声明（位于模块 README 或 architecture doc）：

```md
FOR:
- <负责的 capability>

NOT FOR:
- <明确不负责的事>
```

新增功能前判断它属于 FOR 还是 NOT FOR。
落入 NOT FOR → 不要直接加入该模块，先架构讨论。

---

## 4. Capability vs Component

新增 component 前必问：

- 这是新 capability，还是已有 capability 的变体？
- 能否演化已有组件？
- 是否重复已有抽象 / 创建 parallel system？
- ownership 是否清晰？
- 是否有 ADR 或 roadmap 支撑？

默认**演化已有组件**，不默认建新组件。component-per-feature 是反模式。

---

## 5. 状态词汇（两套独立）

按文档类型选用对应词汇，**不要互换**。

### ADR Status（决策生命周期，Nygard 4 态）

`proposed` / `accepted` / `deprecated` / `superseded`

- `proposed`：起草中，未决
- `accepted`：已生效
- `deprecated`：不再生效，无替代
- `superseded`：被另一 ADR 替代（必须注明替代者，如 `superseded by ADR-0012`）

未被接受的 proposal **不留文件**——没有 `rejected` 态。

### Roadmap / Evolution Status（计划生命周期，6 态）

`proposed` / `active` / `deferred` / `obsolete` / `rejected` / `completed`

- `proposed`：起草，未启动
- `active`：进行中
- `deferred`：暂停但打算回来做
- `obsolete`：不再相关（情况变了）
- `rejected`：明确决定不做
- `completed`：做完

计划失效时：标 `obsolete` 或 `rejected` + 写明原因。**禁止无声删除历史**。

---

## 6. 文档治理

- 所有未来计划必须挂靠到：module / ADR / roadmap item / tracked issue / module evolution section。
- 禁止：孤立 TODO 文档 / generic TODO dump / disconnected planning docs / 没有 owner-status-rationale 的长期计划 / 随意 `ideas.md`。
- 局部 TODO 可以存在，但非平凡 TODO 应关联 owner / issue / ADR / roadmap。
- 架构变化时同步更新：ADR / module docs / module evolution / roadmap status / relevant code comments——
  **与代码同一 commit**，别攒批（攒批 = 文档与代码从此各自漂移）。
- 未来工作管理: 新增或更新 docs/roadmap/deferred/README.md 作为该目录的索引
- 每个重要的延期项应单独存放在 docs/roadmap/deferred/*-DEFER-*.md 文件中

**文档生命周期（anti-rot）**：

- `ACTIVE_CONTEXT.md` 是**快照不是日志**：每次工作收口**整篇重写**而非追加，~60 行上限；"Recent Decisions" 只留最近 3–5 条，更早的进 git history / ADR；已完结工作的过程细节归档、不留快照里。文件头部写明这条契约。
- **已完结工作文档归档**：`docs/` 下交付或废弃的 plan / 调研 / 评审记录移入 `archive/` 并加一行索引，live 区只留在跑 / 在等的；文档只生不死 → live 与历史混杂、无法区分。
- **收口三同步（缺一即腐烂）**：归档完结文档 + 重写 `ACTIVE_CONTEXT.md` 快照 + 翻转 roadmap 状态，三者同级同步做。


---

## 7. Code Traceability

以下场景在代码中标注来源（ADR ID / roadmap item / issue ID）：

- architectural constraints
- security boundaries
- migration logic
- compatibility behavior
- 非显然 tradeoff
- 临时例外 / deprecated path

示例：
```go
// ADR-0007: pricing must remain deterministic
```

显然的代码不加注释。注释保存**长期架构记忆**，不复述代码本身。

---

## 8. Engineering Gate

后端仓库只暴露一个 repo-owned 稳定接口（实际启用 profile/module root 在初始化时写在本节）：

```bash
bash scripts/engineering-gate.sh fix
bash scripts/engineering-gate.sh check
bash scripts/engineering-gate.sh test
```

- `fix` 会改文件，显式运行、review diff、重新 stage；pre-commit 只跑 non-mutating `check` + local `test`。
- CI 调同一 wrapper，并运行语言原生全量收口；本地 hook 可被 `--no-verify` 绕过，不替代 required CI。
- 工具/plugin 版本固定在 repo config/lockfile/wrapper/toolchain；不得依赖开发机偶然 PATH。大仓若用 focused local test，实际范围必须写在本节，CI 仍全量。
- 被门禁阻断时按输出的 Failed / Fix / Retry 操作；规范入口：
  `agent-backend-standard/references/engineering-interface.md`，边界类型细则只见
  `observability-standard/references/standard.md §2`。

---

## 9. 完成标准（项目级补充）

在全局 agent 规则的"验证诚实性"基础上，非平凡改动还要说明：

- 涉及的 ADR / roadmap / issue（traceability）
- 是否触动 FOR / NOT FOR 边界
- 是否需要新增或更新 ADR
- 是否需要更新 module evolution status

行为或架构变化时同步更新文档，未更新需明示。
