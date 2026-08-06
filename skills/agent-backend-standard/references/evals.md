# III-10 — 评估与测试（evals）

> 素材基线：Anthropic demystifying-evals、Shopify judge 校准两篇、τ-bench、
> Terminal-Bench 噪声实验、mcp-builder。

## 1. 起步姿势（最常做错的三件）

- **从 20–50 个真实失败起步**，不是从想象的任务集起步（同附录 F 铁律：禁理论条目）。
- **好任务判据**：两位领域专家独立打分会得出同一 pass/fail。达不到→任务先重写。
- **grade outputs, not paths**：判产出不判路径；每 trial 干净起始、禁共享状态
  （共享状态⇒correlated failure+虚高分）。

## 2. 统计纪律（把 eval 当 CI 门时的两条硬约束）

- **pass^k 不是 pass@k**：生产要的是"每次都对"。单次 75% ⇒ 连续 3 次仅 ~42%
  （τ-bench 实测 SOTA 8 连跑 ~25%）。0% pass@100 通常是任务坏了，不是模型不行。
- **基础设施噪声下限**：仅环境配置差异即可摆动 ~6pp（Terminal-Bench 实测）——
  **<3pp 的差距不构成能力结论**；eval 环境版本要 pin。

## 3. LLM-as-judge 校准（不校准的 judge 是随机数发生器）

- 用 Cohen's Kappa 对人类基线校准（迭代到接近人类间一致性水平）；
  验收法="随机把 judge 换成人，下游能否分辨"。
- 高风险判定用**多 judge 全体一致门**（四前沿模型 consensus，宁漏勿错标）；
  每维度独立 judge；必须给 "Unknown" 逃生口。
- Ground truth 用真实生产分布采样，不用精挑 golden set；**生产流量回流成为
  下一轮采样池**（飞轮）。

## 4. 威胁模型：被测物会作弊

reward hacking 是一等威胁：`sys.exit(0)` 骗 harness、记住测试输入、改计时函数——
可见/隐藏测试差距随代码规模每 10× 增 +28pp。对策：隐藏测试集、判产出行为而非
测试通过、异构验证（做的人不给自己判分）、Kent Beck 三红旗进 review 清单
（凭空循环/未要求的功能/禁删测试）。测试套件本身按攻击面对待。

## 5. Agent-facing 表面的 eval（生态空白=先行位）

- MCP server：10 道需多次工具调用的真实问题、答案单一可字符串比对、脚本直跑
  （mcp-builder 形态，无 judge 无模糊匹配）。
- 工具定义/文档/错误文案的 eval 公开实证≈零——自建即领先（配 II-4 §1 质量定义）。

## 6. 电在回路接线

eval 进 CI：阈值门（fail-on-regression）+ trialCount 测方差；冒烟跑子集、合入跑
全量（两级门同附录 F）。eval 结果随生产 trace 流动（gen_ai.evaluation.result 事件，
语义层见 observability-standard）。
