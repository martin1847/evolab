#!/usr/bin/env bash
# statusline.test.sh — templates/statusline.py contract: renders only what the payload
# provides (no guessed numbers), fail-soft on absent fields, never crashes on bad input.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SL="../templates/statusline.py"
run() { printf '%s' "$1" | python3 "$SL" 2>&1; }

echo "== statusline =="

# full payload: model | dir | ctx% (+abs) | cache% | session duration
out="$(run '{"model":{"display_name":"M"},"workspace":{"current_dir":"/a/repo"},
 "context_window":{"context_window_size":200000,"current_usage":{"input_tokens":5000,
 "cache_creation_input_tokens":15000,"cache_read_input_tokens":80000}},
 "cost":{"total_duration_ms":5045000}}')"
chk_contains "model shown" "M" "$out"
chk_contains "dir basename shown" "repo" "$out"
chk_contains "ctx pct from payload" "ctx 50%" "$out"
chk_contains "ctx absolute part" "(100k/200k)" "$out"
chk_contains "cache hit pct" "cache 80%" "$out"
chk_contains "duration h-form" "1h24m" "$out"

# duration tiers
chk_contains "duration s-form" "42s" "$(run '{"cost":{"total_duration_ms":42000}}')"
chk_contains "duration m-form" "2m"  "$(run '{"cost":{"total_duration_ms":125000}}')"

# absent context/cost -> ctx n/a, no duration segment, no crash
out="$(run '{"model":{"display_name":"M"},"workspace":{"current_dir":"/x/y"}}')"; rc=$?
chk_eq "absent fields exit 0" 0 "$rc"
chk_contains "absent ctx -> n/a" "ctx n/a" "$out"
chk_not_contains "absent cost -> no duration" "0s" "$out"

# garbage input -> graceful line, exit 0
out="$(run 'garbage')"; rc=$?
chk_eq "bad input exit 0" 0 "$rc"
chk_contains "bad input message" "bad input" "$out"

summary
