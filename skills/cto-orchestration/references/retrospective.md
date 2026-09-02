# 复盘仪式操作手册

> SKILL.md §5「复盘仪式」的展开 = **本文件是 checklist 本体，逐条勾**。触发词：复盘 / 复盘仪式 /
> 收口 / retro——听到即走本 checklist，不即兴。事件触发：收口 / 压缩前 / 已关单被打回（ReOpen，
> 复盘问的是"上轮为什么敢关、验收哪层漏了"）后主动提议（压缩点自动提醒接 `retro-hooks.json`）。
> 三个事件不重叠；刚跑过复盘则只补增量，不整套重来。
> SKILL §5 是入口（纪律 + 机械检查 `retro-check.sh`）；这里是七步全文 + 后两步操作细节。

## 七步 checklist

1. **交付清单**：shipped / parked / 残留，**每单元标面**（业务效果 / 必要工程 / 混合，混合单列
   不硬分；分类以落地物路径为准，覆写留理由——覆写清单在此人眼过）+ 报近期配比与
   **距上次真实用户路径被走通的间隔**（配比轴判据见 SKILL §2）——比值是数字才判得了，且它只在
   这里被看见：自动闸只咬间隔，拦不住长期偏离；比值这一期该是多少，由主理人当场调旋钮。
2. **过程×结果四象限**（每个收口单元落唯一一格，禁「上线=好」塌缩）：好程好果=**实力赢**(固化做法) ·
   坏程好果=**走运**(别奖励、补过程洞) · 好程坏果=**倒霉**(别改流程) · 坏程坏果=**实力输**(改)。
   判「走运」即使 shipped 也标 outcome 星号 + 点出过程缺口。
3. **教训分层沉淀**（系统方法论见内核 `orchestrator-core/references/self-evolution.md`，此步为其操作化、自包含可跑）：
   - **分诊落层**：五问追根，**追问停在哪层、教训就落哪层**——事实（路径/凭据/执行路径）→ ACCESS/docs；
     本项目情景教训 → memory（带 **Why + How-to-apply + provenance**〔哪次事故立的〕，memory 只留指针
     不存事实细节）；跨项目操作规则 → skill reference；判断标准 → skill 主干；范式 → meta。
     同类补丁在低层反复出现 = 上一层治理变量有缺陷的信号，升层提问、别再加一条。
   - **晋升三门**：**样本门**（measure-before-more 的复盘版）——n=1 只标 `OBSERVATION`、不改 spec/默认，
     **≥2 例同向**才提议升层；**行为门**——顺手核一条：上轮复盘沉淀的教训这轮 fire 了吗（记录 ≠ 学会，
     没 fire 的进下条淘汰）；再核一条：**上一批买下的性质，这一批有电守着吗**（合同写在 goal 里的，
     goal 归档它就死了）；**压缩门**——同层出现 **≥3 条同族条目 → 提蒸馏合并案**（1 条上层判据 +
     retire 原件，corpus 总量不增；总量没减 = 复制不是晋升）。retro 只**提议**，改 spec 由主理人**裁定**
     （提议/批准分离，防按一次性事件堆规则）。
   - **教训与门同形态**（「缺口要与成绩同形态」的复盘版）：教训入台账写 typed 行——
     `LESSON: <slug> n=<复发次数> gate=<门路径|none|accepted(理由)>`（行首顶格，允许 `- ` 列表前缀；
     slug 用 ASCII 词字符 `A-Za-z0-9_.-`，n 最多 9 位，code fence 内的示例不计入台账）
     ——散文教训进不了决策，复发也没人数得清。n≥2 且 gate=none 是 retro-check 的 blocking FAIL：
     当批要么升门（gate 指向真实存在的文件），要么主理人显式 accepted(理由)；
     一条教训最多以散文形态活两次。
   - **门效果审计（行为门的对偶面）**：本波编排位自造的每个门/上限/仪式写 typed 行
     `GATE-AUDIT: <slug> hits=<真缺陷数> false=<误报 BLOCKED 数> action=<kill|keep(<理由>)>`
     （行首顶格或 `- ` 前缀；slug 同 LESSON 字符集；两个计数各最多 9 位；理由可含括号；
     code fence 内示例不计入）——hits=0 且 false≥2 默认 kill，keep 须写非空理由，否则
     retro-check 第 8 检 FAIL；先问「门该不该在」，再谈校准阈值。
   - **淘汰同轮做**：会在动手那一刻 fire 的才留正文；hook 已强制的收成一行指针；从不 fire 的删或降
     README 背景（不 fire 的散文是净负债）。
4. **上下文治理**：只关本席位 `agentctl start` 派出且已交付完的会话，其他会话一律不动（会话账
   `/tmp/agent-watch-run` 与 tmux server 都是全席位共享，账内 ≠ 你的、不认识的名字一律不动，
   零派工记录 ≠ 全场可清；机器面 retro-check FOREIGN 行只报不杀，但账内他席位会话它不报——散文是
   该格唯一承重面）+ **扫孤儿**（见 SKILL §5「孤儿扫」纪律：`docker ps`/`ps`/后台 job + compose
   trap/finally + repro 禁裸 `while True`）+ **worktree 核对**（已合分支的 worktree 必清 `git worktree remove`）+
   **base 对齐**（squash 集成仓的长驻 checkout：base 分支与 origin 分叉〔ahead 且 behind〕→ 核实
   ahead 内容已被 squash 合并后 backup ref + `reset --hard origin/<base>`；真未合并的工作先救——
   retro-check 1b 只检测告警，reset 归编排者）+
   **敞口清单**（=下会话入口；敞口要变下一批选题时走盘点仪式 `stocktake.md`，取舍判据单源在彼）。
5. **治理同步（与 memory 更新同级、不可省）**：文档归档（→ `orchestration/archive/` + 索引行）+
   **ACTIVE_CONTEXT 整篇重写**（非追加，~60 行）+ **roadmap 翻状态** + **决策队列先清再刷**（规则单源 `decision-queue.md` §队列机制：先移除已处理项，再重浮 revisit 到期项、给周期全局图）。
6. **memory 治理**：见下「memory 治理」。
7. **session 切换决策**：见下「session 切换决策」。

收尾跑 SKILL §5 的 **`retro-check.sh`**：已合分支孤儿 worktree、ACTIVE_CONTEXT 新鲜度与
复发≥2 无门的 LESSON 行、零战果连误报仍无理由 keep 的 GATE-AUDIT 行、DECISION_QUEUE 已清区仍有正文
是 blocking FAIL；roadmap、MEMORY 与队列新鲜度只给 warning，exit 仍可为 0，需按任务语义人工裁决。脚本只验机械代理，不能证明复盘语义完成。

## memory 治理（步骤 6 展开）

- COMPLETED workstream 精简到 ≤10 行（结论 + 关键教训 + 指针），删掉过程细节。
- 事实性细节（路径 / 凭据 / 执行路径 / 导航步骤）沉淀到项目环境文档（如 `ACCESS.local.md`,
  由 `repo-governance-bootstrap` 生成），memory 只留指针——memory 跨 session 存活但容量有限，
  环境文档是 gitignored 的本地 SoT。沉淀时追加更正必须**同时改掉被推翻的原文**（supersede
  原地改写——append-only 是此类文档的主腐烂模式：下游席位审计实测 64 条可核事实 51.6% 已腐，
  且全部是指针类〔路径/URL/对象名/file:line〕，原理散文零腐烂）；文档成规模后配自动指针
  lint——脚本正则抽取指针分档机械核查（路径/符号离线、URL/对象在线），零人工标注。
- 重复 / 矛盾的 memory 合并或删除；已过时的 workstream 状态更新。
- MEMORY.md 是索引（一行一条，宿主只加载前 200 行 / 25KB，且不进非 fork 子 agent），条目按宿主四类 `user / feedback / project / reference` 落文件；索引行只留指针与一句 hook。

## session 切换决策（步骤 7 展开）

治理完评估当前上下文状态，二选一：

- **压缩上下文续跑**：同一任务还在连续迭代、没有天然断点。
- **新 session + handoff**：天然交接点（等外部部署 / 验收、workstream 批次结束、角色 / 优先级切换）。
  写一次性 handoff 到 `/tmp/`（**不进 `docs/orchestration/`**——handoff 是 transient 交接产物，放治理
  SoT 会变又一个只生不死的死文件；持久状态归 ACTIVE_CONTEXT + memory，handoff 只快照运行时状态）。三件事：
  ① 待办队列（带状态 + session/worktree/branch 指针）；② 活跃 tmux sessions 及其当前任务；
  ③ 需用户决策的 blocking 项。新 session 读 handoff + memory 冷启动，**读完即删**。
