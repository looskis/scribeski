import CryptoKit
import Foundation
import ScribeskiCore

/// Append-only, hash-chained audit log (DESIGN §8, BUILD_PLAN P3.5). Each line is one JSON
/// event carrying the SHA-256 of the line before it, so an edit or deletion anywhere breaks
/// the chain from that point on. It survives purge.
///
/// It records what happened and what the machine wrote, never what was said: no transcript
/// text, no field values. Field keys, statuses, confidences, counts, model IDs, times.
public final class AuditLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public struct Entry: Codable, Sendable, Hashable {
        public var seq: Int
        public var time: Date
        public var session: String
        public var event: String
        public var details: [String: String]
        public var prev: String
        public var hash: String
    }

    public enum Verification: Equatable, Sendable {
        case intact(entries: Int)
        case broken(atSeq: Int, reason: String)
    }

    public init(url: URL = SessionStore.defaultRoot.appendingPathComponent("audit.jsonl")) {
        self.url = url
    }

    static let genesis = String(repeating: "0", count: 64)

    @discardableResult
    public func append(session: String, event: String, _ details: [String: String] = [:], at time: Date = .now) throws -> Entry {
        try lock.withLock {
            let last = try entries().last
            var entry = Entry(seq: (last?.seq ?? 0) + 1, time: time, session: session, event: event,
                              details: details, prev: last?.hash ?? Self.genesis, hash: "")
            entry.hash = try Self.digest(entry)
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            return entry
        }
    }

    public func entries() throws -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try data.split(separator: 0x0A).map { try Self.decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Walks the chain from the first line.
    public func verify() -> Verification {
        guard let lines = try? Data(contentsOf: url).split(separator: 0x0A) else { return .intact(entries: 0) }
        var prev = Self.genesis
        for (i, line) in lines.enumerated() {
            guard let e = try? Self.decoder.decode(Entry.self, from: Data(line)) else {
                return .broken(atSeq: i + 1, reason: "unreadable line")
            }
            if e.seq != i + 1 { return .broken(atSeq: i + 1, reason: "sequence gap (a line was removed)") }
            if e.prev != prev { return .broken(atSeq: e.seq, reason: "doesn't follow the previous entry") }
            guard let expected = try? Self.digest(e), expected == e.hash else {
                return .broken(atSeq: e.seq, reason: "contents changed after writing")
            }
            prev = e.hash
        }
        return .intact(entries: lines.count)
    }

    /// SHA-256 over the entry with an empty `hash`, in canonical (sorted-key) JSON.
    static func digest(_ entry: Entry) throws -> String {
        var e = entry
        e.hash = ""
        return SHA256.hash(data: try encoder.encode(e)).map { String(format: "%02x", $0) }.joined()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
