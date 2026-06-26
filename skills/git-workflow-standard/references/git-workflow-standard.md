# IM Git Workflow Standard — 完整版

> 本文件是 `git-workflow-standard/SKILL.md` 的全量镜像 + rationale。规则两层同源,改一处同步另一处(AGENTS.md 纪律)。
> 落地结构与软/硬分工见治理;集成策略 per-repo 见治理。

## 0. 双层模型

| 层 | owner | 形态 | 作用 |
|---|---|---|---|
| 软层 | 本 SOP | agent-facing SOP | write-time 预防、教学、对接缝声明 |
| 硬层 | 你的 IaC 仓 / IaC CTO | GitHub Ruleset / CODEOWNERS / required checks | 强制兜底,绕不过 |

**为什么两层**:skill 文本随长对话 salience 衰减;纯声明机制无 forcing function 会腐烂(见治理调研依据)。**不可逆动作(直推受保护分支、force push 改写历史)的最终防线必须是硬层**;skill 让 agent 不去撞墙,Ruleset 是墙。

## 1. 假设的硬门禁契约（对接缝）

canonical 定义在 你的 IaC ruleset（两层 ruleset）,本 skill 镜像。两层:

**Tier 1 `branch-protection-baseline`(所有仓,含未来仓)** —— 地板,装即生效:
- Block force pushes、Restrict deletions(仅此两条)。
- **不要求 PR、不禁 merge-commit、不强制 linear history** → 小仓 / 文档仓可直推、直接合。

**Tier 2 `branch-protection-ci`(白名单 `var.ci_protected_repositories`,默认 = 受保护分支白名单)** —— 完整流程:
- Require a pull request before merging(+ required approvals ≥1、dismiss stale、Code Owners review、conversation resolution)
- Require status checks to pass(+ branches up to date)
- Require linear history
- Block force pushes、Restrict deletions、Restrict who can push(bypass 名单空 / 仅 break-glass)

**原则:能发布 artifact 的仓必须被保护**——受保护分支集 = 受保护分支白名单 `main` / `master` / `develop` / `dev` / `release/**` / `project/*`。

**已 reconcile(2026-06-25)**:全 agent 开发重定调研 → **merge-commit 弃用、默认线性(squash)**(见 §4),故 Tier 2 强制 linear 是对的、无冲突。集成策略已修订;per-repo linear 开关方案作废(两层 ruleset + 弃 merge-commit 已解决)。

**仓的 tier 归属以 你的 IaC ruleset 为准**(白名单 = 受保护分支白名单);本规范仓走 Tier 1。

## 2. 分支模型

- **业务/受保护分支**:`main`/`master`、`develop`/`dev`、`release/**`、`project/*`(项目集成分支,如 `project/pda`)。**Tier 2 仓:只接受 PR 合入**(Tier 1 仓可直推,仅禁 force-push/删分支)。受保护集 = ACR 出镜像放行集;canonical 定义在 你的 IaC 仓(两层 ruleset)。
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
- **并发会话**:base 可能在你 cut 和 merge 之间被别的 PR 推进——所以 `fetch`+检查**必做**;但"检查"≠"每次都 rebase"。硬层 "branches up to date" 会在合前再卡一次。

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

trivial 单 commit PR 直接合。Tier 2 由 ruleset 强制 linear(见 §1)。

## 5. PR 流程

- PR 描述讲清 **what / why**(不复述 diff)。
- 等 **required checks 绿 + 评审通过** 再合。
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

## 来源(关键锚点)
- rebasing 黄金律 / merge vs rebase:atlassian.com/git/tutorials/merging-vs-rebasing(+ Linus 2009 "clean AND history" 原始邮件)
- 合并方式 per-team、无普世解:docs.github.com/articles/about-merge-methods-on-github、gitlab.com/user/project/merge_requests/methods、workingsoftware.dev
- bisect 用 `--first-parent`、要 green commits:git-scm.com/docs/git-bisect
