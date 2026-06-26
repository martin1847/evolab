# II-9 — 安全 · 护栏 · 生成操作的有界执行

> hub `agent-backend-standard` 的一章。来源:某 agent 服务的来信(内部) `LETTER_engineer-standards_agent-sql-governance`(2026-06-24,DataFabric)+ 对抗验证修正。

## 0. 本质

**执行 agent / LLM 生成的操作 = 执行不可信、无界的输入,直接作用于共享资源。** LLM 可能生成 `SELECT pg_sleep(600)`、无 `LIMIT` 的笛卡尔积、扫全表聚合。没治理,一次坏生成就能耗尽一个 worker / 连接池 / 内存,多租户下炸到所有人(blast radius)。关键字黑名单挡不住(不防慢、不防大、不防资源耗尽)。

实证(某 agent 服务 run_sql 24h):p50 3.2s / p95 47.8s / max 102.6s。路径几乎无边界:无超时、无并发上限、行数靠"SQL 串含 limit 子串"判断(易绕、且全量读内存)、同步阻塞跑在 event loop 上(慢查询冻住整 worker、连坐同 worker 的鉴权小查询)、span catch 异常后记 `ok=True`(慢和失败混一起查不出)。

## 1. 安全边界优先(承重层)—— MUST(验证修正:不是六条平级,有层级)

这三条是**安全边界**,timeout 全挂了它们还在:
1. **只读连接 / 最小权限**:执行生成查询用 read-only role(写另走受控路径)。结构性保证。
2. **参数化 / 不可信输入处理**:生成内容当不可信输入;关键字黑名单是弱兜底(OWASP:deny-list "STRONGLY DISCOURAGED")。
3. OWASP LLM05(Improper Output Handling)/ LLM06(Excessive Agency)**只背书这层姿态**(least-priv / read-only / 参数化 / HITL),**不背书下面的机制**——引用别张冠李戴。

## 2. 资源治理(blast-radius / 可用性控制)—— MUST

在**汇聚所有入口的 choke point** 上套:
1. **硬超时,两层**:
   - **驱动/引擎层**(PG `statement_timeout` / MySQL `MAX_EXECUTION_TIME` / SQL Server Resource Governor)—— 这才能真正取消服务端工作。(去 PG 特化:写成"驱动层能取消服务端工作的机制"。)
   - 应用层兜底(`wait_for`)。⚠️ **线程杀不掉**:阻塞查询 offload 到线程后,应用层超时只让"等待方"返回、**线程仍在跑**(CPython #107505;libpq 不应 Python signal)。驱动层超时不可省。(PG17+psycopg3.2 改善了取消,但原则不变。)
2. **并发上限**(按 worker/租户/数据源)。⚠️ **槽必须持有到"真实工作"完成,不是"等待方"返回**——超时/取消/异常**任一退出路径**提前释放槽,cap 就只限了等待者(某 agent 服务评审抓到的真 bug)。
3. **结果规模上限**:可靠 `LIMIT` 注入(**不靠字符串子串**)+ 流式 / `fetchmany`,禁全量读内存。(LIMIT-子串弱是由 SQLi-黑名单类比推理,非直接来源,但成立。)
4. **不阻塞 event loop**:同步阻塞 DB/IO offload 到线程池。⚠️ offload 只解"不连坐",**不解"跑多久"**——超时/并发/行数一个不能少。

## 3. 覆盖与失控(验证新增)

- **覆盖所有入口(choke point)**:多个 agent 入口能执行 SQL 时,治理放共同汇聚层。某 agent 服务有一入口(`data_call_resource`)**绕过**另一入口的全部治理,评审才抓到——**只覆盖一条分支 ≠ 全覆盖**。
- **DB choke point 不够防 agent 失控环**(验证补的 hidden-loop gap):agent 超时后可**重新规划再发** → 还需 **workflow 级迭代/步数上限 + 成本预算**(见 II-7 韧性 / III-11 成本)。"单 choke point"对 DB 资源边界成立,对 agent runaway 不充分。

## 4. 诚实可观测性(交叉引,不在此重复)

捕获到的失败必须让 span `ok=False` + `error_type`;记**脱敏**维度(`db_type`/`rows_returned`/DB 侧 `duration_ms`/`timeout_ms`/`cancelled`/`error_type`,**不记** SQL 原文/参数/客户数据)。**埋点本体与 GenAI 语义约定 = canonical 在 `observability-standard`**(本章只点要求,不重复规则)。

## 5. 一句话
> 执行生成操作 = 执行不可信无界输入。**先立安全边界(只读/最小权限/参数化,OWASP 背书),再套资源治理**(驱动+应用双层超时、并发上限[槽持到真实结束、覆盖所有退出路径]、可靠 LIMIT+流式、不阻塞 loop),覆盖所有入口 + workflow 迭代上限。少一样,一次坏生成炸全租户。
> **对抗式评审值得跑**:某 agent 服务 3 轮才收敛,抓出"入口绕治理""取消漏槽"两个单测+自审没发现的真 bug。

## 来源
PG statement_timeout;CPython #107505(线程不可杀);psycopg cancel;OWASP SQLi cheat sheet(deny-list discouraged)/LLM05/LLM06;只读副本;SQL Server Resource Governor;SQLAlchemy server-side cursors;asyncio offload;noisy-neighbor 池耗尽。
