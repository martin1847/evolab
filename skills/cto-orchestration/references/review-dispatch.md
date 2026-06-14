# codex 评审派发模板（send-keys 文本）

> 起会话：`tmux new-session -d -s <proj>-<task>-codex -c <同一worktree> 'codex'`
> 启动弹更新提示先 `send-keys '2'` + Enter 跳过。评审期间 omp 不得改同一 worktree。

## 首轮评审

```
Independent code review. Review commit <sha> (the only commit(s) on <branch> vs origin/<base>)
in this worktree (<server root>). Context docs (read first): <goal.md> , <findings.md> (同目录).
Review focus: (1) <该变更最危险的轴，点名：旗标关路径零行为泄漏 / 崩溃恢复 / 并发竞态 /
降级语义 / 安全契约>; (2) <次轴>; (3) test adequacy; (4) scope discipline vs the goal
guardrails; (5) <作者声明的可疑点，要求独立验证，如"2 个预存失败 stale-on-base"的说法>.
Write your review to <REVIEW_codex.md 绝对路径> with severity-tagged findings
(blocker/major/minor/nit) and a final verdict (approve / request-changes).
Read-only review: do NOT modify code or commit.
```

## 复审（第 N 轮）

```
Round <N> re-review: commit <sha> addresses your findings — <逐条一句话>.
Verify each is properly closed — especially <上轮 HIGH 的修复自身的新风险，例如
"recovery path 自身是否 race-safe（恢复 vs 迟到的协调器 finally 双跑？）">,
and confirm no other changes snuck in. Append "Round <N>" verdict to <REVIEW_codex.md>.
Read-only.
```

## 收敛准则注入（防乒乓，第 3 轮左右仍未收敛时）

```
CONVERGENCE CRITERION (from the orchestrator, also state it in the findings doc):
<兜底机制> is a best-effort backstop — <主闸机制> is the primary gate. After this round,
the bar is: all COMMON <X> covered with tests. Further exotic gaps are minor follow-ups,
NOT ship blockers.
```

## 修复派回 omp 模板

```
codex round <N>: request-changes — read <REVIEW_codex.md> and address ALL findings in a
follow-up commit on this branch: [<severity>] <一句话> — <修复方向，含"mirror the EXACT
existing behavior of <同场景的既有路径>"这类对齐要求>; ... Add tests: <修复前必须红的
回归测试>. Re-run the suites, commit, append the change note to the findings doc.
```

## 经验

- **必点评审轴：LLM 产出进入结构化管道的接缝**——凡是"生成内容被当数据消费"的地方
  （提取结果落库、合成答案进解析器、引用标记进溯源链），评审必须验证：①有无内容
  契约（拒收 PII/秘密/编造）；②有无溯源校验（引用/ID 必须能对回真实来源集，幻觉
  条目剥除而非放行）；③测试 fixture 里要有"恶意/幻觉样本"且无防护时必红。
  实战两连击：记忆提取缺 PII 契约、KB 合成缺引用溯源——同一类洞。
- 每轮评审都点名"上一轮修复可能引入的新洞"——4 轮抓 4 个真问题是常态，不是评审过严。
- 要求 codex 独立复跑测试 + current-vs-base 对照（旗标关字节级一致的验证方式）。
- 作者的"与本次无关的预存失败"声明必须让 codex 在干净 base 上复现验证。
