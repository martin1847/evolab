# agentctl — headless worker 控制面（duplex / round 双车道）

Detect and steer coding agents without ever reading a terminal pane. **Surface = `agentctl`**：
omp/claude 走 **duplex** 车道（引擎原生 stdio 协议长驻，轮内协议帧 steer）；codex 走 **round**
车道（exec-resume 逐轮）。tmux 只做进程保活（worker 独立于编排者进程树）；终态真相只来自
typed exit code——协议帧、rc 文件与交付物，**永不抓屏**。

> 目录：[agentctl 命令面](#agentctl--当前命令面2026-07-19-起) · [Why](#why为什么是协议不是屏幕) ·
> [duplex 机制](#duplex-车道机制) · [round 车道](#round-车道codex--恢复腿) · [Launch](#launch) ·
> [typed 状态](#typed-状态编排者纪律) · [判完成要正向证据](#判完成要正向证据不凭-idle--watcher-裁决) ·
> [引擎级注意](#引擎级注意) · [强制层 guard](#强制层两个单一职责-guard-脚本) · [Validation](#validation-status当前态快照过程史在-git-log)

## agentctl —— 当前命令面（2026-07-19 起）

```text
agentctl start  <omp|codex|claude> <session> <cwd> --goal F [--deliverable G] [--require-preflight] [engine args…]
agentctl steer  <session> (-m TEXT | -f FILE) [--now | --replace] [-d G]
agentctl status <session>      # one-shot typed verdict（exit code = 结论）
agentctl watch  <session>      # 阻塞至终态；run_in_background 挂起
agentctl stop   <session>      # 结束 + 清控制态（events/rc/stderr 留作尸检）
```

- **steer 语义**：默认排队（omp `follow_up` / claude 原生排队到下一 turn 边界）；`--now` 即时
  （omp `steer`；claude 无公开中断帧→降级排队并明说）；`--replace` 弃当前重来（omp
  `abort_and_prompt`；claude/codex 走 stop+restart）。投递成功 ≠ 模型照做，验收仍看交付物。
- **typed exit 两车道同词汇**（全表见 [typed 状态](#typed-状态编排者纪律)）；duplex 专义：
  **8 = ENGINE-SILENT**（steer 已投递、引擎 ~2min 零输出——诚实报，不猜）。
- **deliverable gate**：相对 glob 一律按**会话 cwd** 解析（2026-07-19 现场假阴性收编）；freshness
  用 mtime 对 epoch（每次 steer 即轮转）。文件产出必带 `--deliverable`；非文件结果不带。
- **输出有界**：status/watch 只回 typed 一行 + ≤600 字符摘要；引擎 raw 全量只落
  `$RUN/<s>.duplex.events.jsonl`（round 车道 verdict tail 同步收紧 800 字节——147KB 单行 transcript
  回显曾炸编排者上下文 ~88k tokens，2026-07-19 现场）。
- **后台任务 cwd 语义**（现场误杀教训）：宿主后台机制跑 `agentctl watch` 时，命令继承**发起时刻
  编排者的 cwd**，与 worker 会话 cwd 无关；判断后台任务归属认 `$RUN/<session>.*` 文件名，别认 cwd。
- TUI 车道已裁撤（本大版本）：需要人工现场 = `tmux attach -t <session>` 旁观 / `tmux capture-pane -p`
  手动尸检；worker 控制始终走协议。

## Why：为什么是协议、不是屏幕

抓屏猜状态是上代方案的最大误判源（WAITING 误读 DONE、glyph/布局随 CLI 版本漂移；claude ≥2.1.205 /
omp 16.4.4 / codex 0.144.1 三连静默弄坏 TUI 链路），send-keys 注入实测仅 ~70-80% 送达（弹窗吃
Enter、bracketed-paste 丢尾、长文本损坏）。三引擎如今都有官方 headless 双工/逐轮面——duplex 直接
消费引擎自己的结构化事件流，round 消费进程退出 + 输出文件；两者的状态都**确定可判**，这正是
2026-07-12「headless 默认」裁决的完成态：连 escape 车道也不再养屏幕税。

## duplex 车道机制

```text
tmux pane 内：  exec 3<>$RUN/<s>.duplex.in            # fifo 读写打开：引擎 stdin 永不 EOF
               <engine-cmd> <&3 >> events.jsonl 2>> stderr.log
               echo $? > rc                            # 引擎退出（异常）才落 rc
engine-cmd：   omp --mode=rpc …                        # JSON-line RPC（steer/follow_up/get_state）
               claude -p --input-format stream-json --output-format stream-json \
                      --verbose --permission-mode bypassPermissions …
steer/status： duplexctl.py 产协议帧 → flock 单写者写 fifo；投影读 events.jsonl 尾窗
               （omp 状态 = 活体 get_state 往返；claude = result 帧 + sent-offset 防假 DONE）
```

- goal 投递 = `prompt` 帧（正文 = goal 文件 + HEADLESS 协议 footer：立即开工、真阻塞写
  `<cwd>/BLOCKED.md` 停下——fresh BLOCKED.md 映射 exit 4，两车道同协议）。
- **崩溃恢复腿**：引擎死（rc 落盘）→ `agentctl stop` 清态，然后用引擎原生 resume 参数开新会话：
  `agentctl start omp s2 <cwd> --goal followup.md -r <session-file>`（omp）/
  `… claude … --resume <sid>`（claude，cwd 绑定）。上下文由引擎会话文件保住。
- 单写者纪律：所有 fifo 写经 `duplexctl.py`（flock）；并发 steer 由锁串行。

## round 车道（codex + 恢复腿）

`agentctl start codex …` 委派给内部引擎 `dispatch-exec`（久经实战：`codex exec` 逐轮 + resume，
`--workflow review-loop --max-rounds N` 轮数预算、`BUDGET-EXHAUSTED` exit 9 止损、SHIP-BLOCKING
续轮租约）。单轮内引擎不读 stdin——轮内影响只有 goal 预先约定 `STEERING.md` 轮询，或
`agentctl stop` 后重派；轮间 `agentctl steer` = resume 同一 engine session。codex 的 duplex 面
（app-server）官方仍标 experimental，真需要 mid-turn steer 再上（届时用其 schema 生成器锁协议）。
引擎级 resume 语义、退出码坑见 `dispatch-exec` 脚本头注——使用者不需要。

## Launch

- `agentctl start … --goal <f>` 在 goal 帧被引擎接受后返回（omp 有 correlated response；claude 为
  送达即返，无逐帧 ack——诚实边界）；**不会自动 watch**，紧接着用宿主受控后台能力挂
  `agentctl watch <session>`（**NOT shell `&`**，会孤儿化；guard ⑤ 强制 run_in_background，
  同步 shell 编排者前缀 `AGENT_WATCH_SYNC=1` 显式放行并自读 exit code）。
- `--require-preflight` 是显式 opt-in：只给高不确定、即将进入昂贵设计/实现的方向；两车道都在启动
  引擎前调 `../goal-preflight.py` 校验 `Preflight: <probe> => <observed result>` 已解占位。
- 引擎二进制可用 env 覆盖（测试缝 + 自定装机位）：`AGENTCTL_BIN_OMP` / `AGENTCTL_BIN_CLAUDE`。
- exit 6 `IDLE-NO-DELIVERABLE` 用 `agentctl steer` 补一刀，**不要 stop**；`stop` 只用于收工或明确放弃。

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
| 9 BUDGET-EXHAUSTED（round）| review-loop 轮数上限 | 转人工裁决 |
| 10 RUNNING | 瞬时态（status 一次性查询用） | 继续等 |

- **turn_end ≠ 任务终态**：多步 agent 每个 turn/阶段边界都呈 idle（实证 2026-07-05 单日 4 次假
  DONE）——deliverable gate + watch 的 2 连稳定读正是为此；多轮 goal 靠 epoch 轮转防上一轮产物开门
  （实证 2026-07-11 三任务全中）。
- **纯事件驱动会盲等**：挂 watcher 同时按"任务预期时长 ×2"设 fallback 自检（CC `ScheduleWakeup`；
  shell 编排者 cron/有界轮询）。
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
  `E2E_ECONOMY=1` 自 declare）。①用剥引号视图，④用原始 cmd，⑤⑥只认命令位（路径当参数不拦——上线当天
  两次自误伤修出的判据）。git-push 治理归 `git-workflow-standard` + 服务端 ruleset，不在此。
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
| duplex 产帧 / 投影 / 路由 / 死亡路径 | ✅ hermetic | `test/agentctl-duplex.test.sh`：进程级 fake tmux + scriptable fake 引擎驱动真 fifo/flock/events 管线（52 断言） |
| duplex live（真 omp 17.0.5 / claude 2.1.215） | ⏳ 本分支 e2e | `test/e2e/agentctl-duplex.e2e.sh`：start→watch→steer→watch→stop 全链 + 零残留；**claude 裸 CLI stream-json 多轮注入的首个 live 实证**（文档推断，若不成立 claude 腿回退 round） |
| round 车道（dispatch-exec 内部引擎） | ✅ | hermetic 全分支（195 断言）+ 既往 live 双轮绿；deliverable 相对 glob 修复带回归测例 |
| deliverable 门（exit 6 / freshness / 相对 glob） | ✅ | hermetic 对抗测试，两车道 |
| guard ①-⑥ / P0a-P0d | ✅ | hermetic + `hook-deny-pointer` 自指门（DENY 指针目标真实性）|
| BLOCKED.md 协议真 fire | ◯ 未 live 验 | footer 结构化自带；hermetic 有测例，live 实证仍缺 |
