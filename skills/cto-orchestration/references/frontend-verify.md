# 前端验证规范（浏览器联调）

> 适用于任何前端 fix 的运行时验证。
> 核心原则：**前端改动，代码 review + 单测都不够，必须回浏览器看真实渲染**。

## 工具选型：浏览器 CLI 探路、Test 定型、curl 补 HTTP

> 三个词各指一物，**别用裸「CLI」**：`playwright-cli`（浏览器 CLI，驱真浏览器）·
> `@playwright/test`（断言真源）· `curl`（HTTP 直连，不经浏览器）。

| 角色 | 工具 | 何时用 |
|---|---|---|
| **探索 / 定位 / 临时诊断** | `@playwright/cli`（命令 `playwright-cli`）：`snapshot` 取 ref → `find` 搜大快照 → `generate-locator` 出 locator；`requests` / `console` 读联网与运行时 | 真浏览器且省 token——工具 schema 不进上下文，命令即证据可贴进 goal。看得到"渲染对不对"与**前端自己的联网 bug**（代理没配、请求 pending）。ref 定位比坐标/截图稳，坐标/vision 仅作 fallback。 |
| **断言真源 / 重复执行 / 部署后验收** | `@playwright/test` 的 `.spec.ts` | selector 与 oracle 稳定后落 spec；本地 build 与已部署环境**复用同一 spec**，只切 `use.baseURL`（按 `process.env` 分支）与 auth fixture（`auth.setup.ts` setup project + `dependencies` + `storageState`；凭据落 `playwright/.auth` 且 gitignore）。 |
| **后端 ground-truth** | `curl` + bearer token | 抓 SSE 逐事件时序（`curl -N`）、探 API、提 token、脚本化。**绕过前端网络层 → 验不了前端行为**，别拿它当渲染验证。 |
| **Playwright MCP（例外形态）** | 同一套工具的 MCP 前端 | 默认 headed、贵（工具 schema + 快照进上下文）；只在要人眼盯或逐 tool 迭代时用。 |

**浏览器归属与登录态**：默认 Playwright 自起的浏览器，**登录态跟项目走、不用临时 profile**——
每角色一份 storageState（上表的 auth fixture），一个项目一个命名会话 `-s=<project>` 天然隔离、
并行不互污。**绝不抢主理人日常 Chrome/Edge 的 profile**：争控制面之外，锁 profile 会弄坏他自己的
浏览器（断连坑过两次）。企业 SSO 等确实无法回放成 storageState 的场景，**CDP attach 一个已在跑的
专用实例**是正确形态（比夺 profile 好），但要主理人放行——一次性 override、用后即焚。
强制层见 bash guard ⑨ · agent guard P0a，此处只是指针。

## 重复型 E2E：交付物 = `.spec.ts`，不是自建 runner

同一验收第二次起不再手驱：selector 与 oracle 稳定后落 `@playwright/test` spec，负对照内建
（如"某个假 id 必须查无"），随项目入库、路径进该项目 AGENTS.md。**消费口径 = 进程退出码 + reporter
产物**（取代自建 node runner 的 `RESULT` 尾行约定；验收方只认退出码与 report，不认叙述）。

## 状态形状矩阵（E2E 只测新鲜快乐态 = 结构性漏测）<!-- trunk:状态形状矩阵 -->

全部 E2E 只用"刚登录的黄金账号"时，token 过期态（恢复代码缺失）与贫数据形状（oauth 用户缺
nickname/phone）永远走不到——**新鲜登录的测试走不到时间态与数据形状分支**。
铁律：鉴权/用户数据相关的前端验证，至少覆盖：

| 态 | 制造方法（Playwright 可脚本化） |
|---|---|
| 新鲜登录 | 常规流程 |
| **过期/老化会话** | 登录后删 access cookie（保留 refresh/UI 提示 cookie）再导航——断言自动恢复而非报错 |
| **贫数据账号** | mock 最小响应形状（仅必填字段）——断言空态占位而非崩溃/永久加载 |
| 未登录 | 断言引导登录而非通用错误 |
| **引擎×输入方式** | 桌面 chromium 鼠标 click 通过 ≠ 真机触摸可用——至少补一组 **webkit 引擎 + iPhone 设备描述符(hasTouch) + `page.tap`**（近似 WKWebView/微信）；交互命中类改动（可点标签/弹层/浮层）此组必跑 |
| **非 owner 视角**（多主体轴，见主干 §3） | 运行前按产品合同**写死每个单元的 entitlement 与期望结果**，禁止跑完再在「可见/拒绝」间选 oracle：正向单元 = owner 建资源并真实授予第二账号角色/分享 → 断言**全链可见**；拒绝单元 = 未授权或跨租户账号 → 断言各接口**显式拒绝**而非静默消失（典型病形：各接口对同一资源用了不同可见性谓词——一处按分享判、一处只按租户收窄，非 owner 视角整块蒸发而 owner 视角全绿） |

staging 应养**常备测试账号矩阵**（手机号全字段户 / oauth 贫字段户 / 同租户第二身份户），不是一个黄金账号打天下。

## 联调铁律

1. **a11y/DOM 快照优先定位元素**，坐标/截图 fallback。
2. **深层问题（console/network/perf）读运行时**（`playwright-cli console` / `requests`），别从截图猜。
3. **每次改完回浏览器读运行时验证**（vite HMR 自动重载 → 重新 snapshot/读 console/查 network）。
   不要只读代码就认定改对了。
4. **canvas 渲染的 UI**（多维表/图表）a11y 拿不到内容 → 退回截图 read。

## 交付闭环：三段绿 ≠ 真用户能看到（`代验路径≠真路径` 的前端实例）

mock 契约 + 后端 SSE 帧 + 本地 dev 渲染**都过，也不等于真用户能看到**。完整闭环：
改代码 → **本地 localhost E2E（部署前门，必过）** → **运维发布** → **登已发布的真应用跑真实一轮**
（真浏览器，非 mock / 非本地 dev）→ 成功**截图** → 才更新任务系统状态。

- **部署前先在 localhost E2E（必过门，别直接发布）**：用**真 build 连真后端**（不是 §联调铁律3 那种
  vite HMR dev 渲染——那只是迭代时的快照）跑一遍真实用户路径。理由：**部署慢且贵，bug 在本地抓一次
  比"发布→ReOpen→再发布"省一整轮**。本地起服务+API base 覆盖的项目特定坑写进项目 `AGENTS.md`
  （见下「本地起前端」）。localhost E2E 绿是**发布前置条件、非验收**。
- **发布后再登真应用跑真实一轮**才是验收门。**别拿"代验路径"当"真路径"验收**——真实路径常和你
  mock / 甚至 localhost 的那条不是同一条（部署环境的 build config / 路由 / 鉴权 / 通道可能不同）。
通用原则见 SKILL.md §3「验证诚实」。

## E2E 验收委派给浏览器子 agent（不是编排者亲手刨）

"登真应用跑真实一轮"是验收，不占编排者主上下文（SKILL §0 不自己跑长 E2E）。编排者只出**派发包**：
登录/导航配方 + 每条 **PASS 判据** + **凭证接入文件的绝对路径**（它在治理根，子 agent 的 cwd 在
worktree/子仓里搜不到；别指望它自己找、别 symlink 进仓库）。子 agent 隔离上下文里 OBSERVE，回
**PASS/FAIL/BLOCKED + 证据**，**只读、不动 git/状态**。多分钟慢流与重复点击类尤其该派。
**真路径没在真应用验过前不标「可测试」**；「数据缺 / 够不着」是合法 BLOCKED，别逼它猜 PASS。

**两种模式别混**：上面是**验收探针**（判据已知，答 PASS/FAIL）。另一种是**探索器**——判据未知，
让它自己找问题。探索器分两轮，**产量几乎全在第二轮**：第一轮走通路（happy path，抓的多是命名/
渲染不一致）；第二轮**专攻返工、失败、通关与权限切换路径**——用户真正会撞的都在这里，而机制测试
结构上够不着。探索器的原始产出必须筛（噪声比高，凭现场证据留），并要求它自报**探不了什么**
（如 fake 模型下的内容质量）——不自报边界的探索报告不可消费。

## 本地起前端：坑高度项目特定 → 写进该项目 AGENTS.md

每个前端项目本地起服务的坑差别很大，**不在这个通用文件固化**。在你的前端项目 `AGENTS.md`
建一节，按这几个维度写清你项目的**具体答案**：

- **后端代理目标**：dev server 的 `/api` 代理指向哪、哪个 env 控制（未设常请求 pending 挂死）。
- **运行时配置注入点**：API base 等是否在 build config 硬编码、怎么临时覆盖。
- **登录流程**：是否多步（密码 + 租户/组织选择）——密码提交 ≠ 登录成功。
- **测试运行器怪癖**：`watch` 模式是否撞 `EMFILE` 等 → 单跑模式兜底。

只有一条**跨项目通用手法**留在这里：运行时配置硬编码、要临时改指向又不污染正在被 review
的工作树时，在页面加载前把配置对象用 `Object.defineProperty(..., {writable:false})` 锁住，
让页面自身的注入脚本覆盖失败（零文件改动）。**关键是"加载前"**：用 `page.addInitScript`
（`playwright-cli run-code` 或 spec 里直接调，每次导航在页面脚本前跑）——**不是**加载后求值的
`evaluate` 类，那抢不到页面自己注入之前。。

## 新项目接入

把上面"联调铁律"+"工具选型"写进该前端项目的 `AGENTS.md`（"前端联调/浏览器运行时验证规约"节），
并在其中钉死 `@playwright/cli` 与 `@playwright/test` 的版本——前者仍在 0.x（底层走 alpha 通道），
命令面会漂，别当稳定契约引用。
