#!/usr/bin/env bash
# Mechanical contract for cto-orchestration's agentctl lanes and goal paths.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SKILL="../skills/cto-orchestration/SKILL.md"
GOAL="../skills/cto-orchestration/references/goal-template.md"
REVIEW="../skills/cto-orchestration/references/review-dispatch.md"
AGENTCTL_SRC="../skills/cto-orchestration/references/agentctl/agentctl"
DUPLEXCTL="../skills/cto-orchestration/references/agentctl/duplexctl.py"
PREFLIGHT="../skills/cto-orchestration/references/goal-preflight.py"
QUEUE="../skills/cto-orchestration/references/decision-queue.md"
RETRO="../skills/cto-orchestration/references/retrospective.md"
skill_body="$(cat "$SKILL")"
goal_body="$(cat "$GOAL")"
review_body="$(cat "$REVIEW")"
agentctl_body="$(cat "$AGENTCTL_SRC")"
duplexctl_body="$(cat "$DUPLEXCTL")"
preflight_body="$(cat "$PREFLIGHT")"
queue_body="$(cat "$QUEUE")"
retro_body="$(cat "$RETRO")"
readme_body="$(cat ../skills/cto-orchestration/references/agentctl/README.md)"
CLAUSES="../skills/cto-orchestration/references/goal-clauses.md"
clauses_body="$(cat "$CLAUSES")"

echo "== cto docs contract =="
# white-box coupling ban (owner ruling 2026-08-09): tests drive the CLI. Dynamically loading the
# runtime modules to poke internals freezes the internal ABI and taxes every restructure; the
# probes never caught a field bug. Sanctioned consumers only: ws3/probe.py (fake-engine wire
# mechanism), replay-corpus.py (consumes the shipped projector as the single source of truth).
# agentctl-duplex sanctioned 2026-08-17 for ONE block (idle-marks helpers): they are pure
# file arithmetic whose CLI-black-box path requires a full engine emulator answering
# get_state — negative leverage for a hint line. The sanction is enforced PRECISELY below
# (review B2: a whole-file exemption let `m.classify` ride the allowlist unseen): the
# file's dynamically-loaded attribute consumption set must equal exactly the helper pair.
wb_offenders="$(grep -rl 'spec_from_file_location' . 2>/dev/null | sed 's|^\./||' | grep -v '__pycache__' | grep -vE '^(replay-corpus\.py|duplex-fixtures/ws3/probe\.py|cto-docs-contract\.test\.sh|agentctl-duplex\.test\.sh)$' || true)"
chk_eq "white-box dynamic-load stays banned outside sanctioned consumers" "" "$wb_offenders"
# precise sanction: extract every `m.<attr>` the duplex test consumes from the loaded module
# and pin the set to exactly the helper pair. A third internal (`m.classify`…) goes red here.
duplex_consumes="$(grep -oE '\bm\.[A-Za-z_]+' agentctl-duplex.test.sh | sort -u | tr '\n' ' ')"
chk_eq "duplex test's white-box consumption is exactly the helper pair" \
  "m._idle_mark_and_count m._idle_marks_reset " "$duplex_consumes"
# named evasion from review R2: getattr(m, ...) reaches internals without an m.attr literal.
# This gate is a tripwire against accidental scope creep, not a sandbox — but the one named
# evasion shape gets its own tripwire.
chk_eq "no getattr-shaped access to the loaded module" "" \
  "$(grep -n 'getattr( *m' agentctl-duplex.test.sh || true)"
# known positive for the extractor itself: a synthetic line with an extra internal must show up
chk_contains "consumption extractor sees a planted extra internal" "m.classify" \
  "$(printf 'x = m.classify\n' | grep -oE '\bm\.[A-Za-z_]+')"
chk_contains "unified surface is agentctl" "agentctl start|steer|status|watch|stop" "$skill_body"
# WS3: the provider capability matrix is RUNTIME-generated. The main skill keeps the control
# principle and a pointer; the wire-level truth is asserted against duplexctl's one table.
chk_contains "capability truth is runtime-generated" "agentctl capabilities" "$skill_body"
chk_contains "main skill keeps the control principle" "能力差异不分叉车道" "$skill_body"
chk_not_contains "no prose capability matrix survives in the main skill" \
  "abort_and_prompt" "$skill_body"
chk_not_contains "and no per-engine steer column table either" \
  "steer 默认（排队/下一轮）" "$skill_body"
chk_contains "single lane three engines" "一条 lane、三引擎" "$skill_body"
chk_contains "codex mid-turn steer is native" "turn/steer" "$duplexctl_body"
chk_contains "capability states are one closed enum" "CAPABILITY_STATES" "$duplexctl_body"
chk_contains "the capability table is what routing consumes" "VERB_CAPABILITY" "$duplexctl_body"
chk_contains "manual presence is attach-only, control stays on protocol" "worker 控制始终走协议" "$skill_body"
chk_contains "file deliverables require the gate" '文件任务必须声明 `--deliverable <glob>`' "$skill_body"
chk_contains "deliverable glob is session-cwd relative" "相对 glob 按会话 cwd 解析" "$skill_body"
chk_contains "non-file results omit the gate" "非文件结果不带" "$skill_body"
chk_contains "subagent owns browser MCP isolated reads" "浏览器 / MCP / 隔离主上下文的读密集工作" "$skill_body"
chk_contains "start does not auto-watch" "不会自动 watch" "$skill_body"
chk_contains "capability gap refuses instead of forking" "拒绝" "$skill_body"
chk_contains "delivery is not obedience" "投递成功 ≠ 模型照做" "$skill_body"
# was "runtime refuses busy codex steer" / "codex has no queue": the queue-vs-now-vs-replace
# triple is gone (2026-08-29). The invariant that replaced it is stronger — ONE steer verb whose
# route comes from the engine's LIVE turn state, so a busy codex is steered mid-turn instead of
# refused and no operator flag can be forgotten.
chk_contains "steer routes on the live turn state, not an operator flag" \
  "def steer_delivery" "$duplexctl_body"
chk_contains "and the retired opt-in flag is refused with the new semantics" \
  "delivers as soon as the engine allows" "$agentctl_body"
chk_contains "implementation detail is progressively loaded" "references/implementation-discipline.md" "$skill_body"
chk_contains "preflight gate defaults on, exemption is explicit" '`--no-preflight`' "$skill_body"
chk_contains "duplex lane defaults the preflight gate on" 'PREFLIGHT=1;' "$agentctl_body"
chk_contains "duplex lane exempts preflight explicitly" '--no-preflight) PREFLIGHT=0' "$agentctl_body"
chk_contains "lane calls canonical preflight validator" '../goal-preflight.py' "$agentctl_body"
chk_contains "validator rejects unresolved evidence" "unresolved/N/A is not evidence" "$preflight_body"
chk_contains "duplex single fifo writer is flock-serialized" "flock" "$duplexctl_body"
chk_contains "duplex output is bounded by design" "SUMMARY_CHARS" "$duplexctl_body"

chk_contains "goal read and deliverable paths are absolute" "所有“先读路径”和“交付物路径”必须写绝对路径" "$goal_body"
chk_contains "goal exempts command arguments" "不要求证明命令内部每个参数都绝对化" "$goal_body"
chk_contains "findings uses absolute placeholder" "/absolute/path/to/worktree/docs/orchestration/" "$goal_body"
chk_contains "goal delegates understanding gate to runtime" "复述 / 立即开工 / BLOCKED 协议由 runtime" "$goal_body"
chk_contains "runtime understanding gate starts work" "do not idle waiting for approval to begin" "$agentctl_body"
# the gate's other half: a contract STOP is held BY writing BLOCKED.md, and cheap rollback is not
# a licence to self-approve past it. Both halves regressed workers when only the first existed.
chk_contains "runtime gate routes contract STOP to BLOCKED.md" "when the goal contract tells you to stop and wait for the orchestrator" "$agentctl_body"
chk_contains "runtime gate denies self-approval by blast radius" "never licenses self-approval past one" "$agentctl_body"
# the footer consumes the kernel's branch predicate (orchestrator-core §3): a PROMISED pre-work
# review is a gate, and it is held through the same channel — otherwise the kernel states a rule
# the shipping lane does not implement, and that contract shape has two contradictory answers.
chk_contains "runtime gate defers to a promised pre-work review" "Unless the goal contract promises to review that restatement" "$agentctl_body"
chk_contains "promised review is held via the same channel" "a promised pre-work review is such a gate" "$agentctl_body"
chk_not_contains "no unqualified do-not-wait wording" "Do not wait for approval or interaction" "$agentctl_body"
chk_contains "goal has conditional premises section" "Premises this goal rests on (VERIFY — do not trust)" "$goal_body"
chk_contains "premise evidence is candidate not verdict" "candidate evidence" "$goal_body"
chk_contains "false premise stops implementation" "任何 premise 为假 → **STOP AND REPORT**" "$goal_body"
chk_contains "premises carry claim and verify checkbox" '- [ ] **Claim**:' "$goal_body"
chk_contains "refuted audit claims return to source doc" 'REFUTED CLAIMS' "$skill_body"
chk_contains "refuted table has required columns" "claim / evidence / pointer" "$skill_body"
# re-anchored 2026-08-17 (trunk surgery): SKILL no longer copies footer literals — it must
# still carry the contract-gate criterion (promised pre-work review => wait) and name the
# footer as the single source. Both halves pinned so neither the criterion nor the
# no-copy rule silently regresses.
chk_contains "SKILL runtime gate criterion" "合同承诺了开工前核对" "$skill_body"
chk_contains "SKILL names footer as source" "runtime footer 固定追加" "$skill_body"
# negative half (review 2026-08-17 B2): re-copying the retired footer literal back into the
# SKILL must go red — the positive pair alone stays green after a literal re-copy.
chk_not_contains "SKILL does not re-copy footer literal" "runtime footer 要求简短复述后立即开工" "$skill_body"
chk_not_contains "README has no blanket wait gate" "核对无误再放行" "$readme_body"
chk_contains "README duplex protocol footer" "HEADLESS 协议 footer" "$readme_body"
chk_contains "README keeps ENGINE-SILENT honesty" "ENGINE-SILENT" "$readme_body"
chk_contains "README keeps notification black-hole evidence" "完成通知黑洞" "$readme_body"
chk_contains "README keeps send-keys pitfalls for guard pointer" "裸 send-keys 坑" "$readme_body"
chk_not_contains "relative-path contract removed" "Paths relative to" "$goal_body"

chk_contains "queue admits no generic T1 ledger hook" "尚无通用 T1 自动记账 / T2 deny" "$queue_body"
chk_contains "queue freshness is reminder only" "提醒，不冒充权限门" "$queue_body"
chk_contains "queue is active-only" "只存活跃项" "$queue_body"
chk_contains "queue hook covers new context" "SessionStart + UserPromptSubmit" "$queue_body"
chk_contains "retro cleared history is blocking" "已清区仍有正文”返回 blocking FAIL" "$queue_body"
chk_contains "retro queue freshness remains warning" "队列仅不新鲜仍只告警、exit 0" "$queue_body"
chk_contains "retro hard failures are scoped" "是 blocking FAIL" "$retro_body"
chk_contains "retro soft checks admit exit zero" "只给 warning，exit 仍可为 0" "$retro_body"
chk_not_contains "retro does not call every check a hard gate" "未全过不算复盘完成" "$retro_body"

value_gate='Value gate: <existing gap → incremental value>; Preflight: <cheapest read-only falsifier actually run> => <observed result>'
chk_eq "goal has exactly one conditional value-gate line" 1 "$(grep -cF "$value_gate" "$GOAL")"
chk_contains "value gate: exemption condition precedes the action" "取证 / 机械改动 / 纯研究且不新增防御层或复杂度的 goal → 删下一行" "$goal_body"
chk_contains "value gate requires probe before dispatch" "先跑最便宜证伪" "$goal_body"
chk_contains "everything else keeps the value gate line" "其余 goal（含所有新增防御层/复杂度的）→ 先跑最便宜证伪、保留下一行" "$goal_body"
chk_not_contains "goal has no fixed Existing coverage field" "Existing coverage:" "$goal_body"
chk_not_contains "goal has no fixed Incremental value field" "Incremental value:" "$goal_body"
chk_not_contains "goal has no fixed Cheapest falsification field" "Cheapest falsification" "$goal_body"
chk_not_contains "goal has no fixed Stop-loss field" "Stop-loss:" "$goal_body"
# evidence-depth budget line (2026-09-01): the counterpart of the value-gate line on the OUTPUT
# side — a goal that does not declare how deep its proofs go gets "再跑一遍全量" by default
# (3x11min of pure re-run in one batch). Pinned byte-exact and unique, same shape as the
# value-gate line above. Deliberately NOT a `- [ ]` row: it is a template FIELD the goal author
# fills, not an acceptance item, and preflight machine-judges neither (n=1, no gate yet) —
# which is also why the checkbox census below does not move.
evidence_line='Evidence: 各证明证到 <决策行|单套件|全量> 为止（缺省 = 单套件；全量仅当运行本身是验收对象）'
chk_eq "goal has exactly one evidence-depth line" 1 "$(grep -cF "$evidence_line" "$GOAL")"
chk_contains "evidence depth defaults to a single suite" "缺省 = 单套件" "$goal_body"
chk_contains "full runs need the run itself to be the acceptance object" "全量仅当运行本身是验收对象" "$goal_body"
chk_contains "the evidence line is declared machine-unjudged" "preflight 不机判它" "$goal_body"
# measurement protocol: one canonical file, consumed by goal-clauses C05 + goal-review face.
MEAS="../skills/cto-orchestration/references/measurement-protocol.md"
meas_body="$(cat "$MEAS")"
# RE-ANCHORED (scenario clauses externalized): the 14 scenario clause BODIES moved out of
# goal-template.md into goal-clauses.md; the template keeps ONE index row per clause. What these
# assertions judge is unchanged — the protocol pointer, the byte-exact row, its adjacency — they
# now judge it on the file that OWNS the clause text. Leaving them on the template would have
# pinned a SECOND copy of the body there, which is exactly the drift the single-source block
# below forbids. The negative arm is new: the template must NOT carry the protocol pointer.
chk_contains "clause C05 defers to the protocol single source" "measurement-protocol.md" "$clauses_body"
chk_not_contains "the template index carries no protocol pointer" "measurement-protocol.md" "$goal_body"
chk_contains "goal-review consumes the protocol on measurement face" "measurement-protocol.md" "$review_body"
chk_contains "skill routes to the measurement protocol" "references/measurement-protocol.md" "$skill_body"
# consumers stay bare pointers: clause vocabulary re-appearing in a consumer = second index drift.
chk_not_contains "goal no longer inlines rerun-scope detail" "整批环境性失效" "$goal_body"
chk_not_contains "goal row carries no exclusion-category vocabulary" "剔除类别" "$goal_body"
chk_not_contains "goal row carries no clause summary (identity freeze)" "身份冻结" "$goal_body"
chk_not_contains "goal row carries no clause summary (blinding)" "盲化" "$goal_body"
chk_not_contains "skill routing row carries no clause summary (identity freeze)" "身份冻结" "$skill_body"
chk_not_contains "skill routing row carries no clause summary (blinding)" "盲化" "$skill_body"
# the clause file is a consumer too — it inherited the row, so it inherits the denylist.
chk_not_contains "clause file does not inline rerun-scope detail" "整批环境性失效" "$clauses_body"
chk_not_contains "clause file carries no exclusion-category vocabulary" "剔除类别" "$clauses_body"
chk_not_contains "clause file carries no clause summary (identity freeze)" "身份冻结" "$clauses_body"
chk_not_contains "clause file carries no clause summary (blinding)" "盲化" "$clauses_body"
# structural boundary (vocabulary denylists cannot catch paraphrase): the scenario row is pinned
# byte-exact, the next clause heading must stay adjacent (nothing squeezed inside the row), and the
# template's file-wide checkbox census is pinned — inserting ANY new operational row forces a
# deliberate test update instead of sliding in silently.
meas_row1='- [ ] 测量/评测类 Done-when（对比判定 / 命中率 / 基准 / 评测报告）→ 读 measurement-protocol.md，'
meas_row2='  七条款逐条对照实例化进本 goal（细则该文件单源，本模板不复制）。'
chk_eq "clause C05 row line 1 is byte-exact and unique" 1 "$(grep -cF -- "$meas_row1" "$CLAUSES")"
chk_eq "clause C05 row line 2 is byte-exact and unique" 1 "$(grep -cF -- "$meas_row2" "$CLAUSES")"
meas_ctx="$(grep -A3 -F -- "$meas_row1" "$CLAUSES")"
chk_contains "clause C05 has no interior additions" "## C06 鉴权/会话/用户数据相关改动" "$meas_ctx"
# census UNCHANGED at 20 and that is the point: the 14 clause bodies that left the template carried
# exactly 14 `- [ ]` rows, replaced 1:1 by the 14 index rows, so the 6 non-clause checkboxes
# (Premises x3, Done-when x3) plus 14 = 20 still holds. A moved clause must not buy slack here.
chk_eq "goal checkbox census is pinned" 20 "$(grep -c '^- \[ \]' "$GOAL")"

# ── scenario clauses: ONE body per clause in goal-clauses.md, ONE index row in the template ──
# The externalization's whole value is that a goal author reads 14 index lines instead of ~41 lines
# of bodies. Two failure modes get gates: a body creeping back into the template (double source,
# the two copies then drift) and an index row growing into a body (the template re-fattens).
chk_eq "clause file has exactly fourteen clause sections" 14 "$(grep -c '^## C[0-9][0-9] ' "$CLAUSES")"
chk_eq "clause file has exactly fourteen clause bodies" 14 "$(grep -c '^- \[ \]' "$CLAUSES")"
chk_eq "template index has exactly fourteen rows" 14 "$(grep -c '^- \[ \] C[0-9][0-9] ' "$GOAL")"
chk_contains "clause file states the on-demand instantiation rule" "命中则把该条正文" "$clauses_body"
chk_contains "template section points at the clause file" 'references/goal-clauses.md' "$goal_body"
chk_contains "skill 1.2 points at the clause file on demand" '场景条款按需读 `references/goal-clauses.md`' "$skill_body"
# every id defined once and indexed once — a renumber, a dropped clause or a duplicated id reds
id_defects=""
for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  h="$(grep -c "^## C$n " "$CLAUSES")"; r="$(grep -c "^- \[ \] C$n " "$GOAL")"
  [ "$h" = 1 ] && [ "$r" = 1 ] || id_defects="$id_defects C$n(heading=$h,index=$r)"
done
chk_eq "every clause id is defined once and indexed once" "" "$id_defects"
chk_eq "the id census counts a planted duplicate" 2 "$(printf '## C09 a\n## C09 b\n' | grep -c '^## C09 ')"
# index rows stay index-shaped. Width in CHARACTERS (python3, already a suite dependency): a byte
# bound would be a different, looser rule on CJK text.
idx_over() { # $1 file  $2 char limit -> index rows longer than the limit
  python3 -c 'import re, sys
lim = int(sys.argv[2])
for l in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if re.match(r"^- \[ \] C\d\d ", l) and len(l) > lim:
        print(l)
' "$1" "$2"
}
chk_eq "template index rows carry no clause body (<=60 chars each)" "" "$(idx_over "$GOAL" 60)"
# known positive for the width probe itself, through the SAME code path: at an impossible limit
# every one of the 14 rows must be reported, so a probe that silently sees nothing cannot pass.
chk_eq "the width probe fires on all rows at an impossible limit" 14 "$(idx_over "$GOAL" 5 | grep -c '^- \[ \] C')"
# no double source: each clause body's first line lives exactly once in the clause file and never
# in the template.
dual=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  c="$(grep -cF -- "$row" "$CLAUSES")"; g="$(grep -cF -- "$row" "$GOAL")"
  [ "$c" = 1 ] && [ "$g" = 0 ] || dual="$dual[clauses=$c template=$g] $row"
done <<EOF
$(grep '^- \[ \] ' "$CLAUSES")
EOF
chk_eq "each clause body is single-sourced in goal-clauses.md" "" "$dual"
# known positive for that comparison: the same rows looked up in the file that DOES hold them must
# all be found — proves the -cF lookup would catch a body copied back into the template.
found=0
while IFS= read -r row; do
  [ -z "$row" ] && continue
  [ "$(grep -cF -- "$row" "$CLAUSES")" = 0 ] || found=$((found + 1))
done <<EOF
$(grep '^- \[ \] ' "$CLAUSES")
EOF
chk_eq "the double-source probe sees a copy that IS present" 14 "$found"
# structural completeness: exactly seven numbered clauses, one load-bearing invariant pinned each.
chk_eq "protocol has exactly seven numbered clauses" 7 "$(grep -cE '^[0-9]+\. \*\*' "$MEAS")"
chk_contains "c1 freezes instrument identity per batch" "禁与旧批合并" "$meas_body"
chk_contains "c2 preregisters allocation and order" "禁重排、禁挑样本" "$meas_body"
chk_contains "c3 blinds the judge" "不含臂身份与预期结论" "$meas_body"
chk_contains "c3 demotes self-judging to diagnostics" "不得单独支撑 headline" "$meas_body"
chk_contains "c4 keeps the denominator preregistered" "分母恒为预注册样本量" "$meas_body"
chk_contains "c4 bans unsupported directional headlines" "不得断言方向" "$meas_body"
chk_contains "c5 quarantines mixed-version windows" "混合版本窗口" "$meas_body"
chk_contains "c6 keeps incomplete runs off headlines" "禁出 headline" "$meas_body"
chk_contains "c6 keeps rerun discipline single-sourced" "整批环境性失效" "$meas_body"
chk_contains "c7 runs the directional-wording self-check" "禁用方向性词表" "$meas_body"
chk_contains "evidence ladder rejects self-report" "被测自报永不作证据" "$meas_body"

chk_contains "review loop launch is explicit" "--workflow review-loop" "$review_body"
chk_contains "review loop launch requires max rounds" "--max-rounds <N>" "$review_body"
chk_contains "review loop runtime meta is sole source" "stop-loss 只认 runtime meta" "$review_body"
chk_contains "review continuation requires lease from round 2" '（**第 2 轮起**）须在 brief 写 `SHIP-BLOCKING: <依据>`' "$skill_body"
chk_contains "self-growing review fixes stop after two rounds" '连续 2 轮只新增 finding，则止损走三选项之一' "$skill_body"
chk_contains "and the stop-loss space includes the requirement layer" '向主理人请示需求降级' "$skill_body"
# RE-ANCHORED with the clause move: the round-budget carve-out is clause C13's text, so it is
# asserted where C13 now lives; the template must not grow a second copy of it.
chk_contains "clause C13 does not duplicate review rounds" "本 GOAL 不复制轮数" "$clauses_body"
chk_not_contains "the template index does not re-copy the round carve-out" "本 GOAL 不复制轮数" "$goal_body"
chk_contains "runtime persists workflow" "workflow=%s" "$agentctl_body"
chk_contains "runtime persists max rounds" "max_rounds=%s" "$agentctl_body"
chk_contains "runtime owns budget exhausted" "BUDGET-EXHAUSTED" "$duplexctl_body"

# rename completeness: the retired directory path must not survive in any TRACKED file —
# a path-list grep missed a tracked consumer outside the listed dirs after the agentctl
# rename (cold-review field hit 2026-07-29; that derivative doc is since deleted). Tracked-only
# via git grep so another seat's untracked WIP never trips it; NO pathspec list — a pathspec
# that stops existing makes git grep fatal and the gate silently green. fs-grep fallback
# covers git-less archive/installed copies. Runtime contract names (AGENT_WATCH_*, /tmp run
# dir) are NOT paths and stay. Needle is split so this test never matches its own source;
# the git path excludes this file explicitly instead.
old_dir="references/agent-""watch"
if git -C .. rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  stale="$(git -C .. grep -lF "$old_dir" -- ':(exclude)test/cto-docs-contract.test.sh' 2>/dev/null || true)"
else
  stale="$(grep -rlF "$old_dir" ../skills ../meta ../templates ../README.md ../.claude-plugin ../test 2>/dev/null | grep -v __pycache__ || true)"
fi
chk_eq "no tracked consumer of the retired $old_dir path" "" "$stale"

summary
