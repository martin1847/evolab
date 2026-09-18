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
#   heal    — `--heal` (opt-in, never in check mode) rewrites a dead backticked path whose
#             basename is unique under docs/ and whose directory segments the candidate covers;
#             every other pointer is skipped with a reason code. Explicit, mechanical, no guesses.
#
# Usage: bash docs-check.sh [repo-root] [--heal]   (default: cwd) — wire into pre-commit or CI.
# Exit 1 on any FAIL; WARNs never block.
set -eu
HEAL=0
ROOT=.
for a in "$@"; do
  case "$a" in --heal) HEAL=1 ;; *) ROOT="$a" ;; esac
done
python3 - "$ROOT" "$HEAL" <<'PY'
import os, re, sys, time

root = sys.argv[1]
heal = sys.argv[2] == "1"
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

# 5. heal pass — opt-in rewrite of the mechanically unambiguous subset of check 4's phantoms
def segs(pth): return [s for s in pth.split("/") if s and s != "."]

def phantom(ref, md):
    return not os.path.exists(p(ref)) and not os.path.exists(os.path.join(os.path.dirname(md), ref))

def live_refs(line):
    return [m for m in PATH_RE.finditer(line)
            if not (any(c in m.group(1) for c in "*<>{}$") or m.group(1).startswith(("http", "~")))]

SAFE_RE = re.compile(r"[A-Za-z0-9_./-]+\Z")

def heal_target(ref, md, index):
    """(successor ref or None, reason). Healed only when one docs/ file carries the dead ref's
    basename and its directory segments cover the ref's — anything else is a guess, so it skips."""
    cands = index.get(os.path.basename(ref), [])
    if len(cands) != 1:
        return None, "ambiguous" if cands else "gone"
    cand_segs = segs(os.path.dirname(cands[0]))
    ref_segs = [s for s in segs(os.path.dirname(ref)) if s != ".."]
    for s in (cand_segs, ref_segs):
        if s[:1] == ["docs"]:
            del s[0]
    if not set(ref_segs) <= set(cand_segs):
        return None, "dir-mismatch"
    # write the successor in the reading the dead ref used, so check 4 re-resolves it next run
    new = os.path.relpath(p(cands[0]), root if ref.startswith("docs/") else os.path.dirname(md))
    if not SAFE_RE.match(new):
        return None, "unsafe-target"
    return new, "ok"

if heal and not os.path.exists(p(".git")):
    print("  skip: heal (not-a-git-repo — a rewrite would have no rollback)")
    heal = False
if heal:
    index = {}
    for dirpath, dirnames, filenames in os.walk(p("docs")):
        dirnames[:] = [d for d in dirnames if d not in ("archive", "node_modules", ".git")]
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            if not os.path.islink(fp):
                index.setdefault(fn, []).append(os.path.relpath(fp, root))
    for md in mds:
        rel = os.path.relpath(md, root)
        if os.path.islink(md):
            print(f"  skip: {rel} (symlink)")
            continue
        lines = open(md, encoding="utf-8", newline="").readlines()
        healed = False
        for i, line in enumerate(lines, 1):
            refs = live_refs(line)
            dead = [m for m in refs if phantom(m.group(1), md)]
            if not dead:
                continue
            ref = dead[0].group(1)
            if len(refs) > 1:
                print(f"  skip: {rel}:{i} {ref} (multi-ref)")
                continue
            new, why = heal_target(ref, md, index)
            if new is None:
                print(f"  skip: {rel}:{i} {ref} ({why})")
                continue
            lines[i - 1] = line[:dead[0].start(1)] + new + line[dead[0].end(1):]
            healed = True
            print(f"  heal: {rel}:{i} {ref} -> {new}")
        if healed:
            open(md, "w", encoding="utf-8", newline="").writelines(lines)

print()
if fails:
    print(f"docs-check: {fails} FAIL, {warns} WARN — FAIL"); sys.exit(1)
print(f"docs-check: clean ✓ ({warns} WARN)")
PY
