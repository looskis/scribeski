import Darwin
import Synchronization

/// Lock-free single-producer, single-consumer ring of Float32 samples (BUILD_PLAN P2.2).
///
/// The producer is the IOProc on CoreAudio's realtime thread: `write` does no allocation,
/// locking, or logging. Storage is `mlock`ed so audio is never paged to swap, and wiped with
/// `memset_s` (which the compiler can't elide) when the ring is released (DESIGN §3a).
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let bytes: Int
    /// Total samples ever written / read. Monotonic, so full vs. empty is unambiguous.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Samples the producer had to drop because the consumer fell behind.
    private let dropped = Atomic<Int>(0)
    public let isLocked: Bool

    public init(capacity: Int) {
        self.capacity = capacity
        bytes = capacity * MemoryLayout<Float>.stride
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        isLocked = mlock(storage, bytes) == 0
    }

    deinit {
        wipe()
        if isLocked { munlock(storage, bytes) }
        storage.deallocate()
    }

    /// Producer side. Realtime-safe. Drops what doesn't fit and counts it.
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let n = min(count, free)
        if n < count { dropped.add(count - n, ordering: .relaxed) }
        guard n > 0 else { return }
        let start = w % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: samples, count: first)
        if first < n { storage.update(from: samples + first, count: n - first) }
        written.store(w + n, ordering: .releasing)
    }

    /// Producer side, for a strided (interleaved) source: takes every `stride`-th sample.
    public func write(_ samples: UnsafePointer<Float>, count: Int, stride: Int) {
        guard stride > 1 else { return write(samples, count: count) }
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        if n < count { dropped.add(count - n, ordering: .relaxed) }
        for i in 0..<n { storage[(w + i) % capacity] = samples[i * stride] }
        written.store(w + n, ordering: .releasing)
    }

    public var available: Int { written.load(ordering: .acquiring) - read.load(ordering: .relaxed) }
    public var totalWritten: Int { written.load(ordering: .acquiring) }
    public var totalDropped: Int { dropped.load(ordering: .relaxed) }

    /// Consumer side. Hands `body` up to two contiguous chunks covering everything available,
    /// then wipes them and marks them consumed.
    public func consume(_ body: (UnsafeBufferPointer<Float>) -> Void) {
        let r = read.load(ordering: .relaxed)
        let n = written.load(ordering: .acquiring) - r
        guard n > 0 else { return }
        let start = r % capacity
        let first = min(n, capacity - start)
        body(UnsafeBufferPointer(start: storage + start, count: first))
        if first < n { body(UnsafeBufferPointer(start: storage, count: n - first)) }
        // Consumed audio doesn't linger in the ring.
        memset_s(storage + start, first * MemoryLayout<Float>.stride, 0, first * MemoryLayout<Float>.stride)
        if first < n {
            memset_s(storage, (n - first) * MemoryLayout<Float>.stride, 0, (n - first) * MemoryLayout<Float>.stride)
        }
        read.store(r + n, ordering: .releasing)
    }

    /// Zeroes the whole ring. Call only when the producer is stopped.
    public func wipe() {
        memset_s(storage, bytes, 0, bytes)
    }

    /// Test hook: true if every sample in the ring is zero.
    func isAllZero() -> Bool {
        (0..<capacity).allSatisfy { storage[$0] == 0 }
    }
}
