// The per-install key: signatures, proofs, replay protection, and the control channel's
// mutual check (an impostor can neither drive Jarvis nor read what is sent to it).
import test from 'node:test'
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { scratchHome } from './helpers.mjs'

const home = scratchHome('jarvis-auth')
const { clientSignature, ensureKey, loadKey, proveIdentity, sameDigest, verifyClientSignature } = await import('../bridge/voice-auth.mjs')
const { sendControl, startControl } = await import('../core/control.mjs')
test.after(() => home.cleanup())

test('the key is created once, 32 random bytes, private to the user', async () => {
  const k = ensureKey()
  assert.equal(k.length, 32)
  assert.deepEqual(loadKey(), k)
  assert.deepEqual(ensureKey(), k, 'never replaced')
  if (process.platform !== 'win32') {
    const { statSync } = await import('node:fs')
    assert.equal(statSync(process.env.JARVIS_VOICE_KEY_FILE).mode & 0o777, 0o600)
  }
})

test('signatures: valid once, fresh only, and only with the right key', () => {
  const key = loadKey()
  const { header, nonce } = clientSignature(key)
  assert.equal(verifyClientSignature(key, header), nonce)
  assert.equal(verifyClientSignature(key, header), null, 'replay refused')
  assert.equal(verifyClientSignature(randomBytes(32), clientSignature(key).header), null, 'wrong key')
  assert.equal(verifyClientSignature(key, clientSignature(key, Date.now() - 10 * 60_000).header), null, 'stale')
  assert.equal(verifyClientSignature(key, 'v1.1.2.3'), null)
  const proof = proveIdentity(key, 'jarvis-bridge', nonce)
  assert.ok(sameDigest(proof, proveIdentity(key, 'jarvis-bridge', nonce)))
  assert.ok(!sameDigest(proof, proveIdentity(key, 'jarvis-voice-engine', nonce)), 'proofs are per service')
})

const pipe = (name) => (process.platform === 'win32' ? `\\\\.\\pipe\\jarvis-test-${name}-${process.pid}` : join(home.dir, `${name}.sock`))

test('control channel: both ends prove the key before anything is sent', async () => {
  const key = loadKey()
  const path = pipe('control')
  const seen = []
  const server = startControl({ path, key, handle: async (line) => { seen.push(line); return `got ${line}` } })
  await new Promise((r) => server.once('listening', r))
  assert.equal(await sendControl({ path, key, command: 'status' }), 'got status')
  await assert.rejects(sendControl({ path, key: randomBytes(32), command: 'ask secret' }), /unauthorized/)
  assert.deepEqual(seen, ['status'], 'the impostor client never got a command through')
  server.close()
})

test('control channel: a client never sends to something that cannot prove the key', async () => {
  const key = loadKey()
  const path = pipe('impostor')
  const net = await import('node:net')
  const got = []
  const impostor = net.createServer((s) => {
    s.on('data', (d) => got.push(String(d)))
    s.write(`ok ${'0'.repeat(64)}\n`)
  })
  await new Promise((r) => impostor.listen(path, r))
  await assert.rejects(sendControl({ path, key, command: 'ask my bank password is hunter2' }), /cannot prove/)
  await new Promise((r) => setTimeout(r, 100))
  assert.ok(!got.join('').includes('hunter2'), 'the typed text never reached the impostor')
  impostor.close()
})
