# Development

## Layout

| Path | What |
|---|---|
| `src/` | the web face (React, Three.js) — unchanged by the cross-platform work |
| `bridge/` | the brain: Claude Agent SDK sessions, the permission broker, device tools, key handling |
| `core/` | shared by every platform: paths, capability detection, the supervisor, the Kokoro voice engine, the task orchestrator, command parsers, the permission store, the control channel, keepalive, model manifest |
| `client/` | the Windows/Linux voice assistant: `main.mjs`, `listener.mjs` (sherpa-onnx), `speaker.mjs`, `audio.mjs`, `bridge-client.mjs`, `tray.mjs`, `adapters/` |
| `macos/` | the macOS menu bar app (Swift), `jarvisctl`, its unit tests |
| `bin/jarvis.mjs` | the cross-platform CLI |
| `packaging/` | package builder, Windows installer script, Linux wrapper, CI helpers |
| `tests/` | `node:test` suites, shared vectors, speech fixtures |
| `docs/` | these documents |

## Running from a checkout

```bash
npm install
```

```bash
npm start
```

`npm start` is the original browser experience (bridge + Vite face). For the always-on assistant
use `jarvis setup` and `jarvis install` (macOS: `macos/jarvisctl install`). While developing the
Windows/Linux client you can run it in the foreground — stop the service first (`jarvis stop`):

```bash
node client/main.mjs
```

`--no-mic` and `--no-tray` turn those off; `jarvis ask <text>` and `jarvis hear <file.wav>` drive it.

## Tests

```bash
npm test
```

```bash
npm run test:swift
```

`npm test` runs everything that applies to the current OS; platform-specific suites are skipped
elsewhere and say why. Switches (CI sets them on the right runners):

| Variable | Turns on |
|---|---|
| `JARVIS_TEST_MODELS=<dir>` | use speech models from this folder |
| `JARVIS_REQUIRE_SPEECH=1` | fail (not skip) when the speech models are missing |
| `JARVIS_TEST_TTS=1` (+ `JARVIS_TTS_CACHE=<dir>`) | the Kokoro voice engine tests (downloads ≈90 MB once) |
| `JARVIS_E2E_DESKTOP=1` | real desktop tests: Notepad through UI Automation on Windows; a GTK window through AT-SPI on Linux |
| `JARVIS_E2E_AUDIO=1` | Linux: play → sound server → microphone → wake word |

On Linux, `packaging/ci/linux-session.sh <command>` provides a headless desktop (Xvfb, D-Bus,
AT-SPI, a window manager, PulseAudio with a virtual sink). `packaging/ci/Dockerfile.linux-test`
is the same environment as a container image.

Every test runs against a scratch Jarvis folder (`tests/helpers.mjs`) — never your real
settings, key, permissions or logs.

## Rules for changes

- Behaviour belongs in the shared core; an adapter only says how its OS does something.
- A new spoken command goes into `core/commands.mjs` **and** the Swift parser, with vectors in
  `tests/vectors/commands.json`.
- A new device tool keeps the Mac's tool name and argument names, so the broker's rules apply;
  add it to `TOOL_NEEDS` in `bridge/mac.mjs` if it needs a capability.
- Report missing capabilities through `core/platform.mjs` with a reason and a fix; never fake one.
- Never weaken a broker rule for one platform. `tests/broker.test.mjs` runs every rule against
  both tool servers.
