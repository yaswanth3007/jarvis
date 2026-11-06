/** Test helpers: a scratch Jarvis home, so no test ever touches the real settings, key or logs. */
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'

export function scratchHome(name = 'jarvis-test') {
  const dir = mkdtempSync(join(tmpdir(), `${name}-`))
  process.env.JARVIS_HOME = join(dir, 'support')
  process.env.JARVIS_LOG_DIR = join(dir, 'logs')
  process.env.JARVIS_VOICE_KEY_FILE = join(dir, 'support', 'bridge.key')
  process.env.JARVIS_PERMISSIONS_FILE = join(dir, 'support', 'permissions.json')
  process.env.JARVIS_PERMISSION_HISTORY = join(dir, 'support', 'permission-history.jsonl')
  // Speech models given for the tests (".../models") are found through the normal cache path, so
  // the voice assistant started by a test loads them like an installed one would.
  const models = process.env.JARVIS_TEST_MODELS
  process.env.JARVIS_CACHE_DIR = models && basename(models) === 'models' ? dirname(models) : join(dir, 'cache')
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) }
}

export const REPO = new URL('..', import.meta.url)
