import Extraction
import Foundation
import ScribeskiCore

/// `scribeski map` (BUILD_PLAN P1.4): FormProfile → FormMapping via an OpenAI-compatible LLM,
/// behind the egress scrub (`MapRun`).
///
/// ```
/// scribeski map <profile.json> --endpoint <url> --model <name> [--api-key-env VAR]
///               [--second-profile <json>] [--base <mapping.json>] [--out mapping.json]
///               [--batch-size N] [--yes] [--dry-run]
/// ```
/// Exit codes: 0 ok, 1 scrub hit or request failure, 2 usage or confirmation needed.
enum MapCommand {
    static let usage = """
    usage: scribeski map <profile.json> --endpoint <url> --model <name> [--api-key-env VAR] \
    [--second-profile <profile.json>] [--base <mapping.json>] [--out mapping.json] [--batch-size N] \
    [--yes] [--dry-run]
    """

    static func run(_ args: [String]) async {
        do {
            let code = try await execute(args)
            if code != 0 { exit(code) }
        } catch let e as ExtractCommands.UsageError {
            fail(e.description, code: 2)
        } catch {
            fail("\(error)")
        }
    }

    static func execute(_ args: [String]) async throws -> Int32 {
        guard let profilePath = args.first, !profilePath.hasPrefix("--") else {
            throw ExtractCommands.UsageError(description: "missing <profile.json>\n\(usage)")
        }
        let flags = try ExtractCommands.parse(
            Array(args.dropFirst()),
            valued: ["--endpoint", "--model", "--api-key-env", "--second-profile", "--base", "--out", "--batch-size"],
            switches: ["--yes", "--dry-run"], usage: usage)
        let dryRun = flags["--dry-run"] != nil
        let endpointText = try ExtractCommands.require(flags, "--endpoint", usage)
        let model = dryRun ? (flags["--model"] ?? "") : try ExtractCommands.require(flags, "--model", usage)
        guard let endpoint = URL(string: endpointText), let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https", endpoint.host != nil else {
            throw ExtractCommands.UsageError(description: "bad --endpoint \(endpointText)")
        }
        let batchSize = try flags["--batch-size"].map {
            guard let n = Int($0), n > 0 else { throw ExtractCommands.UsageError(description: "bad --batch-size \($0)") }
            return n
        } ?? MappingPrompt.defaultBatchSize

        var apiKey: String?
        if let variable = flags["--api-key-env"] {
            guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
                throw ExtractCommands.UsageError(description: "environment variable \(variable) is not set")
            }
            apiKey = value
        }

        let decoder = JSONDecoder()
        func load<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let options = MapRun.Options(
            profile: try load(FormProfile.self, profilePath),
            secondProfile: try flags["--second-profile"].map { try load(FormProfile.self, $0) },
            base: try flags["--base"].map { try load(FormMapping.self, $0) },
            endpoint: endpoint, yes: flags["--yes"] != nil, dryRun: dryRun, batchSize: batchSize)

        let client = OpenAIChatClient(endpoint: endpoint, model: model, apiKey: apiKey)
        let outcome = await MapRun.run(options, client: client)
        FileHandle.standardError.write(Data(outcome.stderr.utf8))
        if outcome.mapping != nil {
            try ExtractCommands.write(Data(outcome.stdout.utf8), to: flags["--out"])
            if let out = flags["--out"] { ExtractCommands.warn("wrote \(out); review it by hand before use") }
        } else if !outcome.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        return outcome.exitCode
    }
}
