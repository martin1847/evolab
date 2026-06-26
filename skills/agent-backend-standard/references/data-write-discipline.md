# 附录 B — 数据访问与写纪律

> hub `agent-backend-standard` 的一章。来源:某 agent 服务的来信(内部) `LETTER_engineer-standards_bookkeeping-write-pattern`(2026-06-24 慢查询排查)+ 对抗验证修正。

## 0. 本质

**写操作按"关键性 + 一致性需求"分级,用最轻机制实现"记账型写"。** "记账型写(bookkeeping write)"画像:访问计数 / `last_accessed_at` / 使用统计 / 命中数 / "已读"标记 / 埋点计数——**best-effort、可丢、无强一致、常打热行、高频**。把它当普通业务写(进主链路、进业务事务、逐行写)是这类时延问题的通用成因。

实证(某 agent 服务):agent memory 召回后更新 `access_count`/`last_accessed_at`(~100 行小表、主键更新)慢到 **30.3s**。根因非 SQL/索引,是**事务纪律**:① 跑在用户同步主链路;② 复用召回的外层事务,行锁横跨整段召回(含 LLM/IO);③ 逐行 N 次 `UPDATE`。热行 + 长锁窗 + 高频 = 写争用 pile-up。

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

## 3. 一句话
> 记账型写(计数/时间戳/统计,best-effort 可丢):**移出主链路 + 不借业务事务 + per-statement 提交 + 批量服务端增量**;热行列不加索引。
> 业务关键写:保留事务与同步语义。
> "去事务" = 显式 autocommit,不是省 BEGIN;批量计数 = 服务端 `+= delta`,不是写绝对值。

## 来源
PG 锁持到事务尾:postgresql.org/docs/current/explicit-locking.html;idle-in-transaction 反模式;write-behind/cache-aside(AWS/MS,显式划"关键写不适用");lost-update:baeldung.com/cs/concurrency-control-lost-update-problem;HOT:postgresql.org/docs/current/storage-hot.html。
