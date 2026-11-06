// The Kokoro voice engine (core/voice-server.mjs), shared by every platform: it proves itself,
// refuses browsers, and speaks. Needs the Kokoro model (≈90 MB, downloaded once), so it runs when
// JARVIS_TEST_TTS=1 (CI caches the model).
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { scratchHome } from './helpers.mjs'

const skip = process.env.JARVIS_TEST_TTS === '1' ? false : 'set JARVIS_TEST_TTS=1 (downloads the Kokoro model once)'
const home = scratchHome('jarvis-tts')
if (process.env.JARVIS_TTS_CACHE) process.env.JARVIS_CACHE_DIR = process.env.JARVIS_TTS_CACHE
const { ensureKey, freshNonce, proveIdentity, sameDigest } = await import('../bridge/voice-auth.mjs')
const PORT = 18890 + (process.pid % 100)
const base = `http://127.0.0.1:${PORT}`
let engine

test.before(async () => {
  if (skip) return
  ensureKey()
  engine = spawn(process.execPath, [fileURLToPath(new URL('../core/voice-server.mjs', import.meta.url))], { env: { ...process.env, JARVIS_VOICE_PORT: String(PORT) }, stdio: ['ignore', 'pipe', 'pipe'] })
  engine.stdout.on('data', (d) => process.stdout.write(`# ${d}`))
  engine.stderr.on('data', (d) => process.stdout.write(`# ${d}`))
  const t0 = Date.now()
  for (let i = 0; i < 1200; i++) {
    try {
      const h = await (await fetch(`${base}/health`)).json()
      if (h.ready) {
        console.log(`# Kokoro ready after ${Date.now() - t0} ms`)
        return
      }
    } catch {
      /* starting */
    }
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error('the voice engine did not become ready')
})
test.after(() => {
  engine?.kill()
  home.cleanup()
})

test('it proves it holds the per-install key', { skip }, async () => {
  const key = ensureKey()
  const nonce = freshNonce()
  const h = await (await fetch(`${base}/health?nonce=${nonce}`)).json()
  assert.ok(sameDigest(h.proof, proveIdentity(key, 'jarvis-voice-engine', nonce)))
})

test('it refuses browsers and requests without its header', { skip }, async () => {
  const body = JSON.stringify({ text: 'hello' })
  assert.notEqual((await fetch(`${base}/speak`, { method: 'POST', body, headers: { 'content-type': 'application/json', origin: 'http://evil.example', 'x-jarvis-voice': '1' } })).status, 200)
  assert.notEqual((await fetch(`${base}/speak`, { method: 'POST', body, headers: { 'content-type': 'application/json' } })).status, 200)
})

test('it speaks, with a proof on every answer (measured)', { skip }, async () => {
  const key = ensureKey()
  const { wavSeconds } = await import('../client/audio.mjs')
  const times = []
  for (const text of ['Very good.', 'Notepad is open.', "It's twenty past three.", 'I have three tasks running.', 'Done. I will not use the camera any more.', 'Task two, the weather: it is fourteen degrees and cloudy.']) {
    const nonce = freshNonce()
    const t0 = Date.now()
    const res = await fetch(`${base}/speak`, { method: 'POST', body: JSON.stringify({ text }), headers: { 'content-type': 'application/json', 'x-jarvis-voice': '1', 'x-jarvis-nonce': nonce } })
    const wav = Buffer.from(await res.arrayBuffer())
    times.push(Date.now() - t0)
    assert.equal(res.status, 200)
    assert.ok(sameDigest(res.headers.get('x-jarvis-proof'), proveIdentity(key, 'jarvis-voice-engine-speak', nonce)))
    assert.ok(wavSeconds(wav) > 0.3)
  }
  const s = [...times].sort((a, b) => a - b)
  console.log(`# Kokoro synthesis (ms): median ${s[Math.floor(s.length / 2)]}, p95 ${s.at(-1)} (n=${s.length})`)
})
