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

test('play → sound server → microphone → wake word and request', { skip, timeout: 120000 }, async () => {
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
  // Like someone speaking after a moment of quiet: 0.7 s of silence, then the recording.
  const { readFileSync, writeFileSync, mkdtempSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { join } = await import('node:path')
  const wav = readFileSync(fileURLToPath(new URL('./fixtures/hey-jarvis-open-the-calculator.wav', import.meta.url)))
  const silence = Buffer.alloc(16000 * 2 * 0.7)
  const data = Buffer.concat([silence, wav.subarray(44), silence])
  const header = Buffer.from(wav.subarray(0, 44))
  header.writeUInt32LE(36 + data.length, 4)
  header.writeUInt32LE(data.length, 40)
  const dir = mkdtempSync(join(tmpdir(), 'jarvis-audio-'))
  const file = join(dir, 'padded.wav')
  writeFileSync(file, Buffer.concat([header, data]))
  // Where the speech itself ends inside the recording (the voice's own tail is quiet).
  let last = 0
  for (let i = 44; i + 1 < wav.length; i += 2) if (Math.abs(wav.readInt16LE(i)) > 600) last = (i - 44) / 2
  const startedAt = Date.now()
  const played = await adapter.play(file)
  rmSync(dir, { recursive: true, force: true })
  const speechEndedAt = startedAt + 700 + (last / 16000) * 1000
  assert.ok(played, 'the player played the recording')
  for (let i = 0; i < 60 && !heard.some((u) => u.woke); i++) await new Promise((r) => setTimeout(r, 100))
  mic.stop()
  console.log(`# microphone: ${mic.description}, ${frames} frames; heard ${JSON.stringify(heard.map((u) => u.request))}`)
  const wake = heard.find((u) => u.woke)
  console.log(`# utterances: ${JSON.stringify(heard.map((u) => ({ text: u.text, woke: u.woke, keyword: u.keyword, seconds: u.seconds })))}`)
  assert.ok(wake, 'the wake phrase was heard through the sound server')
  assert.match(wake.request, /open the calculator/i)
  console.log(`# end of speech → request transcribed: ${wake.at - speechEndedAt} ms (of which 550 ms is the silence that ends an utterance; includes the sound server's latency)`)
})
