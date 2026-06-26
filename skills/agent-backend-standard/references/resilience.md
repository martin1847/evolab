# II-7 — 韧性 / 错误 / 幂等

> hub `agent-backend-standard` 的一章。借鉴已确立的韧性模式 + 12-Factor Agents / OpenAI agents 指南;agent 链式调用下尤其要命。

## 0. 为什么 agent 场景更要

agent 一次任务串很多外部 / LLM / 工具调用,且会**重试、重规划**。任一调用无界 / 不幂等 / 无熔断,放大成整链卡死或重复副作用。

## 1. 每个外部 / LLM / 工具调用 MUST

1. **超时**:每个调用有显式超时(LLM 调用尤其——可能挂很久)。无超时 = 一个慢上游冻住整链。
2. **有界重试**:重试有上限 + 退避;**只重试可重试错误**(超时 / 5xx / 限流),不盲重 4xx / 校验错。
3. **幂等(被重试的工具 MUST 幂等)**:重试 / agent 重发可能让同一工具跑两次——**有副作用的工具(下单 / 写库 / 发消息)必须幂等**(幂等键 / 去重 / upsert)。这是 agent 重试纪律的承重条。
4. **熔断 / 降级**:依赖持续失败时熔断,给降级路径或干净失败,别雪崩。

## 2. agent 失控防护(与 II-9 呼应)

- **退出条件 / 迭代上限**:agent 循环 MUST 有最大步数 / 轮次 / 时长(OpenAI exit conditions、12-Factor F9)——防超时后重规划无限再发(II-9 hidden-loop)。
- **成本 / token 预算**:每任务设上限,超则停 + 上报(见 III-11)。
- **错误压回上下文**:工具失败把**紧凑、可操作**的错误塞回上下文让 agent 自我纠正(Anthropic),别静默吞、别塞整个 stack trace。

## 3. fan-out 资源纪律
agent 并行 fan-out 子任务 / 工具时,守连接池 / 并发上限(呼应 II-9 并发闸、附录 B 写争用),别一次打爆下游。

## 4. 一句话
> 每个外部/LLM/工具调用:超时 + 有界重试(只重可重试错)+ 幂等(有副作用必幂等)+ 熔断;agent 循环有迭代/成本上限;失败压回上下文可自纠;fan-out 守池。

## 来源
12-Factor Agents F9(compact errors / exit)、OpenAI agents 指南(exit conditions / limits)、Anthropic Writing Tools(actionable errors)、经典韧性模式(retry/backoff/circuit-breaker/bulkhead)。
