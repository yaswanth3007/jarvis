import AppKit
import AVFoundation
import CoreImage
import Foundation

/// The Mac's camera, opened only for the moment a request needs it.
///
/// Answers the bridge's existing `capture` requests (the `look` and `watch`
/// tools in bridge/vision.mjs) with the same format the web interface sends:
/// base64 JPEG. Frames live in memory only and are never written to disk. The
/// session stops as soon as the frames are taken, so the camera light goes out.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.jarvis.voice.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frames = 0
    private let context = CIContext()

    enum CameraError: LocalizedError {
        case denied, unavailable, noFrame
        var errorDescription: String? {
            switch self {
            case .denied:
                "macOS is blocking the camera for Jarvis Voice. The user can allow it in System Settings, Privacy and Security, Camera."
            case .unavailable: "There is no camera available on this Mac right now."
            case .noFrame: "The camera opened but sent no picture."
            }
        }
    }

    /// macOS's own permission, asking through Apple's prompt the first time.
    static func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            log("asking for camera access (macOS shows a prompt)")
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// One frame, or `count` frames spread over `seconds`, each with its offset.
    func capture(count: Int, seconds: Double) async throws -> [(CGImage, Double)] {
        guard await Self.ensureAccess() else { throw CameraError.denied }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { throw CameraError.unavailable }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.unavailable }
        session.addOutput(output)
        session.commitConfiguration()

        reset()
        session.startRunning()
        log("camera on (\(device.localizedName))")
        defer {
            session.stopRunning()
            reset()
            log("camera off")
        }

        // Let exposure and white balance settle before the first real frame.
        let warmUp = Date()
        while Date().timeIntervalSince(warmUp) < 3 {
            if frameCount() >= 12 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        var shots: [(CGImage, Double)] = []
        let n = max(1, count)
        let gap = n > 1 ? seconds / Double(n - 1) : 0
        let start = Date()
        for i in 0..<n {
            if i > 0 {
                let due = start.addingTimeInterval(gap * Double(i))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            if let image = grab() { shots.append((image, Date().timeIntervalSince(start))) }
        }
        guard !shots.isEmpty else { throw CameraError.noFrame }
        return shots
    }

    private func reset() { lock.withLock { latest = nil; frames = 0 } }
    private func frameCount() -> Int { lock.withLock { frames } }

    private func grab() -> CGImage? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock { latest = buffer; frames += 1 }
    }

    // MARK: Encoding

    /// Frames laid out left to right, top to bottom, each stamped with its time —
    /// the same layout the web interface's `watch` sends.
    static func grid(_ shots: [(CGImage, Double)]) -> CGImage? {
        let n = shots.count
        let cols = n <= 2 ? n : (n <= 6 ? 3 : 4)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let cellW = 640, cellH = 360
        guard let ctx = CGContext(data: nil, width: cols * cellW, height: rows * cellH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cols * cellW, height: rows * cellH))
        for (i, shot) in shots.enumerated() {
            let x = (i % cols) * cellW
            let y = (rows - 1 - i / cols) * cellH
            ctx.draw(shot.0, in: CGRect(x: x, y: y, width: cellW, height: cellH))
            let label = String(format: "+%.1fs", shot.1) as NSString
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.yellow,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            label.draw(at: NSPoint(x: x + 10, y: y + 10), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }
}

/// JPEG for Claude: the long edge capped (vision models gain nothing beyond ~1568 px).
func jpegBase64(_ image: CGImage, maxEdge: Int = 1568, quality: Double = 0.72) -> String? {
    var cg = image
    let longest = max(image.width, image.height)
    if longest > maxEdge {
        let scale = Double(maxEdge) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let scaled = ctx.makeImage() { cg = scaled }
        }
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])?.base64EncodedString()
}
