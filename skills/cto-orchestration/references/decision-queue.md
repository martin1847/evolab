# 主理人注意力与决策队列 — 降认知负载（principal cognitive-load offloading）

> 把"降低主理人认知负载"当**编排设计目标**，但不让主理人变甩手掌柜——承重决定仍归他。
> 这是 SKILL §第二铁律（执行前验证、不明先问）的操作化：不是每事问，而是把"该谁决"事先设计掉。
> **2026-07 重定位**：审批流与工作记忆是两种东西，拆开——**三档委派下沉 harness 权限层（结构强制），
> 队列文件只装人脑的判断题（🔴/💤），新鲜度配 shipped hook**。散文规则会随长上下文稀释
> （context rot / instruction drift），官方判词："Permission rules are **enforced by Claude Code,
> not by the model**. Instructions in your prompt or CLAUDE.md **shape** what Claude tries to do,
> but they don't change what Claude Code **allows**."（code.claude.com/docs/en/permissions）

## 负担的两个来源（都靠设计解，非靠人更努力）
1. **状态存在主理人脑子里**（"怕忘记"）——开着的环靠记忆持有 = 持续占工作内存。
2. **"哪些该我决"模糊**（"纠结"）——每件事都隐隐像要他拍，于是每件都耗他。

## 架构：三层各归其位

| 层 | 装什么 | 载体（强制级别） |
|---|---|---|
| **权限层** | T0/T1/T2 三档委派的**执行** | harness permission rules + hook（结构，模型绕不过） |
| **队列文件** | 🔴 需人拍板的判断题 + 💤 parked | markdown（散文，配新鲜度 hook 兜底） |
| **工作记忆** | 🟡 在飞的事、进度 | ACTIVE_CONTEXT / 任务系统——**别在队列里养第二份** |

- **三档委派 → 权限层映射**（语义定义在散文，执行在配置）：
  - **T0 直接做不烦他**（可逆、已授权、无价值判断）→ `allow` rules / acceptEdits。
  - **T1 做了+记一行（可否决）**→ `allow` + PostToolUse hook 自动记账——记录由 hook 确定性追加，
    不靠模型"记得记"。他异步翻、可回退。减负关键 = 多往 T1 挪、少用 T2 当同步闸。
  - **T2 动手前必问**（不可逆/对外、战略/优先级/钱/价值、有实质下行的真模糊）→ `ask`/`deny` rules +
    PreToolUse hook deny（**连 bypassPermissions 都拦**）。cto-guard 与服务端分支保护是既有实例。
- **需要即时拍板的 ≤4 个问题**：用 harness 原生批量提问（如 AskUserQuestion，1-4 问 × 每问 2-4 选项，
  带推荐与默认），别一问一 turn 切碎注意力；**异步/不急的进队列**。
- 队列瘦身后只剩权限系统管不了的**判断题**——这正是它该有的形态：审批流要"不可遗忘、可批量、可恢复"，
  业界收敛到结构化机制（interrupt 队列 / approval inbox / permission rules）；工作记忆才适合 markdown。

## 队列机制（六件，编排者维护、对主理人零增量）

1. **单一决策队列**（GTD open-loops）：`docs/DECISION_QUEUE.md`，编排者维护、主理人只读。
   - **完整性保证（信任前提，最承重）**：必须是**唯一**面、不在别处另存、不静默丢——否则他仍要自己记
     "有没有漏"，offload 失效。
   - 每个 🔴 = 什么 / 为何归他 / 选项 / **我的推荐** / **静默默认** / **revisit 触发**。带推荐+默认让
     "决定"变"确认/微调"。证据：Masicampo & Baumeister 2011（终结反刍靠具体计划）；Leroy（注意力残留，
     "ready-to-resume"注记降再入成本）。[research-backed]
2. **静默默认**：主理人没回 → **可逆按写明默认前进；不可逆一律 HOLD，永不自动越过**（这条不可破）。
3. **聚合绊线**：逐事件看都可逆，但一串双向门会闩死一个单向门（lock-in / 蔓延花费 / scope drift）——
   累积变不可逆时升 T2 并点名该模式。[composed]
4. **批处理 + 升级包**：不每事件 ping，攒到检查点成批给；每个 T2 带议题/影响/已做步骤/需你啥+推荐+默认。
5. **心跳**（management-by-exception）：纯减负会退化成橡皮图章/失去态势感知——每检查点刷新队列，
   即使无事也给周期性全局图。紧急≠重要。
6. **HELD 项 revisit 节奏**："HOLD 到底"安全上对，但会烂成靠不作为决策——每个 HELD/💤 带 revisit
   触发（事件或日期），到点主动重浮。

## 强制层（治「队列腐烂」——本机制曾经的最弱点，散文建议已升 shipped hook）

- **平时**：`queue-freshness.py`（UserPromptSubmit hook，wiring 真源 `queue-hooks.json`，可选接入）——
  `docs/orchestration/` 活动比队列新超过 grace（默认 1h）→ 注入 system-reminder 提醒刷新；
  ≤1 次/小时防唠叨。四分支已合成测试（stale 提醒/限流/新鲜静默/无队列静默）。
- **收口**：`retro-check.sh` 硬门已含"DECISION_QUEUE.md 在则新鲜"断言（复盘七步之一）。
- **为什么是提醒不是 Stop-block**：block 需要"本 turn 存在未记账 T2"的确定性信号，当前无此信号源——
  伪精确的门比诚实的提醒更糟（误拦 + Stop hook 8 次连 block 熔断）。若未来 T2 拦截落 marker 文件，
  可升级为门。

## 失败模式（盯住）

- ~~队列腐烂（编排者忘更新）~~ → **已配强制层**（上节 hook + 收口硬门）；语义质量仍靠检查点纪律。
- **橡皮图章 / 失去态势感知** → 心跳 + 升级包强制带"已做步骤"。
- **聚合盲区** → 绊线（机制 3）。
- **HOLD 烂掉** → revisit 触发（机制 6）。
- **队列长出第二职能**（进度/待办混进来）→ 按「架构」表归位：🟡 归 ACTIVE_CONTEXT/任务系统。

## 落在哪（三层治理，勿混）
- **队列实例**（含具体待决项）→ 项目 `docs/`（随项目走）。
- **本实践方法论** → 本 skill（跨项目沉淀，项目无关）。
- **编排者私有的"本项目决策/教训"** → memory（私有指针）。

## 出处诚实标注
- [research-backed]：GTD open-loops；Masicampo & Baumeister 2011；Leroy 注意力残留；context rot /
  lost-in-the-middle（Anthropic context-engineering 博文 + Liu et al. 2023）。
- [官方机制]：permission rules 判词与 enforced-not-shaped 分界（code.claude.com/docs/en/permissions）；
  hooks "deterministic control … rather than relying on the LLM to choose"（hooks-guide）；
  AskUserQuestion 1-4 问批量。业界同构：LangGraph interrupt + Agent Inbox、OpenAI Agents SDK
  `interruptions` 批量审批——审批流用结构化机制是三家收敛，非本 skill 独创。
- [doctrine, 非实证]：Amazon 单向/双向门、Management 3.0 委派层级、management-by-exception、
  chief-of-staff 实践。**刻意不用**：决策疲劳/ego depletion（复现失败）——减负论据建在 open-loops +
  注意力残留上。
- [composed]：聚合绊线、阈值/节奏数值——机制对、数值靠判断。

## 队列模板（copy-paste 骨架，项目无关）
```markdown
# Decision Queue — <principal> 的 cockpit
> 🔴需你 / 💤parked / ✅已清（🟡在飞的事归 ACTIVE_CONTEXT，不在此维护）。我维护、你只读。
> 完整性保证：这是唯一面，不在别处另存、不静默丢。每🔴带推荐+静默默认；每💤带 revisit 触发。
> 聚合绊线：可逆累积变不可逆时我升🔴。心跳：每检查点刷新给你全局图。Last updated: <date>.

## 🔴 NEEDS YOU
| # | 决定 | 为何归你 | 我的推荐 | 静默默认 | revisit 触发 |

## 💤 PARKED / GATED  | 项 | 为何 parked | revisit 触发 |
## ✅ RECENTLY CLEARED（留最近几条作凭证）
```
