# BLOCKED — one acceptance criterion of WS1 fix round 3 is not satisfiable here

Both R3 work items are DONE, committed and green (details: `docs/orchestration/WS1_FINDINGS.md`,
§Fix round 3). What is blocked is one acceptance criterion of the round, not the work.

## The blocker

`bash test/agentctl-duplex.test.sh` — a suite this work changes by three lines (arming an
identity record for a hand-built session) — became unstable on this machine partway through the
round and has not returned to green since. The round required a serial four-suite green at the
final head; I cannot honestly paste it.

Observed at head `08ad606`: exit 1, 7 failed. The first failing assertion drifts between runs
(`omp idle no-gate`, `steer --replace`, `steer with -d`). The one run whose error text was
captured directly shows the session's engine/pane disappearing mid-suite, after which the next
send fails `ERR: fifo has no reader (Device not configured)` and every remaining assertion for
that session reads exit 2 (`AGENT-DEAD`).

## Why this is not a WS1 regression

Same suite, same machine state, product code swapped underneath:

| product code under test | result |
|---|---|
| this head (`08ad606`) | exit 1 — 7 failed |
| pre-round-3 (`ae3b72d`) | exit 1 — 8 failed |
| **pre-WS1 baseline (`main`, `a6acd86`)** | **exit 1 — 8 failed, same assertion cluster** |

The pre-WS1 baseline reproduces it identically. No WS1 commit is implicated.

## What was ruled out, with evidence

- **My commits** — baseline reproduces (table above).
- **Interpreter/engine start latency against duplexctl's 5 s fifo-open deadline** —
  `python3 -c pass` costs 33 ms; the fake engine reaches its first frame in 60 ms.
- **An external process reaper** — a background engine started the same way from a plain bash
  script survives 60 s untouched.
- **Machine load alone** — still fails at load average 2.2, having passed six times earlier at
  comparable load, including three consecutive four-suite CONCURRENT runs.
- **My leftover processes** — two strays, both unrelated fixtures; killed and retested.

Cause: **UNKNOWN**, left that way deliberately rather than guessed at. It is outside both R3
areas (the lock axis and N4).

## What IS green at this head

```text
bash test/duplexctl-timeout.test.sh    => exit 0  ( 80 passed, 0 failed)
bash test/mirror-sync.test.sh          => exit 0  (  6 passed, 0 failed)
bash test/agentctl-identity.test.sh    => exit 0  (190 passed, 0 failed)
```

Plus the round's own acceptance: three consecutive runs of all four suites CONCURRENTLY, every
suite green each time (`agentctl-duplex` 168/0 in all three), captured before the instability
began — pasted in §Fix round 3. Mutation patches all six apply; M1/M4/M5 re-verified red.

## Smallest available next step

1. Run `bash test/agentctl-duplex.test.sh` on a quiet machine or another host. If it is green
   there, this is environmental and the round can close on the concurrent evidence.
2. If it reproduces elsewhere, instrument the fake-tmux wrapper in that suite to record why the
   pane leader dies — it currently prints no engine diagnostics at all, which is the same gap
   that made the N4 flake UNKNOWN for a whole review cycle.

Nothing was pushed. The worktree is clean.
