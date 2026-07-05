# 前端验证规范（浏览器联调）

> 适用于任何前端 fix 的运行时验证。来源：多 agent CTO 项目前端联调实战（2026-06）。
> 核心原则：**前端改动，代码 review + 单测都不够，必须回浏览器看真实渲染**。

## 工具选型：MCP 主、CLI 补（不是二选一）

| 角色 | 工具 | 何时用 |
|---|---|---|
| **前端行为验证（主）** | **Playwright MCP（默认首选）**；chrome-devtools MCP 仅当必须复用用户已登录的真实 Chrome（CDP attach） | 唯一能看"UI 真实渲染对不对"——有没有提前显示完成/重复/卡死/计时错乱。**前端 fix 必须靠它**。 |
| **前端联网诊断（主）** | Playwright MCP 网络（`browser_network_requests`）；或 chrome-devtools 网络面板 | 看请求 pending/失败/去向——能抓到**前端自己的联网 bug**（如代理目标没配，请求 pending）。CLI 直连会"恰好成功"从而**掩盖**这类 bug。 |
| **元素定位** | a11y/DOM 快照的 uid/ref | 比坐标/截图稳、可复现、token 省；坐标/vision 仅作 fallback（拿不到 ref 或纯视觉布局问题）。 |
| **后端 ground-truth（补充）** | CLI `curl` + bearer token | 抓 SSE 逐事件时序（`curl -N` 比网络面板强）、探 API、提 token、脚本化/循环、token 省。**绕过前端网络层 → 验不了前端行为**。 |


**判据**：纯 CLI 验不了前端渲染；纯 MCP 抓 SSE 时序笨。一个前端 fix 的最优是**混合**——
MCP 驱动登录+渲染验证+网络诊断，CLI 抓 SSE/API ground-truth。

> **Playwright 优先已是 hook 硬规则**（P0a：浏览器派发载 `mcp__chrome-devtools` token 即被 `cto-guard-agent.py` DENY）。
> why：chrome-devtools 与用户浏览器 + 多 agent 争 CDP、断连坑两次；仅当必须 attach 用户已登录会话才值得用它。

## 状态形状矩阵（E2E 只测新鲜快乐态 = 结构性漏测）<!-- trunk:状态形状矩阵 -->

实证（2026-07-05，同日两个 P1 同根）：全部 E2E 用"刚登录的黄金账号"→ ① access token 过期后
前端零恢复代码（UI 提示 cookie 比 access 长命，过期态用户全灭）② 贫数据账号（微信 oauth 用户
缺 nickname/phone）触发崩溃——两者都只在真机上被主理人踩到。**新鲜登录的测试永远走不到时间态
与数据形状分支。** 铁律：鉴权/用户数据相关的前端验证，至少覆盖：

| 态 | 制造方法（Playwright 可脚本化） |
|---|---|
| 新鲜登录 | 常规流程 |
| **过期/老化会话** | 登录后删 access cookie（保留 refresh/UI 提示 cookie）再导航——断言自动恢复而非报错 |
| **贫数据账号** | mock 最小响应形状（仅必填字段）——断言空态占位而非崩溃/永久加载 |
| 未登录 | 断言引导登录而非通用错误 |

staging 应养**常备测试账号矩阵**（手机号全字段户 / oauth 贫字段户），不是一个黄金账号打天下。

## 联调铁律

1. **a11y/DOM 快照优先定位元素**，坐标/截图 fallback。
2. **深层问题（console/network/perf）走 MCP**，别从截图猜运行时。
3. **每次改完回浏览器读运行时验证**（vite HMR 自动重载 → 重新 snapshot/读 console/查 network）。
   不要只读代码就认定改对了。
4. **canvas 渲染的 UI**（多维表/图表）a11y 拿不到内容 → 退回截图 read。

## 交付闭环：三段绿 ≠ 真用户能看到（`代验路径≠真路径` 的前端实例）

mock 契约 + 后端 SSE 帧 + 本地 dev 渲染**都过，也不等于真用户能看到**。完整闭环：
改代码 → **本地 localhost E2E（部署前门，必过）** → **运维发布** → **登已发布的真应用跑真实一轮**
（浏览器 MCP，非 mock / 非本地 dev）→ 成功**截图** → 才更新任务系统状态。

- **部署前先在 localhost E2E（必过门，别直接发布）**：用**真 build 连真后端**（不是 §联调铁律3 那种
  vite HMR dev 渲染——那只是迭代时的快照）跑一遍真实用户路径。理由：**部署慢且贵，bug 在本地抓一次
  比"发布→ReOpen→再发布"省一整轮**。本地起服务+API base 覆盖的项目特定坑写进项目 `AGENTS.md`
  （见下「本地起前端」）。localhost E2E 绿是**发布前置条件、非验收**。
- **发布后再登真应用跑真实一轮**才是验收门。**别拿"代验路径"当"真路径"验收**——真实路径常和你
  mock / 甚至 localhost 的那条不是同一条（部署环境的 build config / 路由 / 鉴权可能不同）。
  实证：记忆建议卡片 mock/SSE/本地三段都绿却被 ReOpen——真前端走 `execute/async`
  （非验证用的 `execute/stream`），卡片帧没进 async UI 读的事件流 + pending 响应无 turn 锚点 → 不渲染。
通用原则见 SKILL.md §3「验证诚实」。

## E2E 验收委派给浏览器子 agent（不是编排者亲手刨）

上面"登真应用跑真实一轮"是验收、不该占编排者主上下文（SKILL §0「不自己跑长 E2E」+ §4 委派模式的前端实例）。
编排者只出**派发包**——登录/导航配方（URL/账号/租户/起步路由坑）+ 每条 **PASS 判据**；**派发包必须写死凭证/接入文件（如 `ACCESS.local.md`）的绝对路径**——它一般在项目治理根（umbrella），子 agent 的 cwd 在 worktree/子仓里、往下搜或相对搜**找不到**（实证:E2E agent 全盘搜没命中、卡在要密码）。别指望它自己找、别 symlink 进仓库（worktree 临时/子仓有远程/secrets-adjacent），goal 直接给绝对路径。子 agent 在隔离上下文
登已发布真应用、OBSERVE、回 **PASS/FAIL/BLOCKED + 证据（截图/尺寸/节点数）**，**只读、不动 git/状态**，据其回报
由编排者翻状态 / 派回修。尤其值得委派多分钟慢流（触发生成→卡 reload 恢复）/ 重复点击类——塞编排者主上下文
既堵又烧 token。**ReOpen 真路径没在真应用验过前不标「可测试」**；子 agent 报「下载够不着 / 数据缺 / 树太小没
复现退回点」是合法 BLOCKED，别逼它猜 PASS。

## 本地起前端：坑高度项目特定 → 写进该项目 AGENTS.md

每个前端项目本地起服务的坑差别很大，**不在这个通用文件固化**。在你的前端项目 `AGENTS.md`
建一节，按这几个维度写清你项目的**具体答案**：

- **后端代理目标**：dev server 的 `/api` 代理指向哪、哪个 env 控制（未设常请求 pending 挂死）。
- **运行时配置注入点**：API base 等是否在 build config 硬编码、怎么临时覆盖。
- **登录流程**：是否多步（密码 + 租户/组织选择）——密码提交 ≠ 登录成功。
- **测试运行器怪癖**：`watch` 模式是否撞 `EMFILE` 等 → 单跑模式兜底。

只有一条**跨项目通用手法**留在这里：运行时配置硬编码、要临时改指向又不污染正在被 review
的工作树时，在页面加载前把配置对象用 `Object.defineProperty(..., {writable:false})` 锁住，
让页面自身的注入脚本覆盖失败（零文件改动）。**关键是"加载前"**：用 Playwright 的
`page.addInitScript`（经 `browser_run_code_unsafe` 调，每次导航在页面脚本前跑）——**不是** `browser_evaluate`
/ chrome-devtools `evaluate_script`，那俩是加载后求值、抢不到页面自己注入之前。实测验证过此手法
（addInitScript 先跑 + writable:false 挡掉页面覆盖）。

## 新项目接入

把上面"联调铁律"+"工具选型"写进该前端项目的 `AGENTS.md`（"前端联调/浏览器运行时验证规约"
节）。MCP server 配在 `~/.claude.json`，新增后需重启会话/`/mcp` 重连,不热加载。
