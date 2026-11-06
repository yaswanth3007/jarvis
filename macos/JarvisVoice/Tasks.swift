import Foundation

/// The orchestration layer. Everything Jarvis does on your behalf — opening an app,
/// a Claude request, one Mac action, a camera capture — is a task with an id, a status,
/// the resources it needs, dependencies, a timeout and its own cancellation.
///
/// - Independent tasks run at the same time, up to a limit per kind (fewer Claude
///   sessions when the Mac is short of memory, hot, or very busy).
/// - Resources are locks: exclusive (one task at a time: typing into an app, the
///   keyboard, the camera) or shared (many readers, but never alongside an exclusive
///   holder: opening apps shares "focus", typing takes it exclusively — so an app that
///   opens can never steal the keystrokes of another task).
/// - A task that depends on others starts only when they are over; with
///   `requireSuccess` it is skipped if one of them failed.
/// - One task failing, timing out or being cancelled never stops the others.
@MainActor
final class TaskManager {
    enum Status: String { case queued, waiting, running, done, failed, cancelled }

    struct Outcome {
        var ok: Bool
        var message: String
        /// Worth another attempt (a launch that failed for a transient reason).
        var retry = false
        static func done(_ message: String) -> Outcome { Outcome(ok: true, message: message) }
        static func failed(_ message: String, retry: Bool = false) -> Outcome { Outcome(ok: false, message: message, retry: retry) }
    }

    final class Job {
        let id: Int
        /// What it is, as said aloud: "opening Chess", "what's the weather in Paris".
        let title: String
        /// app | mac | claude | camera — concurrency is limited per kind.
        let kind: String
        let exclusive: Set<String>
        let shared: Set<String>
        let dependsOn: [Int]
        let requireSuccess: Bool
        let cancellable: Bool
        /// The task that started this one (a Mac action belongs to a Claude task).
        var parent: Int?
        var status = Status.queued
        /// What it is doing or waiting for right now, in words.
        var detail = ""
        /// How it ended.
        var message = ""
        let created = Date()
        var started: Date?
        var finished: Date?
        var attempts = 0
        /// The title as it may appear in the log.
        var logTitle = ""
        fileprivate(set) var acquired = false
        /// Undo what can be undone when it is cancelled or times out.
        var onCancel: (() -> Void)?

        fileprivate init(id: Int, title: String, kind: String, exclusive: Set<String>, shared: Set<String>,
                         dependsOn: [Int], requireSuccess: Bool, cancellable: Bool) {
            self.id = id
            self.title = title
            self.kind = kind
            self.exclusive = exclusive
            self.shared = shared
            self.dependsOn = dependsOn
            self.requireSuccess = requireSuccess
            self.cancellable = cancellable
        }

        var isActive: Bool { status == .queued || status == .waiting || status == .running }
        /// Time spent working (from start, or from creation if it never started).
        var elapsedMs: Int { Int(((finished ?? Date()).timeIntervalSince(started ?? created)) * 1000) }
        /// Time spent waiting for dependencies, a free slot or a resource.
        var waitedMs: Int { Int(((started ?? finished ?? Date()).timeIntervalSince(created)) * 1000) }
    }

    private(set) var jobs: [Job] = []
    private var nextID = 1
    private var exclusiveHolder: [String: Int] = [:]
    private var sharedHolders: [String: Set<Int>] = [:]
    private var running: [String: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Normal concurrency per kind. Claude: the conversation plus two background tasks,
    /// each its own Claude Code session (~350 MB). Apps and Mac actions are light.
    var limits: [String: Int] = ["app": 6, "mac": 4, "claude": 3, "camera": 1]
    /// At most this many tasks of one kind wait for a slot; beyond it, new ones are refused.
    var maxQueued = 4
    /// Called whenever a task starts or ends (menu bar, announcements).
    var onChange: ((Job) -> Void)?

    func job(_ id: Int) -> Job? { jobs.first { $0.id == id } }
    var active: [Job] { jobs.filter(\.isActive) }

    func activeCount(kind: String) -> Int { jobs.filter { $0.kind == kind && $0.isActive }.count }

    /// The concurrency allowed for a kind right now.
    func limit(_ kind: String) -> Int {
        let base = limits[kind] ?? 4
        guard SystemLoad.busy().busy else { return base }
        switch kind {
        case "claude": return max(1, base - 1)
        case "app", "mac": return max(2, base / 2)
        default: return base
        }
    }

    /// Whether a new task of this kind would have to wait for a free slot.
    func wouldQueue(kind: String) -> Bool { (running[kind] ?? 0) + waitingCount(kind) >= limit(kind) }
    func waitingCount(_ kind: String) -> Int { jobs.filter { $0.kind == kind && ($0.status == .queued || $0.status == .waiting) && !$0.acquired }.count }

    /// `sensitiveTitle`: the title is the user's own words (a Claude request), kept out of the log.
    @discardableResult
    func run(_ title: String, kind: String, exclusive: Set<String> = [], shared: Set<String> = [],
             dependsOn: [Int] = [], requireSuccess: Bool = false, cancellable: Bool = true,
             retries: Int = 0, timeout: Double = 60, sensitiveTitle: Bool = false,
             work: @escaping @MainActor (Job) async -> Outcome) -> Job {
        let job = Job(id: nextID, title: title, kind: kind, exclusive: exclusive, shared: shared,
                      dependsOn: dependsOn, requireSuccess: requireSuccess, cancellable: cancellable)
        job.logTitle = sensitiveTitle ? "(\(title.split(separator: " ").count) words)" : title
        nextID += 1
        jobs.append(job)
        prune()
        log("task \(job.id) queued (\(kind)): \(job.logTitle)" + (dependsOn.isEmpty ? "" : " — after task \(dependsOn.map(String.init).joined(separator: ", "))")
            + (exclusive.isEmpty && shared.isEmpty ? "" : " [\((exclusive.sorted().map { "\($0)!" } + shared.sorted()).joined(separator: ", "))]"))
        Task { @MainActor in
            for dep in dependsOn {
                while let other = self.job(dep), other.isActive, job.status != .cancelled {
                    job.detail = "waiting for task \(dep)"
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            guard job.status != .cancelled else { return }
            if job.requireSuccess, let blocker = dependsOn.compactMap({ self.job($0) }).first(where: { $0.status != .done }) {
                self.finish(job, .cancelled, "skipped, because task \(blocker.id) \(blocker.status == .failed ? "failed" : "was stopped")")
                return
            }
            job.status = .waiting
            await self.acquire(job)
            guard job.status != .cancelled else { self.release(job); return }
            job.status = .running
            job.detail = ""
            job.started = Date()
            if job.waitedMs > 150 { log("task \(job.id) started after waiting \(job.waitedMs) ms") }
            self.onChange?(job)
            var outcome: Outcome?
            while true {
                job.attempts += 1
                outcome = await Self.withTimeout(timeout) { await work(job) }
                guard job.status != .cancelled, let o = outcome, !o.ok, o.retry, job.attempts <= retries else { break }
                log("task \(job.id) failed (\(o.message)) — retrying")
                job.detail = "trying again"
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            self.release(job)
            guard job.status != .cancelled else { return }
            if let outcome {
                self.finish(job, outcome.ok ? .done : .failed, outcome.message)
            } else {
                job.onCancel?()
                self.finish(job, .failed, "it timed out after \(Int(timeout)) seconds")
            }
        }
        return job
    }

    /// Stops one task. What has already happened (an app that has launched) is not undone.
    @discardableResult
    func cancel(_ job: Job, reason: String = "cancelled") -> Bool {
        guard job.isActive, job.cancellable else { return false }
        job.status = .cancelled // first, so every loop waiting on its behalf stops
        job.onCancel?()
        job.onCancel = nil
        finish(job, .cancelled, reason, force: true)
        release(job)
        // Its own sub-tasks (a Claude task's Mac actions) go with it.
        for child in jobs where child.parent == job.id && child.isActive { cancel(child, reason: "its task was cancelled") }
        return true
    }

    /// Waits until the task is over, or the timeout passes. True if it is over.
    func wait(_ job: Job, timeout: Double = .infinity) async -> Bool { await waitAll([job], timeout: timeout) }

    /// Checks often at first (a quick action is answered at once), then less often.
    func waitAll(_ group: [Job], timeout: Double = .infinity) async -> Bool {
        let start = Date()
        let end = timeout.isFinite ? start.addingTimeInterval(timeout) : Date.distantFuture
        while group.contains(where: \.isActive) && Date() < end {
            try? await Task.sleep(nanoseconds: Date().timeIntervalSince(start) < 2 ? 10_000_000 : 50_000_000)
        }
        return !group.contains(where: \.isActive)
    }

    /// The most recent task still going — what "stop that" means.
    var latestActive: Job? { active.filter { $0.parent == nil }.max { $0.id < $1.id } ?? active.max { $0.id < $1.id } }

    /// "the Spotify task", "opening Chess", "the weather" → the newest live task that mentions it.
    func find(_ phrase: String) -> Job? {
        let ignored: Set<String> = ["the", "a", "an", "my", "your", "task", "job", "one", "that", "this", "for", "of", "to"]
        let words = normalized(phrase).split(separator: " ").map(String.init).filter { !ignored.contains($0) }
        guard !words.isEmpty else { return nil }
        let candidates = active.filter { $0.parent == nil } + active.filter { $0.parent != nil }
        return candidates.sorted { $0.id > $1.id }.first { job in
            let title = normalized(job.title)
            return words.allSatisfy { title.contains($0) }
        }
    }

    // MARK: - Internals

    private func prune() {
        guard jobs.count > 60 else { return }
        let removable = jobs.filter { !$0.isActive }.prefix(jobs.count - 60).map(\.id)
        jobs.removeAll { removable.contains($0.id) }
    }

    private func finish(_ job: Job, _ status: Status, _ message: String, force: Bool = false) {
        guard job.isActive || force else { return }
        guard job.finished == nil else { return }
        job.status = status
        job.message = message
        job.detail = ""
        job.finished = Date()
        log("task \(job.id) \(status.rawValue) in \(job.elapsedMs) ms\(job.waitedMs > 150 ? " (waited \(job.waitedMs) ms)" : ""): \(job.logTitle)")
        onChange?(job)
    }

    private func canStart(_ job: Job) -> Bool {
        guard (running[job.kind] ?? 0) < limit(job.kind) else { return false }
        for r in job.exclusive where exclusiveHolder[r] != nil || !(sharedHolders[r] ?? []).isEmpty { return false }
        for r in job.shared where exclusiveHolder[r] != nil { return false }
        return true
    }

    private func acquire(_ job: Job) async {
        while !canStart(job) && job.status != .cancelled {
            if job.detail.isEmpty || job.detail.hasPrefix("waiting for task") {
                job.detail = (running[job.kind] ?? 0) >= limit(job.kind) ? "waiting for a free slot" : "waiting its turn"
            }
            await withCheckedContinuation { waiters.append($0) }
        }
        guard job.status != .cancelled else { return }
        running[job.kind, default: 0] += 1
        for r in job.exclusive { exclusiveHolder[r] = job.id }
        for r in job.shared { sharedHolders[r, default: []].insert(job.id) }
        job.acquired = true
    }

    private func release(_ job: Job) {
        defer { wake() }
        guard job.acquired else { return }
        job.acquired = false
        running[job.kind] = max(0, (running[job.kind] ?? 1) - 1)
        for r in job.exclusive where exclusiveHolder[r] == job.id { exclusiveHolder[r] = nil }
        for r in job.shared { sharedHolders[r]?.remove(job.id) }
    }

    private func wake() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Runs `work`, giving up on it after `seconds`. The work itself is not torn down by
    /// Swift cancellation (it may be mid-way through a macOS call); the job's onCancel
    /// stops whatever can be stopped.
    private static func withTimeout(_ seconds: Double, _ work: @escaping @MainActor () async -> Outcome) async -> Outcome? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome?, Never>) in
            let once = Once(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                if !Task.isCancelled { once.resume(nil) }
            }
            Task { @MainActor in
                let result = await work()
                timer.cancel()
                once.resume(result)
            }
        }
    }
}

/// Resumes a continuation once, whoever gets there first.
@MainActor
final class Once<T> {
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
    var done: Bool { continuation == nil }
}

/// How hard the Mac is working — so Jarvis runs fewer things at once when it is short
/// of memory, hot, or its CPU is saturated.
@MainActor
enum SystemLoad {
    static var memoryWarning = false
    private static var source: DispatchSourceMemoryPressure?

    static func watch() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        s.setEventHandler {
            MainActor.assumeIsolated {
                let warning = s.data.contains(.warning) || s.data.contains(.critical)
                if warning != memoryWarning { log("memory pressure: \(warning ? "high — running fewer tasks at once" : "normal")") }
                memoryWarning = warning
            }
        }
        s.resume()
        source = s
    }

    static func busy() -> (busy: Bool, why: String) {
        if memoryWarning { return (true, "memory is running low") }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return (true, "the Mac is running hot")
        default: break
        }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0, load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) * 1.5 {
            return (true, "the processor is very busy")
        }
        return (false, "")
    }
}

extension String {
    var lowercasedFirst: String { isEmpty ? self : prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
