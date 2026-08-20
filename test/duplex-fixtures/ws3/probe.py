#!/usr/bin/env python3
"""WS3 introspection probe — reads the REAL duplexctl module, never a copy of the table.

Structural facts only. Whether a provider actually PERFORMS what it declares is not decidable
from here and is proven by the behaviour battery (§C8 of agentctl-capabilities.test.sh) against
the hermetic fake engines — cold review R1 changed three real behaviours (codex handshake
resume method, omp pending-question projection, the launch branch name) and every registry
comparison stayed green.

Every lookup is TOLERANT: a missing provider / capability / field prints an empty line and
exits 0, so a mutation reds through the suite's own damage assertion instead of a KeyError
traceback (cold review R1, MAJOR). `drift` is the one op that exits non-zero, and only on a
finding it prints.

  providers                  providers with a capability contract
  routeproviders             providers with a route registry
  projectorproviders         providers the state projector can serve
  specproviders              providers in the shell-consumable launch spec
  routes <engine>            every route id with an executable branch
  capkeys <engine>           the capability vocabulary declared for one provider
  map <engine>               <capability>=<state> lines
  cell <engine> <cap> <f>    one field of one cell
  spec <engine> <field>      one field of the shell launch spec row
  wire <engine> <verb>       "declared=<route> emitted=<what the branch really sends>"
  drift                      structural table<->registry gate (exit 1 = drift)
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
DUPLEXCTL = os.environ.get(
    "WS3_DUPLEXCTL",
    os.path.join(HERE, "..", "..", "..", "skills", "cto-orchestration", "references",
                 "agentctl", "duplexctl.py"))

_spec = importlib.util.spec_from_file_location("duplexctl_under_test",
                                               os.path.abspath(DUPLEXCTL))
dx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dx)

SPEC_FIELDS = ("name", "bin_env", "bin", "argv", "extra_argv", "resume_flag",
               "review_sandbox")


def cells(engine: str) -> dict:
    return dx.CAPABILITIES.get(engine) or {}


def cell(engine: str, name: str) -> dict:
    return cells(engine).get(name) or {}


def spec_row(engine: str) -> dict:
    for row in dx.provider_spec_rows():
        parts = row.split("|")
        if parts and parts[0] == engine:
            return dict(zip(SPEC_FIELDS, parts))
    return {}


def wire(engine: str, verb: str) -> str:
    """The declared route id vs the wire name the executable branch REALLY emits.

    omp/claude go through the frame builder; codex is driven for real with the JSON-RPC
    transport stubbed, so the recorded methods are the ones the branch would have sent. This
    proves the route id is not a decoration — it does NOT prove the branch is wired into the
    live lane, which is what the behaviour battery is for."""
    route = (cell(engine, dx.VERB_CAPABILITY.get(verb, "")) or {}).get("route", "")
    # a branch that cannot even be invoked is DAMAGE the suite must report as a wrong value,
    # never as a harness traceback (cold review R1, MAJOR): every failure mode below becomes
    # part of the `emitted=` string.
    if engine in ("omp", "claude"):
        try:
            emitted = json.loads(dx.build_frame(engine, verb, "hello", "req-1")).get("type")
        except SystemExit:
            emitted = "<refused>"
        except Exception as exc:                      # noqa: BLE001 — reported, not raised
            emitted = f"<branch-error:{type(exc).__name__}>"
        return f"declared={route} emitted={emitted}"
    handler = (dx.ROUTES.get(engine) or {}).get(route)
    if handler is None:
        return f"declared={route} emitted=<no-branch>"
    sent: list[str] = []

    def fake_request(sess, method, params, timeout=20.0, on_ready=None):
        sent.append(method)
        return {"result": {}}

    dx.codex_request = fake_request
    dx.wait_for = lambda *a, **k: {"method": "turn/completed"}
    ctx = {"thread": "T1", "text": "hello", "verb": verb, "route": route,
           "active": None if verb == "steer" else "t1",
           "on_ready": lambda: None, "commit": lambda kind: None}
    try:
        handler(types.SimpleNamespace(events="/nonexistent/events"), ctx)
    except SystemExit:
        return f"declared={route} emitted=<refused>"
    except Exception as exc:                          # noqa: BLE001 — reported, not raised
        return f"declared={route} emitted=<branch-error:{type(exc).__name__}>"
    return f"declared={route} emitted={'+'.join(sent)}"


def drift() -> int:
    """Structural consistency, both directions. Any finding is printed and reds the gate."""
    bad: list[str] = []
    declared = set(dx.CAPABILITIES)
    for label, other in (("routes", set(dx.ROUTES)),
                         ("projectors", set(dx.PROJECTORS)),
                         ("launch spec", {r.split("|")[0] for r in dx.provider_spec_rows()})):
        if declared != other:
            bad.append(f"providers with a contract {sorted(declared)} != providers with "
                       f"{label} {sorted(other)}")
    missing_def = set(dx.CAPABILITY_ORDER) - set(dx.CAPABILITY_DEFINITIONS)
    if missing_def:
        bad.append(f"capabilities with no written definition: {sorted(missing_def)}")
    for engine in sorted(declared):
        caps = dx.CAPABILITIES[engine]
        record = dx.PROVIDERS[engine]
        if set(caps) != set(dx.CAPABILITY_ORDER):
            bad.append(f"{engine}: capability keys {sorted(caps)} != the closed vocabulary "
                       f"{sorted(dx.CAPABILITY_ORDER)}")
        used = set()
        for name in sorted(caps):
            c = caps[name]
            state, route, surface = c["state"], c["route"], c["surface"]
            if state not in dx.CAPABILITY_STATES:
                bad.append(f"{engine}.{name}: state '{state}' is outside the closed enum")
            if state == dx.UNSUPPORTED:
                if route or surface:
                    bad.append(f"{engine}.{name}: unsupported but claims a realization "
                               f"(route='{route}' surface='{surface}')")
                if not c["refusal"]:
                    bad.append(f"{engine}.{name}: unsupported with no refusal naming a path")
            else:
                if bool(route) == bool(surface):
                    bad.append(f"{engine}.{name}: state '{state}' needs exactly one of route "
                               f"/ surface (route='{route}' surface='{surface}')")
                elif route:
                    if route not in (dx.ROUTES.get(engine) or {}):
                        bad.append(f"{engine}.{name}: route '{route}' has no executable branch")
                    elif not callable(dx.ROUTES[engine][route]):
                        bad.append(f"{engine}.{name}: route '{route}' is not executable")
                    else:
                        used.add(route)
                elif surface not in dx.CAPABILITY_SURFACES:
                    bad.append(f"{engine}.{name}: surface '{surface}' is not a known "
                               f"realization {list(dx.CAPABILITY_SURFACES)}")
                elif surface == dx.SURFACE_START_ARGV and not record["extra_argv"]:
                    bad.append(f"{engine}.{name}: claims the start-argv surface but the "
                               "provider does not forward extra start args")
            # published-note policy: exactly degraded + unsupported carry one
            if state in (dx.DEGRADED, dx.UNSUPPORTED) and not c["note"]:
                bad.append(f"{engine}.{name}: {state} without a published note")
            if state in (dx.SUPPORTED, dx.EXPERIMENTAL) and c["note"]:
                bad.append(f"{engine}.{name}: {state} must publish no note, has one")
            if c["start_flag"] and not route:
                bad.append(f"{engine}.{name}: start flag '{c['start_flag']}' on a cell with "
                           "no wire route")
            if c["fallback"]:
                if state != dx.DEGRADED:
                    bad.append(f"{engine}.{name}: fallback on a non-degraded state")
                target = dx.VERB_CAPABILITY.get(c["fallback"])
                if target is None:
                    bad.append(f"{engine}.{name}: fallback verb '{c['fallback']}' is not a "
                               "capability verb")
                elif caps[target]["state"] == dx.UNSUPPORTED:
                    bad.append(f"{engine}.{name}: falls back to unsupported '{target}'")
        orphans = set(dx.ROUTES.get(engine) or {}) - used
        if orphans:
            bad.append(f"{engine}: routes with no declared capability {sorted(orphans)}")
    for line in bad:
        print(f"DRIFT: {line}")
    if not bad:
        print("DRIFT: none")
    return 1 if bad else 0


def main() -> int:
    op, rest = sys.argv[1], sys.argv[2:]

    def arg(i: int) -> str:
        return rest[i] if len(rest) > i else ""

    if op == "providers":
        print("\n".join(sorted(dx.CAPABILITIES)))
    elif op == "routeproviders":
        print("\n".join(sorted(dx.ROUTES)))
    elif op == "projectorproviders":
        print("\n".join(sorted(dx.PROJECTORS)))
    elif op == "specproviders":
        print("\n".join(sorted(r.split("|")[0] for r in dx.provider_spec_rows())))
    elif op == "routes":
        print("\n".join(sorted(dx.ROUTES.get(arg(0)) or {})))
    elif op == "capkeys":
        print("\n".join(sorted(cells(arg(0)))))
    elif op == "map":
        print("\n".join(f"{n}={cell(arg(0), n).get('state', '')}"
                        for n in dx.CAPABILITY_ORDER))
    elif op == "cell":
        print(cell(arg(0), arg(1)).get(arg(2), ""))
    elif op == "spec":
        print(spec_row(arg(0)).get(arg(1), ""))
    elif op == "wire":
        print(wire(arg(0), arg(1)))
    elif op == "drift":
        return drift()
    else:
        print(f"unknown probe op '{op}'", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
