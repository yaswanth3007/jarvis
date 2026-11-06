// Linux sound, end to end: Jarvis's player sends a recording to the sound server, Jarvis's
// microphone (parec) hears it, and the listener wakes. Runs on Linux when JARVIS_E2E_AUDIO=1
// (CI provides a PulseAudio null sink whose monitor is the default input).
import test from 'node:test'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { modelStatus } from '../core/models.mjs'
import { paths } from '../core/paths.mjs'

const MODELS = process.env.JARVIS_TEST_MODELS ?? paths.models
const skip = process.platform === 'linux' && process.env.JARVIS_E2E_AUDIO === '1' && modelStatus(MODELS).all ? false : 'needs Linux, JARVIS_E2E_AUDIO=1 and the speech models'

test('play → sound server → microphone → wake word and request', { skip }, async () => {
  const { openMicrophone } = await import('../client/audio.mjs')
  const { Listener } = await import('../client/listener.mjs')
  const { LinuxAdapter } = await import('../client/adapters/linux.mjs')
  const listener = new Listener({ modelsDir: MODELS }).load()
  const mic = openMicrophone({ os: 'linux' })
  const heard = []
  let frames = 0
  mic.on('frame', (f) => {
    frames++
    listener.accept(f)
  })
  listener.on('utterance', (u) => heard.push({ ...u, at: Date.now() }))
  mic.start()
  await new Promise((r) => setTimeout(r, 800))
  const adapter = new LinuxAdapter()
  const played = await adapter.play(fileURLToPath(new URL('./fixtures/hey-jarvis-open-the-calculator.wav', import.meta.url)))
  const endedAt = Date.now()
  assert.ok(played, 'the player played the recording')
  for (let i = 0; i < 60 && !heard.some((u) => u.woke); i++) await new Promise((r) => setTimeout(r, 100))
  mic.stop()
  console.log(`# microphone: ${mic.description}, ${frames} frames; heard ${JSON.stringify(heard.map((u) => u.request))}`)
  const wake = heard.find((u) => u.woke)
  assert.ok(wake, 'the wake phrase was heard through the sound server')
  assert.match(wake.request, /open the calculator/i)
  console.log(`# end of speech → request ready: ${wake.at - endedAt} ms (includes ${listener.loadMs ? 0.55 * 1000 : 0} ms of silence detection)`)
})
