import AVFoundation
import Foundation
import ScribeskiCore
import Testing
@testable import Capture

/// Builds 16 kHz Int16 test signals: tone bursts stand in for speech, low noise for a room.
struct Signal {
    var samples: [Int16] = []
    var rng = SystemRandomNumberGenerator()

    mutating func silence(_ seconds: Double, noise: Double = 0.0005) {
        for _ in 0..<Int(seconds * 16_000) {
            samples.append(Int16(Double.random(in: -noise...noise, using: &rng) * 32767))
        }
    }

    mutating func speech(_ seconds: Double, amplitude: Double = 0.1) {
        let start = samples.count
        for i in 0..<Int(seconds * 16_000) {
            // Two tones with a slow wobble, so frame energy varies a little like speech does.
            let t = Double(start + i) / 16_000
            let v = amplitude * (0.6 * sin(2 * .pi * 220 * t) + 0.4 * sin(2 * .pi * 540 * t)) * (0.8 + 0.2 * sin(2 * .pi * 3 * t))
            samples.append(Int16(v * 32767))
        }
    }
}

final class Collected: @unchecked Sendable {
    var utterances: [Utterance] = []
}

func segment(_ signal: Signal, chunk: Int = 800, rebaseAt: (index: Int, time: Double)? = nil,
             config: Segmenter.Config = .init()) -> [Utterance] {
    let out = Collected()
    let seg = Segmenter(speaker: .client, config: config) { out.utterances.append($0) }
    signal.samples.withUnsafeBufferPointer { all in
        var i = 0
        while i < all.count {
            if let r = rebaseAt, i == r.index { seg.rebase(to: r.time) }
            let n = min(chunk, all.count - i)
            seg.process(UnsafeBufferPointer(rebasing: all[i..<i + n]))
            i += n
        }
    }
    seg.flush()
    return out.utterances
}

@Suite struct SegmenterBehaviour {
    @Test func findsSpeechBurstsAndIgnoresClicks() {
        var s = Signal()
        s.silence(1); s.speech(1.5); s.silence(1.2); s.speech(0.6); s.silence(1.2)
        s.speech(0.04, amplitude: 0.5); s.silence(1) // a click
        let us = segment(s)
        #expect(us.count == 2)
        // Starts include up to 300 ms of pre-roll before onset.
        #expect(us[0].start >= 0.65 && us[0].start <= 1.0)
        #expect(us[0].end >= 2.5 && us[0].end <= 2.8)
        #expect(us[1].start >= 3.35 && us[1].start <= 3.7)
        #expect(us.allSatisfy { $0.speaker == .client })
    }

    @Test func chunkSizeDoesNotChangeTheResult() {
        var s = Signal()
        s.silence(0.5); s.speech(2); s.silence(1)
        let a = segment(s, chunk: 160).map { ($0.start, $0.buffer.frameLength) }
        let b = segment(s, chunk: 4096).map { ($0.start, $0.buffer.frameLength) }
        #expect(a.map(\.0) == b.map(\.0))
        #expect(a.map(\.1) == b.map(\.1))
    }

    @Test func longSpeechIsSplitUnderTheCapWithNothingLost() {
        var s = Signal()
        s.silence(0.5); s.speech(70); s.silence(1)
        let us = segment(s)
        #expect(us.count >= 3)
        #expect(us.allSatisfy { $0.duration <= 30.0001 })
        // Contiguous: each piece starts where the last ended.
        for (a, b) in zip(us, us.dropFirst()) { #expect(abs(a.end - b.start) < 0.001) }
        let covered = us.last!.end - us.first!.start
        #expect(covered >= 70 && covered <= 70.6)
    }

    @Test func rebaseShiftsTimestampsAfterARebuild() {
        var s = Signal()
        s.silence(1); s.speech(1); s.silence(1)      // 3 s on the first device
        s.silence(0.5); s.speech(1); s.silence(1)    // then 12 s later on a new one
        let us = segment(s, chunk: 800, rebaseAt: (index: 48_000, time: 15))
        #expect(us.count == 2)
        #expect(us[0].start < 1.01)
        #expect(us[1].start >= 15.2 && us[1].start <= 15.5)
    }

    @Test func speechOverRoomNoiseIsStillFound() {
        var s = Signal()
        s.silence(2, noise: 0.003); s.speech(1, amplitude: 0.03); s.silence(2, noise: 0.003)
        #expect(segment(s).count == 1)
    }

    @Test func utteranceBuffersAreLockedSpeechFormat() {
        var s = Signal()
        s.silence(0.5); s.speech(1); s.silence(1)
        let u = segment(s)[0]
        #expect(u.buffer.format == SpeechAudio.format)
        #expect(u.buffer.frameCapacity == u.buffer.frameLength, "right-sized copy")
    }
}
