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

**写作纪律「能电不文」**：三条判据全过的规则**绝不写成散文**——
下沉；散文只留方法论与门判不了的判断项，后者允许稍详但不啰嗦。写散文前先问一句
"这条能不能电"。判不了全电、但要被逐句执行的步骤句，退半档写**带电清单行**：
`- [ ] <条件> → <动作>（对象：X）`（无条件写 `ALWAYS →`）——人可读、机可 lint 的窄语法，

## 2. 分层（早反馈 → 收口）

| 层 | 位置 | 适合 | 性质 |
| --- | --- | --- | --- |
| L0 散文 | SKILL/README | 方向、判据、指针 | 不承重执行 |
| L1 hook | PreToolUse / pre-commit | 本地可判定：模型档位、危险 flag、路径越界 | 早反馈，秒级 |
| L2 required CI / 服务端 ruleset | PR 合并线 | 可离线判定:测试、脱敏、格式、conformance | 收口；「绕不过」以 ref 真在 ruleset 覆盖内 + 绿新于门为前提（两者都要验，见 implementation-discipline 自举盲区） |

同一规则可双层：hook 给早反馈，CI 收口（hook 可被本地绕过；CI 在覆盖 + 新鲜两前提验过后才算不可绕）。

## 3. DENY 文案三件套（三件即上限）

每条 DENY 恰好三件，缺一即漂移，多一即重信封：

1. **一句 why**——带实证日期更佳（"2026-07-10 e2e 全红实证"），让被拦者信服而非绕行；
2. **正路命令**——被拦后该做什么，可直接复制执行（含 override 的合法路径及其适用动机）；
3. **owning-doc 指针**——`Read: <skill>/<path>.md §…`，指向真实存在的文件/节。

**刻意不加**：rule-id、Retry 字段、机器可读信封——重信封只归 CI 型 gate（那里的读者是
机器）；hook DENY 的读者是 agent，三件套已是它行动所需的全部，多余字段只稀释信号。

## 4. 配套硬门

- **自指门**：一个测试扫列明的 guard 源码，断言每条 DENY 的 `Read:` 指针目标文件存在（防文档腐烂，
  参考实现 `test/hook-deny-pointer.test.sh`；节锚不校验，新增 guard 文件须加进其扫描清单）。
- **override 有形**：需要逃生舱的 DENY 给一个显式、可审计的 override 动作（如
  `touch /tmp/<allow-marker>`），并在文案里写清**什么动机可用**——override 面向"经核实的
  任何正当动机"，不只文案里举的那一种（只举一种场景的文案会把其他正当动机劝退）。

## 5. Worked example（真实 DENY，三件套齐）

```text
DENY: Agent dispatch missing explicit model tier.
Why: 2026-07-10 长上下文评审派发默认档打满 quota（实证）。          ← why+日期
Fix: 重派并显式钉档：Agent(..., model: "opus"|"haiku")。            ← 正路命令
Read: cto-orchestration/SKILL.md §0                              ← owning-doc 指针
```
