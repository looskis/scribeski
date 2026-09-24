import Foundation
import ScribeskiCore
import Synchronization

/// Collects final segments and gaps from both tracks as they arrive, and merges them by time
/// into one `Transcript` (speaker = track; DESIGN §3: never mix down, never diarize).
public final class TranscriptAssembler: Sendable {
    private struct State {
        var segments: [TranscribedSegment] = []
        var gaps: [Transcript.Gap] = []
        var tracks: [Speaker: Transcript.Track] = [:]
        var bleedDropped = 0
    }
    private let state = Mutex(State())

    public init() {}

    public func add(_ segment: TranscribedSegment) { state.withLock { $0.segments.append(segment) } }
    public func add(_ gap: Transcript.Gap) { state.withLock { $0.gaps.append(gap) } }

    /// Records a track's source. The first source seen for a track wins, so a rebuild onto
    /// a different mic doesn't rewrite history.
    public func noteTracks(_ tracks: [Speaker: Transcript.Track]) {
        state.withLock { s in
            for (speaker, track) in tracks where s.tracks[speaker] == nil { s.tracks[speaker] = track }
        }
    }

    public var segmentCount: Int { state.withLock { $0.segments.count } }

    /// Final text so far, merged by time. Cheap enough to call for a live view.
    public var liveSegments: [TranscribedSegment] {
        state.withLock { $0.segments }.sorted(by: Self.order)
    }

    /// Worker segments dropped as speaker bleed in the last `transcript(…)` call.
    public private(set) var bleedDropped: Int {
        get { state.withLock { $0.bleedDropped } }
        set { state.withLock { $0.bleedDropped = newValue } }
    }

    public func transcript(sessionId: String, startedAt: Date, retention: Retention) -> Transcript {
        let s = state.withLock { $0 }
        let (kept, dropped) = Self.removingBleed(s.segments)
        bleedDropped = dropped
        let merged = kept.sorted(by: Self.order)
        let segments = merged.enumerated().map { i, seg in
            Transcript.Segment(id: String(format: "s%04d", i + 1), speaker: seg.speaker,
                               start: Self.round(seg.start), end: Self.round(seg.end),
                               text: seg.text, confidence: seg.confidence.map(Self.round))
        }
        let gaps = s.gaps.sorted { ($0.start, $0.track.rawValue) < ($1.start, $1.track.rawValue) }
            .map { Transcript.Gap(track: $0.track, start: Self.round($0.start), end: Self.round($0.end), reason: $0.reason) }
        return Transcript(sessionId: sessionId, startedAt: Self.iso8601(startedAt), retention: retention,
                          tracks: s.tracks, segments: segments, gaps: gaps)
    }

    /// A worker on speakers instead of headphones: the mic hears the client, and the call app's
    /// echo cancellation doesn't apply to our raw mic. Drops a worker segment only if it overlaps
    /// a client segment for most of its length AND says nearly the same words. Anything less
    /// certain stays. Echo cancellation proper is a follow-up (BUILD_PLAN P2.2).
    static func removingBleed(_ segments: [TranscribedSegment]) -> (kept: [TranscribedSegment], dropped: Int) {
        let client = segments.filter { $0.speaker == .client }
        var dropped = 0
        let kept = segments.filter { seg in
            guard seg.speaker == .worker else { return true }
            let length = max(seg.end - seg.start, 0.01)
            let echoed = client.contains { c in
                let overlap = min(seg.end, c.end) - max(seg.start, c.start)
                return overlap / length >= 0.5
                    && WordErrorRate.compute(reference: c.text, hypothesis: seg.text) <= 0.25
            }
            if echoed { dropped += 1 }
            return !echoed
        }
        return (kept, dropped)
    }

    /// Time order; on a tie the worker goes first (they usually asked the question).
    static func order(_ a: TranscribedSegment, _ b: TranscribedSegment) -> Bool {
        a.start != b.start ? a.start < b.start : (a.speaker == .worker && b.speaker == .client)
    }

    static func round(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Local time with offset, like `2026-09-17T14:00:00-07:00`.
    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}
