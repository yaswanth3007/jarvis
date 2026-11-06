# Jarvis on Windows

An always-on "Hey Jarvis" assistant for Windows 10 (1809 or later) and Windows 11, on **x64 and
ARM64**. It listens on your computer (the wake word and speech recognition run offline), thinks
with your existing Claude Code sign-in, speaks with the same Kokoro voice as the Mac, and can
open, read and operate your apps through Windows' own accessibility API (UI Automation).

No administrator rights are needed and nothing outside your user profile is changed.

## 1. Prerequisites

- **Node.js 20 or newer** — <https://nodejs.org> (the x64 or ARM64 installer that matches your PC).
- **Claude Code, signed in** — install it, run `claude` once and log in. Jarvis reuses that
  sign-in; it never asks for an API key.
- A microphone, and in **Settings → Privacy & security → Microphone**, "Let desktop apps access
  your microphone" switched on.
- Optional: **ffmpeg** on PATH, for "look through the camera" (Windows has no built-in way for a
  background program to take a photo). Camera access also needs "Let desktop apps access your
  camera".

## 2. Install

**Installer** — run `jarvis-<version>-windows-<arch>-setup.exe`. It installs into
`%LOCALAPPDATA%\Programs\Jarvis`, adds Start menu entries, and offers to run setup straight away.

**Zip** — unzip `jarvis-<version>-windows-<arch>.zip` anywhere you like, open a terminal there and run:

```powershell
.\jarvis.cmd setup
```

```powershell
.\jarvis.cmd install
```

**From a clone** — `npm install`, then `node bin\jarvis.mjs setup` and `node bin\jarvis.mjs install`.

`jarvis setup` creates the per-install key, downloads and verifies the speech models (≈48 MB,
from the sherpa-onnx project's releases, checked against pinned SHA-256 hashes) and prints what
this PC can do. `jarvis install` adds two per-user login entries
(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`: `JarvisAgent`, `JarvisVoice`) and starts
Jarvis now. Each runs through `core\keepalive.mjs` in a hidden console (`conhost --headless`),
which restarts it if it crashes.

## 3. Use it

Say **"Hey Jarvis"**, then your request — or both in one breath: "Hey Jarvis, open Notepad and
Calculator", "what are you doing?", "stop task 2", "read Notepad", "what permissions do you
have?". The first time Jarvis wants to read or operate an app, look at your screen or use the
camera, he asks; answer "allow", "allow always", "no" or "never".

The notification-area icon shows what Jarvis is doing and has **Pause listening**, **Open the
JARVIS interface**, **Open the logs folder** and **Quit**.

From a terminal: `jarvis status`, `jarvis tasks`, `jarvis ask <text>`, `jarvis answer allow`,
`jarvis mute`, `jarvis unmute`, `jarvis doctor`, `jarvis logs voice`.

## What works how on Windows

| | How | Notes |
|---|---|---|
| Wake word, speech-to-text | sherpa-onnx, offline | English |
| Voice | Kokoro voice engine; Windows SAPI voice as fallback | |
| Apps | Start menu apps (incl. Store apps); opened like the Start menu does | |
| Close apps | asks the app to close (it can ask about unsaved work) | "force quit" ends it |
| Read / click / type / keys | UI Automation, SendKeys | apps running as administrator are out of reach; the Windows key can't be pressed |
| Screen | GDI screen copy | protected (DRM) content may appear black |
| Camera | ffmpeg (DirectShow) if installed | |

Jarvis runs its Windows helper by sending a script to `powershell.exe` on standard input; it
never changes PowerShell's execution policy.

Removing Jarvis: [uninstall.md](uninstall.md). Problems: [troubleshooting.md](troubleshooting.md).
