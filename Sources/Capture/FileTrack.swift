import AVFoundation
import Foundation
import ScribeskiCore

/// Plays an audio file through the same resampler and segmenter as live capture, for tests
/// and the P2.7 harness ("the worker track is injected from file"). Never used in a session.
public enum FileTrack {
    /// Segments `url` as `speaker`, starting at session time `offset`. With `realtime`, it
    /// paces itself like live audio so the transcriber sees a realistic arrival rate.
    public static func run(_ url: URL, speaker: Speaker, offset: Double = 0, realtime: Bool = false,
                           config: Segmenter.Config = .init(),
                           settled: @escaping @Sendable (Double) -> Void = { _ in },
                           emit: @escaping @Sendable (Utterance) -> Void) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        // Read as mono Float at the file's rate; the resampler takes it from there.
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let resampler = Resampler(inputRate: format.sampleRate)
        let segmenter = Segmenter(speaker: speaker, config: config, onUtterance: emit)
        segmenter.rebase(to: offset)

        let chunkFrames = AVAudioFrameCount(format.sampleRate / 20) // 50 ms, like capture
        guard let chunk = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: chunkFrames) else { return }
        let clock = ContinuousClock()
        let start = clock.now
        var framesRead = 0
        while reader.framePosition < reader.length, !Task.isCancelled {
            try reader.read(into: chunk, frameCount: chunkFrames)
            let channel = UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            resampler.convert(channel) { segmenter.process($0) }
            settled(segmenter.settledThrough)
            framesRead += Int(chunk.frameLength)
            if realtime {
                // Cancelled means "stop here": flush below rather than throw.
                try? await clock.sleep(until: start + .seconds(Double(framesRead) / format.sampleRate))
            }
        }
        segmenter.flush()
        memset_s(chunk.floatChannelData![0], Int(chunkFrames) * 4, 0, Int(chunkFrames) * 4)
    }
}
