# Building packages

```bash
npm ci
```

```bash
npm run package -- --out out
```

`packaging/package.mjs` builds for the computer it runs on (CI runs it on each OS and
architecture, so every package carries the right native binaries):

| OS | Artifacts |
|---|---|
| macOS | `jarvis-<v>-macos-<arch>.tar.gz` (install with `macos/jarvisctl install`, which compiles and signs the app locally) |
| Windows | `jarvis-<v>-windows-<arch>.zip`, and with NSIS `jarvis-<v>-windows-<arch>-setup.exe` (per-user installer) |
| Linux | `jarvis-<v>-linux-<arch>.tar.gz`, and with `dpkg-deb` `jarvis_<v>_<amd64\|arm64>.deb` |

plus `SHA256SUMS-<os>-<arch>.txt`.

## What goes into a package

1. The face, built once with Vite into `dist/` (served by `core/face-server.mjs`; Vite is not shipped).
2. `bin/`, `bridge/`, `core/`, `docs/`, `scripts/`, and `macos/` (macOS) or `client/` (Windows, Linux).
3. **Only runtime dependencies**: the dependency closure of what `bridge/`, `core/` and `client/`
   import — `@anthropic-ai/claude-agent-sdk`, `zod`, `ws`, `kokoro-js`, plus `sherpa-onnx-node`
   (Windows, Linux) and `@picovoice/pvrecorder-node` (Windows). Packages only needed to build
   the face (React, Three.js, MediaPipe…) are left out.
4. Inside those, what this platform never loads is removed: the other operating systems'
   onnxruntime binaries and its GPU execution providers (the voice engine runs on the CPU), the
   browser-only WebAssembly runtime (the Node build of
   `@huggingface/transformers` imports `onnxruntime-node`; the packager checks this), and source maps.

The largest single item is the Claude Code binary that the Agent SDK runs (≈260 MB unpacked), which
cannot be left out. Node.js itself is a prerequisite and is not bundled; the speech models
(≈48 MB) and the Kokoro voice (≈90 MB) are downloaded and verified on first run, not shipped.

`packaging/ci/smoke-package.mjs <staged folder>` runs the packaged build — its CLI, its bridge
(which must prove itself), its built face and (Windows/Linux) its voice assistant — to show the
package is complete.

## Dependencies, classified

| Dependency | Licence | Where it is used | Class |
|---|---|---|---|
| `@anthropic-ai/claude-agent-sdk` (+ its per-platform Claude Code binary) | Anthropic terms | the bridge, every OS | shared, runtime; native binary per OS/arch |
| `zod`, `ws` | MIT | bridge, client, CLI | shared, runtime |
| `kokoro-js` → `@huggingface/transformers` → `onnxruntime-node`, `sharp` | Apache-2.0 / MIT | the voice engine, every OS | shared, runtime; native binaries per OS/arch |
| `sherpa-onnx-node` (+ `sherpa-onnx-<os>-<arch>`) | Apache-2.0 | wake word, VAD, speech-to-text | Windows and Linux only (optional dependency; not packaged on macOS) |
| `@picovoice/pvrecorder-node` | Apache-2.0 | microphone (WASAPI) | Windows only (optional dependency; packaged on Windows only) |
| React, Three.js, `@react-three/*`, framer-motion, MediaPipe, Porcupine web, DOMPurify, zustand, `@anthropic-ai/sdk` | MIT / Apache-2.0 | the web face, bundled into `dist/` by Vite | build-time for packages (not shipped) |
| Vite, TypeScript, oxlint, tsx, `@types/*` | MIT / Apache-2.0 | development | dev only |
| Speech models (sherpa-onnx GigaSpeech KWS, Silero VAD, Moonshine tiny) | Apache-2.0 / MIT | Windows, Linux | downloaded on first run, SHA-256 pinned |
| Kokoro-82M voice (q8) | Apache-2.0 | every OS | downloaded on first run (Hugging Face) |
| OS tools: PowerShell 5.1 / .NET (Windows); `parec`/`pw-record`/`arecord`, `paplay`/`pw-play`/`aplay`, python3-gi + AT-SPI, `wmctrl`, `xdotool`, `wtype`, `grim`/`scrot`…, `espeak-ng` (Linux) | the OS's | adapters | system, detected at run time; optional ones reported by `jarvis doctor` |

No paid service is required beyond the user's existing Claude Code subscription; ElevenLabs
remains an optional add-on of the web face.

## CI

`.github/workflows/ci.yml` runs on every push: macOS 26 arm64 and x64, Windows x64 and ARM64,
Ubuntu 24.04 x64 and ARM64. Each job installs, downloads and verifies the models, runs the tests
that apply (desktop end-to-end tests included), builds the Swift app (macOS), packages,
smoke-tests the package, installs the .deb (Linux), and uploads the artifacts to the run.
Nothing is published.
