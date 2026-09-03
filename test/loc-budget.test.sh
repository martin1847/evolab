#!/usr/bin/env bash
# 总量棘轮 — three numbers for the whole shipped skill, and one structural canary.
#
# This file replaces four per-file ratchets (skill-face / agentctl-weight / context-budget /
# cto-docs-contract). Those kept a baseline row per file plus lock-new-low arms, so the routine
# outcome of every batch was editing a table, and the tables themselves outgrew what they watched.
# Owner ruling 2026-09-03 (减法批): keep the backpressure, drop the bookkeeping.
#
# WHAT IS ASSERTED, and nothing else:
#   * three totals, one direction only — growth reds, shrinkage is free and needs no lock-in.
#   * one canary: no orphan reference doc.
# There is deliberately NO per-file baseline, NO new-low arm, and NO rationale field. Whether a
# raised MAX is legitimate is a review question; raising it is a governed act, so move the number
# in the same commit that grows the file and say in the commit message what the growth buys.
#
# KNOWN BOUNDARY, stated rather than papered over: a total-only ratchet cannot tell "the code
# shrank" from "the gauge broke". Each assertion below therefore reds on a zero/empty measurement
# instead of reading it as success — but a PARTIALLY blind meter (an extractor that stops seeing
# one sink) still reads as a smaller number. The drop-one-local and known-positive recall probes
# that used to keep the byte meter honest were retired with context-budget.test.sh; that recall
# risk is accepted, not solved.
#
# Re-measure the three current values without asserting:  bash loc-budget.test.sh --measure
#
# GATE-AUDIT slug: loc-budget-total
#   kill criterion: over one retrospective cycle, if every hit was answered by bumping the MAX and
#   not once by a deletion or a 下沉, it is measuring nothing ⇒ delete. A ratchet whose only
#   effect is that its own number goes up is ceremony.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SKILL_ROOT="$REPO_ROOT/skills/cto-orchestration"

# ---- the three ceilings: measured on this tree, 2026-09-03 ------------------------------------
CODE_MAX=12702      # every shipped *.py / *.sh / the `agentctl` bash entrypoint, summed wc -l
PROSE_MAX=1585      # every shipped *.md under the skill, summed wc -l
INJECT_MAX=17314    # UTF-8 bytes of guard text that reaches an agent's context (extractor below)

# ---- meters ------------------------------------------------------------------------------------
# `wc -l` per file and summed, which is what the retired ratchets measured: a trailing line with
# no newline is not counted, consistently on both sides of the comparison.
_sum_lines() { # $@ = find predicates
  find "$SKILL_ROOT" -type f \( "$@" \) -exec wc -l {} + | awk 'END {print $1+0}'
}

code_lines="$(_sum_lines -name '*.py' -o -name '*.sh' -o -name 'agentctl')"
prose_lines="$(_sum_lines -name '*.md')"

# The injected-text census, lifted verbatim from the retired context-budget.test.sh: measure by
# SINK, in UTF-8 bytes. The sinks are where text actually leaves for an agent — sys.stderr.write
# (a PreToolUse denial reason), the additionalContext / permissionDecisionReason / reason /
# systemMessage fields of a json.dumps hook response, and a plain `print` (whose stdout the
# harness adds to context on UserPromptSubmit / SessionStart). Text reaching a sink through one
# local variable is resolved, because that is how the longest messages are written.
EXTRACT="$(mktemp)"; trap 'rm -f "$EXTRACT"' EXIT
cat > "$EXTRACT" <<'PY'
import ast, sys

SINK_KEYS = {"additionalContext", "permissionDecisionReason", "reason", "systemMessage"}

def literal_text(node):
    """Literal string text under one expression, counted once.

    ast.walk visits a JoinedStr and its Constant children, so adding both would double-count;
    collecting only Constants and letting the walk reach them through the JoinedStr avoids that.
    """
    return "".join(n.value for n in ast.walk(node)
                   if isinstance(n, ast.Constant) and isinstance(n.value, str))

def collect(path):
    tree = ast.parse(open(path).read())
    # The long messages are built as `msg = ("..." "...")` and then handed to a sink, so a literal
    # bound to a plain local name has to be resolvable or the biggest payloads read as zero.
    varmap = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            t = literal_text(n.value)
            if len(t) > 15:
                varmap[n.targets[0].id] = t

    def resolve(node):
        """Literal text at this sink, plus every local whose literal value flows into it.

        Resolving only a bare Name weighed an assembled payload — `"\\n".join(t for t in
        (reminder, note) if t)` — as ZERO bytes, so a rule could inject a page of text unweighed.
        """
        parts = [literal_text(node)]
        for n in ast.walk(node):
            if isinstance(n, ast.Name) and n.id in varmap:
                parts.append(varmap[n.id])
        return "".join(parts)

    msgs = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        if (isinstance(f, ast.Attribute) and f.attr == "write"
                and isinstance(f.value, ast.Attribute) and f.value.attr == "stderr"):
            for a in node.args:
                t = resolve(a)
                if len(t) > 15:
                    msgs.append(t)
        if isinstance(f, ast.Attribute) and f.attr == "dumps":
            for a in node.args:
                for n in ast.walk(a):
                    if isinstance(n, ast.Dict):
                        for k, v in zip(n.keys, n.values):
                            if isinstance(k, ast.Constant) and k.value in SINK_KEYS:
                                t = resolve(v)
                                if len(t) > 15:
                                    msgs.append(t)
        # Args carrying a `dumps` call are skipped: those are the JSON responses the branch above
        # already weighed, and counting both would double-charge every byte in the file.
        if isinstance(f, ast.Name) and f.id == "print":
            for a in node.args:
                if any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                       and n.func.attr == "dumps" for n in ast.walk(a)):
                    continue
                t = resolve(a)
                if len(t) > 15:
                    msgs.append(t)
    return msgs

print(sum(len(m.encode("utf-8")) for p in sys.argv[1:] for m in collect(p)))
PY

# Every shipped guard, by glob so a new one joins the meter on arrival (a sink in a file nobody
# listed is a sink nobody weighs). `seat-liveness.py` is a hook entrypoint too, weighed when
# present — the glob does not name it, so its removal leaves slack rather than an error.
GUARDS=("$SKILL_ROOT"/references/agentctl/cto-guard-*.py)
[ -f "$SKILL_ROOT/references/agentctl/seat-liveness.py" ] \
  && GUARDS+=("$SKILL_ROOT/references/agentctl/seat-liveness.py")
inject_bytes="$(python3 "$EXTRACT" "${GUARDS[@]}" 2>/dev/null || echo 0)"

if [ "${1:-}" = "--measure" ]; then
  echo "CODE_MAX=$code_lines    (shipped *.py / *.sh / agentctl, summed wc -l)"
  echo "PROSE_MAX=$prose_lines    (shipped *.md, summed wc -l)"
  echo "INJECT_MAX=$inject_bytes  (guard text reaching agent context, UTF-8 bytes)"
  exit 0
fi

echo "== skill total-size budget =="

# ---- 1..3: the totals, growth-only ---------------------------------------------------------
# A zero reading is a broken meter, never a shrunken skill: `find` matching nothing and the
# extractor failing to parse both look exactly like success against a `<=` ceiling.
_ceiling() { # $1 label  $2 actual  $3 max  $4 unit
  if [ "$2" -eq 0 ]; then
    _record "$1" 0 "the meter read 0 $4 — that is a broken gauge, not a smaller skill"
  elif [ "$2" -le "$3" ]; then
    _record "$1 ($2 <= $3 $4)" 1
  else
    _record "$1" 0 \
      "$2 $4 against a ceiling of $3 (+$(($2 - $3))) — cut something, or move the ceiling in this same commit and say in the commit message what the growth buys"
  fi
}

_ceiling "shipped code within the total ceiling" "$code_lines" "$CODE_MAX" lines
_ceiling "shipped prose within the total ceiling" "$prose_lines" "$PROSE_MAX" lines
_ceiling "injected guard text within the total ceiling" "$inject_bytes" "$INJECT_MAX" bytes

# ---- 4: the structural canary ------------------------------------------------------------------
# An unreferenced reference doc is dead weight nobody routes to and nobody deletes. Each file's
# BASENAME must appear in SKILL.md or in some OTHER reference doc; naming yourself does not count.
# Boundary: a generic basename (`README.md`) matches loosely, so this canary is weaker for those.
orphans=""
scanned=0
while IFS= read -r doc; do
  [ -n "$doc" ] || continue            # an empty find still yields one blank line
  scanned=$((scanned + 1))
  base="$(basename "$doc")"
  hits="$(grep -rlF "$base" "$SKILL_ROOT/SKILL.md" "$SKILL_ROOT/references" --include='*.md' \
          2>/dev/null | grep -vxF "$doc" | head -1)"
  [ -n "$hits" ] || orphans="$orphans $base"
done <<EOF
$(find "$SKILL_ROOT/references" -type f -name '*.md' | sort)
EOF
[ "$scanned" -eq 0 ] && orphans=" ERROR: no reference docs were scanned — the gauge is broken"

chk_eq "every reference doc is named by SKILL.md or another reference ($scanned scanned)" \
  "" "$orphans"

summary
