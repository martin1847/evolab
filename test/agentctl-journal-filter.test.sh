#!/usr/bin/env bash
# The pane journal filter: omp's three `message_update/*_delta` subtypes never reach
# $RUN/<s>.duplex.events.jsonl, and NOTHING ELSE changes by a single byte.
#
# Why a suite of its own: the filter is the one place in this lane where a line can be
# DESTROYED. The cheap half (are the deltas gone?) is one assertion; every other case here is
# the expensive half — a kept frame that merely QUOTES a delta frame in its payload, a frame
# type this control plane reads, a non-omp stream, junk bytes, and the rc file that must land
# on the engine's exit rather than on the pipe reader's EOF.
#
# The filter itself is NEVER re-spelled here: both definition lines are eval'd straight out of
# agentctl, so a drift between the pane and this suite is impossible by construction.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL="$AW_DIR/agentctl"
FIX="$(pwd)/duplex-fixtures"
CORPUS_DIR="$(pwd)/corpus"
# the real-stream sweep may be pointed at a corpus that lives outside this worktree: test/corpus
# is gitignored (real events may carry sensitive content), so a fresh clone has none
REAL_CORPUS_DIR="${JFILTER_CORPUS_DIR:-$CORPUS_DIR}"
GEN_CORPUS="$CORPUS_DIR/omp-journal-filter-0930.events.jsonl"

echo "== journal filter: the ONE definition =="

# damage: a second spelling of the regex anywhere = the pane filtering one thing while this
# suite proves another, and the drift is invisible until a frame silently vanishes in the field
chk_eq "the filter regex is defined exactly once in agentctl" 1 \
  "$(grep -c '^JOURNAL_FILTER_RE=' "$AGENTCTL")"
# damage: same for the invocation — a second `grep -a --line-buffered` is a second policy
chk_eq "the filter command is defined exactly once in agentctl" 1 \
  "$(grep -c '^JOURNAL_FILTER_CMD=' "$AGENTCTL")"
# damage: the pane bypasses the shared definition (an inlined regex) ⇒ every proof below is
# about a command nothing in production runs
chk_eq "the pane line uses the shared definition, not an inlined pattern" 1 \
  "$(grep -c 'JOURNAL_FILTER_CMD \$(q "\$JOURNAL_FILTER_RE")' "$AGENTCTL")"

eval "$(grep '^JOURNAL_FILTER_RE=' "$AGENTCTL")"
eval "$(grep '^JOURNAL_FILTER_CMD=' "$AGENTCTL")"
# `eval` and not a bare expansion, for the same reason the pane works: the pane string is
# SOURCE TEXT parsed by a shell, so `LC_ALL=C` is an assignment prefix there. Expanding the
# variable in place would hand the shell "LC_ALL=C" as a command name instead.
jfilter() { eval "$JOURNAL_FILTER_CMD \"\$JOURNAL_FILTER_RE\"" || true; }  # rc1 = all dropped
echo "  filter under test: $JOURNAL_FILTER_CMD '$JOURNAL_FILTER_RE'"

sandbox_new

# ---------------------------------------------------------------------------------------
echo "== T1: oracle equivalence over a full-coverage corpus =="
# The corpus is REGENERATED here rather than committed: test/corpus/ is gitignored, so a
# checked-in fixture would be absent on every fresh clone. Deterministic content, same path.
mkdir -p "$CORPUS_DIR"
MANIFEST="$SANDBOX/corpus-manifest.txt"
python3 - "$GEN_CORPUS" "$MANIFEST" <<'GENPY'
"""Synthesise one journal covering every frame type the omp pane can emit, plus the lines
that are designed to fool a sloppy filter. Written in binary: some lines are not UTF-8."""
import json
import sys

out_path, manifest_path = sys.argv[1], sys.argv[2]
lines: list[tuple[str, bytes, bool]] = []      # (kind, raw line, expect_drop)


def frame(kind: str, obj: dict, drop: bool = False) -> None:
    lines.append((kind, json.dumps(obj, separators=(",", ":")).encode(), drop))


def ev(subtype: str, **rest) -> dict:
    """assistantMessageEvent in omp's live key order: type first, payload after."""
    return {"type": "message_update",
            "assistantMessageEvent": {"type": subtype, "contentIndex": 1, **rest}}


partial = {"role": "assistant", "content": [{"type": "text", "text": "so far"}]}

# ── the three DROP subtypes ─────────────────────────────────────────────────────────────
frame("text_delta", ev("text_delta", delta="chunk ", partial=partial), True)
frame("thinking_delta", ev("thinking_delta", delta="hmm ", partial=partial), True)
frame("toolcall_delta", ev("toolcall_delta", delta='{"pa', partial=partial), True)
# ── same prefix, NOT delta: the frames that carry the full text and must survive ────────
frame("text_start", ev("text_start"))
frame("text_end", ev("text_end", content={"type": "text", "text": "the whole message"},
                     partial=partial))
frame("thinking_start", ev("thinking_start"))
frame("thinking_end", ev("thinking_end", content={"type": "thinking", "thinking": "done"},
                         partial=partial))
frame("toolcall_start", ev("toolcall_start"))
frame("toolcall_end", ev("toolcall_end",
                         toolCall={"id": "toolu_1", "name": "write",
                                   "arguments": {"path": "a.txt", "content": "x"}},
                         partial=partial))
# ── every other top-level type this lane can see ────────────────────────────────────────
frame("ready", {"type": "ready"})
frame("message_start", {"type": "message_start", "messageId": "m1"})
frame("message_end", {"type": "message_end", "messageId": "m1",
                      "message": {"role": "assistant", "content": []}})
frame("turn_start", {"type": "turn_start", "turnId": "t1"})
frame("turn_end", {"type": "turn_end", "turnId": "t1"})
frame("agent_start", {"type": "agent_start"})
frame("agent_end", {"type": "agent_end"})
frame("tool_execution_start", {"type": "tool_execution_start", "toolCallId": "tc1",
                               "toolName": "bash", "args": {"command": "pytest -q"}})
frame("tool_execution_update", {"type": "tool_execution_update", "toolCallId": "tc1",
                                "toolName": "bash",
                                "delta": {"content": [{"type": "text", "text": "out"}]}})
frame("tool_execution_end", {"type": "tool_execution_end", "toolCallId": "tc1",
                             "toolName": "bash",
                             "result": {"content": [{"type": "text", "text": "ok"}]}})
frame("tool_stream_update", {"type": "tool_stream_update", "toolCallId": "tc1",
                             "chunk": "streamed tool output"})
frame("response", {"id": "ctl-1", "type": "response", "command": "get_state", "success": True,
                   "data": {"isStreaming": True, "isCompacting": False,
                            "sessionId": "s1", "messageCount": 2, "queuedMessageCount": 0}})
frame("extension_ui_request", {"type": "extension_ui_request", "id": "ui-q1",
                               "method": "confirm", "title": "Proceed?"})
frame("session_settled", {"type": "session_settled", "sessionId": "s1"})
# an ask, a delta BETWEEN, then a failed prompt response: the readers' positions are relative
# ORDER (ask vs error — whichever is later is what the engine is doing now), and deleting
# frames between them must not be able to reverse it
frame("order-text_delta", ev("text_delta", delta="mid ", partial=partial), True)
frame("response-prompt-error", {"id": "ctl-1", "type": "response", "command": "prompt",
                                "success": False, "error": "engine refused the prompt"})

# ── adversarial (a): a KEPT frame whose payload quotes a whole delta frame ──────────────
quoted = ('{"type":"message_update","assistantMessageEvent":{"type":"text_delta",'
          '"contentIndex":1,"delta":"x","partial":{}}}')
frame("adv-a-toolcall_end-quotes-delta",
      ev("toolcall_end",
         toolCall={"id": "toolu_2", "name": "write",
                   "arguments": {"path": "journal.md", "content": quoted}},
         partial=partial))
# ── adversarial (b): a response frame whose data carries the delta type string ──────────
frame("adv-b-response-quotes-delta",
      {"id": "ctl-2", "type": "response", "command": "get_state", "success": True,
       "data": {"lastEvent": '"type":"text_delta"', "isStreaming": False}})
# ── adversarial (a2): the RAW prefix bytes mid-line as a NESTED OBJECT (a quoted string gets
# its quotes escaped, so (a)/(b) never put the literal prefix on the wire). Only `^` keeps it.
frame("adv-a2-nested-raw-prefix",
      {"type": "tool_stream_update", "toolCallId": "tc8", "toolName": "read",
       "chunk": {"type": "message_update",
                 "assistantMessageEvent": {"type": "text_delta", "delta": "x"}}})
# ── adversarial (d)/(e): lines that are not frames at all ───────────────────────────────
lines.append(("adv-d-garbage", b"THIS IS NOT JSON AT ALL", False))
lines.append(("adv-d-empty", b"", False))
lines.append(("adv-d-whitespace", b"   \t  ", False))
lines.append(("adv-e-invalid-utf8-and-nul", b"\xff\xfe raw bytes \x00 mid line \x80", False))
# ── adversarial (f): megabyte lines, one of each verdict ────────────────────────────────
big = "z" * (2 * 1024 * 1024)
frame("adv-f-big-toolcall_delta", ev("toolcall_delta", delta=big, partial=partial), True)
frame("adv-f-big-tool_execution_end",
      {"type": "tool_execution_end", "toolCallId": "tc9", "toolName": "bash",
       "result": {"content": [{"type": "text", "text": big}]}})

with open(out_path, "wb") as fh:
    for _kind, raw, _drop in lines:
        fh.write(raw + b"\n")
with open(manifest_path, "w", encoding="utf-8") as fh:
    for kind, raw, drop in lines:
        fh.write(f"{kind}\t1\t{'drop' if drop else 'keep'}\t{len(raw)}\n")
GENPY
# damage: a generator that silently wrote nothing ⇒ every T1/T2/T3 verdict below is about an
# empty file and passes vacuously
chk_eq "corpus generated" 1 "$([ -s "$GEN_CORPUS" ] && echo 1 || echo 0)"

FILTERED="$SANDBOX/filtered.jsonl"
jfilter < "$GEN_CORPUS" > "$FILTERED"

# The oracle is the SPEC, spelled independently of the regex: a line dies iff it parses as
# JSON whose type is message_update and whose assistantMessageEvent.type is one of the three.
ORACLE_OUT="$(python3 - "$GEN_CORPUS" "$FILTERED" "$SANDBOX/expected.jsonl" <<'ORAPY'
import json
import sys

DELTAS = {"text_delta", "thinking_delta", "toolcall_delta"}


def drops(raw: bytes) -> bool:
    try:
        obj = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return False
    if not isinstance(obj, dict) or obj.get("type") != "message_update":
        return False
    event = obj.get("assistantMessageEvent")
    return isinstance(event, dict) and event.get("type") in DELTAS


src = open(sys.argv[1], "rb").read().split(b"\n")[:-1]
actual = open(sys.argv[2], "rb").read().split(b"\n")
actual = actual[:-1] if actual and actual[-1] == b"" else actual
expected = [(i, line) for i, line in enumerate(src, 1) if not drops(line)]
with open(sys.argv[3], "wb") as fh:
    for _i, line in expected:
        fh.write(line + b"\n")
mismatch = []
for pos in range(max(len(expected), len(actual))):
    want = expected[pos][1] if pos < len(expected) else None
    got = actual[pos] if pos < len(actual) else None
    if want != got:
        mismatch.append({"output_pos": pos + 1,
                         "expected_from_input_line": expected[pos][0] if pos < len(expected) else None,
                         "expected_head": (want or b"")[:60].decode("utf-8", "replace"),
                         "got_head": (got or b"")[:60].decode("utf-8", "replace")})
print(json.dumps({"input": len(src), "kept_expected": len(expected), "kept_actual": len(actual),
                  "dropped_expected": len(src) - len(expected),
                  "dropped_actual": len(src) - len(actual),
                  "mismatch": mismatch[:5]}))
ORAPY
)"
jq_get() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
# damage: THE case this filter exists to get right — one kept line lost (or one delta kept)
# and the control plane either loses evidence or keeps the O(L²) bytes it was built to shed
chk_eq "T1 every line's verdict matches the oracle, in order" "[]" \
  "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["mismatch"]))' "$ORACLE_OUT")"
# damage: an all-keep filter (broken regex, grep not running) would pass the line above
chk_eq "T1 the corpus really exercised the drop path" \
  "$(awk -F'\t' '$3 == "drop"' "$MANIFEST" | wc -l | tr -d ' ')" \
  "$(jq_get "$ORACLE_OUT" dropped_actual)"
# damage: coverage claim rot — the corpus silently shrinks below the frame set it claims
chk_eq "T1 corpus covers ≥20 distinct frame kinds" 1 \
  "$([ "$(cut -f1 "$MANIFEST" | sort -u | wc -l | tr -d ' ')" -ge 20 ] && echo 1 || echo 0)"
echo "  corpus: $(jq_get "$ORACLE_OUT" input) lines, $(jq_get "$ORACLE_OUT" dropped_actual) dropped, $(cut -f1 "$MANIFEST" | sort -u | wc -l | tr -d ' ') kinds"

# The fail-SAFE direction, pinned: the pattern is prefix-anchored, so a delta frame serialised
# with some other key order survives. Keeping a line is never data loss; dropping one is.
ODD='{"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"x"},"type":"message_update"}'
# damage: someone "fixes" the key-order gap with `.*` and every KEPT frame that quotes a delta
# frame in its payload (adversarial a/b above) starts vanishing instead
chk_eq "T1b a non-canonical key order is KEPT (fail-open, never fail-destructive)" "$ODD" \
  "$(printf '%s\n' "$ODD" | jfilter)"
# KNOWN POSITIVE for the `^` anchor: a2's bytes DO match the pattern once the anchor is removed —
# so T1's "a2 kept" verdict above was decided by the anchor, not by the prefix being absent
# damage: a2 stops being adversarial (prefix escaped away) and the anchor is never exercised
chk_eq "T1 known positive: a2's raw prefix matches the UNANCHORED pattern" 1 \
  "$(grep -a '"toolCallId":"tc8"' "$GEN_CORPUS" | LC_ALL=C grep -a -c -E "${JOURNAL_FILTER_RE#^}")"

# ---------------------------------------------------------------------------------------
echo "== T2: survivors are byte-identical and in order =="
if cmp -s "$SANDBOX/expected.jsonl" "$FILTERED"; then t2=1; else t2=0; fi
# damage: a filter that rewrites (re-encodes, strips, reorders, drops a trailing newline)
# turns the journal into a lossy copy — `cmp` is the only assertion that can see that
chk_eq "T2 kept lines are byte-for-byte the input lines, in input order" 1 "$t2"

# ---------------------------------------------------------------------------------------
echo "== T3: every reader's verdict is unchanged =="
# The control plane's own projectors, run over the original and the filtered stream.
READERS="$(python3 - "$AW_DIR" "$WATCH_RUN_DIR" "$GEN_CORPUS" "$FILTERED" <<'RDPY'
import json
import shutil
import sys

sys.path.insert(0, sys.argv[1])
import duplexctl as d   # noqa: E402

run_dir = sys.argv[2]
verdicts = []
for name, src in (("jforig", sys.argv[3]), ("jffilt", sys.argv[4])):
    shutil.copyfile(src, f"{run_dir}/{name}.duplex.events.jsonl")
    sess = d.Session(run_dir, name)
    frames, clean, partial = d.complete_frames_integrity(sess)
    ask, ask_at = d.omp_pending_ask(frames)
    kind, evidence, at = d.omp_round_error(frames, "ctl-1")
    with open(src, "rb") as fh:
        fh.seek(max(0, fh.seek(0, 2) - 16384))
        tail = fh.read().decode("utf-8", "replace")
    # The two projector POSITIONS are deliberately not compared as absolute indices: they are
    # indices into the frame list, and removing frames shifts them by construction. What they
    # are FOR is the order between an ask and an error ("whichever came last is what the engine
    # is doing now"), so the compared fact is that ordering — which a deletion cannot change,
    # since both frames survive and grep preserves order.
    order = (ask_at > at) - (ask_at < at)
    verdicts.append({"tool_events": d.omp_tool_events(sess, frames),
                     "clean": clean, "partial": partial,
                     "ask": None if ask is None else ask.get("id"),
                     "err_kind": kind, "err_evidence": evidence,
                     "ask_after_error": order, "quota": d.quota_hit(tail),
                     "_positions_not_compared": [ask_at, at]})
compare = [{k: v for k, v in verdict.items() if not k.startswith("_")}
           for verdict in verdicts]
print(json.dumps({"same": compare[0] == compare[1], "orig": verdicts[0],
                  "filtered": verdicts[1]}))
RDPY
)"
# damage: the filter is provably cheap only if the verdict is provably identical — a changed
# tool count, a flipped `clean` bit or a reordered ask/error is a classify-visible change
chk_eq "T3 tool_events / pending_ask / round_error / clean / quota / ask-vs-error order unchanged" \
  "True" "$(jq_get "$READERS" same)"
echo "  readers: $(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["orig"]))' "$READERS")"
# damage: both sides read as an empty stream (wrong run-dir, unreadable copy) and "same" is vacuous
chk_eq "T3 the readers really saw the frames (tool events counted)" 3 \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["orig"]["tool_events"])' "$READERS")"
# damage: the ask/error pair never coexisted ⇒ the order fact above is vacuous
chk_eq "T3 the ask and the error really both landed (ask BEFORE error)" "-1" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["orig"]["ask_after_error"])' "$READERS")"

# ---------------------------------------------------------------------------------------
echo "== T4: non-omp streams pass through untouched =="
# A claude-lane journal: not one line of it can match an omp-shaped pattern.
CLAUDE_SYN="$SANDBOX/claude-lane.jsonl"
cat > "$CLAUDE_SYN" <<'EOF'
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1"}]}}
{"method":"turn/completed","params":{"turn":{"id":"t","status":"completed"}}}
{"type":"result","is_error":false,"result":"done"}
EOF
jfilter < "$CLAUDE_SYN" > "$SANDBOX/claude-lane.out"
if cmp -s "$CLAUDE_SYN" "$SANDBOX/claude-lane.out"; then t4=1; else t4=0; fi
# damage: an over-broad pattern eats another engine's frames — the filter is installed for ALL
# lanes' pane assembly, and claude/codex journals are what the replay gate reads
chk_eq "T4 a claude-lane journal passes through byte-identical" 1 "$t4"

# Real recorded streams when this box has them (test/corpus is local-only by design).
real_seen=0
for f in "$REAL_CORPUS_DIR"/*.jsonl; do
  [ -f "$f" ] || continue
  [ "$f" = "$GEN_CORPUS" ] && continue
  real_seen=$((real_seen + 1))
  jfilter < "$f" > "$SANDBOX/real.out"
  # damage: a real stream (3k lines of field bytes, not hand-written shapes) loses a line
  chk_eq "T4 real corpus passes through byte-identical: $(basename "$f")" 1 \
    "$(cmp -s "$f" "$SANDBOX/real.out" && echo 1 || echo 0)"
done
[ "$real_seen" = 0 ] && echo "  [skip] no real corpus on this box (test/corpus/ is gitignored, local-only)"

# ---------------------------------------------------------------------------------------
echo "== T5/T6/T7: the real pane path =="
# Harness copied from agentctl-duplex.test.sh: a PROCESS-RUNNING fake tmux, so the pane command
# agentctl assembles (filter pipe included) really runs against a real fifo and a real engine.
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
    ( cd "${cwd:-/}" && exec "${FAKE_TMUX_SHELL:-bash}" -c "$cmd" ) >/dev/null 2>&1 &
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
  for pid in $(pgrep -f "$SANDBOX" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
  done
  return 0
}
install_running_tmux
WT="$SANDBOX/wt"; mkdir -p "$WT"
printf 'investigate the thing\nPreflight: ls duplex-fixtures => 5 fake engines on disk\n' \
  > "$SANDBOX/goal.md"

# engine = the fixture behind a wrapper that dies rc 3, so the rc file has a value only the
# ENGINE could have produced (0 is also what a missing write looks like)
cat > "$SANDBOX/omp-rc3" <<EOF
#!/usr/bin/env bash
python3 $(printf %q "$FIX/fake_omp_duplex.py")
exit 3
EOF
chmod +x "$SANDBOX/omp-rc3"
export AGENTCTL_BIN_OMP="$SANDBOX/omp-rc3"
export FAKE_OMP_DELTA_FRAMES=5
export FAKE_OMP_TOOL_FRAMES="$SANDBOX/omp-tool-switch"
printf 'pytest -q tests/unit\n' > "$FAKE_OMP_TOOL_FRAMES"

bash "$AGENTCTL" start omp jfE "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
EV="$WATCH_RUN_DIR/jfE.duplex.events.jsonl"
await_contains "$EV" '"type":"text_end"' 100
# T7: the engine is ALIVE and a frame it just emitted is already readable — block buffering
# would hold a 4KB-short stream (and the stall probe's mtime) hostage until the engine exits
out="$(bash "$AGENTCTL" status jfE 2>&1)"; rc=$?
# damage: without --line-buffered the journal stays empty for minutes ⇒ every progress source
# reads a working seat as silent, which is the failure this whole goal came from
chk_eq "T7 a frame emitted by a LIVE engine is in the journal within 1s" 1 \
  "$(seen "$EV" '"type":"tool_execution_start"' 10)"
# damage: the live pane path is broken outright (engine never started, status cannot read) —
# a FAILED / traceback / ENGINE-SILENT answer must not pass as "answered"
chk_eq "T5 status over a filtered journal answers the typed healthy verdict" "0 DONE" \
  "$rc ${out%%:*}"

# damage: the deltas are still being journalled — the GB-per-hour bug, unfixed
chk_eq "T5 no delta frame reached the journal" 0 \
  "$(grep -c '"type":"text_delta"' "$EV" 2>/dev/null || true)"
# KNOWN POSITIVE for the line above: the same fixture, same env, stdout unfiltered.
raw_deltas="$(printf '{"type":"prompt","id":"p1","text":"go"}\n{"type":"abort","id":"a1"}\n' \
  | python3 "$FIX/fake_omp_duplex.py" | grep -c '"type":"text_delta"')"
# damage: the zero above is a fixture that emitted nothing, not a filter that worked
chk_eq "T5 known positive: the fixture really emits 5 delta frames unfiltered" 5 "$raw_deltas"
for kind in '"type":"text_start"' '"type":"text_end"' '"type":"tool_execution_start"' \
            '"type":"tool_execution_end"' '"type":"response"'; do
  # damage: the filter took a frame type the control plane reads (or the whole stream)
  chk_eq "T5 kept in the live journal: $kind" 1 \
    "$([ "$(grep -c -- "$kind" "$EV" 2>/dev/null || true)" -ge 1 ] && echo 1 || echo 0)"
done

# T5 rc: the engine exits (abort frame straight into its fifo — `stop` would kill the pane
# instead, which is a different question), and the rc file must carry the ENGINE's code
printf '{"type":"abort","id":"a-jfE"}\n' > "$WATCH_RUN_DIR/jfE.duplex.in"
for _ in $(seq 1 30); do [ -f "$WATCH_RUN_DIR/jfE.duplex.rc" ] && break; /bin/sleep 0.1; done
# damage: the pipe swallowed the engine's status (PIPESTATUS-less `cmd | grep` records grep's
# rc) ⇒ every FAILED engine publishes as a clean exit and watch calls it DONE
chk_eq "T5 the rc file carries the ENGINE's exit code through the pipe" "3" \
  "$(cat "$WATCH_RUN_DIR/jfE.duplex.rc" 2>/dev/null | tr -d ' \n')"
bash "$AGENTCTL" stop jfE >/dev/null 2>&1

# T5z: the same pane under zsh — tmux's default-shell on macOS IS zsh, and the `printf %q`
# quoting agentctl emits has to survive a second parser. Skipped where zsh is absent.
if command -v zsh >/dev/null 2>&1; then
  export FAKE_TMUX_SHELL=zsh
  bash "$AGENTCTL" start omp jfZ "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
  EVZ="$WATCH_RUN_DIR/jfZ.duplex.events.jsonl"
  await_contains "$EVZ" '"type":"text_end"' 100
  # damage: zsh parses the %q-quoted regex differently ⇒ grep runs a different pattern: the
  # deltas come back silently (GB bug lives on under the real shell) or a kept frame dies
  chk_eq "T5z zsh pane: 0 delta journalled, text_end kept" "0 1" \
    "$(grep -c '"type":"text_delta"' "$EVZ" 2>/dev/null || true) $([ "$(grep -c '"type":"text_end"' "$EVZ" 2>/dev/null || true)" -ge 1 ] && echo 1 || echo 0)"
  printf '{"type":"abort","id":"a-jfZ"}\n' > "$WATCH_RUN_DIR/jfZ.duplex.in"
  for _ in $(seq 1 30); do [ -f "$WATCH_RUN_DIR/jfZ.duplex.rc" ] && break; /bin/sleep 0.1; done
  # damage: the in-group rc write leans on a bash-ism ⇒ under zsh the engine's exit code vanishes
  chk_eq "T5z zsh pane: rc file carries the ENGINE's exit code" "3" \
    "$(cat "$WATCH_RUN_DIR/jfZ.duplex.rc" 2>/dev/null | tr -d ' \n')"
  bash "$AGENTCTL" stop jfZ >/dev/null 2>&1
  unset FAKE_TMUX_SHELL
else
  echo "  [skip] T5z: no zsh on this box"
fi

# T6: a grandchild still holds the pipe's write end when the engine dies. The rc must land on
# the ENGINE's exit; waiting for the reader's EOF would hide the death for as long as the
# orphan lives (field shape: an engine that setsid()s a helper before crashing).
export AGENTCTL_BIN_OMP="$FIX/fake_omp_duplex.py"
export FAKE_OMP_LINGER_CHILD=1
unset FAKE_OMP_DELTA_FRAMES
bash "$AGENTCTL" start omp jfL "$WT" --goal "$SANDBOX/goal.md" >/dev/null 2>&1
await_contains "$WATCH_RUN_DIR/jfL.duplex.events.jsonl" '"type":"agent_end"' 100
printf '{"type":"abort","id":"a-jfL"}\n' > "$WATCH_RUN_DIR/jfL.duplex.in"
rc_landed=0
for _ in $(seq 1 10); do
  [ -f "$WATCH_RUN_DIR/jfL.duplex.rc" ] && { rc_landed=1; break; }
  /bin/sleep 0.1
done
# THIS seat's grandchild only: a bare `sleep 3` pattern matches any concurrent runner's fixture
# (the blanket-pkill scar in agentctl-duplex.test.sh's sweep_fakes), so the fixture stamps the
# session name into the child's argv and both the probe and the kill below select on it
LINGER_PAT='agentctl-linger:jfL'
linger="$(pgrep -f "$LINGER_PAT" >/dev/null 2>&1 && echo 1 || echo 0)"
# damage: rc written after the pipe closes ⇒ a dead engine reads as merely quiet for as long
# as any orphan holds stdout, and the terminal verdict is AGENT-DEAD/no-rc instead of its code
chk_eq "T6 rc lands within 1s of the engine's exit, not at pipe EOF" 1 "$rc_landed"
# damage: the linger child never existed ⇒ T6 proved nothing about a held-open pipe
chk_eq "T6 the pipe's write end was really still held (grandchild alive)" 1 "$linger"
bash "$AGENTCTL" stop jfL >/dev/null 2>&1
pkill -f "$LINGER_PAT" 2>/dev/null || true

unset FAKE_OMP_LINGER_CHILD FAKE_OMP_TOOL_FRAMES AGENTCTL_BIN_OMP
sweep_fakes; sandbox_clean
summary
