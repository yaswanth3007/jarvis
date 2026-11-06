# Jarvis on macOS

On macOS, Jarvis Voice is a native menu bar app (Swift, in `macos/`): Apple's on-device speech
recognition for "Hey Jarvis", Core Audio, Accessibility, ScreenCaptureKit and Apple Events, with
every permission asked for by macOS itself. The full guide — every command, the task
orchestrator, the guided permission flow and the latency measurements — is
[macos/README.md](../macos/README.md). This page is the short version.

## Requirements

- **macOS 26 (Tahoe) or later**, Apple silicon (arm64) or Intel (x64). Jarvis Voice uses Apple's
  SpeechAnalyzer, which is new in macOS 26.
- **Xcode Command Line Tools** (`xcode-select --install`) — the app is compiled on your Mac so it
  can be signed with your own identity.
- **Node.js 20 or newer** and **Claude Code, signed in** (`claude` once).

## Install

From a clone (`npm install`) or the `jarvis-<version>-macos-<arch>.tar.gz` package:

```bash
macos/jarvisctl signing-identity
```

```bash
macos/jarvisctl install
```

`signing-identity` (optional, once) creates a self-signed certificate in your login keychain so
macOS keeps the app's permissions across updates; without it every rebuild asks again.
`install` builds Jarvis Voice into `~/Applications`, writes the two LaunchAgents
(`local.jarvis.agent`, `local.jarvis.voice`) and starts them. macOS then asks for the microphone
and speech recognition; Jarvis guides you through Accessibility and Screen Recording when an
action first needs them.

`jarvis <command>` works on macOS too and hands over to `macos/jarvisctl` (status, doctor, tasks,
ask, answer, cancel, logs, restart, uninstall…).

## Notes

- Upgrading from an earlier version keeps your settings, permissions and key: the folders are
  unchanged (`~/Library/Application Support/JarvisVoice`). The agent moved to
  `core/supervisor.mjs`; `macos/agent/supervisor.mjs` remains as a shim, so a LaunchAgent written
  by an earlier version keeps working, and `jarvisctl install` writes the new path.
- The app is signed locally (your own certificate, or ad hoc); it is not notarized. That is fine
  for an app you build yourself; see [limitations](limitations.md).

Removing Jarvis: [uninstall.md](uninstall.md). Problems: [troubleshooting.md](troubleshooting.md).
