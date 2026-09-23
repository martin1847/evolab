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
# Third branch (2026-09-23): SessionStart source=startup|clear emits the handoff-snapshot pointer.
# Its predicate is deliberately ONLY "the repo root of payload cwd has docs/ACTIVE_CONTEXT.md" —
# NOT the orchestration predicate above, because right after a session switch there is usually no
# LIVE seat yet and an AND would go silent exactly when continuity matters most. Asserted below by
# firing it in a repo nobody orchestrates, and by pinning the two older branches byte-for-byte.
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

echo "== retro-reminder: SessionStart(startup|clear) = 交接快照开场指针 =="
# POINT 是一个**没人编排**的仓（run dir 里没有它的 start 行）：指针在这里必须照样说话——这就是
# 「不叠加被编排谓词」的行为证明，换会话后往往还没有 LIVE 席位。
POINT="$FIX/point"; mkdir -p "$POINT/docs" "$POINT/sub/deeper"
git -C "$POINT" init -q
printf '# 驾驶舱\n\nLast rewritten: 2026-01-02\n' > "$POINT/docs/ACTIVE_CONTEXT.md"
out="$(payload SessionStart startup "$POINT" | bash "$SH")"; rc=$?
chk_eq "p1 startup 指针 exits 0" 0 "$rc"
chk_eq "p1 指针恰一行" 1 "$(printf '%s\n' "$out" | grep -c .)"
chk_has "p1 指针指向交接快照本身" 'docs/ACTIVE_CONTEXT.md' "$out"
chk_has "p1 指针带快照日期（让模型自判新旧）" '2026-01-02' "$out"
chk_has "p1 指针声明事件名" '"hookEventName":"SessionStart"' "$out"
chk_not "p1 指针不抢用户可见通道" 'systemMessage' "$out"
json_ok "p1 指针输出是合法 JSON" "$out"
out="$(payload SessionStart clear "$POINT" | bash "$SH")"; rc=$?
chk_has "p2 /clear 同形一行" 'ACTIVE_CONTEXT.md' "$out"
out="$(payload SessionStart resume "$POINT" | bash "$SH")"; rc=$?
chk_eq "p3 resume 不是新开场，零字节" "0|" "$rc|$out"
out="$(payload SessionStart startup "$PLAIN" | bash "$SH")"; rc=$?
chk_eq "p4 PAIRED NEGATIVE：同事件、仓里没有快照 ⇒ 零字节" "0|" "$rc|$out"
out="$(payload SessionStart startup "$POINT/sub/deeper" | bash "$SH")"; rc=$?
chk_has "p5 子目录 cwd 仍命中（谓词找的是仓根）" '2026-01-02' "$out"
POINT2="$FIX/point2"; mkdir -p "$POINT2/docs"; git -C "$POINT2" init -q
printf '# 驾驶舱\n\n没有日期行\n' > "$POINT2/docs/ACTIVE_CONTEXT.md"
touch -t 202602031200 "$POINT2/docs/ACTIVE_CONTEXT.md"
out="$(payload SessionStart startup "$POINT2" | bash "$SH")"; rc=$?
chk_has "p6 没有 Last rewritten 行就退到文件 mtime" '2026-02-03' "$out"
out="$(printf '{"hook_event_name":"UserPromptSubmit","source":"startup","cwd":"%s"}' "$POINT" \
  | bash "$SH")"; rc=$?
chk_eq "p7 指针只在 SessionStart 说话（同 source 同 cwd 的别的事件零字节）" "0|" "$rc|$out"

echo "== retro-reminder: 既有 compact / PreCompact 输出逐字节不变 =="
# 对照 = 本批之前的脚本，钉 SHA（不用 origin/main 这种会动的参照物）。它按 dirname "$0"/agentctl 找
# identity，所以要导出到一个带 agentctl 兄弟目录的临时目录——孤零零一个文件是另一个程序（导出法同
# cto-guard-bash.test.sh 的 E13）。
BASE_REV="d6e03ef853e586a0a5c3522f76f8dff27d3025f2"
BASE_DIR="$FIX/base"; mkdir -p "$BASE_DIR"
cp -R "$HERE/../skills/cto-orchestration/references/agentctl" "$BASE_DIR/agentctl"
git -C "$HERE/.." show "$BASE_REV:skills/cto-orchestration/references/retro-reminder.sh" \
  > "$BASE_DIR/retro-reminder.sh" 2>/dev/null
BASE="$BASE_DIR/retro-reminder.sh"
chk_eq "b0 control: 导出的对照确实早于本批（没有开场指针）" 0 \
  "$(grep -c 'ACTIVE_CONTEXT' "$BASE" 2>/dev/null || true)"
cmp_case() { # $1 event  $2 source  $3 cwd  $4 label — 原始字节，不过命令替换（会吃掉尾换行）
  pl="$(payload "$1" "$2" "$3")"
  pfx="$FIX/cmp-$4"
  printf '%s' "$pl" | bash "$BASE" >"$pfx.base.out" 2>"$pfx.base.err"; echo $? >"$pfx.base.rc"
  printf '%s' "$pl" | bash "$SH"   >"$pfx.new.out"  2>"$pfx.new.err";  echo $? >"$pfx.new.rc"
  for part in out err rc; do
    if cmp -s "$pfx.base.$part" "$pfx.new.$part"; then
      ok "b $4 $part 与 $BASE_REV 逐字节相同"
    else
      bad "b $4 $part 与 $BASE_REV 不同"
    fi
  done
}
cmp_case SessionStart compact "$ORCH" compact-orch
cmp_case SessionStart compact "$PLAIN" compact-plain
cmp_case PreCompact auto "$ORCH" precompact-orch
# 空对空不算绿：两个本该说话的旧输出先证非空（对照若因缺 identity 整体失效，cmp 会假绿）
chk_eq "b control: 对照在 compact/被编排仓确实有输出" 1 \
  "$([ -s "$FIX/cmp-compact-orch.base.out" ] && echo 1 || echo 0)"
chk_eq "b control: 对照在 PreCompact 确实有输出" 1 \
  "$([ -s "$FIX/cmp-precompact-orch.base.out" ] && echo 1 || echo 0)"

echo "== wiring truth-source =="
json_ok "retro-hooks.json is valid JSON" "$(cat "$WIRE")"
chk_has "wiring points both events at the reminder script" 'retro-reminder.sh' "$(cat "$WIRE")"
chk_has "wiring covers PreCompact" '"PreCompact"' "$(cat "$WIRE")"
chk_has "wiring covers SessionStart" '"SessionStart"' "$(cat "$WIRE")"
chk_eq "reminder script is executable" 1 "$([ -x "$SH" ] && echo 1 || echo 0)"

echo "-- $pass passed, $fail failed --"
[ "$fail" -eq 0 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
