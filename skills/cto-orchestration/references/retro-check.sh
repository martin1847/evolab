#!/usr/bin/env bash
# retro-check.sh — deterministic mechanical check for cto-orchestration 复盘 (SKILL.md §5).
# Verifies mechanical proxies only, not semantic quality. Worktree, ACTIVE_CONTEXT and
# dead-agent-session failures return non-zero; roadmap, decision-queue, memory and
# live-session findings are warnings and do not block.
#
# Usage:
#   bash retro-check.sh --base <branch> --docs <docs-dir> [--memory <MEMORY.md>] [--memory-cap N] [--repo <git-dir>]
# Defaults: --base auto-detected (origin/HEAD → main/master/develop); --docs docs; --memory-cap 45.
set -uo pipefail

BASE=""; DOCS="docs"; MEMORY=""; MEMCAP=45; REPO="."
while [ $# -gt 0 ]; do case "$1" in
  --base) BASE="$2"; shift 2;;
  --docs) DOCS="$2"; shift 2;;
  --memory) MEMORY="$2"; shift 2;;
  --memory-cap) MEMCAP="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

TODAY="$(date +%F)"
# THE CYCLE WINDOW, single-sourced: today or yesterday. A retro session routinely crosses
# midnight, so a one-day window is what "本复盘周期" means to every date-judging check here
# (2 = ACTIVE_CONTEXT freshness, 9 = 批 time accounting). An empty YDAY (no BSD and no GNU
# date) narrows the window to today rather than widening it silently.
YDAY="$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F 2>/dev/null)"
fails=0; warns=0
ok(){ echo "  [ok]   $*"; }
fail(){ echo "  [FAIL] $*"; fails=$((fails+1)); }
warn(){ echo "  [warn] $*"; warns=$((warns+1)); }

echo "== retro-check (date=$TODAY) =="

# resolve base branch
if [ -z "$BASE" ]; then
  BASE="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -z "$BASE" ] && for b in main master develop; do git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$b" && BASE="$b" && break; done
fi
[ -z "$BASE" ] && { warn "could not resolve base branch (pass --base); skipping worktree-merged check"; }

# 1) stray LINKED worktrees on already-merged branches (excludes the main checkout)
echo "1) worktree 核对 (已合分支无孤儿; 主 checkout 豁免):"
if [ -n "$BASE" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$REPO" fetch -q origin "$BASE" 2>/dev/null; then FETCH_OK=1; else FETCH_OK=0; fi
  TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
  stray=0; cur="" br=""
  # iterate via a here-string so the loop runs in THIS shell (can bump $stray)
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) cur="${line#worktree }";;
      branch\ *) br="${line#branch refs/heads/}"
        # skip the main checkout (its path == toplevel) — it's not a disposable worktree
        if [ -n "$br" ] && [ "$cur" != "$TOP" ] && git -C "$REPO" merge-base --is-ancestor "$br" "origin/$BASE" 2>/dev/null; then
          echo "  [FAIL] stray worktree on MERGED branch '$br' → $cur  (git worktree remove)"; stray=$((stray+1))
        fi;;
    esac
  done <<< "$(git -C "$REPO" worktree list --porcelain 2>/dev/null)"
  if [ "$stray" -gt 0 ]; then fail "$stray stray linked worktree(s) on merged branches — remove them"; else ok "no linked worktree on a merged branch"; fi

  # 1b) base checkouts diverged from origin (post-squash shape: local side keeps the
  # pre-squash originals, upstream has the squashed result — ff can never happen again).
  # Detection + warn ONLY: the reset is the orchestrator's call (rescue真未合并的工作 first).
  # Ahead-only (unpushed local work, origin未动) deliberately does NOT warn — 宁钝勿敏.
  # A comparison that CANNOT run (fetch failed / ref missing) is UNKNOWN, never "aligned".
  div=0; unknown=0; seen=0
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) cur="${line#worktree }";;
      branch\ *) br="${line#branch refs/heads/}"
        if [ "$br" = "$BASE" ]; then
          seen=$((seen+1))
          if [ "$FETCH_OK" = 1 ] && counts="$(git -C "$REPO" rev-list --left-right --count "origin/$BASE...$br" 2>/dev/null)"; then
            read -r behind ahead <<< "$counts"
            if [ "${ahead:-0}" -gt 0 ] && [ "${behind:-0}" -gt 0 ]; then
              # printf %q: the remedy is meant to be copy-pasted — literal quote-wrapping
              # is not a shell escape (a path containing a quote breaks out of it)
              qcur="$(printf '%q' "$cur")"; qref="$(printf '%q' "origin/$BASE")"
              echo "  [warn] base checkout '$cur' diverged from origin/$BASE (ahead $ahead / behind $behind) — squash-stale? verify content is merged, then: git -C $qcur branch backup/pre-realign && git -C $qcur reset --hard $qref"
              div=$((div+1))
            fi
          else
            echo "  [warn] base checkout '$cur': cannot compare with origin/$BASE (fetch failed / ref missing) — divergence UNKNOWN"
            unknown=$((unknown+1))
          fi
        fi;;
    esac
  done <<< "$(git -C "$REPO" worktree list --porcelain 2>/dev/null)"
  if [ $((div+unknown)) -gt 0 ]; then
    warn "$div diverged / $unknown UNKNOWN base checkout(s) — align after verifying (backup ref first)"
  elif [ "$seen" -eq 0 ]; then
    ok "no checkout on base branch '$BASE' to compare"
  else
    ok "base checkouts aligned with origin/$BASE"
  fi
fi

# 2) ACTIVE_CONTEXT rewritten today
echo "2) ACTIVE_CONTEXT 整篇重写 (今日):"
AC="$DOCS/ACTIVE_CONTEXT.md"
if [ -f "$AC" ]; then
  lr="$(grep -m1 -iE 'Last rewritten' "$AC" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  if [ "$lr" = "$TODAY" ] || [ -n "$YDAY" -a "$lr" = "$YDAY" ]; then ok "Last rewritten: $lr (today/yesterday — session may cross midnight)"; else fail "ACTIVE_CONTEXT 'Last rewritten'=${lr:-none}, stale (>1d vs $TODAY) — rewrite the snapshot"; fi
else fail "$AC not found (pass --docs)"; fi

# 3) roadmap touched recently (soft)
echo "3) roadmap 翻状态 (近期动过):"
RM="$DOCS/roadmap/active-roadmap.md"
if [ -f "$RM" ]; then
  if [ -n "$(find "$RM" -mtime -1 2>/dev/null)" ]; then ok "roadmap modified within 24h"; else warn "roadmap not touched in 24h — confirm status-flip not skipped (ok if genuinely unchanged)"; fi
else warn "$RM not found — skip"; fi

# 4) decision-queue freshness (soft, opt-in — only if DECISION_QUEUE.md present; §9 mechanism)
echo "4) 决策队列刷新 (DECISION_QUEUE.md 在则近期动过):"
DQ="$DOCS/DECISION_QUEUE.md"
if [ -f "$DQ" ]; then
  if [ -n "$(find "$DQ" -mtime -1 2>/dev/null)" ]; then ok "DECISION_QUEUE.md modified within 24h"; else warn "DECISION_QUEUE.md not touched in 24h — refresh (清 ✅ / revisit 到期重浮 / 全局图); 队列腐烂是 §9 最弱点"; fi
  cleared_history="$(awk '
    /^##[[:space:]]+/ {
      if (inside) exit
      upper=toupper($0)
      inside=(index($0, "✅") && (index(upper, "CLEARED") || index($0, "已清")))
      next
    }
    inside && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*<!--/ { print; exit }
  ' "$DQ")"
  if [ -n "$cleared_history" ]; then
    fail "DECISION_QUEUE.md retains cleared history — remove it before handoff/compact; git history is the audit trail"
  else
    ok "decision queue contains active/parked items only"
  fi
else echo "  [skip] no $DQ (decision-queue 是 opt-in)"; fi

# 5) MEMORY.md size (soft)
echo "5) memory 治理 (索引行数):"
if [ -n "$MEMORY" ] && [ -f "$MEMORY" ]; then
  n="$(wc -l < "$MEMORY" | tr -d ' ')"
  if [ "$n" -le "$MEMCAP" ]; then ok "MEMORY.md $n lines (≤$MEMCAP)"; else warn "MEMORY.md $n lines > $MEMCAP — trim/group COMPLETED"; fi
elif [ -n "$MEMORY" ]; then warn "$MEMORY not found — skip"; else echo "  [skip] no --memory given"; fi

# 6) agent sessions of THIS repo left uncleaned — backstop for "terminal state ⇒
# agentctl stop" discipline (field 2026-07-28: 43 unstopped sessions leaked engines).
# FAIL = round believed over (terminal marker / rc recorded / wrapper dead) but control
# state remains; live mid-work sessions only warn (long-runners are legitimate).
echo "6) agent 会话收口 (本仓 duplex 会话: 终态必已 stop):"
AWDIR="${AGENT_WATCH_DIR:-/tmp/agent-watch-run}"
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
if [ -d "$AWDIR" ] && [ -n "$TOP" ]; then
  dead=0; live=0; livenames=""
  for m in "$AWDIR"/*.duplex.meta; do
    [ -e "$m" ] || continue
    mcwd="$(sed -n 's/^cwd=//p' "$m" | head -1)"
    # physical-path normalize: /tmp and /var are symlinks on macOS, and git toplevel
    # is already physical — a raw prefix match would silently skip those sessions
    mcwd="$(cd "$mcwd" 2>/dev/null && pwd -P || echo "$mcwd")"
    case "$mcwd" in "$TOP"|"$TOP"/*) ;; *) continue;; esac
    s="$(basename "$m" .duplex.meta)"
    # terminal evidence needs no tmux (marker / recorded rc); a dead wrapper only
    # counts when tmux is around to probe — without it, liveness is UNKNOWN, not dead.
    over=0
    { [ -e "$AWDIR/$s.terminal.json" ] || [ -e "$AWDIR/$s.duplex.rc" ]; } && over=1
    [ "$over" = 0 ] && command -v tmux >/dev/null 2>&1 \
      && ! tmux has-session -t "=$s" 2>/dev/null && over=1
    if [ "$over" = 1 ]; then
      echo "  [FAIL] session '$s' round is over but not stopped → agentctl stop $s"; dead=$((dead+1))
    else
      live=$((live+1)); livenames="$livenames $s"
    fi
  done
  if [ "$dead" -gt 0 ]; then fail "$dead 本仓终态会话未清 — agentctl stop 收口（引擎进程与控制态在泄漏）"
  else ok "no terminal-but-uncleaned session for this repo"; fi
  [ "$live" -gt 0 ] && warn "$live live/unknown session(s) of this repo still registered:$livenames — 逐个确认是有意长跑，其余 stop"
  # FOREIGN tmux sessions — live sessions matching NO recorded session. The comparison set
  # is EVERY recorded session (all repos, plus each `<s>-watchd` companion): filtering by
  # this repo's cwd would report other seats' legitimate sessions as foreign. Field
  # 2026-08-10: a seat with zero dispatch records read "clean up finished sessions" as a
  # bare `tmux ls` sweep and killed 6+ sessions owned by other seats. So: WARN ONLY —
  # never FAIL, never kill, and a session name is an exact string, never a shell pattern.
  known=""
  for m in "$AWDIR"/*.duplex.meta; do
    [ -e "$m" ] || continue
    known="$known$(basename "$m" .duplex.meta)
$(basename "$m" .duplex.meta)-watchd
"
  done
  if command -v tmux >/dev/null 2>&1; then
    tse="$(mktemp)"; tsout="$(tmux list-sessions -F '#{session_name}' 2>"$tse")"; trc=$?
    tsmsg="$(cat "$tse")"; rm -f "$tse"
    if [ "$trc" != 0 ]; then
      # no server = nobody home (silent); anything else is an UNCHECKED face, not a clean one
      case "$tsmsg" in
        *"no server running"*|*"error connecting to"*|*"no sessions"*) ;;
        *) warn "CHECKER-ERROR: tmux list-sessions rc=$trc (${tsmsg:-no message}) — FOREIGN 面未检查，别当 clean";;
      esac
    else
      foreign=""
      while IFS= read -r sname; do
        [ -n "$sname" ] || continue
        # quote each name: a session name may contain spaces, so an unquoted list would
        # read as more (or fewer) sessions than it names
        printf '%s\n' "$known" | grep -qxF -- "$sname" || foreign="$foreign \"$sname\""
      done < <(printf '%s\n' "$tsout")
      [ -n "$foreign" ] && warn "FOREIGN:$foreign — tmux 会话不在任何记录会话中（可能属他人/他席位）：只报不杀，未经确认勿动"
    fi
  fi
else echo "  [skip] no agentctl run dir / not a git repo"; fi

# 7) typed lesson ledger — 教训要与门同形态 (retrospective.md §3): a lesson line is
# machine-countable data; prose lessons can't drive decisions and nobody counts their
# recurrences. Grammar (line start, optional "- " list marker):
#   LESSON: <slug> n=<int> gate=<none|accepted(<reason>)|<repo-relative-path>>
# FAIL = n>=2 still gateless (a lesson may live as prose at most twice), or a claimed
# gate file that does not exist (a dead pointer reads as protection). No LESSON lines
# at all = ledger not adopted → note only: can't count what was never typed.
echo "7) 教训同形态 (LESSON 行: n≥2 须 gate 或显式 accepted):"
lessons=0; lfail=0
while IFS= read -r ln; do
  lfile="${ln%%:*}"; body="${ln#*LESSON:}"
  lessons=$((lessons+1))
  # full-line grammar FIRST — a partially matching line is malformed, never partially
  # consumed (review-reproduced bypasses: 'n=1x' truncated to 1; an integer past the
  # shell test range erroring straight to green; prose after gate= read as a path).
  # slug is ASCII kebab/word chars; n is 1-9 digits (a cap, so [ -ge ] can't overflow).
  if ! printf '%s' "$body" | grep -qE '^[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+n=[0-9]{1,9}[[:space:]]+gate=[^[:space:]]'; then
    echo "  [warn] malformed LESSON line in $lfile — need 'LESSON: <slug> n=<int> gate=<none|accepted(reason)|path>'"
    warns=$((warns+1)); continue
  fi
  slug="$(printf '%s' "$body" | awk '{print $1}')"
  ln_n="$(printf '%s' "$body" | grep -oE ' n=[0-9]+' | head -1 | cut -d= -f2)"
  gate="$(printf '%s' "$body" | sed -n 's/.* gate=//p' | sed 's/[[:space:]]*$//')"
  case "$gate" in
    none)
      if [ "$ln_n" -ge 2 ]; then
        echo "  [FAIL] lesson '$slug' n=$ln_n gate=none — 复发≥2 还躺散文档：本批升门（gate=<path>）或主理人 accepted(理由)"
        lfail=$((lfail+1))
      fi;;
    none*)  # trailing prose after 'none' is not a path claim — reject, don't guess
      echo "  [warn] malformed LESSON line in $lfile — trailing text after gate=none"
      warns=$((warns+1));;
    accepted\(*\))
      reason="${gate#accepted(}"; reason="${reason%)}"
      if [ -z "$(printf '%s' "$reason" | tr -d '[:space:]')" ]; then
        echo "  [warn] lesson '$slug': accepted needs a reason — accepted(<why>)"; warns=$((warns+1))
      fi;;
    accepted*)
      echo "  [warn] lesson '$slug': accepted needs a reason — accepted(<why>)"; warns=$((warns+1));;
    *)
      if [ ! -e "$REPO/$gate" ]; then
        echo "  [FAIL] lesson '$slug' claims gate '$gate' but no such file — dead pointer reads as protection"
        lfail=$((lfail+1))
      fi;;
  esac
done < <(find "$DOCS" -name '*.md' -type f -exec awk '
  FNR==1 { fence=0 }
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  /^(- )?LESSON:/ { print FILENAME ":" $0 }
' {} + 2>/dev/null)
if [ "$lessons" -eq 0 ]; then
  echo "  [skip] no LESSON lines under $DOCS — 教训台账未 typed 化，复发计数不可机检（形态见 retrospective.md §3）"
elif [ "$lfail" -gt 0 ]; then
  fail "$lfail gateless/dead-pointer lesson(s) — 升门或 accepted 后再收口"
else
  ok "$lessons lesson line(s), none past the prose limit"
fi

# 8) gate-effect audit (GATE-AUDIT 行) — 形态与 FAIL 判据单源: retrospective.md §3「门效果审计」条。
echo "8) 门效果审计 (GATE-AUDIT 行: hits=0 且 false≥2 须 kill 或 keep(理由)):"
gaudits=0; gfail=0
while IFS= read -r ln; do
  gfile="${ln%%:*}"; body="${ln#*GATE-AUDIT:}"
  gaudits=$((gaudits+1))
  if ! printf '%s' "$body" | grep -qE '^[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+hits=[0-9]{1,9}[[:space:]]+false=[0-9]{1,9}[[:space:]]+action=(kill|keep(\(.*\))?)[[:space:]]*$'; then
    echo "  [warn] malformed GATE-AUDIT line in $gfile — need 'GATE-AUDIT: <slug> hits=<int> false=<int> action=<kill|keep(<reason>)>'"
    warns=$((warns+1)); continue
  fi
  gslug="$(printf '%s' "$body" | awk '{print $1}')"
  ghits="$(printf '%s' "$body" | grep -oE ' hits=[0-9]+' | head -1 | cut -d= -f2)"
  gfalse="$(printf '%s' "$body" | grep -oE ' false=[0-9]+' | head -1 | cut -d= -f2)"
  gaction="$(printf '%s' "$body" | sed -n 's/.* action=//p' | sed 's/[[:space:]]*$//')"
  case "$gaction" in
    kill) ;;
    keep\(*\))
      reason="${gaction#keep(}"; reason="${reason%)}"
      if [ -z "$(printf '%s' "$reason" | tr -d '[:space:]')" ] && [ "$ghits" -eq 0 ] && [ "$gfalse" -ge 2 ]; then
        echo "  [FAIL] gate '$gslug' hits=0 false=$gfalse kept with empty reason — 连续误报零战果默认删门，保留要写 keep(<why>)"
        gfail=$((gfail+1))
      fi;;
    keep)
      if [ "$ghits" -eq 0 ] && [ "$gfalse" -ge 2 ]; then
        echo "  [FAIL] gate '$gslug' hits=0 false=$gfalse action=keep — 连续误报零战果默认删门，保留要写 keep(<why>)"
        gfail=$((gfail+1))
      fi;;
  esac
done < <(find "$DOCS" -name '*.md' -type f -exec awk '
  FNR==1 { fence=0 }
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  /^(- )?GATE-AUDIT:/ { print FILENAME ":" $0 }
' {} + 2>/dev/null)
if [ "$gaudits" -eq 0 ]; then
  echo "  [skip] no GATE-AUDIT lines under $DOCS — 本周期自造门未记账（形态见 retrospective.md §3）"
elif [ "$gfail" -gt 0 ]; then
  fail "$gfail zero-catch gate(s) kept without reason — 删门或 keep(理由) 后再收口"
else
  ok "$gaudits gate-audit line(s), no unjustified zero-catch gate"
fi

# 9) 批时间记账 — SKILL §2「提效是显式目标」的收口半边: 批 overhead 计入杠杆账，收口在台账
# 记 wall/avoidable 两个数。没有这两个数，"越搞越慢" 只能靠主理人发火才被发现（本周实证 n=2）。
# 台账 = 该仓 AGENTS.md（`--repo` 定位，不新增入参）；判据只看本复盘周期（TODAY/YDAY）的「批」行。
# 量具坏 = FAIL：台账读不到时这一面根本没检查，而一个看不见的记账面不是一个干净的记账面
# （与 check 2 的 "$AC not found" 同判、与 guard (14)/(15) 的 instrument 面同源）。
# KILL CRITERION (slug `retro-time-ledger`, 复盘按 GATE-AUDIT 结账): hits=0 ∧ false>=2 ⇒ kill,
# 外加一条本检独有的——**记数从未改变过任何决策**（连续两个周期两个数都记了、没有一次因此
# 改派发/砍轮数/换车道）⇒ kill：一个只被填写、从不被读的字段是仪式，不是门。
echo "9) 批时间记账 (本周期「批」行须记 wall= / avoidable=):"
# ── the READ-OUT half (2026-09-03) ────────────────────────────────────────────────────
# This check's input used to be entirely human: both numbers were computed by hand off the
# session transcripts, so all the check could verify was that SOMEBODY had typed two numbers.
# `agentctl phases` gives the first of them a machine source, and this block prints it BEFORE
# the accounting check — as INPUT to the person writing the entry.
# It is deliberately not a verdict and not a suggestion: no `wall≈` / `avoidable≈` line is
# printed. Avoidable minutes are a judgement about what a batch should have cost, and a machine
# guess would be pasted into the ledger as if a machine had made that judgement. The banner
# says which of the two this is, in the one place a reader cannot miss.
# It never touches PASS/FAIL. Coverage `unknown` (a missing ledger shard, an empty ledger, no
# `agentctl` on PATH, no python3) prints ONE `n/a` line and the accounting check below runs
# byte-identically — a reading nobody can vouch for must not look like a measurement.
# Window start comes from the SAME TODAY/YDAY cycle source as every other date-judging check
# here (yesterday 00:00 local, or today 00:00 on a box with no date arithmetic), carried with
# the local UTC offset: ledger rows are UTC, so a naive instant would skew by the timezone
# without saying a word.
PH_OFF="$(date +%z 2>/dev/null)"
case "$PH_OFF" in
  [+-][0-9][0-9][0-9][0-9]) PH_SINCE="${YDAY:-$TODAY}T00:00:00${PH_OFF%??}:${PH_OFF#???}" ;;
  *) PH_SINCE="" ;;
esac
if [ -z "$PH_SINCE" ]; then
  echo "  phases: n/a (date +%z gave no UTC offset — the cycle start cannot be spelled RFC3339)"
elif ! command -v agentctl >/dev/null 2>&1; then
  echo "  phases: n/a (agentctl not on PATH — no phase ledger to read)"
elif ! command -v python3 >/dev/null 2>&1; then
  echo "  phases: n/a (no python3 — the reading cannot be rendered)"
else
  PH_JSON="$(agentctl phases --json --since "$PH_SINCE" ${TOP:+--repo "$TOP"} 2>/dev/null)"
  printf '%s' "$PH_JSON" | python3 -c '
import json
import sys

raw = sys.stdin.read()
try:
    report = json.loads(raw)
except ValueError:
    print("  phases: n/a (agentctl phases produced no readable report)")
    raise SystemExit(0)
if not isinstance(report, dict):
    print("  phases: n/a (agentctl phases produced no readable report)")
    raise SystemExit(0)
if report.get("coverage") != "ok" and report.get("coverage") != "partial":
    # `unknown` — a missing shard, an UNREADABLE one (a directory wearing a shard name, a
    # dangling link, mode 000), an empty ledger, or a report from a version that does not
    # publish coverage at all. Every one of them means this pane cannot vouch for the window,
    # and a set of zeroes nobody measured looks exactly like a measurement.
    holes = ",".join(report.get("shards_missing") or []) or "-"
    dark = ",".join(report.get("shards_unreadable") or []) or "-"
    print("  phases: n/a (coverage unknown — shards missing %s, unreadable %s)"
          % (holes, dark))
    raise SystemExit(0)


def mins(seconds):
    return "n/a" if not isinstance(seconds, (int, float)) else "%.0fm" % (seconds / 60.0)


# Everything below indexes the documented report shape. A report that does not HAVE that shape
# degrades to n/a like every other unusable input: this pane is advisory, and a traceback in
# the middle of a retro is not an advisory.
try:
    read = report["readings"]
    lines = [
        "  MECHANICAL INPUT — DO NOT COPY AS VERDICT",
        "    coverage=%s  seats=%d  skipped=%d  clock_regressed=%d  future_dropped=%d"
        % (report["coverage"], len(report["sessions"]), report["skipped"],
           report["clock_regressed"], report.get("future_dropped", 0)),
        "    batch_span=%s  seat_wall=%s (seat machine-time, parallel seats sum above wall)"
        % (mins(read["batch_span_s"]), mins(read["seat_wall_s"])),
        "    review_wall=%s  idle_span=%s over %d gap(s)"
        % (mins(read["review_wall_s"]), mins(read["idle_span_s"]), read["idle_segments"]),
    ]
    for gap in read["idle_top"]:
        lines.append("      idle %s from %s" % (mins(gap["seconds"]), gap["from"]))
    hops = sorted(read["dispatch_latency"], key=lambda hop: hop["seconds"],
                  reverse=True)[:3]
    lines.append("    dispatch_latency max=%s (%d measured, per terminal — never summed)"
                 % (mins(read["dispatch_latency_max_s"]), len(read["dispatch_latency"])))
    for hop in hops:
        lines.append("      +%s after %s %s → %s %s"
                     % (mins(hop["seconds"]), hop["name"], hop["class"], hop["next_event"],
                        hop["next_name"]))
    lines.append("    ^ numbers only. wall= / avoidable= remain YOUR judgement about "
                 "this batch.")
except (KeyError, TypeError, IndexError, ValueError):
    print("  phases: n/a (agentctl phases produced no readable report)")
    raise SystemExit(0)
print("\n".join(lines))
'
fi
LEDGER="$REPO/AGENTS.md"
if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
  fail "台账 $LEDGER 不可读 — 批 overhead 记账面未检查（量具坏 ≠ 绿）；建台账或用 --repo 指对仓"
else
  unbilled=0; billed=0
  # one pass, two verdicts: `B` = a billed entry, `U<line>` = an entry with no accounting.
  # The loop runs in THIS shell (process substitution, as check 1 does) so both counters survive.
  while IFS= read -r ln; do
    case "$ln" in
      B) billed=$((billed+1));;
      U*) echo "  [FAIL] 批条目缺时间记账: ${ln#U}"; unbilled=$((unbilled+1));;
    esac
  done < <(awk -v today="$TODAY" -v yday="$YDAY" '
    FNR==1 { fence=0 }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    index($0, "批") == 0 { next }
    index($0, today) == 0 && (yday == "" || index($0, yday) == 0) { next }
    index($0, "wall=") && index($0, "avoidable=") { print "B"; next }
    { print "U" $0 }
  ' "$LEDGER")
  if [ "$unbilled" -gt 0 ]; then
    fail "$unbilled 条本周期批条目没记 wall/avoidable — 记账格式一行示例：'批 $TODAY <名> … wall=95m avoidable=30m'（avoidable = 本可避免的返工/空转分钟）"
  elif [ "${billed:-0}" -gt 0 ]; then
    ok "$billed 条本周期批条目均记了 wall/avoidable"
  else
    echo "  [skip] $LEDGER 本周期无「批」条目 — 无 overhead 可核（形态见 SKILL.md §2 提效条）"
  fi
fi

echo "== result: $fails FAIL, $warns warn =="
[ "$fails" -eq 0 ]
