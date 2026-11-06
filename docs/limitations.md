# Known limitations

Stated plainly, so nothing is assumed to work that hasn't been shown to. What was actually
built and tested on which platform is in [validation.md](validation.md).

## Everywhere

- **English only** for the wake word and speech recognition on Windows and Linux (the models
  are English); macOS uses Apple's recogniser for the system language.
- **Claude Code is required** (signed in). Jarvis never asks for an API key, and the Agent SDK's
  own Claude Code binary (≈260 MB) is part of every package.
- **First-run downloads**: speech models ≈48 MB (Windows, Linux) and the Kokoro voice ≈90 MB,
  each verified (pinned SHA-256 for the speech models). Until Kokoro is ready, Jarvis speaks with
  the system voice.
- **Packages are not code-signed** by a publisher certificate: Windows SmartScreen will warn about
  the installer; the .deb is unsigned; the macOS app is signed locally (your own certificate or ad
  hoc) and not notarized.
- **Node.js 20+ is a prerequisite**, not bundled.

## macOS

- Requires macOS 26 (SpeechAnalyzer).
- On Macs managed by an MDM profile that blocks it, Accessibility (reading and operating other
  apps' windows) cannot be granted. On the development Mac, Screen Recording stayed "not granted"
  after being switched on, for reasons macOS did not report; Jarvis reports it honestly.

## Windows

- Apps running as administrator cannot be read or operated (Windows prevents it for normal
  programs); Jarvis does not elevate.
- The Windows key cannot be pressed; shortcuts use Ctrl/Alt/Shift.
- Windows restricts which programs may bring a window to the front. Jarvis uses the documented
  focus APIs; if Windows still keeps another window in front of the app you named (seen on the
  Windows 11 ARM64 CI runner), Jarvis types into the field through UI Automation where the field
  allows it, and refuses key presses with an explanation — it never presses keys into the wrong
  window. If that happens, bring the app to the front yourself and ask again.
- The camera needs ffmpeg on PATH (no built-in way for a background program to take a photo).
- Windows CI runners have no audio devices: microphone capture (PvRecorder/WASAPI) is not
  exercised in CI; the speech pipeline is (from recordings), and playback is exercised where a
  device exists.
- Some apps expose little through UI Automation (games, some custom-drawn apps).

## Linux

- On **Wayland (GNOME, KDE)** the desktop does not let other programs see which window is in
  front, close other apps' windows politely, or send keystrokes. Jarvis says so; "force quit"
  still ends an app. X11 and wlroots compositors (sway, Hyprland) support these.
- Reading/operating windows needs AT-SPI (python3-gi + the Atspi typelib) and apps that expose
  accessibility; Chromium/Electron apps may need `--force-renderer-accessibility`.
- The status icon needs StatusNotifierItem support (GNOME needs the AppIndicator extension).
- **No AppImage** is provided: Jarvis registers per-user services that need a stable path, which
  an AppImage's temporary mount point is not. Use the .deb or the tar.gz.
- CI tests run under Xvfb (X11) with a virtual PulseAudio sink: real microphones, Wayland
  sessions and PipeWire-only systems are not part of the automated tests.

## Not covered by any automated test

Real microphones on Windows and Linux hardware, Bluetooth or USB headsets, log-out/log-in
autostart (the services are installed and started in CI, but no CI runner logs a user in), and
long-running soak tests.
