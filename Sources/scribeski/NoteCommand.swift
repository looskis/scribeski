import Extraction
import Foundation
import Orchestrator
import ScribeskiCore

/// `scribeski note` (BUILD_PLAN P1.7): one command from a transcript to a filled form in the
/// front Safari tab, through the same pipeline the app runs after Stop. `scribeski forms`
/// manages the learned mappings it looks forms up in.
enum NoteCommand {
    static let usage = """
    usage: scribeski note --transcript <file.txt|file.json> [--concurrency N] [--out outcome.json]
           scribeski forms list
           scribeski forms add <mapping.json> --profile <profile.json> [--templates <templates.json>]
           scribeski forms rematch --profile <new-profile.json> [--yes]
           scribeski packs export <pack.json> --name <text> --version <text>
           scribeski packs import <pack.json>
           scribeski charts            learned charts open in Safari, and whose they are
    """

    static func note(_ flags: [String: String]) async throws {
        guard let path = flags["transcript"] else { throw ExtractCommands.UsageError(description: usage) }
        let transcript = try ExtractCommands.loadTranscript(path)
        var pipeline = NotePipeline(llm: try .fromModelStore())
        pipeline.concurrency = flags["concurrency"].flatMap(Int.init) ?? 1
        let outcome = try await pipeline.run(transcript: transcript) { stage in
            ExtractCommands.warn("… \(stage.rawValue)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try ExtractCommands.write(encoder.encode(outcome) + Data("\n".utf8), to: flags["out"])

        var status: [String: Int] = [:]
        for r in outcome.results { status[r.status.rawValue, default: 0] += 1 }
        let notOK = outcome.reports.filter { $0.outcome != .ok && $0.outcome != .computedVerified }
        ExtractCommands.warn("""
            filled “\(outcome.pageTitle)”: \(status.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            fill: \(outcome.reports.count) written, \(notOK.count) not ok; identity \(outcome.identity); \
            page requests during fill: \(outcome.pageNetworkRequests)
            seconds: \(outcome.seconds.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value))" }.joined(separator: ", "))
            """)
    }

    static func forms(_ positional: [String], _ flags: [String: String]) throws {
        let library = FormLibrary()
        switch positional.first {
        case "list":
            print(library.directory.path)
            for f in library.forms() {
                let chart = f.mapping.chart.map { "\($0.origin)\($0.pathPattern)" } ?? "no chart spec"
                print("\(f.fingerprint.prefix(23))…  \(f.name)  (\(f.mapping.fields.count) fields; \(chart))")
                print("    session types: \(f.templates.map(\.name).joined(separator: ", "))")
            }
        case "add" where positional.count == 2:
            guard let profilePath = flags["profile"] else { throw ExtractCommands.UsageError(description: usage) }
            let decoder = JSONDecoder()
            let mapping = try decoder.decode(FormMapping.self, from: Data(contentsOf: URL(fileURLWithPath: positional[1])))
            let profile = try decoder.decode(FormProfile.self, from: Data(contentsOf: URL(fileURLWithPath: profilePath)))
            guard profile.fingerprint == mapping.profileFingerprint else {
                throw ExtractCommands.UsageError(description: "the profile (\(profile.fingerprint.prefix(19))…) isn't the one the mapping was made for (\(mapping.profileFingerprint.prefix(19))…)")
            }
            let templates = try flags["templates"].map {
                try decoder.decode([NoteTemplate].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
            } ?? []
            print(try library.install(LearnedForm(profile: profile, mapping: mapping, templates: templates)).path)
        case "rematch":
            guard let path = flags["profile"] else { throw ExtractCommands.UsageError(description: usage) }
            let new = try JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let old = library.forms().first(where: { $0.profile.origin == new.origin && $0.profile.pathPattern == new.pathPattern }) else {
                throw ExtractCommands.UsageError(description: "no learned form at \(new.origin)\(new.pathPattern)")
            }
            guard old.fingerprint != new.fingerprint else { print("unchanged: \(old.name)"); return }
            let drift = FormDrift.rematch(old, to: new)
            print("\(old.name): \(drift.summary)")
            for r in drift.renamed { print("  moved    \(r.old) → \(r.new)") }
            for k in drift.added { print("  new      \(k) (skip until mapped)") }
            for k in drift.removed { print("  removed  \(k)") }
            for k in drift.optionsChanged { print("  choices  \(k)") }
            if flags["yes"] != nil || positional.contains("--yes") {
                print(try library.replace(old.fingerprint, with: drift.form).path)
            } else {
                print("re-run with --yes to replace the learned form")
            }
        default:
            throw ExtractCommands.UsageError(description: usage)
        }
    }

    /// Form packs: what an agency lead publishes and workers import (BUILD_PLAN P3.4).
    static func packs(_ positional: [String], _ flags: [String: String]) throws {
        let library = FormLibrary()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        switch positional.first {
        case "export" where positional.count == 2:
            let pack = library.exportPack(name: flags["name"] ?? "Scribeski forms", version: flags["version"] ?? "1")
            try encoder.encode(pack).write(to: URL(fileURLWithPath: positional[1]))
            print("exported \(pack.forms.count) form(s) to \(positional[1])")
        case "import" where positional.count == 2:
            let pack = try JSONDecoder().decode(FormPack.self, from: Data(contentsOf: URL(fileURLWithPath: positional[1])))
            let n = try library.importPack(pack)
            print("imported \(n) form(s) from “\(pack.name)” v\(pack.version)")
        default:
            throw ExtractCommands.UsageError(description: usage)
        }
    }

    /// Fills a specific client's chart, wherever its tab is, from saved results: the app's
    /// fill path (locate → bring forward → re-profile → banner check in the page → write).
    static func fillChart(_ flags: [String: String]) async throws {
        guard let client = flags["client"], let resultsPath = flags["results"] else {
            throw ExtractCommands.UsageError(description: "usage: scribeski fill-chart --client <record id> --results <results.json> [--window <safari window id>]")
        }
        let finder = ChartFinder()
        let open = finder.candidates()
        let window = flags["window"].flatMap(Int.init)
        guard let target = open.first(where: { $0.binding.clientID == client && (window == nil || $0.tab.windowID == window) }),
              let form = finder.forms.form(fingerprint: target.binding.fingerprint) else {
            throw NotePipeline.Failure.chartNotOpen(ChartBinding(fingerprint: "", formName: "", clientID: client, clientName: nil))
        }
        let results = try JSONDecoder().decode([FieldResult].self, from: Data(contentsOf: URL(fileURLWithPath: resultsPath)))
        let extraction = NotePipeline.Extraction(pageTitle: form.name, profile: form.profile, results: results,
                                                 binding: target.binding)
        let outcome = try await NotePipeline(llm: try .fromModelStore()).fill(extraction, at: target)
        let notOK = outcome.reports.filter { $0.outcome != .ok && $0.outcome != .computedVerified }
        ExtractCommands.warn("""
            filled \(target.binding.display) in window \(target.tab.windowOrder) tab \(target.tab.tabIndex): \
            \(outcome.reports.count) written, \(notOK.count) not ok; identity \(outcome.identity)
            """)
    }

    /// Lists learned charts open in Safari. Reads every tab's URL, and banners only in tabs
    /// that are learned forms.
    static func charts() {
        let found = ChartFinder().candidates()
        if found.isEmpty { print("no learned chart is open in Safari") }
        for c in found {
            print("\(c.tab.isFront ? "*" : " ") window \(c.tab.windowOrder) tab \(c.tab.tabIndex)  \(c.binding.display)  (\(c.binding.formName))")
        }
    }
}
