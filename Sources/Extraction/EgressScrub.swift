import Foundation
import ScribeskiCore

/// What the scrub found. `ok` is false on any hit; the caller must then refuse to send.
public struct ScrubReport: Codable, Hashable, Sendable {
    public struct Hit: Codable, Hashable, Sendable {
        public var key: String
        /// `key`, `step`, `label`, `help`, `option.value`, or `option.label`.
        public var fieldPart: String
        /// Pattern name, e.g. `phone`, `ssn`, `record_number`.
        public var pattern: String
        /// The match with letters as `x` and digits as `#`, so the report never repeats PHI.
        public var excerptRedacted: String

        public init(key: String, fieldPart: String, pattern: String, excerptRedacted: String) {
            self.key = key
            self.fieldPart = fieldPart
            self.pattern = pattern
            self.excerptRedacted = excerptRedacted
        }

        enum CodingKeys: String, CodingKey {
            case key, pattern
            case fieldPart = "field_part"
            case excerptRedacted = "excerpt_redacted"
        }
    }

    public var hits: [Hit]
    /// Fields whose options were withheld because they changed between page loads.
    public var withheld: [String]
    public var ok: Bool { hits.isEmpty }

    public init(hits: [Hit], withheld: [String]) {
        self.hits = hits
        self.withheld = withheld
    }

    enum CodingKeys: String, CodingKey { case hits, withheld, ok }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hits = try c.decode([Hit].self, forKey: .hits)
        withheld = try c.decode([String].self, forKey: .withheld)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hits, forKey: .hits)
        try c.encode(withheld, forKey: .withheld)
        try c.encode(ok, forKey: .ok)
    }

    public var json: JSONValue {
        .obj([
            "hits": .array(hits.map {
                .obj(["key": .string($0.key), "field_part": .string($0.fieldPart), "pattern": .string($0.pattern),
                      "excerpt_redacted": .string($0.excerptRedacted)])
            }),
            "withheld": .strings(withheld),
            "ok": .bool(ok),
        ])
    }
}

/// Fail-closed regex scan of an `EgressPayload` for PHI shapes (DESIGN §6: "The scrub is
/// load-bearing").
///
/// Every string in the payload is scanned: key, step, label, help, option values and labels.
/// Patterns: phone, email, SSN, numeric and month-name dates, record/case numbers
/// (`AB-114322`, `MRN 1234567`, `#48213`), long digit runs, street addresses, PO boxes,
/// and ZIPs in address context.
///
/// The form's own structural text is allowlisted by **explicit shape rules**, never by
/// trusting a label:
/// - **Placeholder digits.** A match whose digits are all `0` or all `9` is a format example
///   (`Format: AB-000000`, `000-00-0000`, `99/99/9999`), not data.
/// - **Format hints** made of pattern letters (`MM/DD/YYYY`, `XXX-XX-XXXX`, `###-####`) carry
///   no digits, so no digit pattern can match them.
/// - **Reserved example emails** (`example.com/.net/.org`, `.example`, `.test`, `.invalid`
///   TLDs, RFC 2606).
/// - **The profiler's hash key** `f_` + 10 hex (page/src/profile.ts) is our own construction.
/// - **Enum-code option values**: short integers (`0`–`999`) or `UPPER_SNAKE` identifiers
///   with no digit run of five or more (`LINE_988`, `X4`). Their option *labels* are still
///   scanned.
/// Instrument text (PHQ-9, GAD-7 items, "past 2 weeks") has no PHI shape and passes on its own.
public enum EgressScrub {
    struct Pattern: @unchecked Sendable {
        let name: String
        let regex: NSRegularExpression

        init(_ name: String, _ pattern: String, caseInsensitive: Bool = true) {
            self.name = name
            self.regex = try! NSRegularExpression(pattern: pattern,
                                                  options: caseInsensitive ? [.caseInsensitive] : [])
        }
    }

    static let months = "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    static let streetSuffix = "(?:street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|court|ct|way|place|pl|terrace|ter|circle|cir|highway|hwy|parkway|pkwy|square|sq|trail|trl|apt|suite|ste|unit)"

    /// Order matters only for de-duplication: when two patterns overlap, the earlier one is reported.
    static let patterns: [Pattern] = [
        Pattern("email", #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#),
        Pattern("ssn", #"(?<!\d)\d{3}[- ]\d{2}[- ]\d{4}(?!\d)"#),
        Pattern("phone", #"(?<![\d+])(?:\+?1[\s.\-]?)?(?:\(\d{3}\)\s?|\d{3}[\s.\-])\d{3}[\s.\-]\d{4}(?!\d)"#),
        Pattern("phone", #"\+\d{1,3}[\s.\-]?\d{2,4}[\s.\-]?\d{3,4}[\s.\-]?\d{3,4}(?!\d)"#),
        Pattern("date", #"(?<!\d)\d{1,2}[/.\-]\d{1,2}[/.\-](?:\d{4}|\d{2})(?!\d)"#),
        Pattern("date", #"(?<!\d)\d{4}[/.\-]\d{1,2}[/.\-]\d{1,2}(?!\d)"#),
        Pattern("date", #"\b\#(months)\.?\s+\d{1,2}(?:st|nd|rd|th)?\b(?:,?\s+\d{4})?"#),
        Pattern("date", #"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?\#(months)\b\.?(?:,?\s+\d{4})?"#),
        Pattern("date", #"\b\#(months)\.?,?\s+\d{4}\b"#),
        Pattern("street_address", #"(?<![\d.])\d{1,6}[A-Z]?\s+(?:[NSEW]\.?\s+)?(?:[A-Z0-9][A-Z0-9.'\-]*\s+){1,4}\#(streetSuffix)\b\.?"#),
        Pattern("street_address", #"\bP\.?\s?O\.?\s+Box\s+\d+"#),
        Pattern("zip", #"\b[A-Z]{2}\s+\d{5}(?:-\d{4})?(?!\d)"#, caseInsensitive: false),
        Pattern("zip", #"(?<!\d)\d{5}-\d{4}(?!\d)"#),
        Pattern("zip", #"\bzip(?:\s*code)?\s*[:#]?\s*\d{5}(?!\d)"#),
        Pattern("zip", #",\s*\d{5}(?:-\d{4})?(?!\d)"#),
        Pattern("record_number", #"(?<![A-Z0-9])[A-Z]{1,4}[-_ #:]{0,2}\d{5,}(?!\d)"#),
        Pattern("record_number", #"#\s?\d{4,}(?!\d)"#),
        Pattern("long_digit_run", #"(?<!\d)\d{6,}(?!\d)"#),
    ]

    static let hashKey = try! NSRegularExpression(pattern: "^f_[0-9a-f]{10}$")
    static let enumCode = try! NSRegularExpression(pattern: "^(?:[0-9]{1,3}|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)$")
    static let longDigits = try! NSRegularExpression(pattern: "[0-9]{5,}")
    static let reservedEmail = try! NSRegularExpression(
        pattern: #"@(?:[A-Z0-9\-]+\.)*(?:example\.(?:com|net|org)|[A-Z0-9\-]+\.(?:example|test|invalid))$"#,
        options: [.caseInsensitive])

    // MARK: - Scan

    public static func scan(_ payload: EgressPayload, withheld: [String] = []) -> ScrubReport {
        var hits: [ScrubReport.Hit] = []
        for field in payload.fields {
            if !matches(hashKey, field.key) {
                hits += scan(field.key, key: field.key, part: "key")
            }
            hits += scan(field.step, key: field.key, part: "step")
            hits += scan(field.label, key: field.key, part: "label")
            if let help = field.help { hits += scan(help, key: field.key, part: "help") }
            for option in field.optionList {
                if !isEnumCode(option.value) {
                    hits += scan(option.value, key: field.key, part: "option.value")
                }
                hits += scan(option.label, key: field.key, part: "option.label")
            }
        }
        return ScrubReport(hits: hits, withheld: withheld)
    }

    /// Hits in one string, overlapping matches de-duplicated in pattern order.
    public static func scan(_ text: String, key: String, part: String) -> [ScrubReport.Hit] {
        let ns = text as NSString
        var taken: [NSRange] = []
        var found: [(NSRange, ScrubReport.Hit)] = []
        for pattern in patterns {
            for m in pattern.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let excerpt = ns.substring(with: m.range)
                if isPlaceholder(excerpt) { continue }
                if pattern.name == "email", contains(reservedEmail, excerpt) { continue }
                if taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                taken.append(m.range)
                found.append((m.range, ScrubReport.Hit(key: key, fieldPart: part, pattern: pattern.name,
                                                       excerptRedacted: redact(excerpt))))
            }
        }
        return found.sorted { $0.0.location < $1.0.location }.map(\.1)
    }

    // MARK: - Allowlist rules

    /// Every digit is `0`, or every digit is `9`: a format example, not data.
    public static func isPlaceholder(_ s: String) -> Bool {
        let digits = s.filter(\.isASCIIDigit)
        guard let first = digits.first, first == "0" || first == "9" else { return false }
        return digits.allSatisfy { $0 == first }
    }

    /// `0`–`999`, or an `UPPER_SNAKE` code with no run of five or more digits.
    public static func isEnumCode(_ value: String) -> Bool {
        matches(enumCode, value) && !contains(longDigits, value)
    }

    public static func redact(_ s: String) -> String {
        String(s.map { c -> Character in
            if c.isASCIIDigit { return "#" }
            if c.isLetter { return "x" }
            return c
        })
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.firstMatch(in: s, range: range)?.range == range
    }

    static func contains(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
