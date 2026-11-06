#!/usr/bin/env node
/**
 * JARVIS background agent.
 *
 * The platform's own service manager starts this at login and stops it at
 * logout — launchd on macOS (~/Library/LaunchAgents/local.jarvis.agent.plist),
 * systemd --user on Linux (jarvis-agent.service), and on Windows the per-user
 * Run entry through core/keepalive.mjs. It keeps three things running for the
 * voice assistant, each exactly as the project already runs them:
 *
 *   bridge        node bridge/server.mjs          ws://localhost:8787  (the brain)
 *   face          vite, or the built face (dist/)  http://localhost:5173
 *   voice-engine  node core/voice-server.mjs      127.0.0.1:8790 (Kokoro voice)
 *
 * It never starts a second copy of anything. A service that is already
 * answering on its port — an `npm start` you ran in a terminal, say — is
 * reused and watched, and only taken over once it goes away. Crashed or hung
 * services are restarted with backoff. On SIGTERM (logout, shutdown,
 * `jarvisctl stop`) every service it started is stopped cleanly.
 *
 * Optional settings live in agent.env in Jarvis's support folder (core/paths.mjs;
 * on macOS ~/Library/Application Support/JarvisVoice/agent.env) as KEY=VALUE lines (for example JARVIS_ALLOW_WRITES=1 or ELEVENLABS_API_KEY).
 * They are passed to the services and never written to any log.
 */
import { spawn } from 'node:child_process'
import { createWriteStream, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ensureKey, freshNonce, proveIdentity, sameDigest } from '../bridge/voice-auth.mjs'
import { paths } from './paths.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')
const LOGS = paths.logs
const SUPPORT = paths.support
const STATUS_FILE = paths.agentStatus
const ENV_FILE = paths.agentEnv
const MAX_LOG_BYTES = 5 * 1024 * 1024

mkdirSync(LOGS, { recursive: true })
mkdirSync(SUPPORT, { recursive: true, mode: 0o700 })

// The per-install key the bridge, the voice engine and Jarvis Voice prove themselves
// with (bridge/voice-auth.mjs). Created once, readable only by this user.
const KEY = ensureKey()

// ---------------------------------------------------------------------------
// Logs: one file per service, rotated at 5 MB (one previous file kept).
// ---------------------------------------------------------------------------

class RotatingLog {
  constructor(name) {
    this.path = join(LOGS, `${name}.log`)
    this.open()
  }
  open() {
    this.size = existsSync(this.path) ? statSync(this.path).size : 0
    this.stream = createWriteStream(this.path, { flags: 'a' })
  }
  write(text) {
    if (this.size > MAX_LOG_BYTES) {
      this.stream.end()
      try {
        renameSync(this.path, `${this.path}.1`)
      } catch {
        /* keep writing to the current file */
      }
      this.open()
    }
    this.size += Buffer.byteLength(text)
    this.stream.write(text)
  }
}

const agentLog = new RotatingLog('agent')
const stamp = () => new Date().toISOString()
function log(message) {
  const line = `${stamp()} ${message}\n`
  agentLog.write(line)
  if (process.stdout.isTTY) process.stdout.write(line)
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

function readEnvFile() {
  const values = {}
  if (!existsSync(ENV_FILE)) return values
  for (const raw of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const key = line.slice(0, eq).trim()
    let value = line.slice(eq + 1).trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) values[key] = value
  }
  return values
}

const fileEnv = readEnvFile()
const baseEnv = { ...process.env }
// Variables that only describe some other Claude Code session must not leak
// into the bridge's own Claude process.
for (const key of Object.keys(baseEnv)) {
  if (key === 'CLAUDECODE' || key.startsWith('CLAUDE_CODE_')) delete baseEnv[key]
}
const childEnv = { ...baseEnv, ...fileEnv }

const BRIDGE_PORT = Number(childEnv.JARVIS_BRIDGE_PORT ?? 8787)
const FACE_PORT = Number(childEnv.JARVIS_FACE_PORT ?? 5173)
const VOICE_PORT = Number(childEnv.JARVIS_VOICE_PORT ?? 8790)
const FACE_ENABLED = (childEnv.JARVIS_AGENT_FACE ?? '1') !== '0'
// A development checkout runs the face with Vite, as `npm start` does. An installed
// package has no Vite: it serves the face that was built into dist/ at packaging time.
const VITE = join(REPO, 'node_modules/vite/bin/vite.js')
const BUILT_FACE = join(REPO, 'dist/index.html')
const faceArgs = existsSync(VITE) ? [VITE, '--strictPort'] : existsSync(BUILT_FACE) ? [join(HERE, 'face-server.mjs')] : null
const VOICE_ENGINE_ENABLED = (childEnv.JARVIS_AGENT_VOICE_ENGINE ?? '1') !== '0'

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

const services = [
  {
    name: 'bridge',
    port: BRIDGE_PORT,
    health: `http://127.0.0.1:${BRIDGE_PORT}/health`,
    // --import takes a URL: on Windows a bare "C:\…" path would read as a URL scheme.
    args: ['--import', pathToFileURL(join(HERE, 'loopback.mjs')).href, join(REPO, 'bridge/server.mjs')],
    env: {},
    grace: 30_000,
  },
  {
    name: 'face',
    port: FACE_PORT,
    health: `http://localhost:${FACE_PORT}/`,
    args: faceArgs ?? [],
    env: { PORT: String(FACE_PORT) },
    grace: 60_000,
    enabled: FACE_ENABLED && faceArgs !== null,
  },
  {
    name: 'voice-engine',
    port: VOICE_PORT,
    health: `http://127.0.0.1:${VOICE_PORT}/health`,
    args: [join(HERE, 'voice-server.mjs')],
    env: { JARVIS_VOICE_PORT: String(VOICE_PORT) },
    grace: 30_000,
    enabled: VOICE_ENGINE_ENABLED,
  },
].filter((s) => s.enabled !== false)

if (FACE_ENABLED && faceArgs === null) {
  // Logged once the log is open, below: neither Vite nor a built face is present.
  process.nextTick(() => log('face: not started — neither node_modules/vite nor a built dist/ is present (run npm run build)'))
}

for (const s of services) {
  Object.assign(s, { mode: 'starting', child: null, pid: null, restarts: 0, backoff: 0, since: Date.now(), log: new RotatingLog(s.name) })
}

let stopping = false
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const impostorNoted = new Set()

async function healthy(svc) {
  try {
    // The bridge and the voice engine must answer a nonce with proof that they hold this
    // user's key, so a process from another account holding the port is never adopted.
    const nonce = svc.name === 'face' ? null : freshNonce()
    const res = await fetch(nonce ? `${svc.health}?nonce=${nonce}` : svc.health, { signal: AbortSignal.timeout(3000) })
    if (!res.ok) return false
    const body = await res.text()
    if (svc.name === 'face') return body.length > 0
    if (!body.includes('"ok":true')) return false
    let proof = null
    try {
      proof = JSON.parse(body).proof ?? null
    } catch {
      /* not one of ours */
    }
    const who = svc.name === 'bridge' ? 'jarvis-bridge-http' : 'jarvis-voice-engine'
    if (KEY && sameDigest(proof, proveIdentity(KEY, who, nonce))) {
      impostorNoted.delete(svc.name)
      return true
    }
    if (!impostorNoted.has(svc.name)) {
      impostorNoted.add(svc.name)
      log(`${svc.name}: something on port ${svc.port} answers but cannot prove it is this user's — not using it`)
    }
    return false
  } catch {
    return false
  }
}

function setMode(svc, mode) {
  if (svc.mode !== mode) {
    svc.mode = mode
    svc.since = Date.now()
  }
  writeStatus()
}

function writeStatus() {
  const status = {
    updated: stamp(),
    agentPid: process.pid,
    repo: REPO,
    stopping,
    services: Object.fromEntries(
      services.map((s) => [
        s.name,
        { mode: s.mode, pid: s.pid, port: s.port, restarts: s.restarts, since: new Date(s.since).toISOString() },
      ]),
    ),
  }
  try {
    writeFileSync(STATUS_FILE, `${JSON.stringify(status, null, 2)}\n`)
  } catch {
    /* status is advisory */
  }
}

function pipeLines(svc, stream) {
  let pending = ''
  stream.setEncoding('utf8')
  stream.on('data', (chunk) => {
    pending += chunk
    const lines = pending.split('\n')
    pending = lines.pop() ?? ''
    for (const line of lines) svc.log.write(`${stamp()} ${line}\n`)
  })
  stream.on('end', () => {
    if (pending) svc.log.write(`${stamp()} ${pending}\n`)
  })
}

/** Starts one copy of the service and resolves with its exit code once it ends. */
function runChild(svc) {
  return new Promise((resolvePromise) => {
    const child = spawn(process.execPath, svc.args, {
      cwd: REPO,
      env: { ...childEnv, ...svc.env },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    })
    svc.child = child
    svc.pid = child.pid
    svc.log.write(`${stamp()} --- started by the JARVIS agent (pid ${child.pid}) ---\n`)
    pipeLines(svc, child.stdout)
    pipeLines(svc, child.stderr)

    const started = Date.now()
    let failures = 0
    let announced = false
    const monitor = setInterval(async () => {
      if (stopping || child.exitCode !== null) return
      if (await healthy(svc)) {
        failures = 0
        if (!announced) {
          announced = true
          log(`${svc.name}: running (pid ${child.pid})`)
          setMode(svc, 'running')
        }
        return
      }
      if (Date.now() - started < svc.grace) return
      failures++
      if (failures >= 12) {
        log(`${svc.name}: not answering on port ${svc.port} for a minute — restarting it`)
        failures = 0
        void stopChild(svc)
      }
    }, 5000)

    child.on('error', (err) => log(`${svc.name}: failed to start: ${err.message}`))
    child.on('exit', (code, signal) => {
      clearInterval(monitor)
      svc.child = null
      svc.pid = null
      resolvePromise({ code, signal, uptime: Date.now() - started })
    })
  })
}

function stopChild(svc, timeoutMs = 8000) {
  const child = svc.child
  if (!child || child.exitCode !== null) return Promise.resolve()
  if (process.platform === 'win32') {
    // Windows has no SIGTERM: end the service and everything it started (the bridge's
    // Claude process included), so nothing is left running behind.
    return new Promise((done) => {
      child.once('exit', () => done())
      spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }).on('error', () => child.kill())
      setTimeout(done, timeoutMs).unref()
    })
  }
  return new Promise((done) => {
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL')
      } catch {
        /* already gone */
      }
    }, timeoutMs)
    child.once('exit', () => {
      clearTimeout(timer)
      done()
    })
    try {
      child.kill('SIGTERM')
    } catch {
      clearTimeout(timer)
      done()
    }
  })
}

async function supervise(svc) {
  while (!stopping) {
    // Already served by someone else (for example `npm start` in a terminal)?
    // Then reuse it rather than start a duplicate, and keep checking.
    if (await healthy(svc)) {
      if (svc.mode !== 'external') {
        log(`${svc.name}: already running outside the agent on port ${svc.port} — reusing it`)
        setMode(svc, 'external')
      }
      await sleep(5000)
      continue
    }
    if (stopping) break
    if (svc.mode === 'external') log(`${svc.name}: the outside copy has gone — starting one`)
    setMode(svc, 'starting')
    const { code, signal, uptime } = await runChild(svc)
    if (stopping) break
    svc.restarts++
    svc.backoff = uptime > 120_000 ? 1000 : Math.min(Math.max(svc.backoff * 2, 1000), 60_000)
    log(
      `${svc.name}: exited (${signal ?? `code ${code}`}) after ${Math.round(uptime / 1000)}s — ` +
        `checking again in ${svc.backoff / 1000}s`,
    )
    setMode(svc, 'backoff')
    await sleep(svc.backoff)
  }
}

async function shutdown(reason) {
  if (stopping) return
  stopping = true
  log(`stopping (${reason})`)
  writeStatus()
  await Promise.all(services.map((s) => stopChild(s)))
  for (const s of services) s.mode = 'stopped'
  writeStatus()
  log('stopped cleanly')
  setTimeout(() => process.exit(0), 100)
}

for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => void shutdown(signal))
// From core/keepalive.mjs (Windows, and Linux without systemd): the cross-platform "please stop".
process.on('message', (m) => m === 'shutdown' && void shutdown('stop requested'))
process.on('uncaughtException', (err) => {
  log(`agent error: ${err?.stack ?? err}`)
  // Non-zero, so launchd brings the agent back.
  Promise.all(services.map((s) => stopChild(s, 3000))).finally(() => process.exit(1))
})

const configured = Object.keys(fileEnv)
log(
  `agent starting (pid ${process.pid}, node ${process.version}, repo ${REPO})` +
    (configured.length ? `; agent.env sets ${configured.join(', ')}` : ''),
)
writeStatus()
for (const svc of services) void supervise(svc)
