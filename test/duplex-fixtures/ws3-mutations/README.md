# WS3 mutation patches — proof the capability predicates are load-bearing

One patch per predicate. Re-apply, run `bash test/agentctl-capabilities.test.sh`, expect the
named case RED with a **damage assertion** (a wrong value the mutant produced), never a
harness traceback, and every unrelated paired green still GREEN:

```
git -C <worktree> apply test/duplex-fixtures/ws3-mutations/M3-claude-degraded-to-supported.patch
bash test/agentctl-capabilities.test.sh          # expect FAIL
git -C <worktree> apply -R test/duplex-fixtures/ws3-mutations/M3-claude-degraded-to-supported.patch
```

Every probe and every JSON read in the suite is tolerant (`""` on a missing key, an
`emitted=<branch-error:…>` value on an uninvocable branch), so a mutation reds through the
suite's own assertion. Fix round 1 fixed this: M3/M4/M5 previously produced `KeyError`
tracebacks between the damage assertions (cold review R1, MAJOR).

## Structural patches — the table vs the derived registries

| patch | predicate it removes | observed red |
|---|---|---|
| `M1-fixture-provider-unlisted.patch` | every adapter with routes/projection is contracted | C1 — a `fixtureprov` adapter hand-added to the DERIVED `ROUTES`/`PROJECTORS` that no cell declares |
| `M2-advertise-unrouted-supported.patch` | a non-unsupported state needs exactly one realization | C2 — claude `replaceTurn` flipped to `supported` with neither route nor surface |
| `M3-claude-degraded-to-supported.patch` | a degradation is never advertised as the native capability | C4 — claude `midTurnSteer` relabelled `supported`, note and fallback gone |
| `M4-flatten-codex-onto-omp.patch` | provider maps stay provider-specific | C5 — codex handed omp's capability map wholesale |
| `M5-drop-provider-from-table.patch` | a launched provider cannot vanish from the contract | C1 — codex deleted from `PROVIDERS` while the suite still starts it |

## Behaviour patches — the contract vs what the code actually DOES

Added in fix round 1. These are the three mutations the cold reviewer ran against round 0,
where the whole suite stayed `72 passed, 0 failed`: registry agreement could not see a
consumer that had stopped performing the declared capability. §C8 exercises the real code path
against the hermetic fake engines and asserts the observable effect, so all three now red.

| patch | behaviour it breaks | observed red |
|---|---|---|
| `N1-handshake-ignores-declared-resume-route.patch` | the codex handshake sends the resume method its `resume` cell declares | C8 — no `"method":"thread/resume"` on the wire; the session lands on `thread-1` instead of the operator's `old-thread-9` |
| `N2-omp-ask-projects-idle.patch` | an omp `extension_ui_request` projects as WAITING-INPUT | C8 — `status` exits 0 instead of 4 on a live engine question |
| `N3-launch-name-drifts-from-contract.patch` | the generated launch spec names providers exactly as the contract does | C8 — `agentctl start claude` fails; C1/C7 also name the drift |

## Blast radius, stated honestly

The contract is single-sourced ON PURPOSE, so some mutations red more than one case. That is
the property, not sloppiness:

- **M1 / M5 / N3** also red **C7** (the drift gate). Provider coverage is exactly what that
  gate exists to check, so the spec's contract test #1 and the dedicated drift test detect the
  same damage from two directions. Neither is redundant: C1 asserts the published surfaces
  (human table, JSON document, generated launch spec), C7 asserts the module.
- **M5** additionally reds every codex case (C2/C3/C4/C5/C8). Removing a provider from the
  table removes its ROUTING and its LAUNCH SPEC too — `capability()` fails closed with
  `unknown duplex engine: codex — no capability contract`. A dropped provider that kept
  working would mean nothing was actually consuming the table.
- **M2** also reds **C3**: with `replaceTurn` advertised as supported the capability gate stops
  refusing, so the honest `stop` + `--resume` path is never printed. The rejection message and
  the published note are one string.
- **M3** also reds one **C8** row: the runtime stops announcing the degradation, which is the
  behavioural half of the same lie.
- **M4** also reds C2/C3/C7/C8: a flattened "common" contract is not merely cosmetically
  wrong, it is mechanically unroutable — codex ends up declaring omp's `follow_up` /
  `abort_and_prompt` routes, whose branches it cannot even invoke.
- **N3** also reds every claude C8 row, because a provider whose launch name drifted from the
  contract cannot be started at all — which is the whole point.

What must NOT happen under any patch: an unrelated paired green turning red, or a case failing
with a traceback instead of an assertion. Both were checked for all eight
(`grep -c Traceback` = 0 on every run).
