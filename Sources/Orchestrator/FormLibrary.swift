import Foundation
import ScribeskiCore

/// A form Scribeski can fill: its structure (profile, no values), what each field means
/// (mapping), and how to find it and tell whose chart it is (`mapping.chart`).
public struct LearnedForm: Sendable, Hashable {
    public var profile: FormProfile
    public var mapping: FormMapping
    /// Session types for this form (Intake, Follow-up…). Never empty: `[.standard]` if none.
    public var templates: [NoteTemplate]

    public init(profile: FormProfile, mapping: FormMapping, templates: [NoteTemplate] = []) {
        self.profile = profile
        self.mapping = mapping
        self.templates = templates.isEmpty ? [.standard] : templates
    }

    public func template(_ id: String?) -> NoteTemplate {
        templates.first { $0.id == id } ?? templates[0]
    }

    public var fingerprint: String { mapping.profileFingerprint }
    public var name: String { mapping.name ?? profile.origin + profile.pathPattern }
}

/// Learned forms (BUILD_PLAN P3.4 writes these; `scribeski forms add` installs one by hand),
/// one pair of files per form: `<id>.mapping.json` and `<id>.profile.json`. Found by the
/// fingerprint of a page's live profile, or by URL through `mapping.chart`.
public struct FormLibrary: Sendable {
    public let directory: URL

    public init(directory: URL = FormLibrary.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribeski/forms", isDirectory: true)
    }

    public func forms() -> [LearnedForm] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.lastPathComponent.hasSuffix(".mapping.json") }.compactMap { url in
            func sibling(_ suffix: String) -> URL {
                URL(fileURLWithPath: url.path.replacingOccurrences(of: ".mapping.json", with: suffix))
            }
            guard let mapping = try? decoder.decode(FormMapping.self, from: Data(contentsOf: url)),
                  let profile = try? decoder.decode(FormProfile.self, from: Data(contentsOf: sibling(".profile.json"))) else { return nil }
            let templates = (try? decoder.decode([NoteTemplate].self, from: Data(contentsOf: sibling(".templates.json")))) ?? []
            return LearnedForm(profile: profile, mapping: mapping, templates: templates)
        }
        .sorted { $0.name < $1.name }
    }

    public func form(fingerprint: String) -> LearnedForm? {
        forms().first { $0.fingerprint == fingerprint }
    }

    public func mapping(for fingerprint: String) -> FormMapping? {
        form(fingerprint: fingerprint)?.mapping
    }

    /// The learned form a tab's URL points at, if any.
    public func form(forURL url: String) -> LearnedForm? {
        forms().first { $0.mapping.chart?.matches(url) == true }
    }

    /// Stores a form, replacing any earlier one with the same fingerprint.
    @discardableResult
    public func install(_ form: LearnedForm) throws -> URL {
        precondition(form.profile.fingerprint == form.mapping.profileFingerprint, "profile and mapping disagree")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = form.fingerprint.replacingOccurrences(of: "sha256:", with: "").prefix(16)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = directory.appendingPathComponent("\(id).mapping.json")
        try encoder.encode(form.mapping).write(to: url, options: .atomic)
        try encoder.encode(form.profile).write(to: directory.appendingPathComponent("\(id).profile.json"), options: .atomic)
        try encoder.encode(form.templates).write(to: directory.appendingPathComponent("\(id).templates.json"), options: .atomic)
        return url
    }

    /// Replaces a learned form with its re-matched successor (after the EHR changed it).
    @discardableResult
    public func replace(_ old: String, with form: LearnedForm) throws -> URL {
        let prefix = old.replacingOccurrences(of: "sha256:", with: "").prefix(16)
        for suffix in [".mapping.json", ".profile.json", ".templates.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(prefix)\(suffix)"))
        }
        return try install(form)
    }

    // MARK: - Form packs

    /// Installs every form in a pack, replacing same-fingerprint forms. Returns how many.
    @discardableResult
    public func importPack(_ pack: FormPack) throws -> Int {
        for e in pack.forms {
            guard e.profile.fingerprint == e.mapping.profileFingerprint else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey:
                    "\(e.mapping.name ?? "a form") in “\(pack.name)” has a profile and mapping that disagree"])
            }
            try install(LearnedForm(profile: e.profile, mapping: e.mapping, templates: e.templates))
        }
        return pack.forms.count
    }

    public func exportPack(name: String, version: String) -> FormPack {
        FormPack(name: name, version: version,
                 forms: forms().map { FormPack.Entry(profile: $0.profile, mapping: $0.mapping, templates: $0.templates) })
    }
}
