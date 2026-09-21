import AppKit
import Orchestrator
import ScribeskiCore
import SwiftUI

/// Which fields the review list shows.
public enum ReviewFilter: String, CaseIterable, Sendable {
    case attention = "Needs you", all = "All", filled = "Filled", blank = "Blank"
}

/// What the worker should know about one field (BUILD_PLAN P3.3 status chips).
enum ReviewStatus: String, CaseIterable {
    case filled, edited, needsJudgement, insufficientEvidence, conflictSkipped, proposedChange, writeFailed, calculated

    var title: String {
        switch self {
        case .filled: "filled"
        case .edited: "edited by you"
        case .needsJudgement: "needs your judgement"
        case .insufficientEvidence: "insufficient evidence"
        case .conflictSkipped: "kept your value"
        case .proposedChange: "proposed change"
        case .writeFailed: "write failed"
        case .calculated: "calculated"
        }
    }

    /// For list rows, where space is tight.
    var shortTitle: String {
        switch self {
        case .needsJudgement: "yours"
        case .insufficientEvidence: "blank"
        case .conflictSkipped: "kept yours"
        case .proposedChange: "change?"
        case .writeFailed: "failed"
        default: title
        }
    }

    var color: Color {
        switch self {
        case .filled, .calculated: .green
        case .edited: .blue
        case .needsJudgement: .purple
        case .insufficientEvidence: .secondary
        case .conflictSkipped: .orange
        case .proposedChange: .teal
        case .writeFailed: .red
        }
    }

    /// Wants the worker's attention before they confirm.
    var needsAttention: Bool { [.needsJudgement, .conflictSkipped, .proposedChange, .writeFailed].contains(self) }

    /// `updatable`: fields the session's template lets a follow-up change when a different
    /// value is already on file. Those become proposed changes instead of being left alone.
    static func of(_ result: FieldResult, _ report: FillReport?, edited: Bool, updatable: Set<String> = []) -> ReviewStatus {
        if edited { return .edited }
        switch result.status {
        case .clinicianOnly: return .needsJudgement
        case .insufficientEvidence, .rejected: return .insufficientEvidence
        case .derived: return report?.outcome == .computedMismatch ? .writeFailed : .calculated
        case .filled:
            switch report?.outcome {
            case .ok?, .computedVerified?: return .filled
            case .conflictSkipped?: return updatable.contains(result.key) ? .proposedChange : .conflictSkipped
            default: return .writeFailed
            }
        }
    }
}

/// The review panel (BUILD_PLAN P3.3): a floating window beside Safari, not injected into
/// the EHR page. Every field grouped by step with its status; select one to see the client's
/// exact words, jump to it in the form, or write your own value. Confirming ends the session.
public struct ReviewView: View {
    public static let windowID = "review"
    @Bindable var model: SessionModel

    public init(model: SessionModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let extraction = model.extraction {
                content(extraction)
            } else {
                ContentUnavailableView("Nothing to review", systemImage: "checklist",
                                       description: Text("Finish a session and fill the form to review it here."))
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .navigationTitle("Review")
    }

    private func content(_ e: NotePipeline.Extraction) -> some View {
        VStack(spacing: 0) {
            header(e)
            Divider()
            HSplitView {
                fieldList(e).frame(minWidth: 220)
                detail(e).frame(minWidth: 200)
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private func header(_ e: NotePipeline.Extraction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.outcome?.pageTitle ?? e.pageTitle).font(.headline).lineLimit(1)
            let statuses = e.results.map { status($0) }
            HStack(spacing: 10) {
                ForEach([ReviewStatus.filled, .proposedChange, .needsJudgement, .conflictSkipped, .writeFailed], id: \.self) { s in
                    let n = statuses.filter { $0 == s }.count
                    if n > 0 { Chip(status: s, count: n) }
                }
            }
            if model.retention == .none {
                Label("Audio wasn't recorded: quotes only, no playback.", systemImage: "waveform.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.canPlayAudio {
                Label(model.retention == .untilConfirm
                      ? "Audio is kept, encrypted, until you confirm. Press play on a quote to hear it."
                      : "Audio is kept, encrypted, for a while. Press play on a quote to hear it.",
                      systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.unvalidatedModels.isEmpty {
                Label("Not yet validated: \(model.unvalidatedModels.joined(separator: ", ")). Check fields with extra care.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
            let fields = Dictionary(uniqueKeysWithValues: e.profile.fields.map { ($0.key, $0) })
            let required = e.results.filter { requiredBlank($0, fields[$0.key]) }.count
            if required > 0 {
                Label("\(required) required field\(required == 1 ? " is" : "s are") still blank. The form may not save until \(required == 1 ? "it's" : "they're") filled.",
                      systemImage: "asterisk.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let voices = model.transcript?.otherVoices, !voices.isEmpty {
                let at = voices.prefix(4).map { Duration.seconds($0.start).formatted(.time(pattern: .minuteSecond)) }
                    .joined(separator: ", ") + (voices.count > 4 ? "…" : "")
                Label("Another voice was heard on the client's line (\(at)). Check who was present before relying on those lines.",
                      systemImage: "person.2.wave.2")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let gaps = model.transcript?.gaps, !gaps.isEmpty {
                Label("\(gaps.count) stretch\(gaps.count == 1 ? "" : "es") of audio missing from the transcript. Anything said then isn't here.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = model.reviewError {
                Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            Picker("Show", selection: $model.reviewFilter) {
                ForEach(ReviewFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    // MARK: - List

    private func fieldList(_ e: NotePipeline.Extraction) -> some View {
        let fields = Dictionary(uniqueKeysWithValues: e.profile.fields.map { ($0.key, $0) })
        let shown = e.results.filter { r in
            let s = status(r)
            return switch model.reviewFilter {
            case .attention: s.needsAttention || requiredBlank(r, fields[r.key])
            case .all: fields[r.key]?.kind != .hidden
            case .filled: s == .filled || s == .edited || s == .calculated
            case .blank: s == .insufficientEvidence
            }
        }
        return List(selection: $model.reviewSelection) {
            ForEach(e.profile.steps, id: \.id) { step in
                let rows = shown.filter { fields[$0.key]?.step == step.id }
                if !rows.isEmpty {
                    Section(Self.stepTitle(step.id)) {
                        ForEach(rows, id: \.key) { r in
                            FieldRow(label: fields[r.key]?.label ?? r.key, value: displayValue(r, fields[r.key]),
                                     status: status(r), requiredBlank: requiredBlank(r, fields[r.key]))
                                .tag(r.key)
                        }
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                Text(model.reviewFilter == .attention ? "Nothing needs you. Check the form, then confirm." : "No fields here.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ e: NotePipeline.Extraction) -> some View {
        if let key = model.reviewSelection,
           let result = e.results.first(where: { $0.key == key }),
           let field = e.profile.fields.first(where: { $0.key == key }) {
            FieldDetail(model: model, field: field, result: result, status: status(result),
                        report: report(key), segments: model.transcript?.segments ?? [])
                .id(key)
        } else {
            Text("Select a field to see what was said and where it came from.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Undo all…", role: .destructive) { model.confirmingUndo = true }
                .disabled(model.outcome == nil || model.busyKey != nil)
                .confirmationDialog("Put every field back the way it was before Scribeski wrote to it?",
                                    isPresented: $model.confirmingUndo) {
                    Button("Undo all", role: .destructive) { model.undoAll() }
                }
            Spacer()
            Button {
                model.confirmReviewed()
            } label: {
                Text("I've reviewed this").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state != .reviewing || model.busyKey != nil)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func report(_ key: String) -> FillReport? {
        model.outcome?.reports.last { $0.key == key }
    }

    /// The form marks it required and Scribeski left it empty: the worker must fill it (in
    /// the form or here) before the note can be saved.
    private func requiredBlank(_ r: FieldResult, _ f: FormProfile.Field?) -> Bool {
        guard let f, f.required, f.kind != .hidden, !f.computed, model.edited[r.key] == nil else { return false }
        return [.insufficientEvidence, .needsJudgement, .writeFailed].contains(status(r))
    }

    private func status(_ r: FieldResult) -> ReviewStatus {
        ReviewStatus.of(r, report(r.key), edited: model.edited[r.key] != nil,
                        updatable: model.extraction?.template?.updatable ?? [])
    }

    private func displayValue(_ r: FieldResult, _ f: FormProfile.Field?) -> String? {
        guard let v = model.edited[r.key] ?? r.value else { return nil }
        return Self.label(v, f)
    }

    static func label(_ v: FieldValue, _ f: FormProfile.Field?) -> String {
        func one(_ s: String) -> String { f?.options.first { $0.value == s }?.label ?? s }
        switch v {
        case .single(let s): return one(s)
        case .multiple(let a): return a.map(one).joined(separator: ", ")
        }
    }

    static func stepTitle(_ id: String) -> String {
        id.replacingOccurrences(of: "step-", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct Chip: View {
    let status: ReviewStatus
    var count: Int?
    var short = false

    var body: some View {
        Text(count.map { "\($0) \(status.title)" } ?? (short ? status.shortTitle : status.title))
            .lineLimit(1)
            .fixedSize()
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

private struct FieldRow: View {
    let label: String
    let value: String?
    let status: ReviewStatus
    var requiredBlank = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).lineLimit(1)
                if requiredBlank {
                    Text("required").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        .accessibilityLabel("Required, still blank")
                }
                Spacer(minLength: 4)
                Chip(status: status, short: true)
            }
            if let value {
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FieldDetail: View {
    @Bindable var model: SessionModel
    let field: FormProfile.Field
    let result: FieldResult
    let status: ReviewStatus
    let report: FillReport?
    let segments: [Transcript.Segment]

    /// The worker's in-progress value, kept on the model (see `SessionModel.drafts`).
    private var draft: Binding<String> {
        Binding(get: {
            if case .single(let s)? = model.drafts[field.key] ?? model.edited[field.key] ?? result.value { return s }
            return ""
        }, set: { model.drafts[field.key] = .single($0) })
    }

    private var choices: Set<String> {
        if case .multiple(let a)? = model.drafts[field.key] ?? model.edited[field.key] ?? result.value { return Set(a) }
        return []
    }

    private func toggle(_ value: String, _ on: Bool) {
        var set = choices
        if on { set.insert(value) } else { set.remove(value) }
        model.drafts[field.key] = .multiple(set.sorted())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.headline)
                    Chip(status: status)
                    if let help = field.help { Text(help).font(.caption).foregroundStyle(.secondary) }
                }
                explanation
                evidence
                editor
                Button {
                    model.focus(field.key)
                } label: {
                    Label("Show in form", systemImage: "arrow.up.forward.app")
                }
                .disabled(model.busyKey != nil)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var explanation: some View {
        switch status {
        case .needsJudgement:
            Text("This field is yours to fill: Scribeski never answers it.").font(.callout)
        case .insufficientEvidence:
            Text("Nothing in the session clearly answered this, so it was left blank.").font(.callout)
        case .conflictSkipped:
            Text("The field already had a value Scribeski didn't write, so it was left alone.").font(.callout)
        case .proposedChange:
            VStack(alignment: .leading, spacing: 6) {
                Text("The chart has a different value on file. Change it?").font(.callout)
                if let prior = report?.priorValue, let now = result.value {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        GridRow {
                            Text("On file").font(.caption).foregroundStyle(.secondary)
                            Text(ReviewView.label(prior, field)).strikethrough()
                        }
                        GridRow {
                            Text("Session").font(.caption).foregroundStyle(.secondary)
                            Text(ReviewView.label(now, field)).fontWeight(.medium)
                        }
                    }
                    Button("Accept change") { model.write(field.key, now) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busyKey != nil)
                }
            }
        case .writeFailed:
            Text("The form didn't keep the value. Check the field, or write it again below.").font(.callout)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var evidence: some View {
        if !result.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What was said").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, e in
                    let seg = segments.first { $0.id == e.segment }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(e.quote)”").textSelection(.enabled)
                        if let seg {
                            HStack(spacing: 6) {
                                Text("\(seg.speaker == .worker ? "You" : "Client") · \(Duration.seconds(seg.start).formatted(.time(pattern: .minuteSecond)))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if model.canPlayAudio {
                                    Button {
                                        model.play(seg)
                                    } label: {
                                        Image(systemName: model.playingSegmentID == seg.id ? "stop.circle.fill" : "play.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(model.playingSegmentID == seg.id ? "Stop" : "Play what was said")
                                    .accessibilityLabel(model.playingSegmentID == seg.id ? "Stop" : "Play")
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if field.kind != .hidden, !field.computed, field.write != .never {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your value").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                switch field.kind {
                case .select, .combobox, .radioGroup:
                    Picker("Value", selection: draft) {
                        Text("—").tag("")
                        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                case .checkboxGroup:
                    ForEach(field.options, id: \.value) { o in
                        Toggle(o.label, isOn: Binding(get: { choices.contains(o.value) }, set: { toggle(o.value, $0) }))
                    }
                case .textarea:
                    TextEditor(text: draft).frame(minHeight: 80).font(.body)
                default:
                    TextField(field.kind == .date ? "YYYY-MM-DD" : "Value", text: draft)
                }
                Button(model.busyKey == field.key ? "Writing…" : "Write to form") {
                    let value: FieldValue = field.kind == .checkboxGroup
                        ? .multiple(choices.sorted()) : .single(draft.wrappedValue)
                    model.write(field.key, value)
                }
                .disabled(model.busyKey != nil)
            }
        }
    }
}
