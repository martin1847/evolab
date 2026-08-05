#!/usr/bin/env bash
# Hermetic contract for the opt-in cheapest-refutation dispatch gate.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

CHECK="../skills/cto-orchestration/references/goal-preflight.py"
echo "== goal-preflight =="

run_check(){ out="$("$CHECK" "$1" 2>&1)"; rc=$?; }

sandbox_new
goal="$SANDBOX/goal.md"

printf 'Value gate: gap -> value; Preflight: query metrics => 39.5%% hit the 4096 cap\n' > "$goal"
run_check "$goal"
chk_eq "observed preflight passes" 0 "$rc"
chk_eq "passing preflight is silent" "" "$out"

printf "Preflight: jq 'length > 0' metrics.json => no rows hit the cap\n" > "$goal"
run_check "$goal"
chk_eq "negative observed result and comparison operator pass" 0 "$rc"

printf '# no preflight\n' > "$goal"
run_check "$goal"
chk_eq "missing preflight rejected" 1 "$rc"
chk_contains "missing error names exact contract" "expected exactly one" "$out"

printf 'Preflight: <cheapest probe> => <observed result>\n' > "$goal"
run_check "$goal"
chk_eq "placeholders rejected" 1 "$rc"
chk_contains "placeholder error is actionable" "replace every placeholder" "$out"

for unresolved in 'not run' pending unknown N/A; do
  printf 'Preflight: query metrics => %s\n' "$unresolved" > "$goal"
  run_check "$goal"
  chk_eq "unresolved result rejected: $unresolved" 1 "$rc"
done

printf 'Preflight: query metrics => result: pending\n' > "$goal"
run_check "$goal"
chk_eq "labelled unresolved result rejected" 1 "$rc"

printf 'Preflight: probe one => result one\nPreflight: probe two => result two\n' > "$goal"
run_check "$goal"
chk_eq "duplicate declarations rejected" 1 "$rc"

# WARN class (same-source self-proof smell): advisory only, three states, never blocks.
ok='Preflight: query metrics => 39.5%% hit the cap\n'

printf "$ok- [ ] 漂移门断言表与注册表一致\n" > "$goal"
run_check "$goal"
chk_eq "KNOWN-BAD: internal-agreement row still dispatches (advisory)" 0 "$rc"
chk_contains "KNOWN-BAD: it is flagged" "断言内部自洽" "$out"
chk_contains "KNOWN-BAD: the row is quoted" "漂移门" "$out"
chk_contains "KNOWN-BAD: it points at the owning judgement" "仪器第 5 问" "$out"

printf "$ok- [ ] 漂移门：改真实握手动词后该用例变红（观察 emit 的 frame）\n" > "$goal"
run_check "$goal"
chk_eq "KNOWN-GOOD: a behaviour-anchored row passes" 0 "$rc"
chk_eq "KNOWN-GOOD: and stays silent" "" "$out"

printf "$ok- [ ] 交付物 sha256 与声明匹配，且 \`agentctl status\` exits 0\n" > "$goal"
run_check "$goal"
chk_eq "NEGATIVE CONTROL: agreement wording plus observable evidence is not flagged" "" "$out"

printf '# no preflight\n- [ ] 断言表与注册表一致\n' > "$goal"
run_check "$goal"
chk_eq "GATE PRECEDENCE: a hard failure still rejects" 1 "$rc"
chk_not_contains "GATE PRECEDENCE: and the advisory does not speak over it" "断言内部自洽" "$out"

rm -rf "$SANDBOX"
summary
