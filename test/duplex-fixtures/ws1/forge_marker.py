#!/usr/bin/env python3
"""Forge a terminal marker carrying an ARBITRARY identity stamp — the hostile/legacy
producer workstream 1 has to fence out (a prior attempt, a recycled pid, a stampless
legacy artifact).

Deliberately does NOT import identity.py: evidence forged BY the module under test would
prove nothing about foreign artifacts. This writes the file the same way any other process
on the box could — tmp + rename, no identity logic.

  forge_marker.py PATH [--attempt ID] [--incarnation STR] [--seq N] [--rc N]
                       [--seq-raw JSON] [--rc-raw JSON] [--no-identity]

Omitting --attempt / --incarnation is how the "stamp missing a required field" probe is
constructed; --seq-raw / --rc-raw plant a MISTYPED value (`"7"`, `false`) for the schema
probes; --no-identity produces a pre-identity legacy marker.
"""
from __future__ import annotations

import argparse
import json
import os
import time

parser = argparse.ArgumentParser()
parser.add_argument("path")
parser.add_argument("--attempt")
parser.add_argument("--incarnation")
parser.add_argument("--seq", type=int, default=1)
parser.add_argument("--rc", type=int, default=0)
parser.add_argument("--rc-raw", help="JSON literal for rc (mistyped-rc probes)")
parser.add_argument("--seq-raw", help="JSON literal for seq (mistyped-sequence probes)")
parser.add_argument("--no-seq", action="store_true", help="omit seq entirely")
parser.add_argument("--no-identity", action="store_true")
args = parser.parse_args()

marker = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
          "rc": json.loads(args.rc_raw) if args.rc_raw else args.rc,
          "deliverable": ""}
if not args.no_identity:
    stamp: dict = {}
    if not args.no_seq:
        stamp["seq"] = json.loads(args.seq_raw) if args.seq_raw else args.seq
    if args.attempt is not None:
        stamp["attemptId"] = args.attempt
    if args.incarnation is not None:
        stamp["processIncarnation"] = args.incarnation
    marker["identity"] = stamp

tmp = args.path + ".forge"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(marker) + "\n")
os.replace(tmp, args.path)
print(args.path)
