# B3 codex daemon settings — 2026-09-25

Scratch TUI: `b3-daemon-scratch-0925`, cwd `/Users/martin/Documents/TMP`, thread `01a0d80a-173f-7943-a4de-a6244bf605e4` from its status bar. One model turn: `say READY` → `READY`.

Read before writes: `agentctl settings --thread 01a0d80a-173f-7943-a4de-a6244bf605e4 --engine codex` → `SETTINGS: model=gpt-6-luna effort=low mode=default approval=on-request sandbox=workspace-write source=turn_context@1` (rc 0).

Write receipts on this scratch thread, in order:

1. Pre-fix `--effort medium --mode plan` → `ERR: codex daemon rc=1: TimeoutError: daemon update failed` (rc 2). The setting applied, but the script had not subscribed with `thread/resume` and timed out waiting for its notification.
2. After subscription, `--mode default --effort low` → `SETTINGS: model=gpt-6-luna effort=low mode=default approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0).
3. Final check, `--effort medium --mode plan` → `SETTINGS: model=gpt-6-luna effort=medium mode=plan approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0).
4. Restore, `--mode default --effort low` → `SETTINGS: model=gpt-6-luna effort=low mode=default approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0).

`tmux capture-pane -t b3-daemon-scratch-0925 -p` excerpts after writes 3 and 4:

- Plan: `GPT-6-Luna medium · ~/Documents/TMP · ... Plan mode (shift+tab to cycle)`.
- Restored: `GPT-6-Luna low · ~/Documents/TMP · ...` (no `Plan mode`).

The read path prints `sandbox=workspace-write` from the rollout; the write path prints `sandbox=workspaceWrite` from the protocol notification. This is a source spelling difference, not a settings change.

Verification: `copilot-primitives` 126/126 PASS; `agentctl-capabilities` 163/163 PASS; `agentctl-states` 40/40 PASS. LOC `--measure`: CODE 16119, PROSE 1556, DOC 4928, TEST 22146, INJECT 18954, INJECT_SINGLE 2915. CODE/DOC/TEST exceed their pinned limits; INJECT and INJECT_SINGLE are within limits.

Full suite: `bash test/run.sh` → PASS=46, FAIL=2, SKIP=0. The only failed suites were `agentctl-lineage.test.sh` (k2 expected 3 explicit empty blocks, got 2) and `loc-budget.test.sh` (CODE/DOC/TEST only); the later import-ignore comment raised DOC from 4927 to 4928 without changing that classification.

not verified: live `--model` changes, a new model turn after settings changes, or persistence of updated settings into a later rollout `turn_context`.

## Fix r2
- Mode writes now default from live `thread/resume` model/reasoningEffort; CLI forwards only explicit flags, and daemon errors preserve the first stderr line.
- `--effort medium` → `SETTINGS: model=gpt-6-luna effort=medium mode=default approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0).
- `--mode plan` → `SETTINGS: model=gpt-6-luna effort=medium mode=plan approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0); no model turn.
- `--mode default --effort low` → `SETTINGS: model=gpt-6-luna effort=low mode=default approval=on-request sandbox=workspaceWrite source=thread/settings/updated` (rc 0).
- Tests: copilot 127/127, capabilities 163/163, states 40/40, LOC 16/16 PASS.
- `--measure`: CODE 16111, PROSE 1556, DOC 4928, TEST 22146, INJECT 18954, INJECT_SINGLE 2915.
- New SHA: `git log -1 --format=%h -- docs/orchestration/B3_codex.md` after commit; parent `f24f61d`.
