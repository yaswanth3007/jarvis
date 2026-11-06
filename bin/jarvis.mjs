#!/usr/bin/env node
/**
 * jarvis — one command for Jarvis on macOS, Windows and Linux.
 *
 *   jarvis setup            check everything, create the per-install key, download the speech
 *                           models (Windows/Linux), print what this computer can do
 *   jarvis install          start Jarvis at login (launchd / Run key / systemd --user) and now
 *   jarvis uninstall        stop it and remove the login entries (--purge also deletes settings,
 *                           permissions, the key, logs and downloaded models)
 *   jarvis start | stop | restart | status | doctor | capabilities | logs [name]
 *   jarvis ask <text> | answer <text> | say <text> | tasks [all] | cancel <n|all>
 *   jarvis mute | unmute | permissions | devices | reload | version
 *
 * On macOS this hands over to macos/jarvisctl, which manages the native menu bar app.
 * Nothing here needs administrator rights; nothing outside the user's own folders is touched.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ensureKey, loadKey } from '../bridge/voice-auth.mjs'
import { sendControl } from '../core/control.mjs'
import { ensureModels, modelStatus } from '../core/models.mjs'
import { keepaliveChannel, paths } from '../core/paths.mjs'
import { describeCapabilities, detectCapabilities, findOnPath, sherpaAvailable } from '../core/platform.mjs'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PKG = JSON.parse(readFileSync(join(REPO, 'package.json'), 'utf8'))
const [command = 'help', ...rest] = process.argv.slice(2)
const argument = rest.join(' ')
const OS = paths.os
const NODE = process.execPath

const say = (...a) => console.log(...a)
const fail = (msg, code = 1) => {
  console.error(`jarvis: ${msg}`)
  process.exit(code)
}

// ---------------------------------------------------------------------------
// macOS: the native app has its own manager.
// ---------------------------------------------------------------------------

if (OS === 'macos' && !['capabilities', 'version', 'help', '--help', '-h'].includes(command)) {
  const map = { setup: 'doctor', models: 'doctor' }
  const r = spawnSync(join(REPO, 'macos', 'jarvisctl'), [map[command] ?? command, ...rest], { stdio: 'inherit' })
  process.exit(r.status ?? 1)
}

// ---------------------------------------------------------------------------
// Login items and services
// ---------------------------------------------------------------------------

const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
const UNIT_DIR = join(process.env.XDG_CONFIG_HOME?.startsWith('/') ? process.env.XDG_CONFIG_HOME : join(paths.home, '.config'), 'systemd', 'user')
const AUTOSTART_DIR = join(process.env.XDG_CONFIG_HOME?.startsWith('/') ? process.env.XDG_CONFIG_HOME : join(paths.home, '.config'), 'autostart')
const SERVICES = { agent: 'jarvis-agent.service', voice: 'jarvis-voice.service' }

const systemdUser = () => OS === 'linux' && findOnPath('systemctl') && spawnSync('systemctl', ['--user', 'show-environment'], { stdio: 'ignore' }).status === 0
const quoteExec = (a) => (/[\s"'\\$`]/.test(a) ? `"${a.replace(/(["`$\\])/g, '\\$1')}"` : a)
const quoteWin = (a) => `"${a}"`

function windowsRunCommand(which) {
  const conhost = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'conhost.exe')
  // conhost --headless runs Node with no console window at login.
  return `${quoteWin(conhost)} --headless ${quoteWin(NODE)} ${quoteWin(join(REPO, 'core', 'keepalive.mjs'))} ${which}`
}

function unitFile(which) {
  if (which === 'agent') {
    return `[Unit]
Description=JARVIS background agent (bridge, face, voice engine)
Documentation=file://${join(REPO, 'docs', 'setup-linux.md')}

[Service]
Type=simple
ExecStart=${quoteExec(NODE)} ${quoteExec(join(REPO, 'core', 'supervisor.mjs'))}
WorkingDirectory=${REPO}
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=default.target
`
  }
  return `[Unit]
Description=Jarvis Voice — the "Hey Jarvis" assistant
Documentation=file://${join(REPO, 'docs', 'setup-linux.md')}
PartOf=graphical-session.target
After=graphical-session.target ${SERVICES.agent}
Wants=${SERVICES.agent}

[Service]
Type=simple
ExecStart=${quoteExec(NODE)} ${quoteExec(join(REPO, 'client', 'main.mjs'))}
WorkingDirectory=${REPO}
Restart=on-failure
RestartSec=10
TimeoutStopSec=15

[Install]
WantedBy=graphical-session.target
`
}

function autostartEntry(which) {
  return `[Desktop Entry]
Type=Application
Name=${which === 'agent' ? 'JARVIS agent' : 'Jarvis Voice'}
Comment=${which === 'agent' ? 'Bridge, face and voice engine for Jarvis' : 'The "Hey Jarvis" voice assistant'}
Exec=${quoteExec(NODE)} ${quoteExec(join(REPO, 'core', 'keepalive.mjs'))} ${which}
NoDisplay=true
X-GNOME-Autostart-enabled=true
`
}

function startKeepalive(which) {
  const child = spawn(NODE, [join(REPO, 'core', 'keepalive.mjs'), which], { detached: true, stdio: 'ignore', windowsHide: true, cwd: REPO })
  child.unref()
}

async function keepaliveSay(which, line) {
  const key = loadKey()
  if (!key) return null
  return sendControl({ path: keepaliveChannel(which), key, command: line, timeoutMs: 4000 }).catch(() => null)
}

const run = (cmd, args) => spawnSync(cmd, args, { stdio: 'pipe', encoding: 'utf8', windowsHide: true })

async function install() {
  ensureKey()
  if (OS === 'windows') {
    for (const which of ['agent', 'voice']) {
      const r = run('reg', ['add', RUN_KEY, '/v', which === 'agent' ? 'JarvisAgent' : 'JarvisVoice', '/t', 'REG_SZ', '/d', windowsRunCommand(which), '/f'])
      if (r.status !== 0) fail(`could not add the login entry: ${r.stderr.trim()}`)
    }
    say(`Login entries added (${RUN_KEY}: JarvisAgent, JarvisVoice).`)
    await start()
    return
  }
  if (systemdUser()) {
    mkdirSync(UNIT_DIR, { recursive: true })
    for (const which of ['agent', 'voice']) writeFileSync(join(UNIT_DIR, SERVICES[which]), unitFile(which))
    run('systemctl', ['--user', 'daemon-reload'])
    const r = run('systemctl', ['--user', 'enable', '--now', SERVICES.agent, SERVICES.voice])
    if (r.status !== 0) fail(`systemctl could not start the services: ${r.stderr.trim()}`)
    say(`Installed and started ${SERVICES.agent} and ${SERVICES.voice} (systemd --user, in ${UNIT_DIR}).`)
    return
  }
  mkdirSync(AUTOSTART_DIR, { recursive: true })
  for (const which of ['agent', 'voice']) writeFileSync(join(AUTOSTART_DIR, `jarvis-${which}.desktop`), autostartEntry(which))
  say(`No systemd user session: added login entries to ${AUTOSTART_DIR} (XDG autostart).`)
  await start()
}

async function uninstall() {
  await stop()
  if (OS === 'windows') {
    for (const v of ['JarvisAgent', 'JarvisVoice']) run('reg', ['delete', RUN_KEY, '/v', v, '/f'])
    say('Login entries removed.')
  } else {
    if (systemdUser()) run('systemctl', ['--user', 'disable', SERVICES.agent, SERVICES.voice])
    for (const f of Object.values(SERVICES)) rmSync(join(UNIT_DIR, f), { force: true })
    if (findOnPath('systemctl')) run('systemctl', ['--user', 'daemon-reload'])
    for (const which of ['agent', 'voice']) rmSync(join(AUTOSTART_DIR, `jarvis-${which}.desktop`), { force: true })
    say('Services and login entries removed.')
  }
  if (rest.includes('--purge')) {
    for (const dir of [...new Set([paths.support, paths.logs, paths.cache])]) {
      rmSync(dir, { recursive: true, force: true })
      say(`Deleted ${dir}`)
    }
    say('Settings, permissions, the per-install key, logs and downloaded models are gone.')
  } else {
    say(`Settings and permissions are kept in ${paths.support} (jarvis uninstall --purge deletes them).`)
  }
}

async function start() {
  if (OS === 'linux' && systemdUser() && existsSync(join(UNIT_DIR, SERVICES.agent))) {
    const r = run('systemctl', ['--user', 'start', SERVICES.agent, SERVICES.voice])
    if (r.status !== 0) fail(r.stderr.trim())
    say('Started.')
    return
  }
  ensureKey()
  for (const which of ['agent', 'voice']) {
    if ((await keepaliveSay(which, 'ping')) === 'pong') say(`${which}: already running`)
    else {
      startKeepalive(which)
      say(`${which}: started`)
    }
  }
}

async function stop() {
  if (OS === 'linux' && systemdUser() && existsSync(join(UNIT_DIR, SERVICES.agent))) {
    run('systemctl', ['--user', 'stop', SERVICES.voice, SERVICES.agent])
  }
  for (const which of ['voice', 'agent']) {
    const r = await keepaliveSay(which, 'stop')
    if (r) say(`${which}: stopping`)
  }
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

function agentStatus() {
  try {
    return JSON.parse(readFileSync(paths.agentStatus, 'utf8'))
  } catch {
    return null
  }
}

async function voice(line) {
  const key = loadKey()
  if (!key) fail('there is no per-install key yet: run jarvis setup (or start the agent)')
  try {
    return await sendControl({ path: paths.control, key, command: line })
  } catch (err) {
    fail(err.message)
  }
  return ''
}

async function status() {
  const a = agentStatus()
  say(a ? `Agent (pid ${a.agentPid}${a.stopping ? ', stopping' : ''}), updated ${a.updated}:` : 'Agent: not running (no status yet)')
  for (const [name, s] of Object.entries(a?.services ?? {})) say(`  ${name.padEnd(13)} ${String(s.mode).padEnd(9)} port ${s.port}${s.pid ? `, pid ${s.pid}` : ''}, ${s.restarts} restart(s)`)
  const key = loadKey()
  const v = key ? await sendControl({ path: paths.control, key, command: 'status', timeoutMs: 4000 }).catch(() => null) : null
  say(v ? `Voice assistant:\n${v}` : 'Voice assistant: not running')
}

function doctor({ quiet = false } = {}) {
  const problems = []
  const major = Number(process.versions.node.split('.')[0])
  if (major < 20) problems.push(`Node ${process.version} is too old: Jarvis needs Node 20 or newer.`)
  for (const dep of ['ws', 'zod', '@anthropic-ai/claude-agent-sdk', 'kokoro-js']) {
    if (!existsSync(join(REPO, 'node_modules', ...dep.split('/')))) problems.push(`${dep} is not installed: run npm install in ${REPO}.`)
  }
  if (OS !== 'macos') {
    if (!sherpaAvailable()) problems.push(`sherpa-onnx has no build installed for ${process.platform}-${process.arch}: run npm install.`)
    if (!modelStatus().all) problems.push('The speech models are not downloaded: run jarvis setup.')
    if (OS === 'windows' && !existsSync(join(REPO, 'node_modules', '@picovoice', 'pvrecorder-node'))) problems.push('The microphone module is not installed: run npm install.')
  }
  if (!existsSync(join(paths.home, '.claude')) && !existsSync(join(paths.home, '.claude.json')) && !process.env.ANTHROPIC_API_KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
    problems.push('Claude Code has not been signed in on this account yet: run `claude` once and log in (Jarvis reuses that sign-in).')
  }
  const report = detectCapabilities()
  if (!quiet) {
    say(`Jarvis ${PKG.version} on ${report.os} ${report.arch} (${report.release}), Node ${process.version}${report.session ? `, ${report.session.type} session${report.session.desktop ? ` (${report.session.desktop})` : ''}` : ''}`)
    say(`Folders: settings ${paths.support}\n         logs ${paths.logs}\n         cache ${paths.cache}`)
    say('\nWhat this computer can do:')
    for (const line of describeCapabilities(report)) say(`  ${line}`)
    say(problems.length ? `\nTo fix:\n${problems.map((p) => `  - ${p}`).join('\n')}` : '\nEverything Jarvis needs is in place.')
  }
  return problems
}

// ---------------------------------------------------------------------------

switch (command) {
  case 'setup': {
    ensureKey()
    say(`Per-install key: ${paths.key}`)
    if (OS !== 'macos') {
      try {
        await ensureModels({ log: say })
        say('Speech models ready.')
      } catch (err) {
        fail(`speech models: ${err.message}`)
      }
    }
    doctor()
    say('\nNext: jarvis install   (starts Jarvis now and at every login)')
    break
  }
  case 'models':
    await ensureModels({ log: say })
    say(JSON.stringify(modelStatus(), null, 2))
    break
  case 'install':
    if (doctor({ quiet: true }).some((p) => /not installed|too old|no build/.test(p))) fail('fix the problems `jarvis doctor` lists first')
    await install()
    break
  case 'uninstall':
    await uninstall()
    break
  case 'start':
    await start()
    break
  case 'stop':
    await stop()
    break
  case 'restart':
    await stop()
    await new Promise((r) => setTimeout(r, 2500))
    await start()
    break
  case 'status':
    await status()
    break
  case 'doctor':
    process.exit(doctor().length ? 1 : 0)
    break
  case 'capabilities': {
    const report = detectCapabilities()
    say(rest.includes('--json') ? JSON.stringify(report, null, 2) : describeCapabilities(report).join('\n'))
    break
  }
  case 'logs': {
    const name = rest[0] ?? 'voice'
    const file = join(paths.logs, `${name}.log`)
    if (!existsSync(file)) fail(`no log ${file}`)
    say(readFileSync(file, 'utf8').split('\n').slice(-80).join('\n'))
    break
  }
  case 'ask': case 'answer': case 'say':
    if (!argument) fail(`${command} needs some text`)
    say(await voice(`${command} ${argument}`))
    break
  case 'hear':
    say(await voice(`hear ${resolve(argument)}`))
    break
  case 'tasks': case 'cancel': case 'mute': case 'unmute': case 'toggle': case 'permissions': case 'devices': case 'reload': case 'quit': case 'ping':
    say(await voice(argument ? `${command} ${argument}` : command))
    break
  case 'version': case '--version': case '-v':
    say(PKG.version)
    break
  default:
    say(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].replace(/^#!.*\n\/\*\*\n/, '').replace(/^ \* ?/gm, ''))
}
