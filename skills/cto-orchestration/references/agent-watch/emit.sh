#!/usr/bin/env bash
# Shared sentinel emitter for the unified agent-state watch (see README.md).
# Every per-agent hook calls ONLY this — STATE semantics + line format live here.
# Usage: emit.sh <WORKING|WAITING|DONE> [detail]
# Env: AGENT_WATCH_SESSION (required; the tmux session name) ; AGENT_WATCH_DIR
#      (default ~/.agents/run). No session bound => silent no-op so we
#      never break the agent.
set -u
STATE="${1:-}"
DETAIL="${2:-}"
case "$STATE" in WORKING|WAITING|DONE) ;; *) exit 0 ;; esac
SESS="${AGENT_WATCH_SESSION:-}"
[ -n "$SESS" ] || exit 0
DIR="${AGENT_WATCH_DIR:-$HOME/.agents/run}"
mkdir -p "$DIR" 2>/dev/null || exit 0
printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STATE" "$DETAIL" >> "$DIR/$SESS.events"
exit 0
