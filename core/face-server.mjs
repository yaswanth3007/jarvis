#!/usr/bin/env node
/**
 * Serves the built JARVIS face (dist/, from `npm run build`) on localhost, for
 * installed packages that do not ship Vite. A development checkout keeps using
 * Vite exactly as before (see core/supervisor.mjs).
 *
 * Local only: bound to 127.0.0.1, GET/HEAD only, nothing outside dist/ is ever
 * served, and there is no directory listing.
 */
import http from 'node:http'
import { createReadStream, existsSync, statSync } from 'node:fs'
import { dirname, extname, join, normalize, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'dist')
const PORT = Number(process.env.PORT ?? 5173)
const HOST = process.env.JARVIS_BIND_HOST || '127.0.0.1'
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.ico': 'image/x-icon', '.wasm': 'application/wasm', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
  '.ogg': 'audio/ogg', '.woff2': 'font/woff2', '.task': 'application/octet-stream', '.data': 'application/octet-stream',
  '.tflite': 'application/octet-stream', '.txt': 'text/plain; charset=utf-8',
}

if (!existsSync(join(ROOT, 'index.html'))) {
  console.error(`[face] no built face at ${ROOT} — run npm run build`)
  process.exit(1)
}

http
  .createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { allow: 'GET, HEAD' }).end()
      return
    }
    let pathname
    try {
      pathname = decodeURIComponent(new URL(req.url ?? '/', 'http://localhost').pathname)
    } catch {
      res.writeHead(400).end()
      return
    }
    let file = resolve(ROOT, `.${sep}${normalize(pathname)}`)
    if (file !== ROOT && !file.startsWith(ROOT + sep)) {
      res.writeHead(403).end()
      return
    }
    let info = null
    try {
      info = statSync(file)
    } catch {
      /* not found */
    }
    if (!info || info.isDirectory()) {
      // The face is a single-page app: unknown paths get index.html.
      const index = info?.isDirectory() ? join(file, 'index.html') : null
      file = index && existsSync(index) ? index : join(ROOT, 'index.html')
      info = statSync(file)
    }
    res.writeHead(200, {
      'content-type': TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream',
      'content-length': info.size,
      'x-content-type-options': 'nosniff',
      'cache-control': file.endsWith('index.html') ? 'no-cache' : 'max-age=3600',
    })
    if (req.method === 'HEAD') res.end()
    else createReadStream(file).pipe(res)
  })
  .listen(PORT, HOST, () => console.log(`[face] serving ${ROOT} on http://localhost:${PORT}`))
