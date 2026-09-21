import Capture
import CoreML
@preconcurrency import FluidAudio
import Foundation
import ScribeskiCore
import SuiteModelStore

/// Flags a second voice on the client's line (BUILD_PLAN P2.5): someone else in the room with
/// the client, or a handset passed around. Sortformer (CoreML, FluidAudio) runs on the client
/// track's speech only, as it arrives, off the capture thread. The client's main voice is
/// whoever speaks most; any other speaker heard for at least `minSeconds` becomes a span.
/// Nothing is relabelled: the worker gets a flag to check, and the transcript stays two
/// tracks (DESIGN §3). Audio lives only in memory, like everything else downstream of capture.
public final class SecondVoiceDetector: @unchecked Sendable {
    private let diarizer: SortformerDiarizer
    private let queue = DispatchQueue(label: "scribeski.second-voice")
    /// Where each fed stretch sits in the diarizer's stream (speech only, back to back) and in
    /// the session. Maps the diarizer's times back to session times.
    private var pieces: [(stream: Double, session: Double, length: Double)] = []
    private var streamSeconds = 0.0
    private var failed = false
    public static let minSeconds = 1.5

    init(models: SortformerModels, config: SortformerConfig) {
        diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
    }

    /// From the shared model store (the catalog's diarizer: Sortformer v2.1, streaming fast).
    /// Throws if it isn't downloaded: the session then runs without the flag.
    public static func fromModelStore(appName: String = "Scribeski", appID: String = "scribeski") async throws -> SecondVoiceDetector {
        let locator = try ModelLocator(appName: appName, appID: appID)
        guard let dir = locator.localURL(.diarizer) else { throw TranscriberError.modelMissing("diarizer not downloaded") }
        let compiled = try Self.findCompiledModel(in: dir)
        let config = SortformerConfig.fastV2_1
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = SortformerModels.recommendedComputeUnits(for: config)
        let model = try MLModel(contentsOf: compiled, configuration: mlConfig)
        return SecondVoiceDetector(models: try SortformerModels(config: config, main: model), config: config)
    }

    static func findCompiledModel(in dir: URL) throws -> URL {
        let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.pathExtension == "mlmodelc" }
        guard let found else { throw TranscriberError.modelMissing("no compiled Sortformer model in \(dir.lastPathComponent)") }
        return found
    }

    /// Client speech, as the transcriber gets it. Non-blocking: the work happens on a queue.
    public func add(_ utterance: Utterance) {
        guard utterance.speaker == .client else { return }
        let samples = utterance.buffer.int16Samples.map { Float($0) / 32768 }
        let start = utterance.start
        queue.async { [self] in
            guard !failed else { return }
            pieces.append((streamSeconds, start, Double(samples.count) / SpeechAudio.sampleRate))
            streamSeconds += Double(samples.count) / SpeechAudio.sampleRate
            do {
                try diarizer.addAudio(samples)
                _ = try diarizer.process()
            } catch {
                failed = true
            }
        }
    }

    /// Finishes the stream and returns where another voice was heard, in session time.
    public func finish() async -> [Transcript.Span] {
        await withCheckedContinuation { (done: CheckedContinuation<[Transcript.Span], Never>) in
            queue.async { [self] in
                guard !failed else { return done.resume(returning: []) }
                _ = try? diarizer.finalizeSession()
                let segments = diarizer.timeline.speakers.values.map { ($0.index, $0.finalizedSegments + $0.tentativeSegments) }
                let spans = Self.otherVoices(segments.map { ($0.0, $0.1.map { (Double($0.startTime), Double($0.endTime)) }) },
                                             pieces: pieces)
                diarizer.cleanup()
                done.resume(returning: spans)
            }
        }
    }

    /// The main voice is the speaker with the most speech; every other speaker's stretches of
    /// at least `minSeconds`, mapped to session time and merged when they touch.
    static func otherVoices(_ speakers: [(index: Int, segments: [(start: Double, end: Double)])],
                            pieces: [(stream: Double, session: Double, length: Double)]) -> [Transcript.Span] {
        let talk = speakers.map { s in (s.index, s.segments.reduce(0) { $0 + ($1.end - $1.start) }) }
        guard let main = talk.max(by: { $0.1 < $1.1 })?.0 else { return [] }
        func session(_ t: Double) -> Double {
            guard let p = pieces.last(where: { $0.stream <= t }) else { return t }
            return p.session + min(t - p.stream, p.length)
        }
        let others = speakers.filter { $0.index != main }.flatMap(\.segments)
            .filter { $0.end - $0.start >= minSeconds }
            .map { Transcript.Span(start: session($0.start), end: session($0.end)) }
            .sorted { $0.start < $1.start }
        var merged: [Transcript.Span] = []
        for s in others {
            if let last = merged.last, s.start <= last.end + 1 {
                merged[merged.count - 1].end = max(last.end, s.end)
            } else {
                merged.append(s)
            }
        }
        return merged.map { .init(start: ($0.start * 10).rounded() / 10, end: ($0.end * 10).rounded() / 10) }
    }
}
