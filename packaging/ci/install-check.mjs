#!/usr/bin/env node
/**
 * CI only: installs Jarvis the way a user would on this runner (launchd / Run entry /
 * systemd --user), checks that the agent brings up the bridge and that the voice assistant
 * answers, then uninstalls and checks the login entries are gone. Uses the runner's real
 * per-user folders — never run this on your own computer (it would replace your install).
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { paths } from '../../core/paths.mjs'

if (!process.env.CI) {
  console.error('install-check: CI only (it installs into this account). Set CI=1 to force.')
  process.exit(64)
}
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const OS = paths.os
const jarvis = (...args) => {
  const cmd = OS === 'macos' ? [join(REPO, 'macos', 'jarvisctl'), args] : [process.execPath, [join(REPO, 'bin', 'jarvis.mjs'), ...args]]
  const r = spawnSync(cmd[0], cmd[1], { encoding: 'utf8', cwd: REPO })
  console.log(`$ jarvis ${args.join(' ')}\n${r.stdout}${r.stderr}`)
  return r
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let failed = false
const check = (ok, what) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}`)
  if (!ok) failed = true
}

const installed = jarvis('install')
check(installed.status === 0, 'install succeeded')
let status = null
for (let i = 0; i < 90; i++) {
  await sleep(2000)
  try {
    status = JSON.parse(readFileSync(paths.agentStatus, 'utf8'))
    if (status.services?.bridge?.mode === 'running') break
  } catch {
    /* not yet */
  }
}
check(status?.services?.bridge?.mode === 'running', `the agent started at login brings up the bridge (${JSON.stringify(status?.services ?? {})})`)
if (OS === 'macos') {
  const s = jarvis('status')
  check(/local\.jarvis\.voice\s+running/.test(s.stdout), 'Jarvis Voice (the menu bar app) is running under launchd')
} else {
  let pong = null
  for (let i = 0; i < 45 && pong !== 'pong'; i++) {
    await sleep(2000)
    pong = jarvis('ping').stdout.trim()
  }
  check(pong === 'pong', 'the voice assistant answers on its control channel')
  jarvis('status')
}
const removed = jarvis('uninstall')
check(removed.status === 0, 'uninstall succeeded')
await sleep(3000)
if (OS === 'macos') {
  check(!existsSync(join(paths.home, 'Library', 'LaunchAgents', 'local.jarvis.agent.plist')), 'LaunchAgents removed')
} else if (OS === 'windows') {
  const q = spawnSync('reg', ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', '/v', 'JarvisAgent'], { encoding: 'utf8' })
  check(q.status !== 0, 'the Run entries are removed')
} else {
  check(!existsSync(join(paths.home, '.config', 'systemd', 'user', 'jarvis-agent.service')), 'the systemd user units are removed')
  const active = spawnSync('systemctl', ['--user', 'is-active', 'jarvis-agent.service'], { encoding: 'utf8' }).stdout.trim()
  check(active !== 'active', `jarvis-agent.service is stopped (${active})`)
}
process.exit(failed ? 1 : 0)
