import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

@Suite struct ExtractorTests {
    let t: Transcript
    let full: FormProfile
    let mapping: FormMapping

    init() throws {
        t = try Fixtures.sampleTranscript()
        full = try Fixtures.mockEHRProfile()
        mapping = try Fixtures.mapping()
    }

    func answer(_ value: String, _ fragments: [(String, Speaker)]) throws -> String {
        let evidence = try fragments.map { try ev(Fixtures.segment(t, $0.0, speaker: $0.1)) }
        return filled(value, evidence).serialized()
    }

    /// A small profile: a text field, a select, a never-mentioned select, a skipped metadata
    /// field, the nine PHQ-9 items and their derived score and band, one GAD-7 item and its
    /// (underivable) score, a clinician-only field, the substances trap, a narrative, and a
    /// field with no mapping at all.
    func smallProfile() throws -> FormProfile {
        let keys = ["case_number", "pronouns", "gender_identity", "session_date"]
            + (1...9).map { "phq9_\($0)" } + ["phq9_score", "phq9_severity", "gad7_1", "gad7_score",
                                               "risk_level", "substances", "risk_narrative"]
        var fields = try keys.map { try Fixtures.field(full, $0) }
        fields.insert(FormProfile.Field(key: "ghost", step: "step-1", kind: .text, label: "Unmapped",
                                        labelSource: .labelFor, selectors: ["#ghost"], write: .nativeSetter), at: 2)
        return FormProfile(origin: full.origin, pathPattern: full.pathPattern, fingerprint: "sha256:pending",
                           steps: [], fields: fields)
    }

    func script() throws -> [String: String] {
        var a: [String: String] = [:]
        a["case_number"] = try answer("AB-114322", [("I have your case number here as AB-114322.", .worker),
                                                    ("Yeah. AB-114322. That's it.", .client)])
        a["pronouns"] = try answer("SHE_HER", [("She/her.", .client)])
        // gender_identity: the model (correctly) declines; the default scripted answer.
        let phq: [(String, String)] = [
            ("2", "I'd say more than half the days."), ("3", "Nearly every day."),
            ("3", "Nearly every day. Like I said, the sleep is bad."), ("2", "More than half the days, I guess."),
            ("1", "Then — several days, maybe."), ("2", "More than half the days. Like, I feel like I let him down."),
            ("2", "More than half the days. I'll be filling out"), ("2", "More than half the days, probably."),
            ("1", "Several days. Not like — I'm not going to do anything."),
        ]
        for (i, (value, fragment)) in phq.enumerated() {
            a["phq9_\(i + 1)"] = try answer(value, [(fragment, .client)])
        }
        let question = try Fixtures.segment(t, "Any cannabis?", speaker: .worker)
        let denial = try Fixtures.segment(t, "No. None of that.", speaker: .client)
        let beers = try Fixtures.segment(t, "A couple beers", speaker: .client)
        a["substances"] = selections([("ALCOHOL", [ev(beers)]),
                                      ("CANNABIS", [ev(question, "Any cannabis?"), ev(denial)])]).serialized()
        let si = try Fixtures.segment(t, "easier if I just didn't wake up", speaker: .client)
        a["risk_narrative"] = sentences([
            ("Client described passive thoughts that it would be easier not to wake up.",
             [ev(si, "it'd be easier if I just didn't wake up")]),
            ("Client's overall risk is low.", [ev(si, "risk is low")]),
        ]).serialized()
        a["risk_level"] = #"{"status":"filled","evidence":[],"value":"LOW"}"# // must never be asked
        return a
    }

    func run(concurrency: Int) async throws -> (results: [FieldResult], client: ScriptedClient) {
        let client = ScriptedClient(try script())
        let extractor = Extractor(client: client, model: "test-model@sha256:abc", concurrency: concurrency)
        let results = try await extractor.extract(transcript: t, profile: try smallProfile(), mapping: mapping)
        return (results, client)
    }

    @Test func endToEndOverSampleTranscript() async throws {
        let (results, client) = try await run(concurrency: 1)
        let byKey = Dictionary(uniqueKeysWithValues: results.map { ($0.key, $0) })

        #expect(results.map(\.key) == ["case_number", "pronouns", "gender_identity"]
            + (1...9).map { "phq9_\($0)" } + ["phq9_score", "phq9_severity", "gad7_1", "gad7_score",
                                               "risk_level", "substances", "risk_narrative"],
            "profile order; skip and unmapped omitted")

        #expect(byKey["case_number"]?.status == .filled)
        #expect(byKey["case_number"]?.value == .single("AB-114322"))
        #expect(byKey["pronouns"]?.value == .single("SHE_HER"))
        #expect(byKey["gender_identity"]?.status == .insufficientEvidence)
        for i in 1...9 { #expect(byKey["phq9_\(i)"]?.status == .filled, "phq9_\(i)") }

        #expect(byKey["phq9_score"]?.status == .derived)
        #expect(byKey["phq9_score"]?.value == .single("18"))
        #expect(byKey["phq9_severity"]?.value == .single("MODERATELY_SEVERE"))
        #expect(byKey["gad7_1"]?.status == .insufficientEvidence)
        #expect(byKey["gad7_score"]?.status == .insufficientEvidence)
        #expect(byKey["gad7_score"]?.value == nil)

        #expect(byKey["risk_level"]?.status == .clinicianOnly)
        #expect(byKey["risk_level"]?.value == nil)
        #expect(byKey["risk_level"]?.model == nil)

        #expect(byKey["substances"]?.value == .multiple(["ALCOHOL"]))
        #expect(byKey["substances"]?.rejectReason == .negatedAnswer)
        #expect(byKey["risk_narrative"]?.value
            == .single("Client described passive thoughts that it would be easier not to wake up."))

        let asked = client.requests.compactMap(ScriptedClient.key(of:))
        #expect(asked == ["case_number", "pronouns", "gender_identity"] + (1...9).map { "phq9_\($0)" }
            + ["gad7_1", "substances", "risk_narrative"])
        #expect(!asked.contains("risk_level"), "clinician_only never reaches the model")
        #expect(!asked.contains("phq9_score") && !asked.contains("session_date") && !asked.contains("ghost"))
        #expect(client.requests.allSatisfy { $0.responseFormat?["type"] == "json_schema" })

        let requested = results.filter { $0.model != nil }
        #expect(requested.count == asked.count)
        #expect(requested.allSatisfy { $0.model == "test-model@sha256:abc" && $0.ms == 10 })
        #expect(requested.first?.prefillTokens == 4000)
        #expect(requested.dropFirst().allSatisfy { $0.prefillTokens == 30 })

        let prefixes = Set(client.requests.map { $0.messages[0].content })
        #expect(prefixes.count == 1, "one shared prefix for every request")
    }

    @Test func concurrencyKeepsProfileOrderAndResults() async throws {
        let serial = try await run(concurrency: 1).results
        let parallel = try await run(concurrency: 4).results
        func strip(_ r: [FieldResult]) -> [FieldResult] {
            r.map { var x = $0; x.prefillTokens = nil; return x }
        }
        #expect(strip(serial) == strip(parallel))
    }
}
