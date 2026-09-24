import Capture
import Foundation
import ScribeskiCore
import Testing
@testable import Transcription

@Suite struct WERScoring {
    @Test func countsEditsOverReferenceWords() {
        #expect(WordErrorRate.compute(reference: "the cat sat", hypothesis: "the cat sat") == 0)
        #expect(WordErrorRate.compute(reference: "the cat sat", hypothesis: "the bat sat") == 1.0 / 3)
        #expect(WordErrorRate.compute(reference: "the cat sat", hypothesis: "cat sat down") == 2.0 / 3)
        #expect(WordErrorRate.compute(reference: "I've been LOW.", hypothesis: "i've been low") == 0)
    }
}

@Suite struct AssemblerMerging {
    @Test func mergesTracksByTimeAndNumbersSegments() {
        let a = TranscriptAssembler()
        a.noteTracks([.worker: .init(source: "mic:x"), .client: .init(source: "tap:y")])
        a.add(TranscribedSegment(speaker: .client, start: 4.2, end: 6, text: "Fine."))
        a.add(TranscribedSegment(speaker: .worker, start: 1, end: 3.9, text: "How are you?"))
        a.add(Transcript.Gap(track: .client, start: 10, end: 12, reason: .deviceRebuild))
        let t = a.transcript(sessionId: "SES-T", startedAt: .now, retention: .none)
        #expect(t.segments.map(\.id) == ["s0001", "s0002"])
        #expect(t.segments.map(\.speaker) == [.worker, .client])
        #expect(t.gaps.count == 1)
        #expect(t.retention == .none)
    }
}

@Suite struct SpeakerBleed {
    @Test func dropsOnlyOverlappingNearIdenticalWorkerLines() {
        let segs = [
            TranscribedSegment(speaker: .client, start: 8.5, end: 12.3, text: "Hi, yeah. I can hear you. Can you hear me?"),
            TranscribedSegment(speaker: .worker, start: 8.6, end: 12.3, text: "Hi, yeah, I can hear you. Can you hear me?"),
            // Worker echoing the client's words, but later and on purpose: kept.
            TranscribedSegment(speaker: .worker, start: 14, end: 15, text: "Can you hear me? Yes."),
            // Overlapping in time but different words (crosstalk): kept.
            TranscribedSegment(speaker: .worker, start: 9, end: 11, text: "Sorry, go ahead."),
        ]
        let (kept, dropped) = TranscriptAssembler.removingBleed(segs)
        #expect(dropped == 1)
        #expect(kept.count == 3)
        #expect(kept.filter { $0.speaker == .worker }.map(\.text) == ["Can you hear me? Yes.", "Sorry, go ahead."])
    }
}

@Suite struct QueueBackpressure {
    func utterance(_ start: Double, seconds: Double) -> Utterance {
        let b = LockedPCM.make(capacity: Int(seconds * 16_000))
        b.frameLength = b.frameCapacity
        return Utterance(speaker: .client, start: start, buffer: b)
    }

    /// DESIGN §3a: past the cap, drop the oldest untranscribed audio and record a gap. Never spill.
    @Test func overflowDropsOldestAsAGap() async {
        final class Gaps: @unchecked Sendable { var list: [Transcript.Gap] = [] }
        let gaps = Gaps()
        let q = UtteranceQueue(speaker: .client, capacitySeconds: 10) { gaps.list.append($0) }
        for i in 0..<4 { q.push(utterance(Double(i) * 4, seconds: 4)) } // 16 s into a 10 s queue
        #expect(gaps.list.map(\.start) == [0, 4])
        #expect(gaps.list.allSatisfy { $0.reason == .transcriberBacklog })
        q.advance(to: 16)
        q.advance(to: 17) // coalesces
        q.finish()
        var left: [String] = []
        for await item in q {
            switch item {
            case .speech(let u): left.append("speech \(Int(u.start))")
            case .silence(let t): left.append("silence \(Int(t))")
            }
        }
        #expect(left == ["speech 8", "speech 12", "silence 17"])
    }
}

/// Renders `text` with a macOS voice to a 16 kHz WAV.
func tts(_ text: String, voice: String, to url: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
    try p.run()
    p.waitUntilExit()
}

/// Needs the OS speech assets, so it's local-only (CI runners may not have them).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
struct SpeechAnalyzerFromFiles {
    @Test func twoTracksBecomeOneTimeOrderedTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribeski-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workerText = "How have you been sleeping since we last spoke?"
        let clientText = "Not great. I wake up around three most nights and can't get back to sleep."
        try tts(workerText, voice: "Samantha", to: dir.appendingPathComponent("w.wav"))
        try tts(clientText, voice: "Daniel", to: dir.appendingPathComponent("c.wav"))

        let transcriber = SpeechAnalyzerTranscriber()
        try await transcriber.prepare(locale: Locale(identifier: "en_US"), vocabulary: [])
        let live = LiveTranscription(retention: .none, transcriber: transcriber)
        live.noteTrack(.worker, source: "file:w.wav")
        live.noteTrack(.client, source: "file:c.wav")
        try await FileTrack.run(dir.appendingPathComponent("w.wav"), speaker: .worker, offset: 0) { live.submit($0) }
        try await FileTrack.run(dir.appendingPathComponent("c.wav"), speaker: .client, offset: 4) { live.submit($0) }
        let t = await live.stop()

        #expect(t.tracks.count == 2)
        #expect(t.segments.first?.speaker == .worker)
        #expect(t.segments.last?.speaker == .client)
        #expect(t.segments.first { $0.speaker == .client }!.start >= 3.7)
        let worker = t.segments.filter { $0.speaker == .worker }.map(\.text).joined(separator: " ")
        let client = t.segments.filter { $0.speaker == .client }.map(\.text).joined(separator: " ")
        #expect(WordErrorRate.compute(reference: workerText, hypothesis: worker) < 0.15, "\(worker)")
        #expect(WordErrorRate.compute(reference: clientText, hypothesis: client) < 0.15, "\(client)")
    }
}

/// Needs the Parakeet weights in the shared store (`scribeski models pull`), so local-only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil && (try? ParakeetTranscriber.fromModelStore()) != nil))
struct ParakeetFromFiles {
    @Test func transcribesInjectedTracks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribeski-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "Not great. I wake up around three most nights and can't get back to sleep."
        try tts(text, voice: "Daniel", to: dir.appendingPathComponent("c.wav"))

        let transcriber = try ParakeetTranscriber.fromModelStore()
        try await transcriber.prepare(locale: Locale(identifier: "en_US"), vocabulary: [])
        let live = LiveTranscription(retention: .none, transcriber: transcriber)
        try await FileTrack.run(dir.appendingPathComponent("c.wav"), speaker: .client, offset: 2) { live.submit($0) }
        let t = await live.stop()
        let client = t.segments.map(\.text).joined(separator: " ")
        #expect(WordErrorRate.compute(reference: text, hypothesis: client) < 0.1, "\(client)")
        #expect(t.segments.first.map { $0.start >= 2 } == true)
    }
}

/// A transcriber that takes twice as long as the audio: guaranteed to fall behind.
final class SlowTranscriber: Transcriber, @unchecked Sendable {
    let engine = "slow-test"
    func prepare(locale: Locale, vocabulary: [String]) async throws {}
    func degrade(speaker: Speaker) -> String? { "switched to fast mode (test)" }
    func transcribe(speaker: Speaker, utterances: UtteranceQueue) -> AsyncThrowingStream<TranscribedSegment, Error> {
        AsyncThrowingStream { c in
            Task {
                for await item in utterances {
                    guard case .speech(let u) = item else { continue }
                    try? await Task.sleep(for: .milliseconds(Int(u.duration * 20))) // 2x at 1/100 time scale
                    c.yield(TranscribedSegment(speaker: speaker, start: u.start, end: u.end, text: "words"))
                }
                c.finish()
            }
        }
    }
}

@Suite struct ThrottledTranscriber {
    /// BUILD_PLAN P2.3: a throttled transcriber shows degrade → alert → gap, in that order,
    /// and nothing is written anywhere (the queue drops, it doesn't spill).
    @Test func degradeThenAlertThenGap() async throws {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var items: [String] = []
            func add(_ s: String) { lock.withLock { items.append(s) } }
        }
        let log = Log()
        let live = LiveTranscription(retention: .none, transcriber: SlowTranscriber(), queueCapacitySeconds: 10,
                                     handlers: .init(gap: { g in log.add("gap:\(g.reason.rawValue)") },
                                                     backlog: { e in
                                                         switch e {
                                                         case .degraded: log.add("degrade")
                                                         case .alert: log.add("alert")
                                                         case .recovered: log.add("recovered")
                                                         }
                                                     }))
        // 40 s of 2 s utterances, arriving 100x faster than real time.
        for i in 0..<20 {
            let b = LockedPCM.make(capacity: 32_000)
            b.frameLength = b.frameCapacity
            live.submit(Utterance(speaker: .client, start: Double(i) * 2, buffer: b))
            try await Task.sleep(for: .milliseconds(20))
        }
        let t = await live.stop()
        let order = log.items.filter { $0 != "recovered" }
        let firstDegrade = try #require(order.firstIndex(of: "degrade"))
        let firstAlert = try #require(order.firstIndex(of: "alert"))
        let firstGap = try #require(order.firstIndex(of: "gap:transcriber_backlog"))
        #expect(firstDegrade < firstAlert && firstAlert < firstGap, "\(order)")
        #expect(t.gaps.allSatisfy { $0.reason == .transcriberBacklog })
        #expect(!t.gaps.isEmpty)
        #expect(live.backlogEvents.first == .degraded(.client, action: "switched to fast mode (test)"))
    }
}
