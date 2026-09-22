#!/usr/bin/env bash
# codegraph-hooks contract: the hook must keep a worktree's index fresh on the three write/switch
# events, and must NEVER fail or delay the git operation that fired it.
#
# THE HEADLINE (①/②): a commit in a tree that HAS an index runs `codegraph sync -q`; the same
# commit in a tree that has NO index runs nothing. Before 0922 the script had no sync branch at
# all, so every worktree's index froze at init time and `codegraph explore` answered from the
# tree as it was — the failure this file exists to pin.
#
# Mock strategy: a fake `codegraph` on the test PATH appends its argv to $SANDBOX/cg.log. The
# real binary is never run (init/sync on a fixture repo would be slow and would write a real
# index). Because the script BACKGROUNDS codegraph (nohup … &) the hook returns before the shim
# writes, so every read of cg.log goes through the kit's bounded wait (2s here) — and the
# negative cases wait the SAME 2s before concluding "nothing ran", otherwise absence would only
# mean "not yet".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-testkit.sh"

SH="$AW_DIR/codegraph-hooks.sh"
LEGACY="$AW_DIR/post-checkout-codegraph.sh"
TRIES=20   # x 0.1s = 2s, the whole window a case gets in either direction

if ! command -v git >/dev/null 2>&1; then
  echo "  FAIL REQUIRED TOOL MISSING: git — the hook branches on git-dir vs git-common-dir"
  echo "-- 0 passed, 1 failed --"; echo FAIL; exit 1
fi

sandbox_new
trap 'sandbox_clean' EXIT

# fake codegraph: argv census, exit code under fixture control (case ⑥).
cat > "$BIN/codegraph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/cg.log"
exit \${FAKE_CG_RC:-0}
EOF
chmod +x "$BIN/codegraph"

REPO="$SANDBOX/repo"
mkdir -p "$REPO" "$SANDBOX/hooks"
git -C "$REPO" init -q
echo hello > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm first
SHA="$(git -C "$REPO" rev-parse HEAD)"

link() { # $1 hook name -> path of a symlink to the script under test, named like git names it
  ln -sf "${2:-$SH}" "$SANDBOX/hooks/$1"
  printf '%s\n' "$SANDBOX/hooks/$1"
}
run_hook() { # $1 cwd  $2 link path  $3... git's positional args -> echoes rc
  rm -f "$SANDBOX/cg.log"
  ( cd "$1" && bash "$2" "${@:3}" ) 2>/dev/null
  echo "$?"
}
logged() { cat "$SANDBOX/cg.log" 2>/dev/null || true; }

echo "== ① post-commit with an index: the commit is followed by a sync =="
mkdir -p "$REPO/.codegraph"
rc="$(run_hook "$REPO" "$(link post-commit)")"
chk_eq "① the commit hook exits 0" 0 "$rc"
chk_eq "① post-commit in an indexed tree runs codegraph sync" 1 \
  "$(seen "$SANDBOX/cg.log" 'sync -q' "$TRIES")"

echo "== ② PAIRED NEGATIVE: same hook, same commit, no index -> nothing runs =="
rm -rf "$REPO/.codegraph"
rc="$(run_hook "$REPO" "$(link post-commit)")"
chk_eq "② the commit hook still exits 0" 0 "$rc"
chk_eq "② post-commit in an unindexed tree runs no sync" 0 \
  "$(seen "$SANDBOX/cg.log" 'sync' "$TRIES")"
chk_not_contains "② and no init either — an unindexed tree is not ours to index" init "$(logged)"

echo "== ③ post-merge with an index: a merge is a content change like any other =="
mkdir -p "$REPO/.codegraph"
rc="$(run_hook "$REPO" "$(link post-merge)" 0)"
chk_eq "③ the merge hook exits 0" 0 "$rc"
chk_eq "③ post-merge in an indexed tree runs codegraph sync" 1 \
  "$(seen "$SANDBOX/cg.log" 'sync -q' "$TRIES")"

echo "== ④ post-checkout on a freshly created linked worktree: init, never sync =="
git -C "$REPO" worktree add -q "$SANDBOX/wt2" -b b2
chk_eq "④ fixture premise: the new worktree carries no index" 0 \
  "$([ -e "$SANDBOX/wt2/.codegraph" ] && echo 1 || echo 0)"
rc="$(run_hook "$SANDBOX/wt2" "$(link post-checkout)" "$SHA" "$SHA" 1)"
chk_eq "④ the checkout hook exits 0" 0 "$rc"
chk_eq "④ a new linked worktree gets codegraph init" 1 "$(seen "$SANDBOX/cg.log" init "$TRIES")"
chk_not_contains "④ and not a sync — there is no index to sync yet" sync "$(logged)"

echo "== ⑤ post-checkout in the MAIN checkout: sync the existing index, never init =="
rc="$(run_hook "$REPO" "$(link post-checkout)" "$SHA" "$SHA" 1)"
chk_eq "⑤ the checkout hook exits 0" 0 "$rc"
chk_eq "⑤ a branch switch in the indexed main checkout runs sync" 1 \
  "$(seen "$SANDBOX/cg.log" 'sync -q' "$TRIES")"
chk_not_contains "⑤ the main checkout is never init'd by this hook" init "$(logged)"

echo "== ⑥ codegraph failing must not fail the git operation =="
export FAKE_CG_RC=7
rc="$(run_hook "$REPO" "$(link post-commit)")"
chk_eq "⑥ hook exits 0 even though codegraph exits 7" 0 "$rc"
chk_eq "⑥ and the failing run really happened (rc is not being read at all)" 1 \
  "$(seen "$SANDBOX/cg.log" 'sync -q' "$TRIES")"
unset FAKE_CG_RC

echo "== ⑦ no codegraph on PATH: silent no-op =="
STRIPPED=/usr/bin:/bin
chk_eq "⑦ gauge: the stripped PATH really has no codegraph" "" \
  "$(PATH="$STRIPPED" bash -c 'command -v codegraph' 2>/dev/null || true)"
rm -f "$SANDBOX/cg.log"
( cd "$REPO" && PATH="$STRIPPED" bash "$(link post-commit)" ) 2>/dev/null; rc=$?
chk_eq "⑦ hook exits 0 with no codegraph installed" 0 "$rc"
chk_eq "⑦ nothing is run" 0 "$(seen "$SANDBOX/cg.log" '' "$TRIES")"

echo "== ⑧ the pre-0922 wiring name still dispatches as post-checkout =="
chk_eq "⑧ the old name is a symlink to the one script" 1 \
  "$([ -L "$LEGACY" ] && [ "$(readlink "$LEGACY")" = "codegraph-hooks.sh" ] && echo 1 || echo 0)"
git -C "$REPO" worktree add -q "$SANDBOX/wt3" -b b3
rc="$(run_hook "$SANDBOX/wt3" "$(link post-checkout-codegraph.sh "$LEGACY")" "$SHA" "$SHA" 1)"
chk_eq "⑧ hook exits 0 under the legacy name" 0 "$rc"
chk_eq "⑧ a repo wired to the old filename still gets init" 1 \
  "$(seen "$SANDBOX/cg.log" init "$TRIES")"

summary
