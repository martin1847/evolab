# 附录 B — 数据访问纪律（连接 · 读 · 写）

> hub `agent-backend-standard` 的一章。来源:某 agent 服务的来信(慢查询排查)+ 对抗验证修正 + 某 MyBatis/JTA 微服务栈读连接泄漏排查。
> **范围**:连接 / 事务 / 读写纪律是**通用持久层后端**规则,**非 agent/LLM 专属**——写任何碰 DB 的服务都适用,别因 hub 名带 "agent" 就跳过本章(误判"这是普通业务微服务"而跳读的后果见 §R)。

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
6. **旗标门控上线**(goal / owner 标明需灰度时:默认 OFF → 字节级零变化,便于灰度/回退;其余直接落地 + kill-switch,附录 A §3.1)。

## 2. 业务关键写 —— 保留事务/同步/强一致
订单、支付、状态机扭转、余额、任何需与其它写原子绑定或"不能丢"的写。**判不准时按"关键写"处理。**

**共享持久状态并发优先 DB 原语**:项目已有 PostgreSQL,且涉及跨请求/跨实例的共享状态竞争时,先用约束、条件原子写和短事务,确有需要才显式加锁;进程内锁不替代跨实例一致性。

| 要保护的业务不变量/操作 | 最轻选择与边界 |
|---|---|
| 业务键唯一、重复创建/幂等键占位 | 非空业务键 + `UNIQUE`,配合 `INSERT ... ON CONFLICT`;先查后插不防并发重复 |
| 计数、余额/库存扣减、单行状态转移 | 服务端增量/条件 `UPDATE ... WHERE ... RETURNING`;把资格、旧状态或版本放进条件 |
| 多个写同成败、必要的读后再改 | 短事务,需要时 `SELECT ... FOR UPDATE`;多对象按一致顺序锁,查不到的行不受行锁保护 |
| 多 worker 领取可跳过的任务 | 短事务内 `FOR UPDATE SKIP LOCKED` + 原子认领;不是一般一致读,不保证严格 FIFO |
| 无自然行可锁的短资源互斥 | 必要时用事务级 advisory lock;参与者共同遵守,事务结束释放,不保护提交后的工作 |
| 单进程内存/普通 CPU/IO 并行 | 语言/运行时内置、有界的任务/池/信号量;不为本地并行引入 DB 锁 |

**短原子写 + 提交后执行**:
- 条件迁移/claim 检查 `RETURNING` 或影响行数;零行不是成功。单行原子写不能替代跨行不变量所需的约束、锁或隔离级别。
- `FOR UPDATE` 通常持锁至事务结束,不是单条 SQL 结束就释放;明确 autocommit 或短事务提交边界,不承诺微秒时长。session advisory lock 不随事务结束自动释放,不能把连接还池当成解锁。
- 原子写**成功提交后**才做 LLM/HTTP/外部执行;关键写同样不跨这些等待持有事务。短事务内的异步 DB 调用不受此禁令限制。
- claim 不等于完成,也不保证外部副作用恰好一次;幂等沿用 `resilience.md` §1。业务写与可靠外发意图必须同成败时,才用同事务任务表/outbox。

**控制自有协议,不设硬行数门**:需要持久任务恢复/重试调度时优先成熟 PostgreSQL-backed 组件;出现自造锁管理、租约、心跳或恢复协议时先复用组件或简化需求,不因底层用了 PG 就继续堆框架。

**实证(某 agent 服务的委派队列)**:worker claim 用 `SELECT ... FOR UPDATE` 持锁后 await 执行 / task-status
同步,行锁横跨整段——线程模式下直接死锁;prefork(多进程)部署下持 idle-in-transaction 事务 **279s+ 不释放**。
改单条原子 `UPDATE ... FOR UPDATE SKIP LOCKED ... RETURNING` 后根除。
**机械判据(可 lint,进硬层)**:任何 `with_for_update()` / `FOR UPDATE` 之后、同一事务作用域内 `await` 非 DB 工作
(LLM/tool/http/子任务)= 反模式,不论是不是"关键写";`@transaction` 方法体内 `await` 外部调用同理。

**PG 并发验收按不变量,不默认铺变异矩阵**:
- [ ] 实现依赖 DB 并发保证 → 用真实 PostgreSQL 的独立连接、可控交错验证选定不变量(如唯一性、扣减边界、同一任务在一轮竞争中只有一个成功领取者);不 mock 数据库的并发语义,不重证 DB 内部机制。
- [ ] 功能承诺涉及重试、回滚或认领后恢复 → 验对应路径;只验证领取不代表验证了完整任务生命周期。
- 默认不铺变异/全组合矩阵;减负不免验实际承诺,不删除既有回归,也不新增日常门禁。

## 3. 一句话
> 读查询:**弱事务 / autocommit,连接用完即释放**;只交易核心链路用强事务。框架"连接交容器管"(MANAGED+closeConnection=false)时,每条读路径也必须有事务边界,否则漏连接。
> 记账型写(计数/时间戳/统计,best-effort 可丢):**移出主链路 + 不借业务事务 + per-statement 提交 + 批量服务端增量**;热行列不加索引。
> 业务关键写:共享状态优先 DB 原语;保留原子性/一致性,**短事务提交后才做 LLM/外部执行**,不禁事务内异步 DB 调用;并发验收按选定不变量。
> "去事务" = 显式 autocommit,不是省 BEGIN;批量计数 = 服务端 `+= delta`,不是写绝对值。

## 来源
PG [锁寿命/advisory](https://www.postgresql.org/docs/current/explicit-locking.html)、[条件更新/隔离](https://www.postgresql.org/docs/current/transaction-iso.html)、[ON CONFLICT](https://www.postgresql.org/docs/current/sql-insert.html)、[SKIP LOCKED](https://www.postgresql.org/docs/current/sql-select.html);idle-in-transaction 反模式;write-behind/cache-aside(AWS/MS,显式划"关键写不适用");lost-update:baeldung.com/cs/concurrency-control-lost-update-problem;HOT:postgresql.org/docs/current/storage-hot.html。
