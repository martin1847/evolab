#!/usr/bin/env bash
# Ratchet for text this repo INJECTS into an agent's context.
#
# Why: prompts that ship inside CLI tooling are the hidden half. SKILL.md and README get read,
# reviewed and slimmed; the footer stapled onto every goal frame and the text a guard pushes into a
# worker's context when it blocks a call do not — every incident adds a sentence and nothing ever
# takes one away. The footer went 573 -> 957 bytes across two incidents before anyone weighed it.
#
# WHAT IS MEASURED, and why it is not the obvious thing: an earlier version of this gate matched
# string literals by PREFIX ("DENY:", "REMINDER"...) and counted len() as if it were bytes. Cold
# review showed both were wrong, with reproductions: the census missed a live PostToolUse
# additionalContext message entirely (2000 chars could be added to it with this suite staying
# green), double-counted f-string parents and their children, and reported code points, so swapping
# one ASCII char for one CJK char grew the real payload while every number here stood still.
#
# So: measure by SINK, in UTF-8 bytes. The sinks are where text actually leaves for an agent —
# sys.stderr.write (a PreToolUse denial reason) and the additionalContext / permissionDecisionReason
# fields of a json.dumps hook response. Text reaching a sink through one local variable is resolved,
# because that is how the longest messages are written.
#
# KNOWN BOUNDARY, stated rather than papered over: this is static extraction. It follows literals
# and single local-variable assignment; it does not follow conditional assembly, cross-function
# passing, or a sink in a file not listed here. The known-positive recall check below is what keeps
# that honest — it fails if the extractor stops seeing a message we KNOW is injected, so a silent
# regression in the extractor cannot read as a shrinking budget. It does not prove a brand-new
# evasion is impossible.
#
# This gate does not judge whether the wording is good, and does not forbid growth. It makes growth
# deliberate: to raise a ceiling, say in the commit message what the added bytes buy and why it
# could not come from cutting elsewhere, and edit the baseline in the same commit.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL_SRC="../skills/cto-orchestration/references/agentctl/agentctl"
GUARD_BASH="../skills/cto-orchestration/references/agentctl/cto-guard-bash.py"
GUARD_AGENT="../skills/cto-orchestration/references/agentctl/cto-guard-agent.py"
GUARD_EDIT="../skills/cto-orchestration/references/agentctl/cto-guard-edit.py"

# ---- baselines: UTF-8 bytes, measured 2026-08-12 ----------------------------------------------
# These are CURRENT-MAXIMUM ratchets, not validated thresholds. No experiment says 754 bytes is
# where a worker stops reading; the number's only claim is "no bigger than today". Treat a failure
# as "justify this growth", not as "you crossed a known limit".
BUDGET_FOOTER=868          # with-deliverable shape (FIXED bytes — the sentence is generic,
                           # no glob enters the frame: R2 caught that a start-time glob lies
                           # once `steer -d` moves the deliverable, and a variable payload
                           # escapes any ratchet). No-deliverable sessions pay the base 791;
                           # the sentence is conditional (B1: never lie to a legal path).
                           # Raised 791→868: 5/7 cross-seat frame-verified idle cases were
                           # conclusions-in-chat-not-in-file.
BUDGET_GUARD_TOTAL=12860   # all injected text across the three guards (raised 7439→7771 on 2026-08-17:
                           # rule 10b gate;commit weld DENY, +332 B — deliberate, weighed.
                           # Raised 7771→8334 on 2026-08-20: rule (11) bare-codex DENY, +563 B.
                           # Bought: the only route to the review seat's sandbox tier was a
                           # hand-rolled `codex exec --sandbox read-only`, which cost one 10h21m
                           # stdin-EOF hang and one silently-empty round. The message carries the
                           # replacement flag AND the four pass-through spellings, because the
                           # denial lands on a seat that just lost its only known path. Could not
                           # come from cutting elsewhere: every other rule's text is already at or
                           # under its own field-earned minimum, and this one is well under the
                           # per-message ceiling (which did NOT move).
                           # Raised 8334→9313 on 2026-08-20, TWO items, both weighed:
                           #  +590 B rule (12) typed-command-piped DENY. Bought: `agentctl
                           #    steer|watch|start|stop` and `gh …--watch` carry their verdict in
                           #    the exit code, which a pipeline overwrites with the pager's 0.
                           #    The text must name the masked rc AND the file-first replacement,
                           #    because the denied seat was mid-supervision when it landed.
                           #  +389 B rule (13) brief-wording advisory, joining rule (3)'s
                           #    reminder in ONE hook response (204 → 593 B for that sink). It is
                           #    the only branch that ever pays: a clean brief emits nothing.
                           #    Could not come from cutting elsewhere — the advisory has to name
                           #    the matched phrases, the neutral-wording fix AND its own
                           #    non-completeness, or it reads as a verdict instead of a hint.
                           # Raised 9313→11660 on 2026-08-28, and the census now covers a THIRD
                           # file (cto-guard-edit.py — a sink in a file not listed here is
                           # unweighed, which is why the new guard joined on arrival). Three
                           # items, all weighed:
                           #  +939 B cto-guard-bash rules (14)+(15): the two `agentctl start`
                           #    preconditions (dirty worktree / unharvested BLOCKED.md). Each
                           #    denial has to name the seat cwd it judged and the recovery that
                           #    is NOT the other rule's (commit the seed vs harvest the gate),
                           #    because the two failures look identical from the seat's side.
                           #  +1408 B / 5 sinks for cto-guard-edit.py: one DENY (735 B, under the
                           #    unmoved per-message ceiling) plus THREE degrade WARNs. The WARNs
                           #    are the price of ALLOW+WARN over checker-error: a gate that
                           #    cannot answer must say so, or its silence reads as approval.
                           #  Could not come from cutting elsewhere: the E1 denial lands on a
                           #    seat whose entire lane discipline is at stake and must carry the
                           #    dispatch replacement AND the licensed direct-write path.
                           # Raised 11660→11865 on 2026-08-28 (R2 fix round), ONE item weighed:
                           #  +149 B rule (14)'s instrument warning. Bought: `_git_porcelain`
                           #    folded "git missing / timed out" into the same silent allow as
                           #    "not a git work tree", so an UNMEASURED dispatch precondition
                           #    read exactly like a met one (cold review §4.2). It is the
                           #    shortest of the three warns by construction — it joins (3)'s
                           #    reminder and (13)'s advisory in ONE response, and that assembly
                           #    is what the per-message ceiling below weighs.
                           #  The remaining +56 B is net churn inside existing sinks: gate E1's
                           #    denial and degrade warn now name the WRITE TARGET they judged
                           #    (§1.1) and (15)'s `rm` fix quotes the whole path (§5.1).
                           # Raised 11865→12016 on 2026-08-28 (R3 fix round), ONE item weighed:
                           #  +151 B rule (15)'s instrument warning, the twin of (14)'s above.
                           #    Bought: `os.path.exists` answers False for "no BLOCKED.md" AND
                           #    for "could not stat it", so a seat the guard was not allowed to
                           #    look at read exactly like a harvested one and the dispatch went
                           #    through silently green (verify R3 §4.3). Could not come from
                           #    cutting elsewhere: it must name the PATH it failed on (the
                           #    orchestrator has to go look at that one) and say the
                           #    precondition went unchecked, or it reads as a passed check.
                           # Raised 12016→12842 on 2026-09-01 (效率强制层批), TWO items weighed:
                           #  +547 B rule (17)'s unbudgeted-review DENY. Bought: `--max-rounds`
                           #    is the ONLY round ceiling the runtime enforces, so a review seat
                           #    started without it has none anywhere and the round count becomes
                           #    a negotiation (downstream DEV-tier batch ran 3). The text must
                           #    carry the flag PAIR (`--workflow review-loop --max-rounds N` is
                           #    refused half-spelled), the default N, AND the two pass-throughs,
                           #    or the denied seat's next attempt is refused by the lane instead.
                           #  +279 B rule (16)'s babysit-round WARN, joining (3)/(13)/(14)/(15)
                           #    in the SAME assembled response. It is the only branch that ever
                           #    pays: under four re-hangs a day it emits nothing at all. Could
                           #    not come from cutting elsewhere — it has to name the session,
                           #    the count, and the ONE alternative (read the gauge / go to a
                           #    long-interval wakeup), or it is a nag without a next action.
                           # Raised 12842→12860 on 2026-09-01 (F1/F2 fix round), ONE item, +18 B:
                           #  rule (16)'s floor suffix now names BOTH causes. It said "计数未落盘"
                           #  only, but the floor flag is persisted since F2, so the same suffix
                           #  is now also printed by a process whose write SUCCEEDED — for a day
                           #  whose ledger was corrupt earlier. A suffix that names one cause
                           #  while the other is live reads as a wrong diagnosis, not a shorter one.
BUDGET_GUARD_SINGLE=1190   # the longest single message a worker can be handed at once. Raised
                           # 754→893 on 2026-08-28: the worst case is now the (3)+(13)+(14)+(15)
                           # assembled response, i.e. every instrument in this dispatch failing
                           # at once, and it is +151 B — exactly (15)'s new warn, nothing else.
                           # Rule (14)'s warn was cut to 149 B for the OLD 754 ceiling and stays
                           # cut; (15)'s is held to the same shape. The recovery both drop
                           # (which errno / which git failure) is one `ls -ld` or `git status`
                           # away, and that assembly is only reachable when the seat is already
                           # standing in a broken environment.
                           # Raised 893→1172 on 2026-09-01: the worst case is the same assembled
                           # response with rule (16)'s counter joined to it, and it is +279 B —
                           # exactly that warn, nothing else. Reachable only when every dispatch
                           # instrument fails at once AND the same session is on its fourth
                           # re-hang today; the counter alone (its normal shape) is 279 B.
                           # Raised 1172→1190 on 2026-09-01: +18 B, the same widened floor
                           # suffix and nothing else — the assembly is unchanged.
BUDGET_GUARD_COUNT=31      # sink count: a drop means extraction broke or a sink moved out of
                           # view. 21→23 on 2026-08-20: +1 real sink (rule 12) and +1 the meter
                           # had been blind to (see `resolve` below). 23→30 on 2026-08-28:
                           # +2 (rules 14/15) and +5 (the whole new guard). Pinned to the
                           # measured number, never carrying untracked slack.

echo "== injected-context budget =="

# ---- 1. footer: capture what append_footer actually writes ------------------------------------
# Invoking the real function beats reading the literals: the format string, interpolated paths and
# blank lines are all part of what the engine receives. wc -c is bytes, matching the guard side.
fn="$(mktemp)"; out="$(mktemp)"
sed -n '/^append_footer()/,/^}/p' "$AGENTCTL_SRC" > "$fn"
printf ': > "$1"\nappend_footer "$1" "/abs/worktree" "/abs/run/stamp.txt" "out-*.md"\n' >> "$fn"
bash "$fn" "$out"
footer_bytes="$(wc -c < "$out" | tr -d ' ')"
rm -f "$fn" "$out"

if [ "$footer_bytes" -le "$BUDGET_FOOTER" ]; then
  _record "footer within per-session budget ($footer_bytes <= $BUDGET_FOOTER)" 1
else
  _record "footer within per-session budget" 0 \
    "footer grew to $footer_bytes bytes (budget $BUDGET_FOOTER, +$((footer_bytes - BUDGET_FOOTER))); every session pays this — cut something or raise the baseline deliberately"
fi

if [ "$footer_bytes" -gt 100 ]; then
  _record "footer meter reads a non-trivial capture" 1
else
  _record "footer meter reads a non-trivial capture" 0 \
    "captured only $footer_bytes bytes — the extraction broke; this is not a shrunken footer"
fi

# ---- 2. guard sinks -----------------------------------------------------------------------------
# The extractor lives in its OWN file so the suite can run it twice: once for real, once under the
# review's targeted mutation (see the recall probe below). An oracle that cannot be shown to go
# red is not an oracle — R1 M6 proved exactly that against the previous inline copy.
EXTRACT="$(mktemp)"; trap 'rm -f "$EXTRACT"' EXIT
cat > "$EXTRACT" <<'PY'
import ast, os, sys


# Fields whose value is handed to the agent verbatim by the harness.
SINK_KEYS = {"additionalContext", "permissionDecisionReason", "reason"}
# Messages we KNOW are injected, used to calibrate the extractor itself (see header). The set
# covers every sink shape in play AND every local inside the assembled one: a bare local handed
# to a sink, and BOTH locals of the payload assembled at rule (3)'s sink. Two needles were not
# enough — a resolve() that dropped only rule 13's local still recalled the reminder and stayed
# green while 388 bytes went unweighed (review R1 M6). The fourth pins the THIRD file into the
# census: drop cto-guard-edit.py from the invocation below and recall goes 0 instead of the
# budget quietly reporting a smaller, greener number.
KNOWN_POSITIVE = ("[browser/long subagent launched]",          # bare Name sink (PostToolUse)
                  "REMINDER (cto-guard): session",             # assembled sink, first local
                  "wording that has tripped",                  # assembled sink, rule 13's local
                  "编排位直写源码面")                            # cto-guard-edit's E1 denial
# Mutation switch for the recall probe below: comma-separated local names resolve() must ignore.
# Test-only; the real invocation passes nothing.
IGNORE = {n for n in os.environ.get("GUARD_METER_IGNORE", "").split(",") if n}

def literal_text(node):
    """Literal string text under one expression, counted once.

    ast.walk visits a JoinedStr and its Constant children, so adding both would double-count;
    collecting only Constants and letting the walk reach them through the JoinedStr avoids that.
    """
    return "".join(n.value for n in ast.walk(node)
                   if isinstance(n, ast.Constant) and isinstance(n.value, str))

def collect(path):
    tree = ast.parse(open(path).read())
    # The long messages are built as `msg = ("..." "...")` and then handed to a sink, so a literal
    # bound to a plain local name has to be resolvable or the biggest payloads read as zero.
    varmap = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            t = literal_text(n.value)
            if len(t) > 15:
                varmap[n.targets[0].id] = t

    def resolve(node):
        """Literal text at this sink, plus every local whose literal value flows into it.

        Resolving only a bare Name weighed an assembled payload — `"\\n".join(t for t in
        (reminder, note) if t)` — as ZERO bytes, so a rule could inject a page of text with
        this gate green (caught 2026-08-20 while wiring rule 13 onto rule 3's channel).
        """
        parts = [literal_text(node)]
        for n in ast.walk(node):
            if isinstance(n, ast.Name) and n.id in varmap and n.id not in IGNORE:
                parts.append(varmap[n.id])
        return "".join(parts)

    msgs = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        if (isinstance(f, ast.Attribute) and f.attr == "write"
                and isinstance(f.value, ast.Attribute) and f.value.attr == "stderr"):
            for a in node.args:
                t = resolve(a)
                if len(t) > 15:
                    msgs.append(t)
        if isinstance(f, ast.Attribute) and f.attr == "dumps":
            for a in node.args:
                for n in ast.walk(a):
                    if isinstance(n, ast.Dict):
                        for k, v in zip(n.keys, n.values):
                            if isinstance(k, ast.Constant) and k.value in SINK_KEYS:
                                t = resolve(v)
                                if len(t) > 15:
                                    msgs.append(t)
    return msgs

total = longest = count = 0
seen = []
for path in sys.argv[1:]:
    for m in collect(path):
        b = len(m.encode("utf-8"))
        total += b; count += 1; longest = max(longest, b)
        seen.append(m)
recall = int(all(any(k in m for m in seen) for k in KNOWN_POSITIVE))
print(total, longest, count, recall)
PY

read -r guard_total guard_single guard_count guard_recall <<EOF
$(python3 "$EXTRACT" "$GUARD_BASH" "$GUARD_AGENT" "$GUARD_EDIT")
EOF

# RECALL PROBE (review R1 M6, the reviewer's mutation run as a standing negative control): a
# resolve() that ignores ONLY rule 13's local. Before the third known positive this mutation was
# invisible — total silently fell 9313→8925 while count stayed 23 and recall stayed 1, i.e. the
# gate reported green for 388 unweighed bytes. The probe asserts the oracle now BITES.
read -r mut_total _ mut_count mut_recall <<EOF
$(GUARD_METER_IGNORE=note13 python3 "$EXTRACT" "$GUARD_BASH" "$GUARD_AGENT" "$GUARD_EDIT")
EOF
if [ "$mut_recall" = "0" ] && [ "$mut_total" -lt "$guard_total" ]; then
  _record "recall probe: dropping ONLY rule 13's local goes red ($mut_total < $guard_total bytes)" 1
else
  _record "recall probe: dropping ONLY rule 13's local goes red" 0 \
    "mutated run reported recall=$mut_recall total=$mut_total count=$mut_count — the known-positive set does not discriminate rule 13's message, so its bytes could go unweighed"
fi

if [ "$guard_total" -le "$BUDGET_GUARD_TOTAL" ]; then
  _record "guard injected text within budget ($guard_total <= $BUDGET_GUARD_TOTAL)" 1
else
  _record "guard injected text within budget" 0 \
    "guard messages total $guard_total bytes (budget $BUDGET_GUARD_TOTAL, +$((guard_total - BUDGET_GUARD_TOTAL)))"
fi

# The per-message ceiling bites harder than the total: a worker meets exactly ONE of these, at the
# moment it is blocked, and length there competes with the fix line it needs.
if [ "$guard_single" -le "$BUDGET_GUARD_SINGLE" ]; then
  _record "no single guard message exceeds the ratchet ($guard_single <= $BUDGET_GUARD_SINGLE)" 1
else
  _record "no single guard message exceeds the ratchet" 0 \
    "longest guard message is $guard_single bytes (current-maximum ratchet $BUDGET_GUARD_SINGLE)"
fi

if [ "$guard_count" -ge "$BUDGET_GUARD_COUNT" ]; then
  _record "guard meter still sees every sink ($guard_count >= $BUDGET_GUARD_COUNT)" 1
else
  _record "guard meter still sees every sink" 0 \
    "only $guard_count sinks matched (expected >= $BUDGET_GUARD_COUNT) — either extraction broke or a sink moved out of view; a genuinely deleted rule means editing this baseline"
fi

# Known-positive recall: an enumerating meter that quietly stops matching reports a smaller number,
# which reads exactly like success. This message is injected today; if the extractor cannot find it,
# no number above can be trusted.
if [ "$guard_recall" = "1" ]; then
  _record "meter recalls a known injected message" 1
else
  _record "meter recalls a known injected message" 0 \
    "the PostToolUse additionalContext message is no longer found — the extractor is blind to a sink we know exists, so every byte count above is unproven"
fi

summary
