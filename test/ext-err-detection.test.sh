#!/usr/bin/env bash
# Validates the STALLED-EXTERNAL (exit 5) detection PREDICATE of `watch`:
#   tail -15 | grep -qiE "$EXT_ERR_RE".
#
# Scope: the regex predicate ONLY. The live path adds two more gates the predicate
# can't capture — state=WORKING + N consecutive polls — which narrow but do NOT
# close the false-positive surface this test documents.
#
# Design: the pattern is EXTRACTED from the real script at runtime (not copied), so a
# regex edit that drifts from what ships is caught here.
# Run via test/run.sh, or standalone: bash test/ext-err-detection.test.sh
set -u
AW_DIR="$(cd "$(dirname "$0")/.." && pwd)/skills/cto-orchestration/references/agent-watch"
WATCH="$AW_DIR/watch"

extract_re() { grep '^EXT_ERR_RE=' "$1" | sed 's/^EXT_ERR_RE="${AGENT_WATCH_EXT_ERR_RE:-//; s/}"$//'; }
RE="$(extract_re "$WATCH")"

pass=0; fail=0
chk() { # $1 expect(Y/N)  $2 label  $3 screen-text
  if printf '%s\n' "$3" | tail -15 | grep -qiE "$RE"; then got=Y; else got=N; fi
  if [ "$got" = "$1" ]; then echo "  ok   [$2] expect=$1"; pass=$((pass+1))
  else echo "  FAIL [$2] expect=$1 got=$got"; fail=$((fail+1)); fi
}

echo "EXT_ERR_RE (from watch): $RE"

echo "-- true positives (provider-error chrome, MUST match) --"
chk Y "anthropic-529-overloaded" '> retrying (3/10)
529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
chk Y "rate-limit-429"          'rate_limit_error: 429 Too Many Requests, retry-after 12s'
chk Y "service-unavailable-503" 'Error: 503 service unavailable: upstream overloaded'
chk Y "openai-insufficient-quota" 'openai error: insufficient_quota - check plan'
chk Y "stream-error"            'stream error: connection reset, retrying...'

echo "-- true negatives (normal work, must NOT match) --"
chk N "normal-edit"        'Edited src/foo.ts (+12 -3)
Running tests... 42 passed'
chk N "agent-reasoning"    'The function throws an error when input is null. Let me add a guard and a regression test.'
chk N "build-log"          'tsc --noEmit ... 0 errors
bun test ... 88 pass 0 fail'

# KNOWN FALSE POSITIVES (documented, not yet fixable by regex alone — the tokens are
# identical to real chrome). These assert the CURRENT behaviour: the predicate DOES
# match. The human verify-the-tail-before-kill step (SKILL §1.4) is the real safety net.
echo "-- known false positives (predicate matches; verify-before-kill is the mitigation) --"
chk Y "fp-code-writes-429" 'Editing retry.ts:
  if (res.status === 429) throw new Error("Too Many Requests");
  // back off on 503 service unavailable'
chk Y "fp-code-defines-regex" 'const RETRY_RE = /overloaded|rate_limit_error|service unavailable/i;'
chk Y "fp-reads-prod-log"  'tail prod.log:
  ERROR upstream overloaded_error count=37
  WARN  rate_limit_error on /v1/messages'

echo "-- $pass passed, $fail failed --"
[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
