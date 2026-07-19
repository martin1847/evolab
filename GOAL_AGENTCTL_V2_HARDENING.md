# GOAL — Harden agentctl v2 before opt-in cutover

> Owner: implementation agent. Target remote branch `origin/feat/agentctl-v2`
> (`2d819e4` when this brief was written); base `origin/main` (`cd68056`, target branch
> ahead 3 / behind 6). Fetch both refs, create an isolated worktree from the remote target,
> then rebase onto latest `origin/main` before editing.
> Reviewer: fresh-context Codex after commits. No push, merge, default-lane cutover, or
> branch deletion without Martin's new approval.

## Context — read first

- On `origin/feat/agentctl-v2`: `skills/cto-orchestration/references/agentctl/README.md`
- On `origin/feat/agentctl-v2`: `skills/cto-orchestration/references/agentctl/src/agentctl/`
- This brief is self-contained; no additional branch is a dependency.

Keep the architecture: one Python session actor, mode-0600 Unix socket, provider-native
RPC, typed state projection, tmux as process supervisor only. This task fixes
guard/state defects; it is not an architecture rewrite.

## Premises — verify, do not trust

- [ ] Provider preflight currently happens after session claim (`cli.py:_start`).
- [ ] `load_config` currently revalidates live executable/goal paths, so drift can block
  control operations including force-stop.
- [ ] The event pump only catches `TimeoutError` and can leave stale public state.
- [ ] Codex `serverRequest/resolved` does not clear the exact pending request.
- [ ] A terminal Codex turn does not clear the matching `active_turn_id`.
- [ ] OMP correlated replies are not bound to expected response type/command/session, and
  steerability may be projected before `agent_start`.

If any premise is false on the rebased branch, record the proof and skip only that fix.
Do not preserve a finding merely because this brief says it exists.

## Task

1. Rebase the feature branch onto current `origin/main`; resolve only feature-owned seams.
2. Fix the six premises with the smallest local changes:
   - complete provider/version/goal preflight before publishing a session claim, or roll
     back a failed claim without weakening atomic double-start protection;
   - separate immutable config integrity from live-file drift so `status` and exact
     owner-bound force-stop remain available; retain neighbor-session/tamper protection;
   - fail closed on unexpected event-pump errors and never keep reporting stale `WORKING`;
   - clear only the exact Codex request on `serverRequest/resolved`/cancellation;
   - clear only the matching terminal `active_turn_id`, without allowing late events to
     clear a newer turn;
   - validate OMP response type, success, expected command and `get_state.sessionId`;
     expose active-turn steering only after the corresponding `agent_start`.
3. Add one negative regression test per defect. Each test must fail against the pre-fix
   implementation and pass after the fix.
4. Update agentctl documentation only where behavior or verified evidence changed.
5. Commit the focused implementation locally, then stop for cold review.

## Done when

- [ ] Missing/broken provider preflight leaves no poisoned session claim; a corrected
  retry with the same logical session can start.
- [ ] Goal/executable drift cannot prevent status or exact owner-bound force-stop, while
  config substitution and neighbor-stop probes still fail closed.
- [ ] Injected provider/reducer/storage event-pump failure produces `FAILED` or `LOST`,
  never stale `WORKING`.
- [ ] Exact Codex resolution clears pending input; stale/wrong request IDs do not.
- [ ] Exact terminal turn clears its active ID; late old-turn events cannot regress or
  clear a newer active turn.
- [ ] Wrong OMP response type/command, missing session ID, and pre-`agent_start` steering
  are rejected; valid `now/next/replace` flows remain green.
- [ ] `UV_CACHE_DIR=.uv-cache bash test/agentctl-v2.test.sh` exits 0.
- [ ] With host permission, real tmux/socket tests and cost-free installed-provider
  handshakes pass:

  ```bash
  AGENTCTL_REAL_TMUX=1 UV_CACHE_DIR=.uv-cache uv run \
    --project skills/cto-orchestration/references/agentctl \
    python -m unittest -v \
    test/agentctl-v2-fixtures/test_cli_real.py \
    test/agentctl-v2-fixtures/test_supervisor_real.py

  AGENTCTL_LIVE_HANDSHAKE=1 UV_CACHE_DIR=.uv-cache uv run \
    --project skills/cto-orchestration/references/agentctl \
    python -m unittest -v test/agentctl-v2-fixtures/test_live_handshakes.py
  ```

- [ ] Repository full gate `bash test/run.sh` exits 0.
- [ ] Final report states commits, commands actually run, unverified items, remaining
  risks, and any premise refuted by evidence.

## Guardrails / stop-loss

- Scope is the six defects, their tests, and directly affected agentctl docs.
- Out of scope: Claude adapter, facade/default routing, existing shim removal,
  deliverable/review-loop integration, new public commands, provider resurrection,
  cross-machine recovery, remote OTLP export, or real token-consuming prompt E2E.
- Do not weaken mode-0600/0700 permissions, owner nonce/session binding, immutable config
  digest, command deduplication, typed projection, or existing negative tests.
- Do not make the current OMP shim and agentctl concurrent owners of one session.
- No neighboring refactor or bulk formatting. Do not delete, skip, or relax tests.
- If a fix requires changing the actor/supervisor architecture, an existing dispatch
  contract must regress, or the same path fails twice: stop and report the evidence and
  smallest viable options.
- Phase 2 begins only after all gates are green and cold review returns no blocking
  finding. Do not implement cutover in this task.
