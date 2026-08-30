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
# 1070→1159 (2026-08-28, rules 14+15): the weight HAD to land here — both are PreToolUse·Bash
# rules and there is no second home for one; they were built ON rule (3)'s existing `agentctl
# start` match and rule (13)'s `_r13_segment`, so the growth is the cwd positional extractor
# (one shared helper, UNKNOWN-on-expansion like rule 13's `--goal`), one `git status --porcelain`
# probe, the two denial texts, and the doctrine comments this file carries per rule — no second
# shell approximation and no second git wrapper.
# cto-guard-edit.py 213 is a NEW ROW, not a split: `Edit|Write|MultiEdit` is a matcher this
# package had no script for at all (guard-hooks.json carried only Bash and Agent|Task). Its
# weight is the seat-liveness predicate the rule cannot exist without — run-dir census, the
# `_STOP_KEPT` trap (a stopped seat's surviving duplex.meta must not grant write rights), the
# tmux probe with undecidable-reads-as-live, and the three ALLOW+WARN degrade paths.
# 1159→1257 and 213→286 (2026-08-28, cold-review R2 fix round): 11 ship-blocking findings, ALL
# correctness on the four gates already shipped, no new rule and no new surface.
# cto-guard-bash +98: the weight is the PARSE FACE the two rules were missing. R1 judged them on
# rule (3)'s unanchored `re.search`, first match only — argv data (`echo agentctl start …`) was
# DENIED and a real later dispatch in the same command was never judged (§2.1/§2.2, both
# counter-probed). The replacement is one quote/escape-aware segmenter plus a head test built
# from rule (10)/(12)'s EXISTING `_ENV_ASSIGN`/`_WRAPPER` anchor applied to `_pipe_view` of each
# segment: still one shell approximation for the whole file, now reused three ways. The rest is
# `_git_porcelain`'s third return value (instrument-unavailable, §4.2) with its 149 B warn, and
# `shlex.quote` on the copyable recoveries (§5.1) — no second git wrapper appeared.
# cto-guard-edit +73: the rule now judges the WRITE TARGET's work tree instead of the caller's
# cwd (§1.1 — R1 passed a live seat writing another checkout and denied `/tmp/outside.py` from a
# git cwd). That costs `_worktree_root` + `_target_dir` + `_seat_holds` (root equality, which is
# also what closes the §1.4 false positive on a seat launched in a subdirectory), a readable-vs-
# listable census distinction in `_meta_cwd`/`live_seat_cwds` (§1.3), and the doctrine comments
# recording each counter-probe. The extension/test-dir predicate SHRANK (§1.2).
# 1257→1326 (2026-08-28, verify R3 fix round): 2 residual findings, both correctness on gates
# already shipped, no new rule and no new surface.
# cto-guard-bash +69: the two faces of an existing rule had to be made to AGREE. (a) §2.2/N1 —
# `_SEG_HEAD` decided a segment WAS a dispatch on `_pipe_view` (quoted env value = opaque ARG)
# while `_SEG_START` then located the command on the RAW segment, so a decoy inside a quoted env
# value won the first match and the guard judged the wrong seat. The fix is `_quote_blind`: the
# SAME data/opaque split `_pipe_view` already makes, rendered length-preserving so the match
# maps back onto raw offsets and the quoted-cwd extraction keeps working — no third parse face,
# no second shell approximation. (b) §4.3 — `_blocked_stands` replaces `os.path.exists`, which
# answered False both for "no BLOCKED.md" and for "could not stat it"; it is the twin of
# `_git_porcelain`'s instrument-unavailable return that §4.2 already bought, with its 151 B
# warn. The rest is the doctrine comments this file carries per counter-probe.
# duplexctl.py 3972→4317 and agentctl 589→594 (2026-08-29, steer 语义收敛 + STALLED-PROGRESS):
# +345 python / +5 bash, and the split is the point — every JUDGEMENT landed in python while the
# shell only grew the flag surface (`--interrupt`, the `--now` removal refusal, one supervisor env
# passthrough), so C10's share ratchet FELL 129→121/1000.
# The python weight HAD to land here and is three named surfaces, not scattered churn:
#  * ASAP steer routing (~90 lines): per-engine `*_turn_active` + `steer_delivery` + the
#    alternation route split. It replaced three verbs with one, so the three-cell capability rows
#    shrank to two and `_cap`'s `fallback` concept was DELETED — the router reads the live turn
#    state instead of an operator flag. No second frame builder appeared: build_frame took a
#    `route` argument and omp's get_state round trip was EXTRACTED (`omp_get_state`) so the
#    projector and the router share one probe rather than growing a second one.
#  * STALLED-PROGRESS (~150 lines): a new typed state needs its probe (git HEAD + porcelain +
#    dirty-set/deliverable/BLOCKED mtimes), its persisted window, and its 宁钝勿敏 unjudgeable
#    path. It could not reuse `stream_stalled`: that probe answers "the stream stopped" and is
#    blind by construction to a streaming engine doing nothing, which is the field failure
#    (2.5h unnoticed). The window state is a sidecar because classify is one-shot — a window
#    cannot accumulate in memory across the processes that make it up.
#  * steer delivery log (~60 lines): `queued=N` is the engine's whole answer, so the only place
#    that CAN record what the queue holds is the single writer on the lane. It rides the existing
#    commit point (same flock, same best-effort rule as the offset journal), adds no new writer.
# agentctl's +5 is flag parsing and one env name in the supervisor pane command — the thin-entry
# contract holds: nothing in bash reads a verdict, parses a frame or picks a route.
# duplexctl.py 4317→4502 (2026-08-29, R1 cold-review fixes + owner's DELIVERED-NEXT-TURN ruling):
# +185 python, ZERO bash — the thin-entry contract held through the whole batch (`agentctl`
# stayed at 594: `cmd_steer` already `exec`s duplexctl, so a NEW TYPED EXIT CODE cost the shell
# nothing at all). Five named surfaces, each the minimum the finding admits:
#  * strict gauge reading (~35 lines): `json_bool` + `omp_stream_flags` + `codex_frames`. The
#    router selected on Python TRUTHINESS, so a JSON string `"false"` bought the mid-turn route
#    and a `0` bought a fabricated idle. Only `true`/`false` may decide, and the projector reads
#    the SAME helper — one strictness, not two. `codex_frames` had to be new: the old reader
#    folded an unreadable/corrupt stream into an empty frame list, which is a measurement.
#  * DELIVERED-NEXT-TURN (~40 lines): one exit constant, one TYPED_STATES row, `steer_delivery`
#    returning a reason word, and `delivered_rc` at the three delivery success points. It
#    REPLACED a prose note, and the capability note SHRANK: the fact now rides the exit code a
#    wrapper cannot drop instead of a sentence on stdout it routinely did.
#  * porcelain -z parsing (~20 lines): `--untracked-files=all` needs a NUL-record parser,
#    because the default folded nested untracked work into `?? dir/` and fired a false 14. The
#    rename/copy origin record must be consumed, which is exactly why a splitlines() one-liner
#    could not stay.
#  * judgeable vs observed_change_at (~35 lines): the window sidecar gained `moved` + `judgeable`
#    so an unjudgeable probe forbids the verdict WITHOUT publishing the gauge's own failure clock
#    as `last_progress_at` or as `progress=changed`. Two facts cannot share one field.
#  * queue-route filter (~30 lines): `queue_routes` on the steer cell + `print_steer_queue`
#    filtering by it. The depth indexes QUEUED deliveries, and the log holds every delivery, so
#    a mid-turn steer was listed as a queued item and hid the real one. The declaration lives in
#    the capability table because only the cell knows which half is a queue (codex has none).
# The remaining ~25 lines are the doctrine comments this file requires per counter-probe.
# duplexctl.py 4502→4545 (2026-08-29, verify R2 fix round): +43 python, ZERO bash — the
# thin-entry contract held again (`agentctl` stayed at 594; none of the three findings is a
# flag). Three named surfaces, each the minimum the finding admits:
#  * bounded-scan overflow (~18 lines): `_porcelain_paths` now returns `(paths, overflowed)`
#    and `progress_fingerprint` returns `(fp, why)`. Keeping the first 500 dirty paths was a
#    mtime measured over a PREFIX published as if it covered the tree — with 501 dirty files,
#    work confined to the 501st fired a false 14. The scan stays bounded; the READING is
#    refused, and the refusal reuses the unjudgeable path that already existed rather than
#    growing a second verdict. The `why` string replaced a hardcoded sentence, so the
#    undecidable admission now NAMES which of the four probes failed at no extra branch.
#  * unattributed recovery baseline (~10 lines): one `recovered` test in `progress_verdict`
#    plus the `moved`-is-0 reading in `cmd_sense_loop`'s tail word. The first judgeable read
#    after a broken gauge rebuilt the window AND credited itself as movement, so
#    `None → SAME → SAME` reported `progress=changed`. No new field: `moved` already carried
#    exactly this fact and was simply being overwritten.
#  * interrupt handshake on a broken gauge (~15 lines): `codex_active_turn` returns the
#    diagnosis beside the id, and `codex_route_replace` sends `turn/interrupt` whenever the
#    turn state is not a decided idle. Folding "no measurement" into "no turn" skipped the
#    handshake, rotated the attempt, and then sent a `turn/start` the still-running turn
#    rejects. The engine's own refusal is the idle answer, so the branch reuses the existing
#    error path instead of adding a second probe.
# duplexctl.py 4545→4549 (2026-08-29, verify R4): +4 python, ZERO bash (`agentctl` stayed at
# 594 — not a flag). ONE surface, and it is a REVERSAL of R3's last surface above, not a new
# one: `codex_route_replace` no longer sends a threadId-only `turn/interrupt` when the turn
# state is undecidable. codex `TurnInterruptParams` makes `turnId` REQUIRED (app-server
# v0.144.5/v0.147.0), so that frame is malformed on the wire — R3 bought an engine refusal
# it then showed the operator as the engine's own verdict, hiding the operator's real problem
# (their own events gauge). The undecidable case now refuses BEFORE the wire with the gauge
# named, so the +4 is that refusal sentence; the handshake branch simultaneously LOST its
# conditional `turnId` and its conditional terminal-id fence, because a non-empty `active`
# now implies a readable gauge. A typed refusal costing 4 lines replaced a round trip that
# could only ever be rejected.
# duplexctl.py 4549→4855 (2026-08-30, STALLED-PROGRESS 进展源并集 + typed 子原因闭集): +306
# python, ZERO bash (`agentctl` stayed at 594 — `states` already `exec`s duplexctl, so a second
# published vocabulary cost the shell nothing). The weight HAD to land here: both surfaces are
# the classify path's own truth, and a second module would have to hold a copy of the progress
# window, the per-engine frame vocabulary and the exit-code table to say anything at all.
# What the lines buy, and why none of it could be cut instead:
#  * two new progress sources (~95 lines): the engine's own tool/command frame COUNT per engine
#    (built on the vocabulary `claude_inflight`/`codex_inflight` already declare — counted
#    instead of paired, because a tool that opened and closed between polls left no unmatched
#    pair) and one `pgrep -g <pane_pid>` over the pane's process group. The old single-source
#    verdict fired on a seat that really worked and did not write (long suite / docker build /
#    reading code), which is the false positive that retired a downstream seat's own audit
#    script at hits=0 false=2.
#  * the union verdict itself (~65 lines net): three buckets (judged / blind gauge / structurally
#    absent), a judged QUORUM, and per-source movement crediting. It REPLACED the single-probe
#    branch chain, so the arithmetic is smaller than it looks — the old three-branch body is gone.
#  * the SUB_REASONS closed set + `sub_reason()` + the import-time integrity check (~90 lines):
#    the words an orchestrator branches on (`reason=unknown-source`, `progress=unchanged`) were
#    bare literals at their print sites. `STEER_NEXT_TURN_REASONS` and the WATCH-TIMEOUT tail
#    words are now DERIVED from that table, so this is one table replacing three scattered
#    literal sites, not a new parallel vocabulary.
#  * the published document (~35 lines): `states` grew the `subReasons` block (json + human) and
#    the schemaVersion bump. Publishing it in a prose file was the alternative and is exactly
#    what this repo's states verb exists to forbid.
#  * doctrine comments the file carries per decision (~20 lines): the quorum's two calibrations,
#    the [n/a] vs [unknown] distinction, and why omp's tools source is permanently [n/a].
# duplexctl.py 4855→4998 (2026-08-30, R1 cold-review fixes on that same batch): +143 python,
# ZERO bash (`agentctl` stayed at 594 — not one finding is a flag). SIX named surfaces, each the
# minimum the finding admits, and two of them REMOVED cost rather than adding it:
#  * the quorum floor (~10 lines, mostly doctrine): `PROGRESS_QUORUM` 2→1. A fixed 2 turned the
#    contract's own named cell (`repo=unknown + tools=silent + pane=n/a`) into permanent RUNNING
#    — the stall was never reported at all (Q1). The arithmetic did not grow; the comment
#    carrying WHY the floor is one, and why zero still withholds, did.
#  * the landing frame (~35 lines): `complete_frames_integrity` returns a third fact (a
#    non-empty trailing fragment), `events_tail_mark` bounds a tail read, and the union credits
#    a CHANGED fragment as movement. A `tool_use` caught mid-write was read as a settled counter
#    and published terminal 14/tools-silent while the tool was arriving (T1). Two facts (unknown
#    vs arriving) cannot share one flag, and the arriving half is what keeps a landing frame from
#    firing the state at all.
#  * the shared probe budget (~35 lines): `ProbeBudget` + `progress_budget()` + both process
#    probes taking a slice. Three git reads at 20s plus `pgrep` and `ps` summed to 70s of local
#    timeout under a 30s classify watchdog, so a slow gauge published ENGINE-SILENT — the control
#    plane accusing itself for a measurement problem (P3). Derived from `status_timeout()`, so it
#    is not a second knob.
#  * the pane identity fence (~25 lines): `pane_identity_drift`. start persists `pane_lstart`
#    precisely because a pgid is reusable, and the source validated only that the pgid was
#    numeric — an unrelated reused group could vote silent and refresh the clock forever (P2).
#    It reuses `reap_tree`'s existing rule (a leader ps cannot see is not drift), not a new one.
#  * the branching disposition (~13 lines): the exit-14 line picks its instruction from the
#    published word. "Read the events tail, then steer" is the wrong move for an unreadable
#    gauge, and shipping one sentence for both contradicted this repo's own published table (D1).
#  * one read per classify (~10 lines net): `_events_snapshot` memoises the stream read on
#    (size, mtime_ns) and both `complete_frames_integrity` and `events_tail_mark` became views
#    over it. The batch had TWO full reads per classify (stall probe + tools counter) plus a
#    tail seek; the stall probe pairs lifecycle frames across the WHOLE stream, so an
#    offset-incremental reader would change ITS meaning, not just its cost — the memo removes
#    the duplicate read at zero semantic cost (R1 measurement).
#  The rest is the P1 wording correction — this source reports what it OBSERVED at a sampling
#  point, never what happened between two of them.
# duplexctl.py 4998→5009 (2026-08-30, R2 cold-review fixes on the same batch): +11 python, ZERO
# bash. Both surfaces are wording or arithmetic on lines that already existed:
#  * the probe budget's real bound (~10 lines): `PROGRESS_BUDGET_HEADROOM`/`_FLOOR` plus the
#    `min(share, deadline - 1s)` form and the docstring carrying WHY. The share alone left
#    AGENT_WATCH_STATUS_TIMEOUT=1 a budget equal to the whole classify watchdog, i.e. the
#    ENGINE-SILENT-for-a-slow-gauge race the budget exists to remove, still live for two
#    supported knob values (R2 P3). A knob-value guard cannot be a fixture: it is arithmetic.
#  * one line of published wording (P1): the STALLED-PROGRESS state and its two silence
#    sub-reasons now say what was OBSERVED AT SAMPLING POINTS, and say outright that a source
#    which moved and returned between two samples is invisible to these instruments. The old
#    text asserted no source moved for the whole window — more than the gauge can prove.
# duplexctl.py 5009→3634 and watchctl.py 1428 is a NEW ROW (2026-08-30, watch/supervisor 块平移):
# a SPLIT, not deletion and not growth — the shrinking row is rewritten and the new module gets a
# row in the same commit, exactly as the governance note above requires. 1385 contiguous lines
# (`cmd_classify` … `cmd_inventory`, 70 top-level items) moved with the function bodies verbatim;
# the only edited lines are the import face and `_CTL`, which still resolves to duplexctl.py
# because that file remains the sole argv front door. The arithmetic, both directions: duplexctl
# 5009 − 1387 (the 1385-line span plus the two blank separators that belonged to it) + 15 (the
# self-alias that lets `from duplexctl import …` bind to the RUNNING module, the `import watchctl`
# inside main(), and their doctrine) − 3 (`math`/`shutil`/`stat`: the move orphaned them, ruff
# F401 caught it) = 3634; watchctl 1385 moved + 43 header/import face = 1428. Net product lines
# +53, and every one of them is import wiring — no judgement was added anywhere.
BASELINES='
skills/cto-orchestration/references/agentctl/duplexctl.py 3634
skills/cto-orchestration/references/agentctl/watchctl.py 1428
skills/cto-orchestration/references/agentctl/identity.py 1509
skills/cto-orchestration/references/agentctl/agentctl 594
skills/cto-orchestration/references/agentctl/cto-guard-bash.py 1326
skills/cto-orchestration/references/agentctl/cto-guard-edit.py 286
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
# derived, never a second copy of the number: hardcoded fixture literals meant every baseline
# move reds four self-tests that are not about that move at all (2026-08-29)
DX_BASE="$(printf '%s\n' "$BASELINES" | awk -v p="$DX" '$1 == p { print $2 }')"
chk_eq "W2 the fixtures read the baseline they are testing against" 1 \
  "$([ -n "$DX_BASE" ] && echo 1 || echo 0)"
sandbox_new

# ── W2 growth reds ───────────────────────────────────────────────────────────
mk_tree "$SANDBOX/grew" "$DX=$((DX_BASE + 1))"
run_gate "$SANDBOX/grew"
chk_eq "W2 one line over baseline reds (rc)" 1 "$GRC"
chk_contains "W2 breach names the file and the movement" \
  "BREACH $DX grew $DX_BASE->$((DX_BASE + 1))" "$GOUT"
chk_contains "W2 breach names the obligation, not just the number" "commit message" "$GOUT"

# ── W3 an unlocked new low reds; ordinary churn under it does not ────────────
mk_tree "$SANDBOX/newlow" "$DX=$((DX_BASE - LOCK_SLACK - 1))"
run_gate "$SANDBOX/newlow"
chk_eq "W3 51 lines under baseline reds (rc)" 1 "$GRC"
chk_contains "W3 breach tells the batch to lock the new low" "锁住新低" "$GOUT"

# baseline - LOCK_SLACK, the last tolerated value
mk_tree "$SANDBOX/slack" "$DX=$((DX_BASE - LOCK_SLACK))"
run_gate "$SANDBOX/slack"
chk_eq "W3 the slack window itself stays green (rc)" 0 "$GRC"
chk_contains "W3 slack window is reported as within" \
  "within $DX $((DX_BASE - LOCK_SLACK))/$DX_BASE" "$GOUT"

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
