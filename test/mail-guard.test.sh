#!/usr/bin/env bash
# mail-guard.py — PreToolUse guard: Write/Edit/MultiEdit into <bus>/<id>/inbox/ -> DENY (exit 2),
# pointing at `agent-bus send` (direct writes bypass size/brevity/atomic gates; 2026-07-10 live).
# tmp/, archive/, bus-root files, unrelated paths, other tools/events -> allow. Fail-open on
# garbage stdin. Hermetic: HOME and AGENT_MAIL_DIR point into a temp sandbox.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/agent-mail/mail-guard.py"

echo "== mail-guard.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

SB="$(mktemp -d "${TMPDIR:-/tmp}/mg-test.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"
mkdir -p "$HOME/.agents/mail/beta/inbox"
unset AGENT_MAIL_DIR CLAUDE_PROJECT_DIR 2>/dev/null || true

chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

mkp() { # $1 event  $2 tool  $3 file_path -> hook payload JSON on stdout
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name":sys.argv[1],"tool_name":sys.argv[2],"tool_input":{"file_path":sys.argv[3]}}))' "$1" "$2" "$3"
}
run() { local tmpe; tmpe="$(mktemp)"; OUT="$(mkp "$1" "$2" "$3" | python3 "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"; }

# ── DENY: Write/Edit/MultiEdit into an inbox (default bus root ~/.agents/mail) ──
run PreToolUse Write "$HOME/.agents/mail/beta/inbox/20260710-1200-alpha-x.md"
chk_eq "Write to inbox denied (exit 2)" 2 "$RC"
chk_contains "deny points to agent-bus send" "agent-bus send" "$ERR"
chk_contains "deny explains the bypassed gates" "atomic" "$ERR"
run PreToolUse Edit "$HOME/.agents/mail/beta/inbox/20260710-1200-alpha-x.md"
chk_eq "Edit to inbox denied (exit 2)" 2 "$RC"
run PreToolUse MultiEdit "$HOME/.agents/mail/beta/inbox/20260710-1200-alpha-x.md"
chk_eq "MultiEdit to inbox denied (exit 2)" 2 "$RC"
# ~-prefixed path expands before matching (hooks pass file_path verbatim from the tool call)
run PreToolUse Write "~/.agents/mail/beta/inbox/20260710-1200-alpha-y.md"
chk_eq "tilde inbox path denied (exit 2)" 2 "$RC"

# ── ALLOW: helper-owned / non-delivery surfaces under the bus ──
run PreToolUse Write "$HOME/.agents/mail/beta/tmp/20260710-1200-alpha-x.md"
chk_eq "tmp/ staging path allowed" 0 "$RC"
run PreToolUse Write "$HOME/.agents/mail/beta/archive/20260710-1200-alpha-x.md"
chk_eq "archive/ path allowed" 0 "$RC"
run PreToolUse Write "$HOME/.agents/mail/registry.md"
chk_eq "bus-root registry.md allowed" 0 "$RC"

# ── ALLOW: unrelated paths, other tools, other events ──
run PreToolUse Write "$SB/somewhere/else/inbox/letter.md"
chk_eq "unrelated path with inbox segment allowed" 0 "$RC"
run PreToolUse Read "$HOME/.agents/mail/beta/inbox/20260710-1200-alpha-x.md"
chk_eq "Read tool unaffected" 0 "$RC"
run PostToolUse Write "$HOME/.agents/mail/beta/inbox/20260710-1200-alpha-x.md"
chk_eq "PostToolUse unaffected" 0 "$RC"

# ── AGENT_MAIL_DIR env override wins over the default root ──
CUSTOM="$SB/custom-bus"; mkdir -p "$CUSTOM/gamma/inbox"
OUT="$(mkp PreToolUse Write "$CUSTOM/gamma/inbox/z.md" | AGENT_MAIL_DIR="$CUSTOM" python3 "$GUARD" 2>/dev/null)"; RC=$?
chk_eq "env-override bus inbox denied (exit 2)" 2 "$RC"
OUT="$(mkp PreToolUse Write "$HOME/.agents/mail/beta/inbox/w.md" | AGENT_MAIL_DIR="$CUSTOM" python3 "$GUARD" 2>/dev/null)"; RC=$?
chk_eq "default-root path allowed when env points elsewhere" 0 "$RC"

# ── degenerate: fail-open ──
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"
out="$(printf 'not json' | python3 "$GUARD")"; rc=$?
chk_eq "garbage stdin exit 0" 0 "$rc"
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{}}' | python3 "$GUARD")"; rc=$?
chk_eq "missing file_path exit 0" 0 "$rc"

summary
