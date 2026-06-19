// Bun test for memory-discipline-hook.ts (omp tool_result hook). Verifies it calls
// pi.sendUserMessage with deliverAs:"followUp" exactly for write/edit on memory/*.md
// (non-MEMORY.md) and stays silent otherwise. SKIP when bun is absent (suite stays green).
import { join } from "node:path";

const hook = (await import(
  join(import.meta.dir, "..", "skills", "repo-governance-bootstrap", "references", "memory-discipline-hook.ts")
)).default;

// Fake pi: capture the tool_result handler + record sendUserMessage calls.
let handler: ((e: any) => Promise<void>) | undefined;
let calls: Array<{ text: string; opts: any }> = [];
const pi = {
  on: (ev: string, cb: (e: any) => Promise<void>) => { if (ev === "tool_result") handler = cb; },
  sendUserMessage: async (text: string, opts: any) => { calls.push({ text, opts }); },
};
hook(pi);

let pass = 0, fail = 0;
const ok = (label: string, cond: boolean, detail = "") => {
  if (cond) { console.log(`  ok   ${label}`); pass++; }
  else { console.log(`  FAIL ${label}${detail ? " -- " + detail : ""}`); fail++; }
};

ok("registers tool_result", typeof handler === "function");

const fire = async (event: any): Promise<number> => {
  calls = [];
  await handler!(event);
  return calls.length;
};

const w = (path: string, extra: any = {}) => ({ toolName: "write", input: { path }, isError: false, ...extra });

// fires
ok("write memory/ fires", (await fire(w("memory/lesson.md"))) === 1);
ok("write nested memory/ fires", (await fire(w("/proj/memory/sub/x.md"))) === 1);
ok("edit memory/ fires", (await fire({ toolName: "edit", input: { path: "memory/x.md" }, isError: false })) === 1);

// silent
ok("MEMORY.md index silent", (await fire(w("memory/MEMORY.md"))) === 0);
ok("non-memory path silent", (await fire(w("src/app.md"))) === 0);
ok("memory non-.md silent", (await fire(w("memory/notes.txt"))) === 0);
ok("read tool silent", (await fire({ toolName: "read", input: { path: "memory/x.md" }, isError: false })) === 0);
ok("isError silent", (await fire(w("memory/x.md", { isError: true }))) === 0);
ok("missing path silent", (await fire({ toolName: "write", input: {}, isError: false })) === 0);

// payload shape
await fire(w("memory/lesson.md"));
ok("deliverAs followUp", calls[0]?.opts?.deliverAs === "followUp");
ok("reminder text present", typeof calls[0]?.text === "string" && calls[0].text.includes("指针"));

console.log(`-- ${pass} passed, ${fail} failed --`);
process.exit(fail === 0 ? 0 : 1);
