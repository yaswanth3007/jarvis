import AppKit
import AVFoundation
import CryptoKit
import Foundation

/// Speaks replies sentence by sentence, through the best voice available:
///
///   1. ElevenLabs, through the bridge's existing /tts endpoint, when the
///      bridge has an ElevenLabs key (the same premium voice the web UI uses);
///   2. Kokoro, the project's own neural voice, from the local voice engine;
///   3. the macOS speech synthesiser, which always works.
///
/// If a neural engine fails mid-reply that one line falls back to the macOS
/// voice, so a reply is never lost.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Engine: String {
        case elevenlabs = "ElevenLabs (bridge /tts)"
        case kokoro = "Kokoro neural voice (local)"
        case system = "macOS voice"
    }

    private struct Line {
        let id = UUID()
        let text: String
        let audio: Task<Data?, Never>?
    }

    private(set) var engine: Engine = .system
    private var config: Config
    private let synth = AVSpeechSynthesizer()
    private var systemVoice: AVSpeechSynthesisVoice?
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private var queue: [Line] = []
    private var current: UUID?
    private var cachedAck: (phrase: String, engine: Engine, data: Data)?

    /// Called whenever the queue runs dry.
    var onIdle: (() -> Void)?
    /// Called the moment a line actually starts sounding (for latency measurement).
    var onAudioStart: ((String) -> Void)?
    /// Short lines said often ("Yes?", "Safari is open.") are kept ready.
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []

    init(config: Config) {
        self.config = config
        super.init()
        synth.delegate = self
        systemVoice = Self.pickSystemVoice(config.systemVoice)
        log("macOS fallback voice: \(systemVoice.map { "\($0.name) (\($0.language))" } ?? "system default")")
    }

    func update(config: Config) {
        self.config = config
        systemVoice = Self.pickSystemVoice(config.systemVoice)
        cachedAck = nil
    }

    var isBusy: Bool { current != nil || !queue.isEmpty }
    var engineName: String { engine.rawValue }
    var systemVoiceName: String { systemVoice?.name ?? "default" }

    func enqueue(_ text: String) {
        let clean = speakable(text)
        guard !clean.isEmpty else { return }
        let engine = self.engine
        let key = "\(engine.rawValue)|\(clean)"
        let audio: Task<Data?, Never>?
        if engine == .system {
            audio = nil
        } else if let cached = cache[key] {
            audio = Task { cached }
        } else {
            audio = Task {
                let data = await self.synthesize(clean, with: engine)
                if let data, clean.count <= 48 { self.remember(key, data) }
                return data
            }
        }
        queue.append(Line(text: clean, audio: audio))
        pump()
    }

    /// Synthesizes short lines ahead of time, one after another, so they play instantly later.
    func prefetch(_ lines: [String]) {
        let engine = self.engine
        guard engine != .system else { return }
        Task { @MainActor in
            for line in lines {
                let clean = speakable(line)
                let key = "\(engine.rawValue)|\(clean)"
                guard !clean.isEmpty, cache[key] == nil else { continue }
                if let data = await self.synthesize(clean, with: engine) { self.remember(key, data) }
            }
        }
    }

    private func remember(_ key: String, _ data: Data) {
        guard cache[key] == nil else { return }
        cache[key] = data
        cacheOrder.append(key)
        if cacheOrder.count > 60 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// "Yes, sir?" is said often enough to keep ready.
    func acknowledge(_ phrase: String) {
        if let ack = cachedAck, ack.phrase == phrase, ack.engine == engine {
            let data = ack.data
            queue.append(Line(text: phrase, audio: Task { data }))
            pump()
        } else {
            enqueue(phrase)
        }
    }

    func stop() {
        for line in queue { line.audio?.cancel() }
        queue.removeAll()
        current = nil
        player?.stop()
        player = nil
        utterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // MARK: Engine choice

    /// The per-install key (bridge/voice-auth.mjs), read once it exists.
    private var voiceKey: CryptoKit.SymmetricKey?
    private var key: CryptoKit.SymmetricKey? {
        if voiceKey == nil { voiceKey = VoiceKey.load() }
        return voiceKey
    }
    private var unprovenNoted = Set<String>()

    /// A voice engine is used only once it proves it is this user's own: everything Jarvis
    /// says is sent to it, and something else holding its port must never hear it.
    private func proven(_ url: String, _ who: String) async -> [String: Any]? {
        let nonce = VoiceKey.nonce()
        guard let health = await Self.json("\(url)/health?nonce=\(nonce)") else { return nil }
        guard VoiceKey.proves(health["proof"], who, nonce, key: key) else {
            if unprovenNoted.insert(who).inserted {
                logError("voice: \(url) answers but can't prove it is this Mac's \(who) — not using it")
            }
            return nil
        }
        unprovenNoted.remove(who)
        return health
    }

    func refreshEngine() async {
        let preference = config.voiceEngine.lowercased()
        var chosen = Engine.system
        if preference == "auto" || preference == "elevenlabs" {
            if let health = await proven(config.bridgeHTTP, "jarvis-bridge-http"), health["tts"] as? Bool == true {
                chosen = .elevenlabs
            }
        }
        if chosen == .system && (preference == "auto" || preference == "kokoro") {
            if let health = await proven(config.kokoroURL, "jarvis-voice-engine"), health["ready"] as? Bool == true {
                chosen = .kokoro
            }
        }
        if chosen != engine {
            log("voice: \(chosen.rawValue)")
            engine = chosen
            cachedAck = nil
        }
        if cachedAck == nil && engine != .system {
            let phrase = config.acknowledgePhrase
            if let data = await synthesize(phrase, with: engine) {
                cachedAck = (phrase, engine, data)
            }
        }
    }

    private static func json(_ url: String) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func synthesize(_ text: String, with engine: Engine) async -> Data? {
        let endpoint: String
        var body: [String: Any] = ["text": text]
        var request: URLRequest
        switch engine {
        case .system:
            return nil
        case .kokoro:
            endpoint = config.kokoroURL + "/speak"
            body["voice"] = config.kokoroVoice
            body["speed"] = config.kokoroSpeed
        case .elevenlabs:
            endpoint = config.bridgeHTTP + "/tts"
        }
        guard let url = URL(string: endpoint) else { return nil }
        let nonce = VoiceKey.nonce()
        request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("1", forHTTPHeaderField: "x-jarvis-voice")
        request.setValue(nonce, forHTTPHeaderField: "x-jarvis-nonce")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
            // The engine answering must still be ours (it could have been replaced since the
            // last check): if not, this line is dropped and the macOS voice takes over.
            let who = engine == .kokoro ? "jarvis-voice-engine-speak" : "jarvis-bridge-tts"
            guard VoiceKey.proves(http.value(forHTTPHeaderField: "x-jarvis-proof"), who, nonce, key: key) else {
                logError("voice: the \(engine.rawValue) engine's reply wasn't proven — switching to the macOS voice")
                self.engine = .system
                cachedAck = nil
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: Playback

    private func pump() {
        guard current == nil else { return }
        guard !queue.isEmpty else {
            onIdle?()
            return
        }
        let line = queue.removeFirst()
        current = line.id
        currentText = line.text
        guard let audio = line.audio else {
            speakWithSystemVoice(line.text)
            return
        }
        Task { @MainActor in
            let data = await audio.value
            guard self.current == line.id else { return } // stopped meanwhile
            if let data, self.play(data) { return }
            log("neural voice unavailable for one line — using the macOS voice")
            self.speakWithSystemVoice(line.text)
        }
    }

    private func play(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        player.volume = Float(config.volume)
        player.prepareToPlay()
        guard player.play() else { return false }
        self.player = player
        if let line = queueText(current) { onAudioStart?(line) }
        return true
    }

    private func speakWithSystemVoice(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = systemVoice
        u.rate = Float(config.systemRate)
        u.volume = Float(config.volume)
        utterance = u
        synth.speak(u)
    }

    private var currentText: String?
    private func queueText(_ id: UUID?) -> String? { currentText }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { if utterance === self.utterance, let line = currentText { onAudioStart?(line) } }
    }

    private func lineFinished() {
        current = nil
        player = nil
        utterance = nil
        pump()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { if player === self.player { lineFinished() } }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated { if player === self.player { lineFinished() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { if utterance === self.utterance { lineFinished() } }
    }

    // MARK: Voices

    static func pickSystemVoice(_ preference: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        if !preference.isEmpty {
            if let v = AVSpeechSynthesisVoice(identifier: preference) { return v }
            if let v = all.first(where: { $0.name.caseInsensitiveCompare(preference) == .orderedSame }) { return v }
        }
        // Real voices only — not the novelty and Eloquence voices.
        let english = all.filter {
            $0.language.hasPrefix("en") && !$0.identifier.contains("eloquence")
                && !$0.identifier.contains("speech.synthesis.voice")
        }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 100
            if v.language == "en-GB" { s += 30 }
            if v.gender == .male { s += 10 }
            if v.name.hasPrefix("Daniel") || v.name.hasPrefix("Jamie") || v.name.hasPrefix("Arthur") { s += 5 }
            return s
        }
        return english.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }
}

/// Plays a system sound (from /System/Library/Sounds) at the given volume.
func playSound(_ name: String, volume: Double) {
    guard !name.isEmpty, volume > 0, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
    sound.volume = Float(min(volume, 1))
    sound.play()
}
