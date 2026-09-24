/// A versioned schema tag, e.g. `"scribeski.form-profile/1"`.
///
/// Every contract document carries one as its `schema` field. Decoding fails if the tag
/// doesn't match, so a v2 document is never silently read as v1.
public protocol SchemaIdentifier: Sendable {
    static var id: String { get }
}

public struct SchemaTag<ID: SchemaIdentifier>: Codable, Hashable, Sendable {
    public init() {}

    public var id: String { ID.id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let found = try container.decode(String.self)
        guard found == ID.id else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected schema \(ID.id), found \(found)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ID.id)
    }
}

/// A field's value as the page stores it: one string, or the checked option values of a
/// checkbox group.
public enum FieldValue: Codable, Hashable, Sendable {
    case single(String)
    case multiple([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .single(s)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .multiple(let a): try container.encode(a)
        }
    }
}

/// Who spoke. Comes from track identity (mic vs. process tap), never from a model.
public enum Speaker: String, Codable, CodingKeyRepresentable, Hashable, Sendable, CaseIterable {
    case worker
    case client
}
