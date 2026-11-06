# Uninstalling Jarvis

Uninstalling removes the login services and stops Jarvis. Your settings, Jarvis's own
permissions, the per-install key, logs and downloaded models are kept unless you ask for them to
be deleted. Nothing in the operating system's own permission settings is touched — remove Jarvis
from those yourself if you want to (macOS System Settings → Privacy & Security; Windows Settings
→ Privacy & security).

## macOS

```bash
macos/jarvisctl uninstall
```

This stops and removes the two LaunchAgents and `~/Applications/JarvisVoice.app`. To delete
everything else as well — settings, Jarvis's permissions, the key, logs, the voice model, and the
app's own microphone/speech entries in macOS's privacy settings (through Apple's `tccutil`):

```bash
macos/jarvisctl uninstall --purge
```

If you created the signing certificate (`jarvisctl signing-identity`):

```bash
security delete-identity -c "Jarvis Voice Local Signing"
```

## Windows

- Installed with the setup program: **Settings → Apps → Installed apps → Jarvis → Uninstall**
  (or Start menu → Jarvis → Uninstall Jarvis). It runs `jarvis uninstall` first, then removes
  `%LOCALAPPDATA%\Programs\Jarvis`.
- From the zip or a clone: `jarvis uninstall` (or `node bin\jarvis.mjs uninstall`), then delete the folder.

`jarvis uninstall --purge` also deletes `%LOCALAPPDATA%\Jarvis` (settings, permissions, key, logs, models).

## Linux

```bash
jarvis uninstall
```

This stops and disables `jarvis-agent.service` and `jarvis-voice.service` (or removes the XDG
autostart entries) and deletes the unit files. `jarvis uninstall --purge` also deletes
`~/.config/jarvis`, `~/.local/state/jarvis` and `~/.cache/jarvis`. Then, if you installed the
.deb: `sudo apt remove jarvis` (each user who ran `jarvis install` should run `jarvis uninstall`
first; the package cannot remove per-user services itself).
