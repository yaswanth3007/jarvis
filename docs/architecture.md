# Architecture

Jarvis is one shared core and one native client per operating system. Everything that
decides *what* Jarvis may do lives in the shared core, so the rules are the same on every
platform. The clients only decide *how* each action is carried out on their OS.

```
                         ┌──────────────────────────── shared core (Node.js) ───────────────────────────┐
  web face (browser)  ─► │ bridge/server.mjs   Claude Agent SDK session per connection                   │
  React + Three.js       │ bridge/permissions.mjs  the permission broker (every tool call passes it)    │
                         │ bridge/mac.mjs      device tools: jarvis_mac (macOS), jarvis_desktop (Win/Linux)│
                         │ bridge/voice-auth.mjs   per-install key: signatures and proofs                │
                         │ core/supervisor.mjs  keeps bridge + face + voice engine running               │
                         │ core/voice-server.mjs   Kokoro voice (same voice on every OS)                 │
                         │ core/paths.mjs · core/platform.mjs · core/models.mjs · core/tasks.mjs ·      │
                         │ core/commands.mjs · core/permission-store.mjs · core/control.mjs · keepalive  │
                         └──────────────▲─────────────────────────────▲─────────────────────────────────┘
                                        │ signed WebSocket (loopback)  │
                  ┌─────────────────────┴──────┐        ┌──────────────┴───────────────────────────────┐
                  │ macOS client (Swift)        │        │ Windows / Linux client (Node.js, client/)    │
                  │ macos/JarvisVoice           │        │ client/main.mjs + listener + speaker         │
                  │ Apple Speech, AVFoundation, │        │ sherpa-onnx (wake word, VAD, speech-to-text) │
                  │ Accessibility, ScreenCapture│        │ adapters/windows.mjs  (UI Automation…)       │
                  │ Kit, Apple Events, menu bar │        │ adapters/linux.mjs    (AT-SPI, X11/wlroots…) │
                  └─────────────────────────────┘        └──────────────────────────────────────────────┘
```

## Why a native client per OS

The spec's rule is "do not force one operating system's implementation onto another when a
native API is more reliable". So:

| Job | macOS | Windows | Linux |
|---|---|---|---|
| Start at login, restart on crash | launchd LaunchAgents | HKCU `Run` entry → `core/keepalive.mjs` | `systemd --user` units (XDG autostart + keepalive without systemd) |
| Microphone | Core Audio (AVAudioEngine) | WASAPI (PvRecorder) | PipeWire / PulseAudio / ALSA (`pw-record`, `parec`, `arecord`) |
| Wake word, speech-to-text | Apple Speech (SpeechAnalyzer), on device | sherpa-onnx keyword spotter + Silero VAD + Moonshine, on device | same as Windows |
| Voice | Kokoro voice engine (shared) | Kokoro → SoundPlayer; SAPI fallback | Kokoro → `pw-play`/`paplay`/`aplay`; espeak-ng fallback |
| Apps (list, open, close) | NSWorkspace | Start menu (`Get-StartApps`, `shell:AppsFolder`), `CloseMainWindow` | `.desktop` entries, `gtk-launch`/`gio`; close via EWMH (`wmctrl`) or sway |
| Read / operate windows | Accessibility (AXUIElement) | UI Automation, SendKeys | AT-SPI; `xdotool` (X11) / `wtype` (wlroots) for keys |
| Screen | ScreenCaptureKit | GDI screen copy | `grim`, `gnome-screenshot`, `spectacle`, `scrot`, `maim`, ImageMagick |
| Camera | AVFoundation | ffmpeg (DirectShow), if installed | ffmpeg / fswebcam (V4L2) |
| Status icon | menu bar item | notification-area icon (NotifyIcon) | StatusNotifierItem (AppIndicator) |
| OS permission owner | TCC (macOS asks) | Windows privacy settings | the desktop (Wayland portals, `video` group…) |

Anything a platform cannot do is reported honestly by `core/platform.mjs`, shown by `jarvis
doctor`, sent to the bridge when the client connects, and stated in Claude's instructions — so
Jarvis says "that isn't available here, because…" instead of trying another way.

## What is shared, and how consistency is enforced

- **One permission broker** (`bridge/permissions.mjs`) for every client. The Windows/Linux tools
  have the same names as the Mac's (`open_app`, `read_window`, `type_text`, `run_tasks`…), so
  every rule — messages are never sent without the word "send" and a fresh read, shell commands
  are read out and confirmed, program files are confirmed, sub-agents are refused — applies
  identically. `tests/broker.test.mjs` runs the same scenarios against both tool servers.
- **One command language.** `core/commands.mjs` is the JavaScript twin of the Mac app's Swift
  parsers; `tests/vectors/commands.json` is run against both (`npm test` and
  `npm run test:swift`), so "stop task 2", "open Chess and Dictionary" and "revoke camera
  access" mean the same thing everywhere.
- **One task orchestrator design.** `core/tasks.mjs` implements the Mac's `Tasks.swift` rules
  (exclusive/shared resources, dependencies, limits, timeouts, retries, cancellation); the same
  scenarios are tested in both languages.
- **One permission store format** (`permissions.json`), read fresh by the broker on every
  decision, written only by the voice assistant from the user's own answers.
- **One key and handshake** (`bridge/voice-auth.mjs`).

## A request, end to end

1. The client hears "Hey Jarvis, …" (or a typed `jarvis ask …`).
2. Local commands are answered on the computer without Claude: the time and date, task
   status and cancellation, permission commands, opening/closing apps by name.
3. Anything else becomes a task (kind `claude`) on its own bridge connection — one Claude
   session per task. The user's words and the computer's context (which app is in front; a
   window title is someone else's text) travel as separate fields.
4. Each tool call Claude makes passes the broker (`PreToolUse` hook). When the user must
   decide, the bridge sends `confirm`; the client asks aloud and replies with the decision.
5. Device tools come back to the client as `mac` (macOS) or `desktop` (Windows/Linux)
   requests. The client runs them only while a request of its own is running on that
   connection, re-checks the permission store, and schedules them on the orchestrator.
6. The answer is spoken. Requests can continue in the background while you ask something
   else ("Task 2, the weather: …").

## Security model

- Everything listens on loopback only (`core/loopback.mjs`, explicit `127.0.0.1` binds).
- A per-install key (`bridge.key`, 32 random bytes; 0600 in a 0700 folder on macOS/Linux, the
  per-user `%LOCALAPPDATA%` on Windows) never leaves the machine and is never sent over a
  connection. Clients sign each connection (HMAC, single use, ±2 minutes); the bridge, the voice
  engine and the control channels answer nonces with proofs. A process that grabs a port or a
  pipe name while Jarvis is down is never trusted, and nothing is sent to it.
- The web face keeps its original origin checks and never gets device tools.
- Content read from apps, pages, screens and files is data, never instructions (stated in
  Claude's instructions and enforced by the broker's "did the user ask for this?" check).

## Files

| | macOS | Windows | Linux |
|---|---|---|---|
| Settings, key, permissions | `~/Library/Application Support/JarvisVoice` | `%LOCALAPPDATA%\Jarvis` | `$XDG_CONFIG_HOME/jarvis` (`~/.config/jarvis`) |
| Logs | `~/Library/Logs/Jarvis` | `%LOCALAPPDATA%\Jarvis\Logs` | `$XDG_STATE_HOME/jarvis/logs` |
| Models and caches | `~/Library/Caches/JarvisVoice` | `%LOCALAPPDATA%\Jarvis\Cache` | `$XDG_CACHE_HOME/jarvis` |
| Control channel | `control.sock` in the settings folder | `\\.\pipe\jarvis-voice-<user>` | `$XDG_RUNTIME_DIR/jarvis/control.sock` |

`JARVIS_HOME`, `JARVIS_LOG_DIR` and `JARVIS_CACHE_DIR` move them (the tests use this).
