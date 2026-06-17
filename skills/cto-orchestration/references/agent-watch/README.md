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
   for a hard crash where NO hook fires. Hang heuristic — STATE=WORKING but file stale + screen frozen ⇒ exit 3.
   External-provider stall — STATE=WORKING but provider-error chrome (overload/rate-limit/5xx) repeats on screen
   ⇒ STALLED-EXTERNAL (exit 5). Catches a hot-retry loop the hang heuristic misses: a retryable provider error
   is auto-retried in place (omp `auto_retry_start` → backoff → `continue`, capped at `retry.maxRetries`≈10), so a
   fresh `turn_start` (WORKING) fires each retry but a terminal `turn_end`/DONE never does (only a non-retryable
   output-blocked error emits turn_end). The screen repaints each retry so the frozen-screen check never trips
   either → silent wait. Pattern overridable via `AGENT_WATCH_EXT_ERR_RE`. On exit 5:
   don't wait — kill the hot-retrying agent and re-dispatch a fresh session (no back-off state) once the provider recovers.
3. **Graceful degradation**: sentinel file absent (hook not loaded / older agent) ⇒ fall back to `lib/scrape-fallback.sh`
   screen-scraping. So nothing regresses if a session was launched without the hook.

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
- `watch <session> [busy-marker]` — monitor (hook-primary, scrape-fallback). Run via the orchestrator's
  background mechanism (NOT shell `&`); read its output for the `WATCH ARMED` line to confirm liveness.
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
