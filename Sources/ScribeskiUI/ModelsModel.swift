import Foundation
import Observation
import SuiteModelStore

/// Settings → Models (BUILD_PLAN P4.2): what each role uses, whether it's on this Mac, and
/// downloading it with progress. Catalog models are pinned by hash; a custom model is marked
/// "not validated" everywhere it's used.
@MainActor @Observable public final class ModelsModel {
    public struct Row: Identifiable, Sendable {
        public var id: ModelRole { role }
        public var role: ModelRole
        public var name: String
        public var license: String?
        public var sizeBytes: Int64?
        public var installed: Bool
        public var validated: Bool
        public var custom: Bool
        public var problem: String?
        public var options: [ModelManifest]
        public var selectedID: String?
    }

    public var rows: [Row] = []
    public var progress: [ModelRole: Double] = [:]
    public var error: String?
    public var freeBytes: Int64?

    @ObservationIgnored private var locator: ModelLocator?
    public static let roles: [ModelRole] = [.llm, .asr]

    public init() {}

    public func refresh() {
        do {
            let locator = try ModelLocator(appName: "Scribeski", appID: "scribeski")
            self.locator = locator
            freeBytes = ModelStore.volumeAvailableCapacity(locator.store.root)
            rows = Self.roles.map { role in
                let r = locator.resolution(role)
                var row = Row(role: role, name: locator.name(role) ?? "none", license: nil, sizeBytes: nil,
                              installed: locator.localURL(role) != nil, validated: r.validated, custom: r.isCustom,
                              problem: nil, options: locator.store.catalog.models.filter { $0.role == role }, selectedID: nil)
                if case .catalog(let m)? = r.model {
                    row.name = m.displayName
                    row.license = m.license
                    row.sizeBytes = m.totalSize
                    row.selectedID = m.id
                }
                switch r.status {
                case .ok: break
                case .insufficientRAM: row.problem = "Needs \(r.requiredRAMGB ?? 0) GB of memory; this Mac has \(Int(r.availableRAMGB))."
                case .unknownModel: row.problem = "The chosen model isn't in this version's catalog."
                case .roleMismatch: row.problem = "The chosen model is for a different job."
                case .noDefault: row.problem = "No default model for this."
                }
                return row
            }
        } catch {
            self.error = "\(error)"
        }
    }

    public func choose(_ role: ModelRole, catalogID: String) {
        update { $0[role] = .catalog(id: catalogID) }
    }

    /// A model the worker supplies: always shown as not validated.
    public func useCustom(_ role: ModelRole, at url: URL) {
        let format: ModelFormat = url.pathExtension == "gguf" ? .gguf : .coreml
        update { $0[role] = .custom(CustomModel(displayName: url.lastPathComponent, format: format, source: .local(path: url.path))) }
    }

    public func useDefault(_ role: ModelRole) {
        update { $0[role] = nil }
    }

    private func update(_ change: (inout ModelSelection) -> Void) {
        guard let locator else { return }
        do {
            var s = try locator.selections.load()
            change(&s)
            try locator.selections.save(s)
            refresh()
        } catch {
            self.error = "\(error)"
        }
    }

    /// Downloads (resumable, hash-checked) with progress.
    public func download(_ role: ModelRole) async {
        guard let locator, progress[role] == nil else { return }
        progress[role] = 0
        error = nil
        defer { progress[role] = nil; refresh() }
        do {
            for try await event in locator.ensure(role) {
                if case .progress(let p) = event { progress[role] = p.fractionCompleted }
            }
        } catch {
            self.error = "\(error)"
        }
    }

    /// Everything a session needs is on this Mac.
    public var ready: Bool { !rows.isEmpty && rows.allSatisfy { $0.installed && $0.problem == nil } }
}
