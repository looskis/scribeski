import Foundation
import ScribeskiCore
import Testing
@testable import Storage

/// The encrypted audio copy (BUILD_PLAN P2.6).
@Suite(.serialized) struct AudioVaultBehaviour {
    /// A recognisable ramp, so any misplaced sample shows.
    static func ramp(_ n: Int, from: Int = 0) -> [Int16] { (0..<n).map { Int16(truncatingIfNeeded: from + $0) } }

    static func append(_ v: AudioVault, _ s: Speaker, _ samples: [Int16], at t: Double) {
        samples.withUnsafeBufferPointer { v.append(s, $0, at: t) }
    }

    @Test func roundTripsExactlyAndNothingIsPlaintext() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV1", retention: .untilConfirm)
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV1")
        let audio = Self.ramp(40_000) // 2.5 s: two whole chunks and a partial
        Self.append(vault, .client, audio, at: 10)
        vault.finish()

        let back = try AudioVault.read(box.store, sessionID: "SES-AV1", speaker: .client, from: 10, to: 12.5)
        #expect(back == audio)
        let middle = try AudioVault.read(box.store, sessionID: "SES-AV1", speaker: .client, from: 11, to: 11.5)
        #expect(middle == Array(audio[16_000..<24_000]))
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV1", speaker: .worker, from: 0, to: 99).isEmpty)
        #expect(abs(AudioVault.seconds(box.store, sessionID: "SES-AV1", speaker: .client) - 2.5) < 0.001)

        let raw = try Data(contentsOf: AudioVault.fileURL(box.store, "SES-AV1", .client))
        let plain = audio.prefix(64).withUnsafeBytes { Data($0) }
        #expect(raw.range(of: plain) == nil, "no plaintext audio on disk")
    }

    @Test func utterancesKeepTheirOwnTimes() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV2", retention: .days(7))
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV2")
        let first = Self.ramp(8_000), second = Self.ramp(8_000, from: 20_000)
        Self.append(vault, .worker, first, at: 1)   // 1.0–1.5 s
        Self.append(vault, .worker, second, at: 5)  // 5.0–5.5 s, after a silence
        vault.finish()
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV2", speaker: .worker, from: 5, to: 5.5) == second)
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV2", speaker: .worker, from: 2, to: 4.9).isEmpty)
    }

    @Test func chunksCantBeReorderedOrMovedBetweenSessions() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV3", retention: .untilConfirm)
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV3")
        Self.append(vault, .client, Self.ramp(32_000), at: 0)
        vault.finish()
        let url = AudioVault.fileURL(box.store, "SES-AV3", .client)
        let frames = try AudioVault.frames(url)
        #expect(frames.count == 2)
        // Swap the two chunks: both now fail their associated data and are skipped.
        var swapped = Data()
        for f in frames.reversed() {
            var len = UInt32(f.count).bigEndian
            swapped.append(Data(bytes: &len, count: 4))
            swapped.append(f)
        }
        try swapped.write(to: url)
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV3", speaker: .client, from: 0, to: 2).isEmpty)
    }

    @Test func aTornFinalWriteLosesOnlyThatChunk() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV4", retention: .untilConfirm)
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV4")
        Self.append(vault, .client, Self.ramp(48_000), at: 0)
        vault.finish()
        let url = AudioVault.fileURL(box.store, "SES-AV4", .client)
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 100).write(to: url) // crash mid-write of the third second
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV4", speaker: .client, from: 0, to: 3) == Self.ramp(32_000))

        // Writing again after the crash drops the torn bytes and carries on.
        let again = try AudioVault(store: box.store, sessionID: "SES-AV4")
        Self.append(again, .client, Self.ramp(16_000, from: 7), at: 2)
        again.finish()
        #expect(try AudioVault.read(box.store, sessionID: "SES-AV4", speaker: .client, from: 2, to: 3) == Self.ramp(16_000, from: 7))
    }

    @Test func untilConfirmDestroysAudioAtConfirmAndKeepsTheTranscript() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV5", retention: .untilConfirm)
        try box.store.seal(Data("transcript".utf8), as: "transcript", in: "SES-AV5")
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV5")
        Self.append(vault, .client, Self.ramp(16_000), at: 0)
        vault.finish()
        #expect(box.store.hasAudio("SES-AV5"))

        try box.store.confirm("SES-AV5", transcriptDays: 30)
        #expect(!box.store.hasAudio("SES-AV5"))
        #expect(!box.keys.exists(AudioVault.audioKeyID("SES-AV5")))
        #expect(throws: (any Error).self) {
            try AudioVault.read(box.store, sessionID: "SES-AV5", speaker: .client, from: 0, to: 1)
        }
        #expect(try box.store.open("transcript", in: "SES-AV5") == Data("transcript".utf8))
    }

    @Test func daysRetentionPurgesAudioOnItsOwnSchedule() throws {
        let box = Sandbox()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        try box.store.create(id: "SES-AV6", retention: .days(3), at: created)
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV6")
        Self.append(vault, .worker, Self.ramp(16_000), at: 0)
        vault.finish()
        try box.store.update("SES-AV6", stage: "reviewing")

        #expect(try box.store.purgeDue(now: created.addingTimeInterval(2 * 86_400)).isEmpty)
        #expect(box.store.hasAudio("SES-AV6"))
        #expect(try box.store.purgeDue(now: created.addingTimeInterval(4 * 86_400)).isEmpty, "the session stays")
        #expect(!box.store.hasAudio("SES-AV6"))
        #expect(box.keys.exists("SES-AV6"))
    }

    @Test func purgeDestroysBothKeys() throws {
        let box = Sandbox()
        try box.store.create(id: "SES-AV7", retention: .days(7))
        let vault = try AudioVault(store: box.store, sessionID: "SES-AV7")
        Self.append(vault, .client, Self.ramp(1_000), at: 0)
        vault.finish()
        try box.store.purge("SES-AV7")
        #expect(!box.keys.exists("SES-AV7"))
        #expect(!box.keys.exists(AudioVault.audioKeyID("SES-AV7")))
    }
}
