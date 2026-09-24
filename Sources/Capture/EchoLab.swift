import Foundation
import ScribeskiCore

/// Dev: tunes echo cancellation on this Mac's real acoustic path. Captures the tap and the mic
/// for a while into memory (never disk), then runs each configuration over the same audio
/// and reports ERLE. `Scribeski --aec-lab <bundle|pid:N> <seconds> <out.json>`.
public enum EchoLab {
    public struct Config: Codable, Sendable {
        public var filterMs: Int
        public var frame: Int
        public var suppressDb: Int32
        public var suppressActiveDb: Int32
        public var noiseSuppressDb: Int32?
    }

    public struct Result: Codable, Sendable {
        public var config: Config
        /// First pass (includes convergence) and second pass over the same audio (converged).
        public var erleDb: Double?
        public var convergedErleDb: Double?
    }

    public static let configs: [Config] = [
        .init(filterMs: 128, frame: 160, suppressDb: -40, suppressActiveDb: -15, noiseSuppressDb: nil),
        .init(filterMs: 128, frame: 160, suppressDb: -40, suppressActiveDb: -15, noiseSuppressDb: -3),
        .init(filterMs: 128, frame: 160, suppressDb: -40, suppressActiveDb: -15, noiseSuppressDb: -6),
        .init(filterMs: 128, frame: 160, suppressDb: -60, suppressActiveDb: -30, noiseSuppressDb: -6),
        .init(filterMs: 250, frame: 160, suppressDb: -40, suppressActiveDb: -15, noiseSuppressDb: -6),
        .init(filterMs: 250, frame: 160, suppressDb: -60, suppressActiveDb: -30, noiseSuppressDb: -6),
        .init(filterMs: 250, frame: 160, suppressDb: -60, suppressActiveDb: -30, noiseSuppressDb: -15),
    ]

    /// Runs `configs` over captured (reference, mic) audio at 16 kHz.
    public static func evaluate(reference: [Int16], mic: [Int16], configs: [Config] = configs) -> [Result] {
        configs.map { c in
            let aec = EchoCanceller(filterMs: c.filterMs, frame: c.frame, suppressDb: c.suppressDb,
                                    suppressActiveDb: c.suppressActiveDb, noiseSuppressDb: c.noiseSuppressDb)
            func pass() {
                let chunk = 800
                for start in stride(from: 0, to: min(reference.count, mic.count), by: chunk) {
                    let end = min(start + chunk, reference.count, mic.count)
                    reference[start..<end].withUnsafeBufferPointer { aec.reference($0) }
                    mic[start..<end].withUnsafeBufferPointer { aec.process($0) { _ in } }
                }
            }
            pass()
            let first = aec.erleDb
            aec.resetMeter()
            pass()
            return Result(config: c, erleDb: first, convergedErleDb: aec.erleDb)
        }
    }

    /// Captures `seconds` of both tracks, resampled to 16 kHz, into memory.
    public static func capture(processes: [UInt32], seconds: Double) throws -> (reference: [Int16], mic: [Int16]) {
        let session = try CaptureSession(processes: processes)
        guard session.worker != nil else { throw CaptureError("find a microphone", -1) }
        try session.start()
        defer { session.stop() }
        let resamplers: [Speaker: Resampler] = [.client: Resampler(inputRate: session.sampleRate),
                                                          .worker: Resampler(inputRate: session.sampleRate)]
        var out: [Speaker: [Int16]] = [.client: [], .worker: []]
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            session.drain { speaker, samples in
                resamplers[speaker]!.convert(samples) { out[speaker]!.append(contentsOf: $0) }
            }
        }
        return (out[.client]!, out[.worker]!)
    }
}
