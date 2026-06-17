# 服务可观测性与工程规范(语言无关)

> 总纲:**用一条关联主线贯穿定位**。`trace_id` 串起 trace + log;业务库这一环靠**业务 id(`order_id` / `run_id`)同时挂成 span 属性**关联,**不在业务行存 `trace_id`**(见 §2.1)。
> 定位问题永远是 `拿到 trace 或业务 id → 查 trace 看哪步 → 查 log 看为什么 → 按业务 id 查 db 看数据对不对`,绝不靠时间戳猜。
>
> 适用范围:**所有后端服务** —— 普通微服务(auth / 网关 / 业务服务)、以及 agent(单 agent、orchestrator/worker、流水线)、RAG/知识库;Python / Go / Java / Rust 通用。
> 读法:**普适核心(所有服务遵守):§1、§2 普适原则 + §2.1、§3、§4、§5.0、§7**;**§2 / §6 各取你的语言附录**(Python / Go / Java / Rust);**§5.1(agent)/ §5.2(RAG)按项目类型选增量**。
> 维护契约:本文 §1–§7 在 `SKILL.md` 有压缩镜像;改任一条规则必须**同步两处**,不留分叉。

---

## §1 五条普适铁律(语言/项目无关)

1. **一次对外请求 = 一棵 trace**。入站请求 handler 是 root span;所有下游(DB / 缓存 / 跨进程调用 —— agent 场景下还有子 agent / LLM 调用 / 工具调用 / 检索)都是子 span。agent 编排场景额外给整棵 trace 一个 `run_id`。
2. **宽事件优先**:每个处理步骤输出一条富字段结构化事件,而非散文文本。事件名是稳定标识符(可聚合),变量进字段。指标从字段派生,不从 grep 派生。
3. **三信号可关联**:trace 串 span;每条 log 带 `trace_id`+`span_id`(随 trace 同采样 / 保留);**业务 id(`order_id` / `run_id`)挂成 span 属性**以按业务 id 反查 trace。**不往业务行加 `trace_id` 列**——trace 被采样、保留期短,持久业务行存它多半成死指针(详见 §2.1)。
4. **跨进程必传播 context**:任何跨进程边界(HTTP / gRPC / 消息队列 / agent-to-agent 协议)必须传播 W3C `traceparent`,入站 extract、出站 inject。**不传播 = trace 断成多棵互不相连的树 = 跨服务定位失效**。这是头号正确性要求,优先级高于功能。
5. **标准在边界 + 后端无关**:跨进程、对外响应遵守 OTel 语义约定 + 类型校验;LLM 边界额外遵守 GenAI 语义约定;内部实现自由。**只依赖 OTel API/SDK + OTLP exporter,应用代码不 import 厂商 SDK(Langfuse / Datadog 等);标准组件优先用官方 `opentelemetry-instrumentation`(自动 / 零代码)埋点,手写 span 只补领域环节;厂商差异只在 Collector / exporter 配置层 —— 换后端(SigNoz / ClickStack / Langfuse,均支持 OTLP)不改一行埋点。**

---

## §2 类型纪律

**普适原则(四语言都成立):**
- 在**边界**锁死数据结构、运行期校验;内部拿到的是可信类型。
- **ID 不用裸字符串**,用语言各自的"专名类型",防止参数传反。
- **状态/角色/事件名用枚举式类型**,不用裸字符串。
- **跨进程的失败建模成数据,不靠异常穿透**——一旦序列化,栈帧就没了,失败必须是返回值/结果类型的一部分。
- 边界数据模型尽量**不可变**,防下游误改后写错指标。
- **持久化只存自己拥有的 id**:业务 id / `correlation_id` 才落库;`trace_id` 是 ephemeral 链接,不当业务行外键(详见 §2.1)。

### §2.1 id 持久化与关联(普适,所有服务)

**不要在业务写入里塞 `trace_id` 列。** 问题不在字节(一列 16–32 字节,存储上微不足道),在**生命周期错配 + 耦合**:

- **生命周期错配(致命)**:trace 被采样、短保留(典型:1% 平采样 + 偏向错误 / 高延迟的尾采样,代表性 trace 留 ~30 天;头 / 尾采样意味大量 trace 根本不留)。业务行持久(存数年)。存进业务行的 `trace_id` 绝大多数指向一条已被采样丢弃或已过期的 trace = 死指针。
- **schema 耦合**:把持久业务表绑到一个由可观测后端拥有、生命周期完全不同的字段。
- **索引代价**:真要按它查就得建索引 → 热表写放大 + 索引体积;不建索引,这列查不动,等于摆设。

**业界标准做法(都不是"往业务表塞 trace_id"):**

1. **区分持久 `correlation_id` 与 ephemeral `trace_id`**。`trace_id` 不透明、每请求变、无业务含义(on-call 调试能用,但没法按"订单 #12345"查)。要持久存,存你自己拥有、带业务含义的 `correlation_id` / `run_id` / `order_id`,不是裸 OTel `trace_id`。
2. **反转查找方向**:把业务 id 作为 **span 属性**,反过来按业务 id 查可观测库(`WHERE attributes->>'order.id' = '...'`)。业务 id 本就是业务主键、已在库里,只要它也是 span 属性,**零新增列**即可从业务 id 反查到 trace。
3. **传播用 baggage,高基数 id 别进 metric label**。入口设业务 correlation id,用 baggage 传播,使其出现在 spans / logs / metric exemplars;Collector 的 baggage processor 自动注入;高基数 id 进 metric 标签会基数爆炸,指标到 trace 的链接靠 **exemplar**。

**真要 `trace_id` ↔ `request_id` 映射时**:维护一个轻量 correlation 索引(Redis / 专用表)存 `requestId ↔ traceId ↔ 时间戳`,带 ~24h TTL —— 独立索引,不污染业务热表。常见实战:每请求生成 / 传播一个 UUID `correlation_id` 存进 contextvars,注入日志、并作为 `request_id` 写进 trace 元数据;**持久 id 是 `correlation_id`,trace 关联走日志**。

**唯一该持久落库的场景:审计 / 溯源,且进专用 store**(AI 决策、报价 / 金额、对客最终输出、合规):
- 审计事件在**发布到日志管道之前先落进持久存储**(下游日志系统挂了,审计仍正确);
- 保留期对齐最严监管(如 SOX 6 年、PCI 滚动 12 个月),不可变 / 校验和防篡改;
- 用**业务上下文**丰富(用户、记录类型、改了哪些字段),别只存一堆 id;
- 这张专用审计表里放 `correlation_id`(+ 尽力而为的 `trace_id` 链接),而**不是**给每张业务表加列。

### 附录 A·Python
- `pyright`/`mypy` **strict** 进 CI 门禁;公共函数(agent/tool/handler)全标注。
- 边界数据一律 **Pydantic v2**,边界 `model_validate`。
- `NewType` 区分 ID:`RunId = NewType("RunId", str)`。
- `Literal` 表状态/角色/事件名。
- 结果用判别联合:`class Ok(BaseModel): status: Literal["ok"]; ...` / `Result = Ok | Err`,调用方 `match`。
- 不可变事件:`model_config = ConfigDict(frozen=True)`。可换 agent 用 `Protocol` 做结构化子类型。

### 附录 A·Go
- `go vet` + `staticcheck` + `golangci-lint` 进门禁。
- 专名 ID 用 defined type:`type RunID string`(编译期不与普通 string 混用)。
- 边界结构体用 `go-playground/validator` 等做标签校验。
- **`context.Context` 一路下传**(它同时携带 trace 上下文、取消、deadline);函数签名第一参数即 `ctx`。
- 错误是值:`return zero, fmt.Errorf("...: %w", err)` 包装;用 sentinel/typed error(`errors.Is/As`)替代异常穿透;**不要 `panic` 跨边界**。
- 状态用 `type State string` + 常量集合;DTO 尽量值传递保持不可变意图。

### 附录 A·Java
- 编译器 `-Werror` + Error Prone / NullAway 进门禁。
- DTO 用 `record`(天然不可变);边界用 Jakarta Bean Validation(`@NotNull`/`@Valid`)。
- 专名 ID 用 wrapper `record RunId(String value){}`,不用裸 `String`。
- 判别联合用 **sealed interface + record**:`sealed interface Result permits Ok, Err {}`,配合 `switch` 模式匹配穷尽。
- 状态用 `enum`;避免 `null`,用 `Optional` / `@Nullable` 标注。

### 附录 A·Rust
- `cargo clippy -- -D warnings` 进门禁;库内 `#![forbid(unsafe_code)]`(无 FFI 时);公共 API 显式标注类型。
- 专名 ID 用 newtype:`struct RunId(String);` + `#[derive(Clone, Debug, PartialEq, Eq, Hash)]`(编译期不与普通 `String` / 别的 ID 混用)。
- 边界数据用 `serde` + `#[serde(deny_unknown_fields)]` 反序列化即校验;复杂约束用 `garde` / `validator`。
- 失败是值:返回 `Result<T, E>`,错误类型用 `thiserror` 定义(库层),`anyhow` 仅应用顶层;**跨进程失败序列化成结果类型,不靠 `panic` 穿透边界**(panic 跨 `await` / 线程 / FFI 不可靠)。
- 状态/角色/事件名用 `enum`,`match` 穷尽;边界 DTO 默认不可变(绑定默认 immutable,不暴露 `&mut`,共享只读用 `Arc`)。

---

## §3 日志铁律(语言无关)

1. **结构化优先,永不字符串拼接**。`message` = 短事件名(snake_case),变量全进字段。
   - ✅ `info("tool_call_failed", tool="search", code="timeout", attempt=2)`
   - ❌ `info("Failed to call search because timeout on attempt 2")`
2. **日志即数据,不即叙事**。事件名是可查询/聚合的标识符,不是给人读的句子。
3. **trace 绑定是默认**:日志在活跃 span 内打出,`trace_id`/`span_id` 由桥/处理器自动注入。**没有 `trace_id` 的 ERROR 视为 bug**。
4. **上下文绑一次贯穿全程**:进入一次 run 时绑 `run_id`/`tenant_id`/`agent_role`(Python contextvars / Go context / Java MDC),之后每条日志自动带,不手传。
5. **不要 log-and-throw**:要么处理并记录,要么向上抛由处理者记录,别既记录又抛。
6. **永不记录**:密钥/token/凭证、完整 PII、客户机密原文。在日志边界脱敏。
7. **LLM 完整 prompt/completion 不进默认日志**:体积大且常含客户数据 → 走 DEBUG 或 OTel 内容捕获开关(opt-in、可采样)。
8. **必记点(均 ≥ INFO)**:路由/决策点及其依据、状态转移、每次 LLM/工具/检索/跨进程调用的边界与结果状态、重试/回退/降级/补偿、每步 token 与成本(也作 metric)。

---

## §4 日志级别(INFO vs DEBUG 判据)

> 判据:**这条日志在"正常生产运行"里读它有意义吗?** 有 → `INFO`;只有"出问题深挖时"才看 → `DEBUG`。
> 一句话:**INFO 重建"发生了什么"的骨架,DEBUG 重建"为什么"的全部细节。**

| 级别 | 何时用 | 生产默认 | 告警 |
|---|---|---|---|
| `ERROR` | 失败且影响本次请求结果(调用最终失败、不可恢复的工具错误、非法状态转移、跨进程调用彻底失败无法补偿)。**必带 trace + 操作 + 输入标识符 + 异常栈**。 | 开 | 是 |
| `WARNING` | 降级但请求继续(重试、回退备用 prompt/模型、超时用缓存、输出未过校验已重试、部分失败已补偿)。 | 开 | 视情况 |
| `INFO` | 业务里程碑与状态转移。**粒度 = 每个 step / 每次调用 / 每次状态转移一条**;目标:只读 INFO 即可重建一次 run 的骨架。**不刷高频内循环**。 | 开 | 否 |
| `DEBUG` | 深挖细节:完整 prompt、模型中间推理、原始工具响应、检索命中的 chunk、跨进程报文全文。体积大、含敏感数据、仅 deep-dive 看。 | 关(可按 trace 动态开) | 否 |

补充:OTel 无标准 TRACE 级,最细用 `DEBUG`;生产默认 INFO,DEBUG 按环境变量或按特定 `trace_id` 动态开(采样式重放);**排障时若"光看 INFO 不知走到哪步",是 INFO 漏了状态转移点——补 INFO,而不是常开 DEBUG**。

---

## §5 OTel Span 拓扑

### §5.0 服务基线拓扑(所有服务)
任何服务的最小 span 拓扑:**入站 server span = root**(带 `trace_id` / `run.id`、`tenant.id`)→ 每次**出站 client span**(HTTP / gRPC / MQ,**必须 inject `traceparent`**)→ DB / 缓存 / 外部 API 子 span。trace 是请求在系统里的因果树;§5.1 / §5.2 是 agent / RAG 在此基线上的**增量**。

**这三类基线 span 优先用官方 `opentelemetry-instrumentation`(自动 / 零代码)产出**,而非手写:Python 用 `opentelemetry-instrument` + `opentelemetry-instrumentation-{fastapi,requests,sqlalchemy,…}`;Go 用 `otelhttp` / `otelgrpc` 等 contrib;Java 用 `-javaagent:opentelemetry-javaagent.jar`;Rust 用框架中间件(`tower-http` / `tracing`)。手写 span 只补自动埋点拿不到的领域环节(§5.1 / §5.2)。

### §5.1 Agent 增量(在 §5.0 基线上)

> 现状:GenAI 语义约定截至 2026 多为 **experimental**,主流后端已支持。
> 生产显式设 `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` 锁属性命名,避免依赖升级悄改 span/属性名打乱看板与告警。
>
> **接入 LLM 可观测平台(Langfuse / Phoenix 等)优先走 OTLP ingestion** —— 当作一个 OTLP 后端接,不在应用代码引其 SDK(Langfuse 已支持 OTLP)。

| 概念 | OTel span / 操作 | 关键属性 |
|---|---|---|
| 编排 | invoke workflow span | `gen_ai.operation.name=invoke_workflow` |
| 调用子 agent | invoke agent span | `gen_ai.agent.name`, `agent.role`, 路由依据 |
| 每次 LLM 调用 | inference span | `gen_ai.request.model`, `gen_ai.usage.input_tokens/output_tokens`, `gen_ai.response.finish_reasons` |
| 每次工具调用 | execute tool span | 工具名、入参标识符、结果状态 |
| prompt 版本 | 挂在 inference span 上 | `prompt.name/version/variant/tenant` |

拓扑铁律:子 agent 之间若不直连、只经编排者中转,则所有 agent span 都挂在编排 span 下,trace 天然呈**树**(= 编排拓扑的镜像),而非网,便于定位。

**持久化执行(durable execution,如 Temporal / DBOS / Restate / 自建)专项**:工作流跨重启/恢复时默认会**丢失原 trace context**,恢复后那段会脱离原 trace。必须把 `traceparent` 一并持久化进工作流状态、恢复时重建。当成显式设计项,不要假设自动。

### §5.2 RAG / 知识库 增量
在 §5.1 基础上**加开检索链路的 span**(GenAI 约定含 embeddings、retrieval span)。理由:RAG 的两类失败——**检索没召回**(知识在库里但没取到)与 **生成幻觉**(取到了但模型瞎编)——只有靠 retrieval span 才能区分;没有它,你看到错误答案根本不知道该修检索还是修 prompt。

| 概念 | span | 必记字段 |
|---|---|---|
| 向量化 query | embedding span | 嵌入模型、维度、耗时 |
| 检索 | retrieval span | 原始 query、top-k、命中 doc/chunk 的 **id + score**、检索耗时 |
| 重排(若有) | rerank span | 重排模型、重排前后顺序变化 |
| 组装上下文 | (挂检索/生成 span) | **最终进入上下文的 chunk id 列表**(provenance) |
| 生成 | inference span | 同 §5.1,外加引用了哪些 chunk |
| 接地校验(若有) | eval/score | grounding/faithfulness 分、是否有未被来源支持的断言 |

知识库专属铁律:**答案要可溯源到 chunk**。把"最终进上下文的 chunk id"挂到 span,排障时一眼看出"模型是依据哪几段编的"。需持久审计时(ToB / 合规),把答案 + chunk id + 自己拥有的 `correlation_id`(+ 尽力而为的 `trace_id` 链接)落进**专用审计 / outbox store**(按 §2.1),而非给每张业务表加 `trace_id` 列;`trace_id` 受采样 / 保留约束,仅作尽力而为链接。

---

## §6 日志接入(选你的语言)

目标:一处配置,全项目自动产出 `trace_id`-绑定的结构化日志,经 OTLP 进后端。**两层别混**:关联层(把 trace context 注入每条日志)+ 导出层(把日志作为一等遥测发出)。

### 附录 B·Python
- 库:`structlog`(结构化)+ OTel 日志桥 `LoggingHandler`(导出)。
- 关联:自定义 processor 从 `trace.get_current_span()` 取 id 注入;或 contrib 的 `LoggingInstrumentor` / 环境变量 `OTEL_PYTHON_LOG_CORRELATION=true`。
- 导出:`LoggerProvider` + `BatchLogRecordProcessor(OTLPLogExporter())` + `LoggingHandler` 挂到 root logger。
- **坑**:必须在任何库调用 `logging.basicConfig` 之前初始化,否则 trace 注入失效。

### 附录 B·Go
- 库:标准库 `slog` + 桥 `go.opentelemetry.io/contrib/bridges/otelslog`。
- 一行接通:`slog.SetDefault(otelslog.NewLogger("your-service"))`,之后 slog 调用自动带 OTel trace context。
- **坑**:必须用带 Context 的方法 `logger.InfoContext(ctx, ...)`(传当前 ctx),活跃 span 才能关联。
- 高吞吐替代:slog 直接写 JSON 到 stdout,由 OTel Collector 摄入时转 OTel 日志记录(转换成本移出进程),但要自己把 trace 字段注入 JSON(用包装 handler)。

### 附录 B·Java
- 库:Log4j2 或 Logback,经 OTel **MDC** 集成(pattern 里 `%X{trace_id}` / `%mdc{trace_id}`)。
- 关联(两选一):挂 java agent `-javaagent:opentelemetry-javaagent.jar`,自动填 MDC;或用 SDK + `OpenTelemetryAppender`(logback)/ `opentelemetry-log4j-context-data`(log4j2)。
- 导出(两选一):OTLP appender 直发 Collector(简单,有导出开销);或写 stdout/文件 + Collector filelog receiver 采集(复用已有日志基础设施)。
- pattern 示例:`... trace_id=%X{trace_id} span_id=%X{span_id} - %msg%n`。

### 附录 B·Rust
- 库:`tracing`(结构化 span + event,日志与 trace 同一套 API)+ `tracing-subscriber`(订阅/格式化)+ `tracing-opentelemetry`(桥到 OTel)+ `opentelemetry-otlp`(导出)。
- 关联:`OpenTelemetryLayer` 把 `tracing` span 映射成 OTel span,event 自动带当前 `trace_id`/`span_id`;`Registry().with(otel_layer).with(fmt_layer).init()`。
- 埋点:`#[tracing::instrument]` 给函数开 span;结构化字段 `info!(tool = "search", code = "timeout", attempt = 2, "tool_call_failed")`(message 是短事件名,变量进字段)。
- 传播:`global::set_text_map_propagator(TraceContextPropagator::new())`;出站 `inject_context` 进 header,入站 `extract` 后 `span.set_parent(cx)`。
- **坑**:async 里开 span 必须用 `#[instrument]` 或 `fut.instrument(span)`,**不要让 `span.enter()` 的 guard 跨 `.await`**(会把别的 task 时间算进来 / 上下文错乱)。

---

## §7 三查工作流(最快定位)

对外响应回带 `trace_id`(调试入口,受保留期约束)与业务 id(如 `order_id`),客户报问题即拿到入口。

1. **查 trace**:看 span 树 → 哪个子 agent / 哪次 inference / 哪个工具 / 哪次检索 span 红了或慢了。→ "**哪一步**"。
2. **查 log**(同 `trace_id`):跳到该 span 的 INFO/ERROR → 决策、状态转移、错误详情;不够细按此 `trace_id` 动态开 DEBUG 重放看完整 prompt/检索 chunk。→ "**为什么**"。
3. **查 db**(**按业务 id**,如 `order_id` / `run_id` —— 它本就是 span 属性):业务表按业务 id 捞当时落库的数据(抽取结果 / 检索 chunk id / 中间值),与 LLM 输出对账。→ "**数据对不对**"。

三者靠**同一 trace(`trace_id`)+ 业务 id**串联,不在三个系统里靠时间戳猜对应:log / trace 同 `trace_id`,db 这环按业务 id(它是 span 属性)关联,**不依赖业务行存 `trace_id`**。

---

## §8 落地检查清单

- [ ] 类型门禁进 CI(Python: pyright/mypy strict;Go: vet+staticcheck;Java: -Werror+NullAway;Rust: clippy `-D warnings`)
- [ ] 边界数据有 schema 校验;跨进程失败建模成结果类型,不靠异常穿透
- [ ] 日志初始化在任何 `basicConfig`/默认 logger 之前;Go 用 `*Context` 方法;Java 配好 MDC pattern;Rust 用 `#[instrument]`、`enter()` guard 不跨 `.await`
- [ ] 日志全部 `event_name + fields` 形式,无散文拼接
- [ ] 一次 run 骨架仅靠 INFO 可重建;DEBUG 生产默认关、可按 trace 开
- [ ] 密钥/PII/客户机密在日志边界脱敏;LLM 全文走 DEBUG/内容开关
- [ ] **跨进程一律传播 W3C `traceparent`**;持久化执行恢复时重建 trace context
- [ ] LLM / agent 场景:`OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` 已设
- [ ] 埋点只依赖 OTel API/SDK + OTLP;应用代码无厂商 SDK import;标准组件用 `opentelemetry-instrumentation` 自动埋点;厂商差异在 Collector / exporter 层
- [ ] RAG 项目:开 embedding/retrieval span;答案可溯源到 chunk id
- [ ] 业务实体 id(`order_id` / `run_id`)是 span 属性 → 可按业务 id 反查 trace(零新增列);**不往业务行加 `trace_id` 列**
- [ ] 持久溯源(AI 决策 / 金额 / 对客输出 / 合规)落自己拥有的 `correlation_id`,进专用审计 / outbox store(非热表);`trace_id` 仅作受采样 / 保留约束的尽力而为链接
- [ ] 对外响应回带 `trace_id`(调试)+ 业务 id
