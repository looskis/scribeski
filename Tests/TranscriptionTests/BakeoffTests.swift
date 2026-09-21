import Testing
@testable import Transcription

/// The bake-off's entity scoring (P2.8): the words a note depends on, matched loosely enough
/// that "three" and "3" agree, strictly enough that a wrong date or name counts.
@Suite struct BakeoffEntities {
    @Test func picksNumbersDatesNamesAndAcronyms() {
        let e = ASRBakeoff.entities("My name is Kim. I saw Dr. Okafor on Tuesday, the 14th, about SNAP and 50 mg of sertraline. Mateo gets out at three.")
        #expect(e.contains("okafor"))
        #expect(e.contains("tuesday"))
        #expect(e.contains("14th"))
        #expect(e.contains("snap"))
        #expect(e.contains("50"))
        #expect(e.contains("mateo") == false, "sentence-initial: can't tell a name from a capital")
        #expect(e.contains("3"), "spelled numbers normalize to digits")
        #expect(!e.contains("i"))
    }

    @Test func entityErrorRateCountsWhatTheHypothesisMissed() {
        let ref = ASRBakeoff.entities("We meet on Tuesday at 3 with Dr. Okafor.")
        #expect(ASRBakeoff.entityErrorRate(reference: ref, hypothesis: "we meet on tuesday at three with doctor okafor") == 0)
        let missed = ASRBakeoff.entityErrorRate(reference: ref, hypothesis: "we meet on thursday at three with doctor o'connor")
        #expect(abs(missed - 2.0 / Double(ref.count)) < 1e-9)
        #expect(ASRBakeoff.entityErrorRate(reference: [], hypothesis: "anything") == 0)
    }
}
