import CryptoKit
import Foundation
import ScribeskiCore

/// Session data at rest (BUILD_PLAN P3.5). Everything session-derived (transcript, field
/// results, fill reports) is sealed with the session's key (AES-GCM, AAD = session/name).
/// `meta.json` holds only what the retention scheduler needs: no names, no text.
///
/// The data directory is excluded from Time Machine and Spotlight, and `verifyExclusions`
/// checks both rather than assuming.
public final class SessionStore: @unchecked Sendable {
    public let root: URL
    public let keys: SessionKeys
    private let lock = NSLock()

    public struct Meta: Codable, Sendable, Hashable {
        public var id: String
        public var created: Date
        public var retention: Retention
        public var confirmed: Date?
        /// When the session's key is destroyed. Set at confirm (transcript retention).
        public var purgeAfter: Date?
        public var keyBackend: String
        /// How far the session got: recording, transcribing, extracting, readyToFill, filling,
        /// reviewing. What a relaunch resumes from. No client data here.
        public var stage: String?
        /// The learned form (fingerprint) and session template, for resuming.
        public var form: String?
        public var template: String?
    }

    public enum Failure: Error, CustomStringConvertible {
        case unknownSession(String)
        case tampered(String)

        public var description: String {
            switch self {
            case .unknownSession(let id): "No stored session \(id)."
            case .tampered(let what): "\(what) failed authentication: altered, or sealed under another key."
            }
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribeski", isDirectory: true)
    }

    public init(root: URL = SessionStore.defaultRoot, keys: SessionKeys = SessionKeys()) throws {
        self.root = root
        self.keys = keys
        let fm = FileManager.default
        // Earlier builds used `sessions/`: move it under the `.noindex` name.
        let legacy = root.appendingPathComponent("sessions", isDirectory: true)
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: sessionsDirectory.path) {
            try? fm.moveItem(at: legacy, to: sessionsDirectory)
        }
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try applyExclusions()
    }

    /// `.noindex`: Spotlight skips a folder with this suffix anywhere, where
    /// `.metadata_never_index` is only documented to work at a volume's root.
    public var sessionsDirectory: URL { root.appendingPathComponent("sessions.noindex", isDirectory: true) }
    func directory(_ id: String) -> URL { sessionsDirectory.appendingPathComponent(id, isDirectory: true) }

    // MARK: - Exclusions

    /// `.metadata_never_index` keeps Spotlight out; the backup flag keeps Time Machine out.
    private func applyExclusions() throws {
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Reads both exclusions back from disk.
    public func verifyExclusions() -> (spotlight: Bool, backup: Bool) {
        let spotlight = FileManager.default.fileExists(atPath: root.appendingPathComponent(".metadata_never_index").path)
            && sessionsDirectory.lastPathComponent.hasSuffix(".noindex")
        let backup = (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
        return (spotlight, backup ?? false)
    }

    // MARK: - Sessions

    @discardableResult
    public func create(id: String, retention: Retention, at date: Date = .now) throws -> Meta {
        try lock.withLock {
            let backend = try keys.create(for: id)
            try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
            let meta = Meta(id: id, created: date, retention: retention, keyBackend: backend.rawValue,
                            stage: "armed")
            try writeMeta(meta)
            return meta
        }
    }

    public func meta(_ id: String) throws -> Meta {
        let url = directory(id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { throw Failure.unknownSession(id) }
        return try Self.decoder.decode(Meta.self, from: data)
    }

    public func sessions() -> [Meta] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return ids.compactMap { try? meta($0) }.sorted { $0.created < $1.created }
    }

    /// Sessions not yet confirmed: the menu warns at N and refuses to arm at 2N.
    public var unconfirmed: [Meta] { sessions().filter { $0.confirmed == nil && keys.exists($0.id) } }

    public func seal(_ data: Data, as name: String, in id: String) throws {
        let key = try keys.key(for: id)
        let box = try AES.GCM.seal(data, using: key, authenticating: Data("\(id)/\(name)".utf8))
        try box.combined!.write(to: directory(id).appendingPathComponent("\(name).sbk"), options: .atomic)
    }

    public func open(_ name: String, in id: String) throws -> Data {
        let key = try keys.key(for: id)
        let raw = try Data(contentsOf: directory(id).appendingPathComponent("\(name).sbk"))
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key,
                                    authenticating: Data("\(id)/\(name)".utf8))
        } catch {
            throw Failure.tampered("\(id)/\(name)")
        }
    }

    public func seal<T: Encodable>(_ value: T, as name: String, in id: String) throws {
        try seal(try Self.encoder.encode(value), as: name, in: id)
    }

    public func open<T: Decodable>(_ type: T.Type, _ name: String, in id: String) throws -> T {
        try Self.decoder.decode(T.self, from: open(name, in: id))
    }

    /// Records progress, so a crash resumes from here.
    public func update(_ id: String, stage: String? = nil, form: String? = nil, template: String? = nil) throws {
        try lock.withLock {
            var m = try meta(id)
            if let stage { m.stage = stage }
            if let form { m.form = form }
            if let template { m.template = template }
            try writeMeta(m)
        }
    }

    /// Sessions a relaunch can pick up: not confirmed, key still there, past arming.
    public var resumable: [Meta] {
        sessions().filter { $0.confirmed == nil && $0.stage != nil && $0.stage != "armed" && keys.exists($0.id) }
    }

    public func has(_ name: String, in id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(id).appendingPathComponent("\(name).sbk").path)
    }

    /// The worker confirmed: schedule the key's destruction per transcript retention. Audio
    /// kept "until you confirm" goes now.
    public func confirm(_ id: String, transcriptDays: Int, at date: Date = .now) throws {
        let m = try lock.withLock {
            var m = try meta(id)
            m.confirmed = date
            m.stage = "confirmed"
            m.purgeAfter = Calendar.current.date(byAdding: .day, value: transcriptDays, to: date)
            try writeMeta(m)
            return m
        }
        if m.retention == .untilConfirm { try purgeAudio(id) }
    }

    /// Destroys the keys (the real delete), then removes the files (tidiness, not security).
    public func purge(_ id: String) throws {
        try keys.destroy(AudioVault.audioKeyID(id))
        try keys.destroy(id)
        try? FileManager.default.removeItem(at: directory(id))
    }

    /// Destroys a session's audio (its own key), keeping the transcript and notes.
    public func purgeAudio(_ id: String) throws {
        try keys.destroy(AudioVault.audioKeyID(id))
        for speaker in Speaker.allCases {
            try? FileManager.default.removeItem(at: AudioVault.fileURL(self, id, speaker))
        }
    }

    /// Whether a session still has audio that can be played.
    public func hasAudio(_ id: String) -> Bool {
        keys.exists(AudioVault.audioKeyID(id))
            && Speaker.allCases.contains { FileManager.default.fileExists(atPath: AudioVault.fileURL(self, id, $0).path) }
    }

    /// When a session's audio is due to go: at confirm, or N days after the session.
    static func audioDue(_ m: Meta, now: Date) -> Bool {
        switch m.retention {
        case .none: false
        case .untilConfirm: m.confirmed != nil
        case .days(let n): (Calendar.current.date(byAdding: .day, value: n, to: m.created) ?? .distantFuture) <= now
        }
    }

    /// What a retention pass did. Failures don't stop the pass; they're reported for the audit.
    public struct PurgeReport: Sendable, Equatable {
        public var purged: [String: String] = [:]        // session → reason
        public var audioPurged: [String] = []
        public var failed: [String: String] = [:]        // session → error type
        public var purgedIDs: [String] { purged.keys.sorted() }
    }

    /// Purges, each for its reason: confirmed sessions past their transcript retention;
    /// sessions that never got past arming (a capture that failed to start), after an hour;
    /// sessions never reviewed, `unreviewedDays` after they were made (nil: never); and audio
    /// past its own retention. Run at launch and hourly.
    public func purgeDue(now: Date = .now, unreviewedDays: Int? = nil) -> PurgeReport {
        var report = PurgeReport()
        let all = sessions()
        for m in all {
            let reason: String?
            if (m.purgeAfter ?? .distantFuture) <= now {
                reason = "retention"
            } else if m.stage == "armed", m.confirmed == nil, now.timeIntervalSince(m.created) > 3600 {
                reason = "never_started"
            } else if let days = unreviewedDays, m.confirmed == nil,
                      (Calendar.current.date(byAdding: .day, value: days, to: m.created) ?? .distantFuture) <= now {
                reason = "unreviewed"
            } else {
                reason = nil
            }
            guard let reason else { continue }
            do {
                try purge(m.id)
                report.purged[m.id] = reason
            } catch {
                report.failed[m.id] = "\(type(of: error))"
            }
        }
        for m in all where report.purged[m.id] == nil && Self.audioDue(m, now: now) && hasAudio(m.id) {
            do {
                try purgeAudio(m.id)
                report.audioPurged.append(m.id)
            } catch {
                report.failed[m.id] = "\(type(of: error))"
            }
        }
        return report
    }

    private func writeMeta(_ meta: Meta) throws {
        try Self.encoder.encode(meta).write(to: directory(meta.id).appendingPathComponent("meta.json"), options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
