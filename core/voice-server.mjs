#!/usr/bin/env node
/**
 * JARVIS voice engine — the project's own Kokoro neural voice, served locally
 * for the native macOS voice assistant.
 *
 * The browser face already speaks with Kokoro (src/lib/kokoro.ts): the same
 * model id, the same q8 weights and the same British male voices are used
 * here. A background assistant has no browser, so this runs that model in Node
 * on the CPU through onnxruntime-node (already installed with kokoro-js).
 *
 * Nothing leaves the machine except the one-time model download from Hugging
 * Face, which is cached in Jarvis's cache folder (core/paths.mjs; on macOS
 * ~/Library/Caches/JarvisVoice/models).
 *
 * Local only: it binds 127.0.0.1, refuses any request a browser sends (an
 * Origin header), and requires a custom header that a web page cannot add
 * without a CORS preflight this server never approves. It never logs the text
 * it is asked to speak.
 *
 *   GET  /health  → {"ok":true,"ready":bool,...}
 *   POST /speak   {"text","voice"?,"speed"?} with header x-jarvis-voice: 1 → audio/wav
 */
import http from 'node:http'
import { mkdirSync } from 'node:fs'
import { env } from '@huggingface/transformers'
import { KokoroTTS } from 'kokoro-js'
import { loadKey, proveIdentity } from '../bridge/voice-auth.mjs'
import { paths } from './paths.mjs'

// Answering Jarvis Voice's nonce with this proves to it that this is the user's own
// voice engine, not something else holding the port (see bridge/voice-auth.mjs).
const KEY = loadKey()

const PORT = Number(process.env.JARVIS_VOICE_PORT ?? 8790)
const HOST = '127.0.0.1'
const MODEL = 'onnx-community/Kokoro-82M-v1.0-ONNX'
const DEFAULT_VOICE = process.env.JARVIS_KOKORO_VOICE ?? 'bm_george'
const CACHE = paths.models
const VOICE_ID = /^[a-z]{2}_[a-z]+$/

mkdirSync(CACHE, { recursive: true })
env.cacheDir = CACHE

const log = (...parts) => console.log(new Date().toISOString(), '[voice-engine]', ...parts)

let tts = null
let loading = null
let lastError = ''
let generated = 0

async function load() {
  if (tts) return tts
  if (loading) return loading
  loading = (async () => {
    const started = Date.now()
    const reported = new Map()
    try {
      const model = await KokoroTTS.from_pretrained(MODEL, {
        dtype: 'q8',
        device: 'cpu',
        progress_callback: (p) => {
          if (p?.status !== 'progress' || typeof p.progress !== 'number') return
          const step = Math.floor(p.progress / 25) * 25
          if (reported.get(p.file) !== step) {
            reported.set(p.file, step)
            log(`downloading ${p.file} ${step}%`)
          }
        },
      })
      // One throwaway line, so the first real reply doesn't pay for warm-up.
      await model.generate('Ready.', { voice: DEFAULT_VOICE })
      tts = model
      lastError = ''
      log(`Kokoro ready in ${((Date.now() - started) / 1000).toFixed(1)}s (voice ${DEFAULT_VOICE})`)
      return tts
    } catch (err) {
      lastError = String(err?.message ?? err)
      log('Kokoro failed to load:', lastError)
      // Try again in a minute: the usual cause is a network blip mid-download.
      setTimeout(() => void load(), 60_000).unref()
      return null
    } finally {
      loading = null
    }
  })()
  return loading
}

// One generation at a time: parallel ONNX runs only fight over the same cores.
let chain = Promise.resolve()
function synthesize(text, voice, speed) {
  const job = chain.then(async () => {
    const model = tts ?? (await load())
    if (!model) throw new Error(lastError || 'the voice model is not available')
    const audio = await model.generate(text, { voice, speed })
    generated++
    return Buffer.from(audio.toWav())
  })
  chain = job.catch(() => {})
  return job
}

const server = http.createServer(async (req, res) => {
  // A browser always sends Origin on these requests; nothing here is for pages.
  if (req.headers.origin) {
    res.writeHead(403)
    return res.end('forbidden')
  }

  if (req.method === 'GET' && (req.url === '/health' || req.url?.startsWith('/health?'))) {
    const nonce = new URL(req.url, 'http://x').searchParams.get('nonce')
    const proof = nonce ? proveIdentity(KEY, 'jarvis-voice-engine', nonce) : null
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(
      JSON.stringify({
        ok: true,
        engine: 'kokoro',
        ready: Boolean(tts),
        loading: Boolean(loading),
        error: lastError || null,
        voice: DEFAULT_VOICE,
        generated,
        ...(proof ? { proof } : {}),
      }),
    )
  }

  if (req.method === 'POST' && req.url === '/speak') {
    if (req.headers['x-jarvis-voice'] !== '1') {
      res.writeHead(403)
      return res.end('forbidden')
    }
    let body = ''
    for await (const chunk of req) {
      body += chunk
      if (body.length > 16 * 1024) {
        res.writeHead(413)
        return res.end('too large')
      }
    }
    let parsed
    try {
      parsed = JSON.parse(body || '{}')
    } catch {
      res.writeHead(400)
      return res.end('bad json')
    }
    const text = String(parsed.text ?? '').trim().slice(0, 2000)
    if (!text) {
      res.writeHead(400)
      return res.end('no text')
    }
    const voice = VOICE_ID.test(String(parsed.voice ?? '')) ? parsed.voice : DEFAULT_VOICE
    const speed = Number.isFinite(Number(parsed.speed))
      ? Math.min(Math.max(Number(parsed.speed), 0.5), 2)
      : 1
    try {
      const started = Date.now()
      const wav = await synthesize(text, voice, speed)
      // Timing only — never the text. Audio length: 32-bit float mono at 24 kHz.
      const audioSeconds = Math.max(0, (wav.length - 44) / 4 / 24000)
      log(`synthesized ${text.length} chars → ${audioSeconds.toFixed(2)}s audio in ${Date.now() - started}ms`)
      const proof = proveIdentity(KEY, 'jarvis-voice-engine-speak', req.headers['x-jarvis-nonce'])
      res.writeHead(200, {
        'content-type': 'audio/wav',
        'content-length': wav.length,
        'x-synthesis-ms': String(Date.now() - started),
        ...(proof ? { 'x-jarvis-proof': proof } : {}),
      })
      return res.end(wav)
    } catch (err) {
      res.writeHead(503)
      return res.end(String(err?.message ?? err))
    }
  }

  res.writeHead(404)
  res.end('not found')
})

server.on('error', (err) => {
  log(`cannot listen on ${HOST}:${PORT}: ${err.message}`)
  process.exit(1)
})
server.listen(PORT, HOST, () => log(`listening on http://${HOST}:${PORT}`))
void load()

for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => {
    log(`received ${signal}, stopping`)
    server.close()
    // Not process.exit(): that runs onnxruntime's C++ teardown, which aborts
    // ("mutex lock failed") and leaves a crash report at every logout. Ending
    // on the signal itself skips that teardown; there is nothing to flush.
    process.removeAllListeners(signal)
    process.kill(process.pid, signal)
  })
}
