# Evolab

**A²时代的 AI 工作流工具箱** —— Agentic AI × Anything，一个编排者，调度一群专家。

> An AI-native workflow & orchestration toolkit.

Evolab 是 **阳哥进化论** 的 AI 方法论 / skill / 工具栈合集，会持续生长。不是工具清单，
是一套**怎么想**——沉淀自真实的多 agent 编排实战 。

---

## A² = Agentic AI × Anything

> **一拖多：一个编排者，调度一群专家 agent。(Supervisor + Specialist )**

注意"一"指的是**调度者**，不是干活的：不是单个超级 agent 包打天下（那是公认反模式），
而是**一个编排者调度一群各管一段的专家 agent**——执行、评审、取证分开。这就是业界讲的
**agentic orchestration / 多 agent 编排（orchestrator-worker）**，evolab 把它沉淀成一个人
可直接复用的方法论（旗舰 skill `cto-orchestration`）。

范式是 **A²**——Agentic AI 乘以 Anything：你不再亲手做事，而是**调度** agent 去做任何事；
产出从"代码"变成"goal / 监控 / 评审 / 决策 / 落盘"。

四条让"一拖多"不塌的支柱：

1. **编排者不写产品代码。** 哪怕"顺手就改了"也派出去——放大的前提是不亲自下场。
2. **按可逆性分配自主权。** 可逆的事直接做；不可逆的事（push / 迁移 / 删除 / 对外）先说
   意图 + 影响面再放行。同时治 agent、治自己。→ `meta/agency-by-reversibility.md`
3. **对抗式评审。** 执行和评审交给不同 agent，点名最易翻车的轴、让评审写探针复现。交叉
   评审屡次抓到双方都漏的真问题。→ `skills/cto-orchestration`
4. **文档治理管生命周期。** 写入有规范、收口没规范 = 必烂。
   → `skills/repo-governance-bootstrap` + `meta/`

## 目录

| 目录 | 是什么 |
| --- | --- |
| **`skills/`** | 可直接装进 Claude Code 的 skill。当前：`cto-orchestration`（**旗舰**——多 agent 编排）、`repo-governance-bootstrap`（文档治理）。后续更多。 |
| **`templates/`** | 协作设定模板 `CLAUDE.md.example`（人格 + 方法论）。项目治理骨架（AGENTS.md / ADR / roadmap）由 `repo-governance-bootstrap` skill 生成，不在此重复。 |
| **`playbooks/`** | 叙事版：一个真实工作流从头到尾怎么跑（脱敏）。看模式怎么落地。 |
| **`meta/`** | 元认知：可逆性分配 agency、验证诚实性、先测再加（measure-before-more）。**灵魂层**——我是怎么想的。 |

## 用起来

skill 本质是 markdown + 几个脚本——**任何能读项目规则的 AI coding agent 都能用**，不限 Claude Code。

```bash
git clone https://github.com/martin1847/evolab.git
```

- **Claude Code**：把 skill 拷进 skills 目录
  ```bash
  cp -R evolab/skills/cto-orchestration         ~/.claude/skills/
  cp -R evolab/skills/repo-governance-bootstrap ~/.claude/skills/
  ```
- **其他 agent（Cursor / Codex / Cline / …）**：把 `skills/<name>/SKILL.md` 当规则/上下文喂给它，
  或放进该 agent 的 rules / skills 目录。skill 是工具无关的方法论，不绑定某个 runtime。
- `templates/CLAUDE.md.example` 拷成你项目根的 `CLAUDE.md`（或对应 agent 的规则文件），按需删改。

**懒人法——把下面这段直接丢给你的 agent，让它自己装：**

> 帮我 clone https://github.com/martin1847/evolab ，先读一遍 `README.md` 和 `meta/`，
> 理解核心理念 A²——一个智能体调度一切。然后装这两个最核心的 skill：`cto-orchestration`
> （多 agent 编排）和 `repo-governance-bootstrap`（仓库治理）到你的 skills / 规则目录
> （Claude Code 放 `~/.claude/skills/`）。然后把`templates/CLAUDE.md.example` 的协作设定
> 并入我的规则文件。

## 脱敏说明

接入自己的项目时，私货留在你自己的 memory / docs，skill 保持通用——**这条规矩本身就写在 `skills/` 里。**

## 关于

整理自公众号 **阳哥进化论** 的 AI 工作流实践，持续更新。

<img src="assets/wechat-qr.jpg" alt="阳哥进化论 公众号二维码" width="180">

## License

[MIT](LICENSE).
