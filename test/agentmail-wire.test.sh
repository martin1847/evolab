#!/usr/bin/env bash
# agentmail wire — idempotent hook wiring with the level decision in code (条件先于动作:
# two live onboard incidents came from the same decision living in prose). Hermetic: every
# invocation pins HOME into a fixture so the real ~/.claude is never read or written.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AM="../skills/agent-mail/agentmail"
SELF_DIR="$(cd ../skills/agent-mail && pwd -P)"

echo "== agentmail wire =="

FIX="$(mktemp -d /tmp/am-wire.XXXXXX)"
trap 'rm -rf "$FIX"' EXIT

jq_get() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@"; }

# 1. fresh HOME → wires user level with all truth-source entries, absolute commands
H1="$FIX/h1"; mkdir -p "$H1"
out="$(HOME="$H1" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "fresh HOME wires user level (exit 0)" 0 "$rc"
chk_contains "reports user level target" "user level" "$out"
S1="$H1/.claude/settings.json"
chk_eq "settings created" 1 "$([ -f "$S1" ] && echo 1 || echo 0)"
chk_eq "SessionStart wired" "$SELF_DIR/mail-check.py" \
  "$(jq_get "$S1" 'c["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"
chk_eq "UserPromptSubmit wired" "$SELF_DIR/mail-check.py" \
  "$(jq_get "$S1" 'c["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]')"
chk_eq "PreToolUse guard wired with matcher" "Write|Edit|MultiEdit" \
  "$(jq_get "$S1" 'c["hooks"]["PreToolUse"][0]["matcher"]')"
chk_eq "no interpreter prefix / absolute path" 0 "$(grep -c 'python3 /' "$S1" || true)"

# 2. rerun → idempotent no-op, file byte-identical
before="$(cat "$S1")"
out="$(HOME="$H1" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "rerun exits 0" 0 "$rc"
chk_contains "rerun reports nothing to do" "nothing to do" "$out"
chk_eq "rerun leaves file byte-identical" "$before" "$(cat "$S1")"

# 3. user wired + --project → refuse (duplicate = double bubbling)
P3="$FIX/proj3"; mkdir -p "$P3"
out="$(HOME="$H1" bash "$AM" wire --project "$P3" 2>&1)"; rc=$?
chk_eq "project request on wired user level refused" 1 "$rc"
chk_contains "refusal explains double-report" "double-report" "$out"
chk_eq "refusal wrote nothing into project" 0 "$([ -e "$P3/.claude/settings.json" ] && echo 1 || echo 0)"

# 4. fresh HOME + --project → wires project, user stays untouched
H4="$FIX/h4"; P4="$FIX/proj4"; mkdir -p "$H4" "$P4"
out="$(HOME="$H4" bash "$AM" wire --project "$P4" 2>&1)"; rc=$?
chk_eq "fresh HOME + --project exits 0" 0 "$rc"
chk_contains "reports project level" "project level" "$out"
chk_eq "project settings created" 1 "$([ -f "$P4/.claude/settings.json" ] && echo 1 || echo 0)"
chk_eq "user settings untouched" 0 "$([ -e "$H4/.claude/settings.json" ] && echo 1 || echo 0)"

# 5. partial wiring + unrelated keys → completes missing entries, preserves both
H5="$FIX/h5"; mkdir -p "$H5/.claude"
printf '{"model":"keep-me","hooks":{"PreToolUse":[{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"%s/mail-guard.py"}]}]}}\n' "$SELF_DIR" > "$H5/.claude/settings.json"
out="$(HOME="$H5" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "partial wiring completes (exit 0)" 0 "$rc"
chk_contains "existing guard reported present" "already present" "$out"
chk_eq "unrelated key preserved" "keep-me" "$(jq_get "$H5/.claude/settings.json" 'c["model"]')"
chk_eq "mail-check completed at user level" "$SELF_DIR/mail-check.py" \
  "$(jq_get "$H5/.claude/settings.json" 'c["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"
chk_eq "guard not duplicated" 1 "$(jq_get "$H5/.claude/settings.json" 'len(c["hooks"]["PreToolUse"])')"
chk_eq "backup of prior settings kept" 1 "$(ls "$H5/.claude/settings.json.bak-"* >/dev/null 2>&1 && echo 1 || echo 0)"

# 6. malformed settings → refuse, never clobber
H6="$FIX/h6"; mkdir -p "$H6/.claude"
printf 'not json' > "$H6/.claude/settings.json"
out="$(HOME="$H6" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "malformed settings refused" 1 "$rc"
chk_contains "refusal names the file" "settings.json" "$out"
chk_eq "malformed file untouched" "not json" "$(cat "$H6/.claude/settings.json")"

# 7. relative --project → refuse before touching anything
out="$(HOME="$FIX/h4" bash "$AM" wire --project relative/path 2>&1)"; rc=$?
chk_eq "relative project path refused" 1 "$rc"
chk_contains "refusal says absolute" "absolute" "$out"

# 8. project prewired from ANOTHER install root → recognized as wired, no duplicate handler (review M1)
H8="$FIX/h8"; P8="$FIX/proj8"; mkdir -p "$H8" "$P8/.claude"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/old/install/agent-mail/mail-check.py"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/old/install/agent-mail/mail-check.py"}]}],"PreToolUse":[{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"/old/install/agent-mail/mail-guard.py"}]}]}}\n' > "$P8/.claude/settings.json"
out="$(HOME="$H8" bash "$AM" wire --project "$P8" 2>&1)"; rc=$?
chk_eq "prewired project is a no-op (exit 0)" 0 "$rc"
chk_contains "prewired project reports nothing to do" "nothing to do" "$out"
chk_eq "no duplicate SessionStart handler added" 1 "$(jq_get "$P8/.claude/settings.json" 'len(c["hooks"]["SessionStart"])')"

# 9. substring lookalike must NOT flip the level decision (review M3)
H9="$FIX/h9"; P9="$FIX/proj9"; mkdir -p "$H9/.claude" "$P9"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/opt/unrelated/not-mail-check.py-wrapper"}]}]}}\n' > "$H9/.claude/settings.json"
out="$(HOME="$H9" bash "$AM" wire --project "$P9" 2>&1)"; rc=$?
chk_eq "lookalike command does not fake user-level wiring" 0 "$rc"
chk_eq "isolated project wiring proceeds" 1 "$([ -f "$P9/.claude/settings.json" ] && echo 1 || echo 0)"

# 10. pre-planted settings.json.tmp symlink must not be followed or clobber its target (review M2)
H10="$FIX/h10"; mkdir -p "$H10/.claude"
printf 'DO-NOT-TOUCH' > "$FIX/victim"
ln -s "$FIX/victim" "$H10/.claude/settings.json.tmp"
out="$(HOME="$H10" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "wire succeeds despite planted tmp symlink" 0 "$rc"
chk_eq "victim untouched" "DO-NOT-TOUCH" "$(cat "$FIX/victim")"
chk_eq "settings.json is a regular file, not the symlink" 0 "$([ -L "$H10/.claude/settings.json" ] && echo 1 || echo 0)"

# 11. surplus argument after --project pair → refuse (review m2)
out="$(HOME="$FIX/h4" bash "$AM" wire --project "$FIX/proj4" extra 2>&1)"; rc=$?
chk_eq "surplus wire argument refused" 1 "$rc"
chk_contains "surplus refusal names the argument" "extra" "$out"

# 12. same basename, UNRELATED tool → must not flip the level decision nor count as present (review R2)
H12="$FIX/h12"; P12="$FIX/proj12"; mkdir -p "$H12/.claude" "$P12"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/calendar/mail-check.py"}]}]}}\n' > "$H12/.claude/settings.json"
out="$(HOME="$H12" bash "$AM" wire --project "$P12" 2>&1)"; rc=$?
chk_eq "unrelated same-name tool does not fake user wiring" 0 "$rc"
chk_eq "isolated project wiring proceeds beside it" 1 "$([ -f "$P12/.claude/settings.json" ] && echo 1 || echo 0)"
H12b="$FIX/h12b"; mkdir -p "$H12b/.claude"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/calendar/mail-check.py"}]}]}}\n' > "$H12b/.claude/settings.json"
out="$(HOME="$H12b" bash "$AM" wire 2>&1)"; rc=$?
chk_eq "user wiring proceeds beside unrelated same-name tool" 0 "$rc"
chk_eq "our mail-check added, not treated as present" 2 "$(jq_get "$H12b/.claude/settings.json" 'len(c["hooks"]["SessionStart"])')"

# 13. invoked via a PATH symlink (mail-check.py's ~/.local/bin convenience install) → hooks.json
# must resolve beside the REAL script, not the symlink ($0 has to follow the link chain)
H13="$FIX/h13"; B13="$FIX/bin13"; mkdir -p "$H13" "$B13"
ln -s "$SELF_DIR/agentmail" "$B13/agentmail"
out="$(HOME="$H13" "$B13/agentmail" wire 2>&1)"; rc=$?
chk_eq "symlinked invocation wires (exit 0)" 0 "$rc"
chk_eq "commands resolve beside the real script, not the symlink" "$SELF_DIR/mail-check.py" \
  "$(jq_get "$H13/.claude/settings.json" 'c["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"

summary
