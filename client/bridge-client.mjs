/**
 * One signed connection to the user's own bridge — the Windows/Linux counterpart of
 * BridgeConnection in macos/JarvisVoice/Bridge.swift, with the same rules:
 *
 *   - the connection is signed with the per-install key (bridge/voice-auth.mjs);
 *   - nothing from the other end is acted on until its first `ready` proves it holds
 *     the same key — an impostor on port 8787 is dropped at once;
 *   - one connection is one Claude session (one task).
 *
 *   → {"type":"ask","id","text","request","context"}   ← {"type":"text","delta","ask"} …
 *   → {"type":"interrupt"}                              ← {"type":"done","text","ask"} | {"type":"error","message"}
 *   ← {"type":"confirm"|"desktop"|"capture","id",…}    → {"type":"reply","id",…}
 */
import { EventEmitter } from 'node:events'
import WebSocket from 'ws'
import { clientSignature, proveIdentity, sameDigest } from '../bridge/voice-auth.mjs'

export class BridgeConnection extends EventEmitter {
  /**
   * @param {{url: string, key: Buffer, os: 'windows'|'linux', caps: {available: string[], missing: Record<string,string>}, log?: Function}} o
   */
  constructor({ url, key, os, caps, origin = 'http://localhost:5173', log = () => {} }) {
    super()
    this.url = url
    // The bridge only accepts its own face's origin; Jarvis Voice on macOS sends the same.
    this.origin = origin
    this.key = key
    this.os = os
    this.caps = caps
    this.log = log
    this.ws = null
    this.nonce = null
    this.authenticated = false
    this.closed = false
    this.asks = 0
  }

  /** Opens and waits until the bridge has proved itself (or fails). */
  open(timeoutMs = 15_000) {
    if (!this.key) return Promise.reject(new Error('no per-install key yet (start the Jarvis agent first)'))
    const { header, nonce } = clientSignature(this.key)
    this.nonce = nonce
    const caps = Buffer.from(JSON.stringify(this.caps ?? {})).toString('base64url')
    const target = new URL(this.url)
    target.searchParams.set('client', `jarvis-voice-${this.os}`)
    target.searchParams.set('caps', caps)
    return new Promise((resolve, reject) => {
      let settled = false
      const fail = (err) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        reject(err)
      }
      const timer = setTimeout(() => {
        fail(new Error('the bridge did not prove itself in time'))
        this.close()
      }, timeoutMs)
      const ws = new WebSocket(target, { origin: this.origin, headers: { 'x-jarvis-voice-auth': header }, perMessageDeflate: false })
      this.ws = ws
      ws.on('message', (raw) => {
        let msg
        try {
          msg = JSON.parse(raw.toString())
        } catch {
          return
        }
        if (!this.authenticated) {
          // Only a ready with the right proof counts; anything else ends the connection.
          if (msg?.type === 'ready' && sameDigest(msg.proof, proveIdentity(this.key, 'jarvis-bridge', this.nonce))) {
            this.authenticated = true
            settled = true
            clearTimeout(timer)
            resolve(this)
            return
          }
          this.log('refused: not this computer\'s bridge')
          ws.close(1008, 'policy')
          fail(new Error('refused: not this computer\'s bridge'))
          return
        }
        this.dispatch(msg)
      })
      ws.on('error', (err) => fail(err))
      ws.on('close', () => {
        this.closed = true
        fail(new Error('the bridge closed the connection'))
        this.emit('close')
      })
    })
  }

  dispatch(msg) {
    switch (msg.type) {
      case 'text':
        this.emit('text', msg.delta ?? '', msg.ask ?? null)
        break
      case 'done':
        this.emit('done', msg.text ?? '', msg.ask ?? null)
        break
      case 'error':
        this.emit('failed', String(msg.message ?? 'error'))
        break
      case 'tool':
        this.emit('tool', msg.name ?? '')
        break
      case 'ready':
      case 'panel':
      case 'blade':
      case 'ui':
        break
      default:
        if (typeof msg.id === 'string' && typeof msg.type === 'string') this.emit('request', msg.type, msg.id, msg)
    }
  }

  send(obj) {
    if (this.ws?.readyState === WebSocket.OPEN && this.authenticated) this.ws.send(JSON.stringify(obj))
  }

  /** The user's own words and the computer's context travel separately (see server.mjs). */
  ask(request, context = '') {
    const id = `a${++this.asks}`
    this.send({ type: 'ask', id, text: context ? `[PC: ${context}]\n${request}` : request, request, context })
    return id
  }

  interrupt() {
    this.send({ type: 'interrupt' })
  }

  reply(id, payload) {
    this.send({ type: 'reply', id, ...payload })
  }

  close() {
    this.closed = true
    try {
      this.ws?.close()
    } catch {
      /* already closed */
    }
  }
}
