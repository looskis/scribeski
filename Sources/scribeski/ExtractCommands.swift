import Extraction
import Foundation
import ScribeskiCore

/// `scribeski extract` and `scribeski score` (BUILD_PLAN P1.5, P1.6).
///
/// ```
/// scribeski extract --transcript <txt|json> --profile <json> --mapping <json>
///                   --endpoint <url> --model <name> [--api-key-env VAR]
///                   [--concurrency N] [--single-user] [--cold-cache] [--out results.json]
/// scribeski score --results <json> --expected <json> [--slots N] [--out report.md]
/// ```
enum ExtractCommands {
    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static let extractUsage = """
    usage: scribeski extract --transcript <file.txt|file.json> --profile <profile.json> \
    --mapping <mapping.json> --endpoint <url> --model <name> [--api-key-env VAR] \
    [--concurrency N] [--single-user] [--cold-cache] [--out results.json]
    --cold-cache  eval: start from a cold prompt cache (per-run marker at the start of the prefix)
    """

    static let scoreUsage = """
    usage: scribeski score --results <results.json> --expected <expected.json> [--slots N] [--out report.md]
    """

    static func extract(_ args: [String]) async throws {
        let flags = try parse(args, valued: ["--transcript", "--profile", "--mapping", "--endpoint", "--model",
                                             "--api-key-env", "--concurrency", "--out"],
                              switches: ["--single-user", "--cold-cache"], usage: extractUsage)
        let transcriptPath = try require(flags, "--transcript", extractUsage)
        let profilePath = try require(flags, "--profile", extractUsage)
        let mappingPath = try require(flags, "--mapping", extractUsage)
        let endpointText = try require(flags, "--endpoint", extractUsage)
        let model = try require(flags, "--model", extractUsage)
        guard let endpoint = URL(string: endpointText), endpoint.scheme != nil else {
            throw UsageError(description: "bad --endpoint \(endpointText)")
        }
        let concurrency = try flags["--concurrency"].map {
            guard let n = Int($0), n > 0 else { throw UsageError(description: "bad --concurrency \($0)") }
            return n
        } ?? 1

        var apiKey: String?
        if let variable = flags["--api-key-env"] {
            guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
                throw UsageError(description: "environment variable \(variable) is not set")
            }
            apiKey = value
        }

        let transcript = try loadTranscript(transcriptPath)
        let decoder = JSONDecoder()
        let profile = try decoder.decode(FormProfile.self, from: Data(contentsOf: URL(fileURLWithPath: profilePath)))
        let mapping = try decoder.decode(FormMapping.self, from: Data(contentsOf: URL(fileURLWithPath: mappingPath)))
        if mapping.profileFingerprint != profile.fingerprint, mapping.profileFingerprint != "sha256:pending" {
            warn("mapping was made for \(mapping.profileFingerprint), profile is \(profile.fingerprint): the form may have drifted")
        }
        let unmapped = profile.fields.map(\.key).filter { mapping.fields[$0] == nil }
        if !unmapped.isEmpty { warn("no mapping for \(unmapped.count) field(s), skipped: \(unmapped.joined(separator: ", "))") }

        let client = OpenAIChatClient(endpoint: endpoint, model: model, apiKey: apiKey)
        let extractor = Extractor(client: client, model: model, concurrency: concurrency,
                                  prompts: PromptBuilder(layout: flags["--single-user"] != nil ? .singleUser : .systemAndUser,
                                                        runNonce: flags["--cold-cache"] != nil ? UUID().uuidString : nil))
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await extractor.extract(transcript: transcript, profile: profile, mapping: mapping)
        let elapsed = clock.now - start

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(results) + Data("\n".utf8), to: flags["--out"])

        var counts: [String: Int] = [:]
        for r in results { counts[r.status.rawValue, default: 0] += 1 }
        let prefill = results.compactMap(\.prefillTokens)
        warn("\(results.count) fields in \(elapsed): "
            + counts.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            + (prefill.isEmpty ? "" : "; prefill request 1 = \(prefill[0]), requests 2..N = \(prefill.dropFirst().reduce(0, +))"))
    }

    /// Returns whether every gate passed.
    @discardableResult
    static func score(_ args: [String]) throws -> Bool {
        let flags = try parse(args, valued: ["--results", "--expected", "--slots", "--out"], switches: [],
                              usage: scoreUsage)
        let resultsPath = try require(flags, "--results", scoreUsage)
        let expectedPath = try require(flags, "--expected", scoreUsage)
        let slots = try flags["--slots"].map {
            guard let n = Int($0), n > 0 else { throw UsageError(description: "bad --slots \($0)") }
            return n
        } ?? 1
        let results = try JSONDecoder().decode([FieldResult].self,
                                               from: Data(contentsOf: URL(fileURLWithPath: resultsPath)))
        let expected = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        let report = Scorer.score(results: results, expected: expected, slots: slots)
        let title = "Extraction eval: \(URL(fileURLWithPath: resultsPath).lastPathComponent)"
        try write(Data(report.markdown(title: title).utf8), to: flags["--out"])
        warn("score: \(report.passed ? "PASS" : "FAIL")")
        return report.passed
    }

    // MARK: - Helpers

    static func loadTranscript(_ path: String) throws -> Transcript {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "json" {
            return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        return try TranscriptText.parse(text, sessionId: name, source: "fixture").transcript
    }

    static func parse(_ args: [String], valued: Set<String>, switches: Set<String>,
                      usage: String) throws -> [String: String] {
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            let arg = args[i]
            if switches.contains(arg) {
                flags[arg] = ""
                i += 1
            } else if valued.contains(arg) {
                guard i + 1 < args.count else { throw UsageError(description: "\(arg) needs a value\n\(usage)") }
                flags[arg] = args[i + 1]
                i += 2
            } else {
                throw UsageError(description: "unknown argument \(arg)\n\(usage)")
            }
        }
        return flags
    }

    static func require(_ flags: [String: String], _ name: String, _ usage: String) throws -> String {
        guard let v = flags[name], !v.isEmpty else { throw UsageError(description: "missing \(name)\n\(usage)") }
        return v
    }

    static func write(_ data: Data, to path: String?) throws {
        if let path {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
