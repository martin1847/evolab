# 附录 F — 自检清单与评审蒸馏门禁（selfcheck gates）<!-- trunk:selfcheck-gates.md -->

> **电在回路（shock-in-the-loop）：soft prompts steer, hard gates hold the line。**
> canonical：`cto-orchestration/references/shock-in-the-loop.md`（下沉判据/分层/DENY 三件套/
> override 有形）；公开锚点：krpc `skills/krpc/references/guardrails.md`（概念为本工程体系首创）。
> 写作纪律**「能电不文」**：能下沉的绝不写散文；散文只留方法论与门判不了的判断项（可稍详不啰嗦）。
>
> 定位：门禁**从哪来、如何演化**。门禁接口长什么样归附录 C（engineering-interface），
> 本章管的是另一条供给线：把真实评审 findings 蒸馏成仓库自己的护栏。
> 实证来源：某双服务后端仓活体运行（五条负探针实测；曾实抓「契约语义收窄未升版」
> 「聚合数组漏登静默失守」两类真事故）+ krpc 仓 SPEC 镜像漂移 / docs-site 错分支两起真事故。

## 回路（机制本体）

```
真实评审 finding / 真事故
  → 蒸馏成 docs/PR_SELF_CHECK.md 条目（作者提 PR 前过一遍，人和 agent 同一份）
  → 其中可机检的下沉 diff-scoped pre-push hook（毫秒级拦截）
  → 每关带负探针，登记进门禁台账（AGENTS.md 验证配方节）
  → 下一个真 finding 继续喂清单
```

价值主张：把评审往返从多轮压到 1 轮；清单喂人也喂 agent（AGENTS.md 指过去，
agent 提 PR 前自查）。

## 铁律

- **hook 里每一关必须能指到一次真实事故或评审 finding；禁止凭理论发明关卡。**
  这是本机制与一般 lint 清单的本质区别，也是防清单腐烂成仪式的机制。
  新仓落地时清单可以为空——先攒 findings 再蒸馏，不空写通用建议（同 hub 的 TBD 纪律）。

## 下沉判据（清单条目 → hook 关卡）

全部满足才下沉，否则留在清单里靠人/agent 自查：

1. **可机械判定**：纯 git + grep/sed 能出确定性结论，无需理解语义。
2. **毫秒级**：不跑构建、不跑测试、不碰网络（构建级检查归附录 C 的 check/test 或 CI）。
3. **diff-scoped**：只看本次 push 的 range，不做全仓扫描（range walk 骨架 +
   `git config hooks.baseline` 参数化基线分支，见 bootstrap skill 的 `pre-push.template`）。

## hook 是提醒、CI 是门

pre-push 可被 `--no-verify` 绕过，本质是**快速反馈层**（write-time 预防，软层）。
脚本必须设计成可带 range 参数独立调用（如 `pre-push --range origin/main..HEAD`），
CI 复跑同一脚本才构成真门（硬层归 IaC / required CI，与附录 C「本地 hook 不冒充
required CI」同款双层）。

## 负探针台账

每关落地时同车交付负探针配方（怎么让它红、红完怎么恢复），登记进该仓 AGENTS.md
的验证配方节（无此节则建）。**没有实测过 exit 1 的关卡不算存在**——与「验证诚实性」
同源：门禁自身也要正向证据。

## 与附录 C 的分工

| | 附录 C engineering-gate | 附录 F selfcheck gates |
| --- | --- | --- |
| 供给线 | 语言/工具链静态质量（lint/type/test） | 评审 findings / 事故蒸馏 |
| 挂载点 | pre-commit + CI | pre-push + CI |
| 内容来源 | 语言规范（附录 C §1–§6 canonical） | 本仓真实教训，仓仓不同 |
| 速度契约 | check/test 级 | 纯 git+grep 毫秒级 |

## 落地路径

- 新仓：`repo-governance-bootstrap` 建骨架（`pre-push.template` + `PR_SELF_CHECK`
  skeleton + AGENTS.md 指引 slot），清单从空开始。
- 存量仓：从最近一季真 findings 里蒸馏首批条目；可机检的按下沉判据挑 1–2 关起步。
- krpc 生态有面向下游的自包含快照（krpc 仓 `skills/krpc/references/guardrails.md`，
  公开仓不能引私有 skill）；方法论演化以本章为 canonical，快照机会性同步。
