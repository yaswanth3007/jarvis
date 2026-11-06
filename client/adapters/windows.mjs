/**
 * Windows: apps, windows, keyboard, screen, sound — through Windows' own APIs, in a
 * long-lived PowerShell helper (windows-host.ps1) so each action costs milliseconds,
 * not a PowerShell start-up. Two helpers run: one for the desktop, one for sound, so
 * "stop" interrupts speech even while a window is being read.
 */
import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { findOnPath } from '../../core/platform.mjs'
import { matchApp, plain, run, waitFor } from './common.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(HERE, 'windows-host.ps1')

// JSON with everything outside ASCII escaped, so the line survives any console code page.
const asciiJson = (v) => JSON.stringify(v).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`)

export class PsHost {
  constructor(name, log = () => {}) {
    this.name = name
    this.log = log
    this.child = null
    this.pending = new Map()
    this.seq = 0
    this.ready = null
  }

  start() {
    if (this.ready) return this.ready
    this.ready = new Promise((resolve, reject) => {
      const ps = findOnPath('powershell') ?? 'powershell.exe'
      const child = spawn(ps, ['-NoProfile', '-NonInteractive', '-NoLogo', '-Command', '-'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
      this.child = child
      // Writing to a helper that is shutting down is not an error worth crashing over.
      child.stdin.on('error', () => {})
      let buffer = ''
      const timer = setTimeout(() => reject(new Error(`the Windows helper (${this.name}) did not start`)), 30_000)
      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk) => {
        buffer += chunk
        let nl
        while ((nl = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, nl).trim()
          buffer = buffer.slice(nl + 1)
          if (!line.startsWith('@@J ')) continue
          let msg
          try {
            msg = JSON.parse(line.slice(4))
          } catch {
            continue
          }
          if (msg.ready) {
            clearTimeout(timer)
            resolve(this)
            continue
          }
          const slot = this.pending.get(msg.id)
          if (!slot) continue
          this.pending.delete(msg.id)
          clearTimeout(slot.timer)
          if (msg.ok) slot.resolve(msg.result)
          else slot.reject(new Error(String(msg.error ?? 'failed')))
        }
      })
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (d) => this.log(`windows helper (${this.name}): ${String(d).trim().slice(0, 300)}`))
      child.on('error', (err) => {
        clearTimeout(timer)
        reject(err)
      })
      child.on('exit', (code) => {
        this.log(`windows helper (${this.name}) exited (${code})`)
        for (const slot of this.pending.values()) slot.reject(new Error('the Windows helper stopped'))
        this.pending.clear()
        this.ready = null
        this.child = null
      })
      // The script travels as data on standard input; nothing about PowerShell's policy changes.
      const b64 = Buffer.from(readFileSync(SCRIPT, 'utf8'), 'utf8').toString('base64')
      child.stdin.write(`iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}')))\n`)
    })
    return this.ready
  }

  async call(op, args = {}, timeoutMs = 30_000) {
    await this.start()
    const id = `r${++this.seq}`
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`Windows did not answer in time (${op})`))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer })
      this.child.stdin.write(`${asciiJson({ id, op, args })}\n`)
    })
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

/** The Start menu's apps (Get-StartApps), or the Start menu shortcuts where that is unavailable. */
async function listStartApps() {
  const ps = findOnPath('powershell') ?? 'powershell.exe'
  const command = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; " +
    "$a = @(); try { $a = @(Get-StartApps | ForEach-Object { [pscustomobject]@{ name = $_.Name; id = $_.AppID } }) } catch { }; " +
    "if ($a.Count -eq 0) { foreach ($d in @(\"$env:ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\", \"$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\")) { " +
    "if (Test-Path $d) { Get-ChildItem -Path $d -Recurse -Filter *.lnk | ForEach-Object { $a += [pscustomobject]@{ name = $_.BaseName; id = 'lnk:' + $_.FullName } } } } }; " +
    'ConvertTo-Json -InputObject @($a) -Compress -Depth 3'
  const r = await run(ps, ['-NoProfile', '-NonInteractive', '-Command', command], { timeout: 120_000 })
  if (r.code !== 0) throw new Error(`the Start menu could not be listed (${r.stderr.trim().slice(0, 200) || r.code})`)
  const list = JSON.parse(r.stdout.trim() || '[]')
  return Array.isArray(list) ? list : [list]
}

const BROWSERS = { chrome: 'chrome', 'google chrome': 'chrome', edge: 'msedge', 'microsoft edge': 'msedge', firefox: 'firefox', brave: 'brave', opera: 'opera' }
const EDITORS = { 'vs code': 'code', vscode: 'code', 'visual studio code': 'code', code: 'code', notepad: 'notepad.exe', 'notepad++': 'notepad++' }

export class WindowsAdapter {
  constructor({ log = () => {} } = {}) {
    this.os = 'windows'
    this.log = log
    this.ui = new PsHost('desktop', log)
    this.sound = new PsHost('sound', log)
    this.apps = null
    this.appsAt = 0
  }

  async start() {
    await Promise.all([this.ui.start(), this.sound.start()])
  }

  stop() {
    this.ui.stop()
    this.sound.stop()
  }

  /**
   * The Start menu's apps. Listing them can take seconds on a slow PC, so a known list is
   * answered at once and refreshed in the background when it is more than a minute old.
   */
  async installedApps(refresh = false) {
    // Listed by a separate, short-lived PowerShell so the desktop helper is never busy with it.
    const load = () => {
      this.appsLoading ??= listStartApps().then((list) => {
        this.apps = (Array.isArray(list) ? list : [list]).filter((a) => a?.name && a?.id)
        this.appsAt = Date.now()
        return this.apps
      }).finally(() => {
        this.appsLoading = null
      })
      return this.appsLoading
    }
    if (refresh || !this.apps) return load()
    if (Date.now() - this.appsAt > 60_000) void load().catch(() => {})
    return this.apps
  }

  async resolveApp(name) {
    return matchApp(await this.installedApps(), name)
  }

  async running() {
    const list = await this.ui.call('running')
    return (Array.isArray(list) ? list : list ? [list] : []).map((w) => ({ pid: w.pid, name: w.description || w.name, process: w.name, title: plain(w.title) }))
  }

  async frontmost() {
    const f = await this.ui.call('front')
    return f ? { name: f.description || f.name || 'an app', process: f.name, title: plain(f.title), pid: f.pid } : null
  }

  async find(name) {
    const w = await this.ui.call('find', { name })
    return w && typeof w === 'object' && w.pid != null ? w : null
  }

  async openApp(name) {
    const app = await this.resolveApp(name)
    const label = app?.name ?? name
    // Already open: bring it forward.
    const open = (await this.find(label).catch(() => null)) ?? (app ? null : await this.find(name).catch(() => null))
    if (open) {
      this.log(`open ${label}: already running (window “${plain(open.title, 60)}”, pid ${open.pid})`)
      try {
        const r = await this.ui.call('focus', { name: label })
        return { ok: true, message: `${label} is open${r?.focused ? '' : ', though Windows kept another window in front'}.`, name: label }
      } catch (err) {
        // The window went away between the two looks: open it as if it was not running.
        this.log(`open ${label}: ${err.message} — starting it`)
      }
    }
    if (!app) return { ok: false, message: `${name} isn't installed (it isn't in the Start menu).` }
    await this.ui.call('open', { id: app.id })
    // A first launch (Store apps especially) can take a while on a slow or busy PC.
    const appeared = await waitFor(() => this.find(label), 25_000, 400)
    return appeared
      ? { ok: true, message: `${label} is open.`, name: label }
      : { ok: true, message: `${label} was started; its window hasn't appeared yet.`, name: label }
  }

  async closeApp(name, { force = false } = {}) {
    const app = await this.resolveApp(name)
    const label = app?.name ?? name
    let r = await this.ui.call('close', { name: label, force }, 20_000)
    if (r?.state === 'not-running' && label !== name) r = await this.ui.call('close', { name, force }, 20_000)
    switch (r?.state) {
      case 'closed': return { ok: true, message: `${label} is closed.` }
      case 'ended': return { ok: true, message: `${label} was force quit.` }
      case 'still-open': return { ok: false, message: `I asked ${label} to close; it is still open — it may be asking about unsaved work.` }
      default: return { ok: false, message: `${label} isn't open.` }
    }
  }

  async readWindow(name) {
    const r = await this.ui.call('read', { name }, 45_000)
    return { title: plain(r?.title), text: String(r?.text ?? '').trim() }
  }

  async click(name, label, role) {
    return String(await this.ui.call('click', { name, label, role }, 30_000))
  }

  async typeText(name, text, { field, submit } = {}) {
    const r = await this.ui.call('type', { name, text, field, submit: Boolean(submit) }, 45_000)
    if (r?.verified === false) return 'typed, but the field does not show the text — it may not have gone in'
    return r?.via === 'value' ? 'typed (into the field directly: Windows kept another window in front)' : 'typed'
  }

  async pressKeys(name, keys) {
    return String(await this.ui.call('keys', { name, keys }, 20_000))
  }

  async screenshot({ app } = {}) {
    const r = await this.ui.call('shot', { name: app ?? null }, 30_000)
    return { image: r.image, mimeType: 'image/jpeg', width: r.width, height: r.height }
  }

  async openUrl(url, app) {
    const browser = app ? BROWSERS[app.toLowerCase()] ?? null : null
    if (app && !browser) {
      const resolved = await this.resolveApp(app)
      if (!resolved) return `${app} isn't installed.`
    }
    await this.ui.call('url', { url, browser })
    return 'opened'
  }

  async openPath(path, app) {
    const program = app ? EDITORS[app.toLowerCase()] ?? null : null
    await this.ui.call('path', { path, program })
    return 'opened'
  }

  async settings(pane) {
    return `opened ${await this.ui.call('settings', { pane })}`
  }

  async runInTerminal(command, cwd) {
    await this.ui.call('terminal', { command, cwd })
    return 'started in a terminal window'
  }

  // -- sound --
  async play(file) {
    await this.sound.call('play', { file }, 30_000)
  }
  async say(text) {
    await this.sound.call('say', { text }, 30_000)
  }
  async speakingSystemVoice() {
    return Boolean((await this.sound.call('speaking'))?.speaking)
  }
  async stopSound() {
    await this.sound.call('stop', {}, 5000).catch(() => {})
  }

  async camera() {
    const ffmpeg = findOnPath('ffmpeg')
    if (!ffmpeg) throw new Error('Windows has no built-in way for a background program to take a photo. Installing ffmpeg would make the camera available.')
    const list = await run(ffmpeg, ['-hide_banner', '-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'], { timeout: 10_000 })
    const device = /"([^"]+)"\s*\(video\)/.exec(list.stderr)?.[1]
    if (!device) throw new Error('No camera was found.')
    const shot = await run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-f', 'dshow', '-i', `video=${device}`, '-frames:v', '1', '-f', 'image2', '-vcodec', 'mjpeg', 'pipe:1'],
      { timeout: 20_000, encoding: null })
    if (shot.code !== 0 || !shot.stdout?.length) {
      throw new Error(/denied|access/i.test(shot.stderr) ? 'Windows blocked the camera: Settings → Privacy & security → Camera → "Let desktop apps access your camera".' : 'The camera did not give a picture.')
    }
    return { image: shot.stdout.toString('base64'), mimeType: 'image/jpeg' }
  }
}
