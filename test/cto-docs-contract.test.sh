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

echo "== cto docs contract =="
# white-box coupling ban (owner ruling 2026-08-09): tests drive the CLI. Dynamically loading the
# runtime modules to poke internals freezes the internal ABI and taxes every restructure; the
# probes never caught a field bug. Sanctioned consumers only: ws3/probe.py (fake-engine wire
# mechanism), replay-corpus.py (consumes the shipped projector as the single source of truth).
# agentctl-duplex sanctioned 2026-08-17 for ONE block (idle-marks helpers): they are pure
# file arithmetic whose CLI-black-box path requires a full engine emulator answering
# get_state — negative leverage for a hint line. Scope stays the helper pair; consuming any
# other duplexctl internal from that file is still an offence (manifest gate holds).
wb_offenders="$(grep -rl 'spec_from_file_location' . 2>/dev/null | sed 's|^\./||' | grep -v '__pycache__' | grep -vE '^(replay-corpus\.py|duplex-fixtures/ws3/probe\.py|cto-docs-contract\.test\.sh|agentctl-duplex\.test\.sh)$' || true)"
chk_eq "white-box dynamic-load stays banned outside sanctioned consumers" "" "$wb_offenders"
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
chk_contains "runtime refuses busy codex steer" "codex has no queue" "$duplexctl_body"
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
chk_contains "value gate targets uncertain expensive direction" "高不确定方向准备进入昂贵设计/实现" "$goal_body"
chk_contains "value gate requires probe before dispatch" "先跑最便宜证伪" "$goal_body"
chk_contains "forensic/mechanical work deletes value gate" "取证 / 机械改动和纯研究删除它" "$goal_body"
chk_not_contains "goal has no fixed Existing coverage field" "Existing coverage:" "$goal_body"
chk_not_contains "goal has no fixed Incremental value field" "Incremental value:" "$goal_body"
chk_not_contains "goal has no fixed Cheapest falsification field" "Cheapest falsification" "$goal_body"
chk_not_contains "goal has no fixed Stop-loss field" "Stop-loss:" "$goal_body"
# measurement protocol: one canonical file, consumed by goal-template row + goal-review face.
MEAS="../skills/cto-orchestration/references/measurement-protocol.md"
meas_body="$(cat "$MEAS")"
chk_contains "goal measurement row defers to the protocol single source" "measurement-protocol.md" "$goal_body"
chk_contains "goal-review consumes the protocol on measurement face" "measurement-protocol.md" "$review_body"
chk_contains "skill routes to the measurement protocol" "references/measurement-protocol.md" "$skill_body"
# consumers stay bare pointers: clause vocabulary re-appearing in a consumer = second index drift.
chk_not_contains "goal no longer inlines rerun-scope detail" "整批环境性失效" "$goal_body"
chk_not_contains "goal row carries no exclusion-category vocabulary" "剔除类别" "$goal_body"
chk_not_contains "goal row carries no clause summary (identity freeze)" "身份冻结" "$goal_body"
chk_not_contains "goal row carries no clause summary (blinding)" "盲化" "$goal_body"
chk_not_contains "skill routing row carries no clause summary (identity freeze)" "身份冻结" "$skill_body"
chk_not_contains "skill routing row carries no clause summary (blinding)" "盲化" "$skill_body"
# structural boundary (vocabulary denylists cannot catch paraphrase): the scenario row is pinned
# byte-exact, its successor row must stay adjacent (nothing squeezed inside the row), and the
# file-wide checkbox census is pinned — inserting ANY new operational row forces a deliberate
# test update instead of sliding in silently.
meas_row1='- [ ] 测量/评测类 Done-when（对比判定 / 命中率 / 基准 / 评测报告）→ 读 measurement-protocol.md，'
meas_row2='  七条款逐条对照实例化进本 goal（细则该文件单源，本模板不复制）。'
chk_eq "goal measurement row line 1 is byte-exact and unique" 1 "$(grep -cF -- "$meas_row1" "$GOAL")"
chk_eq "goal measurement row line 2 is byte-exact and unique" 1 "$(grep -cF -- "$meas_row2" "$GOAL")"
meas_ctx="$(grep -A2 -F -- "$meas_row1" "$GOAL")"
chk_contains "goal measurement row has no interior additions" "- [ ] 鉴权/会话/用户数据相关改动" "$meas_ctx"
chk_eq "goal checkbox census is pinned" 14 "$(grep -c '^- \[ \]' "$GOAL")"
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
chk_contains "review round 3 requires continuation lease" '第 3 轮起每轮续派须在 brief 写 `SHIP-BLOCKING: <依据>`' "$skill_body"
chk_contains "self-growing review fixes stop after two rounds" '连续 2 轮只新增 finding，则止损并转人工裁决或 accept-documented' "$skill_body"
chk_contains "goal does not duplicate review rounds" "本 GOAL 不复制轮数" "$goal_body"
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
