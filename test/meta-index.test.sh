#!/usr/bin/env bash
# README meta-row completeness gate — the meta enumeration is a list consumed as complete,
# so it gets the surface-before-points treatment itself: every meta/*.md slug must appear
# in the README meta row, and every （slug） token in the row must resolve to a real file.
# Checker is root-parameterized; known-bad sandboxes prove both directions red.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }

check(){ # $1 = repo root; prints problems, exit 1 if any
python3 - "$1" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
files = {os.path.basename(p)[:-3] for p in glob.glob(os.path.join(root, "meta", "*.md"))}
row = ""
for line in open(os.path.join(root, "README.md"), encoding="utf-8"):
    if line.startswith("| **`meta/`**"):
        row = line
        break
bad = []
if not row:
    bad.append("README meta row missing")
listed = set(re.findall(r"（([a-z0-9_-]+)）", row))
for slug in sorted(files - listed):
    bad.append(f"meta/{slug}.md not enumerated in README meta row")
for slug in sorted(listed - files):
    bad.append(f"README meta row names （{slug}） but meta/{slug}.md does not exist")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

echo "== meta-index.test =="
T="$(mktemp -d)"

# 1. sandbox clean: two essays, both enumerated → green
mkdir -p "$T/g/meta"
touch "$T/g/meta/alpha-one.md" "$T/g/meta/beta_two.md"
printf '| **`meta/`** | 甲（alpha-one）、乙（beta_two）。 |\n' > "$T/g/README.md"
out="$(check "$T/g")"; assert_rc $? 0 "clean sandbox green"

# 2. known-bad: essay exists but not enumerated → red, names the file
mkdir -p "$T/b1/meta"
touch "$T/b1/meta/alpha-one.md" "$T/b1/meta/gamma-three.md"
printf '| **`meta/`** | 甲（alpha-one）。 |\n' > "$T/b1/README.md"
out="$(check "$T/b1")"; rc=$?
assert_rc "$rc" 1 "missing enumeration red"
assert_has "$out" "gamma-three" "names the unlisted essay"

# 3. known-bad: row names a nonexistent essay → red (dangling entry)
mkdir -p "$T/b2/meta"
touch "$T/b2/meta/alpha-one.md"
printf '| **`meta/`** | 甲（alpha-one）、幽灵（ghost-essay）。 |\n' > "$T/b2/README.md"
out="$(check "$T/b2")"; rc=$?
assert_rc "$rc" 1 "dangling entry red"
assert_has "$out" "ghost-essay" "names the dangling slug"

# 4. the real tree is complete both ways
out="$(check "$REPO")"; rc=$?
assert_rc "$rc" 0 "real tree meta enumeration complete"
[ -n "$out" ] && echo "$out"

rm -rf "$T"
echo "== meta-index: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
