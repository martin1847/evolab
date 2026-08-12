#!/usr/bin/env bash
# `agentctl states` — the typed state vocabulary is GENERATED from the code that produces it.
#
# Motive: the vocabulary lived only in prose (a table in agentctl's README), while the runtime
# that produces those exits could not say what it produces. Prose drifts silently; a generated
# verb cannot. Contract: ONE TYPED_STATES table in duplexctl.py, every typed exit in that
# module returns one of its EXIT_* constants, and `agentctl states` publishes exactly that set.
#
# S1 carries the suite's OWN oracle (a test with no independent expectation asserts nothing).
# S4 is the anti-drift body: a typed code that exists in the code but not in the published
# vocabulary — or a verdict smuggled out as a bare integer literal — reds here. It reads the
# source STATICALLY (ast.parse of the file text, no dynamic module load: the white-box
# coupling ban applies) and compares it against what the CLI publishes.
#
# Every probe prints a positive token, never "" on success, so a crashed probe cannot pass
# vacuously.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

CTL="$AW_DIR/duplexctl.py"
states() { bash "$AGENTCTL" states "$@"; }

# The suite's own expectation of the vocabulary. Adding a typed state is one edit in
# duplexctl's TYPED_STATES plus one edit here.
ORACLE="0 DONE
2 FAILED|AGENT-DEAD
4 WAITING-INPUT
5 STALLED-EXTERNAL
6 IDLE-NO-DELIVERABLE
7 WATCH-TIMEOUT
8 ENGINE-SILENT
9 BUDGET-EXHAUSTED
10 RUNNING
11 STALLED-STREAM
12 SUPERVISOR-LOST"

echo "== S1: the human table publishes every state the orchestrator lane can report =="
human="$(states)"
missing=""
while read -r code name; do
  case "$human" in
    *"$code  "*) case "$human" in *"$name"*) continue ;; esac ;;
  esac
  missing="$missing $code/$name"
done <<< "$ORACLE"
chk_eq "every expected state appears in the human table" \
  "ALL-PUBLISHED 11" "$([ -n "$human" ] && [ -z "$missing" ] && echo "ALL-PUBLISHED 11" \
                        || echo "MISSING${missing:-:empty-output}")"

echo "== S2: --json parses and carries exactly the human table's rows =="
counts="$(python3 -c '
import json, subprocess, sys
run = lambda *a: subprocess.run(["bash", sys.argv[1], "states", *a],
                                capture_output=True, text=True).stdout
doc = json.loads(run("--json"))
rows = [ln for ln in run().splitlines() if ln[:4].strip().isdigit()]
print("json=%d human=%d" % (len(doc["states"]), len(rows)))
' "$AGENTCTL")"
chk_eq "json entries == human rows" "json=11 human=11" "$counts"

echo "== S3: only two spellings exist; anything else is refused =="
bogus="$(states --bogus 2>&1)"; rc=$?
table=no; case "$bogus" in *SUPERVISOR-LOST*) table=yes ;; esac
chk_eq "unknown option refused, no table printed" "rc=1 table=no" "rc=$rc table=$table"

echo "== S4: source consistency — the published set IS the code's typed vocabulary =="
violations="$(states --json | python3 -c '
import ast, json, os, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read())
published = {s["code"] for s in json.load(sys.stdin)["states"]}
defined = {n.value.value
           for a in tree.body if isinstance(a, ast.Assign)
           for n in [a] if isinstance(a.value, ast.Constant) and isinstance(a.value.value, int)
           for t in a.targets if isinstance(t, ast.Name) and t.id.startswith("EXIT_")}
bad = []
if defined - published:
    bad.append("defined-but-unpublished:" + repr(sorted(defined - published)))
if published - defined:
    bad.append("published-but-undefined:" + repr(sorted(published - defined)))
# A verdict may never leave as a bare literal: it would bypass the table entirely.
# 0/1 are exempt — plain success and usage error, ubiquitous and unambiguous.
def rc_args(node):
    if isinstance(node, ast.Return) and node.value is not None:
        yield node.value
    if isinstance(node, ast.Call):
        fn = node.func
        name = fn.id if isinstance(fn, ast.Name) else getattr(fn, "attr", "")
        if name == "die" and len(node.args) > 1:
            yield node.args[1]
        elif name in ("exit", "_watch_exit") and node.args:
            yield node.args[0]
base = os.path.basename(path)
for n in ast.walk(tree):
    for a in rc_args(n):
        if isinstance(a, ast.Constant) and isinstance(a.value, int) \
                and a.value in published and a.value not in (0, 1):
            bad.append("bare-literal-verdict:%s:%d:%d" % (base, a.lineno, a.value))
print(" ".join(bad) if bad else "CONSISTENT %d" % len(published))
' "$CTL")"
chk_eq "no unpublished typed code and no bare-literal verdict" "CONSISTENT 11" "$violations"

# S4b — the SECOND production definition. duplexctl's table is the claimed single source, but
# identity.py hand-maintains the terminal subset (it gates whether a typed result may be
# published at all). Scanning only duplexctl false-greened a real drift: deleting a class there
# left S4 at 4 passed while the runtime refused to publish that exit (tail review M1 2026-08-12).
id_drift="$(states --json | python3 -c '
import ast, json, sys
pub = {s["code"]: s["name"] for s in json.load(sys.stdin)["states"]}
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
tc = {}
for a in tree.body:
    if isinstance(a, ast.Assign) and any(getattr(t, "id", "") == "TERMINAL_CLASSES" for t in a.targets):
        tc = {k.value: v.value for k, v in zip(a.value.keys, a.value.values)}
bad = [f"terminal-code-not-published:{c}" for c in sorted(tc) if c not in pub]
# names must agree where both speak; the published name may carry alternates (A|B)
bad += [f"name-disagrees:{c}:{tc[c]}!={pub[c]}" for c in sorted(tc)
        if c in pub and tc[c] not in pub[c].split("|")]
print(" ".join(bad) if bad else "AGREES %d" % len(tc))
' "$(dirname "$CTL")/identity.py")"
chk_eq "S4b identity.py terminal map agrees with the published vocabulary" "AGREES 8" "$id_drift"

summary
