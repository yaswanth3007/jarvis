/**
 * The permission broker for the voice assistant (Jarvis Voice on macOS, Windows and Linux).
 *
 * Active only for connections from Jarvis Voice (the macOS menu bar app, or the
 * Windows/Linux voice assistant in client/) when the
 * bridge runs with JARVIS_PERMISSIONS=1 — the web interface and a plain
 * `npm start` keep exactly the behaviour they had before.
 *
 * Every tool call passes three separate checks, in this order:
 *
 *   A. macOS permission   — camera, microphone, screen recording, accessibility,
 *                           automation. Owned by macOS (TCC). Jarvis Voice asks
 *                           through Apple's own prompts when it executes the action;
 *                           nothing here can grant or revoke them.
 *   B. Jarvis capability  — what YOU allow Jarvis to do: use the camera, read files
 *                           in a folder, run shell commands, control a given app…
 *                           Stored in permissions.json in Jarvis's support folder
 *                           (core/paths.mjs; on macOS ~/Library/Application Support/
 *                           JarvisVoice/) — written only by Jarvis Voice, from your
 *                           spoken answers and commands). Unknown → Jarvis asks you.
 *   C. Action authorization — whether THIS action is what you asked for. A tool call
 *                           with consequences that your request did not mention, or
 *                           any sensitive action (deleting, sending, buying,
 *                           installing, sudo, security settings…), is confirmed with
 *                           you aloud first, every time, whatever B says.
 *
 * A PreToolUse hook sees every tool call — including the ones the Claude CLI would
 * otherwise wave through on its own — and can only block or continue. It never
 * widens what the bridge's own decideTool() gate allows.
 *
 * Approvals come only from your spoken answer to a question Jarvis asked, parsed on
 * the Mac — never from the model, a web page, a document or a tool result.
 */
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, resolve, sep } from 'node:path'
import { paths } from '../core/paths.mjs'

const HOME = homedir()
// JARVIS_PERMISSIONS_FILE / JARVIS_PERMISSION_HISTORY (absolute) override these, so tests can
// run against a scratch copy.
const STORE = paths.permissions
const HISTORY = paths.history

/**
 * The MCP servers that act on this computer through Jarvis Voice: jarvis_mac (macOS) and
 * jarvis_desktop (Windows, Linux). Same tool names, same rules.
 */
const DEVICE_SERVERS = new Set(['jarvis_mac', 'jarvis_desktop'])
export const isDeviceServer = (server) => DEVICE_SERVERS.has(server)

/** What happens when you have not decided yet. */
const DEFAULTS = {
  web: 'allow',          // web search and fetching public pages
  'apps.open': 'allow',  // opening an app, a URL, a folder or a Settings pane you asked for
  'apps.close': 'allow', // quitting an app you named (macOS still asks about unsaved work)
  app: 'ask',            // reading or controlling a particular app (per app)
  camera: 'ask',
  screen: 'ask',
  'files.read': 'ask',
  'files.write': 'ask',
  shell: 'ask',
  integration: 'ask',    // MCP integrations that change things
}

const CAPABILITY_NAMES = {
  web: 'search the web',
  'apps.open': 'open apps',
  'apps.close': 'close apps',
  app: 'control',
  camera: 'use the camera',
  screen: 'look at your screen',
  'files.read': 'read files',
  'files.write': 'change files',
  shell: 'run commands',
  integration: 'use',
}

// --------------------------------------------------------------------------
// The store (read fresh on every decision, so a spoken "revoke" applies at once)
// --------------------------------------------------------------------------

export function loadStore() {
  try {
    if (!existsSync(STORE)) return { capabilities: {}, apps: {}, folders: [] }
    const raw = JSON.parse(readFileSync(STORE, 'utf8'))
    return {
      capabilities: raw.capabilities ?? {},
      apps: raw.apps ?? {},
      folders: Array.isArray(raw.folders) ? raw.folders : [],
      integrations: raw.integrations ?? {},
    }
  } catch {
    // A damaged file must never turn into "allow".
    return { capabilities: {}, apps: {}, folders: [], damaged: true }
  }
}

export function recordHistory(entry) {
  try {
    appendFileSync(HISTORY, `${JSON.stringify({ t: new Date().toISOString(), ...entry })}\n`, { mode: 0o600 })
  } catch {
    /* history is best effort */
  }
}

const expand = (p) => {
  if (typeof p !== 'string' || !p) return null
  const s = p.startsWith('~') ? join(HOME, p.slice(1)) : p
  return isAbsolute(s) ? resolve(s) : resolve(HOME, s)
}

/** The folder rule that applies to a path: the most specific one wins. */
function folderRule(store, path) {
  const full = expand(path)
  if (!full) return null
  let best = null
  for (const rule of store.folders) {
    const root = expand(rule.path)
    if (!root) continue
    if (full === root || full.startsWith(root.endsWith(sep) ? root : `${root}${sep}`)) {
      if (!best || root.length > expand(best.path).length) best = rule
    }
  }
  return best
}

// --------------------------------------------------------------------------
// Classification: what does this tool call actually do?
// --------------------------------------------------------------------------

const APP_IDS = {
  safari: 'com.apple.Safari', chrome: 'com.google.Chrome', 'google chrome': 'com.google.Chrome',
  finder: 'com.apple.finder', terminal: 'com.apple.Terminal', 'vs code': 'com.microsoft.VSCode',
  vscode: 'com.microsoft.VSCode', 'visual studio code': 'com.microsoft.VSCode', code: 'com.microsoft.VSCode',
  'system settings': 'com.apple.systempreferences', 'system preferences': 'com.apple.systempreferences',
  spotify: 'com.spotify.client', slack: 'com.tinyspeck.slackmacgap', mail: 'com.apple.mail',
  messages: 'com.apple.MobileSMS', notes: 'com.apple.Notes', textedit: 'com.apple.TextEdit',
  whatsapp: 'net.whatsapp.WhatsApp', telegram: 'ru.keepcoder.Telegram', signal: 'org.whispersystems.signal-desktop',
  discord: 'com.hnc.Discord', teams: 'com.microsoft.teams2', 'microsoft teams': 'com.microsoft.teams2',
  outlook: 'com.microsoft.Outlook', 'microsoft outlook': 'com.microsoft.Outlook', messenger: 'com.facebook.archon',
  skype: 'com.skype.skype', wechat: 'com.tencent.xinWeChat', imessage: 'com.apple.MobileSMS',
  iterm: 'com.googlecode.iterm2', iterm2: 'com.googlecode.iterm2', warp: 'dev.warp.Warp-Stable',
  kitty: 'net.kovidgoyal.kitty', alacritty: 'org.alacritty', wezterm: 'com.github.wez.wezterm',
  hyper: 'co.zeit.hyper', ghostty: 'com.mitchellh.ghostty',
  // Windows and Linux: the same idea — one stable key per app, whatever it is called.
  'windows terminal': 'Microsoft.WindowsTerminal', 'powershell': 'Microsoft.PowerShell',
  'windows powershell': 'Microsoft.PowerShell', pwsh: 'Microsoft.PowerShell', 'command prompt': 'Microsoft.CommandPrompt',
  cmd: 'Microsoft.CommandPrompt', 'gnome terminal': 'org.gnome.Terminal', 'gnome-terminal': 'org.gnome.Terminal',
  console: 'org.gnome.Console', kgx: 'org.gnome.Console', ptyxis: 'org.gnome.Ptyxis', konsole: 'org.kde.konsole',
  yakuake: 'org.kde.yakuake', xterm: 'xterm', uxterm: 'xterm', tilix: 'com.gexperts.Tilix', terminator: 'terminator',
  'xfce4 terminal': 'xfce4-terminal', 'xfce terminal': 'xfce4-terminal', lxterminal: 'lxterminal',
  'mate terminal': 'mate-terminal', foot: 'foot', guake: 'guake', urxvt: 'urxvt', 'rxvt unicode': 'urxvt',
  thunderbird: 'org.mozilla.thunderbird', evolution: 'org.gnome.Evolution', geary: 'org.gnome.Geary',
  element: 'im.riot.app', 'microsoft edge': 'com.microsoft.edgemac', edge: 'com.microsoft.edgemac',
  firefox: 'org.mozilla.firefox', 'file explorer': 'com.apple.finder', explorer: 'com.apple.finder',
  files: 'com.apple.finder', nautilus: 'com.apple.finder', dolphin: 'com.apple.finder',
}
/** "the WhatsApp app", "Whats App", "whatsapp.app" → the same key Jarvis Voice resolves them to. */
export const appKey = (name) => {
  const raw = String(name ?? '').trim().toLowerCase().replace(/\.app$/, '').replace(/^(the|my)\s+/, '').trim()
  const stripped = raw.replace(/\s+(app|application)$/, '').trim()
  for (const n of [raw, raw.replace(/[\s.-]+/g, ''), stripped, stripped.replace(/[\s.-]+/g, '')]) {
    if (APP_IDS[n]) return APP_IDS[n]
  }
  return stripped || raw || 'frontmost'
}
const appLabel = (name) => String(name ?? '').trim() || 'the current app'

/** Apps where typed text followed by Return runs as a shell command. */
const TERMINALS = new Set([
  'com.apple.Terminal', 'com.googlecode.iterm2', 'dev.warp.Warp-Stable', 'net.kovidgoyal.kitty', 'org.alacritty',
  'com.github.wez.wezterm', 'co.zeit.hyper', 'com.mitchellh.ghostty',
  'Microsoft.WindowsTerminal', 'Microsoft.PowerShell', 'Microsoft.CommandPrompt', 'org.gnome.Terminal', 'org.gnome.Console',
  'org.gnome.Ptyxis', 'org.kde.konsole', 'org.kde.yakuake', 'xterm', 'com.gexperts.Tilix', 'terminator', 'xfce4-terminal',
  'lxterminal', 'mate-terminal', 'foot', 'guake', 'urxvt',
])

/** Apps where Return or a Send button delivers a message to someone. */
const MESSAGING = new Set([
  'net.whatsapp.WhatsApp', 'com.apple.MobileSMS', 'com.tinyspeck.slackmacgap', 'ru.keepcoder.Telegram',
  'org.whispersystems.signal-desktop', 'com.hnc.Discord', 'com.microsoft.teams2', 'com.microsoft.teams', 'com.apple.mail',
  'com.microsoft.Outlook', 'com.facebook.archon', 'com.skype.skype', 'com.tencent.xinWeChat',
  'org.mozilla.thunderbird', 'org.gnome.Evolution', 'org.gnome.Geary', 'im.riot.app',
])
const isMessaging = (key) => MESSAGING.has(key)
const SEND_KEYS = /^\s*(return|enter|cmd\s*\+\s*(return|enter)|command\s*\+\s*(return|enter)|ctrl\s*\+\s*(return|enter)|cmd\s*\+\s*shift\s*\+\s*d)\s*$/i

/**
 * Did the user's own request say to send? Words they dictate in quotes are the message,
 * not an instruction ("type “please send me the file”" does not authorise sending).
 */
export function sendRequested(text) {
  const t = String(text ?? '').replace(/"[^"]*"|“[^”]*”/g, ' ')
  return /\b(send|post)\b/i.test(t)
}

/** Patterns that make a shell command sensitive. Each maps to a spoken reason. */
const SENSITIVE_COMMANDS = [
  [/(^|[\s;&|(])(sudo|doas|su)\s/, 'runs a command with administrator privileges'],
  [/(^|[\s;&|(])(rm|rmdir|unlink|shred|srm|trash)\s/, 'deletes files'],
  [/\bfind\b[^|;]*\s-(delete|exec\s+rm)\b/, 'deletes files'],
  [/\bmv\s[^;|&]*\.Trash\b/, 'moves files to the Trash'],
  [/\bgit\s+(push\s+[^;|&]*(-f\b|--force)|reset\s+--hard|clean\s+-[a-z]*f|branch\s+-D|checkout\s+--\s|restore\s)/, 'can discard work in a git repository'],
  [/\bgit\s+push\b/, 'publishes commits to a remote repository'],
  [/(^|[\s;&|(])(dd|mkfs\S*|fdisk|diskutil\s+(erase|partition|apfs\s+delete))\b/, 'can erase a disk'],
  [/(^|[\s;&|(])(kill|killall|pkill)\s/, 'stops running processes'],
  [/(^|[\s;&|(])chmod\s+-R|chown\s+-R/, 'changes permissions on many files'],
  [/\b(brew|port|pip3?|pipx|gem|cargo)\s+(install|uninstall|upgrade|remove)\b|\bnpm\s+(i|install|uninstall)\s+(-g|--global)\b|\bsoftwareupdate\b|\binstaller\s+-pkg\b/, 'installs or removes software'],
  [/\b(curl|wget)\b[^|;]*\|\s*(ba|z)?sh\b/, 'downloads and runs a script'],
  [/\b(curl|wget)\b[^;|&]*(\s-F\s|--data|\s-d\s|\s-T\s|--upload-file|-X\s*(POST|PUT|DELETE))/, 'sends data to the internet'],
  [/\b(defaults\s+(write|delete)|launchctl\s+(load|unload|bootstrap|bootout|enable|disable|remove)|systemsetup|networksetup|scutil\s+--set|pmset|nvram|csrutil|spctl|tccutil|profiles)\b/, 'changes system configuration'],
  [/\bsecurity\s+(add|delete|set|import|unlock|create)/, 'changes keychain or security settings'],
  [/\b(passwd|dscl\s+\S+\s+-passwd|chpass)\b/, 'changes a password'],
  [/\bosascript\b/, 'runs AppleScript, which can control other apps'],
  // A plain ">" replaces a file's contents; stderr redirects and /dev/null do not count.
  [/(^|[^0-9&>])>(?!>)\s*(?!\/dev\/null)[^&\s|]/, 'overwrites a file'],
  [/\b(scp|rsync|sftp|ftp)\b/, 'copies files to or from another machine'],
  [/\bmail\b\s+-s|\bsendmail\b/, 'sends email'],
]

const SENSITIVE_WORDS =
  /\b(send|post|publish|tweet|reply|share|upload|delete|remove|erase|trash|empty|buy|purchase|order|checkout|pay|payment|transfer|subscribe|install|uninstall|grant|allow|password|passcode|sign ?in|log ?in|sign ?out|confirm|submit|accept|agree)\b/i

function sensitiveCommand(cmd) {
  for (const [re, why] of SENSITIVE_COMMANDS) if (re.test(cmd)) return why
  return null
}

/**
 * Shell commands that only report and read no file contents, and so may run under a
 * standing "allow" (for this conversation, or always). This is an allow-list on purpose:
 * a list of dangerous commands can always be dodged (/bin/rm, `…`, python -c …). Anything
 * else — including any pipe, chaining, substitution or redirection — is confirmed every
 * time, with the whole command read out.
 */
const READ_ONLY_PROGRAMS = new Set(['ls', 'pwd', 'whoami', 'date', 'uname', 'sw_vers', 'uptime', 'which', 'df', 'du', 'hostname', 'id', 'cal'])
const GIT_READ = new Set(['status', 'log', 'diff', 'show', 'branch', 'remote', 'rev-parse', 'ls-files', 'blame', 'describe', 'shortlog'])
const SHELL_SYNTAX = /[;&|`$<>(){}\\\r\n]/
export const MAX_COMMAND = 200

export function readOnlyCommand(cmd) {
  const c = String(cmd ?? '').trim()
  if (!c || c.length > MAX_COMMAND || SHELL_SYNTAX.test(c)) return false
  const [program, ...args] = c.match(/"[^"]*"|'[^']*'|\S+/g) ?? []
  if (READ_ONLY_PROGRAMS.has(program)) return true
  if (program !== 'git') return false
  let rest = args
  while (rest[0] === '-C' && rest.length >= 2) rest = rest.slice(2) // git -C <folder> …
  // `git -c core.fsmonitor=…` and friends run arbitrary programs.
  if (rest.some((a) => /^(-c|--config-env|--exec-path|--output|-o|--ext-diff|--upload-pack|--receive-pack)(=|$)/.test(a))) return false
  if (!GIT_READ.has(rest[0])) return false
  if (rest[0] === 'branch' && rest.slice(1).some((a) => /^-[dDmMcCfu]$|^--(delete|move|copy|force|set-upstream|unset-upstream|edit-description)/.test(a))) return false
  if (rest[0] === 'remote' && rest.length > 1 && !['-v', '--verbose', 'show', 'get-url'].includes(rest[1])) return false
  return true
}

/** A shell command from Bash, run_in_terminal, or text typed and entered into a terminal. */
function shellCall(cmd, describeAs) {
  const command = String(cmd ?? '').replace(/\s+/g, ' ').trim()
  const lookOnly = readOnlyCommand(command)
  return {
    capability: 'shell',
    // Standing grants cover only the look-only commands; everything else is asked each time.
    target: lookOnly ? 'read-only commands' : 'shell',
    readOnly: false,
    intent: 'run',
    command,
    lookOnly,
    tooLong: command.length > MAX_COMMAND,
    summary: describeAs(command),
    sensitive: lookOnly ? null : (sensitiveCommand(command) ?? 'is not a read-only command, so it could change things on your computer'),
  }
}

/** "claude_ai_Gmail" → "Gmail". */
const serverLabel = (server) => String(server).replace(/^claude_ai_/i, '').replace(/[_-]+/g, ' ').trim()

/** Integration tools that only look things up. Everything else is an action and is confirmed. */
const READ_TOOL = /^(get|list|read|search|find|query|fetch|describe|inspect|show|view|lookup|count|check|status|info|browse|preview)(?:[_-]|$)/i
function integrationReadOnly(server, tool) {
  // "slack_read_channel" on the Slack server: the leading server name is not the verb.
  const lead = /^([a-z0-9]+)[_-]/i.exec(tool)?.[1]
  const name = lead && String(server).toLowerCase().includes(lead.toLowerCase()) ? tool.slice(lead.length + 1) : tool
  return READ_TOOL.test(name)
}

/** The arguments a person needs to hear before saying yes: who, where, what. */
function argsSummary(input) {
  const keys = ['to', 'cc', 'bcc', 'recipient', 'recipients', 'channel', 'channel_id', 'user', 'email', 'subject',
    'title', 'name', 'url', 'path', 'file_id', 'spreadsheet_id', 'message_id', 'messageId', 'text', 'body']
  const parts = []
  for (const k of keys) {
    const v = input?.[k]
    if (v === undefined || v === null || v === '') continue
    parts.push(`${k.replace(/_/g, ' ')}: ${shorten(Array.isArray(v) ? v.join(', ') : typeof v === 'object' ? JSON.stringify(v) : v, 50)}`)
    if (parts.length >= 4) break
  }
  return parts.length ? ` (${parts.join('; ')})` : ''
}

/** Opening these runs a program or installs something. */
const LAUNCHES = /\.(app|command|tool|sh|bash|zsh|csh|fish|terminal|workflow|action|pkg|mpkg|dmg|scpt|scptd|applescript|jar|py|rb|pl|php|js|mjs|bin|prefpane|kext|exe|msi|msix|msixbundle|appx|appxbundle|bat|cmd|com|ps1|psm1|vbs|vbe|jse|wsf|wsh|lnk|scr|cpl|hta|reg|url|desktop|appimage|run|deb|rpm|snap|flatpakref)[\\/]?$/i

const shorten = (s, n = 90) => {
  const t = String(s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > n ? `${t.slice(0, n - 1)}…` : t
}

/**
 * @returns {{internal?: true, capability?: string, target?: string, readOnly?: boolean,
 *            sensitive?: string|null, summary?: string, path?: string, intent?: string}}
 */
export function classify(toolName, input = {}) {
  const i = input ?? {}
  const m = /^mcp__([^_]+(?:_[^_]+)*?)__(.+)$/.exec(toolName)
  const server = m?.[1]
  const tool = m?.[2] ?? toolName

  // Internal plumbing and our own interface: nothing to ask about.
  if (['TodoWrite', 'ToolSearch', 'BashOutput', 'TaskOutput', 'ListMcpResources',
    'ListMcpResourcesTool', 'ReadMcpResource', 'ReadMcpResourceTool', 'KillShell', 'TaskStop'].includes(toolName)) {
    return { internal: true }
  }
  // Sub-agents and scheduled or background work would act outside the conversation the
  // user is in (and outside these checks' view of what they asked): not for a voice turn.
  if (['Task', 'Agent'].includes(toolName) || /^(Cron|Schedule|RemoteTrigger|Monitor)/.test(toolName)) {
    return { refuse: `${toolName} isn't available to Jarvis Voice. Do the task directly, one step at a time.` }
  }
  if (server === 'jarvis' || server === 'jarvis_ui') return { internal: true }
  if (isDeviceServer(server) && ['list_apps', 'permissions', 'permission_change', 'interface'].includes(tool)) {
    return { internal: true }
  }

  if (toolName === 'WebSearch' || toolName === 'WebFetch') {
    return { capability: 'web', target: 'web', readOnly: true, summary: 'search the web' }
  }

  if (['Read', 'Glob', 'Grep', 'NotebookRead', 'LS'].includes(toolName)) {
    const path = i.file_path ?? i.path ?? i.notebook_path ?? HOME
    return { capability: 'files.read', target: expand(path), path, readOnly: true,
      summary: `read ${shorten(path, 60)}` }
  }
  if (['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(toolName)) {
    const path = i.file_path ?? i.notebook_path ?? ''
    return { capability: 'files.write', target: expand(path), path, readOnly: false, intent: 'write',
      summary: `change the file ${shorten(path, 60)}`,
      sensitive: toolName === 'Write' && existsSync(expand(path) ?? '') ? 'overwrites an existing file' : null }
  }
  // Bash everywhere, and PowerShell where the Claude CLI offers it (Windows): the same rules.
  if (toolName === 'Bash' || toolName === 'PowerShell') {
    return shellCall(i.command, (cmd) => `run the command “${cmd}”`)
  }

  if (server === 'jarvis_eyes') {
    return { capability: 'camera', target: 'camera', readOnly: true, summary: 'use the camera' }
  }

  if (isDeviceServer(server)) {
    const app = i.app ?? i.name
    switch (tool) {
      case 'open_app':
      case 'switch_to_app':
        return { capability: 'apps.open', target: appKey(app), app, readOnly: false, intent: 'open',
          summary: `open ${appLabel(app)}` }
      case 'close_app':
        return { capability: 'apps.close', target: appKey(app), app, readOnly: false, intent: 'close',
          summary: `${i.force ? 'force quit' : 'close'} ${appLabel(app)}`,
          sensitive: i.force ? 'force quitting can lose unsaved work' : null }
      case 'open_url':
      case 'web_search':
        return { capability: 'apps.open', target: appKey(app ?? 'browser'), app, readOnly: false, intent: 'open',
          summary: tool === 'web_search' ? `search for ${shorten(i.query, 50)}` : `open ${shorten(i.url, 60)}` }
      case 'settings':
        return { capability: 'apps.open', target: 'com.apple.systempreferences', readOnly: false, intent: 'open',
          summary: `open the ${shorten(i.pane, 40)} settings` }
      case 'open_path':
        return { capability: 'apps.open', target: appKey(app ?? 'finder'), path: i.path, readOnly: false, intent: 'open',
          summary: `open ${shorten(i.path, 60)}${app ? ` in ${app}` : ''}`,
          sensitive: LAUNCHES.test(String(i.path ?? '')) ? 'would run a program or install something' : null }
      // Acting inside an app always names the app: the app in front can change between
      // the moment this is checked and the moment it happens.
      case 'read_window':
        return { capability: 'app', target: appKey(app), app, readOnly: true, summary: `read ${appLabel(app)}`, needsApp: !i.app }
      case 'read_screen':
        return { capability: 'screen', target: 'screen', app: i.app, readOnly: true, summary: 'look at your screen',
          needsApp: i.target === 'window' && !i.app }
      case 'click': {
        const sends = /\bsend\b/i.test(String(i.label ?? ''))
        return { capability: 'app', target: appKey(app), app, readOnly: false, intent: 'control', sends, needsApp: !i.app,
          summary: `click “${shorten(i.label, 40)}” in ${appLabel(app)}`,
          sensitive: SENSITIVE_WORDS.test(String(i.label ?? '')) ? `presses “${shorten(i.label, 40)}”` : null }
      }
      case 'type_text': {
        const key = appKey(app)
        const enters = i.submit === true || /[\r\n]/.test(String(i.text ?? ''))
        // Typed into a terminal and entered, text is a shell command: the shell rules apply.
        if (TERMINALS.has(key) && enters) {
          return { ...shellCall(i.text, (cmd) => `type and run “${cmd}” in ${appLabel(app)}`), app, appTarget: key, needsApp: !i.app }
        }
        // In a messaging app, Return sends.
        const sends = enters && isMessaging(key)
        return { capability: 'app', target: key, app, readOnly: false, intent: 'type', sends, submits: enters, needsApp: !i.app,
          summary: `type “${shorten(i.text, 50)}” in ${appLabel(app)}`,
          sensitive: !sends && enters && SENSITIVE_WORDS.test(String(i.field ?? '')) ? 'submits a form' : null }
      }
      case 'press_keys': {
        const key = appKey(app)
        const enter = SEND_KEYS.test(String(i.keys ?? ''))
        const sends = enter && isMessaging(key)
        return { capability: 'app', target: key, app, readOnly: false, intent: 'control', sends, needsApp: !i.app,
          sendKeys: enter,
          summary: `press ${shorten(i.keys, 30)} in ${appLabel(app)}`,
          sensitive: enter && TERMINALS.has(key) ? 'runs whatever is typed in the terminal'
            : /\b(cmd|command)\s*\+\s*(delete|backspace|q)\b|\bshift\s*\+\s*(cmd|command)\s*\+\s*delete\b/i.test(String(i.keys ?? ''))
              ? 'can delete or quit' : null }
      }
      case 'run_in_terminal':
        return shellCall(i.command, (cmd) => `run “${cmd}” in Terminal`)
      default:
        return { capability: 'app', target: appKey(app), app, readOnly: false, intent: 'control', summary: `${tool} in ${appLabel(app)}` }
    }
  }

  if (server === 'jarvis_chrome') {
    const read = /^(chrome_)?(status|tabs|read|get|list|find|screenshot|page|text|snapshot)/i.test(tool.replace(/^chrome_/, ''))
    const label = JSON.stringify(i).slice(0, 400)
    return { capability: 'app', target: 'com.google.Chrome', app: 'Chrome', readOnly: read, intent: read ? null : 'control',
      summary: read ? 'read Chrome' : `${tool.replace(/^chrome_/, '').replace(/_/g, ' ')} in Chrome`,
      sensitive: !read && SENSITIVE_WORDS.test(label) ? 'may send, buy, delete or submit something' : null }
  }

  // Any other MCP integration from Claude Code's configuration (Gmail, Slack, Drive…).
  // Only tools whose name says they look something up run without a question; every other
  // tool is an action outside this computer (forward, reply, schedule, trash, evaluate…) and is
  // confirmed each time, naming who or what it affects.
  if (server) {
    const read = integrationReadOnly(server, tool)
    return { capability: 'integration', target: server, readOnly: read, intent: read ? null : 'integration',
      summary: `use ${serverLabel(server)} to ${tool.replace(/[_-]/g, ' ')}${read ? '' : argsSummary(i)}`,
      sensitive: read ? null : `acts through ${serverLabel(server)}, outside this computer` }
  }

  return { capability: 'integration', target: toolName, readOnly: false, intent: 'integration', summary: `use ${toolName}` }
}

// --------------------------------------------------------------------------
// C. Did the user's own request ask for this kind of action?
// --------------------------------------------------------------------------

const INTENT_WORDS = {
  open: /\b(open|launch|start|show|bring up|go to|goto|switch|navigate|visit|search|look up|google|pull up|load|take me|play)\b/i,
  close: /\b(close|quit|exit|shut|kill|stop)\b/i,
  control: /\b(click|press|tap|select|choose|pick|type|enter|search|go to|navigate|scroll|play|pause|skip|open|fill|toggle|turn|set|change|switch|find|mute|unmute|next|previous|back|forward|refresh|reload|zoom|maximi[sz]e|minimi[sz]e)\b/i,
  type: /\b(type|enter|write|search|fill|put|say|reply|message|send|name|rename)\b/i,
  run: /\b(run|execute|command|terminal|shell|script|git|npm|node|python|make|build|test|install|list|check|status|compile|start|deploy|ls|cd)\b/i,
  write: /\b(write|save|create|make|edit|update|change|fix|add|append|rename|move|copy|note|draft|modify|replace|insert|generate)\b/i,
  integration: /\b(send|call|post|create|delete|remove|update|edit|write|install|launch|book|schedule|generate|make|upload|share|order)\b/i,
}

function requestedByUser(c, userText) {
  if (!c.intent) return true
  const re = INTENT_WORDS[c.intent]
  return re ? re.test(userText ?? '') : false
}

/** Camera vs screen: never use one when the user asked about the other. */
function senseMismatch(c, userText) {
  const t = userText ?? ''
  const screenish = /\b(screen|monitor|display|window|tab|page|app|application|error|dialog|desktop)\b/i.test(t)
  const cameraish = /\b(camera|in front of me|holding|hold up|my hand|this object|look at me|see me|webcam|room)\b/i.test(t)
  if (c.capability === 'camera') return screenish && !cameraish
  if (c.capability === 'screen') return cameraish && !screenish
  return false
}

// --------------------------------------------------------------------------
// B. Capability state
// --------------------------------------------------------------------------

function ruleFor(store, c) {
  if (c.capability === 'app' || c.capability === 'apps.open' || c.capability === 'apps.close') {
    const perApp = store.apps?.[c.target]
    if (perApp === 'deny') return 'deny'
    if (c.capability === 'app') return perApp ?? store.capabilities.app ?? DEFAULTS.app
    return store.capabilities[c.capability] ?? DEFAULTS[c.capability]
  }
  if (c.capability === 'files.read' || c.capability === 'files.write') {
    const folder = c.target ? folderRule(store, c.target) : null
    if (folder?.access === 'deny') return 'deny'
    if (folder?.access === 'allow' || (folder?.access === 'read' && c.capability === 'files.read')) return 'allow'
    return store.capabilities[c.capability] ?? DEFAULTS[c.capability]
  }
  if (c.capability === 'integration') {
    const v = store.integrations?.[c.target]
    if (v) return v
    return c.readOnly ? 'allow' : (store.capabilities.integration ?? DEFAULTS.integration)
  }
  return store.capabilities[c.capability] ?? DEFAULTS[c.capability] ?? 'ask'
}

/** The folder a file decision is remembered for. */
function scopeOf(c) {
  if ((c.capability === 'files.read' || c.capability === 'files.write') && c.target) {
    // The containing folder, with this OS's separators (on Windows a path has no "/" to split on,
    // and the scope must never widen to the whole drive).
    return c.capability === 'files.read' && !/\.[a-z0-9]{1,6}$/i.test(c.target) ? c.target : dirname(c.target)
  }
  return c.target
}

function describe(c) {
  switch (c.capability) {
    case 'app': return `control ${c.app ? appLabel(c.app) : 'that app'}`
    case 'files.read': return `read files in ${shorten(scopeOf(c)?.replace(HOME, '~') ?? 'that folder', 50)}`
    case 'files.write': return `change files in ${shorten(scopeOf(c)?.replace(HOME, '~') ?? 'that folder', 50)}`
    case 'integration': return `use ${c.target}`
    default: return CAPABILITY_NAMES[c.capability] ?? c.capability
  }
}

/** The question Jarvis asks, phrased the way a person would. */
function permissionQuestion(c) {
  switch (c.capability) {
    case 'camera': return 'I need camera access to do that. Would you like to allow it?'
    case 'screen': return 'I need to look at your screen to do that. Shall I allow it?'
    case 'files.read': return `I need permission to read files in ${shorten(scopeOf(c)?.replace(HOME, 'your home folder') ?? 'that folder', 60)}. Shall I proceed?`
    case 'files.write': return `I need permission to ${c.summary.replace(HOME, '~')}. Shall I proceed?`
    // Only look-only commands reach a plain permission question (all others are confirmed
    // one by one), and a yes covers just those: it is worded that way.
    case 'shell': return `I need permission to run commands that only look, like “${c.command}”. Shall I allow it?`
    case 'app': return c.readOnly
      ? `I need permission to read ${appLabel(c.app)}. Shall I allow it?`
      : `I need permission to control ${appLabel(c.app)}, to ${c.summary}. Shall I allow it?`
    default: return `I need permission to ${c.summary}. Shall I allow it?`
  }
}

// --------------------------------------------------------------------------
// The hook
// --------------------------------------------------------------------------

/**
 * @param {object} o
 * @param {(kind: string, args: object, timeoutMs?: number) => Promise<object>} o.ask  question to Jarvis Voice
 * @param {() => string} o.userText   the user's latest request, as spoken
 * @param {string} o.connection       an id for the history
 */
/** "[Mac: frontmost app is WhatsApp (window …); …]" → the frontmost app's key. */
function frontmostFrom(context) {
  const m = /frontmost app is ([^(;\]]+?)(?:\s*\(|;|\.\]|\])/.exec(String(context ?? ''))
  return m ? appKey(m[1].trim()) : 'frontmost'
}

/**
 * @param {object} o
 * @param {(kind: string, args: object, timeoutMs?: number) => Promise<object>} o.ask  question to Jarvis Voice
 * @param {() => string} o.userText   the user's latest request, as spoken
 * @param {() => string} [o.context]  the "[Mac: …]" line Jarvis Voice sent with it (which app is in front)
 * @param {string} o.connection       an id for the history
 */
export function permissionHook({ ask, userText, context = () => '', connection }) {
  const session = new Set() // "capability|scope" granted for this conversation (this connection only)
  // What this request has done, per app, in order: a message may be sent only after the
  // window was read (to verify app, recipient, conversation and text) since it was typed.
  const seen = { ask: null, n: 0, read: new Map(), typed: new Map() }
  const deny = (reason) => ({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  })
  const proceed = { continue: true }

  /** One action: 'proceed', 'deny' with a reason, or 'ask' with a question. Asks nothing itself. */
  const decide = (toolName, toolInput, said, store) => {
    const c = classify(toolName, toolInput)
    if (c.internal) return { verdict: 'proceed', c, quiet: true }
    if (c.refuse) return { verdict: 'deny', c, why: 'not available to Jarvis Voice', reason: c.refuse }
    // What is checked must be what is acted on: an action inside an app names the app, never
    // "whichever app is in front", which can change between this check and the action.
    if (c.needsApp) {
      return { verdict: 'deny', c, why: 'no app named',
        reason: 'Name the app explicitly (app: "<its name>") for actions inside an app. If you meant the app in ' +
          'front, use its name from the [Mac: …] line.' }
    }
    if (c.tooLong) {
      return { verdict: 'deny', c, why: 'command too long to read out',
        reason: `That command is longer than ${MAX_COMMAND} characters, too long to read out to the user for approval, ` +
          'so it was not run. Break it into shorter steps.' }
    }
    const scope = scopeOf(c)
    const key = `${c.capability}|${scope}`
    const rule = c.appTarget && store.apps?.[c.appTarget] === 'deny' ? 'deny' : ruleFor(store, c)

    if (rule === 'deny') {
      // A per-app revoke covers everything about that app, opening included.
      const what = store.apps?.[c.target] === 'deny' ? `use ${appLabel(c.app)}` : describe(c)
      return { verdict: 'deny', c, scope, why: 'revoked by the user',
        reason: `The user has not allowed Jarvis to ${what}. Do not try another way. Tell them, in one sentence, ` +
          `that they can allow it by saying "allow Jarvis to ${what}".` }
    }

    // Messages: typing is not sending, and sending needs the user's word and a check first.
    if (c.sends) {
      if (!sendRequested(said)) {
        return { verdict: 'deny', c, scope, why: 'sending was not requested',
          reason: 'The user asked for the message to be written, not sent. Leave it typed and unsent, tell them it is ' +
            'ready, and that they can say "send it". Do not send it another way.' }
      }
      if (c.submits) {
        return { verdict: 'deny', c, scope, why: 'type and send in one step',
          reason: 'Type the message with submit false, read_window to check the recipient, the conversation and the ' +
            'text, then press Return (or click Send) as a separate step.' }
      }
      const readAt = seen.read.get(c.target) ?? 0
      const typedAt = seen.typed.get(c.target) ?? 0
      if (!readAt || readAt < typedAt) {
        return { verdict: 'deny', c, scope, why: 'not verified before sending',
          reason: `Before sending, read_window${c.app ? `(app: "${c.app}")` : ''} to check that it is the right app, ` +
            'the right recipient and conversation, and exactly the message the user dictated. If the recipient is ' +
            'ambiguous, ask the user. Then send.' }
      }
    }

    const permitted = rule === 'allow' || session.has(key)
    // "Send it" asks for exactly the press of Return or Send that sends.
    const unrequested = !c.readOnly && !(c.sends && sendRequested(said)) && !requestedByUser(c, said)
    const mismatch = senseMismatch(c, said)
    // An explicitly requested, verified send needs no second question; other sensitive actions do.
    const sensitive = c.sends ? null : (c.sensitive ?? null)
    if (permitted && !sensitive && !unrequested && !mismatch) {
      return { verdict: 'proceed', c, scope, key, why: rule === 'allow' ? 'allowed' : 'allowed for this conversation' }
    }
    // Something needs the user's say-so. One plain question.
    if (sensitive) {
      return { verdict: 'ask', c, scope, key, kind: 'sensitive', question: `This will ${c.summary}, which ${sensitive}. Do you want me to continue?` }
    }
    if (unrequested || mismatch) {
      return { verdict: 'ask', c, scope, key, kind: 'unrequested', question: `You didn't ask me to ${c.summary}. Shall I go ahead?` }
    }
    return { verdict: 'ask', c, scope, key, kind: 'permission', question: permissionQuestion(c) }
  }

  /** Records what an allowed action did, for the verify-before-send rule. */
  const note = (c) => {
    seen.n += 1
    if (c.capability === 'app' && c.readOnly) seen.read.set(c.target, seen.n)
    if (c.capability === 'screen') seen.read.set(c.app ? appKey(c.app) : frontmostFrom(context()), seen.n)
    if (c.intent === 'type') seen.typed.set(c.target, seen.n)
    if (c.sends) seen.typed.set(c.target, seen.n) // after a send, verify again before the next one
  }

  /** Asks the user one question; true if they allowed it. */
  const confirm = async (toolName, d) => {
    const { c, scope, kind, question } = d
    let reply
    try {
      reply = await ask('confirm', {
        kind,
        capability: c.capability,
        target: scope ?? '',
        app: c.app ?? '',
        summary: c.summary,
        question,
        rememberable: kind === 'permission',
      }, 90_000)
    } catch (err) {
      recordHistory({ connection, tool: toolName, capability: c.capability, target: scope, summary: c.summary, decision: 'deny', why: `no answer: ${err?.message ?? err}` })
      return { ok: false, unanswered: true }
    }
    const decision = String(reply?.decision ?? 'deny')
    recordHistory({ connection, tool: toolName, capability: c.capability, target: scope, summary: c.summary, kind, decision, why: 'spoken answer' })
    if (decision === 'allow_session' && kind === 'permission') session.add(d.key)
    return { ok: decision.startsWith('allow') }
  }

  return async (input) => {
    if (input?.hook_event_name !== 'PreToolUse') return proceed
    const toolName = input.tool_name

    const store = loadStore()
    if (store.damaged) {
      recordHistory({ connection, tool: toolName, decision: 'deny', why: 'permissions.json is unreadable' })
      return deny('Jarvis could not read its permission settings, so it is not doing anything that needs them. Tell the user.')
    }
    const said = userText()
    if (said !== seen.ask) {
      seen.ask = said
      seen.read.clear()
      seen.typed.clear()
    }

    // Several actions at once: every step is decided exactly as if it were called alone.
    const planServer = /^mcp__(jarvis_mac|jarvis_desktop)__run_tasks$/.exec(toolName)?.[1]
    if (planServer) {
      const steps = Array.isArray(input.tool_input?.steps) ? input.tool_input.steps : []
      const decided = []
      for (const step of steps) {
        const name = `mcp__${planServer}__${String(step?.tool ?? '')}`
        const d = decide(name, step?.args ?? {}, said, store)
        const label = `Step ${step?.id ?? decided.length + 1} (${d.c.summary ?? step?.tool})`
        if (d.c.sends) {
          recordHistory({ connection, tool: name, plan: true, summary: d.c.summary, decision: 'deny', why: 'sending inside a plan' })
          return deny(`${label} sends a message. Sending can't be part of run_tasks: run the other steps, then read_window to verify, then send as its own step.`)
        }
        if (d.verdict === 'deny') {
          recordHistory({ connection, tool: name, plan: true, capability: d.c.capability, target: d.scope, summary: d.c.summary, decision: 'deny', why: d.why })
          return deny(`${label}: ${d.reason} Nothing in this plan was run.`)
        }
        decided.push({ name, d })
      }
      for (const { name, d } of decided) {
        if (d.verdict !== 'ask') continue
        const answer = await confirm(name, d)
        if (!answer.ok) {
          return deny(answer.unanswered
            ? 'The user could not be asked for permission, so nothing in this plan was run. Say so in one sentence.'
            : `The user said no to: ${d.c.summary}. Nothing in this plan was run. Don't do that step; ask whether to do the others.`)
        }
      }
      for (const { name, d } of decided) {
        if (d.quiet) continue
        note(d.c)
        recordHistory({ connection, tool: name, plan: true, capability: d.c.capability, target: d.scope, summary: d.c.summary, decision: 'allow', why: d.why ?? 'answered yes' })
      }
      return proceed
    }

    const d = decide(toolName, input.tool_input, said, store)
    if (d.quiet) return proceed
    if (d.verdict === 'deny') {
      recordHistory({ connection, tool: toolName, capability: d.c.capability, target: d.scope, summary: d.c.summary, decision: 'deny', why: d.why })
      return deny(d.reason)
    }
    if (d.verdict === 'proceed') {
      note(d.c)
      recordHistory({ connection, tool: toolName, capability: d.c.capability, target: d.scope, summary: d.c.summary, decision: 'allow', why: d.why })
      return proceed
    }
    const answer = await confirm(toolName, d)
    if (answer.ok) {
      note(d.c)
      return proceed
    }
    return deny(answer.unanswered
      ? 'The user could not be asked for permission, so the action was not taken. Say so in one sentence.'
      : 'The user said no. Do not do it, do not try another way, and acknowledge briefly.')
  }
}

/** For `jarvis_mac permissions`: what the bridge knows, in plain words. */
export function describeStore() {
  const s = loadStore()
  const caps = Object.keys(DEFAULTS).map((k) => `${CAPABILITY_NAMES[k] ?? k}: ${s.capabilities[k] ?? `${DEFAULTS[k]} (default)`}`)
  const apps = Object.entries(s.apps ?? {}).map(([id, v]) => `${id}: ${v}`)
  const folders = (s.folders ?? []).map((f) => `${f.path}: ${f.access}`)
  return { capabilities: caps, apps, folders, integrations: s.integrations ?? {} }
}
