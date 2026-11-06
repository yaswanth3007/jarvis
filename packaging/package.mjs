#!/usr/bin/env node
/**
 * Builds the release artifacts for the computer it runs on (CI runs it on each OS and
 * architecture, so every package carries the right native binaries):
 *
 *   macOS    jarvis-<v>-macos-<arch>.tar.gz           (then: macos/jarvisctl install)
 *   Windows  jarvis-<v>-windows-<arch>.zip            and, with NSIS, jarvis-<v>-windows-<arch>-setup.exe
 *   Linux    jarvis-<v>-linux-<arch>.tar.gz           and, with dpkg-deb, jarvis_<v>_<amd64|arm64>.deb
 *
 * Packages contain the app, the built face (dist/) and only the runtime dependencies this
 * platform uses — nothing needed only to build the face, no dev tools, no other platform's
 * binaries. Node.js (20 or newer) is a prerequisite, not bundled. The speech models are
 * downloaded and verified by `jarvis setup` on first run. SHA256SUMS lists every artifact.
 *
 *   node packaging/package.mjs [--skip-build] [--out <dir>]
 */
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { arch } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { systemTar } from '../core/models.mjs'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2)
const OUT = resolve(args.includes('--out') ? args[args.indexOf('--out') + 1] : join(REPO, 'out'))
const PKG = JSON.parse(readFileSync(join(REPO, 'package.json'), 'utf8'))
const OS = { darwin: 'macos', win32: 'windows', linux: 'linux' }[process.platform]
if (!OS) throw new Error(`unsupported platform ${process.platform}`)
const ARCH = arch()
const NAME = `jarvis-${PKG.version}-${OS}-${ARCH}`
const STAGE = join(OUT, NAME)
const say = (m) => console.log(`[package] ${m}`)
const sh = (cmd, a, opts = {}) => {
  const r = spawnSync(cmd, a, { stdio: 'inherit', shell: process.platform === 'win32' && /^(npm|npx)$/.test(cmd), ...opts })
  if (r.status !== 0) throw new Error(`${cmd} ${a.join(' ')} failed (${r.status ?? r.error?.message})`)
}

// 1. The face, built once into dist/ (Vite is not shipped).
if (!args.includes('--skip-build') || !existsSync(join(REPO, 'dist', 'index.html'))) {
  const wasm = join(REPO, 'node_modules', '@mediapipe', 'tasks-vision', 'wasm')
  if (existsSync(wasm)) cpSync(wasm, join(REPO, 'public', 'mediapipe'), { recursive: true })
  say('building the face (npm run build)')
  sh('npm', ['run', 'build'], { cwd: REPO })
}

// 2. Stage the files this platform needs.
rmSync(STAGE, { recursive: true, force: true })
mkdirSync(STAGE, { recursive: true })
const common = ['bin', 'bridge', 'core', 'dist', 'docs', 'scripts', 'package.json', 'package-lock.json', 'LICENSE', 'README.md', '.env.example']
const perOS = { macos: ['macos'], windows: ['client'], linux: ['client'] }[OS]
for (const item of [...common, ...perOS]) {
  const from = join(REPO, item)
  if (!existsSync(from)) continue
  cpSync(from, join(STAGE, item), {
    recursive: true,
    filter: (src) => !/[\\/](build|Tests|\.DS_Store)$/.test(src) && !src.endsWith('.log'),
  })
}

// 3. Runtime dependencies only: the closure of what bridge/, core/ and client/ import.
const ROOTS = ['@anthropic-ai/claude-agent-sdk', 'zod', 'ws', 'kokoro-js', ...(OS === 'macos' ? [] : ['sherpa-onnx-node']), ...(OS === 'windows' ? ['@picovoice/pvrecorder-node'] : [])]
const NM = join(REPO, 'node_modules')
const keep = new Set()
function resolvePkg(name, fromDir) {
  let dir = fromDir
  for (;;) {
    const candidate = join(dir, 'node_modules', ...name.split('/'))
    if (existsSync(join(candidate, 'package.json'))) return candidate
    if (dir === REPO || dirname(dir) === dir) return null
    dir = dirname(dir)
    if (basename(dir) === 'node_modules') dir = dirname(dir)
  }
}
function visit(dir) {
  if (!dir || keep.has(dir)) return
  keep.add(dir)
  const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
  for (const dep of Object.keys({ ...pkg.dependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies })) {
    visit(resolvePkg(dep, dir))
  }
}
for (const root of ROOTS) {
  const dir = resolvePkg(root, REPO)
  if (!dir) throw new Error(`${root} is not installed — run npm ci first`)
  visit(dir)
}
let bytes = 0
for (const dir of keep) {
  const rel = dir.slice(NM.length + 1)
  const to = join(STAGE, 'node_modules', rel)
  cpSync(dir, to, { recursive: true, filter: (src) => src === dir || !src.slice(dir.length).includes(`${process.platform === 'win32' ? '\\' : '/'}node_modules`) })
}
// 3b. Inside those packages, drop what this platform never loads (checked, not guessed):
//   - onnxruntime-node ships every OS's binary; only bin/napi-v*/<this os>/<this arch> is loaded;
//   - onnxruntime-web and transformers' .wasm are the browser runtime — the Node build of
//     @huggingface/transformers imports onnxruntime-node instead (asserted below);
//   - source maps.
const SM = join(STAGE, 'node_modules')
const ortBin = join(SM, 'onnxruntime-node', 'bin')
if (existsSync(ortBin)) {
  for (const napi of readdirSync(ortBin)) {
    for (const plat of readdirSync(join(ortBin, napi))) {
      if (plat !== process.platform) rmSync(join(ortBin, napi, plat), { recursive: true, force: true })
      else for (const a of readdirSync(join(ortBin, napi, plat))) if (a !== process.arch) rmSync(join(ortBin, napi, plat, a), { recursive: true, force: true })
    }
  }
}
const tfDist = join(SM, '@huggingface', 'transformers', 'dist')
if (existsSync(tfDist)) {
  const nodeBuild = readFileSync(join(tfDist, 'transformers.node.mjs'), 'utf8')
  if (/["']onnxruntime-web["']/.test(nodeBuild)) throw new Error('transformers.node.mjs imports onnxruntime-web — keep it')
  rmSync(join(SM, 'onnxruntime-web'), { recursive: true, force: true })
  for (const f of readdirSync(tfDist)) if (/\.wasm$|jsep\.mjs$/.test(f)) rmSync(join(tfDist, f), { force: true })
}
const dropMaps = (dir) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, e.name)
    if (e.isDirectory()) dropMaps(full)
    else if (e.name.endsWith('.map')) rmSync(full, { force: true })
  }
}
dropMaps(SM)
const du = (p) => {
  const s = statSync(p)
  if (!s.isDirectory()) return s.size
  return readdirSync(p).reduce((n, e) => n + du(join(p, e)), 0)
}
bytes = du(join(STAGE, 'node_modules'))
say(`${keep.size} runtime packages (${(bytes / 1e6).toFixed(0)} MB) for ${OS}-${ARCH}`)
writeFileSync(join(STAGE, 'BUILD-INFO.json'), `${JSON.stringify({ name: PKG.name, version: PKG.version, os: OS, arch: ARCH, node: process.version, built: new Date().toISOString(), packages: [...keep].map((d) => d.slice(NM.length + 1)).sort() }, null, 2)}\n`)

// 4. Platform wrappers.
if (OS === 'windows') {
  writeFileSync(join(STAGE, 'jarvis.cmd'), '@echo off\r\nnode "%~dp0bin\\jarvis.mjs" %*\r\n')
}
if (OS !== 'windows') chmodSync(join(STAGE, 'bin', 'jarvis.mjs'), 0o755)

// 5. Archives and installers.
const artifacts = []
mkdirSync(OUT, { recursive: true })
if (OS === 'windows') {
  const zip = join(OUT, `${NAME}.zip`)
  rmSync(zip, { force: true })
  sh(systemTar(), ['-a', '-c', '-f', zip, '-C', OUT, NAME])
  artifacts.push(zip)
  const makensis = ['makensis', 'C:\\Program Files (x86)\\NSIS\\makensis.exe', 'C:\\Program Files\\NSIS\\makensis.exe'].find((m) => spawnSync(m, ['/VERSION'], { stdio: 'ignore' }).status === 0)
  if (makensis) {
    const exe = join(OUT, `${NAME}-setup.exe`)
    sh(makensis, ['/V2', `/DVERSION=${PKG.version}`, `/DARCH=${ARCH}`, `/DSTAGE=${STAGE}`, `/DOUTFILE=${exe}`, join(REPO, 'packaging', 'windows', 'jarvis.nsi')])
    artifacts.push(exe)
  } else say('NSIS (makensis) not found — skipping the setup .exe')
} else {
  const tgz = join(OUT, `${NAME}.tar.gz`)
  sh('tar', ['-czf', tgz, '-C', OUT, NAME])
  artifacts.push(tgz)
}
if (OS === 'linux' && spawnSync('dpkg-deb', ['--version'], { stdio: 'ignore' }).status === 0) {
  const debArch = { x64: 'amd64', arm64: 'arm64' }[ARCH] ?? ARCH
  const root = join(OUT, `deb-${debArch}`)
  rmSync(root, { recursive: true, force: true })
  mkdirSync(join(root, 'DEBIAN'), { recursive: true })
  mkdirSync(join(root, 'opt'), { recursive: true })
  mkdirSync(join(root, 'usr', 'bin'), { recursive: true })
  mkdirSync(join(root, 'usr', 'share', 'applications'), { recursive: true })
  cpSync(STAGE, join(root, 'opt', 'jarvis'), { recursive: true })
  cpSync(join(REPO, 'packaging', 'linux', 'jarvis'), join(root, 'usr', 'bin', 'jarvis'))
  chmodSync(join(root, 'usr', 'bin', 'jarvis'), 0o755)
  cpSync(join(REPO, 'packaging', 'linux', 'jarvis-setup.desktop'), join(root, 'usr', 'share', 'applications', 'jarvis-setup.desktop'))
  const size = Math.ceil(du(join(root, 'opt')) / 1024)
  writeFileSync(join(root, 'DEBIAN', 'control'), `Package: jarvis
Version: ${PKG.version}
Section: utils
Priority: optional
Architecture: ${debArch}
Installed-Size: ${size}
Maintainer: JARVIS contributors <noreply@users.noreply.github.com>
Recommends: python3-gi, gir1.2-atspi-2.0, pulseaudio-utils | pipewire-bin | alsa-utils, wmctrl, xdotool, bzip2, xdg-utils, espeak-ng
Suggests: gir1.2-ayatanaappindicator3-0.1, gnome-screenshot | scrot | grim, ffmpeg
Description: Always-on "Hey Jarvis" voice assistant driven by Claude Code
 Wake word, speech recognition and Claude integration, with explicit
 permission control. Needs Node.js 20 or newer and a Claude Code sign-in.
 After installing, run as your own user: jarvis setup && jarvis install
`)
  writeFileSync(join(root, 'DEBIAN', 'postinst'), '#!/bin/sh\nset -e\necho "Jarvis is installed in /opt/jarvis. As your own user (not root), run: jarvis setup && jarvis install"\nexit 0\n')
  writeFileSync(join(root, 'DEBIAN', 'prerm'), '#!/bin/sh\nset -e\necho "Jarvis: before removing, each user who installed it can run \\"jarvis uninstall\\" to remove their login services."\nexit 0\n')
  chmodSync(join(root, 'DEBIAN', 'postinst'), 0o755)
  chmodSync(join(root, 'DEBIAN', 'prerm'), 0o755)
  const deb = join(OUT, `jarvis_${PKG.version}_${debArch}.deb`)
  sh('dpkg-deb', ['--root-owner-group', '--build', root, deb])
  rmSync(root, { recursive: true, force: true })
  artifacts.push(deb)
}

// 6. Checksums.
const sums = artifacts.map((f) => `${createHash('sha256').update(readFileSync(f)).digest('hex')}  ${basename(f)}`)
writeFileSync(join(OUT, `SHA256SUMS-${OS}-${ARCH}.txt`), `${sums.join('\n')}\n`)
for (const f of artifacts) say(`${basename(f)}  ${(statSync(f).size / 1e6).toFixed(1)} MB`)
