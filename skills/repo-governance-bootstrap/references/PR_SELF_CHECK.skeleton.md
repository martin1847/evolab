# PR 提交前自检清单 — <项目名>

> 提 PR 前过一遍（人和 agent 同一份）。价值：把评审往返从多轮压到 1 轮。
> **铁律：每条源自真实评审 finding / 事故，禁理论条目**——新仓从空清单开始，
> 先攒 findings 再蒸馏（供给回路见 `agent-backend-standard/references/selfcheck-gates.md` 附录 F）。
> 可机检条目下沉 `.githooks/pre-push`（纯 git+grep 毫秒级、diff-scoped），
> 每关带负探针，登记进 AGENTS.md 验证配方节。

<!-- 蒸馏出第一批条目后按"面"分节，例如：契约面 / DB 面 / 测试面 / 配置密钥面 / 并发面 / CI 收尾面。
     每条标注来源，格式如下：

## 1. <面向>

- [ ] **<一句话规则>**：<为什么/怎么自查>（源：<PR#/评审 finding/事故 一句话>）
-->
