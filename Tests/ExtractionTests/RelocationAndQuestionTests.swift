import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

/// Cases taken from the first real Gemma 4 26B-A4B run (eval/runs/sample-gemma26b-1.md): the
/// model quoted verbatim but misnumbered segments, and answered one PHQ-9 item with another's.
@Suite struct RelocationAndQuestionTests {
    let t: Transcript
    let profile: FormProfile
    let mapping: FormMapping
    let verifier: Verifier

    init() throws {
        t = try Fixtures.sampleTranscript()
        profile = try Fixtures.mockEHRProfile()
        mapping = try Fixtures.mapping()
        let questions = Dictionary(uniqueKeysWithValues: profile.fields
            .filter { $0.kind == .radioGroup && $0.label.split(separator: " ").count >= 5 }
            .map { ($0.key, $0.label) })
        verifier = Verifier(transcript: t, questions: questions)
    }

    func verify(_ key: String, _ answer: JSONValue) throws -> FieldResult {
        verifier.verify(field: try Fixtures.field(profile, key), mapping: try #require(mapping.fields[key]), answer: answer)
    }

    func neighbour(of s: Transcript.Segment, _ offset: Int) throws -> String {
        let i = try #require(t.segments.firstIndex(of: s))
        return t.segments[i + offset].id
    }

    @Test func uniqueLongQuoteWithWrongIdIsRelocated() throws {
        let s = try Fixtures.segment(t, "Several days. A few times. Mostly at night", speaker: .client)
        let wrong = try neighbour(of: s, -1)
        let r = try verify("si_frequency", filled("SEVERAL_DAYS", [ev(wrong, s.text)]))
        #expect(r.status == .filled)
        #expect(r.evidence.first?.segment == s.id)
    }

    @Test func nonexistentIdIsRelocatedToo() throws {
        let s = try Fixtures.segment(t, "Several days. A few times. Mostly at night", speaker: .client)
        let r = try verify("si_frequency", filled("SEVERAL_DAYS", [ev("s0430", s.text)]))
        #expect(r.status == .filled)
        #expect(r.evidence.first?.segment == s.id)
    }

    @Test func shortRepeatedQuoteIsNeverRelocated() throws {
        // "No, never." occurs more than once; moving it could attach it to the wrong question.
        let hits = t.segments.filter { TextNormalizer.normalize($0.text).contains("no never") }
        #expect(hits.count >= 2)
        let r = try verify("hi_ideation", filled("NONE", [ev("s0430", "No, never.")]))
        #expect(r.status == .rejected)
    }

    @Test func answerCitedUnderItsQuestionIdMovesToTheAnswer() throws {
        // Run 2 cited hi_ideation as {s0215 (the worker's question), "No, never."}.
        let question = try Fixtures.segment(t, "hurting someone else", speaker: .worker)
        let i = try #require(t.segments.firstIndex(of: question))
        let answer = t.segments[i + 1]
        #expect(answer.speaker == .client)
        let r = try verify("hi_ideation", filled("NONE", [ev(question.id, answer.text), ev(question)]))
        #expect(r.status == .filled)
        #expect(r.evidence.first?.segment == answer.id)
        // Without its question, a bare "No, never." no longer stands (corpus run 1:
        // session 06 borrowed the suicide question's "No. Never." for hi_ideation).
        let bare = try verify("hi_ideation", filled("NONE", [ev(question.id, answer.text)]))
        #expect(bare.rejectReason == .missingQuestionContext)
    }

    @Test func answerIsOnlyMovedForwardFromItsOwnQuestion() throws {
        // Cited under the worker line AFTER the answer: not "question then answer", so no move.
        let question = try Fixtures.segment(t, "hurting someone else", speaker: .worker)
        let i = try #require(t.segments.firstIndex(of: question))
        let later = try #require(t.segments[(i + 2)...].first { $0.speaker == .worker })
        let r = try verify("hi_ideation", filled("NONE", [ev(later.id, t.segments[i + 1].text)]))
        #expect(r.status == .rejected)
    }

    // Known limit: a bare "No, never." that really exists (here, the answer to the prior-attempts
    // question) verifies for hi_ideation, because nothing structural ties a short answer to
    // which question it answered outside questionnaire items. That's the entailment pass's job
    // (DESIGN §4, Apple Foundation Models), not the verifier's.

    @Test func relocationStillAppliesSpeakerRules() throws {
        // A worker line relocated by its quote is still a worker line.
        let q = try Fixtures.segment(t, "Any cannabis? Opioids, like pain pills?", speaker: .worker)
        let r = try verify("substances", selections([("CANNABIS", [ev("s0001", q.text)])]))
        #expect(r.status == .insufficientEvidence)
        #expect(r.rejectReason == .speakerMismatch)
    }

    @Test func itemWhoseQuestionWasNeverReadIsRejected() throws {
        // Corpus session 04: PHQ-9 never given, yet "I sleep maybe five" became phq9_3 = 2.
        let pronouns = try Fixtures.segment(t, "She/her.", speaker: .client)
        let r = try verify("phq9_3", filled("2", [ev(pronouns)]))
        #expect(r.rejectReason == .questionNotAsked)
    }

    @Test func answerToAnotherItemIsQuestionMismatch() throws {
        // Run 1 answered phq9_2 with the client's answer to item 6.
        let answer6 = try Fixtures.segment(t, "More than half the days. Like, I feel like I let him down", speaker: .client)
        let wrong = try verify("phq9_2", filled("2", [ev(answer6)]))
        #expect(wrong.status == .rejected)
        #expect(wrong.rejectReason == .questionMismatch)
        let right = try verify("phq9_6", filled("2", [ev(answer6)]))
        #expect(right.status == .filled)
    }

    @Test(arguments: ["s0330 CLIENT: Um, sertraline.", "[33:10] s0330 CLIENT: Um, sertraline.", "CLIENT: Um, sertraline.", "Um, sertraline."])
    func copiedLinePrefixIsStripped(_ quote: String) {
        #expect(Verifier.stripLinePrefix(quote) == "Um, sertraline.")
    }

    @Test func onlyALeadingSpeakerLabelIsStripped() {
        #expect(Verifier.stripLinePrefix("I told the worker: no") == "I told the worker: no")
        #expect(Verifier.stripLinePrefix("She said client: fine") == "She said client: fine")
    }
}
