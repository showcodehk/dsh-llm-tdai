import assert from 'node:assert/strict'
import test from 'node:test'

import { apply, readOptions } from '../index.js'

/** 最小 ctx：只实现本插件用到的事件注册与日志。 */
function createContext() {
  const logs = []
  const ctx = {
    handler: undefined,
    on(_event, handler) {
      ctx.handler = handler
    },
    logger: {
      info: (message) => logs.push(['info', message]),
      warn: (message) => logs.push(['warn', message]),
      debug: (message) => logs.push(['debug', message]),
    },
  }
  return { ctx, logs }
}

/** 派发一次请求，返回实际发出的头与 next 是否被调用。 */
function dispatch(ctx, request, headers = new Headers()) {
  let called = false
  const result = ctx.handler(request, headers, () => {
    called = true
    return headers
  })
  return { called, headers: Object.fromEntries(result.entries()) }
}

test('主对话补两个会话头', () => {
  const { ctx } = createContext()
  apply(ctx, { providers: ['tdai'] })
  const { called, headers } = dispatch(ctx, { provider: 'tdai', sessionId: 'session-abc' })
  assert.equal(called, true)
  assert.equal(headers['x-deepseek-harness-session-id'], 'session-abc')
  assert.equal(headers['x-session-id'], 'session-abc')
  assert.equal(headers['x-deepseek-harness-compact'], undefined)
})

test('压缩请求额外标记 compact 头', () => {
  const { ctx } = createContext()
  apply(ctx, { providers: ['tdai'] })
  const { headers } = dispatch(ctx, {
    provider: 'tdai',
    sessionId: 'session-abc',
    purpose: 'compaction',
  })
  assert.equal(headers['x-deepseek-harness-compact'], '1')
  assert.equal(headers['x-deepseek-harness-session-id'], 'session-abc')
})

test('未点名的 provider 一个头都不加', () => {
  const { ctx } = createContext()
  apply(ctx, { providers: ['tdai'] })
  const { called, headers } = dispatch(ctx, { provider: 'openrouter', sessionId: 'session-xyz' })
  assert.equal(called, true)
  assert.deepEqual(headers, {})
})

test('缺少 sessionId 时只告警一次，不发会话头', () => {
  const { ctx, logs } = createContext()
  apply(ctx, { providers: ['tdai'] })
  dispatch(ctx, { provider: 'tdai' })
  dispatch(ctx, { provider: 'tdai' })
  const warned = logs.filter(([level]) => level === 'warn')
  assert.equal(warned.length, 1)
})

test('compact 可以关掉，会话头保留', () => {
  const { ctx } = createContext()
  apply(ctx, { providers: ['tdai'], compact: false })
  const { headers } = dispatch(ctx, {
    provider: 'tdai',
    sessionId: 'session-abc',
    purpose: 'compaction',
  })
  assert.equal(headers['x-deepseek-harness-compact'], undefined)
  assert.equal(headers['x-session-id'], 'session-abc')
})

test('sessionHeaders 设为 false 时不发会话头', () => {
  const { ctx } = createContext()
  apply(ctx, { providers: ['tdai'], sessionHeaders: false })
  const { headers } = dispatch(ctx, {
    provider: 'tdai',
    sessionId: 'session-abc',
    purpose: 'compaction',
  })
  assert.deepEqual(headers, { 'x-deepseek-harness-compact': '1' })
})

test('headers 形状异常时安全跳过并继续链路', () => {
  const { ctx, logs } = createContext()
  apply(ctx, { providers: ['tdai'] })
  const bare = {}
  let called = false
  const result = ctx.handler({ provider: 'tdai', sessionId: 'x' }, bare, () => {
    called = true
    return bare
  })
  assert.equal(called, true)
  assert.equal(result, bare)
  assert.equal(logs.filter(([level]) => level === 'warn').length, 1)
})

test('配置缺省时回落到默认 provider 与默认头', () => {
  const options = readOptions(undefined)
  assert.deepEqual([...options.providers], ['tdai'])
  assert.deepEqual(options.sessionHeaders, ['x-deepseek-harness-session-id', 'x-session-id'])
  assert.equal(options.compact, true)
  assert.equal(options.verbose, false)
})
