import CSpeexEcho
import Darwin

/// Removes the call's audio from the mic (BUILD_PLAN P2.2). A worker on speakers instead of
/// headphones puts the client's voice into the mic; the call app cancels that echo on its
/// own mic stream, not ours. We have what an echo canceller needs most: the exact far-end
/// signal (the tap) on the same clock as the mic (one aggregate device).
///
/// SpeexDSP's MDF adaptive filter (vendored, BSD), then its preprocessor for residual echo
/// suppression, which Speex only applies through its noise suppressor, so that runs with a
/// shallow -6 dB floor. AGC and dereverb stay off. 16 kHz Int16, 10 ms frames.
public final class EchoCanceller {
    public static let frameSize = 160
    private let echo: OpaquePointer
    private let preprocess: OpaquePointer
    /// Far-end (client) audio not yet matched with mic audio, and mic audio short of a frame.
    private var reference: [Int16] = []
    private var mic: [Int16] = []
    private var out: [Int16]
    /// Mic audio held waiting for its reference before the tap counts as stalled.
    static let stallFrames = 4_800
    /// Beyond this, the reference is running ahead of the mic (shouldn't happen on one clock).
    private let maxReference = 16_000

    /// Echo return loss enhancement, measured live over frames where the far end is talking:
    /// mic energy in vs out. Diagnostics only; no audio is kept.
    public private(set) var farActiveFrames = 0
    private var energyIn = 0.0
    private var energyOut = 0.0
    public var erleDb: Double? {
        farActiveFrames > 50 && energyOut > 0 ? 10 * log10(energyIn / energyOut) : nil
    }

    public let frame: Int

    /// `noiseSuppressDb`: Speex applies residual echo suppression only through its noise
    /// suppressor's gain, so that must be on; a shallow noise floor keeps it from reshaping
    /// the worker's voice.
    /// Defaults tuned on a Mac mini speaker + USB mic with `--aec-lab` (2026-09-23): a 128 ms
    /// filter converges fastest (17 dB ERLE on first pass, 24 dB converged, vs 13/16 dB with
    /// the suppressor off). Longer filters converge slower for no converged gain.
    public init(filterMs: Int = 128, frame: Int = EchoCanceller.frameSize, suppressDb: Int32 = -60,
                suppressActiveDb: Int32 = -30, noiseSuppressDb: Int32? = -6) {
        self.frame = frame
        out = [Int16](repeating: 0, count: frame)
        echo = speex_echo_state_init(Int32(frame), Int32(16 * filterMs))
        var rate: Int32 = 16_000
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        preprocess = speex_preprocess_state_init(Int32(frame), rate)
        var off: Int32 = 0
        var denoise: Int32 = noiseSuppressDb == nil ? 0 : 1
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &denoise)
        if var floor = noiseSuppressDb { speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &floor) }
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DEREVERB, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        var suppress = suppressDb, active = suppressActiveDb
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &suppress)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &active)
        // Sized once so they never reallocate (a reallocation leaves the old audio in freed
        // memory); `consume` zeroes what it shifts out.
        reference.reserveCapacity(2 * maxReference)
        mic.reserveCapacity(2 * maxReference)
    }

    deinit {
        speex_preprocess_state_destroy(preprocess)
        speex_echo_state_destroy(echo)
        wipe(&reference)
        wipe(&mic)
        wipe(&out)
    }

    /// The client's audio, as it went to the speakers.
    public func reference(_ samples: UnsafeBufferPointer<Int16>) {
        reference.append(contentsOf: samples)
        if reference.count > maxReference { Self.consume(&reference, reference.count - maxReference) }
    }

    /// Mic audio in; echo-cancelled mic audio out, in whole frames (up to 10 ms held back).
    public func process(_ samples: UnsafeBufferPointer<Int16>, _ emit: (UnsafeBufferPointer<Int16>) -> Void) {
        mic.append(contentsOf: samples)
        let n = frame
        var used = 0
        while mic.count - used >= n {
            if reference.count < n {
                // The mic can run a callback ahead of the reference within one drain. Wait for
                // it: padding would shift the two out of alignment for good. Only a real tap
                // stall (300 ms of mic with no reference) is treated as silence.
                guard mic.count - used >= Self.stallFrames else { break }
                reference.append(contentsOf: repeatElement(0, count: n - reference.count))
            }
            mic.withUnsafeBufferPointer { m in
                reference.withUnsafeBufferPointer { r in
                    out.withUnsafeMutableBufferPointer { o in
                        speex_echo_cancellation(echo, m.baseAddress! + used, r.baseAddress!, o.baseAddress!)
                        _ = speex_preprocess_run(preprocess, o.baseAddress!)
                        let far = Self.energy(r.baseAddress!, n)
                        if far > 1e5 { // about -50 dBFS: the far end is talking
                            farActiveFrames += 1
                            energyIn += Self.energy(m.baseAddress! + used, n)
                            energyOut += Self.energy(o.baseAddress!, n)
                        }
                    }
                }
            }
            Self.consume(&reference, n)
            used += n
            out.withUnsafeBufferPointer(emit)
        }
        Self.consume(&mic, used)
    }

    /// Restarts the ERLE meter without resetting the filter (to measure converged performance).
    public func resetMeter() {
        farActiveFrames = 0
        energyIn = 0
        energyOut = 0
    }

    /// After a device rebuild the acoustic path may differ: start adapting from scratch.
    public func reset() {
        speex_echo_state_reset(echo)
        wipe(&reference)
        wipe(&mic)
        reference = []
        mic = []
    }

    static func energy(_ p: UnsafePointer<Int16>, _ n: Int) -> Double {
        var e = 0.0
        for i in 0..<n { let x = Double(p[i]); e += x * x }
        return e / Double(n)
    }

    /// Drops the first `n` samples and zeroes the slots the shift vacated (still in the
    /// buffer, past `count`): appending zeros within capacity overwrites them, no reallocation.
    static func consume(_ a: inout [Int16], _ n: Int) {
        guard n > 0 else { return }
        a.removeFirst(n)
        a.append(contentsOf: repeatElement(0, count: n))
        a.removeLast(n)
    }

    private func wipe(_ a: inout [Int16]) {
        a.withUnsafeMutableBytes { if let b = $0.baseAddress { memset_s(b, $0.count, 0, $0.count) } }
    }
}
