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

# the annotation surface itself is part of the declaration — a placeholder hiding
# there is just as unresolved (cold-review catch on the first widening)
printf 'Preflight（<编排者补跑>）: query metrics => 3 rows observed\n' > "$goal"
run_check "$goal"
chk_eq "[F1] placeholder INSIDE full-width annotation rejected" 1 "$rc"

printf 'Preflight (<orchestrator note>): query metrics => 3 rows observed\n' > "$goal"
run_check "$goal"
chk_eq "[F1] placeholder INSIDE ascii annotation rejected" 1 "$rc"

# --- absence-claim scope declaration (2026-08-17, external-seat n=6 field shape) ----------
# known-positive recall: the real incident line (generalized) — absence claim, scope only in
# the author's head → reject
printf 'Preflight: 已用带已知阳性的负对照证明自有源码对这 4 个包零引用 => 可删\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] incident line rejected (absence claim, no scope)" 1 "$rc"
chk_contains "[SCOPE] error names the disease" "扫描面" "$out"

printf 'Preflight: rg -l langpkg src/ flask_app/ 零引用（scope=全部启动路径目录）=> 可删\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] path tokens satisfy the declaration" 0 "$rc"

printf 'Preflight: 全仓 rg 证明该 flag 零引用 => 可删\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] whole-repo word satisfies the declaration" 0 "$rc"

printf 'Preflight: zero references to the retired endpoint => remove it\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] english absence claim without scope rejected" 1 "$rc"

# negative control: ordinary negative observation is NOT an absence-over-corpus claim
printf "Preflight: jq 'length > 0' metrics.json => no rows hit the cap\n" > "$goal"
run_check "$goal"
chk_eq "[SCOPE] plain negative observation untouched" 0 "$rc"

# review 2026-08-17 repros as standing assertions (B1 slash-text impostors + M4 zh point obs)
printf 'Preflight: checked https://example.com/x and found zero references => remove\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] URL does not impersonate a scan root" 1 "$rc"

printf 'Preflight: checked on 8/17 and found zero references => remove\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] date slash does not impersonate a scan root" 1 "$rc"

printf 'Preflight: curl -I localhost:3000 => 404，端点不存在\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] zh single-point negative observation untouched" 0 "$rc"

# R2 repros: absolute and dot-relative scan roots are legitimate declarations
printf 'Preflight: rg zero references under ./src/app => remove\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] dot-relative scan root accepted" 0 "$rc"

printf 'Preflight: rg zero references under /abs/repo/root => remove\n' > "$goal"
run_check "$goal"
chk_eq "[SCOPE] absolute scan root accepted" 0 "$rc"

# --- inherited-mechanism premise declaration (2026-08-28, field n=3) ----------------------
# Half-gate by construction: the semantic half ("was this claim re-probed against a live
# system?") needs provenance a regex cannot produce, so only DECLARATION SHAPE is judged —
# exactly the boundary the absence-scope check above already lives on. Optional: a goal with
# no inherited premise writes no line and is judged on nothing.
printf "$ok" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] absent line is not judged" 0 "$rc"
chk_eq "[PREMISE] and stays silent" "" "$out"

printf "${ok}PREMISE: steer 投递即算一轮 verify=\`agentctl status s1\` 读 round => round=2，确认计数\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] a fully resolved declaration passes" 0 "$rc"
chk_eq "[PREMISE] and is silent" "" "$out"

printf "${ok}PREMISE: <claim> verify=<cmd> => <observed>\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] placeholders rejected" 1 "$rc"
chk_contains "[PREMISE] error names the line" "PREMISE 行(第 2 行)" "$out"
chk_contains "[PREMISE] and the disease" "占位符未解" "$out"

printf "${ok}PREMISE: stop 后 meta 留存 verify=<待补> => 已确认\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] a placeholder in the verify half alone is enough" 1 "$rc"

for unresolved in 'not run' pending unknown N/A TBD; do
  printf "${ok}PREMISE: 席位 cwd 可读 verify=ls run dir => %s\n" "$unresolved" > "$goal"
  run_check "$goal"
  chk_eq "[PREMISE] unresolved observation '$unresolved' rejected" 1 "$rc"
  chk_contains "[PREMISE] '$unresolved' error demands a live probe" "核过活体" "$out"
done
printf "${ok}PREMISE: 席位 cwd 可读 verify=TBD => 3 个席位命中\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] an unresolved verify half is rejected too" 1 "$rc"

# a keyword with no verify= / => is prose wearing a declaration's clothes
printf "${ok}PREMISE: duplex.meta 里有 cwd= 这个键\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] a declaration missing all three parts is rejected" 1 "$rc"
chk_contains "[PREMISE] error teaches the full shape" "verify=<cmd|live-probe>" "$out"
printf "${ok}PREMISE: duplex.meta 有 cwd= verify=grep cwd= meta\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] verify= without => rejected" 1 "$rc"
printf "${ok}PREMISE: verify= => observed\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] an empty claim is not a declaration" 1 "$rc"
chk_contains "[PREMISE] and says which part is missing" "三段都要有内容" "$out"

# list / checkbox / blockquote markers are how these actually get written
printf "${ok}- [ ] PREMISE: rc 文件缺失即活体 verify=live-probe 停一个席位 => rc 文件出现，tmux 消失\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] a checkbox row is a declaration" 0 "$rc"
printf "${ok}- [ ] PREMISE: rc 文件缺失即活体 verify=<待跑> => 未知\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] and is judged as one" 1 "$rc"
printf "${ok}> PREMISE: 全角冒号也算 verify=真跑 => 观察到 2 条\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] blockquote marker tolerated" 0 "$rc"
printf "${ok}PREMISE：全角冒号 verify=真跑 => 观察到 2 条\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] full-width colon accepted" 0 "$rc"

# EVERY declaration is judged, not just the first — a second, rotten one must not ride along
printf "${ok}PREMISE: a verify=cmd a => observed a\nPREMISE: b verify=<待补> => observed b\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] a rotten SECOND declaration still reds" 1 "$rc"
chk_contains "[PREMISE] and the reported line number is that one" "第 3 行" "$out"

# FALSE-POSITIVE GUARDS: prose that merely uses the word, and the goal-template heading
printf "${ok}我们的 premise: 这套机制早就核过了，见上文。\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] mid-sentence prose use is not a declaration" 0 "$rc"
printf "$ok## Premises\n- [ ] API schema 与已发布契约一致\n" > "$goal"
run_check "$goal"
chk_eq "[PREMISE] the goal-template 'Premises' heading is not a declaration" 0 "$rc"

# PRECEDENCE: a broken Preflight still answers first, and the PREMISE fault does not speak over it
printf '# no preflight\nPREMISE: x verify=<待补> => y\n' > "$goal"
run_check "$goal"
chk_eq "[PREMISE] Preflight failure keeps precedence" 1 "$rc"
chk_contains "[PREMISE] and it is the Preflight message" "expected exactly one" "$out"
chk_not_contains "[PREMISE] not the premise one" "PREMISE 行" "$out"

# ── R2 (cold review §3.1) unresolved forms with a TAIL ─────────────────────────────────────
# `N/A，待跑` and `TBD（待跑）` both counter-probed rc=0 against the tail-anchored version: the
# closed contract is "N/A/TBD 视为未解", and a full-width comma or a bracket is not evidence.
for tail in 'N/A，待跑' 'TBD（待跑）' 'TBD (pending the run)' 'n/a - nobody ran it' 'N/A：明天补'; do
  printf 'Preflight: query metrics => %s\n' "$tail" > "$goal"
  run_check "$goal"
  chk_eq "[R2-3.1] unresolved with a tail is still unresolved: $tail" 1 "$rc"
  chk_contains "[R2-3.1] and it is the unresolved verdict: $tail" "not evidence" "$out"
done
printf 'Preflight: N/A（还没跑） => 3 rows\n' > "$goal"
run_check "$goal"
chk_eq "[R2-3.1] the PROBE half is judged the same way" 1 "$rc"
printf "${ok}PREMISE: 机理断言 verify=真跑过 => TBD（待跑）\n" > "$goal"
run_check "$goal"
chk_eq "[R2-3.1] and so is a PREMISE observation" 1 "$rc"
chk_contains "[R2-3.1] naming the live-probe obligation" "核过活体" "$out"
# FALSE-POSITIVE GUARD — the reason the GENERIC words stay tail-anchored while N/A and TBD do
# not: a real observation may legitimately open with one of them.
printf 'Preflight: curl -s /health => no rows hit the cap, rc=0 实测\n' > "$goal"
run_check "$goal"
chk_eq "[R2-3.1] a real observation opening with 'no' still dispatches" 0 "$rc"
printf 'Preflight: probe => nap logs show 3 hits\n' > "$goal"
run_check "$goal"
chk_eq "[R2-3.1] and a word merely STARTING with n/a is not the token" 0 "$rc"

# ── R2 (cold review §3.2) the EMPTY placeholder ────────────────────────────────────────────
printf "${ok}PREMISE: claim verify=<> => observed\n" > "$goal"
run_check "$goal"
chk_eq "[R2-3.2] <> is an unresolved placeholder too" 1 "$rc"
chk_contains "[R2-3.2] and it is the placeholder verdict" "占位符未解" "$out"
printf 'Preflight: probe <> => observed\n' > "$goal"
run_check "$goal"
chk_eq "[R2-3.2] and on the Preflight line as well" 1 "$rc"
chk_contains "[R2-3.2] with the placeholder message" "replace every placeholder" "$out"

# ── R2 (cold review §4.4) THE INSTRUMENT: a goal this gate cannot read is never green ──────
# The third mutant this suite owed: the PREMISE battery could only fail on CONTENT, so a broken
# reader would have been invisible to it.
printf "${ok}PREMISE: 机理断言 verify=真跑过 => 观察到 2 条\n" > "$goal"
run_check "$goal"
chk_eq "[R2-4.4] control: this goal is green when readable" 0 "$rc"
chmod 000 "$goal"
run_check "$goal"
UNREADABLE_RC=$rc; UNREADABLE_OUT=$out
chmod 644 "$goal"
chk_eq "[R2-4.4] an unreadable goal exits 1, never 0" 1 "$UNREADABLE_RC"
chk_contains "[R2-4.4] and says the instrument could not read it" "cannot read goal" "$UNREADABLE_OUT"
chk_contains "[R2-4.4] in the ERR family with the doc pointer" "ERR: preflight gate:" "$UNREADABLE_OUT"
run_check "$SANDBOX"
chk_eq "[R2-4.4] a DIRECTORY handed in as the goal is not green either" 1 "$rc"
chk_contains "[R2-4.4] and reports the read failure" "cannot read goal" "$out"
run_check "$SANDBOX/no-such-goal.md"
chk_eq "[R2-4.4] a missing goal file is not green either" 1 "$rc"
run_check "$goal"
chk_eq "[R2-4.4] and the same goal, readable again, is green" 0 "$rc"

rm -rf "$SANDBOX"
summary
