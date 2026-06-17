# Governance plan — agent-watch (cto-orchestration skill) · PLAN ONLY, do not implement yet

Status: **IMPLEMENTED 2026-06-17** (evolab commit `7330b95`). Kept as the rationale record. Smoke-tested:
`dispatch omp → ~/.agents/run/<s>.events → watch detects DONE → teardown cleans`.

## Problems to fix
1. **Naming**: `watcher.sh` (screen-scrape) + `watcher2.sh` (hook-based) = versioned, two entry points, ugly.
2. **Directory**: runtime state at `~/.claude/agent-watch/run/` — buried under `.claude`, tool-coupled (the tool
   serves omp/codex/claude, not just claude).
3. **Hook state never cleaned**: `~/.claude/agent-watch/run/<session>.events` accumulate forever; `.codex/hooks.json`
   left in worktrees; no teardown.
4. **Skill sprawl**: this session added watcher.sh fixes + the whole agent-watch system + SKILL.md §1.4/§3 edits;
   needs consolidation + a single canonical monitor.

## Proposal

### 1. Naming — one monitor, verbs not versions
- `watch`  ← (was `watcher2.sh`) the SINGLE monitor: hook-primary, screen-scrape fallback. No "2".
- `lib/scrape-fallback.sh` ← (was `watcher.sh`) demoted to an INTERNAL fallback module that `watch` execs when
  no sentinel file exists. Not a user-facing entry.
- User-facing verbs: **`dispatch` / `watch` / `emit`** (+ `teardown`, new) + `hooks/`. Drop the `2`, drop version
  suffixes forever.

### 2. Tool-neutral runtime dir — `~/.agents/`
- Runtime state root → **`~/.agents/run/<session>.events`** (default for `AGENT_WATCH_DIR`); env override kept.
- Rename the env too for neutrality: `AGENT_WATCH_DIR` → keep as alias, add `AGENTS_RUN_DIR` (or just repoint the
  default). Skill CODE stays in the skill repo; only RUNTIME state moves out of `.claude` into `~/.agents/`.

### 3. Hook-state lifecycle + cleanup (the "找时机清理")
- `dispatch` **truncates** the session's `.events` on (re)launch → fresh state per session.
- New **`teardown <session>`**: kill the tmux session + `rm ~/.agents/run/<session>.events` + remove the
  worktree's `.codex/hooks.json`. One command to end a dispatch cleanly.
- **Age purge**: `dispatch`/`watch` opportunistically delete `.events` older than N days.
- `.codex/` is already auto-excluded from git (done); `teardown` removes the file itself.

### 4. Skill consolidation
- `watch`/`dispatch` become THE standard in `SKILL.md §1.4` (reference them, not raw `watcher.sh`).
- Keep the v1 screen-scrape ONLY as the internal `lib/scrape-fallback.sh`.
- SKILL.md §3 verify-first + §1.4 watcher discipline edits: keep, repoint to the consolidated names.

### 5. Migration steps (later)
1. `git mv watcher2.sh watch`; `git mv watcher.sh lib/scrape-fallback.sh`; fix `watch`'s fallback exec path.
2. Repoint `AGENT_WATCH_DIR` default → `~/.agents/run` across emit/watch/dispatch/hooks + README.
3. Add `teardown` + dispatch events-truncate + age-purge.
4. Update `SKILL.md` §1.4 references + `README.md` launch/monitor commands.
5. **Commit the evolab/skills repo** — these skill changes (watcher v1 fixes + agent-watch + SKILL.md edits) have
   been UNCOMMITTED all session; the migration is the moment to commit (Martin: external repo was "不用管" during
   the work, revisit at governance).
6. Smoke: `dispatch omp … ` → events in `~/.agents/run` → `watch` detects DONE via hook → `teardown` cleans.

### 6. Deferred / open
- Could extract agent-watch to a standalone `~/.agents/bin/` usable outside the skill — defer, keep in skill now.
- Claude-Code adapter still un-live-tested; codex hook needs trust (falls back to scrape) — note in README, not blocking.

## NOT in this plan / do-now housekeeping (separate from the rename)
Before the session restart, the *current* accumulated runtime state can be cleaned (harmless, not a code change):
stale `~/.claude/agent-watch/run/*.events`, any leftover `.codex/` in `wt-memory-card`, closed sessions. This is
state cleanup, not the skill refactor — safe to do at teardown.
