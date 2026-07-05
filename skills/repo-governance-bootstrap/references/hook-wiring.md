# memory-discipline hook 三 agent wiring（bootstrap 步骤 11 用）

## memory-discipline hook 模板（步骤 11）

> 步骤 11 的三 agent wiring。`references/memory-discipline-hook.py` = CC + codex 共用（python3、stdlib json、双
> extractor、无 jq 依赖），omp 另走 JS hook。字段/flag 已 2026-06 本地实跑验证（见各 ⚠️）。`<S>` = 本 skill 安装路径。
> 脚本可执行 + shebang，直接 exec、别加 `bash`/`python3` 前缀。

**entry 真源 = 本 skill 根 `hooks.json`**（接入读它、command 换安装根绝对路径、直接 exec 别加 `python3 ` 前缀——hooks 不展开 `~`）。下方 ①② 为展开示例：

**① Claude Code** — 项目 `.claude/settings.json`（实测可用）：
```jsonc
"hooks": { "PostToolUse": [{ "matcher": "Write|Edit|MultiEdit",
  "hooks": [{ "type": "command", "command": "<S>/references/memory-discipline-hook.py" }] }] }
```

**② codex** — 项目 `.codex/hooks.json`（**嵌套 JSON、非 TOML**，实测）：
```json
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"<S>/references/memory-discipline-hook.py"}]}]}}
```
⚠️ 实测：codex 写文件 `tool_name=apply_patch`(非 Write)、路径在 `.tool_input.command` patch 文本里——脚本已含该
extractor。起 codex 要带**两个** flag：`--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`
（缺后者 project-local hook 不被信任、不加载）。坑：`~/.codex/hooks.json` 若有解析错误（如 `unknown field`）会让
**整套 hook 加载失败**（含项目级）——先跑一次确认生效。

**③ omp** — JS hook `references/memory-discipline-hook.ts`（实测可用），`omp --hook <S>/references/memory-discipline-hook.ts`
或放 `.omp/hooks/`：
```ts
export default (pi)=>{ pi.on("tool_result", async (e)=>{ /* toolName 小写 write/edit、路径 e.input.path、排除 MEMORY.md */
  await pi.sendUserMessage(REMINDER, { deliverAs:"followUp" }); }); }
```
⚠️ 实测：omp 无 command/stdin hook，走 `tool_result` 事件（`toolName` 小写 `write`/`edit`、路径 `event.input.path`）。注入**必须用
`pi.sendUserMessage(text,{deliverAs:"followUp"})`**——落 `role:user` 进 transcript、模型下一轮读到并遵守；`pi.sendMessage` 是
hidden/developer 通道、模型常忽略，别用。**措辞要中性**（普通提醒口吻），伪 SYSTEM/"你必须…"会被当 prompt-injection 拒绝。

