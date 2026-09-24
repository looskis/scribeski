import AppKit
import Capture
import ScribeskiCore
import FormDriver
import Orchestrator
import SwiftUI
import Transcription

/// Renders the menu in each state to PNGs, light and dark, for review without clicking
/// through a live session: `Scribeski.app/Contents/MacOS/Scribeski --snapshot <dir>`.
@MainActor public enum MenuSnapshots {
    public static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reviewed = SessionModel(driver: SimulatedDriver())
        reviewed.transcript = demoTranscript
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let png = try render(TranscriptView(model: reviewed).frame(width: 560, height: 220), appearance: appearance)
            try png.write(to: directory.appendingPathComponent("6-transcript-\(appearance == .aqua ? "light" : "dark").png"))
        }

        for (name, model) in scenes() {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let png = try render(MenuView(model: model), appearance: appearance)
                try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        try writeWindows(to: directory)
    }

    /// Onboarding, Settings, and Sessions, from fixed state (no TCC, Safari, or model store).
    static func writeWindows(to directory: URL) throws {
        let suite = "scribeski.snapshots"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let models = ModelsModel()
        models.rows = [
            .init(role: .asr, name: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0", sizeBytes: 482_000_000,
                  installed: true, validated: true, custom: false, problem: nil, options: [], selectedID: nil),
            .init(role: .llm, name: "Gemma 4 26B A4B (Q4_0)", license: "Gemma", sizeBytes: 15_600_000_000,
                  installed: false, validated: true, custom: false, problem: nil, options: [], selectedID: nil),
        ]
        models.progress[.llm] = 0.42
        models.freeBytes = 212_000_000_000

        let session = SessionModel(driver: SimulatedDriver())
        session.discoversSources = false
        session.permissions = [.microphone: .granted, .callAudio: .notDetermined, .safariAutomation: .denied]
        let onboarding = OnboardingModel(session: session, models: models, settings: settings)
        onboarding.live = false
        for step in OnboardingModel.Step.allCases {
            onboarding.step = step
            if step == .safari { onboarding.safariCheck = .blocked("Not yet: “Allow JavaScript from Apple Events” is still off.") }
            if step == .form { onboarding.formsLearned = ["Riverside Integrated Client Record"] }
            if step == .micCheck { onboarding.mic.level = 0.62; onboarding.mic.peak = 0.7; onboarding.mic.running = true; onboarding.mic.deviceName = "RODE NT-USB+" }
            let png = try render(OnboardingView(model: onboarding), appearance: .aqua)
            try png.write(to: directory.appendingPathComponent("7-onboarding-\(step.rawValue)-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-")).png"))
        }

        settings.retention = .days(7)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(SettingsView(settings: settings, models: models), appearance: appearance)
                .write(to: directory.appendingPathComponent("8-settings-\(suffix).png"))
        }

        session.pendingSessions = [
            .init(sessionID: "SES-1", started: Date(timeIntervalSince1970: 1_790_000_000), stage: "reviewing",
                  client: "REYES, Daniela · AB-114322", lines: 212, hasNotes: true),
            .init(sessionID: "SES-2", started: Date(timeIntervalSince1970: 1_790_090_000), stage: "extracting",
                  client: nil, lines: 48, hasNotes: false),
        ]
        try render(SessionsView(model: session), appearance: .aqua)
            .write(to: directory.appendingPathComponent("9-sessions-light.png"))
    }

    /// A short transcript for snapshots and `--demo-transcript`.
    public static let demoTranscript = Transcript(
        sessionId: "SES-DEMO", retention: .none,
        tracks: [.worker: .init(source: "mic:RODE"), .client: .init(source: "tap:com.apple.Safari")],
        segments: [
            .init(id: "s0001", speaker: .worker, start: 69.9, end: 71.4, text: "And how's your day been so far?", confidence: 0.92),
            .init(id: "s0002", speaker: .client, start: 74.6, end: 76.5, text: "Honestly, it's been hot.", confidence: 0.72),
            .init(id: "s0003", speaker: .client, start: 76.7, end: 78.2, text: "It's been so hot this week.", confidence: 0.95),
            .init(id: "s0004", speaker: .worker, start: 81.5, end: 83.0, text: "Oh, it's been brutal.", confidence: 0.41),
        ],
        gaps: [.init(track: .client, start: 79.0, end: 80.6, reason: .deviceRebuild)])

    static func scenes() -> [(String, SessionModel)] {
        let meet = CallSource(bundleID: "com.apple.Safari.WebApp.meet", name: "Google Meet", kind: .webApp,
                              processes: [AudioProcess(objectID: 1, pid: 1, bundleID: "com.apple.WebKit.GPU",
                                                       responsibleBundleID: "com.apple.Safari.WebApp.meet",
                                                       isRunningOutput: true)])
        let zoom = CallSource(bundleID: "us.zoom.xos", name: "Zoom", kind: .callApp, processes: [])
        let safari = CallSource(bundleID: "com.apple.Safari", name: "Safari", kind: .browser, processes: [])

        func model(_ path: [SessionState], configure: (SessionModel) -> Void = { _ in }) -> SessionModel {
            let m = SessionModel(driver: SimulatedDriver())
            m.discoversSources = false
            m.microphoneName = "AirPods Pro"
            m.sources = [meet, zoom, safari]
            m.selectedSourceID = meet.id
            for state in path { m.transition(to: state) }
            configure(m)
            return m
        }
        let form = LearnedForm(
            profile: FormProfile(origin: "http://127.0.0.1:8787", pathPattern: "/index.html", fingerprint: "fp",
                                 steps: [], fields: [], unreachable: []),
            mapping: FormMapping(profileFingerprint: "fp", fields: [:], name: "Riverside County HSA — Integrated Client Record"),
            templates: [NoteTemplate(id: "intake", name: "Intake"), NoteTemplate(id: "follow-up", name: "Follow-up")])
        func chart(_ id: String, _ name: String, window: Int) -> ChartCandidate {
            ChartCandidate(tab: SafariTab(windowID: window, tabIndex: 1, windowOrder: window, isCurrentTab: true,
                                          url: "http://127.0.0.1:8787/index.html", title: form.name),
                           binding: ChartBinding(fingerprint: "fp", formName: form.name, clientID: id, clientName: name))
        }
        let daniela = chart("AB-114322", "REYES, Daniela", window: 1)
        let sam = chart("AB-200001", "LEE, Sam", window: 2)
        let recording: [SessionState] = [.armed, .recording(startedAt: .now.addingTimeInterval(-754))]
        let processing = recording + [.stopping, .transcribing, .extracting]
        return [
            ("1-setup", model([]) { $0.consentAffirmed = true }),
            ("1-setup-chart", model([]) {
                $0.consentAffirmed = true
                $0.learnedForms = [form]
                $0.chartCandidates = [daniela]
                $0.chartSelectionID = daniela.id
                $0.templateID = "follow-up"
            }),
            ("1-setup-recovery", model([]) {
                $0.recovery = .init(sessionID: "SES-1", started: Date(timeIntervalSinceNow: -3_600), stage: "recording",
                                    client: "REYES, Daniela · AB-114322", lines: 42, hasNotes: false)
            }),
            ("1-setup-two-charts", model([]) {
                $0.consentAffirmed = true
                $0.learnedForms = [form]
                $0.chartCandidates = [daniela, sam]
            }),
            ("1-setup-permissions", model([]) {
                $0.permissions = [.microphone: .granted, .callAudio: .notDetermined, .safariAutomation: .denied]
            }),
            ("1-setup-empty", model([]) { $0.sources = []; $0.selectedSourceID = nil; $0.microphoneName = nil }),
            ("2-recording", model(recording) {
                $0.workerLevel = 0.1; $0.clientLevel = 0.55
                $0.liveSegments = [TranscribedSegment(speaker: .client, start: 62.2, end: 65.1,
                                                      text: "Mateo gets out at 3, so I have a little bit.")]
            }),
            ("1-setup-loading", model([.armed]) { $0.consentAffirmed = true; $0.statusNote = "Loading the speech model…" }),
            ("2-recording-alarms", model(recording) { $0.clientSilentSeconds = 42; $0.backlogSeconds = 14 }),
            ("3-pipeline", model(processing)),
            ("4-ready-to-fill", model(processing + [.readyToFill]) {
                $0.chart = daniela.binding
                $0.fillCandidate = chart("AB-114322", "REYES, Daniela", window: 2)
            }),
            ("4-ready-to-fill-missing", model(processing + [.readyToFill]) {
                $0.chart = daniela.binding
            }),
            ("4-ready-to-fill-pick", model(processing + [.readyToFill]) {
                $0.chartCandidates = [daniela, sam]
            }),
            ("4-review", model(processing + [.readyToFill, .filling, .reviewing])),
            ("5-failed", model(processing + [.failed(stage: .extracting,
                                                    message: "llama-server exited (code 9). The transcript is saved.")])),
        ]
    }

    static func render(_ view: some View, appearance: NSAppearance.Name) throws -> Data {
        let host = NSHostingView(rootView: view.background(.background))
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = host.fittingSize
        // Real controls only draw inside a window.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
