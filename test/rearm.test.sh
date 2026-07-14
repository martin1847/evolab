#!/usr/bin/env bash
# rearm.test.sh — watchspec self-heal contract: `watch` writes a spec on arm and
# removes it on every NATURAL exit (EXIT trap); SIGKILL skips traps so the spec
# survives; `rearm` lists re-arm commands for dead-pid specs, cleans stale ones,
# and NEVER launches anything itself.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

REARM="../skills/cto-orchestration/references/agent-watch/rearm"

echo "== rearm / watchspec =="

# natural exit leaves NO spec (EXIT trap fired): DONE run end-to-end.
sandbox_new
seed_events nat-sess '2026-01-01T00:00:00Z WORKING t0\n2026-01-01T00:00:01Z DONE t1\n'
export FAKE_PANE_CMD="omp"; pane_fixture "\$ \n"
bash "$WATCH" nat-sess >/dev/null 2>&1
chk_eq "natural exit removes watchspec" 0 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
sandbox_clean

# SIGKILL mid-flight: spec survives; rearm (session still alive) prints the re-arm cmd —
# INCLUDING per-session env (deliverable gate must survive SIGKILL+rearm, not degrade).
sandbox_new
seed_events kill-sess '2026-01-01T00:00:00Z WORKING t0\n'
export FAKE_PANE_CMD="omp"; pane_fixture "busy busy\n"
# Pin the watcher with a REAL sleep for this case only: with the fake no-op sleep the whole
# 260-poll loop can finish (natural exit → trap removes the spec) before kill -9 lands —
# raced green on macOS, red on faster Linux. The spec must be read while watch is mid-flight.
ln -sf /bin/sleep "$BIN/sleep"
AGENT_WATCH_DELIVERABLE="/tmp/out/*.md" bash "$WATCH" kill-sess >/dev/null 2>&1 & wpid=$!
/bin/sleep 1                      # let it arm; watch itself is parked in its first real sleep
kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
chk_eq "SIGKILL leaves watchspec behind" 1 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
export FAKE_TMUX_HASSESSION=0     # tmux session still exists
out="$(bash "$REARM" 2>&1)"
chk_contains "rearm prints the re-arm command" "watch kill-sess" "$out"
chk_contains "re-arm cmd carries deliverable env (gate survives rearm)" "AGENT_WATCH_DELIVERABLE" "$out"
chk_not_contains "rearm does not claim empty" "nothing to re-arm" "$out"
chk_eq "rearm keeps the spec until re-armed" 1 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
unset FAKE_TMUX_HASSESSION
sandbox_clean

# stale spec (dead pid + tmux session gone) -> cleaned up, not re-armed.
sandbox_new
printf 'session=ghost\npid=999999\ncmd=bash /x/watch ghost\n' > "$WATCH_RUN_DIR/ghost.watchspec"
out="$(bash "$REARM" 2>&1)"       # default fake has-session => session gone
chk_contains "stale spec reported" "stale spec removed" "$out"
chk_eq "stale spec deleted" 0 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
sandbox_clean

# live watcher (pid alive) -> left alone, nothing to re-arm.
sandbox_new
tail -f /dev/null & alive=$!
printf 'session=live\npid=%s\ncmd=bash /x/watch live\n' "$alive" > "$WATCH_RUN_DIR/live.watchspec"
out="$(bash "$REARM" 2>&1)"
chk_contains "alive watcher -> nothing to re-arm" "nothing to re-arm" "$out"
chk_eq "alive spec untouched" 1 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
kill "$alive" 2>/dev/null
sandbox_clean

# gap-detect: LIVE session with NO watcher at all (natural watcher exit + a new round sent,
# or never armed) — specs can't see it; scan events sentinels and suggest a re-arm (field:
# "nothing to re-arm" while a session needed manual watch, LH 2026-07-11).
sandbox_new
seed_events orphan-live '2026-01-01T00:00:00Z WORKING t0\n'
export FAKE_TMUX_HASSESSION=0     # tmux session alive
out="$(bash "$REARM" 2>&1)"
chk_contains "gap-detect flags unwatched live session" "NO watcher" "$out"
chk_contains "gap-detect suggests the watch command" "watch orphan-live" "$out"
chk_not_contains "gap-detect not reported as empty" "nothing to re-arm" "$out"
unset FAKE_TMUX_HASSESSION
sandbox_clean

# Headless gap-detect: an exec sentinel with no watcher process must be reported.
sandbox_new
printf 'engine=codex\n' > "$WATCH_RUN_DIR/headless-missing.exec.meta"
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/pgrep"
export FAKE_TMUX_HASSESSION=0
out="$(bash "$REARM" 2>&1)"
chk_contains "missing headless watcher is reported" "NO watcher" "$out"
chk_contains "missing headless watcher gets re-arm command" "watch headless-missing" "$out"
unset FAKE_TMUX_HASSESSION
sandbox_clean

# A healthy headless watcher must not be reported. The metacharacter-heavy session also proves
# rearm passes an escaped, option-safe regex to pgrep rather than interpolating the name raw.
sandbox_new
printf 'engine=codex\n' > "$WATCH_RUN_DIR/head.less[1].exec.meta"
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-f" ] || exit 1
[ "$2" = "--" ] || exit 1
[ "$3" = 'dispatch-exec[[:space:]]+watch[[:space:]]+head\.less\[1\]$' ] || exit 1
exit 0
EOF
chmod +x "$BIN/pgrep"
export FAKE_TMUX_HASSESSION=0
out="$(bash "$REARM" 2>&1)"
chk_not_contains "healthy headless watcher is not reported" "NO watcher" "$out"
chk_contains "healthy headless watcher leaves nothing to re-arm" "nothing to re-arm" "$out"
unset FAKE_TMUX_HASSESSION
sandbox_clean

# empty dir -> honest no-op.
sandbox_new
chk_contains "empty dir -> nothing to re-arm" "nothing to re-arm" "$(bash "$REARM" 2>&1)"
sandbox_clean

summary
