# II-5 — 记忆 / 状态 / 持久：effective-config snapshot

> `agent-backend-standard` 的状态持久化章节。本章只管 durable workflow 的配置一致性；trace context 恢复归 `observability-standard`，HITL 请求上下文校验归 II-8。

## 0. 为什么

配置来自默认值、环境、tenant、feature flag 与运行时覆盖。durable workflow 若每步重读 live config，同一 workflow 会在 resume / recovery 后静默换规则，无法复现也无法安全重放。

## 1. 核心不变量(MUST)

workflow 启动时把分层 override 解析一次，得到 effective config；在 workflow 标记 `RUNNABLE` 或发生首个副作用之前（取更早者），MUST 原子持久化 immutable snapshot。checkpoint MUST 绑定 `snapshot_id` + digest；任一失败都不得进入 runnable 或执行副作用。

## 2. 读取与恢复

step / resume / recovery 只能读取 checkpoint 绑定的 snapshot，不得回退到 live provider、当前默认值或最新配置。每次加载都校验 `snapshot_id`、`schema_version` 与 canonical digest；缺失、损坏或 digest mismatch 一律 fail-closed，并且在任何副作用前拒绝。恢复 / replay 继续使用该 workflow 原绑定 snapshot；live config 变化只影响新 workflow。

## 3. 不可变、迁移与密钥

- snapshot 创建后不可 mutation；修订必须产生新 snapshot id。
- schema migration 必须显式、versioned、可审计，且不得借迁移重读 live config。若迁移生成新 immutable snapshot，checkpoint 重绑与新 snapshot 写入必须原子完成并保留 lineage。
- snapshot 不存 secret value，只存 immutable / versioned secret reference；`latest` / `current` 等可变引用 MUST 拒绝，不能留到恢复时再解析。

## 4. 硬层门禁

1. W1 在配置 A 下启动；live config 切到 B 后，W1 后续 step / resume / recovery 仍观察 A；新 W2 观察 B。
2. 把 live config reader 换成调用即抛错的 stub；旧 workflow 的 step / resume / recovery 仍成功，证明没有触碰 provider。
3. snapshot 缺失、内容篡改或 digest mismatch 时，runtime 在首个副作用前拒绝。
4. snapshot 写入失败时，workflow 不得变为 `RUNNABLE`，也不得产生副作用。
5. snapshot mutation 被拒；`latest` / `current` 等可变 secret reference 被拒。
6. 显式 migration 断言版本、lineage、checkpoint 绑定原子更新；普通 resume 不触发 migration。

## 5. 一句话

> durable workflow 的配置是启动时固化的持久状态：先原子落 immutable effective-config snapshot，再 runnable；此后只读 snapshot，任何缺失 / 篡改 / 漂移都 fail-closed。
