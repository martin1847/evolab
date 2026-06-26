# III-12 — 规范治理（手册如何用、偏离、演化）

> hub `agent-backend-standard` 的一章。模仿 Google C++ Style Guide 的 "Exceptions to the Rules" 收尾。

## 1. 怎么用本手册
- SKILL.md 是 ToC,**按需读单章** references/,别全量加载(context 经济)。
- 章分三类:已写实(读即用)/ *TBD*(占位,无内容别假装有)/ 交叉引用(去独立 skill:`observability-standard`/`git-workflow-standard`/A2A 对外契约规范)。

## 2. 偏离 / 例外(escape hatch)
- 规则是默认不是铁律。**偏离 MUST 显式记录**:在该仓 `AGENTS.md` 或对应 ADR 写明"偏离哪条 + 为何 + 范围",别静默不守。
- 某仓有正当理由覆盖默认(如集成策略、记账写阈值)→ 走 per-repo 声明(参见 per-repo 模式)。

## 3. 双层 + canonical-home(贯穿全手册)
- **双层**:本手册是软层(write-time 预防);硬层(CI 门禁/ruleset/清扫 bot)归 你的 IaC 仓。软层不作不可逆动作唯一防线。
- **canonical-home**:一条规则一个家,别处 `见 X` 引用不复制。横切规则(secret 不进 repo、honest span)各有 canonical(observability / AGENTS.md redaction)。

## 4. 手册如何演化
- 新章 / 改章:走 本规范仓 治理(AGENTS.md)——动命名/结构/边界以 ADR + module 为权威。
- 新增 concern 先判粒度:**触发动词不同 → 独立 skill;同属"写·评审 agent 后端代码" → 本 hub 加章**。
- *TBD* 章在有真实落地素材(案例 / 来信 / 决策)后写实,不空写通用建议(零投机)。
- owner:本规范仓 维护方;跨仓硬层 follow-up 发对应 CTO(如 你的 IaC 仓)。

## 一句话
> 按需读、偏离要显式记、规则有 canonical-home、空章不空写;新 concern 按粒度规则判"独立 skill vs hub 加章"。
