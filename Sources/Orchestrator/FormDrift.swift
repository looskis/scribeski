import Foundation
import ScribeskiCore

/// The form changed since it was learned (an EHR update): its live profile's fingerprint no
/// longer matches. Rather than re-learn from scratch, carry the reviewed mapping across and
/// show the worker what moved (BUILD_PLAN P3.4, agreed 2026-09-23).
public struct FormDrift: Sendable {
    /// Same key and kind: mapping carried as is.
    public var kept: [String] = []
    /// Key changed, but the label, kind, and options match an old field: mapping carried over.
    public var renamed: [Rename] = []
    /// No old field matches: set to `skip` until mapped, so it's never filled on a guess.
    public var added: [String] = []
    /// Old fields the form no longer has.
    public var removed: [String] = []
    /// Choice fields whose options changed: the mapping is carried, but option notes that
    /// refer to vanished options are dropped. Worth a look.
    public var optionsChanged: [String] = []
    /// The learned form, re-based on the new profile. Install it once the worker accepts.
    public var form: LearnedForm

    public struct Rename: Hashable, Sendable {
        public var old: String
        public var new: String
    }

    /// Nothing that needs a person: keys moved or options shifted, but every field is mapped.
    public var isTrivial: Bool { added.isEmpty && removed.isEmpty && optionsChanged.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !renamed.isEmpty { parts.append("\(renamed.count) moved") }
        if !added.isEmpty { parts.append("\(added.count) new (left blank until mapped)") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        if !optionsChanged.isEmpty { parts.append("\(optionsChanged.count) with changed choices") }
        return parts.isEmpty ? "No field changes" : parts.joined(separator: ", ")
    }

    public static func rematch(_ old: LearnedForm, to new: FormProfile) -> FormDrift {
        let oldFields = Dictionary(uniqueKeysWithValues: old.profile.fields.map { ($0.key, $0) })
        var unmatchedOld = Set(oldFields.keys)
        var mapping = FormMapping(profileFingerprint: new.fingerprint, fields: [:], name: old.mapping.name,
                                  chart: old.mapping.chart)
        var drift = FormDrift(form: old)
        var renames: [String: String] = [:]

        func carry(_ m: FormMapping.FieldMapping, to f: FormProfile.Field, from o: FormProfile.Field) -> FormMapping.FieldMapping {
            var m = m
            let values = Set(f.options.map(\.value))
            if values != Set(o.options.map(\.value)) {
                drift.optionsChanged.append(f.key)
                m.optionSemantics = m.optionSemantics?.filter { values.contains($0.key) }
                m.excludeOptions = m.excludeOptions?.filter(values.contains)
                m.perMonthBands = m.perMonthBands?.filter { values.contains($0.key) }
            }
            return m
        }

        // Pass 1: same key, same kind.
        var pending: [FormProfile.Field] = []
        for f in new.fields {
            if let o = oldFields[f.key], o.kind == f.kind, let m = old.mapping.fields[f.key] {
                mapping.fields[f.key] = carry(m, to: f, from: o)
                drift.kept.append(f.key)
                unmatchedOld.remove(f.key)
            } else {
                pending.append(f)
            }
        }
        // Pass 2: a moved field keeps its label, kind, and (for choices) its options.
        for f in pending {
            let match = unmatchedOld.sorted().first { key in
                guard let o = oldFields[key], o.kind == f.kind, normalize(o.label) == normalize(f.label) else { return false }
                return f.options.isEmpty || Set(o.options.map(\.value)) == Set(f.options.map(\.value))
            }
            if let key = match, let o = oldFields[key], let m = old.mapping.fields[key] {
                mapping.fields[f.key] = carry(m, to: f, from: o)
                drift.renamed.append(.init(old: key, new: f.key))
                renames[key] = f.key
                unmatchedOld.remove(key)
            } else {
                mapping.fields[f.key] = .init(intent: "New field since this form was learned; not mapped yet.",
                                              mode: .skip, evidenceSpeaker: .any)
                drift.added.append(f.key)
            }
        }
        drift.removed = unmatchedOld.sorted()

        // Derivations and templates follow renamed keys.
        for (key, var m) in mapping.fields {
            if var d = m.derive {
                d.inputs = d.inputs.map { renames[$0] ?? $0 }
                m.derive = d
                mapping.fields[key] = m
            }
        }
        let templates = old.templates.map { t in
            var t = t
            t.fields = Dictionary(uniqueKeysWithValues: t.fields.compactMap { key, o in
                let k = renames[key] ?? key
                return new.fields.contains { $0.key == k } ? (k, o) : nil
            })
            return t
        }
        drift.form = LearnedForm(profile: new, mapping: mapping, templates: templates)
        return drift
    }

    /// Labels compare without case, punctuation at the ends, required-markers, or extra spaces.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
