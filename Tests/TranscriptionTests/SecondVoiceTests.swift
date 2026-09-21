import ScribeskiCore
import Testing
@testable import Transcription

/// The second-voice flag's bookkeeping (P2.5): which speaker is the client, and where the
/// others were, back in session time. The model itself is exercised by the probe.
@Suite struct SecondVoiceSpans {
    @Test func theMostTalkativeSpeakerIsTheClientAndOthersBecomeSessionSpans() {
        // Diarizer stream: client speech only, back to back. Two pieces fed: 0–30 s of stream
        // was session 10–40 s; 30–50 s of stream was session 100–120 s.
        let pieces: [(stream: Double, session: Double, length: Double)] = [(0, 10, 30), (30, 100, 20)]
        let spans = SecondVoiceDetector.otherVoices([
            (index: 0, segments: [(0, 12), (14, 29), (31, 45)]),
            (index: 1, segments: [(12.0, 14.0), (45.0, 48.0)]),   // 2 s and 3 s: flagged
            (index: 2, segments: [(29.0, 29.8)]),               // under 1.5 s: ignored
        ], pieces: pieces)
        #expect(spans == [.init(start: 22, end: 24), .init(start: 115, end: 118)])
    }

    @Test func oneVoiceMeansNoFlags() {
        #expect(SecondVoiceDetector.otherVoices([(index: 0, segments: [(0, 60)])], pieces: [(0, 0, 60)]).isEmpty)
        #expect(SecondVoiceDetector.otherVoices([], pieces: []).isEmpty)
    }

    @Test func touchingStretchesMerge() {
        let spans = SecondVoiceDetector.otherVoices([
            (index: 0, segments: [(0, 100)]),
            (index: 1, segments: [(10.0, 12.0), (12.5, 15.0)]),
        ], pieces: [(0, 0, 100)])
        #expect(spans == [.init(start: 10, end: 15)])
    }
}
