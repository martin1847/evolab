# agentctl 代码架构（维护者视角；使用语义见 README.md）

两个 python 文件 `duplexctl.py`（引擎侧 + argv 前门）与 `watchctl.py`（巡检侧），bash 前门 `agentctl`，
三个 guard 脚本。本文按**符号**描述分层，不写行号（行号漂）；数字来自只读预扫，重扫命令见文末。

## 分层（调用方向自上而下）

| 层 | 符号 | 引擎耦合 |
|---|---|---|
| bash 前门 | `agentctl`：usage / `case` 分派 / 派工 tmux 会话 / `--review` 档；引擎事实全部来自 `duplexctl providers --shell` 的 7 字段行（`P_*`），**零引擎条件分支** | 无 |
| argv 前门 | `duplexctl.main()` argparse → `cmd_*`（19 个来自 `watchctl`，`main()` 内局部 `import watchctl`）；`watchctl._ctl()` 以 `duplexctl.__file__` 自 exec `classify` / `watch-state` / `watch-lease` / `identity`——**`watchctl.py` 没有 argv 前门，也不会长出一个** | 无 |
| 词表 | `EXIT_*` / `TYPED_STATES` / `SUB_REASONS` / `CAPABILITY_*`；`agentctl states` / `capabilities` 发布面 | 无（词表内不含引擎名） |
| 引擎注册表 | `PROVIDERS{omp,claude,codex}`（spec：bin_env / bin / argv / extra_argv / sandbox / projector / capabilities×6 cell）→ 派生 `CAPABILITIES` / `ROUTES` / `PROJECTORS`；手工表 `TURN_ACTIVE` / `ENGINE_INFLIGHT` / `ENGINE_TOOL_EVENTS` | 按 engine 索引（事实接口） |
| 引擎实现 | `project_<e>` / `<e>_turn_active` / `<e>_inflight` / `<e>_tool_events`；codex 另有 app-server 帧层 `codex_request` / `codex_frames` / `codex_active_turn` / `codex_route_*` | lane-specific |
| 投递与分类（lane-shared） | `build_frame` / `send_frame` / `handshake` / `steer_delivery` / `classify` / `stream_stalled` / `tools_activity` / `progress_sources`：按 engine 分支或查表 | ≥2 引擎 |
| 进展指纹 | `progress_fingerprint` / `progress_verdict` / `ProbeBudget` / `pane_pgroup` / `pane_identity_drift` | 无 |
| watch / supervisor（`watchctl.py`） | lease（`write_lease` / `read_lease` / `supervisor_liveness`）、watcher（`watcher_alive` / `cmd_watch_*` / `consume_tombstone`）、`cmd_sense_loop` / `_sense_conclude`、`cmd_stop_*`、`cmd_inventory`、`cmd_classify` / `cmd_status` / `cmd_identity`；出向 import 面 = duplexctl 的 26 个符号（`EXIT_*` 11 / `Session` / `classify` / `die` / `arm_watchdog` / `status_timeout` / `sub_reason` / `PROVIDERS` …），入向 = `main()` 的 19 处接线 | 无 |
| 会话状态 | `Session`（run dir / fifo / events / meta / sent_offset / steer_log / `queued`）；`queued` 唯一写者 = `project_omp` | 字段被引擎实现读写 |

事实接口 = 6 方法 + 1 spec：`project` / `turn_active` / `inflight` / `tool_events` / `deliver`
（`build_frame` 分支 + `send_frame` 分支 + `ROUTES`）/ `handshake`。新增第四引擎的接入面：这 6 个实现 +
`PROVIDERS` 一条记录（7 键、6 cell）+ 3 张手工表各一条 + `cto-guard-bash.py` 三处
`(?:omp|codex|claude)` 交替 + README 硬计数行。

## 白盒测试耦合（改内部符号前先看）

- `test/duplex-fixtures/ws3/probe.py` `exec_module` 加载 duplexctl，绑定 `CAPABILITIES` / `ROUTES` /
  `PROJECTORS` / `PROVIDERS` / `TURN_ACTIVE`（monkeypatch）/ `steer_delivery` / `build_frame` /
  `codex_request` / `wait_for` 等——`agentctl-capabilities.test.sh` 57 个断言的底座。
- `agentctl-states.test.sh`：`ast.parse` 静态扫 `EXIT_*` / `TYPED_STATES` / `SUB_REASONS` 与四个 decider
  （`progress_verdict` / `_withheld_reason` / `steer_delivery` / `cmd_sense_loop`）。S4/S6 扫描面 =
  duplexctl.py ∪ watchctl.py（`subgate()` 一个入口喂两个文件）。**跨函数事实一律模块限定身份**
  （R2 评审 B1）：`SAFE_SCALAR` / `SAFE_SLOT` 按 (文件, 函数) 键入，FOREIGN 豁免表按
  (文件, 函数, 表达式) 键入，`table_lines` 按 (文件, 行) 键入；裸调用名按 python 的解析顺序落地
  ——调用方本文件的顶层定义优先，其次是它 `from` 导入的那个被扫模块，都不中即 UNRESOLVED 而
  UNRESOLVED 永不算安全（fail-closed）。`sub_reason` 这条公理也走同一解析：全局唯一定义之外的
  同名影子会让整个门喊 `sub_reason-not-uniquely-defined` 并把所有发射点判为不安全。
  **未用到的豁免项也变红**，函数搬家双向触发（豁免项里的文件名写错也红）。S6b 的变异锚按 mode 分
  文件：decider 类（`cmd_sense_loop`）打 watchctl.py，表类（`SUB_REASONS`）打 duplexctl.py。
- `agentctl-duplex.test.sh`：`_idle_mark_and_count` / `_idle_marks_reset` / `CODEX_SANDBOX`（sed 变异，
  divergent fixture 的 `cp` 清单含 watchctl.py）/ `_STOP_KEPT`（已随块搬到 watchctl.py，grep 面同步）。
- `agentctl-supervised-watch.test.sh`：`PROGRESS_BUDGET_*` 四赋值 + `progress_budget`（选中数硬编码 4）。
- `agentctl-reap.test.sh`：`f"={name}"` 存在 / `"-t", name` 缺席 / `os.kill(` 唯一——三条 grep 面都是
  两文件并集（缺席断言两文件都空，唯一断言两文件合计 `1 1`）。
- 文件身份门：`agentctl-weight.test.sh` 行数棘轮（拆文件须同 commit 改基线并为新模块加行）；
  `agentctl-capabilities.test.sh` C10 bash/python 占比分母 = 同目录**全部 `*.py`**（棘轮 76/1000）。
- 直连 CLI 子命令的 134 个调用点与内部符号无关，只要 argv 前门不动就不动。

## 拆分裁决账（kill criterion 读数）

| 日期 | 提案 | 读数 | 判 |
|---|---|---|---|
| 2026-08-30 | 接口 + omp/claude/codex 三实现模块 | movable=454（宽计 702）new-indirection=2；耦合点 25、共享助手绑定 29、白盒 case 86 | abandon（`movable<800`） |
| 2026-08-30 | watch/supervisor 块（`cmd_classify`…`cmd_inventory`）平移出独立模块 | movable=1208 stay=0 mutable-globals-crossing=0 whitebox-cases=9（断言执行 22）new-indirection=1；`_CTL` 须仍指前门；C10 占比 106→135/1000 撞线（预扫按 move=1208 的读数；实际搬 1385 行并删 3 个孤儿 import 后是 140/1000）、weight 棘轮须同 commit 改；states S4/S6 与 reap 缺席断言只扫 duplexctl.py（搬出即盲） | **已执行**（`feat/watch-module`）：1385 行搬入 `watchctl.py`，函数体逐字不改；`_CTL = os.path.abspath(duplexctl.__file__)` 仍指前门；三道门扩面（S4/S6 双文件、reap 三条 grep 并集、C10 分母改全 `*.py`）+ weight 基线 5009→3634 并加 watchctl 1428 行；R2 评审 B1 收口：S6 的跨函数摘要与调用解析改模块限定身份（见白盒耦合面） |

重扫：`python3 -c 'import ast…'` 顶层项分类脚本与各项取数命令归档在编排位本地
`docs/orchestration/archive/PSPLIT_SCAN_RESULT_omp.md`（不入库）；再评时派只读席复跑同一判据。
