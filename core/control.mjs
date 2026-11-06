/**
 * The voice assistant's local control channel on Windows and Linux — what `jarvis status`,
 * `jarvis ask`, `jarvis answer`, `jarvis tasks`… talk to (the macOS app has its own).
 *
 *   Windows  a named pipe, \\.\pipe\jarvis-voice-<user>
 *   Linux    a Unix socket in $XDG_RUNTIME_DIR/jarvis (0700), mode 0600
 *
 * Both ends prove they hold the per-install key before a command is accepted or sent, so
 * neither another account nor a process squatting the pipe name can drive Jarvis or read
 * what is typed to it:
 *
 *   → auth v1.<time>.<nonce>.<hmac>     ← ok <proof>
 *   → <command line>                    ← <reply>   (then the connection closes)
 */
import net from 'node:net'
import { chmodSync, existsSync, mkdirSync, rmSync } from 'node:fs'
import { dirname } from 'node:path'
import { clientSignature, proveIdentity, sameDigest, verifyClientSignature } from '../bridge/voice-auth.mjs'

const lineReader = (socket, onLine) => {
  let buf = ''
  socket.setEncoding('utf8')
  socket.on('data', (d) => {
    buf += d
    if (buf.length > 64 * 1024) socket.destroy()
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '')
      buf = buf.slice(nl + 1)
      onLine(line)
    }
  })
}

export function startControl({ path, key, handle, log = () => {} }) {
  if (!path.startsWith('\\\\.\\pipe\\')) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
    try {
      chmodSync(dirname(path), 0o700)
    } catch {
      /* not ours */
    }
    if (existsSync(path)) rmSync(path, { force: true })
  }
  const server = net.createServer((socket) => {
    let authed = false
    const timer = setTimeout(() => socket.destroy(), 10_000)
    lineReader(socket, async (line) => {
      if (!authed) {
        const nonce = line.startsWith('auth ') ? verifyClientSignature(key, line.slice(5).trim()) : null
        if (!nonce) {
          socket.end('error: unauthorized\n')
          return
        }
        authed = true
        socket.write(`ok ${proveIdentity(key, 'jarvis-voice-control', nonce)}\n`)
        return
      }
      clearTimeout(timer)
      let reply
      try {
        reply = await handle(line)
      } catch (err) {
        reply = `error: ${err?.message ?? err}`
      }
      socket.end(`${reply}\n`)
    })
    socket.on('error', () => {})
  })
  server.on('error', (err) => log(`control channel unavailable: ${err.message}`))
  server.listen(path, () => {
    if (!path.startsWith('\\\\.\\pipe\\')) {
      try {
        chmodSync(path, 0o600)
      } catch {
        /* best effort */
      }
    }
    log(`control channel ready (${path.startsWith('\\\\.\\pipe\\') ? 'named pipe' : 'socket'})`)
  })
  return server
}

/** For the CLI: sends one command and returns the reply (after checking the assistant's proof). */
export function sendControl({ path, key, command, timeoutMs = 20_000 }) {
  return new Promise((resolve, reject) => {
    const { header, nonce } = clientSignature(key)
    const socket = net.connect(path)
    let stage = 'auth'
    let reply = ''
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error('the voice assistant did not answer in time'))
    }, timeoutMs)
    socket.on('connect', () => socket.write(`auth ${header}\n`))
    socket.setEncoding('utf8')
    let buf = ''
    socket.on('data', (d) => {
      if (stage === 'reply') {
        reply += d
        return
      }
      buf += d
      const nl = buf.indexOf('\n')
      if (nl < 0) return
      const first = buf.slice(0, nl)
      const proof = /^ok ([0-9a-f]{64})$/.exec(first)?.[1]
      if (!proof || !sameDigest(proof, proveIdentity(key, 'jarvis-voice-control', nonce))) {
        socket.destroy()
        clearTimeout(timer)
        reject(new Error(first.startsWith('error') ? first : 'whatever answered cannot prove it is this user\'s Jarvis — nothing was sent'))
        return
      }
      stage = 'reply'
      reply = buf.slice(nl + 1)
      socket.write(`${command}\n`)
    })
    socket.on('end', () => {
      clearTimeout(timer)
      if (stage === 'reply') resolve(reply.replace(/\n$/, ''))
    })
    socket.on('error', (err) => {
      clearTimeout(timer)
      reject(err.code === 'ENOENT' || err.code === 'ECONNREFUSED' ? new Error('the voice assistant is not running') : err)
    })
  })
}
