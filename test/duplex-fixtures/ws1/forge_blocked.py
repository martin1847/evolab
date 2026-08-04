#!/usr/bin/env python3
"""Forge a BLOCKED.md carrying an ARBITRARY identity stamp (see forge_marker.py for why the
identity module is deliberately not imported).

  forge_blocked.py PATH [--attempt ID] [--incarnation STR] [--no-stamp]

The stamp line is the one agentctl's headless footer tells the worker to copy from
<run>/<session>.identity.d/blocked-stamp.txt; --no-stamp reproduces a legacy blocker, which
stays fenced by round freshness alone.
"""
from __future__ import annotations

import argparse

parser = argparse.ArgumentParser()
parser.add_argument("path")
parser.add_argument("--attempt", default="")
parser.add_argument("--incarnation", default="")
parser.add_argument("--no-stamp", action="store_true")
args = parser.parse_args()

body = "# BLOCKED\n\nneed a decision on the schema before continuing.\n"
if not args.no_stamp:
    body += "\n<!-- agentctl-identity attempt={} incarnation={} seq=1 -->\n".format(
        args.attempt, args.incarnation)
with open(args.path, "w", encoding="utf-8") as fh:
    fh.write(body)
print(args.path)
