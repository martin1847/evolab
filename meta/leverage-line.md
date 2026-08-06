# 杠杆线（leverage-line）

> 每项能力/活动都有一条杠杆线：线下是甜点区（小投入换走大部分回报），线上边际产出进入
> 衰减尾部。原则：**跨线后的继续权不归执行者**——继续必须经上一层显式裁决并追加预算，
> 不存在默许续投。与可逆性正交：可逆性管**权限轴**（这动作能不能做），杠杆线管**继续权轴**
> （这投入值不值得续）；两轴各自升级、互不替代。
> 学名锚：satisficing（Simon）/ value of computation（Russell-Wefald 元推理）/
> saturation-based stopping（fuzzing·测试停机）/ tolerance + management by exception（PRINCE2）。

## 机制：产出自然衰减，投入没有

同一面上的新发现服从衰减曲线——逐轮新产出近似几何衰减，残余可估（capture-recapture /
Good-Turing 类残余估计是它的统计形态）。投入却不自然衰减：系统里缺一条把**边际产出耦合回
继续决策**的负反馈回路，执行者在开环里惯性前进——沉没成本与"再来一轮就好"把继续变成默认。
杠杆线协议 = 给系统补上这条平衡回路（信号 → 分诊 → 裁决，闭环）。

## 跨线信号（三条一份契约，正本与 fire 点同文；读产物，不读心）

- **产出衰减**：逐轮**新增 blocking** 计数（读各轮 Tally 行）——内容轮 ≥3 且最近两轮不升、
  各 ≤1；衰减尾部的常见形态是从"找新问题"转入打磨已有产物的措辞。
- **remedy 逆转**：本轮 remedy 撤销上轮 remedy 引入的行（同一 finding 的**文本**逆转可机检；
  语义逆转归编排者判断，不标机检）。
- **同面重复**：同一「评审轴 + 路径簇」连续 ≥3 轮出 finding（面身份从产物导出。区别于
  同 finding 两轮止损：那管一条 finding 修复链，这管一个面）。

## 跨线协议（tolerance + andon 合体）

命中任一信号 → 执行层 STOP-and-report（不弃、不续）→ 编排者算杠杆账（正源
`skills/cto-orchestration/SKILL.md` §2）→ 值得续则**显式追加预算并记账**（每次追加是新
tolerance，不是默许）；追加量大或触及不可逆 → 冒泡主理人（决策队列）。定义跨线自动信号的
阈值时 → 宁钝勿敏（对象：自动告警阈值）——过敏的告警会被学会无视（andon 已知失效模式）。

## fire 点（本篇只指认，规则在各正源）

- 评审续轮分诊行：`skills/cto-orchestration/references/review-dispatch.md` §复审。
- 防御性复杂度前提问：`skills/cto-orchestration/references/goal-template.md` Value gate /
  Preflight 区。
- 既有单域特例同属此线：`skills/cto-orchestration/SKILL.md` §2（杠杆账 + SHIP-BLOCKING 续轮 +
  同 finding 两轮止损 + max-rounds）、`skills/cto-orchestration/references/goal-template.md`
  §Guardrails 自证止损、`skills/agent-frontend-standard/SKILL.md` §视觉验证环迭代预算、
  `skills/cto-orchestration/references/retrospective.md` §教训分层沉淀·晋升三门之样本门。
- runtime 机械档（连续轮 Tally 自动解析告警）：候选，纸面档 fire 实证 ≥2 后再升
  （复杂度按证据升级）。

## 来源

两个外部席位同向实证：一场 24 小时审计——最终有效产出 ~80% 在前 24% 投入内锁定，后段换到
自我纠错与建了再删的返工；一场测量整夜重跑、零复验性增量。且两案发生时止损散文均已在场
而未 fire——故本篇落地即带电（fire 点全为带电清单行或既有门），不再新增只靠记忆的散文规则。
