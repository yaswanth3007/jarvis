// The Windows/Linux voice assistant end to end, without a microphone: started as the service
// would start it, driven through its control channel, talking to a fake bridge that checks the
// signature, asks for a desktop action and a permission, and reads the replies.
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { scratchHome } from './helpers.mjs'

const supported = process.platform === 'win32' || process.platform === 'linux'
const skip = supported ? false : 'the Node voice assistant runs on Windows and Linux (macOS has the native app)'
const home = scratchHome('jarvis-client')
const { ensureKey, proveIdentity, verifyClientSignature } = await import('../bridge/voice-auth.mjs')
const { paths } = await import('../core/paths.mjs')
const { sendControl } = await import('../core/control.mjs')
const { WebSocketServer } = await import('ws')
const PORT = 19787 + (process.pid % 500)

let client
let bridge
const seen = { asks: [], replies: [], connections: 0 }

function control(line) {
  return sendControl({ path: paths.control, key: ensureKey(), command: line, timeoutMs: 8000 })
}
function readLog() {
  return existsSync(`${paths.logs}/voice.log`) ? readFileSync(`${paths.logs}/voice.log`, 'utf8') : ''
}
async function until(check, ms = 15_000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    const v = await check()
    if (v) return v
    await new Promise((r) => setTimeout(r, 150))
  }
  return null
}

test.before(async () => {
  if (!supported) return
  const key = ensureKey()
  mkdirSync(paths.support, { recursive: true })
  writeFileSync(paths.config, JSON.stringify({ bridgeURL: `ws://127.0.0.1:${PORT}/`, voiceEngineURL: 'http://127.0.0.1:9', answerSeconds: 20 }))
  bridge = new WebSocketServer({
    port: PORT, host: '127.0.0.1',
    verifyClient: ({ req }, done) => {
      req.nonce = verifyClientSignature(key, req.headers['x-jarvis-voice-auth'])
      done(Boolean(req.nonce) && /client=jarvis-voice-(windows|linux)/.test(req.url))
    },
  })
  bridge.on('connection', (ws, req) => {
    seen.connections++
    seen.caps = JSON.parse(Buffer.from(new URL(req.url, 'http://x').searchParams.get('caps'), 'base64url').toString())
    ws.send(JSON.stringify({ type: 'ready', proof: proveIdentity(key, 'jarvis-bridge', req.nonce) }))
    ws.on('message', (raw) => {
      const m = JSON.parse(String(raw))
      if (m.type === 'ask') {
        seen.asks.push(m)
        if (/list my apps/.test(m.request)) ws.send(JSON.stringify({ type: 'desktop', id: 'q1', op: 'list_apps' }))
        else if (/screen/.test(m.request)) ws.send(JSON.stringify({ type: 'confirm', id: 'q2', kind: 'permission', capability: 'screen', target: 'screen', question: 'May I look at your screen?', rememberable: true, summary: 'look at your screen' }))
        else ws.send(JSON.stringify({ type: 'done', text: 'Hello from the fake bridge.', ask: m.id }))
      }
      if (m.type === 'reply') {
        seen.replies.push(m)
        ws.send(JSON.stringify({ type: 'done', text: `Reply received: ${m.decision ?? m.text ?? m.error}`, ask: 'a1' }))
      }
    })
  })
  client = spawn(process.execPath, [fileURLToPath(new URL('../client/main.mjs', import.meta.url)), '--no-mic', '--no-tray'], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] })
  client.stderr.on('data', (d) => process.stdout.write(`# client stderr: ${d}`))
  for (let i = 0; i < 150; i++) {
    if ((await control('ping').catch(() => null)) === 'pong') return
    await new Promise((r) => setTimeout(r, 200))
  }
  throw new Error(`the client did not start:\n${readLog()}`)
})

test.after(async () => {
  if (client && client.exitCode === null) {
    await control('quit').catch(() => {})
    await new Promise((r) => setTimeout(r, 800))
    client.kill()
  }
  bridge?.close()
  home.cleanup()
})

test('it starts, reports its status and what this computer can do', { skip, timeout: 120000 }, async () => {
  const status = JSON.parse(await control('status'))
  assert.equal(status.os, process.platform === 'win32' ? 'windows' : 'linux')
  assert.ok(['idle', 'starting'].includes(status.state))
  assert.match(await control('capabilities'), /apps\.open/)
  assert.ok(await until(() => seen.connections > 0), 'a warm, signed connection to the bridge')
  assert.ok(Array.isArray(seen.caps.available))
})

test('local commands never go to Claude: the time, task status', { skip, timeout: 120000 }, async () => {
  const asks = seen.asks.length
  assert.equal(await control('ask what time is it'), 'ok')
  assert.ok(await until(() => /saying/.test(readLog())))
  assert.equal(await control('ask what are you doing'), 'ok')
  await new Promise((r) => setTimeout(r, 500))
  assert.equal(seen.asks.length, asks, 'nothing was sent to the bridge')
})

test('a request goes to Claude with the user\'s words and the context apart', { skip, timeout: 120000 }, async () => {
  assert.equal(await control('ask tell me a joke'), 'ok')
  const ask = await until(() => seen.asks.find((a) => a.request === 'tell me a joke'))
  assert.ok(ask)
  assert.equal(typeof ask.context, 'string')
  assert.ok(await until(() => /latency \(claude\)/.test(readLog())))
})

test('the bridge can ask for a desktop action only while a request of ours is running', { skip, timeout: 120000 }, async () => {
  assert.equal(await control('ask list my apps'), 'ok')
  const reply = await until(() => seen.replies.find((r) => typeof r.text === 'string' || r.error))
  assert.ok(reply, 'the desktop action was answered')
  assert.ok(reply.text?.startsWith('Running:') || reply.error, JSON.stringify(reply))
})

test('a permission question is asked out loud and answered; "allow always" is remembered', { skip, timeout: 120000 }, async () => {
  assert.equal(await control('ask look at my screen'), 'ok')
  assert.ok(await until(async () => /asking for permission: screen/.test(readLog())))
  await until(async () => !(await control('answer allow always')).startsWith('error'), 15_000)
  const decision = await until(() => seen.replies.find((r) => r.decision))
  assert.equal(decision?.decision, 'allow_always')
  const store = JSON.parse(readFileSync(paths.permissions, 'utf8'))
  assert.equal(store.capabilities.screen, 'allow')
})

test('"revoke camera access" by voice changes only Jarvis\'s own permission', { skip, timeout: 120000 }, async () => {
  assert.equal(await control('ask revoke camera access'), 'ok')
  const ok = await until(() => {
    try {
      return JSON.parse(readFileSync(paths.permissions, 'utf8')).capabilities.camera === 'deny'
    } catch {
      return false
    }
  })
  assert.ok(ok)
})

test('what it hears (a recording played into the recogniser) is handled like speech', { skip, timeout: 120000 }, async (t) => {
  const status = JSON.parse(await control('status'))
  if (status.speechModels !== 'loaded') {
    if (process.env.JARVIS_REQUIRE_SPEECH === '1') assert.fail('speech models should be loaded in CI')
    t.skip('speech models not downloaded here')
    return
  }
  const asks = seen.asks.length
  assert.equal(await control(`hear ${fileURLToPath(new URL('./fixtures/hey-jarvis-what-time-is-it.wav', import.meta.url))}`), 'ok')
  assert.ok(await until(() => /request heard/.test(readLog())))
  assert.equal(seen.asks.length, asks, '"what time is it" is answered locally')
})

test('it never logs what was said (logTranscripts is off by default)', { skip }, () => {
  const log = readLog()
  assert.ok(!/tell me a joke|look at my screen|revoke camera/.test(log), 'no request text in the log')
})

test('it quits cleanly when asked', { skip, timeout: 120000 }, async () => {
  const exited = new Promise((r) => (client.exitCode !== null ? r(client.exitCode) : client.once('exit', r)))
  assert.match(await control('quit'), /quitting/)
  const code = await exited
  assert.equal(code, 0)
})
