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
# Rows below marked [R2] came from the cold reviewer's counter-probes against the first
# implementation (3 false positives, 4 missed phrasings, wrong-section and wrong-row numbering)
# — heterogeneous mutations adopted as permanent controls.
ok='Preflight: query metrics => 39.5%% hit the cap\n'
dw='## Done when\n'

printf "$ok$dw- [ ] 漂移门断言表与注册表一致\n" > "$goal"
run_check "$goal"
chk_eq "KNOWN-BAD: internal-agreement row still dispatches (advisory)" 0 "$rc"
chk_contains "KNOWN-BAD: it is flagged" "断言内部一致" "$out"
chk_contains "KNOWN-BAD: the row is quoted" "漂移门" "$out"
chk_contains "KNOWN-BAD: it points at the owning judgement" "仪器第 5 问" "$out"

printf "$ok$dw- [ ] 漂移门：改真实握手动词后该用例变红（观察 emit 的 frame）\n" > "$goal"
run_check "$goal"
chk_eq "KNOWN-GOOD: a behaviour-anchored row passes" 0 "$rc"
chk_eq "KNOWN-GOOD: and stays silent" "" "$out"

printf "$ok$dw- [ ] 交付物 sha256 与声明匹配，且 \`agentctl status\` exits 0\n" > "$goal"
run_check "$goal"
chk_eq "NEGATIVE CONTROL: agreement wording plus observable evidence is not flagged" "" "$out"

# [R2] the three false positives: proof carried by a command, by a return reading, and by a
# continuation line — all are observable evidence and must stay silent.
printf "$ok$dw- [ ] HTTP response matches golden JSON (proof: \`jq -e .ok response.json\` returned 0)\n" > "$goal"
run_check "$goal"
chk_eq "[R2] FALSE-POSITIVE GUARD: consumer-boundary proof by command is silent" "" "$out"

printf "$ok$dw- [ ] 生成的 manifest 与 golden 文件匹配（证明：cmp -s out.json expected.json 返回 0）\n" > "$goal"
run_check "$goal"
chk_eq "[R2] FALSE-POSITIVE GUARD: executable proof with a return reading is silent" "" "$out"

printf "$ok$dw- [ ] schema 与 fixture 一致；\n  证明：diff --exit-code schema.json fixture.json exits 0\n" > "$goal"
run_check "$goal"
chk_eq "[R2] FALSE-POSITIVE GUARD: evidence on a continuation line is silent" "" "$out"

# [R2] four internal-agreement phrasings the first predicate missed
for phrasing in 'table equals registry' '能力表与注册表等价' 'registry mirrors the table' 'enabled provider sets are identical'; do
  printf "$ok$dw- [ ] %s\n" "$phrasing" > "$goal"
  run_check "$goal"
  chk_contains "[R2] MISSED PHRASING now caught: $phrasing" "断言内部一致" "$out"
done

# [R2] scoping: only the Done-when section counts, and numbering ignores rows outside it
printf "$ok## Premises\n- [ ] API schema 与已发布契约一致\n$dw- [ ] 部署后端点 200（\`curl -sf\` exits 0）\n" > "$goal"
run_check "$goal"
chk_eq "[R2] SCOPE: a Premises row is not reported as Done-when" "" "$out"

printf "$ok## Premises\n- [ ] a 与 b 一致\n- [ ] c 与 d 一致\n$dw- [ ] 表与注册表一致\n" > "$goal"
run_check "$goal"
chk_contains "[R2] ROW NUMBER counts within Done-when only" "第 1 条" "$out"

# [R3] two adopted fixes: english "returned 0" is evidence; "## Done When" capitalisation counts
printf "$ok$dw- [ ] HTTP response matches golden JSON (proof: jq -e .ok response.json returned 0)\n" > "$goal"
run_check "$goal"
chk_eq "[R3] FALSE-POSITIVE GUARD: bare english returned-N proof is silent" "" "$out"

printf "$ok## Done When\n- [ ] 表与注册表一致\n" > "$goal"
run_check "$goal"
chk_contains "[R3] SECTION CASE: '## Done When' is still in scope" "断言内部一致" "$out"

printf '# no preflight\n## Done when\n- [ ] 断言表与注册表一致\n' > "$goal"
run_check "$goal"
chk_eq "GATE PRECEDENCE: a hard failure still rejects" 1 "$rc"
chk_not_contains "GATE PRECEDENCE: and the advisory does not speak over it" "断言内部一致" "$out"

# [F1] inline （…）/(…) annotation on the keyword and a full-width colon are legitimate
# declaration shapes — rejecting them taught goal authors to move load-bearing notes
# off the line (field friction, upstream seat)
printf 'Preflight（编排者已实跑；worker 复跑）: query metrics => 3 rows observed\n' > "$goal"
run_check "$goal"
chk_eq "[F1] annotated keyword accepted" 0 "$rc"

printf 'Preflight (orchestrator ran): query metrics => 3 rows observed\n' > "$goal"
run_check "$goal"
chk_eq "[F1] ascii-paren annotation accepted" 0 "$rc"

printf 'Preflight：query metrics => 3 rows observed\n' > "$goal"
run_check "$goal"
chk_eq "[F1] full-width colon accepted" 0 "$rc"

printf 'Preflight: a probe => 1 row\nPreflight（re）: b probe => 2 rows\n' > "$goal"
run_check "$goal"
chk_eq "[F1] exactly-one still enforced across the widened shape" 1 "$rc"

printf 'Preflight（编排者已实跑）: <cheapest probe> => <observed result>\n' > "$goal"
run_check "$goal"
chk_eq "[F1] placeholder still rejected behind an annotation" 1 "$rc"

rm -rf "$SANDBOX"
summary
