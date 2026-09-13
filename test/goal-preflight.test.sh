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

rm -rf "$SANDBOX"
summary
