#!/usr/bin/env bash
# onboard.e2e.sh — LIVE consumer-path test of project onboarding (the install→onboard chain).
# A fresh headless `claude` session in an empty repo must, from the installed skills alone,
# initialize everything a new orchestration project needs. Asserts on FILES (durable
# artifacts), never on model prose. This automates the 2026-07 manual E2E that validated:
#   ① docs governance tree (repo-governance-bootstrap 步骤 1-10)
#   ② project AGENTS.md incl. the two orchestration sections (委派边界 + 编排者行为内核)
#   ③ hooks wired in .claude/settings.json (memory-discipline + both cto-guards, ABSOLUTE paths)
#   ④ orchestration dirs + DECISION_QUEUE (cto onboarding checklist)
# COST: one long claude session (~3-6 min, real tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

echo "== onboard.e2e (live claude session; several minutes, uses API tokens) =="

WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-onboard.XXXXXX")"
WTBASE="$(basename "$WT")"
# agent-mail onboarding writes a roster row — point the SESSION at a temp bus so the user's
# real ~/.agents/mail is never touched by the test
TMPMAIL="$(mktemp -d "${TMPDIR:-/tmp}/e2e-mailbus.XXXXXX")"
cleanup() {
  rm -rf "$WT" "$TMPMAIL"
  # the onboarding writes orchestrator memory OUTSIDE the repo (~/.claude/projects/<flattened-cwd>).
  # Flattening turns '.' into '-' (e2e-onboard.Xxx -> ...e2e-onboard-Xxx), so match the translated name.
  find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*$(printf '%s' "$WTBASE" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT

cd "$WT" && git init -q . && printf '# demo-proj\nA tiny demo service.\n' > README.md && git add -A && git commit -qm init

AGENT_MAIL_DIR="$TMPMAIL" timeout 570 claude -p "本项目要接入多 agent 编排开发。请依次完成：
1) 用 repo-governance-bootstrap skill 初始化文档治理（项目名 demo-proj，定位：演示用微服务；capability: demo-api；module: api；需要 AGENTS.md）。所有该问用户的问题都按此给定信息处理，不要等待输入。
2) 然后按 cto-orchestration 的新项目接入清单（references/onboarding-checklist.md）逐步完成接入，包含 AGENTS.md 编排增量增补 和 hook wiring。
3) 本项目也要加入多编排者通信：按 agent-mail skill 的「接入」节完成本席位接入（席位 id: demo-proj）。
4) 只创建文件，不要 push。" --dangerously-skip-permissions < /dev/null >/dev/null 2>&1

# ① docs governance tree
for f in docs/INDEX.md docs/ACTIVE_CONTEXT.md docs/roadmap/active-roadmap.md AGENTS.md CLAUDE.md ACCESS.local.md; do
  chk_eq "exists: $f" 1 "$([ -f "$WT/$f" ] && echo 1 || echo 0)"
done
chk_eq "ADR-0001 created" 1 "$(ls "$WT"/docs/decisions/ADR-0001* >/dev/null 2>&1 && echo 1 || echo 0)"
chk_contains "CLAUDE.md imports AGENTS.md" "@AGENTS.md" "$(cat "$WT/CLAUDE.md" 2>/dev/null)"
chk_eq "ACCESS.local.md gitignored" 0 "$(cd "$WT" && git check-ignore -q ACCESS.local.md; echo $?)"

# ② AGENTS.md orchestration sections (the cto 编排增量两节)
ag="$(cat "$WT/AGENTS.md" 2>/dev/null)"
chk_contains "AGENTS.md has 委派 Agent 边界" "委派 Agent 边界" "$ag"
chk_contains "AGENTS.md has 编排者行为内核" "编排者行为内核" "$ag"
chk_contains "行为内核 has 角色绑定" "角色绑定" "$ag"

# ③ hooks wired, absolute paths (hooks don't expand ~)
SJ="$WT/.claude/settings.json"
chk_eq "settings.json exists" 1 "$([ -f "$SJ" ] && echo 1 || echo 0)"
hook_count() { # event matcher-or-empty command-basename
  [ -f "$SJ" ] || { echo 0; return; }
  python3 - "$SJ" "$1" "$2" "$3" <<'PY'
import json, os, sys
path, event, matcher, command = sys.argv[1:]
d = json.load(open(path, encoding="utf-8"))
n = 0
for group in d.get("hooks", {}).get(event, []):
    if group.get("matcher", "") != matcher:
        continue
    for hook in group.get("hooks", []):
        n += os.path.basename(hook.get("command", "")) == command
print(n)
PY
}
hook_command_count() { # event command-basename, regardless of matcher
  [ -f "$SJ" ] || { echo 0; return; }
  python3 - "$SJ" "$1" "$2" <<'PY'
import json, os, sys
path, event, command = sys.argv[1:]
d = json.load(open(path, encoding="utf-8"))
print(sum(os.path.basename(h.get("command", "")) == command
          for group in d.get("hooks", {}).get(event, []) for h in group.get("hooks", [])))
PY
}
if [ -f "$SJ" ]; then
  cmds="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for arr in d.get("hooks",{}).values():
    for m in arr:
        for h in m.get("hooks",[]):
            print(h.get("command",""))' "$SJ" 2>/dev/null)"
  chk_contains "wired: cto-guard-bash" "cto-guard-bash.py" "$cmds"
  chk_contains "wired: cto-guard-agent" "cto-guard-agent.py" "$cmds"
  chk_contains "wired: memory-discipline" "memory-discipline-hook" "$cmds"
  chk_eq "no tilde paths in hook commands" 0 "$(printf '%s' "$cmds" | grep -c '~' || true)"
  bad=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    # BARE absolute path only — interpreter prefixes (python/python3/bash/sh) are works-by-luck
    # (bet on PATH/venv; scripts ship shebang+exec bit). Tightened after a live audit hit.
    case "$c" in /*) : ;; *) bad=$((bad+1));; esac
  done <<< "$cmds"
  chk_eq "all hook commands are bare absolute paths (no interpreter prefix)" 0 "$bad"
  # matcher must come from the shipped truth-source (guard-hooks.json), not from stale prose copies —
  # KillShell only exists in the truth-source, so its presence proves the source was actually read
  chk_contains "matcher taken from truth-source (has KillShell)" "KillShell" "$(cat "$SJ")"

fi

# ④ orchestration dirs + decision queue
chk_eq "docs/orchestration/ exists" 1 "$([ -d "$WT/docs/orchestration" ] && echo 1 || echo 0)"
chk_eq "DECISION_QUEUE.md exists" 1 "$([ -f "$WT/docs/DECISION_QUEUE.md" ] && echo 1 || echo 0)"

# ⑤ agent-mail onboarding (only asserted when the optional skill is installed):
#    checklist step 3 must register a seat + wire every canonical agent-mail entry exactly once.
if [ -e "$HOME/.claude/skills/agent-mail" ]; then
  # needle = the unique tmpdir basename: survives path normalization (/var vs /private/var, //)
  chk_contains "mail: seat registered (roster row has project workdir)" "$WTBASE" "$(cat "$TMPMAIL/registry.md" 2>/dev/null)"
  chk_eq "mail: SessionStart mail-check wired exactly once" 1 "$(hook_count SessionStart '' mail-check.py)"
  chk_eq "mail: SessionStart has no wrong-matcher duplicate" 1 "$(hook_command_count SessionStart mail-check.py)"
  chk_eq "mail: UserPromptSubmit mail-check wired exactly once" 1 "$(hook_count UserPromptSubmit '' mail-check.py)"
  chk_eq "mail: UserPromptSubmit has no wrong-matcher duplicate" 1 "$(hook_command_count UserPromptSubmit mail-check.py)"
  chk_eq "mail: PreToolUse write guard wired exactly once" 1 "$(hook_count PreToolUse 'Write|Edit|MultiEdit' mail-guard.py)"
  chk_eq "mail: PreToolUse has no wrong-matcher duplicate" 1 "$(hook_command_count PreToolUse mail-guard.py)"
else
  echo "  [skip] agent-mail not installed — ⑤ skipped"
fi

summary
