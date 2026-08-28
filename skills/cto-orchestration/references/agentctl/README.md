# agentctl — headless worker 控制面（一条 duplex lane、三引擎）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**，
一条 duplex lane、三引擎各跑原生 stdio 协议长驻（omp `--mode=rpc` / claude stream-json /
codex app-server），能力差异不分叉车道、由接口干净拒绝。tmux 只做进程保活（worker 独立于
编排者进程树）；终态真相只来自 typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 本文只写 CLI 讲不了的：语义、失败形态、判断。凡是能从 `agentctl` / `agentctl capabilities` /
> `agentctl states` 问出来的事实，这里一律不留副本——副本只会漂。

## agentctl —— 当前命令面

命令面由 CLI 自述，此处不留副本（复述必漂）：裸跑 `agentctl` 出 usage、`agentctl capabilities` 出三引擎能力契约、`agentctl states` 出 typed 状态词表。
下面只写 CLI 讲不了的部分——语义、失败形态、判断。

- **steer 语义**（能力差异拒绝制，不分叉车道）：三引擎能力矩阵由 runtime 生成，`agentctl capabilities`
  是唯一真源（同一张表既驱动路由、又出拒绝文案）。投递成功 ≠ 模型照做，验收仍看交付物。
- **typed exit 三引擎同词汇**（词表 `agentctl states`，处置见下节）；
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **deliverable gate**：相对 glob 一律按**会话 cwd** 解析；freshness
  用 mtime 对 epoch（每次 steer 即轮转）；必带/不带的判据归 SKILL.md §0。
  **`steer -d` 只移动 watcher 的 freshness 目标，不重发 footer**——worker 不会自动得知新目标，
  你的 steer 文本必须自己点名交付文件（runtime 在 `-d` 成功时会当场提醒这一条）。
- **尾行机器可读**：`watch` 四类出口（终态 / 非终态 / ENGINE-SILENT / TIMEOUT）都在 typed
  `=== … ===` 行之后追加最后一行 `EXIT=<n>`——包装层（管道 / 后台 harness）吞掉进程退出码时仍可解析；
  文案与 exit code 均不变。`status` 读到 RUNNING 而**无存活 watcher**（pid 文件缺失、或进程已亡）追加
  一行 `note: no watcher armed — arm: agentctl watch <S>`：只提醒不代挂，typed 行与 exit code 不动。
  **watch 不可用自造轮询顶替**：只认 DONE 的轮询会把 `RUNNING: idle but messages queued` 停成
  无人收割（下游席位 2h 实证）——typed 终态 / deliverable freshness / round 围栏全靠 sensing
  supervisor。`--deliverable` 声明与 brief 点名的输出文件必须同名，否则 exit 6（见 misplaced hint）。
- **supervised watch（默认）**：感知环跑在独立 tmux 会话 `<session>-watchd`，宿主侧 `agentctl watch`
  只是**哑等待者**——只读围栏过的终态记录，自己不 classify。**被外部 TERM 后原地重挂即恢复同一
  class + exit**，连本轮结论都不丢。生命周期绑 attempt：`start` / `stop` / `steer --replace` 回收
  守护环，普通 `steer` 保留。**降级只在守护结构性不可能时发生且响亮告警**（无 tmux / run 目录不可写 /
  自起的 pane 没发租约）——宁可失去抗杀性也不能拒绝观测，stderr 明说 "NOT kill-resilient"。
  **同名 `<s>-watchd` 在但没有本 identity 的租约 = 不可判，不是降级理由**：返回 `12 reason=unknown`
  并点名清理指引（`tmux kill-session -t <s>-watchd` 后重挂），绝不静默 inline。`--inline` 是显式
  兼容旗标（进程内轮询，被杀即丢本轮结论）。
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
  别拿 watch 反复重挂硬扛——宿主事件会成批收割后台 waiter（见下 tombstone 节），长等待期内
  每次收割都触发一次重挂，全是空转轮（下游席位 40min 列车 5 次重挂实证）；改用宿主长间隔
  wakeup / 定时器对齐外部作业的真实时长，到点再回 `status` 一发判态。
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

- goal 投递 = `prompt` 帧（正文 = goal 文件 + HEADLESS 协议 footer：立即开工**除非合同承诺了开工前
  核对**、阻塞**或合同门要求停下等裁决**时写 `<cwd>/BLOCKED.md` 停下——fresh BLOCKED.md 映射
  exit 4，三引擎同协议）。
- **崩溃恢复腿**：照 `agentctl capabilities` 的 `resume` 行走——degraded 两家（`stop` 后重开会话、
  engine args 由 start 原样转发）正路在各自 note 里；codex 唯一 supported，握手内续 thread：
  `agentctl start codex <s> <cwd> --goal <f> --resume-thread <threadId>`（supported 不带 note，故写这）。
- **评审档 `--review`**（codex 专属；非 codex、或与 `--resume-thread` 并存，参数面即拒——thread/resume 只带
  threadId 不重发 tier，放行即上报一个引擎从未钉过的席位）。沙箱两档统一 `danger-full-access`
  （workspace-write 网络封锁致评审席无法独立复算，n=3 假阻塞；写边界零战果）。
  **交付物仍必须在 session cwd 内**——车道纪律非沙箱事实：写进无关树的评审产物会在 worktree
  清理后变孤儿，且 exit-6 近失扫描只走 cwd。绝对与相对 glob 一律判：含 `..` 分量即拒，最深已存在祖先目录物理解析后不在
  cwd 内即拒（含 symlink 外逃），无已存在祖先按歧义拒，basename 为空 = 目录非交付物、拒；
  判定归 `duplexctl check-params`，`start` 与 `steer -d` 同门。另：进 meta 的参数面值一律拒含换行（否则注入 meta key，可无声改档），写点 `meta_update` 兜底引擎回传值。
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
  verdict 行后可能跟 `possible misplaced deliverable: "<abs path>"`（有界扫 cwd 找同名错位产物，
  json 编码防伪造 typed 行；只提示、不改 rc，无命中/扫描退化都零输出）——先看这行再决定 steer 措辞。
- **stop = 进程组收割**（tmux kill 只碰 pane leader，引擎子孙会被 PID 1 收养泄漏）：
  pane 起在自有 session+group（pane_pid == pgid），stop 对该组
  TERM → 有界宽限（`AGENTCTL_REAP_GRACE`，默认 5s）→ KILL → pgrep 复核零残留；陈旧 meta 走
  leader lstart 指纹防 pid 复用误杀，永不按名字/全局杀。终态后**立即 stop 是编排者纪律**，
  retro-check 第 6 检对"本仓终态未清会话"blocking FAIL 兜底。

## typed 状态：处置（词表由 `agentctl states` 自述）

exit code、名字与语义是运行时事实 → `agentctl states`（`--json` 机器读），此处不留第二份。
**本节只写 verb 故意不发布的那一列：处置**——它是判断，不是事实。

| 状态 | 编排者要做什么 |
|---|---|
| DONE | 收货前仍做正向核证（下节），别只认 typed 行 |
| FAILED / AGENT-DEAD | 读 events/stderr 尾（有界），走恢复腿 |
| WAITING-INPUT | 读题，`agentctl steer` 作答 |
| STALLED-EXTERNAL | 修凭据/额度再重启；见引擎级注意 |
| IDLE-NO-DELIVERABLE | poke（steer），别信幻影 DONE、别 stop |
| WATCH-TIMEOUT | 重挂或人工核证，**绝不按 DONE 消费** |
| ENGINE-SILENT | 查 stderr.log；必要时 stop+resume |
| BUDGET-EXHAUSTED | 转人工裁决 |
| RUNNING | 继续等 |
| STALLED-STREAM | **先从 checkout/commits 抢救成果，再 stop**；探针任一不确定按 RUNNING 处理（宁钝勿敏）。窗口用 `AGENT_WATCH_STALL_MINS` 调、0 关 |
| SUPERVISOR-LOST | `reason=dead` → 直接重挂。`reason=unknown` → **先读 detail**：只有它点名 rogue/wedged `<s>-watchd` 时才 `tmux kill-session -t <s>-watchd` 再重挂；其余 unknown（canonical 读超时 / `ps` 不可用 / 租约损坏 / pid 复用嫌疑）**只重挂，绝不杀**——那些情况下杀掉的是一个活着的守护环 |

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
身份三元组 `session_id` / `attempt_id` / `process_incarnation`（pid@start-time）与其提交点、
陈旧记录的拒收规则、回执哈希取代 mtime 的条件——判据在代码注释与 `identity.py`，设计经过在 git log。

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
  （消费即授权、用后即焚）；mixed 命令不 auto-allow、落回分类器。**benign 快路**：整条命令是单一
  `git [-C <path>] worktree prune` 且 porcelain 证明所有 prunable 目录都已消失 → 放行（纯元数据、
  零文件伤害），任何链式/env 前缀/多 `-C`/解析歧义/`lexists` 命中都落回 DENY。⑧ 伞形多仓工作区拦无锚 `git`/`gh`（cwd 漂移打错仓；
  判据与正路见 [§cwd 锚定](#cwd-锚定多仓工作区)，单仓项目永不触发）；⑨ 浏览器归属：`playwright-cli attach`
  带接管旗标（CDP / 浏览器扩展）→ DENY，正路 = `open` 起隔离浏览器（与 agent 侧 P0a 同一条规则的两个通道，
  见 [frontend-verify](../frontend-verify.md)）；⑩ 拦裸 `codex exec` / `codex e` / `codex review`（手搓 headless codex 无 typed 状态、同命令 heredoc 必等 stdin EOF 挂死；正路 = lane 评审档 `--review`；`exec-server` / `--version` / `login` / `agentctl start codex` 不拦）。
  ①用剥引号视图，④用原始 cmd，⑤⑥⑧⑩只认命令位（路径当参数
  不拦）；⑨判归一化后的 shell 执行面（与⑧同一套：剥引号 span + 去反斜杠，故转义写法照拦；
  代价是字面量进 shell 命令即拒，已接受的假阳性）。git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
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


## cwd 锚定（多仓工作区）

Shell cwd 跨工具调用漂移：上一条命令的 cd 残留、被拦命令的 cd 根本没执行、并行调用留下
最后一条的 cwd。单仓项目无感；伞形多仓工作区里 = git/gh 打错仓。
纪律：**每段含 git/gh 的命令自带锚**——行首
`cd /abs/<repo> && …`，或每次调用自锚 `git -C <path>` / `gh -R <owner>/<repo>` / `gh api`。
guard (8) 检测到伞形根（cwd 或近祖先目录含 ≥2 个子 .git）时硬拦无锚 git/gh；
单仓环境该规则永不触发。
