#!/usr/bin/env python3
# /// script
# dependencies = ["websockets"]
# ///
import argparse
import asyncio
import json
import sys

import websockets  # pyright: ignore[reportMissingImports]


class OneLineParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, f"error: {message}\n")


async def update(args):
    async with asyncio.timeout(10):
        async with websockets.unix_connect(path=args.sock) as ws:
            await ws.send(json.dumps({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "agentctl-settings", "version": "1"},
                "capabilities": {"experimentalApi": True}}}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("id") == 1:
                    if "error" in msg:
                        raise ValueError(msg["error"])
                    break
            await ws.send(json.dumps({"method": "initialized", "params": {}}))
            await ws.send(json.dumps({"id": 2, "method": "thread/resume", "params": {
                "threadId": args.thread, "excludeTurns": True}}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("id") == 2:
                    if "error" in msg:
                        raise ValueError(msg["error"])
                    resume = msg["result"]
                    break
            params = {"threadId": args.thread}
            for key in ("effort", "model"):
                if getattr(args, key) is not None:
                    params[key] = getattr(args, key)
            if args.mode is not None:
                params["collaborationMode"] = {"mode": args.mode, "settings": {
                    "model": args.model if args.model is not None else resume["model"],
                    "reasoning_effort": (args.effort if args.effort is not None
                                         else resume.get("reasoningEffort")),
                    "developer_instructions": None}}
            await ws.send(json.dumps({"id": 3, "method": "thread/settings/update", "params": params}))
            ack = settings = None
            while ack is None or settings is None:
                msg = json.loads(await ws.recv())
                if msg.get("id") == 3:
                    if "error" in msg:
                        raise ValueError(msg["error"])
                    ack = msg.get("result", {})
                elif msg.get("method") == "thread/settings/updated" and msg.get("params", {}).get("threadId") == args.thread:
                    settings = msg["params"]["threadSettings"]
            return {"effort": settings.get("effort"),
                    "mode": settings["collaborationMode"]["mode"],
                    "model": settings.get("model"),
                    "approval": settings.get("approvalPolicy"),
                    "sandbox": settings.get("sandboxPolicy")}


if __name__ == "__main__":
    parser = OneLineParser()
    parser.add_argument("--sock", required=True)
    parser.add_argument("--thread", required=True)
    parser.add_argument("--effort")
    parser.add_argument("--mode", choices=("plan", "default"))
    parser.add_argument("--model")
    args = parser.parse_args()
    try:
        print(json.dumps(asyncio.run(update(args))))
    except Exception as exc:
        print(f"{type(exc).__name__}: {str(exc).splitlines()[0] if str(exc) else 'daemon update failed'}", file=sys.stderr)
        sys.exit(1)
