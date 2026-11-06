/**
 * Linux: apps from the desktop's own .desktop entries, windows through AT-SPI (X11 and
 * Wayland), and — where the session allows it — X11 or wlroots tools for focusing,
 * closing and keys. Wayland deliberately stops one program from controlling another's
 * windows; where that applies Jarvis says so instead of trying to get around it.
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, statSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { findOnPath, linuxSession } from '../../core/platform.mjs'
import { launchDetached, matchApp, plain, run, runLauncher, sleep, waitFor } from './common.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ATSPI = join(HERE, 'linux-atspi.py')

/** Desktop Entry Exec parsing (freedesktop spec): quoting, escapes, field codes removed. */
export function parseExec(exec) {
  const args = []
  let cur = ''
  let quoted = false
  let has = false
  for (let i = 0; i < exec.length; i++) {
    const ch = exec[i]
    if (quoted) {
      if (ch === '\\' && i + 1 < exec.length && '"`$\\'.includes(exec[i + 1])) cur += exec[++i]
      else if (ch === '"') quoted = false
      else cur += ch
      continue
    }
    if (ch === '"') {
      quoted = true
      has = true
    } else if (ch === ' ' || ch === '\t') {
      if (has || cur) args.push(cur)
      cur = ''
      has = false
    } else {
      cur += ch
      has = true
    }
  }
  if (has || cur) args.push(cur)
  // %f %F %u %U %i %c %k and the deprecated codes: nothing to pass for "open the app".
  return args.filter((a) => !/^%[fFuUdDnNickvm]$/.test(a)).map((a) => a.replace(/%%/g, '%'))
}

export function parseDesktop(file, id) {
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return null
  }
  const entry = {}
  let inMain = false
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.startsWith('[')) {
      inMain = line === '[Desktop Entry]'
      continue
    }
    if (!inMain || !line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const k = line.slice(0, eq).trim()
    if (!(k in entry)) entry[k] = line.slice(eq + 1).trim()
  }
  if (entry.Type !== 'Application' || !entry.Name || !entry.Exec) return null
  if (/^true$/i.test(entry.NoDisplay ?? '') || /^true$/i.test(entry.Hidden ?? '')) return null
  const desktops = (process.env.XDG_CURRENT_DESKTOP ?? '').split(':').filter(Boolean)
  if (entry.OnlyShowIn && desktops.length && !entry.OnlyShowIn.split(';').some((d) => desktops.includes(d))) return null
  if (entry.NotShowIn && entry.NotShowIn.split(';').some((d) => desktops.includes(d))) return null
  const argv = parseExec(entry.Exec)
  if (!argv.length) return null
  // "python3 /opt/app/run.py", "env FOO=1 app": the program is the script / the real command.
  let first = 0
  if (basename(argv[0]) === 'env') first = argv.findIndex((x, i) => i > 0 && !x.includes('='))
  if (INTERPRETERS.test(basename(argv[first] ?? '')) && argv[first + 1] && !argv[first + 1].startsWith('-')) first += 1
  if (entry.TryExec && !(entry.TryExec.startsWith('/') ? existsSync(entry.TryExec) : findOnPath(entry.TryExec))) return null
  return { id, name: entry.Name, generic: entry.GenericName ?? '', file, argv, program: basename(argv[Math.max(0, first)] ?? argv[0]) }
}

const INTERPRETERS = /^(python[0-9.]*|node|nodejs|perl|ruby|bash|sh|dash|gjs|java|mono)$/

const KEYSYMS = { enter: 'Return', return: 'Return', escape: 'Escape', esc: 'Escape', tab: 'Tab', space: 'space', backspace: 'BackSpace',
  delete: 'Delete', del: 'Delete', up: 'Up', down: 'Down', left: 'Left', right: 'Right', home: 'Home', end: 'End',
  pageup: 'Prior', 'page up': 'Prior', pagedown: 'Next', 'page down': 'Next', insert: 'Insert' }
const MODS = { ctrl: 'ctrl', control: 'ctrl', cmd: 'ctrl', command: 'ctrl', shift: 'shift', alt: 'alt', option: 'alt', super: 'super', win: 'super', meta: 'super' }

/** "ctrl+shift+p" → xdotool's "ctrl+shift+p"; "enter" → "Return". */
export function xdotoolKeys(keys) {
  const parts = String(keys).toLowerCase().split(/\s*\+\s*/).filter(Boolean)
  const mods = []
  let key = null
  for (const p of parts) {
    if (MODS[p]) mods.push(MODS[p])
    else if (KEYSYMS[p]) key = KEYSYMS[p]
    else if (/^f([1-9]|1[0-2])$/.test(p)) key = p.toUpperCase()
    else if (p.length === 1) key = p
    else throw new Error(`I don't know the key '${p}'.`)
  }
  if (!key) throw new Error(`No key to press in '${keys}'.`)
  return [...mods, key].join('+')
}

export class LinuxAdapter {
  constructor({ log = () => {}, env = process.env } = {}) {
    this.os = 'linux'
    this.log = log
    this.env = env
    this.session = linuxSession(env)
    this.apps = null
    this.appsAt = 0
    this.player = null
    this.tool = (names) => names.find((n) => findOnPath(n, env))
  }

  async start() {}
  stop() {
    this.player?.kill()
  }

  appDirs() {
    const home = this.env.HOME ?? homedir()
    const dataHome = this.env.XDG_DATA_HOME || join(home, '.local/share')
    const dirs = (this.env.XDG_DATA_DIRS || '/usr/local/share:/usr/share').split(':')
    return [dataHome, ...dirs, '/var/lib/flatpak/exports/share', join(home, '.local/share/flatpak/exports/share')].map((d) => join(d, 'applications'))
  }

  async installedApps(refresh = false) {
    if (!refresh && this.apps && Date.now() - this.appsAt < 60_000) return this.apps
    const seen = new Map()
    for (const dir of this.appDirs()) {
      const walk = (d, prefix) => {
        let entries = []
        try {
          entries = readdirSync(d, { withFileTypes: true })
        } catch {
          return
        }
        for (const e of entries) {
          if (e.isDirectory()) walk(join(d, e.name), `${prefix}${e.name}-`)
          else if (e.name.endsWith('.desktop')) {
            const id = `${prefix}${e.name}`
            if (seen.has(id)) continue // earlier directories take precedence (spec)
            const app = parseDesktop(join(d, e.name), id)
            seen.set(id, app)
          }
        }
      }
      walk(dir, '')
    }
    this.apps = [...seen.values()].filter(Boolean)
    this.appsAt = Date.now()
    return this.apps
  }

  async resolveApp(name) {
    const apps = await this.installedApps()
    return matchApp(apps, name) ?? matchApp(apps.map((a) => ({ ...a, name: a.generic || a.name })), name)
  }

  /** Processes of this user, with the program each one runs. */
  processes() {
    const uid = process.getuid?.()
    const list = []
    for (const pid of readdirSync('/proc').filter((d) => /^\d+$/.test(d))) {
      try {
        if (uid !== undefined && statSync(`/proc/${pid}`).uid !== uid) continue
        const cmd = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean)
        if (!cmd.length) continue
        let exe = ''
        try {
          exe = readlinkSync(`/proc/${pid}/exe`)
        } catch {
          /* kernel thread or gone */
        }
        const program = basename(cmd[0])
        // Scripts run by an interpreter are known by the script's name ("python3 /usr/bin/foo" is foo).
        const script = INTERPRETERS.test(program) && cmd[1] && !cmd[1].startsWith('-') ? basename(cmd[1]) : null
        list.push({ pid: Number(pid), argv: cmd, program: script ?? program, exe: basename(exe) })
      } catch {
        /* gone */
      }
    }
    return list
  }

  /** X11 windows: id, pid, class and title (wmctrl -lpx). */
  async x11Windows() {
    if (!this.session.x11 || !findOnPath('wmctrl', this.env)) return null
    const r = await run('wmctrl', ['-lpx'], { timeout: 5000 })
    if (r.code !== 0) return null
    return r.stdout.split('\n').filter(Boolean).map((line) => {
      const m = /^(\S+)\s+(-?\d+)\s+(\d+)\s+(\S+)\s+\S+\s+(.*)$/.exec(line)
      return m ? { wid: m[1], pid: Number(m[3]), wmClass: m[4], title: plain(m[5]) } : null
    }).filter(Boolean)
  }

  pidsFor(app) {
    const progs = new Set([app.program, basename(app.argv?.[0] ?? '')].filter(Boolean))
    return this.processes().filter((p) => progs.has(p.program) || progs.has(p.exe)).map((p) => p.pid)
  }

  async running() {
    const apps = await this.installedApps()
    const procs = this.processes()
    const windows = (await this.x11Windows()) ?? []
    const out = []
    for (const app of apps) {
      const pids = procs.filter((p) => p.program === app.program || p.exe === app.program).map((p) => p.pid)
      if (!pids.length) continue
      const win = windows.find((w) => pids.includes(w.pid))
      out.push({ name: app.name, pid: pids[0], title: win?.title ?? '' })
    }
    return out
  }

  async frontmost() {
    if (this.session.x11 && findOnPath('xdotool', this.env)) {
      const r = await run('xdotool', ['getactivewindow', 'getwindowpid', 'getwindowname'], { timeout: 3000 })
      if (r.code === 0) {
        const [pid, ...title] = r.stdout.trim().split('\n')
        const proc = this.processes().find((p) => p.pid === Number(pid))
        const apps = await this.installedApps()
        const app = proc && apps.find((a) => a.program === proc.program || a.program === proc.exe)
        return { name: app?.name ?? proc?.program ?? 'an app', title: plain(title.join(' ')), pid: Number(pid) }
      }
    }
    return null // Wayland does not tell other programs which window is in front.
  }

  async focus(app) {
    const windows = await this.x11Windows()
    if (windows) {
      const pids = this.pidsFor(app)
      const win = windows.find((w) => pids.includes(w.pid))
      if (win) {
        await run('wmctrl', ['-ia', win.wid], { timeout: 3000 })
        return true
      }
    } else if (this.session.wlroots && findOnPath('swaymsg', this.env)) {
      const pid = this.pidsFor(app)[0]
      if (pid) return (await run('swaymsg', [`[pid=${pid}]`, 'focus'], { timeout: 3000 })).code === 0
    }
    return false
  }

  async openApp(name) {
    const app = await this.resolveApp(name)
    if (!app) return { ok: false, message: `${name} isn't installed (no desktop entry for it).` }
    if (this.pidsFor(app).length) {
      const focused = await this.focus(app)
      return { ok: true, message: `${app.name} is open${focused || !this.session.x11 ? '' : ', though it could not be brought to the front'}.`, name: app.name }
    }
    // The desktop's own launcher, given the entry's full path (no lookup that could pick another
    // entry or miss this one), then gtk-launch, then the entry's Exec line directly.
    const cwd = this.env.HOME ?? homedir()
    let started = false
    let why = 'no launcher worked'
    if (findOnPath('gio', this.env)) {
      const code = await runLauncher('gio', ['launch', app.file], { env: this.env, cwd })
      started = code === 0
      if (!started) why = `gio exited ${code}`
    }
    if (!started && findOnPath('gtk-launch', this.env)) {
      const code = await runLauncher('gtk-launch', [app.id.replace(/\.desktop$/, '')], { env: this.env, cwd })
      started = code === 0
      if (!started) why = `gtk-launch exited ${code}`
    }
    if (!started) {
      const r = await launchDetached(app.argv[0], app.argv.slice(1), { cwd, env: this.env })
      started = r.ok
      if (!started) why = r.error?.message ?? why
    }
    if (!started) return { ok: false, message: `${app.name} could not be started (${why}).` }
    const up = await waitFor(() => this.pidsFor(app).length > 0, 15_000, 400)
    return { ok: true, message: up ? `${app.name} is open.` : `${app.name} was started; it hasn't appeared yet.`, name: app.name }
  }

  async closeApp(name, { force = false } = {}) {
    const app = await this.resolveApp(name)
    const label = app?.name ?? name
    const pids = app ? this.pidsFor(app) : []
    if (!pids.length) return { ok: false, message: `${label} isn't open.` }
    if (force) {
      for (const pid of pids) {
        try {
          process.kill(pid, 'SIGTERM')
        } catch {
          /* gone */
        }
      }
      const gone = await waitFor(() => this.pidsFor(app).length === 0, 5000)
      return gone ? { ok: true, message: `${label} was force quit.` } : { ok: false, message: `${label} did not quit.` }
    }
    const windows = await this.x11Windows()
    if (windows) {
      const mine = windows.filter((w) => pids.includes(w.pid))
      for (const w of mine) await run('wmctrl', ['-ic', w.wid], { timeout: 3000 })
    } else if (this.session.wlroots && findOnPath('swaymsg', this.env)) {
      for (const pid of pids) await run('swaymsg', [`[pid=${pid}]`, 'kill'], { timeout: 3000 })
    } else {
      return { ok: false, message: `This ${this.session.desktop || 'Wayland'} session gives other programs no way to ask ${label} to close. Close it yourself, or say "force quit ${label}".` }
    }
    const gone = await waitFor(() => this.pidsFor(app).length === 0, 6000)
    return gone ? { ok: true, message: `${label} is closed.` } : { ok: false, message: `I asked ${label} to close; it is still open — it may be asking about unsaved work.` }
  }

  async atspi(args, timeout = 30_000) {
    if (!findOnPath('python3', this.env)) throw new Error('AT-SPI needs python3 with python3-gi (gir1.2-atspi-2.0).')
    const r = await run('python3', ['-I', ATSPI, ...args], { timeout })
    let v = null
    try {
      v = JSON.parse(r.stdout || '{}')
    } catch {
      /* fall through */
    }
    if (!v) throw new Error(r.stderr.includes('Atspi') ? 'AT-SPI is not available: install python3-gi and gir1.2-atspi-2.0.' : 'The accessibility helper failed.')
    if (v.error) {
      const e = new Error(v.error)
      e.fallback = Boolean(v.fallback)
      throw e
    }
    return v
  }

  async readWindow(name) {
    const app = await this.resolveApp(name)
    const r = await this.atspi(['read', app?.name ?? name], 45_000).catch(async (err) => {
      if (app && app.name !== name) return this.atspi(['read', name], 45_000)
      throw err
    })
    return { title: plain(r.title), text: String(r.text ?? '').trim() }
  }

  async click(name, label, role) {
    const app = await this.resolveApp(name)
    return (await this.atspi(['click', app?.name ?? name, label, role ?? ''])).result
  }

  async typeText(name, text, { field, submit } = {}) {
    const app = await this.resolveApp(name)
    try {
      const r = await this.atspi(['type', app?.name ?? name, text, field ?? '', submit ? '1' : '0'])
      if (submit && !r.submitted) await this.pressKeys(name, 'enter')
      return r.verified === false ? 'typed, but the field does not show the text — it may not have gone in' : 'typed'
    } catch (err) {
      if (!err.fallback && !/accessibility|AT-SPI/.test(err.message)) throw err
      // No editable text through AT-SPI: type with the keyboard where the session allows it.
      const keyboard = this.keyboardTool()
      if (!keyboard) throw new Error(`${err.message} Typing with the keyboard isn't possible in this session either.`)
      if (app && !(await this.focus(app))) throw new Error(`${app.name} could not be brought to the front, so nothing was typed.`)
      await sleep(150)
      if (keyboard === 'xdotool') await run('xdotool', ['type', '--clearmodifiers', '--delay', '8', '--', text], { timeout: 30_000 })
      else await run('wtype', ['--', text], { timeout: 30_000 })
      if (submit) await this.pressKeys(name, 'enter')
      return 'typed'
    }
  }

  keyboardTool() {
    if (this.session.x11 && findOnPath('xdotool', this.env)) return 'xdotool'
    if (this.session.wlroots && findOnPath('wtype', this.env)) return 'wtype'
    return null
  }

  async pressKeys(name, keys) {
    const keyboard = this.keyboardTool()
    if (!keyboard) throw new Error(`Pressing keys in other apps isn't possible in this ${this.session.type} session${this.session.x11 ? ' without xdotool' : ''}.`)
    const app = name ? await this.resolveApp(name) : null
    if (app && !(await this.focus(app))) throw new Error(`${app.name} could not be brought to the front, so no keys were pressed.`)
    await sleep(120)
    const combo = xdotoolKeys(keys)
    if (keyboard === 'xdotool') {
      const r = await run('xdotool', ['key', '--clearmodifiers', combo], { timeout: 5000 })
      if (r.code !== 0) throw new Error('The keys could not be pressed.')
    } else {
      const parts = combo.split('+')
      const key = parts.pop()
      const args = []
      for (const m of parts) args.push('-M', m)
      args.push(key.length === 1 ? key : '-k', ...(key.length === 1 ? [] : [key]))
      for (const m of parts.reverse()) args.push('-m', m)
      await run('wtype', args, { timeout: 5000 })
    }
    return 'pressed'
  }

  async screenshot({ app } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'jarvis-shot-'))
    const file = join(dir, 'shot.jpg')
    const png = join(dir, 'shot.png')
    try {
      const s = this.session
      let ok = false
      let out = file
      const tryRun = async (cmd, args, target = file) => {
        if (ok || !findOnPath(cmd, this.env)) return
        const r = await run(cmd, args, { timeout: 20_000 })
        if (r.code === 0 && existsSync(target)) {
          ok = true
          out = target
        }
      }
      if (s.wayland && s.wlroots) await tryRun('grim', ['-t', 'jpeg', '-q', '80', file])
      if (!s.x11 || !app) await tryRun('gnome-screenshot', ['-f', png], png)
      await tryRun('spectacle', ['-b', '-n', '-o', file])
      if (s.x11) {
        await tryRun('scrot', ['-o', file])
        await tryRun('maim', ['-f', 'jpg', file])
        await tryRun('import', ['-window', 'root', file])
      }
      if (!ok) throw new Error(s.wayland ? 'This Wayland session did not allow a screenshot: install gnome-screenshot (GNOME), spectacle (KDE) or grim (wlroots).' : 'No screenshot tool worked: install scrot, maim or ImageMagick.')
      const data = readFileSync(out)
      if (data.length > 4.5 * 1024 * 1024) throw new Error('The screenshot is too large to look at.')
      return { image: data.toString('base64'), mimeType: out.endsWith('.png') ? 'image/png' : 'image/jpeg' }
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }

  async openWith(app, target) {
    if (app) {
      const resolved = await this.resolveApp(app)
      if (!resolved) return `${app} isn't installed.`
      const r = await launchDetached(resolved.argv[0], [...resolved.argv.slice(1), target])
      return r.ok ? 'opened' : `could not start ${resolved.name}`
    }
    if (!findOnPath('xdg-open', this.env)) throw new Error('xdg-open is not installed (package xdg-utils).')
    const r = await launchDetached('xdg-open', [target])
    return r.ok ? 'opened' : 'could not open it'
  }

  openUrl(url, app) {
    return this.openWith(app, url)
  }

  openPath(path, app) {
    return this.openWith(app, path)
  }

  async settings(pane) {
    const p = String(pane ?? '').toLowerCase().replace(/[^a-z]+/g, '-')
    if (findOnPath('gnome-control-center', this.env)) {
      const panels = { privacy: 'privacy', microphone: 'privacy', camera: 'privacy', sound: 'sound', bluetooth: 'bluetooth', wifi: 'wifi',
        network: 'network', display: 'display', displays: 'display', notifications: 'notifications', apps: 'applications',
        accessibility: 'universal-access', keyboard: 'keyboard', updates: 'info-overview', general: '' }
      await launchDetached('gnome-control-center', panels[p] ? [panels[p]] : [])
      return 'opened Settings'
    }
    if (findOnPath('systemsettings', this.env)) {
      await launchDetached('systemsettings', [])
      return 'opened System Settings'
    }
    throw new Error('This desktop has no settings app Jarvis knows how to open.')
  }

  async runInTerminal(command, cwd) {
    const shell = `${command}; exec "\${SHELL:-bash}"`
    const options = [
      ['gnome-terminal', ['--', 'bash', '-lc', shell]], ['kgx', ['--', 'bash', '-lc', shell]], ['ptyxis', ['--', 'bash', '-lc', shell]],
      ['konsole', ['-e', 'bash', '-lc', shell]], ['xfce4-terminal', ['-x', 'bash', '-lc', shell]], ['x-terminal-emulator', ['-e', 'bash', '-lc', shell]],
      ['xterm', ['-e', 'bash', '-lc', shell]],
    ]
    for (const [term, args] of options) {
      if (!findOnPath(term, this.env)) continue
      const r = await launchDetached(term, args, { cwd: cwd ?? this.env.HOME ?? homedir() })
      if (r.ok) return `started in ${term}`
    }
    throw new Error('No terminal app was found.')
  }

  // -- sound --
  play(file) {
    const player = this.tool(['pw-play', 'paplay', 'aplay'])
    if (!player) return Promise.reject(new Error('no audio player (pw-play, paplay or aplay)'))
    return new Promise((resolve) => {
      const child = spawn(player, player === 'aplay' ? ['-q', file] : [file], { stdio: 'ignore' })
      this.player = child
      child.on('error', () => resolve(false))
      child.on('exit', (code) => {
        if (this.player === child) this.player = null
        resolve(code === 0)
      })
    })
  }

  say(text) {
    const voice = this.tool(['espeak-ng', 'espeak', 'spd-say'])
    if (!voice) return Promise.reject(new Error('no system voice (espeak-ng or speech-dispatcher)'))
    return new Promise((resolve) => {
      const child = spawn(voice, voice === 'spd-say' ? ['-w', text] : ['-v', 'en-gb', text], { stdio: 'ignore' })
      this.player = child
      child.on('error', () => resolve(false))
      child.on('exit', () => {
        if (this.player === child) this.player = null
        resolve(true)
      })
    })
  }

  async stopSound() {
    try {
      this.player?.kill()
    } catch {
      /* gone */
    }
    this.player = null
  }

  async camera() {
    const devices = readdirSync('/dev').filter((d) => /^video\d+$/.test(d)).sort()
    if (!devices.length) throw new Error('No camera (/dev/video*) was found.')
    const dev = `/dev/${devices[0]}`
    let shot
    if (findOnPath('ffmpeg', this.env)) {
      shot = await run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'v4l2', '-i', dev, '-frames:v', '1', '-f', 'image2', '-vcodec', 'mjpeg', 'pipe:1'], { timeout: 20_000, encoding: null })
    } else if (findOnPath('fswebcam', this.env)) {
      shot = await run('fswebcam', ['-q', '-d', dev, '--no-banner', '-r', '1280x720', '--jpeg', '85', '-'], { timeout: 20_000, encoding: null })
    } else {
      throw new Error('Taking a photo needs ffmpeg or fswebcam.')
    }
    if (shot.code !== 0 || !shot.stdout?.length) {
      throw new Error(/denied|permission/i.test(shot.stderr) ? `No access to ${dev}: add yourself to the "video" group.` : 'The camera did not give a picture.')
    }
    return { image: shot.stdout.toString('base64'), mimeType: 'image/jpeg' }
  }
}
