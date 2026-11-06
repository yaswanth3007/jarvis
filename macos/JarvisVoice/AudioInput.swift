import AudioToolbox
import AVFoundation
import Foundation

/// Microphone capture with AVAudioEngine, converted to the recogniser's own
/// format (16 kHz mono). Audio exists only in memory, buffer by buffer, on its
/// way to the on-device recogniser — it is never written anywhere.
final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var observer: NSObjectProtocol?
    private(set) var running = false
    /// Whether the engine is actually running (macOS stops it when the route changes).
    var engineRunning: Bool { engine.isRunning }
    private(set) var device: AudioDevice?

    /// Called on the audio thread with each converted buffer and its loudness (RMS, 0…1).
    var onBuffer: ((AVAudioPCMBuffer, Float) -> Void)?
    /// Called on the main thread when capture cannot continue.
    var onFailure: ((String) -> Void)?
    /// Called on the main thread when macOS reconfigures the audio route.
    var onRouteChange: (() -> Void)?

    init(target: AVAudioFormat) {
        self.target = target
    }

    /// Starts listening through `device`, or the system default when nil.
    func start(device: AudioDevice?) throws {
        guard !running else { return }
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { log("could not select \(device.name) as the microphone (\(status)); using the default") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "JarvisVoice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input is available"])
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "JarvisVoice", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot convert \(format) to \(target)"])
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        self.device = device ?? AudioDevices.defaultInput
        log("microphone on: \(self.device?.description ?? "default") — \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.onRouteChange?()
            }
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        log("microphone off")
    }

    /// Restart on `device` — after a headset is plugged in, say.
    func restart(device: AudioDevice?) {
        stop()
        engine.reset()
        do {
            try start(device: device)
        } catch {
            onFailure?("the microphone could not restart: \(error.localizedDescription)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        onBuffer?(out, Self.rms(out))
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let samples = buffer.int16ChannelData?[0] {
            for i in 0..<n {
                let s = Float(samples[i]) / 32768
                sum += s * s
            }
        } else if let samples = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += samples[i] * samples[i] }
        }
        return (sum / Float(n)).squareRoot()
    }
}
