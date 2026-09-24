import AVFoundation

/// Converts one track from the capture device's rate (Float32 mono) to 16 kHz Int16 mono.
/// Keeps converter state between calls, so chunk boundaries don't click.
final class Resampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    /// Largest input slice converted at once; bounds the output buffer.
    private let slice: Int
    private let output: AVAudioPCMBuffer

    init(inputRate: Double) {
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1,
                                    interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: SpeechAudio.format)!
        slice = Int(inputRate / 10) // 100 ms
        output = LockedPCM.make(capacity: Int(SpeechAudio.sampleRate / 10) + 256)
    }

    /// Converts `samples` and hands the 16 kHz result to `body` (possibly in several calls).
    /// The output memory is reused and wiped after each call.
    func convert(_ samples: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Int16>) -> Void) {
        var offset = 0
        while offset < samples.count {
            let n = min(slice, samples.count - offset)
            convertSlice(UnsafeBufferPointer(rebasing: samples[offset..<offset + n]), body)
            offset += n
        }
    }

    private func convertSlice(_ samples: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Int16>) -> Void) {
        guard let base = samples.baseAddress else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: UnsafeMutableRawPointer(mutating: base)))
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: &list, deallocator: nil) else { return }
        input.frameLength = AVAudioFrameCount(samples.count)

        var supplied = false
        output.frameLength = 0
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if output.frameLength > 0 { body(output.int16Samples) }
        let bytes = Int(output.frameCapacity) * 2
        memset_s(output.int16ChannelData![0], bytes, 0, bytes)
    }
}
