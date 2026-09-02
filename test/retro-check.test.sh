#!/usr/bin/env bash
# Test suite for cto-orchestration references/retro-check.sh (复盘机械门与 warning).
# Hermetic: each case builds a temp git repo + bare origin + docs fixtures, runs
# the gate, asserts exit code + key output lines. NOTHING under test is modified.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/cto-orchestration/references/retro-check.sh"
TODAY="$(date +%F)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
assert_no(){ printf '%s' "$1" | grep -qF "$2" && no "$3: output should NOT have '$2'" || ok; }

# build a temp repo (work + bare origin) with green docs fixtures; echo work path
mkrepo(){
  local d work; d="$(mktemp -d)"; work="$d/work"
  git init -q -b main "$work" >/dev/null
  ( cd "$work"
    git config user.email t@t; git config user.name t
    mkdir -p docs/roadmap
    printf 'Last rewritten: %s\n' "$TODAY" > docs/ACTIVE_CONTEXT.md
    printf '# active roadmap\n' > docs/roadmap/active-roadmap.md
    # check 9's ledger: the repo's AGENTS.md. The green fixture carries ONE billed 批 entry of
    # this cycle, so every case that does not touch it exercises check 9's pass path rather
    # than its absence path (an absent ledger is a FAIL — see case TL3).
    printf '# agents\n- 批 %s hermetic-fixture：绿基线 wall=10m avoidable=0m\n' "$TODAY" > AGENTS.md
    printf 'a\nb\nc\n' > MEMORY.md
    git add -A; git commit -qm init
    git clone -q --bare "$work" "$d/origin.git"
    git remote add origin "$d/origin.git"; git push -q origin main
  )
  echo "$work"
}
# AGENT_WATCH_DIR points at a nonexistent dir so check 6 skips — cases that exercise
# it seed their own dir (the real /tmp run dir would leak machine state into cases).
run(){ ( cd "$1" && AGENT_WATCH_DIR="$1/.no-agent-watch" bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 ); }

echo "== retro-check.test =="

# Case A — all green → exit 0, no FAIL
r="$(mkrepo)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "A/all-green rc"
assert_has "$out" "0 FAIL" "A/all-green result"
assert_no  "$out" "[FAIL]" "A/all-green no fail lines"

# Case B — stale ACTIVE_CONTEXT → FAIL, exit non-zero
r="$(mkrepo)"; printf 'Last rewritten: 2020-01-01\n' > "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "B/stale-AC rc"
assert_has "$out" "ACTIVE_CONTEXT" "B/stale-AC names AC"
assert_has "$out" "stale" "B/stale-AC flags stale"

# Case C — stray worktree on MERGED branch → FAIL, exit non-zero
r="$(mkrepo)"
( cd "$r"
  git checkout -q -b feat; printf 'x\n' > f.txt; git add -A; git commit -qm feat
  git checkout -q main; git merge -q --no-edit feat; git push -q origin main
  git worktree add -q "$r-wt-feat" feat ) >/dev/null 2>&1
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "C/stray-worktree rc"
assert_has "$out" "stray worktree on MERGED" "C/stray-worktree flagged"

# Case D — MEMORY over cap → warn only (not FAIL), exit 0
r="$(mkrepo)"; seq 100 > "$r/MEMORY.md"
out="$( cd "$r" && bash "$SCRIPT" --base main --docs docs --memory MEMORY.md --memory-cap 45 2>&1 )"; rc=$?
assert_rc "$rc" 0 "D/mem-overcap rc (warn≠fail)"
assert_has "$out" "[warn]" "D/mem-overcap warns"
assert_has "$out" "> 45" "D/mem-overcap shows cap"

# Case E — missing ACTIVE_CONTEXT → FAIL
r="$(mkrepo)"; rm "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "E/missing-AC rc"
assert_has "$out" "not found" "E/missing-AC flagged"

# Case F — DECISION_QUEUE.md present but stale → warn only (opt-in soft check), exit 0
r="$(mkrepo)"; printf '# queue\n' > "$r/docs/DECISION_QUEUE.md"; touch -t 202001010000 "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "F/stale-queue rc (warn≠fail)"
assert_has "$out" "DECISION_QUEUE.md not touched" "F/stale-queue warns"

# Case G — no DECISION_QUEUE.md → skip (opt-in), still exit 0
r="$(mkrepo)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G/no-queue rc"
assert_has "$out" "decision-queue 是 opt-in" "G/no-queue skips"

# Case H — cleared history retained in active queue → hard FAIL
r="$(mkrepo)"
printf '# queue\n## 🔴 NEEDS YOU\n\n## ✅ CLEARED（保持为空）\n| D-1 | already decided |\n' > "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "H/cleared-history rc"
assert_has "$out" "retains cleared history" "H/cleared-history blocks"

# Case I — empty cleared section is allowed
r="$(mkrepo)"; printf '# queue\n## ✅ CLEARED（保持为空）\n' > "$r/docs/DECISION_QUEUE.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "I/empty-cleared rc"
assert_has "$out" "active/parked items only" "I/empty-cleared clean"

# --- check 6: 本仓 duplex 会话收口 (fake tmux on PATH keeps liveness deterministic) --
mkaw(){ mktemp -d; }
mkfaketmux(){ # $1 exit code for has-session → echoes bin dir
  local b; b="$(mktemp -d)"
  printf '#!/bin/sh\nexit %s\n' "$1" > "$b/tmux"; chmod +x "$b/tmux"; echo "$b"
}
runaw(){ ( cd "$1" && PATH="$3:$PATH" AGENT_WATCH_DIR="$2" bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 ); }

# Case J — this-repo session with terminal marker → blocking FAIL (tmux liveness moot)
r="$(mkrepo)"; aw="$(mkaw)"; ft="$(mkfaketmux 0)"
printf 'engine=omp\ncwd=%s\n' "$r" > "$aw/j1.duplex.meta"; : > "$aw/j1.terminal.json"
out="$(runaw "$r" "$aw" "$ft")"; rc=$?
assert_rc "$rc" 1 "J/terminal-uncleaned rc"
assert_has "$out" "round is over but not stopped" "J/terminal-uncleaned flagged"
assert_has "$out" "agentctl stop j1" "J names the session"

# Case K — dead wrapper (tmux says gone), no marker → still FAIL
r="$(mkrepo)"; aw="$(mkaw)"; ft="$(mkfaketmux 1)"
printf 'engine=omp\ncwd=%s\n' "$r" > "$aw/k1.duplex.meta"
out="$(runaw "$r" "$aw" "$ft")"; rc=$?
assert_rc "$rc" 1 "K/dead-wrapper rc"
assert_has "$out" "agentctl stop k1" "K/dead-wrapper flagged"

# Case L — live session, no terminal evidence → warn only, exit 0
r="$(mkrepo)"; aw="$(mkaw)"; ft="$(mkfaketmux 0)"
printf 'engine=omp\ncwd=%s\n' "$r" > "$aw/l1.duplex.meta"
out="$(runaw "$r" "$aw" "$ft")"; rc=$?
assert_rc "$rc" 0 "L/live-session rc (warn≠fail)"
assert_has "$out" "live/unknown session" "L/live-session warns"

# Case M — other repo's session is out of scope, stays green
r="$(mkrepo)"; aw="$(mkaw)"; ft="$(mkfaketmux 1)"
printf 'engine=omp\ncwd=/somewhere/else\n' > "$aw/m1.duplex.meta"; : > "$aw/m1.terminal.json"
out="$(runaw "$r" "$aw" "$ft")"; rc=$?
assert_rc "$rc" 0 "M/other-repo rc"
assert_has "$out" "no terminal-but-uncleaned session" "M/other-repo filtered"

# Case N — base checkout diverged from origin (post-squash shape) → warn only, exit 0
r="$(mkrepo)"
( cd "$r"
  echo local > local.txt; git add -A; git commit -qm "local original (pre-squash)"
  d2="$(mktemp -d)"; git clone -q "$(git remote get-url origin)" "$d2/c2"
  cd "$d2/c2"; git config user.email t@t; git config user.name t
  echo squashed > squashed.txt; git add -A; git commit -qm "squashed result"; git push -q origin main
)
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "N/diverged base is warn-only rc"
assert_has "$out" "diverged from origin/main" "N/diverged base checkout warned"
rp="$(cd "$r" && pwd -P)"
assert_has "$out" "git -C $(printf '%q' "$rp") branch backup" "N/remedy is scoped to the warned checkout"

# Case O — base ahead-only (unpushed local work, origin unmoved) → NOT a divergence warn
r="$(mkrepo)"
( cd "$r"; echo wip > wip.txt; git add -A; git commit -qm "unpushed local work" )
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "O/ahead-only rc"
assert_no "$out" "diverged from origin" "O/ahead-only does not warn (宁钝勿敏)"
assert_has "$out" "base checkouts aligned" "O/aligned line present"

# Case P — comparison impossible (origin gone) → UNKNOWN warn, rc 0, NEVER "aligned"
r="$(mkrepo)"
( cd "$r"; git remote remove origin; git update-ref -d refs/remotes/origin/main 2>/dev/null || true )
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "P/unknown comparison is warn-only rc"
assert_has "$out" "divergence UNKNOWN" "P/unknown state warned"
assert_no "$out" "base checkouts aligned" "P/no false aligned line"

# Case Q — checkout path with space + quote → remedy renders as a valid shell escape
r="$(mkrepo)"
( cd "$r"
  git worktree add -f "../nasty dir's wt" main -q 2>/dev/null || git worktree add -f "../nasty dir's wt" main
  echo local > local.txt; git add -A; git commit -qm "local original"
  d2="$(mktemp -d)"; git clone -q "$(git remote get-url origin)" "$d2/c2"
  cd "$d2/c2"; git config user.email t@t; git config user.name t
  echo squashed > sq.txt; git add -A; git commit -qm "squashed"; git push -q origin main
)
out="$(run "$r")"; rc=$?
np="$(cd "$r/../nasty dir's wt" && pwd -P)"
assert_rc "$rc" 0 "Q/nasty path rc"
assert_has "$out" "git -C $(printf '%q' "$np") branch backup" "Q/remedy shell-escapes the nasty path"
assert_has "$out" "git -C $(printf '%q' "$np") reset --hard origin/main" "Q/reset half is escaped and ref-complete"

# Case R — a live tmux session in NO record → FOREIGN warn, rc unchanged, session untouched.
# Real tmux on a private socket (shim on PATH) so the machine's own sessions stay invisible.
if command -v tmux >/dev/null 2>&1; then
  rt="$(command -v tmux)"; ftd="$(mktemp -d)"
  printf '#!/bin/sh\nexec %s -L rc-foreign-%s "$@"\n' "$rt" "$$" > "$ftd/tmux"; chmod +x "$ftd/tmux"
  r="$(mkrepo)"; aw="$(mkaw)"
  # tmux lists sessions alphabetically: the recorded pair sorts BEFORE the foreign one, so
  # a broken record filter would prepend them and break the exact "FOREIGN: <name>" literal.
  printf 'engine=omp\ncwd=/somewhere/else\n' > "$aw/rcf-arec.duplex.meta"
  "$ftd/tmux" new-session -d -s rcf-arec sleep 300         # recorded → must NOT be flagged
  "$ftd/tmux" new-session -d -s rcf-arec-watchd sleep 300  # its watcher → must NOT be flagged
  "$ftd/tmux" new-session -d -s rcf-zforeign sleep 300     # nobody's record → FOREIGN
  out="$(runaw "$r" "$aw" "$ftd")"; rc=$?
  alive="$("$ftd/tmux" has-session -t "=rcf-zforeign" 2>/dev/null && echo ALIVE || echo GONE)"
  "$ftd/tmux" kill-server >/dev/null 2>&1
  assert_rc "$rc" 0 "R/foreign is warn-only"
  assert_has "$out" 'FOREIGN: "rcf-zforeign"' "R/foreign named, recorded session+watchd excluded"
  assert_has "$alive" "ALIVE" "R/foreign session left running (只报不杀)"
else
  echo "  [skip] no tmux — FOREIGN case skipped"
fi

# --- check 7: typed lesson ledger (教训与门同形态, retrospective §3) ------------------
# Case S — known-positive recall: a REAL recurring lesson from the field corpus written
# exactly as the ledger grammar prescribes must go red (n=3, still gateless).
r="$(mkrepo)"; printf 'LESSON: pipe-masks-exit-code n=3 gate=none\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "S/recurrent-gateless rc"
assert_has "$out" "pipe-masks-exit-code" "S names the lesson"
assert_has "$out" "复发≥2" "S states the rule"

# Case T — n=1 gateless is OBSERVATION tier → green
r="$(mkrepo)"; printf 'LESSON: first-sighting n=1 gate=none\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "T/observation-tier rc"
assert_no "$out" "[FAIL]" "T/no fail lines"

# Case U — gate points at a real file (list-marker prefix form) → green
r="$(mkrepo)"; mkdir -p "$r/test"; : > "$r/test/some-gate.sh"
printf -- '- LESSON: gated-lesson n=4 gate=test/some-gate.sh\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "U/gated rc"
assert_has "$out" "none past the prose limit" "U/gated counted clean"

# Case V — claimed gate file does not exist → FAIL (dead pointer reads as protection)
r="$(mkrepo)"; printf 'LESSON: ghost-gate n=2 gate=test/never-written.sh\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "V/dead-pointer rc"
assert_has "$out" "no such file" "V/dead pointer flagged"

# Case W — documented acceptance with a reason → green; empty acceptance → warn only
r="$(mkrepo)"
printf 'LESSON: accepted-boundary n=2 gate=accepted(边界不属病 主理人放行)\nLESSON: hollow-accept n=2 gate=accepted()\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "W/accepted rc"
assert_has "$out" "hollow-accept" "W/empty acceptance named"
assert_has "$out" "needs a reason" "W/empty acceptance warned"

# Case X — malformed line → warn, never silently consumed as green data
r="$(mkrepo)"; printf 'LESSON: broken-entry recurrence=three\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "X/malformed rc (warn≠fail)"
assert_has "$out" "malformed LESSON line" "X/malformed warned"

# Case Y — no LESSON lines anywhere → explicit skip note, not a silent green
r="$(mkrepo)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Y/no-ledger rc"
assert_has "$out" "教训台账未 typed 化" "Y/absence is named, not silent"
assert_has "$out" "自造门未记账" "Y/gate-audit absence named too"

# --- 8) gate-effect audit (GATE-AUDIT lines) ---
# Case G1 — zero real catch + two false BLOCKEDs + bare keep → FAIL (default is kill)
r="$(mkrepo)"; printf 'GATE-AUDIT: line-cap hits=0 false=3 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "G1/zero-catch kept rc"
assert_has "$out" "gate 'line-cap' hits=0 false=3" "G1/named"
# Case G2 — same numbers, keep WITH reason → passes (judgment stated)
r="$(mkrepo)"; printf 'GATE-AUDIT: line-cap hits=0 false=3 action=keep(主理人裁：等第二例再删)\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G2/reasoned keep rc"
# Case G3 — kill → passes; Case G4 — real catch → keep allowed bare
r="$(mkrepo)"; printf -- '- GATE-AUDIT: hunk-ritual hits=0 false=2 action=kill\nGATE-AUDIT: path-closure hits=1 false=3 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G3+G4/kill and real-catch keep rc"
assert_has "$out" "2 gate-audit line(s)" "G3+G4/both counted"
# Case G5 — malformed → warn, not consumed
r="$(mkrepo)"; printf 'GATE-AUDIT: sloppy caught=0 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G5/malformed rc"
assert_has "$out" "malformed GATE-AUDIT line" "G5/malformed warned"
# Case G6 — empty keep() with zero catch → FAIL (hollow reason is no reason)
r="$(mkrepo)"; printf 'GATE-AUDIT: hollow hits=0 false=2 action=keep()\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "G6/hollow keep rc"
# Case G7 — fenced grammar example must NOT count as an audit record (kills: fence skip
# dropped from check 8's awk feeder)
r="$(mkrepo)"; printf '```text\nGATE-AUDIT: example-only hits=0 false=3 action=keep\n```\n' > "$r/docs/guide.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G7/fenced-example rc"
assert_no "$out" "example-only" "G7/fenced example not consumed"
assert_has "$out" "自造门未记账" "G7/still reads as no audit ledger"
# Case G8 — false past the 9-digit grammar cap is malformed, never counted data
# (kills: false cap widened to {1,10})
r="$(mkrepo)"; printf 'GATE-AUDIT: overflow hits=0 false=1000000000 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G8/oversized-false rc (warn≠fail)"
assert_has "$out" "malformed GATE-AUDIT line" "G8/oversized false rejected as malformed"
# Case G9 — trailing prose after the action is malformed, never a silent green bypass
# (kills: end-of-line anchor dropped from the grammar)
r="$(mkrepo)"; printf 'GATE-AUDIT: trailing-prose hits=0 false=2 action=keep because reasons\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G9/trailing-prose rc"
assert_has "$out" "malformed GATE-AUDIT line" "G9/trailing prose rejected"
# Case G10 — a keep reason may contain parentheses; it is a real reason, not malformed
# (kills: reason body narrowed back to \([^)]*\), which misjudged a non-empty nested-paren
#  reason as malformed — warn noise, record escapes the judged surface; not a FAIL bypass)
r="$(mkrepo)"; printf 'GATE-AUDIT: nested-reason hits=0 false=3 action=keep(主理人裁：先留(下批再看))\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G10/nested-paren reason rc"
assert_no "$out" "malformed GATE-AUDIT line" "G10/nested parens are data, not malformation"
assert_has "$out" "1 gate-audit line(s)" "G10/counted as a real audit record"
# Case G11 — false=2 is ON the threshold: bare keep with zero catch → FAIL
# (kills: false>=2 relaxed to false>2 in the bare-keep branch)
r="$(mkrepo)"; printf 'GATE-AUDIT: two-false hits=0 false=2 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "G11/threshold false=2 rc"
assert_has "$out" "gate 'two-false' hits=0 false=2" "G11/named at the threshold"
# Case G12 — one real catch immunizes any false count inside the grammar cap: documented
# narrow boundary (kills: false cap narrowed below 9 digits)
r="$(mkrepo)"; printf 'GATE-AUDIT: real-catch hits=1 false=999999999 action=keep\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G12/real-catch big-false rc"
assert_no "$out" "malformed GATE-AUDIT line" "G12/9-digit false is in-grammar"
assert_has "$out" "no unjustified zero-catch gate" "G12/counted clean"

# --- review reproductions as standing assertions (each was a live bypass/false-positive) --
# Case Z1 — fenced grammar example must NOT count as a ledger record (opt-in boundary)
r="$(mkrepo)"; printf '```text\nLESSON: example-only n=2 gate=none\n```\n' > "$r/docs/guide.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Z1/fenced-example rc"
assert_no "$out" "example-only" "Z1/fenced example not consumed"
assert_has "$out" "教训台账未 typed 化" "Z1/still reads as no ledger"

# Case Z2 — n past the 9-digit grammar cap must be malformed, never reaching the shell
# test operator (the review repro overflowed [ -ge ] into a silent green; the cap is the fix)
r="$(mkrepo)"; printf 'LESSON: huge-count n=9999999999 gate=none\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Z2/oversized-n rc (warn≠fail)"
assert_has "$out" "malformed LESSON line" "Z2/oversized n rejected as malformed"
assert_no "$out" "integer expression expected" "Z2/no shell test error leaks"

# Case Z3 — 'n=1x' must not be truncated to n=1 and consumed
r="$(mkrepo)"; printf 'LESSON: malformed-count n=1x gate=none\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Z3/nonnumeric-n rc"
assert_has "$out" "malformed LESSON line" "Z3/partial match rejected"

# Case Z4 — whitespace-only acceptance reason must warn, not bypass the n>=2 rule
r="$(mkrepo)"; printf 'LESSON: whitespace-only n=2 gate=accepted( )\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Z4/blank-reason rc"
assert_has "$out" "needs a reason" "Z4/blank reason warned"

# Case Z5 — trailing prose after gate=none is rejected, not guessed as a path
r="$(mkrepo)"; printf 'LESSON: trailing-prose n=2 gate=none because reasons\n' > "$r/docs/LESSONS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "Z5/trailing-prose rc"
assert_has "$out" "trailing text after gate=none" "Z5/trailing prose rejected"

# --- 9) 批时间记账 (台账 = <repo>/AGENTS.md; 本周期「批」行须带 wall= / avoidable=) --------
# 提效没有强制层时，退化只能靠主理人发火才被发现（本周实证 n=2）；这一检把 wall/avoidable
# 两个数从"记得写"变成收口条件。

# Case TL1 — a 批 entry of THIS cycle with no accounting → blocking FAIL, the line is named
r="$(mkrepo)"; printf '# agents\n- 批 %s effgate：效率强制层四件\n' "$TODAY" > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "TL1/unbilled batch rc"
assert_has "$out" "批条目缺时间记账" "TL1/the offending line is listed"
assert_has "$out" "effgate" "TL1/and quoted verbatim"
assert_has "$out" "wall=95m avoidable=30m" "TL1/the accounting format is shown"

# Case TL2 — the same entry, billed → green
r="$(mkrepo)"
printf '# agents\n- 批 %s effgate：效率强制层四件 wall=95m avoidable=30m\n' "$TODAY" > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "TL2/billed batch rc"
assert_has "$out" "均记了 wall/avoidable" "TL2/counted clean"
assert_no  "$out" "批条目缺时间记账" "TL2/nothing flagged"

# Case TL3 — no ledger at all → 量具坏 = FAIL, never a silent green (a ledger nobody can read
# is not a clean accounting surface; same reading check 2 gives a missing ACTIVE_CONTEXT)
r="$(mkrepo)"; rm "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "TL3/missing ledger rc"
assert_has "$out" "不可读" "TL3/instrument failure is named"
assert_has "$out" "量具坏" "TL3/and called what it is"
assert_no  "$out" "均记了" "TL3/no clean-accounting line is printed"

# Case TL4 — an unreadable (mode 000) ledger reads the same as an absent one, never as clean
if [ "$(id -u)" != "0" ]; then
  r="$(mkrepo)"; chmod 000 "$r/AGENTS.md"
  out="$(run "$r")"; rc=$?
  chmod 644 "$r/AGENTS.md"
  assert_rc "$rc" 1 "TL4/unreadable ledger rc"
  assert_has "$out" "不可读" "TL4/instrument failure is named"
else
  echo "  [skip] running as root — the unreadable-ledger case cannot be built"
fi

# Case TL5 — a 批 entry from an EARLIER cycle is out of the window: not judged, and with no
# in-window entry left the check says so instead of reporting a green it did not measure
r="$(mkrepo)"; printf '# agents\n- 批 2020-01-01 old-batch：上个纪元\n' > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "TL5/out-of-window entry rc"
assert_no  "$out" "批条目缺时间记账" "TL5/an old entry is not re-judged"
assert_has "$out" "本周期无「批」条目" "TL5/absence is named, not silently green"

# Case TL6 — a fenced format example is documentation, not a ledger record (same boundary
# checks 7 and 8 hold; kills: fence skip dropped from check 9's awk)
r="$(mkrepo)"
printf '# agents\n```text\n- 批 %s example-only：格式示例\n```\n' "$TODAY" > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "TL6/fenced-example rc"
assert_no  "$out" "example-only" "TL6/fenced example not consumed"
assert_has "$out" "本周期无「批」条目" "TL6/reads as no in-window entry"

# Case TL7 — half the accounting is not accounting: wall= without avoidable= still FAILs
r="$(mkrepo)"; printf '# agents\n- 批 %s half：只记了墙钟 wall=95m\n' "$TODAY" > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "TL7/half-billed rc"
assert_has "$out" "批条目缺时间记账" "TL7/half accounting is unbilled"

# --- 第 9 检的读数面 (MECHANICAL INPUT): 只出数, 不出裁决, 不动 PASS/FAIL --------------
# The pane's whole risk is that a printed number gets read as a ruling, so these cases pin the
# three properties that stop it: the banner is present, no `wall≈`/`avoidable≈` suggestion is
# printed, and the existing accounting verdict is byte-identical with the pane on or off.
# A fake `agentctl` on PATH keeps the readings deterministic — the machine's real run dir must
# never leak into a test case (same rule case J..M follow for check 6).
mkphases(){ # $1 dir, $2 json body -> a PATH bin holding a fake `agentctl phases`
  mkdir -p "$1"
  { printf '#!/usr/bin/env bash\n[ "$1" = phases ] || exit 1\ncat <<'\''JSON'\''\n'
    printf '%s\n' "$2"
    printf 'JSON\n'
  } > "$1/agentctl"
  chmod +x "$1/agentctl"
}
PH_OK='{"coverage":"ok","shards_missing":[],"shards_unreadable":[],"skipped":1,
 "clock_regressed":2,"future_dropped":3,
 "sessions":[{"name":"a"},{"name":"b"}],
 "readings":{"batch_span_s":5700,"seat_wall_s":10260,"review_wall_s":2520,
 "idle_span_s":720,"idle_segments":2,
 "idle_top":[{"from":"2026-09-02T01:20:00.000Z","to":"2026-09-02T01:27:00.000Z","seconds":420}],
 "dispatch_latency":[{"name":"a","class":"DONE","next_event":"start","next_name":"b",
 "seconds":480}],"dispatch_latency_max_s":480,"dispatch_pending":0}}'
PH_UNKNOWN='{"coverage":"unknown","shards_missing":["20260901"],"shards_unreadable":[],
 "skipped":0,"clock_regressed":0,"future_dropped":0,"sessions":[],"readings":{}}'
# the R1-B1 shape: every window day EXISTS on disk, but one of them could not be read. It must
# reach this pane as `unknown` — an existing path is not readable data, and a set of zeroes
# nobody measured looks exactly like a measurement.
PH_DARK='{"coverage":"unknown","shards_missing":[],"shards_unreadable":["20260902"],
 "skipped":0,"clock_regressed":0,"future_dropped":0,"sessions":[],"readings":{}}'
# a report whose shape this pane does not know (an older/newer verb): degrade, never traceback
PH_ALIEN='{"coverage":"ok","sessions":[],"readings":{"batch_span_s":1}}'

# Case PH1 — readings available: the banner leads, the numbers follow, no suggestion is made,
# and the accounting check keeps its own verdict (the green fixture is billed)
r="$(mkrepo)"; mkphases "$r/.fakebin" "$PH_OK"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH1/readings do not change rc"
assert_has "$out" "MECHANICAL INPUT — DO NOT COPY AS VERDICT" "PH1/the banner leads the pane"
assert_has "$out" "batch_span=95m" "PH1/batch span is rendered in minutes"
assert_has "$out" "seat_wall=171m" "PH1/seat wall too"
assert_has "$out" "seat machine-time" "PH1/and is labelled as machine-time, not wall clock"
assert_has "$out" "review_wall=42m" "PH1/review wall is broken out"
assert_has "$out" "idle_span=12m" "PH1/idle span is totalled"
assert_has "$out" "dispatch_latency max=8m" "PH1/dispatch latency reports its maximum"
assert_has "$out" "never summed" "PH1/and says it is never summed"
assert_has "$out" "clock_regressed=2" "PH1/the excluded edges are surfaced, not hidden"
assert_has "$out" "future_dropped=3" "PH1/so are rows dropped for claiming a future instant"
assert_no  "$out" "wall≈" "PH1/no wall suggestion is offered"
assert_no  "$out" "avoidable≈" "PH1/no avoidable suggestion is offered"
assert_has "$out" "均记了 wall/avoidable" "PH1/the accounting check still reports its own verdict"

# Case PH2 — the pane must not manufacture a pass: an UNBILLED entry still FAILs with the
# readings printed right above it (that is the whole point — input, not verdict)
r="$(mkrepo)"; mkphases "$r/.fakebin" "$PH_OK"
printf '# agents\n- 批 %s effgate：效率强制层四件\n' "$TODAY" > "$r/AGENTS.md"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 1 "PH2/readings never bill an entry for the human"
assert_has "$out" "MECHANICAL INPUT" "PH2/the pane still printed"
assert_has "$out" "批条目缺时间记账" "PH2/and the accounting FAIL is untouched"

# Case PH3 — coverage unknown: one n/a line, no numbers, verdict unchanged
r="$(mkrepo)"; mkphases "$r/.fakebin" "$PH_UNKNOWN"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH3/unknown coverage does not change rc"
assert_has "$out" "phases: n/a (coverage unknown" "PH3/it says it cannot vouch for the window"
assert_has "$out" "20260901" "PH3/and names the shard it is missing"
assert_no  "$out" "MECHANICAL INPUT" "PH3/no banner over numbers it did not measure"
assert_no  "$out" "batch_span" "PH3/and no numbers at all"
assert_has "$out" "均记了 wall/avoidable" "PH3/the accounting verdict is byte-identical"

# Case PH4 — `agentctl` is on PATH but has no ledger to answer from (silent, nonzero exit):
# the same one-line degradation. The truly-absent-verb branch cannot be built by stripping
# PATH — that would take `git`/`date` away too and degrade every other check in the same run
# — so the honest fixture is a verb that answers with nothing.
r="$(mkrepo)"; mkdir -p "$r/.fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$r/.fakebin/agentctl"; chmod +x "$r/.fakebin/agentctl"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH4/a verb with nothing to say does not change rc"
assert_has "$out" "phases: n/a" "PH4/a silent verb degrades to one n/a line"
assert_no  "$out" "MECHANICAL INPUT" "PH4/and prints no readings"
assert_has "$out" "均记了 wall/avoidable" "PH4/the accounting verdict is byte-identical"

# Case PH5 — a verb that answers with garbage is not a reading either
r="$(mkrepo)"; mkphases "$r/.fakebin" "not json at all"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH5/an unreadable report does not change rc"
assert_has "$out" "phases: n/a" "PH5/it degrades rather than guessing"
assert_no  "$out" "MECHANICAL INPUT" "PH5/and prints no banner"

# Case PH6 — the R1-B1 shape: no shard is MISSING, one is unreadable. Same n/a, and the
# message must name the dark day — otherwise the operator hunts for a hole that is not there.
r="$(mkrepo)"; mkphases "$r/.fakebin" "$PH_DARK"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH6/an unreadable shard does not change rc"
assert_has "$out" "phases: n/a (coverage unknown" "PH6/it still refuses to vouch"
assert_has "$out" "unreadable 20260902" "PH6/and names the day it could not read"
assert_no  "$out" "MECHANICAL INPUT" "PH6/no banner over data it never read"
assert_has "$out" "均记了 wall/avoidable" "PH6/the accounting verdict is byte-identical"

# Case PH7 — a report of a shape this pane does not know (an older or newer verb): degrade to
# n/a. A traceback in the middle of a retro is not an advisory, and this pane is only advisory.
r="$(mkrepo)"; mkphases "$r/.fakebin" "$PH_ALIEN"
out="$( cd "$r" && PATH="$r/.fakebin:$PATH" AGENT_WATCH_DIR="$r/.no-agent-watch" \
        bash "$SCRIPT" --base main --docs docs --memory MEMORY.md 2>&1 )"; rc=$?
assert_rc "$rc" 0 "PH7/an unknown report shape does not change rc"
assert_has "$out" "phases: n/a" "PH7/it degrades to one n/a line"
assert_no  "$out" "Traceback" "PH7/and never leaks a traceback into the retro"
assert_has "$out" "均记了 wall/avoidable" "PH7/the accounting verdict is byte-identical"

echo "== retro-check: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
