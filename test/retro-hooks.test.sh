#!/usr/bin/env bash
# retro-hooks contract: the reminder script must emit ONLY schema-valid shapes per event.
# Pinned failure: a PreCompact hook that emits hookSpecificOutput.additionalContext is
# rejected wholesale by the harness validator (2026-07-28 live) — the reminder silently
# never fires. PreCompact may only carry top-level systemMessage; model-context injection
# belongs to SessionStart(source=compact).
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

echo "== retro-reminder: PreCompact = systemMessage only =="
out="$(printf '{"hook_event_name":"PreCompact","trigger":"auto"}' | bash "$SH")"; rc=$?
chk_eq "PreCompact exits 0" 0 "$rc"
chk_has "PreCompact carries user-visible systemMessage" '"systemMessage"' "$out"
chk_not "PreCompact never emits additionalContext (schema-rejected shape)" 'additionalContext' "$out"
json_ok "PreCompact output is valid JSON" "$out"

echo "== retro-reminder: SessionStart injects only after compact =="
out="$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | bash "$SH")"; rc=$?
chk_eq "SessionStart(compact) exits 0" 0 "$rc"
chk_has "SessionStart(compact) injects model context" '"additionalContext"' "$out"
chk_has "SessionStart(compact) declares its event name" '"hookEventName":"SessionStart"' "$out"
chk_has "reminder routes to the seven-step checklist" 'retrospective.md' "$out"
chk_has "reminder routes to the hard gate" 'retro-check.sh' "$out"
json_ok "SessionStart(compact) output is valid JSON" "$out"
out="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$SH")"; rc=$?
chk_eq "SessionStart(startup) stays silent, exit 0" "0|" "$rc|$out"
out="$(printf '{"hook_event_name":"SessionStart","source":"compact","meta":{"source":"startup"}}' | bash "$SH")"; rc=$?
chk_has "duplicated nested source key cannot silence the reminder (F8)" '"additionalContext"' "$out"
out="$(printf '' | bash "$SH")"; rc=$?
chk_eq "empty stdin stays silent, exit 0" "0|" "$rc|$out"

echo "== wiring truth-source =="
json_ok "retro-hooks.json is valid JSON" "$(cat "$WIRE")"
chk_has "wiring points both events at the reminder script" 'retro-reminder.sh' "$(cat "$WIRE")"
chk_has "wiring covers PreCompact" '"PreCompact"' "$(cat "$WIRE")"
chk_has "wiring covers SessionStart" '"SessionStart"' "$(cat "$WIRE")"
chk_eq "reminder script is executable" 1 "$([ -x "$SH" ] && echo 1 || echo 0)"

echo "-- $pass passed, $fail failed --"
[ "$fail" -eq 0 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
