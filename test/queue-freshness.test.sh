#!/usr/bin/env bash
# Test suite for cto-orchestration references/queue-freshness.py
# (SessionStart + UserPromptSubmit hook).
# Hermetic: each case builds a temp project + isolated TMPDIR (rate-limit stamps live in
# tempfile.gettempdir()), feeds stdin JSON, asserts stdout. NOTHING under test is modified.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/cto-orchestration/references/queue-freshness.py"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
assert_empty(){ [ -z "$1" ] && ok || no "$2: expected silence, got: $1"; }

# temp project with stale queue (old) + fresh orchestration activity; echo root
mkproj(){
  local d; d="$(mktemp -d)"
  mkdir -p "$d/docs/orchestration" "$d/tmp"
  printf '# queue\n' > "$d/docs/DECISION_QUEUE.md"
  touch -t 202601010000 "$d/docs/DECISION_QUEUE.md"
  printf '# goal\n' > "$d/docs/orchestration/X_GOAL.md"
  echo "$d"
}
run(){ printf '{"cwd":"%s","hook_event_name":"%s"}' "$1" "${2:-UserPromptSubmit}" | TMPDIR="$1/tmp" "$SCRIPT" 2>&1; }

echo "== queue-freshness.test =="

# A — stale queue vs orchestration activity → emits additionalContext reminder
r="$(mkproj)"; out="$(run "$r")"
assert_has "$out" "additionalContext" "A/stale emits"
assert_has "$out" "UserPromptSubmit" "A/stale event name"
assert_has "$out" "DECISION_QUEUE.md" "A/stale names queue"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok || no "A/stale output is valid JSON"

# B — rate-limit: second call within interval → silent
out2="$(run "$r")"
assert_empty "$out2" "B/rate-limited second call"

# C — fresh queue → silent
r="$(mkproj)"; touch "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"
assert_empty "$out" "C/fresh queue"

# D — project without a queue file → silent (opt-in)
r="$(mktemp -d)"; mkdir -p "$r/docs/orchestration" "$r/tmp"; printf 'g\n' > "$r/docs/orchestration/G.md"
out="$(run "$r")"
assert_empty "$out" "D/no queue"

# E — queue but no orchestration dir → silent (nothing to compare against)
r="$(mktemp -d)"; mkdir -p "$r/docs" "$r/tmp"; printf 'q\n' > "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"
assert_empty "$out" "E/no orchestration activity"

# F — malformed stdin → silent, exit 0 (hook must never break the harness)
out="$(printf 'not json' | TMPDIR="$(mktemp -d)" "$SCRIPT" 2>&1)"; rc=$?
assert_empty "$out" "F/bad stdin silent"
[ "$rc" -eq 0 ] && ok || no "F/bad stdin rc: expected 0 got $rc"

# G — cleared-history residue is surfaced even without orchestration activity
r="$(mktemp -d)"; mkdir -p "$r/docs" "$r/tmp"
printf '# queue\n## ✅ CLEARED（保持为空）\n| D-1 | already decided |\n' > "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"
assert_has "$out" "Treat every one as CLOSED" "G/cleared residue stays closed"
assert_has "$out" "never rehydrate" "G/cleared residue forbids reactivation"

# H — SessionStart always surfaces residue and uses the correct event name (no mid-session throttle)
out="$(run "$r" SessionStart)"
assert_has "$out" '"hookEventName": "SessionStart"' "H/session-start event"
assert_has "$out" "git history is the audit trail" "H/session-start cleanup direction"
out2="$(run "$r" SessionStart)"
assert_has "$out2" "additionalContext" "H/session-start is not rate-limited"

# I — an empty cleared section is clean and silent when the queue is otherwise fresh
r="$(mktemp -d)"; mkdir -p "$r/docs" "$r/tmp"
printf '# queue\n## ✅ CLEARED（保持为空）\n' > "$r/docs/DECISION_QUEUE.md"
out="$(run "$r" SessionStart)"
assert_empty "$out" "I/empty cleared section"

echo "== queue-freshness: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
