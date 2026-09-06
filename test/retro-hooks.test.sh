#!/usr/bin/env bash
# retro-hooks contract: the reminder script must emit ONLY schema-valid shapes per event, and
# ONLY while this repo is being orchestrated.
# Pinned failure: a PreCompact hook that emits hookSpecificOutput.additionalContext is
# rejected wholesale by the harness validator (2026-07-28 live) — the reminder silently
# never fires. PreCompact may only carry top-level systemMessage; model-context injection
# belongs to SessionStart(source=compact).
# Pinned failure 2 (audit §3, 2026-09-06): the wiring is GLOBAL (~/.claude/settings.json), so
# every compaction of every session — single-agent debugging included — was pushed into the
# seven-step retro. The payload `cwd` now decides, through the same predicate E1 and the Stop
# gate consult, and a repo nobody is orchestrating gets NO output at all (not a shorter one).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/../skills/cto-orchestration/references/retro-reminder.sh"
WIRE="$HERE/../skills/cto-orchestration/references/retro-hooks.json"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL $1"; fail=$((fail+1)); }
chk_eq(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want=$2 got=$3)"; }
chk_has(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1";; esac; }
chk_not(){ case "$3" in *"$2"*) bad "$1";; *) ok "$1";; esac; }
json_ok(){ printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok "$1" || bad "$1"; }

# A missing tool is a VERIFICATION FAILURE, never a green skip: the predicate under test
# compares git common dirs, so without git this suite proves nothing — and an `exit 0` here
# reported "23 passed" for zero assertions executed (review N1).
if ! command -v git >/dev/null 2>&1; then
  bad "REQUIRED TOOL MISSING: git is not on PATH — the orchestration predicate compares git \
common dirs, so none of the assertions below can be judged"
  echo "-- $pass passed, $fail failed --"; echo FAIL; exit 1
fi

# THE PREMISE: a run dir whose today-shard names $ORCH as an orchestrated work tree, and a
# second checkout with no record at all. Both are real git repos — the predicate compares git
# COMMON DIRS, so a fake directory would answer "undecidable" and prove nothing.
FIX="$(mktemp -d /tmp/retrohooks.XXXXXX)"
trap 'rm -rf "$FIX"' EXIT
RUN="$FIX/run"; ORCH="$FIX/orch"; PLAIN="$FIX/plain"
mkdir -p "$RUN" "$ORCH" "$PLAIN"
git -C "$ORCH" init -q; git -C "$PLAIN" init -q
python3 -c 'import json, os, sys
print(json.dumps({"ts": "2026-09-06T00:00:00.000Z", "event": "start", "name": "fixture",
                  "session_id": "s", "attempt": "a", "cwd": os.path.realpath(sys.argv[1])}))' \
  "$ORCH" > "$RUN/phase-ledger-$(date -u +%Y%m%d).jsonl"
export AGENT_WATCH_DIR="$RUN"
payload() { # $1 event  $2 source-or-trigger  $3 cwd ("-" omits it)
  python3 -c 'import json, sys
d = {"hook_event_name": sys.argv[1]}
d["source" if sys.argv[1] == "SessionStart" else "trigger"] = sys.argv[2]
if sys.argv[3] != "-": d["cwd"] = sys.argv[3]
print(json.dumps(d))' "$1" "$2" "$3"
}

echo "== retro-reminder: PreCompact = systemMessage only =="
out="$(payload PreCompact auto "$ORCH" | bash "$SH")"; rc=$?
chk_eq "PreCompact exits 0" 0 "$rc"
chk_has "PreCompact carries user-visible systemMessage" '"systemMessage"' "$out"
chk_not "PreCompact never emits additionalContext (schema-rejected shape)" 'additionalContext' "$out"
json_ok "PreCompact output is valid JSON" "$out"

echo "== retro-reminder: SessionStart injects only after compact =="
out="$(payload SessionStart compact "$ORCH" | bash "$SH")"; rc=$?
chk_eq "SessionStart(compact) exits 0" 0 "$rc"
chk_has "SessionStart(compact) injects model context" '"additionalContext"' "$out"
chk_has "SessionStart(compact) declares its event name" '"hookEventName":"SessionStart"' "$out"
chk_has "reminder routes to the seven-step checklist" 'retrospective.md' "$out"
chk_has "reminder routes to the hard gate" 'retro-check.sh' "$out"
json_ok "SessionStart(compact) output is valid JSON" "$out"
out="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$SH")"; rc=$?
chk_eq "SessionStart(startup) stays silent, exit 0" "0|" "$rc|$out"
out="$(printf '{"hook_event_name":"SessionStart","source":"compact","cwd":"%s","meta":{"source":"startup"}}' "$ORCH" | bash "$SH")"; rc=$?
chk_has "duplicated nested source key cannot silence the reminder (F8)" '"additionalContext"' "$out"
out="$(printf '' | bash "$SH")"; rc=$?
chk_eq "empty stdin stays silent, exit 0" "0|" "$rc|$out"

echo "== retro-reminder: only a repo that IS being orchestrated is spoken to =="
out="$(payload SessionStart compact "$PLAIN" | bash "$SH")"; rc=$?
chk_eq "r1 compact in a repo nobody orchestrates emits NOTHING, exit 0" "0|" "$rc|$out"
out="$(payload SessionStart compact "$ORCH" | bash "$SH")"; rc=$?
chk_has "r2 PAIRED GREEN: the same event in an orchestrated repo still injects" \
  '"additionalContext"' "$out"
out="$(payload PreCompact auto "$PLAIN" | bash "$SH")"; rc=$?
chk_eq "r3 PreCompact in a repo nobody orchestrates emits NOTHING, exit 0" "0|" "$rc|$out"
out="$(payload PreCompact auto - | bash "$SH")"; rc=$?
chk_eq "r4 a payload with no cwd emits NOTHING, exit 0" "0|" "$rc|$out"
# and the probe must never reach for the runtime: a reminder that shelled out to agentctl would
# pay a status call (which publishes an idle conclusion) on every compaction
chk_not "the reminder invokes no agentctl verb" 'agentctl ' "$(cat "$SH")"

echo "== wiring truth-source =="
json_ok "retro-hooks.json is valid JSON" "$(cat "$WIRE")"
chk_has "wiring points both events at the reminder script" 'retro-reminder.sh' "$(cat "$WIRE")"
chk_has "wiring covers PreCompact" '"PreCompact"' "$(cat "$WIRE")"
chk_has "wiring covers SessionStart" '"SessionStart"' "$(cat "$WIRE")"
chk_eq "reminder script is executable" 1 "$([ -x "$SH" ] && echo 1 || echo 0)"

echo "-- $pass passed, $fail failed --"
[ "$fail" -eq 0 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
