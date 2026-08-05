#!/usr/bin/env python3
"""Forge a terminal RECORD carrying arbitrary receipt fields and an arbitrary identity stamp —
the hostile/legacy producer workstream 2 has to fence out (a receipt from a prior attempt, a
receipt whose deliverables claim a hash nobody took, a pre-receipt legacy marker).

Deliberately does NOT import identity.py: a receipt forged BY the module under test would
prove nothing about foreign records. This writes the file the way any other process on the box
could — tmp + rename, no identity logic, no hashing.

  forge_receipt.py PATH --attempt ID --incarnation STR [--seq N] [--rc N]
                        [--deliverable PATH] [--sha256 HEX] [--size N]
                        [--phase delivered] [--reason ENUM] [--git-head SHA|null]
                        [--no-identity]
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
parser.add_argument("--session", help="top-level sessionId (omitted by default — the "
                                      "reviewer's BLOCKER fixture leaves it out)")
parser.add_argument("--seq", type=int, default=1)
parser.add_argument("--rc", type=int, default=0)
parser.add_argument("--deliverable", default="")
parser.add_argument("--sha256")
parser.add_argument("--size", type=int, default=0)
parser.add_argument("--size-raw", dest="size_raw", help="JSON literal for size (mistyped probes)")
parser.add_argument("--phase")
parser.add_argument("--reason", default="OK")
parser.add_argument("--git-head", dest="git_head", default="null")
parser.add_argument("--completed-at", dest="completed_at",
                    help="arbitrary completedAt (RFC3339 probes)")
parser.add_argument("--engine-outcome", dest="engine_outcome", default="completed")
parser.add_argument("--no-engine-outcome", dest="no_engine_outcome", action="store_true")
parser.add_argument("--schema-version", dest="schema_version", type=int, default=1)
parser.add_argument("--deliverables-raw", dest="deliverables_raw",
                    help="JSON literal for the whole deliverables value (shape probes)")
parser.add_argument("--no-identity", action="store_true")
parser.add_argument("--top-session", help="top-level sessionId ONLY — lets a probe forge a record "
                                          "whose receipt view disagrees with its own fenced stamp")
args = parser.parse_args()

record = {"schemaVersion": args.schema_version,
          "completedAt": (args.completed_at if args.completed_at is not None
                          else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
          "rc": args.rc,
          "deliverable": args.deliverable,
          "reason": args.reason}
if args.attempt is not None:
    record["attemptId"] = args.attempt
if args.incarnation is not None:
    record["processIncarnation"] = args.incarnation
if args.session is not None:
    record["sessionId"] = args.session
if args.top_session is not None:
    record["sessionId"] = args.top_session
if args.phase:
    record["phase"] = args.phase
    if not args.no_engine_outcome:
        record["engineOutcome"] = args.engine_outcome
    record["gitHead"] = None if args.git_head == "null" else args.git_head
    if args.deliverables_raw is not None:
        record["deliverables"] = json.loads(args.deliverables_raw)
    elif args.sha256:
        record["deliverables"] = [{
            "path": args.deliverable,
            "sha256": args.sha256,
            "size": json.loads(args.size_raw) if args.size_raw else args.size}]
if not args.no_identity:
    stamp = {"seq": args.seq}
    if args.attempt is not None:
        stamp["attemptId"] = args.attempt
    if args.incarnation is not None:
        stamp["processIncarnation"] = args.incarnation
    if args.session is not None:
        stamp["sessionId"] = args.session
    record["identity"] = stamp

tmp = args.path + ".forge"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(record) + "\n")
os.replace(tmp, args.path)
print(args.path)
