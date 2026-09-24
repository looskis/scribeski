import Foundation


/// The plain-text transcript format used by fixtures and by the extraction prompt.
///
/// Fixture input:
/// ```
/// # session_date: 2026-09-17
/// # started_at: 2026-09-17T14:00:00-07:00
/// [00:04] WORKER: Hi, can you hear me okay?
/// [00:07] CLIENT: Yeah, I can hear you.
/// ```
/// Prompt rendering adds segment ids: `[00:04] s0001 WORKER: Hi, can you hear me okay?`
public enum TranscriptText {
    public struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// Parses fixture text. Header lines (`# key: value`) are returned as metadata; blank
    /// lines are ignored. Segment ids are assigned in file order. A segment ends where the
    /// next one starts (fixtures carry no end times).
    public static func parse(
        _ text: String, sessionId: String, source: String = "fixture"
    ) throws(ParseError) -> (transcript: Transcript, metadata: [String: String]) {
        var metadata: [String: String] = [:]
        var rows: [(speaker: Speaker, start: Double, text: String)] = []

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let colon = body.firstIndex(of: ":") {
                    let key = body[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    metadata[key] = value
                }
                continue
            }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
                throw ParseError(line: lineNumber, message: "expected [mm:ss]")
            }
            guard let start = parseTimestamp(line[line.index(after: line.startIndex)..<close]) else {
                throw ParseError(line: lineNumber, message: "bad timestamp")
            }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else {
                throw ParseError(line: lineNumber, message: "expected SPEAKER:")
            }
            guard let speaker = Speaker(rawValue: rest[..<colon].lowercased()) else {
                throw ParseError(line: lineNumber, message: "unknown speaker \(rest[..<colon])")
            }
            if let previous = rows.last, start < previous.start {
                throw ParseError(line: lineNumber, message: "timestamp goes backwards")
            }
            let utterance = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            rows.append((speaker, start, utterance))
        }

        var segments: [Transcript.Segment] = []
        for (i, row) in rows.enumerated() {
            let wordCount = Double(row.text.split(separator: " ").count)
            let estimatedEnd = row.start + max(1, wordCount * 0.4)
            let end = i + 1 < rows.count ? max(row.start, rows[i + 1].start) : estimatedEnd
            segments.append(.init(id: segmentID(i + 1), speaker: row.speaker,
                                  start: row.start, end: end, text: row.text))
        }

        let transcript = Transcript(
            sessionId: sessionId,
            startedAt: metadata["started_at"],
            retention: .none,
            tracks: [.worker: .init(source: "\(source):worker"), .client: .init(source: "\(source):client")],
            segments: segments
        )
        return (transcript, metadata)
    }

    /// Renders the prompt prefix. Byte-identical across every field request for a session;
    /// the prefix cache depends on it.
    public static func renderForPrompt(_ transcript: Transcript) -> String {
        transcript.segments
            .map { "[\(formatTimestamp($0.start))] \($0.id) \($0.speaker.rawValue.uppercased()): \($0.text)" }
            .joined(separator: "\n")
    }

    public static func segmentID(_ n: Int) -> String {
        let digits = String(n)
        return "s" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// `mm:ss` or `h:mm:ss` → seconds.
    static func parseTimestamp(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let values = parts.map { $0! }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(values.reduce(0) { $0 * 60 + $1 })
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (m, s) = (total / 60, total % 60)
        return (m < 10 ? "0" : "") + "\(m):" + (s < 10 ? "0" : "") + "\(s)"
    }
}
