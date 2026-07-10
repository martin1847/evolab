#!/usr/bin/env bash
# Repo-owned engineering gate template. Copy to scripts/engineering-gate.sh and
# generate scripts/engineering-gate.conf during bootstrap.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${ENGINEERING_GATE_CONFIG:-$ROOT/scripts/engineering-gate.conf}"
ACTION="${1:-}"
PUBLIC_STANDARD="agent-backend-standard/references/engineering-interface.md"
TYPE_STANDARD="observability-standard/references/standard.md §2"

usage() {
  printf 'usage: bash scripts/engineering-gate.sh {fix|check|test}\n' >&2
  exit 2
}

blocked() {
  local profile="$1" stage="$2" failed="$3" retry="$4"
  printf '\nengineering-gate: BLOCKED — %s/%s\n' "$profile" "$stage" >&2
  printf 'Failed: %s\n' "$failed" >&2
  printf 'Fix:   bash scripts/engineering-gate.sh fix\n' >&2
  printf 'Retry: %s\n' "$retry" >&2
  printf 'Read:\n' >&2
  printf '  AGENTS.md § Engineering Gate\n' >&2
  printf '  %s\n' "$PUBLIC_STANDARD" >&2
  printf '  %s\n' "$TYPE_STANDARD" >&2
  exit 1
}

run() {
  local profile="$1" stage="$2" display="$3" retry="$4"
  shift 4
  "$@" || blocked "$profile" "$stage" "$display" "$retry"
}

require_command() {
  local profile="$1" stage="$2" command_name="$3" retry="$4"
  command -v "$command_name" >/dev/null 2>&1 || \
    blocked "$profile" "$stage" "missing tool: $command_name" "$retry"
}

require_wrapper() {
  local profile="$1" stage="$2" wrapper="$3" retry="$4"
  [ -x "$wrapper" ] || blocked "$profile" "$stage" "missing executable wrapper: $wrapper" "$retry"
}

python_profile() {
  local stage="$1" retry="bash scripts/engineering-gate.sh $1"
  require_command python "$stage" uv "$retry"
  case "$stage" in
    fix)
      run python fix 'uv run ruff check --fix .' "$retry" uv run ruff check --fix .
      run python fix 'uv run ruff format .' "$retry" uv run ruff format .
      ;;
    check)
      run python check 'uv run ruff check .' "$retry" uv run ruff check .
      run python check 'uv run ruff format --check .' "$retry" uv run ruff format --check .
      run python check 'uv run pyright' "$retry" uv run pyright
      ;;
    test)
      run python test 'uv run pytest' "$retry" uv run pytest
      ;;
  esac
}

go_profile() {
  local stage="$1" retry="bash scripts/engineering-gate.sh $1" unformatted
  local files_tmp unformatted_tmp file
  require_command go "$stage" go "$retry"
  case "$stage" in
    fix)
      run go fix 'go fmt ./...' "$retry" go fmt ./...
      ;;
    check)
      require_command go check gofmt "$retry"
      files_tmp="$(mktemp "${TMPDIR:-/tmp}/engineering-gate.go-files.XXXXXX")" || \
        blocked go check 'mktemp for tracked Go files' "$retry"
      unformatted_tmp="$(mktemp "${TMPDIR:-/tmp}/engineering-gate.gofmt.XXXXXX")" || {
        rm -f "$files_tmp"
        blocked go check 'mktemp for gofmt output' "$retry"
      }
      if ! git ls-files -z -- '*.go' > "$files_tmp"; then
        rm -f "$files_tmp" "$unformatted_tmp"
        blocked go check "git ls-files -z -- '*.go'" "$retry"
      fi
      while IFS= read -r -d '' file; do
        if ! gofmt -l "$file" >> "$unformatted_tmp"; then
          rm -f "$files_tmp" "$unformatted_tmp"
          blocked go check 'gofmt -l <tracked-go-file>' "$retry"
        fi
      done < "$files_tmp"
      unformatted="$(cat "$unformatted_tmp")"
      rm -f "$files_tmp" "$unformatted_tmp"
      if [ -n "$unformatted" ]; then
        printf '%s\n' "$unformatted" >&2
        blocked go check "gofmt check (unformatted files listed above)" "$retry"
      fi
      run go check 'go vet ./...' "$retry" go vet ./...
      require_command go check staticcheck "$retry"
      run go check 'staticcheck ./...' "$retry" staticcheck ./...
      require_command go check golangci-lint "$retry"
      run go check 'golangci-lint run ./...' "$retry" golangci-lint run ./...
      ;;
    test)
      run go test 'go test ./...' "$retry" go test ./...
      ;;
  esac
}

java_maven_profile() {
  local stage="$1" retry="bash scripts/engineering-gate.sh $1"
  require_wrapper java-maven "$stage" ./mvnw "$retry"
  case "$stage" in
    fix) run java-maven fix './mvnw spotless:apply' "$retry" ./mvnw spotless:apply ;;
    check)
      run java-maven check './mvnw -DskipTests compile spotless:check checkstyle:check' "$retry" \
        ./mvnw -DskipTests compile spotless:check checkstyle:check
      ;;
    test) run java-maven test './mvnw test' "$retry" ./mvnw test ;;
  esac
}

java_gradle_profile() {
  local stage="$1" retry="bash scripts/engineering-gate.sh $1"
  require_wrapper java-gradle "$stage" ./gradlew "$retry"
  case "$stage" in
    fix) run java-gradle fix './gradlew spotlessApply' "$retry" ./gradlew spotlessApply ;;
    check)
      run java-gradle check './gradlew classes testClasses spotlessCheck checkstyleMain checkstyleTest' "$retry" \
        ./gradlew classes testClasses spotlessCheck checkstyleMain checkstyleTest
      ;;
    test) run java-gradle test './gradlew test' "$retry" ./gradlew test ;;
  esac
}

rust_profile() {
  local stage="$1" retry="bash scripts/engineering-gate.sh $1"
  require_command rust "$stage" cargo "$retry"
  case "$stage" in
    fix) run rust fix 'cargo fmt --all' "$retry" cargo fmt --all ;;
    check)
      run rust check 'cargo fmt --all -- --check' "$retry" cargo fmt --all -- --check
      run rust check 'cargo check --workspace --all-targets' "$retry" cargo check --workspace --all-targets
      run rust check 'cargo clippy --workspace --all-targets -- -D warnings' "$retry" \
        cargo clippy --workspace --all-targets -- -D warnings
      ;;
    test) run rust test 'cargo test --workspace' "$retry" cargo test --workspace ;;
  esac
}

case "$ACTION" in fix|check|test) ;; *) usage ;; esac
[ -f "$CONFIG" ] || blocked config load "missing config: $CONFIG" "initialize scripts/engineering-gate.conf"

profiles=0
while IFS=$'\t' read -r profile rel extra || [ -n "${profile:-}${rel:-}${extra:-}" ]; do
  case "${profile:-}" in ''|'#'*) continue ;; esac
  if [ -z "${rel:-}" ] || [ -n "${extra:-}" ]; then
    blocked config load "invalid row; expected <profile><TAB><relative-root>" "fix $CONFIG"
  fi
  case "$rel" in /*|..|../*|*/../*|*/..) blocked config load "unsafe module root: $rel" "fix $CONFIG" ;; esac
  [ -d "$ROOT/$rel" ] || blocked config load "missing module root: $rel" "fix $CONFIG"
  profiles=$((profiles + 1))
  (
    cd "$ROOT/$rel" || exit 1
    case "$profile" in
      python) python_profile "$ACTION" ;;
      go) go_profile "$ACTION" ;;
      java-maven) java_maven_profile "$ACTION" ;;
      java-gradle) java_gradle_profile "$ACTION" ;;
      rust) rust_profile "$ACTION" ;;
      *) blocked config load "unknown profile: $profile" "fix $CONFIG" ;;
    esac
  ) || exit $?
done < "$CONFIG"

[ "$profiles" -gt 0 ] || blocked config load "no active profiles in $CONFIG" "initialize $CONFIG"
printf 'engineering-gate: PASS — %s (%s profile%s)\n' "$ACTION" "$profiles" "$([ "$profiles" -eq 1 ] || printf s)"
