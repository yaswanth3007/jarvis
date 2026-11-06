/**
 * The status icon: notification area on Windows (NotifyIcon), StatusNotifierItem on
 * Linux (AppIndicator). Optional — Jarvis works the same without it, and says so in
 * `jarvis doctor` when this desktop cannot show one.
 */
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { findOnPath } from '../core/platform.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))

export class Tray extends EventEmitter {
  constructor({ os, log = () => {} }) {
    super()
    this.os = os
    this.log = log
    this.child = null
    this.last = {}
  }

  start() {
    let child
    if (this.os === 'windows') {
      const ps = findOnPath('powershell') ?? 'powershell.exe'
      child = spawn(ps, ['-NoProfile', '-NonInteractive', '-NoLogo', '-STA', '-Command', '-'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
      const b64 = Buffer.from(readFileSync(join(HERE, 'tray/windows-tray.ps1'), 'utf8')).toString('base64')
      child.stdin.write(`iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}')))\n`)
    } else {
      if (!findOnPath('python3')) return false
      child = spawn('python3', ['-I', join(HERE, 'tray/linux-tray.py')], { stdio: ['pipe', 'pipe', 'pipe'] })
    }
    this.child = child
    child.stdin.on('error', () => {})
    child.stdout.setEncoding('utf8')
    let buf = ''
    child.stdout.on('data', (d) => {
      buf += d
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (line === 'ready') this.emit('ready')
        else if (line.startsWith('menu ')) this.emit('menu', line.slice(5))
      }
    })
    child.stderr.on('data', () => {})
    child.on('error', () => {})
    child.on('exit', (code) => {
      if (this.child === child) {
        this.child = null
        if (code) this.log(`status icon unavailable (exit ${code})`)
      }
    })
    return true
  }

  update(state) {
    const changed = Object.entries(state).some(([k, v]) => this.last[k] !== v)
    if (!changed || !this.child) return
    Object.assign(this.last, state)
    try {
      this.child.stdin.write(`${JSON.stringify(state)}\n`)
    } catch {
      /* the icon went away */
    }
  }

  stop() {
    try {
      this.child?.stdin.end()
      this.child?.kill()
    } catch {
      /* gone */
    }
  }
}
