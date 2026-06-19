// memory-discipline-hook.ts — omp counterpart of memory-discipline-hook.sh (Claude Code + codex).
//
// omp has no command/stdin PostToolUse hook; it uses a JS factory + tool_result event.
// Verified 2026-06 on omp/16.0.3: pi.sendUserMessage(text, { deliverAs: "followUp" })
// lands a role:"user" entry in the transcript that the model reads on its next turn and
// follows. (pi.sendMessage is a hidden/developer channel — the model often ignores it; do
// not use it here.) Wording MUST stay a neutral reminder — fake-SYSTEM / "you must …"
// phrasing gets flagged as prompt-injection and refused.
//
// Behavior mirrors the .sh: a write/edit on a memory/*.md file (not the MEMORY.md index)
// -> inject the offload reminder. Anything else -> no-op.
//
// Wiring: omp --hook <this> …  (or drop in .omp/hooks/). Test: test/memory-hook-omp.bun.ts.

const REMINDER =
  "[memory 提醒] 刚写了 memory/ 文件：事实细节(schema/config/creds/endpoint/长清单)宜放 ACCESS.local.md/docs，memory 正文留指针+教训即可。";

const isMemoryDoc = (p: string): boolean =>
  /(^|\/)memory\/.*\.md$/.test(p) && p.split("/").pop() !== "MEMORY.md";

export default (pi: any) => {
  pi.on("tool_result", async (event: any) => {
    if (event?.isError) return;
    const name = String(event?.toolName ?? "").toLowerCase();
    if (name !== "write" && name !== "edit") return; // omp tool names are lowercase
    if (!isMemoryDoc(String(event?.input?.path ?? ""))) return;
    await pi.sendUserMessage(REMINDER, { deliverAs: "followUp" });
  });
};
