# Validation

What was actually built and tested, where, and what was measured. Nothing here is estimated:
every number comes from a test run, and anything that could not be tested is listed as such.

**Environments**

- **This Mac** — Apple M1 Max (10 cores), macOS 27.0.1, Node 26 — the real, running installation
  (LaunchAgents, Jarvis Voice with its TCC grants), plus the full test suites. The machine was
  under load during the measurements (local LLM server ≈ 47 % CPU, load average ≈ 7.7), which
  slows the voice engine.
- **GitHub Actions** (`.github/workflows/ci.yml`, Node 22), on GitHub-hosted runners:
  `macos-26` (arm64), `macos-26-intel` (x64), `windows-2025` (x64), `windows-11-arm` (ARM64),
  `ubuntu-24.04` (x64), `ubuntu-24.04-arm` (ARM64). Linux jobs run in a headless desktop session
  (Xvfb, D-Bus, AT-SPI, Openbox, PulseAudio with a virtual sink); Windows jobs use the runner's
  own desktop session.
- **A local Linux ARM64 container** (Debian 12, `packaging/ci/Dockerfile.linux-test`) on this Mac.

## Results by platform

| | macOS arm64 | macOS x64 | Windows x64 | Windows ARM64 | Linux x64 | Linux ARM64 |
|---|---|---|---|---|---|---|
| Install dependencies, native binaries | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Speech models downloaded and SHA-256 verified | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| JS test suite (`npm test`) | ✓ | ✓ | ✓ | WINDOWS_ARM64_TESTS | ✓ | ✓ |
| Swift tests (82, shared vectors) and app build | ✓ | ✓ | — | — | — | — |
| Wake word + transcription on recordings | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Real desktop end to end (open, read, click/type, keys, screenshot, close) | real Mac ✓ | — | ✓ Notepad (UI Automation) | WINDOWS_ARM64_DESKTOP | ✓ GTK app (AT-SPI, X11) | ✓ GTK app (AT-SPI, X11) |
| Live sound: player → sound server → microphone → wake word | — | — | — (no audio device) | — (no audio device) | ✓ | ✓ |
| Voice engine (Kokoro) speaks, with proofs | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Voice assistant end to end against a bridge (signed, permission question, desktop action, quit) | real Mac ✓ | n/a | ✓ | WINDOWS_ARM64_CLIENT | ✓ | ✓ |
| Package built (runtime-only) + smoke test of the package | ✓ | ✓ | ✓ zip + setup.exe | WINDOWS_ARM64_PACKAGE | ✓ tar.gz + .deb | ✓ tar.gz + .deb |
| .deb installed and run | — | — | — | — | ✓ | ✓ |
| Installed as a user would, login service started, uninstalled | ✓ launchd | ✓ launchd | ✓ Run entry + keepalive | WINDOWS_ARM64_INSTALL | ✓ systemd --user | ✓ systemd --user |

On this Mac, after reinstalling with the new shared core (`macos/jarvisctl install`): all services
running from `core/supervisor.mjs`, Jarvis Voice reconnected and verified the bridge, and typed
requests worked end to end — the time (local), "open Calculator and Chess" (two tasks in
parallel), "close Calculator and Chess", a Claude question answered through the updated bridge,
and "look at my screen" asking for permission and honouring "no". `npm test` here: 50 passed,
17 skipped (Windows/Linux only), 0 failed; Swift: 82/82.

## Performance (measured)

**Speech pipeline (Windows/Linux listener; also run on macOS)** — the 10 test recordings, through
the real listener (keyword spotter + VAD + Moonshine):

| | real-time factor (median) | transcription per utterance, median / p95 | models load |
|---|---|---|---|
| This Mac (arm64) | 0.028–0.040 | 32–54 ms / 50–73 ms | 0.7–0.8 s |
| macOS arm64 runner | 0.030 | 38 / 51 ms | 1.9 s |
| macOS x64 runner | 0.099 | 144 / 304 ms | 6.2 s |
| Windows x64 runner | 0.022–0.046 | 28–61 / 39–78 ms | 1.0–1.8 s |
| Windows ARM64 runner | 0.050–0.052 | 52–60 / 82–86 ms | 1.3–1.4 s |
| Linux x64 runner | 0.037 | 49 / 70 ms | 1.0 s |
| Linux ARM64 runner | 0.045 | 56 / 81 ms | 1.1 s |

Every run: all 7 wake-phrase recordings woke Jarvis, none of the 3 other sentences did, and the
requests were transcribed exactly ("what time is it?", "stop task 2.", "open the calculator.").
After speech ends, an utterance is closed by 0.55 s of silence, then transcribed (times above).
Through the Linux sound server (player → virtual sink → microphone) the request was ready
≈ 1.8 s after the speech ended — that figure includes the sound server's own buffering.

**Desktop actions** (one run each, ms):

| | open | read window | click | type | keys | screenshot | close |
|---|---|---|---|---|---|---|---|
| Windows x64 (Notepad) | 3624 | 103 | — | 671 | 228 | 162 | 6049 ¹ |
| Linux x64 (GTK app) | 73 | 57 | 60 | 58 | 162 | 26 | 314 |
| Linux ARM64 (GTK app) | 90 | 52 | 51 | 50 | 159 | 14 | 312 |

¹ Notepad had unsaved text, so it asked about it; Jarvis waited, then reported honestly that it was
still open. The Windows helper answers in 0.3–0.9 ms per call once started (first start 0.3–7.6 s).

**Voice engine (Kokoro, one sentence of 10–57 characters, n = 6)**, median / p95:
this Mac 1518 / 2655 ms; macOS arm64 runner 2211 / 3647; macOS x64 runner 8693 / 12488;
Windows x64 1533–3222 / 2489–5323; Windows ARM64 2109 / 3361; Linux x64 3137 / 4873;
Linux ARM64 1694 / 2949 (container on this Mac: 1553 / 2270). Jarvis speaks the first sentence
while the next is being made.

**Task orchestrator overhead** (n = 200), median / p95: 0.03–0.26 ms / 0.08–0.59 ms on every platform.

**macOS, before and after (this Mac, typed requests through Jarvis Voice, n = 5, medians)**:

| | previous round | this round |
|---|---|---|
| "Open Chess, Dictionary and Font Book": all three running | 0.42 s | 0.41 s |
| … first audio | 0.64 s | 1.03 s ² |
| … complete | 4.2 s | 4.3 s |
| "Open Chess": running | 0.11 s (p95 0.28 s) | 0.23 s |
| … first audio | — | 0.31 s |

² The Swift code on this path is unchanged; the reply is synthesised by the voice engine, which
was slower under today's load (see above).

## Packages (CI artifacts)

| | unpacked runtime | archive | installer |
|---|---|---|---|
| macOS arm64 | 381 MB | 148 MB tar.gz | — (`jarvisctl install` builds and signs the app locally) |
| macOS x64 | 396 MB | 155 MB tar.gz | — |
| Windows x64 | 428 MB | 182 MB zip | 124 MB setup.exe (per-user NSIS) |
| Windows ARM64 | WINDOWS_ARM64_SIZE |
| Linux x64 | 445 MB | 177 MB tar.gz | 137 MB .deb |
| Linux ARM64 | 440 MB | 176 MB tar.gz | 135 MB .deb |

Of each, ≈ 260 MB is the Claude Code binary the Agent SDK runs. Before pruning onnxruntime's GPU
providers, the Linux x64 package was 789 MB unpacked (394 MB tar.gz). Checksums are in each CI
run's `SHA256SUMS-*.txt` artifact.

## Not tested (no environment for it)

Real microphones on Windows and Linux hardware (CI runners have no microphone; Windows runners
have no audio device at all), Wayland sessions, PipeWire-only systems, Bluetooth/USB headsets,
logging out and in (services were installed and started, not restarted by a real login),
Accessibility and Screen Recording on this Mac (blocked by its MDM profile / not granted by macOS),
WhatsApp, VS Code and Spotify (not installed on this Mac). See [limitations.md](limitations.md).
