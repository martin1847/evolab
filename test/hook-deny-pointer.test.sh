#!/usr/bin/env bash
# 电在回路 (shock-in-the-loop) — hard gate for meta/structure-not-discipline.md's L1 exit
# contract (deny-with-directions): every DENY message a shipped hook can emit must carry a
# literal `Read: <path>.md` pointer that resolves as a skills-rooted PATH. The old basename
# fallback accepted any same-named .md anywhere under skills/, so stale-directory pointers
# and prose-only mentions passed (cold-review M2, 2026-07-29). Scans SOURCE, so any future
# DENY added without a valid pointer fails here automatically.
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
def resolvable(tok):  # skills-rooted RELATIVE path only — an absolute tok makes os.path.join
    # DISCARD the skills prefix (light-review P1 2026-07-30), and ../ could traverse out, so
    # reject absolute and require realpath containment under the skills root.
    tok = tok.strip(".,;)")
    if tok.startswith("/"):
        return False
    root = os.path.realpath(os.path.join("..", "skills"))
    p = os.path.realpath(os.path.join(root, tok))
    return p.startswith(root + os.sep) and os.path.exists(p)
bad = [str(ln) for ln, s in msgs
       if not any(resolvable(t) for t in re.findall(r"Read:\s*([\w./-]+\.md)", s))]
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
cat > "$FIX/staledir.py" <<'EOF'
import sys
def main(x):
    # needle split in SOURCE so the repo-wide stale-path gate never matches this fixture;
    # the AST scanner joins adjacent literals, so the scanner still sees the full stale path
    sys.stderr.write(f"DENY: thing {x} refused. Read: cto-orchestration/references/agent-" "watch/README.md.\n")
EOF
cat > "$FIX/prose.py" <<'EOF'
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused (frontend-verify.md mentioned in prose, no Read pointer).\n")
EOF
out="$(scan "$FIX/bad.py")"; rc=$?
chk_eq "scanner flags pointer-less DENY" 1 "$rc"
chk_contains "scanner names the offending line" "pointer lines: 3" "$out"
out="$(scan "$FIX/rotten.py")"; rc=$?
chk_eq "scanner flags rotten pointer (target missing)" 1 "$rc"
# absolute pointer to an EXISTING file outside skills/ — join discards the prefix, must not pass
touch "$FIX/target.md"
cat > "$FIX/abs.py" <<EOF
import sys
def main(x):
    sys.stderr.write(f"DENY: thing {x} refused. Read: $FIX/target.md.\n")
EOF
out="$(scan "$FIX/staledir.py")"; rc=$?
chk_eq "scanner flags stale-directory pointer (basename exists elsewhere)" 1 "$rc"
out="$(scan "$FIX/abs.py")"; rc=$?
chk_eq "scanner flags absolute pointer outside skills root" 1 "$rc"
out="$(scan "$FIX/prose.py")"; rc=$?
chk_eq "scanner flags prose-only .md mention without Read:" 1 "$rc"
out="$(scan "$FIX/good.py")"; rc=$?
chk_eq "scanner passes resolvable DENY" 0 "$rc"
rm -rf "$FIX"

# the shipped guards. cto-guard-stop.py belongs here even though its DENY leaves through a Stop
# `{"decision":"block","reason":…}` rather than stderr: the scanner judges the LITERAL, and the
# exit contract it enforces (why + 正路 + resolvable pointer) is the same one — a block whose
# reason has no pointer leaves the model with a refusal and no page to read.
for f in ../skills/cto-orchestration/references/agentctl/cto-guard-bash.py \
         ../skills/cto-orchestration/references/agentctl/cto-guard-stop.py \
         ../skills/cto-orchestration/references/agentctl/cto-guard-agent.py \
         ../skills/cto-orchestration/references/agentctl/cto-guard-edit.py \
         ../skills/agent-mail/mail-guard.py; do
  out="$(scan "$f")"; rc=$?
  chk_eq "$(basename "$f"): every DENY carries a resolvable doc pointer" 0 "$rc"
  # word-anchored: a plain "0 denies" needle false-fires the moment a file reaches 10 denies
  # ("10 denies" contains it) — bit us live 2026-08-13 when rule 10 landed as the 10th DENY.
  if printf '%s' "$out" | grep -qE '(^|[^0-9])0 denies'; then
    chk_eq "$(basename "$f"): scanner saw denies" "some" "0"
  else
    chk_eq "$(basename "$f"): scanner saw denies" "some" "some"
  fi
done

# seat-liveness.py is REMINDER-ONLY (plain stdout at SessionStart/UserPromptSubmit) and has no
# DENY at all, so it cannot join the loop above: that loop requires >=1 deny, by design. It is
# accounted for here instead, through the SAME scanner — the day a DENY appears in it, this arm
# reds and says where the file has to move, instead of the file silently sitting outside every
# pointer gate.
out="$(scan ../skills/cto-orchestration/references/agentctl/seat-liveness.py)"; rc=$?
chk_eq "seat-liveness.py: reminder-only, zero DENY literals (else move it into the loop above)" 1 \
  "$rc"
chk_contains "seat-liveness.py: the scanner really weighed it and found none" "0 denies" "$out"

summary
