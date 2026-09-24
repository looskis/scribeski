import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

/// A fixed-answer `LLMClient` that records requests.
final class RecordingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ChatRequest] = []
    let answer: @Sendable (ChatRequest) -> String

    init(answer: @escaping @Sendable (ChatRequest) -> String) { self.answer = answer }

    var requests: [ChatRequest] { lock.withLock { _requests } }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        lock.withLock { _requests.append(request) }
        return ChatResponse(content: answer(request))
    }
}

enum MapFixtures {
    static func field(_ key: String, _ kind: FormProfile.Kind, _ label: String, help: String? = nil,
                      options: [(String, String)] = [], computed: Bool = false) -> FormProfile.Field {
        FormProfile.Field(key: key, step: "step-1", frame: ["#inner"], kind: kind, label: label,
                          labelSource: kind == .hidden ? nil : .labelFor, help: help,
                          options: options.map { FormProfile.Option(value: $0.0, label: $0.1) },
                          selectors: ["#\(key)"], write: kind == .hidden ? .never : .nativeSetter,
                          computed: computed)
    }

    static func profile(_ fields: [FormProfile.Field]) -> FormProfile {
        FormProfile(origin: "https://ehr.agency.example", pathPattern: "/clients/*/note",
                    fingerprint: "sha256:abc123", steps: [], fields: fields)
    }

    static func withField(_ label: String = "Label", help: String? = nil,
                          options: [(String, String)] = []) -> EgressPayload {
        EgressPayload.build(from: profile([field("planted", options.isEmpty ? .text : .select, label,
                                                 help: help, options: options)]))
    }

    static let smallProfile = profile([
        field("pronouns", .select, "Pronouns", options: [("SHE_HER", "she/her"), ("HE_HIM", "he/him")]),
        field("presenting_problem", .textarea, "Presenting problem"),
        field("risk_level", .select, "Overall risk level", options: [("LOW", "Low"), ("HIGH", "High")]),
        field("phq9_1", .radioGroup, "Little interest", options: [("0", "Not at all"), ("1", "Several days")]),
        field("phq9_2", .radioGroup, "Feeling down", options: [("0", "Not at all"), ("1", "Several days")]),
        field("phq9_score", .hidden, "", computed: true),
        field("phq9_severity", .hidden, "", computed: true),
        field("bmi_calc", .hidden, "", computed: true),
    ])

    static let smallAnswer = """
    {"pronouns":{"intent":"Pronouns the client states.","mode":"discrete","evidence_speaker":"client",
      "option_semantics":{"SHE_HER":"client says she/her","HE_HIM":"client says he/him","BOGUS":"x"}},
     "presenting_problem":{"intent":"Why the client came in.","mode":"narrative","evidence_speaker":"client","max_chars":99999},
     "risk_level":{"intent":"Risk.","mode":"clinician_only","evidence_speaker":"client",
      "option_semantics":{"LOW":"low","HIGH":"high"}},
     "phq9_1":{"intent":"PHQ-9 item 1.","mode":"discrete","evidence_speaker":"client",
      "option_semantics":{"0":"not at all","1":"several days"}}}
    """
}

@Suite struct EgressPayloadTests {
    @Test func goldenPayloadCarriesOnlyStructure() throws {
        let profile = try Fixtures.mockEHRProfile()
        let payload = EgressPayload.build(from: profile)
        let text = payload.json.serialized()
        for forbidden in ["selector", "frame", "fingerprint", "origin", "path_pattern", "127.0.0.1", "8787",
                          "#risk_frame", "label_source", "\"write\"", "computed", "sha256", "index.html"] {
            #expect(!text.contains(forbidden), "payload leaks \(forbidden)")
        }
        #expect(!text.contains(profile.fingerprint))
        // Hidden/computed fields are decided in code and never sent.
        let keys = payload.fields.map(\.key)
        #expect(!keys.contains("phq9_score") && !keys.contains("gad7_severity"))
        #expect(keys.count == profile.fields.count - 4)
        #expect(keys == profile.fields.filter { !$0.computed }.map(\.key))
        // Exactly the allowed keys per field, in a fixed order.
        let first = try #require(payload.json["fields"]?.arrayValue?.first?.objectValue)
        #expect(first.keys == ["key", "kind", "label", "help", "required", "options", "step"])
        #expect(payload.json.serialized() == EgressPayload.build(from: profile).json.serialized())
    }

    @Test func goldenProfilePassesScrub() throws {
        let profile = try Fixtures.mockEHRProfile()
        let caseNumber = try Fixtures.field(profile, "case_number")
        #expect(caseNumber.help == "Format: AB-000000")
        let report = EgressScrub.scan(EgressPayload.build(from: profile))
        #expect(report.hits == [])
        #expect(report.ok)
    }

    @Test(arguments: [
        ("Call 415-555-0132", "phone"), ("(415) 555-0132", "phone"), ("+1 415.555.0132", "phone"),
        ("jane.doe@gmail.com", "email"), ("SSN 123-45-6789", "ssn"),
        ("DOB 03/14/1987", "date"), ("Seen 2024-02-01", "date"), ("March 14, 1987", "date"),
        ("14 Mar 1987", "date"), ("since Oct 2023", "date"),
        ("Case AB-114322", "record_number"), ("MRN 88213417", "record_number"), ("chart #48213", "record_number"),
        ("value 5512349876", "long_digit_run"),
        ("1234 Elm Street", "street_address"), ("lives at 77 N Market St.", "street_address"),
        ("PO Box 1142", "street_address"), ("Oakland, CA 94612", "zip"), ("zip 94612", "zip"),
    ])
    func plantedPHITripsTheScrub(_ planted: String, _ pattern: String) {
        let places: [EgressPayload] = [
            MapFixtures.withField("Notes: " + planted),
            MapFixtures.withField(help: planted),
            MapFixtures.withField(options: [("A", planted), ("B", "Other")]),
            MapFixtures.withField(options: [(planted, "Household member"), ("B", "Other")]),
        ]
        for payload in places {
            let report = EgressScrub.scan(payload)
            #expect(!report.ok, "\(planted) not caught")
            #expect(report.hits.contains { $0.pattern == pattern }, "\(planted): \(report.hits)")
            let leaked = report.hits.filter { $0.excerptRedacted.contains(where: \.isNumber) }
            #expect(leaked.isEmpty, "report repeats digits")
        }
    }

    @Test(arguments: [
        "Format: AB-000000", "MM/DD/YYYY", "Date (YYYY-MM-DD)", "000-00-0000", "(999) 999-9999", "XXX-XX-XXXX",
        "###-###-####", "e.g. name@example.com", "PHQ-9", "GAD-7 administration", "SI frequency (past 2 weeks)",
        "988 Suicide & Crisis Lifeline", "2–4 times a month", "Oriented x4", "Typical sleep (hours/night)",
        "Every 2 weeks", "Substances used (past 30 days)", "Over the last 2 weeks, how often",
    ])
    func structuralTextIsAllowlisted(_ text: String) {
        let report = EgressScrub.scan(MapFixtures.withField(text, help: text, options: [("LINE_988", text)]))
        #expect(report.ok, "\(text): \(report.hits)")
    }

    @Test func enumCodeRuleIsNarrow() {
        #expect(EgressScrub.isEnumCode("LINE_988"))
        #expect(EgressScrub.isEnumCode("3"))
        #expect(!EgressScrub.isEnumCode("MRN_1143229"))
        #expect(!EgressScrub.isEnumCode("Maria Lopez"))
        #expect(!EgressScrub.scan(MapFixtures.withField(options: [("MRN_1143229", "x")])).ok)
    }

    @Test func profilerHashKeyIsStructuralButOtherKeysAreScanned() {
        var p = MapFixtures.profile([MapFixtures.field("f_f79934c38a", .text, "Duration (minutes)")])
        #expect(EgressScrub.scan(EgressPayload.build(from: p)).ok)
        p.fields[0].key = "client_AB114322_notes"
        #expect(!EgressScrub.scan(EgressPayload.build(from: p)).ok)
    }

    @Test func volatileOptionsAreWithheld() throws {
        let first = try Fixtures.mockEHRProfile()
        var second = first
        let i = try #require(second.fields.firstIndex { $0.key == "emergency_contact_relationship" })
        second.fields[i].options.append(FormProfile.Option(value: "P_4471", label: "Maria Lopez (sister)"))
        #expect(EgressPayload.volatileOptionKeys(first, second) == ["emergency_contact_relationship"])
        // Same set in another order is not volatile.
        var reordered = first
        reordered.fields[i].options.reverse()
        #expect(EgressPayload.volatileOptionKeys(first, reordered) == [])

        let (payload, report) = MapRun.prepare(.init(profile: second, secondProfile: first,
                                                     endpoint: URL(string: "http://localhost:8080")!))
        #expect(report.withheld == ["emergency_contact_relationship"])
        #expect(report.ok)
        let field = try #require(payload.fields.first { $0.key == "emergency_contact_relationship" })
        #expect(field.options == .withheld)
        #expect(field.json["options"] == "withheld")
        #expect(field.label == "Relationship")
        #expect(!payload.json.serialized().contains("Maria"))
        // Withheld fields get no option_semantics in the schema.
        let schema = MappingPrompt.schema(payload, keys: [field.key])
        #expect(schema["properties"]?["emergency_contact_relationship"]?["properties"]?["option_semantics"] == nil)
    }
}

@Suite(.serialized) struct MapRunTests {
    static func stubbedClient(host: String) -> OpenAIChatClient {
        OpenAIChatClient(endpoint: URL(string: "https://\(host)")!, model: "m", session: StubURLProtocol.session())
    }

    static func completion(_ content: String) -> String {
        JSONValue.obj(["choices": .array([.obj(["message": .obj(["role": "assistant", "content": .string(content)])])])])
            .serialized()
    }

    @Test func isLocalhost() {
        #expect(MapRun.isLocalhost(URL(string: "http://localhost:8080")!))
        #expect(MapRun.isLocalhost(URL(string: "http://127.0.0.1:8080/v1")!))
        #expect(MapRun.isLocalhost(URL(string: "http://[::1]:8080")!))
        #expect(!MapRun.isLocalhost(URL(string: "https://api.openai.com")!))
        #expect(!MapRun.isLocalhost(URL(string: "http://localhost.evil.com")!))
        #expect(!MapRun.isLocalhost(URL(string: "http://127.0.0.2")!))
    }

    @Test func nonLocalhostWithoutYesNeverSends() async throws {
        let host = "cloud-noyes.stub.test"
        StubURLProtocol.stub(host: host, body: Self.completion(MapFixtures.smallAnswer))
        let options = MapRun.Options(profile: try Fixtures.mockEHRProfile(),
                                     endpoint: URL(string: "https://\(host)")!)
        let outcome = await MapRun.run(options, client: Self.stubbedClient(host: host))
        #expect(outcome.exitCode == 2)
        #expect(outcome.stderr.contains("re-run with --yes to send this to \(host)"))
        #expect(outcome.stderr.contains(#"{"key":"case_number","kind":"text","label":"Case number","help":"Format: AB-000000""#))
        #expect(outcome.mapping == nil)
        #expect(StubURLProtocol.requests(host: host).isEmpty)
        #expect(outcome.requestsSent == 0)
    }

    @Test func scrubHitRefusesEvenForLocalhostAndWithYes() async throws {
        let host = "cloud-hit.stub.test"
        StubURLProtocol.stub(host: host, body: Self.completion("{}"))
        var profile = MapFixtures.smallProfile
        profile.fields[0].help = "Last seen 03/14/2025"
        let outcome = await MapRun.run(.init(profile: profile, endpoint: URL(string: "https://\(host)")!, yes: true),
                                       client: Self.stubbedClient(host: host))
        #expect(outcome.exitCode == 1)
        #expect(outcome.stderr.contains("refusing to send"))
        #expect(!outcome.stderr.contains("03/14/2025"))
        #expect(StubURLProtocol.requests(host: host).isEmpty)

        let local = RecordingClient { _ in "{}" }
        let localOutcome = await MapRun.run(.init(profile: profile, endpoint: URL(string: "http://127.0.0.1:8080")!),
                                            client: local)
        #expect(localOutcome.exitCode == 1)
        #expect(local.requests.isEmpty)
    }

    @Test func dryRunPrintsPayloadAndReportWithoutSending() async throws {
        let client = RecordingClient { _ in "{}" }
        let outcome = await MapRun.run(.init(profile: try Fixtures.mockEHRProfile(),
                                             endpoint: URL(string: "https://api.example.net")!, dryRun: true),
                                       client: client)
        #expect(outcome.exitCode == 0)
        #expect(client.requests.isEmpty)
        let lines = outcome.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outcome.stdout.hasPrefix("{\"fields\":[\n"))
        #expect(lines.contains { $0 == #"{"hits":[],"withheld":[],"ok":true}"# })
        let payloadText = MapRun.payloadText(outcome.payload)
        let reparsed = try JSONValue.parse(payloadText)
        #expect(reparsed == outcome.payload.json)
    }

    @Test func yesSendsOnlyThePayloadToNonLocalhost() async throws {
        let host = "cloud-yes.stub.test"
        StubURLProtocol.stub(host: host, body: Self.completion(MapFixtures.smallAnswer))
        let outcome = await MapRun.run(.init(profile: MapFixtures.smallProfile,
                                             endpoint: URL(string: "https://\(host)")!, yes: true),
                                       client: Self.stubbedClient(host: host))
        #expect(outcome.exitCode == 0)
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        let body = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        for forbidden in ["sha256:abc123", "ehr.agency.example", "#inner", "#pronouns", "/clients/", "phq9_score"] {
            #expect(!body.contains(forbidden), "request leaks \(forbidden)")
        }
        #expect(body.contains("Pronouns"))
    }

    @Test func batchesAreDeterministicInProfileOrder() throws {
        let payload = EgressPayload.build(from: try Fixtures.mockEHRProfile())
        let batches = MappingPrompt.batches(payload)
        #expect(batches.flatMap { $0 } == payload.fields.map(\.key))
        #expect(batches.dropLast().allSatisfy { $0.count == 15 })
        #expect(batches.count == (payload.fields.count + 14) / 15)
        let r1 = MappingPrompt.request(payload, keys: batches[0])
        let r2 = MappingPrompt.request(payload, keys: batches[0])
        #expect(r1 == r2)
        #expect(!r1.messages.map(\.content).joined().contains("selector"))
    }

    @Test func schemaConstrainsModesAndOptionSemantics() throws {
        let payload = EgressPayload.build(from: MapFixtures.smallProfile)
        let schema = MappingPrompt.schema(payload, keys: ["pronouns", "presenting_problem"])
        #expect(schema["required"] == .strings(["pronouns", "presenting_problem"]))
        #expect(schema["additionalProperties"] == false)
        let pronouns = try #require(schema["properties"]?["pronouns"])
        #expect(pronouns["properties"]?["mode"]?["enum"] == .strings(["discrete", "narrative", "clinician_only", "skip"]))
        #expect(pronouns["properties"]?["evidence_speaker"]?["enum"] == .strings(["client", "any", "worker"]))
        let semantics = try #require(pronouns["properties"]?["option_semantics"])
        #expect(semantics["required"] == .strings(["SHE_HER", "HE_HIM"]))
        #expect(semantics["additionalProperties"] == false)
        #expect(pronouns["properties"]?["max_chars"] == nil)
        let problem = try #require(schema["properties"]?["presenting_problem"])
        #expect(problem["properties"]?["option_semantics"] == nil)
        #expect(problem["properties"]?["max_chars"]?["type"] == "integer")
    }

    @Test func stubbedResponseRoundTripsIntoAValidMapping() async throws {
        let client = RecordingClient { _ in MapFixtures.smallAnswer }
        let outcome = await MapRun.run(.init(profile: MapFixtures.smallProfile,
                                             endpoint: URL(string: "http://localhost:8080")!),
                                       client: client)
        #expect(outcome.exitCode == 0, "\(outcome.stderr)")
        #expect(client.requests.count == 1)
        #expect(client.requests[0].responseFormat?["json_schema"]?["name"] == "form_mapping_batch")

        let mapping = try JSONDecoder().decode(FormMapping.self, from: Data(outcome.stdout.utf8))
        #expect(mapping == outcome.mapping)
        #expect(mapping.profileFingerprint == "sha256:abc123")
        #expect(Set(mapping.fields.keys) == Set(MapFixtures.smallProfile.fields.map(\.key)))

        let pronouns = try #require(mapping.fields["pronouns"])
        #expect(pronouns.optionSemantics == ["SHE_HER": "client says she/her", "HE_HIM": "client says he/him"])
        #expect(pronouns.evidenceSpeaker == .client)
        let problem = try #require(mapping.fields["presenting_problem"])
        #expect(problem.mode == .narrative && problem.maxChars == 4000 && problem.evidenceSpeaker == .any)
        let risk = try #require(mapping.fields["risk_level"])
        #expect(risk.mode == .clinicianOnly && risk.evidenceSpeaker == .any && risk.optionSemantics == nil)
        #expect(mapping.fields["phq9_2"]?.mode == .skip)   // model omitted it: flagged for review
        #expect(outcome.stderr.contains("phq9_2: no usable proposal"))
        #expect(mapping.fields["phq9_score"]?.derive == .init(function: "phq9_total", inputs: ["phq9_1", "phq9_2"]))
        #expect(mapping.fields["phq9_severity"]?.derive == .init(function: "phq9_band", inputs: ["phq9_1", "phq9_2"]))
        #expect(mapping.fields["bmi_calc"]?.mode == .skip)
        // Output lists fields in profile order for hand review.
        let a = try #require(outcome.stdout.range(of: "\"pronouns\""))
        let b = try #require(outcome.stdout.range(of: "\"presenting_problem\""))
        #expect(a.lowerBound < b.lowerBound)
    }
}

@Suite struct MappingPostProcessorTests {
    @Test func hiddenFieldsAreForcedDerivedOrSkip() throws {
        let profile = try Fixtures.mockEHRProfile()
        // Even if a model proposed something for them, code decides.
        let bogus: JSONValue = .obj(["intent": "x", "mode": "discrete", "evidence_speaker": "client"])
        let proposals = Dictionary(uniqueKeysWithValues: profile.fields.map { ($0.key, bogus) })
        let (mapping, _) = MappingPostProcessor.assemble(profile: profile, proposals: proposals, base: nil)
        let reviewed = try Fixtures.mapping()
        for key in ["phq9_score", "phq9_severity", "gad7_score", "gad7_severity"] {
            let m = try #require(mapping.fields[key])
            #expect(m.mode == .derived)
            #expect(m.derive == reviewed.fields[key]?.derive, "\(key) derive differs from hand-reviewed mapping")
            #expect(m.evidenceSpeaker == .any)
        }
        #expect(mapping.profileFingerprint == profile.fingerprint)
        #expect(MappingPostProcessor.derivation(for: "bmi_score", in: profile) == nil)
        #expect(MappingPostProcessor.derivation(for: "gad7_status", in: profile) == nil)
    }

    @Test func baseEntriesArePreserved() throws {
        let profile = try Fixtures.mockEHRProfile()
        let base = try Fixtures.mapping()
        var partial = base
        partial.fields = base.fields.filter { ["risk_level", "substances", "gad7_score"].contains($0.key) }
        partial.fields["removed_field"] = .init(intent: "gone", mode: .skip, evidenceSpeaker: .any)

        let (payload, report) = MapRun.prepare(.init(profile: profile, base: partial,
                                                     endpoint: URL(string: "http://localhost")!))
        #expect(report.ok)
        #expect(!payload.fields.contains { $0.key == "risk_level" || $0.key == "substances" })

        let proposal: JSONValue = .obj(["intent": "model says", "mode": "discrete", "evidence_speaker": "any"])
        let (mapping, warnings) = MappingPostProcessor.assemble(
            profile: profile, proposals: ["risk_level": proposal, "substances": proposal, "session_date": proposal],
            base: partial)
        #expect(mapping.fields["risk_level"] == base.fields["risk_level"])
        #expect(mapping.fields["substances"] == base.fields["substances"])
        #expect(mapping.fields["substances"]?.evidenceSpeaker == .client)
        #expect(mapping.fields["gad7_score"] == base.fields["gad7_score"])
        #expect(mapping.fields["session_date"]?.intent == "model says")
        #expect(mapping.fields["removed_field"] == nil)
        #expect(warnings.contains { $0.contains("removed_field") })
    }

    @Test func fullBaseMeansNothingIsSent() async throws {
        let client = RecordingClient { _ in "{}" }
        let base = try Fixtures.mapping()
        let outcome = await MapRun.run(.init(profile: try Fixtures.mockEHRProfile(), base: base,
                                             endpoint: URL(string: "https://api.example.net")!, yes: true),
                                       client: client)
        #expect(outcome.exitCode == 0)
        #expect(client.requests.isEmpty)
        #expect(outcome.mapping?.fields == base.fields)
    }
}

@Suite struct AttestationRuleTests {
    @Test func attestationIsForcedClinicianOnlyWhateverTheModelSays() throws {
        let profile = try Fixtures.mockEHRProfile()
        let field = try Fixtures.field(profile, "note_attestation")
        #expect(MappingPostProcessor.isAttestation(field))
        let proposal: JSONValue = .obj(["intent": "tick if the note is done", "mode": "discrete", "evidence_speaker": "worker"])
        let (mapping, warnings) = MappingPostProcessor.assemble(profile: profile, proposals: ["note_attestation": proposal], base: nil)
        #expect(mapping.fields["note_attestation"]?.mode == .clinicianOnly)
        #expect(warnings.contains { $0.contains("note_attestation") && $0.contains("forced clinician_only") })
    }

    @Test func ordinaryFieldsAreNotAttestations() throws {
        let profile = try Fixtures.mockEHRProfile()
        let hits = profile.fields.filter(MappingPostProcessor.isAttestation).map(\.key)
        #expect(hits == ["note_attestation"])
    }
}
