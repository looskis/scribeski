import Foundation

/// Where a session is in its lifecycle (BUILD_PLAN P3.1). The orchestrator persists every
/// transition; the menu-bar UI renders from it. Nothing ever asks the worker to re-record,
/// so every post-recording failure resumes from the transcript.
public enum SessionState: Codable, Hashable, Sendable {
    case idle
    /// Consent affirmed, retention fixed for the session, call source chosen.
    case armed
    case recording(startedAt: Date)
    case stopping
    case transcribing
    case extracting
    /// Notes are ready; waiting for the worker to confirm which tab gets filled (P3.3).
    case readyToFill
    case filling
    case reviewing
    /// The worker pressed "I've reviewed this". Purge follows per retention policy.
    case confirmed
    case purged
    case failed(stage: Stage, message: String)

    /// The stage names `failed` can point at.
    public enum Stage: String, Codable, Hashable, Sendable {
        case arming, recording, stopping, transcribing, extracting, filling, purging
    }

    /// Whether the orchestrator may move from `self` to `next`. Anything not listed is a bug.
    public func canTransition(to next: SessionState) -> Bool {
        switch (self, next) {
        case (.idle, .armed), (.armed, .idle), (.armed, .recording),
             (.recording, .stopping), (.stopping, .transcribing),
             (.transcribing, .extracting), (.extracting, .readyToFill), (.readyToFill, .filling),
             (.filling, .reviewing),
             // "Undo all" in review puts the form back and returns to the fill confirmation.
             (.reviewing, .readyToFill),
             // Resuming after a crash, from the sealed transcript or the sealed results.
             (.idle, .extracting), (.idle, .readyToFill),
             (.reviewing, .confirmed), (.confirmed, .purged), (.purged, .idle):
            true
        // Retrying a failed stage resumes from what's already persisted.
        case (.failed(let stage, _), _):
            next == stage.resumeState || next == .idle
        case (_, .failed):
            self != .idle && self != .purged
        default:
            false
        }
    }

    /// True while call audio is flowing into the pipeline.
    public var isCapturing: Bool {
        if case .recording = self { true } else { false }
    }

    /// True between Stop and review: the worker waits, the machine works.
    public var isProcessing: Bool {
        switch self {
        case .stopping, .transcribing, .extracting, .filling: true
        default: false
        }
    }
}

extension SessionState.Stage {
    /// The state a retry re-enters.
    public var resumeState: SessionState {
        switch self {
        case .arming: .idle
        // A capture failure keeps what was transcribed so far and carries on from there.
        case .recording, .stopping, .transcribing: .transcribing
        case .extracting: .extracting
        // A failed fill goes back to the confirmation, so the worker can fix the tab and retry.
        case .filling: .readyToFill
        case .purging: .confirmed
        }
    }
}
