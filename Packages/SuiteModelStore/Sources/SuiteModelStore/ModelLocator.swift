import Foundation

/// One app's view of the shared store: its model choices (a per-app selection file), what
/// each role resolves to, where that model is on disk, and fetching it. Every consumer in an
/// app (the UI, its CLI, its runtimes) goes through this, so they all load the same model.
public struct ModelLocator: Sendable {
    public let store: ModelStore
    public let selections: SelectionStore
    public let appID: String

    /// `appName` names the app's Application Support folder, where its selection file lives.
    public init(appName: String, appID: String, suiteName: String = "Looski", groupID: String? = nil) throws {
        store = try ModelStore(location: ModelStore.resolveLocation(groupID: groupID, suiteName: suiteName))
        selections = SelectionStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/models.json"))
        self.appID = appID
    }

    public func resolution(_ role: ModelRole) -> Resolution {
        Resolver.resolve(role: role, selection: (try? selections.load()) ?? ModelSelection(), catalog: store.catalog)
    }

    /// Where to load `role`'s model from: a catalog snapshot directory, or the custom path.
    /// Nil until it's been downloaded (or if the custom path is gone).
    public func localURL(_ role: ModelRole) -> URL? {
        let r = resolution(role)
        switch r.model {
        case .custom(let c)?:
            if case .local(let path) = c.source { return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
            return r.manifest.flatMap(store.localURL(for:))
        case .catalog(let m)?:
            return store.localURL(for: m)
        case nil:
            return nil
        }
    }

    /// A short name for what `role` resolves to, e.g. the catalog id or the custom model's name.
    public func name(_ role: ModelRole) -> String? {
        switch resolution(role).model {
        case .catalog(let m)?: m.id
        case .custom(let c)?: c.displayName
        case nil: nil
        }
    }

    /// Downloads (or verifies) `role`'s model, reporting progress. Registers it for this app so
    /// the store's garbage collector keeps it.
    public func ensure(_ role: ModelRole) -> AsyncThrowingStream<EnsureEvent, Error> {
        let r = resolution(role)
        guard let manifest = r.manifest else {
            return AsyncThrowingStream { $0.finish(throwing: ModelStoreError.invalidManifest("nothing to download for \(role.rawValue)")) }
        }
        let store = store, appID = appID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Register first: unregistered models are fair game for garbage collection.
                    let registered = (try? store.registrations().first { $0.appID == appID }?.models
                        .compactMap { store.catalog.model(id: $0.id) }) ?? []
                    try await store.register(app: appID, models: Array(Set(registered + [manifest])))
                    for try await event in store.ensureStream(manifest) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
