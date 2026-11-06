import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Speech
import UserNotifications

// MARK: - Jarvis's own permissions (shared with the bridge's permission broker)

/// ~/Library/Application Support/JarvisVoice/permissions.json. Jarvis Voice is
/// the only writer; the bridge reads it fresh on every decision, so a change
/// applies to the very next action.
struct PermissionStore: Codable {
    struct Folder: Codable { var path: String; var access: String } // allow | read | deny

    var capabilities: [String: String] = [:] // capability → allow | deny | ask
    var apps: [String: String] = [:]         // bundle id → allow | deny
    var folders: [Folder] = []
    var integrations: [String: String] = [:]

    static let url = Paths.support.appendingPathComponent("permissions.json")
    static let historyURL = Paths.support.appendingPathComponent("permission-history.jsonl")

    /// What applies when you have not decided (mirrors bridge/permissions.mjs).
    static let defaults: [String: String] = [
        "web": "allow", "apps.open": "allow", "apps.close": "allow", "app": "ask", "camera": "ask",
        "screen": "ask", "files.read": "ask", "files.write": "ask", "shell": "ask", "integration": "ask",
    ]

    static func load() -> PermissionStore {
        guard let data = try? Data(contentsOf: url) else { return PermissionStore() }
        return (try? JSONDecoder().decode(PermissionStore.self, from: data)) ?? PermissionStore()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    func value(_ capability: String) -> String { capabilities[capability] ?? Self.defaults[capability] ?? "ask" }

    static func record(_ entry: [String: Any]) {
        var e = entry
        e["t"] = ISO8601DateFormatter().string(from: Date())
        e["source"] = e["source"] ?? "Jarvis Voice"
        guard let data = try? JSONSerialization.data(withJSONObject: e), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: historyURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
    }

    /// Applies a remembered decision from a spoken answer.
    mutating func remember(capability: String, target: String, allow: Bool) {
        let v = allow ? "allow" : "deny"
        switch capability {
        case "app":
            if !target.isEmpty && target != "frontmost" { apps[target] = v } else { capabilities["app"] = v }
        case "files.read", "files.write":
            let access = allow ? (capability == "files.read" ? "read" : "allow") : "deny"
            folders.removeAll { $0.path == target }
            folders.append(Folder(path: target, access: access))
        case "integration":
            integrations[target] = v
        default:
            capabilities[capability] = v
        }
    }
}

// MARK: - Spoken answers to a permission question

enum PermissionAnswer: String {
    case allowOnce = "allow_once", allowSession = "allow_session", allowAlways = "allow_always"
    case deny = "deny", denyAlways = "deny_always"

    var allows: Bool { rawValue.hasPrefix("allow") }

    /// Only a clear, whole answer counts. Anything else — a sentence that merely
    /// contains "yes", background talk — is not an approval.
    static func parse(_ text: String) -> PermissionAnswer? {
        let filler: Set<String> = ["jarvis", "sir", "please", "um", "uh", "well", "oh", "hey"]
        let words = normalized(text).split(separator: " ").map(String.init).filter { !filler.contains($0) }
        let t = words.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        func any(_ options: [String]) -> Bool { options.contains(t) || options.contains(where: { "\($0) it" == t }) }
        if any(["always allow", "allow always", "always", "remember", "remember that", "yes always", "yes remember",
                "allow and remember", "yes always allow", "always yes", "remember it", "allow it always"]) { return .allowAlways }
        if any(["allow once", "just once", "only once", "once", "this once", "just this once", "allow it once",
                "yes just this once", "yes once", "only this time", "just this time"]) { return .allowOnce }
        if any(["never", "never allow", "don't ever", "do not ever", "always deny", "deny always", "no never",
                "never ever", "don't ever allow", "never allow it"]) { return .denyAlways }
        if any(["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "go ahead", "do it", "proceed", "continue",
                "confirm", "confirmed", "yes please", "yes allow", "yes go ahead", "yes do it", "please do", "affirmative",
                "that's fine", "fine", "yes continue", "allow for now", "for now", "allow for this conversation",
                "allow this time", "yes proceed", "ok go ahead", "okay go ahead", "go for it", "approved", "i approve"]) { return .allowSession }
        if any(["no", "nope", "nah", "don't", "do not", "don't allow", "do not allow", "deny", "cancel", "stop",
                "no thanks", "no thank you", "don't do it", "do not do it", "negative", "never mind", "not now",
                "leave it", "don't bother", "no don't", "no stop", "dont allow", "no do not"]) { return .deny }
        return nil
    }
}

// MARK: - Voice commands about permissions ("revoke camera access")

enum PermissionCommand {
    case list
    case listApps
    case can(String)                                         // "can you control Safari?"
    case change(capability: String, target: String, allow: Bool, label: String)
    case reset
}

extension PermissionCommand {
    static func parse(_ text: String, resolveApp: (String) -> (name: String, bundleID: String)?) -> PermissionCommand? {
        var t = normalized(text).replacingOccurrences(of: "jarvis's", with: "your")
            .split(separator: " ").filter { $0 != "jarvis" && $0 != "please" && $0 != "sir" }.joined(separator: " ")
        for s in [" again", " from now on", " anymore", " any more"] where t.hasSuffix(s) { t.removeLast(s.count) }
        func m(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let r = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<r.numberOfRanges).map { i in
                Range(r.range(at: i), in: t).map { String(t[$0]) } ?? ""
            }
        }
        if m("(what|which) (permissions|access|rights) (do you|have you|you) (currently )?(have|got)( currently| right now| now)?") != nil
            || m("(show|tell|list|read) (me )?(my |your |the )?(current )?permissions( currently| right now)?") != nil
            || m("what (are|is) (my |your |the )?(current )?permissions?( right now)?") != nil
            || m("what are you (allowed|permitted) to do") != nil {
            return .list
        }
        if m("(what|which) (apps|applications|programs) (can|may) you (control|access|use|operate)") != nil { return .listApps }
        if let g = m("can you (control|access|use|operate|read|see) (.+)") { return .can(g[2]) }
        if m("reset (all |your |my )?(the )?permissions") != nil { return .reset }

        // Revoking and denying: "revoke camera access", "don't allow access to my Downloads folder",
        // "remove permission to control other applications", "don't allow you to control Chrome".
        // (pattern, index of the capture group that names what is being revoked)
        // "stop controlling applications", "stop using the camera", "stop opening apps".
        // ("Stop opening Spotify" is about a task, not a permission: see TaskCommand.)
        if let g = m("(stop|quit|no more) (controlling|using|accessing|reading|looking at|watching|opening|launching|closing|quitting) (.+)") {
            let verb = g[2]
            let opening = ["opening", "launching"].contains(verb), closing = ["closing", "quitting"].contains(verb)
            let phrase = (opening ? "opening " : closing ? "closing " : verb == "controlling" ? "controlling " : "") + g[3]
            if let c = capability(for: phrase, resolveApp: resolveApp),
               !(opening || closing) || c.capability == "apps.open" || c.capability == "apps.close" {
                return .change(capability: c.capability, target: c.target, allow: false, label: c.label)
            }
        }
        let take: [(String, Int)] = [
            ("(revoke|remove|withdraw|disable|turn off|take away)( your| the)?( access to| access for| permission to| permission for| permissions for)? (.+?)( access| permission| permissions)?", 4),
            ("(don't|do not|never) (allow|let|give)( you| yourself)?( to)?( access| permission)?( to| for)? (.+?)( access| permission)?", 7),
            ("(block|deny)( your| you)?( access to| access)? (.+)", 4),
        ]
        for (pattern, index) in take {
            if let g = m(pattern), g.count > index,
               let c = capability(for: g[index], resolveApp: resolveApp) {
                return .change(capability: c.capability, target: c.target, allow: false, label: c.label)
            }
        }
        // Granting always gets a spoken confirmation afterwards.
        if let g = m("(allow|let|give|grant)( you| yourself)?( to)?( access| permission)?( to| for)? (.+?)( access| permission)?") {
            let phrase = g[6].trimmingCharacters(in: .whitespaces)
            if let c = capability(for: phrase, resolveApp: resolveApp) {
                return .change(capability: c.capability, target: c.target, allow: true, label: c.label)
            }
        }
        return nil
    }

    /// "camera", "my downloads folder", "control other applications", "safari", "use chrome"…
    static func capability(for raw: String, resolveApp: (String) -> (name: String, bundleID: String)?)
        -> (capability: String, target: String, label: String)? {
        var p = raw.trimmingCharacters(in: .whitespaces)
        // Opening and closing apps are permissions of their own ("stop opening apps").
        let appWords = "(apps|applications|programs|other apps|other applications|any apps|my apps|any app|any application)"
        if p.range(of: "^(opening|open|launching|launch|starting) \(appWords)$", options: .regularExpression) != nil {
            return ("apps.open", "", "opening apps")
        }
        if p.range(of: "^(closing|close|quitting|quit) \(appWords)$", options: .regularExpression) != nil {
            return ("apps.close", "", "closing apps")
        }
        for prefix in ["to ", "my ", "the ", "your ", "use ", "using ", "access ", "access to ", "control ", "controlling ", "read ", "reading ",
                       "accessing ", "looking at ", "watching ", "opening ", "closing "] {
            while p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        }
        p = p.trimmingCharacters(in: .whitespaces)
        switch p {
        case "camera", "the camera", "webcam", "camera access": return ("camera", "", "the camera")
        case "screen", "my screen", "screen recording", "screenshots", "screen capture": return ("screen", "", "your screen")
        case "files", "my files", "files and folders", "documents", "file access": return ("files", "", "your files")
        case "shell", "terminal", "commands", "the terminal", "command line", "shell commands", "run commands": return ("shell", "", "running commands")
        case "other applications", "other apps", "applications", "apps", "all apps", "my apps", "other applications on my mac":
            return ("app", "", "controlling other apps")
        case "web", "the web", "internet", "the internet", "web search", "browsing": return ("web", "", "searching the web")
        case "microphone", "mic", "the microphone": return ("microphone", "", "the microphone")
        default: break
        }
        let folderNames = ["downloads", "desktop", "documents", "pictures", "movies", "music", "home"]
        let folderWord = p.replacingOccurrences(of: " folder", with: "").replacingOccurrences(of: " directory", with: "")
        if folderNames.contains(folderWord) {
            let path = folderWord == "home" ? NSHomeDirectory() : NSHomeDirectory() + "/" + folderWord.capitalized
            return ("files", path, "your \(folderWord.capitalized) folder")
        }
        if p.hasPrefix("~") || p.hasPrefix("/") {
            return ("files", (p as NSString).expandingTildeInPath, p)
        }
        if let app = resolveApp(p) { return ("app", app.bundleID, app.name) }
        return nil
    }
}

// MARK: - What macOS has granted (read only — Jarvis never changes these)

enum MacPermissions {
    static func camera() -> String { name(AVCaptureDevice.authorizationStatus(for: .video)) }
    static func microphone() -> String { name(AVCaptureDevice.authorizationStatus(for: .audio)) }
    static func speech() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }
    static func screenRecording() -> String { CGPreflightScreenCaptureAccess() ? "granted" : "not granted" }

    /// Whether macOS actually shows Jarvis Voice other apps' window contents: their window
    /// titles are only visible with Screen Recording. Asks nothing, shows no prompt.
    static func screenContentVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = getpid()
        return windows.contains { window in
            let owner = window[kCGWindowOwnerPID as String] as? Int32
            let name = window[kCGWindowName as String] as? String
            let app = window[kCGWindowOwnerName as String] as? String
            return owner != me && !(name ?? "").isEmpty && !["Window Server", "Dock", "SystemUIServer", "Control Centre", "Control Center"].contains(app ?? "")
        }
    }
    static func accessibility() -> String { AXIsProcessTrusted() ? "granted" : "not granted" }

    static func notifications() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "granted"
        case .denied: "denied"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    /// Apple Events permission to control one app (without asking).
    static func automation(_ bundleID: String) -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return "unknown" }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return "granted"
        case OSStatus(errAEEventNotPermitted): return "denied"
        case OSStatus(errAEEventWouldRequireUserConsent): return "not asked yet"
        case OSStatus(procNotFound): return "app not running"
        default: return "unknown (\(status))"
        }
    }

    private static func name(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// True when the Mac is managed by an organisation (MDM), which can lock privacy settings.
    static var managed: Bool {
        FileManager.default.fileExists(atPath: "/Library/Managed Preferences")
            && ((try? FileManager.default.contentsOfDirectory(atPath: "/Library/Managed Preferences"))?.isEmpty == false)
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A macOS permission an action needs, and how to guide you to it. Jarvis can only ask
/// macOS (its own prompt) and open the right page of System Settings; switching it on is
/// yours to do, and Jarvis then checks that macOS really reports it as granted.
enum MacNeed: Equatable {
    case accessibility
    case screenRecording
    case camera
    case automation(bundleID: String, app: String)

    /// As said aloud: "Accessibility", "Screen Recording".
    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .camera: "camera"
        case .automation(_, let app): "Automation permission for \(app)"
        }
    }

    var anchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .automation: "Privacy_Automation"
        }
    }

    /// The page in Privacy & Security, as said aloud.
    var pane: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen and System Audio Recording"
        case .camera: "Camera"
        case .automation(_, let app): "Automation, under Jarvis Voice, \(app)"
        }
    }

    @MainActor var granted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .automation(let id, _): MacPermissions.automation(id) == "granted"
        }
    }

    /// Shows macOS's own prompt where there is one (it also puts Jarvis Voice in the list).
    @MainActor func requestFromMacOS() {
        switch self {
        case .accessibility: MacPermissions.requestAccessibility()
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .camera, .automation: break
        }
    }

    /// Screen Recording, once switched on, only applies after the app restarts.
    var needsRestart: Bool { self == .screenRecording }
}
