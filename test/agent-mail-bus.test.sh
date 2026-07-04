#!/usr/bin/env bash
# agent-mail `bus` — hermetic test against a temp $AGENT_MAIL_DIR (user-data dir never touched).
# Asserts: register (roster + mailbox), send (id format <YYYYMMDD-HHMM>-<from>-<slug>, frontmatter
# has NO status/date — state is positional), check (oldest-first pending), archive (state move),
# unregistered recipient still gets delivery (mail must not bounce).
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

BUSBIN="../skills/agent-mail/bus"
export AGENT_MAIL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/am-test.XXXXXX")"
trap 'rm -rf "$AGENT_MAIL_DIR"' EXIT

echo "== agent-mail bus =="

chk_eq "bus is executable" 1 "$([ -x "$BUSBIN" ] && echo 1 || echo 0)"

# register two agents
out="$(bash "$BUSBIN" register alpha /tmp/alpha "编排 A 摊")"
chk_contains "register alpha" "registered alpha" "$out"
bash "$BUSBIN" register beta /tmp/beta "编排 B 摊" >/dev/null
chk_eq "mailbox dirs created" 1 "$([ -d "$AGENT_MAIL_DIR/alpha/inbox" ] && [ -d "$AGENT_MAIL_DIR/beta/archive" ] && echo 1 || echo 0)"
out="$(bash "$BUSBIN" register alpha /tmp/alpha2 dup)"
chk_contains "re-register is idempotent" "already in roster" "$out"
out="$(bash "$BUSBIN" roster)"
chk_contains "roster has alpha" '`alpha`' "$out"; chk_contains "roster has beta" '`beta`' "$out"

# generated registry.md must be STRUCTURALLY valid markdown (init path = ensure_reg + row inserts):
# title line, then a contiguous table (header | separator | data rows, all 3-column), rows inside the table
reg_valid() { python3 - "$AGENT_MAIL_DIR/registry.md" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
rows = [(i, l) for i, l in enumerate(lines) if l.startswith("|")]
assert lines[0].startswith("# "), "missing title"
assert rows, "no table"
idx = [i for i, _ in enumerate(rows)]
first, last = rows[0][0], rows[-1][0]
assert [i for i, _ in rows] == list(range(first, last + 1)), "table not contiguous"
assert "agent-id" in rows[0][1], "header row wrong"
assert set(rows[1][1]) <= set("|- "), "separator row wrong"
for _, r in rows:
    assert r.startswith("|") and r.endswith("|") and r.count("|") == 4, f"not 3-column: {r}"
print("valid")
PY
}
chk_eq "fresh registry structurally valid" "valid" "$(reg_valid)"

# send: id format + frontmatter shape
bash "$BUSBIN" send alpha beta demo-topic "试一封" >/dev/null
f="$(ls "$AGENT_MAIL_DIR/beta/inbox/"*.md | head -1)"
chk_eq "letter delivered to recipient inbox" 1 "$([ -n "$f" ] && echo 1 || echo 0)"
base="$(basename "$f" .md)"
chk_eq "id format YYYYMMDD-HHMM-from-slug" 1 "$(printf '%s' "$base" | grep -qE '^[0-9]{8}-[0-9]{4}-alpha-demo-topic$' && echo 1 || echo 0)"
chk_contains "frontmatter from" "from: alpha" "$(cat "$f")"
chk_contains "frontmatter thread" "thread: demo-topic" "$(cat "$f")"
chk_eq "NO status field (state is positional)" 0 "$(grep -c '^status:' "$f")"
chk_eq "NO date field (id prefix carries it)" 0 "$(grep -c '^date:' "$f")"

# check: pending list, then archive drains it
out="$(bash "$BUSBIN" check beta)"
chk_contains "check shows 1 pending" "1 pending" "$out"
chk_contains "check shows sender" "from=alpha" "$out"
bash "$BUSBIN" archive beta "$base" >/dev/null
chk_eq "archived file moved" 1 "$([ -e "$AGENT_MAIL_DIR/beta/archive/$base.md" ] && [ ! -e "$f" ] && echo 1 || echo 0)"
out="$(bash "$BUSBIN" check beta)"
chk_contains "check empty after archive" "inbox empty" "$out"

# unregistered recipient: deliver anyway + warn
out="$(bash "$BUSBIN" send alpha gamma hello "投递给未注册者")"
chk_contains "warns not registered" "not registered" "$out"
chk_eq "still delivered" 1 "$(ls "$AGENT_MAIL_DIR/gamma/inbox/"*.md >/dev/null 2>&1 && echo 1 || echo 0)"

# register must insert INTO the table, not after a trailing footer note (regression: live dogfood
# caught `>> file` appending the row below the blockquote footer → broken table)
printf '\n> footer note\n' >> "$AGENT_MAIL_DIR/registry.md"
bash "$BUSBIN" register delta /tmp/delta "表格中段插入" >/dev/null
chk_contains "delta registered" '`delta`' "$(cat "$AGENT_MAIL_DIR/registry.md")"
chk_eq "row inserted before footer (file tail is footer, not row)" "> footer note" "$(tail -1 "$AGENT_MAIL_DIR/registry.md")"
chk_eq "registry still structurally valid after footer+insert" "valid" "$(reg_valid)"

# degenerate
out="$(bash "$BUSBIN" check nosuch 2>&1)"; rc=$?
chk_eq "check unknown agent exits nonzero" 1 "$rc"

# ── mail-check.py (SessionStart pending-mail surfacing; identity: env > arg > registry-workdir) ──
MAILCHECK="../skills/agent-mail/mail-check.py"
chk_eq "mail-check is executable" 1 "$([ -x "$MAILCHECK" ] && echo 1 || echo 0)"
bash "$BUSBIN" send alpha beta ping2 "再来一封" >/dev/null
out="$(env -u CLAUDE_PROJECT_DIR AGENT_MAIL_SELF=beta "$MAILCHECK")"
chk_contains "env-self surfaces pending" "1 封" "$out"
chk_contains "output is SessionStart JSON" "SessionStart" "$out"
out="$(env -u CLAUDE_PROJECT_DIR AGENT_MAIL_SELF=alpha "$MAILCHECK")"; rc=$?
chk_eq "empty inbox silent" "" "$out"; chk_eq "empty inbox exit 0" 0 "$rc"
bash "$BUSBIN" send alpha delta hello-d "给 delta" >/dev/null
out="$(env -u AGENT_MAIL_SELF CLAUDE_PROJECT_DIR=/tmp/delta "$MAILCHECK")"
chk_contains "registry workdir lookup resolves self" "delta" "$out"
out="$(env -u AGENT_MAIL_SELF CLAUDE_PROJECT_DIR=/tmp/delta/deep/sub "$MAILCHECK")"
chk_contains "subdir of workdir also resolves" "delta" "$out"
out="$(env -u AGENT_MAIL_SELF CLAUDE_PROJECT_DIR=/nowhere/else "$MAILCHECK")"; rc=$?
chk_eq "no identity match silent" "" "$out"; chk_eq "no identity exit 0" 0 "$rc"

summary
