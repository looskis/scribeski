import Foundation
import Testing
@testable import ScribeskiCore

/// Every contract decodes the documented example, re-encodes, and decodes to an equal value.
@Suite struct ContractRoundTrip {
    func example(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Examples"))
        return try Data(contentsOf: url)
    }

    func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) throws -> T {
        let decoded = try JSONDecoder().decode(T.self, from: example(name))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let again = try JSONDecoder().decode(T.self, from: encoder.encode(decoded))
        #expect(again == decoded)
        return decoded
    }

    @Test func formProfile() throws {
        let p = try roundTrip(FormProfile.self, "form-profile")
        #expect(p.fields.count == 3)
        #expect(p.fields[1].frame == ["#risk_frame"])
        #expect(p.fields[2].labelSource == nil)
        #expect(p.fields[2].computed)
    }

    @Test func formMapping() throws {
        let m = try roundTrip(FormMapping.self, "form-mapping")
        #expect(m.fields["risk_level"]?.mode == .clinicianOnly)
        #expect(m.fields["phq9_score"]?.derive?.function == "phq9_total")
    }

    @Test func transcript() throws {
        let t = try roundTrip(Transcript.self, "transcript")
        #expect(t.retention == .days(30))
        #expect(t.tracks[.client]?.source == "tap:us.zoom.xos")
        #expect(t.gaps.first?.reason == .deviceRebuild)
    }

    @Test func fieldResults() throws {
        let r = try roundTrip([FieldResult].self, "field-results")
        #expect(r[1].value == .multiple(["CANNABIS"]))
        #expect(r[1].rejectReason == .speakerMismatch)
    }

    @Test func fillReports() throws {
        let r = try roundTrip([FillReport].self, "fill-reports")
        #expect(r[0].readBack == .single("AB-114322"))
        #expect(r[1].outcome == .reverted)
    }

    @Test func dictionaryKeyedBySpeakerEncodesAsObject() throws {
        let t = try JSONDecoder().decode(Transcript.self, from: example("transcript"))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        #expect(json["tracks"] is [String: Any])
    }
}

@Suite struct SchemaVersioning {
    @Test func wrongSchemaIsRejected() {
        let json = #"{"schema":"scribeski.form-mapping/2","profile_fingerprint":"x","fields":{}}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FormMapping.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["none", "until_confirm", "days:7"])
    func retentionRoundTrips(_ raw: String) {
        #expect(Retention(rawValue: raw)?.rawValue == raw)
    }

    @Test(arguments: ["", "days:", "days:0", "days:-3", "forever"])
    func invalidRetentionIsRejected(_ raw: String) {
        #expect(Retention(rawValue: raw) == nil)
    }
}
