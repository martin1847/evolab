# 附录 A — 代码 / 依赖生命周期 + 反死代码

> hub `agent-backend-standard` 的一章(详版)。SKILL.md ToC 是压缩镜像。落地结构软/硬分工见治理;
> `EXPIRES`/`REVISIT-WHEN` 标记的 **canonical 定义在本章**;prompt 场景(II-3)引用之。

## 0. 诊断

- 缺的不是检测器,是**生命周期元数据**:市面无现成工具把 why + owner + 退役判据绑到一个引入物上。
- **同一种病、两种形态**:
  - **重组件**(那个没人清的 ES)——重、可走 ADR(§1)。
  - **情境绑定的 hardcode / prompt 内容**(为弱模型写死的 hack、客户特例)——轻、藏在行内(§2)。它**照常执行、结果也"对"**,只是当初的理由没了 = "活着但理由过期"(stale-but-live),比死代码更隐蔽:覆盖率都救不了(它在跑)。
- 用户痛点"可达但实际无人走 / 动态引用 / 配置门控 / 死基础设施接线"**正是静态分析的盲区全集**——只能靠预防(引入即定判据)+ 运行时检测兜。
- **声明式记录无 forcing function 必腐烂**(调研一致:ADR status / catalog lifecycle 字段 / tech-debt register 全腐烂)。本章产出的记录靠硬层 CI 门禁咬住(§6)。
- AI 时代更急:GitClear 2025(复制粘贴↑、重构↓、churn↑)、DORA 2024/2025(AI 放大器、稳定性下滑)。

## 1. 重组件引入门禁(MUST)

### 1.1 阈值
**卡**:新增运行时服务 / 数据存储(DB / ES / 缓存 Redis)/ 消息队列 / 新外部依赖服务 / 新能力类别(首次引入全文检索 / 工作流引擎)。
**不卡**:普通工具库 / 既有能力类别内的小依赖(避免 `npm add` 官僚化)。判不准按"卡",成本只一条 ADR。

### 1.2 ADR-with-sunset 模板
放消费仓 `docs/decisions/`,与 `repo-governance-bootstrap` 的"组件引入 ADR 变体"一致,**增 Owner / Sunset / Review-by**:

```markdown
# ADR-NNN: 引入 <组件>
Status: accepted
Date: YYYY-MM-DD
Owner: <谁负责其存续与退役>
## Context
<问题 + 为何 stdlib / 现有依赖不够;评估过的替代方案>
## Decision
<引入什么;如何 wrap behind interface 保持可替换>
## Sunset Criteria（退役判据）
- <什么条件下应被移除:依赖它的 X 特性下线 / 长期 QPS < N / 被 Y 替代>
## Review-by
- YYYY-MM-DD（到期必须复审:仍需要?可降级/移除?）
## Consequences
<运维成本 / 锁定风险 / 退役难度>
```

### 1.3 默认偏向
复用 > 新增("最笨但能用"优先,Russ Cox《依赖问题》);新增必 **wrap behind interface**(可替换性是退役前提)。

## 2. 情境绑定 hardcode / prompt 生命周期(MUST)

### 2.1 判别
- **稳定不变量**(协议常量、π、`max_retries=3`):不需要生命周期标记——打标 = 噪声 bloat。
- **情境绑定**(因某个**当前、预期会变**的情况才存在的:为弱模型写死的格式 hack、客户 demo 特例、`if model=='gpt-4'` 兼容、临时绕上游 bug)。判据:**"它是不是因为某个预期会变的情况才在这?"** 是 → 有生命周期。

### 2.2 退役标记约定(把"看不见"变"可 grep")—— canonical
检测这类没有工具(它执行、它"对")。唯一杠杆是 write-time 留**机器可搜**的标记 + reason + owner:

```python
# REVISIT-WHEN: 升级到能稳定输出嵌套 JSON 的模型  (reason: gpt-4 搞不定; owner: @yang)
hardcoded_format_hint = "..."
# EXPIRES: 2026-09-30  (reason: acme onboarding demo 特例; owner: @yang)
if tenant == "acme": ...
```
- `EXPIRES: <date>` —— 硬到期,**CI 过期即 fail**。
- `REVISIT-WHEN: <条件>` —— 条件无法自动判,但换模型 / 改架构时 `grep REVISIT-WHEN` 扫出(解决"几个月后踩 bug 才发现")。
> "过期即炸的标记"有现成实践(`todo-or-die` 类;具体工具名置信中等,机制成立)。**只对情境绑定打标**;prompt 场景的额外纪律见 II-3 `prompt-context.md`。

## 3. 检测:工具 + 盲区表

### 3.1 按栈选工具
| 栈 | 工具 | 抓 |
|---|---|---|
| JS/TS | **knip** | 未用文件/导出/依赖(ts-prune 已维护模式) |
| Go | **`deadcode`**(官方 x/tools) | 从 main 不可达;保守建模反射 |
| Python | **vulture** / **FawltyDeps** | 死代码 / 未声明+未用 deps;启发式需人核 |
| Rust | **cargo-machete** / cargo-shear | 未用 deps |
| Java | `mvn dependency:analyze` | 字节码级 used/unused |

### 3.2 盲区(MUST 知道,别盲删)
静态普遍看不到:① 运行时字符串引用(`getattr`/`eval`/反射/`import(var)`)② 配置/feature-flag 门控 ③ 跨服务/跨仓 ④ build-time/宏/codegen ⑤ entry-point 声明不全误报。
**这五类 MUST NOT 因静态报"未用"就删。** Meta SCARF 要**静态+生产日志**双管才敢自动删(5 年删 >1 亿行)。

### 3.3 运行时 route
tombstone(埋日志标记,Feathers "Scythe")+ 生产覆盖率(JaCoCo/coverage.py)+ **soak**;**"窗内没跑 ≠ 死"**(季节/边缘流量),soak + tombstone 确认再删。

## 4. 反 bloat 写作(MUST)
不复制粘贴重复块(GitClear)、优先抽取/复用、**最小可用改动**;不引入未用的"灵活性/可配置性"(= 预定的死代码)。

## 5. 定期清扫(SHOULD)
Ona "Knip daily":定时 job → 跑检测 + 扫过期标记 → **一次只挑一个**删除 → build+lint 验证 → 开小 PR。一次一删可评审、低冲突。

## 6. 硬层契约(归 你的 IaC 仓 / IaC CTO)
- **Danger 规则**:PR 改 `package.json`/`go.mod`/`pyproject.toml`/`Cargo.toml`/`infra/` 但没动对应 ADR → **fail**。无 turnkey 产品,用 Danger `git.modified_files` + CODEOWNERS 自拼。
- **unused-dep required check**:对应栈工具,**warn → 收紧**(误报多,别一上来 hard fail)。
- **过期标记扫描**:`EXPIRES:` 过期 → fail;`REVISIT-WHEN:` 定期 sweep 给 owner 复审。
- **CODEOWNERS** 锁 manifest / infra;清扫 bot 调度。

## 7. 诚实边界
- skill 是预防不是保证;没硬层照样腐烂。
- unused-dep 有误报 → warn-then-tighten。
- 运行时 "cold ≠ dead";动态/flag-gated 删前必 soak+tombstone。
- 标记别滥用,只对情境绑定。
- 不过度承诺新概念(code provenance / PBOM / SBOM-as-ledger 是方向不是实践)。

## 来源
Meta SCARF: engineering.fb.com/2023/10/24/...；Russ Cox: research.swtch.com/deps；Ona: ona.com/stories/knip-automation；GitClear 2025；Feathers Scythe；LaunchDarkly flag debt。
