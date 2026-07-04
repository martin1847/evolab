# II-8 — 人在环(HITL)与可恢复 flow 的 resume 安全

> hub `agent-backend-standard` 的一章。当前写实 **resume 安全**(可恢复 / 挂起-恢复 flow 的承重不变量);HITL escalation 触发阈值等更广内容待扩。clarify / approve 的协议线形见 A2A 对外契约规范(对外契约),本章只管后端 resume 的安全校验。

## 0. 为什么

agent 后端越来越多"挂起等人(HITL)→ 跨轮恢复"的可恢复 flow。**最危险的洞不是功能缺失,是 resume 时只校验 envelope 形状、不校验持久化状态**——一个伪造的 in-process resume 上下文就能:嫁接别的 workflow、跨租户/跨会话恢复、或重放已完成/陈旧 checkpoint。

## 1. 核心原则(MUST)

**resume 时 MUST 用「从持久化存储加载的 checkpoint」校验当前请求上下文,而非只校验 resume envelope 的形状。** in-process 调用方可能伪造 resume 上下文(如内存里的 `partial_state`),唯有比对持久层真实 checkpoint 才挡得住。**防御层 MUST 在 runtime / 状态层,不能只在 API 入口**——API 校验绕不过伪造的 in-process 调用。

## 2. 按序六道闸(任一不过 MUST 拒绝 resume)

1. **envelope 绑本 workflow + task**:envelope 的 `workflow_id` / `task_id` MUST 匹配当前 manifest / task。
2. **加载 checkpoint 的隔离边界**:取出的 checkpoint 的 `tenant_id` + `conversation_id`(会话/session)MUST 等于请求 ctx——跨租户 / 跨会话 resume MUST 拒(fail-closed)。
3. **checkpoint 绑本 workflow + task**:加载的 checkpoint 的 `workflow_id` / `task_id` MUST **再次**匹配——即便 in-process 伪造了 `partial_state`,这步用持久层真值挡跨 workflow 嫁接。
4. **仅挂起态可恢复**:`checkpoint.status` MUST 是 SUSPENDED;非挂起 / 已完成 MUST 拒。
5. **必须是该 task 的最新 checkpoint**:MUST 等于 `latest_for_task`,否则拒(挡陈旧 / 重放 envelope)。
6. **全新(非 resume)启动 MUST 拒绝重跑已完成 task**:最新 checkpoint 已 COMPLETED → 拒绝再启动。

## 3. 威胁模型(rationale)

① 伪造 in-process resume 上下文;② 跨 workflow envelope 嫁接;③ 陈旧 / 已完成重放;④ 跨租户 / 跨会话越界。
四者的共同要害:**信任了不可信的请求侧输入**(envelope / in-process ctx)。所以校验必须落到**持久层真值 + runtime 强制**,不是 envelope 形状、不是 API 层。

## 4. 硬层契约(归 你的 IaC 仓 / IaC CTO)

六道闸配 **conformance 测试**作硬层(光软层提醒会腐烂):跨租户 resume 拒 / 陈旧 replay 拒 / 非 SUSPENDED 拒 / 已完成重跑拒,各一条**会变红**的负例。

## 一句话
> resume = 用持久 checkpoint 校验请求 ctx(非 envelope 形状),六道闸 fail-closed,防御在 runtime/状态层不在 API。
