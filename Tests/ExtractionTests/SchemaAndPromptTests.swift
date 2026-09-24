import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

@Suite struct SchemaBuilderTests {
    let profile: FormProfile
    let mapping: FormMapping

    init() throws {
        profile = try Fixtures.mockEHRProfile()
        mapping = try Fixtures.mapping()
    }

    func schema(_ key: String) throws -> JSONValue {
        SchemaBuilder.schema(for: try Fixtures.field(profile, key), mapping: try #require(mapping.fields[key]))
    }

    func branches(_ s: JSONValue) throws -> (filled: JSONValue, empty: JSONValue) {
        let any = try #require(s["anyOf"]?.arrayValue)
        #expect(any.count == 2)
        #expect(any[0]["properties"]?["status"]?["const"] == "filled")
        #expect(any[1]["properties"]?["status"]?["const"] == "insufficient_evidence")
        for b in any {
            #expect(b["additionalProperties"] == false)
            #expect(b["type"] == "object")
        }
        return (any[0], any[1])
    }

    @Test func selectIsEnumOfOptionValues() throws {
        let (filled, empty) = try branches(schema("si_ideation"))
        #expect(filled["properties"]?["value"]?["enum"] == .strings(["NONE", "PASSIVE", "ACTIVE_NO_PLAN", "ACTIVE_WITH_PLAN"]))
        #expect(filled["properties"]?["evidence"]?["minItems"] == 1)
        #expect(filled["required"] == .strings(["status", "evidence", "value"]))
        #expect(empty["properties"]?["value"]?["type"] == "null")
        #expect(empty["properties"]?["evidence"]?["maxItems"] == 0)
    }

    @Test func radioAndComboboxAreEnums() throws {
        #expect(try branches(schema("phq9_4")).filled["properties"]?["value"]?["enum"] == .strings(["0", "1", "2", "3"]))
        let lang = try branches(schema("language_combo")).filled["properties"]?["value"]?["enum"]?.arrayValue
        #expect(lang?.count == 7)
    }

    @Test func evidenceItemShape() throws {
        let item = try #require(try branches(schema("pronouns")).filled["properties"]?["evidence"]?["items"])
        #expect(item["properties"]?["segment"]?["pattern"] == "^s[0-9]{4}$")
        #expect(item["properties"]?["quote"]?["maxLength"] == .int(SchemaBuilder.maxQuoteLength))
        #expect(item["required"] == .strings(["segment", "quote"]))
        #expect(item["additionalProperties"] == false)
    }

    @Test func dateHasPattern() throws {
        let v = try branches(schema("next_appointment")).filled["properties"]?["value"]
        #expect(v?["pattern"] == "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    }

    @Test func textHasMaxLength() throws {
        let v = try branches(schema("case_number")).filled["properties"]?["value"]
        #expect(v?["type"] == "string")
        #expect(v?["maxLength"] == 20)
    }

    @Test func checkboxIsPerOptionSelections() throws {
        let (filled, empty) = try branches(schema("substances"))
        let sel = try #require(filled["properties"]?["selections"])
        #expect(sel["minItems"] == 1)
        #expect(sel["maxItems"] == 6)
        #expect(sel["items"]?["properties"]?["value"]?["enum"]?.arrayValue?.count == 6)
        #expect(sel["items"]?["properties"]?["evidence"]?["minItems"] == 1)
        #expect(empty["properties"]?["selections"]?["maxItems"] == 0)
    }

    @Test func narrativeIsCitedSentences() throws {
        let (filled, empty) = try branches(schema("risk_narrative"))
        let s = try #require(filled["properties"]?["sentences"])
        #expect(s["items"]?["required"] == .strings(["text", "evidence"]))
        #expect(s["items"]?["properties"]?["evidence"]?["minItems"] == 1)
        #expect(empty["properties"]?["sentences"]?["maxItems"] == 0)
    }

    @Test func responseFormatWrapsSchema() throws {
        let field = try Fixtures.field(profile, "si_plan")
        let rf = SchemaBuilder.responseFormat(for: field, mapping: try #require(mapping.fields["si_plan"]))
        #expect(rf["type"] == "json_schema")
        #expect(rf["json_schema"]?["name"] == "field_si_plan")
        #expect(rf["json_schema"]?["strict"] == true)
        #expect(rf["json_schema"]?["schema"]?["anyOf"] != nil)
    }

    /// Only keywords llama.cpp's json-schema-to-grammar compiles.
    @Test func onlyGrammarSafeKeywords() throws {
        let allowed: Set<String> = ["type", "enum", "const", "anyOf", "properties", "required",
                                    "additionalProperties", "items", "minItems", "maxItems", "pattern",
                                    "minLength", "maxLength"]
        func walk(_ v: JSONValue, underProperties: Bool = false) {
            switch v {
            case .object(let o):
                for (k, child) in o.entries {
                    if !underProperties { #expect(allowed.contains(k), "keyword \(k)") }
                    walk(child, underProperties: !underProperties && k == "properties")
                }
            case .array(let a): a.forEach { walk($0) }
            default: break
            }
        }
        for field in profile.fields {
            guard let m = mapping.fields[field.key], case .request = Extractor.plan(field, m) else { continue }
            walk(SchemaBuilder.schema(for: field, mapping: m))
        }
    }
}

@Suite struct PromptBuilderTests {
    @Test func prefixIsByteIdenticalAcrossEveryMockEHRField() throws {
        let t = try Fixtures.sampleTranscript()
        let profile = try Fixtures.mockEHRProfile()
        let mapping = try Fixtures.mapping()
        let expectedPrefix = PromptBuilder.prefix(transcript: t)
        #expect(expectedPrefix.contains("s0315 CLIENT: No. None of that."))
        #expect(expectedPrefix.contains("2026-09-17T14:00:00-07:00"))
        #expect(expectedPrefix.contains("a Thursday"))

        let requested = profile.fields.compactMap { f -> (FormProfile.Field, FormMapping.FieldMapping)? in
            guard case .request(let m) = Extractor.plan(f, mapping.fields[f.key]) else { return nil }
            return (f, m)
        }
        #expect(requested.count > 60)

        for layout in [PromptBuilder.Layout.systemAndUser, .singleUser] {
            let builder = PromptBuilder(layout: layout)
            var firstBytes: [UInt8]?
            for (field, m) in requested {
                let messages = builder.messages(transcript: t, field: field, mapping: m)
                let prefixBytes: [UInt8]
                switch layout {
                case .systemAndUser:
                    #expect(messages.map(\.role) == ["system", "user"])
                    prefixBytes = Array(messages[0].content.utf8)
                case .singleUser:
                    #expect(messages.map(\.role) == ["user"])
                    prefixBytes = Array(messages[0].content.utf8.prefix(expectedPrefix.utf8.count))
                }
                if let firstBytes { #expect(prefixBytes == firstBytes, "prefix differs for \(field.key)") }
                firstBytes = prefixBytes
                #expect(prefixBytes == Array(expectedPrefix.utf8))
            }
        }
    }

    @Test func suffixDescribesOnlyItsOwnField() throws {
        let profile = try Fixtures.mockEHRProfile()
        let mapping = try Fixtures.mapping()
        let keys = profile.fields.map(\.key).filter { $0.contains("_") }
        for field in profile.fields {
            guard case .request(let m) = Extractor.plan(field, mapping.fields[field.key]) else { continue }
            let suffix = PromptBuilder.suffix(field: field, mapping: m)
            #expect(suffix.contains("key: \(field.key)\n"))
            #expect(suffix.contains("label: \(field.label)"))
            let tokens = Set(suffix.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init))
            for other in keys where other != field.key {
                #expect(!tokens.contains(other), "\(field.key) suffix mentions \(other)")
            }
        }
    }

    @Test func suffixCarriesOptionsSemanticsAndSpeakerRule() throws {
        let profile = try Fixtures.mockEHRProfile()
        let mapping = try Fixtures.mapping()
        let m = try #require(mapping.fields["substances"])
        let s = PromptBuilder.suffix(field: try Fixtures.field(profile, "substances"), mapping: m)
        #expect(s.contains("- CANNABIS: Cannabis (means: client reports using cannabis; a worker asking about cannabis is not a report)"))
        #expect(s.contains("evidence rule: CLIENT · answer format: CHOICES"))
        // The rule text itself lives once, in the cached prefix.
        #expect(!s.contains("CLIENT's own words"))
        #expect(PromptBuilder.answerGuide.contains("CLIENT's own words"))
        #expect(PromptBuilder.answerGuide.contains(#""selections""#))
        let gated = PromptBuilder.suffix(field: try Fixtures.field(profile, "substances"), mapping: m, gated: true)
        #expect(gated.hasSuffix("ask first: was it discussed?"))
    }
}
