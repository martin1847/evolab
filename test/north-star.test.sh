#!/usr/bin/env bash
# Hermetic gate for docs/NORTH_STAR.md — the principle-reference integrity check.
# A NORTH_STAR entry is load-bearing only if references to it cannot rot: any `NS-<n>`
# mentioned anywhere in the tracked tree must exist as a heading, IDs must be unique and
# well-formed, and the file must carry its semver revision line. (Same disease family as
# dead DENY pointers — hook-deny-pointer.test.sh precedent.)
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== north-star =="

# the checker takes a root dir so the same logic runs against the real repo (known-good)
# and against synthetic sandboxes (known-bad) — self-proving, not self-trusting.
check() { # $1 root ; prints violations, exits 0 iff clean
  python3 - "$1" <<'PY'
import os, re, subprocess, sys
root = sys.argv[1]
ns_path = os.path.join(root, "docs", "NORTH_STAR.md")
bad = []
if not os.path.isfile(ns_path):
    bad.append("docs/NORTH_STAR.md missing")
    print("\n".join(bad)); sys.exit(1)
body = open(ns_path, encoding="utf-8").read()
if not re.search(r"(?m)^> v\d+\.\d+\.\d+\b", body):
    bad.append("no semver revision line (`> vX.Y.Z`)")
heads = re.findall(r"(?m)^## (NS-\d+)\b", body)
if not heads:
    bad.append("no NS-<n> headings")
if len(heads) != len(set(heads)):
    bad.append("duplicate NS ids: " + ",".join(sorted({h for h in heads if heads.count(h) > 1})))
defined = set(heads)
# every NS-<digit> reference in TRACKED files must resolve (NS-x/NS-y placeholders don't match)
try:
    files = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True,
                           text=True, check=True).stdout.split()
except Exception:
    files = []
    for dp, _, fns in os.walk(root):
        if ".git" in dp: continue
        files += [os.path.relpath(os.path.join(dp, f), root) for f in fns]
for rel in files:
    if not rel.endswith((".md", ".sh", ".py")) or rel == "docs/NORTH_STAR.md":
        continue
    try:
        text = open(os.path.join(root, rel), encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    for ref in set(re.findall(r"\bNS-\d+\b", text)):
        if ref not in defined:
            bad.append(f"{rel}: dangling reference {ref}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# KNOWN-GOOD: the real repo is clean
out="$(check "$(cd .. && pwd)")"; rc=$?
chk_eq "repo NORTH_STAR passes the gate" 0 "$rc"
chk_eq "and silently" "" "$out"

# KNOWN-BAD battery in a sandbox (no git dir -> walk fallback)
sandbox_new
mkdir -p "$SANDBOX/docs"
printf '# NS\n> v1.0.0\n\n## NS-1 x\n\n## NS-2 y\n' > "$SANDBOX/docs/NORTH_STAR.md"
printf 'goal touches NS-2 fine\n' > "$SANDBOX/ok.md"
out="$(check "$SANDBOX")"; rc=$?
chk_eq "sandbox baseline is green" 0 "$rc"

printf 'this cites NS-9 which does not exist\n' > "$SANDBOX/bad.md"
out="$(check "$SANDBOX")"; rc=$?
chk_eq "KNOWN-BAD: dangling NS reference reds" 1 "$rc"
chk_contains "KNOWN-BAD: names the file and id" "bad.md: dangling reference NS-9" "$out"
rm "$SANDBOX/bad.md"

printf '# NS\n> v1.0.0\n\n## NS-1 x\n\n## NS-1 dup\n' > "$SANDBOX/docs/NORTH_STAR.md"
out="$(check "$SANDBOX")"; rc=$?
chk_eq "KNOWN-BAD: duplicate NS id reds" 1 "$rc"
chk_contains "KNOWN-BAD: names the duplicate" "duplicate NS ids: NS-1" "$out"

printf '# NS\n\n## NS-1 x\n' > "$SANDBOX/docs/NORTH_STAR.md"
out="$(check "$SANDBOX")"; rc=$?
chk_eq "KNOWN-BAD: missing semver revision line reds" 1 "$rc"

rm "$SANDBOX/docs/NORTH_STAR.md"
out="$(check "$SANDBOX")"; rc=$?
chk_eq "KNOWN-BAD: missing NORTH_STAR reds" 1 "$rc"

rm -rf "$SANDBOX"
summary
