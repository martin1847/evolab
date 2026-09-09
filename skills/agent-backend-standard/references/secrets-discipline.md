# 附录 E — 秘密接触面纪律（分离 · 注入）<!-- trunk:secrets-discipline.md -->

> hub `agent-backend-standard` 的一章。来源:某 IaC 伞仓实证蒸馏(2026-07,同 session 三次同构
> 失手换来)。2026-09 减法:原「deny 一刀切 + 金丝雀」两件撤出——permissions deny 通配实测
> 误拦远大于召回(含该文件名的普通命令与子 agent 一并被拒,任务停摆),值的防线改为
> gitignore + `chmod 600` + 进程注入。**范围**:agent 会接触本地凭证/秘密值的任何仓——目标是把
> "agent 失手把密文送进 transcript/stdout/git"从纪律问题降为结构上没有理由发生(尽力而为层,不是沙箱)。

## 0. 本质

**秘密的元数据与值物理分离后,agent 就永远没有"读值文件"的正当理由**——说明文档可整读,
值只经注入进子进程。不用 permissions deny 拦值文件:拦不住 `open()` 类绕过面,却把含该文件名的
一切命令连坐,收益是零召回、代价是整条任务停摆。

## 1. 两件(顺序即依赖:先分离,注入才唯一)

1. **值/元数据物理分离**:说明文档(如 `ACCESS.local.md`)只留元数据 + 秘密**名字** + gotcha
   ——agent 可整读、零遮蔽工序;值进纯 `KEY=VALUE` 的 env 文件(如 `ACCESS.local.env`,
   gitignored + `chmod 600`)。混排文档做遮蔽是失手温床(regex 遮蔽会漏盖普通
   key:value 行,凭证直进 transcript)。**命名刻意不入 `.env` 家族**:dotenv 生态会
   自动加载 `.env*` 进每个 dev 进程(与"值只在显式 source 时进子进程"相悖),且
   `ACCESS.local.md↔.env` 同词干让分离结构写在文件名上;gitignore 仍同时盖 `.env*` 作生态兜底。
2. **注入形态唯一**:`set -a; source <env>; set +a; <cmd>`——值只进子进程 env,不落
   stdout/argv/transcript;脚本一律 `os.environ` 取值。禁止任何"打印出来再粘贴"形态。

## 2. 失效模式(同构识别)

任何遮蔽 / 扫描面(pre-commit check-secrets、redaction hook)只用假数据验证,真值永不作测试载荷
——"用真密文验证防护面"本身就是事故:失效即全泄、被迫全库轮换。

## 3. 与既有纪律的关系

- 全局层(不打印 stdout/不进 transcript/git、只验派生值)是行为纪律;本附录把它
  **结构化**——分离让说明文档零遮蔽工序,注入让值不经 stdout/argv。
- CI/服务端 secret 扫描(push 保护、pre-commit check-secrets)是收口层,与本附录的
  write-time 防失手层互补,不互替。
