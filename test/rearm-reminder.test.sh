#!/usr/bin/env bash
# Claude lifecycle reminder: only actionable rearm output reaches context, always as fixed prose.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SRC="../skills/cto-orchestration/references/agent-watch/rearm-reminder.py"
WATCH_HOOKS="../skills/cto-orchestration/references/agent-watch/watch-hooks.json"
GUARD_HOOKS="../skills/cto-orchestration/references/agent-watch/guard-hooks.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/rearm-reminder.py"
chmod +x "$TMP/rearm-reminder.py"
cat > "$TMP/rearm" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_REARM_MODE:-silent}" in
  silent) printf '# nothing to re-arm\n  # comment only\n\n' ;;
  actionable)
    printf '# active session /tmp/private-session has no watcher\n'
    printf 'bash /tmp/private/watch private-session\n'
    ;;
  error) printf 'raw /tmp/private-session diagnostic\n' >&2; exit 7 ;;
esac
EOF
chmod +x "$TMP/rearm"

run_hook() { # $1 mode $2 event
  printf '{"hook_event_name":"%s"}' "$2" | FAKE_REARM_MODE="$1" "$TMP/rearm-reminder.py"
}

echo "== rearm reminder hook =="

out="$(run_hook silent SessionStart 2>&1)"; rc=$?
chk_eq "comment-only scan is silent" "" "$out"
chk_eq "comment-only scan exits zero" 0 "$rc"

out="$(run_hook actionable SessionStart 2>&1)"; rc=$?
chk_eq "actionable scan exits zero" 0 "$rc"
chk_contains "actionable scan emits context" "additionalContext" "$out"
chk_contains "SessionStart event is preserved" '"hookEventName": "SessionStart"' "$out"
chk_not_contains "context omits raw tmp path" "/tmp/private" "$out"
chk_not_contains "context omits raw session" "private-session" "$out"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
chk_eq "actionable output is valid JSON" 0 "$?"

out="$(run_hook actionable UserPromptSubmit 2>&1)"
chk_contains "UserPromptSubmit event is preserved" '"hookEventName": "UserPromptSubmit"' "$out"

stdout="$TMP/error.out"; stderr="$TMP/error.err"
printf '{"hook_event_name":"SessionStart"}' \
  | FAKE_REARM_MODE=error "$TMP/rearm-reminder.py" > "$stdout" 2> "$stderr"; rc=$?
chk_eq "check error is reminder-only rc0" 0 "$rc"
chk_eq "check error injects no context" "" "$(cat "$stdout")"
chk_contains "check error is honest" "CHECKER-ERROR" "$(cat "$stderr")"
chk_not_contains "check error hides raw diagnostics" "/tmp/private" "$(cat "$stderr")"

printf 'not-json' | "$TMP/rearm-reminder.py" > "$stdout" 2> "$stderr"; rc=$?
chk_eq "parse error is reminder-only rc0" 0 "$rc"
chk_eq "parse error injects no context" "" "$(cat "$stdout")"
chk_contains "parse error is honest" "CHECKER-ERROR" "$(cat "$stderr")"

python3 -c '
import json, sys
watch = json.load(open(sys.argv[1]))
guard = json.load(open(sys.argv[2]))
assert set(watch) == {"//", "SessionStart", "UserPromptSubmit"}
assert "SessionStart" not in guard and "UserPromptSubmit" not in guard
assert all(row == {"command": "references/agent-watch/rearm-reminder.py"}
           for event in ("SessionStart", "UserPromptSubmit") for row in watch[event])
' "$WATCH_HOOKS" "$GUARD_HOOKS"
chk_eq "Claude-only truth source is isolated from shared guards" 0 "$?"

summary
