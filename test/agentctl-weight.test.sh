#!/usr/bin/env bash
# 生长棘轮 — the shipped agentctl files may not grow, and may not quietly shrink either.
#
# Field motive: the four shipped files are where every batch lands, and nothing watched their
# size. duplexctl.py went 916 bash lines → 3972 python lines across the salvage + supervised-lane
# batches with no gate at all; C10 in agentctl-capabilities.test.sh watches only the bash/python
# SHARE, so python growing alone is invisible to it. This file is the absolute half of that
# property: a batch that adds weight to a file must SEE the number move.
#
# The ratchet bites in BOTH directions, on purpose:
#   * actual > baseline           — growth. Either the weight does not belong there, or the
#                                   baseline moves and the commit message says why.
#   * actual < baseline - 50      — a new low was reached and never locked in. Deletion is the
#                                   whole point of this repo's weight work; an unlocked new low
#                                   means the next batch may silently re-spend it.
#   * file unreadable / absent    — ERROR, never pass. A ratchet that cannot measure is not a
#                                   green ratchet (a moved/renamed file used to be a silent pass
#                                   in every gate built this way).
#
# GOVERNANCE, NOT MACHINERY: this file judges NUMBERS only. Whether a baseline change is
# legitimate is a review question — the breach text names the obligation ("write in the commit
# message why the weight had to go into THIS file"), and no code here pretends to verify a
# rationale. A diff-aware rationale check was considered and refused: it buys a green surface
# the reviewer would then trust, and reviewing the reason is the reviewer's job.
set -u
cd "$(dirname "$0")"

# ── the baseline table ───────────────────────────────────────────────────────
# <repo-relative path> <wc -l baseline>. Measured at 483ceb8 (2026-08-20).
# UPDATING A ROW IS A GOVERNED ACT: change the number in the same commit that changes the file
# and state in the commit message why the weight had to go into that file. A batch that splits a
# file rewrites the shrinking row (the lock-new-low arm reds otherwise) and adds a row for the
# new module in that same commit.
# cto-guard-bash.py 831→1019 (2026-08-20, rules 12+13): the weight HAD to land here — a
# PreToolUse·Bash rule has no other home, and rule 12 was deliberately built on rule 10's
# extracted `_pipe_view`/`_pos_head` instead of a second shell approximation, which is why the
# growth is 12/13's own surface (bounded `--goal` extraction + its I/O failure taxonomy) plus
# the doctrine comments this file carries per rule, not duplicated parsing.
# 1019→1070 (same day, impl-review R2 收口): +51 for 11 adopted findings, ALL correctness, no
# new surface — gh global-flag window (B1), env value blanking (B2), timeout duration syntax
# (M1), escaped-separator parking + `#` comment strip (M2), agentctl basename boundary (M3),
# `--watch` boolean semantics (M4), `|&` reclassified from rule 1 to rule 12 (M5), glob/brace/
# tilde UNKNOWN (M7), command-position gate on the advisory (m1), post-read size verdict (m2).
# Each carries the reviewer's reproduction as a standing assertion; the shared parse face stayed
# shared — no second approximation was added to pay for any of them.
BASELINES='
skills/cto-orchestration/references/agentctl/duplexctl.py 3972
skills/cto-orchestration/references/agentctl/identity.py 1509
skills/cto-orchestration/references/agentctl/agentctl 588
skills/cto-orchestration/references/agentctl/cto-guard-bash.py 1070
'
LOCK_SLACK=50           # ordinary churn headroom below the baseline before a new low must be locked

GATE_OK=0
GATE_BREACH=1
GATE_ERROR=2

# The measurement itself, as its OWN invocation (`bash agentctl-weight.test.sh --gate <root>`):
# the self-tests below must exercise the same code path the real repo gets, not a re-implementation
# of it against synthesized fixtures.
gate() { # $1 root -> per-file lines on stdout; rc 0 within / 1 breach / 2 measurement error
  local root="$1" rc=$GATE_OK rel base actual floor
  while read -r rel base; do
    [ -z "$rel" ] && continue
    if [ ! -f "$root/$rel" ] || [ ! -r "$root/$rel" ]; then
      printf 'ERROR %s — the ratchet cannot measure a file it cannot read (moved? renamed? deleted?)\n' "$rel"
      rc=$GATE_ERROR
      continue
    fi
    actual="$(wc -l < "$root/$rel" | tr -d ' ')"
    floor=$(( base - LOCK_SLACK ))
    if [ "$actual" -gt "$base" ]; then
      printf 'BREACH %s grew %s->%s — 下沉/删掉这些行，或更新基线并在 commit message 写明为什么非进这个文件\n' \
        "$rel" "$base" "$actual"
      [ "$rc" -eq $GATE_ERROR ] || rc=$GATE_BREACH
    elif [ "$actual" -lt "$floor" ]; then
      printf 'BREACH %s dropped %s->%s (>%s under baseline) — 锁住新低：把基线改成 %s\n' \
        "$rel" "$base" "$actual" "$LOCK_SLACK" "$actual"
      [ "$rc" -eq $GATE_ERROR ] || rc=$GATE_BREACH
    else
      printf 'within %s %s/%s\n' "$rel" "$actual" "$base"
    fi
  done <<EOF
$BASELINES
EOF
  return $rc
}

if [ "${1:-}" = "--gate" ]; then
  gate "${2:?--gate needs a root}"
  exit $?
fi

. ./lib-testkit.sh

SELF="$(pwd)/$(basename "$0")"
run_gate() { # $1 root -> sets GOUT/GRC
  GOUT="$(bash "$SELF" --gate "$1" 2>&1)"; GRC=$?
}

# ── W1 the real repo is within the ratchet ───────────────────────────────────
run_gate "$REPO_ROOT"
chk_eq "W1 shipped files are within the ratchet (rc)" 0 "$GRC"
chk_not_contains "W1 no breach line for the real tree" "BREACH" "$GOUT"
chk_not_contains "W1 no unmeasurable file in the real tree" "ERROR" "$GOUT"
# every baselined row was actually WEIGHED — a table row that silently matched nothing would make
# this suite green by doing nothing at all.
rows="$(printf '%s\n' "$BASELINES" | grep -c '[^[:space:]]')"
weighed="$(printf '%s\n' "$GOUT" | grep -c '^within ')"
chk_eq "W1 every baseline row was weighed" "$rows" "$weighed"

# ── the mutation fixtures: same gate, synthesized trees ──────────────────────
# Each fixture carries EVERY baselined path so one arm is tested at a time and the other rows stay
# exactly at their baseline (a fixture that reds for two reasons proves neither).
mk_lines() { # $1 path  $2 count
  mkdir -p "$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 0; i < n; i++) print "x" }' > "$1"
}

mk_tree() { # $1 root  [$2 rel=lines | rel=- to omit]
  local root="$1" override_rel="" override_val="" rel base
  if [ -n "${2:-}" ]; then
    override_rel="${2%%=*}"; override_val="${2#*=}"
  fi
  while read -r rel base; do
    [ -z "$rel" ] && continue
    if [ "$rel" = "$override_rel" ]; then
      [ "$override_val" = "-" ] && continue
      mk_lines "$root/$rel" "$override_val"
    else
      mk_lines "$root/$rel" "$base"
    fi
  done <<EOF
$BASELINES
EOF
}

DX=skills/cto-orchestration/references/agentctl/duplexctl.py
sandbox_new

# ── W2 growth reds ───────────────────────────────────────────────────────────
mk_tree "$SANDBOX/grew" "$DX=3973"
run_gate "$SANDBOX/grew"
chk_eq "W2 one line over baseline reds (rc)" 1 "$GRC"
chk_contains "W2 breach names the file and the movement" "BREACH $DX grew 3972->3973" "$GOUT"
chk_contains "W2 breach names the obligation, not just the number" "commit message" "$GOUT"

# ── W3 an unlocked new low reds; ordinary churn under it does not ────────────
mk_tree "$SANDBOX/newlow" "$DX=3921"        # baseline - 51
run_gate "$SANDBOX/newlow"
chk_eq "W3 51 lines under baseline reds (rc)" 1 "$GRC"
chk_contains "W3 breach tells the batch to lock the new low" "锁住新低" "$GOUT"

mk_tree "$SANDBOX/slack" "$DX=3922"         # baseline - 50, the last tolerated value
run_gate "$SANDBOX/slack"
chk_eq "W3 the slack window itself stays green (rc)" 0 "$GRC"
chk_contains "W3 slack window is reported as within" "within $DX 3922/3972" "$GOUT"

# ── W4 exactly-at-baseline is the green case ─────────────────────────────────
mk_tree "$SANDBOX/exact"
run_gate "$SANDBOX/exact"
chk_eq "W4 every file exactly at baseline is green (rc)" 0 "$GRC"
chk_not_contains "W4 no breach at baseline" "BREACH" "$GOUT"

# ── W5 a file the ratchet cannot read is an ERROR, never a pass ─────────────
mk_tree "$SANDBOX/gone" "$DX=-"
run_gate "$SANDBOX/gone"
chk_eq "W5 a missing baselined file exits ERROR, not pass or breach (rc)" 2 "$GRC"
chk_contains "W5 error names the unmeasurable file" "ERROR $DX" "$GOUT"

mk_tree "$SANDBOX/noread"
chmod 000 "$SANDBOX/noread/$DX"
run_gate "$SANDBOX/noread"
UNREADABLE_RC=$GRC; UNREADABLE_OUT=$GOUT
chmod 644 "$SANDBOX/noread/$DX"
chk_eq "W5 an unreadable baselined file exits ERROR (rc)" 2 "$UNREADABLE_RC"
chk_contains "W5 unreadable file is named" "ERROR $DX" "$UNREADABLE_OUT"

# ERROR outranks BREACH: a tree that is both unmeasurable and over baseline must not report the
# softer verdict, because the unmeasured file is the one nobody is watching.
mk_tree "$SANDBOX/both" "$DX=-"
mk_lines "$SANDBOX/both/skills/cto-orchestration/references/agentctl/identity.py" 1600
run_gate "$SANDBOX/both"
chk_eq "W5 ERROR outranks BREACH (rc)" 2 "$GRC"
chk_contains "W5 the breach is still reported alongside" "grew 1509->1600" "$GOUT"

sandbox_clean
summary
