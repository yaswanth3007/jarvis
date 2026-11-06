#!/usr/bin/env node
/**
 * Keeps one Jarvis process running where the OS has no per-user service manager that
 * can: Windows (started at login from HKCU\Software\Microsoft\Windows\CurrentVersion\Run)
 * and Linux desktops without systemd (started from ~/.config/autostart). launchd and
 * systemd --user do this job themselves on macOS and most Linux systems.
 *
 *   node core/keepalive.mjs agent    → core/supervisor.mjs (bridge, face, voice engine)
 *   node core/keepalive.mjs voice    → client/main.mjs (the "Hey Jarvis" assistant)
 *
 * Like launchd's KeepAlive {SuccessfulExit: false} with a 10-second throttle: a crash is
 * restarted, a clean exit (code 0) is not. `jarvis stop` asks it to stop over a local
 * channel that, like the voice assistant's, only answers someone holding the per-install key.
 */
import { fork } from 'node:child_process'
import { mkdirSync, writeFileSync, rmSync, createWriteStream } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ensureKey } from '../bridge/voice-auth.mjs'
import { startControl } from './control.mjs'
import { keepaliveChannel, paths } from './paths.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')
const TARGETS = { agent: join(REPO, 'core', 'supervisor.mjs'), voice: join(REPO, 'client', 'main.mjs') }
const name = process.argv[2]
if (!TARGETS[name]) {
  console.error('usage: keepalive.mjs agent|voice')
  process.exit(64)
}
mkdirSync(paths.logs, { recursive: true })
const out = createWriteStream(join(paths.logs, `keepalive-${name}.log`), { flags: 'a' })
const log = (m) => out.write(`${new Date().toISOString()} ${m}\n`)

const key = ensureKey()
let child = null
let stopping = false
let lastStart = 0

function start() {
  lastStart = Date.now()
  child = fork(TARGETS[name], [], { cwd: REPO, stdio: ['ignore', 'ignore', 'ignore', 'ipc'], windowsHide: true })
  log(`started ${name} (pid ${child.pid})`)
  child.on('exit', (code, signal) => {
    child = null
    if (stopping) {
      log(`${name} stopped`)
      finish()
      return
    }
    if (code === 0) {
      log(`${name} exited cleanly — not restarting`)
      finish()
      return
    }
    const wait = Math.max(0, 10_000 - (Date.now() - lastStart))
    log(`${name} exited (${signal ?? `code ${code}`}) — restarting in ${Math.round(wait / 1000)}s`)
    setTimeout(() => !stopping && start(), wait)
  })
}

function finish() {
  rmSync(join(paths.support, `keepalive-${name}.pid`), { force: true })
  setTimeout(() => process.exit(0), 100)
}

function stop() {
  stopping = true
  if (!child) return finish()
  child.send('shutdown')
  setTimeout(() => child?.kill(), 15_000).unref()
}

const control = startControl({
  path: keepaliveChannel(name),
  key,
  log,
  handle: async (line) => {
    if (line === 'ping') return 'pong'
    if (line === 'status') return JSON.stringify({ name, keepalivePid: process.pid, pid: child?.pid ?? null, since: new Date(lastStart).toISOString() })
    if (line === 'stop') {
      setTimeout(stop, 50)
      return 'ok: stopping'
    }
    if (line === 'restart') {
      child?.send('shutdown')
      return 'ok: restarting'
    }
    return 'error: unknown command'
  },
})
control.on('error', (err) => {
  // Another keepalive for the same thing already owns the channel: leave it running.
  if (err.code === 'EADDRINUSE') {
    log(`another ${name} keepalive is running — exiting`)
    process.exit(0)
  }
})
writeFileSync(join(paths.support, `keepalive-${name}.pid`), `${process.pid}\n`)
for (const s of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(s, stop)
start()
