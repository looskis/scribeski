import AppKit
import Capture
import ScribeskiCore
import SuiteModelStore
import SwiftUI

/// First-run setup (BUILD_PLAN P4.3). Opens at launch until finished; "Set up Scribeski…" in
/// the menu reopens it.
public struct OnboardingView: View {
    public static let windowID = "onboarding"
    @Bindable var model: OnboardingModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(12)
            }
        }
        .frame(width: 720, height: 520)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    // MARK: - Chrome

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Button {
                    model.go(step)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: done(step) ? "checkmark.circle.fill" : (step == model.step ? "circle.inset.filled" : "circle"))
                            .foregroundStyle(done(step) ? .green : (step == model.step ? Color.accentColor : .secondary))
                        Text(step.title).fontWeight(step == model.step ? .semibold : .regular)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(step == model.step ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 170)
    }

    /// A step whose outcome is already in place, whichever order the worker went in.
    private func done(_ step: OnboardingModel.Step) -> Bool {
        switch step {
        case .permissions: model.permissionsReady
        case .safari: model.safariCheck == .allowed
        case .models: model.models.ready
        case .form: !model.formsLearned.isEmpty
        case .micCheck: model.mic.heardSpeech
        case .welcome, .recording: step.rawValue < model.step.rawValue
        case .done: model.settings.onboarded
        }
    }

    private var footer: some View {
        HStack {
            if model.canGoBack { Button("Back") { model.back() } }
            Spacer()
            if model.step == .done {
                Button("Start using Scribeski") {
                    model.finish()
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                if model.step != .welcome { Button("Skip for now") { model.next() } }
                Button(model.step == .welcome ? "Set up" : "Continue") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
        switch model.step {
        case .permissions: model.permissionsReady || !model.live
        default: true
        }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions: permissions
        case .safari: safari
        case .models: modelsStep
        case .recording: recording
        case .form: form
        case .micCheck: micCheck
        case .done: ready
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Scribeski writes your visit notes",
                    "It listens to your Zoom or Meet call, transcribes it on this Mac, and fills your agency's form in Safari. You review every field before anything is final.")
            point("lock.shield", "Everything stays on this Mac", "No audio, transcript, or note is sent anywhere. The models run here.")
            point("waveform.slash", "Nothing recorded unless you choose", "By default audio lives in memory for seconds and is never saved. You can tell clients so.")
            point("checkmark.rectangle.stack", "You confirm everything", "Fields Scribeski isn't sure about are left for you. Clinical judgements are always yours.")
            Text("Setup takes about five minutes, plus the model download.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).frame(width: 28).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Let Scribeski hear the call",
                    "macOS asks you for each of these once. This page updates as soon as you allow them.")
            permissionRow(.microphone, "Your side of the conversation.")
            permissionRow(.callAudio, "The client's side: audio from Zoom or your browser only, never the whole Mac.")
            permissionRow(.safariAutomation, "Filling the form in Safari. Needed only when you fill; you can allow it later.")
        }
    }

    private func permissionRow(_ p: Permission, _ why: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            let status = model.session.permissions[p]
            Image(systemName: status == .granted ? "checkmark.circle.fill" : (status == .denied ? "xmark.circle.fill" : "circle.dashed"))
                .font(.title3)
                .foregroundStyle(status == .granted ? .green : (status == .denied ? .red : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.headline)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if status == .denied {
                    Text("Turned off. Turn it on in System Settings, then come back.").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch status {
            case .granted?: EmptyView()
            case .denied?: Button("Open System Settings") { NSWorkspace.shared.open(p.settingsURL) }
            default: Button("Allow…") { Task { await model.request(p) } }
            }
        }
    }

    private var safari: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Let Scribeski fill forms in Safari",
                    "Safari only lets apps fill pages if you turn on one setting. It's in Safari's developer settings; you don't need to be a developer.")
            VStack(alignment: .leading, spacing: 8) {
                step(1, "In Safari, choose Safari → Settings → Advanced, and turn on “Show features for web developers”.")
                step(2, "Open the Developer tab and turn on “Allow JavaScript from Apple Events”.")
                step(3, "Open any page in Safari, then press Check.")
            }
            HStack(spacing: 10) {
                Button("Check") { Task { await model.checkSafari() } }
                    .disabled(model.safariCheck == .checking)
                switch model.safariCheck {
                case .unchecked: EmptyView()
                case .checking: ProgressView().controlSize(.small)
                case .allowed: Label("Safari is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .blocked(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Text("Check runs a harmless one-word script in the page you're looking at. It reads nothing and changes nothing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Download the models",
                    "One model transcribes; one writes the notes. They download once, are checked against a pinned fingerprint, and run entirely on this Mac.")
            ForEach(model.models.rows) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.title3).foregroundStyle(row.installed ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.role == .llm ? "Writing the notes" : "Transcribing").font(.headline)
                        Text(row.name + (row.sizeBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                            .foregroundStyle(.secondary)
                        if let p = model.models.progress[row.role] {
                            ProgressView(value: p).frame(maxWidth: 260)
                        }
                        if let problem = row.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    if !row.installed, model.models.progress[row.role] == nil {
                        Button("Download") { Task { await model.models.download(row.role) } }
                    }
                }
            }
            if let free = model.models.freeBytes {
                Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.models.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("You can keep going while they download.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Is audio kept?",
                    "Your agency may have decided this for you. You can change it later in Settings.")
            Picker("Audio", selection: Binding(get: { RetentionChoice(model.settings.retention) },
                                               set: { model.settings.retention = $0.retention(days: model.settings.retentionDays) })) {
                Text("Not recorded: transcribe only (recommended)").tag(RetentionChoice.none)
                Text("Kept, encrypted, until you confirm the note").tag(RetentionChoice.untilConfirm)
                Text("Kept, encrypted, for a few days").tag(RetentionChoice.days)
            }
            .pickerStyle(.radioGroup)
            .disabled(model.settings.retentionLocked)
            if model.settings.retentionLocked {
                Label("Set by your agency", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.settings.retention == .none
                 ? "Nothing is saved but the text. You can truthfully tell a client “this isn't being recorded.” There's no playback in review."
                 : "Audio is encrypted with a key for that session alone and destroyed on schedule. Review can play back what was said. Tell clients the session is recorded.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Teach Scribeski your form",
                    "Open your agency's note form in Safari (a blank one, or a test client), then learn it. Scribeski reads the fields' labels and choices, never what's typed in them.")
            if model.formsLearned.isEmpty {
                Label("No forms learned yet.", systemImage: "doc.badge.plus").foregroundStyle(.secondary)
            } else {
                ForEach(model.formsLearned, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            HStack {
                Button("Learn a form…") { openWindow(id: LearnView.windowID) }
                Button("Check again") { model.refreshForms() }
            }
            Text("An agency can also hand you a form pack to import, so you skip this.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var micCheck: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Say something", "Talk as you would on a call. Nothing is kept: this only checks the level.")
            if let name = model.mic.deviceName { Text("Microphone: \(name)").foregroundStyle(.secondary) }
            ProgressView(value: Double(model.mic.level)).frame(maxWidth: 360)
            if model.mic.heardSpeech {
                Label("Heard you clearly.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.mic.running {
                Text("Listening…").foregroundStyle(.secondary)
            }
            if let error = model.mic.error { Label(error, systemImage: "mic.slash").foregroundStyle(.red) }
            Text("Use headphones on calls if you can: it keeps the client's voice out of your mic. Scribeski also removes speaker echo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("You're set", "When a call starts, Scribeski offers to transcribe it. Or start from the menu bar.")
            let missing = [
                model.permissionsReady ? nil : "Permissions to hear the call",
                model.safariCheck == .allowed ? nil : "Safari's JavaScript setting (checked when you first fill)",
                model.models.ready || !model.live ? nil : "The models (still downloading, or not yet)",
                model.formsLearned.isEmpty ? "A learned form" : nil,
            ].compactMap { $0 }
            if missing.isEmpty {
                Label("Everything's in place.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Text("Still to do (the menu reminds you):").font(.headline)
                ForEach(missing, id: \.self) { Label($0, systemImage: "circle").foregroundStyle(.secondary) }
            }
        }
    }
}
