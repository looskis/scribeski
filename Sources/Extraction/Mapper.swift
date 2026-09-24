import Foundation
import ScribeskiCore

/// Turns model proposals into a `FormMapping`. Everything here is decided in code, never
/// trusted to the model (BUILD_PLAN P1.4):
/// - hidden / page-computed fields become `derived` with a derive spec when the key belongs to
///   a known `Derivations` family (`phq9_*` / `gad7_*` score, total, severity, band), else `skip`;
/// - a field with an entry in the `base` mapping keeps that entry verbatim, so re-mapping after
///   drift never clobbers reviewed work;
/// - proposals are normalised: option semantics limited to the field's options, `max_chars`
///   only on free text and clamped, `evidence_speaker: any` for non-extracted modes;
/// - attestation / signature / certification controls are always `clinician_only`: the model
///   once proposed filling "I attest this note reflects services I provided" (eval/runs);
/// - `profile_fingerprint` comes from the profile.
public enum MappingPostProcessor {
    public static let maxCharsRange = 1...4000

    /// `phq9_score` → `phq9_total(phq9_1…phq9_9)`; `gad7_severity` → `gad7_band(gad7_1…gad7_7)`.
    /// Inputs are the profile's `<family>_<n>` fields in item order. Nil if not a known family
    /// or the profile has no items.
    public static func derivation(for key: String, in profile: FormProfile) -> FormMapping.Derivation? {
        let parts = key.lowercased().split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let family = parts[0]
        let kind: String
        switch parts[1] {
        case "score", "total": kind = "total"
        case "severity", "band": kind = "band"
        default: return nil
        }
        let function = "\(family)_\(kind)"
        guard Derivations.known.contains(function) else { return nil }
        let items = profile.fields.compactMap { f -> (Int, String)? in
            guard f.key.lowercased().hasPrefix(family + "_"), !f.computed,
                  let n = Int(f.key.dropFirst(family.count + 1)) else { return nil }
            return (n, f.key)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard !items.isEmpty else { return nil }
        return FormMapping.Derivation(function: function, inputs: items)
    }

    /// The code-decided entry for a hidden or computed field.
    public static func codeDecided(_ field: FormProfile.Field, in profile: FormProfile) -> FormMapping.FieldMapping {
        guard let derive = derivation(for: field.key, in: profile) else {
            return .init(intent: "Hidden or page-computed field with no known derivation; not filled.",
                         mode: .skip, evidenceSpeaker: .any)
        }
        let name = derive.function.hasPrefix("phq9") ? "PHQ-9" : "GAD-7"
        let what = derive.function.hasSuffix("_band") ? "severity band" : "total"
        return .init(intent: "\(name) \(what), computed in code from the \(derive.inputs.count) items.",
                     mode: .derived, evidenceSpeaker: .any, derive: derive)
    }

    /// Reads one batch's model output (`{key: {intent, mode, …}}`).
    public static func parseProposals(_ content: String) throws -> [String: JSONValue] {
        let json: JSONValue
        do { json = try JSONValue.parse(content) } catch {
            throw LLMClientError.malformedResponse("mapping batch is not JSON")
        }
        guard let object = json.objectValue else {
            throw LLMClientError.malformedResponse("mapping batch is not an object")
        }
        return Dictionary(object.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Normalises one proposal against its profile field. Nil if unusable.
    public static func normalise(_ proposal: JSONValue, field: FormProfile.Field,
                                 warnings: inout [String]) -> FormMapping.FieldMapping? {
        guard let intent = proposal["intent"]?.stringValue, !intent.isEmpty,
              let modeText = proposal["mode"]?.stringValue, let mode = FormMapping.Mode(rawValue: modeText),
              MappingPrompt.proposableModes.contains(mode) else { return nil }
        var speaker = proposal["evidence_speaker"]?.stringValue.flatMap(FormMapping.EvidenceSpeaker.init) ?? .any
        var finalMode = mode
        if mode == .narrative, !MappingPrompt.hasFreeText(field.kind) {
            warnings.append("\(field.key): model proposed narrative for a \(field.kind.rawValue); using discrete")
            finalMode = .discrete
        }
        if finalMode == .clinicianOnly || finalMode == .skip {
            return .init(intent: intent, mode: finalMode, evidenceSpeaker: .any)
        }
        if finalMode == .narrative { speaker = .any }

        var semantics: [String: String]?
        if let given = proposal["option_semantics"]?.objectValue, !field.options.isEmpty {
            let allowed = Set(field.options.map(\.value))
            var kept: [String: String] = [:]
            for (value, rule) in given.entries {
                if allowed.contains(value), let text = rule.stringValue { kept[value] = text }
            }
            if kept.count < given.keys.count {
                warnings.append("\(field.key): dropped option_semantics for values not in the profile")
            }
            semantics = kept.isEmpty ? nil : kept
        }
        var maxChars: Int?
        if MappingPrompt.hasFreeText(field.kind), let n = proposal["max_chars"]?.intValue {
            maxChars = min(max(n, maxCharsRange.lowerBound), maxCharsRange.upperBound)
        }
        return .init(intent: intent, mode: finalMode, evidenceSpeaker: speaker,
                     optionSemantics: semantics, maxChars: maxChars)
    }

    /// Assembles the full mapping in code. `proposals` holds the model's raw per-key output.
    public static func assemble(profile: FormProfile, proposals: [String: JSONValue],
                                base: FormMapping?) -> (mapping: FormMapping, warnings: [String]) {
        var warnings: [String] = []
        var fields: [String: FormMapping.FieldMapping] = [:]
        for field in profile.fields {
            if let reviewed = base?.fields[field.key] {
                fields[field.key] = reviewed
                if let s = reviewed.optionSemantics, Set(s.keys) != Set(field.options.map(\.value)), !field.options.isEmpty {
                    warnings.append("\(field.key): kept base entry, but its option_semantics no longer match the profile's options")
                }
                if EgressPayload.decidedInCode(field), reviewed.mode != .derived, reviewed.mode != .skip {
                    warnings.append("\(field.key): kept base entry with mode \(reviewed.mode.rawValue) for a hidden/computed field")
                }
                continue
            }
            if EgressPayload.decidedInCode(field) {
                fields[field.key] = codeDecided(field, in: profile)
                continue
            }
            if isAttestation(field) {
                fields[field.key] = .init(
                    intent: "Attestation or signature by the clinician. Never filled by Scribeski.",
                    mode: .clinicianOnly, evidenceSpeaker: .any)
                if let p = proposals[field.key]?["mode"]?.stringValue, p != "clinician_only" {
                    warnings.append("\(field.key): model proposed \(p) for an attestation; forced clinician_only")
                }
                continue
            }
            if let proposal = proposals[field.key],
               let entry = normalise(proposal, field: field, warnings: &warnings) {
                fields[field.key] = entry
            } else {
                warnings.append("\(field.key): no usable proposal from the model; set to skip for hand review")
                fields[field.key] = .init(intent: "UNMAPPED: the model returned no usable entry. Review by hand.",
                                          mode: .skip, evidenceSpeaker: .any)
            }
        }
        if let base {
            let dropped = Set(base.fields.keys).subtracting(profile.fields.map(\.key)).sorted()
            if !dropped.isEmpty {
                warnings.append("base entries dropped, fields no longer in the profile: \(dropped.joined(separator: ", "))")
            }
        }
        return (FormMapping(profileFingerprint: profile.fingerprint, fields: fields), warnings)
    }

    /// A control whose label or options attest, sign, or certify. Only the clinician does that.
    public static func isAttestation(_ field: FormProfile.Field) -> Bool {
        let text = ([field.label] + field.options.map(\.label)).joined(separator: " ").lowercased()
        return ["attest", "signature", "sign here", "i certify", "e-sign", "esign", "electronically sign"]
            .contains { text.contains($0) }
    }

    /// Hand-editable JSON: fields in profile order, entry keys in a fixed order.
    public static func json(_ mapping: FormMapping, profile: FormProfile) -> JSONValue {
        var fields = JSONObject()
        let order = profile.fields.map(\.key) + mapping.fields.keys.sorted().filter { k in !profile.fields.contains { $0.key == k } }
        for key in order {
            guard let m = mapping.fields[key] else { continue }
            let options = profile.fields.first { $0.key == key }?.options.map(\.value) ?? []
            var o = JSONObject()
            o["intent"] = .string(m.intent)
            o["mode"] = .string(m.mode.rawValue)
            o["evidence_speaker"] = .string(m.evidenceSpeaker.rawValue)
            if let x = m.excludeOptions, !x.isEmpty { o["exclude_options"] = .strings(x) }
            if let bands = m.perMonthBands, !bands.isEmpty {
                var b = JSONObject()
                for (k, r) in bands.sorted(by: { ($0.value.first ?? 0) < ($1.value.first ?? 0) }) {
                    b[k] = .array(r.map { .double($0) })
                }
                o["per_month_bands"] = .object(b)
            }
            if let s = m.optionSemantics {
                var so = JSONObject()
                for v in options where s[v] != nil { so[v] = .string(s[v]!) }
                for v in s.keys.sorted() where so[v] == nil { so[v] = .string(s[v]!) }
                o["option_semantics"] = .object(so)
            }
            if let n = m.maxChars { o["max_chars"] = .int(n) }
            if let d = m.derive { o["derive"] = .obj(["function": .string(d.function), "inputs": .strings(d.inputs)]) }
            fields[key] = .object(o)
        }
        return .obj([
            "schema": .string(FormMapping.Schema.id),
            "profile_fingerprint": .string(mapping.profileFingerprint),
            "fields": .object(fields),
        ])
    }
}

/// `scribeski map`, minus argument parsing and file I/O, so the egress gate is testable.
///
/// Before any network call: build the payload, scrub it, refuse on hits (exit 1). For a
/// non-localhost endpoint, print the exact payload and require `yes` (else exit 2). Localhost
/// endpoints are scrubbed the same way but need no confirmation.
public enum MapRun {
    public struct Options: Sendable {
        public var profile: FormProfile
        public var secondProfile: FormProfile?
        public var base: FormMapping?
        public var endpoint: URL
        public var yes: Bool
        public var dryRun: Bool
        public var batchSize: Int

        public init(profile: FormProfile, secondProfile: FormProfile? = nil, base: FormMapping? = nil,
                    endpoint: URL, yes: Bool = false, dryRun: Bool = false,
                    batchSize: Int = MappingPrompt.defaultBatchSize) {
            self.profile = profile
            self.secondProfile = secondProfile
            self.base = base
            self.endpoint = endpoint
            self.yes = yes
            self.dryRun = dryRun
            self.batchSize = batchSize
        }
    }

    public struct Outcome: Sendable {
        public var exitCode: Int32
        /// Mapping JSON on success, or the payload + report on `--dry-run`.
        public var stdout: String
        /// Human-facing messages: scrub report, payload for confirmation, warnings.
        public var stderr: String
        public var payload: EgressPayload
        public var report: ScrubReport
        public var mapping: FormMapping?
        public var requestsSent: Int
    }

    public static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    public static func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return localHosts.contains(host)
    }

    /// Payload and scrub report for `options`, with no network access.
    public static func prepare(_ options: Options) -> (EgressPayload, ScrubReport) {
        let withheld = options.secondProfile.map { EgressPayload.volatileOptionKeys(options.profile, $0) } ?? []
        let reviewed = Set(options.base?.fields.keys.map { $0 } ?? [])
        let payload = EgressPayload.build(from: options.profile, withheld: Set(withheld), excluding: reviewed)
        return (payload, EgressScrub.scan(payload, withheld: withheld))
    }

    /// The exact payload JSON, one field per line.
    public static func payloadText(_ payload: EgressPayload) -> String {
        if payload.fields.isEmpty { return #"{"fields":[]}"# }
        return "{\"fields\":[\n" + payload.fields.map { "  " + $0.json.serialized() }.joined(separator: ",\n") + "\n]}"
    }

    public static func reportText(_ report: ScrubReport) -> String {
        var lines = ["scrub: \(report.ok ? "ok" : "\(report.hits.count) hit(s), refusing to send")"]
        for h in report.hits {
            lines.append("  \(h.key) \(h.fieldPart): \(h.pattern) \(h.excerptRedacted)")
        }
        if !report.withheld.isEmpty {
            lines.append("  options withheld (changed between page loads, possibly record-derived PHI): "
                + report.withheld.joined(separator: ", "))
        }
        lines.append(report.json.serialized())
        return lines.joined(separator: "\n")
    }

    public static func run(_ options: Options, client: any LLMClient) async -> Outcome {
        let (payload, report) = prepare(options)
        var out = Outcome(exitCode: 0, stdout: "", stderr: "", payload: payload, report: report,
                          mapping: nil, requestsSent: 0)
        let host = options.endpoint.host ?? options.endpoint.absoluteString

        if options.dryRun {
            out.stdout = payloadText(payload) + "\n" + report.json.serialized() + "\n"
            out.stderr = reportText(report) + "\n"
            out.exitCode = report.ok ? 0 : 1
            return out
        }
        guard report.ok else {
            out.stderr = reportText(report) + "\n"
            out.exitCode = 1
            return out
        }
        if !isLocalhost(options.endpoint) {
            out.stderr += "payload for \(host) (\(payload.fields.count) fields, sent with fixed instructions):\n"
                + payloadText(payload) + "\n" + reportText(report) + "\n"
            guard options.yes else {
                out.stderr += "re-run with --yes to send this to \(host)\n"
                out.exitCode = 2
                return out
            }
        } else if !report.withheld.isEmpty {
            out.stderr += reportText(report) + "\n"
        }

        var proposals: [String: JSONValue] = [:]
        for keys in MappingPrompt.batches(payload, size: options.batchSize) {
            do {
                out.requestsSent += 1
                let response = try await client.complete(MappingPrompt.request(payload, keys: keys))
                let parsed = try MappingPostProcessor.parseProposals(response.content)
                for key in keys { if let p = parsed[key] { proposals[key] = p } }
            } catch {
                out.stderr += "error: mapping request for \(keys.first ?? "")…\(keys.last ?? "") failed: \(error)\n"
                out.exitCode = 1
                return out
            }
        }
        let (mapping, warnings) = MappingPostProcessor.assemble(profile: options.profile, proposals: proposals,
                                                                base: options.base)
        out.mapping = mapping
        out.stdout = MappingPostProcessor.json(mapping, profile: options.profile).prettySerialized() + "\n"
        let counts = Dictionary(grouping: mapping.fields.values, by: \.mode.rawValue).mapValues(\.count)
        out.stderr += warnings.map { "warning: \($0)\n" }.joined()
            + "\(mapping.fields.count) fields mapped in \(out.requestsSent) request(s): "
            + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"
        return out
    }
}

extension JSONValue {
    /// Indented JSON with the same key order and escaping as `serialized()`.
    public func prettySerialized(indent: String = "  ") -> String {
        var out = ""
        pretty(into: &out, level: 0, indent: indent)
        return out
    }

    private func pretty(into out: inout String, level: Int, indent: String) {
        let pad = String(repeating: indent, count: level + 1)
        let close = String(repeating: indent, count: level)
        switch self {
        case .array(let a) where !a.isEmpty:
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.pretty(into: &out, level: level + 1, indent: indent)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case .object(let o) where !o.isEmpty:
            out += "{\n"
            let entries = o.entries
            for (i, (k, v)) in entries.enumerated() {
                out += pad + JSONValue.string(k).serialized() + ": "
                v.pretty(into: &out, level: level + 1, indent: indent)
                out += i < entries.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        default:
            out += serialized()
        }
    }
}
