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
12 SUPERVISOR-LOST
14 STALLED-PROGRESS
15 DELIVERED-NEXT-TURN"

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
  "ALL-PUBLISHED 13" "$([ -n "$human" ] && [ -z "$missing" ] && echo "ALL-PUBLISHED 13" \
                        || echo "MISSING${missing:-:empty-output}")"

echo "== S2: --json parses and carries exactly the human table's rows =="
counts="$(python3 -c '
import json, subprocess, sys
run = lambda *a: subprocess.run(["bash", sys.argv[1], "states", *a],
                                capture_output=True, text=True).stdout
doc = json.loads(run("--json"))
lines = [ln for ln in run().splitlines() if ln[:4].strip().isdigit()]
# the two vocabularies share the exit-code column; a sub-reason row is the one that spells the
# word the way the runtime prints it (`reason=<word>`)
states = [ln for ln in lines if "  reason=" not in ln]
subs = [ln for ln in lines if "  reason=" in ln]
print("json=%d human=%d subjson=%d subhuman=%d"
      % (len(doc["states"]), len(states), len(doc["subReasons"]), len(subs)))
' "$AGENTCTL")"
chk_eq "json entries == human rows, in BOTH vocabularies" \
  "json=13 human=13 subjson=8 subhuman=8" "$counts"

echo "== S3: only two spellings exist; anything else is refused =="
bogus="$(states --bogus 2>&1)"; rc=$?
table=no; case "$bogus" in *SUPERVISOR-LOST*) table=yes ;; esac
chk_eq "unknown option refused, no table printed" "rc=1 table=no" "rc=$rc table=$table"

echo "== S4: source consistency — the published set IS the code's typed vocabulary =="
# SCAN FACE = both python files of the lane. `EXIT_*` is defined in duplexctl.py alone, but the
# typed exits that RETURN those constants are split across duplexctl.py (engine + front door) and
# watchctl.py (patrol verbs) since 2026-08-30 — scanning one file would leave every `_watch_exit`
# and every watch verdict outside the bare-literal rule, which is most of the emission sites.
violations="$(states --json | python3 -c '
import ast, json, os, sys
paths = sys.argv[1:]
trees = [ast.parse(open(p, encoding="utf-8").read()) for p in paths]
published = {s["code"] for s in json.load(sys.stdin)["states"]}
defined = {n.value.value
           for tree in trees
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
for path, tree in zip(paths, trees):
    base = os.path.basename(path)
    for n in ast.walk(tree):
        for a in rc_args(n):
            if isinstance(a, ast.Constant) and isinstance(a.value, int) \
                    and a.value in published and a.value not in (0, 1):
                bad.append("bare-literal-verdict:%s:%d:%d" % (base, a.lineno, a.value))
print(" ".join(bad) if bad else "CONSISTENT %d" % len(published))
' "$CTL" "$(dirname "$CTL")/watchctl.py")"
chk_eq "no unpublished typed code and no bare-literal verdict" "CONSISTENT 13" "$violations"

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
chk_eq "S4b identity.py terminal map agrees with the published vocabulary" "AGREES 9" "$id_drift"

# ─────────────────────────────────────────────────────────────────────────────────────────
# S5..S8 — the SECOND published vocabulary: sub-reasons. Same contract, same threat: the words
# an orchestrator branches its disposition on (`reason=unknown-source`, `progress=unchanged`)
# were bare literals at their print sites, so the set existed only in prose and no consumer
# could enumerate it. S5 carries the suite's own oracle, S6 is the static anti-drift body with
# its own mutation calibration, and S7/S8 prove the closed set is ENFORCED at import, not
# merely documented.
SUB_ORACLE="14 repo-silent+tools-active
14 repo-silent+tools-silent
14 unknown-source
15 capability
15 undecidable
7 changed
7 unchanged
7 unknown"

echo "== S5: the published sub-reason set is exactly the suite's oracle =="
pub_subs="$(states --json | python3 -c '
import json, sys
for row in json.load(sys.stdin)["subReasons"]:
    print(row["code"], row["reason"])')"
chk_eq "S5 published sub-reasons == oracle" "$(printf '%s\n' "$SUB_ORACLE" | sort)" \
  "$(printf '%s\n' "$pub_subs" | sort)"
# every row must carry a MEANING: a word with an empty meaning publishes nothing an
# orchestrator can act on, and would make the human table lie by omission
empty="$(states --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)["subReasons"]
print(sum(1 for r in rows if not r["meaning"].strip()))')"
chk_eq "S5 no sub-reason row ships an empty meaning" 0 "$empty"
# the human table spells each word EXACTLY as the runtime prints it on the state's line
human_subs="$(states)"
miss=""
while read -r code word; do
  case "$human_subs" in *"reason=$word"*) continue ;; esac
  miss="$miss $code/$word"
done <<< "$SUB_ORACLE"
chk_eq "S5 the human table prints every word as reason=<word>" "ALL-PUBLISHED 8" \
  "$([ -z "$miss" ] && echo "ALL-PUBLISHED 8" || echo "MISSING$miss")"

echo "== S6: static consistency — a sub-reason may not exist outside the table =="
sandbox_new
GATE="$SANDBOX/subgate.py"
cat > "$GATE" <<'GATEPY'
# (source file..., published-json file) -> "CONSISTENT n" or the violations, statically. Same
# stance as S4: ast.parse of the file TEXT, never a dynamic import of the module under test.
# N SOURCE FILES, one closure: the lane's python is duplexctl.py (engine + front door) +
# watchctl.py (patrol verbs) since 2026-08-30. The rules are file-BLIND on purpose — a decider,
# an exemption or an emission site counts wherever it sits, so moving code between the two files
# can neither hide a violation nor invalidate an exemption. Line-keyed state is keyed by
# (file, line): two files share line numbers, and a shared `table_lines` would exempt an
# arbitrary literal in one file because the OTHER file has its table there.
import ast, json, os, re, sys

*paths, pub_path = sys.argv[1:]
trees = [(os.path.basename(p), ast.parse(open(p, encoding="utf-8").read())) for p in paths]
published = {(r["code"], r["reason"]) for r in json.load(open(pub_path))["subReasons"]}
pub_words = {word for _code, word in published}
ALL_NODES = [(base, node) for base, tree in trees for node in ast.walk(tree)]

ints, strs, table_lines, rows, state_words = {}, {}, set(), [], {}
for base, node in [(b, n) for b, tree in trees for n in tree.body]:
    # BOTH assignment forms: the constants are plain `X = "…"` while the table itself is an
    # ANNOTATED assign (`SUB_REASONS: tuple[...] = (…)`), which ast models as a different node —
    # scanning only ast.Assign found no table at all and would have reported drift forever
    if isinstance(node, ast.Assign):
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
    elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) \
            and node.value is not None:
        names = [node.target.id]
    else:
        continue
    span = range(node.lineno, (node.end_lineno or node.lineno) + 1)
    value = node.value
    if isinstance(value, ast.Constant) and isinstance(value.value, int):
        ints.update({n: value.value for n in names})
    if isinstance(value, ast.Constant) and isinstance(value.value, str):
        strs.update({n: value.value for n in names})
        if any(n.startswith("SUB_REASON_") for n in names):
            table_lines.update((base, ln) for ln in span)
    if "SUB_REASONS" in names and isinstance(value, ast.Tuple):
        table_lines.update((base, ln) for ln in span)
        for elt in value.elts:
            if not isinstance(elt, ast.Tuple) or len(elt.elts) != 3:
                rows.append((None, None))
                continue
            code, word = elt.elts[0], elt.elts[1]
            rows.append((
                ints.get(code.id) if isinstance(code, ast.Name)
                else code.value if isinstance(code, ast.Constant) else None,
                strs.get(word.id) if isinstance(word, ast.Name)
                else word.value if isinstance(word, ast.Constant) else None))
    if "TYPED_STATES" in names and isinstance(value, ast.Tuple):
        # the OTHER published vocabularies. A typed state's own `meaning` sentence is where the
        # words that are NOT sub-reasons are published — the waiter handshake's `dead`/`unknown`
        # (SUPERVISOR-LOST's own four-state machine, deliberately not folded into SUB_REASONS).
        # DERIVED, never hand-listed here: an exemption nobody publishes is a hole.
        table_lines.update((base, ln) for ln in span)
        for elt in value.elts:
            if not isinstance(elt, ast.Tuple) or len(elt.elts) != 3:
                continue
            name, meaning = elt.elts[1], elt.elts[2]
            if isinstance(name, ast.Constant) and isinstance(meaning, ast.Constant):
                state_words[name.value] = set(re.findall(r"reason=(\w[\w-]*)", meaning.value))

bad = []
defined = {(c, w) for c, w in rows if isinstance(c, int) and isinstance(w, str)}
if not rows:
    bad.append("SUB_REASONS-table-not-found")
if len(defined) != len(rows):
    bad.append("unreadable-row-in-SUB_REASONS")
if defined - published:
    bad.append("defined-but-unpublished:" + repr(sorted(defined - published)))
if published - defined:
    bad.append("published-but-undefined:" + repr(sorted(published - defined)))

NODE_BASE = {id(node): base for base, node in ALL_NODES}

# ── MODULE-QUALIFIED IDENTITY for every cross-function fact (R2 B1, hardened R3 F1) ───────
# A bare call name is not an identity once the scan face is two files. Keyed by name alone, a
# SAFE helper in one module whitelisted a same-named UNSAFE helper in the other, and an
# out-of-table `reason=rogue` emission passed with all 38 assertions green. Every summary below
# is keyed by (file, function), and a bare call is resolved by what PYTHON actually binds, never
# by spelling: the CALLER's own top-level definition, else the ORIGINAL symbol behind the name it
# `from`-imports from the other scanned module, else UNRESOLVED — which is never safe.
#
# Two ways the first version of this resolver still reached the wrong function (R3 F1, both
# independently reproduced), and both are now UNRESOLVED rather than "proven":
#   * `from duplexctl import _unsafe as _safe_name` — the alias table dropped `alias.name`, so the
#     checker proved the source module's SAFE `_safe_name` while python calls `_unsafe`. The table
#     now carries (source file, ORIGINAL symbol) and the lookup uses the original.
#   * lexical shadowing — a nested `def`/parameter/local rebinding of the same name inside the
#     emitter means the top-level definition is NOT what the call reaches. Any non-top-level
#     binding of a name anywhere in a file therefore poisons that name for the whole file.
# Coarse on purpose: this can only ever turn a "proven safe" into a red, never the other way.
DEFS = {}                                     # (file, name) -> the FunctionDef that name reaches
for base, node in ALL_NODES:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        DEFS.setdefault((base, node.name), node)
SCANNED = {base for base, _tree in trees}
TOPLEVEL = {id(node) for _base, tree in trees for node in tree.body}
FROM_IMPORT = {}                     # (file, local name) -> (defining file, ORIGINAL symbol)
for base, node in ALL_NODES:
    if isinstance(node, ast.ImportFrom) and node.module and not node.level:
        src = node.module.split(".")[-1] + ".py"
        if src in SCANNED:
            for alias in node.names:
                FROM_IMPORT[(base, alias.asname or alias.name)] = (src, alias.name)

# every name a file binds ANYWHERE except as one of its own top-level def/class statements: a
# nested def, a parameter, a local/loop/with/except/comprehension/walrus target, a function-local
# import, a global/nonlocal declaration, or a module-level assignment over the name.
SHADOWED = {base: set() for base in SCANNED}
for base, node in ALL_NODES:
    add = SHADOWED[base].add
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        if id(node) not in TOPLEVEL:
            add(node.name)
        args = getattr(node, "args", None)
        if args is not None:
            for a in (args.posonlyargs + args.args + args.kwonlyargs
                      + [x for x in (args.vararg, args.kwarg) if x is not None]):
                add(a.arg)
    elif isinstance(node, ast.Lambda):
        a = node.args
        for x in (a.posonlyargs + a.args + a.kwonlyargs
                  + [y for y in (a.vararg, a.kwarg) if y is not None]):
            add(x.arg)
    elif isinstance(node, (ast.Global, ast.Nonlocal)):
        for n in node.names:
            add(n)
    elif isinstance(node, (ast.Import, ast.ImportFrom)):
        if id(node) not in TOPLEVEL:
            for alias in node.names:
                add((alias.asname or alias.name).split(".")[0])
    elif isinstance(node, ast.Assign):          # module-level rebinding counts as well
        for tgt in node.targets:
            for n in ast.walk(tgt):
                if isinstance(n, ast.Name):
                    add(n.id)
    elif isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.NamedExpr)):
        for n in ast.walk(node.target):
            if isinstance(n, ast.Name):
                add(n.id)
    elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
        for n in ast.walk(node.target):
            if isinstance(n, ast.Name):
                add(n.id)
    elif isinstance(node, ast.withitem):
        if node.optional_vars is not None:
            for n in ast.walk(node.optional_vars):
                if isinstance(n, ast.Name):
                    add(n.id)
    elif isinstance(node, ast.ExceptHandler):
        if node.name:
            add(node.name)


def resolve(base, name):
    """the (file, name) key a BARE call to `name` inside `base` reaches, or None if this scan
    cannot prove WHICH function that is"""
    if name in SHADOWED.get(base, ()):          # something other than the top-level def binds it
        return None
    own, imported = (base, name) in DEFS, FROM_IMPORT.get((base, name))
    if own and imported is not None:            # two module-level bindings, order decides: unknown
        return None
    if own:
        return (base, name)
    if imported is not None and imported in DEFS:
        return imported                         # (source file, ORIGINAL symbol), never the alias
    return None


def callee(node):
    """(file, name) of the function this Call reaches, for a bare-name call; else None"""
    name = getattr(node.func, "id", "")
    return resolve(NODE_BASE[id(node)], name) if name else None


def func_key(func):
    return (NODE_BASE[id(func)], func.name)


# the ONE definition of the gate's axiom, resolved not spelled: a call is `sub_reason()` only if
# it reaches THIS function. A rogue same-named shadow in the other module is the same collision
# B1 named, one line different.
SUB_REASON = [k for k in DEFS if k[1] == "sub_reason"]
SUB_REASON_KEY = SUB_REASON[0] if len(SUB_REASON) == 1 else None
if SUB_REASON_KEY is None:
    bad.append("sub_reason-not-uniquely-defined:" + repr(sorted(SUB_REASON)))

# The functions that DECIDE or PRINT a sub-reason. Inside them a published word may appear only
# as an argument of sub_reason() — the one gate that refuses a word outside the closed set.
DECIDERS = ("progress_verdict", "_withheld_reason", "steer_delivery", "cmd_sense_loop")
found = set()
for _base, node in ALL_NODES:
    if not isinstance(node, ast.FunctionDef) or node.name not in DECIDERS:
        continue
    found.add(node.name)
    wrapped = {id(arg) for call in ast.walk(node)
               if isinstance(call, ast.Call) and callee(call) == SUB_REASON_KEY
               and SUB_REASON_KEY is not None
               for arg in call.args}
    for lit in ast.walk(node):
        if isinstance(lit, ast.Constant) and isinstance(lit.value, str) \
                and lit.value in pub_words and id(lit) not in wrapped:
            bad.append("bare-literal-in-decider:%s:%s:%d:%s"
                       % (NODE_BASE[id(node)], node.name, lit.lineno, lit.value))
missing = sorted(set(DECIDERS) - found)
if missing:
    bad.append("decider-not-found:" + ",".join(missing))
# ── EVERY emission of the three published fields takes its word from sub_reason() ─────────
# The rule the S6 scan above could not carry (cold review R1 S1: four out-of-set emission forms
# — an f-string word, a concatenated variable, a getattr-mediated read, a NEW emission helper
# outside the four deciders — all passed a checker that only compared string constants inside
# four named functions). This one scans the WHOLE file: any literal producing `reason=`,
# `progress=` or `progress_reason=` must take the word from `sub_reason()`, directly or through
# a name this scan PROVED is only ever bound to one (a fixpoint over assignments, tuple-unpack
# slots and returns, so `frozen, why, at, undecided, reason = progress_verdict(sess)` counts).
FIELDS = ("progress_reason=", "progress=", "reason=")
# Pinned per site: (FILE, function, the exact expression the word comes from) → why that site is
# not a verdict word. The three OTHER vocabularies, plus the one use of a field prefix that emits
# no word at all. The FILE is part of the key on purpose (R2 B1): a two-file scan face keyed by
# function name alone would let one module's exemption silently cover a same-named function in
# the other. Every entry must be USED — a stale exemption is drift, and a moved function whose
# exemption still names the old file reds here — and a new emission site anywhere reds until a
# human lands it here with what it belongs to named.
FOREIGN = {
    ("duplexctl.py", "receipt_note", "marker.get('reason')"):
        "the DELIVERED marker's own field, echoed out of a foreign record, never a verdict word",
    ("duplexctl.py", "cmd_states", "'reason=' + row['reason']"):
        "the renderer OF the published table: these words come from the table itself",
    ("watchctl.py", "cmd_identity", "identity.PUBLISH_INTERRUPTED"):
        "identity.py's published refusal vocabulary, on an IDENTITY-UNKNOWN message line",
    ("duplexctl.py", "cmd_states", "len('reason=')"):
        "a column WIDTH measured off the prefix: arithmetic, no word is emitted here",
}
used = set()
PARENT = {child: node for _base, node in ALL_NODES for child in ast.iter_child_nodes(node)}
FUNCS = [n for _base, n in ALL_NODES if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]


def enclosing_func(node):
    cur = PARENT.get(node)
    while cur is not None:
        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return cur
        cur = PARENT.get(cur)
    return None


def own_body(func):     # every node of func EXCEPT nested defs: those are their own scope
    out, stack = [], list(func.body)
    while stack:
        node = stack.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            continue
        out.append(node)
        stack.extend(ast.iter_child_nodes(node))
    return out


def ancestors(func):    # a closure reads the enclosing scope's names (delivered_rc/nxt_reason)
    out, cur = [], enclosing_func(func) if func is not None else None
    while cur is not None:
        out.append(cur)
        cur = enclosing_func(cur)
    return out


SAFE_SCALAR, SAFE_SLOT, TAINTED = set(), set(), {}   # SCALAR/SLOT keyed by (file, function)


def safe_expr(node, func):
    """True = this expression can only ever be a word sub_reason() returned (or empty)"""
    if isinstance(node, ast.Constant):
        return node.value == "" or node.value is None
    if isinstance(node, ast.Call) and SUB_REASON_KEY is not None \
            and callee(node) == SUB_REASON_KEY:
        return True
    if isinstance(node, ast.Name):
        return any(node.id in TAINTED.get(f, set()) for f in [func] + ancestors(func))
    if isinstance(node, ast.IfExp):
        return safe_expr(node.body, func) and safe_expr(node.orelse, func)
    if isinstance(node, ast.Call) and callee(node) in SAFE_SCALAR:
        return True
    return False


for _round in range(4):         # fixpoint: name taint and safe returns feed each other
    for func in FUNCS:
        body = own_body(func)
        binds = {}
        for node in body:
            if not isinstance(node, ast.Assign):
                continue
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    binds.setdefault(tgt.id, []).append(safe_expr(node.value, func))
                elif isinstance(tgt, ast.Tuple):
                    for i, elt in enumerate(tgt.elts):
                        if isinstance(elt, ast.Name):
                            binds.setdefault(elt.id, []).append(
                                isinstance(node.value, ast.Call)
                                and (callee(node.value), i) in SAFE_SLOT)
        # ALL bindings must be safe: one unsafe assignment poisons the name for the whole scope
        TAINTED[func] = {n for n, oks in binds.items() if oks and all(oks)}
        rets = [n.value for n in body if isinstance(n, ast.Return) and n.value is not None]
        if rets and all(safe_expr(r, func) for r in rets):
            SAFE_SCALAR.add(func_key(func))
        if rets and all(isinstance(r, ast.Tuple) for r in rets) \
                and len({len(r.elts) for r in rets}) == 1:
            for i in range(len(rets[0].elts)):
                if all(safe_expr(r.elts[i], func) for r in rets):
                    SAFE_SLOT.add((func_key(func), i))

DOCSTRINGS = {id(n.body[0].value) for _base, n in ALL_NODES
              if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
              and n.body and isinstance(n.body[0], ast.Expr)
              and isinstance(n.body[0].value, ast.Constant)
              and isinstance(n.body[0].value.value, str)}


def gated_hits(text):   # (field, word spelled inline or "") for every field this text emits
    return [(m.group(0), (re.match(r"[\w-]+", text[m.end():]) or re.match("", "")).group(0))
            for m in re.finditer(r"(?:progress_reason|progress|reason)=", text)]


def check(node, joined, hit, expr, func):
    field, inline = hit
    base = NODE_BASE[id(node)]
    fname = func.name if func is not None else "<module>"
    if inline:                                  # the word is spelled in the literal itself
        if any(state in joined and inline in words for state, words in state_words.items()):
            return None                         # that state's OWN published vocabulary
        return "hardcoded-word:%s:%s:%d:%s%s" % (base, fname, node.lineno, field, inline)
    # No word inside the literal: then the PREFIX ITSELF is the taint, and it must carry a word
    # this scan can PROVE came from sub_reason(). Cold review R2 S1: `field = "progress_reason="`
    # followed by `print(field + word)` splits the emission across two statements, so no single
    # expression holds prefix and word — and the old `expr is None ⇒ pass` free ride made every
    # such split invisible. A prefix with nothing provable attached to it reds, wherever it sits.
    if expr is None:
        parent = PARENT.get(node)
        key = (base, fname, ast.unparse(parent if parent is not None else node))
        if key in FOREIGN:
            used.add(key)
            return None
        return "prefix-literal-not-gated:%s:%s:%d:%s" % (base, fname, node.lineno, field)
    if safe_expr(expr, func):
        return None                             # proven: sub_reason(), or a name only it binds
    for state, words in state_words.items():
        if state not in joined:
            continue
        lits = ([expr] if isinstance(expr, ast.Constant)
                else [expr.body, expr.orelse] if isinstance(expr, ast.IfExp) else [])
        if lits and all(isinstance(x, ast.Constant) and x.value in words for x in lits):
            return None
    key = (base, fname, ast.unparse(expr))
    if key in FOREIGN:
        used.add(key)
        return None
    return "word-not-from-sub_reason:%s:%s:%d:%s%s" % (base, fname, node.lineno, field,
                                                       ast.unparse(expr))


for base, node in ALL_NODES:
    func = enclosing_func(node)
    if isinstance(node, ast.JoinedStr):
        parts = node.values
        joined = "".join(p.value for p in parts
                         if isinstance(p, ast.Constant) and isinstance(p.value, str))
        for i, part in enumerate(parts):
            if not (isinstance(part, ast.Constant) and isinstance(part.value, str)):
                continue
            for hit in gated_hits(part.value):
                nxt = parts[i + 1] if i + 1 < len(parts) else None
                expr = (nxt.value if not hit[1] and part.value.endswith(hit[0])
                        and isinstance(nxt, ast.FormattedValue) else None)
                bad += [v for v in [check(node, joined, hit, expr, func)] if v]
    elif isinstance(node, ast.Constant) and isinstance(node.value, str) \
            and id(node) not in DOCSTRINGS and (base, node.lineno) not in table_lines \
            and not isinstance(PARENT.get(node), ast.JoinedStr):
        parent = PARENT.get(node)
        for hit in gated_hits(node.value):
            # a CONCATENATION is the bypass form: the word rides the BinOp, not the literal
            expr = (parent if not hit[1] and isinstance(parent, ast.BinOp)
                    and isinstance(parent.op, ast.Add) else None)
            bad += [v for v in [check(node, node.value, hit, expr, func)] if v]

bad += ["unused-exemption:" + ":".join(key) for key in FOREIGN if key not in used]


# The words that are collision-free by construction (the other five — capability, undecidable,
# changed, unchanged, unknown — are ordinary English this module uses for other vocabularies:
# the supervisor liveness tri-state, the capability column header). These may not appear as a
# string literal ANYWHERE but the table, decider or not.
distinct = {w for w in pub_words if w.startswith("repo-silent") or w == "unknown-source"}
for base, lit in ALL_NODES:
    if isinstance(lit, ast.Constant) and isinstance(lit.value, str) \
            and lit.value in distinct and (base, lit.lineno) not in table_lines:
        bad.append("distinctive-word-outside-table:%s:%d:%s" % (base, lit.lineno, lit.value))
print(" ".join(bad) if bad else "CONSISTENT %d" % len(published))
GATEPY
states --json > "$SANDBOX/pub.json"
# the scan face is a shell function so no call site can forget the second file — the failure mode
# of a per-call-site path list is a green gate that stopped looking at half the lane
subgate() { python3 "$GATE" "$1/duplexctl.py" "$1/watchctl.py" "$SANDBOX/pub.json"; }
chk_eq "S6 the real module passes the sub-reason gate" "CONSISTENT 8" \
  "$(subgate "$(dirname "$CTL")")"

# ── S6b the gate BITES: the same checker against mutated copies ──────────────────────────
# A gate never calibrated against a known positive is a green surface, not a gate (this suite's
# own S4 history). Each mutation is proven to have really changed the file first.
cat > "$SANDBOX/mutate.py" <<'MUTPY'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
src = before = open(path, encoding="utf-8").read()
TABLE = "SUB_REASONS: tuple[tuple[int, str, str], ...] = (\n"
SENSE = "def cmd_sense_loop(args: argparse.Namespace) -> int:\n"
if mode == "bare-literal":       # a decision function spelling the word itself
    src = src.replace(SENSE, SENSE + '    _smuggled = "unknown-source"\n', 1)
elif mode == "drop-row":         # the code loses a word the published contract still carries
    src = re.sub(r"    \(EXIT_STALLED_PROGRESS, SUB_REASON_UNKNOWN_SOURCE,\n(?:     [^\n]*\n)+",
                 "", src, count=1)
elif mode == "unpublished-code":  # a sub-reason qualifying an exit the vocabulary never had
    src = src.replace(TABLE, TABLE + '    (3, "smuggled-word", "a sub-reason on exit 3"),\n', 1)
elif mode == "orphan-constant":   # a SUB_REASON_* constant nothing publishes
    src = src.replace(TABLE, 'SUB_REASON_ORPHAN = "orphan-word"\n\n' + TABLE, 1)
# ── the BYPASS forms cold review R1 S1 / R2 S1 walked through the old checkers ─────────────
# Each one emits a word outside the closed set WITHOUT a bare constant inside a named decider,
# which is exactly what the old scan could not see. All of them land on the same anchor so the
# fixture proves the FORM, not the location.
elif mode == "fstring-word":      # the word spelled straight into the format string
    src = src.replace(SENSE, SENSE + '    print(f"progress_reason=rogue-word smuggled")\n', 1)
elif mode == "concat-var":        # the word arrives by concatenation, never as one literal
    src = src.replace(SENSE, SENSE + '    _w = "rogue"\n'
                      '    print("progress_reason=" + _w + " smuggled")\n', 1)
elif mode == "getattr-word":      # a published constant read dynamically, bypassing the gate
    src = src.replace(SENSE, SENSE +
                      '    _g = getattr(sys.modules[__name__], "SUB_REASON_UNKNOWN")\n'
                      '    print(f"progress_reason={_g} smuggled")\n', 1)
elif mode == "new-helper":        # a NEW emission helper, outside every named decider
    src = src.replace("def cmd_sense_loop",
                      'def _emit_reason(word: str) -> None:\n'
                      '    print(f"progress_reason={word} smuggled")\n\n\n'
                      'def cmd_sense_loop', 1)
elif mode == "split-prefix":      # cold review R2 S1: the PREFIX is hoisted into its own
    # statement, so no single expression ever holds both the field and the word — the form that
    # walked straight through the `expr is None ⇒ pass` free ride
    src = src.replace(SENSE, SENSE + '    _field = "progress_reason="\n'
                      '    print(_field + "rogue" + " smuggled")\n', 1)
else:
    raise SystemExit("unknown mutation mode " + mode)
open(path, "w", encoding="utf-8").write(src)
print("MUTATED" if src != before else "NO-OP")
MUTPY
# `cmd_sense_loop` lives in watchctl.py and the SUB_REASONS table in duplexctl.py, so the mutation
# target is per MODE: an anchor applied to the wrong file is a NO-OP, which the chk below catches.
mutant() { # $1 mode -> copy of the shipped agentctl dir at $SANDBOX/$1, mutated
  rm -rf "$SANDBOX/$1"
  cp -R "$(dirname "$CTL")" "$SANDBOX/$1"
  local target=watchctl.py                     # the SENSE-anchored (decider) mutations
  case "$1" in
    drop-row|unpublished-code|orphan-constant) target=duplexctl.py ;;   # the TABLE-anchored ones
  esac
  chk_eq "S6b the '$1' mutation really changed the copy" "MUTATED" \
    "$(python3 "$SANDBOX/mutate.py" "$SANDBOX/$1/$target" "$1")"
}

mutant bare-literal
out="$(subgate "$SANDBOX/bare-literal")"
chk_contains "S6b a bare word inside a decision function reds" "bare-literal-in-decider" "$out"
chk_contains "S6b and the collision-free word is caught outside the table too" \
  "distinctive-word-outside-table" "$out"

mutant drop-row
out="$(subgate "$SANDBOX/drop-row")"
chk_contains "S6b a word dropped from the table but still published reds" \
  "published-but-undefined" "$out"

# the out-of-set emission FORMS: each must red on the closure scan, and the message must name
# the form — a gate that reds for the wrong reason is not calibrated either.
for form in fstring-word concat-var getattr-word new-helper split-prefix; do
  mutant "$form"
  out="$(subgate "$SANDBOX/$form")"
  case "$form" in
    fstring-word) want="hardcoded-word" ;;
    split-prefix) want="prefix-literal-not-gated" ;;
    *)            want="word-not-from-sub_reason" ;;
  esac
  chk_contains "S6b the '$form' bypass reds on the closure scan" "$want" "$out"
  chk_contains "S6b and the '$form' violation names the emitting function" \
    "progress_reason=" "$out"
done

# PAIRED GREEN for the closure scan itself: the copy mechanism is not what reds the four above.
rm -rf "$SANDBOX/closure-clean"
cp -R "$(dirname "$CTL")" "$SANDBOX/closure-clean"
chk_eq "S6b an unmutated copy still passes the closure scan" "CONSISTENT 8" \
  "$(subgate "$SANDBOX/closure-clean")"

echo "== S7: the closed set is ENFORCED at import, not merely published =="
# A row naming an exit the typed vocabulary does not publish, or a SUB_REASON_* constant absent
# from the table, must take EVERY verb down — a half-broken table that still serves `states` is
# how a word reaches an operator that no consumer can enumerate.
mutant unpublished-code
out="$(python3 "$SANDBOX/unpublished-code/duplexctl.py" states --json 2>&1)"; rc=$?
chk_eq "S7 a sub-reason on an unpublished exit refuses the whole module (rc)" 1 "$rc"
chk_contains "S7 and says the closed set is broken" "closed set is broken" "$out"

mutant orphan-constant
out="$(python3 "$SANDBOX/orphan-constant/duplexctl.py" states --json 2>&1)"; rc=$?
chk_eq "S7 an orphan SUB_REASON_* constant refuses the whole module (rc)" 1 "$rc"
chk_contains "S7 and names the constant that is not in the table" \
  "absent from the SUB_REASONS table" "$out"

echo "== S8: PAIRED GREEN — an unmutated copy still publishes and still passes =="
rm -rf "$SANDBOX/clean"
cp -R "$(dirname "$CTL")" "$SANDBOX/clean"
out="$(python3 "$SANDBOX/clean/duplexctl.py" states --json 2>&1)"; rc=$?
chk_eq "S8 the copy mechanism itself is not what reds S7 (rc)" 0 "$rc"
chk_eq "S8 and the unmutated copy carries the same 8 sub-reasons" 8 \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["subReasons"]))')"
sandbox_clean

summary
