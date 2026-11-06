import AppKit
import Carbon.HIToolbox
import Foundation
import Synchronization

// MARK: - Locations

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/JarvisVoice", isDirectory: true)
    // JARVIS_LOG_DIR (absolute) moves the log, as in core/paths.mjs — used by the unit tests so
    // they never write into the real voice.log. The LaunchAgent does not set it.
    static let logs = ProcessInfo.processInfo.environment["JARVIS_LOG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        ?? home.appendingPathComponent("Library/Logs/Jarvis", isDirectory: true)
    static let config = support.appendingPathComponent("config.json")
    static let configDefaults = support.appendingPathComponent("config.defaults.json")
    static let controlSocket = support.appendingPathComponent("control.sock").path

    static func ensure() {
        for dir in [support, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Log

/// Appends to ~/Library/Logs/Jarvis/voice.log, rotating at 5 MB.
/// Never given microphone audio, and transcripts only when the user opts in
/// with "logTranscripts": true.
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let queue = DispatchQueue(label: "local.jarvis.voice.log")
    private let url = Paths.logs.appendingPathComponent("voice.log")
    private let limit: UInt64 = 5 * 1024 * 1024
    private let toTerminal = isatty(STDERR_FILENO) == 1
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        Paths.ensure()
        reopen()
    }

    private func reopen() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(stamp.string(from: now)) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if size > limit {
                try? handle?.close()
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
                reopen()
            }
            handle?.write(data)
            size += UInt64(data.count)
            if toTerminal { FileHandle.standardError.write(data) }
        }
    }

    /// Waits for queued lines to reach the disk (used just before exiting).
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }
}

func log(_ message: String) { Log.shared.write("info", message) }
func logError(_ message: String) { Log.shared.write("error", message) }

// MARK: - Settings

/// ~/Library/Application Support/JarvisVoice/config.json holds only what you
/// change; every other key takes the default below. config.defaults.json, next
/// to it, is rewritten on every launch with all keys and their defaults, for
/// reference. Edit config.json, then choose "Reload Settings" from the menu bar
/// (or run `jarvisctl reload`).
struct Config: Codable {
    /// The name that wakes him, plus spellings the recogniser sometimes produces.
    var wakeWords = ["jarvis", "jarvys", "jervis"]
    /// Optional words in front of the name: "hey jarvis", "ok jarvis".
    var wakePrefixes = ["hey", "hi", "ok", "okay"]
    /// true = only "hey jarvis" wakes him, not "jarvis" alone.
    var requirePrefix = false
    var locale = "en-US"

    /// "?client=jarvis-voice-mac" tells the bridge this is Jarvis Voice: Mac tools and
    /// the permission broker are offered only to this client.
    var bridgeURL = "ws://127.0.0.1:8787/?client=jarvis-voice-mac"
    /// The bridge only accepts its own local web interface as a client.
    var bridgeOrigin = "http://localhost:5173"
    var bridgeHTTP = "http://127.0.0.1:8787"
    var interfaceURL = "http://localhost:5173"

    /// auto = ElevenLabs if the bridge has a key, else Kokoro, else the macOS voice.
    var voiceEngine = "auto"
    var kokoroURL = "http://127.0.0.1:8790"
    var kokoroVoice = "bm_george"
    var kokoroSpeed = 1.0
    /// A macOS voice name or identifier; empty picks the best installed English voice.
    var systemVoice = ""
    var systemRate = 0.5
    var volume = 1.0

    /// auto = the system microphone, but the Mac's own mic instead of a Bluetooth
    /// headset's (so headphones keep full-quality audio); system; builtin.
    var inputDevice = "auto"

    /// Quiet (by the microphone's own level) that ends a request…
    var endOfSpeechSeconds = 0.6
    /// …or, when the room is too noisy to tell, quiet in the transcript.
    var commandSilenceSeconds = 1.2
    /// After a bare "Jarvis", how soon he answers "Yes?".
    var ackAfterSeconds = 0.45
    /// How loud (RMS) counts as someone speaking, at the least.
    var voiceLevel = 0.008
    var maxCommandSeconds = 25.0
    /// How long he keeps listening, without the wake word, after he answers.
    var followUpSeconds = 8.0
    var responseTimeoutSeconds = 180.0

    var acknowledgePhrase = "Yes?"
    var dismissPhrase = "Very good, sir."
    var fillerAfterSeconds = 4.0
    /// Say a filler as soon as Claude starts using a tool (a search, an app action).
    var fillerOnTool = true
    var fillers = ["One moment.", "Working on it.", "Just a moment."]
    /// How long he waits for your answer to a permission question.
    var answerSeconds = 8.0
    /// Speak over him to interrupt (with headphones any speech; on speakers his
    /// name, "stop", or clearly new words).
    var bargeIn = true
    /// What interrupts him: "auto" (his name or a stop word through the speakers, any clear
    /// speech with headphones), "name", or "speech".
    var interruptWith = "auto"
    /// Keep one Claude session open and ready, so the first answer comes sooner.
    var warmConnection = true
    /// Handle "open Safari", "close it", "revoke camera access"… on the Mac, without Claude.
    var localCommands = true
    var endPhrases = ["that's all", "that is all", "that will be all", "that'll be all", "goodbye", "good bye",
                      "bye", "thank you", "thanks", "never mind", "nevermind", "stop", "cancel", "dismissed",
                      "go to sleep", "nothing", "no thanks", "no thank you", "that's it"]
    var cancelPhrases = ["stop", "cancel", "never mind", "nevermind", "forget it", "stop that", "cancel that"]

    /// Say "Jarvis…" while he is working on something to ask for something else: the first
    /// request carries on as a background task and its answer is given when it is ready.
    var backgroundTasks = true
    /// A task that takes longer than this (an app that is slow to open) is acknowledged
    /// and finished in the background, so you can carry on talking.
    var backgroundAfterSeconds = 1.5
    /// Claude requests at once: the conversation plus background tasks. Each is its own
    /// Claude session; fewer run when the Mac is short of memory or very busy.
    var maxClaudeTasks = 3
    /// How long he waits for you to switch on a macOS permission he has guided you to.
    var permissionGuideSeconds = 60.0

    var wakeSound = "Tink"
    var endSound = "Pop"
    /// Kept low: the wake chime plays while you may still be speaking.
    var soundVolume = 0.3
    var logTranscripts = false
    /// Option-Command-J: talk to Jarvis, or cut him off while he is speaking.
    var hotkey = true

    static func load() -> Config {
        let defaults = Config()
        Paths.ensure()
        defaults.save(to: Paths.configDefaults)
        guard let data = try? Data(contentsOf: Paths.config) else {
            createEmptyUserConfig()
            return defaults
        }
        guard let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logError("config.json is not valid JSON — using the defaults")
            return defaults
        }
        guard let defaultData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
        else { return defaults }
        for (key, value) in user { merged[key] = value }
        do {
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            return try JSONDecoder().decode(Config.self, from: mergedData)
        } catch {
            logError("config.json has a value of the wrong type (\(error)) — using the defaults")
            return defaults
        }
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Your settings file starts empty, so changes to the defaults in a later
    /// version still reach you. Copy any key you want to change from
    /// config.defaults.json.
    static func createEmptyUserConfig() {
        guard !FileManager.default.fileExists(atPath: Paths.config.path) else { return }
        try? Data("{\n}\n".utf8).write(to: Paths.config, options: .atomic)
    }

    var displayWakePhrase: String {
        let name = (wakeWords.first ?? "jarvis").capitalized
        if let prefix = wakePrefixes.first { return "\(prefix.capitalized) \(name)" }
        return name
    }

    var contextualStrings: [String] {
        let name = (wakeWords.first ?? "jarvis").capitalized
        return [name] + wakePrefixes.prefix(2).map { "\($0.capitalized) \(name)" }
    }
}

// MARK: - Wake phrase

struct WakeMatcher {
    private let regex: NSRegularExpression
    private static let trim = CharacterSet(charactersIn: " ,.:;!?-—–\n\t\"'")

    init(config: Config) {
        let words = config.wakeWords.map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }.filter { !$0.isEmpty }
        let prefixes = config.wakePrefixes.map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }.filter { !$0.isEmpty }
        let name = "(?:" + (words.isEmpty ? "jarvis" : words.joined(separator: "|")) + ")"
        var prefix = ""
        if !prefixes.isEmpty {
            prefix = "(?:(?:" + prefixes.joined(separator: "|") + ")[\\s,.!]+)" + (config.requirePrefix ? "" : "?")
        }
        // The lookahead keeps possessives ("Jarvis's job") from waking him.
        let pattern = "\\b" + prefix + name + "\\b(?!['’]s)"
        regex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (try! NSRegularExpression(pattern: "\\bjarvis\\b", options: [.caseInsensitive]))
    }

    private func firstMatch(_ text: String) -> Range<String.Index>? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(m.range, in: text)
    }

    func contains(_ text: String) -> Bool { firstMatch(text) != nil }

    /// How many words, up to and including the wake phrase ("Hey Jarvis" → 2).
    func wordsThroughWake(_ text: String) -> Int? {
        guard let r = firstMatch(text) else { return nil }
        return text[..<r.upperBound].split(whereSeparator: { $0.isWhitespace }).count
    }

    /// What follows the first wake phrase, or nil if there is none.
    func after(_ text: String) -> String? {
        guard let r = firstMatch(text) else { return nil }
        return String(text[r.upperBound...]).trimmingCharacters(in: Self.trim)
    }

    /// Drops a leading "Jarvis," from follow-up speech; everything else is kept.
    func strippingLeading(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = firstMatch(t), t.distance(from: t.startIndex, to: r.lowerBound) <= 2 {
            return String(t[r.upperBound...]).trimmingCharacters(in: Self.trim)
        }
        return t
    }
}

// MARK: - Text helpers

/// Lowercased words only, for comparing phrases.
func normalized(_ s: String) -> String {
    let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
    let mapped = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
    return String(mapped).split(separator: " ").joined(separator: " ")
}

private let markdownLink = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)")
private let bareURL = try! NSRegularExpression(pattern: "https?://\\S+")
private let markup = try! NSRegularExpression(pattern: "[*_`#>|~]+")
private let bullet = try! NSRegularExpression(pattern: "^\\s*(?:[-•]|\\d+\\.)\\s+", options: [.anchorsMatchLines])
private let spaces = try! NSRegularExpression(pattern: "\\s+")

private func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
    regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
}

/// Removes anything that should not be read aloud (the bridge's own prompt
/// already asks for plain prose; this is the safety net).
func speakable(_ text: String) -> String {
    var t = replace(markdownLink, in: text, with: "$1")
    t = replace(bareURL, in: t, with: "a link")
    t = replace(bullet, in: t, with: "")
    t = replace(markup, in: t, with: "")
    t = replace(spaces, in: t, with: " ")
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Turns a stream of text deltas into whole sentences, so speech can start
/// before the full reply has arrived.
struct SentenceBuffer {
    private var pending = ""
    private var emitted = 0
    private static let boundary = try! NSRegularExpression(pattern: "(?<=[.!?…])[\"'”’)\\]]*\\s+|\\n+")
    private static let clause = try! NSRegularExpression(pattern: "(?<=[,;:—])\\s+")

    mutating func push(_ delta: String) -> [String] {
        pending += delta
        let ns = pending as NSString
        let matches = Self.boundary.matches(in: pending, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else {
            // A long first sentence: start speaking at its first clause rather
            // than waiting for the full stop — the voice engine needs a moment
            // per line, and the first line is the one you wait for.
            if emitted == 0, ns.length > 60,
               let cut = Self.clause.firstMatch(in: pending, range: NSRange(location: 30, length: ns.length - 30)) {
                let end = cut.range.location + cut.range.length
                let head = ns.substring(to: end).trimmingCharacters(in: .whitespacesAndNewlines)
                pending = ns.substring(from: end)
                emitted += 1
                return [head]
            }
            return []
        }
        defer { emitted += 1 }
        var sentences: [String] = []
        var start = 0
        for m in matches {
            let end = m.range.location + m.range.length
            let s = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            start = end
        }
        pending = ns.substring(from: last.range.location + last.range.length)
        return sentences
    }

    mutating func flush() -> String? {
        let s = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return s.isEmpty ? nil : s
    }
}

// MARK: - Audio gate shared with the capture thread

/// Whether microphone audio is currently passed to the recogniser, and how
/// much has been (the recogniser's own clock).
final class AudioGate: Sendable {
    let open = Atomic<Bool>(false)
    let frames = Atomic<Int>(0)
    /// Background level, ×1e6 — follows the room down quickly and up slowly.
    let noise = Atomic<Int>(0)
    /// When the microphone last heard something louder than the room (ms, uptime).
    let lastVoice = Atomic<Int>(0)
    /// When it last heard anything clearly above the room, even quiet speech (ms, uptime) —
    /// a more sensitive signal, used only so Jarvis never starts talking over someone.
    let lastSound = Atomic<Int>(0)
    /// False while Jarvis is speaking: his own voice must not become "the room".
    let adapting = Atomic<Bool>(true)
    let rate: Double
    let minLevel: Float

    init(rate: Double, minLevel: Float) {
        self.rate = rate
        self.minLevel = minLevel
    }

    var seconds: Double { Double(frames.load(ordering: .relaxed)) / rate }

    private static var nowMs: Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    /// Called from the audio thread for every buffer: a simple local voice-activity detector.
    func observe(level: Float) {
        var floor = Float(noise.load(ordering: .relaxed)) / 1_000_000
        if adapting.load(ordering: .relaxed) {
            floor = floor == 0 ? min(level, 0.01) : (level < floor ? floor * 0.9 + level * 0.1 : floor * 0.999 + level * 0.001)
            floor = min(floor, 0.01) // a quiet-to-normal room; never "as loud as a voice"
            noise.store(Int(floor * 1_000_000), ordering: .relaxed)
        }
        if level > max(floor * 3, minLevel) { lastVoice.store(Self.nowMs, ordering: .relaxed) }
        if level > max(floor * 1.8, minLevel * 0.5) { lastSound.store(Self.nowMs, ordering: .relaxed) }
    }

    /// Uptime in ms of the last speech-level sound.
    var lastVoiceMs: Int { lastVoice.load(ordering: .relaxed) }
    static var uptimeMs: Int { nowMs }

    /// Milliseconds since the microphone last heard speech-level sound.
    var msSinceVoice: Int { Self.nowMs - lastVoice.load(ordering: .relaxed) }
    var msSinceSound: Int { Self.nowMs - lastSound.load(ordering: .relaxed) }
    var noiseFloor: Double { Double(noise.load(ordering: .relaxed)) / 1_000_000 }
}

// MARK: - Global shortcut (Option-Command-J). Carbon hot keys need no permissions.

final class HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init?(action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4A52_5653), id: 1) // 'JRVS'
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(cmdKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else { return nil }
    }
}
