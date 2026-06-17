// Bun test for hooks/omp-watch.ts — verifies the omp adapter registers each
// lifecycle event and maps it to the unified STATE + the emit.sh line format.
// Driven by the runner ONLY when `bun` is on PATH (else SKIP, suite stays green).
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "aw-omp-"));
const SESS = "ompts";
process.env.AGENT_WATCH_SESSION = SESS;
process.env.AGENT_WATCH_DIR = dir;

const hook = (await import(join(import.meta.dir, "..", "skills", "cto-orchestration", "references", "agent-watch", "hooks", "omp-watch.ts"))).default;

// Fake `pi`: capture (event -> cb) registrations.
const reg: Record<string, () => void> = {};
const pi = { on: (ev: string, cb: () => void) => { reg[ev] = cb; } };
hook(pi);

let pass = 0, fail = 0;
const ok = (label: string, cond: boolean, detail = "") => {
  if (cond) { console.log(`  ok   ${label}`); pass++; }
  else { console.log(`  FAIL ${label}${detail ? " -- " + detail : ""}`); fail++; }
};

// All five events from the adapter table must be registered.
for (const ev of ["turn_start", "tool_call", "waiting", "turn_end", "idle"]) {
  ok(`registers ${ev}`, typeof reg[ev] === "function");
}

// Fire each, then assert the resulting last line's STATE.
const eventsFile = join(dir, `${SESS}.events`);
const lastState = (): string => {
  if (!existsSync(eventsFile)) return "<none>";
  const lines = readFileSync(eventsFile, "utf8").trim().split("\n");
  return lines[lines.length - 1].split(" ")[1];
};
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;

const fire = (ev: string, expectState: string) => {
  reg[ev]();
  ok(`${ev} -> ${expectState}`, lastState() === expectState, `got ${lastState()}`);
  const lines = readFileSync(eventsFile, "utf8").trim().split("\n");
  ok(`${ev} line ISO format`, ISO.test(lines[lines.length - 1]));
};

fire("turn_start", "WORKING");
fire("tool_call", "WORKING");
fire("waiting", "WAITING");
fire("turn_end", "DONE");
fire("idle", "DONE");

// no-session => no-op (never throws, writes nothing new).
{
  const dir2 = mkdtempSync(join(tmpdir(), "aw-omp2-"));
  process.env.AGENT_WATCH_DIR = dir2;
  delete process.env.AGENT_WATCH_SESSION;
  const reg2: Record<string, () => void> = {};
  hook({ on: (ev: string, cb: () => void) => { reg2[ev] = cb; } });
  reg2["turn_start"]();
  ok("no-session no-op", !existsSync(join(dir2, "ompts.events")) && !existsSync(join(dir2, "undefined.events")));
}

console.log(`-- ${pass} passed, ${fail} failed --`);
if (fail === 0) { console.log("PASS"); process.exit(0); } else { console.log("FAIL"); process.exit(1); }
