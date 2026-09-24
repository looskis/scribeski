import Capture
import Foundation
import ScribeskiCore

/// Speech-to-text behind one interface (BUILD_PLAN P2.4). Every engine runs in-process:
/// no transcription sidecar, so no audio crosses a process boundary (DESIGN §3).
public protocol Transcriber: Sendable {
    /// Short engine name, recorded with the session.
    var engine: String { get }

    /// Loads the model and installs any OS assets. Call once, before the session.
    /// `vocabulary` biases recognition toward program acronyms, drug names, staff names.
    func prepare(locale: Locale, vocabulary: [String]) async throws

    /// Transcribes one track as its utterances arrive. Only final text comes out, in time
    /// order. The output ends once `utterances` ends and everything has been finalized.
    func transcribe(speaker: Speaker, utterances: UtteranceQueue) -> AsyncThrowingStream<TranscribedSegment, Error>

    /// The backlog passed half its cap: trade accuracy for speed if the engine can
    /// (BUILD_PLAN P2.3). Returns what it did, for the audit trail.
    func degrade(speaker: Speaker) -> String?
}

extension Transcriber {
    public func degrade(speaker: Speaker) -> String? { nil }
}

/// What the backlog did, in order. P2.3 requires degrade → alert → gap, never a spill.
public enum BacklogEvent: Sendable, Equatable {
    /// Past 50% of the cap. `action` is what the engine did about it, if anything.
    case degraded(Speaker, action: String?)
    /// At the cap: the worker is told, and the oldest untranscribed audio is being dropped.
    case alert(Speaker)
    /// Back under 25%.
    case recovered(Speaker)
}

/// Final text for a stretch of one track, on the capture clock.
public struct TranscribedSegment: Sendable, Hashable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Double?

    public init(speaker: Speaker, start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case localeNotSupported(String)
    case notPrepared
    case modelMissing(String)
    case sourceNotFound(String)

    public var description: String {
        switch self {
        case .localeNotSupported(let l): "Speech recognition doesn't support \(l)."
        case .notPrepared: "The transcriber wasn't prepared."
        case .modelMissing(let m): "Speech model not found: \(m)"
        case .sourceNotFound(let s): "No app is playing audio as \(s)."
        }
    }
}
