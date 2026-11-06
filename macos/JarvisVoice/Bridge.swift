import CryptoKit
import Foundation

/// The per-install key shared with the bridge and the voice engine (bridge/voice-auth.mjs):
/// ~/Library/Application Support/JarvisVoice/bridge.key, readable only by this user. With it,
/// Jarvis Voice signs its connections (so nothing else can pose as it) and checks that the
/// bridge and the voice engine prove they hold it too (so nothing else on their ports is
/// ever obeyed or told what Jarvis says). The key itself is never sent.
enum VoiceKey {
    static let url = Paths.support.appendingPathComponent("bridge.key")

    static func load() -> SymmetricKey? {
        guard let hex = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return SymmetricKey(data: bytes)
    }

    static func sign(_ key: SymmetricKey, _ parts: String...) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "|").utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 16 random bytes as hex (SystemRandomNumberGenerator is cryptographically secure).
    static func nonce() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// Does `proof` answer `nonce` for `who` ("jarvis-bridge", "jarvis-voice-engine"…)? Constant time.
    static func proves(_ proof: Any?, _ who: String, _ nonce: String, key: SymmetricKey?) -> Bool {
        guard let key, let proof = proof as? String else { return false }
        let expected = sign(key, who, "v1", nonce)
        guard proof.utf8.count == expected.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(proof.utf8, expected.utf8) { difference |= a ^ b }
        return difference == 0
    }
}

/// One conversation with the existing JARVIS bridge (bridge/server.mjs), over
/// the same WebSocket protocol the web interface uses:
///
///   → {"type":"ask","id","text"}         ← {"type":"text","delta","ask"} …
///   → {"type":"interrupt"}               ← {"type":"done","text","ask"} | {"type":"error","message"}
///
/// The bridge keeps one Claude session per connection, so follow-up questions
/// in the same conversation keep their context. A new conversation opens a new
/// connection, which starts a fresh session.
@MainActor
final class BridgeConnection: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let origin: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var currentAsk: String?
    private var counter = 0
    private let key = VoiceKey.load()
    private let nonce = VoiceKey.nonce()
    private(set) var isOpen = false
    private(set) var isClosed = false
    /// The bridge has proved it is this Mac's own bridge. Until then nothing is sent to it
    /// and nothing it asks for is done.
    private(set) var authenticated = false

    var onDelta: ((String) -> Void)?
    var onDone: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onTool: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    /// Requests the bridge makes of this client: "mac" actions, "confirm"
    /// questions for the user, and "capture" for the camera. Answer each with reply().
    var onRequest: ((String, String, [String: Any]) -> Void)?

    init(url: String, origin: String) {
        self.url = URL(string: url) ?? URL(string: "ws://127.0.0.1:8787/")!
        self.origin = origin
    }

    var busy: Bool { currentAsk != nil }

    func connect() {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let key {
            let time = String(Int(Date().timeIntervalSince1970))
            let signature = VoiceKey.sign(key, "jarvis-voice-client", "v1", time, nonce)
            request.setValue("v1.\(time).\(nonce).\(signature)", forHTTPHeaderField: "X-Jarvis-Voice-Auth")
        } else {
            logError("the bridge key is missing (\(VoiceKey.url.path)); the agent creates it — run jarvisctl install")
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20 // panels can carry images
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    /// Open and proven to be this Mac's bridge.
    func waitUntilOpen(timeout: Double) async -> Bool {
        if authenticated { return true }
        if isClosed { return false }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveWaiters(self?.authenticated ?? false)
            }
        }
    }

    private func resolveWaiters(_ ok: Bool) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: ok) }
    }

    /// `request` is the user's own words and `context` the Mac's "[Mac: …]" facts, sent apart so
    /// the bridge never mistakes text from the screen (a window title) for what the user asked.
    func ask(_ text: String, request: String? = nil, context: String? = nil) {
        guard authenticated else { return }
        counter += 1
        let id = "mac-voice-\(Int(Date().timeIntervalSince1970))-\(counter)"
        currentAsk = id
        var message: [String: Any] = ["type": "ask", "id": id, "text": text]
        if let request { message["request"] = request }
        if let context { message["context"] = context }
        send(message)
    }

    func interrupt() {
        guard currentAsk != nil else { return }
        currentAsk = nil
        send(["type": "interrupt"])
    }

    func close() {
        guard !isClosed else { return }
        currentAsk = nil
        task?.cancel(with: .normalClosure, reason: nil)
        finish("closed at the end of the conversation", notify: false)
    }

    private func finish(_ why: String, notify: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        isOpen = false
        log("bridge connection \(why)")
        resolveWaiters(false)
        session?.invalidateAndCancel()
        if notify { onClose?() }
    }

    /// Answers one of the bridge's requests.
    func reply(_ id: String, _ payload: [String: Any]) {
        var object = payload
        object["type"] = "reply"
        object["id"] = id
        send(object)
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { Task { @MainActor in logError("bridge send failed: \(error.localizedDescription)") } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch result {
                case .failure(let error):
                    self.finish("lost: \(error.localizedDescription)")
                case .success(let message):
                    switch message {
                    case .string(let text): self.dispatch(text)
                    case .data(let data): self.dispatch(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func dispatch(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        let ask = object["ask"] as? String
        let mine = ask != nil && ask == currentAsk

        // First, the bridge proves it is this Mac's own (its first "ready" answers our nonce).
        // Anything on the port that can't is disconnected, and nothing it sends is acted on.
        guard authenticated else {
            guard type == "ready", VoiceKey.proves(object["proof"], "jarvis-bridge", nonce, key: key) else {
                logError("the bridge at \(url.host ?? "localhost"):\(url.port ?? 0) did not prove it is this Mac's JARVIS bridge — disconnecting")
                task?.cancel(with: .policyViolation, reason: nil)
                finish("refused: not this Mac's bridge")
                return
            }
            authenticated = true
            resolveWaiters(true)
            onOpen?()
            return
        }

        switch type {
        case "text":
            if mine, let delta = object["delta"] as? String { onDelta?(delta) }
        case "done":
            if mine {
                currentAsk = nil
                onDone?(object["text"] as? String ?? "")
            }
        case "error":
            if currentAsk != nil && (mine || ask == nil) {
                currentAsk = nil
                onError?(object["message"] as? String ?? "")
            }
        case "tool":
            if mine { onTool?(object["name"] as? String ?? "") }
        case "ready", "panel", "blade", "ui":
            break // visual-only messages for the web interface
        default:
            guard let id = object["id"] as? String else { break }
            if ["mac", "confirm", "capture"].contains(type), let onRequest {
                onRequest(type, id, object)
            } else {
                // Something only the web interface can do: decline rather than let the turn hang.
                reply(id, ["error": "Jarvis Voice cannot do that (\(type)); there is no JARVIS screen in this conversation."])
                log("declined a '\(type)' request from the bridge")
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate (delivered on the main queue)

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        // Open is not enough: waiters are released once the bridge has proved itself (dispatch).
        MainActor.assumeIsolated { isOpen = true }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated { finish("closed by the bridge (\(closeCode.rawValue))") }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error { finish("failed: \(error.localizedDescription)") } else { finish("ended") }
        }
    }
}
