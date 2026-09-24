import Foundation
import Security

/// Where the store lives, and why that place was chosen.
public struct StoreLocation: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// `SUITE_MODEL_STORE` was set to an absolute path.
        case environment
        /// The shared App Group container of the given group id.
        case appGroup(String)
        /// `~/Library/Application Support/<suiteName>/Models` (unentitled dev tools).
        case applicationSupport
    }

    /// The `Models/` directory: `blobs/`, `snapshots/`, `users/`, `tmp/`, `.lock` live directly in it.
    public var root: URL
    public var source: Source
    /// Human-readable explanation, including why earlier options were skipped.
    public var reason: String

    public init(root: URL, source: Source, reason: String) {
        self.root = root
        self.source = source
        self.reason = reason
    }

    public static let environmentVariable = "SUITE_MODEL_STORE"
    public static let appGroupEntitlement = "com.apple.security.application-groups"

    /// Resolves the store location, in order:
    /// 1. `SUITE_MODEL_STORE` (must be an absolute path; it *is* the `Models/` directory);
    /// 2. the App Group container for `groupID` (production: `"<TEAMID>.<suite>"`), when this
    ///    process is entitled to that group — `<container>/Models`;
    /// 3. `~/Library/Application Support/<suiteName>/Models`.
    ///
    /// The entitlement is checked before calling `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// because on recent macOS an unentitled call can raise a "wants to access data from other apps"
    /// prompt. `environment`, `hasGroupEntitlement` and `containerURL` are injectable for tests.
    public static func resolve(
        groupID: String?,
        suiteName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        hasGroupEntitlement: (String) -> Bool = StoreLocation.processHasAppGroupEntitlement,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) -> StoreLocation {
        var skipped: [String] = []

        if let raw = environment[environmentVariable], !raw.isEmpty {
            if raw.hasPrefix("/") {
                return StoreLocation(
                    root: URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL,
                    source: .environment,
                    reason: "\(environmentVariable) is set to \(raw)")
            }
            skipped.append("\(environmentVariable)='\(raw)' ignored: not an absolute path")
        }

        if let groupID, !groupID.isEmpty {
            if !hasGroupEntitlement(groupID) {
                skipped.append("process lacks the \(appGroupEntitlement) entitlement for '\(groupID)'")
            } else if let container = containerURL(groupID) {
                return StoreLocation(
                    root: container.appendingPathComponent("Models", isDirectory: true),
                    source: .appGroup(groupID),
                    reason: (skipped + ["App Group container for '\(groupID)'"]).joined(separator: "; "))
            } else {
                skipped.append("no App Group container for '\(groupID)'")
            }
        } else {
            skipped.append("no App Group id configured")
        }

        let root = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        return StoreLocation(
            root: root, source: .applicationSupport,
            reason: (skipped + ["falling back to Application Support"]).joined(separator: "; "))
    }

    /// True if this process's code signature grants `com.apple.security.application-groups`
    /// containing `groupID`.
    public static func processHasAppGroupEntitlement(_ groupID: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, appGroupEntitlement as CFString, nil)
        guard let groups = value as? [String] else { return false }
        return groups.contains(groupID)
    }
}
