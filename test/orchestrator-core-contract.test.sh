#!/usr/bin/env bash
# Mechanical contract for orchestrator-core (the domain-agnostic kernel).
#
# Why this suite exists: the kernel had zero assertion coverage, and a stale line in it
# ("restate, then the orchestrator releases you") survived the ruling that killed the same
# wording in the cto-orchestration lane — headless workers cannot be "released" because
# nobody is there to press confirm. A cold review found the survivor only by reading both
# skills side by side.
#
# What these assertions pin, and why it is the PREDICATE and not the outcomes: the first
# attempt at the fix split the rule by environment (orchestrator present vs worker cannot
# reach a person). A duplex lane satisfies both readings — the worker cannot prompt, yet the
# orchestrator can inject follow-ups — so a worker could not compute which branch it was in.
# Pinning only the two outcomes let a wrong classification pass green. The rule now turns on
# what the dispatch contract promises (readable by the worker before it acts) and keeps the
# channel question orthogonal, so these assertions pin the deciding predicate, the fail-safe
# default direction, and the orthogonality — not just the phrasing of the results.
#
# Layering: the kernel states the ABSTRACT rule (a gate must land on a structured channel);
# the naming of any concrete channel (BLOCKED.md, exit codes) stays in the lane that ships it.
# Asserting a concrete artifact name here would drag the implementation into the kernel.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

# ORCH_CORE_SKILL points the suite at another copy of the kernel — used to show these
# assertions discriminate against NATURAL bad samples rather than only passing on today's
# tree. Two known-positive samples, both reproducible:
#   git show origin/main:skills/orchestrator-core/SKILL.md   (pre-split kernel)
#   git show 12f1ac5:skills/orchestrator-core/SKILL.md       (the environment-keyed split a
#                                                             cold review rejected as undecidable)
# Feed either via: ORCH_CORE_SKILL=/dev/stdin, or write it to a file first.
CORE="${ORCH_CORE_SKILL:-../skills/orchestrator-core/SKILL.md}"
core_body="$(cat "$CORE")"

echo "== orchestrator-core contract =="

# (1) The branch predicate itself. A worker must be able to evaluate it from the contract in
# its hands, before acting — not by inferring who is watching.
chk_contains "release branch keys on the dispatch contract" "显式承诺了开工前的核对回合" "$core_body"
chk_contains "predicate is computable before acting" "读合同就能算" "$core_body"
chk_not_contains "presence is not the branch predicate" "编排者在场（能来回）→ 核对再放行" "$core_body"

# (2) The default direction is fail-safe: silence in the contract means no release round, so a
# worker never idles waiting for a handshake the lane never promised. Flipping this default is
# the mutation this assertion exists to catch.
chk_contains "unpromised release defaults to start immediately" "没承诺（默认）→ 无放行可言" "$core_body"

# (3) The channel rule, and its orthogonality to (1) — collapsing the two back into a single
# either/or is what made the predicate undecidable the first time.
chk_contains "headless gates must land on a structured channel" "结构化通道" "$core_body"
chk_contains "channel decides expression, not whether to stop" "通道只决定门怎么表达，决定不了" "$core_body"

# (4) The understanding gate itself must survive: the split refines it, never replaces it.
chk_contains "kernel keeps the understanding gate" "理解门" "$core_body"
chk_contains "kernel keeps silence-is-not-consent" "别把沉默当默许" "$core_body"

summary
