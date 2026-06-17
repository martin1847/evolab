#!/usr/bin/env bash
# Hook shim for codex & Claude Code (command-type hooks). The STATE is passed as
# $1 by the hook REGISTRATION (one entry per event→state mapping in hooks.json /
# settings.json), so we do NOT parse the JSON payload — robust, no jq dependency.
# We just drain stdin (so the agent doesn't block on the pipe) then emit.
# Usage (from hooks config): emit-from-stdin.sh <WORKING|WAITING|DONE> [detail]
set -u
cat >/dev/null 2>&1 || true   # drain the hook JSON on stdin
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/../emit.sh" "${1:-}" "${2:-stdin-hook}"
