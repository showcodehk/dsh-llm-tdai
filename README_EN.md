# dsh-llm-tdai

**English** | [中文](./README.md)

**dsh-llm-tdai** is a plugin (bundle) for DeepSeek Harness (DSH). It supplies the session and compaction request headers that DSH's **llm-pi-ai channel** leaves out, so an upstream memory proxy — [TencentDB Agent Memory (TDAI)](https://github.com/TencentCloud/TencentDB-Agent-Memory)'s MemoryProxy — can attribute every request of a conversation to the same session, and can recognise a context-compaction call as an auxiliary request.

## What it solves

DSH issues three kinds of request against a model route: the main conversation, context compaction, and session titling. The memory proxy tells them apart using two signals:

```text
x-deepseek-harness-session-id    session identity (session-<uuid>)
x-deepseek-harness-compact: 1    sent only on compaction requests
```

The problem is with those two headers: they are sent only by the `@deepseek-ai/dsh-llm-deepseek` adapter:

```ts
// packages/llm/llm-deepseek/src/adapter.ts
...requestIdentity.purpose === 'compaction' ? { 'x-deepseek-harness-compact': '1' } : {},
```

When the provider goes through the **llm-pi-ai adapter** (`api: openai-completions`, pointed at a self-hosted or third-party OpenAI-compatible endpoint), neither header is sent. Two things follow:

- the proxy gets no session identity, so one conversation is written to memory as several unrelated sessions;
- a compaction request looks like a main turn, so both the compaction instruction and its output end up in the memory store.

The plugin hooks DSH's public extension point `llm-pi-ai/request-headers` and adds those headers per request. **It does not modify the adapter, does not touch the DSH installation, and does not replace any built-in row.**

## What it does

For the providers named in `config.providers`, before every llm-pi-ai inference request:

| Condition | Action |
| --- | --- |
| a sessionId is present | set `x-deepseek-harness-session-id` and `x-session-id` |
| `purpose === 'compaction'` | set `x-deepseek-harness-compact: 1` |
| any other request | session headers only, no compaction marker |

## Differences from TDAI's DSH integration guide

TDAI's `agents/dsh/README.md` [(v2.0.4)](https://github.com/TencentCloud/TencentDB-Agent-Memory/tree/v2.0.4/agents/dsh) concludes in §1.6 that on the desktop build only the "DeepSeek (deepseek-official)" card can reach a memory proxy, on the grounds that the llm-pi-ai adapter "keeps only attribution headers and filters out every `x-deepseek-harness-*`". With this plugin installed, that conclusion no longer applies.

**The headers are not filtered — llm-pi-ai simply never sends them.** The distinction matters: "filtered" would mean nothing external can add them, while "never sent" means they can be supplied — `llm-pi-ai/request-headers` is the public extension point for exactly that. With the plugin in place, the proxy sees:

```text
[identity] sessionId=session-<uuid> custom=[x-deepseek-harness-session-id,x-session-id,x-stainless-arch,...]
[injection-debug] conversationId=session-<uuid> agentSource=dsh kind=main
                  dshHeadless=false sessionInitEnabled=true injectedSkipped=false
```

**The three consequences the guide lists all disappear:**

| Guide §1.6.2 says | With the plugin |
| --- | --- |
| `conversationId=null` | `conversationId=session-<uuid>` |
| `injectedSkipped=true`, the session-init form never appears | `injectedSkipped=false` and `dshHeadless=false`, the form can appear |
| full passthrough, injection / archiving / mem commands all skipped | `injectors=["skill","knowledge","tdai-memory"]` all running, `tdai-recorder:write-l0` writes normally |

So the desktop build can stay on the "custom settings / add a model provider" card instead of migrating to deepseek-official.

One caveat:

- The guide's judgement holds in its own context — **with no plugin installed**, llm-pi-ai really does not carry these headers. This plugin turns "unavailable" into "available"; it does not overturn the reasoning behind that statement.

## Install

**Fully quit** DSH first (including the tray). The command per platform:

Windows CMD:

```bat
curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.cmd -o install.cmd && install.cmd
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.ps1 | iex
```

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.sh | bash
```

**These three commands never change between versions.** The script finds the latest release itself — you do not need to know the version number or where the `.tgz` lands. Running it again is an overwrite install, which is also how you upgrade.

**If the script does not work**, install by hand (run it in the directory holding the `.tgz`):

```sh
dsh plugin --profile desktop add ./dsh-llm-tdai.tgz
```

**Restart DSH after installing.**

## Uninstall

The uninstall command, identical on every platform:

```sh
dsh plugin --profile desktop remove dsh-llm-tdai
```

## Plugin configuration

The `cordis.patch.yml` shipped with the project is **one layer**; `dsh plugin add` installs it and the loader applies it automatically. You do not copy it into your profile's `cordis.patch.yml`. It declares only what is necessary — the minimal configuration:

```yaml
- insert:
    - id: llm-tdai
      name: 'dsh-llm-tdai'
      config:
        providers:
          - tdai
```

All available options follow. **Do not copy the defaults** — writing them down pins the old values, so future changes to the plugin's defaults no longer reach you.

```yaml
      config:
        providers: [tdai]     # must be an array; must match the llm-pi-ai config.providers keys
        sessionHeaders: true  # false disables session headers only; compaction is unaffected
        compact: true         # false disables the compaction marker only; session headers still sent
        verbose: false        # true writes debug lines to the dsh console (not persisted on desktop)
```

`providers` is an array, and its values must match the `llm-pi-ai` `config.providers` keys character for character; multiple providers go as `[tdai, my-gateway]`. A single string is accepted without error but never used.

## Profile configuration (Recommended)

Note the two files share a name: the `cordis.patch.yml` above is **the plugin's**, applied automatically by `dsh plugin add`; the one below is the provider route inside **your own profile** (`$DSH_HOME/profiles/<name>/cordis.patch.yml`). They are different files — do not paste one into the other.

A ready-to-copy version lives in [`examples/tdai-route.patch.yml`](./examples/tdai-route.patch.yml).

The llm-pi-ai adapter probes configuration by provider name. A past workaround was to **name the provider `openrouter`** so that `isOpenRouter` turns on the session-affinity headers:

```ts
// @earendil-works/pi-ai  dist/api/openai-completions.js
const isOpenRouter = provider === "openrouter" || baseUrl.includes("openrouter.ai");
...
sendSessionAffinityHeaders: isOpenRouter,
sessionAffinityFormat: isOpenRouter ? "openrouter" : "openai",
```

That works, but the name is a lie and it drags in OpenRouter's vendor metadata. With this plugin installed it is unnecessary, and the provider can carry its real name again. Two places in the profile's `cordis.patch.yml`:

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

        # Route-level compat: what this gateway does not support. All three
        # defaults llm-pi-ai infers from the baseURL are wrong here.
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

            # Model-level compat: this model's protocol details. Overrides the
            # route-level values field by field.
            compat:
              thinkingFormat: deepseek
              requiresReasoningContentOnAssistantMessages: true

            # A hand-declared model offers only "off" by default, so the levels
            # have to be listed explicitly. Only the three DeepSeek really
            # supports: low / high / max.
            # "off" needs quoting, or YAML parses it as boolean false; leaving it
            # empty means thinking is off.
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

Splitting `compat` across two levels is not a style choice: **route level states what the gateway does not support, model level states this model's protocol details.** Route values are the default for every model on that route; a model's own `compat` overrides them field by field.

Renaming affects only two detected values; everything else is overridden by the explicit `compat` entries:

| compat field | level | as `openrouter` | as `tdai` | explicit value | net result |
| --- | --- | --- | --- | --- | --- |
| `supportsStore` | route | true | true | false | unchanged |
| `supportsDeveloperRole` | route | false | true | false | unchanged |
| `maxTokensField` | route | `max_completion_tokens` | `max_completion_tokens` | `max_tokens` | unchanged |
| `requiresReasoningContentOnAssistantMessages` | model | false | false | true | unchanged |
| `thinkingFormat` | model | `openrouter` | `openai` | `deepseek` | unchanged |
| `sendSessionAffinityHeaders` | — | true | **false** | not settable (withheld) | **supplied by this plugin** |
| `sessionAffinityFormat` | — | `openrouter` | `openai` | not settable | no effect |

Two things to know:

- After renaming the provider, **old sessions** may record a model route pointing at the name that no longer exists; you need to pick the model once when reopening. The conversation itself is not lost.
- **The plugin has to be installed in the same round as the rename. Renaming without it loses the session identity.**

## Verified environment

System:

```text
Windows 11 + DSH 0.2.2-rc.3 (desktop) + TDAI v2.0.4 (image 1.0.4)
```

Confirmed: the session id resolves to a real `session-<uuid>`, all three injectors run, and `tdai-recorder:write-l0` writes normally.

**The code carries no platform-specific logic (plain ESM, zero dependencies, only `ctx.on` and `Headers`), but it has not been verified on macOS or Linux. The `os` field in `package.json` lists `win32 / linux / darwin` — that is the range allowed to install, not a verification result.**

## Version contract

The plugin depends on two DSH internals, checked against the running package (`app.asar`) of **DSH 0.2.2-rc.3** (desktop ProductVersion 0.2.2.0):

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

Re-check these after upgrading DSH. If the event name or the fields change, the plugin **fails silently**: no error, no startup problem, the headers simply stop being sent.

## License

MIT © 2026 dsh-llm-tdai contributors
