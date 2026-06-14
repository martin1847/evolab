# 编排增量条款：并入项目 AGENTS.md 的「委派 Agent 边界」

> **定位**：项目的完整 AGENTS.md 由 `/repo-governance-bootstrap` 用其
> `references/PROJECT_AGENT.md` 生成——已含 Source of Truth / 三档 Work Modes / 模块边界 /
> 状态词汇 / Validation。本文件**只补一节**：多 agent 并发编排特有的防漂移条款，bootstrap
> 宪法里没有。把下面这节增补进生成的 AGENTS.md，按项目改凭据中枢名。
>
> Work Modes 与 Validation **不在这里重复**——以 `PROJECT_AGENT.md` 为准（canonical）。

```markdown
## 委派 Agent 边界（防漂移 anti-drift）

多个 agent 会话并发运行，每个 agent 必须：
- 待在分配给它的 **scope 内**（即 goal 文档）；不改属于其他会话 scope 的文件。
- 被阻塞、或想扩张 scope 时：**停下并上报**，不自行授权。
- 不改既有用户可见行为，除非是明确批准的修复——行为变更一律藏在 env flag 后、默认 OFF。
- trace / 日志 / docs 里脱敏 secrets 与客户敏感值；凭据只存于 <凭据中枢，如 1Password / Vault>，绝不进仓库树。
- 未经明确批准，绝不把本地实验连到生产数据。
- commit 留本地，直到 owner 明确批准 push；push 到 feature 分支 + PR，绝不 force 推共享分支。
```
