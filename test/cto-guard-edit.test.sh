#!/usr/bin/env bash
# cto-guard-edit.py — PreToolUse·Edit|Write|MultiEdit guard, ONE rule (E1): the orchestrator
# writing product code by hand is DENIED unless the write comes from a LIVE agentctl seat's cwd
# or carries the one-shot override marker.
#
# Every case below drives the REAL hook contract: a JSON payload on stdin, verdict read off the
# exit code and stderr/stdout — not a python-level call into a helper. The two cases the forensic
# report singled out as the whole difficulty of this gate are pinned as named assertions:
#   * a LIVE seat writing source inside its own worktree must pass;
#   * a STOPPED seat's surviving duplex.meta (watchctl `_STOP_KEPT` keeps it) must NOT grant
#     write rights — otherwise a worktree that finished days ago holds them forever.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agentctl/cto-guard-edit.py"

echo "== cto-guard-edit.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "    git not on PATH — guard test skipped"; exit 0
fi

FIX="$(mktemp -d /tmp/ctoedit.XXXXXX)"
RUN="$FIX/run"
BIN="$FIX/bin"
mkdir -p "$RUN" "$BIN"
trap 'rm -rf "$FIX"; rm -f /tmp/cto-allow-direct-write' EXIT

# Fake tmux: `has-session -t =<name>` succeeds only for a session named in $TMUX_LIVE.
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
target=""
for a in "$@"; do case "$a" in =*) target="${a#=}";; esac; done
case " ${TMUX_LIVE:-} " in *" $target "*) exit 0 ;; esac
exit 1
EOF
chmod +x "$BIN/tmux"
PATH="$BIN:$PATH"; export PATH
TMUX_LIVE=""; export TMUX_LIVE

# The orchestrator's own cwd: a real git repo that is NOT any seat's worktree. The seat's
# worktree sits INSIDE it on purpose — that makes the containment test's DIRECTION load-bearing
# (a seat licenses itself and what is under it, never its parent).
ORCH="$FIX/umbrella"
mkdir -p "$ORCH"
git -C "$ORCH" init -q
SEAT="$ORCH/wt-worker"
mkdir -p "$SEAT"
git -C "$SEAT" init -q

# THE PREMISE OF EVERY CASE BELOW, and it is a premise the gate really requires since
# 2026-09-06: E1 judges only a repo THIS BOX IS ORCHESTRATING (a LIVE seat, or a phase-ledger
# `start` row of today/yesterday, in the same repo by git common dir). A checkout with neither
# is silently none of the gate's business — asserted as its own arm at the end of this file, so
# the rows written here are what makes the DENY arms discriminate at all.
ledger_row() { # $1 cwd — one `start` row in today's shard of THIS fixture's run dir
  python3 -c 'import json, os, sys
print(json.dumps({"ts": "2026-09-06T00:00:00.000Z", "event": "start", "name": "fixture",
                  "session_id": "s", "attempt": "a", "engine": "omp",
                  "cwd": os.path.realpath(sys.argv[1])}))' "$1" \
    >> "$RUN/phase-ledger-$(date -u +%Y%m%d).jsonl"
}
ledger_row "$ORCH"
ledger_row "$SEAT"

seat_meta() { # $1 session  $2 cwd  [$3 rc-value → writes the rc file = engine exited]
  printf 'engine=omp\ncwd=%s\nround=1\n' "$2" > "$RUN/$1.duplex.meta"
  if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$RUN/$1.duplex.rc"; else rm -f "$RUN/$1.duplex.rc"; fi
}

mkpayload() { # $1 tool  $2 file_path  $3 cwd ("-" omits the key)
  python3 -c 'import json,sys
d={"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}
if sys.argv[3]!="-": d["cwd"]=sys.argv[3]
print(json.dumps(d))' "$@"; }

run() { # $1 tool  $2 file_path  $3 cwd  [$4 run-dir override]
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkpayload "$1" "$2" "$3" | AGENT_WATCH_DIR="${4:-$RUN}" python3 "$GUARD" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }

chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# ── E1 BAD SAMPLES: the orchestrator hand-writing source outside every live seat ───────────
rm -f "$RUN"/*.duplex.meta /tmp/cto-allow-direct-write
run Write "$ORCH/skills/foo.py" "$ORCH"
chk_eq "orchestrator writing a .py denied (exit 2)" 2 "$RC"
chk_contains "deny names the disease" "编排位直写源码面" "$ERR"
chk_contains "deny gives the正路 dispatch command" "agentctl start <engine> <session> <cwd>" "$ERR"
chk_contains "deny names the override marker" "/tmp/cto-allow-direct-write" "$ERR"
chk_contains "deny carries the doc pointer" "Read: cto-orchestration/SKILL.md" "$ERR"
chk_eq "a deny writes no hook response on stdout" "" "$OUT"

run Edit "$ORCH/scripts/deploy.sh" "$ORCH"
chk_eq "Edit on a .sh denied" 2 "$RC"
run MultiEdit "$ORCH/src/app.ts" "$ORCH"
chk_eq "MultiEdit on a .ts denied" 2 "$RC"
# the whole declared extension set ships tested: an unexercised entry could be a silent typo
for ext in py sh bash ts js tsx jsx go rs java kt rb; do
  run Write "$ORCH/src/unit.$ext" "$ORCH"
  chk_eq "source extension .$ext is guarded" 2 "$RC"
done
# extension-less file under a test dir — the shape the extension list cannot see
run Write "$ORCH/test/fixtures/golden" "$ORCH"
chk_eq "a file under /test/ is the test face, guarded" 2 "$RC"
run Write "$ORCH/tests/helper" "$ORCH"
chk_eq "and /tests/ too" 2 "$RC"
# case: uppercase extension is the same file type to every toolchain
run Write "$ORCH/src/Main.PY" "$ORCH"
chk_eq "extension match is case-insensitive" 2 "$RC"

# ── E1 GOOD SAMPLES: non-source faces are never this rule's business ──────────────────────
for f in docs/GOAL.md docs/data.json config/app.yaml pyproject.toml notes.txt README; do
  run Write "$ORCH/$f" "$ORCH"
  chk_eq "non-source $f allowed" 0 "$RC"
  chk_eq "and silent: $f" "" "$ERR$OUT"
done
# a dotted directory must not be read as the file's extension
run Write "$ORCH/pkg.py/NOTES" "$ORCH"
chk_eq "extension is read off the BASENAME, not the path" 0 "$RC"

# ── E1 GOOD SAMPLE: a LIVE seat writing source inside its own worktree ────────────────────
seat_meta worker "$SEAT"
TMUX_LIVE="worker"
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "live seat writing in its own worktree allowed" 0 "$RC"
chk_eq "and silently" "" "$ERR$OUT"
run Write "$SEAT/src/app.py" "$SEAT/src/deep/dir"
chk_eq "live seat cd'd deeper is still that seat" 0 "$RC"
# PAIRED RED: the same live seat does not license the ORCHESTRATOR's cwd
run Write "$ORCH/src/app.py" "$ORCH"
chk_eq "a live seat elsewhere does not license the orchestrator's cwd" 2 "$RC"
# THE DIRECTION: the seat's worktree lives inside $ORCH, so the very same live seat must not
# license a write from its PARENT — that parent is the orchestrator's checkout.
run Write "$ORCH/src/app.py" "$ORCH"
chk_eq "the seat's parent directory is not the seat" 2 "$RC"

# ── E1 THE _STOP_KEPT TRAP: a stopped seat's surviving meta must not grant write rights ───
# `agentctl stop` keeps <s>.duplex.meta AND <s>.duplex.rc for post-mortem, and kills the tmux
# session. Reading the meta alone would hand this worktree permanent write rights.
seat_meta worker "$SEAT" 0
TMUX_LIVE=""
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "stopped seat (rc file present) is NOT live — denied" 2 "$RC"
# rc file absent but the tmux session is gone (crashed pane, killed shell): also not live
seat_meta worker "$SEAT"
TMUX_LIVE="someone-else"
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "meta without a tmux session is NOT live — denied" 2 "$RC"
# UNDECIDABLE LIVENESS FAILS OPEN, on purpose. Targeted mutation rather than PATH surgery: an
# unexecutable `tmux` on PATH is SKIPPED by execvp, which then finds the real binary and answers
# a decidable "no" — so only killing the tmux call itself reproduces "the probe never answered".
seat_meta worker "$SEAT"
TMUX_LIVE=""
tmpe="$(mktemp)"
out="$(AGENT_WATCH_DIR="$RUN" python3 -c 'import io,runpy,subprocess,sys
sys.stdin=io.StringIO(sys.argv[2])
_run=subprocess.run
subprocess.run=lambda a,**k: ((_ for _ in ()).throw(FileNotFoundError("no tmux"))
                              if list(a)[:1]==["tmux"] else _run(a,**k))
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" \
      "$(mkpayload Write "$SEAT/src/app.py" "$SEAT")" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"
rm -f "$tmpe"
chk_eq "an unanswerable tmux probe reads as LIVE (allowed, 宁钝勿敏)" 0 "$rc"
chk_eq "and that allow is silent" "" "$err$out"
# a meta with no cwd= line contributes no seat
printf 'engine=omp\nround=1\n' > "$RUN/nocwd.duplex.meta"
TMUX_LIVE="nocwd"
run Write "$ORCH/src/app.py" "$ORCH"
chk_eq "a meta without cwd= grants nothing" 2 "$RC"
rm -f "$RUN/nocwd.duplex.meta" "$RUN"/worker.duplex.*
TMUX_LIVE=""

# ── E1 OVERRIDE: one-shot, consumed on use ───────────────────────────────────────────────
touch /tmp/cto-allow-direct-write
run Write "$ORCH/skills/guard.py" "$ORCH"
chk_eq "override marker lifts the deny" 0 "$RC"
chk_eq "override is silent (permission flow applies)" "" "$ERR$OUT"
chk_eq "override marker consumed (one-shot)" 0 \
  "$([ -e /tmp/cto-allow-direct-write ] && echo 1 || echo 0)"
run Write "$ORCH/skills/guard.py" "$ORCH"
chk_eq "the next write denies again (no standing bypass)" 2 "$RC"
# consumption IS the approval: an unremovable object at the marker path must not become one
mkdir /tmp/cto-allow-direct-write
run Write "$ORCH/skills/guard.py" "$ORCH"
chk_eq "a directory at the marker path still denies" 2 "$RC"
run Write "$ORCH/skills/guard.py" "$ORCH"
chk_eq "and denies repeatably" 2 "$RC"
rmdir /tmp/cto-allow-direct-write

# ── E1 DEGRADE: ALLOW + WARN, never a checker-error that bricks the Edit tool ─────────────
run Write "$ORCH/src/app.py" "$ORCH" "$FIX/no-such-run-dir"
chk_eq "unreadable run dir allows (exit 0)" 0 "$RC"
chk_eq "and never writes to stderr" "" "$ERR"
chk_contains "the degrade is announced, not silent" "WARN (cto-guard E1)" "$(ctx "$OUT")"
chk_contains "the warn names the unreadable run dir" "no-such-run-dir" "$(ctx "$OUT")"
chk_contains "the warn still states the rule" "铁律①" "$(ctx "$OUT")"

run Write "/tmp/scratch/app.py" "/tmp"
chk_eq "a cwd outside any git work tree allows (exit 0)" 0 "$RC"
chk_contains "and says why it could not judge" "not inside a git work tree" "$(ctx "$OUT")"

run Write "$ORCH/src/app.py" -
chk_eq "a payload with no cwd allows (exit 0)" 0 "$RC"
chk_contains "and reports the missing attribution" "carries no \`cwd\`" "$(ctx "$OUT")"

# ── E1 SCOPE: other tools and other events are none of this guard's business ──────────────
run Read "$ORCH/src/app.py" "$ORCH"
chk_eq "a non-matching tool is a silent no-op" 0 "$RC"
chk_eq "and emits nothing" "" "$ERR$OUT"
tmpe="$(mktemp)"
out="$(printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ORCH/x.py\"},\"cwd\":\"$ORCH\"}" \
      | AGENT_WATCH_DIR="$RUN" python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "PostToolUse Write is out of scope" 0 "$rc"
chk_eq "and silent" "" "$err$out"

# ── E1 BROKEN INSTRUMENT: a malformed payload is a CHECKER-ERROR, never a clean allow ────
for bad in 'not json' \
           '{"hook_event_name":"PreToolUse","tool_name":"Write"}' \
           '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{}}' \
           '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":42}}' \
           '[1,2,3]'; do
  tmpe="$(mktemp)"
  out="$(printf '%s' "$bad" | AGENT_WATCH_DIR="$RUN" python3 "$GUARD" 2>"$tmpe")"; rc=$?
  err="$(cat "$tmpe")"; rm -f "$tmpe"
  chk_eq "malformed payload is a checker error: ${bad:0:44}" 2 "$rc"
  chk_contains "and carries the marker: ${bad:0:44}" "CHECKER-ERROR" "$err"
done
# an internal failure must not collapse into a silent allow either
tmpe="$(mktemp)"
out="$(python3 -c 'import io,os,runpy,sys
sys.stdin=io.StringIO(sys.argv[2])
os.listdir=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom"))
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" \
      "$(mkpayload Write "$ORCH/src/app.py" "$ORCH")" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"
rm -f "$tmpe"
chk_eq "an internal guard failure exits 2" 2 "$rc"
chk_contains "internal failure marker" "CHECKER-ERROR" "$err"

# ── R2 (cold review §1) THE JUDGED FACE: the write TARGET, not the caller's cwd ────────────
# R1 classified the target from `file_path` but attributed repo/seat ownership from payload `cwd`
# alone, so it never proved the write lands in a governed repo. Both counter-probes are pinned
# here as a red/green PAIR, because a blanket allow or a blanket deny satisfies neither.
rm -f "$RUN"/*.duplex.meta "$RUN"/*.duplex.rc /tmp/cto-allow-direct-write
OTHER="$FIX/other-checkout"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
ledger_row "$OTHER"            # the foreign checkout is orchestrated too — see the premise above
seat_meta worker "$SEAT"; TMUX_LIVE="worker"
run Write "$OTHER/src/app.py" "$SEAT"
chk_eq "R2-1.1 a LIVE seat writing source into ANOTHER checkout is denied" 2 "$RC"
chk_contains "R2-1.1 and the deny names the target it judged" "$OTHER/src/app.py" "$ERR"
run Write "/tmp/cto-e1-outside.py" "$ORCH"
chk_eq "R2-1.1 a target no work tree owns is outside this rule's face (exit 0)" 0 "$RC"
chk_eq "R2-1.1 and never lands on stderr" "" "$ERR"
chk_contains "R2-1.1 the unjudged write is announced" "WARN (cto-guard E1)" "$(ctx "$OUT")"
chk_contains "R2-1.1 and the warn names the TARGET" "/tmp/cto-e1-outside.py" "$(ctx "$OUT")"
run Write "$ORCH/src/app.py" "$ORCH"
chk_eq "R2-1.1 control: the same cwd writing INSIDE its own repo is still denied" 2 "$RC"

# §1.4 a seat launched in a SUBDIRECTORY owns its whole work tree — R1 denied that legal worker.
# Root equality is the mechanism, and the DIRECTION still holds: $ORCH is a different work tree.
mkdir -p "$SEAT/sub"
seat_meta worker "$SEAT/sub"; TMUX_LIVE="worker"
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "R2-1.4 a seat launched in a subdirectory still owns its repo root" 0 "$RC"
chk_eq "R2-1.4 and silently" "" "$ERR$OUT"
run Write "$ORCH/src/app.py" "$ORCH"
chk_eq "R2-1.4 and it still does not own the parent checkout" 2 "$RC"

# §1.2 the test-dir shape catches ONLY what the extension list cannot see: data and docs under
# `test/` are the non-source face the contract puts through, and R1 denied every one of them.
rm -f "$RUN"/*.duplex.meta "$RUN"/*.duplex.rc
TMUX_LIVE=""
for f in test/fixtures/data.json tests/config.yaml test/README.md test/fixtures/expected.toml \
         test/cases/one.yml test/notes.txt; do
  run Write "$ORCH/$f" "$ORCH"
  chk_eq "R2-1.2 non-source under a test dir is allowed: $f" 0 "$RC"
  chk_eq "R2-1.2 and silent: $f" "" "$ERR$OUT"
done
run Write "$ORCH/test/fixtures/helper.py" "$ORCH"
chk_eq "R2-1.2 control: a .py under the same test dir is still guarded" 2 "$RC"
run Write "$ORCH/test/fixtures/runner" "$ORCH"
chk_eq "R2-1.2 control: an EXTENSION-LESS file under it is still guarded" 2 "$RC"

# §1.3 a listable run dir is NOT a readable census: a meta that cannot be OPENED must degrade to
# ALLOW+WARN, never silently drop the seat it belongs to (R1 could DENY that seat's own worker).
seat_meta worker "$SEAT"; TMUX_LIVE="worker"
chmod 000 "$RUN/worker.duplex.meta"
run Write "$ORCH/src/app.py" "$ORCH"
META_RC=$RC; META_OUT=$OUT; META_ERR=$ERR
chmod 644 "$RUN/worker.duplex.meta"
chk_eq "R2-1.3 an unopenable meta degrades to ALLOW (exit 0)" 0 "$META_RC"
chk_eq "R2-1.3 and never to a DENY" "" "$META_ERR"
chk_contains "R2-1.3 the short census is announced" "WARN (cto-guard E1)" "$(ctx "$META_OUT")"
# and the rc-file probe: a stat that cannot ANSWER reads as LIVE, it does not drop the seat.
# Targeted mutation, `.duplex.rc` only — `os.path.exists` reported a stat ERROR as False, which
# is the opposite verdict from the contracted "rc 不可判按 live".
# TMUX SAYS DEAD on purpose: with a live tmux session this case cannot discriminate the fix at
# all (the seat would be admitted by the OTHER half of the predicate), and a mutation run proved
# exactly that — the first version of this assertion survived reverting `os.stat` to
# `os.path.exists`. An undecidable rc file is admitted BEFORE the tmux probe is consulted.
seat_meta worker "$SEAT"; TMUX_LIVE="someone-else"
tmpe="$(mktemp)"
out="$(AGENT_WATCH_DIR="$RUN" python3 -c 'import io,os,runpy,sys
sys.stdin=io.StringIO(sys.argv[2])
_stat=os.stat
os.stat=lambda p,*a,**k: ((_ for _ in ()).throw(PermissionError("stat refused"))
                          if str(p).endswith(".duplex.rc") else _stat(p,*a,**k))
runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" \
      "$(mkpayload Write "$SEAT/src/app.py" "$SEAT")" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"
rm -f "$tmpe"
chk_eq "R2-1.3 an unanswerable rc stat keeps the seat LIVE (allowed)" 0 "$rc"
chk_eq "R2-1.3 and that allow is silent" "" "$err$out"
# PAIRED RED, same fixture unmutated: with the rc file merely ABSENT and tmux dead, the seat is
# dead and the write denied — so the allow above comes from the unanswerable probe, not the setup.
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "R2-1.3 control: an ANSWERED probe with tmux dead still denies" 2 "$RC"
seat_meta worker "$SEAT" 0
run Write "$SEAT/src/app.py" "$SEAT"
chk_eq "R2-1.3 control: a real rc file still means dead (denied)" 2 "$RC"
rm -f "$RUN"/worker.duplex.* /tmp/cto-e1-outside.py
TMUX_LIVE=""

# ── THE IDENTITY PREDICATE (audit §1, 2026-09-06): which REPO is this gate's business ───────
# Every arm below drives the same hook contract; the three-state predicate is observed through
# the only faces it has — a silent rc 0 (`not`: nobody is orchestrating here), a DENY (`orches-
# trated`), and the ALLOW+WARN (`undecidable`). No python-level call into the helper.
SHARD="$RUN/phase-ledger-$(date -u +%Y%m%d).jsonl"
rm -f "$RUN"/*.duplex.meta "$RUN"/*.duplex.rc /tmp/cto-allow-direct-write
TMUX_LIVE=""

# i3/e1/i6 — a repo with NO live seat and NO ledger row: the single-agent lane the SKILL
# excludes. i6 rides the same fixture: BOTH this repo and $ORCH (which IS orchestrated) answer
# `git rev-parse --git-common-dir` with the literal string `.git`, so a gate comparing that
# output verbatim would unify them and deny here.
NOORCH="$FIX/plain-checkout"; mkdir -p "$NOORCH"; git -C "$NOORCH" init -q
run Edit "$NOORCH/src/app.py" "$NOORCH"
chk_eq "e1/i3 an unorchestrated repo's .py edit is allowed" 0 "$RC"
chk_eq "e1/i3 and the gate says NOTHING at all (no WARN, no deny)" "" "$ERR$OUT"
chk_eq "i6 DAMAGE ORACLE: a literal \`.git\` compare would have denied this (repo id is the "\
"realpath'd common dir)" 0 "$RC"

# i1/i2/e2/e4 — the normal shape: orchestrator in the main checkout, seat in a SIBLING worktree
# of the SAME repo. Root equality (the holder test) says "not this seat's tree", repo identity
# (the predicate) says "this repo is being orchestrated" — so the main checkout is denied while
# the seat's own worktree passes.
WTREPO="$FIX/wt-main"; mkdir -p "$WTREPO"; git -C "$WTREPO" init -q
git -C "$WTREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
WTLINK="$FIX/wt-sibling"
git -C "$WTREPO" worktree add -q "$WTLINK" 2>/dev/null
chk_eq "i1 fixture: the sibling worktree really exists" 1 \
  "$([ -e "$WTLINK/.git" ] && echo 1 || echo 0)"
seat_meta sib "$WTLINK"; TMUX_LIVE="sib"
run Write "$WTREPO/src/app.py" "$WTREPO"
chk_eq "i1 a LIVE seat in a SIBLING worktree makes the repo orchestrated → main checkout denied" \
  2 "$RC"
chk_contains "i1 and the deny names the live-seat evidence" "LIVE agentctl seat" "$ERR"
run Write "$WTLINK/src/app.py" "$WTLINK"
chk_eq "e4 the same live seat writing inside its OWN worktree still passes" 0 "$RC"
chk_eq "e4 and silently" "" "$ERR$OUT"
rm -f "$RUN"/sib.duplex.*; TMUX_LIVE=""
run Write "$WTREPO/src/app.py" "$WTREPO"
chk_eq "i1 PAIRED GREEN: with that seat gone and no ledger row, the same write is allowed" 0 "$RC"
chk_eq "i1 PAIRED GREEN: and silently" "" "$ERR$OUT"
ledger_row "$WTLINK"
run Write "$WTREPO/src/app.py" "$WTREPO"
chk_eq "i2/e2 a ledger \`start\` row in a sibling worktree denies the main checkout" 2 "$RC"
chk_contains "i2/e2 and the deny names the ledger evidence" "phase ledger" "$ERR"

# i7 — a symlinked spelling of a repo is the same repo (realpath, both sides)
SYMREPO="$FIX/sym-real"; mkdir -p "$SYMREPO"; git -C "$SYMREPO" init -q
ln -s "$SYMREPO" "$FIX/sym-link"
ledger_row "$FIX/sym-link"
run Write "$SYMREPO/src/app.py" "$SYMREPO"
chk_eq "i7 a ledger row spelled through a symlink still names this repo" 2 "$RC"

# i8 — a corrupt ledger line is SKIPPED, it does not make the day unanswerable
JUNK="$FIX/junk-repo"; mkdir -p "$JUNK"; git -C "$JUNK" init -q
printf '{ this is not json\n\n' >> "$SHARD"
ledger_row "$JUNK"
printf 'neither is this\n' >> "$SHARD"
run Write "$JUNK/src/app.py" "$JUNK"
chk_eq "i8 a broken JSONL line is skipped, the good row still decides" 2 "$RC"
chk_eq "i8 and it is a DENY, never the undecidable WARN" "" "$OUT"

# i9 — yesterday's shard counts (the window is today + yesterday, by shard NAME)
YDAY="$FIX/yday-repo"; mkdir -p "$YDAY"; git -C "$YDAY" init -q
python3 -c 'import json, os, sys
print(json.dumps({"ts": "y", "event": "start", "name": "fixture", "session_id": "s",
                  "attempt": "a", "cwd": os.path.realpath(sys.argv[1])}))' "$YDAY" \
  > "$RUN/phase-ledger-$(python3 -c 'import time; print(time.strftime("%Y%m%d", time.gmtime(time.time()-86400)))').jsonl"
run Write "$YDAY/src/app.py" "$YDAY"
chk_eq "i9 yesterday's shard still names this repo as orchestrated" 2 "$RC"

# e5 — the judged face is the TARGET's repo, not the caller's: a LIVE seat writing source into
# an UNORCHESTRATED checkout is allowed, while the same write into an orchestrated one denies
# (the R2-1.1 arm above). A blanket rule satisfies neither.
seat_meta sib2 "$WTLINK"; TMUX_LIVE="sib2"
run Write "$NOORCH/src/app.py" "$WTLINK"
chk_eq "e5 a live seat writing into an UNORCHESTRATED checkout is allowed" 0 "$RC"
chk_eq "e5 and silently — the caller's own repo does not drag the target in" "" "$ERR$OUT"
rm -f "$RUN"/sib2.duplex.*; TMUX_LIVE=""

# i4/e3 — a shard that EXISTS and cannot be READ is blindness: ALLOW + WARN, never a silent
# allow (which would read as "nobody is orchestrating") and never a DENY. Last arm on purpose:
# it takes the fixture's ledger away.
chmod 000 "$SHARD"
run Write "$NOORCH/src/app.py" "$NOORCH"
E3_RC=$RC; E3_OUT=$OUT; E3_ERR=$ERR
chmod 644 "$SHARD"
chk_eq "i4/e3 an unreadable ledger shard allows (exit 0)" 0 "$E3_RC"
chk_eq "i4/e3 and never denies" "" "$E3_ERR"
chk_contains "i4/e3 the undecidable identity is announced" "WARN (cto-guard E1)" "$(ctx "$E3_OUT")"
chk_contains "i4/e3 and the warn names what could not be read" "phase ledger shard" \
  "$(ctx "$E3_OUT")"

# i10/i11 — a SOURCE cwd whose own repo cannot be resolved is UNDECIDABLE evidence, not a
# confirmed stranger. `git -C <that cwd>` is made to time out for real (the target's own probes
# stay live), which is exactly H1's "git unavailable or timed out ⇒ U" on the input side. Its
# own run dir: the fixture above has positive rows for this repo and would mask both arms.
TORUN="$FIX/run-timeout"; mkdir -p "$TORUN"
TOSRC="$FIX/timeout-src"; mkdir -p "$TOSRC"; git -C "$TOSRC" init -q
TOTGT="$FIX/timeout-target"; mkdir -p "$TOTGT"; git -C "$TOTGT" init -q
TOREAL="$(cd "$TOSRC" && pwd -P)"
python3 -c 'import json, os, sys
print(json.dumps({"ts": "2026-09-06T00:00:00.000Z", "event": "start", "name": "fixture",
                  "session_id": "s", "attempt": "a", "cwd": os.path.realpath(sys.argv[1])}))' \
  "$TOSRC" > "$TORUN/phase-ledger-$(date -u +%Y%m%d).jsonl"
run_gitto() { # $1 tool  $2 target  $3 cwd  $4 run-dir  $5 dir whose `git -C` times out
  local tmpe; tmpe="$(mktemp)"
  OUT="$(AGENT_WATCH_DIR="$4" python3 -c 'import io, runpy, subprocess, sys
sys.stdin = io.StringIO(sys.argv[2])
_run = subprocess.run
def gate(cmd, *a, **k):
    if isinstance(cmd, (list, tuple)) and list(cmd[:3]) == ["git", "-C", sys.argv[3]]:
        raise subprocess.TimeoutExpired(list(cmd), k.get("timeout"))
    return _run(cmd, *a, **k)
subprocess.run = gate
runpy.run_path(sys.argv[1], run_name="__main__")' \
        "$GUARD" "$(mkpayload "$1" "$2" "$3")" "$5" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}
run_gitto Write "$TOTGT/src/app.py" "$TOTGT" "$TORUN" "$TOREAL"
chk_eq "i11 a ledger cwd whose git times out is undecidable, so the write allows" 0 "$RC"
chk_eq "i11 and it is never a DENY" "" "$ERR"
chk_contains "i11 the undecidable identity is announced" "WARN (cto-guard E1)" "$(ctx "$OUT")"
chk_contains "i11 and the warn names the unattributable work tree" "could not be attributed" \
  "$(ctx "$OUT")"
# PAIRED RED-SIDE CONTROL: same fixture, no injected timeout — the row resolves to a DIFFERENT
# repo, so this really is `not` (silent allow). The WARN above comes from the timeout alone.
run Write "$TOTGT/src/app.py" "$TOTGT" "$TORUN"
chk_eq "i11 CONTROL: with that git probe answering, the same write is silently allowed" "0|" \
  "$RC|$ERR$OUT"
# i10 — a CONFIRMED positive still wins over an unresolvable second row (T beats U)
python3 -c 'import json, os, sys
print(json.dumps({"ts": "2026-09-06T00:00:01.000Z", "event": "start", "name": "fixture2",
                  "session_id": "s", "attempt": "a", "cwd": os.path.realpath(sys.argv[1])}))' \
  "$TOTGT" >> "$TORUN/phase-ledger-$(date -u +%Y%m%d).jsonl"
run_gitto Write "$TOTGT/src/app.py" "$TOTGT" "$TORUN" "$TOREAL"
chk_eq "i10 an unresolvable row cannot take back a CONFIRMED ledger positive → DENY" 2 "$RC"
chk_contains "i10 and the deny names the ledger evidence" "phase ledger" "$ERR"

# i12/i13 — THE COST. Liveness is a subprocess per seat, so the predicate must compare repos
# FIRST (a foreign seat costs zero tmux) and every probe it does start must be bounded by the
# REMAINING budget. Driven at the helper: "how many subprocesses did it start" has no hook face.
SLOWBIN="$FIX/slowbin"; mkdir -p "$SLOWBIN"
cat > "$SLOWBIN/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
exec /bin/sleep 30
EOF
chmod +x "$SLOWBIN/tmux"
COST="$(PATH="$SLOWBIN:$PATH" python3 - "$(dirname "$GUARD")" "$FIX" <<'EOF'
import os, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
import identity as m
fix = sys.argv[2]

def repo(path):
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "-C", path, "init", "-q"], check=True)
    return path

def probe(run, target, budget=None):
    if budget is not None:
        m._PREDICATE_BUDGET = budget
    log = os.path.join(run, "tmux-calls")
    os.environ["TMUX_CALL_LOG"] = log
    start = time.monotonic()
    state, _why = m.orchestrated(target, run)
    elapsed = time.monotonic() - start
    calls = sum(1 for ln in open(log) if ln.strip()) if os.path.exists(log) else 0
    return state, calls, elapsed

# i12: two seats, both in a FOREIGN repo. Repo identity decides them; tmux is never asked.
far = repo(os.path.join(fix, "cost-foreign"))
near = repo(os.path.join(fix, "cost-target"))
run12 = os.path.join(fix, "cost-run12")
os.makedirs(run12, exist_ok=True)
for name in ("one", "two"):
    open(os.path.join(run12, name + ".duplex.meta"), "w").write("cwd=%s\n" % far)
state, calls, elapsed = probe(run12, near)
print("i12 %s %d %s" % (state, calls, "fast" if elapsed < 1.0 else "SLOW:%.1f" % elapsed))

# i13: one seat in the SAME repo, so tmux IS asked — and its timeout is the remaining budget,
# not its own 10s. An unanswered liveness probe at the deadline is UNDECIDABLE, never a
# positive nobody proved. The budget is shortened to keep the suite quick; the mechanism under
# test is the deadline being propagated at all.
run13 = os.path.join(fix, "cost-run13")
os.makedirs(run13, exist_ok=True)
open(os.path.join(run13, "mine.duplex.meta"), "w").write("cwd=%s\n" % near)
state, calls, elapsed = probe(run13, near, budget=2.0)
print("i13 %s %d %s" % (state, calls,
                        "bounded" if elapsed < 4.0 else "OVERRUN:%.1f" % elapsed))
EOF
)"
chk_eq "i12 two FOREIGN seats are not-orchestrated with zero tmux subprocesses, sub-second" \
  "i12 not 0 fast" "$(printf '%s\n' "$COST" | grep '^i12 ')"
chk_eq "i13 a same-repo seat whose liveness probe outruns the budget → undecidable, bounded" \
  "i13 undecidable 1 bounded" "$(printf '%s\n' "$COST" | grep '^i13 ')"

# i14 — a seat whose engine ALREADY EXITED is not the live half of anything, and its meta
# outlives it by design (`watchctl._STOP_KEPT`) while the work tree it names is routinely
# removed once the batch ends. Attributing a repo to THAT row made every plain checkout on the
# box undecidable, so E1 warned on exactly the single-agent edits it must be silent about
# (review R2-M3). The rc file is the FREE half of the liveness predicate, so a retired row is
# dropped before even a `git rev-parse` is spent on it.
rm -f "$RUN"/*.duplex.meta "$RUN"/*.duplex.rc
RETIRED="$FIX/removed-worktree"          # deliberately never created: the worktree is gone
seat_meta ended "$RETIRED" 0
STATE="$(python3 -c 'import sys
sys.path.insert(0, sys.argv[1])
import identity as m
print(m.orchestrated(sys.argv[2], sys.argv[3])[0])' "$(dirname "$GUARD")" "$NOORCH" "$RUN")"
chk_eq "(i14) an ENDED seat naming a removed work tree is no evidence at all" "not" "$STATE"
run Edit "$NOORCH/src/app.py" "$NOORCH"
chk_eq "(i14) so E1 stays silent on the plain repo (exit 0)" 0 "$RC"
chk_eq "(i14) and says nothing at all" "" "$ERR$OUT"
# PAIRED RED-SIDE CONTROL: the SAME row with its rc file removed is a seat nobody can rule
# out, so the unresolvable work tree is undecidable again and the WARN comes back. The rc
# evidence is what buys the silence above, not the row's shape.
seat_meta ended "$RETIRED"
run Edit "$NOORCH/src/app.py" "$NOORCH"
chk_eq "(i14) CONTROL: with no rc evidence that row is undecidable, so E1 allows and warns" \
  0 "$RC"
chk_contains "(i14) CONTROL: and the warn is what the rc evidence removes" \
  "could not be attributed" "$(ctx "$OUT")"
rm -f "$RUN"/ended.duplex.*

summary
