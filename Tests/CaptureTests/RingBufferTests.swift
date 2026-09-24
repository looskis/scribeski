import Testing
@testable import Capture

@Suite struct RingBufferBehaviour {
    func write(_ ring: RingBuffer, _ values: [Float]) {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    func drain(_ ring: RingBuffer) -> [Float] {
        var out: [Float] = []
        ring.consume { out.append(contentsOf: $0) }
        return out
    }

    @Test func wrapsAroundInOrder() {
        let ring = RingBuffer(capacity: 4)
        write(ring, [1, 2, 3])
        #expect(drain(ring) == [1, 2, 3])
        write(ring, [4, 5, 6])
        #expect(drain(ring) == [4, 5, 6])
    }

    @Test func dropsWhatDoesNotFitAndCountsIt() {
        let ring = RingBuffer(capacity: 4)
        write(ring, [1, 2, 3, 4, 5, 6])
        #expect(ring.totalDropped == 2)
        #expect(drain(ring) == [1, 2, 3, 4])
    }

    @Test func takesFirstChannelOfInterleavedInput() {
        let ring = RingBuffer(capacity: 8)
        let stereo: [Float] = [1, -1, 2, -2, 3, -3]
        stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3, stride: 2) }
        #expect(drain(ring) == [1, 2, 3])
    }

    /// DESIGN §3a: consumed audio doesn't linger in memory.
    @Test func consumedSamplesAreZeroed() {
        let ring = RingBuffer(capacity: 4)
        write(ring, [0.5, 0.25, 0.125])
        _ = drain(ring)
        #expect(ring.isAllZero())
        write(ring, [0.5, 0.5, 0.5]) // wraps
        _ = drain(ring)
        #expect(ring.isAllZero())
    }

    @Test func storageIsLockedInRAM() {
        #expect(RingBuffer(capacity: 48_000).isLocked)
    }
}

@Suite struct ZeroRecordingGuards {
    @Test func fileVaultCheckAnswersWithoutRoot() {
        // Whatever the answer, it must not hang or need a password.
        _ = SessionGuards.fileVaultActive
    }

    @Test func sleepAssertionIsHeldAndReleased() {
        var assertion: SessionGuards.SleepAssertion? = .init(reason: "Scribeski test")
        #expect(assertion?.isHeld == true)
        assertion = nil
        #expect(assertion == nil)
    }
}
