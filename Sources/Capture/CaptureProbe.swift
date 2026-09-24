import CoreAudio
import Foundation
import ScribeskiCore

/// Dev check for P2.2: capture from one app for a few seconds and report levels, frame
/// counts, and drops. Reports numbers only; no audio leaves memory.
public enum CaptureProbe {
    public struct Report: Codable, Sendable {
        public var source: String
        public var processes: [Int32]
        public var sampleRate: Double
        public var inputLayout: [Int]
        public var microphone: String?
        public var seconds: Double
        public var frames: [String: Int]
        public var dropped: [String: Int]
        /// RMS per track per second.
        public var rms: [String: [Float]]
    }

    public static func run(bundleID: String, seconds: Double) throws -> Report {
        let sources = CallSources.group(AudioProcessList.snapshot())
        guard let source = sources.first(where: { $0.bundleID == bundleID }) else {
            throw CaptureError("find \(bundleID) among audio processes", kAudioHardwareBadObjectError)
        }
        let session = try CaptureSession(processes: source.processes.map(\.objectID))
        try session.start()

        var frames: [Speaker: Int] = [:]
        var sumSquares: [Speaker: Double] = [:]
        var perSecond: [Speaker: [Float]] = [:]
        var windowFrames: [Speaker: Int] = [:]
        let window = Int(session.sampleRate)
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            session.drain { track, samples in
                for s in samples {
                    sumSquares[track, default: 0] += Double(s * s)
                    windowFrames[track, default: 0] += 1
                    if windowFrames[track] == window {
                        perSecond[track, default: []].append(Float((sumSquares[track]! / Double(window)).squareRoot()))
                        sumSquares[track] = 0
                        windowFrames[track] = 0
                    }
                }
                frames[track, default: 0] += samples.count
            }
        }
        let report = Report(
            source: source.name,
            processes: source.processes.map(\.pid),
            sampleRate: session.sampleRate,
            inputLayout: session.inputLayout,
            microphone: session.microphoneName,
            seconds: seconds,
            frames: Dictionary(uniqueKeysWithValues: frames.map { ($0.key.rawValue, $0.value) }),
            dropped: ["client": session.client.totalDropped, "worker": session.worker?.totalDropped ?? 0],
            rms: Dictionary(uniqueKeysWithValues: perSecond.map { ($0.key.rawValue, $0.value) }))
        session.stop()
        return report
    }
}
