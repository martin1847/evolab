# Truth is not checker output

> **坏样本红、好样本绿、量具坏时报不知道；缺一不消费 PASS。**

## 核心合同

checker 输出不是事实，只是从观测面推导出的认识论结果。控制链必须保持五层分离：

```text
truth → observable → checker → outcome → action
```

任何一层看不到、判不准或自身故障，都不能被压成 `PASS`。

## Outcome 与 Action 分离

Outcome 只表达“现在知道什么”：

| Outcome | 含义 |
|---|---|
| `PASS` | 在声明的 scope 内，证据支持条件满足 |
| `FAIL` | 已观测到足以推翻条件的事实 |
| `ABSTAIN` | 输入、证据或适用性不足，无法判断 |
| `ERROR` | checker、依赖或观测链自身故障 |

Action 只表达“接下来做什么”：`ALLOW / DENY / HOLD / REMIND`。

- 高风险 hard gate：`ERROR/ABSTAIN → HOLD 或 DENY`，不得放行。
- reminder-only：数据缺失或内部异常时软 `ABSTAIN`，静默或降级提醒，不阻断工作。
- `FAIL` 是否 `DENY`、`PASS` 是否 `ALLOW`，仍由场景策略决定，不能写死在 checker truth 中。

## 最小可信控制

每个高风险 checker 至少同时具备三联控制：

1. **Known-bad**：目标问题存在时必须 `FAIL`。
2. **Known-good**：干净输入必须 `PASS`，防止恒红。
3. **Checker-broken**：malformed input、缺字段、依赖异常或内部异常必须 `ERROR/ABSTAIN`，不得伪装成 `PASS`。

控制样本还要覆盖代表性 variants 与 exit paths：语法/空白/Unicode 变体、边界值，以及 success、cancel、timeout、crash、dependency failure 等出口。

否定性结论前先用 known-positive 校准检测链；看不见已知存在的目标时，结论保持 `ABSTAIN`。

## evolab 当前落地

- watcher/dispatch runtime 返回 typed states，区分 DONE、WAITING、FAILED、STALLED、NO-HOOK、TIMEOUT 等；fresh deliverable 是完成判定的 known-positive，陈旧或缺失产物不能打开 DONE gate。
- `cto-guard-bash.py`、`cto-guard-agent.py`、`mail-guard.py` 的高风险 PreToolUse 对 malformed JSON、必填字段错误和内部异常 fail-closed，输出 `CHECKER-ERROR`/exit 2；测试同时保留 known-bad、known-good、checker-broken。
- PostToolUse reminder 与 queue freshness 保持 reminder-only：无法判断时软 `ABSTAIN`，不把提醒器故障升级为全局阻断。
- goal preflight 当前只验证声明的 presence/shape；它不是事实 oracle，不能证明 probe 真执行、结果真实或方向正确。

## 当前不做

暂不引入全局 checker registry、统一 digest、FP/FN 统计平台或新的治理系统。先在现有 runtime seam 固化三联控制和 outcome/action 分离。

只有当某个 verdict 需要跨 checker 或 contract 版本复用时，才为该局部证据加入 digest 与 freshness 绑定；不提前全局化。

## 参考

- “评测本身也必须被评测”不是小概率洁癖，而是现实工程问题。[OpenAI：Separating signal from noise](https://openai.com/index/separating-signal-from-noise-coding-evaluations/)
- 人工注入小故障，测量测试套件有没有能力发现它，而不是满足于 coverage 或绿灯。[Google Mutation Testing](https://research.google/pubs/state-of-mutation-testing-at-google/)
- [Anthropic agent eval 指南](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)明确区分了 transcript 中“agent 说订好了”和环境中“数据库是否真的存在预订”，并建议多 grader、多 trial 和 outcome verification。
- 未经验证的 test oracle 导致的空洞验证（vacuous verification）.
    - [Test oracle problem](https://discovery.ucl.ac.uk/id/eprint/1471263/)
    - [Vacuous pass](https://weizmann.elsevierpure.com/en/publications/efficient-detection-of-vacuity-in-temporal-model-checking-2/)
    - [Measurement-system validity failure](https://www.itl.nist.gov/div898/handbook/pri/section2/pri21.htm)
    - [Goodhart/reward hacking 是后续放大器](https://openai.com/index/how-we-monitor-internal-coding-agents-misalignment/)