// Dev CLI. Subcommands arrive with their tasks: map (P1.4), eval (P1.6), demo (P1.7),
// models (P1.8), record (P2).
import FormDriver
import Foundation
import ScribeskiCore

let usage = """
usage: scribeski <command>

  transcript <file.txt>        parse a fixture transcript and print it as Transcript JSON
  js <expression>              evaluate JS in Safari's front tab and print the result
  page <command-json>          run a page-bundle command in Safari's front tab (e.g. '{"op":"ping"}')
  profile [--out file]         profile the form in Safari's front tab (structure only, no values)
  fill --profile <json> --results <json> [--identity-selector <css> --identity <text>]
                               fill the front tab from FieldResult[]; prints FillReports
  map <profile.json> --endpoint <url> --model <name> [--second-profile|--base|--out|--yes|--dry-run]  FormMapping via LLM, behind the egress scrub (P1.4)
  extract --transcript <txt|json> --profile <json> --mapping <json> --endpoint <url> --model <name>
          [--api-key-env VAR] [--concurrency N] [--out results.json]
                               per-field extraction with verified evidence (P1.5)
  score --results <json> --expected <json> [--slots N] [--out report.md]
                               score results against ground truth; exits 1 if any gate fails
  note --transcript <txt|json> [--concurrency N] [--out outcome.json]
                               transcript → profile → extract → fill the front tab, in one go (P1.7)
  forms list | add <mapping.json> --profile <profile.json>
                               learned forms (profile + mapping), found by fingerprint or URL
  charts                       learned charts open in Safari, and whose they are
  packs export <file> | import <file>
                               form packs: learned forms + session templates, to share across an agency
  models <subcommand>          shared model store: where | list | status | pull | use | reset
  version                      print the version

  Safari commands take --transport scriptingbridge|applescript (default scriptingbridge).
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func printJSON(_ value: Any?) {
    guard let value, JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber else {
        print(value.map { String(describing: $0) } ?? "null")
        return
    }
    if let s = value as? String { print(s); return }
    if let n = value as? NSNumber {
        // JSONSerialization hands booleans back as NSNumber; print them as JSON does.
        print(CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n)
        return
    }
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

/// Splits `--flag value` pairs out of the argument list.
func parseFlags(_ args: [String]) -> (positional: [String], flags: [String: String]) {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        if args[i].hasPrefix("--"), i + 1 < args.count {
            flags[String(args[i].dropFirst(2))] = args[i + 1]
            i += 2
        } else {
            positional.append(args[i])
            i += 1
        }
    }
    return (positional, flags)
}

func makeSession(_ flags: [String: String]) -> PageSession {
    let transport: any JSTransport = flags["transport"] == "applescript" ? AppleScriptSafari() : ScriptingBridgeSafari()
    do {
        return try PageSession(transport: transport, bundleSource: PageSession.loadBundle())
    } catch {
        fail(error.description)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let (positional, flags) = parseFlags(Array(args.dropFirst()))

switch args.first {
case "version":
    print("scribeski 0.0.0")

case "transcript" where positional.count == 1:
    do {
        let text = try String(contentsOfFile: positional[0], encoding: .utf8)
        let name = URL(fileURLWithPath: positional[0]).deletingPathExtension().lastPathComponent
        let (transcript, _) = try TranscriptText.parse(text, sessionId: name, source: "fixture")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(transcript))
        print()
    } catch {
        fail("\(error)")
    }

case "js" where positional.count == 1:
    do {
        printJSON(try makeSession(flags).evaluate(positional[0]))
    } catch {
        fail(error.description)
    }

case "page" where positional.count == 1:
    guard let command = try? JSONSerialization.jsonObject(with: Data(positional[0].utf8)) as? [String: Any] else {
        fail("command must be a JSON object")
    }
    do {
        printJSON(try await makeSession(flags).run(command))
    } catch {
        fail(error.description)
    }

case "extract":
    do {
        try await ExtractCommands.extract(Array(args.dropFirst()))
    } catch {
        fail("\(error)")
    }

case "map":
    await MapCommand.run(Array(args.dropFirst()))

case "score":
    do {
        if try !ExtractCommands.score(Array(args.dropFirst())) { exit(1) }
    } catch {
        fail("\(error)")
    }

case "note":
    do {
        try await NoteCommand.note(flags)
    } catch {
        fail("\(error)")
    }

case "forms":
    do {
        try NoteCommand.forms(positional, flags)
    } catch {
        fail("\(error)")
    }

case "charts":
    NoteCommand.charts()

case "packs":
    do {
        try NoteCommand.packs(positional, flags)
    } catch {
        fail("\(error)")
    }

case "fill-chart":
    do {
        try await NoteCommand.fillChart(flags)
    } catch {
        fail("\(error)")
    }

case "models":
    do {
        try await ModelsCommand.run(Array(args.dropFirst()))
    } catch {
        fail("\(error)")
    }

case "profile":
    do {
        let profile = try await makeSession(flags).profile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(profile)
        if let out = flags["out"] { try data.write(to: URL(fileURLWithPath: out)) } else { print(String(decoding: data, as: UTF8.self)) }
        FileHandle.standardError.write(Data("\(profile.fields.count) fields, \(profile.unreachable.count) unreachable frames\n".utf8))
    } catch let e as PageSession.Error {
        fail(e.description)
    } catch {
        fail("\(error)")
    }

case "fill":
    guard let profilePath = flags["profile"], let resultsPath = flags["results"] else { fail(usage, code: 2) }
    do {
        let profile = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: URL(fileURLWithPath: profilePath)))
        let results = try JSONDecoder().decode([FieldResult].self, from: Data(contentsOf: URL(fileURLWithPath: resultsPath)))
        var identity: PageSession.Identity?
        if let sel = flags["identity-selector"], let expected = flags["identity"] {
            identity = .init(selector: sel, expected: expected)
        }
        let outcome = try await makeSession(flags).fill(profile: profile, results: results, identity: identity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(outcome.reports), as: UTF8.self))
        let bad = outcome.reports.filter { $0.outcome != .ok && $0.outcome != .computedVerified }
        FileHandle.standardError.write(Data("""
            \(outcome.reports.count) reports, \(bad.count) not ok; identity \(outcome.identity); \
            page made \(outcome.network.requests) network requests during fill\(outcome.network.requests > 0 ? " (AUTOSAVE?)" : "")

            """.utf8))
    } catch let e as PageSession.Error {
        fail(e.description)
    } catch {
        fail("\(error)")
    }

default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(args.isEmpty ? 0 : 2)
}
