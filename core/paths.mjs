/**
 * Where Jarvis keeps its per-user files, on each operating system.
 *
 * Nothing here is hard-coded to one machine: every location is derived from the
 * user's home folder and the platform's own conventions, and can be moved with an
 * environment variable.
 *
 *              support (settings, key, permissions)    logs                         cache (models)
 *   macOS      ~/Library/Application Support/JarvisVoice ~/Library/Logs/Jarvis       ~/Library/Caches/JarvisVoice
 *   Windows    %LOCALAPPDATA%\Jarvis                    %LOCALAPPDATA%\Jarvis\Logs  %LOCALAPPDATA%\Jarvis\Cache
 *   Linux      $XDG_CONFIG_HOME/jarvis (~/.config)      $XDG_STATE_HOME/jarvis/logs $XDG_CACHE_HOME/jarvis
 *
 * macOS keeps the folders Jarvis Voice has always used, so existing settings,
 * permissions and the per-install key carry on unchanged. Windows uses the local
 * (not roaming) profile: the key and permissions belong to this machine.
 *
 * Overrides: JARVIS_HOME (support), JARVIS_LOG_DIR, JARVIS_CACHE_DIR, and the
 * older single-file ones JARVIS_VOICE_KEY_FILE and JARVIS_PERMISSIONS_FILE.
 */
import { homedir, userInfo } from 'node:os'
import path from 'node:path'

/** The OS name Jarvis uses everywhere: macos | windows | linux (other Unixes count as linux). */
export function osName(platform = process.platform) {
  if (platform === 'darwin') return 'macos'
  if (platform === 'win32') return 'windows'
  return 'linux'
}

export function jarvisPaths({ platform = process.platform, env = process.env, home = homedir(), user } = {}) {
  const p = platform === 'win32' ? path.win32 : path.posix
  // XDG variables only count when absolute (the spec says to ignore relative ones).
  const absolute = (v) => (typeof v === 'string' && v && p.isAbsolute(v) ? v : null)
  let support
  let logs
  let cache
  let runtime
  if (platform === 'darwin') {
    support = p.join(home, 'Library', 'Application Support', 'JarvisVoice')
    logs = p.join(home, 'Library', 'Logs', 'Jarvis')
    cache = p.join(home, 'Library', 'Caches', 'JarvisVoice')
    runtime = support
  } else if (platform === 'win32') {
    const local = absolute(env.LOCALAPPDATA) ?? p.join(home, 'AppData', 'Local')
    support = p.join(local, 'Jarvis')
    logs = p.join(support, 'Logs')
    cache = p.join(support, 'Cache')
    runtime = support
  } else {
    support = p.join(absolute(env.XDG_CONFIG_HOME) ?? p.join(home, '.config'), 'jarvis')
    logs = p.join(absolute(env.XDG_STATE_HOME) ?? p.join(home, '.local', 'state'), 'jarvis', 'logs')
    cache = p.join(absolute(env.XDG_CACHE_HOME) ?? p.join(home, '.cache'), 'jarvis')
    const run = absolute(env.XDG_RUNTIME_DIR)
    runtime = run ? p.join(run, 'jarvis') : support
  }
  support = absolute(env.JARVIS_HOME) ?? support
  logs = absolute(env.JARVIS_LOG_DIR) ?? logs
  cache = absolute(env.JARVIS_CACHE_DIR) ?? cache
  if (absolute(env.JARVIS_HOME) && platform !== 'darwin') runtime = support

  let name = user
  if (!name) {
    try {
      name = userInfo().username
    } catch {
      name = env.USERNAME ?? env.USER ?? 'user'
    }
  }
  const safeUser = String(name).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 40) || 'user'

  return {
    os: osName(platform),
    home,
    support,
    logs,
    cache,
    runtime,
    models: p.join(cache, 'models'),
    key: absolute(env.JARVIS_VOICE_KEY_FILE) ?? p.join(support, 'bridge.key'),
    permissions: absolute(env.JARVIS_PERMISSIONS_FILE) ?? p.join(support, 'permissions.json'),
    history: absolute(env.JARVIS_PERMISSION_HISTORY) ?? p.join(support, 'permission-history.jsonl'),
    config: p.join(support, 'config.json'),
    agentEnv: p.join(support, 'agent.env'),
    agentStatus: p.join(support, 'agent-status.json'),
    voiceStatus: p.join(support, 'voice-status.json'),
    // The voice assistant's local control channel (status, ask, answer, tasks…).
    // macOS: Jarvis Voice's own socket. Windows: a named pipe (per user; both ends
    // also prove they hold the per-install key). Linux: a socket in the runtime dir.
    control: platform === 'win32' ? `\\\\.\\pipe\\jarvis-voice-${safeUser}` : p.join(runtime, 'control.sock'),
  }
}

export const paths = jarvisPaths()

/** The stop/status channel of core/keepalive.mjs for "agent" or "voice". */
export function keepaliveChannel(which, p = paths, platform = process.platform) {
  return platform === 'win32'
    ? p.control.replace('jarvis-voice-', `jarvis-keepalive-${which}-`)
    : path.posix.join(p.runtime, `keepalive-${which}.sock`)
}
