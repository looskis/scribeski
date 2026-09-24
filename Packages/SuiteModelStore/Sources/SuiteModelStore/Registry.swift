import Foundation

/// `users/<app-id>.json`: the models one app depends on. These files are the GC roots.
public struct AppRegistration: Codable, Sendable, Hashable {
    public struct Model: Codable, Sendable, Hashable {
        public var id: String
        public var revision: String
        /// SHA-256s of every file, so GC knows what's referenced even before a snapshot exists.
        public var blobs: [String]
    }

    public var appID: String
    public var updatedAt: Date
    public var models: [Model]

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case updatedAt = "updated_at"
        case models
    }
}

/// What `garbageCollect` removed (or would remove, for a dry run).
public struct GarbageCollectionReport: Sendable, Hashable {
    public var dryRun: Bool
    public var removedBlobs: [String] = []
    public var removedSnapshots: [String] = []
    public var removedPartials: [String] = []
    /// Blobs that were unreferenced but in use (download lock held), so were left alone.
    public var skippedBusy: [String] = []
    public var bytesFreed: Int64 = 0
}

extension ModelStore {
    static func registrationEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func registrationDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func registrationURL(app: String) -> URL { usersDirectory.appendingPathComponent("\(app).json") }

    /// Records that `app` depends on exactly `models` (replacing its previous set). Anything no
    /// app references becomes eligible for `garbageCollect`.
    public func register(app: String, models: [ModelManifest]) async throws {
        guard ModelManifest.isSafeComponent(app) else { throw ModelStoreError.invalidAppID(app) }
        for m in models { try m.validate() }
        let reg = AppRegistration(
            appID: app, updatedAt: Date(),
            models: models.map { .init(id: $0.id, revision: $0.revision, blobs: $0.files.map(\.sha256)) })
        let data = try Self.registrationEncoder().encode(reg)
        let lock = try await FileLock.acquire(storeLockURL)
        defer { lock.release() }
        try data.write(to: registrationURL(app: app), options: .atomic)
    }

    /// Removes `app`'s registration (e.g. on uninstall or "remove downloaded models").
    public func unregister(app: String) async throws {
        guard ModelManifest.isSafeComponent(app) else { throw ModelStoreError.invalidAppID(app) }
        let lock = try await FileLock.acquire(storeLockURL)
        defer { lock.release() }
        let url = registrationURL(app: app)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// All apps' registrations. Throws if any file is unreadable — GC must never guess.
    public func registrations() throws -> [AppRegistration] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: usersDirectory.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.map {
            try Self.registrationDecoder().decode(
                AppRegistration.self, from: Data(contentsOf: usersDirectory.appendingPathComponent($0)))
        }
    }

    /// Removes blobs, snapshots and partial downloads that no registered app references.
    /// Never removes anything referenced, and skips blobs whose download lock is held.
    @discardableResult
    public func garbageCollect(dryRun: Bool = false) async throws -> GarbageCollectionReport {
        let fm = FileManager.default
        let storeLock = try await FileLock.acquire(storeLockURL)
        defer { storeLock.release() }

        let regs = try registrations()
        var liveBlobs = Set<String>()
        var liveSnapshots = Set<String>()
        for reg in regs {
            for m in reg.models {
                liveBlobs.formUnion(m.blobs.map { $0.lowercased() })
                liveSnapshots.insert("\(m.id)@\(m.revision)")
            }
        }

        var report = GarbageCollectionReport(dryRun: dryRun)

        func size(_ url: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }

        /// Removes `url` while holding the blob's download lock, so nobody is mid-download or
        /// mid-publish for that sha. Returns false if the lock is busy.
        func removeUnderBlobLock(_ sha: String, _ url: URL) throws -> Bool {
            guard let lock = try FileLock.tryAcquire(blobLockURL(sha256: sha)) else { return false }
            defer { lock.release() }
            guard fm.fileExists(atPath: url.path) else { return true }
            report.bytesFreed += size(url)
            if !dryRun { try fm.removeItem(at: url) }
            return true
        }

        for name in try fm.contentsOfDirectory(atPath: blobsDirectory.path).sorted() {
            guard name.hasPrefix("sha256-") else { continue }
            let sha = String(name.dropFirst("sha256-".count))
            guard !liveBlobs.contains(sha) else { continue }
            if try removeUnderBlobLock(sha, blobsDirectory.appendingPathComponent(name)) {
                report.removedBlobs.append(sha)
            } else {
                report.skippedBusy.append(sha)
            }
        }

        for name in try fm.contentsOfDirectory(atPath: snapshotsDirectory.path).sorted() {
            // Staging dirs only exist while someone holds the store lock (we do), so any found
            // now are crash leftovers.
            guard !liveSnapshots.contains(name) else { continue }
            if !dryRun { try fm.removeItem(at: snapshotsDirectory.appendingPathComponent(name)) }
            report.removedSnapshots.append(name)
        }

        for name in try fm.contentsOfDirectory(atPath: tmpDirectory.path).sorted() {
            guard name.hasSuffix(".partial") else { continue }
            let sha = String(name.dropLast(".partial".count))
            guard !liveBlobs.contains(sha) else { continue }  // keep: resumable
            if try removeUnderBlobLock(sha, tmpDirectory.appendingPathComponent(name)) {
                report.removedPartials.append(sha)
            } else {
                report.skippedBusy.append(sha)
            }
        }
        return report
    }
}
