#!/usr/bin/env node
/**
 * Runs the packaged build (not the checkout) to prove the package is complete: its CLI answers,
 * its agent starts the bridge and serves the built face, the bridge proves itself, and on
 * Windows/Linux its voice assistant starts and answers on its control channel.
 *   node packaging/ci/smoke-package.mjs <staged package folder>
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const PKG = resolve(process.argv[2] ?? '')
if (!existsSync(join(PKG, 'bin', 'jarvis.mjs'))) throw new Error(`not a package folder: ${PKG}`)
const scratch = mkdtempSync(join(tmpdir(), 'jarvis-smoke-'))
const env = {
  ...process.env, JARVIS_HOME: join(scratch, 'support'), JARVIS_LOG_DIR: join(scratch, 'logs'), JARVIS_CACHE_DIR: join(scratch, 'cache'),
  JARVIS_VOICE_KEY_FILE: join(scratch, 'support', 'bridge.key'), JARVIS_BRIDGE_PORT: '28787', JARVIS_FACE_PORT: '5199', JARVIS_AGENT_VOICE_ENGINE: '0',
}
const say = (m) => console.log(`[smoke] ${m}`)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const fail = (m) => {
  console.error(`[smoke] FAILED: ${m}`)
  process.exitCode = 1
}

const node = (args) => spawnSync(process.execPath, args, { cwd: PKG, env, encoding: 'utf8' })
const v = node([join(PKG, 'bin', 'jarvis.mjs'), 'version'])
if (v.status !== 0 || !/^\d+\.\d+\.\d+/.test(v.stdout.trim())) fail(`jarvis version: ${v.stderr || v.stdout}`)
else say(`jarvis version ${v.stdout.trim()}`)
const caps = node([join(PKG, 'bin', 'jarvis.mjs'), 'capabilities', '--json'])
if (caps.status !== 0) fail(`jarvis capabilities: ${caps.stderr}`)
else say(`capabilities: ${Object.entries(JSON.parse(caps.stdout).capabilities).filter(([, c]) => c.available).map(([k]) => k).join(', ')}`)

const agent = spawn(process.execPath, [join(PKG, 'core', 'supervisor.mjs')], { cwd: PKG, env, stdio: 'ignore' })
let status = null
for (let i = 0; i < 120; i++) {
  await sleep(500)
  try {
    status = JSON.parse(readFileSync(join(env.JARVIS_HOME, 'agent-status.json'), 'utf8'))
    if (status.services.bridge?.mode === 'running' && status.services.face?.mode === 'running') break
  } catch {
    /* not yet */
  }
}
if (status?.services.bridge?.mode !== 'running') fail(`the packaged bridge did not start: ${JSON.stringify(status?.services ?? {})}\n${safeRead(join(env.JARVIS_LOG_DIR, 'bridge.log'))}`)
else say('bridge running')
if (status?.services.face?.mode !== 'running') fail(`the packaged face did not start: ${safeRead(join(env.JARVIS_LOG_DIR, 'face.log'))}`)
else {
  const html = await (await fetch('http://127.0.0.1:5199/')).text()
  if (!/<html/i.test(html)) fail('the face did not serve index.html')
  else say('face serves the built index.html')
}

if (process.platform !== 'darwin') {
  const client = spawn(process.execPath, [join(PKG, 'client', 'main.mjs'), '--no-mic', '--no-tray'], { cwd: PKG, env: { ...env }, stdio: 'ignore' })
  const { sendControl } = await import(pathToFileURL(join(PKG, 'core', 'control.mjs')).href)
  const { loadKey } = await import(pathToFileURL(join(PKG, 'bridge', 'voice-auth.mjs')).href)
  const { jarvisPaths } = await import(pathToFileURL(join(PKG, 'core', 'paths.mjs')).href)
  const p = jarvisPaths({ env })
  let pong = null
  for (let i = 0; i < 60 && pong !== 'pong'; i++) {
    await sleep(500)
    pong = await sendControl({ path: p.control, key: loadKey(), command: 'ping', timeoutMs: 2000 }).catch(() => null)
  }
  if (pong !== 'pong') fail(`the packaged voice assistant did not answer: ${safeRead(join(env.JARVIS_LOG_DIR, 'voice.log'))}`)
  else say('voice assistant answers on its control channel')
  await sendControl({ path: p.control, key: loadKey(), command: 'quit' }).catch(() => {})
  await sleep(800)
  client.kill()
}

agent.kill('SIGTERM')
if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(agent.pid), '/T', '/F'], { stdio: 'ignore' })
await sleep(1500)
rmSync(scratch, { recursive: true, force: true })
say(process.exitCode ? 'package smoke test FAILED' : 'package smoke test passed')

function safeRead(f) {
  try {
    return readFileSync(f, 'utf8').split('\n').slice(-30).join('\n')
  } catch {
    return '(no log)'
  }
}
