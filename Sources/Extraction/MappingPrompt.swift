import ScribeskiCore

/// The setup-time mapping request (BUILD_PLAN P1.4): the model proposes, per field,
/// `{intent, mode, evidence_speaker, option_semantics?, max_chars?}`; the worker reviews.
///
/// The model sees only `EgressPayload` fields, never a transcript. Requests are batched
/// deterministically in payload (profile) order, and each batch's output is constrained by a
/// JSON schema built in code: one required property per field key, closed objects, enums for
/// `mode` and `evidence_speaker`, `option_semantics` keyed exactly by that field's option
/// values, and `max_chars` only for free-text fields. Same llama.cpp-compilable keyword subset
/// as `SchemaBuilder`.
public enum MappingPrompt {
    public static let defaultBatchSize = 15
    public static let maxIntentLength = 400
    public static let maxSemanticsLength = 200

    /// Modes the model may propose. `derived` is decided in code (hidden, page-computed
    /// fields never reach the model), so it is not offered.
    public static let proposableModes: [FormMapping.Mode] = [.discrete, .narrative, .clinicianOnly, .skip]

    public static let speakers: [FormMapping.EvidenceSpeaker] = [.client, .any, .worker]

    public static let system = """
    You are configuring a documentation assistant for social workers. You see the structure \
    of one EHR form: field keys, kinds, labels, help text, and options. You never see a \
    session transcript or any client data. For every field you are given, propose how a \
    later extraction step should treat it, as JSON matching the schema exactly.

    For each field return:
    - intent: one or two plain sentences saying what the field records and whose words count \
    as evidence. Say what must NOT be inferred when that is a real risk (e.g. gender identity \
    from pronouns).
    - mode:
      - "discrete": one value (an option, a date, or a short text) stated in the session.
      - "narrative": a free-text summary written from the session (long textareas such as \
    presenting problem, history, interventions, plan).
      - "clinician_only": professional judgement the worker must make, never extracted: \
    overall risk level, mental-status observations the clinician makes (appearance, affect, \
    thought process, orientation, insight, judgment), diagnosis or diagnostic impression, \
    recommended level of care, attestations or signatures, supervisor consultation.
      - "skip": session metadata the app supplies itself: session date, duration, modality \
    (video/phone/in person).
    - evidence_speaker:
      - "client": the client's own state, history, symptoms, circumstances, demographics, \
    contact details, questionnaire answers (PHQ-9, GAD-7 and similar items), substance use, \
    housing, income, supports, goals, the client's own words.
      - "any": facts the worker asserts about the session itself: whether an instrument was \
    completed or deferred, whether a safety plan was completed, referrals made, resources \
    given, session type, consents, follow-up. Also "any" for narrative, clinician_only and skip.
      - "worker": only when solely the worker's statement can count.
    - option_semantics (only for fields that have options): for EVERY option value, a short \
    rule for when that option applies, phrased as what must be said in the session. For \
    options that only record absence ("Not asked", "Not assessed", "Unknown"), say to leave \
    the field blank instead.
    - max_chars (only for text and textarea fields): a sensible length cap; short for names, \
    ids, phone numbers; 800-1200 for narratives.

    Never propose inferring a value the client did not state. Prefer leaving a field blank \
    over guessing.
    """

    /// Payload keys split into batches of `size`, in payload order.
    public static func batches(_ payload: EgressPayload, size: Int = defaultBatchSize) -> [[String]] {
        let keys = payload.fields.map(\.key)
        let n = max(1, size)
        return stride(from: 0, to: keys.count, by: n).map { Array(keys[$0..<min($0 + n, keys.count)]) }
    }

    public static func request(_ payload: EgressPayload, keys: [String]) -> ChatRequest {
        let user = """
        Form fields (JSON):
        \(payload.json(keys: keys).serialized())

        Return one entry per field key: \(keys.joined(separator: ", ")).
        """
        return ChatRequest(messages: [ChatMessage(role: "system", content: system),
                                      ChatMessage(role: "user", content: user)],
                           responseFormat: responseFormat(payload, keys: keys),
                           maxTokens: 400 * keys.count + 200)
    }

    public static func responseFormat(_ payload: EgressPayload, keys: [String]) -> JSONValue {
        .obj([
            "type": "json_schema",
            "json_schema": .obj(["name": "form_mapping_batch", "strict": true, "schema": schema(payload, keys: keys)]),
        ])
    }

    public static func schema(_ payload: EgressPayload, keys: [String]) -> JSONValue {
        let byKey = Dictionary(payload.fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return SchemaBuilder.object(keys.compactMap { key in byKey[key].map { (key, fieldSchema($0)) } })
    }

    public static func hasFreeText(_ kind: FormProfile.Kind) -> Bool {
        kind == .text || kind == .textarea
    }

    static func fieldSchema(_ field: EgressPayload.Field) -> JSONValue {
        var props: [(String, JSONValue)] = [
            ("intent", .obj(["type": "string", "minLength": 1, "maxLength": .int(maxIntentLength)])),
            ("mode", .obj(["type": "string", "enum": .strings(proposableModes.map(\.rawValue))])),
            ("evidence_speaker", .obj(["type": "string",
                                       "enum": .strings(speakers.map(\.rawValue))])),
        ]
        let values = field.optionList.map(\.value)
        if !values.isEmpty {
            props.append(("option_semantics", SchemaBuilder.object(values.map {
                ($0, .obj(["type": "string", "minLength": 1, "maxLength": .int(maxSemanticsLength)]))
            })))
        }
        if hasFreeText(field.kind) {
            props.append(("max_chars", .obj(["type": "integer"])))
        }
        return SchemaBuilder.object(props)
    }
}
