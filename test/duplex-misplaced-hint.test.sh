#!/usr/bin/env bash
# duplexctl classify — misplaced-deliverable hint under IDLE-NO-DELIVERABLE.
#
# Field incident (external seat, 2026-08-18): worker and reviewer wrote their file into
# the session cwd ROOT under the declared BASENAME while the declaration named a path one
# directory deeper. The gate read IDLE-NO-DELIVERABLE 6, the orchestrator read "no
# output", stopped the seat and re-dispatched — a review carrying a BLOCKER was never
# consumed. The bytes were on disk the whole time, one directory away.
#
# What is pinned here (observability only — no exit code, no state, no receipt moves):
#   A. the incident shape produces the hint on BOTH emit points (engine exited rc=0 and
#      live-idle), driven through the real classify verdict path, never the helper alone
#   B. the typed-line surface is injection-proof: a filename holding a newline cannot
#      forge a second typed line (json.dumps encoding, asserted line by line)
#   C. the traversal bounds are real: 3 shown + counted remainder, entry cap wording,
#      depth-4 invisible, symlinks and dotted names are never candidates — each with a
#      positive control in the SAME fixture, so a dead scanner cannot pass as a bound
#   D. the negative path is byte-identical to the pre-change verdict (inline golden)
#   E. fail-safe: an injected non-OSError scan fault degrades to exactly that golden on
#      both branches, and the same fixture WITHOUT the injection does hint (the meter is
#      proven to see something before its blindness is called a feature)
#
# Harness: no engines, no real tmux — classify driven on hand-built session state (same
# stance as duplex-verdict-gaps.test.sh). Fault injection is BLACK BOX: a sitecustomize
# on PYTHONPATH breaks os.scandir for the whole interpreter, so no product knob exists
# for tests to lean on. duplexctl calls os.scandir in exactly one place (the scanner),
# which is what makes that injection surgical.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DUPLEXCTL="$AW_DIR/duplexctl.py"

seed() { # $1 name  $2 engine  $3 cwd  [$4 deliverable glob]
  { printf 'engine=%s\ncwd=%s\n' "$2" "$3"
    [ -n "${4:-}" ] && printf 'deliverable=%s\n' "$4"
  } > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  mkfifo "$WATCH_RUN_DIR/$1.duplex.in" 2>/dev/null || true
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
}
exited()  { printf '0\n' > "$WATCH_RUN_DIR/$1.duplex.rc"; }          # branch A: rc=0 on disk
went_idle() { # branch B: a claude result frame with a live pane projects IDLE
  printf '%s\n' '{"type":"result","is_error":false,"result":"turn done"}' \
    >> "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
}

OUT="" ; ERR=""
run_c() { # $1 session [$2.. env assignments] — stdout to $OUT, rc in $rc
  env "${@:2}" python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify "$1" \
    > "$OUT" 2> "$ERR"; rc=$?
}
enc() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
verdict_exited() { printf "IDLE-NO-DELIVERABLE: engine exited rc=0 but '%s' not produced this round\n" "$1"; }
verdict_idle() { printf "IDLE-NO-DELIVERABLE: engine idle but '%s' not produced this round — steer the agent; do not stop\n" "$1"; }
lines_of() { wc -l < "$1" | tr -d ' '; }
# every typed prefix duplexctl can emit — none may appear below line 1
typed_below_first() {
  awk 'NR>1 && /^(DONE|FAILED|AGENT-DEAD|IDENTITY-UNKNOWN|WAITING-INPUT|STALLED-EXTERNAL|STALLED-STREAM|IDLE-NO-DELIVERABLE|RUNNING|WATCH-TIMEOUT|ENGINE-SILENT|BUDGET-EXHAUSTED|SUPERVISOR-LOST):/ {c++} END {print c+0}' "$1"
}
cmp_full() { # $1 label  $2 expected-file — BYTE-exact whole stdout, not a contains
  if cmp -s "$2" "$OUT"; then _record "$1" 1
  else _record "$1" 0 "stdout differs: $(diff "$2" "$OUT" | tr '\n' '|')"; fi
}
first_line() { sed -n '1p' "$1"; }

sandbox_new
# The hint prints os.path.abspath output, so the fixture roots this suite builds its
# expectations from must be normalized THE SAME WAY (a TMPDIR ending in "/" otherwise
# leaves a "//" the product collapses and the expectation does not — the one
# normalization in this file, and it is on the fixture side, never on the observed
# stdout: goldens below are compared byte for byte, unedited).
SANDBOX="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$SANDBOX")"
export FAKE_TMUX_HASSESSION=0   # pane alive: classify must reach the projector
OUT="$SANDBOX/out.txt"; ERR="$SANDBOX/err.txt"

# black-box fault injection: os.scandir raises a NON-OSError, so it can only be caught
# by the scanner's blanket fail-safe arm (its inner OSError arm would mask the point)
INJ="$SANDBOX/inject"; mkdir -p "$INJ"
cat > "$INJ/sitecustomize.py" <<'PY'
import os
def _boom(*_a, **_k):
    raise RuntimeError("injected scan fault")
os.scandir = _boom
PY

echo "== A. incident shape: same-basename file in the cwd root, both emit points =="

WTA="$SANDBOX/wtA"; mkdir -p "$WTA/docs/orchestration"
DECL_A="$WTA/docs/orchestration/RESULT.md"          # declared, absolute, ABSENT
MIS_A="$WTA/RESULT.md"                              # what the agent actually wrote
printf 'the review nobody read\n' > "$MIS_A"
HINT_A="possible misplaced deliverable: $(enc "$MIS_A")"

# mark_fresh AFTER seeding: seed stamps this round's epoch, and a candidate is only a
# candidate when it is at least as new as that epoch (the incident file was written
# during the round). Every block below seeds first, then marks.
mark_fresh() { touch "$@"; }

seed mhA1 claude "$WTA" "$DECL_A"; exited mhA1; mark_fresh "$MIS_A"
run_c mhA1
chk_eq "A1 exited-rc0 branch still exits 6" 6 "$rc"
chk_eq "A1 the original verdict line is untouched, still line 1" \
  "$(verdict_exited "$DECL_A")" "$(first_line "$OUT")"
chk_contains "A1 hint names the misplaced file, json-encoded" "$HINT_A" "$(cat "$OUT")"
{ verdict_exited "$DECL_A"; printf '%s\n' "$HINT_A"; } > "$SANDBOX/exp-A1.txt"
cmp_full "A1 stdout is exactly verdict + one hint" "$SANDBOX/exp-A1.txt"

seed mhA2 claude "$WTA" "$DECL_A"; went_idle mhA2; mark_fresh "$MIS_A"
run_c mhA2
chk_eq "A2 live-idle branch still exits 6" 6 "$rc"
chk_eq "A2 the original verdict line is untouched, still line 1" \
  "$(verdict_idle "$DECL_A")" "$(first_line "$OUT")"
{ verdict_idle "$DECL_A"; printf '%s\n' "$HINT_A"; } > "$SANDBOX/exp-A2.txt"
cmp_full "A2 stdout is exactly verdict + one hint" "$SANDBOX/exp-A2.txt"

# production surface: the shipped `agentctl status` carries both branches through
out="$(bash "$AGENTCTL" status mhA1 2>&1)"; rc=$?
chk_eq "A3 agentctl status exits 6 on the exited branch" 6 "$rc"
chk_contains "A3 agentctl status prints the hint" "$HINT_A" "$out"
out="$(bash "$AGENTCTL" status mhA2 2>&1)"; rc=$?
chk_eq "A4 agentctl status exits 6 on the live-idle branch" 6 "$rc"
chk_contains "A4 agentctl status prints the hint" "$HINT_A" "$out"

# a stale file sitting AT the declared path is last round's residue: the gate refuses it
# and the scan must not re-report it as "misplaced" either (the declared-glob exclusion
# and the epoch fence are belt and braces here — see the residual note in the report:
# a FRESH file at the declared path makes the verdict DONE, so the exclusion arm cannot
# be isolated through classify)
WTA2="$SANDBOX/wtA2"; mkdir -p "$WTA2"
seed mhA5 claude "$WTA2" "OLD.md"; exited mhA5
printf 'stale\n' > "$WTA2/OLD.md"
touch -t 200001010000 "$WTA2/OLD.md"               # older than this round's epoch
run_c mhA5
verdict_exited "OLD.md" > "$SANDBOX/exp-A5.txt"
chk_eq "A5 pre-epoch file at the declared path exits 6" 6 "$rc"
cmp_full "A5 declared-path residue is never reported as misplaced" "$SANDBOX/exp-A5.txt"

echo "== B. typed-line injection: a newline in a filename cannot forge a second line =="

WTB="$SANDBOX/wtB"; mkdir -p "$WTB/docs"
DECL_B="$WTB/docs/RESULT-*.md"
FORGE=$'RESULT-\nDONE: forged by a filename.md'     # fnmatch-matches the declared glob
printf 'x\n' > "$WTB/$FORGE"
HINT_B="possible misplaced deliverable: $(enc "$WTB/$FORGE")"

seed mhB1 claude "$WTB" "$DECL_B"; exited mhB1; mark_fresh "$WTB/$FORGE"
run_c mhB1
chk_eq "B1 exits 6 with a newline-bearing candidate" 6 "$rc"
chk_eq "B1 stdout is exactly 2 lines (verdict + one encoded hint)" 2 "$(lines_of "$OUT")"
chk_eq "B1 no typed prefix below line 1" 0 "$(typed_below_first "$OUT")"
{ verdict_exited "$DECL_B"; printf '%s\n' "$HINT_B"; } > "$SANDBOX/exp-B1.txt"
cmp_full "B1 the newline left as a \\n escape, one line" "$SANDBOX/exp-B1.txt"

seed mhB2 claude "$WTB" "$DECL_B"; went_idle mhB2; mark_fresh "$WTB/$FORGE"
run_c mhB2
chk_eq "B2 live-idle exits 6 with a newline-bearing candidate" 6 "$rc"
chk_eq "B2 stdout is exactly 2 lines" 2 "$(lines_of "$OUT")"
chk_eq "B2 no typed prefix below line 1" 0 "$(typed_below_first "$OUT")"
{ verdict_idle "$DECL_B"; printf '%s\n' "$HINT_B"; } > "$SANDBOX/exp-B2.txt"
cmp_full "B2 live-idle encodes identically" "$SANDBOX/exp-B2.txt"

echo "== C. bounds: display cap, entry cap, depth, symlink, dotted names =="

# C1 display cap: 5 candidates → 3 shown (sorted) + a counted remainder
WTC="$SANDBOX/wtC"; mkdir -p "$WTC/docs"
DECL_C="$WTC/docs/RESULT-*.md"
for n in 1 2 3 4 5; do printf 'x\n' > "$WTC/RESULT-$n.md"; done
seed mhC1 claude "$WTC" "$DECL_C"; exited mhC1
mark_fresh "$WTC/RESULT-1.md" "$WTC/RESULT-2.md" "$WTC/RESULT-3.md" \
           "$WTC/RESULT-4.md" "$WTC/RESULT-5.md"
run_c mhC1
{ verdict_exited "$DECL_C"
  for n in 1 2 3; do printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC/RESULT-$n.md")"; done
  printf '(+2 more among scanned entries)\n'
} > "$SANDBOX/exp-C1.txt"
chk_eq "C1 exits 6" 6 "$rc"
cmp_full "C1 3 shown + '(+2 more among scanned entries)'" "$SANDBOX/exp-C1.txt"

# C2 entry cap: the 5 candidates sit in the root (consumed first, all of them), a bulk
# subdir then exhausts the remaining budget → the remainder line must say so
WTC2="$SANDBOX/wtC2"; mkdir -p "$WTC2/docs" "$WTC2/bulk"
DECL_C2="$WTC2/docs/RESULT-*.md"
for n in 1 2 3 4 5; do printf 'x\n' > "$WTC2/RESULT-$n.md"; done
python3 -c 'import sys,os
d = sys.argv[1]
for i in range(2100):
    open(os.path.join(d, "filler-%04d.txt" % i), "w").close()' "$WTC2/bulk"
chk_eq "C2 fixture really exceeds the 2000-entry budget" 2100 \
  "$(python3 -c 'import os,sys;print(len(os.listdir(sys.argv[1])))' "$WTC2/bulk")"
seed mhC2 claude "$WTC2" "$DECL_C2"; exited mhC2
mark_fresh "$WTC2/RESULT-1.md" "$WTC2/RESULT-2.md" "$WTC2/RESULT-3.md" \
           "$WTC2/RESULT-4.md" "$WTC2/RESULT-5.md"
run_c mhC2
{ verdict_exited "$DECL_C2"
  for n in 1 2 3; do printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC2/RESULT-$n.md")"; done
  printf '(+2 more among scanned entries; scan capped)\n'
} > "$SANDBOX/exp-C2.txt"
chk_eq "C2 exits 6" 6 "$rc"
cmp_full "C2 capped scan refuses to claim a precise total" "$SANDBOX/exp-C2.txt"

# C3 depth: a match 4 directory levels down is out of range; the SAME fixture at depth 3
# is in range (the positive control that keeps "no hint" from meaning "scanner dead")
WTC3="$SANDBOX/wtC3"; mkdir -p "$WTC3/docs" "$WTC3/d1/d2/d3/d4"
DECL_C3="$WTC3/docs/RESULT.md"
printf 'x\n' > "$WTC3/d1/d2/d3/d4/RESULT.md"
seed mhC3 claude "$WTC3" "$DECL_C3"; exited mhC3
run_c mhC3
verdict_exited "$DECL_C3" > "$SANDBOX/exp-C3.txt"
chk_eq "C3 exits 6" 6 "$rc"
cmp_full "C3 depth-4 match is never scanned (no hint at all)" "$SANDBOX/exp-C3.txt"
printf 'x\n' > "$WTC3/d1/d2/d3/RESULT.md"
run_c mhC3
{ verdict_exited "$DECL_C3"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC3/d1/d2/d3/RESULT.md")"
} > "$SANDBOX/exp-C3b.txt"
cmp_full "C3b same fixture at depth 3 does hint (bound, not blindness)" "$SANDBOX/exp-C3b.txt"

# C4 symlinks and dotted names are never candidates, and are not followed
WTC4="$SANDBOX/wtC4"; mkdir -p "$WTC4/docs" "$SANDBOX/outside/nested"
DECL_C4="$WTC4/docs/RESULT.md"
printf 'x\n' > "$SANDBOX/outside/RESULT.md"
printf 'x\n' > "$SANDBOX/outside/nested/RESULT.md"
ln -s "$SANDBOX/outside/RESULT.md" "$WTC4/RESULT.md"        # file symlink
ln -s "$SANDBOX/outside/nested" "$WTC4/linkdir"             # directory symlink
mkdir -p "$WTC4/.hidden"
printf 'x\n' > "$WTC4/.hidden/RESULT.md"                    # dotted dir
printf 'x\n' > "$WTC4/.RESULT.md"                           # dotted file — see C6 for the
                                                            # non-vacuous dotfile arm
seed mhC4 claude "$WTC4" "$DECL_C4"; exited mhC4
run_c mhC4
verdict_exited "$DECL_C4" > "$SANDBOX/exp-C4.txt"
chk_eq "C4 exits 6" 6 "$rc"
cmp_full "C4 symlinks (file+dir) and a dotted dir yield no candidate" "$SANDBOX/exp-C4.txt"
printf 'x\n' > "$WTC4/real-RESULT-probe.md"                 # name mismatch: still nothing
run_c mhC4
cmp_full "C4b a non-matching regular file changes nothing" "$SANDBOX/exp-C4.txt"
rm -f "$WTC4/RESULT.md"                                     # drop the symlink…
printf 'x\n' > "$WTC4/RESULT.md"                            # …and put a REAL file there
run_c mhC4
{ verdict_exited "$DECL_C4"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC4/RESULT.md")"
} > "$SANDBOX/exp-C4c.txt"
cmp_full "C4c the same path as a regular file does hint (positive control)" "$SANDBOX/exp-C4c.txt"

# C5 freshness: a same-basename file OLDER than this round's epoch is last round's
# residue, not this round's misplaced output
WTC5="$SANDBOX/wtC5"; mkdir -p "$WTC5/docs"
DECL_C5="$WTC5/docs/RESULT.md"
printf 'x\n' > "$WTC5/RESULT.md"
seed mhC5 claude "$WTC5" "$DECL_C5"; exited mhC5
touch -t 200001010000 "$WTC5/RESULT.md"
run_c mhC5
verdict_exited "$DECL_C5" > "$SANDBOX/exp-C5.txt"
chk_eq "C5 exits 6" 6 "$rc"
cmp_full "C5 pre-epoch residue is not reported" "$SANDBOX/exp-C5.txt"
touch "$WTC5/RESULT.md"
run_c mhC5
{ verdict_exited "$DECL_C5"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC5/RESULT.md")"
} > "$SANDBOX/exp-C5b.txt"
cmp_full "C5b the same file, touched this round, does hint" "$SANDBOX/exp-C5b.txt"

# C6 dotted names, with a declared basename that DOES fnmatch a dotfile (R1 M1: the C4
# fixture declared `RESULT.md`, so `.RESULT.md` was rejected by fnmatch and the hidden-name
# arm could be deleted from the product while this suite stayed green). `*.md` matches
# `.hidden-RESULT.md` under fnmatch — only the hidden-name rule can keep it out.
WTC6="$SANDBOX/wtC6"; mkdir -p "$WTC6/docs" "$WTC6/.hid"
DECL_C6="$WTC6/docs/*.md"
seed mhC6 claude "$WTC6" "$DECL_C6"; exited mhC6
printf 'x\n' > "$WTC6/.hidden-RESULT.md"                    # dotted FILE, fnmatch-matching
printf 'x\n' > "$WTC6/.hid/inside.md"                       # inside a dotted DIR, matching
printf 'x\n' > "$WTC6/visible.md"                           # the positive control
run_c mhC6
{ verdict_exited "$DECL_C6"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTC6/visible.md")"
} > "$SANDBOX/exp-C6.txt"
chk_eq "C6 exits 6" 6 "$rc"
cmp_full "C6 dotfile and dotted-dir matches stay out; the visible one is reported" \
  "$SANDBOX/exp-C6.txt"

echo "== D. negative golden: no candidate → byte-identical to the pre-change verdict =="

# The declared glob is RELATIVE here on purpose: the verdict line then carries no temp
# path, so the golden is inline literal text with NOTHING normalized away.
WTD="$SANDBOX/wtD"; mkdir -p "$WTD/docs"
printf 'notes\n' > "$WTD/NOTES.md"          # scanned, rejected: proves the scan ran
printf "IDLE-NO-DELIVERABLE: engine exited rc=0 but 'docs/RESULT.md' not produced this round\n" \
  > "$SANDBOX/golden-exited.txt"
printf "IDLE-NO-DELIVERABLE: engine idle but 'docs/RESULT.md' not produced this round — steer the agent; do not stop\n" \
  > "$SANDBOX/golden-idle.txt"

seed mhD1 claude "$WTD" "docs/RESULT.md"; exited mhD1
run_c mhD1
chk_eq "D1 exits 6" 6 "$rc"
cmp_full "D1 exited-branch stdout is the bare verdict, byte for byte" "$SANDBOX/golden-exited.txt"
seed mhD2 claude "$WTD" "docs/RESULT.md"; went_idle mhD2
run_c mhD2
chk_eq "D2 exits 6" 6 "$rc"
cmp_full "D2 live-idle stdout is the bare verdict, byte for byte" "$SANDBOX/golden-idle.txt"

echo "== E. fail-safe: an injected scan fault reads exactly like a clean cwd =="

WTE="$SANDBOX/wtE"; mkdir -p "$WTE/docs"
printf 'the misplaced file\n' > "$WTE/RESULT.md"
HINT_E="possible misplaced deliverable: $(enc "$WTE/RESULT.md")"

seed mhE1 claude "$WTE" "docs/RESULT.md"; exited mhE1; mark_fresh "$WTE/RESULT.md"
run_c mhE1
chk_contains "E1 meter positive: uninjected, the same fixture DOES hint" "$HINT_E" "$(cat "$OUT")"
run_c mhE1 "PYTHONPATH=$INJ"
chk_eq "E1 injected exited-branch still exits 6" 6 "$rc"
cmp_full "E1 injected scan degrades to the D1 golden, byte for byte" "$SANDBOX/golden-exited.txt"

seed mhE2 claude "$WTE" "docs/RESULT.md"; went_idle mhE2; mark_fresh "$WTE/RESULT.md"
run_c mhE2
chk_contains "E2 meter positive: uninjected live-idle DOES hint" "$HINT_E" "$(cat "$OUT")"
run_c mhE2 "PYTHONPATH=$INJ"
chk_eq "E2 injected live-idle still exits 6" 6 "$rc"
cmp_full "E2 injected scan degrades to the D2 golden, byte for byte" "$SANDBOX/golden-idle.txt"

# the injection must be the SCANNER's fault, not a broken interpreter: a DONE verdict
# still comes out clean under it (otherwise E1/E2 would pass vacuously)
seed mhE3 claude "$WTE" "docs/RESULT.md"; exited mhE3
printf 'x\n' > "$WTE/docs/RESULT.md"        # written AFTER the epoch → the gate is satisfied
run_c mhE3 "PYTHONPATH=$INJ"
chk_eq "E3 injection does not disturb an unrelated verdict (rc 0)" 0 "$rc"
chk_contains "E3 and that verdict is DONE" "DONE: engine exited rc=0" "$(cat "$OUT")"

echo "== F. B1: the published (watch) detail truncates by LINE, never mid-JSON =="

# R1 B1: identity published `detail[:600]`, so a long cwd handed the DEFAULT consumer
# (supervised watch replaying the terminal record) a half-cut json.dumps payload — the hint
# became unparseable at exactly the moment a reader wanted the path.
# R2 B1: clipping only the classify half and THEN appending the writer's receipt display line
# left the field — the thing `watch-state` actually replays — past 600 with the marker no
# longer last. The oracle below therefore measures the WHOLE field: `len <= 600`, every line
# whole, and the marker (when present) as the LAST line. Under pressure the tail goes first,
# so the receipt display line is dropped before any hint line — it is a rendering of
# structural fields the receipt readers consume directly, the hint is the payload.
cat > "$SANDBOX/lines.py" <<'PY'
import json, sys
RE_MARK = "…[detail truncated"
RE_BUILT = "receipt (rebuilt from record fields): "
RE_RCPT = "terminal record published ("
raw = open(sys.argv[1], encoding="utf-8").read()
bound = int(sys.argv[2]) if len(sys.argv) > 2 else 0
bad, marks, receipt, rebuilt = [], 0, 0, 0
# exactly ONE trailing newline is allowed (the transport one a `printf '%s\n'` capture adds);
# anything beyond it is a stray blank line and must be observable (impl review R3 minor 1)
text = raw[:-1] if raw.endswith("\n") else raw
if text.endswith("\n"):
    bad.append("extra-trailing-blank-line")
    text = text.rstrip("\n")
lines = text.split("\n")
for i, ln in enumerate(lines):
    last = i == len(lines) - 1
    if ln.startswith("possible misplaced deliverable: "):
        try:
            path = json.loads(ln.split(": ", 1)[1])
        except Exception:
            bad.append("unparsable-json-line:%d" % i)
            continue
        if not path.startswith("/"):
            bad.append("not-absolute:%d" % i)
    elif ln.startswith(RE_MARK):
        marks += 1
        # the marker ends the STORED field; on a replay one rebuilt receipt line may follow it
        if not last and not (i == len(lines) - 2 and lines[-1].startswith(RE_BUILT)):
            bad.append("marker-not-last:%d/%d" % (i, len(lines) - 1))
    elif ln.startswith(RE_BUILT):
        rebuilt += 1
        if not last:
            bad.append("rebuilt-not-last:%d/%d" % (i, len(lines) - 1))
    elif ln.startswith(RE_RCPT):
        receipt += 1
    elif i == 0 and ln.startswith("IDLE-NO-DELIVERABLE:"):
        pass
    elif ln.startswith("(+") and ln.endswith(")"):
        pass
    else:
        bad.append("stray-line:%d:%s" % (i, ln[:40]))
# the DETAIL_MAX bound is about the STORED field, so a rebuilt tail line is not charged to it
stored = "\n".join(lines[:-1]) if rebuilt else text
if bound and len(stored) > bound:
    bad.append("over-bound:%d" % len(stored))
print(" ".join(bad) if bad else "LINES_OK n=%d mark=%d receipt=%d rebuilt=%d"
      % (len(lines), marks, receipt, rebuilt))
PY
detail_to() { # $1 terminal.json  $2 dest file — the published detail, verbatim
  python3 -c 'import json,sys
open(sys.argv[2], "w", encoding="utf-8").write(json.load(open(sys.argv[1]))["detail"])' "$1" "$2"
}
head_to() { # $1 text file  $2 dest — the CLASSIFY portion: everything above the receipt line
  python3 -c 'import sys
out = []
for ln in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if ln.startswith("terminal record published ("):
        break
    out.append(ln)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")' "$1" "$2"
}
MARK="…[detail truncated; run agentctl status <session> for full lines]"
publish_detail() { # $1 session  $2 file — publish that text as the record's detail (rc 6)
  local armed
  armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token "$1")"
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish "$1" --armed "$armed" \
    --rc 6 --round 0 --detail "$(cat "$2")" >/dev/null 2>&1
}
publish_classify() { publish_detail "$1" "$OUT"; }   # this round's classify stdout

# a legal deep cwd (three 110-char components) with TWO candidates: the encoded payload is
# far past 600, so the record MUST drop a whole line rather than cut one
L110="$(python3 -c 'print("d"*110)')"
WTF="$SANDBOX/$L110/$L110/$L110"; mkdir -p "$WTF/docs"
seed mhF1 claude "$WTF" "docs/RESULT-*.md"; exited mhF1
printf 'x\n' > "$WTF/RESULT-1.md"; printf 'x\n' > "$WTF/RESULT-2.md"
mark_fresh "$WTF/RESULT-1.md" "$WTF/RESULT-2.md"
run_c mhF1
chk_eq "F1 long-path classify still exits 6" 6 "$rc"
chk_eq "F1 raw classify stdout really overruns the record bound" over \
  "$(python3 -c 'import sys;t=open(sys.argv[1]).read().rstrip("\n");print("over" if len(t)>600 else "under:%d"%len(t))' "$OUT")"
chk_eq "F1 and every raw line is whole JSON" "LINES_OK n=3 mark=0 receipt=0 rebuilt=0" \
  "$(python3 "$SANDBOX/lines.py" "$OUT")"
publish_classify mhF1
chk_eq "F1 publish accepted the conclusion" 0 "$?"
detail_to "$WATCH_RUN_DIR/mhF1.terminal.json" "$SANDBOX/detail-F1.txt"
# the WHOLE field is measured here: bound, line-wholeness, marker last. Under this pressure
# the receipt display line is the first casualty (receipt=0), the hint survives.
chk_eq "F1 the RECORD field is <=600, line-whole, marker last" \
  "LINES_OK n=3 mark=1 receipt=0 rebuilt=0" \
  "$(python3 "$SANDBOX/lines.py" "$SANDBOX/detail-F1.txt" 600)"
chk_contains "F1 the surviving hint line is intact, not cut" \
  "possible misplaced deliverable: $(enc "$WTF/RESULT-1.md")" "$(cat "$SANDBOX/detail-F1.txt")"
chk_not_contains "F1 the dropped hint left no fragment behind" \
  "RESULT-2.md" "$(cat "$SANDBOX/detail-F1.txt")"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state mhF1 --arm 2>&1)"; rc=$?
chk_eq "F1 watch-state replays the record as rc 6" 6 "$rc"
printf '%s\n' "$out" > "$SANDBOX/replay-F1.txt"
# the replay adds ONE line the stored field lost: the receipt summary, rebuilt from structural
# fields. Without it a replaying waiter would be the only surface with no receipt at all
# (impl review R3 — `receipt_note` lives on the classify/adopt DONE path, not here).
chk_eq "F1 the REPLAY is the bounded field plus one rebuilt receipt line" \
  "LINES_OK n=4 mark=1 receipt=0 rebuilt=1" \
  "$(python3 "$SANDBOX/lines.py" "$SANDBOX/replay-F1.txt" 600)"
chk_eq "F1 the rebuilt line agrees with the record's structural fields" \
  "reason=GLOB phase=-" \
  "$(python3 -c 'import sys
built = [ln for ln in open(sys.argv[1], encoding="utf-8").read().split(chr(10))
         if ln.startswith("receipt (rebuilt from record fields): ")]
bits = built[0].split(": ", 1)[1].split() if built else ["MISSING"]
print(" ".join(b for b in bits if b.startswith(("reason=", "phase="))))' \
     "$SANDBOX/replay-F1.txt")"
chk_contains "F1 replay carries the truncation marker verbatim" "$MARK" "$out"
# byte level: the stored field is EXACTLY classify's first two lines plus the marker
{ sed -n '1,2p' "$OUT"; printf '%s\n' "$MARK"; } > "$SANDBOX/exp-detail-F1.txt"
printf '\n' >> "$SANDBOX/detail-F1.txt"        # the field carries no trailing newline
chk_eq "F1 stored field == classify lines 1-2 + marker, byte for byte" ok \
  "$(cmp -s "$SANDBOX/exp-detail-F1.txt" "$SANDBOX/detail-F1.txt" && echo ok || echo differs)"
# …and dropping that display line costs the record NOTHING structural: class / rc / reason /
# round live in their own fields and the receipt reader works off those, never off this text
# (R2 blast-radius axis). `struct_of` prints the record's structural triple plus what the
# canonical receipt reader answers, so F1 (line dropped) and F2 (line kept) can be compared
# as a pair. The IDENTITY-UNKNOWN verdict is this harness talking, not the truncation: with a
# faked tmux there is no pane incarnation to tie the stamp to, and BOTH sides say it.
struct_of() { # $1 session — one line: record fields + receipt-reader answer + its exit code
  local vrc
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity receipt "$1" \
    > "$SANDBOX/rcpt-$1.json" 2>&1; vrc=$?
  python3 -c 'import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
v = json.load(open(sys.argv[2], encoding="utf-8"))
print("rc=%s class=%s reason=%s round=%s verdict=%s receipt=%s view_rc=%s"
      % (m["rc"], m["class"], m.get("reason") or "-", m.get("round"),
         v.get("verdict"), v.get("receipt"), sys.argv[3]))' \
    "$WATCH_RUN_DIR/$1.terminal.json" "$SANDBOX/rcpt-$1.json" "$vrc"
}
# `reason` is itself structural and fixture-dependent (a glob declaration reports GLOB, a
# single missing path MISSING) — pinned per fixture below, which is exactly the point: the
# truncation moves neither.
STRUCT_TAIL="round=0 verdict=IDENTITY-UNKNOWN receipt=legacy view_rc=3"
chk_eq "F1 structural fields and the receipt reader are untouched by the dropped line" \
  "rc=6 class=IDLE-NO-DELIVERABLE reason=GLOB $STRUCT_TAIL" "$(struct_of mhF1)"

# paired control: a detail that FITS is published verbatim — no marker, nothing dropped
WTF2="$SANDBOX/wtF2"; mkdir -p "$WTF2/docs"
seed mhF2 claude "$WTF2" "docs/RESULT.md"; exited mhF2
printf 'x\n' > "$WTF2/RESULT.md"; mark_fresh "$WTF2/RESULT.md"
run_c mhF2
publish_classify mhF2
detail_to "$WATCH_RUN_DIR/mhF2.terminal.json" "$SANDBOX/detail-F2.txt"
chk_eq "F2 a short detail publishes verbatim: no marker, receipt line kept" \
  "LINES_OK n=3 mark=0 receipt=1 rebuilt=0" \
  "$(python3 "$SANDBOX/lines.py" "$SANDBOX/detail-F2.txt" 600)"
head_to "$SANDBOX/detail-F2.txt" "$SANDBOX/head-F2.txt"
chk_eq "F2 and its classify portion is byte-identical to the classify stdout" ok \
  "$(cmp -s "$OUT" "$SANDBOX/head-F2.txt" && echo ok || echo differs)"
chk_eq "F2 PAIRED with F1: same structural answer when nothing was dropped" \
  "rc=6 class=IDLE-NO-DELIVERABLE reason=MISSING $STRUCT_TAIL" "$(struct_of mhF2)"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state mhF2 --arm 2>&1)"; rc=$?
printf '%s\n' "$out" > "$SANDBOX/replay-F2.txt"
# PAIRED CONTROL for the rebuild: nothing was dropped, so the replay keeps the record's own
# receipt line and NO rebuilt line is added — the summary must never appear twice
chk_eq "F2 the unpressured replay keeps its receipt line and gains no rebuilt one" \
  "6 LINES_OK n=3 mark=0 receipt=1 rebuilt=0" \
  "$rc $(python3 "$SANDBOX/lines.py" "$SANDBOX/replay-F2.txt" 600)"

# F3 is the R2 reviewer's exact repro, replayed as a regression: a 530-char first line plus one
# long hint, published through the production write API. Before this round the record measured
# 758 chars with the marker at index 1 and the receipt display line last; the field is now
# 596 = 530 (kept prose line) + 1 + 65 (marker), and the marker is last. The detail is
# synthetic on purpose — no temp path enters it, so the length is an exact, portable oracle.
python3 -c 'import json
print("IDLE-NO-DELIVERABLE: " + "v" * 509)
print("possible misplaced deliverable: " + json.dumps("/" + "p" * 300 + "/RESULT.md"))' \
  > "$SANDBOX/f3-detail.txt"
chk_eq "F3 the repro input is the reviewer's shape (530-char line 1, 876 total)" "530 876" \
  "$(python3 -c 'import sys
t = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
print("%d %d" % (len(t.split(chr(10))[0]), len(t)))' "$SANDBOX/f3-detail.txt")"
WTF3="$SANDBOX/wtF3"; mkdir -p "$WTF3"
seed mhF3 claude "$WTF3" "docs/RESULT.md"
publish_detail mhF3 "$SANDBOX/f3-detail.txt"
chk_eq "F3 publish accepted the conclusion" 0 "$?"
detail_to "$WATCH_RUN_DIR/mhF3.terminal.json" "$SANDBOX/detail-F3.txt"
chk_eq "F3 the record field is bounded and marker-last (was 758 before R3)" \
  "LINES_OK n=2 mark=1 receipt=0 rebuilt=0" \
  "$(python3 "$SANDBOX/lines.py" "$SANDBOX/detail-F3.txt" 600)"
chk_eq "F3 and its exact length is the documented arithmetic" 596 \
  "$(python3 -c 'import sys;print(len(open(sys.argv[1], encoding="utf-8").read()))' \
     "$SANDBOX/detail-F3.txt")"
# BOTH public replay entry points, because both are what a killed waiter comes back through:
# `watch-state --arm` (canonical read) and `watch-arm-read` (the arm-time recovery wrapper).
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state mhF3 --arm 2>&1)"; rc=$?
printf '%s\n' "$out" > "$SANDBOX/replay-F3.txt"
chk_eq "F3 watch-state replays the bounded field plus the rebuilt receipt line" \
  "6 LINES_OK n=3 mark=1 receipt=0 rebuilt=1" \
  "$rc $(python3 "$SANDBOX/lines.py" "$SANDBOX/replay-F3.txt" 600)"
chk_eq "F3 the rebuilt summary agrees with the record's structural fields" \
  "reason=MISSING phase=-" \
  "$(python3 -c 'import sys
built = [ln for ln in open(sys.argv[1], encoding="utf-8").read().split(chr(10))
         if ln.startswith("receipt (rebuilt from record fields): ")]
bits = built[0].split(": ", 1)[1].split() if built else ["MISSING-LINE"]
print(" ".join(b for b in bits if b.startswith(("reason=", "phase="))))' \
     "$SANDBOX/replay-F3.txt")"
chk_eq "F3 the rebuilt reason AND phase ARE the record's fields, not test literals" ok \
  "$(python3 -c 'import json,sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
built = [ln for ln in open(sys.argv[2], encoding="utf-8").read().split(chr(10))
         if ln.startswith("receipt (rebuilt from record fields): ")]
bits = built[0].split() if built else []
want = ["reason=%s" % rec.get("reason"), "phase=%s" % (rec.get("phase") or "-")]
missing = [w for w in want if w not in bits]
print("ok" if built and not missing else "differs:%s" % ",".join(missing or ["no-line"]))' \
     "$WATCH_RUN_DIR/mhF3.terminal.json" "$SANDBOX/replay-F3.txt")"
# the OTHER public replay entry point must produce the SAME line, byte for byte — the one
# already checked against the record's fields above, not merely something reason-shaped.
# A missing line yields a sentinel, never the empty string: `chk_contains ""` passes against
# anything, and the mutation probe caught exactly that vacuity here.
f3_built="$(python3 -c 'import sys
for ln in open(sys.argv[1], encoding="utf-8").read().split(chr(10)):
    if ln.startswith("receipt (rebuilt from record fields): "):
        print(ln)
        break
else:
    print("NO-REBUILT-LINE-IN-THE-CANONICAL-REPLAY")' "$SANDBOX/replay-F3.txt")"
# watch-arm-read LAST: reporting a non-DONE conclusion rotates the record to
# `<s>.terminal.consumed.json` (delivery), so every assertion that needs terminal.json on disk
# has to run before this line.
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-arm-read mhF3 --armed-seq 0 2>&1)"
rc=$?
chk_eq "F3 watch-arm-read exits 6 too" 6 "$rc"
chk_contains "F3 and its replay carries that exact rebuilt receipt line" "$f3_built" "$out"

echo "== G. B2: a subtree OSError degrades bounded — earlier hits still speak =="

# Two failure layers, and this fixture separates them: a PER-DIRECTORY OSError skips that
# subtree only (expected filesystem noise), while an unexpected error goes fully silent (E).
SUBFAULT="$SANDBOX/subfault"; mkdir -p "$SUBFAULT"
cat > "$SUBFAULT/sitecustomize.py" <<'PY'
import os
_real, _calls = os.scandir, [0]
def _wrapped(path, *a, **k):
    _calls[0] += 1
    if _calls[0] >= 2:                      # root enumerates; every subtree faults
        raise OSError(5, "synthetic subtree fault")
    return _real(path, *a, **k)
os.scandir = _wrapped
PY
WTG="$SANDBOX/wtG"; mkdir -p "$WTG/docs" "$WTG/sub"
seed mhG1 claude "$WTG" "docs/RESULT.md"; exited mhG1
printf 'x\n' > "$WTG/RESULT.md"                 # root hit — the incident shape
printf 'x\n' > "$WTG/sub/RESULT.md"             # subtree hit — lost when the subtree faults
mark_fresh "$WTG/RESULT.md" "$WTG/sub/RESULT.md"
run_c mhG1
{ verdict_exited "docs/RESULT.md"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTG/RESULT.md")"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTG/sub/RESULT.md")"
} > "$SANDBOX/exp-G-clean.txt"
chk_eq "G1 uninjected exits 6" 6 "$rc"
cmp_full "G1 uninjected: both the root and the subtree hit are reported" \
  "$SANDBOX/exp-G-clean.txt"
run_c mhG1 "PYTHONPATH=$SUBFAULT"
{ verdict_exited "docs/RESULT.md"
  printf 'possible misplaced deliverable: %s\n' "$(enc "$WTG/RESULT.md")"
} > "$SANDBOX/exp-G-fault.txt"
chk_eq "G2 subtree-fault run still exits 6" 6 "$rc"
cmp_full "G2 the faulted subtree drops out; the root hit survives" "$SANDBOX/exp-G-fault.txt"

echo "== H. B3: the entry cap consumes at most SCAN_MAX_ENTRIES dirents, counted =="

# R1 B3: `for entry in it` pulled the 2001st dirent to discover the budget was spent. The
# meter is a counting proxy around the REAL os.scandir, so the assertion is on consumption,
# not on the wording that follows it. Declared patterns here are magic-free on purpose:
# glob() would otherwise scandir on its own and pollute the count.
COUNTER="$SANDBOX/counter"; mkdir -p "$COUNTER"
cat > "$COUNTER/sitecustomize.py" <<'PY'
import atexit, os
_real, _n = os.scandir, [0]
_dest = os.environ.get("SCAN_COUNT_FILE")
class _Counting:
    def __init__(self, it):
        self._it = it
    def __iter__(self):
        return self
    def __next__(self):
        entry = next(self._it)              # StopIteration propagates untouched
        _n[0] += 1
        return entry
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return self._it.__exit__(*a)
    def close(self):
        self._it.close()
os.scandir = lambda *a, **k: _Counting(_real(*a, **k))
if _dest:
    atexit.register(lambda: open(_dest, "w").write(str(_n[0])))
PY
count_run() { # $1 session — classify under the counting proxy; consumed count in $consumed
  rm -f "$SANDBOX/scan-count.txt"
  run_c "$1" "PYTHONPATH=$COUNTER" "SCAN_COUNT_FILE=$SANDBOX/scan-count.txt"
  consumed="$(cat "$SANDBOX/scan-count.txt" 2>/dev/null || echo missing)"
}

# calibration first: a small flat cwd consumes exactly its own dirents (a meter stuck at the
# cap, or one that never fires, would fail here before the cap claim below means anything)
WTH1="$SANDBOX/wtH1"; mkdir -p "$WTH1/docs"
seed mhH1 claude "$WTH1" "docs/RESULT.md"; exited mhH1
python3 -c 'import os,sys
for i in range(10): open(os.path.join(sys.argv[1], "f-%02d.txt" % i), "w").close()' "$WTH1"
count_run mhH1
chk_eq "H1 meter calibration: 11 dirents present, 11 consumed" "6 11" "$rc $consumed"

# now the cap: 2100 dirents in one flat directory, budget 2000
WTH2="$SANDBOX/wtH2"; mkdir -p "$WTH2/docs"
seed mhH2 claude "$WTH2" "docs/RESULT.md"; exited mhH2
python3 -c 'import os,sys
for i in range(2100): open(os.path.join(sys.argv[1], "filler-%04d.txt" % i), "w").close()' "$WTH2"
chk_eq "H2 fixture holds 2101 dirents" 2101 \
  "$(python3 -c 'import os,sys;print(len(os.listdir(sys.argv[1])))' "$WTH2")"
count_run mhH2
chk_eq "H2 consumption stops EXACTLY at the cap (2001 = the off-by-one)" "6 2000" \
  "$rc $consumed"
verdict_exited "docs/RESULT.md" > "$SANDBOX/exp-H2.txt"
cmp_full "H2 and a capped scan with no candidate stays silent" "$SANDBOX/exp-H2.txt"

rm -rf "$SANDBOX"
summary
