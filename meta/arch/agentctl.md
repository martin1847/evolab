# agentctl 代码架构（维护者视角；使用语义见 `skills/cto-orchestration/references/agentctl/README.md`）

维护者内容不进 skill 本体（skill = 产品面；制造过程与白盒细节收敛在本仓 meta/arch）。
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
- 子原因闭集的两道门：import 期自检（`SUB_REASONS` 每行必须落在已发布 typed state 上、每个
  `SUB_REASON_*` 常量必须在表里）+ S6 静态门——任何产出 `reason=` / `progress=` /
  `progress_reason=` 的字面量或 f-string，其词必须来自 `sub_reason()`（直接调用，或经赋值 /
  元组解包 / return 传递且全程只绑定过其结果的名字），否则红；f-string 硬写词 / 拼接 / `getattr`
  绕读 / 新写发射 helper 四种形态各有变异用例转红。三套已发布词表按站点点名豁免
  （SUPERVISOR-LOST 的 `dead`/`unknown` 由该 state 的 `meaning` 句发布并被门反查、DONE 收据回显
  marker 自带字段、IDENTITY-UNKNOWN 用 identity.py 词表），豁免表每条必须被用到——多一条即红。
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

## 实现细节（自产品 README 剥离；改这些行为时同步这里，不回流 README）

- **check-params glob 判定全枚举**：绝对与相对 glob 一律判——含 `..` 分量即拒；最深已存在祖先目录
  物理解析后不在 cwd 内即拒（含 symlink 外逃）；无已存在祖先按歧义拒；basename 为空 = 目录非交付物、拒。
  进 meta 的参数面值一律拒含换行（否则注入 meta key 可无声改档），写点 `meta_update` 兜底引擎回传值。
- **fifo 单写者**：所有 fifo 写经 duplexctl `write_frame`（flock `acquire_writer_lock`）；并发 steer 由锁串行。
- **steer-log sidecar**：ts + mode + 首行 ≤80B，单写者 duplexctl，best-effort。
- **stop 收割序列**：pane 起在自有 session+group（pane_pid == pgid）；TERM → 宽限
  `AGENTCTL_REAP_GRACE`（默认 5s）→ KILL → pgrep 复核零残留；陈旧 meta 走 leader lstart 指纹防
  pid 复用误杀。
- **worktree 门（guard ⑦）benign 快路**：整条命令是单一 `git [-C <path>] worktree prune` 且
  porcelain 证明所有 prunable 目录已消失 → 放行；任何链式 / env 前缀 / 多 `-C` / 解析歧义 /
  `lexists` 命中都落回 DENY；mixed 命令不 auto-allow、落回分类器。
- **progress 三源细节**：仓库指纹的脏树 hash 按 untracked 逐文件展开；events 尾部半行帧 = 正在落帧，
  该源本次不可判且那些字节算移动；pane 源 `pgrep -g <pane_pid>` + `pane_lstart` 指纹（不符 = pid
  复用，该源不可判）；三探针共用 classify 死线 40% 的预算（默认 12s），超预算按不可判计、绝不让慢
  量具变成 ENGINE-SILENT；合同：任一源不可判 + 其余可判源全静 ⇒ 14 `reason=unknown-source`。
  unknown-source 的 detail 候选：git 探针失败 / 脏路径超 500 / 预算用尽 / events 坏行或半行 /
  pgrep 空组 / pane 身份不符。
- **guard 解析器注意**：bash 规则①用剥引号视图，④用原始 cmd，⑤⑥⑧⑩只认命令位（路径当参数不拦）；
  ⑨判归一化后的 shell 执行面（剥引号 span + 去反斜杠，转义写法照拦；字面量进 shell 命令即拒 =
  已接受的假阳性）；⑬ cyberPolicy 误拦实证 n=4 故降 WARN。
- **steer 语义迁移史**：旧 `--now` 已删（传了报错指新语义）；`--replace` 为 `--interrupt` 的静默别名。

重扫：`python3 -c 'import ast…'` 顶层项分类脚本与各项取数命令归档在编排位本地
`docs/orchestration/archive/PSPLIT_SCAN_RESULT_omp.md`（不入库）；再评时派只读席复跑同一判据。
