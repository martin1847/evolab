# Self-Evolution — 经验分层沉淀与晋升（铁律九「复盘回写」的系统化展开）

> **复盘不是目的。** 教训若只是散文追加，corpus 稀释、单条被遵守的概率随总量下降（context rot），
> 系统停在「记录了 ≠ 学到了」。本文回答三问：一条教训**落哪层**（§2 分诊）、**何时升层**（§3 晋升三门）、
> **何时删**（§4 淘汰）。
> 双源背书：七个互相独立的人类传统（Argyris 双环学习 / Meadows 杠杆点 / SECI / 美军 CALL / 丰田 kata /
> 宪法层级 / Dreyfus 专长模型）收敛出同一副骨架；AI agent SOTA（ACE / Memp / SSGM / Bugbot learned
> rules / Claude auto memory）的机制清单与之逐条互证。出处见 §7。

## 1. 分层沉淀表（Meadows 杠杆轴的实例化）<!-- trunk:分层沉淀 -->

变化有深度层级，且各家是同一根轴：**改「做什么」→ 改「按什么规则做」→ 改「为什么/以什么身份做」**。
杠杆随深度递增、变更频率递减、准入门随深度收紧（pace layering：fast learns, slow remembers）：

| 层 | 改什么 | 载体（本仓实例化，皮可换） | 准入门 | 预算纪律 |
|---|---|---|---|---|
| **事实** | 环境/路径/凭据入口 | 项目 docs / ACCESS | 随手写（写时纪律，不等复盘） | 宽，但只放可复验事实 |
| **情景教训** | 本项目怎么做 | 编排者 memory | n=1 先标 `OBSERVATION` + provenance | 每 workstream 精简、索引一行 |
| **操作规则** | 跨项目按什么规则做 | skill references | **n≥2 同向** + 提议/批准分离 | 行数预算、主干枚举同步 |
| **判据** | 按什么标准判断 | SKILL.md 主干 | 多实例 + 对抗评审（打磨五刀） | 主干 <500 行、砍是纪律 |
| **原则/范式** | 为什么这么做 | meta 文档 · 内核铁律 | **修宪门**：两张现存皮都容不下才改 + 主理人裁定 | 条数极少 |
| **身份** | 以什么身份做 | 全局规则文件人格 / resident digest | 主理人明示 | 数行级 |

**正交轴：载体硬化度**。每层内容另有 L0 散文 → L1 hook 强制 → L2 设计消灭 的硬化阶梯
（见 structure-not-discipline）——「住哪层」和「硬化到什么程度」是两个独立决策，别混。

## 2. 分诊器：一条教训落哪层

五问法追根，**追问停在哪层、教训就落哪层**：操作失误 → 事实层；规则缺失 → references；
判断标准错 → 主干；范式错 → meta/内核。两个方向的错层都是病：

- **只喂最低层**（Meadows 记录的通病：90% 精力花在参数微调，因为阻力最小）——同类单环修正反复出现，
  是上一层治理变量有缺陷的信号，该升层提问，不是再加一条操作规则（Argyris 双环）。
- **参数住进原则层**（美国宪法第 18 修正案：把参数写进宪法，成了唯一被整条废除的修正案）——
  晋升评审必查「这条的抽象度配得上这一层吗」。

## 3. 晋升三门（量的门 · 行为的门 · 压缩的门）<!-- trunk:压缩即晋升 -->

1. **样本门（量）**：n=1 只标 `OBSERVATION`、不改 spec/默认；**n≥2 例同向**才有资格提议升层；
   retro 只提议、主理人裁定（提议/批准分离，防按一次性事件堆规则——也是 memory poisoning 的防线）。
2. **行为门（质）**：晋升判据是**行为改变，不是记录**（美军 CALL 对 lesson learned 的正式定义：导致
   doctrine/行为改变才算；否则只是 lesson *identified*——NASA 教训库变坟场的机理）。一条教训的
   **关单条件 = 指向某层的已合入 diff + 下次真实任务的行为核验（fire 了吗）**。工业对应物：Bugbot
   candidate 规则先影子评估、正信号累积才 promote。
3. **压缩门（质变判据）**：升层的动作是**把 N 条下层实例蒸馏成 1 条上层判据、并删除/降级原件**——
   认知科学的 chunking、五问法的 instance→class、复盘第四步「总结规律」都是它。
   **晋升后 corpus 总量必须不增；总量没减 = 复制，不是质变。**
   - **结构跃迁触发器**（复盘仪式的固定检查，非手感）：同层出现 **≥3 条同族条目** → 触发抽象合并提案
     （蒸馏 1 条上层 + retire 原件）。这是当前 AI SOTA 的公开空白（ACE 的 dedup 只消同义冗余、不做
     抽象合并），而本内核自身就是一次实证——从两张皮数百行操作沉淀里蒸馏出九条铁律、原件降级为皮。

## 4. 淘汰：删除是一等公民

健康系统的规则数是**倒 U 形**（Dreyfus：专长的标志是规则**脱落**而非累加；corpus 单调增长本身就是
「系统停留在新手层」的症状）。四条：

- **写入时付删除成本**：每条规则入库必带 provenance（哪次事故 / 为什么立）——Chesterton's fence：
  说不出篱笆为什么立就不许拆；反之，原因已消失即可安全拆。
- **fire-or-delete razor**：从不 fire 的散文是净负债——复盘时抽查，要么升硬化度、要么删。
- **能力升级即减负**：模型/结构已可靠做对的事，对应的下层规则删除（强迫专家守新手规则会摧毁专长）。
- **升 L2 设计消灭后回删服务于它的 L0 散文与 L1 特例**（留一行墓志铭），否则三层同活成新漂移面。

**为什么删不能省**：每事故加一条 guard = Senge「shifting the burden」的症状解成瘾回路——规则越多，
关键规则的注意力配额越少 → 更多事故 → 更多规则。decay 不是清洁工，是斩断这条回路的结构件。

## 5. 快照 vs 知识库：两种文档、两种纪律

表面冲突要辨析：状态快照（AGENTS.md / ACTIVE_CONTEXT）的纪律是**整篇重写、有上限**（快照非日志）；
规则 corpus（skill / memory / meta）的纪律恰恰相反——**增量定位修改、禁整篇重写**（ACE 实测
context collapse：LLM 整篇重写 memory 一步之内 18k token 崩到 122、准确率跌破无记忆基线）。
判据：内容是「现在的状态」→ 重写；是「累积的知识」→ 逐条增改删，条目化（可寻址、可计数、可单独淘汰）。

## 6. 反模式速查

散文追加稀释（150-200 条指令是前沿模型的经验上限）｜防御性单环（反复打补丁不问治理变量）｜
参数住进原则层｜记录当学会（无行为核验）｜一次性事件直改默认（跳样本门）｜整篇重写知识库
（context collapse）｜规则只增不删（症状解成瘾）｜给强模型塞新手操作细则（降智）。

## 7. 出处（可核对）

- 人类侧：Meadows "Leverage Points"（donellameadows.org）· Argyris & Schön 1978（双环；"triple-loop"
  非其原创，见 Tosey et al. 2012）· Nonaka & Takeuchi SECI 1995 · 美军 CALL 管线与 lesson-learned 定义
  （Handbook 15-11）+ GAO-02-195（NASA 教训库失效实证）· Rother《Toyota Kata》2009 · Chase & Simon 1973
  （chunking）· Dreyfus 1980/1986 · Chesterton 1929 · Senge 1990 · Brand pace layering 1999 ·
  柳传志复盘四步（回顾目标→评估结果→分析原因→总结规律）。
- AI 侧：ACE（arXiv 2510.04618：itemized playbook + Generator/Reflector/Curator + delta 合并 +
  context collapse 实测）· Memp（2508.06433：Addition/Validation/Revise/Deprecation）· SSGM
  （2603.11768：写前验证门 + Weibull decay + append-only 对账）· Cursor Bugbot learned rules
  （candidate→影子评估→promote/auto-disable，业界唯一公开完整晋升管线）· Claude Code auto memory
  （MEMORY.md 索引 + topic files 溢出）· Voyager 2305.16291（skill 组合）· ArcMemo 2509.04439
  （instance→concept 抽象）· A-MEM 2502.12110（记忆网络自重组）。
