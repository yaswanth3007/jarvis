# JARVIS on macOS — always on, hands free, and under your control

This folder turns the JARVIS web app into a background assistant built into your
Mac. Log in, and JARVIS is already listening: say **“Hey Jarvis”** (or just
**“Jarvis”**) from any app and talk to him. He answers out loud, keeps the
conversation going without the wake word, opens and closes apps, reads your
screen or an app's window, looks through the camera when you ask, and does
things inside apps — but only what you explicitly asked, and only with your
permission. He can work on several things at once: each is a numbered task you
can ask about (“what are you doing?”) and stop (“stop task 2”), and he stays
responsive while they run.

The brain is still `bridge/server.mjs` and your existing Claude Code login (no
API key). The web interface at http://localhost:5173 keeps working exactly as
before and is optional.

> macOS gives third-party apps no access to Siri's own “Hey Siri” trigger. This
> is a separate, ordinary background listener that uses Apple's **on-device**
> speech recognition and the normal macOS permission prompts.

---

## How it works

```
 login ──▶ launchd
            ├─ local.jarvis.agent  node core/supervisor.mjs   (shared with Windows and Linux)
            │     ├─ bridge        node bridge/server.mjs   127.0.0.1:8787   (the brain: Claude Code)
            │     ├─ face          vite                     localhost:5173   (the web interface, as before)
            │     └─ voice-engine  Kokoro neural voice      127.0.0.1:8790
            │
            └─ local.jarvis.voice  ~/Applications/JarvisVoice.app   (menu bar)
                  microphone ─▶ Apple SpeechAnalyzer (on-device) ─▶ “Hey Jarvis”?
                     │ simple commands ("open Safari", "open Chess and Dictionary", "what time is it",
                     │ "stop task 2", "revoke camera access") ─▶ done on the Mac, no Claude
                     ▼ everything else
                  task manager ─ every action is a task: id, status, locks, dependencies, timeout, cancel
                     │
                  ws://127.0.0.1:8787/?client=jarvis-voice-mac ─▶ Claude — one session per task
                     ▲   │ tool calls ─▶ permission broker ─▶ Jarvis Voice asks you ─▶ Mac / camera / screen
                     │   ▼ reply, streamed sentence by sentence (a background task's: labelled, when you're free)
                  Kokoro / ElevenLabs / macOS voice ─▶ your speakers or headphones ─▶ follow-up
```

| Menu bar icon | Meaning |
|---|---|
| waveform | Ready — listening for the wake phrase |
| mic (filled / outline) | Listening to you / listening for a follow-up |
| ellipsis | Thinking |
| speaker | Speaking (talk over him to interrupt) |
| question mark | Waiting for your answer to a permission question |
| eye | Camera or screen in use |
| mic with slash | Muted (microphone off) |

### What changed in the project

Everything is additive. New: `macos/` (this folder), `bridge/mac.mjs` (the Mac
tools, including `run_tasks` for several actions at once) and
`bridge/permissions.mjs` (the permission broker, including the message-sending
rules). `bridge/server.mjs` gained a small, gated change: when a connection
identifies itself as Jarvis Voice **and** the bridge runs with
`JARVIS_PERMISSIONS=1` (the background agent sets it), that connection gets the
Mac tools, the voice-only system prompt, the permission broker and a longer wait
for the camera's first-use prompt. Every other client — the web interface,
`npm start`, `npm run bridge:writes` — behaves exactly as it did.

In the app, `Tasks.swift` is the task manager and `TaskCommands.swift` parses the
spoken task commands and several-apps-at-once requests.

---

## Install

Requirements: macOS 26 or newer, Apple's Command Line Tools (`xcode-select
--install`), Node 20+, `npm install` done in the project, and Claude Code signed
in (`claude auth login`).

```bash
macos/jarvisctl install
```

macOS asks for **Microphone** and **Speech Recognition** — click **Allow**. Other
permissions are asked for only when a feature first needs them (see below). No
`sudo`; nothing outside your own `~/Library` and `~/Applications`.

**Once, before or after installing (recommended):**

```bash
macos/jarvisctl signing-identity
```

This creates a self-signed code-signing certificate, “Jarvis Voice Local
Signing”, in your login keychain (only `codesign` may use its key) and every
build is signed with it. macOS ties its permissions to an app's signature: with
this, every update of Jarvis Voice is the same app to macOS, so it stops asking
for the microphone, speech recognition and camera again after each rebuild
(verified across three different builds). Without it, builds are signed ad hoc
and each one is new to macOS. The next install after creating it asks one last
time. `macos/jarvisctl doctor` shows which kind of signature is in use. To
remove it: `security delete-identity -c "Jarvis Voice Local Signing"`.

## Talking to JARVIS

- **“Hey Jarvis, what's the weather in London?”** — one breath is fine.
- **“Jarvis.”** → *“Yes?”* → ask. The microphone stays open while he says it.
- Follow up for 8 seconds without the wake word. End with *“that's all”*,
  *“thank you”*, *“goodbye”*… or just stop talking.
- **Interrupt** by talking over him. Through the Mac's speakers say his name or
  “stop” / “wait” / “cancel” (anyone talking nearby would otherwise cut him off);
  with headphones any clear speech works. `"interruptWith"`: `auto`, `name`,
  `speech`.
- Say **“cancel”** while he's thinking to drop the request.
- Say **“Jarvis, …”** while he's still working on something to ask for something
  else: the first request carries on as a background task and he answers it
  when it's done (see below). He never starts “One moment” over you.
- **⌥⌘J** (Option-Command-J) talks without the wake word or cuts him off.

## Several things at once — tasks

Everything he does for you is a numbered **task**: opening an app, a Claude
request, one action inside an app, a camera capture. Independent tasks run at
the same time; tasks that need the same thing take turns.

| You say | What happens |
|---|---|
| “Open Chess, Dictionary and Font Book” | Three tasks at once, on the Mac (no Claude): *“Chess, Dictionary and Font Book are open.”* One app missing never holds up the others: *“Chess and Font Book are open. VS Code isn't installed on this Mac.”* |
| “Open Chess, then Dictionary” | In that order. |
| “Open Safari and search for GitHub while opening Calculator” | Claude plans it (`run_tasks`): Calculator opens while Safari launches; the search waits for Safari. Every step is checked by the permission broker as if it were asked alone. |
| “Jarvis, what time is it?” while he's busy | Answered at once; the other request carries on. |
| **“What are you doing?”** | *“Task 3: search the web for the history of the Hubble Space…”*, including what a task is waiting for (*“waiting for your permission to use the camera”*). |
| **“Stop task 2”**, **“stop the Chrome task”**, **“stop opening Spotify”**, **“stop that”** | Stops that task only. A Claude task's session is closed, so no process is left behind. What has already happened (an app that has launched) is not undone, and he says so. |
| **“Cancel all tasks”**, **“stop everything”** | Stops every task that can be stopped safely. |
| **“Continue task 1”** | Its waiting question or answer now, and its Claude session for what you say next. |

- **Background answers** are said when you're not talking and he isn't busy,
  labelled with their task: *“Task 4, what is the capital of Australia: Canberra,
  sir.”* An answer can never be spoken as another task's: each task has its own
  Claude session.
- **Questions from background tasks** wait the same way and say which task
  they're for. A grant for one task is not a grant for another.
- **Locks.** Each app's window is one task's at a time while it is being changed
  (reading can be shared); typing and key presses hold the keyboard focus, so
  no other task can open or switch apps under them; the camera is one task's.
  Before typing, he checks again that the right app and field still have focus.
- **Limits.** Up to 3 Claude requests at once (each is a Claude Code session,
  about 350 MB), fewer when the Mac is short of memory, hot or its CPU is
  saturated; past that a request waits its turn (*“that's task 7, I'll start it
  as soon as I can”*), and beyond 4 waiting he says he's busy. Up to 6 app
  launches and 4 in-app actions at once. Every task has a timeout; a timed-out
  task is stopped and reported; a failed launch is retried once.
- `macos/jarvisctl tasks` lists tasks with their state, locks and timings;
  `macos/jarvisctl cancel 3` / `cancel all` stops them.

## Apps, the screen and the camera

| You say | What happens |
|---|---|
| “Open Safari / Chrome / VS Code / Terminal / Finder / System Settings / Slack…” | Opened directly on the Mac (no Claude round trip) and verified with macOS. If it isn't installed he says so — he never downloads or installs anything. |
| “Close Safari”, “close it” | Quit the normal way, so macOS still asks about unsaved work — he tells you, and never answers that dialog for you. “It” is the app he last opened or used, otherwise the one in front. Force quit only if you say so, after a confirmation. |
| “Open your interface” / “hide your interface” | Opens or closes the JARVIS web interface; voice keeps working either way. |
| “Search for GitHub”, “go to YouTube” (after opening a browser) | Claude acts in that app: Chrome through the existing Claude extension tools, other apps through Accessibility, URLs, keystrokes. |
| “Open my Jarvis project in VS Code”, “open Finder and go to Downloads”, “open System Settings and go to Privacy & Security” | Multi-step requests are done step by step — only the steps you listed. |
| “Read what's on the page”, “read the error”, “what does this window say?” | The front window's text through Accessibility (the least invasive way); a screenshot only when text isn't enough. |
| “Look at my screen” | A screenshot of the screen (never the camera). |
| “What's in front of me?”, “can you read this?”, “what is this object?” | One frame from the camera (never the screen); the camera is off again straight after. Follow-up questions use the same picture. |
| “Open Terminal and run git status in my Jarvis project” | Typed into a visible Terminal window. Anything destructive is explained and confirmed first. |
| “Open WhatsApp and type I'll be late” | Typed, **not sent**: *“It's ready to send.”* |
| “Send it” | Only now: he reads the window first to check the app, the recipient, the conversation and the text, presses Return, and reads it again to confirm it went. |
| “Message John saying I'll be late and send it” | The whole flow, because you said “send”. If two chats could be John, he asks which one and sends nothing. |

**Messages are never sent unless you say “send”** (WhatsApp, Messages, Slack,
Mail, Teams, Telegram, Signal, Discord…). The broker enforces it whatever Claude
tries: Return or a Send button in a messaging app is refused unless your request
said to send, refused until the window has been read since the text was typed,
and never allowed inside a `run_tasks` plan. Words you dictate in quotes (“type
‘please send me the file’”) are the message, not an instruction.

## Permissions — three separate layers

1. **macOS permissions** (Apple's TCC) — microphone, speech recognition, camera,
   screen recording, Accessibility, automation of other apps. Jarvis Voice
   requests them through Apple's own prompts when a feature first needs them.
   Only you can grant or revoke them, in **System Settings → Privacy & Security**;
   Jarvis never touches the permission database and never claims a macOS
   permission changed when only his own setting did. When an action needs one
   macOS hasn't given, he **guides you**: *“I need Accessibility permission to
   read what's in Calculator. Would you like to allow it?”* — on **“Allow”** he
   opens System Settings at the right page (and shows macOS's own prompt), says
   what to switch on, and waits up to a minute until macOS **confirms** it, then
   carries on. On **“Don't allow”** the action isn't done. If macOS still reports
   it off, he says so (and that a managed Mac may lock it). Screen Recording only
   applies after a restart, so he offers to restart himself.
2. **Jarvis's own permissions** — what you allow Jarvis to do: use the camera,
   look at the screen, read or change files (per folder), run commands, control
   a given app (per app). Unknown → he asks:
   *“I need camera access to do that. Would you like to allow it?”* You answer:
   - **“Allow”** / “yes” — for this conversation,
   - **“Allow once”** — this one time,
   - **“Always allow”** / “remember” — remembered,
   - **“Don't allow”** / “no” — refused; **“never”** — refused and remembered.
   Only a clear, whole answer to the question counts — never background talk, a
   sentence that happens to contain “yes”, or his own voice.
3. **Your instruction** — having a permission is not a reason to act. Anything
   with consequences that your request didn't mention, and every **sensitive
   action** (deleting files, emptying Trash, sending or posting, buying or paying,
   installing software, `sudo`, destructive commands, changing security or system
   settings, sharing or uploading files), is confirmed out loud first — every
   time: *“This will run rm …, which deletes files. Do you want me to continue?”*

Opening and closing apps you name, and searching the web, need no question.
Instructions found inside web pages, emails, documents, screens or command
output are treated as data, never as orders. A few rules hold whatever Claude
tries:

- **Commands.** Only commands that just look (`git status`/`log`/`diff`, `ls`,
  `pwd`, `df`…, with no pipes, `;`, `$( )` or redirection) can run under an
  “allow”. Every other command, run in Terminal, through Claude's shell, or typed
  into a terminal and entered, is read out in full and confirmed each time.
  Commands too long to read out aren't run.
- **Integrations** (Gmail, Slack, Drive, Sheets… from your Claude account): look-ups
  run; anything that acts (forward, reply, schedule, trash, clear…) is confirmed
  each time, naming who or what it affects.
- **Inside apps** every action names its app. Jarvis never acts on “whatever is
  in front”, because that can change between the check and the action.
- Opening a file that would run a program (`.command`, `.app`, `.pkg`, scripts) is
  confirmed. Sub-agents and scheduled tasks aren't available to Jarvis Voice.

Say: **“What permissions do you have?”**, **“What apps can you control?”**,
**“Can you control Safari?”**, **“Revoke camera access”**, **“Don't allow access
to my Downloads folder”**, **“Don't allow Jarvis to control Chrome”**, **“Stop
controlling applications”** (no more reading, clicking or typing in other apps —
and any task doing that is stopped; opening and closing apps still work),
**“Stop opening apps”**, **“Stop using the camera”**, **“Allow Jarvis to control
VS Code”** / **“Allow you to control applications again”** (he confirms),
**“Reset permissions”**. Revoking takes effect on the very next action. Every
decision and action is appended to
`~/Library/Application Support/JarvisVoice/permission-history.jsonl`.

An answer he can't make out is asked again (*“Sorry, I didn't catch that”*)
rather than taken as “no”; silence is still “no”. You can also answer by typing:
`macos/jarvisctl answer allow`.

**Write access.** `agent.env` turns on `JARVIS_ALLOW_WRITES=1` together with
`JARVIS_PERMISSIONS=1`, so Jarvis Voice can act — always behind the checks above.
The web interface stays read-only unless you run `npm run bridge:writes`
yourself.

## Audio devices

Jarvis listens through the system microphone and speaks through the system
output, and follows macOS when devices change (plugging in headphones,
connecting AirPods, choosing a device in Sound settings). One exception, by
default: when the system microphone is a **Bluetooth headset**, he listens
through the Mac's own microphone instead, because macOS drops Bluetooth
headphones to low-quality call audio for as long as their mic is open — and he
listens all the time. Replies still play through the headphones at full
quality. Set `"inputDevice": "system"` to always use the system microphone, or
`"builtin"`. `macos/jarvisctl devices` shows what he's using.

## Commands

| | |
|---|---|
| Status | `macos/jarvisctl status` |
| End-to-end check | `macos/jarvisctl doctor` |
| Permissions and recent decisions | `macos/jarvisctl permissions` |
| Microphone and speakers in use | `macos/jarvisctl devices` |
| Start now | `macos/jarvisctl start` (or `start agent` / `start voice`) |
| Stop until next login | `macos/jarvisctl stop` |
| Restart | `macos/jarvisctl restart` |
| Mute / unmute the microphone | `macos/jarvisctl mute` / `macos/jarvisctl unmute` |
| Speak a line / ask by typing | `macos/jarvisctl say "Hello"` / `macos/jarvisctl ask "What time is it?"` |
| Answer his question by typing | `macos/jarvisctl answer allow` (or `no`, `allow always`…) |
| Tasks: list / stop one / stop all | `macos/jarvisctl tasks` (`tasks all` for finished ones too) / `macos/jarvisctl cancel 3` / `macos/jarvisctl cancel all` |
| Follow the logs | `macos/jarvisctl logs` |
| Keep permissions across updates (once) | `macos/jarvisctl signing-identity` |
| Reload settings | `macos/jarvisctl reload` |
| Uninstall | `macos/jarvisctl uninstall` (add `--purge` for settings, logs, cache and permissions) |

## Automatic start and stop

Two per-user LaunchAgents in `~/Library/LaunchAgents`, both `RunAtLoad`, restarted
if they crash, stopped cleanly at logout or shutdown, limited to your GUI
session:

- `local.jarvis.agent` — `node core/supervisor.mjs` (the same supervisor Windows and Linux
  use; `macos/agent/supervisor.mjs` remains as a shim for LaunchAgents written by earlier
  versions): runs the bridge, the web interface and the voice engine, reuses any copy already
  running (no duplicates), restarts anything that crashes or hangs.
- `local.jarvis.voice` — `~/Applications/JarvisVoice.app`, the menu bar app.

They appear in **System Settings → General → Login Items & Extensions → Allow in
the Background**; switching them off there stops them from starting.

## Settings

`~/Library/Application Support/JarvisVoice/config.json` holds only what you
change; `config.defaults.json` beside it lists every key with its default. Edit,
then `macos/jarvisctl reload`. Useful keys: `wakeWords`, `wakePrefixes`,
`requirePrefix` (only “Hey Jarvis” wakes him), `followUpSeconds`,
`endOfSpeechSeconds`, `ackAfterSeconds`, `acknowledgePhrase`, `bargeIn`,
`warmConnection`, `localCommands`, `inputDevice`, `voiceEngine`
(`auto`/`elevenlabs`/`kokoro`/`system`), `kokoroVoice`, `systemVoice`,
`logTranscripts`, `backgroundTasks` (“Jarvis, …” while he works starts another
task), `backgroundAfterSeconds` (when a slow action is acknowledged and finished
in the background, 1.5), `maxClaudeTasks` (3), `permissionGuideSeconds` (how long
he waits for you in System Settings, 60).

Bridge settings (`JARVIS_MODEL`, `JARVIS_EFFORT`, `ELEVENLABS_API_KEY`,
`JARVIS_ALLOW_WRITES`, …) go in `~/Library/Application Support/JarvisVoice/agent.env`
as `KEY=value` lines, then `macos/jarvisctl restart agent`. Values are never
logged.

## Privacy

- Wake-word listening and transcription happen on the Mac; audio is never stored
  or sent anywhere. Only the text of a request you made goes to Claude.
- The camera and screen are used only for a request that needs them, the image
  goes to Claude for that request, and nothing is saved. The camera light and
  the menu bar eye show when they're in use.
- Logs (`~/Library/Logs/Jarvis/`) record states, timings and word counts, not
  what you said (unless you set `logTranscripts`). Secrets are never logged.
- Everything listens on `127.0.0.1`/`localhost` only. The control socket is
  readable only by you; the voice engine refuses requests from web pages.
- Loopback ports are shared by every account on the Mac, so Jarvis Voice, the
  bridge and the voice engine prove themselves to each other with a per-install key:
  `~/Library/Application Support/JarvisVoice/bridge.key`. The agent creates it; it
  is readable only by you, and that folder is closed to other accounts.
  - Only a connection signed with the key gets the Mac tools and write access.
  - Jarvis Voice acts on nothing, and says nothing, until the bridge or voice engine
    has proved it holds the key. An impostor on the port is disconnected, or replaced
    by the macOS voice.
  - The key itself is never sent. Deleting it makes the agent create a new one at
    the next start.

## Troubleshooting

- **No menu bar icon** — `macos/jarvisctl status`; check *Allow in the
  Background*; `macos/jarvisctl start`.
- **Never wakes** — `macos/jarvisctl doctor`; check Privacy & Security →
  Microphone / Speech Recognition list *Jarvis Voice* as allowed.
- **“macOS currently blocks this”** — reading or clicking inside apps needs
  *Accessibility*, screenshots need *Screen & System Audio Recording*, Terminal
  and closing tabs need *Automation*: switch Jarvis Voice on in Privacy &
  Security. After a macOS screen-recording grant, Jarvis may need a restart
  (`macos/jarvisctl restart voice`).
- **Wakes by itself** (a video said “Jarvis”) — set `"requirePrefix": true`.
- **`npm start` fails with “address in use”** — the agent already serves the
  bridge and http://localhost:5173. Use that, or `macos/jarvisctl stop agent`.
- **It asks for permission again after an update** — the build was signed ad hoc
  (each build a new identity to macOS). Run `macos/jarvisctl signing-identity`
  once; after one last round of prompts, updates keep their permissions. A
  Screen Recording or Accessibility switch that is on may still belong to an
  older build: remove Jarvis Voice from that list with −, add
  `~/Applications/JarvisVoice.app` with +, then `macos/jarvisctl restart voice`.
- **macOS's “Quit & Reopen”** (after a Screen Recording change) restarts the app
  outside launchd; Jarvis Voice notices and hands itself back to its LaunchAgent,
  and `jarvisctl start/stop/restart voice` also stops any such stray copy.
- **He didn't catch your answer** — on a very busy Mac the recogniser can fall
  several seconds behind; he waits for it and asks again. `macos/jarvisctl answer
  allow` works too.

## Measured latency (this Mac, real voice turns through the speakers)

Same phrases, same flow (“Hey Jarvis.” → “Yes?” → question → follow-up), Apple
Silicon M1 Max under load (a local LLM using CPU, Zscaler on the network).
“Before” is the first installed build (median of 3), “after” the build with the
latency work (median of 3), “now” this version with tasks (9 conversations:
median, and p95 — with 9 samples the p95 is the slowest one). Values are first
question / follow-up where there are two.

| | before | after | now: median (p95) |
|---|---|---|---|
| Wake phrase recognised | ~50 ms after it ends | while it is still ending | about as it ends (−0.6 to +0.3 s) |
| “Hey Jarvis” → “Yes?” starts | 2.1 s | 0.04 s (0.03–0.4) | 0.55 s (3.0 s) |
| End of speech → request transcribed | 2.6 s | 0.3 s / 0.7 s | 1.2 s (4.2 s) / 1.3 s (4.7 s) — the recogniser trailing this busy Mac |
| End of speech → Claude's first word | 9.0 s / 5.5 s | 10.7 s / 6.4 s | 10.9 s (23.2 s) / 11.1 s (14.5 s) — Claude's own time; it varied 5–935 s during testing |
| Claude's first word → JARVIS's first word | 7.3 s | 2.2 s | 2.4 s (4.1 s) / 2.1 s (2.8 s) |
| End of speech → JARVIS starts speaking | 16.2 s / 8.7 s | 13.0 s / 8.1 s | 13.4 s (26.0 s) / 13.5 s (16.8 s) |
| “Open <app>” (local) → first word | 9.3 s to say it couldn't | 2.1–4.8 s, app verified in ~0.3 s | 0.33 s (3.8 s) typed, + transcription when spoken; app running after 0.11 s |
| “Close it” (local) → first word | — | 0.8 s | 0.12 s (0.19 s) typed |

Between “after” and “now” the voice path itself (wake detection, endpointing,
streaming, the voice) is unchanged apart from the task wrapper (~5 ms); the
spread in recognition and Claude's time is the Mac's load and the service on the
day. End of speech →
first word: −2.8 s (−17 %) against “before” for a first question; follow-ups were
slower this time (+4.8 s) because Claude's first word took 11.1 s instead of 5.5 s.

A warm Claude session (one kept connected while idle) brought Claude's first word
from 10–18 s down to ~7 s in isolated tests; the effort level made no consistent
difference. What remains is Claude's own response time.

### Tasks, several apps at once, and staying responsive

Measured on this Mac through Jarvis Voice's own pipeline (typed requests, so
speech recognition is not in these numbers; apps already in the disk cache).
“Before” is the build before the task manager, where Claude opened the apps one
after another.

| | before | after | difference |
|---|---|---|---|
| “Open Chess, Dictionary and Font Book” → all three running | 9.4 s (median of 3; 7.3–11.3) | 0.42 s (median of 5; 0.39–0.46) | −9.0 s (−96 %) |
| … → JARVIS's first word | 16.6 s | 0.64 s (0.61–3.3 s; the slow one synthesised a new sentence) | −16.0 s (−96 %) |
| … → answer finished | 19.8 s | 4.2 s | −15.6 s (−79 %) |
| “Hey Jarvis, what time is it?” said 3 s into a Claude web search | not heard — lost | answered 6.9 s after the question ended (3.7 s of it the recogniser catching up on this loaded Mac); the search went on as task 3 and was reported when done | — |
| Task manager overhead on top of the action itself | — | median 5 ms, p95 9 ms (n = 36) | |

Sequential versus parallel, same three apps, same build (median of 5):
all three running after **0.69 s** opened one after another (“open Chess, then
Dictionary, then Font Book”) and **0.42 s** at the same time — 39 % faster; each
launch takes a little longer when they overlap (0.24–0.58 s against 0.22–0.31 s),
the total is shorter. A Claude-planned request on the real Mac (“open Safari and
search for GitHub while opening Calculator”, `run_tasks`): Calculator ready after
0.48 s while Safari cold-launched (3.46 s), the search waited for Safari and took
0.06 s — 3.6 s for the plan against about 4.0 s one after another. In the task
manager's own tests, three independent 300 ms tasks finish in 323 ms together and
three tasks on one lock in 634 ms.

Single local commands (n = 12, median / p95):

| | median | p95 |
|---|---|---|
| “Open Calculator” → running | 110 ms | 277 ms |
| “Open Calculator” → first word | 332 ms | 3.8 s (a sentence not yet synthesised) |
| “Close Calculator” → process gone | 116 ms | 192 ms |
| “Close Calculator” → first word | 122 ms | 185 ms |
| “What time is it?” → first word | 33 ms (same minute, phrase cached) | 1.8 s (synthesised) |

Four Claude requests at once: three ran together (7.6, 8.4 and 9.4 s), the
fourth waited 5.4 s for a free slot, then took 5.5 s; each answer was announced
under its own task number. Claude Code processes went from 1 (the ready spare)
to 5 and back to 1 when the finished sessions closed — none left behind.

Accessibility lookups (finding a button, reading a window) could not be timed:
macOS Accessibility is not available to Jarvis Voice on this managed Mac (nor to
the shell used for testing). The app logs `accessibility: … in N ms` for each
lookup where it is available.

## Limitations

- **Accessibility on managed Macs.** Reading windows, clicking, typing and key
  presses need macOS Accessibility. On a Mac enrolled in company device
  management, an IT privacy profile can keep that switch from taking effect even
  when it looks on — Jarvis then says “macOS currently blocks this” rather than
  pretend. Screenshots (screen recording), Chrome (through the Claude extension),
  opening/closing apps, URLs, folders, Settings and Terminal still work.

- **Screen Recording on this Mac (unresolved).** Since 6 November Jarvis Voice
  stays “not granted” for Screen Recording even with its switch on, re-added with
  +, restarted — and with the stable signing identity, so the signature is not the
  cause. macOS genuinely withholds it: `macos/jarvisctl status` shows
  `screenContentVisible: false` (other apps' window titles stay hidden), and the
  device-management profile has no rule about it. Earlier builds had it on
  5 November. Screenshots and “look at my screen” need it; the guided flow asks,
  opens Settings, waits and then says honestly that macOS still has it off.
- Replies need Claude: typically ~5–8 s from the end of your question to his
  first word (a warm session saves 3–10 s of that; requests that use tools take
  longer). Opening and closing apps, the time and date, task commands and
  permission commands skip Claude.
- A new request while he's working needs his name (“Jarvis, …”): anything said
  without it is treated as talk in the room. Through the speakers, a reply he is
  *speaking* is interrupted rather than sent to the background.
- Several Claude tasks share your Claude account and rate limits; each one is a
  separate session, so a background task doesn't know what you said in another.
  “Continue task 2” brings its session back into the conversation.
- Through the Mac's speakers the level detector only partly hears a quiet or
  distant voice; he also counts words from the recogniser so as not to talk over
  you, but on a very busy Mac the recogniser can trail by several seconds.
- Through the Mac's speakers, interruption needs his name, “stop”, or clearly
  new words; any speech works with headphones.
- Accessibility exposes different amounts of detail per app; when it's thin, he
  falls back to a screenshot. Some apps (games, some Electron apps) expose little.
- Each request is a Claude turn on your account.
- If the web interface is open and initialised at the same time, both will
  answer “Hey Jarvis” — mute one.
- The Kokoro voice engine uses about 550 MB of memory and runs on the CPU; under
  heavy CPU load (a local LLM, say) its first word comes later. Set
  `JARVIS_AGENT_VOICE_ENGINE=0` in `agent.env` to use the instant macOS voice
  instead (Premium voices from System Settings → Accessibility → Spoken Content
  sound much better than the defaults).

## Windows and Linux

The same assistant runs on Windows and Linux too — the same wake phrase, commands, permission
broker and task rules, with each OS's own APIs. See [docs/setup-windows.md](../docs/setup-windows.md),
[docs/setup-linux.md](../docs/setup-linux.md) and [docs/architecture.md](../docs/architecture.md).
