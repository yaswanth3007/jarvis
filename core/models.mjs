/**
 * The on-device speech models the Windows and Linux voice assistant uses.
 *
 * macOS does not need any of these: Jarvis Voice listens with Apple's own speech
 * recogniser. On Windows and Linux the same jobs are done on the CPU, offline,
 * by sherpa-onnx (Apache-2.0) with these open models, downloaded once from the
 * sherpa-onnx project's own GitHub releases and checked against the SHA-256
 * pinned below before anything is unpacked. Nothing is ever sent anywhere.
 *
 *   wake word        "Hey Jarvis"   zipformer keyword spotter (GigaSpeech, 3.3M params)
 *   voice activity   speech/silence Silero VAD
 *   speech-to-text   your request   Moonshine tiny English (quantized)
 */
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { createWriteStream, existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { paths } from './paths.mjs'

const RELEASES = 'https://github.com/k2-fsa/sherpa-onnx/releases/download'

export const MODELS = {
  kws: {
    title: 'wake word ("Hey Jarvis")',
    dir: 'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01',
    url: `${RELEASES}/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2`,
    sha256: 'f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a',
    bytes: 17626723,
    license: 'Apache-2.0',
    archive: true,
    // Only the quantized model is used; the rest of the archive is removed after unpacking.
    keep: ['encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx', 'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
      'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx', 'tokens.txt', 'README.md'],
  },
  vad: {
    title: 'voice activity detection',
    dir: 'silero-vad',
    file: 'silero_vad.onnx',
    url: `${RELEASES}/asr-models/silero_vad.onnx`,
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    bytes: 643854,
    license: 'MIT',
    archive: false,
  },
  asr: {
    title: 'speech recognition',
    dir: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27',
    url: `${RELEASES}/asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2`,
    sha256: '9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d',
    bytes: 29858559,
    license: 'MIT',
    archive: true,
    keep: ['encoder_model.ort', 'decoder_model_merged.ort', 'tokens.txt', 'LICENSE'],
  },
}

/**
 * "Hey Jarvis" and "Jarvis" as the keyword spotter's BPE tokens (from the model's own
 * bpe.model: "HEY JARVIS" → ▁HE Y ▁JA R VI S). ":boost #threshold @label".
 */
export const KEYWORDS = '▁HE Y ▁JA R VI S :2.5 #0.15 @HEY_JARVIS\n▁JA R VI S :2.0 #0.30 @JARVIS\n'

export function modelPaths(root = paths.models) {
  const kws = join(root, MODELS.kws.dir)
  const asr = join(root, MODELS.asr.dir)
  return {
    root,
    kws: {
      encoder: join(kws, MODELS.kws.keep[0]),
      decoder: join(kws, MODELS.kws.keep[1]),
      joiner: join(kws, MODELS.kws.keep[2]),
      tokens: join(kws, 'tokens.txt'),
      keywords: join(kws, 'jarvis-keywords.txt'),
    },
    vad: join(root, MODELS.vad.dir, MODELS.vad.file),
    asr: { encoder: join(asr, 'encoder_model.ort'), mergedDecoder: join(asr, 'decoder_model_merged.ort'), tokens: join(asr, 'tokens.txt') },
  }
}

/** Which models are present (and the keyword file written). */
export function modelStatus(root = paths.models) {
  const p = modelPaths(root)
  const present = {
    kws: [p.kws.encoder, p.kws.decoder, p.kws.joiner, p.kws.tokens].every((f) => existsSync(f)),
    vad: existsSync(p.vad),
    asr: [p.asr.encoder, p.asr.mergedDecoder, p.asr.tokens].every((f) => existsSync(f)),
  }
  return { ...present, all: present.kws && present.vad && present.asr, paths: p }
}

async function download(model, to, log) {
  const res = await fetch(model.url, { redirect: 'follow', signal: AbortSignal.timeout(15 * 60_000) })
  if (!res.ok || !res.body) throw new Error(`download failed (${res.status}) for ${model.url}`)
  const hash = createHash('sha256')
  const out = createWriteStream(to, { mode: 0o600 })
  let got = 0
  let lastShown = 0
  for await (const chunk of res.body) {
    hash.update(chunk)
    got += chunk.length
    if (got > model.bytes * 1.05) throw new Error(`${model.url} is larger than expected — stopped`)
    if (!out.write(chunk)) await new Promise((r) => out.once('drain', r))
    const pct = Math.floor((got / model.bytes) * 100)
    if (pct >= lastShown + 25) {
      lastShown = pct - (pct % 25)
      log?.(`  ${model.title}: ${lastShown}%`)
    }
  }
  await new Promise((r, j) => out.end((err) => (err ? j(err) : r())))
  const digest = hash.digest('hex')
  if (digest !== model.sha256) {
    rmSync(to, { force: true })
    throw new Error(`${model.title}: checksum mismatch (got ${digest}) — the download was discarded`)
  }
}

/**
 * Windows' own bsdtar (System32\tar.exe, Windows 10 1803+), not a GNU tar from Git for Windows
 * that may come first on PATH and would read "C:\…" as a remote host.
 */
export const systemTar = () => (process.platform === 'win32' ? join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe') : 'tar')

/** Downloads and unpacks whatever is missing. Verified before anything is unpacked. */
export async function ensureModels({ root = paths.models, log = console.log } = {}) {
  mkdirSync(root, { recursive: true })
  const status = modelStatus(root)
  for (const [key, model] of Object.entries(MODELS)) {
    if (status[key]) continue
    const total = (model.bytes / 1e6).toFixed(1)
    log?.(`Downloading the ${model.title} model (${total} MB, ${model.license}) from github.com/k2-fsa/sherpa-onnx…`)
    const staging = join(root, `.staging-${key}-${process.pid}`)
    rmSync(staging, { recursive: true, force: true })
    mkdirSync(staging, { recursive: true })
    try {
      const file = join(staging, model.archive ? 'archive.tar.bz2' : model.file)
      await download(model, file, log)
      if (model.archive) {
        // bsdtar on Windows 10+ and macOS, GNU tar (with bzip2) on Linux.
        const r = spawnSync(systemTar(), ['-xjf', file, '-C', staging], { stdio: 'pipe', windowsHide: true })
        if (r.status !== 0) {
          throw new Error(`could not unpack ${model.title}: ${String(r.stderr ?? r.error ?? '').trim() || 'tar failed'}` +
            (process.platform === 'linux' ? ' (is bzip2 installed?)' : ''))
        }
        rmSync(file, { force: true })
        const unpacked = join(staging, model.dir)
        if (!existsSync(unpacked) || !statSync(unpacked).isDirectory()) throw new Error(`${model.title}: unexpected archive layout`)
        // Keep only what Jarvis uses.
        for (const entry of readdirSync(unpacked)) {
          if (!model.keep.includes(entry)) rmSync(join(unpacked, entry), { recursive: true, force: true })
        }
        rmSync(join(root, model.dir), { recursive: true, force: true })
        renameSync(unpacked, join(root, model.dir))
      } else {
        mkdirSync(join(root, model.dir), { recursive: true })
        renameSync(file, join(root, model.dir, model.file))
      }
    } finally {
      rmSync(staging, { recursive: true, force: true })
    }
  }
  const p = modelPaths(root)
  writeFileSync(p.kws.keywords, KEYWORDS)
  return modelStatus(root)
}
