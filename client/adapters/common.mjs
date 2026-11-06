/**
 * Helpers both desktop adapters share: finding an installed app by the name the user
 * said, running helper programs safely (no shell, argument arrays only), and tidying
 * text that comes from other apps before anyone sees it.
 */
import { spawn } from 'node:child_process'
import { normalized } from '../../core/commands.mjs'

/** Names people say → the names apps are installed under. */
const ALIASES = {
  'vs code': ['visual studio code', 'code'], vscode: ['visual studio code', 'code'], code: ['visual studio code'],
  chrome: ['google chrome', 'chromium'], 'google chrome': ['chromium'], edge: ['microsoft edge'], teams: ['microsoft teams'],
  word: ['microsoft word', 'word', 'libreoffice writer'], excel: ['microsoft excel', 'excel', 'libreoffice calc'],
  powerpoint: ['microsoft powerpoint', 'libreoffice impress'], outlook: ['microsoft outlook', 'outlook'],
  terminal: ['windows terminal', 'terminal', 'gnome terminal', 'console', 'konsole', 'xfce terminal', 'xterm'],
  files: ['file explorer', 'files', 'nautilus', 'dolphin', 'thunar', 'nemo'], 'file explorer': ['explorer', 'files'],
  explorer: ['file explorer', 'files'], finder: ['file explorer', 'files'], settings: ['settings', 'gnome settings', 'system settings'],
  'system settings': ['settings'], calculator: ['calculator', 'gnome calculator', 'kcalc', 'galculator'],
  'text editor': ['text editor', 'gedit', 'kate', 'mousepad', 'notepad'], notepad: ['notepad', 'text editor'],
  'task manager': ['task manager', 'system monitor'], 'activity monitor': ['task manager', 'system monitor'],
  browser: ['microsoft edge', 'firefox', 'google chrome', 'chromium'],
}

/**
 * The installed app a spoken name means, or null. Exact names win, then aliases, then a
 * name that starts with what was said ("visual studio" → "Visual Studio Code").
 * @param {{name: string}[]} apps
 */
export function matchApp(apps, spoken) {
  const want = normalized(String(spoken ?? '').replace(/\.(exe|desktop|app)$/i, '')).replace(/^(the|my) /, '').replace(/ (app|application)$/, '')
  if (!want) return null
  const byName = new Map()
  for (const a of apps) {
    const n = normalized(a.name)
    if (n && !byName.has(n)) byName.set(n, a)
  }
  if (byName.has(want)) return byName.get(want)
  for (const alias of ALIASES[want] ?? []) if (byName.has(alias)) return byName.get(alias)
  const squashed = want.replace(/ /g, '')
  for (const [n, a] of byName) if (n.replace(/ /g, '') === squashed) return a
  let best = null
  for (const [n, a] of byName) {
    if (n.startsWith(`${want} `) && (!best || n.length < normalized(best.name).length)) best = a
  }
  if (best) return best
  // Every word said appears, in order, as a whole word of the app's name ("calculator" → "GNOME Calculator").
  for (const [n, a] of byName) {
    const words = n.split(' ')
    if (want.split(' ').every((w) => words.includes(w)) && words.length <= want.split(' ').length + 2) return a
  }
  return null
}

/**
 * Runs a program (never through a shell) and collects its output.
 * @returns {Promise<{code: number|null, stdout: string, stderr: string, error?: Error}>}
 */
export function run(cmd, args = [], { timeout = 15_000, input, env, cwd, encoding = 'utf8', maxBytes = 30 * 1024 * 1024 } = {}) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env: env ?? process.env, cwd })
    } catch (error) {
      resolve({ code: null, stdout: '', stderr: '', error })
      return
    }
    const out = []
    const err = []
    let size = 0
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout)
    child.stdout.on('data', (d) => {
      size += d.length
      if (size <= maxBytes) out.push(d)
    })
    child.stderr.on('data', (d) => err.push(d))
    child.on('error', (error) => {
      clearTimeout(timer)
      resolve({ code: null, stdout: '', stderr: '', error })
    })
    child.on('close', (code) => {
      clearTimeout(timer)
      const buf = Buffer.concat(out)
      resolve({ code, stdout: encoding ? buf.toString(encoding) : buf, stderr: Buffer.concat(err).toString('utf8') })
    })
    if (input !== undefined) child.stdin.end(input)
    else child.stdin.end()
  })
}

/** Starts a program the user asked to open, fully detached from Jarvis. */
export function launchDetached(cmd, args = [], { cwd, env } = {}) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(cmd, args, { detached: true, stdio: 'ignore', windowsHide: false, cwd, env: env ?? process.env })
    } catch (error) {
      resolve({ ok: false, error })
      return
    }
    child.once('error', (error) => resolve({ ok: false, error }))
    child.once('spawn', () => {
      child.unref()
      resolve({ ok: true, pid: child.pid })
    })
  })
}

/**
 * Text from another app's window (a title, a page heading) is someone else's words: one
 * line, no brackets that could look like Jarvis's own context markers, and short.
 */
export const plain = (text, max = 120) =>
  String(text ?? '').replace(/[[\]\p{Cc}\p{Zl}\p{Zp}]+/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, max)

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Waits until check() returns something truthy, up to ms. */
export async function waitFor(check, ms = 10_000, every = 300) {
  const until = Date.now() + ms
  while (Date.now() < until) {
    const v = await check()
    if (v) return v
    await sleep(every)
  }
  return null
}
