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
BUDGET_GUARD_TOTAL=8334    # all injected text across both guards (raised 7439→7771 on 2026-08-17:
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
BUDGET_GUARD_SINGLE=754    # the longest single message a worker can be handed at once
BUDGET_GUARD_COUNT=21      # sink count: a drop means extraction broke or a sink moved out of view

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
read -r guard_total guard_single guard_count guard_recall <<EOF
$(python3 - "$GUARD_BASH" "$GUARD_AGENT" <<'PY'
import ast, sys

# Fields whose value is handed to the agent verbatim by the harness.
SINK_KEYS = {"additionalContext", "permissionDecisionReason", "reason"}
# A message we KNOW is injected, used to calibrate the extractor itself (see header).
KNOWN_POSITIVE = "[browser/long subagent launched]"

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
        return varmap.get(node.id, "") if isinstance(node, ast.Name) else literal_text(node)

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
recall = 0
for path in sys.argv[1:]:
    for m in collect(path):
        b = len(m.encode("utf-8"))
        total += b; count += 1; longest = max(longest, b)
        if KNOWN_POSITIVE in m:
            recall = 1
print(total, longest, count, recall)
PY
)
EOF

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
