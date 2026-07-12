#!/usr/bin/env bash
# 电必带路 (deny-with-directions) — hard gate for meta/structure-not-discipline.md's L1 exit
# contract: every DENY message a shipped hook can emit must point back to the owning doc
# (a *.md reference), so the shock teaches instead of just blocking. Scans SOURCE, so any
# future DENY added without a pointer fails here automatically.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== hook DENY messages carry a doc pointer =="

scan() { # $1 python-hook-source; prints "N denies, missing-pointer lines: ..."; rc 1 on violation/none
  python3 - "$1" <<'PY'
import ast, re, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
inner = set()  # Constants inside f-strings — consumed via their JoinedStr, skip standalone
for node in ast.walk(tree):
    if isinstance(node, ast.JoinedStr):
        for c in node.values:
            inner.add(id(c))
msgs = []
for node in ast.walk(tree):
    if isinstance(node, ast.JoinedStr):
        s = "".join(c.value for c in node.values if isinstance(c, ast.Constant) and isinstance(c.value, str))
        if s.lstrip().startswith("DENY"):
            msgs.append((node.lineno, s))
    elif (isinstance(node, ast.Constant) and id(node) not in inner
          and isinstance(node.value, str) and node.value.lstrip().startswith("DENY")):
        msgs.append((node.lineno, node.value))
bad = [str(ln) for ln, s in msgs if not re.search(r"\S+\.md", s)]
print(f"{len(msgs)} denies, missing-pointer lines: {','.join(bad) if bad else 'none'}")
sys.exit(1 if bad or not msgs else 0)
PY
}

# scanner self-test: a pointer-less DENY must fail, a pointered one must pass — including
# the f-string + implicit-concatenation shapes the real guards use.
mkdir -p /tmp/aw-denyptr.$$
cat > /tmp/aw-denyptr.$$/bad.py <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. " "Do the other thing instead.\n")
EOF
cat > /tmp/aw-denyptr.$$/good.py <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. " "Do the other thing. Read: some-skill/SKILL.md.\n")
EOF
out="$(scan /tmp/aw-denyptr.$$/bad.py)"; rc=$?
chk_eq "scanner flags pointer-less DENY" 1 "$rc"
chk_contains "scanner names the offending line" "missing-pointer lines: 3" "$out"
out="$(scan /tmp/aw-denyptr.$$/good.py)"; rc=$?
chk_eq "scanner passes pointered DENY" 0 "$rc"
rm -rf /tmp/aw-denyptr.$$

# the shipped guards
for f in ../skills/cto-orchestration/references/agent-watch/cto-guard-bash.py \
         ../skills/cto-orchestration/references/agent-watch/cto-guard-agent.py \
         ../skills/agent-mail/mail-guard.py; do
  out="$(scan "$f")"; rc=$?
  chk_eq "$(basename "$f"): every DENY carries a doc pointer" 0 "$rc"
  chk_not_contains "$(basename "$f"): scanner saw denies" "0 denies" "$out"
done

summary
