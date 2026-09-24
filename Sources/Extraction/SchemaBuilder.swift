import ScribeskiCore

/// Builds the per-field JSON Schema sent as `response_format: json_schema`.
///
/// Every schema is an `anyOf` of two shapes, so the sampler can only produce one of:
/// - **filled**: `status: "filled"`, at least one evidence item, and a value of the field's
///   type (an option enum, a date pattern, a length-capped string);
/// - **insufficient**: `status: "insufficient_evidence"`, no evidence, no value.
///
/// Only keywords llama.cpp's `json-schema-to-grammar` compiles are used: `type`, `enum`,
/// `const`, `anyOf`, `properties`, `required`, `additionalProperties: false`, `items`,
/// `minItems`, `maxItems`, `pattern`, `minLength`, `maxLength`. Patterns use `[0-9]`
/// rather than `\d`. Checkbox uniqueness can't be expressed in a grammar, so the verifier
/// de-duplicates instead.
public enum SchemaBuilder {
    /// Maximum characters in one evidence quote.
    /// Output tokens are ~75% of extraction time, so quotes are short: the words that carry
    /// the answer, not the paragraph around them.
    public static let maxQuoteLength = 160
    /// Maximum evidence items per value, option, or sentence.
    public static let maxEvidenceItems = 3
    public static let defaultTextMaxChars = 200
    public static let defaultNarrativeMaxChars = 900
    public static let maxNarrativeSentences = 4
    public static let maxNarrativeSentenceChars = 300
    public static let periods = ["day", "week", "month", "year"]
    public static let segmentPattern = "^s[0-9]{4}$"
    public static let datePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"

    /// The llama.cpp / OpenAI `response_format` object wrapping `schema(for:mapping:)`.
    public static func responseFormat(for field: FormProfile.Field,
                                      mapping: FormMapping.FieldMapping, gated: Bool = false) -> JSONValue {
        .obj([
            "type": "json_schema",
            "json_schema": .obj([
                "name": .string(schemaName(field.key)),
                "strict": true,
                "schema": schema(for: field, mapping: mapping, gated: gated),
            ]),
        ])
    }

    /// The per-field schema. `mapping.mode` picks narrative vs. discrete; the profile kind
    /// picks the value shape.
    ///
    /// `gated` (selection fields that aren't questionnaire items): the answer must open with
    /// `discussed`. "no" forces an empty answer: the model has to decide explicitly whether
    /// the topic came up before it can pick a value, instead of reading silence as "None" or
    /// "Independent". "yes" requires `raised_at`, the line where it came up, which the
    /// verifier checks like any quote and uses as the question context.
    public static func schema(for field: FormProfile.Field,
                              mapping: FormMapping.FieldMapping, gated: Bool = false) -> JSONValue {
        let (filled, empty) = shapes(field, mapping)
        let filledStatus = ("status", JSONValue.obj(["const": "filled"]))
        let emptyStatus = ("status", JSONValue.obj(["const": "insufficient_evidence"]))
        guard gated else {
            return .obj(["anyOf": .array([object([filledStatus] + filled), object([emptyStatus] + empty)])])
        }
        let yes = [("discussed", JSONValue.obj(["const": "yes"])), ("raised_at", evidenceItem)]
        return .obj(["anyOf": .array([
            object([("discussed", .obj(["const": "no"])), emptyStatus] + empty),
            object(yes + [emptyStatus] + empty),
            object(yes + [filledStatus] + filled),
        ])])
    }

    /// The filled and empty property lists (without `status`) for a field.
    static func shapes(_ field: FormProfile.Field, _ mapping: FormMapping.FieldMapping)
        -> (filled: [(String, JSONValue)], empty: [(String, JSONValue)]) {
        if mapping.mode == .narrative {
            let maxChars = mapping.maxChars ?? defaultNarrativeMaxChars
            let sentence = object([
                ("text", .obj(["type": "string", "minLength": 1,
                               "maxLength": .int(min(maxChars, maxNarrativeSentenceChars))])),
                ("evidence", evidenceArray(min: 1, max: 2)),
            ])
            return ([("sentences", .obj(["type": "array", "items": sentence, "minItems": 1,
                                         "maxItems": .int(maxNarrativeSentences)]))],
                    [("sentences", .obj(["type": "array", "items": sentence, "maxItems": 0]))])
        }
        if mapping.perMonthBands != nil {
            return ([("evidence", evidenceArray(min: 1, max: maxEvidenceItems)),
                     ("count", .obj(["type": "number"])),
                     ("period", .obj(["type": "string", "enum": .strings(periods)]))],
                    [("evidence", evidenceArray(min: 0, max: 0)),
                     ("count", .obj(["type": "null"])), ("period", .obj(["type": "null"]))])
        }
        switch field.kind {
        case .checkboxGroup:
            let selection = object([
                ("value", .obj(["type": "string", "enum": .strings(field.options.map(\.value))])),
                ("evidence", evidenceArray(min: 1, max: maxEvidenceItems)),
            ])
            return ([("selections", .obj(["type": "array", "items": selection, "minItems": 1,
                                          "maxItems": .int(max(1, field.options.count))]))],
                    [("selections", .obj(["type": "array", "items": selection, "maxItems": 0]))])
        case .select, .radioGroup, .combobox:
            return discrete(value: .obj(["type": "string", "enum": .strings(field.options.map(\.value))]))
        case .date:
            return discrete(value: .obj(["type": "string", "pattern": .string(datePattern)]))
        case .text, .textarea, .hidden:
            let maxChars = mapping.maxChars ?? defaultTextMaxChars
            return discrete(value: .obj(["type": "string", "minLength": 1, "maxLength": .int(maxChars)]))
        }
    }

    /// `{segment, quote}`: a segment id and a verbatim quote from it.
    public static var evidenceItem: JSONValue {
        object([
            ("segment", .obj(["type": "string", "pattern": .string(segmentPattern)])),
            ("quote", .obj(["type": "string", "minLength": 1, "maxLength": .int(maxQuoteLength)])),
        ])
    }

    // MARK: - Helpers

    static func schemaName(_ key: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return "field_" + String(safe)
    }

    static func evidenceArray(min: Int, max: Int) -> JSONValue {
        var o = JSONObject()
        o["type"] = "array"
        o["items"] = evidenceItem
        if min > 0 { o["minItems"] = .int(min) }
        o["maxItems"] = .int(max)
        return .object(o)
    }

    /// A closed object: every property required, nothing else allowed.
    static func object(_ properties: [(String, JSONValue)]) -> JSONValue {
        var props = JSONObject()
        for (k, v) in properties { props[k] = v }
        return .obj([
            "type": "object",
            "properties": .object(props),
            "required": .strings(properties.map(\.0)),
            "additionalProperties": false,
        ])
    }

    /// Discrete single value: evidence comes before value so the value is generated
    /// after, and conditioned on, the quotes.
    static func discrete(value: JSONValue) -> (filled: [(String, JSONValue)], empty: [(String, JSONValue)]) {
        ([("evidence", evidenceArray(min: 1, max: maxEvidenceItems)), ("value", value)],
         [("evidence", evidenceArray(min: 0, max: 0)), ("value", .obj(["type": "null"]))])
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
}
