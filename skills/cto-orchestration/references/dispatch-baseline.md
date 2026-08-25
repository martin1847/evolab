# 派工基线纪律 + 收工核证（编排者侧规程）

> SKILL.md §1 step1（基线纪律）+ step6（收工核证）的展开。**受众是编排者，不是 worker**——
> 前半发生在 goal 存在之前（开基线），后半发生在 worker 自报 done 之后（独立核证），
> 都不属于 goal 合同：塞进合同 = 让执行者替编排者守门，恰好废掉"完成状态不由执行者自报"这道防线。
> worker 侧合同见 `goal-template.md`（本文产出它 header 里的 `cut from latest origin/<base> @ <sha>`）。
> 权威 git 细节见你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard`）；这里只留编排基线。

## 基线纪律（fetch + 检查，按需 rebase，集成用 squash）

派工基线四件（`agentctl start` 前编排位亲自做完）：

1. **fresh worktree @ 最新远端 base**：`git fetch` 后
   `git worktree add ../wt-<name> -b feat/<name> origin/<base>`——不让 agent 在过期基线开工。
2. **构建/依赖就绪**（venv、node_modules 等按该仓声明）——席位开工即能跑测试，不烧轮装环境。
3. **播种即 seed commit**：编排位播进 worktree 的任何文件（goal/评审档等）先落 commit——
   untracked 即脏树，撞席位清洁门直接 STOP（下游席位 n=2 各烧一轮）；非交付件放伞仓
   docs/，别落 worktree。
4. **主 checkout 不在核对面**：goal 固定句「基线核对只针对你自己的 worktree；主 checkout 与
   本地 <base> 分支不在核对面、不得要求 fast-forward」——squash 集成仓的主 checkout 必然
   分叉，席位拿它判 BLOCKED / 要求 fast-forward 全是误报（下游席位 n=3）。

- **rebase 条件动作 / 集成默认 squash（merge-commit 弃用）**：base 没动不 rebase；动了且与
  改动重叠才 rebase（或 merge base 进来）——判据细节与合后 ancestry 陷阱归你所在仓的 Git 协作
  规范，此处不复读。编排位只记一条：多会话并发时 base 常被别的 PR 推进，
  **`git fetch`+检查这一步省不得**（省了才会在过期基线上 PR）。
- 按 SHA 部署的项目：squash / rebase-merge 的 ancestry 都干净线性（`contains <sha>` 成立）。
- **同 cwd 起第二席前先收割 BLOCKED.md**：BLOCKED.md 是席位间共享路径——前席遗留不清，
  新席正确拒动他席文件而卡死（同日 n=2）。编排位收割（读取归档其内容）后删除，再派新席。
- **只读 scout/audit/Explore 也算"开工"**：经 Agent 工具派出时**静默继承编排者 cwd**（常是落后的主
  checkout、非新 worktree）→ 对着过期基线出"幻影发现"（删了的看着还在、已合的看着没合）。派 scout
  **显式指到新 worktree**，可疑结论再**对 base ref 复核**（`git show origin/<base>:<path>` / `git grep`）。

## 收工核证四件套（SKILL §1.6 验收原则的操作化；四件套定义在此）

1. `git status -s` 干净（执行 agent 常"声称完成没 commit"；**评审审合同不审过程卫生，
   这件永远归编排位**——别为此往 goal 合同里塞自守门条款）。
2. `git log origin/<base>..HEAD` 与声明一致（多了 = 夹带，少了 = 没交）。
3. 独立复跑 test+lint——不吃 worker 转述的结果。
4. 测试计数用 `grep -E 'passed|failed'`，别信被截断的点行。
