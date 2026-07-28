# agentctl — headless worker 控制面（一条 duplex lane、三引擎）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**，
一条 duplex lane、三引擎各跑原生 stdio 协议长驻（omp `--mode=rpc` / claude stream-json /
codex app-server），能力差异不分叉车道、由接口干净拒绝。tmux 只做进程保活（worker 独立于
编排者进程树）；终态真相只来自 typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 目录：[agentctl 命令面](#agentctl--当前命令面2026-07-19-起) · [Why](#why为什么是协议不是屏幕) ·
> [duplex 机制](#duplex-车道机制) · [Launch](#launch) ·
> [typed 状态](#typed-状态编排者纪律) · [判完成要正向证据](#判完成要正向证据不凭-idle--watcher-裁决) ·
> [引擎级注意](#引擎级注意) · [强制层 guard](#强制层两个单一职责-guard-脚本) · [Validation](#validation-status当前态快照过程史在-git-log)

## agentctl —— 当前命令面（2026-07-19 起）

```text
agentctl start  <omp|codex|claude> <session> <cwd> --goal F [--deliverable G] [--no-preflight] [engine args…]
agentctl steer  <session> (-m TEXT | -f FILE) [--now | --replace] [-d G]
agentctl status <session>      # one-shot typed verdict（exit code = 结论）
agentctl watch  <session>      # 阻塞至终态；run_in_background 挂起
agentctl stop   <session>      # 结束 + 按进程组收割整棵树 + 清控制态（events/rc/stderr 留作尸检）
```

- **steer 语义**（能力差异拒绝制，不分叉车道）：默认排队 / `--now` / `--replace` × 三引擎的语义
  矩阵（含原生动词）见 SKILL.md §0 表；runtime 对不支持组合当场拒绝并指正路（claude `--replace`
  拒绝 → `stop` + `--resume <sid>` 重启）。投递成功 ≠ 模型照做，验收仍看交付物。
- **typed exit 三引擎同词汇**（全表见 [typed 状态](#typed-状态编排者纪律)）；
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **deliverable gate**：相对 glob 一律按**会话 cwd** 解析（现场假阴性收编）；freshness
  用 mtime 对 epoch（每次 steer 即轮转）；必带/不带的判据归 SKILL.md §0。
- **尾行机器可读**（1.6.0）：`watch` 四类出口（终态 / 非终态 / ENGINE-SILENT / TIMEOUT）都在 typed
  `=== … ===` 行之后追加最后一行 `EXIT=<n>`——包装层（管道 / 后台 harness）吞掉进程退出码时仍可解析；
  文案与 exit code 均不变。`status` 读到 RUNNING 而**无存活 watcher**（pid 文件缺失、或进程已亡）追加
  一行 `note: no watcher armed — arm: agentctl watch <S>`：只提醒不代挂，typed 行与 exit code 不动。
- **输出有界**：status/watch 只回 typed 一行 + ≤600 字符摘要；引擎 raw 全量只落
  `$RUN/<s>.duplex.events.jsonl`（147KB 单行 transcript 回显曾炸编排者上下文 ~88k tokens，
  2026-07-19 现场——摘要有界是本控制面的硬设计）。
- **后台任务 cwd 语义**（现场误杀教训）：宿主后台机制跑 `agentctl watch` 时，命令继承**发起时刻
  编排者的 cwd**，与 worker 会话 cwd 无关；判断后台任务归属认 `$RUN/<session>.*` 文件名，别认 cwd。
- TUI 车道已裁撤：需要人工现场 = `tmux attach -t <session>` 旁观 / `tmux capture-pane -p`
  手动尸检；worker 控制始终走协议。

## Why：为什么是协议、不是屏幕

抓屏猜状态与 send-keys 注入是上代方案的最大误判源（WAITING 误读 DONE、注入实测仅 ~70-80% 送达）；
三引擎都有官方 headless 双工面——直接消费结构化事件流 + 进程退出与文件，状态**确定可判**。
完整数据与论证见 meta 文《protocol-not-screen》。

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
- **崩溃恢复腿**：引擎死（rc 落盘）→ `agentctl stop` 清态，然后用引擎原生 resume 开新会话：
  omp `… -r <session-file>`（engine args）/ claude `… --resume <sid>`（engine args，cwd 绑定）/
  codex `agentctl start codex s2 <cwd> --goal f --resume-thread <threadId>`（meta `thread=` 里有）。
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
- **watcher 被外部杀（TERM）= 预期可恢复态**：收到 killed 通知即重挂，stateless 零状态损失（生产 ×2
  实证）。归因看 tombstone：trap 在退出前落 `$RUN/<s>.watch.tombstone.jsonl`（ts / signal / ppid /
  uptime——发送方沙箱内不可见，事后只有这一行可查，实证 2026-07-23）。宿主一次事件会成批收割全部
  后台 watcher（外杀 5 例 tombstone 归因实证、含同秒双杀一起，2026-07-25）且 killed 通知本身可能随
  会话一起丢——`status` 对 RUNNING+无 watcher 的会话自动打死亡归因行、并点名 ±120s 邻近窗口内
  一同死亡的其他 watcher（邻近 ≠ 因果实证），照单逐个重挂；重挂或 `stop` 即消费 tombstone
  （转 `.consumed` 留取证），已消解的死亡不复报。
- 引擎二进制可用 env 覆盖（测试缝 + 自定装机位）：`AGENTCTL_BIN_OMP` / `AGENTCTL_BIN_CLAUDE` / `AGENTCTL_BIN_CODEX`。
- exit 6 `IDLE-NO-DELIVERABLE` 用 `agentctl steer` 补一刀，**不要 stop**；`stop` 只用于收工或明确放弃。
- **stop = 进程组收割**（tmux kill 只碰 pane leader，引擎子孙会被 PID 1 收养泄漏——2026-07-28 实证
  43 会话漏 8 worker + 16 孙进程）：pane 起在自有 session+group（pane_pid == pgid），stop 对该组
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

- **turn_end ≠ 任务终态**：多步 agent 每个 turn/阶段边界都呈 idle（实证 2026-07-05 单日 4 次假
  DONE）——deliverable gate + watch 的 2 连稳定读正是为此；多轮 goal 靠 epoch 轮转防上一轮产物开门
  （实证 2026-07-11 三任务全中）。
- **纯事件驱动会盲等**：挂 watcher 同时按"任务预期时长 ×2"设 fallback 自检（CC `ScheduleWakeup`；
  shell 编排者 cron/有界轮询）。
- **可用性排序（实测，2026-07-27 收割夜）**：watcher 活到终态 > watcher 被外部收割（宿主把后台任务
  死亡也当完成事件推送——仍唤醒编排者，status 复核 + re-arm 零信息丢失）> 自研轮询卡死但活着
  （零通知，沉默与"还在跑"同形 = 编排者失明）。判据不是"会不会失败"，而是**失败时响不响**——会被
  收割的 watcher 比会卡死的轮询器可靠；自研通知通道投产前先拿已知阳性证明它会响。
- **终态 marker**：算出 DONE 的观察者落 `$RUN/<s>.terminal.json`（ts / rc / deliverable，
  合法 JSON）——纯文件系统等待与事后恢复真相都不依赖"当时有人在听"，通知进程全被收割也不丢。
  生命周期 = 存在即"本轮已完成"：`start` / `steer`（新轮）/ `stop` 都清除；status 单读只在
  已声明 deliverable（门背书）时落盘，未声明的由 watch 双稳读落。
- **Agent 工具异步 subagent 的完成通知有黑洞**：只在"停止且自身无存活后台子进程"时才发；子 agent 自起
  后台 fork（E2E/monitor）→ 父 idle 而通知永不来（实证 2026-06-26，靠主动 SendMessage 才发现）。
  对策：别只信完成通知（fallback 自检兜底）；派工要求验证同回合做完、不留孤儿 fork、里程碑 SendMessage 回 main。

## 判完成要正向证据、不凭 idle / watcher 裁决

watcher 裁决是线索不是判决：DONE 收货前自己核**正向交付物**（本地 commit / 产物计数达标 / 显式
review 标记）。agent 自起后台 job 会 yield＝呈 idle 但没完成（bg 跑完自动续；实证按 idle 轮询屡误报，
改判"出现本地 commit + idle 稳定"才准）——`沉默 ≠ 交付` 同族。

## 引擎级注意

- **引擎额度是编排级单点**：omp/codex 默认走 OpenAI 后端——执行席 + 异构评审席可能共享同一 quota
  池，耗尽两线同瘫（实证 2026-07-11 一夜 insufficient_quota 全线，编排者还以为 omp 是 Claude）。
  start 回显 engine 行；高强度批跑前确认各后端余额；应急 = 执行席换 Claude（评审同 lineage 失异构
  价值，标注即可）。
- **omp `--model` fuzzy match 会开交互 picker** 吃掉派发（会话卡在选择器）——引擎 args 只传 EXACT id
  （`--model=anthropic/claude-opus-4-8`）。
- **裸 send-keys 坑枚举**（guard ④ DENY 的实证依据，仅剩人工 attach 场景相关）：长中文/①②③/全角触发
  omp skill 模糊搜索弹窗吃 Enter 且 Escape/Ctrl-C 关不掉（实证 2026-07-02，卡 24min）；bracketed-paste
  吞尾部 Enter；>2000 字符 paste 损坏。协议帧车道天然免疫——这正是 duplex 的立道理由之一。
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
`.claude/settings.json` / Codex `.codex/hooks.json` 同格式）。**直接 exec 别加 `python3 `/`bash `
前缀**（脚本自带 shebang）；matcher 别手编（与实现同包维护，曾实证 README 抄本漂移丢 `KillShell`）。

- **`cto-guard-bash.py`（PreToolUse·Bash）** — ① 拦背景 `&`（剥引号 span 后任意单 `&`；`&&`/重定向/
  引号内放行）；② DENY 纯 idle-absence 裸轮询（带 git 交付物 / Verdict 正向 grep 才放行）；③
  `agentctl start` 后同条没 arm watch → 提醒（omission 无法硬 deny）；④ 拦长/CJK 裸 `tmux send-keys`
  （逼 `agentctl steer`）；⑤ 拦前台阻塞 `agentctl watch`（前台 Bash 超时 143 连 watcher 一起杀，实证
  2026-07-11；`AGENT_WATCH_SYNC=1` 显式放行）；⑥ 拦编排者亲跑 live e2e（派便宜模型 runner，命令前缀
  `E2E_ECONOMY=1` 自 declare）；⑦ worktree 生命周期：非 force `git worktree remove`
  常设放行（git 自拒脏树、可逆）；`--force`/`-f`/`prune` DENY（force 碾 untracked、prune 按
  staleness 猜删，均有实证）——正路 = 先 `git -C <wt> status --porcelain` 独立命令抢救核证再请示，
  验证与销毁绝不同一命令行；已批销毁走一次性 override `touch /tmp/cto-allow-worktree-destroy`
  （消费即授权、用后即焚）；mixed 命令不 auto-allow、落回分类器。⑧ 伞形多仓工作区拦无锚 `git`/`gh`（cwd 漂移打错仓；
  判据与正路见 [§cwd 锚定](#cwd-锚定多仓工作区)，单仓项目永不触发）。①用剥引号视图，④用原始 cmd，⑤⑥⑧只认命令位（路径当参数
  不拦——上线当天两次自误伤修出的判据）。git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
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
`hooks:` 自注册**（实测 mid-session 经 Skill 工具激活不注册 → 显式 wiring 才可靠）。

## Validation status（当前态快照；过程史在 git log）

| 面 | 状态 | 方式与要点 |
|---|---|---|
| duplex 产帧 / 投影 / 路由 / 死亡路径 | ✅ hermetic | `test/agentctl-duplex.test.sh`：进程级 fake tmux + scriptable fake 引擎驱动真 fifo/flock/events 管线 |
| duplex live | ✅ 生产实测（2026-07-19~21） | omp + codex：两日重载 11 会话 / 20+ steer 零丢帧 / 并发 2-3 无冲突 / watcher 外杀 2 次 stateless re-arm 零损失；claude：生产首单全链（preflight 门→start→watch DONE→deliverable fresh，1.6.0 runtime 工单自举交付）。`test/e2e/agentctl-duplex.e2e.sh` 仍为 pre-release 门（start→watch→steer→watch→stop + 零残留） |
| deliverable 门（exit 6 / freshness / 相对 glob） | ✅ | hermetic 对抗测试，两车道 |
| guard ①-⑧ / P0a-P0d | ✅ | hermetic + `hook-deny-pointer` 自指门（DENY 指针目标真实性）；③ 与 status no-watcher 提示均有生产 fire 实证；⑧ 上线当日即生产 fire（含正路 `git -C` 放行）+ hermetic 对抗电池（payload 钉 cwd、伞形/单仓双景） |
| BLOCKED.md 协议真 fire | ◯ 未 live 验 | footer 结构化自带；hermetic 有测例，live 实证仍缺 |

## cwd 锚定（多仓工作区）

Shell cwd 跨工具调用漂移：上一条命令的 cd 残留、被拦命令的 cd 根本没执行、并行调用留下
最后一条的 cwd。单仓项目无感；伞形多仓工作区里 = git/gh 打错仓（实证：2026-07-24 一轮
三咬；2026-07-26 PR 开进错误仓库）。纪律：**每段含 git/gh 的命令自带锚**——行首
`cd /abs/<repo> && …`，或每次调用自锚 `git -C <path>` / `gh -R <owner>/<repo>` / `gh api`。
guard (8) 检测到伞形根（cwd 或近祖先目录含 ≥2 个子 .git）时硬拦无锚 git/gh；
单仓环境该规则永不触发。
