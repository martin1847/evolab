# Agent-friendly engineering interface

## §1 Scope and source of truth

This reference defines the stable engineering interface that every backend repository exposes to
humans and coding agents. It standardizes **how to fix, check, and test**, not every tool's internal
configuration.

- Type and boundary-model rules remain canonical in
  `observability-standard/references/standard.md §2`; do not copy them here.
- Repository bootstrap and Git hook wiring belong to `repo-governance-bootstrap`; this file owns the
  command and failure contracts.
- A local hook is an inner-loop forcing function. It does not replace a required CI check because
  `git commit --no-verify` can bypass it.

## §2 Stable three-command contract

Every backend repository MUST expose these repo-owned commands from its root:

```bash
bash scripts/engineering-gate.sh fix
bash scripts/engineering-gate.sh check
bash scripts/engineering-gate.sh test
```

- `fix` may rewrite source files. Agents run it explicitly, review the diff, and stage again.
- `check` MUST be non-mutating and cover formatting plus compiler/static-analysis gates.
- `test` MUST run the repository-declared deterministic local suite. CI runs the full suite and any
  platform/feature matrix.
- Tool commands live behind this interface. AGENTS.md, hooks, CI, and agents call the wrapper instead
  of duplicating tool invocations in four places.
- New repositories start strict. Existing repositories may ratchet (§4), but the three command names
  and failure behavior stay identical.

## §3 Language profiles

The bootstrap-generated `scripts/engineering-gate.conf` pins one or more explicit profile/root pairs.
Do not recursively guess languages on every run. Polyglot repositories list each module root.

| Profile | `fix` | `check` | `test` | Full CI close |
|---|---|---|---|---|
| Python | `uv run ruff check --fix .` then `uv run ruff format .` | Ruff lint + format check + `uv run pyright` | `uv run pytest` | check + full pytest |
| Go | `go fmt ./...` | tracked-file `gofmt` check + `go vet ./...` + `staticcheck ./...` + `golangci-lint run ./...` | `go test ./...` | check + full test |
| Java / Maven | `./mvnw spotless:apply` | compile + Spotless + Checkstyle | `./mvnw test` | `./mvnw verify` with quality plugins bound to lifecycle |
| Java / Gradle | `./gradlew spotlessApply` | compile classes + Spotless + Checkstyle | `./gradlew test` | `./gradlew check` with quality tasks attached |
| Rust | `cargo fmt --all` | rustfmt check + `cargo check` + Clippy warnings-as-errors | `cargo test --workspace` | check + full test + repository-declared feature/platform matrix |

Normative details:

- Ruff safe fixes are the default; do not enable unsafe fixes company-wide. Ruff documents
  [`check --fix`](https://docs.astral.sh/ruff/linter/) and the non-mutating
  [`format --check`](https://docs.astral.sh/ruff/formatter/) contract. Pyright is strict for new code;
  project configuration owns excludes and legacy strict-path ratchets.
- `go fmt` rewrites files, while `gofmt -l` only lists differences and needs wrapper logic to fail on
  non-empty output. `go vet` is a heuristic static check, not a proof of correctness. See the official
  [`gofmt`](https://go.dev/cmd/gofmt/), [`vet`](https://pkg.go.dev/cmd/vet), and
  [`go test`](https://pkg.go.dev/cmd/go#hdr-Test_packages) documentation.
- Java has no JDK-wide canonical formatter. Company defaults use Spotless as the build-tool facade;
  Maven and Gradle projects MUST use their committed wrapper. Spotless supplies apply/check pairs for
  [Maven](https://github.com/diffplug/spotless/tree/main/plugin-maven) and
  [Gradle](https://github.com/diffplug/spotless/blob/main/plugin-gradle/README.md). Maven closes at
  [`verify`](https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html); Gradle
  verification tasks attach to [`check`](https://docs.gradle.org/current/userguide/java_plugin.html).
- Rust uses the toolchain-native [`cargo fmt`](https://doc.rust-lang.org/cargo/commands/cargo-fmt.html),
  [`cargo clippy`](https://doc.rust-lang.org/clippy/usage.html), and
  [`cargo test`](https://doc.rust-lang.org/cargo/commands/cargo-test.html). Do not hard-code
  `--all-features`: features may be mutually exclusive; the repository declares its CI matrix.

Strong static typing is not an exemption. Java and Rust need format, compiler/lint, tests, and runtime
validation of untrusted input; they simply do not need a Python-style external type checker.

Profile provisioning is part of initialization, not a workstation prerequisite:

- Python pins Ruff, Pyright, and pytest as project dev dependencies in `pyproject.toml` + `uv.lock`;
  new repositories set Pyright strict, while legacy repositories use §4 ratchets.
- Go pins `staticcheck` and `golangci-lint` through a repo-owned version manifest/bootstrap (use a
  `go.mod` tool dependency when supported) and verifies their versions in CI; ambient PATH versions
  are not the source of truth.
- Java commits exactly one wrapper (`mvnw` or `gradlew`), pins Spotless and Checkstyle plugin versions,
  commits formatter/lint configuration, and binds their check goals/tasks to `verify` / `check`.
- Rust commits `rust-toolchain.toml` with a pinned channel and `rustfmt` / `clippy` components.

The shipped script is a bootstrap template. For a large repository, initialization MAY replace each
profile's default full local test with a documented deterministic focused suite; AGENTS.md records the
exact local scope, while CI still runs the full close from the table.

## §4 Boundary validation and legacy ratchets

At every external boundary, parse and validate once, then pass a trusted typed value internally.
Static types do not validate semantic constraints or untrusted serialized data. The language-specific
patterns (Pydantic, Go validators, Jakarta Validation, Serde plus validation) live only in
`observability-standard/references/standard.md §2`.

Legacy adoption MUST be monotonic:

- New/changed code meets the full profile immediately.
- A baseline, exclude, or allowlist has an owner and a shrinking acceptance metric; it MUST NOT grow
  merely to make CI green.
- Python uses strict-path or baseline ratchets rather than a permanent weaker global mode.
- Java/Go/Rust lint suppressions are narrow and justified at the finding site; no repository-wide
  warning disable without an ADR.
- No gate command uses `|| true`, soft-fail, or an unbounded retry.

## §5 Hook and failure contract

Pre-commit runs `check` and the repository-declared local `test`; it MUST NOT run `fix`. Auto-fixing
after files are staged can leave the Git index holding the old content. CI independently runs the full
close from §3.

Every gate failure MUST preserve the underlying tool output and then print this actionable envelope:

```text
engineering-gate: BLOCKED — <profile>/<stage>
Failed: <exact command>
Fix:   bash scripts/engineering-gate.sh fix
Retry: bash scripts/engineering-gate.sh <check|test>
Read:
  AGENTS.md § Engineering Gate
  agent-backend-standard/references/engineering-interface.md
  observability-standard/references/standard.md §2
```

Missing tools and invalid configuration use the same envelope. A bare `lint failed` or raw
`command not found` is not an acceptable agent interface.

## §6 Initialization acceptance

Bootstrap is complete only when:

1. `scripts/engineering-gate.conf` explicitly names every initialized language/module root.
2. Profile tools/plugins are repo-pinned as specified in §3; a clean machine does not rely on ambient
   versions. All three commands exist; `check` and `test` are non-mutating.
3. `.githooks/pre-commit` calls docs-check (when present), then engineering `check`, then `test`.
4. Existing hook frameworks or `core.hooksPath` are merged, never overwritten silently.
5. AGENTS.md records the three commands, active profiles, and the §5 standard pointers.
6. Positive evidence passes once, and hermetic negative probes prove tool failure and partial
   gate/config installation both block with the required actionable envelope.
7. CI calls the same wrapper and the language-native full close; a real PR proves the required check can
   turn red.
