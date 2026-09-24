import AppKit
import ScribeskiCore
import SuiteModelStore
import SwiftUI
import UniformTypeIdentifiers

/// Settings (BUILD_PLAN P3.5, P4.2). Anything the agency locks with a configuration profile
/// shows its value and "Set by your agency".
public struct SettingsView: View {
    public static let windowID = "settings"
    @Bindable var settings: AppSettings
    @Bindable var models: ModelsModel
    @Environment(\.openWindow) private var openWindow

    public init(settings: AppSettings = .shared, models: ModelsModel) {
        self.settings = settings
        self.models = models
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transcription.tabItem { Label("Transcription", systemImage: "waveform") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .onAppear { models.refresh() }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Picker("Audio", selection: Binding(get: { RetentionChoice(settings.retention) },
                                                   set: { settings.retention = $0.retention(days: settings.retentionDays) })) {
                    Text("Not recorded (transcribe only)").tag(RetentionChoice.none)
                    Text("Kept, encrypted, until you confirm").tag(RetentionChoice.untilConfirm)
                    Text("Kept, encrypted, for some days").tag(RetentionChoice.days)
                }
                .disabled(settings.retentionLocked)
                if case .days = settings.retention {
                    Stepper("Keep audio \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")",
                            value: Binding(get: { settings.retentionDays }, set: { settings.retention = .days($0) }), in: 1...30)
                        .disabled(settings.retentionLocked)
                }
                locked(settings.retentionLocked)
                Text(settings.retention == .none
                     ? "Audio lives only in memory for seconds and is never written to disk. You can say “this isn't being recorded”."
                     : "Audio is encrypted with a key for this session only; deleting the session destroys the key.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Recording") }

            Section {
                Stepper("Keep transcripts and notes \(settings.transcriptDays) days after you confirm",
                        value: $settings.transcriptDays, in: 1...90)
                    .disabled(settings.transcriptDaysLocked)
                locked(settings.transcriptDaysLocked)
                Stepper("Remind me at \(settings.unconfirmedLimit) unreviewed sessions (block new ones at \(settings.unconfirmedLimit * 2))",
                        value: $settings.unconfirmedLimit, in: 1...20)
                    .disabled(settings.unconfirmedLimitLocked)
                locked(settings.unconfirmedLimitLocked)
            } header: { Text("Keeping") }

            Section {
                Button("Set up Scribeski again…") { openWindow(id: OnboardingView.windowID) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Transcription

    private var transcription: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(AppSettings.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(settings.engineLocked)
                locked(settings.engineLocked)
            }
            Section {
                TextEditor(text: Binding(get: { settings.extraVocabulary.joined(separator: "\n") },
                                         set: { settings.extraVocabulary = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .font(.body.monospaced())
                    .frame(height: 120)
                    .disabled(settings.vocabularyLocked)
                locked(settings.vocabularyLocked)
                Text("One per line: program names, medications, staff names. Helps the transcript spell them right. "
                     + "Built in: \(Vocabulary.default.prefix(8).joined(separator: ", "))…")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Words to expect") }
        }
        .formStyle(.grouped)
    }

    // MARK: - Models

    private var modelsTab: some View {
        Form {
            ForEach(models.rows) { row in
                Section {
                    Picker("Model", selection: Binding(get: { row.custom ? "custom" : (row.selectedID ?? "") },
                                                       set: { id in if id != "custom" { models.choose(row.role, catalogID: id) } })) {
                        ForEach(row.options, id: \.id) { m in
                            Text(m.displayName + (m.validated ? "" : " (not validated)")).tag(m.id)
                        }
                        if row.custom { Text(row.name + " (yours, not validated)").tag("custom") }
                    }
                    HStack {
                        if row.installed {
                            Label("On this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let p = models.progress[row.role] {
                            ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%") }
                        } else {
                            Button("Download\(row.sizeBytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? "")") {
                                Task { await models.download(row.role) }
                            }
                        }
                        Spacer()
                        Button("Use my own…") { pickCustom(row.role) }.controlSize(.small)
                        if row.custom { Button("Use the default") { models.useDefault(row.role) }.controlSize(.small) }
                    }
                    if !row.validated {
                        Label("Not validated: it hasn't passed Scribeski's accuracy checks. Sessions using it say so in review.",
                              systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    }
                    if let problem = row.problem { Label(problem, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                    if let license = row.license { Text("License: \(license)").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text(row.role == .llm ? "Writing the notes" : "Transcribing")
                }
            }
            if let free = models.freeBytes {
                Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free for models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = models.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
    }

    private func pickCustom(_ role: ModelRole) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = role == .asr
        panel.canChooseFiles = role == .llm
        if role == .llm { panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data] }
        panel.message = role == .llm ? "Choose a GGUF model file" : "Choose a CoreML Parakeet model folder"
        if panel.runModal() == .OK, let url = panel.url { models.useCustom(role, at: url) }
    }

    @ViewBuilder private func locked(_ isLocked: Bool) -> some View {
        if isLocked {
            Label("Set by your agency", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The retention picker's cases (the day count lives beside it).
enum RetentionChoice: Hashable {
    case none, untilConfirm, days

    init(_ r: Retention) {
        switch r {
        case .none: self = .none
        case .untilConfirm: self = .untilConfirm
        case .days: self = .days
        }
    }

    func retention(days: Int) -> Retention {
        switch self {
        case .none: .none
        case .untilConfirm: .untilConfirm
        case .days: .days(days)
        }
    }
}

extension AppSettings {
    var retentionDays: Int { if case .days(let n) = retention { n } else { 7 } }
}

/// Credits and licences (BUILD_PLAN P4.2: Parakeet's CC-BY-4.0 attribution belongs here).
public struct AboutView: View {
    public init() {}

    static let credits: [(String, String)] = [
        ("Parakeet TDT 0.6B v3", "NVIDIA, CC BY 4.0. Converted to CoreML by FluidInference."),
        ("Gemma 4", "Google, under the Gemma Terms of Use."),
        ("FluidAudio", "FluidInference, Apache License 2.0."),
        ("llama.cpp", "The ggml authors, MIT License."),
        ("SpeexDSP echo canceller", "Xiph.Org Foundation and contributors, BSD 3-Clause License."),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scribeski").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") "
                 + "(\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                .foregroundStyle(.secondary)
            Text("Everything runs on this Mac. Scribeski sends nothing about your sessions anywhere.").font(.callout)
            Divider()
            Text("Built with").font(.headline)
            ForEach(Self.credits, id: \.0) { name, note in
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(.medium))
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
