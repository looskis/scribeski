import Foundation

/// A session type for one form: Intake, Follow-up, Crisis… (BUILD_PLAN P3.4, agreed
/// 2026-09-23). A thin override of the form's base mapping, so one learned form serves every
/// kind of session without re-learning. Agency leads write these; workers only pick one.
public struct NoteTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Per-field changes to the base mapping. Fields not listed keep the base mapping.
    public var fields: [String: FieldOverride]

    public init(id: String, name: String, fields: [String: FieldOverride] = [:]) {
        self.id = id
        self.name = name
        self.fields = fields
    }

    public struct FieldOverride: Codable, Hashable, Sendable {
        /// e.g. `skip` for demographics already on file at a follow-up.
        public var mode: FormMapping.Mode?
        /// e.g. "What changed since the last session about …".
        public var intent: String?
        /// A value already on file may be replaced, but only as a proposed change the worker
        /// accepts in review. Without this, a field that already has a value is never touched.
        public var update: Bool?

        public init(mode: FormMapping.Mode? = nil, intent: String? = nil, update: Bool? = nil) {
            self.mode = mode
            self.intent = intent
            self.update = update
        }
    }

    /// The base mapping with this template's overrides applied.
    public func apply(to base: FormMapping) -> FormMapping {
        var m = base
        for (key, o) in fields {
            guard var f = m.fields[key] else { continue }
            if let mode = o.mode { f.mode = mode }
            if let intent = o.intent { f.intent = intent }
            m.fields[key] = f
        }
        return m
    }

    /// Fields whose on-file value this template may propose to change.
    public var updatable: Set<String> { Set(fields.filter { $0.value.update == true }.map(\.key)) }

    /// The base mapping as is: what a form uses when it has no templates.
    public static let standard = NoteTemplate(id: "standard", name: "Standard")
}

/// A shareable bundle of learned forms and their templates (BUILD_PLAN P3.4). An agency lead
/// learns each form once and publishes a pack; workers import it. No client data: profiles
/// are structure only, mappings describe meaning.
public struct FormPack: Codable, Hashable, Sendable {
    public enum Schema: SchemaIdentifier { public static let id = "scribeski.form-pack/1" }

    public var schema = SchemaTag<Schema>()
    public var name: String
    public var version: String
    public var forms: [Entry]

    public init(name: String, version: String, forms: [Entry]) {
        self.name = name
        self.version = version
        self.forms = forms
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var profile: FormProfile
        public var mapping: FormMapping
        public var templates: [NoteTemplate]

        public init(profile: FormProfile, mapping: FormMapping, templates: [NoteTemplate]) {
            self.profile = profile
            self.mapping = mapping
            self.templates = templates
        }
    }
}
