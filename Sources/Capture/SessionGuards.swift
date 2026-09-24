import Foundation
import IOKit.pwr_mgt

/// Zero-recording preconditions (DESIGN §3a, BUILD_PLAN P2.3). In `none` mode audio lives
/// only in RAM, and RAM reaches disk if the Mac hibernates: the sleep image is encrypted only
/// under FileVault. So `none` refuses to arm without FileVault, and holds off idle sleep for
/// the session.
public enum SessionGuards {
    public enum Failure: Error, CustomStringConvertible {
        case fileVaultOff

        public var description: String {
            switch self {
            case .fileVaultOff:
                "FileVault is off. “Audio not recorded” can't be promised without it: if the Mac slept, "
                    + "audio in memory could reach disk unencrypted. Turn on FileVault in System Settings → "
                    + "Privacy & Security, or choose a retention setting that keeps encrypted audio."
            }
        }
    }

    /// `fdesetup isactive` needs no root and prints "true" when FileVault is on.
    public static var fileVaultActive: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        p.arguments = ["isactive"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Throws if a `none`-retention session can't be armed on this Mac.
    public static func checkZeroRecording() throws {
        guard fileVaultActive else { throw Failure.fileVaultOff }
    }

    /// Holds idle sleep off while alive. Release it (or let it go) when the session ends.
    public final class SleepAssertion: @unchecked Sendable {
        private var id: IOPMAssertionID = 0
        public let isHeld: Bool

        public init(reason: String = "Scribeski is transcribing a session") {
            isHeld = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
        }

        deinit {
            if isHeld { IOPMAssertionRelease(id) }
        }
    }
}
