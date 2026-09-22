#!/usr/bin/env bash
# codegraph git hooks — one script, three events, so a worktree's index keeps matching the
# worktree it describes.
#
# Dispatch creates one worktree per seat; with this wired, every seat lands in a worktree whose
# codegraph index is already building (post-checkout), and that index is re-synced after every
# commit and merge. codegraph 1.5.0 does NOT sync before a query, so without the two write
# events a seat's `codegraph explore` reports the blast radius of the tree as it was at init —
# stale, and silently so.
#
# Wire it (per repo, hooks are not cloned):
#   for h in post-checkout post-commit post-merge; do
#     ln -s <abs path to this file> <repo>/.git/hooks/$h
#   done
# The event is read from the LINK NAME (basename "$0"), which is how git invokes a hook; a
# trailing `-codegraph.sh` is stripped so the pre-0922 wiring name (post-checkout-codegraph.sh)
# keeps working. Any other name is a no-op.
# Ensure `.codegraph/` is in the repo's .gitignore — an untracked index makes every new
# worktree dirty and trips the dirty-worktree dispatch gate.
#
# Contract: NEVER fail or delay a git operation (always exit 0; codegraph runs detached, log
# under /tmp; no daemon, no lock, no result check, nothing is waited on). Two events firing at
# once just run two syncs. `init` fires only for a freshly created linked worktree ($3 = 1,
# git-dir != git-common-dir) that has no index yet; `sync` fires only where an index already
# exists, so a checkout that is not ours is left alone rather than silently indexed.
# git runs all three hooks with cwd = the worktree root.
set -u

hook="$(basename "$0")"
hook="${hook%-codegraph.sh}"
case "$hook" in
  post-checkout | post-commit | post-merge) ;;
  *) exit 0 ;;
esac
command -v codegraph >/dev/null 2>&1 || exit 0

wt="$(pwd)"

# (a) freshly created linked worktree, no index yet -> build one.
if [ "$hook" = "post-checkout" ] && [ "${3:-0}" = "1" ] && [ ! -e .codegraph ]; then
  gd="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
  if [ "$gd" != "$gcd" ]; then           # main checkout: not our job
    log="/tmp/codegraph-init-$(basename "$wt")-$$.log"
    nohup codegraph init >"$log" 2>&1 </dev/null &
    echo "post-checkout: codegraph init started in background for $wt (log: $log)" >&2
  fi
  exit 0
fi

# (b) any of the three events on a tree that already has an index -> refresh it.
[ -e .codegraph ] || exit 0
log="/tmp/codegraph-sync-$(basename "$wt")-$$.log"
nohup codegraph sync -q >"$log" 2>&1 </dev/null &
echo "$hook: codegraph sync started in background for $wt (log: $log)" >&2
exit 0
