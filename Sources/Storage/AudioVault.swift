import CryptoKit
import Darwin
import Foundation
import ScribeskiCore

/// The encrypted audio tee (BUILD_PLAN P2.6), only when retention keeps audio. The same 16 kHz
/// Int16 stream the transcriber gets, sealed in 1-second chunks with the session's *audio* key
/// (separate from the transcript's, so "until you confirm" can destroy audio at confirm while
/// the transcript follows its own retention). Each chunk is AES-GCM with its session, track and
/// index as associated data, so chunks can't be reordered or moved between sessions or tracks.
/// Appended to `audio-<track>.sbv` and fsynced every few seconds: after a crash, everything up
/// to the last complete chunk decrypts.
///
/// File: repeated `[UInt32 big-endian length][AES-GCM combined box]`. Plaintext:
/// `[Float64 start seconds][UInt32 index][Int16 samples…]`, little-endian.
public final class AudioVault: @unchecked Sendable {
    public static let sampleRate = 16_000
    static let chunkSamples = 16_000
    static let syncEvery = 5

    private let store: SessionStore
    private let sessionID: String
    private let key: SymmetricKey
    private let lock = NSLock()
    private var tracks: [Speaker: Track] = [:]

    private final class Track {
        let handle: FileHandle
        /// At most one chunk, reserved once so it never reallocates (and leaves no copies).
        var pending: [Int16]
        var pendingStart = 0.0
        var index: UInt32 = 0
        var sinceSync = 0

        init(handle: FileHandle) {
            self.handle = handle
            pending = []
            pending.reserveCapacity(AudioVault.chunkSamples)
        }
    }

    public static func audioKeyID(_ sessionID: String) -> String { "\(sessionID).audio" }

    /// Opens (or creates) the vault for a session. Creates the audio key on first use.
    public init(store: SessionStore, sessionID: String) throws {
        self.store = store
        self.sessionID = sessionID
        let keyID = Self.audioKeyID(sessionID)
        if !store.keys.exists(keyID) { try store.keys.create(for: keyID) }
        key = try store.keys.key(for: keyID)
    }

    deinit { finish() }

    static func fileURL(_ store: SessionStore, _ sessionID: String, _ speaker: Speaker) -> URL {
        store.directory(sessionID).appendingPathComponent("audio-\(speaker.rawValue).sbv")
    }

    /// Adds audio that starts at session time `time`. Seals whole seconds as they fill; a
    /// stretch that doesn't follow on from the last (the silence between utterances) starts a
    /// new chunk, so every chunk is contiguous audio from its start time.
    public func append(_ speaker: Speaker, _ samples: UnsafeBufferPointer<Int16>, at time: Double) {
        lock.withLock {
            guard let track = track(speaker), !samples.isEmpty else { return }
            let expected = track.pendingStart + Double(track.pending.count) / Double(Self.sampleRate)
            if !track.pending.isEmpty, abs(time - expected) > 1.0 / Double(Self.sampleRate) { seal(speaker, track) }
            if track.pending.isEmpty { track.pendingStart = time }
            var offset = 0
            while offset < samples.count {
                let take = min(Self.chunkSamples - track.pending.count, samples.count - offset)
                track.pending.append(contentsOf: UnsafeBufferPointer(rebasing: samples[offset..<offset + take]))
                offset += take
                if track.pending.count == Self.chunkSamples { seal(speaker, track) }
            }
        }
    }

    /// Seals what's left, syncs, and closes. Called at Stop (and on release).
    public func finish() {
        lock.withLock {
            for (speaker, track) in tracks {
                if !track.pending.isEmpty { seal(speaker, track) }
                try? track.handle.synchronize()
                try? track.handle.close()
            }
            tracks = [:]
        }
    }

    private func track(_ speaker: Speaker) -> Track? {
        if let t = tracks[speaker] { return t }
        let url = Self.fileURL(store, sessionID, speaker)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        // Continue after anything already written, dropping a torn final frame.
        let (count, valid) = (try? Self.scan(url)) ?? (0, 0)
        try? handle.truncate(atOffset: UInt64(valid))
        _ = try? handle.seekToEnd()
        let t = Track(handle: handle)
        t.index = UInt32(count)
        tracks[speaker] = t
        return t
    }

    private func seal(_ speaker: Speaker, _ track: Track) {
        let count = track.pending.count
        var plain = Data(capacity: 12 + count * 2)
        var start = track.pendingStart.bitPattern.littleEndian
        var index = track.index.littleEndian
        withUnsafeBytes(of: &start) { plain.append(contentsOf: $0) }
        withUnsafeBytes(of: &index) { plain.append(contentsOf: $0) }
        track.pending.withUnsafeBufferPointer { plain.append(UnsafeBufferPointer(start: $0.baseAddress, count: count)) }
        defer {
            // Plaintext audio doesn't outlive the seal.
            plain.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) }
            track.pending.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) }
            track.pending.removeAll(keepingCapacity: true)
            track.pendingStart += Double(count) / Double(Self.sampleRate)
        }
        guard let box = try? AES.GCM.seal(plain, using: key, authenticating: Self.aad(sessionID, speaker, track.index)),
              let combined = box.combined else { return }
        var length = UInt32(combined.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(combined)
        try? track.handle.write(contentsOf: frame)
        track.index += 1
        track.sinceSync += 1
        if track.sinceSync >= Self.syncEvery {
            try? track.handle.synchronize()
            track.sinceSync = 0
        }
    }

    static func aad(_ sessionID: String, _ speaker: Speaker, _ index: UInt32) -> Data {
        Data("\(sessionID)/audio/\(speaker.rawValue)/\(index)".utf8)
    }

    // MARK: - Reading

    static func frames(_ url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        return ranges(data).map { data[$0] }
    }

    /// Frame count and the byte length they cover (anything after is a torn write).
    static func scan(_ url: URL) throws -> (count: Int, valid: Int) {
        let data = try Data(contentsOf: url)
        let r = ranges(data)
        return (r.count, r.last.map { data.distance(from: data.startIndex, to: $0.upperBound) } ?? 0)
    }

    private static func ranges(_ data: Data) -> [Range<Data.Index>] {
        var out: [Range<Data.Index>] = []
        var i = data.startIndex
        while data.distance(from: i, to: data.endIndex) >= 4 {
            let length = data[i..<i + 4].reduce(0) { ($0 << 8) | Int($1) }
            let start = i + 4
            // A torn final frame (crash mid-write) is ignored: everything before it is intact.
            guard length > 0, data.distance(from: start, to: data.endIndex) >= length else { break }
            out.append(start..<start + length)
            i = start + length
        }
        return out
    }

    /// Decrypts `speaker`'s audio between two session times, in memory only. Chunks that fail
    /// authentication (tampered, or another session's) are skipped.
    public static func read(_ store: SessionStore, sessionID: String, speaker: Speaker,
                            from: Double, to: Double) throws -> [Int16] {
        let key = try store.keys.key(for: audioKeyID(sessionID))
        let url = fileURL(store, sessionID, speaker)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] } // nothing said on that track
        var out: [Int16] = []
        for (n, frame) in try frames(url).enumerated() {
            guard let box = try? AES.GCM.SealedBox(combined: frame),
                  var plain = try? AES.GCM.open(box, using: key, authenticating: aad(sessionID, speaker, UInt32(n))),
                  plain.count >= 12 else { continue }
            defer { plain.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
            let start = Double(bitPattern: plain[plain.startIndex..<plain.startIndex + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
            let samples = (plain.count - 12) / 2
            let end = start + Double(samples) / Double(sampleRate)
            guard end > from, start < to else { continue }
            let lo = max(0, Int(((from - start) * Double(sampleRate)).rounded(.down)))
            let hi = min(samples, Int(((to - start) * Double(sampleRate)).rounded(.up)))
            guard hi > lo else { continue }
            plain.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: 12)
                for s in lo..<hi { out.append(Int16(littleEndian: base.loadUnaligned(fromByteOffset: s * 2, as: Int16.self))) }
            }
        }
        return out
    }

    /// Seconds of audio stored per track (to show recovery coverage).
    public static func seconds(_ store: SessionStore, sessionID: String, speaker: Speaker) -> Double {
        guard let frames = try? frames(fileURL(store, sessionID, speaker)) else { return 0 }
        return frames.reduce(0) { $0 + Double(max($1.count - 28 - 12, 0) / 2) } / Double(sampleRate)
    }
}
