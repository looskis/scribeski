import Foundation
import ScribeskiCore

/// Scores a `[FieldResult]` against an `expected-*.json` (BUILD_PLAN P1.6).
///
/// The expected file is read tolerantly as `JSONValue`: unknown buckets are ignored, and a
/// missing bucket is empty. Narrative concepts need a judge, so narratives are listed for
/// manual review rather than auto-scored.
public enum Scorer {
    /// Must-fill accuracy gate.
    public static let accuracyThreshold = 0.90

    public static func score(results: [FieldResult], expected: JSONValue, slots: Int = 1) -> ScoreReport {
        let byKey = Dictionary(results.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let risk = Set(expected["risk_fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var accuracy: [ScoreReport.Check] = []
        var blank: [ScoreReport.Check] = []

        func actual(_ key: String) -> FieldValue? {
            guard let r = byKey[key], r.status == .filled || r.status == .derived else { return nil }
            return r.value
        }
        func check(_ key: String, _ bucket: String, expected: String, pass: Bool) -> ScoreReport.Check {
            ScoreReport.Check(key: key, bucket: bucket, expected: expected,
                              actual: describe(actual(key), status: byKey[key]?.status),
                              pass: pass, risk: risk.contains(key))
        }

        for (key, want) in sortedEntries(expected["must_fill"]) {
            let got = actual(key)
            let pass: Bool
            if let s = want.stringValue {
                pass = got == .single(s)
            } else if let a = want.arrayValue?.compactMap(\.stringValue) {
                pass = Set(values(got)) == Set(a) && got != nil
            } else {
                pass = false
            }
            accuracy.append(check(key, "must_fill", expected: describe(want), pass: pass))
        }

        for (key, list) in sortedEntries(expected["acceptable"]) {
            let options = list.arrayValue ?? []
            let got = actual(key)
            let pass = options.contains { opt in
                if opt.isNull { return isBlank(got) }
                if let s = opt.stringValue { return got == .single(s) }
                return false
            }
            accuracy.append(check(key, "acceptable", expected: "one of " + describe(list), pass: pass))
        }

        for (key, spec) in sortedEntries(expected["checkbox_constraints"]) {
            let include = spec["must_include"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let exclude = spec["must_exclude"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let got = Set(values(actual(key)))
            let pass = include.allSatisfy(got.contains) && !exclude.contains(where: got.contains)
            let want = "include [\(include.joined(separator: ", "))], exclude [\(exclude.joined(separator: ", "))]"
            accuracy.append(check(key, "checkbox_constraints", expected: want, pass: pass))
        }

        for (key, spec) in sortedEntries(expected["text_match"]) {
            let mode = spec["normalize"]?.stringValue ?? "case_insensitive"
            let match = spec["match"]?.stringValue ?? "equals"
            let wants = spec["value"]?.arrayValue?.compactMap(\.stringValue)
                ?? spec["value"]?.stringValue.map { [$0] } ?? []
            var pass = false
            if case .single(let s)? = actual(key), let got = normalizeText(s, mode: mode) {
                let normalizedWants = wants.compactMap { normalizeText($0, mode: mode) }
                if match == "contains" {
                    pass = !normalizedWants.isEmpty && normalizedWants.allSatisfy { got.contains($0) }
                } else if match == "contains_any" {
                    pass = normalizedWants.contains { got.contains($0) }
                } else {
                    pass = normalizedWants.count == 1 && got == normalizedWants[0]
                }
            }
            accuracy.append(check(key, "text_match", expected: "\(match) \(mode) " + describe(spec["value"] ?? .null),
                                  pass: pass))
        }

        let mustLeaveBlank = expected["must_leave_blank"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for (key, want) in sortedEntries(expected["derived"]) {
            if let s = want.stringValue {
                accuracy.append(check(key, "derived", expected: s, pass: actual(key) == .single(s)))
            } else if want.isNull, !mustLeaveBlank.contains(key) {
                blank.append(check(key, "derived", expected: "blank", pass: isBlank(actual(key))))
            }
        }

        for key in mustLeaveBlank {
            blank.append(check(key, "must_leave_blank", expected: "blank", pass: isBlank(actual(key))))
        }
        for key in expected["clinician_only"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let r = byKey[key]
            let pass = r?.status == .clinicianOnly && isBlank(r?.value)
            blank.append(check(key, "clinician_only", expected: "clinician_only, blank", pass: pass))
        }

        let narratives = sortedEntries(expected["narrative"]).map { key, _ in
            ScoreReport.Narrative(key: key, status: byKey[key]?.status.rawValue ?? "missing",
                                  chars: byKey[key]?.value.flatMap { if case .single(let s) = $0 { s.count } else { nil } } ?? 0,
                                  citations: byKey[key]?.evidence.count ?? 0, risk: risk.contains(key))
        }

        // Traps: every field's check, wherever it lives. Narrative/unscored fields → manual.
        let checksByKey = Dictionary(grouping: accuracy + blank, by: \.key)
        let traps = (expected["traps"]?.arrayValue ?? []).map { trap -> ScoreReport.Trap in
            let fields = trap["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var failed: [String] = [], manual: [String] = [], checked = 0
            for f in fields {
                guard let cs = checksByKey[f] else { manual.append(f); continue }
                checked += 1
                if cs.contains(where: { !$0.pass }) { failed.append(f) }
            }
            let status: ScoreReport.Trap.Status = !failed.isEmpty ? .fail : (checked > 0 ? .pass : .manual)
            return ScoreReport.Trap(id: trap["id"]?.stringValue ?? "?", rule: trap["rule"]?.stringValue ?? "",
                                    status: status, failedFields: failed, manualFields: manual)
        }

        var rejections: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        for r in results {
            statuses[r.status.rawValue, default: 0] += 1
            if let reason = r.rejectReason { rejections[reason.rawValue, default: 0] += 1 }
        }

        let cache = cacheCheck(prefill: results.compactMap(\.prefillTokens), slots: slots)
        let passed = accuracy.filter(\.pass).count
        let acc = accuracy.isEmpty ? 0 : Double(passed) / Double(accuracy.count)
        let violations = blank.filter { !$0.pass }
        let riskErrors = (accuracy + blank).filter { $0.risk && !$0.pass }

        let gates = [
            ScoreReport.Gate(name: "must_leave_blank violations = 0", pass: violations.isEmpty,
                             detail: "\(violations.count)"),
            ScoreReport.Gate(name: "risk-field errors = 0", pass: riskErrors.isEmpty, detail: "\(riskErrors.count)"),
            ScoreReport.Gate(name: "must-fill accuracy ≥ \(Int(accuracyThreshold * 100))%",
                             pass: acc >= accuracyThreshold,
                             detail: String(format: "%.1f%% (%d/%d)", acc * 100, passed, accuracy.count)),
            ScoreReport.Gate(name: "prefix cache (no request re-processes the prefix)", pass: cache.pass,
                             detail: cache.pass == nil ? "no prefill data"
                                 : "\(cache.misses) misses; request 1 = \(cache.firstPrefill ?? 0), mean after = \(Int((cache.restRatio ?? 0) * Double(cache.firstPrefill ?? 0)))"),
        ]

        return ScoreReport(
            accuracyChecks: accuracy, blankChecks: blank, narratives: narratives,
            mustFillPassed: passed, mustFillTotal: accuracy.count, mustFillAccuracy: acc,
            blankViolations: violations, riskErrors: riskErrors, traps: traps,
            rejections: rejections, statuses: statuses,
            totalMs: results.compactMap(\.ms).reduce(0, +), cache: cache, gates: gates,
            reviewLoad: (expected["needs_review"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { key in
                actual(key) != nil && accuracy.contains { $0.key == key && $0.pass }
            })
    }

    /// The cache assertion. With `S` parallel slots the first `S` requests each pay the full
    /// prefix. After that, a hit costs only the per-field suffix (a few hundred tokens) and a
    /// miss re-processes the whole prefix, so a request is a **miss** when its prefill exceeds
    /// half of request 1's. Pass iff no request after the first `S` misses.
    ///
    /// (An earlier "total ≤ (S + 5%·(N−S)) × request 1" rule failed on short transcripts even
    /// with perfect caching: an 8-minute transcript's prefix is ~2.4k tokens, so a ~250-token
    /// field suffix is already 10% of it. Corpus run 1, session 05.)
    public static func cacheCheck(prefill: [Int], slots: Int = 1) -> ScoreReport.Cache {
        let s = max(1, slots)
        guard let first = prefill.first else {
            return .init(requests: 0, slots: s, firstPrefill: nil, totalPrefill: 0, allowed: nil,
                         restRatio: nil, misses: 0, pass: nil)
        }
        let n = prefill.count
        let total = prefill.reduce(0, +)
        let threshold = cacheMissFraction * Double(first)
        let misses = prefill.dropFirst(s).filter { Double($0) > threshold }.count
        let ratio = n > 1 && first > 0 ? Double(total - first) / Double(first * (n - 1)) : nil
        return .init(requests: n, slots: s, firstPrefill: first, totalPrefill: total, allowed: threshold,
                     restRatio: ratio, misses: misses, pass: misses == 0)
    }

    /// A request after the first `S` that processes more than this fraction of request 1's
    /// prefill re-did the prefix.
    public static let cacheMissFraction = 0.5

    // MARK: - Helpers

    static func sortedEntries(_ json: JSONValue?) -> [(String, JSONValue)] {
        guard let o = json?.objectValue else { return [] }
        return o.keys.sorted().map { ($0, o[$0]!) }
    }

    static func values(_ v: FieldValue?) -> [String] {
        switch v {
        case .single(let s)?: s.isEmpty ? [] : [s]
        case .multiple(let a)?: a
        case nil: []
        }
    }

    static func isBlank(_ v: FieldValue?) -> Bool { values(v).isEmpty }

    static func describe(_ v: FieldValue?, status: FieldResult.Status?) -> String {
        switch v {
        case .single(let s)?: return s
        case .multiple(let a)?: return "[" + a.joined(separator: ", ") + "]"
        case nil: return status.map { "∅ (\($0.rawValue))" } ?? "∅ (missing)"
        }
    }

    static func describe(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .null: "null"
        case .array(let a): "[" + a.map(describe).joined(separator: ", ") + "]"
        default: v.serialized()
        }
    }

    /// `digits`, `case_insensitive`, or `date` (→ `YYYY-MM-DD`; nil when unparseable).
    public static func normalizeText(_ s: String, mode: String) -> String? {
        switch mode {
        case "digits":
            // "four, five hours" is a fine answer in a free-text field; compare the numbers.
            return String(spelledNumbersAsDigits(s).unicodeScalars.filter { ("0"..."9").contains($0) }
                .map(Character.init))
        case "date":
            return parseDate(s)
        default:
            return TextNormalizer.normalize(s)
        }
    }

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Replaces spelled-out numbers up to 99 with digits ("twenty-one" → "21").
    static func spelledNumbersAsDigits(_ s: String) -> String {
        let words = s.lowercased().replacingOccurrences(of: "-", with: " ")
            .split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            let bare = words[i].trimmingCharacters(in: .punctuationCharacters)
            if let tens = numberWords[bare], tens >= 20, i + 1 < words.count,
               let ones = numberWords[words[i + 1].trimmingCharacters(in: .punctuationCharacters)], ones < 10 {
                out.append(String(tens + ones)); i += 2; continue
            }
            out.append(numberWords[bare].map(String.init) ?? words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    static func parseDate(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Verifier.isISODate(s) { return s }
        // "March 3rd, 1989" → "March 3, 1989"
        s = s.replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        for format in ["M/d/yyyy", "MM/dd/yyyy", "MMMM d, yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMM d yyyy",
                       "d MMMM yyyy", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: s) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }
}

/// The outcome of one scoring run. Render with `markdown`.
public struct ScoreReport: Codable, Hashable, Sendable {
    public struct Check: Codable, Hashable, Sendable {
        public var key: String
        /// The expected-file bucket that owns the key.
        public var bucket: String
        public var expected: String
        public var actual: String
        public var pass: Bool
        public var risk: Bool
    }

    public struct Narrative: Codable, Hashable, Sendable {
        public var key: String
        public var status: String
        public var chars: Int
        public var citations: Int
        public var risk: Bool
    }

    public struct Trap: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable { case pass, fail, manual }
        public var id: String
        public var rule: String
        public var status: Status
        public var failedFields: [String]
        /// Fields with no automatic check (narratives, unscored); need a human or a judge.
        public var manualFields: [String]

        enum CodingKeys: String, CodingKey {
            case id, rule, status
            case failedFields = "failed_fields"
            case manualFields = "manual_fields"
        }
    }

    public struct Cache: Codable, Hashable, Sendable {
        public var requests: Int
        public var slots: Int
        public var firstPrefill: Int?
        public var totalPrefill: Int
        /// Per-request prefill above which a request counts as a cache miss.
        public var allowed: Double?
        /// Mean prefill of requests 2..N as a fraction of request 1.
        public var restRatio: Double?
        /// Requests after the first `slots` that re-processed the prefix.
        public var misses: Int
        /// Nil when no request reported prefill tokens.
        public var pass: Bool?

        enum CodingKeys: String, CodingKey {
            case requests, slots, allowed, pass, misses
            case firstPrefill = "first_prefill"
            case totalPrefill = "total_prefill"
            case restRatio = "rest_ratio"
        }
    }

    public struct Gate: Codable, Hashable, Sendable {
        public var name: String
        /// Nil when the gate couldn't be measured; counts as not passed.
        public var pass: Bool?
        public var detail: String
    }

    public var accuracyChecks: [Check]
    public var blankChecks: [Check]
    public var narratives: [Narrative]
    public var mustFillPassed: Int
    public var mustFillTotal: Int
    public var mustFillAccuracy: Double
    public var blankViolations: [Check]
    public var riskErrors: [Check]
    public var traps: [Trap]
    public var rejections: [String: Int]
    public var statuses: [String: Int]
    public var totalMs: Int
    public var cache: Cache
    public var gates: [Gate]
    /// Keys in the expected file's `needs_review` that were filled acceptably: correct enough
    /// to count, but resting on an inference the review HUD must flag (P3.3).
    public var reviewLoad: [String] = []

    public var passed: Bool { gates.allSatisfy { $0.pass == true } }

    enum CodingKeys: String, CodingKey {
        case narratives, traps, rejections, statuses, cache, gates
        case accuracyChecks = "accuracy_checks"
        case blankChecks = "blank_checks"
        case mustFillPassed = "must_fill_passed"
        case mustFillTotal = "must_fill_total"
        case mustFillAccuracy = "must_fill_accuracy"
        case blankViolations = "blank_violations"
        case riskErrors = "risk_errors"
        case totalMs = "total_ms"
        case reviewLoad = "review_load"
    }

    /// A human-readable report for `eval/extraction-<date>.md`.
    public func markdown(title: String = "Extraction eval") -> String {
        var md: [String] = ["# \(title)", ""]
        md.append("**Result: \(passed ? "PASS" : "FAIL")**")
        md.append("")
        md.append("## Gates")
        md.append("")
        md.append("| gate | result | detail |")
        md.append("| --- | --- | --- |")
        for g in gates {
            md.append("| \(g.name) | \(g.pass.map { $0 ? "pass" : "FAIL" } ?? "not measured") | \(g.detail) |")
        }
        md.append("")
        md.append("Review load (accepted, but the HUD must flag for review): \(reviewLoad.count)"
            + (reviewLoad.isEmpty ? "" : " (\(reviewLoad.joined(separator: ", ")))"))

        func table(_ checks: [Check]) {
            md.append("| key | bucket | expected | actual | |")
            md.append("| --- | --- | --- | --- | --- |")
            for c in checks {
                md.append("| \(c.key)\(c.risk ? " (risk)" : "") | \(c.bucket) | \(cell(c.expected)) | \(cell(c.actual)) | \(c.pass ? "ok" : "**FAIL**") |")
            }
        }

        md.append("")
        md.append("## Blank violations (\(blankViolations.count))")
        md.append("")
        if blankViolations.isEmpty { md.append("None.") } else { table(blankViolations) }

        md.append("")
        md.append("## Risk-field errors (\(riskErrors.count))")
        md.append("")
        if riskErrors.isEmpty { md.append("None.") } else { table(riskErrors) }

        md.append("")
        md.append("## Traps")
        md.append("")
        md.append("| trap | result | failed fields | needs manual review |")
        md.append("| --- | --- | --- | --- |")
        for t in traps {
            let status = t.status == .fail ? "**FAIL**" : t.status.rawValue
            md.append("| \(t.id) | \(status) | \(t.failedFields.joined(separator: ", ")) | \(t.manualFields.joined(separator: ", ")) |")
        }

        md.append("")
        md.append(String(format: "## Must-fill accuracy: %.1f%% (%d/%d)", mustFillAccuracy * 100,
                         mustFillPassed, mustFillTotal))
        md.append("")
        table(accuracyChecks.filter { !$0.pass } + accuracyChecks.filter(\.pass))

        md.append("")
        md.append("## Narratives (manual concept review)")
        md.append("")
        md.append("| key | status | chars | citations |")
        md.append("| --- | --- | --- | --- |")
        for n in narratives {
            md.append("| \(n.key)\(n.risk ? " (risk)" : "") | \(n.status) | \(n.chars) | \(n.citations) |")
        }

        md.append("")
        md.append("## Rejections by reason")
        md.append("")
        if rejections.isEmpty { md.append("None.") }
        for (reason, n) in rejections.sorted(by: { $0.key < $1.key }) { md.append("- \(reason): \(n)") }
        md.append("")
        md.append("Statuses: " + statuses.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }
            .joined(separator: " · "))

        md.append("")
        md.append("## Prefix cache")
        md.append("")
        if let first = cache.firstPrefill {
            md.append("- requests: \(cache.requests), parallel slots: \(cache.slots)")
            md.append("- request 1 prefill: \(first) tokens")
            md.append("- requests 2..N prefill: \(cache.totalPrefill - first) tokens"
                + (cache.restRatio.map { String(format: " (mean %.2f%% of request 1)", $0 * 100) } ?? ""))
            md.append("- misses (a request after the first \(cache.slots) with prefill > \(Int(cache.allowed ?? 0)) tokens): "
                + "\(cache.misses) → " + (cache.pass == true ? "pass" : "**FAIL**"))
        } else {
            md.append("No prefill data in results.")
        }
        md.append("")
        md.append("Summed model time: \(totalMs) ms")
        return md.joined(separator: "\n") + "\n"
    }

    private func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
