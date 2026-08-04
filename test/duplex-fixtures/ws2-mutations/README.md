# WS2 mutation patches — proof the receipt predicates are load-bearing

One patch per predicate, each targeting ONLY that predicate. Re-apply, run
`bash test/agentctl-receipt.test.sh`, expect the named case RED with a damage assertion (not a
crash), and every unrelated paired green still GREEN:

| patch | predicate it removes | expected red (see docs/orchestration/WS2_FINDINGS.md for the exact lines) |
|---|---|---|
| `M1-skip-hashing.patch` | the deliverable's bytes are actually hashed | R1 — recorded sha256 becomes the empty-input digest |
| `M2-drop-stamp-fence.patch` | reuse of the WS1 identity fence on the record | R2 — a prior-attempt / forged receipt opens the gate |
| `M3-delivered-on-missing.patch` | delivery requires satisfied evidence | R3 — `phase=delivered` on a missing file |
| `M4-plain-write-not-atomic.patch` | atomic temp+fsync+replace publication | R4 — partial JSON at the record path, prior record destroyed |
| `M5-invent-githead.patch` | never inventing provenance | R5 — `gitHead` becomes a fabricated all-zero sha |
| `M6-skip-receipt-schema.patch` | receipt-body validation at the read boundary (fix round 1) | R7 — a forged current-stamped body opens the gate mtime refused |
| `M7-absolute-symlink-exemption.patch` | the ancestor walk for ABSOLUTE declarations (fix round 1) | R8 — foreign bytes hashed through a symlinked ancestor and delivered |
| `M8-missing-meta-reports-ok.patch` | refusing when the session lane is gone (fix round 1) | R9 — publish exits 0 with no meta, so a stale DONE survives |

```
git -C <worktree> apply test/duplex-fixtures/ws2-mutations/M2-drop-stamp-fence.patch
bash test/agentctl-receipt.test.sh          # expect FAIL
git -C <worktree> apply -R test/duplex-fixtures/ws2-mutations/M2-drop-stamp-fence.patch
```

Fix round 2 added five more, one per predicate introduced while closing the round-2 review
(each again RED only on its own case, paired greens elsewhere intact):

| patch | predicate it removes | expected red |
|---|---|---|
| `M9-first-symlink-is-platform-prefix.patch` | the platform-alias allowlist | R10 — a user's cwd symlink is exempted, foreign bytes hashed |
| `M10-githead-sha1-only.patch` | accepting 64-hex (sha256) git object ids | R11 — the publisher's own sha256-repo receipt is refused |
| `M11-traverse-requires-read.patch` | `O_SEARCH`/`O_PATH` ancestor traversal | R12 — a readable file under a mode-0111 directory is refused |
| `M12-rfc3339-shape-only.patch` | parsing the whole timestamp | R13 — `+99:99` / `+24:00` / `+23:60` validate again |
| `M13-require-noncontract-field.patch` | requiring only contract fields | R14 — a contract-shaped record is refused for a missing extension |

Fix round 3 added three more and REGENERATED `M7`, `M9`, `M10`, `M12` (their targets moved when
the anchor/parse predicates changed — a patch that no longer applies proves nothing):

| patch | predicate it removes | expected red |
|---|---|---|
| `M14-deadpane-skips-validator.patch` | one acceptance rule for every terminal-truth reader | R15 — dead-pane adoption returns DONE 0 on a body the canonical reader refuses |
| `M15-anchor-dollar-not-fullmatch.patch` | full-string matching of evidence values | R17 — a 40/64-hex gitHead or a sha256 with a trailing newline is accepted |
| `M16-leap-second-anywhere.patch` | the leap-second POSITION rule | R18 — `:60` validates mid-day |
