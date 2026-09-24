import Testing
@testable import ScribeskiCore

@Suite struct TranscriptTextTests {
    let sample = """
    # session_date: 2026-09-17
    # started_at: 2026-09-17T14:00:00-07:00

    [00:04] WORKER: Hi, can you hear me okay?
    [00:07] CLIENT: Yeah — I can hear you.
    [1:02:03] CLIENT: Still here.
    """

    @Test func parsesHeaderAndSegments() throws {
        let (t, meta) = try TranscriptText.parse(sample, sessionId: "T")
        #expect(meta["session_date"] == "2026-09-17")
        #expect(t.startedAt == "2026-09-17T14:00:00-07:00")
        #expect(t.segments.map(\.id) == ["s0001", "s0002", "s0003"])
        #expect(t.segments[0].speaker == .worker)
        #expect(t.segments[0].end == 7)
        #expect(t.segments[2].start == 3723)
        #expect(t.segments[1].text == "Yeah — I can hear you.")
    }

    @Test func rendersPromptLines() throws {
        let (t, _) = try TranscriptText.parse(sample, sessionId: "T")
        let lines = TranscriptText.renderForPrompt(t).split(separator: "\n")
        #expect(lines[0] == "[00:04] s0001 WORKER: Hi, can you hear me okay?")
        #expect(lines[2] == "[62:03] s0003 CLIENT: Still here.")
    }

    @Test(arguments: [
        "[00:04] NARRATOR: hi",
        "00:04 WORKER: hi",
        "[00:61] WORKER: hi",
        "[00:10] WORKER: a\n[00:05] CLIENT: b",
    ])
    func rejectsMalformedInput(_ text: String) {
        #expect(throws: TranscriptText.ParseError.self) {
            try TranscriptText.parse(text, sessionId: "T")
        }
    }
}
