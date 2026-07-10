#!/usr/bin/env bash
# Shared test kit for the agent-watch suite. Sourced by each *.test.sh.
# Provides: hermetic temp sandbox (own AGENT_WATCH_DIR + temp PATH bin with fake
# tmux/sleep), fixture seeding helpers, and PASS/FAIL assertion accounting.
#
# Mock strategy (see test/README why): the scripts under test loop {1..260} with
# sleep 20 and drive tmux. We prepend a temp bin to PATH holding a no-op `sleep`
# (loop runs instantly) and a scripted `tmux` (returns fixtures from env/files).
# NOTHING under test is modified — the fakes live only on the test PATH.
set -u

# Resolve the agent-watch dir. test/ lives at the repo root; the scripts under
# test live under skills/cto-orchestration/references/agent-watch/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW_DIR="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
WATCH="$AW_DIR/watch"
SCRAPE="$AW_DIR/lib/scrape-fallback.sh"
EMIT="$AW_DIR/emit.sh"
EMIT_STDIN="$AW_DIR/hooks/emit-from-stdin.sh"
DISPATCH="$AW_DIR/dispatch"
TEARDOWN="$AW_DIR/teardown"
OMP_TS="$AW_DIR/hooks/omp-watch.ts"

PASS=0
FAIL=0

# ---- assertion helpers -------------------------------------------------------
# ok <bool-cmd-result-via-string> : pass a label + condition already evaluated.
chk() { # $1 label  $2 cond(0/1 string "ok"/"bad") -- prefer chk_eq / chk_code
  :
}

_record() { # $1 label  $2 ok(1)/notok(0)  [$3 detail]
  if [ "$2" = "1" ]; then
    printf '  ok   %s\n' "$1"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s%s\n' "$1" "${3:+ -- $3}"
    FAIL=$((FAIL+1))
  fi
}

chk_eq() { # $1 label  $2 expected  $3 actual
  if [ "$2" = "$3" ]; then _record "$1" 1
  else _record "$1" 0 "expected[$2] got[$3]"; fi
}

chk_contains() { # $1 label  $2 needle  $3 haystack
  case "$3" in
    *"$2"*) _record "$1" 1 ;;
    *) _record "$1" 0 "needle[$2] not in output" ;;
  esac
}

chk_not_contains() { # $1 label  $2 needle  $3 haystack
  case "$3" in
    *"$2"*) _record "$1" 0 "unexpected needle[$2] present" ;;
    *) _record "$1" 1 ;;
  esac
}

summary() { # exits non-zero if any failed
  echo "-- $PASS passed, $FAIL failed --"
  if [ "$FAIL" -eq 0 ]; then echo "PASS"; return 0; else echo "FAIL"; return 1; fi
}

# ---- hermetic sandbox --------------------------------------------------------
# Creates: $SANDBOX (tmpdir), $WATCH_RUN_DIR (AGENT_WATCH_DIR), $BIN (temp PATH bin).
# Installs fake `tmux` + `sleep`. Caller exports fixture controls before running.
sandbox_new() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXXXX")"
  WATCH_RUN_DIR="$SANDBOX/run"
  BIN="$SANDBOX/bin"
  mkdir -p "$WATCH_RUN_DIR" "$BIN"
  export AGENT_WATCH_DIR="$WATCH_RUN_DIR"

  # fake sleep: no-op so the 260x loop is instant.
  cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/sleep"

  # fake tmux: scripted. Fixture controls via env:
  #   FAKE_TMUX_DISPLAY_FAIL=1  -> display-message exits 1 (SESSION-GONE path)
  #   FAKE_TMUX_CAPTURE_FAIL=1  -> capture-pane exits 1 (scrape SESSION-GONE path)
  #   FAKE_PANE_CMD=<str>       -> pane_current_command output
  #   FAKE_PANE_FILE=<path>     -> file whose contents capture-pane prints
  #   FAKE_TMUX_CMD_FILE=<path> -> new-session's final command string
  #   FAKE_TMUX_DELIV_FILE=<path> -> AGENT_WATCH_DELIVERABLE seen by fake tmux
  # new-session / send-keys / kill-session / has-session(=> no session) = no-op success.
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  display-message)
    [ "${FAKE_TMUX_DISPLAY_FAIL:-0}" = "1" ] && exit 1
    printf '%s\n' "${FAKE_PANE_CMD:-omp}"
    ;;
  capture-pane)
    [ "${FAKE_TMUX_CAPTURE_FAIL:-0}" = "1" ] && exit 1
    if [ -n "${FAKE_PANE_FILE:-}" ] && [ -f "${FAKE_PANE_FILE:-}" ]; then
      cat "$FAKE_PANE_FILE"
    fi
    ;;
  has-session)
    # Default: no such session (rc 1) so `dispatch` proceeds. Override w/ FAKE_TMUX_HASSESSION=0->exists
    if [ "${FAKE_TMUX_HASSESSION:-1}" = "0" ]; then exit 0; else exit 1; fi
    ;;
  new-session)
    [ -n "${FAKE_TMUX_CMD_FILE:-}" ] && printf '%s\n' "${!#}" > "$FAKE_TMUX_CMD_FILE"
    [ -n "${FAKE_TMUX_DELIV_FILE:-}" ] && printf '%s\n' "${AGENT_WATCH_DELIVERABLE:-}" > "$FAKE_TMUX_DELIV_FILE"
    exit 0
    ;;
  send-keys|kill-session|set-option|select-pane)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$BIN/tmux"

  OLD_PATH="$PATH"
  export PATH="$BIN:$PATH"
}

sandbox_clean() {
  export PATH="${OLD_PATH:-$PATH}"
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  unset SANDBOX WATCH_RUN_DIR BIN AGENT_WATCH_DIR
  unset FAKE_TMUX_DISPLAY_FAIL FAKE_TMUX_CAPTURE_FAIL FAKE_PANE_CMD FAKE_PANE_FILE FAKE_TMUX_HASSESSION
  unset FAKE_TMUX_CMD_FILE FAKE_TMUX_DELIV_FILE
}

# seed_events <session> <content...>  -- write the sentinel events file.
seed_events() { # $1 session ; remaining = lines via printf %b
  local sess="$1"; shift
  printf '%b' "$*" > "$WATCH_RUN_DIR/$sess.events"
}

# pane_fixture <content...> -- write a capture-pane fixture file, export FAKE_PANE_FILE.
pane_fixture() {
  FAKE_PANE_FILE="$SANDBOX/pane.txt"
  printf '%b' "$*" > "$FAKE_PANE_FILE"
  export FAKE_PANE_FILE
}
