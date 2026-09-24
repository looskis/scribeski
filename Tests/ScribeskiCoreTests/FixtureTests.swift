import Foundation
import Testing
@testable import ScribeskiCore

/// The checked-in fixtures parse, and hold the invariants other tests rely on.
@Suite struct FixtureTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    @Test func sampleSessionParses() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("sample-session.txt"), encoding: .utf8)
        let (t, meta) = try TranscriptText.parse(text, sessionId: "sample-session")
        #expect(meta["session_date"] == "2026-09-17")
        #expect(t.segments.count > 300)
        #expect(Set(t.segments.map(\.speaker)) == [.worker, .client])
        let last = try #require(t.segments.last)
        #expect((40 * 60...46 * 60).contains(last.start))
    }

    @Test func expectedExtractionDerivesPHQ9FromItems() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("expected-extraction.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mustFill = try #require(json["must_fill"] as? [String: Any])
        let items = (1...9).compactMap { mustFill["phq9_\($0)"] as? String }.compactMap(Int.init)
        #expect(items.count == 9)
        let derived = try #require(json["derived"] as? [String: Any])
        #expect(derived["phq9_score"] as? String == String(items.reduce(0, +)))
        #expect(mustFill["phq9_score"] == nil, "scores are derived, never extracted")
    }

    /// The page bundle's golden profile decodes with the Swift contract: the TS and Swift
    /// sides of FormProfile can't drift apart silently.
    @Test func goldenProfileDecodes() throws {
        let url = Self.root.deletingLastPathComponent()
            .appendingPathComponent("page/test/golden/mock-ehr.profile.json")
        let profile = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: url))
        #expect(profile.fields.count == 107)
        #expect(profile.fields.filter { $0.frame == ["#risk_frame"] }.count == 10)
        #expect(profile.fields.filter(\.computed).count == 4)
        #expect(profile.fingerprint.hasPrefix("sha256:"))
    }
}
