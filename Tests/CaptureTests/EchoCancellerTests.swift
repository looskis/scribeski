import Foundation
import Testing
@testable import Capture

@Suite struct EchoCancellation {
    /// Deterministic noise, so the test is repeatable.
    struct LCG { var s: UInt32; mutating func next() -> Double { s = s &* 1_664_525 &+ 1_013_904_223; return Double(s) / Double(UInt32.max) * 2 - 1 } }

    func energyDb(_ x: ArraySlice<Int16>) -> Double {
        let e = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
        return 10 * log10(max(e, 1e-9))
    }

    /// Speakers play the client (far end); the mic hears it 40 ms later through a crude room,
    /// plus the worker speaking in the second half. The canceller must remove most of the echo
    /// and keep the worker.
    @Test func removesSpeakerEchoAndKeepsTheWorker() {
        let rate = 16_000, seconds = 8
        var rng = LCG(s: 7)
        let far: [Int16] = (0..<rate * seconds).map { _ in Int16(rng.next() * 6_000) }
        let delay = rate * 40 / 1000
        var mic = [Int16](repeating: 0, count: far.count)
        for i in delay..<far.count {
            // Room: attenuated, a little smeared.
            let e = 0.35 * Double(far[i - delay]) + 0.15 * Double(far[max(i - delay - 7, 0)])
            mic[i] = Int16(clamping: Int(e))
        }
        // The worker talks (a 300 Hz tone) from 5 s to 7 s, over the echo.
        for i in (5 * rate)..<(7 * rate) { mic[i] = Int16(clamping: Int(mic[i]) + Int(4_000 * sin(2 * .pi * 300 * Double(i) / Double(rate)))) }

        let aec = EchoCanceller()
        var cleaned: [Int16] = []
        let chunk = 800 // 50 ms, like capture
        for start in stride(from: 0, to: far.count, by: chunk) {
            let end = min(start + chunk, far.count)
            far[start..<end].withUnsafeBufferPointer { aec.reference($0) }
            mic[start..<end].withUnsafeBufferPointer { m in aec.process(m) { cleaned.append(contentsOf: $0) } }
        }

        // Echo only, after 2 s to converge: at least 15 dB quieter.
        let echoIn = energyDb(mic[(3 * rate)..<(5 * rate)])
        let echoOut = energyDb(cleaned[(3 * rate)..<(5 * rate)])
        #expect(echoIn - echoOut > 15, "echo reduced by \(echoIn - echoOut) dB")
        // Worker over echo: the worker's tone survives (well above the residual echo).
        let talk = energyDb(cleaned[(5 * rate + 1_000)..<(7 * rate - 1_000)])
        #expect(talk - echoOut > 15, "worker \(talk - echoOut) dB above residual echo")
    }
}

@Suite struct EchoAlignment {
    /// Within one drain the mic can arrive a callback before its reference. The canceller must
    /// wait for the reference, not pad it, or the echo path shifts and cancellation collapses.
    @Test func micArrivingFirstDoesNotShiftTheReference() {
        let rate = 16_000
        var rng = EchoCancellation.LCG(s: 3)
        let far: [Int16] = (0..<rate * 6).map { _ in Int16(rng.next() * 6_000) }
        var mic = [Int16](repeating: 0, count: far.count)
        for i in 480..<far.count { mic[i] = Int16(clamping: Int(0.4 * Double(far[i - 480]))) }

        let aec = EchoCanceller()
        var cleaned: [Int16] = []
        // Jittered delivery: the mic gets 512 samples ahead, then the reference catches up.
        var r = 0, m = 0
        while m < mic.count {
            let mEnd = min(m + 1_312, mic.count)
            mic[m..<mEnd].withUnsafeBufferPointer { b in aec.process(b) { cleaned.append(contentsOf: $0) } }
            m = mEnd
            let rEnd = min(r + 1_312, far.count, m) // never ahead of the mic
            far[r..<rEnd].withUnsafeBufferPointer { aec.reference($0) }
            r = rEnd
        }
        func db(_ x: ArraySlice<Int16>) -> Double {
            10 * log10(max(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count), 1e-9))
        }
        let reduction = db(mic[(3 * rate)..<(5 * rate)]) - db(cleaned[(3 * rate)..<min(5 * rate, cleaned.count)])
        #expect(reduction > 15, "echo reduced by \(reduction) dB")
    }
}
