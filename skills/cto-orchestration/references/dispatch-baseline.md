# 派工基线纪律 + 收工核证

> SKILL.md §1 step1（基线纪律）+ step6（收工核证 Implemented→Verified）的展开。
> 主干只留判据；这里是命令全串、rebase 三分支判定、squash 论证、核证四件套与实证。
> 权威 git 细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard` 规划中）；这里只留编排基线。

## 基线纪律（fetch + 检查，按需 rebase，集成用 squash）

派工前 `git fetch` + 基于最新远端目标分支开 worktree：

```bash
git worktree add ../wt-<name> -b feat/<name> origin/<base>
```

**不让 agent 在过期基线开工。**

- **rebase 不是仪式、是条件动作**：push/PR 前 `git fetch` 后查 base 有没有动
  （`git log <branchpoint>..origin/<base>` 空=没动）。**没动 → 什么都不做**（别空转 rebase，
  否则看着像"忘了"其实是 no-op）。**动了且碰了你改的文件 → rebase** 解冲突再 PR；动了但文件不重叠
  → 可不动（合并自然干净）。
- **集成（并回主干）默认 squash（linear history）；merge-commit 已弃用**：全 agent 开发没人读
  git 历史，agent 要逻辑原子 + message 清楚的 commit（squash 产物），中间 wip churn 是 context 污染。
  出 artifact 的仓由 IaC ruleset 强制 linear，merge-commit 会被挡。对抗评审知识落
  **ADR + PR 记录 + commit trailer**（`Constraint:` / `Rejected-alternative:`），不靠 commit graph。
- 多会话并发时 base 常被别的 PR 推进，所以 **`git fetch`+检查这一步省不得**（省了才会在过期基线上 PR）。
- 按 SHA 部署的项目：squash / rebase-merge 的 ancestry 都干净线性（`contains <sha>` 成立）。
- **只读 scout/audit/Explore 也算"开工"**：经 Agent 工具派出时**静默继承编排者 cwd**（常是落后的主
  checkout、非新 worktree）→ 对着过期基线出"幻影发现"（删了的看着还在、已合的看着没合）。派 scout
  **显式指到新 worktree**，可疑结论再**对 base ref 复核**（`git show origin/<base>:<path>` / `git grep`）。
  实证：审计跑在落后 70 commit 的主 checkout、把已被某 PR 删净的子系统报成"待删"，靠对 origin 重核才在派删除前抓出。

## 收工核证：Implemented → Verified

watcher 测的是 idle、agent 自报的是 "done"——**都只算 Implemented，不是交付**（别让交付状态由执行者
自报，§1.4 存活检测是同一主题）。升 **Verified** 仅当：

1. 核证四件套过；
2. 异构 codex 独立确认（执行者再严的完成自审——哪怕跑了结构化完成审计——仍是同 lineage 自审 =
   self-preference bias，不可信）。

**roadmap / ACTIVE_CONTEXT / 关单只认 Verified。**

核证四件套：

1. `git status -s` 干净（实证：omp 屡次"声称完成没 commit"）。
2. `git log origin/<base>..HEAD` 与声明一致。
3. 独立复跑 test+lint。
4. 测试计数用 `grep -E 'passed|failed'`，别信被截断的点行。
