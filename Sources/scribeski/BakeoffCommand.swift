import Foundation
import ScribeskiCore
import Transcription

/// `scribeski asr-bakeoff <dir> [--engines parakeet,speechanalyzer] [--out report.md]`
/// (BUILD_PLAN P2.8). Writes the report, plus each engine's transcript per session beside it
/// (`<session>.<engine>.transcript.json`) for the field-accuracy step.
enum BakeoffCommand {
    static func run(_ positional: [String], _ flags: [String: String]) async throws {
        guard let dir = positional.first else { fail("usage: scribeski asr-bakeoff <dir> [--engines …] [--out report.md]", code: 2) }
        let sessions = try ASRBakeoff.sessions(in: URL(fileURLWithPath: dir))
        guard !sessions.isEmpty else { fail("no sessions in \(dir): each needs client.<audio> and reference.json") }
        let engines = (flags["engines"] ?? "parakeet,speechanalyzer").split(separator: ",").map(String.init)
        let out = URL(fileURLWithPath: flags["out"] ?? "eval/asr-bakeoff.md")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var rows: [ASRBakeoff.Row] = []
        for engine in engines {
            let transcriber: any Transcriber
            switch engine {
            case "parakeet": transcriber = try ParakeetTranscriber.fromModelStore()
            case "speechanalyzer": transcriber = SpeechAnalyzerTranscriber()
            default: fail("unknown engine \(engine) (parakeet, speechanalyzer)", code: 2)
            }
            FileHandle.standardError.write(Data("preparing \(engine)…\n".utf8))
            try await transcriber.prepare(locale: Locale(identifier: "en_US"), vocabulary: Vocabulary.default)
            for session in sessions {
                FileHandle.standardError.write(Data("  \(session.name) with \(engine)…\n".utf8))
                let (row, transcript) = try await ASRBakeoff.run(session, transcriber: transcriber)
                rows.append(row)
                try encoder.encode(transcript).write(to: out.deletingLastPathComponent()
                    .appendingPathComponent("\(session.name).\(engine).transcript.json"))
            }
        }
        try ASRBakeoff.markdown(rows).write(to: out, atomically: true, encoding: .utf8)
        try encoder.encode(rows).write(to: out.deletingPathExtension().appendingPathExtension("json"))
        print(ASRBakeoff.markdown(rows))
    }
}
