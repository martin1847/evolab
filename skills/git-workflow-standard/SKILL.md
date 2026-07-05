---
name: git-workflow-standard
version: 1.0.2
description: 生产级 Git 协作 SOP——受保护分支(main/master/develop/dev/release/**/project/*)禁直推、改动从 feature 分支起、base 移动且与你改动重叠才 rebase(条件动作非仪式)、走 PR + 评审 + CI 合入、集成策略默认 squash(线性;merge-commit 弃用)、提交不加 AI 签名。任何 git commit / push / 开 PR / 建分支 / 合并场景加载;agent 写完代码准备提交前必读。Use when committing, pushing, opening a PR, branching, rebasing, or merging in any company repo.
---

# Git Workflow（协作 SOP）

agent 与人共用的 Git 工作流规范。**完整版 + rationale 见 `references/git-workflow-standard.md`。**

> 双层落地:本 skill 是**软层**(write-time 预防)。不可逆动作(直推受保护分支、force push)的最终防线是**硬层**——GitHub Ruleset(归 你的 IaC 仓 / IaC CTO)。**两者都在,不互替。**

## 硬门禁契约（服务端已生效；与硬层对接缝，两层 ruleset）

canonical = 你的 IaC ruleset（两层 ruleset）,本 skill 镜像。**服务端已生效(硬层回报)**:Tier 1 baseline 自 2026-06-30、Tier 2 ci ruleset 自 2026-07-04 均 active;Tier 2 的 CODEOWNERS review 待各仓 CODEOWNERS 铺齐后开启(现变量化关闭)。两层:
- **Tier 1 `branch-protection-baseline`(所有仓,含未来仓)**:地板 = **禁 force-push + 禁删分支**;**不要求 PR、不禁 merge-commit** → 小仓 / 文档仓可直推、直接合。
- **Tier 2 `branch-protection-ci`(白名单 `var.ci_protected_repositories`,默认 = 受保护分支白名单)**:完整流程 = **require PR + CODEOWNERS + linear history + status checks**。**原则:能发布 artifact 的仓必须被保护**;受保护分支集 = 受保护分支白名单 `main` / `master` / `develop` / `dev` / `release/**` / `project/*`。

下面「你 MUST 做的」是 **Tier 2(完整流程)仓**的 SOP;**Tier 1 仓**只需守 §5(提交信息)+ §6(受保护分支不 force-push),其余可简化(直推 / 直接合)。**你的仓走哪档,在该仓 AGENTS.md 声明**,agent 进仓先读。

## 你 MUST 做的

1. **从最新 base 起 feature 分支**:`git switch -c <type>/<slug>`(`feat/` `fix/` `chore/` …),不在受保护分支上直接改。
2. **受保护分支禁直推**:`main`/`master`/`develop`/`dev`/`release/**`/`project/*` 一律走 PR,MUST NOT `git push` 直推、MUST NOT `push -f` 改写其历史。
3. **rebase 是条件动作、不是仪式**:push/PR 前 `git fetch`,查 base 动没动(`git log <branchpoint>..origin/<base>` 空 = 没动)。**没动 → 什么都不做**(空 rebase 是 no-op,不是漏步骤);**动了且碰了你改的文件 → rebase 或把 base merge 进来**解冲突再 PR;**动了但文件不重叠 → 可不动**。并发会话下 `fetch`+检查必做,但"检查"≠"每次都 rebase"。
4. **走 PR + 评审 + CI**:PR 描述讲清 what/why;等 required checks 绿 + 评审通过再合;**合并方式按本仓声明的集成策略**(见 §集成策略)。
5. **提交信息**:讲清意图,**MUST NOT 加任何 AI / Claude 签名行 / co-author**。
6. **force push 仅限自己的 feature 分支**,优先 `--force-with-lease`;受保护分支永不 force。

## 集成策略（默认线性，2026-06-25 修订）

**默认 squash**;可选 **rebase-merge**(同为线性)。**merge-commit 不是 sanctioned 选项。**
- **squash**:线性、每 PR 一个原子全绿 commit、易 revert、bisect 友好 —— 默认。
- **rebase-merge**:偏好保留 PR 内分块 commit 且要线性的仓。
- **为何弃 merge-commit**:全 agent、无人读 git 历史 → merge-commit 卖点失效(详见 references §4)。**Tier 2(出 artifact 仓)由 ruleset 强制 linear。**
- **对抗评审的知识**(约束 / 被否方案)落 **ADR + PR 记录 + commit trailer**,不进 commit graph —— squash 丢 exhaust 不丢 knowledge。

## MUST NOT
- 直推 / force push 受保护分支(靠硬层兜底,agent 不该去撞)。
- 用与本仓声明不符的方式合并。
- 把未过 CI / 未评审的改动合进受保护分支。
- 提交里出现 secret / 凭证(见 `observability-standard` 边界纪律)。

## 关联
- 完整规范 + rationale:`references/git-workflow-standard.md`
- 硬层(Ruleset / CODEOWNERS / required checks)= 你的 IaC 仓(IaC CTO 维护);两层 ruleset 定义与变量见该仓。
