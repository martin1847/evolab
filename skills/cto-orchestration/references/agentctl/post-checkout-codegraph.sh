#!/usr/bin/env bash
# post-checkout git hook — auto codegraph init for freshly created linked worktrees.
#
# Dispatch creates one worktree per seat; with this hook wired, every seat lands in a
# worktree whose codegraph index is already building — goals can rely on `codegraph explore`
# without each seat paying its own init.
#
# Wire it (per repo, hooks are not cloned):
#   ln -s <abs path to this file> <repo>/.git/hooks/post-checkout
# Ensure `.codegraph/` is in the repo's .gitignore — an untracked index makes every new
# worktree dirty and trips the dirty-worktree dispatch gate.
#
# Contract: NEVER fail the checkout (always exit 0); never block (init runs detached,
# log under /tmp). Fires only for linked worktrees ($3 = 1, git-dir != git-common-dir)
# with no existing .codegraph; the main checkout is untouched; no codegraph binary = no-op.
# git runs post-checkout with cwd = the new worktree root.
set -u

flag="${3:-0}"
[ "$flag" = "1" ] || exit 0
command -v codegraph >/dev/null 2>&1 || exit 0

gd="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
[ "$gd" != "$gcd" ] || exit 0          # main checkout: not our job
[ ! -e .codegraph ] || exit 0          # already initialized

wt="$(pwd)"
log="/tmp/codegraph-init-$(basename "$wt")-$$.log"
nohup codegraph init >"$log" 2>&1 </dev/null &
echo "post-checkout: codegraph init started in background for $wt (log: $log)" >&2
exit 0
