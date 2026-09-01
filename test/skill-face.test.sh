#!/usr/bin/env bash
# 产品面两颗牙 — what ships inside skills/ is the CUSTOMER's surface, and nothing watched it.
#
# Field motive, both halves observed in this repo:
#  * MAINTAINER DOCS LEAKED IN. ARCHITECTURE.md was added under
#    skills/cto-orchestration/references/agentctl/ at b79455b and lived there until a human
#    noticed and moved it out by hand. Manufacturing/maintenance prose is not a customer's
#    context; it belongs in the repo's own meta/arch/. Nothing mechanical objected.
#  * SHIPPED PROSE HAD NO BACKPRESSURE. Code has the weight ratchet (agentctl-weight.test.sh),
#    injected text has the context budget (context-budget.test.sh). The md files a client
#    actually reads had neither — every batch could add three sentences forever, and "brief"
#    as a discipline never held for one review cycle.
#
# This file is two independent gates in one suite, each with its own real invocation so the
# self-tests below exercise the SAME code path the repo gets, never a re-implementation:
#   bash skill-face.test.sh --gate-filename <root>   T1
#   bash skill-face.test.sh --gate-prose <root>      T3
#
# GOVERNANCE, NOT MACHINERY (same rule as the weight ratchet): these gates judge NAMES and
# NUMBERS only. Whether a baseline bump is legitimate, or whether a doc really is a maintainer
# doc, is a review question — the breach text names the obligation and no code here pretends to
# verify a rationale.
#
# GATE-AUDIT slugs — each tooth is accounted for separately at retrospective:
#   slug: skill-face-filename
#     kill criterion: hits=0 ∧ false-positives>=2 over one retrospective cycle ⇒ delete the gate.
#   slug: skill-face-prose-ratchet
#     kill criterion: hits=0 ∧ false-positives>=2 over one retrospective cycle ⇒ delete; AND,
#     independently, if over a cycle it never once forced a deletion or a 下沉 and every hit was
#     answered by a mechanical baseline bump, it is measuring nothing ⇒ delete. A ratchet whose
#     only effect is that its own number goes up is ceremony.
set -u
cd "$(dirname "$0")"

GATE_OK=0
GATE_BREACH=1
GATE_ERROR=2

# ── T1: the maintainer-doc filename gate ─────────────────────────────────────
# Basename prefixes, matched case-INSENSITIVELY, extension-blind (`ARCHITECTURE.md`,
# `architecture`, `Architecture.rst` all count — the leak this gate exists for was a .md, but a
# rename is not a defence). `maintainer*` covers MAINTAINERS* by prefix.
# Deliberately a NAME test and not a content test: names are what a customer's file tree shows,
# they are cheap to judge, and a content classifier here would buy a green surface a reviewer
# would then trust. False positives are the accepted cost and are what the kill criterion counts.
MAINT_PREFIXES='architecture design contributing maintainer hacking'
SKILL_TREE='skills'
MAINT_HOME='meta/arch/'

filename_gate() { # $1 root -> findings on stdout; rc 0 clean / 1 breach / 2 measurement error
  local root="$1" rc=$GATE_OK tree list frc n path base lower pfx hit
  tree="$root/$SKILL_TREE"
  if [ ! -d "$tree" ] || [ ! -r "$tree" ] || [ ! -x "$tree" ]; then
    printf 'GATE_ERROR %s/ — 量不到 skill 树（不存在/不可读）：门不会因为看不见而绿\n' "$SKILL_TREE"
    return $GATE_ERROR
  fi
  # find's rc must be READ, not swallowed by a pipeline (this repo's known bug shape): capture
  # first, judge the rc, and only then iterate.
  # __pycache__ is pruned: running this repo's own suite imports duplexctl/watchctl/identity and
  # drops .pyc files INSIDE the skill tree, so an unpruned census counted 82 on a clean checkout
  # and 85 after one suite run. Those bytes are a byproduct, not product, and no .pyc basename can
  # match a maintainer-doc prefix — pruning removes noise from the reported count, not coverage.
  # SYMLINKS ARE ENTRIES (R2/B1): `-type f` alone missed them, so a `skills/**/ARCHITECTURE.md`
  # that was a link to a maintainer doc outside the tree scanned clean at rc=0 — the exact
  # bypass of a name judgement this gate exists to make. T1 judges the BASENAME a customer's
  # file tree shows, so the link's target is irrelevant: a broken link named DESIGN.md is still
  # a DESIGN.md on the product face, and a link is never followed here.
  list="$(find "$tree" \( -type f -o -type l \) -not -path '*/__pycache__/*' -print 2>&1)"; frc=$?
  if [ "$frc" -ne 0 ]; then
    printf 'GATE_ERROR find %s/ rc=%s — 量具坏：%s\n' "$SKILL_TREE" "$frc" "$list"
    return $GATE_ERROR
  fi
  n="$(printf '%s\n' "$list" | grep -c '[^[:space:]]')"
  if [ "$n" -eq 0 ]; then
    printf 'GATE_ERROR %s/ 下 0 个文件 — 量具坏（一个空扫描不是一次通过）\n' "$SKILL_TREE"
    return $GATE_ERROR
  fi
  while read -r path; do
    [ -z "$path" ] && continue
    base="${path##*/}"
    lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    hit=0
    for pfx in $MAINT_PREFIXES; do
      case "$lower" in "$pfx"*) hit=1; break ;; esac
    done
    if [ "$hit" -eq 1 ]; then
      printf 'BREACH %s — 维护者文档不进 skill 本体：下沉到 %s（客户用不到的不进产品面）\n' \
        "${path#"$root"/}" "$MAINT_HOME"
      rc=$GATE_BREACH
    fi
  done <<EOF
$list
EOF
  [ "$rc" -eq $GATE_OK ] && printf 'clean %s/ %s files scanned, no maintainer-doc name\n' "$SKILL_TREE" "$n"
  return $rc
}

# ── T3: the shipped-prose ratchet ────────────────────────────────────────────
# Per-file `wc -l` baselines for every *.md shipped under the orchestration skill. Measured at
# fb09bfb (2026-08-31) on this worktree's HEAD — the numbers are what the tree WAS, never a
# target anyone argued for.
#
# The ratchet bites four ways, on purpose:
#   * actual > baseline        — growth. Either the prose belongs in references/ or meta/arch/,
#                                or the baseline moves in the SAME commit and the commit message
#                                says why the words had to go into THIS shipped file.
#   * actual < baseline-slack  — a new low nobody locked in. Cutting prose is the whole point;
#                                an unlocked new low lets the next batch silently re-spend it.
#                                The slack is PER FILE (see prose_slack below), never a flat
#                                number: one constant that fits a 225-line page is a dead arm on
#                                a 20-line one, and a gate with a dead arm on a third of its rows
#                                is measuring less than it claims.
#   * a row's file is gone     — GATE_ERROR, never a pass. A renamed/moved file was a silent
#                                green in every gate this repo built before the weight ratchet.
#   * an unregistered *.md     — BREACH. A new shipped page is exactly how prose escapes a
#                                per-file table, so registration is part of the ratchet.
# ERROR outranks BREACH: the file nobody can measure is the one nobody is watching.
#
# UPDATING A ROW IS A GOVERNED ACT. Same commit, and the reason in the commit message.
PROSE_SUBTREE='skills/cto-orchestration'
PROSE_BASELINES='
skills/cto-orchestration/SKILL.md 134
skills/cto-orchestration/README.md 151
skills/cto-orchestration/references/agentctl/README.md 230
skills/cto-orchestration/references/agents-md-orchestration-section.md 53
skills/cto-orchestration/references/decision-queue.md 76
skills/cto-orchestration/references/dispatch-baseline.md 42
skills/cto-orchestration/references/frontend-verify.md 104
skills/cto-orchestration/references/goal-template.md 129
skills/cto-orchestration/references/implementation-discipline.md 94
skills/cto-orchestration/references/measurement-protocol.md 43
skills/cto-orchestration/references/onboarding-checklist.md 20
skills/cto-orchestration/references/ops-prompt-template.md 43
skills/cto-orchestration/references/retrospective.md 81
skills/cto-orchestration/references/review-brief-preamble.md 28
skills/cto-orchestration/references/review-dispatch.md 208
skills/cto-orchestration/references/shock-in-the-loop.md 58
skills/cto-orchestration/references/stocktake.md 25
'
# Per-file lock-new-low slack: max(5, baseline/10) floored. Mechanical, so no row gets an
# argued-for exemption, and every row's arm is LIVE — a 20-line page must be cut by 6 before it
# owes a lock, a 225-line one by 23. The 10% shape is a tunable with no experiment behind it; the
# floor of 5 exists because a 1-2 line arm on the smallest pages would fire on ordinary churn.
prose_slack() { # $1 baseline -> slack
  local s=$(( $1 / 10 ))
  [ "$s" -lt 5 ] && s=5
  printf '%s\n' "$s"
}

prose_gate() { # $1 root -> per-file verdicts on stdout; rc 0 within / 1 breach / 2 measurement error
  local root="$1" rc=$GATE_OK sub list frc n rel base actual slack floor registry path
  sub="$root/$PROSE_SUBTREE"
  if [ ! -d "$sub" ] || [ ! -r "$sub" ] || [ ! -x "$sub" ]; then
    printf 'GATE_ERROR %s — 量不到散文树（不存在/不可读）：门不会因为看不见而绿\n' "$PROSE_SUBTREE"
    return $GATE_ERROR
  fi
  # SYMLINKS ARE ENTRIES (R2/B2): `-type f` alone missed them, so an unregistered
  # `references/unregistered-link.md` symlink escaped the per-file table entirely at rc=0. The
  # registered rows already read THROUGH a link (`-f`/`wc -l` follow), so a row may legitimately
  # BE a link as long as its target measures within baseline; what may not happen is an entry
  # nobody weighs. A link whose target is broken or unreadable is a MEASUREMENT failure, not a
  # pass: arm (a) reds it via `-f`, arm (b) below reds it explicitly.
  list="$(find "$sub" \( -type f -o -type l \) -name '*.md' -print 2>&1)"; frc=$?
  if [ "$frc" -ne 0 ]; then
    printf 'GATE_ERROR find %s rc=%s — 量具坏：%s\n' "$PROSE_SUBTREE" "$frc" "$list"
    return $GATE_ERROR
  fi
  n="$(printf '%s\n' "$list" | grep -c '[^[:space:]]')"
  if [ "$n" -eq 0 ]; then
    printf 'GATE_ERROR %s 下 0 个 *.md — 量具坏（一个空扫描不是一次通过）\n' "$PROSE_SUBTREE"
    return $GATE_ERROR
  fi

  # (a) every registered row is weighed
  registry=' '
  while read -r rel base; do
    [ -z "$rel" ] && continue
    registry="$registry$rel "
    if [ ! -f "$root/$rel" ] || [ ! -r "$root/$rel" ]; then
      printf 'GATE_ERROR %s — 棘轮量不到这个文件（moved? renamed? deleted?）：登记表和树必须同 commit 对齐\n' "$rel"
      rc=$GATE_ERROR
      continue
    fi
    actual="$(wc -l < "$root/$rel" | tr -d ' ')"
    slack="$(prose_slack "$base")"
    floor=$(( base - slack ))
    if [ "$actual" -gt "$base" ]; then
      printf 'BREACH %s grew %s->%s — 下沉到 references/ 或 meta/arch，或同 commit bump 基线并在 commit message 写明为什么非进这个 shipped 文件\n' \
        "$rel" "$base" "$actual"
      [ "$rc" -eq $GATE_ERROR ] || rc=$GATE_BREACH
    elif [ "$actual" -lt "$floor" ]; then
      printf 'BREACH %s dropped %s->%s (>%s under baseline) — 锁住新低：把基线改成 %s（棘轮只紧不松）\n' \
        "$rel" "$base" "$actual" "$slack" "$actual"
      [ "$rc" -eq $GATE_ERROR ] || rc=$GATE_BREACH
    else
      printf 'within %s %s/%s\n' "$rel" "$actual" "$base"
    fi
  done <<EOF
$PROSE_BASELINES
EOF

  # (b) every shipped *.md is registered — the escape hatch a per-file table otherwise leaves open
  while read -r path; do
    [ -z "$path" ] && continue
    rel="${path#"$root"/}"
    case "$registry" in
      *" $rel "*) continue ;;   # registered rows are judged in (a); no second verdict here
    esac
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      printf 'GATE_ERROR %s 未登记且量不到（断链/不可读 symlink，或指向目录）：先修这个 entry，再登记基线\n' "$rel"
      rc=$GATE_ERROR
      continue
    fi
    printf 'BREACH %s 未登记 — 新增 shipped md 必须同 commit 登记一行基线（%s 行）\n' \
      "$rel" "$(wc -l < "$path" | tr -d ' ')"
    [ "$rc" -eq $GATE_ERROR ] || rc=$GATE_BREACH
  done <<EOF
$list
EOF
  return $rc
}

case "${1:-}" in
  --gate-filename) filename_gate "${2:?--gate-filename needs a root}"; exit $? ;;
  --gate-prose)    prose_gate    "${2:?--gate-prose needs a root}";    exit $? ;;
esac

. ./lib-testkit.sh

SELF="$(pwd)/$(basename "$0")"
run_gate() { # $1 --gate-*  $2 root -> sets GOUT/GRC
  GOUT="$(bash "$SELF" "$1" "$2" 2>&1)"; GRC=$?
}

mk_lines() { # $1 path  $2 count
  mkdir -p "$(dirname "$1")"
  : > "$1"
  [ "$2" -gt 0 ] && seq 1 "$2" > "$1"
  return 0
}

sandbox_new

# ═══ T1 skill-face-filename ══════════════════════════════════════════════════

# ── F1 the real tree is clean ────────────────────────────────────────────────
run_gate --gate-filename "$REPO_ROOT"
chk_eq "F1 the real skills/ tree carries no maintainer doc (rc)" 0 "$GRC"
chk_not_contains "F1 no breach line for the real tree" "BREACH" "$GOUT"
chk_not_contains "F1 no measurement error on the real tree" "GATE_ERROR" "$GOUT"
chk_contains "F1 the scan reports what it weighed" "clean skills/" "$GOUT"
# a census that silently saw nothing would make this arm green by doing nothing at all. Same
# census as the gate: __pycache__ pruned (suite byproduct), symlinks counted as entries (R2/B1).
real_files="$(find "$REPO_ROOT/skills" \( -type f -o -type l \) -not -path '*/__pycache__/*' | grep -c '[^[:space:]]')"
chk_contains "F1 the scanned count is the real file count" "skills/ $real_files files scanned" "$GOUT"

# ── the T1 fixture: a skills/ tree shaped like the real one, no maintainer doc ─
mk_fnfix() { # $1 root
  rm -rf "$1"
  mk_lines "$1/skills/cto-orchestration/SKILL.md" 10
  mk_lines "$1/skills/cto-orchestration/references/dispatch-baseline.md" 10
  mk_lines "$1/skills/cto-orchestration/references/agentctl/README.md" 10
  mk_lines "$1/skills/cto-orchestration/references/agentctl/agentctl" 10
  mk_lines "$1/skills/agent-mail/SKILL.md" 10
}

# ── F2 the leak that actually happened reds, at the path it happened at ──────
mk_fnfix "$SANDBOX/leak"
mk_lines "$SANDBOX/leak/skills/cto-orchestration/references/agentctl/ARCHITECTURE.md" 40
run_gate --gate-filename "$SANDBOX/leak"
chk_eq "F2 ARCHITECTURE.md under a skill reds (rc)" 1 "$GRC"
chk_contains "F2 breach names the offending path" \
  "BREACH skills/cto-orchestration/references/agentctl/ARCHITECTURE.md" "$GOUT"
chk_contains "F2 breach points at the maintainer home" "meta/arch/" "$GOUT"

# ── F3 case does not launder it, and neither does a missing extension ────────
mk_fnfix "$SANDBOX/lower"
mk_lines "$SANDBOX/lower/skills/agent-mail/design.md" 5
run_gate --gate-filename "$SANDBOX/lower"
chk_eq "F3 lowercase design.md reds (rc)" 1 "$GRC"
chk_contains "F3 breach names the lowercase file" "BREACH skills/agent-mail/design.md" "$GOUT"

mk_fnfix "$SANDBOX/noext"
mk_lines "$SANDBOX/noext/skills/agent-mail/HACKING" 5
run_gate --gate-filename "$SANDBOX/noext"
chk_eq "F4 an extensionless HACKING reds (rc)" 1 "$GRC"
chk_contains "F4 breach names the extensionless file" "BREACH skills/agent-mail/HACKING" "$GOUT"

mk_fnfix "$SANDBOX/suffixed"
mk_lines "$SANDBOX/suffixed/skills/agent-mail/CONTRIBUTING.rst" 5
mk_lines "$SANDBOX/suffixed/skills/agent-mail/MAINTAINERS.md" 5
run_gate --gate-filename "$SANDBOX/suffixed"
chk_eq "F4 prefix match is extension-blind and covers MAINTAINERS (rc)" 1 "$GRC"
chk_contains "F4 CONTRIBUTING.rst is named" "BREACH skills/agent-mail/CONTRIBUTING.rst" "$GOUT"
chk_contains "F4 MAINTAINERS.md is named" "BREACH skills/agent-mail/MAINTAINERS.md" "$GOUT"

# ── F5 removing the injected file restores green: the gate reacts to the file,
#     not to the fixture ─────────────────────────────────────────────────────
rm -f "$SANDBOX/lower/skills/agent-mail/design.md"
run_gate --gate-filename "$SANDBOX/lower"
chk_eq "F5 the same tree without the injected doc is green (rc)" 0 "$GRC"
chk_not_contains "F5 no breach after the injected doc is removed" "BREACH" "$GOUT"

# ── F6 the gate is not over-broad: ordinary shipped names stay green ─────────
mk_fnfix "$SANDBOX/plain"
run_gate --gate-filename "$SANDBOX/plain"
chk_eq "F6 SKILL.md / README.md / dispatch-baseline.md are not maintainer docs (rc)" 0 "$GRC"

# ── F7 a broken gauge is an explicit red, never a silent pass ────────────────
mkdir -p "$SANDBOX/noskills"
run_gate --gate-filename "$SANDBOX/noskills"
chk_eq "F7 a missing skills/ tree exits GATE_ERROR (rc)" 2 "$GRC"
chk_contains "F7 the error names the unmeasurable tree" "GATE_ERROR skills/" "$GOUT"

mk_fnfix "$SANDBOX/unreadable"
chmod 000 "$SANDBOX/unreadable/skills"
run_gate --gate-filename "$SANDBOX/unreadable"
FN_UNREAD_RC=$GRC; FN_UNREAD_OUT=$GOUT
chmod 755 "$SANDBOX/unreadable/skills"
chk_eq "F7 an unreadable skills/ tree exits GATE_ERROR (rc)" 2 "$FN_UNREAD_RC"
chk_contains "F7 the unreadable tree is named" "GATE_ERROR skills/" "$FN_UNREAD_OUT"

mkdir -p "$SANDBOX/emptyskills/skills"
run_gate --gate-filename "$SANDBOX/emptyskills"
chk_eq "F7 an empty scan is a measurement error, not a pass (rc)" 2 "$GRC"
chk_contains "F7 the empty scan is named as a broken gauge" "0 个文件" "$GOUT"

# ── F8 a symlink is an ENTRY, not a hole (R2/B1) ─────────────────────────────
# The reviewer's repro: a `skills/**/ARCHITECTURE.md` that is a LINK to a maintainer doc outside
# the tree. `find -type f` never listed it, so the gate reported `clean` at rc=0 — the name
# judgement bypassed by one `ln -s`. T1 judges the basename a customer's tree shows and never
# follows the link, so all three shapes below red: link to a real file, link to a directory,
# and a dangling link.
mk_fnfix "$SANDBOX/symlink"
mk_lines "$SANDBOX/symlink/outside-maintainer-doc.md" 40
ln -s "$SANDBOX/symlink/outside-maintainer-doc.md" \
  "$SANDBOX/symlink/skills/cto-orchestration/references/ARCHITECTURE.md"
run_gate --gate-filename "$SANDBOX/symlink"
chk_eq "F8 a symlinked ARCHITECTURE.md reds (rc)" 1 "$GRC"
chk_contains "F8 breach names the symlinked path" \
  "BREACH skills/cto-orchestration/references/ARCHITECTURE.md" "$GOUT"

mk_fnfix "$SANDBOX/symdangling"
ln -s "$SANDBOX/symdangling/no-such-target.md" \
  "$SANDBOX/symdangling/skills/agent-mail/DESIGN.md"
run_gate --gate-filename "$SANDBOX/symdangling"
chk_eq "F8 a DANGLING symlink named DESIGN.md still reds (rc)" 1 "$GRC"
chk_contains "F8 breach names the dangling link" "BREACH skills/agent-mail/DESIGN.md" "$GOUT"

mk_fnfix "$SANDBOX/symdir"
mkdir -p "$SANDBOX/symdir/some-dir"
ln -s "$SANDBOX/symdir/some-dir" "$SANDBOX/symdir/skills/agent-mail/HACKING.md"
run_gate --gate-filename "$SANDBOX/symdir"
chk_eq "F8 a symlink-to-directory named HACKING.md reds (rc)" 1 "$GRC"
chk_contains "F8 breach names the directory link" "BREACH skills/agent-mail/HACKING.md" "$GOUT"

# still not over-broad: an innocent link name stays green, and the census GREW by it
mk_fnfix "$SANDBOX/syminnocent"
mk_lines "$SANDBOX/syminnocent/shared-readme.md" 10
ln -s "$SANDBOX/syminnocent/shared-readme.md" "$SANDBOX/syminnocent/skills/agent-mail/README.md"
run_gate --gate-filename "$SANDBOX/syminnocent"
chk_eq "F8 an innocent symlink name stays green (rc)" 0 "$GRC"
chk_contains "F8 the innocent link was still COUNTED (6 entries, not 5)" \
  "skills/ 6 files scanned" "$GOUT"

# ═══ T3 skill-face-prose-ratchet ═════════════════════════════════════════════

SK=skills/cto-orchestration/SKILL.md
# derived, never a second copy of the number: a hardcoded fixture literal reds self-tests that
# are not about that baseline move at all (the lesson agentctl-weight.test.sh already paid for)
SK_BASE="$(printf '%s\n' "$PROSE_BASELINES" | awk -v p="$SK" '$1 == p { print $2 }')"
chk_eq "P0 the fixtures read the baseline they test against" 1 \
  "$([ -n "$SK_BASE" ] && echo 1 || echo 0)"

# ── P1 the real tree is within the ratchet, and every row was weighed ───────
run_gate --gate-prose "$REPO_ROOT"
chk_eq "P1 shipped prose is within the ratchet (rc)" 0 "$GRC"
chk_not_contains "P1 no breach line for the real tree" "BREACH" "$GOUT"
chk_not_contains "P1 no measurement error on the real tree" "GATE_ERROR" "$GOUT"
rows="$(printf '%s\n' "$PROSE_BASELINES" | grep -c '[^[:space:]]')"
weighed="$(printf '%s\n' "$GOUT" | grep -c '^within ')"
chk_eq "P1 every baseline row was weighed" "$rows" "$weighed"
# and the table covers the whole subtree — a row missing from the table must red, so the count
# of shipped md entries and the count of rows have to agree on the real tree. Same census as the
# gate: symlinks are entries (R2/B2 — this assertion shared the blind `-type f` census).
real_md="$(find "$REPO_ROOT/$PROSE_SUBTREE" \( -type f -o -type l \) -name '*.md' | grep -c '[^[:space:]]')"
chk_eq "P1 the table registers every shipped md in the subtree" "$real_md" "$rows"

# ── the T3 fixture: every registered path at exactly its baseline ───────────
mk_prosefix() { # $1 root  [$2 rel=lines | rel=- to omit]
  local root="$1" rel base ov ovrel ovval
  rm -rf "$root"
  while read -r rel base; do
    [ -z "$rel" ] && continue
    ovval=""
    for ov in "${@:2}"; do
      ovrel="${ov%%=*}"
      [ "$ovrel" = "$rel" ] && ovval="${ov#*=}"
    done
    [ "$ovval" = "-" ] && continue
    mk_lines "$root/$rel" "${ovval:-$base}"
  done <<EOF
$PROSE_BASELINES
EOF
}

mk_prosefix "$SANDBOX/exact"
run_gate --gate-prose "$SANDBOX/exact"
chk_eq "P2 every file exactly at baseline is green (rc)" 0 "$GRC"
chk_not_contains "P2 no breach at baseline" "BREACH" "$GOUT"

# ── P3 one line of growth reds ──────────────────────────────────────────────
mk_prosefix "$SANDBOX/grew" "$SK=$((SK_BASE + 1))"
run_gate --gate-prose "$SANDBOX/grew"
chk_eq "P3 one line over baseline reds (rc)" 1 "$GRC"
chk_contains "P3 breach names the file and the movement" \
  "BREACH $SK grew $SK_BASE->$((SK_BASE + 1))" "$GOUT"
chk_contains "P3 breach names the 下沉 obligation" "下沉" "$GOUT"
chk_contains "P3 breach names the commit-message obligation" "commit message" "$GOUT"

# ── P4 an unlocked new low reds; ordinary churn under the baseline does not ──
# The slack is per-file, so the fixtures DERIVE it from the same helper the gate uses. A literal
# here would both drift from the rule and hide the arm that matters: the small-file arm below,
# which a flat constant left permanently dead.
SK_SLACK="$(prose_slack "$SK_BASE")"
chk_eq "P4 SKILL.md's slack is max(5, baseline/10) floored" 13 "$SK_SLACK"

mk_prosefix "$SANDBOX/newlow" "$SK=$((SK_BASE - SK_SLACK - 1))"
run_gate --gate-prose "$SANDBOX/newlow"
chk_eq "P4 one line past SKILL.md's own slack reds (rc)" 1 "$GRC"
chk_contains "P4 breach tells the batch to lock the new low" "锁住新低" "$GOUT"
chk_contains "P4 breach reports the file's OWN slack, not a global one" \
  "dropped $SK_BASE->$((SK_BASE - SK_SLACK - 1)) (>$SK_SLACK under baseline)" "$GOUT"
chk_contains "P4 breach names the number to write down" \
  "把基线改成 $((SK_BASE - SK_SLACK - 1))" "$GOUT"

mk_prosefix "$SANDBOX/slack" "$SK=$((SK_BASE - SK_SLACK))"
run_gate --gate-prose "$SANDBOX/slack"
chk_eq "P4 the slack window itself stays green (rc)" 0 "$GRC"
chk_contains "P4 slack window is reported as within" \
  "within $SK $((SK_BASE - SK_SLACK))/$SK_BASE" "$GOUT"

# the arm that a flat 30 killed: the smallest shipped page. Its floor must be REACHABLE.
SMALL=skills/cto-orchestration/references/onboarding-checklist.md
SMALL_BASE="$(printf '%s\n' "$PROSE_BASELINES" | awk -v p="$SMALL" '$1 == p { print $2 }')"
SMALL_SLACK="$(prose_slack "$SMALL_BASE")"
chk_eq "P4 the smallest page gets the floor-of-5 slack" 5 "$SMALL_SLACK"
mk_prosefix "$SANDBOX/smalllow" "$SMALL=$((SMALL_BASE - SMALL_SLACK - 1))"
run_gate --gate-prose "$SANDBOX/smalllow"
chk_eq "P4 a 20-line page cut to 14 reds — the small-file arm is LIVE (rc)" 1 "$GRC"
chk_contains "P4 the small page's breach names its own slack and target" \
  "$SMALL dropped $SMALL_BASE->$((SMALL_BASE - SMALL_SLACK - 1)) (>$SMALL_SLACK under baseline) — 锁住新低：把基线改成 $((SMALL_BASE - SMALL_SLACK - 1))" "$GOUT"
mk_prosefix "$SANDBOX/smallslack" "$SMALL=$((SMALL_BASE - SMALL_SLACK))"
run_gate --gate-prose "$SANDBOX/smallslack"
chk_eq "P4 the small page's own slack window stays green (rc)" 0 "$GRC"

# no row may have an unreachable floor — that is exactly the dead arm this ruling removed
dead=0
while read -r r b; do
  [ -z "$r" ] && continue
  [ $(( b - $(prose_slack "$b") )) -le 0 ] && dead=$((dead + 1))
done <<EOF
$PROSE_BASELINES
EOF
chk_eq "P4 every registered row has a reachable lock-new-low floor" 0 "$dead"

# ── P5 an unregistered new page reds ────────────────────────────────────────
mk_prosefix "$SANDBOX/newmd"
mk_lines "$SANDBOX/newmd/skills/cto-orchestration/references/brand-new-doctrine.md" 77
run_gate --gate-prose "$SANDBOX/newmd"
chk_eq "P5 an unregistered shipped md reds (rc)" 1 "$GRC"
chk_contains "P5 breach names the unregistered file and its size" \
  "BREACH skills/cto-orchestration/references/brand-new-doctrine.md 未登记" "$GOUT"
chk_contains "P5 breach says register a baseline row in the same commit" "登记一行基线（77 行）" "$GOUT"
# a non-md file is NOT the prose ratchet's business — the weight ratchet owns code
mk_prosefix "$SANDBOX/newpy"
mk_lines "$SANDBOX/newpy/skills/cto-orchestration/references/agentctl/newtool.py" 500
run_gate --gate-prose "$SANDBOX/newpy"
chk_eq "P5 a new .py is not this ratchet's business (rc)" 0 "$GRC"

# ── P5b a *.md symlink is an ENTRY, not a hole (R2/B2) ───────────────────────
# The reviewer's repro: an unregistered `references/unregistered-link.md` symlink. `find -type f`
# never listed it, so all 17 rows reported within and the gate exited 0 — a whole shipped page
# outside the per-file table, invisible.
mk_prosefix "$SANDBOX/symnew"
mk_lines "$SANDBOX/symnew/outside-page.md" 88
ln -s "$SANDBOX/symnew/outside-page.md" \
  "$SANDBOX/symnew/skills/cto-orchestration/references/unregistered-link.md"
run_gate --gate-prose "$SANDBOX/symnew"
chk_eq "P5b an unregistered *.md symlink reds (rc)" 1 "$GRC"
chk_contains "P5b breach names the link and weighs it THROUGH the link" \
  "BREACH skills/cto-orchestration/references/unregistered-link.md 未登记 — 新增 shipped md 必须同 commit 登记一行基线（88 行）" "$GOUT"

# a REGISTERED row may legitimately be a link: the ratchet reads through it (`wc -l` follows), so
# what it judges is the target's line count against that row's baseline — within stays within...
mk_prosefix "$SANDBOX/symrow" "$SK=-"
mk_lines "$SANDBOX/symrow/linked-skill.md" "$SK_BASE"
ln -s "$SANDBOX/symrow/linked-skill.md" "$SANDBOX/symrow/$SK"
run_gate --gate-prose "$SANDBOX/symrow"
chk_eq "P5b a registered row that IS a link measures through it (rc)" 0 "$GRC"
chk_contains "P5b the linked row is weighed at its target's size" \
  "within $SK $SK_BASE/$SK_BASE" "$GOUT"

# ...and growth through the link still reds, so the link is no laundering path either
mk_prosefix "$SANDBOX/symgrew" "$SK=-"
mk_lines "$SANDBOX/symgrew/linked-skill.md" "$((SK_BASE + 1))"
ln -s "$SANDBOX/symgrew/linked-skill.md" "$SANDBOX/symgrew/$SK"
run_gate --gate-prose "$SANDBOX/symgrew"
chk_eq "P5b growth behind a link still reds (rc)" 1 "$GRC"
chk_contains "P5b the breach names the movement through the link" \
  "BREACH $SK grew $SK_BASE->$((SK_BASE + 1))" "$GOUT"

# a broken link is a MEASUREMENT failure, both as a registered row and as an unregistered entry
mk_prosefix "$SANDBOX/symbrokenrow" "$SK=-"
ln -s "$SANDBOX/symbrokenrow/no-such-target.md" "$SANDBOX/symbrokenrow/$SK"
run_gate --gate-prose "$SANDBOX/symbrokenrow"
chk_eq "P5b a registered row that is a DANGLING link exits GATE_ERROR (rc)" 2 "$GRC"
chk_contains "P5b the dangling registered row is named" "GATE_ERROR $SK" "$GOUT"

mk_prosefix "$SANDBOX/symbrokennew"
ln -s "$SANDBOX/symbrokennew/no-such-target.md" \
  "$SANDBOX/symbrokennew/skills/cto-orchestration/references/dangling-link.md"
run_gate --gate-prose "$SANDBOX/symbrokennew"
chk_eq "P5b an unregistered DANGLING *.md link exits GATE_ERROR, never green (rc)" 2 "$GRC"
chk_contains "P5b the dangling unregistered entry is named as unmeasurable" \
  "GATE_ERROR skills/cto-orchestration/references/dangling-link.md 未登记且量不到" "$GOUT"

# ── P6 a row the ratchet cannot measure is an ERROR, never a pass ───────────
mk_prosefix "$SANDBOX/gone" "$SK=-"
run_gate --gate-prose "$SANDBOX/gone"
chk_eq "P6 a registered-but-absent file exits GATE_ERROR (rc)" 2 "$GRC"
chk_contains "P6 the error names the unmeasurable file" "GATE_ERROR $SK" "$GOUT"

mk_prosefix "$SANDBOX/noread"
chmod 000 "$SANDBOX/noread/$SK"
run_gate --gate-prose "$SANDBOX/noread"
PR_UNREAD_RC=$GRC; PR_UNREAD_OUT=$GOUT
chmod 644 "$SANDBOX/noread/$SK"
chk_eq "P6 an unreadable registered file exits GATE_ERROR (rc)" 2 "$PR_UNREAD_RC"
chk_contains "P6 the unreadable file is named" "GATE_ERROR $SK" "$PR_UNREAD_OUT"

# ERROR outranks BREACH: a tree that is both unmeasurable and over baseline must not report the
# softer verdict, because the unmeasured file is the one nobody is watching.
mk_prosefix "$SANDBOX/both" "$SK=-" \
  "skills/cto-orchestration/README.md=999"
run_gate --gate-prose "$SANDBOX/both"
chk_eq "P6 ERROR outranks BREACH (rc)" 2 "$GRC"
chk_contains "P6 the breach is still reported alongside" \
  "BREACH skills/cto-orchestration/README.md grew" "$GOUT"

# ── P7 a broken gauge on the subtree itself is an explicit red ──────────────
mkdir -p "$SANDBOX/nosubtree"
run_gate --gate-prose "$SANDBOX/nosubtree"
chk_eq "P7 a missing prose subtree exits GATE_ERROR (rc)" 2 "$GRC"
chk_contains "P7 the error names the unmeasurable subtree" "GATE_ERROR $PROSE_SUBTREE" "$GOUT"

mkdir -p "$SANDBOX/emptysubtree/$PROSE_SUBTREE"
run_gate --gate-prose "$SANDBOX/emptysubtree"
chk_eq "P7 an empty md scan is a measurement error, not a pass (rc)" 2 "$GRC"
chk_contains "P7 the empty scan is named as a broken gauge" "0 个 *.md" "$GOUT"

mk_prosefix "$SANDBOX/unreadsub"
chmod 000 "$SANDBOX/unreadsub/$PROSE_SUBTREE"
run_gate --gate-prose "$SANDBOX/unreadsub"
PR_SUB_RC=$GRC; PR_SUB_OUT=$GOUT
chmod 755 "$SANDBOX/unreadsub/$PROSE_SUBTREE"
chk_eq "P7 an unreadable prose subtree exits GATE_ERROR (rc)" 2 "$PR_SUB_RC"
chk_contains "P7 the unreadable subtree is named" "GATE_ERROR $PROSE_SUBTREE" "$PR_SUB_OUT"

sandbox_clean
summary
