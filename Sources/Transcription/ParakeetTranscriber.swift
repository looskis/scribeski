import AVFoundation
import Capture
import FluidAudio
import Foundation
import ScribeskiCore
import SuiteModelStore
import Synchronization

/// NVIDIA Parakeet TDT 0.6B v3 on CoreML via FluidAudio (DESIGN §3: the provisional default).
/// Runs on the Neural Engine, so it doesn't compete with the call app for the GPU.
/// Weights load from the shared model store only; this never downloads (`loadLocal`).
///
/// One decode per VAD utterance. Parakeet needs no silence between them, so `.silence`
/// markers are ignored. It has no vocabulary biasing; that's post-correction (P2.8).
public final class ParakeetTranscriber: Transcriber {
    public let engine = "parakeet-tdt-0.6b-v3"
    public static let catalogID = "parakeet-tdt-0.6b-v3-coreml"
    public let modelDirectory: URL
    private let manager = Mutex<AsrManager?>(nil)

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// The speech model this app resolves to, if it's a CoreML Parakeet that's downloaded.
    public static func fromModelStore(appName: String = "Scribeski", appID: String = "scribeski") throws -> ParakeetTranscriber {
        let locator = try ModelLocator(appName: appName, appID: appID)
        guard let url = locator.localURL(.asr) else {
            throw TranscriberError.modelMissing("\(locator.name(.asr) ?? catalogID) (Settings → Models)")
        }
        return ParakeetTranscriber(modelDirectory: url)
    }

    public func prepare(locale: Locale, vocabulary: [String]) async throws {
        let directory = modelDirectory
        // Loading compiles for the Neural Engine on first use (cached by the OS after). Blocking.
        let models = try await Task.detached { try AsrModels.loadLocal(from: directory, version: .v3) }.value
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        // Warm-up so the first real utterance isn't slow.
        var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state, language: .english)
        manager.withLock { $0 = asr }
    }

    public func transcribe(speaker: ScribeskiCore.Speaker, utterances: UtteranceQueue) -> AsyncThrowingStream<TranscribedSegment, Error> {
        let asr = manager.withLock { $0 }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let asr else { throw TranscriberError.notPrepared }
                    for await item in utterances {
                        guard case .speech(let u) = item else { continue }
                        if let segment = try await Self.decode(u, asr: asr) { continuation.yield(segment) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parakeet refuses anything under 0.3 s; shorter utterances are padded with silence.
    static let minimumSamples = 4_800

    static func decode(_ u: Utterance, asr: AsrManager) async throws -> TranscribedSegment? {
        // FluidAudio takes [Float]. This copy is ours, so it's wiped after the decode.
        var samples = u.buffer.int16Samples.map { Float($0) / 32_768 }
        if samples.count < minimumSamples { samples += [Float](repeating: 0, count: minimumSamples - samples.count) }
        defer { samples.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) } }

        var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state, language: .english)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }

        // Token timings (80 ms steps) tighten the segment to where words actually are.
        let timings = result.tokenTimings ?? []
        let start = timings.first.map { u.start + $0.startTime } ?? u.start
        let end = timings.last.map { u.start + $0.endTime } ?? u.end
        return TranscribedSegment(speaker: u.speaker, start: start, end: max(end, start), text: text,
                                  confidence: Double(result.confidence))
    }
}
