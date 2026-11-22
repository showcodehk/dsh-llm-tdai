# dsh-llm-tdai

[English](./README_EN.md) | **中文**

**dsh-llm-tdai** 是 DeepSeek Harness（DSH）的一款插件（bundle）。它给 DSH 的 **llm-pi-ai 通道**补齐会话与压缩请求头，让上游的记忆代理 [TencentDB Agent Memory (TDAI)](https://github.com/TencentCloud/TencentDB-Agent-Memory) 的 MemoryProxy 能把一次会话的历次请求归到同一个会话，并把上下文压缩请求识别为辅助调用。

## 它解决什么问题

DSH 会向模型路由发出三类请求：主对话、上下文压缩（compaction）、会话标题。记忆代理要区分它们，靠两个信号：

```text
x-deepseek-harness-session-id    会话身份（session-<uuid>）
x-deepseek-harness-compact: 1    仅压缩请求携带
```

问题出在会话身份和压缩标记这两个头上：它们只在 `@deepseek-ai/dsh-llm-deepseek` 适配器里发出：

```ts
// packages/llm/llm-deepseek/src/adapter.ts
...requestIdentity.purpose === 'compaction' ? { 'x-deepseek-harness-compact': '1' } : {},
```

如果 provider 走的是 **llm-pi-ai 适配器**（`api: openai-completions`，接自建或第三方的 OpenAI 兼容端点），这两个头都不会发。后果有两个：

- 代理拿不到会话身份，记忆写入会被拆成多个孤立会话；
- 压缩请求被当成主对话，压缩指令和压缩产物一起被记进记忆库。

本插件挂载 DSH 的公开扩展点 `llm-pi-ai/request-headers`，按请求补上这些头。**它不改动适配器、不改动 DSH 安装目录、不替换任何内置行。**

## 它做什么

对 `config.providers` 里点名的 provider，在每次 llm-pi-ai 推理请求前：

| 条件 | 动作 |
| --- | --- |
| 有 sessionId | 设置 `x-deepseek-harness-session-id` 与 `x-session-id` |
| `purpose === 'compaction'` | 设置 `x-deepseek-harness-compact: 1` |
| 其它请求 | 只补会话头，不加压缩标记 |

## 与 TDAI 官方接入文档的差异

TDAI 的 `agents/dsh/README.md`[（v2.0.4）](https://github.com/TencentCloud/TencentDB-Agent-Memory/tree/v2.0.4/agents/dsh) 在 §1.6 里判断：桌面版只有「DeepSeek (deepseek-official)」
那张卡能接入记忆代理，因为 llm-pi-ai 适配器"只保留 attribution header，把所有 `x-deepseek-harness-*`
系列过滤掉"。装上本插件后，这个结论不再适用。

**头不是被过滤，而是 llm-pi-ai 本来就不发。** 两者差别很实际：前者意味着外部补不进去，
后者意味着可以补——`llm-pi-ai/request-headers` 就是它公开的扩展点。装好后代理侧能看到：

```text
[identity] sessionId=session-<uuid> custom=[x-deepseek-harness-session-id,x-session-id,x-stainless-arch,...]
[injection-debug] conversationId=session-<uuid> agentSource=dsh kind=main
                  dshHeadless=false sessionInitEnabled=true injectedSkipped=false
```

**文档列的三条后果会一并消失：**

| 官方文档 §1.6.2 的说法 | 装插件后 |
| --- | --- |
| `conversationId=null` | `conversationId=session-<uuid>` |
| `injectedSkipped=true`，session-init 表单永远弹不出来 | `injectedSkipped=false` 且 `dshHeadless=false`，表单可以弹 |
| 全程 passthrough，注入 / 归档 / mem 命令全部跳过 | `injectors=["skill","knowledge","tdai-memory"]` 全在跑，`tdai-recorder:write-l0` 正常写入 |

所以桌面版也可以走「自定义设置 / 添加模型提供商」那张卡，不必迁到 deepseek-official。

一点保留：

- 文档的判断在它的语境里成立——**不装插件时**，llm-pi-ai 确实不带这些头。本插件做的是把"不可用"变成"可用"，不是推翻那条判断的依据。

## 安装

先**完全退出** DSH（含托盘），各系统平台的安装命令如下：

Windows CMD：

```bat
curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.cmd -o install.cmd && install.cmd
```

Windows PowerShell：

```powershell
irm https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.ps1 | iex
```

macOS / Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.sh | bash
```

**这三条命令不会随版本变化。** 脚本自己去找最新的发布包，你不需要知道版本号，也不需要关心 `.tgz` 落在哪里。重复执行就是覆盖安装，升级也用它。



**脚本跑不通时**，可以手动安装（在`.tgz`安装包目录下执行）：

```sh
dsh plugin --profile desktop add ./dsh-llm-tdai.tgz
```

**安装完成后重新启动 DSH。**

## 卸载

所有系统平台的卸载命令如下：

```sh
dsh plugin --profile desktop remove dsh-llm-tdai
```

## plugin 配置

项目自带的 `cordis.patch.yml` 是**一层**，`dsh plugin add` 装好后由 loader 自动应用，
不需要往 profile 的 `cordis.patch.yml` 里抄。它只写了必要的一项，就是最小配置：

```yaml
- insert:
    - id: llm-tdai
      name: 'dsh-llm-tdai'
      config:
        providers:
          - tdai
```

全部可配项如下。**默认值不用照抄，省略即可**——写死默认值的坏处是插件以后调整默认值时，
你的配置会把旧值锁住。

```yaml
      config:
        providers: [tdai]     # 必须是数组；值须与 llm-pi-ai 的 config.providers 键一致
        sessionHeaders: true  # false 只关会话头；压缩头不受影响，照发
        compact: true         # false 只关压缩头；会话头不受影响，照发
        verbose: false        # true 时向 dsh 的 console 输出 debug 行（桌面端不落盘，见下文「回看」）
```

`providers` 是数组，取值必须与 profile 里 `llm-pi-ai` 的 `config.providers` 键逐字一致；
多个 provider 写成 `[tdai, my-gateway]`。写成单个字符串不会报错，但也不会被采用。

## profile 配置（推荐）

注意区分两份同名文件：上面那个 `cordis.patch.yml` 是**插件的**，由 `dsh plugin add` 自动应用；
下面这份是**你自己 profile**（`$DSH_HOME/profiles/<name>/cordis.patch.yml`）里的 provider 路由，两者不是同一个文件，也不要互相粘贴。

完整可复制版本见 [`examples/tdai-route.patch.yml`](./examples/tdai-route.patch.yml)。

DSH 的 llm-pi-ai 适配器会按 provider 名做协议探测。过往有一种做法是**把 provider 名故意起成 `openrouter`**，借 `isOpenRouter` 打开会话亲和头：

```ts
// @earendil-works/pi-ai  dist/api/openai-completions.js
const isOpenRouter = provider === "openrouter" || baseUrl.includes("openrouter.ai");
...
sendSessionAffinityHeaders: isOpenRouter,
sessionAffinityFormat: isOpenRouter ? "openrouter" : "openai",
```

这可以起作用，但名字是假的，而且会连带继承 OpenRouter 的供应商元数据。装了本插件之后就不需要这样了，provider 名可以改回真实的称呼。profile 的 `cordis.patch.yml` 里对应两处：

```yaml
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      tdai:
        displayName: DeepSeek TDAI
        api: openai-completions
        apiKeyEnv: PROXY_USER_KEY
        baseURL: http://127.0.0.1:8096/dsh/default
        reasoning: max

        # 路由级 compat：这个网关不支持什么。
        # llm-pi-ai 按 baseURL 猜出来的三个默认值在这里都不可用。
        compat:
          supportsDeveloperRole: false
          maxTokensField: max_tokens
          supportsStore: false

        models:
          - id: deepseek-flash
            name: DeepSeek-V4.1-Flash
            contextWindow: 1000000
            maxTokens: 393216
            input:
              - text
              - image

            # 模型级 compat：这个模型的协议细节。逐字段覆盖路由级。
            compat:
              thinkingFormat: deepseek
              requiresReasoningContentOnAssistantMessages: true

            # 手工声明的模型默认只认 "off"，必须显式列档位。
            # 只列官方真实支持的 low / high / max。
            # "off" 要加引号，否则 YAML 会解析成布尔 false；留空表示关闭思考。
            reasoningEfforts:
              "off":
              low: low
              high: high
              max: max

- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: tdai
    model: deepseek-flash
    reasoningEffort: max
```

`compat` 分两层不是风格问题：**路由级写「网关不支持什么」，模型级写「这个模型的协议细节」**。路由级的值是该路由上每个模型的默认值，模型自身的 `compat` 逐字段覆盖。

改名前后只影响两个 llm-pi-ai 检测值，其余都被 `compat` 里的显式声明覆盖：

| compat 字段 | 层级 | 叫 `openrouter` 时 | 叫 `tdai` 时 | 显式值 | 最终结果 |
| --- | --- | --- | --- | --- | --- |
| `supportsStore` | 路由 | true | true | false | 不变 |
| `supportsDeveloperRole` | 路由 | false | true | false | 不变 |
| `maxTokensField` | 路由 | `max_completion_tokens` | `max_completion_tokens` | `max_tokens` | 不变 |
| `requiresReasoningContentOnAssistantMessages` | 模型 | false | false | true | 不变 |
| `thinkingFormat` | 模型 | `openrouter` | `openai` | `deepseek` | 不变 |
| `sendSessionAffinityHeaders` | — | true | **false** | 不可设（withhold） | **由本插件补** |
| `sessionAffinityFormat` | — | `openrouter` | `openai` | 不可设 | 无影响 |

两点注意：

- 改 provider 名后，**旧会话**里记录的模型路由可能指向已经不存在的老名字，打开时需要重新选择一次模型。会话内容不会丢。
- **本插件必须在改名的同一轮里装好。只改名字不装插件，会失去会话身份**。

## 已验证环境

系统环境：

```text
Windows 11 + DSH 0.2.2-rc.3（桌面端）+ TDAI v2.0.4（镜像 1.0.4）
```

实测通过：会话 id 解析到真实 `session-<uuid>`、注入三项全开、`tdai-recorder:write-l0` 正常写入。

**代码本身不含系统平台相关逻辑（纯 ESM、零依赖，只用 `ctx.on` 与 `Headers`），但没有在
macOS / Linux 上验证过。`package.json` 的 `os` 字段列了 `win32 / linux / darwin`，那是允许安装的范围，不是验证结论。**

## 版本契约

本插件依赖两处 DSH 内部契约，已在 **DSH 0.2.2-rc.3**（桌面端 ProductVersion 0.2.2.0）的实际运行包 `app.asar` 内核对过：

```text
@deepseek-ai/dsh-llm-pi-ai/src/index.ts
  'llm-pi-ai/request-headers'(request: PiAiRequestHeaderContext,
                              headers: Headers,
                              next: () => Headers): Headers

@deepseek-ai/dsh-llm-pi-ai/src/types.ts
  PiAiRequestHeaderContext
    = Readonly<Pick<GenerateOptions<string>,
        'provider' | 'model' | 'sessionId' | 'purpose'>>
      & { readonly baseURL: string }
```

DSH 升级后请复核这两处。如果事件名或字段发生变化，本插件会**静默失效**：不报错、不影响启动，只是相关请求头不再发送了。

## 许可

MIT © 2026 dsh-llm-tdai contributors
