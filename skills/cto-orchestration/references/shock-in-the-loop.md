# 电在回路（shock-in-the-loop）—— 承重规则的强制层设计

> 触发：有人对你说「电在回路」/ "shock-in-the-loop"，或你要新增/评审任何 hook DENY、
> CI gate、guardrail 时，按本文执行。类比 HITL：人在回路管**决策权**，电在回路管
> **规则触点**——散文给方向，承重规则必须在动作发生的那一刻电到 agent，而不是指望
> 它记得读过的文档。

## 1. 下沉判据（三条全过才下沉，否则留散文）

1. **承重**：违反 = 真实事故/真实成本（有过实证最佳；没实证先别立法）。
2. **可确定判定**：机器无需人审即可裁决（正则/AST/文件存在性/参数值）。
3. **有触点**：存在能拦到该动作的时刻（PreToolUse hook、pre-commit、required CI）。

不满足①的下沉是噪声（狼来了，agent 学会无视电击）；不满足②的硬拦是误伤源；
不满足③的规则写成散文 + 指针，等触点出现再下沉。

## 2. 分层（早反馈 → 收口）

| 层 | 位置 | 适合 | 性质 |
| --- | --- | --- | --- |
| L1 hook | PreToolUse / pre-commit | 本地可判定：模型档位、危险 flag、路径越界 | 早反馈，秒级 |
| L2 required CI / 服务端 ruleset | PR 合并线 | 可离线判定:测试、脱敏、格式、conformance | 收口，绕不过 |
| L0 散文 | SKILL/README | 方向、判据、指针 | 不承重执行 |

同一规则可双层：hook 给早反馈，CI 收口（hook 可被本地绕过，CI 不可）。

## 3. DENY 文案三件套（三件即上限）

每条 DENY 恰好三件，缺一即漂移，多一即重信封：

1. **一句 why**——带实证日期更佳（"2026-07-10 e2e 全红实证"），让被拦者信服而非绕行；
2. **正路命令**——被拦后该做什么，可直接复制执行（含 override 的合法路径及其适用动机）；
3. **owning-doc 指针**——`Read: <skill>/<path>.md §…`，指向真实存在的文件/节。

**刻意不加**：rule-id、Retry 字段、机器可读信封——重信封只归 CI 型 gate（那里的读者是
机器）；hook DENY 的读者是 agent，三件套已是它行动所需的全部，多余字段只稀释信号。

## 4. 配套硬门

- **自指门**：一个测试扫全部 DENY 源码，断言每条指针存在且目标文件/节真实（防文档腐烂，
  参考实现 `test/hook-deny-pointer.test.sh` 形态：AST 抽 DENY 字符串 → 校验 `Read:` 目标）。
- **override 有形**：需要逃生舱的 DENY 给一个显式、可审计的 override 动作（如
  `touch /tmp/<allow-marker>`），并在文案里写清**什么动机可用**——override 面向"经核实的
  任何正当动机"，不只文案里举的那一种（2026-07-19 现场：guard 只讲黑洞场景，派错前提的
  合法杀单被文案劝退）。

## 5. 反模式

- 散文规则无触点（写了没人读 = 净负，见判据③）。
- DENY 只骂不指路（缺正路/缺指针 → agent 只能绕行或卡死）。
- 万物皆 hook（不承重也拦 → 电击贬值）。
- 指针指向不存在的节（无自指门必然腐烂）。

## 6. Worked example（真实 DENY，三件套齐）

```text
DENY: Agent dispatch missing explicit model tier.
Why: 2026-07-10 长上下文评审派发默认档打满 quota（实证）。          ← why+日期
Fix: 重派并显式钉档：Agent(..., model: "opus"|"haiku")。            ← 正路命令
Read: cto-orchestration/references/agent-watch/README.md §P0c        ← owning-doc 指针
```
