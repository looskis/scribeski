import Foundation

/// A model the user supplied themselves. Always `validated == false`: it has not passed the
/// owning app's evaluation gates, and the app should warn and audit-log its use.
public struct CustomModel: Codable, Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A file or directory already on disk. Not managed (or garbage-collected) by the store.
        case local(path: String)
        /// A single remote file, pinned by content. Fetched through the store like any other blob.
        case remote(url: URL, sha256: String, size: Int64)
    }

    public var displayName: String
    public var format: ModelFormat
    public var source: Source
    /// Optional; when set, the resolver applies the same RAM check as for catalog models.
    public var minRAMGB: Int?

    /// Always false. Present so callers can treat catalog and custom resolutions uniformly.
    public var validated: Bool { false }

    public init(displayName: String, format: ModelFormat, source: Source, minRAMGB: Int? = nil) {
        self.displayName = displayName
        self.format = format
        self.source = source
        self.minRAMGB = minRAMGB
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case format
        case localPath = "local_path"
        case url, sha256, size
        case minRAMGB = "min_ram_gb"
        case validated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        format = try c.decode(ModelFormat.self, forKey: .format)
        minRAMGB = try c.decodeIfPresent(Int.self, forKey: .minRAMGB)
        if let path = try c.decodeIfPresent(String.self, forKey: .localPath) {
            source = .local(path: path)
        } else {
            source = .remote(
                url: try c.decode(URL.self, forKey: .url),
                sha256: try c.decode(String.self, forKey: .sha256).lowercased(),
                size: try c.decode(Int64.self, forKey: .size))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(minRAMGB, forKey: .minRAMGB)
        switch source {
        case let .local(path):
            try c.encode(path, forKey: .localPath)
        case let .remote(url, sha256, size):
            try c.encode(url, forKey: .url)
            try c.encode(sha256, forKey: .sha256)
            try c.encode(size, forKey: .size)
        }
        try c.encode(false, forKey: .validated)
    }

    /// For `.remote` models: a manifest the store can `ensure`/`register`. Nil for `.local`.
    public func manifest(role: ModelRole) -> ModelManifest? {
        guard case let .remote(url, sha256, size) = source else { return nil }
        let name = url.lastPathComponent
        let path = ModelManifest.isSafeComponent(name) ? name : "model.\(format.rawValue)"
        return ModelManifest(
            id: "custom-\(sha256.prefix(16))", displayName: displayName, role: role, format: format,
            source: url.host(), revision: "sha256-\(sha256)", license: "unknown (user-supplied)",
            minRAMGB: minRAMGB ?? 0,
            files: [ModelFile(path: path, url: url, sha256: sha256, size: size)],
            notes: "User-supplied custom model; has not passed the app's evaluation gates.",
            validated: false)
    }
}

/// One role's choice: a catalog id or a custom model.
public enum ModelChoice: Codable, Sendable, Hashable {
    case catalog(id: String)
    case custom(CustomModel)

    enum CodingKeys: String, CodingKey { case kind, id, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "catalog": self = .catalog(id: try c.decode(String.self, forKey: .id))
        case "custom": self = .custom(try c.decode(CustomModel.self, forKey: .model))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .catalog(id):
            try c.encode("catalog", forKey: .kind)
            try c.encode(id, forKey: .id)
        case let .custom(model):
            try c.encode("custom", forKey: .kind)
            try c.encode(model, forKey: .model)
        }
    }
}

/// An app's per-role model choices. Roles without a choice use the catalog default.
public struct ModelSelection: Codable, Sendable, Hashable {
    public var choices: [ModelRole: ModelChoice]

    public init(choices: [ModelRole: ModelChoice] = [:]) { self.choices = choices }

    public subscript(role: ModelRole) -> ModelChoice? {
        get { choices[role] }
        set { choices[role] = newValue }
    }
}

/// Persists a `ModelSelection` as JSON at a URL the app chooses (the store doesn't decide where
/// each app keeps its settings).
public struct SelectionStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// An empty selection (all defaults) if the file doesn't exist yet.
    public func load() throws -> ModelSelection {
        guard FileManager.default.fileExists(atPath: url.path) else { return ModelSelection() }
        return try JSONDecoder().decode(ModelSelection.self, from: Data(contentsOf: url))
    }

    public func save(_ selection: ModelSelection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(selection).write(to: url, options: .atomic)
    }
}
