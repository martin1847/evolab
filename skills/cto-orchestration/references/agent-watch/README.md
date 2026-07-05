# Agent-state watch — unified, hook-based (replaces glyph screen-scraping)

Detect a tmux-resident coding-agent's state — **WORKING / WAITING / DONE** — from the agent's OWN lifecycle
hooks, not by scraping/guessing the TUI. Supports **omp, codex, Claude Code**. Screen-scraping
(`lib/scrape-fallback.sh`) remains the FALLBACK + the hard-crash backstop.

## Why
Screen-scraping mis-detects WAITING (TUI renders nav hints as text vs glyphs, menu glyph outside the tail
window → a still-waiting agent reads as idle/DONE) and is version/layout fragile. Every supported agent exposes
deterministic lifecycle hooks that fire regardless of how the prompt renders — that's the ground truth.

## Contract (all three agents converge here)
- **Sentinel file**: `$AGENT_WATCH_DIR/<session>.events` (default `AGENT_WATCH_DIR=~/.agents/run`).
  `<session>` = the tmux session name, passed to the agent process via env `AGENT_WATCH_SESSION` at launch.
- **Line format**: `<ISO8601-UTC> <STATE> [detail]`, one per event. `STATE ∈ {WORKING, WAITING, DONE}`.
- **Current state** = the LAST line's STATE. New turn → WORKING again; the watcher reacts to transitions.
- **Shared emitter**: `emit.sh <STATE> [detail]` appends one line. Every per-agent hook calls ONLY this — state
  semantics live in one place; adapters just map their native events to a STATE.

## Per-agent adapters (thin; map native events → STATE → emit.sh)
| agent | WORKING | WAITING | DONE | load mechanism |
|---|---|---|---|---|
| omp | `pi.on("turn_start"\|"tool_call")` | `pi.on("waiting")` | `pi.on("turn_end"\|"idle")` | `omp --hook hooks/omp-watch.ts` (or `~/.omp/agent/hooks/`) |
| codex | `PreToolUse` | `PermissionRequest` | `Stop` | `.codex/hooks.json` → calls `hooks/emit-from-stdin.sh` |
| claude | `PostToolUse` | `Notification` matcher `permission_prompt` | `Stop` + `Notification` matcher `idle_prompt` | `.claude/settings.json` hooks → `hooks/emit-from-stdin.sh` |

Codex/Claude hooks pass JSON on stdin with `hook_event_name` (+ codex) / `notification_type` (Claude); the
`emit-from-stdin.sh` shim reads it, maps to a STATE, calls `emit.sh`. omp's TS hook calls a tiny writer inline.

## `watch` (the monitor)
1. **Primary**: tail `$AGENT_WATCH_DIR/<session>.events`. Last STATE: `DONE`→exit 0, `WAITING`→exit 4,
   `WORKING`→keep polling. Reacts to the agent's real lifecycle, no glyph heuristics.
2. **Backstop (kept from v1)**: liveness guard — `pane_current_command` back to a shell ⇒ AGENT-DEAD (exit 2),
   for a hard crash where NO hook fires. Hang heuristic — STATE=WORKING + events file stale ~6min AND
   the screen is genuinely frozen (two captures ~3s apart identical) ⇒ exit 3. The frozen-screen
   re-check is load-bearing: event-staleness ALONE false-positives during a long recon/sub-agent phase
   where the pane is alive and repainting (observed 2026-07-03) — such a case defers instead of firing.
   Menu guard (B2) — before HANG ripens: stale ~1min + interactive-menu chrome in the pane tail
   (`enter select` / `Type to search`; override `AGENT_WATCH_MENU_RE`) ⇒ WAITING (exit 4), because an
   agent's ask-user menu may not fire its WAITING hook (实证 2026-07-02: omp clarify-menu emitted no
   `waiting` event → stale-WORKING + frozen screen misread as HANG; real state = waiting on the orchestrator).
   External-provider stall — STATE=WORKING but provider-error chrome (overload/rate-limit/5xx) repeats on screen
   ⇒ STALLED-EXTERNAL (exit 5). Catches a hot-retry loop the hang heuristic misses: a retryable provider error
   is auto-retried in place (omp `auto_retry_start` → backoff → `continue`, capped at `retry.maxRetries`≈10), so a
   fresh `turn_start` (WORKING) fires each retry but a terminal `turn_end`/DONE never does (only a non-retryable
   output-blocked error emits turn_end). The screen repaints each retry so the frozen-screen check never trips
   either → silent wait. Pattern overridable via `AGENT_WATCH_EXT_ERR_RE`. On exit 5:
   don't wait — kill the hot-retrying agent and re-dispatch a fresh session (no back-off state) once the provider recovers.
3. **Graceful degradation**: sentinel file absent (hook not loaded / older agent) — OR present but still empty after
   ~2min (hook wired but never firing, e.g. codex hooks untrusted) — ⇒ fall back to `lib/scrape-fallback.sh`
   screen-scraping. So nothing regresses whether a session launched without the hook, or with a silent one.

## Honest limits
- Hooks fire INSIDE the agent process → a hard crash (SIGKILL/segfault) emits nothing. The liveness guard, not
  the hook, catches that. Two layers by design.
- **codex** WAITING only covers `PermissionRequest` (tool-approval). A free-form "ask the user" menu may not fire
  it (codex `notify` is turn-complete-only too). Screen-scrape fallback covers that gap for codex.
- **Claude Code** `Notification` fires in INTERACTIVE mode only (not `claude -p`). We run interactive `claude` in
  tmux for steering, so it applies; headless would need `Stop`/`PostToolBatch` instead.
- **STALLED-EXTERNAL (exit 5) can false-positive**: the `EXT_ERR_RE` chrome (e.g. `Too Many Requests`,
  `service unavailable`, `Overloaded`) is also plausible content an agent prints while editing retry/error-handling
  code or reading logs. BUSY/WORKING + N-poll repetition + a wide tail narrow it, but don't eliminate it. exit 5
  dumps the pane tail so the orchestrator can eyeball it as provider chrome before killing — confirm, don't blind-kill.
- **codex launch frictions (per-machine, not skill bugs)**: a malformed GLOBAL `~/.codex/hooks.json` makes codex
  warn at every launch (`failed to parse hooks config … unknown field`) but does NOT block — the skill installs a
  project-local `.codex/hooks.json`, unaffected. And codex prompts for directory-trust on first launch in a new cwd
  (send `1`+Enter) — separate from any bypass flags. Both observed while driving codex as the orchestrator.

## Launch (per agent, sets env + hook)
> **CRITICAL (verified the hard way):** the `AGENT_WATCH_*` env MUST be set **INSIDE the command string**
> tmux runs — NOT as a prefix before `tmux new-session`. A running tmux server has a frozen environment, so a
> client-side prefix does NOT reach the pane process → the hook sees empty `process.env` → silent no-op (events
> file stays empty). Put the assignments in the `sh -c` command:
- omp:    `tmux new-session -d -s <s> -c <cwd> 'AGENT_WATCH_SESSION=<s> AGENT_WATCH_DIR=<dir> omp --hook <abs>/hooks/omp-watch.ts'`
- codex:  copy `hooks/codex-hooks.json`→`<cwd>/.codex/hooks.json` with `ABS` replaced by the abs path to
  `hooks/emit-from-stdin.sh`; then `tmux new-session -d -s <s> -c <cwd> 'AGENT_WATCH_SESSION=<s> AGENT_WATCH_DIR=<dir> codex'`
- claude: merge `hooks/claude-hooks.json` (`ABS` replaced) into `<cwd>/.claude/settings.json`; then
  `tmux new-session -d -s <s> -c <cwd> 'AGENT_WATCH_SESSION=<s> AGENT_WATCH_DIR=<dir> claude'`
**Canonical commands (use these, not the raw recipes above):**
- `dispatch <omp|codex|claude> <session> <cwd>` — launches the agent wired to the hook (bakes in the
  env-in-command rule + ABS sub; truncates the session sentinel; age-purges old ones).
- `watch <session> [busy-marker]` — monitor (hook-primary, scrape-fallback). It BLOCKS until a terminal state,
  then exits a typed code (0–5). **Default (any shell orchestrator — codex etc.): run it synchronously and read
  the code** — `bash <dir>/watch <session>; rc=$?` then branch on `$rc`. A **background orchestrator (Claude Code)**
  instead launches it via its background mechanism (NOT shell `&`, which orphans it) + reads the `WATCH ARMED`
  line + completion notification. Either way, confirm with capture-pane — the code is a lead, not gospel.
  (Validated: a codex shell-orchestrator independently built `…/watch <s>; rc=$?`, read `0=DONE`, then verified.)
- `teardown <session> [cwd]` — kill the session + remove its sentinel + remove the worktree's `.codex` hook config.

## Validation status (2026-06-16)
- ✅ omp adapter e2e: hook loads (omp 15.12.4), `turn_start`→WORKING / `turn_end`→DONE fire + write the sentinel.
- ✅ emit.sh / emit-from-stdin.sh (drains stdin, state-from-arg) / watch tail-parse / fallback-to-scrape.
- ✅ omp via `dispatch` (real dispatch): hook fires the full lifecycle (turn_start/tool_call→WORKING,
  turn_end→DONE); watch reads the sentinel (NOT fallback) and detects DONE correctly. Full dogfood passed.
- ⚠️ **codex hooks need TRUST**: a freshly-dropped `.codex/hooks.json` does NOT run until trusted (codex has
  `--dangerously-bypass-hook-trust`); until then no events fire → **watch falls back to screen-scrape**
  (graceful, by design). To get the real codex signal, persist hook trust once or launch codex with the bypass
  flag. Until then codex monitoring = screen-scrape fallback (works, just not hook-deterministic).
- ⏳ Claude (`Stop`/`Notification`/`PostToolUse`) wiring built per docs — validate on first real Claude dispatch.
- ◑ STALLED-EXTERNAL (exit 5): detection PREDICATE validated offline against provider-error-chrome fixtures —
  true positives (529/overloaded, 429 rate-limit, 503 unavailable, insufficient_quota, stream error) and true
  negatives (normal edits, an agent merely reasoning about "error") classify correctly; watch↔scrape regex parity
  asserted. **KNOWN false positives**: the same tokens appear when an agent edits rate-limit/error-handling code
  or reads provider logs (predicate matches) — so exit 5 is advisory: eyeball the dumped tail (provider chrome vs
  file content) before killing. NOT yet validated: the WORKING/BUSY + N-poll gates and a live provider stall e2e.
- Note: `dispatch` writes `.codex/hooks.json` into the worktree and auto-adds `.codex/` to that repo's
  `.git/info/exclude` (so it can't be `git add -A`'d). `teardown` removes the file itself.

---

## Orchestrator-side dispatch & watch discipline (SKILL §1.3–1.4 的展开)

SKILL 主干只留三条 watch 判据（typed 状态 + DEAD≠DONE / 判完成要正向证据 / 后台启动不加 shell `&`）
和派发的 hook-gate 判据。这里是派发命令、坑枚举、typed 状态全枚举、各失败态的实证。

### 派发（首轮一律融合 `--goal` 一条命令，omp/codex 同构；复审轮/steering 用 `dispatch send`）

```bash
# 首选（首轮派发，omp/codex/claude 同构）：launch → 送 goal/brief → 验 hook → 自动 watch，一次 Bash
# run_in_background 调用。dispatch 把 hook env 注进 tmux 命令串——watcher 走 hook 主信号的前提，缺则退化抓屏。
references/agent-watch/dispatch <omp|codex|claude> <proj>-<task>-<agent> <worktree> --goal <abs-goal-or-brief-path>
# 派发后 Read 一次输出确认：[send] OK…WORKING + hook 三档之一——
#   hook: WORKING ✓（sentinel 在）/ pane is BUSY（codex 首个 tool 前无 sentinel，正常）/ NO sentinel…（真异常，停下重起）
# 无独立 --watch flag（goal 即 watch）；设计论证见 dispatch 头注。

# 两步流（复审轮 / 后续 steering；codex 首启目录信任提示由 --goal 自动应答，不再是两步流的理由）：
references/agent-watch/dispatch send <session> -f <fixround.md>   # 确认环收尾：真转 WORKING 才算送达
# 然后单独 watch —— 必 Bash run_in_background，禁 shell `&`
```

裸 send-keys 是**逃生舱不是正路**（长/CJK 已被 guard DENY，逼 `dispatch send`），其坑照录在案：
文本与 Enter 分开发；文本含 `@` 触发补全 → 先发 `Escape` 再 `Enter`；**长中文/特殊符号
（①②③、全角冒号）指令会触发 omp 的 skill 模糊搜索弹窗吃掉 Enter，且 Escape/Ctrl-C 关不掉**（实证
2026-07-02）→ `C-u` 清输入框 + 改发一行短 ASCII 引用指令文件（评审回修/多段指令一律写成
`docs/orchestration/*_TASK|FIXROUND*.md` 再让 agent 读）；**弹窗事故后 TUI 输入层可能整体楔死**
（多词 send-keys / paste-buffer 全被吞、C-u 无效，仅单 token 偶通）→ 别恋战，teardown + 重派新会话
（状态都在 commit/goal 文件里，无损）；codex 启动更新提示——一次性在
`~/.codex/config.toml` 设 `check_for_update_on_startup = false` 免掉（否则每次得先发 `2`+Enter）。

**起后立刻验 hook（硬 gate，别跳）**：Read dispatch 输出按三档判定——`WORKING ✓`（sentinel）或
`pane is BUSY`（codex 首个 tool 前正常）均可继续；`NO sentinel…pane not busy` = 没走 dispatch / goal
没送达 → **停下重起、别带病跑**
（实证：裸起整 session 退抓屏，误报 DONE + 漏 WAITING——澄清菜单挂 busy 标记 ⟦esc⟧、抓屏永判"忙"、卡 21min 零 ping）。

**派发后、动手前先过理解门**：第一轮要 agent 复述"这改动碰哪些文件/契约、有哪些风险"，核对无误再放行；
弱答/跑偏当场纠正，别把沉默当默许。一句复述挡掉大半"误解 goal 就埋头改"。

### typed 状态（编排者纪律）

- **typed 状态**：0 DONE / 1 SESSION-GONE / 2 AGENT-DEAD / 3 HANG / 4 WAITING-INPUT / 5 STALLED-EXTERNAL
  （DEAD≠DONE、WAITING 要回输入）。长跑批触 HANG 上限 = "still busy" 重挂、非故障。
- **5 STALLED-EXTERNAL = 外部 provider 错误热重试盲区**（overload/rate-limit/5xx；agent 活着 WORKING 却永不
  DONE，机制见上文 `watch` backstop + Honest limits）。收到 5：**先核证再动手**——扫 exit 5 附带的屏尾，确是
  provider chrome（非 agent 写错误处理代码刷屏误报）再 kill 热重试 agent、换新会话（不带退避状态）。实证盲等 ~13min。
- **纯事件驱动会盲等：挂 watcher 时同时设上限**。除 watcher 外，按"任务预期时长 ×2"设个 fallback 自检
  （定时兜底——CC:`ScheduleWakeup`；codex/shell 编排者:cron 或有界轮询），到点没终态就主动 capture-pane
  ——"WORKING 但卡死/热重试"不发终态事件。
- **Agent 工具异步 subagent 的完成通知有黑洞：只在"停止且自身无存活后台子进程"时才发**。子 agent 若自起后台
  fork（如它派 Playwright E2E、或为保活起 monitor），这些子进程一直活着 → 父 agent idle 等待却**永不发完成
  通知** → 编排者盲等到天荒地老（实证 2026-06-26：某 agent 自起 E2E fork + 保活 monitor，完成通知从不触发，
  靠主动 SendMessage 才发现它早停那了）。对策：① **别只信完成通知**——长/浏览器异步 dispatch 按上条配
  fallback 自检（`ScheduleWakeup`/cron）兜底；② 派工时要求 agent **验证在本回合内同步做完、不留孤儿后台
  fork**，到里程碑 **SendMessage 回 main**，让父 agent 能干净收尾发通知。

### 判完成要正向证据、不凭 idle / watcher 裁决

tmux 链路无失败信号：session 在则 send/capture 都"成功"；watcher 裁决同样只是线索，后台型/阻塞型哪条
消费路径（见 SKILL §0 + 上文 `watch`）都要自己 capture-pane 正向核证、不盲信。两个坑：
- ① agent 死了退回 shell = 空屏+无忙碌 → 必须核 `pane_current_command` 仍是 agent 进程；
- ② **agent 自起后台 job 会 yield=发 DONE 但没完成**（bg 跑完自动续）——凡这类相把完成信号绑**正向交付物**
  （本地 commit／产物计数达标／显式 review 标记），别把"等自己 bg"误判成"等编排者"（实证：重批量抽取走
  agent 自起 bg，按 idle 轮询屡误报，改判"出现本地 commit + idle 稳定"才准）。是 `沉默≠交付` 的同族。

### 强制层：两个单一职责 guard 脚本

脆弱完成信号会以三种方式骗编排者，光记规则没用（有规则照样违反）→ 工具调用层兜底。**两个 python3 脚本，按
hook 拆开**（wiring 层本就按 event 分两条 entry，内部再分派是死重量；JSON 用 stdlib 解析/生成）：
- **`cto-guard-bash.py`（PreToolUse·Bash；deny=exit 2+stderr，提醒=additionalContext）** — ① 拦背景 `&`（**剥引号 span 后
  任意单 `&`**，含 `& <命令>`；`&&`/`2>&1`/`&>`/引号内 `&` 放行）；② DENY「纯 idle-absence、无正向 grep」的裸轮询
  （idle≠done；带 git 交付物 / pane Verdict·prompt 才放行）；③ `dispatch` 后同条没 arm `watch` → 提醒（omission 无法硬 deny）；
  ④ **拦长/CJK 裸 `tmux send-keys`**（omp 弹窗吃 Enter → 卡死 → 逼走 `dispatch send`）。① 用剥引号视图（`echo "a & b"`
  不误报），④ 用原始 cmd（CJK 在引号内）。**git-push 治理不在此**——归你的 Git 协作规范（evolab 公开镜像 `git-workflow-standard`）+ 服务端分支保护 ruleset。
- **`cto-guard-agent.py`（Pre+PostToolUse·Agent|Task|TaskStop，按 `hook_event_name`+`tool_name` 分派）** — **Pre·Agent**:
  browser/E2E 派发 prompt 含 `mcp__chrome-devtools` → DENY（逼 Playwright，防 CDP 争抢挂死，P0a）；**Pre·TaskStop**: 杀的 agent
  `.output` 120s 内还在长 = 活的 → DENY（"零截图"≠卡死，a11y agent 只产快照；override=`touch /tmp/cto-allow-kill-<id>`，P0b）；
  **Post·Agent**: browser 派发注入黑洞 deadline-watch 提醒（提醒必须 JSON `additionalContext`，纯 stdout agent 看不到）。

#### Wiring（§0：CC / Codex / omp 都能坐编排位；hook 模型各异，已对三家官方文档核实）

| | Claude Code | Codex | omp (oh-my-pi) |
|---|---|---|---|
| hook 形态 | command 脚本 + stdin JSON | **同 CC**（契约对齐） | **in-process TS/JS 模块** |
| 两脚本直接挂 | ✓ | ✓（bash 脚本；agent 脚本休眠） | ✗ 需 TS port |
| 命令字段 | `tool_input.command` | `tool_input.command` | `event.input.command` |
| deny 机制 | `exit 2 + stderr` | `exit 2 + stderr` | `return {block:true,reason}` |
| 浏览器提醒 | ✓ `additionalContext` | 休眠（无 Agent/Task 工具） | `tool_result` 不能注入（需 `context` 事件） |
| wiring | `.claude/settings.json` | `.codex/hooks.json`（嵌套 JSON） | `.omp/hooks/pre/*.ts` |

**不另造 settings 脚手架——并进 `repo-governance-bootstrap` §11 已建的那份**。**entry 真源 = 本目录
`guard-hooks.json`（唯一权威，别抄文档散文）**：接入时读它、把 command 换成安装根绝对路径（hooks 不展开 `~`）、
按 event 并进项目 settings（CC `.claude/settings.json` / Codex `.codex/hooks.json` 同格式）。两条铁则：
**直接 exec 别加 `python3 `/`bash ` 前缀**（脚本自带 shebang；前缀=押注 PATH 里的解释器，venv 一动全静默死）；
matcher 别手编——它与脚本实现同包维护、发布门校验一致（曾实证漂移：README 抄本少了 `KillShell`）。

> **不靠 skill frontmatter `hooks:` 自注册**：文档说 skill 可在 frontmatter 声明 hook、skill active 时生效，但
> **实测 mid-session 经 Skill 工具激活并不注册**（cto 恰是按需 mid-session 激活，正是要 guard 的那刻拿不到）→ 显式 wiring 才可靠。

- **CC / Codex**：上面同一 JSON（CC `.claude/settings.json`、Codex `.codex/hooks.json`；契约对齐 drop-in：
  `hook_event_name`/`tool_name`/`tool_input.command`、`exit 2` deny、`additionalContext` 全同名）。Codex 无 Agent/Task
  工具 → agent 脚本休眠（harmless）；codex 起需带 `--dangerously-bypass-hook-trust`（见 bootstrap §11 ⚠️）。
- **omp**：hook 是 in-process TS 模块（默认导出 factory、`pi.on("tool_call", e => …)`、`e.input.command`、return
  `{block:true,reason}`），**不吃 stdin-JSON 命令脚本** → python 脚本挂不上；把 bash 脚本判定写成 `.omp/hooks/pre/*.ts`
  （或 TS shell-out + 字段映射 `event.input.command`→stdin-JSON + `exit 2`→`{block:true}`）。浏览器提醒在 omp 最难：
  `tool_result` 只能改输出、不能给模型注入 context，要走单独 `context` 事件。
