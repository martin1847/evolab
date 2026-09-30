# agentctl — headless worker 控制面（一条 duplex lane、三引擎）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**，
一条 duplex lane、三引擎各跑原生 stdio 协议长驻（omp `--mode=rpc` / claude stream-json /
codex app-server），能力差异不分叉车道、由接口干净拒绝。tmux 只做进程保活（worker 独立于
编排者进程树）；终态真相只来自 typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 本文只写 CLI 讲不了的：语义、失败形态、判断。能从 `agentctl` / `capabilities` / `states` 问出来的
> 事实以 CLI 为准；本文偶有的复述（exit 码、resume 命令、env 覆盖）漂移时 CLI 赢。

## agentctl —— 当前命令面

命令面由 CLI 自述（裸跑 `agentctl` 出 usage、`capabilities` 出能力契约、`states` 出状态词表），此处只写语义、失败形态、判断。

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
  **`-m` 正文禁命令替换**（反引号 / `$(` 在 shell 阶段就展开、例子命令真被执行；单引号内同拦，`<<'EOF'` 正文是 DATA）：guard ㉑ DENY，正路 `-f <file>`。
- **steer 队列可见**：`queued=N` 只是引擎报的深度，lane 自己记 sidecar `<s>.steer-log.jsonl`；
  `status` 在 N>0 时按深度列出末 N 条，无队列面的引擎零输出。stop 随控制态一起清。
- **typed exit 三引擎同词汇**（词表 `agentctl states`，处置见下节）；
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **`start` 默认模型来自环境变量**（`agentctl` usage 列优先级）：显式 `--model` > `AGENTCTL_MODEL_<E>_REVIEW`（仅 `--review`）
  > `AGENTCTL_MODEL_<E>_DEEP`（仅**非 review** 且 goal `Tier:` 判 deep，口径 = goal-preflight `TIER_LINE`；review 席未设 `_REVIEW` 即直接落基础变量）> `AGENTCTL_MODEL_<E>` > 引擎默认；
  start 回显标来源 `(from AGENTCTL_MODEL_<E>…)`；`--resume-thread` 忽略（线程保留创建时的模型）。omp 依旧只传 EXACT id（见 §引擎级注意）。
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
- **supervised watch（默认）**：感知环跑在独立 tmux 会话 `<session>-watchd`，宿主侧 `agentctl watch` 只是哑等待者——
  被外部 TERM 后原地重挂即恢复同一 class + exit，本轮结论不丢。生命周期绑 attempt（`start` / `stop` / `steer --interrupt`
  回收，普通 `steer` 保留）。降级只在结构性不可能时发生且 stderr 明说 "NOT kill-resilient"；同名 `<s>-watchd` 在但没有
  本 identity 的租约 = `12 reason=unknown` + 清理指引（`tmux kill-session -t <s>-watchd` 后重挂），绝不静默 inline。
  `--inline` = 进程内轮询（被杀即丢本轮结论，不跟随）。
- **waiter 默认跟随会话**：steer 轮转对等待中的 waiter 透明；`WATCH-TIMEOUT` / `SUPERVISOR-LOST reason=dead` 打完整 typed 行 +
  `EXIT=` 后**有界**自动重挂（`AGENT_WATCH_FOLLOW_MAX`，默认 8；0 = 单轮）；动作类判决立即以该码退出。跟随中每轮各有
  一行 `EXIT=<n>`，进程**最后一行**才是退出码。
- **输出有界**：`status` 回 typed 一行 + 摘要（+ 至多 4 行错位产物提示，见 exit 6）；terminal record 的 detail ≤600 字符、
  按整行截并以 `…[detail truncated; …]` 标记行收尾，绝不半截 JSON。引擎 raw 全量只落 `$RUN/<s>.duplex.events.jsonl`（单条可达
  百 KB，回显有界是硬设计）；omp 的 `message_update/*_delta` 帧在 pane 管道里整行滤掉（`*_end` 帧带全文，控制面零损失）。
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
- **preflight 门默认开**：起引擎前于席位 cwd 调 `../goal-preflight.py`——`Preflight:` 行缺失 / 占位未解、或 PREMISE 行实跑与作者 `rc=` / `count=` 记号不符即拒发（形态规则见 `goal-template.md` §Premises 与脚本头注）；`--no-preflight` 显式豁免（判据归 SKILL.md §1）；命中本 goal 写集（Task 路径 ∪ `--deliverable`）且未锚 pinned base 的活树探针只 WARN。
- **`--expect <分钟>` = 本轮等待预算**（`start` 声明、`watch --expect` 覆盖；不给 = 关闭）：超 1.5× 且引擎还在跑 → typed `OVER-BUDGET`（每 (attempt, round, 预算值) 报一次；`status` 在 RUNNING 上打 `note: over budget by …min`）——只说等待超了，不说工作没进展。抬高预算重挂 = 在新阈值再报一次（同值不重报），长跑轮次的周期唤醒就是这么拿的。
- **席位不能观测/操作自己**：pane 注入 `AGENTCTL_SESSION`，`watch/status/steer/stop/start` 目标等于它即参数面拒（rc=1，非 typed 判决、不打 `EXIT=` 尾行）——席位在自己 turn 里等自己的交付物是死锁；要停下等裁决写 `BLOCKED.md` 并结束本轮，要报进度写进交付物。席位自行 unset 该变量可绕过 = accepted 边界（防手滑，非对手模型）。
- **watcher 被外部杀（TERM）= 预期可恢复态**：收到 killed 通知即重挂（supervised 下只是重新读记录）。归因看 tombstone
  `$RUN/<s>.watch.tombstone.jsonl`（ts / signal / ppid / uptime）；宿主一次事件会成批收割全部后台 watcher，且 killed 通知
  可能随会话丢——`status` 对 RUNNING+无 watcher 的会话自动打死亡归因行；重挂或 `stop` 即消费 tombstone，已消解的死亡不复报。
- 引擎二进制可用 env 覆盖（测试缝 + 自定装机位）：`AGENTCTL_BIN_OMP` / `AGENTCTL_BIN_CLAUDE` / `AGENTCTL_BIN_CODEX`。
- exit 6 `IDLE-NO-DELIVERABLE` 用 `agentctl steer` 补一刀，**不要 stop**；`stop` 只用于收工或明确放弃。
  verdict 行后可能跟 `possible misplaced deliverable: "<abs path>"`（有界扫 cwd 找同名错位产物，
  json 编码防伪造 typed 行；只提示、不改 rc，无命中/扫描退化都零输出）——先看这行再决定 steer 措辞。
- **stop = 进程组收割 + 按会话标签收割组外进程**：pane 进程组 TERM → 有界宽限（`AGENTCTL_REAP_GRACE`）→ 强杀 → 复核；再按 pane
  导出的 `AGENTCTL_SESSION` + `AGENTCTL_CWD`（环境成员精确相等、非 ps 字面量；pid 复用即跳过）逐个收割逃出进程组的子孙，输出
  `reaped N lineage process(es)`。**判不出就不杀、只 stderr ADVISORY**：候选的 cwd 属于另一个活会话（共享 broker）、任何一格不可判、
  无标签幸存者、环境读不到的进程（只出一行 `[unknown] N process(es) with unreadable environment` 计数，不算候选）。标签 FN 边界
  （ADVISORY 的沉默也不覆盖）：tmux server 派生、`env -i` 后派生、共享工具替**别的** client 派生、快照后新派生、macOS SIP 二进制。
  无 pane、无 meta 的会话再跑一次 `agentctl stop <s>` = inventory 报 `lineage-orphan` 后的唯一出口。
- **`agentctl inventory --dry-run`** = 三块只读普查（控制态 vs tmux 漂移 / PID 1 收养的引擎孤儿 / lineage census），永不发信号；
  终态后**立即 stop 是编排者纪律**（retro-check 第 6 检兜底）。
- **`agentctl phases [--since …] [--repo <abs>] [--json]`** = 相位账本读数（batch_span / seat_wall / review_wall / idle_span / 逐 terminal
  dispatch_latency + `coverage: ok|partial|unknown`）——**只出数，不出裁决**，台账的 `wall=` / `avoidable=` 仍是你的判断。

## typed 状态：处置（词表由 `agentctl states` 自述）

exit code、名字、语义、二级子原因词（`reason=<word>`，闭集）都是运行时事实 →
`agentctl states`（`--json` 机器读），此处不留第二份。**本节只写 verb 故意不发布的那一列：
处置**——它是判断，不是事实。

| 状态 | 编排者要做什么 |
|---|---|
| DONE | 收货前仍做正向核证（下节），别只认 typed 行。行尾 `dirty=<N>` = **排除声明产物后**（declared `--deliverable` glob + `<cwd>/BLOCKED.md`）仍未提交的路径数：`500+` 是**超扫描上限的告警、不是精确值**；**字段缺席 = 未判定**（cwd 非 git 树 / 探针失败 / 预算用尽），**绝不读成干净**。`>0` 或缺席都先手跑 `git status` 再收货；`0` 只证「排除声明产物后无未提交路径」，**不证整树干净** |
| FAILED / AGENT-DEAD | 读 events/stderr 尾（有界），走恢复腿 |
| WAITING-INPUT | 读题，`agentctl steer` 作答 |
| STALLED-EXTERNAL | 修凭据/额度再重启；见引擎级注意 |
| IDLE-NO-DELIVERABLE | poke（steer），别信幻影 DONE、别 stop |
| WATCH-TIMEOUT | 重挂或人工核证，**绝不按 DONE 消费**。行尾 `progress=changed\|unchanged\|unknown` 是进展源的观察结论，不是工作量判决：`unknown` = 探针关闭 / 未测 / 末次读零可判源 / 整段窗口从未测到过一次可判的**移动**（窗口由不可判读开启或重建，恢复后只重建基线），绝不读成「没进展」 |
| ENGINE-SILENT | 查 stderr.log；必要时 stop+resume |
| BUDGET-EXHAUSTED | 转人工裁决 |
| RUNNING | 继续等 |
| STALLED-STREAM | **先从 checkout/commits 抢救成果，再 stop**；探针任一不确定按 RUNNING 处理（宁钝勿敏）。窗口用 `AGENT_WATCH_STALL_MINS` 调、0 关 |
| STALLED-PROGRESS | 流还活着，但整个窗口内可判的进展源（仓库痕迹 / 引擎工具帧计数 / pane 进程组；三源细则归源码头注）在每个采样点都没动。窗口 `AGENT_WATCH_PROGRESS_MINS`（默认 30min）、0 关；探针超预算按不可判计。**处置按 `reason=` 分支**：<br>· `repo-silent+tools-silent` → **先读 events 尾**——无效循环 → `steer` 给具体下一步；方向已错 → `--interrupt` 重开；确认走死 → 抢救成果再 stop。<br>· `unknown-source` → 有源量具坏（detail 点名哪个）：先修那个源或人工核证，别当「席位停滞」直接 steer/stop。<br>· RUNNING 行上的 `progress_reason=repo-silent+tools-active` → 引擎在动（长测试 / docker / 取证）：**继续等**。<br>量具坏后恢复的第一次可判读只重建基线、不算移动 |
| OVER-BUDGET | **等待**超预算（`--expect`×1.5），不是工作没进展：读行后事件尾 → `steer` 给下一步 / `--interrupt` 重开 / `watch --expect <更大值>` 重挂继续等（新阈值再报一次，同值不重报；at-least-once）。预算是否合理是你的估计问题 |
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
  gate 是真消费路径（A 完成后引擎立即起 B，下一读即 RUNNING）。

## 强制层：单一职责 guard 脚本

脆弱完成信号会骗编排者，光记规则没用 → 工具调用层兜底（[电在回路](../shock-in-the-loop.md)：DENY 三件套 = why + 正路 + 本文档指针）。
**entry 真源 = 本目录 `guard-hooks.json`**：接入时 command 换成安装根绝对路径（hooks 不展开 `~`）、按 event 并进项目 settings
（CC `.claude/settings.json` / Codex `.codex/hooks.json` 同格式）；直接 exec 别加 `python3` / `bash` 前缀；matcher 别手编。
**扩展 = 组合，不 fork 不注入**：要自己的规则，在自己的 settings 里并列再挂一个 hook 脚本（任一 exit 2 即 DENY，零耦合）；
本 guard 不加载外部规则（repo 内代码进 hook 进程 = 红线）。「单 SoT」按**规则**算：本 guard 已盖的面别再自建双源。

- **`cto-guard-bash.py`（PreToolUse·Bash）** — 每条规则的判据、正路与边界正源 = DENY 文案本身（why + 正路 + 指针）+
  源码里该规则块的注释（源码内序号是实现顺序，与本索引的圈码不同源，按关键词找）。圈码是 SKILL / DENY 指针 / 测试
  `r<n>-*` 共用的公开身份，本文只留索引：① 背景 `&`（orphan）· ② idle-absence 裸轮询 · ③ `start` 后未
  arm watch → 提醒 · ④ 长/CJK 裸 `tmux send-keys` · ⑤ 前台阻塞 `agentctl watch` · ⑥ 编排者亲跑 live e2e
  （`E2E_ECONOMY=1` 自 declare）· ⑦ `git worktree remove --force` / `prune`（先独立命令 `status --porcelain` 核证再请示；
  已批走一次性 `touch /tmp/cto-allow-worktree-destroy`）· ⑧ 伞形多仓无锚 `git`/`gh`（见 [§cwd 锚定](#cwd-锚定多仓工作区)）·
  ⑨ `playwright-cli attach` 接管旗标（已批走 `touch /tmp/cto-allow-browser-attach`；正路 `open` 起隔离浏览器，见
  [frontend-verify](../frontend-verify.md)）· ⑩ 裸 `codex exec|e|review`（正路 lane `--review`）· ⑪ typed 命令在管道非末端 ·
  ⑫ 门命令 `;` 后接 `git commit` · ⑬ codex brief 含攻击词 → WARN · ⑭ 派工 cwd 脏 · ⑮ `<cwd>/BLOCKED.md` 未收割 ·
  ⑯ 保姆轮计数 → WARN · ⑰ 评审派发无 `--max-rounds` · ⑱ 历史重写与他步同链 · ⑲ 验证批跨仓 cd → WARN ·
  ⑳ 编排位经 bash 三类字面写入（重定向族 / `tee` / `sed -i`）触及源码面 → WARN 留痕（= E1 的 bash 通道；`cp`/`mv`/`git apply`
  等 accepted-uncovered；不可判目标同样 ALLOW+WARN）· (21) `steer -m` 含反引号或
  `$(`（正路 `-f`）。git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
- **`cto-guard-edit.py`（PreToolUse·Edit|Write|MultiEdit）** — E1：**本仓正在被编排时**，编排位对源码/测试文件的写入 → WARN 留痕
  （「正在被编排」= 同仓有 LIVE 席位或今/昨相位账本 `start` 行，同仓 = git common dir；判 not 则零输出放行，不打扰单 agent 会话；
  活体席位自己的 cwd 零输出放行；run dir / 账本不可读 → ALLOW+WARN）。
- **`cto-guard-agent.py`（Pre·Agent|Task|TaskStop|KillShell + Post·Agent|Task）** — Pre·Agent：browser/E2E 派发含
  `mcp__chrome-devtools` → DENY（逼 Playwright）；派发未显式钉 `model` 档 → DENY；e2e-runner 派发 model 非便宜档 → DENY；prompt 里的绝对路径若是落后 upstream 的 git 树 → WARN+UNMEASURED（P0e `stale-scout-cwd`，≤4 树 / 6s 预算，永不 DENY）。**只管主位**：agentctl 起的席位（env `AGENTCTL_SESSION`）模型已由派发者钉死，P0c/P0d 在那里静默；两级同接按 `tool_use_id` 去重，一次派发只判一次。
  Pre·TaskStop|KillShell：目标 `.output` 与 subagent transcript 取最鲜 mtime，120s 内还在长 = 活的 → DENY（override
  `touch /tmp/cto-allow-kill-<id>`，任何经核实的杀单动机都适用）。Post·Agent：browser 派发注入 deadline-watch 提醒。
- **`cto-guard-stop.py`（Stop）** — **本仓正在被编排**且本仓席位 `agentctl status` 说 RUNNING 且附 `no watcher armed`：
  结束 turn 时 block（reason 三件套）。「本仓」= 与 payload cwd 同 git common dir（兄弟 worktree 算本仓，另一 checkout 不算）；
  席位普查 / 归属过滤 / 谓词在同目录 `seat-census.py`（纯库、无 entrypoint）与 `identity.py`（`orchestrated`，E1 / 压缩提醒共用），import 复用不复制。
  **判不出一律 exit 0 + 一行 `systemMessage` WARN，绝不 block**；fail-open / 归属过滤 / 有界细则见两文件头注与 `test/cto-guard-stop.test.sh`。

### Wiring（CC / Codex / omp 都能坐编排位）

| | Claude Code | Codex | omp (oh-my-pi) |
|---|---|---|---|
| hook 形态 | command 脚本 + stdin JSON | 同 CC（契约对齐；Stop 同构 `stop_hook_active` + `{"decision":"block"}`） | in-process TS/JS 模块，需 port，Stop 契约未实证 |
| wiring | `.claude/settings.json` | `.codex/hooks.json`（非托管 hook 首次需用户 `/hooks` 信任，按 hash 记账、脚本一改重新信任） | `.omp/hooks/pre/*.ts` |

并进 `repo-governance-bootstrap` §11 已建的那份 settings，**不靠 skill frontmatter `hooks:` 自注册**（mid-session 激活不注册）。
层级：cto-guard-edit / -stop / retro-reminder 自认仓库身份（非编排仓静默），cto-guard-agent 自认席位角色（agentctl 席位下只静默 P0c/P0d）→ 都接**用户级**；
cto-guard-bash（除 ⑧⑳）是角色属性 DENY 门 → 只接**项目级**，两级同接会双触发。
接完自检：edit / stop 用非编排仓 cwd 喂合成载荷应零输出；agent 用 `AGENTCTL_SESSION=x` 喂无 `model` 载荷应零输出、去掉它应 DENY；
bash 只验「别的仓的 settings 里没有它」。Codex Stop 片段（结构以 codex 官方文档为准）：
`{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/abs/<安装根>/references/agentctl/cto-guard-stop.py"}]}]}}`。

## cwd 锚定（多仓工作区）

伞形多仓里 bare git/gh 会打在 cwd 所在的仓——未必是你以为的那个；每段含 git/gh 的命令自带锚：`cd /abs/<repo> && …`、
`git -C <path>`、`gh -R <owner>/<repo>`。guard ⑧ 只拦 **cwd 是伞目录本身**（直接子目录 ≥2 个带 `.git` 的仓、且 cwd 不在任何工作树内）
时的裸 git/gh；cwd 在工作树内一律不拦，判不出 → 不拦 + 一行 WARN。**明示放弃的覆盖**（效率优先）：cwd 漂到兄弟仓后的裸 git、
伞仓子仓下再嵌套的仓、单条命令内 `cd ../B && git …`——回到「作用于 cwd 所在仓」的普通语义。判据与 accepted 边界见
`cto-guard-bash.py` 规则 (8) 注释与 `test/cto-guard-bash.test.sh` 的 `r8-*` 断言。
