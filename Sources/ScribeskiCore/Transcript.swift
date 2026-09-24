/// What the ears heard. Two single-speaker tracks, merged by time.
public struct Transcript: Codable, Hashable, Sendable {
    public enum Schema: SchemaIdentifier { public static let id = "scribeski.transcript/1" }

    public var schema = SchemaTag<Schema>()
    public var sessionId: String
    /// ISO 8601 wall-clock time of the first sample. Lets extraction resolve relative dates
    /// ("next Thursday") without guessing the year.
    public var startedAt: String?
    public var retention: Retention
    public var tracks: [Speaker: Track]
    public var segments: [Segment]
    public var gaps: [Gap]

    public init(sessionId: String, startedAt: String? = nil, retention: Retention,
                tracks: [Speaker: Track], segments: [Segment], gaps: [Gap] = []) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.retention = retention
        self.tracks = tracks
        self.segments = segments
        self.gaps = gaps
    }

    enum CodingKeys: String, CodingKey {
        case schema, retention, tracks, segments, gaps
        case sessionId = "session_id"
        case startedAt = "started_at"
    }

    public struct Track: Codable, Hashable, Sendable {
        /// e.g. `mic:BuiltInMicrophoneDevice`, `tap:us.zoom.xos`, `fixture:sample-session.txt`.
        public var source: String

        public init(source: String) { self.source = source }
    }

    public struct Segment: Codable, Hashable, Sendable, Identifiable {
        /// `s0001`, `s0002`, … in merged time order.
        public var id: String
        public var speaker: Speaker
        /// Seconds from session start, on the capture clock.
        public var start: Double
        public var end: Double
        public var text: String
        public var confidence: Double?

        public init(id: String, speaker: Speaker, start: Double, end: Double, text: String,
                    confidence: Double? = nil) {
            self.id = id
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
            self.confidence = confidence
        }
    }

    public struct Gap: Codable, Hashable, Sendable {
        public var track: Speaker
        public var start: Double
        public var end: Double
        public var reason: Reason

        public init(track: Speaker, start: Double, end: Double, reason: Reason) {
            self.track = track
            self.start = start
            self.end = end
            self.reason = reason
        }

        public enum Reason: String, Codable, Hashable, Sendable {
            case deviceRebuild = "device_rebuild"
            case transcriberBacklog = "transcriber_backlog"
            case transcriberCrash = "transcriber_crash"
            /// Capture's consumer fell behind the realtime thread and the ring overflowed.
            case captureOverrun = "capture_overrun"
        }
    }
}

/// Audio retention policy, fixed for a session at arm time.
/// Encoded as `"none"`, `"until_confirm"`, or `"days:N"`.
public enum Retention: Codable, Hashable, Sendable {
    /// Zero-recording: audio never touches disk. No playback, no re-transcription.
    case none
    case untilConfirm
    case days(Int)

    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "until_confirm": self = .untilConfirm
        default:
            guard rawValue.hasPrefix("days:"), let n = Int(rawValue.dropFirst(5)), n > 0 else {
                return nil
            }
            self = .days(n)
        }
    }

    public var rawValue: String {
        switch self {
        case .none: "none"
        case .untilConfirm: "until_confirm"
        case .days(let n): "days:\(n)"
        }
    }

    public var retainsAudio: Bool { self != .none }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Retention(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid retention \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
