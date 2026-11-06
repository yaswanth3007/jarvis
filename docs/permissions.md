# Permissions

Every action passes three separate checks, in this order, on every platform.

| Layer | Who owns it | What it covers | Can Jarvis change it? |
|---|---|---|---|
| **A. Operating-system permission** | macOS (TCC), Windows privacy settings, the Linux desktop | microphone, camera, screen recording, accessibility, automation | **No.** Jarvis asks you to change it and opens the right settings page; it never edits a protected permission database and never claims a change it did not see. |
| **B. Jarvis capability** | you, through Jarvis's own store | camera, screen, files (per folder), shell, apps (per app), web, integrations | Only from your own spoken (or typed `jarvis answer`) decision. |
| **C. Action authorization** | you, every time | anything you did not ask for, and every sensitive action (deleting, sending, buying, installing, sudo, security settings, running a program file) | Never remembered: asked aloud each time. |

## A. What each operating system controls

- **macOS** — TCC asks you the first time for the microphone, speech recognition, camera,
  screen recording, accessibility and automation; Jarvis Voice guides you to System Settings
  and reports honestly what macOS granted (`jarvisctl status`). Managed (MDM) Macs may block
  Accessibility entirely.
- **Windows** — Settings → Privacy & security → **Microphone** and **Camera** ("Let desktop apps
  access…"). Windows does not let a normal program automate apps that run as administrator;
  Jarvis reports that instead of trying to elevate.
- **Linux** — usually no microphone prompt; the camera needs access to `/dev/video*` (often the
  `video` group). Wayland sessions deliberately stop one program from reading which window is in
  front, closing other apps' windows or sending keys (GNOME/KDE); screenshots go through the
  desktop's own tools. AT-SPI must be available for reading and operating windows.

Jarvis never bypasses any of these, never runs `sudo`, and never changes system security
settings. "Stop using the camera" revokes **Jarvis's own** permission and says so; the OS
setting is unchanged.

## B. Jarvis's own permissions (Ask / Allow / Revoke)

Stored in `permissions.json` in the settings folder (see [architecture](architecture.md#files)),
readable only by you, written only by the voice assistant, and read fresh by the bridge on every
decision — a revoke applies to the very next action. A damaged file is never read as "allow".

| Capability | Default | Meaning |
|---|---|---|
| `web` | allow | web search and public pages |
| `apps.open` / `apps.close` | allow | opening / closing apps you named |
| `app` (per app) | ask | reading or operating inside an app |
| `camera`, `screen` | ask | looking through the camera / at the screen |
| `files.read` / `files.write` (per folder) | ask | reading / changing files; a decision covers that folder only |
| `shell` | ask | look-only commands (`ls`, `git status`…) can be allowed; everything else is confirmed every time |
| `integration` | ask | Claude Code integrations that change things |

Answers: **"allow"** / **"yes"** (this conversation), **"allow once"**, **"allow always"**
(remembered), **"no"**, **"never"** (remembered). Anything unclear is not an approval: Jarvis asks
once more, then treats silence as "no".

Spoken commands (the same on every OS): "What permissions do you have?", "Stop controlling
applications", "Stop opening apps", "Stop using the camera", "Revoke camera access", "Don't allow
you to control Chrome", "Allow opening apps", "Reset all permissions".

## C. Rules the broker always applies

- **Act only on explicit instructions**; reading something is never permission to act on it.
- **Messages**: typing is not sending. A send needs the word "send" in your request, and a fresh
  read of the window (right app, recipient, conversation and text) right before; never inside a
  multi-step plan.
- **Shell**: a command is read out in full before it runs unless it is a look-only command you
  allowed; commands longer than 200 characters are refused. Typing into a terminal and pressing
  Enter counts as running a command (Terminal, iTerm, Windows Terminal, PowerShell, cmd, GNOME
  Terminal, Konsole…). PowerShell on Windows follows the same rules as Bash.
- **Program files**: opening `.app`, `.command`, `.exe`, `.msi`, `.ps1`, `.bat`, `.lnk`,
  `.desktop`, `.AppImage`, `.deb`, `.rpm`… is confirmed every time.
- **Integrations**: look-ups run; actions (forward, reply, schedule, trash…) are confirmed each
  time, naming who or what they affect.
- **Sub-agents and scheduled or background agents** are refused for voice requests.
- **Acting inside an app must name the app** — the app in front can change between the check
  and the action.

Every decision is appended to `permission-history.jsonl` in the settings folder.
