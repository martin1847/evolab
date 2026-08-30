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

summary
