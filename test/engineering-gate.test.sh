#!/usr/bin/env bash
# Hermetic contract tests for the bootstrap engineering gate template.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../skills/repo-governance-bootstrap/references/engineering-gate.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); printf '  FAIL: %s\n' "$*"; }
has(){ case "$1" in *"$2"*) ok ;; *) no "$3: missing [$2]" ;; esac; }
eq(){ [ "$1" = "$2" ] && ok || no "$3: expected [$2] got [$1]"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/repo"
BIN="$TMP/bin"
LOG="$TMP/calls.log"
mkdir -p "$ROOT/scripts" "$ROOT/py" "$ROOT/go" "$ROOT/jm" "$ROOT/jg" "$ROOT/rs" "$BIN"
cp "$SOURCE" "$ROOT/scripts/engineering-gate.sh"
chmod +x "$ROOT/scripts/engineering-gate.sh"
git -C "$ROOT" init -q
printf 'package demo\n' > "$ROOT/go/main.go"
git -C "$ROOT" add go/main.go

printf 'python\tpy\ngo\tgo\njava-maven\tjm\njava-gradle\tjg\nrust\trs\n' > "$ROOT/scripts/engineering-gate.conf"

cat > "$BIN/tool-shim" <<'SHIM'
#!/usr/bin/env bash
name="$(basename "$0")"
line="$name $*"
printf '%s\n' "$line" >> "$GATE_TEST_LOG"
if [ "$name" = gofmt ] && [ "${UNFORMATTED:-0}" = 1 ]; then
  printf 'main.go\n'
fi
case "$line" in *"${FAIL_MATCH:-__never__}"*) exit 9 ;; esac
exit 0
SHIM
chmod +x "$BIN/tool-shim"
for tool in uv go gofmt staticcheck golangci-lint cargo; do ln -s tool-shim "$BIN/$tool"; done

cat > "$ROOT/jm/mvnw" <<'WRAPPER'
#!/usr/bin/env bash
printf 'mvnw %s\n' "$*" >> "$GATE_TEST_LOG"
case "mvnw $*" in *"${FAIL_MATCH:-__never__}"*) exit 9 ;; esac
WRAPPER
cat > "$ROOT/jg/gradlew" <<'WRAPPER'
#!/usr/bin/env bash
printf 'gradlew %s\n' "$*" >> "$GATE_TEST_LOG"
case "gradlew $*" in *"${FAIL_MATCH:-__never__}"*) exit 9 ;; esac
WRAPPER
chmod +x "$ROOT/jm/mvnw" "$ROOT/jg/gradlew"

export GATE_TEST_LOG="$LOG"
OLD_PATH="$PATH"
export PATH="$BIN:$PATH"

echo '== engineering-gate.test =='

for action in fix check test; do
  out="$(cd "$ROOT" && bash scripts/engineering-gate.sh "$action" 2>&1)"; rc=$?
  eq "$rc" 0 "$action rc"
  has "$out" "engineering-gate: PASS — $action (5 profiles)" "$action pass envelope"
done
calls="$(cat "$LOG")"
has "$calls" 'uv run ruff check --fix .' 'python fix'
has "$calls" 'go vet ./...' 'go check'
has "$calls" 'staticcheck ./...' 'go staticcheck'
has "$calls" 'golangci-lint run ./...' 'go golangci'
has "$calls" 'mvnw -DskipTests compile spotless:check checkstyle:check' 'maven check'
has "$calls" 'gradlew classes testClasses spotlessCheck checkstyleMain checkstyleTest' 'gradle check'
has "$calls" 'cargo clippy --workspace --all-targets -- -D warnings' 'rust check'

export FAIL_MATCH=pyright
out="$(cd "$ROOT" && bash scripts/engineering-gate.sh check 2>&1)"; rc=$?
eq "$rc" 1 'tool failure blocks'
has "$out" 'engineering-gate: BLOCKED — python/check' 'failure stage'
has "$out" 'Failed: uv run pyright' 'failure exact command'
has "$out" 'Fix:   bash scripts/engineering-gate.sh fix' 'failure fix'
has "$out" 'Retry: bash scripts/engineering-gate.sh check' 'failure retry'
has "$out" 'AGENTS.md § Engineering Gate' 'failure local standard'
has "$out" 'agent-backend-standard/references/engineering-interface.md' 'failure canonical standard'
has "$out" 'observability-standard/references/standard.md §2' 'failure type standard'
unset FAIL_MATCH

export UNFORMATTED=1
out="$(cd "$ROOT" && bash scripts/engineering-gate.sh check 2>&1)"; rc=$?
eq "$rc" 1 'gofmt difference blocks'
has "$out" 'main.go' 'gofmt lists file'
has "$out" 'engineering-gate: BLOCKED — go/check' 'gofmt failure stage'
unset UNFORMATTED

export FAIL_MATCH=gofmt
out="$(cd "$ROOT" && bash scripts/engineering-gate.sh check 2>&1)"; rc=$?
eq "$rc" 1 'gofmt tool failure blocks'
has "$out" 'Failed: gofmt -l <tracked-go-file>' 'gofmt tool failure exact command'
has "$out" 'engineering-gate: BLOCKED — go/check' 'gofmt tool failure stage'
unset FAIL_MATCH

printf 'python\t../escape\n' > "$ROOT/scripts/engineering-gate.conf"
out="$(cd "$ROOT" && bash scripts/engineering-gate.sh check 2>&1)"; rc=$?
eq "$rc" 1 'unsafe root blocks'
has "$out" 'unsafe module root: ../escape' 'unsafe root explanation'

export PATH="$OLD_PATH"
echo "== engineering-gate: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
