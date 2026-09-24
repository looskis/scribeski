import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

/// The "was it discussed?" gate and code-side frequency bands (corpus run 2's two largest
/// classes of unsafe output: silence read as an answer, and month/week confusion).
@Suite struct GateAndBandTests {
    let t: Transcript
    let profile: FormProfile
    let mapping: FormMapping
    let verifier: Verifier

    init() throws {
        t = try Fixtures.sampleTranscript()
        profile = try Fixtures.mockEHRProfile()
        mapping = try Fixtures.mapping()
        verifier = Verifier(transcript: t)
    }

    func verify(_ key: String, _ answer: JSONValue) throws -> FieldResult {
        verifier.verify(field: try Fixtures.field(profile, key), mapping: try #require(mapping.fields[key]), answer: answer)
    }

    // MARK: Gate

    @Test func notDiscussedIsBlankWhateverElseIsThere() throws {
        let r = try verify("iadl_transport", .obj(["discussed": "no", "status": "insufficient_evidence",
                                                    "evidence": .array([]), "value": .null]))
        #expect(r.status == .insufficientEvidence)
        #expect(r.value == nil)
    }

    @Test func raisedAtMustBeARealQuote() throws {
        let s = try Fixtures.segment(t, "She/her.", speaker: .client)
        let answer: JSONValue = .obj(["discussed": "yes", "raised_at": ev(s.id, "What pronouns do you use, and do you like?"),
                                      "status": "filled", "evidence": .array([ev(s)]), "value": "SHE_HER"])
        #expect(try verify("pronouns", answer).rejectReason == .quoteNotFound)
    }

    @Test func raisedAtSuppliesQuestionContextForAShortNo() throws {
        // The worker's question, cited as raised_at, lets a bare "No, never." stand.
        let q = try Fixtures.segment(t, "hurting someone else", speaker: .worker)
        let a = t.segments[t.segments.firstIndex(of: q)! + 1]
        let answer: JSONValue = .obj(["discussed": "yes", "raised_at": ev(q), "status": "filled",
                                      "evidence": .array([ev(a)]), "value": "NONE"])
        let r = try verify("hi_ideation", answer)
        #expect(r.status == .filled)
        #expect(r.evidence.map(\.segment) == [q.id, a.id])
    }

    @Test func gatedCheckboxCarriesRaisedAtIntoEachSelection() throws {
        let q = try Fixtures.segment(t, "Any cannabis? Opioids, like pain pills?", speaker: .worker)
        let beer = try Fixtures.segment(t, "A couple beers", speaker: .client)
        let answer: JSONValue = .obj(["discussed": "yes", "raised_at": ev(q), "status": "filled",
                                      "selections": .array([.obj(["value": "ALCOHOL", "evidence": .array([ev(beer)])]),
                                                            .obj(["value": "CANNABIS", "evidence": .array([ev(q)])])])])
        let r = try verify("substances", answer)
        #expect(r.value == .multiple(["ALCOHOL"]))
    }

    @Test func gatingAppliesToSelectionFieldsButNotQuestionnaireItems() throws {
        let f = { (k: String) in try Fixtures.field(self.profile, k) }
        let m = { (k: String) in try #require(self.mapping.fields[k]) }
        let q: Set<String> = ["phq9_1"]
        #expect(Extractor.isGated(try f("iadl_transport"), try m("iadl_transport"), questionnaire: q))
        #expect(Extractor.isGated(try f("substances"), try m("substances"), questionnaire: q))
        #expect(!Extractor.isGated(try f("phq9_1"), try m("phq9_1"), questionnaire: q))
        #expect(!Extractor.isGated(try f("client_first_name"), try m("client_first_name"), questionnaire: q))
        #expect(!Extractor.isGated(try f("presenting_problem"), try m("presenting_problem"), questionnaire: q))
    }

    @Test func gatedSchemaOffersNotDiscussedFirst() throws {
        let field = try Fixtures.field(profile, "food_security")
        let schema = SchemaBuilder.schema(for: field, mapping: try #require(mapping.fields["food_security"]), gated: true)
        let shapes = try #require(schema["anyOf"]?.arrayValue)
        #expect(shapes.count == 3)
        #expect(shapes[0]["properties"]?["discussed"]?["const"] == "no")
        #expect(shapes[2]["required"]?.arrayValue?.first == "discussed")
    }

    // MARK: Frequency bands

    @Test(arguments: [
        (2.5, "month", "TWO_TO_FOUR_PER_MONTH"),   // "two or three Saturdays a month"
        (1.0, "week", "TWO_TO_FOUR_PER_MONTH"),    // weekly ≈ 4.3 a month
        (2.5, "week", "TWO_TO_THREE_PER_WEEK"),
        (5.0, "week", "FOUR_PLUS_PER_WEEK"),
        (6.0, "year", "MONTHLY_OR_LESS"),
        (0.0, "month", "NEVER"),
    ])
    func countAndPeriodMapToABand(_ count: Double, _ period: String, _ band: String) throws {
        let bands = try #require(mapping.fields["alcohol_frequency"]?.perMonthBands)
        #expect(Verifier.band(count: count, period: period, bands: bands) == band)
    }

    @Test func frequencyFieldIsFilledFromCountAndPeriod() throws {
        let s = try Fixtures.segment(t, "two or three Saturdays a month", speaker: .client)
        let answer: JSONValue = .obj(["status": "filled", "evidence": .array([ev(s)]), "count": .double(2.5), "period": "month"])
        let r = try verify("alcohol_frequency", answer)
        #expect(r.status == .filled)
        #expect(r.value == .single("TWO_TO_FOUR_PER_MONTH"))
    }
}
