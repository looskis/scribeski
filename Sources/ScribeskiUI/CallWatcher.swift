import Capture
import Foundation
import UserNotifications

/// Notices a call starting (a call app or browser beginning to use the mic) while no session
/// is running, and offers to start one (BUILD_PLAN P2.1). It only offers: consent is still
/// affirmed by hand in the start panel, and nothing records until Start is pressed.
@MainActor public final class CallWatcher {
    private let model: SessionModel
    private var inCall: Set<String> = []
    private var task: Task<Void, Never>?
    private var asked = false

    public init(model: SessionModel) {
        self.model = model
    }

    public func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Mic use isn't in the process-list notification, so this polls: cheap, and only reads.
    func check() {
        let sources = CallSources.group(AudioProcessList.snapshot(), excluding: [Bundle.main.bundleIdentifier ?? ""])
        guard let source = callStarted(in: sources) else { return }
        model.sources = sources
        model.selectedSourceID = source.id
        Task { await notify(source) }
    }

    /// The source that has just started a call, if a session could start now. Once per call:
    /// a source has to leave the call before it can prompt again.
    func callStarted(in sources: [CallSource]) -> CallSource? {
        let now = Set(sources.filter(\.isInCall).map(\.id))
        let started = now.subtracting(inCall)
        inCall = now
        guard model.state == .idle, let id = started.sorted().first else { return nil }
        return sources.first { $0.id == id }
    }

    private func notify(_ source: CallSource) async {
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = "\(source.name) call started"
        content.body = "Transcribe it? You'll confirm the client's consent first."
        content.categoryIdentifier = Self.category
        try? await center.add(UNNotificationRequest(identifier: "call-\(source.id)", content: content, trigger: nil))
    }

    public static let category = "com.looski.scribeski.call-started"
}
