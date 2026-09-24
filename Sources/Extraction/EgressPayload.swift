import ScribeskiCore

/// The only form-derived data that may leave the machine (DESIGN §6 step 5, BUILD_PLAN P1.4).
///
/// Per field: `key, kind, label, help, required, options [{value, label}], step`. Nothing
/// else: no origin or path, no selectors, no frame paths, no fingerprint, no write strategy.
/// The profile never carries values, and this type has nowhere to put one.
///
/// Fields decided in code are left out entirely (they never need the model): hidden and
/// page-computed fields (see `MappingPostProcessor`), and any keys the caller excludes, such
/// as fields that keep a hand-reviewed `--base` entry.
public struct EgressPayload: Hashable, Sendable {
    public enum Options: Hashable, Sendable {
        case list([FormProfile.Option])
        /// The option set changed between two page loads: possibly record-derived PHI.
        case withheld
    }

    public struct Field: Hashable, Sendable {
        public var key: String
        public var kind: FormProfile.Kind
        public var label: String
        public var help: String?
        public var required: Bool
        public var options: Options
        public var step: String

        public init(key: String, kind: FormProfile.Kind, label: String, help: String?, required: Bool,
                    options: Options, step: String) {
            self.key = key
            self.kind = kind
            self.label = label
            self.help = help
            self.required = required
            self.options = options
            self.step = step
        }

        public var optionList: [FormProfile.Option] {
            if case .list(let o) = options { o } else { [] }
        }
    }

    public var fields: [Field]

    public init(fields: [Field]) { self.fields = fields }

    /// Whether the model is never asked about this field: its mapping is decided in code.
    public static func decidedInCode(_ field: FormProfile.Field) -> Bool {
        field.computed || field.kind == .hidden
    }

    /// Builds the payload in profile order. `withheld` keys keep the field but drop its
    /// options; `excluding` keys are left out.
    public static func build(from profile: FormProfile, withheld: Set<String> = [],
                             excluding: Set<String> = []) -> EgressPayload {
        EgressPayload(fields: profile.fields.compactMap { f in
            guard !decidedInCode(f), !excluding.contains(f.key) else { return nil }
            return Field(key: f.key, kind: f.kind, label: f.label, help: f.help, required: f.required,
                         options: withheld.contains(f.key) ? .withheld : .list(f.options), step: f.step)
        })
    }

    /// Keys whose option set differs between two loads of the same form, in `profile` order.
    /// A dropdown filled from the client record (household members, staff) is PHI that no
    /// regex sees; the only structural tell is that it changes between records.
    public static func volatileOptionKeys(_ profile: FormProfile, _ other: FormProfile) -> [String] {
        let otherByKey = Dictionary(other.fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return profile.fields.compactMap { f in
            guard let g = otherByKey[f.key] else { return nil }
            guard !f.options.isEmpty || !g.options.isEmpty else { return nil }
            return Set(f.options) == Set(g.options) ? nil : f.key
        }
    }

    // MARK: - JSON

    /// Deterministic JSON: fields in profile order, fixed key order, `help` omitted when absent.
    public var json: JSONValue {
        .obj(["fields": .array(fields.map(\.json))])
    }

    public func json(keys: [String]) -> JSONValue {
        let wanted = Set(keys)
        return .obj(["fields": .array(fields.filter { wanted.contains($0.key) }.map(\.json))])
    }
}

extension EgressPayload.Field {
    public var json: JSONValue {
        var o = JSONObject()
        o["key"] = .string(key)
        o["kind"] = .string(kind.rawValue)
        o["label"] = .string(label)
        if let help { o["help"] = .string(help) }
        o["required"] = .bool(required)
        switch options {
        case .list(let list):
            o["options"] = .array(list.map { .obj(["value": .string($0.value), "label": .string($0.label)]) })
        case .withheld:
            o["options"] = "withheld"
        }
        o["step"] = .string(step)
        return .object(o)
    }
}
