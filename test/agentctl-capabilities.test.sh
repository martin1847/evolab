#!/usr/bin/env bash
# WS3 — runtime-generated provider capability contract (2026-08-05, fix round 1).
#
# Field motive: provider capability truth lived in TWO hand-maintained places — the routing
# and rejection sites in duplexctl.py, and a prose matrix in the main SKILL.md. Nothing
# mechanically tied them together, so the prose could promise a capability the lane refuses
# (or hide a degradation the lane silently performs) and no test would notice. Contract now:
# ONE provider table in duplexctl.py from which routes, projector selection and the shell
# launch spec are all GENERATED, and which the routing reads back (route = the wire name a
# branch emits, refusal = the sentence a refused verb prints).
#
# Fix round 1 (cold review R1 BLOCKER): registry agreement is NOT evidence. The reviewer
# changed three real behaviours — the codex handshake's resume method, omp's pending-question
# projection, the launch branch name — and the structural suite stayed 72/72 green. §C8 is the
# answer: every declared non-unsupported capability is EXERCISED against the hermetic fake
# engines and asserted by its observable effect (a frame on the wire, a typed exit, a launch
# command), so a provider that stops performing what it declares reds here.
#
# Harness: hermetic. C1-C7 introspect the REAL module through duplex-fixtures/ws3/probe.py and
# drive `agentctl steer` over synthesized lanes (every capability refusal fires before any
# transport, so no engine is needed). C8 uses the process-running fake tmux + the scriptable
# fake engines — real fifo, real flock, real events pipeline, no real tmux and no tokens.
# Every negative case carries a PAIRED GREEN: refusing a capability the provider really has is
# a failure too.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

FIX="$(pwd)/duplex-fixtures"
WS3="$FIX/ws3"
probe() { python3 "$WS3/probe.py" "$@"; }
caps() { bash "$AGENTCTL" capabilities "$@"; }

# The suite's OWN oracle. Adding a provider is one edit in duplexctl's PROVIDERS table plus
# one edit here — a test with no independent expectation asserts nothing.
ALL_PROVIDERS="claude codex omp"

setup() {
  sandbox_new
  WT="$SANDBOX/wt"; mkdir -p "$WT"
}
teardown() { sandbox_clean; }

# A duplex lane with no engine behind it: meta (engine + cwd) is everything the capability
# gate needs, because a capability refusal must land BEFORE any frame reaches the fifo.
mk_lane() { # $1 name  $2 engine  [$3 extra meta line]
  { printf 'engine=%s\ncwd=%s\n' "$2" "$WT"
    [ -n "${3:-}" ] && printf '%s\n' "$3"; : ; } > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
}

codex_turn() { # $1 session  $2 started|completed
  local f
  f='{"method":"turn/started","params":{"threadId":"T1","turn":{"id":"t1"}}}'
  [ "$2" = completed ] && f='{"method":"turn/completed","params":{"threadId":"T1","turn":{"id":"t1","status":"completed"}}}'
  printf '%s\n' "$f" >> "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
}

# Tolerant JSON reader: a missing key prints "" so a mutation reds through the suite's own
# damage assertion, never through a KeyError traceback (cold review R1, MAJOR).
json_field() { # $1 dotted path into the --json document
  caps --json | python3 -c '
import json, sys
node = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    if isinstance(node, dict):
        node = node.get(part)
    elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
        node = node[int(part)]
    else:
        node = None
    if node is None:
        print(""); raise SystemExit(0)
print(node if not isinstance(node, (dict, list)) else json.dumps(node, sort_keys=True))
' "$1"
}

sorted_list() { printf '%s\n' $1 | sort | tr '\n' ' '; }

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C1: every provider adapter appears in the capability output =="
setup
want="$(sorted_list "$ALL_PROVIDERS")"
chk_eq "C1 DAMAGE ORACLE: the contract covers exactly the lane's adapters" \
  "$want" "$(probe providers | tr '\n' ' ')"
chk_eq "C1 DAMAGE ORACLE: every adapter with a ROUTE REGISTRY has a contract" \
  "$want" "$(probe routeproviders | tr '\n' ' ')"
chk_eq "C1 every engine the state projector serves is contracted" \
  "$want" "$(probe projectorproviders | tr '\n' ' ')"
# the shell side has no list of its own: agentctl's allowlist and launch command both come
# from this generated spec, so it is the surface C1 must check (cold review R1)
chk_eq "C1 the generated launch spec covers exactly the contracted providers" \
  "$want" "$(probe specproviders | tr '\n' ' ')"
chk_eq "C1 agentctl's provider names come from that same generator" "$want" \
  "$(python3 "$WS3/../../../skills/cto-orchestration/references/agentctl/duplexctl.py" providers | sort | tr '\n' ' ')"
for e in $ALL_PROVIDERS; do
  chk_contains "C1 the human table has a column for $e" "$e" "$(caps | sed -n 2p)"
  chk_eq "C1 $e appears in the machine document" "1" \
    "$(caps --json | python3 -c 'import json,sys;print(1 if sys.argv[1] in json.load(sys.stdin)["providers"] else 0)' "$e")"
  chk_eq "C1 $e has a launch spec row (binary + argv)" 1 \
    "$([ -n "$(probe spec "$e" bin)" ] && echo 1 || echo 0)"
done
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C2: every declared non-unsupported capability has an EXECUTABLE realization =="
setup
# THE predicate: nothing may be advertised at supported/degraded/experimental unless a real
# branch (or a declared non-protocol surface) performs it.
chk_eq "C2 DAMAGE ORACLE: every declared non-unsupported capability resolves to a branch" "" \
  "$(probe drift | grep -E 'no declared route|no executable branch|not executable|exactly one of route' || true)"
# the declared route id IS the wire name the branch emits, not a label near it
chk_eq "C2 omp queuedSteer emits the frame type it declares" \
  "declared=follow_up emitted=follow_up" "$(probe wire omp steer)"
chk_eq "C2 omp midTurnSteer emits the frame type it declares" \
  "declared=steer emitted=steer" "$(probe wire omp steer-now)"
chk_eq "C2 omp replaceTurn emits the frame type it declares" \
  "declared=abort_and_prompt emitted=abort_and_prompt" "$(probe wire omp replace)"
chk_eq "C2 claude queuedSteer emits the frame type it declares" \
  "declared=user emitted=user" "$(probe wire claude steer)"
chk_eq "C2 codex queuedSteer sends the method it declares" \
  "declared=turn/start emitted=turn/start" "$(probe wire codex steer)"
chk_eq "C2 codex midTurnSteer sends the method it declares" \
  "declared=turn/steer emitted=turn/steer" "$(probe wire codex steer-now)"
chk_eq "C2 codex replaceTurn sends BOTH methods of its route, in order" \
  "declared=turn/interrupt+turn/start emitted=turn/interrupt+turn/start" \
  "$(probe wire codex replace)"
# non-verb capabilities resolve too: structuredAsk through the projector, codex resume through
# the handshake, omp/claude resume through the declared start-argv surface
chk_eq "C2 omp structuredAsk names a route with an executable branch" "extension_ui_request" \
  "$(probe cell omp structuredAsk route)"
chk_contains "C2 and that route is registered" "extension_ui_request" "$(probe routes omp)"
chk_eq "C2 codex resume names the handshake route" "thread/resume" \
  "$(probe cell codex resume route)"
chk_contains "C2 and that route is registered" "thread/resume" "$(probe routes codex)"
chk_eq "C2 omp resume declares the start-argv surface instead of a wire route" "start-argv" \
  "$(probe cell omp resume surface)"
chk_eq "C2 and the provider really does forward start args" "1" "$(probe spec omp extra_argv)"
chk_eq "C2 claude resume likewise" "start-argv" "$(probe cell claude resume surface)"
chk_eq "C2 and claude forwards start args too" "1" "$(probe spec claude extra_argv)"
# the other direction: an unsupported capability claims no realization at all
chk_eq "C2 claude replaceTurn claims no route (it has no branch)" "" \
  "$(probe cell claude replaceTurn route)"
chk_eq "C2 claude replaceTurn claims no surface either" "" \
  "$(probe cell claude replaceTurn surface)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C3: an unsupported operation is REJECTED and the message names the supported path =="
setup
mk_lane cl3 claude
out="$(bash "$AGENTCTL" steer cl3 -m "start over" --replace 2>&1)"; rc=$?
chk_eq "C3 DAMAGE ORACLE: claude --replace is refused, never degraded into something lesser" \
  1 "$rc"
chk_contains "C3 the refusal says WHY" "claude has no interrupt/replace frame" "$out"
chk_contains "C3 the refusal names the supported path (stop)" "agentctl stop" "$out"
chk_contains "C3 the refusal names the supported path (resume)" "--resume <session_id>" "$out"
chk_eq "C3 the refusal text IS the published note (one sentence, two surfaces)" \
  "$(probe cell claude replaceTurn refusal)" "$(json_field providers.claude.replaceTurn.note)"
chk_eq "C3 nothing was delivered: no write-intent, no frame" 0 \
  "$([ -e "$WATCH_RUN_DIR/cl3.duplex.write-intent" ] && echo 1 || echo 0)"

# codex's conditional refusal: the route EXISTS but has no queue, so a busy turn is refused
mk_lane cx3 codex "thread=T1"
codex_turn cx3 started
out="$(bash "$AGENTCTL" steer cx3 -m "queue me" 2>&1)"; rc=$?
chk_eq "C3 DAMAGE ORACLE: a busy codex default steer is refused (there is no queue)" 1 "$rc"
chk_contains "C3 the refusal says WHY" "codex has no queue" "$out"
chk_contains "C3 the refusal names the supported path" "use --now" "$out"
chk_eq "C3 the codex refusal is the table's own text" \
  "$(probe cell codex queuedSteer refusal)" \
  "$(printf '%s' "$out" | sed -n 's/^ERR: //p' | tr -d '\n')"
# and --now with NO active turn is refused in the other direction, before any transport
mk_lane cx3b codex "thread=T1"
out="$(bash "$AGENTCTL" steer cx3b -m "adjust" --now 2>&1)"; rc=$?
chk_eq "C3 an idle --now is refused too (nothing to steer mid-turn)" 1 "$rc"
chk_contains "C3 and points at the default steer" "default steer starts the next turn" "$out"
# a start flag that no provider capability declares is refused at start, with the pointer
# (a real non-empty goal: the empty-contract refusal sits earlier on the parameter surface)
printf 'x\nPreflight: true => ok\n' > "$WATCH_RUN_DIR/cx3c.goal.md"
out="$(bash "$AGENTCTL" start omp cx3c "$WT" --goal "$WATCH_RUN_DIR/cx3c.goal.md" --resume-thread x 2>&1)"; rc=$?
chk_eq "C3 --resume-thread on a provider whose resume declares no such flag is refused" 1 "$rc"
chk_contains "C3 and the refusal points at the runtime contract" "agentctl capabilities" "$out"

# PAIRED GREEN: a SUPPORTED capability is never refused by the gate. omp --replace reaches
# the transport (the lane has no engine, so it dies there) with no capability refusal at all.
mk_lane om3 omp
out="$(bash "$AGENTCTL" steer om3 -m "start over" --replace 2>&1)"; rc=$?
chk_not_contains "C3 PAIRED GREEN: omp --replace is not refused by the capability gate" \
  "no interrupt" "$out"
chk_contains "C3 PAIRED GREEN: it got as far as the transport" "fifo has no reader" "$out"
# PAIRED GREEN: an IDLE codex default steer is not refused either
mk_lane cx3d codex "thread=T1"
codex_turn cx3d started
codex_turn cx3d completed
out="$(bash "$AGENTCTL" steer cx3d -m "next turn please" 2>&1)"; rc=$?
chk_not_contains "C3 PAIRED GREEN: an idle codex steer is NOT refused" "codex has no queue" "$out"
chk_contains "C3 PAIRED GREEN: it reached the transport" "fifo has no reader" "$out"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C4: claude's degraded queued fallback is NEVER advertised as native mid-turn steering =="
setup
chk_eq "C4 DAMAGE ORACLE: claude midTurnSteer is degraded, not supported" "degraded" \
  "$(probe cell claude midTurnSteer state)"
chk_eq "C4 DAMAGE ORACLE: the published state agrees" "degraded" \
  "$(json_field providers.claude.midTurnSteer.state)"
note="$(json_field providers.claude.midTurnSteer.note)"
chk_eq "C4 a degraded state carries a note" 1 "$([ -n "$note" ] && echo 1 || echo 0)"
chk_contains "C4 the note names the degradation as a QUEUED steer" "QUEUED" "$note"
chk_contains "C4 and denies it is native mid-turn steering" "NOT native mid-turn" "$note"
chk_not_contains "C4 the human table never calls it supported" \
  "midTurnSteer           supported     supported" "$(caps)"
# the RUNTIME behaves the way the contract says: --now says the degradation out loud and is
# delivered as a queued steer, never silently
mk_lane cl4 claude
out="$(bash "$AGENTCTL" steer cl4 -m "adjust now" --now 2>&1)"; rc=$?
chk_contains "C4 the runtime prints the degradation before delivering" \
  "delivered as a QUEUED steer" "$out"
chk_eq "C4 the printed degradation IS the published note" 1 \
  "$([ -n "$note" ] && printf '%s' "$out" | grep -cF "$note" || echo 0)"
chk_not_contains "C4 and it is not refused (the fallback is a real path)" \
  "no interrupt/replace frame" "$out"
# PAIRED GREEN: the providers that DO have native mid-turn steering still say supported
chk_eq "C4 PAIRED GREEN: omp midTurnSteer is native" "supported" \
  "$(probe cell omp midTurnSteer state)"
chk_eq "C4 PAIRED GREEN: codex midTurnSteer is native" "supported" \
  "$(probe cell codex midTurnSteer state)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C5: codex and omp stay provider-specific — no flattened false-common contract =="
setup
omp_map="$(probe map omp)"; codex_map="$(probe map codex)"; claude_map="$(probe map claude)"
chk_eq "C5 DAMAGE ORACLE: codex's map is NOT identical to omp's" 1 \
  "$([ "$omp_map" != "$codex_map" ] && echo 1 || echo 0)"
chk_eq "C5 DAMAGE ORACLE: claude's map is NOT identical to omp's" 1 \
  "$([ "$omp_map" != "$claude_map" ] && echo 1 || echo 0)"
chk_eq "C5 DAMAGE ORACLE: claude's map is NOT identical to codex's" 1 \
  "$([ "$codex_map" != "$claude_map" ] && echo 1 || echo 0)"
# the differences are the REAL ones, not incidental: omp queues natively, codex cannot;
# codex resumes in-session through the protocol, omp/claude only through a stop+start
chk_eq "C5 omp queues natively" "supported" "$(probe cell omp queuedSteer state)"
chk_eq "C5 codex has no queue" "degraded" "$(probe cell codex queuedSteer state)"
chk_eq "C5 codex resumes in-session through the handshake" "supported" \
  "$(probe cell codex resume state)"
chk_eq "C5 omp resume is degraded (stop + start-argv, no in-session route)" "degraded" \
  "$(probe cell omp resume state)"
chk_eq "C5 the published document keeps the same distinction" "degraded" \
  "$(json_field providers.codex.queuedSteer.state)"
chk_eq "C5 and does not copy omp's answer onto codex" "supported" \
  "$(json_field providers.omp.queuedSteer.state)"
# the criterion itself is written down, so a cell cannot be judged by a private rule
chk_contains "C5 the resume criterion is published next to the table" \
  "in-session route, or stop + start with resume args" "$(caps)"
# The two sandbox tiers are STATIC in the published text: `capabilities` has no session to read
# a tier out of, so it must name BOTH. An operator choosing between the execution seat and the
# review seat reads exactly this row, and a runtime that published only the default tier would
# hide the review seat entirely. Existing C6 assertions pin key SETS, never the wording — so
# without these three the refusal string could drop a tier and stay green.
caps_text="$(caps)"
chk_contains "C5 the default sandbox tier is published" "danger-full-access" "$caps_text"
chk_contains "C5 and the review tier is published bound to its flag" 'danger-full-access (`--review`' "$caps_text"
chk_contains "C5 the review tier names the flag that selects it" '`--review`' "$caps_text"
# ONE table, not two literals: the published text and the shell launch spec read the same dict
chk_eq "C5 the review tier reaches the shell spec from that same table" "danger-full-access" \
  "$(probe spec codex review_sandbox)"
chk_eq "C5 DAMAGE ORACLE: a provider with no OS sandbox declares no tier at all" "" \
  "$(probe spec omp review_sandbox)"
chk_eq "C5 every capability has a written definition" "" \
  "$(probe drift | grep 'no written definition' || true)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C6: --json is a stable machine shape — exact keys, closed states, notes in exactly one place =="
setup
doc="$(caps --json)"
chk_eq "C6 the document parses as JSON" 1 \
  "$(printf '%s' "$doc" | python3 -c 'import json,sys
try:
    json.load(sys.stdin); print(1)
except Exception:
    print(0)')"
chk_eq "C6 the top level is exactly schemaVersion + providers" "providers,schemaVersion" \
  "$(printf '%s' "$doc" | python3 -c 'import json,sys;print(",".join(sorted(json.load(sys.stdin))))')"
chk_eq "C6 schemaVersion is 1" "1" "$(json_field schemaVersion)"
chk_eq "C6 every provider declares EXACTLY the seven contract capabilities" "ok" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
want = {"queuedSteer","midTurnSteer","replaceTurn","structuredAsk","structuredReply",
        "resume","permissionEnforcement"}
bad = [p + ":" + ",".join(sorted(set(c) ^ want))
       for p, c in json.load(sys.stdin)["providers"].items() if set(c) != want]
print("ok" if not bad else ";".join(bad))')"
chk_eq "C6 every cell has only {state} or {state,note} — no internal fields leak" "ok" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
bad = [p + "." + n + ":" + ",".join(sorted(set(cell) - {"state", "note"}))
       for p, caps in json.load(sys.stdin)["providers"].items()
       for n, cell in caps.items() if set(cell) - {"state", "note"}]
print("ok" if not bad else ";".join(bad))')"
chk_eq "C6 DAMAGE ORACLE: no route / refusal / surface / fallback is published" 0 \
  "$(printf '%s' "$doc" | grep -cE '"(route|refusal|surface|fallback|impl|detect|start_flag)"')"
chk_eq "C6 every state is inside the closed enum, and none is a boolean" "ok" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
ok = {"supported", "degraded", "unsupported", "experimental"}
bad = [p + "." + n + "=" + repr(cell["state"])
       for p, caps in json.load(sys.stdin)["providers"].items()
       for n, cell in caps.items()
       if not isinstance(cell["state"], str) or cell["state"] not in ok]
print("ok" if not bad else ";".join(bad))')"
# BOTH directions of the note rule (cold review R1, MAJOR): a note exactly where the state is
# not self-explanatory — required on degraded and unsupported, forbidden anywhere else.
chk_eq "C6 DAMAGE ORACLE: every degraded AND every unsupported cell carries a note" "ok" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
bad = [p + "." + n + "[" + cell["state"] + "]"
       for p, caps in json.load(sys.stdin)["providers"].items()
       for n, cell in caps.items()
       if cell["state"] in ("degraded", "unsupported") and not cell.get("note")]
print("ok" if not bad else ";".join(bad))')"
chk_eq "C6 DAMAGE ORACLE: no supported or experimental cell carries a note" "ok" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
bad = [p + "." + n + "[" + cell["state"] + "]"
       for p, caps in json.load(sys.stdin)["providers"].items()
       for n, cell in caps.items()
       if cell["state"] in ("supported", "experimental") and "note" in cell]
print("ok" if not bad else ";".join(bad))')"
chk_eq "C6 the rule is not vacuous: both classes really occur in the document" "1 1" \
  "$(printf '%s' "$doc" | python3 -c '
import json, sys
d = json.load(sys.stdin)["providers"]
noted = any(cell.get("note") for caps in d.values() for cell in caps.values())
bare = any("note" not in cell for caps in d.values() for cell in caps.values())
print(int(noted), int(bare))')"
# the human surface is not a second source: every state it prints is read back and compared
# to the machine document, cell by cell
chk_eq "C6 the human table and the document agree on every cell" "ok" \
  "$(caps | python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))["providers"]
rows = [l.rstrip() for l in sys.stdin if l.strip()]
engines = rows[1].split()[1:]
bad = []
for row in rows[2:2 + 7]:
    parts = row.split()
    for engine, state in zip(engines, parts[1:]):
        if doc.get(engine, {}).get(parts[0], {}).get("state") != state:
            bad.append(engine + "." + parts[0])
print("ok" if not bad else ";".join(bad))' <(caps --json))"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C7 DRIFT GATE: the table and the derived registries cannot diverge =="
setup
out="$(probe drift 2>&1)"; rc=$?
chk_eq "C7 DAMAGE ORACLE: no drift between the capability table and the routing" 0 "$rc"
chk_eq "C7 and the gate says so explicitly" "DRIFT: none" "$out"
chk_eq "C7 the gate covers all 21 cells (3 providers x 7 capabilities)" 21 \
  "$(for e in $ALL_PROVIDERS; do probe capkeys "$e"; done | grep -c .)"
chk_eq "C7 every registered route is declared by a capability" "" \
  "$(probe drift | grep 'routes with no declared capability' || true)"
teardown

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== C8 BEHAVIOUR GATE: a declared capability is PERFORMED, not merely registered =="
# Cold review R1 (BLOCKER): the structural gate above compares the table to registries derived
# FROM the table, so it cannot see a consumer that stopped doing the declared thing. The
# reviewer proved it — codex's handshake resume method, omp's WAITING projection and the launch
# branch name were each broken with the suite fully green. Everything below asserts an
# OBSERVABLE EFFECT of the real code path against the scriptable fake engines: a frame on the
# wire, a typed exit code, a launch command line.
install_running_tmux() {
  export FAKE_TMUX_STATE="$SANDBOX/tmux-state"
  mkdir -p "$FAKE_TMUX_STATE"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
name=""; cwd=""; cmd=""
while [ "$#" -gt 0 ]; do case "$1" in
  -s|-t) name="$2"; shift 2;;
  -c) cwd="$2"; shift 2;;
  -d|-p) shift;;
  *) cmd="$1"; shift;;
esac; done
name="${name#=}"; name="${name%:}"
case "$sub" in
  new-session)
    [ -n "${FAKE_TMUX_LAUNCH_LOG:-}" ] && printf '%s\n' "$cmd" >> "$FAKE_TMUX_LAUNCH_LOG"
    ( cd "${cwd:-/}" && exec bash -c "$cmd" ) >/dev/null 2>&1 &
    echo $! > "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  has-session)
    pid="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)" || exit 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null ;;
  kill-session)
    pid="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)"
    if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
    rm -f "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/tmux"
}
sweep_fakes() {
  local pidfile pid
  for pidfile in "$FAKE_TMUX_STATE"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
  done
  pkill -f "duplex-fixtures/fake_omp_duplex" 2>/dev/null
  pkill -f "duplex-fixtures/fake_claude_duplex" 2>/dev/null
  pkill -f "duplex-fixtures/fake_codex_duplex" 2>/dev/null
  return 0
}

setup
install_running_tmux
export FAKE_TMUX_LAUNCH_LOG="$SANDBOX/launch.log"
printf 'do the thing\nPreflight: ls duplex-fixtures => fake engines on disk\n' > "$SANDBOX/goal.md"
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
export AGENTCTL_BIN_CLAUDE="$FIX/fake_claude_duplex.py"
export AGENTCTL_BIN_CODEX="$FIX/fake_codex_duplex.py"

# ── every provider launches under its DECLARED name and pinned argv ──────────────────────
for e in omp claude codex; do
  export FAKE_PROVIDER_LOG="$SANDBOX/$e.log"
  # codex is the extra_argv=0 lane: --model must ride the PROTOCOL. The negative assertion
  # below only bites if the start actually carries one (a --model-free start asserts nothing).
  MDL=""; [ "$e" = codex ] && MDL="--model gpt-fake"
  # shellcheck disable=SC2086 -- deliberate split: MDL is a literal two-token flag, or empty
  out="$(bash "$AGENTCTL" start "$e" "b_$e" "$WT" --goal "$SANDBOX/goal.md" $MDL 2>&1)"; rc=$?
  chk_eq "C8 BEHAVIOUR: '$e' is a launchable provider name (start rc0)" 0 "$rc"
  chk_eq "C8 BEHAVIOUR: the goal frame really reached the $e engine" 1 \
    "$([ -s "$SANDBOX/$e.log" ] && echo 1 || echo 0)"
  chk_contains "C8 BEHAVIOUR: $e launched with the binary its spec declares" \
    "$(probe spec "$e" bin_env >/dev/null; basename "$(eval echo \$"$(probe spec "$e" bin_env)")")" \
    "$(cat "$FAKE_TMUX_LAUNCH_LOG")"
  chk_contains "C8 BEHAVIOUR: and with the argv its spec pins" \
    "$(probe spec "$e" argv | awk '{print $NF}')" "$(cat "$FAKE_TMUX_LAUNCH_LOG")"
  if [ "$e" = codex ]; then
    chk_not_contains "C8 BEHAVIOUR: and NOTHING else — codex argv stays pinned, --model rides the protocol" \
      "--model" "$(cat "$FAKE_TMUX_LAUNCH_LOG")"
  fi
done

# ── omp: queuedSteer / midTurnSteer / replaceTurn each emit their declared frame ──────────
export FAKE_PROVIDER_LOG="$SANDBOX/omp.log"
bash "$AGENTCTL" steer b_omp -m "queued" >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR omp.queuedSteer: the declared follow_up frame is on the wire" \
  "\"type\":\"$(probe cell omp queuedSteer route)\"" "$(cat "$SANDBOX/omp.log")"
bash "$AGENTCTL" steer b_omp -m "right now" --now >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR omp.midTurnSteer: the declared steer frame is on the wire" \
  "\"type\":\"$(probe cell omp midTurnSteer route)\"" "$(cat "$SANDBOX/omp.log")"
bash "$AGENTCTL" steer b_omp -m "start over" --replace >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR omp.replaceTurn: the declared abort_and_prompt frame is on the wire" \
  "\"type\":\"$(probe cell omp replaceTurn route)\"" "$(cat "$SANDBOX/omp.log")"
bash "$AGENTCTL" stop b_omp >/dev/null 2>&1

# ── omp.structuredAsk: a real engine question must PROJECT as WAITING-INPUT ───────────────
# This is the reviewer's mutation #2: flipping the projection to IDLE left the old suite green.
export FAKE_OMP_ASK=1
export FAKE_PROVIDER_LOG="$SANDBOX/omp-ask.log"
bash "$AGENTCTL" start omp b_ask "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
/bin/sleep 0.4
out="$(bash "$AGENTCTL" status b_ask 2>&1)"; rc=$?
chk_eq "C8 BEHAVIOUR omp.structuredAsk: a native ask projects as WAITING-INPUT (exit 4)" 4 "$rc"
chk_contains "C8 BEHAVIOUR omp.structuredAsk: and says so" "WAITING-INPUT" "$out"
chk_contains "C8 BEHAVIOUR omp.structuredAsk: quoting the engine's own ask frame" \
  "$(probe cell omp structuredAsk route)" "$out"
bash "$AGENTCTL" stop b_ask >/dev/null 2>&1
unset FAKE_OMP_ASK
# PAIRED GREEN: the connect-time setWidget chrome the cell declares as noise must NOT project
# as a question — a projector that says WAITING for everything is not structuredAsk support
export FAKE_PROVIDER_LOG="$SANDBOX/omp-noise.log"
bash "$AGENTCTL" start omp b_noise "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
/bin/sleep 0.3
out="$(bash "$AGENTCTL" status b_noise 2>&1)"; rc=$?
chk_eq "C8 PAIRED GREEN: declared UI noise never projects as a question (DONE 0)" 0 "$rc"
chk_not_contains "C8 PAIRED GREEN: no WAITING-INPUT from chrome" "WAITING-INPUT" "$out"
bash "$AGENTCTL" stop b_noise >/dev/null 2>&1

# ── claude: queuedSteer delivers; midTurnSteer degrades to the SAME frame, out loud ───────
export FAKE_PROVIDER_LOG="$SANDBOX/claude.log"
bash "$AGENTCTL" steer b_claude -m "queued please" >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR claude.queuedSteer: the declared user frame is on the wire" \
  "\"type\":\"$(probe cell claude queuedSteer route)\"" "$(cat "$SANDBOX/claude.log")"
before="$(grep -c . "$SANDBOX/claude.log")"
out="$(bash "$AGENTCTL" steer b_claude -m "now please" --now 2>&1)"
after="$(grep -c . "$SANDBOX/claude.log")"
chk_contains "C8 BEHAVIOUR claude.midTurnSteer: the degradation is announced" \
  "delivered as a QUEUED steer" "$out"
chk_eq "C8 BEHAVIOUR claude.midTurnSteer: and it really delivered one more frame" 1 \
  "$([ "$after" -gt "$before" ] && echo 1 || echo 0)"
before="$(grep -c . "$SANDBOX/claude.log")"
out="$(bash "$AGENTCTL" steer b_claude -m "abandon" --replace 2>&1)"; rc=$?
after="$(grep -c . "$SANDBOX/claude.log")"
chk_eq "C8 BEHAVIOUR claude.replaceTurn: unsupported means NOTHING reaches the engine" \
  "$before" "$after"
chk_eq "C8 BEHAVIOUR claude.replaceTurn: and the verb fails" 1 "$rc"
bash "$AGENTCTL" stop b_claude >/dev/null 2>&1

# ── codex: queuedSteer / midTurnSteer / replaceTurn on the wire ───────────────────────────
export FAKE_PROVIDER_LOG="$SANDBOX/codex.log"
bash "$AGENTCTL" steer b_codex -m "next turn" >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR codex.queuedSteer: the declared turn/start method is on the wire" \
  "\"method\":\"$(probe cell codex queuedSteer route)\"" "$(cat "$SANDBOX/codex.log")"
bash "$AGENTCTL" stop b_codex >/dev/null 2>&1
export FAKE_CODEX_GATE="$SANDBOX/cx-gate"
export FAKE_PROVIDER_LOG="$SANDBOX/codex-gate.log"
bash "$AGENTCTL" start codex b_cxg "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
/bin/sleep 0.3
bash "$AGENTCTL" steer b_cxg -m "mid turn" --now >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR codex.midTurnSteer: the declared turn/steer method is on the wire" \
  "\"method\":\"$(probe cell codex midTurnSteer route)\"" "$(cat "$SANDBOX/codex-gate.log")"
bash "$AGENTCTL" steer b_cxg -m "abandon this" --replace >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR codex.replaceTurn: the interrupt half of the route is on the wire" \
  "\"method\":\"turn/interrupt\"" "$(cat "$SANDBOX/codex-gate.log")"
chk_contains "C8 BEHAVIOUR codex.replaceTurn: and the replacement half too" \
  "\"method\":\"turn/start\"" "$(cat "$SANDBOX/codex-gate.log")"
: > "$FAKE_CODEX_GATE"
bash "$AGENTCTL" stop b_cxg >/dev/null 2>&1
unset FAKE_CODEX_GATE

# ── codex.resume: the DECLARED route must appear on the wire when its start flag is used ──
# This is the reviewer's mutation #1: swapping the handshake to thread/start left the old
# suite green because nothing ever looked at the frames.
export FAKE_PROVIDER_LOG="$SANDBOX/codex-resume.log"
out="$(bash "$AGENTCTL" start codex b_cxr "$WT" --goal "$SANDBOX/goal.md" \
        "$(probe cell codex resume start_flag)" old-thread-9 2>&1)"; rc=$?
chk_eq "C8 BEHAVIOUR codex.resume: start with the declared flag succeeds" 0 "$rc"
chk_contains "C8 BEHAVIOUR codex.resume: the DECLARED resume method is on the wire" \
  "\"method\":\"$(probe cell codex resume route)\"" "$(cat "$SANDBOX/codex-resume.log")"
chk_contains "C8 BEHAVIOUR codex.resume: carrying the thread the operator named" \
  "old-thread-9" "$(cat "$SANDBOX/codex-resume.log")"
chk_eq "C8 BEHAVIOUR codex.resume: and the session really continues that thread" \
  "old-thread-9" "$(sed -n 's/^thread=//p' "$WATCH_RUN_DIR/b_cxr.duplex.meta")"
bash "$AGENTCTL" stop b_cxr >/dev/null 2>&1

# ── codex.structuredAsk: a native engine ask must PROJECT as WAITING-INPUT ────────────────
export FAKE_CODEX_ASK=1
export FAKE_PROVIDER_LOG="$SANDBOX/codex-ask.log"
bash "$AGENTCTL" start codex b_cxa "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
/bin/sleep 0.4
out="$(bash "$AGENTCTL" status b_cxa 2>&1)"; rc=$?
chk_eq "C8 BEHAVIOUR codex.structuredAsk: a native ask projects as WAITING-INPUT (exit 4)" 4 "$rc"
chk_contains "C8 BEHAVIOUR codex.structuredAsk: and names it as an engine ask" \
  "native engine ask" "$out"
bash "$AGENTCTL" stop b_cxa >/dev/null 2>&1
unset FAKE_CODEX_ASK

# ── omp / claude resume: the declared start-argv surface really forwards the engine flag ──
: > "$FAKE_TMUX_LAUNCH_LOG"
export FAKE_PROVIDER_LOG="$SANDBOX/omp-resume.log"
bash "$AGENTCTL" start omp b_ompr "$WT" --goal "$SANDBOX/goal.md" -r /tmp/ws3-omp-session \
  >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR omp.resume: the start-argv surface forwards the engine's own flag" \
  "/tmp/ws3-omp-session" "$(cat "$FAKE_TMUX_LAUNCH_LOG")"
bash "$AGENTCTL" stop b_ompr >/dev/null 2>&1
: > "$FAKE_TMUX_LAUNCH_LOG"
export FAKE_PROVIDER_LOG="$SANDBOX/claude-resume.log"
bash "$AGENTCTL" start claude b_clr "$WT" --goal "$SANDBOX/goal.md" --resume sess-abc \
  >/dev/null 2>&1
chk_contains "C8 BEHAVIOUR claude.resume: the start-argv surface forwards --resume verbatim" \
  "sess-abc" "$(cat "$FAKE_TMUX_LAUNCH_LOG")"
bash "$AGENTCTL" stop b_clr >/dev/null 2>&1
# PAIRED NEGATIVE: codex declares NO start-argv surface, so stray argv is refused, not forwarded
out="$(bash "$AGENTCTL" start codex b_cxn "$WT" --goal "$SANDBOX/goal.md" --resume sess-abc 2>&1)"
rc=$?
chk_eq "C8 PAIRED NEGATIVE: a provider without the start-argv surface refuses stray argv" 1 "$rc"
chk_contains "C8 PAIRED NEGATIVE: and says the config rides the protocol" \
  "engine config via protocol" "$out"

sweep_fakes
unset FAKE_TMUX_LAUNCH_LOG AGENTCTL_BIN_OMP AGENTCTL_BIN_CLAUDE AGENTCTL_BIN_CODEX FAKE_PROVIDER_LOG
teardown

echo "== C9: PATH-symlink invocation still resolves duplexctl.py beside the REAL script =="
# Deployment surface, not protocol: agentctl is symlinked into ~/.local/bin on seats. $0 is
# then the symlink, and a dirname that doesn't follow the link chain points CTL at the bin
# dir — capabilities table unreadable, every engine name goes unknown (live seat incident,
# 2026-08-05). Two hops pins the resolution LOOP, not just one readlink.
setup
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
ln -s "$AGENTCTL" "$BIN/agentctl-real-hop"
ln -s "agentctl-real-hop" "$BIN/agentctl"
out="$("$BIN/agentctl" capabilities 2>&1)"; rc=$?
chk_eq "C9 symlinked agentctl exits 0" 0 "$rc"
chk_contains "C9 capability table read through a two-hop relative symlink" \
  "capability contract" "$out"
teardown

# ── C10 thin-entry ratchet: judgement stays in python, bash stays plumbing ──
# The salvage batch bought this property (bash 916→449, decisions moved into duplexctl) but the
# contract lived only in that goal doc — it died when the goal was archived, and bash then grew
# 449→513 across four batches with nothing watching. Ratchet the SHARE, not an absolute count
# (fixed budgets were already refuted once: they go stale and get declared around). Share is what
# the property actually means — bash may grow when the runtime grows, it may not grow ALONE.
# Baseline 12.5% measured 2026-08-12; 1.0-point headroom absorbs ordinary plumbing.
BASH_LINES="$(wc -l < "$AGENTCTL")"
PY_LINES="$(wc -l < "$(dirname "$AGENTCTL")/duplexctl.py")"
# cross-multiply, do not floor a percentage then compare (floor turned the stated 13.5% into
# an effective <13.6% ratchet — review m1 2026-08-12)
SHARE_X10="$(( BASH_LINES * 1000 / (BASH_LINES + PY_LINES) ))"
OVER=$(( BASH_LINES * 1000 > 135 * (BASH_LINES + PY_LINES) ? 1 : 0 ))
# breach message names the fix, not just the number (a bare number teaches nobody)
[ "$OVER" -eq 0 ] && VERDICT="within" \
  || VERDICT="BREACH(${SHARE_X10}/1000): bash 占比回升 = 判定正在回流 shell — 下沉 duplexctl，或在 goal 声明理由并更新基线"
chk_eq "C10 thin entry: bash share ${SHARE_X10}/1000 stays under the 135 ratchet" "within" "$VERDICT"

summary
