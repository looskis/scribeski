import CryptoKit
import Foundation
import ScribeskiCore
import Testing
@testable import Storage

/// Each test gets its own directory and Keychain service, and cleans both up.
final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribeski-store-\(UUID())")
    let keys = SessionKeys(service: "com.looski.scribeski.test.\(UUID().uuidString.prefix(8))")
    lazy var store = try! SessionStore(root: root, keys: keys)

    deinit {
        for m in store.sessions() {
            try? keys.destroy(m.id)
            try? keys.destroy(AudioVault.audioKeyID(m.id))
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct SessionStoreBehaviour {
    @Test func sealsAndOpensWithTheSessionKey() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-A", retention: .none)
        try box.store.seal(Data("the client said something private".utf8), as: "transcript", in: "SES-A")
        let raw = try Data(contentsOf: box.store.directory("SES-A").appendingPathComponent("transcript.sbk"))
        #expect(raw.range(of: Data("private".utf8)) == nil, "no plaintext on disk")
        #expect(String(decoding: try box.store.open("transcript", in: "SES-A"), as: UTF8.self)
                == "the client said something private")
    }

    @Test func purgeDestroysTheKeySoDataIsGone() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-B", retention: .untilConfirm)
        try box.store.seal(Data("x".utf8), as: "transcript", in: "SES-B")
        try box.store.purge("SES-B")
        #expect(!box.keys.exists("SES-B"))
        #expect(throws: (any Error).self) { try box.store.open("transcript", in: "SES-B") }
    }

    @Test func tamperingIsDetected() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-C", retention: .none)
        try box.store.seal(Data("hello".utf8), as: "results", in: "SES-C")
        let url = box.store.directory("SES-C").appendingPathComponent("results.sbk")
        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: url)
        #expect(throws: SessionStore.Failure.self) { try box.store.open("results", in: "SES-C") }
    }

    @Test func blobsCantBeSwappedBetweenNames() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-D", retention: .none)
        try box.store.seal(Data("a".utf8), as: "transcript", in: "SES-D")
        let dir = box.store.directory("SES-D")
        try FileManager.default.copyItem(at: dir.appendingPathComponent("transcript.sbk"),
                                         to: dir.appendingPathComponent("results.sbk"))
        #expect(throws: SessionStore.Failure.self) { try box.store.open("results", in: "SES-D") }
    }

    @Test func retentionSchedulerPurgesOnlyWhatsDue() throws {
        let box = Sandbox()
        let day: TimeInterval = 86_400
        try box.store.create(id: "SES-OLD", retention: .none, at: Date(timeIntervalSinceNow: -40 * day))
        try box.store.confirm("SES-OLD", transcriptDays: 30, at: Date(timeIntervalSinceNow: -35 * day))
        try box.store.create(id: "SES-NEW", retention: .none)
        try box.store.confirm("SES-NEW", transcriptDays: 30)
        try box.store.create(id: "SES-OPEN", retention: .none)
        try box.store.update("SES-OPEN", stage: "reviewing")
        #expect(box.store.purgeDue(unreviewedDays: 30).purged == ["SES-OLD": "retention"])
        #expect(box.store.unconfirmed.map(\.id) == ["SES-OPEN"])
    }

    @Test func unreviewedSessionsDontLiveForever() throws {
        let box = Sandbox()
        let day: TimeInterval = 86_400
        try box.store.create(id: "SES-STALE", retention: .none, at: Date(timeIntervalSinceNow: -31 * day))
        try box.store.update("SES-STALE", stage: "reviewing")
        try box.store.create(id: "SES-RECENT", retention: .none, at: Date(timeIntervalSinceNow: -2 * day))
        try box.store.update("SES-RECENT", stage: "reviewing")
        #expect(box.store.purgeDue().purged.isEmpty, "no cap given: kept")
        #expect(box.store.purgeDue(unreviewedDays: 30).purged == ["SES-STALE": "unreviewed"])
        #expect(!box.keys.exists("SES-STALE"))
        #expect(box.keys.exists("SES-RECENT"))
    }

    @Test func dataDirectoryIsExcludedFromSpotlightAndBackups() {
        let box = Sandbox()
        let x = box.store.verifyExclusions()
        #expect(x.spotlight)
        #expect(x.backup)
    }
}

@Suite struct AuditChain {
    func log() -> AuditLog {
        AuditLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID()).jsonl"))
    }

    @Test func appendsAndVerifies() throws {
        let log = log()
        defer { try? FileManager.default.removeItem(at: log.url) }
        try log.append(session: "SES-1", event: "armed", ["consent": "affirmed", "retention": "none"])
        try log.append(session: "SES-1", event: "confirmed")
        #expect(log.verify() == .intact(entries: 2))
        #expect(try log.entries().map(\.seq) == [1, 2])
    }

    @Test func detectsAnEditedLine() throws {
        let log = log()
        defer { try? FileManager.default.removeItem(at: log.url) }
        try log.append(session: "SES-1", event: "filled", ["fields": "12"])
        try log.append(session: "SES-1", event: "confirmed")
        var text = try String(contentsOf: log.url, encoding: .utf8)
        text = text.replacingOccurrences(of: #""fields":"12""#, with: #""fields":"13""#)
        try text.write(to: log.url, atomically: true, encoding: .utf8)
        #expect(log.verify() == .broken(atSeq: 1, reason: "contents changed after writing"))
    }

    @Test func detectsARemovedLine() throws {
        let log = log()
        defer { try? FileManager.default.removeItem(at: log.url) }
        for e in ["armed", "stopped", "confirmed"] { try log.append(session: "SES-1", event: e) }
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        try (lines[0] + "\n" + lines[2] + "\n").write(to: log.url, atomically: true, encoding: .utf8)
        if case .broken(let seq, _) = log.verify() { #expect(seq == 2) } else { Issue.record("not detected") }
    }
}

@Suite(.serialized) struct ClientTags {
    @Test func stablePerInstallAndNormalizedButKeyed() throws {
        let keysA = SessionKeys(service: "com.looski.scribeski.test.tag.\(UUID().uuidString.prefix(8))")
        let keysB = SessionKeys(service: "com.looski.scribeski.test.tag.\(UUID().uuidString.prefix(8))")
        defer { try? keysA.destroy(ClientTagger.keyID); try? keysB.destroy(ClientTagger.keyID) }
        let a = ClientTagger(keys: keysA), b = ClientTagger(keys: keysB)
        let t1 = try a.tag("AB-114322")
        #expect(t1 == (try a.tag(" ab-114322 ")), "same client, same tag")
        #expect(t1 != (try a.tag("AB-114323")))
        #expect(t1 != (try b.tag("AB-114322")), "another install's key gives another tag")
        #expect(!t1.contains("114322") && t1.hasPrefix("ct:") && t1.count == 35)
    }
}

@Suite(.serialized) struct CrashRecovery {
    @Test func unfinishedSessionsAreResumableUntilConfirmedOrPurged() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-ARMED", retention: .none)            // never got going
        try box.store.create(id: "SES-CRASHED", retention: .none)
        try box.store.update("SES-CRASHED", stage: "recording", form: "sha256:f", template: "follow-up")
        try box.store.seal(Data("partial".utf8), as: "transcript-partial", in: "SES-CRASHED")
        try box.store.create(id: "SES-DONE", retention: .none)
        try box.store.update("SES-DONE", stage: "reviewing")
        try box.store.confirm("SES-DONE", transcriptDays: 30)
        try box.store.create(id: "SES-GONE", retention: .none)
        try box.store.update("SES-GONE", stage: "extracting")
        try box.store.purge("SES-GONE")

        #expect(box.store.resumable.map(\.id) == ["SES-CRASHED"])
        let m = try box.store.meta("SES-CRASHED")
        #expect(m.stage == "recording" && m.form == "sha256:f" && m.template == "follow-up")
        #expect(box.store.has("transcript-partial", in: "SES-CRASHED"))
        #expect(!box.store.has("results", in: "SES-CRASHED"))
        #expect(try box.store.meta("SES-DONE").stage == "confirmed")
    }
}
