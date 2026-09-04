#!/usr/bin/env bash
# agentctl stop / inventory — the LABEL lineage phase (2026-09-04).
#
# The leak class this covers: a child that setsid()s or double-forks out of the pane's process
# group is invisible to the group-scoped `reap_tree` in `agentctl` by construction, so before
# this phase existed it got one stderr ADVISORY from watchctl.py's cmd_stop_survivors and
# nothing else (field 2026-08: one stop left 32 MCP children, ~700MB). The pane assembly point
# exports AGENTCTL_SESSION + AGENTCTL_CWD, every exec'd descendant inherits both, and
# duplexctl.py's `lineage-plan` turns that into a per-pid reap the shell signals.
#
# TWO properties of this file are load-bearing and were each bought with a red finding:
#
#  * SCOPE. The implementation scans every process of the current user, so a fixture wearing a
#    fixed label would be reaped by ANOTHER runner's stop. Every session name and every label
#    here carries $NONCE, and every signal — the tmux double's kill-session included — goes to
#    a pid this runner recorded whose start time still matches. No pattern kill, no pid-tree
#    kill: two copies of this file must run at once without touching each other's processes.
#  * STREAMS. `reaped N lineage process(es)` is a stdout contract; ADVISORY / [unknown] /
#    [skipped …] are stderr contracts. Every run below captures the two separately, so moving a
#    token to the wrong stream reds.
#
# IDs match the goal's scenario matrix so matrix and file are cross-checkable by grep. (u*) are
# function-level checks on the environment parser and the Linux /proc branch — the only way to
# reach those failure modes on a box that has neither /proc nor a breakable env probe.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

echo "== agentctl-lineage =="

sandbox_new
# the grace loop needs REAL time: the sandbox no-op sleep would burn the whole budget in
# microseconds and mislabel every TERM reap as a KILL escalation.
printf '#!/usr/bin/env bash\nexec /bin/sleep "$@"\n' > "$BIN/sleep"; chmod +x "$BIN/sleep"

# ---- identity, not argv -----------------------------------------------------------------
# In a FILE, because the tmux double is a separate process and must reap by the SAME rule this
# runner uses: only a pid recorded here, and only while (pid, start time) still names that
# process. Never an argv marker — macOS `/usr/bin/python3` re-execs through Python.app and
# REPLACES the argv0 handed to execv, so an argv probe calls live fixtures dead.
export FIXID="$SANDBOX/fixid.sh"
cat > "$FIXID" <<'EOF'
lstart_of() { # $1 pid → the start time, normalized the way the implementation normalizes it
  ps -p "${1:-0}" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/ *$//'
}
alive() { # $1 pid → 1 while it is a live non-zombie process
  local st
  st="$(ps -o state= -p "${1:-0}" 2>/dev/null | tr -d ' ')"
  case "${st:-gone}" in ''|gone|Z*) echo 0;; *) echo 1;; esac
}
same_proc() { # $1 pid  $2 recorded start time → 1 only if the pid is STILL that process
  [ "$(alive "$1")" = 1 ] && [ "$(lstart_of "$1")" = "$2" ] && echo 1 || echo 0
}
reap_fixture() { # $1 pid  $2 recorded start time — can only ever hit OUR OWN recorded fixture
  [ "$(same_proc "${1:-0}" "${2:-}")" = 1 ] || return 0
  kill -KILL "$1" 2>/dev/null
}
EOF
. "$FIXID"

# One tmux double for the whole file: pane-running (so `start` can really assemble a pane),
# plus the list-sessions face the ownership predicate reads.
#   FAKE_TMUX_SESSIONS="a b"  -> list-sessions output      FAKE_TMUX_LS_RC=1 -> "no server running"
#   FAKE_TMUX_LS_RC=2         -> a BROKEN probe (rc 2)     FAKE_TMUX_DISPLAY_FAIL=1 -> no live pane
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
. "$FIXID"      # pane pids are RECORDED with their start time and only ever reaped by identity
sub="$1"; shift || true
name=""; cwd=""; cmd=""
while [ "$#" -gt 0 ]; do case "$1" in
  -s|-t) name="$2"; shift 2;;
  -c) cwd="$2"; shift 2;;
  -F) shift 2;;
  -d|-p) shift;;
  *) cmd="$1"; shift;;
esac; done
name="${name#=}"; name="${name%:}"
case "$sub" in
  list-sessions)
    case "${FAKE_TMUX_LS_RC:-0}" in
      0) [ -n "${FAKE_TMUX_SESSIONS:-}" ] && printf '%s\n' ${FAKE_TMUX_SESSIONS}; exit 0 ;;
      1) echo "no server running on /tmp/tmux-0/default" >&2; exit 1 ;;
      *) echo "tmux: connection refused" >&2; exit "$FAKE_TMUX_LS_RC" ;;
    esac ;;
  new-session)
    ( cd "${cwd:-/}" && exec bash -c "$cmd" ) >/dev/null 2>&1 &
    printf '%s %s\n' "$!" "$(lstart_of "$!")" > "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  has-session)
    read -r pid pls < "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null || exit 1
    [ "$(same_proc "${pid:-0}" "${pls:-}")" = 1 ] ;;
  kill-session)
    read -r pid pls < "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null
    reap_fixture "${pid:-0}" "${pls:-}"
    rm -f "$FAKE_TMUX_STATE/$name.pid"; exit 0 ;;
  display-message)
    [ "${FAKE_TMUX_DISPLAY_FAIL:-0}" = "1" ] && exit 1
    printf '%s\n' "${FAKE_PANE_CMD:-}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/tmux"
export FAKE_TMUX_STATE="$SANDBOX/tmux-state"; mkdir -p "$FAKE_TMUX_STATE"
export FAKE_TMUX_DISPLAY_FAIL=1        # default: no live pane, so the LABEL phase is isolated

# ---- two-stream capture -----------------------------------------------------------------
ENVV=()
run_stop() { # $1 session — sets RC / OUT (stdout) / ERR (stderr); extra env via ENVV
  local o="$SANDBOX/cap.out" e="$SANDBOX/cap.err"
  env "${ENVV[@]+"${ENVV[@]}"}" bash "$AGENTCTL" stop "$1" > "$o" 2> "$e"; RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"; ENVV=()
}
run_inv() { # sets RC / OUT / ERR for `inventory --dry-run`; extra env via ENVV
  local o="$SANDBOX/cap.out" e="$SANDBOX/cap.err"
  env "${ENVV[@]+"${ENVV[@]}"}" bash "$AGENTCTL" inventory --dry-run > "$o" 2> "$e"; RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"; ENVV=()
}

# Reads a live pid's ENVIRONMENT through the same source the implementation reads, so a
# forgery pre-probe asserts what the code will see rather than what a ps line looks like.
cat > "$SANDBOX/envprobe.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import watchctl as w
pid = sys.argv[2]
if os.path.isdir("/proc/self"):
    with open(f"/proc/{pid}/environ", "rb") as fh:
        env = w._env_members([p for p in fh.read().split(b"\0") if p])
else:
    blob = w._sysctl_procargs2(int(pid))
    env = w.parse_procargs2(blob) if blob is not None else None
env = env if env is not None else {}
for key in sys.argv[3:]:
    print(f"{key}={env[key]}" if key in env else f"{key}=<absent>")
PY

mkmeta() { # $1 session  $2 cwd ("-" = omit the cwd line entirely)
  { printf 'engine=omp\n'
    [ "$2" = "-" ] || printf 'cwd=%s\n' "$2"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
}

# A labelled escapee: setsid OUT of the caller's group, double-forked so PID 1 really adopts
# it, self-expiring, and its ENVIRONMENT carries the pane labels. Echoes "<pid> <lstart>".
#   $3 mode: plain | ignore-term | no-cwd (session label only — the undecidable-ownership格)
spawn_labelled() { # $1 session  $2 cwd-label  $3 mode  $4 pidfile
  AGENTCTL_SESSION="$1" AGENTCTL_CWD="$2" python3 - "$3" "$4" <<'EOF'
import os, sys
mode, pidfile = sys.argv[1:3]
body = "import time; time.sleep(90)"
if mode == "ignore-term":
    body = ("import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "time.sleep(90)")
if mode == "no-cwd":
    os.environ.pop("AGENTCTL_CWD", None)
pid = os.fork()
if pid == 0:
    os.setsid()
    if os.fork() == 0:
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        with open(pidfile, "w") as fh:
            fh.write(str(os.getpid()))
        os.execv(sys.executable, [sys.executable, "-c", body])
    os._exit(0)
os.waitpid(pid, 0)
EOF
  local i=0 p
  while [ ! -s "$4" ] && [ "$i" -lt 60 ]; do /bin/sleep 0.1; i=$((i+1)); done
  p="$(cat "$4" 2>/dev/null)"
  printf '%s %s\n' "$p" "$(lstart_of "$p")"
}

# The FORGERIES. Neither carries a label in its ENVIRONMENT; both put the literal text where a
# text-matching implementation would find it:
#   argv   — the pane shell's own argv is literally `export AGENTCTL_SESSION=x AGENTCTL_CWD=y`
#   value  — an unrelated variable's VALUE contains ` AGENTCTL_SESSION=<s> AGENTCTL_CWD=/x`
# The second is review B1's decoy: with `ps -E` space-joining argv and env into one line there
# is no way to tell "next member" from "a ` NAME=` inside the previous member's value", and it
# walked into a signal plan. Both are refused structurally now, by counting past argc in the
# KERN_PROCARGS2 buffer / splitting /proc/<pid>/environ on NUL.
spawn_forgery() { # $1 kind(argv|value)  $2 session  $3 cwd-label  $4 pidfile
  env -u AGENTCTL_SESSION -u AGENTCTL_CWD \
      FORGE_KIND="$1" FORGE_SESSION="$2" FORGE_CWD="$3" \
      python3 - "$4" <<'EOF'
import os, sys
pidfile = sys.argv[1]
kind = os.environ.pop("FORGE_KIND")
sess = os.environ.pop("FORGE_SESSION")
cwd = os.environ.pop("FORGE_CWD")
extra = []
if kind == "argv":
    extra = [f"AGENTCTL_SESSION={sess}", f"AGENTCTL_CWD={cwd}"]
else:
    os.environ["DECOY"] = f"prefix AGENTCTL_SESSION={sess} AGENTCTL_CWD={cwd}"
pid = os.fork()
if pid == 0:
    os.setsid()
    if os.fork() == 0:
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        with open(pidfile, "w") as fh:
            fh.write(str(os.getpid()))
        os.execv(sys.executable,
                 [sys.executable, "-c", "import time; time.sleep(90)", *extra])
    os._exit(0)
os.waitpid(pid, 0)
EOF
  local i=0 p
  while [ ! -s "$4" ] && [ "$i" -lt 60 ]; do /bin/sleep 0.1; i=$((i+1)); done
  p="$(cat "$4" 2>/dev/null)"
  printf '%s %s\n' "$p" "$(lstart_of "$p")"
}

# A live pane-like group with an UNLABELLED escapee — the pre-existing advisory's own fixture.
spawn_escape_tree() { # $1 pidfile → "<leader/pgid> <escapee pid> <escapee lstart>"
  local leader p
  leader="$(env -u AGENTCTL_SESSION -u AGENTCTL_CWD python3 - "$1" <<'EOF'
import os, subprocess, sys, time
pidfile = sys.argv[1]
pid = os.fork()
if pid == 0:
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    subprocess.Popen(["/bin/sleep", "90"])           # IN the group: the reap owns this one
    if os.fork() == 0:
        os.setsid()                                  # OUT of the group: the reap cannot see it
        with open(pidfile, "w") as fh:
            fh.write(str(os.getpid()))
        os.execv("/bin/sleep", ["/bin/sleep", "90"])
    time.sleep(90)
print(pid)
EOF
)"
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 60 ]; do /bin/sleep 0.1; i=$((i+1)); done
  p="$(cat "$1" 2>/dev/null)"
  printf '%s %s %s\n' "$leader" "$p" "$(lstart_of "$p")"
}

# Every label this runner creates carries the nonce, so a concurrent runner's scan cannot
# claim it and this runner's stop cannot claim theirs.
NONCE="n$$x$RANDOM"
S_A="lin${NONCE}a"; S_B="lin${NONCE}b"; S_C="lin${NONCE}c"; S_D="lin${NONCE}d"
S_E="lin${NONCE}e"; S_E2="lin${NONCE}e2"; S_F="lin${NONCE}f"; S_G="lin${NONCE}g"
S_G2="lin${NONCE}g2"; S_H="lin${NONCE}h"; S_H0="lin${NONCE}h0"; S_H4="lin${NONCE}h4"
S_H5="lin${NONCE}h5"; S_H6="lin${NONCE}h6"; S_I="lin${NONCE}i"; S_I0="lin${NONCE}i0"
S_I1="lin${NONCE}i1"; S_J="lin${NONCE}j"; S_KD="lin${NONCE}kd"; S_KL="lin${NONCE}kl"
S_L="lin${NONCE}l"
S_P="lin${NONCE}peer"
CWD_A="$SANDBOX/wt-a"; CWD_B="$SANDBOX/wt-b"; mkdir -p "$CWD_A" "$CWD_B"

# ═══ (u) function-level: the environment parser and the Linux /proc branch ═══════════════
# The env source is not breakable from PATH any more (sysctl / /proc, not a `ps` invocation),
# so these branches have no black-box seam — and review M3 was exactly that they had no
# unit-level evidence either. These are WHITE-BOX by instruction (fix round R1/R6 asked for
# unit-level assertions on the parser and the /proc branch); there is no CLI seam for them,
# because giving one would mean a new public verb. They use a plain `import` after a sys.path
# insert, not the dynamically-loading recipe loc-budget.test.sh §6 bans.
cat > "$SANDBOX/unit.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import watchctl as w

out = []
def check(name, expected, actual):
    out.append(f"{name}\t{expected}\t{actual}")

def buf(argc, execpath, argv, env, pad=1):
    blob = argc.to_bytes(4, sys.byteorder) + execpath + b"\0" * pad
    for a in argv:
        blob += a + b"\0"
    for e in env:
        blob += e + b"\0"
    return blob

# u1: a VALUE containing spaces AND '=' survives intact — the exact case `ps -E` truncated
env = w.parse_procargs2(buf(2, b"/x/exe", [b"argv0", b"argv1"],
                           [b"AGENTCTL_CWD=/a b FAKE=2", b"AGENTCTL_SESSION=s1"]))
check("u1-cwd-with-space-and-equals", "/a b FAKE=2", (env or {}).get("AGENTCTL_CWD"))
check("u1-session", "s1", (env or {}).get("AGENTCTL_SESSION"))

# u2: an EMPTY environment segment is an answer (unlabelled), never uncertainty — this is the
# SIP platform-binary case (`/bin/sleep`, measured argc=2 with zero env members)
check("u2-empty-env-is-empty-dict", "{}", str(w.parse_procargs2(buf(2, b"/bin/sleep", [b"a", b"b"], []))))

# u3: a buffer whose argv is truncated cannot locate the env segment → None, not a guess
check("u3-truncated-argv", "None", str(w.parse_procargs2(buf(9, b"/x/exe", [b"a"], [b"K=v"]))))
check("u3-too-short", "None", str(w.parse_procargs2(b"\x01\x02")))

# u4: a LABEL whose value is not valid UTF-8 makes the whole environment unreadable
check("u4-bad-label-bytes", "None",
      str(w.parse_procargs2(buf(1, b"/x/exe", [b"a"], [b"AGENTCTL_CWD=\xff\xfe"]))))

# u5: a bad OTHER member is skipped; the labels still read
env = w.parse_procargs2(buf(1, b"/x/exe", [b"a"], [b"JUNK=\xff", b"AGENTCTL_SESSION=s5"]))
check("u5-other-bad-member-skipped", "s5", (env or {}).get("AGENTCTL_SESSION"))

# u6: review B1's decoy — the literal text inside another member's VALUE is not a member
env = w.parse_procargs2(buf(1, b"/x/exe", [b"a"],
                            [b"DECOY=prefix AGENTCTL_SESSION=s6 AGENTCTL_CWD=/tmp/x"]))
check("u6-decoy-value-is-not-a-member", "None", str((env or {}).get("AGENTCTL_SESSION")))
check("u6-decoy-value-kept-whole", "prefix AGENTCTL_SESSION=s6 AGENTCTL_CWD=/tmp/x",
      (env or {}).get("DECOY"))

# ---- the Linux /proc branch, driven through its injected open/stat -----------------------
ME = os.getuid()
class Stat:
    def __init__(self, uid): self.st_uid = uid
class Blob:
    def __init__(self, data): self.data = data
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self): return self.data

rows = [{"pid": 11, "state": "S"}]
mine = lambda p: Stat(ME)

# u7: same uid, environ unreadable (EACCES) → blind, NEVER a silently dropped candidate
envs, blind = w._env_by_pid_proc(rows, opener=lambda p: (_ for _ in ()).throw(PermissionError(13, "denied")), stater=mine)
check("u7-eacces-is-blind", "([], [11])", f"({sorted(envs)}, {blind})")

# u8: stat itself failing for a pid we cannot classify → blind
envs, blind = w._env_by_pid_proc(rows, opener=lambda p: Blob(b""),
                                 stater=lambda p: (_ for _ in ()).throw(PermissionError(13, "denied")))
check("u8-stat-failure-is-blind", "([], [11])", f"({sorted(envs)}, {blind})")

# u9: the process merely EXITED (ENOENT) → gone, not a gap
envs, blind = w._env_by_pid_proc(rows, opener=lambda p: (_ for _ in ()).throw(FileNotFoundError(2, "gone")), stater=mine)
check("u9-enoent-is-gone", "([], [])", f"({sorted(envs)}, {blind})")

# u10: another uid → decidably not ours, skipped without a gap
envs, blind = w._env_by_pid_proc(rows, opener=lambda p: Blob(b"AGENTCTL_SESSION=x\0"),
                                 stater=lambda p: Stat(ME + 1))
check("u10-foreign-uid-skipped", "([], [])", f"({sorted(envs)}, {blind})")

# u11: the happy path really parses NUL-delimited members, values with spaces included
envs, blind = w._env_by_pid_proc(
    rows, opener=lambda p: Blob(b"AGENTCTL_SESSION=s11\0AGENTCTL_CWD=/a b\0X=1\0"), stater=mine)
check("u11-nul-parse", "s11|/a b", f"{envs[11]['AGENTCTL_SESSION']}|{envs[11]['AGENTCTL_CWD']}")

# u12: a zombie has no environ to read and is not a gap
envs, blind = w._env_by_pid_proc([{"pid": 12, "state": "Z"}],
                                 opener=lambda p: Blob(b""), stater=mine)
check("u12-zombie-skipped", "([], [])", f"({sorted(envs)}, {blind})")

open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
python3 "$SANDBOX/unit.py" "$AW_DIR" "$SANDBOX/unit.txt"
while IFS=$'\t' read -r uname uexp uact; do
  [ -n "$uname" ] || continue
  chk_eq "(u) $uname" "$uexp" "$uact"
done < "$SANDBOX/unit.txt"
# and the deletion is pinned: the ambiguous `ps -E` reader is GONE, not merely unused
chk_eq "(u) the ps -E space-joined env reader is deleted, not kept beside the new one" "" \
  "$(grep -nE '_split_env|_ENV_NAME_RE|axEwwo' "$AW_DIR/watchctl.py" || true)"
chk_contains "(u) the environment source is the NUL-delimited one" "KERN_PROCARGS2" \
  "$(cat "$AW_DIR/watchctl.py")"

# ═══ (a)-(l) end to end ═══════════════════════════════════════════════════════════════════

# --- (a) a labelled escapee outside every group stop owns is REAPED -------------------------
read -r esc esc_ls <<EOF
$(spawn_labelled "$S_A" "$CWD_A" plain "$SANDBOX/a.pid")
EOF
chk_eq "(a) pre-probe: the fixture is alive under its recorded identity" 1 "$(same_proc "$esc" "$esc_ls")"
chk_eq "(a) pre-probe: it is genuinely OUTSIDE this shell's process group" 1 \
  "$([ "$(ps -o pgid= -p "$esc" 2>/dev/null | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] \
     && echo 1 || echo 0)"
mkmeta "$S_A" "$CWD_A"
run_stop "$S_A"
chk_eq  "(a) stop rc=0" 0 "$RC"
chk_contains "(a) the count line is on STDOUT" "reaped 1 lineage process(es)" "$OUT"
chk_not_contains "(a) …and not on stderr" "reaped 1 lineage" "$ERR"
chk_eq  "(a) the labelled escapee is GONE" 0 "$(alive "$esc")"
reap_fixture "$esc" "$esc_ls"

# --- (b) another seat's label is not this stop's business ------------------------------------
read -r esc_b esc_b_ls <<EOF
$(spawn_labelled "lin${NONCE}other" "$CWD_A" plain "$SANDBOX/b.pid")
EOF
mkmeta "$S_B" "$CWD_A"
run_stop "$S_B"
chk_eq  "(b) stop rc=0" 0 "$RC"
chk_contains "(b) nothing of ours was labelled, and stdout says so" \
             "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(b) the other seat's process SURVIVED, same identity" 1 "$(same_proc "$esc_b" "$esc_b_ls")"
chk_not_contains "(b) and it was never even named" "pid=$esc_b" "$ERR"
reap_fixture "$esc_b" "$esc_b_ls"

# --- (c) an UNLABELLED escapee: the pre-existing advisory, byte-for-byte unchanged -----------
read -r pg esc_c esc_c_ls <<EOF
$(spawn_escape_tree "$SANDBOX/c.pid")
EOF
/bin/sleep 0.5
chk_eq "(c) pre-probe: the escapee left the pane's group" 1 \
  "$([ -n "$esc_c" ] && [ "$(ps -o pgid= -p "$esc_c" 2>/dev/null | tr -d ' ')" != "$pg" ] \
     && echo 1 || echo 0)"
{ printf 'engine=omp\ncwd=%s\npane_pid=%s\n' "$CWD_A" "$pg"; } > "$WATCH_RUN_DIR/$S_C.duplex.meta"
run_stop "$S_C"
chk_eq  "(c) stop rc=0" 0 "$RC"
chk_contains "(c) the group stop owns was still reaped (stdout)" "reaped process group $pg" "$OUT"
chk_contains "(c) the unlabelled escapee still gets the ADVISORY (stderr)" \
             "1 descendant(s) escaped" "$ERR"
chk_contains "(c) …and the advisory still says NOT signalled" "NOT signalled" "$ERR"
chk_contains "(c) the label phase claims nothing" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(c) the unlabelled escapee SURVIVED" 1 "$(same_proc "$esc_c" "$esc_c_ls")"
reap_fixture "$esc_c" "$esc_c_ls"

# --- (d) this stop's OWN ancestry wears the label and is never signalled ----------------------
# Real shape: a seat may `unset AGENTCTL_SESSION` to get past the self-refusal (README §Launch
# calls that an accepted boundary) and its parent keeps the label. The KNOWN POSITIVE beside it
# is what makes this non-vacuous: a SIBLING wearing the identical label and cwd is reaped by the
# very same stop, so "nothing happened to the ancestor" cannot mean "the phase did nothing".
read -r esc_d esc_d_ls <<EOF
$(spawn_labelled "$S_D" "$CWD_A" plain "$SANDBOX/d.pid")
EOF
mkmeta "$S_D" "$CWD_A"
AGENTCTL_SESSION="$S_D" AGENTCTL_CWD="$CWD_A" python3 - "$AGENTCTL" "$S_D" "$SANDBOX/d" <<'EOF'
import os, subprocess, sys
ctl, sess, base = sys.argv[1:4]
# the pid is recorded BEFORE the stop and the survival marker AFTER it: a process that was
# signalled never writes the second file, so the marker IS the liveness evidence — no argv
# marker, and no race against this helper's own exit
open(base + ".pid", "w").write(f"{os.getpid()}\n")
env = dict(os.environ)
env.pop("AGENTCTL_SESSION", None)          # the documented self-refusal bypass
env.pop("AGENTCTL_CWD", None)
done = subprocess.run(["bash", ctl, "stop", sess], capture_output=True, text=True, env=env)
open(base + ".out", "w").write(done.stdout)
open(base + ".err", "w").write(done.stderr)
open(base + ".alive", "w").write(f"{os.getpid()}\n")
EOF
anc="$(tr -d ' \n' < "$SANDBOX/d.pid")"
OUT="$(cat "$SANDBOX/d.out")"; ERR="$(cat "$SANDBOX/d.err")"
chk_eq  "(d) the labelled ancestor outlived its own stop and said so" "$anc" \
        "$(tr -d ' \n' < "$SANDBOX/d.alive" 2>/dev/null)"
chk_not_contains "(d) the ancestry was never a candidate, not even a skipped one" \
                 "pid=$anc" "$ERR"
chk_contains "(d) known positive: the identically labelled SIBLING was reaped" \
             "reaped 1 lineage process(es)" "$OUT"
chk_eq  "(d) …so the phase really ran" 0 "$(alive "$esc_d")"
reap_fixture "$esc_d" "$esc_d_ls"

# --- (e) argv is NOT the environment ---------------------------------------------------------
read -r esc_e esc_e_ls <<EOF
$(spawn_forgery argv "$S_E" "$CWD_A" "$SANDBOX/e.pid")
EOF
argv_e="$(ps -o args= -p "${esc_e:-0}" 2>/dev/null)"
both=0
case "$argv_e" in *"AGENTCTL_SESSION=$S_E"*"AGENTCTL_CWD=$CWD_A"*) both=1;; esac
chk_eq "(e) pre-probe: the fixture's ARGV really carries both literal labels" 1 "$both"
env_probe="$(python3 "$SANDBOX/envprobe.py" "$AW_DIR" "$esc_e" AGENTCTL_SESSION AGENTCTL_CWD)"
chk_contains "(e) pre-probe: its ENVIRONMENT has no session member" "AGENTCTL_SESSION=<absent>" \
             "$env_probe"
chk_contains "(e) pre-probe: …and no cwd member either" "AGENTCTL_CWD=<absent>" "$env_probe"
mkmeta "$S_E" "$CWD_A"
run_stop "$S_E"
chk_eq  "(e) stop rc=0" 0 "$RC"
chk_contains "(e) a forged argv label buys nothing" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(e) the forger SURVIVED" 1 "$(same_proc "$esc_e" "$esc_e_ls")"
reap_fixture "$esc_e" "$esc_e_ls"

# --- (e2) review B1's decoy: the literal text inside another VARIABLE'S VALUE ----------------
read -r esc_e2 esc_e2_ls <<EOF
$(spawn_forgery value "$S_E2" "$CWD_A" "$SANDBOX/e2.pid")
EOF
env_probe="$(python3 "$SANDBOX/envprobe.py" "$AW_DIR" "$esc_e2" DECOY AGENTCTL_SESSION)"
chk_contains "(e2) pre-probe: the decoy VALUE really is one whole environment member" \
             "DECOY=prefix AGENTCTL_SESSION=$S_E2 AGENTCTL_CWD=$CWD_A" "$env_probe"
chk_contains "(e2) pre-probe: and there is NO session member" "AGENTCTL_SESSION=<absent>" \
             "$env_probe"
mkmeta "$S_E2" "$CWD_A"
run_stop "$S_E2"
chk_eq  "(e2) stop rc=0" 0 "$RC"
chk_contains "(e2) a decoy inside a VALUE is not a member" "reaped 0 lineage process(es)" "$OUT"
chk_not_contains "(e2) the decoy was never planned" "pid=$esc_e2" "$ERR"
chk_eq  "(e2) the decoy SURVIVED" 1 "$(same_proc "$esc_e2" "$esc_e2_ls")"
reap_fixture "$esc_e2" "$esc_e2_ls"

# --- (f) a probe that cannot answer says [unknown], reaps nothing, leaves rc alone -----------
read -r esc_f esc_f_ls <<EOF
$(spawn_labelled "$S_F" "$CWD_A" plain "$SANDBOX/f.pid")
EOF
mkmeta "$S_F" "$CWD_A"
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
# break ONLY the lineage snapshot form; reap_tree's own `ps -p/-o` reads stay real
[ "$1" = "-axwwo" ] && exit 1
exec /bin/ps "$@"
EOF
chmod +x "$BIN/ps"
run_stop "$S_F"
stop_rc="$RC"; stop_out="$OUT"; stop_err="$ERR"
ENVV=(AGENT_WATCH_DIR="$WATCH_RUN_DIR"); run_inv
rm -f "$BIN/ps"
chk_eq  "(f) a broken probe leaves stop's rc alone" 0 "$stop_rc"
chk_contains "(f) stop announces the gap on STDERR" "lineage probe [unknown]" "$stop_err"
chk_contains "(f) …and says nothing was signalled" "NOT enumerable and NOTHING was signalled" "$stop_err"
chk_contains "(f) the count line still prints on stdout, at zero" \
             "reaped 0 lineage process(es)" "$stop_out"
chk_not_contains "(f) the [unknown] token never leaks to stdout" "[unknown]" "$stop_out"
chk_eq  "(f) the labelled process SURVIVED a probe failure" 1 "$(same_proc "$esc_f" "$esc_f_ls")"
chk_eq  "(f) inventory exits 0 on a broken probe" 0 "$RC"
chk_contains "(f) inventory's lineage block is NOT a clean bill" "[unknown] lineage census:" "$OUT"
chk_not_contains "(f) …and never dresses the failure up as empty" "(none orphaned)" "$OUT"
# a BROKEN INSTRUMENT and an OPAQUE PROCESS are different facts and must not be merged: this
# cell is block-level (`lineage probe [unknown]`, fail-closed, planner rc 3 → the caller reads
# "recognized something"), the (m) cell below is a per-pid readability gap that carries no
# answer at all and must not move that rc. The pairing is what keeps ③ of the mutation list
# (a failed probe rendered as "nothing found") red.
chk_not_contains "(f) a broken instrument is never worded as the opaque-process count" \
                 "unreadable environment" "$stop_err"
chk_not_contains "(f) …and the census keeps the two apart too" "unreadable environment" "$OUT"
reap_fixture "$esc_f" "$esc_f_ls"

# --- (g) identity is re-read BEFORE TERM: a changed start time is a stranger ------------------
read -r esc_g esc_g_ls <<EOF
$(spawn_labelled "$S_G" "$CWD_A" plain "$SANDBOX/g.pid")
EOF
mkmeta "$S_G" "$CWD_A"
cat > "$BIN/ps" <<EOF
#!/usr/bin/env bash
# the PLAN still sees the truth; every pre-signal re-read sees a recycled pid
if [ "\$1" = "-p" ] && [ "\$2" = "$esc_g" ] && [ "\$3" = "-o" ] && [ "\$4" = "lstart=" ]; then
  echo "Thu Jan  1 00:00:00 1970"; exit 0
fi
exec /bin/ps "\$@"
EOF
chmod +x "$BIN/ps"
run_stop "$S_G"
rm -f "$BIN/ps"
chk_eq  "(g) stop rc=0" 0 "$RC"
chk_contains "(g) the pid is skipped by name, on stderr" \
             "[skipped pid=$esc_g identity changed]" "$ERR"
chk_contains "(g) …and the skip names the TERM stage" "since the plan was sampled" "$ERR"
chk_contains "(g) and it is not counted as reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(g) the process SURVIVED — no signal reached it" 1 "$(same_proc "$esc_g" "$esc_g_ls")"
reap_fixture "$esc_g" "$esc_g_ls"

# --- (g2) identity is re-read AGAIN before KILL --------------------------------------------
# The pid was itself at TERM time and became a stranger while the grace window ran; the second
# re-verify is the only thing between that and a KILL sent to whoever now owns the number.
# Deleting it leaves (g) green (review M4) — this is the case that reds.
read -r esc_g2 esc_g2_ls <<EOF
$(spawn_labelled "$S_G2" "$CWD_A" ignore-term "$SANDBOX/g2.pid")
EOF
mkmeta "$S_G2" "$CWD_A"
cat > "$BIN/ps" <<EOF
#!/usr/bin/env bash
# call 1 for THIS pid tells the truth (so TERM is sent); every later call reports a stranger
if [ "\$1" = "-p" ] && [ "\$2" = "$esc_g2" ] && [ "\$3" = "-o" ] && [ "\$4" = "lstart=" ]; then
  n=0; [ -f "$SANDBOX/g2.ticks" ] && n="\$(cat "$SANDBOX/g2.ticks")"
  echo \$((n + 1)) > "$SANDBOX/g2.ticks"
  if [ "\$n" = 0 ]; then exec /bin/ps "\$@"; fi
  echo "Thu Jan  1 00:00:00 1970"; exit 0
fi
exec /bin/ps "\$@"
EOF
chmod +x "$BIN/ps"
ENVV=(AGENTCTL_REAP_GRACE=1); run_stop "$S_G2"
ticks="$(cat "$SANDBOX/g2.ticks" 2>/dev/null)"
rm -f "$BIN/ps" "$SANDBOX/g2.ticks"
chk_eq  "(g2) stop rc=0" 0 "$RC"
chk_eq  "(g2) known positive: the identity really was read twice for this pid" 1 \
        "$([ "${ticks:-0}" -ge 2 ] && echo 1 || echo 0)"
chk_contains "(g2) the KILL is refused by name, on stderr" \
             "[skipped pid=$esc_g2 identity changed] — not KILLed" "$ERR"
chk_contains "(g2) and it is not counted as reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(g2) the TERM-proof process SURVIVED, unKILLed" 1 "$(same_proc "$esc_g2" "$esc_g2_ls")"
reap_fixture "$esc_g2" "$esc_g2_ls"

# --- (h) a cwd another LIVE session works in = somebody's tool, advisory only -----------------
read -r esc_h esc_h_ls <<EOF
$(spawn_labelled "$S_H" "$CWD_A" plain "$SANDBOX/h.pid")
EOF
mkmeta "$S_H" "$CWD_A"; mkmeta "$S_P" "$CWD_A"
ENVV=(FAKE_TMUX_SESSIONS="$S_P"); run_stop "$S_H"
chk_eq  "(h) stop rc=0" 0 "$RC"
chk_contains "(h) the shared tool is refused and the sharer NAMED, on stderr" \
             "'$S_P', which is LIVE" "$ERR"
chk_contains "(h) …with the shared directory spelled out" "$CWD_A is also the working" "$ERR"
chk_contains "(h) nothing was reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(h) the shared tool SURVIVED" 1 "$(same_proc "$esc_h" "$esc_h_ls")"

# (h2) the peer is live but its lane state cannot say WHERE it works → undecidable, not clean
mkmeta "$S_H" "$CWD_A"; mkmeta "$S_P" "-"
ENVV=(FAKE_TMUX_SESSIONS="$S_P"); run_stop "$S_H"
chk_eq  "(h2) stop rc=0" 0 "$RC"
chk_contains "(h2) an unreadable peer cwd is [unknown], never 'no sharer'" \
             "has no readable cwd in its lane state" "$ERR"
chk_contains "(h2) …and the pid is named as NOT signalled" "pid=$esc_h" "$ERR"
chk_eq  "(h2) the candidate SURVIVED" 1 "$(same_proc "$esc_h" "$esc_h_ls")"

# (h3) the tmux probe itself is broken → undecidable, not "zero live sessions"
mkmeta "$S_H" "$CWD_A"; mkmeta "$S_P" "$CWD_A"
ENVV=(FAKE_TMUX_LS_RC=2); run_stop "$S_H"
chk_eq  "(h3) stop rc=0" 0 "$RC"
chk_contains "(h3) a broken tmux probe is [unknown]" \
             "the other live sessions could not be enumerated" "$ERR"
chk_contains "(h3) …naming the rc it got" "tmux list-sessions rc=2" "$ERR"
chk_eq  "(h3) the candidate SURVIVED" 1 "$(same_proc "$esc_h" "$esc_h_ls")"
reap_fixture "$esc_h" "$esc_h_ls"

# (h4) the question is asked of the CANDIDATE's cwd, never the stopping session's. Two halves:
# same fixture shape, same live peer, the ONLY difference is which directory that peer works in.
read -r esc_h4 esc_h4_ls <<EOF
$(spawn_labelled "$S_H4" "$CWD_B" plain "$SANDBOX/h4.pid")
EOF
mkmeta "$S_H4" "$CWD_A"          # the SEAT works in A; the escapee's own label says B
mkmeta "$S_P" "$CWD_B"           # the live peer works in B — the candidate's directory
ENVV=(FAKE_TMUX_SESSIONS="$S_P"); run_stop "$S_H4"
chk_eq  "(h4) stop rc=0" 0 "$RC"
chk_contains "(h4) a peer sharing the CANDIDATE's cwd blocks the reap" \
             "$CWD_B is also the working" "$ERR"
chk_eq  "(h4) …so the cross-cwd tool SURVIVED" 1 "$(same_proc "$esc_h4" "$esc_h4_ls")"
mkmeta "$S_H4" "$CWD_A"
mkmeta "$S_P" "$CWD_A"           # now the live peer works where the SEAT did, not the candidate
ENVV=(FAKE_TMUX_SESSIONS="$S_P"); run_stop "$S_H4"
chk_eq  "(h4) stop rc=0 (control half)" 0 "$RC"
chk_contains "(h4) a peer sharing only the SEAT's cwd blocks nothing" \
             "reaped 1 lineage process(es)" "$OUT"
chk_eq  "(h4) …and the escapee is gone" 0 "$(alive "$esc_h4")"
reap_fixture "$esc_h4" "$esc_h4_ls"
rm -f "$WATCH_RUN_DIR/$S_P.duplex.meta"

# --- (h0) the CANDIDATE has no cwd label → ownership undecidable, no signal -------------------
read -r esc_h0 esc_h0_ls <<EOF
$(spawn_labelled "$S_H0" "$CWD_A" no-cwd "$SANDBOX/h0.pid")
EOF
mkmeta "$S_H0" "$CWD_A"
run_stop "$S_H0"
chk_eq  "(h0) stop rc=0" 0 "$RC"
chk_contains "(h0) the missing cwd label is named as undecidable" \
             "carries this session's label but no AGENTCTL_CWD" "$ERR"
chk_contains "(h0) …and the pid is in that line" "pid=$esc_h0" "$ERR"
chk_contains "(h0) nothing was reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(h0) the candidate SURVIVED" 1 "$(same_proc "$esc_h0" "$esc_h0_ls")"
reap_fixture "$esc_h0" "$esc_h0_ls"

# --- (h5) the run dir is MISSING → the ownership gate is blind, not empty ---------------------
# `inventory` may read "never created" as zero records because it only prints. This gate
# AUTHORIZES a TERM: a lane-state root that vanished hides exactly the live same-cwd peer that
# would have refused the signal (review B2).
read -r esc_h5 esc_h5_ls <<EOF
$(spawn_labelled "$S_H5" "$CWD_A" plain "$SANDBOX/h5.pid")
EOF
ENVV=(AGENT_WATCH_DIR="$SANDBOX/never-created-run"); run_stop "$S_H5"
chk_contains "(h5) a missing run dir is [unknown], not zero peers" \
             "run dir $SANDBOX/never-created-run unreadable" "$ERR"
chk_contains "(h5) …and the pid is NOT signalled" "pid=$esc_h5" "$ERR"
chk_contains "(h5) nothing was reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(h5) the candidate SURVIVED" 1 "$(same_proc "$esc_h5" "$esc_h5_ls")"
# …and the same for a run dir that exists but cannot be listed
mkdir -p "$SANDBOX/locked-run"; chmod 000 "$SANDBOX/locked-run"
ENVV=(AGENT_WATCH_DIR="$SANDBOX/locked-run"); run_stop "$S_H5"
chmod 755 "$SANDBOX/locked-run"
chk_contains "(h5) an unreadable run dir is [unknown] too" \
             "run dir $SANDBOX/locked-run unreadable" "$ERR"
chk_eq  "(h5) the candidate SURVIVED that too" 1 "$(same_proc "$esc_h5" "$esc_h5_ls")"
reap_fixture "$esc_h5" "$esc_h5_ls"

# --- (h6) a live peer whose meta is not decodable, and a planner that DIES --------------------
# `identity._meta_read` decodes UTF-8 and lets a bad byte escape as UnicodeDecodeError. Two
# halves, both fail-closed: the planner calls that peer [unknown], and a planner that exits
# non-zero must not be rendered as an empty plan — the count line would then read like a clean
# box while an unenumerated escapee is still running.
read -r esc_h6 esc_h6_ls <<EOF
$(spawn_labelled "$S_H6" "$CWD_A" plain "$SANDBOX/h6.pid")
EOF
mkmeta "$S_H6" "$CWD_A"
printf 'engine=omp\ncwd=\xff\xfe\n' > "$WATCH_RUN_DIR/$S_P.duplex.meta"
ENVV=(FAKE_TMUX_SESSIONS="$S_P"); run_stop "$S_H6"
chk_eq  "(h6) stop rc=0" 0 "$RC"
chk_contains "(h6) an undecodable peer meta is [unknown]" "has an unreadable meta" "$ERR"
chk_contains "(h6) …and the pid is NOT signalled" "pid=$esc_h6" "$ERR"
chk_contains "(h6) nothing was reaped" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(h6) the candidate SURVIVED" 1 "$(same_proc "$esc_h6" "$esc_h6_ls")"
# The second half as BEHAVIOUR: a python shim that fails only the plan verb and passes every
# other one through (`AGENTCTL_PYTHON` is the interpreter agentctl already reads). No live peer
# this time, so the ownership gate would have authorized the TERM — only the dead planner stops
# it. The stop above consumed the lane state, so the meta is re-laid for the duplex branch.
cat > "$SANDBOX/py-plan-fails" <<'PYF'
#!/usr/bin/env bash
case " $* " in *" lineage-plan "*) echo "planner exploded" >&2; exit 7 ;; esac
exec python3 "$@"
PYF
chmod +x "$SANDBOX/py-plan-fails"
mkmeta "$S_H6" "$CWD_A"
ENVV=(AGENTCTL_PYTHON="$SANDBOX/py-plan-fails"); run_stop "$S_H6"
chk_eq  "(h6) a planner that DIES does not fail the stop" 0 "$RC"
chk_contains "(h6) …it is named on stderr, with its rc" "lineage plan failed (rc=7)" "$ERR"
chk_contains "(h6) …the count line still prints" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(h6) …and NOTHING was signalled" 1 "$(same_proc "$esc_h6" "$esc_h6_ls")"
reap_fixture "$esc_h6" "$esc_h6_ls"
rm -f "$WATCH_RUN_DIR/$S_P.duplex.meta"

# --- (i0) POST-MORTEM, the raw cell: no lane state, no tmux, no residue, only a label --------
# This is the exit an `inventory` lineage-orphan row sends an operator to. It must not need a
# new verb, a new flag, a resurrected session — or a non-zero rc for having worked.
read -r esc_i0 esc_i0_ls <<EOF
$(spawn_labelled "$S_I0" "$CWD_A" plain "$SANDBOX/i0.pid")
EOF
chk_eq "(i0) pre-probe: the session owns NOTHING in the run dir" "" \
       "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep "^$S_I0\." || true)"
run_stop "$S_I0"
chk_eq  "(i0) the post-mortem stop exits 0 — it did its job" 0 "$RC"
chk_contains "(i0) …and reaps the leftover" "reaped 1 lineage process(es)" "$OUT"
chk_not_contains "(i0) the unknown-session error is gone" "unknown session" "$ERR"
chk_eq  "(i0) the leftover is GONE" 0 "$(alive "$esc_i0")"
reap_fixture "$esc_i0" "$esc_i0_ls"
# the negative control: NOTHING labelled either → still the typed unknown-session refusal
run_stop "lin${NONCE}nosuch"
chk_eq  "(i0) with nothing to reap it is still an unknown session (rc 1)" 1 "$RC"
chk_contains "(i0) …with the unchanged error on stderr" "unknown session" "$ERR"
chk_contains "(i0) …and a zero count on stdout" "reaped 0 lineage process(es)" "$OUT"

# --- (i1) POST-MORTEM, candidate RECOGNIZED and refused → 0, not "unknown session" -----------
# The raw no-lane cell again, one square over: the label phase DID attribute a process to this
# name and then refused to signal it (here the undecidable-ownership格 of (h0), reached with no
# lane state at all). `unknown session` claims the name owns nothing anywhere, which is the
# opposite of what the refusal line above it just said — and rc 1 makes automation read a
# fail-closed refusal as a failed operation (review r3 M1).
read -r esc_i1 esc_i1_ls <<EOF
$(spawn_labelled "$S_I1" "$CWD_A" no-cwd "$SANDBOX/i1.pid")
EOF
chk_eq "(i1) pre-probe: the session owns NOTHING in the run dir" "" \
       "$(ls "$WATCH_RUN_DIR" 2>/dev/null | grep "^$S_I1\." || true)"
run_stop "$S_I1"
chk_eq  "(i1) a refused candidate is not an operation that failed" 0 "$RC"
chk_contains "(i1) the refusal names the pid and the gap" \
             "[unknown] pid=$esc_i1 carries this session's label but no AGENTCTL_CWD" "$ERR"
chk_not_contains "(i1) …and the session is NOT called unknown" "unknown session" "$ERR"
chk_contains "(i1) the count line still prints a zero" "reaped 0 lineage process(es)" "$OUT"
chk_eq  "(i1) the candidate SURVIVED — refused means unsignalled" 1 \
        "$(same_proc "$esc_i1" "$esc_i1_ls")"
chk_not_contains "(i1) …and the planner is not blamed for a failure it did not have" \
                 "lineage plan failed" "$ERR"
reap_fixture "$esc_i1" "$esc_i1_ls"
# The other undecided shape of the SAME rc rule, with the fixture already reaped so nothing is
# recognizable at all: a planner that DIES enumerated nothing either, so this stop has no
# standing to call the name unknown (the shim from (h6), no lane state this time).
ENVV=(AGENTCTL_PYTHON="$SANDBOX/py-plan-fails"); run_stop "$S_I1"
chk_eq  "(i1) a stop whose planner died does not claim the name is unknown" 0 "$RC"
chk_contains "(i1) …it says the planner failed, with its rc" "lineage plan failed (rc=7)" "$ERR"
chk_not_contains "(i1) …and does not also call the session unknown" "unknown session" "$ERR"

# --- (i2) the same cell with ZERO candidates keeps the typed unknown-session refusal ----------
# The pin under (i1): only a DECIDED empty answer may be rendered as an unknown name. If a
# same-uid pid anywhere on this box had an unreadable environment the plan would say so with an
# `[unknown] pid=` line and this rc would (correctly) become 0, so the absence of that line is
# asserted as the precondition rather than assumed.
run_stop "lin${NONCE}nocand"
chk_eq  "(i2) with nothing recognized it is still an unknown session (rc 1)" 1 "$RC"
chk_contains "(i2) …with the unchanged error on stderr" "unknown session" "$ERR"
chk_not_contains "(i2) …and the emptiness was DECIDED, not blind" "[unknown] pid=" "$ERR"

# --- (i) POST-MORTEM with post-mortem artifacts on disk --------------------------------------
read -r esc_i esc_i_ls <<EOF
$(spawn_labelled "$S_I" "$CWD_A" plain "$SANDBOX/i.pid")
EOF
: > "$WATCH_RUN_DIR/$S_I.duplex.events.jsonl"          # what a real stop leaves behind
run_stop "$S_I"
chk_eq  "(i) the post-mortem stop exits 0" 0 "$RC"
chk_contains "(i) it still recognizes the dead session" "already stopped" "$OUT"
chk_contains "(i) …and still reaps the leftover" "reaped 1 lineage process(es)" "$OUT"
chk_eq  "(i) the leftover is GONE" 0 "$(alive "$esc_i")"
reap_fixture "$esc_i" "$esc_i_ls"

# --- (j) TERM ignored → bounded escalation to KILL, and the line SAYS KILL --------------------
read -r esc_j esc_j_ls <<EOF
$(spawn_labelled "$S_J" "$CWD_A" ignore-term "$SANDBOX/j.pid")
EOF
chk_eq "(j) pre-probe: the fixture is alive and ignoring TERM" 1 "$(same_proc "$esc_j" "$esc_j_ls")"
mkmeta "$S_J" "$CWD_A"
ENVV=(AGENTCTL_REAP_GRACE=1); run_stop "$S_J"
chk_eq  "(j) stop rc=0 after the escalation" 0 "$RC"
chk_contains "(j) the count line marks the escalation" \
             "reaped 1 lineage process(es) (KILL: $esc_j)" "$OUT"
chk_eq  "(j) the TERM-proof process is gone" 0 "$(alive "$esc_j")"
reap_fixture "$esc_j" "$esc_j_ls"
# UNREACHABLE by fixture, stated rather than faked: "survives its own KILL" cannot be built —
# SIGKILL is not maskable — so the rc rule for that cell is code-read, not fixture-proved.
chk_contains "(j) the survives-KILL branch exists and WARNs by pid" \
             'WARN: labelled process(es) survived KILL:' "$(cat "$AGENTCTL")"
chk_contains "(j) …and stop's exit is the max of the two phases" \
             '[ "$LIN_RC" -gt "$REAP_RC" ] && REAP_RC="$LIN_RC"' "$(cat "$AGENTCTL")"

# --- (k) inventory censuses labels whose session tmux no longer has ---------------------------
read -r esc_kd esc_kd_ls <<EOF
$(spawn_labelled "$S_KD" "$CWD_A" plain "$SANDBOX/kd.pid")
EOF
read -r esc_kl esc_kl_ls <<EOF
$(spawn_labelled "$S_KL" "$CWD_B" plain "$SANDBOX/kl.pid")
EOF
ENVV=(FAKE_TMUX_SESSIONS="$S_KL" AGENT_WATCH_DIR="$WATCH_RUN_DIR"); run_inv
chk_eq  "(k) inventory exits 0" 0 "$RC"
chk_contains "(k) the third block exists and is named" "-- lineage census --" "$OUT"
chk_eq  "(k) the dead session's process is listed exactly once, on stdout" 1 \
        "$(printf '%s\n' "$OUT" | grep -c "^lineage-orphan .*session=$S_KD .*pid=$esc_kd ")"
chk_contains "(k) …with the cwd label it carries" "cwd=$CWD_A" "$OUT"
chk_eq  "(k) a LIVE session's process is not an orphan" 0 \
        "$(printf '%s\n' "$OUT" | grep -c "session=$S_KL")"
chk_eq  "(k) the census signalled nothing: both fixtures alive" "1 1" \
        "$(same_proc "$esc_kd" "$esc_kd_ls") $(same_proc "$esc_kl" "$esc_kl_ls")"
chk_contains "(k) the boundary names the label census's false negatives" \
             "[boundary] lineage FN:" "$OUT"
reap_fixture "$esc_kd" "$esc_kd_ls"
reap_fixture "$esc_kl" "$esc_kl_ls"

# --- (k2) no tmux server + no run dir → the third block's empty word, exactly ----------------
# Hermetic on both axes: the process world is a stubbed one-row snapshot owned by another uid,
# so "we saw nothing" is a world under this test's control rather than the developer's box.
cat > "$BIN/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axwwo" ]; then
  echo "4242     1     0 S    Mon Aug 10 00:00:00 2026     01:02:03 /bin/zsh -l"
  exit 0
fi
exec /bin/ps "$@"
EOF
chmod +x "$BIN/ps"
ENVV=(AGENT_WATCH_DIR="$SANDBOX/never-created-inv" FAKE_TMUX_LS_RC=1); run_inv
rm -f "$BIN/ps"
chk_eq  "(k2) the clean fixture exits 0" 0 "$RC"
chk_eq  "(k2) the lineage block prints its own empty word exactly once" 1 \
        "$(printf '%s\n' "$OUT" | grep -c '^(none orphaned)$')"
chk_eq  "(k2) all three blocks report an explicit empty" 3 \
        "$(printf '%s\n' "$OUT" | grep -cE '^\(none\)$|^\(none orphaned\)$')"
chk_not_contains "(k2) an empty world is never dressed up as [unknown]" "[unknown]" "$OUT"

# --- (m) an OPAQUE process is a candidate of NO session ---------------------------------------
# The CI Linux red (run 33877707389, ubuntu-latest): a same-uid process whose dumpable flag is
# cleared has a root-owned /proc/<pid>/environ, so the probe goes blind on it. Those pids used
# to be printed one `[unknown] pid=` line each AND counted as "this stop recognized something",
# which turned every unknown session name on such a box into rc 0 — the (i0)/(i2) cells above
# went red on CI and stayed green on macOS, where SIP binaries yield an EMPTY env segment (a
# decidable "unlabelled") and nothing ever goes blind.
# The injection is BLACK BOX in the duplex-misplaced-hint.test.sh sense: a sitecustomize on
# PYTHONPATH adds one REAL live pid to the blind list at the single seam both platforms' env
# sources land in (`_env_by_pid`), so the shape is exercised on macOS too and no product knob
# exists for the test to lean on. The pid is a real process, so the planner's own
# "did it merely exit mid-probe" re-read keeps it — and its survival is asserted.
BLINDSHIM="$SANDBOX/blindshim"; mkdir -p "$BLINDSHIM"
cat > "$BLINDSHIM/sitecustomize.py" <<'PY'
import builtins, os
_pid = os.environ.get("FAKE_BLIND_PID")
if _pid:
    _real_import = builtins.__import__
    def _hook(name, *a, **k):
        mod = _real_import(name, *a, **k)
        if name == "watchctl" and not getattr(mod, "_BLIND_SHIM", False):
            mod._BLIND_SHIM = True
            _real = mod._env_by_pid
            def _spy(rows):
                envs, blind = _real(rows)
                return envs, blind if envs is None else sorted({*blind, int(_pid)})
            mod._env_by_pid = _spy
        return mod
    builtins.__import__ = _hook
PY
blind_count() { # $1 stderr text → the N of the one summary line, 0 when there is none
  local n
  n="$(printf '%s\n' "$1" \
       | sed -n 's/.*\[unknown\] \([0-9]*\) process(es) with unreadable environment.*/\1/p' \
       | head -1)"
  echo "${n:-0}"
}
S_M="lin${NONCE}m"; S_M2="lin${NONCE}m2"
/bin/sleep 300 & BLIND_PID=$!
BLIND_LS="$(lstart_of "$BLIND_PID")"
chk_eq "(m) pre-probe: the process to be made opaque is alive" 1 \
       "$(same_proc "$BLIND_PID" "$BLIND_LS")"
# CONTROL first, on the same name: whatever this box's own opaque processes number, N.
run_stop "$S_M"
base_n="$(blind_count "$ERR")"
chk_eq  "(m) CONTROL: a name that owns nothing is an unknown session (rc 1)" 1 "$RC"
ENVV=(PYTHONPATH="$BLINDSHIM" FAKE_BLIND_PID="$BLIND_PID"); run_stop "$S_M"
chk_eq "(m) METER POSITIVE: the injected pid really reached the blind reading (N+1)" 1 \
       "$(( $(blind_count "$ERR") - base_n ))"
chk_eq  "(m) an opaque process never makes an unknown name look owned (rc 1)" 1 "$RC"
chk_contains "(m) …with the unchanged error on stderr" "unknown session" "$ERR"
chk_eq  "(m) the blindness is reported as ONE count line" 1 \
        "$(printf '%s\n' "$ERR" \
           | grep -cE '\[unknown\] [0-9]+ process\(es\) with unreadable environment')"
chk_not_contains "(m) …never one line per pid (a multi-user box would flood)" \
                 "[unknown] pid=" "$ERR"
chk_eq  "(m) the count line still prints on stdout, at zero" 1 \
        "$(printf '%s\n' "$OUT" | grep -c '^reaped 0 lineage process(es)$')"
chk_eq  "(m) and the blindness never leaks to stdout" 0 \
        "$(printf '%s\n' "$OUT" | grep -c 'unreadable environment')"
chk_eq  "(m) the opaque process was never signalled" 1 "$(same_proc "$BLIND_PID" "$BLIND_LS")"
# the census says it the same way: a count, never a row per pid
ENVV=(PYTHONPATH="$BLINDSHIM" FAKE_BLIND_PID="$BLIND_PID" AGENT_WATCH_DIR="$WATCH_RUN_DIR")
run_inv
chk_eq  "(m) inventory exits 0 beside an opaque process" 0 "$RC"
chk_eq  "(m) the census prints ONE count row for the opaque processes" 1 \
        "$(printf '%s\n' "$OUT" \
           | grep -cE '^lineage-unknown +[0-9]+ process\(es\) with unreadable environment')"
chk_eq  "(m) …and never a census row per pid" 0 \
        "$(printf '%s\n' "$OUT" | grep -c '^lineage-unknown.*pid=')"

# --- (m2) blindness beside a RECOGNIZED candidate changes nothing about the candidate ---------
read -r esc_m2 esc_m2_ls <<EOF
$(spawn_labelled "$S_M2" "$CWD_A" plain "$SANDBOX/m2.pid")
EOF
mkmeta "$S_M2" "$CWD_A"
ENVV=(PYTHONPATH="$BLINDSHIM" FAKE_BLIND_PID="$BLIND_PID"); run_stop "$S_M2"
chk_eq  "(m2) stop rc=0" 0 "$RC"
chk_contains "(m2) the recognized candidate is still reaped by the existing predicate" \
             "reaped 1 lineage process(es)" "$OUT"
chk_eq  "(m2) the candidate is GONE" 0 "$(alive "$esc_m2")"
chk_eq  "(m2) the blindness is STILL one single count line" 1 \
        "$(printf '%s\n' "$ERR" \
           | grep -cE '\[unknown\] [0-9]+ process\(es\) with unreadable environment')"
chk_not_contains "(m2) …and still not one line per pid" "[unknown] pid=" "$ERR"
chk_eq  "(m2) the opaque process itself survived, unsignalled" 1 \
        "$(same_proc "$BLIND_PID" "$BLIND_LS")"
reap_fixture "$esc_m2" "$esc_m2_ls"
reap_fixture "$BLIND_PID" "$BLIND_LS"

# --- (l) ASSEMBLY: one pane point exports both labels, and a real engine sees them ------------
unset FAKE_TMUX_DISPLAY_FAIL
FIX="$REPO_ROOT/test/duplex-fixtures"
WT="$SANDBOX/wt-l"; mkdir -p "$WT"
WT_REAL="$(cd "$WT" && pwd -P)"          # agentctl records the PHYSICAL cwd, /private on macOS
printf 'investigate the thing\n' > "$SANDBOX/goal-l.md"
cat > "$SANDBOX/env-dump-omp" <<EOF
#!/usr/bin/env bash
. "$FIXID"
# The pane command ends in "ENGINE <&3 >>events", so the engine is a CHILD of the pane shell
# and no pidfile of this runner would name it. It records its own identity here (the exec
# below keeps both pid and start time), which is what lets teardown reap it without a pid tree.
printf '%s %s\n' "\$\$" "\$(lstart_of \$\$)" > "$FAKE_TMUX_STATE/engine.pid"
printenv AGENTCTL_SESSION > "$SANDBOX/pane-session.txt" || : > "$SANDBOX/pane-session.txt"
printenv AGENTCTL_CWD     > "$SANDBOX/pane-cwd.txt"     || : > "$SANDBOX/pane-cwd.txt"
exec python3 "$FIX/fake_omp_duplex.py"
EOF
chmod +x "$SANDBOX/env-dump-omp"
export AGENTCTL_BIN_OMP="$SANDBOX/env-dump-omp" FAKE_PROVIDER_LOG="$SANDBOX/l-omp.log"
out="$(bash "$AGENTCTL" start omp "$S_L" "$WT" --goal "$SANDBOX/goal-l.md" --no-preflight 2>&1)"
rc=$?
chk_eq  "(l) the session started" 0 "$rc"
chk_eq  "(l) the pane exports the session label" 1 "$(seen "$SANDBOX/pane-session.txt" "$S_L")"
chk_eq  "(l) …and the value IS the session name, nothing else" "$S_L" \
        "$(cat "$SANDBOX/pane-session.txt" 2>/dev/null)"
chk_eq  "(l) the SAME point exports the cwd label" 1 "$(seen "$SANDBOX/pane-cwd.txt" "$WT_REAL")"
chk_eq  "(l) …and the value IS the session cwd" "$WT_REAL" \
        "$(cat "$SANDBOX/pane-cwd.txt" 2>/dev/null)"
chk_eq  "(l) both labels come from ONE export in ONE assembly point" 1 \
        "$(grep -c 'export AGENTCTL_SESSION=.* AGENTCTL_CWD=' "$AGENTCTL")"
chk_eq  "(l) the engine recorded its own identity, so teardown has one to verify" 1 \
        "$(read -r p pls < "$FAKE_TMUX_STATE/engine.pid"; same_proc "${p:-0}" "${pls:-}")"
bash "$AGENTCTL" stop "$S_L" >/dev/null 2>&1
unset AGENTCTL_BIN_OMP FAKE_PROVIDER_LOG
# teardown by RECORDED (pid, start time) only: a concurrent runner's engine is untouched, and a
# pid recycled since it was recorded is not signalled either
for pidfile in "$FAKE_TMUX_STATE"/*.pid; do
  [ -f "$pidfile" ] || continue
  read -r p pls < "$pidfile" || continue
  reap_fixture "${p:-0}" "${pls:-}"
done

sandbox_clean
summary
