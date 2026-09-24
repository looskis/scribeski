import Capture
import Foundation
import ScribeskiCore

/// Walks the session through its states with fake levels and timings, so the UI can be built
/// and demoed before capture (P2.2) and the orchestrator (P3.1) exist. No audio is touched.
@MainActor public final class SimulatedDriver: SessionDriver {
    public let simulationNote: String? = "Capture isn't wired. Levels and pipeline timings are fake."
    private var task: Task<Void, Never>?
    /// Seconds each processing stage takes.
    private let stageDelay: Duration

    public init(stageDelay: Duration = .milliseconds(1500)) {
        self.stageDelay = stageDelay
    }

    public func start(source: CallSource, retention: Retention, model: SessionModel) {
        model.transition(to: .recording(startedAt: .now))
        model.microphoneName = model.microphoneName ?? "Simulated mic"
        task = Task { [weak model] in
            var t = 0.0
            while !Task.isCancelled, let model, model.state.isCapturing {
                t += 0.1
                // Two speakers taking turns every ~6 s, with some jitter.
                let clientTurn = Int(t / 6) % 2 == 1
                model.workerLevel = clientTurn ? Float.random(in: 0...0.05) : Float.random(in: 0.2...0.8)
                model.clientLevel = clientTurn ? Float.random(in: 0.2...0.7) : Float.random(in: 0...0.05)
                model.clientSilentSeconds = clientTurn ? 0 : model.clientSilentSeconds + 0.1
                model.backlogSeconds = max(0, model.backlogSeconds + Double.random(in: -0.2...0.2))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func stop(model: SessionModel) {
        task?.cancel()
        model.transition(to: .stopping)
        run(from: .transcribing, model: model)
    }

    public func retry(_ stage: SessionState.Stage, model: SessionModel) {
        let resume = stage.resumeState
        if resume == .idle { model.transition(to: .idle) } else { run(from: resume, model: model) }
    }

    public func focus(_ key: String, model: SessionModel) {}

    public func locateChart(model: SessionModel) {}
    public func findRecovery(model: SessionModel) {}
    public func resume(model: SessionModel) {}
    public func discardRecovery(model: SessionModel) { model.recovery = nil }
    public func acceptDrift(model: SessionModel) { model.drift = nil }

    public func write(_ key: String, _ value: FieldValue, model: SessionModel) {
        model.edited[key] = value
    }

    public func undoAll(model: SessionModel) {
        model.edited = [:]
        model.transition(to: .readyToFill)
    }

    public func confirmFill(model: SessionModel) {
        run(from: .filling, model: model)
    }

    public func purge(model: SessionModel) {
        model.transition(to: .purged)
        model.transition(to: .idle)
    }

    func run(from first: SessionState, model: SessionModel) {
        let stages: [SessionState] = [.transcribing, .extracting, .readyToFill, .filling, .reviewing]
        guard let start = stages.firstIndex(of: first) else { return }
        task = Task { [weak model, stageDelay] in
            for next in stages[start...] {
                guard !Task.isCancelled, let model else { return }
                model.transition(to: next)
                if next == .readyToFill {
                    model.fillTarget = "Riverside County HSA — Integrated Client Record"
                    return // waits for the worker, like the real thing
                }
                if next != .reviewing { try? await Task.sleep(for: stageDelay) }
            }
        }
    }
}
