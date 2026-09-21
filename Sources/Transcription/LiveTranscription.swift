import Capture
import Foundation
import ScribeskiCore
import Synchronization

/// One session's streaming transcription (DESIGN §3, §3a): capture → per-track segmenter →
/// bounded queue → transcriber, with only final text kept. The transcript is ready seconds
/// after `stop`, because the work happened during the call.
public final class LiveTranscription: Sendable {
    public let sessionId: String
    public let retention: Retention
    public let startedAt: Date
    public let transcriber: any Transcriber

    public struct Handlers: Sendable {
        public var levels: @Sendable ([Speaker: Float]) -> Void
        public var segment: @Sendable (TranscribedSegment) -> Void
        public var gap: @Sendable (Transcript.Gap) -> Void
        public var backlog: @Sendable (BacklogEvent) -> Void
        /// Every utterance as it's submitted, before transcription: the encrypted audio copy's
        /// feed when retention keeps audio (P2.6). Never set in zero-recording mode.
        public var audio: (@Sendable (Utterance) -> Void)?

        public init(levels: @escaping @Sendable ([Speaker: Float]) -> Void = { _ in },
                    segment: @escaping @Sendable (TranscribedSegment) -> Void = { _ in },
                    gap: @escaping @Sendable (Transcript.Gap) -> Void = { _ in },
                    backlog: @escaping @Sendable (BacklogEvent) -> Void = { _ in },
                    audio: (@Sendable (Utterance) -> Void)? = nil) {
            self.levels = levels
            self.segment = segment
            self.gap = gap
            self.backlog = backlog
            self.audio = audio
        }
    }

    private struct Lane: Sendable {
        let queue: UtteranceQueue
        let task: Task<Void, Never>
    }

    private let handlers: Handlers
    private let assembler = TranscriptAssembler()
    private let lanes = Mutex<[Speaker: Lane]>([:])
    private let lastEnd = Mutex<[Speaker: Double]>([:])
    private let capture = Mutex<CaptureController?>(nil)
    private let secondVoice = Mutex<SecondVoiceDetector?>(nil)
    private let failures = Mutex<[String]>([])
    private let events = Mutex<[BacklogEvent]>([])
    /// Lanes currently degraded or alerting, so each event fires once per episode.
    private let pressure = Mutex<[Speaker: BacklogEvent]>([:])
    public let queueCapacitySeconds: Double
    /// Restarts per lane before giving up on a track for the rest of the session.
    private static let maxRestarts = 5

    public init(sessionId: String = "SES-\(UUID().uuidString.prefix(8))", retention: Retention,
                transcriber: any Transcriber, queueCapacitySeconds: Double = 120, handlers: Handlers = .init()) {
        self.queueCapacitySeconds = queueCapacitySeconds
        self.sessionId = sessionId
        self.retention = retention
        self.transcriber = transcriber
        self.handlers = handlers
        startedAt = .now
    }

    /// Starts capturing `source` (and the mic, if asked). The transcriber must be prepared.
    /// `silenceSource` is for the test harness only (see `CaptureSession`).
    public func start(source: CallSource, useMicrophone: Bool = true, silenceSource: Bool = false,
                      cancelEcho: Bool = true) throws {
        let controller = CaptureController(source: source, useMicrophone: useMicrophone,
                                           silenceSource: silenceSource, cancelEcho: cancelEcho, callbacks: .init(
            utterance: { [weak self] in self?.submit($0) },
            gap: { [weak self] in self?.record($0) },
            levels: { [handlers] in handlers.levels($0) },
            tracks: { [weak self] in self?.assembler.noteTracks($0) },
            settled: { [weak self] in self?.settle($0, through: $1) }))
        try controller.start()
        capture.withLock { $0 = controller }
    }

    public var microphoneName: String? { capture.withLock { $0 }?.microphoneName }

    public var echoDiagnostics: (erleDb: Double?, farActiveFrames: Int)? {
        capture.withLock { $0 }?.echoDiagnostics ?? nil
    }

    /// Rebuilds capture as a device change would (tests and the harness).
    public func forceCaptureRebuild() { capture.withLock { $0 }?.forceRebuild() }
    public var captureDiagnostics: (rebuilds: Int, overloads: Int, sampleRate: Double)? {
        capture.withLock { $0 }?.diagnostics
    }

    /// Seconds of audio waiting for the transcriber, worst track. Drives the backlog alarm.
    public var backlogSeconds: Double {
        lanes.withLock { $0.values.map(\.queue.queuedSeconds).max() ?? 0 }
    }

    public var liveSegments: [TranscribedSegment] { assembler.liveSegments }

    /// The transcript so far, for sealing to disk while recording (crash recovery).
    public func snapshot() -> Transcript {
        assembler.transcript(sessionId: sessionId, startedAt: startedAt, retention: retention)
    }
    /// Worker lines dropped as the client's audio leaking into the mic (after `stop`).
    public var bleedDropped: Int { assembler.bleedDropped }

    /// Flags a second voice on the client's line from here on (P2.5). Optional: sessions run
    /// without it when the diarizer model isn't downloaded.
    public func attach(secondVoice detector: SecondVoiceDetector) {
        secondVoice.withLock { $0 = detector }
    }

    /// Feeds an utterance from any producer: capture, or a file for tests.
    public func submit(_ utterance: Utterance) {
        if retention.retainsAudio { handlers.audio?(utterance) }
        secondVoice.withLock { $0 }?.add(utterance)
        let queue = lane(for: utterance.speaker).queue
        // Judged on the backlog *with* this utterance, before pushing, so the alert always
        // precedes the gap its push may cause.
        checkPressure(utterance.speaker, queued: queue.queuedSeconds + utterance.duration)
        queue.push(utterance)
        lastEnd.withLock { $0[utterance.speaker] = max($0[utterance.speaker] ?? 0, utterance.end) }
    }

    /// Backlog events so far, in order.
    public var backlogEvents: [BacklogEvent] { events.withLock { $0 } }

    private func checkPressure(_ speaker: Speaker, queued: Double) {
        let fill = queued / queueCapacitySeconds
        let state = pressure.withLock { $0[speaker] }
        var event: BacklogEvent?
        switch state {
        case nil where fill >= 0.95:
            // Straight past both thresholds: still degrade first, then alert.
            let degraded = BacklogEvent.degraded(speaker, action: transcriber.degrade(speaker: speaker))
            events.withLock { $0.append(degraded) }
            handlers.backlog(degraded)
            event = .alert(speaker)
        case nil where fill >= 0.5:
            event = .degraded(speaker, action: transcriber.degrade(speaker: speaker))
        case .degraded? where fill >= 0.95:
            event = .alert(speaker)
        case .degraded?, .alert?:
            if fill < 0.25 { event = .recovered(speaker) }
        default:
            break
        }
        guard let event else { return }
        pressure.withLock { $0[speaker] = { if case .recovered = event { return nil } else { return event } }() }
        events.withLock { $0.append(event) }
        handlers.backlog(event)
    }

    /// Nothing on `speaker` will start before `time`; lets the engine finalize during silence.
    public func settle(_ speaker: Speaker, through time: Double) {
        lanes.withLock { $0[speaker] }?.queue.advance(to: time)
    }

    /// Transcriber failures this session, newest last. Each one restarted its lane.
    public var errors: [String] { failures.withLock { $0 } }

    /// Declares a track that isn't coming from capture (e.g. injected from a file).
    public func noteTrack(_ speaker: Speaker, source: String) {
        assembler.noteTracks([speaker: .init(source: source)])
    }

    /// Stops capture, lets the transcriber finalize what's in flight, and returns the transcript.
    public func stop() async -> Transcript {
        let controller = capture.withLock { c -> CaptureController? in defer { c = nil }; return c }
        controller?.stop() // flushes segmenters: the last utterances arrive before this returns
        let all = lanes.withLock { $0 }
        for lane in all.values { lane.queue.finish() }
        for lane in all.values { await lane.task.value }
        var transcript = assembler.transcript(sessionId: sessionId, startedAt: startedAt, retention: retention)
        if let detector = secondVoice.withLock({ d -> SecondVoiceDetector? in defer { d = nil }; return d }) {
            transcript.otherVoices = await detector.finish()
        }
        return transcript
    }

    private func record(_ gap: Transcript.Gap) {
        assembler.add(gap)
        handlers.gap(gap)
    }

    private func lane(for speaker: Speaker) -> Lane {
        lanes.withLock { lanes in
            if let lane = lanes[speaker] { return lane }
            let queue = UtteranceQueue(speaker: speaker, capacitySeconds: queueCapacitySeconds) { [weak self] in
                self?.record($0)
            }
            let task = Task { [assembler, handlers, transcriber, weak self] in
                var reached = 0.0
                for attempt in 0...Self.maxRestarts {
                    do {
                        for try await segment in transcriber.transcribe(speaker: speaker, utterances: queue) {
                            assembler.add(segment)
                            handlers.segment(segment)
                            reached = max(reached, segment.end)
                        }
                        return
                    } catch {
                        // The engine died. Keep what it finished, mark what it had in flight as
                        // missing, and restart it on the same queue so the rest of the call survives.
                        self?.failures.withLock { $0.append("\(speaker.rawValue) #\(attempt + 1): \(error)") }
                        let end = self?.lastEnd.withLock { $0[speaker] } ?? reached
                        if end > reached {
                            self?.record(.init(track: speaker, start: reached, end: end, reason: .transcriberCrash))
                        }
                        reached = end
                    }
                }
            }
            let lane = Lane(queue: queue, task: task)
            lanes[speaker] = lane
            return lane
        }
    }
}
