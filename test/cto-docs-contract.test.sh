#!/usr/bin/env bash
# Mechanical contract for cto-orchestration's three dispatch lanes and goal paths.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SKILL="../skills/cto-orchestration/SKILL.md"
GOAL="../skills/cto-orchestration/references/goal-template.md"
skill_body="$(cat "$SKILL")"
goal_body="$(cat "$GOAL")"
readme_body="$(cat ../skills/cto-orchestration/references/agent-watch/README.md)"

echo "== cto docs contract =="
chk_contains "three lanes named" "三条派工 lane" "$skill_body"
chk_contains "TUI owns in-round interaction" "轮内实时交互 / 即时 steering / 菜单或 pane" "$skill_body"
chk_contains "headless is self-contained per round" "单轮自包含、轮内不交互" "$skill_body"
chk_contains "headless supports later resume" '后续轮仍可用 `send` resume' "$skill_body"
chk_contains "headless entry is the env switch, same command surface" '`DISPATCH_EXEC=1`——命令面与 TUI 完全同面' "$skill_body"
chk_contains "headless truth is typed status" '只认 `dispatch status` / `watch` 的 typed status' "$skill_body"
chk_contains "file deliverables require the gate" '文件产出必须声明 `--deliverable` 加 fresh deliverable 门' "$skill_body"
chk_contains "non-file results omit the gate" "非文件结果不带" "$skill_body"
chk_contains "subagent owns browser MCP isolated reads" "需要浏览器 / MCP / 隔离主上下文的读密集一次性" "$skill_body"

chk_contains "goal read and deliverable paths are absolute" "所有“先读路径”和“交付物路径”必须写绝对路径" "$goal_body"
chk_contains "goal exempts command arguments" "不要求证明命令内部每个参数都绝对化" "$goal_body"
chk_contains "findings uses absolute placeholder" "/absolute/path/to/worktree/docs/orchestration/" "$goal_body"
chk_contains "TUI understanding gate waits" "TUI lane 先复述" "$goal_body"
chk_contains "headless understanding gate starts" "headless lane 简短复述后直接开工、不得等待交互" "$goal_body"
chk_contains "headless blocker path is absolute" "/absolute/path/to/cwd/BLOCKED.md" "$goal_body"
chk_contains "goal has conditional premises section" "Premises this goal rests on (VERIFY — do not trust)" "$goal_body"
chk_contains "premise evidence is candidate not verdict" "candidate evidence" "$goal_body"
chk_contains "false premise stops implementation" "任何 premise 为假 → **STOP AND REPORT**" "$goal_body"
chk_contains "premises carry claim and verify checkbox" '- [ ] **Claim**:' "$goal_body"
chk_contains "refuted audit claims return to source doc" 'REFUTED CLAIMS' "$skill_body"
chk_contains "refuted table has required columns" "claim / evidence / pointer" "$skill_body"
chk_contains "SKILL lane gate split" "理解门按 lane" "$skill_body"
chk_contains "SKILL headless gate starts" "headless 由 runtime footer 要求简短复述后" "$skill_body"
chk_contains "README lane gate split" "理解门按 lane" "$readme_body"
chk_not_contains "README has no blanket wait gate" "核对无误再放行" "$readme_body"
chk_not_contains "relative-path contract removed" "Paths relative to" "$goal_body"

summary
