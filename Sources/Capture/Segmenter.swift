import AVFoundation
import Darwin
import ScribeskiCore

/// Per-track voice-activity segmenter (BUILD_PLAN P2.3). Takes 16 kHz Int16 audio in any
/// chunk size and emits `Utterance`s of at most `maxSeconds`. Each track is single-speaker,
/// so segments are clean by construction; this only has to find where speech is.
///
/// Energy-based with an adaptive noise floor: deterministic and testable. Every buffer it
/// owns is locked and wiped (see `LockedPCM`).
public final class Segmenter {
    public struct Config: Sendable {
        public var frameMs = 20
        /// Audio kept from before speech onset so the first syllable isn't clipped.
        public var preRollMs = 300
        /// Silence that ends an utterance.
        public var hangoverMs = 700
        /// Silence kept after the last speech frame.
        public var tailMs = 200
        /// Consecutive speech frames that start an utterance.
        public var onsetFrames = 2
        /// Utterances with less speech than this are dropped as clicks and blips.
        public var minSpeechMs = 200
        public var maxSeconds = 30.0
        /// Speech must be this far above the noise floor…
        public var marginDb = 10.0
        /// …and above this absolute level.
        public var minSpeechDb = -55.0

        public init() {}
    }

    public let speaker: Speaker
    public let config: Config
    private let onUtterance: (Utterance) -> Void

    private let frameSize: Int
    private var frame: [Int16]
    private var frameFill = 0

    /// Session seconds of sample 0 since the last `rebase`.
    private var timeBase = 0.0
    private var samplesSinceBase = 0

    private var noiseFloorDb = -90.0
    private var onsetCount = 0
    private let preRoll: LockedRing

    private var current: AVAudioPCMBuffer?
    private var currentStart = 0.0
    /// Per-frame energy of the current utterance, for choosing where to split a long one.
    private var frameEnergies: [Double] = []
    private var speechFrames = 0
    private var silentFrames = 0
    private var lastSpeechEnd = 0

    public init(speaker: Speaker, config: Config = Config(), onUtterance: @escaping (Utterance) -> Void) {
        self.speaker = speaker
        self.config = config
        self.onUtterance = onUtterance
        frameSize = Int(SpeechAudio.sampleRate) * config.frameMs / 1000
        frame = [Int16](repeating: 0, count: frameSize)
        preRoll = LockedRing(capacity: Int(SpeechAudio.sampleRate) * config.preRollMs / 1000)
    }

    deinit {
        frame.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) }
    }

    /// Session time of the next sample to arrive.
    public var now: Double { timeBase + Double(samplesSinceBase) / SpeechAudio.sampleRate }

    /// No utterance this segmenter emits later can start before this: the start of the one in
    /// progress, or else the oldest audio held for pre-roll.
    public var settledThrough: Double {
        if current != nil { return currentStart }
        return now - Double(preRoll.count + frameFill) / SpeechAudio.sampleRate
    }

    /// Feeds audio. Emits zero or more utterances through the callback.
    public func process(_ samples: UnsafeBufferPointer<Int16>) {
        var i = 0
        while i < samples.count {
            let n = min(frameSize - frameFill, samples.count - i)
            for k in 0..<n { frame[frameFill + k] = samples[i + k] }
            frameFill += n
            i += n
            if frameFill == frameSize {
                frame.withUnsafeBufferPointer { processFrame($0) }
                frameFill = 0
            }
        }
    }

    /// Ends any utterance in progress (at Stop, or before a device rebuild).
    public func flush() {
        if current != nil { finish(trimToSpeech: true) }
        preRoll.clear()
        onsetCount = 0
        frameFill = 0
    }

    /// After a capture rebuild: the next sample is at `sessionTime`.
    public func rebase(to sessionTime: Double) {
        flush()
        timeBase = sessionTime
        samplesSinceBase = 0
    }

    // MARK: - Frames

    private func processFrame(_ f: UnsafeBufferPointer<Int16>) {
        let db = Self.energyDb(f)
        let isSpeech = db > max(noiseFloorDb + config.marginDb, config.minSpeechDb)
        let frameStart = now
        samplesSinceBase += f.count

        if current == nil {
            // Track the floor only outside speech: fall fast, rise slowly.
            noiseFloorDb = db < noiseFloorDb ? db : noiseFloorDb + (db - noiseFloorDb) * 0.02
            noiseFloorDb = min(max(noiseFloorDb, -90), -30)
            preRoll.push(f)
            onsetCount = isSpeech ? onsetCount + 1 : 0
            if onsetCount >= config.onsetFrames { begin(onsetEnd: frameStart + Double(f.count) / SpeechAudio.sampleRate) }
            return
        }

        current!.append(f)
        frameEnergies.append(db)
        if isSpeech {
            speechFrames += 1
            silentFrames = 0
            lastSpeechEnd = Int(current!.frameLength)
        } else {
            silentFrames += 1
            if silentFrames * config.frameMs >= config.hangoverMs {
                finish(trimToSpeech: true)
                return
            }
        }
        if Double(current!.frameLength) >= config.maxSeconds * SpeechAudio.sampleRate {
            split()
        }
    }

    private func begin(onsetEnd: Double) {
        let buffer = LockedPCM.make(capacity: Int(config.maxSeconds * SpeechAudio.sampleRate))
        let held = preRoll.drain(into: buffer)
        currentStart = onsetEnd - Double(held) / SpeechAudio.sampleRate
        current = buffer
        frameEnergies = Array(repeating: -90, count: held / frameSize)
        speechFrames = config.onsetFrames
        silentFrames = 0
        lastSpeechEnd = Int(buffer.frameLength)
        onsetCount = 0
    }

    private func finish(trimToSpeech: Bool) {
        guard let buffer = current else { return }
        current = nil
        let tail = Int(SpeechAudio.sampleRate) * config.tailMs / 1000
        let length = trimToSpeech ? min(Int(buffer.frameLength), lastSpeechEnd + tail) : Int(buffer.frameLength)
        let enoughSpeech = speechFrames * config.frameMs >= config.minSpeechMs
        if enoughSpeech, length > 0 {
            onUtterance(Utterance(speaker: speaker, start: currentStart, buffer: Self.copy(buffer, frames: length)))
        }
        frameEnergies.removeAll(keepingCapacity: true)
        speechFrames = 0
        silentFrames = 0
    }

    /// At the length cap: cut at the quietest frame in the last 2 s, emit the first part,
    /// and carry the rest into a new utterance so no word is split if we can help it.
    private func split() {
        guard let buffer = current else { return }
        let window = min(frameEnergies.count, 2000 / config.frameMs)
        let startIndex = frameEnergies.count - window
        let quietest = (startIndex..<frameEnergies.count).min { frameEnergies[$0] < frameEnergies[$1] } ?? frameEnergies.count
        let cut = min((quietest + 1) * frameSize, Int(buffer.frameLength))

        let head = Self.copy(buffer, frames: cut)
        let rest = Int(buffer.frameLength) - cut
        onUtterance(Utterance(speaker: speaker, start: currentStart, buffer: head))

        let next = LockedPCM.make(capacity: Int(config.maxSeconds * SpeechAudio.sampleRate))
        next.append(UnsafeBufferPointer(start: buffer.int16Samples.baseAddress! + cut, count: rest))
        currentStart += Double(cut) / SpeechAudio.sampleRate
        current = next
        frameEnergies = Array(frameEnergies.suffix(from: min(quietest + 1, frameEnergies.count)))
        speechFrames = frameEnergies.filter { $0 > config.minSpeechDb }.count
        lastSpeechEnd = rest
    }

    /// A right-sized locked copy, so a short utterance doesn't pin 30 s of locked memory.
    private static func copy(_ buffer: AVAudioPCMBuffer, frames: Int) -> AVAudioPCMBuffer {
        let out = LockedPCM.make(capacity: frames)
        out.append(UnsafeBufferPointer(start: buffer.int16Samples.baseAddress, count: frames))
        return out
    }

    static func energyDb(_ f: UnsafeBufferPointer<Int16>) -> Double {
        guard !f.isEmpty else { return -90 }
        var sum = 0.0
        for s in f { let x = Double(s) / 32768; sum += x * x }
        let rms = (sum / Double(f.count)).squareRoot()
        return rms > 0 ? max(20 * log10(rms), -90) : -90
    }
}

/// Small locked circular buffer of Int16 for the segmenter's pre-roll.
final class LockedRing {
    private let storage: AVAudioPCMBuffer
    private let capacity: Int
    private var start = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = LockedPCM.make(capacity: capacity)
        storage.frameLength = AVAudioFrameCount(capacity)
    }

    private var base: UnsafeMutablePointer<Int16> { storage.int16ChannelData![0] }

    func push(_ samples: UnsafeBufferPointer<Int16>) {
        for s in samples {
            base[(start + count) % capacity] = s
            if count < capacity { count += 1 } else { start = (start + 1) % capacity }
        }
    }

    /// Moves everything held into `buffer`, oldest first, and clears. Returns frames moved.
    func drain(into buffer: AVAudioPCMBuffer) -> Int {
        let first = min(count, capacity - start)
        buffer.append(UnsafeBufferPointer(start: base + start, count: first))
        buffer.append(UnsafeBufferPointer(start: base, count: count - first))
        let moved = count
        clear()
        return moved
    }

    func clear() {
        memset_s(base, capacity * 2, 0, capacity * 2)
        start = 0
        count = 0
    }
}
