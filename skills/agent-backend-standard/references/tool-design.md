# II-4 — 工具 / 函数设计（ACI: Agent-Computer Interface）

> 素材基线：Anthropic writing-tools / advanced-tool-use / code-execution-with-MCP、
> MCP 2026-07-28 规范（stateful handle 节）。

## 1. 质量定义（先立靶）

工具集的质量**不是**实现得多全，而是：只拿这套工具、无其他上下文的 LLM 能否答出
真实且困难的多跳问题（MCP 官方 mcp-builder 的定义）。→ 工具定义是**可测、可回归的
软件表面**：改描述/改 schema 必须过 eval（III-10），不是改散文。
实证幅度：Tool Search（按需检索工具定义）49%→74%；Tool Use Examples（参数示例）
复杂参数准确率 72%→90%——**描述与示例的杠杆比实现本身大**。

## 2. 设计规则（判断项，按咬人频率排）

1. **命名空间前缀分组**（`asana_search` / `jira_search`）：多服务工具面防混淆；
   prefix 命名实测优于 suffix。
2. **token 效率是一等设计维度**：分页/过滤/截断默认给（参考上限 ~25k tokens/响应）；
   提供 `response_format` enum（concise/detailed，实测 72 vs 206 tokens）；高频大结果
   工具优先返回轻量标识符再按需展开（just-in-time）。
3. **错误响应为 LLM 而写**：actionable、含具体修法与当前合法值（"Invalid departure
   date: must be in the future. Current date is 2025-08-08."），不吐 opaque 错误码/
   堆栈。执行错误（isError）≠协议错误——业务失败走前者，让模型能自纠重试。
4. **中间结果不过模型**：链式取数场景考虑代码执行面（agent 写代码调工具、本地过滤后
   只回结论）——工具定义+中间结果全过上下文的成本实测可差 98%（150k→2k）。
5. **整合优于碎化**：一个"完成任务"的工具优于三个"暴露 API"的工具（REST→工具一键
   转换的 CRUD 碎化是已知反模式：语义丢失/chatty/事务缺失）。

## 3. 有状态 handle 四约束（MCP 2026-07-28 规范级，跨调用状态的正解）

跨调用状态外化为**服务端签发的显式 handle**（普通参数传递），且：
1. **handle 是名字不是能力**：每次调用都对 caller 重新鉴权（无认证场景 handle 即
   bearer token——足够熵+有界生命周期）；
2. **不透明**：编码内部结构会招致解析与猜测；
3. **生命周期写进创建工具的 description**（"expires after 24h"）——模型决定建状态时
   就能看到；
4. **过期返回明确执行错误**，让模型自恢复。

## 4. 电在回路接线

- 工具描述/schema 变更 → eval 回归门（CI）；
- 错误文案质量无法机检 → 留人审清单项 + 用 eval transcript 反哺（让 agent 读自己的
  失败记录重构工具定义，官方 collaborate 流程）。
