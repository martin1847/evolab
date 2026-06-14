# 前端验证规范（浏览器联调）

> 适用于任何前端 fix 的运行时验证。来源：多 agent CTO 项目前端联调实战（2026-06）。
> 核心原则：**前端改动，代码 review + 单测都不够，必须回浏览器看真实渲染**。

## 工具选型：MCP 主、CLI 补（不是二选一）

| 角色 | 工具 | 何时用 |
|---|---|---|
| **前端行为验证（主）** | chrome-devtools MCP（或 Playwright MCP） | 唯一能看"UI 真实渲染对不对"——有没有提前显示完成/重复/卡死/计时错乱。**前端 fix 必须靠它**。 |
| **前端联网诊断（主）** | chrome-devtools MCP 网络面板 | 看请求 pending/失败/去向——能抓到**前端自己的联网 bug**（如代理目标没配，请求 pending）。CLI 直连会"恰好成功"从而**掩盖**这类 bug。 |
| **元素定位** | a11y/DOM 快照的 uid/ref | 比坐标/截图稳、可复现、token 省；坐标/vision 仅作 fallback（拿不到 ref 或纯视觉布局问题）。 |
| **后端 ground-truth（补充）** | CLI `curl` + bearer token | 抓 SSE 逐事件时序（`curl -N` 比网络面板强）、探 API、提 token、脚本化/循环、token 省。**绕过前端网络层 → 验不了前端行为**。 |


**判据**：纯 CLI 验不了前端渲染；纯 MCP 抓 SSE 时序笨。一个前端 fix 的最优是**混合**——
MCP 驱动登录+渲染验证+网络诊断，CLI 抓 SSE/API ground-truth。

## 联调铁律

1. **a11y/DOM 快照优先定位元素**，坐标/截图 fallback。
2. **深层问题（console/network/perf）走 MCP**，别从截图猜运行时。
3. **每次改完回浏览器读运行时验证**（vite HMR 自动重载 → 重新 snapshot/读 console/查 network）。
   不要只读代码就认定改对了。
4. **canvas 渲染的 UI**（多维表/图表）a11y 拿不到内容 → 退回截图 read。

## 本地起前端：坑高度项目特定 → 写进该项目 AGENTS.md

每个前端项目本地起服务的坑差别很大，**不在这个通用文件固化**。在你的前端项目 `AGENTS.md`
建一节，按这几个维度写清你项目的**具体答案**：

- **后端代理目标**：dev server 的 `/api` 代理指向哪、哪个 env 控制（未设常请求 pending 挂死）。
- **运行时配置注入点**：API base 等是否在 build config 硬编码、怎么临时覆盖。
- **登录流程**：是否多步（密码 + 租户/组织选择）——密码提交 ≠ 登录成功。
- **测试运行器怪癖**：`watch` 模式是否撞 `EMFILE` 等 → 单跑模式兜底。

只有一条**跨项目通用手法**留在这里：运行时配置硬编码、要临时改指向又不污染正在被 review
的工作树时，用浏览器 MCP 在页面加载前以 `initScript` 把配置对象
`Object.defineProperty(..., {writable:false})` 锁住，让页面自身的注入脚本覆盖失败（零文件改动）。

## 新项目接入

把上面"联调铁律"+"工具选型"写进该前端项目的 `AGENTS.md`（"前端联调/浏览器运行时验证规约"
节）。MCP server 配在 `~/.claude.json`，新增后需重启会话/`/mcp` 重连,不热加载。
