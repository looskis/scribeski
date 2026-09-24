import Capture
import Foundation
import ScribeskiCore
import Synchronization

/// What a transcriber consumes for one track, in time order.
public enum TrackInput: Sendable {
    case speech(Utterance)
    /// No speech on this track before `until` (session seconds). Lets a streaming engine
    /// advance its timeline, and finalize, while nobody is talking.
    case silence(until: Double)
}

/// Utterances waiting for a transcriber, bounded by seconds of audio (BUILD_PLAN P2.3).
///
/// Backpressure never spills to disk. Past `capacitySeconds` the oldest untranscribed
/// utterance is dropped (its locked memory wiped as it's released) and reported as a
/// `transcriber_backlog` gap. The producer never blocks: it's the capture queue.
///
/// Consumers may be replaced (a crashed transcriber is restarted on the same queue), so a
/// waiting `next()` returns nil when its task is cancelled instead of stranding the item.
public final class UtteranceQueue: AsyncSequence, Sendable {
    public typealias Element = TrackInput

    public let speaker: Speaker
    public let capacitySeconds: Double
    private let onDrop: @Sendable (Transcript.Gap) -> Void

    private struct State {
        var items: [TrackInput] = []
        var queuedSeconds = 0.0
        var waiter: CheckedContinuation<TrackInput?, Never>?
        var finished = false
    }
    private let state = Mutex(State())

    public init(speaker: Speaker, capacitySeconds: Double = 120,
                onDrop: @escaping @Sendable (Transcript.Gap) -> Void = { _ in }) {
        self.speaker = speaker
        self.capacitySeconds = capacitySeconds
        self.onDrop = onDrop
    }

    /// Seconds of speech waiting. Drives the "falling behind" alarm.
    public var queuedSeconds: Double { state.withLock { $0.queuedSeconds } }

    public func push(_ utterance: Utterance) {
        var dropped: [Utterance] = []
        let waiter = state.withLock { s -> CheckedContinuation<TrackInput?, Never>? in
            guard !s.finished else { return nil }
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.items.append(.speech(utterance))
            s.queuedSeconds += utterance.duration
            while s.queuedSeconds > capacitySeconds,
                  let i = s.items.firstIndex(where: { if case .speech = $0 { true } else { false } }),
                  s.items.count > 1 {
                if case .speech(let old) = s.items.remove(at: i) {
                    s.queuedSeconds -= old.duration
                    dropped.append(old)
                }
            }
            return nil
        }
        waiter?.resume(returning: .speech(utterance))
        for old in dropped {
            onDrop(.init(track: speaker, start: old.start, end: old.end, reason: .transcriberBacklog))
        }
    }

    /// Nothing will be said on this track before `time`. Coalesces with a pending marker.
    public func advance(to time: Double) {
        let waiter = state.withLock { s -> CheckedContinuation<TrackInput?, Never>? in
            guard !s.finished else { return nil }
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            if case .silence(let t)? = s.items.last {
                s.items[s.items.count - 1] = .silence(until: Swift.max(t, time))
            } else {
                s.items.append(.silence(until: time))
            }
            return nil
        }
        waiter?.resume(returning: .silence(until: time))
    }

    /// No more input: the consumer drains what's queued, then its sequence ends.
    public func finish() {
        let waiter = state.withLock { s -> CheckedContinuation<TrackInput?, Never>? in
            s.finished = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> TrackInput? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: TrackInput?? = state.withLock { s in
                    if !s.items.isEmpty {
                        let item = s.items.removeFirst()
                        if case .speech(let u) = item { s.queuedSeconds -= u.duration }
                        return .some(item)
                    }
                    if s.finished || Task.isCancelled { return .some(nil) }
                    s.waiter = continuation
                    return .none
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<TrackInput?, Never>? in
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let queue: UtteranceQueue
        public mutating func next() async -> TrackInput? { await queue.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(queue: self) }
}
