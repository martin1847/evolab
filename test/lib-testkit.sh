#!/usr/bin/env bash
# Shared test kit for the agentctl suite. Sourced by each *.test.sh.
# Provides: hermetic temp sandbox (own AGENT_WATCH_DIR + temp PATH bin with fake
# tmux/sleep), fixture seeding helpers, and PASS/FAIL assertion accounting.
#
# Mock strategy (see test/README why): the scripts under test loop {1..260} with
# sleep 20 and drive tmux. We prepend a temp bin to PATH holding a no-op `sleep`
# (loop runs instantly) and a scripted `tmux` (returns fixtures from env/files).
# NOTHING under test is modified — the fakes live only on the test PATH.
set -u

# Hermetic means hermetic to the CALLER'S env too: a maintainer with the exec-lane
# switch in ~/.zshenv re-routes every TUI-launch test and skips guard check (5) —
# suite red on that box, green everywhere else (caught by independent review 2026-07-11).
# Tests that assert exec routing set the switch INLINE per invocation.
unset AGENT_WATCH_SYNC 2>/dev/null || true
# Same class, new surface (2026-09-10): `AGENTCTL_MODEL_<ENGINE>` is DOCUMENTED as a shell-profile
# export, so the maintainer who follows the README injects a --model into every start this suite
# makes — meta grows a model= line and the argv-forwarding engines grow two argv tokens. Red on
# that box, green in CI, for doing exactly what the docs say. The tests that assert the variable
# set it INLINE per invocation, like the exec-lane switch above. The `_REVIEW` spelling (the
# review seat's own default, 2026-09-11) is documented the same way and leaks the same way.
unset AGENTCTL_MODEL_OMP AGENTCTL_MODEL_CODEX AGENTCTL_MODEL_CLAUDE \
      AGENTCTL_MODEL_OMP_REVIEW AGENTCTL_MODEL_CODEX_REVIEW AGENTCTL_MODEL_CLAUDE_REVIEW 2>/dev/null || true

# Same rule for git: the MACHINE's git config is not the suite's business. This maintainer's
# box sets `core.hooksPath=~/.githooks`, whose post-checkout backgrounds `codegraph init` for
# every freshly created linked worktree — so a fixture's `git worktree add` grows a `.codegraph/`
# ~0.3s later, and cto-guard-bash's "metadata-only prune" fixture (one prunable entry whose dir
# must be GONE) gets that dir RE-CREATED under it and stops being metadata-only: suite red on
# that box, green in CI (independent forensics 2026-09-06, REVIEW_AUDIT_A_codex_r2 §F8, which
# reproduced green under GIT_CONFIG_GLOBAL=/dev/null). Aliases, credential helpers, insteadOf
# rewrites and init.defaultBranch are the same class of leak, just quieter.
# It lives HERE and not per suite because the leak is not suite-shaped: every suite reaches git
# through the scripts under test (the guards run `git rev-parse` / `worktree list --porcelain`
# on the caller's cwd), so the exposed surface is "any suite, any current or future git call" —
# exactly the caller-env blast radius the shared kit already owns for AGENT_WATCH_SYNC above.
# Identity ships with it: with the global file gone a bare `git commit` in a fixture has no
# user.email and dies (a silent fixture degradation — see cto-guard-bash's 2026-08-10 note), so
# the kit supplies one instead of asking every fixture to remember, exactly as
# repo-gov-prepush-template.test.sh already does for itself.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=testkit GIT_AUTHOR_EMAIL=testkit@invalid
export GIT_COMMITTER_NAME=testkit GIT_COMMITTER_EMAIL=testkit@invalid

# Resolve the agentctl dir. test/ lives at the repo root; the scripts under
# test live under skills/cto-orchestration/references/agentctl/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW_DIR="$REPO_ROOT/skills/cto-orchestration/references/agentctl"
AGENTCTL="$AW_DIR/agentctl"

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

# ---- bounded waits -----------------------------------------------------------
# Async lanes have NO per-frame ack: `agentctl steer` returns on DELIVERY (engine stdin),
# provider logs and events sidecars are written by the engine afterwards. An immediate
# snapshot therefore reports a frame that is merely LATE as missing, and under load that
# reads as a real behaviour failure (cold review R1, §5). Every read of an async artifact
# goes through this bounded wait, and the assertion is made on ITS result — so a timeout
# still reds, but only after the frame really had its chance to appear.
await_contains() { # $1 file  $2 exact needle  [$3 tries, 0.1s each (default 100 = 10s)]
  local i=0 tries="${3:-100}"
  while [ "$i" -lt "$tries" ]; do
    if [ -f "$1" ]; then
      case "$(cat "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
    fi
    /bin/sleep 0.1
    i=$((i+1))
  done
  return 1
}

# 1/0 for chk_eq, so the label names WHICH artifact never showed the marker
seen() { # $1 file  $2 needle  [$3 tries]
  await_contains "$1" "$2" "${3:-100}" && echo 1 || echo 0
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
  #   FAKE_TMUX_CAPTURE_FAIL=1  -> capture-pane exits 1
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
    [ "${FAKE_TMUX_NEWSESSION_FAIL:-0}" = "1" ] && exit 42
    [ -n "${FAKE_TMUX_CMD_FILE:-}" ] && printf '%s\n' "${!#}" > "$FAKE_TMUX_CMD_FILE"
    [ -n "${FAKE_TMUX_LAUNCH_LOG:-}" ] && printf '%s\n' "${!#}" >> "$FAKE_TMUX_LAUNCH_LOG"
    if [ -n "${FAKE_TMUX_HOLD_FILE:-}" ]; then
      : > "$FAKE_TMUX_HOLD_FILE.started"
      while [ -e "$FAKE_TMUX_HOLD_FILE" ]; do /bin/sleep 0.02; done
    fi
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
  unset FAKE_TMUX_DISPLAY_FAIL FAKE_TMUX_CAPTURE_FAIL FAKE_PANE_CMD FAKE_PANE_FILE FAKE_TMUX_HASSESSION FAKE_TMUX_NEWSESSION_FAIL
  unset FAKE_TMUX_CMD_FILE FAKE_TMUX_DELIV_FILE
  unset FAKE_TMUX_LAUNCH_LOG FAKE_TMUX_HOLD_FILE
}
