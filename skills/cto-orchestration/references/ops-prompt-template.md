# 运维 agent 取证/验证提示词模板

> 用途：我们够不着的环境（prod、独立运行时 DB、SigNoz）的只读取证或部署后验证。
> 写成自包含单文件放 `docs/orchestration/<NAME>_PROMPT.md`，由用户整份转交。

```markdown
# Prompt for ops agent — <一句话目的>

> Context: <两三行背景：什么问题、我们已知什么、这次要定什么>。
> READ-ONLY: run SELECTs / queries only. Do NOT modify any rows or config.
> Do NOT dump document/customer contents — metadata, counters, identifiers only.

## Target
<环境/库/trace 范围 + 精确 id>

## Check 0 —（部署验证类必加）running-state trap
验证 RUNNING 容器内的实际配置（docker exec ... env），不是磁盘上的文件——
compose env_file 在容器创建时注入，docker restart 不会重读，必须 recreate。
不通过则后续检查无意义，报告并停止。

## Queries / Checks（每项一个结果表）
1. <SQL/查询全文，占位符 <table> 注明按实际 schema 替换> —— 预期读数 + 判定规则
   （"X≈5 且单文档 ⇒ C1"这种一眼可判的形式）
2. ...

## Report format
（给死格式，让回报可直接粘贴决策）
```
field_a=__  field_b=__  (Check 1)
...
One-line verdict: <枚举的可选结论>
```

## Also report（顺带捎带的小问题，如部署镜像 tag/SHA）
```

## 经验

- 判定规则写进提示词，让运维不需要理解业务也能给出 verdict。
- 一次取证一份文件；部署后验证复用同一份（POST-FIX 版），便于前后对照。
- 运维的现场观察优先于我们的代码推断——矛盾时先查构建漂移（prod 跑旧版本）。
- 顺带问题（镜像 SHA、为什么某配置曾被改）放末尾"Also report"，不增加主流程负担。
```
