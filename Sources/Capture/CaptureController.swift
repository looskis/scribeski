import CoreAudio
import Foundation
import ScribeskiCore

/// Runs capture for a session (BUILD_PLAN P2.2–P2.3): owns the `CaptureSession`, drains it
/// every 50 ms through a resampler and a segmenter per track, and survives device changes.
///
/// - Mic unplugged, default input changed, sample rate changed (AirPods profile switch), or
///   the aggregate died: tear down, rebuild, and record a `device_rebuild` gap on each track
///   for the time it was dark. If the mic is gone, carry on tap-only.
/// - The call app gained or lost helper processes: update the tap's process list in place.
///
/// Everything runs on one serial queue, so there are no locks outside the realtime rings.
public final class CaptureController: @unchecked Sendable {
    public struct Callbacks: Sendable {
        public var utterance: @Sendable (Utterance) -> Void
        public var gap: @Sendable (Transcript.Gap) -> Void
        /// Peak RMS per track since the last call, every 50 ms.
        public var levels: @Sendable ([Speaker: Float]) -> Void
        /// Which tracks are live, and from what device or app. Called at start and after rebuilds.
        public var tracks: @Sendable ([Speaker: Transcript.Track]) -> Void
        /// Every 50 ms per live track: no later utterance will start before this session time.
        public var settled: @Sendable (Speaker, Double) -> Void

        public init(utterance: @escaping @Sendable (Utterance) -> Void,
                    gap: @escaping @Sendable (Transcript.Gap) -> Void = { _ in },
                    levels: @escaping @Sendable ([Speaker: Float]) -> Void = { _ in },
                    tracks: @escaping @Sendable ([Speaker: Transcript.Track]) -> Void = { _ in },
                    settled: @escaping @Sendable (Speaker, Double) -> Void = { _, _ in }) {
            self.utterance = utterance
            self.gap = gap
            self.levels = levels
            self.tracks = tracks
            self.settled = settled
        }
    }

    public let sourceBundleID: String
    private let useMicrophone: Bool
    private let silenceSource: Bool
    private let cancelEcho: Bool
    /// Cancels the call's audio out of the mic, with the tap as reference. Nil without a mic.
    private var echo: EchoCanceller?
    private let callbacks: Callbacks
    private let segmenterConfig: Segmenter.Config
    private let queue = DispatchQueue(label: "com.looski.scribeski.capture", qos: .userInitiated)

    private var processes: [AudioObjectID]
    private let bundleIDs: [String]
    private var session: CaptureSession?
    private var micDevice: AudioDeviceID?
    private var resamplers: [Speaker: Resampler] = [:]
    private var segmenters: [Speaker: Segmenter] = [:]
    private var droppedSoFar: [Speaker: Int] = [:]
    /// Tracks currently dark, and the session time they went dark.
    private var darkSince: [Speaker: Double] = [:]
    private var timer: DispatchSourceTimer?
    private var listeners: [Listener] = []
    private var processListener: Listener?
    private var startedAt: ContinuousClock.Instant?
    private var rebuildPending = false
    private var builtMicRate = 0.0
    /// Tracks of the current graph, not yet placed on the session timeline: that happens
    /// when their first audio arrives, not when the device is started (~1 s later).
    private var awaitingFirstAudio: Set<Speaker> = []
    private var recentRebuilds: [ContinuousClock.Instant] = []
    private var stopped = false

    /// How many times capture was rebuilt, and how many realtime overloads the device reported.
    public private(set) var rebuilds = 0
    public private(set) var overloads = 0

    public init(source: CallSource, useMicrophone: Bool = true, silenceSource: Bool = false,
                cancelEcho: Bool = true, segmenter: Segmenter.Config = .init(), callbacks: Callbacks) {
        self.silenceSource = silenceSource
        self.cancelEcho = cancelEcho
        sourceBundleID = source.bundleID
        processes = source.processes.map(\.objectID)
        bundleIDs = source.restorableBundleIDs
        self.useMicrophone = useMicrophone
        segmenterConfig = segmenter
        self.callbacks = callbacks
    }

    /// Session seconds since `start`, on the host clock. Used only to place rebuilds.
    private var elapsed: Double {
        guard let startedAt else { return 0 }
        let d = ContinuousClock.now - startedAt
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Don't call `start` or `stop` from a callback: callbacks run on the capture queue.
    public func start() throws(CaptureError) {
        var failure: CaptureError?
        queue.sync {
            startedAt = .now
            do { try build(at: 0) } catch { failure = error as? CaptureError ?? CaptureError("start capture", -1); return }
            processListener = Listener(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), queue) { [weak self] in
                self?.processesChanged()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        if let failure { throw failure }
    }

    /// Drains what's left, ends in-progress utterances, and releases the devices.
    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            tick()
            let end = elapsed
            for segmenter in segmenters.values { segmenter.flush() }
            for (speaker, since) in darkSince where end > since {
                callbacks.gap(.init(track: speaker, start: since, end: end, reason: .deviceRebuild))
            }
            darkSince = [:]
            teardown()
            processListener = nil
        }
    }

    /// Tears capture down and rebuilds it, as a device change would. For tests and the harness.
    public func forceRebuild() {
        queue.async { [weak self] in self?.rebuild() }
    }

    public var microphoneName: String? {
        queue.sync { session?.microphoneName }
    }

    public var diagnostics: (rebuilds: Int, overloads: Int, sampleRate: Double) {
        queue.sync { (rebuilds, overloads, session?.sampleRate ?? 0) }
    }

    /// Echo cancellation so far: dB removed while the far end talked, and how many 10 ms frames.
    public var echoDiagnostics: (erleDb: Double?, farActiveFrames: Int)? {
        queue.sync { echo.map { ($0.erleDb, $0.farActiveFrames) } }
    }

    // MARK: - Build and rebuild

    private func build(at time: Double) throws(CaptureError) {
        let session = try CaptureSession(processes: processes, bundleIDs: bundleIDs, useMicrophone: useMicrophone,
                                         silenceSource: silenceSource)
        try session.start()
        self.session = session
        micDevice = session.worker == nil ? nil : CA.defaultInputDevice

        var live: [Speaker: Transcript.Track] = [.client: .init(source: "tap:\(sourceBundleID)")]
        if session.worker != nil, let mic = micDevice {
            live[.worker] = .init(source: "mic:\(CA.uid(mic) ?? session.microphoneName ?? "default")")
        }
        for speaker in live.keys {
            resamplers[speaker] = Resampler(inputRate: session.sampleRate)
            droppedSoFar[speaker] = 0
            if segmenters[speaker] == nil {
                segmenters[speaker] = Segmenter(speaker: speaker, config: segmenterConfig) { [callbacks] in
                    callbacks.utterance($0)
                }
            }
        }
        awaitingFirstAudio = Set(live.keys)
        // A new device means a new acoustic path: adapt from scratch.
        echo = cancelEcho && live[.worker] != nil ? EchoCanceller() : nil
        // A track that existed before and didn't come back is dark from now on.
        for speaker in segmenters.keys where live[speaker] == nil && darkSince[speaker] == nil {
            darkSince[speaker] = time
            resamplers[speaker] = nil
        }
        callbacks.tracks(live)
        watchDevices()
    }

    private func teardown() {
        listeners.removeAll()
        session?.stop()
        session = nil
    }

    private func scheduleRebuild() {
        guard !rebuildPending, !stopped else { return }
        rebuildPending = true
        // Device changes arrive in bursts; let them settle. If rebuilds keep coming anyway,
        // back off rather than chop the session into pieces.
        let now = ContinuousClock.now
        recentRebuilds.removeAll { now - $0 > .seconds(30) }
        let delay: Duration = recentRebuilds.count >= 3 ? .seconds(5) : .milliseconds(300)
        queue.asyncAfter(deadline: .now() + delay.timeInterval) { [weak self] in
            guard let self else { return }
            rebuildPending = false
            // Still wrong after settling? (A forced rebuild skips this check.)
            if devicesChanged { rebuild() }
        }
    }

    private func rebuild() {
        guard !stopped else { return }
        tick()
        for (speaker, segmenter) in segmenters where darkSince[speaker] == nil {
            segmenter.flush()
            darkSince[speaker] = segmenter.now
        }
        teardown()
        rebuilds += 1
        recentRebuilds.append(.now)
        do {
            try build(at: elapsed)
        } catch {
            // No device right now (e.g. mid-unplug). Everything stays dark; try again.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebuild() }
        }
    }

    // MARK: - Watching

    /// Listens broadly, but rebuilds only when something we depend on actually changed.
    /// Building an aggregate itself fires notifications on the mic (sample rate, alive), so
    /// rebuilding on every notification loops: one forced rebuild became 30 (2026-09-23).
    private func watchDevices() {
        builtMicRate = micDevice.map(CA.nominalSampleRate) ?? 0
        let check: @Sendable () -> Void = { [weak self] in self?.checkDevices() }
        listeners.append(Listener(CA.system, CA.address(kAudioHardwarePropertyDefaultInputDevice), queue, check))
        // A device appearing or vanishing (USB mic unplugged, AirPods connecting).
        listeners.append(Listener(CA.system, CA.address(kAudioHardwarePropertyDevices), queue, check))
        if let mic = micDevice {
            listeners.append(Listener(mic, CA.address(kAudioDevicePropertyNominalSampleRate), queue, check))
            listeners.append(Listener(mic, CA.address(kAudioDevicePropertyDeviceIsAlive), queue, check))
        }
        if let aggregate = session?.aggregateID {
            listeners.append(Listener(aggregate, CA.address(kAudioDevicePropertyDeviceIsAlive), queue, check))
            listeners.append(Listener(aggregate, CA.address(kAudioDeviceProcessorOverload), queue) { [weak self] in
                self?.overloads += 1
            })
        }
    }

    /// What would make the current capture graph wrong.
    private var devicesChanged: Bool {
        if let aggregate = session?.aggregateID, CA.read(aggregate, kAudioDevicePropertyDeviceIsAlive, UInt32(1)) == 0 {
            return true
        }
        // Covers the mic unplugged, a new default input, and a mic arriving mid-session.
        if useMicrophone, CA.defaultInputDevice != micDevice { return true }
        if let mic = micDevice {
            if CA.read(mic, kAudioDevicePropertyDeviceIsAlive, UInt32(1)) == 0 { return true }
            if CA.nominalSampleRate(mic) != builtMicRate { return true } // e.g. AirPods profile switch
        }
        return false
    }

    private func checkDevices() {
        if !stopped, devicesChanged { scheduleRebuild() }
    }

    /// The call app's helper set changed: follow it without rebuilding.
    private func processesChanged() {
        guard !stopped, let session else { return }
        let current = CallSources.group(AudioProcessList.snapshot())
            .first { $0.bundleID == sourceBundleID }?.processes.map(\.objectID) ?? []
        // If the app quit, keep the old list: the tap goes quiet, and resumes when it's back.
        guard !current.isEmpty, Set(current) != Set(processes) else { return }
        processes = current
        if !session.updateProcesses(current) { scheduleRebuild() }
    }

    // MARK: - Consuming

    /// Places a new graph's tracks on the session timeline once audio is flowing: sample 0
    /// is `now - buffered`. Closes any `device_rebuild` gap at that point.
    private func placeOnTimeline(_ session: CaptureSession) {
        let buffered = max(session.client.available, session.worker?.available ?? 0)
        guard !awaitingFirstAudio.isEmpty, buffered > 0 else { return }
        var start = elapsed - Double(buffered) / session.sampleRate
        // Never overlap what was already on the timeline before the rebuild.
        start = max(start, darkSince.values.max() ?? 0, 0)
        for speaker in awaitingFirstAudio {
            segmenters[speaker]?.rebase(to: start)
            if let since = darkSince.removeValue(forKey: speaker), start - since > 0.05 {
                callbacks.gap(.init(track: speaker, start: since, end: start, reason: .deviceRebuild))
            }
        }
        awaitingFirstAudio = []
    }

    private func tick() {
        guard let session else { return }
        placeOnTimeline(session)
        guard awaitingFirstAudio.isEmpty else { return }
        var levels: [Speaker: Float] = [:]
        // The client drains first, so its audio is the echo reference before the mic needs it.
        session.drain { speaker, samples in
            levels[speaker] = max(levels[speaker] ?? 0, rms(samples))
            guard let resampler = resamplers[speaker], let segmenter = segmenters[speaker] else { return }
            resampler.convert(samples) { pcm in
                switch (speaker, echo) {
                case (.client, let echo?):
                    echo.reference(pcm)
                    segmenter.process(pcm)
                case (.worker, let echo?):
                    echo.process(pcm) { segmenter.process($0) }
                default:
                    segmenter.process(pcm)
                }
            }
        }
        // The ring dropped audio because we fell behind: say so, and keep timestamps honest.
        for (speaker, ring) in [(Speaker.client, session.client), (.worker, session.worker)] {
            guard let ring, let segmenter = segmenters[speaker] else { continue }
            let dropped = ring.totalDropped - (droppedSoFar[speaker] ?? 0)
            guard dropped > 0 else { continue }
            droppedSoFar[speaker] = ring.totalDropped
            let start = segmenter.now
            let end = start + Double(dropped) / session.sampleRate
            segmenter.rebase(to: end)
            callbacks.gap(.init(track: speaker, start: start, end: end, reason: .captureOverrun))
        }
        for (speaker, segmenter) in segmenters where darkSince[speaker] == nil {
            callbacks.settled(speaker, segmenter.settledThrough)
        }
        callbacks.levels(levels)
    }
}

/// A CoreAudio property listener that removes itself when released.
final class Listener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ queue: DispatchQueue,
         _ handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
