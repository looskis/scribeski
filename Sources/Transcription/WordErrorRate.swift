import Foundation

/// Word error rate: (substitutions + deletions + insertions) / reference words, after
/// lowercasing and stripping punctuation. Used by the E2E harness and the ASR bake-off.
public enum WordErrorRate {
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    public static func compute(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                current[j] = r[i - 1] == h[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }
}
