/// One CoreAudio process object, as seen by call-app discovery (BUILD_PLAN P2.1).
public struct AudioProcess: Hashable, Sendable {
    public var objectID: UInt32
    public var pid: Int32
    /// The process's own bundle ID, e.g. `com.apple.WebKit.GPU`.
    public var bundleID: String
    /// The app macOS holds responsible for this process. Browser audio comes from helpers
    /// (Safari's from `com.apple.WebKit.GPU`, parented to launchd), so grouping by bundle
    /// family misses it; grouping by responsible app doesn't.
    public var responsibleBundleID: String
    public var responsibleName: String?
    public var isRunningOutput: Bool
    public var isRunningInput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String, responsibleBundleID: String,
                responsibleName: String? = nil, isRunningOutput: Bool = false,
                isRunningInput: Bool = false) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.responsibleBundleID = responsibleBundleID
        self.responsibleName = responsibleName
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

/// An app the worker can pick as "the call": every audio process it is responsible for.
public struct CallSource: Hashable, Sendable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var kind: Kind
    public var processes: [AudioProcess]

    public init(bundleID: String, name: String, kind: Kind, processes: [AudioProcess]) {
        self.bundleID = bundleID
        self.name = name
        self.kind = kind
        self.processes = processes
    }

    public enum Kind: Hashable, Sendable {
        case callApp
        /// A Safari "Add to Dock" web app. Believed to get its own WebKit processes, so its
        /// tap would hold only the call. Unverified.
        case webApp
        /// A whole browser: a tap picks up every tab, not just the call (R5).
        case browser
        case other
    }

    public var isPlaying: Bool { processes.contains { $0.isRunningOutput } }

    /// Using the microphone: for a call app or a browser, the strongest sign a call is live.
    /// Zoom, Teams, and a Meet tab only take the mic while in a meeting.
    public var isInCall: Bool { (kind != .other) && processes.contains { $0.isRunningInput } }

    /// Bundle IDs a tap can follow across restarts (macOS 26 `CATapDescription.bundleIDs`).
    /// Native call apps only: every WebKit client's audio process is `com.apple.WebKit.GPU`,
    /// so following a browser by bundle ID would capture every WebKit app.
    public var restorableBundleIDs: [String] {
        guard kind == .callApp else { return [] }
        return Array(Set([bundleID] + processes.map(\.bundleID).filter { !$0.isEmpty })).sorted()
    }

    /// What else a tap on this source will hear, stated for the worker.
    public var isolationWarning: String? {
        switch kind {
        case .callApp: nil
        case .webApp: "Web app isolation isn't verified yet."
        case .browser: "Captures every \(name) tab. Close other tabs playing audio."
        case .other: "Not a known call app."
        }
    }
}

public enum CallSources {
    /// Checked in order, so a more specific prefix must come before a shorter one.
    static let known: [(prefix: String, name: String, kind: CallSource.Kind)] = [
        ("us.zoom.", "Zoom", .callApp),
        ("com.microsoft.teams", "Microsoft Teams", .callApp),
        ("Cisco-Systems.Spark", "Webex", .callApp),
        ("com.apple.FaceTime", "FaceTime", .callApp),
        ("com.tinyspeck.slackmacgap", "Slack", .callApp),
        ("com.apple.Safari.WebApp", "Safari web app", .webApp),
        ("com.apple.Safari", "Safari", .browser),
        ("com.google.Chrome", "Google Chrome", .browser),
        ("com.microsoft.edgemac", "Microsoft Edge", .browser),
        ("org.mozilla.firefox", "Firefox", .browser),
        ("company.thebrowser.", "Arc", .browser),
    ]

    public static func classify(_ bundleID: String) -> (name: String, kind: CallSource.Kind)? {
        known.first { bundleID.hasPrefix($0.prefix) }.map { ($0.name, $0.kind) }
    }

    /// Groups processes by responsible app. Known call apps and browsers are always listed;
    /// anything else only while it is playing audio. `excluding` drops our own app.
    /// Call apps come first, then whatever is playing, then by name.
    public static func group(_ processes: [AudioProcess], excluding: Set<String> = []) -> [CallSource] {
        let byApp = Dictionary(grouping: processes.filter { !excluding.contains($0.responsibleBundleID) },
                               by: \.responsibleBundleID)
        let sources = byApp.compactMap { bundleID, procs -> CallSource? in
            let known = classify(bundleID)
            let named = procs.lazy.compactMap(\.responsibleName).first
            let source = CallSource(
                bundleID: bundleID,
                // A web app's own name ("Google Meet") beats the generic table entry.
                name: known?.kind == .webApp ? (named ?? known!.name) : (known?.name ?? named ?? bundleID),
                kind: known?.kind ?? .other,
                processes: procs.sorted { $0.pid < $1.pid })
            return source.kind == .other && !source.isPlaying ? nil : source
        }
        // In a call first, then call apps, then whatever is playing, then by name.
        return sources.sorted {
            if $0.isInCall != $1.isInCall { return $0.isInCall }
            let a = ($0.kind == .callApp || $0.kind == .webApp, $0.isPlaying)
            let b = ($1.kind == .callApp || $1.kind == .webApp, $1.isPlaying)
            if a != b { return a.0 != b.0 ? a.0 : a.1 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
