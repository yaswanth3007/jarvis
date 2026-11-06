/**
 * What this computer can do, honestly.
 *
 * Every capability Jarvis has is reported with how it is done on this OS (the
 * native API or tool used), whether it is available right now, and — when it is
 * not — why, and what would make it available. The voice assistant tells Claude
 * (and so the user) about anything missing instead of pretending; `jarvis doctor`
 * prints the same report.
 *
 * Nothing here changes the system: it only looks for programs on PATH, loadable
 * modules and the session type.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readdirSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { arch as osArch, release } from 'node:os'
import path from 'node:path'
import { modelStatus } from './models.mjs'
import { jarvisPaths, osName } from './paths.mjs'

const require = createRequire(import.meta.url)

/** A program on PATH (with PATHEXT on Windows), or null. */
export function findOnPath(name, env = process.env, platform = process.platform) {
  const p = platform === 'win32' ? path.win32 : path.posix
  const dirs = String(env.PATH ?? env.Path ?? '').split(platform === 'win32' ? ';' : ':').filter(Boolean)
  const exts = platform === 'win32' ? ['', ...String(env.PATHEXT ?? '.EXE;.CMD;.BAT;.COM').split(';').map((e) => e.toLowerCase())] : ['']
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = p.join(dir, name + ext)
      try {
        if (statSync(full).isFile()) return full
      } catch {
        /* not here */
      }
    }
  }
  return null
}

const first = (names, env, platform) => {
  for (const n of names) if (findOnPath(n, env, platform)) return n
  return null
}

function resolvable(id) {
  try {
    require.resolve(id)
    return true
  } catch {
    return false
  }
}

/** Python with the GObject introspection module and a given namespace (AT-SPI, AppIndicator). */
function pythonGi(namespaces, env) {
  if (!findOnPath('python3', env, 'linux')) return null
  for (const [ns, version] of namespaces) {
    const r = spawnSync('python3', ['-I', '-c', `import gi; gi.require_version('${ns}', '${version}'); from gi.repository import ${ns}`],
      { stdio: 'ignore', timeout: 5000 })
    if (r.status === 0) return ns
  }
  return null
}

export function linuxSession(env = process.env) {
  const type = (env.XDG_SESSION_TYPE || (env.WAYLAND_DISPLAY ? 'wayland' : env.DISPLAY ? 'x11' : 'tty')).toLowerCase()
  const desktop = env.XDG_CURRENT_DESKTOP || env.DESKTOP_SESSION || ''
  const wlroots = Boolean(env.SWAYSOCK || env.HYPRLAND_INSTANCE_SIGNATURE) || /sway|hyprland|river|wayfire|labwc|niri/i.test(desktop)
  // X11 tools also work for X11 apps under XWayland, but not for native Wayland windows.
  return { type, desktop, wlroots, x11: type === 'x11' && Boolean(env.DISPLAY), wayland: type === 'wayland' }
}

export function sherpaAvailable(platform = process.platform, arch = process.arch) {
  const plat = platform === 'win32' ? 'win' : platform
  return resolvable('sherpa-onnx-node') && resolvable(`sherpa-onnx-${plat}-${arch}/package.json`)
}

/**
 * @returns {{os, arch, release, node, session?, capabilities: Record<string, {available: boolean, via: string, needs?: string, reason?: string}>}}
 */
export function detectCapabilities({ env = process.env, platform = process.platform, deep = true } = {}) {
  const os = osName(platform)
  const caps = {}
  const set = (key, available, via, extra = {}) => {
    caps[key] = { available: Boolean(available), via, ...extra }
  }
  const report = { os, arch: osArch(), release: release(), node: process.version, capabilities: caps }

  if (os === 'macos') {
    // Done natively by Jarvis Voice (Swift); macOS itself (TCC) grants or refuses each one.
    // `jarvisctl status` shows what macOS has actually granted.
    set('voice.wake', true, 'Apple Speech (SpeechAnalyzer) in Jarvis Voice', { needs: 'Microphone and Speech Recognition permission' })
    set('voice.stt', true, 'Apple Speech (on device)', { needs: 'Speech Recognition permission' })
    set('voice.tts', true, 'Kokoro voice engine, macOS voices as fallback')
    set('audio.input', true, 'Core Audio (AVAudioEngine)', { needs: 'Microphone permission' })
    set('audio.output', true, 'Core Audio (AVAudioPlayer)')
    set('apps.list', true, 'NSWorkspace')
    set('apps.open', true, 'NSWorkspace')
    set('apps.close', true, 'NSRunningApplication.terminate (apps still ask about unsaved work)')
    set('window.read', true, 'Accessibility (AXUIElement)', { needs: 'Accessibility permission' })
    set('window.control', true, 'Accessibility + CGEvent', { needs: 'Accessibility permission' })
    set('screen', true, 'ScreenCaptureKit', { needs: 'Screen Recording permission' })
    set('camera', true, 'AVFoundation', { needs: 'Camera permission' })
    set('automation', true, 'Apple Events', { needs: 'Automation permission per app' })
    set('tray', true, 'menu bar item (NSStatusItem)')
    set('notifications', true, 'UserNotifications')
    set('autostart', true, 'launchd LaunchAgents (local.jarvis.agent, local.jarvis.voice)')
    return report
  }

  const speech = sherpaAvailable(platform)
  const models = modelStatus(jarvisPaths({ platform, env }).models)
  const speechWhy = !speech
    ? `sherpa-onnx has no build for ${platform}-${osArch()} installed (run npm install)`
    : !models.all ? 'the speech models are not downloaded yet (run: jarvis setup)' : undefined

  if (os === 'windows') {
    const ps = findOnPath('powershell', env, platform)
    const why = ps ? undefined : 'Windows PowerShell (powershell.exe) was not found'
    const recorder = resolvable('@picovoice/pvrecorder-node')
    set('voice.wake', speech && models.kws && recorder, 'sherpa-onnx keyword spotter (offline)', { reason: speechWhy ?? (!recorder ? 'the microphone module is not installed' : undefined) })
    set('voice.stt', speech && models.asr && models.vad, 'sherpa-onnx Moonshine + Silero VAD (offline)', { reason: speechWhy })
    set('voice.tts', Boolean(ps), 'Kokoro voice engine; Windows SAPI voice as fallback', { reason: why })
    set('audio.input', recorder, 'WASAPI (PvRecorder)', {
      needs: 'Settings → Privacy & security → Microphone → "Let desktop apps access your microphone"',
      reason: recorder ? undefined : 'the microphone module (@picovoice/pvrecorder-node) is not installed',
    })
    set('audio.output', Boolean(ps), 'System.Media.SoundPlayer', { reason: why })
    set('apps.list', Boolean(ps), 'Get-StartApps (Start menu apps, including Store apps)', { reason: why })
    set('apps.open', Boolean(ps), 'shell:AppsFolder (the same launch the Start menu does)', { reason: why })
    set('apps.close', Boolean(ps), 'CloseMainWindow (apps still ask about unsaved work)', { reason: why })
    set('window.read', Boolean(ps), 'UI Automation', { reason: why, needs: 'nothing; apps running as administrator cannot be read from a normal account' })
    set('window.control', Boolean(ps), 'UI Automation + SendKeys', { reason: why })
    set('screen', Boolean(ps), 'GDI screen copy (System.Drawing)', { reason: why })
    const ffmpeg = findOnPath('ffmpeg', env, platform)
    set('camera', Boolean(ffmpeg), 'ffmpeg (DirectShow)', {
      needs: 'Settings → Privacy & security → Camera → "Let desktop apps access your camera"',
      reason: ffmpeg ? undefined : 'Windows has no built-in way for a background program to take a photo; install ffmpeg to enable it',
    })
    set('automation', false, '—', { reason: 'Apple Events are macOS only; on Windows, apps are controlled through UI Automation' })
    set('tray', Boolean(ps), 'notification-area icon (NotifyIcon)', { reason: why })
    set('notifications', Boolean(ps), 'notification-area balloons', { reason: why })
    set('autostart', Boolean(findOnPath('reg', env, platform)), 'HKCU\\…\\Run (per user, no administrator rights)')
    return report
  }

  // Linux (and other Unix desktops)
  const s = linuxSession(env)
  report.session = s
  const mic = first(['pw-record', 'parec', 'arecord'], env, platform)
  const player = first(['pw-play', 'paplay', 'aplay'], env, platform)
  const sysVoice = first(['espeak-ng', 'espeak', 'spd-say'], env, platform)
  const atspi = deep ? pythonGi([['Atspi', '2.0']], env) : null
  const indicator = deep ? pythonGi([['AyatanaAppIndicator3', '0.1'], ['AppIndicator3', '0.1']], env) : null
  const appDirs = [env.XDG_DATA_HOME || path.join(env.HOME ?? '', '.local/share'), ...(env.XDG_DATA_DIRS || '/usr/local/share:/usr/share').split(':')]
    .map((d) => path.join(d, 'applications'))
    .filter((d) => {
      try {
        return readdirSync(d).some((f) => f.endsWith('.desktop'))
      } catch {
        return false
      }
    })
  const launcher = first(['gtk-launch', 'gio'], env, platform)
  const sessionWhy = s.type === 'tty' ? 'no graphical session (DISPLAY / WAYLAND_DISPLAY are not set)' : undefined

  set('voice.wake', speech && models.kws && Boolean(mic), 'sherpa-onnx keyword spotter (offline)', { reason: speechWhy ?? (!mic ? 'no recorder: install pipewire (pw-record), pulseaudio-utils (parec) or alsa-utils (arecord)' : undefined) })
  set('voice.stt', speech && models.asr && models.vad, 'sherpa-onnx Moonshine + Silero VAD (offline)', { reason: speechWhy })
  set('voice.tts', Boolean(player) || Boolean(sysVoice), `Kokoro voice engine${sysVoice ? `; ${sysVoice} as fallback` : ''}`,
    { reason: player || sysVoice ? undefined : 'no audio player: install pipewire (pw-play), pulseaudio-utils (paplay) or alsa-utils (aplay)' })
  set('audio.input', Boolean(mic), mic ? `${mic} (${mic === 'arecord' ? 'ALSA' : mic === 'parec' ? 'PulseAudio' : 'PipeWire'})` : '—',
    { reason: mic ? undefined : 'no recorder: install pipewire (pw-record), pulseaudio-utils (parec) or alsa-utils (arecord)' })
  set('audio.output', Boolean(player), player ?? '—', { reason: player ? undefined : 'no audio player found' })
  set('apps.list', appDirs.length > 0, 'XDG .desktop entries', { reason: appDirs.length ? undefined : 'no .desktop application entries found' })
  set('apps.open', appDirs.length > 0 && !sessionWhy, launcher ? `${launcher} (desktop entries)` : 'desktop entry Exec line', { reason: sessionWhy })
  const closer = s.x11 ? first(['wmctrl', 'xdotool'], env, platform) : s.wlroots ? first(['swaymsg'], env, platform) : null
  set('apps.close', Boolean(closer), closer ? `${closer} (a normal close request; apps still ask about unsaved work)` : '—', {
    reason: closer ? undefined
      : s.x11 ? 'install wmctrl or xdotool to close windows politely'
        : `${s.desktop || 'this'} Wayland session gives other programs no way to ask an app to close; "force quit" still works`,
  })
  set('window.read', Boolean(atspi) && !sessionWhy, 'AT-SPI accessibility', {
    reason: sessionWhy ?? (atspi ? undefined : 'AT-SPI is not available to Jarvis: install python3-gi and gir1.2-atspi-2.0 (Debian/Ubuntu) or python3-gobject and at-spi2-core (Fedora)'),
    needs: 'accessibility enabled for apps (GNOME: on by default; some apps need toolkit-accessibility)',
  })
  const typer = s.x11 ? first(['xdotool'], env, platform) : s.wlroots ? first(['wtype'], env, platform) : null
  set('window.control', Boolean(atspi) || Boolean(typer), [atspi && 'AT-SPI actions', typer].filter(Boolean).join(' + ') || '—', {
    reason: atspi || typer ? undefined : s.wayland ? 'install python3-gi + gir1.2-atspi-2.0 (clicks, text) and wtype (keys, wlroots only)' : 'install xdotool and python3-gi + gir1.2-atspi-2.0',
  })
  const shooter = s.wayland
    ? first(s.wlroots ? ['grim'] : /kde/i.test(s.desktop) ? ['spectacle'] : ['gnome-screenshot', 'spectacle', 'grim'], env, platform)
    : s.x11 ? first(['gnome-screenshot', 'spectacle', 'scrot', 'maim', 'import'], env, platform) : null
  set('screen', Boolean(shooter), shooter ?? '—', {
    reason: shooter ? undefined : sessionWhy ?? (s.wayland ? 'install gnome-screenshot (GNOME), spectacle (KDE) or grim (wlroots)' : 'install scrot, maim, gnome-screenshot or ImageMagick'),
  })
  const cam = first(['ffmpeg', 'fswebcam'], env, platform)
  const videoDevice = existsSync('/dev') && readdirSafe('/dev').some((d) => /^video\d+$/.test(d))
  set('camera', Boolean(cam) && videoDevice, cam ? `${cam} (V4L2)` : '—', {
    reason: !cam ? 'install ffmpeg or fswebcam' : !videoDevice ? 'no camera (/dev/video*) found' : undefined,
    needs: 'membership of the "video" group on some distributions',
  })
  set('automation', false, '—', { reason: 'Apple Events are macOS only; on Linux, apps are controlled through AT-SPI' })
  set('tray', Boolean(indicator) && !sessionWhy, indicator ? `${indicator} (StatusNotifierItem)` : '—', {
    reason: indicator ? undefined : 'install gir1.2-ayatanaappindicator3-0.1 (GNOME also needs the AppIndicator extension); status is still in `jarvis status`',
  })
  set('notifications', Boolean(findOnPath('notify-send', env, platform)), 'notify-send')
  const systemd = Boolean(findOnPath('systemctl', env, platform)) && Boolean(env.XDG_RUNTIME_DIR) && existsSync(path.join(env.XDG_RUNTIME_DIR ?? '/nonexistent', 'systemd'))
  set('autostart', true, systemd ? 'systemd --user units' : 'XDG autostart entry (~/.config/autostart)')
  return report
}

function readdirSafe(dir) {
  try {
    return readdirSync(dir)
  } catch {
    return []
  }
}

/** The capabilities, as one line each, for `jarvis doctor` and the assistant's own prompt. */
export function describeCapabilities(report) {
  return Object.entries(report.capabilities).map(([key, c]) =>
    `${c.available ? 'yes' : 'no '}  ${key.padEnd(15)} ${[c.via !== '—' ? c.via : '', c.reason].filter(Boolean).join(' — ')}${c.needs && c.available ? ` (needs: ${c.needs})` : ''}`)
}
