import Foundation
import SuiteModelStore

/// Suite identity. Placeholders until the suite has a name and a Developer ID team; nothing
/// has shipped, so renaming is free until then.
enum Suite {
    static let name = "Looski"
    /// `<TEAMID>.looski` once the Developer ID team exists. Nil: dev fallback location.
    static let groupID: String? = nil
    static let appID = "scribeski"
    /// Roles Scribeski uses. VAD is built into the transcription engines.
    static let roles: [ModelRole] = [.llm, .asr, .diarizer]

    static var selectionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribeski/models.json")
    }
}

/// `scribeski models …`: inspect, choose, and fetch models in the shared store.
enum ModelsCommand {
    static let usage = """
    usage: scribeski models <subcommand>

      where                         where the shared store is, and why
      list                          the catalog, with defaults (*), your choices (>), and what's installed
      status                        what each role resolves to on this Mac
      pull [<id>…]                  download models (default: what each role resolves to)
      use <role> <catalog-id>       choose a catalog model for a role (llm, asr, diarizer)
      use <role> --path <file|dir> --format gguf|coreml|mlx [--name <text>] [--min-ram <GB>]
                                    use your own model (always marked NOT VALIDATED)
      reset <role>                  go back to the default
    """

    static func run(_ args: [String]) async throws {
        let location = ModelStore.resolveLocation(groupID: Suite.groupID, suiteName: Suite.name)
        let store = try ModelStore(location: location)
        let selections = SelectionStore(url: Suite.selectionURL)
        var selection = try selections.load()
        let (positional, flags) = parseFlags(Array(args.dropFirst()))

        switch args.first {
        case "where":
            print(location.root.path)
            print(location.reason)

        case "list":
            for m in store.catalog.models.sorted(by: { ($0.role.rawValue, $0.id) < ($1.role.rawValue, $1.id) }) {
                let isDefault = store.catalog.defaults[m.role] == m.id
                let chosen: Bool = if case .catalog(let id)? = selection[m.role] { id == m.id } else { false }
                let mark = (chosen ? ">" : " ") + (isDefault ? "*" : " ")
                let size = ByteCountFormatter.string(fromByteCount: m.files.reduce(0) { $0 + $1.size }, countStyle: .file)
                let installed = store.localURL(for: m) != nil ? "installed" : ""
                print("\(mark) \(m.role.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                    + "\(m.id.padding(toLength: 34, withPad: " ", startingAt: 0))"
                    + "\(size.padding(toLength: 10, withPad: " ", startingAt: 0))"
                    + "\(m.license.padding(toLength: 26, withPad: " ", startingAt: 0))"
                    + "\(m.validated ? "validated" : "not validated")  \(installed)")
            }
            print("\n* default   > your choice")

        case "status":
            for role in Suite.roles {
                let r = Resolver.resolve(role: role, selection: selection, catalog: store.catalog)
                print("\(role.rawValue): \(describe(r, store: store))")
            }

        case "pull":
            var manifests: [ModelManifest] = []
            if positional.isEmpty {
                for role in Suite.roles {
                    let r = Resolver.resolve(role: role, selection: selection, catalog: store.catalog)
                    if r.status != .ok { print("skipping \(role.rawValue): \(r.status.rawValue)"); continue }
                    if let m = r.manifest {
                        manifests.append(m)
                    } else if case .custom(let c)? = r.model, let m = c.manifest(role: role) {
                        manifests.append(m)
                    }
                }
            } else {
                for id in positional {
                    guard let m = store.catalog.model(id: id) else { throw CLIError("unknown model \(id)") }
                    manifests.append(m)
                }
            }
            // Register first: unregistered models are fair game for garbage collection.
            let registered = try store.registrations()
                .first { $0.appID == Suite.appID }?.models
                .compactMap { store.catalog.model(id: $0.id) } ?? []
            try await store.register(app: Suite.appID, models: Array(Set(registered + manifests)))
            for m in manifests {
                print("\(m.id): \(m.license)\(m.validated ? "" : " · not validated")")
                let url = try await store.ensure(m) { p in
                    guard p.phase == .downloading else { return }
                    FileHandle.standardError.write(Data("\r  \(Int(p.fractionCompleted * 100))%  \(p.path)   ".utf8))
                }
                FileHandle.standardError.write(Data("\n".utf8))
                print("  → \(url.path)")
            }

        case "use" where positional.count >= 1:
            guard let role = ModelRole(rawValue: positional[0]) else { throw CLIError("unknown role \(positional[0])") }
            if let path = flags["path"] {
                guard let format = flags["format"].flatMap(ModelFormat.init(rawValue:)) else {
                    throw CLIError("--format gguf|coreml|mlx is required with --path")
                }
                let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: absolute) else { throw CLIError("no such file: \(absolute)") }
                selection[role] = .custom(CustomModel(
                    displayName: flags["name"] ?? URL(fileURLWithPath: absolute).lastPathComponent,
                    format: format, source: .local(path: absolute), minRAMGB: flags["min-ram"].flatMap(Int.init)))
                print("WARNING: custom models have not passed Scribeski's accuracy checks. Results will be marked NOT VALIDATED.")
            } else if positional.count == 2 {
                guard let m = store.catalog.model(id: positional[1]) else { throw CLIError("unknown model \(positional[1])") }
                guard m.role == role else { throw CLIError("\(m.id) is a \(m.role.rawValue) model, not \(role.rawValue)") }
                selection[role] = .catalog(id: m.id)
            } else {
                throw CLIError(usage)
            }
            try FileManager.default.createDirectory(at: Suite.selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try selections.save(selection)
            print("\(role.rawValue): \(describe(Resolver.resolve(role: role, selection: selection, catalog: store.catalog), store: store))")

        case "reset" where positional.count == 1:
            guard let role = ModelRole(rawValue: positional[0]) else { throw CLIError("unknown role \(positional[0])") }
            selection[role] = nil
            try selections.save(selection)
            print("\(role.rawValue): \(describe(Resolver.resolve(role: role, selection: selection, catalog: store.catalog), store: store))")

        default:
            throw CLIError(usage)
        }
    }

    static func describe(_ r: Resolution, store: ModelStore) -> String {
        var parts: [String] = []
        switch r.model {
        case .catalog(let m)?:
            parts.append(m.id)
            parts.append(store.localURL(for: m) != nil ? "installed" : "not downloaded")
        case .custom(let c)?:
            parts.append("custom: \(c.displayName)")
        case nil:
            parts.append("none")
        }
        parts.append(r.origin == .userChoice ? "your choice" : "default")
        if !r.validated { parts.append("NOT VALIDATED") }
        if r.status != .ok {
            parts.append("\(r.status.rawValue) (needs \(r.requiredRAMGB ?? 0) GB, this Mac has \(Int(r.availableRAMGB.rounded())) GB)")
        }
        return parts.joined(separator: " · ")
    }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}
