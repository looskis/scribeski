import AVFoundation
import Foundation

/// The TCC grants a session needs (BUILD_PLAN P2.0). Each is tied to the app's code
/// signature, so they survive rebuilds only when the app is signed with a stable identity.
public enum Permission: String, CaseIterable, Sendable {
    /// Your side of the call.
    case microphone
    /// The client's side: a process tap on the call app. "Audio Recording" in System Settings.
    case callAudio
    /// Filling the form: Apple Events to Safari. Not needed until the fill step.
    case safariAutomation

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .callAudio: "Call audio"
        case .safariAutomation: "Control Safari"
        }
    }

    /// Where to fix a denial by hand.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .callAudio: "Privacy_AudioCapture"
        case .safariAutomation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// Never asked; requesting shows the system prompt.
    case notDetermined
    /// Can't tell without asking (Safari not running, or the check itself is unavailable).
    case unknown
}

public enum Permissions {
    public static func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unknown
            }
        case .callAudio:
            TCC.preflight(TCC.audioCapture)
        case .safariAutomation:
            safariAutomation(ask: false)
        }
    }

    /// Shows the system prompt if the user hasn't answered yet, and returns the outcome.
    public static func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return status(.microphone)
        case .callAudio:
            return await TCC.request(TCC.audioCapture)
        case .safariAutomation:
            // Blocks until the user answers the prompt, so keep it off the main thread.
            return await Task.detached { safariAutomation(ask: true) }.value
        }
    }

    /// Safari's bundle ID. The Automation grant is per target app.
    static let safari = "com.apple.Safari"

    static func safariAutomation(ask: Bool) -> PermissionStatus {
        var target = AEAddressDesc()
        let status: OSStatus = safari.withCString { id in
            guard AECreateDesc(typeApplicationBundleID, id, strlen(id), &target) == noErr else { return OSStatus(paramErr) }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        }
        switch Int(status) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        case Int(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown // procNotFound (-600): Safari isn't running.
        }
    }
}

/// Private TCC calls for the one grant with no public API: process-tap audio capture.
/// Resolved at runtime, so if they disappear the status reads `.unknown` and the tap's own
/// first use triggers the prompt instead. Verified present on macOS 27.0, 2026-09-23.
enum TCC {
    static let audioCapture = "kTCCServiceAudioCapture"

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW), name)
    }

    static func preflight(_ service: String) -> PermissionStatus {
        guard let preflightFn = symbol("TCCAccessPreflight").map({ unsafeBitCast($0, to: PreflightFn.self) }) else {
            return .unknown
        }
        return switch preflightFn(service as CFString, nil) {
        case 0: .granted
        case 1: .denied
        default: .notDetermined
        }
    }

    static func request(_ service: String) async -> PermissionStatus {
        guard let requestFn = symbol("TCCAccessRequest").map({ unsafeBitCast($0, to: RequestFn.self) }) else {
            return .unknown
        }
        let granted = await withCheckedContinuation { continuation in
            requestFn(service as CFString, nil) { continuation.resume(returning: $0) }
        }
        return granted ? .granted : .denied
    }
}
