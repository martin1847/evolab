#!/usr/bin/env bash
# 电在回路 (shock-in-the-loop) — hard gate for meta/structure-not-discipline.md's L1 exit
# contract (deny-with-directions): every DENY message a shipped hook can emit must point back
# to the owning doc (a *.md reference), AND at least one referenced doc must actually exist
# under skills/ (pointer rot = a shock with directions to nowhere). Scans SOURCE, so any
# future DENY added without a valid pointer fails here automatically.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== hook DENY messages carry a resolvable doc pointer =="

scan() { # $1 python-hook-source; rc 1 on missing/unresolvable pointer or zero denies
  python3 - "$1" <<'PY'
import ast, glob as g, os, re, sys
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
def resolvable(tok):  # skill-rooted path or unique basename under skills/
    tok = tok.strip(".,;)")
    return (os.path.exists(os.path.join("..", "skills", tok))
            or bool(g.glob(os.path.join("..", "skills", "**", os.path.basename(tok)), recursive=True)))
bad = [str(ln) for ln, s in msgs
       if not any(resolvable(t) for t in re.findall(r"[\w./-]+\.md", s))]
print(f"{len(msgs)} denies, missing/unresolvable-pointer lines: {','.join(bad) if bad else 'none'}")
sys.exit(1 if bad or not msgs else 0)
PY
}

# scanner self-test: pointer-less and rotten-pointer DENYs must fail; a resolvable one must
# pass — including the f-string + implicit-concatenation shapes the real guards use.
FIX="$(mktemp -d /tmp/aw-denyptr.XXXXXX)"
cat > "$FIX/bad.py" <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. " "Do the other thing instead.\n")
EOF
cat > "$FIX/rotten.py" <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. Read: no-such-skill/GHOST.md.\n")
EOF
cat > "$FIX/good.py" <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. Do the other thing. Read: agent-mail/SKILL.md.\n")
EOF
out="$(scan "$FIX/bad.py")"; rc=$?
chk_eq "scanner flags pointer-less DENY" 1 "$rc"
chk_contains "scanner names the offending line" "pointer lines: 3" "$out"
out="$(scan "$FIX/rotten.py")"; rc=$?
chk_eq "scanner flags rotten pointer (target missing)" 1 "$rc"
out="$(scan "$FIX/good.py")"; rc=$?
chk_eq "scanner passes resolvable DENY" 0 "$rc"
rm -rf "$FIX"

# the shipped guards
for f in ../skills/cto-orchestration/references/agent-watch/cto-guard-bash.py \
         ../skills/cto-orchestration/references/agent-watch/cto-guard-agent.py \
         ../skills/agent-mail/mail-guard.py; do
  out="$(scan "$f")"; rc=$?
  chk_eq "$(basename "$f"): every DENY carries a resolvable doc pointer" 0 "$rc"
  chk_not_contains "$(basename "$f"): scanner saw denies" "0 denies" "$out"
done

summary
