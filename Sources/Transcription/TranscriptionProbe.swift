import Capture
import Darwin
import Foundation
import ScribeskiCore

/// Dev harness for P2.7: live capture of one app (and optionally a worker track injected from
/// a file) → streaming transcription → `Transcript`, scored against a reference if given.
/// Only text is written; audio never leaves locked memory.
public enum TranscriptionProbe {
    public struct Options: Sendable {
        /// A bundle ID, or `pid:<n>` to tap one process. Ignored when `clientFile` is set.
        public var source: String
        /// Play this with `afplay` and tap that process as the client (P2.7 CaptureE2E).
        public var clientFile: URL?
        /// Played by a second `afplay` at the same time. Must not reach the client track.
        public var distractorFile: URL?
        /// afplay volume. The tap hears the scaled signal; keep it quiet in the room.
        public var playbackVolume = 0.2
        public var seconds: Double
        public var useMicrophone = true
        public var workerFile: URL?
        /// `reference.json` from `scripts/synth-audio.swift`, for WER and timing checks.
        public var reference: URL?
        public var vocabulary: [String] = []
        /// Force a capture rebuild this many seconds in, to exercise device-change handling.
        public var rebuildAt: Double?
        /// Mute the players' output while tapping them, so the room stays quiet.
        public var silent = false
        /// Echo cancellation on the mic (on by default; off to measure what it buys).
        public var cancelEcho = true
        /// A retained mode, with the encrypted audio copy's feed (P2.6), to check the tee on
        /// real capture. `none` (the default) keeps the zero-recording byte check meaningful.
        public var retention: Retention = .none
        public var audio: (@Sendable (Utterance) -> Void)?

        public init(source: String, seconds: Double) {
            self.source = source
            self.seconds = seconds
        }
    }

    public struct ReferenceLine: Codable, Sendable {
        public var speaker: Speaker
        public var start: Double
        public var end: Double
        public var text: String
    }

    public struct Report: Codable, Sendable {
        public var transcript: Transcript
        public var engine: String
        public var microphone: String?
        public var rebuilds: Int
        public var overloads: Int
        /// Seconds from Stop to a finished transcript.
        public var stopToTranscript: Double
        public var wer: [String: Double]?
        /// Reference lines with no transcript segment overlapping them in time.
        public var missedLines: [String: Int]?
        public var transcriberErrors: [String]
        /// Bytes this process wrote to disk from capture start to transcript (DESIGN §3a:
        /// should be ~0 in `none` mode; audio would be ~64 KB/s per track).
        public var diskBytesWritten: UInt64
        public var bleedDropped: Int
        /// Echo removed from the mic while the far end talked (ERLE), and over how many frames.
        public var echoErleDb: Double?
        public var echoFarFrames: Int?
    }

    public static func run(_ options: Options, transcriber: any Transcriber = SpeechAnalyzerTranscriber()) async throws -> Report {
        try await transcriber.prepare(locale: Locale(identifier: "en_US"), vocabulary: options.vocabulary)

        // Launch the players first: a process only has an audio object once it's playing.
        var players: [Process] = []
        defer { players.forEach { $0.terminate() } }
        var spec = options.source
        let clock = ContinuousClock()
        var clientLaunched = clock.now
        if let file = options.clientFile {
            clientLaunched = clock.now
            let player = try play(file, volume: options.playbackVolume)
            players.append(player)
            spec = "pid:\(player.processIdentifier)"
            try await waitForAudio(pid: player.processIdentifier)
        }
        var muter: ProcessMuter?
        if let file = options.distractorFile {
            let player = try play(file, volume: options.playbackVolume)
            players.append(player)
            if options.silent {
                try await waitForAudio(pid: player.processIdentifier)
                muter = ProcessMuter(processes: AudioProcessList.snapshot()
                    .filter { $0.pid == player.processIdentifier }.map(\.objectID))
            }
        }
        defer { _ = muter }

        let source = try resolve(spec)
        let live = LiveTranscription(retention: options.retention, transcriber: transcriber,
                                     handlers: .init(audio: options.audio))
        let writtenBefore = bytesWritten()
        let captureStarted = clock.now
        try live.start(source: source, useMicrophone: options.useMicrophone && options.workerFile == nil,
                       silenceSource: options.silent, cancelEcho: options.cancelEcho)
        // Put the injected worker file on the same timeline as the client file: both t = 0
        // at the moment afplay launched.
        let offset = seconds(clientLaunched - captureStarted)
        let reference = offset

        let injected = Task {
            guard let file = options.workerFile else { return }
            live.noteTrack(.worker, source: "file:\(file.lastPathComponent)")
            try await FileTrack.run(file, speaker: .worker, offset: offset, realtime: true,
                                    settled: { live.settle(.worker, through: $0) }) { live.submit($0) }
        }
        if let at = options.rebuildAt {
            try await Task.sleep(for: .seconds(at))
            live.forceCaptureRebuild()
            try await Task.sleep(for: .seconds(options.seconds + offset - at))
        } else {
            try await Task.sleep(for: .seconds(options.seconds + offset))
        }
        injected.cancel() // the run ends at `seconds`, however long the file is
        try? await injected.value

        let diagnostics = live.captureDiagnostics
        let echo = live.echoDiagnostics
        let microphone = live.microphoneName
        let stopped = ContinuousClock.now
        let transcript = await live.stop()
        let latency = ContinuousClock.now - stopped
        let written = bytesWritten() - writtenBefore

        var report = Report(
            transcript: transcript, engine: transcriber.engine, microphone: microphone,
            rebuilds: diagnostics?.rebuilds ?? 0, overloads: diagnostics?.overloads ?? 0,
            stopToTranscript: seconds(latency), transcriberErrors: live.errors, diskBytesWritten: written,
            bleedDropped: live.bleedDropped, echoErleDb: echo?.erleDb, echoFarFrames: echo?.farActiveFrames)
        if let url = options.reference {
            // Reference times are file times; shift them onto the session clock.
            let lines = try JSONDecoder().decode([ReferenceLine].self, from: Data(contentsOf: url))
                .filter { $0.end < options.seconds }
                .map { ReferenceLine(speaker: $0.speaker, start: $0.start + reference, end: $0.end + reference, text: $0.text) }
            score(&report, against: lines)
        }
        return report
    }

    /// Lifetime disk bytes written by this process (`proc_pid_rusage`; no root needed).
    static func bytesWritten() -> UInt64 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? info.ri_diskio_byteswritten : 0
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func play(_ file: URL, volume: Double) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(volume), file.path]
        try p.run()
        return p
    }

    static func waitForAudio(pid: Int32) async throws {
        for _ in 0..<60 where !AudioProcessList.snapshot().contains(where: { $0.pid == pid }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func score(_ report: inout Report, against lines: [ReferenceLine]) {
        var wer: [String: Double] = [:]
        var missed: [String: Int] = [:]
        for speaker in Speaker.allCases {
            let ref = lines.filter { $0.speaker == speaker }
            let hyp = report.transcript.segments.filter { $0.speaker == speaker }
            guard !ref.isEmpty else { continue }
            wer[speaker.rawValue] = WordErrorRate.compute(
                reference: ref.map(\.text).joined(separator: " "),
                hypothesis: hyp.map(\.text).joined(separator: " "))
            missed[speaker.rawValue] = ref.filter { line in
                !hyp.contains { $0.start < line.end + 0.5 && $0.end > line.start - 0.5 }
            }.count
        }
        report.wer = wer
        report.missedLines = missed
    }

    static func resolve(_ spec: String) throws -> CallSource {
        let processes = AudioProcessList.snapshot()
        if spec.hasPrefix("pid:"), let pid = Int32(spec.dropFirst(4)) {
            let matching = processes.filter { $0.pid == pid }
            guard !matching.isEmpty else { throw TranscriberError.sourceNotFound(spec) }
            return CallSource(bundleID: spec, name: spec, kind: .other, processes: matching)
        }
        guard let source = CallSources.group(processes).first(where: { $0.bundleID == spec }) else {
            throw TranscriberError.sourceNotFound(spec)
        }
        return source
    }
}
