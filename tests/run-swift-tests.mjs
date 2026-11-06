#!/usr/bin/env node
/**
 * Compiles and runs the macOS app's unit tests (macos/Tests/main.swift) together with the
 * real sources they test — the orchestrator and the voice-command parsers — against the
 * same vectors the JavaScript tests use. macOS only (they use Apple frameworks).
 */
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

if (process.platform !== 'darwin') {
  console.log('Swift tests: macOS only — skipped on this platform.')
  process.exit(0)
}
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(REPO, 'macos', 'JarvisVoice')
const dir = mkdtempSync(join(tmpdir(), 'jarvis-swift-tests-'))
const bin = join(dir, 'tests')
const sources = ['Tasks.swift', 'TaskCommands.swift', 'Permissions.swift', 'Support.swift'].map((f) => join(SRC, f))
// The same language mode and deployment target the app itself is built with (macos/jarvisctl).
const arch = process.env.JARVIS_SWIFT_ARCH ?? (process.arch === 'arm64' ? 'arm64' : 'x86_64')
const compile = spawnSync('swiftc', ['-swift-version', '5', '-O', '-target', `${arch}-apple-macos26.0`, '-o', bin, join(REPO, 'macos', 'Tests', 'main.swift'), ...sources], { stdio: 'inherit' })
if (compile.status !== 0) {
  rmSync(dir, { recursive: true, force: true })
  process.exit(compile.status ?? 1)
}
// The tests' log lines go to a scratch folder, never the real voice.log.
const r = spawnSync(bin, [join(REPO, 'tests', 'vectors', 'commands.json')], { stdio: 'inherit', env: { ...process.env, JARVIS_LOG_DIR: dir } })
rmSync(dir, { recursive: true, force: true })
process.exit(r.status ?? 1)
