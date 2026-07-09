#!/usr/bin/env bash
# docs-check — mechanical anti-rot gate for the governance skeleton (bootstrap step 12).
#
# Rot is a workflow problem: nothing verifies docs against code unless a gate does.
# Four checks, each backed by a documented failure mode:
#   1. size    — AGENTS.md/CLAUDE.md over budget (>200 lines WARN; combined >32KiB FAIL:
#                Codex silently truncates merged instruction files at 32KiB).
#   2. links   — relative .md links in docs/ + AGENTS.md must resolve (FAIL on broken).
#   3. fresh   — ACTIVE_CONTEXT.md "Last rewritten:" older than $DOCS_FRESH_DAYS (default 14)
#                or over ~80 lines → WARN (snapshot is the fastest-rotting doc in the repo).
#   4. paths   — backticked repo paths (`a/b.ext`) in AGENTS.md + docs/*.md that no longer
#                exist → WARN (study: 23% of repos carry context files referencing deleted
#                code elements; conservative pattern, placeholders/globs/URLs skipped).
#
# Usage: bash docs-check.sh [repo-root]   (default: cwd) — wire into pre-commit or CI.
# Exit 1 on any FAIL; WARNs never block.
set -eu
ROOT="${1:-.}"
python3 - "$ROOT" <<'PY'
import os, re, sys, time

root = sys.argv[1]
fails, warns = 0, 0
def fail(m):  # blocking
    global fails; fails += 1; print(f"  ✗ FAIL {m}")
def warn(m):  # advisory
    global warns; warns += 1; print(f"  ⚠ WARN {m}")

def p(*a): return os.path.join(root, *a)

# 1. size gate
combined = 0
for f in ("AGENTS.md", "CLAUDE.md"):
    fp = p(f)
    if not os.path.isfile(fp):
        continue
    data = open(fp, encoding="utf-8", errors="replace").read()
    combined += len(data.encode())
    n = data.count("\n") + 1
    if n > 200:
        warn(f"{f}: {n} lines (>200 — adherence drops as instruction files bloat)")
if combined > 32 * 1024:
    fail(f"AGENTS.md+CLAUDE.md combined {combined} bytes (>32KiB — Codex silently truncates)")

# collect markdown files in scope
mds = []
for base in (p("docs"),):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in ("archive", "node_modules", ".git")]
        mds += [os.path.join(dirpath, fn) for fn in filenames if fn.endswith(".md")]
for f in ("AGENTS.md",):
    if os.path.isfile(p(f)):
        mds.append(p(f))

# 2. relative link gate
for md in mds:
    body = open(md, encoding="utf-8", errors="replace").read()
    for target in re.findall(r"\]\(([^)#\s]+?\.md)(?:#[^)]*)?\)", body):
        if target.startswith(("http://", "https://", "mailto:")) or "<" in target:
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(md), target))
        if not os.path.exists(resolved):
            fail(f"{os.path.relpath(md, root)}: broken link -> {target}")

# 3. ACTIVE_CONTEXT freshness
ac = p("docs", "ACTIVE_CONTEXT.md")
if os.path.isfile(ac):
    body = open(ac, encoding="utf-8", errors="replace").read()
    n = body.count("\n") + 1
    if n > 80:
        warn(f"ACTIVE_CONTEXT.md: {n} lines (snapshot contract is ~60 — journal creep?)")
    m = re.search(r"Last rewritten:\s*(\d{4})-(\d{2})-(\d{2})", body)
    if not m:
        warn("ACTIVE_CONTEXT.md: no 'Last rewritten: YYYY-MM-DD' header (freshness unknowable)")
    else:
        age = (time.time() - time.mktime(time.strptime("-".join(m.groups()), "%Y-%m-%d"))) / 86400
        limit = int(os.environ.get("DOCS_FRESH_DAYS", "14"))
        if age > limit:
            warn(f"ACTIVE_CONTEXT.md: last rewritten {age:.0f}d ago (>{limit}d — stale snapshot misleads every new session)")

# 4. phantom path references (conservative: real-looking repo paths only)
PATH_RE = re.compile(r"`([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+\.[A-Za-z0-9]{1,8})`")
for md in mds:
    body = open(md, encoding="utf-8", errors="replace").read()
    for ref in set(PATH_RE.findall(body)):
        if any(c in ref for c in "*<>{}$") or ref.startswith(("http", "~")):
            continue
        if not os.path.exists(p(ref)) and not os.path.exists(os.path.join(os.path.dirname(md), ref)):
            warn(f"{os.path.relpath(md, root)}: references `{ref}` which does not exist (phantom path)")

print()
if fails:
    print(f"docs-check: {fails} FAIL, {warns} WARN — FAIL"); sys.exit(1)
print(f"docs-check: clean ✓ ({warns} WARN)")
PY
