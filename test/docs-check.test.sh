#!/usr/bin/env bash
# Test suite for repo-governance-bootstrap references/docs-check.sh (anti-rot gate).
# Hermetic: each case builds a temp governance skeleton, runs the gate, asserts
# exit code + key output lines. NOTHING under test is modified.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/repo-governance-bootstrap/references/docs-check.sh"
TODAY="$(date +%F)"
pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "  FAIL: $*"; }
assert_rc(){ [ "$1" = "$2" ] && ok || no "$3: expected rc=$2 got $1"; }
assert_has(){ printf '%s' "$1" | grep -qF "$2" && ok || no "$3: output missing '$2'"; }
assert_no(){ printf '%s' "$1" | grep -qF "$2" && no "$3: output should NOT have '$2'" || ok; }

# green minimal skeleton; echo root path
mkskel(){
  local d; d="$(mktemp -d)"
  mkdir -p "$d/docs/decisions"
  printf '# ADR-0001: Scope\n' > "$d/docs/decisions/ADR-0001-scope.md"
  printf '# Index\n\n- [ADR-0001](decisions/ADR-0001-scope.md)\n' > "$d/docs/INDEX.md"
  printf '# Active Context\n\nLast rewritten: %s\n' "$TODAY" > "$d/docs/ACTIVE_CONTEXT.md"
  printf '# AGENTS\n\nshort constitution\n' > "$d/AGENTS.md"
  printf '@AGENTS.md\n' > "$d/CLAUDE.md"
  echo "$d"
}
run(){ bash "$SCRIPT" "$1" 2>&1; }
healrun(){ bash "$SCRIPT" "$1" --heal 2>&1; }
# skeleton with a git dir (heal refuses to rewrite where there is no rollback)
mkheal(){ local d; d="$(mkskel)"; mkdir -p "$d/.git"; echo "$d"; }

echo "== docs-check.test =="

# A — green skeleton → exit 0, clean
r="$(mkskel)"; out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "A/green rc"
assert_has "$out" "clean" "A/green clean line"
assert_no  "$out" "FAIL" "A/green no FAIL"

# B — broken relative link → FAIL, exit 1
r="$(mkskel)"; printf '\n[gone](decisions/ADR-0999-gone.md)\n' >> "$r/docs/INDEX.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "B/broken-link rc"
assert_has "$out" "broken link" "B/broken-link flagged"

# C — stale ACTIVE_CONTEXT → WARN only, exit 0
r="$(mkskel)"; printf '# AC\n\nLast rewritten: 2020-01-01\n' > "$r/docs/ACTIVE_CONTEXT.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "C/stale-AC rc (warn≠fail)"
assert_has "$out" "stale snapshot" "C/stale-AC warns"

# D — AGENTS.md over 200 lines → WARN only, exit 0
r="$(mkskel)"; seq 210 | sed 's/^/line /' > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "D/oversize-lines rc (warn≠fail)"
assert_has "$out" ">200" "D/oversize-lines warns"

# E — combined AGENTS+CLAUDE over 32KiB → FAIL, exit 1
r="$(mkskel)"; python3 -c "print('x' * 34000)" > "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 1 "E/32KiB rc"
assert_has "$out" "32KiB" "E/32KiB flagged"

# F — phantom backticked path → WARN only, exit 0; existing path stays silent
r="$(mkskel)"; mkdir -p "$r/src"; touch "$r/src/real.py"
printf '\nsee `src/real.py` and `src/ghost.py`\n' >> "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "F/phantom rc (warn≠fail)"
assert_has "$out" "src/ghost.py" "F/phantom flagged"
assert_no  "$out" "src/real.py" "F/existing path silent"

# G — placeholder/glob/url paths are skipped (no false positive)
r="$(mkskel)"; printf '\n`docs/<module>.md` `roadmap/*.md` `https://x.y/z.md`\n' >> "$r/AGENTS.md"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "G/placeholders rc"
assert_no  "$out" "phantom" "G/placeholders not flagged"

# H — check mode is byte-identical with the heal code present (no rewrite, no heal lines)
r="$(mkheal)"; printf '\nsee `docs/ADR-0001-scope.md`\n' >> "$r/AGENTS.md"
before="$(md5sum < "$r/AGENTS.md")"
out="$(run "$r")"; rc=$?
assert_rc "$rc" 0 "H/check-mode rc"
assert_has "$out" "phantom path" "H/check-mode still warns"
assert_no  "$out" "heal:" "H/check-mode emits no heal line"
[ "$before" = "$(md5sum < "$r/AGENTS.md")" ] && ok || no "H/check-mode mutated the file"

# I — unique same-basename candidate → rewritten, heal line, second check is WARN-free
r="$(mkheal)"; printf '\nsee `docs/ADR-0001-scope.md`\n' >> "$r/AGENTS.md"
out="$(healrun "$r")"; rc=$?
assert_rc "$rc" 0 "I/heal rc"
assert_has "$out" "heal: AGENTS.md:5 docs/ADR-0001-scope.md -> docs/decisions/ADR-0001-scope.md" "I/heal line"
assert_has "$(cat "$r/AGENTS.md")" '`docs/decisions/ADR-0001-scope.md`' "I/file rewritten"
assert_has "$(run "$r")" "clean ✓ (0 WARN)" "I/healed pointer re-resolves clean"

# J — two files share the basename → ambiguous, untouched
r="$(mkheal)"; mkdir -p "$r/docs/notes"; printf '# copy\n' > "$r/docs/notes/ADR-0001-scope.md"
printf '\nsee `docs/ADR-0001-scope.md`\n' >> "$r/AGENTS.md"
out="$(healrun "$r")"; rc=$?
assert_has "$out" "skip: AGENTS.md:5 docs/ADR-0001-scope.md (ambiguous)" "J/ambiguous skip"
assert_has "$(cat "$r/AGENTS.md")" '`docs/ADR-0001-scope.md`' "J/ambiguous untouched"

# K — ref names a directory the candidate does not sit under → dir-mismatch, untouched
r="$(mkheal)"; printf '\nsee `docs/guides/ADR-0001-scope.md`\n' >> "$r/AGENTS.md"
out="$(healrun "$r")"; rc=$?
assert_has "$out" "skip: AGENTS.md:5 docs/guides/ADR-0001-scope.md (dir-mismatch)" "K/dir-mismatch skip"
assert_has "$(cat "$r/AGENTS.md")" '`docs/guides/ADR-0001-scope.md`' "K/dir-mismatch untouched"

# L — two backticked refs on one line → multi-ref, untouched (splice ambiguity is not healed)
r="$(mkheal)"; printf '\nsee `docs/ADR-0001-scope.md` and `docs/INDEX.md`\n' >> "$r/AGENTS.md"
out="$(healrun "$r")"; rc=$?
assert_has "$out" "skip: AGENTS.md:5 docs/ADR-0001-scope.md (multi-ref)" "L/multi-ref skip"
assert_has "$(cat "$r/AGENTS.md")" '`docs/ADR-0001-scope.md`' "L/multi-ref untouched"

echo "== docs-check: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
