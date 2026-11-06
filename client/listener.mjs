/**
 * Hearing "Hey Jarvis" and what follows it, entirely on this computer.
 *
 * Two things listen to the same microphone samples:
 *   - the keyword spotter fires the instant "Hey Jarvis" is said — used to interrupt
 *     Jarvis while he is speaking;
 *   - voice activity detection cuts speech into utterances, and each one is transcribed.
 *     An utterance that starts with the wake phrase is a request ("Hey Jarvis, open
 *     Notepad"); during a conversation the next utterance is, without the wake phrase.
 *
 * Measured on the test recordings (tests/fixtures): the spotter alone missed one short
 * "Hey Jarvis."; together with the transcript check, every wake phrase was caught and no
 * other sentence woke it. Transcripts are kept in memory only and never logged unless
 * the user switches on "logTranscripts".
 */
import { EventEmitter } from 'node:events'
import { createRequire } from 'node:module'
import { existsSync, writeFileSync } from 'node:fs'
import { KEYWORDS, modelPaths, modelStatus } from '../core/models.mjs'
import { stripWake } from '../core/commands.mjs'
import { SAMPLE_RATE } from './audio.mjs'

const require = createRequire(import.meta.url)
const WINDOW = 512 // Silero VAD window at 16 kHz

export class Listener extends EventEmitter {
  constructor({ modelsDir, log = () => {}, threads = 1, padSeconds = 0.3 } = {}) {
    super()
    this.log = log
    this.modelsDir = modelsDir
    this.threads = threads
    // Voice activity detection marks an utterance from the moment speech is certain, which can
    // clip its first sound ("Hey" → "Pay"). The recogniser gets a little of what came just
    // before and after, kept in a short ring buffer (memory only).
    this.pad = Math.round(padSeconds * SAMPLE_RATE)
    this.ring = new Float32Array(SAMPLE_RATE * 24)
    this.fed = 0 // samples given to the VAD since its last reset (its own coordinates)
    this.pending = new Float32Array(0)
    this.samples = 0 // samples seen so far, for timing
    this.lastKeywordAt = -Infinity
    this.paused = false
  }

  load() {
    const status = modelStatus(this.modelsDir)
    if (!status.all) throw new Error('the speech models are not downloaded yet (run: jarvis setup)')
    const sherpa = require('sherpa-onnx-node')
    const p = modelPaths(this.modelsDir)
    if (!existsSync(p.kws.keywords)) writeFileSync(p.kws.keywords, KEYWORDS)
    const started = Date.now()
    this.kws = new sherpa.KeywordSpotter({
      featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
      modelConfig: { transducer: { encoder: p.kws.encoder, decoder: p.kws.decoder, joiner: p.kws.joiner }, tokens: p.kws.tokens, numThreads: 1, provider: 'cpu', debug: 0 },
      keywordsFile: p.kws.keywords,
    })
    this.kwsStream = this.kws.createStream()
    this.vad = new sherpa.Vad({
      sileroVad: { model: p.vad, threshold: 0.5, minSilenceDuration: 0.55, minSpeechDuration: 0.25, windowSize: WINDOW, maxSpeechDuration: 20 },
      sampleRate: SAMPLE_RATE, numThreads: 1, provider: 'cpu', debug: 0,
    }, 30)
    this.asr = new sherpa.OfflineRecognizer({
      featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
      modelConfig: { moonshine: { encoder: p.asr.encoder, mergedDecoder: p.asr.mergedDecoder }, tokens: p.asr.tokens, numThreads: Math.max(1, this.threads), provider: 'cpu', debug: 0 },
    })
    this.loadMs = Date.now() - started
    this.log(`speech models loaded in ${this.loadMs} ms (sherpa-onnx ${sherpa.version ?? ''})`)
    return this
  }

  /** Transcribes one utterance (16 kHz Float32). */
  transcribe(samples) {
    const stream = this.asr.createStream()
    stream.acceptWaveform({ samples, sampleRate: SAMPLE_RATE })
    this.asr.decode(stream)
    return String(this.asr.getResult(stream).text ?? '').trim()
  }

  /** Feeds microphone samples (16 kHz mono Float32Array). */
  accept(frame) {
    if (this.paused || !this.kws) return
    const t = this.samples / SAMPLE_RATE
    this.samples += frame.length
    // Keyword spotter: instant "Hey Jarvis".
    this.kwsStream.acceptWaveform({ samples: frame, sampleRate: SAMPLE_RATE })
    while (this.kws.isReady(this.kwsStream)) {
      this.kws.decode(this.kwsStream)
      const r = this.kws.getResult(this.kwsStream)
      if (r?.keyword) {
        this.kws.reset(this.kwsStream)
        this.lastKeywordAt = t
        this.emit('keyword', { label: r.keyword, at: t })
      }
    }
    // Voice activity → utterances.
    const merged = new Float32Array(this.pending.length + frame.length)
    merged.set(this.pending)
    merged.set(frame, this.pending.length)
    let off = 0
    for (; off + WINDOW <= merged.length; off += WINDOW) {
      const win = merged.subarray(off, off + WINDOW)
      this.remember(win)
      this.vad.acceptWaveform(win)
    }
    this.pending = merged.slice(off)
    const speaking = this.vad.isDetected()
    if (speaking !== this.speaking) {
      this.speaking = speaking
      this.emit(speaking ? 'speech-start' : 'speech-end')
    }
    while (!this.vad.isEmpty()) {
      const seg = this.vad.front(false)
      this.vad.pop()
      this.finishSegment(seg)
    }
  }

  remember(win) {
    const n = this.ring.length
    for (let i = 0; i < win.length; i++) this.ring[(this.fed + i) % n] = win[i]
    this.fed += win.length
  }

  /** The utterance with `pad` samples of what came before and after it, as far as the ring still holds. */
  padded(seg) {
    const n = this.ring.length
    const begin = Math.max(0, seg.start - this.pad, this.fed - n)
    const end = Math.min(this.fed, seg.start + seg.samples.length + this.pad)
    if (seg.start < begin || end <= begin) return seg.samples
    const out = new Float32Array(end - begin)
    for (let i = 0; i < out.length; i++) out[i] = this.ring[(begin + i) % n]
    return out
  }

  finishSegment(seg) {
    const start = seg.start / SAMPLE_RATE
    const seconds = seg.samples.length / SAMPLE_RATE
    const began = Date.now()
    let text = ''
    try {
      text = this.transcribe(this.pad ? this.padded(seg) : seg.samples)
    } catch (err) {
      this.log(`transcription failed: ${err.message}`)
      return
    }
    // The spotter heard "Hey Jarvis" inside this utterance (or just before it).
    const keyword = this.lastKeywordAt >= start - 0.5 && this.lastKeywordAt <= start + seconds + 0.3
    const { woke, request } = stripWake(text)
    this.emit('utterance', { text, request: woke ? request : keyword ? dropLeadingName(text) : text, woke: woke || keyword, keyword, seconds, asrMs: Date.now() - began })
  }

  /** Drops whatever was half-heard; used after Jarvis speaks so his own voice is not a request. */
  reset() {
    this.vad?.reset()
    this.fed = 0
    this.pending = new Float32Array(0)
    this.speaking = false
  }
}

/** When only the spotter heard the name, the transcript may hold a mangled version of it. */
function dropLeadingName(text) {
  return String(text).replace(/^\s*(?:(?:hey|hi|hay|ok|okay|a)[\s,.!]+)?[a-z']{3,9}[\s,.!?]+/i, (m) => (/\b(hey|hi|ok|okay)\b/i.test(m) ? '' : m)).trim()
}
