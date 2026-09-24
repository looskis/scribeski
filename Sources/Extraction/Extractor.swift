import Foundation
import ScribeskiCore

/// Runs per-field extraction over a whole form.
///
/// For each profile field, in profile order:
/// - no mapping, `skip`, or a hidden/computed field without a derivation → omitted;
/// - `clinician_only` → `clinician_only`, never sent to the model;
/// - `derived` → computed in code after all discrete fields (see `Derivations`);
/// - `discrete` / `narrative` → one request, verified by `Verifier`.
///
/// Requests go out in profile order, `concurrency` at a time. With concurrency 1 the first
/// result's `prefill_tokens` is the full prefix and every later one should be near zero:
/// that is what the scorer's cache assertion checks.
public struct Extractor: Sendable {
    public var client: any LLMClient
    /// Recorded on every result, e.g. `gemma-4-26b-a4b-qat-q4_0`.
    public var model: String
    public var concurrency: Int
    public var prompts: PromptBuilder

    public init(client: any LLMClient, model: String, concurrency: Int = 1,
                prompts: PromptBuilder = PromptBuilder()) {
        self.client = client
        self.model = model
        self.concurrency = max(1, concurrency)
        self.prompts = prompts
    }

    /// What happens to one field.
    public enum Plan: Hashable, Sendable {
        case request(FormMapping.FieldMapping)
        case clinicianOnly
        case derived(FormMapping.Derivation)
        case omit
    }

    public static func plan(_ field: FormProfile.Field, _ mapping: FormMapping.FieldMapping?) -> Plan {
        guard let mapping else { return .omit }
        switch mapping.mode {
        case .skip: return .omit
        case .clinicianOnly: return .clinicianOnly
        case .derived:
            guard let derive = mapping.derive else { return .omit }
            return .derived(derive)
        case .discrete, .narrative:
            if field.computed || field.kind == .hidden || field.write == .never { return .omit }
            if mapping.mode == .discrete, field.kind != .text, field.kind != .textarea,
               field.kind != .date, field.options.isEmpty {
                return .omit // a choice field with no options can't be answered
            }
            return .request(mapping)
        }
    }

    public func extract(transcript: Transcript, profile: FormProfile,
                        mapping: FormMapping) async throws -> [FieldResult] {
        let plans = profile.fields.map { Self.plan($0, mapping.fields[$0.key]) }
        var results = [FieldResult?](repeating: nil, count: plans.count)

        let requests: [(index: Int, field: FormProfile.Field, mapping: FormMapping.FieldMapping)] =
            plans.enumerated().compactMap { i, plan in
                if case .request(let m) = plan { return (i, profile.fields[i], m) }
                return nil
            }

        // Questionnaire items: radio groups whose label is a full question (PHQ-9, GAD-7 rows).
        let questions = Dictionary(uniqueKeysWithValues: profile.fields
            .filter { $0.kind == .radioGroup && $0.label.split(separator: " ").count >= 5 }
            .map { ($0.key, $0.label) })
        let verifier = Verifier(transcript: transcript, questions: questions)
        let questionnaire = Set(questions.keys)
        try await withThrowingTaskGroup(of: (Int, FieldResult).self) { group in
            var next = 0
            func launch() {
                let r = requests[next]
                next += 1
                group.addTask { [self] in
                    (r.index, try await self.run(r.field, r.mapping, transcript, verifier,
                                                 gated: Self.isGated(r.field, r.mapping, questionnaire: questionnaire)))
                }
            }
            while next < requests.count, next < concurrency { launch() }
            while let (i, result) = try await group.next() {
                results[i] = result
                if next < requests.count { launch() }
            }
        }

        for (i, plan) in plans.enumerated() where plan == .clinicianOnly {
            results[i] = FieldResult(key: profile.fields[i].key, status: .clinicianOnly)
        }

        // Derived fields, possibly depending on other derived fields (band from total).
        var values: [String: FieldValue] = [:]
        for case let r? in results where r.status == .filled || r.status == .derived {
            if let v = r.value { values[r.key] = v }
        }
        var pending = plans.enumerated().compactMap { i, plan -> (Int, FormMapping.Derivation)? in
            if case .derived(let d) = plan { return (i, d) }
            return nil
        }
        var progressed = true
        while progressed, !pending.isEmpty {
            progressed = false
            pending.removeAll { i, derive in
                guard let v = Derivations.compute(derive, values: values) else { return false }
                let key = profile.fields[i].key
                values[key] = .single(v)
                results[i] = FieldResult(key: key, status: .derived, value: .single(v))
                progressed = true
                return true
            }
        }
        for (i, _) in pending {
            results[i] = FieldResult(key: profile.fields[i].key, status: .insufficientEvidence)
        }

        return results.compactMap { $0 }
    }

    func run(_ profileField: FormProfile.Field, _ mapping: FormMapping.FieldMapping,
             _ transcript: Transcript, _ verifier: Verifier, gated: Bool = false) async throws -> FieldResult {
        // Excluded options vanish from schema, prompt, and verifier alike.
        var field = profileField
        if let excluded = mapping.excludeOptions, !excluded.isEmpty {
            field.options.removeAll { excluded.contains($0.value) }
        }
        let request = ChatRequest(
            messages: prompts.messages(transcript: transcript, field: field, mapping: mapping, gated: gated),
            responseFormat: SchemaBuilder.responseFormat(for: field, mapping: mapping, gated: gated),
            maxTokens: Self.maxTokens(field, mapping))
        let response = try await client.complete(request)
        var result = verifier.verify(field: field, mapping: mapping, output: response.content)
        result.model = model
        result.prefillTokens = response.prefillTokens
        result.ms = response.ms
        return result
    }

    /// Selection fields answer "was it discussed?" before a value. Questionnaire items are
    /// exempt: their question is located in code (`Verifier.checkQuestion`).
    static func isGated(_ field: FormProfile.Field, _ mapping: FormMapping.FieldMapping,
                        questionnaire: Set<String>) -> Bool {
        guard mapping.mode == .discrete, !questionnaire.contains(field.key) else { return false }
        return [.select, .radioGroup, .combobox, .checkboxGroup].contains(field.kind)
    }

    /// Caps sized to the schema's own limits (3 quotes of ≤ 160 chars; ≤ 4 narrative sentences
    /// of ≤ 300 chars with ≤ 2 quotes each), so a well-formed answer always fits.
    static func maxTokens(_ field: FormProfile.Field, _ mapping: FormMapping.FieldMapping) -> Int {
        if mapping.mode == .narrative { return 1024 }
        if field.kind == .checkboxGroup { return 1024 }
        return 384
    }
}
