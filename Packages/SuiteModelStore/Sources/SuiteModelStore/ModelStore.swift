import CryptoKit
import Foundation

/// The per-user, content-addressed model store shared by every app in the suite.
///
/// Layout under `root` (the `Models/` directory):
///
///     blobs/sha256-<hex>                   verified weights, mode 0444
///     snapshots/<id>@<rev>/<path>          relative symlinks into blobs/
///     users/<app-id>.json                  which models each app depends on (GC roots)
///     tmp/<hex>.partial                    resumable partial downloads
///     locks/<hex>.lock                     per-blob download locks (flock)
///     .lock                                store-wide lock for snapshot/registry/GC mutations
///     .metadata_never_index                keeps Spotlight out
///
/// All coordination is through `flock(2)`, so it is correct across tasks, `ModelStore`
/// instances and processes alike. Instances hold no mutable state.
public final class ModelStore: Sendable {
    public let location: StoreLocation
    /// The catalog this store was opened with (the package's built-in catalog by default).
    public let catalog: Catalog
    /// Free space that must remain after a download completes.
    public let diskSpaceMargin: Int64

    let downloader: Downloader
    let availableCapacity: @Sendable (URL) -> Int64?

    public var root: URL { location.root }
    public var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var snapshotsDirectory: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    public var usersDirectory: URL { root.appendingPathComponent("users", isDirectory: true) }
    public var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var locksDirectory: URL { root.appendingPathComponent("locks", isDirectory: true) }
    var storeLockURL: URL { root.appendingPathComponent(".lock") }

    public static let defaultDiskSpaceMargin: Int64 = 2 * 1024 * 1024 * 1024

    /// See `StoreLocation.resolve` for the precedence rules.
    public static func resolveLocation(groupID: String?, suiteName: String) -> StoreLocation {
        StoreLocation.resolve(groupID: groupID, suiteName: suiteName)
    }

    /// Opens (creating if needed) the store at `location`.
    ///
    /// - Parameters:
    ///   - catalog: defaults to `Catalog.builtIn()`.
    ///   - sessionConfiguration: inject `protocolClasses` here to stub the network in tests.
    ///   - availableCapacity: free bytes on the store's volume; defaults to
    ///     `volumeAvailableCapacityForImportantUsage`. Injectable for tests.
    public init(
        location: StoreLocation,
        catalog: Catalog? = nil,
        sessionConfiguration: URLSessionConfiguration = .default,
        diskSpaceMargin: Int64 = ModelStore.defaultDiskSpaceMargin,
        availableCapacity: (@Sendable (URL) -> Int64?)? = nil
    ) throws {
        self.location = location
        self.catalog = try catalog ?? Catalog.builtIn()
        self.diskSpaceMargin = diskSpaceMargin
        self.downloader = Downloader(configuration: sessionConfiguration)
        self.availableCapacity = availableCapacity ?? ModelStore.volumeAvailableCapacity
        try prepare()
    }

    /// Convenience: a store at an explicit directory (tests, tools).
    public convenience init(root: URL, catalog: Catalog? = nil,
                            sessionConfiguration: URLSessionConfiguration = .default,
                            diskSpaceMargin: Int64 = ModelStore.defaultDiskSpaceMargin,
                            availableCapacity: (@Sendable (URL) -> Int64?)? = nil) throws {
        try self.init(
            location: StoreLocation(root: root, source: .environment, reason: "explicit root"),
            catalog: catalog, sessionConfiguration: sessionConfiguration,
            diskSpaceMargin: diskSpaceMargin, availableCapacity: availableCapacity)
    }

    private func prepare() throws {
        let fm = FileManager.default
        for dir in [root, blobsDirectory, snapshotsDirectory, usersDirectory, tmpDirectory, locksDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Weights are re-downloadable and large: keep them out of Time Machine and Spotlight.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
        if !fm.fileExists(atPath: storeLockURL.path) {
            fm.createFile(atPath: storeLockURL.path, contents: nil)
        }
    }

    public static func volumeAvailableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Paths

    public func blobURL(sha256: String) -> URL {
        blobsDirectory.appendingPathComponent("sha256-\(sha256.lowercased())")
    }

    public func snapshotURL(for manifest: ModelManifest) -> URL {
        snapshotsDirectory.appendingPathComponent(manifest.snapshotName, isDirectory: true)
    }

    func partialURL(sha256: String) -> URL { tmpDirectory.appendingPathComponent("\(sha256).partial") }
    func blobLockURL(sha256: String) -> URL { locksDirectory.appendingPathComponent("\(sha256).lock") }

    // MARK: - Lookup

    /// The model's snapshot directory if every file is present with the pinned size, else nil.
    /// Cheap (stat only): blobs are only ever placed after a full SHA-256 check and are read-only;
    /// use `verify` for a full re-hash.
    public func localURL(for manifest: ModelManifest) -> URL? {
        guard (try? manifest.validate()) != nil else { return nil }
        let dir = snapshotURL(for: manifest)
        return isSnapshotComplete(dir, manifest) ? dir : nil
    }

    func isSnapshotComplete(_ dir: URL, _ manifest: ModelManifest) -> Bool {
        let fm = FileManager.default
        for file in manifest.files {
            let link = dir.appendingPathComponent(file.path)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  dest.hasSuffix("blobs/sha256-\(file.sha256)"),
                  blobSize(file.sha256) == file.size
            else { return false }
        }
        return true
    }

    func blobSize(_ sha: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: blobURL(sha256: sha).path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Ensure

    /// Returns the model's snapshot directory, downloading and verifying whatever is missing.
    ///
    /// Blobs shared with other models are stored once. If another task or process is already
    /// downloading a blob, this waits for it and reuses the result. Register the model for your
    /// app (`register(app:models:)`) before or right after calling this: unregistered models are
    /// fair game for `garbageCollect`.
    @discardableResult
    public func ensure(
        _ manifest: ModelManifest,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try manifest.validate()
        if let url = localURL(for: manifest) { return url }

        // Same content under two paths is fetched once.
        var unique: [String: ModelFile] = [:]
        for file in manifest.files where unique[file.sha256] == nil { unique[file.sha256] = file }
        let files = unique.values.sorted { $0.sha256 < $1.sha256 }

        try preflightDiskSpace(files)

        let counter = ProgressCounter(total: files.reduce(0) { $0 + $1.size })
        for attempt in 0..<3 {
            for file in files {
                try Task.checkCancellation()
                try await ensureBlob(file, modelID: manifest.id, counter: counter, progress: progress)
            }
            // Link the snapshot under the store lock so it can't interleave with GC.
            let lock = try await FileLock.acquire(storeLockURL)
            defer { lock.release() }
            if files.allSatisfy({ blobSize($0.sha256) == $0.size }) {
                return try buildSnapshot(manifest)
            }
            // A concurrent GC removed a blob of an unregistered model between download and link.
            if attempt == 2 { break }
            counter.reset()
        }
        throw ModelStoreError.io("blobs for \(manifest.id) kept disappearing; register the model before ensure")
    }

    /// `ensure` as an event stream: `.progress` events, then `.completed(snapshotURL)`.
    public func ensureStream(_ manifest: ModelManifest) -> AsyncThrowingStream<EnsureEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try await self.ensure(manifest) { continuation.yield(.progress($0)) }
                    continuation.yield(.completed(url))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func preflightDiskSpace(_ files: [ModelFile]) throws {
        let fm = FileManager.default
        var needed: Int64 = 0
        for file in files where blobSize(file.sha256) != file.size {
            let partial = (try? fm.attributesOfItem(atPath: partialURL(sha256: file.sha256).path))?[.size]
            let have = (partial as? NSNumber)?.int64Value ?? 0
            needed += max(0, file.size - min(have, file.size))
        }
        guard needed > 0, let available = availableCapacity(root) else { return }
        if available < needed + diskSpaceMargin {
            throw ModelStoreError.insufficientDiskSpace(required: needed + diskSpaceMargin, available: available)
        }
    }

    private func ensureBlob(
        _ file: ModelFile, modelID: String, counter: ProgressCounter,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws {
        @Sendable func emit(_ phase: DownloadProgress.Phase, _ fileBytes: Int64) {
            guard let progress else { return }
            let total = counter.update(file.sha256, fileBytes)
            progress(DownloadProgress(
                modelID: modelID, phase: phase, path: file.path, fileBytesCompleted: fileBytes,
                fileSize: file.size, totalBytesCompleted: total, totalBytes: counter.total))
        }

        let lock = try await FileLock.acquire(blobLockURL(sha256: file.sha256)) {
            emit(.waitingForLock, 0)
        }
        defer { lock.release() }

        let fm = FileManager.default
        let blob = blobURL(sha256: file.sha256)
        if let size = blobSize(file.sha256) {
            if size == file.size {
                emit(.alreadyPresent, file.size)
                return
            }
            try fm.removeItem(at: blob)  // Wrong size: corrupt or truncated. Never trust it.
        }

        let partial = partialURL(sha256: file.sha256)
        try await downloader.download(
            file, to: partial,
            onHashingPartial: { emit(.hashingPartial, 0) },
            onBytes: { emit(.downloading, $0) })

        // Verified: make it read-only and publish atomically.
        guard chmod(partial.path, 0o444) == 0 else {
            throw ModelStoreError.io("chmod 0444 \(partial.path) failed: errno \(errno)")
        }
        guard rename(partial.path, blob.path) == 0 else {
            throw ModelStoreError.io("rename into blobs/ failed: errno \(errno)")
        }
        emit(.fileComplete, file.size)
    }

    /// Caller holds the store lock.
    private func buildSnapshot(_ manifest: ModelManifest) throws -> URL {
        let fm = FileManager.default
        let final = snapshotURL(for: manifest)
        if isSnapshotComplete(final, manifest) { return final }

        let staging = snapshotsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in manifest.files {
                let link = staging.appendingPathComponent(file.path)
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Relative, so the whole store can be moved. Staging has the same depth as final.
                let depth = file.path.split(separator: "/").count
                let target = String(repeating: "../", count: depth + 1) + "blobs/sha256-\(file.sha256)"
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return final
    }

    // MARK: - Verify

    public struct VerificationReport: Sendable, Hashable {
        public var ok: [String] = []
        public var missing: [String] = []
        /// Files whose blob failed the SHA-256 check (removed if `removeCorrupt`).
        public var corrupt: [String] = []
        public var isValid: Bool { missing.isEmpty && corrupt.isEmpty }
    }

    /// Re-hashes every blob of `manifest`. Corrupt blobs are deleted by default so the next
    /// `ensure` re-downloads them.
    public func verify(_ manifest: ModelManifest, removeCorrupt: Bool = true) async throws -> VerificationReport {
        try manifest.validate()
        var report = VerificationReport()
        var verdicts: [String: Bool?] = [:]
        for file in manifest.files {
            if verdicts[file.sha256] == nil {
                let lock = try await FileLock.acquire(blobLockURL(sha256: file.sha256))
                defer { lock.release() }
                let blob = blobURL(sha256: file.sha256)
                if blobSize(file.sha256) == nil {
                    verdicts[file.sha256] = .some(nil)
                } else {
                    let good = try Self.sha256Hex(of: blob) == file.sha256 && blobSize(file.sha256) == file.size
                    if !good && removeCorrupt { try? FileManager.default.removeItem(at: blob) }
                    verdicts[file.sha256] = .some(good)
                }
            }
            switch verdicts[file.sha256]! {
            case .none: report.missing.append(file.path)
            case .some(true): report.ok.append(file.path)
            case .some(false): report.corrupt.append(file.path)
            }
        }
        return report
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Downloader.hashChunk), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Aggregates per-file byte counts into a manifest-wide total for progress events.
final class ProgressCounter: @unchecked Sendable {
    let total: Int64
    private var perFile: [String: Int64] = [:]
    private let lock = NSLock()

    init(total: Int64) { self.total = total }

    func update(_ key: String, _ bytes: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        perFile[key] = bytes
        return perFile.values.reduce(0, +)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        perFile.removeAll()
    }
}
