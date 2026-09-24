import Foundation
import Testing
@testable import SuiteModelStore

@Suite struct StoreTests {
    @Test func contentAddressingDedupesSharedBlobs() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let shared = deterministicBytes(300_000, seed: 1)
        let a = makeManifest(id: "model-a", server: server, files: [
            ("a.bin", deterministicBytes(200_000, seed: 2)), ("shared.bin", shared),
        ])
        let b = makeManifest(id: "model-b", server: server, files: [
            ("b.bin", deterministicBytes(100_000, seed: 3)), ("tokenizer/shared.json", shared),
        ])
        let store = try makeStore(dir, server)

        try await store.ensure(a)
        try await store.ensure(b)

        #expect(try blobNames(store).count == 3)
        #expect(server.requestCount(routePath(a, "shared.bin")) == 1)
        #expect(server.requestCount(routePath(b, "tokenizer/shared.json")) == 0)  // reused, never fetched

        // Calling ensure again is a no-op.
        try await store.ensure(a)
        #expect(server.totalRequests == 3)
    }

    @Test func snapshotSymlinksResolveToReadOnlyBlobs() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let weight = deterministicBytes(150_000, seed: 4)
        let meta = Data(#"{"x":1}"#.utf8)
        let m = makeManifest(id: "coreml-model", format: .coreml, server: server, files: [
            ("Encoder.mlmodelc/weights/weight.bin", weight), ("Encoder.mlmodelc/metadata.json", meta),
            ("vocab.json", meta),
        ])
        let store = try makeStore(dir, server)
        let snap = try await store.ensure(m)

        #expect(snap == store.snapshotURL(for: m))
        #expect(snap.lastPathComponent == "coreml-model@0123abcd")
        #expect(try Data(contentsOf: snap.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")) == weight)
        #expect(try Data(contentsOf: snap.appendingPathComponent("vocab.json")) == meta)

        let fm = FileManager.default
        let dest = try fm.destinationOfSymbolicLink(atPath: snap.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin").path)
        #expect(dest.hasPrefix("../../../../blobs/sha256-"), "relative link: \(dest)")

        let blob = store.blobURL(sha256: sha256Hex(weight))
        let perms = try fm.attributesOfItem(atPath: blob.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o444)
        #expect(store.localURL(for: m) == snap)
        #expect(try blobNames(store).count == 2)  // meta and vocab share content
    }

    @Test func singleFileModelGetsOneSymlink() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let m = makeManifest(id: "tiny-gguf", server: server, files: [("tiny.gguf", deterministicBytes(10_000, seed: 5))])
        let store = try makeStore(dir, server)
        let snap = try await store.ensure(m)
        #expect(try FileManager.default.contentsOfDirectory(atPath: snap.path) == ["tiny.gguf"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: snap.appendingPathComponent("tiny.gguf").path)
            == "../../blobs/sha256-\(m.files[0].sha256)")
    }

    @Test func resumesAfterInterruptedDownload() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let body = deterministicBytes(1_000_000, seed: 6)
        let m = makeManifest(id: "resumable", server: server, files: [("w.gguf", body)])
        server.serve(routePath(m, "w.gguf"), .init(body: body, dropFirstRequestAfter: 64 * 1024 * 5))
        let store = try makeStore(dir, server)

        await #expect(throws: (any Error).self) { try await store.ensure(m) }
        let partial = store.partialURL(sha256: m.files[0].sha256)
        let partialSize = try #require(FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber).intValue
        // URLSession may drop the tail of what was in flight when the connection died; any
        // non-empty prefix is fine as long as the resume request starts right after it.
        #expect(partialSize > 0 && partialSize <= 64 * 1024 * 5)
        #expect(try blobNames(store).isEmpty)

        let snap = try await store.ensure(m)
        #expect(try Data(contentsOf: snap.appendingPathComponent("w.gguf")) == body)
        #expect(server.rangeHeaders(routePath(m, "w.gguf")) == [nil, "bytes=\(partialSize)-"])
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func resumeFallsBackWhenServerIgnoresRange() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let body = deterministicBytes(500_000, seed: 7)
        let m = makeManifest(id: "norange", server: server, files: [("w.gguf", body)])
        server.serve(routePath(m, "w.gguf"), .init(body: body, honorRange: false, dropFirstRequestAfter: 128 * 1024))
        let store = try makeStore(dir, server)
        await #expect(throws: (any Error).self) { try await store.ensure(m) }
        let snap = try await store.ensure(m)
        #expect(try Data(contentsOf: snap.appendingPathComponent("w.gguf")) == body)
    }

    @Test func tamperedBytesThrowHashMismatchAndLeaveNothing() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let good = deterministicBytes(200_000, seed: 8)
        var evil = good
        evil[1234] ^= 0xFF
        let m = makeManifest(id: "tampered", server: server, files: [("w.gguf", good)])
        server.serve(routePath(m, "w.gguf"), evil)
        let store = try makeStore(dir, server)

        do {
            try await store.ensure(m)
            Issue.record("expected hashMismatch")
        } catch let ModelStoreError.hashMismatch(path, expected, actual) {
            #expect(path == "w.gguf")
            #expect(expected == sha256Hex(good))
            #expect(actual == sha256Hex(evil))
        }
        #expect(try blobNames(store).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.tmpDirectory.path).isEmpty)
        #expect(store.localURL(for: m) == nil)
    }

    @Test func oversizedResponseIsRejected() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let good = deterministicBytes(100_000, seed: 9)
        let m = makeManifest(id: "oversize", server: server, files: [("w.gguf", good)])
        server.serve(routePath(m, "w.gguf"), good + Data(count: 70_000))
        let store = try makeStore(dir, server)
        await #expect(throws: ModelStoreError.self) { try await store.ensure(m) }
        #expect(try blobNames(store).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.tmpDirectory.path).isEmpty)
    }

    @Test func concurrentEnsureDownloadsOnce() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let body = deterministicBytes(640 * 1024, seed: 10)
        let m = makeManifest(id: "concurrent", server: server, files: [("w.gguf", body)])
        server.serve(routePath(m, "w.gguf"), .init(body: body, chunkDelay: 0.01))
        let store = try makeStore(dir, server)

        async let one = store.ensure(m)
        async let two = store.ensure(m)
        let (u1, u2) = try await (one, two)
        #expect(u1 == u2)
        #expect(server.requestCount(routePath(m, "w.gguf")) == 1)
    }

    @Test func separateStoreInstancesShareLocksAndBlobs() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let body = deterministicBytes(640 * 1024, seed: 11)
        let m = makeManifest(id: "two-apps", server: server, files: [("w.gguf", body)])
        server.serve(routePath(m, "w.gguf"), .init(body: body, chunkDelay: 0.01))
        let appA = try makeStore(dir, server)
        let appB = try makeStore(dir, server)

        // The store-wide lock excludes across instances.
        let held = try #require(try FileLock.tryAcquire(appA.storeLockURL))
        #expect(try FileLock.tryAcquire(appB.storeLockURL) == nil)
        held.release()
        let again = try #require(try FileLock.tryAcquire(appB.storeLockURL))
        again.release()

        // Second app waits for the first app's download, then reuses it.
        let waited = WaitFlag()
        async let a = appA.ensure(m)
        try await Task.sleep(for: .milliseconds(30))
        async let b = appB.ensure(m) { if $0.phase == .waitingForLock { waited.set() } }
        _ = try await (a, b)
        #expect(server.requestCount(routePath(m, "w.gguf")) == 1)
        #expect(waited.value)
    }

    @Test func diskSpacePreflight() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let m = makeManifest(id: "big", server: server, files: [("w.gguf", deterministicBytes(50_000, seed: 12))])
        let store = try makeStore(dir, server, available: 10_000)
        do {
            try await store.ensure(m)
            Issue.record("expected insufficientDiskSpace")
        } catch let ModelStoreError.insufficientDiskSpace(required, available) {
            #expect(required == 50_000)
            #expect(available == 10_000)
        }
        #expect(server.totalRequests == 0)
    }

    @Test func progressStreamReportsBytesThenCompletes() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let m = makeManifest(id: "progress", server: server, files: [
            ("a.bin", deterministicBytes(3 * 1024 * 1024, seed: 13)), ("b.bin", deterministicBytes(1000, seed: 14)),
        ])
        let store = try makeStore(dir, server)
        var events: [EnsureEvent] = []
        for try await e in store.ensureStream(m) { events.append(e) }
        guard case let .completed(url)? = events.last else { Issue.record("no completion"); return }
        #expect(url == store.snapshotURL(for: m))
        let progress = events.compactMap { if case let .progress(p) = $0 { p } else { nil } }
        #expect(progress.contains { $0.phase == .downloading })
        #expect(progress.last?.totalBytesCompleted == m.totalSize)
        #expect(progress.last?.totalBytes == m.totalSize)
    }

    @Test func verifyDetectsAndRemovesCorruptBlob() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let body = deterministicBytes(100_000, seed: 15)
        let m = makeManifest(id: "verify", server: server, files: [("w.gguf", body)])
        let store = try makeStore(dir, server)
        try await store.ensure(m)
        #expect(try await store.verify(m).isValid)

        // Simulate on-disk corruption (bit rot or a tampering process that got around 0444).
        let blob = store.blobURL(sha256: m.files[0].sha256)
        chmod(blob.path, 0o644)
        var bad = body
        bad[0] ^= 1
        try bad.write(to: blob)
        let report = try await store.verify(m)
        #expect(report.corrupt == ["w.gguf"])
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        #expect(store.localURL(for: m) == nil)

        try await store.ensure(m)  // re-downloads
        #expect(try await store.verify(m).isValid)
    }

    @Test func storeIsExcludedFromBackupAndSpotlight() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let store = try makeStore(dir, server)
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".metadata_never_index").path))
        for sub in ["blobs", "snapshots", "users", "tmp"] {
            #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(sub).path))
        }
    }

    @Test func unsafeManifestsAreRejected() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let store = try makeStore(dir, server)
        var m = makeManifest(id: "evil", server: server, files: [("ok.bin", Data([1]))])
        m.files[0].path = "../../../etc/evil"
        await #expect(throws: ModelStoreError.self) { try await store.ensure(m) }
        m.files[0].path = "ok.bin"
        m.id = "../escape"
        await #expect(throws: ModelStoreError.self) { try await store.ensure(m) }
        m.id = "evil"
        m.files[0].sha256 = "nothex"
        await #expect(throws: ModelStoreError.self) { try await store.ensure(m) }
        #expect(server.totalRequests == 0)
    }
}

final class WaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@Suite struct GarbageCollectionTests {
    @Test func keepsReferencedRemovesUnreferenced() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let shared = deterministicBytes(50_000, seed: 20)
        let a = makeManifest(id: "keep-me", server: server, files: [("a.bin", deterministicBytes(40_000, seed: 21)), ("s.bin", shared)])
        let b = makeManifest(id: "drop-me", server: server, files: [("b.bin", deterministicBytes(30_000, seed: 22)), ("s.bin", shared)])
        let store = try makeStore(dir, server)
        try await store.register(app: "com.example.scribeski", models: [a])
        try await store.ensure(a)
        try await store.ensure(b)
        #expect(try blobNames(store).count == 3)

        // An abandoned partial of an unreferenced blob.
        let orphan = store.partialURL(sha256: String(repeating: "e", count: 64))
        try Data([1, 2, 3]).write(to: orphan)

        let dry = try await store.garbageCollect(dryRun: true)
        #expect(dry.removedBlobs == [b.files[0].sha256])
        #expect(dry.removedSnapshots == ["drop-me@0123abcd"])
        #expect(dry.bytesFreed == 30_003)
        #expect(try blobNames(store).count == 3)  // dry run touched nothing

        let report = try await store.garbageCollect()
        #expect(report.removedBlobs == [b.files[0].sha256])
        #expect(report.removedPartials == [String(repeating: "e", count: 64)])
        #expect(try blobNames(store).count == 2)
        #expect(store.localURL(for: a) != nil)
        #expect(store.localURL(for: b) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.snapshotURL(for: b).path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func referencesFromAnyAppAreKept() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let a = makeManifest(id: "one", server: server, files: [("a.bin", deterministicBytes(1000, seed: 23))])
        let b = makeManifest(id: "two", server: server, files: [("b.bin", deterministicBytes(1000, seed: 24))])
        let store = try makeStore(dir, server)
        try await store.register(app: "app-1", models: [a])
        try await store.register(app: "app-2", models: [a, b])
        try await store.ensure(a)
        try await store.ensure(b)
        #expect(try await store.garbageCollect().removedBlobs.isEmpty)

        try await store.register(app: "app-2", models: [])  // app-2 no longer needs b
        #expect(try await store.garbageCollect().removedBlobs == [b.files[0].sha256])
        try await store.unregister(app: "app-1")
        #expect(try await store.garbageCollect().removedBlobs == [a.files[0].sha256])
        #expect(try store.registrations().map(\.appID) == ["app-2"])
    }

    @Test func registeredButNotYetDownloadedPartialIsKept() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let m = makeManifest(id: "pending", server: server, files: [("a.bin", deterministicBytes(1000, seed: 25))])
        let store = try makeStore(dir, server)
        try await store.register(app: "app", models: [m])
        let partial = store.partialURL(sha256: m.files[0].sha256)
        try Data([9]).write(to: partial)
        #expect(try await store.garbageCollect().removedPartials.isEmpty)
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func busyBlobIsSkipped() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let server = StubServer()
        let m = makeManifest(id: "busy", server: server, files: [("a.bin", deterministicBytes(1000, seed: 26))])
        let store = try makeStore(dir, server)
        try await store.ensure(m)
        let lock = try #require(try FileLock.tryAcquire(store.blobLockURL(sha256: m.files[0].sha256)))
        let report = try await store.garbageCollect()
        #expect(report.removedBlobs.isEmpty)
        #expect(report.skippedBusy == [m.files[0].sha256])
        lock.release()
        #expect(try await store.garbageCollect().removedBlobs == [m.files[0].sha256])
    }

    @Test func rejectsUnsafeAppID() async throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let store = try makeStore(dir, StubServer())
        await #expect(throws: ModelStoreError.invalidAppID("../x")) { try await store.register(app: "../x", models: []) }
    }
}
