# 附录 E — 秘密接触面纪律（分离 · 注入 · deny · 金丝雀）<!-- trunk:secrets-discipline.md -->

> hub `agent-backend-standard` 的一章。来源:某 IaC 伞仓实证蒸馏(2026-07,同 session 三次同构
> 失手换来的四件套,已实装验证)。**范围**:agent 会接触本地凭证/秘密值的任何仓——目标是把
> "agent 失手把密文送进 transcript/stdout/git"从纪律问题降为结构不可能(尽力而为层)。

## 0. 本质

**秘密的元数据与值物理分离后,agent 就永远没有"读值文件"的正当理由——deny 才能一刀切。**
所有防护面在接触真密文前必须用假数据金丝雀自证有效(防护自认为在位 ≠ 在位)。

## 1. 四件套(顺序即依赖:先分离,deny 才成立;先金丝雀,真值才进场)

1. **值/元数据物理分离**:说明文档(如 `ACCESS.local.md`)只留元数据 + 秘密**名字** + gotcha
   ——agent 可整读、零遮蔽工序;值进纯 `KEY=VALUE` 的 env 文件(如 `ACCESS.local.env`,
   gitignored + `chmod 600`)。混排文档做遮蔽是失手温床(实证:regex 遮蔽漏盖普通
   key:value 行,5 组凭证进 transcript)。**命名刻意不入 `.env` 家族**:dotenv 生态会
   自动加载 `.env*` 进每个 dev 进程(与"值只在显式 source 时进子进程"相悖),且
   `ACCESS.local.md↔.env` 同词干让分离结构写在文件名上、deny 锚精确不误伤构建用
   `.env`;gitignore 仍同时盖 `.env*` 作生态兜底。
2. **注入形态唯一**:`set -a; source <env>; set +a; <cmd>`——值只进子进程 env,不落
   stdout/argv/transcript;脚本一律 `os.environ` 取值。禁止任何"打印出来再粘贴"形态。
3. **deny 一刀切**:项目 settings deny `Read(<env 文件>)` + Bash 全系 display 命令模式
   (cat/grep/sed/awk/head/tail/strings/od/base64…作用于该文件)。定位=**防失手,不是沙箱**
   (python `open()` 等绕过面存在,如实标注,不冒充安全边界)。
4. **金丝雀纪律(MUST,血价最高)**:任何秘密防护面(遮蔽脚本/deny 规则/redaction hook)
   上线或变更后,必须用**假数据金丝雀跑全矩阵**(Read / 各 Bash display 形态 / 正控注入),
   全绿才允许真密文进该路径。注意 settings permissions 默认**会话重启才加载**——改完先
   金丝雀验加载,勿假设即时生效(实证:deny 配好未验加载、拿真文件测"预期被拒",
   21 值全量进 transcript,被迫全库轮换)。

## 2. 失效模式(同构识别)

一句话病理:**"防护自认为在位 → 用真密文验证 → 失效即全泄"**。任何"用真值测试防护面"
的动作本身就是事故——测试防护面永远用金丝雀,真值只在防护面已被金丝雀证实后进场。

## 3. 与既有纪律的关系

- 全局层(不打印 stdout/不进 transcript/git、只验派生值)是行为纪律;本附录是把它
  **结构化**——分离让 deny 可行,金丝雀让验证不再依赖真值。
- CI/服务端 secret 扫描(push 保护、pre-commit check-secrets)是收口层,与本附录的
  write-time 防失手层互补,不互替。
