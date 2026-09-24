import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

@Suite struct ScorerTests {
    let expected: JSONValue

    init() throws { expected = try Fixtures.expected() }

    /// A result set that matches expected-extraction.json exactly.
    func perfectResults() -> [FieldResult] {
        var results: [FieldResult] = []
        func add(_ key: String, _ status: FieldResult.Status, _ value: FieldValue?) {
            results.append(FieldResult(key: key, status: status, value: value,
                                       evidence: value == nil ? [] : [.init(segment: "s0001", quote: "x")]))
        }
        for (key, v) in expected["must_fill"]?.objectValue?.entries ?? [] {
            add(key, .filled, v.stringValue.map(FieldValue.single) ?? .multiple(v.arrayValue!.compactMap(\.stringValue)))
        }
        for (key, _) in expected["acceptable"]?.objectValue?.entries ?? [] { add(key, .insufficientEvidence, nil) }
        for (key, spec) in expected["checkbox_constraints"]?.objectValue?.entries ?? [] {
            add(key, .filled, .multiple(spec["must_include"]!.arrayValue!.compactMap(\.stringValue)))
        }
        for (key, spec) in expected["text_match"]?.objectValue?.entries ?? [] {
            let text = spec["value"]!.stringValue ?? spec["value"]!.arrayValue!.compactMap(\.stringValue).joined(separator: " ")
            add(key, .filled, .single(text))
        }
        for (key, v) in expected["derived"]?.objectValue?.entries ?? [] {
            if let s = v.stringValue { add(key, .derived, .single(s)) } else { add(key, .insufficientEvidence, nil) }
        }
        for key in expected["must_leave_blank"]?.arrayValue?.compactMap(\.stringValue) ?? []
        where !results.contains(where: { $0.key == key }) {
            add(key, .insufficientEvidence, nil)
        }
        for key in expected["clinician_only"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            add(key, .clinicianOnly, nil)
        }
        for (key, _) in expected["narrative"]?.objectValue?.entries ?? [] {
            add(key, .filled, .single("A cited sentence."))
        }
        // Prefill: request 1 pays the prefix, the rest hit the cache.
        for i in results.indices where results[i].status == .filled || results[i].status == .insufficientEvidence {
            results[i].prefillTokens = results.firstIndex(where: { $0.prefillTokens != nil }) == nil ? 9000 : 25
            results[i].ms = 300
        }
        return results
    }

    @Test func perfectResultsPassEveryGate() throws {
        let report = Scorer.score(results: perfectResults(), expected: expected)
        #expect(report.mustFillAccuracy == 1.0, "\(report.accuracyChecks.filter { !$0.pass })")
        #expect(report.mustFillTotal == 37 + 9 + 6 + 17 + 2)
        #expect(report.blankViolations.isEmpty, "\(report.blankViolations)")
        #expect(report.riskErrors.isEmpty)
        #expect(report.cache.pass == true)
        #expect(report.gates.allSatisfy { $0.pass == true })
        #expect(report.passed)
        #expect(report.traps.count == 16)
        #expect(!report.traps.contains { $0.status == .fail }, "\(report.traps.filter { $0.status == .fail })")
        let substances = try #require(report.traps.first { $0.id == "speaker_attribution_substances" })
        #expect(substances.status == .pass)
        let faith = try #require(report.traps.first { $0.id == "faith_mentioned_declined" })
        #expect(faith.manualFields == ["client_strengths"])

        let md = report.markdown()
        #expect(md.contains("**Result: PASS**"))
        #expect(md.contains("| speaker_attribution_substances | pass |"))
    }

    @Test func blankViolationAndRiskErrorFailGates() throws {
        var results = perfectResults()
        let g = try #require(results.firstIndex { $0.key == "gender_identity" })
        results[g] = FieldResult(key: "gender_identity", status: .filled, value: .single("WOMAN"))
        let p = try #require(results.firstIndex { $0.key == "si_plan" })
        results[p] = FieldResult(key: "si_plan", status: .filled, value: .single("YES"))
        results.append(FieldResult(key: "si_means", status: .rejected, value: .single("NO_ACCESS"),
                                   rejectReason: .speakerMismatch))
        results.removeAll { $0.key == "si_means" && $0.status == .insufficientEvidence }

        let report = Scorer.score(results: results, expected: expected)
        #expect(report.blankViolations.map(\.key) == ["gender_identity"])
        #expect(report.riskErrors.map(\.key) == ["si_plan"], "a rejected value is blank, so si_means is fine")
        #expect(report.rejections == ["speaker_mismatch": 1])
        #expect(!report.passed)
        #expect(report.gates[0].pass == false)
        #expect(report.gates[1].pass == false)
        #expect(report.gates[2].pass == true, "one miss out of 71 is still ≥ 90%")
        #expect(report.traps.first { $0.id == "gender_not_asked" }?.status == .fail)
        #expect(report.traps.first { $0.id == "gender_not_asked" }?.failedFields == ["gender_identity"])
        #expect(report.markdown().contains("**Result: FAIL**"))
    }

    @Test func clinicianOnlyMustSurface() throws {
        var results = perfectResults()
        let i = try #require(results.firstIndex { $0.key == "risk_level" })
        results[i] = FieldResult(key: "risk_level", status: .filled, value: .single("LOW"))
        let report = Scorer.score(results: results, expected: expected)
        #expect(report.blankViolations.map(\.key) == ["risk_level"])
        #expect(report.traps.first { $0.id == "risk_level_never_stated" }?.status == .fail)
    }

    @Test func textMatchNormalization() {
        #expect(Scorer.normalizeText("(510) 555-0193", mode: "digits") == "5105550193")
        #expect(Scorer.normalizeText("March 3rd, 1989", mode: "date") == "1989-03-03")
        #expect(Scorer.normalizeText("3/3/1989", mode: "date") == "1989-03-03")
        #expect(Scorer.normalizeText("2026-09-24", mode: "date") == "2026-09-24")
        #expect(Scorer.normalizeText("2210 Alder St., Apt. 4", mode: "case_insensitive") == "2210 alder st apt 4")
    }

    @Test func cacheAssertion() {
        // One slot: request 1 = 10 000 tokens; hits cost only the field suffix.
        let good = [10_000] + Array(repeating: 400, count: 99)
        #expect(Scorer.cacheCheck(prefill: good).pass == true)
        // One request re-processed the prefix.
        let miss = [10_000] + Array(repeating: 400, count: 50) + [10_300] + Array(repeating: 400, count: 48)
        let m = Scorer.cacheCheck(prefill: miss)
        #expect(m.pass == false)
        #expect(m.misses == 1)
        // Short transcript (corpus session 05): suffix is ~10% of the prefix, still all hits.
        let short = [2_400] + Array(repeating: 260, count: 90)
        #expect(Scorer.cacheCheck(prefill: short).pass == true)
        // Four slots: the first four each pay the full prefix.
        let parallel = Array(repeating: 10_000, count: 4) + Array(repeating: 400, count: 96)
        #expect(Scorer.cacheCheck(prefill: parallel, slots: 1).pass == false)
        #expect(Scorer.cacheCheck(prefill: parallel, slots: 4).pass == true)
        #expect(Scorer.cacheCheck(prefill: []).pass == nil)
        let r = Scorer.cacheCheck(prefill: [1000, 10, 30])
        #expect(r.restRatio == 0.02)
        #expect(r.totalPrefill == 1040)
    }

    @Test(arguments: [("four, five hours", "45"), ("maybe five", "5"), ("twenty-one days", "21"),
                      ("4-5 hours", "45"), ("Someone said none", "")])
    func spelledNumbersCompareAsDigits(_ text: String, _ digits: String) {
        #expect(Scorer.normalizeText(text, mode: "digits") == digits)
    }
}
