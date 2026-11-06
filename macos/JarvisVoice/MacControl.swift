import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit

/// The outcome of one Mac action: what Claude is told, what is said aloud.
struct MacResult {
    var text: String?
    var image: String?
    var error: String?
    var spoken: String?
    /// The failure was transient (a launch error), so one more attempt is reasonable.
    var retryable = false

    static func ok(_ text: String, say: String? = nil) -> MacResult { MacResult(text: text, spoken: say) }
    static func fail(_ error: String, retryable: Bool = false) -> MacResult { MacResult(error: error, retryable: retryable) }

    var payload: [String: Any] {
        var p: [String: Any] = [:]
        if let text { p["text"] = text }
        if let image { p["image"] = image; p["mimeType"] = "image/jpeg" }
        if let error { p["error"] = error }
        return p
    }
    /// For replies Jarvis gives itself, without Claude.
    var speech: String { error ?? spoken ?? text ?? "Done." }
}

struct InstalledApp: Equatable {
    let name: String
    let url: URL
    let bundleID: String
}

/// Acting on the Mac: apps, windows, the screen. Everything here uses Apple's own
/// mechanisms — Launch Services, Accessibility, ScreenCaptureKit, Apple Events —
/// so macOS asks you before Jarvis Voice may read or control anything.
@MainActor
final class MacControl {
    private(set) var installed: [InstalledApp] = []
    private var scannedAt = Date.distantPast
    /// The app Jarvis last opened or acted on — what "it" usually means.
    private(set) var lastApp: InstalledApp?
    /// The app in front, other than Jarvis Voice itself.
    private(set) var frontmost: NSRunningApplication?
    private var observer: NSObjectProtocol?
    var interfaceURL = "http://localhost:5173"

    static let accessibilityBlocked =
        "macOS currently blocks this. Please enable Accessibility for Jarvis Voice in System Settings, Privacy & Security, Accessibility — I've asked macOS to show you the switch."
    static let screenBlocked =
        "macOS currently blocks screen capture. Please enable Jarvis Voice in System Settings, Privacy & Security, Screen & System Audio Recording, then ask again."

    init() {
        let front = NSWorkspace.shared.frontmostApplication
        frontmost = front?.processIdentifier == getpid() ? nil : front
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != getpid() { self?.frontmost = app }
            }
        }
    }

    // MARK: - Finding apps

    private static let aliases: [String: String] = [
        "chrome": "google chrome", "google": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code",
        "code": "visual studio code", "visual studio": "visual studio code", "settings": "system settings",
        "system preferences": "system settings", "preferences": "system settings", "word": "microsoft word",
        "excel": "microsoft excel", "powerpoint": "microsoft powerpoint", "outlook": "microsoft outlook",
        "teams": "microsoft teams", "zoom": "zoom.us", "iterm2": "iterm", "text edit": "textedit", "face time": "facetime",
        "quicktime": "quicktime player", "imessage": "messages", "app store": "app store",
    ]

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    func scanIfNeeded() {
        guard installed.isEmpty || Date().timeIntervalSince(scannedAt) > 300 else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var found: [InstalledApp] = []
        func add(_ url: URL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, !seen.contains(id) else { return }
            seen.insert(id)
            let name = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
            found.append(InstalledApp(name: name, url: url, bundleID: id))
        }
        for root in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                     "\(home)/Applications", "/System/Library/CoreServices"] {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    add(url)
                } else if root == "/Applications" || root == "\(home)/Applications",
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for sub in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where sub.hasSuffix(".app") {
                        add(url.appendingPathComponent(sub))
                    }
                }
            }
        }
        installed = found
        scannedAt = Date()
    }

    /// The installed app a spoken name means — or nil when unsure (never a guess).
    func resolve(_ raw: String) -> InstalledApp? {
        scanIfNeeded()
        var q = normalized(raw).replacingOccurrences(of: "'s", with: "")
        for w in ["the ", "my ", "app ", "application "] where q.hasPrefix(w) { q.removeFirst(w.count) }
        for w in [" app", " application", " browser", " program"] where q.hasSuffix(w) && q != "app store" { q.removeLast(w.count) }
        q = Self.aliases[q] ?? q
        let target = Self.squash(q)
        guard target.count >= 2 else { return nil }
        let ranked = installed.sorted { rank($0) < rank($1) }
        if let exact = ranked.first(where: { Self.squash($0.name) == target }) { return exact }
        if let byID = ranked.first(where: { $0.bundleID.lowercased() == q }) { return byID }
        let prefixed = ranked.filter { Self.squash($0.name).hasPrefix(target) }
        if prefixed.count == 1 { return prefixed[0] }
        if let close = prefixed.first(where: { Self.squash($0.name).count - target.count <= 2 }) { return close }
        if target.count >= 4 {
            let contained = ranked.filter { Self.squash($0.name).contains(target) }
            if contained.count == 1 { return contained[0] }
        }
        return nil
    }

    private func rank(_ app: InstalledApp) -> Int {
        if app.bundleID == "com.apple.finder" { return 0 }
        return app.url.path.hasPrefix("/System/Library/CoreServices") ? 2 : 1
    }

    func info(for app: NSRunningApplication) -> InstalledApp? {
        guard let url = app.bundleURL, let id = app.bundleIdentifier else { return nil }
        return InstalledApp(name: app.localizedName ?? (url.lastPathComponent as NSString).deletingPathExtension, url: url, bundleID: id)
    }

    func running(_ name: String) -> NSRunningApplication? {
        if let info = resolve(name), let app = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).first {
            return app
        }
        let q = Self.squash(name)
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && Self.squash($0.localizedName ?? "") == q
        }
    }

    /// The app an action inside an app is for: always named, never "whatever is in front",
    /// which can change between the permission check and the action itself.
    private func named(_ name: String?) -> NSRunningApplication? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return running(name)
    }

    private static func unnamed(_ name: String?) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Name the app to act in (app: \"<its name>\") — I don't act on whichever app happens to be in front."
        }
        return "\(name) isn't running."
    }

    /// The app a request is about: the one named, or the one in front.
    func target(_ name: String?) -> NSRunningApplication? {
        if let name, !name.isEmpty { return running(name) }
        return frontmost
    }

    private func denied(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return PermissionStore.load().apps[bundleID] == "deny"
    }

    private func revoked(_ name: String) -> MacResult { .fail("You've revoked my access to \(name). Say “allow Jarvis to use \(name)” to change that.") }

    /// Jarvis's own permission to read or act inside an app (the bridge asks for it before
    /// Claude acts; this is the same rule, enforced again where the action happens).
    private func controlBlocked(_ app: NSRunningApplication) -> MacResult? {
        let store = PermissionStore.load()
        let name = app.localizedName ?? "that app"
        if let id = app.bundleIdentifier, let rule = store.apps[id] {
            return rule == "deny" ? revoked(name) : nil
        }
        if store.value("app") == "deny" {
            return .fail("You've told me to stop controlling applications, so I haven't touched \(name). Say “allow you to control applications” to change that.")
        }
        return nil
    }

    // MARK: - What each action needs exclusively (see TaskManager)

    /// Locks for one action. Typing and key presses take the keyboard focus exclusively, so
    /// nothing can switch apps under them; opening, switching and clicking share it. Each app's
    /// UI is exclusive to the task changing it, shared between tasks only reading it.
    func resources(op: String, args: [String: Any]) -> (exclusive: Set<String>, shared: Set<String>) {
        func key(_ name: Any?) -> String {
            let raw = (name as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if raw.isEmpty { return "app:" + (frontmost?.bundleIdentifier ?? "frontmost") }
            return "app:" + (resolve(raw)?.bundleID ?? running(raw)?.bundleIdentifier ?? Self.squash(raw))
        }
        switch op {
        case "type_text", "press_keys": return ([key(args["app"]), "focus", "keyboard"], [])
        case "click": return ([key(args["app"])], ["focus"])
        case "read_window": return ([], [key(args["app"])])
        case "read_screen":
            let app: [String] = (args["app"] as? String).map { [key($0)] } ?? []
            return ([], Set(["screen"] + app))
        case "open_app", "switch_to_app", "close_app": return ([key(args["name"])], ["focus"])
        case "open_url", "web_search", "open_path":
            let app: [String] = (args["app"] as? String).map { [key($0)] } ?? []
            return (Set(app), ["focus"])
        case "settings": return (["app:com.apple.systempreferences"], ["focus"])
        case "run_in_terminal": return (["app:com.apple.Terminal"], ["focus"])
        case "interface": return (["interface"], ["focus"])
        default: return ([], [])
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - Opening, switching and closing apps

    func openApp(_ name: String) async -> MacResult {
        guard let info = resolve(name) else {
            return .fail("\(Self.displayName(name)) isn't installed on this Mac. I won't download or install anything without your say-so.")
        }
        if denied(info.bundleID) { return revoked(info.name) }
        if PermissionStore.load().value("apps.open") == "deny" {
            return .fail("You've turned off opening apps, so I haven't opened \(info.name). Say “allow opening apps” to change that.")
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).isEmpty
        let started = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: info.url, configuration: configuration)
            let launched = await waitUntil(12) { app.isFinishedLaunching }
            let inFront = await waitUntil(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastApp = info
            log("app: opened \(info.name) in \(ms) ms (finished launching: \(launched), in front: \(inFront))")
            guard launched else { return .fail("\(info.name) started but hasn't finished launching yet.") }
            let state = wasRunning ? "was already running and is now in front" : (inFront ? "is open and in front" : "is open")
            return .ok("\(info.name) \(state). (Verified by macOS in \(ms) ms.)", say: "\(info.name) is open.")
        } catch {
            return .fail("\(info.name) didn't open. macOS returned an error: \(error.localizedDescription)", retryable: true)
        }
    }

    /// "vs code" → "VS Code", "font book" → "Font Book", for apps that aren't installed.
    static func displayName(_ raw: String) -> String {
        let known = ["vs code": "VS Code", "vscode": "VS Code", "whatsapp": "WhatsApp", "iterm": "iTerm", "iterm2": "iTerm",
                     "chatgpt": "ChatGPT", "imovie": "iMovie", "1password": "1Password", "facetime": "FaceTime"]
        let key = normalized(raw)
        return known[key] ?? key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    func closeApp(_ name: String, force: Bool) async -> MacResult {
        guard let app = running(name) else {
            if let info = resolve(name) { return .ok("\(info.name) isn't running.", say: "\(info.name) isn't open.") }
            return .fail("No app called \(Self.displayName(name)) is running.")
        }
        let label = app.localizedName ?? name
        if denied(app.bundleIdentifier) { return revoked(label) }
        if PermissionStore.load().value("apps.close") == "deny" {
            return .fail("You've turned off closing apps, so I haven't closed \(label). Say “allow closing apps” to change that.")
        }
        let protected = ["local.jarvis.voice", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
                         "com.apple.WindowManager", "com.apple.controlcenter"]
        if let id = app.bundleIdentifier, protected.contains(id) { return .fail("\(label) is part of macOS, so I won't quit it.") }
        if app.bundleIdentifier == "com.apple.finder" {
            let result = await runAppleScript("tell application \"Finder\" to close every window")
            if let error = result.error { return .fail("I couldn't close Finder's windows: \(error)") }
            return .ok("Finder's windows are closed (Finder itself always keeps running).", say: "Finder's windows are closed.")
        }
        let started = Date()
        if force { app.forceTerminate() } else { _ = app.terminate() } // terminate() lets the app ask about unsaved work
        let closed = await waitUntil(force ? 4 : 7) { app.isTerminated }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if closed {
            if lastApp?.bundleID == app.bundleIdentifier { lastApp = nil }
            log("app: closed \(label) in \(ms) ms\(force ? " (forced)" : "")")
            return .ok("\(label) is closed. (Verified: the process has exited, \(ms) ms.)", say: "\(label) is closed.")
        }
        if hasDialog(app) {
            return .fail("\(label) is asking whether to save changes. I haven't answered it for you — reply to its dialog, or tell me to force quit.")
        }
        return .fail("\(label) didn't quit. It may be waiting for you on screen.")
    }

    func switchTo(_ name: String) async -> MacResult {
        await openApp(name) // Launch Services brings a running app forward, which a background app cannot do directly.
    }

    func listApps() -> MacResult {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap(\.localizedName)
        var lines = ["Running apps: \(names.joined(separator: ", "))."]
        if let front = frontmost {
            let title = windowTitle(front).map { " — window “\($0)”" } ?? ""
            lines.append("In front: \(front.localizedName ?? "unknown")\(title).")
        }
        if let last = lastApp { lines.append("Jarvis last opened or used: \(last.name).") }
        return .ok(lines.joined(separator: "\n"))
    }

    /// "[Mac: …]" — prepended to requests so "it" and "this app" resolve.
    /// The Mac's facts for Claude ("frontmost app is Safari (window '…'); Jarvis last opened
    /// or used Safari."), sent apart from the user's words. A window title is someone else's
    /// text (a web page, an email subject), so it is made plain: no brackets, quotes or breaks.
    func contextLine() -> String {
        var parts: [String] = []
        if let front = frontmost, let name = front.localizedName {
            let title = windowTitle(front).map { " (window '\(Self.plain($0, 80))')" } ?? ""
            parts.append("frontmost app is \(Self.plain(name, 60))\(title)")
        }
        if let last = lastApp { parts.append("Jarvis last opened or used \(Self.plain(last.name, 60))") }
        return parts.isEmpty ? "" : parts.joined(separator: "; ") + "."
    }

    static func plain(_ text: String, _ limit: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            switch scalar {
            case "[", "]", "“", "”", "\"", "'", "`": return " "
            default: return Character(scalar)
            }
        }
        return String(String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    // MARK: - URLs, folders, Settings, Terminal, the JARVIS interface

    func openURL(_ raw: String, app name: String?) async -> MacResult {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") && !s.hasPrefix("x-apple") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "x-apple.systempreferences"].contains(scheme) else {
            return .fail("I only open web addresses (http or https) and System Settings.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let name, !name.isEmpty {
            guard let info = resolve(name) else { return .fail("\(name) isn't installed on this Mac.") }
            if denied(info.bundleID) { return revoked(info.name) }
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: info.url, configuration: configuration)
                lastApp = info
                return .ok("Opened \(url.host ?? s) in \(info.name).", say: "Done.")
            } catch {
                return .fail("\(info.name) couldn't open that address: \(error.localizedDescription)")
            }
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return .fail("No app on this Mac opens that address.") }
        let browser = (FileManager.default.displayName(atPath: appURL.path) as NSString).deletingPathExtension
        if let id = Bundle(url: appURL)?.bundleIdentifier, denied(id) { return revoked(browser) }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            if let id = Bundle(url: appURL)?.bundleIdentifier { lastApp = InstalledApp(name: browser, url: appURL, bundleID: id) }
            return .ok("Opened \(url.host ?? s) in \(browser).", say: "Done.")
        } catch {
            return .fail("That address didn't open: \(error.localizedDescription)")
        }
    }

    func webSearch(_ query: String, app: String?) async -> MacResult {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let result = await openURL(components.url!.absoluteString, app: app)
        if result.error != nil { return result }
        return .ok("Searching for “\(query)” in \(lastApp?.name ?? "the browser"). The results page is open.", say: "Done.")
    }

    func expandPath(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let named = ["downloads": "Downloads", "desktop": "Desktop", "documents": "Documents", "pictures": "Pictures",
                     "music": "Music", "movies": "Movies", "applications": "Applications", "home": ""]
        let key = t.lowercased().replacingOccurrences(of: " folder", with: "").replacingOccurrences(of: "my ", with: "")
        if let folder = named[key] { return folder.isEmpty ? home : "\(home)/\(folder)" }
        if t.hasPrefix("~") { return (t as NSString).expandingTildeInPath }
        if t.hasPrefix("/") { return t }
        return "\(home)/\(t)"
    }

    func openPath(_ raw: String, app name: String?) async -> MacResult {
        let path = expandPath(raw)
        let shown = path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        guard FileManager.default.fileExists(atPath: path) else { return .fail("There's nothing at \(shown).") }
        let store = PermissionStore.load()
        if store.folders.contains(where: { $0.access == "deny" && (path == $0.path || path.hasPrefix($0.path + "/")) }) {
            return .fail("You've told me not to access \(shown).")
        }
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let name, !name.isEmpty {
            guard let info = resolve(name) else { return .fail("\(name) isn't installed on this Mac.") }
            if denied(info.bundleID) { return revoked(info.name) }
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: info.url, configuration: configuration)
                lastApp = info
                return .ok("Opened \(shown) in \(info.name).", say: "Done.")
            } catch {
                return .fail("\(info.name) couldn't open \(shown): \(error.localizedDescription)")
            }
        }
        guard NSWorkspace.shared.open(url) else { return .fail("\(shown) didn't open.") }
        if let finder = resolve("finder") { lastApp = finder }
        return .ok("Opened \(shown) in Finder.", say: "Done.")
    }

    private static let panes: [String: String] = [
        "privacy": "com.apple.settings.PrivacySecurity.extension",
        "privacy security": "com.apple.settings.PrivacySecurity.extension",
        "security": "com.apple.settings.PrivacySecurity.extension",
        "accessibility": "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        "microphone": "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
        "camera": "com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
        "screen recording": "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        "automation": "com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
        "files": "com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
        "full disk": "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "bluetooth": "com.apple.BluetoothSettings", "sound": "com.apple.Sound-Settings.extension",
        "wifi": "com.apple.wifi-settings-extension", "wi fi": "com.apple.wifi-settings-extension",
        "network": "com.apple.Network-Settings.extension", "displays": "com.apple.Displays-Settings.extension",
        "display": "com.apple.Displays-Settings.extension", "notifications": "com.apple.Notifications-Settings.extension",
        "general": "com.apple.systempreferences.GeneralSettings", "login items": "com.apple.LoginItems-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension", "keyboard": "com.apple.Keyboard-Settings.extension",
        "appearance": "com.apple.Appearance-Settings.extension", "focus": "com.apple.Focus-Settings.extension",
        "software update": "com.apple.Software-Update-Settings.extension", "users": "com.apple.Users-Groups-Settings.extension",
    ]

    func settings(_ pane: String) async -> MacResult {
        let key = normalized(pane.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "&", with: " "))
            .replacingOccurrences(of: " and ", with: " ").replacingOccurrences(of: "settings", with: "")
            .trimmingCharacters(in: .whitespaces)
        let id = Self.panes[key] ?? Self.panes.first(where: { key.contains($0.key) })?.value
        let url = URL(string: "x-apple.systempreferences:\(id ?? "")")!
        guard NSWorkspace.shared.open(url) else { return .fail("System Settings didn't open.") }
        if let settingsApp = resolve("system settings") { lastApp = settingsApp }
        let shown = id == nil ? "System Settings is open." : "System Settings is open at \(pane)."
        return .ok(shown + (id == nil ? " I don't know a pane called \(pane), so it's on the main page." : ""), say: shown)
    }

    func runInTerminal(_ command: String, cwd: String?) async -> MacResult {
        if denied("com.apple.Terminal") { return revoked("Terminal") }
        var line = command
        if let cwd, !cwd.isEmpty { line = "cd \(Self.shellQuote(expandPath(cwd))) && \(command)" }
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(Self.appleScriptEscape(line))\"\nend tell"
        let result = await runAppleScript(script)
        if let error = result.error {
            if error.contains("-1743") {
                return .fail("macOS blocked me from controlling Terminal. Allow Jarvis Voice under System Settings, Privacy & Security, Automation, Terminal.")
            }
            return .fail("Terminal didn't run it: \(error)")
        }
        if let terminal = resolve("terminal") { lastApp = terminal }
        return .ok("Running “\(command)” in a Terminal window. Use read_window with app Terminal to see the output.", say: "It's running in Terminal.")
    }

    func interface(_ action: String) async -> MacResult {
        guard let url = URL(string: interfaceURL) else { return .fail("The interface address is not set.") }
        if action == "open" {
            guard NSWorkspace.shared.open(url) else { return .fail("The browser didn't open.") }
            return .ok("The JARVIS interface is open in your browser.", say: "My interface is open. I'm still listening here, too.")
        }
        let prefix = interfaceURL
        var closedAny = false
        for (bundle, app) in [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari")]
            where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let result = await runAppleScript("tell application \"\(app)\" to close (every tab of every window whose URL starts with \"\(prefix)\")")
            if result.error == nil { closedAny = true } else { log("interface: closing in \(app) failed: \(result.error!)") }
        }
        return closedAny
            ? .ok("The JARVIS interface tab is closed.", say: "My interface is closed. I'm still here by voice.")
            : .ok("No browser had the interface open that I could close.", say: "My interface wasn't open in Chrome or Safari.")
    }

    // MARK: - Reading and acting inside apps (Accessibility)

    func readWindow(_ name: String?) -> MacResult {
        guard AXIsProcessTrusted() else { return .fail(Self.accessibilityBlocked) }
        guard let app = named(name) else { return .fail(Self.unnamed(name)) }
        if let blocked = controlBlocked(app) { return blocked }
        let started = Date()
        let root = AX.application(app)
        guard let window = AX.window(root) else { return .fail("\(app.localizedName ?? "That app") has no window open.") }
        let title = AX.string(window, kAXTitleAttribute) ?? ""
        let text = AX.text(window, limit: 14_000)
        if let info = info(for: app) { lastApp = info }
        log("accessibility: read \(app.localizedName ?? "app") window, \(text.count) chars in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return .ok("App: \(app.localizedName ?? "unknown") — window “\(title)”\n\(text.isEmpty ? "(no readable text in this window)" : text)")
    }

    func click(_ label: String, app name: String?, role: String?) async -> MacResult {
        guard AXIsProcessTrusted() else { return .fail(Self.accessibilityBlocked) }
        guard let app = named(name) else { return .fail(Self.unnamed(name)) }
        if let blocked = controlBlocked(app) { return blocked }
        let started = Date()
        let root = AX.application(app)
        let scope = [AX.window(root), AX.element(root, kAXMenuBarAttribute)].compactMap { $0 }
        guard let match = AX.find(label, role: role, in: scope) else {
            let options = AX.pressableLabels(in: scope, limit: 25)
            return .fail("I couldn't find “\(label)” in \(app.localizedName ?? "that app"). Things I can press there: \(options.joined(separator: ", ")).")
        }
        log("accessibility: found the element to press in \(app.localizedName ?? "app") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        // Never press something more consequential than what was asked for.
        if AX.consequential(match.label) && !AX.consequential(label) {
            return .fail("The closest match is “\(match.label)”, which is not what was asked for, so I didn't press it.")
        }
        guard AX.press(match.element) else { return .fail("“\(match.label)” couldn't be pressed.") }
        if let info = info(for: app) { lastApp = info }
        return .ok("Pressed “\(match.label)” in \(app.localizedName ?? "the app").", say: "Done.")
    }

    func typeText(_ text: String, field: String?, app name: String?, submit: Bool) async -> MacResult {
        guard AXIsProcessTrusted() else { return .fail(Self.accessibilityBlocked) }
        guard let app = named(name) else { return .fail(Self.unnamed(name)) }
        if let blocked = controlBlocked(app) { return blocked }
        let label = app.localizedName ?? "the app"
        await bringToFront(app)
        let root = AX.application(app)
        var element: AXUIElement?
        if let field, !field.isEmpty {
            guard let found = AX.findField(field, in: [AX.window(root)].compactMap { $0 }) else {
                return .fail("There's no field called “\(field)” in \(label).")
            }
            element = found
            AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 120_000_000)
        } else {
            element = AX.element(root, kAXFocusedUIElementAttribute)
        }
        if let element, AX.isSecure(element) { return .fail("That's a password field. I don't type into those.") }
        // Check again right before typing: another app may have come forward meanwhile.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return .fail("\(label) isn't in front any more (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app") is), so I didn't type anything.")
        }
        if let element, let focused = AX.element(root, kAXFocusedUIElementAttribute), !CFEqual(focused, element) {
            return .fail("The text field in \(label) lost focus before I could type, so I didn't type anything.")
        }
        let before = element.flatMap { AX.string($0, kAXValueAttribute) } ?? ""
        let typed = await Keyboard.typeInBackground(text) { [weak self] in
            // Stop at once if focus moves to another app mid-way.
            MainActor.assumeIsolated { self == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier }
        }
        guard typed == text.utf16.count else {
            return .fail("I stopped typing after \(typed) of \(text.utf16.count) characters because \(label) lost focus.")
        }
        // Verify the text is really in the field, where the app lets Accessibility see it.
        try? await Task.sleep(nanoseconds: 120_000_000)
        let after = element.flatMap { AX.string($0, kAXValueAttribute) }
        let verified = after.map { $0 != before && $0.contains(text.suffix(min(text.count, 40))) }
        if submit {
            try? await Task.sleep(nanoseconds: 150_000_000)
            Keyboard.press(UInt16(kVK_Return), flags: [])
        }
        if let info = info(for: app) { lastApp = info }
        let check = verified == true ? " The text is in the field (verified)." : verified == false
            ? " I couldn't see the text in the field afterwards — read the window to check." : ""
        return .ok("Typed “\(text)”\(submit ? " and pressed Return" : "") in \(label).\(check)", say: "Done.")
    }

    func pressKeys(_ keys: String, app name: String?) async -> MacResult {
        guard AXIsProcessTrusted() else { return .fail(Self.accessibilityBlocked) }
        guard let app = named(name) else { return .fail(Self.unnamed(name)) }
        if let blocked = controlBlocked(app) { return blocked }
        guard let combo = Keyboard.parse(keys) else { return .fail("I don't know the key combination “\(keys)”.") }
        await bringToFront(app)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return .fail("\(app.localizedName ?? "That app") isn't in front, so I didn't press \(keys).")
        }
        Keyboard.press(combo.0, flags: combo.1)
        if let info = info(for: app) { lastApp = info }
        return .ok("Pressed \(keys) in \(app.localizedName ?? "the app").", say: "Done.")
    }

    private func bringToFront(_ app: NSRunningApplication) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        _ = await waitUntil(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
    }

    private func hasDialog(_ app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return true } // cannot look; assume it is asking
        let root = AX.application(app)
        for window in AX.elements(root, kAXWindowsAttribute) {
            if let sub = AX.string(window, kAXSubroleAttribute), ["AXDialog", "AXSystemDialog"].contains(sub) { return true }
            if AX.elements(window, kAXChildrenAttribute).contains(where: { AX.string($0, kAXRoleAttribute) == "AXSheet" }) { return true }
        }
        return false
    }

    func windowTitle(_ app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted(), controlBlocked(app) == nil else { return nil }
        let root = AX.application(app, enableElectron: false)
        guard let window = AX.window(root), let title = AX.string(window, kAXTitleAttribute), !title.isEmpty else { return nil }
        return title
    }

    // MARK: - The screen (ScreenCaptureKit)

    func readScreen(target: String?, app name: String?) async -> MacResult {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .fail(Self.screenBlocked)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            let filter: SCContentFilter
            var described = "the main display"
            if target == "window" || (name?.isEmpty == false) {
                guard let app = self.named(name) else { return .fail(Self.unnamed(name)) }
                if denied(app.bundleIdentifier) { return revoked(app.localizedName ?? "that app") }
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 80
                }
                guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    return .fail("\(app.localizedName ?? "That app") has no window on screen.")
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                configuration.width = Int(window.frame.width * 2)
                configuration.height = Int(window.frame.height * 2)
                described = "\(app.localizedName ?? "the app")'s window “\(window.title ?? "")”"
                if let info = info(for: app) { lastApp = info }
            } else {
                let main = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
                    return .fail("There's no display to capture.")
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                configuration.width = display.width * 2
                configuration.height = display.height * 2
            }
            let started = Date()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let encoded = jpegBase64(image) else { return .fail("The screenshot could not be encoded.") }
            log("screen: captured \(described) (\(image.width)x\(image.height)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms — not saved")
            return MacResult(text: "Screenshot of \(described):", image: encoded)
        } catch {
            return .fail("The screen could not be captured: \(error.localizedDescription)")
        }
    }

    // MARK: - Apple Events

    func runAppleScript(_ source: String) async -> (output: String?, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(returning: (nil, "\(message) (\(number))"))
                } else {
                    continuation.resume(returning: (result?.stringValue, nil))
                }
            }
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func application(_ app: NSRunningApplication, enableElectron: Bool = true) -> AXUIElement {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        // Electron apps (VS Code, Slack…) only build their accessibility tree when asked.
        if enableElectron, let url = app.bundleURL,
           FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return root
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let v = value(element, attribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    static func window(_ root: AXUIElement) -> AXUIElement? {
        element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) ?? elements(root, kAXWindowsAttribute).first
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == "AXSecureTextField" || string(element, kAXSubroleAttribute) == "AXSecureTextField"
    }

    private struct Info {
        let role: String, subrole: String, title: String?, desc: String?, value: String?, placeholder: String?
        let children: [AXUIElement]
    }

    private static func info(_ element: AXUIElement) -> Info {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                     kAXPlaceholderValueAttribute, kAXChildrenAttribute] as [CFString]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == names.count else {
            return Info(role: string(element, kAXRoleAttribute) ?? "", subrole: "", title: nil, desc: nil, value: nil, placeholder: nil,
                        children: elements(element, kAXChildrenAttribute))
        }
        func text(_ i: Int) -> String? {
            if let s = array[i] as? String { return s.isEmpty ? nil : s }
            if let n = array[i] as? NSNumber, CFGetTypeID(n) != AXValueGetTypeID() { return n.stringValue }
            return nil
        }
        return Info(role: text(0) ?? "", subrole: text(1) ?? "", title: text(2), desc: text(3), value: text(4),
                    placeholder: text(5), children: (array[6] as? [AXUIElement]) ?? [])
    }

    /// The readable text of a window, in reading order, as compact lines.
    static func text(_ root: AXUIElement, limit: Int) -> String {
        var lines: [String] = []
        var chars = 0, visited = 0
        var last = ""
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while case let (element, depth)? = stack.popLast(), visited < 6000, chars < limit {
            visited += 1
            let i = info(element)
            if i.role == "AXSecureTextField" || i.subrole == "AXSecureTextField" { lines.append("[password field]"); continue }
            var line: String?
            switch i.role {
            case "AXStaticText": line = i.value ?? i.title
            case "AXButton", "AXMenuButton", "AXPopUpButton": line = (i.title ?? i.desc).map { "[button] \($0)" }
            case "AXLink": line = (i.title ?? i.desc ?? i.value).map { "[link] \($0)" }
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
                line = "[\(i.title ?? i.desc ?? i.placeholder ?? "text field")] \(i.value ?? "")"
            case "AXHeading": line = (i.title ?? i.value ?? i.desc).map { "## \($0)" }
            case "AXCheckBox", "AXRadioButton", "AXSwitch":
                line = (i.title ?? i.desc).map { "[option] \($0)\(i.value == "1" ? " (on)" : i.value == "0" ? " (off)" : "")" }
            case "AXImage": line = i.desc.map { "[image] \($0)" }
            case "AXSheet", "AXDialog": line = "--- dialog ---"
            case "AXRow", "AXCell", "AXGroup", "AXScrollArea", "AXWebArea", "AXList", "AXOutline", "AXTable", "AXSplitGroup",
                 "AXToolbar", "AXLayoutArea", "AXUnknown", "AXWindow", "AXTabGroup", "AXSplitter", "AXScrollBar", "AXValueIndicator":
                line = nil
            default: line = i.title
            }
            if let l = line?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty, l != last {
                lines.append(l); chars += l.count + 1; last = l
            }
            if depth < 45 { for child in i.children.reversed() { stack.append((child, depth + 1)) } }
        }
        return lines.joined(separator: "\n")
    }

    private static let pressable: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
                                                 "AXPopUpButton", "AXMenuButton", "AXTab", "AXCell", "AXRow", "AXStaticText", "AXImage", "AXDisclosureTriangle"]

    /// The element whose visible label best matches `label`.
    static func find(_ label: String, role: String?, in roots: [AXUIElement]) -> (element: AXUIElement, label: String)? {
        let want = normalized(label)
        var exact: (AXUIElement, String)?
        var partial: (AXUIElement, String)?
        var visited = 0
        var stack = roots.map { ($0, 0) }
        while case let (element, depth)? = stack.popLast(), visited < 6000 {
            visited += 1
            let i = info(element)
            let names = [i.title, i.desc, i.value].compactMap { $0 }.filter { $0.count < 120 }
            if pressable.contains(i.role), role.map({ i.role.lowercased().contains(normalized($0).replacingOccurrences(of: " ", with: "")) }) ?? true {
                for name in names {
                    let n = normalized(name)
                    if n == want { exact = exact ?? (element, name) }
                    else if partial == nil, !want.isEmpty, n.contains(want) || (want.contains(n) && n.count >= 4) { partial = (element, name) }
                }
            }
            if exact != nil { break }
            if depth < 45 { for child in i.children.reversed() { stack.append((child, depth + 1)) } }
        }
        return exact ?? partial
    }

    static func findField(_ label: String, in roots: [AXUIElement]) -> AXUIElement? {
        let want = normalized(label)
        var stack = roots.map { ($0, 0) }
        var visited = 0
        while case let (element, depth)? = stack.popLast(), visited < 6000 {
            visited += 1
            let i = info(element)
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(i.role) {
                let names = [i.title, i.desc, i.placeholder].compactMap { $0 }.map(normalized)
                if names.contains(where: { $0 == want || $0.contains(want) }) { return element }
            }
            if depth < 45 { for child in i.children.reversed() { stack.append((child, depth + 1)) } }
        }
        return nil
    }

    static func pressableLabels(in roots: [AXUIElement], limit: Int) -> [String] {
        var out: [String] = []
        var stack = roots.map { ($0, 0) }
        var visited = 0
        while case let (element, depth)? = stack.popLast(), visited < 3000, out.count < limit {
            visited += 1
            let i = info(element)
            if ["AXButton", "AXLink", "AXMenuBarItem", "AXTab", "AXRadioButton", "AXCheckBox"].contains(i.role),
               let name = i.title ?? i.desc, !name.isEmpty, !out.contains(name) { out.append(name) }
            if depth < 30 { for child in i.children.reversed() { stack.append((child, depth + 1)) } }
        }
        return out
    }

    static func press(_ element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        // Rows and cells select rather than press.
        if AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return true }
        if let parent = AX.element(element, kAXParentAttribute) {
            return AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success
                || AXUIElementSetAttributeValue(parent, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        }
        return false
    }

    /// Labels whose press has consequences: never pressed as a "closest match".
    static func consequential(_ label: String) -> Bool {
        let pattern = "\\b(send|post|publish|delete|remove|erase|trash|empty|buy|purchase|order|pay|checkout|subscribe|install|uninstall|allow|grant|share|upload|submit|confirm|sign out|log out|transfer|reset)\\b"
        return label.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Keyboard (CGEvent; needs Accessibility)

enum Keyboard {
    nonisolated(unsafe) private static let source = CGEventSource(stateID: .hidSystemState)

    static func type(_ text: String) {
        for unit in text.utf16 { post(unit) }
    }

    private static func post(_ unit: UInt16) {
        var u = unit
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            event.post(tap: .cghidEventTap)
        }
        usleep(4000)
    }

    /// Types off the main thread (so Jarvis keeps listening during a long message), checking
    /// every few characters that it should carry on. Returns how many characters were typed.
    @MainActor
    static func typeInBackground(_ text: String, stop: @escaping @MainActor () -> Bool) async -> Int {
        let units = Array(text.utf16)
        let check: @Sendable () -> Bool = { DispatchQueue.main.sync { MainActor.assumeIsolated { stop() } } }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var typed = 0
                for (i, unit) in units.enumerated() {
                    if i % 6 == 0, check() { break }
                    post(unit)
                    typed += 1
                }
                continuation.resume(returning: typed)
            }
        }
    }

    static func press(_ code: UInt16, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }

    private static let codes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        "return": kVK_Return, "enter": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape, "tab": kVK_Tab, "space": kVK_Space,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "up": kVK_UpArrow,
        "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    static func parse(_ combo: String) -> (UInt16, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: String?
        for part in combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+") {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = String(part)
            }
        }
        guard let key, let code = codes[key] else { return nil }
        return (UInt16(code), flags)
    }
}
