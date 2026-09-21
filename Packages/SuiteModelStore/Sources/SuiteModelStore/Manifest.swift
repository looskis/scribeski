import Foundation

/// What a model is used for. Raw values are the JSON spelling.
public enum ModelRole: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case llm
    case asr
    case diarizer
    case vad
}

/// On-disk format of a model. Raw values are the JSON spelling.
public enum ModelFormat: String, Codable, Sendable, CaseIterable {
    case gguf
    case coreml
    case mlx
}

/// One file of a model, pinned by content.
public struct ModelFile: Codable, Sendable, Hashable {
    /// Path relative to the model's snapshot directory (e.g. `Encoder.mlmodelc/weights/weight.bin`).
    public var path: String
    /// Where to fetch it. For catalog entries this always contains the pinned revision.
    public var url: URL
    /// Lower-case hex SHA-256 of the file's bytes.
    public var sha256: String
    /// Exact byte size.
    public var size: Int64

    public init(path: String, url: URL, sha256: String, size: Int64) {
        self.path = path
        self.url = url
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

/// A pinned, fully specified model: every byte is named by a SHA-256.
public struct ModelManifest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var role: ModelRole
    public var format: ModelFormat
    /// Upstream repository (informational), e.g. `google/gemma-4-26B-A4B-it-qat-q4_0-gguf`.
    public var source: String?
    /// Pinned upstream revision (a commit sha for Hugging Face). Never a moving ref like `main`.
    public var revision: String
    /// SPDX id where one exists, otherwise the license's name.
    public var license: String
    public var licenseURL: URL?
    public var minRAMGB: Int
    public var files: [ModelFile]
    public var notes: String?
    /// True only once the model has passed the owning app's evaluation gates.
    public var validated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case role, format, source, revision, license
        case licenseURL = "license_url"
        case minRAMGB = "min_ram_gb"
        case files, notes, validated
    }

    public init(
        id: String, displayName: String, role: ModelRole, format: ModelFormat,
        source: String? = nil, revision: String, license: String, licenseURL: URL? = nil,
        minRAMGB: Int, files: [ModelFile], notes: String? = nil, validated: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.format = format
        self.source = source
        self.revision = revision
        self.license = license
        self.licenseURL = licenseURL
        self.minRAMGB = minRAMGB
        self.files = files
        self.notes = notes
        self.validated = validated
    }

    /// Sum of all file sizes.
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Name of this model's snapshot directory: `<id>@<revision>`.
    public var snapshotName: String { "\(id)@\(revision)" }

    /// Rejects manifests that could escape the store or can't be verified. Called by the store
    /// before touching disk, so a hostile manifest (e.g. a user-supplied custom model) can't
    /// write outside `snapshots/<id>@<rev>/`.
    public func validate() throws {
        guard Self.isSafeComponent(id) else { throw ModelStoreError.invalidManifest("unsafe model id '\(id)'") }
        guard Self.isSafeComponent(revision) else {
            throw ModelStoreError.invalidManifest("unsafe revision '\(revision)' for \(id)")
        }
        guard !files.isEmpty else { throw ModelStoreError.invalidManifest("\(id) has no files") }
        var seen = Set<String>()
        for file in files {
            guard Self.isSafeRelativePath(file.path) else {
                throw ModelStoreError.invalidManifest("unsafe file path '\(file.path)' in \(id)")
            }
            guard seen.insert(file.path).inserted else {
                throw ModelStoreError.invalidManifest("duplicate file path '\(file.path)' in \(id)")
            }
            guard Self.isSHA256Hex(file.sha256) else {
                throw ModelStoreError.invalidManifest("bad sha256 for \(file.path) in \(id)")
            }
            guard file.size >= 0 else { throw ModelStoreError.invalidManifest("negative size for \(file.path)") }
            guard file.url.scheme?.lowercased() == "https" else {
                throw ModelStoreError.invalidManifest("model files download over HTTPS only: \(file.path) in \(id)")
            }
        }
        // A file path must not also be a directory prefix of another (`a` and `a/b`).
        for path in seen where seen.contains(where: { $0.hasPrefix(path + "/") }) {
            throw ModelStoreError.invalidManifest("path '\(path)' is both a file and a directory in \(id)")
        }
    }

    static func isSafeComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 200, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-+".unicodeScalars.contains($0)
        }
    }

    static func isSafeRelativePath(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("/"), !s.hasSuffix("/") else { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            let c = String($0)
            return !c.isEmpty && c != "." && c != ".." && !c.contains("\0") && !c.contains("\\")
        }
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }
}

/// A set of pinned manifests plus the default model id for each role.
public struct Catalog: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    /// Date the catalog was last re-pinned (informational).
    public var pinnedAt: String?
    public var defaults: [ModelRole: String]
    public var models: [ModelManifest]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pinnedAt = "pinned_at"
        case defaults, models
    }

    public init(schemaVersion: Int = 1, pinnedAt: String? = nil, defaults: [ModelRole: String], models: [ModelManifest]) {
        self.schemaVersion = schemaVersion
        self.pinnedAt = pinnedAt
        self.defaults = defaults
        self.models = models
    }

    public func model(id: String) -> ModelManifest? { models.first { $0.id == id } }

    public func models(for role: ModelRole) -> [ModelManifest] { models.filter { $0.role == role } }

    public func defaultModel(for role: ModelRole) -> ModelManifest? {
        defaults[role].flatMap { model(id: $0) }
    }

    /// The catalog shipped inside this package (`Resources/catalog.json`), generated by
    /// `scripts/pin-catalog.sh`.
    public static func builtIn() throws -> Catalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            throw ModelStoreError.invalidManifest("catalog.json missing from bundle")
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: data)
    }
}
