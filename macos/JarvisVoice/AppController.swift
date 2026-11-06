import AppKit
import AVFoundation
import Speech

/// The voice loop:
///
///   idle ──"Hey Jarvis"──▶ listening ──quiet──▶ thinking ──reply──▶ speaking
///     ▲                         ▲ (interrupt)                          │
///     └── silence / "that's all" ◀── followUp (no wake word) ◀─────────┘
///
/// The microphone feeds Apple's on-device recogniser continuously, so the wake
/// phrase is spotted locally. Only the request that follows it is sent anywhere —
/// to the existing JARVIS bridge on this Mac. Simple commands ("open Safari",
/// "revoke camera access") are carried out here without Claude at all.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    enum State: String {
        case starting, downloading, permission, idle, listening, followUp, thinking, speaking, confirming, looking, muted, failed
    }

    /// What to do when the speaker next goes quiet.
    private enum AfterSpeech { case nothing, reply, followUp, endConversation, resumeThinking, idle, answer }
    /// What the utterance being heard is for.
    private enum Purpose { case request, answer }

    private(set) var state: State = .starting
    private var detail = ""
    private var config: Config
    private var wake: WakeMatcher
    private let menu = StatusMenu()
    private let speaker: Speaker
    private let control = ControlServer()
    private let mac = MacControl()
    private let camera = Camera()
    private var transcriber = Transcriber()
    private var audio: AudioInput?
    private var gate: AudioGate?
    private var bridge: BridgeConnection?
    private var warm: BridgeConnection?
    private var warmRetry = 2.0
    private var hotKey: HotKey?
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var engineTimer: Timer?
    private var routeWork: DispatchWorkItem?
    private var muted = false
    private var starting = false
    private var pausedBySystem = false
    private var restartWork: DispatchWorkItem?
    private let launched = Date()

    // What the recogniser has heard — in memory only, and only recently.
    private struct Segment { let text: String; let start: Double; let end: Double; let words: [Word] }
    private var finals: [Segment] = []
    private var volatile: Segment?
    private var wakeFloor = 0.0
    /// How far (recogniser clock) the recogniser has delivered results, dots included.
    private var processedUntil = 0.0

    // The current conversation.
    private var inConversation = false
    private var purpose = Purpose.request
    private var anchor = 0.0
    private var expectWake = false
    private var acknowledged = false
    /// Words of Jarvis's own voice to drop from the start of what is heard next ("yes" from "Yes?").
    private var echoWords = Set<String>()
    private var listenStarted = Date()
    private var lastChange = Date()
    private var lastHeard = ""
    private var bestHeard = ""
    private var wakeWordCount = 2
    /// When listening began (uptime ms), to tell whether the voice detector has heard you since.
    private var listenUptime = 0
    private var endpointTimer: Timer?
    private var thinkingAnchor = 0.0
    private var speakingAnchor = 0.0
    private var spokenWords = Set<String>()
    private var sentences = SentenceBuffer()
    private var spokeReply = false
    private var turnDone = false
    private var responseTimer: Timer?
    private var fillerTimer: Timer?
    private var fillerPlayed = false
    private var stillTimer: Timer?
    private var afterSpeech = AfterSpeech.nothing
    private var answerHandler: ((String) -> Void)?
    private var pendingDeny: (() -> Void)?
    /// The last answer to a question had a voice in it (or the recogniser had not caught up)
    /// but no words: asked once more rather than taken as "no".
    private var answerUnclear = false
    /// When the recogniser last produced new words (anyone's).
    private var lastWordsAt = Date.distantPast
    private var source = "wake"

    // Tasks: everything Jarvis is doing, the conversation's own Claude request, and the ones
    // carrying on in the background (each with its own bridge connection, so its own
    // Claude session, context and conversation-scoped permissions).
    private let tasks = TaskManager()
    private var foregroundTurn: ClaudeTurn?
    private var backgroundTurns: [ObjectIdentifier: ClaudeTurn] = [:]
    /// The task just sent to the background by "Jarvis, …" — "Jarvis, stop" cancels it.
    private var interjectedTask: Int?
    /// Background results and questions, said when you are not talking and he is not busy.
    private var pendingSpeech: [PendingSpeech] = []
    private var pendingTimer: Timer?
    /// Jobs whose outcome has already been reported, so nothing is said twice.
    private var reported = Set<Int>()
    /// When he last finished saying his own name (recogniser clock; infinite while he is
    /// saying it): his own voice saying "Jarvis Voice" must never count as you saying it.
    private var ownNameUntil = 0.0

    private struct PendingSpeech {
        let jobID: Int?
        let text: String
        var adopt: ClaudeTurn?
        var onAnswer: ((String) -> Void)?
        var onSkip: (() -> Void)?
        let created = Date()
        var isQuestion: Bool { onAnswer != nil }
    }

    @MainActor
    final class ResultBox { var result: MacResult? }

    @MainActor
    final class PayloadBox { var value: [String: Any] = [:] }

    // Timing of the current turn, for the latency log.
    private struct Timing {
        var source = ""
        var speechEnd: Date?, captured: Date?, sent: Date?, firstToken: Date?, firstAudio: Date?, done: Date?
        var actionMs: Int?
        var logged = true
    }
    private var timing = Timing()
    private var wakeHeardAt: Date?

    // Diagnostics for `jarvisctl status` (in memory only).
    private var wakes = 0
    private var requests = 0
    private var lastWakeAt: Date?
    private var lastRequest = ""
    private var lastProblem = ""
    private var lastLatency = ""

    override init() {
        let config = Config.load()
        self.config = config
        self.wake = WakeMatcher(config: config)
        self.speaker = Speaker(config: config)
        super.init()
        mac.interfaceURL = config.interfaceURL
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.handOverToLaunchd() { return }
        if ControlServer.anotherInstanceIsRunning(at: Paths.controlSocket) {
            log("Jarvis Voice is already running — this copy is exiting")
            Log.shared.flush()
            exit(0)
        }
        log("Jarvis Voice starting (pid \(getpid()), \(ProcessInfo.processInfo.operatingSystemVersionString))")
        menu.install(target: self)
        set(.starting, "Starting…")
        installSignalHandlers()
        observeSystemEvents()
        do {
            try control.start(path: Paths.controlSocket) { [weak self] line in
                await self?.handleControl(line) ?? "error"
            }
        } catch {
            logError("control socket unavailable: \(error.localizedDescription)")
        }
        if config.hotkey {
            hotKey = HotKey { [weak self] in MainActor.assumeIsolated { self?.talkPressed() } }
            if hotKey == nil { log("Option-Command-J is already taken by another app — use the menu bar instead") }
        }
        speaker.onIdle = { [weak self] in self?.speakerWentQuiet() }
        speaker.onAudioStart = { [weak self] line in self?.audioStarted(line) }
        SystemLoad.watch()
        tasks.limits["claude"] = max(1, config.maxClaudeTasks)
        tasks.onChange = { [weak self] job in self?.taskChanged(job) }
        AudioDevices.observe { [weak self] in self?.audioDevicesChanged() }
        Task { await speaker.refreshEngine() }
        engineTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.inConversation, !self.speaker.isBusy else { return }
                Task { await self.speaker.refreshEngine() }
            }
        }
        Task {
            mac.scanIfNeeded()
            await startListening()
            prepareWarm()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            speaker.prefetch(["Okay.", "Done.", config.dismissPhrase] + config.fillers)
        }
    }

    /// Started by macOS rather than by its LaunchAgent — System Settings' "Quit & Reopen" after a
    /// permission change does that. Hands over to launchd, so it stays supervised: restarted after
    /// a crash, stopped cleanly at logout, managed by jarvisctl.
    private static func handOverToLaunchd() -> Bool {
        let label = "local.jarvis.voice"
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != label else { return false }
        let plist = Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let installed = Paths.home.appendingPathComponent("Applications/JarvisVoice.app").standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: plist.path),
              Bundle.main.bundleURL.standardizedFileURL.path == installed else { return false }
        log("started outside launchd (by macOS) — handing over to the LaunchAgent")
        let handOver = Process()
        handOver.executableURL = URL(fileURLWithPath: "/bin/sh")
        handOver.arguments = ["-c", "sleep 1; /bin/launchctl kickstart gui/\(getuid())/\(label)"]
        try? handOver.run()
        Log.shared.flush()
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("quitting")
        cleanUp()
        Log.shared.flush()
    }

    private func installSignalHandlers() {
        // launchd sends SIGTERM at logout and shutdown: microphone off, connections
        // closed, then exit 0 so launchd does not restart us.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    log("received signal \(sig) — shutting down")
                    self?.cleanUp()
                    Log.shared.flush()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func cleanUp() {
        endpointTimer?.invalidate()
        stopResponseTimers()
        pendingDeny?()
        pendingDeny = nil
        // No orphans: every task is stopped and every Claude session it held is closed.
        for item in pendingSpeech { item.onSkip?() }
        pendingSpeech.removeAll()
        for job in tasks.active where job.parent == nil { tasks.cancel(job, reason: "Jarvis Voice quit") }
        for turn in backgroundTurns.values { turn.connection.close() }
        backgroundTurns.removeAll()
        speaker.stop()
        bridge?.close()
        bridge = nil
        warm?.close()
        warm = nil
        gate?.open.store(false, ordering: .relaxed)
        audio?.stop()
        control.stop()
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool, String)] = [
            (NSWorkspace.willSleepNotification, true, "the Mac is going to sleep"),
            (NSWorkspace.didWakeNotification, false, "the Mac woke up"),
            (NSWorkspace.sessionDidResignActiveNotification, true, "another user took over the screen"),
            (NSWorkspace.sessionDidBecomeActiveNotification, false, "this user is back"),
        ]
        for (name, pause, why) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if pause { self?.pauseForSystem(why) } else { self?.resumeAfterSystem(why) }
                }
            })
        }
    }

    private func pauseForSystem(_ why: String) {
        guard !pausedBySystem else { return }
        pausedBySystem = true
        log("pausing: \(why)")
        if inConversation { endConversation(reason: why, quiet: true) }
        gate?.open.store(false, ordering: .relaxed)
        audio?.stop()
    }

    private func resumeAfterSystem(_ why: String) {
        guard pausedBySystem else { return }
        pausedBySystem = false
        log("resuming: \(why)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.muted, !self.pausedBySystem, let audio = self.audio else { return }
                do {
                    try audio.start(device: self.chooseInput())
                    self.resetTranscript()
                    self.gate?.open.store(true, ordering: .relaxed)
                    if self.state == .idle || self.state == .failed { self.setIdle() }
                } catch {
                    self.audioFailed("the microphone could not restart after \(why): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - State

    private func set(_ newState: State, _ newDetail: String? = nil) {
        let changed = newState != state
        state = newState
        if let newDetail { detail = newDetail }
        if changed { log("state: \(newState.rawValue)") }
        menu.update(state: state, detail: detail, muted: muted)
    }

    private func setIdle() {
        set(.idle, "Say “\(config.displayWakePhrase)”")
        if !pendingSpeech.isEmpty { schedulePending(after: 0.6) }
    }

    private var gateSeconds: Double { gate?.seconds ?? 0 }

    // MARK: - Microphone, devices and recogniser

    private func chooseInput() -> AudioDevice? {
        let choice = AudioDevices.chooseInput(policy: config.inputDevice)
        log("audio: listening through \(choice.device?.description ?? "the default microphone") — \(choice.reason); speaking through \(AudioDevices.defaultOutput?.description ?? "the default output")")
        return choice.device
    }

    /// Headphones plugged in, AirPods connected, an input chosen in Sound settings…
    private func audioDevicesChanged() {
        routeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let audio = self.audio, !self.muted, !self.pausedBySystem else { return }
                let choice = AudioDevices.chooseInput(policy: self.config.inputDevice)
                let output = AudioDevices.defaultOutput
                if audio.engineRunning, choice.device?.id == audio.device?.id {
                    log("audio: devices changed — still \(choice.device?.description ?? "default") in, \(output?.description ?? "default") out")
                    return
                }
                log("audio: devices changed — input \(choice.device?.description ?? "default") (\(choice.reason)), output \(output?.description ?? "default")")
                audio.restart(device: choice.device)
                if self.state == .idle { self.setIdle() }
            }
        }
        routeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func startListening() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }

        set(.starting, "Checking microphone permission…")
        guard await microphoneAllowed() else {
            set(.permission, "Allow Jarvis Voice in System Settings → Privacy & Security → Microphone.")
            scheduleRestart(after: 5)
            return
        }
        await requestSpeechPermissionIfNeeded()

        do {
            set(.starting, "Loading on-device speech recognition…")
            let transcriber = Transcriber()
            transcriber.onEvent = { [weak self] event in self?.heard(event) }
            transcriber.onFailure = { [weak self] message in self?.recogniserFailed(message) }
            let format = try await transcriber.start(localeID: config.locale,
                                                     contextualStrings: config.contextualStrings) { [weak self] status in
                self?.set(.downloading, status)
            }
            self.transcriber = transcriber
            log("speech recognition: \(transcriber.engineName)")

            let gate = AudioGate(rate: format.sampleRate, minLevel: Float(config.voiceLevel))
            let input = AudioInput(target: format)
            input.onBuffer = { buffer, level in
                gate.observe(level: level)
                guard gate.open.load(ordering: .relaxed) else { return }
                gate.frames.wrappingAdd(Int(buffer.frameLength), ordering: .relaxed)
                transcriber.feed(buffer)
            }
            input.onFailure = { [weak self] message in MainActor.assumeIsolated { self?.audioFailed(message) } }
            input.onRouteChange = { [weak self] in MainActor.assumeIsolated { self?.audioDevicesChanged() } }
            self.gate = gate
            self.audio = input
            resetTranscript()
            if muted {
                set(.muted, "Microphone off")
                return
            }
            try input.start(device: chooseInput())
            gate.open.store(true, ordering: .relaxed)
            setIdle()
        } catch {
            logError("could not start listening: \(error.localizedDescription)")
            lastProblem = error.localizedDescription
            set(.failed, "Speech recognition could not start — retrying.")
            scheduleRestart(after: 15)
        }
    }

    private func scheduleRestart(after seconds: Double) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.restartListening() }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func restartListening() async {
        endConversation(reason: "restart", quiet: true)
        gate?.open.store(false, ordering: .relaxed)
        audio?.stop()
        audio = nil
        gate = nil
        await transcriber.stop()
        await startListening()
    }

    private func recogniserFailed(_ message: String) {
        logError(message)
        lastProblem = message
        set(.failed, "Speech recognition stopped — restarting.")
        scheduleRestart(after: 3)
    }

    private func audioFailed(_ message: String) {
        logError(message)
        lastProblem = message
        set(.failed, "The microphone stopped — retrying.")
        scheduleRestart(after: 5)
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            log("asking for microphone access (macOS shows a prompt)")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log("microphone access \(granted ? "granted" : "denied")")
            return granted
        default:
            return false
        }
    }

    private func requestSpeechPermissionIfNeeded() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        set(.starting, "Waiting for Speech Recognition permission…")
        log("asking for speech recognition access (macOS shows a prompt)")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
        }
        log("speech recognition access: \(MacPermissions.speech())")
    }

    // MARK: - Hearing

    private func resetTranscript() {
        finals.removeAll()
        volatile = nil
        wakeFloor = gateSeconds
    }

    private func heard(_ event: TranscriptEvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        processedUntil = max(processedUntil, event.end)
        if text.contains(where: { $0.isLetter }), text != volatile?.text { lastWordsAt = Date() }
        if event.isFinal, config.logTranscripts {
            log(String(format: "heard final %.2f–%.2f (%d timed words): %@", event.start, event.end, event.words.count, text))
        }
        if event.isFinal {
            let hasWords = text.contains(where: { $0.isLetter || $0.isNumber })
            if hasWords {
                finals.append(Segment(text: text, start: event.start, end: event.end, words: event.words))
            } else if let v = volatile, v.text.contains(where: { $0.isLetter || $0.isNumber }), v.end > event.start {
                // The final pass sometimes turns a short phrase it had already heard ("close it")
                // into "..": keep what it heard rather than lose the words.
                finals.append(v)
            }
            if finals.count > 50 { finals.removeFirst(finals.count - 50) }
            volatile = nil
        } else {
            volatile = text.isEmpty ? nil : Segment(text: text, start: event.start, end: event.end, words: event.words)
        }
        switch state {
        case .idle: lookForWakePhrase()
        case .listening, .followUp: noteProgress()
        case .confirming: if endpointTimer != nil { noteProgress() }
        case .thinking, .looking:
            lookForCancel()
            lookForInterjection()
        case .speaking: checkBargeIn()
        default: break
        }
    }

    private func lookForWakePhrase() {
        var recent: [Segment] = []
        if let last = finals.last, last.end > wakeFloor + 0.05 { recent.append(last) }
        if let v = volatile, v.end > wakeFloor + 0.05 { recent.append(v) }
        guard !recent.isEmpty, wake.contains(recent.map(\.text).joined(separator: " ")) else { return }
        wakeHeardAt = Date()
        // With word timings, the request is exactly what is said after the name.
        let names = Set(config.wakeWords.map { normalized($0) })
        for segment in recent {
            if let name = segment.words.first(where: { names.contains(normalized($0.text)) && $0.end > wakeFloor + 0.05 }) {
                beginConversation(anchor: name.end, expectWake: false, source: "wake")
                return
            }
        }
        let first = recent.first(where: { wake.contains($0.text) }) ?? recent[0]
        let fromWake = recent.filter { $0.start >= first.start }.map(\.text).joined(separator: " ")
        wakeWordCount = wake.wordsThroughWake(fromWake) ?? 2
        beginConversation(anchor: first.start, expectWake: true, source: "wake")
    }

    /// Everything said after `time` (recogniser clock) — word by word, using each word's own
    /// timestamp, so Jarvis's voice before that moment can never leak in.
    private func heardAfter(_ time: Double) -> String {
        var pieces: [String] = []
        for segment in finals + (volatile.map { [$0] } ?? []) where segment.end > time + 0.02 {
            if segment.words.isEmpty {
                // Untimed (provisional) text. If it began before `time`, it may hold his own voice
                // and yours in one stretch: drop his words from the front. The timestamped final
                // that follows settles it exactly.
                guard segment.end > time + 0.15 else { continue }
                if segment.start >= time - 0.1 {
                    pieces.append(segment.text)
                } else {
                    var words = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    while let first = words.first, normalized(first).isEmpty || spokenWords.contains(normalized(first)) {
                        words.removeFirst()
                    }
                    if !words.isEmpty { pieces.append(words.joined(separator: " ")) }
                }
                continue
            }
            let kept = segment.words.filter { $0.start >= time - 0.03 }.map(\.text).joined()
            if !kept.isEmpty { pieces.append(kept) }
        }
        return pieces.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func heardSince(_ time: Double) -> String {
        var parts = finals.filter { $0.end > time + 0.05 }.map(\.text)
        if let v = volatile, v.end > time + 0.05 { parts.append(v.text) }
        return parts.joined(separator: " ")
    }

    /// The utterance so far, without the wake phrase or Jarvis's own echo.
    private func currentRequest() -> String {
        var request: String
        let heard = expectWake ? heardSince(anchor) : heardAfter(anchor)
        if !expectWake {
            request = wake.strippingLeading(heard)
        } else if let after = wake.after(heard) {
            request = after
        } else {
            // The recogniser can rewrite the wake word as it firms up ("Jarvis" → "Travis");
            // the request still starts where it did.
            let words = heard.split(whereSeparator: { $0.isWhitespace })
            request = words.count > wakeWordCount ? words.dropFirst(wakeWordCount).joined(separator: " ") : ""
        }
        if !echoWords.isEmpty {
            var words = request.split(separator: " ").map(String.init)
            while let first = words.first, echoWords.contains(normalized(first)) { words.removeFirst() }
            request = words.joined(separator: " ")
        }
        return String(request.drop(while: { $0.isPunctuation || $0.isWhitespace }))
    }

    private func lookForCancel() {
        let said = normalized(wake.strippingLeading(heardAfter(thinkingAnchor)))
        guard !said.isEmpty, config.cancelPhrases.map(normalized).contains(said) else { return }
        log("request cancelled by voice")
        bridge?.interrupt()
        cancelForeground("cancelled by voice")
        endConversation(reason: "cancelled")
    }

    private func isCancelPhrase(_ text: String) -> Bool {
        config.cancelPhrases.map(normalized).contains(normalized(wake.strippingLeading(text)))
    }

    /// "Jarvis, …" while he is still working on a request: that request carries on as a
    /// background task, and he listens to the new one.
    private func lookForInterjection() {
        if ownNameUntil.isInfinite && !speaker.isBusy { ownNameUntil = gateSeconds } // stopped mid-line
        // Even over a filler ("One moment."): only his own line with his name in it is ignored.
        guard config.backgroundTasks, inConversation, let turn = foregroundTurn, !turn.over,
              state == .thinking || state == .looking, answerHandler == nil, ownNameUntil.isFinite else { return }
        let names = Set(config.wakeWords.map { normalized($0) })
        let floor = max(thinkingAnchor, ownNameUntil + 0.3)
        for segment in finals + (volatile.map { [$0] } ?? []) where segment.end > floor + 0.05 {
            if let name = segment.words.first(where: { names.contains(normalized($0.text)) && $0.start >= floor - 0.03 }) {
                interject(turn, anchor: name.end, expectWake: false)
                return
            }
        }
        // Untimed (provisional) text: only well clear of his own voice.
        if let v = volatile, v.words.isEmpty, v.start >= floor, wake.contains(v.text) {
            interject(turn, anchor: v.start, expectWake: true)
        }
    }

    private func interject(_ turn: ClaudeTurn, anchor: Double, expectWake: Bool) {
        sendToBackground(turn)
        interjectedTask = turn.job?.id
        if speaker.isBusy { speaker.stop() } // a filler: you are talking now
        afterSpeech = .nothing
        wakes += 1
        lastWakeAt = Date()
        source = "interjection"
        log("activated (interjection) — task \(turn.job?.id ?? 0) carries on in the background")
        playSound(config.wakeSound, volume: config.soundVolume)
        listen(from: anchor, expectWake: expectWake, as: .listening, ack: true)
    }

    /// Speaking over Jarvis stops him. With headphones any speech counts; through the
    /// Mac's speakers his own voice reaches the microphone too, so it takes his name,
    /// a stop word, or clearly new words.
    private func checkBargeIn() {
        guard config.bargeIn, afterSpeech == .reply || afterSpeech == .nothing, inConversation else { return }
        let heard = heardAfter(speakingAnchor)
        guard !heard.isEmpty else { return }
        let words = normalized(heard).split(separator: " ").map(String.init)
        let novel = words.filter { !spokenWords.contains($0) }
        guard !novel.isEmpty else { return }
        let nameSaid = wake.contains(heard) && !config.wakeWords.contains(where: { spokenWords.contains($0) })
        let stopWord = novel.contains { ["stop", "wait", "cancel", "pause", "quiet", "enough", "hold"].contains($0) }
        // Through the Mac's speakers anyone talking nearby sounds like new words, so only his
        // name or a stop word interrupts; with headphones, any clear speech does.
        let headphones = !(AudioDevices.defaultOutput?.isBuiltIn ?? true)
        let bySpeech = config.interruptWith == "speech" || (config.interruptWith != "name" && headphones)
        let fresh = bySpeech && novel.count >= 3 && Double(novel.count) >= Double(words.count) * 0.6
        guard nameSaid || stopWord || fresh else { return }

        log("interrupted while speaking (\(nameSaid ? "name" : stopWord ? "stop word" : "speech"))")
        // The new request starts at the first word that isn't his (or just after his name).
        let timed = (finals + (volatile.map { [$0] } ?? [])).flatMap(\.words).filter { $0.start >= speakingAnchor - 0.03 }
        let names = Set(config.wakeWords.map { normalized($0) })
        let nameWord = timed.first { names.contains(normalized($0.text)) }
        let firstNew = timed.first { !spokenWords.contains(normalized($0.text)) }
        let start = nameSaid ? (nameWord?.end ?? gateSeconds) : (firstNew?.start ?? gateSeconds)
        speaker.stop()
        bridge?.interrupt()
        cancelForeground("interrupted")
        stopResponseTimers()
        turnDone = true
        afterSpeech = .nothing
        source = "interruption"
        if stopWord && novel.count <= 2 && !nameSaid {
            listen(from: gateSeconds, expectWake: false, as: .followUp)
            return
        }
        listen(from: start, expectWake: false, as: .listening)
    }

    // MARK: - Listening for a request (or an answer)

    private func beginConversation(anchor: Double, expectWake: Bool, source: String) {
        wakes += 1
        lastWakeAt = Date()
        inConversation = true
        self.source = source
        log("activated (\(source))")
        playSound(config.wakeSound, volume: config.soundVolume)
        _ = openBridge() // a warm session is ready; otherwise this starts one while you speak
        listen(from: anchor, expectWake: expectWake, as: .listening, ack: source == "wake")
    }

    private func listen(from anchor: Double, expectWake: Bool, as newState: State, ack: Bool = false) {
        self.anchor = anchor
        self.expectWake = expectWake
        acknowledged = !ack
        echoWords = []
        listenStarted = Date()
        listenUptime = AudioGate.uptimeMs
        gate?.adapting.store(true, ordering: .relaxed)
        lastChange = Date()
        lastHeard = currentRequest()
        bestHeard = lastHeard
        switch newState {
        case .listening: set(newState, "Listening…")
        case .confirming: set(newState, "Waiting for your answer…")
        default: set(newState, "Listening — no need to say “\(config.displayWakePhrase)”")
        }
        startEndpointTimer()
    }

    private func startEndpointTimer() {
        endpointTimer?.invalidate()
        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.endpointTick() }
        }
    }

    private func stopEndpointTimer() {
        endpointTimer?.invalidate()
        endpointTimer = nil
    }

    private func noteProgress() {
        let now = currentRequest()
        if now != lastHeard {
            lastHeard = now
            lastChange = Date()
        }
        if !now.isEmpty {
            bestHeard = now
            acknowledged = true // they are already talking: no "Yes?"
        }
    }

    private static let continuation = try! NSRegularExpression(
        pattern: "(\\b(and|or|but|so|because|if|when|that|which|who|to|of|in|on|at|by|for|with|from|about|the|a|an|my|your|is|are|was|can|could|would|should|will|like|than|then|as)|[,;:–—-])$",
        options: [.caseInsensitive])

    private func endpointTick() {
        guard endpointTimer != nil, [.listening, .followUp, .confirming].contains(state) else {
            stopEndpointTimer()
            return
        }
        noteProgress()
        let elapsed = Date().timeIntervalSince(listenStarted)
        let quietMs = gate?.msSinceVoice ?? 0
        if bestHeard.isEmpty {
            if purpose == .request && state == .listening && !acknowledged && elapsed >= config.ackAfterSeconds && quietMs >= 300 {
                acknowledge() // just "Jarvis" and a pause
                return
            }
            let patience = state == .confirming ? config.answerSeconds
                : (state == .followUp ? config.followUpSeconds : config.ackAfterSeconds + config.followUpSeconds)
            if elapsed >= patience {
                if purpose == .answer { finishUtterance() } else { endConversation(reason: state == .followUp ? "no follow-up" : "nothing asked") }
            }
            return
        }
        let stable = Date().timeIntervalSince(lastChange)
        let trailing = bestHeard.trimmingCharacters(in: .whitespaces)
        let continues = Self.continuation.firstMatch(in: trailing, range: NSRange(trailing.startIndex..., in: trailing)) != nil
        let needQuiet = Int(((continues ? config.commandSilenceSeconds : config.endOfSpeechSeconds)) * 1000)
        // Trust the voice detector's "quiet" only if it actually heard you in this utterance.
        let voiceSeen = (gate?.lastVoiceMs ?? 0) > listenUptime
        if (voiceSeen && quietMs >= needQuiet && stable >= 0.35) || stable >= config.commandSilenceSeconds || elapsed >= config.maxCommandSeconds {
            finishUtterance()
        }
    }

    /// "Yes?" — with the microphone left open, so a request that starts over it isn't lost.
    private func acknowledge() {
        acknowledged = true
        echoWords = Set(normalized(config.acknowledgePhrase).split(separator: " ").map(String.init))
        let ack = echoWords
        speaker.acknowledge(config.acknowledgePhrase)
        anchor = gateSeconds
        expectWake = false
        listenStarted = Date()
        listenUptime = AudioGate.uptimeMs
        lastChange = Date()
        echoWords = ack
        set(.listening, "Listening…")
    }

    private func finishUtterance() {
        stopEndpointTimer()
        let quietMs = gate?.msSinceVoice ?? 0
        let speechEnd = Date().addingTimeInterval(-Double(min(quietMs, 3000)) / 1000)
        let forAnswer = purpose == .answer
        if !forAnswer {
            set(.thinking, "Thinking…")
            thinkingAnchor = gateSeconds
            timing = Timing(source: source, speechEnd: speechEnd, logged: false)
        }
        let transcriber = self.transcriber
        // Where speech ended, on the recogniser's clock.
        let spokenUntil = gateSeconds - Double(min(quietMs, 3000)) / 1000
        let voiceHeard = (gate?.lastVoiceMs ?? 0) > listenUptime
        Task { @MainActor in
            await transcriber.finalizeNow()
            // On a busy Mac the recogniser can run seconds behind the audio: wait until it has
            // processed everything up to the moment you stopped (up to 3 s; for the answer to a
            // question, which must not be lost, up to 8 s).
            let waitStart = Date()
            while Date().timeIntervalSince(waitStart) < (forAnswer ? 8 : 3) {
                if self.volatile == nil, self.processedUntil >= spokenUntil - 0.1 { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            // Behind the audio, or a voice with no words: the answer was not understood, rather than "no".
            self.answerUnclear = forAnswer && (voiceHeard || self.processedUntil < spokenUntil - 0.5)
            let text = self.currentRequest()
            if self.config.logTranscripts {
                log(String(format: "utterance from %.2f, speech ended %.2f, recogniser at %.2f after waiting %d ms: “%@”",
                           self.anchor, spokenUntil, self.processedUntil, Int(Date().timeIntervalSince(waitStart) * 1000), text))
            }
            let final = text.isEmpty ? self.bestHeard : text
            if forAnswer {
                self.deliverAnswer(final)
            } else {
                self.timing.captured = Date()
                self.submit(final)
            }
        }
    }

    private func submit(_ raw: String) {
        guard state == .thinking, inConversation else { return }
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Jarvis — stop": the request just sent to the background is the one to stop.
        if let id = interjectedTask, let job = tasks.job(id) {
            interjectedTask = nil
            if job.isActive, isCancelPhrase(request) {
                log("request cancelled by voice (task \(id))")
                _ = cancelTask(job)
                endConversation(reason: "cancelled")
                return
            }
        }
        if request.isEmpty {
            endConversation(reason: "nothing heard")
            return
        }
        if isEndPhrase(request) {
            log("conversation dismissed by voice")
            if config.dismissPhrase.isEmpty { endConversation(reason: "dismissed") } else { say(config.dismissPhrase, then: .endConversation) }
            return
        }
        requests += 1
        lastRequest = request
        log(config.logTranscripts ? "request: \(request)" : "request captured (\(request.split(separator: " ").count) words)")
        if config.localCommands && handleLocally(request) { return }
        // The same request twice (said again while it is still running) is not sent twice.
        let title = Self.taskTitle(request)
        if let same = tasks.active.first(where: { $0.kind == "claude" && normalized($0.title) == normalized(title) }) {
            speakLocal("I'm already working on that. It's task \(same.id).")
            return
        }
        ask(request)
    }

    /// A Claude task's name, from the request: "what's the weather in Paris".
    static func taskTitle(_ request: String) -> String {
        var t = request.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first sentence is what it is about ("What is the capital of Australia? Answer briefly.").
        if let end = t.range(of: "[?.!](\\s|$)", options: .regularExpression) { t = String(t[..<end.lowerBound]) }
        t = t.replacingOccurrences(of: "[?.!,;:]+$", with: "", options: .regularExpression)
        let words = t.split(separator: " ")
        if words.count > 9 {
            // Cut after a word that ends a phrase well, not on "the" or "of".
            var cut = Array(words.prefix(9))
            while let last = cut.last, cut.count > 5,
                  ["the", "a", "an", "of", "for", "to", "in", "on", "and", "with", "about", "by", "my", "your"].contains(last.lowercased()) {
                cut.removeLast()
            }
            t = cut.joined(separator: " ")
        }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        return first == "I" || first.hasPrefix("I'") ? t : t.lowercasedFirst
    }

    private func isEndPhrase(_ text: String) -> Bool {
        let ignored = Set(config.wakeWords.map { $0.lowercased() } + ["sir", "please", "ok", "okay", "hey", "and"])
        var words = normalized(text).split(separator: " ").map(String.init).filter { !ignored.contains($0) }
        guard !words.isEmpty else { return false }
        let phrases = config.endPhrases
            .map { normalized($0).split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        while !words.isEmpty {
            guard let match = phrases.first(where: { words.starts(with: $0) }) else { return false }
            words.removeFirst(match.count)
        }
        return true
    }

    // MARK: - Simple commands, carried out on the Mac without Claude

    private enum LocalIntent {
        case open(String), close(String), closeIt, switchTo(String), openInterface, closeInterface, whichApp
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    private func localIntent(_ request: String) -> LocalIntent? {
        var t = normalized(wake.strippingLeading(request))
        for word in ["please ", "can you ", "could you ", "would you "] where t.hasPrefix(word) { t.removeFirst(word.count) }
        for word in [" please", " for me", " now", " right now"] where t.hasSuffix(word) { t.removeLast(word.count) }
        let interface = "(your|the jarvis|jarvis's|jarvis|the) (interface|ui|dashboard|website|web interface|web page|window)"
        if Self.match("(open|show|bring up|launch|pull up)( me)? \(interface)", t) != nil || t == "open jarvis" || t == "show jarvis" {
            return .openInterface
        }
        if Self.match("(close|hide|dismiss|shut)( down)? \(interface)", t) != nil { return .closeInterface }
        if Self.match("(which|what) (app|application|program|window) (is|am i)( this| in| using| active| open| in front| on top| frontmost)( right now)?", t) != nil {
            return .whichApp
        }
        if Self.match("(close|quit|exit|shut down)( it| this| that| this app| that app| the app| this application| the current app| the current application| that application)", t) != nil {
            return .closeIt
        }
        if let g = Self.match("(open|launch|start|run|fire up)( up)? (the )?(.+?)( app| application)?", t) { return .open(g[4]) }
        if let g = Self.match("(close|quit|exit)( out of)? (the )?(.+?)( app| application)?", t) { return .close(g[4]) }
        if let g = Self.match("(switch to|bring up|go to|show me|show) (the )?(.+?)( app| application)?", t) { return .switchTo(g[3]) }
        return nil
    }

    /// True when the request was handled here; false hands it to Claude.
    private func handleLocally(_ request: String) -> Bool {
        let resolveApp = { [mac] (name: String) in mac.resolve(name).map { ($0.name, $0.bundleID) } }
        let words = wake.strippingLeading(request)
        if let command = TaskCommand.parse(words) {
            // "Stop reading my files" with nothing like that running is about a permission.
            if case .cancelNamed(let phrase) = command, tasks.find(phrase) == nil,
               let permission = PermissionCommand.parse(request, resolveApp: resolveApp) {
                timing.source = "local"
                Task { await self.runPermissionCommand(permission) }
                return true
            }
            timing.source = "local"
            runTaskCommand(command)
            return true
        }
        if let command = PermissionCommand.parse(request, resolveApp: resolveApp) {
            timing.source = "local"
            Task { await self.runPermissionCommand(command) }
            return true
        }
        // Several apps in one go: "open Chess, Dictionary and Font Book" — at the same time.
        if let plan = AppPlan.parse(words, isApp: { [mac] name in mac.resolve(name) != nil || mac.running(name) != nil }) {
            runAppPlan(plan)
            return true
        }
        guard let intent = localIntent(request) else { return false }
        switch intent {
        case .open(let name):
            guard mac.resolve(name) != nil else { return false } // "open my Jarvis project" is Claude's
            runAppPlan(AppPlan(verb: .open, stages: [[name]]))
        case .switchTo(let name):
            guard let info = mac.resolve(name) else { return false } // "go to YouTube" is Claude's
            runLocal("switch to \(name)", title: "switching to \(info.name)", op: "switch_to_app", args: ["name": name]) { await self.mac.switchTo(name) }
        case .close(let name):
            guard mac.running(name) != nil || mac.resolve(name) != nil else { return false }
            runAppPlan(AppPlan(verb: .close, stages: [[name]]))
        case .closeIt:
            // "It" is the app Jarvis last opened or used, else the one in front.
            if let last = mac.lastApp, mac.running(last.name) != nil {
                runAppPlan(AppPlan(verb: .close, stages: [[last.name]]))
            } else if let front = mac.frontmost, let name = front.localizedName {
                runAppPlan(AppPlan(verb: .close, stages: [[name]]))
            } else {
                speakLocal("Which app should I close?")
            }
        case .openInterface:
            runLocal("open the interface", title: "opening my interface", op: "interface") { await self.mac.interface("open") }
        case .closeInterface:
            runLocal("close the interface", title: "closing my interface", op: "interface") { await self.mac.interface("close") }
        case .whichApp:
            let front = mac.frontmost?.localizedName
            let title = mac.frontmost.flatMap { mac.windowTitle($0) }
            speakLocal(front.map { "\($0) is in front\(title.map { ", showing \($0.prefix(60))" } ?? "")." } ?? "No app is in front.")
        }
        return true
    }

    /// One Mac action as a task: answered at once when it is quick; otherwise acknowledged,
    /// so the conversation carries on, and reported when it is done.
    private func runLocal(_ label: String, title: String, op: String, args: [String: Any] = [:],
                          _ action: @escaping () async -> MacResult) {
        let started = Date()
        timing.source = "local"
        log("local command: \(label)")
        let locks = mac.resources(op: op, args: args)
        let job = tasks.run(title, kind: "app", exclusive: locks.exclusive, shared: locks.shared, timeout: 40) { _ in
            let result = await action()
            return result.error == nil ? .done(result.speech) : .failed(result.speech)
        }
        Task { @MainActor in
            let quick = await self.tasks.wait(job, timeout: self.config.backgroundAfterSeconds)
            if !quick, self.inConversation, self.state == .thinking {
                self.timing.actionMs = Int(Date().timeIntervalSince(started) * 1000)
                self.speakLocal("Working on it — that's task \(job.id).")
            }
            _ = await self.tasks.wait(job)
            self.reported.insert(job.id)
            PermissionStore.record(["layer": "action", "action": label, "result": job.status.rawValue, "via": "voice command",
                                    "task": job.id, "ms": job.elapsedMs])
            if quick {
                self.timing.actionMs = Int(Date().timeIntervalSince(started) * 1000)
                guard self.inConversation, self.state == .thinking else { return }
                self.speakLocal(job.message)
            } else if job.status != .cancelled {
                self.announce(job.message, job: job)
            }
        }
    }

    /// Opens or closes apps as separate tasks: every app in a stage at the same time, the
    /// stages in order. One app failing ("isn't installed") never holds up the others.
    private func runAppPlan(_ plan: AppPlan) {
        let started = Date()
        timing.source = "local"
        let opening = plan.verb == .open
        var group: [(job: TaskManager.Job, name: String)] = []
        var previous: [Int] = []
        for stage in plan.stages {
            var current: [Int] = []
            for name in stage {
                let info = mac.resolve(name) ?? mac.running(name).flatMap { mac.info(for: $0) }
                let display = info?.name ?? MacControl.displayName(name)
                let locks = mac.resources(op: opening ? "open_app" : "close_app", args: ["name": name])
                let job = tasks.run((opening ? "opening " : "closing ") + display, kind: "app",
                                    exclusive: locks.exclusive, shared: locks.shared, dependsOn: previous,
                                    retries: opening ? 1 : 0, timeout: opening ? 40 : 20) { [mac] _ in
                    let result = opening ? await mac.openApp(name) : await mac.closeApp(name, force: false)
                    return result.error == nil ? .done(result.speech) : .failed(result.speech, retry: result.retryable)
                }
                group.append((job, display))
                current.append(job.id)
            }
            previous = current
        }
        let jobs = group.map(\.job)
        log("local command: \(opening ? "open" : "close") \(group.map(\.name).joined(separator: ", "))"
            + (group.count > 1 ? " as tasks \(jobs.map { String($0.id) }.joined(separator: ", "))" : ""))
        Task { @MainActor in
            let quick = await self.tasks.waitAll(jobs, timeout: self.config.backgroundAfterSeconds)
            if !quick, self.inConversation, self.state == .thinking {
                // A slow launch: say what's happening and carry on listening.
                self.timing.actionMs = Int(Date().timeIntervalSince(started) * 1000)
                let waiting = group.filter { $0.job.isActive }.map(\.name)
                self.speakLocal("\(opening ? "Opening" : "Closing") \(Self.list(waiting)).")
            }
            _ = await self.tasks.waitAll(jobs)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            for entry in group {
                self.reported.insert(entry.job.id)
                PermissionStore.record(["layer": "action", "action": "\(opening ? "open" : "close") \(entry.name)", "result": entry.job.status.rawValue,
                                        "via": "voice command", "task": entry.job.id, "ms": entry.job.elapsedMs])
            }
            if group.count > 1 { log("tasks \(jobs.map { String($0.id) }.joined(separator: ", ")) finished together in \(ms) ms") }
            let summary = self.appSummary(opening, group)
            if quick {
                self.timing.actionMs = ms
                guard self.inConversation, self.state == .thinking else { return }
                self.speakLocal(summary)
                // "Close it" usually follows "open it": have the answer ready.
                if opening, let app = self.mac.lastApp { self.speaker.prefetch(["\(app.name) is closed."]) }
            } else if !jobs.allSatisfy({ $0.status == .cancelled }) {
                self.announce(summary, job: nil)
            }
        }
    }

    /// "Chess and Dictionary are open. VS Code isn't installed on this Mac."
    private func appSummary(_ opening: Bool, _ group: [(job: TaskManager.Job, name: String)]) -> String {
        if group.count == 1, let only = group.first, only.job.status != .cancelled { return only.job.message }
        let done = opening ? "open" : "closed"
        var fine: [String] = [], notes: [String] = []
        var notInstalled = false
        for (job, name) in group {
            switch job.status {
            case .done where job.message == "\(name) is \(done).":
                fine.append(name)
            case .done, .failed:
                var message = job.message
                if message.contains("I won't download or install") {
                    notInstalled = true
                    message = message.replacingOccurrences(of: " I won't download or install anything without your say-so.", with: "")
                }
                notes.append(message)
            case .cancelled:
                notes.append("I stopped \(opening ? "opening" : "closing") \(name)" + (opening && job.started != nil ? "; it may still finish opening." : "."))
            default:
                break
            }
        }
        var parts: [String] = []
        if !fine.isEmpty { parts.append("\(Self.list(fine)) \(fine.count == 1 ? "is" : "are") \(done).") }
        parts += notes
        if notInstalled { parts.append("I won't install anything without your say-so.") }
        return parts.joined(separator: " ")
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    // MARK: - Tasks by voice

    private func runTaskCommand(_ command: TaskCommand) {
        switch command {
        case .time:
            let f = DateFormatter()
            f.locale = Locale(identifier: config.locale)
            f.timeStyle = .short
            f.dateStyle = .none
            speakLocal("It's \(f.string(from: Date())).")
        case .date:
            let f = DateFormatter()
            f.locale = Locale(identifier: config.locale)
            f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            speakLocal("It's \(f.string(from: Date())).")
        case .status:
            speakLocal(statusReport())
        case .cancel(let id):
            guard let job = tasks.job(id) else { return speakLocal("There's no task \(id).") }
            speakLocal(cancelTask(job))
        case .cancelNamed(let phrase):
            guard let job = tasks.find(phrase) else { return speakLocal("I'm not running anything like that.") }
            speakLocal(cancelTask(job))
        case .cancelLatest:
            guard let job = tasks.latestActive else {
                // Nothing running: "stop that" just means "that's enough".
                if config.dismissPhrase.isEmpty { endConversation(reason: "dismissed") } else { say(config.dismissPhrase, then: .endConversation) }
                return
            }
            speakLocal(cancelTask(job))
        case .cancelAll:
            speakLocal(cancelAllTasks())
        case .stopEverything:
            let summary = cancelAllTasks()
            speaker.stop()
            say(summary == "Nothing is running." ? "Very good." : summary, then: .endConversation)
        case .resume(let id):
            resumeTask(id)
        }
    }

    /// "Task 1: open Chrome and search for GitHub, opening Google Chrome. Task 3: waiting for camera permission."
    private func statusReport() -> String {
        let live = tasks.active.filter { $0.parent == nil }.sorted { $0.id < $1.id }
        let waitingToSay = pendingSpeech.filter { !$0.isQuestion }.compactMap(\.jobID)
        if live.isEmpty {
            if let id = waitingToSay.first { return "Nothing is running. Task \(id) has finished; I'll give you its answer now." }
            return "Nothing at the moment. I'm just listening."
        }
        var lines: [String] = []
        for job in live {
            var line = "Task \(job.id): \(job.title)"
            let step = tasks.active.first { $0.parent == job.id && $0.status == .running }
            if pendingSpeech.contains(where: { $0.jobID == job.id && $0.isQuestion }) {
                line += ", waiting for your answer to a question"
            } else if let step, !step.detail.isEmpty {
                line += ", \(step.detail)"
            } else if let step {
                line += ", \(step.title)"
            } else if !job.detail.isEmpty {
                line += ", \(job.detail)"
            } else if job.status != .running {
                line += ", waiting its turn"
            }
            lines.append(line + ".")
        }
        let head = live.count > 1 ? "I'm working on \(live.count) tasks. " : ""
        return head + lines.joined(separator: " ")
    }

    /// Stops one task — and only that one.
    private func cancelTask(_ job: TaskManager.Job) -> String {
        let top = job.parent.flatMap { tasks.job($0) }.flatMap { $0.isActive ? $0 : nil } ?? job
        guard top.isActive else {
            switch top.status {
            case .done: return "Task \(top.id) has already finished."
            case .failed: return "Task \(top.id) had already stopped, because it failed."
            default: return "Task \(top.id) was already stopped."
            }
        }
        let launching = top.kind == "app" && top.status == .running && top.title.hasPrefix("opening ")
        guard tasks.cancel(top, reason: "cancelled by voice") else { return "Task \(top.id) can't be stopped safely right now." }
        reported.insert(top.id)
        removePending(for: top.id)
        PermissionStore.record(["layer": "task", "task": top.id, "action": "cancel", "via": "voice command"])
        return "Stopped task \(top.id), \(top.title)." + (launching ? " macOS had already started opening it, so it may still appear." : "")
    }

    private func cancelAllTasks() -> String {
        let live = tasks.active.filter { $0.parent == nil }
        guard !live.isEmpty else { return "Nothing is running." }
        var stopped = 0
        for job in live where tasks.cancel(job, reason: "cancelled by voice") {
            stopped += 1
            reported.insert(job.id)
            removePending(for: job.id)
        }
        PermissionStore.record(["layer": "task", "action": "cancel all", "count": stopped, "via": "voice command"])
        let kept = live.count - stopped
        return "Stopped \(stopped == 1 ? "1 task" : "\(stopped) tasks")." + (kept > 0 ? " \(kept) couldn't be stopped safely." : "")
    }

    /// "Continue task 1": its waiting question or answer now, and its session for what you say next.
    private func resumeTask(_ id: Int) {
        guard let job = tasks.job(id) else { return speakLocal("There's no task \(id).") }
        if let index = pendingSpeech.firstIndex(where: { $0.jobID == id }) {
            let item = pendingSpeech.remove(at: index)
            stopEndpointTimer()
            if let onAnswer = item.onAnswer {
                askUser(item.text, onAnswer: onAnswer)
            } else {
                if let turn = item.adopt, !turn.connection.isClosed, foregroundTurn.map({ $0.over }) ?? true { adopt(turn) }
                speakLocal(item.text)
            }
            return
        }
        let turn = backgroundTurns.values.first { $0.job?.id == id }
        switch job.status {
        case .queued, .waiting:
            speakLocal("Task \(id) is waiting its turn\(job.detail.isEmpty ? "" : ": \(job.detail)"). It will start as soon as it can.")
        case .running:
            if let turn, foregroundTurn.map({ $0.over }) ?? true {
                // Back to the foreground: what it has said so far, then the rest as it comes.
                adopt(turn)
                turnDone = false
                spokeReply = false
                fillerPlayed = true
                sentences = SentenceBuffer()
                timing = Timing(source: "resumed", speechEnd: Date(), logged: true)
                set(.thinking, "Working on task \(id)…")
                thinkingAnchor = gateSeconds
                afterSpeech = .resumeThinking
                speaker.enqueue("Back to task \(id). Still working on it.")
                startResponseTimers()
                for sentence in sentences.push(turn.reply) { speakReply(sentence) }
            } else {
                speakLocal("Task \(id) is still running: \(job.title).")
            }
        case .done:
            if let turn, !turn.connection.isClosed, foregroundTurn.map({ $0.over }) ?? true { adopt(turn) }
            let answer = turn.map(\.reply).flatMap { $0.isEmpty ? nil : speakable($0) } ?? job.message
            speakLocal("Task \(id) has finished. \(answer)")
        case .failed:
            speakLocal("Task \(id) didn't work: \(job.message)")
        case .cancelled:
            speakLocal("Task \(id) was stopped. Ask me again if you'd like it done.")
        }
    }

    private func speakLocal(_ text: String) {
        turnDone = true
        spokeReply = true
        sentences = SentenceBuffer()
        if state != .speaking {
            prepareToSpeak(listening: true)
            set(.speaking, "Speaking…")
        }
        afterSpeech = .reply
        // Sentence by sentence, so the first one starts while the rest are prepared.
        var split = SentenceBuffer()
        var lines = split.push(text + " ")
        if let tail = split.flush() { lines.append(tail) }
        for line in lines {
            spokenWords.formUnion(normalized(line).split(separator: " ").map(String.init))
            speaker.enqueue(line)
        }
    }

    // MARK: - Permissions by voice

    private func runPermissionCommand(_ command: PermissionCommand) async {
        switch command {
        case .list:
            speakLocal(await permissionsSummary(detailed: false))
        case .listApps:
            speakLocal(appsSummary())
        case .can(let what):
            speakLocal(canAnswer(what))
        case .reset:
            askUser("Reset all of my permissions, so I ask before using anything again?") { [weak self] said in
                guard let self else { return }
                if PermissionAnswer.parse(said)?.allows == true {
                    PermissionStore().save()
                    PermissionStore.record(["layer": "permission", "capability": "all", "decision": "reset", "via": "voice command"])
                    self.speakLocal("Done. I'll ask before using anything again.")
                } else {
                    self.speakLocal("Very good. Nothing has changed.")
                }
            }
        case .change(let capability, let target, let allow, let label):
            if allow {
                // Granting is never taken from a single phrase: it gets its own spoken yes.
                askUser(grantQuestion(capability, target: target, label)) { [weak self] said in
                    guard let self else { return }
                    if PermissionAnswer.parse(said)?.allows == true {
                        self.apply(capability, target: target, allow: true, label: label)
                        self.speakLocal(self.grantMessage(capability, label))
                    } else {
                        self.speakLocal("Very good. Nothing has changed.")
                    }
                }
            } else {
                apply(capability, target: target, allow: false, label: label)
                var message = revokeMessage(capability, target: target, label)
                // "Stop controlling applications" also stops what is controlling one right now.
                if capability == "app" {
                    let controlling = tasks.active.filter { job in
                        job.kind == "mac" && ["clicking", "typing", "pressing", "reading"].contains(where: { job.title.hasPrefix($0) })
                            && (target.isEmpty || job.exclusive.union(job.shared).contains("app:\(target)"))
                    }
                    for job in controlling { tasks.cancel(job, reason: "you stopped app control") }
                    if !controlling.isEmpty { message += " I've also stopped \(controlling.count == 1 ? "the task" : "\(controlling.count) tasks") that \(controlling.count == 1 ? "was" : "were") doing that." }
                }
                speakLocal(message)
            }
        }
    }

    private func apply(_ capability: String, target: String, allow: Bool, label: String) {
        var store = PermissionStore.load()
        let v = allow ? "allow" : "deny"
        switch capability {
        case "files":
            if target.isEmpty {
                store.capabilities["files.read"] = v
                store.capabilities["files.write"] = v
            } else {
                store.folders.removeAll { $0.path == target }
                store.folders.append(.init(path: target, access: v))
            }
        case "app":
            if target.isEmpty { store.capabilities["app"] = v } else { store.apps[target] = v }
        case "microphone":
            setMuted(!allow)
        default:
            store.capabilities[capability] = v
        }
        store.save()
        PermissionStore.record(["layer": "permission", "capability": capability, "target": target, "decision": v, "via": "voice command"])
        log("permission \(capability)\(target.isEmpty ? "" : " (\(target))") set to \(v) by voice")
    }

    /// The spoken yes a grant always needs, worded for what is being granted.
    private func grantQuestion(_ capability: String, target: String, _ label: String) -> String {
        let what: String
        switch capability {
        case "app": what = target.isEmpty ? "read, click and type in other apps when you ask" : "control \(label) when you ask"
        case "apps.open": what = "open apps again"
        case "apps.close": what = "close apps again"
        case "camera": what = "use the camera when you ask"
        case "screen": what = "look at your screen when you ask"
        case "shell": what = "run commands when you ask"
        case "web": what = "search the web"
        case "microphone": what = "listen again"
        case "files": what = target.isEmpty ? "read and change your files when you ask" : "use \(label)"
        default: what = "use \(label)"
        }
        return "Allow me to \(what)? Say allow to confirm."
    }

    /// Says exactly what changed: Jarvis's own permission, never a claim about macOS's.
    private func revokeMessage(_ capability: String, target: String = "", _ label: String) -> String {
        switch capability {
        case "camera":
            return "Done. I won't use the camera." + (MacPermissions.camera() == "granted"
                ? " macOS still lists me as allowed to use it; to remove that too, switch me off in System Settings, Privacy and Security, Camera." : "")
        case "screen":
            return "Done. I won't look at your screen." + (MacPermissions.screenRecording() == "granted"
                ? " macOS still allows me screen recording; you can switch that off in System Settings, Privacy and Security." : "")
        case "app":
            let what = target.isEmpty ? "read, click or type in other apps" : "control \(label)"
            return "Done. I won't \(what)." + (target.isEmpty ? " I can still open and close apps when you ask." : "")
                + (MacPermissions.accessibility() == "granted"
                    ? " macOS's Accessibility access is still on; switch it off in System Settings if you want that gone too."
                    : " That's my own setting; macOS's Accessibility permission isn't on for me anyway.")
        case "apps.open":
            return "Done. I won't open apps until you say “allow opening apps”."
        case "apps.close":
            return "Done. I won't close apps until you say “allow closing apps”."
        case "microphone":
            return "I've muted myself. The microphone stays off until you unmute me from the menu bar."
        default:
            return "Done. I won't use \(label)."
        }
    }

    private func grantMessage(_ capability: String, _ label: String) -> String {
        switch capability {
        case "camera" where MacPermissions.camera() != "granted":
            return "Done. macOS will ask you to allow the camera the first time I use it."
        case "screen" where MacPermissions.screenRecording() != "granted":
            return "Done. macOS still needs to allow screen recording; I'll ask it when I first need to look."
        case "app" where MacPermissions.accessibility() != "granted":
            return "Done. To read or click inside \(label == "controlling other apps" ? "other apps" : label), macOS also needs Accessibility switched on for me; I'll guide you there when it's needed."
        case "app" where label == "controlling other apps":
            return "Done. I can control other apps again when you ask."
        case "apps.open", "apps.close":
            return "Done. I can \(capability == "apps.open" ? "open" : "close") apps again when you ask."
        default:
            return "Done. I can use \(label) when you ask."
        }
    }

    private func permissionsSummary(detailed: Bool) async -> String {
        let store = PermissionStore.load()
        var free: [String] = [], ask: [String] = [], off: [String] = []
        for (capability, label) in [("apps.open", "open apps"), ("apps.close", "close apps"), ("web", "search the web"),
                                    ("camera", "use the camera"), ("screen", "look at your screen"), ("files.read", "read files"),
                                    ("files.write", "change files"), ("shell", "run commands"), ("app", "control apps")] {
            switch store.value(capability) {
            case "allow": free.append(label)
            case "deny": off.append(label)
            default: ask.append(label)
            }
        }
        let names = { (ids: [String]) in ids.map { id in self.mac.installed.first(where: { $0.bundleID == id })?.name ?? id } }
        let allowedApps = names(store.apps.filter { $0.value == "allow" }.map(\.key))
        let blockedApps = names(store.apps.filter { $0.value == "deny" }.map(\.key))
        let blockedFolders = store.folders.filter { $0.access == "deny" }.map { ($0.path as NSString).lastPathComponent }
        var parts: [String] = []
        if !free.isEmpty { parts.append("I can \(free.joined(separator: ", ")) when you ask.") }
        if !ask.isEmpty { parts.append("I'll ask before I \(ask.joined(separator: ", ")).") }
        if !off.isEmpty { parts.append("You've turned off: \(off.joined(separator: ", ")).") }
        if !allowedApps.isEmpty { parts.append("You've let me control \(allowedApps.joined(separator: ", ")).") }
        if !blockedApps.isEmpty { parts.append("You've blocked \(blockedApps.joined(separator: ", ")).") }
        if !blockedFolders.isEmpty { parts.append("I'm kept out of \(blockedFolders.joined(separator: ", ")).") }
        let os = [("microphone", MacPermissions.microphone()), ("speech recognition", MacPermissions.speech()),
                  ("camera", MacPermissions.camera()), ("screen recording", MacPermissions.screenRecording()),
                  ("accessibility", MacPermissions.accessibility())]
        let granted = os.filter { $0.1 == "granted" }.map(\.0)
        let notYet = os.filter { $0.1 != "granted" }.map(\.0)
        var line = "macOS has given me \(granted.isEmpty ? "nothing yet" : granted.joined(separator: ", "))"
        if !notYet.isEmpty { line += "; not \(notYet.joined(separator: ", "))" }
        parts.append(line + ".")
        if detailed {
            parts.append("Notifications: \(await MacPermissions.notifications()). Automation of Terminal: \(MacPermissions.automation("com.apple.Terminal")), Safari: \(MacPermissions.automation("com.apple.Safari")), Chrome: \(MacPermissions.automation("com.google.Chrome")).")
        }
        return parts.joined(separator: " ")
    }

    private func appsSummary() -> String {
        let store = PermissionStore.load()
        let name = { (id: String) in self.mac.installed.first(where: { $0.bundleID == id })?.name ?? id }
        let allowed = store.apps.filter { $0.value == "allow" }.map { name($0.key) }
        let blocked = store.apps.filter { $0.value == "deny" }.map { name($0.key) }
        var s = "I can open and close any app you name."
        s += allowed.isEmpty ? " I'll ask before controlling one." : " You've let me control \(allowed.joined(separator: ", ")); for others I'll ask first."
        if !blocked.isEmpty { s += " You've blocked \(blocked.joined(separator: ", "))." }
        if MacPermissions.accessibility() != "granted" { s += " macOS hasn't given me Accessibility yet, which reading and clicking inside apps needs." }
        return s
    }

    private func canAnswer(_ what: String) -> String {
        let store = PermissionStore.load()
        if let c = PermissionCommand.capability(for: what, resolveApp: { [mac] n in mac.resolve(n).map { ($0.name, $0.bundleID) } }) {
            if c.capability == "app", !c.target.isEmpty {
                let rule = store.apps[c.target] ?? store.value("app")
                let os = MacPermissions.accessibility() == "granted" ? "" : " Reading or clicking inside it also needs macOS's Accessibility permission, which I don't have yet."
                switch rule {
                case "deny": return "No. You've blocked me from \(c.label)."
                case "allow": return "Yes, I can open and control \(c.label)." + os
                default: return "I can open \(c.label); I'll ask before controlling it." + os
                }
            }
            let key = c.capability == "files" ? "files.read" : c.capability
            switch store.value(key) {
            case "deny": return "No. You've turned off \(c.label)."
            case "allow": return "Yes, I can use \(c.label)."
            default: return "Only after asking you first."
            }
        }
        return "I'm not sure what you mean by \(what)."
    }

    // MARK: - Asking you a question and hearing the answer

    private func askUser(_ question: String, onAnswer: @escaping (String) -> Void) {
        stopEndpointTimer()
        stopFiller()
        answerHandler = onAnswer
        purpose = .answer
        // The microphone keeps feeding the recogniser (interruption is off while he asks), so
        // the answer arrives with full context; the question's own words are excluded by time.
        prepareToSpeak(listening: true)
        set(.confirming, "Waiting for your answer…")
        afterSpeech = .answer
        spokenWords.formUnion(normalized(question).split(separator: " ").map(String.init))
        speaker.enqueue(question)
    }

    private func deliverAnswer(_ text: String) {
        let handler = answerHandler
        answerHandler = nil
        purpose = .request
        handler?(text)
    }

    private func handleConfirm(_ id: String, _ payload: [String: Any], _ connection: BridgeConnection) {
        let foreground = connection === bridge
        let job = foreground ? foregroundTurn?.job : backgroundTurn(connection)?.job
        guard foreground ? inConversation : (job?.isActive == true) else {
            connection.reply(id, ["decision": "deny"])
            return
        }
        let kind = payload["kind"] as? String ?? "permission"
        let capability = payload["capability"] as? String ?? ""
        var target = payload["target"] as? String ?? ""
        var question = payload["question"] as? String ?? "Shall I go ahead?"
        if capability == "app", target.isEmpty || target == "frontmost", let front = mac.frontmost {
            question = question.replacingOccurrences(of: "the current app", with: front.localizedName ?? "the current app")
            target = front.bundleIdentifier ?? target
        }
        let rememberable = payload["rememberable"] as? Bool ?? false
        log("asking for permission: \(capability) (\(kind))\(foreground ? "" : " for background task \(job?.id ?? 0)")")
        var attempts = 0
        func finish(_ said: String) {
            let answer = PermissionAnswer.parse(said)
            if answer == nil, !said.isEmpty || answerUnclear, attempts == 0 {
                attempts += 1
                let again = rememberable ? "Please say allow, allow always, or don't allow." : "Please say yes, or no."
                askUser(said.isEmpty ? "Sorry, I didn't catch that. \(again)" : again, onAnswer: finish)
                return
            }
            let decided = answer ?? .deny
            var decision = decided.rawValue
            if !rememberable { decision = decided.allows ? "allow_once" : "deny" }
            if rememberable && (decided == .allowAlways || decided == .denyAlways) {
                var store = PermissionStore.load()
                store.remember(capability: capability, target: target, allow: decided == .allowAlways)
                store.save()
            }
            PermissionStore.record(["layer": kind == "permission" ? "permission" : "confirmation", "capability": capability,
                                    "target": target, "question": question, "decision": decision, "task": job?.id ?? 0,
                                    "via": said.isEmpty ? "no answer" : "spoken answer"])
            log("permission \(capability): \(decision)")
            pendingDeny = nil
            job?.detail = ""
            connection.reply(id, ["decision": decision])
            guard inConversation else { return }
            if !foreground {
                // Back to whatever you were doing; the task carries on and reports when done.
                speakLocal(decided.allows ? "Okay." : "Very good. I won't.")
                return
            }
            set(.thinking, decided.allows ? "Working on it…" : "Thinking…")
            thinkingAnchor = gateSeconds
            startResponseTimers()
            if decided.allows { speaker.enqueue("Okay.") }
        }
        if foreground {
            stopResponseTimers()
            pendingDeny = { connection.reply(id, ["decision": "deny"]) }
            askUser(question, onAnswer: finish)
            return
        }
        // A background task: asked when you are free, saying which task it is for.
        job?.detail = "waiting for your permission to \((payload["summary"] as? String) ?? "go on")"
        var item = PendingSpeech(jobID: job?.id, text: "Task \(job?.id ?? 0), \(job?.title ?? "in the background"): \(question)")
        item.onAnswer = { [weak self] said in
            self?.pendingDeny = nil
            finish(said)
        }
        item.onSkip = { [weak job] in
            job?.detail = ""
            connection.reply(id, ["decision": "deny"])
        }
        enqueueQuestion(item)
    }

    // MARK: - Requests from the bridge (camera, Mac actions, questions)

    private func handleRequest(_ kind: String, _ id: String, _ payload: [String: Any], from connection: BridgeConnection) {
        // Only on behalf of one of our own requests that is still running on that connection:
        // an idle (warm) connection, or one whose request has finished, can make the Mac do nothing.
        let owner = connection === bridge ? foregroundTurn : backgroundTurn(connection)
        guard let owner, !owner.over, owner.connection === connection else {
            log("refused a '\(kind)' request: no request of ours is running on that connection")
            connection.reply(id, kind == "confirm" ? ["decision": "deny"] : ["error": "No Jarvis Voice request is running on this connection."])
            return
        }
        switch kind {
        case "confirm": handleConfirm(id, payload, connection)
        case "capture": Task { await self.handleCapture(id, payload, connection) }
        case "mac": Task { await self.handleMac(id, payload, connection) }
        default: connection.reply(id, ["error": "Jarvis Voice cannot do that."])
        }
    }

    private func handleCapture(_ id: String, _ p: [String: Any], _ connection: BridgeConnection) async {
        if PermissionStore.load().value("camera") == "deny" {
            connection.reply(id, ["error": "The user has turned off Jarvis's camera access. They can say “allow camera access”."])
            return
        }
        let watch = (p["mode"] as? String) == "watch"
        if watch && (p["when"] as? String) == "past" {
            connection.reply(id, ["error": "Jarvis Voice keeps no recording, so there is nothing from the past to review. Offer to watch now instead."])
            return
        }
        let owner = connection === bridge ? foregroundTurn : backgroundTurn(connection)
        let box = PayloadBox()
        // One task at a time has the camera.
        let job = tasks.run("using the camera", kind: "camera", exclusive: ["camera"], timeout: 110) { [weak self] job in
            guard let self else { return .failed("Jarvis Voice stopped.") }
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted {
                switch await self.ensureMacPermission(.camera, purpose: "look through the camera", connection: connection, job: job) {
                case .granted: break
                case .declined:
                    box.value = ["error": "The user chose not to allow camera access in macOS, so nothing was captured."]
                    return .failed("declined")
                case .stillOff:
                    box.value = ["error": "macOS still doesn't allow Jarvis Voice to use the camera (checked after opening System Settings), so nothing was captured."]
                    return .failed("not granted")
                }
            }
            let foreground = connection === self.bridge
            let before = self.state
            if foreground { self.set(.looking, "Camera on…") }
            defer { if foreground, self.state == .looking { self.set(before == .looking ? .thinking : before, "Thinking…") } }
            do {
                let seconds = watch ? min(max((p["seconds"] as? NSNumber)?.doubleValue ?? 6, 2), 15) : 0
                let count = watch ? min(12, max(4, Int(seconds * 1.5))) : 1
                let shots = try await self.camera.capture(count: count, seconds: seconds)
                guard let image = watch ? Camera.grid(shots) : shots.first?.0, let encoded = jpegBase64(image) else {
                    throw Camera.CameraError.noFrame
                }
                box.value = ["data": encoded, "mimeType": "image/jpeg"]
                log("camera: \(watch ? "\(shots.count) frames over \(Int(seconds)) s" : "one frame") sent to Claude — not saved")
                return .done("captured")
            } catch {
                box.value = ["error": error.localizedDescription]
                return .failed(error.localizedDescription)
            }
        }
        job.parent = owner?.job?.id
        _ = await tasks.wait(job)
        let payload = box.value.isEmpty
            ? ["error": job.status == .cancelled ? "The user cancelled this." : "The camera didn't answer: \(job.message)."]
            : box.value
        connection.reply(id, payload)
    }

    private func handleMac(_ id: String, _ p: [String: Any], _ connection: BridgeConnection) async {
        let op = p["op"] as? String ?? ""
        let owner = connection === bridge ? foregroundTurn : backgroundTurn(connection)
        if op == "run_tasks" {
            connection.reply(id, await runPlan(p, connection: connection, owner: owner).payload)
            return
        }
        let (job, box) = macJob(op, p, connection: connection, owner: owner, dependsOn: [])
        _ = await tasks.wait(job)
        let result = box.result ?? .fail(job.status == .cancelled ? "The user cancelled this task, so it was not done." : "It didn't finish: \(job.message).")
        connection.reply(id, result.payload)
    }

    /// One Mac action as a task, with the locks it needs (see MacControl.resources).
    private func macJob(_ op: String, _ p: [String: Any], connection: BridgeConnection, owner: ClaudeTurn?,
                        dependsOn: [Int], requireSuccess: Bool = false) -> (TaskManager.Job, ResultBox) {
        let box = ResultBox()
        let locks = mac.resources(op: op, args: p)
        let job = tasks.run(macTitle(op, p), kind: "mac", exclusive: locks.exclusive, shared: locks.shared,
                            dependsOn: dependsOn, requireSuccess: requireSuccess, timeout: macTimeout(op)) { [weak self] job in
            guard let self else { return .failed("Jarvis Voice stopped.") }
            let result = await self.performMac(op, p, connection: connection, job: job)
            box.result = result
            return result.error == nil ? .done(result.spoken ?? "done") : .failed(result.error ?? "failed")
        }
        job.parent = owner?.job?.id
        return (job, box)
    }

    private func macTitle(_ op: String, _ p: [String: Any]) -> String {
        let app = (p["app"] as? String) ?? (p["name"] as? String) ?? "the app in front"
        switch op {
        case "open_app": return "opening \(app)"
        case "close_app": return "closing \(app)"
        case "switch_to_app": return "switching to \(app)"
        case "read_window": return "reading \(app)"
        case "read_screen": return "looking at the screen"
        case "click": return "clicking in \(app)"
        case "type_text": return "typing in \(app)"
        case "press_keys": return "pressing keys in \(app)"
        case "open_url": return "opening a web page"
        case "web_search": return "searching the web in a browser"
        case "open_path": return "opening a folder"
        case "settings": return "opening System Settings"
        case "run_in_terminal": return "running a command in Terminal"
        case "interface": return "opening or closing my interface"
        default: return op.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Long enough for the guided macOS permission flow where an action can need one.
    private func macTimeout(_ op: String) -> Double {
        switch op {
        case "read_window", "click", "type_text", "press_keys", "read_screen": return 30 + config.permissionGuideSeconds + 40
        case "run_in_terminal": return 30 + config.permissionGuideSeconds + 20
        case "open_app", "switch_to_app": return 40
        case "permission_change": return 60
        default: return 25
        }
    }

    private func performMac(_ op: String, _ p: [String: Any], connection: BridgeConnection, job: TaskManager.Job) async -> MacResult {
        func s(_ key: String) -> String? {
            guard let v = (p[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let foreground = connection === bridge
        // Layer A: a macOS permission this action needs and macOS hasn't given — ask, guide, verify.
        if let need = macNeed(op) {
            switch await ensureMacPermission(need, purpose: Self.purpose(op, p, fallback: macTitle(op, p)), connection: connection, job: job) {
            case .granted: break
            case .declined:
                return .fail("The user chose not to allow \(need.name) in macOS, so this was not done. Don't try another way.")
            case .stillOff:
                return .fail("macOS still reports \(need.name) as off for Jarvis Voice after I opened System Settings and waited "
                    + "\(Int(config.permissionGuideSeconds)) seconds, so nothing was done."
                    + (need.needsRestart ? " If the user has just switched it on, macOS applies it after Jarvis Voice restarts (jarvisctl restart voice)." : "")
                    + (MacPermissions.managed ? " This Mac is managed by an organisation, which can lock this setting." : ""))
            }
        }
        let started = Date()
        let before = state
        var result: MacResult
        switch op {
        case "open_app": result = await mac.openApp(s("name") ?? "")
        case "close_app": result = await mac.closeApp(s("name") ?? "", force: p["force"] as? Bool ?? false)
        case "switch_to_app": result = await mac.switchTo(s("name") ?? "")
        case "list_apps": result = mac.listApps()
        case "read_window": result = mac.readWindow(s("app"))
        case "read_screen":
            if foreground { set(.looking, "Looking at your screen…") }
            result = await mac.readScreen(target: s("target"), app: s("app"))
            if foreground, state == .looking { set(before, "Thinking…") }
        case "click": result = await mac.click(s("label") ?? "", app: s("app"), role: s("role"))
        case "type_text": result = await mac.typeText(p["text"] as? String ?? "", field: s("field"), app: s("app"), submit: p["submit"] as? Bool ?? false)
        case "press_keys": result = await mac.pressKeys(s("keys") ?? "", app: s("app"))
        case "open_url": result = await mac.openURL(s("url") ?? "", app: s("app"))
        case "web_search": result = await mac.webSearch(s("query") ?? "", app: s("app"))
        case "open_path": result = await mac.openPath(s("path") ?? "", app: s("app"))
        case "settings": result = await mac.settings(s("pane") ?? "")
        case "run_in_terminal":
            result = await mac.runInTerminal(p["command"] as? String ?? "", cwd: s("cwd"))
            // macOS said no to Apple Events: guide, verify, and try once more.
            if result.error?.contains("Automation") == true,
               await ensureMacPermission(.automation(bundleID: "com.apple.Terminal", app: "Terminal"), purpose: "run that in Terminal",
                                         connection: connection, job: job) == .granted {
                result = await mac.runInTerminal(p["command"] as? String ?? "", cwd: s("cwd"))
            }
        case "interface": result = await mac.interface(s("action") ?? "open")
        case "permissions": result = .ok(await permissionsSummary(detailed: true))
        case "permission_change": result = await permissionChangeFromClaude(p)
        default: result = .fail("Jarvis Voice doesn't know how to \(op).")
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log("mac \(op): \(result.error == nil ? "done" : "failed") in \(ms) ms (task \(job.id))")
        if foreground { timing.actionMs = (timing.actionMs ?? 0) + ms }
        PermissionStore.record(["layer": "action", "action": op, "result": result.error == nil ? "done" : "failed", "via": "Claude",
                                "ms": ms, "task": job.id, "parent": job.parent ?? 0])
        return result
    }

    /// "read the Calculator window", "type in WhatsApp" — for the permission question.
    private static func purpose(_ op: String, _ p: [String: Any], fallback: String) -> String {
        let app = (p["app"] as? String).map { "in \($0)" } ?? "in the app in front"
        switch op {
        case "read_window": return "read what's \(app)"
        case "click": return "click \((p["label"] as? String).map { "“\($0)” " } ?? "")\(app)"
        case "type_text": return "type \(app)"
        case "press_keys": return "press keys \(app)"
        case "read_screen": return "look at your screen"
        default: return fallback
        }
    }

    private func macNeed(_ op: String) -> MacNeed? {
        switch op {
        case "read_window", "click", "type_text", "press_keys": return AXIsProcessTrusted() ? nil : .accessibility
        case "read_screen": return CGPreflightScreenCaptureAccess() ? nil : .screenRecording
        default: return nil
        }
    }

    /// Several Mac actions from one Claude request (run_tasks): independent ones at the same
    /// time, dependent ones in order (a step whose prerequisite failed is skipped).
    private func runPlan(_ p: [String: Any], connection: BridgeConnection, owner: ClaudeTurn?) async -> MacResult {
        let allowed: Set<String> = ["open_app", "close_app", "switch_to_app", "open_url", "web_search", "open_path", "settings",
                                    "read_window", "read_screen", "click", "type_text", "press_keys"]
        guard let raw = p["steps"] as? [[String: Any]], !raw.isEmpty else { return .fail("run_tasks needs a list of steps.") }
        let steps = Array(raw.prefix(8)).enumerated().map { i, step in
            (id: (step["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(i + 1)", tool: step["tool"] as? String ?? "",
             args: step["args"] as? [String: Any] ?? [:], after: step["after"] as? [String] ?? [])
        }
        if let bad = steps.first(where: { !allowed.contains($0.tool) }) { return .fail("Step \(bad.id): \(bad.tool) can't run as a task.") }
        // Order by dependency (and refuse a cycle) so every step's prerequisites exist first.
        var ordered: [Int] = []
        var placed = Set<String>()
        while ordered.count < steps.count {
            guard let next = steps.indices.first(where: { i in
                !ordered.contains(i) && steps[i].after.allSatisfy { dep in placed.contains(dep) || !steps.contains(where: { $0.id == dep }) }
            }) else { return .fail("The steps depend on each other in a circle, so I didn't run them.") }
            ordered.append(next)
            placed.insert(steps[next].id)
        }
        let started = Date()
        var jobIDs: [String: Int] = [:]
        var entries: [(id: String, tool: String, job: TaskManager.Job, box: ResultBox)] = []
        for i in ordered {
            let step = steps[i]
            let (job, box) = macJob(step.tool, step.args, connection: connection, owner: owner,
                                    dependsOn: step.after.compactMap { jobIDs[$0] }, requireSuccess: true)
            jobIDs[step.id] = job.id
            entries.append((step.id, step.tool, job, box))
        }
        log("plan: \(entries.count) steps as tasks \(entries.map { "\($0.job.id)" }.joined(separator: ", "))")
        _ = await tasks.waitAll(entries.map(\.job))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log("plan: \(entries.count) steps finished in \(ms) ms")
        let lines = entries.sorted { $0.job.id < $1.job.id }.map { e -> String in
            let outcome: String
            if let r = e.box.result {
                outcome = r.error.map { "FAILED: \($0)" } ?? (r.text ?? "done")
            } else {
                outcome = e.job.status == .cancelled ? "not run (\(e.job.message))" : "failed: \(e.job.message)"
            }
            return "Step \(e.id) — \(e.tool), \(e.job.elapsedMs) ms: \(outcome)"
        }
        var result = MacResult.ok("Ran \(entries.count) steps as separate tasks in \(ms) ms (independent ones at the same time):\n"
                                  + lines.joined(separator: "\n"))
        result.image = entries.compactMap { $0.box.result?.image }.first
        return result
    }

    // MARK: - macOS permissions: ask, guide, verify

    private enum GuideResult { case granted, declined, stillOff }

    /// "I need Accessibility permission to read what's in Calculator. Would you like to allow it?"
    /// On yes: macOS's own prompt where there is one, System Settings opened at the right page,
    /// and a check that macOS really reports it on. Jarvis never changes it itself.
    private func ensureMacPermission(_ need: MacNeed, purpose: String, connection: BridgeConnection, job: TaskManager.Job?) async -> GuideResult {
        if need.granted { return .granted }
        let foreground = connection === bridge
        let owner = job.flatMap { $0.parent }.flatMap { tasks.job($0) } ?? job
        owner?.detail = "waiting for \(need.name) permission"
        log("macOS permission needed: \(need.name)")
        let yes = await askYesNo("I need \(need.name) permission to \(purpose). Would you like to allow it?", connection: connection, job: job)
        PermissionStore.record(["layer": "macos", "permission": need.name, "decision": yes ? "guide" : "declined", "via": "spoken answer"])
        guard yes else {
            owner?.detail = ""
            log("macOS permission \(need.name): the user declined")
            return .declined
        }
        // System Settings first: macOS's own prompt, shown at the same moment, swallows the
        // request to open it. The prompt then follows, which also lists Jarvis Voice on that page.
        MacPermissions.openSettings(need.anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { need.requestFromMacOS() }
        owner?.detail = "waiting for you to switch on \(need.name) in System Settings"
        if foreground { set(.thinking, "Waiting for \(need.name) in System Settings…") }
        await sayAndWait("I've opened System Settings at Privacy and Security, \(need.pane). Please switch me on there, and I'll carry on as soon as macOS confirms it.",
                         connection: connection, job: job)
        let started = Date()
        while Date().timeIntervalSince(started) < config.permissionGuideSeconds, job?.status != .cancelled, !need.granted {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        owner?.detail = ""
        if need.granted {
            log("macOS permission \(need.name): granted, verified after \(Int(Date().timeIntervalSince(started))) s")
            PermissionStore.record(["layer": "macos", "permission": need.name, "decision": "granted (verified)", "via": "System Settings"])
            await sayAndWait("Thank you. macOS has given me \(need.name).", connection: connection, job: job)
            if foreground { startResponseTimers() }
            return .granted
        }
        log("macOS permission \(need.name): still not granted after \(Int(config.permissionGuideSeconds)) s")
        PermissionStore.record(["layer": "macos", "permission": need.name, "decision": "still off", "via": "System Settings"])
        // Screen Recording only takes effect once the app restarts: offer to do that, on your yes.
        if need.needsRestart, foreground, inConversation,
           await askYesNo("If you've switched it on, macOS only applies it once I restart. Shall I restart now?", connection: connection, job: job) {
            await sayAndWait("Restarting. Ask me again in a moment.", connection: connection, job: job)
            restartSelf(because: "\(need.name) was switched on")
        }
        if foreground { startResponseTimers() }
        return .stillOff
    }

    /// Quits with a failure code, so launchd (KeepAlive, SuccessfulExit false) starts a fresh copy.
    private func restartSelf(because why: String) {
        log("restarting so that \(why)")
        cleanUp()
        Log.shared.flush()
        exit(75)
    }

    /// A yes-or-no question for you: at once in the conversation, otherwise when you are free.
    private func askYesNo(_ question: String, connection: BridgeConnection, job: TaskManager.Job?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            var retried = false
            var handle: ((String) -> Void)!
            handle = { [weak self] said in
                guard let self else { return once.resume(false) }
                let answer = PermissionAnswer.parse(said)
                if answer == nil, !said.isEmpty || self.answerUnclear, !retried, self.inConversation {
                    retried = true
                    self.askUser(said.isEmpty ? "Sorry, I didn't catch that. Please say yes, or no." : "Please say yes, or no.", onAnswer: handle)
                    return
                }
                self.pendingDeny = nil
                let yes = answer?.allows == true
                once.resume(yes)
                guard self.inConversation else { return }
                if connection === self.bridge {
                    self.set(.thinking, yes ? "Working on it…" : "Thinking…")
                    self.thinkingAnchor = self.gateSeconds
                } else if !yes {
                    self.speakLocal("Very good. I won't.")
                }
            }
            if connection === bridge, inConversation {
                stopResponseTimers()
                pendingDeny = { once.resume(false) }
                askUser(question, onAnswer: handle)
            } else {
                let top = job.flatMap { $0.parent }.flatMap { tasks.job($0) } ?? job
                var item = PendingSpeech(jobID: top?.id, text: top.map { "Task \($0.id), \($0.title): \(question)" } ?? question)
                item.onAnswer = handle
                item.onSkip = { once.resume(false) }
                enqueueQuestion(item)
            }
        }
    }

    /// Says a line; in the conversation, waits until it has been said.
    private func sayAndWait(_ line: String, connection: BridgeConnection, job: TaskManager.Job?) async {
        guard connection === bridge, inConversation else {
            announce(line, job: job.flatMap { $0.parent }.flatMap { tasks.job($0) } ?? job)
            return
        }
        stopResponseTimers()
        afterSpeech = .resumeThinking
        spokenWords.formUnion(normalized(line).split(separator: " ").map(String.init))
        speaker.enqueue(line)
        let started = Date()
        while speaker.isBusy, Date().timeIntervalSince(started) < 25 { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Claude may revoke on the user's behalf; granting always goes back to the user's own voice.
    private func permissionChangeFromClaude(_ p: [String: Any]) async -> MacResult {
        let change = p["change"] as? String ?? "revoke"
        let raw = [p["capability"] as? String, p["target"] as? String].compactMap { $0 }.joined(separator: " ")
        let resolve = { [mac] (n: String) in mac.resolve(n).map { ($0.name, $0.bundleID) } }
        let target = (p["target"] as? String).flatMap { PermissionCommand.capability(for: $0, resolveApp: resolve) }
        guard let c = target ?? PermissionCommand.capability(for: (p["capability"] as? String) ?? raw, resolveApp: resolve) else {
            return .fail("I don't know which permission “\(raw)” means.")
        }
        if change == "revoke" {
            apply(c.capability, target: c.target, allow: false, label: c.label)
            return .ok(revokeMessage(c.capability, target: c.target, c.label))
        }
        return await withCheckedContinuation { continuation in
            // If the conversation ends first, answer "no" rather than leave this waiting.
            pendingDeny = { continuation.resume(returning: .fail("The user did not answer. Nothing changed.")) }
            askUser(grantQuestion(c.capability, target: c.target, c.label)) { [weak self] said in
                guard let self else { return continuation.resume(returning: .fail("No answer.")) }
                self.pendingDeny = nil
                if PermissionAnswer.parse(said)?.allows == true {
                    self.apply(c.capability, target: c.target, allow: true, label: c.label)
                    self.set(.thinking, "Thinking…")
                    continuation.resume(returning: .ok("The user said yes: \(self.grantMessage(c.capability, c.label))"))
                } else {
                    self.set(.thinking, "Thinking…")
                    continuation.resume(returning: .fail("The user did not allow it. Nothing changed."))
                }
            }
        }
    }

    // MARK: - The bridge (one warm Claude session kept ready)

    private func makeConnection() -> BridgeConnection {
        let connection = BridgeConnection(url: config.bridgeURL, origin: config.bridgeOrigin)
        // Each connection's words go to its own request only: the conversation's are spoken as
        // they stream, a background task's are kept for when it is done.
        connection.onDelta = { [weak self, weak connection] delta in
            guard let self, let connection else { return }
            if connection === self.bridge { self.replyDelta(delta) } else { self.backgroundTurn(connection)?.reply += delta }
        }
        connection.onDone = { [weak self, weak connection] text in
            guard let self, let connection else { return }
            if connection === self.bridge {
                self.replyDone(text)
            } else if let turn = self.backgroundTurn(connection) {
                self.backgroundFinished(turn, text: text, error: nil)
            }
        }
        connection.onError = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            if connection === self.bridge {
                self.replyError(message)
            } else if let turn = self.backgroundTurn(connection) {
                self.backgroundFinished(turn, text: "", error: message)
            }
        }
        connection.onTool = { [weak self, weak connection] name in
            guard let self, let connection else { return }
            if connection === self.bridge {
                self.toolStarted(name)
            } else if let turn = self.backgroundTurn(connection) {
                log("tool used: \(name) (background task \(turn.job?.id ?? 0))")
            }
        }
        connection.onRequest = { [weak self, weak connection] kind, id, payload in
            guard let self, let connection else { return }
            self.handleRequest(kind, id, payload, from: connection)
        }
        connection.onOpen = { [weak self] in self?.warmRetry = 2 }
        connection.onClose = { [weak self, weak connection] in self?.connectionClosed(connection) }
        connection.connect()
        return connection
    }

    private func openBridge() -> BridgeConnection {
        if let existing = bridge, !existing.isClosed { return existing }
        if let ready = warm, !ready.isClosed {
            warm = nil
            bridge = ready
            log("using the warm bridge session")
            return ready
        }
        let connection = makeConnection()
        bridge = connection
        return connection
    }

    private func prepareWarm() {
        guard config.warmConnection, !muted, warm == nil || warm?.isClosed == true else { return }
        warm = makeConnection()
    }

    private func connectionClosed(_ connection: BridgeConnection?) {
        guard let connection else { return }
        if connection === warm {
            warm = nil
            let delay = warmRetry
            warmRetry = min(warmRetry * 2, 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.prepareWarm() }
            }
            return
        }
        if let turn = backgroundTurn(connection) {
            backgroundTurns[ObjectIdentifier(connection)] = nil
            turn.closeTimer?.invalidate()
            if !turn.over { backgroundFinished(turn, text: "", error: "I lost the connection to my systems.") }
            return
        }
        guard connection === bridge else { return }
        bridge = nil
        if let turn = foregroundTurn, !turn.over { turn.finish(.failed("the bridge connection dropped")) }
        if inConversation && (state == .thinking || state == .confirming || (state == .speaking && !turnDone)) {
            lastProblem = "the bridge connection dropped"
            fail("I'm afraid I lost the connection to my systems, sir.")
        }
    }

    private func backgroundTurn(_ connection: BridgeConnection) -> ClaudeTurn? { backgroundTurns[ObjectIdentifier(connection)] }

    private func ask(_ request: String) {
        turnDone = false
        spokeReply = false
        fillerPlayed = false
        sentences = SentenceBuffer()
        afterSpeech = .nothing
        tasks.limits["claude"] = max(1, config.maxClaudeTasks)
        // A request still running (a typed question on top of a spoken one) carries on in the
        // background rather than sharing a session with this one.
        if let running = foregroundTurn, !running.over { sendToBackground(running) }
        // Backpressure: past the limit, a request waits for a free slot — up to a point.
        let queued = tasks.wouldQueue(kind: "claude")
        if queued, tasks.waitingCount("claude") >= tasks.maxQueued {
            log("claude tasks: limit reached, request refused")
            speakLocal("I'm already working on as much as I safely can. Ask me again when one of the tasks has finished.")
            return
        }
        let connection = openBridge()
        let context = mac.contextLine()
        let turn = ClaudeTurn(request: request, text: context.isEmpty ? request : "[Mac: \(context)]\n\(request)",
                              connection: connection, context: context)
        foregroundTurn = turn
        let job = startClaudeJob(turn)
        if queued {
            sendToBackground(turn)
            let busy = SystemLoad.busy()
            speakLocal("I'm already working on \(max(1, tasks.activeCount(kind: "claude") - 1)) other things"
                       + (busy.busy ? ", and \(busy.why)" : "") + ", so that's task \(job.id). I'll start it as soon as I can.")
        }
    }

    /// A Claude request as a task: it holds one of the Claude slots while it runs, and
    /// finishes when its answer (or error) arrives, it is cancelled, or it times out.
    private func startClaudeJob(_ turn: ClaudeTurn) -> TaskManager.Job {
        let job = tasks.run(Self.taskTitle(turn.request), kind: "claude",
                            timeout: config.responseTimeoutSeconds + 15, sensitiveTitle: !config.logTranscripts) { [weak self] job in
            guard let self else { return .failed("Jarvis Voice stopped.") }
            let connection = turn.connection
            guard await connection.waitUntilOpen(timeout: 10) else {
                turn.finish(.failed("I couldn't reach my systems."))
                if turn === self.foregroundTurn, self.state == .thinking {
                    self.lastProblem = "the bridge did not accept the connection"
                    self.fail("I'm afraid I can't reach my systems at the moment, sir.")
                }
                return turn.outcome ?? .failed("I couldn't reach my systems.")
            }
            if let outcome = turn.outcome { return outcome } // cancelled while connecting
            connection.ask(turn.text, request: turn.request, context: turn.context)
            if turn === self.foregroundTurn {
                self.timing.sent = Date()
                log("timing: request sent")
                self.startResponseTimers()
            } else {
                log("task \(job.id): request sent (background)")
            }
            return await turn.result()
        }
        turn.job = job
        job.onCancel = { [weak self] in self?.stopTurn(turn) }
        return job
    }

    /// Stops a Claude request. A background one's session is closed, so no Claude process is left behind.
    private func stopTurn(_ turn: ClaudeTurn) {
        turn.connection.interrupt()
        turn.finish(.failed("cancelled"))
        if turn === foregroundTurn {
            foregroundTurn = nil
            if inConversation, [.thinking, .looking].contains(state) { endConversation(reason: "cancelled") }
        } else {
            backgroundTurns[ObjectIdentifier(turn.connection)] = nil
            turn.closeTimer?.invalidate()
            turn.connection.close()
        }
        removePending(for: turn.job?.id)
    }

    /// Ends the conversation's own request, when the conversation is cancelled or interrupted.
    private func cancelForeground(_ reason: String) {
        guard let turn = foregroundTurn else { return }
        foregroundTurn = nil
        guard !turn.over else { return }
        if let job = turn.job, job.isActive {
            job.onCancel = nil // the caller is already stopping it
            tasks.cancel(job, reason: reason)
        }
        turn.finish(.failed(reason))
    }

    /// The conversation's request carries on as a background task with its own session; the
    /// next request gets a fresh, separate one.
    private func sendToBackground(_ turn: ClaudeTurn) {
        guard turn.foreground else { return }
        turn.foreground = false
        backgroundTurns[ObjectIdentifier(turn.connection)] = turn
        if bridge === turn.connection { bridge = nil }
        if foregroundTurn === turn { foregroundTurn = nil }
        stopResponseTimers()
        log("task \(turn.job?.id ?? 0) continues in the background")
        prepareWarm()
    }

    /// A finished background session becomes the conversation's, so follow-ups continue it.
    private func adopt(_ turn: ClaudeTurn) {
        backgroundTurns[ObjectIdentifier(turn.connection)] = nil
        turn.closeTimer?.invalidate()
        turn.foreground = true
        if let old = bridge, old !== turn.connection { old.close() }
        bridge = turn.connection
        foregroundTurn = turn
        log("task \(turn.job?.id ?? 0): its session is now the conversation's")
    }

    private func backgroundFinished(_ turn: ClaudeTurn, text: String, error: String?) {
        guard let job = turn.job, !turn.over else { return }
        let answer = speakable((turn.reply.isEmpty ? text : turn.reply).trimmingCharacters(in: .whitespacesAndNewlines))
        reported.insert(job.id)
        if let error {
            turn.finish(.failed(error))
            announce("Task \(job.id), \(job.title), didn't work. \(error)", job: job)
        } else {
            turn.finish(.done(answer.isEmpty ? "Done." : answer))
            announce("Task \(job.id), \(job.title): \(answer.isEmpty ? "it's done." : answer)", job: job, adopt: turn)
        }
        // Its session stays open a little while, for "continue task \(job.id)", then closes.
        turn.closeTimer?.invalidate()
        turn.closeTimer = Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { [weak self, weak turn] _ in
            MainActor.assumeIsolated {
                guard let self, let turn, self.bridge !== turn.connection else { return }
                self.backgroundTurns[ObjectIdentifier(turn.connection)] = nil
                turn.connection.close()
            }
        }
    }

    /// Every task start and end: the menu bar, and a word about background tasks that end
    /// without having said anything themselves (a timeout).
    private func taskChanged(_ job: TaskManager.Job) {
        let live = tasks.active.filter { $0.parent == nil }
        menu.updateTasks(live.isEmpty ? "" : "\(live.count) task\(live.count == 1 ? "" : "s") running: "
                         + live.map { "\($0.id). \($0.title)" }.joined(separator: "; "))
        guard !job.isActive, job.parent == nil, job.kind == "claude", !reported.contains(job.id),
              job.status == .failed, foregroundTurn?.job !== job else { return }
        reported.insert(job.id)
        announce("Task \(job.id), \(job.title), didn't finish: \(job.message).", job: job)
    }

    // MARK: - Saying things for background tasks when you are free

    private func announce(_ text: String, job: TaskManager.Job?, adopt turn: ClaudeTurn? = nil) {
        pendingSpeech.append(PendingSpeech(jobID: job?.id, text: text, adopt: turn))
        log("task \(job?.id ?? 0): something to say when you're free")
        deliverPending()
    }

    /// Questions go before announcements: a task is waiting on them.
    private func enqueueQuestion(_ item: PendingSpeech) {
        let index = pendingSpeech.firstIndex(where: { !$0.isQuestion }) ?? pendingSpeech.endIndex
        pendingSpeech.insert(item, at: index)
        log("task \(item.jobID ?? 0): a question waiting to be asked")
        deliverPending()
    }

    private func removePending(for id: Int?) {
        guard let id else { return }
        pendingSpeech.removeAll { item in
            guard item.jobID == id else { return false }
            item.onSkip?()
            return true
        }
    }

    private func schedulePending(after seconds: Double) {
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverPending() }
        }
    }

    private func deliverPending() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        // The bridge stops waiting for an answer after 90 s; anything from a stopped task goes.
        pendingSpeech.removeAll { item in
            let stale = item.isQuestion ? Date().timeIntervalSince(item.created) > 80 : Date().timeIntervalSince(item.created) > 600
            let stopped = item.jobID.flatMap { tasks.job($0) }.map { $0.status == .cancelled } ?? false
            guard stale || stopped else { return false }
            item.onSkip?()
            return true
        }
        guard let first = pendingSpeech.first else { return }
        guard voiceIsFree(waited: Date().timeIntervalSince(first.created)) else {
            schedulePending(after: 0.4)
            return
        }
        pendingSpeech.removeFirst()
        stopEndpointTimer()
        if !inConversation {
            inConversation = true
            source = "task"
            log("speaking up for task \(first.jobID ?? 0)")
        }
        if let onAnswer = first.onAnswer {
            pendingDeny = first.onSkip
            askUser(first.text, onAnswer: onAnswer)
            return
        }
        if let turn = first.adopt, bridge == nil, !turn.connection.isClosed { adopt(turn) }
        speakLocal(first.text)
    }

    /// You are not talking, he is not talking, and nothing else is waiting on you.
    private func voiceIsFree(waited: Double) -> Bool {
        guard !muted, !pausedBySystem, !speaker.isBusy, answerHandler == nil, audio?.running == true else { return false }
        let quietMs = gate?.msSinceVoice ?? 0
        switch state {
        case .idle: return quietMs > 1200 || waited > 20
        case .followUp: return bestHeard.isEmpty && quietMs > 900
        default: return false
        }
    }

    // MARK: - Replies

    private func replyDelta(_ delta: String) {
        foregroundTurn?.reply += delta
        guard inConversation, [.thinking, .speaking, .looking].contains(state) else { return }
        if timing.firstToken == nil {
            timing.firstToken = Date()
            log("timing: first reply token")
        }
        for sentence in sentences.push(delta) { speakReply(sentence) }
    }

    private func speakReply(_ sentence: String) {
        stopFiller()
        if state != .speaking {
            prepareToSpeak(listening: true)
            set(.speaking, "Speaking…")
        }
        afterSpeech = .reply
        spokeReply = true
        spokenWords.formUnion(normalized(sentence).split(separator: " ").map(String.init))
        speaker.enqueue(sentence)
    }

    private func replyDone(_ text: String) {
        if let turn = foregroundTurn, !turn.over {
            let answer = (turn.reply.isEmpty ? text : turn.reply).trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = turn.job?.id { reported.insert(id) }
            turn.finish(.done(answer.isEmpty ? "Done." : speakable(answer)))
        }
        guard inConversation, [.thinking, .speaking, .looking].contains(state) else { return }
        stopResponseTimers()
        if let tail = sentences.flush() { speakReply(tail) }
        if !spokeReply {
            let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !full.isEmpty { speakReply(full) }
        }
        turnDone = true
        if speaker.isBusy {
            afterSpeech = spokeReply ? .reply : .followUp
        } else {
            afterSpeech = .nothing
            toFollowUp()
        }
    }

    private func replyError(_ message: String) {
        if let turn = foregroundTurn, !turn.over {
            if let id = turn.job?.id { reported.insert(id) }
            turn.finish(.failed(message))
        }
        guard inConversation else { return }
        lastProblem = message
        logError("bridge reported: \(message)")
        let line = message.count < 90 && message.hasSuffix(".") ? message : "I'm afraid that request failed, sir."
        fail(line)
    }

    private func toolStarted(_ name: String) {
        log("tool used: \(name)")
        if config.fillerOnTool, state == .thinking, !spokeReply, !fillerPlayed, !speaker.isBusy,
           !name.contains("permission"), !name.hasSuffix("__list_apps") {
            playFiller()
        }
    }

    /// Says what went wrong, once, then goes back to waiting for the wake word.
    private func fail(_ sentence: String) {
        guard afterSpeech != .endConversation else { return }
        stopResponseTimers()
        stopEndpointTimer()
        say(sentence, then: .endConversation)
    }

    private func startResponseTimers() {
        stopResponseTimers()
        responseTimer = Timer.scheduledTimer(withTimeInterval: config.responseTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.responseTimedOut() }
        }
        if config.fillerAfterSeconds > 0, !config.fillers.isEmpty, !fillerPlayed {
            fillerTimer = Timer.scheduledTimer(withTimeInterval: config.fillerAfterSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.playFiller() }
            }
        }
        stillTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sayStillWorking() }
        }
    }

    private func sayStillWorking() {
        stillTimer = nil
        guard state == .thinking, !spokeReply, !speaker.isBusy else { return }
        if someoneTalking {
            stillTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.sayStillWorking() }
            }
            return
        }
        log("still waiting for Claude after 25 s")
        afterSpeech = .resumeThinking
        speaker.enqueue("Still working on it.")
    }

    private func stopFiller() {
        fillerTimer?.invalidate()
        fillerTimer = nil
    }

    private func stopResponseTimers() {
        responseTimer?.invalidate()
        responseTimer = nil
        stillTimer?.invalidate()
        stillTimer = nil
        stopFiller()
    }

    /// Someone is talking (you asking for something else, say): he doesn't talk over you.
    /// Generous on purpose: the level detector misses quiet stretches of speech, so recent
    /// words from the recogniser count too.
    private var someoneTalking: Bool {
        guard let gate else { return false }
        return gate.msSinceVoice < 1000 || gate.msSinceSound < 1500 || Date().timeIntervalSince(lastWordsAt) < 1.5
    }

    private func playFiller() {
        fillerTimer = nil
        guard state == .thinking, !speaker.isBusy, !fillerPlayed, let line = config.fillers.randomElement() else { return }
        if someoneTalking {
            fillerTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.playFiller() }
            }
            return
        }
        fillerPlayed = true
        afterSpeech = .resumeThinking
        speaker.enqueue(line)
    }

    private func responseTimedOut() {
        guard inConversation, [.thinking, .speaking, .looking].contains(state) else { return }
        bridge?.interrupt()
        if let turn = foregroundTurn, !turn.over {
            if let id = turn.job?.id { reported.insert(id) }
            turn.finish(.failed("it took too long"))
        }
        lastProblem = "the reply took too long"
        fail("I'm afraid that is taking too long, sir.")
    }

    // MARK: - Speaking

    /// Commit what was heard so far, so speech that follows starts a fresh segment.
    /// With `listening`, the microphone stays open so the user can interrupt.
    private func prepareToSpeak(listening: Bool) {
        // No forced finalize: word timestamps already separate what came before, and forcing
        // one costs the recogniser the context it needs for the short reply that often follows.
        speakingAnchor = gateSeconds
        spokenWords = Set(normalized(config.acknowledgePhrase).split(separator: " ").map(String.init))
        gate?.adapting.store(false, ordering: .relaxed)
        if !(listening && config.bargeIn) { gate?.open.store(false, ordering: .relaxed) }
    }

    /// A line of our own (not from Claude), said with the microphone closed.
    private func say(_ text: String, then next: AfterSpeech) {
        prepareToSpeak(listening: false)
        afterSpeech = next
        set(.speaking, "Speaking…")
        speaker.enqueue(text)
    }

    private func audioStarted(_ line: String) {
        if wake.contains(line) { ownNameUntil = .infinity }
        if config.logTranscripts { log("saying: \(line)") }
        if line == speakable(config.acknowledgePhrase), let heard = wakeHeardAt {
            log("timing: acknowledgement audio started (\(Int(Date().timeIntervalSince(heard) * 1000)) ms after the wake phrase was recognised)")
            wakeHeardAt = nil
            return
        }
        if state == .speaking, timing.firstAudio == nil, !timing.logged {
            timing.firstAudio = Date()
            log("timing: audio started")
        }
    }

    private func speakerWentQuiet() {
        if ownNameUntil.isInfinite { ownNameUntil = gateSeconds }
        switch afterSpeech {
        case .nothing:
            break
        case .reply:
            if turnDone {
                afterSpeech = .nothing
                toFollowUp()
            }
        case .followUp:
            afterSpeech = .nothing
            toFollowUp()
        case .endConversation:
            afterSpeech = .nothing
            endConversation(reason: "finished")
        case .resumeThinking:
            afterSpeech = .nothing
            if state == .thinking { reopenMicrophone {} }
        case .idle:
            afterSpeech = .nothing
            reopenMicrophone { [weak self] in
                guard let self, !self.inConversation, self.state == .speaking else { return }
                self.setIdle()
            }
        case .answer:
            afterSpeech = .nothing
            let askedUntil = gateSeconds // the end of the question, on the recogniser's clock
            reopenMicrophone { [weak self] in
                guard let self, self.purpose == .answer else { return }
                log("listening for an answer")
                self.listen(from: askedUntil + 0.15, expectWake: false, as: .confirming)
            }
        }
    }

    private func toFollowUp() {
        timing.done = Date()
        logLatency()
        let transcriber = self.transcriber
        // The moment he stopped, on the recogniser's clock: everything of his is before it,
        // everything of yours after it — however far behind the recogniser happens to be.
        let stoppedAt = gateSeconds
        _ = transcriber // no forced finalize here: it costs the recogniser the context it needs for a short reply
        Task { @MainActor in
            guard self.inConversation, !self.muted, [.speaking, .thinking, .looking].contains(self.state) else { return }
            if self.audio?.running == true { self.gate?.open.store(true, ordering: .relaxed) }
            self.source = "follow-up"
            self.listen(from: stoppedAt + 0.15, expectWake: false, as: .followUp)
            // A background task's answer or question, if one is waiting and you say nothing.
            if !self.pendingSpeech.isEmpty { self.schedulePending(after: 1.0) }
        }
    }

    private func logLatency() {
        guard !timing.logged, let end = timing.speechEnd else { return }
        timing.logged = true
        func ms(_ d: Date?) -> String { d.map { "\(Int($0.timeIntervalSince(end) * 1000)) ms" } ?? "—" }
        let line = "latency (\(timing.source)): end of speech → transcribed \(ms(timing.captured)), sent \(ms(timing.sent)), "
            + "first token \(ms(timing.firstToken)), first audio \(ms(timing.firstAudio)), finished \(ms(timing.done))"
            + (timing.actionMs.map { ", Mac actions \($0) ms" } ?? "")
        lastLatency = line
        log(line)
    }

    private func reopenMicrophone(then next: @escaping () -> Void) {
        // A short pause so the tail of his own voice isn't heard as yours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.muted else { return }
                if self.audio?.running == true { self.gate?.open.store(true, ordering: .relaxed) }
                next()
            }
        }
    }

    private func endConversation(reason: String, quiet: Bool = false) {
        stopEndpointTimer()
        stopResponseTimers()
        afterSpeech = .nothing
        purpose = .request
        answerHandler = nil
        pendingDeny?()
        pendingDeny = nil
        interjectedTask = nil
        speaker.stop()
        // The conversation's own request ends with it; background tasks carry on.
        cancelForeground("the conversation ended")
        bridge?.close()
        bridge = nil
        let wasActive = inConversation
        inConversation = false
        turnDone = false
        if wasActive {
            log("conversation ended (\(reason))")
            if !quiet { playSound(config.endSound, volume: config.soundVolume) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.prepareWarm() }
            }
        }
        let transcriber = self.transcriber
        Task { await transcriber.finalizeNow() }
        resetTranscript()
        if muted {
            set(.muted, "Microphone off")
            return
        }
        if audio?.running == true { gate?.open.store(true, ordering: .relaxed) }
        if [.listening, .followUp, .thinking, .speaking, .confirming, .looking, .idle].contains(state) { setIdle() }
    }

    // MARK: - Controls (menu bar, Option-Command-J, jarvisctl)

    func talkPressed() {
        switch state {
        case .idle:
            beginConversation(anchor: gateSeconds, expectWake: false, source: "shortcut")
        case .speaking:
            // Cut him off and listen.
            bridge?.interrupt()
            cancelForeground("interrupted")
            stopResponseTimers()
            speaker.stop()
            turnDone = true
            afterSpeech = .nothing
            if inConversation { toFollowUp() } else { reopenMicrophone { [weak self] in self?.setIdle() } }
        case .listening, .followUp:
            if bestHeard.isEmpty { endConversation(reason: "shortcut") } else { finishUtterance() }
        case .thinking, .confirming, .looking:
            bridge?.interrupt()
            cancelForeground("cancelled")
            endConversation(reason: "cancelled")
        case .muted:
            setMuted(false)
        case .permission:
            MacPermissions.openSettings("Privacy_Microphone")
        default:
            break
        }
    }

    func stopSpeaking() {
        if inConversation {
            bridge?.interrupt()
            cancelForeground("stopped")
            endConversation(reason: "stopped")
        } else if speaker.isBusy {
            speaker.stop()
            afterSpeech = .nothing
            reopenMicrophone { [weak self] in self?.setIdle() }
        }
    }

    func setMuted(_ value: Bool) {
        guard value != muted else { return }
        muted = value
        if value {
            if inConversation { endConversation(reason: "muted", quiet: true) }
            speaker.stop()
            gate?.open.store(false, ordering: .relaxed)
            audio?.stop()
            warm?.close()
            warm = nil
            log("muted")
            set(.muted, "Microphone off")
        } else {
            log("unmuted")
            guard let audio else {
                Task { await startListening() }
                return
            }
            do {
                try audio.start(device: chooseInput())
                resetTranscript()
                gate?.open.store(true, ordering: .relaxed)
                setIdle()
                prepareWarm()
            } catch {
                audioFailed("the microphone could not start: \(error.localizedDescription)")
            }
        }
    }

    private func sayStandalone(_ text: String) {
        if inConversation || state == .speaking { speaker.enqueue(text) } else { say(text, then: .idle) }
    }

    /// Typed instead of spoken — the same path from there on.
    private func askTyped(_ text: String) {
        // Like saying "Jarvis, …" while he works: the request in progress carries on in the background.
        if let turn = foregroundTurn, !turn.over, config.backgroundTasks { sendToBackground(turn) }
        if !inConversation {
            inConversation = true
            _ = openBridge()
        }
        stopEndpointTimer()
        speaker.stop()
        afterSpeech = .nothing
        source = "typed"
        set(.thinking, "Thinking…")
        thinkingAnchor = gateSeconds
        timing = Timing(source: "typed", speechEnd: Date(), captured: Date(), logged: false)
        submit(text)
    }

    private func reloadSettings() {
        let fresh = Config.load()
        let restart = fresh.locale != config.locale || fresh.contextualStrings != config.contextualStrings
        let rerouted = fresh.inputDevice != config.inputDevice
        config = fresh
        wake = WakeMatcher(config: fresh)
        speaker.update(config: fresh)
        mac.interfaceURL = fresh.interfaceURL
        Task { await speaker.refreshEngine() }
        log("settings reloaded")
        if restart {
            Task { await restartListening() }
        } else {
            if rerouted { audioDevicesChanged() }
            if state == .idle { setIdle() }
        }
    }

    func handleControl(_ line: String) async -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "status": return statusJSON()
        case "mute": setMuted(true); return "ok: muted"
        case "unmute": setMuted(false); return "ok: listening"
        case "toggle": setMuted(!muted); return muted ? "ok: muted" : "ok: listening"
        case "talk": talkPressed(); return "ok"
        case "stop": stopSpeaking(); return "ok"
        case "say":
            guard !argument.isEmpty else { return "error: say needs some text" }
            sayStandalone(argument)
            return "ok"
        case "ask":
            guard !argument.isEmpty else { return "error: ask needs some text" }
            askTyped(argument)
            return "ok"
        case "answer":
            // A typed answer to the question he is asking ("allow", "no") — the same parsing as a spoken one.
            guard purpose == .answer, answerHandler != nil, state == .confirming || state == .speaking else {
                return "error: Jarvis isn't waiting for an answer"
            }
            guard !argument.isEmpty else { return "error: answer needs some text, e.g. allow or no" }
            stopEndpointTimer()
            speaker.stop()
            answerUnclear = false
            log("answer typed")
            deliverAnswer(argument)
            return "ok"
        case "permissions": return await permissionsSummary(detailed: true)
        case "tasks": return tasksJSON(all: argument == "all")
        case "cancel":
            if argument == "all" { return "ok: " + cancelAllTasks() }
            guard let n = Int(argument), let job = tasks.job(n) else { return "error: cancel needs a task number or all" }
            return "ok: " + cancelTask(job)
        case "devices":
            let choice = AudioDevices.chooseInput(policy: config.inputDevice)
            return "listening through: \(audio?.device?.description ?? "none") — \(choice.reason)\n"
                + "speaking through: \(AudioDevices.defaultOutput?.description ?? "default")\n"
                + "devices: " + AudioDevices.all().map(\.description).joined(separator: ", ")
        case "reload": reloadSettings(); return "ok: settings reloaded"
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return "ok: quitting"
        case "ping": return "pong"
        default:
            return "error: unknown command — try status, tasks, cancel <n|all>, permissions, devices, mute, unmute, toggle, talk, stop, say <text>, ask <text>, reload, quit"
        }
    }

    private func taskInfo(_ job: TaskManager.Job) -> [String: Any] {
        var info: [String: Any] = ["id": job.id, "title": job.title, "kind": job.kind, "status": job.status.rawValue,
                                   "ms": job.elapsedMs, "waitedMs": job.waitedMs, "attempts": job.attempts]
        if let parent = job.parent { info["parent"] = parent }
        if !job.detail.isEmpty { info["detail"] = job.detail }
        if !job.message.isEmpty, job.kind != "claude" || config.logTranscripts { info["message"] = String(job.message.prefix(160)) }
        if !job.dependsOn.isEmpty { info["after"] = job.dependsOn }
        if !job.exclusive.isEmpty { info["exclusive"] = job.exclusive.sorted() }
        if !job.shared.isEmpty { info["shared"] = job.shared.sorted() }
        return info
    }

    private func tasksJSON(all: Bool) -> String {
        let list = all ? tasks.jobs : tasks.jobs.filter { $0.isActive || Date().timeIntervalSince($0.finished ?? Date()) < 120 }
        let info: [String: Any] = [
            "active": tasks.active.count,
            "limits": ["claude": tasks.limit("claude"), "app": tasks.limit("app"), "mac": tasks.limit("mac"), "camera": tasks.limit("camera")],
            "load": SystemLoad.busy().busy ? SystemLoad.busy().why : "normal",
            "backgroundSessions": backgroundTurns.count,
            "waitingToSay": pendingSpeech.map { ["task": $0.jobID ?? 0, "question": $0.isQuestion] },
            "tasks": list.map(taskInfo),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func statusJSON() -> String {
        var info: [String: Any] = [
            "state": state.rawValue,
            "detail": detail,
            "muted": muted,
            "inConversation": inConversation,
            "microphoneOn": audio?.running == true,
            "transcribing": gate?.open.load(ordering: .relaxed) == true,
            "listeningThrough": audio?.device?.description ?? "",
            "speakingThrough": AudioDevices.defaultOutput?.description ?? "",
            "speechRecognition": transcriber.engineName,
            "voice": speaker.engineName,
            "macOSVoice": speaker.systemVoiceName,
            "wakePhrase": config.displayWakePhrase,
            "warmSession": warm.map { $0.authenticated ? "ready (bridge verified)" : "connecting" } ?? "none",
            "wakes": wakes,
            "requests": requests,
            "pid": Int(getpid()),
            "uptimeSeconds": Int(Date().timeIntervalSince(launched)),
            "microphonePermission": MacPermissions.microphone(),
            "speechPermission": MacPermissions.speech(),
            "cameraPermission": MacPermissions.camera(),
            "screenRecordingPermission": MacPermissions.screenRecording(),
            "screenContentVisible": MacPermissions.screenContentVisible(),
            "accessibilityPermission": MacPermissions.accessibility(),
        ]
        if let lastWakeAt { info["lastWake"] = ISO8601DateFormatter().string(from: lastWakeAt) }
        if !lastRequest.isEmpty { info["lastRequest"] = lastRequest }
        if !lastProblem.isEmpty { info["lastProblem"] = lastProblem }
        if !lastLatency.isEmpty { info["lastLatency"] = lastLatency }
        if let front = mac.frontmost?.localizedName { info["frontmostApp"] = front }
        if let last = mac.lastApp?.name { info["lastAppUsed"] = last }
        info["activeTasks"] = tasks.active.filter { $0.parent == nil }.map { "\($0.id): \($0.kind == "claude" && !config.logTranscripts ? "a Claude request" : $0.title) (\($0.status.rawValue))" }
        info["backgroundSessions"] = backgroundTurns.count
        if let gate {
            info["voiceDetector"] = ["noiseFloor": (gate.noiseFloor * 10_000).rounded() / 10_000,
                                     "msSinceVoice": min(gate.msSinceVoice, 999_999), "msSinceSound": min(gate.msSinceSound, 999_999)]
        }
        if config.logTranscripts {
            info["recentlyHeard"] = (finals.suffix(3).map(\.text) + [volatile?.text ?? ""]).joined(separator: " | ")
        }
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Menu actions

    @objc func menuTalk() { talkPressed() }
    @objc func menuStop() { stopSpeaking() }
    @objc func menuMute() { setMuted(!muted) }
    @objc func menuPermissions() { MacPermissions.openSettings("Privacy_Microphone") }
    @objc func menuReload() { reloadSettings() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    @objc func menuInterface() {
        if let url = URL(string: config.interfaceURL) { NSWorkspace.shared.open(url) }
    }

    @objc func menuSettings() {
        Config.createEmptyUserConfig()
        NSWorkspace.shared.open(Paths.configDefaults)
        NSWorkspace.shared.open(Paths.config)
    }

    @objc func menuLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logs.appendingPathComponent("voice.log")])
    }
}

/// One request to Claude, on its own bridge connection (its own Claude session). The
/// conversation's request streams straight into speech; a background one is buffered and
/// said, labelled with its task number, when it is done — so an answer can never be
/// spoken as the answer to something else.
@MainActor
final class ClaudeTurn {
    let request: String
    /// What was sent: the request with the "[Mac: …]" context line.
    let text: String
    /// The Mac's facts on their own (sent apart from the user's words).
    let context: String
    let connection: BridgeConnection
    var job: TaskManager.Job?
    var foreground = true
    var reply = ""
    private(set) var outcome: TaskManager.Outcome?
    private var waiter: CheckedContinuation<TaskManager.Outcome, Never>?
    var closeTimer: Timer?

    init(request: String, text: String, connection: BridgeConnection, context: String = "") {
        self.request = request
        self.text = text
        self.context = context
        self.connection = connection
    }

    var over: Bool { outcome != nil }

    func finish(_ outcome: TaskManager.Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    func result() async -> TaskManager.Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }
}
