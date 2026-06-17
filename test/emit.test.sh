#!/usr/bin/env bash
# emit.sh (shared emitter) + hooks/emit-from-stdin.sh (codex/claude shim).
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

echo "== emit.sh =="

# valid state writes one ISO <STATE> <detail> line.
sandbox_new
AGENT_WATCH_SESSION=s1 bash "$EMIT" WORKING tool-call
events="$WATCH_RUN_DIR/s1.events"
line="$(cat "$events" 2>/dev/null)"
nlines="$(wc -l < "$events" 2>/dev/null | tr -d ' ')"
chk_eq "emit one line" 1 "$nlines"
if printf '%s\n' "$line" | grep -qE "${ISO_RE} WORKING tool-call$"; then _record "emit line format" 1
else _record "emit line format" 0 "got[$line]"; fi
sandbox_clean

# invalid state -> no-op (exit 0, no file).
sandbox_new
AGENT_WATCH_SESSION=s2 bash "$EMIT" BOGUS detail; rc=$?
chk_eq "emit bad-state rc0" 0 "$rc"
if [ -f "$WATCH_RUN_DIR/s2.events" ]; then _record "emit bad-state no file" 0 "file created"; else _record "emit bad-state no file" 1; fi
sandbox_clean

# no session bound -> silent no-op even for valid state.
sandbox_new
( unset AGENT_WATCH_SESSION; bash "$EMIT" DONE x ); rc=$?
chk_eq "emit no-session rc0" 0 "$rc"
# nothing should be written for any session
cnt="$(ls "$WATCH_RUN_DIR"/*.events 2>/dev/null | wc -l | tr -d ' ')"
chk_eq "emit no-session no file" 0 "$cnt"
sandbox_clean

# appends (does not clobber) across calls.
sandbox_new
AGENT_WATCH_SESSION=s3 bash "$EMIT" WORKING a
AGENT_WATCH_SESSION=s3 bash "$EMIT" DONE b
n="$(wc -l < "$WATCH_RUN_DIR/s3.events" | tr -d ' ')"
chk_eq "emit appends" 2 "$n"
last="$(tail -1 "$WATCH_RUN_DIR/s3.events" | awk '{print $2}')"
chk_eq "emit last state" "DONE" "$last"
sandbox_clean

echo "== emit-from-stdin.sh (codex/claude shim) =="
# The shim drains stdin (JSON payload) and emits the STATE passed as $1 by the hook
# REGISTRATION. Per README adapter table the registration arg is fixed per event:
#   codex:  PreToolUse->WORKING, PermissionRequest->WAITING, Stop->DONE
#   claude: PostToolUse->WORKING, Notification(permission)->WAITING, Notification(idle)/Stop->DONE
# So the shim's job = drain JSON, forward $1. We pipe representative JSON and assert
# the emitted STATE matches the registration arg.

shim_case() { # $1 label  $2 state-arg  $3 detail-arg  $4 json-on-stdin  $5 sess
  printf '%s' "$4" | AGENT_WATCH_SESSION="$5" bash "$EMIT_STDIN" "$2" "$3"
  local got; got="$(tail -1 "$WATCH_RUN_DIR/$5.events" 2>/dev/null | awk '{print $2}')"
  chk_eq "$1 -> $2" "$2" "$got"
}

sandbox_new
shim_case "codex PreToolUse"        WORKING tool  '{"hook_event_name":"PreToolUse","tool_name":"shell"}'      cdx
shim_case "codex PermissionRequest" WAITING perm  '{"hook_event_name":"PermissionRequest"}'                   cdx
shim_case "codex Stop"              DONE    stop  '{"hook_event_name":"Stop"}'                                 cdx
shim_case "claude PostToolUse"      WORKING tool  '{"hook_event_name":"PostToolUse","tool_name":"Edit"}'       cld
shim_case "claude Notif permission" WAITING perm  '{"notification_type":"permission_prompt"}'                  cld
shim_case "claude Notif idle"       DONE    idle  '{"notification_type":"idle_prompt"}'                        cld
shim_case "claude Stop"             DONE    stop  '{"hook_event_name":"Stop"}'                                 cld
# shim drains stdin without requiring jq / blocking
chk_eq "shim drains+emits cdx count" 3 "$(wc -l < "$WATCH_RUN_DIR/cdx.events" | tr -d ' ')"
chk_eq "shim drains+emits cld count" 4 "$(wc -l < "$WATCH_RUN_DIR/cld.events" | tr -d ' ')"
sandbox_clean

summary
