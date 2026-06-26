# II-3 — 上下文与 prompt 工程

> hub `agent-backend-standard` 的一章。当前只写实 **prompt 内容生命周期**(有真实素材);通用 context engineering(右高度 system prompt、compaction、context 作有限资源)待素材再扩,*TBD*。

## 1. prompt 内容生命周期(MUST)

prompt 比代码更易腐烂——常住字符串 / 模板 / config,逃过 code review 严格度,也逃过所有工具(它执行、它"对")。

- **判别同附录 A §2.1**:稳定指令不管;**情境绑定**的写死内容(为弱模型写死的格式 hack、客户特例、模型版本耦合)有生命周期。
- **退役标记**(canonical 定义在附录 A `code-dependency-lifecycle.md` §2.2):情境绑定的 prompt 写死项 MUST 带 `EXPIRES:` / `REVISIT-WHEN:` + reason + owner。模型版本耦合打 `REVISIT-WHEN: 换模型`——切模型时 `grep` 扫出。
- **prompt 额外:绑 eval**。prompt 里每个写死的具体值 / few-shot 例子 MUST 能追溯到一个 eval case(IM 侧 AAM `agent-eval-suite`)。**指不出哪个 eval 需要它 → 可疑、可删**;eval 不再需要时,它就该删。

## 2. 通用 context engineering（TBD）
右高度 system prompt、context 作有限资源、compaction / 结构化 note-taking、own-your-context——有真实落地素材再写实(Anthropic context engineering / 12-Factor F2·F3)。

## 一句话
> 情境绑定的 prompt 写死内容打 `EXPIRES`/`REVISIT-WHEN`(标记规则见附录 A)+ **绑一个 eval case**;指不出 eval 即可删。
