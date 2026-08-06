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

echo "== retro-check: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
