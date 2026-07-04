# 配置即债务：skill / plugin 的接线与治理

> 装进全局配置的每一个 skill、command、rule，都不是"备着总没坏处"——常驻注入的是
> **每个 session 都要交的税**：context 被灌满、skill 选择列表被污染、内置能力被同名文件
> 遮蔽。配置和代码一样会烂，区别是代码烂了编译器叫，配置烂了**静默生效好几个月**。
> 所以接线要有拓扑，治理要有巡检。

## 接线拓扑：单一真源 + symlink 接入

```
evolab/skills/<name>/          ← 真源（git 管理，改这里）
  └→ ~/.agents/skills/<name>   ← 跨 agent 接入层（symlink）
       ├→ ~/.claude/skills/<name>   ← Claude Code 接入层（symlink）
       └→ ~/.codex/skills/<name>    ← codex 接入层（symlink）

evolab/templates/rules/coding.md   ← 写码纪律真源（paths 条件加载）
  └→ ~/.agents/rules/coding.md     ← 跨 agent 接入层（symlink）
       └→ ~/.claude/rules/coding.md ← symlink；omp 兼容 Claude 配置，同一份两端生效（实测）

同一纪律的 skill 形态：`evolab/skills/source-coding-discipline`（给不支持条件 rules 的
agent，codex 走 `~/.agents/skills` 发现）。**镜像对**，改任一边同步另一边——
不是软约定：`test/mirror-sync.test.sh` 对四段正文逐字 diff（含负例自验），漂移即红；
Claude Code / omp 已走 rules 条件加载，刻意不接这个 skill（双重注入）。
```

- **真源只有一个**，且在 git 里。修 skill = 改仓库 + 提交，所有接入端即时生效，
  不存在"哪台机器上是哪个版本"的问题。
- **接入一律 symlink，不拷贝。** 拷贝 = 分叉的开始：README 抄本会漂移，整仓拷贝会把别人的 81 个 command、47 个 agent、32 条死 hook 和
  169KB rules 一起拖进家门（2026-07-04 清理实证，见文末）。
- symlink 的副产品是**断链可机检**：目标删了，链子留着，一行 shell 扫得出来——
  拷贝烂掉是查不出来的。

## 三条治理原则

1. **常驻 vs 按需，是最贵的一个决定。** rules / CLAUDE.md 每 session 全量注入，
   command / agent 每 session 进选择列表——只有"每个 session 都真用"的东西配得上常驻。
   工程规范（git 流程、可观测性、后端手册）沉在 skill 里按需加载，不进全局 rules。
2. **别装大礼包。** 社区合集（ECC / oh-my-claudecode 之流）的安装方式是整仓拷进
   `~/.claude/`，卸载不干净、hook 抄了前台没抄引擎、rules 与你自己的方法论打架。
   要哪个能力，单独装官方 plugin 或抄进真源自己养。
3. **归档不删除。** 清理时 `mv` 到 `~/.claude/_archive/<日期>/`，观察两周无感再删。
   撤回成本 ≈ 0，符合按可逆性分配自主权（→ `agency-by-reversibility.md`）。

## 巡检（半年一次，或任何"装了个包"之后）

```bash
# 1. 断链扫描：所有接入端各跑一遍
for l in ~/.claude/skills/* ~/.codex/skills/* ~/.agents/skills/* ~/.claude/rules/*; do
  [ -L "$l" ] && [ ! -e "$l" ] && echo "BROKEN: $l -> $(readlink "$l")"
done

# 2. hook 真伪对照：生效层只有 settings 家族与已启用 plugin 的 hooks.json。
#    躺在 ~/.claude/hooks/ 等非标准路径里的定义是"文件在、没接线"的假 hook。
cat ~/.claude/settings.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('hooks',{}))"

# 3. 遮蔽检查：~/.claude/commands/ 里的同名文件会盖掉内置 skill
#    （/code-review、/verify 曾被社区阉割版遮蔽数月而不自知）。
ls ~/.claude/commands/ 2>/dev/null

# 4. 权限垃圾：setup 向导写坏的条目（Bash(then)/else/fi、指向已卸载包的死路径）
grep -E 'then|else|fi\)|marketplaces' ~/.claude/settings.local.json
```

判据一句话：**列出来的每一项，都要能答出"谁在用、最近一次用是什么时候"**；答不出的进归档。

## 2026-07-04 清理实录（本篇的实证来源）

| 发现 | 规模 | 处置 |
| --- | --- | --- |
| ECC 大礼包整仓拷贝残留 | 81 commands + 47 agents + 32 条从未接线的 hook + 169KB rules（common/zh 双语双份、每 session 约 4 万 token） | 全量归档；rules 只留自写的 `coding.md` |
| 断链 symlink | 9 条（目标早已删除） | 删除 |
| 无引擎的 hookify 抄本 | 4 commands + 1 agent（规则写了也不会拦） | 归档，换官方 plugin |
| oh-my-claudecode 卸载残留 | 空壳目录 + settings.local.json 里 9 条死/垃圾权限 | 归档 + 清理 |
| 内置 skill 被遮蔽 | `/code-review`、`/verify` 被本地同名阉割版盖住 | 归档后内置版自动浮出 |
| 用不上的领域包双份拷贝 | Cloudflare 全家桶 ×7 在 `~/.claude/skills` 和 `~/.codex/skills` 各一份实体 | 双侧归档 |
| 条件加载规则失效 | `coding.md` frontmatter 的 `---` 提前闭合，`paths:` 为空 → 一直无条件全量注入，omp 侧则完全吃不到 | 修 frontmatter；真源挪 `~/.agents/rules/`，`~/.claude/rules/` 回链；omp 实测按 paths 条件加载成功 |
| 安装器锁文件失真 | `~/.agents/.skill-lock.json` 登记的 31 个 skill 全部早已不在 | 归档 |
| **清理误伤自研 skill** | `source-coding-discipline`（写码纪律的 skill 形态，codex 专用）混在社区 skill 里被一起归档——它不在安装器 lock 里，这个信号当时漏看了 | 恢复并真源化进 `evolab/skills/`；教训：清理前先分"自研 / 装的"，判据=安装器 lock + git remote |

清完的终态：skills = 6 个 evolab 真源（Claude Code / omp / codex 三端 symlink 接入），
agents / commands 清零，rules 只剩一份条件加载的 `coding.md`，
plugins 4 个全部"已启用且说得出用途"。配置表面积缩到能一屏答完"谁在用"。
