import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

func ev(_ s: Transcript.Segment, _ quote: String? = nil) -> JSONValue {
    .obj(["segment": .string(s.id), "quote": .string(quote ?? s.text)])
}

func ev(_ id: String, _ quote: String) -> JSONValue {
    .obj(["segment": .string(id), "quote": .string(quote)])
}

func filled(_ value: String, _ evidence: [JSONValue]) -> JSONValue {
    .obj(["status": "filled", "evidence": .array(evidence), "value": .string(value)])
}

func selections(_ items: [(String, [JSONValue])]) -> JSONValue {
    .obj(["status": "filled", "selections": .array(items.map {
        .obj(["value": .string($0.0), "evidence": .array($0.1)])
    })])
}

func sentences(_ items: [(String, [JSONValue])]) -> JSONValue {
    .obj(["status": "filled", "sentences": .array(items.map {
        .obj(["text": .string($0.0), "evidence": .array($0.1)])
    })])
}

@Suite struct VerifierTests {
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

    func verify(_ key: String, _ answer: JSONValue, speaker: FormMapping.EvidenceSpeaker? = nil,
                maxChars: Int? = nil) throws -> FieldResult {
        let field = try Fixtures.field(profile, key)
        var m = try #require(mapping.fields[key])
        if let speaker { m.evidenceSpeaker = speaker }
        if let maxChars { m.maxChars = maxChars }
        return verifier.verify(field: field, mapping: m, answer: answer)
    }

    // MARK: Rule 1: quotes

    @Test func verbatimQuoteFills() throws {
        let s = try Fixtures.segment(t, "She/her.", speaker: .client)
        let r = try verify("pronouns", filled("SHE_HER", [ev(s)]))
        #expect(r.status == .filled)
        #expect(r.value == .single("SHE_HER"))
        #expect(r.evidence == [.init(segment: s.id, quote: "She/her.")])
    }

    @Test func quoteMatchIgnoresCaseQuotesDashesPunctuation() throws {
        let s = try Fixtures.segment(t, "English is fine for me", speaker: .client)
        let q = "english is fine for me - my mom only speaks Spanish, but it’s just me"
        #expect(try verify("language_combo", filled("ENGLISH", [ev(s, q)])).status == .filled)
    }

    @Test func alteredQuoteIsRejected() throws {
        let s = try Fixtures.segment(t, "She/her.", speaker: .client)
        let r = try verify("pronouns", filled("SHE_HER", [ev(s, "She/her, and they/them.")]))
        #expect(r.status == .rejected)
        #expect(r.rejectReason == .quoteNotFound)
    }

    @Test func quoteMatchIsOnWordBoundaries() throws {
        let s = try Fixtures.segment(t, "No. Nothing.", speaker: .client)
        let r = try verify("hi_ideation", filled("NONE", [ev(s, "Nothin")]))
        #expect(r.rejectReason == .quoteNotFound)
    }

    @Test func quoteFromAnotherSegmentIsRejected() throws {
        let other = try Fixtures.segment(t, "No. None of that.", speaker: .client)
        let wrong = t.segments[t.segments.firstIndex(of: other)! - 3]
        let r = try verify("hi_ideation", filled("NONE", [ev(wrong, "No. None of that.")]))
        #expect(r.rejectReason == .quoteNotFound)
    }

    @Test func unknownSegmentIsRejected() throws {
        let r = try verify("pronouns", filled("SHE_HER", [ev("s9999", "She/her.")]))
        #expect(r.status == .rejected)
        #expect(r.rejectReason == .segmentNotFound)
    }

    @Test func quoteMaySpanConsecutiveCitedSegmentsOfOneSpeaker() throws {
        let a = try Fixtures.segment(t, "Daniela Reyes.", speaker: .client)
        let b = try Fixtures.segment(t, "But everyone calls me Dani.", speaker: .client)
        #expect(t.segments.firstIndex(of: b)! == t.segments.firstIndex(of: a)! + 1)
        let quote = "Daniela Reyes. But everyone calls me Dani."

        let both = try verify("client_preferred_name", filled("Dani", [ev(a, quote), ev(b, "everyone calls me Dani")]))
        #expect(both.status == .filled)

        let onlyFirst = try verify("client_preferred_name", filled("Dani", [ev(a, quote)]))
        #expect(onlyFirst.rejectReason == .quoteNotFound, "the second segment must be cited too")
    }

    @Test func spanDoesNotCrossSpeakers() throws {
        let q = try Fixtures.segment(t, "Any cannabis? Opioids, like pain pills?", speaker: .worker)
        let a = try Fixtures.segment(t, "No. None of that.", speaker: .client)
        let r = try verify("hi_ideation", filled("NONE", [ev(q, "like pain pills? No. None of that."), ev(a)]),
                           speaker: .any)
        #expect(r.rejectReason == .quoteNotFound)
    }

    // MARK: Rule 2: speaker

    @Test func workerOnlyEvidenceFailsClientField() throws {
        let w = try Fixtures.segment(t, "have you had any alcohol?", speaker: .worker)
        let r = try verify("tobacco_use", filled("CURRENT", [ev(w)]))
        #expect(r.status == .rejected)
        #expect(r.rejectReason == .speakerMismatch)
    }

    @Test func workerOnlyMetadataPassesWithAnySpeaker() throws {
        let w = try Fixtures.segment(t, "let's do that one next week", speaker: .worker)
        let answer = filled("DEFERRED", [ev(w, "Normally there's another questionnaire I do, about anxiety. But we're running long — let's do that one next week.")])
        #expect(try verify("gad7_status", answer).status == .filled)
        #expect(mapping.fields["gad7_status"]?.evidenceSpeaker == .any)
        #expect(try verify("gad7_status", answer, speaker: .client).rejectReason == .speakerMismatch)
    }

    // MARK: Rule 3: negated short answers

    /// The trap from sample-session.txt: the worker names cannabis and opioids, the client
    /// says "No. None of that." Citing the question *and* the client's answer satisfies the
    /// speaker rule, so only the negation rule catches it.
    @Test func cannabisTrap() throws {
        let question = try Fixtures.segment(t, "Any cannabis? Opioids, like pain pills?", speaker: .worker)
        let denial = try Fixtures.segment(t, "No. None of that.", speaker: .client)
        let alcohol = try Fixtures.segment(t, "A couple beers", speaker: .client)
        #expect(question.id == "s0314")
        #expect(denial.id == "s0315")

        let r = try verify("substances", selections([
            ("ALCOHOL", [ev(alcohol)]),
            ("CANNABIS", [ev(question, "Any cannabis?"), ev(denial)]),
            ("OPIOIDS", [ev(question, "Opioids, like pain pills?"), ev(denial)]),
        ]))
        #expect(r.status == .filled)
        #expect(r.value == .multiple(["ALCOHOL"]))
        #expect(r.rejectReason == .negatedAnswer)
        #expect(r.evidence == [.init(segment: alcohol.id, quote: alcohol.text)])

        let only = try verify("substances", selections([("CANNABIS", [ev(question, "Any cannabis?"), ev(denial)])]))
        #expect(only.status == .insufficientEvidence)
        #expect(only.value == nil)
        #expect(only.rejectReason == .negatedAnswer)
    }

    @Test func negationSupportsNegativeValueButNotPositive() throws {
        let s = try Fixtures.segment(t, "No, never.", speaker: .client)
        let q = t.segments[t.segments.firstIndex(of: s)! - 1]
        #expect(try verify("hi_ideation", filled("NONE", [ev(q), ev(s)])).status == .filled)
        let bad = try verify("hi_ideation", filled("ACTIVE", [ev(q), ev(s)]))
        #expect(bad.status == .rejected)
        #expect(bad.rejectReason == .negatedAnswer)
    }

    @Test func negatedAnswerAppliesToRadioScales() throws {
        // "Not at all" is the negative PHQ-9 option; "No." can't support "Nearly every day".
        let s = try Fixtures.segment(t, "No. Nothing.", speaker: .client)
        #expect(try verify("phq9_1", filled("3", [ev(s)])).rejectReason == .negatedAnswer)
        // Outside a registered questionnaire, a short "No." must come with its question.
        let q = t.segments[t.segments.firstIndex(of: s)! - 1]
        #expect(try verify("phq9_1", filled("0", [ev(s)])).rejectReason == .missingQuestionContext)
        #expect(try verify("phq9_1", filled("0", [ev(q), ev(s)])).status == .filled)
    }

    // MARK: Rule 4: bare affirmations

    @Test func bareAffirmationNeedsTheQuestion() throws {
        let yes = try Fixtures.segment(t, "Yes. Yeah, that's fine.", speaker: .client)
        let question = try Fixtures.segment(t, "Do I have your verbal consent", speaker: .worker)
        #expect(t.segments.firstIndex(of: question)! == t.segments.firstIndex(of: yes)! - 1)

        let alone = try verify("consent_telehealth", filled("VERBAL", [ev(yes)]))
        #expect(alone.status == .rejected)
        #expect(alone.rejectReason == .missingQuestionContext)

        let withQuestion = try verify("consent_telehealth", filled("VERBAL", [ev(question), ev(yes)]))
        #expect(withQuestion.status == .filled)

        let farQuestion = try Fixtures.segment(t, "is it okay if I leave a voicemail", speaker: .worker)
        let wrongQuestion = try verify("consent_telehealth", filled("VERBAL", [ev(farQuestion), ev(yes)]))
        #expect(wrongQuestion.rejectReason == .missingQuestionContext)
    }

    @Test func affirmationWithContentIsNotBare() {
        #expect(TextNormalizer.isBareAffirmation("Yeah."))
        #expect(TextNormalizer.isBareAffirmation("Yes. Yeah, that's fine."))
        #expect(TextNormalizer.isBareAffirmation("Mm-hmm."))
        #expect(!TextNormalizer.isBareAffirmation("Yes, Fairhaven. 92503."))
        #expect(!TextNormalizer.isBareAffirmation("Yeah. AB-114322. That's it."))
        #expect(TextNormalizer.isNegatedShortAnswer("No. None of that."))
        #expect(TextNormalizer.isNegatedShortAnswer("Um, nope."))
        #expect(!TextNormalizer.isNegatedShortAnswer("No. I can't really afford more than that anyway, honestly."))
        #expect(!TextNormalizer.isNegatedShortAnswer("Nothing like what you'd think, I drink"
            + " a couple beers most weekends"))
    }

    // MARK: Checkbox groups and narratives

    @Test func checkboxDropsOnlyFailingOptions() throws {
        let food = try Fixtures.segment(t, "Fairhaven Community Food Bank", speaker: .worker)
        let psych = try Fixtures.segment(t, "seeing a psychiatrist would help", speaker: .worker)
        let r = try verify("referrals_made", selections([
            ("FOOD_BANK", [ev(food, "I'm going to refer you to the Fairhaven Community Food Bank.")]),
            ("PSYCHIATRY", [ev(psych, "I'm referring you to psychiatry.")]),
            ("FOOD_BANK", [ev(food, "First, food.")]),
        ]))
        #expect(r.status == .filled)
        #expect(r.value == .multiple(["FOOD_BANK"]))
        #expect(r.rejectReason == .quoteNotFound)

        let none = try verify("referrals_made", selections([("PSYCHIATRY", [ev(psych, "I'm referring you to psychiatry.")])]))
        #expect(none.status == .insufficientEvidence)
        #expect(none.rejectReason == .quoteNotFound)
    }

    @Test func noneOptionIsDroppedWhenAPositiveOptionSurvives() throws {
        let alcohol = try Fixtures.segment(t, "A couple beers", speaker: .client)
        let nothing = try Fixtures.segment(t, "No. Nothing.", speaker: .client)
        let r = try verify("substances", selections([("NONE_REPORTED", [ev(nothing)]), ("ALCOHOL", [ev(alcohol)])]))
        #expect(r.value == .multiple(["ALCOHOL"]))
        // NONE_REPORTED went anyway: its bare "No. Nothing." didn't cite the question.
        #expect(r.rejectReason == .missingQuestionContext)
    }

    @Test func narrativeDropsUncitedSentencesAndCapsLength() throws {
        let si = try Fixtures.segment(t, "easier if I just didn't wake up", speaker: .client)
        let plan = try Fixtures.segment(t, "No. No plan. Nothing like that.", speaker: .client)
        let answer = sentences([
            ("Client reported passive thoughts that it would be easier not to wake up.", [ev(si, "it'd be easier if I just didn't wake up")]),
            ("Client has access to firearms.", [ev(plan, "I have a gun")]),
            ("Client denied a plan.", [ev(t.segments[t.segments.firstIndex(of: plan)! - 1]), ev(plan, "No plan.")]),
        ])
        let r = try verify("risk_narrative", answer)
        #expect(r.status == .filled)
        #expect(r.value == .single("Client reported passive thoughts that it would be easier not to wake up. Client denied a plan."))
        #expect(r.rejectReason == .quoteNotFound)
        #expect(r.evidence.count == 3)

        let capped = try verify("risk_narrative", answer, maxChars: 90)
        #expect(capped.value == .single("Client reported passive thoughts that it would be easier not to wake up."))

        let nothing = try verify("risk_narrative", sentences([("Client has access to firearms.", [ev(plan, "I have a gun")])]))
        #expect(nothing.status == .insufficientEvidence)
        #expect(nothing.rejectReason == .quoteNotFound)
    }

    // MARK: Shape

    @Test func invalidOptionAndDateAreRejected() throws {
        let s = try Fixtures.segment(t, "She/her.", speaker: .client)
        #expect(try verify("pronouns", filled("SHE", [ev(s)])).rejectReason == .invalidOption)
        let d = try Fixtures.segment(t, "March 3rd, 1989.", speaker: .client)
        #expect(try verify("client_dob", filled("1989-02-30", [ev(d)])).rejectReason == .invalidOption)
        #expect(try verify("client_dob", filled("1989-03-03", [ev(d)])).status == .filled)
    }

    @Test func insufficientAndMalformedOutput() throws {
        let field = try Fixtures.field(profile, "pronouns")
        let m = try #require(mapping.fields["pronouns"])
        let insufficient = verifier.verify(field: field, mapping: m,
                                           output: #"{"status":"insufficient_evidence","evidence":[],"value":null}"#)
        #expect(insufficient.status == .insufficientEvidence)
        #expect(insufficient.rejectReason == nil)
        #expect(verifier.verify(field: field, mapping: m, output: "SHE_HER").status == .rejected)
    }
}
