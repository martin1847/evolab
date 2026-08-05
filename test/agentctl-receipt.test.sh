#!/usr/bin/env bash
# WS2 — canonical delivery receipt (2026-08-04).
#
# Field motive: the lane's terminal truth was an identity-stamped marker carrying NO deliverable
# evidence — `{ts, rc, deliverable, identity}`. "Deliverable fresh" was therefore judged by
# mtime alone at watch time: a `touch` on the declared path opened the gate, and a post-mortem
# could never say WHICH bytes the attempt had produced. Contract now: ONE record (the same
# marker file, same atomic publish under the same WS1 lock and double-read fence) extended to
# `schemaVersion / sessionId / attemptId / processIncarnation / phase / engineOutcome /
# deliverables[path,sha256,size] / gitHead / completedAt`, plus a STRUCTURAL `reason` from a
# closed enum on every non-delivered outcome. `phase=delivered` means runtime terminal +
# declared artifact evidence hashed — NOTHING about reviewed / verified / E2E / deployed.
#
# Harness: hermetic, no tmux server needed. A synthesized duplex session (meta + round-epoch +
# rc=0) drives the REAL classify → publish → read path of agentctl/duplexctl/identity.py; the
# fake tmux from lib-testkit is never reached because the rc lane short-circuits before it.
# Every negative case carries a PAIRED GREEN control: refusing a correct delivery is a failure
# here, not acceptable collateral of failing closed.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

WS2="$(pwd)/duplex-fixtures/ws2"
DUPLEXCTL="$AW_DIR/duplexctl.py"

ctl() { python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" "$@"; }

setup() {
  sandbox_new
  WT="$SANDBOX/wt"; mkdir -p "$WT"
  # canonical form: on darwin $TMPDIR lives under /var -> /private/var, and a forged record
  # carrying the UNRESOLVED path is refused by the declared-path rule before any rule under
  # test is reached — every schema probe then passed for the wrong reason (Linux CI, 2026-08-05)
  WTP="$(cd "$WT" && pwd -P)"
}
teardown() { sandbox_clean; }

# A duplex session without an engine: everything classify needs on the rc lane (meta with the
# session cwd + the declared deliverable, a round epoch, rc=0) plus a real identity record
# minted by the module under test. pane_pid/pane_lstart make the incarnation establishable, so
# the WS1 fence is live rather than degraded to UNKNOWN.
mk_session() { # $1 name  $2 declared-deliverable ("" = none)  [$3 cwd]
  local s="$1" deliv="$2" cwd="${3:-$WT}"
  { printf 'engine=omp\ncwd=%s\npane_pid=%s\npane_lstart=FAKE-%s\n' "$cwd" "$$" "$s"
    [ -n "$deliv" ] && printf 'deliverable=%s\n' "$deliv"
    : ; } > "$WATCH_RUN_DIR/$s.duplex.meta"
  : > "$WATCH_RUN_DIR/$s.duplex.events.jsonl"
  : > "$WATCH_RUN_DIR/$s.duplex.round-started"
  printf '0\n' > "$WATCH_RUN_DIR/$s.duplex.rc"
  ctl identity start "$s" >/dev/null
}

token() { ctl identity token "$1"; }
publish() { ctl identity publish "$1" --armed "$(token "$1")" 2>&1; }

rec_field() { # $1 session  $2 dotted field — "" absent, "null" JSON null
  python3 - "$WATCH_RUN_DIR/$1.terminal.json" "$2" <<'PY'
import json, sys
try:
    node = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
for key in sys.argv[2].split("."):
    if isinstance(node, list):
        node = node[int(key)]
    elif isinstance(node, dict) and key in node:
        node = node[key]
    else:
        print(""); raise SystemExit
print("null" if node is None else node)
PY
}

view_field() { # $1 session  $2 field of `identity receipt`
  ctl identity receipt "$1" 2>/dev/null | python3 -c 'import json,sys
try: v = json.load(sys.stdin).get(sys.argv[1])
except Exception: v = None
print("" if v is None else v)' "$2"
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
parses() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1 && echo 1 || echo 0; }
debris_count() { local n; n=$(ls "$WATCH_RUN_DIR"/.$1.terminal.json-*.tmp 2>/dev/null | grep -c .); echo "$n"; }
newid() { python3 -c 'import uuid; print(uuid.uuid4().hex)'; }

# One bounded-evidence row: synthesize, publish, report reason + phase. Used by the predicate
# table cases so each row is one line and the shape of the table is visible in the test.
row() { # $1 name  $2 declared  $3 expected-reason  $4 expected-phase("-" = none)
  mk_session "$1" "$2"
  publish "$1" >/dev/null
  chk_eq "TABLE $3: reason on the record" "$3" "$(rec_field "$1" reason)"
  chk_eq "TABLE $3: phase" "$4" "$(rec_field "$1" phase | sed 's/^$/-/')"
  chk_eq "TABLE $3: receipt view agrees" "$3" "$(view_field "$1" reason)"
}

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R1: a fresh timestamp with WRONG content is hashed accurately, and claims nothing more =="
setup
mk_session r1 report.md
printf 'WRONG CONTENT — not what the goal asked for\n' > "$WT/report.md"   # fresh mtime, bad bytes
out="$(bash "$AGENTCTL" status r1 2>&1)"; rc=$?
chk_eq "R1 arrange: the terminal verdict is DONE 0 (the engine DID finish)" 0 "$rc"
chk_contains "R1 the machine line carries the structural reason" "reason=OK" "$out"
chk_contains "R1 phase is delivered" "phase=delivered" "$out"
actual="$(sha_of "$WT/report.md")"
expected="$(printf 'the CORRECT deliverable content\n' | shasum -a 256 | cut -d' ' -f1)"
chk_eq "R1 DAMAGE ORACLE: the recorded sha256 is the sha of the ACTUAL bytes" \
  "$actual" "$(rec_field r1 deliverables.0.sha256)"
chk_eq "R1 DAMAGE ORACLE: it is NOT the sha of what the goal expected" 1 \
  "$([ "$(rec_field r1 deliverables.0.sha256)" != "$expected" ] && echo 1 || echo 0)"
chk_eq "R1 the recorded size is the real byte count" \
  "$(wc -c < "$WT/report.md" | tr -d ' ')" "$(rec_field r1 deliverables.0.size)"
chk_eq "R1 mtime freshness alone never becomes a hash claim (hash ≠ empty)" 1 \
  "$([ ${#actual} = 64 ] && echo 1 || echo 0)"
chk_eq "R1 delivered is bounded: engineOutcome is the ONLY outcome claim" "completed" \
  "$(rec_field r1 engineOutcome)"
# The CLAIM surface only: filesystem paths are excluded because a random sandbox name can
# contain any substring (a `mktemp` name with "e2e" in it turned this into a false red while
# re-verifying a mutation patch — the record was innocent, the tmpdir was not).
claims_of() { # $1 session — record rendering with path-valued fields removed
  python3 -c 'import json,sys
rec = json.load(open(sys.argv[1]))
rec.pop("deliverable", None)
for item in rec.get("deliverables") or []:
    item.pop("path", None)
print(json.dumps(rec, sort_keys=True).lower())' "$WATCH_RUN_DIR/$1.terminal.json"
}
chk_not_contains "R1 the record claims no review" "review" "$(claims_of r1)"
chk_not_contains "R1 the record claims no verification" "verified" "$(claims_of r1)"
chk_not_contains "R1 the record claims no E2E" "e2e" "$(claims_of r1)"
chk_contains "R1 the human line says delivered ≠ verified out loud" "delivered ≠ verified" "$out"
chk_eq "R1 schemaVersion is stamped" "1" "$(rec_field r1 schemaVersion)"
chk_eq "R1 the receipt triple matches the fence stamp (one record, two shapes)" \
  "$(rec_field r1 identity.attemptId)" "$(rec_field r1 attemptId)"
chk_eq "R1 completedAt is RFC3339" 1 \
  "$(printf '%s' "$(rec_field r1 completedAt)" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"

# paired green: the CORRECT content hashes to the expected digest and still sets phase=delivered
mk_session r1b report2.md
printf 'the CORRECT deliverable content\n' > "$WT/report2.md"
out="$(bash "$AGENTCTL" status r1b 2>&1)"; rc=$?
chk_eq "R1 PAIRED GREEN: correct content still reaches DONE 0" 0 "$rc"
chk_eq "R1 PAIRED GREEN: the recorded hash is the expected digest" "$expected" \
  "$(rec_field r1b deliverables.0.sha256)"
chk_eq "R1 PAIRED GREEN: phase=delivered is set" "delivered" "$(rec_field r1b phase)"
chk_eq "R1 PAIRED GREEN: the receipt view calls it delivered" "True" "$(view_field r1b delivered)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R2: a RECORD stamped by a prior attempt is refused — no delivered receipt =="
setup
mk_session r2 report.md
printf 'produced by attempt A\n' > "$WT/report.md"
publish r2 >/dev/null
chk_eq "R2 arrange: attempt A published a delivered receipt" "delivered" "$(rec_field r2 phase)"
a_sha="$(rec_field r2 deliverables.0.sha256)"
# rotate the attempt (a state-resetting steer) and rotate the round epoch: the ONLY route to
# DONE left is the receipt on disk, and that receipt now belongs to a dead attempt
touch "$WATCH_RUN_DIR/r2.duplex.round-started"
ctl identity replace r2 >/dev/null
out="$(bash "$AGENTCTL" status r2 2>&1)"; rc=$?
chk_eq "R2 DAMAGE ORACLE: a prior-attempt receipt cannot open the current gate" 6 "$rc"
chk_not_contains "R2 no delivered claim is emitted for the new attempt" "phase=delivered" "$out"
chk_eq "R2 the receipt view names the WS1 stale class as the reason" "STALE-ATTEMPT" \
  "$(view_field r2 reason)"
chk_eq "R2 and refuses to call it delivered" "False" "$(view_field r2 delivered)"
chk_eq "R2 stale evidence stays on disk, not rewritten" "$a_sha" "$(rec_field r2 deliverables.0.sha256)"

# a FOREIGN full receipt (forged by a producer that never imported identity.py) is refused the
# same way — including one whose deliverables claim a hash of bytes nobody read
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r2.terminal.json" \
  --attempt "$(python3 -c 'import uuid;print(uuid.uuid4().hex)')" --incarnation "$$@FAKE-r2" \
  --deliverable "$WTP/report.md" --sha256 "$(printf 0123456789abcdef | shasum -a 256 | cut -d' ' -f1)" \
  --size 4 --phase delivered >/dev/null
out="$(bash "$AGENTCTL" status r2 2>&1)"; rc=$?
chk_eq "R2 a forged foreign receipt is refused too" 6 "$rc"
chk_eq "R2 forged receipt: reason is the stale class" "STALE-ATTEMPT" "$(view_field r2 reason)"
chk_eq "R2 forged receipt: never delivered" "False" "$(view_field r2 delivered)"

# paired green: the CURRENT attempt publishes and the same file is delivered again — and the
# hash evidence supersedes the (stale) mtime heuristic that alone would have said 6
out="$(bash "$AGENTCTL" status r2 2>&1)"; rc=$?
chk_eq "R2 PAIRED GREEN: re-publishing under the current attempt is refused for the FORGED file first" 6 "$rc"
publish r2 >/dev/null
out="$(bash "$AGENTCTL" status r2 2>&1)"; rc=$?
chk_eq "R2 PAIRED GREEN: a current-attempt receipt delivers → DONE 0" 0 "$rc"
chk_contains "R2 PAIRED GREEN: and says so with hash evidence" "phase=delivered" "$out"
chk_contains "R2 PAIRED GREEN: hash evidence supersedes the mtime heuristic" \
  "supersedes the mtime freshness heuristic" "$out"
chk_eq "R2 PAIRED GREEN: the delivered receipt belongs to the CURRENT attempt" \
  "$(ctl identity show r2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')" \
  "$(rec_field r2 attemptId)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R3: missing / unreadable deliverables cannot produce a delivered receipt =="
setup
mk_session r3 missing-report.md
out="$(bash "$AGENTCTL" status r3 2>&1)"; rc=$?
chk_eq "R3 DAMAGE ORACLE: a missing deliverable never reads as DONE" 6 "$rc"
chk_eq "R3 the mtime gate refused before any publish — no record at all" 0 \
  "$([ -e "$WATCH_RUN_DIR/r3.terminal.json" ] && echo 1 || echo 0)"
# The publisher is also reachable with the file GONE — the TOCTOU the reason channel exists
# for: present when the gate looked, deleted before the record was written. It must publish a
# terminal record with NO phase and a typed reason, never a vacuous delivery.
pout="$(publish r3)"
chk_eq "R3 DAMAGE ORACLE: reason=MISSING on the published record" "MISSING" "$(rec_field r3 reason)"
chk_eq "R3 and NO phase field at all" "" "$(rec_field r3 phase)"
chk_eq "R3 and no deliverables array to mis-read" "" "$(rec_field r3 deliverables.0.sha256)"
chk_contains "R3 the reason reaches the machine line" "reason=MISSING" "$pout"
chk_not_contains "R3 nothing claims delivery" "phase=delivered" "$pout"

# SEPARATE case: unreadable. The oracle only counts if the RUNNING identity truly gets EACCES —
# a probe that stays readable proves nothing and must be reported NOT VERIFIED, never green.
mk_session r3u locked.md
printf 'secret\n' > "$WT/locked.md"; chmod 000 "$WT/locked.md"
if [ "$(id -u)" = 0 ] || cat "$WT/locked.md" >/dev/null 2>&1; then
  echo "  NOT VERIFIED: this identity ($(id -un), uid $(id -u)) can still read a mode-000 file — the UNREADABLE row is NOT proven here"
else
  chk_eq "R3 arrange: the running identity really gets EACCES on the declared path" 1 \
    "$(cat "$WT/locked.md" >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)"
  out="$(bash "$AGENTCTL" status r3u 2>&1)"; rc=$?
  # the EXIT CONTRACT is untouched: the pre-existing mtime gate still says the file appeared
  # this round, so the verdict stays DONE 0 — what the receipt refuses is the DELIVERY CLAIM
  chk_eq "R3 the exit-code contract is unchanged (mtime gate still verdicts DONE 0)" 0 "$rc"
  chk_eq "R3 DAMAGE ORACLE: an unreadable deliverable is NEVER delivered" "" "$(rec_field r3u phase)"
  chk_eq "R3 reason=UNREADABLE (not MISSING — the file exists)" "UNREADABLE" "$(rec_field r3u reason)"
  chk_eq "R3 unreadable: no hash is claimed" "" "$(rec_field r3u deliverables.0.sha256)"
  chk_eq "R3 unreadable: the receipt view refuses delivery" "False" "$(view_field r3u delivered)"
  chk_contains "R3 unreadable: the reason reaches the machine line" "reason=UNREADABLE" "$out"
fi
chmod 644 "$WT/locked.md"

# paired green: the same declared path, now readable, delivers
out="$(bash "$AGENTCTL" status r3u 2>&1)"; rc=$?
chk_eq "R3 PAIRED GREEN: a readable present file reaches DONE 0" 0 "$rc"
chk_eq "R3 PAIRED GREEN: phase=delivered" "delivered" "$(rec_field r3u phase)"
chk_eq "R3 PAIRED GREEN: hashed the real bytes" "$(sha_of "$WT/locked.md")" \
  "$(rec_field r3u deliverables.0.sha256)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R4: an interrupted publish leaves the prior complete record or none — never partial JSON =="
setup
mk_session r4 report.md
printf 'round one output\n' > "$WT/report.md"
publish r4 >/dev/null
prior_sha="$(rec_field r4 deliverables.0.sha256)"
prior_at="$(rec_field r4 completedAt)"
chk_eq "R4 arrange: a prior COMPLETE record exists" "delivered" "$(rec_field r4 phase)"

# the TEST-ONLY deterministic seam: temp file written+fsynced, barrier fires, SIGKILL. No sleep,
# no race — the barrier file is the proof the window was entered at all.
BARRIER="$SANDBOX/barrier-r4"
printf 'round two output — larger, different bytes\n' > "$WT/report.md"
AGENTCTL_PUBLISH_BARRIER="$BARRIER" ctl identity publish r4 --armed "$(token r4)" >/dev/null 2>&1
krc=$?
chk_eq "R4 arrange: the publisher died on the seam (SIGKILL = 137)" 137 "$krc"
chk_eq "R4 PROOF THE WINDOW WAS EXERCISED: the barrier was reached" 1 \
  "$([ -s "$BARRIER" ] && echo 1 || echo 0)"
chk_contains "R4 the barrier fired inside the terminal-record publish" "r4.terminal.json" \
  "$(cat "$BARRIER" 2>/dev/null)"
chk_eq "R4 the interrupted publish left its temp file behind (never renamed)" 1 \
  "$([ "$(debris_count r4)" -ge 1 ] && echo 1 || echo 0)"
chk_eq "R4 DAMAGE ORACLE: the record on disk still parses as JSON" 1 "$(parses "$WATCH_RUN_DIR/r4.terminal.json")"
chk_eq "R4 DAMAGE ORACLE: it is the PRIOR COMPLETE record, byte-for-byte intact" "$prior_sha" \
  "$(rec_field r4 deliverables.0.sha256)"
chk_eq "R4 the prior record's timestamp is untouched" "$prior_at" "$(rec_field r4 completedAt)"
chk_eq "R4 the reader still calls the prior record delivered" "True" "$(view_field r4 delivered)"

# same seam with NO prior record: the reader must see NOTHING, and know why
mk_session r4b report.md
BARRIER2="$SANDBOX/barrier-r4b"
AGENTCTL_PUBLISH_BARRIER="$BARRIER2" ctl identity publish r4b --armed "$(token r4b)" >/dev/null 2>&1
chk_eq "R4 no-prior-record: the barrier was reached" 1 "$([ -s "$BARRIER2" ] && echo 1 || echo 0)"
chk_eq "R4 no-prior-record: no record was published at all" 0 \
  "$([ -e "$WATCH_RUN_DIR/r4b.terminal.json" ] && echo 1 || echo 0)"
chk_eq "R4 no-prior-record: no partial JSON is readable as a record" "" "$(rec_field r4b reason)"
chk_eq "R4 no-prior-record: the reader reports reason=PUBLISH_INTERRUPTED" "PUBLISH_INTERRUPTED" \
  "$(view_field r4b reason)"
chk_eq "R4 no-prior-record: nothing is delivered" "False" "$(view_field r4b delivered)"

# paired green: the same publish, uninterrupted, is complete
out="$(publish r4b)"
chk_eq "R4 PAIRED GREEN: an uninterrupted publish writes a complete record" 1 \
  "$(parses "$WATCH_RUN_DIR/r4b.terminal.json")"
chk_eq "R4 PAIRED GREEN: and it is delivered" "delivered" "$(rec_field r4b phase)"
chk_contains "R4 PAIRED GREEN: with the structural reason on the machine line" "reason=OK" "$out"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R5: a non-git cwd yields gitHead=null; a repo yields the HEAD of the SESSION's cwd =="
setup
mk_session r5 report.md
printf 'no repository here\n' > "$WT/report.md"
chk_eq "R5 arrange: the session cwd is not a git repository" 1 \
  "$(git -C "$WT" rev-parse HEAD >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)"
publish r5 >/dev/null
chk_eq "R5 DAMAGE ORACLE: gitHead is JSON null, never an invented sha" "null" "$(rec_field r5 gitHead)"
chk_eq "R5 non-git still DELIVERS (a receipt is not a provenance claim)" "delivered" \
  "$(rec_field r5 phase)"

# paired green: a real repository at the session cwd → the real HEAD sha of THAT worktree
REPO="$SANDBOX/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'in-repo deliverable\n' > "$REPO/report.md"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@example.com -c user.name=test commit -qm "seed"
mk_session r5b report.md "$REPO"
publish r5b >/dev/null
chk_eq "R5 PAIRED GREEN: gitHead is the real HEAD of the session cwd's worktree" \
  "$(git -C "$REPO" rev-parse HEAD)" "$(rec_field r5b gitHead)"
chk_eq "R5 PAIRED GREEN: and the deliverable is hashed from that worktree" \
  "$(sha_of "$REPO/report.md")" "$(rec_field r5b deliverables.0.sha256)"
# the orchestrator's OWN repo must never leak in as provenance
chk_eq "R5 PAIRED GREEN: gitHead is NOT the orchestrator's repo HEAD" 1 \
  "$([ "$(rec_field r5b gitHead)" != "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" ] && echo 1 || echo 0)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R6: the bounded-evidence table — every row a typed reason, never a silent skip =="
setup
printf 'real bytes\n' > "$WT/report.md"
mkdir -p "$WT/subdir"
row t_missing   "gone.md"        MISSING     -
row t_dir       "subdir"         DIRECTORY   -
row t_glob      "*.md"           GLOB        -
row t_none      ""               NO_DELIVERABLE_DECLARED -
ln -s "$WT/report.md" "$WT/link-report.md"
row t_link      "link-report.md" SYMLINK     -
# an ANCESTOR is a link → O_NOFOLLOW alone would have hashed the foreign file happily
mkdir -p "$SANDBOX/elsewhere"; printf 'someone elses file\n' > "$SANDBOX/elsewhere/report.md"
ln -s "$SANDBOX/elsewhere" "$WT/linkdir"
row t_ancestor  "linkdir/report.md" SYMLINK  -
chk_eq "TABLE SYMLINK(ancestor): the foreign file was readable — the refusal is the rule, not an IO error" 1 \
  "$([ -r "$WT/linkdir/report.md" ] && echo 1 || echo 0)"

# a fifo at the declared path: not a regular file, nothing to hash, and the reader must not block
mkfifo "$WT/pipe.md"
row t_fifo      "pipe.md"        UNREADABLE  -

# > 64 MiB: the ONE bounded case that still DELIVERS — real size, hash explicitly labelled
python3 -c 'import os,sys; f=open(sys.argv[1],"wb"); f.truncate(64*1024*1024+1); f.close()' "$WT/huge.bin"
row t_big       "huge.bin"       OVERSIZED_HASH_SKIPPED delivered
chk_eq "TABLE OVERSIZED: the hash is LABELLED skipped, never a claimed digest" "oversized" \
  "$(rec_field t_big deliverables.0.sha256)"
chk_eq "TABLE OVERSIZED: the REAL size is recorded" "$(wc -c < "$WT/huge.bin" | tr -d ' ')" \
  "$(rec_field t_big deliverables.0.size)"
chk_eq "TABLE OVERSIZED: delivery still happens (benefit preserved)" "True" \
  "$(view_field t_big delivered)"

# just under the bound: hashed for real (the boundary is not off by one)
python3 -c 'import os,sys; f=open(sys.argv[1],"wb"); f.truncate(64*1024*1024); f.close()' "$WT/atlimit.bin"
row t_limit     "atlimit.bin"    OK          delivered
chk_eq "TABLE boundary: exactly 64 MiB is hashed, not skipped" 64 \
  "$(printf '%s' "$(rec_field t_limit deliverables.0.sha256)" | wc -c | tr -d ' ')"

# IDENTITY_UNKNOWN: no establishable identity ⇒ no receipt, typed reason, nothing published
mk_session t_unk report.md
rm -f "$WATCH_RUN_DIR/t_unk.identity.d/active.json"
out="$(publish t_unk)"; prc=$?
chk_eq "TABLE IDENTITY_UNKNOWN: the publish is refused" 2 "$prc"
chk_contains "TABLE IDENTITY_UNKNOWN: with the typed reason" "reason=IDENTITY_UNKNOWN" "$out"
chk_eq "TABLE IDENTITY_UNKNOWN: and nothing is published" 0 \
  "$([ -e "$WATCH_RUN_DIR/t_unk.terminal.json" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" status t_unk 2>&1)"; rc=$?
chk_eq "TABLE IDENTITY_UNKNOWN: status exits 2 per WS1, never DONE" 2 "$rc"
chk_contains "TABLE IDENTITY_UNKNOWN: status names the class" "IDENTITY-UNKNOWN" "$out"

# LEGACY: a WS1 marker with no receipt fields stays adoptable exactly as before
mk_session t_legacy report.md
python3 "$(pwd)/duplex-fixtures/ws1/forge_marker.py" "$WATCH_RUN_DIR/t_legacy.terminal.json" \
  --attempt "$(ctl identity show t_legacy | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')" \
  --incarnation "$(ctl identity show t_legacy | python3 -c 'import json,sys;print(json.load(sys.stdin)["processIncarnation"])')" \
  --seq 1 >/dev/null
chk_eq "LEGACY: a receipt-less WS1 marker is still identity-valid" "OK" "$(view_field t_legacy verdict)"
chk_eq "LEGACY: it is simply not delivered (no receipt fields to claim)" "False" \
  "$(view_field t_legacy delivered)"
chk_eq "LEGACY: and it carries no invented reason" "" "$(view_field t_legacy reason)"
touch "$WT/report.md"
out="$(bash "$AGENTCTL" status t_legacy 2>&1)"; rc=$?
chk_eq "LEGACY: the mtime path still reaches DONE 0 for a legacy marker" 0 "$rc"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R7 (fix round 1, BLOCKER): a CURRENT-stamped receipt is still nothing without a valid receipt schema =="
# Cold review R1: the read boundary accepted any record whose nested WS1 stamp matched the
# active attempt. `validate_marker_schema` only ever checked `rc` + the stamp, so a forged
# record could claim `sha256:"oversized"` on a 5-byte file, a fabricated gitHead and an
# arbitrary completedAt — and that record then SUPERSEDED the mtime gate and returned DONE 0
# for a deliverable the real predicate had refused. Reproduced with production `classify`.
setup
cur_stamp() { # $1 session  $2 field of the ACTIVE record
  ctl identity show "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}
# the reviewer's fixture, verbatim in shape: current attempt + current incarnation, NO
# top-level sessionId, oversized label on a small file, forty-zero gitHead, arbitrary
# completedAt — and a round epoch NEWER than the file so mtime alone must refuse
mk_session r7 small.md
printf '12345' > "$WT/small.md"
/bin/sleep 0.02; touch "$WATCH_RUN_DIR/r7.duplex.round-started"
out="$(bash "$AGENTCTL" status r7 2>&1)"; rc=$?
chk_eq "R7 arrange: with no record at all the mtime gate refuses (6)" 6 "$rc"
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r7.terminal.json" \
  --attempt "$(cur_stamp r7 attemptId)" --incarnation "$(cur_stamp r7 processIncarnation)" \
  --deliverable "$WT/small.md" --sha256 oversized --size 67108865 \
  --git-head "$(printf "0%.0s" $(seq 40))" \
  --completed-at "whenever it felt like it" --phase delivered >/dev/null
out="$(bash "$AGENTCTL" status r7 2>&1)"; rc=$?
chk_eq "R7 DAMAGE ORACLE: a schema-invalid receipt never opens the gate mtime refused" 6 "$rc"
chk_not_contains "R7 no delivered claim is printed" "phase=delivered" "$out"
chk_not_contains "R7 the invented oversized label never reaches the verdict line" "oversized" "$out"
chk_not_contains "R7 the mtime heuristic is NOT declared superseded by junk" \
  "supersedes the mtime freshness heuristic" "$out"
chk_eq "R7 the receipt view refuses to call it delivered" "False" "$(view_field r7 delivered)"
chk_eq "R7 and types the refusal on the closed enum" "IDENTITY_UNKNOWN" "$(view_field r7 reason)"
chk_eq "R7 the forged record stays on disk for post-mortem, not rewritten" "67108865" \
  "$(rec_field r7 deliverables.0.size)"

# every individual schema violation is refused on its own — one probe per rule, so a future
# relaxation of any single field cannot hide behind another field's failure
schema_probe() { # $1 label  $2... forge args (after --phase delivered)
  local label="$1"; shift
  python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r7b.terminal.json" \
    --attempt "$(cur_stamp r7b attemptId)" --incarnation "$(cur_stamp r7b processIncarnation)" \
    --session "$(cur_stamp r7b sessionId)" --deliverable "$WTP/report.md" \
    --phase delivered "$@" >/dev/null
  chk_eq "R7 SCHEMA: $label ⇒ not delivered" "False" "$(view_field r7b delivered)"
  chk_eq "R7 SCHEMA: $label ⇒ typed IDENTITY_UNKNOWN" "IDENTITY_UNKNOWN" "$(view_field r7b reason)"
}
mk_session r7b report.md
printf 'real bytes\n' > "$WT/report.md"
good_sha="$(sha_of "$WT/report.md")"
/bin/sleep 0.02; touch "$WATCH_RUN_DIR/r7b.duplex.round-started"
schema_probe "sha256 is not 64-hex"        --sha256 deadbeef --size 11
schema_probe "sha256 has non-hex chars"    --sha256 "$(printf 'z%.0s' $(seq 64))" --size 11
schema_probe "size is negative"            --sha256 "$good_sha" --size -1
schema_probe "size is a string"            --sha256 "$good_sha" --size-raw '"11"'
schema_probe "size is a bool"              --sha256 "$good_sha" --size-raw 'true'
schema_probe "oversized label on a small file" --sha256 oversized --size 11
schema_probe "gitHead is not a 40-hex sha" --sha256 "$good_sha" --size 11 --git-head not-a-sha
schema_probe "completedAt is not RFC3339"  --sha256 "$good_sha" --size 11 --completed-at "yesterday"
schema_probe "engineOutcome missing"       --sha256 "$good_sha" --size 11 --no-engine-outcome
schema_probe "engineOutcome is not completed" --sha256 "$good_sha" --size 11 --engine-outcome maybe
schema_probe "schemaVersion is unknown"    --sha256 "$good_sha" --size 11 --schema-version 2
schema_probe "deliverables is not a list"  --deliverables-raw '{"path":"x"}'
schema_probe "deliverables is empty"       --deliverables-raw '[]'
schema_probe "a deliverable entry is not an object" --deliverables-raw '["report.md"]'
schema_probe "a deliverable entry has no sha256" --deliverables-raw "[{\"path\":\"$WTP/report.md\",\"size\":11}]"
schema_probe "the recorded path is not the declared deliverable" \
  --deliverables-raw "[{\"path\":\"$WTP/somethingelse.md\",\"sha256\":\"$good_sha\",\"size\":11}]"
schema_probe "reason contradicts the delivered claim" --sha256 "$good_sha" --size 11 --reason MISSING
# the identity triple must be CROSS-CHECKED against the fenced stamp, not merely present
# PAIRED GREEN: the record the REAL publisher writes passes the validator and still delivers —
# including the genuine oversized case, whose label is legitimate because the size backs it
publish r7b >/dev/null
chk_eq "R7 PAIRED GREEN: a real publisher record validates and delivers" "True" \
  "$(view_field r7b delivered)"
chk_eq "R7 PAIRED GREEN: with reason=OK" "OK" "$(view_field r7b reason)"
out="$(bash "$AGENTCTL" status r7b 2>&1)"; rc=$?
chk_eq "R7 PAIRED GREEN: and its hash evidence still supersedes a stale mtime → DONE 0" 0 "$rc"
chk_contains "R7 PAIRED GREEN: the supersede is explicit" "supersedes the mtime freshness heuristic" "$out"

# sessionId probes get their OWN session and an unused seq: on the shared r7b record the
# refusal came from an earlier rule (proved by mutation — dropping sessionId from the triple
# cross-check left both assertions green), i.e. they were passing for the wrong reason.
mk_session r7c report.md
printf 'real bytes\n' > "$WT/report.md"
c_sha="$(sha_of "$WT/report.md")"
/bin/sleep 0.02; touch "$WATCH_RUN_DIR/r7c.duplex.round-started"

# --session sets BOTH views, so it cannot express a receipt-vs-stamp mismatch at all;
# --top-session moves ONLY the receipt view, which is the claim under test.
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r7c.terminal.json" \
  --attempt "$(cur_stamp r7c attemptId)" --incarnation "$(cur_stamp r7c processIncarnation)" \
  --session "$(cur_stamp r7c sessionId)" --top-session "$(newid)" --seq 41 \
  --deliverable "$WTP/report.md" --sha256 "$c_sha" --size 11 --phase delivered >/dev/null
chk_eq "R7 SCHEMA: top-level sessionId ≠ the fenced stamp ⇒ not delivered" "False" \
  "$(view_field r7c delivered)"
chk_eq "R7 SCHEMA: and typed IDENTITY_UNKNOWN" "IDENTITY_UNKNOWN" "$(view_field r7c reason)"

# PAIRED GREEN on the same session and seq: identical record, matching sessionId ⇒ delivers,
# so the refusal above is attributable to sessionId alone.
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r7c.terminal.json" \
  --attempt "$(cur_stamp r7c attemptId)" --incarnation "$(cur_stamp r7c processIncarnation)" \
  --session "$(cur_stamp r7c sessionId)" --seq 41 \
  --deliverable "$WTP/report.md" --sha256 "$c_sha" --size 11 --phase delivered >/dev/null
chk_eq "R7 SCHEMA PAIRED GREEN: the same record with a matching sessionId delivers" "True" \
  "$(view_field r7c delivered)"

# the case Linux CI caught: a record whose two session views AGREE with each other but name a
# foreign session still rode this attempt's stamp into `delivered`, because the WS1 fence pins
# attemptId + incarnation only. The receipt must also belong to the ACTIVE session.
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r7c.terminal.json" \
  --attempt "$(cur_stamp r7c attemptId)" --incarnation "$(cur_stamp r7c processIncarnation)" \
  --session "$(newid)" --seq 42 \
  --deliverable "$WTP/report.md" --sha256 "$c_sha" --size 11 --phase delivered >/dev/null
chk_eq "R7 SCHEMA: a self-consistent FOREIGN sessionId is refused" "False" \
  "$(view_field r7c delivered)"
chk_eq "R7 SCHEMA: and types it IDENTITY_UNKNOWN" "IDENTITY_UNKNOWN" "$(view_field r7c reason)"

mk_session r7c huge.bin
python3 -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate(64*1024*1024+1); f.close()' "$WT/huge.bin"
publish r7c >/dev/null
chk_eq "R7 PAIRED GREEN: a GENUINE oversized receipt still validates" "True" \
  "$(view_field r7c delivered)"
chk_eq "R7 PAIRED GREEN: and keeps its honest label" "oversized" \
  "$(rec_field r7c deliverables.0.sha256)"
# LEGACY stays legacy: a receipt-less WS1 marker must bypass the receipt validator as a legacy
# marker (adoptable, mtime-governed), never as a delivered receipt
mk_session r7d report.md
python3 "$(pwd)/duplex-fixtures/ws1/forge_marker.py" "$WATCH_RUN_DIR/r7d.terminal.json" \
  --attempt "$(cur_stamp r7d attemptId)" --incarnation "$(cur_stamp r7d processIncarnation)" \
  --seq 1 >/dev/null
chk_eq "R7 LEGACY: a receipt-less marker is still identity-valid" "OK" "$(view_field r7d verdict)"
chk_eq "R7 LEGACY: never delivered, never typed as broken" "False" "$(view_field r7d delivered)"
chk_eq "R7 LEGACY: no invented reason" "" "$(view_field r7d reason)"
touch "$WT/report.md"
out="$(bash "$AGENTCTL" status r7d 2>&1)"; rc=$?
chk_eq "R7 LEGACY: the mtime path still reaches DONE 0" 0 "$rc"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R8 (fix round 1, MAJOR): an ABSOLUTE declaration is walked component-wise too =="
# Cold review R2: `_link_below` treated "outside the session cwd" as "only the final component
# can be judged", and every ABSOLUTE declaration took that exemption. O_NOFOLLOW guards only
# the last component, so a symlinked ANCESTOR was followed and a FOREIGN tree's bytes were
# hashed and published as phase=delivered under the declared path. The binding table says
# final AND ancestor, with no absolute-path exemption.
setup
CWDIR="$SANDBOX/abs-cwd"; mkdir -p "$CWDIR"
REALDIR="$SANDBOX/abs-real"; mkdir -p "$REALDIR"
printf 'FOREIGN BYTES\n' > "$REALDIR/artifact.md"
ln -s "$REALDIR" "$SANDBOX/abs-linked"
foreign_sha="$(sha_of "$REALDIR/artifact.md")"
mk_session r8 "$SANDBOX/abs-linked/artifact.md" "$CWDIR"
chk_eq "R8 arrange: the declaration is absolute and outside the session cwd" 1 \
  "$([ "${SANDBOX#/}" != "$SANDBOX" ] && echo 1 || echo 0)"
chk_eq "R8 arrange: the foreign file IS readable through the link (so a refusal is the rule)" 1 \
  "$([ -r "$SANDBOX/abs-linked/artifact.md" ] && echo 1 || echo 0)"
pout="$(publish r8)"
chk_eq "R8 DAMAGE ORACLE: reason=SYMLINK, not a delivery" "SYMLINK" "$(rec_field r8 reason)"
chk_eq "R8 DAMAGE ORACLE: no phase" "" "$(rec_field r8 phase)"
chk_eq "R8 DAMAGE ORACLE: the FOREIGN bytes were never hashed" "" \
  "$(rec_field r8 deliverables.0.sha256)"
chk_not_contains "R8 the foreign digest appears nowhere in the record" "$foreign_sha" \
  "$(cat "$WATCH_RUN_DIR/r8.terminal.json")"
chk_contains "R8 the machine line types it" "reason=SYMLINK" "$pout"

# an ancestor link INSIDE the session cwd, declared absolutely — same rule, same refusal
mkdir -p "$CWDIR/sub"; ln -s "$REALDIR" "$CWDIR/sub/linked"
mk_session r8b "$CWDIR/sub/linked/artifact.md" "$CWDIR"
publish r8b >/dev/null
chk_eq "R8 in-cwd absolute ancestor link ⇒ SYMLINK" "SYMLINK" "$(rec_field r8b reason)"
chk_eq "R8 in-cwd absolute ancestor link ⇒ never delivered" "False" "$(view_field r8b delivered)"

# the final component as a link, declared absolutely
ln -s "$REALDIR/artifact.md" "$CWDIR/final-link.md"
mk_session r8c "$CWDIR/final-link.md" "$CWDIR"
publish r8c >/dev/null
chk_eq "R8 absolute final-component link ⇒ SYMLINK" "SYMLINK" "$(rec_field r8c reason)"

# PAIRED GREEN: an absolute regular path with no link anywhere below the anchor delivers, and
# hashes the file the declaration actually names
printf 'honest absolute artifact\n' > "$CWDIR/sub/real.md"
mk_session r8d "$CWDIR/sub/real.md" "$CWDIR"
publish r8d >/dev/null
chk_eq "R8 PAIRED GREEN: an absolute regular path delivers" "delivered" "$(rec_field r8d phase)"
chk_eq "R8 PAIRED GREEN: with the real digest of the named file" "$(sha_of "$CWDIR/sub/real.md")" \
  "$(rec_field r8d deliverables.0.sha256)"
chk_eq "R8 PAIRED GREEN: and the receipt validates at the read boundary" "True" \
  "$(view_field r8d delivered)"
# PAIRED GREEN: an absolute declaration UNDER the session cwd on a platform-symlinked temp root
# (macOS /var -> private/var) must not be mistaken for an escape — the whole class of CI boxes
printf 'platform prefix artifact\n' > "$WT/plat.md"
mk_session r8e "$WT/plat.md"
publish r8e >/dev/null
chk_eq "R8 PAIRED GREEN: absolute path under a platform-symlinked temp root still delivers" \
  "delivered" "$(rec_field r8e phase)"
chk_eq "R8 PAIRED GREEN: hashing the real bytes" "$(sha_of "$WT/plat.md")" \
  "$(rec_field r8e deliverables.0.sha256)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R9 (fix round 1, MAJOR): losing session meta is a REFUSAL, never a successful publish =="
# Cold review R3: a missing `<s>.duplex.meta` returned class OK with reason=IDENTITY_UNKNOWN,
# so `duplexctl identity publish` exited 0 and `agentctl status/watch` — which only convert a
# NONZERO publisher exit into refusal — kept the prior DONE verdict. That is the forbidden
# shape "a refusal silently becomes OK": a stop race explains why meta vanished, it does not
# make the pre-stop conclusion safe to report as this session's result.
setup
mk_session r9 report.md
printf 'produced before the stop race\n' > "$WT/report.md"
armed="$(token r9)"
rm -f "$WATCH_RUN_DIR/r9.duplex.meta"          # ONLY the meta, exactly the reviewer's probe
out="$(ctl identity publish r9 --armed "$armed" 2>&1)"; prc=$?
chk_eq "R9 DAMAGE ORACLE: a publish with no session meta NEVER exits zero" 1 \
  "$([ "$prc" != 0 ] && echo 1 || echo 0)"
chk_eq "R9 the refusal uses the WS1 unknown exit class (2)" 2 "$prc"
chk_contains "R9 the refusal is typed on the WS1 class" "IDENTITY-UNKNOWN" "$out"
chk_contains "R9 and carries the structural reason" "reason=IDENTITY_UNKNOWN" "$out"
chk_eq "R9 nothing was published" 0 \
  "$([ -e "$WATCH_RUN_DIR/r9.terminal.json" ] && echo 1 || echo 0)"
chk_eq "R9 and no publish debris was left behind either" 0 "$(debris_count r9)"

# and the callers cannot preserve DONE: with meta gone `status` has no lane at all, and a
# PRIOR record must not be re-reported as this session's current delivered result
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/r9.terminal.json" \
  --attempt "$(ctl identity show r9 | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')" \
  --incarnation "$(ctl identity show r9 | python3 -c 'import json,sys;print(json.load(sys.stdin)["processIncarnation"])')" \
  --session "$(ctl identity show r9 | python3 -c 'import json,sys;print(json.load(sys.stdin)["sessionId"])')" \
  --deliverable "$WTP/report.md" --sha256 "$(sha_of "$WT/report.md")" \
  --size "$(wc -c < "$WT/report.md" | tr -d ' ')" --phase delivered >/dev/null
chk_eq "R9 a record left over from before the stop is not delivered without a lane" "False" \
  "$(view_field r9 delivered)"
out="$(bash "$AGENTCTL" status r9 2>&1)"; rc=$?
chk_eq "R9 status refuses an unknown session instead of reporting DONE" 1 "$rc"
chk_contains "R9 status says the session is unknown" "unknown session" "$out"
rm -f "$WATCH_RUN_DIR/r9.terminal.json"

# PAIRED GREEN: with meta intact the same publish succeeds and delivers
mk_session r9b report.md
printf 'intact lane\n' > "$WT/report.md"
out="$(ctl identity publish r9b --armed "$(token r9b)" 2>&1)"; prc=$?
chk_eq "R9 PAIRED GREEN: an intact lane publishes and exits 0" 0 "$prc"
chk_contains "R9 PAIRED GREEN: with reason=OK" "reason=OK" "$out"
chk_eq "R9 PAIRED GREEN: phase=delivered" "delivered" "$(rec_field r9b phase)"
out="$(bash "$AGENTCTL" status r9b 2>&1)"; rc=$?
chk_eq "R9 PAIRED GREEN: status still reaches DONE 0" 0 "$rc"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R10 (fix round 2, MAJOR): only the REAL platform prefix is exempt from the walk =="
# Cold review R2: `_platform_prefix()` returned the FIRST symlink in the literal session cwd
# without establishing that it is a platform alias, and `_anchor_and_parts()` then resolved and
# EXEMPTED it. With `alias -> real`, cwd `alias/cwd` and the absolute declaration
# `alias/sibling/artifact.md`, the walk started BELOW the user's link and hashed foreign bytes
# with reason=OK — the same false accept the component walk exists to prevent.
#
# The session cwd here is realpath-resolved first, exactly as `agentctl start` records it
# (`cd "$CWD" && pwd -P`), so the FIRST symlink in the literal path is the user's `alias` and
# not the platform's `/var`. That is what makes this the production shape.
setup
SBR="$(cd "$SANDBOX" && pwd -P)"          # no platform link left in the literal path
T="$SBR/p1"; mkdir -p "$T/real/cwd" "$T/real/sibling"
printf 'FOREIGN BYTES\n' > "$T/real/sibling/artifact.md"
ln -s "$T/real" "$T/alias"
foreign_sha="$(sha_of "$T/real/sibling/artifact.md")"
chk_eq "R10 arrange: the cwd literal's first symlink is the USER's alias, not a platform one" 1 \
  "$(python3 - "$T/alias/cwd" <<'PY'
import os, sys
p = ""
for part in sys.argv[1].strip(os.sep).split(os.sep):
    p = f"{p}{os.sep}{part}"
    if os.path.islink(p):
        print(1 if os.path.basename(p) == "alias" else 0); break
else:
    print(0)
PY
)"
mk_session p1 "$T/alias/sibling/artifact.md" "$T/alias/cwd"
pout="$(publish p1)"
chk_eq "R10 DAMAGE ORACLE: a user symlink in the cwd is NOT a platform prefix" "SYMLINK" \
  "$(rec_field p1 reason)"
chk_eq "R10 DAMAGE ORACLE: nothing is delivered through it" "" "$(rec_field p1 phase)"
chk_not_contains "R10 DAMAGE ORACLE: the foreign digest is nowhere in the record" "$foreign_sha" \
  "$(cat "$WATCH_RUN_DIR/p1.terminal.json")"
chk_contains "R10 the machine line types it" "reason=SYMLINK" "$pout"
# the same shape straight at the library boundary — the reviewer's probe, so the predicate is
# proven where it lives and not only through the lane
libout="$(python3 - "$AW_DIR/identity.py" "$T/alias/cwd" "$T/alias/sibling/artifact.md" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("idm", sys.argv[1]); m = u.module_from_spec(spec)
assert spec.loader; spec.loader.exec_module(m)
entries, reason, detail = m.deliverable_evidence(sys.argv[2], sys.argv[3])
print("reason", reason)
print("sha", (entries or [{}])[0].get("sha256", "-"))
PY
)"
chk_contains "R10 library boundary: deliverable_evidence refuses it too" "reason SYMLINK" "$libout"
chk_not_contains "R10 library boundary: no digest of the foreign bytes" "$foreign_sha" "$libout"

# PAIRED GREEN 1: the genuine platform prefix stays exempt — an out-of-tree ABSOLUTE path with
# no link of its own must still deliver, or every temp/CI tree on this OS class breaks
OUT="$SANDBOX/p1-out"; mkdir -p "$OUT"
printf 'honest out-of-tree artifact\n' > "$OUT/plain.md"
mk_session p1b "$OUT/plain.md" "$SANDBOX/wt"
publish p1b >/dev/null
chk_eq "R10 PAIRED GREEN: out-of-tree absolute path under the platform prefix still delivers" \
  "delivered" "$(rec_field p1b phase)"
chk_eq "R10 PAIRED GREEN: hashing the real bytes" "$(sha_of "$OUT/plain.md")" \
  "$(rec_field p1b deliverables.0.sha256)"
chk_eq "R10 PAIRED GREEN: and it validates at the read boundary" "True" "$(view_field p1b delivered)"
# PAIRED GREEN 2: a real regular path INSIDE the linked tree, declared through the resolved
# name, is unaffected by the refusal above
printf 'real sibling artifact\n' > "$T/real/sibling/ok.md"
mk_session p1c "$T/real/sibling/ok.md" "$T/real/cwd"
publish p1c >/dev/null
chk_eq "R10 PAIRED GREEN: the same file named through the REAL path delivers" "delivered" \
  "$(rec_field p1c phase)"
chk_eq "R10 PAIRED GREEN: with its real digest" "$(sha_of "$T/real/sibling/ok.md")" \
  "$(rec_field p1c deliverables.0.sha256)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R11 (fix round 2, MAJOR): a SHA-256 repository's 64-hex HEAD is a valid gitHead =="
# Cold review R2: `git_head()` honestly records the repository's HEAD, but `GITHEAD_RE` accepted
# only 40 hex — so in a SHA-256 (`--object-format=sha256`) repository the REAL publisher wrote a
# receipt that its OWN reader then rejected (`publish_rc=0`, `receipt_view_rc=3`,
# reason=IDENTITY_UNKNOWN). The binding asks for the worktree HEAD, not for a SHA-1 object id.
# This is the erased-benefit direction: a legitimate record refused by our own validator.
setup
R256="$SANDBOX/repo256"; mkdir -p "$R256"
if git init -q --object-format=sha256 "$R256" 2>/dev/null; then
  printf 'sha256 repo artifact\n' > "$R256/report.md"
  git -C "$R256" add -A
  git -C "$R256" -c user.email=t@example.com -c user.name=test commit -qm seed
  head256="$(git -C "$R256" rev-parse HEAD)"
  chk_eq "R11 arrange: this git really produced a 64-hex HEAD" 64 "${#head256}"
  mk_session g256 report.md "$R256"
  pout="$(publish g256)"; prc=$?
  chk_eq "R11 the publisher accepts the lane (exit 0)" 0 "$prc"
  chk_eq "R11 the recorded gitHead is the repository's real 64-hex HEAD" "$head256" \
    "$(rec_field g256 gitHead)"
  chk_eq "R11 DAMAGE ORACLE: our own reader does NOT reject what our publisher wrote" "True" \
    "$(view_field g256 delivered)"
  chk_eq "R11 DAMAGE ORACLE: and does not type a legitimate receipt as broken" "OK" \
    "$(view_field g256 reason)"
  rrc=0; ctl identity receipt g256 >/dev/null 2>&1 || rrc=$?
  chk_eq "R11 the receipt read API exits 0 (delivered), not 3" 0 "$rrc"
  out="$(bash "$AGENTCTL" status g256 2>&1)"; rc=$?
  chk_eq "R11 and status reaches DONE 0" 0 "$rc"
else
  echo "  NOT VERIFIED: this git ($(git --version)) cannot create --object-format=sha256 repos — the real-repo half of R11 is NOT proven here"
fi

# fixture-level, independent of git's capabilities: a 64-hex gitHead validates, a wrong length
# does not. Both directions asserted so widening the rule cannot silently accept junk.
mk_session g256b report.md
printf 'plain artifact\n' > "$WT/report.md"
good_sha="$(sha_of "$WT/report.md")"; good_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
# the entry path must be the SAME resolution the publisher and the validator share
# (declared_target: realpath'd session cwd + the declared relative path)
want_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
forge_head() { # $1 gitHead value
  python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/g256b.terminal.json" \
    --attempt "$(ctl identity show g256b | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')" \
    --incarnation "$(ctl identity show g256b | python3 -c 'import json,sys;print(json.load(sys.stdin)["processIncarnation"])')" \
    --session "$(ctl identity show g256b | python3 -c 'import json,sys;print(json.load(sys.stdin)["sessionId"])')" \
    --deliverable report.md --phase delivered --git-head "$1" \
    --deliverables-raw "[{\"path\":\"$want_path\",\"sha256\":\"$good_sha\",\"size\":$good_size}]" >/dev/null
}
forge_head "$(printf 'a%.0s' $(seq 64))"
chk_eq "R11 a 64-hex gitHead validates (SHA-256 object format)" "True" "$(view_field g256b delivered)"
forge_head "$(printf 'b%.0s' $(seq 40))"
chk_eq "R11 a 40-hex gitHead still validates (SHA-1 object format)" "True" "$(view_field g256b delivered)"
forge_head "$(printf 'c%.0s' $(seq 41))"
chk_eq "R11 DAMAGE ORACLE: 41 hex is still refused (the rule widened, it did not vanish)" "False" \
  "$(view_field g256b delivered)"
forge_head "$(printf 'd%.0s' $(seq 63))"
chk_eq "R11 DAMAGE ORACLE: 63 hex is still refused" "False" "$(view_field g256b delivered)"
forge_head "$(printf 'z%.0s' $(seq 64))"
chk_eq "R11 DAMAGE ORACLE: 64 NON-hex characters are still refused" "False" \
  "$(view_field g256b delivered)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R12 (fix round 2, MAJOR): traversal needs SEARCH on ancestors, not READ =="
# Cold review R2: the component walk opened the anchor and every ancestor with
# `O_RDONLY|O_DIRECTORY`, adding a directory READ-permission requirement ordinary pathname
# traversal does not have. With an ancestor at mode 0111 (execute-only for its owner) a plain
# `cat` of the declared regular file succeeded while `deliverable_evidence()` returned
# `UNREADABLE (EACCES)` — a legitimate deliverable refused because of how we open its parent.
setup
mkdir -p "$WT/searchonly"
printf 'artifact under a search-only directory\n' > "$WT/searchonly/report.md"
# every fixture inside the directory is created BEFORE the write bit goes away: a mode-0111
# parent denies creation, and a file that never existed proves MISSING, not UNREADABLE
printf 'unreadable\n' > "$WT/searchonly/locked.md"
chmod 000 "$WT/searchonly/locked.md"
chmod 0111 "$WT/searchonly"
if [ "$(id -u)" = 0 ]; then
  echo "  NOT VERIFIED: running as uid 0 — permission bits do not constrain root, so the R12 oracle is NOT proven here"
else
  chk_eq "R12 arrange: the ancestor is execute-only for its owner (no read bit)" "111" \
    "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$WT/searchonly")"
  chk_eq "R12 arrange: listing the directory really is denied" 1 \
    "$(ls "$WT/searchonly" >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)"
  chk_eq "R12 arrange: but the regular file itself really is readable" 1 \
    "$(cat "$WT/searchonly/report.md" >/dev/null 2>&1 && echo 1 || echo 0)"
  mk_session x1 searchonly/report.md
  pout="$(publish x1)"
  chk_eq "R12 DAMAGE ORACLE: a readable file under a search-only ancestor DELIVERS" "delivered" \
    "$(rec_field x1 phase)"
  chk_eq "R12 DAMAGE ORACLE: with the real digest, not an UNREADABLE refusal" \
    "$(sha_of "$WT/searchonly/report.md")" "$(rec_field x1 deliverables.0.sha256)"
  chk_eq "R12 reason=OK" "OK" "$(rec_field x1 reason)"
  chk_contains "R12 the machine line says so" "reason=OK" "$pout"
  chk_eq "R12 and the read boundary calls it delivered" "True" "$(view_field x1 delivered)"
  # an absolute declaration through the same search-only ancestor behaves identically
  mk_session x1b "$WT/searchonly/report.md"
  publish x1b >/dev/null
  chk_eq "R12 absolute spelling through a search-only ancestor also delivers" "delivered" \
    "$(rec_field x1b phase)"

  # PAIRED NEGATIVE: search permission is not read permission — a file the identity truly
  # cannot read is still UNREADABLE, and a symlinked search-only ancestor is still SYMLINK
  # (locked.md and its mode were set up above, before the parent lost its write bit)
  if cat "$WT/searchonly/locked.md" >/dev/null 2>&1; then
    echo "  NOT VERIFIED: this identity can still read a mode-000 file — the R12 paired negative is NOT proven here"
  else
    mk_session x1c searchonly/locked.md
    publish x1c >/dev/null
    chk_eq "R12 PAIRED NEGATIVE: an unreadable file under it is still UNREADABLE" "UNREADABLE" \
      "$(rec_field x1c reason)"
    chk_eq "R12 PAIRED NEGATIVE: and never delivered" "" "$(rec_field x1c phase)"
  fi
  chmod 644 "$WT/searchonly/locked.md"
  mkdir -p "$SANDBOX/elsewhere2"; printf 'foreign\n' > "$SANDBOX/elsewhere2/report.md"
  ln -s "$SANDBOX/elsewhere2" "$WT/searchlink"
  chmod 0111 "$SANDBOX/elsewhere2"
  mk_session x1d searchlink/report.md
  publish x1d >/dev/null
  chk_eq "R12 PAIRED NEGATIVE: a symlinked ancestor is still SYMLINK, search bits notwithstanding" \
    "SYMLINK" "$(rec_field x1d reason)"
  chmod 755 "$SANDBOX/elsewhere2"
fi
chmod 755 "$WT/searchonly"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R13 (fix round 2, MAJOR): completedAt is parsed, not shape-matched =="
# Cold review R2: `_rfc3339()` regex-matched the shape and then strptime'd only the first 19
# characters, so the ZONE OFFSET was never checked semantically — `+99:99`, `+24:00` and
# `+23:60` all validated, and such a current-stamped record could still supersede mtime with an
# impossible completion time. In the other direction it REFUSED lowercase `t`/`z`, a spelling
# RFC3339 explicitly permits. Both failure directions in one predicate.
setup
mk_session ts1 report.md
printf 'timestamp probe artifact\n' > "$WT/report.md"
ts_sha="$(sha_of "$WT/report.md")"; ts_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
ts_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
forge_ts() { # $1 completedAt value
  python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/ts1.terminal.json" \
    --attempt "$(ctl identity show ts1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')" \
    --incarnation "$(ctl identity show ts1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["processIncarnation"])')" \
    --session "$(ctl identity show ts1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["sessionId"])')" \
    --deliverable report.md --phase delivered --completed-at "$1" \
    --deliverables-raw "[{\"path\":\"$ts_path\",\"sha256\":\"$ts_sha\",\"size\":$ts_size}]" >/dev/null
}
ts_case() { # $1 completedAt  $2 expected-delivered(True/False)  $3 label
  forge_ts "$1"
  chk_eq "R13 $3 ($1)" "$2" "$(view_field ts1 delivered)"
}
# false ACCEPTS the old shape-only check let through — impossible zone offsets
ts_case "2026-08-04T14:00:00+99:99" False "DAMAGE ORACLE: an impossible offset is refused"
ts_case "2026-08-04T14:00:00+24:00" False "DAMAGE ORACLE: a 24-hour offset is refused"
ts_case "2026-08-04T14:00:00+23:60" False "DAMAGE ORACLE: a 60-minute offset is refused"
ts_case "2026-13-04T14:00:00Z"      False "DAMAGE ORACLE: month 13 is refused"
ts_case "2026-08-32T14:00:00Z"      False "DAMAGE ORACLE: day 32 is refused"
ts_case "2026-08-04T25:00:00Z"      False "DAMAGE ORACLE: hour 25 is refused"
ts_case "2026-08-04T14:00:00"       False "DAMAGE ORACLE: a timestamp with no zone is refused"
ts_case "whenever it felt like it"  False "DAMAGE ORACLE: prose is refused"
ts_case "20260804T140000Z"          False "DAMAGE ORACLE: the compact form is not RFC3339 here"
# false REJECTS the old check produced — lawful spellings
ts_case "2026-08-04t14:00:00z"      True  "PAIRED GREEN: lowercase t/z is lawful RFC3339"
ts_case "2026-08-04T14:00:00Z"      True  "PAIRED GREEN: the canonical Z form"
ts_case "2026-08-04T14:00:00+02:00" True  "PAIRED GREEN: a real positive offset"
ts_case "2026-08-04T14:00:00-07:30" True  "PAIRED GREEN: a real negative offset"
ts_case "2026-08-04T14:00:00.512Z"  True  "PAIRED GREEN: fractional seconds"
ts_case "2026-08-04T23:59:60Z"      True  "PAIRED GREEN: a leap second is lawful RFC3339"
# and the REAL publisher's own timestamp validates (the writer and the reader agree)
publish ts1 >/dev/null
chk_eq "R13 PAIRED GREEN: the publisher's own completedAt validates" "True" \
  "$(view_field ts1 delivered)"
chk_eq "R13 PAIRED GREEN: which is the canonical UTC form" 1 \
  "$(printf '%s' "$(rec_field ts1 completedAt)" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R14 (fix round 2, MINOR): the validator requires only fields the contract declares =="
# Cold review R2: `receipt_status()` required a top-level singular `deliverable` field and made
# it equal session metadata — but the binding receipt schema has `deliverables` and no singular
# form. A record carrying EVERY binding field, with the matching entry path, was refused solely
# for lacking that extension: `('invalid', "record deliverable None is not the session's
# declared 'report.md'")`. The authority is the entry PATH cross-check, which stays.
setup
mk_session c1 report.md
printf 'contract-shaped artifact\n' > "$WT/report.md"
c1_sha="$(sha_of "$WT/report.md")"; c1_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
c1_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
c1_attempt="$(ctl identity show c1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')"
c1_inc="$(ctl identity show c1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["processIncarnation"])')"
c1_session="$(ctl identity show c1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["sessionId"])')"
# a record with exactly the binding fields — no singular `deliverable` extension at all
python3 - "$WATCH_RUN_DIR/c1.terminal.json" "$c1_session" "$c1_attempt" "$c1_inc" "$c1_path" \
         "$c1_sha" "$c1_size" <<'PY'
import json, os, sys, time
path, session, attempt, inc, dpath, sha, size = sys.argv[1:8]
record = {"schemaVersion": 1, "sessionId": session, "attemptId": attempt,
          "processIncarnation": inc, "phase": "delivered", "engineOutcome": "completed",
          "deliverables": [{"path": dpath, "sha256": sha, "size": int(size)}],
          "gitHead": None, "completedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
          # the fence fields the lane itself needs; NO singular "deliverable"
          "rc": 0, "reason": "OK",
          "identity": {"sessionId": session, "attemptId": attempt,
                       "processIncarnation": inc, "seq": 1}}
tmp = path + ".forge"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(record) + "\n")
os.replace(tmp, path)
PY
chk_eq "R14 arrange: the record carries no singular 'deliverable' field" "" \
  "$(rec_field c1 deliverable)"
chk_eq "R14 DAMAGE ORACLE: a contract-shaped record is NOT refused for a missing extension" \
  "True" "$(view_field c1 delivered)"
chk_eq "R14 and it types as OK" "OK" "$(view_field c1 reason)"

# the cross-check that actually carries the weight is unaffected: an entry path that is not the
# declared deliverable is still refused, with or without the extension field
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/c1.terminal.json" \
  --attempt "$c1_attempt" --incarnation "$c1_inc" --session "$c1_session" \
  --phase delivered --deliverables-raw "[{\"path\":\"$WT/somewhere-else.md\",\"sha256\":\"$c1_sha\",\"size\":$c1_size}]" \
  >/dev/null
chk_eq "R14 PAIRED NEGATIVE: a wrong entry path is still refused" "False" "$(view_field c1 delivered)"
chk_eq "R14 PAIRED NEGATIVE: typed IDENTITY_UNKNOWN" "IDENTITY_UNKNOWN" "$(view_field c1 reason)"
# and the publisher's own record (which does carry the pre-WS2 `deliverable` field, because the
# WS1 marker always had it) keeps validating — dropping the REQUIREMENT is not dropping the field
publish c1 >/dev/null
chk_eq "R14 PAIRED GREEN: the publisher's record still validates" "True" "$(view_field c1 delivered)"
chk_eq "R14 PAIRED GREEN: and still carries the WS1 marker's deliverable field" "report.md" \
  "$(rec_field c1 deliverable)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R15 (fix round 3, BLOCKER): ONE acceptance rule — dead-pane adoption included =="
# Cold review R3: the rc and idle branches go through `delivered_receipt()` (WS1 fence + WS2
# body validator), but the DEAD-PANE adoption branch called only `marker_verdict()` and adopted
# any current-stamped rc=0 record. So the SAME canonical record was refused by one reader
# (`identity receipt` exit 3, delivered=false) and accepted as terminal truth by another
# (`classify` exit 0, "adopted the terminal marker"). A branch-specific shortcut is not a
# boundary; every reader that can conclude terminal truth goes through the same gate.
setup
dead_pane() { # $1 session — no rc file, no tmux session: exactly the adoption branch
  rm -f "$WATCH_RUN_DIR/$1.duplex.rc"
}
stamp_of() { # $1 session  $2 field
  ctl identity show "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}
mk_session d1 report.md
printf 'dead pane artifact\n' > "$WT/report.md"
d1_sha="$(sha_of "$WT/report.md")"; d1_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
d1_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
dead_pane d1
forge_d1() { # $1 completedAt
  python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/d1.terminal.json" \
    --attempt "$(stamp_of d1 attemptId)" --incarnation "$(stamp_of d1 processIncarnation)" \
    --session "$(stamp_of d1 sessionId)" --deliverable report.md --phase delivered \
    --completed-at "$1" \
    --deliverables-raw "[{\"path\":\"$d1_path\",\"sha256\":\"$d1_sha\",\"size\":$d1_size}]" >/dev/null
}
# the reviewer's case: current stamp, rc=0, phase=delivered, INVALID completedAt
forge_d1 "2026-08-04T14:00:00+99:99"
rrc=0; ctl identity receipt d1 >/dev/null 2>&1 || rrc=$?
chk_eq "R15 arrange: the canonical reader refuses this record (exit 3)" 3 "$rrc"
chk_eq "R15 arrange: and calls it not delivered" "False" "$(view_field d1 delivered)"
cout="$(ctl classify d1 2>&1)"; crc=$?
chk_eq "R15 DAMAGE ORACLE: the OTHER reader must not conclude DONE on it" 1 \
  "$([ "$crc" != 0 ] && echo 1 || echo 0)"
chk_eq "R15 DAMAGE ORACLE: it exits on the WS1 unknown class (2)" 2 "$crc"
chk_not_contains "R15 nothing is adopted" "adopted the terminal marker" "$cout"
chk_contains "R15 the refusal is typed" "IDENTITY-UNKNOWN" "$cout"
out="$(bash "$AGENTCTL" status d1 2>&1)"; rc=$?
chk_eq "R15 and agentctl status agrees with the canonical reader" 2 "$rc"
chk_eq "R15 the two readers now agree (both refuse)" 1 \
  "$([ "$rrc" != 0 ] && [ "$rc" != 0 ] && echo 1 || echo 0)"

# PAIRED GREEN 1: a VALID delivered receipt is still adopted on a dead pane, with its evidence
forge_d1 "2026-08-04T14:00:00Z"
chk_eq "R15 PAIRED GREEN: the canonical reader accepts this one" "True" "$(view_field d1 delivered)"
cout="$(ctl classify d1 2>&1)"; crc=$?
chk_eq "R15 PAIRED GREEN: dead-pane adoption still reaches DONE 0" 0 "$crc"
chk_contains "R15 PAIRED GREEN: and says it adopted the marker" "adopted the terminal marker" "$cout"
chk_contains "R15 PAIRED GREEN: with the delivered evidence summary" "sha256=${d1_sha:0:12}" "$cout"

# PAIRED GREEN 2: a receipt-less WS1 marker keeps its WS1 adoption exactly (legacy, not broken)
mk_session d2 report.md
dead_pane d2
python3 "$(pwd)/duplex-fixtures/ws1/forge_marker.py" "$WATCH_RUN_DIR/d2.terminal.json" \
  --attempt "$(stamp_of d2 attemptId)" --incarnation "$(stamp_of d2 processIncarnation)" \
  --seq 1 >/dev/null
cout="$(ctl classify d2 2>&1)"; crc=$?
chk_eq "R15 PAIRED GREEN: a legacy WS1 marker is still adopted (DONE 0)" 0 "$crc"
chk_contains "R15 PAIRED GREEN: legacy adoption is explicit" "adopted the terminal marker" "$cout"
chk_not_contains "R15 PAIRED GREEN: and claims no delivered evidence" "delivered evidence" "$cout"
# and a STALE-stamped record keeps its WS1 refusal (the fence still comes first)
mk_session d3 report.md
dead_pane d3
python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/d3.terminal.json" \
  --attempt "$(newid)" --incarnation "$(stamp_of d3 processIncarnation)" \
  --session "$(stamp_of d3 sessionId)" --deliverable report.md --phase delivered \
  --deliverables-raw "[{\"path\":\"$d1_path\",\"sha256\":\"$d1_sha\",\"size\":$d1_size}]" >/dev/null
cout="$(ctl classify d3 2>&1)"; crc=$?
chk_eq "R15 PAIRED GREEN: a stale-stamped record is still refused by the fence" 2 "$crc"
chk_contains "R15 PAIRED GREEN: with the WS1 stale class" "STALE-ATTEMPT" "$cout"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R16 (fix round 3, MAJOR): the inside-cwd absolute shortcut no longer resolves a link away =="
# Cold review R3 (still-open half of R10): `_anchor_and_parts()` treated an absolute declaration
# as "inside the session cwd" whenever some prefix of it had the same realpath as the cwd, and
# then anchored at the RESOLVED cwd — so with `alias -> real`, cwd `alias/cwd` and declared
# `alias/cwd/report.md` the descriptor walk started BELOW `alias` and could no longer observe it:
# `reason=OK`, recorded `real/cwd/report.md`, bytes behind the link digested. The final/ancestor
# rule has no exception for a user-owned prefix.
setup
SBR2="$(cd "$SANDBOX" && pwd -P)"
T2="$SBR2/p2"; mkdir -p "$T2/real/cwd"
printf 'BEHIND THE LINK\n' > "$T2/real/cwd/report.md"
ln -s "$T2/real" "$T2/alias"
behind_sha="$(sha_of "$T2/real/cwd/report.md")"
mk_session p2 "$T2/alias/cwd/report.md" "$T2/alias/cwd"
pout="$(publish p2)"
chk_eq "R16 DAMAGE ORACLE: an absolute declaration INSIDE an aliased cwd is refused" "SYMLINK" \
  "$(rec_field p2 reason)"
chk_eq "R16 DAMAGE ORACLE: nothing is delivered" "" "$(rec_field p2 phase)"
chk_not_contains "R16 DAMAGE ORACLE: the bytes behind the link were never digested" "$behind_sha" \
  "$(cat "$WATCH_RUN_DIR/p2.terminal.json")"
chk_contains "R16 the machine line types it" "reason=SYMLINK" "$pout"
libout="$(python3 - "$AW_DIR/identity.py" "$T2/alias/cwd" "$T2/alias/cwd/report.md" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("idm", sys.argv[1]); m = u.module_from_spec(spec)
assert spec.loader; spec.loader.exec_module(m)
entries, reason, detail = m.deliverable_evidence(sys.argv[2], sys.argv[3])
print("reason", reason)
print("recorded", (entries or [{}])[0].get("path", "-"))
print("sha", (entries or [{}])[0].get("sha256", "-"))
PY
)"
chk_contains "R16 library boundary: the reviewer's own probe refuses it" "reason SYMLINK" "$libout"
chk_not_contains "R16 library boundary: no digest behind the link" "$behind_sha" "$libout"
chk_not_contains "R16 library boundary: and no resolved path is recorded" "real/cwd/report.md" "$libout"

# PAIRED GREEN 1: the SAME file, declared absolutely through its real path, delivers
mk_session p2b "$T2/real/cwd/report.md" "$T2/real/cwd"
publish p2b >/dev/null
chk_eq "R16 PAIRED GREEN: the real absolute path delivers" "delivered" "$(rec_field p2b phase)"
chk_eq "R16 PAIRED GREEN: with the file's real digest" "$behind_sha" \
  "$(rec_field p2b deliverables.0.sha256)"
# PAIRED GREEN 2: the RELATIVE spelling keeps anchoring at the session's own resolved cwd — the
# operator's cwd is the trust root, and production records it already resolved (`pwd -P`)
mk_session p2c report.md "$T2/alias/cwd"
publish p2c >/dev/null
chk_eq "R16 PAIRED GREEN: a relative declaration under the same cwd still delivers" "delivered" \
  "$(rec_field p2c phase)"
chk_eq "R16 PAIRED GREEN: hashing the file the operator named" "$behind_sha" \
  "$(rec_field p2c deliverables.0.sha256)"
# PAIRED GREEN 3: an absolute declaration under a platform-alias temp root still delivers
printf 'platform-rooted artifact\n' > "$WT/plat2.md"
mk_session p2d "$WT/plat2.md"
publish p2d >/dev/null
chk_eq "R16 PAIRED GREEN: absolute path under the platform prefix still delivers" "delivered" \
  "$(rec_field p2d phase)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R17 (fix round 3, MAJOR): evidence values are matched in FULL, newline included =="
# Cold review R3 (still-open half of R11): Python's `$` matches immediately before a trailing
# newline, so `[0-9a-f]{40}$` accepted a 41-character value ending in "\n" — and the same defect
# accepted a 65-character sha256 and a newline-extended completedAt. `receipt_status()` returned
# ok / delivered=true on all of them. Malformed evidence must not pass the canonical reader.
setup
mk_session n1 report.md
printf 'anchor probe artifact\n' > "$WT/report.md"
n1_sha="$(sha_of "$WT/report.md")"; n1_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
n1_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
n1_attempt="$(stamp_of n1 attemptId)"; n1_inc="$(stamp_of n1 processIncarnation)"
n1_session="$(stamp_of n1 sessionId)"
# the forge fixture writes JSON, so the trailing newline has to be INSIDE the string value —
# python builds these records directly, exactly like the reviewer's probes
forge_raw() { # $1 gitHead-json  $2 sha256-json  $3 completedAt-json
  python3 - "$WATCH_RUN_DIR/n1.terminal.json" "$n1_session" "$n1_attempt" "$n1_inc" \
           "$n1_path" "$n1_size" "$1" "$2" "$3" <<'PY'
import json, os, sys
path, session, attempt, inc, dpath, size, head, sha, at = sys.argv[1:10]
record = {"schemaVersion": 1, "rc": 0, "reason": "OK", "deliverable": "report.md",
          "sessionId": session, "attemptId": attempt, "processIncarnation": inc,
          "phase": "delivered", "engineOutcome": "completed",
          "completedAt": json.loads(at), "gitHead": json.loads(head),
          "deliverables": [{"path": dpath, "sha256": json.loads(sha), "size": int(size)}],
          "identity": {"sessionId": session, "attemptId": attempt,
                       "processIncarnation": inc, "seq": 1}}
tmp = path + ".forge"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(record) + "\n")
os.replace(tmp, path)
PY
}
good_at='"2026-08-04T14:00:00Z"'
sha40="$(printf 'a%.0s' $(seq 40))"; sha64="$(printf 'b%.0s' $(seq 64))"
forge_raw "\"$sha40\\n\"" "\"$n1_sha\"" "$good_at"
chk_eq "R17 DAMAGE ORACLE: a 40-hex gitHead with a trailing newline is refused (len 41)" "False" \
  "$(view_field n1 delivered)"
chk_eq "R17 and typed IDENTITY_UNKNOWN" "IDENTITY_UNKNOWN" "$(view_field n1 reason)"
forge_raw "\"$sha64\\n\"" "\"$n1_sha\"" "$good_at"
chk_eq "R17 DAMAGE ORACLE: a 64-hex gitHead with a trailing newline is refused (len 65)" "False" \
  "$(view_field n1 delivered)"
forge_raw "null" "\"$n1_sha\\n\"" "$good_at"
chk_eq "R17 DAMAGE ORACLE: a sha256 with a trailing newline is refused (len 65)" "False" \
  "$(view_field n1 delivered)"
forge_raw "null" "\"$n1_sha\"" '"2026-08-04T14:00:00Z\n"'
chk_eq "R17 DAMAGE ORACLE: a completedAt with a trailing newline is refused" "False" \
  "$(view_field n1 delivered)"
forge_raw "null" "\"$n1_sha\"" '" 2026-08-04T14:00:00Z"'
chk_eq "R17 DAMAGE ORACLE: a leading space in completedAt is refused" "False" \
  "$(view_field n1 delivered)"
forge_raw "\" $sha40\"" "\"$n1_sha\"" "$good_at"
chk_eq "R17 DAMAGE ORACLE: a leading space in gitHead is refused" "False" "$(view_field n1 delivered)"
forge_raw "null" "\"$n1_sha \"" "$good_at"
chk_eq "R17 DAMAGE ORACLE: a trailing space in sha256 is refused" "False" "$(view_field n1 delivered)"

# PAIRED GREEN: the clean values of both legitimate widths still deliver
forge_raw "\"$sha40\"" "\"$n1_sha\"" "$good_at"
chk_eq "R17 PAIRED GREEN: a clean 40-hex gitHead delivers" "True" "$(view_field n1 delivered)"
forge_raw "\"$sha64\"" "\"$n1_sha\"" "$good_at"
chk_eq "R17 PAIRED GREEN: a clean 64-hex gitHead delivers" "True" "$(view_field n1 delivered)"
forge_raw "null" "\"$n1_sha\"" '"2026-08-04t14:00:00z"'
chk_eq "R17 PAIRED GREEN: a clean lowercase RFC3339 still delivers" "True" "$(view_field n1 delivered)"
publish n1 >/dev/null
chk_eq "R17 PAIRED GREEN: the publisher's own record still delivers" "True" "$(view_field n1 delivered)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== R18 (fix round 3, MAJOR): a leap second is only lawful at the end of a UTC day =="
# Cold review R3: fix round 2 rewrote EVERY `:60` seconds value to `:59` before parsing, without
# constraining it to a leap-second POSITION. `2026-08-04T14:00:60Z` therefore returned
# receipt_status=ok / delivered=true — 14:00:60 UTC is not a lawful instant in any calendar.
# A leap second exists only as the 61st second of the last UTC minute of a day.
setup
mk_session ls1 report.md
printf 'leap second probe\n' > "$WT/report.md"
ls_sha="$(sha_of "$WT/report.md")"; ls_size="$(wc -c < "$WT/report.md" | tr -d ' ')"
ls_path="$(python3 -c 'import os,sys; print(os.path.join(os.path.realpath(sys.argv[1]), "report.md"))' "$WT")"
forge_ls() { # $1 completedAt
  python3 "$WS2/forge_receipt.py" "$WATCH_RUN_DIR/ls1.terminal.json" \
    --attempt "$(stamp_of ls1 attemptId)" --incarnation "$(stamp_of ls1 processIncarnation)" \
    --session "$(stamp_of ls1 sessionId)" --deliverable report.md --phase delivered \
    --completed-at "$1" \
    --deliverables-raw "[{\"path\":\"$ls_path\",\"sha256\":\"$ls_sha\",\"size\":$ls_size}]" >/dev/null
}
ls_case() { # $1 completedAt  $2 expected-delivered  $3 label
  forge_ls "$1"
  chk_eq "R18 $3 ($1)" "$2" "$(view_field ls1 delivered)"
}
ls_case "2026-08-04T14:00:60Z"       False "DAMAGE ORACLE: a leap second mid-day is refused"
ls_case "2026-08-04T00:00:60Z"       False "DAMAGE ORACLE: a leap second at midnight-start is refused"
ls_case "2026-08-04T23:58:60Z"       False "DAMAGE ORACLE: a leap second in the second-to-last minute is refused"
ls_case "2026-08-04T22:59:60Z"       False "DAMAGE ORACLE: a leap second an hour early is refused"
ls_case "2026-08-04T23:59:60+02:00"  False "DAMAGE ORACLE: 23:59:60 at a +02:00 offset is not the UTC day end"
# lawful positions: the last second of a UTC day, in any spelling of that same instant
ls_case "2016-12-31T23:59:60Z"       True  "PAIRED GREEN: the canonical UTC leap second"
ls_case "2016-12-31T18:59:60-05:00"  True  "PAIRED GREEN: the same instant written at -05:00"
ls_case "2017-01-01T00:59:60+01:00"  True  "PAIRED GREEN: and at +01:00"
ls_case "2016-12-31t23:59:60z"       True  "PAIRED GREEN: lowercase spelling of it"
# ordinary timestamps are untouched by the rule
ls_case "2026-08-04T14:00:59Z"       True  "PAIRED GREEN: an ordinary :59 second still delivers"
ls_case "2026-08-04T23:59:59Z"       True  "PAIRED GREEN: the last ordinary second of a day"
publish ls1 >/dev/null
chk_eq "R18 PAIRED GREEN: the publisher's own timestamp still validates" "True" \
  "$(view_field ls1 delivered)"
teardown

summary
