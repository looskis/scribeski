import AppKit
import Extraction
import FormDriver
import Orchestrator
import ScribeskiCore
import SwiftUI

/// "Learn a form" (BUILD_PLAN P3.4): read the front tab → pick the client banner → preview
/// what the mapping model gets → generate → review → save.
public struct LearnView: View {
    public static let windowID = "learn"
    @Bindable var model: LearnModel

    public init(model: LearnModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            steps.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.step {
                    case .read: read
                    case .banner: banner
                    case .mapping: mapping
                    case .review: review
                    case .saved: saved
                    }
                    if let busy = model.busy {
                        HStack { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle("Learn a form")
    }

    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Read", "Client banner", "Mapping", "Review", "Saved"].enumerated()), id: \.offset) { i, name in
                Text("\(i + 1). \(name)")
                    .font(.caption.weight(model.step.rawValue == i ? .semibold : .regular))
                    .foregroundStyle(model.step.rawValue >= i ? .primary : .tertiary)
                if i < 4 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    // MARK: - 1 Read

    @ViewBuilder private var read: some View {
        Text("Open the form in Safari on any client's chart. Scribeski reads the form's structure: labels, field types, and choices. Never the values in it.")
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField("Paste the form's address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.readAddress() } }
            Button("Paste") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    model.address = s
                    Task { await model.readAddress() }
                }
            }
            Button("Read") { Task { await model.readAddress() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.address.isEmpty || model.busy != nil)
        }
        if let url = model.addressToOpen {
            HStack {
                Text("\(url.host() ?? "That page") isn't open in Safari.").foregroundStyle(.secondary)
                Button("Open it in Safari") { Task { await model.openAddress() } }
            }
            .font(.callout)
        }
        HStack {
            Text("or").foregroundStyle(.secondary)
            Button("Read the tab in front") { Task { await model.readFrontTab() } }
                .disabled(model.busy != nil)
        }
        .font(.callout)
        if let p = model.profile, let tab = model.tab {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tab.title).font(.headline)
                    Text(p.origin + p.pathPattern).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("\(p.fields.count) fields across \(max(p.steps.count, 1)) step\(p.steps.count == 1 ? "" : "s")")
                    if let warning = model.unreachableWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.alreadyLearned {
                Label("Already learned, and unchanged. Nothing to do.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let drift = model.drift {
                Label("Learned before; it has changed since: \(drift.summary).", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Keep the reviewed mapping and update") { model.acceptDrift() }.buttonStyle(.borderedProminent)
                    Button("Map the new fields…") { model.step = .banner }
                }
            } else {
                Button("Next: the client banner") { model.step = .banner }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 2 Banner

    @ViewBuilder private var banner: some View {
        Text("Which part of the page says whose chart this is? Scribeski checks it before every fill, so a note can't land in another client's chart.")
            .fixedSize(horizontal: false, vertical: true)
        if model.banners.isEmpty {
            Text("Nothing on the page looks like a client banner. You can still save the form, but fills won't be checked against the client.")
                .foregroundStyle(.orange).font(.callout)
        }
        ForEach(model.banners, id: \.selector) { b in
            Button { model.chooseBanner(b.selector) } label: {
                HStack(alignment: .top) {
                    Image(systemName: model.bannerSelector == b.selector ? "largecircle.fill.circle" : "circle")
                    VStack(alignment: .leading) {
                        Text(b.text)
                        Text(b.selector).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        if model.bannerSelector != nil {
            GroupBox("How to read it") {
                Grid(alignment: .leading) {
                    GridRow { Text("Record ID"); TextField("pattern", text: $model.idPattern).font(.body.monospaced()) }
                    GridRow { Text("Name"); TextField("pattern (optional)", text: $model.namePattern).font(.body.monospaced()) }
                }
                if let p = model.bannerPreview {
                    Label("Reads: \(p.id)\(p.name.map { " · \($0)" } ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("These patterns don't find a record ID in that text.", systemImage: "xmark.circle").foregroundStyle(.red)
                }
            }
        }
        HStack {
            Button("Back") { model.step = .read }
            Spacer()
            Button("Next: the mapping") {
                model.preparePayload()
                model.step = .mapping
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.bannerSelector != nil && model.bannerPreview == nil)
        }
    }

    // MARK: - 3 Mapping

    @ViewBuilder private var mapping: some View {
        Text("A language model reads the form's labels and choices and proposes what each field means. This is exactly what it gets. It runs on this Mac: nothing leaves it.")
            .fixedSize(horizontal: false, vertical: true)
        Label(model.scrubOK ? "Checked: no names, numbers, or dates that look like client data." : "Refused: the form's labels look like they contain client data.",
              systemImage: model.scrubOK ? "checkmark.shield.fill" : "xmark.shield.fill")
            .foregroundStyle(model.scrubOK ? .green : .red)
        GroupBox("Sent to the model") {
            ScrollView(.vertical) {
                Text(model.payloadText).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
        if !model.scrubOK {
            Text(model.scrubReport).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        HStack {
            Button("Back") { model.step = .banner }
            Spacer()
            Button("Generate the mapping") { Task { await model.generate() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.scrubOK || model.busy != nil)
        }
    }

    // MARK: - 4 Review

    @ViewBuilder private var review: some View {
        TextField("Form name", text: $model.formName).textFieldStyle(.roundedBorder)
        Text("Check what each field means. Scribeski only fills fields marked “from the session”; “yours” fields are always left for you.")
            .font(.callout).foregroundStyle(.secondary)
        if let p = model.profile, model.mapping != nil {
            ForEach(p.fields.filter { $0.kind != .hidden }, id: \.key) { f in
                MappingRow(model: model, field: f)
                Divider()
            }
        }
        HStack {
            Button("Back") { model.step = .mapping }
            Spacer()
            Button("Save the form") { model.save() }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 5 Saved

    @ViewBuilder private var saved: some View {
        Label("Saved. Sessions can now fill “\(model.formName)”.", systemImage: "checkmark.seal.fill")
            .font(.headline).foregroundStyle(.green)
        Text("To share it with your team, export a form pack: scribeski packs export.").font(.callout).foregroundStyle(.secondary)
    }
}

/// One field's mapping, editable.
private struct MappingRow: View {
    @Bindable var model: LearnModel
    let field: FormProfile.Field

    private var entry: Binding<FormMapping.FieldMapping> {
        Binding(get: { model.mapping?.fields[field.key] ?? .init(intent: "", mode: .skip, evidenceSpeaker: .any) },
                set: { model.mapping?.fields[field.key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label.isEmpty ? field.key : field.label).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if entry.wrappedValue.mode == .derived {
                    Text("calculated").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: entry.mode) {
                        Text("from the session").tag(FormMapping.Mode.discrete)
                        Text("written summary").tag(FormMapping.Mode.narrative)
                        Text("yours").tag(FormMapping.Mode.clinicianOnly)
                        Text("skip").tag(FormMapping.Mode.skip)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if entry.wrappedValue.mode == .discrete || entry.wrappedValue.mode == .narrative {
                TextField("What belongs here", text: entry.intent, axis: .vertical).font(.caption).lineLimit(1...3)
                Picker("Who says it", selection: entry.evidenceSpeaker) {
                    Text("the client").tag(FormMapping.EvidenceSpeaker.client)
                    Text("you").tag(FormMapping.EvidenceSpeaker.worker)
                    Text("either").tag(FormMapping.EvidenceSpeaker.any)
                }
                .pickerStyle(.segmented).font(.caption).fixedSize()
            }
        }
    }
}
