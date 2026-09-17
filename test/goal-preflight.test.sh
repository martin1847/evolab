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
# AUTHORIZED EDIT (orchestrator ruling, fix round 1): this line used to pin SILENCE for a probe
# mixing prose with an inline-code span, from the era when the gate executed nothing at all.
# The premise changed: the shape is still never executed, but a visually opted-in command that is
# silently skipped reads to its author as verified, so it must now say 未执行 (review B1).
chk_contains "[PREMISE] and the mixed prose+span probe is reported as not run" "未执行（混排" "$out"

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

# ── premise probe EXECUTION ────────────────────────────────────────────────────────────────
# A probe written as ONE inline-code span is the author's per-line opt-in: the gate runs it
# verbatim (shell, cwd = the seat cwd, GOAL_PREFLIGHT_TIMEOUT seconds) and compares the
# author's own `rc=` / `count=` markers against the live reading (count = non-empty STDOUT
# lines). Only a self-declared contradiction blocks: no markers = no verdict, a timeout or an
# unrunnable command = WARN, and a shape fault = nothing in the batch is executed at all.
run_at(){ # $1 seat cwd  $2 goal — stderr captured APART from stdout
  err="$(GOAL_PREFLIGHT_CWD="$1" "$CHECK" "$2" 2>&1 >/dev/null)"; rc=$?
}
ran(){ [ -e "$1" ] && echo ran || echo absent; }   # side effects asserted, never assumed
seat="$SANDBOX/seat"; elsewhere="$SANDBOX/elsewhere"; mkdir -p "$seat" "$elsewhere"

# ① the disease this gate exists for: a declared count the command itself refutes
printf "${ok}PREMISE: 只有一行输出 verify=\`echo one\` => count=2 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ① a refuted count= declaration reds" 1 "$rc"
chk_contains "[EXEC] ① and names declared vs got" "declared count=2, got count=1" "$err"
chk_contains "[EXEC] ① pointing at the contract" "goal-template.md §Premises" "$err"

# ② negative control: the same probe carrying the markers it really produces
printf "${ok}PREMISE: 只有一行输出 verify=\`echo one\` => count=1 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ② a declaration the run confirms passes" 0 "$rc"
chk_eq "[EXEC] ② and stays silent" "" "$err"

# ③ no markers → the gate judges nothing and prints what it saw
printf "${ok}PREMISE: 只有一行输出 verify=\`echo one\` => 观察到一行\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ③ a marker-free observation is not judged" 0 "$rc"
chk_contains "[EXEC] ③ but the live reading is reported" "rc=0 count=1" "$err"
chk_contains "[EXEC] ③ and says why it did not judge" "未声明记号，只报实况" "$err"

# ④ a probe that is not a command is never executed — asserted by side effect, not by belief
printf "${ok}PREMISE: 停席位即出 rc 文件 verify=live-probe: touch %s/live-ran 停一个席位 => rc 文件出现\n" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ④ a live-probe recipe does not dispatch a shell" 0 "$rc"
chk_eq "[EXEC] ④ and left no side effect" absent "$(ran "$seat/live-ran")"
chk_contains "[EXEC] ④ saying it was not run" "未执行（非命令形态）" "$err"

# ⑤ shape first: a placeholder row rejects and NOTHING in the batch runs (side-effect probe)
printf "${ok}PREMISE: 可执行的一条 verify=\`touch %s/batch-ran\` => count=0 rc=0\nPREMISE: 占位符一条 verify=\`touch %s/ph-ran <待补>\` => count=0 rc=0\n" "$seat" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ⑤ a placeholder row still rejects" 1 "$rc"
chk_contains "[EXEC] ⑤ on shape, before any execution" "占位符未解" "$err"
chk_eq "[EXEC] ⑤ and no probe in the batch ran" "absent absent" \
  "$(ran "$seat/batch-ran") $(ran "$seat/ph-ran")"

# ⑤b an unresolved row is the same class: judged on shape, never executed
printf "${ok}PREMISE: 可执行的一条 verify=\`touch %s/unres-ran\` => count=0 rc=0\nPREMISE: 未解一条 verify=TBD => 未知\n" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ⑤b an unresolved row rejects too" 1 "$rc"
chk_eq "[EXEC] ⑤b with nothing executed" absent "$(ran "$seat/unres-ran")"

# ⑥ a probe that outruns the budget WARNs and never blocks a dispatch
printf "${ok}PREMISE: 慢探针 verify=\`python3 -c 'import time; time.sleep(9)'\` => rc=0\n" > "$goal"
export GOAL_PREFLIGHT_TIMEOUT=1
run_at "$seat" "$goal"
unset GOAL_PREFLIGHT_TIMEOUT
chk_eq "[EXEC] ⑥ a timed-out probe never blocks" 0 "$rc"
chk_contains "[EXEC] ⑥ and is reported as a timeout" "超时" "$err"

# ⑥b nor does a command this machine cannot run at all
printf "${ok}PREMISE: 缺失的二进制 verify=\`no-such-binary-xyz42\` => count=1 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ⑥b an unrunnable command never blocks" 0 "$rc"
chk_contains "[EXEC] ⑥b and is reported as unrunnable" "无法执行" "$err"

# ⑦ cwd semantics: one relative probe, two seat cwds, two answers
: > "$seat/marker-in-cwd"
printf "${ok}PREMISE: 席位 cwd 有 marker verify=\`test -f marker-in-cwd\` => rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] ⑦ a relative probe resolves against the seat cwd" 0 "$rc"
run_at "$elsewhere" "$goal"
chk_eq "[EXEC] ⑦ and refutes the same declaration from another cwd" 1 "$rc"
chk_contains "[EXEC] ⑦ naming the cwd it ran in" "$elsewhere" "$err"

# BOUNDARY: an inline-code FRAGMENT inside prose is a citation, not a runnable probe — never
# executed, but always announced as not run (review 2026-09-10 B1 replaced the earlier silence).
printf "${ok}PREMISE: 混形态 verify=\`touch %s/mixed-ran\` 读 round => round=2\n" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] BOUNDARY: an inline-code fragment inside prose is not a probe" 0 "$rc"
chk_eq "[EXEC] BOUNDARY: it does not run" absent "$(ran "$seat/mixed-ran")"
chk_contains "[EXEC] BOUNDARY: and it says it was not run" "未执行（混排 / 多段反引号" "$err"

# LINE NUMBERS are what an operator opens: a row written the way goals really write it (section
# heading, blank line, list marker + checkbox) must report ITS line, not the blank one above it.
printf "${ok}## Premises\n\n- [ ] PREMISE: 执行判决报行号 verify=\`echo one\` => count=2 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] LINE NUMBER: a row under a section break still reds" 1 "$rc"
chk_contains "[EXEC] LINE NUMBER: and the exec verdict names its own line" "PREMISE 行(第 4 行)" "$err"
printf "${ok}## Premises\n\n- [ ] PREMISE: 形态判决报行号 verify=<待补> => 未知\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] LINE NUMBER: the shape verdict reds on the same row" 1 "$rc"
chk_contains "[EXEC] LINE NUMBER: and numbers it the same way" "PREMISE 行(第 4 行)" "$err"

# ── review 2026-09-10 fix round 1 ───────────────────────────────────────────────────────────
# B1: several spans, or one span mixed into prose, is not runnable as written. Silence is the
# worst of the three answers — the author opted in visibly — so the gate refuses AND says why.
printf "${ok}PREMISE: 多段 verify=\`touch %s/multi-a\` and \`touch %s/multi-b\` => rc=1\n" "$seat" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] B1 a multi-span probe never blocks a dispatch" 0 "$rc"
chk_eq "[EXEC] B1 and neither span ran" "absent absent" \
  "$(ran "$seat/multi-a") $(ran "$seat/multi-b")"
chk_contains "[EXEC] B1 but it is reported as not run" "未执行（混排 / 多段反引号" "$err"
chk_contains "[EXEC] B1 telling the author how to opt in" "放进一个反引号段" "$err"
printf "${ok}PREMISE: 非命令 verify=live-probe: 停一个席位 => rc 文件出现\n" > "$goal"
run_at "$seat" "$goal"
chk_not_contains "[EXEC] B1 a span-free probe keeps its own wording" "混排" "$err"

# M1: `count` counts non-empty STDOUT lines and the probe's own stderr is dropped. One probe
# writing to BOTH streams is what tells the two implementations apart: count=1 passes, count=2
# reds — a regression that folded stderr into the count would flip exactly these two.
printf '#!/bin/sh\nprintf "out\\n"\nprintf "err\\n" >&2\n' > "$seat/two-streams.sh"
chmod +x "$seat/two-streams.sh"
printf "${ok}PREMISE: 只数 stdout verify=\`./two-streams.sh\` => count=1 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M1 one stdout line and one stderr line count as count=1" 0 "$rc"
chk_eq "[EXEC] M1 and the passing declaration is silent" "" "$err"
printf "${ok}PREMISE: 不数 stderr verify=\`./two-streams.sh\` => count=2 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M1 declaring both streams is refuted" 1 "$rc"
chk_contains "[EXEC] M1 naming the stdout-only reading" "declared count=2, got count=1" "$err"

# M2: each marker at most ONCE. The comparison consumes one value per marker, so a repeated one
# would be judged on whichever half came first and the author's own conflict would go unseen.
printf "${ok}PREMISE: 记号重复 verify=\`true\` => prior rc=1; now rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M2 a repeated rc= marker is rejected" 1 "$rc"
chk_contains "[EXEC] M2 as a duplicate declaration" "记号重复：rc= 出现 2 次，只能声明一次" "$err"
chk_not_contains "[EXEC] M2 not judged by the first hit" "declared rc=1" "$err"
chk_contains "[EXEC] M2 pointing at the contract" "goal-template.md" "$err"
printf "${ok}PREMISE: 记号重复 verify=\`echo one\` => count=1 count=2 rc=0\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M2 a repeated count= marker too" 1 "$rc"
chk_contains "[EXEC] M2 naming which marker repeated" "记号重复：count= 出现 2 次" "$err"
printf "${ok}PREMISE: 可执行的一条 verify=\`touch %s/dup-ran\` => count=0 rc=0\nPREMISE: 记号重复 verify=\`true\` => rc=0 也许 rc=1\n" "$seat" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M2 duplication is a shape fault, so nothing in the batch ran" absent \
  "$(ran "$seat/dup-ran")"
printf "${ok}PREMISE: 各一次 verify=\`echo one\` => count=1 rc=0（src=0 recount=2 不是记号）\n" > "$goal"
run_at "$seat" "$goal"
chk_eq "[EXEC] M2 NEGATIVE CONTROL: one of each still passes, impostors do not count" 0 "$rc"

# M3: the deadline knob takes a POSITIVE FINITE number of seconds. `nan` parses as a legal float
# and then makes every communicate() deadline comparison false — no deadline at all, i.e. the
# dispatch gate becomes hangable again (review 2026-09-10 M3: `nan` + `sleep 30` never returned).
# Driven through the CLI only (white-box dynamic loading is banned, loc-budget check 6), so the
# fallback is asserted where an operator sees it: the WARN names the rejected value AND the
# seconds it fell back to, and the batch still gets its verdict. That the fallback is a REAL
# deadline is pinned by the CONTROL below plus the 120s live proof recorded in findings.
printf "${ok}PREMISE: 快探针 verify=\`echo one\` => count=1 rc=0\n" > "$goal"
for bad in nan -nan inf -inf 0 -0.0 -1 abc; do
  export GOAL_PREFLIGHT_TIMEOUT="$bad"
  run_at "$seat" "$goal"
  unset GOAL_PREFLIGHT_TIMEOUT
  chk_eq "[EXEC] M3 GOAL_PREFLIGHT_TIMEOUT=$bad still yields the batch verdict" 0 "$rc"
  chk_contains "[EXEC] M3 =$bad WARNs with the value and the fallback it used" \
    "GOAL_PREFLIGHT_TIMEOUT=$bad 不是正的有限秒数，回退默认 120s" "$err"
done
# NEGATIVE CONTROL: a legitimate value is never warned about, and the passing probe stays silent
export GOAL_PREFLIGHT_TIMEOUT=5
run_at "$seat" "$goal"
unset GOAL_PREFLIGHT_TIMEOUT
chk_eq "[EXEC] M3 a valid knob is silent" "" "$err"
run_at "$seat" "$goal"
chk_eq "[EXEC] M3 and so is an unset knob" "" "$err"
# (the sandbox PATH holds a no-op `sleep` shim, so a real delay must come from python3 — ⑥ same)
printf "${ok}PREMISE: 慢探针 verify=\`python3 -c 'import time; time.sleep(9)'\` => rc=0\n" > "$goal"
export GOAL_PREFLIGHT_TIMEOUT=1
run_at "$seat" "$goal"
unset GOAL_PREFLIGHT_TIMEOUT
chk_contains "[EXEC] M3 CONTROL: a finite deadline is still enforced" "超时 1s" "$err"

# MINOR 1: the supported PREMISE prefix set, stated. ASCII horizontal indentation (space / Tab)
# and the list markers are declarations; a form-feed / VT / NBSP prefix is not read as one (the
# pre-fix `\s` class matched them — accepted narrowing, goals indent with spaces and Tabs).
printf "${ok}   PREMISE: 空格缩进 verify=<待补> => 未知\n" > "$goal"
run_check "$goal"
chk_eq "[PREFIX] a space-indented row IS a declaration" 1 "$rc"
printf "${ok}\tPREMISE: Tab 缩进 verify=<待补> => 未知\n" > "$goal"
run_check "$goal"
chk_eq "[PREFIX] a Tab-indented row IS a declaration" 1 "$rc"
for exotic in '\f' '\v' '\302\240'; do
  printf "${ok}${exotic}PREMISE: 非常规空白 verify=<待补> => 未知\n" > "$goal"
  run_check "$goal"
  chk_eq "[PREFIX] unsupported whitespace prefix ($exotic) is not read as a declaration" 0 "$rc"
done
# CR is NOT in that family, and a regex-only probe cannot see why: the gate reads the goal in
# TEXT mode, so Python's universal-newline translation turns a lone \r into \n before the regex
# runs — the row lands on its own line and IS judged, numbered as that line.
printf "${ok}\rPREMISE: CR 前缀 verify=<待补> => 未知\n" > "$goal"
run_check "$goal"
chk_eq "[PREFIX] a lone CR is a line break, so the row IS judged" 1 "$rc"
chk_contains "[PREFIX] and numbered as its own line" "第 3 行" "$out"

# ── live-tree probe morphology (2026-09-13, field n=4 in four days across two seats) ───────
# A premise probe reading a path THIS goal will change declares a reading its own deliverable
# flips: own repo 2026-09-10 (LESSON premise-anchored-to-live-tree) plus three downstream fix
# rounds on 2026-09-13. WARN-only by owner ruling — a deliberate "must still hold AFTER
# delivery" invariant wears the identical shape, so rc must never move. Three states pinned:
# bad sample WARNs (①④), good samples stay silent (②③⑥), broken gauge neither blocks nor
# crashes (illegal env, missing write-set section).
lp_run(){ # $1 goal  [$2 GOAL_PREFLIGHT_DELIVERABLE — unset when the arg is absent]
  if [ "$#" -ge 2 ]; then
    err="$(GOAL_PREFLIGHT_CWD="$seat" GOAL_PREFLIGHT_DELIVERABLE="$2" "$CHECK" "$1" 2>&1 >/dev/null)"; rc=$?
  else
    err="$(GOAL_PREFLIGHT_CWD="$seat" "$CHECK" "$1" 2>&1 >/dev/null)"; rc=$?
  fi
}
lp_goal(){ # $1 PREMISE row (lands on line 3)  $2 Task / Deliverables item (line 5)
  printf "${ok}## Premises\n%s\n## Task / Deliverables\n%s\n" "$1" "$2" > "$goal"
}
LIVE='活树探针命中本 goal 写集路径'
mkdir -p "$seat/docs" "$elsewhere/docs"
printf 'k here\n' > "$seat/docs/x.md"          # so the declared count=1 rc=0 is the TRUE reading
printf 'nothing\n' > "$seat/docs/other.md"     # …and count=0 rc=1 outside the write set
printf 'k here\n' > "$elsewhere/docs/x.md"     # same file name, another tree (⑥)

# ① the disease itself: write-set path, live tree, no pinned anchor
lp_goal 'PREMISE: k 还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_contains "[LIVE] ① a live-tree probe on a write-set path WARNs" "$LIVE" "$err"
chk_contains "[LIVE] ① naming the line an operator opens" "PREMISE 行(第 3 行)" "$err"
chk_contains "[LIVE] ① and the path it reads" "docs/x.md" "$err"
chk_contains "[LIVE] ① handing over the pinned shape" "git show <base sha>:docs/x.md" "$err"
# ⑦ the ruling: WARN never moves rc — an intentional post-delivery invariant wears this shape
chk_eq "[LIVE] ⑦ rc stays 0 while the WARN is on stderr" 0 "$rc"

# ② the same claim anchored to a pinned revision cannot flip, so it is never reported
lp_goal 'PREMISE: base 里有 k verify=`git show 0000000:docs/x.md | grep -n k` => 观察到一行' \
  '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_not_contains "[LIVE] ② a pinned-base probe is silent" "$LIVE" "$err"
chk_eq "[LIVE] ② and still dispatches" 0 "$rc"

# ③ a live-tree probe on a path this goal does NOT touch is nobody's business
lp_goal 'PREMISE: other 里没有 k verify=`grep -n k docs/other.md` => count=0 rc=1' \
  '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_not_contains "[LIVE] ③ a path outside the write set is silent" "$LIVE" "$err"
chk_eq "[LIVE] ③ and dispatches" 0 "$rc"

# ④ the lane's own --deliverable glob is the second write-set source: a goal whose Task section
# names no path at all is still judged against what the dispatch declared it would produce
lp_goal 'PREMISE: k 还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 改文档里那一行'
lp_run "$goal"
chk_not_contains "[LIVE] ④ CONTROL: no declared path, nothing to hit" "$LIVE" "$err"
lp_run "$goal" 'docs/*.md'
chk_contains "[LIVE] ④ GOAL_PREFLIGHT_DELIVERABLE glob makes it a write-set hit" "$LIVE" "$err"
chk_contains "[LIVE] ④ naming the probe's own path, not the glob" "docs/x.md" "$err"
chk_eq "[LIVE] ④ and still never blocks" 0 "$rc"
# ⑧ an empty variable is not a setting — byte-identical to an unset one
lp_run "$goal"; lp_unset_err="$err"
lp_run "$goal" ""
chk_eq "[LIVE] ⑧ an empty GOAL_PREFLIGHT_DELIVERABLE equals an unset one" "$lp_unset_err" "$err"
chk_eq "[LIVE] ⑧ and neither invents a hit" 0 "$rc"

# a write-set entry naming a DIRECTORY covers what lives under it (the declared 口径: equality,
# under a declared dir, or glob — never by basename)
lp_goal 'PREMISE: 入口还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 重写 `docs/legacy` 目录'
lp_run "$goal"
chk_not_contains "[LIVE] DIR: a sibling directory is not a hit" "$LIVE" "$err"
lp_goal 'PREMISE: 入口还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 重写 `docs/api` 目录'
lp_run "$goal" 'docs/x.md'
chk_contains "[LIVE] DIR: and the declared path itself still hits" "$LIVE" "$err"

# ⑤ the same predicate on the REJECTION path: a refuted reading whose path this goal rewrites
# is most often the live-tree shape, so the ERR says so instead of leaving the author to guess
lp_goal 'PREMISE: 五行 k verify=`grep -n k docs/x.md` => count=5 rc=0' '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_eq "[LIVE] ⑤ a refuted declaration still reds" 1 "$rc"
chk_contains "[LIVE] ⑤ with the existing verdict" "declared count=5, got count=1" "$err"
chk_contains "[LIVE] ⑤ plus the write-set hint" "该路径在本 goal 写集内" "$err"
lp_goal 'PREMISE: 五行 k verify=`grep -n k docs/other.md` => count=5 rc=1' '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_eq "[LIVE] ⑤ a refuted declaration outside the write set reds the same" 1 "$rc"
chk_not_contains "[LIVE] ⑤ but carries no write-set hint" "该路径在本 goal 写集内" "$err"

# ⑥ known negatives: a URL, a date/ratio slash, and an absolute path in ANOTHER tree
lp_goal 'PREMISE: 文档地址 verify=`echo https://example.com/docs/x.md` => count=1 rc=0' \
  '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_not_contains "[LIVE] ⑥ a URL does not impersonate a write-set path" "$LIVE" "$err"
lp_goal 'PREMISE: 跑分 verify=`echo 8/17` => count=1 rc=0' '1. 改 `docs/x.md` 加一行'
lp_run "$goal"
chk_not_contains "[LIVE] ⑥ nor does a bare ratio" "$LIVE" "$err"
printf "${ok}## Premises\nPREMISE: 别的树 verify=\`grep -n k %s/docs/x.md\` => count=1 rc=0\n## Task / Deliverables\n1. 改 \`docs/x.md\` 加一行\n" "$elsewhere" > "$goal"
lp_run "$goal"
chk_not_contains "[LIVE] ⑥ an absolute path outside the seat tree is not this write set" "$LIVE" "$err"
chk_eq "[LIVE] ⑥ and nothing crashed" 0 "$rc"
chk_not_contains "[LIVE] ⑥ no traceback" Traceback "$err"
# …while the SAME file named absolutely INSIDE the seat tree is the disease, normalized
printf "${ok}## Premises\nPREMISE: 席位树 verify=\`grep -n k %s/docs/x.md\` => count=1 rc=0\n## Task / Deliverables\n1. 改 \`docs/x.md\` 加一行\n" "$seat" > "$goal"
lp_run "$goal"
chk_contains "[LIVE] ⑥ an absolute path INSIDE the seat tree normalizes and hits" "$LIVE" "$err"
chk_contains "[LIVE] ⑥ reported repo-relative, not as typed" "写集路径 docs/x.md" "$err"

# the gauge itself: an unusable variable and a goal with no write-set section are both answered
# with silence-or-one-line, never a crash and never a refusal
lp_goal 'PREMISE: k 还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 改文档里那一行'
lp_run "$goal" "$elsewhere/*.md"
chk_eq "[LIVE] GAUGE: a deliverable glob outside the seat tree never blocks" 0 "$rc"
chk_contains "[LIVE] GAUGE: and says the variable was unusable" "归一不到席位树内路径" "$err"
chk_not_contains "[LIVE] GAUGE: without inventing a hit" "$LIVE" "$err"
printf "${ok}## Premises\nPREMISE: k 还在 verify=\`grep -n k docs/x.md\` => count=1 rc=0\n" > "$goal"
lp_run "$goal"
chk_eq "[LIVE] GAUGE: a goal with no Task / Deliverables section dispatches" 0 "$rc"
chk_not_contains "[LIVE] GAUGE: with an empty write set nothing can hit" "$LIVE" "$err"
chk_not_contains "[LIVE] GAUGE: and no traceback" Traceback "$err"

# ── fix round 1 (2026-09-13, cold review REVIEW_LIVE_PROBE_WARN_codex) ─────────────────────
# Four WARN-precision defects, each kept here as the minimal goal that WARNed on c161a49 and
# must not now. PRECISION only: nothing below widens recall, and ⑧ re-pins rc on every row —
# a false WARN costs the layer its 误 WARN ≤1/week kill criterion just as surely as a miss.
# ① an abbreviation is not a filename: a one-character run after the dot is not an extension
lp_goal 'PREMISE: 缩写 verify=`echo e.g.` => count=1 rc=0' 'Use e.g. for examples.'
lp_run "$goal"
chk_not_contains '[LIVE-FIX] ① e.g. is not a write-set path' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ① rc unmoved' 0 "$rc"
# ② nor is a version number: its dotted runs carry no letter
lp_goal 'PREMISE: 版本 verify=`echo v1.7.10` => count=1 rc=0' '1. 把依赖升到 v1.7.10'
lp_run "$goal"
chk_not_contains '[LIVE-FIX] ② a version number is not a write-set path' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ② rc unmoved' 0 "$rc"
# ③ bold markers are stripped in PAIRS — the leading ** used to reach fnmatch as a glob and
# swallow every sibling directory, so a path the goal never declared came back as a hit
lp_goal 'PREMISE: 别的树 verify=`echo otherdocs/x.md` => count=1 rc=0' '**docs/x.md**'
lp_run "$goal"
chk_not_contains '[LIVE-FIX] ③ bold write set does not glob over a sibling directory' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ③ negative rc unmoved' 0 "$rc"
lp_goal 'PREMISE: 入口还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '**docs/x.md**'
lp_run "$goal"
chk_contains '[LIVE-FIX] ③ CONTROL: the bolded path itself still hits' "$LIVE" "$err"
chk_contains '[LIVE-FIX] ③ named without its bold markers' "写集路径 docs/x.md" "$err"
chk_eq '[LIVE-FIX] ⑧ ③ positive rc unmoved' 0 "$rc"
# ④ the write set is what the goal will CHANGE: a title merely containing "Task" read an
# exclusion section as a declaration and reported the paths the goal swore off
printf "${ok}## Premises\nPREMISE: 入口还在 verify=\`grep -n k docs/x.md\` => count=1 rc=0\n## Out of scope / Tasks not done\ndocs/x.md\n" > "$goal"
lp_run "$goal"
chk_not_contains '[LIVE-FIX] ④ an out-of-scope section is not a write set' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ④ rc unmoved' 0 "$rc"
printf "${ok}## Premises\nPREMISE: 入口还在 verify=\`grep -n k docs/x.md\` => count=1 rc=0\n## 2. Deliverables\ndocs/x.md\n" > "$goal"
lp_run "$goal"
chk_contains '[LIVE-FIX] ④ CONTROL: a numbered Deliverables title still declares one' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ④ control rc unmoved' 0 "$rc"
# ⑤ the anchor is morphology at any distance: a long `git -C <path> show <rev>:` reads a
# committed object exactly like the short form, and the old 40-character window missed it
lp_goal 'PREMISE: base 里有 README verify=`git -C /tmp/no-such-tree/a/b/c/d/e/f/g/h/i/j/k/l/m show HEAD:README.md` => count=0 rc=128' \
  '1. 改 `README.md` 加一行'
lp_run "$goal"
chk_not_contains '[LIVE-FIX] ⑤ a long -C path is still a pinned anchor' "$LIVE" "$err"
chk_eq '[LIVE-FIX] ⑧ ⑤ rc unmoved' 0 "$rc"
# ⑥ a directory is also written with a trailing slash
lp_goal 'PREMISE: 入口还在 verify=`grep -n k docs/x.md` => count=1 rc=0' '1. 重写 `docs/` 下的全部文档'
lp_run "$goal"
chk_contains '[LIVE-FIX] ⑥ a trailing-slash directory covers what lives under it' "$LIVE" "$err"
chk_contains '[LIVE-FIX] ⑥ naming the probe path, not the directory' "写集路径 docs/x.md" "$err"
chk_eq '[LIVE-FIX] ⑧ ⑥ rc unmoved' 0 "$rc"
# ⑦ the real directory-prefix positive the DIR row above never exercised: the write set names
# a directory and the probe reads a file UNDER it, with no --deliverable glob to lean on
lp_goal 'PREMISE: 接口文档还在 verify=`echo docs/api/x.md` => count=1 rc=0' '1. 重写 `docs/api` 目录'
lp_run "$goal"
chk_contains '[LIVE-FIX] ⑦ a file under a declared directory is a hit' "$LIVE" "$err"
chk_contains '[LIVE-FIX] ⑦ named as the probe reads it' "写集路径 docs/api/x.md" "$err"
chk_eq '[LIVE-FIX] ⑧ ⑦ rc unmoved' 0 "$rc"

# ── --claims: the governance-document claim census ─────────────────────────────────────────
# Same PREMISE contract, new consumer: the retro instead of the dispatcher. A governance fact
# sentence can only be re-checked by a human, so "整篇重写" degrades into transcription plus a
# fresh timestamp and the wrong sentence gains that freshness as endorsement. What is pinned
# below is the four ways this mode DIFFERS from the goal mode (no Preflight line required,
# every DEAD reported, a bad row does not hide the others, a weak-assertion share) plus the
# unchanged halves it inherits (未判 wording, shape-before-execution, marker comparison).
claims_run(){ # $@ = doc paths — probes run in $seat, stderr captured APART from stdout
  err="$(GOAL_PREFLIGHT_CWD="$seat" "$CHECK" --claims "$@" 2>&1 >/dev/null)"; rc=$?
}
cdoc="$SANDBOX/gov.md"; cdoc2="$SANDBOX/gov2.md"
: > "$seat/live-file"

# ① a claim its own probe confirms: rc 0, and the census line is the ONLY thing printed
printf 'PREMISE: 只有一行输出 verify=`echo one` => count=1 rc=0\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ① a confirmed claim passes" 0 "$rc"
chk_eq "[CLAIMS] ① and prints only the census line" \
  "claims: 1 文件 1 条，DEAD 0，未判 0，弱断言 0（0%）" "$err"

# ② the disease: a declared reading the document's own command refutes
printf 'PREMISE: 两行输出 verify=`echo one` => count=2 rc=0\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ② a refuted claim reds" 1 "$rc"
chk_contains "[CLAIMS] ② as a DEAD line at file:line" "DEAD: $cdoc:1" "$err"
chk_contains "[CLAIMS] ② naming declared vs got" "declared rc=0 count=2, got rc=0 count=1" "$err"
chk_contains "[CLAIMS] ② and the command an operator re-runs" 'echo one' "$err"
chk_contains "[CLAIMS] ② counted in the census" "DEAD 1" "$err"

# ③ EVERY dead account, not the earliest sighting — a retro wants the census
printf 'PREMISE: a verify=`echo one` => count=2 rc=0\nPREMISE: b verify=`false` => rc=0\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ③ two refuted claims red" 1 "$rc"
chk_eq "[CLAIMS] ③ and BOTH are reported" 2 "$(printf '%s\n' "$err" | grep -c '^DEAD:')"
chk_contains "[CLAIMS] ③ the first row" "DEAD: $cdoc:1" "$err"
chk_contains "[CLAIMS] ③ the second row" "DEAD: $cdoc:2" "$err"

# ④ weak assertions: a probe proving only that a POINTER resolves cannot refute its sentence.
# Share over 40% WARNs, never reds — a pointer claim is sometimes exactly the claim.
{ printf 'PREMISE: w1 verify=`test -f live-file` => rc=0\n'
  printf 'PREMISE: w2 verify=`ls live-file` => rc=0\n'
  printf 'PREMISE: w3 verify=`stat live-file` => rc=0\n'
  printf 'PREMISE: s1 verify=`echo one` => count=1 rc=0\n'
  printf 'PREMISE: s2 verify=`grep -c x /dev/null` => rc=1\n'; } > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ④ a weak share never moves rc" 0 "$rc"
chk_contains "[CLAIMS] ④ 3/5 is warned" "弱断言占比 60% > 40%——只证指针在，不证事实成立" "$err"
chk_contains "[CLAIMS] ④ and counted in the census" "弱断言 3（60%）" "$err"
# 1/5 is under the line: counted, never warned. `test 1 = 1` is a real comparison, not an
# existence probe — the judgement is the first OPTION, so a test with none is never weak.
{ printf 'PREMISE: w1 verify=`[ -f live-file ]` => rc=0\n'
  printf 'PREMISE: s1 verify=`test 1 = 1` => rc=0\n'
  printf 'PREMISE: s2 verify=`echo one` => count=1 rc=0\n'
  printf 'PREMISE: s3 verify=`true` => rc=0\n'
  printf 'PREMISE: s4 verify=`false` => rc=1\n'; } > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ④ 1/5 still dispatches" 0 "$rc"
chk_not_contains "[CLAIMS] ④ and is not warned about" "弱断言占比" "$err"
chk_contains "[CLAIMS] ④ but is still counted" "弱断言 1（20%）" "$err"

# ⑤ a probe this machine could not finish says so and is 未判 — never a dead account
printf "PREMISE: 慢探针 verify=\`python3 -c 'import time; time.sleep(3)'\` => rc=0\n" > "$cdoc"
export GOAL_PREFLIGHT_TIMEOUT=1
claims_run "$cdoc"
unset GOAL_PREFLIGHT_TIMEOUT
chk_eq "[CLAIMS] ⑤ a timed-out probe never reds" 0 "$rc"
chk_contains "[CLAIMS] ⑤ with the inherited 未判 wording" "超时 1s，未判（不拒发）" "$err"
chk_contains "[CLAIMS] ⑤ and is counted as 未判, not DEAD" "DEAD 0，未判 1" "$err"

# ⑥ shape first: an unresolved row is an ERR and is never executed (side effect asserted)
printf 'PREMISE: 占位符 verify=`touch %s/ph-claims` => <待补>\n' "$seat" > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ⑥ a placeholder row is an ERR" 1 "$rc"
chk_contains "[CLAIMS] ⑥ named at file:line" "$cdoc:1 PREMISE 声明未成立" "$err"
chk_contains "[CLAIMS] ⑥ with the placeholder verdict" "占位符未解" "$err"
chk_eq "[CLAIMS] ⑥ and nothing ran" absent "$(ran "$seat/ph-claims")"
# ⑥b the deliberate difference from the goal mode: no dispatch is being held here, so one
# malformed row must not hide the OTHER rows' dead accounts
printf 'PREMISE: 占位符 verify=`true` => <待补>\nPREMISE: 死账 verify=`echo one` => count=2 rc=0\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ⑥b a malformed row still reds" 1 "$rc"
chk_contains "[CLAIMS] ⑥b and the other row is judged anyway" "DEAD: $cdoc:2" "$err"

# ⑦ several documents, each located in its own file at its own line
printf 'PREMISE: a verify=`echo one` => count=2 rc=0\n' > "$cdoc"
printf '# gov2\n\nPREMISE: b verify=`echo one` => count=3 rc=0\n' > "$cdoc2"
claims_run "$cdoc" "$cdoc2"
chk_eq "[CLAIMS] ⑦ both files red" 1 "$rc"
chk_contains "[CLAIMS] ⑦ the first file's row" "DEAD: $cdoc:1" "$err"
chk_contains "[CLAIMS] ⑦ the second file's own line" "DEAD: $cdoc2:3" "$err"
chk_contains "[CLAIMS] ⑦ census counts files and rows" "claims: 2 文件 2 条，DEAD 2" "$err"

# ⑧ the live-tree WARN is deliberately NOT in this mode: a governance claim reading the live
# tree is exactly what makes it falsifiable, and there is no write set to be anchored against
printf 'PREMISE: k 还在 verify=`grep -n k docs/x.md` => count=1 rc=0\n## Task / Deliverables\n1. 改 `docs/x.md` 加一行\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[CLAIMS] ⑧ a live-tree probe dispatches" 0 "$rc"
chk_not_contains "[CLAIMS] ⑧ and raises no write-set WARN" "$LIVE" "$err"

# ⑨ retro-check check 10 — opt-in skip, then the same dead claim reddening the retro gate
RETRO="$REPO_ROOT/skills/cto-orchestration/references/retro-check.sh"
rdocs="$SANDBOX/retro/docs"; mkdir -p "$rdocs"
RTODAY="$(date +%F)"
printf '# agents\n- 批 %s claims-fixture：绿基线 wall=1m avoidable=0m\n' "$RTODAY" > "$SANDBOX/retro/AGENTS.md"
retro_run(){ out="$( cd "$SANDBOX/retro" && AGENT_WATCH_DIR="$SANDBOX/retro/.none" \
  bash "$RETRO" --docs docs 2>&1 )"; rc=$?; }
printf 'Last rewritten: %s\n' "$RTODAY" > "$rdocs/ACTIVE_CONTEXT.md"
retro_run
chk_eq "[CLAIMS] ⑨ docs with no PREMISE line keep the retro gate green" 0 "$rc"
chk_contains "[CLAIMS] ⑨ and check 10 says it skipped" "[skip] no PREMISE claims in docs (opt-in)" "$out"
printf 'PREMISE: 仓根有 NOPE.md verify=`test -f NOPE.md` => rc=0\n' >> "$rdocs/ACTIVE_CONTEXT.md"
retro_run
chk_eq "[CLAIMS] ⑨ one dead claim reds the retro gate" 1 "$rc"
chk_contains "[CLAIMS] ⑨ as a FAIL line" "[FAIL] 1 dead claim(s)" "$out"
chk_contains "[CLAIMS] ⑨ with the DEAD line passed through" "ACTIVE_CONTEXT.md:2" "$out"
printf 'Last rewritten: %s\nPREMISE: docs 里有 ACTIVE_CONTEXT verify=`test -f docs/ACTIVE_CONTEXT.md` => rc=0\n' \
  "$RTODAY" > "$rdocs/ACTIVE_CONTEXT.md"
retro_run
chk_eq "[CLAIMS] ⑨ a live claim keeps it green" 0 "$rc"
chk_contains "[CLAIMS] ⑨ counted as zero dead accounts" "PREMISE 行 0 DEAD" "$out"
chk_contains "[CLAIMS] ⑨ and the WARN is passed through verbatim" "WARN: preflight: 弱断言占比 100%" "$out"

# ⑩ the echo this batch fixed: `.rc` is written by the pane after the engine returns, so a
# stop that kills the pane never leaves one — the unconditional promise was a dead claim
WATCHCTL="$REPO_ROOT/skills/cto-orchestration/references/agentctl/watchctl.py"
chk_eq "[CLAIMS] ⑩ stop names .rc as conditional" 1 \
  "$(grep -c 'only when the engine exited on its own' "$WATCHCTL")"
chk_eq "[CLAIMS] ⑩ and no longer lists it unconditionally" 0 \
  "$(grep -c 'stderr\.log, \.rc,' "$WATCHCTL")"

# ── tier declaration + goal-review receipt (2026-09-17, field n=3/3 in one dispatch) ───────
# The disease: three goals wrote 「档位：深档」 in their own header prose and goal-review ran
# zero times; the one goal in that same dispatch that faced a MACHINE gate (the missing
# Preflight line) complied on the spot. So the tier declaration moves onto a parsed line and a
# deep goal with no receipt is told once. WARN-only by owner ruling (a legitimate skip exists),
# opt-in by absence (no `Tier:` line ⇒ nothing judged, so no existing goal changes behaviour).
TIERW='深档 goal 无 goal-review 回执'
tier_run(){ err="$("$CHECK" "$1" 2>&1 >/dev/null)"; rc=$?; }

# ① the disease itself: a deep goal carrying no receipt at all
printf "${ok}Tier: deep\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ① a deep goal with no receipt still dispatches" 0 "$rc"
chk_contains "[TIER] ① and is told once" "$TIERW" "$err"
chk_contains "[TIER] ① naming the line to write" 'Goal-Review: <路径>' "$err"
chk_contains "[TIER] ① and the exemption form" 'Goal-Review: SKIPPED: <理由>' "$err"
chk_contains "[TIER] ① pointing at the owning contract" "review-dispatch §goal-review" "$err"
chk_eq "[TIER] ① exactly one line, never a wall" 1 "$(printf '%s\n' "$err" | grep -c "$TIERW")"

# ② a receipt PATH closes it — existence is deliberately not judged (the receipt may live in
# another tree, and a gate that stats it would fail on every legitimate remote path)
printf "${ok}Tier: deep\nGoal-Review: /abs/REVIEW.md\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ② a declared receipt is silent" "" "$err"
chk_eq "[TIER] ② and dispatches" 0 "$rc"

# ③ the sanctioned exemption: a reasoned SKIPPED is a declaration, not an evasion
printf "${ok}Tier: deep\nGoal-Review: SKIPPED: 纯取证\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ③ a reasoned skip is silent" "" "$err"
chk_eq "[TIER] ③ and dispatches" 0 "$rc"

# ④ …but a bare SKIPPED is the evasion: no reason means nothing was declared
printf "${ok}Tier: deep\nGoal-Review: SKIPPED:\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ④ a reasonless skip never blocks either" 0 "$rc"
chk_contains "[TIER] ④ but is warned about" "跳过未写理由" "$err"
printf "${ok}Tier: deep\nGoal-Review: SKIPPED\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ④ the colonless form too" "跳过未写理由" "$err"

# ⑤⑥ the two silent states: a light goal owes no receipt, and a goal with no Tier line at all
# is not in this layer's territory (opt-in — every goal written before this batch)
printf "${ok}Tier: light\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑤ a light goal is silent" "" "$err"
chk_eq "[TIER] ⑤ and dispatches" 0 "$rc"
printf "${ok}" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑥ no Tier line, nothing judged" "" "$err"
chk_eq "[TIER] ⑥ and dispatches" 0 "$rc"

# ⑦ a third value is not a third tier: the doctrine has exactly two, so an unknown word is a
# declaration the gate cannot read and says so instead of guessing a tier
printf "${ok}Tier: medium\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑦ an unknown tier never blocks" 0 "$rc"
chk_contains "[TIER] ⑦ but is named" "Tier 值不认识" "$err"
chk_contains "[TIER] ⑦ quoting what was written" "medium" "$err"
chk_not_contains "[TIER] ⑦ and no receipt verdict is invented" "$TIERW" "$err"

# ⑧ an unfilled template placeholder is an absent receipt, not a present one — the shape the
# template itself ships with, and the one a copy-paste author leaves behind
printf "${ok}Tier: deep\nGoal-Review: <回执路径>\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ⑧ a placeholder receipt is no receipt" "$TIERW" "$err"
chk_eq "[TIER] ⑧ and still never blocks" 0 "$rc"

# ⑨ coexistence with the one thing in this gate that DOES block: the advisory is printed
# before the verdict, so a refuted premise never swallows it
printf "${ok}Tier: deep\n## Premises\nPREMISE: 两行 verify=\`echo one\` => count=2 rc=0\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑨ a refuted premise still reds" 1 "$rc"
chk_contains "[TIER] ⑨ and the advisory is still printed" "$TIERW" "$err"
chk_eq "[TIER] ⑨ WARN before ERR" 1 "$(printf '%s\n' "$err" | grep -n "$TIERW\|^ERR:" | sed -n '1s/:.*//p')"
chk_contains "[TIER] ⑨ ERR is the second line" "ERR: preflight gate" "$(printf '%s\n' "$err" | sed -n 2p)"

# ⑩ --claims is a different consumer (a governance document, not a dispatch): it judges no
# tier, so a document merely containing the word is untouched
printf 'Tier: deep\nPREMISE: 一行 verify=`echo one` => count=1 rc=0\n' > "$cdoc"
claims_run "$cdoc"
chk_eq "[TIER] ⑩ claims mode dispatches" 0 "$rc"
chk_not_contains "[TIER] ⑩ and judges no tier" "$TIERW" "$err"
chk_not_contains "[TIER] ⑩ nor its value" "Tier 值不认识" "$err"

# ⑪ the doctrine is written in Chinese and so are the goals: 深档 / 轻档 are the same two tiers
printf "${ok}Tier: 深档\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ⑪ 深档 is deep" "$TIERW" "$err"
printf "${ok}Tier: 深档\nGoal-Review: /abs/REVIEW.md\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑪ and closes the same way" "" "$err"
printf "${ok}Tier: 轻档\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑪ 轻档 is light, and silent" "" "$err"
# the declaration is a LINE, so a list marker or a blockquote prefix is still one — that is how
# the template's header actually reaches a goal author's file
printf "${ok}> Tier: deep\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ⑪ a blockquoted declaration is a declaration" "$TIERW" "$err"
printf "${ok}Tier: deep（新增判据面）\nGoal-Review: /abs/REVIEW.md（冷评审）\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑪ an annotated value is not an unknown one" "" "$err"

# ⑫ the shape codex's cold review found: a template header copied with the receipt value never
# filled in. `\s*` after the colon matched the NEWLINE too, so the line below — in the template
# that is exactly `## Context` — was captured as the receipt VALUE: non-empty, no placeholder,
# gate silent on the most common bad sample there is. The value now ends where its line ends.
printf "${ok}Tier: deep\nGoal-Review:\n\n## Context\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ⑫ an empty receipt value is no receipt" "$TIERW" "$err"
chk_eq "[TIER] ⑫ and still never blocks" 0 "$rc"
chk_not_contains "[TIER] ⑫ the line below was never the value" "## Context" "$err"

# ⑬ the same disease wearing the value's own whitespace: spaces and a tab after the colon are
# still an empty value, and the body line under them is still body
printf "${ok}Tier: deep\nGoal-Review:  \t\n正文一行\n" > "$goal"
tier_run "$goal"
chk_contains "[TIER] ⑬ a whitespace-only receipt is no receipt" "$TIERW" "$err"
chk_eq "[TIER] ⑬ and still never blocks" 0 "$rc"

# ⑭ the negative control for ⑫: the identical `## Context` follower behind a REAL receipt stays
# silent, so the fix shortened the value's span and changed nothing else
printf "${ok}Tier: deep\nGoal-Review: /abs/REVIEW.md\n\n## Context\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑭ a filled receipt above body is silent" "" "$err"
chk_eq "[TIER] ⑭ and dispatches" 0 "$rc"

# ⑮ RULING, this batch: an empty `Tier:` value is NO declaration — not an unknown tier. The
# layer is opt-in by absence (⑥) and a value nobody typed is an absence, so nothing is judged
# and the deep receipt is not asked for. Before the fix the same span bug named the body line
# below it (`##`) a third tier and printed 不认识.
printf "${ok}Tier:\n\n## Context\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑮ an empty Tier value declares nothing" "" "$err"
chk_eq "[TIER] ⑮ and dispatches" 0 "$rc"
printf "${ok}Tier:  \t\nGoal-Review: <回执路径>\n" > "$goal"
tier_run "$goal"
chk_eq "[TIER] ⑮ whitespace-only too, and no receipt verdict" "" "$err"

rm -rf "$SANDBOX"
summary
