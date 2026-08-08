# agentctl — headless worker 控制面（一条 duplex lane、三引擎）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**，
一条 duplex lane、三引擎各跑原生 stdio 协议长驻（omp `--mode=rpc` / claude stream-json /
codex app-server），能力差异不分叉车道、由接口干净拒绝。tmux 只做进程保活（worker 独立于
编排者进程树）；终态真相只来自 typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 目录：[agentctl 命令面](#agentctl--当前命令面) · [Why](#why为什么是协议不是屏幕) ·
> [duplex 机制](#duplex-车道机制) · [Launch](#launch) ·
> [typed 状态](#typed-状态编排者纪律) · [判完成要正向证据](#判完成要正向证据不凭-idle--watcher-裁决) ·
> [引擎级注意](#引擎级注意) · [强制层 guard](#强制层两个单一职责-guard-脚本) · [Validation](#validation-status当前态快照过程史在-git-log)

## agentctl —— 当前命令面

```text
agentctl start  <omp|codex|claude> <session> <cwd> --goal F [--deliverable G] [--no-preflight] [engine args…]
agentctl steer  <session> (-m TEXT | -f FILE) [--now | --replace] [-d G]
agentctl status <session>      # one-shot typed verdict（exit code = 结论）
agentctl watch  <session> [--inline]   # 阻塞至终态；run_in_background 挂起（默认 supervised，见下）
agentctl stop   <session>      # 结束 + 按进程组收割整棵树 + 清控制态（events/rc/stderr 留作尸检）
agentctl capabilities [--json]  # 运行时生成的三引擎能力契约（路由与本表同源，唯一真源）
```

- **steer 语义**（能力差异拒绝制，不分叉车道）：三引擎能力矩阵由 runtime 生成，`agentctl capabilities`
  是唯一真源（同一张表既驱动路由、又出拒绝文案）。投递成功 ≠ 模型照做，验收仍看交付物。
- **typed exit 三引擎同词汇**（全表见 [typed 状态](#typed-状态编排者纪律)）；
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **deliverable gate**：相对 glob 一律按**会话 cwd** 解析；freshness
  用 mtime 对 epoch（每次 steer 即轮转）；必带/不带的判据归 SKILL.md §0。
- **尾行机器可读**：`watch` 四类出口（终态 / 非终态 / ENGINE-SILENT / TIMEOUT）都在 typed
  `=== … ===` 行之后追加最后一行 `EXIT=<n>`——包装层（管道 / 后台 harness）吞掉进程退出码时仍可解析；
  文案与 exit code 均不变。`status` 读到 RUNNING 而**无存活 watcher**（pid 文件缺失、或进程已亡）追加
  一行 `note: no watcher armed — arm: agentctl watch <S>`：只提醒不代挂，typed 行与 exit code 不动。
- **supervised watch（默认）**：感知环（classify 轮询）跑在 tmux 里的独立会话 `<session>-watchd`，
  宿主侧 `agentctl watch` 只是**哑等待者**——只读围栏过的终态记录，自己不 classify、不重算。
  被外部 TERM 后原地重挂即从记录恢复同一 class + exit（重挂不再是一轮重算）。守护环用
  `$RUN/<s>.watch.super.json` 发租约（pid@start-time + identity token + 轮次 + 心跳 mtime）；
  日志 `$RUN/<s>.watch.super.log`，退役/被围栏拒绝时的遗言落 `$RUN/<s>.watch.super.exit`
  并由等待者原样转述。生命周期绑 attempt：`start` / `stop` / `steer --replace` 退役并回收守护环，
  普通 `steer`（同 attempt、下一轮）保留它。**降级只在守护结构性不可能时发生且响亮告警**：无 tmux /
  run 目录不可写 / **本等待者自己起的**那个 pane 在 arm 窗口内没发租约（这三种情况下守护环在此环境
  根本跑不起来，宁可失去抗杀性也不能拒绝观测）——降级前先回收自己起的那个 pane，stderr 明说
  "NOT kill-resilient"。**同名 `<s>-watchd` 已存在却没有本 identity 的租约 = 不可判，不是降级理由**：
  等待者返回四态机④ `12 SUPERVISOR-LOST reason=unknown`，detail 点名 rogue/wedged watchd 与清理指引
  （`tmux kill-session -t <s>-watchd` 后重挂），绝不静默 inline——一个空转的同名会话曾因此长期抹掉
  canonical 入口的抗杀收益（评审 F-05）。`--inline` 仍是显式兼容旗标，语义 = 未引入守护环之前的
  进程内轮询（不落非 DONE 记录，被杀即丢本轮结论）。
- **输出有界**：status/watch 只回 typed 一行 + ≤600 字符摘要；引擎 raw 全量只落
  `$RUN/<s>.duplex.events.jsonl`（单条 raw transcript 可达百 KB 级，回显会炸编排者上下文——
  摘要有界是本控制面的硬设计）。
- **后台任务 cwd 语义**：宿主后台机制跑 `agentctl watch` 时，命令继承**发起时刻
  编排者的 cwd**，与 worker 会话 cwd 无关；判断后台任务归属认 `$RUN/<session>.*` 文件名，别认 cwd。
- 需要人工现场 = `tmux attach -t <session>` 旁观 / `tmux capture-pane -p`
  手动尸检；worker 控制始终走协议。

## Why：为什么是协议、不是屏幕

三引擎都有官方 headless 双工面——直接消费结构化事件流 + 进程退出与文件，状态**确定可判**；
抓屏猜状态与 send-keys 注入不可靠。完整数据与论证见 meta 文《protocol-not-screen》。

## duplex 车道机制

```text
tmux pane 内：  exec 3<>$RUN/<s>.duplex.in            # fifo 读写打开：引擎 stdin 永不 EOF
               <engine-cmd> <&3 >> events.jsonl 2>> stderr.log
               echo $? > rc.tmp && mv rc.tmp rc        # 引擎退出才落 rc（tmp+rename 原子发布）
engine-cmd：   omp --mode=rpc …                        # JSON-line RPC（steer/follow_up/get_state）
               claude -p --input-format stream-json --output-format stream-json \
                      --verbose --permission-mode bypassPermissions …
               codex app-server                        # JSON-RPC（handshake 建 thread，v1 参数形状）
steer/status： duplexctl.py 产协议帧 → flock 单写者写 fifo；投影只认 steer 后完整帧
               （omp = 活体 get_state 往返；claude = result 帧；codex = turn/completed）
```

- goal 投递 = `prompt` 帧（正文 = goal 文件 + HEADLESS 协议 footer：立即开工、真阻塞写
  `<cwd>/BLOCKED.md` 停下——fresh BLOCKED.md 映射 exit 4，三引擎同协议）。
- **崩溃恢复腿**：照 `agentctl capabilities` 的 `resume` 行走——degraded 两家（`stop` 后重开会话、
  engine args 由 start 原样转发）正路在各自 note 里；codex 唯一 supported，握手内续 thread：
  `agentctl start codex <s> <cwd> --goal <f> --resume-thread <threadId>`（supported 不带 note，故写这）。
- 单写者纪律：所有 fifo 写经 `duplexctl.py`（flock）；并发 steer 由锁串行。

codex 引擎注：app-server 官方标 experimental，但错误帧自描述（参数漂移当场报全量合法值）、
握手/turn/steer 全链实证；协议假设由 fake 引擎钉进 hermetic 门。`--workflow review-loop --max-rounds N`
预算与 SHIP-BLOCKING 续轮租约已移植进 duplex meta，三引擎通用（每次 goal/steer 投递计一轮，
超限 `BUDGET-EXHAUSTED` exit 9）。

## Launch

- `agentctl start … --goal <f>` 在 goal 帧被引擎接受后返回（omp 有 correlated response；claude 为
  送达即返，无逐帧 ack——诚实边界）；**不会自动 watch**，紧接着用宿主受控后台能力挂
  `agentctl watch <session>`（**NOT shell `&`**，会孤儿化；guard ⑤ 强制 run_in_background，
  同步 shell 编排者前缀 `AGENT_WATCH_SYNC=1` 显式放行并自读 exit code）。
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
- **stop = 进程组收割**（tmux kill 只碰 pane leader，引擎子孙会被 PID 1 收养泄漏）：
  pane 起在自有 session+group（pane_pid == pgid），stop 对该组
  TERM → 有界宽限（`AGENTCTL_REAP_GRACE`，默认 5s）→ KILL → pgrep 复核零残留；陈旧 meta 走
  leader lstart 指纹防 pid 复用误杀，永不按名字/全局杀。终态后**立即 stop 是编排者纪律**，
  retro-check 第 6 检对"本仓终态未清会话"blocking FAIL 兜底。

## typed 状态（编排者纪律）

| exit | 义 | 处置 |
|---|---|---|
| 0 DONE | 引擎 idle 且（如声明）交付物 fresh | 收货前仍做正向核证（下节） |
| 2 FAILED / AGENT-DEAD | 引擎异常退出 / 无 rc 且 pane 亡 | 读 events/stderr 尾（有界），走恢复腿 |
| 4 WAITING-INPUT | fresh `BLOCKED.md` / omp 真问题帧（setWidget 噪声已滤） | 读题，`agentctl steer` 作答 |
| 5 STALLED-EXTERNAL | 引擎死于 quota/auth 错误 chrome | 修凭据/额度再重启；见引擎级注意 |
| 6 IDLE-NO-DELIVERABLE | 终态样但声明的 glob 本轮没出现 | poke（steer），别信幻影 DONE、别 stop |
| 7 WATCH-TIMEOUT | 有界轮询耗尽、引擎仍 active | 重挂或人工核证，绝不按 DONE 消费 |
| 8 ENGINE-SILENT（duplex）| steer 已投递、引擎 ~2min 零输出 | 查 stderr.log；必要时 stop+resume |
| 9 BUDGET-EXHAUSTED | review-loop 轮数上限（steer 计轮） | 转人工裁决 |
| 10 RUNNING | 瞬时态（status 一次性查询用） | 继续等 |
| 11 STALLED-STREAM（duplex）| events 流停滞超窗（默认 12min，`AGENT_WATCH_STALL_MINS` 调、0 关）且引擎自身 lifecycle 帧无未配对在飞工作（tool_use/结果、command、后台任务、item——按引擎配对；进程年龄载不动请求边界，流才是主信号）且 pane 树无年轻子进程否决——「在想」与「挂死」由此分辨 | 先从 checkout/commits 抢救成果，再 stop；探针任一不确定按 RUNNING 处理（宁钝勿敏） |
| 12 SUPERVISOR-LOST（watch only）| 本轮**没有**围栏通过的终态记录，且感知守护环无法被证明在跑：`reason=dead`（进程没了）/ `reason=unknown`（租约缺失·损坏·陈旧·**租约没有 start-time**·pid 复用嫌疑·`ps` 探针本身不可用·**等待者自己那次 canonical 读超时**·**同名 `<s>-watchd` 在占名却没有本 identity 的租约（rogue/wedged）**·记录 torn/corrupt/不可读且守护环不可证活） | 重挂 `agentctl watch`（重建守护环）或 `agentctl status` 取一次性判定；detail 点名 rogue-watchd 时先 `tmux kill-session -t <s>-watchd` 再重挂；**绝不按任何业务结论消费**——12 说的是"判不出"，不是"完成"也不是"失败" |

新增 typed MESSAGE 行（**exit 码契约不变**，三类都映射到既有失败 / UNKNOWN 出口）：

| MESSAGE 行 | 触发 | 映射 exit | 处置 |
|---|---|---|---|
| `STALE-ATTEMPT` | 证据 stamp 的 `attempt_id` ≠ 活跃记录（精确串比） | 不改判：证据被丢弃后按本轮真实态出码（marker 路径落 2 AGENT-DEAD；BLOCKED 路径继续投影） | 视为**前一次 attempt 的遗留**，留盘做事后取证，别回填 |
| `STALE-INCARNATION` | `attempt_id` 相同但 `process_incarnation`（pid@start-time）不同 = pid 复用 / 换进程 | 同上 | 同上；说明有 impostor 或未走 resume 的重启 |
| `IDENTITY-UNKNOWN` | 活跃记录缺 / 损坏 / 无法解析、stamp 缺字段、start-time 信号取不到 | 2（既有失败出口，**永不映射成 0**） | 身份不可判定就不许收货：`agentctl stop` 后重启建立新 attempt |

**supervised 等待者判定状态机（唯一合同，按优先级）**——三条以外没有第四种走向，判不出一律有界 typed 12，
永不映射成 0：

| 优先级 | 输入 | 输出 |
|---|---|---|
| ① | 当前 identity **且**当前 round 的有效终态记录存在 | 该记录的 class + exit（终态优先：守护环「刚发布完就退出」不得被读成死亡） |
| ② | 无有效终态记录，且结构化证据证明守护环在跑（租约新鲜 + pid@start-time 对得上 + `ps` 探针自证可用） | 继续等（10 RUNNING 期间绝不误报死亡或终态） |
| ③ | 无有效终态记录，且证据证明守护环已死 | `12 SUPERVISOR-LOST reason=dead` |
| ④ | 无有效终态记录，且证据缺失 / 损坏 / 陈旧 / 不可判（含 pid 复用嫌疑与"租约无 start-time"、canonical 读自身超时、rogue 同名 watchd 占名无租约、记录 torn/corrupt/不可读且守护环不可证活） | `12 SUPERVISOR-LOST reason=unknown`，有界返回 |

租约陈旧窗按守护环**自己记录的 classify 预算**推导（`max(4×poll, 120s, statusTimeout+60s)`）：
`AGENT_WATCH_STATUS_TIMEOUT=300` 的合法慢 classify 在第 121 秒**不**判 12（评审 F-06）。
**停滞判定权只在轮询等待者手里，且只由它自己的 poll 计数产生，不由任何时钟产生**（评审 R2 F-03 /
R3 F-03）：轮询等待者每轮对租约内容取 checksum，连续采样内容没动才算 wedged。计的是**已流逝
interval，不是采样数**——n 次连续采样只能证明 n−1 个 interval 过去了（第一次采样只是立基线），所以
`需要采样数 = max(2, ⌈陈旧窗 ÷ 本等待者 poll 间隔⌉) + 1`。300s 预算（窗 360s）配 60s poll：第 6 次采样
只覆盖 300s，**不判**；第 7 次覆盖 360s，才判（评审 R3 F-02——把采样数当 interval 数会提前 60 秒
误杀一个仍在预算内的慢 classify）。纯计数、不读任何时钟，双向时钟跳变都动不了它。
**一次性读者**（`status`、挂载读、单发 `duplexctl watch-state`）没有自己的 poll 历史，因此**没有任何
年龄类判据**：它对租约只核**结构**——schema（数值有限且过下限）、identity 围栏、pid + start-time——
核不过照样 typed 12，核得过就是 alive，**永不因为"租约看起来旧"判 12**。此前它退回"租约 mtime 相对
文件系统时钟的年龄"（`fs_now` 探针），同一时钟域并不等于同一侧：整机时钟在租约写后前跳，两个 mtime
分居跳变两侧，一个 pid/start-time 全对的新鲜租约照样被判 wedged（评审 R3 F-03）。该探针已删除。
**已知限制（如实记）**：① 停滞判定权在轮询 waiter——`status` / 单发读**发现不了** wedged 守护环，
只会说 alive；要判停滞就得挂 `agentctl watch`（它本来就是唯一会被 12 打断的那条路径）。
② 自钟版发现 wedge 需要 N 轮自身 poll，比"一次读就判"慢一个窗口；外层 cap（`MAX×2+24` 轮）仍是兜底。

记录不可读**但守护环可证活** → 走 ②（它可能正在写）。活跃身份缺 / 损坏时等待者在挂载即
`IDENTITY-UNKNOWN` exit 2，连守护环都不建（没有身份就没有可发布的结论）。

- **attempt 身份三元组**：`session_id`（跨轮稳定）/ `attempt_id`（start 与 `--replace` 各换新）/
  `process_incarnation`（`pid@start-time`，pid 单独不够——会复用；tmux 名更不够——会重名）。
  pane pid 取不到时 `process_incarnation` 为 null，此时**改由 `incarnation_epoch` 兜底**（每次
  transition 铸的一次性值，随记录与终态 marker 一起落盘）：两个都"取不到"的生命因此不相等，
  两者都没有的历史记录拿到永不自等的 nonce——不可判一律 fail closed。
  唯一活跃记录写在 `$RUN/<s>.identity.d/active.json`，mkstemp 同目录 + fsync + `os.replace` 原子落盘。
  **提交点 = "该帧真要发出去"的那一刻，且在帧之前**：`start` 在首个 goal 帧前；omp `--replace`
  （`abort_and_prompt` 本身就是替换帧）在该帧前；**codex `--replace` 在引擎接受 interrupt 且被中断
  turn 到达终态之后、替换 `turn/start` 之前**——interrupt 超时被拒的替换**不换身份**（否则把仍然当前的
  attempt 变陈旧，连它自己后来的证据和已挂 watcher 一起误杀）。写失败则该 verb typed 失败且帧不发，
  前一份记录继续持有权威。排队 / `--now` steer 不换身份、不写盘。
- **活跃记录缺失与损坏同罪**：两者都 = 身份不可建立 ⇒ `IDENTITY-UNKNOWN` exit 2，不存在"没有记录就按
  legacy 放行"这条路（否则 rc/deliverable 腿会给一个没有身份的会话发 DONE）。
- **陈旧是读时派生**（stamp ≠ 活跃记录），陈旧文件**不回写**：唯一真相写者是活跃记录，旧证据留盘取证。
  watcher 只在"挂载时快照 == 发布前在锁内重读的活跃记录"时才发布终态结论，否则只吐上表的 typed 行、
  什么都不发布。**身份的每一次变更（transition / 事件采信 / marker 发布）共用一把稳定的 per-session
  锁**（`$RUN/<s>.identity.lock`，放 run 目录所以跨 clear/重建仍是同一 inode）：token 比对、记录改写、
  marker 落盘同在一个临界区内完成，中间没有让并发 replace 挤进来、再被发布者旧副本盖回去的窗口。
- 所有身份读写只走一个抽象（`identity.py` / `duplexctl identity {token,show,start,replace,resume,publish,receipt,watermark,clear}`）；
  `duplexctl identity show <s>` 读活跃记录，`identity receipt <s>` 读**唯一终态记录**（围栏判定 +
  结构化 reason，exit 0 = delivered / 3 = 未交付）——给下游与人的读 API。
- BLOCKED 归属：footer 让 worker 把 `$RUN/<s>.identity.d/blocked-stamp.txt` 的内容作为 `BLOCKED.md`
  末行。带 stamp 的记录按上表围栏；**未带 stamp 的沿用原有 round-epoch mtime 围栏**（CLI 行为不变）。

- **turn_end ≠ 任务终态**：多步 agent 每个 turn/阶段边界都呈 idle——deliverable gate + watch 的
  2 连稳定读正是为此；多轮 goal 靠 epoch 轮转防上一轮产物开门。
- **纯事件驱动会盲等**：挂 watcher 同时按"任务预期时长 ×2"设 fallback 自检（CC `ScheduleWakeup`；
  shell 编排者 cron/有界轮询）。
- **可用性排序**：watcher 活到终态 > watcher 被外部收割（宿主把后台任务
  死亡也当完成事件推送——仍唤醒编排者，status 复核 + re-arm 零信息丢失）> 自研轮询卡死但活着
  （零通知，沉默与"还在跑"同形 = 编排者失明）。判据不是"会不会失败"，而是**失败时响不响**——会被
  收割的 watcher 比会卡死的轮询器可靠；自研通知通道投产前先拿已知阳性证明它会响。
- **终态记录 = 交付回执（唯一一份，不存在第二份权威）**：算出终态的观察者落
  `$RUN/<s>.terminal.json`——同一个文件既是 WS1 围栏 stamp 又是 WS2 delivery receipt，字段：
  `schemaVersion / completedAt(RFC3339) / rc / class / round / detail / deliverable / reason /
  sessionId / attemptId / processIncarnation / identity{…,seq}`；交付成立时再加
  `phase:"delivered" / engineOutcome:"completed" / deliverables[{path,sha256,size}] / gitHead`
  （合法 JSON）——纯文件系统等待与事后恢复真相都不依赖"当时有人在听"，通知进程全被
  收割也不丢。生命周期 = 存在即"本轮已完成"：`start` / `steer`（新轮）/ `stop` 都清除（连同发布中断
  残留的 `.<s>.terminal.json-*.tmp`）。**steer 的清除发生在 duplexctl 的 round 提交点**——writer flock
  内、reader 确认之后、round 计数器推进的同一刻，不在 shell 里预清：被拒的 steer（引擎已退出 / 输入流
  被污染 / 评审预算封顶）根本没开新轮，就不许销毁任何已挂载等待者尚未读到的结论（评审 R2 F-02：预清
  曾让失败的 steer 抹掉同伴的唯一结论，慢等待者回 12、快等待者回 2）。status 单读只在已声明
  deliverable（门背书）时落盘，未声明的由 watch 双稳读落。
- **八个 watch 终态类逐一落盘**（supervised 感知环发布，原子 temp+rename，唯一 canonical reader =
  `duplexctl watch-state`）：`0 DONE / 2 FAILED|AGENT-DEAD / 4 WAITING-INPUT / 5 STALLED-EXTERNAL /
  6 IDLE-NO-DELIVERABLE / 7 WATCH-TIMEOUT / 8 ENGINE-SILENT / 11 STALLED-STREAM`。
  **`10 RUNNING` 明确非终态、永不落记录**。`class` 是 exit code 的纯函数（**不从散文里解析**），
  两者对不上即判定不可信；`round` 是轮次围栏：发布时轮次已经翻页 → 拒绝写（typed `STALE-ROUND`），
  读取时轮次不匹配 → 拒绝采信。absent / torn / corrupt / 非常规文件（symlink、fifo）/ 不可读 /
  陈旧（跨 attempt·跨 incarnation·跨 round）**一律不作业务结论**，走状态机 ②/④。
  **消费/交付语义**：`0 DONE` 是本轮持久事实，报出后仍留盘（既有合同：纯文件等待者与事后回执都靠它）；
  其余七类是**本次观测回合**的结论——被等待者报出后轮转为 `<s>.terminal.consumed.json`（**交付而非销毁**，
  取证留全），于是下一次 `agentctl watch` 是"接着看"、不是无限重放上一回合的 WATCH-TIMEOUT。轮转
  **不改变已挂载等待者读到的结论**：canonical reader 收 `--armed-seq`（等待者挂载时看到的**发布序号
  水位**，取自 `duplexctl identity watermark`），凡 `identity.seq > 本等待者水位` 的记录，即使已被同伴
  取走也照样是本等待者的答案——两个挂在同一守护环上的等待者对同一终态**必收敛到同一 typed 结论，
  八类皆然**（评审 F-02：曾出现快等待者 `FAILED 2`、慢等待者 `SUPERVISOR-LOST 12`）。**先后由持久化
  序号定，不由时间戳定**：早先用"记录 mtime ≥ 等待者挂载时刻"，两端都是可跳的墙钟，时钟回拨后一个
  刚挂载的等待者会被当成已挂载同伴、把已消费的业务结论**重放**给它（评审 R2 F-03——这比 12 降级更
  严重）。**水位按 attempt 定界**：`publishSeq` 每次 `start` / `replace` 归零（`resume` 同 attempt 继承），
  而上一个 attempt 的 live / consumed 记录会留在盘上（失败的 `steer --replace` 就是这形状——替换身份先
  提交、帧后发失败，轮次没翻、旧记录全在）。取全盘最大值会让退役 attempt 的 `seq=1` 把新等待者的水位
  抬到 1，新 attempt 的**第一个**结论也是 `seq=1`，于是同伴报 `FAILED 2`、这个等待者判"我挂载前就结束了"
  掉进 `SUPERVISOR-LOST 12`——同一终态又裂成 2/12（评审 R3 F-01）。因此只有**当前 attempt** 戳记的记录
  进水位、参与已挂载比较；身份围栏切断跨 attempt 的一切采信面，排序水位不是例外。
  没被报出（等待者中途被杀）的记录原地不动，下一个等待者照常恢复它——丢的
  方向永远是"多重放一次"，不是"少一个结论"。
  **轮次围栏两端一致，且两端都是必填**：daemon / status / `--inline` 三个发布者一律把"classify 之前
  捕获的轮次"传给写者，公共 CLI `duplexctl identity publish` 的 `--round` **必填**（省略即 typed 拒绝、
  不落盘、无回执）——可选的围栏等于没有围栏，省略时写者会拿"publish 那一刻的 meta 轮次"盖戳，把上一轮
  结论变成本轮 DONE（评审 R2 F-01）。读端对称：`class` 与 `round` 是 canonical reader 的**必需 schema
  字段**，缺任一即坏记录、走状态机 ④，**不再有"没有 class 且 rc=0 就当 legacy DONE"和"没有 round 就跳过
  轮次围栏"这两条兼容路**。round-less legacy meta 的 0 归一只发生在**写端**（写者读 meta 时的事实），
  永不发生在读端补缺——读端补缺等于替别人的记录猜围栏。
  **进程生命围栏在 pid 信号取不到时也成立**：活跃记录每次 transition 都铸一枚 `incarnationEpoch`
  并随记录发布，`resume` 前后两个"取不到 pane pid"的生命因此**不相等**——不可判即 fail closed，
  旧生命的 DONE 一律走 ④（评审 F-03）。
- **`phase=delivered` ≠ 已验证**：它只表示"运行时终态 + 已声明产物的证据被观察并算过哈希"，
  **不表示** reviewed / verified / E2E 通过 / merged / deployed。回执自己不是验收，任何"已验证"结论
  必须另有独立来源。
- **结构化 reason（闭集，不是散文）**：每个未交付 / 被拒结论都在记录里和 status/watch 机器行上带
  `reason=<enum>`：`OK` / `NO_DELIVERABLE_DECLARED` / `MISSING` / `UNREADABLE` / `SYMLINK` /
  `DIRECTORY` / `GLOB` / `OVERSIZED_HASH_SKIPPED` / `IDENTITY_UNKNOWN` / `PUBLISH_INTERRUPTED`
  （身份围栏拒收时 reason = WS1 的 `STALE-ATTEMPT` / `STALE-INCARNATION`）。加一种结论 = 在
  `identity.py` 这一处扩枚举，永不新增散文串；调用方与测试只断言枚举。
- **有界取证规则**（每条都 typed，绝不静默）：声明路径缺失 = `MISSING`；存在但读不了（EACCES /
  fifo / 设备）= `UNREADABLE`；末段或**任一祖先**是符号链接 = `SYMLINK`——判定方式是 **openat 式
  逐段下降**（每跳 `O_NOFOLLOW` 且相对上一段的 fd），所以①绝对路径声明没有豁免（否则被链接的
  祖先被跟随、外源字节被哈希成交付）②没有 islink 预检就没有
  check-then-open TOCTOU；③祖先按 **SEARCH 打开**（`O_SEARCH` / Linux `O_PATH`，回落 `O_RDONLY`），
  绝不额外要求目录可读——路径解析本来只要 x，用 `O_RDONLY` 会把 mode 0111 祖先下完全可读的产物
  误判成 `UNREADABLE`。anchor（谁都不许经链接到达的真实起点）：**相对声明**用
  realpath(会话 cwd)——cwd 是操作者指定的信任根，且 `agentctl start` 记的本来就是 `pwd -P` 解析过
  的形态；**绝对声明**只在命中**固定的顶层平台别名白名单**（`/var` `/tmp` `/etc`——darwin 自己做成
  `/private/*` 的那几个，且运行时仍验证它当前是链接）时豁免那一段，否则从文件系统根开始，其余
  每一段都走。绝对声明**没有"落在 cwd 内"的捷径**（否则 `alias -> real` + cwd 在 alias 之下时，
  逐段检查从 `alias` 之下才开始、链接背后的字节被哈希）；**用户自建的链接在任何深度都不豁免**。
  绝对路径按写出来的样子判——回执声称哪条
  路径就检查哪条路径。目录 = `DIRECTORY`；路径含 glob 元字符
  （`*?[`）= `GLOB`（回执要显式常规文件路径，该会话仍走原 mtime 门）；常规文件 > 64 MiB = **仍交付**，
  `sha256:"oversized"` + 真实 `size` + `reason=OVERSIZED_HASH_SKIPPED`（有界成本、诚实标注，唯一
  一条"仍交付"的有界例外）；未声明 deliverable = 落终态记录但**无 `phase`**、
  `reason=NO_DELIVERABLE_DECLARED`（绝不空口交付）；非 git 目录 = 交付且 `gitHead:null`（绝不编造）。
  相对路径按**会话 cwd** 解析，`gitHead` 读的是该 cwd 所属仓库的 worktree HEAD，不是编排者的。
- **读边界先校验 receipt schema，再谈交付**（`identity.receipt_status()`）——**每一个能得出终态
  真相的读者都走这同一道门**，不存在分支专用捷径：`phase` 缺失 = legacy WS1 marker（按 marker
  采信、永不算交付）；声称交付但违反任一条 = 拒收、`reason=IDENTITY_UNKNOWN`、绝不 DONE-by-receipt
  （分支专用捷径会让两个读者对同一条记录一说拒收一说 DONE）。校验：`schemaVersion==1`、
  `rc` 严格 int 0、`engineOutcome=="completed"`、
  `reason` ∈ 可交付集、顶层 `sessionId/attemptId/processIncarnation` 与被围栏的 `identity` stamp
  逐字段相等、`completedAt` 用**完整解析**（形状允许小写 `t`/`z` 与闰秒 `:60`、必须带偏移；
  再由 `datetime.fromisoformat` 拒掉 `+24:00` / `+23:60` / 13 月 / 32 日 / 25 点这类不可能值——
  只匹形状再 strptime 前 19 字符等于根本没校验偏移；`:60` 还必须落在 **UTC 一天的最后一分钟**，
  否则不存在的瞬时也会过）、`gitHead` 为
  null 或 git object id（sha1 40 hex 或 sha256 64 hex——只认 40 会让 `--object-format=sha256`
  仓库里**发布者自己写的回执被自家读边界拒收**）、`deliverables` 非空
  且**所有证据值整串匹配**（`\Z` + `fullmatch`，绝不用 `$`——Python 的 `$` 匹在末尾换行之前，
  于是 hex 摘要 + `\n` 会被放行）；
  `deliverables` 每项 `path` 非空、`size` 非负 int、`sha256` 为 64-hex 或恰好 `oversized` 哨兵（哨兵只在
  `reason=OVERSIZED_HASH_SKIPPED` 且 size 超界时合法；真摘要只在 `reason=OK` 且 size 不超界时合法），
  且 entry 的 path 必须等于同一个解析器（`declared_target()`）的结果。**只**校验绑定 schema 声明的
  字段：单数 `deliverable` 是 WS1 marker 的扩展、不在绑定字段表里，要求它会拒掉合规记录。
  **没有这道门时**：只要嵌套 stamp 与活跃 attempt 一致，伪造 body
  就能在 5 字节文件上声称 oversized + 编造 gitHead + 任意 completedAt，把真实 deliverable 谓词刚
  拒掉的门变成 DONE 0。这道门证明的是内部一致 + 声称的就是本会话
  声明的产物；它证明不了"已知当前 attempt+incarnation 的自洽伪造"是真的——那是 WS1 围栏的信任边界。
- **会话 lane 消失 = 拒收，不是发布成功**：meta 不在（stop 竞态 / 被清）时发布返回 WS1 的
  `IDENTITY-UNKNOWN` 类、`reason=IDENTITY_UNKNOWN`、不落任何记录，`duplexctl` 退 2、status/watch
  双双拒收（发布者退 0 会让旧的 DONE 活着被当成本会话结果）。stop 竞态能解释 meta 为什么不见，
  但不能让 stop 之前的结论变成现在的结论。
- **回执有效性绑定 attempt + incarnation**：陈旧判定永远落在**记录**上，不落在文件字节上（磁盘上的
  产物自己不带来源）。陈旧 / 异源 stamp 的记录一律拒收（`STALE-*` / `IDENTITY_UNKNOWN`），
  身份有效的记录则如实哈希当下字节。**有回执时哈希证据取代 mtime 新鲜度启发**（legacy 无回执 marker
  仍走 mtime 门，行为不变）。发布仍是 mkstemp+fsync+`os.replace` 且在同一把身份锁内：中断只会留下
  前一份完整记录或没有记录，永不留半截 JSON；只留 temp 残骸时读侧报 `reason=PUBLISH_INTERRUPTED`。
  exit 码契约不变——回执只决定"能不能声称交付"，不改变既有出口分类。
- **pane 已亡（无 rc）时终态记录可被采信一次**：死进程发不出新事件，stamp 与活跃记录精确一致即
  "本轮在 pane 被收割前就已完成"（此前一律 AGENT-DEAD）。采信前先过 marker schema 门
  （`rc` 严格 int——`False == 0` 不算 0；stamp 的 attemptId / incarnation 非空串、`seq` 必须是 int），
  再按 **per-attempt 单调 high-watermark** 判同一性：只有 `seq > watermark` 才推进状态，
  `seq <= watermark` 在该 attempt 的整个生命周期里都是 no-op（不用有界环——会遗忘旧键从而允许重放）。
  stamp 不一致 / 不可判定（含 schema 不合格）→ 上表 typed 行，绝不采信、绝不动记录。
- **Agent 工具异步 subagent 的完成通知有黑洞**：只在"停止且自身无存活后台子进程"时才发；子 agent 自起
  后台 fork（E2E/monitor）→ 父 idle 而通知永不来。
  对策：别只信完成通知（fallback 自检兜底）；派工要求验证同回合做完、不留孤儿 fork、里程碑 SendMessage 回 main。

## 判完成要正向证据、不凭 idle / watcher 裁决

watcher 裁决是线索不是判决：DONE 收货前自己核**正向交付物**（本地 commit / 产物计数达标 / 显式
review 标记）。agent 自起后台 job 会 yield＝呈 idle 但没完成（bg 跑完自动续）——判 DONE 认
"正向交付物 + idle 稳定"，`沉默 ≠ 交付` 同族。

## 引擎级注意

- **引擎额度是编排级单点**：omp/codex 默认走 OpenAI 后端——执行席 + 异构评审席可能共享同一 quota
  池，耗尽两线同瘫。
  start 回显 engine 行；高强度批跑前确认各后端余额；应急 = 执行席换 Claude（评审同 lineage 失异构
  价值，标注即可）。
- **omp `--model` fuzzy match 会开交互 picker** 吃掉派发（会话卡在选择器）——引擎 args 只传 EXACT id
  （`--model=anthropic/claude-opus-4-8`）。
- **裸 send-keys 坑**（仅剩人工 attach 场景相关，guard ④ 拦）：长中文/全角触发 omp 模糊搜索弹窗
  吃 Enter 且关不掉；bracketed-paste 吞尾部 Enter；>2000 字符 paste 损坏。协议帧车道天然免疫。
- omp rpc 面无版本稳定性文档：launch 的 ready 握手即 preflight，握手失败 = fail-fast 清场重来，
  不带病跑。
- **claude queued steer 的 turn 归属无引擎关联面**（诚实边界）：turn A 运行中排队 steer B，
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
  （消费即授权、用后即焚）；mixed 命令不 auto-allow、落回分类器。⑧ 伞形多仓工作区拦无锚 `git`/`gh`（cwd 漂移打错仓；
  判据与正路见 [§cwd 锚定](#cwd-锚定多仓工作区)，单仓项目永不触发）。①用剥引号视图，④用原始 cmd，⑤⑥⑧只认命令位（路径当参数
  不拦）。git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
- **`cto-guard-agent.py`（Pre·Agent|Task|TaskStop|KillShell + Post·Agent|Task）** — Pre·Agent：
  browser/E2E 派发含 `mcp__chrome-devtools` → DENY（逼 Playwright，P0a）；派发未显式钉 `model` 档 →
  DENY（P0c）；e2e-runner 派发 model 非便宜档 → DENY（P0d）；Pre·TaskStop|KillShell：目标 `.output`
  120s 内还在长 = 活的 → DENY（**完成通知黑洞**与"零截图≠卡死"实证；override =
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

## Validation status（当前态快照；过程史在 git log）

| 面 | 状态 | 方式 |
|---|---|---|
| duplex 产帧 / 投影 / 路由 / 死亡路径 | ✅ hermetic | `test/agentctl-duplex.test.sh`：进程级 fake tmux + scriptable fake 引擎驱动真 fifo/flock/events 管线 |
| duplex live | ✅ 生产实测 | 三引擎真跑全链；`test/e2e/agentctl-duplex.e2e.sh` 为 pre-release 门（start→watch→steer→watch→stop + 零残留） |
| deliverable 门（exit 6 / freshness / 相对 glob） | ✅ | hermetic 对抗测试，两车道 |
| guard ①-⑧ / P0a-P0d | ✅ | hermetic + `hook-deny-pointer` 自指门（DENY 指针目标真实性）；生产 fire 实证限 ③ 与 ⑧，其余面为 hermetic 覆盖 |
| BLOCKED.md 协议真 fire | ◯ 未 live 验 | footer 结构化自带；hermetic 有测例，live 实证仍缺 |

## cwd 锚定（多仓工作区）

Shell cwd 跨工具调用漂移：上一条命令的 cd 残留、被拦命令的 cd 根本没执行、并行调用留下
最后一条的 cwd。单仓项目无感；伞形多仓工作区里 = git/gh 打错仓。
纪律：**每段含 git/gh 的命令自带锚**——行首
`cd /abs/<repo> && …`，或每次调用自锚 `git -C <path>` / `gh -R <owner>/<repo>` / `gh api`。
guard (8) 检测到伞形根（cwd 或近祖先目录含 ≥2 个子 .git）时硬拦无锚 git/gh；
单仓环境该规则永不触发。
