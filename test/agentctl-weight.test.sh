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
# agentctl 594→599 (2026-09-01, M09 Linux 回归 hotfix): +5 bash, ZERO python. One line of
# behaviour (`run_child` spawns the interpreter directly instead of backgrounding the `ctl`
# FUNCTION, so `$!` is the reader the TERM trap must kill) plus the four-line doctrine comment
# that keeps it from being "cleaned up" back into `ctl "$@" &`. The weight HAD to land here:
# both the trap that kills `$CHILD` and the launch that names it are lines of this entry script,
# and the failure they caused is invisible by inspection — a reaped waiter left a live reader
# that consumed the round's conclusion, so the next watch re-derived it under a second
# supervisor (CI M09 swSILENT expected[1] got[2]). The paired oracle is a test, not prose:
# M01b in agentctl-supervised-watch.test.sh censuses processes after the TERM.
# watchctl.py 1428→1508, duplexctl.py 3634→3654, agentctl 599→620 (2026-09-01, watch 默认 follow):
# +80/+20 python and +21 bash. The bash growth is the one number to justify, and it is a LOOP,
# not a decision: `cmd_watch` now re-arms while a waiter verb tells it to (two opaque internal
# codes, exactly like the pre-existing 13) and re-captures the two arm-time snapshots per
# episode. Every judgement stayed in python — whether a round's outcome ends the waiter, and the
# ceiling on automatic re-arms (`--follow-max`, AGENT_WATCH_FOLLOW_MAX, read where every other
# watch bound is read) — so C10's measured share moved 66→68/1000, still under its 76 ratchet.
# The python weight is three named surfaces:
#  * the follow decision (~35 lines incl. doctrine): `_follow_or_exit` + `_watch_mark` (the
#    `EXIT=<n>` half of a verdict, now printable without dying on it) + the FOLLOW_* codes. The
#    action/non-action split is the whole contract and it is stated ONCE, at one call site each
#    in `cmd_watch_arm_read` and `cmd_watch_wait`.
#  * round-rotation transparency (~15): `_round_now` + the test at the top of the wait loop. It
#    is a second reader of the meta round on purpose — `_session_round` normalizes an absent
#    meta to 0 for the PUBLISH fence, and a loop that read a vanished session as "round 0"
#    would call SESSION-GONE a rotation.
#  * `--follow` on the canonical read (~10 python, 4 of them argparse help): the `dead` liveness
#    fact leaves as its own code so the continuation decision reads an exit status instead of
#    sniffing the human line for the word the same function printed. The printed verdict, and
#    every other caller's 12, are byte-identical — asserted in FL3.
# cto-guard-bash.py 1326→1472 (2026-09-01, 效率强制层: rules 16+17): +146, and the weight HAD to
# land here for the same reason every other rule did — both are PreToolUse·Bash judgements and a
# hook matcher has no second home. Neither grew a parse face: (17) reads `_cmd_segments` +
# `_pipe_view` + the `_ENV_ASSIGN`/`_WRAPPER` head (14)/(15) already built; (16) reuses the same
# three and adds the only thing a counter cannot borrow — a
# day-stamped, uid-scoped tally file with its read/write failure taxonomy (silent on a meter that
# cannot answer, floor-and-say-so on one that cannot persist), which is ~45 of the 146. The rest
# is the two message bodies and the per-rule doctrine comments this file carries, including both
# kill criteria (`g16-babysit-counter` / `g17-review-budget`) the retro GATE-AUDIT reads.
# 1472→1522 (2026-09-01, F1/F2 cold-review fix round): +50, TWO findings, both correctness on
# rules already shipped, no new rule and no new surface.
# F1 (SHIP-BLOCKING) is +38: (17) judged flags by membership in `view.split()`, so a VALUED
# option's ARGUMENT was read as a flag — one root cause facing both ways (`--goal '--review'`
# DENIED a legal dispatch; `--goal '--max-rounds' --review` and the `--resume-thread` twin
# bought their way out of the gate with a filename). The fix is `_start_option_flags`, which
# mirrors `agentctl start`'s own argv arity (agentctl:183-198) — a six-name set and one token
# walk, NOT a second parser: the segmentation, the view and the command-position head are still
# the shared ones, and this walk starts from the head match's own end offset.
# F2 is +12: the corrupt-ledger floor flag is now PERSISTED in the day's record
# (`{"floor":…,"n":{…}}`), because the process that reset a corrupt tally knew the history was
# gone and the next one did not — it published `4 times today` as an exact reading. Sticky for
# the day, so any later process keeps admitting the floor; the doctrine for why an unrecognized
# shape must reset AND raise the flag is most of those 12 lines.
# 1522→1544 (2026-09-01, R2 verify residual): +22, ONE finding, the F1 root cause one layer
# down — `_pipe_view` strips backslashes, so the single argv word `--goal x\ --max-rounds\ y`
# reached the arity walk as three and the `--max-rounds` inside the VALUE was promoted to a
# budget flag (the quoted spelling of the same value was already correct, which is what made
# the two spellings disagree about one word). `_arity_view` is 3 lines of code: `_pipe_view`
# applied to a segment whose escaped whitespace has been parked into a sentinel, the same trick
# `_ESCAPED` already plays for escaped separators — no new parse face, and rule (17) is the only
# consumer, so no other rule's view moves. The other ~19 lines are the doctrine this file
# carries per counter-probe, most of it the BACKSLASH PARITY argument: only an odd run escapes
# the space, so `x\\ --max-rounds 2` must keep its real option pair.
# 1544→1753 (2026-09-01, 下游 guard 三件批: rules 18+19 + rule (8) gauge calibration): +209, and
# the weight HAD to land here for the same reason every other rule did — all three are
# PreToolUse·Bash judgements and a hook matcher has no second home.
# REAL COMPOSITION, measured, not asserted (review F8/finding 8 corrected an earlier claim here
# that the growth was "mostly doctrine"): net +209 = 78 comment + 20 blank + 111 code/string. So
# it is MOSTLY CODE AND MESSAGE TEXT, with doctrine a bit over a third. The `git diff -U0` awk
# that produced those four numbers is in the review record; re-run it before editing this row.
# Where the 111 went: `_git_argv` + `_rewrites_history` + `_rewrite_in_chain` (the (18) walk and
# its step count), `_registered_repos` + `_cd_lands_in` + `_cwd_drift` (the (19) register and
# scan), `_umbrella_near` moved in from rule (8)'s frame, `_fold8`/`_unq8`, the `quoted_only`
# parameter and second stripper pass, two message bodies (602 B + 313 B), and the header index.
# NO NEW PARSE FACE, which is the claim that actually matters and is separate from line counts:
#  * (18) reads `_cmd_segments` + `_pipe_view` + one `_ENV_ASSIGN`/`_WRAPPER` head, all already
#    here, plus `_git_argv` — a token walk mirroring git's OWN option arity, the same discipline
#    rule (17) had to learn one batch earlier (a valued option's argument is DATA: `git -c
#    alias.x=rebase status` is not a rebase, `git commit -m '--amend'` is not an amend).
#  * (19) reads the SAME `_umbrella_near` scan rule (8) 已有 — the function moved from rule (8)'s
#    frame to module level unchanged except for returning the ROOT instead of a bool, so the repo
#    register is one `listdir` of a directory rule (8) already located. No subprocess, no git.
#  * the (8) fix is a PARAMETER on the heredoc stripper that was already here (`quoted_only`) plus
#    two 2-line view helpers (`_fold8`/`_unq8`) that replaced three copies of the same two
#    substitutions — the rule-8 face got a second view, not a second parser, and `_exec_face`
#    got shorter.
# The doctrine third is: both kill criteria (`g18-rewrite-single-step` / `g19-cwd-drift`) the
# retro GATE-AUDIT reads, (18)'s exemption argument (denying `cd /abs && git rebase` would put it
# in a fight with rule (8), whose fix line hands out that spelling) with its accepted false
# positive, (19)'s WARN-only ruling and its unmeasurable-register contract, and the (8)
# calibration's field evidence (false+2) plus the blind spot it accepts by construction.
# 1753→1805 (2026-09-01, 评审 FIX-FIRST 修复轮): +52 = 33 comment + 2 blank + 17 code, three
# findings' worth of correctness on rules that had just shipped — no new rule, no new surface.
# F1 (SHIP-BLOCKING, findings 1+4) is the largest share: rule (8)'s interpreter face is now built
# at COMMAND POSITION on the shared `_WRAP8` chain. One root cause faced both ways — the pipe RHS
# admitted only a BARE interpreter, so `cat <<EOF | env sh -` went silent at exit 0 where the
# baseline denied it (under-fire regression), while the same missing anchor read the FILENAME in
# `cat > /tmp/bash <<EOF` as an interpreter and re-scanned a document. Most of those lines are the
# argument for why the two halves must be fixed in one pass.
# F2 (SHIP-BLOCKING, findings 2+6+7) is ~8 code lines: four names left `_COMMIT_VALUED` because
# `-S[<keyid>]`/`-u[<mode>]` are OPTIONAL-ATTACHED and were swallowing the `--amend` behind them;
# a `--` terminator arm (everything after it is pathspec); and the cd anchor now asks the RAW text
# whether the path is absolute, because `_pipe_view` blanks a quoted span with a space to `ARG`
# and destroyed the leading `/` rule (8) preserves — two spellings of one path, one verdict.
# F5 (MAJOR, finding 5) is `_cd_lands_in`: the register carries repo ROOTS and the cd target is
# resolved against them, because a NAME is not a LOCATION — `cd /somewhere/otherrepo/not-a-repo`
# was announcing a repo the command was never in.
# 1805→1846 (2026-09-01, R2 verify 残余 R2-1 的 R3 窄修): +41 = 14 comment + 2 blank + 25 code,
# ONE finding, the F1 root cause one layer down — and the same fault class this batch exists to
# remove. F1 anchored rule (8)'s interpreter at command position but still asked the question of
# the RAW text, so a documentation heredoc that SHOWS a nested shell heredoc (`cat > brief.md
# <<OUTER` / `bash <<INNER` / …) had its inner EXAMPLE read as a real interpreter feed. A
# line-start `bash <<TAG` is the ordinary way a brief quotes a command; denying it is the
# "heredoc body judged as commands" false positive again, one level in.
# The 25 code lines are NOT a new parse face: the heredoc walk that was already here was split
# into `_heredoc_scan` (structure: [(command-line, [(body, closer)])], body lines dropped BY
# CONSTRUCTION) with `_strip_heredocs` now a 7-line projection of it — one walk, two consumers,
# byte-identical string output. Detection then runs per command LINE of that structure, and only a
# line that fires rescans the bodies THAT line opens. That last part fixed a SECOND false positive
# of the same class for free (the old whole-text rescan convicted an innocent feed whenever any
# document body mentioned git — 587651c denied it, probe rc=2 where 0 was owed), which is why the
# arm asserting it is paired with the R2-1 repro.
# cto-guard-bash.py 1846→2298 (2026-09-02, guard ⑧ 收窄 + 新规则 ⑳ + R1 评审 F1 修复): +452, and
# the weight HAD to land here for the same reason every other rule's did — both are
# PreToolUse·Bash judgements and a hook matcher has no second home. What the lines buy:
#  * rule (8)'s narrowing (~60): `_git_top` (a no-subprocess walk to the nearest `.git`, because
#    this runs on EVERY umbrella-scoped git/gh command and `git rev-parse` measured 12.5 ms) +
#    `_cwd_is_session_root` + the `transcript_path`/slug doctrine. `_umbrella_near` is BYTE-EQUAL
#    — the scan was not touched, a second conjunct was added to the gate. The DENY text SHRANK
#    (430→429 B) while changing what it claims.
#  * rule (20)'s judgement (~110): `_write_targets` + `_r20_judge` + `_sed_in_place` +
#    `_positionals` + `_cmd_head`, one DENY (752 B) and two WARNs (313/196 B). Seat attribution
#    is IMPORTED from cto-guard-edit.py rather than copied (`_edit_guard`, 14 lines including its
#    load-failure degrade), so the census, the liveness rules and the source face stayed single-
#    source: without that import this row would have grown by another ~120 and the two channels
#    could then disagree about who owns a work tree.
#  * rule (20)'s own execution face (~90): `_write_face` / `_write_segments` / `_seg_tokens` /
#    `_unquote_word`. This is the one place a NEW face was unavoidable and R1 F1 is the proof:
#    `_pipe_view` blanks a multi-word quoted span to `ARG` and strips backslashes, so
#    `> "/a b/x.py"` and `> /a\ b/y.py` — two ordinary spellings of one real file — reached the
#    rule with no target at all (both counter-probed at rc=0). A gate that cannot read a
#    space-bearing filename is not a gate. The face is length-preserving so operators are found
#    on the blinded text and the path is read from the ORIGINAL bytes — the same two-read idiom
#    `_quote_blind` already established for rules (14)/(17), not a third parser.
#  * the rest (~190) is comment: the two kill criteria the retro GATE-AUDIT reads
#    (`g20-bash-direct-write` plus rule (8)'s recalibration evidence), the CLOSED SET with its
#    accepted-uncovered list (`cp` / `mv` / `dd of=` / `git apply` / interpreter writes …), and
#    the per-decision counter-probe record this file carries per rule. The uncovered list is
#    load-bearing prose: a gate that implied coverage it does not have would be worse than the
#    gap, and README §强制层 carries the reader-facing twin.
# cto-guard-bash.py 2298→2319 (2026-09-02, R2 封闭性复审修复轮): +21, four findings, ALL
# correctness on the execution face the previous row bought — no new rule, no new surface, and
# the shared faces (`_pipe_view` / `_quote_blind` / `_cmd_segments` / `_heredoc_scan` /
# `_umbrella_near`) are byte-equal, verified per function. Where the 21 went:
#  * the comment sentinel (~9, R2-1): a comment got its OWN sentinel and `_seg_tokens` now drops
#    it like whitespace. Sharing the quote blind left it a same-length WORD that was read back
#    off the raw text, so `tee #comment.py` was DENIED for a file no shell opens.
#  * duplication arity (~5, R2-2): `_R20_DUP` + `after_op = not _R20_DUP.fullmatch(op)`. A
#    duplication's operand is INSIDE the operator, so consuming a word too swallowed the real
#    argv behind it (`tee 2>&1 <repo>/x.py` walked). Tightening the fd side to `\d+|-` also made
#    bash's `>&word` spelling fall through to the plain `>` arm, where the word IS the target.
#  * shell word recovery (~7, R2-3): the dquote scan now decides expansion on the ORIGINAL bytes
#    (`"\$literal.py"` is a filename with a dollar, not an expansion), and the line-continuation
#    fold moved AHEAD of word splitting with rule (8)'s own backslash PARITY.
# The remaining lines are the per-finding counter-probe comments this file carries.
# cto-guard-bash.py 2319→2373 (2026-09-02, 新规则 (21)): +54, and the weight is where a BYTE BAN
# has to be argued. The rule itself is 3 lines of matcher (`_R21_HEAD` / `_R21_SUBST`) plus a
# 9-line branch carrying the DENY text: a command-position `agentctl steer … -m` whose body
# (from `-m` to the END of the command text) holds a backtick or `$(` is denied, because the
# SHELL expands it before agentctl is exec'd — 2026-08-30 a `gh api …` example inside a steer
# body ran against the real repo and the `>` in the same text truncated the message, leaving
# agentctl a parse error as its only report. No new parse face: `_pos_head` / `_AGENTCTL` are the
# shared command-position anchor, and the judged view is `raw`, the quoted-heredoc-stripped face
# every general rule already reads.
# The other ~40 lines are comment, and they are the load-bearing half: this rule DELIBERATELY
# does not distinguish single quotes, double quotes or `\$(`, so two accepted false positives
# (`-m 'plain `ls` text'`, `-m "cost \$(x)"`) and one accepted over-reach (a command chained
# after a clean `-m` is read as body) are stated with their oracle names, together with the
# accepted FN a mention-is-not-a-command anchor buys. A ban whose边界 is not written down is a
# rule the next batch narrows by accident; the kill criterion (hits=0 for a year) is recorded
# where the retro GATE-AUDIT reads it.
# cto-guard-bash.py 2373→2412 (2026-09-02, README 产品面瘦身): +39, ZERO behaviour change — the
# weight is a承诺面 MOVING, not growing. Owner ruling 2026-09-02: README §cwd 锚定 and the ⑳
# entry owe the reader 何时拦 / 怎么办 / 为什么我碰不到, and 边界目录 is not one of those, so the
# enumerations that page carried (-21 lines there, see skill-face) now sit next to the code that
# implements them: rule (8)'s fail-open scope gate — including the CORRECTION of a comment that
# claimed an unreadable cwd stays denied when `_umbrella_near` returns None and the rule never
# evaluates — plus its nested-repo / symlink-realpath / slug-collision boundaries with the
# `r8-*` oracles that pin each; and rule (20)'s closed set spelled out per channel (redirect
# family, EVERY `tee` path incl. `-a` / `--`, all five in-place `sed` spellings), its
# accepted-uncovered list, the quoted/escaped space-bearing path recovery, the
# comment-heredoc-opener gap, and the opaque-target / missing-target verdict directions.
# This is the cheaper place for those bytes: a承诺面 stated twice drifts, and the README rows
# this replaces included two corrections of exactly that drift.
# cto-guard-bash.py 2412→2423 (2026-09-02, R1 评审 blocking 修复): +11, one CORRECTNESS fix on
# rule (21) and the argument for it. The matcher's pre-`-m` scan ran past `;` / `&&` / `||` / `|`,
# so a `steer` carrying only `-f` borrowed the NEXT command's `-m` and the rule denied with a
# message naming a `-m` that steer never had — `agentctl steer s1 -f /tmp/b.md; printf '%s' -m
# 'literal `date`'` counter-probed at rc=2, i.e. the rule broke its own two published promises
# (`-f` never matches, no `-m` never matches). The scan now stops at rule (12)'s separator set
# plus newline, and WHICH separators count is decided on `_quote_blind` — no new parse face, the
# same length-preserving two-read idiom rules (14)/(17) carry, so a quoted option value holding a
# `;` or `|` stays data while the body is still read from `raw` at the same offset. The comment
# carries the counter-probe and the one direction the narrowing gives up (a backslash-ESCAPED
# separator ends the scan = a MISS, fail-open), because a boundary nobody wrote down is the one
# the next batch re-widens by accident. Oracles: `r21-neg-dash-m-of-next-command-is-not-ours`
# plus a chained-steer positive control and a quoted-separator positive.
BASELINES='
skills/cto-orchestration/references/agentctl/duplexctl.py 3654
skills/cto-orchestration/references/agentctl/watchctl.py 1508
skills/cto-orchestration/references/agentctl/identity.py 1509
skills/cto-orchestration/references/agentctl/agentctl 620
skills/cto-orchestration/references/agentctl/cto-guard-bash.py 2423
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
