import AVFoundation
import Darwin
import ScribeskiCore

/// The format every Scribeski-owned audio buffer downstream of capture uses: 16 kHz mono
/// Int16 (BUILD_PLAN P2.3). SpeechAnalyzer's `bestAvailableAudioFormat` asks for exactly this.
public enum SpeechAudio {
    public static let sampleRate = 16_000.0
    public static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                             channels: 1, interleaved: true)!
}

/// A block of 16 kHz Int16 samples in `mlock`ed memory, handed to transcribers as an
/// `AVAudioPCMBuffer` that points straight at it (no copy). When the last reference goes —
/// ours, or the transcriber's — the memory is wiped with `memset_s` and freed (DESIGN §3a).
public enum LockedPCM {
    /// Allocates a zeroed, locked buffer for up to `capacity` frames.
    public static func make(capacity: Int) -> AVAudioPCMBuffer {
        let bytes = max(capacity, 1) * MemoryLayout<Int16>.stride
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        memset(data, 0, bytes)
        let locked = mlock(data, bytes) == 0
        // AVAudioPCMBuffer copies the list struct; the deallocator gets its copy, so only
        // the sample memory is ours to free.
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: data))
        let buffer = AVAudioPCMBuffer(pcmFormat: SpeechAudio.format, bufferListNoCopy: &list) { _ in
            memset_s(data, bytes, 0, bytes)
            if locked { munlock(data, bytes) }
            data.deallocate()
        }!
        buffer.frameLength = 0
        return buffer
    }
}

extension AVAudioPCMBuffer {
    /// Appends Int16 frames, up to capacity. Returns how many fit.
    @discardableResult
    func append(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        let room = Int(frameCapacity - frameLength)
        let n = min(room, samples.count)
        guard n > 0, let base = samples.baseAddress, let dst = int16ChannelData?[0] else { return 0 }
        (dst + Int(frameLength)).update(from: base, count: n)
        frameLength += AVAudioFrameCount(n)
        return n
    }

    public var int16Samples: UnsafeBufferPointer<Int16> {
        UnsafeBufferPointer(start: int16ChannelData?[0], count: Int(frameLength))
    }
}

/// One stretch of speech on one track, ready to transcribe.
public struct Utterance: @unchecked Sendable {
    public let speaker: Speaker
    /// Session seconds of the first sample, on the capture clock.
    public let start: Double
    /// 16 kHz mono Int16 in locked memory. Wiped when released.
    public let buffer: AVAudioPCMBuffer

    public var duration: Double { Double(buffer.frameLength) / SpeechAudio.sampleRate }
    public var end: Double { start + duration }

    public init(speaker: Speaker, start: Double, buffer: AVAudioPCMBuffer) {
        self.speaker = speaker
        self.start = start
        self.buffer = buffer
    }
}
