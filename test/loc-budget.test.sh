#!/usr/bin/env bash
# 总量棘轮 — three numbers for the whole shipped skill, and one structural canary.
#
# This file replaces four per-file ratchets (skill-face / agentctl-weight / context-budget /
# cto-docs-contract). Those kept a baseline row per file plus lock-new-low arms, so the routine
# outcome of every batch was editing a table, and the tables themselves outgrew what they watched.
# Owner ruling 2026-09-03 (减法批): keep the backpressure, drop the bookkeeping.
#
# WHAT IS ASSERTED, and nothing else:
#   * four ceilings, one direction only — growth reds, shrinkage is free and needs no lock-in.
#     Three are totals; the fourth is the longest SINGLE injected message, which bites where the
#     total cannot: a worker meets exactly one message, at the moment it is blocked.
#   * one canary: no orphan reference doc.
#   * two invariants recovered from the retired cto-docs-contract, each guarding a whole drift
#     class for ~5 lines: the white-box dynamic-load ban, and clause single-sourcing.
# There is deliberately NO per-file baseline, NO new-low arm, and NO rationale field. Whether a
# raised MAX is legitimate is a review question; raising it is a governed act, so move the number
# in the same commit that grows the file and say in the commit message what the growth buys.
#
# KNOWN BOUNDARY, stated rather than papered over: a total-only ratchet cannot tell "the code
# shrank" from "the gauge broke". Every arm here therefore reds on a zero/empty measurement
# instead of reading it as success — the ceilings on a 0 reading, the canary on a 0-file scan,
# the clause scan on a body-line face that is no longer 43. But a PARTIALLY blind byte meter (an
# extractor that stops seeing ONE sink) still reads as a smaller number: the drop-one-local and
# known-positive recall probes that kept it honest were retired with context-budget.test.sh, and
# that recall risk is accepted, not solved. Still abandoned with them, and NOT recovered here:
# the per-session footer budget, and skill-face's maintainer-doc filename gate.
#
# Re-measure the current values without asserting:  bash loc-budget.test.sh --measure
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
CODE_MAX=12597      # every shipped *.py / *.sh / the `agentctl` bash entrypoint, summed wc -l
PROSE_MAX=1533      # every shipped *.md under the skill, summed wc -l
INJECT_MAX=16913    # UTF-8 bytes of guard text that reaches an agent's context (extractor below)
INJECT_SINGLE_MAX=2012  # the longest SINGLE message, which bites harder than the total: a worker
                        # meets exactly one of these, at the moment it is blocked, and length
                        # there competes with the fix line it needs.

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
# harness adds to context on the two prompt-time events). Text reaching a sink through one
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

sizes = [len(m.encode("utf-8")) for p in sys.argv[1:] for m in collect(p)]
print(sum(sizes), max(sizes) if sizes else 0)
PY

# Every shipped hook entrypoint, by glob so a new guard joins the meter on arrival (a sink in a
# file nobody listed is a sink nobody weighs). `seat-census.py` is deliberately NOT here: it is a
# pure library the Stop gate imports and has no sink of its own.
GUARDS=("$SKILL_ROOT"/references/agentctl/cto-guard-*.py)
read -r inject_bytes inject_single <<EOF
$(python3 "$EXTRACT" "${GUARDS[@]}" 2>/dev/null || echo "0 0")
EOF

if [ "${1:-}" = "--measure" ]; then
  echo "CODE_MAX=$code_lines    (shipped *.py / *.sh / agentctl, summed wc -l)"
  echo "PROSE_MAX=$prose_lines    (shipped *.md, summed wc -l)"
  echo "INJECT_MAX=$inject_bytes  (guard text reaching agent context, UTF-8 bytes)"
  echo "INJECT_SINGLE_MAX=$inject_single   (longest single message a worker meets at once)"
  exit 0
fi

echo "== skill total-size budget =="

# ---- 1..4: the ceilings, growth-only --------------------------------------------------------
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
_ceiling "no single guard message exceeds the ceiling" "$inject_single" "$INJECT_SINGLE_MAX" bytes

# ---- 5: the structural canary ------------------------------------------------------------------
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

# ---- 6: white-box dynamic-load ban (recovered from cto-docs-contract, owner ruling 2026-08-09) --
# Tests drive the CLI. Dynamically loading the runtime modules to poke internals freezes the
# internal ABI and taxes every restructure; the probes never caught a field bug. Sanctioned
# consumers only: ws3/probe.py (fake-engine wire mechanism), replay-corpus.py (consumes the
# shipped projector as the single source of truth), and THIS file (the grep pattern below is
# itself a literal match). agentctl-duplex sanctioned 2026-08-17 for ONE block (idle-marks
# helpers): pure file arithmetic whose CLI-black-box path needs a full engine emulator answering
# get_state — negative leverage for a hint line. That sanction is enforced PRECISELY, not as a
# whole-file pass (review B2: a whole-file exemption let `m.classify` ride the allowlist unseen).
wb_offenders="$(grep -rl 'spec_from_file_location' . 2>/dev/null | sed 's|^\./||' | grep -v '__pycache__' | grep -vE '^(replay-corpus\.py|duplex-fixtures/ws3/probe\.py|loc-budget\.test\.sh|agentctl-duplex\.test\.sh)$' || true)"
chk_eq "white-box dynamic-load stays banned outside sanctioned consumers" "" "$wb_offenders"
# the sanction's precise face: every `m.<attr>` the duplex test consumes from the loaded module,
# pinned to exactly the helper pair. A third internal (`m.classify`…) goes red here.
duplex_consumes="$(grep -oE '\bm\.[A-Za-z_]+' agentctl-duplex.test.sh | sort -u | tr '\n' ' ')"
chk_eq "duplex test's white-box consumption is exactly the helper pair" \
  "m._idle_mark_and_count m._idle_marks_reset " "$duplex_consumes"
# named evasion from review R2: getattr(m, ...) reaches internals without an m.attr literal.
chk_eq "no getattr-shaped access to the loaded module" "" \
  "$(grep -n 'getattr( *m' agentctl-duplex.test.sh || true)"

# ---- 7: clause single source (recovered from cto-docs-contract) --------------------------------
# The externalization's whole value is that a goal author reads 14 index lines instead of ~41
# lines of bodies. Two failure modes: a body creeping back into the template (double source, the
# two copies then drift) and an index row growing into a body (the template re-fattens).
CLAUSES="$SKILL_ROOT/references/goal-clauses.md"
GOAL="$SKILL_ROOT/references/goal-template.md"
chk_eq "clause file has exactly fourteen clause sections" 14 "$(grep -c '^## C[0-9][0-9] ' "$CLAUSES")"
chk_eq "clause file has exactly fourteen clause bodies" 14 "$(grep -c '^- \[ \]' "$CLAUSES")"
chk_eq "template index has exactly fourteen rows" 14 "$(grep -c '^- \[ \] C[0-9][0-9] ' "$GOAL")"
# every id defined once and indexed once — a renumber, a dropped clause or a duplicated id reds
id_defects=""
for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  h="$(grep -c "^## C$n " "$CLAUSES")"; r="$(grep -c "^- \[ \] C$n " "$GOAL")"
  [ "$h" = 1 ] && [ "$r" = 1 ] || id_defects="$id_defects C$n(heading=$h,index=$r)"
done
chk_eq "every clause id is defined once and indexed once" "" "$id_defects"
# no double source, over EVERY non-empty body line (R1 Major-3 ruling): a first-line-only scan
# covered 14 of 43 body lines, so a copied-back CONTINUATION was invisible — and a partial copy
# drifts exactly like a whole one.
clause_body_lines() { # $1 clause file -> every non-empty line belonging to a clause body
  python3 -c 'import re, sys
inbody = False
for l in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if re.match(r"^- \[ \] ", l):
        inbody = True; print(l); continue
    if inbody and l.startswith("  ") and l.strip():
        print(l); continue
    inbody = False
' "$1"
}
dual_scan() { # $1 clause file  $2 template -> one defect line per body line not single-sourced
  local row c g
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    c="$(grep -cF -- "$row" "$1")"; g="$(grep -cF -- "$row" "$2")"
    [ "$c" = 1 ] && [ "$g" = 0 ] || printf '[clauses=%s template=%s] %s\n' "$c" "$g" "$row"
  done <<EOF
$(clause_body_lines "$1")
EOF
}
# the face's own size is pinned: an extractor that stops seeing body lines would make the scan
# below vacuously green, which is the same broken-gauge-reads-as-success shape as a zero total.
chk_eq "the single-source face is all 43 body lines, not just the 14 first lines" 43 \
  "$(clause_body_lines "$CLAUSES" | grep -c '[^[:space:]]')"
chk_eq "every clause body line is single-sourced in goal-clauses.md" "" "$(dual_scan "$CLAUSES" "$GOAL")"

summary
