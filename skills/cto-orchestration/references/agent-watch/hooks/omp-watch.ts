// omp (oh-my-pi) lifecycle hook for the unified agent-state watch.
// Load with:  omp --hook <abs>/omp-watch.ts   (or copy into ~/.omp/agent/hooks/)
// Maps omp's native events to the unified STATE and appends to the sentinel file.
// Self-contained (writes the file directly, env-driven) so it has no dependency on
// resolving emit.sh's path from inside the hook loader. Format matches emit.sh.
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const SESS = process.env.AGENT_WATCH_SESSION || "";
// Default matches the shell scripts: /tmp, not $HOME (codex sandbox blocks $HOME writes).
const DIR = process.env.AGENT_WATCH_DIR || "/tmp/agent-watch-run";

function emit(state: string, detail = ""): void {
	if (!SESS) return; // no session bound → no-op, never break the agent
	try {
		mkdirSync(DIR, { recursive: true });
		appendFileSync(join(DIR, `${SESS}.events`), `${new Date().toISOString()} ${state} ${detail}\n`);
	} catch {
		/* never throw from a hook */
	}
}

// HookAPI type is provided by omp at load time; keep the signature loose to avoid
// a hard import that could break across omp versions.
export default function (pi: any): void {
	pi.on("turn_start", () => emit("WORKING", "turn_start"));
	pi.on("tool_call", () => emit("WORKING", "tool_call"));
	pi.on("waiting", () => emit("WAITING", "waiting"));
	pi.on("turn_end", () => emit("DONE", "turn_end"));
	pi.on("idle", () => emit("DONE", "idle"));
}
