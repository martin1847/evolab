#!/usr/bin/env bash
# retro-check.sh — deterministic gate for the cto-orchestration 复盘仪式 (SKILL.md §5 hard gate).
# Verifies MECHANICAL governance invariants only (did the steps run / are artifacts fresh) —
# NOT semantic quality (whether the sync is meaningful). Exit non-zero on any FAIL so a caller
# (or a Stop/PreCompact hook) can block "复盘 done" until the floor is met.
#
# Usage:
#   bash retro-check.sh --base <branch> --docs <docs-dir> [--memory <MEMORY.md>] [--memory-cap N] [--repo <git-dir>]
# Defaults: --base auto-detected (origin/HEAD → main/master/develop); --docs docs; --memory-cap 45.
set -uo pipefail

BASE=""; DOCS="docs"; MEMORY=""; MEMCAP=45; REPO="."
while [ $# -gt 0 ]; do case "$1" in
  --base) BASE="$2"; shift 2;;
  --docs) DOCS="$2"; shift 2;;
  --memory) MEMORY="$2"; shift 2;;
  --memory-cap) MEMCAP="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

TODAY="$(date +%F)"
fails=0; warns=0
ok(){ echo "  [ok]   $*"; }
fail(){ echo "  [FAIL] $*"; fails=$((fails+1)); }
warn(){ echo "  [warn] $*"; warns=$((warns+1)); }

echo "== retro-check (date=$TODAY) =="

# resolve base branch
if [ -z "$BASE" ]; then
  BASE="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -z "$BASE" ] && for b in main master develop; do git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$b" && BASE="$b" && break; done
fi
[ -z "$BASE" ] && { warn "could not resolve base branch (pass --base); skipping worktree-merged check"; }

# 1) stray LINKED worktrees on already-merged branches (excludes the main checkout)
echo "1) worktree 核对 (已合分支无孤儿; 主 checkout 豁免):"
if [ -n "$BASE" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" fetch -q origin "$BASE" 2>/dev/null || true
  TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
  stray=0; cur="" br=""
  # iterate via a here-string so the loop runs in THIS shell (can bump $stray)
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) cur="${line#worktree }";;
      branch\ *) br="${line#branch refs/heads/}"
        # skip the main checkout (its path == toplevel) — it's not a disposable worktree
        if [ -n "$br" ] && [ "$cur" != "$TOP" ] && git -C "$REPO" merge-base --is-ancestor "$br" "origin/$BASE" 2>/dev/null; then
          echo "  [FAIL] stray worktree on MERGED branch '$br' → $cur  (git worktree remove)"; stray=$((stray+1))
        fi;;
    esac
  done <<< "$(git -C "$REPO" worktree list --porcelain 2>/dev/null)"
  if [ "$stray" -gt 0 ]; then fail "$stray stray linked worktree(s) on merged branches — remove them"; else ok "no linked worktree on a merged branch"; fi
fi

# 2) ACTIVE_CONTEXT rewritten today
echo "2) ACTIVE_CONTEXT 整篇重写 (今日):"
AC="$DOCS/ACTIVE_CONTEXT.md"
if [ -f "$AC" ]; then
  lr="$(grep -m1 -iE 'Last rewritten' "$AC" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  YDAY="$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F 2>/dev/null)"
  if [ "$lr" = "$TODAY" ] || [ -n "$YDAY" -a "$lr" = "$YDAY" ]; then ok "Last rewritten: $lr (today/yesterday — session may cross midnight)"; else fail "ACTIVE_CONTEXT 'Last rewritten'=${lr:-none}, stale (>1d vs $TODAY) — rewrite the snapshot"; fi
else fail "$AC not found (pass --docs)"; fi

# 3) roadmap touched recently (soft)
echo "3) roadmap 翻状态 (近期动过):"
RM="$DOCS/roadmap/active-roadmap.md"
if [ -f "$RM" ]; then
  if [ -n "$(find "$RM" -mtime -1 2>/dev/null)" ]; then ok "roadmap modified within 24h"; else warn "roadmap not touched in 24h — confirm status-flip not skipped (ok if genuinely unchanged)"; fi
else warn "$RM not found — skip"; fi

# 4) decision-queue freshness (soft, opt-in — only if DECISION_QUEUE.md present; §9 mechanism)
echo "4) 决策队列刷新 (DECISION_QUEUE.md 在则近期动过):"
DQ="$DOCS/DECISION_QUEUE.md"
if [ -f "$DQ" ]; then
  if [ -n "$(find "$DQ" -mtime -1 2>/dev/null)" ]; then ok "DECISION_QUEUE.md modified within 24h"; else warn "DECISION_QUEUE.md not touched in 24h — refresh (清 ✅ / revisit 到期重浮 / 全局图); 队列腐烂是 §9 最弱点"; fi
else echo "  [skip] no $DQ (decision-queue 是 opt-in)"; fi

# 5) MEMORY.md size (soft)
echo "5) memory 治理 (索引行数):"
if [ -n "$MEMORY" ] && [ -f "$MEMORY" ]; then
  n="$(wc -l < "$MEMORY" | tr -d ' ')"
  if [ "$n" -le "$MEMCAP" ]; then ok "MEMORY.md $n lines (≤$MEMCAP)"; else warn "MEMORY.md $n lines > $MEMCAP — trim/group COMPLETED"; fi
elif [ -n "$MEMORY" ]; then warn "$MEMORY not found — skip"; else echo "  [skip] no --memory given"; fi

echo "== result: $fails FAIL, $warns warn =="
[ "$fails" -eq 0 ]
