import AVFoundation
import Foundation
import Observation

/// Onboarding's "say something" check (BUILD_PLAN P4.3): a live level from the default
/// microphone, so the worker sees it hears them. Levels only: nothing is kept or transcribed,
/// and the audio never leaves the tap callback.
@MainActor @Observable public final class MicCheck {
    /// 0...1, roughly perceptual.
    public var level: Float = 0
    /// Loudest level seen since starting: "we heard you" once it's past speech.
    public var peak: Float = 0
    public var running = false
    public var error: String?
    public var deviceName: String?

    @ObservationIgnored private var engine: AVAudioEngine?

    public init() {}

    public var heardSpeech: Bool { peak > 0.35 }

    public func start() {
        guard !running else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "No microphone found. Plug one in, or check System Settings → Sound → Input."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            let meter = Self.meter(rms)
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.level = meter
                self.peak = max(self.peak, meter)
            }
        }
        do {
            try engine.start()
            self.engine = engine
            running = true
            error = nil
            peak = 0
            deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't listen to the microphone: \(error.localizedDescription)"
        }
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        level = 0
    }

    /// -60 dBFS → 0, 0 dBFS → 1.
    nonisolated static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 60) / 60, 0), 1)
    }
}
