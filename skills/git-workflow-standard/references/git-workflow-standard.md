# Git Workflow Standard — 完整版

> 本文件是 `git-workflow-standard/SKILL.md` 的全量镜像 + rationale。规则两层同源,改一处同步另一处(AGENTS.md 纪律)。
> 软/硬双层分工见下 §0;集成策略 per-repo 在各仓 AGENTS.md 声明。

## 0. 双层模型

| 层 | owner | 形态 | 作用 |
|---|---|---|---|
| 软层 | 本 SOP | agent-facing SOP | write-time 预防、教学、对接缝声明 |
| 硬层 | 你的 IaC 仓 / IaC CTO | GitHub Ruleset / CODEOWNERS / required checks | 三档 tier 渐进强制,绕不过 |

**为什么两层**:skill 文本随长对话 salience 衰减;纯声明机制无 forcing function 会腐烂。**不可逆动作(直推受保护分支、force push 改写历史)的最终防线必须是硬层**;skill 让 agent 不去撞墙,Ruleset 是墙。

## 1. 硬门禁契约（服务端已生效；对接缝）

canonical 定义在 你的 IaC ruleset,本 skill 只镜像行为契约;具体仓的 enrollment 以 IaC 为准。硬层内部分三档:

**Tier 1 baseline(所有仓,含未来仓)** —— 地板,装即生效:
- Block force pushes、Restrict deletions(仅此两条)。
- **不要求 PR、不禁 merge-commit、不强制 linear history** → 小仓 / 文档仓可直推、直接合。

**Tier 2 PR gate(显式白名单)** —— PR 合入地板:
- Require a pull request before merging + Block force pushes + Restrict deletions。
- 平台默认 `required_approvals=0`,允许作者 self-merge。
- 不统一强制 CODEOWNERS review / last-push approval / conversation resolution / linear history / status checks;跨人评审是建议,除非 repo-local gate 显式升格。

**Tier 3 required CI(单独显式 enrollment)** —— 在 Tier 2 上叠加 CI 硬门:
- Require status checks to pass;仅显式接入的仓生效。
- aggregate check **MUST always-report**:即使上游失败 / cancelled / skipped,也必须产出明确终态,避免 required check 永久 pending。

**原则:能发布 artifact 的仓必须被保护**——受保护分支集 = 受保护分支白名单 `main` / `master` / `develop` / `dev` / `release/**` / `project/*`。

**集成策略边界**:**merge-commit 弃用、默认 squash**(见 §4)是本 SOP 约定,不是 Tier 2 服务端强制;repo-local 如需 linear history,应在本地门显式声明并强制。

**仓的 tier 归属以 你的 IaC ruleset 为准**;本规范仓走 Tier 1。

## 2. 分支模型

- **业务/受保护分支**:`main`/`master`、`develop`/`dev`、`release/**`、`project/*`(项目集成分支,如 `project/example`)。**Tier 2 / Tier 3 仓:只接受 PR 合入**(Tier 1 仓可直推,仅禁 force-push/删分支)。受保护集 = ACR 出镜像放行集;canonical 定义在 你的 IaC 仓(三档 tier ruleset)。
- **工作分支**:`<type>/<slug>`,`type ∈ {feat, fix, chore, docs, refactor, test, perf}`。从最新 base 起,开发者在自己分支上自由 commit / rebase / force-with-lease。

## 3. rebase 是条件动作,不是仪式

被混叫"rebase"的其实是两件独立的事:① **跟上 base**(合前要不要挪到最新主干)② **集成策略**(怎么并回,§4)。本节只讲 ①。

```bash
git fetch origin
git log <branchpoint>..origin/<base>   # 空 = base 没动
```

- **base 没动 → 什么都不做**。空 rebase 是 no-op,**"没看到 rebase 命令" ≠ "漏了步骤"**(这是反复被误解的点)。
- **base 动了且碰了你改的文件 → rebase 或把 base merge 进来**解冲突,再 PR。
- **base 动了但文件不重叠 → 可不动**(合并自然干净)。
- **并发会话**:base 可能在你 cut 和 merge 之间被别的 PR 推进——所以 `fetch`+检查**必做**;但"检查"≠"每次都 rebase"。若 repo-local 门明确要求 branches up to date,合前还会再卡一次。

## 4. 集成策略（默认线性,2026-06-25 全 agent 修订）

**默认 squash**;可选 **rebase-merge**(同为线性)。**merge-commit 不是 sanctioned 选项。**

| 策略 | 何时选 | 取舍 |
|---|---|---|
| **squash**(默认) | 绝大多数仓 | 线性、每 PR 一个原子全绿 commit、一键 revert、bisect 友好;糊掉 PR 内 WIP 轨迹(对 agent 是噪声,无损) |
| **rebase-merge** | 偏好保留 PR 内分块 commit 且要线性 | 线性、无 merge bubble;别 rebase 已共享分支(rebasing 黄金律) |
| ~~merge-commit~~ | —— | **弃用**(理由见下) |

**为何全 agent 下弃 merge-commit**(2026-06-25 重定调研):
- merge-commit 唯一卖点是"给人读的修复故事";**公司全 agent 开发、无人读 git 历史** → 该论点蒸发(pro-history 倡导者自述其价值是看"一个**人**做了什么")。
- agent **确实用历史**(Code Researcher ablation:删 commit-history 检索 → 成功率↓),但有用的是**逻辑成块 + 好 message 的 commit**(= squash 产物);WIP/"改评论" churn 是 context 污染、降 bisect 分辨率。
- agent commit 量爆炸(~275M/wk)下,squash 把每个 PR 收成一个可读节点,主线 `git log --first-parent` 才 legible。
- **对抗评审的知识**(约束/被否方案)落 **ADR + PR 记录 + commit trailer**(`Constraint:`/`Rejected-alternative:`),不进 commit graph —— squash 丢 exhaust 不丢 knowledge。
- **诚实边界**:emerging、无对照实验;结论 = git 机制 + 一个 ablation + 实践共识 + merge-commit 论点结构性坍塌。

> bisect 健康 = **每个 commit 都绿** + `--first-parent`;squash 让主线全绿,正是 agent 驱动 bisect 要的(merge 的中间 commit 可能红,descend 进 bubble 就踩坑)。

trivial 单 commit PR 直接合。默认线性是 SOP 约定;Tier 2 本身不强制 linear(见 §1)。

## 5. PR 流程

- PR 描述讲清 **what / why**(不复述 diff)。
- Tier 3 等 **required checks 绿**再合;review / CODEOWNERS 等仅在 repo-local gate 已升格时是阻断条件,否则跨人评审只是建议。
- 合并方式 = 本仓声明的集成策略(§4)。
- 合后删 head 分支(硬层可设自动删)。

## 6. 提交信息纪律

- 讲清意图;祈使句、简洁。
- **MUST NOT 加任何 AI / Claude 签名行、co-authored-by 之类**(公司纪律,全局亦然)。
- squash 策略下 PR 内可留过程 commit(合并时折叠为一个原子 commit);rebase-merge 策略下保留有意义的分块 commit、清掉纯噪声("wip"/"fix typo")。

## 7. force push 边界

- **受保护分支永不 force**(硬层 block,agent 也不该尝试;rebasing 黄金律:绝不改写已共享的历史)。
- 自己的工作分支可 force,优先 `git push --force-with-lease`(防覆盖他人推送)。

## 8. 安全

- 提交里 **MUST NOT 出现 secret / 凭证 / 内网拓扑**;凭证只进 gitignored 的本地访问文件 + 外部 vault(呼应 `observability-standard` 边界类型纪律 + AGENTS.md redaction 边界)。

## 9. 与其他 skill 的关系

- 编排者多 agent 派工的 Git 纪律细化见 `cto-orchestration`(编排视角);本 skill 是面向所有研发的通用 SOP。
- 依赖 / 重组件引入的 PR 还要走 `agent-backend-standard` 附录 A(引入门禁 + 退役判据)。

## 10. Local-first final-image Docker E2E 与 CI single-build

- 产品仓库 MUST 声明 Docker 构建与运行输入、包定义与锁文件、workspace 配置、发布 workflow 等 critical paths。开发者机器上的 `pre-push` 仅在这些已声明路径有变更时触发，触发后 MUST 在本机构建该产品**正式（final）应用镜像本体**（不是跑 host 测试，也不是构建代测/mock 镜像），并在该镜像**内部**执行完整的 E2E/smoke 断言；未命中已声明路径时 MAY 跳过。该检查是 push 前硬门——E2E 失败 MUST 阻断本次 push（fail-closed），不得降级为警告或静默放行。
- 已声明的 critical paths 存在未提交改动时 MUST fail closed。成功的本地验证 MAY 按“目标 commit + E2E contract digest + base-image digest”指纹缓存；任一组成变化即不得复用。
- 本地 hook 不是唯一安全边界；`git push --no-verify` 始终可能绕过 `pre-push`，remote CI MUST 独立执行并强制该契约。
- remote release CI 的职责是：校验交付契约、只构建一次 final image，推送后取得其不可变 digest，并对该 exact pushed digest 执行 layer、entrypoint 与 runtime smoke（镜像内轻量启动/导入检查，不是完整 E2E）；全部通过后才可放行 GitOps write-back。remote MUST NOT 执行产品仓库声明的本地 `docker_e2e_command`——完整 E2E 只在开发机的 `pre-push` 跑。runtime smoke（远端、轻量、绑定 pushed digest）与本地 final-image Docker E2E（本地、完整、pre-push 硬门）是两个不同的门，措辞与语义不可混用。
- 产品仓库只负责项目命令、critical-path 声明与项目 smoke 断言；可复用的平台 tooling 负责 hook/install/cache 机制及 single-build/exact-image workflow 机制。
- 契约 MUST 保持语言与包管理器中立：Python、Java、JavaScript 或其他栈均通过各自命令与路径声明接入，不在通用机制中绑定特定工具链。

## 来源(关键锚点)
- rebasing 黄金律 / merge vs rebase:atlassian.com/git/tutorials/merging-vs-rebasing(+ Linus 2009 "clean AND history" 原始邮件)
- 合并方式 per-team、无普世解:docs.github.com/articles/about-merge-methods-on-github、gitlab.com/user/project/merge_requests/methods、workingsoftware.dev
- bisect 用 `--first-parent`、要 green commits:git-scm.com/docs/git-bisect
