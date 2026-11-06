# Jarvis on Linux

An always-on "Hey Jarvis" assistant for Linux desktops on **x64 and ARM64** (tested on Ubuntu
24.04 and Debian 12). It listens on your computer (offline wake word and speech recognition),
thinks with your existing Claude Code sign-in, speaks with the same Kokoro voice as the Mac, and
reads and operates apps through AT-SPI, the desktop's accessibility API.

It runs as your user (`systemd --user`); nothing needs root except installing distribution packages.

## 1. Prerequisites

- **Node.js 20 or newer** — from <https://nodejs.org>, your distribution (if new enough) or a version manager.
- **Claude Code, signed in** — run `claude` once and log in. Jarvis reuses that sign-in.
- **Desktop packages** (pick your family; only what you want is needed — `jarvis doctor` says what is missing):

```bash
sudo apt install python3-gi gir1.2-atspi-2.0 pulseaudio-utils wmctrl xdotool bzip2 xdg-utils espeak-ng gir1.2-ayatanaappindicator3-0.1
```

```bash
sudo dnf install python3-gobject at-spi2-core pulseaudio-utils wmctrl xdotool bzip2 xdg-utils espeak-ng libayatana-appindicator-gtk3
```

```bash
sudo pacman -S python-gobject at-spi2-core libpulse wmctrl xdotool bzip2 xdg-utils espeak-ng libayatana-appindicator
```

`pulseaudio-utils` provides `parec`/`paplay`, which also work on PipeWire systems (through
pipewire-pulse); `pw-record`/`pw-play` or ALSA's `arecord`/`aplay` are used if that is what you have.

## 2. Install

- **.deb** (Debian, Ubuntu and derivatives): `sudo apt install ./jarvis_<version>_<amd64|arm64>.deb`,
  then **as your own user**: `jarvis setup` and `jarvis install`.
- **tar.gz**: unpack `jarvis-<version>-linux-<arch>.tar.gz` where you like, then run
  `./bin/jarvis.mjs setup` and `./bin/jarvis.mjs install` from it.
- **From a clone**: `npm install`, `node bin/jarvis.mjs setup`, `node bin/jarvis.mjs install`.

`jarvis setup` creates the per-install key, downloads and verifies the speech models (≈48 MB,
pinned SHA-256) and prints what this desktop can do. `jarvis install` writes two user units into
`~/.config/systemd/user` and starts them:

- `jarvis-agent.service` — the bridge, the face and the voice engine (`WantedBy=default.target`);
- `jarvis-voice.service` — the assistant itself, tied to your graphical session
  (`PartOf=graphical-session.target`), restarted if it crashes.

Without a systemd user session, `jarvis install` uses XDG autostart entries in
`~/.config/autostart` with `core/keepalive.mjs` instead.

## 3. Use it

Say **"Hey Jarvis"** and your request: "open Firefox and the Calculator", "read the text editor",
"what are you doing?", "stop task 2", "stop controlling applications". `jarvis status`, `jarvis
tasks`, `jarvis ask <text>`, `jarvis answer allow`, `jarvis mute`, `jarvis doctor`, `jarvis logs voice`.

## X11 and Wayland

| | X11 | Wayland (GNOME, KDE) | Wayland (wlroots: sway, Hyprland…) |
|---|---|---|---|
| Wake word, speech, voice | yes | yes | yes |
| Open apps | yes | yes | yes |
| Read windows, click, type (AT-SPI) | yes | yes | yes |
| Which window is in front | yes (`xdotool`) | **not available** — Wayland does not tell other programs | not available |
| Close an app politely | yes (`wmctrl`) | **not available** — say "force quit" to end it | yes (`swaymsg`) |
| Keyboard shortcuts in other apps | yes (`xdotool`) | **not available** | yes (`wtype`) |
| Screenshot | `scrot`, `maim`, ImageMagick, `gnome-screenshot` | `gnome-screenshot`, `spectacle` | `grim` |
| Status icon | AppIndicator | GNOME: needs the AppIndicator extension (Ubuntu ships it) | depends on the bar |

These Wayland limits are the desktop's security design; Jarvis says when something is not
available instead of working around it.

Removing Jarvis: [uninstall.md](uninstall.md). Problems: [troubleshooting.md](troubleshooting.md).
