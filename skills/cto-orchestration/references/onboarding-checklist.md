# 新项目接入清单

> SKILL.md §6 路由表「新项目接入」行的展开 = 整段操作清单。主干只留一行指针。

1. 项目无治理结构 → 先跑 `/repo-governance-bootstrap` 生成 docs/AGENTS.md 骨架。
   **已有骨架的存量仓不短路**：对照 bootstrap 目标结构逐项核缺（伞仓 NORTH_STAR / docs-check·
   pre-commit 门 / hooks 接线），缺则单项补、不整仓重跑。
2. bootstrap 已生成完整 AGENTS.md（含 Work Modes / Validation）；再把
   同目录 `agents-md-orchestration-section.md` 的**两节**增补进去——①委派 Agent 边界（常驻兜底，
   与 goal 合同纵深防御）+ ②编排者行为内核（角色绑定必并；纪律 bullets **按该文件头部的三层分工
   条件并入**——编排者个人全局配置已有同款则只留角色绑定，防两层复制漂移）。
3. **wire 强制层 hooks**：把 `cto-guard-bash.py` + `cto-guard-agent.py` + `cto-guard-edit.py` +
   `cto-guard-stop.py`（Stop 门）并进 bootstrap §11 已建的**项目** settings.json——**bash / agent 两门是角色属性
   DENY、只接项目级**（`&` 后台 / amend 复合链在任何仓 fire）；edit / stop 门自认身份、可接用户级（见 agentctl
   README §Wiring）；用户级只放席位属性的提醒（retro-reminder / agent-mail 收信）。
   **同一门两级同接会双触发 → 提示主理人二选一**，别在项目级再叠一份。（路径用**绝对路径**——hooks 不展开
   `~`；entry 真源 `references/agentctl/guard-hooks.json`——读它、command 换安装根绝对路径后 merge，别抄散文；
   细节 README §Wiring）；接完各喂一条合成 payload **验真触发**（尾随 `&` 应 deny、browser 派发应出提醒），
   再用**非编排仓** cwd 喂 edit / stop 载荷**应零输出**；bash / agent 只验别的仓 settings 里没有它，别只信"配了"。
   （多编排者场景装了 `agent-mail` 的，其席位注册 + 收信 hook 由该 skill 自己的「接入」节自包含，不在本清单。）
4. 建 `docs/orchestration/` + `docs/orchestration/archive/` 目录（生命周期见 SKILL §5）。
   装了 codegraph 的仓可选：`ln -s <安装根>/references/agentctl/post-checkout-codegraph.sh
   <repo>/.git/hooks/post-checkout`（派工 worktree 创建即后台建索引；`.codegraph/` 须进
   .gitignore，否则新 worktree 立即脏、撞派工门；接线细节见脚本头）。
5. 第一个任务走一遍 SKILL §1 全流程，校准该项目的忙碌标记/工具链差异。
6. 在项目 memory 里建 working-style 条目（含本 skill 引用 + 项目特有的差异）。
7. 建主理人的 `docs/DECISION_QUEUE.md`（架构+模板见同目录 `decision-queue.md`）——第一个 T2 决定就进
   队列；可选 wire 新鲜度 hook（entry 真源 `queue-hooks.json`，同步骤 3 的接入方式）。
