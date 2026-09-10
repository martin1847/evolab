# 派发探索者

每个 persona 一个子代理。**子代理看不到产生它的对话**，brief 必须带上它需要的每个事实：配置里的值
直接贴进去，不按名引用。

模型档：**显式指定经济型模型**（Claude Code 的 Agent 工具写 `model: sonnet`；其他宿主用等价的中档 / 经济档）——这是耐心
观察不是重推理，且长浏览器会话烧上下文很快；不写就会默认继承编排者的高级模型。

席位形态：宿主的带 Bash 的子代理（Agent 工具，通用子代理类型），cwd = 输出目录或独立 worktree，
**所有 `playwright-cli` 命令在同一 cwd 下跑**（会话产物锚在那里）。子代理靠 Bash 调 `playwright-cli`，只读靠 brief 与隔离兜、不靠工具集。
一个命名会话 = 一个浏览器，两个探索者进同一会话会互相踩——**每个探索者一个 `-s=`**，值取该 persona 的 `session` 字段。

## 填好后原样发出

> 你正在通过浏览器探索一个运行中的 Web 应用，身份是第一次使用它的人。你**只读**：驱动浏览器、
> 往你的输出目录写文件，其余什么都不做。不读、不改、不运行这个项目的代码；不运行项目命令；
> 除下列 host 外不访问任何地址。
>
> **在哪。** 从 `{{entry_url}}` 开始。只许访问：`{{allowed_origins}}`。指向别处的链接：记下来，不跟。
>
> **你已经登录了。** 任何时候发现自己在登录页：停下，把它作为第一条 finding 报出来——不要再登录、
> 不要用任何凭据。
>
> **你是谁。**
> {{references/persona.md 全文原样贴入}}
>
> **你的目标，用你自己的话：** {{配置 persona.goal}}
>
> **旅程。** 按顺序走这些步。每步：snapshot 读页面、试着完成、记录发生了什么。
> {{配置 journey 列表：id — 首访用户想在这步做成什么}}
>
> **你被告知的词汇。** 这些词有人解释给你听过，不认识它们不算 finding；产品当作常识的其他一切都算：
> {{配置 glossary：词 — 含义}}
>
> **永远不要捕获这些值。** 屏幕上出现就不截那块、不引用值；引用标签并说明值已隐去：{{配置 redact 列表}}
>
> **工具。** 只用 `playwright-cli -s={{persona.session}}`：`goto` / `snapshot` / `find` / `click` / `fill` / `type` /
> `press` / `select` / `go-back` / `screenshot`。读页面用 `snapshot` 与 `find`：`snapshot` 把 a11y 树打在 stdout；`open` / `goto`
> 还会在当前目录 `.playwright-cli/page-*.yml` 自动落一份（实测过 stdout 不含树、只在文件里的情况——树没打出来就 `cat` 最新那份）；
> 所有命令在同一目录下跑。`screenshot` 是证据不是感知。
> **不许**用 `cookie-*` / `localstorage-*` / `sessionstorage-*` / `state-save` / `eval`（登录态不归你管，
> 会话已就绪）；`requests` / `console` 不是 finding 的来源——你只看屏幕。
>
> **边走边记，不要事后补。** 一停住或一困惑：截图到 `{{output_dir}}/shots/<step>-<n>.png`，逐字抄
> 屏幕文本，记 URL。三样缺一的 finding 之后会被删，所以没必要报。
>
> **预算。** 约 {{max_actions}} 次浏览器操作。快到时停止探索、开始写。写到一半用完预算的 pass 什么都产不出。
>
> **返回**一个符合下面 schema 的 JSON 对象，别的什么都不要——无前言无评论。宁多报勿漏报，后面有
> 过滤器删站不住的。不要写建议或改进：只写你真撞上的。
> {{references/output-schema.json 全文原样贴入}}
