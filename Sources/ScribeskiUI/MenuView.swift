import AppKit
import Capture
import Orchestrator
import ScribeskiCore
import SwiftUI

/// The menu-bar window (BUILD_PLAN P3.6): pick the call, affirm consent, start, watch it,
/// stop, follow the pipeline, confirm.
public struct MenuView: View {
    @Bindable var model: SessionModel
    @Environment(\.openWindow) private var openWindow

    public init(model: SessionModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch model.state {
            case .idle, .armed: setup
            case .recording(let startedAt): recording(since: startedAt)
            case .stopping, .transcribing, .extracting, .filling: pipeline
            case .readyToFill: readyToFill
            case .reviewing, .confirmed, .purged: review
            case .failed(let stage, let message): failure(stage, message)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.watchSources()
            model.refreshPermissions()
            model.refreshCharts()
            model.findRecovery()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Scribeski").font(.headline)
            Spacer()
            if let note = model.driver.simulationNote {
                Text(note.hasPrefix("Capture is real") ? "DEV" : "SIMULATED")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                    .help(note)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = model.recovery { recoveryBanner(r) }
            if model.tooManyUnreviewed || model.unreviewedWarning {
                HStack(alignment: .top) {
                    Alarm(text: model.tooManyUnreviewed
                          ? "\(model.pendingSessions.count) sessions are waiting for review. Review or discard some before starting another."
                          : "\(model.pendingSessions.count) sessions are waiting for review.")
                    Spacer()
                    Button("Review") {
                        openWindow(id: SessionsView.windowID)
                        NSApplication.shared.activate()
                    }
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Call").font(.subheadline.weight(.medium))
                if model.sources.isEmpty {
                    Text("No call app or browser found. Start or join the call, then reopen this menu.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, isSelected: source.id == model.selectedSourceID)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedSourceID = source.id }
                    }
                }
            }

            chartSection

            Label(model.retentionStatement.prefix(1).uppercased() + model.retentionStatement.dropFirst(),
                  systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
            if let mic = model.microphoneName {
                Label(mic, systemImage: "mic").font(.callout).foregroundStyle(.secondary)
            } else {
                Alarm(text: "No microphone connected. Your side of the call won't be transcribed.")
            }

            if !AppSettings.shared.onboarded, model.driver.simulationNote == nil {
                Button {
                    openWindow(id: OnboardingView.windowID)
                    NSApplication.shared.activate()
                } label: {
                    Label("Finish setting up Scribeski", systemImage: "sparkles")
                }
                .buttonStyle(.link)
            }

            if model.needsPermissionAttention {
                PermissionsBlock(model: model)
            }

            Toggle("The client has agreed to transcription", isOn: $model.consentAffirmed)
                .toggleStyle(.checkbox)

            if let note = model.statusNote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }

            Button {
                model.start()
            } label: {
                Label(model.chartDeferred ? "Start transcribing" : model.selectedChart.map { "Start · \($0.binding.shortName)" } ?? "Start transcribing",
                      systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStart)
        }
    }

    /// A session that didn't finish: pick it up from what was saved. Nothing is re-recorded.
    private func recoveryBanner(_ r: SessionModel.Recovery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("A session didn't finish", systemImage: "arrow.uturn.forward.circle").font(.callout.weight(.medium))
            Text("\(r.started.formatted(date: .abbreviated, time: .shortened))\(r.client.map { " · \($0)" } ?? "") · "
                 + (r.hasNotes ? "notes saved" : "\(r.lines) line\(r.lines == 1 ? "" : "s") saved"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(r.hasNotes ? "Continue to filling" : "Continue to notes") { model.resume() }
                    .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) { model.discardRecovery() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Whose chart this session is for (BUILD_PLAN P3.1). Pressing Start confirms it.
    @ViewBuilder private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chart").font(.subheadline.weight(.medium))
                Spacer()
                if !model.chartCandidates.isEmpty {
                    Menu(model.chartDeferred ? "Later" : "Change") {
                        ForEach(model.chartCandidates) { c in
                            Button(c.binding.display) {
                                model.chartSelectionID = c.id
                                model.chartDeferred = false
                            }
                        }
                        Divider()
                        Button("Pick it before filling") {
                            model.chartSelectionID = nil
                            model.chartDeferred = true
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
            }
            if let c = model.selectedChart, !model.chartDeferred {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.binding.display).font(.callout.weight(.medium))
                    Text(c.binding.formName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                sessionType
            } else if model.chartDeferred {
                Text("You'll pick the chart before filling.").font(.callout).foregroundStyle(.secondary)
            } else if model.chartCandidates.count > 1 {
                Text("\(model.chartCandidates.count) charts are open. Choose this session's client from Change.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No chart open. Paste its address, or pick it before filling.").font(.callout).foregroundStyle(.secondary)
                if model.learnedForms.count > 1 {
                    Picker("Form", selection: $model.selectedFormFingerprint) {
                        ForEach(model.learnedForms, id: \.fingerprint) { Text($0.name).tag(Optional($0.fingerprint)) }
                    }
                    .font(.caption)
                }
                sessionType
            }
            addressField
        }
    }

    /// "Paste the chart's address": finds that tab (or offers to open it) and uses it.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Paste the chart's address", text: $model.chartAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { model.useChartAddress() }
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        model.chartAddress = s
                        model.useChartAddress()
                    }
                }
                .controlSize(.small)
            }
            if let note = model.addressNote {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.addressToOpen != nil {
                Button("Open it in Safari") { Task { await model.openChartAddress() } }.controlSize(.small)
            }
        }
    }

    /// Intake, Follow-up…: which of the form's templates this session uses.
    @ViewBuilder private var sessionType: some View {
        if model.templates.count > 1, let selected = model.selectedTemplate {
            Picker("Session", selection: Binding(get: { selected.id }, set: { model.chooseTemplate($0) })) {
                ForEach(model.templates) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .font(.caption)
        }
    }

    private func recording(since start: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                // The line the worker can read aloud to the client.
                Text("Transcribing · \(model.retentionStatement)").font(.body.weight(.medium))
                Spacer()
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(start)),
                         format: .time(pattern: .minuteSecond))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let source = model.selectedSource {
                Text(source.name).font(.callout).foregroundStyle(.secondary)
            }

            LevelMeter(label: "You", level: model.workerLevel)
            LevelMeter(label: "Client", level: model.clientLevel)

            if let last = model.liveSegments.last {
                // The latest final line, so the worker can see it's working.
                (Text(last.speaker == .worker ? "You: " : "Client: ").bold() + Text(last.text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.microphoneName == nil {
                Alarm(text: "No microphone. Only the client's side is being captured.")
            }
            if model.isClientSilent {
                Alarm(text: "No client audio for \(Int(model.clientSilentSeconds)) s. Is the call app muted or on another output?")
            }
            if model.isFallingBehind {
                Alarm(text: "Transcription is falling behind.")
            }

            Button(role: .destructive) {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
        }
    }

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working on the note").font(.body.weight(.medium))
            if let t = model.transcript {
                Text("\(t.segments.count) lines transcribed").font(.caption).foregroundStyle(.secondary)
            }
            PipelineStep(title: "Transcribing", state: model.state, step: .transcribing)
            PipelineStep(title: "Extracting fields", state: model.state, step: .extracting)
            PipelineStep(title: "Filling the form", state: model.state, step: .filling)
            if let note = model.statusNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Target confirmation (BUILD_PLAN P3.3): nothing is written until the worker says this
    /// tab is the right chart. The fill re-checks the form's fingerprint too.
    private var readyToFill: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes are ready", systemImage: "checkmark.seal").font(.body.weight(.medium))
            if let e = model.extraction {
                let filled = e.results.filter { $0.status == .filled }.count
                Text("\(filled) of \(e.results.count) fields have answers from the session.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let chart = model.chart {
                boundTarget(chart)
            } else {
                pickTarget
            }
            if let error = model.reviewError {
                Alarm(text: error)
            }
            HStack {
                Button("View transcript") {
                    openWindow(id: TranscriptView.windowID)
                    NSApplication.shared.activate()
                }
                Spacer()
                Button {
                    model.confirmFill()
                } label: {
                    Text(model.chart.map { "Fill \($0.shortName)'s chart" } ?? "Fill the form").frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.fillCandidate == nil)
            }
        }
        .onAppear { model.refreshFillTarget() }
    }

    /// Target confirmation (BUILD_PLAN P3.3): the bound client's chart, found wherever it is.
    /// The fill brings it forward and checks the banner again in the page before writing.
    @ViewBuilder private func boundTarget(_ chart: ChartBinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.fillCandidate == nil ? "Waiting for the chart" : "Fill this chart?")
                .font(.caption).foregroundStyle(.secondary)
            Text(chart.display).font(.callout.weight(.medium))
            Text(chart.formName + (model.fillCandidate.map { " · Safari, window \($0.tab.windowOrder)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        if !model.fillChoices.isEmpty {
            Text("This chart is open in \(model.fillChoices.count) tabs. Which one? Pick below, or paste the tab's address.")
                .font(.caption).foregroundStyle(.orange)
            addressField
            ForEach(model.fillChoices) { c in
                Button {
                    model.chooseFillTab(c)
                } label: {
                    HStack {
                        Image(systemName: model.fillCandidate?.id == c.id ? "largecircle.fill.circle" : "circle")
                        Text("Window \(c.tab.windowOrder), tab \(c.tab.tabIndex)\(c.tab.isFront ? " (in front)" : "")")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        } else if model.fillCandidate == nil {
            addressField
            HStack {
                Text("Open the chart for \(chart.display) in Safari to fill it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Look again") { model.refreshFillTarget() }.controlSize(.small)
            }
        }
    }

    /// No chart was bound at Start: the worker picks one now. Never guessed.
    @ViewBuilder private var pickTarget: some View {
        Text("Which client's chart is this for?").font(.caption).foregroundStyle(.secondary)
        addressField
        if model.chartCandidates.isEmpty {
            HStack {
                Text("No open chart of this form. Open the client's chart in Safari.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Look again") { model.refreshFillTarget() }.controlSize(.small)
            }
        } else {
            ForEach(model.chartCandidates) { c in
                Button {
                    model.bindChart(c)
                } label: {
                    HStack {
                        Image(systemName: "person.text.rectangle")
                        Text(c.binding.display)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Form filled. Review it before you submit.", systemImage: "checklist")
                .font(.body.weight(.medium))
            if let o = model.outcome {
                let ok = o.reports.filter { $0.outcome == .ok || $0.outcome == .computedVerified }.count
                let judgement = o.results.filter { $0.status == .clinicianOnly || $0.status == .rejected }.count
                let problems = o.reports.count - ok
                Text("\(ok) fields written · \(judgement) need your judgement\(problems > 0 ? " · \(problems) didn't stick" : "")")
                    .font(.callout).foregroundStyle(.secondary)
                if o.pageNetworkRequests > 0 {
                    Alarm(text: "The page made \(o.pageNetworkRequests) network request(s) while filling. It may autosave drafts.")
                }
            }
            HStack {
                Button("View transcript") {
                    openWindow(id: TranscriptView.windowID)
                    NSApplication.shared.activate()
                }
                .disabled(model.transcript == nil)
                Button("Open review") {
                    openWindow(id: ReviewView.windowID)
                    NSApplication.shared.activate()
                }
                .disabled(model.extraction == nil)
            }
            Button {
                model.confirmReviewed()
            } label: {
                Text("I've reviewed this").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(model.retention == .none
                 ? "Confirming ends the session. No audio was recorded."
                 : "Confirming ends the session and deletes the audio per your retention setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func failure(_ stage: SessionState.Stage, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Stopped while \(stage.rawValue)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.body.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let drift = model.drift {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(drift.renamed.prefix(4), id: \.self) { Text("moved: \($0.old) → \($0.new)") }
                    ForEach(drift.added.prefix(4), id: \.self) { Text("new, left blank: \($0)") }
                    ForEach(drift.removed.prefix(4), id: \.self) { Text("removed: \($0)") }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Accept changes and fill") { model.acceptDrift() }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Retry") { model.retry() }.buttonStyle(.borderedProminent)
                Button("Discard") { model.discard() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Learn a form…") {
                openWindow(id: LearnView.windowID)
                NSApplication.shared.activate()
            }
            .disabled(model.state != .idle)
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApplication.shared.activate() })
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .disabled(model.state.isCapturing || model.state.isProcessing)
                .help(model.state.isCapturing ? "Stop the session first." : "")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Pieces

struct SourceRow: View {
    let source: CallSource
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                    if source.isInCall {
                        Text("in a call")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(.green)
                            .background(.green.opacity(0.12), in: Capsule())
                    } else if source.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Playing audio now")
                    }
                }
                if let warning = source.isolationWarning {
                    // Whole-browser capture is the real privacy cost; the rest are notes.
                    Text(warning).font(.caption)
                        .foregroundStyle(source.kind == .browser ? Color.orange : .secondary)
                }
            }
        }
    }
}

struct PermissionsBlock: View {
    let model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.subheadline.weight(.medium))
            ForEach(Permission.allCases, id: \.self) { permission in
                HStack(spacing: 8) {
                    icon(model.permissions[permission])
                    VStack(alignment: .leading, spacing: 0) {
                        Text(permission.title)
                        if permission == .safariAutomation {
                            Text("Needed to fill the form").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    switch model.permissions[permission] {
                    case .notDetermined?:
                        Button("Allow…") { Task { await model.request(permission) } }
                    case .denied?:
                        Button("Open Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                    case .unknown? where permission == .safariAutomation:
                        Text("Open Safari to check").font(.caption).foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func icon(_ status: PermissionStatus?) -> some View {
        switch status {
        case .granted?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined?: Image(systemName: "circle.dashed").foregroundStyle(.orange)
        default: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct Alarm: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PipelineStep: View {
    let title: String
    let state: SessionState
    let step: SessionState

    private static let order: [SessionState] = [.stopping, .transcribing, .extracting, .filling, .reviewing]

    var body: some View {
        let current = Self.order.firstIndex(of: state == .stopping ? .transcribing : state) ?? 0
        let mine = Self.order.firstIndex(of: step) ?? 0
        HStack(spacing: 8) {
            Group {
                if mine < current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if mine == current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            Text(title).foregroundStyle(mine > current ? .secondary : .primary)
        }
    }
}

extension SessionModel {
    /// SF Symbol for the menu-bar item.
    public var menuBarSymbol: String {
        switch state {
        case .recording: "record.circle.fill"
        case .stopping, .transcribing, .extracting, .filling: "hourglass"
        case .reviewing: "checklist"
        case .readyToFill: "square.and.pencil"
        case .failed: "exclamationmark.triangle"
        default: "waveform"
        }
    }
}
