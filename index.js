/**
 * dsh-llm-tdai - Host half.
 *
 * 给 pi-ai 通道补齐两类请求头，让上游的记忆代理（例如 TDAI MemoryProxy）
 * 能把一次会话的历次请求归到同一个会话，并把压缩请求识别为辅助调用：
 *
 *   x-deepseek-harness-session-id   dsh 自己的会话头，pi-ai 通道默认不发
 *   x-session-id                    OpenRouter 风格的会话亲和头，兼容只认它的读法
 *   x-deepseek-harness-compact: 1   仅 purpose === 'compaction' 的请求
 *
 * 为什么需要它：dsh 只在 llm-deepseek 适配器里发这些头（见
 * packages/llm/llm-deepseek/src/adapter.ts），pi-ai 适配器不发。于是走 pi-ai 的
 * provider 拿不到会话身份，压缩请求也会被下游当成主对话。dsh 为此留了公开扩展点，
 * 本插件只挂这一个事件，不改动任何其它行为。
 *
 * 契约来源（已在 dsh 0.2.2-rc.3 的运行包 app.asar 内核对，与 0.2.1-rc.5 逐字相同）：
 *   @deepseek-ai/dsh-llm-pi-ai/src/index.ts   llm-pi-ai/request-headers 事件（waterfall）
 *   @deepseek-ai/dsh-llm-pi-ai/src/types.ts   PiAiRequestHeaderContext 含
 *                                             provider / model / baseURL / sessionId / purpose
 * 升级 dsh 后请复核这两处；事件名或字段变化会让本插件静默失效（不会影响启动）。
 *
 * 零 import：本地 bundle 位于 app.asar 之外，只用运行时注入的 ctx 与公开事件。
 *
 * @module dsh-llm-tdai
 */

/** 插件逻辑名，需与 cordis.patch.yml 里的行 id 一致。 */
const name = 'llm-tdai'

/** 未配置时默认补头的 provider 名。 */
const DEFAULT_PROVIDERS = ['tdai']

/** 会话头。前者是 dsh 自己的命名，后者兼容 OpenRouter 风格读法。 */
const SESSION_HEADERS = ['x-deepseek-harness-session-id', 'x-session-id']

/** 压缩请求标记头，与 llm-deepseek 适配器同名同值。 */
const COMPACT_HEADER = 'x-deepseek-harness-compact'

/**
 * 归一化插件配置。字段全部做防御式取值：本地 bundle 不声明 schemastery Config，
 * 配置对象就是 patch 里写入的原始值，可能缺字段，也可能类型不对。
 *
 * @param config - patch 行里给出的 config 对象
 * @returns 内部使用的选项
 */
function readOptions(config) {
  const raw = config !== null && typeof config === 'object' ? config : {}
  const declared = Array.isArray(raw.providers)
    ? raw.providers.filter((item) => typeof item === 'string' && item.length > 0)
    : []
  return {
    providers: new Set(declared.length > 0 ? declared : DEFAULT_PROVIDERS),
    sessionHeaders: raw.sessionHeaders === false ? [] : SESSION_HEADERS,
    compact: raw.compact !== false,
    verbose: raw.verbose === true,
  }
}

/**
 * 挂载请求头贡献。
 *
 * @param ctx - 插件上下文，由 loader 注入
 * @param config - patch 行里的 config
 */
function apply(ctx, config) {
  const options = readOptions(config)
  let requests = 0
  let compactions = 0
  let missingSession = 0
  let shapeWarned = false

  ctx.on('llm-pi-ai/request-headers', (request, headers, next) => {
    // 只处理点名过的 provider，避免污染同一 profile 里的其它路由。
    if (!options.providers.has(request?.provider)) return next()

    // 事件形状变了就不要再往下做：抛错会让本次推理以 REQUEST_HEADERS 失败。
    if (typeof headers?.set !== 'function') {
      if (!shapeWarned) {
        shapeWarned = true
        ctx.logger?.warn?.(`[${name}] 事件形状不符合预期（headers 不是 Headers），本次跳过补头`)
      }
      return next()
    }

    requests += 1
    const sessionId = request.sessionId === undefined || request.sessionId === null
      ? ''
      : String(request.sessionId)

    if (sessionId.length > 0) {
      for (const header of options.sessionHeaders) headers.set(header, sessionId)
    } else if (missingSession === 0) {
      missingSession += 1
      ctx.logger?.warn?.(`[${name}] provider "${request.provider}" 的请求没有 sessionId，会话头未发送`)
    } else {
      missingSession += 1
    }

    if (options.compact && request.purpose === 'compaction') {
      headers.set(COMPACT_HEADER, '1')
      compactions += 1
      if (options.verbose) ctx.logger?.debug?.(`[${name}] compaction #${compactions} 已标记`)
    }

    return next()
  })

  ctx.logger?.info?.(
    `[${name}] 已挂载：providers=${[...options.providers].join(',')} `
    + `session=${options.sessionHeaders.join('+') || '(off)'} compact=${options.compact ? 'on' : 'off'}`,
  )
}

export { apply, name, readOptions };
