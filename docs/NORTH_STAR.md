# NORTH_STAR — evolab 长期架构方向

> v1.0.0 · 仅 maintainer 修订，semver 版本化；ADR 记历史，这里记方向。
> 条目带稳定 NS-ID，供 goal 的 Direction-doc 闸与评审 brief 引用；引用完整性由
> `test/north-star.test.sh` 强制（仓内出现的 NS-ID 必须真实存在——没人检查的原则是注释）。

## NS-1 四短语架构句（分层不变式）

**Deterministic workflow outside, bounded intelligence inside, evidence at the boundary —
and intelligence periodically attacks the workflow.**
确定性 workflow 在外，受约束的智能在内，边界用证据交接——智能定期反攻 workflow。

| 层 | 承担 | 现载体 |
|---|---|---|
| SKILL | 少量稳定原则（何时派工 / 读并行写单线 / goal 合同 / Implemented≠Verified / 不可逆真人授权 / 冷评审与 E2E 判据） | `skills/*/SKILL.md` 主干 |
| references | 门判不了的操作细则——**过渡层**：变得可判定者持续下沉 runtime | `skills/*/references/` |
| runtime | 机械控制：attempt identity · capability · typed status · watcher · 轮数/超时预算 · delivery receipt · stale fencing · 进程收割（缺口台账：permission profile / 通用 retry budget，等实证再做） | `agentctl` + hooks + CI |
| agent | 边界内的专业判断：读码 / 设计 / 实现 / 找问题 / 裁决建议 | omp / codex / claude 席位 |

边界证据形态：回执 sha256 · typed status · 评审探针 + attest · preflight 读数 · 变异红证。
第四短语的机制见 `meta/truth_not_eq_checker_output.md`（同源陷阱 / workflow 会撒谎）。

## NS-2 A²：一个编排者，调度一群专家

「一」是调度者不是干活的：编排者不写产品代码，产出契约、调度、裁决与状态；执行、评审、
取证分席。反模式 = 单超级 agent 包打天下、agent 任意 peer mesh。

## NS-3 能电不文（规则的归宿）

三判据（承重 / 可判定 / 有触点）全过的规则绝不写散文——下沉强制层；判不了全电的执行句退写
带电清单行；SKILL 主干只减不增。判据本体见 `skills/cto-orchestration/references/shock-in-the-loop.md`。

## NS-4 复杂度按证据升级（机制的准入）

单 agent 能解决不加第二个；固定 workflow 能解决不加动态 planner；文件状态能解决不上数据库；
本机能解决不上 federation。新 runtime 机制的准入 = 真实事故或 n≥2 实证，不是架构美感。
