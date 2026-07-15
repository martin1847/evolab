# 派工基线纪律 + 收工核证（编排者侧规程）

> SKILL.md §1 step1（基线纪律）+ step6（收工核证）的展开。**受众是编排者，不是 worker**——
> 前半发生在 goal 存在之前（开基线），后半发生在 worker 自报 done 之后（独立核证），
> 都不属于 goal 合同：塞进合同 = 让执行者替编排者守门，恰好废掉"完成状态不由执行者自报"这道防线。
> worker 侧合同见 `goal-template.md`（本文产出它 header 里的 `cut from latest origin/<base> @ <sha>`）。
> 权威 git 细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard`）；这里只留编排基线。

## 基线纪律（fetch + 检查，按需 rebase，集成用 squash）

派工前 `git fetch` + 基于最新远端目标分支开 worktree：

```bash
git worktree add ../wt-<name> -b feat/<name> origin/<base>
```

**不让 agent 在过期基线开工。**

- **rebase 条件动作 / 集成默认 squash（merge-commit 弃用）**：判据、ADR-trailer 与合后 ancestry
  陷阱归 `git-workflow-standard`（§工作流、§集成策略），此处不复读。编排位只记一条：多会话并发时
  base 常被别的 PR 推进，**`git fetch`+检查这一步省不得**（省了才会在过期基线上 PR）。
- 按 SHA 部署的项目：squash / rebase-merge 的 ancestry 都干净线性（`contains <sha>` 成立）。
- **只读 scout/audit/Explore 也算"开工"**：经 Agent 工具派出时**静默继承编排者 cwd**（常是落后的主
  checkout、非新 worktree）→ 对着过期基线出"幻影发现"（删了的看着还在、已合的看着没合）。派 scout
  **显式指到新 worktree**，可疑结论再**对 base ref 复核**（`git show origin/<base>:<path>` / `git grep`）。
  实证：审计跑在落后 70 commit 的主 checkout、把已被某 PR 删净的子系统报成"待删"，靠对 origin 重核才在派删除前抓出。

## 收工核证四件套（判据与定义见 SKILL §1.6，此处只留每件的操作细节与实证）

1. `git status -s` 干净（实证：执行 agent 屡次"声称完成没 commit"）。
2. `git log origin/<base>..HEAD` 与声明一致（多了 = 夹带，少了 = 没交）。
3. 独立复跑 test+lint——不吃 worker 转述的结果。
4. 测试计数用 `grep -E 'passed|failed'`，别信被截断的点行。
