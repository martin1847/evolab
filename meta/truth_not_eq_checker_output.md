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

## 同源陷阱：三联控制齐了仍可能空绿

三联控制只管样本**存在**，不管样本**从哪来**。量具、坏样本、"要防哪类损坏"的命名出自同一个人
同一个模型时，模型错误对三者是**共模**的——坏样本红了、好样本绿了、三问全过，测出的只是模型自洽。
用同一把尺子量它自己，永远量不出刻度是错的。

判据：坏样本必须打在**承诺面**（读者会信的那句话，破它即行为真变坏），不能打在实现的中间结构
（内部表 / 注册表 / 自洽性）。破除共模只有两条路，都要异源：换个模型出题（异构评审在实现前先给
变异清单），或从消费者视角反推（这句承诺骗到读者时，世界上什么会变坏）。

两例同日实证：①「表是路由的唯一真源」的契约测试，四枚变异全打在表上，改真实握手动词/投影/启动
分支后 72 断言照样全绿，异构评审换个打法一击即穿；②随手 grep 统计阻塞频次，62/63 命中全是 goal
footer 里的说明文本——**随手探针同病，且不在"高风险 checker"的措辞覆盖内**，所以这条按人人适用的
判据写，不按门的等级写。

## 为什么机械的 workflow 也会撒谎（第三句的由来）

直觉说机制比人稳定，怎么会撒谎？因为**稳定管的是方差，撒谎是偏置**。机制以近零方差执行的是
它被编码的 spec，不是你的意图——编码错了（观察面选错、谓词写错、scope 圈错），它就以机器级
的可靠性**重复**那个错答案：永远绿、从不累、次次一致。散文错得吵闹而随机，迟早被撞见；错的
机制错得安静而一致，**没有任何东西看起来不对**——一致性反而成了说服力。稳定是放大器，放大对
也放大错。

三个撒谎形态，全有实证：

1. **对 spec 忠诚、对意图失真**：超时旋钮一钮双阀，运维把 send 调快即静默压死握手窗——机制
   分毫不差地执行了有缺陷的编码；漂移门忠实地比对表与注册表，而承诺说的是行为。
2. **世界动了、机制冻着**：服务端 required check 的 include 漏了新路径 → 门红照样合、面板
   全绿（外部席位 n=2 生产实证）；量具盯着 `.output` 而任务型产物恒为 stub——观察面在世界
   变化后失效，机制不自知。
3. **机制看不见自己**：门检查不了"自己有没有被跑过"，锁保护不了"锁文件被自家清理删掉"，
   声明门验不了声明的真伪。自指盲区是结构性的，加码同类机制解决不了。

所以「Workflow outside, intelligence inside」在我们屋里定稿为四短语（NS-1）：
**Deterministic workflow outside, bounded intelligence inside, evidence at the boundary —
and intelligence periodically attacks the workflow.**
前两句让系统便宜地跑（确定性机制管流程/状态/验收，判断力只花在编不出来的地方），第三句让它
不在跑的过程中悄悄烂掉：异构变异打承诺面、活体门抓措辞病、known-positive 校准探针、编排位
对 SHIP 做变异复验。攻击的节律挂在既有触点上（评审轮、大版门、复盘），不新设仪式。

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