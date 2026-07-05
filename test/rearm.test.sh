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

# SIGKILL mid-flight: spec survives; rearm (session still alive) prints the re-arm cmd.
sandbox_new
seed_events kill-sess '2026-01-01T00:00:00Z WORKING t0\n'
export FAKE_PANE_CMD="omp"; pane_fixture "busy busy\n"
bash "$WATCH" kill-sess >/dev/null 2>&1 & wpid=$!
/bin/sleep 1                      # real sleep: let it arm (PATH sleep is the fake)
kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
chk_eq "SIGKILL leaves watchspec behind" 1 "$(ls "$WATCH_RUN_DIR"/*.watchspec 2>/dev/null | wc -l | tr -d ' ')"
export FAKE_TMUX_HASSESSION=0     # tmux session still exists
out="$(bash "$REARM" 2>&1)"
chk_contains "rearm prints the re-arm command" "watch kill-sess" "$out"
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

# empty dir -> honest no-op.
sandbox_new
chk_contains "empty dir -> nothing to re-arm" "nothing to re-arm" "$(bash "$REARM" 2>&1)"
sandbox_clean

summary
