# agentctl — headless worker 控制面（一条 duplex lane、三引擎）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**，
一条 duplex lane、三引擎各跑原生 stdio 协议长驻（omp `--mode=rpc` / claude stream-json /
codex app-server），能力差异不分叉车道、由接口干净拒绝。tmux 只做进程保活（worker 独立于
编排者进程树）；终态真相只来自 typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 本文只写 CLI 讲不了的：语义、失败形态、判断。能从 `agentctl` / `capabilities` / `states` 问出来的
> 事实以 CLI 为准；本文偶有的复述（exit 码、resume 命令、env 覆盖）漂移时 CLI 赢。

## agentctl —— 当前命令面

命令面由 CLI 自述，此处不留副本（复述必漂）：裸跑 `agentctl` 出 usage、`agentctl capabilities` 出三引擎能力契约、`agentctl states` 出 typed 状态词表。
下面只写 CLI 讲不了的部分——语义、失败形态、判断。

- **steer 语义 = 两个动词**（能力差异拒绝制，不分叉车道）：默认 `agentctl steer` **尽快送达**——
  引擎有轮中路由且正在跑 turn 就进 turn（omp `steer` / codex `turn/steer`），空闲就立刻开下一轮
  （omp `follow_up` / codex `turn/start` / claude `user`）；**选路只看活体 turn 态，没有 flag 可忘传**
  （`--replace` = `--interrupt` 别名）。
  `--interrupt` = 弃当前 turn 以本条重开（omp `abort_and_prompt` / codex `turn/interrupt+turn/start`；
  claude 无此帧 → 拒绝并指 stop+resume），并回收 supervisor、轮转 attempt。
  **降级/判不出都是 typed 出口，不是 stdout 散文**：turn 运行中却进不去 turn 时，`steer` 出
  **`DELIVERED-NEXT-TURN`**（词表见 `agentctl states`）并带 reason——`reason=capability`
  = 引擎无轮中帧（claude degraded）、`reason=undecidable` = 活体 turn 态判不出（omp get_state
  非布尔/失败、codex events 不可解析）。**真进 turn 或 idle 立刻开下一轮 = exit 0**。
  判不出按「开下一轮」走（宁钝勿敏：晚一个边界 > 丢一条指令）。三引擎能力矩阵由 runtime 生成，
  `agentctl capabilities` 是唯一真源（同一张表既驱动路由、又出拒绝文案）。投递成功 ≠ 模型照做，
  验收仍看交付物。
- **steer 队列可见**：`queued=N` 只是引擎报的深度，lane 自己记 sidecar `<s>.steer-log.jsonl`；
  `status` 在 N>0 时按深度列出末 N 条，无队列面的引擎零输出。stop 随控制态一起清。
- **typed exit 三引擎同词汇**（词表 `agentctl states`，处置见下节）；
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **deliverable gate**：相对 glob 一律按**会话 cwd** 解析；freshness
  用 mtime 对 epoch（每次 steer 即轮转）；必带/不带的判据归 SKILL.md §0。
  **`steer -d` 只移动 watcher 的 freshness 目标，不重发 footer**——worker 不会自动得知新目标，
  你的 steer 文本必须自己点名交付文件（runtime 在 `-d` 成功时会当场提醒这一条）。
- **尾行机器可读**：`watch` 四类出口（终态 / 非终态 / ENGINE-SILENT / TIMEOUT）都在 typed
  `=== … ===` 行之后追加最后一行 `EXIT=<n>`——包装层（管道 / 后台 harness）吞掉进程退出码时仍可解析。
  `status` 读到 RUNNING 而**无存活 watcher**（pid 文件缺失、或进程已亡）追加
  一行 `note: no watcher armed — arm: agentctl watch <S>`：只提醒不代挂，typed 行与 exit code 不动。
  **watch 不可用自造轮询顶替**：只认 DONE 的轮询会把 `RUNNING: idle but queued=<n>` 停成
  无人收割——typed 终态 / deliverable freshness / round 围栏全靠 sensing supervisor。
  `--deliverable` 声明与 brief 点名的输出文件必须同名：runtime 只看声明的 glob——worker 按 brief
  写到别名得 exit 6（misplaced hint 只扫 cwd 同名近失）；写了声明名却违背 brief 则 DONE 不拦。
- **supervised watch（默认）**：感知环跑在独立 tmux 会话 `<session>-watchd`，宿主侧 `agentctl watch`
  只是**哑等待者**——只读围栏过的终态记录，自己不 classify。**被外部 TERM 后原地重挂即恢复同一
  class + exit**，连本轮结论都不丢。生命周期绑 attempt：`start` / `stop` / `steer --interrupt` 回收
  守护环，普通 `steer` 保留。**降级只在守护结构性不可能时发生且响亮告警**（无 tmux / run 目录不可写 /
  自起的 pane 没发租约）——宁可失去抗杀性也不能拒绝观测，stderr 明说 "NOT kill-resilient"。
  **同名 `<s>-watchd` 在但没有本 identity 的租约 = 不可判，不是降级理由**：返回 `12 reason=unknown`
  并点名清理指引（`tmux kill-session -t <s>-watchd` 后重挂），绝不静默 inline。`--inline` 是显式
  兼容旗标（进程内轮询，被杀即丢本轮结论；不跟随）。
- **waiter 默认跟随会话**（block until an ACTION verdict）：steer 轮转对等待中的 waiter 透明——自动
  瞄新轮不退出；`WATCH-TIMEOUT` 与 `SUPERVISOR-LOST reason=dead` 打完整 typed 行 + `EXIT=` 标记后
  **有界**自动重挂（`AGENT_WATCH_FOLLOW_MAX`，默认 8；0 = 单轮 waiter）；动作类判决
  （0/2/4/5/6/8/9/11/14、12 unknown）立即以该码退出唤醒编排位。跟随中每个被报告轮各有一行
  `EXIT=<n>`，进程**最后一行**才是退出码——计数 `EXIT=` 的消费面要改读末行。
- **输出有界**：`status` 回 typed 一行 + 摘要，另可跟至多 4 行错位产物提示（见下 exit 6）；
  terminal record 里落盘的 detail 硬上界 ≤600 字符且**按整行截**——放不下的行整行丢弃并追加
  `…[detail truncated; …]` 标记行为末行，绝不半截 JSON。`watch` 回放 = 该 detail（≤600），
  受压丢掉 receipt 展示行时再补一行由结构字段重建的 receipt 摘要
  （`receipt (rebuilt from record fields): reason=… phase=…`）。引擎 raw 全量只落
  `$RUN/<s>.duplex.events.jsonl`（单条 raw transcript 可达百 KB 级，回显会炸编排者上下文——
  摘要有界是本控制面的硬设计）。
- **后台任务 cwd 语义**：宿主后台机制跑 `agentctl watch` 时，命令继承**发起时刻
  编排者的 cwd**，与 worker 会话 cwd 无关；判断后台任务归属认 `$RUN/<session>.*` 文件名，别认 cwd。
- **watch 等的是 worker，不是外部作业**：worker 在等长外部作业（部署列车 / CI / 远端队列）时
  别拿 watch 反复重挂硬扛——宿主事件会成批收割后台 waiter（见下 tombstone 节），每次收割触发
  一次重挂、全是空转轮；改用宿主长间隔 wakeup / 定时器对齐外部作业的真实时长，到点再回
  `status` 一发判态。
- 需要人工现场 = `tmux attach -t <session>` 旁观 / `tmux capture-pane -p`
  手动尸检；worker 控制始终走协议。

## duplex 车道（机制归代码与 meta 文《protocol-not-screen》，此处只留编排位要知道的）

- goal 投递 = `prompt` 帧（正文 = goal 文件 + HEADLESS 协议 footer：合同承诺了开工前核对、阻塞、
  或合同门要求停下等裁决时 → 写 `<cwd>/BLOCKED.md` 停下（fresh BLOCKED.md 映射 exit 4，三引擎同协议）；
  其余情况立即开工）。
- **崩溃恢复腿**：照 `agentctl capabilities` 的 `resume` 行走——degraded 两家（`stop` 后重开会话、
  engine args 由 start 原样转发）正路在各自 note 里；codex 唯一 supported，握手内续 thread：
  `agentctl start codex <s> <cwd> --goal <f> --resume-thread <threadId>`（supported 不带 note，故写这）。
- **评审档 `--review`**（codex 专属；非 codex、或与 `--resume-thread` 并存，参数面即拒——thread/resume 只带
  threadId 不重发 tier）。沙箱两档统一 `danger-full-access`（评审席需网络独立复算）。
  **交付物仍必须在 session cwd 内**——车道纪律非沙箱事实：写进无关树的评审产物会在 worktree
  清理后变孤儿，且 exit-6 近失扫描只走 cwd。越界（`..` 分量、symlink 外逃、歧义祖先、空 basename）
  即参数面拒——判定归 `duplexctl check-params`，`start` 与 `steer -d` 同门。
- 并发 steer 串行（lane 单写者锁）。

`--workflow review-loop --max-rounds N` 预算与 SHIP-BLOCKING 续轮租约在 duplex meta，三引擎通用
（每次 goal/steer 投递计一轮，超限 `BUDGET-EXHAUSTED` exit 9）。

## Launch

- `agentctl start … --goal <f>` 在 goal 帧被引擎接受后返回（omp 有 correlated response；claude 为
  送达即返，无逐帧 ack——诚实边界）；**不会自动 watch**，紧接着用宿主受控后台能力挂
  `agentctl watch <session>`（guard ⑤ 强制宿主后台、拦 shell `&` 与前台阻塞；同步 shell 编排者
  前缀 `AGENT_WATCH_SYNC=1` 显式放行并自读 exit code）。
- **preflight 门默认开**：启动引擎前调 `../goal-preflight.py` 校验 goal 里
  `Preflight: <probe> => <observed result>` 存在且已解占位，未过即拒发、不起引擎；
  `--no-preflight` 显式豁免（豁免类别的判据归 SKILL.md §1）。
- **watcher 被外部杀（TERM）= 预期可恢复态**：收到 killed 通知即重挂——supervised 模式下感知环在
  tmux 里没被碰过，重挂只是重新读记录，连本轮结论都不丢（下线期间算出的终态照样在盘上等着）。
  归因看 tombstone：trap 在退出前落 `$RUN/<s>.watch.tombstone.jsonl`（ts / signal / ppid /
  uptime——发送方沙箱内不可见，事后只有这一行可查）。宿主一次事件会成批收割全部后台 watcher，
  且 killed 通知本身可能随会话一起丢——`status` 对 RUNNING+无 watcher 的会话自动打死亡归因行、
  并点名 ±120s 邻近窗口内一同死亡的其他 watcher（邻近 ≠ 因果），照单逐个重挂；重挂或 `stop`
  即消费 tombstone（转 `.consumed` 留取证），已消解的死亡不复报。
- 引擎二进制可用 env 覆盖（测试缝 + 自定装机位）：`AGENTCTL_BIN_OMP` / `AGENTCTL_BIN_CLAUDE` / `AGENTCTL_BIN_CODEX`。
- exit 6 `IDLE-NO-DELIVERABLE` 用 `agentctl steer` 补一刀，**不要 stop**；`stop` 只用于收工或明确放弃。
  verdict 行后可能跟 `possible misplaced deliverable: "<abs path>"`（有界扫 cwd 找同名错位产物，
  json 编码防伪造 typed 行；只提示、不改 rc，无命中/扫描退化都零输出）——先看这行再决定 steer 措辞。
- **stop = 进程组收割**（tmux kill 只碰 pane leader，引擎子孙会被 PID 1 收养泄漏）：有界宽限后
  强杀并复核零残留（宽限由 `AGENTCTL_REAP_GRACE` 调）；防 pid 复用误杀，永不按名字/全局杀。
  终态后**立即 stop 是编排者纪律**，retro-check 第 6 检对"本仓终态未清会话"blocking FAIL 兜底。

## typed 状态：处置（词表由 `agentctl states` 自述）

exit code、名字、语义、二级子原因词（`reason=<word>`，闭集）都是运行时事实 →
`agentctl states`（`--json` 机器读），此处不留第二份。**本节只写 verb 故意不发布的那一列：
处置**——它是判断，不是事实。

| 状态 | 编排者要做什么 |
|---|---|
| DONE | 收货前仍做正向核证（下节），别只认 typed 行 |
| FAILED / AGENT-DEAD | 读 events/stderr 尾（有界），走恢复腿 |
| WAITING-INPUT | 读题，`agentctl steer` 作答 |
| STALLED-EXTERNAL | 修凭据/额度再重启；见引擎级注意 |
| IDLE-NO-DELIVERABLE | poke（steer），别信幻影 DONE、别 stop |
| WATCH-TIMEOUT | 重挂或人工核证，**绝不按 DONE 消费**。行尾 `progress=changed\|unchanged\|unknown`（三词由 `agentctl states` 发布）是**进展源的观察结论**，不是工作量判决：`unknown` = 探针关闭 / 未测 / 最后一次读**一个可判源都没有** / **整段窗口从未测到过一次可判的移动**（窗口由不可判的读开启或重建，中间那段没人量过），绝不读成「没进展」 |
| ENGINE-SILENT | 查 stderr.log；必要时 stop+resume |
| BUDGET-EXHAUSTED | 转人工裁决 |
| RUNNING | 继续等 |
| STALLED-STREAM | **先从 checkout/commits 抢救成果，再 stop**；探针任一不确定按 RUNNING 处理（宁钝勿敏）。窗口用 `AGENT_WATCH_STALL_MINS` 调、0 关 |
| STALLED-PROGRESS | 流还活着，但整个窗口内**可判的进展源在每个采样点都没动**（三源：①仓库痕迹〔HEAD/脏树/交付物/BLOCKED.md〕②引擎工具/命令帧计数〔纯 token 流不算，那是 STALLED-STREAM 的题〕③pane 进程组集合〔采样点间生灭的短命子进程看不见，别读成「没起过进程」〕）。窗口用 `AGENT_WATCH_PROGRESS_MINS` 调（默认 30min）、0 关；探针预算有界，超预算按不可判计。**处置按 `reason=` 分支**：<br>· `reason=repo-silent+tools-silent` → 可判源全静且没有源不可判：**先读 events 尾**再决定——卡在无效循环 → `steer` 给具体下一步；方向已错 → `--interrupt` 重开；确认走死 → 抢救成果再 stop。<br>· `reason=unknown-source` → 可判源全静但**有源量具坏**（detail 点名哪个）。**按量具坏处置**：先修那个源或人工核证，别当「席位停滞」直接 steer/stop。<br>· `progress_reason=repo-silent+tools-active`（**不出 14**，打在 RUNNING 行上）→ 仓库不落痕但引擎在动（长测试 / docker / 取证）：**继续等**。<br>结构性缺位的源不算量具坏（`[n/a]`，不污染 `reason=`）；只有**零可判源**才整个关闭本状态（每次读打 `progress=unknown: <原因>` 且不刷时间戳）。`last_progress_at` = 上次观察到某源变化的时刻；量具坏后恢复的第一次可判读**只重建基线、不算移动** |
| SUPERVISOR-LOST | `reason=dead` → 直接重挂。`reason=unknown` → **先读 detail**：只有它点名 rogue/wedged `<s>-watchd` 时才 `tmux kill-session -t <s>-watchd` 再重挂；其余 unknown（canonical 读超时 / `ps` 不可用 / 租约损坏 / pid 复用嫌疑）**只重挂，绝不杀**——那些情况下杀掉的是一个活着的守护环 |
| DELIVERED-NEXT-TURN | **steer verb 的出口，不是会话状态**（watch/status 永不产它）：指令已送达但落在 turn 边界。`reason=capability` → 引擎无轮中帧，等边界即可，别重发；`reason=undecidable` → 量具坏（detail 点名哪个），**先修量具或读 events 尾**再决定要不要 `--interrupt`。两者都**已送达**，重发会得到两条指令 |

新增 typed MESSAGE 行（**exit 码契约不变**，三类都映射到既有失败 / UNKNOWN 出口）：

| MESSAGE 行 | 触发 | 映射 exit | 处置 |
|---|---|---|---|
| `STALE-ATTEMPT` | 证据 stamp 的 `attempt_id` ≠ 活跃记录（精确串比） | 不改判：证据被丢弃后按本轮真实态出码（marker 路径落 2 AGENT-DEAD；BLOCKED 路径继续投影） | 视为**前一次 attempt 的遗留**，留盘做事后取证，别回填 |
| `STALE-INCARNATION` | `attempt_id` 相同但 `process_incarnation`（pid@start-time）不同 = pid 复用 / 换进程 | 同上 | 同上；说明有 impostor 或未走 resume 的重启 |
| `IDENTITY-UNKNOWN` | 活跃记录缺 / 损坏 / 无法解析、stamp 缺字段、start-time 信号取不到 | 2（既有失败出口，**永不映射成 0**） | 身份不可判定就不许收货：`agentctl stop` 后重启建立新 attempt |

**判定合同（唯一，按优先级）**：①本 attempt+round 有围栏过的终态记录 → 用它的 class + exit；
②无记录但结构化证据证明守护环在跑 → 继续等（RUNNING）；③无记录且证明守护环已死 → `12 reason=dead`；
④其余（证据缺失 / 损坏 / 陈旧 / 不可判）→ `12 reason=unknown`。**四条之外没有第五种走向，
判不出一律有界 typed 12，永不映射成 0。** 停滞判定权只在轮询等待者手里且只由它自己的 poll 计数
产生（不读任何时钟）；一次性读者（`status` / 单发读）只核结构、**永不因"租约看起来旧"判 12**，
因此它发现不了 wedged 守护环——要判停滞就挂 `agentctl watch`。

- **Agent 工具异步 subagent 的完成通知有黑洞**：只在"停止且自身无存活后台子进程"时才发；子 agent 自起
  后台 fork（E2E/monitor）→ 父 idle 而通知永不来。
  对策：别只信完成通知（fallback 自检兜底）；派工要求验证同回合做完、不留孤儿 fork、里程碑 SendMessage 回 main。

## 判完成要正向证据、不凭 idle / watcher 裁决

watcher 裁决是线索不是判决：DONE 收货走 dispatch-baseline「收工核证四件套」（单源）；agent 自起后台
job 会呈 idle 但没完成——`沉默 ≠ 交付`。

## 引擎级注意

- **引擎额度是编排级单点**：omp/codex 默认走 OpenAI 后端——执行席 + 异构评审席可能共享同一 quota
  池，耗尽两线同瘫。
  start 回显 engine 行；高强度批跑前确认各后端余额；应急 = 执行席换 Claude（评审同 lineage 失异构
  价值，标注即可）。
- **omp `--model` fuzzy match 会开交互 picker** 吃掉派发（会话卡在选择器）——引擎 args 只传 EXACT id
  （`--model=anthropic/claude-opus-4-8`）。
- **裸 send-keys 坑**由 guard ④ 拦（长/CJK 文本在人工 attach 面必坏），控制一律走协议帧。
- omp rpc 面无版本稳定性文档：launch 的 ready 握手即 preflight，握手失败 = fail-fast 清场重来，
  不带病跑。
- **claude 边界送达的 turn 归属无引擎关联面**（诚实边界）：turn A 运行中送达 steer B（degraded 已明说），
  A 的 result 先落盘——`status` 单发可能把它读成终态；`watch` 的 2 连读稳定门 + deliverable
  gate 是真消费路径（A 完成后引擎立即起 B，下一读即 RUNNING）。turn 级关联等 P2
  （codex app-server 上车时统一按 id 解）。

## 强制层：两个单一职责 guard 脚本

脆弱完成信号会骗编排者，光记规则没用 → 工具调用层兜底（[电在回路](../shock-in-the-loop.md)：DENY
三件套 = why + 正路 + 本文档指针）。**entry 真源 = 本目录 `guard-hooks.json`**（唯一权威）：接入时把
command 换成安装根绝对路径（hooks 不展开 `~`）、按 event 并进项目 settings（CC
`.claude/settings.json` / Codex `.codex/hooks.json` 同格式）。**直接 exec 别加 `python3` / `bash`
前缀**（脚本自带 shebang）；matcher 别手编（与实现同包维护，抄本必漂移）。

**扩展 = 组合，不 fork 不注入**：项目/席位要自己的规则（如构建工具锚定、
项目特有禁令），在**自己的** settings 里并列再挂一个自己的 hook 脚本——hooks 是列表、逐个都跑、
任一 exit 2 即 DENY，天然可组合零耦合。本 guard 不提供加载外部规则的扩展点（repo 内代码进 hook
进程 = 任意仓库可执行代码，红线）；自写 guard 建议沿用 DENY 三件套 + 可解析文档指针的契约。
「单 SoT」按**规则**算不按文件算：本 guard 已盖的面（git/gh 锚定）别再自建双源，没盖的面自己的
规则就是唯一正源。

- **`cto-guard-bash.py`（PreToolUse·Bash）** — ① 拦背景 `&`（剥引号 span 后任意单 `&`；`&&`/重定向/
  引号内放行）；② DENY 纯 idle-absence 裸轮询（带 git 交付物 / Verdict 正向 grep 才放行）；③
  `agentctl start` 后同条没 arm watch → 提醒（omission 无法硬 deny）；④ 拦长/CJK 裸 `tmux send-keys`
  （逼 `agentctl steer`）；⑤ 拦前台阻塞 `agentctl watch`（前台 Bash 超时会连 watcher 一起杀；
  `AGENT_WATCH_SYNC=1` 显式放行）；⑥ 拦编排者亲跑 live e2e（派便宜模型 runner，命令前缀
  `E2E_ECONOMY=1` 自 declare）；⑦ worktree 生命周期：非 force `git worktree remove`
  常设放行（git 自拒脏树、可逆）；`--force`/`-f`/`prune` DENY（force 碾 untracked、prune 按
  staleness 猜删）——正路 = 先 `git -C <wt> status --porcelain` 独立命令抢救核证再请示，
  验证与销毁绝不同一命令行；已批销毁走一次性 override `touch /tmp/cto-allow-worktree-destroy`
  （消费即授权、用后即焚）；纯元数据且 porcelain 证明零文件伤害的单命令 prune 放行。⑧ 伞形多仓工作区拦无锚 `git`/`gh`（cwd 漂移打错仓；
  判据与正路见 [§cwd 锚定](#cwd-锚定多仓工作区)，单仓项目永不触发）；⑨ 浏览器归属：`playwright-cli attach`
  带接管旗标（CDP / 浏览器扩展）→ 默认 DENY，主理人批后 `touch /tmp/cto-allow-browser-attach` 一次性放行；正路 = `open` 起隔离浏览器（与 agent 侧 P0a 同一条规则的两个通道，
  见 [frontend-verify](../frontend-verify.md)）；⑩ 拦裸 `codex exec` / `codex e` / `codex review`（手搓 headless codex 无 typed 状态、同命令 heredoc 必等 stdin EOF 挂死；正路 = lane 评审档 `--review`；`exec-server` / `--version` / `login` / `agentctl start codex` 不拦）；⑪ typed 命令（`agentctl watch/steer/start/stop`、`gh pr checks --watch`、`gh run watch`）位于管道**非末端** → DENY（末端放行；rc 被末命令吞、帧被截）；⑫ 门命令段以 `;` 结束且其后接 `git commit` → DENY（commit 不再依赖门 rc；`&&` 链放行）；⑬ 直接派 `agentctl start codex --goal <brief>` 时扫该 brief 的六个字面攻击词 → WARN（brief 读不到也 WARN）；⑭ `agentctl start … <cwd>` 且 `git -C <cwd> status --porcelain` 非空 → DENY（先 seed commit）；⑮ `<cwd>/BLOCKED.md` 存在 → DENY（先收割）。
  ⑳ 编排位经 bash **三类可解析字面文本写入**触及源码/测试路径 → DENY（= edit 侧 E1 同一条规则的 bash 通道：
  auto mode 下 harness 优先用 Bash 改文件，E1 挂在 Edit|Write 上对这条路径是纸门——2026-09-02 编排位与冷评审
  各自实测 heredoc / 追加重定向 / `tee` / `sed -i` 四形态全 rc=0）。**覆盖面就是这三类，别读成"bash 写文件都拦"**：
  重定向族 `>` `>>` `&>` `&>>` `N>` `N>>` 指向一个路径（`>&N` / `N>&M` 是复制不是写文件；`/dev/null` 之类不带
  源码扩展的目标本来就过不了源码面，不另设特例）；`tee` 的**每个**
  路径参数（含 `-a` / `--`，任一命中即 DENY）；`sed` 就地（`-i` / `-iSUF` / `-i SUF` / `--in-place[=SUF]`，命中后该段
  所有位置参数逐个过源码面）。**带空格的字面路径也算字面**：`> "…/a b/x.py"` 与 `> …/a\ b/y.py` 都判（判定读
  操作符偏移处的**原始字节**再按 shell 规则去引号/去转义，不读会把 quoted span 抹成 `ARG` 的通用视图）。
  判定在 shell **执行面**做：引号内、`#` 注释后与 heredoc 正文里的 `>` 是 DATA。**accepted-uncovered，
  不声称覆盖**：`cp` / `mv` / `install` / `dd of=` / `rsync` / `git apply` / `patch` / 编辑器 / 解释器内写文件
  （`python - <<EOF` 里的 `open().write`）；目标含 `$`、反引号、`$(`、glob（`* ? [`）或前导 `~` → 不可判，
  ALLOW + 一行 WARN 且**不消费** override；目标缺失（行尾裸 `>`）→ 静默。席位归属、override、降级方向与 E1 同源
  （代码 import 复用，不复制）：活体席位写自己 worktree 放行、`touch /tmp/cto-allow-direct-write` 一次性放行、
  run dir 不可读或目标不属任何受管 work tree → ALLOW+WARN。铁律出处见 [SKILL §0 铁律①](../../SKILL.md)。
  git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
- **`cto-guard-edit.py`（PreToolUse·Edit|Write|MultiEdit）** — E1：编排位对源码/测试文件的写入 → DENY
  （活体席位自己的 cwd 放行；`/tmp/cto-allow-direct-write` 一次性放行；run dir 不可读 → ALLOW+WARN）。
- **`cto-guard-agent.py`（Pre·Agent|Task|TaskStop|KillShell + Post·Agent|Task）** — Pre·Agent：
  browser/E2E 派发含 `mcp__chrome-devtools` → DENY（逼 Playwright，P0a）；派发未显式钉 `model` 档 →
  DENY（P0c）；e2e-runner 派发 model 非便宜档 → DENY（P0d）；Pre·TaskStop|KillShell：目标 `.output` 与 subagent transcript 取最鲜 mtime，
  120s 内还在长 = 活的 → DENY（Agent 型 `.output` 常是静态 stub，判活主要靠 transcript）（**完成通知黑洞**与"零截图≠卡死"实证；override =
  `touch /tmp/cto-allow-kill-<id>`，适用于**任何经核实的杀单动机**——含"派错前提"，P0b）；
  Post·Agent：browser 派发注入 deadline-watch 提醒（必须 JSON `additionalContext`，纯 stdout 黑洞）。

### Wiring（CC / Codex / omp 都能坐编排位）

| | Claude Code | Codex | omp (oh-my-pi) |
|---|---|---|---|
| hook 形态 | command 脚本 + stdin JSON | 同 CC（契约对齐） | in-process TS/JS 模块 |
| 两脚本直接挂 | ✓ | ✓（agent 脚本休眠） | ✗ 需 TS port（`{block:true,reason}`） |
| wiring | `.claude/settings.json` | `.codex/hooks.json` | `.omp/hooks/pre/*.ts` |

不另造 settings 脚手架——并进 `repo-governance-bootstrap` §11 已建的那份。**不靠 skill frontmatter
`hooks:` 自注册**（mid-session 经 Skill 工具激活不注册 → 显式 wiring 才可靠）。

## cwd 锚定（多仓工作区）

伞形多仓里 shell cwd 跨调用漂移会让 git/gh 打错仓——每段含 git/gh 的命令自带锚（`cd /abs/<repo> && …`
或 `git -C <path>` / `gh -R <owner>/<repo>`）；guard ⑧ 在伞形根硬拦无锚 git/gh，单仓永不触发。

guard ⑧ 的判据（2026-09-02 收窄；两机 728 次真实 DENY 里 598 条是这条规则，按 hook cwd 归因最大的桶全是
session 自己的项目根——那种 cwd 打不到别的仓）：**只在 cwd 或 5 层祖先内存在多仓伞形时评估**（扫描语义不变，
单仓永不触发）；评估时 **cwd 所在 git 顶层 == 本 session 项目根 → 不触发**（Claude Code 里 shell cwd 在项目树内
跨调用持久、`cd` 出项目根后下一条被拉回，所以这种 cwd 不可能是漂到兄弟仓的 cwd；session 根从 hook payload 的
`transcript_path` 父目录名反解：目录名 = 项目根路径把每个非 `[A-Za-z0-9]` 字符换成 `-`——**实测归纳、非官方契约**，
所以只用一个方向：相等才放行）。**照拦**：session 根本身就是伞形（2026-07-26「PR 开错仓」的形态）、cwd 落在伞形内
另一个仓（含该仓之下的嵌套仓）、payload 无 `transcript_path`（codex 席位）。**cwd 不存在 / 不可列**不在照拦面上：
`_umbrella_near` 直接返回 None，规则从不评估（fail-open，oracle = 断言 `unreadable cwd fails open`）。三条 accepted 边界：
① 外层仓 + 单个嵌套仓且 5 层祖先内无伞形 → 规则从不评估（现状，不变；钉成断言
`r8-doc-nested-no-umbrella-never-evaluates` + 加一个直接子仓即翻成 DENY 的对照）；② slug 编码非单射，同一伞形下仅以标点
区分的兄弟仓（`a.b` / `a-b`）会互认 → 放行，accept-documented（钉成断言 `r8-doc-slug-collision`，要改方向先改
那条断言与本节）；③ cwd 经 symlink 指到仓根时按 realpath 判，slug 不等 → 照拦（保守方向）。
