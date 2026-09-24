import AVFoundation
import Foundation

/// Plays a stretch of decrypted session audio (P2.6 review playback). The samples live only in
/// memory, are wiped when playback ends, and never touch disk. Output only: no input node, so
/// no microphone use.
@MainActor final class SegmentPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var generation = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Plays `samples` (16 kHz Int16), replacing anything playing. `done` runs on the main
    /// actor when it finishes or is stopped.
    func play(_ samples: [Int16], done: @escaping @MainActor () -> Void) throws {
        stop()
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { done(); return }
        for (i, s) in samples.enumerated() { out[i] = Float(s) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !engine.isRunning { try engine.start() }
        generation += 1
        let mine = generation
        let bytes = samples.count * MemoryLayout<Float>.stride
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            memset_s(out, bytes, 0, bytes)
            Task { @MainActor [weak self] in
                guard let self, self.generation == mine else { return }
                done()
            }
        }
        node.play()
    }

    func stop() {
        generation += 1
        node.stop()
        if engine.isRunning { engine.stop() }
    }
}
