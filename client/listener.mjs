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
  constructor({ modelsDir, log = () => {}, threads = 1 } = {}) {
    super()
    this.log = log
    this.modelsDir = modelsDir
    this.threads = threads
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
    for (; off + WINDOW <= merged.length; off += WINDOW) this.vad.acceptWaveform(merged.subarray(off, off + WINDOW))
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

  finishSegment(seg) {
    const start = seg.start / SAMPLE_RATE
    const seconds = seg.samples.length / SAMPLE_RATE
    const began = Date.now()
    let text = ''
    try {
      text = this.transcribe(seg.samples)
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
    this.pending = new Float32Array(0)
    this.speaking = false
  }
}

/** When only the spotter heard the name, the transcript may hold a mangled version of it. */
function dropLeadingName(text) {
  return String(text).replace(/^\s*(?:(?:hey|hi|hay|ok|okay|a)[\s,.!]+)?[a-z']{3,9}[\s,.!?]+/i, (m) => (/\b(hey|hi|ok|okay)\b/i.test(m) ? '' : m)).trim()
}
