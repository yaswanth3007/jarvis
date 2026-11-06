/**
 * The microphone, as 16 kHz mono samples, on Windows and Linux.
 *
 *   Windows  WASAPI through PvRecorder (Apache-2.0, prebuilt for x64 and ARM64)
 *   Linux    the session's own sound server: PulseAudio/PipeWire (parec, pw-record) or ALSA (arecord)
 *
 * Audio is only ever held in memory for the speech recogniser; nothing is recorded to disk.
 */
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { createRequire } from 'node:module'
import { findOnPath } from '../core/platform.mjs'

const require = createRequire(import.meta.url)
export const SAMPLE_RATE = 16000

const toFloat = (int16) => {
  const out = new Float32Array(int16.length)
  for (let i = 0; i < int16.length; i++) out[i] = int16[i] / 32768
  return out
}

class WindowsMicrophone extends EventEmitter {
  constructor({ device, log }) {
    super()
    const { PvRecorder } = require('@picovoice/pvrecorder-node')
    const devices = PvRecorder.getAvailableDevices()
    if (!devices.length) throw new Error('Windows reports no microphone')
    let index = -1
    if (device && device !== 'default') {
      index = devices.findIndex((d) => d.toLowerCase().includes(String(device).toLowerCase()))
      if (index < 0) log?.(`microphone "${device}" not found — using the default`)
    }
    this.recorder = new PvRecorder(512, index)
    this.description = this.recorder.getSelectedDevice()
    this.devices = devices
    this.running = false
  }
  start() {
    this.recorder.start()
    this.running = true
    void (async () => {
      while (this.running) {
        try {
          const frame = await this.recorder.read()
          this.emit('frame', toFloat(frame))
        } catch (err) {
          if (this.running) this.emit('error', err)
          break
        }
      }
    })()
    return this
  }
  stop() {
    this.running = false
    try {
      this.recorder.stop()
      this.recorder.release()
    } catch {
      /* already released */
    }
  }
}

class CommandMicrophone extends EventEmitter {
  constructor({ tool, device }) {
    super()
    this.tool = tool
    const dev = device && device !== 'default' ? device : null
    this.args = {
      parec: ['--rate=16000', '--channels=1', '--format=s16le', '--raw', '--latency-msec=50', ...(dev ? [`--device=${dev}`] : [])],
      'pw-record': ['--rate', '16000', '--channels', '1', '--format', 's16', ...(dev ? ['--target', dev] : []), '-'],
      arecord: ['-q', '-t', 'raw', '-f', 'S16_LE', '-r', '16000', '-c', '1', ...(dev ? ['-D', dev] : []), '-'],
    }[tool]
    this.description = `${tool}${dev ? ` (${dev})` : ' (default input)'}`
    this.child = null
    this.carry = Buffer.alloc(0)
  }
  start() {
    const child = spawn(this.tool, this.args, { stdio: ['ignore', 'pipe', 'pipe'] })
    this.child = child
    let errText = ''
    child.stderr.on('data', (d) => (errText = (errText + d).slice(-400)))
    child.stdout.on('data', (chunk) => {
      const buf = this.carry.length ? Buffer.concat([this.carry, chunk]) : chunk
      const usable = buf.length - (buf.length % 2)
      this.carry = buf.subarray(usable)
      if (!usable) return
      const samples = new Int16Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + usable))
      this.emit('frame', toFloat(samples))
    })
    child.on('error', (err) => this.emit('error', err))
    child.on('exit', (code, signal) => {
      if (this.child === child && !this.stopped) this.emit('error', new Error(`${this.tool} stopped (${signal ?? code})${errText ? `: ${errText.trim()}` : ''}`))
    })
    return this
  }
  stop() {
    this.stopped = true
    try {
      this.child?.kill()
    } catch {
      /* gone */
    }
  }
}

/** Opens the default (or named) microphone. */
export function openMicrophone({ os, device = 'default', log = () => {}, env = process.env } = {}) {
  if (os === 'windows') return new WindowsMicrophone({ device, log })
  const tool = ['parec', 'pw-record', 'arecord'].find((t) => findOnPath(t, env))
  if (!tool) throw new Error('no recorder found: install pulseaudio-utils (parec), pipewire (pw-record) or alsa-utils (arecord)')
  return new CommandMicrophone({ tool, device })
}

/** A short, quiet two-note chime (16-bit PCM WAV) for "I'm listening". */
export function chimeWav() {
  const rate = 22050
  const notes = [[880, 0.07], [1320, 0.09]]
  const total = notes.reduce((n, [, d]) => n + Math.round(d * rate), 0)
  const data = Buffer.alloc(total * 2)
  let o = 0
  for (const [f, d] of notes) {
    const n = Math.round(d * rate)
    for (let i = 0; i < n; i++) {
      const env = Math.min(1, i / 200, (n - i) / 400)
      data.writeInt16LE(Math.round(Math.sin((2 * Math.PI * f * i) / rate) * 0.18 * env * 32767), o)
      o += 2
    }
  }
  const h = Buffer.alloc(44)
  h.write('RIFF', 0)
  h.writeUInt32LE(36 + data.length, 4)
  h.write('WAVE', 8)
  h.write('fmt ', 12)
  h.writeUInt32LE(16, 16)
  h.writeUInt16LE(1, 20)
  h.writeUInt16LE(1, 22)
  h.writeUInt32LE(rate, 24)
  h.writeUInt32LE(rate * 2, 28)
  h.writeUInt16LE(2, 32)
  h.writeUInt16LE(16, 34)
  h.write('data', 36)
  h.writeUInt32LE(data.length, 40)
  return Buffer.concat([h, data])
}

/** Seconds of audio in a WAV file's bytes (PCM or float), or 0. */
export function wavSeconds(buf) {
  try {
    if (buf.toString('ascii', 0, 4) !== 'RIFF') return 0
    let off = 12
    let rate = 0
    let block = 0
    while (off + 8 <= buf.length) {
      const id = buf.toString('ascii', off, off + 4)
      const size = buf.readUInt32LE(off + 4)
      if (id === 'fmt ') {
        rate = buf.readUInt32LE(off + 12)
        block = buf.readUInt16LE(off + 20)
      } else if (id === 'data') {
        return rate && block ? Math.min(size, buf.length - off - 8) / (rate * block) : 0
      }
      off += 8 + size + (size % 2)
    }
  } catch {
    /* not a WAV */
  }
  return 0
}

/**
 * Any PCM or 32-bit float WAV (the Kokoro engine sends float) as 16-bit PCM, mono or
 * stereo as it came — the one format every player (SoundPlayer, aplay…) accepts.
 */
export function toPcm16Wav(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF') throw new Error('not a WAV file')
  let off = 12
  let fmt = null
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4)
    const size = buf.readUInt32LE(off + 4)
    if (id === 'fmt ') {
      fmt = { format: buf.readUInt16LE(off + 8), channels: buf.readUInt16LE(off + 10), rate: buf.readUInt32LE(off + 12), bits: buf.readUInt16LE(off + 22) }
    } else if (id === 'data' && fmt) {
      const data = buf.subarray(off + 8, Math.min(buf.length, off + 8 + size))
      if (fmt.format === 1 && fmt.bits === 16) return buf
      if (fmt.format !== 3 || fmt.bits !== 32) throw new Error(`unsupported WAV format ${fmt.format}/${fmt.bits}`)
      const n = Math.floor(data.length / 4)
      const pcm = Buffer.alloc(n * 2)
      for (let i = 0; i < n; i++) {
        const v = Math.max(-1, Math.min(1, data.readFloatLE(i * 4)))
        pcm.writeInt16LE(Math.round(v * 32767), i * 2)
      }
      const h = Buffer.alloc(44)
      h.write('RIFF', 0)
      h.writeUInt32LE(36 + pcm.length, 4)
      h.write('WAVE', 8)
      h.write('fmt ', 12)
      h.writeUInt32LE(16, 16)
      h.writeUInt16LE(1, 20)
      h.writeUInt16LE(fmt.channels, 22)
      h.writeUInt32LE(fmt.rate, 24)
      h.writeUInt32LE(fmt.rate * fmt.channels * 2, 28)
      h.writeUInt16LE(fmt.channels * 2, 32)
      h.writeUInt16LE(16, 34)
      h.write('data', 36)
      h.writeUInt32LE(pcm.length, 40)
      return Buffer.concat([h, pcm])
    }
    off += 8 + size + (size % 2)
  }
  throw new Error('WAV file without audio data')
}
