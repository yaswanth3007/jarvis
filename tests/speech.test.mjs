// The Windows/Linux listener on real audio: the wake phrase in five voices must wake it, other
// sentences must not, and what follows the wake phrase must be understood. Runs wherever
// sherpa-onnx has a build (every supported OS and architecture) once the models are present
// (JARVIS_TEST_MODELS, or the normal model folder). CI sets JARVIS_REQUIRE_SPEECH=1 so a
// missing model is a failure there, not a skip.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { modelStatus } from '../core/models.mjs'
import { paths } from '../core/paths.mjs'
import { sherpaAvailable } from '../core/platform.mjs'
import { parseTaskCommand } from '../core/commands.mjs'

const require = createRequire(import.meta.url)
const MODELS = process.env.JARVIS_TEST_MODELS ?? paths.models
const ready = sherpaAvailable() && modelStatus(MODELS).all
const skip = ready ? false : 'speech models or sherpa-onnx not available here'
if (!ready && process.env.JARVIS_REQUIRE_SPEECH === '1') throw new Error(`speech test required but ${skip} (models: ${MODELS})`)

const FIX = fileURLToPath(new URL('./fixtures/', import.meta.url))

/** Deterministic "room tone", the same on every machine. */
function withNoise(samples, amplitude = 0.004) {
  const out = new Float32Array(samples.length + 16000 * 1.5)
  out.set(samples, 8000)
  let seed = 12345
  for (let i = 0; i < out.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    out[i] += ((seed / 0x7fffffff) - 0.5) * 2 * amplitude
  }
  return out
}

async function hear(listener, file) {
  const sherpa = require('sherpa-onnx-node')
  const wave = sherpa.readWave(FIX + file)
  const audio = withNoise(wave.samples)
  const events = { utterances: [], keywords: [] }
  const onU = (u) => events.utterances.push(u)
  const onK = (k) => events.keywords.push(k)
  listener.on('utterance', onU)
  listener.on('keyword', onK)
  const t0 = process.hrtime.bigint()
  for (let i = 0; i < audio.length; i += 512) listener.accept(audio.subarray(i, i + 512))
  const ms = Number(process.hrtime.bigint() - t0) / 1e6
  listener.off('utterance', onU)
  listener.off('keyword', onK)
  listener.reset()
  return { ...events, ms, seconds: audio.length / 16000 }
}

test('wake phrase, requests and non-wake sentences', { skip }, async () => {
  const { Listener } = await import('../client/listener.mjs')
  const listener = new Listener({ modelsDir: MODELS }).load()
  const rtf = []
  const asr = []
  const files = readdirSync(FIX).filter((f) => f.endsWith('.wav')).sort()
  for (const f of files) {
    const r = await hear(listener, f)
    rtf.push(r.ms / 1000 / r.seconds)
    for (const u of r.utterances) asr.push(u.asrMs)
    const woke = r.keywords.length > 0 || r.utterances.some((u) => u.woke)
    const request = r.utterances.find((u) => u.woke)?.request ?? ''
    console.log(`# ${f}: woke=${woke} keyword=${r.keywords.length} request=${JSON.stringify(request)} (${r.ms.toFixed(0)} ms for ${r.seconds.toFixed(1)} s)`)
    if (f.startsWith('no-')) {
      assert.equal(woke, false, `${f} must not wake Jarvis`)
    } else {
      assert.equal(woke, true, `${f} must wake Jarvis`)
    }
    if (f === 'hey-jarvis-what-time-is-it.wav') assert.deepEqual(parseTaskCommand(request), { type: 'time' })
    if (f === 'hey-jarvis-stop-task-two.wav') assert.deepEqual(parseTaskCommand(request), { type: 'cancel', n: 2 })
    if (f === 'hey-jarvis-open-the-calculator.wav') assert.match(request, /open the calculator/i)
  }
  rtf.sort((a, b) => a - b)
  asr.sort((a, b) => a - b)
  console.log(`# listener real-time factor: median ${rtf[Math.floor(rtf.length / 2)].toFixed(3)}, worst ${rtf.at(-1).toFixed(3)} (n=${rtf.length}); transcription per utterance: median ${asr[Math.floor(asr.length / 2)]} ms, p95 ${asr[Math.min(asr.length - 1, Math.floor(asr.length * 0.95))]} ms; models loaded in ${listener.loadMs} ms`)
  assert.ok(rtf.at(-1) < 1, 'the listener keeps up with real time')
})
