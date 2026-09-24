import AppKit
import CoreAudio
import Foundation

/// Reads CoreAudio's process object list (BUILD_PLAN P2.1). No TCC permission needed:
/// listing and `IsRunningOutput` are readable by anyone; only the tap itself is gated.
public enum AudioProcessList {
    public static func snapshot() -> [AudioProcess] {
        let ids = CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return ids.compactMap { id in
            let pid: pid_t = CA.read(id, kAudioProcessPropertyPID, 0)
            guard pid > 0 else { return nil }
            let owner = responsiblePID(for: pid)
            let app = NSRunningApplication(processIdentifier: owner)
            let bundleID = CA.string(id, kAudioProcessPropertyBundleID) ?? ""
            return AudioProcess(
                objectID: id,
                pid: pid,
                bundleID: bundleID,
                responsibleBundleID: app?.bundleIdentifier ?? bundleID,
                responsibleName: app?.localizedName,
                isRunningOutput: CA.read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0,
                isRunningInput: CA.read(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0)
        }
    }

    /// Calls `onChange` on the main queue whenever a process starts or stops using audio,
    /// so a tap can pick up helpers that appear mid-session. Keep the token to keep listening.
    public static func observe(_ onChange: @escaping @MainActor () -> Void) -> Observation {
        Observation(onChange)
    }

    public final class Observation {
        private let block: AudioObjectPropertyListenerBlock
        private var address = CA.address(kAudioHardwarePropertyProcessObjectList)

        init(_ onChange: @escaping @MainActor () -> Void) {
            block = { _, _ in MainActor.assumeIsolated { onChange() } }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    // MARK: - Responsible process

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// libquarantine SPI, resolved at runtime so a missing symbol degrades to "self".
    /// Maps com.apple.WebKit.GPU → Safari, Chrome helpers → Chrome. Verified 2026-09-22.
    private static let responsibleFn: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW),
        "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ResponsibleFn.self) }

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }
}
