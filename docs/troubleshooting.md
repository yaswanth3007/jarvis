# Troubleshooting

Start with **`jarvis doctor`** (on macOS: `macos/jarvisctl doctor`). It prints what this computer
can do, why anything is missing, and what to install or switch on. `jarvis status` shows the
services and the voice assistant; `jarvis logs voice` (or `agent`, `bridge`, `face`,
`voice-engine`) shows the last lines of a log. Logs never contain what you said unless you turn
on `"logTranscripts": true` in `config.json` — turn it off again afterwards.

| Symptom | Likely cause | Fix |
|---|---|---|
| Jarvis never wakes | microphone off or the wrong one | `jarvis devices`; Windows: Privacy & security → Microphone; set `"inputDevice"` in `config.json`; macOS: `jarvisctl devices` |
| "the speech models are not downloaded yet" | first run | `jarvis setup` (≈48 MB; on Linux needs `bzip2`) |
| Jarvis speaks with a robotic voice | the Kokoro engine is still downloading its model (≈90 MB, once) or not running | wait for `voice-engine: running` in `jarvis status`; `jarvis logs voice-engine` |
| "I can't reach my brain" | the agent isn't running, or Claude Code isn't signed in | `jarvis start`; run `claude` once and log in |
| Log says "refused: not this computer's bridge" | something else is using port 8787 | stop it, or set `JARVIS_BRIDGE_PORT` in `agent.env` and `"bridgeURL"` in `config.json` |
| "cannot prove it is this user's" in a log | another account's Jarvis, or a stranger, holds a port or pipe | nothing is sent to it; stop the other process |
| Windows: no icon in the notification area | hidden in the overflow menu | Settings → Personalization → Taskbar → Other system tray icons |
| Windows: an app can't be read or controlled | it runs as administrator | Windows doesn't let normal programs automate elevated apps |
| Windows: "look at this" fails | no camera support without ffmpeg | install ffmpeg (on PATH) and allow desktop apps to use the camera |
| Linux: "AT-SPI is not available" | accessibility libraries missing | `python3-gi` and `gir1.2-atspi-2.0` (Debian/Ubuntu) or `python3-gobject` and `at-spi2-core` (Fedora) |
| Linux: an app's window reads as empty | the app doesn't expose accessibility | GTK, Qt, Firefox, LibreOffice do; Chromium/Electron apps may need `--force-renderer-accessibility` |
| Linux: can't close apps / press keys / see the front window | Wayland (GNOME/KDE) doesn't allow it | expected; use an X11 session if you need those, or say "force quit" to close |
| Linux: no status icon on GNOME | GNOME needs the AppIndicator extension | install/enable it (Ubuntu has it on by default) |
| Linux: `jarvis-voice.service` doesn't start | the session didn't start `graphical-session.target`, or DISPLAY isn't in the user manager | `systemctl --user status jarvis-voice`; `systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP` then `systemctl --user restart jarvis-voice` |
| macOS: Accessibility actions never work | the Mac is managed (MDM) and blocks it | ask your administrator; reading through the camera and screen still work if granted |
| macOS: Screen Recording stays "not granted" | macOS hasn't applied the switch | switch it off and on in System Settings, then "Quit & Reopen"; `jarvisctl status` shows what macOS reports |

A permission that seems stuck: ask "What permissions do you have?", or look at `permissions.json`
in the settings folder. `jarvis uninstall --purge` (macOS: `jarvisctl uninstall`) starts over.
