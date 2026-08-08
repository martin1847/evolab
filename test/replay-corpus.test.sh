#!/usr/bin/env bash
# Real-stream replay gate wrapper. Two duties:
#   1. self-proof: the driver must go RED on a known-bad synthetic stream and GREEN
#      on a known-good one (a gate that cannot go red proves nothing);
#   2. corpus sweep: every real stream in test/corpus/ (gitignored, local-only —
#      real events may carry sensitive content) must hold the terminal-verdict
#      invariants. Empty/absent corpus is a SKIP, not a failure: CI and fresh
#      clones carry no corpus by design.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DRIVER="./replay-corpus.py"
echo "== replay-corpus =="

sandbox_new

# known-bad: a result with NO pending-task accounting, then a harness-automatic
# continuation (task_notification before the next init) — the projection reads IDLE
# at that prefix, which is exactly the false-DONE window the gate must flag
cat > "$SANDBOX/bad.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}
{"type":"result","is_error":false,"result":"turn done"}
{"type":"system","subtype":"task_notification","task_id":"t9","status":"completed"}
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"text","text":"continued"}]}}
{"type":"result","is_error":false,"result":"final"}
EOF
out="$(python3 "$DRIVER" "$SANDBOX/bad.jsonl" 2>&1)"; rc=$?
chk_eq "known-bad stream goes RED" 1 "$rc"
chk_contains "violation names the false-DONE window" "false-DONE window" "$out"

# known-good: pending accounting keeps the gap RUNNING; the final result (tasks
# retired, EOF) stays IDLE so DONE remains reachable
cat > "$SANDBOX/good.jsonl" <<'EOF'
{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","description":"gate"}]}
{"type":"result","is_error":false,"result":"turn done"}
{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"completed"}}
{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed"}
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"text","text":"continued"}]}}
{"type":"result","is_error":false,"result":"final"}
EOF
out="$(python3 "$DRIVER" "$SANDBOX/good.jsonl" 2>&1)"; rc=$?
chk_eq "known-good stream stays GREEN" 0 "$rc"

# non-claude stream is skipped, never judged
printf '{"method":"turn/completed","params":{"turn":{"id":"t"}}}\n' > "$SANDBOX/codex.jsonl"
out="$(python3 "$DRIVER" "$SANDBOX/codex.jsonl" 2>&1)"; rc=$?
chk_eq "non-claude stream skips green" 0 "$rc"
chk_contains "skip is said out loud" "[skip]" "$out"

# corpus sweep (local-only)
corpus_found=0
for f in ./corpus/*.jsonl; do
  [ -e "$f" ] || continue
  corpus_found=1
  out="$(python3 "$DRIVER" "$f" 2>&1)"; rc=$?
  chk_eq "corpus green: $(basename "$f")" 0 "$rc"
done
[ "$corpus_found" = 0 ] && echo "  [skip] no corpus files (test/corpus/ is local-only by design)"

rm -rf "$SANDBOX"
summary
