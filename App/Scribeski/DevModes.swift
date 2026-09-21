#if DEBUG
import Capture
import Darwin
import Extraction
import Foundation
import Orchestrator
import ScribeskiCore
import ScribeskiUI
import Storage
import SwiftUI
import Transcription

/// Developer modes: probes, harnesses, demos. Compiled into Debug builds only, so a shipped
/// app can't be told to record without the consent screen (`--auto-session`) or to mute the
/// call (`--silent`). Each `run…` either exits the process or configures the session.
enum DevModes {
    static var demoTranscript: Bool { CommandLine.arguments.contains("--demo-transcript") }
    static var simulated: Bool { CommandLine.arguments.contains("--simulated") }
    /// Modes that open windows or drive a session themselves don't want the call watcher.
    static var suppressesCallWatcher: Bool {
        ["--auto-session", "--demo-review", "--demo-learn", "--learn-probe", "--recovery-report"]
            .contains(where: CommandLine.arguments.contains)
    }

    /// One-shot probes that write a JSON report and exit before the app starts.
    @MainActor static func runExclusiveModes() {
        let args = CommandLine.arguments
        // Dev: start the note-writing sidecar exactly as a session does (the bundled helper,
        // unix socket, lockdown checks), ask it one thing, stop it, and report. No transcript.
        // `open -W App.app --args --sidecar-check <out.json>`
        if let i = args.firstIndex(of: "--sidecar-check"), i + 1 < args.count {
            let out = args[i + 1]
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                var report: [String: Any] = [:]
                do {
                    let config = try LlamaServer.Configuration.fromModelStore()
                    report["binary"] = config.binary.path
                    report["bundled"] = config.binary.path.hasPrefix(Bundle.main.bundleURL.path)
                    let server = LlamaServer(config)
                    let started = ContinuousClock.now
                    let client = try await server.start()
                    report["start_seconds"] = (ContinuousClock.now - started).components.seconds
                    report["lockdown"] = "verified"
                    let r = try await client.complete(ChatRequest(
                        messages: [ChatMessage(role: "user", content: "Reply with the single word: ready")], maxTokens: 8))
                    report["reply"] = r.content
                    report["ms"] = r.ms
                    server.stop()
                    try? await Task.sleep(for: .milliseconds(500))
                    report["stopped"] = !server.isRunning
                } catch {
                    report["error"] = "\(error)"
                }
                FileManager.default.createFile(atPath: out, contents: try? JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
                done.signal()
            }
            done.wait()
            exit(0)
        }
        // Dev: write this app's own TCC status as JSON and exit. Launch it with
        // `open -W App.app --args --permissions-report <file>` so TCC sees the app, not the shell.
        if let i = args.firstIndex(of: "--permissions-report"), i + 1 < args.count {
            let report = Dictionary(uniqueKeysWithValues: Permission.allCases.map {
                ($0.rawValue, "\(Permissions.status($0))")
            })
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileManager.default.createFile(atPath: args[i + 1], contents: data)
            exit(0)
        }
        // Dev: capture from one app for N seconds and write levels as JSON (P2.2 probe).
        // `open -W App.app --args --capture-probe com.apple.Safari 5 <file>`
        if let i = args.firstIndex(of: "--capture-probe"), i + 3 < args.count {
            let result: Any
            do {
                let report = try CaptureProbe.run(bundleID: args[i + 1], seconds: Double(args[i + 2]) ?? 5)
                result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
            } catch {
                result = ["error": "\(error)"]
            }
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            FileManager.default.createFile(atPath: args[i + 3], contents: data)
            exit(0)
        }
        // Dev: `--restore-check <bundle-id> <seconds> <out.json>`: taps an app by bundle ID (muted)
        // and reports its level every 0.5 s, to see the tap re-attach when the app restarts.
        if let i = args.firstIndex(of: "--restore-check"), i + 3 < args.count {
            let bundle = args[i + 1]
            let procs = AudioProcessList.snapshot().filter { $0.responsibleBundleID == bundle }.map(\.objectID)
            var levels: [Float] = []
            var failure: String?
            do {
                let s = try CaptureSession(processes: procs, bundleIDs: [bundle], useMicrophone: false, silenceSource: true)
                try s.start()
                for _ in 0..<Int((Double(args[i + 2]) ?? 15) * 2) {
                    Thread.sleep(forTimeInterval: 0.5)
                    var peak: Float = 0
                    s.drain { _, x in peak = max(peak, rms(x)) }
                    levels.append((peak * 1000).rounded() / 1000)
                }
                s.stop()
            } catch {
                failure = "\(error)"
            }
            let data = try? JSONSerialization.data(withJSONObject: ["levels": levels, "error": failure ?? NSNull(), "startedWith": procs.count])
            FileManager.default.createFile(atPath: args[i + 3], contents: data)
            exit(0)
        }
        // Dev: `--mute-check pid:N <out.json>`: mic level with the player audible, then muted.
        if let i = args.firstIndex(of: "--mute-check"), i + 2 < args.count, let pid = Int32(args[i + 1].dropFirst(4)) {
            let procs = AudioProcessList.snapshot().filter { $0.pid == pid }.map(\.objectID)
            func micLevel(_ seconds: Double) -> Float {
                guard let s = try? CaptureSession(processes: procs), (try? s.start()) != nil else { return -1 }
                defer { s.stop() }
                var peak: Float = 0
                let end = Date.now.addingTimeInterval(seconds)
                while Date.now < end {
                    Thread.sleep(forTimeInterval: 0.05)
                    s.drain { speaker, x in if speaker == .worker { peak = max(peak, rms(x)) } }
                }
                return peak
            }
            let audible = micLevel(3)
            let muter = ProcessMuter(processes: procs)
            let muted = micLevel(3)
            _ = muter
            let data = try? JSONSerialization.data(withJSONObject: ["audible": audible, "muted": muted, "muter": muter != nil])
            FileManager.default.createFile(atPath: args[i + 2], contents: data)
            exit(0)
        }
        // Dev: `--aec-lab pid:N <seconds> <out.json>` tunes echo cancellation on this room.
        if let i = args.firstIndex(of: "--aec-lab"), i + 3 < args.count, let pid = Int32(args[i + 1].dropFirst(4)) {
            let procs = AudioProcessList.snapshot().filter { $0.pid == pid }.map(\.objectID)
            let result: Any
            do {
                let audio = try EchoLab.capture(processes: procs, seconds: Double(args[i + 2]) ?? 30)
                result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                    EchoLab.evaluate(reference: audio.reference, mic: audio.mic)))
            } catch {
                result = ["error": "\(error)"]
            }
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileManager.default.createFile(atPath: args[i + 3], contents: data)
            exit(0)
        }
        // Dev: live capture → streaming transcription → Transcript JSON (P2.7 harness).
        // `open -W App.app --args --transcribe-probe <bundle|pid:N|-> <seconds> <out.json>
        //   [--client-file f] [--worker-file f] [--distractor-file f] [--reference f] [--no-mic]`
        if let i = args.firstIndex(of: "--transcribe-probe"), i + 3 < args.count {
            func value(_ flag: String) -> URL? {
                args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            }
            var options = TranscriptionProbe.Options(source: args[i + 1], seconds: Double(args[i + 2]) ?? 30)
            options.clientFile = value("--client-file")
            options.workerFile = value("--worker-file")
            options.distractorFile = value("--distractor-file")
            options.reference = value("--reference")
            options.useMicrophone = !args.contains("--no-mic")
            options.rebuildAt = args.firstIndex(of: "--rebuild-at").flatMap { Double(args[$0 + 1]) }
            options.silent = args.contains("--silent")
            options.cancelEcho = !args.contains("--no-aec")
            options.secondVoice = args.contains("--second-voice")
            let parakeet = args.contains("--engine") && args[args.firstIndex(of: "--engine")! + 1] == "parakeet"
            let out = args[i + 3]
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let data: Data?
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let engine: any Transcriber = parakeet ? try ParakeetTranscriber.fromModelStore() : SpeechAnalyzerTranscriber()
                    // `--retain`: exercise the encrypted audio copy on real capture (P2.6), in a
                    // throwaway store whose keys are destroyed afterwards.
                    var options = options
                    var vault: (AudioVault, SessionStore)?
                    if args.contains("--retain") {
                        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribeski-retain-\(UUID())")
                        let store = try SessionStore(root: root, keys: SessionKeys(service: "com.looski.scribeski.probe"))
                        try store.create(id: "SES-PROBE", retention: .untilConfirm)
                        let v = try AudioVault(store: store, sessionID: "SES-PROBE")
                        vault = (v, store)
                        options.retention = .untilConfirm
                        options.audio = { u in v.append(u.speaker, u.buffer.int16Samples, at: u.start) }
                    }
                    let report = try await TranscriptionProbe.run(options, transcriber: engine)
                    data = try encoder.encode(report)
                    if let (v, store) = vault {
                        v.finish()
                        let check = Self.vaultCheck(store, "SES-PROBE", report.transcript)
                        try? store.purge("SES-PROBE")
                        try? FileManager.default.removeItem(at: store.root)
                        FileManager.default.createFile(atPath: out + ".vault.json",
                                                       contents: try? JSONSerialization.data(withJSONObject: check, options: [.prettyPrinted, .sortedKeys]))
                    }
                } catch {
                    data = try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])
                }
                FileManager.default.createFile(atPath: out, contents: data)
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-review"), i + 4 < args.count {
            MainActor.assumeIsolated {
                do {
                    try MenuSnapshots.writeReview(to: URL(fileURLWithPath: args[i + 1]), outcome: URL(fileURLWithPath: args[i + 2]),
                                                  profile: URL(fileURLWithPath: args[i + 3]), transcript: URL(fileURLWithPath: args[i + 4]),
                                                  select: i + 5 < args.count ? args[i + 5] : nil)
                    exit(0)
                } catch { print(error); exit(1) }
            }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            MainActor.assumeIsolated {
                do { try MenuSnapshots.write(to: dir); exit(0) } catch { print(error); exit(1) }
            }
        }
    }

    /// What the audio copy holds against the transcript: seconds per track, and how many
    /// transcript segments have decryptable, non-silent audio under them.
    nonisolated static func vaultCheck(_ store: SessionStore, _ id: String, _ transcript: Transcript) -> [String: Any] {
        var out: [String: Any] = [:]
        for speaker in Speaker.allCases {
            out["seconds_\(speaker.rawValue)"] = AudioVault.seconds(store, sessionID: id, speaker: speaker)
        }
        var covered = 0
        for seg in transcript.segments {
            let samples = (try? AudioVault.read(store, sessionID: id, speaker: seg.speaker, from: seg.start, to: seg.end)) ?? []
            let rms = samples.isEmpty ? 0 : (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
            if Double(samples.count) >= (seg.end - seg.start) * 16_000 * 0.8, rms > 30 { covered += 1 }
        }
        out["segments"] = transcript.segments.count
        out["segments_with_audio"] = covered
        return out
    }

    /// Demos and harnesses that run inside the normal app.
    @MainActor static func configure(model: SessionModel, learn: inout LearnModel) {
        let args = CommandLine.arguments
        if demoTranscript { model.transcript = MenuSnapshots.demoTranscript }
        // Dev: `--demo-review <outcome.json> <profile.json> <transcript.txt> [field]` opens review on files.
        if let i = args.firstIndex(of: "--demo-review"), i + 3 < args.count {
            try? model.loadDemoReview(outcome: URL(fileURLWithPath: args[i + 1]), profile: URL(fileURLWithPath: args[i + 2]),
                                      transcript: URL(fileURLWithPath: args[i + 3]),
                                      select: i + 4 < args.count ? args[i + 4] : nil)
        }

        // Dev: `--demo-learn <profile.json> <mapping.json> <read|banner|mapping|review>` opens the learn window.
        var learnOut: LearnModel?
        if let i = args.firstIndex(of: "--demo-learn"), i + 3 < args.count,
           let p = try? JSONDecoder().decode(FormProfile.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1]))),
           let m = try? JSONDecoder().decode(FormMapping.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) {
            let step: LearnModel.Step = switch args[i + 3] { case "banner": .banner; case "mapping": .mapping; case "review": .review; default: .read }
            let learn = LearnModel()
            learn.loadDemo(profile: p, mapping: m, step: step)
            learnOut = learn
        }
        if let learnOut { learn = learnOut }
        // Dev: `--learn-probe <out.json> [--generate]`: the learn flow on the front tab, headless,
        // saving into a temporary library (never the real one).
        if let i = args.firstIndex(of: "--learn-probe"), i + 1 < args.count {
            let out = args[i + 1]
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("learn-\(UUID())")
                let learn = LearnModel(library: FormLibrary(directory: dir))
                if let j = args.firstIndex(of: "--address"), j + 1 < args.count {
                    learn.address = args[j + 1]
                    await learn.readAddress()
                    if learn.addressToOpen != nil, args.contains("--open") { await learn.openAddress() }
                } else {
                    await learn.readFrontTab()
                }
                learn.preparePayload()
                if args.contains("--generate") { await learn.generate() }
                if learn.mapping != nil { learn.save() }
                var modes: [String: Int] = [:]
                for f in learn.mapping?.fields.values.map({ $0 }) ?? [] { modes[f.mode.rawValue, default: 0] += 1 }
                let report: [String: Any] = [
                    "title": learn.tab?.title ?? NSNull(), "fields": learn.profile?.fields.count ?? 0,
                    "tab": learn.tab.map { "window \($0.windowOrder) tab \($0.tabIndex) \($0.url)" } ?? NSNull(),
                    "banners": learn.banners.map { ["selector": $0.selector, "text": $0.text] },
                    "idPattern": learn.idPattern, "namePattern": learn.namePattern,
                    "preview": learn.bannerPreview.map { "\($0.id) · \($0.name ?? "-")" } ?? NSNull(),
                    "alreadyLearned": learn.alreadyLearned, "scrubOK": learn.scrubOK,
                    "payloadFields": learn.payloadText.components(separatedBy: "\n").count - 2,
                    "mappingModes": modes, "saved": learn.step == .saved, "error": learn.error ?? NSNull(),
                    "savedForms": FormLibrary(directory: dir).forms().map { "\($0.name) \($0.mapping.chart?.bannerSelector ?? "no chart")" },
                ]
                FileManager.default.createFile(atPath: out, contents: try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
                try? FileManager.default.removeItem(at: dir)
                exit(0)
            }
        }
        // Dev: `--recovery-report <out.json> [--discard]`: what a relaunch would offer after a crash.
        if let i = args.firstIndex(of: "--recovery-report"), i + 1 < args.count {
            let out = args[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                model.findRecovery()
                let r = model.recovery
                let json: [String: Any] = r.map { ["session": $0.sessionID, "stage": $0.stage, "lines": $0.lines,
                                                  "hasNotes": $0.hasNotes, "client": $0.client ?? NSNull()] } ?? ["recovery": NSNull()]
                if args.contains("--discard") { model.discardRecovery() }
                FileManager.default.createFile(atPath: out, contents: try? JSONSerialization.data(withJSONObject: json))
                exit(0)
            }
        }
        // Dev: `--auto-session pid:N <seconds>` runs a real session through the menu's model
        // and opens the transcript, so the whole app path can be checked without clicks.
        if let i = args.firstIndex(of: "--auto-session"), i + 2 < args.count,
           let pid = Int32(args[i + 1].dropFirst(4)), let seconds = Double(args[i + 2]) {
            LiveDriver.devSilenceSource = args.contains("--silent")
            Task { @MainActor in
                let processes = AudioProcessList.snapshot().filter { $0.pid == pid }
                guard !processes.isEmpty else { return }
                await model.autoRun(source: CallSource(bundleID: args[i + 1], name: "Test player", kind: .other,
                                                       processes: processes), seconds: seconds)
            }
        }
    }
}

/// Dev windows and the unattended `--auto-session` path.
struct DevWindowOpener: View {
    let model: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                if CommandLine.arguments.contains("--demo-review") { openWindow(id: ReviewView.windowID) }
                if CommandLine.arguments.contains("--demo-learn") { openWindow(id: LearnView.windowID) }
            }
            .onChange(of: model.state) { _, state in
                let args = CommandLine.arguments
                guard args.contains("--auto-session") else { return }
                // `--auto-fill` also confirms the target tab, for an unattended end-to-end check.
                if state == .readyToFill, args.contains("--auto-fill") { model.confirmFill() }
                if state == .reviewing {
                    openWindow(id: args.contains("--auto-fill") ? ReviewView.windowID : TranscriptView.windowID)
                }
            }
    }
}
#endif
