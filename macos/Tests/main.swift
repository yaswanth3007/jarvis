// Unit tests for the orchestrator and the voice-command parsers, compiled together with
// the real Tasks.swift, TaskCommands.swift, Permissions.swift and Support.swift.
import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1 } else { failed += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
}

// MARK: Parsers — the shared vectors in tests/vectors/commands.json (also run against core/commands.mjs)

let vectorsPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/vectors/commands.json"
guard let vectorData = FileManager.default.contents(atPath: vectorsPath),
      let vectors = try? JSONSerialization.jsonObject(with: vectorData) as? [String: Any] else {
    print("cannot read \(vectorsPath)")
    exit(2)
}

func describe(_ c: TaskCommand?) -> [String: AnyHashable]? {
    guard let c else { return nil }
    switch c {
    case .status: return ["type": "status"]
    case .cancel(let n): return ["type": "cancel", "n": n]
    case .cancelNamed(let s): return ["type": "cancelNamed", "name": s]
    case .cancelLatest: return ["type": "cancelLatest"]
    case .cancelAll: return ["type": "cancelAll"]
    case .stopEverything: return ["type": "stopEverything"]
    case .resume(let n): return ["type": "resume", "n": n]
    case .time: return ["type": "time"]
    case .date: return ["type": "date"]
    }
}
func hashable(_ v: Any?) -> [String: AnyHashable]? {
    guard let d = v as? [String: Any] else { return nil }
    var out: [String: AnyHashable] = [:]
    for (k, x) in d {
        // JSON numbers arrive as NSNumber, and NSNumber(1) also casts to Bool: tell them apart properly.
        if let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { out[k] = n.intValue } else if let s = x as? String { out[k] = s }
    }
    return out
}
for case let pair as [Any] in vectors["taskCommands"] as? [Any] ?? [] {
    let text = pair[0] as! String
    let want = hashable(pair[1])
    let got = describe(TaskCommand.parse(text))
    check("command “\(text)”", got == want, "\(String(describing: got))")
}

let installed = Set((vectors["installedApps"] as? [String]) ?? [])
let isApp: (String) -> Bool = { installed.contains($0) }
for case let row as [Any] in vectors["appPlans"] as? [Any] ?? [] {
    let text = row[0] as! String
    let verb: AppPlan.Verb? = (row[1] as? String).map { $0 == "open" ? .open : .close }
    let stages = (row[2] as? [[String]]) ?? []
    let plan = AppPlan.parse(text, isApp: isApp)
    let ok = verb == nil ? plan == nil : (plan?.verb == verb && plan?.stages == stages)
    check("plan “\(text)”", ok, plan.map { "\($0.verb) \($0.stages)" } ?? "none")
}

let apps = (vectors["permissionApps"] as? [String: [String]]) ?? [:]
let resolve: (String) -> (name: String, bundleID: String)? = { n in apps[n].map { ($0[0], $0[1]) } }
func permission(_ text: String) -> String {
    guard let c = PermissionCommand.parse(text, resolveApp: resolve) else { return "none" }
    switch c {
    case .change(let capability, let target, let allow, _): return "\(allow ? "allow" : "deny") \(capability)\(target.isEmpty ? "" : " \(target)")"
    case .list: return "list"
    case .listApps: return "listApps"
    case .can(let w): return "can \(w)"
    case .reset: return "reset"
    }
}
for case let pair as [String] in vectors["permissionCommands"] as? [Any] ?? [] {
    let got = permission(pair[0])
    check("permission “\(pair[0])”", got == pair[1], got)
}
for case let pair as [Any] in vectors["permissionAnswers"] as? [Any] ?? [] {
    let text = pair[0] as! String
    let want = pair[1] as? String
    let got = PermissionAnswer.parse(text)?.rawValue
    check("answer “\(text)”", got == want, String(describing: got))
}

// MARK: Orchestrator

@MainActor
func orchestrator() async {
    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    // Independent tasks overlap; the total is close to the longest, not the sum.
    do {
        let m = TaskManager()
        let t0 = Date()
        let jobs = (0..<3).map { i in m.run("job \(i)", kind: "app", exclusive: ["app:\(i)"], shared: ["focus"]) { _ in await sleep(0.3); return .done("ok") } }
        _ = await m.waitAll(jobs)
        let ms = Date().timeIntervalSince(t0) * 1000
        check("parallel: three independent 300 ms tasks finish together", ms < 550, "\(Int(ms)) ms")
    }
    // Same exclusive resource: one after another.
    do {
        let m = TaskManager()
        let t0 = Date()
        let jobs = (0..<3).map { i in m.run("type \(i)", kind: "mac", exclusive: ["app:x", "keyboard"]) { _ in await sleep(0.2); return .done("ok") } }
        _ = await m.waitAll(jobs)
        let ms = Date().timeIntervalSince(t0) * 1000
        let ordered = zip(jobs, jobs.dropFirst()).allSatisfy { a, b in (a.finished ?? .distantFuture) <= (b.started ?? .distantPast) }
        check("serialised: tasks sharing an exclusive resource never overlap", ordered && ms >= 580, "\(Int(ms)) ms")
    }
    // Typing holds focus exclusively: an app open (shared focus) waits for it, other opens don't wait for each other.
    do {
        let m = TaskManager()
        let typing = m.run("typing", kind: "mac", exclusive: ["app:a", "focus", "keyboard"]) { _ in await sleep(0.3); return .done("ok") }
        await sleep(0.02)
        let open1 = m.run("open b", kind: "app", exclusive: ["app:b"], shared: ["focus"]) { _ in await sleep(0.1); return .done("ok") }
        let open2 = m.run("open c", kind: "app", exclusive: ["app:c"], shared: ["focus"]) { _ in await sleep(0.1); return .done("ok") }
        _ = await m.waitAll([typing, open1, open2])
        let waited = (open1.started ?? .distantPast) >= (typing.finished ?? .distantFuture)
        let together = abs((open1.started ?? .distantPast).timeIntervalSince(open2.started ?? .distantFuture)) < 0.05
        check("focus: opening an app waits while another task is typing", waited)
        check("focus: two opens share focus and run together", together)
    }
    // Dependencies: after, and skipped when a required step failed.
    do {
        let m = TaskManager()
        let a = m.run("open chrome", kind: "app") { _ in await sleep(0.15); return .done("ok") }
        let b = m.run("search", kind: "mac", dependsOn: [a.id], requireSuccess: true) { _ in .done("ok") }
        _ = await m.waitAll([a, b])
        check("dependency: the search starts after Chrome has opened", (b.started ?? .distantPast) >= (a.finished ?? .distantFuture))
        let c = m.run("open missing", kind: "app") { _ in .failed("isn't installed") }
        let d = m.run("search in it", kind: "mac", dependsOn: [c.id], requireSuccess: true) { _ in .done("ok") }
        let e = m.run("unrelated", kind: "app") { _ in .done("ok") }
        _ = await m.waitAll([c, d, e])
        check("dependency: a step after a failed one is skipped", d.status == .cancelled && d.started == nil, d.message)
        check("failure isolation: an unrelated task still succeeds", e.status == .done)
    }
    // Cancellation: only the task asked for; its cleanup runs; a waiting task never starts.
    do {
        let m = TaskManager()
        var cleaned = false
        let long = m.run("long", kind: "claude") { _ in await sleep(2); return .done("ok") }
        long.onCancel = { cleaned = true }
        let other = m.run("other", kind: "claude") { _ in await sleep(0.3); return .done("ok") }
        let blocked = m.run("blocked", kind: "mac", exclusive: ["x"]) { _ in await sleep(1); return .done("ok") }
        let waiting = m.run("waiting", kind: "mac", exclusive: ["x"]) { _ in .done("ran") }
        await sleep(0.1)
        m.cancel(long)
        m.cancel(waiting)
        _ = await m.waitAll([other])
        check("cancel: the cancelled task is cancelled and cleaned up", long.status == .cancelled && cleaned)
        check("cancel: the other task carries on", other.status == .done)
        check("cancel: a task waiting for a resource never starts", waiting.status == .cancelled && waiting.started == nil)
        m.cancel(blocked)
    }
    // Timeout and retry.
    do {
        let m = TaskManager()
        var stopped = false
        let slow = m.run("slow", kind: "mac", timeout: 0.3) { _ in await sleep(5); return .done("late") }
        slow.onCancel = { stopped = true }
        var attempts = 0
        let flaky = m.run("flaky launch", kind: "app", retries: 1) { _ in
            attempts += 1
            return attempts == 1 ? .failed("transient", retry: true) : .done("opened")
        }
        _ = await m.waitAll([slow, flaky])
        check("timeout: a task that runs too long fails and is stopped", slow.status == .failed && stopped && slow.message.contains("timed out"), slow.message)
        check("retry: a transient failure is retried once", flaky.status == .done && flaky.attempts == 2, "\(flaky.attempts) attempts")
    }
    // Limits and backpressure.
    do {
        let m = TaskManager()
        m.limits["claude"] = 2
        let jobs = (0..<3).map { i in m.run("claude \(i)", kind: "claude") { _ in await sleep(0.25); return .done("ok") } }
        await sleep(0.05)
        check("limit: a third Claude task waits for a free slot", jobs[2].status == .waiting && m.wouldQueue(kind: "claude"), jobs[2].detail)
        _ = await m.waitAll(jobs)
        check("limit: it runs once a slot frees", jobs[2].status == .done && (jobs[2].started ?? .distantPast) >= min(jobs[0].finished ?? .distantFuture, jobs[1].finished ?? .distantFuture))
    }
    // Finding tasks by name, newest first.
    do {
        let m = TaskManager()
        let a = m.run("opening Google Chrome", kind: "app") { _ in await sleep(0.3); return .done("ok") }
        let b = m.run("opening Spotify", kind: "app") { _ in await sleep(0.3); return .done("ok") }
        check("find: “the Chrome task”", m.find("chrome")?.id == a.id)
        check("find: “opening spotify”", m.find("opening spotify")?.id == b.id)
        check("find: “that” is the newest", m.latestActive?.id == b.id)
        _ = await m.waitAll([a, b])
    }
}

Task { @MainActor in
    await orchestrator()
    print("\n\(passed)/\(passed + failed) passed")
    exit(failed == 0 ? 0 : 1)
}
RunLoop.main.run()
