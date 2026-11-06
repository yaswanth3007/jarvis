/**
 * Proof between Jarvis Voice (the voice assistant on macOS, Windows or Linux) and its own
 * bridge and voice engine.
 *
 * The bridge (127.0.0.1:8787) and the voice engine (127.0.0.1:8790) listen on loopback,
 * which every account on this computer — and any app allowed to open network connections —
 * can reach, and any of them could also bind those ports while the real service is down.
 * A per-install secret that only this user can read (bridge.key in Jarvis's support folder,
 * see core/paths.mjs: mode 0600 in a 0700 folder on macOS and Linux; on Windows the
 * per-user %LOCALAPPDATA% folder, which other accounts cannot read) lets each side prove it
 * is the real one without ever sending the secret:
 *
 *   - Jarvis Voice signs each connection: HMAC(key, "jarvis-voice-client|v1|<time>|<nonce>").
 *     The bridge accepts a signature once, and only within two minutes of <time>. Only a
 *     signed connection gets the Mac tools and write access.
 *   - The bridge and the voice engine answer a nonce with HMAC(key, "<who>|v1|<nonce>"), so
 *     Jarvis Voice never acts on requests from, or speaks text to, an impostor on the port.
 */
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, writeSync } from 'node:fs'
import { dirname } from 'node:path'
import { paths } from '../core/paths.mjs'

// JARVIS_VOICE_KEY_FILE (absolute) still overrides it, for tests against a scratch bridge.
export const KEY_FILE = paths.key

const KEY_HEX = /^[0-9a-f]{64}$/
const NONCE = /^[0-9a-f]{32}$/
const MAC = /^[0-9a-f]{64}$/

/** Creates the key (and locks its folder down) if it doesn't exist yet. */
export function ensureKey() {
  const dir = dirname(KEY_FILE)
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  try {
    chmodSync(dir, 0o700)
  } catch {
    /* not ours to change (a custom location) */
  }
  if (!existsSync(KEY_FILE)) {
    try {
      const fd = openSync(KEY_FILE, 'wx', 0o600)
      writeSync(fd, `${randomBytes(32).toString('hex')}\n`)
      closeSync(fd)
    } catch (err) {
      if (err?.code !== 'EEXIST') throw err
    }
  }
  try {
    chmodSync(KEY_FILE, 0o600)
  } catch {
    /* read below decides */
  }
  return loadKey()
}

/** The key, or null if it is missing or malformed. Never logged. */
export function loadKey() {
  try {
    const hex = readFileSync(KEY_FILE, 'utf8').trim()
    return KEY_HEX.test(hex) ? Buffer.from(hex, 'hex') : null
  } catch {
    return null
  }
}

export const sign = (key, ...parts) => createHmac('sha256', key).update(parts.join('|')).digest('hex')

/** Constant-time comparison of two hex digests. */
export function sameDigest(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || !MAC.test(a) || !MAC.test(b)) return false
  return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'))
}

const seen = new Map() // nonce → when it may be forgotten

/**
 * Checks Jarvis Voice's signature on a connection ("v1.<unix seconds>.<nonce>.<hmac>").
 * Returns the nonce if it is valid and fresh, otherwise null.
 */
export function verifyClientSignature(key, header, now = Date.now()) {
  if (!key || typeof header !== 'string') return null
  const [version, time, nonce, mac, extra] = header.trim().split('.')
  if (version !== 'v1' || extra !== undefined || !/^\d{9,11}$/.test(time ?? '') || !NONCE.test(nonce ?? '')) return null
  if (Math.abs(now / 1000 - Number(time)) > 120) return null
  for (const [n, until] of seen) if (until < now) seen.delete(n)
  if (seen.has(nonce)) return null
  if (!sameDigest(mac, sign(key, 'jarvis-voice-client', 'v1', time, nonce))) return null
  seen.set(nonce, now + 5 * 60_000)
  return nonce
}

/** The answer that proves a service holds the key: "jarvis-bridge", "jarvis-voice-engine"… */
export function proveIdentity(key, who, nonce) {
  if (!key || !NONCE.test(String(nonce ?? ''))) return null
  return sign(key, who, 'v1', nonce)
}

/** For the supervisor: a fresh nonce to challenge a listener with. */
export const freshNonce = () => randomBytes(16).toString('hex')

/**
 * For the Windows/Linux voice assistant and the `jarvis` CLI: the signature a client sends
 * ("v1.<unix seconds>.<nonce>.<hmac>"), the same one Jarvis Voice on macOS sends.
 */
export function clientSignature(key, now = Date.now()) {
  const time = String(Math.floor(now / 1000))
  const nonce = freshNonce()
  return { header: `v1.${time}.${nonce}.${sign(key, 'jarvis-voice-client', 'v1', time, nonce)}`, nonce }
}
