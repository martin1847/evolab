# 附录 B — 数据访问纪律（连接 · 读 · 写）

> hub `agent-backend-standard` 的一章。来源:某 agent 服务的来信(慢查询排查)+ 对抗验证修正 + 某 MyBatis/JTA 微服务栈读连接泄漏排查。
> **范围**:连接 / 事务 / 读写纪律是**通用持久层后端**规则,**非 agent/LLM 专属**——写任何碰 DB 的服务都适用,别因 hub 名带 "agent" 就跳过本章(实证:正因误判"这是普通业务微服务、不是 agent 后端"而没读本章 → 读服务连接全漏,见 §R)。

## 0. 本质

**写操作按"关键性 + 一致性需求"分级,用最轻机制实现"记账型写"。** "记账型写(bookkeeping write)"画像:访问计数 / `last_accessed_at` / 使用统计 / 命中数 / "已读"标记 / 埋点计数——**best-effort、可丢、无强一致、常打热行、高频**。把它当普通业务写(进主链路、进业务事务、逐行写)是这类时延问题的通用成因。

实证(某 agent 服务):agent memory 召回后更新 `access_count`/`last_accessed_at`(~100 行小表、主键更新)慢到 **30.3s**。根因非 SQL/索引,是**事务纪律**:① 跑在用户同步主链路;② 复用召回的外层事务,行锁横跨整段召回(含 LLM/IO);③ 逐行 N 次 `UPDATE`。热行 + 长锁窗 + 高频 = 写争用 pile-up。

## R. 读查询 / 连接生命周期 —— MUST

**读也占连接。** 每个查询从池借一个连接;**不释放就漏**——不是并发才漏,**顺序几个读就能抽干池**。泄漏判据:低流量(单人测)下 `acquisition timeout`,是"跑几个就满"而非"高并发才满"。

**连接释放靠框架的事务边界,不是"读完自动还"。** 事务型 ORM/桥接(MyBatis `MANAGED`、JTA 容器托管)把连接生命周期**交给事务**:进事务借、出事务还。**非事务读没有事务边界 → 没人触发还池 → 连接挂死**(读版 idle-in-transaction)。

1. **读用弱事务 / autocommit** —— 读查询用最轻机制,**连接用完即释放**;别把读挂在"等一个不存在的事务"上。
2. **只有交易核心链路用强事务** —— 写/状态机/余额/需原子绑定的才 `@Transactional` 强事务(且遵 §2 不持锁跨 LLM/外部)。
3. **框架桥接看清"谁还连接"** —— ORM 若配"连接交容器/JTA 管"(如 MyBatis `MANAGED` + `closeConnection=false`),则**每条访问路径必须真有事务边界**,否则漏。读路径要么给只读弱事务边界、要么切 autocommit 让 ORM 每查询释放。

**机械判据(可 lint,进硬层)**:`transactionManager=MANAGED` + `closeConnection=false`(或等价"连接交容器管") 且**存在无事务注解的读方法** = 连接泄漏反模式。

**实证(某 MyBatis(MANAGED)+JTA/Quarkus 微服务栈)**:多个只读服务的 `mybatis-config` 用 `MANAGED` + `closeConnection=false`(为 JTA 写路径设计——连接交容器管)。但读方法**无 `@Transactional`** → 无容器事务 → MyBatis 不关、容器也不管 → **连接不还池**。低流量(单人测)下几次读就 `SQLException: acquisition timeout`。同环境 A/B(仅翻这一行、池调小放大信号)坐实:`closeConnection=true` 连打 12 次 0 泄漏、`false` 第 2 次即 `acquisition timeout`。修:纯读服务 `closeConnection=true`(MyBatis SqlSession 关时释放连接),有写服务的读方法加只读弱事务让容器释放。

**诊断技巧(通用,接口疑挂死/空 → 先绕前端直打)**:`curl` 类客户端 + `timeout` 直打 RPC/HTTP —— **exit=timeout** 是真 hang;**返 error** 看 message(此例 `acquisition timeout`)+ 上游耗时;**多服务抽测**判全局(PG 满)vs 单服务(该服务连接/查询)。**acquisition timeout + 低流量 = 连接泄漏,非并发打满。**

## 1. 记账型写(best-effort / 可丢 / 无强一致)—— MUST

1. **移出用户请求主链路** —— 异步 / fire-and-forget,用户响应不等它。(fire-and-forget 必须:持 task 强引用防 GC、错误记日志不静默吞、失败不影响主响应。)
2. **不复用业务请求事务** —— 否则行锁拉到整个请求(含 LLM / 外部 IO)时长。**agent 化要命点:绝不在 LLM / 外部调用期间持有 DB 事务。**
3. **per-statement 提交(autocommit)** —— 每条语句独立提交,锁窗缩到单语句。
   ⚠️ 措辞精确(验证修正):数据库**没有"无事务"**——每条语句都在事务里;"去事务" = 显式设 **autocommit / per-statement 隐式提交**,不是"省掉 BEGIN"。且驱动常默认 autocommit **OFF**(psycopg 坑:不显式 `autocommit=True` 仍会开隐式事务并持锁)。
4. **批量化** —— 循环里 N 条单行 `UPDATE` 合成一条 `UPDATE ... WHERE id IN (...)`。
   ⚠️ **lost-update(验证新增,必守)**:批量/异步合并计数 **MUST 服务端增量** `SET count = count + :delta`,**不能 read-modify-write 或写客户端算好的绝对值**——否则异步合并**写坏计数**(不只是丢几次)。
5. **MVCC / HOT 注意(验证新增)**:热行高频 UPDATE 产生死元组;UPDATE 只有"**不碰索引列 + 页有空间**"才是 HOT 廉价写。→ `last_accessed_at` 之类**必须不加索引**,表可能要降 `fillfactor`,否则"廉价写"变索引写放大 + autovacuum 负担。
6. **旗标门控上线**(默认 OFF → 字节级零变化,便于灰度/回退)。

## 2. 业务关键写 —— 保留事务/同步/强一致
订单、支付、状态机扭转、余额、任何需与其它写原子绑定或"不能丢"的写。**判不准时按"关键写"处理。**

**⚠️ 但"保留事务"≠"持锁跨 LLM/外部/async"——这条对关键写同样是 MUST(实证补强)。**
"关键写"保留的是**原子性/一致性**,不是"把事务/行锁持开很久"。§1.2「绝不在 LLM/外部调用期间持有 DB 事务」
**对业务关键写(含状态机扭转)一样适用**——最易误读的点:把写判成"关键"→"保留事务"→就把 `FOR UPDATE`/事务
**持过了下游执行/LLM/外部调用**,正中 idle-in-transaction 反模式。**§2 只说"保留事务"、不重复这条 caveat 时,反而
把状态机写指向这个坑。**

**正确姿势 = 短原子写 + 锁外执行**:
- 状态机扭转用**单条原子语句**完成 claim/迁移,拿 `RETURNING` 判成败、**立即释放**;队列 claim 用
  `UPDATE ... WHERE id=(SELECT id ... WHERE status='queued' ... FOR UPDATE SKIP LOCKED) RETURNING *`
  ——`FOR UPDATE` 只活在这一条语句内(微秒),绝不跨 app await。
- LLM / 执行 / task-status 同步之类下游工作,一律在**原子写提交之后、任何持锁之外**做。
- 需与其它写原子绑定 → 用**短事务**包住那几个写即可,同样不跨任何 LLM/外部/async。

**实证(某 agent 服务的委派队列)**:worker claim 用 `SELECT ... FOR UPDATE` 持锁后 await 执行 / task-status
同步,行锁横跨整段——线程模式下直接死锁;prefork(多进程)部署下持 idle-in-transaction 事务 **279s+ 不释放**。
改单条原子 `UPDATE ... FOR UPDATE SKIP LOCKED ... RETURNING` 后根除。
**机械判据(可 lint,进硬层)**:任何 `with_for_update()` / `FOR UPDATE` 之后、同一事务作用域内 `await` 非 DB 工作
(LLM/tool/http/子任务)= 反模式,不论是不是"关键写";`@transaction` 方法体内 `await` 外部调用同理。

## 3. 一句话
> 读查询:**弱事务 / autocommit,连接用完即释放**;只交易核心链路用强事务。框架"连接交容器管"(MANAGED+closeConnection=false)时,每条读路径也必须有事务边界,否则漏连接。
> 记账型写(计数/时间戳/统计,best-effort 可丢):**移出主链路 + 不借业务事务 + per-statement 提交 + 批量服务端增量**;热行列不加索引。
> 业务关键写:保留原子性/一致性 —— 但**同样不持锁跨 LLM/外部/async**(短原子写 `... FOR UPDATE SKIP LOCKED ... RETURNING` + 锁外执行)。
> "去事务" = 显式 autocommit,不是省 BEGIN;批量计数 = 服务端 `+= delta`,不是写绝对值。

## 来源
PG 锁持到事务尾:postgresql.org/docs/current/explicit-locking.html;idle-in-transaction 反模式;write-behind/cache-aside(AWS/MS,显式划"关键写不适用");lost-update:baeldung.com/cs/concurrency-control-lost-update-problem;HOT:postgresql.org/docs/current/storage-hot.html。
