import Darwin
import Foundation

/// A Unix-domain socket that `jarvisctl` talks to (status, mute, unmute, talk…).
/// Unix sockets are unreachable from web pages and from other machines, and the
/// file is created owner-only (0600), so only you can control the assistant.
final class ControlServer: @unchecked Sendable {
    private var fd: Int32 = -1
    private var path: String?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "local.jarvis.voice.control")
    private var handler: (@MainActor (String) async -> String)?

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// True if another copy of the app is already answering on the socket.
    static func anotherInstanceIsRunning(at path: String) -> Bool {
        guard var addr = address(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    func start(path: String, handler: @escaping @MainActor (String) async -> String) throws {
        self.handler = handler
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0, var addr = Self.address(path) else {
            throw TranscriberError("cannot create the control socket")
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(s)
            throw TranscriberError("cannot bind the control socket: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard listen(s, 8) == 0 else {
            close(s)
            throw TranscriberError("cannot listen on the control socket")
        }
        fd = s
        self.path = path
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while data.count < 16_384 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(10) { break }
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = self.handler
        Task { @MainActor in
            let reply = await handler?(line) ?? "error"
            let bytes = Array((reply + "\n").utf8)
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            close(client)
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        if let path { unlink(path) }
    }
}
