import AVFoundation
import Capture
import CoreMedia
import Foundation
import ScribeskiCore
import Speech
import Synchronization

/// Apple's on-device `SpeechAnalyzer` (DESIGN §3: the baseline engine). Nothing to ship:
/// the OS manages per-locale assets. One analyzer per track, fed VAD utterances with their
/// capture-clock start times, so result times are already session times.
public final class SpeechAnalyzerTranscriber: Transcriber {
    public let engine = "speechanalyzer"

    private struct Prepared: Sendable {
        var locale: Locale
        var vocabulary: [String]
    }
    private let prepared = Mutex<Prepared?>(nil)

    public init() {}

    public func prepare(locale: Locale, vocabulary: [String]) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeNotSupported(locale.identifier)
        }
        // A first run downloads the locale's model. That's real, so it isn't hidden.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.module(supported)]) {
            try await request.downloadAndInstall()
        }
        prepared.withLock { $0 = Prepared(locale: supported, vocabulary: vocabulary) }
    }

    public func transcribe(speaker: Speaker, utterances: UtteranceQueue) -> AsyncThrowingStream<TranscribedSegment, Error> {
        let config = prepared.withLock { $0 }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let config else { throw TranscriberError.notPrepared }
                    let module = Self.module(config.locale)
                    let context = AnalysisContext()
                    if !config.vocabulary.isEmpty { context.contextualStrings[.general] = config.vocabulary }
                    let analyzer = SpeechAnalyzer(
                        modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
                    try await analyzer.setContext(context)
                    try await analyzer.prepareToAnalyze(in: SpeechAudio.format)

                    let results = Task {
                        for try await result in module.results where result.isFinal {
                            if let segment = Self.segment(result, speaker: speaker) { continuation.yield(segment) }
                        }
                    }
                    let inputs = Self.continuous(utterances)
                    if let last = try await analyzer.analyzeSequence(inputs) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                    try await results.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// SpeechAnalyzer wants an unbroken timeline. Fed only VAD utterances with explicit
    /// start times, it fragments and repeats words at the joins (11.5% WER on the synthetic
    /// session vs 3.1% continuous, 2026-09-23). So the time between utterances is sent as
    /// zeros in ≤1 s buffers, up to each utterance and up to each silence marker.
    ///
    /// Positions are whole samples: a half-sample rounding overlap between buffers makes
    /// the analyzer fail. Zeros carry nothing, so they needn't be locked.
    static func continuous(_ queue: UtteranceQueue) -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = Task {
            let rate = Int(SpeechAudio.sampleRate)
            var cursor: Int?
            func time(_ sample: Int) -> CMTime { CMTime(value: CMTimeValue(sample), timescale: CMTimeScale(rate)) }
            func fill(to target: Int) {
                guard var at = cursor else { return }
                while target > at {
                    let frames = min(rate, target - at)
                    guard let silence = AVAudioPCMBuffer(pcmFormat: SpeechAudio.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
                    silence.frameLength = AVAudioFrameCount(frames)
                    memset(silence.int16ChannelData![0], 0, frames * 2)
                    continuation.yield(AnalyzerInput(buffer: silence, bufferStartTime: time(at)))
                    at += frames
                }
                cursor = at
            }
            for await item in queue {
                switch item {
                case .silence(let until):
                    fill(to: Int((until * SpeechAudio.sampleRate).rounded(.down)))
                case .speech(let u):
                    var start = Int((u.start * SpeechAudio.sampleRate).rounded())
                    if cursor == nil { cursor = start }
                    fill(to: start)
                    // Never overlap what's already been sent.
                    start = max(start, cursor!)
                    continuation.yield(AnalyzerInput(buffer: u.buffer, bufferStartTime: time(start)))
                    cursor = start + Int(u.buffer.frameLength)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func segment(_ result: SpeechTranscriber.Result, speaker: Speaker) -> TranscribedSegment? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        // Punctuation-only results ("." or "'") carry no words.
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        // Mean of the per-run confidences, weighted by run length.
        var weighted = 0.0
        var total = 0
        for run in result.text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let n = result.text.characters[run.range].count
            weighted += c * Double(n)
            total += n
        }
        return TranscribedSegment(
            speaker: speaker,
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            text: text,
            confidence: total > 0 ? weighted / Double(total) : nil)
    }
}
