/**
 * What the user said, understood the same way on every platform.
 *
 * JavaScript versions of Jarvis Voice's macOS parsers (TaskCommands.swift,
 * Permissions.swift): task commands ("stop task 2"), several apps at once ("open
 * Chess and Dictionary"), answers to permission questions ("allow always"), and
 * voice commands about permissions ("revoke camera access"). The test vectors in
 * tests/vectors/commands.json are run against both implementations, so the two
 * cannot drift apart.
 */

/** Lowercase, curly apostrophes straightened, anything but letters, digits and ' as spaces. */
export function normalized(s) {
  return String(s ?? '').toLowerCase().replace(/’/g, "'").replace(/[^\p{L}\p{N}']+/gu, ' ').trim().replace(/ +/g, ' ')
}

const whole = (pattern, t) => {
  const r = new RegExp(`^${pattern}$`).exec(t)
  return r ? Array.from(r, (g) => g ?? '') : null
}

const NUMBER_WORDS = {
  one: 1, won: 1, two: 2, to: 2, too: 2, three: 3, four: 4, for: 4, five: 5, six: 6, seven: 7, eight: 8, ate: 8, nine: 9,
  ten: 10, eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18,
  nineteen: 19, twenty: 20, first: 1, second: 2, third: 3, fourth: 4, fifth: 5,
}
export const number = (word) => (/^\d+$/.test(word) ? Number(word) : NUMBER_WORDS[word] ?? null)

/** Task commands and the questions answered locally. `text` is the request without the wake word. */
export function parseTaskCommand(text) {
  let t = normalized(text)
  for (const p of ['please ', 'can you ', 'could you ', 'would you ', 'ok ', 'okay ', 'now ', 'and ']) if (t.startsWith(p)) t = t.slice(p.length)
  for (const s of [' please', ' now', ' right now', ' for me', ' sir']) if (t.endsWith(s)) t = t.slice(0, -s.length)
  t = t.trim()
  if (!t) return null
  const m = (p) => whole(p, t)

  if (m("(what time is it|what's the time|what is the time|tell me the time|time|the time|current time|what's the current time|what is the current time|do you know what time it is|do you have the time|have you got the time)")) {
    return { type: 'time' }
  }
  if (m("(what's the date|what is the date|what's today's date|what is today's date|what's the date today|what is the date today|what day is it|what day is it today|what's today|what is today|which day is it|today's date|the date)")) {
    return { type: 'date' }
  }
  if (m('what are you (doing|working on|up to|busy with)')
    || m("(what's|what is|what are|anything|is anything|are any tasks?) (running|going on|happening|in progress)")
    || m('(what|which) tasks? (are|is) (running|active|going|going on|in progress|open)')
    || m('(list|show|tell me)( me)?( the| my| all| your| all the| all your)? (tasks|active tasks|running tasks|current tasks)')
    || m('(task|tasks) (status|list|update)')
    || m('(status|state) of (the |my |your |all )?tasks')
    || m("(how are|how's|how is) (the |my |your )?(tasks?|task) (going|doing)")
    || m('are you (doing|working on) anything')
    || m('(any|are there any) tasks( running)?')) {
    return { type: 'status' }
  }
  const stop = '(stop|cancel|kill|end|abort|halt|terminate|drop|scrap)'
  let g = m('(stop|stops|stopped|stock|top|cancel|cancelled|canceled|kill|end|abort|halt|terminate|drop|scrap) (the )?tasks?( number)? ([a-z0-9]+)')
  if (g && number(g[4]) !== null) return { type: 'cancel', n: number(g[4]) }
  g = m(`${stop} (the )?(first|second|third|fourth|fifth) task`)
  if (g && number(g[3]) !== null) return { type: 'cancel', n: number(g[3]) }
  if (m(`${stop} (everything|it all|all of it|all of that)`) || t === 'stop all') return { type: 'stopEverything' }
  if (m(`${stop} (all|all the|all of the|every|all my|all your|all of my|all of your)( running| active| background| current)? tasks`)
    || m(`${stop} all (running |active |background )?tasks`)
    || m('clear (all )?(the |my |your )?tasks')) {
    return { type: 'cancelAll' }
  }
  if (m(`${stop} (that|it|this|that one|this one|that task|this task|the last task|the last one|what you're doing|what you are doing)`)
    || t === 'never mind that' || t === 'forget that') {
    return { type: 'cancelLatest' }
  }
  g = m(`${stop} (the |my |your )?(.+?) (task|one|job)`)
  if (g) return { type: 'cancelNamed', name: g[3] }
  g = m(`${stop} ((opening|launching|closing|quitting|searching|looking|loading|reading|typing|running) .+)`)
  if (g) return { type: 'cancelNamed', name: g[2] }
  g = m('(continue|resume|go back to|back to|carry on with|return to|switch to|pick up|finish) (the )?task( number)? ([a-z0-9]+)')
  if (g && number(g[4]) !== null) return { type: 'resume', n: number(g[4]) }
  return null
}

/** Apps people name that may not be installed ("open Spotify" says it isn't, rather than searching the web). */
export const KNOWN_APPS = new Set([
  'spotify', 'whatsapp', 'vs code', 'vscode', 'visual studio code', 'code', 'slack', 'zoom', 'teams', 'microsoft teams',
  'discord', 'telegram', 'signal', 'notion', 'figma', 'postman', 'docker', 'word', 'excel', 'powerpoint', 'outlook',
  'onenote', 'xcode', 'iterm', 'iterm2', 'warp', 'firefox', 'brave', 'edge', 'microsoft edge', 'arc', 'obsidian',
  '1password', 'steam', 'vlc', 'skype', 'webex', 'sublime text', 'intellij', 'pycharm', 'android studio', 'cursor',
  'chatgpt', 'messenger', 'pages', 'numbers', 'keynote', 'imovie', 'garageband', 'final cut pro', 'logic pro',
  'safari', 'chrome', 'google chrome', 'finder', 'terminal', 'notes', 'mail', 'messages', 'music', 'photos',
  'calendar', 'reminders', 'maps', 'facetime', 'system settings', 'settings', 'calculator', 'preview', 'textedit',
  'chess', 'dictionary', 'font book', 'stickies', 'activity monitor', 'app store', 'podcasts', 'news', 'stocks',
  'weather', 'clock', 'freeform', 'shortcuts', 'contacts', 'books', 'home', 'tv', 'quicktime player', 'automator',
  // Windows and Linux
  'notepad', 'paint', 'file explorer', 'explorer', 'task manager', 'snipping tool', 'windows terminal', 'powershell',
  'command prompt', 'control panel', 'wordpad', 'thunderbird', 'gedit', 'text editor', 'files', 'nautilus', 'dolphin',
  'konsole', 'gnome terminal', 'libreoffice', 'gimp', 'inkscape', 'blender', 'kate', 'system monitor', 'software',
])

const PLAN_VERBS = new Set([
  'search', 'go', 'type', 'navigate', 'play', 'find', 'look', 'read', 'send', 'message', 'write', 'tell', 'show',
  'run', 'click', 'press', 'open', 'close', 'quit', 'launch', 'start', 'then', 'while', 'to', 'for', 'with', 'in',
  'on', 'at', 'it', 'that', 'this', 'my', 'about', 'how', 'what', 'why', 'make', 'create', 'delete', 'explain',
])

/** "chess dictionary font book" → app names, or null if any word is left over. */
function segment(text, isApp) {
  const words = text.split(' ').filter(Boolean)
  if (words.length < 2 || words.length > 9 || words.some((w) => PLAN_VERBS.has(w))) return null
  const best = new Map([[0, []]])
  for (let end = 1; end <= words.length; end++) {
    for (let start = end - 1; start >= Math.max(0, end - 4); start--) {
      const before = best.get(start)
      if (!before) continue
      const name = words.slice(start, end).join(' ')
      if (!isApp(name) && !KNOWN_APPS.has(name)) continue
      if (!best.has(end) || best.get(end).length > before.length + 1) best.set(end, [...before, name])
    }
  }
  const names = best.get(words.length)
  return names && names.length >= 2 ? names : null
}

/**
 * Several apps in one request: "open Chess, Dictionary and Font Book", "close Chess and
 * Dictionary", "open Chess then Dictionary". Each stage opens together; stages in order.
 * @returns {{verb: 'open'|'close', stages: string[][]} | null}
 */
export function parseAppPlan(request, isApp) {
  let t = String(request ?? '').toLowerCase().replace(/’/g, "'")
  t = t.replace(/[.!?]+$/, '').trim()
  for (const p of ['please ', 'can you ', 'could you ', 'would you ', 'jarvis, ', 'jarvis ']) if (t.startsWith(p)) t = t.slice(p.length)
  const verbMatch = /^(open|launch|start|fire up|close|quit|exit)( up)? /.exec(t)
  if (!verbMatch) return null
  const verbWord = verbMatch[0].trim()
  const verb = /^(close|quit|exit)/.test(verbWord) ? 'close' : 'open'
  let rest = t.slice(verbMatch[0].length)
  for (const s of [' please', ' for me', ' now', ' apps', ' applications']) if (rest.endsWith(s)) rest = rest.slice(0, -s.length)
  const stageTexts = rest.split(/\s*,?\s*\b(?:and then|then|after that|afterwards|followed by)\b\s*/)
  const stages = []
  for (const stageText of stageTexts) {
    if (!stageText.trim()) continue
    const items = []
    for (const raw of stageText.split(/\s*(?:,|&|\band\b|\bplus\b|\balso\b)\s*/)) {
      let item = normalized(raw)
      for (const p of ['the ', 'my ', 'open ', 'launch ', 'close ', 'quit ']) if (item.startsWith(p)) item = item.slice(p.length)
      for (const s of [' app', ' application']) if (item.endsWith(s)) item = item.slice(0, -s.length)
      if (!item) continue
      if (isApp(item) || KNOWN_APPS.has(item)) items.push(item)
      else {
        const split = segment(item, isApp)
        if (!split) return null // not an app: Claude's to work out
        items.push(...split)
      }
    }
    if (items.length) stages.push(items)
  }
  const count = stages.reduce((n, s) => n + s.length, 0)
  return count >= 2 ? { verb, stages } : null
}

/** A clear, whole answer to a permission question — or null (never a guess). */
export function parsePermissionAnswer(text) {
  const filler = new Set(['jarvis', 'sir', 'please', 'um', 'uh', 'well', 'oh', 'hey'])
  const t = normalized(text).split(' ').filter((w) => w && !filler.has(w)).join(' ')
  if (!t) return null
  const any = (options) => options.includes(t) || options.some((o) => `${o} it` === t)
  if (any(['always allow', 'allow always', 'always', 'remember', 'remember that', 'yes always', 'yes remember',
    'allow and remember', 'yes always allow', 'always yes', 'remember it', 'allow it always'])) return 'allow_always'
  if (any(['allow once', 'just once', 'only once', 'once', 'this once', 'just this once', 'allow it once',
    'yes just this once', 'yes once', 'only this time', 'just this time'])) return 'allow_once'
  if (any(['never', 'never allow', "don't ever", 'do not ever', 'always deny', 'deny always', 'no never',
    'never ever', "don't ever allow", 'never allow it'])) return 'deny_always'
  if (any(['yes', 'yeah', 'yep', 'yup', 'sure', 'ok', 'okay', 'allow', 'go ahead', 'do it', 'proceed', 'continue',
    'confirm', 'confirmed', 'yes please', 'yes allow', 'yes go ahead', 'yes do it', 'please do', 'affirmative',
    "that's fine", 'fine', 'yes continue', 'allow for now', 'for now', 'allow for this conversation',
    'allow this time', 'yes proceed', 'ok go ahead', 'okay go ahead', 'go for it', 'approved', 'i approve'])) return 'allow_session'
  if (any(['no', 'nope', 'nah', "don't", 'do not', "don't allow", 'do not allow', 'deny', 'cancel', 'stop',
    'no thanks', 'no thank you', "don't do it", 'do not do it', 'negative', 'never mind', 'not now',
    'leave it', "don't bother", "no don't", 'no stop', 'dont allow', 'no do not'])) return 'deny'
  return null
}
export const answerAllows = (a) => typeof a === 'string' && a.startsWith('allow')

/** "camera", "my downloads folder", "control other applications", "firefox"… */
export function permissionCapability(raw, resolveApp, { home = '', sep = '/' } = {}) {
  let p = String(raw ?? '').trim()
  const appWords = '(apps|applications|programs|other apps|other applications|any apps|my apps|any app|any application)'
  if (new RegExp(`^(opening|open|launching|launch|starting) ${appWords}$`).test(p)) return { capability: 'apps.open', target: '', label: 'opening apps' }
  if (new RegExp(`^(closing|close|quitting|quit) ${appWords}$`).test(p)) return { capability: 'apps.close', target: '', label: 'closing apps' }
  for (const prefix of ['to ', 'my ', 'the ', 'your ', 'use ', 'using ', 'access ', 'access to ', 'control ', 'controlling ', 'read ', 'reading ',
    'accessing ', 'looking at ', 'watching ', 'opening ', 'closing ']) {
    while (p.startsWith(prefix)) p = p.slice(prefix.length)
  }
  p = p.trim()
  switch (p) {
    case 'camera': case 'the camera': case 'webcam': case 'camera access': return { capability: 'camera', target: '', label: 'the camera' }
    case 'screen': case 'my screen': case 'screen recording': case 'screenshots': case 'screen capture': return { capability: 'screen', target: '', label: 'your screen' }
    case 'files': case 'my files': case 'files and folders': case 'documents': case 'file access': return { capability: 'files', target: '', label: 'your files' }
    case 'shell': case 'terminal': case 'commands': case 'the terminal': case 'command line': case 'shell commands': case 'run commands':
      return { capability: 'shell', target: '', label: 'running commands' }
    case 'other applications': case 'other apps': case 'applications': case 'apps': case 'all apps': case 'my apps':
    case 'other applications on my mac': case 'other applications on my computer': case 'other apps on my computer':
      return { capability: 'app', target: '', label: 'controlling other apps' }
    case 'web': case 'the web': case 'internet': case 'the internet': case 'web search': case 'browsing': return { capability: 'web', target: '', label: 'searching the web' }
    case 'microphone': case 'mic': case 'the microphone': return { capability: 'microphone', target: '', label: 'the microphone' }
    default: break
  }
  const folders = ['downloads', 'desktop', 'documents', 'pictures', 'movies', 'videos', 'music', 'home']
  const folderWord = p.replace(/ folder/g, '').replace(/ directory/g, '')
  if (folders.includes(folderWord)) {
    const name = folderWord[0].toUpperCase() + folderWord.slice(1)
    return { capability: 'files', target: folderWord === 'home' ? home : `${home}${sep}${name}`, label: `your ${name} folder` }
  }
  if (p.startsWith('~') || p.startsWith('/')) return { capability: 'files', target: p.startsWith('~') ? home + p.slice(1) : p, label: p }
  const app = resolveApp(p)
  if (app) return { capability: 'app', target: app.bundleID, label: app.name }
  return null
}

/**
 * Voice commands about permissions.
 * @returns {{type:'list'}|{type:'listApps'}|{type:'can', what:string}|{type:'reset'}|
 *           {type:'change', capability:string, target:string, allow:boolean, label:string}|null}
 */
export function parsePermissionCommand(text, resolveApp, where = {}) {
  let t = normalized(text).replace(/jarvis's/g, 'your').split(' ').filter((w) => w !== 'jarvis' && w !== 'please' && w !== 'sir').join(' ')
  for (const s of [' again', ' from now on', ' anymore', ' any more']) if (t.endsWith(s)) t = t.slice(0, -s.length)
  const m = (p) => whole(p, t)
  const capability = (phrase) => permissionCapability(phrase, resolveApp, where)
  if (m('(what|which) (permissions|access|rights) (do you|have you|you) (currently )?(have|got)( currently| right now| now)?')
    || m('(show|tell|list|read) (me )?(my |your |the )?(current )?permissions( currently| right now)?')
    || m('what (are|is) (my |your |the )?(current )?permissions?( right now)?')
    || m('what are you (allowed|permitted) to do')) {
    return { type: 'list' }
  }
  if (m('(what|which) (apps|applications|programs) (can|may) you (control|access|use|operate)')) return { type: 'listApps' }
  let g = m('can you (control|access|use|operate|read|see) (.+)')
  if (g) return { type: 'can', what: g[2] }
  if (m('reset (all |your |my )?(the )?permissions')) return { type: 'reset' }
  g = m('(stop|quit|no more) (controlling|using|accessing|reading|looking at|watching|opening|launching|closing|quitting) (.+)')
  if (g) {
    const verb = g[2]
    const opening = verb === 'opening' || verb === 'launching'
    const closing = verb === 'closing' || verb === 'quitting'
    const phrase = (opening ? 'opening ' : closing ? 'closing ' : verb === 'controlling' ? 'controlling ' : '') + g[3]
    const c = capability(phrase)
    if (c && (!(opening || closing) || c.capability === 'apps.open' || c.capability === 'apps.close')) {
      return { type: 'change', capability: c.capability, target: c.target, allow: false, label: c.label }
    }
  }
  const take = [
    ['(revoke|remove|withdraw|disable|turn off|take away)( your| the)?( access to| access for| permission to| permission for| permissions for)? (.+?)( access| permission| permissions)?', 4],
    ["(don't|do not|never) (allow|let|give)( you| yourself)?( to)?( access| permission)?( to| for)? (.+?)( access| permission)?", 7],
    ['(block|deny)( your| you)?( access to| access)? (.+)', 4],
  ]
  for (const [pattern, index] of take) {
    g = m(pattern)
    const c = g && g.length > index ? capability(g[index]) : null
    if (c) return { type: 'change', capability: c.capability, target: c.target, allow: false, label: c.label }
  }
  g = m('(allow|let|give|grant)( you| yourself)?( to)?( access| permission)?( to| for)? (.+?)( access| permission)?')
  if (g) {
    const c = capability(g[6].trim())
    if (c) return { type: 'change', capability: c.capability, target: c.target, allow: true, label: c.label }
  }
  return null
}

/** The wake phrase at the start of what was heard: "Hey Jarvis, open Notepad" → "open Notepad". */
const WAKE = /^\s*(?:(?:hey|hi|hay|ok|okay|a)[\s,.!]+)?(?:jarvis|jarvi|jervis|jarviss|jarvas|jarves|jarvys|jarbis)\b[\s,.!?:;-]*/i
const WAKE_FUZZY = /^\s*(?:hey|hi|hay|ok|okay)[\s,.!]+(?:javis|javes|jarvess|jarvies|jarvy|jarvi's|jarvis's|jovis|jervis)\b[\s,.!?:;-]*/i
export function stripWake(heard) {
  const text = String(heard ?? '')
  const m = WAKE.exec(text) ?? WAKE_FUZZY.exec(text)
  return m ? { woke: true, request: text.slice(m[0].length).trim() } : { woke: false, request: text.trim() }
}
