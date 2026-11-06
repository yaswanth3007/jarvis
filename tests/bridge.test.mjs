// A scratch bridge (its own key, its own port): Windows/Linux clients are accepted only with a
// valid signature, the bridge proves itself first, and impostors on either side are refused.
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { scratchHome } from './helpers.mjs'

const home = scratchHome('jarvis-bridge')
const { ensureKey, clientSignature, proveIdentity, sameDigest } = await import('../bridge/voice-auth.mjs')
const { BridgeConnection } = await import('../client/bridge-client.mjs')
const WebSocket = (await import('ws')).default
const key = ensureKey()
const PORT = 18787 + (process.pid % 500)
let bridge

test.before(async () => {
  bridge = spawn(process.execPath, ['--import', new URL('../core/loopback.mjs', import.meta.url).href, fileURLToPath(new URL('../bridge/server.mjs', import.meta.url))], {
    env: { ...process.env, JARVIS_BRIDGE_PORT: String(PORT), JARVIS_PERMISSIONS: '1', JARVIS_ALLOW_WRITES: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let out = ''
  bridge.stdout.on('data', (d) => (out += d))
  bridge.stderr.on('data', (d) => (out += d))
  for (let i = 0; i < 100 && !/bridge listening/.test(out); i++) await new Promise((r) => setTimeout(r, 100))
  assert.match(out, /bridge listening/, out.slice(-500))
})
test.after(() => {
  bridge?.kill()
  home.cleanup()
})

const url = `ws://127.0.0.1:${PORT}/`
const caps = { available: ['apps.open', 'apps.list', 'window.read'], missing: { 'apps.close': 'GNOME Wayland gives no way to close apps politely' } }

for (const os of ['linux', 'windows']) {
  test(`${os} client: signed, and the bridge proves itself in its first message`, async () => {
    const conn = new BridgeConnection({ url, key, os, caps })
    await conn.open(10_000)
    assert.ok(conn.authenticated)
    conn.close()
  })
}

const raw = (query, headers = {}, origin = 'http://localhost:5173') => new Promise((resolve) => {
  const ws = new WebSocket(`${url}${query}`, { origin, headers })
  ws.on('unexpected-response', (_req, res) => resolve({ status: res.statusCode }))
  ws.on('message', (m) => {
    resolve({ status: 101, first: JSON.parse(String(m)) })
    ws.close()
  })
  ws.on('error', () => resolve({ status: 'error' }))
})

test('claiming to be Jarvis Voice without a signature is refused', async () => {
  assert.equal((await raw('?client=jarvis-voice-linux')).status, 401)
  assert.equal((await raw('?client=jarvis-voice-windows', { 'x-jarvis-voice-auth': `v1.${Math.floor(Date.now() / 1000)}.${'a'.repeat(32)}.${'b'.repeat(64)}` })).status, 401)
})

test('a signature from another key is refused; an unknown client name is refused', async () => {
  const other = (await import('node:crypto')).randomBytes(32)
  assert.equal((await raw('?client=jarvis-voice-linux', { 'x-jarvis-voice-auth': clientSignature(other).header })).status, 401)
  assert.equal((await raw('?client=jarvis-voice-plan9', { 'x-jarvis-voice-auth': clientSignature(key).header })).status, 400)
})

test('a signature is good for one connection only', async () => {
  const { header, nonce } = clientSignature(key)
  const first = await raw('?client=jarvis-voice-linux', { 'x-jarvis-voice-auth': header })
  assert.equal(first.status, 101)
  assert.ok(sameDigest(first.first.proof, proveIdentity(key, 'jarvis-bridge', nonce)))
  assert.equal((await raw('?client=jarvis-voice-linux', { 'x-jarvis-voice-auth': header })).status, 401)
})

test('malformed capabilities never break the connection', async () => {
  const { header } = clientSignature(key)
  assert.equal((await raw('?client=jarvis-voice-linux&caps=%%%not-base64', { 'x-jarvis-voice-auth': header })).status, 101)
})

test('the web face keeps working exactly as before (no proof, no device tools)', async () => {
  const r = await raw('')
  assert.equal(r.status, 101)
  assert.equal(r.first.type, 'ready')
  assert.equal(r.first.proof, undefined)
  assert.equal((await raw('', {}, 'http://evil.example')).status, 403)
})

test('the client drops a bridge that cannot prove itself', async () => {
  const { WebSocketServer } = await import('ws')
  const fake = new WebSocketServer({ port: PORT + 1, host: '127.0.0.1' })
  fake.on('connection', (s) => s.send(JSON.stringify({ type: 'ready', proof: '0'.repeat(64) })))
  const conn = new BridgeConnection({ url: `ws://127.0.0.1:${PORT + 1}/`, key, os: 'linux', caps })
  await assert.rejects(conn.open(5000), /not this computer's bridge/)
  fake.close()
})
