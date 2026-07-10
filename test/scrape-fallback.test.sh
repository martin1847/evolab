#!/usr/bin/env bash
# Exercises every exit path of lib/scrape-fallback.sh via fake tmux capture-pane
# fixtures (busy marker, waiting-menu glyphs, provider-error chrome, frozen screen).
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

MARK='⟦esc⟧'   # default busy marker

run_scrape() { # $1 session
  SC_OUT="$(bash "$SCRAPE" "$1" 2>&1)"; SC_RC=$?
}

echo "== scrape-fallback: exit-code map =="

# exit 0 IDLE/DONE: no marker, alive foreground, no input chrome -> idle>=2.
sandbox_new
export FAKE_PANE_CMD="omp"
pane_fixture "task complete.\nsummary written.\n"
run_scrape idle-sess
chk_eq "exit0 IDLE/DONE rc" 0 "$SC_RC"
chk_contains "exit0 IDLE/DONE marker" "IDLE/DONE" "$SC_OUT"
sandbox_clean

# exit 1 SESSION-GONE: capture-pane fails.
sandbox_new
export FAKE_TMUX_CAPTURE_FAIL=1
export FAKE_PANE_CMD="omp"
run_scrape gone-sess
chk_eq "exit1 SESSION-GONE rc" 1 "$SC_RC"
chk_contains "exit1 SESSION-GONE marker" "SESSION GONE" "$SC_OUT"
sandbox_clean

# exit 2 AGENT-DEAD: foreground matches shell regex (checked before marker).
sandbox_new
export FAKE_PANE_CMD="bash"
pane_fixture "user@host:~$ \n"
run_scrape dead-sess
chk_eq "exit2 AGENT-DEAD rc" 2 "$SC_RC"
chk_contains "exit2 AGENT-DEAD marker" "AGENT DEAD" "$SC_OUT"
sandbox_clean

# exit 3 HANG: busy marker present + screen frozen (static cksum) + no error chrome -> samehash>=8.
sandbox_new
export FAKE_PANE_CMD="omp"
pane_fixture "thinking ${MARK}\nspinner frame (frozen)\n"
run_scrape hang-sess
chk_eq "exit3 HANG rc" 3 "$SC_RC"
chk_contains "exit3 HANG marker" "SUSPECTED HANG" "$SC_OUT"
sandbox_clean

# exit 4 WAITING: no marker, interactive prompt glyph in tail.
sandbox_new
export FAKE_PANE_CMD="omp"
pane_fixture "Choose an option:\n◉ yes\n○ no\n↑/↓ navigate, enter select\n"
run_scrape wait-sess
chk_eq "exit4 WAITING rc" 4 "$SC_RC"
chk_contains "exit4 WAITING marker" "WAITING FOR INPUT" "$SC_OUT"
sandbox_clean

# exit 5 STALLED-EXTERNAL: busy marker present + provider-error chrome -> exterr>=2.
sandbox_new
export FAKE_PANE_CMD="omp"
pane_fixture "working ${MARK}\n> retrying after 429 Too Many Requests\noverloaded_error\n"
run_scrape stall-sess
chk_eq "exit5 STALLED-EXTERNAL rc" 5 "$SC_RC"
chk_contains "exit5 STALLED-EXTERNAL marker" "STALLED-EXTERNAL" "$SC_OUT"
sandbox_clean


# exit 6 IDLE-NO-DELIVERABLE (scrape path): idle agent, declared deliverable never appears.
sandbox_new
export FAKE_PANE_CMD="omp"
pane_fixture "looks finished\n"
export AGENT_WATCH_DELIVERABLE="$SANDBOX/out/*.md" AGENT_WATCH_NODELIV_POLLS=1
run_scrape nodeliv-sc
chk_eq "scrape exit6 rc" 6 "$SC_RC"
chk_contains "scrape exit6 marker" "IDLE-NO-DELIVERABLE" "$SC_OUT"
unset AGENT_WATCH_DELIVERABLE AGENT_WATCH_NODELIV_POLLS
sandbox_clean

# exit 7 WATCH-TIMEOUT: bounded polling exhausted while the live pane remains busy.
sandbox_new
export FAKE_PANE_CMD="omp" AGENT_WATCH_MAX_POLLS=1
pane_fixture "still working ${MARK}\n"
run_scrape timeout-sc
chk_eq "scrape exit7 rc" 7 "$SC_RC"
chk_contains "scrape exit7 marker" "WATCHER TIMEOUT" "$SC_OUT"
unset AGENT_WATCH_MAX_POLLS
sandbox_clean

summary
