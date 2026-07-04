#!/usr/bin/env python3
# Minimal statusline: model | dir | context-used % | cache-hit %.
# The % comes ONLY from the context_window payload Claude Code pipes in
# (the same source as /context). No transcript parsing, no guessed window
# size — if the field is absent we print "ctx n/a" instead of a wrong number.
import json
import os
import sys


def cache_hit_pct(cw):
    cu = cw.get("current_usage")
    if not isinstance(cu, dict):
        return None
    read = cu.get("cache_read_input_tokens") or 0
    total = (cu.get("input_tokens") or 0) + (cu.get("cache_creation_input_tokens") or 0) + read
    return read / total * 100 if total > 0 else None


def fmt_tokens(n):
    if n >= 1_000_000:
        v = n / 1_000_000
        return f"{v:.1f}M" if v < 10 else f"{v:.0f}M"
    if n >= 1000:
        return f"{n / 1000:.0f}k"
    return str(n)


def context_usage(cw):
    """Return (pct, used_tokens, window_size); any element may be None."""
    size = cw.get("context_window_size")
    size = size if isinstance(size, (int, float)) and size > 0 else None
    cu = cw.get("current_usage")
    used = None
    if isinstance(cu, (int, float)):
        used = cu
    elif isinstance(cu, dict):
        used = sum(cu.get(k) or 0 for k in (
            "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    pct = cw.get("used_percentage")
    if not isinstance(pct, (int, float)):
        pct = used / size * 100 if used is not None and size else None
    if used is None and pct is not None and size:
        used = pct / 100 * size
    return pct, used, size


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        print("statusline: bad input")
        return
    model = (d.get("model") or {}).get("display_name") or ""
    cwd = os.path.basename((d.get("workspace") or {}).get("current_dir") or "")
    cw = d.get("context_window") or {}
    pct, used, size = context_usage(cw)
    if pct is None:
        ctx = "ctx n/a"
    else:
        color = "\033[31m" if pct >= 90 else "\033[33m" if pct >= 70 else "\033[32m"
        abs_part = f" ({fmt_tokens(used)}/{fmt_tokens(size)})" if used is not None and size else ""
        ctx = f"{color}ctx {pct:.0f}%{abs_part}\033[0m"
    hit = cache_hit_pct(cw)
    cache = f"\033[36mcache {hit:.0f}%\033[0m" if hit is not None else ""
    parts = [x for x in (model, cwd, ctx, cache) if x]
    print("  \033[90m|\033[0m  ".join(parts))


if __name__ == "__main__":
    main()
