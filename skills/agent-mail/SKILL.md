---
name: agent-mail
version: 0.1.0
description: 多编排者/长期 agent 身份之间的异步信箱总线——发信、收信、回信、归档、名册注册。每个身份一个 inbox，一封信只有一个去处（收件人 inbox），收信只查自己信箱。触发：给另一个编排者/CTO/agent 写信或提议、查我的信箱、跨编排者协调、看有哪些注册身份。可选伴随 cto-orchestration 使用（多编排者场景）。Use when writing to / reading mail from another orchestrator agent, coordinating across orchestrators, or managing the agent roster.
---

# agent-mail — 编排者间信箱总线

> 多个编排者（各管一摊的 CTO/agent 身份）并行运行时的异步通信层。
> 信箱是**用户数据**，活在 skill 之外：`$AGENT_MAIL_DIR`（默认 `~/.agents/mail`）——
> 发布/升级本 skill 永不触碰信件。

## 为什么

**痛点**：信散在发信人各自的 repo/目录、命名不一，收信要翻遍别人的地盘，谁漏看谁背锅；
"只取最新"式检查会让先到的信被后到的**永久遮蔽**（多编排者并行实战实证）。
**本机制**：一封信只有一个去处 = **收件人 inbox**；一个身份只查一个地方 = **自己 inbox**。

## 数据目录（总线）

```
$AGENT_MAIL_DIR/            # 默认 ~/.agents/mail（与 agent-watch 的 ~/.agents/run 同规）
  registry.md               # 名册：id → 工作目录 → 职责（bus register 维护）
  <agent-id>/inbox/         # 发给"我"的信
  <agent-id>/archive/       # "我"处理完移进来
```

## 五条规则

1. **发信** = 写到**收件人** inbox：`$AGENT_MAIL_DIR/<收件人>/inbox/<id>.md`。绝不写进对方 git 树。
2. **收信** = 只扫**自己** inbox。一个地方，不翻别人 repo。
3. **回信** = 写到**原发信人** inbox，`re:` 填被回信的 id、`thread:` 沿用。
4. **归档** = 处理完把信从自己 inbox 移到自己 archive。**状态即位置**：inbox=待处理、
   archive=已处理、回信在 thread 里——信件里不设可变 status 字段（别人写的文件没有 owner，必烂）。
5. **待处理 = inbox 里的每一封**，全量、最旧优先——防"只取最新"的遮蔽。

## id 与 frontmatter

id：`<YYYYMMDD-HHMM>-<from>-<slug>`（时间排序含同日多封 + 一眼看发信人），
例 `20260704-0930-alpha-txn-standard-gap`。

```markdown
---
id: 20260704-0930-alpha-txn-standard-gap
from: alpha          # 发信 agent-id
to: beta             # 收信 agent-id
thread: txn-standard # 话题串（回信沿用）
re:                  # 回信填被回 id；首发留空
subject: 一句话主题
priority: normal     # low | normal | high
---
正文：结论先行；要对方做什么写清；要 verify 的给 file:line/证据。
```

## bus helper（可选便捷；纯 bash 无依赖）

```
bus register <agent-id> <工作目录> <职责...>   # 加名册 + 建信箱（新身份接入=这一条）
bus check <agent-id>                          # 列我 inbox 待处理（最旧优先）
bus send <from> <to> <slug> [subject...]      # 脚手架一封信到收件人 inbox
bus archive <agent-id> <id>                   # 处理完移 archive
bus roster                                    # 打印名册
```

不用 helper 也行：发信 = 手写 md 到对方 inbox；收信 = `ls $AGENT_MAIL_DIR/<我>/inbox/`。

## 接入（新席位，两步，本 skill 自包含——不依赖任何编排 skill 的清单）

1. **注册**：`bus register <席位id> <项目根绝对路径> <职责一句话>`（名册加行 + 信箱建好）。
2. **wire 收信提醒 hook**：项目 settings.json（如 `.claude/settings.json`）加
   `SessionStart → <skill绝对路径>/mail-check.py`（零参数——身份靠名册 workdir 反查、子目录也认；
   hooks 不展开 `~`，用绝对路径）。开 session 即冒泡"你有 N 封未处理信"——「记得查信箱」不再靠记忆
   （软规则必衰减，这是 forcing function）。接完设 `AGENT_MAIL_SELF=<席位id>` 跑一次脚本**验真触发**
   （有信应出 JSON、空箱应静默），别只信"配了"。

## 远程信箱（跨网络边界的收件人）

收件人够不着本机目录时（如网络隔离的线上运维 agent），**协议不变、只换传输**：信箱挂在双方都够得着的
中转（对象存储 / 同步盘），本质仍是"写 md 到收件人 inbox 前缀、收信只查自己前缀"。判据：

- **路由靠名册**：远程收件人照常 `register`，职责栏写明信箱实际位置（如 `<对象存储>://<bucket>/<prefix>/`）
  + 项目文档指针。发信人查名册知道往哪投——一个"写信"动词，不再按语境猜通道。
- **协议不变量跨传输成立**：唯一 id / 单一去处 / **待处理=全量最旧优先**（防遮蔽规则正是远程管道
  实证事故沉淀的）/ 处理完移 archive 前缀。
- **外部传输升级 redaction 为硬规则**：中转在外部存储上——**凭证 / 客户数据 / 内部拓扑绝不进信**，
  只放命令/SQL/计数/结论；凭证走各自项目的凭据中枢。
- **传输适配器归项目**（CLI 工具、认证、前缀布局进项目 ACCESS/docs），本 skill 不感知厂商。

## 约定

- **不擅改对方 skill/repo**：领域归各自 owner；要改 → 发信提议 + file:line 证据，
  采纳/措辞/编号对方定（提议/批准分离）。例外：主理人明确授权的直接改动，改动方仍发信告知。
- **敏感信息不进信件**（凭证/客户数据），与各 repo redaction 纪律一致。
- 总线默认非 git；要历史可在 `$AGENT_MAIL_DIR` 下自行 `git init`（数据归用户，不随 skill 发布）。
- 跨机器同步（网盘/私有 remote）自理，协议不感知。
