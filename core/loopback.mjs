/**
 * Preloaded into the bridge when the background agent runs it:
 *
 *   node --import core/loopback.mjs bridge/server.mjs
 *
 * bridge/server.mjs calls `server.listen(PORT)` with no host, which Node binds
 * to every interface — so on a café or office network the bridge (and every
 * MCP server behind it) is reachable from other machines, guarded only by an
 * Origin header that a non-browser client can simply set. For a process that
 * now runs all day, that is too much exposure.
 *
 * This keeps the bridge's own code untouched and only changes the default:
 * a listen() that names a port but no host is bound to 127.0.0.1. Anything
 * that passes an explicit host, or listens on a Unix socket path, is left
 * exactly as it was. The browser face still reaches ws://localhost:8787,
 * because browsers fall back from ::1 to 127.0.0.1 for localhost.
 *
 * Override with JARVIS_BIND_HOST if you genuinely need another address.
 */
import net from 'node:net'

const HOST = process.env.JARVIS_BIND_HOST || '127.0.0.1'
const listen = net.Server.prototype.listen

const isPort = (v) => typeof v === 'number' || (typeof v === 'string' && /^\d+$/.test(v))

net.Server.prototype.listen = function (...args) {
  const [first] = args
  if (isPort(first) && (args.length === 1 || typeof args[1] === 'function')) {
    args.splice(1, 0, HOST)
  } else if (
    first &&
    typeof first === 'object' &&
    !Array.isArray(first) &&
    first.port !== undefined &&
    first.host === undefined &&
    first.path === undefined
  ) {
    args[0] = { ...first, host: HOST }
  }
  return listen.apply(this, args)
}

console.log(`[jarvis-agent] network listeners default to ${HOST} (loopback only)`)
