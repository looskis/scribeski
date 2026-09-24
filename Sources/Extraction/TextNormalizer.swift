import Foundation

/// Normalization used to match model quotes against transcript text, plus the small
/// lexicons behind the negation and affirmation rules.
///
/// Matching is on normalized text: case-folded, curly quotes and dashes mapped to ASCII,
/// apostrophes dropped (`don't` → `dont`), every other non-alphanumeric character treated
/// as a word break, whitespace collapsed. Substring tests are on word boundaries, so the
/// quote `no` never matches inside `nothing`.
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        for ch in folded {
            switch ch {
            case "'", "\u{2018}", "\u{2019}", "\u{02BC}", "`", "\u{00B4}":
                continue // apostrophes join: don't → dont
            default:
                if ch.isLetter || ch.isNumber {
                    out.append(ch)
                } else {
                    out.append(" ") // quotes, dashes, punctuation, whitespace → word break
                }
            }
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Word-boundary containment of normalized strings. An empty needle never matches.
    public static func contains(normalizedHaystack haystack: String, normalizedNeedle needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return (" " + haystack + " ").contains(" " + needle + " ")
    }

    public static func words(_ normalized: String) -> [Substring] {
        normalized.split(separator: " ")
    }

    // MARK: Lexicons

    static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "oh", "well", "so", "hmm", "hm", "mm", "ah"]

    /// Phrases that open a negative short answer.
    static let negations: [[String]] = [
        "none of that", "none of those", "not at all", "not really", "not anymore", "not any",
        "no way", "no thanks", "no thank you", "i dont", "i do not", "i havent", "i have not",
        "i never", "no", "nope", "never", "none", "nah", "nothing",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Phrases that open a bare affirmation.
    static let affirmations: [[String]] = [
        "mm hmm", "mm hm", "mhm", "mmhmm", "uh huh", "thats right", "thats it", "thats correct",
        "yes", "yeah", "yep", "yup", "yea", "right", "correct", "sure", "exactly", "okay", "ok",
    ].map { $0.split(separator: " ").map(String.init) }

    private static func stripLeadingFillers(_ words: [String]) -> [String] {
        var w = words[...]
        while let first = w.first, fillers.contains(first) { w = w.dropFirst() }
        return w.isEmpty ? words : Array(w)
    }

    private static func startsWithAny(_ words: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { p in words.count >= p.count && Array(words.prefix(p.count)) == p }
    }

    /// A short answer (≤ `maxWords` words) that opens with a negation, e.g. "No. None of that."
    public static func isNegatedShortAnswer(_ text: String, maxWords: Int = 5) -> Bool {
        let w = words(normalize(text)).map(String.init)
        guard !w.isEmpty, w.count <= maxWords else { return false }
        return startsWithAny(stripLeadingFillers(w), negations)
    }

    /// Words that can make up a bare affirmation once it has opened with one.
    static let affirmationVocabulary: Set<String> = [
        "yes", "yeah", "yep", "yup", "yea", "right", "correct", "sure", "exactly", "okay", "ok",
        "mm", "hmm", "hm", "mhm", "mmhmm", "uh", "huh", "um", "thats", "that", "it", "is", "fine",
        "true", "i", "do", "did", "am", "have", "so", "oh", "absolutely", "definitely",
    ]

    /// A bare affirmation (≤ `maxWords` words, nothing but affirmation words) such as
    /// "Yeah." or "Yes. Yeah, that's fine." — but not "Yes, Fairhaven."
    public static func isBareAffirmation(_ text: String, maxWords: Int = 4) -> Bool {
        let w = words(normalize(text)).map(String.init)
        guard !w.isEmpty, w.count <= maxWords else { return false }
        return startsWithAny(stripLeadingFillers(w), affirmations)
            && w.allSatisfy { affirmationVocabulary.contains($0) }
    }

    /// True when an option reads as the negative/absent answer: `NONE`, `NO`, `NEVER`,
    /// `NOT_*`, `NO_*`, `NONE_*`, `DECLINED`, a label like "Not at all", or option semantics
    /// that start with "Negative".
    public static func isNegativeOption(value: String, label: String?, semantics: String?) -> Bool {
        let v = value.uppercased()
        if ["NONE", "NO", "NEVER", "DECLINED", "NOT_AT_ALL", "NOTHING"].contains(v) { return true }
        if v.hasPrefix("NONE_") || v.hasPrefix("NO_") || v.hasPrefix("NOT_") || v.hasSuffix("_NONE") {
            return true
        }
        if let label {
            let l = normalize(label)
            if ["none", "no", "never", "not at all", "declined", "nothing"].contains(l)
                || l.hasPrefix("none ") || l.hasPrefix("not ") || l.hasPrefix("no ") {
                return true
            }
        }
        if let semantics, normalize(semantics).hasPrefix("negative") { return true }
        return false
    }
}
