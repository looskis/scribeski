import Foundation

/// What each profiled field means. Produced once at setup and reviewed by the worker.
public struct FormMapping: Codable, Hashable, Sendable {
    public enum Schema: SchemaIdentifier { public static let id = "scribeski.form-mapping/1" }

    public var schema = SchemaTag<Schema>()
    /// The profile this mapping was made against. A mismatch at fill time means drift.
    public var profileFingerprint: String
    public var fields: [String: FieldMapping]
    /// What the worker calls this form, e.g. "Riverside County ICR".
    public var name: String?
    /// How to find this form in Safari and whose chart it is. Optional until learned (P3.4).
    public var chart: Chart?

    public init(profileFingerprint: String, fields: [String: FieldMapping], name: String? = nil, chart: Chart? = nil) {
        self.profileFingerprint = profileFingerprint
        self.fields = fields
        self.name = name
        self.chart = chart
    }

    enum CodingKeys: String, CodingKey {
        case schema, fields, name, chart
        case profileFingerprint = "profile_fingerprint"
    }

    /// Where a form lives and how to tell whose chart a tab shows (BUILD_PLAN P3.1). Chosen
    /// once when the form is learned; used to find the right tab and refuse the wrong client.
    public struct Chart: Codable, Hashable, Sendable {
        /// e.g. `https://ehr.example.org`.
        public var origin: String
        /// Path, with `*` matching any run of characters: `/clients/*/intake`.
        public var pathPattern: String
        /// Top-document element that names the client whose record is open.
        public var bannerSelector: String
        /// Regex; its first capture group is the client's record ID, e.g. `(AB-\d{6})`.
        public var clientIDPattern: String
        /// Regex; its first capture group is the client's display name. Optional.
        public var clientNamePattern: String?

        public init(origin: String, pathPattern: String, bannerSelector: String, clientIDPattern: String,
                    clientNamePattern: String? = nil) {
            self.origin = origin
            self.pathPattern = pathPattern
            self.bannerSelector = bannerSelector
            self.clientIDPattern = clientIDPattern
            self.clientNamePattern = clientNamePattern
        }

        enum CodingKeys: String, CodingKey {
            case origin
            case pathPattern = "path_pattern"
            case bannerSelector = "banner_selector"
            case clientIDPattern = "client_id_pattern"
            case clientNamePattern = "client_name_pattern"
        }

        /// Whether a tab's URL is this form. Query and fragment are ignored.
        public func matches(_ url: String) -> Bool {
            guard let u = URL(string: url), let scheme = u.scheme, let host = u.host() else { return false }
            let port = u.port.map { ":\($0)" } ?? ""
            guard "\(scheme)://\(host)\(port)" == origin else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: pathPattern).replacingOccurrences(of: "\\*", with: ".*")
            return u.path().range(of: "^\(escaped)$", options: .regularExpression) != nil
        }

        /// The path with record-specific segments as `*` (3+ digits, a UUID, a long hex id), so
        /// a client's number in the URL isn't saved and the chart matches every client's page.
        /// Same rule as the page bundle's `generalizePath`.
        public static func generalizePath(_ path: String) -> String {
            path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
                let s = String(seg).removingPercentEncoding ?? String(seg)
                let digits = s.filter(\.isNumber).count
                let uuid = s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"#, options: .regularExpression) != nil
                let hex = s.count >= 12 && s.allSatisfy(\.isHexDigit)
                return digits >= 3 || uuid || hex ? "*" : String(seg)
            }.joined(separator: "/")
        }

        /// Patterns proposed from one example of the banner's text, for the worker to check:
        /// the ID-looking token generalized by shape (`AB-114322` → `([A-Z]{2}-\d{6})`), led
        /// by the word before it if there is one, and the name as whatever follows a separator.
        public static func proposePatterns(from text: String) -> (id: String, name: String?)? {
            let token = #"[A-Z]{1,4}[- ]?\d{4,}|\d{6,}"#
            guard let re = try? NSRegularExpression(pattern: #"(?:([A-Za-z]+)[:#\s]+)?\b("# + token + #")\b"#),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let idRange = Range(m.range(at: 2), in: text) else { return nil }
            var shape = ""
            var run: (Character, Int)? = nil
            func flush() {
                guard let (kind, n) = run else { return }
                shape += (kind == "A" ? "[A-Z]" : "\\d") + "{\(n)}"
                run = nil
            }
            for c in text[idRange] {
                let kind: Character? = c.isLetter ? "A" : c.isNumber ? "9" : nil
                if let kind {
                    if run?.0 == kind { run!.1 += 1 } else { flush(); run = (kind, 1) }
                } else {
                    flush()
                    shape += NSRegularExpression.escapedPattern(for: String(c)).replacingOccurrences(of: " ", with: "\\s")
                }
            }
            flush()
            let lead = Range(m.range(at: 1), in: text).map { NSRegularExpression.escapedPattern(for: String(text[$0])) + #"[:#\s]+"# } ?? ""
            let id = lead + "(" + shape + ")"
            // A name after a separator: "… · REYES, Daniela", "… | Maria Reyes", "… – Sam Lee".
            let after = text[idRange.upperBound...]
            let separators = ["·", "|", "–", "—", " - "]
            let name = separators.first { after.contains($0) }.map {
                NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) + #"\s*(.+)$"#
            }
            return (id, name)
        }

        /// The client's record ID and name, read from the banner's text.
        public func client(inBanner text: String) -> (id: String, name: String?)? {
            func first(_ pattern: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let id = first(clientIDPattern), !id.isEmpty else { return nil }
            return (id, clientNamePattern.flatMap(first))
        }
    }

    public enum Mode: String, Codable, Hashable, Sendable {
        /// One value from the transcript, with evidence.
        case discrete
        /// Cited sentences generated from the transcript.
        case narrative
        /// Computed in code from other fields (scores). Never sent to the model.
        case derived
        /// Clinical judgement. Never sent to the model; surfaced as "needs your judgement".
        case clinicianOnly = "clinician_only"
        case skip
    }

    public enum EvidenceSpeaker: String, Codable, Hashable, Sendable {
        case client, worker, any
    }

    public struct Derivation: Codable, Hashable, Sendable {
        /// Name of a derivation implemented in code, e.g. `"phq9_total"`, `"phq9_band"`.
        public var function: String
        public var inputs: [String]

        public init(function: String, inputs: [String]) {
            self.function = function
            self.inputs = inputs
        }
    }

    public struct FieldMapping: Codable, Hashable, Sendable {
        public var intent: String
        public var mode: Mode
        public var evidenceSpeaker: EvidenceSpeaker
        public var optionSemantics: [String: String]?
        public var maxChars: Int?
        public var derive: Derivation?
        /// Options the model may never choose, because choosing them is a clinical judgement
        /// or an inference from silence (e.g. safety plan "Not indicated", crisis resources
        /// "None"). Removed from the schema and the prompt; blank is the safe equivalent.
        public var excludeOptions: [String]?
        /// Frequency fields: option → [min, max] occasions per month. The model reports a
        /// count and a period from the quote; code converts and picks the band, so the model
        /// never does the arithmetic ("two or three a month" is not "per week").
        public var perMonthBands: [String: [Double]]?

        public init(intent: String, mode: Mode, evidenceSpeaker: EvidenceSpeaker,
                    optionSemantics: [String: String]? = nil, maxChars: Int? = nil,
                    derive: Derivation? = nil, excludeOptions: [String]? = nil,
                    perMonthBands: [String: [Double]]? = nil) {
            self.intent = intent
            self.mode = mode
            self.evidenceSpeaker = evidenceSpeaker
            self.optionSemantics = optionSemantics
            self.maxChars = maxChars
            self.derive = derive
            self.excludeOptions = excludeOptions
            self.perMonthBands = perMonthBands
        }

        enum CodingKeys: String, CodingKey {
            case intent, mode, derive
            case evidenceSpeaker = "evidence_speaker"
            case optionSemantics = "option_semantics"
            case maxChars = "max_chars"
            case excludeOptions = "exclude_options"
            case perMonthBands = "per_month_bands"
        }
    }
}
