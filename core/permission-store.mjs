/**
 * Jarvis's own permissions (Ask / Allow / Revoke), for the Windows and Linux voice
 * assistant — the same permissions.json format Jarvis Voice writes on macOS
 * (PermissionStore in macos/JarvisVoice/Permissions.swift) and the bridge's broker
 * reads fresh on every decision (bridge/permissions.mjs).
 *
 * Only the voice assistant writes it, and only from the user's own spoken (or typed
 * `jarvis answer`) decisions. A damaged file is never read as "allow".
 */
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { paths } from './paths.mjs'

/** What applies when you have not decided (mirrors bridge/permissions.mjs and the Mac app). */
export const DEFAULTS = {
  web: 'allow', 'apps.open': 'allow', 'apps.close': 'allow', app: 'ask', camera: 'ask',
  screen: 'ask', 'files.read': 'ask', 'files.write': 'ask', shell: 'ask', integration: 'ask',
}

const empty = () => ({ capabilities: {}, apps: {}, folders: [], integrations: {} })

export function loadPermissions(file = paths.permissions) {
  try {
    if (!existsSync(file)) return empty()
    const raw = JSON.parse(readFileSync(file, 'utf8'))
    return {
      capabilities: raw.capabilities ?? {},
      apps: raw.apps ?? {},
      folders: Array.isArray(raw.folders) ? raw.folders : [],
      integrations: raw.integrations ?? {},
    }
  } catch {
    return { ...empty(), damaged: true }
  }
}

const sortKeys = (v) => (v && typeof v === 'object' && !Array.isArray(v)
  ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]))
  : Array.isArray(v) ? v.map(sortKeys) : v)

export function savePermissions(store, file = paths.permissions) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 })
  const { damaged: _ignored, ...clean } = store
  const tmp = `${file}.${process.pid}.tmp`
  writeFileSync(tmp, `${JSON.stringify(sortKeys(clean), null, 2)}\n`, { mode: 0o600 })
  renameSync(tmp, file)
  try {
    chmodSync(file, 0o600)
  } catch {
    /* Windows: the per-user folder's own access rules apply */
  }
}

export const permissionValue = (store, capability) => store.capabilities[capability] ?? DEFAULTS[capability] ?? 'ask'

/** Applies a remembered decision ("allow always", "never", "revoke camera access"). */
export function remember(store, capability, target, allow) {
  const v = allow ? 'allow' : 'deny'
  switch (capability) {
    case 'app':
      if (target && target !== 'frontmost') store.apps[target] = v
      else store.capabilities.app = v
      break
    case 'files.read':
    case 'files.write': {
      const access = allow ? (capability === 'files.read' ? 'read' : 'allow') : 'deny'
      store.folders = store.folders.filter((f) => f.path !== target)
      store.folders.push({ path: target, access })
      break
    }
    case 'files':
      // "revoke file access" covers reading and changing; a folder gets one rule.
      if (target) {
        store.folders = store.folders.filter((f) => f.path !== target)
        store.folders.push({ path: target, access: allow ? 'allow' : 'deny' })
      } else {
        store.capabilities['files.read'] = v
        store.capabilities['files.write'] = v
      }
      break
    case 'apps':
      store.capabilities['apps.open'] = v
      store.capabilities['apps.close'] = v
      break
    case 'integration':
      store.integrations[target] = v
      break
    default:
      store.capabilities[capability] = v
  }
  return store
}

export function recordPermission(entry, file = paths.history) {
  try {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 })
    appendFileSync(file, `${JSON.stringify({ t: new Date().toISOString(), source: 'Jarvis Voice', ...entry })}\n`, { mode: 0o600 })
  } catch {
    /* history is best effort */
  }
}
