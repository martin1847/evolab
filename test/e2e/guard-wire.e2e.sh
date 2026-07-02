#!/usr/bin/env bash
# guard-wire.e2e.sh — LIVE closed-loop for the agent-watch enforcement layer.
# Proves the REAL delivery path, not just script logic: a fresh headless `claude` session,
# with cto-guard wired via project .claude/settings.json, actually DENIES a trailing-`&`
# Bash command (PreToolUse exit-2 path shown to the agent; command never runs).
# This is the automated form of the v1.2.4 manual 真 wire 闭环验证.
# Asserts on durable evidence (the marker file the & command would create), not model prose.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only; no sandbox needed

REPO_ROOT="$(cd ../.. && pwd)"
BASH_GUARD="$REPO_ROOT/skills/cto-orchestration/references/agent-watch/cto-guard-bash.py"

echo "== guard-wire.e2e (live claude session; ~1min, uses API tokens) =="
[ -x "$BASH_GUARD" ] || { echo "  FAIL guard script missing/not executable: $BASH_GUARD"; exit 1; }

WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-guardwire.XXXXXX")"
cleanup() {
  rm -rf "$WT"
  # sweep the session's memory dir under ~/.claude/projects (flattening turns '.' into '-')
  find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*$(printf '%s' "$(basename "$WT")" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$WT/.claude"
cat > "$WT/.claude/settings.json" <<EOF
{ "hooks": { "PreToolUse": [
  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$BASH_GUARD" } ] }
] } }
EOF

out="$(cd "$WT" && timeout 180 claude -p \
  "Use the Bash tool to run EXACTLY this command once, unmodified: touch AMP_RAN.marker &
Then state verbatim any block/deny message you received. Do not retry or work around it." \
  --dangerously-skip-permissions < /dev/null 2>&1)"

# durable evidence: the marker must NOT exist (command denied, never ran)
chk_eq "trailing-& command did not run (no marker)" 0 "$([ -f "$WT/AMP_RAN.marker" ] && echo 1 || echo 0)"
chk_contains "deny reason reached the agent" "ORPHAN" "$out"

summary
