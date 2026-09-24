import CoreAudio
import Foundation
import ScribeskiCore

/// One private aggregate device holding the mic (main sub-device, so its clock drives
/// everything) and a per-process tap on the call app, read by a single IOProc
/// (BUILD_PLAN P2.2). One clock means the two tracks can't drift apart.
///
/// Without an input device the aggregate runs tap-only, clocked by the default output device,
/// and `worker` is nil. The caller decides whether that's acceptable.
public final class CaptureSession: @unchecked Sendable {
    public let sampleRate: Double
    public let client: RingBuffer
    public let worker: RingBuffer?
    /// Name of the mic in use, for the UI. Nil when running tap-only.
    public let microphoneName: String?

    private let tap: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false

    /// - Parameters:
    ///   - processes: CoreAudio process object IDs to tap (a `CallSource`'s processes).
    ///   - useMicrophone: include the default input device as the worker track.
    ///   - ringSeconds: how much audio each ring holds before the producer starts dropping.
    ///     The consumer drains continuously, so this only has to cover consumer hiccups.
    ///   - silenceSource: test harness only. Mutes the tapped process's output (the tap still
    ///     hears it), so synthetic sessions don't play through the room. Never in a real session:
    ///     the worker must hear the call.
    ///   - bundleIDs: also follow these apps by bundle ID (macOS 26), re-attaching when they
    ///     restart or first start: a native call app launched, or relaunched, mid-session.
    ///     Never a browser's (see `CallSource.restorableBundleIDs`).
    public init(processes: [AudioObjectID], bundleIDs: [String] = [], useMicrophone: Bool = true,
                ringSeconds: Double = 8, silenceSource: Bool = false) throws(CaptureError) {
        precondition(!processes.isEmpty || !bundleIDs.isEmpty, "tap needs a process or a bundle ID")
        // Mono mixdown of just these processes. Never a global tap: we'd capture ourselves.
        tap = CATapDescription(monoMixdownOfProcesses: processes)
        if !bundleIDs.isEmpty {
            tap.bundleIDs = bundleIDs
            tap.isProcessRestoreEnabled = true
        }
        tap.name = "Scribeski client track"
        tap.isPrivate = true
        // Asserted explicitly: muted or mutedWhenTapped would silence the call for the worker.
        tap.muteBehavior = silenceSource ? .muted : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CaptureError.check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")
        self.tapID = tapID

        let mic = useMicrophone ? CA.defaultInputDevice : nil
        guard let clock = mic ?? CA.defaultOutputDevice, let clockUID = CA.uid(clock) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError("find a clock device", kAudioHardwareBadDeviceError)
        }
        microphoneName = mic.flatMap { CA.string($0, kAudioObjectPropertyName) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribeski capture",
            kAudioAggregateDeviceUIDKey: "com.looski.scribeski.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError("create aggregate device", status)
        }
        self.aggregateID = aggregateID

        sampleRate = CA.nominalSampleRate(aggregateID)
        let capacity = Int(max(sampleRate, 48_000) * ringSeconds)
        client = RingBuffer(capacity: capacity)
        worker = mic == nil ? nil : RingBuffer(capacity: capacity)
    }

    deinit {
        stop()
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    /// The aggregate's input buffers, in IOProc order: the mic's streams (if any), then the
    /// tap's. Verified 2026-09-23 with a RØDE VideoMic GO II: `[1, 1]`, tap last.
    public var inputLayout: [Int] {
        var address = CA.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .map { Int($0.mNumberChannels) }
    }

    public func start() throws(CaptureError) {
        guard !running else { return }
        // Captured as locals so the realtime block touches no `self` state.
        let client = client
        let worker = worker
        let block: AudioDeviceIOBlock = { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let tapBuffer = buffers.last, let tapData = tapBuffer.mData else { return }
            // Take the first channel of each track; the tap is a mono mixdown already.
            func push(_ buffer: AudioBuffer, _ data: UnsafeMutableRawPointer, into ring: RingBuffer) {
                let channels = max(Int(buffer.mNumberChannels), 1)
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                ring.write(data.assumingMemoryBound(to: Float.self), count: frames, stride: channels)
            }
            push(tapBuffer, tapData, into: client)
            if let worker, buffers.count > 1, let micData = buffers[0].mData {
                push(buffers[0], micData, into: worker)
            }
        }
        var procID: AudioDeviceIOProcID?
        try CaptureError.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "create IOProc")
        self.procID = procID
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID!)
            self.procID = nil
            throw CaptureError("start aggregate device", status)
        }
        running = true
    }

    /// Points the running tap at a new process set (call-app helpers came or went) without
    /// rebuilding. Returns false if CoreAudio refused, in which case the caller rebuilds.
    func updateProcesses(_ processes: [AudioObjectID]) -> Bool {
        tap.processes = processes
        var address = CA.address(kAudioTapPropertyDescription)
        var description = tap
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        return status == noErr
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
        running = false
        client.wipe()
        worker?.wipe()
    }

    /// Consumer side: hands each track's newly captured samples to `body`, then wipes them.
    public func drain(_ body: (Speaker, UnsafeBufferPointer<Float>) -> Void) {
        client.consume { body(.client, $0) }
        worker?.consume { body(.worker, $0) }
    }
}

/// Root-mean-square level of a block of samples, 0...1 for full-scale audio.
public func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    return (sum / Float(samples.count)).squareRoot()
}

/// Test harness only: silences one process's output. A muted tap mutes only while it's
/// running, so this runs one (in its own private aggregate) and throws the audio away.
/// An unread muted tap does nothing: that let a test distractor play aloud for 40 minutes.
public final class ProcessMuter: @unchecked Sendable {
    private let session: CaptureSession
    private let drainer: DispatchSourceTimer

    public init?(processes: [AudioObjectID]) {
        guard !processes.isEmpty,
              let session = try? CaptureSession(processes: processes, useMicrophone: false, ringSeconds: 1,
                                                silenceSource: true),
              (try? session.start()) != nil else { return nil }
        self.session = session
        drainer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        drainer.schedule(deadline: .now(), repeating: .milliseconds(200))
        drainer.setEventHandler { session.drain { _, _ in } }
        drainer.resume()
    }

    deinit {
        drainer.cancel()
        session.stop()
    }
}
