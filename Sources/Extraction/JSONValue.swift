import Foundation

/// An arbitrary JSON document with **ordered** object keys.
///
/// Used for JSON Schemas, request bodies, model output, and tolerant reads of scoring
/// files. `serialized()` is deterministic and preserves key order, so what goes on the wire
/// is byte-stable and the schema's property order (which llama.cpp's grammar follows) is
/// the order written here.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Builds an object from ordered pairs. Later duplicates replace earlier values in place.
    public static func obj(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var o = JSONObject()
        for (k, v) in pairs { o[k] = v }
        return .object(o)
    }

    public static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    public var isNull: Bool { self == .null }
    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }
}

/// A JSON object that remembers insertion order.
public struct JSONObject: Hashable, Sendable {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var entries: [(key: String, value: JSONValue)] { keys.map { ($0, storage[$0]!) } }
    public var isEmpty: Bool { keys.isEmpty }

    /// Equality ignores key order, as JSON does; serialization keeps it.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

// MARK: - Serialization

extension JSONValue {
    /// Compact, deterministic JSON text. Keys keep insertion order; non-ASCII is emitted as
    /// UTF-8, `/` is not escaped.
    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public func serializedData() -> Data { Data(serialized().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if !d.isFinite { out += "null" }
            else if d.rounded() == d && abs(d) < 1e15 { out += String(Int(d)) }
            else { out += "\(d)" }
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, (k, v)) in o.entries.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(k, into: &out)
                out += ":"
                v.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Parses JSON text. Object key order follows the source when Foundation preserves it,
    /// otherwise keys are sorted; nothing in this module depends on decoded key order.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var o = JSONObject()
            for key in keyed.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                o[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(o)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var a: [JSONValue] = []
            while !unkeyed.isAtEnd { a.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(a)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .object(let o):
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in o.entries { try c.encode(v, forKey: AnyKey(stringValue: k)) }
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        default:
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .array, .object: break
            }
        }
    }
}
