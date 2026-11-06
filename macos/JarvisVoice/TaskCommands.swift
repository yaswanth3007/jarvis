import Foundation

/// Spoken commands about tasks, and a few questions answered on the Mac itself.
enum TaskCommand: Equatable {
    case status                 // "what are you doing?"
    case cancel(Int)            // "stop task 2"
    case cancelNamed(String)    // "stop the Chrome task", "stop opening Spotify"
    case cancelLatest           // "stop that"
    case cancelAll              // "cancel all tasks"
    case stopEverything         // "stop everything"
    case resume(Int)            // "continue task 1"
    case time                   // "what time is it?"
    case date                   // "what's the date?"

    private static func m(_ pattern: String, _ t: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let r = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        return (0..<r.numberOfRanges).map { i in Range(r.range(at: i), in: t).map { String(t[$0]) } ?? "" }
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "won": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "ate": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
    ]

    static func number(_ word: String) -> Int? { Int(word) ?? numberWords[word] }

    /// `text` is the request without the wake word.
    static func parse(_ text: String) -> TaskCommand? {
        var t = normalized(text)
        for p in ["please ", "can you ", "could you ", "would you ", "ok ", "okay ", "now ", "and "] where t.hasPrefix(p) { t.removeFirst(p.count) }
        for s in [" please", " now", " right now", " for me", " sir"] where t.hasSuffix(s) { t.removeLast(s.count) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // The time and the date.
        if m("(what time is it|what's the time|what is the time|tell me the time|time|the time|current time|what's the current time|what is the current time|do you know what time it is|do you have the time|have you got the time)", t) != nil {
            return .time
        }
        if m("(what's the date|what is the date|what's today's date|what is today's date|what's the date today|what is the date today|what day is it|what day is it today|what's today|what is today|which day is it|today's date|the date)", t) != nil {
            return .date
        }

        // What is going on.
        if m("what are you (doing|working on|up to|busy with)", t) != nil
            || m("(what's|what is|what are|anything|is anything|are any tasks?) (running|going on|happening|in progress)", t) != nil
            || m("(what|which) tasks? (are|is) (running|active|going|going on|in progress|open)", t) != nil
            || m("(list|show|tell me)( me)?( the| my| all| your| all the| all your)? (tasks|active tasks|running tasks|current tasks)", t) != nil
            || m("(task|tasks) (status|list|update)", t) != nil
            || m("(status|state) of (the |my |your |all )?tasks", t) != nil
            || m("(how are|how's|how is) (the |my |your )?(tasks?|task) (going|doing)", t) != nil
            || m("are you (doing|working on) anything", t) != nil
            || m("(any|are there any) tasks( running)?", t) != nil {
            return .status
        }

        let stop = "(stop|cancel|kill|end|abort|halt|terminate|drop|scrap)"
        // "stop task 2", "cancel task number two", "stop the second task". Followed by "task" and a
        // number this can mean nothing else, so the recogniser's usual mishearings of "stop"
        // ("stock task 10", "stopped task two") count too.
        if let g = m("(stop|stops|stopped|stock|top|cancel|cancelled|canceled|kill|end|abort|halt|terminate|drop|scrap) (the )?tasks?( number)? ([a-z0-9]+)", t),
           let n = number(g[4]) {
            return .cancel(n)
        }
        if let g = m("\(stop) (the )?(first|second|third|fourth|fifth) task", t), let n = number(g[3]) { return .cancel(n) }
        // Everything.
        if m("\(stop) (everything|it all|all of it|all of that)", t) != nil || t == "stop all" { return .stopEverything }
        if m("\(stop) (all|all the|all of the|every|all my|all your|all of my|all of your)( running| active| background| current)? tasks", t) != nil
            || m("\(stop) all (running |active |background )?tasks", t) != nil
            || m("clear (all )?(the |my |your )?tasks", t) != nil {
            return .cancelAll
        }
        // "stop that", "cancel it", "stop that task".
        if m("\(stop) (that|it|this|that one|this one|that task|this task|the last task|the last one|what you're doing|what you are doing)", t) != nil
            || t == "never mind that" || t == "forget that" {
            return .cancelLatest
        }
        // "stop the Chrome task", "cancel the weather one".
        if let g = m("\(stop) (the |my |your )?(.+?) (task|one|job)", t) { return .cancelNamed(g[3]) }
        // "stop opening Spotify", "cancel searching for flights".
        if let g = m("\(stop) ((opening|launching|closing|quitting|searching|looking|loading|reading|typing|running) .+)", t) {
            return .cancelNamed(g[2])
        }

        // "continue task 1", "go back to task two".
        if let g = m("(continue|resume|go back to|back to|carry on with|return to|switch to|pick up|finish) (the )?task( number)? ([a-z0-9]+)", t),
           let n = number(g[4]) {
            return .resume(n)
        }
        return nil
    }
}

/// Several apps in one request: "open Chess, Dictionary and Font Book", "close Chess
/// and Dictionary", "open Chess then Dictionary". Each stage is opened together; the
/// stages one after another.
struct AppPlan {
    enum Verb { case open, close }
    let verb: Verb
    let stages: [[String]]

    var count: Int { stages.reduce(0) { $0 + $1.count } }

    /// Apps people name that may not be installed: "open Spotify" should say it isn't
    /// installed rather than become a web search.
    static let knownApps: Set<String> = [
        "spotify", "whatsapp", "vs code", "vscode", "visual studio code", "code", "slack", "zoom", "teams", "microsoft teams",
        "discord", "telegram", "signal", "notion", "figma", "postman", "docker", "word", "excel", "powerpoint", "outlook",
        "onenote", "xcode", "iterm", "iterm2", "warp", "firefox", "brave", "edge", "microsoft edge", "arc", "obsidian",
        "1password", "steam", "vlc", "skype", "webex", "sublime text", "intellij", "pycharm", "android studio", "cursor",
        "chatgpt", "messenger", "pages", "numbers", "keynote", "imovie", "garageband", "final cut pro", "logic pro",
        "safari", "chrome", "google chrome", "finder", "terminal", "notes", "mail", "messages", "music", "photos",
        "calendar", "reminders", "maps", "facetime", "system settings", "settings", "calculator", "preview", "textedit",
        "chess", "dictionary", "font book", "stickies", "activity monitor", "app store", "podcasts", "news", "stocks",
        "weather", "clock", "freeform", "shortcuts", "contacts", "books", "home", "tv", "quicktime player", "automator",
    ]

    private static let verbs: Set<String> = [
        "search", "go", "type", "navigate", "play", "find", "look", "read", "send", "message", "write", "tell", "show",
        "run", "click", "press", "open", "close", "quit", "launch", "start", "then", "while", "to", "for", "with", "in",
        "on", "at", "it", "that", "this", "my", "about", "how", "what", "why", "make", "create", "delete", "explain",
    ]

    /// `request` is the user's own words (punctuation kept). `isApp` says whether a name
    /// is an installed app; `isRunning` whether it is running (for close).
    static func parse(_ request: String, isApp: (String) -> Bool) -> AppPlan? {
        var t = request.lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for p in ["please ", "can you ", "could you ", "would you ", "jarvis, ", "jarvis "] where t.hasPrefix(p) { t.removeFirst(p.count) }
        guard let verbMatch = t.range(of: "^(open|launch|start|fire up|close|quit|exit)( up)? ", options: .regularExpression) else { return nil }
        let verbWord = String(t[verbMatch]).trimmingCharacters(in: .whitespaces)
        let verb: Verb = verbWord.hasPrefix("close") || verbWord.hasPrefix("quit") || verbWord.hasPrefix("exit") ? .close : .open
        var rest = String(t[verbMatch.upperBound...])
        for s in [" please", " for me", " now", " apps", " applications"] where rest.hasSuffix(s) { rest.removeLast(s.count) }

        let stageTexts = rest.components(separatedBy: try! NSRegularExpression(pattern: "\\s*,?\\s*\\b(and then|then|after that|afterwards|followed by)\\b\\s*"))
        var stages: [[String]] = []
        for stageText in stageTexts where !stageText.trimmingCharacters(in: .whitespaces).isEmpty {
            var items: [String] = []
            for raw in stageText.components(separatedBy: try! NSRegularExpression(pattern: "\\s*(,|&|\\band\\b|\\bplus\\b|\\balso\\b)\\s*")) {
                var item = normalized(raw)
                for p in ["the ", "my ", "open ", "launch ", "close ", "quit "] where item.hasPrefix(p) { item.removeFirst(p.count) }
                for s in [" app", " application"] where item.hasSuffix(s) { item.removeLast(s.count) }
                guard !item.isEmpty else { continue }
                if isApp(item) || knownApps.contains(item) {
                    items.append(item)
                } else if let split = segment(item, isApp: isApp) {
                    items.append(contentsOf: split) // "chess dictionary" heard without its comma
                } else {
                    return nil // something that isn't an app: Claude's to work out
                }
            }
            if !items.isEmpty { stages.append(items) }
        }
        let plan = AppPlan(verb: verb, stages: stages)
        return plan.count >= 2 ? plan : nil
    }

    /// Splits "chess dictionary font book" into app names, or nil if any word is left over.
    private static func segment(_ text: String, isApp: (String) -> Bool) -> [String]? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 9, !words.contains(where: { verbs.contains($0) }) else { return nil }
        // Fewest names covering every word, longest names first.
        var best: [Int: [String]] = [0: []]
        for end in 1...words.count {
            for start in stride(from: end - 1, through: max(0, end - 4), by: -1) {
                guard let before = best[start] else { continue }
                let name = words[start..<end].joined(separator: " ")
                guard isApp(name) || knownApps.contains(name) else { continue }
                if best[end] == nil || best[end]!.count > before.count + 1 { best[end] = before + [name] }
            }
        }
        guard let names = best[words.count], names.count >= 2 else { return nil }
        return names
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var last = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let r = Range(match.range, in: self) else { continue }
            parts.append(String(self[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(self[last...]))
        return parts
    }
}
