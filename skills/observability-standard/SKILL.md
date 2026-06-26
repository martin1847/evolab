---
name: observability-standard
version: 1.1.0
description: 生产级可观测性与工程规范,适用于**所有后端服务** —— 普通微服务(auth / 网关 / 业务服务)与 agent / 多 agent / RAG 知识库项目通用。核心:用 trace_id 串 trace/log + 业务 id 反查 db、结构化日志、OpenTelemetry 埋点、跨进程 W3C traceparent 传播、日志级别纪律、边界类型纪律(含 id 持久化:不往业务行塞 trace_id);agent / RAG 场景在此基线上加 LLM / 工具 / 检索埋点与 GenAI 语义约定。Use this skill whenever writing or reviewing backend code that involves logging setup, OpenTelemetry tracing, structured logs, cross-process context propagation, choosing log levels (INFO vs DEBUG), correlating logs / traces / db to debug, defining types for boundary or inter-service data — and additionally agent orchestration / sub-agents, LLM / tool / retrieval calls, or GenAI semantic conventions. 适用 Python / Go / Java / Rust。Apply it even when the user only says things like "加点日志" "接一下 trace / instrument this" "set up observability" "这个错误怎么查不到" "这个请求怎么追踪",不限于显式提到规范时。目标:trace_id 串 trace/log、业务 id 反查 db,让线上问题最快定位。
---

# 可观测性与工程规范

## 何时应用
写或评审**任何后端服务**的代码时应用 —— 普通微服务(auth / 网关 / 业务服务)与 agent / 多 agent / RAG 知识库项目一视同仁,尤其涉及:日志接入、OpenTelemetry 埋点、跨进程 context 传播、日志级别选择、跨 trace/log/db 排障、边界数据建模;**agent 场景额外**涉及编排与子 agent、LLM/工具/检索调用。Python / Go / Java / Rust 通用。即使用户只说"加点日志""接一下 trace""这个错查不到""这请求怎么追",也按本规范做。

## 总纲
**用一条关联主线贯穿定位**:`trace_id` 串起 trace + log;业务库这一环靠**业务 id(order_id / run_id)同时挂成 span 属性**双向关联,**不在业务行存 `trace_id`**(trace 受采样 / 短保留,持久行存它多半是死指针 —— 见 references §2.1)。定位永远是
`trace 或业务 id → 查 trace 看哪步 → 查 log 看为什么 → 按业务 id 查 db 看数据对不对`,不靠时间戳猜。

## 五条铁律(所有服务,全部遵守)
1. **一次对外请求 = 一棵 trace**。入站请求 handler 是 root span,所有下游(DB / 缓存 / 跨进程调用 —— agent 场景下还有子 agent / LLM / 工具 / 检索)都是子 span。
2. **宽事件优先**:每步一条富字段结构化事件;事件名是稳定可聚合标识符,变量进字段;不写散文。
3. **三信号可关联**:每条 log 带 `trace_id`+`span_id`(随 trace 同采样 / 保留);**业务 id 挂成 span 属性**以按业务 id 反查 trace,**不往业务行加 `trace_id` 列**;需持久溯源处(AI 决策 / 金额 / 对客输出 / 合规)落自己拥有的 `correlation_id`,优先进专用审计 / outbox 表(见 references §2.1)。
4. **跨进程必传播 W3C `traceparent`**(HTTP / gRPC / 消息队列 / 任何 agent 协议都算)。不传 = trace 断成多棵互不相连的树 = 跨服务定位失效。**优先级高于功能**。
5. **标准在边界 + 后端无关**:跨进程 / 对外响应遵守 OTel 语义约定 + 类型校验(LLM 边界额外遵守 GenAI 约定);内部自由。**只依赖 OTel API/SDK + OTLP,应用代码不 import 厂商 SDK(Langfuse / Datadog 等);标准组件优先用官方 auto-instrumentation 自动埋点,手写 span 只补领域环节;厂商差异只在 Collector / exporter 配置层 → 换后端不重埋(见 references §1 铁律5 / §5.0 / 附录 C)。**

## 日志铁律
- 结构化优先:`event_name + fields`,**绝不字符串拼接**。日志即数据,不即叙事。
- 日志在活跃 span 内打出,`trace_id`/`span_id` 自动注入;**没有 `trace_id` 的 ERROR 视为 bug**。
- 上下文绑一次贯穿全程(语言原生 ambient context 机制,见 references 附录 B),不手传。
- 不要 log-and-throw;密钥/PII/客户机密在边界脱敏;LLM 完整 prompt/completion 走 DEBUG 或内容开关,不进默认日志。
- 必记(≥ INFO):决策点 + 依据、状态转移、每次跨进程 / LLM / 工具 / 检索调用的边界与结果状态、重试/回退/降级/补偿、每步 token + 成本(agent 场景)。

## 日志级别判据
判据:**这条日志在正常生产运行里读它有意义吗?** 有 → `INFO`;只有出问题深挖才看 → `DEBUG`。
- `INFO` 重建"发生了什么"的骨架(每步 / 每次调用 / 每次状态转移一条,**不刷高频内循环**)。
- `DEBUG` 重建"为什么"的细节(完整 prompt、推理、原始响应、命中 chunk、跨进程报文全文),**生产默认关、可按 trace 动态开**。
- `ERROR` = 失败且影响本次结果,必带 trace + 操作 + 输入标识符 + 栈;`WARNING` = 降级但请求继续。
- 排障时"光看 INFO 不知走到哪步" → **补 INFO,别常开 DEBUG**。

## 要开的 span
### 核心(所有服务)
- 入站 **server span**(root,带 `trace_id` / `tenant.id`,并把**业务 id**如 `order_id` / `run_id` 挂成 span 属性 → 供按业务 id 反查 trace),出站 **client span**(每次跨进程调用,**必须传 `traceparent`**),DB / 缓存 / 外部 API 子 span。
- 这三类基线 span **优先用官方 auto-instrumentation(自动 / 零代码)产出**(HTTP / gRPC / DB 驱动 / 框架中间件;包见 references 附录 C),手写 span 只补领域环节(下方 agent / LLM / 工具 / 检索)。

### Agent / RAG 扩展(在核心基线上加)
- agent:`invoke_workflow`(编排)、`invoke_agent`(子 agent,带 `agent.role` + 路由依据)、`inference`(LLM,带 `gen_ai.request.model` / `gen_ai.usage.*_tokens` / `gen_ai.response.finish_reasons`)、`execute_tool`。prompt 版本挂 inference span(`prompt.name/version/variant/tenant`)。
- **RAG 额外**开 `embedding` + `retrieval` span,记 query / top-k / 命中 chunk 的 **id+score** / 最终进上下文的 chunk id;**答案要可溯源到 chunk**。
- LLM 场景设 `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` 锁属性命名(GenAI 约定 2026 仍 experimental)。
- 持久化执行(Temporal/DBOS/Restate/自建)恢复时会丢 trace context,须持久化 `traceparent` 并重建。

## 类型纪律
边界锁结构、运行期校验;ID 用专名类型不混用;状态/角色用枚举式类型;**跨进程失败建模成结果类型**(序列化后异常栈必丢),别靠异常穿透;边界模型尽量不可变。**持久化纪律:只存自己拥有的业务 id / `correlation_id`,不把 ephemeral `trace_id` 当业务行外键**(trace 受采样 / 短保留;需 trace_id↔request_id 映射时用带 TTL 的轻量关联索引或 log,不污染业务热表)。各语言地道写法见 references §2 附录,id 持久化完整 rationale 见 §2.1。

## 三查工作流
对外响应回带 `trace_id`(调试用,受保留期约束)+ 业务 id(如 `order_id`)。① 查 trace:哪个 span 红/慢 →"哪一步"。② 查 log(同 `trace_id`):决策/状态/错误 →"为什么",不够细按此 trace 开 DEBUG 重放。③ 查 db(**按业务 id**,它本就是 span 属性):落库数据对不对。

## 强制生效(让规范咬人,而非形式化)

**没有 gate 的规范 = 形式化,必然漂移**——靠人工对照清单的规范,会在"没测试看的地方"悄悄烂掉,埋点的洞恰好出现在没人 gate 的模块(实证:某服务规范齐全、14 模块有 span,却有一个模块整条链路零埋点数月,单测/评审全绿,直到线上查不到 trace 才暴露)。**强制手段是采纳可观测性的一等交付物,不是事后补丁。** 立规范必须同时立 gate(机制按栈替换):
- **conformance 测试断 span 覆盖 + parent 正确,且会变红**:进程内捕获 span(语言的进程内 span 捕获器,见 references 附录 C),断言每条新 LLM/工具/检索/领域决策路径**发出领域 span 且 parent 正确**;**必带负例探针**(删 span / 断 parent → 测试变红),只测 happy-path 不强制任何东西。
- **gate 真在 CI 跑、能 fail build**:workflow 放工具识别的位置(GitHub Actions 只跑**仓库根** `.github/workflows/`)、paths 覆盖、**无 `|| true`/soft-fail**;**在真 PR 上验证 gate 确实触发**,别假设。
- **每条铁律 → 机制**:铁律5(禁厂商 SDK)→ 静态 import 契约(各语言 import 守卫,见 references 附录 C);铁律4(传 traceparent)→ 跨边界断言下游 span 同 trace_id;类型纪律 → 类型检查进 CI(见 references 附录 A)。
- **孤儿 span 陷阱**(最常见隐形失败):`create_task`/goroutine/线程池/队列交接丢 ambient context → 子 span 变孤儿 root,"埋了却不可见";跨脱离点捕获并重 attach context,conformance 断言异步两侧同 trace_id。
- **宪法条款**:仓库 `AGENTS.md`/`CONTRIBUTING` 写明"新 LLM/工具/检索/领域路径必须有 parent 正确的领域 span",指向本 skill。

达标线:**每条会被违反且能自动检测的铁律,都要有一个会让 CI 变红的 gate;检测不了的才进人工清单。立规范只产文档不产 gate = 没立。** 完整机制 + 实证见 §9。

## 何时读 references/standard.md

> **本 SKILL 是 `references/standard.md` §1–§9 的压缩镜像**(总纲 / 铁律 → §1、类型纪律 → §2 + §2.1、日志铁律 → §3、级别 → §4、span → §5、三查 → §7、强制生效 → §9;standard 另含 §6 日志接入、§8 检查清单、附录 A/B/C 各语言写法与工具链)。**改任一条规则必须同步两处。**

出现以下任一情况,读 `references/standard.md`:
- 需要**具体语言**(Python / Go / Java / Rust)的日志接入与类型纪律地道写法
- 做 **agent / 多 agent**,需要完整 span 拓扑与属性表
- 做 **RAG / 知识库**,需要完整检索链路埋点字段表
- 需要完整 span 属性表、落地检查清单,或某条规则背后的 rationale

落地前对照 `references/standard.md` 文末检查清单自查。
