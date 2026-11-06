/**
 * Jarvis's voice on Windows and Linux: the project's own Kokoro voice engine (shared with
 * macOS, core/voice-server.mjs), played through the platform's player; the system voice
 * (Windows SAPI, espeak-ng / speech-dispatcher) if the engine is not available.
 *
 * Like the Mac app, it only speaks through an engine that proves it holds this user's
 * key (bridge/voice-auth.mjs): text is never sent to an impostor on the port.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { freshNonce, proveIdentity, sameDigest } from '../bridge/voice-auth.mjs'
import { toPcm16Wav, wavSeconds } from './audio.mjs'
import { sleep } from './adapters/common.mjs'

/** Markdown and links read badly aloud. */
export function forSpeech(text) {
  return String(text ?? '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/https?:\/\/\S+/g, 'a link')
    .replace(/^\s*(?:[-•]|\d+\.)\s+/gm, '')
    .replace(/[*_`#>|~]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Sentences, so the first one can play while the next is made. */
export function sentences(text) {
  const parts = forSpeech(text).match(/[^.!?]+[.!?]+["')\]]*|[^.!?]+$/g) ?? []
  const out = []
  for (const p of parts.map((s) => s.trim()).filter(Boolean)) {
    if (out.length && (out[out.length - 1].length < 40 || p.length < 12)) out[out.length - 1] += ` ${p}`
    else out.push(p)
  }
  return out
}

export class Speaker {
  constructor({ adapter, key, engineUrl = 'http://127.0.0.1:8790', voice, log = () => {} }) {
    this.adapter = adapter
    this.key = key
    this.engineUrl = engineUrl
    this.voice = voice
    this.log = log
    this.dir = mkdtempSync(join(tmpdir(), 'jarvis-voice-'))
    this.generation = 0
    this.busy = false
    this.engineOk = null
    this.engineCheckedAt = 0
    this.files = 0
  }

  get isBusy() {
    return this.busy
  }

  /** Does the engine on the port prove it is ours? Cached for a minute. */
  async engineReady() {
    if (this.engineOk !== null && Date.now() - this.engineCheckedAt < 60_000) return this.engineOk
    this.engineCheckedAt = Date.now()
    try {
      const nonce = freshNonce()
      const res = await fetch(`${this.engineUrl}/health?nonce=${nonce}`, { signal: AbortSignal.timeout(2000) })
      const body = await res.json()
      this.engineOk = Boolean(body?.ok && body?.ready && this.key && sameDigest(body.proof, proveIdentity(this.key, 'jarvis-voice-engine', nonce)))
      if (body?.ok && !this.engineOk && body?.ready) this.log('voice engine: something on the port cannot prove it is this user\'s — using the system voice')
    } catch {
      this.engineOk = false
    }
    return this.engineOk
  }

  async synthesize(text) {
    const nonce = freshNonce()
    const res = await fetch(`${this.engineUrl}/speak`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-jarvis-voice': '1', 'x-jarvis-nonce': nonce },
      body: JSON.stringify({ text, ...(this.voice ? { voice: this.voice } : {}) }),
      signal: AbortSignal.timeout(30_000),
    })
    if (!res.ok) throw new Error(`voice engine answered ${res.status}`)
    if (!sameDigest(res.headers.get('x-jarvis-proof'), proveIdentity(this.key, 'jarvis-voice-engine-speak', nonce))) {
      this.engineOk = false
      throw new Error('the voice engine could not prove it is this user\'s')
    }
    const wav = toPcm16Wav(Buffer.from(await res.arrayBuffer()))
    const file = join(this.dir, `say-${++this.files % 4}.wav`)
    writeFileSync(file, wav, { mode: 0o600 })
    return { file, seconds: wavSeconds(wav) }
  }

  /** Plays one prepared clip; resolves when it ends or is stopped. */
  async playClip(clip, generation) {
    if (generation !== this.generation) return
    if (this.adapter.os === 'windows') {
      await this.adapter.play(clip.file)
      const until = Date.now() + clip.seconds * 1000 + 120
      while (Date.now() < until && generation === this.generation) await sleep(50)
    } else {
      await this.adapter.play(clip.file)
    }
  }

  /** Speaks text; resolves when finished (or stopped). */
  async speak(text) {
    const parts = sentences(text)
    if (!parts.length) return
    const generation = ++this.generation
    this.busy = true
    try {
      if (await this.engineReady()) {
        let next = this.synthesize(parts[0])
        for (let i = 0; i < parts.length; i++) {
          if (generation !== this.generation) return
          let clip
          try {
            clip = await next
          } catch (err) {
            this.log(`voice engine failed (${err.message}) — using the system voice`)
            this.engineOk = false
            await this.systemVoice(parts.slice(i).join(' '), generation)
            return
          }
          next = i + 1 < parts.length ? this.synthesize(parts[i + 1]) : null
          next?.catch(() => {})
          await this.playClip(clip, generation)
        }
        return
      }
      await this.systemVoice(parts.join(' '), generation)
    } finally {
      if (generation === this.generation) this.busy = false
    }
  }

  async systemVoice(text, generation) {
    if (generation !== this.generation) return
    try {
      if (this.adapter.os === 'windows') {
        await this.adapter.say(text)
        await sleep(300)
        while (generation === this.generation && (await this.adapter.speakingSystemVoice())) await sleep(150)
      } else {
        await this.adapter.say(text)
      }
    } catch (err) {
      this.log(`no voice available: ${err.message}`)
    }
  }

  async playFile(file, seconds) {
    const generation = ++this.generation
    this.busy = true
    try {
      await this.playClip({ file, seconds }, generation)
    } finally {
      if (generation === this.generation) this.busy = false
    }
  }

  stop() {
    this.generation++
    this.busy = false
    void this.adapter.stopSound()
  }

  dispose() {
    this.stop()
    try {
      rmSync(this.dir, { recursive: true, force: true })
    } catch {
      /* temp files go with the session */
    }
  }

  writeTemp(name, data) {
    mkdirSync(this.dir, { recursive: true })
    const file = join(this.dir, name)
    writeFileSync(file, data, { mode: 0o600 })
    return file
  }
}
