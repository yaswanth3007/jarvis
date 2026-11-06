import AudioToolbox
import CoreAudio
import Foundation

/// One CoreAudio device, as much as Jarvis needs to know about it.
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var kind: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        default: "wired"
        }
    }

    var description: String { "\(name) (\(kind))" }
}

/// The Mac's audio devices, and which microphone Jarvis should listen through.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func name(_ id: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let name = value?.takeRetainedValue() else { return "device \(id)" }
        return name as String
    }

    static func device(_ id: AudioDeviceID) -> AudioDevice {
        AudioDevice(id: id, name: name(id), transport: uint32(id, kAudioDevicePropertyTransportType))
    }

    static var defaultInput: AudioDevice? {
        let id = uint32(system, kAudioHardwarePropertyDefaultInputDevice)
        return id == 0 ? nil : device(id)
    }

    static var defaultOutput: AudioDevice? {
        let id = uint32(system, kAudioHardwarePropertyDefaultOutputDevice)
        return id == 0 ? nil : device(id)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(device)
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static var builtInMicrophone: AudioDevice? {
        all().first { $0.isBuiltIn && hasInput($0.id) && uint32($0.id, kAudioDevicePropertyDeviceIsAlive) != 0 }
    }

    /// The microphone to listen through, and why.
    ///   auto    — the system microphone, except that Bluetooth headsets are skipped in
    ///             favour of the Mac's own mic, so headphones stay in high-quality audio
    ///             (macOS drops Bluetooth headphones to call quality while their mic is open).
    ///   system  — always the system microphone.
    ///   builtin — always the Mac's own microphone.
    static func chooseInput(policy: String) -> (device: AudioDevice?, reason: String) {
        let system = defaultInput
        switch policy.lowercased() {
        case "system":
            return (system, "the system microphone")
        case "builtin", "built-in":
            if let mic = builtInMicrophone { return (mic, "the Mac's own microphone (as configured)") }
            return (system, "the system microphone (no built-in microphone found)")
        default:
            if let system, system.isBluetooth, let mic = builtInMicrophone {
                return (mic, "the Mac's own microphone, so \(system.name) stays in high-quality audio")
            }
            return (system, "the system microphone")
        }
    }

    /// Calls `handler` on the main queue when devices come and go or the defaults change.
    static func observe(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
        }
    }
}
