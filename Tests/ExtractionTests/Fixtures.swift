import Foundation
import Testing
@testable import Extraction
import ScribeskiCore

/// Loads the checked-in fixtures. The mock-EHR profile is the page profiler's golden file;
/// `fieldsMDProfile()` rebuilds it independently from FIELDS.md as a cross-check.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func sampleTranscript() throws -> Transcript {
        let text = try String(contentsOf: url("sample-session.txt"), encoding: .utf8)
        return try TranscriptText.parse(text, sessionId: "sample-session").transcript
    }

    static func mapping() throws -> FormMapping {
        try JSONDecoder().decode(FormMapping.self, from: Data(contentsOf: url("mock-ehr/mapping.json")))
    }

    static func expected() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: url("expected-extraction.json")))
    }

    /// First segment whose text contains `fragment` (optionally by `speaker`).
    static func segment(_ t: Transcript, _ fragment: String, speaker: Speaker? = nil) throws -> Transcript.Segment {
        try #require(t.segments.first { $0.text.contains(fragment) && (speaker == nil || $0.speaker == speaker) },
                     "no segment contains \(fragment)")
    }

    // MARK: - Mock EHR profile from FIELDS.md

    static func mockEHRProfile() throws -> FormProfile {
        let golden = root.deletingLastPathComponent().appendingPathComponent("page/test/golden/mock-ehr.profile.json")
        return try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: golden))
    }

    static func fieldsMDProfile() throws -> FormProfile {
        let text = try String(contentsOf: url("mock-ehr/FIELDS.md"), encoding: .utf8)
        var fields: [FormProfile.Field] = []
        var step = "step-0"
        var columns: [String: Int] = [:]

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## Step ") {
                step = "step-" + String(line.dropFirst(8).prefix(1))
                columns = [:]
                continue
            }
            guard line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "#" {
                columns = Dictionary(uniqueKeysWithValues: cells.enumerated().map { ($1, $0) })
                continue
            }
            guard let keyCol = columns["key"], let kindCol = columns["kind"], cells.count == columns.count,
                  !cells[0].hasPrefix("---") else { continue }

            var label = cells[columns["label"]!].replacingOccurrences(of: "\"", with: "")
            let optionsColumn = columns.first { $0.key.hasPrefix("options") }?.value
            var optionText = optionsColumn.map { cells[$0] } ?? ""
            if optionText.isEmpty, let dash = label.range(of: " — ") {
                let tail = String(label[dash.upperBound...])
                if tail.allSatisfy({ $0.isUppercase || $0 == "_" || $0 == "," || $0 == " " }) {
                    optionText = tail
                    label = String(label[..<dash.lowerBound])
                }
            }
            guard let kind = FormProfile.Kind(rawValue: cells[kindCol]) else { continue }
            var options = optionText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("(") }
                .map { FormProfile.Option(value: $0, label: $0.replacingOccurrences(of: "_", with: " ").capitalized) }
            if kind == .radioGroup, options.isEmpty {
                options = [("0", "Not at all"), ("1", "Several days"), ("2", "More than half the days"),
                           ("3", "Nearly every day")].map { FormProfile.Option(value: $0.0, label: $0.1) }
            }

            for key in expandKeys(cells[keyCol]) {
                let write: FormProfile.WriteStrategy = switch kind {
                case .select: .select
                case .radioGroup, .checkboxGroup: .clickToggle
                case .combobox: .comboboxClick
                case .hidden: .never
                default: .nativeSetter
                }
                fields.append(FormProfile.Field(
                    key: key, step: step, kind: kind, label: kind == .hidden ? "" : label,
                    labelSource: kind == .hidden ? nil : .labelFor, options: kind == .hidden ? [] : options,
                    selectors: ["#\(key)"], write: write, computed: kind == .hidden))
            }
        }
        return FormProfile(origin: "http://localhost:8787", pathPattern: "/index.html",
                           fingerprint: "sha256:pending", steps: [], fields: fields)
    }

    /// `phq9_1 … phq9_9`, `adl_bathing, adl_dressing`, `*(none)* duration`.
    static func expandKeys(_ cell: String) -> [String] {
        let cleaned = cell.replacingOccurrences(of: "*(none)*", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.contains("…") {
            let parts = cleaned.components(separatedBy: "…").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let us = parts[0].lastIndex(of: "_"), let lo = Int(parts[0][parts[0].index(after: us)...]),
                  let hi = Int(parts[1].split(separator: "_").last ?? "") else { return [] }
            let stem = parts[0][...us]
            return (lo...hi).map { "\(stem)\($0)" }
        }
        return cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func field(_ profile: FormProfile, _ key: String) throws -> FormProfile.Field {
        try #require(profile.fields.first { $0.key == key })
    }
}

/// A scripted `LLMClient`: answers by field key (read from the prompt suffix) and records
/// every request.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private var _requests: [ChatRequest] = []
    var prefillFirst = 4000
    var prefillRest = 30

    init(_ answers: [String: String]) { self.answers = answers }

    var requests: [ChatRequest] { lock.withLock { _requests } }

    static func key(of request: ChatRequest) -> String? {
        guard let content = request.messages.last?.content,
              let line = content.split(separator: "\n").first(where: { $0.hasPrefix("key: ") }) else { return nil }
        return String(line.dropFirst(5))
    }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let (answer, n) = lock.withLock { () -> (String, Int) in
            _requests.append(request)
            let key = Self.key(of: request) ?? ""
            return (answers[key] ?? #"{"status":"insufficient_evidence","evidence":[],"value":null}"#, _requests.count)
        }
        return ChatResponse(content: answer, prefillTokens: n == 1 ? prefillFirst : prefillRest, ms: 10)
    }
}
