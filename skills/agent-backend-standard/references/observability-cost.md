# III-11 — 可观测与成本 / 时延

> hub `agent-backend-standard` 的一章(**薄**)。埋点本体不在此——canonical 在独立 skill `observability-standard`(粒度规则:埋点是不同触发动词,独立 skill)。本章只加 agent 特有的**成本 / token / 时延**面 + 指回 observability。

## 1. 交叉引用(不重复)
- trace_id 串 trace/log、结构化日志、OTel、GenAI 语义约定、honest span(`ok=False`+`error_type`)、脱敏维度 → **`observability-standard`**。II-9 的诚实 span 要求亦锚那里。

## 2. 成本 / token / 时延(本章 MUST)
- **每任务记 token + 美元成本**(prompt/completion 分项)、**端到端时延**、每步 LLM/工具耗时;脱敏。
- **预算上限**:每任务 / 每租户设 token·成本上限,超则停 + 上报(呼应 II-7 退出条件、II-9 失控防护)。
- **告警 / 看板**:p95 时延、成本异常、超时率、`cancelled` 率。
- eval 驱动选型也看成本(见 III-10 *TBD*):同质量挑更省的模型。

## 一句话
> 埋点走 `observability-standard`;本章只管 agent 的钱和时间——每任务记 token/成本/时延、设预算上限超则停、对 p95 与成本异常告警。
