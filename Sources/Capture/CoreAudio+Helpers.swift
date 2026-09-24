import CoreAudio
import Foundation

/// Thin wrappers over `AudioObjectGetPropertyData` for the handful of reads capture needs.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                         _ fallback: T) -> T {
        var address = address(selector, scope: scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                          of: T.Type) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!) == noErr
                ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultInputDevice: AudioDeviceID? {
        let id: AudioDeviceID = read(system, kAudioHardwarePropertyDefaultInputDevice, 0)
        guard id != kAudioObjectUnknown, inputChannelCount(id) > 0 else { return nil }
        return id
    }

    static var defaultOutputDevice: AudioDeviceID? {
        let id: AudioDeviceID = read(system, kAudioHardwarePropertyDefaultSystemOutputDevice, 0)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        read(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }
}

public struct CaptureError: Error, CustomStringConvertible, Sendable {
    public let step: String
    public let status: OSStatus

    init(_ step: String, _ status: OSStatus) {
        self.step = step
        self.status = status
    }

    public var description: String {
        let fourCC = withUnsafeBytes(of: status.bigEndian) { bytes in
            bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        }
        return "\(step) failed (\(status)\(fourCC))"
    }

    static func check(_ status: OSStatus, _ step: String) throws(CaptureError) {
        if status != noErr { throw CaptureError(step, status) }
    }
}

/// Device facts the UI shows before a session starts.
public enum AudioDevices {
    /// The default input device's name, or nil if the Mac has no usable input.
    public static var defaultInputName: String? {
        CA.defaultInputDevice.flatMap { CA.string($0, kAudioObjectPropertyName) }
    }
}
