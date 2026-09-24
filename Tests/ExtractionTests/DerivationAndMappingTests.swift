import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

@Suite struct DerivationTests {
    let phq = (1...9).map { "phq9_\($0)" }
    let gad = (1...7).map { "gad7_\($0)" }

    func values(_ keys: [String], _ scores: [Int]) -> [String: FieldValue] {
        Dictionary(uniqueKeysWithValues: zip(keys, scores.map { .single(String($0)) }))
    }

    @Test func phq9FromSampleSession() {
        let v = values(phq, [2, 3, 3, 2, 1, 2, 2, 2, 1])
        #expect(Derivations.compute("phq9_total", inputs: phq, values: v) == "18")
        #expect(Derivations.compute("phq9_band", inputs: phq, values: v) == "MODERATELY_SEVERE")
        // A band may also be derived from the total.
        #expect(Derivations.compute("phq9_band", inputs: ["phq9_score"], values: ["phq9_score": .single("18")])
            == "MODERATELY_SEVERE")
    }

    @Test func bandsAtBoundaries() {
        let phqBands: [(Int, String)] = [(0, "MINIMAL"), (4, "MINIMAL"), (5, "MILD"), (9, "MILD"), (10, "MODERATE"),
                                         (14, "MODERATE"), (15, "MODERATELY_SEVERE"), (19, "MODERATELY_SEVERE"),
                                         (20, "SEVERE"), (27, "SEVERE")]
        for (n, band) in phqBands { #expect(Derivations.phq9Band(n) == band) }
        #expect(Derivations.phq9Band(28) == nil)
        let gadBands: [(Int, String)] = [(0, "MINIMAL"), (4, "MINIMAL"), (5, "MILD"), (9, "MILD"), (10, "MODERATE"),
                                         (14, "MODERATE"), (15, "SEVERE"), (21, "SEVERE")]
        for (n, band) in gadBands { #expect(Derivations.gad7Band(n) == band) }
        #expect(Derivations.gad7Band(22) == nil)
    }

    @Test func incompleteItemsDeriveNothing() {
        var v = values(phq, [2, 3, 3, 2, 1, 2, 2, 2, 1])
        v["phq9_9"] = nil
        #expect(Derivations.compute("phq9_total", inputs: phq, values: v) == nil)
        #expect(Derivations.compute("phq9_band", inputs: phq, values: v) == nil)
        #expect(Derivations.compute("gad7_total", inputs: gad, values: [:]) == nil)
        v["phq9_9"] = .single("")
        #expect(Derivations.compute("phq9_total", inputs: phq, values: v) == nil)
        #expect(Derivations.compute("no_such_function", inputs: ["phq9_1"], values: v) == nil)
    }

    @Test func gad7() {
        let v = values(gad, [3, 3, 2, 2, 2, 2, 1])
        #expect(Derivations.compute("gad7_total", inputs: gad, values: v) == "15")
        #expect(Derivations.compute("gad7_band", inputs: gad, values: v) == "SEVERE")
    }
}

/// `fixtures/mock-ehr/mapping.json` meets BUILD_PLAN P1.4's done-when.
@Suite struct MockEHRMappingTests {
    let mapping: FormMapping
    let profile: FormProfile

    init() throws {
        mapping = try Fixtures.mapping()
        profile = try Fixtures.mockEHRProfile()
    }

    @Test func coversEveryFieldInFIELDSmd() throws {
        #expect(profile.fields.count == 107)
        #expect(Set(profile.fields.map(\.key)) == Set(mapping.fields.keys))
        #expect(mapping.profileFingerprint == profile.fingerprint)
    }

    /// The profiler's golden file and FIELDS.md describe the same form (except the hash key
    /// the profiler gives the control that has no id or name).
    @Test func goldenProfileMatchesFIELDSmd() throws {
        let fromDoc = try Fixtures.fieldsMDProfile()
        let docKeys = Set(fromDoc.fields.map(\.key)).subtracting(["duration"])
        let goldenKeys = Set(profile.fields.map(\.key)).filter { !$0.hasPrefix("f_") }
        #expect(docKeys == goldenKeys)
    }

    @Test func doneWhen() throws {
        let f = mapping.fields
        #expect(f["risk_level"]?.mode == .clinicianOnly)
        for key in ["phq9_score", "phq9_severity", "gad7_score", "gad7_severity"] {
            let m = try #require(f[key])
            #expect(m.mode == .derived)
            let d = try #require(m.derive)
            #expect(Derivations.known.contains(d.function))
            #expect(d.inputs.count == (key.hasPrefix("phq9") ? 9 : 7))
        }
        #expect(f["substances"]?.evidenceSpeaker == .client)
        for key in ["mse_appearance", "mse_affect", "mse_thought_process", "mse_orientation", "mse_insight",
                    "mse_judgment", "level_of_care", "diagnosis_impression", "note_attestation", "supervisor_consult"] {
            #expect(f[key]?.mode == .clinicianOnly, "\(key)")
        }
        #expect(f["mse_mood"]?.mode == .discrete)
        for key in ["session_date", "f_f79934c38a", "session_modality"] { #expect(f[key]?.mode == .skip) }
    }

    @Test func agreesWithExpectedExtraction() throws {
        let expected = try Fixtures.expected()
        for key in expected["clinician_only"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            #expect(mapping.fields[key]?.mode == .clinicianOnly, "\(key)")
        }
        let trap = try #require(expected["traps"]?.arrayValue?.first { $0["id"] == "worker_only_metadata" })
        for key in trap["fields"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            #expect(mapping.fields[key]?.evidenceSpeaker == .any, "\(key) must accept worker statements")
        }
        for key in expected["not_scored"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            #expect(mapping.fields[key]?.mode == .skip)
        }
        for key in expected["narrative"]?.objectValue?.keys ?? [] {
            #expect(mapping.fields[key]?.mode == .narrative)
            #expect(mapping.fields[key]?.maxChars != nil)
        }
        let risk = expected["risk_fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for key in risk where profile.fields.first(where: { $0.key == key })?.options.isEmpty == false {
            let semantics = try #require(mapping.fields[key]?.optionSemantics, "\(key) needs option_semantics")
            let options = try Fixtures.field(profile, key).options.map(\.value)
            #expect(Set(semantics.keys) == Set(options), "\(key)")
        }
        for key in ["substances", "language_combo", "interpreter_needed", "gender_identity", "income_sources",
                    "support_system", "protective_factors", "referrals_made", "release_of_info", "legal_involvement",
                    "housing_status", "medication_adherence", "gad7_status"] {
            #expect(mapping.fields[key]?.optionSemantics?.isEmpty == false, "\(key)")
        }
    }

    @Test func optionSemanticsOnlyNameRealOptions() throws {
        for field in profile.fields {
            guard let semantics = mapping.fields[field.key]?.optionSemantics else { continue }
            let options = Set(field.options.map(\.value))
            #expect(Set(semantics.keys).isSubset(of: options), "\(field.key)")
        }
    }
}
